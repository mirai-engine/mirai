package mirai_audio

import "base:runtime"
import "core:math"
import "core:testing"

RATE :: 48000

@(private)
test_mixer :: proc(t:^testing.T,desc:Mixer_Desc={}) -> ^Mixer {
    desc:=desc
    if desc.sample_rate==0 {desc.sample_rate=RATE}
    m,error:=mixer_create(desc)
    testing.expect_value(t,error,Error.None)
    return m
}
// Renders frames of the mixer's channel count into temporary memory.
@(private)
test_render :: proc(m:^Mixer,frames:int) -> []f32 {
    out:=make([]f32,frames*m.channels,context.temp_allocator)
    for &sample in out {sample=123} // render replaces what the buffer held
    mixer_render(m,out)
    return out
}
// A stereo sound whose left channel is value(i) and its right channel the opposite.
@(private)
test_stereo :: proc(t:^testing.T,m:^Mixer,frames:int,value:proc(i:int) -> f32,rate:=RATE) -> Sound {
    samples:=make([]f32,frames*2,context.temp_allocator)
    for i in 0..<frames {samples[i*2]=value(i);samples[i*2+1]=-value(i)}
    sound,error:=sound_create(m,samples,2,rate)
    testing.expect_value(t,error,Error.None)
    return sound
}
@(private)
test_mono :: proc(t:^testing.T,m:^Mixer,frames:int,value:proc(i:int) -> f32,rate:=RATE) -> Sound {
    samples:=make([]f32,frames,context.temp_allocator)
    for i in 0..<frames {samples[i]=value(i)}
    sound,error:=sound_create(m,samples,1,rate)
    testing.expect_value(t,error,Error.None)
    return sound
}
@(private) test_one :: proc(i:int) -> f32 {return 1}
@(private) test_ramp :: proc(i:int) -> f32 {return f32(i+1)/(1<<17)} // under full scale, exact
@(private) test_small :: proc(i:int) -> f32 {return f32(i%7)*0.125-0.25}
@(private)
test_near :: proc(t:^testing.T,got,want:f32,tolerance:f32=1e-5,loc:=#caller_location) -> bool {
    if abs(got-want)<=tolerance {return true}
    testing.expectf(t,false,"got %v, want %v (tolerance %v)",got,want,tolerance,loc=loc)
    return false
}
// An allocator that gives nothing and counts who asked.
@(private)
test_no_allocator :: proc(count:^int) -> runtime.Allocator {
    refuse :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {(cast(^int)data)^+=1}
        return nil,.Out_Of_Memory
    }
    return {refuse,count}
}

@(test)
mixer_rejects_a_desc_it_cannot_serve :: proc(t:^testing.T) {
    m,error:=mixer_create({channels=6})
    testing.expect(t,m==nil && error==.Invalid_Desc)
    m,error=mixer_create({sample_rate=-1})
    testing.expect(t,m==nil && error==.Invalid_Desc)
    m,error=mixer_create({voice_capacity=-4})
    testing.expect(t,m==nil && error==.Invalid_Desc)
    m,error=mixer_create({output=Output_Kind(9)})
    testing.expect(t,m==nil && error==.Invalid_Desc)
    for desc in ([?]Mixer_Desc{{feed_capacity=max(int)},{feed_frames=max(int)},{stream_frames=max(int)},{voice_capacity=max(int)},{command_capacity=max(int)},{feed_frames=-1}}) {
        m,error=mixer_create(desc)
        testing.expect(t,m==nil && error==.Invalid_Desc)
    }
    m,error=mixer_create({})
    testing.expect(t,m!=nil && error==.None)
    defer mixer_destroy(m)
    testing.expect_value(t,m.sample_rate,48000)
    testing.expect_value(t,m.channels,2)
    testing.expect_value(t,len(m.voices),64)
    testing.expect_value(t,len(m.commands.items),1024)
    mixer_destroy(nil)
}

@(test)
silence_is_rendered_when_nothing_plays :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    out:=test_render(m,700)
    for sample in out {testing.expect_value(t,sample,f32(0))}
    testing.expect_value(t,mixer_clock(m),u64(700))
    testing.expect_value(t,mixer_stats(m).frames_rendered,u64(700))
    testing.expect_value(t,mixer_stats(m).voices_active,0)
    // Nothing to render is not an error.
    mixer_render(m,nil)
    testing.expect_value(t,mixer_clock(m),u64(700))
}

@(test)
sixteen_bit_frames_play_as_their_fraction_of_full_scale :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    sound,error:=sound_create_pcm16(m,{16384,-32768,0,-16384},2,RATE)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,sound_frames(m,sound),2)
    _,odd:=sound_create_pcm16(m,{1,2,3},2,RATE)
    testing.expect_value(t,odd,Error.Invalid_Desc)
    desc:=VOICE_DEFAULT
    desc.pan=0
    testing.expect(t,voice_play(m,sound,desc)!=0)
    out:=test_render(m,2)
    // A stereo sound at the center keeps its channels as they are.
    test_near(t,out[0],0.5);test_near(t,out[1],-1);test_near(t,out[2],0);test_near(t,out[3],-0.5)
}

@(test)
voices_are_summed_sample_by_sample :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    a:=test_stereo(t,m,600,test_ramp)
    b:=test_stereo(t,m,300,test_small)
    testing.expect(t,voice_play(m,a)!=0)
    testing.expect(t,voice_play(m,b)!=0)
    out:=test_render(m,700)
    for i in 0..<700 {
        want:=f32(0)
        if i<600 {want+=test_ramp(i)}
        if i<300 {want+=test_small(i)}
        if !test_near(t,out[i*2],want,0) || !test_near(t,out[i*2+1],-want,0) {break}
    }
    testing.expect_value(t,mixer_stats(m).voices_active,0)
    testing.expect_value(t,mixer_stats(m).voices_played,u64(2))
}

@(test)
render_does_not_depend_on_how_the_frames_are_asked_for :: proc(t:^testing.T) {
    whole,pieces:[]f32
    for pass in 0..<2 {
        m:=test_mixer(t)
        defer mixer_destroy(m)
        desc:=VOICE_DEFAULT
        desc.pitch=1.37;desc.loop=true;desc.pan=0.3
        voice_play(m,test_mono(t,m,157,test_small,44100),desc)
        voice_play(m,test_stereo(t,m,400,test_ramp))
        if pass==0 {whole=test_render(m,1500);continue}
        pieces=make([]f32,3000,context.temp_allocator)
        sizes:=[?]int{1,37,256,255,300,7,644}
        done:=0
        for size in sizes {
            mixer_render(m,pieces[done*2:][:size*2])
            done+=size
        }
        testing.expect_value(t,done,1500)
    }
    for i in 0..<3000 {
        if !test_near(t,pieces[i],whole[i],0) {break}
    }
}

@(test)
mono_voice_follows_the_constant_power_pan_law :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    sound:=test_mono(t,m,64,test_one)
    Case :: struct {pan,volume,left,right:f32}
    half:=f32(math.SQRT_TWO/2)
    cases:=[?]Case{
        {0,1,half,half},
        {-1,1,1,0},
        {1,1,0,1},
        {0.5,1,math.cos_f32(3*math.PI/8),math.sin_f32(3*math.PI/8)},
        {0,0.5,half*0.5,half*0.5},
        {-1,0.75,0.75,0},
        {-7,1,1,0}, // clamped
    }
    for c in cases {
        desc:=VOICE_DEFAULT
        desc.pan=c.pan;desc.volume=c.volume
        testing.expect(t,voice_play(m,sound,desc)!=0)
        out:=test_render(m,64)
        for i in 0..<64 {
            if !test_near(t,out[i*2],c.left,1e-6) || !test_near(t,out[i*2+1],c.right,1e-6) {break}
        }
        // Energy does not depend on where the sound is.
        test_near(t,out[0]*out[0]+out[1]*out[1],c.volume*c.volume,1e-5)
        mixer_update(m)
    }
    testing.expect_value(t,pan_gains(0),[2]f32{half,half})
}

@(test)
stereo_voice_is_balanced_instead_of_panned :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    sound:=test_stereo(t,m,32,test_one)
    Case :: struct {pan,left,right:f32}
    cases:=[?]Case{{0,1,-1},{-1,1,0},{1,0,-1},{0.5,0.5,-1},{-0.25,1,-0.75}}
    for c in cases {
        desc:=VOICE_DEFAULT
        desc.pan=c.pan
        voice_play(m,sound,desc)
        out:=test_render(m,32)
        for i in 0..<32 {
            if !test_near(t,out[i*2],c.left,1e-6) || !test_near(t,out[i*2+1],c.right,1e-6) {break}
        }
        mixer_update(m)
    }
    testing.expect_value(t,balance_gains(0.5),[2]f32{0.5,1})
}

@(test)
mono_output_plays_a_centered_sound_at_its_level :: proc(t:^testing.T) {
    m:=test_mixer(t,{channels=1})
    defer mixer_destroy(m)
    voice_play(m,test_mono(t,m,100,test_small))
    out:=test_render(m,120)
    testing.expect_value(t,len(out),120)
    for i in 0..<120 {
        if !test_near(t,out[i],test_small(i) if i<100 else 0,1e-6) {break}
    }
}

@(test)
volume_change_is_ramped_across_one_chunk :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    desc:=VOICE_DEFAULT
    desc.loop=true
    voice:=voice_play(m,test_stereo(t,m,64,test_one),desc)
    test_render(m,CHUNK_FRAMES)
    testing.expect(t,voice_set_volume(m,voice,0.25))
    out:=test_render(m,CHUNK_FRAMES*2)
    // A straight line from the old volume to the new one, then the new one.
    for i in 0..<CHUNK_FRAMES {
        if !test_near(t,out[i*2],1-0.75*f32(i)/CHUNK_FRAMES,1e-5) {break}
    }
    for i in CHUNK_FRAMES..<CHUNK_FRAMES*2 {
        if !test_near(t,out[i*2],0.25,1e-6) {break}
    }
    // The same for the pan of a mono sound.
    mono:=voice_play(m,test_mono(t,m,64,test_one),desc)
    voice_stop(m,voice)
    test_render(m,CHUNK_FRAMES)
    voice_set_pan(m,mono,-1)
    out=test_render(m,CHUNK_FRAMES*2)
    previous:=out[0]
    for i in 1..<CHUNK_FRAMES {
        testing.expect(t,out[i*2]>previous && out[i*2+1]<out[(i-1)*2+1])
        previous=out[i*2]
    }
    test_near(t,out[CHUNK_FRAMES*2],1,1e-6)
    test_near(t,out[CHUNK_FRAMES*2+1],0,1e-6)
}

@(private="file")
sine_440 :: proc(i:int) -> f32 {return math.sin_f32(2*math.PI*440*f32(i)/44100)}

@(test)
resampled_sine_matches_the_sine_at_the_new_rate :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    // One second of 440 Hz recorded at 44.1 kHz, played by a 48 kHz mixer.
    sound:=test_stereo(t,m,44100,sine_440,44100)
    Case :: struct {pitch,frequency:f32}
    cases:=[?]Case{{1,440},{2,880},{0.5,220},{1.5,660}}
    for c in cases {
        desc:=VOICE_DEFAULT
        desc.pitch=c.pitch
        voice:=voice_play(m,sound,desc)
        out:=test_render(m,4000)
        worst:=f32(0)
        for i in 0..<4000 {
            want:=f32(math.sin(2*math.PI*f64(c.frequency)*f64(i)/RATE))
            worst=max(worst,abs(out[i*2]-want),abs(out[i*2+1]+want))
        }
        // Linear interpolation of a sine is off by (w*w)/8 at most, w being the phase step between source frames.
        w:=2*math.PI*f32(440)/44100
        testing.expectf(t,worst<w*w/8+2e-4,"pitch %v: off by %v",c.pitch,worst)
        voice_stop(m,voice)
        test_render(m,CHUNK_FRAMES)
        mixer_update(m)
    }
}

@(test)
pitch_is_clamped_and_zero_means_as_recorded :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    sound:=test_stereo(t,m,100000,test_ramp)
    desc:=VOICE_DEFAULT
    desc.pitch=0
    voice:=voice_play(m,sound,desc)
    out:=test_render(m,8)
    for i in 0..<8 {test_near(t,out[i*2],test_ramp(i),0)}
    voice_set_pitch(m,voice,1000)
    out=test_render(m,4)
    // From frame 8 on, PITCH_MAX source frames per output frame.
    for i in 0..<4 {test_near(t,out[i*2],test_ramp(8+i*int(PITCH_MAX)),0)}
    voice_set_pitch(m,voice,-3)
    out=test_render(m,2)
    test_near(t,out[2]-out[0],test_ramp(1)-test_ramp(0),0)
}

@(test)
loop_seam_has_no_gap_and_no_repeated_frame :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    desc:=VOICE_DEFAULT
    desc.loop=true
    sound:=test_stereo(t,m,100,test_ramp)
    voice:=voice_play(m,sound,desc)
    out:=test_render(m,1000)
    for i in 0..<1000 {
        if !test_near(t,out[i*2],test_ramp(i%100),0) {break}
    }
    voice_stop(m,voice)
    test_render(m,CHUNK_FRAMES)
    mixer_update(m)
    // At half speed every other output frame lies between two source frames;
    // the one after the last source frame lies between it and the first.
    desc.pitch=0.5
    voice=voice_play(m,sound,desc)
    out=test_render(m,600)
    for i in 0..<600 {
        a:=test_ramp((i/2)%100)
        b:=test_ramp((i/2+1)%100)
        want:=a if i%2==0 else (a+b)*0.5
        if !test_near(t,out[i*2],want,1e-4) {break}
    }
    test_near(t,out[199*2],(test_ramp(99)+test_ramp(0))*0.5,1e-4)
    // Told to stop looping, it plays to the end of the sound and ends there.
    voice_set_loop(m,voice,false)
    out=test_render(m,600)
    testing.expect(t,out[0]!=0)
    testing.expect_value(t,out[599*2],f32(0))
    mixer_update(m)
    testing.expect(t,!voice_valid(m,voice))
}

@(test)
sound_that_ends_is_followed_by_silence_and_its_voice_dies :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    voice:=voice_play(m,test_stereo(t,m,300,test_ramp))
    testing.expect(t,voice_valid(m,voice))
    out:=test_render(m,256)
    test_near(t,out[255*2],test_ramp(255),0)
    mixer_update(m)
    testing.expect(t,voice_valid(m,voice))
    out=test_render(m,256)
    test_near(t,out[43*2],test_ramp(299),0)
    test_near(t,out[44*2],0,0)
    // The handle is valid until an update has seen the end.
    testing.expect(t,voice_valid(m,voice))
    mixer_update(m)
    testing.expect(t,!voice_valid(m,voice))
    testing.expect(t,!voice_stop(m,voice) && !voice_set_volume(m,voice,1) && !voice_set_paused(m,voice,true))
    testing.expect(t,!voice_valid(m,0) && !voice_valid(m,Voice(0xffff_ffff_ffff)))
    // A sound that ends exactly with a chunk ends in that chunk.
    exact:=voice_play(m,test_stereo(t,m,CHUNK_FRAMES,test_one))
    test_render(m,CHUNK_FRAMES)
    mixer_update(m)
    testing.expect(t,!voice_valid(m,exact))
    testing.expect_value(t,mixer_stats(m).voices_active,0)
}

@(test)
fade_envelopes_are_linear_to_the_sample :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    desc:=VOICE_DEFAULT
    desc.loop=true
    desc.fade_in=400.0/RATE
    voice:=voice_play(m,test_stereo(t,m,64,test_one),desc)
    out:=test_render(m,600)
    for i in 0..<600 {
        if !test_near(t,out[i*2],min(f32(i)/400,1),2e-6) {break}
    }
    // From 1 down to a quarter in 300 frames, starting in the middle of nowhere.
    testing.expect(t,voice_fade(m,voice,0.25,300.0/RATE))
    out=test_render(m,500)
    for i in 0..<500 {
        if !test_near(t,out[i*2],max(1-0.75*f32(i)/300,0.25),2e-6) {break}
    }
    // A fade of no length is a jump.
    voice_fade(m,voice,0.5,0)
    out=test_render(m,10)
    test_near(t,out[0],0.5,0)
    // Stopping with a fade goes from the current level to silence, then the voice ends.
    testing.expect(t,voice_stop(m,voice,200.0/RATE))
    // Another fade cannot keep it alive.
    voice_fade(m,voice,1,0)
    out=test_render(m,400)
    for i in 0..<400 {
        if !test_near(t,out[i*2],max(0.5-0.5*f32(i)/200,0),2e-6) {break}
    }
    testing.expect(t,voice_valid(m,voice))
    mixer_update(m)
    testing.expect(t,!voice_valid(m,voice))
}

@(test)
stop_without_a_fade_ramps_to_silence_within_the_chunk :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    desc:=VOICE_DEFAULT
    desc.loop=true
    voice:=voice_play(m,test_stereo(t,m,64,test_one),desc)
    test_render(m,100)
    testing.expect(t,voice_stop(m,voice))
    out:=test_render(m,300)
    for i in 0..<CHUNK_FRAMES {
        if !test_near(t,out[i*2],1-f32(i)/CHUNK_FRAMES,1e-5) {break}
    }
    for i in CHUNK_FRAMES..<300 {testing.expect_value(t,out[i*2],f32(0))}
    mixer_update(m)
    testing.expect(t,!voice_valid(m,voice))
}

@(test)
voice_starts_on_the_frame_it_was_scheduled_for :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    test_render(m,1000)
    desc:=VOICE_DEFAULT
    desc.start_frame=mixer_clock(m)+300
    voice:=voice_play(m,test_stereo(t,m,500,test_ramp),desc)
    // Rendered in pieces that do not line up with the start.
    out:=make([]f32,1000*2,context.temp_allocator)
    for done:=0;done<1000;done+=125 {mixer_render(m,out[done*2:][:250])}
    for i in 0..<1000 {
        want:=f32(0)
        if i>=300 && i<800 {want=test_ramp(i-300)}
        if !test_near(t,out[i*2],want,0) {break}
    }
    mixer_update(m)
    testing.expect(t,!voice_valid(m,voice))
    // A start in the past is a start now; an offset skips into the sound.
    desc.start_frame=5
    desc.offset=100.0/RATE
    voice_play(m,test_stereo(t,m,500,test_ramp),desc)
    out=test_render(m,4)
    test_near(t,out[0],test_ramp(100),0)
    // A voice stopped before its start never sounds.
    desc.start_frame=mixer_clock(m)+50
    desc.offset=0
    later:=voice_play(m,test_stereo(t,m,500,test_one),desc)
    test_render(m,10)
    voice_stop(m,later)
    test_render(m,10)
    mixer_update(m)
    testing.expect(t,!voice_valid(m,later))
}

@(test)
pause_keeps_the_place_and_resume_goes_on_from_it :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    voice:=voice_play(m,test_stereo(t,m,100000,test_one))
    ramp:=voice_play(m,test_stereo(t,m,100000,test_ramp))
    voice_set_volume(m,ramp,0)
    test_render(m,CHUNK_FRAMES)
    testing.expect(t,voice_set_paused(m,voice,true))
    out:=test_render(m,CHUNK_FRAMES*2)
    // It goes quiet over the chunk instead of being cut.
    test_near(t,out[0],1,1e-6)
    test_near(t,out[(CHUNK_FRAMES/2)*2],0.5,1e-5)
    for i in CHUNK_FRAMES..<CHUNK_FRAMES*2 {testing.expect_value(t,out[i*2],f32(0))}
    mixer_update(m)
    testing.expect(t,voice_valid(m,voice))
    testing.expect_value(t,mixer_stats(m).voices_active,2)
    testing.expect(t,voice_set_paused(m,voice,false))
    out=test_render(m,CHUNK_FRAMES*2)
    test_near(t,out[0],0,1e-6)
    test_near(t,out[CHUNK_FRAMES*2],1,1e-6)

    // The position: a voice created paused plays its first frame when resumed.
    desc:=VOICE_DEFAULT
    desc.paused=true
    held:=voice_play(m,test_stereo(t,m,1000,test_ramp),desc)
    voice_stop(m,voice);voice_stop(m,ramp)
    out=test_render(m,CHUNK_FRAMES*2)
    testing.expect_value(t,out[CHUNK_FRAMES*2+2],f32(0))
    voice_set_paused(m,held,false)
    out=test_render(m,CHUNK_FRAMES)
    // Ramped in over the chunk: by its end the sound is at its level, 256 frames in.
    test_near(t,out[(CHUNK_FRAMES-1)*2],test_ramp(CHUNK_FRAMES-1)*f32(CHUNK_FRAMES-1)/CHUNK_FRAMES,test_ramp(0)/100)
    voice_set_paused(m,held,true)
    test_render(m,CHUNK_FRAMES*3)
    voice_set_paused(m,held,false)
    out=test_render(m,CHUNK_FRAMES*2)
    // One chunk played while pausing, none while paused.
    test_near(t,out[CHUNK_FRAMES*2],test_ramp(CHUNK_FRAMES*3),0)
    // A paused voice is stopped at once.
    voice_set_paused(m,held,true)
    test_render(m,CHUNK_FRAMES)
    voice_stop(m,held,1)
    test_render(m,1)
    mixer_update(m)
    testing.expect(t,!voice_valid(m,held))
}

@(test)
oldest_voice_of_the_lowest_priority_is_stolen :: proc(t:^testing.T) {
    m:=test_mixer(t,{voice_capacity=3})
    defer mixer_destroy(m)
    desc:=VOICE_DEFAULT
    desc.loop=true
    // Volumes that tell the voices apart in their sum, under full scale.
    unit:=f32(1.0/32768)
    one:=test_stereo(t,m,64,test_one)
    desc.volume=unit;desc.priority=5
    important:=voice_play(m,one,desc)
    desc.volume=10*unit;desc.priority=1
    old:=voice_play(m,one,desc)
    desc.volume=100*unit
    young:=voice_play(m,one,desc)
    out:=test_render(m,CHUNK_FRAMES)
    test_near(t,out[0],111*unit,1e-4*unit)
    // No voice is free: the new one takes the place of the oldest of priority 1.
    desc.volume=1000*unit;desc.priority=1
    newest:=voice_play(m,one,desc)
    testing.expect(t,newest!=0 && newest!=old)
    testing.expect(t,!voice_valid(m,old))
    testing.expect(t,voice_valid(m,important) && voice_valid(m,young) && voice_valid(m,newest))
    testing.expect_value(t,mixer_stats(m).voices_stolen,u64(1))
    // The stolen sound leaves over one chunk while the new one is already there.
    out=test_render(m,CHUNK_FRAMES*2)
    test_near(t,out[0],1111*unit,1e-3*unit)
    test_near(t,out[(CHUNK_FRAMES/2)*2],1106*unit,1e-2*unit)
    test_near(t,out[CHUNK_FRAMES*2],1101*unit,1e-3*unit)
    testing.expect_value(t,mixer_stats(m).voices_active,3)
    // The old handle does nothing to the voice that took its slot.
    testing.expect(t,!voice_stop(m,old))
    // Nothing of lower or equal priority to steal: the new voice is not played.
    desc.priority=0
    testing.expect_value(t,voice_play(m,one,desc),Voice(0))
    testing.expect_value(t,mixer_stats(m).voices_rejected,u64(1))
    // A higher priority steals from the lowest there is.
    desc.priority=9;desc.volume=10000*unit
    top:=voice_play(m,one,desc)
    testing.expect(t,top!=0 && !voice_valid(m,young) && voice_valid(m,newest) && voice_valid(m,important))
    // Stolen twice before a single chunk: only the last one plays there.
    desc.priority=9;desc.volume=20000*unit
    again:=voice_play(m,one,desc)
    testing.expect(t,again!=0 && !voice_valid(m,newest))
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[0],30001*unit,1e-2*unit)
    // Ended voices free their slots: nothing is stolen for the next one.
    voice_stop(m,top);voice_stop(m,again);voice_stop(m,important)
    test_render(m,CHUNK_FRAMES)
    mixer_update(m)
    stolen:=mixer_stats(m).voices_stolen
    testing.expect(t,voice_play(m,one,desc)!=0)
    testing.expect_value(t,mixer_stats(m).voices_stolen,stolen)
}

@(test)
full_command_queue_refuses_instead_of_blocking :: proc(t:^testing.T) {
    m:=test_mixer(t,{command_capacity=4})
    defer mixer_destroy(m)
    sound:=test_stereo(t,m,64,proc(i:int) -> f32 {return 0.25})
    voices:[4]Voice
    for &voice in voices {
        voice=voice_play(m,sound)
        testing.expect(t,voice!=0)
    }
    // The audio thread has not run: the queue is full.
    testing.expect_value(t,voice_play(m,sound),Voice(0))
    testing.expect(t,!voice_set_volume(m,voices[0],0.5))
    testing.expect(t,!bus_set_volume(m,BUS_MASTER,0.5))
    testing.expect(t,!listener_set(m,{},1))
    testing.expect_value(t,mixer_stats(m).commands_dropped,u64(4))
    testing.expect_value(t,bus_volume(m,BUS_MASTER),f32(1))
    out:=test_render(m,1)
    test_near(t,out[0],1,0)
    // The slot of the voice that was not played is still free.
    testing.expect(t,voice_play(m,sound)!=0)
    testing.expect(t,voice_set_volume(m,voices[0],0.5))
}

@(test)
destroyed_sound_ends_its_voices_and_is_freed_by_an_update :: proc(t:^testing.T) {
    m:=test_mixer(t,{sound_capacity=2,voice_capacity=2})
    defer mixer_destroy(m)
    desc:=VOICE_DEFAULT
    desc.loop=true
    doomed:=test_stereo(t,m,64,proc(i:int) -> f32 {return 0.5})
    kept:=test_stereo(t,m,64,test_ramp)
    testing.expect_value(t,mixer_stats(m).sounds,2)
    _,full:=sound_create(m,{0,0},2,RATE)
    testing.expect_value(t,full,Error.Capacity_Exhausted)
    a:=voice_play(m,doomed,desc)
    b:=voice_play(m,kept,desc)
    test_render(m,10)
    sound_destroy(m,doomed)
    // The handle is dead at once; the memory waits for the audio thread.
    testing.expect(t,!sound_valid(m,doomed) && sound_valid(m,kept))
    testing.expect_value(t,voice_play(m,doomed),Voice(0))
    mixer_update(m)
    testing.expect_value(t,mixer_stats(m).sounds,2)
    out:=test_render(m,4)
    test_near(t,out[0],test_ramp(10),0)
    mixer_update(m)
    testing.expect_value(t,mixer_stats(m).sounds,1)
    testing.expect(t,!voice_valid(m,a) && voice_valid(m,b))
    // Its slot is free for another sound, under a new handle.
    replacement,error:=sound_create(m,{0.5,0.5},2,RATE)
    testing.expect(t,error==.None && replacement!=doomed && sound_valid(m,replacement))
    sound_destroy(m,doomed)
    sound_destroy(m,0)
    testing.expect(t,sound_valid(m,replacement))
    // A sound destroyed while a voice waits to steal a slot with it: that
    // voice never sounds, and the one it replaced leaves all the same.
    d:=voice_play(m,kept,desc)
    c:=voice_play(m,replacement,desc)
    testing.expect(t,c!=0 && d!=0 && !voice_valid(m,b) && voice_valid(m,d))
    sound_destroy(m,replacement)
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[0],test_ramp(CHUNK_FRAMES%64),0)
    mixer_update(m)
    testing.expect(t,!voice_valid(m,c) && voice_valid(m,d))
    testing.expect_value(t,mixer_stats(m).sounds,1)
    testing.expect_value(t,mixer_stats(m).voices_active,1)
}

@(test)
sounds_report_what_they_hold :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    sound,error:=sound_create(m,make([]f32,24000,context.temp_allocator),2,24000)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,sound_frames(m,sound),12000)
    testing.expect_value(t,sound_channels(m,sound),2)
    testing.expect_value(t,sound_sample_rate(m,sound),24000)
    testing.expect_value(t,sound_seconds(m,sound),f32(0.5))
    testing.expect(t,sound_frames(m,0)==0 && sound_channels(m,0)==0 && sound_sample_rate(m,0)==0 && sound_seconds(m,0)==0)
    _,error=sound_create(m,{1,2,3},2,RATE)
    testing.expect_value(t,error,Error.Invalid_Desc)
    _,error=sound_create(m,{1,2,3},3,RATE)
    testing.expect_value(t,error,Error.Invalid_Desc)
    _,error=sound_create(m,{1,2},1,0)
    testing.expect_value(t,error,Error.Invalid_Desc)
    // An empty sound ends as soon as it plays.
    empty,empty_error:=sound_create(m,nil,1,RATE)
    testing.expect_value(t,empty_error,Error.None)
    voice:=voice_play(m,empty)
    test_render(m,1)
    mixer_update(m)
    testing.expect(t,voice!=0 && !voice_valid(m,voice))
    desc:=VOICE_DEFAULT
    desc.bus=Bus(3)
    testing.expect_value(t,voice_play(m,sound,desc),Voice(0))
}

@(test)
steady_playback_allocates_nothing :: proc(t:^testing.T) {
    m:=test_mixer(t,{voice_capacity=8})
    defer mixer_destroy(m)
    sounds:=[2]Sound{test_mono(t,m,300,test_small,44100),test_stereo(t,m,500,test_small)}
    bus,_:=bus_create(m)
    sent,_:=bus_create(m)
    out:=make([]f32,480*2)
    defer delete(out)
    count:=0
    {
        context.allocator=test_no_allocator(&count)
        context.temp_allocator=test_no_allocator(&count)
        for frame in 0..<200 {
            desc:=VOICE_DEFAULT
            desc.bus=([3]Bus{bus,BUS_MASTER,sent})[frame%3]
            desc.volume=4 // the limiter holds them
            desc.spatial=frame%3==0;desc.position={f32(frame%7)-3,0,-2};desc.doppler=1
            desc.loop=frame%5==0;desc.pitch=0.5+f32(frame%4)*0.4;desc.fade_in=0.01
            voice:=voice_play(m,sounds[frame%2],desc)
            voice_set_volume(m,voice,0.8)
            voice_set_position(m,voice,{1,0,f32(frame%5)},{0,0,3})
            voice_set_occlusion(m,voice,f32(frame%3)*0.5,TRANSMISSION_DEFAULT)
            if frame%50==0 {mixer_set_output(m,.Speakers if frame%100==0 else .Headphones)}
            if frame%4==0 {voice_stop(m,voice,0.02)}
            listener_set(m,{f32(frame%3),0,0},1,{1,0,0})
            bus_set_volume(m,bus,0.5+f32(frame%2)*0.5)
            bus_set_lowpass(m,bus,2000 if frame%10<5 else 0)
            bus_set_duck(m,bus,{source=BUS_MASTER,threshold=0.1,amount=0.5,attack=0.01,release=0.1})
            bus_set_send(m,sent,bus if frame%7<3 else BUS_MASTER)
            mixer_render(m,out)
            mixer_update(m)
            _=mixer_stats(m)
        }
    }
    testing.expect_value(t,count,0)
    testing.expect(t,mixer_stats(m).voices_played>=200-mixer_stats(m).voices_rejected)
    testing.expect_value(t,mixer_stats(m).commands_dropped,u64(0))
}

// Gives memory from the allocator of the test until it has been asked `allowed` times.
@(private="file")
Failing_Allocator :: struct {backing:runtime.Allocator,allowed,asked:int}
@(private="file")
failing_allocator :: proc(state:^Failing_Allocator) -> runtime.Allocator {
    limited :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        state:=cast(^Failing_Allocator)data
        if mode==.Alloc || mode==.Alloc_Non_Zeroed {
            state.asked+=1
            if state.asked>state.allowed {return nil,.Out_Of_Memory}
        }
        return state.backing.procedure(state.backing.data,mode,size,alignment,old,old_size,loc)
    }
    return {limited,state}
}

@(test)
mixer_that_runs_out_of_memory_leaves_nothing_behind :: proc(t:^testing.T) {
    // Every allocation of mixer_create fails in turn; the test runner reports what is not freed.
    created:=false
    for allowed in 0..<64 {
        state:=Failing_Allocator{backing=context.allocator,allowed=allowed}
        m,error:=mixer_create({stream_capacity=2,allocator=failing_allocator(&state)})
        if error==.None {
            testing.expect(t,m!=nil && allowed>8)
            // The mixer is full of memory it cannot get more of: sounds fail cleanly too.
            _,sound_error:=sound_create(m,{1,2,3,4},2,RATE)
            testing.expect_value(t,sound_error,Error.Out_Of_Memory)
            wav:=[?]i16le{1,2,3,4}
            _,sound_error=sound_load(m,test_wav(1,2,RATE,16,(cast([^]u8)&wav[0])[:8]))
            testing.expect_value(t,sound_error,Error.Out_Of_Memory)
            testing.expect_value(t,mixer_stats(m).sounds,0)
            mixer_destroy(m)
            created=true
            break
        }
        testing.expect(t,m==nil && error==.Out_Of_Memory)
    }
    testing.expect(t,created,"mixer_create never succeeded")
}
