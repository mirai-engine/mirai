package bc7

import "core:math/bits"
import "mirai:cook/compressor/texture/common"

// Bit ranges of the fields of each BC7 mode, low to high: header, endpoints,
// pbits, indices.

// A BC7 block as two little-endian words.
Bits :: common.Bits128

TOTAL_BITS_ENDPOINTS :: [8]int{72,72,90,84,42,58,56,80}
TOTAL_BITS_PBITS     :: [8]int{6,2,0,4,0,0,2,4}
TOTAL_BITS_INDICES   :: [8]int{45,46,29,30,78,62,63,30}

@(rodata)
BITS_HEADER := [8]int{5,8,9,10,8,8,7,14}
@(rodata)
BITS_ENDPOINTS := [8]int{72,72,90,84,42,58,56,80}
@(rodata)
BITS_PBITS := [8]int{6,2,0,4,0,0,2,4}
@(rodata)
BITS_INDICES := [8]int{45,46,29,30,78,62,63,30}

@(rodata)
BITRANGE_HEADER_MASK := [8]Bits{
    {0x000000000000001F,0},{0x00000000000000FF,0},{0x00000000000001FF,0},{0x00000000000003FF,0},
    {0x00000000000000FF,0},{0x00000000000000FF,0},{0x000000000000007F,0},{0x0000000000003FFF,0},
}
@(rodata)
BITRANGE_ENDPOINTS_MASK := [8]Bits{
    {0xFFFFFFFFFFFFFFE0,0x0000000000001FFF},{0xFFFFFFFFFFFFFF00,0x000000000000FFFF},
    {0xFFFFFFFFFFFFFE00,0x00000007FFFFFFFF},{0xFFFFFFFFFFFFFC00,0x000000003FFFFFFF},
    {0x0003FFFFFFFFFF00,0x0000000000000000},{0xFFFFFFFFFFFFFF00,0x0000000000000003},
    {0x7FFFFFFFFFFFFF80,0x0000000000000000},{0xFFFFFFFFFFFFC000,0x000000003FFFFFFF},
}
@(rodata)
BITRANGE_PBITS_MASK := [8]Bits{
    {0,0x000000000007E000},{0,0x0000000000030000},{0,0},{0,0x00000003C0000000},
    {0,0},{0,0},{0x8000000000000000,0x0000000000000001},{0,0x00000003C0000000},
}
@(rodata)
BITRANGE_INDICES_MASK := [8]Bits{
    {0,0xFFFFFFFFFFF80000},{0,0xFFFFFFFFFFFC0000},{0,0xFFFFFFF800000000},{0,0xFFFFFFFC00000000},
    {0xFFFC000000000000,0xFFFFFFFFFFFFFFFF},{0,0xFFFFFFFFFFFFFFFC},{0,0xFFFFFFFFFFFFFFFE},
    {0,0xFFFFFFFC00000000},
}
@(rodata)
BITRANGE_HEADER_WITHOUT_MODE_MASK := [8]Bits{
    {0x1E,0},{0xFC,0},{0x1F8,0},{0x3F0,0},{0xE0,0},{0xC0,0},{0,0},{0x3F00,0},
}
@(rodata)
BITRANGE_ENDPOINTS_WITH_PBITS_MASK := [8]Bits{
    {0xFFFFFFFFFFFFFFE0,0x000000000007FFFF},{0xFFFFFFFFFFFFFF00,0x000000000003FFFF},
    {0xFFFFFFFFFFFFFE00,0x00000007FFFFFFFF},{0xFFFFFFFFFFFFFC00,0x00000003FFFFFFFF},
    {0x0003FFFFFFFFFF00,0x0000000000000000},{0xFFFFFFFFFFFFFF00,0x0000000000000003},
    {0xFFFFFFFFFFFFFF80,0x0000000000000001},{0xFFFFFFFFFFFFC000,0x00000003FFFFFFFF},
}
@(rodata)
BITRANGE_INDICES_WITH_PBITS_MASK := [8]Bits{
    {0,0xFFFFFFFFFFFFE000},{0,0xFFFFFFFFFFFF0000},{0,0xFFFFFFF800000000},{0,0xFFFFFFFFC0000000},
    {0xFFFC000000000000,0xFFFFFFFFFFFFFFFF},{0,0xFFFFFFFFFFFFFFFC},{0x8000000000000000,
        0xFFFFFFFFFFFFFFFF},
    {0,0xFFFFFFFFC0000000},
}

@(private)
bits_load :: #force_inline proc "contextless" (b:^[16]u8) -> Bits {
    r:Bits
    for i in 0..<8 {
        r[0]|=u64(b[i])<<uint(i*8)
        r[1]|=u64(b[8+i])<<uint(i*8)
    }
    return r
}

@(private)
bits_store :: #force_inline proc "contextless" (b:^[16]u8,v:Bits) {
    for i in 0..<8 {
        b[i]=u8(v[0]>>uint(i*8))
        b[8+i]=u8(v[1]>>uint(i*8))
    }
}

// The mode of a block; 8 when it has no mode bit.
@(private)
bits_get_mode :: #force_inline proc "contextless" (b:Bits) -> int {
    m:=int(bits.count_trailing_zeros(b[0]))
    return m>8 ? 8 : m
}

@(private)
bits_extract_indices :: proc "contextless" (b:Bits,with_pbits:bool) -> Bits {
    m:=bits_get_mode(b)&7
    mask:=with_pbits ? BITRANGE_INDICES_WITH_PBITS_MASK[m] : BITRANGE_INDICES_MASK[m]
    return b&mask
}

@(private)
bits_zero_indices :: proc "contextless" (b:Bits,also_zero_pbits:bool) -> Bits {
    return b~bits_extract_indices(b,also_zero_pbits)
}
