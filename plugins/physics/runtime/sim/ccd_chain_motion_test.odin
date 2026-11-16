package mirai_physics

import "core:testing"

@(test)
ccd_finds_an_angular_impact_after_starting_inside_the_outer_clearance :: proc(t:^testing.T) {
    rod:=Shape{type=.Box,size={1,.05,.1}}
    floor:=Shape{type=.Box,size={5,.5,5}}
    rod_points,floor_points:[8]Vec3
    a,b:=shape_proxy(nil,&rod,&rod_points,nil),shape_proxy(nil,&floor,&floor_points,nil)
    sa:=Sweep{c1={0,.054,0},c2={0,.154,0},q1=QUAT_IDENTITY,q2=q_axis_angle({0,0,1},.5)}
    sb:=Sweep{c1={0,-.5,0},c2={0,-.5,0},q1=QUAT_IDENTITY,q2=QUAT_IDENTITY}
    outer:=time_of_impact(a,b,sa,sb)
    testing.expect_value(t,outer.state,Toi_State.Hit)
    testing.expect_value(t,outer.fraction,f32(0))
    actual:=continuous_toi(a,b,sa,sb,1,0,0)
    testing.expect_value(t,actual.state,Toi_State.Hit)
    testing.expectf(t,actual.fraction>0 && actual.fraction<.05,"angular impact fraction %v",actual.fraction)
}

@(test)
an_anchored_ccd_chain_on_the_floor_moves_after_successive_impulses :: proc(t:^testing.T) {
    for bullet in ([2]bool{false,true}) {
        w:World
        if !testing.expect(t,test_world(&w,32,256)) {return}
        defer world_destroy(&w)
        test_ground(&w,{10,1,10})
        pivot:=test_anchor(&w,{-1.47,2.5,0})
        links:[7]Body_Handle
        for &body,index in links {
            desc:=BODY_DESC_DEFAULT
            desc.position={f32(index)*.42-1.26,2.5,0}
            desc.bullet=bullet
            body=body_create(&w,desc)
            shape:=SHAPE_DESC_DEFAULT;shape.geometry=Box{{.2,.2,.2}}
            shape_create(&w,body,shape)
            body_set_mass_properties(&w,body,2,{},mat3_diagonal({.0533333,.0533333,.0533333}))
            previous:=index==0?pivot:links[index-1]
            joint:=test_joint(&w,.Spherical,previous,body,desc.position-Vec3{.21,0,0})
            testing.expect(t,joint_create(&w,joint)!={})
        }
        test_steps(&w,360)
        for activation in 0..<3 {
            before:[7]Vec3
            for body,index in links {before[index]=body_position(&w,body)}
            blast:=Test_Ball{{0,.4,0},6}
            count,ok:=world_apply_area(&w,test_ball_area(&blast),{35,0,0},radial=true,impulse=true,velocity_change=true)
            testing.expect(t,ok && count==7)
            maximum_move:f32
            stationary_with_velocity:=0
            for _ in 0..<180 {
                previous:[7]Vec3
                for body,index in links {previous[index]=body_position(&w,body)}
                world_step(&w,1.0/60)
                moving,stationary:=false,true
                for body,index in links {
                    current:=body_position(&w,body)
                    maximum_move=max(maximum_move,length(current-before[index]))
                    moving||=length(body_linear_velocity(&w,body))>1
                    stationary&&=length(current-previous[index])<1e-7
                    testing.expect(t,current.y>.05)
                }
                if moving && stationary {stationary_with_velocity+=1}
            }
            testing.expectf(t,maximum_move>.1,"bullet=%v activation=%v move=%v frozen ticks=%v",bullet,activation,maximum_move,stationary_with_velocity)
            testing.expectf(t,stationary_with_velocity<30,"bullet=%v activation=%v frozen ticks=%v",bullet,activation,stationary_with_velocity)
            testing.expect_value(t,world_stats(&w).joints,7)
        }
    }
}
