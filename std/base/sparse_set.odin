package base

import "base:runtime"

// Set of integers below a fixed bound with constant-time insert, remove, test
// and clear, and its members packed in dense[:count]. Callers keep their data
// in columns parallel to dense: an insert appends a row, a remove moves the
// last row into the hole it reports.
Sparse_Set :: struct {
    sparse:[]u32, // key -> index in dense; only meaningful when dense[index] is the key
    dense:[]u32,
    using usage:Usage,
    owner:runtime.Allocator,
}

// Keys go from 0 to key_bound-1; at most capacity of them are members at once.
sparse_set_init :: proc(s:^Sparse_Set,key_bound,capacity:int,allocator:=context.allocator) -> bool {
    s^={}
    if key_bound<=0 || capacity<=0 {return false}
    sparse,first:=slice_make([]u32,key_bound,allocator)
    dense,second:=slice_make([]u32,min(capacity,key_bound),allocator)
    if !first || !second {delete(sparse,allocator);delete(dense,allocator);return false}
    sparse_set_init_buffer(s,sparse,dense)
    s.owner=allocator
    return true
}
// len(sparse) is the bound of the keys and len(dense) the capacity.
sparse_set_init_buffer :: proc(s:^Sparse_Set,sparse,dense:[]u32) {
    s^={sparse=sparse,dense=dense}
    s.capacity=len(dense)
    for &entry in sparse {entry=0}
}
sparse_set_destroy :: proc(s:^Sparse_Set) {
    if s.owner.procedure!=nil {delete(s.sparse,s.owner);delete(s.dense,s.owner)}
    s^={}
}
sparse_set_contains :: #force_inline proc "contextless" (s:^Sparse_Set,key:u32) -> bool {
    if int(key)>=len(s.sparse) {return false}
    index:=s.sparse[key]
    return int(index)<s.count && s.dense[index]==key
}
// Row of a member.
sparse_set_index :: #force_inline proc "contextless" (s:^Sparse_Set,key:u32) -> (index:int,ok:bool) {
    if !sparse_set_contains(s,key) {return -1,false}
    return int(s.sparse[key]),true
}
// Row of the key, which is new when inserted is true. The row is -1 when the
// key is out of bounds or the set is full.
sparse_set_insert :: proc(s:^Sparse_Set,key:u32) -> (index:int,inserted:bool) {
    if int(key)>=len(s.sparse) {return -1,false}
    if existing:=s.sparse[key];int(existing)<s.count && s.dense[existing]==key {return int(existing),false}
    if s.count>=len(s.dense) {s.failed+=1;return -1,false}
    index=s.count
    s.dense[index]=key;s.sparse[key]=u32(index)
    usage_add(&s.usage)
    return index,true
}
// The caller must move row `last` into row `index` when they differ.
sparse_set_remove :: proc(s:^Sparse_Set,key:u32) -> (index,last:int,ok:bool) {
    if !sparse_set_contains(s,key) {return -1,-1,false}
    index=int(s.sparse[key]);last=s.count-1
    moved:=s.dense[last]
    s.dense[index]=moved;s.sparse[moved]=u32(index)
    s.count=last
    return index,last,true
}
sparse_set_clear :: proc "contextless" (s:^Sparse_Set) {s.count=0}
sparse_set_members :: #force_inline proc "contextless" (s:^Sparse_Set) -> []u32 {return s.dense[:s.count]}
