package asset

import "base:runtime"
import "mirai:std/codec"
import "mirai:std/lz4"
import "mirai:std/zstd"

// The codecs the engine holds: Zstandard for what loads once or travels, LZ4 for what streams
// while playing. Every program reads them; a game shipped with something else leaves them out.

ASSET_OPEN :: #config(ASSET_OPEN,true)

OPEN_ZSTD :: codec.Id(u32('Z')|u32('S')<<8|u32('T')<<16|u32('D')<<24)
OPEN_LZ4 :: codec.Id(u32('L')|u32('Z')<<8|u32('4')<<16|u32('H')<<24)
@(private) OPEN_COUNT :: 2

open_general :: proc "contextless" () -> codec.Encode {return {id=OPEN_ZSTD,bound=open_zstd_bound,encode=open_zstd_encode,edit=3,ship=22,quick=6}}

open_streamed :: proc "contextless" () -> codec.Encode {return {id=OPEN_LZ4,bound=open_lz4_bound,encode=open_lz4_encode,edit=3,ship=lz4.HC_CLEVEL_MAX,quick=lz4.HC_CLEVEL_DEFAULT}}

open_decoders :: proc "contextless" () -> codec.Table {
    table:codec.Table
    table.list[0]={id=OPEN_ZSTD,scratch_make=open_zstd_scratch_make,scratch_free=open_zstd_scratch_free,decode=open_zstd_decode}
    table.list[1]={id=OPEN_LZ4,decode=open_lz4_decode}
    table.count=OPEN_COUNT
    return table
}

@(private="file")
open_zstd_bound :: proc "c" (size:uint) -> uint {return size>uint(max(int))?0:uint(zstd.compress_bound(int(size)))}

// A piece holds at most PACK_PIECE bytes, so the highest levels ask for no more memory to decode
// than the lowest.
@(private="file")
open_zstd_encode :: proc "c" (level:i32,src:[^]u8,src_bytes:uint,dst:[^]u8,capacity:uint) -> uint {
    context=runtime.default_context()
    if src_bytes>zstd.MAX_SOURCE_BYTES || capacity>uint(max(int)) {return 0}
    written,err:=zstd.compress(dst,int(capacity),src,int(src_bytes),int(level),allocator=runtime.heap_allocator())
    return err!=.None?0:uint(written)
}

@(private="file")
open_lz4_bound :: proc "c" (size:uint) -> uint {
    return size>uint(max(i32))?0:uint(lz4.compress_bound(int(size)))
}

@(private="file")
open_lz4_encode :: proc "c" (level:i32,src:[^]u8,src_bytes:uint,dst:[^]u8,capacity:uint) -> uint {
    context=runtime.default_context()
    if src_bytes==0 || src_bytes>uint(max(i32)) || capacity>uint(max(i32)) {return 0}
    written,ok:=lz4.compress_hc(src[:src_bytes],dst[:capacity],int(level),runtime.heap_allocator())
    return ok?uint(written):0
}

@(private="file")
open_zstd_scratch_make :: proc "c" () -> rawptr {
    context=runtime.default_context()
    dctx,err:=zstd.dctx_create(runtime.heap_allocator())
    return err!=.None?nil:dctx
}

@(private="file")
open_zstd_scratch_free :: proc "c" (scratch:rawptr) {
    context=runtime.default_context()
    zstd.dctx_destroy((^zstd.DCtx)(scratch),runtime.heap_allocator())
}

@(private="file")
open_zstd_decode :: proc "c" (scratch:rawptr,src:[^]u8,src_bytes:uint,dst:[^]u8,dst_bytes:uint) -> bool {
    if src_bytes>uint(max(int)) || dst_bytes>uint(max(int)) {return false}
    written,err:=zstd.decompress_dctx((^zstd.DCtx)(scratch),dst,int(dst_bytes),src,int(src_bytes))
    return err==.None && uint(written)==dst_bytes
}

@(private="file")
open_lz4_decode :: proc "c" (scratch:rawptr,src:[^]u8,src_bytes:uint,dst:[^]u8,dst_bytes:uint) -> bool {
    if src_bytes>uint(max(i32)) || dst_bytes>uint(max(i32)) {return false}
    written,ok:=lz4.decompress_safe(src[:src_bytes],dst[:dst_bytes])
    return ok && uint(written)==dst_bytes
}
