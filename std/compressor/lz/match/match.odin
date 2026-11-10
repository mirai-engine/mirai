package match

import "base:intrinsics"
import "mirai:std/compressor"
import "mirai:std/compressor/lz/entropy"

// Match finders of the LZ encoder: the hash-cache tables the greedy and lazy parses drive
// directly (Ctmf, Fast_Ctmf). The find-all finders of the optimal parses and the long range
// matcher are in cook/compressor/lz. Offsets are positive distances back from the current
// position.

Unpacked_Match_Pair :: struct {length,offset:i32}

// Match pairs per position the optimal parses ask for.
NEWLZ_MATCH_NUM_PAIRS :: 4

//===================================================================
// Pointer helpers. A [^]u8 with a byte offset that may be negative.

padd :: #force_inline proc "contextless" (p:[^]u8,
    n:int) -> [^]u8 {return ([^]u8)(uintptr(p)+uintptr(n))}
pdiff :: #force_inline proc "contextless" (a,
    b:[^]u8) -> int {return int(uintptr(a))-int(uintptr(b))}

load16 :: #force_inline proc "contextless" (p:[^]u8) -> u16 {
    return intrinsics.unaligned_load((^u16)(p))
}
load32 :: #force_inline proc "contextless" (p:[^]u8) -> u32 {
    return intrinsics.unaligned_load((^u32)(p))
}
load64 :: #force_inline proc "contextless" (p:[^]u8) -> u64 {
    return intrinsics.unaligned_load((^u64)(p))
}

//===================================================================
// Match lengths. p1 is the current position and is checked against ptrend; p2 is the earlier
// position and is not. Every read stays below ptrend relative to p1, except the 32-bit loads of
// the *_one32/*_two32/mml3/mml4 variants, which need p1+4 <= ptrend.

getmatchlen_mml1 :: #force_inline proc "contextless" (p1,p2,ptrend:[^]u8) -> int #no_bounds_check {
    n:=pdiff(ptrend,p1)
    l:=0
    for l+8<=n {
        d:=load64(padd(p1,l))~load64(padd(p2,l))
        if d!=0 {return l+int(intrinsics.count_trailing_zeros(d)>>3)}
        l+=8
    }
    for l<n && p1[l]==p2[l] {l+=1}
    return l
}

getmatchlen_after4 :: #force_inline proc "contextless" (p1,p2,ptrend:[^]u8) -> int {
    return 4+getmatchlen_mml1(padd(p1,4),padd(p2,4),ptrend)
}

getmatchlen_mml4 :: #force_inline proc "contextless" (p1,p2,ptrend:[^]u8) -> int {
    if load32(p1)!=load32(p2) {return 0}
    return getmatchlen_after4(p1,p2,ptrend)
}

getmatchlen_mml4_two32 :: #force_inline proc "contextless" (p1_32,p2_32:u32,p1,p2,
    ptrend:[^]u8) -> int {
    if p1_32!=p2_32 {return 0}
    return getmatchlen_after4(p1,p2,ptrend)
}

getmatchlen_mml3_two32 :: #force_inline proc "contextless" (p1_32,p2_32:u32,p1,p2,
    ptrend:[^]u8) -> int {
    diff:=p1_32~p2_32
    if diff!=0 {return diff&0x00FFFFFF!=0?0:3}
    return getmatchlen_after4(p1,p2,ptrend)
}

getmatchlen_mml3_one32 :: #force_inline proc "contextless" (p1_32:u32,p1,p2,ptrend:[^]u8) -> int {
    return getmatchlen_mml3_two32(p1_32,load32(p2),p1,p2,ptrend)
}

getmatchlen_mml4_one32 :: #force_inline proc "contextless" (p1_32:u32,p1,p2,ptrend:[^]u8) -> int {
    return getmatchlen_mml4_two32(p1_32,load32(p2),p1,p2,ptrend)
}

havematch_mml2_one32 :: #force_inline proc "contextless" (p1_32:u32,p1,p2,ptrend:[^]u8,
    outml:^int) -> bool {
    p2_32:=load32(p2)
    if u16(p1_32)!=u16(p2_32) {return false}
    diff:=p1_32~p2_32
    if diff!=0 {
        outml^=diff&0x00FFFFFF!=0?2:3
        return true
    }
    outml^=getmatchlen_after4(p1,p2,ptrend)
    return true
}

// A match longer than prevml, if there is one.
havematch_better :: #force_inline proc "contextless" (p1,p2,ptrend:[^]u8,prevml:int,
    outml:^int) -> bool {
    if prevml>=pdiff(ptrend,p1) {return false}
    if p1[prevml]!=p2[prevml] {return false}
    l:=getmatchlen_mml1(p1,p2,ptrend)
    if l<=prevml {return false}
    outml^=l
    return true
}

//===================================================================

clamp_s32 :: #force_inline proc "contextless" (v:int) -> i32 {return i32(clamp(v,int(min(i32)),
    int(max(i32))))}

// The compress options GetLZMatchTableBits reads; the zero value is the library default.
Table_Bits_Options :: struct {seek_chunk_reset:bool, seek_chunk_len:i32, match_table_size_log2:i32}

// Hash table size of a greedy/lazy parse: log2 of the input clamped to [vf_lo,vf_hi] at
// SuperFast/VeryFast and to [lo,hi] above.
get_lz_match_table_bits :: proc "contextless" (raw_len:int,level:i32,vf_lo,vf_hi,lo,hi:i32,
    options:Table_Bits_Options={}) -> i32 {
    raw_len32:=clamp_s32(raw_len)
    size_for_table:=raw_len32
    if options.seek_chunk_reset && options.seek_chunk_len<raw_len32 {
        size_for_table=options.seek_chunk_len
    }
    log2:=i32(entropy.ilog2round(u32(size_for_table)))
    bits:i32
    if level<=compressor.LEVEL_VERY_FAST {bits=clamp(log2-1,vf_lo,vf_hi)} else {bits=clamp(log2,lo,hi)}
    if options.match_table_size_log2>0 {
        if options.match_table_size_log2>100 {
            bits=clamp(options.match_table_size_log2-100,8,28)
        } else {
            bits=clamp(min(bits,options.match_table_size_log2),12,26)
        }
    }
    return bits
}

@(private="file")
is_cont_byte :: #force_inline proc "contextless" (c:u8) -> bool {return c>=0x80 && c<=0xbf}

@(private="file")
all_cont_bytes :: proc "contextless" (s:[]u8) -> bool {
    for c in s {if !is_cont_byte(c) {return false}}
    return true
}

@(private="file")
might_be_utf8 :: proc "contextless" (s:[]u8) -> bool {
    p,end:=0,len(s)
    for p<end && is_cont_byte(s[p]) {p+=1}
    if p>3 {return false}
    for p<end {
        b:=s[p];p+=1
        if b>=0x09 && b<=0x7e {continue}
        if b>=0xc2 && b<=0xf4 {
            if b<=0xdf {
                if end-p<1 {return true}
                if !is_cont_byte(s[p]) {return false}
                p+=1
            } else if b<=0xef {
                if end-p<2 {return all_cont_bytes(s[p:])}
                if !is_cont_byte(s[p]) || !is_cont_byte(s[p+1]) {return false}
                p+=2
            } else {
                if end-p<3 {return all_cont_bytes(s[p:])}
                if !is_cont_byte(s[p]) || !is_cont_byte(s[p+1]) ||
                    !is_cont_byte(s[p+2]) {return false}
                p+=3
            }
        } else {
            return false
        }
    }
    return true
}

// Whether the fast levels hash more than 4 bytes: true for text (UTF-8 in most of 32 samples).
guess_should_hash_length_be_over_four :: proc "contextless" (buf:[]u8) -> bool {
    NSMP :: 32
    NBYTES :: 32
    size:=len(buf)
    step:=size/NSMP
    if step<NBYTES {return false}
    score:=0
    for smp in 0..<NSMP {
        pos:=smp*step
        if might_be_utf8(buf[pos:min(pos+NBYTES,size)]) {score+=1}
    }
    return score>=14
}
