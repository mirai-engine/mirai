package physics

import "core:strings"
import "core:testing"
import "mirai:core"
import sim "plugins:physics/runtime/sim"
import "core:math/linalg"
import mm "mirai:std/math"

@(test)
a_chain_built_only_from_public_components_stays_connected :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.gravity={0,-9.81,0}
    links:[9]core.Entity
    links[0]=physics_test_box(&f,{0,10,0},{0.2,0.2,0.2})
    rigid:=RIGID_BODY_DYNAMIC
    rigid.mass=1
    joints:[len(links)]core.Entity
    for i in 1..<len(links) {
        links[i]=physics_test_box(&f,{0,10-f32(i)*0.5,0},{0.2,0.2,0.2},rigid)
        joints[i]=physics_test_joint(&f,links[i],{0,0.25,0},joint_spherical(links[i-1]))
    }
    for _ in 0..<360 {physics_test_step(&f)}
    for i in 1..<len(links) {
        distance:=linalg.length(physics_test_pose(&f,links[i]).position-physics_test_pose(&f,links[i-1]).position)
        testing.expectf(t,distance<0.55,"link %v distance %v",i,distance)
        state,_:=core.get(&f.joint_states,joints[i])
        testing.expect_value(t,state.error,Joint_Error.None)
    }
}

@(test)
joint_requests_drive_disable_repair_and_reject_unsupported_changes :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    rigid:=RIGID_BODY_DYNAMIC
    rigid.mass=1
    body:=physics_test_box(&f,{},{0.2,0.2,0.2},rigid)
    joint:=physics_test_joint(&f,body,{},joint_fixed(core.NONE))
    physics_test_step(&f)
    // The drive frees the locked axes it drives: frame b, the world, goes to -1 in the frame of the body.
    set_joint_drive(&f.joint_requests,joint,{-1,0,0},1,5,1,1000,1000)
    for _ in 0..<180 {physics_test_step(&f)}
    testing.expectf(t,abs(physics_test_pose(&f,body).position.x-1)<0.01,"at %v",physics_test_pose(&f,body).position)
    held,_:=core.get(&f.joints,joint)
    set_joint_drive_enabled(&f.joint_requests,joint,false)
    physics_test_step(&f)
    disabled,_:=core.get(&f.joints,joint)
    testing.expect_value(t,disabled.linear[0].position,held.linear[0].position)
    testing.expect(t,.Disabled in disabled.linear[0].drive)
    set_joint_drive_enabled(&f.joint_requests,joint,true)
    physics_test_step(&f)
    enabled,_:=core.get(&f.joints,joint)
    shared:=[3]Joint_Axis{{motion=.Limited,upper=1},{motion=.Limited,upper=1,drive={.Velocity},velocity=1,max_force=1},{motion=.Limited,upper=1}}
    set_joint_axes(&f.joint_requests,joint,shared,{})
    set_joint_drive(&f.joint_requests,joint,{1,0,0},1,0,0,-1,0)
    physics_test_step(&f)
    refused:=core.problem_find(&f.problems,joint,"physics.joint_request")
    if testing.expect(t,refused!=nil && refused.count==2,"both changes are refused on the entity of the joint") {
        testing.expect(t,strings.contains(core.problem_text(refused),"request"),core.problem_text(refused))
    }
    testing.expect_value(t,core.at(&f.joints,core.row_of(&f.joints,joint)),enabled)
    before,_:=core.get(&f.joints,joint)
    before.break_force=0.001
    core.add(&f.joints,joint,before)
    apply_impulse(&f.requests,body,{0,100,0})
    physics_test_step(&f)
    state,_:=core.get(&f.joint_states,joint)
    testing.expect(t,state.broken)
    before.break_force=0
    core.add(&f.joints,joint,before)
    repair_joint(&f.joint_requests,joint)
    physics_test_step(&f)
    state,_=core.get(&f.joint_states,joint)
    testing.expect(t,!state.broken)
    testing.expect(t,sim.joint_valid(&f.state.world,core.entity_map_get(&f.state.joints,joint).joint))
}

@(test)
ending_manipulation_can_preserve_velocity_for_animation_to_physics :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    e:=physics_test_box(&f,{},{0.2,0.2,0.2},RIGID_BODY_DYNAMIC)
    physics_test_step(&f,0)
    manipulation_target(&f.requests,e,{0.1,0,0})
    physics_test_step(&f)
    body:=body_of(core.ref(&f.state),e)
    before:=sim.body_linear_velocity(&f.state.world,body)
    testing.expect(t,before.x>1)
    manipulation_end(&f.requests,e,true)
    physics_test_step(&f)
    testing.expect_value(t,sim.body_type(&f.state.world,body),sim.Body_Type.Dynamic)
    testing.expectf(t,abs(sim.body_linear_velocity(&f.state.world,body).x-before.x)<0.01,"velocity was lost")
}

@(test)
world_rotation_drives_use_recaptured_frames_and_preserve_request_order :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    rigid:=RIGID_BODY_DYNAMIC;rigid.mass=1
    parent:=physics_test_box(&f,{},{0.2,0.2,0.2})
    other:=physics_test_box(&f,{2,0,0},{0.2,0.2,0.2})
    body:=physics_test_box(&f,{0,1,0},{0.2,0.2,0.2},rigid)
    e:=physics_test_joint(&f,body,{},joint_spherical(parent))
    set_joint_world_rotation(&f.joint_requests,e,1,1,5,1,1000)
    physics_test_step(&f)
    joint,_:=core.get(&f.joints,e)
    state,_:=core.get(&f.joint_states,e)
    testing.expect(t,state.taken && .Position in joint.angular[0].drive)
    testing.expect_value(t,f.problems.count,0)
    for b in ([2]core.Entity{parent,other}) {
        // Another body and another frame: the frame on b is taken again.
        joint.b=b
        core.add(&f.transforms,e,core.Transform{{0.1,0.15,0},mm.quat_axis_angle({0,0,1},1.2),{1,1,1}})
        set_joint_configuration(&f.joint_requests,e,joint)
        set_joint_world_rotation(&f.joint_requests,e,1,1,5,1,1000)
        physics_test_step(&f)
        joint,_=core.get(&f.joints,e)
        testing.expect(t,abs(joint.angular[0].position)+abs(joint.angular[1].position)+abs(joint.angular[2].position)<0.001)
        testing.expect(t,mm.quat_angle(physics_test_pose(&f,body).rotation,1)<0.001)
        set_joint_world_rotation(&f.joint_requests,e,1,1,5,1,1000)
        set_joint_drive_enabled(&f.joint_requests,e,false)
        physics_test_step(&f)
        joint,_=core.get(&f.joints,e)
        testing.expect(t,.Disabled in joint.angular[0].drive)
        set_joint_drive_enabled(&f.joint_requests,e,false)
        set_joint_world_rotation(&f.joint_requests,e,1,1,5,1,1000)
        physics_test_step(&f)
        joint,_=core.get(&f.joints,e)
        testing.expect(t,.Disabled not_in joint.angular[0].drive)
    }
    invalid:=joint;invalid.b=body
    before:=joint
    set_joint_configuration(&f.joint_requests,e,invalid)
    nan:=transmute(f32)u32(0x7fc00000)
    set_joint_world_rotation(&f.joint_requests,e,quaternion(x=0,y=0,z=0,w=nan),1,5,1,1000)
    physics_test_step(&f)
    joint,_=core.get(&f.joints,e)
    testing.expect_value(t,joint,before)
    refused:=core.problem_find(&f.problems,e,"physics.joint_request")
    testing.expect(t,refused!=nil && refused.count==2)
    invalid=before;invalid.break_force=0.001
    set_joint_configuration(&f.joint_requests,e,invalid)
    apply_impulse(&f.requests,body,{0,100,0})
    physics_test_step(&f)
    state,_=core.get(&f.joint_states,e)
    testing.expect(t,state.broken)
    invalid.break_force=0
    set_joint_configuration(&f.joint_requests,e,invalid)
    repair_joint(&f.joint_requests,e)
    set_joint_world_rotation(&f.joint_requests,e,1,1,5,1,1000)
    physics_test_step(&f)
    state,_=core.get(&f.joint_states,e)
    testing.expect(t,!state.broken && state.taken)
    testing.expect(t,sim.joint_valid(&f.state.world,core.entity_map_get(&f.state.joints,e).joint))
    testing.expect(t,refused.count==2,"a repaired joint takes its requests")
}

// A body is joined to as many bodies as it has joints: a plank held at both ends by two joints of its own.
@(test)
one_body_owns_two_joints :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.gravity={0,-9.81,0}
    left:=physics_test_box(&f,{-2,5,0},{0.1,0.1,0.1})
    right:=physics_test_box(&f,{2,5,0},{0.1,0.1,0.1})
    rigid:=RIGID_BODY_DYNAMIC
    rigid.mass=10
    plank:=physics_test_box(&f,{0,5,0},{1.9,0.05,0.3},rigid)
    ends:=[2]core.Entity{physics_test_joint(&f,plank,{-1.95,0,0},joint_spherical(left)),physics_test_joint(&f,plank,{1.95,0,0},joint_spherical(right))}
    for _ in 0..<120 {physics_test_step(&f)}
    for end in ends {
        state,_:=core.get(&f.joint_states,end)
        testing.expect_value(t,state.error,Joint_Error.None)
        testing.expect(t,sim.joint_valid(&f.state.world,core.entity_map_get(&f.state.joints,end).joint))
    }
    pose:=physics_test_pose(&f,plank)
    testing.expectf(t,linalg.length(pose.position-[3]f32{0,5,0})<0.02,"the plank sagged to %v",pose.position)
}
