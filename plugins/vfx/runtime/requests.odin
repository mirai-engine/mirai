package vfx

import "core:mem"
import "mirai:core"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"

// What a game asks of an emitter it does not own: particles_tick takes the
// requests in the next fixed step, in order. A request for an entity without
// a Particle_Emitter, or that its emitter cannot take, is a problem of that
// entity.
Particle_Command :: enum u8 {
    Start,            // emits whatever active says, from where its cycle is (from the start once done)
    Stop,             // emits no more; its particles finish
    Restart,          // another generation: its particles go and the cycle starts again
    Pause,            // nothing moves, neither the clock nor its particles
    Resume,
    Authored,         // back to what its fields say
    Burst,            // count particles now
    Override_Set,     // the value at the path of hash name
    Override_Remove,
    Override_Clear,
    Parameter_Set,    // a parameter of its program
    Parameter_Remove,
    Parameter_Clear,
}

Particle_Request :: struct {
    entity:core.Entity,
    command:Particle_Command,
    count:u32,
    name:u64,                               // base.name_hash of the path of an override
    value:[effect.PARTICLE_VALUE_BYTES]u8,   // of an override
    parameter:effect.Particle_Parameter,     // of Parameter_Set; its name for Parameter_Remove
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
authored :: proc(requests:^Particle_Requests,e:core.Entity) {core.push(&requests.queue,Particle_Request{entity=e,command=.Authored})}
burst :: proc(requests:^Particle_Requests,e:core.Entity,count:u32) {core.push(&requests.queue,Particle_Request{entity=e,command=.Burst,count=count})}

// Asks for a value of the effect for this entity. A path or value the effect
// does not take is refused here, with the error.
request_override :: proc(requests:^Particle_Requests,e:core.Entity,path:string,value:$T) -> Error {
    check:Particle_Override
    if error:=override_set(&check,path,value);error!=.None {return error}
    request:=Particle_Request{entity=e,command=.Override_Set,name=check.names[0]}
    request.value=check.values[0]
    core.push(&requests.queue,request)
    return .None
}

request_override_remove :: proc(requests:^Particle_Requests,e:core.Entity,path:string) -> Error {
    if _,found:=effect.particle_value_at(path);!found {return .Unknown_Field}
    core.push(&requests.queue,Particle_Request{entity=e,command=.Override_Remove,name=base.name_hash(path)})
    return .None
}

request_override_clear :: proc(requests:^Particle_Requests,e:core.Entity) {core.push(&requests.queue,Particle_Request{entity=e,command=.Override_Clear})}

request_parameter :: proc(requests:^Particle_Requests,e:core.Entity,name:string,value:$T) -> Error {
    parameter:effect.Particle_Parameter
    if error:=parameter_of(name,value,&parameter);error!=.None {return error}
    if effect.particle_parameter_validate(&parameter).message!="" {return .Invalid_Parameter}
    core.push(&requests.queue,Particle_Request{entity=e,command=.Parameter_Set,parameter=parameter})
    return .None
}

request_parameter_remove :: proc(requests:^Particle_Requests,e:core.Entity,name:string) -> Error {
    if name=="" || len(name)>=effect.PARTICLE_NAME_BYTES {return .Invalid_Parameter}
    request:=Particle_Request{entity=e,command=.Parameter_Remove}
    base.text_set(request.parameter.name[:],name)
    core.push(&requests.queue,request)
    return .None
}

request_parameter_clear :: proc(requests:^Particle_Requests,e:core.Entity) {core.push(&requests.queue,Particle_Request{entity=e,command=.Parameter_Clear})}

// The requests since the last step, applied in order.
@(private)
requests_apply :: proc(
    requests:^Particle_Requests,emitters:core.Read(Particle_Emitter),overrides:^core.Table(Particle_Override),
    parameters:^core.Table(Particle_Parameters),clocks:^Particle_Clocks,problems:^core.Problems,
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
            case .Start:
                // A single cycle that ended starts again.
                emitter,_:=core.get(emitters,request.entity)
                if clock.done || !emitter.loop && clock.time>=f64(clock.emission.duration) {clock.time,clock.pending,clock.done=0,0,false}
                clock.control=.Playing
            case .Stop: clock.control=.Stopped
            case .Restart:
                clock_restart(clock)
                clock.control=.Playing
            case .Pause: clock.paused=true
            case .Resume: clock.paused=false
            case .Authored: clock.control=.Authored
            case .Burst:
                if !clock.paused {
                    births_add(clock,clock.time,request.count,request.count,0)
                    clock.done=false
                }
            case .Override_Set,.Override_Remove,.Override_Clear:
                override:Particle_Override
                if current,found:=core.get(overrides,request.entity);found {override=current}
                #partial switch request.command {
                case .Override_Set:
                    field,found:=effect.particle_value_find(request.name)
                    if !found || field.kind==.Asset {error=.Unknown_Field;break}
                    error=override_put(&override,request.name,request.value[:field.size])
                case .Override_Remove: override_remove_hash(&override,request.name)
                case .Override_Clear: override={}
                }
                if error==.None {
                    if row:=core.edit(overrides,request.entity);row!=nil {row^=override} else {core.add(overrides,request.entity,override)}
                }
            case .Parameter_Set,.Parameter_Remove,.Parameter_Clear:
                given:Particle_Parameters
                if current,found:=core.get(parameters,request.entity);found {given=current}
                #partial switch request.command {
                case .Parameter_Set: error=parameter_put(&given,&request.parameter)
                case .Parameter_Remove: parameter_remove(&given,base.text_get(request.parameter.name[:]))
                case .Parameter_Clear: given={}
                }
                if error==.None {
                    if row:=core.edit(parameters,request.entity);row!=nil {row^=given} else {core.add(parameters,request.entity,given)}
                }
            }
        }
        if error!=.None {
            core.report(problems,request.entity,"vfx.request","a %v request of Particle_Requests did nothing on this entity (%v): %s",request.command,error,error_message(error))
        }
    }
}

// Puts the bytes of a value by the hash of its path, as override_set does by the path.
@(private)
override_put :: proc(override:^Particle_Override,name:u64,bytes:[]u8) -> Error {
    field,found:=effect.particle_value_find(name)
    if !found {return .Unknown_Field}
    candidate:=effect.PARTICLE_DEFAULTS
    mem.copy(rawptr(uintptr(&candidate)+field.offset),raw_data(bytes),field.size)
    if !effect.particle_check({info=&candidate}) {return .Invalid_Value}
    at:=-1
    for stored,i in override.names[:min(override.count,PARTICLE_OVERRIDE_CAPACITY)] {
        if stored==name {at=i;break}
    }
    if at<0 {
        if override.count>=PARTICLE_OVERRIDE_CAPACITY {return .Override_Capacity}
        at=int(override.count)
        override.count+=1
    }
    override.names[at]=name
    override.values[at]={}
    copy(override.values[at][:],bytes)
    return .None
}
