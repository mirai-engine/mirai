package echo

import "base:runtime"
import "core:testing"
import "mirai:core"
import mixer "mirai:audio"
import audio "mirai:engine/audio"

// The allocations of what it wraps, counted.
@(private="file")
Counting :: struct {backing:runtime.Allocator,count,bytes:int}
@(private="file")
counting :: proc(c:^Counting) -> runtime.Allocator {
    count :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        c:=(^Counting)(data)
        if mode==.Alloc || mode==.Alloc_Non_Zeroed {c.count+=1;c.bytes+=size}
        return c.backing.procedure(c.backing.data,mode,size,alignment,old,old_size,loc)
    }
    return {count,c}
}
@(private="file")
render :: proc(m:^mixer.Mixer,frames:int) -> []f32 {
    out:=make([]f32,frames*2,context.temp_allocator)
    mixer.mixer_render(m,out)
    mixer.mixer_update(m)
    return out
}

// A bus with an echo plays an impulse, then its echoes every delay, each
// feedback times the last, scaled by wet; a bus without one reserves nothing
// for it and plays as it comes; taken out, the echo fades and its line is freed.
@(test)
a_bus_echoes_what_plays_and_one_without_reserves_nothing :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    allocations:=Counting{backing=context.allocator}
    m,error:=mixer.mixer_create({allocator=counting(&allocations)})
    if !testing.expect_value(t,error,mixer.Error.None) {return}
    defer mixer.mixer_destroy(m)
    problems:core.Problems
    // No echoes: nothing reserved.
    before:=allocations
    testing.expect(t,echoes_apply(m,nil,&problems) && echoes_apply(m,&Bus_Echoes{},&problems))
    testing.expect_value(t,allocations.count,before.count)
    echoes:=Bus_Echoes{echoes={0={bus=audio.BUS_MUSIC,seconds=0.01,feedback=0.5,wet=0.8},1={bus=audio.BUS_VOICE,seconds=1}}}
    before=allocations
    testing.expect(t,echoes_apply(m,&echoes,&problems))
    // One line, of the bus with a wet echo, as long as its seconds ask.
    testing.expect_value(t,allocations.count,before.count+1)
    testing.expect_value(t,allocations.bytes-before.bytes,line_bytes(0.01,mixer.MIXER_RATE))
    testing.expect(t,line_bytes(0.01,mixer.MIXER_RATE)<16*1024)
    for bus in 0..<audio.AUDIO_BUS_CAPACITY {
        effect:=audio.bus_effect(m,audio.Audio_Bus(bus),0)
        testing.expectf(t,(effect.id==ECHO_EFFECT)==(audio.Audio_Bus(bus)==audio.BUS_MUSIC),"bus %d: %v",bus,effect.id)
    }
    // Applied again unchanged, nothing more.
    before=allocations
    testing.expect(t,echoes_apply(m,&echoes,&problems))
    testing.expect_value(t,allocations.count,before.count)
    for mixer.bus_count(m)<audio.AUDIO_BUS_CAPACITY {mixer.bus_create(m)}
    click,_:=mixer.sound_create(m,{0.5,-0.5},2,mixer.MIXER_RATE)
    for bus in ([?]audio.Audio_Bus{audio.BUS_MUSIC,audio.BUS_EFFECTS}) {
        desc:=mixer.VOICE_DEFAULT
        desc.bus=mixer.Bus(bus)
        desc.volume=1 if bus==audio.BUS_MUSIC else 0.25
        mixer.voice_play(m,click,desc)
    }
    out:=render(m,1500)
    Echo_At :: struct {frame:int,level:f32}
    for echo in ([?]Echo_At{{0,0.5+0.125},{1,0},{479,0},{480,0.4},{481,0},{960,0.2},{1440,0.1}}) {
        testing.expectf(t,abs(out[echo.frame*2]-echo.level)<1e-6 && abs(out[echo.frame*2+1]+echo.level)<1e-6,"frame %d: %v, not %v",echo.frame,out[echo.frame*2],echo.level)
    }
    // A longer time takes a longer line, in place of the old one.
    echoes.echoes[0].seconds=0.5
    testing.expect(t,echoes_apply(m,&echoes,&problems))
    testing.expect_value(t,len(audio.bus_effect(m,audio.BUS_MUSIC,0).state),line_bytes(0.5,mixer.MIXER_RATE))
    render(m,mixer.CHUNK_FRAMES)
    // Taken out: its echoes fade over a chunk, and then it goes.
    echoes.echoes[0].wet=0
    testing.expect(t,!echoes_apply(m,&echoes,&problems))
    testing.expect_value(t,audio.bus_effect(m,audio.BUS_MUSIC,0).params[2],f32(0))
    render(m,mixer.CHUNK_FRAMES)
    testing.expect(t,!echoes_apply(m,&echoes,&problems))
    render(m,mixer.CHUNK_FRAMES)
    testing.expect(t,echoes_apply(m,&echoes,&problems))
    testing.expect(t,audio.bus_effect(m,audio.BUS_MUSIC,0).process==nil)
    testing.expect_value(t,problems.count,0)
}
