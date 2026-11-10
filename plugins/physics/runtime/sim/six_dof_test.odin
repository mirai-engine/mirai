package mirai_physics

import "core:testing"
import cmath "core:math"

@(test)
six_dof_axes_lock_and_limits_stop_even_an_extreme_motor :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    anchor:=test_anchor(&w,{})
    body:=test_body(&w,Box{{0.5,0.5,0.5}},{})
    desc:=test_joint(&w,.Free,anchor,body,{})
    for &axis in desc.linear {axis.motion=.Locked}
    for &axis in desc.angular {axis.motion=.Locked}
    desc.linear[0]={motion=.Limited,lower=-0.5,upper=0.5,drive={.Velocity},velocity=100,max_force=1e8}
    testing.expect(t,joint_create(&w,desc)!={})
    body_set_velocity(&w,body,{4,2,3},{1,2,3})
    test_steps(&w,180)
    position:=body_position(&w,body)
    testing.expectf(t,position.x<=0.52 && position.x>=0.48 && abs(position.y)<0.01 && abs(position.z)<0.01,"position %v",position)
    testing.expect(t,length(q_rotation_vector(body_rotation(&w,body)))<0.01)
}

@(test)
six_dof_pose_drives_reach_a_translation_and_compound_rotation :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    anchor:=test_anchor(&w,{})
    body:=test_body(&w,Box{{0.5,0.5,0.5}},{})
    desc:=test_joint(&w,.Free,anchor,body,{})
    target:=q_axis_angle(normalize({1,2,3}),1.5)
    position:=Vec3{1,-0.5,0.25}
    testing.expect_value(t,joint_drive_pose(&desc,position,target,5,1,100000,100000),Joint_Error.None)
    testing.expect(t,joint_create(&w,desc)!={})
    test_steps(&w,240)
    testing.expectf(t,length(body_position(&w,body)-position)<0.01,"position %v",body_position(&w,body))
    testing.expectf(t,length(q_rotation_vector(conj(target)*body_rotation(&w,body)))<0.01,"rotation %v",body_rotation(&w,body))
}

@(test)
axes_that_do_not_make_sense_are_rejected_without_creating_a_joint :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    anchor:=test_anchor(&w,{})
    body:=test_body(&w,Box{{0.5,0.5,0.5}},{0,2,0})
    Case :: struct {desc:Joint_Desc,error:Joint_Error}
    distance_driven:=test_distance(anchor,body,0,2)
    distance_driven.linear[1].drive,distance_driven.linear[1].velocity,distance_driven.linear[1].max_force={.Velocity},1,10
    locked_driven:=test_joint(&w,.Free,anchor,body,{})
    locked_driven.linear[1]={motion=.Locked,drive={.Velocity},velocity=2,max_force=10}
    uneven_cone:=test_joint(&w,.Spherical,anchor,body,{})
    uneven_cone.angular[1],uneven_cone.angular[2]={motion=.Limited,lower=-0.5,upper=0.5},{motion=.Limited,lower=0.2,upper=0.5}
    uneven_distance:=test_distance(anchor,body,0,2)
    uneven_distance.linear[2].upper=3
    nan:=test_joint(&w,.Revolute,anchor,body,{})
    nan.angular[0]={motion=.Limited,lower=transmute(f32)u32(0x7fc00000),upper=1}
    cases:=[?]Case{{distance_driven,.Unsupported_Option},{locked_driven,.Invalid_Axis},{uneven_cone,.Invalid_Axis},{uneven_distance,.Invalid_Axis},{nan,.Invalid_Axis}}
    for c in cases {
        testing.expect_value(t,joint_configuration_error(c.desc),c.error)
        testing.expect(t,joint_create(&w,c.desc)=={})
    }
    testing.expect_value(t,world_stats(&w).joints,0)
    desc:=test_joint(&w,.Spherical,anchor,body,{})
    original:=desc
    testing.expect_value(t,joint_drive_pose(&desc,{},QUAT_IDENTITY,0,1,-1,0),Joint_Error.Invalid_Value)
    testing.expect_value(t,desc,original)
    testing.expect_value(t,joint_drive_pose(&desc,{},QUAT_IDENTITY,0,1,0,10),Joint_Error.Invalid_Value)
    testing.expect_value(t,desc,original)
}

@(test)
a_distance_limit_without_a_spring_is_a_tension_only_rope :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    anchor:=test_anchor(&w,{})
    body:=test_body(&w,Sphere{0.1},{1,0,0})
    testing.expect(t,joint_create(&w,test_distance(anchor,body,0,2))!={})
    body_set_velocity(&w,body,{4,0,0},{})
    test_steps(&w,120)
    testing.expectf(t,abs(body_position(&w,body).x-2)<0.02,"rope %v",body_position(&w,body))
    body_set_velocity(&w,body,{-1,0,0},{})
    test_steps(&w,30)
    testing.expect(t,body_position(&w,body).x<1.6)
}

@(test)
six_dof_drives_keep_warm_impulses_and_replay_identically_with_workers :: proc(t:^testing.T) {
    pool:Test_Pool
    test_pool_init(&pool,4)
    defer test_pool_destroy(&pool)
    a,b:World
    testing.expect(t,test_world_threaded(&a,nil,128,512,64))
    testing.expect(t,test_world_threaded(&b,&pool,128,512,64))
    defer world_destroy(&a)
    defer world_destroy(&b)
    for w in ([2]^World{&a,&b}) {
        world_set_gravity(w,{})
        for i in 0..<32 {
            position:=Vec3{0,0,f32(i)*2}
            anchor:=test_anchor(w,position)
            body:=test_body(w,Box{{0.2,0.2,0.2}},position)
            desc:=test_joint(w,.Free,anchor,body,position)
            joint_drive_pose(&desc,{0.3,0.25,0.5},q_axis_angle(normalize({1,2,3}),1.2),5,1,100000,100000)
            joint_create(w,desc)
        }
    }
    for _ in 0..<30 {
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        testing.expect_value(t,world_hash(&a),world_hash(&b))
    }
    snapshot:=make([]byte,world_snapshot_size(&a))
    defer delete(snapshot)
    world_snapshot(&a,snapshot)
    for _ in 0..<60 {
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        testing.expect_value(t,world_hash(&a),world_hash(&b))
    }
    final:=world_hash(&a)
    testing.expect(t,world_restore(&a,snapshot))
    test_steps(&a,60)
    testing.expect_value(t,world_hash(&a),final)
}

@(test)
six_dof_snapshots_restore_into_another_world_and_survive_joint_slot_reuse :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_world(&a) && test_world(&b))
    defer world_destroy(&a)
    defer world_destroy(&b)
    world_set_gravity(&a,{})
    anchor:=test_anchor(&a,{})
    body:=test_body(&a,Box{{0.2,0.2,0.2}},{})
    desc:=test_joint(&a,.Free,anchor,body,{})
    joint_drive_pose(&desc,{0.3,0.2,0.5},q_axis_angle(normalize({1,2,3}),1),5,1,100000,100000)
    joint:=joint_create(&a,desc)
    test_steps(&a,30)
    buffer:=make([]byte,world_snapshot_capacity(&a))
    defer delete(buffer)
    written,ok:=world_snapshot(&a,buffer)
    testing.expect(t,ok)
    testing.expect(t,world_restore(&b,buffer[:written]))
    testing.expect_value(t,world_hash(&a),world_hash(&b))
    change :: proc(w:^World,joint:Joint_Handle,desc:Joint_Desc) {
        joint_destroy(w,joint)
        next:=test_distance(desc.body_a,desc.body_b,0.7,0.7)
        next.frame_a,next.frame_b=desc.frame_a,desc.frame_b
        joint_create(w,next)
        next=desc
        joint_drive_pose(&next,{-0.2,0.1,0.4},q_axis_angle({0,1,0},0.3),5,1,100000,100000)
        joint_create(w,next)
        test_steps(w,30)
    }
    change(&a,joint,desc)
    change(&b,joint,desc)
    testing.expect_value(t,world_hash(&a),world_hash(&b))
    testing.expect(t,world_restore(&a,buffer[:written]))
    change(&a,joint,desc)
    testing.expect_value(t,world_hash(&a),world_hash(&b))
    before:=world_hash(&a)
    buffer[written-1]~=1
    testing.expect(t,!world_restore(&a,buffer[:written]))
    testing.expect_value(t,world_hash(&a),before)
}

// A drive solved one axis at a time stops at the cone of the swings, whose angle toward each side is the limit
// of that side.
@(test)
a_driven_swing_stops_at_the_side_of_its_cone :: proc(t:^testing.T) {
    for side in ([2]f32{1,-1}) {
        w:World
        testing.expect(t,test_world(&w))
        defer world_destroy(&w)
        world_set_gravity(&w,{})
        anchor:=test_anchor(&w,{})
        body:=test_body(&w,Box{{0.5,0.1,0.1}},{})
        desc:=test_joint(&w,.Spherical,anchor,body,{})
        desc.angular[1],desc.angular[2]={motion=.Limited,lower=-0.2,upper=0.6},{motion=.Limited,lower=-0.3,upper=0.3}
        testing.expect_value(t,joint_drive_pose(&desc,{},q_axis_angle({0,1,0},side*1.2),5,1,0,1000),Joint_Error.None)
        joint:=joint_create(&w,desc)
        _,slot:=joint_get(&w,joint)
        testing.expect_value(t,w.joints[slot].kernel,Joint_Kernel.General)
        test_steps(&w,240)
        swing:=cmath.acos(clamp(dot(q_rotate(body_rotation(&w,body),Vec3{1,0,0}),Vec3{1,0,0}),-1,1))
        expect_near(t,swing,side>0?0.6:0.2,0.03)
    }
}
