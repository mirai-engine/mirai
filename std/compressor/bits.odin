package compressor

import "base:intrinsics"
import "base:runtime"

// With COMPRESSOR_CHECKED the tables the decoder builds from what a stream says (code lengths,
// symbol lists, state counts, run lengths) are slices, and every index into them is bounds
// checked; without it they are pointers, and what their builders validate is all that guards
// them. The mutation tests run with it next to the sanitizer, which sees the bytes of the
// stream, the output and the scratch, pointers in both.
@(private) CHECKED :: #config(COMPRESSOR_CHECKED,false)

when CHECKED {
    @(private) view :: #force_inline proc "contextless" (a:^$A/[$N]$T) -> []T {return a[:]}
} else {
    @(private) view :: #force_inline proc "contextless" (a:^$A/[$N]$T) -> [^]T {return ([^]T)(a)}
}

// Unaligned loads and stores. Every target is little-endian.

@(private) load16 :: #force_inline proc "contextless" (
    p:[^]u8,
) -> u32 {return u32(intrinsics.unaligned_load((^u16)(p)))}
@(private) load32 :: #force_inline proc "contextless" (
    p:[^]u8,
) -> u32 {return intrinsics.unaligned_load((^u32)(p))}
@(private) load64 :: #force_inline proc "contextless" (
    p:[^]u8,
) -> u64 {return intrinsics.unaligned_load((^u64)(p))}
@(private) load16be :: #force_inline proc "contextless" (
    p:[^]u8,
) -> u32 {return u32(p[0])<<8|u32(p[1])}
@(private) load24be :: #force_inline proc "contextless" (
    p:[^]u8,
) -> u32 {return u32(p[0])<<16|u32(p[1])<<8|u32(p[2])}
@(private) load24le :: #force_inline proc "contextless" (
    p:[^]u8,
) -> u32 {return u32(p[0])|u32(p[1])<<8|u32(p[2])<<16}
@(private) load32be :: #force_inline proc "contextless" (
    p:[^]u8,
) -> u32 {return intrinsics.byte_swap(load32(p))}
@(private) load64be :: #force_inline proc "contextless" (
    p:[^]u8,
) -> u64 {return intrinsics.byte_swap(load64(p))}
@(private) store32 :: #force_inline proc "contextless" (
    p:[^]u8,v:u32,
) {intrinsics.unaligned_store((^u32)(p),v)}
@(private) store64 :: #force_inline proc "contextless" (
    p:[^]u8,v:u64,
) {intrinsics.unaligned_store((^u64)(p),v)}
@(private) copy8 :: #force_inline proc "contextless" (dst,src:[^]u8) {store64(dst,load64(src))}
@(private) copy16 :: #force_inline proc "contextless" (dst,src:[^]u8) {
    intrinsics.unaligned_store((^[16]u8)(dst),intrinsics.unaligned_load((^[16]u8)(src)))
}

// The 8 bytes at src plus the 8 bytes at prev, lane by lane.
@(private) copy_add8 :: #force_inline proc "contextless" (dst,prev,src:[^]u8) {
    a:=intrinsics.unaligned_load((^#simd[8]u8)(prev))
    b:=intrinsics.unaligned_load((^#simd[8]u8)(src))
    intrinsics.unaligned_store((^#simd[8]u8)(dst),a+b)
}

@(private) ptr_diff :: #force_inline proc "contextless" (
    a,b:[^]u8,
) -> int {return int(uintptr(a))-int(uintptr(b))}
@(private) align_up :: #force_inline proc "contextless" (p:[^]u8,align:uintptr) -> [^]u8 {
    return ([^]u8)((uintptr(p)+align-1)&~(align-1))
}

// count in 0..31
@(private) mask32 :: #force_inline proc "contextless" (
    count:u32,
) -> u32 {return ~(~u32(0)<<(count&31))}

// Bit reader that takes bits from the top of a 64-bit word: forward streams
// read bytes in order, backward streams from the end down.
@(private)
Bits :: struct {
    bits:u64,
    inv_bitlen:int, // 63 - the number of valid bits
    cur:[^]u8,
    end:[^]u8,
}

@(private) bits_len :: #force_inline proc "contextless" (b:^Bits) -> int {return 63-b.inv_bitlen}

@(private) bits_open_no_refill :: #force_inline proc "contextless" (b:^Bits,ptr,end:[^]u8) {
    b.bits=0;b.inv_bitlen=63;b.cur=ptr;b.end=end
}

@(private) get8_safe :: #force_inline proc "contextless" (
    p,end:[^]u8,
) -> u64 {return ptr_diff(end,p)>0 ? u64(p[0]) : 0}

@(private) get64be_safe :: #force_inline proc "contextless" (p,end:[^]u8) -> u64 {
    if ptr_diff(end,p)>=8 {return load64be(p)}
    v:u64
    for i in 0..<8 {v=v<<8|get8_safe(p[i:],end)}
    return v
}

@(private) bits_refill_safe :: #force_inline proc "contextless" (b:^Bits) #no_bounds_check {
    len:=uint(bits_len(b))&63
    consumed:=b.inv_bitlen>>3
    b.bits|=get64be_safe(b.cur,b.end)>>len
    b.cur=b.cur[consumed:]
    b.inv_bitlen-=consumed<<3
}

@(private) bits_refill :: #force_inline proc "contextless" (b:^Bits) #no_bounds_check {
    len:=uint(bits_len(b))&63
    consumed:=b.inv_bitlen>>3
    b.bits|=load64be(b.cur)>>len
    b.cur=b.cur[consumed:]
    b.inv_bitlen-=consumed<<3
}

@(private) bits_refill_back :: #force_inline proc "contextless" (b:^Bits) #no_bounds_check {
    len:=uint(bits_len(b))&63
    consumed:=b.inv_bitlen>>3
    b.bits|=load64(b.cur[-8:])>>len
    b.cur=b.cur[-consumed:]
    b.inv_bitlen-=consumed<<3
}

@(private) bits_open :: #force_inline proc "contextless" (b:^Bits,ptr,end:[^]u8) #no_bounds_check {
    bits_open_no_refill(b,ptr,end)
    b.bits=get8_safe(b.cur,b.end)<<56
    b.cur=b.cur[1:]
    b.inv_bitlen-=8
    bits_refill_safe(b)
}

// count in 1..56
@(private) bits_get :: #force_inline proc "contextless" (b:^Bits,count:int) -> u64 {
    c:=uint(count)&63
    v:=b.bits>>((64-c)&63)
    b.bits<<=c
    b.inv_bitlen+=count
    return v
}

// count in 0..56
@(private) bits_get0 :: #force_inline proc "contextless" (b:^Bits,count:int) -> u64 {
    c:=uint(count)&63
    v:=(b.bits>>1)>>((63-c)&63)
    b.bits<<=c
    b.inv_bitlen+=count
    return v
}

@(private) bits_get1 :: #force_inline proc "contextless" (b:^Bits) -> u64 {
    v:=b.bits>>63
    b.bits<<=1
    b.inv_bitlen+=1
    return v
}

@(private) bits_peek :: #force_inline proc "contextless" (
    b:^Bits,count:int,
) -> u64 {return b.bits>>((64-uint(count))&63)}

@(private) bits_use :: #force_inline proc "contextless" (b:^Bits,count:int) {
    b.bits<<=uint(count)&63
    b.inv_bitlen+=count
}

@(private) bits_clz :: #force_inline proc "contextless" (
    b:^Bits,
) -> int {return int(intrinsics.count_leading_zeros(b.bits))}

@(private) bits_end_ptr :: #force_inline proc "contextless" (
    b:^Bits,
) -> [^]u8 {return b.cur[-(bits_len(b)/8):]}
@(private) bits_back_end_ptr :: #force_inline proc "contextless" (
    b:^Bits,
) -> [^]u8 {return b.cur[bits_len(b)/8:]}

// Exp-Golomb code with rshift raw low bits; false on more than 18-rshift
// leading zeros.
@(private) bits_get_expgolomb :: #force_inline proc "contextless" (
    b:^Bits,rshift:int,
) -> (u32,bool) {
    minval:=u64(1)<<uint(63-(18-rshift))
    if b.bits<minval {return 0,false}
    lz:=bits_clz(b)
    v:=bits_get(b,2*lz+1+rshift)
    return u32(v-(u64(1)<<uint(rshift))),true
}

// Reads count bits under an implied top bit: (1<<count)|bits, count in 0..56.
@(private) bits_get_plus_top :: #force_inline proc "contextless" (b:^Bits,count:int) -> u32 {
    return u32(u64(1)<<uint(count)|bits_get0(b,count))
}

// Bit cursor over bytes read most significant bit first.
@(private)
Block_Bits :: struct {
    ptr:[^]u8,
    end:[^]u8,
    pos_in_byte:u32, // bits of ptr[0] already consumed, from the top
}

@(private) bits_to_block :: #force_inline proc "contextless" (b:^Bits) -> Block_Bits {
    len:=uint(bits_len(b))
    return {ptr=b.cur[-int((len+7)>>3):],end=b.end,pos_in_byte=u32((0-len)&7)}
}

@(private) bits_from_block :: #force_inline proc "contextless" (b:^Bits,bb:^Block_Bits) {
    bits_open(b,bb.ptr,bb.end)
    bits_use(b,int(bb.pos_in_byte))
}

@(private) fill :: #force_inline proc "contextless" (p:[^]u8,v:u8,n:int) {
    if n>0 {runtime.memset(p,i32(v),n)}
}

// 8 literals at to: raw, or added to the bytes at match.
@(private) literals_copy8 :: #force_inline proc "contextless" (to,match,lits:[^]u8,$SUB:bool) {
    when SUB {copy_add8(to,match,lits)} else {copy8(to,lits)}
}
