package mirai_audio

import "core:math"
import mm "mirai:std/math"

// The direct sound of a spatial voice, translated from Steam Audio's direct
// effect (direct_effect.cpp, direct_simulator.cpp, air_absorption.cpp,
// directivity.cpp, eq_effect.cpp, iir.cpp): one gain and a three-band EQ from
// the distance, the air, the directivity of the source and what hides it.

// Bands of the EQ, in Hz: below 800, 800 to 8000 and above 8000.
BANDS :: 3
// Default transmission of what hides a source (Steam Audio's default
// material), low to high band: a wall lets through some lows and few highs.
TRANSMISSION_DEFAULT :: [BANDS]f32{0.1,0.05,0.03}

// How a source sends its sound around it: a dipole that is weight parts
// figure-eight and the rest omnidirectional, raised to power. Weight 0, or
// power 0, sounds the same all around; 0.5 is a cardioid that faces -Z of the
// source.
Directivity :: struct {
    weight,power:f32,
}

@(private) AIR_ABSORPTION :: [BANDS]f32{0.0002,0.0017,0.0182} // per meter
@(private) EQ_GAIN_MIN :: f32(0.0625)
@(private) EQ_GAIN_STEP :: f32(0.0115) // 0.1 dB: below what an ear tells apart
@(private) EQ_FLAT :: f32(0.944)       // -0.5 dB: a band this near unity is not heard dulled
@(private) BAND_EDGES :: [2]f32{800,8000}

// The part of each band the air lets through over distance meters.
air_absorption :: proc "contextless" (distance:f32) -> (gains:[BANDS]f32) {
    d:=max(distance,0)
    for c,i in AIR_ABSORPTION {gains[i]=math.exp(-c*d)}
    return
}

// The gain of a source with a directivity, turned by rotation, toward a point.
directivity_gain :: proc "contextless" (d:Directivity,source:[3]f32,rotation:quaternion128,point:[3]f32) -> f32 {
    if d.weight==0 {return 1}
    to:=point-source
    length:=math.sqrt(to.x*to.x+to.y*to.y+to.z*to.z)
    if !(length>1e-6) {return 1}
    local:=mm.quat_rotate(conj(quat_unit(rotation)),to/length)
    return math.pow(abs((1-d.weight)+d.weight*-local.z),d.power)
}

@(private)
quat_unit :: proc "contextless" (q:quaternion128) -> quaternion128 {
    length:=math.sqrt(real(q)*real(q)+imag(q)*imag(q)+jmag(q)*jmag(q)+kmag(q)*kmag(q))
    if !(length>1e-6) || !finite(length) {return 1}
    return quaternion(real=real(q)/length,imag=imag(q)/length,jmag=jmag(q)/length,kmag=kmag(q)/length)
}

// DirectEffect::calculateGainAndEQ with frequency-dependent transmission:
// occlusion is how hidden the source is (0 in sight, 1 hidden) and
// transmission the part of each band what hides it lets through. The EQ is
// normalized to a peak of 1, with the rest in the gain.
direct_gain_eq :: proc "contextless" (attenuation,directivity:f32,air:[BANDS]f32,occlusion:f32,transmission:[BANDS]f32) -> (gain:f32,eq:[BANDS]f32) {
    gain=attenuation*directivity
    visible:=1-clamp(occlusion,0,1)
    for i in 0..<BANDS {eq[i]=air[i]*(visible+(1-visible)*clamp(transmission[i],0,1))}
    peak:=max(eq[0],eq[1],eq[2])
    if !(peak>=1.17549435e-38) {return 0,{1,1,1}}
    for &g in eq {g=max(g/peak,EQ_GAIN_MIN)}
    gain*=peak
    return
}

@(private)
Biquad_State :: struct {z1,z2:f32} // transposed direct form II

@(private)
biquad_shelf :: proc "contextless" (cutoff,gain:f32,sample_rate:int,high:bool) -> Biquad {
    w0:=2*math.PI*f64(cutoff)/f64(sample_rate)
    cw,sw:=math.cos(w0),math.sin(w0)
    alpha:=sw/(2*0.707)
    a:=math.sqrt(f64(gain))
    root:=2*math.sqrt(a)*alpha
    s:=f64(1) if high else -1
    a0:=(a+1)-s*(a-1)*cw+root
    a1:=s*2*((a-1)-s*(a+1)*cw)
    a2:=(a+1)-s*(a-1)*cw-root
    b0:=a*((a+1)+s*(a-1)*cw+root)
    b1:=-s*2*a*((a-1)+s*(a+1)*cw)
    b2:=a*((a+1)+s*(a-1)*cw-root)
    return {f32(b0/a0),f32(b1/a0),f32(b2/a0),f32(a1/a0),f32(a2/a0)}
}
@(private)
biquad_peaking :: proc "contextless" (low,high,gain:f32,sample_rate:int) -> Biquad {
    center:=math.sqrt(f64(low)*f64(high))
    q_inverse:=(f64(high)-f64(low))/center
    w0:=2*math.PI*center/f64(sample_rate)
    cw,sw:=math.cos(w0),math.sin(w0)
    alpha:=sw*q_inverse/2
    a:=math.sqrt(f64(gain))
    a0:=1+alpha/a
    return {f32((1+alpha*a)/a0),f32(-2*cw/a0),f32((1-alpha*a)/a0),f32(-2*cw/a0),f32((1-alpha/a)/a0)}
}

// EQEffect::setFilterGains: a low shelf, a peak and a high shelf.
@(private)
eq_filters :: proc "contextless" (gains:[BANDS]f32,sample_rate:int) -> [BANDS]Biquad {
    edges:=BAND_EDGES
    return {
        biquad_shelf(edges[0],gains[0],sample_rate,false),
        biquad_peaking(edges[0],edges[1],gains[1],sample_rate),
        biquad_shelf(edges[1],gains[2],sample_rate,true),
    }
}

// IIR2Filterer::apply over a cascade, in place, the three stages in one pass
// over the samples.
@(private)
eq_run :: proc "contextless" (filters:^[BANDS]Biquad,states:^[BANDS]Biquad_State,samples:[]f32) #no_bounds_check {
    f0,f1,f2:=filters[0],filters[1],filters[2]
    s0,s1,s2:=states[0],states[1],states[2]
    for &x in samples {
        b:=f0.b0*x+s0.z1
        s0.z1=f0.b1*x-f0.a1*b+s0.z2
        s0.z2=f0.b2*x-f0.a2*b
        c:=f1.b0*b+s1.z1
        s1.z1=f1.b1*b-f1.a1*c+s1.z2
        s1.z2=f1.b2*b-f1.a2*c
        y:=f2.b0*c+s2.z1
        s2.z1=f2.b1*c-f2.a1*y+s2.z2
        s2.z2=f2.b2*c-f2.a2*y
        x=y
    }
    states^={s0,s1,s2}
}
