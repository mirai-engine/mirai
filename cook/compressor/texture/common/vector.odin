package common

import "base:intrinsics"
import "core:simd"

V16u8 :: #simd[16]u8
V8i16 :: #simd[8]i16
V8u16 :: #simd[8]u16
V4i32 :: #simd[4]i32
V4u32 :: #simd[4]u32
V4f32 :: #simd[4]f32
V32u8 :: #simd[32]u8
V16i16 :: #simd[16]i16
V16u16 :: #simd[16]u16
V8i32 :: #simd[8]i32
V8u32 :: #simd[8]u32
V8f32 :: #simd[8]f32


load_u8x16 :: #force_inline proc "contextless" (p:rawptr) -> V16u8 {
    return intrinsics.unaligned_load((^V16u8)(p))
}

// Sum of the absolute differences of the bytes (psadbw, uabd).
// Not reduce_add_bisect: it keeps half of the sum (llvm/llvm-project#239204).
sad_u8x16 :: #force_inline proc "contextless" (a,b:V16u8) -> u32 {
    return simd.reduce_add_ordered(cast(#simd[16]u32)(simd.max(a,b)-simd.min(a,b)))
}

// The squared RGBA difference of each of four texels.
ssd_rgba4 :: #force_inline proc "contextless" (a,b:V16u8) -> V4i32 {
    d:=transmute(V8i16)(simd.max(a,b)-simd.min(a,b))
    lo:=d&V8i16(0xff)
    hi:=transmute(V8i16)simd.shr(transmute(V8u16)d,V8u16(8))
    return madd_i16(lo,lo)+madd_i16(hi,hi)
}

// [a0+a1, a2+a3, b0+b1, b2+b3]
hadd_i32 :: #force_inline proc "contextless" (a,b:V4i32) -> V4i32 {
    return simd.shuffle(a,b,0,2,4,6)+simd.shuffle(a,b,1,3,5,7)
}

// base+k for each set bit k of the low four bits of m, packed into to[0:4] (all four are
// written); returns how many.
store_active_lanes4 :: #force_inline proc "contextless" (to:[^]i32,base:i32,
    m:u32) -> int #no_bounds_check {
    t:=ACTIVE_LANE_TABLE8[m&15]
    v:=transmute(V4i32)(simd.shr(V4u32(t),V4u32{0,4,8,12})&V4u32(15))+V4i32(base)
    intrinsics.unaligned_store((^V4i32)(to),v)
    return int(intrinsics.count_ones(m&15))
}

// The SADs of four groups of 16 bytes, from their sad_halves.
sad_sum4 :: #force_inline proc "contextless" (s0,s1,s2,s3:V4u32) -> V4i32 {
    return hadd_i32(transmute(V4i32)simd.shuffle(s0,s1,0,2,4,6),
        transmute(V4i32)simd.shuffle(s2,s3,0,2,4,6))
}

// How many of the 16 values at keys are below x.
count_below_i16x16 :: #force_inline proc "contextless" (keys:[^]i16,x:i16) -> int {
    a:=intrinsics.unaligned_load((^V8i16)(keys))
    b:=intrinsics.unaligned_load((^V8i16)(keys[8:]))
    m:=u32(transmute(u8)simd.extract_msbs(simd.lanes_lt(a,V8i16(x))))|
        u32(transmute(u8)simd.extract_msbs(simd.lanes_lt(b,V8i16(x))))<<8
    return int(intrinsics.count_ones(m))
}
