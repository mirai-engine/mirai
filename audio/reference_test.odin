package mirai_audio

import "core:fmt"
import "core:math"
import "core:testing"

@(private="file") REFERENCE_OGG :: #load("testdata/sine_mono.ogg") // 0.5 s at 44.1 kHz, mono: resampled as it plays

// A storm of voices of one loaded sound, all started on one tick, mixes as
// the plain whole decode of its file summed at the sample each was
// scheduled for, resampled by a cubic Hermite written apart here and taken by
// constant power gains: Ogg Vorbis within its rounding to 16 bits, lossless
// exactly. The mixer decodes before every render, as a recording does.
@(test)
a_storm_of_voices_mixes_as_the_whole_decode_summed_at_their_samples :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    VOICES :: 32
    FRAMES :: 30000
    LEAD :: 256
    VOLUME :: f32(0.03)
    samples:=make([]i16,9000,context.temp_allocator)
    for &sample,i in samples {sample=i16(12000*math.sin(f32(i)*0.07+0.5)*f32(9000-i)/9000)}
    lossless,_:=lossless_encode(samples,1,MIXER_RATE,context.temp_allocator)
    Case :: struct {what:string,file:[]u8,tolerance:f32}
    for c in ([?]Case{{"Ogg Vorbis",REFERENCE_OGG,VOICES*VOLUME*(0.5/32768)+1e-6},{"lossless",lossless,1e-6}}) {
        m,_:=mixer_create({voice_capacity=VOICES,decoder_thread=true})
        sound,error:=sound_load(m,c.file)
        testing.expect_value(t,error,Error.None)
        start:=mixer_clock(m)+LEAD
        mixer_batch_begin(m)
        for _ in 0..<VOICES {
            desc:=VOICE_DEFAULT
            desc.volume=VOLUME
            desc.start_frame=start
            voice_play(m,sound,desc)
        }
        mixer_batch_end(m)
        got:=make([]f32,FRAMES*2,context.temp_allocator)
        for at:=0;at<FRAMES;at+=480 {
            mixer_decode(m)
            mixer_render(m,got[at*2:][:min(480,FRAMES-at)*2])
            mixer_update(m)
        }
        mixer_destroy(m)
        // The reference: whole decode, Catmull-Rom between the frame before and the two after, silence outside.
        pcm,_:=decode(c.file,context.temp_allocator)
        step:=u64(f64(pcm.sample_rate)/f64(MIXER_RATE)*f64(u64(1)<<32))
        source :: proc(pcm:Pcm,i:i64) -> f32 {return pcm.samples[i] if i>=0 && i<i64(len(pcm.samples)) else 0}
        gain:=VOLUME*f32(math.cos(math.PI/4))*VOICES
        worst:=f32(0)
        first:=-1
        rounded_worst,worst_at:=f32(0),0
        rounded:=make([]f32,len(pcm.samples),context.temp_allocator)
        for x,i in pcm.samples {
            // To the nearest of 16 bits, half away from zero.
            scaled:=clamp(x,-1,1)*32768
            rounded[i]=f32(i16(clamp(scaled+(scaled<0?-0.5:0.5),-32768,32767)))/32768
        }
        for frame in 0..<FRAMES {
            want:=f32(0)
            // A voice ends once it passes its last frame.
            if frame>=LEAD && i64((u64(frame-LEAD)*step)>>32)<i64(len(pcm.samples)) {
                p:=u64(frame-LEAD)*step
                i:=i64(p>>32)
                mu:=f32(u32(p))/4294967296.0
                a,b,cc,d:=source(pcm,i-1),source(pcm,i),source(pcm,i+1),source(pcm,i+2)
                want=gain*0.5*(2*b+(cc-a)*mu+(2*a-5*b+4*cc-d)*mu*mu+(3*(b-cc)+d-a)*mu*mu*mu)
            }
            if abs(got[frame*2]-want)>worst {worst_at=frame}
            for channel in 0..<2 {worst=max(worst,abs(got[frame*2+channel]-want))}
            if frame>=LEAD && i64((u64(frame-LEAD)*step)>>32)<i64(len(pcm.samples)) {
                p:=u64(frame-LEAD)*step
                i:=i64(p>>32)
                mu:=f32(u32(p))/4294967296.0
                r :: proc(s:[]f32,i:i64) -> f32 {return s[i] if i>=0 && i<i64(len(s)) else 0}
                a,b,cc,d:=r(rounded,i-1),r(rounded,i),r(rounded,i+1),r(rounded,i+2)
                rw:=gain*0.5*(2*b+(cc-a)*mu+(2*a-5*b+4*cc-d)*mu*mu+(3*(b-cc)+d-a)*mu*mu*mu)
                rounded_worst=max(rounded_worst,abs(got[frame*2]-rw))
            }
            if first<0 && got[frame*2]!=0 {first=frame}
        }
        fmt.printfln("%s: against the rounded decode %v; worst at frame %d",c.what,rounded_worst,worst_at)
        fmt.printfln("%s: %d voices against the whole decode summed at frame %d: largest difference %v, first sound at frame %d",c.what,VOICES,LEAD,worst,first)
        testing.expectf(t,worst<=c.tolerance && first==LEAD,"%s: largest difference %v (at most %v), first sound at frame %d",c.what,worst,c.tolerance,first)
    }
}
