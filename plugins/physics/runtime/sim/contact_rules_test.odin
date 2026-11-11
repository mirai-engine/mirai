package mirai_physics

import "core:testing"

@(private="file")
rules_floor :: proc(w:^World,half:Vec3,position:Vec3,surface_speed:Vec3={},one_way:=false,rotation:=QUAT_IDENTITY) -> (Body_Handle,Shape_Handle) {
    desc:=BODY_DESC_DEFAULT
    desc.type=.Static
    desc.position,desc.rotation=position,rotation
    body:=body_create(w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{half}
    shape.surface_speed,shape.one_way=surface_speed,one_way
    return body,shape_create(w,body,shape)
}

@(private="file")
rules_box :: proc(w:^World,half,position,velocity:Vec3,friction:f32=0.6,dominance:i8=0) -> Body_Handle {
    desc:=BODY_DESC_DEFAULT
    desc.position,desc.linear_velocity=position,velocity
    body:=body_create(w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{half}
    shape.friction,shape.dominance=friction,dominance
    shape_create(w,body,shape)
    return body
}

@(test)
a_conveyor_carries_a_box_at_the_speed_of_its_surface :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    // The belt is turned a quarter about Y: its local +X runs along the world -Z.
    _,belt:=rules_floor(&w,{10,0.5,10},{0,-0.5,0},{2,0,0},false,q_axis_angle(UP,PI/2))
    box:=rules_box(&w,{0.25,0.25,0.25},{0,0.25,0},{})
    test_steps(&w,120)
    v:=body_linear_velocity(&w,box)
    testing.expectf(t,abs(v.z+2)<0.05 && abs(v.x)<0.05,"carried at %v",v)
    testing.expect(t,body_position(&w,box).z< -2)
    // Stopping the belt stops what it carries, without making the shape again.
    shape_set_surface(&w,belt,{},false,0)
    speed,one_way,dominance:=shape_surface(&w,belt)
    testing.expect(t,speed=={} && !one_way && dominance==0)
    test_steps(&w,60)
    testing.expectf(t,length(body_linear_velocity(&w,box))<0.05,"stopped at %v",body_linear_velocity(&w,box))
}

@(test)
a_one_way_platform_lets_bodies_up_through_it_and_holds_them_from_above :: proc(t:^testing.T) {
    for bullet in ([2]bool{false,true}) {
        w:World
        testing.expect(t,test_world(&w))
        defer world_destroy(&w)
        test_ground(&w)
        rules_floor(&w,{2,0.1,2},{0,3,0},{},true)
        // Thrown up from below it goes through, falls back and stays on top.
        box:=rules_box(&w,{0.25,0.25,0.25},{0,1.5,0},{0,10,0})
        body_set_bullet(&w,box,bullet)
        rose:=false
        for _ in 0..<240 {
            world_step(&w,1.0/60)
            rose||=body_position(&w,box).y>3.5
        }
        testing.expectf(t,rose,"bullet %v: went up through the platform",bullet)
        y:=body_position(&w,box).y
        testing.expectf(t,abs(y-3.35)<0.03,"bullet %v: rests on top at %v",bullet,y)
    }
    // A platform turned upside down blocks from below instead.
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    rules_floor(&w,{2,0.1,2},{0,3,0},{},true,q_axis_angle({1,0,0},PI))
    box:=rules_box(&w,{0.25,0.25,0.25},{0,1.5,0},{0,10,0})
    test_steps(&w,30)
    testing.expect(t,body_position(&w,box).y<2.7)
}

@(test)
a_one_way_platform_turned_off_blocks_what_was_going_through :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    _,platform:=rules_floor(&w,{2,0.1,2},{0,3,0},{},true)
    box:=rules_box(&w,{0.25,0.25,0.25},{0,2.6,0},{0,4,0})
    body_set_gravity_scale(&w,box,0)
    world_step(&w,1.0/60)
    shape_set_surface(&w,platform,{},false,0)
    test_steps(&w,10)
    // Halfway through when the rule went: the solver pushes it out of the platform.
    testing.expect(t,abs(body_position(&w,box).y-3)>0.3)
}

@(test)
the_shape_of_more_dominance_is_not_pushed_back_by_a_dynamic_body :: proc(t:^testing.T) {
    for dominance in ([2]i8{0,1}) {
        w:World
        testing.expect(t,test_world(&w))
        defer world_destroy(&w)
        test_ground(&w)
        pusher:=rules_box(&w,{0.5,0.5,0.5},{-2,0.5,0},{3,0,0},0,dominance)
        pushed:=rules_box(&w,{0.5,0.5,0.5},{0,0.5,0},{},0)
        test_steps(&w,40)
        a,b:=body_linear_velocity(&w,pusher).x,body_linear_velocity(&w,pushed).x
        if dominance>0 {
            testing.expectf(t,abs(a-3)<0.05 && b>=a-0.05,"the dominant box keeps its speed: %v and %v",a,b)
        } else {
            testing.expectf(t,a<2.5,"equal boxes share the push: %v and %v",a,b)
        }
    }
}

@(test)
a_dominant_body_still_rests_on_static_ground :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    box:=rules_box(&w,{0.5,0.5,0.5},{0,0.6,0},{},0.6,100)
    test_steps(&w,120)
    testing.expectf(t,abs(body_position(&w,box).y-0.5)<0.02,"rests at %v",body_position(&w,box).y)
}

@(test)
a_fast_body_that_goes_through_a_thin_trigger_begins_and_ends_the_overlap_in_the_step :: proc(t:^testing.T) {
    for bullet in ([2]bool{false,true}) {
        w:World
        testing.expect(t,test_world(&w))
        defer world_destroy(&w)
        desc:=BODY_DESC_DEFAULT
        desc.type=.Static
        trigger_body:=body_create(&w,desc)
        shape:=SHAPE_DESC_DEFAULT
        shape.geometry=Box{{0.02,2,2}}
        shape.filter=Filter{layers=1,overlap=0xffffffff}
        trigger:=shape_create(&w,trigger_body,shape)
        ball:=test_bullet(&w,{-1,0,0},{200,0,0},bullet)
        world_step(&w,1.0/60)
        events:=world_events(&w)
        testing.expect_value(t,len(events.overlap_begin),2)
        testing.expect_value(t,len(events.overlap_end),2)
        if len(events.overlap_begin)==2 {
            testing.expect(t,events.overlap_begin[0].crossed && events.overlap_end[1].crossed)
            testing.expect(t,events.overlap_begin[0].body==ball && events.overlap_begin[0].other==trigger || events.overlap_begin[1].body==ball && events.overlap_begin[1].other==trigger)
        }
        // It keeps going: nothing is left of the pair at the next step.
        testing.expect(t,body_position(&w,ball).x>2)
        world_step(&w,1.0/60)
        testing.expect_value(t,len(world_events(&w).overlap_begin),0)
        testing.expect_value(t,len(world_events(&w).overlap_end),0)
    }
}

@(test)
a_bullet_stopped_by_a_wall_before_a_trigger_does_not_cross_it :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_body(&w,Box{{0.01,2,2}},{0.5,0,0},.Static,0)
    desc:=BODY_DESC_DEFAULT
    desc.type=.Static
    desc.position={1,0,0}
    trigger_body:=body_create(&w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{{0.02,2,2}}
    shape.filter=Filter{layers=1,overlap=0xffffffff}
    shape_create(&w,trigger_body,shape)
    test_bullet(&w,{-1,0,0},{200,0,0},true)
    world_step(&w,1.0/60)
    testing.expect_value(t,len(world_events(&w).overlap_begin),0)
    testing.expect_value(t,len(world_events(&w).contact_begin),1)
}

@(test)
a_bullet_that_stops_inside_a_trigger_begins_it_once :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    desc:=BODY_DESC_DEFAULT
    desc.type=.Static
    trigger_body:=body_create(&w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{{1,2,2}}
    shape.filter=Filter{layers=1,overlap=0xffffffff}
    shape_create(&w,trigger_body,shape)
    // 200 m/s for a tick reaches 3.33 m: from -3 it ends inside the box that spans -1..1.
    ball:=test_bullet(&w,{-3,0,0},{180,0,0},true)
    world_step(&w,1.0/60)
    testing.expect_value(t,len(world_events(&w).overlap_begin),0)
    body_set_velocity(&w,ball,{},{})
    world_step(&w,1.0/60)
    testing.expect_value(t,len(world_events(&w).overlap_begin),2)
    if len(world_events(&w).overlap_begin)>0 {testing.expect(t,!world_events(&w).overlap_begin[0].crossed)}
}

@(test)
a_conveyor_carries_a_character_standing_still :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    rules_floor(&w,{20,0.5,20},{0,-0.5,0},{0,0,1.5})
    ch:=test_character(&w,{0,0,0})
    test_steps(&w,120)
    testing.expectf(t,abs(character_velocity(&w,ch).z-1.5)<0.1,"carried at %v",character_velocity(&w,ch))
    testing.expect(t,character_position(&w,ch).z>2)
}

@(test)
contact_rules_replay_identically_after_restore :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    rules_floor(&w,{3,0.1,3},{0,2,0},{1,0,0},true)
    a:=rules_box(&w,{0.25,0.25,0.25},{0,0.5,0},{0,9,0},0.6,2)
    rules_box(&w,{0.25,0.25,0.25},{0.6,0.5,0},{0,9,0})
    body_set_bullet(&w,a,true)
    test_steps(&w,10)
    buffer:World
    defer world_destroy(&buffer)
    ok:=test_keep(&buffer,&w)
    testing.expect(t,ok)
    test_steps(&w,60)
    expected:=world_hash(&w)
    testing.expect(t,test_restore(&w,&buffer))
    test_steps(&w,60)
    testing.expect_value(t,world_hash(&w),expected)
}
