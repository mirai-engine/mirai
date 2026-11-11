package physics

import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/spatial"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

@(test)
a_teleport_is_a_jump_by_what_takes_the_body_from_where_it_was :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    jumps:core.Jumps
    defer delete(jumps.queue.items)
    box:=physics_test_box(&f,{1,2,3},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
    physics_test_step(&f,0)

    teleport(&f.requests,box,{10,2,-4},mm.quat_axis_angle({0,1,0},math.PI/2))
    physics_test_settle(&f)
    physics_step(
        &f.state,core.ref(&f.settings),&f.requests,&f.events,&f.meshes,&f.app,{},
        core.read(&f.rigids),core.read(&f.colliders),core.read(&f.characters),core.read(&f.moves),
        &f.joints,core.read(&f.statics),core.read(&f.parents),core.read(&f.names),
        &f.transforms,&f.bodies,core.read(&f.replicas),&f.character_states,&f.joint_states,{},nil,{},{},nil,&jumps,&f.problems,{},{},{},{},{},core.ref(&f.hierarchy),{},{},{},{},
    )
    physics_test_settle(&f)
    testing.expect_value(t,f.state.stats.teleports,u64(1))
    if !testing.expect_value(t,len(jumps.queue.items),1) {return}
    jumped:=jumps.queue.items[0]
    testing.expect(t,jumped.entity==box)
    // Where the body was is taken to where it was put, turned as it was turned.
    testing.expect(t,linalg.length(mm.transform_point(jumped.by,{1,2,3})-[3]f32{10,2,-4})<1e-4)
    testing.expect(t,linalg.length(mm.quat_rotate(jumped.by.rotation,[3]f32{0,0,1})-[3]f32{1,0,0})<1e-4)
    testing.expect(t,linalg.length(physics_test_pose(&f,box).position-[3]f32{10,2,-4})<1e-4)

    // Who steps the simulation by hand, without jumps, is asked for none.
    teleport(&f.requests,box,{0,2,0})
    physics_test_step(&f,0)
    testing.expect_value(t,len(jumps.queue.items),1)
    testing.expect_value(t,f.state.stats.teleports,u64(2))
}

// A place at rest stops the body it puts; one that is not keeps its velocity.
@(test)
a_place_at_rest_stops_the_body :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    places:core.Places
    defer delete(places.queue.items)
    box:=physics_test_box(&f,{1,2,3},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
    physics_test_step(&f,0)
    body:=link_find(&f.state,box).body
    cases:=[]struct{at_rest:bool,velocity:[3]f32}{{false,{5,0,0}},{true,{}}}
    for c,i in cases {
        set_velocity(&f.requests,box,{5,0,0})
        physics_test_step(&f,0)
        core.push(&places.queue,core.Place_Request{box,{f32(i),2,0},1,c.at_rest})
        physics_places(&places,&f.requests,core.ref(&f.state),core.read(&f.rigids),core.read(&f.characters))
        physics_test_step(&f,0)
        testing.expect_value(t,sim.body_linear_velocity(&f.state.world,body),c.velocity)
        testing.expect(t,linalg.length(physics_test_pose(&f,box).position-[3]f32{f32(i),2,0})<1e-4)
    }
}

// A body that passes to another parent where it is (a section that it left
// gives it to the next) stays where the simulation has it: no teleport and
// no write of another function.
@(test)
a_body_that_changes_parent_where_it_is_is_no_teleport :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    box:=physics_test_box(&f,{5,0,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
    physics_test_step(&f)
    section:=core.create(&f.entities)
    core.add(&f.transforms,section,core.Transform{{10,0,0},1,{1,1,1}})
    core.add(&f.parents,box,core.Parent{entity=section})
    core.edit(&f.transforms,box).position-={10,0,0}
    physics_test_step(&f)
    physics_test_step(&f)
    testing.expect_value(t,f.state.stats.teleports,u64(0))
    world,_:=core.world_of(core.read(&f.transforms),core.read(&f.parents),box)
    testing.expect(t,abs(world.position.x-5)<1e-3,"it stays where it was")
}

// While it plays, a write that only turns a Character is not taken, and the
// problem says how to turn it; one that puts it elsewhere is a teleport.
@(test)
a_write_that_only_turns_a_character_is_a_problem_that_says_how :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{{0,1,0},1,{1,1,1}})
    core.add(&f.colliders,e,collider_character())
    core.add(&f.characters,e,character_default())
    physics_test_step(&f)
    physics_test_step(&f)
    turned:=mm.quat_axis_angle({0,1,0},math.PI/2)
    core.edit(&f.transforms,e).rotation=turned
    physics_test_step(&f)
    reported:=false
    for &p in f.problems.entries[:f.problems.count] {
        if base.text_get(p.code[:])=="physics.character_turn" && p.entity==e {reported=strings.contains(base.text_get(p.text[:]),"core.place")}
    }
    testing.expect(t,reported,"the turn that is not taken is reported, with what to do")
    testing.expect(t,abs(linalg.dot(quaternion_vector(physics_test_pose(&f,e).rotation),quaternion_vector(turned)))<0.999,"the rotation stays that of the simulation")
}

@(private="file")
quaternion_vector :: proc(q:mm.Quat) -> [4]f32 {return {real(q),imag(q),jmag(q),kmag(q)}}

// A Transform or a request that is not finite is a problem of its entity, and the body stays where it was.
@(test)
values_that_are_not_finite_leave_a_body_where_it_was_with_a_problem :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    e:=physics_test_box(&f,{0,2,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
    physics_test_step(&f)
    l:=link_find(&f.state,e)
    if !testing.expect(t,l!=nil && l.kind==.Body) {return}
    was:=sim.body_position(&f.state.world,l.body)
    core.edit(&f.transforms,e).position={math.nan_f32(),2,0}
    physics_test_step(&f)
    testing.expect(t,core.problem_find(&f.problems,e,"physics.transform")!=nil)
    testing.expect_value(t,sim.body_position(&f.state.world,l.body),was)
    teleport(&f.requests,e,{0,math.inf_f32(1),0})
    apply_impulse(&f.requests,e,{math.nan_f32(),0,0})
    physics_test_step(&f)
    testing.expect(t,core.problem_find(&f.problems,e,"physics.request_value")!=nil)
    testing.expect(t,sim.finite(sim.body_position(&f.state.world,l.body),sim.body_linear_velocity(&f.state.world,l.body)))
    for &tree in f.state.world.trees {testing.expect(t,spatial.dynamic_tree_validate(&tree))}
}
