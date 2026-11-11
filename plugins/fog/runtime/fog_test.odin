package fog

import "core:testing"
import volume "mirai:engine/volume"
import mm "mirai:std/math"

// The shaders get the volumes relative to the origin the renderer draws from:
// the base of a volume and its box move by it, and what it is made of does not.
@(test)
fog_volumes_go_to_the_shaders_relative_to_the_origin :: proc(t:^testing.T) {
    state:Fog_Gpu
    pose:=mm.Transform{position={-18000.5,250,9000},rotation=1,scale=1}
    state.volumes[0]={volume=volume.gpu_volume(volume.Volume{shape=.Box,extents={10,5,10}},pose),medium={0.1,0.1,0.1,0.1},params={0,0.5,0.2,245}}
    state.count=1
    origin:=[3]f32{-17408,0,9216}
    got:=volumes_relative(&state,origin)[0]
    testing.expect_value(t,got.params,[4]f32{0,0.5,0.2,245})
    testing.expect_value(t,got.medium,state.volumes[0].medium)
    testing.expect_value(t,got.volume,volume.gpu_volume_relative(state.volumes[0].volume,origin))
    far:=volumes_relative(&state,{0,1024,0})[0]
    testing.expect_value(t,far.params.w,f32(245-1024))
}

// A medium another plugin adds is a box whose sides are the scale of its
// transform, added to what is there; a dry one holds nothing and takes out
// what carves.
@(test)
fog_media_are_boxes_that_add_to_the_volumes :: proc(t:^testing.T) {
    state:Fog_Gpu
    box:=mm.Transform{position={3,-2,1},rotation=1,scale={4,2,6}}
    testing.expect(t,medium_gpu(&state,{box=box,density=0.5,color={1,1,1},carved=true,sun_only=true,shade=0.25}))
    testing.expect(t,medium_gpu(&state,{box=box,priority=1,dry=true}))
    testing.expect(t,!medium_gpu(&state,{box={rotation=1,scale={1,0,1}},density=1}))
    testing.expect_value(t,state.count,2)
    water,dry:=state.volumes[0],state.volumes[1]
    testing.expect_value(t,water.volume.shape.xyz,[3]f32{2,1,3})
    testing.expect_value(t,water.volume.kind,[4]u32{1,1,0,0})
    testing.expect_value(t,water.params.w,f32(-3))
    testing.expect_value(t,water.carve,[4]f32{0,f32(CARVE_CARVED|CARVE_SUN_ONLY),0.25,0})
    testing.expect_value(t,dry.medium,[4]f32{})
    testing.expect_value(t,dry.carve,[4]f32{1,f32(CARVE_DRY),0,0})
    testing.expect(t,state.shade && state.dry)
}

// A layer of the wisps is where the world and the time put it, whatever the
// origin the renderer draws from: a place far from the centre of the world
// falls on the same point of the noise from two origins, and the layer moves
// by its drift.
@(test)
fog_wisps_stay_in_the_world_whatever_the_origin :: proc(t:^testing.T) {
    drift:=[3]f32{0.5,0,0.2}
    at :: proc(cell:[4]i32,within:[4]f32,place,origin:[3]f32,size:f64) -> [3]f64 {
        p:[3]f64
        for axis in 0..<3 {p[axis]=f64(cell[axis])+f64(within[axis])+f64(place[axis]-origin[axis])/size}
        return p
    }
    place:=[3]f32{-180000.25,40,90100.5}
    sizes,shares,changes:=WISP_SIZES,WISP_DRIFT,WISP_CHANGE
    for k in 0..<WISP_OCTAVES {
        size:=1.5*f64(sizes[k])
        a_cell,a_within:=wisp_lattice(drift,1.5,k,{-179200,0,90112},3600)
        b_cell,b_within:=wisp_lattice(drift,1.5,k,{-181248,1024,89088},3600)
        a:=at(a_cell,a_within,place,{-179200,0,90112},size)
        b:=at(b_cell,b_within,place,{-181248,1024,89088},size)
        for axis in 0..<3 {testing.expectf(t,abs(a[axis]-b[axis])<1e-3,"layer %d axis %d: %v and %v",k,axis,a,b)}
        later_cell,later_within:=wisp_lattice(drift,1.5,k,{-179200,0,90112},3601)
        later:=at(later_cell,later_within,place,{-179200,0,90112},size)
        moved:=f64(drift.x)*f64(shares[k])+f64(changes[k].x)*1.5
        testing.expectf(t,abs((a.x-later.x)*size-moved)<1e-3,"layer %d moves %v m in a second along x",k,(a.x-later.x)*size)
    }
}
