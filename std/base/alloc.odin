package base

import "base:runtime"
import "core:mem"
import "core:mem/tlsf"

// Allocators over a fixed block of memory. None of them asks for more: a
// request that does not fit fails with .Out_Of_Memory and is counted. They are
// not thread safe.

Alloc_Stats :: struct {
    capacity:int, // bytes
    used:int,     // bytes
    peak:int,     // largest used since init
    requests:u64, // allocations served
    failed:u64,   // allocations refused for lack of room
}

// Bytes std/base asks an allocator for at most: allocators add headers and
// alignment to the size, a sum that past this can overflow inside them.
@(private) ALLOC_MAX :: max(int)/2

@(private)
block_acquire :: proc(size,alignment:int,allocator:runtime.Allocator) -> ([]byte,bool) {
    if size<=0 || size>ALLOC_MAX {return nil,false}
    memory,error:=mem.alloc_bytes_non_zeroed(size,alignment,allocator)
    return memory,error==nil && memory!=nil
}
@(private)
block_release :: proc(memory:[]byte,owner:runtime.Allocator) {
    if owner.procedure!=nil && memory!=nil {mem.free_bytes(memory,owner)}
}
@(private)
alignment_valid :: #force_inline proc "contextless" (alignment:int) -> bool {return alignment>0 && alignment&(alignment-1)==0}
// make for a count the caller chose: false instead of a crash when the count
// is negative, its bytes pass ALLOC_MAX or the allocator has no memory.
@(private)
slice_make :: proc($T:typeid/[]$E,count:int,allocator:runtime.Allocator,loc:=#caller_location) -> (T,bool) {
    if count<0 || count>ALLOC_MAX/max(size_of(E),1) {return nil,false}
    s,error:=make(T,count,allocator,loc)
    if error!=nil || len(s)!=count {delete(s,allocator,loc);return nil,false}
    return s,true
}

// Shortens a dynamic array to count elements it already holds. resize does
// the same and may also grow, so its error has to be received; this asks for
// no memory and cannot fail. A count past the length changes nothing.
truncate :: proc "contextless" (array:^$T/[dynamic]$E,#any_int count:int) {
    raw:=(^runtime.Raw_Dynamic_Array)(array)
    raw.len=clamp(count,0,raw.len)
}

// ---------------------------------------------------------------- arena

// Linear allocator: everything is released together, by arena_reset or back
// to a mark. It is mem.Arena with counters, and its last allocation grows in place.
Arena :: struct {
    arena:mem.Arena,
    requests,failed:u64,
    owner:runtime.Allocator, // allocator of the block; none when the caller supplied it
}

arena_init :: proc(a:^Arena,capacity:int,allocator:=context.allocator) -> bool {
    a^={}
    memory,ok:=block_acquire(capacity,mem.DEFAULT_ALIGNMENT,allocator)
    if !ok {return false}
    mem.arena_init(&a.arena,memory)
    a.owner=allocator
    return true
}
arena_init_buffer :: proc(a:^Arena,memory:[]byte) {
    a^={}
    mem.arena_init(&a.arena,memory)
}
arena_destroy :: proc(a:^Arena) {
    block_release(a.arena.data,a.owner)
    a^={}
}
arena_allocator :: proc(a:^Arena) -> runtime.Allocator {return {arena_allocator_proc,a}}
arena_reset :: proc(a:^Arena) {a.arena.offset=0}
// Position to give back to arena_rewind, which releases what was allocated
// after it. A mark past the current position changes nothing.
arena_mark :: proc(a:^Arena) -> int {return a.arena.offset}
arena_rewind :: proc(a:^Arena,mark:int) {
    if mark>=0 && mark<=a.arena.offset {a.arena.offset=mark}
}
arena_stats :: proc(a:^Arena) -> Alloc_Stats {
    return {len(a.arena.data),a.arena.offset,a.arena.peak_used,a.requests,a.failed}
}
// Zeroed bytes, or nil when they do not fit.
arena_alloc :: proc(a:^Arena,size:int,alignment:=mem.DEFAULT_ALIGNMENT) -> []byte {
    bytes,_:=arena_allocator_proc(a,.Alloc,size,alignment,nil,0)
    return bytes
}

arena_allocator_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    a:=(^Arena)(data)
    switch mode {
    case .Alloc,.Alloc_Non_Zeroed:
        if a.arena.data==nil || size<0 || size>len(a.arena.data)-a.arena.offset || !alignment_valid(alignment) {a.failed+=1;return nil,.Out_Of_Memory}
        bytes,error:=mem.arena_alloc_bytes_non_zeroed(&a.arena,size,alignment,loc)
        if error!=nil {a.failed+=1;return nil,error}
        if mode==.Alloc {mem.zero_slice(bytes)}
        a.requests+=1
        return bytes,nil
    case .Resize,.Resize_Non_Zeroed:
        if old_memory==nil {return arena_allocator_proc(data,.Alloc if mode==.Resize else .Alloc_Non_Zeroed,size,alignment,nil,0,loc)}
        if size<=0 {return nil,nil}
        if old_size<0 || !alignment_valid(alignment) {a.failed+=1;return nil,.Out_Of_Memory}
        end:=uintptr(raw_data(a.arena.data))+uintptr(a.arena.offset)
        if uintptr(old_memory)+uintptr(old_size)==end && old_size<=a.arena.offset && mem.is_aligned(old_memory,alignment) {
            start:=a.arena.offset-old_size
            if size>len(a.arena.data)-start {a.failed+=1;return nil,.Out_Of_Memory}
            offset:=start+size
            a.arena.offset=offset;a.arena.peak_used=max(a.arena.peak_used,offset)
            bytes:=([^]byte)(old_memory)[:size]
            if mode==.Resize && size>old_size {mem.zero_slice(bytes[old_size:])}
            return bytes,nil
        }
        if size<=old_size && mem.is_aligned(old_memory,alignment) {return ([^]byte)(old_memory)[:size],nil}
        bytes,error:=arena_allocator_proc(data,.Alloc_Non_Zeroed,size,alignment,nil,0,loc)
        if error!=nil {return nil,error}
        kept:=copy(bytes,([^]byte)(old_memory)[:old_size])
        if mode==.Resize {mem.zero_slice(bytes[kept:])}
        return bytes,nil
    case .Free:
        return nil,.Mode_Not_Implemented
    case .Free_All:
        arena_reset(a)
    case .Query_Features:
        if set:=(^runtime.Allocator_Mode_Set)(old_memory);set!=nil {
            set^={.Alloc,.Alloc_Non_Zeroed,.Free_All,.Resize,.Resize_Non_Zeroed,.Query_Features}
        }
    case .Query_Info:
        return nil,.Mode_Not_Implemented
    }
    return nil,nil
}

// ---------------------------------------------------------------- stack

// Linear allocator that also frees one allocation at a time, newest first.
// A header before each allocation keeps the position to go back to.
Stack :: struct {
    data:[]byte,
    used:int, // bytes, with headers and padding
    last:int, // offset of the newest allocation; 0 when there is none
    peak:int,
    requests,failed:u64,
    owner:runtime.Allocator,
}

@(private)
Stack_Header :: struct {used,last:int} // those of the Stack before the allocation that follows

stack_init :: proc(s:^Stack,capacity:int,allocator:=context.allocator) -> bool {
    s^={}
    memory,ok:=block_acquire(capacity,mem.DEFAULT_ALIGNMENT,allocator)
    if !ok {return false}
    s.data=memory;s.owner=allocator
    return true
}
stack_init_buffer :: proc(s:^Stack,memory:[]byte) {s^={data=memory}}
stack_destroy :: proc(s:^Stack) {
    block_release(s.data,s.owner)
    s^={}
}
stack_allocator :: proc(s:^Stack) -> runtime.Allocator {return {stack_allocator_proc,s}}
stack_reset :: proc(s:^Stack) {s.used=0;s.last=0}
stack_stats :: proc(s:^Stack) -> Alloc_Stats {return {len(s.data),s.used,s.peak,s.requests,s.failed}}

@(private)
stack_push :: proc(s:^Stack,size,alignment:int) -> ([]byte,runtime.Allocator_Error) {
    if size<0 || size>len(s.data)-s.used || !alignment_valid(alignment) {s.failed+=1;return nil,.Out_Of_Memory}
    start:=uintptr(raw_data(s.data))
    at:=int(mem.align_forward_uintptr(start+uintptr(s.used+size_of(Stack_Header)),uintptr(max(alignment,align_of(Stack_Header))))-start)
    if at>len(s.data)-size {s.failed+=1;return nil,.Out_Of_Memory}
    (^Stack_Header)(&s.data[at-size_of(Stack_Header)])^={s.used,s.last}
    s.used=at+size;s.last=at;s.peak=max(s.peak,s.used)
    s.requests+=1
    return s.data[at:][:size],nil
}
// False when the memory is not the newest allocation.
@(private)
stack_pop :: proc(s:^Stack,memory:rawptr) -> bool {
    if s.last==0 || uintptr(memory)!=uintptr(raw_data(s.data))+uintptr(s.last) {return false}
    header:=(^Stack_Header)(&s.data[s.last-size_of(Stack_Header)])^
    s.used=header.used;s.last=header.last
    return true
}

stack_allocator_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    s:=(^Stack)(data)
    switch mode {
    case .Alloc,.Alloc_Non_Zeroed:
        bytes,error:=stack_push(s,size,alignment)
        if error==nil && mode==.Alloc {mem.zero_slice(bytes)}
        return bytes,error
    case .Free:
        if old_memory==nil {return nil,nil}
        return nil,.None if stack_pop(s,old_memory) else .Invalid_Pointer
    case .Free_All:
        stack_reset(s)
    case .Resize,.Resize_Non_Zeroed:
        if old_memory==nil {return stack_allocator_proc(data,.Alloc if mode==.Resize else .Alloc_Non_Zeroed,size,alignment,nil,0,loc)}
        if size<=0 {return stack_allocator_proc(data,.Free,0,0,old_memory,old_size,loc)}
        start:=uintptr(raw_data(s.data))
        if uintptr(old_memory)<start || uintptr(old_memory)>=start+uintptr(s.used) {return nil,.Invalid_Pointer}
        offset:=int(uintptr(old_memory)-start)
        if offset==s.last && alignment_valid(alignment) && mem.is_aligned(old_memory,alignment) {
            if size>len(s.data)-offset {s.failed+=1;return nil,.Out_Of_Memory}
            current:=s.used-offset
            s.used=offset+size;s.peak=max(s.peak,s.used)
            bytes:=s.data[offset:][:size]
            if mode==.Resize && size>current {mem.zero_slice(bytes[current:])}
            return bytes,nil
        }
        // Any other allocation moves to the top.
        if old_size<0 || old_size>s.used-offset {return nil,.Invalid_Pointer}
        bytes,error:=stack_push(s,size,alignment)
        if error!=nil {return nil,error}
        kept:=copy(bytes,s.data[offset:][:old_size])
        if mode==.Resize {mem.zero_slice(bytes[kept:])}
        return bytes,nil
    case .Query_Features:
        if set:=(^runtime.Allocator_Mode_Set)(old_memory);set!=nil {
            set^={.Alloc,.Alloc_Non_Zeroed,.Free,.Free_All,.Resize,.Resize_Non_Zeroed,.Query_Features}
        }
    case .Query_Info:
        return nil,.Mode_Not_Implemented
    }
    return nil,nil
}

// ---------------------------------------------------------------- heap

// General allocator with constant-time alloc and free of any size (TLSF). Its
// bookkeeping lives at the head of the block: HEAP_OVERHEAD bytes, and one bit
// for every 8 bytes of the rest, are not available to allocations.
Heap :: struct {
    control:^tlsf.Allocator,
    memory:[]byte,
    pool:[]byte,
    starts:[]u64,  // bit n is set while an allocation starts 8n bytes into the pool
    used,peak:int, // bytes, counting the header of every allocation
    requests,failed:u64,
    owner:runtime.Allocator,
}

HEAP_OVERHEAD :: size_of(tlsf.Allocator)+tlsf.INITIAL_POOL_OVERHEAD

heap_init :: proc(h:^Heap,capacity:int,allocator:=context.allocator) -> bool {
    h^={}
    memory,ok:=block_acquire(capacity,align_of(tlsf.Allocator),allocator)
    if !ok {return false}
    if !heap_init_buffer(h,memory) {block_release(memory,allocator);return false}
    h.owner=allocator
    return true
}
// False when the block is too small, too large or not aligned to 8 bytes.
heap_init_buffer :: proc(h:^Heap,memory:[]byte) -> bool {
    h^={}
    if len(memory)<=size_of(tlsf.Allocator) || !mem.is_aligned(raw_data(memory),align_of(tlsf.Allocator)) {return false}
    rest:=memory[size_of(tlsf.Allocator):]
    words:=len(rest)/(64*8+size_of(u64))+1
    if words*size_of(u64)>=len(rest) {return false}
    control:=(^tlsf.Allocator)(raw_data(memory))
    control^={}
    pool:=rest[words*size_of(u64):]
    if tlsf.init_from_buffer(control,pool)!=.None {return false}
    h.control=control;h.memory=memory;h.pool=pool
    h.starts=(cast([^]u64)raw_data(rest))[:words]
    bits_clear_all(h.starts)
    return true
}
heap_destroy :: proc(h:^Heap) {
    block_release(h.memory,h.owner)
    h^={}
}
heap_allocator :: proc(h:^Heap) -> runtime.Allocator {return {heap_allocator_proc,h}}
// Releases every allocation at once.
heap_reset :: proc(h:^Heap) {
    if h.control==nil {return}
    tlsf.allocator_proc(h.control,.Free_All,0,0,nil,0)
    bits_clear_all(h.starts)
    h.used=0
}
heap_stats :: proc(h:^Heap) -> Alloc_Stats {return {len(h.memory),h.used,h.peak,h.requests,h.failed}}

// A used TLSF block stores its size, with two flag bits, right before the memory it hands out.
@(private)
heap_block_bytes :: proc(memory:rawptr) -> int {
    if memory==nil {return 0}
    size:=(^uint)(uintptr(memory)-size_of(uint))^
    return int(size&~(tlsf.BLOCK_HEADER_FREE|tlsf.BLOCK_HEADER_PREV_FREE))+int(tlsf.BLOCK_HEADER_OVERHEAD)
}

heap_allocator_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    h:=(^Heap)(data)
    if h.control==nil {
        if mode==.Alloc || mode==.Alloc_Non_Zeroed {h.failed+=1}
        return nil,.Out_Of_Memory
    }
    switch mode {
    case .Alloc,.Alloc_Non_Zeroed:
        if size<=0 {return nil,nil}
        // TLSF asserts on alignments that are not powers of two, and a resize past its largest block returns more than the block.
        if !alignment_valid(alignment) || size>len(h.pool)-alignment {h.failed+=1;return nil,.Out_Of_Memory}
        bytes,error:=tlsf.allocator_proc(h.control,mode,size,alignment,nil,0,loc)
        if error!=nil || bytes==nil {h.failed+=1;return nil,.Out_Of_Memory}
        bits_set(h.starts,heap_slot(h,raw_data(bytes)))
        h.used+=heap_block_bytes(raw_data(bytes));h.peak=max(h.peak,h.used);h.requests+=1
        return bytes[:size],nil
    case .Free:
        if old_memory==nil {return nil,nil}
        slot:=heap_slot(h,old_memory)
        if !bits_test(h.starts,slot) {return nil,.Invalid_Pointer}
        bits_clear(h.starts,slot)
        h.used-=heap_block_bytes(old_memory)
        return tlsf.allocator_proc(h.control,.Free,0,0,old_memory,old_size,loc)
    case .Resize,.Resize_Non_Zeroed:
        if old_memory==nil {return heap_allocator_proc(data,.Alloc if mode==.Resize else .Alloc_Non_Zeroed,size,alignment,nil,0,loc)}
        slot:=heap_slot(h,old_memory)
        if !bits_test(h.starts,slot) {return nil,.Invalid_Pointer}
        if size<=0 {return heap_allocator_proc(data,.Free,0,0,old_memory,old_size,loc)}
        if !alignment_valid(alignment) || size>len(h.pool)-alignment {h.failed+=1;return nil,.Out_Of_Memory}
        before:=heap_block_bytes(old_memory)
        // TLSF copies min(old_size, new size) bytes when it has to move the block.
        known:=old_size if old_size>0 else before-int(tlsf.BLOCK_HEADER_OVERHEAD)
        bytes,error:=tlsf.allocator_proc(h.control,mode,size,alignment,old_memory,known,loc)
        if error!=nil || bytes==nil {h.failed+=1;return nil,.Out_Of_Memory}
        if raw_data(bytes)!=old_memory {bits_clear(h.starts,slot);bits_set(h.starts,heap_slot(h,raw_data(bytes)))}
        h.used+=heap_block_bytes(raw_data(bytes))-before;h.peak=max(h.peak,h.used)
        return bytes[:size],nil
    case .Free_All:
        heap_reset(h)
    case .Query_Features:
        if set:=(^runtime.Allocator_Mode_Set)(old_memory);set!=nil {
            set^={.Alloc,.Alloc_Non_Zeroed,.Free,.Free_All,.Resize,.Resize_Non_Zeroed,.Query_Features}
        }
    case .Query_Info:
        return nil,.Mode_Not_Implemented
    }
    return nil,nil
}

// Bit of starts for an address, or -1 when no allocation can start there.
@(private)
heap_slot :: #force_inline proc "contextless" (h:^Heap,memory:rawptr) -> int {
    offset:=uintptr(memory)-uintptr(raw_data(h.pool))
    return int(offset>>3) if uintptr(memory)>=uintptr(raw_data(h.pool)) && offset&7==0 else -1
}

// ---------------------------------------------------------------- frame

// Two arenas used in turn. frame_swap empties the older one and makes it
// current, so what a frame allocates stays valid until the end of the next.
// frame_allocator does not change with the swap: it can stay in a context.
Frame_Allocator :: struct {
    arenas:[2]Arena,
    current:int,
    frame:u64,
    memory:[]byte,
    owner:runtime.Allocator,
}

// Reserves capacity bytes for each of the two frames.
frame_init :: proc(f:^Frame_Allocator,capacity:int,allocator:=context.allocator) -> bool {
    f^={}
    if capacity<=0 || capacity>max(int)/2-mem.DEFAULT_ALIGNMENT {return false}
    half:=mem.align_forward_int(capacity,mem.DEFAULT_ALIGNMENT)
    memory,ok:=block_acquire(half*2,mem.DEFAULT_ALIGNMENT,allocator)
    if !ok {return false}
    f.memory=memory;f.owner=allocator
    arena_init_buffer(&f.arenas[0],memory[:capacity])
    arena_init_buffer(&f.arenas[1],memory[half:][:capacity])
    return true
}
frame_destroy :: proc(f:^Frame_Allocator) {
    block_release(f.memory,f.owner)
    f^={}
}
frame_swap :: proc(f:^Frame_Allocator) {
    f.current~=1;f.frame+=1
    arena_reset(&f.arenas[f.current])
}
frame_allocator :: proc(f:^Frame_Allocator) -> runtime.Allocator {return {frame_allocator_proc,f}}
// Zeroed bytes that live until the end of the next frame, or nil when they do not fit.
frame_alloc :: proc(f:^Frame_Allocator,size:int,alignment:=mem.DEFAULT_ALIGNMENT) -> []byte {
    return arena_alloc(&f.arenas[f.current],size,alignment)
}
// Capacity and used are those of the current frame; peak is the largest frame so far.
frame_stats :: proc(f:^Frame_Allocator) -> Alloc_Stats {
    a,b:=arena_stats(&f.arenas[f.current]),arena_stats(&f.arenas[f.current~1])
    return {a.capacity,a.used,max(a.peak,b.peak),a.requests+b.requests,a.failed+b.failed}
}

frame_allocator_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    f:=(^Frame_Allocator)(data)
    return arena_allocator_proc(&f.arenas[f.current],mode,size,alignment,old_memory,old_size,loc)
}

// ---------------------------------------------------------------- block pool

// Blocks of one size carved from a single region: constant-time alloc and
// free, no fragmentation. Blocks are identified by index as well as by address.
Block_Pool :: struct {
    blocks:[]byte,
    next:[]u32,    // free list: the block to reuse after this one, plus 1; BLOCK_USED while handed out
    block_size:int,
    stride:int,    // block_size rounded up to the alignment
    capacity:int,  // blocks
    fresh:int,     // blocks from here on were never handed out
    free_head:u32, // first block of the free list, plus 1; 0 when it is empty
    in_use,peak:int,
    requests,failed:u64,
    memory:[]byte,
    owner:runtime.Allocator,
}

@(private) BLOCK_USED :: u32(0xffffffff)

block_pool_init :: proc(p:^Block_Pool,block_size,block_count:int,block_align:=mem.DEFAULT_ALIGNMENT,allocator:=context.allocator) -> bool {
    p^={}
    if block_size<=0 || block_count<=0 || block_count>=int(BLOCK_USED) || !alignment_valid(block_align) || block_size>max(int)/2-block_align {return false}
    stride:=mem.align_forward_int(block_size,block_align)
    if stride>max(int)/2/block_count {return false}
    links:=mem.align_forward_int(stride*block_count,align_of(u32))
    memory,ok:=block_acquire(links+block_count*size_of(u32),max(block_align,align_of(u32)),allocator)
    if !ok {return false}
    p.memory=memory;p.owner=allocator
    block_pool_setup(p,memory[:stride*block_count],(cast([^]u32)raw_data(memory[links:]))[:block_count],block_size,stride)
    return true
}
// Uses as many blocks as fit in the memory; false when not even one does.
block_pool_init_buffer :: proc(p:^Block_Pool,memory:[]byte,block_size:int,block_align:=mem.DEFAULT_ALIGNMENT) -> bool {
    p^={}
    if block_size<=0 || !alignment_valid(block_align) || block_size>max(int)/2-block_align {return false}
    stride:=mem.align_forward_int(block_size,block_align)
    start:=int(uintptr(mem.align_forward(raw_data(memory),uintptr(block_align)))-uintptr(raw_data(memory)))
    if start>=len(memory) {return false}
    usable:=memory[start:]
    count:=min(len(usable)/(stride+size_of(u32)),int(BLOCK_USED)-1)
    for count>0 && mem.align_forward_int(stride*count,align_of(u32))+count*size_of(u32)>len(usable) {count-=1}
    if count<=0 {return false}
    links:=mem.align_forward_int(stride*count,align_of(u32))
    block_pool_setup(p,usable[:stride*count],(cast([^]u32)raw_data(usable[links:]))[:count],block_size,stride)
    return true
}
@(private)
block_pool_setup :: proc(p:^Block_Pool,blocks:[]byte,next:[]u32,block_size,stride:int) {
    p.blocks=blocks;p.next=next
    p.block_size=block_size;p.stride=stride;p.capacity=len(next)
}
block_pool_destroy :: proc(p:^Block_Pool) {
    block_release(p.memory,p.owner)
    p^={}
}
// Releases every block at once.
block_pool_reset :: proc(p:^Block_Pool) {
    p.fresh=0;p.free_head=0;p.in_use=0
}
// The block is not zeroed unless asked. ok is false when every block is in use.
block_pool_alloc :: proc(p:^Block_Pool,zero:=false) -> (block:[]byte,ok:bool) {
    index:int
    if p.free_head!=0 {
        index=int(p.free_head)-1;p.free_head=p.next[index]
    } else if p.fresh<p.capacity {
        index=p.fresh;p.fresh+=1
    } else {
        p.failed+=1
        return nil,false
    }
    p.next[index]=BLOCK_USED
    p.in_use+=1;p.peak=max(p.peak,p.in_use);p.requests+=1
    block=p.blocks[index*p.stride:][:p.block_size]
    if zero {mem.zero_slice(block)}
    return block,true
}
// False when the address is not the start of a block of this pool in use.
block_pool_free :: proc(p:^Block_Pool,block:rawptr) -> bool {
    index:=block_pool_in_use(p,block)
    if index<0 {return false}
    p.next[index]=p.free_head;p.free_head=u32(index)+1
    p.in_use-=1
    return true
}
// Index of the block that starts at the address, or -1.
block_pool_index :: proc(p:^Block_Pool,block:rawptr) -> int {
    start:=uintptr(raw_data(p.blocks))
    if p.stride==0 || uintptr(block)<start || uintptr(block)>=start+uintptr(len(p.blocks)) {return -1}
    offset:=int(uintptr(block)-start)
    if offset%p.stride!=0 {return -1}
    return offset/p.stride
}
@(private)
block_pool_in_use :: proc(p:^Block_Pool,block:rawptr) -> int {
    index:=block_pool_index(p,block)
    return index if index>=0 && index<p.fresh && p.next[index]==BLOCK_USED else -1
}
// nil when the index is not below the capacity.
block_pool_block :: proc(p:^Block_Pool,index:int) -> []byte {
    if index<0 || index>=p.capacity {return nil}
    return p.blocks[index*p.stride:][:p.block_size]
}
block_pool_stats :: proc(p:^Block_Pool) -> Alloc_Stats {
    return {p.capacity*p.block_size,p.in_use*p.block_size,p.peak*p.block_size,p.requests,p.failed}
}
// Serves any request that fits in one block.
block_pool_allocator :: proc(p:^Block_Pool) -> runtime.Allocator {return {block_pool_allocator_proc,p}}

block_pool_allocator_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    p:=(^Block_Pool)(data)
    switch mode {
    case .Alloc,.Alloc_Non_Zeroed:
        if size>p.block_size || !alignment_valid(alignment) || (p.blocks!=nil && !mem.is_aligned(raw_data(p.blocks),alignment)) || p.stride&(alignment-1)!=0 {
            p.failed+=1
            return nil,.Out_Of_Memory
        }
        block,ok:=block_pool_alloc(p,mode==.Alloc)
        if !ok {return nil,.Out_Of_Memory}
        return block[:max(size,0)],nil
    case .Free:
        if old_memory==nil {return nil,nil}
        return nil,.None if block_pool_free(p,old_memory) else .Invalid_Pointer
    case .Free_All:
        block_pool_reset(p)
    case .Resize,.Resize_Non_Zeroed:
        if old_memory==nil {return block_pool_allocator_proc(data,.Alloc if mode==.Resize else .Alloc_Non_Zeroed,size,alignment,nil,0,loc)}
        if size<=0 {return block_pool_allocator_proc(data,.Free,0,0,old_memory,old_size,loc)}
        if block_pool_in_use(p,old_memory)<0 {return nil,.Invalid_Pointer}
        if size>p.block_size || !alignment_valid(alignment) || !mem.is_aligned(old_memory,alignment) {p.failed+=1;return nil,.Out_Of_Memory}
        bytes:=([^]byte)(old_memory)[:size]
        if mode==.Resize && size>old_size {mem.zero_slice(bytes[max(old_size,0):])}
        return bytes,nil
    case .Query_Features:
        if set:=(^runtime.Allocator_Mode_Set)(old_memory);set!=nil {
            set^={.Alloc,.Alloc_Non_Zeroed,.Free,.Free_All,.Resize,.Resize_Non_Zeroed,.Query_Features}
        }
    case .Query_Info:
        return nil,.Mode_Not_Implemented
    }
    return nil,nil
}

// ---------------------------------------------------------------- dynamic arena

// mem.dynamic_arena_allocator, without the defect of Odin that
// after a block it could not get hands out address 0 as memory: the arena
// keeps the room of the block it has not (odin-lang/Odin#8103; docs/ODIN_WORKAROUNDS.md).
dynamic_arena_allocator :: proc(a:^mem.Dynamic_Arena) -> mem.Allocator {
    return {dynamic_arena_allocator_proc,a}
}

@(private="file")
dynamic_arena_allocator_proc :: proc(data:rawptr,mode:mem.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,mem.Allocator_Error) {
    memory,error:=mem.dynamic_arena_allocator_proc(data,mode,size,alignment,old_memory,old_size,loc)
    a:=(^mem.Dynamic_Arena)(data)
    if a.current_block==nil {a.bytes_left=0}
    return memory,error
}
