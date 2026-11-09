package tracy

import "base:intrinsics"

// The LZ4 block format of the frames the Tracy server reads: sequences of a
// token, literals, a 16-bit offset and a match length, with the end rules of
// the reference decoder.

LZ4_MAX_INPUT :: 0x7e000000

@(private="file") MIN_MATCH :: 4
@(private="file") LAST_LITERALS :: 5
@(private="file") MATCH_LIMIT :: 12 // a match never starts in the last 12 bytes
@(private="file") HASH_LOG :: 14
@(private="file") MAX_OFFSET :: 65535
@(private="file") SKIP_SHIFT :: 6

// The largest size lz4_compress can produce for an input of this size.
lz4_bound :: proc "contextless" (size:int) -> int {return size+size/255+16}

@(private="file")
load32 :: #force_inline proc "contextless" (p:[^]u8,at:int) -> u32 {return intrinsics.unaligned_load((^u32)(&p[at]))}
@(private="file")
load64 :: #force_inline proc "contextless" (p:[^]u8,at:int) -> u64 {return intrinsics.unaligned_load((^u64)(&p[at]))}

@(private="file")
length_bytes :: #force_inline proc "contextless" (length:int) -> int {return length>=15?(length-15)/255+1:0}

@(private="file")
write_length :: #force_inline proc "contextless" (out:[^]u8,at:int,length:int) -> int {
    at,rest:=at,length
    for rest>=255 {out[at]=255;at+=1;rest-=255}
    out[at]=u8(rest)
    return at+1
}

// Compresses src into dst. Fails when dst is smaller than what the input
// needs; lz4_bound(len(src)) always fits.
lz4_compress :: proc(src:[]u8,dst:[]u8) -> (size:int,ok:bool) #no_bounds_check {
    length:=len(src)
    if length>LZ4_MAX_INPUT {return 0,false}
    in_,out:=raw_data(src),raw_data(dst)
    capacity:=len(dst)
    op,anchor:=0,0
    if length>MATCH_LIMIT {
        table:[1<<HASH_LOG]u32
        match_end:=length-LAST_LITERALS
        last_start:=length-MATCH_LIMIT
        ip:=1
        search: for ip<=last_start {
            sequence:=load32(in_,ip)
            slot:=(sequence*2654435761)>>(32-HASH_LOG)
            ref:=int(table[slot])
            table[slot]=u32(ip)
            if ref>=ip || ip-ref>MAX_OFFSET || load32(in_,ref)!=sequence {
                ip+=1+(ip-anchor)>>SKIP_SHIFT
                continue
            }
            for ip>anchor && ref>0 && in_[ip-1]==in_[ref-1] {ip-=1;ref-=1}
            literals:=ip-anchor
            match:=MIN_MATCH
            for ip+match+8<=match_end {
                difference:=load64(in_,ip+match)~load64(in_,ref+match)
                if difference!=0 {
                    match+=int(intrinsics.count_trailing_zeros(difference)>>3)
                    break
                }
                match+=8
            }
            if ip+match+8>match_end {
                for ip+match<match_end && in_[ip+match]==in_[ref+match] {match+=1}
            }
            // token, literal length bytes, literals, offset, match length bytes
            if op+1+length_bytes(literals)+literals+2+length_bytes(match-MIN_MATCH)>capacity {return 0,false}
            token:=op
            op+=1
            if literals>=15 {
                out[token]=0xf0
                op=write_length(out,op,literals-15)
            } else {
                out[token]=u8(literals<<4)
            }
            intrinsics.mem_copy_non_overlapping(&out[op],&in_[anchor],literals)
            op+=literals
            offset:=ip-ref
            out[op],out[op+1]=u8(offset),u8(offset>>8)
            op+=2
            if match-MIN_MATCH>=15 {
                out[token]|=0x0f
                op=write_length(out,op,match-MIN_MATCH-15)
            } else {
                out[token]|=u8(match-MIN_MATCH)
            }
            ip+=match
            anchor=ip
            if ip<=last_start {
                table[(load32(in_,ip-2)*2654435761)>>(32-HASH_LOG)]=u32(ip-2)
            }
        }
    }
    literals:=length-anchor
    if op+1+length_bytes(literals)+literals>capacity {return 0,false}
    token:=op
    op+=1
    if literals>=15 {
        out[token]=0xf0
        op=write_length(out,op,literals-15)
    } else {
        out[token]=u8(literals<<4)
    }
    if literals>0 {intrinsics.mem_copy_non_overlapping(&out[op],&in_[anchor],literals)}
    return op+literals,true
}
