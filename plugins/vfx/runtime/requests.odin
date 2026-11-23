package vfx

import "mirai:core"
import "mirai:host"
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
    Burst,            // count particles now, in every layer or in the one it names
    Value,            // a value of its instance, of hash name (value_put)
    Value_Remove,
    Values_Clear,
}

Particle_Request :: struct {
    entity:core.Entity,
    command:Particle_Command,
    count:u32,
    name:u64,                               // of Value and Value_Remove: base.name_hash of the path of the value inside its layer
    value:[effect.PARTICLE_VALUE_BYTES]u8,   // of Value
    layer:u8,                               // of Burst, Value and Value_Remove: the layer it names + 1; 0: none (every layer of a Burst)
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
// count particles now in every layer of the effect, or in the layer it names
// (0 the primary).
burst :: proc(requests:^Particle_Requests,e:core.Entity,count:u32,layer:=-1) {
    named:=u8(layer+1) if layer>=0 && layer<effect.PARTICLE_LAYERS else 0
    core.push(&requests.queue,Particle_Request{entity=e,command=.Burst,count=count,layer=named})
}

// Asks for a value of this entity for its effect, as value_set gives it
// ("layers.1.rate", "parameters.heat"). A name or value it does not take is
// refused here, with the error.
request_value :: proc(requests:^Particle_Requests,e:core.Entity,name:string,value:$T) -> Error {
    path,layer,named:=value_layer(name)
    if !named {return .Unknown_Field}
    request:=Particle_Request{entity=e,command=.Value,name=base.name_hash(path),layer=layer}
    if error:=value_encode(path,value,&request.value);error!=.None {return error}
    core.push(&requests.queue,request)
    return .None
}

request_value_remove :: proc(requests:^Particle_Requests,e:core.Entity,name:string) {
    path,layer,named:=value_layer(name)
    if !named {return}
    core.push(&requests.queue,Particle_Request{entity=e,command=.Value_Remove,name=base.name_hash(path),layer=layer})
}
request_values_clear :: proc(requests:^Particle_Requests,e:core.Entity) {core.push(&requests.queue,Particle_Request{entity=e,command=.Values_Clear})}

// The requests since the last step, applied in order.
@(private)
requests_apply :: proc(
    requests:^Particle_Requests,emitters:^core.Table(Particle_Emitter),overrides:^core.Table(Particle_Override),
    clocks:^Particle_Clocks,sync:^Particle_Sync,problems:^core.Problems,assets:^host.Assets=nil,playing:=true,
) {
    for &request in core.take(&requests.queue) {
        error:=Error.None
        if !core.has(emitters,request.entity) {error=.Invalid_Entity}
        clock:^Emitter_Clock
        if error==.None {
            emitter,_:=core.get(emitters,request.entity)
            if clock=clocks_resolve(clocks,sync,overrides,assets,request.entity,emitter);clock==nil {error=.Invalid_Entity}
        }
        if error==.None {
            switch request.command {
            case .Start,.Stop:
                emitter:=core.edit(emitters,request.entity)
                active:=request.command==.Start
                if playing {emitter.active=active} else {emitter.preview=active}
                if active {
                    for layer in 0..=int(clock.layers) {
                        c:=clock_find(clocks,request.entity,layer)
                        if c!=nil && (c.done || !emitter.loop && c.time>=f64(c.emission.duration)) {
                            c.time,c.pending,c.done,c.program_until=0,0,false,0
                        }
                    }
                }
            case .Restart,.Pause,.Resume,.Burst:
                if int(request.layer)>int(clock.layers)+1 {error=.Invalid_Value;break}
                for layer in 0..=int(clock.layers) {
                    if request.command==.Burst && request.layer!=0 && int(request.layer)!=layer+1 {continue}
                    c:=clock_find(clocks,request.entity,layer)
                    if c==nil {continue}
                    #partial switch request.command {
                    case .Restart: clock_restart(c)
                    case .Pause: c.paused=true
                    case .Resume: c.paused=false
                    case .Burst:
                        if !c.paused {
                            births_add(c,c.time,request.count,request.count,0)
                            c.done=false
                        }
                    }
                }
            case .Value,.Value_Remove,.Values_Clear:
                // The row an earlier request of this step adds, too.
                override:Particle_Override
                if staged:=core.staged(overrides,request.entity);staged!=nil {override=staged^}
                #partial switch request.command {
                case .Value:
                    emitter,_:=core.get(emitters,request.entity)
                    layer:=max(request.layer,1)-1
                    if int(layer)>int(clock.layers) {error=.Unknown_Field;break}
                    info:=particle_resolve(assets,emitter.particle,&override,emitter.preset,layer)
                    error=value_put(&override,request.name,request.value[:],&info,request.layer)
                case .Value_Remove: value_drop(&override,request.name,request.layer)
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
