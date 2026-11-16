package base

import "base:runtime"

// Map from u64 keys to values with a fixed number of entries: open addressing
// with linear probing, at most two thirds full, no tombstones. Every key is
// allowed. Pointers to values are good until the next removal.
Hash_Map :: struct($V:typeid) {
    keys:[]u64,  // 0 marks an empty slot; the entry of key 0 has the extra last slot
    values:[]V,
    shift:u32,   // 64 - log2 of the slot count
    has_zero:bool,
    using usage:Usage,
    owner:runtime.Allocator,
}

@(private)
hash_map_slots :: proc "contextless" (capacity:int) -> int {
    slots:=4
    for slots*2<capacity*3 {slots<<=1}
    return slots
}
@(private)
hash_map_home :: #force_inline proc "contextless" (key:u64,shift:u32) -> int {
    return int((key*0x9e3779b97f4a7c15)>>shift)
}

hash_map_init :: proc(m:^$M/Hash_Map($V),capacity:int,allocator:=context.allocator,loc:=#caller_location) -> bool {
    m^={}
    // Beyond max(int)/32 entries the slot count or the bytes of the keys overflow an int.
    if capacity<=0 || capacity>max(int)/32 {return false}
    slots:=hash_map_slots(capacity)
    keys,first:=slice_make([]u64,slots+1,allocator,loc)
    values,second:=slice_make([]V,slots+1,allocator,loc)
    if !first || !second {delete(keys,allocator);delete(values,allocator);return false}
    m.keys=keys;m.values=values;m.owner=allocator
    m.capacity=capacity
    m.shift=64
    for size:=slots;size>1;size>>=1 {m.shift-=1}
    return true
}
// Makes room for capacity entries, keeping every entry: an operation of a
// transaction, which moves the values. False, changing nothing, without memory
// or on a map that was never initialized.
hash_map_grow :: proc(m:^$M/Hash_Map($V),capacity:int,loc:=#caller_location) -> bool {
    if capacity<=m.capacity {return true}
    grown:M
    if !hash_map_init(&grown,capacity,m.owner,loc) {return false}
    if m.has_zero {hash_map_set(&grown,0,m.values[len(m.keys)-1])}
    for key,i in m.keys[:len(m.keys)-1] {
        if key!=0 {hash_map_set(&grown,key,m.values[i])}
    }
    grown.usage.failed,grown.usage.peak=m.usage.failed,max(m.usage.peak,grown.usage.peak)
    hash_map_destroy(m)
    m^=grown
    return true
}

hash_map_destroy :: proc(m:^$M/Hash_Map($V)) {
    if m.owner.procedure!=nil {delete(m.keys,m.owner);delete(m.values,m.owner)}
    m^={}
}
// Slot of a key, or -1.
@(private)
hash_map_find :: #force_inline proc "contextless" (m:^$M/Hash_Map($V),key:u64) -> int {
    slots:=len(m.keys)-1
    if key==0 {return slots if m.has_zero else -1}
    if slots<=0 {return -1}
    mask:=slots-1
    #no_bounds_check for index:=hash_map_home(key,m.shift);;index=(index+1)&mask {
        found:=m.keys[index]
        if found==key {return index}
        if found==0 {return -1}
    }
}
// nil when the key is absent.
hash_map_ptr :: proc "contextless" (m:^$M/Hash_Map($V),key:u64) -> ^V {
    index:=hash_map_find(m,key)
    return &m.values[index] if index>=0 else nil
}
hash_map_get :: proc "contextless" (m:^$M/Hash_Map($V),key:u64) -> (value:V,found:bool) #optional_ok {
    index:=hash_map_find(m,key)
    if index<0 {return}
    return m.values[index],true
}
hash_map_contains :: proc "contextless" (m:^$M/Hash_Map($V),key:u64) -> bool {return hash_map_find(m,key)>=0}
// The value of the key, zeroed when the key is new. nil when the key is new
// and the map is full.
hash_map_insert :: proc(m:^$M/Hash_Map($V),key:u64) -> (value:^V,inserted:bool) {
    slots:=len(m.keys)-1
    if slots<=0 {m.failed+=1;return nil,false}
    index:=slots
    if key==0 {
        if m.has_zero {return &m.values[slots],false}
    } else {
        mask:=slots-1
        #no_bounds_check for index=hash_map_home(key,m.shift);;index=(index+1)&mask {
            found:=m.keys[index]
            if found==key {return &m.values[index],false}
            if found==0 {break}
        }
    }
    if m.count>=m.capacity {m.failed+=1;return nil,false}
    if key==0 {m.has_zero=true} else {m.keys[index]=key}
    m.values[index]={}
    usage_add(&m.usage)
    return &m.values[index],true
}
// False when the key is new and the map is full.
hash_map_set :: proc(m:^$M/Hash_Map($V),key:u64,value:V) -> bool {
    slot,_:=hash_map_insert(m,key)
    if slot==nil {return false}
    slot^=value
    return true
}
hash_map_remove :: proc(m:^$M/Hash_Map($V),key:u64) -> (value:V,found:bool) {
    index:=hash_map_find(m,key)
    if index<0 {return}
    value=m.values[index]
    m.count-=1
    if key==0 {m.has_zero=false;return value,true}
    // Entries that probed past the hole move back, so no lookup stops short of them.
    mask:=len(m.keys)-2
    #no_bounds_check for next:=(index+1)&mask;;next=(next+1)&mask {
        moved:=m.keys[next]
        if moved==0 {break}
        home:=hash_map_home(moved,m.shift)
        if (next-home)&mask>=(next-index)&mask {
            m.keys[index]=moved;m.values[index]=m.values[next]
            index=next
        }
    }
    m.keys[index]=0
    return value,true
}
hash_map_clear :: proc(m:^$M/Hash_Map($V)) {
    for &key in m.keys {key=0}
    m.has_zero=false;m.count=0
}

// Visits every entry in no particular order; nothing may be inserted or removed meanwhile:
//     it:=hash_map_iterator(&m)
//     for key,value in hash_map_iterate(&it) {...}
Hash_Map_Iterator :: struct($V:typeid) {
    keys:[]u64,
    values:[]V,
    index:int,
    has_zero:bool,
}
hash_map_iterator :: proc "contextless" (m:^$M/Hash_Map($V)) -> Hash_Map_Iterator(V) {
    return {m.keys,m.values,0,m.has_zero}
}
hash_map_iterate :: proc "contextless" (it:^$I/Hash_Map_Iterator($V)) -> (key:u64,value:^V,ok:bool) {
    slots:=len(it.keys)-1
    #no_bounds_check for it.index<slots {
        index:=it.index
        it.index+=1
        if it.keys[index]!=0 {return it.keys[index],&it.values[index],true}
    }
    if it.index==slots && it.has_zero {
        it.index+=1
        return 0,&it.values[slots],true
    }
    return 0,nil,false
}
