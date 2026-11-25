package physics

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import sim "plugins:physics/runtime/sim"

// A body that rides a mount (core.Carried) has no body in the simulation, nor
// does what hangs from it: it moves with its mount and adds no shape to it,
// and a place puts its Transform under the mount. Off it, its body is made
// where it was put.
@(test)
a_rider_has_no_body_until_it_gets_off :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    hull:=physics_test_box(&f,{0,0,0},{2,0.5,1},RIGID_BODY_DYNAMIC)
    rider:=physics_test_box(&f,{5,0,0},{0.3,0.9,0.3},RIGID_BODY_DYNAMIC)
    hand:=physics_test_box(&f,{0,0.5,0},{0.1,0.1,0.1})
    core.add(&f.parents,hand,core.Parent{entity=rider})
    physics_test_step(&f)
    shapes :: proc(f:^Physics_Test,e:core.Entity) -> int {
        l:=link_find(&f.state,e)
        if l==nil || !link_made(&f.state,l) {return 0}
        out:[8]sim.Shape_Handle
        return sim.body_shapes(&f.state.world,l.body,out[:])
    }
    testing.expectf(t,shapes(&f,hull)==1 && shapes(&f,rider)==2,"before: the hull %d shapes, the rider %d",shapes(&f,hull),shapes(&f,rider))

    // It rides the hull, at its place.
    core.add(&f.carried,rider,core.Carried{by=hull})
    core.add(&f.parents,rider,core.Parent{entity=hull})
    physics_test_settle(&f)
    physics_test_place(&f,rider,{0,0,0})
    physics_test_step(&f)
    testing.expectf(t,shapes(&f,rider)==0 && shapes(&f,hull)==1,"riding: the rider %d shapes, the hull %d",shapes(&f,rider),shapes(&f,hull))
    testing.expect_value(t,physics_test_pose(&f,rider).position,[3]f32{})
    testing.expect_value(t,f.problems.count,0)

    // It gets off at an exit beside the hull.
    core.remove(&f.carried,rider)
    core.remove(&f.parents,rider)
    physics_test_settle(&f)
    physics_test_place(&f,rider,{0,0,3},at_rest=true)
    physics_test_step(&f)
    testing.expectf(t,shapes(&f,rider)==2,"off: the rider %d shapes",shapes(&f,rider))
    l:=link_find(&f.state,rider)
    testing.expect(t,l!=nil && linalg.length(sim.body_position(&f.state.world,l.body)-[3]f32{0,0,3})<1e-3)
    testing.expect(t,linalg.length(physics_test_pose(&f,rider).position-[3]f32{0,0,3})<1e-3)
    testing.expect_value(t,f.problems.count,0)
}
