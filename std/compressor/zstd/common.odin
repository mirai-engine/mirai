package zstd

import "base:intrinsics"

// What the decoder and the encoder share. The formats are little-endian and so are the three
// platforms, so reads and writes do not swap.

Error :: enum {
    None,
    Generic,
    Prefix_Unknown,
    Frame_Parameter_Unsupported,
    Frame_Parameter_Window_Too_Large,
    Corruption_Detected,
    Checksum_Wrong,
    Literals_Header_Wrong,
    Table_Log_Too_Large,
    Max_Symbol_Value_Too_Large,
    Max_Symbol_Value_Too_Small,
    Parameter_Unsupported,
    Parameter_Out_Of_Bound,
    Memory_Allocation,
    Workspace_Too_Small,
    Dst_Size_Too_Small,
    Src_Size_Wrong,
}

MAGIC_NUMBER :: u32(0xFD2FB528)
MAGIC_SKIPPABLE_START :: u32(0x184D2A50)
MAGIC_SKIPPABLE_MASK :: u32(0xFFFFFFF0)
SKIPPABLE_HEADER_SIZE :: 8
FRAME_ID_SIZE :: 4
FRAME_CHECKSUM_SIZE :: 4
BLOCK_HEADER_SIZE :: 3
BLOCK_SIZE_LOG_MAX :: 17
BLOCK_SIZE_MAX :: 1<<BLOCK_SIZE_LOG_MAX
MIN_CBLOCK_SIZE :: 2
MIN_LITERALS_FOR_4_STREAMS :: 6
WINDOW_LOG_ABSOLUTE_MIN :: 10
WINDOW_LOG_MAX :: 31

Block_Type :: enum u32 {Raw,RLE,Compressed,Reserved}
Symbol_Encoding_Type :: enum u32 {Basic,RLE,Compressed,Repeat}

KB :: 1<<10
MB :: 1<<20

OPT_NUM :: 1<<12
REP_NUM :: 3
@(rodata) REP_START_VALUE:=[REP_NUM]u32{1,4,8}

LONG_NB_SEQ :: 0x7F00
MINMATCH :: 3
LIT_BITS :: 8
LIT_HUF_LOG :: 11
MAX_LIT :: (1<<LIT_BITS)-1
MAX_ML :: 52
MAX_LL :: 35
DEFAULT_MAX_OFF :: 28
MAX_OFF :: 31
MAX_SEQ :: MAX_ML
ML_FSE_LOG :: 9
LL_FSE_LOG :: 9
OFF_FSE_LOG :: 8
MAX_FSE_LOG :: 9
MAX_ML_BITS :: 16
MAX_LL_BITS :: 16
MAX_HUF_HEADER_SIZE :: 128
MAX_FSE_HEADERS_SIZE :: ((MAX_ML+1)*ML_FSE_LOG+(MAX_LL+1)*LL_FSE_LOG+(MAX_OFF+1)*OFF_FSE_LOG+7)/8

@(rodata) LL_bits:=[MAX_LL+1]u8{
    0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,
    1,1,1,1,2,2,3,3,
    4,6,7,8,9,10,11,12,
    13,14,15,16,
}
@(rodata) LL_default_norm:=[MAX_LL+1]i16{
    4,3,2,2,2,2,2,2,
    2,2,2,2,2,1,1,1,
    2,2,2,2,2,2,2,2,
    2,3,2,1,1,1,1,1,
    -1,-1,-1,-1,
}
LL_DEFAULT_NORM_LOG :: 6

@(rodata) ML_bits:=[MAX_ML+1]u8{
    0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,
    1,1,1,1,2,2,3,3,
    4,4,5,7,8,9,10,11,
    12,13,14,15,16,
}
@(rodata) ML_default_norm:=[MAX_ML+1]i16{
    1,4,3,2,2,2,2,2,
    2,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,-1,-1,
    -1,-1,-1,-1,-1,
}
ML_DEFAULT_NORM_LOG :: 6

@(rodata) OF_default_norm:=[DEFAULT_MAX_OFF+1]i16{
    1,1,1,1,1,1,2,2,
    2,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,
    -1,-1,-1,-1,-1,
}
OF_DEFAULT_NORM_LOG :: 5

HUF_TABLELOG_MAX :: 12
HUF_TABLELOG_DEFAULT :: 11
HUF_SYMBOLVALUE_MAX :: 255
HUF_TABLELOG_ABSOLUTEMAX :: 12
HUF_WORKSPACE_SIZE :: (8<<10)+512
FSE_MAX_SYMBOL_VALUE :: 255
FSE_MAX_TABLELOG :: 12
FSE_MIN_TABLELOG :: 5
FSE_TABLELOG_ABSOLUTE_MAX :: 15

WILDCOPY_OVERLENGTH :: 32
WILDCOPY_VECLEN :: 16

// A position of a buffer, moved by any amount, also backwards.
padd :: #force_inline proc "contextless" (p:[^]u8,n:int) -> [^]u8 {return ([^]u8)(uintptr(p)+uintptr(n))}
// How many bytes a is after b.
pdiff :: #force_inline proc "contextless" (a,b:[^]u8) -> int {return int(uintptr(a)-uintptr(b))}

read16 :: #force_inline proc "contextless" (p:[^]u8) -> u16 {return intrinsics.unaligned_load((^u16)(p))}
read32 :: #force_inline proc "contextless" (p:[^]u8) -> u32 {return intrinsics.unaligned_load((^u32)(p))}
read64 :: #force_inline proc "contextless" (p:[^]u8) -> u64 {return intrinsics.unaligned_load((^u64)(p))}
read24 :: #force_inline proc "contextless" (p:[^]u8) -> u32 {return u32(read16(p))|u32(p[2])<<16}
write16 :: #force_inline proc "contextless" (p:[^]u8,v:u16) {intrinsics.unaligned_store((^u16)(p),v)}
write32 :: #force_inline proc "contextless" (p:[^]u8,v:u32) {intrinsics.unaligned_store((^u32)(p),v)}
write64 :: #force_inline proc "contextless" (p:[^]u8,v:u64) {intrinsics.unaligned_store((^u64)(p),v)}
write24 :: #force_inline proc "contextless" (p:[^]u8,v:u32) {write16(p,u16(v));p[2]=u8(v>>16)}

// The value is not 0.
highbit32 :: #force_inline proc "contextless" (v:u32) -> u32 {return 31-intrinsics.count_leading_zeros(v)}
ctz32 :: #force_inline proc "contextless" (v:u32) -> u32 {return intrinsics.count_trailing_zeros(v)}
ctz64 :: #force_inline proc "contextless" (v:u64) -> u32 {return u32(intrinsics.count_trailing_zeros(v))}
clz32 :: #force_inline proc "contextless" (v:u32) -> u32 {return intrinsics.count_leading_zeros(v)}
clz64 :: #force_inline proc "contextless" (v:u64) -> u32 {return u32(intrinsics.count_leading_zeros(v))}
nb_common_bytes :: #force_inline proc "contextless" (v:u64) -> int {return int(ctz64(v)>>3)}
rotr64 :: #force_inline proc "contextless" (v:u64,count:u32) -> u64 {return v>>(count&63)|v<<((0-count)&63)}
rotr32 :: #force_inline proc "contextless" (v:u32,count:u32) -> u32 {return v>>(count&31)|v<<((0-count)&31)}
rotr16 :: #force_inline proc "contextless" (v:u16,count:u32) -> u16 {return v>>(count&15)|v<<((0-count)&15)}

copy8 :: #force_inline proc "contextless" (dst,src:[^]u8) {write64(dst,read64(src))}

// A load and a store: the two may overlap.
copy16 :: #force_inline proc "contextless" (dst,src:[^]u8) {
    a,b:=read64(src),read64(padd(src,8))
    write64(dst,a)
    write64(padd(dst,8),b)
}

Overlap :: enum {No_Overlap,Src_Before_Dst}

// Copies at least length bytes and may write up to WILDCOPY_OVERLENGTH past them. With
// Src_Before_Dst the two may overlap but are at least 8 bytes apart.
wildcopy :: #force_inline proc "contextless" (dst,src:[^]u8,length:int,overlap:Overlap) {
    diff:=pdiff(dst,src)
    ip:=src
    op:=dst
    oend:=padd(op,length)
    if overlap==.Src_Before_Dst && diff<WILDCOPY_VECLEN {
        for {
            copy8(op,ip)
            op=padd(op,8);ip=padd(ip,8)
            if uintptr(op)>=uintptr(oend) {break}
        }
    } else {
        copy16(op,ip)
        if 16>=length {return}
        op=padd(op,16);ip=padd(ip,16)
        for {
            copy16(op,ip);op=padd(op,16);ip=padd(ip,16)
            copy16(op,ip);op=padd(op,16);ip=padd(ip,16)
            if uintptr(op)>=uintptr(oend) {break}
        }
    }
}
