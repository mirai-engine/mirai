package mirai_physics

import "core:testing"

@(private="file")
test_bouncing_bullet :: proc(w:^World,position,velocity:Vec3) -> Body_Handle {
    body:=test_bullet(w,position,velocity,true)
    body_set_bullet(w,body,true)
    return body
}

@(test)
a_fast_bullet_bounces_between_two_walls_for_the_whole_step :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    // Elastic and without friction: the inner faces are at x=±0.5, so the sphere of 5 cm turns at ±0.445,
    // 5 mm of clearance before touching.
    for x in ([2]f32{-0.51,0.51}) {test_body(&w,Box{{0.01,2,2}},{x,0,0},.Static,0,1)}
    bullet:=test_bouncing_bullet(&w,{},{120,0,0})
    world_step(&w,1.0/60)
    // 2 m in the step: 0.445 to the right wall, 0.89 back to the left one and the remaining 0.665 m.
    x,v:=body_position(&w,bullet).x,body_linear_velocity(&w,bullet).x
    testing.expectf(t,abs(x-0.22)<0.02 && abs(v-120)<0.5,"after one step at %v with %v m/s",x,v)
    testing.expect_value(t,len(world_events(&w).contact_begin),2)
    for _ in 0..<60 {
        world_step(&w,1.0/60)
        x=body_position(&w,bullet).x
        testing.expectf(t,abs(x)<=0.45+LINEAR_SLOP,"left the walls at %v",x)
    }
    testing.expectf(t,abs(abs(body_linear_velocity(&w,bullet).x)-120)<1,"speed %v",body_linear_velocity(&w,bullet))
}

@(test)
a_bullet_zigzags_down_a_narrow_corridor_without_losing_time :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    for z in ([2]f32{-0.16,0.16}) {test_body(&w,Box{{60,2,0.01}},{0,0,z},.Static,0,1)}
    // 1 m along the corridor and 0.4 m across it per step: two or three impacts on its walls.
    bullet:=test_bouncing_bullet(&w,{},{60,0,24})
    test_steps(&w,30)
    p,v:=body_position(&w,bullet),body_linear_velocity(&w,bullet)
    testing.expectf(t,abs(p.x-30)<0.1,"advanced %v along the corridor",p.x)
    testing.expectf(t,abs(p.z)<=0.1 && abs(p.y)<1e-3,"left the corridor at %v",p)
    testing.expectf(t,abs(v.x-60)<0.5 && abs(abs(v.z)-24)<0.5,"velocity %v",v)
}

@(test)
a_bullet_stops_after_a_few_impacts_in_a_step :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    // A gap of 0.1 m crossed at 360 m/s, 6 m in a step: far more impacts than a step takes.
    for x in ([2]f32{-0.11,0.11}) {test_body(&w,Box{{0.01,2,2}},{x,0,0},.Static,0,1)}
    bullet:=test_bouncing_bullet(&w,{},{360,0,0})
    for _ in 0..<10 {
        world_step(&w,1.0/60)
        x:=body_position(&w,bullet).x
        testing.expectf(t,abs(x)<0.06,"left the walls at %v",x)
    }
    testing.expectf(t,abs(abs(body_linear_velocity(&w,bullet).x)-360)<5,"speed %v",body_linear_velocity(&w,bullet))
}

@(test)
overlaps_a_bullet_crosses_beyond_its_capacity_are_counted :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    for i in 0..<6 {
        body:=body_create(&w,{type=.Static,position={0.5+0.5*f32(i),0,0}})
        shape:=SHAPE_DESC_DEFAULT
        shape.geometry=Box{{0.01,1,1}}
        shape.filter=Filter{layers=1,overlap=0xffffffff}
        shape_create(&w,body,shape)
    }
    test_bouncing_bullet(&w,{},{240,0,0})
    world_step(&w,1.0/60)
    events:=world_events(&w)
    testing.expect_value(t,len(events.overlap_begin),2*CCD_OVERLAP_CAPACITY)
    testing.expect_value(t,world_stats(&w).ccd_overlaps_dropped,6-CCD_OVERLAP_CAPACITY)
}

// Meshes are one-sided for bullets as for every body: what comes from behind a face goes through it.
@(test)
bullets_cross_a_one_sided_mesh_from_behind_and_stop_on_both_layers_of_a_closed_one :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    vertices:=[8]Vec3{{0,-2,-2},{0,-2,2},{0,2,-2},{0,2,2},{0.02,-2,-2},{0.02,-2,2},{0.02,2,-2},{0.02,2,2}}
    front:=[6]u32{0,1,2, 2,1,3}
    closed:=[12]u32{0,1,2, 2,1,3, 4,6,5, 6,7,5}
    single,ok:=mesh_create(&w,{vertices=vertices[:],indices=front[:]})
    testing.expect(t,ok)
    both,ok2:=mesh_create(&w,{vertices=vertices[:],indices=closed[:]})
    testing.expect(t,ok2)
    test_static_shape(&w,single)
    test_static_shape(&w,both,{0,0,10})
    facing:=test_bouncing_bullet(&w,{-1,0,0},{200,0,0})
    behind:=test_bouncing_bullet(&w,{1,0.5,0},{-200,0,0})
    closed_behind:=test_bouncing_bullet(&w,{1,0,10},{-200,0,0})
    world_step(&w,1.0/60)
    testing.expect(t,body_position(&w,facing).x<0)
    testing.expect(t,body_position(&w,behind).x< -1)
    testing.expect(t,body_position(&w,closed_behind).x>0.02)
}

// The speculative contact of the step already bounced it: the answer of its impact adds to that and does not
// take it back.
@(test)
a_bullet_that_ends_a_step_against_an_elastic_wall_bounces_off_it :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_body(&w,Box{{0.01,2,2}},{0.51,0,0},.Static,0,1)
    bullet:=test_bouncing_bullet(&w,{0.44,0,0},{120,0,0})
    world_step(&w,1.0/60)
    testing.expectf(t,abs(body_linear_velocity(&w,bullet).x+120)<0.5,"velocity %v",body_linear_velocity(&w,bullet))
    testing.expect(t,body_position(&w,bullet).x<0.44)
}

// A tilted bar hits the wall with one corner and pivots on it, which brings that corner back several times in
// the step. No impact may leave the bar touching the wall, or the next pass would not see it and the rest of
// the step would carry the bar through.
@(test)
a_bullet_that_pivots_on_a_corner_against_a_thin_wall_does_not_go_through :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_body(&w,Box{{0.05,20,20}},{5,0,0},.Static)
    bar:=test_bullet(&w,{},{300,0,0},true,Box{{0.2,0.3,0.2}})
    body_set_transform(&w,bar,{},q_axis_angle({0,0,1},0.3))
    for _ in 0..<4 {
        world_step(&w,1.0/60)
        testing.expectf(t,body_position(&w,bar).x<4.9,"the bar went through to %v",body_position(&w,bar))
    }
}

@(test)
every_contact_a_bouncing_bullet_begins_also_ends :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    walls:[2]Body_Handle
    for x,i in ([2]f32{-0.51,0.51}) {walls[i]=test_body(&w,Box{{0.01,2,2}},{x,0,0},.Static,0,1)}
    bullet:=test_bouncing_bullet(&w,{},{120,0,0})
    open:[2]int
    for step in 0..<60 {
        world_step(&w,1.0/60)
        events:=world_events(&w)
        for i in 0..<2 {
            for e in events.contact_end {
                if e.body_a==walls[i] || e.body_b==walls[i] {open[i]-=1}
            }
            for e in events.contact_begin {
                if e.body_a==walls[i] || e.body_b==walls[i] {open[i]+=1}
            }
            testing.expectf(t,open[i]==0 || open[i]==1,"step %d: wall %d has %d contacts open",step,i,open[i])
        }
    }
    _=bullet
}

@(test)
a_touching_contact_that_continuous_collision_finds_apart_ends :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    w.desc.gravity={}
    floor:=test_body(&w,Box{{2,0.1,2}},{0,0,0},.Static)
    ball:=test_body(&w,Sphere{0.1},{0,0.2,0})
    world_step(&w,1.0/60)
    testing.expect_value(t,len(world_events(&w).contact_begin),1)
    // Continuous collision answers the pair again where the ball no longer touches the floor.
    b,_:=body_get(&w,ball)
    b.position.y,b.center.y=1,1
    f,_:=body_get(&w,floor)
    // As the narrow phase of the next step leaves it: touching since before, not just begun.
    w.contacts[contact_find(&w,f.shape_list,b.shape_list)].flags-={.Started}
    w.events.counts={}
    continuous_contact(&w,f.shape_list,b.shape_list)
    testing.expect_value(t,len(world_events(&w).contact_end),1)
}
