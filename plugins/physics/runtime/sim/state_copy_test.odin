package mirai_physics

import "core:testing"

// What a snapshot is: a world kept with the state w has now, which test_restore puts back.
@(private)
test_keep :: proc(kept,w:^World) -> bool {
    if kept.allocator.procedure==nil || !world_state_fits(kept,w) {
        world_destroy(kept)
        if !world_kept_init(kept,w,context.allocator) {return false}
    }
    _,ok:=world_state_copy(kept,w)
    return ok
}

@(private)
test_restore :: proc(w,kept:^World) -> bool {
    _,ok:=world_state_copy(w,kept)
    return ok
}

@(test)
a_state_copied_into_another_world_steps_as_one_put_back_from_a_kept_world :: proc(t:^testing.T) {
    a,b,c,kept:World
    testing.expect(t,test_world(&a) && test_world(&b) && test_world(&c))
    defer world_destroy(&a)
    defer world_destroy(&b)
    defer world_destroy(&c)
    defer world_destroy(&kept)
    test_scene(&a)
    for step in 0..<50 {
        test_scene_edit(&a,step)
        world_step(&a,1.0/60)
    }
    // b had more of everything than a has now: the slots a never used go back to never used.
    test_scene(&b)
    for step in 0..<70 {
        test_scene_edit(&b,step)
        world_step(&b,1.0/60)
    }
    testing.expect(t,test_keep(&kept,&a) && test_restore(&c,&kept))
    _,copied:=world_state_copy(&b,&a)
    testing.expect(t,copied)
    testing.expect_value(t,world_hash(&b),world_hash(&a))
    testing.expect_value(t,world_hash(&c),world_hash(&a))
    for step in 0..<90 {
        test_scene_edit(&b,50+step)
        test_scene_edit(&c,50+step)
        world_step(&b,1.0/60)
        world_step(&c,1.0/60)
        if world_hash(&b)!=world_hash(&c) {
            testing.expectf(t,false,"the copy diverged from the one put back %v steps after",step)
            return
        }
    }
}

@(test)
a_state_copy_into_a_world_of_other_capacities_or_without_its_geometry_changes_nothing :: proc(t:^testing.T) {
    w,small,bare,unmade:World
    testing.expect(t,test_world(&w) && test_world(&small,bodies=8) && test_world(&bare))
    defer world_destroy(&w)
    defer world_destroy(&small)
    defer world_destroy(&bare)
    test_scene(&w)
    vertices:=[4]Vec3{{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
    counts:=[4]u8{3,3,3,3};faces:=[12]u8{0,2,1,0,1,3,0,3,2,1,2,3}
    hull,made:=hull_create(&w,{vertices[:],counts[:],faces[:]})
    testing.expect(t,made)
    test_body(&w,hull,{0,4,0})
    test_steps(&w,10)
    before,empty,now:=world_hash(&small),world_hash(&bare),world_hash(&w)
    cases:=[?]struct{dst,src:^World,hash:u64}{{&small,&w,before},{&bare,&w,empty},{&unmade,&w,world_hash(&unmade)},{&w,&unmade,now}}
    for c,i in cases {
        written,ok:=world_state_copy(c.dst,c.src)
        testing.expectf(t,!ok && written==0,"case %v was copied",i)
        testing.expectf(t,world_hash(c.dst)==c.hash,"case %v changed the world",i)
    }
}

// 1000 bodies asleep on the ground and 10 that fall, then an idle character: a copy kept for the world
// takes what each tick changed, and nothing once all of it rests.
@(test)
a_kept_copy_takes_what_a_tick_changed_and_nothing_when_all_rests :: proc(t:^testing.T) {
    w,kept:World
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=1100,1100,4096,0
    testing.expect(t,world_init(&w,desc))
    defer world_destroy(&w)
    defer world_destroy(&kept)
    whole,moving,still:=test_sleepers(&w,&kept)
    testing.expectf(t,whole>1000*(size_of(Body)+size_of(Shape)),"a whole copy wrote %v bytes",whole)
    testing.expectf(t,moving>0 && 10*moving<whole,"a tick of 10 falling bodies wrote %v bytes of %v",moving,whole)
    testing.expectf(t,still==0,"a tick where nothing moved wrote %v bytes",still)
}

// The bytes a whole copy into kept writes, those a tick with 10 bodies falling writes, and those a tick
// writes once they and an idle character rest.
@(private)
test_sleepers :: proc(w,kept:^World) -> (whole,moving,still:int) {
    test_ground(w)
    rest:=BODY_DESC_DEFAULT
    rest.asleep=true
    box:=SHAPE_DESC_DEFAULT
    box.geometry=Box{{0.25,0.25,0.25}}
    for i in 0..<1000 {
        rest.position={f32(i%40)-20,0.25,f32(i/40)-12.5}
        shape_create(w,body_create(w,rest),box)
    }
    for i in 0..<10 {test_body(w,Sphere{0.2},{f32(i)*2-10,6,20})}
    ch:=character_create(w,CHARACTER_DESC_DEFAULT,{0,0,30})
    test_steps(w,3)
    if !world_kept_init(kept,w,context.allocator) {return}
    whole,_=world_state_copy(kept,w)
    world_step(w,1.0/60)
    moving,_=world_state_copy(kept,w)
    for _ in 0..<240 {
        world_step(w,1.0/60)
        character_set_move(w,ch,{})
        world_state_copy(kept,w)
    }
    world_step(w,1.0/60)
    still,_=world_state_copy(kept,w)
    return
}

// What core does to put back a world from its history: the kept state goes into a staged world, which
// trades places with the running one. The copies kept for it go on taking only what changed.
@(test)
a_world_put_back_through_a_staged_copy_goes_on_with_the_copies_kept_for_it :: proc(t:^testing.T) {
    live,stage,kept:World
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=1100,1100,4096,0
    testing.expect(t,world_init(&live,desc) && world_init(&stage,desc))
    defer world_destroy(&live)
    defer world_destroy(&stage)
    defer world_destroy(&kept)
    whole,_,_:=test_sleepers(&live,&kept)
    test_body(&live,Sphere{0.2},{0,8,20})
    world_step(&live,1.0/60)
    testing.expect(t,test_keep(&kept,&live))
    saved:=world_hash(&live)
    test_steps(&live,5)
    _,staged:=world_state_copy(&stage,&kept)
    testing.expect(t,staged)
    live,stage=stage,live
    world_succeed(&live,&stage)
    testing.expect_value(t,world_hash(&live),saved)
    world_step(&live,1.0/60)
    written,ok:=world_state_copy(&kept,&live)
    testing.expectf(t,ok && written>0 && 10*written<whole,"the copy after the put back wrote %v bytes of %v",written,whole)
    testing.expect_value(t,world_hash(&kept),world_hash(&live))
}
