package importer

import "core:fmt"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import audio "mirai:audio"

// The sounds of the demo and of the game template as the importer stores them, and the Vorbis
// test files a short Ogg keeps as its file, in a mixer: memory held, the cost of a start, the
// audio thread and the decoder per 10 ms with 1, 32 and 256 voices, and the worst render of a
// minute in real time under storms of starts. COOK_BENCH=true.
@(test)
bench_sounds_in_the_mixer :: proc(t:^testing.T) {
    if !BENCH {return}
    Named :: struct {name:string,bytes:[]u8}
    sources:=[?]Named{
        {"hum.wav (demo)",#load("../../demo/assets/showcase/hum.wav")},
        {"shot.wav (template)",#load("../../templates/game/assets/weapon/shot.wav")},
        {"tone_long.ogg",#load("../../audio/testdata/tone_long.ogg")},
        {"sine_stereo.ogg",#load("../../audio/testdata/sine_stereo.ogg")},
        {"intro_tone.ogg",#load("../../audio/testdata/intro_tone.ogg")},
        {"click.ogg",#load("../../audio/testdata/click.ogg")},
    }
    payloads:[len(sources)][]u8
    coded:[len(sources)]bool
    for source,i in sources {
        desc,error:=sound_build(source.bytes,.Smallest,context.allocator)
        testing.expect_value(t,error,audio.Error.None)
        payloads[i]=desc.lossless if len(desc.lossless)>0 else desc.file
        coded[i]=len(desc.lossless)>0
        fmt.printfln("%-20s source %7d bytes, stored %7d bytes as %s, %d frames at %d Hz",source.name,len(source.bytes),len(payloads[i]),"lossless" if len(desc.lossless)>0 else "its file",desc.frames,desc.sample_rate)
    }
    defer for payload,i in payloads {if coded[i] {delete(payload)}}

    // Memory held once loaded.
    {
        m,_:=audio.mixer_create({})
        defer audio.mixer_destroy(m)
        total:=0
        for payload,i in payloads {
            before:=audio.mixer_stats(m).sound_bytes
            _,error:=audio.sound_load(m,payload)
            testing.expect_value(t,error,audio.Error.None)
            held:=audio.mixer_stats(m).sound_bytes-before
            total+=len(payload)
            fmt.printfln("%-20s loaded: %8d bytes held (%5.2fx what it stores)",sources[i].name,held,f64(held)/f64(len(payload)))
        }
        fmt.printfln("all loaded: %d bytes held for %d bytes stored",audio.mixer_stats(m).sound_bytes,total)
    }

    // A start: voice_play on a mixer that decodes on the calling thread, the voice ready to sound.
    for payload,i in payloads {
        m,_:=audio.mixer_create({voice_capacity=64})
        defer audio.mixer_destroy(m)
        sound,_:=audio.sound_load(m,payload)
        out:=make([]f32,256*2,context.temp_allocator)
        times:[64]f64
        for &sample in times {
            start:=time.tick_now()
            voice:=audio.voice_play(m,sound)
            sample=time.duration_microseconds(time.tick_since(start))
            testing.expect(t,voice!=0)
        }
        audio.mixer_render(m,out)
        slice.sort(times[:])
        fmt.printfln("%-20s start: median %7.1f us, worst %7.1f us",sources[i].name,times[32],times[63])
    }

    // Per 10 ms with every voice playing, looped, at pitches around 1.
    for count in ([?]int{1,32,256}) {
        RUNS :: 1000
        m,_:=audio.mixer_create({voice_capacity=count,command_capacity=4096})
        defer audio.mixer_destroy(m)
        sounds:[len(payloads)]audio.Sound
        for payload,i in payloads {sounds[i],_=audio.sound_load(m,payload)}
        for i in 0..<count {
            desc:=audio.VOICE_DEFAULT
            desc.loop=true;desc.volume=0.01;desc.pitch=0.9+f32(i%5)*0.05;desc.offset=f64(i)*0.003
            testing.expect(t,audio.voice_play(m,sounds[i%len(sounds)],desc)!=0)
        }
        out:=make([]f32,480*2,context.temp_allocator)
        render,decoding:=make([]f64,RUNS,context.temp_allocator),make([]f64,RUNS,context.temp_allocator)
        for run in 0..<RUNS {
            start:=time.tick_now()
            audio.mixer_decode(m)
            decoding[run]=time.duration_microseconds(time.tick_since(start))
            start=time.tick_now()
            audio.mixer_render(m,out)
            render[run]=time.duration_microseconds(time.tick_since(start))
        }
        testing.expect_value(t,audio.mixer_stats(m).voices_active,count)
        slice.sort(render);slice.sort(decoding)
        fmt.printfln("%3d voices per 10 ms: render median %7.1f us, 99th %7.1f us; decoder median %7.1f us, 99th %7.1f us; underruns %d",
            count,render[RUNS/2],render[RUNS*99/100],decoding[RUNS/2],decoding[RUNS*99/100],audio.mixer_stats(m).underruns)
    }

    // A minute in real time: the audio thread renders 10 ms every 10 ms; the game thread updates
    // every 16 ms, keeps 24 loops playing and every half second starts 64 shots on one tick.
    {
        m,_:=audio.mixer_create({voice_capacity=128,command_capacity=4096,decoder_thread=true})
        defer audio.mixer_destroy(m)
        sounds:[len(payloads)]audio.Sound
        for payload,i in payloads {sounds[i],_=audio.sound_load(m,payload)}
        Shared :: struct {m:^audio.Mixer,quit:bool,worst,total:f64,renders:int}
        shared:=Shared{m=m}
        audio_thread:=thread.create_and_start_with_data(&shared,proc(data:rawptr) {
            s:=(^Shared)(data)
            out:=make([]f32,480*2)
            defer delete(out)
            next:=time.tick_now()
            for !sync.atomic_load(&s.quit) {
                start:=time.tick_now()
                audio.mixer_render(s.m,out)
                spent:=time.duration_microseconds(time.tick_since(start))
                s.worst=max(s.worst,spent);s.total+=spent;s.renders+=1
                next=time.tick_add(next,10*time.Millisecond)
                if wait:=time.tick_diff(time.tick_now(),next);wait>0 {time.sleep(wait)}
            }
        })
        for i in 0..<24 {
            desc:=audio.VOICE_DEFAULT
            desc.loop=true;desc.volume=0.01;desc.offset=f64(i)*0.01
            audio.voice_play(m,sounds[i%len(sounds)],desc)
        }
        started,refused:=0,0
        begin:=time.tick_now()
        for tick:=0;time.duration_seconds(time.tick_since(begin))<60;tick+=1 {
            audio.mixer_update(m)
            if tick%30==0 {
                audio.mixer_batch_begin(m)
                for i in 0..<64 {
                    desc:=audio.VOICE_DEFAULT
                    desc.volume=0.01;desc.pitch=0.9+f32(i%5)*0.05
                    if audio.voice_play(m,sounds[1],desc)!=0 {started+=1} else {refused+=1}
                }
                audio.mixer_batch_end(m)
            }
            time.sleep(16*time.Millisecond)
        }
        sync.atomic_store(&shared.quit,true)
        thread.destroy(audio_thread)
        stats:=audio.mixer_stats(m)
        fmt.printfln("a minute of storms: %d renders, worst %.1f us, mean %.1f us; %d shots started, %d refused, %d stolen; underruns %d",
            shared.renders,shared.worst,shared.total/f64(max(shared.renders,1)),started,refused,stats.voices_stolen,stats.underruns)
    }
}
