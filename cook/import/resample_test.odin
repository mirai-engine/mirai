package importer

import "core:math"
import "core:testing"
import audio "mirai:audio"

// The amplitude at frequency of channel 0 of samples at rate, through a Hann
// window, so that a sine of amplitude a gives a.
@(private="file")
amplitude :: proc(samples:[]f32,channels,rate:int,frequency:f64) -> f64 {
    n:=len(samples)/channels
    s,c,weights:f64
    for i in 0..<n {
        w:=0.5-0.5*math.cos(2*math.PI*f64(i)/f64(n-1))
        phase:=2*math.PI*frequency*f64(i)/f64(rate)
        s+=w*f64(samples[i*channels])*math.sin(phase)
        c+=w*f64(samples[i*channels])*math.cos(phase)
        weights+=w
    }
    return 2*math.sqrt(s*s+c*c)/weights
}
@(private="file")
db :: proc(x:f64) -> f64 {return 20*math.log10(max(x,1e-30))}

// A sweep to 20 kHz at 44.1 kHz brought to 48 kHz keeps its band and leaves
// no image between the Nyquist frequency of its source and that of the mixer.
@(test)
resampled_sweep_keeps_its_band_without_images :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    sweep:=make([]f32,44100,context.temp_allocator)
    for &x,i in sweep {
        time:=f64(i)/44100
        x=f32(0.5*math.sin(2*math.PI*(20*time+(20000-20)*time*time/2)))
    }
    out,_,error:=resample(sweep,1,44100,audio.MIXER_RATE,0,context.temp_allocator)
    testing.expect_value(t,error,audio.Error.None)
    testing.expect_value(t,len(out),48000)
    // The level of the sweep at a frequency of its band, and the loudest image above it.
    band:=amplitude(out,1,audio.MIXER_RATE,10000)
    reference:=amplitude(sweep,1,44100,10000)
    testing.expectf(t,abs(db(band/reference))<0.05,"the band moved by %v dB",db(band/reference))
    image:=f64(0)
    for f:=22200.0;f<24000;f+=50 {image=max(image,amplitude(out,1,audio.MIXER_RATE,f))}
    testing.expectf(t,db(image/band)<-(RESAMPLE_STOPBAND-10),"an image at %v dB under the band",db(image/band))
}

// Every rate it takes is brought to the mixer's, keeping the level of what is
// below both Nyquist frequencies and removing what is above the mixer's; what
// it cannot take is refused.
@(test)
resample_takes_any_rate_and_refuses_what_it_cannot :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    two_tones :: proc(rate:int,low,high:f64) -> []f32 {
        samples:=make([]f32,rate/4,context.temp_allocator)
        for &x,i in samples {x=f32(0.25*math.sin(2*math.PI*low*f64(i)/f64(rate))+0.25*math.sin(2*math.PI*high*f64(i)/f64(rate)))}
        return samples
    }
    // 8 kHz has nothing above 4 kHz to remove; at 192 kHz a 30 kHz tone would come back at 18 kHz.
    Case :: struct {rate:int,high,alias:f64}
    for c in ([?]Case{{8000,3000,0},{22050,10000,0},{192000,30000,18000}}) {
        source:=two_tones(c.rate,1000,c.high)
        out,_,error:=resample(source,1,c.rate,audio.MIXER_RATE,0,context.temp_allocator)
        testing.expect_value(t,error,audio.Error.None)
        testing.expect_value(t,len(out),int(math.round(f64(len(source))*f64(audio.MIXER_RATE)/f64(c.rate))))
        testing.expectf(t,abs(db(amplitude(out,1,audio.MIXER_RATE,1000)/0.25))<0.05,"%d Hz: 1 kHz at %v dB",c.rate,db(amplitude(out,1,audio.MIXER_RATE,1000)/0.25))
        if c.alias>0 {
            testing.expectf(t,db(amplitude(out,1,audio.MIXER_RATE,c.alias)/0.25)<-(RESAMPLE_STOPBAND-10),"%d Hz: an alias at %v dB",c.rate,db(amplitude(out,1,audio.MIXER_RATE,c.alias)/0.25))
        } else {
            testing.expectf(t,abs(db(amplitude(out,1,audio.MIXER_RATE,c.high)/0.25))<0.05,"%d Hz: %v Hz moved",c.rate,c.high)
        }
    }
    // The loop start moves with the rate; nothing gives nothing, one frame at least one.
    stereo:=make([]f32,44100*2,context.temp_allocator)
    out,loop,error:=resample(stereo,2,44100,48000,22050,context.temp_allocator)
    testing.expect(t,error==.None && len(out)==48000*2 && loop==24000)
    out,loop,error=resample(nil,1,44100,48000,0,context.temp_allocator)
    testing.expect(t,error==.None && len(out)==0)
    out,loop,error=resample({0.5},1,192000,48000,0,context.temp_allocator)
    testing.expect(t,error==.None && len(out)==1 && abs(out[0])<=0.5)
    // Rates of 0 or below, more than two channels, frames cut in a channel, a rate above the most.
    Bad :: struct {samples:[]f32,channels,from,to,loop_start:int,error:audio.Error}
    for c in ([?]Bad{
        {stereo,2,0,48000,0,.Invalid_Desc},
        {stereo,2,-44100,48000,0,.Invalid_Desc},
        {stereo,2,44100,0,0,.Invalid_Desc},
        {stereo,3,44100,48000,0,.Invalid_Desc},
        {stereo[:3],2,44100,48000,0,.Invalid_Desc},
        {stereo,2,44100,48000,-1,.Invalid_Desc},
        {stereo,2,RESAMPLE_MAX_RATE+1,48000,0,.Unsupported_Format},
    }) {
        _,_,error=resample(c.samples,c.channels,c.from,c.to,c.loop_start,context.temp_allocator)
        testing.expect_value(t,error,c.error)
    }
}
