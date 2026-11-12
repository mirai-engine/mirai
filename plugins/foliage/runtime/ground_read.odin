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
// in jobs, with where foliage is kept out of them. A keep-out that comes,
// goes or changes is a change of the ground under its old and new boxes. A
// tile is fine near the streaming sources, within the reach of the meshes of
// its types, and where the editor asks; coarse farther.

GROUND_TILES :: 24 // tiles of ground read in a call (the step runs in the frame and in each tick)
GROUND_REACH :: f32(512) // m from a source past which a tile is coarse, for the meshes of every type
COARSE_SAMPLES :: 5 // per side of a coarse tile
SAMPLES_MIN :: 9 // per side of a fine tile, whatever the spacing of the ground
SAMPLES_MAX :: 65

// A tile of the ground of a Foliage to read again.
Ground_Task :: struct {
    entity:core.Entity,
    coord:[2]i32,
    fine:bool, // asked for by the editor: fine wherever the sources are (what the sorted queue holds)
}

// A tile read in a job.
@(private)
Tile_Work :: struct {
    task:Ground_Task,
    owner_world,owner_local:mm.Mat4,
    samples:int,
    coarse:bool,
    generates:bool, // its cell: one without ground there is a problem
    heights:[]f32,
    weights:[][4]u8,
    kept:[]u64,
    layers:[RULE_LAYERS]base.Asset_Id,
    any:bool,
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
        for tile in owner.tiles {
            if all || tile.coord in touched {ground_ask(ground,e,tile.coord)}
        }
        // A change also covers cells without a tile: ground came, moved or grew, or its pages came.
        for &cell in entry.source.cells {
            if (cells || all || cell.coord in touched) && ground_tile_find(owner,cell.coord)<0 {ground_ask(ground,e,cell.coord)}
        }
        // The editor asks for fine ground under its brush.
        for request in asked {
            if request.entity==e && ground_tile_samples(owner,request.coord)!=owner.samples {ground_ask(ground,e,request.coord,true)}
        }
        // A tile goes from fine to coarse, or back, as the sources move.
        if sources_moved || cells || all {
            near:=ground_near(sources.ptr,owner_world,&entry.source)
            for tile in owner.tiles {
                fine:=ground_tile_samples(owner,tile.coord)!=COARSE_SAMPLES
                if tile_fine(&near,tile.coord,fine)!=fine {ground_ask(ground,e,tile.coord)}
            }
        }
    }
}

// Whether a box of the space of an owner, in x and z, covers some of a tile.
@(private)
covers_tile :: proc "contextless" (box:mm.Aabb,coord:[2]i32) -> bool {
    corner:=cell_corner(coord)
    return box.min.x<=corner.x+CELL_SIZE && box.max.x>=corner.x && box.min.z<=corner.z+CELL_SIZE && box.max.z>=corner.z
}

// The sources as a Foliage sees them, as far as the meshes of its types are
// drawn (a type never culled, or none, as far as GROUND_REACH), up to it.
@(private)
ground_near :: proc(sources:^scene.Streaming_Sources,placed:mm.Mat4,s:^Source) -> scene.Sources_Near {
    reach:=len(s.types)==0?GROUND_REACH:0
    for t in s.types {
        _,cull:=mesh_distances(t,type_far(t))
        reach=max(reach,cull>0?min(cull,GROUND_REACH):GROUND_REACH)
    }
    return scene.sources_near(sources,placed,reach)
}

// Whether the tile of a cell is fine: near a source, by its residency, or
// everywhere without sources.
@(private)
tile_fine :: proc "contextless" (near:^scene.Sources_Near,coord:[2]i32,was:bool) -> bool {
    if near.count==0 {return true}
    corner:=cell_corner(coord)
    low,high:=[3]f32{corner.x,-POSITION_MAX,corner.z},[3]f32{corner.x+CELL_SIZE,POSITION_MAX,corner.z+CELL_SIZE}
    return scene.resident(scene.box_near(near,low,high),was)
}

// Asks for a tile of the ground of a Foliage to be read again, once; fine
// wherever the sources are.
@(private)
ground_ask :: proc(ground:^Foliage_Ground,e:core.Entity,coord:[2]i32,fine:=false) {
    task:=Ground_Task{e,coord,fine}
    at,found:=slice.binary_search_by(ground.queued[:],task,task_order)
    if found {ground.queued[at].fine||=fine;return}
    inject_at(&ground.queued,at,task)
    append(&ground.queue,task)
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

// The heights of a tile of an owner: the highest ground under each sample
// along the down of the Foliage, in its space, and the weights of its layers
// there; false when no ground covers any of it.
tile_sample :: proc(q:^core.Ground_Query,owner_world,owner_local:mm.Mat4,coord:[2]i32,samples:int,heights:[]f32,weights:[][4]u8,coarse:=false) -> (layers:[RULE_LAYERS]base.Asset_Id,any:bool) {
    down:=-(owner_world*[4]f32{0,1,0,0}).xyz
    step:=CELL_SIZE/f32(samples-1)
    corner:=cell_corner(coord)
    for z in 0..<samples {
        for x in 0..<samples {
            k:=z*samples+x
            heights[k],weights[k]=NO_GROUND,{}
            hit,found:=q.probe(q.user,mm.mat4_point(owner_world,corner+{f32(x)*step,0,f32(z)*step}),down,coarse)
            any||=found!=.None
            if found!=.Ground {continue}
            heights[k],weights[k]=mm.mat4_point(owner_local,hit.point).y,hit.weights
            if layers=={} {layers=hit.layers}
        }
    }
    return
}

// Reads GROUND_TILES tiles of the queue, in jobs, fine or coarse by where the
// sources are then, and writes them in the order they were asked.
@(private)
ground_read :: proc(ground:^Foliage_Ground,q:^core.Ground_Query,data:core.Ref(Foliage_Data),foliages:^core.Table(Foliage,$A),worlds:^core.Table(core.World_Transform,$B),sources:^scene.Streaming_Sources,keeps:[]Keep_Out,job_system:^jobs.Job_System,problems:^core.Problems) {
    if len(ground.queue)==0 {return}
    Reading :: struct {q:^core.Ground_Query,keeps:[]Keep_Out,work:[dynamic]Tile_Work}
    // Temporary like the slices it holds: kept in the storage, the world would free them.
    reading:=Reading{q,keeps,make([dynamic]Tile_Work,0,GROUND_TILES,context.temp_allocator)}
    taken:=0
    for taken<len(ground.queue) && len(reading.work)<GROUND_TILES {
        task:=ground.queue[taken]
        taken+=1
        if at,found:=slice.binary_search_by(ground.queued[:],task,task_order);found {
            task.fine=ground.queued[at].fine
            ordered_remove(&ground.queued,at)
        }
        owner:=ground_owner(ground,task.entity)
        world,placed:=core.get(worlds,task.entity)
        f,shown:=core.get(foliages,task.entity)
        if owner==nil || !placed || !shown {continue}
        entry:=data_find(data.ptr,f.source)
        owner_world:=mm.transform_matrix(world.transform)
        owner_local,inverted:=mm.transform_inverse_matrix(world.transform)
        if !inverted || entry==nil {continue}
        near:=ground_near(sources,owner_world,&entry.source)
        was:=ground_tile_samples(owner,task.coord)
        coarse:=!task.fine && !tile_fine(&near,task.coord,was!=0 && was!=COARSE_SAMPLES)
        n:=coarse?COARSE_SAMPLES:int(owner.samples)
        cell:=source_cell(&entry.source,task.coord)
        append(&reading.work,Tile_Work{task=task,owner_world=owner_world,owner_local=owner_local,samples=n,coarse=coarse,generates=cell!=nil && cell.generate,heights=make([]f32,n*n,context.temp_allocator),weights=make([][4]u8,n*n,context.temp_allocator),kept=make([]u64,KEEP_OUT_WORDS,context.temp_allocator)})
    }
    remove_range(&ground.queue,0,taken)
    sample :: proc(reading:^Reading,first,last:int,worker:int) {
        for &w in reading.work[first:last] {
            w.layers,w.any=tile_sample(reading.q,w.owner_world,w.owner_local,w.task.coord,w.samples,w.heights,w.weights,w.coarse)
            if w.any {tile_keep_out(reading.keeps,w.owner_world,w.task.coord,{samples=w.samples,heights=w.heights},w.kept)}
        }
    }
    if job_system!=nil && jobs.worker_count(job_system)>1 && len(reading.work)>1 {
        jobs.parallel_for(job_system,jobs.OWNER,len(reading.work),1,sample,&reading)
    } else {sample(&reading,0,len(reading.work),jobs.OWNER)}
    for &w in reading.work {
        owner:=ground_owner(ground,w.task.entity)
        if owner==nil || !w.coarse && int(owner.samples)!=w.samples {continue}
        at:=ground_tile_find(owner,w.task.coord)
        if !w.any {
            if at>=0 {ground_tile_remove(owner,at)}
            if w.generates {core.report(problems,w.task.entity,"foliage.no_ground","cell %v of this Foliage generates instances but no ground is under it, so none stands there: move the Foliage or the ground under the cell, or turn its generator off (foliage.paint ungenerate)",w.task.coord)}
            continue
        }
        if w.layers!={} {
            owner.layers,owner.layer_count=w.layers,0
            for layer in w.layers {if layer!={} {owner.layer_count+=1}}
        }
        same:=at>=0 && int(ground_tile_samples(owner,w.task.coord))==w.samples
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
