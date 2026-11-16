package mirai_anim

import "core:testing"
import "core:mem"
import mm "mirai:std/math"

@(test)
blend_spaces_sort_one_dimensional_samples_and_clamp_both_ends :: proc(t:^testing.T) {
    points:=[3]mm.Vec2{{10,0},{0,0},{4,0}}
    space,ok:=blend_space_prepare(points[:],.One)
    if !testing.expect(t,ok) {return};defer blend_space_destroy(&space)
    testing.expect(t,blend_space_validate(space))
    for value in ([?]f32{-100,0,2,4,7,10,100}) {
        weights,sampled:=blend_space_sample(space,{value,0})
        if !testing.expect(t,sampled && weights.count==2) {continue}
        blended:f32
        for weight,i in weights.weights[:weights.count] {blended+=weight*points[weights.samples[i]].x;testing.expect(t,weight>=0 && weight<=1)}
        testing.expect(t,abs(blended-max(f32(0),min(f32(10),value)))<1e-5)
        testing.expect(t,abs(weights.weights[0]+weights.weights[1]-1)<1e-6)
    }
    testing.expect(t,!blend_space_validate({dimension=.One,points=points[:],segments={{samples={1,2}},{samples={1,0}}}}))
    one,prepared:=blend_space_prepare({{2,0}},.One)
    testing.expect(t,prepared);defer blend_space_destroy(&one)
    result,sampled:=blend_space_sample(one,{-100,0})
    testing.expect(t,sampled && result.count==1 && result.weights[0]==1)
}

@(test)
blend_spaces_triangulate_two_dimensions_and_project_outside_the_hull :: proc(t:^testing.T) {
    points:=[5]mm.Vec2{{0,0},{1,0},{1,1},{0,1},{0.5,0.5}}
    space,ok:=blend_space_prepare(points[:],.Two)
    if !testing.expect(t,ok) {return};defer blend_space_destroy(&space)
    testing.expect(t,blend_space_validate(space))
    testing.expect_value(t,len(space.triangles),4)
    probes:=[?]mm.Vec2{{0.2,0.3},{0.5,0.5},{0,0},{1,1},{2,0.4},{0.3,-2},{-1,-1},{4,3}}
    for probe in probes {
        result,sampled:=blend_space_sample(space,probe)
        if !testing.expect(t,sampled && result.count<=3) {continue}
        blended:mm.Vec2;sum:f32
        for weight,i in result.weights[:result.count] {sum+=weight;blended+=weight*points[result.samples[i]];testing.expect(t,weight>=0 && weight<=1)}
        expected:=mm.Vec2{max(f32(0),min(f32(1),probe.x)),max(f32(0),min(f32(1),probe.y))}
        testing.expect(t,abs(blended.x-expected.x)<1e-5 && abs(blended.y-expected.y)<1e-5 && abs(sum-1)<1e-6)
    }
    space.triangles[0].samples[0]=max(u16)
    _,sampled:=blend_space_sample(space,{0,0});testing.expect(t,!sampled)
    testing.expect(t,!blend_space_validate(space))
}

@(test)
blend_spaces_reject_invalid_data_and_sample_without_allocations :: proc(t:^testing.T) {
    nan:=transmute(f32)u32(0x7fc00000)
    _,ok:=blend_space_prepare({{0,0},{0,0}},.One);testing.expect(t,!ok)
    _,ok=blend_space_prepare({{0,0},{1,1},{2,2}},.Two);testing.expect(t,!ok)
    _,ok=blend_space_prepare({{0,0},{1,0},{nan,1}},.Two);testing.expect(t,!ok)
    _,ok=blend_space_prepare({{0,0},{1,0}},.Two);testing.expect(t,!ok)
    _,ok=blend_space_sample({},{});testing.expect(t,!ok)
    tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    saved:=context;context.allocator=mem.tracking_allocator(&tracking);defer context=saved
    points:[25]mm.Vec2
    for &point,i in points {point={f32(i%5),f32(i/5)}}
    space,prepared:=blend_space_prepare(points[:],.Two)
    if !testing.expect(t,prepared) {return};defer blend_space_destroy(&space)
    allocations:=tracking.total_allocation_count
    for i in 0..<1000 {
        result,sampled:=blend_space_sample(space,{f32(i%13)*0.5-1,f32(i%11)*0.5-1})
        testing.expect(t,sampled && result.count<=3)
    }
    testing.expect_value(t,tracking.total_allocation_count,allocations)
    _,sampled:=blend_space_sample(space,{nan,0});testing.expect(t,!sampled)
}

@(test)
blend_space_preparation_handles_extreme_coordinates_and_canonical_edges :: proc(t:^testing.T) {
    points:=[4]mm.Vec2{{-1e30,-1e30},{1e30,-1e30},{1e30,1e30},{-1e30,1e30}}
    space,ok:=blend_space_prepare(points[:],.Two)
    if !testing.expect(t,ok) {return};defer blend_space_destroy(&space)
    result,sampled:=blend_space_sample(space,{0,0})
    testing.expect(t,sampled && abs(result.weights[0]+result.weights[1]+result.weights[2]-1)<1e-6)
    bad:=space;bad.triangles=space.triangles[:1]
    testing.expect(t,!blend_space_validate(bad))
    grid:[BLEND_MAX_SAMPLES]mm.Vec2
    for &point,i in grid {point={f32(i%16),f32(i/16)}}
    full,prepared:=blend_space_prepare(grid[:],.Two)
    if !testing.expect(t,prepared) {return};defer blend_space_destroy(&full)
    testing.expect(t,blend_space_validate(full))
    result,sampled=blend_space_sample(full,{9.25,7.5})
    testing.expect(t,sampled && result.count<=3)
}

@(test)
hostile_blend_spaces_reject_untrusted_topology_and_keep_random_triangulations_normalized :: proc(t:^testing.T) {
    rng:=mm.rng_make(919)
    rounds :: #config(ANIM_BLEND_HOSTILE_ROUNDS,400)
    for _ in 0..<rounds {
        points:[12]mm.Vec2
        for &point in points {point={mm.random_f32(&rng),mm.random_f32(&rng)}}
        space,ok:=blend_space_prepare(points[:],.Two)
        if !testing.expect(t,ok) {continue}
        result,sampled:=blend_space_sample(space,{mm.random_range(&rng,-10,10),mm.random_range(&rng,-10,10)})
        testing.expect(t,sampled && result.count<=3)
        sum:f32;for weight in result.weights[:result.count] {sum+=weight;testing.expect(t,weight>=0 && weight<=1)}
        testing.expect(t,abs(sum-1)<1e-5)
        triangle:=&space.triangles[mm.random_int(&rng,0,len(space.triangles))]
        triangle.samples[0]=max(u16)
        _,sampled=blend_space_sample(space,{0,0});testing.expect(t,!sampled)
        testing.expect(t,!blend_space_validate(space))
        blend_space_destroy(&space)
    }
}

@(private) Blend_Allocation_Failure :: struct {owner:mem.Allocator,remaining:int}
@(private)
blend_failure_allocator :: proc(data:rawptr,mode:mem.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,mem.Allocator_Error) {
    state:=(^Blend_Allocation_Failure)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if state.remaining==0 {return nil,.Out_Of_Memory};state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
blend_space_preparation_releases_every_partial_allocation_and_reports_memory_failure :: proc(t:^testing.T) {
    points:=[5]mm.Vec2{{0,0},{1,0},{1,1},{0,1},{0.5,0.5}}
    failure:=Blend_Allocation_Failure{owner=context.allocator}
    success:=false
    for budget in 0..<16 {
        failure.remaining=budget
        error:Blend_Error
        space,ok:=blend_space_prepare(points[:],.Two,{blend_failure_allocator,&failure},&error)
        if ok {testing.expect_value(t,error,Blend_Error.None);blend_space_destroy(&space);success=true;break}
        testing.expect_value(t,error,Blend_Error.Out_Of_Memory)
    }
    testing.expect(t,success)
}
