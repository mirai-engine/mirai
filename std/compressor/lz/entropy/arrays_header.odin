package entropy

import "base:intrinsics"
import "core:mem"
import "mirai:std/compressor"

LAGRANGE_COST_INVALID :: f32(1024*1024*1024)
ARRAY_DEADLINE_HUGE :: f32(1024*1024*1024*1024)



// entropy_flags: the optional array features a stream may use.
ARRAY_FLAG_ALLOW_HUFF6 :: u32(1<<0)
ARRAY_FLAG_ALLOW_TANS :: u32(1<<1)
ARRAY_FLAG_ALLOW_RLE :: u32(1<<2)
ARRAY_FLAG_ALLOW_RLEHUFF :: u32(1<<3)
ARRAY_FLAG_ALLOW_SPLIT :: u32(1<<4)
ARRAY_FLAG_ALLOW_SPLIT_INDEXED :: u32(1<<5)
ARRAY_FLAG_ALLOW_HUFFLENS2 :: u32(1<<6)
ARRAY_FLAG_ALLOW_RLE_MEMSET :: u32(1<<7)

// Uncompressed array header: 3 bytes, big-endian length. Returns the position after it.
put_array_uncomp_header :: #force_inline proc "contextless" (to:[^]u8, from_len:int) -> [^]u8 {
    h:=u32(from_len)
    to[0]=u8(h>>16);to[1]=u8(h>>8);to[2]=u8(h)
    return to[3:]
}

// Compressed array header: 5 bytes of type (4 bits), from_len-1 (18 bits) and comp_len (18 bits),
// in front of the comp_len payload bytes already at to[5:]. Returns the position after the payload.
put_array_comp_header :: #force_inline proc "contextless" (to:[^]u8, array_type:int,
    from_len:int, comp_len:int) -> [^]u8 {
    h:=u64(array_type)<<36+u64(from_len-1)<<compressor.ARRAY_SIZE_BITS+u64(comp_len)
    to[0]=u8(h>>32);to[1]=u8(h>>24);to[2]=u8(h>>16);to[3]=u8(h>>8);to[4]=u8(h)
    return to[5+comp_len:]
}

put_array_huff3_memset_payload :: #force_inline proc "contextless" (to:[^]u8, value:u8) -> [^]u8 {
    to[0]=0x00
    to[1]=0x40|(value>>2)
    to[2]=(value&3)<<6
    return to[3:]
}

put_array_huff3_memset :: #force_inline proc "contextless" (to:[^]u8, from_len:int,
    value:u8) -> [^]u8 {
    put_array_huff3_memset_payload(to[5:],value)
    return put_array_comp_header(to,compressor.ARRAY_TYPE_HUFF,from_len,3)
}

ptr_diff :: #force_inline proc "contextless" (a,b:[^]u8) -> int {
    return int(uintptr(a))-int(uintptr(b))
}

// Subtracts the bytes `offset` back from each of the n bytes at from (sub literals).
put_sub_literals :: #force_inline proc "contextless" (to:[^]u8, from:[^]u8, n:int,
    offset:int) #no_bounds_check {
    back:=([^]u8)(uintptr(from)-uintptr(offset))
    i:=0
    for ;i+16<=n;i+=16 {
        a:=intrinsics.unaligned_load((^#simd[16]u8)(&from[i]))
        b:=intrinsics.unaligned_load((^#simd[16]u8)(&back[i]))
        intrinsics.unaligned_store((^#simd[16]u8)(&to[i]),a-b)
    }
    for ;i<n;i+=1 {to[i]=from[i]-back[i]}
}

@(private) copy_bytes :: #force_inline proc "contextless" (to,from:[^]u8,
    n:int) {if n>0 {mem.copy(to,from,n)}}
