package mirai_audio

import "core:fmt"
import "core:math"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private) TONE_LONG :: #load("testdata/tone_long.ogg") // 2 s, 330 Hz, 32 kHz, mono, amplitude 0.4
@(private="file") CLICK :: #load("testdata/click.ogg")  // 1 s at 44.1 kHz, mono
@(private="file") SINE :: #load("testdata/sine_mono.ogg") // 0.5 s at 44.1 kHz, mono, encoded as CLICK was

// A 16 bit value of frame i that changes every frame.
@(private="file")
pcm_value :: proc(i:int) -> i16 {return i16((i*37)%30011-15005)}
// A stereo 16 bit WAV whose frame i holds pcm_value(i) on the left and its opposite on the right.
@(private="file")
ramp_wav :: proc(frames:int,rate:=RATE) -> []u8 {
    samples:=make([]i16le,frames*2,context.temp_allocator)
    for i in 0..<frames {samples[i*2]=i16le(pcm_value(i));samples[i*2+1]=-i16le(pcm_value(i))}
    return test_wav(1,2,rate,16,(cast([^]u8)raw_data(samples))[:len(samples)*2])
}
@(private="file")
ramp_at :: proc(i:int) -> f32 {return f32(pcm_value(i))*(1.0/32768)}
// Renders like a game does: a little audio, then an update, over and over.
// Faster than real time, a decoder thread would lag: it decodes here too.
@(private="file")
play_along :: proc(m:^Mixer,frames:int,step:=200) -> []f32 {
    out:=make([]f32,frames*2,context.temp_allocator)
    for done:=0;done<frames;done+=step {
        n:=min(step,frames-done)
        if m.feeder!=nil {mixer_decode(m)}
        mixer_render(m,out[done*2:][:n*2])
        mixer_update(m)
    }
    return out
}
// The whole decode of a file in a sound made in memory, as a voice plays it: 16 bit samples.
@(private="file")
whole_sound :: proc(t:^testing.T,m:^Mixer,file:[]u8) -> Sound {
    pcm,error:=decode(file,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    for &sample in pcm.samples {sample=f32(sample_pcm16(sample))*(1.0/32768)}
    sound,_:=sound_create(m,pcm.samples,pcm.channels,pcm.sample_rate)
    return sound
}

// A loaded sound holds its bytes as they came, of a WAV its samples, and of
// an Ogg Vorbis one setup for every sound encoded alike: less than
// VORBIS_SETUP_BYTES. A feed holds its ring and, once a Vorbis sound is
// loaded, a workspace of a few tens of KB; nothing else grows with the sound.
@(test)
a_loaded_sound_holds_its_file_and_what_its_setup_shares :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    VORBIS_SETUP_BYTES :: 200*1024
    m:=test_mixer(t)
    defer mixer_destroy(m)
    feeds:=mixer_stats(m).feed_bytes
    // The rings, and the scratch of the decoder thread and of the game thread.
    testing.expect_value(t,feeds,len(m.feeds)*m.feed_frames*2*2+2*(m.feed_frames*4+FEED_FLOAT_FRAMES*2*4))
    samples:=make([]i16,LOSSLESS_BLOCK_FRAMES*3*2,context.temp_allocator)
    for &sample,i in samples {sample=pcm_value(i)}
    lossless,_:=lossless_encode(samples,2,RATE,context.temp_allocator)
    wav:=ramp_wav(5000)
    sounds:[4]Sound
    error:Error
    sounds[0],error=sound_load(m,lossless)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,mixer_stats(m).sound_bytes,len(lossless))
    sounds[1],error=sound_load(m,wav)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,mixer_stats(m).sound_bytes,len(lossless)+5000*2*2)
    testing.expect_value(t,mixer_stats(m).feed_bytes,feeds)
    before:=mixer_stats(m).sound_bytes
    sounds[2],error=sound_load(m,CLICK)
    testing.expect_value(t,error,Error.None)
    setup:=mixer_stats(m).sound_bytes-before-len(CLICK)
    testing.expectf(t,setup>0 && setup<VORBIS_SETUP_BYTES,"a Vorbis setup holds %d bytes",setup)
    workspace:=m.feed_workspace
    testing.expectf(t,workspace>0 && workspace<48*1024,"the Vorbis workspace of a feed is %d bytes",workspace)
    testing.expect_value(t,mixer_stats(m).feed_bytes,feeds+workspace*len(m.feeds))
    // Encoded alike: it adds its file alone.
    before=mixer_stats(m).sound_bytes
    sounds[3],error=sound_load(m,SINE)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,mixer_stats(m).sound_bytes,before+len(SINE))
    for sound in sounds {voice_play(m,sound)}
    play_along(m,RATE/10)
    testing.expect_value(t,mixer_stats(m).feed_bytes,feeds+workspace*len(m.feeds))
    for sound in sounds {sound_destroy(m,sound)}
    play_along(m,CHUNK_FRAMES*2)
    testing.expect(t,mixer_stats(m).sounds==0 && mixer_stats(m).sound_bytes==0 && m.setups[0].decoder==nil)
}

// Lossless, WAV or Vorbis, a voice plays the whole decode of its file sample
// for sample, rounded to 16 bits: from the start, from an offset, looping,
// and at a pitch of 2.
@(test)
a_voice_of_a_loaded_sound_plays_its_whole_decode :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    samples:=make([]i16,(LOSSLESS_BLOCK_FRAMES*5+321)*2,context.temp_allocator)
    for &sample,i in samples {sample=pcm_value(i/2)*(i%2==0?1:-1)}
    lossless,_:=lossless_encode(samples,2,44100,context.temp_allocator)
    files:=[?][]u8{lossless,ramp_wav(9000,22050),TONE_LONG}
    names:=[?]string{"lossless","wav","vorbis"}
    Play :: struct {offset:f64,loop:bool,pitch:f32,frames:int}
    plays:=[?]Play{{0,false,1,0},{0.21,false,1,0},{0,true,1,0},{0.33,true,2,0},{0,false,2,0}}
    for file,k in files {
        for p in plays {
            loaded:=test_mixer(t)
            memory:=test_mixer(t)
            sound,error:=sound_load(loaded,file)
            if !testing.expect_value(t,error,Error.None) {
                mixer_destroy(loaded);mixer_destroy(memory)
                continue
            }
            reference:=whole_sound(t,memory,file)
            desc:=VOICE_DEFAULT
            desc.offset,desc.loop,desc.pitch,desc.pan=p.offset,p.loop,p.pitch,-0.3
            a:=voice_play(loaded,sound,desc)
            b:=voice_play(memory,reference,desc)
            testing.expect(t,a!=0 && b!=0)
            // Past the end and around the loop.
            frames:=int(f64(sound_frames(loaded,sound))*f64(RATE)/f64(sound_sample_rate(loaded,sound))/f64(p.pitch))+3000
            if p.loop {frames+=frames/2}
            got:=play_along(loaded,frames,step=480)
            want:=play_along(memory,frames,step=480)
            for i in 0..<len(want) {
                if got[i]!=want[i] {
                    testing.expectf(t,false,"%s %v: sample %d is %v, its whole decode %v",names[k],p,i,got[i],want[i])
                    break
                }
            }
            testing.expect_value(t,voice_valid(loaded,a),p.loop)
            testing.expect_value(t,mixer_stats(loaded).underruns,u64(0))
            mixer_destroy(loaded);mixer_destroy(memory)
        }
    }
}

// Many voices of one sound that start on one tick each sound at the sample
// they were scheduled for, from their first frame, while the decoder thread
// does nothing: voice_play decoded their first chunk.
@(test)
a_storm_of_starts_places_every_voice_at_its_scheduled_sample :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    VOICES :: 64
    for threaded in ([?]bool{false,true}) {
        m:=test_mixer(t,{voice_capacity=VOICES,decoder_thread=threaded})
        reference:=test_mixer(t)
        sound,_:=sound_load(m,CLICK)
        once:=whole_sound(t,reference,CLICK)
        // The decoder is held: what plays is what voice_play decoded.
        pump_lock(m)
        desc:=VOICE_DEFAULT
        desc.volume=1.0/VOICES
        started:=time.tick_now()
        mixer_batch_begin(m)
        for i in 0..<VOICES {
            // Scheduled in the middle of the next chunks, a sample apart.
            desc.start_frame=mixer_clock(m)+100+u64(i)
            testing.expect(t,voice_play(m,sound,desc)!=0)
        }
        mixer_batch_end(m)
        if threaded {fmt.printfln("a storm of %d starts decodes their first frames in %v",VOICES,time.tick_since(started))}
        got:=test_render(m,FEED_START_FRAMES)
        pump_unlock(m)
        desc.volume=1.0/VOICES
        for i in 0..<VOICES {
            desc.start_frame=mixer_clock(reference)+100+u64(i)
            voice_play(reference,once,desc)
        }
        want:=test_render(reference,FEED_START_FRAMES)
        for i in 0..<len(want) {
            if !test_near(t,got[i],want[i],1e-6) {break}
        }
        testing.expect_value(t,mixer_stats(m).voices_active,VOICES)
        testing.expect_value(t,mixer_stats(m).underruns,u64(0))
        mixer_destroy(m);mixer_destroy(reference)
    }
}

// The same scripted mix rendered twice is the same to the sample: once with a
// decoder thread that lags, once decoding before every render. Clicks start
// on one tick, a song loops, a hum plays, and some start between renders.
@(test)
the_same_mix_rendered_twice_is_the_same_to_the_sample :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    samples:=make([]i16,LOSSLESS_BLOCK_FRAMES*3,context.temp_allocator)
    for &sample,i in samples {sample=pcm_value(i)}
    hum,_:=lossless_encode(samples,1,RATE,context.temp_allocator)
    run :: proc(t:^testing.T,threaded:bool,hum:[]u8) -> []f32 {
        m:=test_mixer(t,{voice_capacity=48,decoder_thread=threaded})
        defer mixer_destroy(m)
        click,_:=sound_load(m,CLICK)
        song,_:=sound_load(m,TONE_LONG)
        drone,_:=sound_load(m,hum)
        out:=make([]f32,48000*2,context.temp_allocator)
        for at,round:=0,0;at<48000;at,round=at+480,round+1 {
            // A decoder thread that lags behind the first renders of each start.
            if threaded && round%4==0 {pump_lock(m)}
            if round==0 || round==7 {
                mixer_batch_begin(m)
                for i in 0..<32 {
                    desc:=VOICE_DEFAULT
                    desc.volume=0.03;desc.pan=f32(i%5)*0.4-0.8;desc.pitch=0.9+f32(i%3)*0.1
                    desc.start_frame=mixer_clock(m)+u64(37*i)
                    voice_play(m,click,desc)
                }
                if round==0 {
                    desc:=VOICE_DEFAULT
                    desc.loop=true;desc.volume=0.3
                    voice_play(m,song,desc)
                    desc.volume=0.2;desc.offset=0.01
                    voice_play(m,drone,desc)
                }
                mixer_batch_end(m)
            }
            if !threaded {mixer_decode(m)}
            mixer_render(m,out[at*2:][:480*2])
            if threaded && round%4==0 {
                pump_unlock(m)
                mixer_decode(m)
            }
            mixer_update(m)
        }
        testing.expect_value(t,mixer_stats(m).underruns,u64(0))
        return out
    }
    a,b:=run(t,true,hum),run(t,false,hum)
    for i in 0..<len(a) {
        if a[i]!=b[i] {
            testing.expectf(t,false,"sample %d is %v with a lagging decoder thread, %v decoding before every render",i,a[i],b[i])
            break
        }
    }
}

// A decode that misses its deadline after the first chunk: the ring of a
// voice that runs dry goes silent, counts underruns, and resumes with the
// frame it stopped at.
@(test)
a_dry_ring_goes_silent_and_skips_nothing :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    m:=test_mixer(t,{decoder_thread=true})
    defer mixer_destroy(m)
    sound,_:=sound_load(m,ramp_wav(40000))
    // The decoder is held: the voice has what voice_play decoded and nothing more.
    pump_lock(m)
    voice:=voice_play(m,sound)
    held:=sync.atomic_load(&m.feeds[0].write)
    testing.expect(t,held>=FEED_START_FRAMES)
    out:=test_render(m,int(held)+1000)
    heard:=0
    for i in 0..<len(out)/2 {
        if out[i*2]==0 && ramp_at(i)!=0 {break}
        heard+=1
    }
    testing.expect_value(t,u64(heard),held)
    testing.expect_value(t,out[len(out)-2],f32(0))
    testing.expect(t,mixer_stats(m).underruns>0)
    testing.expect(t,voice_valid(m,voice))
    pump_unlock(m)
    for sync.atomic_load(&m.feeds[0].write)<held+FEED_START_FRAMES {thread.yield()}
    out=test_render(m,300)
    for i in 0..<300 {
        if !test_near(t,out[i*2],ramp_at(int(held)+i),0) {break}
    }
    testing.expect(t,voice_valid(m,voice))
}

@(test)
looping_voice_wraps_without_a_seam_until_told_to_stop :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    FRAMES :: 9500
    START :: 500
    sound,_:=sound_load(m,ramp_wav(FRAMES))
    // The decoder goes back to the loop start: the frames before it play once.
    testing.expect(t,sound_set_loop_start(m,sound,START))
    desc:=VOICE_DEFAULT
    desc.loop=true
    voice:=voice_play(m,sound,desc)
    out:=play_along(m,FRAMES*3+100,step=173)
    for i in 0..<FRAMES*3+100 {
        if !test_near(t,out[i*2],ramp_at(i if i<FRAMES else START+(i-FRAMES)%(FRAMES-START)),0) {break}
    }
    // No more loops: it ends at an end of the file, the next one that was not decoded yet.
    testing.expect(t,voice_set_loop(m,voice,false))
    out=play_along(m,FRAMES*2,step=173)
    last:=0
    for i in 0..<FRAMES*2 {
        if out[i*2]!=0 {last=i}
    }
    test_near(t,out[last*2],ramp_at(FRAMES-1),0)
    testing.expect(t,!voice_valid(m,voice))
}

@(test)
an_ogg_voice_can_crossfade_with_itself :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    m:=test_mixer(t)
    defer mixer_destroy(m)
    reference:=test_mixer(t)
    defer mixer_destroy(reference)
    loaded,error:=sound_load(m,TONE_LONG)
    if !testing.expect_value(t,error,Error.None) {return}
    sound:=whole_sound(t,reference,TONE_LONG)
    desc:=VOICE_DEFAULT
    desc.volume=0.25
    outgoing:=voice_play(m,loaded,desc)
    original:=voice_play(reference,sound,desc)
    _=play_along(m,2400)
    _=play_along(reference,2400)
    testing.expect(t,voice_stop(m,outgoing,0.05) && voice_stop(reference,original,0.05))
    desc.offset=0.25
    desc.fade_in=0.05
    asks:=0
    allocator:=m.allocator
    m.allocator=test_no_allocator(&asks)
    incoming:=voice_play(m,loaded,desc)
    m.allocator=allocator
    if !testing.expect(t,incoming!=0 && incoming!=outgoing) {return}
    testing.expect_value(t,asks,0)
    voice_play(reference,sound,desc)
    got:=play_along(m,4800)
    want:=play_along(reference,4800)
    for sample,i in got {
        if !test_near(t,sample,want[i],0) {break}
    }
    testing.expect(t,!voice_valid(m,outgoing) && voice_valid(m,incoming))
    testing.expect_value(t,mixer_stats(m).underruns,u64(0))
}

@(test)
voices_take_feeds_only_while_playing :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    m:=test_mixer(t,{voice_capacity=8,feed_capacity=4})
    defer mixer_destroy(m)
    file:=ramp_wav(4000)
    sounds:[5]Sound
    for &sound in sounds {
        error:Error
        sound,error=sound_load(m,file)
        if !testing.expect_value(t,error,Error.None) {return}
    }
    desc:=VOICE_DEFAULT
    desc.volume=0.25
    for sound in sounds[:4] {
        if !testing.expect(t,voice_play(m,sound,desc)!=0) {return}
    }
    testing.expect_value(t,voice_play(m,sounds[4],desc),Voice(0))
    testing.expect_value(t,mixer_stats(m).feeds_busy,u64(1))
    out:=play_along(m,1600)
    testing.expect_value(t,mixer_stats(m).voices_active,4)
    test_near(t,out[len(out)-2],ramp_at(1599))
    sound_destroy(m,sounds[0])
    play_along(m,CHUNK_FRAMES)
    testing.expect(t,voice_play(m,sounds[4],desc)!=0)
    testing.expect(t,!sound_valid(m,sounds[0]))
    for sound in sounds[1:] {testing.expect(t,sound_valid(m,sound))}
}

// What is not a sound that plays is refused, and nothing of it stays.
@(test)
a_file_that_does_not_play_is_refused :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    m:=test_mixer(t)
    defer mixer_destroy(m)
    pcm:=[?]i16le{1,2,3,4}
    data:=(cast([^]u8)&pcm[0])[:8]
    samples:=[?]i16{1,2,3,4}
    tone:=TONE_LONG
    Case :: struct {what:string,file:[]u8,error:Error}
    cases:=[?]Case{
        {"nothing",nil,.Invalid_Data},
        {"three bytes",{1,2,3},.Invalid_Data},
        {"a WAV without frames",test_wav(1,1,RATE,16,nil),.Invalid_Data},
        {"a WAV at 1 Hz",test_wav(1,1,1,16,data),.Unsupported_Format},
        {"a WAV at 2 GHz",test_wav(1,1,2_000_000_000,16,data),.Unsupported_Format},
        {"a lossless file without frames",lossless_of(t,nil,1,RATE),.Invalid_Data},
        {"a lossless file at 500 Hz",lossless_of(t,samples[:],2,500),.Unsupported_Format},
        {"an Ogg page and nothing else",{'O','g','g','S',0,2,0,0,0,0,0,0,0,0,1,2,3,4,0,0,0,0,9,9,9,9,1,30,1,2,3},.Invalid_Data},
        {"an Ogg Vorbis cut in its headers",tone[:200],.Invalid_Data},
        {"an Ogg Vorbis cut after its headers",tone[:ogg_header_end(tone)],.Invalid_Data},
        {"an Ogg Vorbis cut inside its page of audio",tone[:len(tone)-1],.Invalid_Data},
    }
    for c in cases {
        sound,error:=sound_load(m,c.file)
        testing.expectf(t,sound==0 && error==c.error,"%s: %v, not %v",c.what,error,c.error)
    }
    testing.expect(t,mixer_stats(m).sounds==0 && mixer_stats(m).sound_bytes==0 && m.feed_workspace==0)
}
@(private="file")
lossless_of :: proc(t:^testing.T,samples:[]i16,channels,rate:int) -> []u8 {
    file,error:=lossless_encode(samples,channels,max(rate,48000),context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    // The rate, written over.
    for i in 0..<4 {file[8+i]=u8(u32(rate)>>(u32(i)*8))}
    return file
}
// Where the pages of the headers of an Ogg Vorbis file end: those of the three header packets.
@(private="file")
ogg_header_end :: proc(file:[]u8) -> int {
    at,packets:=0,0
    for packets<3 {
        segments:=int(file[at+26])
        body:=27+segments
        for lacing in file[at+27:][:segments] {
            body+=int(lacing)
            if lacing<255 {packets+=1}
        }
        at+=body
    }
    return at
}

@(private="file")
Render_Thread :: struct {m:^Mixer,stop:bool,chunks:int,peak:f32}

// The threads a mixer is made for, each doing its part as fast as it can:
// afterwards no voice, feed or sound is lost and nothing was left playing.
@(test)
audio_thread_and_game_thread_share_a_mixer_without_locks :: proc(t:^testing.T) {
    m:=test_mixer(t,{voice_capacity=16,decoder_thread=true})
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
    music:Sound
    bus,_:=bus_create(m)
    voices:[64]Voice
    tracks:[2]Voice
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
            sound_destroy(m,music)
            music,_=sound_load(m,TONE_LONG)
        }
        voice:=voice_play(m,sounds[round%4],desc)
        if voice!=0 {voices[slot]=voice;played+=1}
        voice_set_volume(m,voices[(slot+7)%len(voices)],0.02)
        voice_set_pan(m,voices[(slot+11)%len(voices)],-0.5)
        if round%5==0 {voice_stop(m,voices[(slot+3)%len(voices)],0.001)}
        if round%11==0 {voice_set_paused(m,voices[(slot+5)%len(voices)],round%22==0)}
        for &voice in tracks {
            if !voice_valid(m,voice) {
                desc.volume=0.0001;desc.loop=round%2==0;desc.spatial=false;desc.pitch=1;desc.priority=255
                voice=voice_play(m,music,desc)
            }
        }
        listener_set(m,{f32(round%3),0,0},1)
        bus_set_volume(m,bus,0.5)
        if round%4==0 {mixer_update(m)}
        if round%64==0 {
            before:=sync.atomic_load(&state.chunks)
            for sync.atomic_load(&state.chunks)==before {thread.yield()}
        }
    }
    testing.expect(t,played>1000)
    // Everything is stopped and the audio thread is given the time to say so.
    for attempt:=0;attempt<2000;attempt+=1 {
        for voice in voices {voice_stop(m,voice)}
        for voice in tracks {voice_stop(m,voice)}
        for &shadow,i in m.shadows {
            if shadow.active {command_push(m,{kind=.Voice_Stop,index=u32(i),generation=shadow.generation})}
        }
        before:=sync.atomic_load(&state.chunks)
        for sync.atomic_load(&state.chunks)<before+3 {thread.yield()}
        mixer_update(m)
        if m.free_count==len(m.shadows) && m.free_feed_count==len(m.feeds) {break}
    }
    sync.atomic_store(&state.stop,true)
    thread.join(worker)
    testing.expect_value(t,m.free_count,len(m.shadows))
    testing.expect_value(t,m.free_feed_count,len(m.feeds))
    testing.expect_value(t,mixer_stats(m).voices_active,0)
    testing.expect(t,mixer_stats(m).frames_rendered>0 && state.chunks>0)
    testing.expect(t,state.peak<4,"The mix went far above what the voices could add up to")
    testing.expect(t,!math.is_nan(state.peak))
    testing.expect_value(t,mixer_stats(m).sounds,5)
}
