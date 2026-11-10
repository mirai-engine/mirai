package mirai_audio

import "core:math"
import "core:sync"
import "core:testing"
import "core:thread"

@(private="file") TONE_LONG :: #load("testdata/tone_long.ogg") // 2 s of 330 Hz at 32 kHz, mono, amplitude 0.4

// A stereo f32 WAV whose frame i holds test_ramp(i) on the left and its opposite on the right.
@(private="file")
ramp_wav :: proc(frames:int,rate:=RATE) -> []u8 {
    samples:=make([]f32le,frames*2,context.temp_allocator)
    for i in 0..<frames {samples[i*2]=f32le(test_ramp(i));samples[i*2+1]=-f32le(test_ramp(i))}
    return test_wav(3,2,rate,32,(cast([^]u8)raw_data(samples))[:len(samples)*4])
}
// Renders like a game does: a little audio, then an update, over and over.
@(private="file")
play_along :: proc(m:^Mixer,frames:int,step:=200) -> []f32 {
    out:=make([]f32,frames*2,context.temp_allocator)
    for done:=0;done<frames;done+=step {
        n:=min(step,frames-done)
        mixer_render(m,out[done*2:][:n*2])
        mixer_update(m)
    }
    return out
}

@(test)
stream_plays_exactly_what_its_file_holds :: proc(t:^testing.T) {
    m:=test_mixer(t,{stream_frames=1024})
    defer mixer_destroy(m)
    FRAMES :: 5000
    sound,error:=sound_stream(m,ramp_wav(FRAMES))
    testing.expect_value(t,error,Error.None)
    testing.expect(t,sound_valid(m,sound) && sound_frames(m,sound)==FRAMES && sound_channels(m,sound)==2 && sound_sample_rate(m,sound)==RATE)
    voice:=voice_play(m,sound)
    testing.expect(t,voice!=0)
    // The file is five times the ring: it is decoded as it plays.
    out:=play_along(m,FRAMES+600)
    for i in 0..<FRAMES+600 {
        want:=test_ramp(i) if i<FRAMES else 0
        if !test_near(t,out[i*2],want,0) || !test_near(t,out[i*2+1],-want,0) {break}
    }
    testing.expect(t,!voice_valid(m,voice))
    testing.expect_value(t,mixer_stats(m).underruns,u64(0))
    // Played again, it starts from the beginning.
    desc:=VOICE_DEFAULT
    desc.volume=0.5
    voice=voice_play(m,sound,desc)
    out=play_along(m,300)
    for i in 0..<300 {
        if !test_near(t,out[i*2],test_ramp(i)*0.5,0) {break}
    }
    // One voice at a time.
    testing.expect_value(t,voice_play(m,sound),Voice(0))
    testing.expect_value(t,mixer_stats(m).streams_busy,u64(1))
    // Stopped, it is free again once an update has seen it end.
    voice_stop(m,voice)
    testing.expect_value(t,voice_play(m,sound),Voice(0))
    play_along(m,CHUNK_FRAMES)
    voice=voice_play(m,sound)
    testing.expect(t,voice!=0)
    out=play_along(m,10)
    test_near(t,out[0],test_ramp(0),0)
}

@(test)
looping_stream_wraps_without_a_seam_until_told_to_stop :: proc(t:^testing.T) {
    m:=test_mixer(t,{stream_frames=1024})
    defer mixer_destroy(m)
    FRAMES :: 1500
    sound,_:=sound_stream(m,ramp_wav(FRAMES))
    desc:=VOICE_DEFAULT
    desc.loop=true
    voice:=voice_play(m,sound,desc)
    out:=play_along(m,FRAMES*4+100,step=173)
    for i in 0..<FRAMES*4+100 {
        if !test_near(t,out[i*2],test_ramp(i%FRAMES),0) {break}
    }
    // No more loops: it ends at an end of the file, the next one that was not decoded yet.
    testing.expect(t,voice_set_loop(m,voice,false))
    out=play_along(m,FRAMES*3,step=173)
    last:=0
    for i in 0..<FRAMES*3 {
        if out[i*2]!=0 {last=i}
    }
    test_near(t,out[last*2],test_ramp(FRAMES-1),0)
    testing.expect(t,last<FRAMES*2+100)
    testing.expect(t,!voice_valid(m,voice))
}

@(test)
starved_stream_goes_quiet_and_resumes_where_it_was :: proc(t:^testing.T) {
    m:=test_mixer(t,{stream_frames=1024})
    defer mixer_destroy(m)
    sound,_:=sound_stream(m,ramp_wav(20000))
    voice:=voice_play(m,sound)
    // The game thread stalls: no update while more than the ring is rendered.
    out:=test_render(m,3000)
    heard:=0
    for i in 0..<3000 {
        if out[i*2]==0 {continue}
        heard+=1
        if !test_near(t,out[i*2],test_ramp(heard-1),0) {break}
    }
    testing.expect_value(t,heard,1024)
    testing.expect_value(t,out[2999*2],f32(0))
    testing.expect(t,mixer_stats(m).underruns>0)
    testing.expect(t,voice_valid(m,voice))
    // It comes back with the very next frame of the sound.
    mixer_update(m)
    out=play_along(m,2000)
    for i in 0..<2000 {
        if !test_near(t,out[i*2],test_ramp(1024+i),0) {break}
    }
}

@(test)
resampled_ogg_stream_sounds_like_the_same_file_played_from_memory :: proc(t:^testing.T) {
    memory:=test_mixer(t)
    defer mixer_destroy(memory)
    streamed:=test_mixer(t,{stream_frames=2048})
    defer mixer_destroy(streamed)
    loaded,load_error:=sound_load(memory,TONE_LONG)
    testing.expect_value(t,load_error,Error.None)
    stream,stream_error:=sound_stream(streamed,TONE_LONG)
    testing.expect_value(t,stream_error,Error.None)
    testing.expect(t,sound_frames(streamed,stream)==64000 && sound_sample_rate(streamed,stream)==32000 && sound_channels(streamed,stream)==1)
    desc:=VOICE_DEFAULT
    desc.pitch=1.1;desc.pan=-0.4
    a:=voice_play(memory,loaded,desc)
    b:=voice_play(streamed,stream,desc)
    // 64000 frames at 32 kHz, 1.1 times as fast, on a 48 kHz mixer: about 87273 frames.
    TOTAL :: 90000
    want:=play_along(memory,TOTAL,step=480)
    got:=play_along(streamed,TOTAL,step=480)
    worst:=f32(0)
    for i in 0..<TOTAL*2 {worst=max(worst,abs(want[i]-got[i]))}
    testing.expectf(t,worst<1e-5,"the stream differs from the sound in memory by %v",worst)
    // And it is the tone that was encoded: 330*1.1 Hz.
    energy:=f64(0)
    for i in 48000..<57600 {energy+=f64(got[i*2])*f64(got[i*2])}
    left:=pan_gains(-0.4)[0]
    test_near(t,f32(math.sqrt(energy/9600)),0.4*f32(math.SQRT_TWO/2)*left,5e-3)
    testing.expect(t,got[87000*2]!=0 || got[87001*2]!=0)
    testing.expect_value(t,got[87400*2],f32(0))
    testing.expect(t,!voice_valid(memory,a) && !voice_valid(streamed,b))
    testing.expect_value(t,mixer_stats(streamed).underruns,u64(0))
}

@(test)
streams_are_limited_and_their_place_is_freed_with_the_sound :: proc(t:^testing.T) {
    m:=test_mixer(t,{stream_capacity=1,voice_capacity=1})
    defer mixer_destroy(m)
    file:=ramp_wav(4000)
    first,error:=sound_stream(m,file)
    testing.expect_value(t,error,Error.None)
    _,error=sound_stream(m,file)
    testing.expect_value(t,error,Error.Capacity_Exhausted)
    _,error=sound_stream(m,{1,2,3})
    testing.expect_value(t,error,Error.Capacity_Exhausted)
    // The voice of a stream is not stolen, whatever the priority of the newcomer.
    voice:=voice_play(m,first)
    desc:=VOICE_DEFAULT
    desc.priority=255
    testing.expect_value(t,voice_play(m,test_stereo(t,m,64,test_one),desc),Voice(0))
    testing.expect_value(t,mixer_stats(m).voices_rejected,u64(1))
    play_along(m,100)
    sound_destroy(m,first)
    testing.expect(t,!sound_valid(m,first))
    play_along(m,CHUNK_FRAMES)
    testing.expect(t,!voice_valid(m,voice))
    second,second_error:=sound_stream(m,TONE_LONG)
    testing.expect_value(t,second_error,Error.None)
    testing.expect(t,voice_play(m,second)!=0)
    _,error=sound_stream(m,{'O','g','g','S',1,2,3})
    testing.expect_value(t,error,Error.Capacity_Exhausted)
    sound_destroy(m,second)
    play_along(m,CHUNK_FRAMES)
    _,error=sound_stream(m,{'O','g','g','S',1,2,3})
    testing.expect_value(t,error,Error.Invalid_Data)
    _,error=sound_stream(m,{1,2,3})
    testing.expect_value(t,error,Error.Invalid_Data)
}

@(private="file")
Render_Thread :: struct {m:^Mixer,stop:bool,chunks:int,peak:f32}

// The threads a mixer is made for, each doing its part as fast as it can:
// afterwards no voice, feed or sound is lost and nothing was left playing.
@(test)
audio_thread_and_game_thread_share_a_mixer_without_locks :: proc(t:^testing.T) {
    m:=test_mixer(t,{voice_capacity=16,stream_frames=2048,decoder_thread=true})
    defer mixer_destroy(m)
    state:=Render_Thread{m=m}
    render :: proc(state:^Render_Thread) {
        out:[128*2]f32
        for !sync.atomic_load(&state.stop) {
            mixer_render(state.m,out[:])
            for sample in out {state.peak=max(state.peak,abs(sample))}
            sync.atomic_add(&state.chunks,1)
        }
    }
    worker:=thread.create_and_start_with_poly_data(&state,render)
    defer thread.destroy(worker)
    sounds:[4]Sound
    sounds[0]=test_mono(t,m,2000,test_small,44100)
    sounds[1]=test_stereo(t,m,3000,test_small)
    // Kept encoded: every voice of it decodes on the decoder thread.
    samples:=make([]i16,3000*2,context.temp_allocator)
    for &sample,i in samples {sample=i16(i%101-50)}
    encoded,_:=lossless_encode(samples,2,22050,context.temp_allocator)
    sounds[2],_=sound_load(m,encoded)
    stream,_:=sound_stream(m,ramp_wav(9000))
    bus,_:=bus_create(m)
    voices:[64]Voice
    music:Voice
    played:=0
    for round in 0..<20000 {
        slot:=round%len(voices)
        desc:=VOICE_DEFAULT
        desc.volume=0.01;desc.loop=round%3==0;desc.pitch=0.5+f32(round%5)*0.3
        desc.priority=u8(round%4);desc.bus=bus if round%2==0 else BUS_MASTER
        desc.spatial=round%7==0;desc.position={f32(round%9)-4,0,-1}
        if round%2500==0 {
            // A sound comes and goes while its voices play.
            sound_destroy(m,sounds[3])
            sounds[3],_=sound_create(m,make([]f32,512,context.temp_allocator),1,RATE)
        }
        voice:=voice_play(m,sounds[round%4],desc)
        if voice!=0 {voices[slot]=voice;played+=1}
        voice_set_volume(m,voices[(slot+7)%len(voices)],0.02)
        voice_set_pan(m,voices[(slot+11)%len(voices)],-0.5)
        if round%5==0 {voice_stop(m,voices[(slot+3)%len(voices)],0.001)}
        if round%11==0 {voice_set_paused(m,voices[(slot+5)%len(voices)],round%22==0)}
        if !voice_valid(m,music) {
            desc.volume=0.0001;desc.loop=round%2==0;desc.spatial=false;desc.pitch=1
            music=voice_play(m,stream,desc)
        }
        listener_set(m,{f32(round%3),0,0},1)
        bus_set_volume(m,bus,0.5)
        if round%4==0 {mixer_update(m)}
        if round%64==0 {thread.yield()}
    }
    testing.expect(t,played>1000)
    // Everything is stopped and the audio thread is given the time to say so.
    for attempt:=0;attempt<2000;attempt+=1 {
        for voice in voices {voice_stop(m,voice)}
        voice_stop(m,music)
        for &shadow,i in m.shadows {
            if shadow.active {command_push(m,{kind=.Voice_Stop,index=u32(i),generation=shadow.generation})}
        }
        before:=sync.atomic_load(&state.chunks)
        for sync.atomic_load(&state.chunks)<before+3 {thread.yield()}
        mixer_update(m)
        if m.free_count==len(m.shadows) && m.free_feed_count==m.pool_feeds && feed_phase(&m.feeds[m.pool_feeds])==.Free {break}
    }
    sync.atomic_store(&state.stop,true)
    thread.join(worker)
    testing.expect_value(t,m.free_count,len(m.shadows))
    testing.expect_value(t,m.free_feed_count,m.pool_feeds)
    testing.expect_value(t,mixer_stats(m).voices_active,0)
    testing.expect(t,mixer_stats(m).frames_rendered>0 && state.chunks>0)
    testing.expect(t,state.peak<4,"The mix went far above what the voices could add up to")
    testing.expect(t,!math.is_nan(state.peak))
    // No voice plays the stream any more, and every sound slot but the live ones is free.
    testing.expect_value(t,feed_phase(&m.feeds[m.pool_feeds]),Feed_Phase.Free)
    testing.expect_value(t,mixer_stats(m).sounds,5)
}
