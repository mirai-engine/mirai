package vfx

import "core:fmt"
import "core:math"
import "core:strings"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"

// Births a game gives particles by channel (core.Births): one emitter, many
// births, each where and how the game says. Each emitter whose
// Particle_Channel names the channel of a birth starts particles of its
// effect at it, and a Vfx program reads those of the channel of a resource of
// kind channel with its name (`//! resource name channel`).
// particles_tick numbers the births of each channel in the world, as the
// clocks number theirs, and particles_sync starts on the GPU only those it
// did not start: a rollback that pushes them again does not draw them twice.
// A channel keeps the births of its last ticks, CHANNEL_BIRTHS at most;
// older ones are lost and counted.

CHANNEL_BIRTHS :: 1024

// The channel an emitter starts particles of its effect from: at each birth
// pushed to it, count of them where the birth is, besides its own. A silent
// one starts none: its program reads the births alone, by a resource of
// kind channel of the same name.
@(component)
Particle_Channel :: struct {
    name:core.Birth_Channel,
    silent:bool, // its effect starts no particles at the births
}

Channel_Record :: struct {
    birth:core.Birth,
    time:f64, // seconds of the world when it was born; negative: not known (the editor), it starts as it is
}

// The births of a channel some emitter listens to, numbered.
Channel_Ring :: struct {
    name:core.Birth_Channel,
    records:[CHANNEL_BIRTHS]Channel_Record,
    start,count:u32,
    emitted:u64, // births since the channel began: the number of the next
    lost:u64,    // births lost because the ring was full
}

// The births of a step into the channels the emitters of the world listen to.
@(private)
channels_step :: proc(clocks:^Particle_Clocks,pushed:[]core.Birth,listeners:core.Read(Particle_Channel),time:core.Time) {
    // The rings follow the channels some emitter names.
    for i:=len(clocks.channels)-1;i>=0;i-=1 {
        named:=false
        for row in 0..<core.count(listeners) {named||=core.at(listeners,row).name==clocks.channels[i].name}
        if !named {unordered_remove(&clocks.channels,i)}
    }
    for row in 0..<core.count(listeners) {
        name:=core.at(listeners,row).name
        if channel_ring(clocks,name)==nil {append(&clocks.channels,Channel_Ring{name=name})}
    }
    at:=time.playing?time.seconds+f64(time.dt):-1
    for &birth in pushed {
        if ring:=channel_ring(clocks,birth.channel);ring!=nil {ring_record(ring,birth,at)}
    }
}

// A birth into a ring, at the seconds of the world; negative: not known.
@(private)
ring_record :: proc(ring:^Channel_Ring,birth:core.Birth,at:f64) {
    if ring.count==CHANNEL_BIRTHS {
        ring.start=(ring.start+1)%CHANNEL_BIRTHS
        ring.count-=1
        ring.lost+=1
    }
    ring.records[(ring.start+ring.count)%CHANNEL_BIRTHS]={birth=birth,time=at}
    ring.count+=1
    ring.emitted+=1
}

// Particles a birth of the preview of a listening emitter starts.
CHANNEL_PREVIEW_COUNT :: 16

// In the editor, while the world does not play, an emitter that starts particles at
// the births of its channel gets one at itself as each cycle of its effect begins:
// nothing else gives it births there, and it shows where it stands.
@(private)
channel_preview :: proc(clocks:^Particle_Clocks,listener:Particle_Channel,position:[3]f32,before,after,duration:f64) {
    if listener.silent {return}
    cycle:=max(duration,0.5)
    if before>0 && math.floor(before/cycle)==math.floor(after/cycle) {return}
    if ring:=channel_ring(clocks,listener.name);ring!=nil {ring_record(ring,{position=position,count=CHANNEL_PREVIEW_COUNT},-1)}
}

// The channels the resources of kind channel of a program read: those whose
// constants have the names the program gives them (`//! resource displacers
// channel` reads CHANNEL_DISPLACERS).
@(private)
channel_needs :: proc(a:^host.Assets,program:^Program,needs:^Program_Needs,info:^core.World_Info) -> (problem:string) {
    found:=erender.program_find(a,base.text_get(program.name[:]),.Vfx) if a!=nil && program.id!=0 else nil
    if found==nil {return}
    for resource,at in found.resources[:min(len(found.resources),RESOURCES)] {
        need:=&needs.resources[at]
        if need.kind!=.Channel {continue}
        value,named:=core.name_value(info,core.Birth_Channel,resource.name)
        need.channel=core.Birth_Channel(value)
        if !named && problem=="" {
            problem=fmt.tprintf("Vfx program %s reads the channel %q, which no constant of core.Birth_Channel names: declare CHANNEL_%s :: core.Birth_Channel(n), n from %d in a game",base.text_get(program.name[:]),resource.name,strings.to_upper(resource.name,context.temp_allocator),core.CHANNEL_GAME)
        }
    }
    return
}

channel_ring :: proc(clocks:^Particle_Clocks,name:core.Birth_Channel) -> ^Channel_Ring {
    for &ring in clocks.channels {if ring.name==name {return &ring}}
    return nil
}

// shaders/particles.slang: Particle_Birth.
Gpu_Birth :: struct {
    position:[3]f32, size:f32,
    velocity:[3]f32, age:f32, // seconds it is old at the end of the frame
    color:[4]f32,
    values:[4]f32,
    count,number:u32,         // particles, and its number in its channel
    pad:[2]u32,
}
#assert(size_of(Gpu_Birth)==80)

// Where the births of a channel are among those of the frame.
Channel_Region :: struct {
    name:core.Birth_Channel,
    first,count:u32,
}

// What the GPU started of a channel.
Channel_Started :: struct {
    name:core.Birth_Channel,
    started:u64,
}

// The births of each channel the GPU did not start, into the births of the
// frame, and where each channel has them. now: the seconds of the world.
@(private)
channels_sync :: proc(sync:^Particle_Sync,clocks:^Particle_Clocks,now:f64,problems:^core.Problems) {
    clear(&sync.births)
    clear(&sync.regions)
    if clocks==nil {return}
    for &ring in clocks.channels {
        started:^u64
        for &entry in sync.started {if entry.name==ring.name {started=&entry.started}}
        if started==nil {
            if _,err:=append(&sync.started,Channel_Started{name=ring.name});err!=nil {
                core.report(problems,core.NONE,"vfx.memory","out of memory for a channel of particles; its births wait for the next frame: free memory")
                continue
            }
            started=&sync.started[len(sync.started)-1].started
        }
        // A rollback that pushed again fewer than were started: what comes next starts.
        if ring.emitted<started^ {started^=ring.emitted}
        oldest:=ring.emitted-u64(ring.count)
        first:=u32(len(sync.births))
        for number in max(started^,oldest)..<ring.emitted {
            record:=&ring.records[(u64(ring.start)+number-oldest)%CHANNEL_BIRTHS]
            b:=record.birth
            color:=b.color if b.color!={} else {1,1,1,1}
            append(&sync.births,Gpu_Birth{
                position=b.position,size=b.size>0?b.size:1,velocity=b.velocity,
                age=record.time>=0?f32(clamp(now-record.time,0,f64(FRAME_MAX)*4)):0,
                color=color,values=b.values,count=max(b.count,1),number=u32(number),
            })
        }
        started^=ring.emitted
        if count:=u32(len(sync.births))-first;count>0 {append(&sync.regions,Channel_Region{ring.name,first,count})}
    }
}

@(private)
channel_region :: proc(sync:^Particle_Sync,name:core.Birth_Channel) -> (first,count:u32) {
    for region in sync.regions {
        if region.name==name {return region.first,region.count}
    }
    return
}
