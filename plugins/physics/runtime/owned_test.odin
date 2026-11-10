package physics

import "core:testing"
import "mirai:core"

// A library makes a static body of its own with a shape: the bodies of the entities rest on it, a hit on it
// says whose it is and which, a copy of the simulation knows it too, and only its owner ends it.
@(test)
a_library_makes_and_ends_bodies_of_its_own :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.gravity={0,-9.81,0}
    box:=physics_test_box(&f,{0,2,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
    ground:=core.create(&f.entities)
    _,no_simulation:=owned_body_create(&f.state,{7,ground,42},{},1)
    testing.expect_value(t,no_simulation,Owned_Error.Invalid)
    physics_test_step(&f,0)
    _,no_owner:=owned_body_create(&f.state,{0,ground,42},{},1)
    testing.expect_value(t,no_owner,Owned_Error.Invalid)
    body,error:=owned_body_create(&f.state,{7,ground,42},{0,-1,0},1)
    if !testing.expect(t,body!={} && error==.None) {return}
    shape:=owned_shape_create(&f.state,&f.collision,body,{collider=collider_box({5,0.5,5}),position={0,0.5,0},rotation=1,user=9})
    testing.expect(t,shape!={})
    testing.expect(t,owned_shape_create(&f.state,&f.collision,body,{collider=collider_hull(),rotation=1})=={},"a primitive only")
    for _ in 0..<120 {physics_test_step(&f)}
    testing.expect(t,abs(physics_test_pose(&f,box).position.y-0.5)<0.02,"the box rests on it")

    hit,found:=raycast(core.ref(&f.state),{3,5,3},{0,-1,0},10)
    testing.expect(t,found && hit.entity==ground && hit.body==body && hit.shape==shape)
    // The box as if it were 20 m up, where nothing is now: only a ray asked at that pose hits it.
    _,nothing:=raycast(core.ref(&f.state),{0,25,0},{0,-1,0},4)
    testing.expect(t,!nothing)
    lifted,up:=raycast_at(core.ref(&f.state),box,{0,20,0},1,{0,25,0},{0,-1,0},10)
    testing.expect(t,up && lifted.entity==box && abs(lifted.distance-4.5)<0.01)
    for direction in ([][3]f32{{},{0,transmute(f32)u32(0x7fc00000),0}}) {
        _,up=raycast_at(core.ref(&f.state),box,{0,20,0},1,{0,25,0},direction,10)
        testing.expect(t,!up)
    }
    _,up=raycast_at(core.ref(&f.state),core.Entity(987654),{0,20,0},1,{0,25,0},{0,-1,0},10)
    testing.expect(t,!up)
    owned,is_owned:=owned_body_of(&f.state,hit.body)
    testing.expect(t,is_owned && owned==Owned_Body{7,ground,42})
    user,has_user:=owned_shape_user(&f.state,hit.shape)
    testing.expect(t,has_user && user==9)

    // The body of an entity is nobody's to end.
    of_entity:=body_of(core.ref(&f.state),box)
    _,is_owned=owned_body_of(&f.state,of_entity)
    testing.expect(t,!is_owned && !owned_body_destroy(&f.state,of_entity) && body_of(core.ref(&f.state),box)==of_entity)

    seen:u32
    testing.expect(t,!simulation_replaced(&f.state,&seen))
    copied:Physics_State
    defer state_destroy(&copied)
    if !testing.expect(t,state_copy(&copied,&f.state)) {return}
    owned,is_owned=owned_body_of(&copied,body)
    testing.expect(t,is_owned && owned.user==42 && simulation_replaced(&copied,&seen) && !simulation_replaced(&copied,&seen))

    testing.expect(t,owned_shape_destroy(&f.state,shape) && !owned_shape_destroy(&f.state,shape))
    testing.expect(t,owned_body_destroy(&f.state,body) && !owned_body_destroy(&f.state,body))
    _,is_owned=owned_body_of(&f.state,body)
    testing.expect(t,!is_owned)
    testing.expect_value(t,f.problems.count,0)
}
