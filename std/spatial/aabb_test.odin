package spatial

import "core:math/rand"
import "core:testing"
import math "mirai:std/math"

@(private) Random :: struct {state:rand.Default_Random_State}
@(private) random_make :: proc(seed:u64) -> Random {return {rand.create(seed)}}
@(private) random_f32 :: proc(r:^Random, lo,hi:f32) -> f32 {return rand.float32_range(lo,hi,rand.default_random_generator(&r.state))}
@(private) random_int :: proc(r:^Random, n:int) -> int {return rand.int_max(n,rand.default_random_generator(&r.state))}
@(private) random_vector :: proc(r:^Random, lo,hi:f32) -> [3]f32 {return {random_f32(r,lo,hi),random_f32(r,lo,hi),random_f32(r,lo,hi)}}
@(private) random_box :: proc(r:^Random, world,size:f32) -> Aabb {
    center,half:=random_vector(r,-world,world),random_vector(r,0,size)
    return {center-half,center+half}
}
// A translation with some components exactly zero, the case a slab test has to survive.
@(private) random_translation :: proc(r:^Random, length:f32) -> [3]f32 {
    d:=random_vector(r,-length,length)
    for i in 0..<3 {
        if random_int(r,4)==0 {d[i]=0}
    }
    return d
}

@(test)
aabb_measures_area_center_and_half_size :: proc(t:^testing.T) {
    a:=Aabb{{-1,0,2},{1,3,6}}
    testing.expect_value(t,aabb_area(a),f32(2*(2*3+3*4+4*2)))
    testing.expect_value(t,aabb_center(a),[3]f32{0,1.5,4})
    testing.expect_value(t,aabb_extents(a),[3]f32{1,1.5,2})
    testing.expect_value(t,aabb_area(Aabb{{1,1,1},{1,1,1}}),f32(0))
}

@(test)
aabb_translate_extend_bounds_the_box_and_its_displaced_copy :: proc(t:^testing.T) {
    a:=Aabb{{0,0,0},{1,1,1}}
    testing.expect_value(t,aabb_translate_extend(a,{2,-3,0}),Aabb{{0,-3,0},{3,1,1}})
    testing.expect_value(t,aabb_translate_extend(a,{}),a)
}

@(test)
aabb_valid_rejects_inverted_and_non_finite_boxes :: proc(t:^testing.T) {
    zero:=f32(0)
    testing.expect(t,aabb_valid(Aabb{{0,0,0},{0,0,0}}))
    testing.expect(t,aabb_valid(Aabb{{-1,-1,-1},{1,1,1}}))
    testing.expect(t,!aabb_valid(Aabb{{0,2,0},{1,1,1}}))
    testing.expect(t,!aabb_valid(Aabb{{0,0,0},{1,1/zero,1}}))
    testing.expect(t,!aabb_valid(Aabb{{zero/zero,0,0},{1,1,1}}))
}

@(test)
aabb_ray_reports_where_the_segment_enters_the_box :: proc(t:^testing.T) {
    a:=Aabb{{0,0,0},{1,1,1}}
    fraction,hit:=aabb_ray(a,{-2,0.5,0.5},{4,0,0},1)
    testing.expect(t,hit)
    testing.expect_value(t,fraction,f32(0.5))
    fraction,hit=aabb_ray(a,{3,0.5,0.5},{-4,0,0},1)
    testing.expect(t,hit)
    testing.expect_value(t,fraction,f32(0.5))
    fraction,hit=aabb_ray(a,{0.5,0.5,0.5},{1,2,3},1)
    testing.expect(t,hit)
    testing.expect_value(t,fraction,f32(0))
    fraction,hit=aabb_ray(a,{-1,-1,-1},{4,4,4},1)
    testing.expect(t,hit)
    testing.expect_value(t,fraction,f32(0.25))
}

@(test)
aabb_ray_misses_boxes_off_the_segment_or_beyond_its_reach :: proc(t:^testing.T) {
    a:=Aabb{{0,0,0},{1,1,1}}
    _,hit:=aabb_ray(a,{-2,2,0.5},{4,0,0},1)
    testing.expect(t,!hit)
    _,hit=aabb_ray(a,{-2,0.5,0.5},{-4,0,0},1)
    testing.expect(t,!hit)
    _,hit=aabb_ray(a,{-2,0.5,0.5},{4,0,0},0.25)
    testing.expect(t,!hit)
    _,hit=aabb_ray(a,{-2,0.5,0.5},{4,0,0},0.5)
    testing.expect(t,hit)
    _,hit=aabb_ray(a,{-1,3,0.5},{4,-1,0},1)
    testing.expect(t,!hit)
    _,hit=aabb_ray(a,{0.5,0.5,0.5},{1,0,0},-1)
    testing.expect(t,!hit)
}

@(test)
aabb_ray_handles_zero_components_of_the_translation :: proc(t:^testing.T) {
    a:=Aabb{{0,0,0},{1,1,1}}
    // Sliding along a face touches the box; the same line just outside does not.
    fraction,hit:=aabb_ray(a,{-1,1,0.5},{4,0,0},1)
    testing.expect(t,hit)
    testing.expect_value(t,fraction,f32(0.25))
    _,hit=aabb_ray(a,{-1,1.0001,0.5},{4,0,0},1)
    testing.expect(t,!hit)
    // No translation at all is a point test.
    fraction,hit=aabb_ray(a,{1,1,1},{},1)
    testing.expect(t,hit)
    testing.expect_value(t,fraction,f32(0))
    _,hit=aabb_ray(a,{1,1,1.5},{},1)
    testing.expect(t,!hit)
    // A component too small to divide by is parallel, not an overflow.
    _,hit=aabb_ray(a,{0.5,0.5,-1},{1e-30,0,2},1)
    testing.expect(t,hit)
    _,hit=aabb_ray(a,{1.5,0.5,-1},{1e-30,0,2},1)
    testing.expect(t,!hit)
    // A box without volume is still hit by a segment through it.
    point:=Aabb{{2,2,2},{2,2,2}}
    fraction,hit=aabb_ray(point,{2,0,2},{0,4,0},1)
    testing.expect(t,hit)
    testing.expect_value(t,fraction,f32(0.5))
}

@(test)
aabb_ray_never_misses_a_box_inside_one_it_hits_later :: proc(t:^testing.T) {
    random:=random_make(11)
    failures:=0
    for _ in 0..<4000 {
        inner:=random_box(&random,10,2)
        outer:=math.aabb_merge(inner,random_box(&random,10,2))
        origin,translation:=random_vector(&random,-12,12),random_translation(&random,20)
        inner_fraction,inner_hit:=aabb_ray(inner,origin,translation,1)
        outer_fraction,outer_hit:=aabb_ray(outer,origin,translation,1)
        if inner_hit&&(!outer_hit||outer_fraction>inner_fraction) {failures+=1}
    }
    testing.expect_value(t,failures,0)
}

@(test)
aabb_sweep_reports_the_first_touch_of_a_moving_box :: proc(t:^testing.T) {
    a:=Aabb{{0,0,0},{1,1,1}}
    moving:=Aabb{{-4,0,0},{-3,1,1}}
    fraction,hit:=aabb_sweep(a,moving,{6,0,0},1)
    testing.expect(t,hit)
    testing.expect_value(t,fraction,f32(0.5))
    _,hit=aabb_sweep(a,moving,{2,0,0},1)
    testing.expect(t,!hit)
    _,hit=aabb_sweep(a,moving,{6,3,0},1)
    testing.expect(t,!hit)
    fraction,hit=aabb_sweep(a,Aabb{{0.5,0.5,0.5},{2,2,2}},{0,1,0},1)
    testing.expect(t,hit)
    testing.expect_value(t,fraction,f32(0))
    // Without motion it is the overlap test.
    _,hit=aabb_sweep(a,Aabb{{1,1,1},{2,2,2}},{},1)
    testing.expect(t,hit)
    _,hit=aabb_sweep(a,Aabb{{1.5,1,1},{2,2,2}},{},1)
    testing.expect(t,!hit)
}
