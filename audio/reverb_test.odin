package mirai_audio

import "core:math"
import "core:testing"

@(private="file")
tone :: proc(t:^testing.T,m:^Mixer,hz:f32,frames:int) -> Sound {
    samples:=make([]f32,frames,context.temp_allocator)
    for &sample,i in samples {sample=math.sin(2*math.PI*hz*f32(i)/RATE)*0.5}
    sound,error:=sound_create(m,samples,1,RATE)
    testing.expect_value(t,error,Error.None)
    return sound
}

@(private="file")
energy :: proc(samples:[]f32) -> (sum:f32) {
    for sample in samples {sum+=sample*sample}
    return
}

@(test)
what_a_voice_sends_rings_on_in_the_reverb_after_it_ends :: proc(t:^testing.T) {
    // A click, then what the room gives back after it.
    tail :: proc(t:^testing.T,send:f32,reverb:Reverb,muted:=false) -> f32 {
        m:=test_mixer(t)
        defer mixer_destroy(m)
        effects,_:=bus_create(m)
        testing.expect(t,reverb_set(m,reverb,effects))
        if muted {bus_set_mute(m,effects,true)}
        desc:=VOICE_DEFAULT
        desc.reverb=send
        testing.expect(t,voice_play(m,tone(t,m,440,CHUNK_FRAMES),desc)!=0)
        test_render(m,CHUNK_FRAMES)
        return energy(test_render(m,RATE/2))
    }
    room:=Reverb{room_size=0.8,damping=0.3,wet=1,width=1}
    rings:=tail(t,1,room)
    testing.expectf(t,rings>1e-4,"the room rings after the click: %v",rings)
    testing.expect_value(t,tail(t,0,room),f32(0))
    testing.expect_value(t,tail(t,1,{room_size=0.8,damping=0.3}),f32(0))
    testing.expect_value(t,tail(t,1,room,muted=true),f32(0))
    smaller:=room
    smaller.room_size=0.1
    testing.expectf(t,tail(t,1,smaller)<rings,"a smaller room rings for less")

    m:=test_mixer(t)
    defer mixer_destroy(m)
    testing.expect(t,!reverb_set(m,room,Bus(3)),"a bus that was not reserved is refused")
    testing.expect(t,reverb_set(m,{room_size=2,damping=-1,wet=-1,width=3}))
    got,bus:=reverb_get(m)
    testing.expect(t,got==Reverb{1,0,0,1} && bus==BUS_MASTER)
}

// A tail that rings down to silence passes through the subnormal floats, which
// x86 computes about a hundred times slower: the render counts them as zero.
@(test)
a_reverb_tail_rings_down_to_zeros_without_subnormals :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    testing.expect(t,reverb_set(m,{wet=1,width=1}))
    desc:=VOICE_DEFAULT
    desc.reverb=1
    testing.expect(t,voice_play(m,tone(t,m,440,CHUNK_FRAMES),desc)!=0)
    subnormals:=0
    for _ in 0..<100 {
        test_render(m,RATE/10)
        for sample in m.reverb.memory {
            bits:=transmute(u32)sample
            if bits&0x7f80_0000==0 && bits&0x007f_ffff!=0 {subnormals+=1}
        }
    }
    testing.expect_value(t,subnormals,0)
    silent:=true
    for sample in m.reverb.memory {silent&&=sample==0}
    testing.expect(t,silent,"ten seconds after the click the room holds zeros")
}

@(test)
the_reverb_of_a_bus_rings_on_what_plays_in_it_alone :: proc(t:^testing.T) {
    tail :: proc(t:^testing.T,on_music:bool,wet:f32) -> f32 {
        m:=test_mixer(t)
        defer mixer_destroy(m)
        music,_:=bus_create(m)
        effects,_:=bus_create(m)
        testing.expect(t,bus_set_reverb(m,music,{room_size=0.85,damping=0.2,wet=wet,width=1}))
        desc:=VOICE_DEFAULT
        desc.bus=music if on_music else effects
        testing.expect(t,voice_play(m,tone(t,m,440,CHUNK_FRAMES),desc)!=0)
        test_render(m,CHUNK_FRAMES)
        return energy(test_render(m,RATE/2))
    }
    testing.expect(t,tail(t,true,1)>1e-4,"a song in a bus with a reverb rings on")
    testing.expect_value(t,tail(t,false,1),f32(0))
    testing.expect_value(t,tail(t,true,0),f32(0))
    m:=test_mixer(t)
    defer mixer_destroy(m)
    testing.expect(t,!bus_set_reverb(m,Bus(5),{wet=1}),"a bus that was not reserved is refused")
    testing.expect(t,bus_set_reverb(m,BUS_MASTER,{room_size=0.5,wet=2}))
    testing.expect(t,bus_reverb(m,BUS_MASTER)==Reverb{0.5,0,2,0})
}
