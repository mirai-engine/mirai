package base

import "base:intrinsics"
import "base:runtime"

// Hands out slots with generations. What a slot holds lives in the caller's
// arrays, indexed by handle_index. A freed slot is reused with a newer
// generation, so handles to its previous occupant stop being valid.
//
// A generation is odd while its slot is in use and even while it is free:
// comparing it with the one in the handle is the whole validity test. A slot
// that used up its generations is retired instead of handing out a repeated handle.
Handle_Pool :: struct {
    generations:[]u32,
    next:[]u32,  // free list: the slot to reuse after this one, plus 1
    extent:int,  // slots below this were handed out at least once
    free_head:u32, // first slot of the free list, plus 1; 0 when it is empty
    retired:int,
    using usage:Usage,
    owner:runtime.Allocator,
}

@(private) SLOT_NONE :: u32(0xffffffff)
@(private) GENERATION_LAST :: u32(0xfffffffd)

handle_pool_init :: proc(p:^Handle_Pool,capacity:int,allocator:=context.allocator) -> bool {
    p^={}
    if capacity<=0 || capacity>=int(SLOT_NONE) {return false}
    generations,first:=slice_make([]u32,capacity,allocator)
    next,second:=slice_make([]u32,capacity,allocator)
    if !first || !second {delete(generations,allocator);delete(next,allocator);return false}
    handle_pool_init_buffer(p,generations,next)
    p.owner=allocator
    return true
}
// The capacity is the length of the shorter slice.
handle_pool_init_buffer :: proc(p:^Handle_Pool,generations,next:[]u32) {
    capacity:=min(len(generations),len(next),int(SLOT_NONE)-1)
    p^={generations=generations[:capacity],next=next[:capacity]}
    p.capacity=capacity
    for &generation in p.generations {generation=0}
}
handle_pool_destroy :: proc(p:^Handle_Pool) {
    if p.owner.procedure!=nil {delete(p.generations,p.owner);delete(p.next,p.owner)}
    p^={}
}
// Handle(0) when every slot is in use.
handle_pool_alloc :: proc(p:^Handle_Pool) -> Handle {
    index:u32
    if p.free_head!=0 {
        index=p.free_head-1;p.free_head=p.next[index]
    } else {
        for p.extent<len(p.generations) && p.generations[p.extent]>GENERATION_LAST {p.extent+=1}
        if p.extent>=len(p.generations) {p.failed+=1;return 0}
        index=u32(p.extent);p.extent+=1
    }
    p.generations[index]+=1
    usage_add(&p.usage)
    return handle_make(index,p.generations[index])
}
// False when the handle is not valid any more.
handle_pool_free :: proc(p:^Handle_Pool,h:Handle) -> bool {
    index:=handle_index(h)
    if !handle_pool_valid(p,h) {return false}
    p.generations[index]+=1
    p.count-=1
    if p.generations[index]>GENERATION_LAST {p.retired+=1;return true}
    p.next[index]=p.free_head;p.free_head=index+1
    return true
}
handle_pool_valid :: #force_inline proc "contextless" (p:^Handle_Pool,h:Handle) -> bool {
    index,generation:=handle_index(h),handle_generation(h)
    return int(index)<p.extent && generation&1==1 && p.generations[index]==generation
}
// The slot of a valid handle.
handle_pool_slot :: #force_inline proc "contextless" (p:^Handle_Pool,h:Handle) -> (slot:int,ok:bool) {
    if !handle_pool_valid(p,h) {return -1,false}
    return int(handle_index(h)),true
}
handle_pool_alive :: #force_inline proc "contextless" (p:^Handle_Pool,slot:int) -> bool {
    return slot>=0 && slot<p.extent && p.generations[slot]&1==1
}
// Handle of the occupant of a slot, or Handle(0) when it is free.
handle_pool_handle :: proc "contextless" (p:^Handle_Pool,slot:int) -> Handle {
    if !handle_pool_alive(p,slot) {return 0}
    return handle_make(u32(slot),p.generations[slot])
}
// Frees every slot. Handles created before the call never become valid again.
handle_pool_clear :: proc(p:^Handle_Pool) {
    for &generation in p.generations[:p.extent] {
        if generation&1==1 {generation+=1}
    }
    p.extent=0;p.free_head=0;p.count=0
    p.retired=0
    for generation in p.generations {
        if generation>GENERATION_LAST {p.retired+=1}
    }
}

// Values packed in a dense array and reached through generational handles of
// type H. Removing moves the last value into the hole: values[:count] has no
// gaps, pointers into it are only good until the next removal, and the order
// of iteration changes.
Slot_Map :: struct($T:typeid,$H:typeid) where intrinsics.type_is_integer(H),size_of(H)==size_of(Handle) {
    handles:Handle_Pool,
    dense:[]u32, // slot -> index in values
    slots:[]u32, // index in values -> slot
    values:[]T,
    owner:runtime.Allocator,
}

slot_map_init :: proc(m:^$M/Slot_Map($T,$H),capacity:int,allocator:=context.allocator) -> bool {
    m^={}
    if !handle_pool_init(&m.handles,capacity,allocator) {return false}
    dense,first:=slice_make([]u32,capacity,allocator)
    slots,second:=slice_make([]u32,capacity,allocator)
    values,third:=slice_make([]T,capacity,allocator)
    m.dense=dense;m.slots=slots;m.values=values;m.owner=allocator
    if !first || !second || !third {slot_map_destroy(m);return false}
    return true
}
slot_map_destroy :: proc(m:^$M/Slot_Map($T,$H)) {
    handle_pool_destroy(&m.handles)
    if m.owner.procedure!=nil {delete(m.dense,m.owner);delete(m.slots,m.owner);delete(m.values,m.owner)}
    m^={}
}
// H(0) when the map is full.
slot_map_insert :: proc(m:^$M/Slot_Map($T,$H),value:T) -> H {
    h:=handle_pool_alloc(&m.handles)
    if h==0 {return H(0)}
    index:=u32(m.handles.count-1)
    m.dense[handle_index(h)]=index;m.slots[index]=handle_index(h)
    m.values[index]=value
    return H(h)
}
slot_map_remove :: proc(m:^$M/Slot_Map($T,$H),h:H) -> bool {
    slot:=handle_index(Handle(h))
    if !handle_pool_free(&m.handles,Handle(h)) {return false}
    index,last:=m.dense[slot],u32(m.handles.count)
    if index!=last {
        moved:=m.slots[last]
        m.values[index]=m.values[last]
        m.slots[index]=moved;m.dense[moved]=index
    }
    return true
}
// nil when the handle is not valid.
slot_map_get :: #force_inline proc "contextless" (m:^$M/Slot_Map($T,$H),h:H) -> ^T {
    if !handle_pool_valid(&m.handles,Handle(h)) {return nil}
    return &m.values[m.dense[handle_index(Handle(h))]]
}
slot_map_valid :: #force_inline proc "contextless" (m:^$M/Slot_Map($T,$H),h:H) -> bool {
    return handle_pool_valid(&m.handles,Handle(h))
}
slot_map_len :: #force_inline proc "contextless" (m:^$M/Slot_Map($T,$H)) -> int {return m.handles.count}
// The live values, packed.
slot_map_values :: #force_inline proc "contextless" (m:^$M/Slot_Map($T,$H)) -> []T {return m.values[:m.handles.count]}
// Handle of the value at an index of slot_map_values.
slot_map_handle :: proc "contextless" (m:^$M/Slot_Map($T,$H),index:int) -> H {
    if index<0 || index>=m.handles.count {return H(0)}
    slot:=m.slots[index]
    return H(handle_make(slot,m.handles.generations[slot]))
}
slot_map_clear :: proc(m:^$M/Slot_Map($T,$H)) {handle_pool_clear(&m.handles)}
