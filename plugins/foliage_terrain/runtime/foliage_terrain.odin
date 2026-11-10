package foliage_terrain

import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"
import foliage "plugins:foliage/runtime"
import terrain "plugins:terrain/runtime"

// The ground of the foliage from the terrains of the world: it fills the
// tiles of foliage.Foliage_Ground, those over the cells of each Foliage
// that a terrain covers and those the editor asks for, with the highest
// terrain under each sample and the weights of the layers it shows there. A
// Heightfield is read directly where its up is that of the Foliage; any other
// source, or one turned another way, by a ray
// along the down of the Foliage. When a terrain changes, only the tiles over
// the chunks whose version changed (or over the whole terrain, when it
// moves, comes or goes) are read again. The tiles to read wait in a queue,
// GROUND_TILES a frame, sampled in jobs, each against the terrains whose
// box covers it: a world that loads many terrains and Foliage at once keeps
// answering, and the ground arrives over the frames that follow.
//
// A tile is fine (as many samples as the finest terrain under it asks) near
// the streaming sources, within the reach of the meshes of the types of its
// Foliage up to GROUND_REACH, and where the editor asks; farther, where only
// far forms or nothing is drawn, it is coarse: COARSE_SAMPLES per side, a
// Heightfield read from its coarse grid, in memory whatever pages are. A fine
// tile over pages that are not in memory takes the coarse grid there until
// they come. Without sources every tile is fine.

GROUND_TILES :: 24 // tiles of ground read in a call (the step runs in the frame and in each tick)
GROUND_REACH :: f32(512) // m from a source past which a tile is coarse, for the meshes of every type
COARSE_SAMPLES :: 5 // per side of a coarse tile: a step of 8 m, that of the coarse grid of a terrain of 1 m

// What the ground was last written from.
@(storage)
Foliage_Terrain :: struct {
    terrain:[3]u64, // Terrain_Data: epoch, loads and change
    foliage:[2]u64, // Foliage_Data: entries made and loads
    seen:[3]core.Seen, // the tables of Terrain, Foliage and World_Transform
    streamed:u64,   // the revision of the streaming sources
    sources:[dynamic]Seen_Source,
    terrains:[dynamic]Seen_Terrain,
    owners:[dynamic]Seen_Owner,
    regions:[dynamic]Region, // scratch: boxes of the world whose ground changed
    views:[dynamic]Terrain_View,
    now:[dynamic]Seen_Terrain,
    queue:[dynamic]Ground_Task, // tiles to read, in the order they were asked
    queued:[dynamic]Ground_Task, // the same, sorted: what the queue holds
    hidden:[dynamic]Ground_Task, // tiles left without ground while a stroke of the editor is held over them
}

// A tile of the ground of a Foliage to read again.
Ground_Task :: struct {
    entity:core.Entity,
    coord:[2]i32,
    fine:bool, // asked for by the editor: fine wherever the sources are (what the sorted queue holds)
}

// A tile read in a job: the terrains under it and the heights and weights it found.
Tile_Work :: struct {
    task:Ground_Task,
    views:[]Terrain_View,
    owner_world,owner_local:mm.Mat4,
    samples:int,
    coarse:bool,
    heights:[]f32,
    weights:[][4]u8,
    any:bool,
}
Seen_Source :: struct {
    id:base.Asset_Id,
    versions:[dynamic]u32,   // of each chunk
    boxes:[dynamic][2][3]f32, // of each chunk of a Mesh source, in its space
}
Seen_Terrain :: struct {
    entity:core.Entity,
    source:base.Asset_Id,
    transform:mm.Transform,
    low,high:[3]f32, // in the world
}
Seen_Owner :: struct {
    entity:core.Entity,
    transform:mm.Transform,
    epoch:u64,
    loads:u32,
}
Region :: struct {low,high:[3]f32}

// A terrain as the samples read it, for the frame that writes the ground.
Terrain_View :: struct {
    source:^terrain.Source,
    to_local,to_world:mm.Mat4,
    low,high:[3]f32, // of the source, in its space
}

// Samples per side of a tile: one step at least as fine as the finest
// terrain under it, within these.
SAMPLES_MIN :: 9
SAMPLES_MAX :: 65

@(private)
box_corners :: proc "contextless" (m:mm.Mat4,low,high:[3]f32) -> (a,b:[3]f32) {
    a,b={1e30,1e30,1e30},{-1e30,-1e30,-1e30}
    for corner in 0..<8 {
        p:=mm.mat4_point(m,{corner&1!=0?high.x:low.x,corner&2!=0?high.y:low.y,corner&4!=0?high.z:low.z})
        a,b=linalg.min(a,p),linalg.max(b,p)
    }
    return
}

// The box of a source in its own space.
source_box :: proc "contextless" (s:^terrain.Source) -> (low,high:[3]f32) {
    if s.kind==.Mesh {
        low,high={1e30,1e30,1e30},{-1e30,-1e30,-1e30}
        for chunk in s.mesh_chunks {low,high=linalg.min(low,chunk.low),linalg.max(high,chunk.high)}
        return
    }
    low=terrain.source_origin(s)
    high=low+[3]f32{f32(s.samples.x-1),f32(s.samples.y-1),f32(s.samples.z-1)}*s.cell
    if s.kind==.Heightfield {low.y,high.y=-terrain.HEIGHT_LIMIT,terrain.HEIGHT_LIMIT}
    return
}

// The box of a chunk of a Heightfield or Volume in the space of its source,
// with a cell around it: the normals of the samples next to it change too.
chunk_box :: proc "contextless" (s:^terrain.Source,index:int) -> (low,high:[3]f32) {
    coord:=terrain.chunk_coord(s,index)
    origin:=terrain.source_origin(s)
    for axis in 0..<3 {
        first:=int(coord[axis])*int(s.chunk_cells)
        last:=min(first+int(s.chunk_cells),int(s.samples[axis])-1)
        low[axis]=origin[axis]+f32(first-1)*s.cell
        high[axis]=origin[axis]+f32(last+1)*s.cell
    }
    if s.kind==.Heightfield {low.y,high.y=-terrain.HEIGHT_LIMIT,terrain.HEIGHT_LIMIT}
    return
}

// Where the ray from `origin` along `down` (of the world) meets a terrain
// first, in the world, and there in the space of its source: the point and
// the normal of the surface, against the ray (none straight down a Heightfield).
terrain_hit :: proc(view:^Terrain_View,origin,down:[3]f32) -> (point,local,normal:[3]f32,ok:bool) {
    s:=view.source
    o:=mm.mat4_point(view.to_local,origin)
    d:=linalg.normalize0((view.to_local*[4]f32{down.x,down.y,down.z,0}).xyz)
    if d=={} {return}
    if s.kind==.Heightfield && d.y< -0.9999 {
        hit:bool
        local,_,_,hit=heightfield_below(s,o,false)
        if !hit {return}
        return mm.mat4_point(view.to_world,local),local,{},true
    }
    // From above the source, along the ray.
    top:=view.high.y+s.cell
    if s.kind==.Heightfield {top=terrain.HEIGHT_LIMIT}
    if d.y<0 && o.y<top {o-=d*((top-o.y)/(-d.y))}
    hit:bool
    local,normal,hit=terrain.source_ray(s,o,d)
    if !hit {return}
    normal=linalg.normalize0(normal)
    if linalg.dot(normal,d)>0 {normal=-normal}
    return mm.mat4_point(view.to_world,local),local,normal,true
}

// The weights of the layers a source shows at a point of its surface, in its
// space: those painted with its automatic layers over them, at the slope and
// height there. A Heightfield as its chunks show it: over the triangle of its
// cell, from the weights of its samples, each with the rule at the slope and
// the height of its own.
shown_weights :: proc "contextless" (s:^terrain.Source,local,normal:[3]f32) -> [4]u8 {
    count:=int(s.layer_count)
    if s.kind!=.Heightfield {
        return terrain.weights_quantize(terrain.layers_vertex(s,terrain.source_weights_at(s,local),normal,local.y),count)
    }
    at :: proc "contextless" (s:^terrain.Source,x,z:int) -> [4]f32 {
        p:=terrain.source_point(s,{x,0,z})
        return terrain.layers_vertex(s,terrain.source_weights_at(s,p),terrain.heightfield_normal(s,x,z,terrain.LAYER_RULE_SAMPLES),p.y)
    }
    origin:=terrain.source_origin(s)
    column,row:=clamp((local.x-origin.x)/s.cell,0,f32(s.samples.x-1)),clamp((local.z-origin.z)/s.cell,0,f32(s.samples.z-1))
    c,r:=min(int(column),int(s.samples.x)-2),min(int(row),int(s.samples.z)-2)
    u,v:=column-f32(c),row-f32(r)
    a,b,d:=at(s,c,r),at(s,c+1,r),at(s,c,r+1)
    w:=a+(b-a)*u+(d-a)*v
    if u+v>1 {e:=at(s,c+1,r+1);w=e+(d-e)*(1-u)+(b-e)*(1-v)}
    return terrain.weights_quantize(w,count)
}

// Straight down a heightfield from o, in the space of its source: its
// surface there, if it has one. From its coarse grid, with the weights it
// shows there, when coarse or where its pages are not in memory.
@(private)
heightfield_below :: proc(s:^terrain.Source,o:[3]f32,coarse:bool) -> (local:[3]f32,weights:[4]u8,from_coarse,ok:bool) {
    start:=terrain.source_origin(s)
    u,v:=(o.x-start.x)/s.cell,(o.z-start.z)/s.cell
    if !(u>=0) || !(v>=0) || u>f32(s.samples.x-1) || v>f32(s.samples.z-1) {return}
    if !coarse {
        if terrain.source_hole(s,min(int(u),int(s.samples.x)-2),min(int(v),int(s.samples.z)-2)) {return}
        if height,held:=terrain.source_height_held(s,o.x,o.z);held {return {o.x,height,o.z},{},false,true}
    }
    height,_,shown,known:=terrain.source_coarse_at(s,o.x,o.z)
    if !known {return}
    return {o.x,height,o.z},terrain.weights_quantize(shown,int(s.layer_count)),true,true
}

// The heights of a tile of an owner: the highest terrain under each sample
// along the down of the Foliage, in its space, and the weights of its layers
// there; a Heightfield from its coarse grid when coarse. False when no
// terrain is under it.
tile_sample :: proc(views:[]Terrain_View,owner_world,owner_local:mm.Mat4,coord:[2]i32,samples:int,heights:[]f32,weights:[][4]u8,coarse:=false) -> (any:bool) {
    down:=linalg.normalize0(-(owner_world*[4]f32{0,1,0,0}).xyz)
    step:=foliage.CELL_SIZE/f32(samples-1)
    corner:=foliage.cell_corner(coord)
    for &height in heights[:samples*samples] {height=foliage.NO_GROUND}
    for &w in weights[:samples*samples] {w={}}
    for &view in views {
        // Straight down a heightfield, from the space of the Foliage to that of the source and back at once.
        d:=linalg.normalize0((view.to_local*[4]f32{down.x,down.y,down.z,0}).xyz)
        straight:=view.source.kind==.Heightfield && d.y< -0.9999
        to_source,from_source:=view.to_local*owner_world,owner_local*view.to_world
        for z in 0..<samples {
            for x in 0..<samples {
                q:=corner+[3]f32{f32(x)*step,0,f32(z)*step}
                y:f32
                local,normal:[3]f32
                shown:[4]u8
                from_coarse:bool
                if straight {
                    hit:bool
                    local,shown,from_coarse,hit=heightfield_below(view.source,mm.mat4_point(to_source,q),coarse)
                    if !hit {continue}
                    y=mm.mat4_point(from_source,local).y
                } else {
                    point:[3]f32
                    hit:bool
                    point,local,normal,hit=terrain_hit(&view,mm.mat4_point(owner_world,q),down)
                    if !hit {continue}
                    y=mm.mat4_point(owner_local,point).y
                }
                any=true
                best:=&heights[z*samples+x]
                if best^>=y {continue}
                best^=y
                weights[z*samples+x]=from_coarse?shown:shown_weights(view.source,local,normal)
            }
        }
    }
    return
}

// Whether a box of the space of an owner, in x and z, covers some of a tile.
@(private)
covers_tile :: proc "contextless" (low,high:[3]f32,coord:[2]i32) -> bool {
    corner:=foliage.cell_corner(coord)
    return low.x<=corner.x+foliage.CELL_SIZE && high.x>=corner.x && low.z<=corner.z+foliage.CELL_SIZE && high.z>=corner.z
}

@(private)
seen_source :: proc(state:^Foliage_Terrain,id:base.Asset_Id) -> ^Seen_Source {
    for &source in state.sources {if source.id==id {return &source}}
    if _,error:=append(&state.sources,Seen_Source{id=id});error!=nil {return nil}
    return &state.sources[len(state.sources)-1]
}

@(private)
region_add :: proc(state:^Foliage_Terrain,m:mm.Mat4,low,high:[3]f32) {
    a,b:=box_corners(m,low,high)
    append(&state.regions,Region{a,b})
}

// Writes the ground of the foliage where the terrains under it changed, the
// cells a Foliage gains and those asked for. A frame where none of them
// changed reads nothing.
@(step="fixed frame",loops="game editor",stage="simulate",after="terrain_update foliage_load",before="physics_prepare")
foliage_terrain_ground :: proc(
    state:^Foliage_Terrain,ground:^foliage.Foliage_Ground,requests:^foliage.Foliage_Ground_Requests,
    data:core.Ref(foliage.Foliage_Data),foliages:core.Read(foliage.Foliage),
    terrains:core.Read(terrain.Terrain),terrain_data:core.Ref(terrain.Terrain_Data),worlds:core.Read(core.World_Transform),
    sources:core.Ref(scene.Streaming_Sources),job_system:^jobs.Job_System,focus:terrain.Terrain_Focus,problems:^core.Problems,
) {
    asked:=core.take(&requests.cells)
    if data.ptr==nil || terrain_data.ptr==nil {return}
    defer ground_read(state,ground,data,foliages,worlds,sources.ptr,job_system)
    ground_hide(state,ground,foliages,terrains,worlds,focus)
    td:=terrain_data.ptr
    // The versions of the tables: an entity can show another source that is already loaded.
    terrain_now:=[3]u64{u64(td.epoch),td.stats.loads,terrain.terrain_data_change(terrain_data)}
    foliage_now:=[2]u64{data.made,data.stats.loads}
    moved:=core.touched(terrains,&state.seen[0]) | core.touched(foliages,&state.seen[1]) | core.touched(worlds,&state.seen[2])
    streamed:=sources.ptr!=nil?sources.ptr.revision:0
    sources_moved:=streamed!=state.streamed
    state.streamed=streamed
    if terrain_now==state.terrain && foliage_now==state.foliage && !moved && !sources_moved && len(asked)==0 && core.count(foliages)==len(state.owners) {
        if len(state.queue)>0 {ground_views(state,terrains,terrain_data,worlds)}
        return
    }
    rebuilt:=terrain_now.x!=state.terrain.x
    sources_changed:=terrain_now!=state.terrain
    state.terrain,state.foliage=terrain_now,foliage_now
    clear(&state.regions)
    ground_views(state,terrains,terrain_data,worlds)
    // A terrain that comes, goes, moves or shows another source: all it covered and covers.
    for seen in state.terrains {
        same:=false
        for now in state.now {if now.entity==seen.entity && now.source==seen.source && now.transform==seen.transform {same=true;break}}
        if !same || rebuilt {append(&state.regions,Region{seen.low,seen.high})}
    }
    for now in state.now {
        same:=false
        for seen in state.terrains {if now.entity==seen.entity && now.source==seen.source && now.transform==seen.transform {same=true;break}}
        if !same || rebuilt {append(&state.regions,Region{now.low,now.high})}
    }
    clear(&state.terrains)
    append(&state.terrains,..state.now[:])
    // The chunks whose version changed, under each terrain that shows them.
    if sources_changed {
        for &entry in td.entries {
            seen:=seen_source(state,entry.id)
            s:=&entry.source
            whole:=rebuilt || seen==nil || len(seen.versions)!=len(entry.versions)
            for version,i in entry.versions {
                if !whole && seen.versions[i]==version {continue}
                low,high:[3]f32
                if s.kind==.Mesh {
                    if i>=len(s.mesh_chunks) {continue}
                    low,high=s.mesh_chunks[i].low,s.mesh_chunks[i].high
                    if seen!=nil && i<len(seen.boxes) {low,high=linalg.min(low,seen.boxes[i][0]),linalg.max(high,seen.boxes[i][1])}
                } else {low,high=chunk_box(s,i)}
                for &view in state.views {if view.source==s {region_add(state,view.to_world,low,high)}}
            }
            // Forgotten without memory: its next change takes the whole source as changed.
            if seen==nil || resize(&seen.versions,len(entry.versions))!=nil || resize(&seen.boxes,s.kind==.Mesh?len(s.mesh_chunks):0)!=nil {
                if seen!=nil {clear(&seen.versions);clear(&seen.boxes)}
                core.report(problems,core.NONE,"foliage_terrain.memory","out of memory to remember the chunks of a terrain under the foliage; its next change places again the foliage of all of it: free memory")
                continue
            }
            copy(seen.versions[:],entry.versions[:])
            if s.kind==.Mesh {for chunk,i in s.mesh_chunks {seen.boxes[i]={chunk.low,chunk.high}}}
        }
        for i:=len(state.sources)-1;i>=0;i-=1 {
            if terrain.terrain_source(terrain_data,state.sources[i].id)!=nil {continue}
            delete(state.sources[i].versions);delete(state.sources[i].boxes)
            unordered_remove(&state.sources,i)
        }
    }
    // The ground of each Foliage.
    for i:=len(ground.owners)-1;i>=0;i-=1 {
        if core.has(foliages,ground.owners[i].entity) {continue}
        foliage.ground_owner_destroy(&ground.owners[i])
        unordered_remove(&ground.owners,i)
    }
    for i:=len(state.owners)-1;i>=0;i-=1 {if !core.has(foliages,state.owners[i].entity) {unordered_remove(&state.owners,i)}}
    for row in 0..<core.count(foliages) {
        e:=core.entity_at(foliages,row)
        f:=core.at(foliages,row)
        world,placed:=core.get(worlds,e)
        entry:=foliage.data_find(data.ptr,f.source)
        if !placed || entry==nil {continue}
        owner_world:=mm.transform_matrix(world.transform)
        owner_local,inverted:=mm.transform_inverse_matrix(world.transform)
        if !inverted {continue}
        seen:^Seen_Owner
        for &held in state.owners {if held.entity==e {seen=&held;break}}
        owner:=foliage.ground_owner(ground,e)
        fresh:=owner==nil
        enough:=true
        if seen==nil {_,error:=append(&state.owners,Seen_Owner{entity=e});enough=error==nil}
        if fresh && enough {_,error:=append(&ground.owners,foliage.Ground_Owner{entity=e});enough=error==nil}
        if !enough {
            // The next step looks at every Foliage again.
            state.foliage,state.seen[1]={},{}
            core.report(problems,e,"foliage_terrain.memory","out of memory for the ground under this Foliage; it is looked at again in the next frame: free memory")
            continue
        }
        if seen==nil {seen=&state.owners[len(state.owners)-1]}
        if fresh {owner=&ground.owners[len(ground.owners)-1]}
        if len(state.views)>0 {
            first:=state.views[0].source
            owner.layer_count=min(first.layer_count,foliage.RULE_LAYERS)
            for &material,i in owner.layers[:owner.layer_count] {material=first.layers[i].material}
        }
        cells:=seen.epoch!=entry.epoch || seen.loads!=entry.loads
        asked_here:=false
        for request in asked {asked_here||=request.entity==e}
        if !fresh && !cells && !asked_here && !sources_moved && len(state.regions)==0 && seen.transform==world.transform {continue}
        // The terrains in the space of this Foliage, and how fine its tiles are.
        step:=f32(foliage.CELL_SIZE)
        boxes:=make([][2][3]f32,len(state.views),context.temp_allocator)
        for &view,k in state.views {
            a,b:=box_corners(owner_local*view.to_world,view.low,view.high)
            boxes[k]={a,b}
            scale:=linalg.length((owner_local*view.to_world*[4]f32{1,0,0,0}).xyz)
            step=min(step,view.source.cell*scale)
        }
        samples:=u32(clamp(int(math.ceil(foliage.CELL_SIZE/max(step,1e-3)))+1,SAMPLES_MIN,SAMPLES_MAX))
        all:=seen.transform!=world.transform || owner.samples!=samples
        if owner.samples!=samples {foliage.ground_owner_reset(owner,samples)}
        seen.transform,seen.epoch,seen.loads=world.transform,entry.epoch,entry.loads
        covered :: proc "contextless" (boxes:[][2][3]f32,coord:[2]i32) -> bool {
            for box in boxes {if covers_tile(box[0],box[1],coord) {return true}}
            return false
        }
        // The tiles and cells the regions cover: each region names those under
        // it, of the ones this Foliage has, once its box meets theirs in the world.
        touched:=make(map[[2]i32]struct{},context.temp_allocator)
        if !all && len(state.regions)>0 {
            lo,hi:=[2]i32{max(i32),max(i32)},[2]i32{min(i32),min(i32)}
            for tile in owner.tiles {lo,hi=linalg.min(lo,tile.coord),linalg.max(hi,tile.coord)}
            for &cell in entry.source.cells {lo,hi=linalg.min(lo,cell.coord),linalg.max(hi,cell.coord)}
            if lo.x<=hi.x {
                c:=foliage.CELL_SIZE
                near_low,near_high:=box_corners(owner_world,{f32(lo.x)*c,-terrain.HEIGHT_LIMIT,f32(lo.y)*c},{f32(hi.x+1)*c,terrain.HEIGHT_LIMIT,f32(hi.y+1)*c})
                for region in state.regions {
                    if region.low.x>near_high.x || region.high.x<near_low.x || region.low.y>near_high.y || region.high.y<near_low.y || region.low.z>near_high.z || region.high.z<near_low.z {continue}
                    a,b:=box_corners(owner_local,region.low,region.high)
                    first:=[2]i32{i32(clamp(math.floor(a.x/c)-1,f32(lo.x),f32(hi.x)+1)),i32(clamp(math.floor(a.z/c)-1,f32(lo.y),f32(hi.y)+1))}
                    last:=[2]i32{i32(clamp(math.floor(b.x/c)+1,f32(lo.x)-1,f32(hi.x))),i32(clamp(math.floor(b.z/c)+1,f32(lo.y)-1,f32(hi.y)))}
                    for z in first.y..=last.y {for x in first.x..=last.x {if covers_tile(a,b,{x,z}) {touched[{x,z}]={}}}}
                }
            }
        }
        // A tile is (re)read when its owner moved, a region over it changed,
        // or its cell or a request needs one it does not have.
        for tile in owner.tiles {
            if all || tile.coord in touched {ground_ask(state,e,tile.coord)}
        }
        need :: proc(owner:^foliage.Ground_Owner,boxes:[][2][3]f32,coord:[2]i32) -> bool {
            return foliage.ground_tile_find(owner,coord)<0 && covered(boxes,coord)
        }
        // A region also covers cells without a tile: a terrain came, moved or grew, or its pages came.
        for &cell in entry.source.cells {
            if (cells || all || cell.coord in touched) && need(owner,boxes,cell.coord) {ground_ask(state,e,cell.coord)}
        }
        // The editor asks for fine ground under its brush.
        for request in asked {
            if request.entity!=e || !covered(boxes,request.coord) {continue}
            if foliage.ground_tile_samples(owner,request.coord)!=owner.samples {ground_ask(state,e,request.coord,true)}
        }
        // A tile goes from fine to coarse, or back, as the sources move.
        if sources_moved || cells || all {
            near:=ground_near(sources.ptr,owner_world,&entry.source)
            for tile in owner.tiles {
                fine:=foliage.ground_tile_samples(owner,tile.coord)!=COARSE_SAMPLES
                if tile_fine(&near,tile.coord,fine)!=fine {ground_ask(state,e,tile.coord)}
            }
        }
    }
}

// The sources as a Foliage sees them, as far as the meshes of its types are
// drawn (a type never culled, or none, as far as GROUND_REACH), up to it.
@(private)
ground_near :: proc(sources:^scene.Streaming_Sources,placed:mm.Mat4,s:^foliage.Source) -> scene.Sources_Near {
    reach:=len(s.types)==0?GROUND_REACH:0
    for t in s.types {
        _,cull:=foliage.mesh_distances(t,foliage.type_far(t))
        reach=max(reach,cull>0?min(cull,GROUND_REACH):GROUND_REACH)
    }
    return scene.sources_near(sources,placed,reach)
}

// Whether the tile of a cell is fine: near a source, by its residency, or
// everywhere without sources.
@(private)
tile_fine :: proc "contextless" (near:^scene.Sources_Near,coord:[2]i32,was:bool) -> bool {
    if near.count==0 {return true}
    corner:=foliage.cell_corner(coord)
    low,high:=[3]f32{corner.x,-foliage.POSITION_MAX,corner.z},[3]f32{corner.x+foliage.CELL_SIZE,foliage.POSITION_MAX,corner.z+foliage.CELL_SIZE}
    return scene.resident(scene.box_near(near,low,high),was)
}

// The terrains as they are now: the views the samples read.
@(private)
ground_views :: proc(state:^Foliage_Terrain,terrains:core.Read(terrain.Terrain),terrain_data:core.Ref(terrain.Terrain_Data),worlds:core.Read(core.World_Transform)) {
    clear(&state.views)
    clear(&state.now)
    for row in 0..<core.count(terrains) {
        e:=core.entity_at(terrains,row)
        marker:=core.at(terrains,row)
        source:=terrain.terrain_source(terrain_data,marker.source)
        world,placed:=core.get(worlds,e)
        if source==nil || !placed || !terrain.source_valid(source.info) {continue}
        to_world:=mm.transform_matrix(world.transform)
        to_local,inverted:=mm.transform_inverse_matrix(world.transform)
        if !inverted {continue}
        low,high:=source_box(source)
        if !(low.x<=high.x) {continue}
        append(&state.views,Terrain_View{source=source,to_local=to_local,to_world=to_world,low=low,high=high})
        a,b:=box_corners(to_world,low,high)
        append(&state.now,Seen_Terrain{entity=e,source=marker.source,transform=world.transform,low=a,high=b})
    }
}

// Asks for a tile of the ground of a Foliage to be read again, once; fine
// wherever the sources are.
@(private)
ground_ask :: proc(state:^Foliage_Terrain,e:core.Entity,coord:[2]i32,fine:=false) {
    task:=Ground_Task{e,coord,fine}
    at,found:=slice.binary_search_by(state.queued[:],task,task_order)
    if found {state.queued[at].fine||=fine;return}
    inject_at(&state.queued,at,task)
    append(&state.queue,task)
}

@(private)
task_order :: proc(a,b:Ground_Task) -> slice.Ordering {
    switch {
    case a.entity!=b.entity: return a.entity<b.entity?.Less:.Greater
    case a.coord.x!=b.coord.x: return a.coord.x<b.coord.x?.Less:.Greater
    case a.coord.y!=b.coord.y: return a.coord.y<b.coord.y?.Less:.Greater
    }
    return .Equal
}

// Reads GROUND_TILES tiles of the queue, in jobs, each against the terrains
// whose box covers it, fine or coarse by where the sources are then, and
// writes them in the order they were asked.
@(private)
ground_read :: proc(state:^Foliage_Terrain,ground:^foliage.Foliage_Ground,data:core.Ref(foliage.Foliage_Data),foliages:core.Read(foliage.Foliage),worlds:core.Read(core.World_Transform),sources:^scene.Streaming_Sources,job_system:^jobs.Job_System) {
    if len(state.queue)==0 {return}
    // Temporary like the slices it holds: kept in the storage, the world would free them.
    work:=make([dynamic]Tile_Work,0,GROUND_TILES,context.temp_allocator)
    taken:=0
    for taken<len(state.queue) && len(work)<GROUND_TILES {
        task:=state.queue[taken]
        taken+=1
        if at,found:=slice.binary_search_by(state.queued[:],task,task_order);found {
            task.fine=state.queued[at].fine
            ordered_remove(&state.queued,at)
        }
        owner:=foliage.ground_owner(ground,task.entity)
        world,placed:=core.get(worlds,task.entity)
        f,shown:=core.get(foliages,task.entity)
        if owner==nil || !placed || !shown {continue}
        entry:=foliage.data_find(data.ptr,f.source)
        owner_world:=mm.transform_matrix(world.transform)
        owner_local,inverted:=mm.transform_inverse_matrix(world.transform)
        if !inverted || entry==nil {continue}
        near:=ground_near(sources,owner_world,&entry.source)
        was:=foliage.ground_tile_samples(owner,task.coord)
        coarse:=!task.fine && !tile_fine(&near,task.coord,was!=0 && was!=COARSE_SAMPLES)
        views:=make([dynamic]Terrain_View,context.temp_allocator)
        for view in state.views {
            a,b:=box_corners(owner_local*view.to_world,view.low,view.high)
            if covers_tile(a,b,task.coord) {append(&views,view)}
        }
        n:=coarse?COARSE_SAMPLES:int(owner.samples)
        append(&work,Tile_Work{task=task,views=views[:],owner_world=owner_world,owner_local=owner_local,samples=n,coarse=coarse,heights=make([]f32,n*n,context.temp_allocator),weights=make([][4]u8,n*n,context.temp_allocator)})
    }
    remove_range(&state.queue,0,taken)
    sample :: proc(work:^[dynamic]Tile_Work,first,last:int,worker:int) {
        for &w in work[first:last] {w.any=tile_sample(w.views,w.owner_world,w.owner_local,w.task.coord,w.samples,w.heights,w.weights,w.coarse)}
    }
    if job_system!=nil && jobs.worker_count(job_system)>1 && len(work)>1 {
        jobs.parallel_for(job_system,jobs.OWNER,len(work),1,sample,&work)
    } else {sample(&work,0,len(work),jobs.OWNER)}
    for &w in work {
        owner:=foliage.ground_owner(ground,w.task.entity)
        if owner==nil || !w.coarse && int(owner.samples)!=w.samples {continue}
        at:=foliage.ground_tile_find(owner,w.task.coord)
        if !w.any {
            if at>=0 {foliage.ground_tile_remove(owner,at)}
            continue
        }
        same:=at>=0 && int(foliage.ground_tile_samples(owner,w.task.coord))==w.samples
        heights,weights,tile:=foliage.ground_tile(owner,w.task.coord,u32(w.samples))
        if tile==nil {continue}
        if same && same_heights(heights,w.heights) && slice.equal(weights,w.weights) {continue}
        copy(heights,w.heights)
        copy(weights,w.weights)
        owner.revision+=1
        tile.revision=owner.revision
    }
}

@(private)
same_heights :: proc "contextless" (a,b:[]f32) -> bool {
    for value,i in a {
        other:=b[i]
        if value!=other && !(value-value!=0 && other-other!=0) {return false}
    }
    return true
}

// While the editor holds a stroke on a terrain, what it changed is not in
// Terrain_Data until it is confirmed: the tiles under it show no ground, so
// the generated foliage there is not shown over the old ground, as Unreal
// leaves its grass out while a stroke is held. When the stroke ends they are
// read again.
@(private)
ground_hide :: proc(state:^Foliage_Terrain,ground:^foliage.Foliage_Ground,foliages:core.Read(foliage.Foliage),terrains:core.Read(terrain.Terrain),worlds:core.Read(core.World_Transform),focus:terrain.Terrain_Focus) {
    if !focus.stroke {
        for task in state.hidden {ground_ask(state,task.entity,task.coord)}
        clear(&state.hidden)
        return
    }
    for row in 0..<core.count(terrains) {
        if core.at(terrains,row).source!=focus.source {continue}
        placed,known:=core.get(worlds,core.entity_at(terrains,row))
        if !known {continue}
        to_world:=mm.transform_matrix(placed.transform)
        low,high:=[3]f32{focus.low.x,-terrain.HEIGHT_LIMIT,focus.low.y},[3]f32{focus.high.x,terrain.HEIGHT_LIMIT,focus.high.y}
        for i in 0..<core.count(foliages) {
            e:=core.entity_at(foliages,i)
            owner:=foliage.ground_owner(ground,e)
            world,has_world:=core.get(worlds,e)
            if owner==nil || !has_world {continue}
            to_local,inverted:=mm.transform_inverse_matrix(world.transform)
            if !inverted {continue}
            a,b:=box_corners(to_local*to_world,low,high)
            for i:=0;i<len(owner.tiles);i+=1 {
                coord:=owner.tiles[i].coord
                if !covers_tile(a,b,coord) {continue}
                task:=Ground_Task{entity=e,coord=coord}
                if slice.contains(state.hidden[:],task) {continue}
                heights,weights,held:=foliage.ground_tile(owner,coord)
                if held==nil {continue}
                for &h in heights {h=foliage.NO_GROUND}
                for &w in weights {w={}}
                owner.revision+=1
                held.revision=owner.revision
                append(&state.hidden,task)
            }
        }
    }
}
