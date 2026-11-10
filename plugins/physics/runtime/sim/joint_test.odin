package mirai_physics

import "core:testing"
import cmath "core:math"

@(private)
test_anchor :: proc(w:^World,position:Vec3) -> Body_Handle {
    return body_create(w,{type=.Static,position=position})
}

// The kinds of joint the six axes express, by what each locks.
@(private) Test_Joint :: enum {Free,Fixed,Spherical,Revolute,Prismatic}

@(private)
test_joint :: proc(w:^World,kind:Test_Joint,a,b:Body_Handle,anchor:Vec3,axis:Vec3={1,0,0}) -> Joint_Desc {
    frame_a,frame_b:=joint_frames(w,a,b,anchor,axis)
    desc:=Joint_Desc{body_a=a,body_b=b,frame_a=frame_a,frame_b=frame_b}
    locked:=Joint_Axis{motion=.Locked}
    switch kind {
    case .Free:
    case .Fixed: desc.linear,desc.angular={locked,locked,locked},{locked,locked,locked}
    case .Spherical: desc.linear={locked,locked,locked}
    case .Revolute: desc.linear,desc.angular={locked,locked,locked},{{},locked,locked}
    case .Prismatic: desc.linear,desc.angular={{},locked,locked},{locked,locked,locked}
    }
    return desc
}

// Anchors that stay between lower and upper meters apart; at a length when they are equal.
@(private)
test_distance :: proc(a,b:Body_Handle,lower,upper:f32) -> Joint_Desc {
    limit:=Joint_Axis{motion=.Limited,lower=lower,upper=upper}
    return {body_a=a,body_b=b,linear={limit,limit,limit}}
}

// A joint with one of its axes changed.
@(private)
test_axis_set :: proc(w:^World,joint:Joint_Handle,angular:bool,index:int,axis:Joint_Axis) {
    _,slot:=joint_get(w,joint)
    linear,turns:=w.joint_axes[slot].linear_axes,w.joint_axes[slot].angular_axes
    if angular {turns[index]=axis} else {linear[index]=axis}
    joint_set_axes(w,joint,linear,turns)
}

// The kinds of joint the solver had before the six axes, written in them, move as they moved then: the
// positions and rotations their old descriptions gave after the same steps.
@(test)
the_old_kinds_written_in_six_axes_move_as_before :: proc(t:^testing.T) {
    Case :: struct {name:string,setup:proc(w:^World) -> Body_Handle,steps:int,position:Vec3,rotation:Quat}
    cases:=[?]Case{
        {"fixed",proc(w:^World) -> Body_Handle {
            a,b:=test_anchor(w,{0,5,0}),test_body(w,Box{{0.5,0.2,0.2}},{1,5,0})
            joint_create(w,test_joint(w,.Fixed,a,b,{0,5,0}))
            body_set_velocity(w,b,{0,2,1},{1,0,2})
            return b
        },60,{0.999999,4.998503,0},quaternion(x=0,y=0,z=-0.000357,w=1)},
        {"spherical",proc(w:^World) -> Body_Handle {
            a,b:=test_anchor(w,{0,5,0}),test_body(w,Box{{0.2,0.5,0.2}},{0,4.5,0})
            d:=test_joint(w,.Spherical,a,b,{0,5,0},{0,-1,0})
            d.angular={{motion=.Limited,lower=-0.3,upper=0.3},{motion=.Limited,lower=-0.5,upper=0.5},{motion=.Limited,lower=-0.5,upper=0.5}}
            joint_create(w,d)
            body_set_velocity(w,b,{2,0,1},{3,1,2})
            return b
        },90,{0.138179,4.519892,0.022635},quaternion(x=-0.043446,y=0.147810,z=0.134593,w=0.978851)},
        {"revolute motor",proc(w:^World) -> Body_Handle {
            a,b:=test_anchor(w,{0,5,0}),test_body(w,Box{{0.5,0.2,0.2}},{1,5,0})
            d:=test_joint(w,.Revolute,a,b,{0,5,0},{0,0,1})
            d.angular[0]={motion=.Limited,lower=-1,upper=1,drive={.Velocity},velocity=2,max_force=50}
            joint_create(w,d)
            return b
        },90,{0.540001,4.158267,0},quaternion(x=0,y=0,z=-0.479442,w=0.877574)},
        {"revolute spring",proc(w:^World) -> Body_Handle {
            a,b:=test_anchor(w,{0,5,0}),test_body(w,Box{{0.5,0.2,0.2}},{1,5,0})
            d:=test_joint(w,.Revolute,a,b,{0,5,0},{0,0,1})
            d.angular[0]={drive={.Position},position=0.5,hertz=2,damping_ratio=0.3,max_force=max(f32)}
            joint_create(w,d)
            return b
        },90,{0.997325,4.926849,0},quaternion(x=0,y=0,z=-0.036250,w=0.999343)},
        {"prismatic motor",proc(w:^World) -> Body_Handle {
            a,b:=test_anchor(w,{0,5,0}),test_body(w,Box{{0.2,0.2,0.2}},{0,5,0})
            d:=test_joint(w,.Prismatic,a,b,{0,5,0},{1,1,0})
            d.linear[0]={motion=.Limited,lower=-0.5,upper=0.5,drive={.Velocity},velocity=1,max_force=100}
            joint_create(w,d)
            return b
        },90,{-0.353519,4.646412,0},1},
        {"prismatic spring",proc(w:^World) -> Body_Handle {
            a,b:=test_anchor(w,{0,5,0}),test_body(w,Box{{0.2,0.2,0.2}},{0,5,0})
            d:=test_joint(w,.Prismatic,a,b,{0,5,0},{1,0,0})
            d.linear[0]={drive={.Position},position=0.4,hertz=3,damping_ratio=0.2,max_force=max(f32)}
            joint_create(w,d)
            body_set_velocity(w,b,{0,0,1},{})
            return b
        },90,{0.399884,4.999931,0},1},
        {"distance rope",proc(w:^World) -> Body_Handle {
            a,b:=test_anchor(w,{}),test_body(w,Sphere{0.1},{1,0,0})
            joint_create(w,test_distance(a,b,0,2))
            body_set_velocity(w,b,{4,1,0},{})
            return b
        },120,{-1.992052,-0.178754,0},1},
        {"distance rod",proc(w:^World) -> Body_Handle {
            a,b:=test_anchor(w,{}),test_body(w,Sphere{0.1},{1.5,0,0})
            joint_create(w,test_distance(a,b,1.5,1.5))
            return b
        },90,{-1.499946,-0.013205,0},1},
        {"distance spring",proc(w:^World) -> Body_Handle {
            a,b:=test_anchor(w,{}),test_body(w,Sphere{0.1},{2,0,0})
            d:=test_distance(a,b,0.5,3)
            d.linear[0].drive,d.linear[0].position,d.linear[0].hertz,d.linear[0].damping_ratio,d.linear[0].max_force={.Position},1,2,0.5,max(f32)
            joint_create(w,d)
            return b
        },90,{-0.898611,-0.526898,0},1},
        {"six axes",proc(w:^World) -> Body_Handle {
            a,b:=test_anchor(w,{0,5,0}),test_body(w,Box{{0.5,0.2,0.2}},{1,5,0})
            d:=test_joint(w,.Free,a,b,{0,5,0})
            for &axis in d.linear {axis.motion=.Locked}
            d.angular={{motion=.Limited,lower=-0.4,upper=0.4},{drive={.Position},position=0.3,hertz=4,damping_ratio=1,max_force=500},{motion=.Locked}}
            joint_create(w,d)
            body_set_velocity(w,b,{},{2,0,0})
            return b
        },90,{0.817698,4.880383,-0.563276},quaternion(x=-0.195519,y=0.301893,z=-0.000415,w=0.933077)},
    }
    for c in cases {
        w:World
        testing.expect(t,test_world(&w))
        body:=c.setup(&w)
        test_steps(&w,c.steps)
        position,rotation:=body_position(&w,body),body_rotation(&w,body)
        testing.expectf(t,length(position-c.position)<1e-3,"%s: at %v, before at %v",c.name,position,c.position)
        testing.expectf(t,abs(rotation.x*c.rotation.x+rotation.y*c.rotation.y+rotation.z*c.rotation.z+rotation.w*c.rotation.w)>0.99999,"%s: turned to %v, before to %v",c.name,rotation,c.rotation)
        world_destroy(&w)
    }
}

@(test)
a_fixed_joint_holds_a_cantilever :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    wall:=test_anchor(&w,{0,5,0})
    beam:=test_body(&w,Box{{1,0.1,0.1}},{1,5,0})
    joint:=joint_create(&w,test_joint(&w,.Fixed,wall,beam,{0,5,0}))
    testing.expect(t,joint_valid(&w,joint))
    body_set_sleep_disabled(&w,beam,true)
    test_steps(&w,180)
    expect_near3(t,body_position(&w,beam),{1,5,0},0.02)
    testing.expect(t,abs(body_rotation(&w,beam).w)>0.9999)
    force,torque:=joint_reaction(&w,joint)
    mass:=body_mass(&w,beam)
    expect_near(t,force,mass*9.81,0.05*mass*9.81)
    expect_near(t,torque,mass*9.81,0.05*mass*9.81)
    a,b:=joint_bodies(&w,joint)
    testing.expect(t,a==wall && b==beam)
    joint_destroy(&w,joint)
    testing.expect(t,!joint_valid(&w,joint))
    test_steps(&w,30)
    testing.expect(t,body_position(&w,beam).y<4.5)
}

@(test)
a_revolute_joint_swings_about_its_axis_only :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    pivot:=test_anchor(&w,{0,5,0})
    bob:=test_body(&w,Sphere{0.2},{2,5,0})
    joint:=joint_create(&w,test_joint(&w,.Revolute,pivot,bob,{0,5,0},{0,0,1}))
    lowest:f32=5
    for _ in 0..<240 {
        world_step(&w,1.0/60)
        p:=body_position(&w,bob)
        expect_near(t,length(p-Vec3{0,5,0}),2,0.02)
        expect_near(t,p.z,0,1e-3)
        lowest=min(lowest,p.y)
    }
    expect_near(t,lowest,3,0.05)
    // The swing loses little energy: it comes back near the height it started from.
    highest:f32=0
    for _ in 0..<240 {
        world_step(&w,1.0/60)
        if body_position(&w,bob).x<0 {highest=max(highest,body_position(&w,bob).y)}
    }
    testing.expectf(t,highest>4.6,"swung back up to %v",highest)
    _,slot:=joint_get(&w,joint)
    testing.expect_value(t,w.joints[slot].kernel,Joint_Kernel.Revolute)
}

@(test)
revolute_limits_motor_and_spring_act_on_the_angle :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    pivot:=test_anchor(&w,{0,5,0})
    arm:=test_body(&w,Box{{0.5,0.05,0.05}},{0.5,5,0})
    body_set_sleep_disabled(&w,arm,true)
    desc:=test_joint(&w,.Revolute,pivot,arm,{0,5,0},{0,0,1})
    desc.angular[0]={motion=.Limited,lower=-0.5,upper=0.5}
    joint:=joint_create(&w,desc)
    test_steps(&w,180)
    expect_near(t,joint_angle(&w,joint),-0.5,0.02)
    // A motor strong enough lifts the arm to the upper limit and holds it there.
    test_axis_set(&w,joint,true,0,{motion=.Limited,lower=-0.5,upper=0.5,drive={.Velocity},velocity=1,max_force=500})
    test_steps(&w,30)
    testing.expect(t,joint_angle(&w,joint)>-0.1)
    test_steps(&w,120)
    expect_near(t,joint_angle(&w,joint),0.5,0.02)
    // Without limits the motor keeps its speed.
    test_axis_set(&w,joint,true,0,{drive={.Velocity},velocity=1,max_force=500})
    test_steps(&w,60)
    expect_near(t,body_angular_velocity(&w,arm).z,1,0.02)
    // A stiff spring holds the arm near its target against gravity.
    test_axis_set(&w,joint,true,0,{drive={.Position},position=0.3,hertz=8,damping_ratio=1,max_force=max(f32)})
    test_steps(&w,240)
    expect_near(t,joint_angle(&w,joint),0.3,0.05)
}

@(test)
a_prismatic_joint_slides_along_its_axis :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    rail:=test_anchor(&w,{0,5,0})
    slider:=test_body(&w,Box{{0.2,0.2,0.2}},{0,5,0})
    body_set_sleep_disabled(&w,slider,true)
    axis:=normalize(Vec3{1,-1,0})
    desc:=test_joint(&w,.Prismatic,rail,slider,{0,5,0},axis)
    desc.linear[0]={motion=.Limited,lower=-1,upper=2}
    joint:=joint_create(&w,desc)
    for _ in 0..<180 {
        world_step(&w,1.0/60)
        offset:=body_position(&w,slider)-Vec3{0,5,0}
        testing.expect(t,length(offset-axis*dot(offset,axis))<0.01)
        testing.expect(t,abs(body_rotation(&w,slider).w)>0.99999)
    }
    expect_near(t,joint_translation(&w,joint),2,0.02)
    test_axis_set(&w,joint,false,0,{motion=.Limited,lower=-1,upper=2,drive={.Velocity},velocity=-1,max_force=4000})
    test_steps(&w,60)
    expect_near(t,joint_translation(&w,joint),1,0.05)
    test_steps(&w,180)
    expect_near(t,joint_translation(&w,joint),-1,0.02)
    test_axis_set(&w,joint,false,0,{drive={.Position},position=0.5,hertz=3,damping_ratio=1,max_force=max(f32)})
    test_steps(&w,300)
    // The spring rests where it balances gravity along the axis: stretched by g sin / w^2.
    sag:f32=9.81*0.70710678/(4*cmath.PI*cmath.PI*9)
    expect_near(t,joint_translation(&w,joint),0.5+sag,0.02)
}

@(test)
a_spherical_joint_keeps_the_anchor_and_its_cone :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    pivot:=test_anchor(&w,{0,5,0})
    rod:=test_body(&w,Box{{0.05,0.5,0.05}},{0,4.5,0})
    body_set_sleep_disabled(&w,rod,true)
    desc:=test_joint(&w,.Spherical,pivot,rod,{0,5,0},{0,-1,0})
    desc.angular={{motion=.Limited,lower=-0.2,upper=0.2},{motion=.Limited,lower=-0.4,upper=0.4},{motion=.Limited,lower=-0.4,upper=0.4}}
    joint_create(&w,desc)
    body_set_velocity(&w,rod,{4,0,3},{0,6,0})
    widest,twisted:f32
    frame:=q_between({1,0,0},{0,-1,0})
    for _ in 0..<300 {
        world_step(&w,1.0/60)
        xf:=body_transform(&w,rod)
        expect_near3(t,xf_point(xf,{0,0.5,0}),{0,5,0},0.02)
        down:=q_rotate(xf.q,Vec3{0,-1,0})
        widest=max(widest,cmath.acos(clamp(dot(down,Vec3{0,-1,0}),-1,1)))
        twisted=max(twisted,abs(twist_angle(frame,xf.q*frame)))
    }
    testing.expectf(t,widest>0.3 && widest<0.45,"swung out to %v",widest)
    testing.expectf(t,twisted<0.25,"twisted to %v",twisted)
}

@(test)
a_distance_joint_keeps_or_springs_its_length :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    hook:=test_anchor(&w,{0,5,0})
    weight:=test_body(&w,Sphere{0.2},{1.5,5,0})
    body_set_sleep_disabled(&w,weight,true)
    rope:=joint_create(&w,test_distance(hook,weight,1.5,1.5))
    for _ in 0..<240 {
        world_step(&w,1.0/60)
        expect_near(t,joint_distance(&w,rope),1.5,0.02)
    }
    joint_destroy(&w,rope)
    // A soft spring of rest length 1 stretches under the weight but not past its upper limit.
    body_set_transform(&w,weight,{0,4,0},QUAT_IDENTITY)
    body_set_velocity(&w,weight,{},{})
    body_set_damping(&w,weight,0.5,0)
    desc:=test_distance(hook,weight,0.5,1.15)
    desc.linear[0].drive,desc.linear[0].position,desc.linear[0].hertz,desc.linear[0].damping_ratio,desc.linear[0].max_force={.Position},1,1,0.5,max(f32)
    spring:=joint_create(&w,desc)
    longest:f32
    for _ in 0..<480 {
        world_step(&w,1.0/60)
        longest=max(longest,joint_distance(&w,spring))
    }
    testing.expectf(t,longest>1.12 && longest<1.17,"stretched to %v",longest)
    // Its limits wide apart, the spring alone holds the weight.
    wide:=desc.linear
    for &axis in wide {axis.lower,axis.upper=0,100}
    joint_set_axes(&w,spring,wide,{})
    test_steps(&w,600)
    expect_near(t,joint_distance(&w,spring),1+9.81/(4*cmath.PI*cmath.PI),0.03)
}

@(test)
a_hanging_chain_stays_connected :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    previous:=test_anchor(&w,{0,10,0})
    links:[12]Body_Handle
    for i in 0..<12 {
        links[i]=test_body(&w,Capsule{0.1,0.2},{0.25+f32(i)*0.5,10,0})
        body_set_transform(&w,links[i],{0.25+f32(i)*0.5,10,0},q_axis_angle({0,0,1},cmath.PI/2))
        joint_create(&w,test_joint(&w,.Spherical,previous,links[i],{f32(i)*0.5,10,0}))
        previous=links[i]
    }
    worst:f32
    for _ in 0..<600 {
        world_step(&w,1.0/60)
        end:=Vec3{0,10,0}
        for link in links {
            xf:=body_transform(&w,link)
            worst=max(worst,length(xf_point(xf,{0,0.25,0})-end))
            end=xf_point(xf,{0,-0.25,0})
        }
    }
    testing.expectf(t,worst<0.03,"a link separated by %v",worst)
}

@(test)
an_overloaded_joint_breaks_and_reports_it :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    wall:=test_anchor(&w,{0,5,0})
    light:=test_body(&w,Box{{0.1,0.1,0.1}},{0.2,5,0})
    heavy:=test_body(&w,Box{{0.5,0.5,0.5}},{0.6,8,0})
    desc:=test_joint(&w,.Fixed,wall,light,{0,5,0})
    desc.break_force=5000
    kept:=joint_create(&w,desc)
    desc=test_joint(&w,.Fixed,wall,heavy,{0,8,0})
    desc.break_force=5000
    desc.user_data=7
    broken:=joint_create(&w,desc)
    testing.expect_value(t,joint_user_data(&w,broken),7)
    events:=0
    for _ in 0..<30 {
        world_step(&w,1.0/60)
        for event in world_events(&w).joint_break {
            events+=1
            testing.expect_value(t,event.joint,broken)
            testing.expect_value(t,event.body_b,heavy)
            testing.expect(t,event.force>5000)
        }
    }
    testing.expect_value(t,events,1)
    testing.expect(t,!joint_valid(&w,broken))
    testing.expect(t,joint_valid(&w,kept))
    testing.expect(t,body_position(&w,heavy).y<7.9)
    expect_near3(t,body_position(&w,light),{0.2,5,0},0.01)
}

@(test)
joined_bodies_collide_only_when_asked :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    a:=test_body(&w,Box{{0.5,0.5,0.5}},{0,0,0})
    b:=test_body(&w,Box{{0.5,0.5,0.5}},{0.9,0,0})
    world_step(&w,1.0/60)
    testing.expect_value(t,world_stats(&w).contacts,1)
    joint:=joint_create(&w,test_joint(&w,.Revolute,a,b,{0.45,0,0},{0,0,1}))
    testing.expect_value(t,world_stats(&w).contacts,0)
    test_steps(&w,30)
    testing.expect_value(t,world_stats(&w).contacts,0)
    joint_destroy(&w,joint)
    world_step(&w,1.0/60)
    testing.expect_value(t,world_stats(&w).contacts,1)
    desc:=test_joint(&w,.Revolute,a,b,body_position(&w,a)+{0.45,0,0},{0,0,1})
    desc.collide_connected=true
    joint_create(&w,desc)
    testing.expect_value(t,world_stats(&w).contacts,1)
}

@(test)
joint_capacity_and_invalid_bodies_are_refused :: proc(t:^testing.T) {
    w:World
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=16,16,64,2
    testing.expect(t,world_init(&w,desc))
    defer world_destroy(&w)
    a:=test_body(&w,Sphere{0.5},{0,0,0})
    b:=test_body(&w,Sphere{0.5},{3,0,0})
    testing.expect_value(t,joint_create(&w,{body_a=a,body_b=a}),Joint_Handle{})
    testing.expect_value(t,joint_create(&w,{body_a=a}),Joint_Handle{})
    first:=joint_create(&w,test_distance(a,b,3,3))
    testing.expect(t,first!={})
    testing.expect(t,joint_create(&w,test_distance(a,b,3,3))!={})
    testing.expect_value(t,joint_create(&w,test_distance(a,b,3,3)),Joint_Handle{})
    testing.expect_value(t,world_stats(&w).joint_capacity_exhausted,1)
    // Destroying a body takes its joints with it.
    body_destroy(&w,b)
    testing.expect(t,!joint_valid(&w,first))
    testing.expect_value(t,world_stats(&w).joints,0)
    testing.expect(t,joint_create(&w,test_distance(a,test_body(&w,Sphere{0.5},{3,0,0}),3,3))!={})
}

@(test)
no_motor_pushes_a_revolute_or_prismatic_joint_through_its_limit :: proc(t:^testing.T) {
    for torque in ([?]f32{1e4,1e6,1e8}) {
        w:World
        testing.expect(t,test_world(&w))
        defer world_destroy(&w)
        anchor:=test_body(&w,Box{{0.1,0.1,0.1}},{0,2,0},.Static)
        arm:=test_body(&w,Box{{1,0.1,0.1}},{1,2,0})
        hinge_desc:=test_joint(&w,.Revolute,anchor,arm,{0,2,0},{0,0,1})
        hinge_desc.angular[0]={motion=.Limited,lower=-0.5,upper=0.5,drive={.Velocity},velocity=10,max_force=torque}
        hinge:=joint_create(&w,hinge_desc)
        slider_base:=test_body(&w,Box{{0.1,0.1,0.1}},{5,2,0},.Static)
        slider:=test_body(&w,Box{{0.2,0.2,0.2}},{5,2,0})
        rail_desc:=test_joint(&w,.Prismatic,slider_base,slider,{5,2,0},{1,0,0})
        rail_desc.linear[0]={motion=.Limited,lower=-1,upper=1,drive={.Velocity},velocity=20,max_force=torque*10}
        rail:=joint_create(&w,rail_desc)
        widest,farthest:f32
        for _ in 0..<120 {
            world_step(&w,1.0/60)
            widest=max(widest,joint_angle(&w,hinge))
            farthest=max(farthest,joint_translation(&w,rail))
        }
        testing.expectf(t,widest<0.52 && abs(joint_angle(&w,hinge)-0.5)<1e-3,"%v N m: the hinge reached %v and rests at %v",torque,widest,joint_angle(&w,hinge))
        testing.expectf(t,farthest<1.02 && abs(joint_translation(&w,rail)-1)<1e-3,"%v N: the slider reached %v and rests at %v",torque*10,farthest,joint_translation(&w,rail))
    }
}
