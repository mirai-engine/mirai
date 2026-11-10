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
    testing.expect(t,!bus_set_volume(m,missing,1) && !bus_set_mute(m,missing,true) && !bus_set_lowpass(m,missing,100))
    testing.expect(t,bus_volume(m,missing)==0 && !bus_muted(m,missing) && bus_lowpass(m,missing)==0)
    testing.expect(t,!bus_set_duck(m,missing,{source=BUS_MASTER,amount=1}))
    testing.expect(t,!bus_set_duck(m,first,{source=missing,amount=1}))
    testing.expect(t,!bus_set_duck(m,first,{source=first,amount=1}))
    testing.expect(t,!bus_set_duck(m,BUS_MASTER,{source=first,amount=1}))
}

@(private="file") tone_low :: proc(i:int) -> f32 {return math.sin_f32(2*math.PI*100*f32(i)/RATE)}
@(private="file") tone_cut :: proc(i:int) -> f32 {return math.sin_f32(2*math.PI*1000*f32(i)/RATE)}
@(private="file") tone_high :: proc(i:int) -> f32 {return math.sin_f32(2*math.PI*8000*f32(i)/RATE)}

@(test)
bus_low_pass_keeps_the_lows_and_removes_the_highs :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    bus,_:=bus_create(m)
    testing.expect(t,bus_set_lowpass(m,bus,1000))
    testing.expect_value(t,bus_lowpass(m,bus),f32(1000))
    desc:=VOICE_DEFAULT
    desc.loop=true;desc.bus=bus
    // Whole periods in a second of sound: the loops are seamless.
    Case :: struct {tone:proc(i:int) -> f32,low,high:f32}
    full:=f32(math.SQRT_TWO/2) // RMS of a sine
    cases:=[?]Case{
        {tone_low,0.99*full,1.01*full},    // two decades below the cutoff
        {tone_cut,0.68*full,0.74*full},    // at the cutoff: -3 dB
        {tone_high,0,0.02*full},           // three octaves above: 12 dB per octave
    }
    for c in cases {
        voice:=voice_play(m,test_stereo(t,m,RATE,c.tone),desc)
        test_render(m,4800) // the filter settles
        out:=test_render(m,9600)
        level:=rms(out,0)
        testing.expectf(t,level>=c.low && level<=c.high,"RMS %v outside [%v,%v]",level,c.low,c.high)
        test_near(t,rms(out,1),level,1e-4)
        voice_stop(m,voice)
        test_render(m,4800)
        mixer_update(m)
    }
    // Turned off, the bus passes everything again.
    bus_set_lowpass(m,bus,0)
    voice_play(m,test_stereo(t,m,RATE,tone_high),desc)
    test_render(m,CHUNK_FRAMES)
    out:=test_render(m,9600)
    test_near(t,rms(out,0),full,1e-3)
    // A cutoff at or above half the sample rate is no filter.
    bus_set_lowpass(m,bus,RATE)
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,9600)
    test_near(t,rms(out,0),full,1e-3)
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
