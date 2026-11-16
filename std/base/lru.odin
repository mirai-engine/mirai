package base

import "base:runtime"

// Cache of a fixed number of entries by u64 key. Putting a new key into a full
// cache evicts the entry used least recently and returns it, so the caller
// can release what it stood for.
Lru :: struct($V:typeid) {
    index:Hash_Map(u32), // key -> entry
    keys:[]u64,
    values:[]V,
    newer,older:[]u32,   // links of the use order; newer also chains the free entries
    newest,oldest:u32,
    free_head:u32,
    hits,misses,evictions:u64,
    owner:runtime.Allocator,
}

lru_init :: proc(c:^$C/Lru($V),capacity:int,allocator:=context.allocator) -> bool {
    c^={}
    if capacity<=0 || capacity>=int(SLOT_NONE) {return false}
    if !hash_map_init(&c.index,capacity,allocator) {return false}
    keys,first:=slice_make([]u64,capacity,allocator)
    values,second:=slice_make([]V,capacity,allocator)
    newer,third:=slice_make([]u32,capacity,allocator)
    older,fourth:=slice_make([]u32,capacity,allocator)
    c.keys=keys;c.values=values;c.newer=newer;c.older=older;c.owner=allocator
    if !first || !second || !third || !fourth {lru_destroy(c);return false}
    lru_clear(c)
    return true
}
lru_destroy :: proc(c:^$C/Lru($V)) {
    hash_map_destroy(&c.index)
    if c.owner.procedure!=nil {delete(c.keys,c.owner);delete(c.values,c.owner);delete(c.newer,c.owner);delete(c.older,c.owner)}
    c^={}
}
lru_clear :: proc(c:^$C/Lru($V)) {
    hash_map_clear(&c.index)
    for &link,i in c.newer {link=u32(i+1)}
    if len(c.newer)>0 {c.newer[len(c.newer)-1]=SLOT_NONE}
    c.free_head=0 if len(c.newer)>0 else SLOT_NONE
    c.newest=SLOT_NONE;c.oldest=SLOT_NONE
}
lru_len :: #force_inline proc "contextless" (c:^$C/Lru($V)) -> int {return c.index.count}

@(private)
lru_unlink :: proc "contextless" (c:^$C/Lru($V),entry:u32) {
    newer,older:=c.newer[entry],c.older[entry]
    if newer!=SLOT_NONE {c.older[newer]=older} else {c.newest=older}
    if older!=SLOT_NONE {c.newer[older]=newer} else {c.oldest=newer}
}
@(private)
lru_link_newest :: proc "contextless" (c:^$C/Lru($V),entry:u32) {
    c.newer[entry]=SLOT_NONE;c.older[entry]=c.newest
    if c.newest!=SLOT_NONE {c.newer[c.newest]=entry} else {c.oldest=entry}
    c.newest=entry
}
// The value of the key, which becomes the most recently used. nil on a miss.
lru_get :: proc "contextless" (c:^$C/Lru($V),key:u64) -> ^V {
    entry,found:=hash_map_get(&c.index,key)
    if !found {c.misses+=1;return nil}
    c.hits+=1
    if entry!=c.newest {lru_unlink(c,entry);lru_link_newest(c,entry)}
    return &c.values[entry]
}
// Like lru_get without touching the use order or the counters.
lru_peek :: proc "contextless" (c:^$C/Lru($V),key:u64) -> ^V {
    entry,found:=hash_map_get(&c.index,key)
    return &c.values[entry] if found else nil
}
// Stores the value as the most recently used. When the key is new and the
// cache is full, the entry it replaces comes back with evicted set.
lru_put :: proc(c:^$C/Lru($V),key:u64,value:V) -> (evicted_key:u64,evicted_value:V,evicted:bool) {
    if entry,found:=hash_map_get(&c.index,key);found {
        c.values[entry]=value
        if entry!=c.newest {lru_unlink(c,entry);lru_link_newest(c,entry)}
        return
    }
    if len(c.keys)==0 {c.index.failed+=1;return}
    entry:=c.free_head
    if entry!=SLOT_NONE {
        c.free_head=c.newer[entry]
    } else {
        entry=c.oldest
        if entry==SLOT_NONE {c.index.failed+=1;return}
        evicted_key,evicted_value,evicted=c.keys[entry],c.values[entry],true
        lru_unlink(c,entry)
        hash_map_remove(&c.index,evicted_key)
        c.evictions+=1
    }
    c.keys[entry]=key;c.values[entry]=value
    hash_map_set(&c.index,key,entry)
    lru_link_newest(c,entry)
    return
}
lru_remove :: proc(c:^$C/Lru($V),key:u64) -> (value:V,found:bool) {
    entry:u32
    entry,found=hash_map_remove(&c.index,key)
    if !found {return}
    lru_unlink(c,entry)
    c.newer[entry]=c.free_head;c.free_head=entry
    return c.values[entry],true
}
// Key and value of the entry that the next eviction would take.
lru_oldest :: proc "contextless" (c:^$C/Lru($V)) -> (key:u64,value:^V,ok:bool) {
    if c.oldest==SLOT_NONE || len(c.keys)==0 {return}
    return c.keys[c.oldest],&c.values[c.oldest],true
}
