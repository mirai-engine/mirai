package mirai_net

import "base:runtime"
import "core:mem"
import "core:testing"
import "mirai:std/serial"

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private="file")
Memory_Limit :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
memory_limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    limit:=(^Memory_Limit)(data)
    if size>0 && (mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed) {
        if limit.remaining<=0 {return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// What a protocol asks its allocator for to be made, to take a type and to be
// sealed, with the memory ending at each request in turn: the call answers
// false and the protocol takes nothing of it, nothing is left allocated, and
// with memory enough it goes through.
@(test)
protocol_calls_without_memory_fail_whole :: proc(t:^testing.T) {
    Pose :: struct {x,y:f32,flags:u8}
    schema:serial.Schema;serial.schema_init(&schema);defer serial.schema_destroy(&schema)
    pose,described:=serial.schema_add(&schema,Pose)
    if !testing.expect(t,described) {return}
    Call :: enum {Init,Register,Seal}
    for call in Call {
        done,refused:=false,false
        for served in 0..<64 {
            tracking:mem.Tracking_Allocator
            mem.tracking_allocator_init(&tracking,context.allocator)
            limit:=Memory_Limit{owner=mem.tracking_allocator(&tracking),remaining=max(int)}
            limited:=runtime.Allocator{memory_limit_proc,&limit}
            p:Protocol
            ok:bool
            if call==.Init {limit.remaining=served}
            ok=protocol_init(&p,limited)
            if call!=.Init && !testing.expect(t,ok) {return}
            if call==.Register {limit.remaining=served}
            if ok {
                registered:bool
                _,registered=type_register(&p,"pose",{{schema=&schema,type=pose}})
                if call==.Register {
                    ok=registered
                    testing.expectf(t,type_count(&p)==(ok?1:0),"%d requests served: a type is registered whole or not at all",served)
                } else if call==.Seal && !testing.expect(t,registered) {return}
            }
            if call==.Seal {
                limit.remaining=served
                _,ok=protocol_seal(&p)
                limit.remaining=max(int)
                _,composed:=type_compose(&p,{0})
                testing.expectf(t,p.sealed==ok && composed==ok,"%d requests served: only a sealed protocol composes types",served)
            }
            limit.remaining=max(int)
            protocol_destroy(&p)
            testing.expectf(t,len(tracking.allocation_map)==0 && len(tracking.bad_free_array)==0,"%v with %d requests served: %d left allocated",call,served,len(tracking.allocation_map))
            mem.tracking_allocator_destroy(&tracking)
            if done=ok;done {break}
            refused=true
        }
        testing.expectf(t,done && refused,"%v: refused without memory, and with it it goes through",call)
    }
}
