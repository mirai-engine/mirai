package pcg

import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:core"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

// pcg_ground keeps the cells each graph wants (those of its Volume near the
// streaming sources, within the reach of its layers, by scene.resident), and
// reads again the tiles over what the ground announces changed, over the
// excluding zones that came, went or moved, the cells a graph gains and those
// the editor asks for: GROUND_SAMPLES samples a frame (its ticks and itself
// together), in jobs that end within the call, those the editor asks for
// first and then the nearest the sources; the rest wait for the next frames.
// While some wait, a cell without a tile takes a coarse one of SAMPLES_MIN a
// side first, from GROUND_COARSE of them, so its points show and correct when
// its tile is read. A tile is whole within GROUND_REACH of a source (or the
// reach of its layers, if less) and where the editor asks; farther it is
// sparse: the samples around the points of the layers seen that far.

// Samples of ground read in a frame: a count, not a time, so what a frame
// reads does not depend on the load of the machine.
GROUND_SAMPLES :: 32768
GROUND_COARSE :: GROUND_SAMPLES/4 // of them kept for coarse tiles while tiles wait
GROUND_REACH :: f32(512)  // m from a source past which a tile is sparse
REACH_MAX :: f32(2048)    // m from a source a layer that is never culled places to
SAMPLES_MIN :: 9          // per side of a tile, whatever the spacing of the ground
SAMPLES_MAX :: 65
WANTED_MAX :: 16384       // cells of a graph at once: past them, the nearest
EXCLUSION_PIECE :: f32(1) // m between the samples of the curve of an excluding Spline
EXCLUSION_SAMPLES :: 512  // of the curve of an excluding Spline, at most
EXCLUSIONS_A_TILE :: 64   // tested at each square of a tile; past them, all of them are
#assert(GROUND_SAMPLES-GROUND_COARSE>=SAMPLES_MAX*SAMPLES_MAX)

// A tile of the ground of a graph to read again.
Pcg_Ground_Task :: struct {
    entity:core.Entity,
    coord:[2]i32,
    fine:bool, // asked for by the editor: fine wherever the sources are, and read first
    near:f32,  // how near the sources came to it when the queue was ordered
}

// Where an excluding zone was when the tiles under it were last asked for.
Zone_Seen :: struct {
    entity:core.Entity,
    box:mm.Aabb,
    stamp:u64,
}

// An excluding zone in the world: its Volume, or the width of its Spline.
Exclusion :: struct {
    entity:core.Entity,
    spline:bool,
    region:Pcg_Region,
    points:[]mm.Path_Point, // of a Spline, its curve in the world
    box:mm.Aabb,
    stamp:u64,
}

// How far from the sources a source places: its farthest cull distance,
// REACH_MAX for a layer never culled; 0 without layers. The Micro layers
// count: what scatters them on the GPU reads the same ground tiles.
source_reach :: proc "contextless" (s:^Pcg_Source) -> f32 {
    reach:=f32(0)
    for l in s.layers {reach=max(reach,l.cull_distance>0?min(l.cull_distance,REACH_MAX):REACH_MAX)}
    return reach
}

// How far from the sources its tiles are whole.
@(private)
fine_reach :: proc "contextless" (s:^Pcg_Source) -> f32 {return min(GROUND_REACH,source_reach(s))}

// The excluding zones now, into out, with points from the temporary
// allocator. One that says nowhere is a problem.
exclusions_gather :: proc(zones:^core.Table(Pcg_Zone,$A),at:volume.Where,out:^[dynamic]Exclusion,problems:^core.Problems) {
    clear(out)
    if zones==nil {return}
    for row in 0..<core.count(zones) {
        if !core.at(zones,row).exclude {continue}
        e:=core.entity_at(zones,row)
        x:=Exclusion{entity=e}
        spline_row:=at.splines!=nil?core.row_of(at.splines,e):-1
        switch {
        case at.volumes!=nil && core.has(at.volumes,e):
            ok:bool
            x.region.volume,x.region.pose,x.region.outline,ok=volume.placed(at,e)
            if !ok {continue}
            x.box=volume.bounds(x.region.volume,x.region.pose,x.region.outline)
        case spline_row>=0:
            world,placed:=core.get(at.worlds,e)
            if !placed {continue}
            x.spline=true
            buffer:=make([]mm.Path_Point,EXCLUSION_SAMPLES,context.temp_allocator)
            spline:=&at.splines.values[spline_row]
            n:=volume.spline_sample(spline,EXCLUSION_PIECE,buffer)
            reach,reached:=volume.spline_reach(spline,world.transform)
            if n<2 || !reached {continue}
            across:=max(abs(world.transform.scale.x),abs(world.transform.scale.z))
            for &p in buffer[:n] {p.position,p.width=mm.transform_point(world.transform,p.position),p.width*across}
            x.points,x.box=buffer[:n],reach
        case:
            core.report(problems,e,"pcg.zone","this excluding Pcg_Zone does not say where: give its entity a Volume or a Spline")
            continue
        }
        // Past every cell, not without end: a box without end has no centre.
        reach:=2*POSITION_MAX
        x.box.min=linalg.clamp(x.box.min,-reach,reach)
        x.box.max=linalg.clamp(x.box.max,-reach,reach)
        x.stamp=exclusion_stamp(&x)
        append(out,x)
    }
}

@(private)
exclusion_stamp :: proc(x:^Exclusion) -> u64 {
    Fixed :: struct {spline:bool,shape:volume.Volume,pose:mm.Transform}
    fixed:=Fixed{x.spline,x.region.volume,x.region.pose}
    h:=base.hash64(([^]byte)(&fixed)[:size_of(fixed)])
    h=base.hash64(([^]byte)(raw_data(x.region.outline))[:len(x.region.outline)*size_of(mm.Path_Point)],h)
    return base.hash64(([^]byte)(raw_data(x.points))[:len(x.points)*size_of(mm.Path_Point)],h)
}

// Whether an excluding zone holds a point of the world.
exclusion_holds :: proc "contextless" (x:^Exclusion,p:[3]f32) -> bool {
    if !mm.aabb_contains_point(x.box,p) {return false}
    if !x.spline {return volume.depth(x.region.volume,x.region.pose,p,x.region.outline)>=0}
    for i in 1..<len(x.points) {
        a,b:=x.points[i-1],x.points[i]
        ab,ap:=b.position.xz-a.position.xz,p.xz-a.position.xz
        t:=clamp(linalg.dot(ap,ab)/max(linalg.dot(ab,ab),1e-12),0,1)
        d:=ap-ab*t
        half:=0.5*(a.width+(b.width-a.width)*t)
        if d.x*d.x+d.y*d.y<=half*half {return true}
    }
    return false
}

// The boxes of the excluding zones that came, went or changed since seen,
// into changes, and seen made what they are now.
@(private)
exclusions_changed :: proc(now:[]Exclusion,seen:^[dynamic]Zone_Seen,changes:^[dynamic]mm.Aabb) {
    next:=make([dynamic]Zone_Seen,0,len(now),context.temp_allocator)
    for x in now {append(&next,Zone_Seen{x.entity,x.box,x.stamp})}
    for old in seen {
        found:=false
        for x in next {
            if x.entity!=old.entity {continue}
            found=true
            if x.stamp!=old.stamp || x.box!=old.box {append(changes,old.box,x.box)}
            break
        }
        if !found {append(changes,old.box)}
    }
    for x in next {
        found:=false
        for old in seen {if old.entity==x.entity {found=true;break}}
        if !found {append(changes,x.box)}
    }
    clear(seen)
    append(seen,..next[:])
}

// Marks the squares of a tile where points are kept out: those whose centre,
// on the ground of the tile, an excluding zone holds.
@(private)
tile_kept :: proc(exclusions:[]Exclusion,frame_world:mm.Mat4,coord:[2]i32,ground:Pcg_Ground_Cell,kept:[]u64) {
    for &w in kept {w=0}
    if len(exclusions)==0 {return}
    cell:=ground.cell_size
    corner:=cell_corner(cell,coord)
    column:=mm.aabb_transform({{corner.x,-POSITION_MAX,corner.z},{corner.x+cell,POSITION_MAX,corner.z+cell}},frame_world)
    near:[EXCLUSIONS_A_TILE]int
    count:=0
    for &x,i in exclusions {
        if !mm.aabb_overlaps(x.box,column) {continue}
        if count==len(near) {count=-1;break}
        near[count]=i
        count+=1
    }
    if count==0 {return}
    step:=cell/KEPT_SIDE
    for k in 0..<KEPT_SIDE*KEPT_SIDE {
        x,z:=(f32(k%KEPT_SIDE)+0.5)*step,(f32(k/KEPT_SIDE)+0.5)*step
        h,_,on_ground:=ground_at(ground,x,z)
        if !on_ground {continue}
        p:=mm.mat4_point(frame_world,corner+{x,h,z})
        held:=false
        if count<0 {
            for &other in exclusions {if exclusion_holds(&other,p) {held=true;break}}
        } else {
            for i in near[:count] {if exclusion_holds(&exclusions[i],p) {held=true;break}}
        }
        if held {kept[k>>6]|=1<<(uint(k)&63)}
    }
}

// Where the Volume of a graph bounds its cells, in their frame; unbounded:
// it does not. hash: of where it is.
graph_domain :: proc(at:volume.Where,e:core.Entity,frame_local:mm.Mat4) -> (box:mm.Aabb,bounded:bool,region:Pcg_Region,hash:u64) {
    v,pose,outline,ok:=volume.placed(at,e)
    // It rules nowhere: no cell, and no point.
    if !ok {return {min={1,1,1},max={0,0,0}},true,{volume=volume.box({0,0,0}),pose=mm.TRANSFORM_IDENTITY},1}
    region={v,pose,outline}
    Fixed :: struct {v:volume.Volume,pose:mm.Transform}
    fixed:=Fixed{v,pose}
    hash=base.hash64(([^]byte)(&fixed)[:size_of(fixed)])
    hash=base.hash64(([^]byte)(raw_data(outline))[:len(outline)*size_of(mm.Path_Point)],hash)
    if v.shape==.Unbounded || v.shape==.Plane {return {},false,region,hash}
    return mm.aabb_transform(volume.bounds(v,pose,outline),frame_local),true,region,hash
}

// The cells a graph wants, into owner.cells in their order: those of its
// domain resident by the sources, within the reach of its source, the
// nearest WANTED_MAX; without sources, every cell of a bounded domain.
@(private)
graph_wants :: proc(owner:^Pcg_Ground_Owner,s:^Pcg_Source,frame_world:mm.Mat4,box:mm.Aabb,bounded:bool,sources:^scene.Streaming_Sources) {
    cell:=s.info.cell_size
    was:=slice.clone(owner.cells[:],context.temp_allocator)
    clear(&owner.cells)
    reach:=source_reach(s)
    if reach<=0 {owner.cells_revision+=1;return}
    near:=scene.sources_near(sources,frame_world,reach)
    range_of :: proc "contextless" (cell:f32,low,high:[2]f32) -> (first,last:[2]i32) {
        for axis in 0..<2 {
            first[axis]=i32(clamp(math.floor(low[axis]/cell),f32(-COORD_MAX),f32(COORD_MAX)))
            last[axis]=i32(clamp(math.floor(high[axis]/cell),f32(-COORD_MAX),f32(COORD_MAX)))
        }
        return
    }
    add :: proc(owner:^Pcg_Ground_Owner,coord:[2]i32,near:f32) -> bool {
        if len(owner.cells)>=4*WANTED_MAX {return false}
        append(&owner.cells,Ground_Want{coord,near})
        return true
    }
    if near.count==0 {
        if bounded && box.min.x<=box.max.x {
            first,last:=range_of(cell,box.min.xz,box.max.xz)
            all: for z in first.y..=last.y {for x in first.x..=last.x {if !add(owner,{x,z},0) {break all}}}
        }
    } else {
        for point,i in near.points[:near.count] {
            r:=near.reaches[i]*scene.RESIDENT_KEEP
            low,high:=point.xz-r,point.xz+r
            if bounded {low,high=linalg.max(low,box.min.xz),linalg.min(high,box.max.xz)}
            if low.x>high.x || low.y>high.y {continue}
            first,last:=range_of(cell,low,high)
            all_near: for z in first.y..=last.y {
                for x in first.x..=last.x {
                    corner:=cell_corner(cell,{x,z})
                    n:=scene.box_near(&near,{corner.x,-POSITION_MAX,corner.z},{corner.x+cell,POSITION_MAX,corner.z+cell})
                    at:=coord_lower(was,{x,z})
                    held:=at<len(was) && was[at].coord==[2]i32{x,z}
                    if !scene.resident(n,held) {continue}
                    if !add(owner,{x,z},n) {break all_near}
                }
            }
        }
    }
    slice.sort_by(owner.cells[:],proc(a,b:Ground_Want) -> bool {return coord_before(a.coord,b.coord)})
    kept:=0
    for c,k in owner.cells {
        if k>0 && c.coord==owner.cells[kept-1].coord {continue}
        owner.cells[kept]=c
        kept+=1
    }
    base.truncate(&owner.cells,kept)
    if len(owner.cells)>WANTED_MAX {
        slice.sort_by(owner.cells[:],proc(a,b:Ground_Want) -> bool {return a.near<b.near || a.near==b.near && coord_before(a.coord,b.coord)})
        base.truncate(&owner.cells,WANTED_MAX)
        slice.sort_by(owner.cells[:],proc(a,b:Ground_Want) -> bool {return coord_before(a.coord,b.coord)})
    }
    if len(was)!=len(owner.cells) || !slice.equal(was,owner.cells[:]) {owner.cells_revision+=1}
}

@(step="fixed frame",loops="game editor",stage="simulate")
pcg_ground :: proc(
    ground:^Pcg_Ground,requests:^Pcg_Ground_Requests,data:core.Ref(Pcg_Data),graphs:^core.Table(Pcg_Graph,.Read),
    sources:core.Ref(scene.Streaming_Sources),queries:core.Ref(core.Ground_Queries),zones:^core.Table(Pcg_Zone,.Read),at:volume.Where,
    world:core.World_Ref,frame:core.Frame_Time,job_system:^jobs.Job_System,problems:^core.Problems,
) {
    asked:=core.take(&requests.cells)
    if data.ptr==nil {return}
    q:=core.ground_query(core.world_read(world),queries)
    exclusions:=make([dynamic]Exclusion,context.temp_allocator)
    changes:=make([dynamic]mm.Aabb,context.temp_allocator)
    if queries.ptr!=nil {append(&changes,..queries.changed.items[:])}
    zones_moved:=core.touched(zones,&ground.zone_seen[0]) | core.touched(at.volumes,&ground.zone_seen[1]) | core.touched(at.splines,&ground.zone_seen[2])
    if zones_moved {
        exclusions_gather(zones,at,&exclusions,problems)
        exclusions_changed(exclusions[:],&ground.zones,&changes)
    }
    defer {
        if !zones_moved && len(ground.queue)>0 {exclusions_gather(zones,at,&exclusions,problems)}
        ground_read(ground,&q,data.ptr,graphs,at,exclusions[:],sources.ptr,job_system,problems)
        // The frame call ends the frame: its ticks came before it.
        if frame.phase!=.Fixed {ground.spent=0}
    }
    data_now:=[2]u64{data.made,data.stats.loads}
    moved:=core.touched(graphs,&ground.seen[0]) | core.touched(at.worlds,&ground.seen[1]) | core.touched(at.volumes,&ground.seen[2])
    streamed:=sources.ptr!=nil?sources.ptr.revision:0
    sources_moved:=streamed!=ground.streamed
    ground.streamed=streamed
    if len(changes)==0 && data_now==ground.data && !moved && !sources_moved && len(asked)==0 && core.count(graphs)==len(ground.owners) {return}
    ground.data=data_now
    for i:=len(ground.owners)-1;i>=0;i-=1 {
        if core.has(graphs,ground.owners[i].entity) {continue}
        ground_owner_destroy(&ground.owners[i])
        unordered_remove(&ground.owners,i)
    }
    for row in 0..<core.count(graphs) {
        e:=core.entity_at(graphs,row)
        g:=core.at(graphs,row)
        placed,has_world:=core.get(at.worlds,e)
        entry:=data_find(data.ptr,g.source)
        if !has_world || entry==nil || len(entry.source.compiled)!=len(entry.source.layers) {continue}
        frame_pose:=graph_frame(g,placed.transform)
        frame_world:=mm.transform_matrix(frame_pose)
        frame_local,inverted:=mm.transform_inverse_matrix(frame_pose)
        if !inverted {continue}
        owner:=ground_owner(ground,e)
        fresh:=owner==nil
        if fresh {
            if _,error:=append(&ground.owners,Pcg_Ground_Owner{entity=e});error!=nil {
                // The next call looks at every graph again.
                ground.data,ground.seen[0]={},{}
                core.report(problems,e,"pcg.memory","out of memory for the ground under this Pcg_Graph; it is looked at again in the next frame: free memory")
                continue
            }
            owner=&ground.owners[len(ground.owners)-1]
        }
        s:=&entry.source
        cell:=s.info.cell_size
        loaded:=owner.epoch!=entry.epoch || owner.loads!=entry.loads
        // As many samples as the ground has under a cell, in the frame.
        samples:=u32(SAMPLES_MIN)
        if q.probe!=nil {
            step:=q.spacing/max(abs(frame_pose.scale.x),abs(frame_pose.scale.z),1e-6) if q.spacing>0 else cell
            samples=u32(clamp(int(math.ceil(cell/max(step,1e-3)))+1,SAMPLES_MIN,SAMPLES_MAX))
        }
        all:=owner.frame!=frame_pose || owner.samples!=samples || owner.cell_size!=cell
        if all {ground_owner_reset(owner,samples,cell)}
        box,bounded,_,domain:=graph_domain(at,e,frame_local)
        if fresh || loaded || all || sources_moved || domain!=owner.domain {graph_wants(owner,s,frame_world,box,bounded,sources.ptr)}
        owner.frame,owner.epoch,owner.loads,owner.domain=frame_pose,entry.epoch,entry.loads,domain
        // The tiles of cells it no longer wants go.
        for i:=len(owner.tiles)-1;i>=0;i-=1 {
            if _,wanted:=ground_wants(owner,owner.tiles[i].coord);!wanted {ground_tile_remove(owner,i)}
        }
        for want in owner.cells {
            if ground_tile_find(owner,want.coord)<0 {ground_ask(ground,e,want.coord)}
        }
        // The tiles under a change, of those it has.
        if !all && len(changes)>0 && len(owner.tiles)>0 {
            for tile in owner.tiles {
                corner:=cell_corner(cell,tile.coord)
                column:=mm.aabb_transform({{corner.x,-POSITION_MAX,corner.z},{corner.x+cell,POSITION_MAX,corner.z+cell}},frame_world)
                for change in changes {
                    if mm.aabb_overlaps(change,column) {ground_ask(ground,e,tile.coord);break}
                }
            }
        }
        // A sparse tile holds the samples around the points of its source: another source asks them again.
        if loaded && !all {
            for tile in owner.tiles {if tile.pool==SPARSE_POOL {ground_ask(ground,e,tile.coord)}}
        }
        for request in asked {
            if request.entity!=e {continue}
            if _,wanted:=ground_wants(owner,request.coord);!wanted {continue}
            if ground_tile_samples(owner,request.coord)!=owner.samples || ground_tile_sparse(owner,request.coord) {ground_ask(ground,e,request.coord,true)}
        }
        // A tile goes from whole to sparse, or back, as the sources move.
        if sources_moved || loaded {
            near:=scene.sources_near(sources.ptr,frame_world,fine_reach(s))
            for tile in owner.tiles {
                whole:=tile.pool!=SPARSE_POOL
                if tile_fine(&near,cell,tile.coord,whole)!=whole {ground_ask(ground,e,tile.coord)}
            }
        }
    }
    if ground.unordered || sources_moved {queue_order(ground,data.ptr,graphs,at.worlds,sources.ptr)}
}

// Whether the tile of a cell is whole: near a source, by its residency, or
// everywhere without sources.
@(private)
tile_fine :: proc "contextless" (near:^scene.Sources_Near,cell:f32,coord:[2]i32,was:bool) -> bool {
    if near.count==0 {return true}
    corner:=cell_corner(cell,coord)
    return scene.resident(scene.box_near(near,{corner.x,-POSITION_MAX,corner.z},{corner.x+cell,POSITION_MAX,corner.z+cell}),was)
}

@(private)
ground_ask :: proc(ground:^Pcg_Ground,e:core.Entity,coord:[2]i32,fine:=false) {
    append(&ground.queue,Pcg_Ground_Task{entity=e,coord=coord,fine=fine})
    ground.unordered=true
}

@(private)
task_before :: proc(a,b:Pcg_Ground_Task) -> bool {
    if a.entity!=b.entity {return a.entity<b.entity}
    return coord_before(a.coord,b.coord)
}

// Orders the queue of tiles: each tile once (fine if one ask was), none of a
// graph that is gone or no longer wants it, and the next to read at its end:
// those the editor asks for, then the nearest a source.
@(private)
queue_order :: proc(ground:^Pcg_Ground,data:^Pcg_Data,graphs:^core.Table(Pcg_Graph,$A),worlds:^core.Table(core.World_Transform,$B),sources:^scene.Streaming_Sources) {
    ground.unordered=false
    if len(ground.queue)==0 {return}
    slice.sort_by(ground.queue[:],task_before)
    kept:=0
    for task in ground.queue {
        if kept>0 && ground.queue[kept-1].entity==task.entity && ground.queue[kept-1].coord==task.coord {
            ground.queue[kept-1].fine||=task.fine
            continue
        }
        owner:=ground_owner(ground,task.entity)
        if owner==nil {continue}
        near,wanted:=ground_wants(owner,task.coord)
        if !wanted {continue}
        next:=task
        next.near=near
        ground.queue[kept]=next
        kept+=1
    }
    base.truncate(&ground.queue,kept)
    slice.sort_by(ground.queue[:],proc(a,b:Pcg_Ground_Task) -> bool {
        if a.fine!=b.fine {return b.fine}
        if a.near!=b.near {return a.near>b.near}
        return task_before(b,a)
    })
}

// The Ground_Layers a tile meets, which its samples index while it is read.
@(private) TILE_LAYERS :: 64
@(private)
Tile_Layers :: struct {
    items:[TILE_LAYERS]Ground_Layers,
    count:int,
    over:bool, // more than TILE_LAYERS: the samples of those have no layers
}

// Whether any layer of s filters placement by ground material layers.
@(private)
source_uses_ground_layers :: proc "contextless" (s:^Pcg_Source) -> bool {
    for l in s.layers {if l.ground_rule.enabled && l.ground_rule.layers!={} {return true}}
    return false
}

// Canonicalizes a ground sample's (weights, layers) so order of dominance does not multiply
// distinct Ground_Layers keys across a multi-layer terrain: zero-weight slots are dropped and
// active slots are ordered by material Asset_Id.
@(private)
ground_layers_canonical :: proc "contextless" (weights:[4]u8,layers:Ground_Layers) -> (out_w:[4]u8,out_l:Ground_Layers) {
    n:=0
    for i in 0..<4 {
        w,m:=weights[i],layers[i]
        if w==0 || m=={} {continue}
        out_w[n],out_l[n]=w,m
        n+=1
    }
    for i in 1..<n {
        w,m:=out_w[i],out_l[i]
        j:=i
        for j>0 && (m[0]<out_l[j-1][0] || m[0]==out_l[j-1][0] && m[1]<out_l[j-1][1]) {
            out_w[j],out_l[j]=out_w[j-1],out_l[j-1]
            j-=1
        }
        out_w[j],out_l[j]=w,m
    }
    return
}

// A tile read in a job.
@(private)
Tile_Work :: struct {
    task:Pcg_Ground_Task,
    frame_world,frame_local:mm.Mat4,
    cell_size:f32,
    samples:int,
    sparse:bool,
    coarse:bool, // SAMPLES_MIN a side, for a cell without a tile, whose task stays queued
    uses_layers:bool,
    keys:[]u16,
    heights:[]f32,
    weights:[]Layer_Weights,
    layers:Tile_Layers,
    kept:[]u64,
    any:bool,
}

// The heights of a tile: the highest ground under each sample along the down
// of the frame, in it, and the weights of its layers; without a probe, the
// plane y = 0 of the frame. With keys, only the samples they name. False
// when no ground covers any of it.
@(private)
tile_sample :: proc(q:^core.Ground_Query,w:^Tile_Work) -> (any:bool) {
    w.layers={}
    down:=-(w.frame_world*[4]f32{0,1,0,0}).xyz
    step:=w.cell_size/f32(w.samples-1)
    corner:=cell_corner(w.cell_size,w.task.coord)
    count:=len(w.keys)>0?len(w.keys):w.samples*w.samples
    for i in 0..<count {
        k:=len(w.keys)>0?int(w.keys[i]):i
        w.heights[i],w.weights[i]=NO_GROUND,{}
        if q.probe==nil {
            w.heights[i]=0
            any=true
            continue
        }
        hit,found:=q.probe(q.user,mm.mat4_point(w.frame_world,corner+{f32(k%w.samples)*step,0,f32(k/w.samples)*step}),down)
        any||=found!=.None
        if found!=.Ground {continue}
        w.heights[i]=mm.mat4_point(w.frame_local,hit.point).y
        if hit.weights=={} {continue}
        weights,layers:=ground_layers_canonical(hit.weights,hit.layers)
        if weights=={} {continue}
        at:=0
        for at<w.layers.count && w.layers.items[at]!=layers {at+=1}
        if at==TILE_LAYERS {w.layers.over=true;continue}
        if at==w.layers.count {w.layers.items[at]=layers;w.layers.count+=1}
        w.weights[i]={weights,u8(at)}
    }
    return
}

// The samples of a sparse tile, in order: the four around each point of the
// layers seen farther than reach (cull distance 0 or beyond it), and around
// those of all the layers with a radius in the margin when one is, and
// around the centre of the cell, which says whether it has ground at all.
@(private)
sparse_keys :: proc(s:^Pcg_Source,seed:u32,coord:[2]i32,samples:int,reach:f32,keys:^[dynamic]u16) -> bool {
    clear(keys)
    if samples<2 || samples*samples>int(max(u16))+1 {return false}
    cell:=s.info.cell_size
    marks:=make([]bool,samples*samples,context.temp_allocator)
    mark :: proc "contextless" (marks:[]bool,cell:f32,samples:int,at:[2]f32) {
        corners,_,_:=ground_around(cell,samples,at.x,at.y)
        for k in corners {marks[k]=true}
    }
    seen :: proc "contextless" (l:^Pcg_Layer,reach:f32) -> bool {return l.cull_distance<=0 || l.cull_distance>reach}
    mark(marks,cell,samples,{cell*0.5,cell*0.5})
    share:=generated_share(s)
    margin:=f32(0)
    spaced:=false
    for u in s.units {
        margin=max(margin,2*u.reach)
        for m in s.members[u.first:][:u.count] {spaced||=u.reach>0 && seen(&s.layers[m],reach)}
    }
    points:=make([dynamic]Point,context.temp_allocator)
    for u in s.units {
        far:=false
        for m in s.members[u.first:][:u.count] {far||=seen(&s.layers[m],reach)}
        for m in s.members[u.first:][:u.count] {
            // The children of a layer seen far stand around its points.
            for l in s.layers {if l.kind==.Cascade && l.parent_layer==s.layers[m].id && seen(&s.layers[m],reach) {far=true}}
        }
        if spaced && u.reach>0 {
            for k in 0..<9 {
                d:=[2]i32{i32(k%3)-1,i32(k/3)-1}
                clear(&points)
                if !unit_scatter(s,seed,coord,d,u,share,&points) {return false}
                for p in points {
                    if p.at.x< -margin || p.at.y< -margin || p.at.x>cell+margin || p.at.y>cell+margin {continue}
                    mark(marks,cell,samples,p.at)
                }
            }
            continue
        }
        if !far {continue}
        clear(&points)
        if !unit_scatter(s,seed,coord,{0,0},u,share,&points) {return false}
        for p in points {mark(marks,cell,samples,p.at)}
    }
    for m,k in marks {
        if !m {continue}
        if _,error:=append(keys,u16(k));error!=nil {return false}
    }
    return true
}

// Reads the tiles at the end of the queue, in jobs, whole or sparse by where
// the sources are then, as many as the samples left in the frame give room
// for while keeping GROUND_COARSE, and writes them in that order. While some
// wait, the cells of those without a tile take a coarse one, nearest first.
@(private)
ground_read :: proc(ground:^Pcg_Ground,q:^core.Ground_Query,data:^Pcg_Data,graphs:^core.Table(Pcg_Graph,$A),at:volume.Where,exclusions:[]Exclusion,sources:^scene.Streaming_Sources,job_system:^jobs.Job_System,problems:^core.Problems) {
    left:=GROUND_SAMPLES-ground.spent
    if len(ground.queue)==0 || left<=0 {return}
    Reading :: struct {q:^core.Ground_Query,exclusions:[]Exclusion,work:[dynamic]Tile_Work}
    // Temporary like the slices it holds: kept in the storage, the world would free them.
    reading:=Reading{q,exclusions,make([dynamic]Tile_Work,context.temp_allocator)}
    keys:=make([dynamic]u16,context.temp_allocator)
    Owned :: struct {owner:^Pcg_Ground_Owner,entry:^Pcg_Data_Entry,graph:Pcg_Graph,frame_world,frame_local:mm.Mat4,ok:bool}
    task_owner :: proc(ground:^Pcg_Ground,data:^Pcg_Data,graphs:^core.Table(Pcg_Graph,$A),at:volume.Where,task:Pcg_Ground_Task) -> (o:Owned) {
        o.owner=ground_owner(ground,task.entity)
        world,placed:=core.get(at.worlds,task.entity)
        graph,shown:=core.get(graphs,task.entity)
        if o.owner==nil || !placed || !shown {return}
        o.graph=graph
        o.entry=data_find(data,graph.source)
        frame:=graph_frame(graph,world.transform)
        o.frame_world=mm.transform_matrix(frame)
        inverted:bool
        o.frame_local,inverted=mm.transform_inverse_matrix(frame)
        o.ok=inverted && o.entry!=nil && len(o.entry.source.compiled)==len(o.entry.source.layers)
        return
    }
    used:=0
    for len(ground.queue)>0 {
        task:=ground.queue[len(ground.queue)-1]
        o:=task_owner(ground,data,graphs,at,task)
        if !o.ok {pop(&ground.queue);continue}
        s:=&o.entry.source
        near:=scene.sources_near(sources,o.frame_world,fine_reach(s))
        held:=ground_tile_find(o.owner,task.coord)
        sparse:=!task.fine && !tile_fine(&near,o.owner.cell_size,task.coord,held>=0 && o.owner.tiles[held].pool!=SPARSE_POOL)
        n:=int(o.owner.samples)
        w:=Tile_Work{task=task,frame_world=o.frame_world,frame_local=o.frame_local,cell_size=o.owner.cell_size,samples=n,sparse=sparse,uses_layers=source_uses_ground_layers(s)}
        count:=n*n
        if sparse {
            if !sparse_keys(s,graph_seed(s.info.seed,o.graph.seed),task.coord,n,fine_reach(s),&keys) {
                pop(&ground.queue)
                core.report(problems,task.entity,"pcg.memory","out of memory for the ground under this Pcg_Graph far away; it is read again when it changes: free memory")
                continue
            }
            count=len(keys)
        }
        if used+count>left-GROUND_COARSE {break}
        pop(&ground.queue)
        if sparse {w.keys=slice.clone(keys[:],context.temp_allocator)}
        w.heights,w.weights=make([]f32,count,context.temp_allocator),make([]Layer_Weights,count,context.temp_allocator)
        w.kept=make([]u64,KEPT_WORDS,context.temp_allocator)
        append(&reading.work,w)
        used+=count
    }
    for i:=len(ground.queue)-1;i>=0 && used+SAMPLES_MIN*SAMPLES_MIN<=left;i-=1 {
        task:=ground.queue[i]
        o:=task_owner(ground,data,graphs,at,task)
        if !o.ok || task.fine || o.owner.samples<=SAMPLES_MIN || ground_tile_find(o.owner,task.coord)>=0 {continue}
        count:=SAMPLES_MIN*SAMPLES_MIN
        w:=Tile_Work{task=task,frame_world=o.frame_world,frame_local=o.frame_local,cell_size=o.owner.cell_size,samples=SAMPLES_MIN,coarse=true,uses_layers=source_uses_ground_layers(&o.entry.source)}
        w.heights,w.weights=make([]f32,count,context.temp_allocator),make([]Layer_Weights,count,context.temp_allocator)
        w.kept=make([]u64,KEPT_WORDS,context.temp_allocator)
        append(&reading.work,w)
        used+=count
    }
    ground.spent+=used
    sample :: proc(reading:^Reading,first,last:int,worker:int) {
        for &w in reading.work[first:last] {
            w.any=tile_sample(reading.q,&w)
            if w.any {tile_kept(reading.exclusions,w.frame_world,w.task.coord,{cell_size=w.cell_size,samples=w.samples,heights=w.heights,keys=w.keys},w.kept)}
        }
    }
    if job_system!=nil && jobs.worker_count(job_system)>1 && len(reading.work)>1 {
        jobs.parallel_for(job_system,jobs.OWNER,len(reading.work),1,sample,&reading)
    } else {sample(&reading,0,len(reading.work),jobs.OWNER)}
    for &w in reading.work {
        owner:=ground_owner(ground,w.task.entity)
        if owner==nil || !w.coarse && int(owner.samples)!=w.samples || owner.cell_size!=w.cell_size {continue}
        if _,wanted:=ground_wants(owner,w.task.coord);!wanted {continue}
        at:=ground_tile_find(owner,w.task.coord)
        // A coarse tile stands in for one not read yet, and says nothing where it finds no ground.
        if w.coarse && (at>=0 || !w.any) {continue}
        if !w.any {
            if at>=0 {ground_tile_remove(owner,at)}
            continue
        }
        index:[TILE_LAYERS]u8
        known:[TILE_LAYERS]bool
        for layers,i in w.layers.items[:w.layers.count] {index[i],known[i]=ground_layers_index(owner,layers)}
        for &sample in w.weights {
            if sample.weights=={} {continue}
            if !known[sample.layers] {sample={};continue}
            sample.layers=index[sample.layers]
        }
        if w.uses_layers && (w.layers.over || slice.contains(known[:w.layers.count],false)) {
            core.report(problems,w.task.entity,"pcg.layers","the ground under cell %v of this Pcg_Graph has more terrains with other layers than it keeps apart (%d in a cell, GROUND_LAYERS_MAX in all), so a ground rule takes none of the ground of some of them: give the terrains under it the same layers, or fewer terrains",w.task.coord,TILE_LAYERS)
        }
        if w.sparse {
            ground_sparse_write(owner,w.task.coord,w.keys,w.heights,w.weights,w.kept)
            continue
        }
        same:=at>=0 && owner.tiles[at].pool!=SPARSE_POOL && int(ground_tile_samples(owner,w.task.coord))==w.samples
        heights,weights,kept,tile:=ground_tile(owner,w.task.coord,u32(w.samples))
        if tile==nil {
            core.report(problems,w.task.entity,"pcg.memory","out of memory for the ground under cell %v of this Pcg_Graph; it is read again when it changes: free memory",w.task.coord)
            continue
        }
        if same && same_heights(heights,w.heights) && slice.equal(weights,w.weights) && slice.equal(kept,w.kept) {continue}
        copy(heights,w.heights)
        copy(weights,w.weights)
        copy(kept,w.kept)
        owner.revision+=1
        tile.revision=owner.revision
    }
}
