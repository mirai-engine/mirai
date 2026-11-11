package mirai_physics

import "core:testing"
import cmath "core:math"

@(private)
test_character_world :: proc(w:^World,characters:=8,pool:^Test_Pool=nil) -> bool {
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=128,128,1024,16
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=8,4,2,256
    desc.character_capacity=characters
    if pool!=nil {
        desc.worker_count=pool.workers
        desc.parallel_for=test_pool_parallel_for
        desc.parallel_user=pool
    }
    return world_init(w,desc)
}

@(private)
test_static_box :: proc(w:^World,half,position:Vec3,rotation:=QUAT_IDENTITY,friction:f32=0.6) -> Body_Handle {
    desc:=BODY_DESC_DEFAULT
    desc.type=.Static
    desc.position,desc.rotation=position,rotation
    body:=body_create(w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{half}
    shape.friction=friction
    shape_create(w,body,shape)
    return body
}

@(private)
test_dynamic_box :: proc(w:^World,half,position:Vec3,mass:f32,friction:f32=0.6) -> Body_Handle {
    desc:=BODY_DESC_DEFAULT
    desc.position=position
    body:=body_create(w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{half}
    shape.friction=friction
    shape.density=mass/(8*half.x*half.y*half.z)
    shape_create(w,body,shape)
    return body
}

// A character that has come to rest on the ground under `position`, looking along -Z (yaw 0).
@(private)
test_character :: proc(w:^World,position:Vec3,desc:=Character_Desc{}) -> Character_Handle {
    d:=desc
    if d.radius==0 {d=CHARACTER_DESC_DEFAULT}
    return character_create(w,d,position)
}

// The move of a walk at 5 m/s toward `move`, in the axes of the yaw of the character: along the ground it
// stands on, or keeping its velocity in the air. A jump leaves the ground at the speed of 1.2 m.
@(private)
test_move :: proc(w:^World,ch:Character_Handle,move:Vec3,jump:=false) -> Character_Move {
    state:=character_state(w,ch)
    m:=character_move(w,ch)
    v:=character_velocity(w,ch)
    s,c:=cmath.sincos(m.yaw)
    wish:=Vec3{c*move.x+s*move.z,0,c*move.z-s*move.x}
    m.flags,m.launch={},{}
    m.air={}
    n:=state.ground_normal
    if .Hit not_in state.ground {n=UP}
    m.ground={force=character_desc(w,ch).traction_force}
    if wish!={} {
        along:=wish-UP*(dot(wish,n)/n.y)
        m.ground.velocity=along*(5*length(wish)/length(along))
    }
    if jump && .Standing in state.ground {m.launch=UP*(cmath.sqrt(f32(2*9.81*1.2))-(v.y-state.ground_velocity.y))}
    return m
}

@(private)
test_walk :: proc(w:^World,ch:Character_Handle,move:Vec3,ticks:int,jump:=false) {
    for _ in 0..<ticks {
        character_set_move(w,ch,test_move(w,ch,move,jump))
        test_steps(w,1)
    }
}

@(private)
test_standing :: proc(w:^World,ch:Character_Handle) -> bool {return .Standing in character_state(w,ch).ground}

@(private) near :: proc(a,b,tolerance:f32) -> bool {return abs(a-b)<=tolerance}

@(test)
a_character_dropped_on_the_ground_lands_and_stands :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    ch:=test_character(&w,{0,0.5,0})
    testing.expect(t,character_valid(&w,ch))
    test_steps(&w,1)
    testing.expect(t,!test_standing(&w,ch))
    test_steps(&w,90)
    state:=character_state(&w,ch)
    testing.expect(t,.Standing in state.ground)
    testing.expectf(t,near(character_position(&w,ch).y,0,0.005),"feet at %v",character_position(&w,ch).y)
    testing.expect(t,length(character_velocity(&w,ch))<0.01)
    testing.expect(t,near(state.ground_normal.y,1,1e-4) && abs(state.ground_distance)<0.005)
    // The capsule floats: nothing touches it.
    contacts:[4]Contact_Info
    testing.expect_value(t,body_contacts(&w,character_body(&w,ch),contacts[:]),0)
}

@(test)
walking_on_a_slope_keeps_the_target_speed_and_standing_does_not_slide :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    angle:f32=20*cmath.RAD_PER_DEG
    normal:=Vec3{0,cmath.cos(angle),cmath.sin(angle)}
    test_static_box(&w,{30,1,30},-normal,q_axis_angle({1,0,0},angle))
    ch:=test_character(&w,{0,0.1,0})
    test_steps(&w,60)
    testing.expect(t,test_standing(&w,ch))
    rest:=character_position(&w,ch)
    test_steps(&w,60)
    testing.expectf(t,length(character_position(&w,ch)-rest)<0.002,"slid %v",character_position(&w,ch)-rest)
    test_walk(&w,ch,{0,0,-1},60)
    up:=character_velocity(&w,ch)
    testing.expectf(t,near(length(up),5,0.05) && near(up.y,5*cmath.sin(angle),0.05),"uphill %v",up)
    test_walk(&w,ch,{0,0,1},90)
    down:=character_velocity(&w,ch)
    testing.expectf(t,near(length(down),5,0.05) && near(down.y,-5*cmath.sin(angle),0.05),"downhill %v",down)
    testing.expect(t,test_standing(&w,ch))
}

@(test)
a_wall_stops_a_walking_character :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    test_static_box(&w,{5,2,0.5},{0,2,-3.5})
    ch:=test_character(&w,{0,0,0})
    test_steps(&w,30)
    test_walk(&w,ch,{0,0,-1},20)
    testing.expect(t,character_state(&w,ch).wall_normal=={},"in the open it leans on no wall")
    test_walk(&w,ch,{0,0,-1},130)
    p:=character_position(&w,ch)
    testing.expectf(t,near(p.z,-2.7,0.02) && near(p.y,0,0.01),"position %v",p)
    testing.expect(t,length(character_velocity(&w,ch))<0.05)
    testing.expect(t,test_standing(&w,ch))
    state:=character_state(&w,ch)
    testing.expectf(t,length(state.wall_normal-{0,0,1})<1e-3 && near(state.wall_push,5,.05),"it leans on the wall, whose normal faces it, pushing at 5 m/s: %v %v",state.wall_normal,state.wall_push)
}

@(test)
steps_up_to_the_step_height_are_climbed_and_taller_ones_block :: proc(t:^testing.T) {
    // The step height is 0.3: a centimeter above it is an obstacle.
    for height,i in ([6]f32{0.15,0.28,0.3,0.31,0.36,0.5}) {
        w:World
        testing.expect(t,test_character_world(&w))
        test_ground(&w)
        test_static_box(&w,{5,0.5*height,10},{0,0.5*height,-12})
        ch:=test_character(&w,{0,0,0})
        test_steps(&w,30)
        highest:f32
        for _ in 0..<120 {
            test_walk(&w,ch,{0,0,-1},1)
            highest=max(highest,character_position(&w,ch).y)
        }
        p:=character_position(&w,ch)
        if i<3 {
            testing.expectf(t,p.z<-4 && near(p.y,height,0.01),"a step of %v was not climbed: %v",height,p)
            testing.expectf(t,highest<height+0.02,"hopped to %v over a step of %v",highest,height)
            testing.expect(t,test_standing(&w,ch))
        } else {
            // The bottom of the capsule rests against the edge; the axis never passes the face at z=-2.
            testing.expectf(t,p.z>-2 && highest<0.02,"a step of %v was climbed: %v, highest %v",height,p,highest)
        }
        world_destroy(&w)
    }
}

@(test)
walking_down_a_step_keeps_the_feet_on_the_ground :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    test_static_box(&w,{5,0.125,3},{0,0.125,0})
    ch:=test_character(&w,{0,0.25,0})
    test_steps(&w,30)
    for _ in 0..<90 {
        test_walk(&w,ch,{0,0,-1},1)
        testing.expect(t,test_standing(&w,ch))
    }
    p:=character_position(&w,ch)
    testing.expectf(t,p.z<-5 && near(p.y,0,0.01),"position %v",p)
}

@(test)
a_slope_steeper_than_the_limit_slides_the_character_down :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    angle:f32=60*cmath.RAD_PER_DEG
    normal:=Vec3{0,cmath.cos(angle),cmath.sin(angle)}
    test_static_box(&w,{30,1,30},-normal,q_axis_angle({1,0,0},angle))
    ch:=test_character(&w,{0,0.3,0})
    test_steps(&w,45)
    start:=character_position(&w,ch)
    state:=character_state(&w,ch)
    testing.expect(t,.Standing not_in state.ground)
    testing.expect(t,state.ground_body!={} && state.ground_normal.y<0.6)
    testing.expect(t,character_velocity(&w,ch).z>2 && start.y<-0.5)
    // Pushing uphill does not stop the slide.
    test_walk(&w,ch,{0,0,-1},45)
    testing.expect(t,character_velocity(&w,ch).z>2 && character_position(&w,ch).y<start.y-2)
    testing.expect(t,!test_standing(&w,ch))

    // Two such faces in a V hold it: it stands in the groove within half a second, and jumps out of it.
    v:World
    testing.expect(t,test_character_world(&v))
    defer world_destroy(&v)
    for side in ([2]f32{-1,1}) {
        n:=Vec3{-side*cmath.sin(angle),cmath.cos(angle),0}
        along:=Vec3{side*cmath.cos(angle),cmath.sin(angle),0}
        test_static_box(&v,{1.5,0.25,3},along*1.5-n*0.25,q_axis_angle({0,0,1},side*angle))
    }
    wedged:=test_character(&v,{0,1,0})
    test_walk(&v,wedged,{},30)
    held:=character_position(&v,wedged)
    for _ in 0..<30 {
        test_walk(&v,wedged,{},1)
        testing.expectf(t,test_standing(&v,wedged),"it stands in the groove at %v",character_position(&v,wedged))
    }
    testing.expectf(t,length(character_position(&v,wedged)-held)<0.01,"it stays where the groove holds it: %v from %v",character_position(&v,wedged),held)
    test_walk(&v,wedged,{},1,jump=true)
    testing.expectf(t,character_velocity(&v,wedged).y>4,"it jumps out: %v",character_velocity(&v,wedged))
}

@(test)
a_character_pushes_a_light_box_and_is_stopped_by_a_heavy_one :: proc(t:^testing.T) {
    for mass,i in ([2]f32{20,2000}) {
        w:World
        testing.expect(t,test_character_world(&w))
        test_ground(&w)
        box:=test_dynamic_box(&w,{0.5,0.5,0.5},{0,0.5,-2},mass)
        ch:=test_character(&w,{0,0,0})
        test_steps(&w,30)
        test_walk(&w,ch,{0,0,-1},120)
        moved:=-2-body_position(&w,box).z
        speed:=-character_velocity(&w,ch).z
        if i==0 {
            // Friction of the box on the ground: 0.6*20*9.81 N, far below the push force.
            testing.expectf(t,moved>5 && speed>4.5 && near(-body_linear_velocity(&w,box).z,speed,0.2),"moved %v at %v",moved,speed)
        } else {
            // 0.6*2000*9.81 N, more than the 3200 N of traction.
            testing.expectf(t,moved<0.02 && speed<0.05,"moved %v at %v",moved,speed)
        }
        world_destroy(&w)
    }
}

@(test)
the_push_force_caps_what_the_traction_of_a_character_passes_to_a_box :: proc(t:^testing.T) {
    for push in ([2]f32{800,0}) {
        w:World
        testing.expect(t,test_character_world(&w))
        test_ground(&w)
        // Each character starts against its box, so that only the push moves it. 0.6*300*9.81 N of
        // friction: more than 800 N, less than the 3200 N of traction.
        heavy:=test_dynamic_box(&w,{0.5,0.5,0.5},{0,0.5,-0.81},300)
        // Without friction the push accelerates the box and the character together.
        free_box:=test_dynamic_box(&w,{0.5,0.5,0.5},{4,0.5,-0.81},2000,0)
        desc:=CHARACTER_DESC_DEFAULT
        desc.push_force=push
        a:=test_character(&w,{0,0,0},desc)
        b:=test_character(&w,{4,0,0},desc)
        test_steps(&w,30)
        character_set_move(&w,b,test_move(&w,b,{0,0,-1}))
        test_walk(&w,a,{0,0,-1},30)
        start:=-body_linear_velocity(&w,free_box).z
        test_steps(&w,60)
        moved:=-0.81-body_position(&w,heavy).z
        gained:=-body_linear_velocity(&w,free_box).z-start
        if push>0 {
            testing.expectf(t,moved<0.02 && near(-character_velocity(&w,a).z,0,0.05),"the heavy box moved %v",moved)
            testing.expectf(t,near(gained,push/2080,0.03),"the free box gained %v m/s in a second",gained)
        } else {
            testing.expectf(t,moved>0.5,"the traction moved the heavy box %v",moved)
            testing.expectf(t,gained>1,"the free box gained %v m/s in a second",gained)
        }
        world_destroy(&w)
    }
}

@(test)
walking_on_a_free_cart_pushes_it_back_by_the_ratio_of_the_masses :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    cart:=test_dynamic_box(&w,{6,0.25,1},{0,0.25,0},160,0)
    ch:=test_character(&w,{-3,0.5,0})
    test_steps(&w,60)
    testing.expect_value(t,character_state(&w,ch).ground_body,cart)
    testing.expect(t,length(body_linear_velocity(&w,cart))<0.01)
    test_walk(&w,ch,{1,0,0},40)
    vc,vk:=character_velocity(&w,ch).x,body_linear_velocity(&w,cart).x
    // 80 kg against 160 kg at 5 m/s of relative speed, and no momentum from outside.
    testing.expectf(t,near(vc-vk,5,0.05),"relative speed %v",vc-vk)
    testing.expectf(t,near(vc,10.0/3,0.05) && near(vk,-5.0/3,0.05),"character %v, cart %v",vc,vk)
    // A jump pushes the cart down and back up, and leaves it its speed.
    test_walk(&w,ch,{1,0,0},1,true)
    testing.expect(t,character_velocity(&w,ch).y>4)
    testing.expect(t,near(body_linear_velocity(&w,cart).x,vk,0.05))
}

@(test)
a_character_rides_a_platform_that_moves_and_turns :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    platform:=test_body(&w,Box{{4,0.25,4}},{0,1,0},.Kinematic)
    ch:=test_character(&w,{2,1.25,1})
    test_steps(&w,30)
    testing.expect_value(t,character_state(&w,ch).ground_body,platform)
    local:=xf_inv_point(body_transform(&w,platform),character_position(&w,ch))
    body_set_velocity(&w,platform,{1.5,0,0.5},{0,0.8,0})
    test_steps(&w,30)
    local=xf_inv_point(body_transform(&w,platform),character_position(&w,ch))
    // Whoever moves it turns its yaw with the ground, and the body turns with the yaw.
    for _ in 0..<150 {
        move:=character_move(&w,ch)
        move.yaw+=character_state(&w,ch).ground_turn
        character_set_move(&w,ch,move)
        world_step(&w,1.0/60)
    }
    after:=xf_inv_point(body_transform(&w,platform),character_position(&w,ch))
    testing.expectf(t,length(after-local)<0.01,"drifted %v on the platform",after-local)
    testing.expect(t,body_position(&w,platform).x>4)
    testing.expectf(t,near(character_state(&w,ch).ground_turn,0.8/60,1e-4),"turn %v",character_state(&w,ch).ground_turn)
    testing.expectf(t,near(character_move(&w,ch).yaw,0.8*150.0/60,0.01),"yaw %v",character_move(&w,ch).yaw)
    facing:=q_rotate(body_transform(&w,character_body(&w,ch)).q,{0,0,-1})
    testing.expectf(t,length(facing-q_rotate(q_axis_angle(UP,character_move(&w,ch).yaw),{0,0,-1}))<1e-4,"facing %v",facing)
    testing.expect(t,test_standing(&w,ch))
    // Walking on it is relative to it, in the axes of the yaw.
    move:=character_move(&w,ch)
    move.yaw=0
    character_set_move(&w,ch,move)
    body_set_velocity(&w,platform,{1.5,0,0.5},{})
    test_walk(&w,ch,{0,0,-1},30)
    v:=character_velocity(&w,ch)
    testing.expectf(t,near(v.x,1.5,0.05) && near(v.z,0.5-5,0.05),"velocity %v",v)
}

@(test)
two_characters_pushing_each_other_stall_and_the_stronger_one_wins :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    a:=test_character(&w,{-2,0,0})
    b:=test_character(&w,{2,0,0})
    test_steps(&w,30)
    character_set_move(&w,b,test_move(&w,b,{-1,0,0}))
    test_walk(&w,a,{1,0,0},120)
    pa,pb:=character_position(&w,a),character_position(&w,b)
    testing.expectf(t,near(pb.x-pa.x,0.6,0.02) && abs(pa.x+pb.x)<0.2,"positions %v and %v",pa.x,pb.x)
    testing.expect(t,abs(character_velocity(&w,a).x)<0.05 && abs(character_velocity(&w,b).x)<0.05)
    strong:=character_desc(&w,a)
    strong.push_force*=3
    character_set_desc(&w,a,strong)
    test_steps(&w,90)
    va,vb:=character_velocity(&w,a).x,character_velocity(&w,b).x
    testing.expectf(t,va>1 && near(va,vb,0.1),"velocities %v and %v",va,vb)
    testing.expect(t,near(character_position(&w,b).x-character_position(&w,a).x,0.6,0.03))
}

@(test)
two_characters_of_a_yielding_pair_pass_through_each_other_and_end_apart :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    testing.expect(t,!world_set_push_rules(&w,{{a=1,b=1,force=0}}))
    testing.expect(t,!world_set_push_rules(&w,{{a=0,b=1,force=150}}))
    testing.expect(t,world_set_push_rules(&w,{{a=1,b=1,force=150}}))
    a:=test_character(&w,{-2,0,0})
    b:=test_character(&w,{2,0,0.1})
    test_steps(&w,30)
    character_set_move(&w,a,test_move(&w,a,{1,0,0}))
    character_set_move(&w,b,test_move(&w,b,{-1,0,0}))
    buffer:World
    defer world_destroy(&buffer)
    kept:=false
    highest:f32
    for _ in 0..<120 {
        pa,pb:=character_position(&w,a),character_position(&w,b)
        highest=max(highest,pa.y,pb.y)
        // Halfway through each other: what follows repeats bit for bit from here.
        if !kept && pb.x-pa.x<0.3 {
            kept=true
            testing.expect(t,test_keep(&buffer,&w))
            hashes:[40]u64
            for &hash in hashes {
                test_steps(&w,1)
                hash=world_hash(&w)
            }
            testing.expect(t,test_restore(&w,&buffer))
            for hash,i in hashes {
                test_steps(&w,1)
                highest=max(highest,character_position(&w,a).y,character_position(&w,b).y)
                if world_hash(&w)!=hash {
                    testing.expectf(t,false,"the hash diverged %v ticks after the restore",i)
                    return
                }
            }
        }
        test_steps(&w,1)
    }
    pa,pb:=character_position(&w,a),character_position(&w,b)
    testing.expect(t,kept)
    testing.expectf(t,highest<0.02,"one went over the other: %v m up",highest)
    testing.expectf(t,pa.x-pb.x>2 && near(pa.y,0,0.02) && near(pb.y,0,0.02),"positions %v and %v",pa,pb)
    testing.expectf(t,character_velocity(&w,a).x>4.5 && character_velocity(&w,b).x< -4.5,"velocities %v and %v",character_velocity(&w,a),character_velocity(&w,b))
}

@(test)
a_launch_throws_a_walking_character_into_the_air :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    ch:=test_character(&w,{0,0,0})
    test_steps(&w,30)
    character_launch(&w,ch,{2,0,0})
    character_launch(&w,ch,{0,6,0})
    test_steps(&w,1)
    testing.expect(t,!test_standing(&w,ch))
    v:=character_velocity(&w,ch)
    testing.expectf(t,near(v.x,2,0.01) && near(v.y,6,0.2),"velocity %v",v)
    apex:f32
    for _ in 0..<90 {
        test_steps(&w,1)
        apex=max(apex,character_position(&w,ch).y)
    }
    testing.expectf(t,near(apex,36/(2*9.81),0.06),"apex %v",apex)
    testing.expect(t,test_standing(&w,ch))
    character_launch(&w,ch,{0,0,-3},true)
    test_steps(&w,1)
    testing.expect(t,character_velocity(&w,ch).z<-2)
}

@(test)
character_capacity_descriptions_and_stale_handles_are_checked :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w,1))
    defer world_destroy(&w)
    test_ground(&w)
    bad:=CHARACTER_DESC_DEFAULT
    bad.height=0.5
    testing.expect_value(t,character_create(&w,bad,{}),Character_Handle{})
    bad=CHARACTER_DESC_DEFAULT
    bad.max_slope=2
    testing.expect_value(t,character_create(&w,bad,{}),Character_Handle{})
    a:=test_character(&w,{0,0,0})
    testing.expect(t,a!={})
    testing.expect_value(t,test_character(&w,{2,0,0}),Character_Handle{})
    stats:=world_stats(&w)
    testing.expect(t,stats.character_capacity_exhausted==1 && stats.characters==1 && stats.bodies==2)
    body:=character_body(&w,a)
    character_destroy(&w,a)
    testing.expect(t,!character_valid(&w,a) && !body_valid(&w,body))
    testing.expect_value(t,character_position(&w,a),Vec3{})
    character_set_move(&w,a,{ground={velocity={1,0,0}}})
    character_launch(&w,a,{0,5,0})
    b:=test_character(&w,{0,0,0})
    testing.expect(t,b!={} && b!=a && character_valid(&w,b))
    testing.expect_value(t,character_move(&w,b).ground.velocity,Vec3{})
    character_set_position(&w,b,{3,0.2,-1})
    testing.expect_value(t,character_position(&w,b),Vec3{3,0.2,-1})
    test_steps(&w,10)
    testing.expect_value(t,world_stats(&w).characters,1)
}

// A scene with what characters interact with, and inputs that depend only on the tick.
@(private)
test_character_scene :: proc(w:^World) -> [3]Character_Handle {
    test_ground(w)
    test_static_box(w,{2,0.125,2},{4,0.125,0})
    test_static_box(w,{3,1,0.5},{0,1,-6})
    test_dynamic_box(w,{0.4,0.4,0.4},{0,0.4,-2},30)
    test_dynamic_box(w,{0.4,0.4,0.4},{-3,0.4,1},30)
    platform:=test_body(w,Box{{2,0.2,2}},{-6,0.6,0},.Kinematic)
    body_set_velocity(w,platform,{0,0,0.5},{0,0.4,0})
    return {test_character(w,{0,0,0}),test_character(w,{-5.5,0.8,0}),test_character(w,{3,0.5,2})}
}

@(private)
test_character_script :: proc(w:^World,chs:[3]Character_Handle,tick:int) {
    first:=character_move(w,chs[0])
    first.yaw=0.01*f32(tick)
    character_set_move(w,chs[0],first)
    character_set_move(w,chs[0],test_move(w,chs[0],{0,0,-1},tick%40==12))
    character_set_move(w,chs[1],test_move(w,chs[1],{f32(tick%50<25?1:-1),0,0.3}))
    character_set_move(w,chs[2],test_move(w,chs[2],{-1,0,-0.5},tick%64==30))
    if tick>=25 && tick<35 {character_set_move(w,chs[0],{air={{6,0,-6},80*12*240},yaw=first.yaw,flags={.Airborne,.Drive_Vertical,.No_Gravity}})}
    if tick==50 {character_launch(w,chs[2],{1,5,0})}
}

@(test)
restoring_in_the_middle_of_a_jump_repeats_the_trajectory_exactly :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    chs:=test_character_scene(&w)
    for tick in 0..<20 {
        test_character_script(&w,chs,tick)
        world_step(&w,1.0/60)
    }
    state:=character_state(&w,chs[0])
    testing.expect(t,.Standing not_in state.ground && character_position(&w,chs[0]).y>0.3)
    buffer:World
    defer world_destroy(&buffer)
    ok:=test_keep(&buffer,&w)
    testing.expect(t,ok)
    Sample :: struct {positions:[3]Vec3,hash:u64}
    first:[100]Sample
    for &sample,i in first {
        test_character_script(&w,chs,20+i)
        world_step(&w,1.0/60)
        for ch,j in chs {sample.positions[j]=character_position(&w,ch)}
        sample.hash=world_hash(&w)
    }
    testing.expect(t,test_restore(&w,&buffer))
    testing.expect_value(t,character_state(&w,chs[0]),state)
    for sample,i in first {
        test_character_script(&w,chs,20+i)
        world_step(&w,1.0/60)
        for ch,j in chs {
            if character_position(&w,ch)!=sample.positions[j] {
                testing.expectf(t,false,"character %v diverged %v ticks after the restore",j,i)
                return
            }
        }
        if world_hash(&w)!=sample.hash {
            testing.expectf(t,false,"the hash diverged %v ticks after the restore",i)
            return
        }
    }
}

@(test)
equal_character_moves_give_equal_hashes_with_and_without_threads :: proc(t:^testing.T) {
    pool:Test_Pool
    test_pool_init(&pool,4)
    defer test_pool_destroy(&pool)
    a,b:World
    testing.expect(t,test_character_world(&a,32))
    testing.expect(t,test_character_world(&b,32,&pool))
    defer world_destroy(&a)
    defer world_destroy(&b)
    chs:[2][3]Character_Handle
    crowd:[2][20]Character_Handle
    for w,i in ([2]^World{&a,&b}) {
        chs[i]=test_character_scene(w)
        for &ch,j in crowd[i] {ch=test_character(w,{f32(j%5)*1.5-3,0,6+f32(j/5)*1.5})}
    }
    testing.expect_value(t,chs[0],chs[1])
    moved:=false
    for tick in 0..<150 {
        for w,i in ([2]^World{&a,&b}) {
            test_character_script(w,chs[i],tick)
            for ch,j in crowd[i] {character_set_move(w,ch,test_move(w,ch,{f32(j%3)-1,0,f32((tick/30+j)%3)-1}))}
            world_step(w,1.0/60)
        }
        if world_hash(&a)!=world_hash(&b) {
            testing.expectf(t,false,"the worlds diverged at tick %v",tick)
            return
        }
        moved||=length(character_velocity(&a,crowd[0][7]))>3
    }
    testing.expect(t,moved)
    // The move is part of the state.
    character_set_move(&a,chs[0][0],{ground={velocity={1,0,0}}})
    testing.expect(t,world_hash(&a)!=world_hash(&b))
}

@(test)
the_ground_probe_follows_the_collision_filter_and_group_of_the_character :: proc(t:^testing.T) {
    platform :: proc(w:^World,filter:Filter) {
        desc:=BODY_DESC_DEFAULT
        desc.type=.Static
        desc.position={0,0.95,0}
        body:=body_create(w,desc)
        shape:=SHAPE_DESC_DEFAULT
        shape.geometry=Box{{3,0.05,3}}
        shape.filter=filter
        shape_create(w,body,shape)
    }
    // A platform of the same negative group is not there for the character: it falls to the ground.
    {
        w:World
        testing.expect(t,test_character_world(&w))
        defer world_destroy(&w)
        test_ground(&w)
        platform(&w,{layers=1,block=0xffffffff,group=3})
        d:=CHARACTER_DESC_DEFAULT
        d.filter.group=3
        ch:=test_character(&w,{0,1,0},d)
        test_steps(&w,90)
        testing.expectf(t,near(character_position(&w,ch).y,0,0.01),"feet at %v",character_position(&w,ch).y)
    }
    // A platform of a layer the character blocks holds it until a new filter of the character stops blocking it.
    {
        w:World
        testing.expect(t,test_character_world(&w))
        defer world_destroy(&w)
        test_ground(&w)
        platform(&w,{layers=4,block=0xffffffff})
        ch:=test_character(&w,{0,1,0})
        test_steps(&w,90)
        testing.expectf(t,near(character_position(&w,ch).y,1,0.01),"feet at %v",character_position(&w,ch).y)
        testing.expect(t,test_standing(&w,ch))
        character_set_filter(&w,ch,{layers=1,block=1})
        testing.expect_value(t,character_desc(&w,ch).filter,Filter{layers=1,block=1})
        test_steps(&w,90)
        testing.expectf(t,near(character_position(&w,ch).y,0,0.01),"feet at %v",character_position(&w,ch).y)
    }
}

@(test)
a_character_at_rest_lets_what_it_stands_on_and_touches_sleep :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    floor:=test_dynamic_box(&w,{2,0.25,2},{0,0.25,0},200)
    leaning:=test_dynamic_box(&w,{0.2,0.5,0.2},{0.55,1,0},20)
    ch:=test_character(&w,{0,0.5,0})
    test_steps(&w,120)
    testing.expect_value(t,character_state(&w,ch).ground_body,floor)
    testing.expect(t,!body_is_awake(&w,floor),"the box under a still character sleeps")
    testing.expect(t,!body_is_awake(&w,leaning),"a box leaning on a still character sleeps")
    testing.expect(t,test_standing(&w,ch) && near(character_position(&w,ch).y,0.5,0.01))
    // Walking wakes them: the floor slides back under the feet while the character speeds up.
    before:=body_position(&w,floor).x
    test_walk(&w,ch,{-1,0,0},20)
    testing.expect(t,body_is_awake(&w,floor) && body_is_awake(&w,leaning))
    testing.expectf(t,body_position(&w,floor).x-before>0.005,"the floor moved %v",body_position(&w,floor).x-before)
}

@(test)
a_crouched_character_passes_under_a_low_ceiling_and_stands_up_only_in_the_open :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    // A ceiling 1.3 m high over z in [-6,-2].
    test_static_box(&w,{3,0.2,2},{0,1.5,-4})
    ch:=test_character(&w,{0,0,0})
    test_steps(&w,30)
    // Standing, the capsule (1.8 m) hits the edge of the ceiling.
    test_walk(&w,ch,{0,0,-1},90)
    testing.expectf(t,character_position(&w,ch).z>-2,"walked under the ceiling standing: %v",character_position(&w,ch))
    testing.expect(t,character_set_height(&w,ch,1.1))
    testing.expect_value(t,character_desc(&w,ch).height,f32(1.1))
    test_walk(&w,ch,{0,0,-1},35)
    test_walk(&w,ch,{},20)
    under:=character_position(&w,ch)
    testing.expectf(t,under.z<-2.6 && under.z>-5.4 && near(under.y,0,0.01),"crouched at %v",under)
    testing.expect(t,!character_set_height(&w,ch,1.8),"the ceiling keeps it crouched")
    testing.expect_value(t,character_desc(&w,ch).height,f32(1.1))
    test_walk(&w,ch,{0,0,-1},60)
    testing.expect(t,character_position(&w,ch).z<-6.5)
    testing.expect(t,character_set_height(&w,ch,1.8))
    test_steps(&w,30)
    testing.expect(t,near(character_position(&w,ch).y,0,0.01) && test_standing(&w,ch))
    testing.expect(t,!character_set_height(&w,ch,0.5),"a capsule shorter than its diameter and step does not fit")
    // A wall it leans on crouched does not keep it crouched.
    test_static_box(&w,{3,2,0.2},{0,2,-16})
    testing.expect(t,character_set_height(&w,ch,1.1))
    test_walk(&w,ch,{0,0,-1},90)
    testing.expectf(t,character_position(&w,ch).z>-15.85,"leans on the wall at %v",character_position(&w,ch))
    testing.expect(t,character_set_height(&w,ch,1.8),"stands up against the wall")
}

// The up turns toward the opposite of the gravity at up_speed, by the shortest way and about the feet, and
// keeps still where the gravity does not change it.
@(test)
the_up_turns_toward_the_opposite_of_gravity_at_its_speed_about_the_feet :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    floating:=Character_Move{flags={.Airborne,.No_Gravity}}
    ch:=test_character(&w,{0,10,0})
    held:=CHARACTER_DESC_DEFAULT
    held.up_speed=0
    still:=test_character(&w,{10,10,0},held)
    character_set_move(&w,ch,floating)
    character_set_move(&w,still,floating)
    test_steps(&w,10)
    testing.expect_value(t,character_state(&w,ch).up_frame,QUAT_IDENTITY)
    // Sideways: the up turns a quarter, toward -X, about +Z.
    world_set_gravity(&w,{9.81,0,0})
    dt:f32=1.0/60
    up:=up_frame_up(character_state(&w,ch).up_frame)
    target:=Vec3{-1,0,0}
    for step in 0..<40 {
        test_steps(&w,1)
        frame:=character_state(&w,ch).up_frame
        next:=up_frame_up(frame)
        turned:=cmath.acos(clamp(dot(up,next),-1,1))
        testing.expectf(t,turned<=PI*dt+1e-4,"step %v turned %v",step,turned)
        testing.expectf(t,dot(next,target)>=dot(up,target)-1e-6,"step %v turned away",step)
        testing.expectf(t,length(q_rotate(frame,{0,0,1})-Vec3{0,0,1})<1e-4,"step %v twisted the frame",step)
        testing.expectf(t,length(q_rotate(body_rotation(&w,character_body(&w,ch)),UP)-next)<1e-5,"the body follows the up")
        up=next
    }
    testing.expectf(t,length(up-target)<1e-4,"up %v",up)
    feet:=character_position(&w,ch)
    testing.expectf(t,length(feet-Vec3{0,10,0})<1e-4,"the feet stay: %v",feet)
    center:=body_center(&w,character_body(&w,ch))
    testing.expectf(t,length(center-(feet+target*1.05))<1e-3,"the capsule turned about the feet: %v",center)
    testing.expect_value(t,character_state(&w,still).up_frame,QUAT_IDENTITY)
}
