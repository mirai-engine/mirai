package foliage

import "core:math"
import "core:slice"
import "mirai:core"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import physics "plugins:physics/runtime"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

// foliage_ground reads again the tiles over what the ground announces changed,
// the cells a Foliage gains and those the editor asks for, GROUND_TILES a call
// in jobs, those the editor asks for first and then the nearest the streaming
// sources, with where foliage is kept out of them. A keep-out that comes,
// goes or changes is a change of the ground under its old and new boxes. A
// tile is whole near the sources, within the reach of the meshes of its
// types, and where the editor asks; farther it is sparse: the samples of the
// same grid around the instances of the types seen that far, so that they
// stand and pass their rules as near.

GROUND_TILES :: 24 // tiles of ground read in a call (the step runs in the frame and in each tick)
GROUND_REACH :: f32(512) // m from a source past which a tile is sparse, for the meshes of every type
SAMPLES_MIN :: 9 // per side of a tile, whatever the spacing of the ground
SAMPLES_MAX :: 65

// A tile of the ground of a Foliage to read again.
Ground_Task :: struct {
    entity:core.Entity,
    coord:[2]i32,
    fine:bool, // asked for by the editor: fine wherever the sources are, and read first
    near:f32,  // how near the sources came to it when the queue was ordered, in reaches of its fine tiles
}

// A tile read in a job.
@(private)
Tile_Work :: struct {
    task:Ground_Task,
    owner_world,owner_local:mm.Mat4,
    samples:int,
    sparse:bool,
    keys:[]u16,     // of a sparse tile: the samples it reads
    generates:bool, // its cell: one without ground there is a problem
    heights:[]f32,
    weights:[]Layer_Weights, // their layers index those of the tile
    layers:Tile_Layers,
    kept:[]u64,
    any:bool,
}

// The Ground_Layers a tile meets, which its samples index while it is read.
TILE_LAYERS :: 8
Tile_Layers :: struct {
    items:[TILE_LAYERS]Ground_Layers,
    count:int,
    over:bool, // more than TILE_LAYERS: the samples of those have no layers
}

@(step="fixed frame",loops="game editor",stage="simulate")
foliage_ground :: proc(
    ground:^Foliage_Ground,requests:^Foliage_Ground_Requests,data:core.Ref(Foliage_Data),foliages:^core.Table(Foliage,.Read),
    worlds:^core.Table(core.World_Transform,.Read),sources:core.Ref(scene.Streaming_Sources),queries:core.Ref(core.Ground_Queries),
    keeps:^core.Table(Foliage_Keep_Out,.Read),volumes:^core.Table(volume.Volume,.Read),splines:^core.Table(volume.Spline,.Read),colliders:^core.Table(physics.Collider,.Read),
    world:core.World_Ref,job_system:^jobs.Job_System,problems:^core.Problems,
) {
    asked:=core.take(&requests.cells)
    q:=core.ground_query(world,queries)
    if q.probe==nil || data.ptr==nil {return}
    foliage_now:=[2]u64{data.made,data.stats.loads}
    moved:=core.touched(foliages,&ground.seen[0]) | core.touched(worlds,&ground.seen[1])
    regions:=make([dynamic]Keep_Out,context.temp_allocator)
    changes:=make([dynamic]mm.Aabb,context.temp_allocator)
    append(&changes,..queries.changed.items[:])
    kept_moved:=core.touched(keeps,&ground.keep_seen[0]) | core.touched(volumes,&ground.keep_seen[1]) | core.touched(splines,&ground.keep_seen[2]) | core.touched(colliders,&ground.keep_seen[3])
    at:=volume.Where{volumes=volumes,worlds=worlds,splines=splines}
    gathered:=kept_moved || moved
    if gathered {
        keep_outs_gather(keeps,at,colliders,&regions,problems)
        keep_outs_changed(regions[:],&ground.keep_outs,&changes)
    }
    defer {
        if !gathered && len(ground.queue)>0 {keep_outs_gather(keeps,at,colliders,&regions,problems)}
        ground_read(ground,&q,data,foliages,worlds,sources.ptr,regions[:],job_system,problems)
    }
    streamed:=sources.ptr!=nil?sources.ptr.revision:0
    sources_moved:=streamed!=ground.streamed
    ground.streamed=streamed
    if len(changes)==0 && foliage_now==ground.foliage && !moved && !sources_moved && len(asked)==0 && core.count(foliages)==len(ground.owners) {return}
    ground.foliage=foliage_now
    for i:=len(ground.owners)-1;i>=0;i-=1 {
        if core.has(foliages,ground.owners[i].entity) {continue}
        ground_owner_destroy(&ground.owners[i])
        unordered_remove(&ground.owners,i)
    }
    for row in 0..<core.count(foliages) {
        e:=core.entity_at(foliages,row)
        world,placed:=core.get(worlds,e)
        entry:=data_find(data.ptr,core.at(foliages,row).source)
        if !placed || entry==nil {continue}
        owner_world:=mm.transform_matrix(world.transform)
        owner_local,inverted:=mm.transform_inverse_matrix(world.transform)
        if !inverted {continue}
        owner:=ground_owner(ground,e)
        fresh:=owner==nil
        if fresh {
            if _,error:=append(&ground.owners,Ground_Owner{entity=e});error!=nil {
                // The next call looks at every Foliage again.
                ground.foliage,ground.seen[0]={},{}
                core.report(problems,e,"foliage.memory","out of memory for the ground under this Foliage; it is looked at again in the next frame: free memory")
                continue
            }
            owner=&ground.owners[len(ground.owners)-1]
        }
        cells:=owner.epoch!=entry.epoch || owner.loads!=entry.loads
        asked_here:=false
        for request in asked {asked_here||=request.entity==e}
        if !fresh && !cells && !asked_here && !sources_moved && len(changes)==0 && owner.transform==world.transform {continue}
        // As many samples as the ground has under a cell, in the space of this Foliage.
        step:=q.spacing/max(abs(world.transform.scale.x),abs(world.transform.scale.z),1e-6) if q.spacing>0 else CELL_SIZE
        samples:=u32(clamp(int(math.ceil(CELL_SIZE/max(step,1e-3)))+1,SAMPLES_MIN,SAMPLES_MAX))
        all:=owner.transform!=world.transform || owner.samples!=samples
        if owner.samples!=samples {ground_owner_reset(owner,samples)}
        owner.transform,owner.epoch,owner.loads=world.transform,entry.epoch,entry.loads
        // The tiles and cells the changes cover, of the ones this Foliage has.
        touched:=make(map[[2]i32]struct{},context.temp_allocator)
        if !all && len(changes)>0 {
            lo,hi:=[2]i32{max(i32),max(i32)},[2]i32{min(i32),min(i32)}
            for tile in owner.tiles {lo,hi={min(lo.x,tile.coord.x),min(lo.y,tile.coord.y)},{max(hi.x,tile.coord.x),max(hi.y,tile.coord.y)}}
            for &cell in entry.source.cells {lo,hi={min(lo.x,cell.coord.x),min(lo.y,cell.coord.y)},{max(hi.x,cell.coord.x),max(hi.y,cell.coord.y)}}
            c:=CELL_SIZE
            near:=mm.aabb_transform({{f32(lo.x)*c,-POSITION_MAX,f32(lo.y)*c},{f32(hi.x+1)*c,POSITION_MAX,f32(hi.y+1)*c}},owner_world)
            for change in changes {
                if lo.x>hi.x || !mm.aabb_overlaps(change,near) {continue}
                box:=mm.aabb_transform(change,owner_local)
                first:=[2]i32{i32(clamp(math.floor(box.min.x/c)-1,f32(lo.x),f32(hi.x)+1)),i32(clamp(math.floor(box.min.z/c)-1,f32(lo.y),f32(hi.y)+1))}
                last:=[2]i32{i32(clamp(math.floor(box.max.x/c)+1,f32(lo.x)-1,f32(hi.x))),i32(clamp(math.floor(box.max.z/c)+1,f32(lo.y)-1,f32(hi.y)))}
                for z in first.y..=last.y {for x in first.x..=last.x {if covers_tile(box,{x,z}) {touched[{x,z}]={}}}}
            }
        }
        if all {
            for tile in owner.tiles {ground_ask(ground,e,tile.coord)}
        } else if cells {
            // A sparse tile holds the samples around the instances of its cell: another source asks them again.
            for tile in owner.tiles {if tile.pool==SPARSE_POOL {ground_ask(ground,e,tile.coord)}}
        }
        // A change also covers cells without a tile: ground came, moved or grew, or its pages came.
        if cells || all {
            for &cell in entry.source.cells {if ground_tile_find(owner,cell.coord)<0 {ground_ask(ground,e,cell.coord)}}
        } else {
            for coord in touched {
                if ground_tile_find(owner,coord)>=0 || source_cell(&entry.source,coord)!=nil {ground_ask(ground,e,coord)}
            }
        }
        // The editor asks for fine ground under its brush.
        for request in asked {
            if request.entity==e && (ground_tile_samples(owner,request.coord)!=owner.samples || ground_tile_sparse(owner,request.coord)) {ground_ask(ground,e,request.coord,true)}
        }
        // A tile goes from whole to sparse, or back, as the sources move: only
        // the whole ones and the sparse ones near a source can.
        if sources_moved || cells || all {
            near:=ground_near(sources.ptr,owner_world,&entry.source)
            flip :: proc(ground:^Foliage_Ground,owner:^Ground_Owner,near:^scene.Sources_Near,e:core.Entity,coord:[2]i32) {
                whole:=!ground_tile_sparse(owner,coord)
                if tile_fine(near,coord,whole)!=whole {ground_ask(ground,e,coord)}
            }
            if cells || all || near.count==0 {
                for tile in owner.tiles {flip(ground,owner,&near,e,tile.coord)}
            } else {
                for pool in owner.pools {
                    for coord in pool.coords {flip(ground,owner,&near,e,coord)}
                }
                close:=make([dynamic]u32,context.temp_allocator)
                coords_near(owner.tiles[:],&near,&close)
                for at in close {
                    if owner.tiles[at].pool==SPARSE_POOL {flip(ground,owner,&near,e,owner.tiles[at].coord)}
                }
            }
        }
    }
    if ground.unordered || sources_moved {queue_order(ground,data.ptr,foliages,worlds,sources.ptr)}
}

// Whether a box of the space of an owner, in x and z, covers some of a tile.
@(private)
covers_tile :: proc "contextless" (box:mm.Aabb,coord:[2]i32) -> bool {
    corner:=cell_corner(coord)
    return box.min.x<=corner.x+CELL_SIZE && box.max.x>=corner.x && box.min.z<=corner.z+CELL_SIZE && box.max.z>=corner.z
}

// How far from the sources the tiles of a source are whole: as far as the
// meshes of its types are drawn (a type never culled, or none, as far as
// GROUND_REACH), up to it. Past it only the types seen farther than that show.
@(private)
ground_reach :: proc "contextless" (s:^Source) -> f32 {
    reach:=len(s.types)==0?GROUND_REACH:0
    for t in s.types {
        _,cull:=mesh_distances(t,type_far(t))
        reach=max(reach,cull>0?min(cull,GROUND_REACH):GROUND_REACH)
    }
    return reach
}

/// The samples of the grid of samples a side that a sparse tile of a cell
// keeps, in order: the four around each point that may show there, and
// those under the centre of its square of keep-out (kept_out), and those
// around the centre of the cell, which say whether it has ground at all.
// The points are the instances of the types seen farther than reach that
// stand on the ground (generated, or grounded), and with one of them with a
// radius, every point of the types with a radius within the margin around
// the cell, as spaced_stand reads them; so a sparse tile tells where an
// instance seen that far stands, and whether it does, as the whole one.
sparse_keys :: proc(s:^Source,cell:^Cell,coord:[2]i32,samples:int,reach:f32,keys:^[dynamic]u16) -> bool {
    clear(keys)
    if samples<2 || samples*samples>int(max(u16))+1 {return false}
    marks:=make([]bool,samples*samples,context.temp_allocator)
    mark :: proc "contextless" (marks:[]bool,samples:int,at:[2]f32) {
        corners,_,_:=ground_around(samples,at.x,at.y)
        for k in corners {marks[k]=true}
        step:=CELL_SIZE/KEEP_OUT_SIDE
        square:=[2]f32{f32(clamp(int(at.x/step),0,KEEP_OUT_SIDE-1)),f32(clamp(int(at.y/step),0,KEEP_OUT_SIDE-1))}
        corners,_,_=ground_around(samples,(square.x+0.5)*step,(square.y+0.5)*step)
        for k in corners {marks[k]=true}
    }
    seen :: proc "contextless" (t:^Foliage_Type,reach:f32) -> bool {return t!=nil && (t.cull_distance<=0 || t.cull_distance>reach)}
    mark(marks,samples,{CELL_SIZE*0.5,CELL_SIZE*0.5})
    if cell!=nil {
        for b in cell.manual {
            if t,_:=source_type(s,b.type);b.flags&INSTANCE_GROUNDED!=0 && seen(t,reach) {mark(marks,samples,b.position.xz)}
        }
        for o in cell.overrides {
            if t,_:=source_type(s,o.kind==.Moved?o.type:o.instance.type);o.kind!=.Deleted && o.instance.flags&INSTANCE_GROUNDED!=0 && seen(t,reach) {mark(marks,samples,o.instance.position.xz)}
        }
        if cell.generate {
            share:=generated_share(s)
            spaced:=false
            widest:f32
            for &t in s.types {
                if t.radius<=0 {continue}
                spaced||=seen(&t,reach)
                widest=max(widest,t.radius*t.scale[1])
            }
            margin:=2*widest
            points:=make([dynamic]Generated,context.temp_allocator)
            for &t in s.types {
                if spaced && t.radius>0 {
                    for k in 0..<9 {
                        d:=[2]i32{i32(k%3)-1,i32(k/3)-1}
                        clear(&points)
                        if !scatter(s.info.seed,coord+d,t,&points,share) {return false}
                        for g in points {
                            at:=g.position+[2]f32{f32(d.x),f32(d.y)}*CELL_SIZE
                            if at.x< -margin || at.y< -margin || at.x>CELL_SIZE+margin || at.y>CELL_SIZE+margin {continue}
                            mark(marks,samples,at)
                        }
                    }
                    continue
                }
                if !seen(&t,reach) {continue}
                clear(&points)
                if !scatter(s.info.seed,coord,t,&points,share) {return false}
                for g in points {mark(marks,samples,g.position)}
            }
        }
    }
    for m,k in marks {
        if !m {continue}
        if _,error:=append(keys,u16(k));error!=nil {return false}
    }
    return true
}

// The sources as a Foliage sees them, as far as its tiles are whole.
@(private)
ground_near :: proc(sources:^scene.Streaming_Sources,placed:mm.Mat4,s:^Source) -> scene.Sources_Near {
    return scene.sources_near(sources,placed,ground_reach(s))
}

// Whether the tile of a cell is whole: near a source, by its residency, or
// everywhere without sources.
@(private)
tile_fine :: proc "contextless" (near:^scene.Sources_Near,coord:[2]i32,was:bool) -> bool {
    if near.count==0 {return true}
    corner:=cell_corner(coord)
    low,high:=[3]f32{corner.x,-POSITION_MAX,corner.z},[3]f32{corner.x+CELL_SIZE,POSITION_MAX,corner.z+CELL_SIZE}
    return scene.resident(scene.box_near(near,low,high),was)
}

// Asks for a tile of the ground of a Foliage to be read again; fine
// wherever the sources are. queue_order keeps it once.
@(private)
ground_ask :: proc(ground:^Foliage_Ground,e:core.Entity,coord:[2]i32,fine:=false) {
    append(&ground.queue,Ground_Task{entity=e,coord=coord,fine=fine})
    ground.unordered=true
}

@(private)
task_before :: proc(a,b:Ground_Task) -> bool {
    if a.entity!=b.entity {return a.entity<b.entity}
    return coord_before(a.coord,b.coord)
}

// Orders the queue of tiles to read when something was asked or the sources
// moved: each tile once (fine if one ask was), none of a Foliage that is gone,
// and the next to read at its end: those the editor asks for, then the
// nearest a source.
@(private)
queue_order :: proc(ground:^Foliage_Ground,data:^Foliage_Data,foliages:^core.Table(Foliage,$A),worlds:^core.Table(core.World_Transform,$B),sources:^scene.Streaming_Sources) {
    ground.unordered=false
    if len(ground.queue)==0 {return}
    slice.sort_by(ground.queue[:],task_before)
    kept:=0
    near:scene.Sources_Near
    held:=core.NONE
    known:=false
    for task in ground.queue {
        if kept>0 && ground.queue[kept-1].entity==task.entity && ground.queue[kept-1].coord==task.coord {
            ground.queue[kept-1].fine||=task.fine
            continue
        }
        if task.entity!=held {
            held,known=task.entity,false
            world,placed:=core.get(worlds,task.entity)
            f,shown:=core.get(foliages,task.entity)
            if entry:=data_find(data,f.source);placed && shown && entry!=nil {
                near=ground_near(sources,mm.transform_matrix(world.transform),&entry.source)
                known=true
            }
        }
        if !known {continue}
        next:=task
        corner:=cell_corner(task.coord)
        next.near=0 if near.count==0 else scene.box_near(&near,{corner.x,-POSITION_MAX,corner.z},{corner.x+CELL_SIZE,POSITION_MAX,corner.z+CELL_SIZE})
        ground.queue[kept]=next
        kept+=1
    }
    base.truncate(&ground.queue,kept)
    slice.sort_by(ground.queue[:],proc(a,b:Ground_Task) -> bool {
        if a.fine!=b.fine {return b.fine}
        if a.near!=b.near {return a.near>b.near}
        return task_before(b,a)
    })
}

// The heights of a tile of an owner: the highest ground under each sample
// along the down of the Foliage, in its space, and the weights of its layers
// there, of the materials of that ground: those weights index in layers.
// With keys, only the samples they name, in their order. False when no
// ground covers any of it.
tile_sample :: proc(q:^core.Ground_Query,owner_world,owner_local:mm.Mat4,coord:[2]i32,samples:int,heights:[]f32,weights:[]Layer_Weights,keys:[]u16=nil) -> (layers:Tile_Layers,any:bool) {
    down:=-(owner_world*[4]f32{0,1,0,0}).xyz
    step:=CELL_SIZE/f32(samples-1)
    corner:=cell_corner(coord)
    count:=len(keys)>0?len(keys):samples*samples
    for i in 0..<count {
        k:=len(keys)>0?int(keys[i]):i
        heights[i],weights[i]=NO_GROUND,{}
        hit,found:=q.probe(q.user,mm.mat4_point(owner_world,corner+{f32(k%samples)*step,0,f32(k/samples)*step}),down)
        any||=found!=.None
        if found!=.Ground {continue}
        heights[i]=mm.mat4_point(owner_local,hit.point).y
        if hit.weights=={} {continue}
        at:=0
        for at<layers.count && layers.items[at]!=hit.layers {at+=1}
        if at==TILE_LAYERS {layers.over=true;continue}
        if at==layers.count {layers.items[at]=hit.layers;layers.count+=1}
        weights[i]={hit.weights,u8(at)}
    }
    return
}

// Reads the GROUND_TILES tiles at the end of the queue, in jobs, whole or
// sparse by where the sources are then, and writes them in that order.
@(private)
ground_read :: proc(ground:^Foliage_Ground,q:^core.Ground_Query,data:core.Ref(Foliage_Data),foliages:^core.Table(Foliage,$A),worlds:^core.Table(core.World_Transform,$B),sources:^scene.Streaming_Sources,keeps:[]Keep_Out,job_system:^jobs.Job_System,problems:^core.Problems) {
    if len(ground.queue)==0 {return}
    Reading :: struct {q:^core.Ground_Query,keeps:[]Keep_Out,work:[dynamic]Tile_Work}
    // Temporary like the slices it holds: kept in the storage, the world would free them.
    reading:=Reading{q,keeps,make([dynamic]Tile_Work,0,GROUND_TILES,context.temp_allocator)}
    keys:=make([dynamic]u16,context.temp_allocator)
    for len(ground.queue)>0 && len(reading.work)<GROUND_TILES {
        task:=pop(&ground.queue)
        owner:=ground_owner(ground,task.entity)
        world,placed:=core.get(worlds,task.entity)
        f,shown:=core.get(foliages,task.entity)
        if owner==nil || !placed || !shown {continue}
        entry:=data_find(data.ptr,f.source)
        owner_world:=mm.transform_matrix(world.transform)
        owner_local,inverted:=mm.transform_inverse_matrix(world.transform)
        if !inverted || entry==nil {continue}
        reach:=ground_reach(&entry.source)
        near:=ground_near(sources,owner_world,&entry.source)
        at:=ground_tile_find(owner,task.coord)
        sparse:=!task.fine && !tile_fine(&near,task.coord,at>=0 && owner.tiles[at].pool!=SPARSE_POOL)
        n:=int(owner.samples)
        cell:=source_cell(&entry.source,task.coord)
        w:=Tile_Work{task=task,owner_world=owner_world,owner_local=owner_local,samples=n,sparse=sparse,generates=cell!=nil && cell.generate}
        count:=n*n
        if sparse {
            if !sparse_keys(&entry.source,cell,task.coord,n,reach,&keys) {
                memory_problem(problems,task.entity,"the ground under this Foliage far away")
                continue
            }
            w.keys=slice.clone(keys[:],context.temp_allocator)
            count=len(w.keys)
        }
        w.heights,w.weights=make([]f32,count,context.temp_allocator),make([]Layer_Weights,count,context.temp_allocator)
        w.kept=make([]u64,KEEP_OUT_WORDS,context.temp_allocator)
        append(&reading.work,w)
    }
    sample :: proc(reading:^Reading,first,last:int,worker:int) {
        for &w in reading.work[first:last] {
            w.layers,w.any=tile_sample(reading.q,w.owner_world,w.owner_local,w.task.coord,w.samples,w.heights,w.weights,w.keys)
            if w.any {tile_keep_out(reading.keeps,w.owner_world,w.task.coord,{samples=w.samples,heights=w.heights,keys=w.keys},w.kept)}
        }
    }
    if job_system!=nil && jobs.worker_count(job_system)>1 && len(reading.work)>1 {
        jobs.parallel_for(job_system,jobs.OWNER,len(reading.work),1,sample,&reading)
    } else {sample(&reading,0,len(reading.work),jobs.OWNER)}
    for &w in reading.work {
        owner:=ground_owner(ground,w.task.entity)
        if owner==nil || int(owner.samples)!=w.samples {continue}
        at:=ground_tile_find(owner,w.task.coord)
        if !w.any {
            if at>=0 {ground_tile_remove(owner,at)}
            // A sparse tile reads too little of its cell to say that it has no ground.
            if w.generates && !w.sparse {core.report(problems,w.task.entity,"foliage.no_ground","cell %v of this Foliage generates instances but no ground is under it, so none stands there: move the Foliage or the ground under the cell, or turn its generator off (foliage.paint ungenerate)",w.task.coord)}
            continue
        }
        // The layers of the tile by their index among those of the owner.
        index:[TILE_LAYERS]u8
        known:[TILE_LAYERS]bool
        for layers,i in w.layers.items[:w.layers.count] {index[i],known[i]=ground_layers_index(owner,layers)}
        for &sample in w.weights {
            if sample.weights=={} {continue}
            if !known[sample.layers] {sample={};continue}
            sample.layers=index[sample.layers]
        }
        if w.layers.over || slice.contains(known[:w.layers.count],false) {
            core.report(problems,w.task.entity,"foliage.layers","the ground under cell %v of this Foliage has more terrains with other layers than it keeps apart (%d in a cell, LAYERS_MAX in all), so a rule of layers takes none of the ground of some of them: give the terrains under it the same layers, or fewer terrains",w.task.coord,TILE_LAYERS)
        }
        if w.sparse {
            ground_sparse_write(owner,w.task.coord,w.keys,w.heights,w.weights,w.kept)
            continue
        }
        same:=at>=0 && owner.tiles[at].pool!=SPARSE_POOL && int(ground_tile_samples(owner,w.task.coord))==w.samples
        heights,weights,tile:=ground_tile(owner,w.task.coord,u32(w.samples))
        if tile==nil {continue}
        kept:=ground_tile_kept(owner,ground_tile_find(owner,w.task.coord))
        if same && same_heights(heights,w.heights) && slice.equal(weights,w.weights) && slice.equal(kept,w.kept) {continue}
        copy(heights,w.heights)
        copy(weights,w.weights)
        copy(kept,w.kept)
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
