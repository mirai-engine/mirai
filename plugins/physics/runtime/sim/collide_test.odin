package mirai_physics

import "core:testing"
import cmath "core:math"
import "core:math/rand"

@(private)
expect_near :: proc(t:^testing.T,value,expected:f32,tolerance:f32=1e-4,loc:=#caller_location) {
    testing.expectf(t,abs(value-expected)<=tolerance,"got %v, expected %v",value,expected,loc=loc)
}
@(private)
expect_near3 :: proc(t:^testing.T,value,expected:Vec3,tolerance:f32=1e-4,loc:=#caller_location) {
    testing.expectf(t,length(value-expected)<=tolerance,"got %v, expected %v",value,expected,loc=loc)
}

@(test)
spheres_touch_within_the_speculative_distance :: proc(t:^testing.T) {
    m:Local_Manifold
    collide_spheres(&m,{0,0,0},1,{0,2.5,0},1,0.02)
    testing.expect_value(t,m.count,0)
    collide_spheres(&m,{0,0,0},1,{0,2.01,0},1,0.02)
    testing.expect_value(t,m.count,1)
    expect_near(t,m.points[0].separation,0.01)
    collide_spheres(&m,{0,0,0},1,{1.5,0,0},1,0.02)
    expect_near3(t,m.normal,{1,0,0})
    expect_near(t,m.points[0].separation,-0.5)
    expect_near3(t,m.points[0].point,{0.75,0,0})
}

@(test)
parallel_capsules_rest_on_two_points :: proc(t:^testing.T) {
    m:Local_Manifold
    collide_capsules(&m,{-1,0,0},{1,0,0},0.5,{-0.5,0.9,0},{2,0.9,0},0.5,0.02)
    testing.expect_value(t,m.count,2)
    expect_near3(t,m.normal,{0,1,0})
    expect_near(t,m.points[0].separation,-0.1)
    expect_near(t,m.points[1].separation,-0.1)
    expect_near(t,abs(m.points[0].point.x-m.points[1].point.x),1.5)
    collide_capsules(&m,{-1,0,0},{1,0,0},0.5,{0,0.9,-1},{0,0.9,1},0.5,0.02)
    testing.expect_value(t,m.count,1)
    expect_near3(t,m.points[0].point,{0,0.45,0})
}

@(test)
stacked_boxes_touch_on_four_corners :: proc(t:^testing.T) {
    storage_a,storage_b:Box_Hull
    a:=box_hull(&storage_a,{0.5,0.5,0.5})
    b:=box_hull(&storage_b,{0.5,0.5,0.5})
    m:Local_Manifold
    collide_hulls(&m,&a,&b,{{0,0.99,0},QUAT_IDENTITY},0.02)
    testing.expect_value(t,m.count,4)
    expect_near3(t,m.normal,{0,1,0})
    ids:[4]u32
    for point,i in m.points[:m.count] {
        expect_near(t,point.separation,-0.01)
        expect_near(t,abs(point.point.x),0.5)
        expect_near(t,abs(point.point.z),0.5)
        expect_near(t,point.point.y,0.495)
        ids[i]=point.id
        for j in 0..<i {testing.expect(t,ids[j]!=ids[i])}
    }
    collide_hulls(&m,&a,&b,{{0,1.03,0},QUAT_IDENTITY},0.02)
    testing.expect_value(t,m.count,0)
    collide_hulls(&m,&a,&b,{{0,1.01,0},QUAT_IDENTITY},0.02)
    testing.expect_value(t,m.count,4)
    expect_near(t,m.points[0].separation,0.01)
}

@(test)
rotated_box_on_a_box_reduces_to_four_points :: proc(t:^testing.T) {
    storage_a,storage_b:Box_Hull
    a:=box_hull(&storage_a,{1,0.5,1})
    b:=box_hull(&storage_b,{1,0.5,1})
    m:Local_Manifold
    collide_hulls(&m,&a,&b,{{0,0.98,0},q_axis_angle({0,1,0},cmath.PI/4)},0.02)
    testing.expect_value(t,m.count,4)
    expect_near3(t,m.normal,{0,1,0})
    for point in m.points[:m.count] {expect_near(t,point.separation,-0.02)}
}

@(test)
crossed_box_edges_give_one_edge_point :: proc(t:^testing.T) {
    storage_a,storage_b:Box_Hull
    a:=box_hull(&storage_a,{0.5,0.5,0.5})
    b:=box_hull(&storage_b,{0.5,0.5,0.5})
    // A is rotated 45 degrees about z so an edge points up; B is rotated 45 degrees about x so an edge points down.
    qa:=q_axis_angle({0,0,1},cmath.PI/4)
    qb:=q_axis_angle({1,0,0},cmath.PI/4)
    xf:=xf_inv_mul({{0,0,0},qa},{{0,2*0.70710678-0.01,0},qb})
    m:Local_Manifold
    collide_hulls(&m,&a,&b,xf,0.02)
    testing.expect_value(t,m.count,1)
    expect_near3(t,q_rotate(qa,m.normal),{0,1,0})
    expect_near(t,m.points[0].separation,-0.01,1e-3)
    testing.expect(t,m.points[0].id&ID_EDGE_PAIR!=0)
}

@(test)
reference_face_swap_keeps_the_contact_geometry :: proc(t:^testing.T) {
    storage_a,storage_b:Box_Hull
    a:=box_hull(&storage_a,{2,0.5,2})
    b:=box_hull(&storage_b,{0.5,0.5,0.5})
    xf:=Transform{{0.3,0.99,-0.2},q_axis_angle({0,1,0},0.3)}
    m,n:Local_Manifold
    collide_hulls(&m,&a,&b,xf,0.02)
    collide_hulls(&n,&b,&a,xf_inv(xf),0.02)
    testing.expect_value(t,m.count,4)
    testing.expect_value(t,n.count,4)
    expect_near3(t,m.normal,-q_rotate(xf.q,n.normal))
    for point in m.points[:m.count] {
        found:=false
        for other in n.points[:n.count] {
            if length(point.point-xf_point(xf,other.point))<1e-4 {found=true}
        }
        testing.expect(t,found)
    }
}

@(test)
the_box_path_agrees_with_the_hull_path :: proc(t:^testing.T) {
    state:=rand.create(11)
    context.random_generator=rand.default_random_generator(&state)
    touching,edges:=0,0
    for round in 0..<4000 {
        half_a:=Vec3{rand.float32_range(0.2,1.5),rand.float32_range(0.2,1.5),rand.float32_range(0.2,1.5)}
        half_b:=Vec3{rand.float32_range(0.2,1.5),rand.float32_range(0.2,1.5),rand.float32_range(0.2,1.5)}
        axis:=normalize(Vec3{rand.float32_range(-1,1),rand.float32_range(-1,1),rand.float32_range(-1,1)+0.01})
        direction:=normalize(Vec3{rand.float32_range(-1,1),rand.float32_range(-1,1),rand.float32_range(-1,1)+0.01})
        // Some pairs rest face to face, where the choice of feature is most delicate.
        angle:=round%3==0?f32(0):rand.float32_range(0,6.28)
        if round%3==0 {direction=Vec3{0,1,0}}
        reach:=abs(direction.x)*(half_a.x+half_b.x)+abs(direction.y)*(half_a.y+half_b.y)+abs(direction.z)*(half_a.z+half_b.z)
        xf:=Transform{direction*reach*rand.float32_range(0.5,1.05),q_axis_angle(axis,angle)}
        storage_a,storage_b:Box_Hull
        a:=box_hull(&storage_a,half_a)
        b:=box_hull(&storage_b,half_b)
        fast,slow:Local_Manifold
        collide_boxes(&fast,half_a,half_b,xf,0.02)
        collide_hulls(&slow,&a,&b,xf,0.02)
        if fast.count!=slow.count {
            testing.expectf(t,false,"round %v: %v points against %v",round,fast.count,slow.count)
            continue
        }
        if fast.count==0 {continue}
        touching+=1
        if fast.points[0].id&ID_EDGE_PAIR!=0 {edges+=1}
        testing.expectf(t,length(fast.normal-slow.normal)<1e-3,"round %v: normal %v against %v",round,fast.normal,slow.normal)
        for i in 0..<int(fast.count) {
            testing.expect_value(t,fast.points[i].id,slow.points[i].id)
            testing.expectf(t,length(fast.points[i].point-slow.points[i].point)<1e-3,"round %v: point %v against %v",round,fast.points[i].point,slow.points[i].point)
            expect_near(t,fast.points[i].separation,slow.points[i].separation,1e-3)
        }
    }
    testing.expect(t,touching>1000)
    testing.expect(t,edges>50)
}

@(test)
the_cached_axis_gives_what_the_full_search_gives_while_it_holds :: proc(t:^testing.T) {
    storage_a,storage_b:Box_Hull
    a:=box_hull(&storage_a,{0.5,0.5,0.5})
    b:=box_hull(&storage_b,{0.4,0.3,0.6})
    cache:Sat_Cache
    hits:=0
    for step in 0..<400 {
        // Rests, slides and turns on the top face, tips over an edge of it and leaves.
        s:=f32(step)
        tilt:=0.02*cmath.sin(s*0.07) if step<250 else f32(step-250)*0.006
        lift:=0.79+0.004*cmath.sin(s*0.13) if step<330 else 0.79+f32(step-330)*0.01
        xf:=Transform{{0.2*cmath.sin(s*0.02),lift,0.1*cmath.cos(s*0.03)},q_normalize(q_axis_angle({1,0,0},tilt)*q_axis_angle({0,1,0},s*0.01))}
        before:=cache
        cached,full:Local_Manifold
        collide_hulls(&cached,&a,&b,xf,0.02,&cache)
        collide_hulls(&full,&a,&b,xf,0.02)
        if before.kind!=.None && before==cache {hits+=1}
        testing.expectf(t,(cached.count>0)==(full.count>0),"step %d: %d points with the cache, %d without",step,cached.count,full.count)
        if cached.count>0 && full.count>0 {
            deepest_cached,deepest_full:=max(f32),max(f32)
            for p in cached.points[:cached.count] {deepest_cached=min(deepest_cached,p.separation)}
            for p in full.points[:full.count] {deepest_full=min(deepest_full,p.separation)}
            testing.expectf(t,abs(deepest_cached-deepest_full)<2*LINEAR_SLOP,"step %d: deepest %v with the cache, %v without",step,deepest_cached,deepest_full)
        }
    }
    testing.expectf(t,hits>250,"the cache decided %d of 400 steps",hits)
    // Apart along the cached axis: no contact and no search.
    cache={}
    m:Local_Manifold
    collide_hulls(&m,&a,&b,{{0,3,0},QUAT_IDENTITY},0.02,&cache)
    testing.expect(t,m.count==0 && cache.kind!=.None && abs(cache.separation-2.2)<1e-4)
    kept:=cache
    collide_hulls(&m,&a,&b,{{0,2.5,0},QUAT_IDENTITY},0.02,&cache)
    testing.expect(t,m.count==0 && cache==kept)
}
