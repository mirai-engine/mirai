package vfx

import erender "mirai:engine/render"
import "mirai:std/base"

@(private)
particle_data_name :: proc "contextless" (side:u8) -> string {
    return "vfx particle data" if side==0 else "vfx particle data grown"
}

@(private)
pool_data_take :: proc(pool:^Pool,bytes:u64) -> (offset:u64,ok:bool) {
    ranges:=&pool.attribute_free
    if offset,ok=base.ranges_take(ranges,bytes);ok {return}
    fixed:=pool_data_bytes(pool.capacity)
    if fixed>=pool.data_limit {return 0,false}
    limit:=(pool.data_limit-fixed)&~u64(15)
    old:=ranges.size
    tail:=u64(0)
    if n:=len(ranges.free);n>0 {
        last:=ranges.free[n-1]
        if last.offset+last.size==old {tail=last.size}
    }
    needed:=old+bytes-tail
    if needed>limit {return 0,false}
    size:=min((max(4096,needed,2*old)+15)&~u64(15),limit)
    if tail>0 {ranges.free[len(ranges.free)-1].size+=size-old}
    else if _,err:=append(&ranges.free,base.Range{old,size-old});err!=nil {return 0,false}
    ranges.size=size
    return base.ranges_take(ranges,bytes)
}

// Growing the arena retains all live attributes, draw records, and emitter state.
@(private)
pool_data_make :: proc(pool:^Pool,pass:^erender.Pass,copy:erender.Pipeline) -> bool {
    bytes:=pool_data_bytes(pool.capacity)+pool.attribute_free.size
    if bytes==pool.data_bytes {return true}
    old:=pool_buffer(pool,.Data)
    if !pool.made || !erender.pass_buffer_held(pass,old) {
        pool.data_bytes=bytes
        return true
    }
    if copy==0 {return false}
    next:=pool.data_side~1
    if ok,_:=erender.pass_buffer(pass,0,old);!ok {return false}
    if ok,_:=erender.pass_buffer(pass,1,{particle_data_name(next),bytes});!ok {return false}
    count:=u32(old.size/16)
    blocks:=min(groups(count,64),65535)
    params:=[2]u32{count,blocks*64}
    erender.pass_pipeline(pass,copy)
    if !erender.pass_params(pass,&params,size_of(params)) {return false}
    erender.pass_dispatch(pass,blocks)
    pool.data_side,pool.data_bytes,pool.retire_data=next,bytes,true
    return true
}

@(private)
pool_birth_entries :: proc(sync:^Particle_Sync) {
    pool:=&sync.pool
    for &resource in sync.resources {
        if resource.kind!=.Emitter {continue}
        at:=pool_slot_find(pool,resource.emitter)
        if at<0 {continue}
        slot:=&pool.slots[at]
        if slot.birth_entries!=max(u32) {continue}
        start,ok:=pool_data_take(pool,(u64(slot.capacity)*4+15)&~u64(15))
        if !ok {continue}
        slot.birth_entries=u32(start)
        slot.birth_clear=true
        bits_add(&pool.dirty,at)
    }
}
