package mirai_physics

import "core:testing"
import cmath "core:math"

// More new pairs than the pair buffer holds: which ones become contacts must not depend on the workers.
@(test)
overflowing_pairs_do_not_depend_on_the_workers :: proc(t:^testing.T) {
    pool:Test_Pool
    test_pool_init(&pool,4)
    defer test_pool_destroy(&pool)
    a,b:World
    testing.expect(t,test_world_threaded(&a,nil,256,2048,8))
    testing.expect(t,test_world_threaded(&b,&pool,256,2048,8))
    defer world_destroy(&a)
    defer world_destroy(&b)
    for w in ([2]^World{&a,&b}) {
        test_ground(w)
        // A clump of 50 spheres that all overlap, in the first shapes, then loose ones far apart.
        for i in 0..<50 {test_body(w,Sphere{0.5},{f32(i%4)*0.3,0.5+f32(i/16)*0.3,f32(i/4%4)*0.3})}
        for i in 0..<150 {test_body(w,Sphere{0.2},{f32(i%15)*2-14,0.5,f32(i/15)*2+4})}
    }
    for step in 0..<20 {
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        if step==0 {testing.expectf(t,world_stats(&a).contacts>1000,"the clump made %v contacts",world_stats(&a).contacts)}
        if world_hash(&a)!=world_hash(&b) {
            testing.expectf(t,false,"the pairs found by four workers differ at step %v",step)
            return
        }
    }
}

// A steel ball bearing of 1 mm: its inertia is about 1.3e-11 kg m2, and the determinant of the tensor 2e-33.
@(test)
a_tiny_ball_turns_under_torques_and_offset_impulses :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    ball:=body_create(&w,{type=.Dynamic,position={0,5,0},rotation=QUAT_IDENTITY,gravity_scale=1,sleep_threshold=0.05})
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Sphere{0.001}
    shape.density=7850
    shape_create(&w,ball,shape)
    mass,_,inertia:=body_mass_properties(&w,ball)
    expect_near(t,inertia[0,0],0.4*mass*1e-6,1e-15)
    body_apply_angular_impulse(&w,ball,{1e-11,0,0})
    expect_near(t,body_angular_velocity(&w,ball).x,1e-11/inertia[0,0],1e-3)
    body_apply_impulse_at(&w,ball,{1e-8,0,0},body_center(&w,ball)+{0,0.001,0})
    expect_near(t,body_angular_velocity(&w,ball).z,-1e-11/inertia[0,0],1e-3)
    body_set_velocity(&w,ball,{},{})
    body_apply_torque(&w,ball,{0,1e-10,0})
    world_step(&w,1.0/60)
    expect_near(t,body_angular_velocity(&w,ball).y,1e-10/inertia[1,1]/60,1e-3)
}

// A steel block of 200 m hangs from a joint at one end: its inverse inertia is about 2e-12 and the determinant
// of the angular mass of the joint about 1e-33.
@(test)
a_fixed_joint_holds_a_huge_block :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    wall:=test_anchor(&w,{0,100,0})
    block:=body_create(&w,{type=.Dynamic,position={100,100,0},rotation=QUAT_IDENTITY,gravity_scale=1})
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{{100,5,5}}
    shape.density=8000
    shape_create(&w,block,shape)
    joint_create(&w,test_joint(&w,.Fixed,wall,block,{0,100,0}))
    body_set_sleep_disabled(&w,block,true)
    test_steps(&w,120)
    testing.expectf(t,abs(body_rotation(&w,block).w)>0.9999,"the block turned to %v",body_rotation(&w,block))
}

// The ball joins the island of the stack while it touches it; once it rolls away the island splits and the
// stack falls asleep alone.
@(test)
a_ball_that_rolls_away_lets_the_stack_it_touched_fall_asleep :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    boxes:[3]Body_Handle
    for &box,i in boxes {box=test_body(&w,Box{{0.5,0.5,0.5}},{0,0.5+f32(i),0})}
    ball:=test_body(&w,Sphere{0.5},{1.0,0.5,0})
    body_set_sleep_disabled(&w,ball,true)
    test_steps(&w,30)
    testing.expect_value(t,world_stats(&w).islands,1)
    body_set_velocity(&w,ball,{4,0,0},{0,0,-8})
    test_steps(&w,90)
    testing.expect(t,body_is_awake(&w,ball))
    for box in boxes {testing.expect(t,!body_is_awake(&w,box))}
    // Touching the stack again wakes it and joins the islands.
    body_set_transform(&w,ball,{1.0,0.5,0},QUAT_IDENTITY)
    body_set_velocity(&w,ball,{-1,0,0},{})
    test_steps(&w,2)
    for box in boxes {testing.expect(t,body_is_awake(&w,box))}
    testing.expect_value(t,world_stats(&w).islands,1)
}

// Two boxes that touched share an island; after one is moved away, putting the other to sleep leaves it awake.
@(test)
putting_a_body_to_sleep_takes_only_what_still_touches_it :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    a:=test_body(&w,Box{{0.5,0.5,0.5}},{0,0.5,0})
    b:=test_body(&w,Box{{0.5,0.5,0.5}},{0,1.5,0})
    c:=test_body(&w,Box{{0.5,0.5,0.5}},{0,2.5,0})
    test_steps(&w,10)
    testing.expect_value(t,world_stats(&w).islands,1)
    body_set_transform(&w,c,{5,0.5,0},QUAT_IDENTITY)
    test_steps(&w,2)
    body_set_awake(&w,a,false)
    testing.expect(t,!body_is_awake(&w,a) && !body_is_awake(&w,b))
    testing.expect(t,body_is_awake(&w,c))
    // A push wakes the island of the body and nothing else.
    body_apply_impulse(&w,b,{0,1,0})
    testing.expect(t,body_is_awake(&w,a) && body_is_awake(&w,b))
    test_steps(&w,1)
    testing.expect_value(t,world_stats(&w).islands,2)
}

// A body asleep on another and under a third changes type: it leaves its island with its contacts, and wakes
// as what it becomes with what rested on it.
@(test)
a_body_asleep_between_others_changes_type :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    a:=test_body(&w,Box{{0.5,0.5,0.5}},{0,0.5,0})
    b:=test_body(&w,Box{{0.5,0.5,0.5}},{0,1.5,0})
    for type in ([3]Body_Type{.Kinematic,.Dynamic,.Static}) {
        test_steps(&w,10)
        body_set_awake(&w,a,false)
        testing.expect(t,!body_is_awake(&w,a))
        body_set_type(&w,a,type)
        testing.expect_value(t,body_type(&w,a),type)
        testing.expect(t,body_is_awake(&w,a)==(type!=.Static) && body_is_awake(&w,b))
    }
}

// Sixty boxes on a plank: the plank cannot take a color for each of its manifolds, and the rest run in order
// on single lanes. They hold the boxes as firmly, and the same with any number of workers.
@(test)
manifolds_without_color_hold_a_load_the_same_with_any_workers :: proc(t:^testing.T) {
    pool:Test_Pool
    test_pool_init(&pool,4)
    defer test_pool_destroy(&pool)
    a,b:World
    testing.expect(t,test_world_threaded(&a,nil,256,2048,8))
    testing.expect(t,test_world_threaded(&b,&pool,256,2048,8))
    defer world_destroy(&a)
    defer world_destroy(&b)
    for w in ([2]^World{&a,&b}) {
        w.desc.sleep_disabled=true
        test_ground(w)
        test_body(w,Box{{4,0.1,1}},{0,0.1,0})
        for i in 0..<60 {test_body(w,Box{{0.15,0.15,0.15}},{(f32(i%20)-9.5)*0.38,0.36,(f32(i/20)-1)*0.6})}
    }
    for step in 0..<120 {
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        if world_hash(&a)!=world_hash(&b) {
            testing.expectf(t,false,"four workers changed the result at step %v",step)
            return
        }
    }
    testing.expectf(t,world_stats(&a).overflow_constraints>=40,"%v manifolds without color",world_stats(&a).overflow_constraints)
    for i in 0..<60 {
        box:=body_handle(&a,i32(2+i))
        expect_near3(t,body_position(&a,box),{(f32(i%20)-9.5)*0.38,0.35,(f32(i/20)-1)*0.6},0.01)
    }
}

// A hub hangs 30 balls on distance joints and chains of every joint type that lanes solve: the hub cannot
// take a color for each of its joints, and the rest run in order on single lanes. The same with any workers.
@(test)
joints_without_color_hold_the_same_with_any_workers :: proc(t:^testing.T) {
    pool:Test_Pool
    test_pool_init(&pool,4)
    defer test_pool_destroy(&pool)
    a,b:World
    testing.expect(t,test_world_threaded(&a,nil,256,2048,64))
    testing.expect(t,test_world_threaded(&b,&pool,256,2048,64))
    defer world_destroy(&a)
    defer world_destroy(&b)
    for w in ([2]^World{&a,&b}) {
        w.desc.sleep_disabled=true
        anchor:=test_anchor(w,{0,10,0})
        hub:=test_body(w,Box{{0.5,0.5,0.5}},{0,8,0})
        joint_create(w,test_joint(w,.Fixed,anchor,hub,{0,9,0}))
        for i in 0..<30 {
            angle:=f32(i)*2*PI/30
            ball:=test_body(w,Sphere{0.1},{2*cmath.cos(angle),8,2*cmath.sin(angle)})
            desc:=test_joint(w,.Distance,hub,ball,{0,8,0})
            desc.frame_b.p={}
            joint_create(w,desc)
        }
        types:=[4]Joint_Type{.Spherical,.Revolute,.Prismatic,.Fixed}
        for type,k in types {
            previous:=anchor
            for link in 0..<5 {
                position:=Vec3{f32(k)*2-3,6-f32(link)*0.6,4}
                body:=test_body(w,Box{{0.1,0.2,0.1}},position)
                desc:=test_joint(w,type,previous,body,position+{0,0.3,0},{0,0,1})
                if type==.Prismatic {desc.enable_limit,desc.lower,desc.upper=true,-0.05,0.05}
                joint_create(w,desc)
                previous=body
            }
        }
    }
    for step in 0..<120 {
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        if world_hash(&a)!=world_hash(&b) {
            testing.expectf(t,false,"four workers changed the result at step %v",step)
            return
        }
    }
    testing.expectf(t,a.step.joint_single_count>=10,"%v joints without color",a.step.joint_single_count)
    hub:=body_handle(&a,1)
    expect_near3(t,body_position(&a,hub),{0,8,0},0.02)
    for i in 0..<30 {
        ball:=body_handle(&a,i32(2+i))
        expect_near(t,length(body_position(&a,ball)-body_center(&a,hub)),2,0.02)
    }
}

// Far more new pairs than contacts fit: the pair buffer fills, and only real pairs of the clump become contacts.
@(test)
a_full_pair_buffer_makes_contacts_only_of_real_pairs :: proc(t:^testing.T) {
    pool:Test_Pool
    test_pool_init(&pool,4)
    defer test_pool_destroy(&pool)
    a,b:World
    testing.expect(t,test_world_threaded(&a,nil,256,100,8))
    testing.expect(t,test_world_threaded(&b,&pool,256,100,8))
    defer world_destroy(&a)
    defer world_destroy(&b)
    for w in ([2]^World{&a,&b}) {
        test_ground(w)
        for i in 0..<70 {test_body(w,Sphere{0.5},{f32(i%4)*0.3,0.5+f32(i/16)*0.3,f32(i/4%4)*0.3})}
        for i in 0..<70 {test_body(w,Sphere{0.2},{f32(i%10)*2-9,0.5,f32(i/10)*2+4})}
    }
    for step in 0..<10 {
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        for &contact in a.contacts[:a.contact_high] {
            if contact.shape_b<0 {continue}
            testing.expect(t,contact.shape_a!=contact.shape_b && contact.body_a!=contact.body_b)
        }
        if world_hash(&a)!=world_hash(&b) {
            testing.expectf(t,false,"four workers changed the result at step %v",step)
            return
        }
    }
    testing.expect(t,world_stats(&a).contact_capacity_exhausted>0)
}

// The step walks the lists of the awake bodies and of the moved shapes instead of every slot: with thousands
// asleep it integrates only the awake ones, and the lists hold exactly the bodies that are awake and the
// shapes that need pairs through sleep, waking, a change of type, a removal and a restore.
@(test)
the_step_visits_only_the_awake_bodies :: proc(t:^testing.T) {
    lists_hold :: proc(t:^testing.T,w:^World) {
        listed,previous:=0,i32(-1)
        for i:=w.awake_head;i>=0;i=w.bodies[i].awake_next {
            testing.expect(t,w.bodies[i].generation&1!=0 && .Awake in w.bodies[i].flags && w.bodies[i].awake_prev==previous)
            listed,previous=listed+1,i
        }
        moved,previous_shape:=0,i32(-1)
        for i:=w.moved_head;i>=0;i=w.shapes[i].moved_next {
            testing.expect(t,w.shapes[i].generation&1!=0 && .Moved in w.shapes[i].flags && w.shapes[i].moved_prev==previous_shape)
            moved,previous_shape=moved+1,i
        }
        awake,flagged:=0,0
        for &body in w.bodies[:w.body_high] {if body.generation&1!=0 && .Awake in body.flags {awake+=1}}
        for &shape in w.shapes[:w.shape_high] {if shape.generation&1!=0 && .Moved in shape.flags {flagged+=1}}
        testing.expect_value(t,listed,awake)
        testing.expect_value(t,moved,flagged)
    }
    w:=new(World)
    defer free(w)
    testing.expect(t,test_world_threaded(w,nil,4096,16384,8))
    defer world_destroy(w)
    test_ground(w,{60,1,60})
    for i in 0..<3000 {
        desc:=BODY_DESC_DEFAULT
        desc.position,desc.asleep={(f32(i%55)-27)*1.1,0.25,(f32(i/55)-27)*1.1},true
        shape:=SHAPE_DESC_DEFAULT
        shape.geometry=Box{{0.25,0.25,0.25}}
        shape_create(w,body_create(w,desc),shape)
    }
    falling:=[3]Body_Handle{test_body(w,Sphere{0.2},{0,3,80}),test_body(w,Sphere{0.2},{3,3,80}),test_body(w,Sphere{0.2},{6,3,80})}
    lists_hold(t,w)
    for _ in 0..<5 {world_step(w,1.0/60)}
    integrated,_:=world_stepped(w)
    testing.expect_value(t,len(integrated),3)
    testing.expect_value(t,w.moved_head,i32(-1))
    lists_hold(t,w)
    asleep:=Body_Handle(body_handle(w,500))
    body_set_awake(w,asleep,true)
    body_set_type(w,falling[0],.Static)
    body_destroy(w,falling[1])
    lists_hold(t,w)
    buffer:=make([]byte,world_snapshot_capacity(w))
    defer delete(buffer)
    size,ok:=world_snapshot(w,buffer)
    testing.expect(t,ok)
    world_step(w,1.0/60)
    integrated,_=world_stepped(w)
    testing.expect_value(t,len(integrated),2)
    body_set_type(w,falling[0],.Dynamic)
    lists_hold(t,w)
    testing.expect(t,world_restore(w,buffer[:size]))
    lists_hold(t,w)
    for _ in 0..<60 {world_step(w,1.0/60)}
    lists_hold(t,w)
    testing.expect(t,world_stats(w).awake_bodies<=2)
}
