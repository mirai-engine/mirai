package foliage

import "mirai:core"
import "mirai:std/base"
import scene "mirai:engine/scene"
import mm "mirai:std/math"
import physics "plugins:physics/runtime"

// The collision of the foliage: a static body per resident cell of each
// Foliage, with a shape per instance of a type that collides, made as bodies
// the foliage owns in the simulation (physics.owned_body_create). A cell
// collides while it is resident by the residency of the sources
// (scene.resident), as it is drawn, within the farthest distance at which a
// type that collides is drawn as its mesh (collision_reach): far away there
// is nothing to meet it. The sources are those of the simulation
// (scene.Simulation_Sources), never the view, so that a world collides the
// same whoever looks at it; without any, every cell collides.
// Its handles live with the world, as the simulation does: a copy for Play
// or a rollback takes both. A shape is the instance's alone, so taking one
// instance out destroys one shape (collider_remove) and touches nothing else.

@(storage)
Foliage_Physics :: struct {
    owners:[dynamic]Physics_Owner,
    cells:[dynamic]Physics_Cell,
    shapes:[dynamic]physics.Shape_Handle, // by cell, one per instance that collides; zero once removed
    chosen:[scene.SOURCES_MAX]scene.Source, // the simulation sources the cells were last chosen by
    chosen_count:int,
    revision:u64, // raised when those sources move (scene.sources_moved)
    stats:Foliage_Physics_Stats,
}
Foliage_Physics_Stats :: struct {bodies,shapes,removed:u64}
Physics_Owner :: struct {
    entity:core.Entity,
    source:base.Asset_Id,
    epoch:u64,
    loads:u32,
    ground:u32,
    transform:mm.Transform,
    sources:u64, // Foliage_Physics.revision when its cells were chosen
    removed:u64, // the hash of the instances taken out of it then (Removed_Owner)
}
// Each cell of the source of a Foliage, with a body when it is resident and
// an instance of it collides.
Physics_Cell :: struct {
    owner:core.Entity,
    coord:[2]i32,
    version:u32, // of the cell it was built from; 0 when not all of it fit
    ground:u32,  // the revision of its ground then
    removed:u64, // the hash of the instances taken out of it then (removed_cell)
    resident:bool,
    body:physics.Body_Handle,
    first,count:u32, // its shapes
}

BODY_OWNER :: physics.Body_Owner('f'|'o'<<8|'l'<<16|'i'<<24)

// The index physics keeps of the body of a cell: its coordinates.
@(private)
cell_user :: proc "contextless" (coord:[2]i32) -> u64 {return u64(u32(coord.x))|u64(u32(coord.y))<<32}

// How far from a source the cells of a source collide: the farthest distance
// at which a type that collides is drawn as its mesh, and no farther than
// COLLISION_REACH, also for a type never culled: what moves far from every
// source meets no foliage, and many sections loaded do not fill the
// simulation with the cells of all of them. 0 when no type collides.
COLLISION_REACH :: f32(128)
collision_reach :: proc(s:^Source) -> f32 {
    reach:=f32(0)
    for t in s.types {
        if t.collision==.None {continue}
        _,cull:=mesh_distances(t,type_far(t))
        reach=max(reach,cull<=0 ? COLLISION_REACH : min(cull,COLLISION_REACH))
    }
    return reach
}

// Whether a cell collides, near the sources as near gives them (reach 0: every one).
@(private)
cell_collides :: proc(near:^scene.Sources_Near,reach:f32,coord:[2]i32,was:bool) -> bool {
    if reach<=0 || near==nil {return true}
    corner:=cell_corner(coord)
    return scene.resident(scene.box_near(near,{corner.x,-POSITION_MAX,corner.z},{corner.x+CELL_SIZE,POSITION_MAX,corner.z+CELL_SIZE}),was)
}

// The shape of an instance of a type, in the frame of the body of its cell,
// which has the position and rotation of the entity.
instance_shape :: proc "contextless" (t:^Foliage_Type,p:Placed,owner:mm.Transform) -> (shape:physics.Owned_Shape,ok:bool) {
    across,along:=p.scale[0]*abs(owner.scale.x),p.scale[1]*abs(owner.scale.y)
    center:=[3]f32{0,0,0}
    shape.collider={friction=0.6,preset=physics.Collision_Preset(t.preset)}
    switch t.collision {
    case .None: return
    case .Capsule:
        radius,height:=t.size.x*across,t.size.y*along
        if !(radius>0) || !(height>0) {return}
        shape.collider.kind,shape.collider.size=.Capsule,{radius,max(height*0.5-radius,0),0}
        center.y=max(height*0.5,radius)
    case .Box:
        half:=[3]f32{t.size.x*across,t.size.y*along,t.size.z*across}*0.5
        if !(half.x>0) || !(half.y>0) || !(half.z>0) {return}
        shape.collider.kind,shape.collider.size=.Box,half
        center.y=half.y
    }
    shape.position,shape.rotation,shape.user=p.position*owner.scale+mm.quat_rotate(p.rotation,center),p.rotation,p.id
    return shape,true
}

// The bodies of the resident cells of one Foliage, from its source on its
// ground; near: the streaming sources as its entity sees them, with
// collision_reach (nil: every cell collides). With all, those it had are
// destroyed first; otherwise a cell whose content, ground, instances taken
// out (gone) and residency did not change keeps its body. False when the
// simulation had no room for all of them.
physics_owner_build :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,collision:^physics.Collision_Settings,e:core.Entity,s:^Source,transform:mm.Transform,ground:^Ground_Owner=nil,all:=true,near:^scene.Sources_Near=nil,reach:=f32(0),gone:^Removed_Owner=nil) -> (complete,enough:bool) {
    held:=make([dynamic]Physics_Cell,context.temp_allocator)
    held_shapes:=make([dynamic]physics.Shape_Handle,context.temp_allocator)
    // What each cell of the owner was, in the order of the source, for the residency to hold.
    before:=make([dynamic]Physics_Cell,context.temp_allocator)
    for cell in fp.cells {if cell.owner==e {append(&before,cell)}}
    if !all {
        for cell in before {
            source:=source_cell(s,cell.coord)
            _,revision:=ground_cell(ground,cell.coord)
            _,removed:=removed_cell(gone,cell.coord)
            if source==nil || cell.version==0 || source.version!=cell.version || revision!=cell.ground || removed!=cell.removed {continue}
            if cell_collides(near,reach,cell.coord,cell.resident)!=cell.resident {continue}
            kept:=cell
            kept.first=u32(len(held_shapes))
            append(&held_shapes,..fp.shapes[cell.first:][:cell.count])
            append(&held,kept)
        }
    }
    physics_owner_clear(fp,state,e,held[:])
    complete,enough=true,true
    work:Build_Work
    defer build_work_destroy(&work)
    j,b:=0,0
    for &cell in s.cells {
        // The cells of an owner and those it keeps are in the order of the cells of its source.
        for j<len(held) && coord_before(held[j].coord,cell.coord) {j+=1}
        if j<len(held) && held[j].coord==cell.coord {
            kept:=held[j]
            first:=u32(len(fp.shapes))
            append(&fp.shapes,..held_shapes[kept.first:][:kept.count])
            kept.first=first
            append(&fp.cells,kept)
            continue
        }
        tile,revision:=ground_cell(ground,cell.coord)
        removed,removed_hash:=removed_cell(gone,cell.coord)
        for b<len(before) && coord_before(before[b].coord,cell.coord) {b+=1}
        was:=b<len(before) && before[b].coord==cell.coord && before[b].resident
        if !cell_collides(near,reach,cell.coord,was) {
            append(&fp.cells,Physics_Cell{owner=e,coord=cell.coord,version=cell.version,ground=revision,removed=removed_hash,first=u32(len(fp.shapes))})
            continue
        }
        if !cell_build(s,&cell,tile,&work,removed) {
            // Version 0: built again by the next build of the owner.
            enough=false
            append(&fp.cells,Physics_Cell{owner=e,coord=cell.coord,ground=revision,removed=removed_hash,resident=true,first=u32(len(fp.shapes))})
            continue
        }
        body:physics.Body_Handle
        first:=u32(len(fp.shapes))
        fit:=true
        for p in work.placed {
            t,_:=source_type(s,p.type)
            if t==nil || t.collision==.None {continue}
            wanted,ok:=instance_shape(t,p,transform)
            if !ok {continue}
            if body=={} {
                failure:physics.Owned_Error
                body,failure=physics.owned_body_create(state,{BODY_OWNER,e,cell_user(cell.coord)},transform.position,transform.rotation)
                if body=={} {
                    enough&&=failure!=.Out_Of_Memory
                    fit=false
                    break
                }
                fp.stats.bodies+=1
            }
            shape:=physics.owned_shape_create(state,collision,body,wanted)
            if shape=={} {fit=false;continue}
            append(&fp.shapes,shape)
            fp.stats.shapes+=1
        }
        complete&&=fit
        append(&fp.cells,Physics_Cell{owner=e,coord=cell.coord,version=fit?cell.version:0,ground=revision,removed=removed_hash,resident=true,body=body,first=first,count=u32(len(fp.shapes))-first})
    }
    return
}

// Destroys the bodies of a Foliage, but those of the cells in keep (some of
// its cells, in their order), and forgets its cells.
physics_owner_clear :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,e:core.Entity,keep:[]Physics_Cell={}) {
    kept:=0
    shapes:=0
    k:=0
    for cell in fp.cells {
        if cell.owner==e {
            if k<len(keep) && keep[k].coord==cell.coord {k+=1;continue}
            physics.owned_body_destroy(state,cell.body)
            continue
        }
        moved:=cell
        copy(fp.shapes[shapes:],fp.shapes[cell.first:][:cell.count])
        moved.first=u32(shapes)
        shapes+=int(cell.count)
        fp.cells[kept]=moved
        kept+=1
    }
    base.truncate(&fp.cells,kept)
    base.truncate(&fp.shapes,shapes)
}

// Takes the collision of one instance of a cell out of the simulation, in
// constant time: instance is its place among the shapes of the cell. False
// when it has none, or it was taken out already.
collider_remove :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,cell,instance:int) -> bool {
    if cell<0 || cell>=len(fp.cells) || instance<0 || instance>=int(fp.cells[cell].count) {return false}
    shape:=&fp.shapes[int(fp.cells[cell].first)+instance]
    if !physics.owned_shape_destroy(state,shape^) {return false}
    shape^={}
    fp.stats.removed+=1
    return true
}

// The instance of a Foliage a hit of physics met; false for anything else.
hit_of :: proc(state:core.Ref(physics.Physics_State),hit:physics.Hit) -> (found:Foliage_Plant,ok:bool) {
    return shape_instance(state.ptr,hit.body,hit.shape)
}

@(private)
shape_instance :: proc(state:^physics.Physics_State,body:physics.Body_Handle,shape:physics.Shape_Handle) -> (found:Foliage_Plant,ok:bool) {
    cell:=physics.owned_body_of(state,body) or_return
    if cell.owner!=BODY_OWNER {return}
    instance:=physics.owned_shape_user(state,shape) or_return
    return {cell.entity,{i32(u32(cell.user)),i32(u32(cell.user>>32))},instance},true
}

// Keeps the bodies of the foliage of the world equal to its sources, the
// places of their entities and the cells the simulation sources keep resident.
@(step="fixed",loops="game editor",stage="simulate",after="physics_prepare",before="physics_places")
foliage_physics :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,collision:core.Ref(physics.Collision_Settings),data:core.Ref(Foliage_Data),grounds:core.Ref(Foliage_Ground),removals:core.Ref(Foliage_Removals),foliages:^core.Table(Foliage,.Read),worlds:^core.Table(core.World_Transform,.Read),kept:^core.Table(scene.Far_Kept,.Read),sources:core.Ref(scene.Simulation_Sources),time:core.Time,problems:^core.Problems) {
    if !state.ready || data.ptr==nil || time.resimulating {return}
    now:[]scene.Source
    if sources.ptr!=nil {now=sources.ptr.items[:clamp(sources.ptr.count,0,scene.SOURCES_MAX)]}
    if scene.sources_moved(fp.chosen[:fp.chosen_count],now) {
        copy(fp.chosen[:],now)
        fp.chosen_count=len(now)
        fp.revision+=1
    }
    // Without settings every preset is the Default category, colliding with all.
    defaults:physics.Collision_Settings
    settings:=collision.ptr if collision.ptr!=nil else &defaults
    for i:=len(fp.owners)-1;i>=0;i-=1 {
        owner:=fp.owners[i]
        f,shown:=core.get(foliages,owner.entity)
        // What stands for a section that is not loaded collides with nothing.
        if shown && f.source==owner.source && !(kept!=nil && core.has(kept,owner.entity)) {continue}
        physics_owner_clear(fp,state,owner.entity)
        unordered_remove(&fp.owners,i)
    }
    placed:=core.join(foliages,worlds)
    for e,f,world in core.each_joined(&placed) {
        entry:=data_find(data.ptr,f.source)
        if entry==nil || (kept!=nil && core.has(kept,e)) {continue}
        ground:=ground_owner(grounds.ptr,e)
        revision:=ground!=nil?ground.revision:0
        streamed:=fp.revision
        gone:=removed_owner(removals.ptr,e)
        removed:=gone!=nil?gone.hash:0
        owner:^Physics_Owner
        for &held in fp.owners {if held.entity==e {owner=&held;break}}
        if owner==nil {
            if _,err:=append(&fp.owners,Physics_Owner{entity=e,source=f.source});err!=nil {
                memory_problem(problems,e,"the collision of its foliage, which does not collide")
                continue
            }
            owner=&fp.owners[len(fp.owners)-1]
        } else if owner.epoch==entry.epoch && owner.loads==entry.loads && owner.ground==revision && owner.transform==world.transform && owner.sources==streamed && owner.removed==removed {continue}
        // A source read again, a ground that changed, instances taken out or sources that moved build only the cells that changed.
        all:=owner.epoch!=entry.epoch || owner.transform!=world.transform
        owner.epoch,owner.loads,owner.ground,owner.transform,owner.source,owner.sources,owner.removed=entry.epoch,entry.loads,revision,world.transform,f.source,streamed,removed
        reach:=collision_reach(&entry.source)
        near:scene.Sources_Near
        if reach>0 {near=scene.sources_near_of(fp.chosen[:fp.chosen_count],mm.transform_matrix(world.transform),reach)}
        complete,enough:=physics_owner_build(fp,state,settings,e,&entry.source,world.transform,ground,all,fp.chosen_count>0?&near:nil,reach,gone)
        if !enough {
            owner.loads=0
            memory_problem(problems,e,"the collision of its foliage: some cells do not collide")
        } else if !complete {
            core.report(problems,e,"foliage.physics","the simulation has no room for every collision of its foliage: some cells or instances do not collide; raise the bodies or shapes of Physics_Settings, or give fewer types a collision")
        }
    }
}
