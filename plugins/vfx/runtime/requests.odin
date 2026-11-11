package vfx

import "mirai:core"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"

// What a game asks of an emitter it does not own: particles_tick takes the
// requests in the next fixed step, in order. A request for an entity without
// a Particle_Emitter, or that its emitter cannot take, is a problem of that
// entity.
Particle_Command :: enum u8 {
    Start,            // sets active, from where its cycle is (from the start once done)
    Stop,             // clears active: it emits no more and its particles finish
    Restart,          // another generation: its particles go and the cycle starts again
    Pause,            // nothing moves, neither the clock nor its particles
    Resume,
    Burst,            // count particles now
    Value,            // a value of its instance, of hash name (value_put)
    Value_Remove,
    Values_Clear,
}

Particle_Request :: struct {
    entity:core.Entity,
    command:Particle_Command,
    count:u32,
    name:u64,                               // of Value and Value_Remove: base.name_hash of the name of the value
    value:[effect.PARTICLE_VALUE_BYTES]u8,   // of Value
}

@(storage,queue)
Particle_Requests :: struct {
    queue:core.Queue(Particle_Request),
}

start :: proc(requests:^Particle_Requests,e:core.Entity) {core.push(&requests.queue,Particle_Request{entity=e,command=.Start})}
stop :: proc(requests:^Particle_Requests,e:core.Entity) {core.push(&requests.queue,Particle_Request{entity=e,command=.Stop})}
restart :: proc(requests:^Particle_Requests,e:core.Entity) {core.push(&requests.queue,Particle_Request{entity=e,command=.Restart})}
pause :: proc(requests:^Particle_Requests,e:core.Entity) {core.push(&requests.queue,Particle_Request{entity=e,command=.Pause})}
resume :: proc(requests:^Particle_Requests,e:core.Entity) {core.push(&requests.queue,Particle_Request{entity=e,command=.Resume})}
burst :: proc(requests:^Particle_Requests,e:core.Entity,count:u32) {core.push(&requests.queue,Particle_Request{entity=e,command=.Burst,count=count})}

// Asks for a value of this entity for its effect, as value_set gives it. A
// name or value it does not take is refused here, with the error.
request_value :: proc(requests:^Particle_Requests,e:core.Entity,name:string,value:$T) -> Error {
    check:Particle_Override
    if error:=value_set(&check,name,value);error!=.None {return error}
    core.push(&requests.queue,Particle_Request{entity=e,command=.Value,name=check.names[0],value=check.values[0]})
    return .None
}

request_value_remove :: proc(requests:^Particle_Requests,e:core.Entity,name:string) {core.push(&requests.queue,Particle_Request{entity=e,command=.Value_Remove,name=base.name_hash(name)})}
request_values_clear :: proc(requests:^Particle_Requests,e:core.Entity) {core.push(&requests.queue,Particle_Request{entity=e,command=.Values_Clear})}

// The requests since the last step, applied in order.
@(private)
requests_apply :: proc(
    requests:^Particle_Requests,emitters:^core.Table(Particle_Emitter),overrides:^core.Table(Particle_Override),
    clocks:^Particle_Clocks,problems:^core.Problems,
) {
    for &request in core.take(&requests.queue) {
        error:=Error.None
        if !core.has(emitters,request.entity) {error=.Invalid_Entity}
        clock:^Emitter_Clock
        if error==.None {
            if clock=clock_of(clocks,request.entity);clock==nil {error=.Invalid_Entity}
        }
        if error==.None {
            switch request.command {
            case .Start,.Stop:
                emitter:=core.edit(emitters,request.entity)
                emitter.active=request.command==.Start
                // A single cycle that ended starts again.
                if emitter.active && (clock.done || !emitter.loop && clock.time>=f64(clock.emission.duration)) {clock.time,clock.pending,clock.done=0,0,false}
            case .Restart: clock_restart(clock)
            case .Pause: clock.paused=true
            case .Resume: clock.paused=false
            case .Burst:
                if !clock.paused {
                    births_add(clock,clock.time,request.count,request.count,0)
                    clock.done=false
                }
            case .Value,.Value_Remove,.Values_Clear:
                // The row an earlier request of this step adds, too.
                override:Particle_Override
                if staged:=core.staged(overrides,request.entity);staged!=nil {override=staged^}
                #partial switch request.command {
                case .Value: error=value_put(&override,request.name,request.value[:])
                case .Value_Remove: value_drop(&override,request.name)
                case .Values_Clear: override={}
                }
                if error==.None {
                    if row:=core.staged(overrides,request.entity);row!=nil {row^=override} else {core.add(overrides,request.entity,override)}
                }
            }
        }
        if error!=.None {
            core.report(problems,request.entity,"vfx.request","a %v request of Particle_Requests did nothing on this entity (%v): %s",request.command,error,error_message(error))
        }
    }
}
