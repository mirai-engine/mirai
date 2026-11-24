package mirai_audio

import "core:math"

// Filters: the biquads of the Audio EQ Cookbook (Robert Bristow-Johnson) in
// transposed direct form II, five coefficients and two values of memory per
// channel. A bus runs BUS_FILTERS of them in a row and a voice one low-pass.
// A change of coefficients never steps: across the chunk after it the filter
// before the change keeps running beside the new one, which takes over its
// memory, and the output crossfades from one to the other.

Filter_Kind :: enum u8 {Off,Lowpass,Highpass,Bandpass,Peak}

// One band. A filter whose frequency is 0 or not under FILTER_HZ_MAX of the
// sample rate passes what comes in: a low-pass that high hears everything.
Filter :: struct {
    kind:Filter_Kind,
    frequency:f32, // Hz: cutoff of a low or high pass, center of a band pass or a peak
    q:f32,         // how narrow: FILTER_Q_DEFAULT (Butterworth) when 0
    gain:f32,      // dB of a peak; within FILTER_GAIN_MAX
}

BUS_FILTERS :: 4
FILTER_Q_DEFAULT :: f32(math.SQRT_TWO/2)
FILTER_Q_MIN :: f32(0.1)
FILTER_Q_MAX :: f32(24)
FILTER_GAIN_MAX :: f32(24) // dB
FILTER_HZ_MIN :: f32(10)
FILTER_HZ_MAX :: f32(0.49) // of the sample rate

@(private)
Biquad :: struct {b0,b1,b2,a1,a2:f32}

// A filter as it runs: its coefficients, and those before its last change
// while it crossfades from them.
@(private)
Biquad_Fade :: struct {
    now,old:Biquad,
    on,old_on,fading:bool,
    state,old_state:[2]Biquad_State, // per channel
}

// Whether a filter can be set: numbers where a filter of its kind needs them.
filter_valid :: proc "contextless" (f:Filter) -> bool {
    if f.kind>max(Filter_Kind) {return false}
    if f.kind==.Off {return true}
    return finite(f.frequency) && f.frequency>=0 && finite(f.q) && f.q>=0 && finite(f.gain) && abs(f.gain)<=FILTER_GAIN_MAX
}

// The coefficients of a filter at a sample rate; false when it passes what
// comes in as it is.
@(private)
biquad_of :: proc "contextless" (f:Filter,sample_rate:f32) -> (b:Biquad,on:bool) {
    if f.kind==.Off || !(f.frequency>0) {return}
    // Above what it can shape, a low-pass or a peak leaves everything as it is.
    if f.frequency>=sample_rate*FILTER_HZ_MAX && (f.kind==.Lowpass || f.kind==.Peak) {return}
    if f.kind==.Peak && f.gain==0 {return}
    hz:=clamp(f.frequency,FILTER_HZ_MIN,sample_rate*FILTER_HZ_MAX)
    q:=clamp(f.q if f.q>0 else FILTER_Q_DEFAULT,FILTER_Q_MIN,FILTER_Q_MAX)
    omega:=2*math.PI*f64(hz)/f64(sample_rate)
    cosine:=math.cos(omega)
    alpha:=math.sin(omega)/(2*f64(q))
    b0,b1,b2,a0,a1,a2:f64
    a1=-2*cosine
    switch f.kind {
    case .Off:return
    case .Lowpass:
        b0,b1,b2=(1-cosine)/2,1-cosine,(1-cosine)/2
        a0,a2=1+alpha,1-alpha
    case .Highpass:
        b0,b1,b2=(1+cosine)/2,-(1+cosine),(1+cosine)/2
        a0,a2=1+alpha,1-alpha
    case .Bandpass:
        // Constant skirt gain, 0 dB at its center.
        b0,b1,b2=alpha,0,-alpha
        a0,a2=1+alpha,1-alpha
    case .Peak:
        a:=math.pow(10,f64(clamp(f.gain,-FILTER_GAIN_MAX,FILTER_GAIN_MAX))/40)
        b0,b1,b2=1+alpha*a,-2*cosine,1-alpha*a
        a0,a2=1+alpha/a,1-alpha/a
    }
    return {f32(b0/a0),f32(b1/a0),f32(b2/a0),f32(a1/a0),f32(a2/a0)},true
}

// Gives the filter new coefficients, crossfaded into over the next run.
@(private)
biquad_fade_set :: proc "contextless" (f:^Biquad_Fade,b:Biquad,on:bool) {
    if !f.fading {f.old,f.old_state,f.old_on,f.fading=f.now,f.state,f.on,true}
    if on {f.now=b}
    f.state=f.old_state if f.old_on else {}
    f.on=on
    if !f.on && !f.old_on {f.fading=false}
}

@(private)
biquad_tick :: #force_inline proc "contextless" (f:Biquad,s:^Biquad_State,x:f32) -> f32 {
    y:=f.b0*x+s.z1
    s.z1=f.b1*x-f.a1*y+s.z2
    s.z2=f.b2*x-f.a2*y
    return y
}

// Filters stereo frames [from,to) of buffer in place.
@(private)
biquad_fade_run :: proc "contextless" (f:^Biquad_Fade,buffer:[^]f32,from,to:int) {
    if to<=from {return}
    span:=f32(to-from)
    #no_bounds_check for channel in 0..<2 {
        switch {
        case f.fading:
            for k in from..<to {
                x:=buffer[k*2+channel]
                y:=biquad_tick(f.now,&f.state[channel],x) if f.on else x
                old:=biquad_tick(f.old,&f.old_state[channel],x) if f.old_on else x
                buffer[k*2+channel]=old+(y-old)*(f32(k-from)/span)
            }
        case f.on:
            s:=f.state[channel]
            c:=f.now
            for k in from..<to {
                x:=buffer[k*2+channel]
                y:=c.b0*x+s.z1
                s.z1=c.b1*x-c.a1*y+s.z2
                s.z2=c.b2*x-c.a2*y
                buffer[k*2+channel]=y
            }
            f.state[channel]=s
        }
    }
    f.fading=false
}
