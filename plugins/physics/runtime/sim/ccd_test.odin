package mirai_physics

import "core:testing"

@(test)
ccd_stops_or_bounces_and_emits_the_impulse_in_the_impact_tick :: proc(t:^testing.T) {
    for restitution in ([2]f32{0,0.8}) {
        w:World
        testing.expect(t,test_world(&w))
        defer world_destroy(&w)
        wall:=test_body(&w,Box{{0.01,2,2}},{},.Static,0,restitution)
        bullet:=test_bullet(&w,{-1,0,0},{200,0,0},true)
        world_step(&w,1.0/60)
        testing.expect(t,body_position(&w,bullet).x<0)
        testing.expectf(t,abs(body_linear_velocity(&w,bullet).x+200*restitution)<0.01,"velocity %v",body_linear_velocity(&w,bullet))
        events:=world_events(&w)
        testing.expect_value(t,len(events.contact_begin),1)
        if len(events.contact_begin)==1 {
            testing.expect(t,events.contact_begin[0].impulse>0)
            testing.expect(t,events.contact_begin[0].body_a==wall || events.contact_begin[0].body_b==wall)
        }
        position:=body_position(&w,bullet)
        world_step(&w,1.0/60)
        testing.expect_value(t,len(world_events(&w).contact_begin),0)
        if restitution>0 {testing.expect(t,body_position(&w,bullet).x<position.x-1)}
    }
}

@(test)
ccd_resolves_an_approaching_speculative_contact_and_releases_a_departing_sweep :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_body(&w,Box{{0.01,2,2}},{},.Static,0)
    a:=test_bullet(&w,{-0.066,0,0},{200,0,0},true)
    world_step(&w,1.0/60)
    testing.expectf(t,abs(body_linear_velocity(&w,a).x)<0.01,"speculative velocity %v",body_linear_velocity(&w,a))
    testing.expect_value(t,len(world_events(&w).contact_begin),1)
    body_set_velocity(&w,a,{-50,0,0},{})
    world_step(&w,1.0/60)
    testing.expect(t,body_position(&w,a).x< -0.8)
}

@(test)
ccd_transfers_momentum_to_a_sleeping_target_and_wakes_its_joint_island :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    a:=test_bullet(&w,{-1,0,0},{200,0,0},true)
    b:=test_bullet(&w,{},{},false)
    c:=test_bullet(&w,{0,2,0},{},false)
    joint_create(&w,test_distance(b,c,2,2))
    body_set_awake(&w,b,false)
    testing.expect(t,!body_is_awake(&w,b) && !body_is_awake(&w,c))
    world_step(&w,1.0/60)
    testing.expectf(t,abs(body_linear_velocity(&w,a).x-100)<0.02,"bullet %v",body_linear_velocity(&w,a))
    testing.expectf(t,abs(body_linear_velocity(&w,b).x-100)<0.02,"target %v",body_linear_velocity(&w,b))
    testing.expect(t,body_is_awake(&w,b) && body_is_awake(&w,c))
    testing.expect_value(t,len(world_events(&w).contact_begin),1)
}

@(test)
ccd_applies_friction_angular_response_and_respects_angular_locks :: proc(t:^testing.T) {
    for locked in ([2]bool{false,true}) {
        w:World
        testing.expect(t,test_world(&w))
        defer world_destroy(&w)
        test_body(&w,Box{{0.01,4,4}},{},.Static,1)
        bullet:=test_bullet(&w,{-1,0,0},{200,30,0},true)
        if locked {body_set_locks(&w,bullet,{.Lock_Angular_X,.Lock_Angular_Y,.Lock_Angular_Z})}
        world_step(&w,1.0/60)
        testing.expect(t,abs(body_linear_velocity(&w,bullet).x)<0.01)
        testing.expect(t,body_linear_velocity(&w,bullet).y<29)
        if locked {testing.expect_value(t,body_angular_velocity(&w,bullet),Vec3{})}
        else {testing.expect(t,length(body_angular_velocity(&w,bullet))>1)}
    }
}

@(test)
ccd_deduplicates_two_bullets_and_preserves_the_first_impact :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    a:=test_bullet(&w,{-1,0,0},{200,0,0},true)
    b:=test_bullet(&w,{1,0,0},{-200,0,0},true)
    world_step(&w,1.0/60)
    testing.expect(t,abs(body_linear_velocity(&w,a).x)<0.01)
    testing.expect(t,abs(body_linear_velocity(&w,b).x)<0.01)
    testing.expect_value(t,len(world_events(&w).contact_begin),1)
}

@(test)
ccd_searches_again_when_its_target_stopped_before_the_impact :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    a:=test_bullet(&w,{-1,0,0},{200,0,0},true)
    b:=test_bullet(&w,{1,0,0},{-200,0,0},true)
    wall:=test_body(&w,Box{{0.01,2,2}},{0.5,0,0},.Static,0)
    world_step(&w,1.0/60)
    // The wall stops b on its right before a reaches where b would have been (x=-0.05). a does not answer
    // that discarded trajectory, and searching again it meets the left face of the wall instead of
    // crossing it.
    pa,pb:=body_position(&w,a).x,body_position(&w,b).x
    testing.expectf(t,abs(pa-0.435)<0.002 && abs(pb-0.565)<0.002,"a at %v and b at %v",pa,pb)
    testing.expect(t,abs(body_linear_velocity(&w,a).x)<0.01 && abs(body_linear_velocity(&w,b).x)<0.01)
    events:=world_events(&w)
    testing.expect_value(t,len(events.contact_begin),2)
    for event in events.contact_begin {testing.expect(t,event.body_a==wall || event.body_b==wall)}
    test_steps(&w,30)
    testing.expect(t,body_position(&w,a).x<0.45 && body_position(&w,b).x>0.55)
}

@(test)
ccd_mesh_and_heightfield_impacts_respond_in_the_same_tick :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    mesh,_:=test_grid_mesh(&w,8,16)
    test_static_shape(&w,mesh)
    field,_:=test_heights(&w,9,9,{2,1,2},proc(column,row:int)->f32 {return 0})
    test_static_shape(&w,field,{100,0,0})
    a:=test_bullet(&w,{0.3,1,0.2},{0,-200,0},true)
    b:=test_bullet(&w,{108.3,1,8.2},{0,-200,0},true)
    world_step(&w,1.0/60)
    for body in ([2]Body_Handle{a,b}) {
        testing.expect(t,body_position(&w,body).y>0)
        testing.expect(t,abs(body_linear_velocity(&w,body).y)<0.01)
    }
    testing.expect_value(t,len(world_events(&w).contact_begin),2)
}

@(test)
ccd_skips_overlapping_and_ignored_layers :: proc(t:^testing.T) {
    for overlap in ([2]bool{false,true}) {
        w:World
        testing.expect(t,test_world(&w))
        defer world_destroy(&w)
        body:=BODY_DESC_DEFAULT
        body.type=.Static
        wall:=body_create(&w,body)
        shape:=SHAPE_DESC_DEFAULT
        shape.geometry=Box{{0.01,2,2}}
        shape.filter=overlap?Filter{layers=1,overlap=0xffffffff}:Filter{layers=1}
        shape_create(&w,wall,shape)
        a:=test_bullet(&w,{-1,0,0},{200,0,0},true)
        world_step(&w,1.0/60)
        testing.expect(t,body_position(&w,a).x>1)
        testing.expect_value(t,len(world_events(&w).contact_begin),0)
    }
}

@(test)
bullets_and_fast_moving_targets_use_both_trajectories :: proc(t:^testing.T) {
    for other_bullet in ([2]bool{false,true}) {
        w:World
        testing.expect(t,test_world(&w))
        defer world_destroy(&w)
        a:=test_bullet(&w,{-1,0,0},{200,0,0},true)
        b:=test_bullet(&w,{1,0,0},{-200,0,0},other_bullet)
        world_step(&w,1.0/60)
        testing.expectf(t,body_position(&w,a).x<body_position(&w,b).x,"crossed: %v %v",body_position(&w,a),body_position(&w,b))
        test_steps(&w,30)
        testing.expect(t,body_position(&w,a).x<body_position(&w,b).x)
    }
}

@(test)
a_resting_bullet_detects_a_target_crossing_its_path_during_the_tick :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    bullet:=test_bullet(&w,{},{},true)
    plate:=test_bullet(&w,{-1,0,0},{200,0,0},false,Box{{0.01,1,1}})
    world_step(&w,1.0/60)
    testing.expectf(t,body_position(&w,plate).x<body_position(&w,bullet).x,"plate crossed: %v %v",body_position(&w,plate),body_position(&w,bullet))
}

@(test)
continuous_collision_uses_immutable_sweeps_with_threads_and_after_restore :: proc(t:^testing.T) {
    pool:Test_Pool
    test_pool_init(&pool,4)
    defer test_pool_destroy(&pool)
    a,b:World
    testing.expect(t,test_world_threaded(&a,nil,128,512,16))
    testing.expect(t,test_world_threaded(&b,&pool,128,512,16))
    defer world_destroy(&a)
    defer world_destroy(&b)
    for w in ([2]^World{&a,&b}) {
        for i in 0..<32 {
            z:=f32(i)*2
            test_bullet(w,{-1,0,z},{200,0,0},true)
            test_bullet(w,{1,0,z},{-200,0,0},true)
        }
    }
    before:World
    defer world_destroy(&before)
    test_keep(&before,&a)
    for _ in 0..<40 {
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        testing.expect_value(t,world_hash(&a),world_hash(&b))
    }
    final:=world_hash(&a)
    testing.expect(t,test_restore(&a,&before))
    test_steps(&a,40)
    testing.expect_value(t,world_hash(&a),final)
}

@(private)
test_bullet :: proc(w:^World,position,velocity:Vec3,bullet:bool,geometry:Geometry=Sphere{0.05}) -> Body_Handle {
    desc:=BODY_DESC_DEFAULT
    desc.position=position
    desc.linear_velocity=velocity
    desc.bullet=bullet
    desc.gravity_scale=0
    body:=body_create(w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=geometry
    shape_create(w,body,shape)
    return body
}

@(test)
small_fast_bodies_do_not_cross_meshes_heightfields_or_thin_walls :: proc(t:^testing.T) {
    Target :: enum {Mesh,Wall,Heightfield}
    geometries:=[3]proc(size:f32)->Geometry{
        proc(size:f32)->Geometry {return Sphere{size}},
        proc(size:f32)->Geometry {return Box{{size,size,size}}},
        proc(size:f32)->Geometry {return Capsule{size,size}},
    }
    sizes:=[3]f32{0.05,0.15,0.5}
    speeds:=[4]f32{5,20,80,200}
    for target in Target {
        for bullet in ([2]bool{false,true}) {
            w:World
            testing.expect(t,test_world(&w))
            defer world_destroy(&w)
            // The surface is the plane y=0, or x=0 for the wall, which is 2 cm thick.
            switch target {
            case .Mesh:
                mesh,_:=test_grid_mesh(&w,8,60)
                test_static_shape(&w,mesh)
            case .Heightfield:
                field,_:=test_heights(&w,31,31,{2,1,2},proc(column,row:int)->f32 {return 0})
                test_static_shape(&w,field,{-30,0,-30})
            case .Wall:
                test_static_shape(&w,Box{{0.01,30,30}},{-0.01,0,0})
            }
            normal:=target==.Wall?Vec3{-1,0,0}:Vec3{0,1,0}
            bodies:[len(geometries)*len(sizes)*len(speeds)]Body_Handle
            for &body,i in bodies {
                size,speed:=sizes[i/len(speeds)%len(sizes)],speeds[i%len(speeds)]
                along:=Vec3{f32(i%6)*4-10,0,f32(i/6)*4-10}
                if target==.Wall {along={0,along.x,along.z}}
                // Starts close enough that the fastest cross the surface within the first step.
                body=test_bullet(&w,along+normal*(2*size+0.6*speed/60),-normal*speed,bullet,geometries[i/(len(speeds)*len(sizes))](size))
                body_set_velocity(&w,body,-normal*speed,{3,5,7})
            }
            test_steps(&w,30)
            for body,i in bodies {
                testing.expectf(t,dot(body_position(&w,body),normal)>0,"%v bullet=%v body %v crossed: %v",target,bullet,i,body_position(&w,body))
            }
        }
    }
}

@(test)
bullets_land_on_moving_bodies :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    // A plate that crosses the path: the bullet is stopped where the plate is at the end of the step.
    plate:=test_bullet(&w,{50,5,0},{0,0,0},false,Box{{2,0.02,2}})
    body_set_gravity_scale(&w,plate,0)
    on_plate:=test_bullet(&w,{50,20,0},{0,-200,0},true)
    test_steps(&w,20)
    testing.expect(t,body_position(&w,on_plate).y>body_position(&w,plate).y)
    testing.expect(t,body_linear_velocity(&w,plate).y<0)
}
