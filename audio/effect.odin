package mirai_audio

import "core:sync"

// Effects a plugin adds to a bus: a procedure the audio thread runs on the
// stereo frames of the bus in place, after its filters and before its volume,
// with the state and the parameters it was given. A bus has BUS_EFFECT_SLOTS
// slots, which run in order; one without an effect costs nothing. The
// procedure is "contextless": it neither allocates nor takes locks.

BUS_EFFECT_SLOTS :: 4
BUS_EFFECT_PARAMS :: 4

// n is CHUNK_FRAMES at most; sample_rate is that of the mixer.
Bus_Effect_Proc :: #type proc "contextless" (state:[]u8,params:[BUS_EFFECT_PARAMS]f32,frames:[^]f32,n,sample_rate:int)
Bus_Effect :: struct {
    id:u64, // what effect it is, a constant of whoever puts it there: the same across reloads of its code
    process:Bus_Effect_Proc,
    state:[]u8, // allocated with the allocator of the mixer, which owns it from bus_set_effect on
    params:[BUS_EFFECT_PARAMS]f32,
}

@(private)
Effect_Shadow :: struct {
    using effect:Bus_Effect,
    retired:[]u8,  // the state of the effect it replaced, which the audio thread may still run
    serial:u64,    // of the command that replaced it
}

bus_effect :: proc(m:^Mixer,bus:Bus,slot:int) -> Bus_Effect {
    if !bus_valid(m,bus) || slot<0 || slot>=BUS_EFFECT_SLOTS {return {}}
    return m.effect_shadows[int(bus)*BUS_EFFECT_SLOTS+slot].effect
}
// Puts an effect in a slot of a bus, in place of the one there; a zero
// effect takes it out. The mixer owns its state from now on and frees the
// state it replaces once the audio thread lets go of it (mixer_update). False,
// and the state is still the caller's, for a slot out of range, a full
// queue, or a slot whose last replaced state the audio thread has not let go
// of yet: a later frame tries again.
bus_set_effect :: proc(m:^Mixer,bus:Bus,slot:int,effect:Bus_Effect) -> bool {
    if !bus_valid(m,bus) || slot<0 || slot>=BUS_EFFECT_SLOTS || effect.process==nil && (effect.id!=0 || effect.state!=nil) {return false}
    shadow:=&m.effect_shadows[int(bus)*BUS_EFFECT_SLOTS+slot]
    if shadow.retired!=nil {return false}
    m.effect_serial+=1
    if !command_push(m,{kind=.Bus_Effect,index=u32(bus),frames=u32(slot),effect=effect,serial=m.effect_serial}) {
        m.effect_serial-=1
        return false
    }
    shadow.retired,shadow.serial=shadow.state,m.effect_serial
    shadow.effect=effect
    return true
}
// New parameters of the effect in a slot, from the next chunk.
bus_set_effect_params :: proc(m:^Mixer,bus:Bus,slot:int,params:[BUS_EFFECT_PARAMS]f32) -> bool {
    if !bus_valid(m,bus) || slot<0 || slot>=BUS_EFFECT_SLOTS {return false}
    shadow:=&m.effect_shadows[int(bus)*BUS_EFFECT_SLOTS+slot]
    if shadow.process==nil || !command_push(m,{kind=.Bus_Effect_Params,index=u32(bus),frames=u32(slot),effect={params=params}}) {return false}
    shadow.params=params
    return true
}

// Frees the states the audio thread let go of: those replaced by a command it applied.
@(private)
effects_retire :: proc(m:^Mixer) {
    applied:=sync.atomic_load_explicit(&m.effects_applied,.Acquire)
    for &shadow in m.effect_shadows {
        if shadow.retired==nil || shadow.serial>applied {continue}
        delete(shadow.retired,m.allocator)
        shadow.retired=nil
    }
}

// The effects of a bus over n frames of its buffer.
@(private)
effects_run :: #force_inline proc "contextless" (m:^Mixer,bus:int,buffer:[^]f32,n:int) {
    for &e in m.buses[bus].effects {
        if e.process!=nil {e.process(e.state,e.params,buffer,n,m.sample_rate)}
    }
}
