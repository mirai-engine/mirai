package base

import "base:runtime"

// Index of a string in an Interner, in order of arrival. 0 is the empty string.
Symbol :: distinct u32

// Table of distinct strings: equal strings get the same Symbol, so names are
// stored and compared as one integer. Strings are never removed; the ones
// returned point into the table and live as long as it does.
Interner :: struct {
    bytes:[]u8,     // every string, back to back
    used:int,
    offsets:[]u32,  // string s is bytes[offsets[s]:offsets[s+1]]
    hashes:[]u64,   // name_hash of every string
    table:[]u32,    // open addressing by name_hash: a Symbol, or 0 for an empty slot
    using usage:Usage,
    owner:runtime.Allocator,
}

// Room for max_strings distinct non-empty strings that add up to max_bytes.
intern_init :: proc(t:^Interner,max_strings,max_bytes:int,allocator:=context.allocator) -> bool {
    t^={}
    if max_strings<=0 || max_bytes<=0 || max_strings>=int(SLOT_NONE) || max_bytes>=int(SLOT_NONE) {return false}
    slots:=hash_map_slots(max_strings)
    bytes,first:=slice_make([]u8,max_bytes,allocator)
    offsets,second:=slice_make([]u32,max_strings+2,allocator)
    hashes,third:=slice_make([]u64,max_strings+1,allocator)
    table,fourth:=slice_make([]u32,slots,allocator)
    t.bytes=bytes;t.offsets=offsets;t.hashes=hashes;t.table=table;t.owner=allocator
    if !first || !second || !third || !fourth {intern_destroy(t);return false}
    t.capacity=max_strings
    t.hashes[0]=name_hash("")
    return true
}
intern_destroy :: proc(t:^Interner) {
    if t.owner.procedure!=nil {delete(t.bytes,t.owner);delete(t.offsets,t.owner);delete(t.hashes,t.owner);delete(t.table,t.owner)}
    t^={}
}
intern_string :: proc "contextless" (t:^Interner,symbol:Symbol) -> string {
    if symbol==0 || int(symbol)>t.count {return ""}
    return string(t.bytes[t.offsets[symbol]:t.offsets[symbol+1]])
}
// name_hash of the string of a symbol, without reading the string.
intern_hash :: proc "contextless" (t:^Interner,symbol:Symbol) -> u64 {
    if int(symbol)>t.count || len(t.hashes)==0 {return name_hash("")}
    return t.hashes[symbol]
}
@(private)
intern_probe :: proc "contextless" (t:^Interner,text:string,hash:u64) -> (slot:int,symbol:Symbol) {
    mask:=len(t.table)-1
    for slot=int(hash*0x9e3779b97f4a7c15>>32)&mask;;slot=(slot+1)&mask {
        symbol=Symbol(t.table[slot])
        if symbol==0 {return}
        if t.hashes[symbol]==hash && intern_string(t,symbol)==text {return}
    }
}
// The symbol of a string that is already in the table.
intern_find :: proc "contextless" (t:^Interner,text:string) -> (symbol:Symbol,found:bool) {
    if len(text)==0 {return 0,true}
    if len(t.table)==0 {return 0,false}
    _,symbol=intern_probe(t,text,name_hash(text))
    return symbol,symbol!=0
}
// The symbol of the string, adding it when it is new. ok is false when it is
// new and the table has no room for it.
intern_add :: proc(t:^Interner,text:string) -> (symbol:Symbol,ok:bool) {
    if len(text)==0 {return 0,true}
    if len(t.table)==0 {t.failed+=1;return 0,false}
    hash:=name_hash(text)
    slot:int
    slot,symbol=intern_probe(t,text,hash)
    if symbol!=0 {return symbol,true}
    if t.count>=t.capacity || t.used+len(text)>len(t.bytes) {t.failed+=1;return 0,false}
    usage_add(&t.usage)
    symbol=Symbol(t.count)
    t.offsets[symbol]=u32(t.used)
    copy(t.bytes[t.used:],text)
    t.used+=len(text)
    t.offsets[symbol+1]=u32(t.used)
    t.hashes[symbol]=hash
    t.table[slot]=u32(symbol)
    return symbol,true
}
// Forgets every string. Symbols handed out before are not valid any more.
intern_clear :: proc(t:^Interner) {
    for &slot in t.table {slot=0}
    t.count=0;t.used=0
}
