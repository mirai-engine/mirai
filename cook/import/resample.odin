package importer

import "base:runtime"
import "core:math"
import audio "mirai:audio"

// Band-limited resampling of a sound to the rate of the mixer, once, when it
// is imported, so that a voice at its own pitch plays it by copying. Each
// output frame is the sum of the source frames around its place weighted by
// a sinc windowed by Kaiser, the design of the sinc converters of
// libsamplerate and r8brain: the window is sampled once into a table, fine
// enough to be read with linear interpolation, and its length follows from
// the stopband and the transition band (Kaiser's formulas). Quality goes
// before speed: this runs on import, never in a frame.

RESAMPLE_STOPBAND :: 120     // dB: images and aliases are taken down by this much
RESAMPLE_PASSBAND :: 0.92    // of the lower Nyquist frequency, flat; the transition ends at it
RESAMPLE_MAX_RATE :: 384000  // Hz: a source above it is refused
// Table steps per zero crossing of the sinc: its linear interpolation stays
// below the stopband.
RESAMPLE_STEPS :: 2048

// The interleaved frames of samples, at rate from, at rate to. The loop
// start moves with them, to the nearest frame. Empty for no frames; at least
// one frame for one or more.
resample :: proc(samples:[]f32,channels,from,to,loop_start:int,allocator:=context.allocator) -> (out:[]f32,moved_loop_start:int,error:audio.Error) {
    if channels<1 || channels>2 || len(samples)%channels!=0 || to<=0 || to>RESAMPLE_MAX_RATE || from<=0 || loop_start<0 {return nil,0,.Invalid_Desc}
    if from>RESAMPLE_MAX_RATE {return nil,0,.Unsupported_Format}
    frames:=len(samples)/channels
    if frames==0 {return nil,0,.None}
    count:=max(int(math.round(f64(frames)*f64(to)/f64(from))),1)
    loop:=min(int(math.round(f64(loop_start)*f64(to)/f64(from))),count-1)
    failed:runtime.Allocator_Error
    if out,failed=make([]f32,count*channels,allocator);failed!=nil {return nil,0,.Out_Of_Memory}
    // The cutoff, in cycles per source frame, between the end of the
    // passband and the lower Nyquist frequency.
    nyquist:=0.5*f64(min(from,to))/f64(from)
    cutoff:=nyquist*(1+RESAMPLE_PASSBAND)/2
    transition:=nyquist*(1-RESAMPLE_PASSBAND)
    beta:=0.1102*(f64(RESAMPLE_STOPBAND)-8.7)
    half:=int(math.ceil((f64(RESAMPLE_STOPBAND)-7.95)/(2.285*2*math.PI*transition)/2))+1 // source frames to each side
    steps:=max(int(math.ceil(f64(RESAMPLE_STEPS)*2*cutoff)),16) // per source frame
    table:[]f64
    if table,failed=make([]f64,half*steps+2,context.temp_allocator);failed!=nil {delete(out,allocator);return nil,0,.Out_Of_Memory}
    defer delete(table,context.temp_allocator)
    for &h,j in table {
        x:=f64(j)/f64(steps)
        r:=x/f64(half)
        if r>=1 {h=0;continue}
        sinc:=2*cutoff if x==0 else math.sin(2*math.PI*cutoff*x)/(math.PI*x)
        h=sinc*bessel_i0(beta*math.sqrt(1-r*r))/bessel_i0(beta)
    }
    for n in 0..<count {
        // Where output frame n is in the source: whole frames and a fraction, exact in integers.
        place:=u64(n)*u64(from)
        index:=int(place/u64(to))
        fraction:=f64(place%u64(to))/f64(to)
        sums:[2]f64
        for k in max(index-half+1,0)..=min(index+half,frames-1) {
            d:=abs(f64(index-k)+fraction)*f64(steps)
            j:=int(d)
            if j+1>=len(table) {continue}
            w:=table[j]+(table[j+1]-table[j])*(d-f64(j))
            for c in 0..<channels {sums[c]+=w*f64(samples[k*channels+c])}
        }
        for c in 0..<channels {out[n*channels+c]=f32(sums[c])}
    }
    return out,loop,.None
}

// The modified Bessel function of the first kind, order 0, by its series.
@(private="file")
bessel_i0 :: proc(x:f64) -> f64 {
    sum,term:=1.0,1.0
    for k in 1..<200 {
        term*=(x/(2*f64(k)))*(x/(2*f64(k)))
        sum+=term
        if term<sum*1e-17 {break}
    }
    return sum
}
