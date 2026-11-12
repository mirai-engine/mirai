package vfx

import erender "mirai:engine/render"

// Bytes of a buffer of the pool of a world.
Pool_Range :: struct {
    buffer:erender.Buffer_Desc,
    offset,size:u64,
}

// Where the rows of an emitter are in the buffers of its pool: the first
// count of its particles, their Attributes (stride bytes each; no size
// without a program that keeps them) and its counters. local: their places
// are its own or of an effect view, not relative to Pool.origin.
Emitter_Ranges :: struct {
    particles,attributes,state:Pool_Range,
    stride:u32,
    local:bool,
}

// The ranges of the emitter of an id; false for one the pool does not hold.
emitter_ranges :: proc(pool:^Pool,id:u64,count:u32) -> (r:Emitter_Ranges,ok:bool) {
    at:=pool_slot_find(pool,id)
    if at<0 {return}
    s:=&pool.slots[at]
    n:=u64(min(s.capacity,max(count,1)))
    r.particles={pool_buffer(pool,.Particles),u64(s.offset)*size_of(Gpu_Particle),n*size_of(Gpu_Particle)}
    r.attributes={pool_buffer(pool,.Data),u64(ATTRIBUTES_AT+s.attributes),n*u64(s.stride)}
    r.state={pool_buffer(pool,.State),u64(at)*size_of(Gpu_State),size_of(Gpu_State)}
    r.stride=s.stride
    r.local=s.desc.info.local_space || s.desc.view!=0
    return r,true
}

// The bytes of its pool the emitter of a slot holds: its share of the
// particles and lists, its Attributes, its counters and its row.
emitter_bytes :: proc(pool:^Pool,at:int) -> u64 {
    s:=&pool.slots[at]
    shared:=pool_buffer(pool,.Particles).size+pool_buffer(pool,.Lists).size
    return u64(s.capacity)*(shared/u64(max(pool.capacity,1))+u64(s.stride))+pool_buffer(pool,.State).size/EMITTER_CAPACITY+size_of(Gpu_Emitter)
}
