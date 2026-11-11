package lz_optimal

import "base:intrinsics"
import "mirai:std/compressor"
import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor/lz/match"

// Find-all finder of Optimal1: a depth-16 cache table with a second hash of 8 bytes, minimum match
// 4, plus the LRM. Matches of 77 or more are carried forward: positions inside them report the
// same offset every 4 bytes and nothing in between.

Cache_Table_Ctmf :: match.Ctmf(u32,4,8,4)

@(private="file") LONG_MATCH_LEN :: 77
@(private="file") PREFETCH_DIST :: 8
@(private="file") U32x8 :: #simd[8]u32

Cache_Table_Finder :: struct {
    ubuf,raw,raw_end:[^]u8,
    size,pos,parse_end_pos:int,
    lrms:^Lrm_Set,
    long_match_pos,long_match_end:int,
    long_match_len,long_match_offs:i32,
    ctmf:Cache_Table_Ctmf,
    scanner:Lrm_Scanner,
}

@(private)
cache_table_init :: proc(f:^Cache_Table_Finder,ubuf:[^]u8,size,start_recording_pos:int,
    lrms:^Lrm_Set,arena:^entropy.Arena) -> bool {
    f.ubuf=ubuf
    f.raw=padd(ubuf,start_recording_pos)
    f.raw_end=padd(ubuf,size)
    f.size=size
    f.parse_end_pos=size-8
    f.pos=start_recording_pos
    f.lrms=lrms
    table_bits:=clamp(int(entropy.ilog2ceil(u32(match.clamp_s32(size)))),18,24)
    if !match.ctmf_allocate(&f.ctmf,table_bits,0,0,arena,0) {return false}
    // every hashed position needs 8 bytes; with fewer left nothing is ever searched
    if start_recording_pos+8<=size {
        match.ctmf_set_base_and_preload(&f.ctmf,ubuf,f.raw,start_recording_pos)
        match.ctmf_set_next(&f.ctmf,f.raw)
    } else {
        match.ctmf_set_base(&f.ctmf,ubuf)
    }
    lrm_scanner_windowed_init(&f.scanner,f.lrms,f.raw,f.raw_end,compressor.MAX_OFFSET)
    return true
}

@(private)
cache_table_release :: proc(f:^Cache_Table_Finder,arena:^entropy.Arena) {match.ctmf_release(&f.ctmf,
    arena)}

@(private="file")
eval_matches :: #force_inline proc "contextless" (matches:^[33]match.Unpacked_Match_Pair,num:int,pos:int,
    row,row2:[^]u32,hash:u32,
    ptr,ptr_matchend:[^]u8,neg_offs_limit:int) -> int #no_bounds_check {
    num:=num
    ref:=U32x8(hash&match.CTMF_CHECK_MASK)
    cm:=U32x8(match.CTMF_CHECK_MASK)
    r00:=intrinsics.unaligned_load((^#simd[8]u32)(row))
    r01:=intrinsics.unaligned_load((^#simd[8]u32)(&row[8]))
    r10:=intrinsics.unaligned_load((^#simd[8]u32)(row2))
    r11:=intrinsics.unaligned_load((^#simd[8]u32)(&row2[8]))
    m00:=u32(transmute(u8)intrinsics.simd_extract_msbs(intrinsics.simd_lanes_eq(r00&cm,ref)))
    m01:=u32(transmute(u8)intrinsics.simd_extract_msbs(intrinsics.simd_lanes_eq(r01&cm,ref)))
    m10:=u32(transmute(u8)intrinsics.simd_extract_msbs(intrinsics.simd_lanes_eq(r10&cm,ref)))
    m11:=u32(transmute(u8)intrinsics.simd_extract_msbs(intrinsics.simd_lanes_eq(r11&cm,ref)))
    valid:=m00|m01<<8|m10<<16|m11<<24
    if row==row2 {valid&=0xffff}
    prevml:=3
    for valid!=0 {
        d:=int(intrinsics.count_trailing_zeros(valid))
        valid&=valid-1
        e:=d<16?row[d]:row2[d-16]
        neg:=match.ctmf_resolve_neg_offset(e,u32(pos))
        if neg<neg_offs_limit {continue}
        l:int
        if !match.havematch_better(ptr,padd(ptr,neg),ptr_matchend,prevml,&l) {continue}
        prevml=l
        matches[num]=match.Unpacked_Match_Pair{i32(l),i32(-neg)}
        num+=1
    }
    return num
}

@(private="file")
process_chunk_template :: proc(f:^Cache_Table_Finder,pos,chunk_start,chunk_end:int,
    out:[^]match.Unpacked_Match_Pair,max_pairs:int) -> int #no_bounds_check {
    pos:=pos
    parse_end_pos:=f.parse_end_pos
    lrms:=f.lrms
    ubuf:=f.ubuf
    raw_end:=f.raw_end
    ptr_matchend:=padd(raw_end,-4)
    c:=&f.ctmf
    for ;pos<chunk_end;pos+=1 {
        ptr:=padd(ubuf,pos)
        row:=c.next_row
        hash:=c.next_hash
        row2:=c.next_row_second
        if pos+PREFETCH_DIST<parse_end_pos {match.ctmf_prefetch_next(c,padd(ptr,PREFETCH_DIST))}
        match.ctmf_set_next(c,padd(ptr,1))
        matches:[33]match.Unpacked_Match_Pair=---
        num:=0
        if lrms!=nil {
            lrm_offset:int
            lrm_length:=lrm_scanner_windowed_find_match_and_roll(&f.scanner,ptr,raw_end,&lrm_offset)
            if lrm_length>0 {
                matches[0]=match.Unpacked_Match_Pair{lrm_length,i32(lrm_offset)}
                num+=1
            }
        }
        num=eval_matches(&matches,num,pos,row,row2,hash,ptr,ptr_matchend,-pos)
        match.ctmf_insert(c,row,u32(pos),hash)
        match.ctmf_insert(c,row2,u32(pos),hash)
        cur:=out[(pos-chunk_start)*max_pairs:]
        if num==0 {
            cur[0].length=0
            continue
        }
        if num>1 {
            for i in 1..<num {
                m:=matches[i]
                j:=i
                for j>0 && match_pair_less(m,matches[j-1]) {matches[j]=matches[j-1];j-=1}
                matches[j]=m
            }
            num=match_pairs_unique(matches[:num],match_pair_equal_length)
        }
        longest:=matches[0].length
        num=min(num,max_pairs)
        for i in 0..<num {cur[i]=matches[i]}
        if num<max_pairs {cur[num].length=0}
        if longest>=LONG_MATCH_LEN {
            f.long_match_pos=pos
            f.long_match_end=pos+int(longest)
            f.long_match_len=longest
            f.long_match_offs=matches[0].offset
            pos=report_long_match(f,out,chunk_start,chunk_end,pos,max_pairs)-1
        }
    }
    return pos
}

@(private="file")
report_long_match :: proc(f:^Cache_Table_Finder,out:[^]match.Unpacked_Match_Pair,chunk_start,chunk_end,
    pos:int,max_pairs:int) -> int #no_bounds_check {
    lo:=max(f.long_match_pos+1,chunk_start)
    hi:=min(f.long_match_end,chunk_end)
    for i in lo..<hi {out[(i-chunk_start)*max_pairs].length=0}
    if f.long_match_pos+1>=lo && f.long_match_pos+1<hi {
        cur:=out[(f.long_match_pos+1-chunk_start)*max_pairs:]
        cur[0]=match.Unpacked_Match_Pair{f.long_match_len-1,f.long_match_offs}
        cur[1].length=0
    }
    STEP :: 4
    loop_start:=max(f.long_match_pos+2,lo)
    loop_start+=(f.long_match_pos-loop_start)&(STEP-1)
    for i:=loop_start;i<hi;i+=STEP {
        cur:=out[(i-chunk_start)*max_pairs:]
        cur[0]=match.Unpacked_Match_Pair{i32(f.long_match_end-i),f.long_match_offs}
        cur[1].length=0
    }
    if hi==f.long_match_end {
        if f.long_match_end<f.parse_end_pos {
            match.ctmf_step_and_insert(&f.ctmf,padd(f.ubuf,f.long_match_pos),int(f.long_match_len))
        }
        if f.lrms!=nil {
            lrm_scanner_windowed_init(&f.scanner,f.lrms,padd(f.ubuf,f.long_match_end),f.raw_end,
                compressor.MAX_OFFSET)
        }
        f.long_match_offs=0
    }
    return hi
}

@(private)
cache_table_process_chunk :: proc(f:^Cache_Table_Finder,chunk_size:int,out:[^]match.Unpacked_Match_Pair,
    max_pairs:int) -> int #no_bounds_check {
    pos:=f.pos
    chunk_start:=pos
    chunk_end:=min(pos+chunk_size,f.parse_end_pos)
    real_chunk_end:=min(pos+chunk_size,f.size)
    if f.long_match_offs!=0 && pos<chunk_end {
        pos=report_long_match(f,out,chunk_start,chunk_end,pos,max_pairs)
    }
    pos=process_chunk_template(f,pos,chunk_start,chunk_end,out,max_pairs)
    for ;pos<real_chunk_end;pos+=1 {out[(pos-chunk_start)*max_pairs].length=0}
    f.pos=max(pos,f.pos)
    return real_chunk_end-chunk_start
}
