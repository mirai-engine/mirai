package mirai_physics

import "core:testing"

@(test)
six_dof_axes_lock_and_limits_stop_even_an_extreme_motor :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    anchor:=test_anchor(&w,{})
    body:=test_body(&w,Box{{0.5,0.5,0.5}},{})
    desc:=test_joint(&w,.SixDOF,anchor,body,{})
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
    desc:=test_joint(&w,.SixDOF,anchor,body,{})
    target:=q_axis_angle(normalize({1,2,3}),1.5)
    position:=Vec3{1,-0.5,0.25}
    testing.expect_value(t,joint_drive_pose(&desc,position,target,5,1,100000,100000),Joint_Error.None)
    testing.expect(t,joint_create(&w,desc)!={})
    test_steps(&w,240)
    testing.expectf(t,length(body_position(&w,body)-position)<0.01,"position %v",body_position(&w,body))
    testing.expectf(t,length(q_rotation_vector(conj(target)*body_rotation(&w,body)))<0.01,"rotation %v",body_rotation(&w,body))
}

@(test)
joint_options_that_have_no_solver_are_rejected_without_creating_a_joint :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    anchor:=test_anchor(&w,{})
    body:=test_body(&w,Box{{0.5,0.5,0.5}},{0,2,0})
    desc:=test_joint(&w,.Spherical,anchor,body,{})
    desc.enable_motor=true
    testing.expect_value(t,joint_configuration_error(desc),Joint_Error.Unsupported_Option)
    testing.expect(t,joint_create(&w,desc)=={})
    desc.type=.SixDOF
    desc.enable_motor=false
    desc.linear[1]={motion=.Locked,drive={.Velocity},velocity=2,max_force=10}
    testing.expect_value(t,joint_configuration_error(desc),Joint_Error.Invalid_Axis)
    testing.expect(t,joint_create(&w,desc)=={})
    testing.expect_value(t,world_stats(&w).joints,0)
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
    desc:=Joint_Desc{type=.Distance,body_a=anchor,body_b=body,enable_limit=true,lower=0,upper=2}
    testing.expect(t,joint_create(&w,desc)!={})
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
            desc:=test_joint(w,.SixDOF,anchor,body,position)
            joint_drive_pose(&desc,{0.3,0.25,0.5},q_axis_angle(normalize({1,2,3}),1.2),5,1,100000,100000)
            joint_create(w,desc)
        }
    }
    for _ in 0..<30 {
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        testing.expect_value(t,world_hash(&a),world_hash(&b))
    }
    snapshot:World
    defer world_destroy(&snapshot)
    test_keep(&snapshot,&a)
    for _ in 0..<60 {
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        testing.expect_value(t,world_hash(&a),world_hash(&b))
    }
    final:=world_hash(&a)
    testing.expect(t,test_restore(&a,&snapshot))
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
    desc:=test_joint(&a,.SixDOF,anchor,body,{})
    joint_drive_pose(&desc,{0.3,0.2,0.5},q_axis_angle(normalize({1,2,3}),1),5,1,100000,100000)
    joint:=joint_create(&a,desc)
    test_steps(&a,30)
    buffer:World
    defer world_destroy(&buffer)
    ok:=test_keep(&buffer,&a)
    testing.expect(t,ok)
    testing.expect(t,test_restore(&b,&buffer))
    testing.expect_value(t,world_hash(&a),world_hash(&b))
    change :: proc(w:^World,joint:Joint_Handle,desc:Joint_Desc) {
        joint_destroy(w,joint)
        next:=desc
        next.type,next.linear,next.angular=.Distance,{},{}
        next.length=0.7
        joint_create(w,next)
        next=desc
        joint_drive_pose(&next,{-0.2,0.1,0.4},q_axis_angle({0,1,0},0.3),5,1,100000,100000)
        joint_create(w,next)
        test_steps(w,30)
    }
    change(&a,joint,desc)
    change(&b,joint,desc)
    testing.expect_value(t,world_hash(&a),world_hash(&b))
    testing.expect(t,test_restore(&a,&buffer))
    change(&a,joint,desc)
    testing.expect_value(t,world_hash(&a),world_hash(&b))
}
