package vfx

import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"

PARTICLE_BIRTHS :: 8 // groups of births a clock keeps

// Particles an emitter started: count of them, per at each instant, the first
// instant at time (seconds of the clock) and the next ones spacing seconds
// apart. first: the index of the first among every birth of the emitter.
Particle_Birth :: struct {
    first:u64,
    time:f64,
    count,per:u32,
    spacing:f32,
}

// How an emitter is told to emit besides its fields.
Particle_Control :: enum u8 {
    Authored, // as its fields say: active, or preview while the world does not play
    Playing,  // started by a request, whatever active says
    Stopped,  // stopped by a request: its particles finish
}

// What of its effect the clock of an emitter follows.
Emission :: struct {
    duration,rate,rate_over_distance:f32,
    rate_over_cycle:effect.Particle_Curve,
    bursts:[effect.PARTICLE_BURSTS]effect.Particle_Burst,
    prewarm:bool,
    longest:f32, // lifetime of its particles at most
    tail:f32,    // seconds its last particles last, with those they start
}

// Where an emitter is in the cycle of its effect, and what it started.
Emitter_Clock :: struct {
    time:f64,             // seconds of this generation; a paused clock stays
    generation:u32,       // a restart starts another: the renderer drops the particles of the one before
    control:Particle_Control,
    paused:bool,          // nothing moves: neither the clock nor its particles
    done:bool,            // its cycle ended and its last particles died
    placed:bool,
    pending:f64,          // fraction of a particle of the rate
    travelled:f64,        // of the distance
    position:[3]f32,      // where it was the step before
    emitted:u64,          // births since it began, of every generation
    first:u64,            // emitted when this generation began
    last:f64,             // time of its last birth; -max for none
    births:[PARTICLE_BIRTHS]Particle_Birth, // the latest, in the order of their indices
    birth_count:u32,
    resolved:u64,         // what emission was resolved from
    emission:Emission,
}

// What a clock follows of an effect: its emission, and how long its last
// particles and those their sub effect starts live.
emission_of :: proc(a:^host.Assets,info:^effect.Particle_Info) -> (e:Emission) {
    e={duration=max(info.duration,0.001),rate=info.rate,rate_over_distance=info.rate_over_distance,rate_over_cycle=info.rate_over_cycle,bursts=info.bursts,prewarm=info.prewarm}
    e.longest=max(info.lifetime[0],info.lifetime[1],0)
    e.tail=e.longest
    if info.trigger!=.None && info.sub_particle!={} {
        sub:=particle_resolve(a,info.sub_particle,nil)
        e.tail+=max(sub.lifetime[0],sub.lifetime[1],0)
    }
    return
}

// Piecewise linear between keys at ascending times; past the ends, the end
// keys. As particle_curve and particle_gradient of particles.slang, edges
// included: keys closer than 1e-5 ramp over 1e-5.
keys_at :: proc "contextless" (times:[]f32,values:[]$T,x:f32) -> T {
    previous_time,previous:=times[0],values[0]
    if x<=previous_time {return previous}
    for i in 1..<len(times) {
        if x<=times[i] {return previous+(values[i]-previous)*math.saturate((x-previous_time)/max(times[i]-previous_time,1e-5))}
        previous_time,previous=times[i],values[i]
    }
    return previous
}

// The value of a curve at x.
curve_at :: proc "contextless" (c:^effect.Particle_Curve,x:f32) -> f32 {return keys_at(c.times[:],c.values[:],x)}

// Starts the clock again: another generation, which the renderer starts empty.
clock_restart :: proc(clock:^Emitter_Clock) {
    clock.generation+=1
    clock.time,clock.pending,clock.travelled,clock.done=0,0,0,false
    clock.first,clock.last=clock.emitted,-max(f64)
    clock.births={}
    clock.birth_count=0
}

// Adds births to the clock: they take the next indices. A clock full of
// births joins its two oldest groups, spread between their first and last
// instants.
births_add :: proc(clock:^Emitter_Clock,time:f64,count,per:u32,spacing:f32) {
    if count==0 {return}
    if clock.birth_count==PARTICLE_BIRTHS {
        a,b:=clock.births[0],clock.births[1]
        end:=b.time+f64(birth_instants(b)-1)*f64(b.spacing)
        start:=min(a.time,b.time)
        total:=a.count+b.count
        clock.births[1]={first=a.first,time=start,count=total,per=1,spacing=total>1?f32((end-start)/f64(total-1)):0}
        copy(clock.births[:PARTICLE_BIRTHS-1],clock.births[1:])
        clock.birth_count-=1
    }
    clock.births[clock.birth_count]={first=clock.emitted,time=time,count=count,per=max(per,1),spacing=spacing}
    clock.birth_count+=1
    clock.emitted+=u64(count)
    instants:=(count+max(per,1)-1)/max(per,1)
    clock.last=max(clock.last,time+f64(instants-1)*f64(spacing))
}

birth_instants :: proc "contextless" (b:Particle_Birth) -> u32 {return (b.count+max(b.per,1)-1)/max(b.per,1)}

// Advances the clock of an emitter dt seconds, with the births of that time:
// its rate along the cycle, the bursts the cycle reaches, the distance the
// emitter moved and, at the start of a looping generation that asks it, a
// whole life of births before it (a prewarm).
emission_step :: proc(clock:^Emitter_Clock,e:^Emission,emitting,looping:bool,position:[3]f32,dt:f32) {
    if !clock.placed {clock.position,clock.placed,clock.last=position,true,-max(f64)}
    if clock.paused || !(dt>=0) {return}
    duration:=f64(e.duration)
    before:=clock.time
    after:=before+f64(dt)
    clock.time=after
    over:=!looping && before>=duration
    if emitting && !over {
        if before==0 && e.prewarm && looping && e.rate>0 && e.longest>0 {
            count:=u32(min(f64(e.rate)*f64(e.longest),f64(1<<20)))
            if count>0 {births_add(clock,-f64(e.longest),count,1,e.longest/f32(count))}
        }
        // The rate, at the middle of the step along the cycle.
        end:=looping?after:min(after,duration)
        if active:=end-before;active>0 && e.rate>0 {
            middle:=math.mod(before+active*0.5,duration)/duration
            rate:=f64(e.rate)*f64(max(curve_at(&e.rate_over_cycle,f32(middle)),0))
            if rate>0 {
                total:=clock.pending+rate*active
                whole:=math.floor(total)
                if whole>0 {births_add(clock,before+(1-clock.pending)/rate,u32(min(whole,f64(max(u32)))),1,f32(1/rate))}
                clock.pending=total-whole
            }
        }
        for burst in e.bursts {
            if burst.count==0 || f64(burst.time)>=duration {continue}
            burst_births(clock,burst,duration,looping,before,after)
        }
        if e.rate_over_distance>0 {
            moved:=linalg.length(position-clock.position)
            clock.travelled+=f64(moved*e.rate_over_distance)
            whole:=math.floor(clock.travelled)
            if whole>0 {
                spacing:=f64(dt)/whole
                births_add(clock,before+spacing,u32(min(whole,f64(max(u32)))),1,f32(spacing))
            }
            clock.travelled-=whole
        }
    }
    clock.position=position
    finished:=!looping && after>=duration || !emitting && clock.control==.Stopped
    clock.done=finished && after-clock.last>=f64(e.tail)
}

// The occurrences of a burst in (before, after] of the clock, and at 0 when
// the clock starts there; those of one cycle go in one group.
@(private)
burst_births :: proc(clock:^Emitter_Clock,burst:effect.Particle_Burst,duration:f64,looping:bool,before,after:f64) {
    cycles:=u32(max(burst.cycles,1))
    interval:=f64(burst.interval)
    first_cycle,last_cycle:=f64(0),f64(0)
    if looping {first_cycle,last_cycle=math.floor(before/duration),math.floor(after/duration)}
    // A step longer than many cycles takes the last of them.
    first_cycle=max(first_cycle,last_cycle-63)
    for cycle:=first_cycle;cycle<=last_cycle;cycle+=1 {
        start:=cycle*duration
        group_time:f64
        group_count:u32
        for k in 0..<cycles {
            local:=f64(burst.time)+f64(k)*interval
            if local>=duration || k>0 && interval<=0 {break}
            at:=start+local
            reached:=at>before && at<=after || before==0 && at==0
            if !reached {continue}
            if group_count==0 {group_time=at}
            group_count+=1
        }
        if group_count>0 {births_add(clock,group_time,group_count*burst.count,burst.count,f32(interval))}
    }
}

// Particles an effect needs alive at once when it does not say.
emitter_capacity :: proc(info:^effect.Particle_Info) -> u32 {
    if info.max_particles>0 {return info.max_particles}
    longest:=max(info.lifetime[0],info.lifetime[1],0.001)
    peak:=f32(0)
    for value in info.rate_over_cycle.values {peak=max(peak,value)}
    total:=info.rate*peak*longest
    for burst in info.bursts {total+=f32(burst.count)*f32(max(burst.cycles,1))}
    if info.rate_over_distance>0 {total+=info.rate_over_distance*longest*20}
    return u32(clamp(total*1.25+16,16,f32(1<<20)))
}

// What the emission of a clock was resolved from: the effect, the revision of
// the assets and the stamp of the values of the entity.
emission_key :: proc(particle:base.Asset_Id,a:^host.Assets,stamp:u64) -> u64 {
    return base.hash_combine(base.hash_combine(base.hash_combine(particle[0],particle[1]),a!=nil?a.revision:0),stamp)|1
}

// The stamp of the row of an entity, 0 without one: it moves when the row is
// written, added or taken.
@(private)
row_stamp :: proc "contextless" (rows:core.Read($T),e:core.Entity) -> u64 {
    at:=core.row_of(rows,e)
    return at>=0?core.stamp(rows,at):0
}

// The color of a gradient at x.
gradient_at :: proc "contextless" (g:^effect.Particle_Gradient,x:f32) -> [4]f32 {return keys_at(g.times[:],g.colors[:],x)}
