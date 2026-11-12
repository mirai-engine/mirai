package mirai_physics

import "core:testing"

// The area of a test: a ball whose weight goes from 0 at its border to 1 at its center.
Test_Ball :: struct {center:Vec3,radius:f32}

test_ball_area :: proc(ball:^Test_Ball) -> Area {
    weight :: proc "contextless" (user:rawptr,point:Vec3) -> f32 {
        ball:=(^Test_Ball)(user)
        return max(1-length(point-ball.center)/ball.radius,0)
    }
    reach:=Vec3{ball.radius,ball.radius,ball.radius}
    return {bounds={ball.center-reach,ball.center+reach},center=ball.center,rotation=QUAT_IDENTITY,weight=weight,user=ball}
}

@(test)
radial_impulses_launch_a_grounded_character_in_the_same_tick :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    character:=character_create(&w,CHARACTER_DESC_DEFAULT,{})
    test_steps(&w,60)
    testing.expect(t,.Standing in character_state(&w,character).ground)
    ball:=Test_Ball{{0,-1,0},5}
    count,ok:=world_apply_area(&w,test_ball_area(&ball),{800,0,0},radial=true,impulse=true,falloff=.Constant)
    testing.expect(t,ok && count==1)
    world_step(&w,1.0/60)
    testing.expect(t,.Standing not_in character_state(&w,character).ground)
    testing.expect(t,character_velocity(&w,character).y>5)
}

@(test)
an_area_weighs_filters_and_pushes_each_body_once :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    body:=test_body(&w,Sphere{0.1},{1,0,0})
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Sphere{0.1}
    shape.transform.p={0,0.1,0}
    shape_create(&w,body,shape)
    mass:=body_mass(&w,body)
    // The body, of two shapes, is halfway from the border of the ball to its center.
    ball:=Test_Ball{{},2}
    count,ok:=world_apply_area(&w,test_ball_area(&ball),{mass*60,0,0})
    testing.expect(t,ok && count==1)
    world_step(&w,1.0/60)
    testing.expect(t,abs(body_linear_velocity(&w,body).x-0.5)<0.01)
    count,ok=world_apply_area(&w,test_ball_area(&ball),{0,mass*60,0},falloff=.Constant)
    testing.expect(t,ok && count==1)
    world_step(&w,1.0/60)
    testing.expect(t,abs(body_linear_velocity(&w,body).y-1)<0.01)
    count,ok=world_apply_area(&w,test_ball_area(&ball),{mass*60,0,0},radial=true,falloff=.Constant,filter={filter={}})
    testing.expect(t,ok && count==0)
    // A body whose shapes are in the box of the area and whose center is out of the area gets nothing.
    far:=Test_Ball{body_center(&w,body)-Vec3{1.95,0,0},2}
    count,ok=world_apply_area(&w,test_ball_area(&far),{mass*60,0,0})
    testing.expect(t,ok && count==1)
    far.radius=1.9
    count,ok=world_apply_area(&w,test_ball_area(&far),{mass*60,0,0})
    testing.expect(t,ok && count==0)
}

@(test)
each_falloff_curve_goes_from_the_border_to_the_center_within_its_range :: proc(t:^testing.T) {
    // Weights at the center, halfway and at the border, with the formulas of the curves.
    expected:=[Radial_Falloff][3]f32{
        .Constant={1,1,1},
        .Linear={1,0.5,0},
        .Inverse={1,2*(1-1/1.5),0},
        .Squared={1,0.25,0},
        .Logarithmic={1,0.5849625,0},
    }
    for curve,falloff in expected {
        for value,i in curve {
            distance:=f32(i)*0.5
            curve:=falloff_curve(1-distance,falloff)
            testing.expectf(t,near(curve,value,1e-5),"%v at %v: %v",falloff,distance,curve)
            testing.expectf(t,near(weight_from_range({0.2,0.8},curve),0.2+0.6*value,1e-5),"%v in range at %v",falloff,distance)
            testing.expectf(t,near(weight_from_range({1,0},curve),1-value,1e-5),"%v inverted at %v",falloff,distance)
        }
    }
    testing.expect_value(t,falloff_curve(0.5,Radial_Falloff(5)),f32(0))
}

@(test)
field_noise_is_the_same_for_equal_inputs_and_stays_in_its_range :: proc(t:^testing.T) {
    noise:=Field_Noise{scale=2,seed=7,range={0.25,0.75}}
    rotation:=q_axis_angle({0,1,0},0.3)
    low,high:=f32(1),f32(0)
    differs:=false
    for i in 0..<64 {
        point:=Vec3{f32(i)*0.37,f32(i%5)*0.9,-f32(i%7)*1.3}
        value:=noise_weight(point,{1,2,3},rotation,noise)
        testing.expect_value(t,noise_weight(point,{1,2,3},rotation,noise),value)
        other:=noise
        other.seed=8
        differs=differs || noise_weight(point,{1,2,3},rotation,other)!=value
        low,high=min(low,value),max(high,value)
    }
    testing.expectf(t,low>=0.25 && high<=0.75 && high-low>0.1,"noise from %v to %v",low,high)
    testing.expect(t,differs)
    testing.expect_value(t,noise_weight({1,2,3},{},QUAT_IDENTITY,{}),f32(1))
    testing.expect_value(t,noise_weight({1,2,3},{},QUAT_IDENTITY,{scale=-1}),f32(0))
    far:=noise_weight({3e38,-3e38,1},{},QUAT_IDENTITY,{scale=1e-3})
    testing.expect(t,far>=0 && far<=1)
}

@(test)
the_weight_of_an_area_goes_through_the_curve_and_the_noise_and_hostile_areas_push_nothing :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    // At a quarter, a half and seven eighths of the way from the border of the ball to its center.
    weights:=[3]f32{0.25,0.5,0.875}
    ball:=Test_Ball{{0,1,0},4}
    bodies:[3]Body_Handle
    for weight,i in weights {bodies[i]=test_body(&w,Sphere{0.1},{(1-weight)*4,1,0})}
    mass:=body_mass(&w,bodies[0])
    count,ok:=world_apply_area(&w,test_ball_area(&ball),{0,0,mass*60},falloff=.Squared)
    testing.expect(t,ok && count==3)
    world_step(&w,1.0/60)
    for weight,i in weights {
        testing.expectf(t,near(body_linear_velocity(&w,bodies[i]).z,weight*weight,1e-3),"weight %v: %v",weight,body_linear_velocity(&w,bodies[i]).z)
        body_set_velocity(&w,bodies[i],{},{})
    }
    noise:=Field_Noise{scale=0.7,seed=3,range={-1,1}}
    expected:[3]f32
    for body,i in bodies {expected[i]=noise_weight(body_position(&w,body),{0,1,0},QUAT_IDENTITY,noise)}
    count,ok=world_apply_area(&w,test_ball_area(&ball),{mass*60,0,0},falloff=.Constant,noise=noise)
    testing.expect(t,ok && count==3)
    world_step(&w,1.0/60)
    for body,i in bodies {
        testing.expectf(t,near(body_linear_velocity(&w,body).x,expected[i],1e-3),"noise %v against %v",body_linear_velocity(&w,body).x,expected[i])
        body_set_velocity(&w,body,{},{})
    }
    testing.expect(t,expected[0]!=expected[1] || expected[1]!=expected[2])
    // An area without end reaches every body; one whose weight is not a number pushes none.
    everywhere:=test_ball_area(&ball)
    everywhere.bounds={{-max(f32),-max(f32),-max(f32)},{max(f32),max(f32),max(f32)}}
    count,ok=world_apply_area(&w,everywhere,{},falloff=.Constant)
    testing.expect(t,ok && count==0,"a force of zero pushes nothing")
    count,ok=world_apply_area(&w,everywhere,{mass*60,0,0},falloff=.Constant)
    testing.expect(t,ok && count==3)
    everywhere.weight=proc "contextless" (user:rawptr,point:Vec3) -> f32 {
        nan:=f32(0)
        return nan/nan
    }
    count,ok=world_apply_area(&w,everywhere,{mass*60,0,0})
    testing.expect(t,ok && count==0)
    nan:=f32(0)
    nan/=nan
    Hostile :: struct {name:string,area:Area,force:Vec3,falloff:Radial_Falloff,noise:Field_Noise,velocity_change:bool}
    good:=test_ball_area(&ball)
    cases:=[?]Hostile{
        {name="no weight",area={bounds=good.bounds,rotation=QUAT_IDENTITY},force={1,0,0}},
        {name="a center that is not a number",area={bounds=good.bounds,center={nan,0,0},rotation=QUAT_IDENTITY,weight=good.weight,user=&ball},force={1,0,0}},
        {name="a box inside out",area={bounds={{1,1,1},{-1,-1,-1}},rotation=QUAT_IDENTITY,weight=good.weight,user=&ball},force={1,0,0}},
        {name="a box that is not a number",area={bounds={{nan,0,0},{1,1,1}},rotation=QUAT_IDENTITY,weight=good.weight,user=&ball},force={1,0,0}},
        {name="a force that is not finite",area=good,force={max(f32)*2,0,0}},
        {name="a falloff out of range",area=good,force={1,0,0},falloff=Radial_Falloff(9)},
        {name="a negative noise scale",area=good,force={1,0,0},noise={scale=-1}},
        {name="a velocity change that is not an impulse",area=good,force={1,0,0},velocity_change=true},
    }
    for c in cases {
        count,ok=world_apply_area(&w,c.area,c.force,velocity_change=c.velocity_change,falloff=c.falloff,noise=c.noise)
        testing.expectf(t,!ok && count==0,"%s was applied",c.name)
    }
    world_step(&w,1.0/60)
    for body in bodies {testing.expectf(t,near(body_linear_velocity(&w,body).x,1,1e-3),"only the area without end pushed: %v",body_linear_velocity(&w,body))}
}
