package mirai_audio

import "core:math"
import "core:testing"

@(private="file") TONE :: f32(0.2) // under full scale with a peak of 12 dB
@(private="file") tone_100 :: proc(i:int) -> f32 {return TONE*math.sin_f32(2*math.PI*100*f32(i)/RATE)}
@(private="file") tone_1k :: proc(i:int) -> f32 {return TONE*math.sin_f32(2*math.PI*1000*f32(i)/RATE)}
@(private="file") tone_8k :: proc(i:int) -> f32 {return TONE*math.sin_f32(2*math.PI*8000*f32(i)/RATE)}

@(private="file")
rms :: proc(out:[]f32,channel:int) -> f32 {
    sum:=f64(0)
    for i in 0..<len(out)/2 {sum+=f64(out[i*2+channel])*f64(out[i*2+channel])}
    return f32(math.sqrt(sum/f64(len(out)/2)))
}

// Each kind of band at 1 kHz, by the gain it gives a tone below, at and above
// it: what the Audio EQ Cookbook's responses say, measured in the mix.
@(test)
bus_filters_shape_the_tones_as_their_kind_says :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    bus,_:=bus_create(m)
    desc:=VOICE_DEFAULT
    desc.loop=true;desc.bus=bus
    tones:=[3]proc(i:int) -> f32{tone_100,tone_1k,tone_8k}
    Case :: struct {filter:Filter,gains:[3][2]f32} // per tone: the lowest and highest gain
    cases:=[?]Case{
        {{kind=.Lowpass,frequency=1000},{{0.99,1.01},{0.68,0.74},{0,0.02}}},
        {{kind=.Highpass,frequency=1000},{{0,0.02},{0.68,0.74},{0.99,1.02}}},
        {{kind=.Bandpass,frequency=1000},{{0.12,0.16},{0.98,1.02},{0.13,0.19}}},
        {{kind=.Peak,frequency=1000,q=1,gain=12},{{0.99,1.08},{3.9,4.05},{0.99,1.05}}},
        {{kind=.Peak,frequency=1000,q=1,gain=-12},{{0.93,1.01},{0.24,0.26},{0.95,1.01}}},
        {{kind=.Off,frequency=1000},{{0.999,1.001},{0.999,1.001},{0.999,1.001}}},
        // A low-pass at or above half the sample rate is no filter.
        {{kind=.Lowpass,frequency=RATE},{{0.999,1.001},{0.999,1.001},{0.999,1.001}}},
    }
    full:=TONE*math.SQRT_TWO/2 // RMS of the tone
    for c in cases {
        for band in 0..<BUS_FILTERS {
            testing.expect(t,bus_set_filter(m,bus,band,c.filter if band==1 else {}))
        }
        testing.expect_value(t,bus_filter(m,bus,1),c.filter)
        for tone,i in tones {
            voice:=voice_play(m,test_stereo(t,m,RATE,tone),desc)
            test_render(m,4800) // the filter settles
            out:=test_render(m,9600)
            gain:=rms(out,0)/full
            testing.expectf(t,gain>=c.gains[i][0] && gain<=c.gains[i][1],"%v, tone %d: gain %v outside %v",c.filter.kind,i,gain,c.gains[i])
            test_near(t,rms(out,1),rms(out,0),1e-4)
            voice_stop(m,voice)
            test_render(m,4800)
            mixer_update(m)
        }
    }
    // A value that is not a number, or a band that is not one, is refused.
    nan:=math.nan_f32()
    testing.expect(t,!bus_set_filter(m,bus,0,{kind=.Lowpass,frequency=nan}))
    testing.expect(t,!bus_set_filter(m,bus,0,{kind=.Peak,frequency=100,gain=60}))
    testing.expect(t,!bus_set_filter(m,bus,BUS_FILTERS,{kind=.Lowpass,frequency=100}))
    testing.expect(t,!bus_set_filter(m,bus,-1,{}))
}

// Bands of a chain swept every chunk crossfade: the wave never steps more
// than it does unfiltered.
@(test)
bus_filter_chain_sweeps_without_steps :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    bus,_:=bus_create(m)
    desc:=VOICE_DEFAULT
    desc.loop=true;desc.bus=bus
    voice_play(m,test_stereo(t,m,RATE,tone_100),desc)
    last:f32
    largest_step :: proc(out:[]f32,last:^f32) -> (step:f32) {
        for k in 0..<len(out)/2 {step=max(step,abs(out[k*2]-last^));last^=out[k*2]}
        return
    }
    unfiltered:=largest_step(test_render(m,4800),&last)
    swept:f32
    for hz:=f32(16000);hz>300;hz*=0.8 {
        bus_set_filter(m,bus,0,{kind=.Highpass,frequency=hz*0.002})
        bus_set_filter(m,bus,1,{kind=.Peak,frequency=hz,q=2,gain=-6})
        bus_set_filter(m,bus,2,{kind=.Lowpass,frequency=hz})
        swept=max(swept,largest_step(test_render(m,CHUNK_FRAMES),&last))
    }
    // A coefficient that jumped would step by about the amplitude of the sine.
    testing.expectf(t,swept<=unfiltered*1.5,"the sweep steps by %v, the sine by %v",swept,unfiltered)
}

// Which buses are heard by their mutes and solos: a soloed bus, those that
// play into it and those it plays through to the master; the master always.
@(test)
bus_solo_and_mute_choose_what_is_heard :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    a,_:=bus_create(m) // into the master
    b,_:=bus_create(m) // into the master
    c,_:=bus_create(m) // into a
    testing.expect(t,bus_set_send(m,c,a))
    unit:=f32(1.0/2048) // all of them under full scale
    one:=test_stereo(t,m,64,test_one)
    desc:=VOICE_DEFAULT
    desc.loop=true
    // Levels that tell the buses apart in their sum.
    for level,bus in ([4]f32{1000,1,10,100}) {
        desc.bus=Bus(bus);desc.volume=level*unit
        voice_play(m,one,desc)
    }
    Case :: struct {solo,mute:[4]bool,silent:[4]bool,heard:f32}
    cases:=[?]Case{
        {heard=1111},
        {solo={false,true,false,false},silent={false,false,true,false},heard=1101},
        {solo={false,false,true,false},silent={false,true,false,true},heard=1010},
        {solo={false,false,false,true},silent={false,false,true,false},heard=1101},
        {solo={false,true,true,false},heard=1111},
        {mute={false,true,false,false},silent={false,true,false,false},heard=1010},
        {solo={false,false,false,true},mute={false,true,false,false},silent={false,true,true,false},heard=1000},
        {mute={true,false,false,false},silent={true,false,false,false},heard=0},
    }
    for c,i in cases {
        for bus in 1..<4 {testing.expect(t,bus_set_solo(m,Bus(bus),c.solo[bus]))}
        for bus in 0..<4 {testing.expect(t,bus_set_mute(m,Bus(bus),c.mute[bus]))}
        for bus in 0..<4 {
            testing.expectf(t,bus_silent(m,Bus(bus))==c.silent[bus],"case %d: bus %d silent %v",i,bus,bus_silent(m,Bus(bus)))
            testing.expect(t,bus_soloed(m,Bus(bus))==c.solo[bus] && bus_muted(m,Bus(bus))==c.mute[bus])
        }
        test_render(m,CHUNK_FRAMES)
        out:=test_render(m,4)
        testing.expectf(t,abs(out[0]-c.heard*unit)<1e-4,"case %d: heard %v, want %v",i,out[0]/unit,c.heard)
    }
    testing.expect(t,!bus_set_solo(m,BUS_MASTER,true))
}

// A meter holds the peak of each channel of what a bus played, after its
// volume, and falls METER_FALL dB a second once it is quiet.
@(test)
bus_meter_holds_and_falls :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    bus,_:=bus_create(m)
    bus_set_volume(m,bus,0.5)
    test_render(m,CHUNK_FRAMES)
    desc:=VOICE_DEFAULT
    desc.bus=bus;desc.loop=true;desc.pan=0
    voice:=voice_play(m,test_stereo(t,m,RATE,tone_1k),desc)
    testing.expect_value(t,bus_meter(m,bus),[2]f32{})
    test_render(m,4800)
    meter:=bus_meter(m,bus)
    test_near(t,meter[0],TONE*0.5,1e-3)
    test_near(t,meter[1],TONE*0.5,1e-3)
    test_near(t,bus_meter(m,BUS_MASTER)[0],TONE*0.5,1e-3)
    voice_stop(m,voice)
    test_render(m,CHUNK_FRAMES)
    held:=bus_meter(m,bus)[0]
    test_render(m,RATE/2)
    // Half a second later, METER_FALL/2 dB lower.
    test_near(t,bus_meter(m,bus)[0],held*math.pow(10,-METER_FALL/40),1e-3)
    testing.expect_value(t,bus_meter(m,Bus(99)),[2]f32{})
}

// The low-pass of a voice dulls only it, and moves without steps.
@(test)
voice_low_pass_dulls_the_voice :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    desc:=VOICE_DEFAULT
    desc.loop=true;desc.lowpass=1000
    high:=test_stereo(t,m,RATE,tone_8k)
    dulled:=voice_play(m,high,desc)
    test_render(m,4800)
    full:=TONE*math.SQRT_TWO/2
    testing.expect(t,rms(test_render(m,9600),0)<0.02*full)
    // Taken out, the voice plays as it is.
    testing.expect(t,voice_set_lowpass(m,dulled,0))
    test_render(m,CHUNK_FRAMES)
    test_near(t,rms(test_render(m,9600),0),full,1e-3)
    testing.expect(t,!voice_set_lowpass(m,dulled,math.nan_f32()))
    desc.lowpass=math.inf_f32(1)
    testing.expect_value(t,voice_play(m,high,desc),Voice(0))
    voice_stop(m,dulled)
    test_render(m,CHUNK_FRAMES)
    mixer_update(m)
    // A sweep of its cutoff every chunk.
    desc.lowpass=16000
    low:=voice_play(m,test_stereo(t,m,RATE,tone_100),desc)
    last:f32
    largest_step :: proc(out:[]f32,last:^f32) -> (step:f32) {
        for k in 0..<len(out)/2 {step=max(step,abs(out[k*2]-last^));last^=out[k*2]}
        return
    }
    unfiltered:=largest_step(test_render(m,4800),&last)
    swept:f32
    for hz:=f32(16000);hz>300;hz*=0.7 {
        voice_set_lowpass(m,low,hz)
        swept=max(swept,largest_step(test_render(m,CHUNK_FRAMES),&last))
    }
    testing.expectf(t,swept<=unfiltered*1.05,"the sweep steps by %v, the sine by %v",swept,unfiltered)
}

// Voices played in a batch start in the same chunk even when the audio thread
// renders between them; outside of one, the second would wait a chunk.
@(test)
batch_starts_voices_in_the_same_frame :: proc(t:^testing.T) {
    for batched in ([2]bool{true,false}) {
        m:=test_mixer(t)
        defer mixer_destroy(m)
        one:=test_stereo(t,m,CHUNK_FRAMES*4,test_one)
        desc:=VOICE_DEFAULT
        desc.volume=0.25
        test_render(m,10)
        if batched {mixer_batch_begin(m)}
        voice_play(m,one,desc)
        first:=test_render(m,CHUNK_FRAMES)
        voice_play(m,one,desc)
        if batched {mixer_batch_end(m)}
        out:=test_render(m,CHUNK_FRAMES)
        if batched {
            testing.expect_value(t,first[0],f32(0))
            test_near(t,out[0],0.5)
            test_near(t,out[(CHUNK_FRAMES-1)*2],0.5)
        } else {
            test_near(t,first[0],0.25)
            test_near(t,out[0],0.5)
        }
    }
}
