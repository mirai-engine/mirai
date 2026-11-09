package base

import "core:mem"
import "core:testing"

@(test)
arena_serves_aligned_zeroed_memory_until_full :: proc(t:^testing.T) {
    a:Arena
    testing.expect(t,arena_init(&a,256));defer arena_destroy(&a)
    first:=arena_alloc(&a,10,1)
    testing.expect_value(t,len(first),10)
    for &b in first {b=0xff}
    second:=arena_alloc(&a,32,32)
    testing.expect(t,mem.is_aligned(raw_data(second),32))
    for b in second {testing.expect_value(t,b,u8(0))}
    testing.expect(t,arena_alloc(&a,1024)==nil,"A request beyond the capacity is refused")
    stats:=arena_stats(&a)
    testing.expect_value(t,stats.capacity,256)
    testing.expect_value(t,stats.requests,u64(2))
    testing.expect_value(t,stats.failed,u64(1))
    testing.expect(t,stats.used>=42 && stats.used<=256)
    arena_reset(&a)
    testing.expect_value(t,arena_stats(&a).used,0)
    testing.expect_value(t,arena_stats(&a).peak,stats.used)
    again:=arena_alloc(&a,10,1)
    testing.expect_value(t,again[0],u8(0))
}

@(test)
arena_without_memory_refuses_every_request :: proc(t:^testing.T) {
    a:Arena
    testing.expect(t,!arena_init(&a,0))
    testing.expect(t,arena_alloc(&a,8)==nil)
    testing.expect_value(t,arena_stats(&a).failed,u64(1))
    _,error:=mem.alloc_bytes(8,8,arena_allocator(&a))
    testing.expect_value(t,error,mem.Allocator_Error.Out_Of_Memory)
}

@(test)
arena_grows_its_last_allocation_in_place :: proc(t:^testing.T) {
    backing:[2048]byte
    a:Arena;arena_init_buffer(&a,backing[:])
    context.allocator=arena_allocator(&a)
    values:=make([dynamic]int,0,4)
    start:=raw_data(values)
    for i in 0..<40 {append(&values,i)}
    testing.expect_value(t,raw_data(values),start)
    for value,i in values {testing.expect_value(t,value,i)}
    testing.expect(t,arena_stats(&a).used<=cap(values)*size_of(int)+16,"Growing in place leaves no copies behind")
    // Something allocated after it forces the next growth to move.
    other:=make([]u8,8)
    reserve(&values,cap(values)+8)
    testing.expect(t,raw_data(values)!=start)
    for value,i in values {testing.expect_value(t,value,i)}
    _=other
    // What does not fit fails and leaves the array as it was.
    count:=len(values)
    error:=reserve(&values,1000)
    testing.expect_value(t,error,mem.Allocator_Error.Out_Of_Memory)
    testing.expect_value(t,len(values),count)
    testing.expect(t,arena_stats(&a).failed>=1)
}

@(test)
arena_rewinds_to_a_mark :: proc(t:^testing.T) {
    backing:[128]byte
    a:Arena;arena_init_buffer(&a,backing[:])
    kept:=arena_alloc(&a,16)
    mark:=arena_mark(&a)
    scratch:=arena_alloc(&a,64)
    testing.expect(t,scratch!=nil)
    arena_rewind(&a,mark)
    testing.expect_value(t,arena_stats(&a).used,mark)
    again:=arena_alloc(&a,64)
    testing.expect_value(t,raw_data(again),raw_data(scratch))
    testing.expect(t,raw_data(kept)!=raw_data(again))
}

@(test)
stack_frees_newest_first :: proc(t:^testing.T) {
    s:Stack
    testing.expect(t,stack_init(&s,256));defer stack_destroy(&s)
    allocator:=stack_allocator(&s)
    a,_:=mem.alloc_bytes(16,8,allocator)
    b,_:=mem.alloc_bytes(16,8,allocator)
    used:=stack_stats(&s).used
    testing.expect_value(t,mem.free_bytes(a,allocator),mem.Allocator_Error.Invalid_Pointer)
    testing.expect_value(t,mem.free_bytes(b,allocator),mem.Allocator_Error.None)
    testing.expect(t,stack_stats(&s).used<used)
    testing.expect_value(t,mem.free_bytes(a,allocator),mem.Allocator_Error.None)
    testing.expect_value(t,stack_stats(&s).used,0)
    _,error:=mem.alloc_bytes(1024,8,allocator)
    testing.expect_value(t,error,mem.Allocator_Error.Out_Of_Memory)
    stats:=stack_stats(&s)
    testing.expect_value(t,stats.requests,u64(2))
    testing.expect_value(t,stats.failed,u64(1))
    testing.expect_value(t,stats.peak,used)
}

@(test)
heap_returns_the_requested_byte_length_for_aligned_allocations_and_resizes :: proc(t:^testing.T) {
    h:Heap
    testing.expect(t,heap_init(&h,HEAP_OVERHEAD+8192));defer heap_destroy(&h)
    allocator:=heap_allocator(&h)
    bytes,error:=mem.alloc_bytes(495,64,allocator)
    testing.expect_value(t,error,mem.Allocator_Error.None)
    testing.expect_value(t,len(bytes),495)
    testing.expect(t,mem.is_aligned(raw_data(bytes),64))
    for &value in bytes {value=37}
    resized,resize_error:=mem.resize_bytes(bytes,513,64,allocator)
    testing.expect_value(t,resize_error,mem.Allocator_Error.None)
    testing.expect_value(t,len(resized),513)
    testing.expect(t,mem.is_aligned(raw_data(resized),64))
    for value in resized[:495] {testing.expect_value(t,value,u8(37))}
    for value in resized[495:] {testing.expect_value(t,value,u8(0))}
    mem.free_bytes(resized,allocator)
    testing.expect_value(t,heap_stats(&h).used,0)
}

@(test)
heap_reuses_freed_memory_and_tracks_use :: proc(t:^testing.T) {
    h:Heap
    testing.expect(t,heap_init(&h,HEAP_OVERHEAD+4096));defer heap_destroy(&h)
    allocator:=heap_allocator(&h)
    blocks:[16][]byte
    for &block,i in blocks {
        error:mem.Allocator_Error
        block,error=mem.alloc_bytes(100,16,allocator)
        testing.expect_value(t,error,mem.Allocator_Error.None)
        testing.expect(t,mem.is_aligned(raw_data(block),16))
        for &b in block {b=u8(i)}
    }
    full:=heap_stats(&h)
    testing.expect(t,full.used>=1600 && full.used<=4096)
    for block,i in blocks {for b in block {testing.expect_value(t,b,u8(i))}}
    for block in blocks {mem.free_bytes(block,allocator)}
    testing.expect_value(t,heap_stats(&h).used,0)
    testing.expect_value(t,heap_stats(&h).peak,full.used)
    // The whole block is available again as one piece.
    large,error:=mem.alloc_bytes(3000,8,allocator)
    testing.expect_value(t,error,mem.Allocator_Error.None)
    testing.expect_value(t,len(large),3000)
    testing.expect_value(t,heap_stats(&h).requests,u64(17))
}

@(test)
heap_refuses_requests_beyond_its_block :: proc(t:^testing.T) {
    h:Heap
    testing.expect(t,heap_init(&h,HEAP_OVERHEAD+1024));defer heap_destroy(&h)
    context.allocator=heap_allocator(&h)
    _,error:=mem.alloc_bytes(4096)
    testing.expect_value(t,error,mem.Allocator_Error.Out_Of_Memory)
    testing.expect_value(t,heap_stats(&h).failed,u64(1))
    values:=make([dynamic]u32,0,8)
    for i in 0..<100 {append(&values,u32(i))}
    for value,i in values {testing.expect_value(t,value,u32(i))}
    error=reserve(&values,100000)
    testing.expect_value(t,error,mem.Allocator_Error.Out_Of_Memory)
    testing.expect_value(t,len(values),100)
    for value,i in values {testing.expect_value(t,value,u32(i))}
    used:=heap_stats(&h).used
    testing.expect(t,used>=400)
    delete(values)
    testing.expect_value(t,heap_stats(&h).used,0)
    heap_reset(&h)
    again,_:=mem.alloc_bytes(512)
    testing.expect_value(t,len(again),512)
}

@(test)
heap_rejects_blocks_it_cannot_use :: proc(t:^testing.T) {
    h:Heap
    small:[64]byte
    testing.expect(t,!heap_init_buffer(&h,small[:]))
    testing.expect(t,!heap_init(&h,0))
    _,error:=mem.alloc_bytes(8,8,heap_allocator(&h))
    testing.expect_value(t,error,mem.Allocator_Error.Out_Of_Memory)
    backing:=make([]u64,(HEAP_OVERHEAD+2048)/8);defer delete(backing)
    bytes:=mem.slice_to_bytes(backing)
    testing.expect(t,!heap_init_buffer(&h,bytes[1:]),"The block must be aligned")
    testing.expect(t,heap_init_buffer(&h,bytes))
    stranger:u64
    testing.expect_value(t,mem.free(&stranger,heap_allocator(&h)),mem.Allocator_Error.Invalid_Pointer)
}

@(test)
frame_keeps_the_previous_frame_alive_for_one_swap :: proc(t:^testing.T) {
    f:Frame_Allocator
    testing.expect(t,frame_init(&f,256));defer frame_destroy(&f)
    allocator:=frame_allocator(&f)
    first:=frame_alloc(&f,64)
    for &b in first {b=1}
    frame_swap(&f)
    second,_:=mem.alloc_bytes(64,8,allocator)
    for &b in second {b=2}
    testing.expect(t,raw_data(first)!=raw_data(second))
    for b in first {testing.expect_value(t,b,u8(1))}
    frame_swap(&f)
    third:=frame_alloc(&f,64)
    testing.expect_value(t,raw_data(third),raw_data(first))
    for b in third {testing.expect_value(t,b,u8(0))}
    for b in second {testing.expect_value(t,b,u8(2))}
    testing.expect_value(t,f.frame,u64(2))
    testing.expect(t,frame_alloc(&f,512)==nil)
    stats:=frame_stats(&f)
    testing.expect_value(t,stats.capacity,256)
    testing.expect_value(t,stats.used,64)
    testing.expect_value(t,stats.requests,u64(3))
    testing.expect_value(t,stats.failed,u64(1))
    empty:Frame_Allocator
    testing.expect(t,!frame_init(&empty,0))
}

@(test)
block_pool_hands_out_every_block_once :: proc(t:^testing.T) {
    p:Block_Pool
    testing.expect(t,block_pool_init(&p,48,8,64));defer block_pool_destroy(&p)
    testing.expect_value(t,p.stride,64)
    blocks:[8][]byte
    for &block,i in blocks {
        ok:bool
        block,ok=block_pool_alloc(&p)
        testing.expect(t,ok)
        testing.expect_value(t,len(block),48)
        testing.expect(t,mem.is_aligned(raw_data(block),64))
        testing.expect_value(t,block_pool_index(&p,raw_data(block)),i)
        for &b in block {b=u8(i+1)}
    }
    _,ok:=block_pool_alloc(&p)
    testing.expect(t,!ok,"The pool is exhausted")
    for block,i in blocks {for b in block {testing.expect_value(t,b,u8(i+1))}}
    stats:=block_pool_stats(&p)
    testing.expect_value(t,stats.capacity,8*48)
    testing.expect_value(t,stats.used,8*48)
    testing.expect_value(t,stats.failed,u64(1))
    testing.expect(t,block_pool_free(&p,raw_data(blocks[3])))
    testing.expect(t,block_pool_free(&p,raw_data(blocks[5])))
    reused,_:=block_pool_alloc(&p,true)
    testing.expect_value(t,raw_data(reused),raw_data(blocks[5]))
    for b in reused {testing.expect_value(t,b,u8(0))}
    testing.expect_value(t,raw_data(block_pool_block(&p,3)),raw_data(blocks[3]))
    testing.expect_value(t,block_pool_stats(&p).used,7*48)
    testing.expect_value(t,block_pool_stats(&p).peak,8*48)
    block_pool_reset(&p)
    testing.expect_value(t,block_pool_stats(&p).used,0)
    first,_:=block_pool_alloc(&p)
    testing.expect_value(t,raw_data(first),raw_data(blocks[0]))
}

@(test)
block_pool_rejects_foreign_and_repeated_frees :: proc(t:^testing.T) {
    p:Block_Pool
    testing.expect(t,block_pool_init(&p,32,4));defer block_pool_destroy(&p)
    block,_:=block_pool_alloc(&p)
    outside:[32]byte
    testing.expect(t,!block_pool_free(&p,&outside[0]))
    testing.expect(t,!block_pool_free(&p,&block[1]),"Not the start of a block")
    testing.expect(t,!block_pool_free(&p,raw_data(block_pool_block(&p,2))),"A block never handed out")
    testing.expect(t,block_pool_free(&p,raw_data(block)))
    testing.expect(t,!block_pool_free(&p,raw_data(block)),"Already free")
    testing.expect_value(t,p.in_use,0)
    bad:Block_Pool
    testing.expect(t,!block_pool_init(&bad,0,4))
    testing.expect(t,!block_pool_init(&bad,16,0))
    testing.expect(t,!block_pool_init(&bad,16,4,24),"The alignment must be a power of two")
}

@(test)
block_pool_works_over_caller_memory :: proc(t:^testing.T) {
    backing:[1000]byte
    p:Block_Pool
    testing.expect(t,block_pool_init_buffer(&p,backing[1:],100,16))
    testing.expect(t,p.capacity>=7 && p.capacity<=8)
    seen:=0
    for {
        block,ok:=block_pool_alloc(&p)
        if !ok {break}
        testing.expect(t,mem.is_aligned(raw_data(block),16))
        testing.expect(t,uintptr(raw_data(block))>=uintptr(&backing[0]) && uintptr(raw_data(block))+100<=uintptr(&backing[0])+1000)
        for &b in block {b=0xab}
        seen+=1
    }
    testing.expect_value(t,seen,p.capacity)
    for link in p.next {testing.expect_value(t,link,BLOCK_USED)}
    tiny:[8]byte
    testing.expect(t,!block_pool_init_buffer(&p,tiny[:],100))
}

@(test)
block_pool_allocator_serves_requests_that_fit_one_block :: proc(t:^testing.T) {
    Node :: struct {value:[6]u64}
    p:Block_Pool
    testing.expect(t,block_pool_init(&p,size_of(Node),2,align_of(Node)));defer block_pool_destroy(&p)
    allocator:=block_pool_allocator(&p)
    a:=new(Node,allocator)
    b:=new(Node,allocator)
    testing.expect(t,a!=nil && b!=nil && a!=b)
    testing.expect_value(t,a.value,[6]u64{})
    c,error:=new(Node,allocator)
    testing.expect(t,c==nil)
    testing.expect_value(t,error,mem.Allocator_Error.Out_Of_Memory)
    _,error=mem.alloc_bytes(size_of(Node)+1,8,allocator)
    testing.expect_value(t,error,mem.Allocator_Error.Out_Of_Memory)
    free(a,allocator)
    testing.expect_value(t,mem.free(a,allocator),mem.Allocator_Error.Invalid_Pointer)
    d:=new(Node,allocator)
    testing.expect_value(t,d,a)
    testing.expect_value(t,block_pool_stats(&p).failed,u64(2))
}

@(private="file")
exhausted :: proc(data:rawptr,mode:mem.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,mem.Allocator_Error) {
    return nil,.Out_Of_Memory
}

@(test)
dynamic_arena_without_memory_keeps_refusing :: proc(t:^testing.T) {
    a:mem.Dynamic_Arena
    mem.dynamic_arena_init(&a,{exhausted,nil},context.allocator)
    defer mem.dynamic_arena_destroy(&a)
    allocator:=dynamic_arena_allocator(&a)
    for _ in 0..<2 {
        memory,error:=mem.alloc_bytes(16,allocator=allocator)
        testing.expect(t,memory==nil)
        testing.expect_value(t,error,mem.Allocator_Error.Out_Of_Memory)
    }
}

@(test)
truncate_only_shortens_a_dynamic_array :: proc(t:^testing.T) {
    values:=make([dynamic]int,8);defer delete(values)
    held:=cap(values)
    for count,i in ([?][2]int{{5,5},{9,5},{-1,0},{0,0}}) {
        truncate(&values,count[0])
        testing.expectf(t,len(values)==count[1] && cap(values)==held,"case %d: length %d, capacity %d",i,len(values),cap(values))
    }
}
