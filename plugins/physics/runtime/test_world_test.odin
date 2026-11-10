package physics

import "mirai:core"
import "mirai:host"
import "mirai:std/jobs"
import cam "mirai:engine/camera"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import sim "plugins:physics/runtime/sim"

// The tables and the storages of a World that physics steps on. The test
// world of a library that uses physics holds them after its header with
// `using physics:physics.Test_Physics`, gives physics.test_types to
// core.test_world_init or core.test_info, and steps with physics.test_step.
Test_Physics :: struct {
    rigids:core.Table(Rigid_Body),
    colliders:core.Table(Collider),
    characters:core.Table(Character),
    moves:core.Table(Character_Move),
    joints:core.Table(Joint),
    statics:core.Table(render.Mesh_Renderer),
    disabled:core.Table(core.Disabled),
    parents:core.Table(core.Parent),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    bodies:core.Table(core.Motion),
    replicas:core.Table(core.Pose_Target),
    character_states:core.Table(Character_State),
    joint_states:core.Table(Joint_State),
    volumes:core.Table(Fluid_Volume),
    verticals:core.Table(core.Vertical),
    // The gravity of the places of the world: a step reads them when its host says fields.
    gravities:core.Table(volume.Gravity),
    gravity_volumes:core.Table(volume.Volume),
    worlds:core.Table(core.World_Transform), // of what has a Gravity: the bodies of a test have none
    hierarchy:core.Hierarchy,
    state:Physics_State,
    settings:Physics_Settings,
    collision:Collision_Settings,
    sync_check:core.Sync_Check,
    simulation_hash:core.Simulation_Hash,
    requests:Body_Requests,
    joint_requests:Joint_Requests,
    events:Physics_Events,
}

// What a step of physics takes that the World does not hold: what the
// application holds for it and what the test asks of the step.
// test_host_destroy frees it.
Test_Physics_Host :: struct {
    meshes:Collider_Meshes,
    app:host.App,
    problems:core.Problems,
    gravity:[3]f32, // of its world: none unless a test gives it, or fields does
    fields:bool,    // the gravity of the world is that of its Gravity rows
    whole:bool,     // physics_step gets no hierarchy: every sync goes through every body
}

// What the declarations of physics and of the libraries it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    cam.test_types(types)
    volume.test_types(types)
    append(types,
        core.test_type(Physics_State,copy=state_copy,copy_kept=state_copy_kept,swap=state_swap,free=state_destroy,reset=state_reset),
        core.test_type(Collider_Meshes,free=collider_meshes_destroy),
        core.test_type(Collision_Settings,default=proc(dst:^Collision_Settings) {dst^=COLLISION_SETTINGS_DEFAULT}),
        core.test_type(Rigid_Body,default=proc(dst:^Rigid_Body) {dst^=RIGID_BODY_DEFAULT}),
        core.test_type(Collider,default=proc(dst:^Collider) {dst^=COLLIDER_DEFAULT}),
        core.test_type(Character,default=proc(dst:^Character) {dst^=character_default()}),
        core.test_type(Fluid_Volume,default=proc(dst:^Fluid_Volume) {dst^=FLUID_VOLUME_DEFAULT}),
        core.test_type(Fluid_Waves,default=proc(dst:^Fluid_Waves) {dst^=FLUID_WAVES_DEFAULT}),
        core.test_type(Walk,default=proc(dst:^Walk) {dst^=WALK_DEFAULT}),
        core.test_type(Fly,default=proc(dst:^Fly) {dst^=FLY_DEFAULT}),
        core.test_type(Swim,default=proc(dst:^Swim) {dst^=SWIM_DEFAULT}),
        core.test_type(Slide,default=proc(dst:^Slide) {dst^=SLIDE_DEFAULT}),
        core.test_type(Mantle,default=proc(dst:^Mantle) {dst^=MANTLE_DEFAULT}),
        core.test_type(Tactical_Sprint,default=proc(dst:^Tactical_Sprint) {dst^=TACTICAL_SPRINT_DEFAULT}),
        core.test_type(Ledge_Jump,default=proc(dst:^Ledge_Jump) {dst^=LEDGE_JUMP_DEFAULT}),
        core.test_type(Walk_Actions,default=proc(dst:^Walk_Actions) {dst^=walk_actions_default()}),
    )
}

// A simulation alone, with the capacities of settings: where the test of a library that makes its bodies itself
// makes them, and steps them with simulate. state_destroy frees it.
test_state_make :: proc(state:^Physics_State,settings:=Physics_Settings{}) -> bool {
    settings:=settings
    job_system:jobs.Job_System
    problems:core.Problems
    return state_make(state,&settings,&job_system,&problems)
}

test_host_destroy :: proc(h:^Test_Physics_Host) {
    collider_meshes_destroy(&h.meshes)
}

// physics_step alone, on the rows as they are and as the loop calls it.
test_step :: proc(p:^Test_Physics,h:^Test_Physics_Host,dt:f32) {
    gravities:core.Read(volume.Gravity);gravity_volumes:core.Read(volume.Volume);worlds:core.Read(core.World_Transform)
    if h.fields {gravities,gravity_volumes,worlds=core.read(&p.gravities),core.read(&p.gravity_volumes),core.read(&p.worlds)}
    if state_make(&p.state,&p.settings,&h.app.jobs,&h.problems) {
        if !h.fields {sim.world_set_gravity(&p.state.world,h.gravity)}
    }
    physics_step(
        &p.state,core.ref(&p.settings),&p.requests,&p.events,&h.meshes,&h.app,{dt=dt,playing=dt>0},
        core.read(&p.rigids),core.read(&p.colliders),core.read(&p.characters),core.read(&p.moves),
        &p.joints,core.read(&p.statics),core.read(&p.parents),core.read(&p.names),
        &p.transforms,&p.bodies,core.read(&p.replicas),&p.character_states,&p.joint_states,core.read(&p.volumes),&p.joint_requests,core.ref(&p.collision),core.ref(&p.sync_check),&p.simulation_hash,nil,&h.problems,
        gravities,gravity_volumes,worlds,{},{},h.whole?{}:core.ref(&p.hierarchy),
    )
}
