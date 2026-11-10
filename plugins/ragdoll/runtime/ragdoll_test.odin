package ragdoll

import "core:mem"
import "core:math/linalg"
import "core:strings"
import "core:testing"
import "mirai:core"
import phys "plugins:physics/runtime"
import mm "mirai:std/math"
import "mirai:std/base"
import anim "plugins:animation/runtime"

@(test)
physical_animation_rejects_a_stale_parent_binding_and_invalid_parent_offsets :: proc(t:^testing.T) {
    f:Ragdoll_Fixture
    if !ragdoll_fixture_init(t,&f) {return}
    defer ragdoll_fixture_free(&f)
    core.edit(&f.configs,f.rig).mode=.Driven
    ragdoll_fixture_step(&f)
    child,_:=core.get(&f.states,f.lower)
    testing.expect(t,child.active && child.error==.None)
    core.edit(&f.bones,f.upper).bone=anim.bone_ref("missing")
    ragdoll_fixture_step(&f)
    child,_=core.get(&f.states,f.lower)
    driven,_:=core.get(&f.joints,f.joint)
    testing.expect(t,!child.active && child.error==.Missing_Bone && .Disabled in driven.angular[2].drive)
    core.edit(&f.bones,f.upper).bone=anim.bone_ref("upper")
    ragdoll_fixture_step(&f)
    child,_=core.get(&f.states,f.lower)
    testing.expect(t,child.active && child.error==.None)
    core.edit(&f.bones,f.upper).offset.rotation=0
    ragdoll_fixture_step(&f)
    child,_=core.get(&f.states,f.lower)
    driven,_=core.get(&f.joints,f.joint)
    testing.expect(t,!child.active && child.error==.Invalid_Settings && .Disabled in driven.angular[2].drive)
}

@(private)
Ragdoll_World :: struct {
    using world:core.Test_World,
    using physics:phys.Test_Physics,
    configs:core.Table(Ragdoll),
    bones:core.Table(Ragdoll_Bone),
    states:core.Table(Ragdoll_State),
    playback:anim.Playback,
    poses:anim.Animation_Requests,
    ragdoll:Ragdoll_Runtime,
}

// A rig of two bodies, one under the other, in a world without gravity.
@(private)
Ragdoll_Fixture :: struct {
    using w:Ragdoll_World,
    using host:phys.Test_Physics_Host,
    rig,upper,lower,joint:core.Entity,
}

@(private)
ragdoll_fixture_settle :: proc(f:^Ragdoll_Fixture) {core.test_world_settle(&f.w)}

@(private)
ragdoll_fixture_init :: proc(t:^testing.T,f:^Ragdoll_Fixture) -> bool {
    if !core.test_world_init(t,&f.w,test_types) {return false}
    f.whole=true
    f.rig,f.upper,f.lower=core.create(&f.entities),core.create(&f.entities),core.create(&f.entities)
    core.add(&f.transforms,f.rig,core.from_math(mm.TRANSFORM_IDENTITY))
    for entity,i in ([2]core.Entity{f.upper,f.lower}) {
        core.add(&f.transforms,entity,{{0,2-f32(i),0},1,{1,1,1}})
        core.add(&f.rigids,entity,phys.RIGID_BODY_DYNAMIC)
        collider:=phys.collider_box({.1,.4,.1});collider.group=f.rig
        core.add(&f.colliders,entity,collider)
        binding:=RAGDOLL_BONE_DEFAULT;binding.rig=f.rig;binding.bone=anim.bone_ref("upper" if i==0 else "lower")
        core.add(&f.bones,entity,binding)
    }
    // The joint of lower, half a meter over it, meets upper half a meter under it.
    joint:=phys.joint_fixed(f.upper);joint.b_frame,joint.b_anchor,joint.b_rotation=true,{0,-.5,0},1
    joint.angular[0]={motion=.Limited,lower=-1,upper=1}
    joint.angular[1],joint.angular[2]={motion=.Limited,lower=-1,upper=1},{motion=.Limited,lower=-1,upper=1}
    f.joint=core.create(&f.entities)
    core.add(&f.transforms,f.joint,{{0,.5,0},1,{1,1,1}})
    core.add(&f.parents,f.joint,core.Parent{entity=f.lower})
    core.add(&f.joints,f.joint,joint)
    config:=RAGDOLL_DEFAULT;config.mode=.Animated;config.max_torque=1000
    core.add(&f.configs,f.rig,config)
    f.settings={bodies=32,shapes=32,contacts=128,joints=8,characters=1}
    f.playback.frame=1
    state:=anim.Playing{entity=f.rig,bound=1,seen=1,pose_ready=true}
    append(&state.parents,-1,0,1)
    append(&state.targets,base.name_hash("actor"),base.name_hash("upper"),base.name_hash("lower"))
    append(&state.aliases,base.name_hash("actor"),base.name_hash("upper"),base.name_hash("lower"))
    append(&state.rest,mm.TRANSFORM_IDENTITY,mm.Transform{{0,2,0},1,{1,1,1}},mm.Transform{{0,-1,0},1,{1,1,1}})
    append(&state.local,..state.rest[:]);append(&state.sampled,..state.rest[:]);resize(&state.world,3)
    append(&f.playback.states,state)
    resize(&f.playback.rows,core.entity_index(f.rig)+1);f.playback.rows[core.entity_index(f.rig)]=1
    ragdoll_fixture_settle(f)
    return true
}

@(private)
ragdoll_fixture_free :: proc(f:^Ragdoll_Fixture) {
    phys.test_host_destroy(&f.host)
    core.test_world_destroy(&f.w)
}

@(private)
ragdoll_fixture_step :: proc(f:^Ragdoll_Fixture) {
    settings:=RAGDOLL_SETTINGS_DEFAULT
    time:=core.Time{dt=1.0/60,playing=true}
    ragdoll_prepare(core.read(&f.configs),core.read(&f.bones),&f.states,core.read(&f.rigids),core.read(&f.joints),core.read(&f.transforms),core.read(&f.parents),core.ref(&f.playback),&f.ragdoll,core.ref(&settings),&f.requests,&f.joint_requests,time,&f.poses,&f.problems)
    ragdoll_fixture_settle(f)
    phys.test_step(&f.physics,&f.host,time.dt)
    ragdoll_fixture_settle(f)
    ragdoll_pose(core.read(&f.configs),core.read(&f.bones),core.read(&f.states),core.read(&f.transforms),core.read(&f.parents),&f.poses,time,&f.problems)
}

@(test)
ragdolls_follow_current_animation_preserve_handoff_velocity_and_drive_real_joints :: proc(t:^testing.T) {
    f:Ragdoll_Fixture
    if !ragdoll_fixture_init(t,&f) {return}
    defer ragdoll_fixture_free(&f)
    ragdoll_fixture_step(&f)
    f.playback.states[0].sampled[1].position.x=.1
    ragdoll_fixture_step(&f)
    upper,_:=core.get(&f.transforms,f.upper)
    testing.expect(t,abs(upper.position.x-.1)<.001)
    velocity,_:=core.get(&f.bodies,f.upper)
    testing.expect(t,velocity.linear.x>5)
    core.edit(&f.configs,f.rig).mode=.Simulated
    ragdoll_fixture_step(&f)
    upper,_=core.get(&f.transforms,f.upper)
    testing.expect(t,upper.position.x>.15)
    testing.expect_value(t,len(f.poses.final_poses.items),2)
    for pose in f.poses.final_poses.items {testing.expect(t,pose.binding.revision==1 && pose.binding.index>=1)}
    clear(&f.poses.final_poses.items)
    core.edit(&f.configs,f.rig).mode=.Driven
    f.playback.states[0].sampled[2].rotation=mm.quat_axis_angle({0,0,1},.4)
    for tick in 0..<120 {clear(&f.poses.final_poses.items);ragdoll_fixture_step(&f)}
    child,_:=core.get(&f.transforms,f.lower)
    upper,_=core.get(&f.transforms,f.upper)
    relative:=mm.quat_inverse(upper.rotation)*child.rotation
    testing.expect(t,mm.quat_angle(relative,f.playback.states[0].sampled[2].rotation)<.08)
    driven,_:=core.get(&f.joints,f.joint)
    testing.expect(t,.Position in driven.angular[2].drive && driven.angular[2].motion==.Limited)
    core.edit(&f.configs,f.rig).hertz=0
    clear(&f.poses.final_poses.items);ragdoll_fixture_step(&f)
    driven,_=core.get(&f.joints,f.joint)
    testing.expect(t,.Disabled in driven.angular[2].drive)
    core.edit(&f.configs,f.rig).hertz=5
    clear(&f.poses.final_poses.items);ragdoll_fixture_step(&f)
    driven,_=core.get(&f.joints,f.joint)
    testing.expect(t,.Disabled not_in driven.angular[2].drive)
    core.edit(&f.configs,f.rig).mode=.Simulated
    clear(&f.poses.final_poses.items);ragdoll_fixture_step(&f)
    driven,_=core.get(&f.joints,f.joint)
    testing.expect(t,.Disabled in driven.angular[2].drive)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
invalid_bindings_and_removed_configuration_release_kinematic_bodies :: proc(t:^testing.T) {
    f:Ragdoll_Fixture
    if !ragdoll_fixture_init(t,&f) {return}
    defer ragdoll_fixture_free(&f)
    ragdoll_fixture_step(&f)
    core.edit(&f.bones,f.lower).bone=anim.bone_ref("missing")
    ragdoll_fixture_step(&f)
    state,_:=core.get(&f.states,f.lower)
    testing.expect(t,state.error==.Missing_Bone && !state.active)
    missing:=core.problem_find(&f.problems,f.lower,"ragdoll.bone")
    testing.expect(t,missing!=nil && strings.contains(core.problem_text(missing),"bone 'missing' of this Ragdoll_Bone"),"the body names the bone it could not find")
    core.remove(&f.configs,f.rig);ragdoll_fixture_settle(&f)
    ragdoll_fixture_step(&f)
    testing.expect_value(t,core.count(&f.states),0)
    testing.expect(t,!ragdoll_valid(Ragdoll{weight=2}))
    bone:=RAGDOLL_BONE_DEFAULT;bone.rig=f.rig;bone.bone=anim.bone_ref("upper");bone.offset.rotation=0
    testing.expect(t,!ragdoll_bone_valid(bone))
}

@(test)
physical_animation_uses_current_auto_frames_and_reuses_world_buffers :: proc(t:^testing.T) {
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator);defer mem.tracking_allocator_destroy(&track)
    previous_context:=context;context.allocator=mem.tracking_allocator(&track)
    defer context=previous_context
    f:Ragdoll_Fixture
    if !ragdoll_fixture_init(t,&f) {return}
    defer ragdoll_fixture_free(&f)
    // After the world is made: making it reads its sources into the temporary allocator.
    context.temp_allocator=context.allocator
    core.edit(&f.configs,f.rig).mode=.Driven
    core.edit(&f.joints,f.joint).b_frame=false
    turn:=mm.quat_axis_angle({0,1,0},.4)
    core.edit(&f.transforms,f.lower).rotation=turn
    f.playback.states[0].sampled[2].rotation=turn
    ragdoll_fixture_step(&f)
    joint,_:=core.get(&f.joints,f.joint)
    testing.expect(t,.Position in joint.angular[0].drive && abs(joint.angular[1].position)<.001)
    for tick in 0..<10 {clear(&f.poses.final_poses.items);ragdoll_fixture_step(&f)}
    joint,_=core.get(&f.joints,f.joint)
    testing.expect(t,abs(joint.angular[0].position)<.001 && abs(joint.angular[1].position)<.001 && abs(joint.angular[2].position)<.001)
    allocations:=track.total_allocation_count
    for tick in 0..<60 {clear(&f.poses.final_poses.items);ragdoll_fixture_step(&f)}
    testing.expect_value(t,track.total_allocation_count,allocations)
    testing.expect_value(t,f.problems.count,0)
}
