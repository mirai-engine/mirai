package foliage

import "core:slice"
import "mirai:core"
import "mirai:host"
import render "mirai:engine/render"
import "mirai:std/base"
import scene "mirai:engine/scene"
import mm "mirai:std/math"
import pcg "plugins:pcg/runtime"
import physics "plugins:physics/runtime"

// The collision of the foliage: a static body per cell the graph of a
// Foliage generated, at the corner of the cell, with the shapes of each
// instance of a layer that collides, made as bodies the foliage owns in the
// simulation (physics.owned_body_create). Every cell the graph keeps
// collides, however far it is from the view and at any detail: what moves
// far from every player (an NPC or a shot on a server) meets the foliage as
// near ones do, and the navmesh, built from the static collision, has the
// same obstacles whoever looks. A Foliage kept for a section that is not
// loaded (scene.Far_Kept) collides with nothing. A tick builds at most a
// budget of instances, the cells nearest the simulation sources
// (scene.Simulation_Sources) first, never the view; the others keep what
// they had, or wait. Its handles live with the world, as the simulation
// does: a copy for Play or a rollback takes both. The shapes of an instance
// are its own, so a cell that only lost instances (taken out of its graph)
// destroys theirs and touches nothing else.

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
    source:base.Asset_Id, // of its graph
    foliage:Foliage,
    epoch:u64,            // of the entry of Pcg_Data its shapes were made from
    loads:u32,
    revision,wants:u32,   // of its generated graph when its cells were built
    count:int,            // of the cells of that graph then
    transform:mm.Transform,
    pending:bool, // some of its cells wait for the budget of a tick
    full:bool,    // some of its cells are full (Physics_Cell.full)
}

// Bytes the collision of the foliage holds, by the room of its lists: what a
// copy of the world (Play, a rollback) copies of it. The bodies and shapes
// its handles name are the simulation's.
physics_bytes :: proc "contextless" (p:^Foliage_Physics) -> int {
    if p==nil {return 0}
    return size_of(Foliage_Physics)+cap(p.owners)*size_of(Physics_Owner)+cap(p.cells)*size_of(Physics_Cell)+cap(p.shapes)*size_of(Physics_Shape)+cap(p.hulls)*size_of(physics.Hull_Handle)
}

// What a tick builds of the collision of the foliage at most: instances of
// the cells that collide, the nearest a source first; the rest wait
// (waiting) for the ticks after.
PHYSICS_INSTANCES_A_TICK :: 1 << 14
Physics_Budget :: struct {
    instances:int, // left
    waiting:bool,  // some cell waits for the next tick
}
// A cell of the graph of a Foliage, with a body when an instance of it collides.
Physics_Cell :: struct {
    owner:core.Entity,
    coord:[2]i32,
    revision:u32, // of the generated cell it was built from
    built:bool,   // false while it waits for the budget of a tick or for memory
    full:bool,    // the simulation had no room for all of its shapes: it keeps those it has until it changes
    body:physics.Body_Handle,
    first,count:u32, // its shapes
}
// A shape of an instance: zero once the instance is taken out.
Physics_Shape :: struct {
    handle:physics.Shape_Handle,
    instance:u64, // its id in its cell (Placed.id)
    hash:u64,     // of where it stands and what it places (placed_hash)
}

BODY_OWNER :: physics.Body_Owner('f'|'o'<<8|'l'<<16|'i'<<24)

// The index physics keeps of the body of a cell: its coordinates.
@(private)
cell_user :: proc "contextless" (coord:[2]i32) -> u64 {return u64(u32(coord.x))|u64(u32(coord.y))<<32}

// A shape of a layer at scale 1, and where it is from the place of an instance.
Type_Shape :: struct {
    layer:u32,
    collider:physics.Collider,
    placement:mm.Mat4,
    hull:physics.Hull_Handle, // of a Hull collider, which every instance scales
}

// What an instance collides as: where it stands and what it places.
placed_hash :: proc(p:pcg.Placed) -> u64 {
    values:=[?]f32{p.position.x,p.position.y,p.position.z,real(p.rotation),imag(p.rotation),jmag(p.rotation),kmag(p.rotation),p.scale.x,p.scale.y,p.scale.z,transmute(f32)p.layer}
    what:=[1]base.Asset_Id{p.asset}
    return base.hash64(bytes_of(values[:]),base.hash64(bytes_of(what[:])))
}

// The shapes of the looks that collide, appended to out in their order: a
// mesh as its convex hulls (those of its source, or else the convex pieces
// of its triangles: physics.owned_hulls) under the preset of its Foliage; a
// prefab as its colliders, or without any, the hulls of its meshes. The
// hulls are asked of physics once for every instance and kept in fp.hulls.
// left_out: the looks that collide without what they collide as (a mesh
// that cannot be read, no room for hulls, no prefab that reads) and the
// colliders of prefabs an instance cannot have (a Mesh, a sensor). waiting:
// a mesh is still being read, and its hulls are not among them.
type_shapes :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,meshes:^physics.Collider_Meshes,app:^host.App,looks:[]Look,preset:physics.Collision_Preset,assets:^host.Assets,out:^[dynamic]Type_Shape) -> (left_out:int,waiting:bool) {
    // The hulls of what a renderer shows, each a shape of the collider placed as the renderer is.
    hulls_of :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,meshes:^physics.Collider_Meshes,app:^host.App,renderer:render.Mesh_Renderer,layer:u32,collider:physics.Collider,placement:mm.Mat4,out:^[dynamic]Type_Shape,waiting:^bool) -> bool {
        made:=make([dynamic]physics.Hull_Handle,context.temp_allocator)
        ok,wait:=physics.owned_hulls(state,meshes,app,renderer,&made)
        if wait {waiting^=true;return true}
        if !ok {return false}
        for hull in made {
            append(out,Type_Shape{layer,collider,placement,hull})
            if !slice.contains(fp.hulls[:],hull) {append(&fp.hulls,hull)}
        }
        return true
    }
    for look in looks {
        if !look.collides || look.asset=={} {continue}
        hull:=physics.collider_hull()
        hull.preset=preset
        if !look.prefab {
            if !hulls_of(fp,state,meshes,app,{mesh=look.asset},look.layer,hull,1,out,&waiting) {left_out+=1}
            continue
        }
        file:=host.assets_scene(assets,look.asset) if assets!=nil else nil
        if file==nil {left_out+=1;continue}
        parts:=make([dynamic]Prefab_Part,context.temp_allocator)
        colliders:=make([dynamic]Prefab_Collider,context.temp_allocator)
        _,skipped:=prefab_parts(file,&assets.types,&parts,&colliders)
        left_out+=skipped
        for c in colliders {
            if c.collider.kind!=.Hull {append(out,Type_Shape{look.layer,c.collider,c.placement,{}});continue}
            if !hulls_of(fp,state,meshes,app,c.renderer,look.layer,c.collider,c.placement,out,&waiting) {left_out+=1}
        }
        if len(colliders)>0 || skipped>0 {continue}
        for part in parts {
            if !hulls_of(fp,state,meshes,app,part.renderer,look.layer,hull,part.placement,out,&waiting) {left_out+=1}
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

// A shape of an instance of a layer, in the frame of the body of its cell:
// at its corner, with the rotation of the frame of the graph.
instance_shape :: proc "contextless" (shape:Type_Shape,p:pcg.Placed,corner:[3]f32,frame:mm.Transform) -> (made:physics.Owned_Shape,ok:bool) {
    s:=p.scale*[3]f32{abs(frame.scale.x),abs(frame.scale.y),abs(frame.scale.z)}
    at:=(p.position-corner)*frame.scale
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

// Whether a cell built before stands for what its graph places now but for
// instances taken out: each instance that collides has its shapes there, as
// it stood, and taking out those it no longer has makes it what is placed.
// With take, those shapes are destroyed.
@(private)
cell_only_lost :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,cell:^Physics_Cell,shapes:[]Physics_Shape,placed:[]pcg.Placed,take:bool) -> bool {
    Now :: struct {id,hash:u64}
    now:=make([dynamic]Now,0,len(placed),context.temp_allocator)
    for p in placed {if p.collides {append(&now,Now{p.id,placed_hash(p)})}}
    slice.sort_by(now[:],proc(a,b:Now) -> bool {return a.id<b.id})
    seen:=make([]bool,len(now),context.temp_allocator)
    find :: proc(now:[]Now,id:u64) -> int {
        low,high:=0,len(now)
        for low<high {mid:=(low+high)/2;if now[mid].id<id {low=mid+1} else {high=mid}}
        return low if low<len(now) && now[low].id==id else -1
    }
    for shape in shapes {
        if shape.handle=={} {continue}
        at:=find(now[:],shape.instance)
        if at<0 {continue}
        if now[at].hash!=shape.hash {return false}
        seen[at]=true
    }
    for s in seen {if !s {return false}}
    if !take {return true}
    live:=0
    for &shape in shapes {
        if shape.handle=={} {continue}
        if find(now[:],shape.instance)<0 {
            physics.owned_shape_destroy(state,shape.handle)
            shape.handle={}
            fp.stats.removed+=1
            continue
        }
        live+=1
    }
    if live==0 && cell.body!={} {
        physics.owned_body_destroy(state,cell.body)
        cell.body={}
    }
    return true
}

// Builds the body of a cell from what its graph places there, appending its shapes to fp.shapes.
@(private)
cell_body_build :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,collision:^physics.Collision_Settings,e:core.Entity,cell:^Physics_Cell,placed:[]pcg.Placed,shapes:[]Type_Shape,cell_size:f32,frame:mm.Transform) -> (fit,enough:bool) {
    fit,enough=true,true
    corner:=pcg.cell_corner(cell_size,cell.coord)
    cell.body={}
    cell.first=u32(len(fp.shapes))
    made: for p in placed {
        if !p.collides {continue}
        hash:=placed_hash(p)
        for shape in shapes {
            if shape.layer!=p.layer {continue}
            wanted,ok:=instance_shape(shape,p,corner,frame)
            if !ok {continue}
            if cell.body=={} {
                failure:physics.Owned_Error
                cell.body,failure=physics.owned_body_create(state,{BODY_OWNER,e,cell_user(cell.coord)},mm.transform_point(frame,corner),frame.rotation)
                if cell.body=={} {
                    enough=failure!=.Out_Of_Memory
                    fit=false
                    break made
                }
                fp.stats.bodies+=1
            }
            handle:=physics.owned_shape_create(state,collision,cell.body,wanted)
            if handle=={} {fit=false;continue}
            append(&fp.shapes,Physics_Shape{handle,p.id,hash})
            fp.stats.shapes+=1
        }
    }
    cell.count=u32(len(fp.shapes))-cell.first
    cell.full=!fit
    cell.built=enough
    return
}

// The bodies of the cells of one Foliage, from what its graph generated with
// the shapes of its looks (type_shapes). With all, those it had are built
// again; otherwise a cell whose generated cell did not change keeps its
// body, and one that only lost instances loses their shapes alone
// (cell_only_lost). With a budget, the cells to build go nearest the sources
// of near first while it lasts, and the others keep what they had, or wait
// without a body. A cell the simulation has no room for is full: it keeps
// what fit and is not built again until it changes. A cell the graph no
// longer keeps goes. complete is false while a cell of the Foliage is full.
physics_owner_build :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,collision:^physics.Collision_Settings,e:core.Entity,gen:^pcg.Generated_Graph,cell_size:f32,frame:mm.Transform,shapes:[]Type_Shape,all:=true,near:^scene.Sources_Near=nil,budget:^Physics_Budget=nil) -> (complete,enough:bool) {
    held:=make([dynamic]Physics_Cell,context.temp_allocator)
    held_shapes:=make([dynamic]Physics_Shape,context.temp_allocator)
    for cell in fp.cells {
        if cell.owner!=e {continue}
        kept:=cell
        kept.first=u32(len(held_shapes))
        append(&held_shapes,..fp.shapes[cell.first:][:cell.count])
        append(&held,kept)
    }
    slice.sort_by(held[:],proc(a,b:Physics_Cell) -> bool {return coord_before(a.coord,b.coord)})
    physics_cells_drop(fp,e)
    complete,enough=true,true
    // What becomes of each generated cell: kept, built now, or waiting.
    Plan :: enum u8 {Keep,Build,Wait}
    Order :: struct {cell,held:int,near:f32,plan:Plan}
    orders:=make([dynamic]Order,0,len(gen.cells),context.temp_allocator)
    matched:=make([]bool,len(held),context.temp_allocator)
    j:=0
    for &cell,k in gen.cells {
        for j<len(held) && coord_before(held[j].coord,cell.coord) {j+=1}
        h:=j<len(held) && held[j].coord==cell.coord?j:-1
        if h>=0 {matched[h]=true}
        order:=Order{cell=k,held=h,plan=.Build}
        if !cell.built {order.plan=.Keep}
        else if h>=0 && !all && held[h].built {
            c:=&held[h]
            if c.revision==cell.revision || cell_only_lost(fp,state,c,held_shapes[c.first:][:c.count],cell.placed[:],false) {order.plan=.Keep}
        }
        if order.plan==.Build && near!=nil {
            low,high:=cell_box(cell_size,cell.coord)
            order.near=scene.box_near(near,low,high)
        }
        append(&orders,order)
    }
    // Those the graph no longer keeps go.
    for &c,h in held {
        if matched[h] {continue}
        physics.owned_body_destroy(state,c.body)
    }
    if budget!=nil {
        building:=make([dynamic]scene.Resident_Order,context.temp_allocator)
        for o,k in orders {if o.plan==.Build {append(&building,scene.Resident_Order{near=o.near,index=u32(k)})}}
        slice.sort_by(building[:],proc(a,b:scene.Resident_Order) -> bool {return a.near<b.near || a.near==b.near && a.index<b.index})
        for b in building {
            o:=&orders[b.index]
            if budget.instances<=0 {o.plan=.Wait;budget.waiting=true;continue}
            collides:=0
            for p in gen.cells[o.cell].placed {collides+=int(p.collides)}
            budget.instances-=max(collides,1)
        }
    }
    for o in orders {
        cell:=&gen.cells[o.cell]
        switch o.plan {
        case .Keep,.Wait:
            if o.held<0 {
                if o.plan==.Wait || cell.built {append(&fp.cells,Physics_Cell{owner=e,coord=cell.coord,first=u32(len(fp.shapes))})}
                continue
            }
            kept:=held[o.held]
            if o.plan==.Keep && cell.built && kept.built && kept.revision!=cell.revision {
                cell_only_lost(fp,state,&kept,held_shapes[kept.first:][:kept.count],cell.placed[:],true)
                kept.revision=cell.revision
            }
            first:=u32(len(fp.shapes))
            append(&fp.shapes,..held_shapes[kept.first:][:kept.count])
            kept.first=first
            append(&fp.cells,kept)
            complete&&=!kept.full
        case .Build:
            if o.held>=0 {physics.owned_body_destroy(state,held[o.held].body)}
            made:=Physics_Cell{owner=e,coord=cell.coord,revision=cell.revision}
            fit,room:=cell_body_build(fp,state,collision,e,&made,cell.placed[:],shapes,cell_size,frame)
            complete&&=fit
            enough&&=room
            append(&fp.cells,made)
        }
    }
    return
}

// Forgets the cells of a Foliage, without destroying their bodies.
@(private)
physics_cells_drop :: proc(fp:^Foliage_Physics,e:core.Entity) {
    kept:=0
    shapes:=0
    for cell in fp.cells {
        if cell.owner==e {continue}
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

// Destroys the bodies of a Foliage and forgets its cells.
physics_owner_clear :: proc(fp:^Foliage_Physics,state:^physics.Physics_State,e:core.Entity) {
    for cell in fp.cells {if cell.owner==e {physics.owned_body_destroy(state,cell.body)}}
    physics_cells_drop(fp,e)
}

// Gives back to physics the hulls no shape uses any more.
hulls_sweep :: proc(fp:^Foliage_Physics,state:^physics.Physics_State) {
    for i:=len(fp.hulls)-1;i>=0;i-=1 {
        if physics.owned_hull_release(state,fp.hulls[i]) {unordered_remove(&fp.hulls,i)}
    }
}

// The instance of a Foliage a hit of physics met, as pcg_suppress_request
// and foliage_promote take it; false for anything else.
hit_of :: proc(state:core.Ref(physics.Physics_State),hit:physics.Hit) -> (found:pcg.Pcg_Instance,ok:bool) {
    return shape_instance(state.ptr,hit.body,hit.shape)
}

@(private)
shape_instance :: proc(state:^physics.Physics_State,body:physics.Body_Handle,shape:physics.Shape_Handle) -> (found:pcg.Pcg_Instance,ok:bool) {
    cell:=physics.owned_body_of(state,body) or_return
    if cell.owner!=BODY_OWNER {return}
    instance:=physics.owned_shape_user(state,shape) or_return
    return {cell.entity,{i32(u32(cell.user)),i32(u32(cell.user>>32))},instance},true
}

// Keeps the bodies of the foliage of the world equal to what their graphs
// place and the frames of their cells, a budget of instances a tick.
@(step="fixed",loops="game editor",stage="simulate",after="physics_prepare pcg_update",before="physics_places")
foliage_physics :: proc(
    fp:^Foliage_Physics,state:^physics.Physics_State,meshes:^physics.Collider_Meshes,app:^host.App,collision:core.Ref(physics.Collision_Settings),
    data:core.Ref(pcg.Pcg_Data),generated:core.Ref(pcg.Pcg_Generated),foliages:^core.Table(Foliage,.Read),graphs:^core.Table(pcg.Pcg_Graph,.Read),
    worlds:^core.Table(core.World_Transform,.Read),kept:^core.Table(scene.Far_Kept,.Read),sources:core.Ref(scene.Simulation_Sources),assets:^host.Assets,time:core.Time,problems:^core.Problems,
) {
    if !state.ready || data.ptr==nil || time.resimulating {return}
    // Without settings every preset is the Default category, colliding with all.
    defaults:physics.Collision_Settings
    settings:=collision.ptr if collision.ptr!=nil else &defaults
    built:=false
    defer if built {hulls_sweep(fp,state)}
    for i:=len(fp.owners)-1;i>=0;i-=1 {
        owner:=fp.owners[i]
        graph,graphed:=core.get(graphs,owner.entity)
        // What stands for a section that is not loaded collides with nothing.
        if core.has(foliages,owner.entity) && graphed && graph.source==owner.source && !(kept!=nil && core.has(kept,owner.entity)) {continue}
        physics_owner_clear(fp,state,owner.entity)
        unordered_remove(&fp.owners,i)
        built=true
    }
    now:[]scene.Source
    if sources.ptr!=nil {now=sources.ptr.items[:clamp(sources.ptr.count,0,scene.SOURCES_MAX)]}
    budget:=Physics_Budget{instances=PHYSICS_INSTANCES_A_TICK}
    looks:=make([dynamic]Look,context.temp_allocator)
    for row in 0..<core.count(foliages) {
        e:=core.entity_at(foliages,row)
        f:=core.at(foliages,row)
        graph,graphed:=core.get(graphs,e)
        world,placed:=core.get(worlds,e)
        if !graphed || !placed || (kept!=nil && core.has(kept,e)) {continue}
        entry:=pcg.data_find(data.ptr,graph.source)
        gen:=pcg.generated_graph(generated.ptr,e)
        if entry==nil || gen==nil {continue}
        frame:=pcg.graph_frame(graph,world.transform)
        owner:^Physics_Owner
        for &held in fp.owners {if held.entity==e {owner=&held;break}}
        if owner==nil {
            if _,err:=append(&fp.owners,Physics_Owner{entity=e,source=graph.source}); err!=nil {
                memory_problem(problems,e,"the collision of its foliage, which does not collide")
                continue
            }
            owner=&fp.owners[len(fp.owners)-1]
        } else if !owner.pending && owner.epoch==entry.epoch && owner.loads==entry.loads && owner.foliage==f && owner.transform==frame && owner.revision==gen.revision && owner.wants==gen.wants && owner.count==len(gen.cells) {
            if owner.full {room_problem(problems,e)}
            continue
        }
        // A graph that places otherwise builds only the cells that changed.
        all:=owner.epoch!=entry.epoch || owner.loads!=entry.loads || owner.foliage!=f || owner.transform!=frame
        owner.epoch,owner.loads,owner.foliage,owner.transform,owner.source=entry.epoch,entry.loads,f,frame,graph.source
        owner.revision,owner.wants,owner.count=gen.revision,gen.wants,len(gen.cells)
        if !looks_make(&looks,&entry.source,f,assets) {
            memory_problem(problems,e,"the collision of its foliage, which does not collide")
            owner.loads=0
            continue
        }
        shapes:=make([dynamic]Type_Shape,context.temp_allocator)
        left_out,reading:=type_shapes(fp,state,meshes,app,looks[:],f.preset,assets,&shapes)
        if reading {
            // Its cells are built once the meshes of its hulls are read.
            owner.pending=true
            built=true
            continue
        }
        if left_out>0 {
            core.report(problems,e,"foliage.collision","a layer of its graph collides but what it places has nothing it can collide as: give it a mesh of the assets that reads, or a prefab whose colliders are boxes, spheres, capsules, cylinders or hulls; or raise the hulls of Physics_Settings")
        }
        // The nearest cells first, in cells from the sources.
        near:=scene.sources_near_of(now,mm.transform_matrix(frame),entry.source.info.cell_size)
        budget.waiting=false
        complete,enough:=physics_owner_build(fp,state,settings,e,gen,entry.source.info.cell_size,frame,shapes[:],all,len(now)>0?&near:nil,&budget)
        owner.pending,owner.full=budget.waiting,!complete
        built=true
        if !enough {
            owner.loads=0
            memory_problem(problems,e,"the collision of its foliage: some cells do not collide")
        } else if !complete {
            room_problem(problems,e)
        }
    }
}

@(private)
room_problem :: proc(problems:^core.Problems,e:core.Entity) {
    core.report(problems,e,"foliage.physics","the simulation has no room for every collision of its foliage: some cells or instances do not collide; raise the bodies or shapes of Physics_Settings, or give fewer layers a collision")
}
