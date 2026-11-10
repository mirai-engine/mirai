package lz_optimal

import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor/lz/match"

// A find-all finder over buf[0:size): positions before start_recording_pos are only indexed (the
// dictionary backup); each process_chunk call then fills the pairs of the next chunk_size
// positions, max_pairs per position, longest first, ended by a zero length when fewer.
Incremental_Finder :: union {^Cache_Table_Finder, ^Suffix_Trie_Finder}

// nil on invalid parameters or out of memory. lrm_set may be nil; it must outlive the finder.
incremental_create :: proc(kind:Finder_Kind,buf:[^]u8,size,start_recording_pos:int,lrm_set:^Lrm_Set,
    arena:^entropy.Arena) -> Incremental_Finder {
    if buf==nil || size<=0 || size>=int(max(i32)) || start_recording_pos<0 ||
        start_recording_pos>=size {return nil}
    switch kind {
    case .Ctmf_Find_All:
        s:=entropy.arena_alloc_zeroed(arena,Cache_Table_Finder,1)
        if s==nil {return nil}
        f:=&s[0]
        if !cache_table_init(f,buf,size,start_recording_pos,lrm_set,arena) {
            cache_table_release(f,arena)
            entropy.arena_free(arena,s)
            return nil
        }
        return f
    case .Suffix_Trie:
        s:=entropy.arena_alloc_zeroed(arena,Suffix_Trie_Finder,1)
        if s==nil {return nil}
        f:=&s[0]
        if !suffix_trie_init(f,buf,size,start_recording_pos,lrm_set,arena) {
            suffix_trie_release(f,arena)
            entropy.arena_free(arena,s)
            return nil
        }
        return f
    case .None:
    }
    return nil
}

// Returns the number of positions filled (0 at the end); matches needs that many * max_pairs
// entries. Returns -1 when max_pairs < 2, chunk_size < 0 or matches is too short.
incremental_process_chunk :: proc(f:Incremental_Finder,chunk_size:int,
    matches:[]match.Unpacked_Match_Pair,max_pairs:int) -> int {
    if max_pairs<2 || chunk_size<0 {return -1}
    switch v in f {
    case ^Cache_Table_Finder:
        n:=clamp(v.size-v.pos,0,chunk_size)
        if len(matches)<n*max_pairs {return -1}
        return cache_table_process_chunk(v,n,raw_data(matches),max_pairs)
    case ^Suffix_Trie_Finder:
        n:=clamp(v.size-v.pos,0,chunk_size)
        if len(matches)<n*max_pairs {return -1}
        return suffix_trie_chunk(v,n,raw_data(matches),max_pairs)
    }
    return -1
}

incremental_release :: proc(f:^Incremental_Finder,arena:^entropy.Arena) {
    switch v in f^ {
    case ^Cache_Table_Finder:
        cache_table_release(v,arena)
        entropy.arena_free(arena,([^]Cache_Table_Finder)(v)[:1])
    case ^Suffix_Trie_Finder:
        suffix_trie_release(v,arena)
        entropy.arena_free(arena,([^]Suffix_Trie_Finder)(v)[:1])
    }
    f^=nil
}

// Longest first, then lowest offset.
@(private)
match_pair_less :: #force_inline proc "contextless" (a,b:match.Unpacked_Match_Pair) -> bool {
    if a.length!=b.length {return a.length>b.length}
    return a.offset<b.offset
}
@(private)
match_pair_equal_length :: #force_inline proc "contextless" (a,b:match.Unpacked_Match_Pair) -> bool {
    return a.length==b.length
}

// Smallest multiple of an offset below MIN_OFFSET that is at least MIN_OFFSET.
@(private)
round_up_small_offset :: #force_inline proc "contextless" (offset:u32) -> u32 {
    @(static,rodata) rounded_up:=[8]u32{0,8,8,9,8,10,12,14}
    return rounded_up[offset&7]
}

// Keeps the first of each run of pairs that `equal` says are the same; returns the new count.
@(private)
match_pairs_unique :: proc "contextless" (pairs:[]match.Unpacked_Match_Pair,
    equal:proc "contextless" (a,b:match.Unpacked_Match_Pair) -> bool) -> int {
    n:=len(pairs)
    it:=0
    for it<n-1 && !equal(pairs[it],pairs[it+1]) {it+=1}
    if it>=n-1 {return n}
    out:=it
    it+=2
    for ;it<n;it+=1 {
        if !equal(pairs[out],pairs[it]) {out+=1;pairs[out]=pairs[it]}
    }
    return out+1
}
