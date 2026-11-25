package vfx

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
// that a rollback runs again pairs each birth it pushes with one the run it
// corrects pushed in that tick and channel, one to one: the nearest by the
// same entity (Birth.by), or with none, the nearest with none within
// BIRTH_SAME_DISTANCE. A paired one is not drawn twice and, if the GPU did not
// start it yet, takes what the corrected tick says; one only it pushes is
// drawn, and one only the run it corrects pushed is not drawn if the GPU did
// not start it yet. A clock that goes back without running ticks again (a
// load) forgets the births kept. A channel keeps CHANNEL_BIRTHS births; one
// that gives its place before the GPU started it is lost and reported.

CHANNEL_BIRTHS :: 1024
BIRTH_SAME_DISTANCE :: f32(1) // m: a birth of no entity a tick run again pushes this near one it pushed before can be that one

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
channels_step :: proc(clocks:^Particle_Clocks,sync:^Particle_Sync,pushed:[]core.Birth,listeners:^core.Table(Particle_Channel,$A),time:core.Time,problems:^core.Problems) {
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
        // The births of a channel are kept from when it is listened to: a tick does not allocate.
        for clock in clocks.channels {
            if clock.name in sync.channels {continue}
            ring,err:=new(Channel_Ring)
            if err==nil {
                if _,err=map_insert(&sync.channels,clock.name,ring);err!=nil {free(ring)}
            }
            if err!=nil {
                core.report(problems,core.NONE,"vfx.memory","out of memory for the births of a channel; they are dropped until there is: free memory")
                clocks.seen_channels={}
                break
            }
        }
    }
    at:=time.playing?time.seconds+f64(time.dt):-1
    sync.passes+=1
    again:=time.playing && time.resimulating
    // The clock went back without running ticks again (a load): what was kept is of another run.
    if time.playing && !time.resimulating && time.tick<sync.births_tick {
        for _,ring in sync.channels {ring.oldest,ring.started=ring.next,ring.next}
    }
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
    if again {
        for _,ring in sync.channels {
            for number in max(ring.oldest,ring.started)..<ring.next {
                record:=&ring.records[number%CHANNEL_BIRTHS]
                if record.tick==time.tick && record.pass!=sync.passes {record.gone=true}
            }
        }
    }
}

// Whether birth pairs with one the run of tick that this one corrects pushed,
// not paired yet in this pass: the nearest by the same entity or, by none, the
// nearest by none within BIRTH_SAME_DISTANCE. Then that one is kept for this
// pass and, if the GPU did not start it, takes what birth says.
@(private)
channel_again :: proc(sync:^Particle_Sync,name:core.Birth_Channel,birth:core.Birth,tick:u64) -> bool {
    ring:=sync.channels[name]
    if ring==nil {return false}
    nearest:=max(u64)
    distance:=BIRTH_SAME_DISTANCE*BIRTH_SAME_DISTANCE if birth.by==core.NONE else max(f32)
    for number in ring.oldest..<ring.next {
        record:=&ring.records[number%CHANNEL_BIRTHS]
        if record.tick!=tick || record.birth.by!=birth.by || record.pass==sync.passes || record.gone && number<ring.started {continue}
        if d:=linalg.length2(record.birth.position-birth.position);d<=distance {nearest,distance=number,d}
    }
    if nearest==max(u64) {return false}
    record:=&ring.records[nearest%CHANNEL_BIRTHS]
    record.pass,record.gone=sync.passes,false
    if nearest>=ring.started {record.birth=birth}
    return true
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

// A ring is missing only while memory for it runs out, which channels_step reported.
@(private)
channel_record :: proc(sync:^Particle_Sync,name:core.Birth_Channel,birth:core.Birth,at:f64,tick:u64) {
    ring:=sync.channels[name]
    if ring==nil {return}
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
