package vfx

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "mirai:core"
import "mirai:std/base"

// Births a game gives particles by channel (core.Births): one emitter, many
// births, each where and how the game says. Each emitter whose
// Particle_Channel names the channel of a birth starts particles of its
// effect at it, and a Vfx program reads those of the channel of a resource of
// kind channel with its name (`//! resource name channel`).
// particles_tick keeps the births of each channel with the tick that read
// them, and particles_sync starts on the GPU those it did not start. A tick
// that a rollback runs again finds its births by tick and place: one it pushes
// again is not drawn twice, one only it pushes is drawn, and one only the run
// it corrects pushed is not drawn if the GPU did not start it yet. A channel
// keeps CHANNEL_BIRTHS births; one that gives its place before the GPU started
// it is lost and reported.

CHANNEL_BIRTHS :: 1024
BIRTH_SAME_DISTANCE :: f32(1) // m: a birth a tick run again pushes this near one it pushed before is that one

// The channel an emitter starts particles of its effect from: at each birth
// pushed to it, count of them where the birth is, besides its own. A silent
// one starts none: its program reads the births alone, by a resource of
// kind channel of the same name.
@(component)
Particle_Channel :: struct {
    name:[core.CHANNEL_NAME_BYTES]u8 `mirai:"text"`,
    silent:bool, // its effect starts no particles at the births
}

// The channel an emitter listens to; 0: none.
@(private)
channel_key :: proc(listener:Particle_Channel) -> core.Birth_Channel {
    listener:=listener
    return core.birth_channel(base.text_get(listener.name[:]))
}

Channel_Clock :: struct {
    name:core.Birth_Channel,
    emitted:u64,
    latest:f64,
}

// Births by number: those from oldest to next are kept, and from started on
// the GPU did not start them.
Channel_Ring :: struct {
    records:[CHANNEL_BIRTHS]Channel_Record,
    oldest,next,started:u64,
    lost:u64,      // gave their place before the GPU started them, since the last report
}

Channel_Record :: struct {
    birth:core.Birth,
    time:f64,
    tick:u64,  // that read it
    pass:u64,  // Particle_Sync.passes when a tick pushed it, or pushed it again
    gone:bool, // the tick that ran again did not push it: it is not started
}

#assert(size_of(Channel_Clock)<=32)

@(private)
channels_step :: proc(clocks:^Particle_Clocks,sync:^Particle_Sync,pushed:[]core.Birth,listeners:^core.Table(Particle_Channel,$A),time:core.Time) {
    if core.touched(listeners,&clocks.seen_channels) {
        names:=make([dynamic]core.Birth_Channel,context.temp_allocator)
        for row in 0..<core.count(listeners) {
            if name:=channel_key(core.at(listeners,row));name!=0 {
                if _,err:=append(&names,name);err!=nil {clocks.seen_channels={};return}
            }
        }
        slice.sort(names[:])
        channels:[dynamic]Channel_Clock
        if reserve(&channels,len(names))!=nil {clocks.seen_channels={};return}
        for name,i in names {
            if i>0 && name==names[i-1] {continue}
            if old:=channel_clock(clocks,name);old!=nil {append(&channels,old^)}
            else {append(&channels,Channel_Clock{name=name,latest=-max(f64)})}
        }
        delete(clocks.channels)
        clocks.channels=channels
        stale: [dynamic]core.Birth_Channel
        stale.allocator=context.temp_allocator
        for name in sync.channels {
            if channel_clock(clocks,name)==nil {append(&stale,name)}
        }
        for name in stale {
            free(sync.channels[name])
            delete_key(&sync.channels,name)
        }
    }
    at:=time.playing?time.seconds+f64(time.dt):-1
    sync.passes+=1
    again:=time.playing && time.resimulating
    // What a run whose clock went back (a load) pushed and the GPU did not start is not started.
    if time.playing && !time.resimulating && time.tick<sync.births_tick {channels_gone(sync,time.tick,false)}
    if time.playing {sync.births_tick=time.tick}
    for &birth in pushed {
        if clock:=channel_clock(clocks,birth.channel);clock!=nil {
            clock.emitted+=1
            clock.latest=at
            if again && channel_again(sync,clock.name,birth,time.tick) {continue}
            channel_record(sync,clock.name,birth,at,time.tick)
        }
    }
    // What only the run this tick corrects pushed, and the GPU did not start, is not started.
    if again {channels_gone(sync,time.tick,true)}
}

@(private)
channels_gone :: proc(sync:^Particle_Sync,tick:u64,again:bool) {
    for _,ring in sync.channels {
        for number in max(ring.oldest,ring.started)..<ring.next {
            record:=&ring.records[number%CHANNEL_BIRTHS]
            if again ? record.tick==tick && record.pass!=sync.passes : record.tick>=tick {record.gone=true}
        }
    }
}

// Whether birth was pushed by the run of tick that this one corrects: then it
// is kept for this pass, and not pushed again.
@(private)
channel_again :: proc(sync:^Particle_Sync,name:core.Birth_Channel,birth:core.Birth,tick:u64) -> bool {
    ring:=sync.channels[name]
    if ring==nil {return false}
    for number in ring.oldest..<ring.next {
        record:=&ring.records[number%CHANNEL_BIRTHS]
        if record.tick!=tick || record.pass==sync.passes || record.gone && number<ring.started {continue}
        if linalg.length2(record.birth.position-birth.position)>BIRTH_SAME_DISTANCE*BIRTH_SAME_DISTANCE {continue}
        record.pass,record.gone=sync.passes,false
        return true
    }
    return false
}

@(private)
channel_clock :: proc(clocks:^Particle_Clocks,name:core.Birth_Channel) -> ^Channel_Clock {
    lo,hi:=0,len(clocks.channels)
    for lo<hi {
        mid:=(lo+hi)/2
        if clocks.channels[mid].name<name {lo=mid+1} else {hi=mid}
    }
    if lo<len(clocks.channels) && clocks.channels[lo].name==name {return &clocks.channels[lo]}
    return nil
}

@(private)
channel_record :: proc(sync:^Particle_Sync,name:core.Birth_Channel,birth:core.Birth,at:f64,tick:u64) {
    ring:=sync.channels[name]
    if ring==nil {
        err:runtime.Allocator_Error
        if ring,err=new(Channel_Ring);err!=nil {return}
        if _,err:=map_insert(&sync.channels,name,ring);err!=nil {free(ring);return}
    }
    if ring.next-ring.oldest==CHANNEL_BIRTHS {
        if ring.oldest>=ring.started && !ring.records[ring.oldest%CHANNEL_BIRTHS].gone {ring.lost+=1}
        ring.oldest+=1
    }
    ring.records[ring.next%CHANNEL_BIRTHS]={birth=birth,time=at,tick=tick,pass=sync.passes}
    ring.next+=1
}

CHANNEL_PREVIEW_COUNT :: 16

@(private)
channel_preview :: proc(clocks:^Particle_Clocks,sync:^Particle_Sync,listener:Particle_Channel,position:[3]f32,before,after,duration:f64) {
    cycle:=max(duration,0.5)
    if before>0 && math.floor(before/cycle)==math.floor(after/cycle) {return}
    if clock:=channel_clock(clocks,channel_key(listener));clock!=nil {
        clock.emitted+=1
        channel_record(sync,clock.name,{position=position,count=CHANNEL_PREVIEW_COUNT},-1,0)
    }
}

@(private)
channels_clear :: proc(sync:^Particle_Sync) {
    for _,ring in sync.channels {free(ring)}
    clear(&sync.channels)
}

// shaders/particles.slang: Particle_Birth.
Gpu_Birth :: struct {
    position:[3]f32, size:f32,
    velocity:[3]f32, age:f32, // seconds it is old at the end of the frame
    color:[4]f32,
    values:[4]f32,
    count,number:u32,         // particles, and its number in its channel
    normal:[3]f32,
    pad:[3]u32,
}
#assert(size_of(Gpu_Birth)==96)

// Where the births of a channel are among those of the frame.
Channel_Region :: struct {
    name:core.Birth_Channel,
    first,count:u32,
}

@(private)
channels_sync :: proc(sync:^Particle_Sync,clocks:^Particle_Clocks,now:f64,problems:^core.Problems) {
    clear(&sync.births)
    clear(&sync.regions)
    if clocks==nil {return}
    for &clock in clocks.channels {
        ring:=sync.channels[clock.name]
        if ring==nil {continue}
        if ring.lost>0 {
            core.report(problems,core.NONE,"vfx.births","%d births of a channel were lost: more than %d waited for a frame to start them; push fewer births to one channel in a frame",ring.lost,CHANNEL_BIRTHS)
            ring.lost=0
        }
        start:=max(ring.started,ring.oldest)
        count:=0
        for number in start..<ring.next {
            if !ring.records[number%CHANNEL_BIRTHS].gone {count+=1}
        }
        if count==0 {ring.started=ring.next;continue}
        first:=len(sync.births)
        if reserve(&sync.births,first+count)!=nil || reserve(&sync.regions,len(sync.regions)+1)!=nil {
            core.report(problems,core.NONE,"vfx.memory","out of memory for a channel of particles; its births wait for the next frame: free memory")
            continue
        }
        for number in start..<ring.next {
            record:=&ring.records[number%CHANNEL_BIRTHS]
            if record.gone {continue}
            b:=&record.birth
            color:=b.color if b.color!={} else {1,1,1,1}
            append(&sync.births,Gpu_Birth{
                position=b.position,size=b.size>0?b.size:1,velocity=b.velocity,normal=b.normal,
                age=record.time>=0?f32(clamp(now-record.time,0,f64(FRAME_MAX)*4)):0,
                color=color,values=b.values,count=max(b.count,1),number=u32(number),
            })
        }
        append(&sync.regions,Channel_Region{clock.name,u32(first),u32(count)})
        ring.started=ring.next
    }
}

@(private)
channel_region :: proc(sync:^Particle_Sync,name:core.Birth_Channel) -> (first,count:u32) {
    for region in sync.regions {
        if region.name==name {return region.first,region.count}
    }
    return
}
