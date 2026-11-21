package vfx

import "base:runtime"
import "core:mem"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"

Emitter_Info :: struct {
    info:effect.Particle_Info,
    program:Program,
    references:int,
    allocator:runtime.Allocator,
}

@(private)
emitter_info_keep :: proc(held:^Emitter_Info) {
    if held!=nil && held.allocator.procedure!=nil {held.references+=1}
}

@(private)
emitter_info_drop :: proc(held:^Emitter_Info) {
    if held==nil || held.allocator.procedure==nil {return}
    held.references-=1
    if held.references==0 {free(held,held.allocator)}
}

@(private)
emitter_info_intern :: proc(cache:^map[u64]^Emitter_Info,value:^Emitter_Info) -> ^Emitter_Info {
    key:=base.hash_combine(base.hash64(mem.ptr_to_bytes(&value.info)),
        base.hash64(mem.ptr_to_bytes(&value.program)))
    for {
        found:=cache^[key]
        if found==nil {break}
        if found.info==value.info && found.program==value.program {
            emitter_info_keep(found)
            return found
        }
        key=base.hash_combine(key,1)
    }
    held,err:=new(Emitter_Info)
    if err!=nil {return nil}
    held.info=value.info
    held.program=value.program
    held.allocator=context.allocator
    held.references=2
    if _,err:=map_insert(cache,key,held);err!=nil {free(held);return nil}
    return held
}

@(private)
emitter_infos_prune :: proc(cache:^map[u64]^Emitter_Info) {
    stale:[dynamic]u64
    stale.allocator=context.temp_allocator
    for key,held in cache^ {
        if held.references==1 {append(&stale,key)}
    }
    for key in stale {
        emitter_info_drop(cache^[key])
        delete_key(cache,key)
    }
}

@(private)
shown_drop :: proc(shown:^Emitter_Shown) {
    emitter_info_drop(shown.desc.spec)
    emitter_info_drop(shown.sub_desc.spec)
}
