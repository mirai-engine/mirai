package base

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:testing"

// Every public procedure is handed what it has to refuse: capacities, sizes
// and alignments that are zero, negative or huge, stale, forged and zero
// handles, keys that collide, full and empty containers, and text of any
// bytes. Each result is held against a reference model: what was served is
// right, what was refused left its structure as it was, and nothing stays
// allocated.

@(private="file") HOSTILE_ROUNDS :: #config(BASE_HOSTILE_ROUNDS,400)

@(private="file")
hostile_memory_check :: proc(t:^testing.T,m:^Hostile_Memory,loc:=#caller_location) {
    leaked,bad_frees:=hostile_memory_end(m)
    testing.expectf(t,leaked==0 && bad_frees==0,"%d allocations were left and %d frees were of nothing",leaked,bad_frees,loc=loc)
}

@(private="file")
hostile_zeroed :: proc(value:^$T) -> bool {return mem.check_zero_ptr(value,size_of(T))}

// A capacity or size: usually small, sometimes empty, negative or beyond any memory.
@(private="file")
hostile_size :: proc(h:^Hostile) -> int {
    switch hostile_int(h,14) {
    case 0: return 0
    case 1: return -1
    case 2: return 1
    case 3: return min(int)
    case 4: return 1<<50
    case 5: return 1<<52
    case 6: return 1<<55
    case 7: return 1<<51
    case 8: return 3
    case 9: return 2
    }
    return hostile_int(h,600)+1
}

@(private="file") HOSTILE_SIZE_HELD :: 600 // the largest hostile_size a machine has memory for

@(private="file")
hostile_small :: proc(h:^Hostile) -> int {
    switch hostile_int(h,10) {
    case 0: return 0
    case 1: return -1
    case 2: return 1
    }
    return hostile_int(h,130)
}

@(private="file")
hostile_alignment :: proc(h:^Hostile,wild:bool) -> int {
    if !wild {return 1<<uint(hostile_int(h,hostile_int(h,8)==0?41:13))}
    switch hostile_int(h,14) {
    case 0: return 0
    case 1: return -8
    case 2: return 3
    case 3: return 1<<40
    case 4: return 1
    case 5: return 4096
    case 6: return 1<<20
    case 7: return max(int)
    case 8: return min(int)
    case 9: return 5
    }
    return 1<<uint(hostile_int(h,7))
}

@(private="file")
hostile_key :: proc(h:^Hostile) -> u64 {
    switch hostile_int(h,6) {
    case 0: return 0
    case 1: return max(u64)
    case 2: return u64(hostile_int(h,40))<<32
    }
    return u64(hostile_int(h,40))
}

@(private="file")
hostile_handle :: proc(h:^Hostile,real:[]Handle) -> Handle {
    switch hostile_int(h,8) {
    case 0: return 0
    case 1: return Handle(max(u64))
    case 2: return Handle(hostile_next(h))
    case 3: return handle_make(u32(hostile_int(h,70)),u32(hostile_int(h,6)))
    case 4: return handle_make(max(u32),max(u32))
    }
    if len(real)==0 {return Handle(hostile_next(h))}
    return real[hostile_int(h,len(real))]
}

@(private="file")
hostile_text :: proc(h:^Hostile,buffer:[]u8) -> string {
    for &b in buffer {
        switch hostile_int(h,6) {
        case 0: b=0xff
        case 1: b=0x80+u8(hostile_int(h,64))
        case 2: b=0xe0+u8(hostile_int(h,32))
        case 3: b=u8(hostile_next(h))
        case: b='a'+u8(hostile_int(h,26))
        }
    }
    return string(buffer)
}

// A capacity whose size in bytes no machine holds, and overflows int for most element types.
@(private="file")
hostile_huge :: proc(h:^Hostile) -> int {
    huge:=[?]int{max(int),max(int)/2+1,1<<62,1<<61+1,1<<61,max(int)/3,1<<60+1,max(int)-1,1<<59,1<<58+1}
    return huge[hostile_int(h,len(huge))]
}

// ---------------------------------------------------------------- allocators

// A served allocation and the byte it was filled with, which has to be there until it is given back.
@(private="file")
Hostile_Block :: struct {memory:[]byte,fill:u8}

@(private="file")
hostile_filled :: proc(bytes:[]byte,fill:u8) -> bool {
    for b in bytes {if b!=fill {return false}}
    return true
}

@(private="file")
hostile_apart :: proc(live:[]Hostile_Block,skip:int,bytes:[]byte) -> bool {
    if len(bytes)==0 {return true}
    from:=uintptr(raw_data(bytes))
    for block,i in live {
        if i==skip || len(block.memory)==0 {continue}
        start:=uintptr(raw_data(block.memory))
        if from<start+uintptr(len(block.memory)) && start<from+uintptr(len(bytes)) {return false}
    }
    return true
}

@(private="file")
hostile_forget :: proc(live:^[dynamic]Hostile_Block,memory:rawptr) {
    for block,i in live {
        if raw_data(block.memory)==memory {ordered_remove(live,i);return}
    }
}

// What an allocator served: the size and alignment asked for, zeroed when asked, and apart from every other live block.
@(private="file")
hostile_served :: proc(t:^testing.T,name:string,live:[]Hostile_Block,skip:int,bytes:[]byte,size,alignment:int) {
    testing.expectf(t,len(bytes)==max(size,0),"%s: %d bytes served for a request of %d",name,len(bytes),size)
    testing.expectf(t,alignment_valid(alignment) && uintptr(raw_data(bytes))&uintptr(alignment-1)==0,"%s: memory served for the alignment %d is not aligned to it",name,alignment)
    testing.expectf(t,hostile_apart(live,skip,bytes),"%s: memory served twice",name)
}

// Runs the allocator procedure with every mode, with sizes and alignments it
// may refuse and with pointers it never handed out, and returns how many
// allocations it served.
@(private="file")
hostile_allocator_use :: proc(t:^testing.T,h:^Hostile,name:string,allocator:runtime.Allocator,ops:int,wild:bool) -> (served:int) {
    live:[dynamic]Hostile_Block
    freed:[dynamic]rawptr
    defer {delete(live);delete(freed)}
    stray:[64]byte
    fill:u8
    for _ in 0..<ops {
        size:=hostile_int(h,5)==0?hostile_size(h):hostile_int(h,300)
        alignment:=hostile_int(h,3)==0?hostile_alignment(h,wild):mem.DEFAULT_ALIGNMENT
        zeroed:=hostile_int(h,2)==0
        fill=fill%250+1
        switch hostile_int(h,9) {
        case 0,1,2:
            bytes,error:=allocator.procedure(allocator.data,.Alloc if zeroed else .Alloc_Non_Zeroed,size,alignment,nil,0)
            if error!=nil || raw_data(bytes)==nil {
                testing.expectf(t,len(bytes)==0,"%s: a refused request of %d bytes returned memory",name,size)
                continue
            }
            served+=1
            hostile_served(t,name,live[:],-1,bytes,size,alignment)
            testing.expectf(t,!zeroed || hostile_filled(bytes,0),"%s: zeroed memory came with other bytes",name)
            mem.set(raw_data(bytes),fill,len(bytes))
            append(&live,Hostile_Block{bytes,fill})
        case 3:
            if len(live)==0 {continue}
            at:=hostile_int(h,len(live))
            block:=live[at]
            bytes,error:=allocator.procedure(allocator.data,.Resize if zeroed else .Resize_Non_Zeroed,size,alignment,raw_data(block.memory),len(block.memory))
            if error!=nil {
                testing.expectf(t,len(bytes)==0 && hostile_filled(block.memory,block.fill),"%s: a refused resize changed its block",name)
                continue
            }
            append(&freed,raw_data(block.memory))
            if raw_data(bytes)==nil {unordered_remove(&live,at);continue}
            hostile_served(t,name,live[:],at,bytes,size,alignment)
            kept:=min(len(block.memory),len(bytes))
            testing.expectf(t,hostile_filled(bytes[:kept],block.fill),"%s: a resize lost the bytes of its block",name)
            testing.expectf(t,!zeroed || hostile_filled(bytes[kept:],0),"%s: a zeroed resize grew with other bytes",name)
            mem.set(raw_data(bytes),fill,len(bytes))
            live[at]={bytes,fill}
        case 4:
            if len(live)==0 {continue}
            at:=hostile_int(h,len(live))
            block:=live[at]
            testing.expectf(t,hostile_filled(block.memory,block.fill),"%s: a live block changed",name)
            _,error:=allocator.procedure(allocator.data,.Free,0,0,raw_data(block.memory),len(block.memory))
            append(&freed,raw_data(block.memory))
            if error==nil {ordered_remove(&live,at)}
        case 5:
            if len(freed)==0 {continue}
            stale:=freed[hostile_int(h,len(freed))]
            // A stale pointer the allocator takes is the start of a block it handed out again.
            if _,error:=allocator.procedure(allocator.data,.Free,0,0,stale,hostile_int(h,300));error==nil {hostile_forget(&live,stale)}
        case 6:
            if hostile_int(h,2)==0 {
                allocator.procedure(allocator.data,.Free,0,0,nil,hostile_int(h,100))
            } else {
                _,error:=allocator.procedure(allocator.data,.Free,0,0,&stray[hostile_int(h,64)],hostile_int(h,100))
                testing.expectf(t,error!=nil,"%s: freed memory that is not its own",name)
            }
        case 7:
            if len(live)==0 {continue}
            block:=live[hostile_int(h,len(live))]
            if len(block.memory)>1 {
                _,error:=allocator.procedure(allocator.data,.Free,0,0,raw_data(block.memory[hostile_int(h,len(block.memory)-1)+1:]),0)
                testing.expectf(t,error!=nil,"%s: freed a pointer into the middle of a block",name)
            }
        case 8:
            if hostile_int(h,4)==0 {
                allocator.procedure(allocator.data,.Free_All,0,0,nil,0)
                for block in live {append(&freed,raw_data(block.memory))}
                clear(&live)
            } else {
                set:runtime.Allocator_Mode_Set
                _,error:=allocator.procedure(allocator.data,.Query_Features,0,0,&set,0)
                testing.expectf(t,error!=nil || .Alloc in set,"%s: no features reported",name)
                allocator.procedure(allocator.data,.Query_Info,0,0,nil,0)
            }
        }
    }
    for block in live {
        if !testing.expectf(t,hostile_filled(block.memory,block.fill),"%s: a live block changed",name) {break}
    }
    return
}

@(private="file")
Hostile_Allocators :: struct {arena:Arena,stack:Stack,heap:Heap,frame:Frame_Allocator,pool:Block_Pool}

@(private="file")
Hostile_Allocator :: struct {
    name:string,
    init:proc(m:^Hostile_Allocators,h:^Hostile,capacity:int) -> bool,
    init_buffer:proc(m:^Hostile_Allocators,h:^Hostile,memory:[]byte) -> bool, // nil when it only takes memory from an allocator
    allocator:proc(m:^Hostile_Allocators) -> runtime.Allocator,
    stats:proc(m:^Hostile_Allocators) -> Alloc_Stats,
    destroy:proc(m:^Hostile_Allocators),
}

@(test)
hostile_requests_through_the_allocators :: proc(t:^testing.T) {
    memory:Hostile_Memory
    context.allocator=hostile_memory_begin(&memory)
    defer hostile_memory_check(t,&memory)
    families:=[?]Hostile_Allocator{
        {"arena",
            proc(m:^Hostile_Allocators,h:^Hostile,capacity:int) -> bool {return arena_init(&m.arena,capacity)},
            proc(m:^Hostile_Allocators,h:^Hostile,memory:[]byte) -> bool {arena_init_buffer(&m.arena,memory);return true},
            proc(m:^Hostile_Allocators) -> runtime.Allocator {return arena_allocator(&m.arena)},
            proc(m:^Hostile_Allocators) -> Alloc_Stats {return arena_stats(&m.arena)},
            proc(m:^Hostile_Allocators) {arena_destroy(&m.arena)}},
        {"stack",
            proc(m:^Hostile_Allocators,h:^Hostile,capacity:int) -> bool {return stack_init(&m.stack,capacity)},
            proc(m:^Hostile_Allocators,h:^Hostile,memory:[]byte) -> bool {stack_init_buffer(&m.stack,memory);return true},
            proc(m:^Hostile_Allocators) -> runtime.Allocator {return stack_allocator(&m.stack)},
            proc(m:^Hostile_Allocators) -> Alloc_Stats {return stack_stats(&m.stack)},
            proc(m:^Hostile_Allocators) {stack_destroy(&m.stack)}},
        {"heap",
            proc(m:^Hostile_Allocators,h:^Hostile,capacity:int) -> bool {return heap_init(&m.heap,HEAP_OVERHEAD+max(capacity,-HEAP_OVERHEAD))},
            proc(m:^Hostile_Allocators,h:^Hostile,memory:[]byte) -> bool {return heap_init_buffer(&m.heap,memory)},
            proc(m:^Hostile_Allocators) -> runtime.Allocator {return heap_allocator(&m.heap)},
            proc(m:^Hostile_Allocators) -> Alloc_Stats {return heap_stats(&m.heap)},
            proc(m:^Hostile_Allocators) {heap_destroy(&m.heap)}},
        {"frame",
            proc(m:^Hostile_Allocators,h:^Hostile,capacity:int) -> bool {return frame_init(&m.frame,capacity)},
            nil,
            proc(m:^Hostile_Allocators) -> runtime.Allocator {return frame_allocator(&m.frame)},
            proc(m:^Hostile_Allocators) -> Alloc_Stats {return frame_stats(&m.frame)},
            proc(m:^Hostile_Allocators) {frame_destroy(&m.frame)}},
        {"block pool",
            proc(m:^Hostile_Allocators,h:^Hostile,capacity:int) -> bool {
                count:=hostile_int(h,4)==0?hostile_size(h):hostile_int(h,10)+1
                return block_pool_init(&m.pool,capacity,count,hostile_int(h,3)==0?hostile_alignment(h,true):mem.DEFAULT_ALIGNMENT)
            },
            proc(m:^Hostile_Allocators,h:^Hostile,memory:[]byte) -> bool {
                return block_pool_init_buffer(&m.pool,memory,hostile_size(h),hostile_int(h,3)==0?hostile_alignment(h,true):mem.DEFAULT_ALIGNMENT)
            },
            proc(m:^Hostile_Allocators) -> runtime.Allocator {return block_pool_allocator(&m.pool)},
            proc(m:^Hostile_Allocators) -> Alloc_Stats {return block_pool_stats(&m.pool)},
            proc(m:^Hostile_Allocators) {block_pool_destroy(&m.pool)}},
    }
    GUARD :: 0xa5
    backing:=make([]u64,(HEAP_OVERHEAD+2048)/8+1)
    defer delete(backing)
    buffer:=mem.slice_to_bytes(backing)
    for family,seed in families {
        h:=Hostile{u64(seed)+1}
        for _ in 0..<HOSTILE_ROUNDS {
            if testing.failed(t) {return}
            m:Hostile_Allocators
            capacity:=hostile_int(&h,6)==0?hostile_huge(&h):hostile_size(&h)
            if family.init(&m,&h,capacity) {
                testing.expectf(t,capacity>0 && capacity<=HOSTILE_SIZE_HELD,"%s: took a capacity of %d bytes",family.name,capacity)
                allocator:=family.allocator(&m)
                hostile_allocator_use(t,&h,family.name,allocator,40,hostile_int(&h,2)==0)
                bytes,error:=allocator.procedure(allocator.data,.Alloc,max(int)-hostile_int(&h,5000),hostile_alignment(&h,false),nil,0)
                testing.expectf(t,error!=nil && bytes==nil,"%s: served nearly max(int) bytes",family.name)
                stats:=family.stats(&m)
                testing.expectf(t,stats.used>=0 && stats.used<=stats.peak && stats.peak<=stats.capacity,"%s: used %d, peak %d, capacity %d",family.name,stats.used,stats.peak,stats.capacity)
            } else {
                testing.expectf(t,hostile_zeroed(&m),"%s: a refused init left something behind",family.name)
            }
            family.destroy(&m)
            family.destroy(&m)
            testing.expectf(t,hostile_zeroed(&m),"%s: destroy left something behind",family.name)

            if family.init_buffer!=nil {
                mem.set(raw_data(buffer),GUARD,len(buffer))
                start:=hostile_int(&h,40)
                if hostile_int(&h,2)==0 {start&~=7}
                size:=hostile_int(&h,2)==0?hostile_int(&h,50):hostile_int(&h,len(buffer)-start+1)
                if family.init_buffer(&m,&h,buffer[start:][:size]) {
                    hostile_allocator_use(t,&h,family.name,family.allocator(&m),40,hostile_int(&h,2)==0)
                }
                family.destroy(&m)
                testing.expectf(t,hostile_filled(buffer[:start],GUARD) && hostile_filled(buffer[start+size:],GUARD),"%s: wrote outside the %d bytes it was given",family.name,size)
            }

            zero:Hostile_Allocators
            served:=hostile_allocator_use(t,&h,family.name,family.allocator(&zero),10,hostile_int(&h,2)==0)
            testing.expectf(t,served==0,"%s: served %d allocations without memory",family.name,served)
            stats:=family.stats(&zero)
            testing.expectf(t,stats.capacity==0 && stats.used==0,"%s: a zeroed allocator reports memory",family.name)
            family.destroy(&zero)
        }
    }
}

@(test)
hostile_marks_frames_and_blocks_of_the_allocators :: proc(t:^testing.T) {
    memory:Hostile_Memory
    context.allocator=hostile_memory_begin(&memory)
    defer hostile_memory_check(t,&memory)
    h:=Hostile{2}
    held:[dynamic][]byte
    defer delete(held)
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        a:Arena
        if arena_init(&a,hostile_int(&h,500)+1) {
            for _ in 0..<6 {
                size,alignment:=hostile_size(&h),hostile_alignment(&h,hostile_int(&h,2)==0)
                before:=arena_stats(&a)
                bytes:=arena_alloc(&a,size,alignment)
                after:=arena_stats(&a)
                if bytes==nil {
                    testing.expect(t,size==0 || (after.used==before.used && after.failed==before.failed+1),"A refused arena request moved the arena or was not counted")
                } else {
                    testing.expect(t,len(bytes)==size && hostile_filled(bytes,0) && alignment_valid(alignment) && uintptr(raw_data(bytes))&uintptr(alignment-1)==0,"The arena served other than zeroed, aligned bytes of the size asked")
                    mem.set(raw_data(bytes),0xee,len(bytes))
                }
            }
            used:=arena_mark(&a)
            mark:=hostile_int(&h,4)==0?hostile_size(&h):hostile_int(&h,60)
            arena_rewind(&a,mark)
            testing.expect_value(t,arena_mark(&a),mark if mark>=0 && mark<=used else used)
            arena_destroy(&a)
        }

        f:Frame_Allocator
        if frame_init(&f,hostile_int(&h,600)+1) {
            previous:[]byte
            for frame in 0..<6 {
                current:=frame_alloc(&f,hostile_int(&h,5)==0?hostile_size(&h):hostile_int(&h,200),hostile_alignment(&h,hostile_int(&h,2)==0))
                testing.expect(t,hostile_filled(current,0),"A frame served bytes that are not zeroed")
                mem.set(raw_data(current),u8(frame)+1,len(current))
                testing.expect(t,hostile_filled(previous,u8(frame)),"What a frame allocated did not last until the end of the next one")
                previous=current
                frame_swap(&f)
            }
            frame_destroy(&f)
        }

        p:Block_Pool
        clear(&held)
        if block_pool_init(&p,hostile_int(&h,60)+1,hostile_int(&h,12)+1) {
            for _ in 0..<40 {
                switch hostile_int(&h,6) {
                case 0,1:
                    zero:=hostile_int(&h,2)==0
                    block,ok:=block_pool_alloc(&p,zero)
                    testing.expect(t,ok==(len(held)<p.capacity),"The block pool is full exactly when every block is held")
                    if !ok {continue}
                    index:=block_pool_index(&p,raw_data(block))
                    testing.expect(t,len(block)==p.block_size && index>=0 && index<p.capacity && raw_data(block_pool_block(&p,index))==raw_data(block),"A block of the pool has its size and its index")
                    testing.expect(t,!zero || hostile_filled(block,0),"A zeroed block came with other bytes")
                    for other in held {testing.expect(t,raw_data(other)!=raw_data(block),"The pool handed out a block twice")}
                    append(&held,block)
                case 2:
                    if len(held)==0 {continue}
                    at:=hostile_int(&h,len(held))
                    testing.expect(t,block_pool_free(&p,raw_data(held[at])),"A held block was not freed")
                    testing.expect(t,!block_pool_free(&p,raw_data(held[at])),"A block was freed twice")
                    unordered_remove(&held,at)
                case 3:
                    stray:[8]byte
                    refused:=!block_pool_free(&p,&stray[hostile_int(&h,8)]) && !block_pool_free(&p,nil)
                    if len(held)>0 && len(held[0])>1 {refused&&=!block_pool_free(&p,raw_data(held[0][hostile_int(&h,len(held[0])-1)+1:]))}
                    testing.expect(t,refused,"The pool freed a pointer that is not the start of a block")
                case 4:
                    index:=hostile_small(&h)-1
                    testing.expect(t,(block_pool_block(&p,index)==nil)==(index<0 || index>=p.capacity),"Only an index below the capacity names a block")
                    testing.expect_value(t,block_pool_index(&p,rawptr(uintptr(hostile_next(&h))|1<<63)),-1)
                case 5:
                    if hostile_int(&h,5)==0 {block_pool_reset(&p);clear(&held)}
                }
                testing.expect_value(t,block_pool_stats(&p).used,len(held)*p.block_size)
            }
            block_pool_destroy(&p)
        }
    }
}

// ---------------------------------------------------------------- handles

@(private="file")
hostile_handle_index :: proc(handles:[]Handle,handle:Handle) -> int {
    for held,i in handles {if held==handle {return i}}
    return -1
}

@(test)
hostile_handles_through_the_pool :: proc(t:^testing.T) {
    memory:Hostile_Memory
    context.allocator=hostile_memory_begin(&memory)
    defer hostile_memory_check(t,&memory)
    h:=Hostile{6}
    live,dead:[dynamic]Handle
    defer {delete(live);delete(dead)}
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        clear(&live);clear(&dead)
        p:Handle_Pool
        generations,next:[8]u32
        capacity:=hostile_size(&h)
        ok:bool
        if hostile_int(&h,4)==0 {
            first,second:=hostile_int(&h,9),hostile_int(&h,9)
            handle_pool_init_buffer(&p,generations[:first],next[:second])
            capacity=min(first,second);ok=true
        } else {
            ok=handle_pool_init(&p,capacity)
            testing.expect(t,ok==(capacity>0 && capacity<=HOSTILE_SIZE_HELD) && (ok || hostile_zeroed(&p)),"The pool takes the capacities it can hold and stays zeroed on the others")
        }
        if ok {
            // Slots near their last generation retire instead of repeating a handle, so the pool may fill early.
            worn:=hostile_int(&h,3)==0
            if worn {for &g in p.generations {g=u32(0xfffffff0+2*hostile_int(&h,8))}}
            for _ in 0..<60 {
                switch hostile_int(&h,7) {
                case 0,1:
                    handle:=handle_pool_alloc(&p)
                    if handle==0 {
                        testing.expect(t,worn || len(live)==capacity,"The pool refused a handle with slots to spare")
                        continue
                    }
                    testing.expect(t,len(live)<capacity && int(handle_index(handle))<capacity,"The pool handed out more slots than it has")
                    testing.expect(t,hostile_handle_index(live[:],handle)<0 && hostile_handle_index(dead[:],handle)<0,"The pool repeated a handle")
                    append(&live,handle)
                case 2,6:
                    handle:=hostile_handle(&h,live[:])
                    at:=hostile_handle_index(live[:],handle)
                    testing.expect(t,handle_pool_free(&p,handle)==(at>=0),"Only a live handle is freed")
                    testing.expect(t,!handle_pool_free(&p,handle),"A handle was freed twice")
                    if at>=0 {unordered_remove(&live,at);append(&dead,handle)}
                case 3:
                    handle:=hostile_handle(&h,live[:])
                    known:=hostile_handle_index(live[:],handle)>=0
                    slot,found:=handle_pool_slot(&p,handle)
                    testing.expect(t,handle_pool_valid(&p,handle)==known && found==known,"Only a live handle is valid")
                    testing.expect_value(t,slot,int(handle_index(handle)) if known else -1)
                case 4:
                    slot:=hostile_small(&h)-1
                    occupant:=Handle(0)
                    for handle in live {if int(handle_index(handle))==slot {occupant=handle}}
                    testing.expect(t,handle_pool_alive(&p,slot)==(occupant!=0) && handle_pool_handle(&p,slot)==occupant,"A slot reports its occupant")
                case 5:
                    if hostile_int(&h,6)==0 {
                        handle_pool_clear(&p)
                        append(&dead,..live[:]);clear(&live)
                    }
                }
                testing.expect_value(t,p.count,len(live))
            }
            for handle in dead {
                if !testing.expect(t,!handle_pool_valid(&p,handle),"A freed handle became valid again") {break}
            }
            handle_pool_destroy(&p)
        }
        handle_pool_destroy(&p)
        zero:Handle_Pool
        handle:=hostile_handle(&h,nil)
        _,found:=handle_pool_slot(&zero,handle)
        refused:=handle_pool_alloc(&zero)==0 && !handle_pool_free(&zero,handle) && !handle_pool_valid(&zero,handle) && !found
        refused&&=!handle_pool_alive(&zero,hostile_small(&h)) && handle_pool_handle(&zero,hostile_small(&h))==0
        testing.expect(t,refused,"A zeroed pool has no handles")
        handle_pool_clear(&zero);handle_pool_destroy(&zero)
    }
}

@(test)
hostile_handles_through_the_slot_map :: proc(t:^testing.T) {
    memory:Hostile_Memory
    context.allocator=hostile_memory_begin(&memory)
    defer hostile_memory_check(t,&memory)
    h:=Hostile{7}
    Id :: distinct Handle
    live:[dynamic]Handle
    values:[dynamic]f32
    defer {delete(live);delete(values)}
    serial:f32
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        clear(&live);clear(&values)
        m:Slot_Map(f32,Id)
        capacity:=hostile_size(&h)
        ok:=slot_map_init(&m,capacity)
        testing.expect(t,ok==(capacity>0 && capacity<=HOSTILE_SIZE_HELD) && (ok || hostile_zeroed(&m)),"The map takes the capacities it can hold and stays zeroed on the others")
        if ok {
            for _ in 0..<60 {
                switch hostile_int(&h,7) {
                case 0,1:
                    serial+=1
                    handle:=slot_map_insert(&m,serial)
                    testing.expect(t,(handle!=0)==(len(live)<capacity),"The map is full exactly at its capacity")
                    if handle!=0 {append(&live,Handle(handle));append(&values,serial)}
                case 2,6:
                    handle:=hostile_handle(&h,live[:])
                    at:=hostile_handle_index(live[:],handle)
                    testing.expect(t,slot_map_remove(&m,Id(handle))==(at>=0),"Only a live handle is removed")
                    testing.expect(t,!slot_map_remove(&m,Id(handle)),"A handle was removed twice")
                    if at>=0 {unordered_remove(&live,at);unordered_remove(&values,at)}
                case 3:
                    handle:=hostile_handle(&h,live[:])
                    at:=hostile_handle_index(live[:],handle)
                    value:=slot_map_get(&m,Id(handle))
                    testing.expect(t,slot_map_valid(&m,Id(handle))==(at>=0) && (value!=nil)==(at>=0),"Only a live handle reaches a value")
                    if value!=nil && at>=0 {testing.expect_value(t,value^,values[at])}
                case 4:
                    index:=hostile_small(&h)-1
                    at:=hostile_handle_index(live[:],Handle(slot_map_handle(&m,index)))
                    packed:=slot_map_values(&m)
                    if index<0 || index>=len(live) {
                        testing.expect(t,at<0,"An index past the values has no handle")
                    } else if testing.expect(t,at>=0 && len(packed)==len(live),"Every packed value has a live handle") {
                        testing.expect_value(t,packed[index],values[at])
                    }
                case 5:
                    if hostile_int(&h,6)==0 {slot_map_clear(&m);clear(&live);clear(&values)}
                }
                testing.expect_value(t,slot_map_len(&m),len(live))
            }
            slot_map_destroy(&m)
        }
        slot_map_destroy(&m)
        zero:Slot_Map(f32,Id)
        handle:=Id(hostile_handle(&h,nil))
        refused:=slot_map_insert(&zero,1)==0 && !slot_map_remove(&zero,handle) && slot_map_get(&zero,handle)==nil && !slot_map_valid(&zero,handle)
        refused&&=slot_map_handle(&zero,hostile_small(&h))==0 && slot_map_len(&zero)==0 && len(slot_map_values(&zero))==0
        testing.expect(t,refused,"A zeroed map holds nothing")
        slot_map_clear(&zero);slot_map_destroy(&zero)
    }
}

// ---------------------------------------------------------------- bits

@(private="file") HOSTILE_BIT_WORDS :: 4

@(private="file")
hostile_bit_index :: proc(h:^Hostile) -> int {return hostile_int(h,3)==0?hostile_size(h):hostile_int(h,300)-20}

// A write to the bit set and the same write to the model: one bool per bit of the words handed in.
@(private="file")
Hostile_Bit_Write :: struct {name:string,apply:proc(h:^Hostile,words:[]u64,model:[]bool)}

@(private="file")
hostile_bit_range :: proc(model:[]bool,first,count:int,value:bool) {
    for &bit,i in model {
        if i128(i)>=i128(first) && i128(i)<i128(first)+i128(count) {bit=value}
    }
}

@(test)
hostile_indices_through_the_bit_sets :: proc(t:^testing.T) {
    writes:=[?]Hostile_Bit_Write{
        {"bits_set",proc(h:^Hostile,words:[]u64,model:[]bool) {
            index:=hostile_bit_index(h)
            bits_set(words,index)
            if index>=0 && index<len(model) {model[index]=true}
        }},
        {"bits_clear",proc(h:^Hostile,words:[]u64,model:[]bool) {
            index:=hostile_bit_index(h)
            bits_clear(words,index)
            if index>=0 && index<len(model) {model[index]=false}
        }},
        {"bits_toggle",proc(h:^Hostile,words:[]u64,model:[]bool) {
            index:=hostile_bit_index(h)
            bits_toggle(words,index)
            if index>=0 && index<len(model) {model[index]=!model[index]}
        }},
        {"bits_assign",proc(h:^Hostile,words:[]u64,model:[]bool) {
            index,value:=hostile_bit_index(h),hostile_int(h,2)==0
            bits_assign(words,index,value)
            if index>=0 && index<len(model) {model[index]=value}
        }},
        {"bits_set_range",proc(h:^Hostile,words:[]u64,model:[]bool) {
            first,count:=hostile_bit_index(h),hostile_bit_index(h)
            bits_set_range(words,first,count)
            hostile_bit_range(model,first,count,true)
        }},
        {"bits_clear_range",proc(h:^Hostile,words:[]u64,model:[]bool) {
            first,count:=hostile_bit_index(h),hostile_bit_index(h)
            bits_clear_range(words,first,count)
            hostile_bit_range(model,first,count,false)
        }},
        {"bits_clear_all",proc(h:^Hostile,words:[]u64,model:[]bool) {
            if hostile_int(h,8)!=0 {return}
            bits_clear_all(words)
            for &bit in model {bit=false}
        }},
    }
    h:=Hostile{9}
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        words:[HOSTILE_BIT_WORDS]u64
        model:[HOSTILE_BIT_WORDS*64]bool
        for &word in words {word=hostile_next(&h)}
        for &bit,i in model {bit=words[i>>6]>>uint(i&63)&1!=0}
        before:=words
        used:=hostile_int(&h,HOSTILE_BIT_WORDS+1)
        view,bits:=words[:used],model[:used*64]
        for _ in 0..<12 {
            write:=writes[hostile_int(&h,len(writes))]
            write.apply(&h,view,bits)
            set,first_set,first_clear:=0,-1,-1
            for bit,i in bits {
                if !testing.expectf(t,bits_test(view,i)==bit,"%s: bit %d of %d differs from the model",write.name,i,len(bits)) {return}
                if bit {set+=1}
                if bit && first_set<0 {first_set=i}
                if !bit && first_clear<0 {first_clear=i}
            }
            testing.expectf(t,slice.equal(words[used:],before[used:]),"%s: wrote past the words it was given",write.name)
            testing.expect(t,bits_count(view)==set && bits_any(view)==(set>0),"The count of set bits is that of the model")
            index,found:=bits_first(view)
            testing.expect(t,index==first_set && found==(first_set>=0),"The first set bit is that of the model")
            limit:=hostile_bit_index(&h)
            index,found=bits_first_clear(view,limit)
            testing.expect(t,found==(first_clear>=0 && first_clear<limit) && index==(first_clear if found else -1),"The first clear bit below a count is that of the model")
            from:=hostile_bit_index(&h)
            after:=-1
            for bit,i in bits {if bit && i>=from {after=i;break}}
            index,found=bits_next(view,from)
            testing.expect(t,index==after && found==(after>=0),"The next set bit is that of the model")
            outside:=hostile_bit_index(&h)
            if outside<0 || outside>=len(bits) {testing.expect(t,!bits_test(view,outside),"A bit beyond the words reads as clear")}
            it:=bits_iterator(view)
            visited,last:=0,-1
            for at in bits_iterate(&it) {
                if !testing.expect(t,at>last && at<len(bits) && bits[at],"The iterator visits the set bits in ascending order") {return}
                visited+=1;last=at
            }
            testing.expect_value(t,visited,set)
        }
        count:=hostile_size(&h)
        testing.expect_value(t,bits_words(count),(count-1)/64+1 if count>0 else 0)
        empty:=bits_iterator(nil)
        _,more:=bits_iterate(&empty)
        testing.expect(t,!more,"No words, no bits")
    }
}

@(private="file")
Hostile_Bit_Combine :: struct {name:string,combine:proc "contextless" (dst,a,b:[]u64),reference:proc(a,b:u64) -> u64}

@(test)
hostile_lengths_through_the_bit_operations :: proc(t:^testing.T) {
    families:=[?]Hostile_Bit_Combine{
        {"bits_and",bits_and,proc(a,b:u64) -> u64 {return a&b}},
        {"bits_or",bits_or,proc(a,b:u64) -> u64 {return a|b}},
        {"bits_xor",bits_xor,proc(a,b:u64) -> u64 {return a~b}},
        {"bits_and_not",bits_and_not,proc(a,b:u64) -> u64 {return a&~b}},
    }
    h:=Hostile{10}
    for _ in 0..<HOSTILE_ROUNDS {
        for family in families {
            words:[3][6]u64
            for &row in words {for &w in row {w=hostile_next(&h)}}
            before:=words
            lengths:=[3]int{hostile_int(&h,7),hostile_int(&h,7),hostile_int(&h,7)}
            family.combine(words[0][:lengths[0]],words[1][:lengths[1]],words[2][:lengths[2]])
            shared:=min(lengths[0],lengths[1],lengths[2])
            for i in 0..<len(words[0]) {
                want:=family.reference(before[1][i],before[2][i]) if i<shared else before[0][i]
                testing.expectf(t,words[0][i]==want,"%s: word %d of lengths %v",family.name,i,lengths)
            }
            testing.expectf(t,words[1]==before[1] && words[2]==before[2],"%s: changed its operands",family.name)
        }
    }
}

// ---------------------------------------------------------------- hashing and identities

@(private="file")
hostile_hex :: proc(text:string,digits:int) -> bool {
    if len(text)!=digits {return false}
    for i in 0..<len(text) {
        switch text[i] {
        case '0'..='9','a'..='f','A'..='F':
        case: return false
        }
    }
    return true
}

@(test)
hostile_bytes_through_hashing_and_ids :: proc(t:^testing.T) {
    h:=Hostile{11}
    buffer,moved:[65]u8
    for _ in 0..<HOSTILE_ROUNDS {
        text:=hostile_text(&h,buffer[:hostile_int(&h,65)])
        data:=transmute([]byte)text
        // The same bytes at another address.
        copy(moved[1:],data)
        again:=moved[1:][:len(data)]
        seed:=hostile_next(&h)
        testing.expect(t,hash64(data,seed)==hash64(again,seed) && hash128(data,seed)==hash128(again,seed),"A hash depends only on the bytes and the seed")
        testing.expect(t,hash64(nil,seed)==hash64(data[:0],seed) && hash128(nil,seed)==hash128(data[:0],seed),"No bytes hash like an empty slice")
        testing.expect_value(t,name_hash(text),name_hash(string(again)))
        other:=hostile_next(&h)
        testing.expect(t,other==seed || hash_u64(other)!=hash_u64(seed),"hash_u64 keeps distinct values distinct")
        id:=asset_id_from_content(data)
        testing.expect(t,id!={} && id==asset_id_from_content(again) && asset_id_from_content(nil)!={},"The identity of some bytes is theirs and never none")

        out:[40]u8
        for &b in out {b='#'}
        room:=hostile_int(&h,41)
        shown:=entity_id_format(Entity_Id(seed),out[:room])
        testing.expect(t,len(shown)==(ENTITY_ID_TEXT if room>=ENTITY_ID_TEXT else 0) && hostile_filled(out[len(shown):],'#'),"An entity id is written whole or not at all")
        if len(shown)>0 {
            parsed,ok:=entity_id_parse(shown)
            testing.expect(t,ok && parsed==Entity_Id(seed),"An entity id reads back from its text")
        }
        for &b in out {b='#'}
        shown=asset_id_format(id,out[:room])
        testing.expect(t,len(shown)==(ASSET_ID_TEXT if room>=ASSET_ID_TEXT else 0) && hostile_filled(out[len(shown):],'#'),"An asset id is written whole or not at all")
        if len(shown)>0 {
            parsed,ok:=asset_id_parse(shown)
            testing.expect(t,ok && parsed==id,"An asset id reads back from its text")
        }
        // Any text: sometimes hex digits of either case, of the right length or not.
        if hostile_int(&h,2)==0 {
            digits:="0123456789abcdefABCDEF"
            for &b in buffer[:len(text)] {b=digits[hostile_int(&h,len(digits))]}
            if hostile_int(&h,2)==0 {text=text[:min(len(text),hostile_int(&h,2)==0?ENTITY_ID_TEXT:ASSET_ID_TEXT)]}
        }
        _,entity_ok:=entity_id_parse(text)
        value,hex_ok:=hex_parse_u64(text)
        _,asset_ok:=asset_id_parse(text)
        testing.expect(t,entity_ok==hostile_hex(text,ENTITY_ID_TEXT) && hex_ok==entity_ok && asset_ok==hostile_hex(text,ASSET_ID_TEXT),"Only hex digits of the exact length are an id")
        if hex_ok {
            reparsed,_:=hex_parse_u64(hex_format_u64(value,out[:]))
            testing.expect_value(t,reparsed,value)
        }

        a,b:=rng_make(seed,other),rng_make(seed,other)
        testing.expect(t,rng_u32(&a)==rng_u32(&b) && rng_u64(&a)==rng_u64(&b),"A seed repeats its sequence")
        state:=seed
        testing.expect(t,entity_id_next(&state)!=0 && state!=seed && asset_id_random(&a)!={},"A new identity is never none")
    }
}

// ---------------------------------------------------------------- containers

@(test)
hostile_keys_through_the_hash_map :: proc(t:^testing.T) {
    memory:Hostile_Memory
    context.allocator=hostile_memory_begin(&memory)
    defer hostile_memory_check(t,&memory)
    h:=Hostile{12}
    model:map[u64]u32
    defer delete(model)
    serial:u32
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        clear(&model)
        m:Hash_Map(u32)
        capacity:=hostile_int(&h,8)==0?hostile_huge(&h):hostile_size(&h)
        ok:=hash_map_init(&m,capacity)
        testing.expect(t,ok==(capacity>0 && capacity<=HOSTILE_SIZE_HELD) && (ok || hostile_zeroed(&m)),"The map takes the capacities it can hold and stays zeroed on the others")
        if ok {
            for _ in 0..<80 {
                key:=hostile_key(&h)
                known:=key in model
                serial+=1
                switch hostile_int(&h,9) {
                case 0,1,2:
                    value,inserted:=hash_map_insert(&m,key)
                    if value==nil {
                        testing.expect(t,!known && !inserted && len(model)>=m.capacity,"The map refused a key it has or has room for")
                        continue
                    }
                    testing.expect(t,inserted==!known && value^==(model[key] if known else 0),"An insert gives the value of the key, zeroed when it is new")
                    value^=serial;model[key]=serial
                case 3:
                    stored:=hash_map_set(&m,key,serial)
                    testing.expect(t,stored==(known || len(model)<m.capacity),"A set fails only for a new key in a full map")
                    if stored {model[key]=serial}
                case 4:
                    value,found:=hash_map_remove(&m,key)
                    testing.expect(t,found==known && value==model[key],"A remove returns the value of the key")
                    delete_key(&model,key)
                case 5:
                    value,found:=hash_map_get(&m,key)
                    at:=hash_map_ptr(&m,key)
                    testing.expect(t,found==known && hash_map_contains(&m,key)==known && (at!=nil)==known,"A lookup finds the keys of the model")
                    testing.expect(t,value==model[key] && (at==nil || at^==value),"A lookup gives the value of the key")
                case 6:
                    it:=hash_map_iterator(&m)
                    visited:=0
                    for found,value in hash_map_iterate(&it) {
                        want,held:=model[found]
                        if !testing.expect(t,held && value^==want,"The iteration visits the entries of the model") {return}
                        visited+=1
                    }
                    testing.expect_value(t,visited,len(model))
                case 7:
                    if hostile_int(&h,4)!=0 {continue}
                    wanted:=hostile_size(&h)
                    held:=m.capacity
                    grown:=hash_map_grow(&m,wanted)
                    testing.expect(t,grown==(wanted<=max(held,HOSTILE_SIZE_HELD)) && m.capacity==(max(held,wanted) if grown else held),"A grow reaches the capacity or changes nothing")
                    for found,want in model {
                        if value,still:=hash_map_get(&m,found);!testing.expect(t,still && value==want,"A grow keeps every entry") {return}
                    }
                case 8:
                    if hostile_int(&h,6)==0 {hash_map_clear(&m);clear(&model)}
                }
                testing.expect_value(t,m.count,len(model))
            }
            hash_map_destroy(&m)
        }
        hash_map_destroy(&m)
        zero:Hash_Map(u32)
        key:=hostile_key(&h)
        value,_:=hash_map_insert(&zero,key)
        _,removed:=hash_map_remove(&zero,key)
        _,found:=hash_map_get(&zero,key)
        it:=hash_map_iterator(&zero)
        _,_,visited:=hash_map_iterate(&it)
        refused:=value==nil && !hash_map_set(&zero,key,1) && !removed && !found && hash_map_ptr(&zero,key)==nil && !hash_map_contains(&zero,key) && !visited
        wanted:=hostile_int(&h,50)-3
        refused&&=hash_map_grow(&zero,wanted)==(wanted<=0) && len(zero.keys)==0 && !hash_map_set(&zero,1,1)
        testing.expect(t,refused,"A zeroed map holds nothing and does not grow")
        hash_map_clear(&zero)
        hash_map_destroy(&zero)
    }
}

@(private="file")
Hostile_Name :: struct {bytes:[40]u8,size:int}

@(test)
hostile_text_through_the_interner :: proc(t:^testing.T) {
    memory:Hostile_Memory
    context.allocator=hostile_memory_begin(&memory)
    defer hostile_memory_check(t,&memory)
    h:=Hostile{13}
    buffer:[40]u8
    names:[dynamic]Hostile_Name // names[s-1] is the string of symbol s
    defer delete(names)
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        clear(&names)
        table:Interner
        max_strings,max_bytes:=hostile_size(&h),hostile_size(&h)
        ok:=intern_init(&table,max_strings,max_bytes)
        testing.expect(t,ok==(min(max_strings,max_bytes)>0 && max(max_strings,max_bytes)<=HOSTILE_SIZE_HELD) && (ok || hostile_zeroed(&table)),"The table takes the sizes it can hold and stays zeroed on the others")
        if ok {
            for _ in 0..<60 {
                text:=hostile_text(&h,buffer[:hostile_int(&h,41)])
                if len(names)>0 && hostile_int(&h,3)==0 {
                    name:=&names[hostile_int(&h,len(names))]
                    text=string(name.bytes[:name.size])
                }
                known:=Symbol(0)
                for &name,i in names {if string(name.bytes[:name.size])==text {known=Symbol(i+1)}}
                switch hostile_int(&h,5) {
                case 0,1:
                    used:=table.used
                    symbol,added:=intern_add(&table,text)
                    switch {
                    case len(text)==0: testing.expect(t,added && symbol==0,"The empty string is symbol 0")
                    case known!=0: testing.expect(t,added && symbol==known,"A string keeps its symbol")
                    case !added: testing.expect(t,symbol==0 && table.used==used && (len(names)>=max_strings || used+len(text)>max_bytes),"The table refused a string it has room for")
                    case:
                        testing.expect(t,int(symbol)==len(names)+1 && intern_string(&table,symbol)==text,"A new string gets the next symbol")
                        name:=Hostile_Name{size=len(text)}
                        copy(name.bytes[:],text)
                        append(&names,name)
                    }
                case 2:
                    symbol,found:=intern_find(&table,text)
                    testing.expect(t,found==(known!=0 || len(text)==0) && symbol==known,"Only the strings of the table are found")
                case 3:
                    symbol:=Symbol(hostile_next(&h))
                    if len(names)>0 && hostile_int(&h,2)==0 {symbol=Symbol(hostile_int(&h,len(names))+1)}
                    want:=""
                    if symbol>0 && int(symbol)<=len(names) {want=string(names[symbol-1].bytes[:names[symbol-1].size])}
                    testing.expect(t,intern_string(&table,symbol)==want && intern_hash(&table,symbol)==name_hash(want),"A symbol gives its string and its hash, an unknown one those of the empty string")
                case 4:
                    if hostile_int(&h,8)==0 {intern_clear(&table);clear(&names)}
                }
                testing.expect_value(t,table.count,len(names))
            }
            intern_destroy(&table)
        }
        intern_destroy(&table)
        zero:Interner
        text:=hostile_text(&h,buffer[:hostile_int(&h,41)])
        symbol,added:=intern_add(&zero,text)
        _,found:=intern_find(&zero,text)
        refused:=symbol==0 && added==(len(text)==0) && found==(len(text)==0)
        refused&&=intern_string(&zero,Symbol(hostile_next(&h)))=="" && intern_hash(&zero,Symbol(hostile_next(&h)))==name_hash("")
        testing.expect(t,refused,"A zeroed table has only the empty string")
        intern_clear(&zero);intern_destroy(&zero)
    }
}

@(private="file")
Hostile_Entry :: struct {key:u64,value:u32}

@(private="file")
hostile_entry_index :: proc(entries:[]Hostile_Entry,key:u64) -> int {
    for entry,i in entries {if entry.key==key {return i}}
    return -1
}

@(test)
hostile_keys_through_the_lru :: proc(t:^testing.T) {
    memory:Hostile_Memory
    context.allocator=hostile_memory_begin(&memory)
    defer hostile_memory_check(t,&memory)
    h:=Hostile{14}
    model:[dynamic]Hostile_Entry // oldest first
    defer delete(model)
    serial:u32
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        clear(&model)
        c:Lru(u32)
        capacity:=hostile_int(&h,8)==0?hostile_huge(&h):hostile_size(&h)
        ok:=lru_init(&c,capacity)
        testing.expect(t,ok==(capacity>0 && capacity<=HOSTILE_SIZE_HELD) && (ok || hostile_zeroed(&c)),"The cache takes the capacities it can hold and stays zeroed on the others")
        if ok {
            for _ in 0..<100 {
                key:=hostile_key(&h)
                at:=hostile_entry_index(model[:],key)
                serial+=1
                switch hostile_int(&h,7) {
                case 0,1,2:
                    evicted_key,evicted_value,evicted:=lru_put(&c,key,serial)
                    if at>=0 {
                        ordered_remove(&model,at)
                        testing.expect(t,!evicted,"Putting a key the cache has evicts nothing")
                    } else if len(model)>=capacity {
                        testing.expect(t,evicted && evicted_key==model[0].key && evicted_value==model[0].value,"A full cache evicts its least recently used entry")
                        ordered_remove(&model,0)
                    } else {
                        testing.expect(t,!evicted,"A cache with room evicts nothing")
                    }
                    append(&model,Hostile_Entry{key,serial})
                case 3:
                    value:=lru_get(&c,key)
                    if testing.expect(t,(value!=nil)==(at>=0),"A get finds the keys of the model") && at>=0 {
                        entry:=model[at]
                        testing.expect_value(t,value^,entry.value)
                        ordered_remove(&model,at);append(&model,entry)
                    }
                case 4:
                    value:=lru_peek(&c,key)
                    if testing.expect(t,(value!=nil)==(at>=0),"A peek finds the keys of the model") && at>=0 {testing.expect_value(t,value^,model[at].value)}
                case 5:
                    value,found:=lru_remove(&c,key)
                    if testing.expect(t,found==(at>=0),"A remove finds the keys of the model") && at>=0 {
                        testing.expect_value(t,value,model[at].value)
                        ordered_remove(&model,at)
                    }
                case 6:
                    if hostile_int(&h,10)==0 {lru_clear(&c);clear(&model)}
                }
                oldest_key,oldest_value,any:=lru_oldest(&c)
                testing.expect(t,lru_len(&c)==len(model) && any==(len(model)>0),"The cache holds the entries of the model")
                if any && len(model)>0 {testing.expect(t,oldest_key==model[0].key && oldest_value^==model[0].value,"The oldest entry is the least recently used")}
            }
            lru_destroy(&c)
        }
        lru_destroy(&c)
        zero:Lru(u32)
        key:=hostile_key(&h)
        _,_,evicted:=lru_put(&zero,key,1)
        _,removed:=lru_remove(&zero,key)
        _,_,any:=lru_oldest(&zero)
        testing.expect(t,!evicted && lru_get(&zero,key)==nil && lru_peek(&zero,key)==nil && !removed && lru_len(&zero)==0 && !any,"A zeroed cache holds nothing")
        lru_clear(&zero);lru_destroy(&zero)
    }
}

@(private="file")
Hostile_Priority :: struct {key:f32,value:u32}

@(test)
hostile_keys_through_the_priority_queue :: proc(t:^testing.T) {
    memory:Hostile_Memory
    context.allocator=hostile_memory_begin(&memory)
    defer hostile_memory_check(t,&memory)
    h:=Hostile{15}
    model:[dynamic]Hostile_Priority
    defer delete(model)
    serial:u32
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        clear(&model)
        q:Priority_Queue(f32,u32)
        keys:[8]f32
        values:[8]u32
        capacity:=hostile_int(&h,8)==0?hostile_huge(&h):hostile_size(&h)
        ok:bool
        if hostile_int(&h,4)==0 {
            first,second:=hostile_int(&h,9),hostile_int(&h,9)
            priority_queue_init_buffer(&q,keys[:first],values[:second])
            capacity=min(first,second);ok=true
        } else {
            ok=priority_queue_init(&q,capacity)
            testing.expect(t,ok==(capacity>0 && capacity<=HOSTILE_SIZE_HELD) && (ok || hostile_zeroed(&q)),"The queue takes the capacities it can hold and stays zeroed on the others")
        }
        if ok {
            // A NaN key has no order: from its push until the queue empties, only what leaves is checked, not when.
            unordered:=false
            for _ in 0..<80 {
                switch hostile_int(&h,5) {
                case 0,1,2:
                    key:=f32(hostile_int(&h,50))
                    switch hostile_int(&h,4) {
                    case 0: key=f32(0h7fc00000)
                    case 1: key=f32(0h7f800000)
                    }
                    serial+=1
                    pushed:=priority_queue_push(&q,key,serial)
                    testing.expect(t,pushed==(len(model)<capacity),"The queue is full exactly at its capacity")
                    if pushed {append(&model,Hostile_Priority{key,serial});unordered||=key!=key}
                case 3,4:
                    pop:=hostile_int(&h,2)==0
                    key:f32
                    value:u32
                    any:bool
                    if pop {key,value,any=priority_queue_pop(&q)} else {key,value,any=priority_queue_peek(&q)}
                    if !testing.expect(t,any==(len(model)>0),"The queue has an entry exactly when the model does") || !any {continue}
                    at,smallest:=-1,true
                    for entry,i in model {
                        if entry.value==value {at=i}
                        smallest&&=key<=entry.key
                    }
                    testing.expect(t,unordered || smallest,"The smallest key leaves first")
                    if testing.expect(t,at>=0 && transmute(u32)model[max(at,0)].key==transmute(u32)key,"What leaves the queue is an entry that was pushed") && pop {unordered_remove(&model,at)}
                    if hostile_int(&h,10)==0 {priority_queue_clear(&q);clear(&model)}
                }
                if len(model)==0 {unordered=false}
                testing.expect_value(t,q.count,len(model))
            }
            priority_queue_destroy(&q)
        }
        priority_queue_destroy(&q)
        zero:Priority_Queue(f32,u32)
        _,_,popped:=priority_queue_pop(&zero)
        _,_,peeked:=priority_queue_peek(&zero)
        testing.expect(t,!priority_queue_push(&zero,1,1) && !popped && !peeked,"A zeroed queue holds nothing")
        priority_queue_clear(&zero);priority_queue_destroy(&zero)
    }
}

@(test)
hostile_values_through_the_ring_and_queue :: proc(t:^testing.T) {
    memory:Hostile_Memory
    context.allocator=hostile_memory_begin(&memory)
    defer hostile_memory_check(t,&memory)
    h:=Hostile{16}
    model:[dynamic]u32 // front first
    defer delete(model)
    serial:u32
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        clear(&model)
        r:Ring(u32)
        buffer:[5]u32
        capacity:=hostile_int(&h,8)==0?hostile_huge(&h):hostile_size(&h)
        ok:bool
        if hostile_int(&h,4)==0 {
            capacity=hostile_int(&h,6)
            ring_init_buffer(&r,buffer[:capacity]);ok=true
        } else {
            ok=ring_init(&r,capacity)
            testing.expect(t,ok==(capacity>0 && capacity<=HOSTILE_SIZE_HELD) && (ok || hostile_zeroed(&r)),"The ring takes the capacities it can hold and stays zeroed on the others")
        }
        if ok {
            for _ in 0..<100 {
                serial+=1
                full:=len(model)>=capacity
                switch hostile_int(&h,8) {
                case 0:
                    testing.expect(t,ring_push_back(&r,serial)==!full,"The ring is full exactly at its capacity")
                    if !full {append(&model,serial)}
                case 1:
                    testing.expect(t,ring_push_front(&r,serial)==!full,"The ring is full exactly at its capacity")
                    if !full {inject_at(&model,0,serial)}
                case 2:
                    dropped,overwrote:=ring_push_overwrite(&r,serial)
                    testing.expect(t,overwrote==(full && capacity>0) && (!overwrote || dropped==model[0]),"A full ring drops its front to take a value")
                    if overwrote {ordered_remove(&model,0)}
                    if capacity>0 {append(&model,serial)}
                case 3:
                    value,any:=ring_pop_front(&r)
                    testing.expect(t,any==(len(model)>0) && (!any || value==model[0]),"The front leaves from the front")
                    if any {ordered_remove(&model,0)}
                case 4:
                    value,any:=ring_pop_back(&r)
                    testing.expect(t,any==(len(model)>0) && (!any || value==model[len(model)-1]),"The back leaves from the back")
                    if any {pop(&model)}
                case 5,6:
                    index:=hostile_small(&h)-1 if hostile_int(&h,2)==0 else hostile_size(&h)
                    value:=ring_get(&r,index)
                    inside:=index>=0 && index<len(model)
                    testing.expect(t,(value!=nil)==inside && (!inside || value^==model[index]),"Only an index below the count reaches a value")
                case 7:
                    if hostile_int(&h,10)==0 {ring_clear(&r);clear(&model)}
                }
                front,back:=ring_front(&r),ring_back(&r)
                testing.expect(t,r.count==len(model) && ring_space(&r)==capacity-len(model) && (front!=nil)==(len(model)>0) && (back!=nil)==(len(model)>0),"The ring holds the values of the model")
                if front!=nil && back!=nil && len(model)>0 {testing.expect(t,front^==model[0] && back^==model[len(model)-1],"The ends of the ring are those of the model")}
            }
            ring_destroy(&r)
        }
        ring_destroy(&r)
        zero:Ring(u32)
        _,overwrote:=ring_push_overwrite(&zero,1)
        _,front:=ring_pop_front(&zero)
        _,back:=ring_pop_back(&zero)
        refused:=!ring_push_back(&zero,1) && !ring_push_front(&zero,1) && !overwrote && !front && !back
        refused&&=ring_get(&zero,0)==nil && ring_front(&zero)==nil && ring_back(&zero)==nil && ring_space(&zero)==0
        testing.expect(t,refused,"A zeroed ring holds nothing")
        ring_clear(&zero);ring_destroy(&zero)

        q:Spsc_Queue(u32)
        capacity=hostile_int(&h,8)==0?hostile_huge(&h):hostile_size(&h)
        ok=spsc_init(&q,capacity)
        testing.expect(t,ok==(capacity>0 && capacity<=HOSTILE_SIZE_HELD) && (ok || hostile_zeroed(&q)),"The queue takes the capacities it can hold and stays zeroed on the others")
        if ok {
            pushed,popped:u32
            for _ in 0..<100 {
                if hostile_int(&h,3)<2 {
                    took:=spsc_push(&q,pushed)
                    testing.expect(t,took==(int(pushed-popped)<capacity),"The queue is full exactly at its capacity")
                    if took {pushed+=1}
                } else {
                    value,any:=spsc_pop(&q)
                    testing.expect(t,any==(pushed>popped) && (!any || value==popped),"Values leave the queue in the order they entered")
                    if any {popped+=1}
                }
                testing.expect_value(t,spsc_len(&q),int(pushed-popped))
            }
            spsc_destroy(&q)
        }
        spsc_destroy(&q)
        zero_queue:Spsc_Queue(u32)
        _,any:=spsc_pop(&zero_queue)
        testing.expect(t,!spsc_push(&zero_queue,1) && !any && spsc_len(&zero_queue)==0,"A zeroed queue holds nothing")
        spsc_destroy(&zero_queue)
    }
}

@(test)
hostile_keys_through_the_sparse_set :: proc(t:^testing.T) {
    memory:Hostile_Memory
    context.allocator=hostile_memory_begin(&memory)
    defer hostile_memory_check(t,&memory)
    h:=Hostile{17}
    model:map[u32]bool
    defer delete(model)
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        clear(&model)
        s:Sparse_Set
        sparse:[6]u32
        dense:[4]u32
        ok:bool
        if hostile_int(&h,4)==0 {
            sparse_set_init_buffer(&s,sparse[:hostile_int(&h,7)],dense[:hostile_int(&h,5)]);ok=true
        } else {
            key_bound:=hostile_int(&h,8)==0?hostile_huge(&h):hostile_size(&h)
            capacity:=hostile_int(&h,8)==0?hostile_huge(&h):hostile_size(&h)
            ok=sparse_set_init(&s,key_bound,capacity)
            // The capacity is at most the bound of the keys, so only the bound has to fit in memory.
            testing.expect(t,ok==(min(key_bound,capacity)>0 && key_bound<=HOSTILE_SIZE_HELD) && (ok || hostile_zeroed(&s)),"The set takes the sizes it can hold and stays zeroed on the others")
        }
        if ok {
            key_bound,capacity:=len(s.sparse),len(s.dense)
            for _ in 0..<100 {
                key:=u32(hostile_key(&h))
                if hostile_int(&h,8)==0 {key=u32(hostile_next(&h))}
                known:=key in model
                switch hostile_int(&h,6) {
                case 0,1:
                    index,inserted:=sparse_set_insert(&s,key)
                    fits:=int(key)<key_bound && (known || len(model)<capacity)
                    testing.expect(t,inserted==(fits && !known) && (index>=0)==fits,"An insert takes a new key below the bound while there is room")
                    if fits {
                        rows:=sparse_set_members(&s)
                        testing.expect(t,index<len(rows) && (index<0 || rows[index]==key),"The row of a key holds it")
                        model[key]=true
                    }
                case 2:
                    index,last,removed:=sparse_set_remove(&s,key)
                    testing.expect(t,removed==known && (!removed || (index>=0 && index<=last && last==len(model)-1)),"A remove reports the hole and the last row")
                    delete_key(&model,key)
                case 3:
                    index,found:=sparse_set_index(&s,key)
                    testing.expect(t,sparse_set_contains(&s,key)==known && found==known && (index>=0)==known,"Only the members of the model are in the set")
                case 4,5:
                    if hostile_int(&h,10)==0 {sparse_set_clear(&s);clear(&model)}
                }
                members:=sparse_set_members(&s)
                if !testing.expect(t,len(members)==len(model) && s.count==len(model),"The set has the members of the model") {return}
                for member,row in members {
                    index,_:=sparse_set_index(&s,member)
                    if !testing.expect(t,member in model && index==row,"Every row is a member that knows its row") {return}
                }
            }
            sparse_set_destroy(&s)
        }
        sparse_set_destroy(&s)
        zero:Sparse_Set
        key:=u32(hostile_int(&h,10))
        index,inserted:=sparse_set_insert(&zero,key)
        _,_,removed:=sparse_set_remove(&zero,key)
        _,found:=sparse_set_index(&zero,key)
        testing.expect(t,index==-1 && !inserted && !removed && !found && !sparse_set_contains(&zero,key) && len(sparse_set_members(&zero))==0,"A zeroed set has no members")
        sparse_set_clear(&zero);sparse_set_destroy(&zero)
    }
}

@(test)
hostile_counts_through_the_radix_sort :: proc(t:^testing.T) {
    h:=Hostile{18}
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        n:=hostile_int(&h,300)
        items:=make([]Sort_Key32,n);defer delete(items)
        wide:=make([]Sort_Key64,n);defer delete(wide)
        keys:=make([]u64,n);defer delete(keys)
        // A scratch shorter than the items cannot be used: nothing moves.
        short:=hostile_int(&h,4)==0
        room:=hostile_int(&h,n) if short else n+hostile_int(&h,3)
        scratch:=make([]Sort_Key32,room);defer delete(scratch)
        wide_scratch:=make([]Sort_Key64,room);defer delete(wide_scratch)
        shape:=hostile_int(&h,4)
        for i in 0..<n {
            key:=u64(hostile_next(&h))
            switch shape {
            case 1: key=0
            case 2: key=max(u64)
            case 3: key&=0xff
            }
            items[i]={u32(key),u32(i)}
            wide[i]={key,u32(i)}
            keys[i]=key
        }
        radix_sort32(items,scratch)
        radix_sort64(wide,wide_scratch)
        for i in 0..<n {
            if short {
                testing.expect(t,int(items[i].index)==i && int(wide[i].index)==i,"Without scratch nothing moves")
                continue
            }
            narrow,full:=items[i],wide[i]
            if !testing.expect(t,int(narrow.index)<n && int(full.index)<n && narrow.key==u32(keys[narrow.index]) && full.key==keys[full.index],"Every sorted item is one that was given") {break}
            if i==0 {continue}
            // Stable: equal keys keep the order they came in.
            testing.expect(t,items[i-1].key<narrow.key || (items[i-1].key==narrow.key && items[i-1].index<narrow.index),"The 32-bit keys are sorted and stable")
            testing.expect(t,wide[i-1].key<full.key || (wide[i-1].key==full.key && wide[i-1].index<full.index),"The 64-bit keys are sorted and stable")
        }
        radix_sort32(nil,nil);radix_sort64(nil,nil)
        a,b:=hostile_f32(&h),hostile_f32(&h)
        if a<b {testing.expect(t,sort_key_f32(a)<sort_key_f32(b),"Float keys sort like their numbers")}
        x,y:=i64(hostile_next(&h)),i64(hostile_next(&h))
        testing.expect(t,(x<y)==(sort_key_i64(x)<sort_key_i64(y)) && (i32(x)<i32(y))==(sort_key_i32(i32(x))<sort_key_i32(i32(y))),"Integer keys sort like their numbers")
    }
}

@(test)
hostile_bytes_through_the_text_buffers :: proc(t:^testing.T) {
    GUARD :: 0xa5
    h:=Hostile{20}
    source:[80]u8
    store,previous:[42]u8
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        text:=hostile_text(&h,source[:hostile_int(&h,41)])
        other:=hostile_text(&h,source[40:][:hostile_int(&h,20)])
        for &b in store {b=GUARD}
        start:=1+hostile_int(&h,40)
        buffer:=store[start:len(store)-1]
        if hostile_int(&h,2)==0 {buffer=buffer[:hostile_int(&h,len(buffer)+1)]}
        for &b in buffer {b=u8(hostile_next(&h))}

        whole:=text_set(buffer,text)
        got:=text_get(buffer)
        cut:=len(got)
        // The array holds the text up to its first NUL, or a prefix that ends at a code point.
        testing.expect(t,cut<=len(text) && got==text[:min(cut,len(text))] && cut==text_len(buffer) && text_equal(buffer,got),"The array holds a prefix of the text")
        testing.expect(t,whole==(got==text) && (whole || cut==0 || text[cut]&0xc0!=0x80),"text_set says whether the whole text is in the array, and cuts at a code point")
        testing.expect(t,hostile_filled(buffer[cut:],0) && (len(buffer)==0 || cut<len(buffer)),"The rest of the array is zeros and its last byte a NUL")

        previous=store
        held:=cut
        text_append(buffer,other)
        got=text_get(buffer)
        added:=len(got)-held
        testing.expect(t,added>=0 && added<=len(other) && got[:held]==string(previous[start:][:held]) && got[held:]==other[:max(added,0)],"An append keeps the text and adds a prefix")
        testing.expect(t,hostile_filled(buffer[len(got):],0),"The rest of the array is zeros after an append")

        second:=store[hostile_int(&h,len(store)):]
        second=second[:hostile_int(&h,len(second)+1)]
        testing.expect_value(t,text_compare(buffer,second),-text_compare(second,buffer))
        testing.expect_value(t,text_compare(buffer,buffer),0)

        formats:=[?]string{"%s","%v","%d","%","%%%","%*d","%[9]d","%!","%s%s%s",string(source[:hostile_int(&h,10)])}
        complete:=text_format(buffer,formats[hostile_int(&h,len(formats))],text,hostile_int(&h,100))
        testing.expect(t,!complete || len(buffer)>0,"Nothing is complete in an array without room")
        testing.expect(t,hostile_filled(buffer[text_len(buffer):],0) && (len(buffer)==0 || text_len(buffer)<len(buffer)),"A formatted text ends in zeros")
        text_clear(buffer)
        testing.expect(t,hostile_filled(buffer,0) && text_len(buffer)==0,"A cleared array is zeros")
        testing.expect(t,hostile_filled(store[:start],GUARD) && hostile_filled(store[start+len(buffer):],GUARD),"The text procedures write only inside their array")

        testing.expect(t,text_set(nil,text)==(len(text)==0) && text_append(nil,text)==(len(text)==0) && !text_format(nil,"%s",text),"An array without room holds no text")
        testing.expect(t,text_get(nil)=="" && text_len(nil)==0 && text_compare(nil,nil)==0,"An array without room reads as empty")
        text_clear(nil)
    }
}

@(test)
hostile_sizes_through_the_region :: proc(t:^testing.T) {
    h:=Hostile{21}
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        r:Region
        size:=hostile_size(&h)
        if size>1<<28 {size=1<<28}
        if region_reserve(&r,size) {
            testing.expect(t,size>0 && len(r.data)>=size && r.committed==0 && r.tail==0,"A reserved region has the bytes asked and none committed")
            for _ in 0..<10 {
                want:=hostile_int(&h,3)==0?hostile_size(&h):hostile_int(&h,1<<18)
                if want>1<<24 {want=len(r.data)+hostile_int(&h,3)-1+(hostile_int(&h,2)==0?0:1<<40)}
                tail:=hostile_int(&h,2)==0
                before:=r
                committed:=region_commit_tail(&r,want) if tail else region_commit(&r,want)
                now,was:=r.tail if tail else r.committed,before.tail if tail else before.committed
                if !committed {
                    testing.expect(t,want>len(r.data) && r.committed==before.committed && r.tail==before.tail && raw_data(r.data)==raw_data(before.data),"A commit past the reserve is refused and changes nothing")
                    continue
                }
                testing.expect(t,now>=max(want,was) && now<=len(r.data) && raw_data(r.data)==raw_data(before.data),"A commit covers the bytes asked without moving the region")
                // While the two ends have not met, the bytes a commit adds were never written.
                if now>was && r.committed+r.tail<=len(r.data) {
                    fresh:=r.data[len(r.data)-now:][:now-was] if tail else r.data[was:now]
                    testing.expect(t,fresh[0]==0 && fresh[len(fresh)-1]==0,"Committed bytes are zero")
                    fresh[0]=1;fresh[len(fresh)-1]=1
                }
            }
            count:=hostile_small(&h)-1
            testing.expect_value(t,len(region_slice(&r,u32,count)),clamp(count,0,len(r.data)/size_of(u32)))
            region_release(&r)
        } else {
            testing.expect(t,size<=0 && hostile_zeroed(&r),"Only an empty region is refused, and it stays zeroed")
        }
        region_release(&r)
        testing.expect(t,hostile_zeroed(&r),"A released region is zeroed")

        capacity:=hostile_size(&h)>>20
        list,ok:=region_dynamic(&r,u64,capacity)
        testing.expect(t,!ok || (capacity>0 && len(list)==0 && cap(list)==capacity),"A list over a region is empty with the capacity asked")
        if ok {
            for _ in 0..<5 {
                count:=hostile_small(&h) if hostile_int(&h,4)!=0 else max(int)-hostile_int(&h,100)
                held:=len(list)
                grown:=region_grow(&r,&list,count)
                testing.expect(t,grown==(count<=capacity-held),"A list grows while it has capacity")
                if grown && count>=1 {
                    for i in 0..<count {append(&list,u64(held+i))}
                    testing.expect(t,len(list)==held+count && list[held+count-1]==u64(held+count-1) && rawptr(raw_data(list))==rawptr(raw_data(r.data)),"The appends land in the region")
                }
            }
        }
        region_release(&r)
        zero:Region
        testing.expect(t,region_commit(&zero,hostile_int(&h,5000)+1)==false && region_commit_tail(&zero,hostile_int(&h,5000)+1)==false && hostile_zeroed(&zero),"A zeroed region commits nothing")
        region_release(&zero)
    }
}

@(test)
hostile_sizes_through_the_profile :: proc(t:^testing.T) {
    memory:Hostile_Memory
    context.allocator=hostile_memory_begin(&memory)
    defer hostile_memory_check(t,&memory)
    h:=Hostile{23}
    SENTINEL :: Profile_Zone{name="untouched",thread=max(u16)}
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        p:Profile
        threads,zones:=hostile_small(&h)-1,hostile_small(&h)-1
        ok:=profile_init(&p,{threads,zones,{}})
        testing.expect(t,ok==(threads>0 && zones>0) && (ok || hostile_zeroed(&p)),"The profile takes positive sizes and stays zeroed on the others")
        if ok {
            out:[9]Profile_Zone
            for _ in 0..<60 {
                thread:=hostile_small(&h)-1
                inside:=thread>=0 && thread<threads
                switch hostile_int(&h,6) {
                case 0,1:
                    scope:=profile_begin(&p,thread,"zone")
                    if hostile_int(&h,3)!=0 {profile_end(scope)}
                case 2:
                    func:=proc(p:^Profile,thread:int) {
                        profile_zone(p,thread,"nested")
                        profile_zone(p,thread,"inner")
                    }
                    func(&p,thread)
                case 3:
                    for &zone in out {zone=SENTINEL}
                    room:=hostile_int(&h,len(out))
                    since:=u64(hostile_int(&h,64))
                    count,next,lost:=profile_read_since(&p,thread,since,out[:room])
                    testing.expect(t,count>=0 && count<=room && (inside || (count==0 && next==since && lost==0)),"A read fills at most its room, and nothing for a thread out of range")
                    testing.expect(t,next<=since || u64(count)+lost==next-since,"Every zone since the last read is either read or lost")
                    for zone,i in out {
                        if i<count {
                            testing.expect(t,int(zone.thread)==thread && zone.duration>=0 && (zone.name=="zone" || zone.name=="nested" || zone.name=="inner"),"A zone read is one that was recorded on its thread")
                        } else {
                            testing.expect(t,zone==SENTINEL,"A read writes only the zones it returns")
                        }
                    }
                    count=profile_read(&p,thread,out[:room])
                    testing.expect(t,count>=0 && count<=room && (inside || (count==0 && profile_lost(&p,thread)==0)),"The newest zones fit their room, and none are of a thread out of range")
                case 4:
                    profile_frame(&p);profile_set_enabled(&p,hostile_int(&h,2)==0)
                case 5:
                    if hostile_int(&h,8)==0 {
                        profile_clear(&p)
                        testing.expect(t,!inside || (profile_read(&p,thread,out[:])==0 && profile_lost(&p,thread)==0),"A cleared profile has no zones")
                    }
                }
            }
            profile_destroy(&p)
        }
        profile_destroy(&p)
        testing.expect(t,hostile_zeroed(&p),"A destroyed profile is zeroed")
        zero:Profile
        scope:=profile_begin(&zero,hostile_small(&h)-1,"zone")
        profile_end(scope)
        profile_end({})
        out:[2]Profile_Zone
        count,_,lost:=profile_read_since(&zero,hostile_small(&h)-1,u64(hostile_small(&h)),out[:])
        testing.expect(t,profile_read(&zero,hostile_small(&h)-1,out[:])==0 && profile_lost(&zero,hostile_small(&h)-1)==0 && count==0 && lost==0,"A zeroed profile records nothing")
        profile_frame(&zero);profile_clear(&zero);profile_destroy(&zero)
        profile_end(profile_begin(nil,0,"nil"))
    }
}

// ---------------------------------------------------------------- capacities beyond memory

// True when the init of a structure took a capacity no machine holds, or refused it leaving something behind.
@(private="file")
Hostile_Capacity :: struct {name:string,took:proc(h:^Hostile) -> bool}

@(test)
hostile_capacities_no_memory_holds :: proc(t:^testing.T) {
    memory:Hostile_Memory
    context.allocator=hostile_memory_begin(&memory)
    defer hostile_memory_check(t,&memory)
    families:=[?]Hostile_Capacity{
        {"arena",proc(h:^Hostile) -> bool {a:Arena;return arena_init(&a,hostile_huge(h)) || !hostile_zeroed(&a)}},
        {"stack",proc(h:^Hostile) -> bool {s:Stack;return stack_init(&s,hostile_huge(h)) || !hostile_zeroed(&s)}},
        {"heap",proc(h:^Hostile) -> bool {heap:Heap;return heap_init(&heap,hostile_huge(h)) || !hostile_zeroed(&heap)}},
        {"frame allocator",proc(h:^Hostile) -> bool {f:Frame_Allocator;return frame_init(&f,hostile_huge(h)) || !hostile_zeroed(&f)}},
        {"block pool",proc(h:^Hostile) -> bool {
            p:Block_Pool
            sizes:=[2]int{hostile_huge(h),hostile_huge(h)}
            if shape:=hostile_int(h,3);shape<2 {sizes[shape]=hostile_int(h,50)+1}
            return block_pool_init(&p,sizes[0],sizes[1]) || !hostile_zeroed(&p)
        }},
        {"handle pool",proc(h:^Hostile) -> bool {p:Handle_Pool;return handle_pool_init(&p,hostile_huge(h)) || !hostile_zeroed(&p)}},
        {"slot map",proc(h:^Hostile) -> bool {m:Slot_Map(u32,Handle);return slot_map_init(&m,hostile_huge(h)) || !hostile_zeroed(&m)}},
        {"hash map",proc(h:^Hostile) -> bool {m:Hash_Map(u32);return hash_map_init(&m,hostile_huge(h)) || !hostile_zeroed(&m)}},
        {"lru",proc(h:^Hostile) -> bool {c:Lru(u32);return lru_init(&c,hostile_huge(h)) || !hostile_zeroed(&c)}},
        {"priority queue",proc(h:^Hostile) -> bool {q:Priority_Queue(f32,u32);return priority_queue_init(&q,hostile_huge(h)) || !hostile_zeroed(&q)}},
        {"ring",proc(h:^Hostile) -> bool {r:Ring(u32);return ring_init(&r,hostile_huge(h)) || !hostile_zeroed(&r)}},
        {"spsc queue",proc(h:^Hostile) -> bool {q:Spsc_Queue(u32);return spsc_init(&q,hostile_huge(h)) || !hostile_zeroed(&q)}},
        {"sparse set",proc(h:^Hostile) -> bool {
            s:Sparse_Set
            return sparse_set_init(&s,hostile_huge(h),hostile_int(h,2)==0?hostile_huge(h):hostile_int(h,50)+1) || !hostile_zeroed(&s)
        }},
        {"interner",proc(h:^Hostile) -> bool {
            table:Interner
            sizes:=[2]int{hostile_huge(h),hostile_huge(h)}
            if shape:=hostile_int(h,3);shape<2 {sizes[shape]=hostile_int(h,50)+1}
            return intern_init(&table,sizes[0],sizes[1]) || !hostile_zeroed(&table)
        }},
        {"profile",proc(h:^Hostile) -> bool {
            p:Profile
            sizes:=[2]int{hostile_huge(h),hostile_huge(h)}
            if shape:=hostile_int(h,3);shape<2 {sizes[shape]=hostile_int(h,4)+1}
            return profile_init(&p,{sizes[0],sizes[1],{}}) || !hostile_zeroed(&p)
        }},
        {"region",proc(h:^Hostile) -> bool {r:Region;return region_reserve(&r,hostile_huge(h)) || !hostile_zeroed(&r)}},
        {"region list",proc(h:^Hostile) -> bool {
            r:Region
            _,ok:=region_dynamic(&r,u64,hostile_huge(h))
            return ok || !hostile_zeroed(&r)
        }},
    }
    for family,seed in families {
        h:=Hostile{u64(seed)+40}
        for _ in 0..<HOSTILE_ROUNDS {
            if !testing.expectf(t,!family.took(&h),"%s: took a capacity no memory holds, or refused it leaving something behind",family.name) {break}
        }
    }
}
