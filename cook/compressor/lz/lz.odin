package lz_optimal

import "base:intrinsics"
import "mirai:std/compressor"
import "mirai:std/compressor/lz"
import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor/lz/match"
import "mirai:std/compressor/lz/parse"

// The optimal levels of the LZ encoder: their parser, their find-all match finders and the long
// range matcher. The streams are those of std/compressor/lz, which frames them and which every
// program has; only what cooks imports this package.

Level :: enum i8 {Optimal1=compressor.LEVEL_OPTIMAL1, Optimal2, Optimal3, Optimal4, Optimal5}

mode :: proc "contextless" (level:Level) -> lz.Mode {
    return {level=i32(level),parser={setup=setup,encode_chunk=encode_chunk},whole=compress_whole}
}

// What a cook writes with: SHIP to the smallest stream at a decode the loader sustains (the
// cooking of a shipped game), QUICK for a cook that checks a change (a --dev game): a few times
// faster to write and a little larger.
SHIP :: lz.Mode{level=compressor.LEVEL_OPTIMAL5,parser={setup=setup,encode_chunk=encode_chunk},
    whole=compress_whole}
QUICK :: lz.Mode{level=compressor.LEVEL_OPTIMAL1,parser={setup=setup,encode_chunk=encode_chunk},
    whole=compress_whole}

@(private) padd :: #force_inline proc "contextless" (p:[^]u8,
    n:int) -> [^]u8 {return ([^]u8)(uintptr(p)+uintptr(n))}
@(private) pdiff :: #force_inline proc "contextless" (a,
    b:[^]u8) -> int {return int(uintptr(a))-int(uintptr(b))}
@(private) load16 :: #force_inline proc "contextless" (p:[^]u8) -> u16 {
    return intrinsics.unaligned_load((^u16)(p))
}
@(private) load32 :: #force_inline proc "contextless" (p:[^]u8) -> u32 {
    return intrinsics.unaligned_load((^u32)(p))
}
@(private) load64 :: #force_inline proc "contextless" (p:[^]u8) -> u64 {
    return intrinsics.unaligned_load((^u64)(p))
}

// Which finder fills the match pairs of a level.
Finder_Kind :: enum u8 {None, Ctmf_Find_All, Suffix_Trie}

@(private) PARSE_CHUNK_LEN_MAX :: 4096
@(private) MAX_LOCAL_DICTIONARY :: 16<<20

@(private)
finder_kind :: proc "contextless" (level:i32) -> Finder_Kind {
    if level>=compressor.LEVEL_OPTIMAL2 {return .Suffix_Trie}
    if level==compressor.LEVEL_OPTIMAL1 {return .Ctmf_Find_All}
    return .None
}

// The rows of the level table above Normal and the scratch of their parse.
@(private)
setup :: proc(e:^parse.Encoder, arena:^entropy.Arena) -> bool {
    if e==nil || arena==nil || finder_kind(e.level)==.None {return false}
    level:=e.level
    if level>=compressor.LEVEL_OPTIMAL3 {e.entropy_flags|=entropy.ARRAY_FLAG_ALLOW_SPLIT_INDEXED}
    e.bitstream_flags|=parse.BITSTREAM_FLAG_ALT_OFFSETS
    num_tlls:=level>=compressor.LEVEL_OPTIMAL4 ? 2 : 1
    e.parse_space=entropy.arena_alloc(arena,parse.Parse,compressor.CHUNK_LEN/2+PARSE_CHUNK_LEN_MAX)
    e.arrivals_space=entropy.arena_alloc(arena,u8,arrivals_size(num_tlls*(compressor.CHUNK_LEN+1)))
    ok:=e.parse_space!=nil && e.arrivals_space!=nil
    if ok && num_tlls>1 {
        e.last_tll_len_space=entropy.arena_alloc(arena,i32,compressor.CHUNK_LEN+1)
        ok=e.last_tll_len_space!=nil
    }
    return ok
}

@(private)
encode_chunk :: proc(c:^parse.Chunk, pairs:[^]match.Unpacked_Match_Pair, chunk_type:^i32,
    J:^f32) -> int {
    return encode_chunk_optimal_tll(c,([^]Match_Parse_Record)(pairs),chunk_type,J)
}

@(private)
fill :: proc(finder:rawptr, block_len:int, matches:[]match.Unpacked_Match_Pair) -> int {
    return incremental_process_chunk((^Incremental_Finder)(finder)^,block_len,matches,
        match.NEWLZ_MATCH_NUM_PAIRS)
}

// newlz_compress_vtable for an input without dictionary. Above the local dictionary size the
// suffix trie is rebuilt over windows of half of it, with a long range matcher for what the
// window no longer sees. The parse still takes the whole input as its dictionary base, as the
// library does (its source passes the window start).
@(private)
compress_whole :: proc(f:^lz.Framing) -> int {
    if f==nil || f.arena==nil {return -1}
    kind:=finder_kind(f.level)
    base:=raw_data(f.parser.raw)
    n:=len(f.parser.raw)
    if kind==.None || n<=0 {return -1}
    if n<=compressor.BLOCK_LEN {
        finder:=incremental_create(kind,base,n,0,nil,f.arena)
        if finder==nil {return -1}
        defer incremental_release(&finder,f.arena)
        return lz.compress_sub(f,0,n,0,{fill,&finder})
    }
    max_local:=MAX_LOCAL_DICTIONARY
    if f.level<compressor.LEVEL_OPTIMAL2 {max_local=max(max_local,1<<26)}
    max_sub:=n
    cascade:^Lrm_Cascade
    if max_local<n {
        max_sub=max_local/2
        chunks:=(n+max_sub-1)/max_sub
        last_chunk_dic_start:=chunks*max_sub-max_local
        cascade=lrm_create_cascade_incremental(base,last_chunk_dic_start,LRM_STEP,
            LRM_JUMP_BITS,0,max_sub,LRM_HASH_LENGTH,f.arena)
        if cascade==nil {return -1}
    }
    defer lrm_destroy_cascade(cascade)
    total:=0
    for pos:=0;pos<n; {
        remaining:=n-pos
        cur:=min(remaining,max_sub)
        if pos==0 {cur=min(remaining,max_local)}
        if remaining<=(max_sub*5)/4 {cur=remaining}
        backup:=0
        if cur<max_local {backup=min(pos,max_sub,max_local-cur)}
        raw_ptr:=padd(base,pos)
        start:=padd(raw_ptr,-backup)
        set:Lrm_Set
        lrm_set:^Lrm_Set
        if cascade!=nil && backup<pos {
            if !lrm_cascade_get_set_align_update_incremental(cascade,&set,start,raw_ptr) {
                return -1
            }
            lrm_set=&set
        }
        finder:=incremental_create(kind,start,backup+cur,backup,lrm_set,f.arena)
        if finder==nil {return -1}
        k:=lz.compress_sub(f,pos,cur,total,{fill,&finder})
        incremental_release(&finder,f.arena)
        if k<0 {return -1}
        total+=k
        pos+=cur
    }
    return total
}
