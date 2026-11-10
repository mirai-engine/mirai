package mirai_physics

import "core:testing"

@(test)
disabling_ccd_restores_discrete_motion_and_clears_contact_flags :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_body(&w,Box{{0.01,2,2}},{},.Static,0)
    body:=test_bullet(&w,{-1,0,0},{200,0,0},true)
    world_step(&w,1.0/60)
    testing.expect(t,abs(body_linear_velocity(&w,body).x)<0.01)
    testing.expect_value(t,len(world_events(&w).contact_begin),1)
    body_set_bullet(&w,body,false)
    body_set_transform(&w,body,{-1,0,0},QUAT_IDENTITY)
    body_set_velocity(&w,body,{200,0,0},{})
    world_step(&w,1.0/60)
    testing.expect(t,body_position(&w,body).x>2)
    testing.expect_value(t,body_linear_velocity(&w,body),Vec3{200,0,0})
    testing.expect_value(t,len(world_events(&w).contact_begin),0)
    body_set_transform(&w,body,{-0.066,0,0},QUAT_IDENTITY)
    body_set_velocity(&w,body,{1,0,0},{})
    test_steps(&w,8)
    testing.expect(t,body_position(&w,body).x< -0.05)
    testing.expect(t,abs(body_linear_velocity(&w,body).x)<0.01)
}

@(test)
a_spinning_ccd_sphere_can_depart_after_a_frictional_bounce :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_body(&w,Box{{0.01,4,4}},{},.Static,1,0.8)
    body:=test_bullet(&w,{-1,0,0},{200,30,0},true)
    world_step(&w,1.0/60)
    testing.expect(t,body_linear_velocity(&w,body).x< -100)
    testing.expect(t,length(body_angular_velocity(&w,body))>1)
    position:=body_position(&w,body)
    world_step(&w,1.0/60)
    testing.expectf(t,body_position(&w,body).x<position.x-1,"spinning bounce froze: %v -> %v, velocity %v",position,body_position(&w,body),body_linear_velocity(&w,body))
    testing.expect_value(t,len(world_events(&w).contact_begin),0)
}
