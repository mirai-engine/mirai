package foliage

import "core:slice"
import "mirai:core"
import "mirai:host"
import render "mirai:engine/render"
import "mirai:std/base"
import scene "mirai:engine/scene"
import mm "mirai:std/math"
import physics "plugins:physics/runtime"

// The collision of the foliage: a static body per cell of each loaded
// Foliage, at the corner of the cell, with the shapes of each instance of a
// type that collides, made as bodies the foliage owns in the simulation
// (physics.owned_body_create). Every cell collides, however far it is from
// the streaming sources: what moves far from every player (an NPC or a shot
// on a server) meets the foliage as near ones do, and the navmesh, built from
// the static collision, has the same obstacles wherever the players are. A
// Foliage kept for a section that is not loaded (scene.Far_Kept) collides
// with nothing. A tick builds at most a budget of instances, the cells
// nearest the simulation sources (scene.Simulation_Sources) first, never the
// view, so that a world collides the same whoever looks at it; the others
// wait for the ticks after. Its handles live with the world, as the
// simulation does: a copy for Play or a rollback takes both. The shapes of an
// instance are its own, so taking it out destroys them (collider_remove) and
// touches nothing else; putting one back builds its cell again.

@(storage)
Foliage_Physics :: struct {
    owners:[dynamic]Physics_Owner,
    cells:[dynamic]Physics_Cell,
    shapes:[dynamic]Physics_Shape, // by cell, in the order of its instances
    hulls:[dynamic]physics.Hull_Handle, // asked of physics (owned_hulls), each once, until no shape uses it
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
    removed:u64, // the hash of the instances taken out of it then (Removed_Owner)
    pending:bool, // some of its cells wait for the budget of a tick
}

// What a tick builds of the collision of the foliage at most: instances of
// the cells, by the most each shows (cell_bound), the nearest a source first;
// the rest wait (waiting) for the ticks after.
PHYSICS_INSTANCES_A_TICK :: 1 << 14
Physics_Budget :: struct {
    instances:int, // left
    waiting:bool,  // some cell waits for the next tick
}
// Each cell of the source of a Foliage, with a body when an instance of it collides.
Physics_Cell :: struct {
    owner:core.Entity,
    coord:[2]i32,
    version:u32, // of the cell it was built from; 0 when not all of it fit
    ground:u32,  // the revision of its ground then
    removed:u64, // the hash of the instances taken out of it then (removed_cell)
    body:physics.Body_Handle,
    first,count:u32, // its shapes
}
// A shape of an instance: zero once the instance is taken out.
Physics_Shape :: struct {
    handle:physics.Shape_Handle,
    instance:u64, // its id in its cell (Placed.id)
}

BODY_OWNER :: physics.Body_Owner('f'|'o'<<8|'l'<<16|'i'<<24)

// The index physics keeps of the body of a cell: its coordinates.
@(private)
cell_user :: proc "contextless" (coord:[2]i32) -> u64 {return u64(u32(coord.x))|u64(u32(coord.y))<<32}

// A shape of a type at scale 1, and where it is from the place of an instance.
Type_Shape :: struct {
    type:u32,
    collider:physics.Collider,
    placement:mm.Mat4,
    hull:physics.Hull_Handle, // of a Hull collider, which every instance scales
}

// The shapes of the types of a source that collide, appended to out in the
// order of the types: its capsule or box, standing on the instance, the
// colliders of its prefab, or the convex hulls of its meshes, asked of
// physics once for every instance and kept in fp.hulls. left_out: the types
// of Prefab or Hull collision without what they collide as (no prefab, a
// mesh without collision geometry, no room for hulls) and the colliders of
// prefabs an instance cannot have (a Mesh, a sensor). Without assets a
// prefab gives none.
type_shapes :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,s:^Source,assets:^host.Assets,out:^[dynamic]Type_Shape) -> (left_out:int) {
    // The hulls of what a renderer shows, each a shape of the collider placed as the renderer is.
    hulls_of :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,assets:^host.Assets,renderer:render.Mesh_Renderer,type:u32,collider:physics.Collider,placement:mm.Mat4,out:^[dynamic]Type_Shape) -> bool {
        made:=make([dynamic]physics.Hull_Handle,context.temp_allocator)
        if !physics.owned_hulls(state,assets,renderer,&made) {return false}
        for hull in made {
            append(out,Type_Shape{type,collider,placement,hull})
            if !slice.contains(fp.hulls[:],hull) {append(&fp.hulls,hull)}
        }
        return true
    }
    for t in s.types {
        hull:=physics.collider_hull()
        hull.preset=physics.Collision_Preset(t.preset)
        switch t.collision {
        case .None:
        case .Capsule:
            c:=physics.collider_capsule(t.size.x,max(t.size.y*0.5-t.size.x,0))
            c.center.y,c.preset=max(t.size.y*0.5,t.size.x),physics.Collision_Preset(t.preset)
            append(out,Type_Shape{t.id,c,1,{}})
        case .Box:
            c:=physics.collider_box(t.size*0.5)
            c.center.y,c.preset=t.size.y*0.5,physics.Collision_Preset(t.preset)
            append(out,Type_Shape{t.id,c,1,{}})
        case .Prefab:
            file:=assets!=nil && t.prefab!={} ? host.assets_scene(assets,t.prefab) : nil
            if file==nil {
                if t.prefab=={} {left_out+=1}
                continue
            }
            parts:=make([dynamic]Prefab_Part,context.temp_allocator)
            colliders:=make([dynamic]Prefab_Collider,context.temp_allocator)
            _,skipped:=prefab_parts(file,&assets.types,&parts,&colliders)
            left_out+=skipped
            for c in colliders {
                if c.collider.kind!=.Hull {append(out,Type_Shape{t.id,c.collider,c.placement,{}});continue}
                if !hulls_of(fp,state,assets,c.renderer,t.id,c.collider,c.placement,out) {left_out+=1}
            }
        case .Hull:
            if t.mesh!={} {
                if !hulls_of(fp,state,assets,{mesh=t.mesh},t.id,hull,1,out) {left_out+=1}
                continue
            }
            file:=assets!=nil && t.prefab!={} ? host.assets_scene(assets,t.prefab) : nil
            if file==nil {
                if t.prefab=={} {left_out+=1}
                continue
            }
            parts:=make([dynamic]Prefab_Part,context.temp_allocator)
            prefab_parts(file,&assets.types,&parts)
            for part in parts {
                if !hulls_of(fp,state,assets,part.renderer,t.id,hull,part.placement,out) {left_out+=1}
            }
        }
    }
    return
}

// A collider under a scale along its x, y and z, as an owned shape holds it:
// a box scales along each axis, a sphere by the largest, a capsule and a
// cylinder across by the largest of x and z, and along y from end to end.
@(private)
collider_scaled :: proc "contextless" (c:physics.Collider,scale:[3]f32) -> (scaled:physics.Collider,ok:bool) {
    scaled=c
    scaled.center=0
    across:=max(scale.x,scale.z)
    #partial switch c.kind {
    case .Box:     scaled.size=c.size*scale
    case .Sphere:  scaled.size.x=c.size.x*max(scale.x,scale.y,scale.z)
    case .Capsule: scaled.size.x,scaled.size.y=c.size.x*across,max((c.size.y+c.size.x)*scale.y-c.size.x*across,0)
    case .Cylinder:scaled.size.x,scaled.size.y=c.size.x*across,c.size.y*scale.y
    case:          return
    }
    if !(scaled.size.x>0) || c.kind==.Box && (!(scaled.size.y>0) || !(scaled.size.z>0)) || c.kind==.Cylinder && !(scaled.size.y>0) {return}
    return scaled,true
}

// A shape of an instance of a type, in the frame of the body of its cell: at
// its corner, with the rotation of the entity.
instance_shape :: proc "contextless" (shape:Type_Shape,p:Placed,coord:[2]i32,owner:mm.Transform) -> (made:physics.Owned_Shape,ok:bool) {
    s:=[3]f32{p.scale[0],p.scale[1],p.scale[0]}*[3]f32{abs(owner.scale.x),abs(owner.scale.y),abs(owner.scale.z)}
    at:=(p.position-cell_corner(coord))*owner.scale
    m:=mm.transform_matrix({position=at,rotation=p.rotation,scale=s})*shape.placement*mm.transform_matrix({position=shape.collider.center,rotation=1,scale=1})
    position,rotation,scale,_:=matrix_pose(m)
    if shape.collider.kind==.Hull {
        made.collider,made.hull,made.scale=shape.collider,shape.hull,scale
        made.collider.center=0
    } else {
        made.collider=collider_scaled(shape.collider,scale) or_return
    }
    made.position,made.rotation,made.user=position,rotation,p.id
    return made,true
}

// The bodies of the cells of one Foliage, from its source on its ground with
// the shapes of its types (type_shapes). With all, those it had are
// destroyed first; otherwise a cell whose content and ground did not change
// keeps its body, and the instances newly taken out of it (gone) leave with
// their shapes alone. With a budget, the cells to build go nearest the
// sources of near first while it lasts, and the others wait without a body
// (version 0). False when the simulation had no room for all of them.
physics_owner_build :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,collision:^physics.Collision_Settings,e:core.Entity,s:^Source,transform:mm.Transform,shapes:[]Type_Shape,ground:^Ground_Owner=nil,all:=true,gone:^Removed_Owner=nil,near:^scene.Sources_Near=nil,budget:^Physics_Budget=nil) -> (complete,enough:bool) {
    held:=make([dynamic]Physics_Cell,context.temp_allocator)
    held_shapes:=make([dynamic]Physics_Shape,context.temp_allocator)
    if !all {
        for &cell,index in fp.cells {
            if cell.owner!=e {continue}
            source:=source_cell(s,cell.coord)
            _,revision:=ground_cell(ground,cell.coord)
            ids,removed:=removed_cell(gone,cell.coord)
            if source==nil || cell.version==0 || source.version!=cell.version || revision!=cell.ground {continue}
            if removed!=cell.removed {
                // One taken out before that is not any more was put back: the cell is built again.
                back:=false
                for shape in fp.shapes[cell.first:][:cell.count] {back||=shape.handle=={} && !ids_have(ids,shape.instance)}
                if back {continue}
                cell_take_out(fp,state,index,ids)
            }
            kept:=cell
            kept.removed=removed
            kept.first=u32(len(held_shapes))
            append(&held_shapes,..fp.shapes[cell.first:][:cell.count])
            append(&held,kept)
        }
    }
    physics_owner_clear(fp,state,e,held[:])
    complete,enough=true,true
    // Which of the cells to build the budget takes: the nearest.
    chosen:[]bool
    if budget!=nil {
        chosen=make([]bool,len(s.cells),context.temp_allocator)
        wanted:=make([dynamic]scene.Resident_Order,context.temp_allocator)
        j:=0
        for &cell,k in s.cells {
            for j<len(held) && coord_before(held[j].coord,cell.coord) {j+=1}
            if j<len(held) && held[j].coord==cell.coord {continue}
            low,high:=cell_box(cell.coord)
            append(&wanted,scene.Resident_Order{near=near!=nil?scene.box_near(near,low,high):0,index=u32(k)})
        }
        slice.sort_by(wanted[:],proc(a,b:scene.Resident_Order) -> bool {return a.near<b.near || a.near==b.near && a.index<b.index})
        for order in wanted {
            if budget.instances<=0 {budget.waiting=true;break}
            instances,_:=cell_bound(s,&s.cells[order.index],0)
            budget.instances-=max(instances,1)
            chosen[order.index]=true
        }
    }
    work:Build_Work
    defer build_work_destroy(&work)
    j:=0
    for &cell,k in s.cells {
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
        if budget!=nil && !chosen[k] {
            // Version 0: built by a later tick.
            append(&fp.cells,Physics_Cell{owner=e,coord=cell.coord,ground=revision,removed=removed_hash,first=u32(len(fp.shapes))})
            continue
        }
        if !cell_build(s,&cell,tile,&work,removed,0) {
            // Version 0: built again by the next build of the owner.
            enough=false
            append(&fp.cells,Physics_Cell{owner=e,coord=cell.coord,ground=revision,removed=removed_hash,first=u32(len(fp.shapes))})
            continue
        }
        body:physics.Body_Handle
        first:=u32(len(fp.shapes))
        fit:=true
        made: for p in work.placed {
            for shape in shapes {
                if shape.type!=p.type {continue}
                wanted,ok:=instance_shape(shape,p,cell.coord,transform)
                if !ok {continue}
                if body=={} {
                    failure:physics.Owned_Error
                    body,failure=physics.owned_body_create(state,{BODY_OWNER,e,cell_user(cell.coord)},mm.transform_point(transform,cell_corner(cell.coord)),transform.rotation)
                    if body=={} {
                        enough&&=failure!=.Out_Of_Memory
                        fit=false
                        break made
                    }
                    fp.stats.bodies+=1
                }
                handle:=physics.owned_shape_create(state,collision,body,wanted)
                if handle=={} {fit=false;continue}
                append(&fp.shapes,Physics_Shape{handle,p.id})
                fp.stats.shapes+=1
            }
        }
        complete&&=fit
        append(&fp.cells,Physics_Cell{owner=e,coord=cell.coord,version=fit?cell.version:0,ground=revision,removed=removed_hash,body=body,first=first,count=u32(len(fp.shapes))-first})
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

// Takes the collision of one instance of a cell (its index among the cells)
// out of the simulation: its shapes, and the body of the cell once it has
// none. False when it has none, or it was taken out already.
collider_remove :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,cell:int,instance:u64) -> bool {
    if cell<0 || cell>=len(fp.cells) {return false}
    before:=fp.stats.removed
    ids:=[1]u64{instance}
    cell_take_out(fp,state,cell,ids[:])
    return fp.stats.removed>before
}

// Takes the instances of ids (in order) out of the collision of a cell.
@(private)
cell_take_out :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,index:int,ids:[]u64) {
    cell:=&fp.cells[index]
    shapes:=fp.shapes[cell.first:][:cell.count]
    live:=0
    for &shape in shapes {
        if shape.handle!={} && ids_have(ids,shape.instance) {
            physics.owned_shape_destroy(state,shape.handle)
            shape.handle={}
            fp.stats.removed+=1
        }
        if shape.handle!={} {live+=1}
    }
    if live==0 && cell.body!={} {
        physics.owned_body_destroy(state,cell.body)
        cell.body={}
    }
}

// Gives back to physics the hulls no shape uses any more.
hulls_sweep :: proc(fp:^Foliage_Physics,state:^physics.Physics_State) {
    for i:=len(fp.hulls)-1;i>=0;i-=1 {
        if physics.owned_hull_release(state,fp.hulls[i]) {unordered_remove(&fp.hulls,i)}
    }
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

// Keeps the bodies of the foliage of the world equal to its sources and the
// places of their entities, a budget of instances a tick.
@(step="fixed",loops="game editor",stage="simulate",after="physics_prepare",before="physics_places")
foliage_physics :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,collision:core.Ref(physics.Collision_Settings),data:core.Ref(Foliage_Data),grounds:core.Ref(Foliage_Ground),removals:core.Ref(Foliage_Removals),foliages:^core.Table(Foliage,.Read),worlds:^core.Table(core.World_Transform,.Read),kept:^core.Table(scene.Far_Kept,.Read),sources:core.Ref(scene.Simulation_Sources),assets:^host.Assets,time:core.Time,problems:^core.Problems) {
    if !state.ready || data.ptr==nil || time.resimulating {return}
    // Without settings every preset is the Default category, colliding with all.
    defaults:physics.Collision_Settings
    settings:=collision.ptr if collision.ptr!=nil else &defaults
    built:=false
    defer if built {hulls_sweep(fp,state)}
    for i:=len(fp.owners)-1;i>=0;i-=1 {
        owner:=fp.owners[i]
        f,shown:=core.get(foliages,owner.entity)
        // What stands for a section that is not loaded collides with nothing.
        if shown && f.source==owner.source && !(kept!=nil && core.has(kept,owner.entity)) {continue}
        physics_owner_clear(fp,state,owner.entity)
        unordered_remove(&fp.owners,i)
        built=true
    }
    now:[]scene.Source
    if sources.ptr!=nil {now=sources.ptr.items[:clamp(sources.ptr.count,0,scene.SOURCES_MAX)]}
    budget:=Physics_Budget{instances=PHYSICS_INSTANCES_A_TICK}
    placed:=core.join(foliages,worlds)
    for e,f,world in core.each_joined(&placed) {
        entry:=data_find(data.ptr,f.source)
        if entry==nil || (kept!=nil && core.has(kept,e)) {continue}
        ground:=ground_owner(grounds.ptr,e)
        revision:=ground!=nil?ground.revision:0
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
        } else if !owner.pending && owner.epoch==entry.epoch && owner.loads==entry.loads && owner.ground==revision && owner.transform==world.transform && owner.removed==removed {continue}
        // A source read again, a ground that changed or instances taken out build only the cells that changed.
        all:=owner.epoch!=entry.epoch || owner.transform!=world.transform
        owner.epoch,owner.loads,owner.ground,owner.transform,owner.source,owner.removed=entry.epoch,entry.loads,revision,world.transform,f.source,removed
        shapes:=make([dynamic]Type_Shape,context.temp_allocator)
        if type_shapes(fp,state,&entry.source,assets,&shapes)>0 {
            core.report(problems,e,"foliage.collision","a type of its foliage collides as its prefab or its hulls but has nothing it can collide as: give a Prefab type a prefab whose colliders are boxes, spheres, capsules, cylinders or hulls; give a Hull type a mesh with collision geometry; or raise the hulls of Physics_Settings")
        }
        // The nearest cells first, in cells from the sources.
        near:=scene.sources_near_of(now,mm.transform_matrix(world.transform),CELL_SIZE)
        budget.waiting=false
        complete,enough:=physics_owner_build(fp,state,settings,e,&entry.source,world.transform,shapes[:],ground,all,gone,len(now)>0?&near:nil,&budget)
        owner.pending=budget.waiting
        built=true
        if !enough {
            owner.loads=0
            memory_problem(problems,e,"the collision of its foliage: some cells do not collide")
        } else if !complete {
            core.report(problems,e,"foliage.physics","the simulation has no room for every collision of its foliage: some cells or instances do not collide; raise the bodies or shapes of Physics_Settings, or give fewer types a collision")
        }
    }
}
