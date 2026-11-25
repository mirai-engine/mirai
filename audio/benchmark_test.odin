package mirai_audio

import "core:fmt"
import "core:math"
import "core:slice"
import "core:testing"
import "core:time"

AUDIO_BENCHMARK :: #config(AUDIO_BENCHMARK,false)

@(private="file")
Scenario :: enum {
    // Sounds at the rate of the mixer, as every imported one is: at their own pitch they are
    // copied, at another resampled.
    Mono_Direct,Mono_Pitched,Stereo_Direct,Stereo_Pitched,
    // Spatial voices that move every 10 ms: within 2.5 m and in sight, 30 to 50 m away, or hidden.
    Speakers_Near,Speakers_Far,Speakers_Occluded,Headphones_Near,Headphones_Far,Headphones_Occluded,
    Mixed_Buses,
}

// Time to mix 10 ms of audio (480 frames at 48 kHz) with every voice playing.
@(test)
benchmark_mixing_ten_milliseconds :: proc(t:^testing.T) {
    if !AUDIO_BENCHMARK {return}
    FRAMES :: 480
    RUNS :: 2000
    out:=make([]f32,FRAMES*2)
    defer delete(out)
    times:=make([]f64,RUNS)
    defer delete(times)
    for scenario in Scenario {
        for count in ([?]int{64,256}) {
            headphones:=scenario>=.Headphones_Near && scenario<=.Headphones_Occluded
            spatial:=scenario>=.Speakers_Near && scenario<=.Headphones_Occluded
            far:=scenario==.Speakers_Far || scenario==.Headphones_Far
            m:=test_mixer(t,{voice_capacity=count,command_capacity=4096,output=.Headphones if headphones else .Speakers})
            defer mixer_destroy(m)
            mono:=test_mono(t,m,RATE,proc(i:int) -> f32 {return 0.01*math.sin_f32(f32(i)*0.05)})
            stereo:=test_stereo(t,m,RATE,proc(i:int) -> f32 {return 0.01*math.sin_f32(f32(i)*0.05)})
            buses:[3]Bus
            for &bus in buses {bus,_=bus_create(m)}
            if scenario==.Mixed_Buses {
                bus_set_filter(m,buses[0],0,{kind=.Lowpass,frequency=4000})
                bus_set_filter(m,buses[1],0,{kind=.Lowpass,frequency=800})
                bus_set_filter(m,buses[1],1,{kind=.Peak,frequency=2000,q=1,gain=-6})
                bus_set_delay(m,buses[1],{seconds=0.25,feedback=0.4,wet=0.3})
                bus_set_duck(m,buses[0],{source=buses[2],threshold=0.001,amount=0.5,attack=0.01,release=0.2})
            }
            voices:=make([]Voice,count,context.temp_allocator)
            for &voice,i in voices {
                desc:=VOICE_DEFAULT
                desc.loop=true
                desc.pan=f32(i%9)/4-1
                desc.offset=f64(i)*0.003
                sound:=mono
                switch scenario {
                case .Mono_Direct:
                case .Mono_Pitched:desc.pitch=0.8+f32(i%8)*0.05
                case .Stereo_Direct:sound=stereo
                case .Stereo_Pitched:sound=stereo;desc.pitch=0.8+f32(i%8)*0.05
                case .Speakers_Near,.Speakers_Far,.Speakers_Occluded,.Headphones_Near,.Headphones_Far,.Headphones_Occluded:
                    desc.spatial=true;desc.doppler=1
                    desc.position=bench_place(i,0,far)
                    if scenario==.Speakers_Occluded || scenario==.Headphones_Occluded {desc.occlusion=1}
                case .Mixed_Buses:
                    sound=stereo if i%4==1 else mono;desc.pitch=0.9 if i%2==0 else 1
                    desc.bus=buses[i%3];desc.spatial=i%4==0;desc.position={f32(i%16)-8,0,-2}
                }
                voice=voice_play(m,sound,desc)
            }
            testing.expect_value(t,mixer_stats(m).commands_dropped,u64(0))
            mixer_render(m,out)
            testing.expect_value(t,mixer_stats(m).voices_active,count)
            for &sample,run in times {
                if spatial {
                    // Every voice and the listener move every 10 ms: all positions are worked out again.
                    for voice,i in voices {voice_set_position(m,voice,bench_place(i,run,far),{1,0,0})}
                    listener_set(m,{f32(run%50)*0.01,0,0},1)
                }
                start:=time.tick_now()
                mixer_render(m,out)
                sample=f64(time.duration_microseconds(time.tick_since(start)))
            }
            slice.sort(times)
            fmt.printfln("%-17v %3d voices: median %7.1f us, best %7.1f us, 99th percentile %7.1f us (%.2f%% of 10 ms)",scenario,count,times[RUNS/2],times[0],times[RUNS*99/100],times[RUNS/2]/100)
        }
    }
}

// Where spatial voice i is in run: around the listener, ahead, drifting.
@(private="file")
bench_place :: proc(i,run:int,far:bool) -> [3]f32 {
    near:=[3]f32{f32(i%5)*0.5-1+f32(run%100)*0.005,f32(i%3)*0.3-0.3,-1.5-f32(i%4)*0.25}
    return near*20 if far else near
}
