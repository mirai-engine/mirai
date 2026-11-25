package mirai_audio

import "core:math"
import "core:testing"

@(private="file")
rms :: proc(out:[]f32,channel:int) -> f32 {
    sum:=f64(0)
    for i in 0..<len(out)/2 {sum+=f64(out[i*2+channel])*f64(out[i*2+channel])}
    return f32(math.sqrt(sum/f64(len(out)/2)))
}

@(test)
bus_volume_and_mute_scale_what_plays_into_it :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    music,ok:=bus_create(m)
    testing.expect(t,ok && music!=BUS_MASTER)
    effects,_:=bus_create(m)
    desc:=VOICE_DEFAULT
    desc.loop=true
    // Levels that tell the buses apart in their sum, under full scale.
    unit:=f32(1.0/128)
    one:=test_stereo(t,m,64,test_one)
    desc.bus=music;desc.volume=unit
    voice_play(m,one,desc)
    desc.bus=effects;desc.volume=10*unit
    voice_play(m,one,desc)
    desc.bus=BUS_MASTER;desc.volume=100*unit
    voice_play(m,one,desc)
    out:=test_render(m,4)
    test_near(t,out[0],111*unit,1e-4)
    test_near(t,out[1],-111*unit,1e-4)
    testing.expect(t,bus_set_volume(m,music,0.5))
    testing.expect_value(t,bus_volume(m,music),f32(0.5))
    out=test_render(m,CHUNK_FRAMES+4)
    // Ramped across a chunk, like every other change of gain.
    test_near(t,out[0],111*unit,1e-4)
    test_near(t,out[(CHUNK_FRAMES/2)*2],110.75*unit,1e-5)
    test_near(t,out[CHUNK_FRAMES*2],110.5*unit,1e-4)
    testing.expect(t,bus_set_mute(m,effects,true))
    testing.expect(t,bus_muted(m,effects) && !bus_muted(m,music))
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[0],100.5*unit,1e-4)
    // The volume of a muted bus is kept for when it comes back.
    bus_set_volume(m,effects,2)
    bus_set_mute(m,effects,false)
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[0],120.5*unit,1e-4)
    // The master scales everything, buses included.
    bus_set_volume(m,BUS_MASTER,0.1)
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[0],12.05*unit,1e-5)
    bus_set_mute(m,BUS_MASTER,true)
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    testing.expect_value(t,out[0],f32(0))
    bus_set_volume(m,music,-3)
    testing.expect_value(t,bus_volume(m,music),f32(0))
}

@(test)
buses_are_limited_to_their_capacity :: proc(t:^testing.T) {
    m:=test_mixer(t,{bus_capacity=2})
    defer mixer_destroy(m)
    first,ok:=bus_create(m)
    testing.expect(t,ok && first==Bus(1))
    _,ok=bus_create(m)
    testing.expect(t,!ok)
    missing:=Bus(1+1)
    testing.expect(t,!bus_set_volume(m,missing,1) && !bus_set_mute(m,missing,true) && !bus_set_filter(m,missing,0,{kind=.Lowpass,frequency=100}))
    testing.expect(t,bus_volume(m,missing)==0 && !bus_muted(m,missing) && bus_filter(m,missing,0)=={})
    testing.expect(t,!bus_set_duck(m,missing,{source=BUS_MASTER,amount=1}))
    testing.expect(t,!bus_set_duck(m,first,{source=missing,amount=1}))
    testing.expect(t,!bus_set_duck(m,first,{source=first,amount=1}))
    testing.expect(t,!bus_set_duck(m,BUS_MASTER,{source=first,amount=1}))
}

// The water plugin sweeps the cutoff while the listener goes under: a
// filter that jumped to its new coefficients would step the wave each chunk.
@(test)
bus_low_pass_sweep_has_no_steps :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    bus,_:=bus_create(m)
    desc:=VOICE_DEFAULT
    desc.loop=true;desc.bus=bus
    voice_play(m,test_stereo(t,m,RATE,proc(i:int) -> f32 {return 0.5*math.sin_f32(2*math.PI*100*f32(i)/RATE)}),desc)
    last:f32
    largest_step :: proc(out:[]f32,last:^f32) -> (step:f32) {
        for k in 0..<len(out)/2 {step=max(step,abs(out[k*2]-last^));last^=out[k*2]}
        return
    }
    unfiltered:=largest_step(test_render(m,4800),&last)
    // From 16 kHz down to 300 Hz, a new cutoff every chunk.
    swept:f32
    for cutoff:=f32(16000);cutoff>300;cutoff*=0.7 {
        bus_set_filter(m,bus,0,{kind=.Lowpass,frequency=cutoff})
        swept=max(swept,largest_step(test_render(m,CHUNK_FRAMES),&last))
    }
    testing.expectf(t,swept<=unfiltered,"the sweep steps by %v, the sine by %v",swept,unfiltered)
}

@(test)
bus_is_ducked_while_another_one_is_loud :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    music,_:=bus_create(m)
    speech,_:=bus_create(m)
    attack,release:=f32(0.02),f32(0.1)
    testing.expect(t,bus_set_duck(m,music,{source=speech,threshold=0.05,amount=0.75,attack=attack,release=release}))
    desc:=VOICE_DEFAULT
    desc.loop=true;desc.bus=music
    one:=test_stereo(t,m,64,proc(i:int) -> f32 {return 0.5}) // under full scale with the speech over it
    voice_play(m,one,desc)
    out:=test_render(m,RATE/10)
    // Nothing on the speech bus: the music is left alone.
    test_near(t,out[len(out)-2],0.5,1e-6)
    desc.bus=speech;desc.volume=0.08
    quiet:=voice_play(m,one,desc)
    out=test_render(m,RATE/10)
    // Below the threshold: music plus the quiet speech.
    test_near(t,out[len(out)-2],0.54,1e-5)
    voice_stop(m,quiet)
    desc.volume=0.5
    loud:=voice_play(m,one,desc)
    attack_frames:=int(attack*RATE)
    out=test_render(m,attack_frames+2*CHUNK_FRAMES)
    // It comes down steadily, never below its ducked level, and gets there in the attack time.
    previous:=f32(2)
    for i in CHUNK_FRAMES..<len(out)/2 {
        music_level:=out[i*2]-0.25
        testing.expect(t,music_level<=previous+1e-5 && music_level>=0.125-1e-5)
        previous=music_level
    }
    test_near(t,out[len(out)-2],0.125+0.25,1e-4)
    test_near(t,out[(CHUNK_FRAMES+attack_frames/2)*2],0.3125+0.25,0.1)
    // The speech ends: the music comes back in the release time, not before.
    voice_stop(m,loud)
    test_render(m,CHUNK_FRAMES)
    release_frames:=int(release*RATE)
    out=test_render(m,release_frames/2)
    testing.expect(t,out[len(out)-2]>0.25 && out[len(out)-2]<0.4)
    out=test_render(m,release_frames/2+2*CHUNK_FRAMES)
    test_near(t,out[len(out)-2],0.5,1e-4)
    // An amount of zero ends the ducking; a muted source ducks nothing.
    bus_set_mute(m,speech,true)
    voice_play(m,one,desc)
    out=test_render(m,RATE/10)
    test_near(t,out[len(out)-2],0.5,1e-4)
    bus_set_mute(m,speech,false)
    testing.expect(t,bus_set_duck(m,music,{source=speech}))
    out=test_render(m,RATE/5)
    test_near(t,out[len(out)-2],0.75,1e-4)
}

// An ambience bus sends into the effects bus: the volume of effects reaches
// it. A bus sends only to the master or to one created before it.
@(test)
a_bus_sends_into_one_created_before_it :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    effects,_:=bus_create(m)
    ambience,_:=bus_create(m)
    testing.expect_value(t,bus_send(m,ambience),BUS_MASTER)
    testing.expect(t,bus_set_send(m,ambience,effects))
    testing.expect_value(t,bus_send(m,ambience),effects)
    for refused in ([?][2]Bus{{effects,ambience},{ambience,ambience},{BUS_MASTER,BUS_MASTER},{Bus(9),BUS_MASTER}}) {
        testing.expectf(t,!bus_set_send(m,refused[0],refused[1]),"%v cannot send to %v",refused[0],refused[1])
    }
    testing.expect_value(t,bus_send(m,effects),BUS_MASTER)
    desc:=VOICE_DEFAULT
    desc.loop=true;desc.bus=ambience;desc.volume=0.5
    voice_play(m,test_stereo(t,m,64,test_one),desc)
    bus_set_volume(m,effects,0.5)
    bus_set_volume(m,ambience,0.5)
    test_render(m,CHUNK_FRAMES)
    out:=test_render(m,4)
    test_near(t,out[0],0.125)
    // Back to the master, the volume of effects no longer reaches it.
    testing.expect(t,bus_set_send(m,ambience,BUS_MASTER))
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[0],0.25)
}

// A sum of loud voices comes out at full scale at most, at once, and comes
// back after its hold and release; a quiet mix comes out as it is.
@(test)
the_master_limiter_holds_a_loud_mix_under_full_scale :: proc(t:^testing.T) {
    for channels in 1..=2 {
        m:=test_mixer(t,{channels=channels})
        defer mixer_destroy(m)
        desc:=VOICE_DEFAULT
        desc.loop=true
        // A centered mono sound: at its level on one speaker, by the pan law on two.
        level:=f32(1) if channels==1 else f32(math.SQRT_TWO/2)
        quiet_mix :: proc(t:^testing.T,out:[]f32,channels:int,level:f32,from:int) {
            for x,i in out {
                if !test_near(t,x,test_small(from+i/channels)*level,1e-6) {break}
            }
        }
        quiet:=voice_play(m,test_mono(t,m,RATE,test_small),desc)
        quiet_mix(t,test_render(m,RATE/10),channels,level,0)
        voice_stop(m,quiet)
        test_render(m,CHUNK_FRAMES)
        loud:[8]Voice
        for &voice in loud {voice=voice_play(m,test_mono(t,m,64,test_one),desc)}
        out:=test_render(m,RATE/10)
        peak:=f32(0)
        for x in out {peak=max(peak,abs(x))}
        testing.expectf(t,peak<=LIMITER_CEILING && peak>0.99*LIMITER_CEILING,"%d channels: a mix of 8 at full scale peaks at %v",channels,peak)
        for voice in loud {voice_stop(m,voice)}
        test_render(m,int((LIMITER_HOLD+LIMITER_RELEASE)*RATE)+CHUNK_FRAMES)
        mixer_update(m)
        quiet=voice_play(m,test_mono(t,m,RATE,test_small),desc)
        quiet_mix(t,test_render(m,RATE/10),channels,level,0)
    }
}

// Nested batches hold commands until the outermost end.
@(test)
nested_batches_flush_once :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    mixer_batch_begin(m)
    mixer_batch_begin(m)
    bus_set_volume(m,BUS_MASTER,0.5)
    mixer_batch_end(m)
    // Inner end must not publish yet.
    test_render(m,CHUNK_FRAMES)
    testing.expect_value(t,m.buses[BUS_MASTER].volume,f32(1))
    mixer_batch_end(m)
    test_render(m,CHUNK_FRAMES)
    testing.expect_value(t,m.buses[BUS_MASTER].volume,f32(0.5))
}

// The effects of a bus run on what it plays in the order of their slots,
// with their parameters from the next chunk; a bus without one plays as it
// comes. The state an effect replaces is freed only once the audio thread
// let go of it, and the mixer frees the states it holds when it goes.
@(test)
bus_effects_run_in_order_and_free_their_state_once_let_go :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    scale :: proc "contextless" (state:[]u8,params:[BUS_EFFECT_PARAMS]f32,frames:[^]f32,n,rate:int) {
        (^int)(raw_data(state))^+=1
        for i in 0..<n*2 {frames[i]*=params[0]}
    }
    offset :: proc "contextless" (state:[]u8,params:[BUS_EFFECT_PARAMS]f32,frames:[^]f32,n,rate:int) {
        for i in 0..<n*2 {frames[i]+=params[0]}
    }
    state :: proc(m:^Mixer) -> []u8 {
        bytes,_:=make([]u8,size_of(int),m.allocator)
        return bytes
    }
    effected,_:=bus_create(m)
    plain,_:=bus_create(m)
    sound:=test_stereo(t,m,RATE,proc(i:int) -> f32 {return 0.125})
    for bus in ([?]Bus{effected,plain}) {
        desc:=VOICE_DEFAULT
        desc.bus=bus
        voice_play(m,sound,desc)
    }
    first:=state(m)
    testing.expect(t,bus_set_effect(m,effected,1,{id=2,process=offset,params={0.25,0,0,0}}))
    testing.expect(t,bus_set_effect(m,effected,0,{id=1,process=scale,state=first,params={2,0,0,0}}))
    testing.expect(t,!bus_set_effect(m,effected,BUS_EFFECT_SLOTS,{id=1,process=scale}) && !bus_set_effect(m,effected,0,{id=1}))
    out:=test_render(m,CHUNK_FRAMES)
    // Both buses add up at the master: one with its effects, one as it comes.
    test_near(t,out[0],0.125*2+0.25+0.125)
    testing.expect_value(t,(^int)(raw_data(first))^,1)
    testing.expect(t,bus_set_effect_params(m,effected,0,{3,0,0,0}) && bus_effect(m,effected,0).params[0]==3)
    out=test_render(m,CHUNK_FRAMES)
    test_near(t,out[0],0.125*3+0.25+0.125)
    // Replaced: the old state is the audio thread's until it applied the change.
    second:=state(m)
    testing.expect(t,bus_set_effect(m,effected,0,{id=1,process=scale,state=second,params={1,0,0,0}}))
    mixer_update(m)
    testing.expect(t,m.effect_shadows[int(effected)*BUS_EFFECT_SLOTS].retired!=nil)
    testing.expect(t,!bus_set_effect(m,effected,0,{}),"a slot waits for its last state to be let go of")
    out=test_render(m,CHUNK_FRAMES)
    test_near(t,out[0],0.125+0.25+0.125)
    mixer_update(m)
    testing.expect(t,m.effect_shadows[int(effected)*BUS_EFFECT_SLOTS].retired==nil)
    // Taken out, the bus plays as it comes.
    testing.expect(t,bus_set_effect(m,effected,1,{}))
    out=test_render(m,CHUNK_FRAMES)
    test_near(t,out[0],0.125+0.125)
    testing.expect(t,bus_effect(m,plain,0).process==nil && bus_effect(m,effected,1).process==nil)
}
