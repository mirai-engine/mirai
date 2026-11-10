package parse

import "base:intrinsics"
import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor/lz/match"
import "mirai:std/compressor"

// LZ encoder: the fast and lazy chunk parsers and the packing of the literals, packets, offsets
// and excesses of a parse into the chunk format. The optimal parser of the levels above Normal is
// in cook/compressor/lz and comes in as an Optimal.

ESCAPE_OFFSET_MIN :: (1<<23)-256+compressor.MIN_OFFSET
MML_NORMAL :: 4
LRL_FOR_LONGER_MML :: 24+32
LOML_GOOD_ENOUGH :: 4
LAZYBETTER_LAZY2 :: 3
EXCESS_U32_COUNT_EXPGOLOMB_SHIFT :: 0

BITSTREAM_FLAG_SEND_EXCESS_SIZE :: u32(1<<0)
BITSTREAM_FLAG_ALT_OFFSETS :: u32(1<<2)

LAMBDA_LZ :: f32(0.01)
DEFAULT_SSTB :: 256

// The options the LZ encoder reads. Zero means default.
Options :: struct {
    min_match_len:i32,
    dictionary_size:i32,
    space_speed_tradeoff_bytes:i32,
    match_table_size_log2:i32,
    far_match_min_len:i32,
    far_match_offset_log2:i32,
    seek_chunk_reset:bool,
    seek_chunk_len:i32,
}

DEFAULT_OPTIONS :: Options{space_speed_tradeoff_bytes=DEFAULT_SSTB, seek_chunk_len=compressor.BLOCK_LEN}

Ctmf_Very_Fast :: match.Ctmf(u32,1,0,4)
Ctmf_Fast :: match.Ctmf(u32,3,0,4)
Ctmf_Normal :: match.Ctmf(u32,2,8,4)
Ctmf_Hyper32 :: match.Fast_Ctmf(u32)
Ctmf_Hyper16 :: match.Fast_Ctmf(u16)

Matcher :: union {Ctmf_Very_Fast, Ctmf_Fast, Ctmf_Normal, Ctmf_Hyper32, Ctmf_Hyper16}

// What the levels above Normal add to the encoder. A program that hands none compiles no
// optimal parser or find-all match finder, and those levels are invalid for it.
Optimal :: struct {
    // The rest of setup: the flags of the level and the scratch of its parse.
    setup:proc(e:^Encoder, arena:^entropy.Arena) -> bool,
    // The parse of one chunk over match.NEWLZ_MATCH_NUM_PAIRS found pairs per position.
    encode_chunk:proc(c:^Chunk, pairs:[^]match.Unpacked_Match_Pair, chunk_type:^i32, J:^f32) -> int,
}

Encoder :: struct {
    level:i32, lambda:f32, entropy_flags:u32, bitstream_flags:u32, chunk_len:int,
    try_huff_chunks:bool, decode_type:i32,
    optimal:Optimal,

    options:Options,
    raw:[]u8,
    matcher:Matcher,
    hash_len:int,
    arrays_space:[]u8,
    // scratch of the optimal parse, which its setup allocates
    parse_space:[]Parse,
    arrivals_space:[]u8,
    last_tll_len_space:[]i32,
    // optimal parse statistics carried from the previous chunk; chunktype -1 when there are none
    carried_passinfo:Passinfo,
    carried_chunktype:i32,
}

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

@(private)
sstb_for_lambda :: proc "contextless" (o:^Options) -> f32 {
    s:=o.space_speed_tradeoff_bytes
    if s==0 {return DEFAULT_SSTB}
    if s<0 {return 0}
    return f32(s)
}

@(private)
arrays_space_size :: proc "contextless" (chunk_len:int) -> int {
    return 2*(chunk_len+8)+(chunk_len/2+8)+chunk_len/3+(chunk_len/3)*4+chunk_len/5+
        (chunk_len/256)*4+256+8
}

// LZ_FillVTable and newlz_vtable_setup_ctmf for the whole input `raw`, with the dictionary
// base at raw start and no preload. Returns false on invalid level, on a level above Normal
// without its optimal, or out of memory.
setup :: proc(e:^Encoder, level:i32, raw:[]u8, arena:^entropy.Arena,
    options:=DEFAULT_OPTIONS, optimal:=Optimal{}) -> bool {
    e^={}
    e.carried_chunktype=-1
    if level<compressor.LEVEL_HYPER_FAST4 || level>compressor.LEVEL_OPTIMAL5 || level==compressor.LEVEL_NONE ||
        arena==nil {return false}
    if level>=compressor.LEVEL_OPTIMAL1 {
        if optimal.setup==nil || optimal.encode_chunk==nil {return false}
        e.optimal=optimal
    }
    e.options=options
    o:=&e.options
    if o.dictionary_size<0 {o.dictionary_size=0}
    raw_len:=len(raw)
    e.raw=raw
    e.level=level
    e.decode_type=compressor.DECODE_TYPE_LZ
    e.lambda=LAMBDA_LZ
    e.lambda*=sstb_for_lambda(o)*(1.0/DEFAULT_SSTB)
    e.chunk_len=compressor.CHUNK_LEN
    e.try_huff_chunks=level>=compressor.LEVEL_FAST
    e.entropy_flags=entropy.ARRAY_FLAG_ALLOW_HUFF6
    e.entropy_flags|=entropy.ARRAY_FLAG_ALLOW_TANS|entropy.ARRAY_FLAG_ALLOW_RLE|
        entropy.ARRAY_FLAG_ALLOW_RLEHUFF
    e.entropy_flags|=entropy.ARRAY_FLAG_ALLOW_SPLIT|entropy.ARRAY_FLAG_ALLOW_HUFFLENS2|
        entropy.ARRAY_FLAG_ALLOW_RLE_MEMSET

    tbo:=match.Table_Bits_Options{seek_chunk_reset=o.seek_chunk_reset,
        seek_chunk_len=o.seek_chunk_len,
        match_table_size_log2=o.match_table_size_log2}
    table_bits:=int(match.get_lz_match_table_bits(raw_len,max(level,compressor.LEVEL_VERY_FAST),16,20,
        17,24,tbo))
    explicit_bits:=o.match_table_size_log2>0

    hash_len:=4
    if level<compressor.LEVEL_NORMAL && level>=compressor.LEVEL_HYPER_FAST2 {
        if o.min_match_len>4 {
            hash_len=int(min(8,o.min_match_len))
        } else if raw_len>64*1024 && match.guess_should_hash_length_be_over_four(raw) {
            hash_len=6
        }
    }
    e.hash_len=hash_len

    ok:=true
    base:=raw_data(raw)
    if level<=compressor.LEVEL_HYPER_FAST1 {
        switch level {
        case compressor.LEVEL_HYPER_FAST1:
            if !explicit_bits {table_bits=min(table_bits,16)}
            e.matcher=Ctmf_Hyper32{}
        case compressor.LEVEL_HYPER_FAST2:
            if !explicit_bits {table_bits=min(table_bits,14)}
            e.matcher=Ctmf_Hyper16{}
        case:
            if !explicit_bits {table_bits=min(table_bits,12)}
            e.matcher=Ctmf_Hyper16{}
        }
        e.entropy_flags&=~(entropy.ARRAY_FLAG_ALLOW_TANS|entropy.ARRAY_FLAG_ALLOW_SPLIT|
            entropy.ARRAY_FLAG_ALLOW_RLE)
    } else if level<=compressor.LEVEL_SUPER_FAST {
        if !explicit_bits {table_bits=min(table_bits,19)}
        e.matcher=Ctmf_Hyper32{}
        e.entropy_flags&=~(entropy.ARRAY_FLAG_ALLOW_TANS|entropy.ARRAY_FLAG_ALLOW_SPLIT|
            entropy.ARRAY_FLAG_ALLOW_RLE)
    } else if level<=compressor.LEVEL_VERY_FAST {
        e.matcher=Ctmf_Very_Fast{}
        e.entropy_flags&=~(entropy.ARRAY_FLAG_ALLOW_TANS|entropy.ARRAY_FLAG_ALLOW_SPLIT)
    } else if level==compressor.LEVEL_FAST {
        if !explicit_bits {table_bits=min(table_bits,21)}
        e.matcher=Ctmf_Fast{}
        e.entropy_flags&=~(entropy.ARRAY_FLAG_ALLOW_TANS|entropy.ARRAY_FLAG_ALLOW_SPLIT)
    } else if level==compressor.LEVEL_NORMAL {
        e.matcher=Ctmf_Normal{}
        e.entropy_flags&=~entropy.ARRAY_FLAG_ALLOW_TANS
        hash_len=0
    }

    switch &m in e.matcher {
    case Ctmf_Very_Fast: ok=match.ctmf_allocate(&m,table_bits,table_bits,16,arena,
        hash_len); m.base_ptr=base
    case Ctmf_Fast: ok=match.ctmf_allocate(&m,table_bits,table_bits,16,arena,
        hash_len); m.base_ptr=base
    case Ctmf_Normal: ok=match.ctmf_allocate(&m,table_bits,table_bits,16,arena,
        hash_len); m.base_ptr=base
    case Ctmf_Hyper32: ok=match.fast_ctmf_allocate(&m,table_bits,table_bits,16,arena,
        hash_len); m.base_ptr=base
    case Ctmf_Hyper16: ok=match.fast_ctmf_allocate(&m,table_bits,table_bits,16,arena,
        hash_len); m.base_ptr=base
    }
    if !ok {destroy(e,arena);return false}

    e.arrays_space=entropy.arena_alloc(arena,u8,arrays_space_size(compressor.CHUNK_LEN))
    if e.arrays_space==nil {destroy(e,arena);return false}
    if e.optimal.setup!=nil && !e.optimal.setup(e,arena) {destroy(e,arena);return false}
    return true
}

destroy :: proc(e:^Encoder, arena:^entropy.Arena) {
    if arena==nil {return}
    switch &m in e.matcher {
    case Ctmf_Very_Fast: match.ctmf_release(&m,arena)
    case Ctmf_Fast: match.ctmf_release(&m,arena)
    case Ctmf_Normal: match.ctmf_release(&m,arena)
    case Ctmf_Hyper32: match.fast_ctmf_release(&m,arena)
    case Ctmf_Hyper16: match.fast_ctmf_release(&m,arena)
    }
    e.matcher=nil
    entropy.arena_free(arena,e.arrays_space)
    entropy.arena_free(arena,e.parse_space)
    entropy.arena_free(arena,e.arrivals_space)
    entropy.arena_free(arena,e.last_tll_len_space)
    e.arrays_space=nil;e.parse_space=nil;e.arrivals_space=nil;e.last_tll_len_space=nil
}

// fp_encode_chunk: returns the compressed length; >= chunk_len means expanded or failed.
// match_pairs holds match.NEWLZ_MATCH_NUM_PAIRS pairs per position of the chunk (optimal levels).
encode_chunk :: proc(e:^Encoder, arena:^entropy.Arena, dictionary_base:[^]u8,
    chunk_ptr:[^]u8, chunk_len:int, comp:[^]u8, comp_end:[^]u8, chunk_pos:int,
    chunk_type:^i32, J:^f32, deadlines:^entropy.LZ_Chunk_Deadlines,
    match_pairs:[^]match.Unpacked_Match_Pair) -> int {
    ct:i32;jj:f32
    pct:=chunk_type!=nil ? chunk_type : &ct
    pj:=J!=nil ? J : &jj
    pct^=-1
    pj^=entropy.LAGRANGE_COST_INVALID
    if chunk_len<=0 {return 0}
    if e==nil || arena==nil || chunk_ptr==nil || comp==nil || comp_end==nil ||
        e.arrays_space==nil ||
        chunk_len>compressor.CHUNK_LEN || uintptr(comp_end)<uintptr(comp) {return chunk_len}
    raw_base:=raw_data(e.raw)
    if raw_base==nil || dictionary_base!=raw_base || uintptr(chunk_ptr)<uintptr(raw_base) ||
        pdiff(chunk_ptr,raw_base)+chunk_len>len(e.raw) || chunk_pos<0 || chunk_pos>pdiff(chunk_ptr,
            raw_base) {
        return chunk_len
    }
    // a chunk after the first reads MIN_OFFSET bytes of history before it
    if chunk_pos!=0 && pdiff(chunk_ptr,raw_base)<compressor.MIN_OFFSET {return chunk_len}
    dl:entropy.LZ_Chunk_Deadlines
    if deadlines!=nil {dl=deadlines^} else {entropy.speedfit_deadlines_lz(&dl,chunk_len)}

    c:=Chunk{e=e,arena=arena,dictionary_base=dictionary_base,chunk_ptr=chunk_ptr,
        chunk_len=chunk_len,
        comp=comp,comp_end=comp_end,chunk_pos=chunk_pos,deadline=&dl}
    ret:int
    if e.optimal.encode_chunk!=nil {
        if match_pairs==nil || e.parse_space==nil || e.arrivals_space==nil {return chunk_len}
        ret=e.optimal.encode_chunk(&c,match_pairs,pct,pj)
    } else {
        switch &m in e.matcher {
        case Ctmf_Hyper32:
            if e.level==compressor.LEVEL_HYPER_FAST1 {ret=encode_chunk_fast_mode(&c,&m,4,true,0,true,
                false,pct,pj)}
            else {ret=encode_chunk_fast_mode(&c,&m,5,true,0,true,true,pct,pj)}
        case Ctmf_Hyper16:
            if e.level==compressor.LEVEL_HYPER_FAST2 {ret=encode_chunk_fast_mode(&c,&m,4,true,0,false,
                false,pct,pj)}
            else {ret=encode_chunk_fast_mode(&c,&m,3,false,1,false,false,pct,pj)}
        case Ctmf_Very_Fast: ret=encode_chunk_lazy(&c,&m,0,true,8,pct,pj)
        case Ctmf_Fast: ret=encode_chunk_lazy(&c,&m,1,true,0,pct,pj)
        case Ctmf_Normal: ret=encode_chunk_lazy(&c,&m,2,true,0,pct,pj)
        case: return chunk_len
        }
    }
    if ret<0 || ret>=chunk_len {return chunk_len}
    return ret
}

// Arguments of one encode_chunk call shared by the parsers and the output.
Chunk :: struct {
    e:^Encoder, arena:^entropy.Arena, dictionary_base:[^]u8,
    chunk_ptr:[^]u8, chunk_len:int, comp:[^]u8, comp_end:[^]u8, chunk_pos:int,
    deadline:^entropy.LZ_Chunk_Deadlines,
}

dictionary_size :: #force_inline proc "contextless" (o:^Options) -> u32 {
    if o.dictionary_size<=0 {return compressor.MAX_OFFSET}
    return min(u32(compressor.MAX_OFFSET),u32(o.dictionary_size))
}

