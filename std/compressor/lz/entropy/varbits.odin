package entropy

import "base:intrinsics"

// Big-endian bit writer: the most significant bit goes out first. put does not write; output
// writes the whole bytes waiting (at most 56 bits may wait between outputs). Writes never pass
// `end`: what does not fit is dropped, so a caller checks the size against its bound.
Var_Bits :: struct {cur:[^]u8, end:[^]u8, bits:u64, bitlen:int}

VARBITS_MAX_BITS_PER_STEP :: 31

varbits_open :: #force_inline proc "contextless" (vb:^Var_Bits, ptr:[^]u8, end:[^]u8) {
    vb^=Var_Bits{cur=ptr,end=end}
}

varbits_put :: #force_inline proc "contextless" (vb:^Var_Bits, val:u64, count:int) {
    vb.bits=(vb.bits<<uint(count))|val
    vb.bitlen+=count
}

varbits_output :: #force_inline proc "contextless" (vb:^Var_Bits) #no_bounds_check {
    n:=vb.bitlen>>3
    if n==0 {return}
    w:=vb.bits<<uint(64-vb.bitlen)
    room:=ptr_diff(vb.end,vb.cur)
    if room>=8 {
        intrinsics.unaligned_store((^u64be)(vb.cur),u64be(w))
    } else {
        for i in 0..<min(n,room) {vb.cur[i]=u8(w>>uint(56-8*i))}
    }
    vb.cur=vb.cur[n:]
    vb.bitlen-=n<<3
}

// Backward writer: bytes go to decreasing addresses, the first one at cur-1; `end` is the lowest
// address it may write.
varbits_output_back :: #force_inline proc "contextless" (vb:^Var_Bits) #no_bounds_check {
    n:=vb.bitlen>>3
    if n==0 {return}
    w:=vb.bits<<uint(64-vb.bitlen)
    room:=ptr_diff(vb.cur,vb.end)
    if room>=8 {
        intrinsics.unaligned_store((^u64le)(uintptr(vb.cur)-8),u64le(w))
    } else {
        for i in 0..<min(n,room) {
            p:=([^]u8)(uintptr(vb.cur)-uintptr(i+1))
            p[0]=u8(w>>uint(56-8*i))
        }
    }
    vb.cur=([^]u8)(uintptr(vb.cur)-uintptr(n))
    vb.bitlen-=n<<3
}

// Pads the last partial byte with zero bits and writes it.
varbits_put_flush8 :: proc "contextless" (vb:^Var_Bits) {
    varbits_output(vb)
    if vb.bitlen>0 {
        varbits_put(vb,0,8-vb.bitlen)
        varbits_output(vb)
    }
}

varbits_put_flush8_back :: proc "contextless" (vb:^Var_Bits) {
    varbits_output_back(vb)
    if vb.bitlen>0 {
        varbits_put(vb,0,8-vb.bitlen)
        varbits_output_back(vb)
    }
}

varbits_put_end_ptr :: #force_inline proc "contextless" (vb:^Var_Bits) -> [^]u8 {
    return vb.cur[(vb.bitlen+7)/8:]
}
varbits_put_size_bytes :: #force_inline proc "contextless" (vb:^Var_Bits, base:[^]u8) -> int {
    return ptr_diff(vb.cur,base)+(vb.bitlen+7)/8
}

bit_level_nonzero :: #force_inline proc "contextless" (v:u32) -> u32 {
    return 32-u32(intrinsics.count_leading_zeros(v))
}
bit_level :: #force_inline proc "contextless" (v:u32) -> u32 {
    return v!=0 ? bit_level_nonzero(v) : 0
}

ilog2ceil :: #force_inline proc "contextless" (v:u32) -> u32 {
    if v<=1 {return 0}
    return 32-u32(intrinsics.count_leading_zeros(v-1))
}

count_bits_elias_gamma :: #force_inline proc "contextless" (val:u32) -> int {
    topbit:=bit_level_nonzero(val+1)-1
    return 1+2*int(topbit)
}
count_bits_exp_golomb :: #force_inline proc "contextless" (val:u32, rshift:u32) -> int {
    return count_bits_elias_gamma(val>>rshift)+int(rshift)
}

write_unary :: proc "contextless" (vb:^Var_Bits, val:u32) {
    val:=val
    for val>=VARBITS_MAX_BITS_PER_STEP {
        varbits_put(vb,0,VARBITS_MAX_BITS_PER_STEP)
        varbits_output(vb)
        val-=VARBITS_MAX_BITS_PER_STEP
    }
    varbits_put(vb,1,int(val)+1)
    varbits_output(vb)
}

write_rice :: proc "contextless" (vb:^Var_Bits, val:u32, bits:u32) {
    write_unary(vb,val>>bits)
    varbits_put(vb,u64(val&((u32(1)<<bits)-1)),int(bits))
    varbits_output(vb)
}

write_elias_gamma :: proc "contextless" (vb:^Var_Bits, val:u32) {
    v:=val+1
    topbit:=bit_level_nonzero(v)-1
    write_unary(vb,topbit)
    if topbit>0 {
        v-=u32(1)<<topbit
        varbits_put(vb,u64(v),int(topbit))
        varbits_output(vb)
    }
}

write_exp_golomb :: proc "contextless" (vb:^Var_Bits, val:u32, rshift:u32) {
    write_elias_gamma(vb,val>>rshift)
    varbits_put(vb,u64(val&((u32(1)<<rshift)-1)),int(rshift))
    varbits_output(vb)
}
