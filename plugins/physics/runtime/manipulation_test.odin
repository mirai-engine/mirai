package physics

import "core:testing"
import "mirai:core"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

@(private)
Physics_Test_World :: struct {
    using world:core.Test_World,
    using physics:Test_Physics,
}

@(private)
Physics_Test :: struct {
    using w:Physics_Test_World,
    using host:Test_Physics_Host,
}

@(private)
physics_test_init :: proc(t:^testing.T,f:^Physics_Test) -> bool {
    if !core.test_world_init(t,&f.w,test_types) {return false}
    f.settings={bodies=32,shapes=32,contacts=128,joints=8,characters=2}
    return true
}

@(private)
physics_test_destroy :: proc(f:^Physics_Test) {
    test_host_destroy(&f.host)
    core.test_world_destroy(&f.w)
}

@(private)
physics_test_settle :: proc(f:^Physics_Test) {core.test_world_settle(&f.w)}

@(private)
physics_test_step :: proc(f:^Physics_Test,dt:f32=1.0/60) {
    physics_test_settle(f)
    physics_test_run(f,dt)
    physics_test_settle(f)
}

// physics_step alone, on the rows as they are.
@(private)
physics_test_run :: proc(f:^Physics_Test,dt:f32) {test_step(&f.physics,&f.host,dt)}

@(private)
physics_test_box :: proc(f:^Physics_Test,position,half:[3]f32,rigid:Maybe(Rigid_Body)=nil) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{position,1,{1,1,1}})
    core.add(&f.colliders,e,collider_box(half))
    if body,has:=rigid.?;has {core.add(&f.rigids,e,body)}
    return e
}

// A Joint on an entity of its own under a, at a place relative to it.
@(private)
physics_test_joint :: proc(f:^Physics_Test,a:core.Entity,at:[3]f32,joint:Joint,rotation:=mm.Quat(1)) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{at,rotation,{1,1,1}})
    core.add(&f.parents,e,core.Parent{entity=a})
    core.add(&f.joints,e,joint)
    return e
}

@(private)
physics_test_pose :: proc(f:^Physics_Test,e:core.Entity) -> core.Transform {
    pose,_:=core.get(&f.transforms,e)
    return pose
}

@(test)
moving_a_collider_only_wall_pushes_bodies_then_restores_static_motion :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    wall:=physics_test_box(&f,{0,0,0},{0.5,2,2})
    box:=physics_test_box(&f,{1.1,0,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
    physics_test_step(&f,0)
    testing.expect_value(t,manipulation_owner(core.ref(&f.state),wall),wall)
    wall_body:=body_of(core.ref(&f.state),wall)
    for tick in 1..=30 {
        manipulation_target(&f.requests,wall,{f32(tick)/30,0,0})
        physics_test_step(&f)
    }
    moved:=physics_test_pose(&f,box).position.x
    testing.expect(t,moved>1.9)
    testing.expect_value(t,sim.body_type(&f.state.world,wall_body),Body_Type.Kinematic)
    testing.expect(t,abs(physics_test_pose(&f,wall).position.x-1)<0.001)
    for _ in 0..<10 {physics_test_step(&f)}
    testing.expect(t,abs(sim.body_position(&f.state.world,wall_body).x-1)<0.001)
    manipulation_target(&f.requests,wall,{1.1,0,0})
    manipulation_end(&f.requests,wall)
    physics_test_step(&f)
    testing.expect_value(t,sim.body_type(&f.state.world,wall_body),Body_Type.Static)
    testing.expect(t,abs(physics_test_pose(&f,wall).position.x-1.1)<0.001)
    testing.expect(t,!core.has(&f.rigids,wall))
    testing.expect_value(t,f.state.stats.teleports,u64(0))
    testing.expect_value(t,f.problems.count,0)
}

@(test)
held_dynamic_bodies_restore_mass_gravity_and_copy_their_manipulation_state :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.gravity={0,-9.81,0}
    rigid:=RIGID_BODY_DYNAMIC
    rigid.mass=5
    box:=physics_test_box(&f,{0,3,0},{0.5,0.5,0.5},rigid)
    physics_test_step(&f,0)
    body:=body_of(core.ref(&f.state),box)
    manipulation_target(&f.requests,box,{1,3,0})
    physics_test_step(&f)
    copied:Physics_State
    state_copy(&copied,&f.state)
    defer state_destroy(&copied)
    testing.expect(t,.Manipulation in link_find(&copied,box).hold.by)
    testing.expect_value(t,sim.body_type(&copied.world,body),Body_Type.Kinematic)
    for _ in 0..<10 {physics_test_step(&f)}
    testing.expect(t,abs(physics_test_pose(&f,box).position.y-3)<0.001)
    manipulation_target(&f.requests,box,{2,3,0})
    manipulation_end(&f.requests,box)
    physics_test_step(&f)
    actual_rigid,_:=core.get(&f.rigids,box)
    testing.expect_value(t,actual_rigid,rigid)
    testing.expect_value(t,sim.body_type(&f.state.world,body),Body_Type.Dynamic)
    testing.expect_value(t,sim.body_mass(&f.state.world,body),f32(5))
    testing.expect_value(t,sim.body_linear_velocity(&f.state.world,body),[3]f32{})
    testing.expect(t,abs(physics_test_pose(&f,box).position.x-2)<0.001)
    for _ in 0..<10 {physics_test_step(&f)}
    testing.expect(t,physics_test_pose(&f,box).position.y<2.9)
}

@(test)
manipulation_resolves_compounds_and_world_rotation_under_a_scaled_parent :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    parent:=core.create(&f.entities)
    core.add(&f.transforms,parent,core.Transform{{10,0,0},mm.quat_axis_angle({0,1,0},0.6),{2,3,4}})
    root:=physics_test_box(&f,{1,1,1},{0.5,0.5,0.5},RIGID_BODY_STATIC)
    core.add(&f.parents,root,core.Parent{parent,0})
    child:=physics_test_box(&f,{1,0,0},{0.2,0.2,0.2})
    core.add(&f.parents,child,core.Parent{root,0})
    physics_test_step(&f,0)
    testing.expect_value(t,manipulation_owner(core.ref(&f.state),child),root)
    target:=mm.quat_axis_angle({0,0,1},0.3)
    manipulation_target(&f.requests,root,{11,4,2},target)
    physics_test_step(&f,0)
    pose,ok:=core.world_of(core.read(&f.transforms),core.read(&f.parents),root)
    testing.expect(t,ok)
    wanted:=[3]f32{11,4,2}
    for i in 0..<3 {testing.expect(t,abs(pose.position[i]-wanted[i])<0.001)}
    testing.expect(t,abs(pose.rotation.w-target.w)<0.001)
    manipulation_end(&f.requests,root)
    physics_test_step(&f,0)
    testing.expect_value(t,sim.body_type(&f.state.world,body_of(core.ref(&f.state),root)),Body_Type.Static)
    testing.expect(t,!step_world({},&f.app,0))
}

@(test)
large_manipulations_reach_the_target_before_releasing_and_can_return :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    wall:=physics_test_box(&f,{0,0,0},{0.5,0.5,0.5})
    physics_test_step(&f,0)
    body:=body_of(core.ref(&f.state),wall)
    rotation:=mm.quat_axis_angle({0,1,0},2)
    manipulation_target(&f.requests,wall,{50,0,0},rotation)
    manipulation_end(&f.requests,wall)
    physics_test_step(&f)
    testing.expect_value(t,sim.body_type(&f.state.world,body),Body_Type.Kinematic)
    testing.expect(t,sim.body_position(&f.state.world,body).x<10)
    for _ in 0..<30 {physics_test_step(&f)}
    testing.expect_value(t,sim.body_type(&f.state.world,body),Body_Type.Static)
    testing.expect(t,abs(sim.body_position(&f.state.world,body).x-50)<0.001)
    testing.expect(t,!pose_differs(sim.body_transform(&f.state.world,body),{p={50,0,0},q=rotation}))
    manipulation_target(&f.requests,wall,{0,0,0})
    manipulation_end(&f.requests,wall)
    for _ in 0..<30 {physics_test_step(&f)}
    testing.expect_value(t,sim.body_type(&f.state.world,body),Body_Type.Static)
    testing.expect(t,!pose_differs(sim.body_transform(&f.state.world,body),{q=1}))
    testing.expect_value(t,f.state.stats.teleports,u64(0))
}
