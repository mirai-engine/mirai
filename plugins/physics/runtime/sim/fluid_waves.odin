package mirai_physics

import cmath "core:math"

// The waves of the surface of a plane: a sum of waves of Gerstner. The water
// at a point of the still surface goes round in the plane of each wave, up by
// its amplitude and along it by its share of the steepness, which sharpens the
// crests and widens the troughs. Every reader of the surface goes through
// wave_point and wave_surface, the shaders of the water through their Slang
// twins (plugins/water/shaders/water_waves.slang) on the terms that
// wave_terms makes: the same function on the same numbers.

FLUID_WAVES :: 8
@(private) WAVE_FOLD :: f32(0.9)    // most of the sum of k A the steepness reaches: the surface never folds over itself
@(private) WAVE_ITERATIONS :: 3     // steps of Newton from a point of the surface back to where it rests
@(private) WAVE_ORIGIN_STEP :: 256.0 // m: the queries of the solver measure the phase from a multiple of it near them

// A wave of Gerstner in the world.
Fluid_Wave :: struct {
    direction:[2]f32, // along x and z, where it travels; not zero
    length:f32,       // m, crest to crest
    amplitude:f32,    // m, from the still surface to a crest
    speed:f32,        // m/s of its crests
    phase:f32,        // radians at the origin of the world at time zero
}

Fluid_Waves :: struct {
    waves:[FLUID_WAVES]Fluid_Wave,
    count:u32,
    steepness:f32, // 0 to 1: of what the water of a wave of Gerstner moves sideways, the share it does; 0 rounds the crests as sines
}

// A wave at a time, measured from an origin: what wave_point evaluates, on
// the CPU and in the shaders (water_waves.slang Water_Wave).
Wave_Term :: struct {
    k:[2]f32,     // radians a metre, along its direction
    amplitude:f32,
    across:f32,   // m the water moves along the direction
    phase:f32,    // radians at the origin, at the time
}

@(private)
waves_valid :: proc "contextless" (waves:Fluid_Waves) -> bool {
    if waves.count>FLUID_WAVES || !(waves.steepness>=0 && waves.steepness<=1) {return false}
    for i in 0..<waves.count {
        wave:=waves.waves[i]
        d:=wave.direction
        if !(d.x*d.x+d.y*d.y>1e-12 && d.x*d.x+d.y*d.y<=max(f32)) {return false}
        if !(wave.length>0 && wave.length<=max(f32)) || !(wave.amplitude>=0 && wave.amplitude<=max(f32)) {return false}
        if !(wave.speed>=0 && wave.speed<=max(f32)) || !(abs(wave.phase)<=max(f32)) {return false}
    }
    return true
}

// Each wave with a unit direction.
@(private)
waves_of :: proc "contextless" (waves:Fluid_Waves) -> Fluid_Waves {
    out:=waves
    for &wave in out.waves[:out.count] {wave.direction/=cmath.sqrt(wave.direction.x*wave.direction.x+wave.direction.y*wave.direction.y)}
    for &wave in out.waves[out.count:] {wave={}}
    return out
}

// How far above the still surface the crests can reach, and below it the troughs.
waves_reach :: proc "contextless" (waves:^Fluid_Waves) -> (reach:f32) {
    for wave in waves.waves[:waves.count] {reach+=wave.amplitude}
    return
}

// The most the height of the waves changes, metres a metre of the still
// surface the water rests on, and the most of that metre the water moves
// sideways: under 1, as the surface never folds. The surface itself rises no
// more than rise / (1 - moved) a metre.
waves_slope :: proc "contextless" (waves:^Fluid_Waves) -> (rise,moved:f32) {
    for wave in waves.waves[:waves.count] {rise+=2*cmath.PI/wave.length*wave.amplitude}
    return rise,waves.steepness*min(rise,WAVE_FOLD)
}

// The waves at `time` seconds, measured from `origin` (x and z of the world):
// a point at p relative to it is at origin + p. The phase is reduced in f64,
// so far from the centre of the world and long after it started, every wave
// keeps its precision.
wave_terms :: proc "contextless" (waves:^Fluid_Waves,time:f64,origin:[2]f64) -> (terms:[FLUID_WAVES]Wave_Term,count:int) {
    count=int(waves.count)
    folded:f32
    for wave in waves.waves[:count] {folded+=2*cmath.PI/wave.length*wave.amplitude}
    share:=waves.steepness*min(1,WAVE_FOLD/max(folded,1e-30))
    for wave,i in waves.waves[:count] {
        number:=2*cmath.PI/f64(wave.length)
        k:=[2]f64{f64(wave.direction.x),f64(wave.direction.y)}*number
        turned:=f64(wave.phase)-number*f64(wave.speed)*time+k.x*origin.x+k.y*origin.y
        turned-=cmath.floor(turned/(2*cmath.PI)+0.5)*2*cmath.PI
        terms[i]={k={f32(k.x),f32(k.y)},amplitude=wave.amplitude,across=wave.amplitude*share,phase=f32(turned)}
    }
    return
}

// Where the water that rests at p (x and z from the origin of the terms) is,
// as an offset from that point of the still surface, and the normal of the
// surface there. j: how the place it reaches changes with p, x and z by x and z.
wave_point :: proc "contextless" (terms:[]Wave_Term,p:[2]f32) -> (offset:Vec3,normal:Vec3,j:matrix[2,2]f32) {
    j=1
    slope:[2]f32
    for term in terms {
        s,c:=cmath.sincos(term.k.x*p.x+term.k.y*p.y+term.phase)
        number:=cmath.sqrt(term.k.x*term.k.x+term.k.y*term.k.y)
        d:=term.k/number
        offset.x-=term.across*d.x*s
        offset.z-=term.across*d.y*s
        offset.y+=term.amplitude*c
        slope-=term.amplitude*s*term.k
        bend:=term.across*number*c
        j[0,0]-=bend*d.x*d.x
        j[0,1]-=bend*d.x*d.y
        j[1,0]-=bend*d.y*d.x
        j[1,1]-=bend*d.y*d.y
    }
    along_x:=Vec3{j[0,0],slope.x,j[1,0]}
    along_z:=Vec3{j[0,1],slope.y,j[1,1]}
    n:=Vec3{along_z.y*along_x.z-along_z.z*along_x.y,along_z.z*along_x.x-along_z.x*along_x.z,along_z.x*along_x.y-along_z.y*along_x.x}
    length:=cmath.sqrt(n.x*n.x+n.y*n.y+n.z*n.z)
    normal=length>1e-20?n/length:UP
    return
}

// The height of the surface over x and z (from the origin of the terms) above
// the still surface, and its normal: the place where the water that reaches
// there rests, found by Newton from that point.
wave_surface :: proc "contextless" (terms:[]Wave_Term,x,z:f32) -> (height:f32,normal:Vec3) {
    if len(terms)==0 {return 0,UP}
    p:=[2]f32{x,z}
    for _ in 0..<WAVE_ITERATIONS {
        offset,_,j:=wave_point(terms,p)
        miss:=p+{offset.x,offset.z}-{x,z}
        det:=j[0,0]*j[1,1]-j[0,1]*j[1,0]
        if !(abs(det)>1e-6) {break}
        p-={j[1,1]*miss.x-j[0,1]*miss.y,j[0,0]*miss.y-j[1,0]*miss.x}/det
    }
    offset,n,_:=wave_point(terms,p)
    return offset.y,n
}

// The origin a query of the solver near x and z measures the waves from.
@(private)
wave_origin :: #force_inline proc "contextless" (x,z:f32) -> [2]f64 {
    return {cmath.round(f64(x)/WAVE_ORIGIN_STEP)*WAVE_ORIGIN_STEP,cmath.round(f64(z)/WAVE_ORIGIN_STEP)*WAVE_ORIGIN_STEP}
}

// Seconds the world has stepped: the time of its waves.
world_time :: proc(w:^World) -> f64 {return w.time}
