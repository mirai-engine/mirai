package physics

import "core:math/linalg"
import "mirai:core"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

// What looks into the world without knowing physics (the arm of a camera, the
// feet of a rig) casts against the shapes of its simulation; none until it is ready.
query_of :: proc(state:^Physics_State) -> (core.World_Query,bool) {
    if state==nil || !state.ready {return {},false}
    return {user=state,probe=query_probe,support=query_support,solid=query_solid},true
}

@(private)
query_open :: proc(w:core.World_Ref) -> (core.World_Query,bool) {
    return query_of(core.world_storage_of(w,Physics_State))
}

@(private)
query_probe :: proc(user:rawptr,origin,direction:[3]f32,length,radius:f32,ignore:core.Entity,mask:u32) -> (found:core.World_Hit,ok:bool) {
    state:=core.ref(cast(^Physics_State)user)
    filter:=QUERY_FILTER_DEFAULT
    filter.filter.block=Collision_Layers(mask)
    if linalg.length(direction)<1e-12 {return}
    hit:Hit
    if radius>0 {
        hit=sweep(state,Sphere{radius},origin,1,direction,length,ignore,filter) or_return
    } else {hit=raycast(state,origin,direction,length,ignore,filter) or_return}
    support:=sim.body_transform(&state.world,hit.body)
    return {hit.point,hit.normal,hit.distance,hit.entity,u64(hit.body),{support.p,support.q,{1,1,1}}},true
}

@(private)
query_support :: proc(user:rawptr,id:u64) -> (mm.Transform,bool) {
    state:=cast(^Physics_State)user
    body:=sim.Body_Handle(id)
    if !sim.body_valid(&state.world,body) {return {},false}
    transform:=sim.body_transform(&state.world,body)
    return {transform.p,transform.q,{1,1,1}},true
}

@(private)
query_solid :: proc(user:rawptr,e:core.Entity) -> bool {
    return body_of(core.ref(cast(^Physics_State)user),e)!=0
}

// The triangles of the static collision whose boxes meet `box`, in world space, that block `filter`, for
// whoever builds from the level (a navmesh): the rules of sim.shapes_triangles. colliders, when not empty,
// takes the entity of the Collider of each triangle and limits how many fit. Nothing while the simulation
// is not ready.
static_triangles :: proc(physics:core.Ref(Physics_State),box:mm.Aabb,vertices:[][3]f32,indices:[]u32,filter:=QUERY_FILTER_DEFAULT,colliders:[]core.Entity=nil) -> (vertex_count,index_count:int,complete:bool) {
    if physics.ptr==nil || !physics.ready {return 0,0,true}
    world:=&physics.world
    #assert(size_of(core.Entity)==size_of(sim.Shape_Handle))
    // The shapes go where their entities will be, each read before it is replaced.
    shapes:=transmute([]sim.Shape_Handle)colliders
    vertex_count,index_count,complete=sim.shapes_triangles(world,box,vertices,indices,filter,shapes)
    if len(colliders)>0 {
        for i in 0..<index_count/3 {colliders[i]=core.Entity(sim.shape_user_data(world,shapes[i]))}
    }
    return
}

// Where a reader of static_changes is: the simulation it read and how far. The zero cursor has read nothing.
Static_Cursor :: struct {
    epoch:u32,
    next:u64,
}

// The boxes where the static collision changed since the cursor, oldest first, by the rules of
// sim.static_changes, and the cursor to read from next. overflow also when the simulation of the world was
// made again, copied or swapped since the cursor was taken: the reader takes everything as changed. Nothing
// while the simulation is not ready.
static_changes :: proc(physics:core.Ref(Physics_State),since:Static_Cursor,boxes:[]mm.Aabb) -> (next:Static_Cursor,count:int,overflow:bool) {
    if physics.ptr==nil || !physics.ready {return since,0,false}
    // A cursor of another simulation is ahead of any log, which overflows.
    at:=since.epoch==physics.epoch?since.next:max(u64)
    at,count,overflow=sim.static_changes(&physics.world,at,boxes)
    return {physics.epoch,at},count,overflow
}

// The box around the static collision that blocks, without sensors, as of the last physics_step; false without
// any or while the simulation is not ready.
static_bounds :: proc(physics:core.Ref(Physics_State)) -> (box:mm.Aabb,ok:bool) {
    if physics.ptr==nil || !physics.ready {return}
    return sim.static_bounds(&physics.world)
}
