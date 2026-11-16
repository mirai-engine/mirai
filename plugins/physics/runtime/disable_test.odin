package physics

import "core:testing"
import "mirai:core"

// A body whose components are off leaves the simulation where it was, and on
// again it comes back with the velocity it had.
@(test)
a_body_turned_off_stops_and_comes_back_with_its_velocity :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    box:=physics_test_box(&f,{0,10,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
    core.add(&f.bodies,box,core.Motion{linear={0,0,-3}}) // the fixture has no gravity
    for _ in 0..<10 {physics_test_step(&f)}
    state,moving:=core.get(&f.bodies,box)
    testing.expect(t,moving && state.linear.z< -2.9)
    falling:=state.linear

    core.disable(&f.rigids,box);core.disable(&f.colliders,box)
    physics_test_step(&f)
    testing.expect(t,link_find(&f.state,box)==nil,"the body left the simulation")
    stopped:=physics_test_pose(&f,box)
    for _ in 0..<10 {physics_test_step(&f)}
    testing.expect_value(t,physics_test_pose(&f,box),stopped)
    kept,_:=core.get(&f.bodies,box)
    testing.expect_value(t,kept.linear,falling)

    core.enable(&f.rigids,box);core.enable(&f.colliders,box)
    physics_test_step(&f)
    testing.expect(t,link_find(&f.state,box)!=nil)
    back,_:=core.get(&f.bodies,box)
    testing.expect(t,back.linear.z< -2.9,"it keeps the velocity it had")
    testing.expect(t,physics_test_pose(&f,box).position.z<stopped.position.z,"from where it was")
}
