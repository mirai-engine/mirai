package physics

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

@(private="file")
field_place :: proc(f:^Physics_Test,g:volume.Gravity,v:Maybe(volume.Volume),position:[3]f32) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.gravities,e,g)
    if v,ok:=v.?;ok {core.add(&f.volumes,e,v)}
    core.add(&f.worlds,e,core.World_Transform{transform={position=position,rotation=1,scale=1}})
    physics_test_settle(f)
    return e
}

// The level pulls down; a room without gravity replaces it inside its box,
// and a planet pulls what is near it toward its center.
@(test)
bodies_fall_with_the_gravity_of_their_place :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.fields=true
    field_place(&f,volume.GRAVITY_DEFAULT,nil,{})
    field_place(&f,volume.Gravity{zone={priority=1}},volume.box({5,5,5}),{20,0,0})
    field_place(&f,volume.Gravity{pull=.Center,acceleration=5,radius=2,zone={priority=1}},volume.sphere(10),{-40,0,0})
    rigid:=RIGID_BODY_DYNAMIC
    rigid.mass=1
    falling:=physics_test_box(&f,{0,0,0},{0.2,0.2,0.2},rigid)
    floating:=physics_test_box(&f,{20,0,0},{0.2,0.2,0.2},rigid)
    orbiting:=physics_test_box(&f,{-40,4,0},{0.2,0.2,0.2},rigid)
    for _ in 0..<30 {physics_test_step(&f)}
    testing.expect(t,physics_test_pose(&f,falling).position.y< -1,"the level pulls down")
    testing.expect(t,abs(physics_test_pose(&f,floating).position.y)<1e-3,"the room has none")
    at:=physics_test_pose(&f,orbiting).position
    testing.expect(t,at.y<4 && at.y>2 && abs(at.x+40)<1e-3,"the planet pulls toward its center")
    testing.expect_value(t,gravity_of_entity(core.ref(&f.state),floating),[3]f32{})
    testing.expect_value(t,gravity(core.ref(&f.state)),[3]f32{0,-9.81,0})
}

// A planet at the centre of the world that rules everywhere pulls each body
// toward it; the gravity of the world, which nothing that pulls toward a
// center has away from a place, is the default and not what the planet
// pulls at its own center, nothing.
@(test)
a_planet_at_the_origin_pulls_bodies_and_leaves_the_gravity_of_the_world :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.fields=true
    field_place(&f,volume.Gravity{pull=.Center,acceleration=9.81,radius=20},nil,{})
    rigid:=RIGID_BODY_DYNAMIC
    rigid.mass=1
    above:=physics_test_box(&f,{0,25,0},{0.2,0.2,0.2},rigid)
    beside:=physics_test_box(&f,{-25,0,0},{0.2,0.2,0.2},rigid)
    physics_test_step(&f)
    testing.expect_value(t,gravity(core.ref(&f.state)),sim.world_desc_default().gravity)
    toward:=gravity_of_entity(core.ref(&f.state),beside)
    testing.expectf(t,toward.x>5 && abs(toward.y)<1e-3,"the body beside the planet falls toward it: %v",toward)
    for _ in 0..<30 {physics_test_step(&f)}
    testing.expect(t,physics_test_pose(&f,above).position.y<25 && physics_test_pose(&f,beside).position.x> -25)
}

// A planet whose radius is left at 0 pulls with its acceleration at any
// distance, instead of with nothing.
@(test)
a_center_without_a_radius_pulls_as_strong_at_any_distance :: proc(t:^testing.T) {
    g:=volume.Gravity{pull=.Center,acceleration=3}
    pose:=mm.TRANSFORM_IDENTITY
    testing.expect(t,linalg.length(volume.gravity_of(g,pose,{0,2,0})-{0,-3,0})<1e-5)
    testing.expect(t,linalg.length(volume.gravity_of(g,pose,{500,0,0})-{-3,0,0})<1e-5)
}

// Without fields that have a border or pull toward a center, the bodies fall
// with the gravity of the world and nothing is asked for any of them; the
// fields are combined again only when one changes, and then the bodies
// asleep wake if theirs changed.
@(test)
without_local_fields_a_body_costs_reading_the_gravity_of_the_world :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.fields=true
    level:=field_place(&f,volume.Gravity{acceleration=4},nil,{})
    field_place(&f,volume.Gravity{acceleration=1,zone={priority=1,mode=.Add}},volume.world(),{})
    rigid:=RIGID_BODY_DYNAMIC
    rigid.mass=1
    floor:=physics_test_box(&f,{0,-1,0},{10,0.5,10})
    resting:=physics_test_box(&f,{0,0,0},{0.4,0.4,0.4},rigid)
    _=floor
    physics_test_step(&f)
    testing.expect(t,!state_gravity_local(&f.state) && !f.state.own_gravity,"every body falls with the world")
    testing.expect_value(t,gravity(core.ref(&f.state)),[3]f32{0,-5,0})
    testing.expect_value(t,gravity_of_entity(core.ref(&f.state),resting),[3]f32{0,-5,0})
    seen:=f.state.gravity.index.seen
    for _ in 0..<240 {physics_test_step(&f)}
    testing.expect_value(t,f.state.gravity.index.seen,seen)
    body:=body_of(core.ref(&f.state),resting)
    testing.expect(t,!sim.body_is_awake(&f.state.world,body),"the body came to rest")
    // The level turns: what fell down now falls along +X, and the body wakes.
    core.edit(&f.worlds,level).rotation=mm.quat_axis_angle({0,0,1},mm.PI/2)
    physics_test_step(&f)
    testing.expect(t,linalg.length(gravity(core.ref(&f.state))-{4,-1,0})<1e-4)
    testing.expect(t,sim.body_is_awake(&f.state.world,body),"a body asleep wakes when its gravity changes")
}

@(private="file")
state_gravity_local :: proc(state:^Physics_State) -> bool {return gravity_local(&state.gravity)}
