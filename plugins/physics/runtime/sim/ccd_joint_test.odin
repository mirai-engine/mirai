package mirai_physics

import "core:testing"

@(test)
ccd_clips_joint_neighbours_at_the_same_time_without_clipping_contact_only_bodies :: proc(t:^testing.T) {
    w:World
    if !testing.expect(t,test_world(&w)) {return}
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    wall:=test_body(&w,Box{{.01,.205,.3}},{},.Static)
    links:[3]Body_Handle
    for &body,index in links {
        position:=Vec3{-1,f32(index)*.42,0}
        body=test_bullet(&w,position,{200,0,0},index==0,Box{{.2,.2,.2}})
        if index>0 {joint_create(&w,test_joint(&w,.Fixed,links[index-1],body,position-Vec3{0,.21,0}))}
    }
    outsider:=test_bullet(&w,{-1,1.24,0},{200,0,0},false,Box{{.2,.2,.2}})
    world_step(&w,1.0/60)
    impact:=body_position(&w,links[0])
    testing.expect(t,impact.x<-.19)
    for body,index in links {
        expect_near3(t,body_position(&w,body),impact+Vec3{0,f32(index)*.42,0},1e-4)
    }
    testing.expect(t,body_position(&w,outsider).x>2)
    wall_impacts:=0
    outsider_contacts:=0
    for contact in world_events(&w).contact_begin {
        if contact.body_a==wall || contact.body_b==wall {wall_impacts+=1;testing.expect(t,contact.impulse>0)}
        if contact.body_a==outsider || contact.body_b==outsider {outsider_contacts+=1}
    }
    testing.expect_value(t,wall_impacts,1)
    testing.expect_value(t,outsider_contacts,1)
}

@(test)
ccd_joint_components_replay_identically_with_one_and_four_workers :: proc(t:^testing.T) {
    pool:Test_Pool;test_pool_init(&pool,4);defer test_pool_destroy(&pool)
    a,b:World
    if !testing.expect(t,test_world_threaded(&a,nil,128,512,64)) {return}
    defer world_destroy(&a)
    if !testing.expect(t,test_world_threaded(&b,&pool,128,512,64)) {return}
    defer world_destroy(&b)
    links:[2][8][4]Body_Handle
    for w,side in ([2]^World{&a,&b}) {
        world_set_gravity(w,{})
        for &component,at in links[side] {
            z:=f32(at)*2
            velocity:=Vec3{200+f32(at)*5,0,0}
            test_body(w,Box{{.01,.205,.3}},{0,0,z},.Static)
            for &body,index in component {
                position:=Vec3{-1,f32(index)*.42,z}
                body=test_bullet(w,position,velocity,index==0,Box{{.2,.2,.2}})
                if index>0 {joint_create(w,test_joint(w,.Fixed,component[index-1],body,position-Vec3{0,.21,0}))}
            }
            test_bullet(w,{-1,1.66,z},velocity,false,Box{{.2,.2,.2}})
        }
    }
    testing.expect_value(t,world_hash(&a),world_hash(&b))
    before:World;defer world_destroy(&before)
    during:World;defer world_destroy(&during)
    ok:=test_keep(&before,&a)
    if !testing.expect(t,ok) {return}
    hashes:[60]u64
    middle:=0
    for tick in 0..<len(hashes) {
        world_step(&a,1.0/60);world_step(&b,1.0/60)
        hashes[tick]=world_hash(&a)
        if !testing.expect_value(t,hashes[tick],world_hash(&b)) {return}
        if tick==0 {
            for component in links[0] {
                impact:=body_position(&a,component[0])
                testing.expect(t,impact.x<-.19)
                for body,index in component {expect_near3(t,body_position(&a,body),impact+Vec3{0,f32(index)*.42,0},1e-4)}
            }
        }
        if tick==11 {ok=test_keep(&during,&a);if !testing.expect(t,ok) {return}}
    }
    if !testing.expect(t,test_restore(&a,&before)) {return}
    for tick in 0..<len(hashes) {
        world_step(&a,1.0/60)
        if !testing.expect_value(t,world_hash(&a),hashes[tick]) {return}
    }
    if !testing.expect(t,test_restore(&b,&during)) {return}
    for tick in 12..<len(hashes) {
        world_step(&b,1.0/60)
        if !testing.expect_value(t,world_hash(&b),hashes[tick]) {return}
    }
}
