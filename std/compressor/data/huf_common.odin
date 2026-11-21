#+private
package data

import "base:intrinsics"

@(private)
Huff_Error :: enum {
    None,
    Generic,
    Corruption_Detected,
    Table_Log_Too_Large,
    Max_Symbol_Value_Too_Large,
    Max_Symbol_Value_Too_Small,
    Workspace_Too_Small,
    Dst_Size_Too_Small,
    Src_Size_Wrong,
}

@(private)
HUF_TABLELOG_MAX :: 12
@(private)
HUF_TABLELOG_DEFAULT :: 11
@(private)
HUF_SYMBOLVALUE_MAX :: 255
@(private)
HUF_TABLELOG_ABSOLUTEMAX :: 12
@(private)
HUF_WORKSPACE_SIZE :: (8<<10)+512
@(private)
FSE_MAX_SYMBOL_VALUE :: 255
@(private)
FSE_MAX_TABLELOG :: 12
@(private)
FSE_MIN_TABLELOG :: 5
@(private)
FSE_TABLELOG_ABSOLUTE_MAX :: 15
@(private)
padd :: #force_inline proc "contextless" (p:[^]u8,n:int) -> [^]u8 {
    return ([^]u8)(uintptr(p)+uintptr(n))
}
@(private)
pdiff :: #force_inline proc "contextless" (a,b:[^]u8) -> int {return int(uintptr(a)-uintptr(b))}
@(private)
read16 :: #force_inline proc "contextless" (p:[^]u8) -> u16 {
    return intrinsics.unaligned_load((^u16)(p))
}
@(private)
read32 :: #force_inline proc "contextless" (p:[^]u8) -> u32 {
    return intrinsics.unaligned_load((^u32)(p))
}
@(private)
read64 :: #force_inline proc "contextless" (p:[^]u8) -> u64 {
    return intrinsics.unaligned_load((^u64)(p))
}
@(private)
write16 :: #force_inline proc "contextless" (p:[^]u8,v:u16) {
    intrinsics.unaligned_store((^u16)(p),v)
}
@(private)
write64 :: #force_inline proc "contextless" (p:[^]u8,v:u64) {
    intrinsics.unaligned_store((^u64)(p),v)
}
@(private)
highbit32 :: #force_inline proc "contextless" (v:u32) -> u32 {
    return 31-intrinsics.count_leading_zeros(v)
}
@(private)
ctz32 :: #force_inline proc "contextless" (v:u32) -> u32 {return intrinsics.count_trailing_zeros(v)}
@(private)
ctz64 :: #force_inline proc "contextless" (v:u64) -> u32 {
    return u32(intrinsics.count_trailing_zeros(v))
}
