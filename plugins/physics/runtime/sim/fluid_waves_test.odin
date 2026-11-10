package mirai_physics

import "core:testing"
import cmath "core:math"

@(private="file")
swell :: proc() -> Fluid_Waves {
    waves:Fluid_Waves
    waves.waves[0]={direction={1,0},length=12,amplitude=0.6,speed=4.3,phase=0.3}
    waves.waves[1]={direction={0.6,0.8},length=5,amplitude=0.2,speed=2.8,phase=1.9}
    waves.waves[2]={direction={-0.3,1},length=2.2,amplitude=0.05,speed=1.8,phase=4}
    waves.count,waves.steepness=3,0.8
    return waves
}

// The height the solver finds over a point is that of the water that rests
// where Newton finds it, and its normal is that of the surface around it.
@(test)
the_surface_over_a_point_is_where_the_water_of_the_waves_goes :: proc(t:^testing.T) {
    waves:=waves_of(swell())
    terms,count:=wave_terms(&waves,37.25,{-512,256})
    for i in 0..<64 {
        rest:=[2]f32{f32(i%8)*1.7-6,f32(i/8)*1.3-5}
        offset,normal,_:=wave_point(terms[:count],rest)
        reached:=rest+{offset.x,offset.z}
        height,found:=wave_surface(terms[:count],reached.x,reached.y)
        testing.expectf(t,abs(height-offset.y)<1e-3,"over %v: %v, the water there is at %v",reached,height,offset.y)
        testing.expectf(t,cmath.abs(found.x-normal.x)+cmath.abs(found.z-normal.z)<1e-2,"normal %v and %v",found,normal)
        // The normal is across the surface: a step along it keeps the height as the normal says.
        step:=f32(1e-2)
        ahead,_:=wave_surface(terms[:count],reached.x+step,reached.y)
        testing.expectf(t,abs((ahead-height)/step+normal.x/normal.y)<3e-2,"slope along x at %v",reached)
    }
    // Sharp crests and wide troughs: the mean height over a wave is under its still surface.
    one:Fluid_Waves
    one.waves[0]={direction={1,0},length=10,amplitude=0.8,speed=0}
    one.count,one.steepness=1,1
    one=waves_of(one)
    line,n:=wave_terms(&one,0,{})
    top,bottom,sum:=f32(-1e9),f32(1e9),f32(0)
    for i in 0..<200 {
        h,_:=wave_surface(line[:n],f32(i)*0.05,0)
        top,bottom,sum=max(top,h),min(bottom,h),sum+h
    }
    testing.expect(t,abs(top-0.8)<1e-2 && abs(bottom+0.8)<1e-2)
    testing.expectf(t,sum/200< -0.02,"mean %v",sum/200)
}

// Far from the centre of the world, the waves are those near it moved by a
// whole number of their lengths: the phase keeps its precision.
@(test)
the_waves_far_from_the_centre_and_late_keep_their_shape :: proc(t:^testing.T) {
    one:Fluid_Waves
    one.waves[0]={direction={1,0},length=8,amplitude=0.5,speed=3}
    one.count=1
    one=waves_of(one)
    near,count:=wave_terms(&one,10,{0,0})
    // 8 m a wave and 24 m in 8 s: the same crest, 125000 waves away and 8 s later.
    far,_:=wave_terms(&one,18,{1000000,0})
    for x in 0..<16 {
        a,_:=wave_surface(near[:count],f32(x)*0.5,0)
        b,_:=wave_surface(far[:count],f32(x)*0.5+24,0)
        testing.expectf(t,abs(a-b)<1e-3,"at %v: %v and %v",x,a,b)
    }
}

// A body that floats rides the waves: it rises over a crest and falls into a
// trough, and the world steps the same from a snapshot.
@(test)
a_body_floats_on_the_waves_and_repeats_from_a_snapshot :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    waves:Fluid_Waves
    waves.waves[0]={direction={1,0},length=20,amplitude=0.6,speed=5.6}
    waves.count,waves.steepness=1,0.5
    sea:=fluid_create(&w,{shape=.Plane,density=1000,waves=waves})
    testing.expect(t,sea!={})
    testing.expect(t,fluid_create(&w,{shape=.Box,position={0,0,100},half_extents={1,1,1},density=1000,waves=waves})!={},"a lake has waves as the sea does")
    desc:=BODY_DESC_DEFAULT
    body:=body_create(&w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{{0.5,0.25,0.5}}
    shape.density=400
    shape_create(&w,body,shape)
    low,high:=f32(1e9),f32(-1e9)
    for step in 0..<600 {
        world_step(&w,1.0/60)
        if step<120 {continue}
        state,_:=body_get(&w,body)
        surface,_,_:=fluid_surface(&w,sea,state.center.x,state.center.z)
        testing.expectf(t,abs(state.center.y-surface)<0.35,"step %d: the body at %v, the surface at %v",step,state.center.y,surface)
        low,high=min(low,state.center.y),max(high,state.center.y)
    }
    testing.expectf(t,high-low>0.6,"it went from %v to %v",low,high)
    testing.expect(t,world_time(&w)>9.99 && world_time(&w)<10.01)
    buffer:=make([]byte,world_snapshot_capacity(&w))
    defer delete(buffer)
    written,ok:=world_snapshot(&w,buffer)
    testing.expect(t,ok)
    for _ in 0..<60 {world_step(&w,1.0/60)}
    first:=world_hash(&w)
    testing.expect(t,world_restore(&w,buffer[:written]))
    for _ in 0..<60 {world_step(&w,1.0/60)}
    testing.expect_value(t,world_hash(&w),first)
}
