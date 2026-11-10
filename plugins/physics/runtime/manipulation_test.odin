package physics

import "core:testing"
import "mirai:core"
import "mirai:host"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

@(private)
Physics_Test :: struct {
    entities:core.Entities,
    gravity:[3]f32, // of its world: none unless a test gives it, or fields does
    fields:^Physics_Test_Fields,
    rigids:core.Table(Rigid_Body),
    colliders:core.Table(Collider),
    characters:core.Table(Character),
    moves:core.Table(Character_Move),
    joints:core.Table(Joint),
    statics:core.Table(render.Mesh_Renderer),
    parents:core.Table(core.Parent),
    hierarchy:core.Hierarchy,
    whole:bool, // physics_step gets no hierarchy: every sync goes through every body
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    bodies:core.Table(core.Motion),
    replicas:core.Table(core.Pose_Target),
    character_states:core.Table(Character_State),
    joint_states:core.Table(Joint_State),
    volumes:core.Table(Fluid_Volume),
    state:Physics_State,
    settings:Physics_Settings,
    collision:Collision_Settings,
    sync_check:core.Sync_Check,
    simulation_hash:core.Simulation_Hash,
    requests:Body_Requests,
    joint_requests:Joint_Requests,
    events:Physics_Events,
    meshes:Collider_Meshes,
    app:host.App,
    problems:core.Problems,
}

@(private)
physics_test_init :: proc(f:^Physics_Test) {
    core.entities_init(&f.entities)
    core.table_init(&f.rigids,"Rigid_Body")
    core.table_init(&f.colliders,"Collider")
    core.table_init(&f.characters,"Character")
    core.table_init(&f.moves,"Character_Move")
    core.table_init(&f.joints,"Joint")
    core.table_init(&f.statics,"Mesh_Renderer")
    core.table_init(&f.parents,"Parent")
    core.table_init(&f.names,"Name")
    core.table_init(&f.transforms,"Transform")
    core.table_init(&f.bodies,"Motion")
    core.table_init(&f.replicas,"Replica")
    core.table_init(&f.character_states,"Character_State")
    core.table_init(&f.joint_states,"Joint_State")
    core.table_init(&f.volumes,"Fluid_Volume")
    f.settings={bodies=32,shapes=32,contacts=128,joints=8,characters=2}
    f.collision=COLLISION_SETTINGS_DEFAULT
}

// The Gravity of a test, with its own World_Transform: the bodies of the
// test have none.
@(private)
Physics_Test_Fields :: struct {
    gravities:core.Table(volume.Gravity),
    volumes:core.Table(volume.Volume),
    worlds:core.Table(core.World_Transform),
}

@(private)
physics_test_destroy :: proc(f:^Physics_Test) {
    state_destroy(&f.state)
    collider_meshes_destroy(&f.meshes)
    core.table_destroy(&f.rigids)
    core.table_destroy(&f.colliders)
    core.table_destroy(&f.characters)
    core.table_destroy(&f.moves)
    core.table_destroy(&f.joints)
    core.table_destroy(&f.statics)
    core.table_destroy(&f.parents)
    core.value_free(&f.hierarchy,type_info_of(core.Hierarchy))
    core.table_destroy(&f.names)
    core.table_destroy(&f.transforms)
    core.table_destroy(&f.bodies)
    core.table_destroy(&f.replicas)
    core.table_destroy(&f.character_states)
    core.table_destroy(&f.joint_states)
    core.table_destroy(&f.volumes)
    core.entities_destroy(&f.entities)
    delete(f.requests.queue.items)
    delete(f.joint_requests.queue.items)
    delete(f.events.contact_begin.items);delete(f.events.contact_end.items)
    delete(f.events.overlap_begin.items);delete(f.events.overlap_end.items)
    delete(f.events.sleep.items);delete(f.events.wake.items);delete(f.events.joint_break.items)
}

@(private)
physics_test_settle :: proc(f:^Physics_Test) {
    core.table_settle(&f.rigids,&f.entities)
    core.table_settle(&f.colliders,&f.entities)
    core.table_settle(&f.characters,&f.entities)
    core.table_settle(&f.moves,&f.entities)
    core.table_settle(&f.joints,&f.entities)
    core.table_settle(&f.statics,&f.entities)
    core.table_settle(&f.parents,&f.entities)
    core.hierarchy_settle(&f.hierarchy,core.read(&f.parents),&f.entities)
    core.table_settle(&f.names,&f.entities)
    core.table_settle(&f.transforms,&f.entities)
    core.table_settle(&f.bodies,&f.entities)
    core.table_settle(&f.replicas,&f.entities)
    core.table_settle(&f.character_states,&f.entities)
    core.table_settle(&f.joint_states,&f.entities)
    core.table_settle(&f.volumes,&f.entities)
    core.entities_settle(&f.entities)
}

@(private)
physics_test_step :: proc(f:^Physics_Test,dt:f32=1.0/60) {
    physics_test_settle(f)
    physics_test_run(f,dt)
    physics_test_settle(f)
}

// physics_step alone, on the rows as they are.
@(private)
physics_test_run :: proc(f:^Physics_Test,dt:f32) {
    gravities:core.Read(volume.Gravity);gravity_volumes:core.Read(volume.Volume);worlds:core.Read(core.World_Transform)
    if g:=f.fields;g!=nil {gravities,gravity_volumes,worlds=core.read(&g.gravities),core.read(&g.volumes),core.read(&g.worlds)}
    if state_make(&f.state,&f.settings,&f.app.jobs,&f.problems) {
        if f.fields==nil {sim.world_set_gravity(&f.state.world,f.gravity)}
    }
    physics_step(
        &f.state,core.ref(&f.settings),&f.requests,&f.events,&f.meshes,&f.app,{dt=dt,playing=dt>0},
        core.read(&f.rigids),core.read(&f.colliders),core.read(&f.characters),core.read(&f.moves),
        &f.joints,core.read(&f.statics),core.read(&f.parents),core.read(&f.names),
        &f.transforms,&f.bodies,core.read(&f.replicas),&f.character_states,&f.joint_states,core.read(&f.volumes),&f.joint_requests,core.ref(&f.collision),core.ref(&f.sync_check),&f.simulation_hash,nil,&f.problems,
        gravities,gravity_volumes,worlds,{},{},f.whole?{}:core.ref(&f.hierarchy),
    )
}

@(private)
physics_test_box :: proc(f:^Physics_Test,position,half:[3]f32,rigid:Maybe(Rigid_Body)=nil) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{position,1,{1,1,1}})
    core.add(&f.colliders,e,collider_box(half))
    if body,has:=rigid.?;has {core.add(&f.rigids,e,body)}
    return e
}

@(private)
physics_test_pose :: proc(f:^Physics_Test,e:core.Entity) -> core.Transform {
    pose,_:=core.get(core.read(&f.transforms),e)
    return pose
}

@(test)
moving_a_collider_only_wall_pushes_bodies_then_restores_static_motion :: proc(t:^testing.T) {
    f:Physics_Test
    physics_test_init(&f)
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
    physics_test_init(&f)
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
    actual_rigid,_:=core.get(core.read(&f.rigids),box)
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
    physics_test_init(&f)
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
    physics_test_init(&f)
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
