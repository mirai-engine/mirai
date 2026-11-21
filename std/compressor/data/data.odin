package data

import "base:runtime"
import "../lz4"
import "../zstd"

// Compression of bytes, the contract every implementation of the collection compressor keeps: a
// write chooses a profile, a read decodes by the format the profile wrote.

// Names this implementation in caches and reports.
NAME :: "open"

Profile :: enum u8 {
    Fast,     // the least time to write: what the editor and a running game save
    Speed,    // the least time to read: what streams while playing
    Balanced, // between the two: what a development cook writes
    Ultra,    // the smallest: what a shipped game loads once
}

// Four characters, stored beside what a format wrote so that a read finds what decodes it.
Format :: distinct u32

ZSTD :: Format(u32('Z')|u32('S')<<8|u32('T')<<16|u32('D')<<24)
LZ4 :: Format(u32('L')|u32('Z')<<8|u32('4')<<16|u32('H')<<24)
MDC1 :: Format(u32('M')|u32('D')<<8|u32('C')<<16|u32('1')<<24)
// The LZ of the private implementation, also the streams Unreal packages hold. This one does not
// decode it: Unknown_Format.
MLZ1 :: Format(u32('M')|u32('L')<<8|u32('Z')<<16|u32('1')<<24)

Error :: enum u8 {
    None,
    Unknown_Format,   // a format this implementation does not decode
    Corrupt,          // what was read does not decode to the size asked for
    Too_Large,        // more than the format takes in one call
    Output_Too_Small, // dst has less than bound
    Out_Of_Memory,
}

// What the writes of one thread keep.
Encoder :: struct {
    allocator:runtime.Allocator,
    mdc:^Encode_Work,
}

// What the reads of one thread keep, made once by whoever reads: decode does not allocate.
Decoder :: struct {
    zstd:^zstd.DCtx,
    mdc:^Decode_Work,
    allocator:runtime.Allocator,
}

encoder_init :: proc(e:^Encoder,allocator:=context.allocator) -> Error {
    e^={allocator=allocator}
    return .None
}

encoder_destroy :: proc(e:^Encoder) {
    if e.mdc!=nil {free(e.mdc,e.allocator)}
    e^={}
}

// An MDC1 reader also reserves the scratch of entropy blocks.
decoder_init :: proc(d:^Decoder,allocator:=context.allocator,mdc1:=false) -> Error {
    d^={allocator=allocator}
    dctx,err:=zstd.dctx_create(allocator)
    if err!=.None {return .Out_Of_Memory}
    d.zstd=dctx
    if !mdc1 {return .None}
    work,allocation:=new(Decode_Work,allocator)
    if allocation!=nil {
        decoder_destroy(d)
        return .Out_Of_Memory
    }
    d.mdc=work
    return .None
}

decoder_destroy :: proc(d:^Decoder) {
    if d.zstd!=nil {zstd.dctx_destroy(d.zstd,d.allocator)}
    if d.mdc!=nil {free(d.mdc,d.allocator)}
    d^={}
}

// The format a profile writes. open: only the formats of this implementation, which every build
// reads; this one has no others.
format :: proc "contextless" (profile:Profile,open:=false) -> Format {
    return LZ4 if profile==.Speed else ZSTD
}

// The most encode writes for size bytes, whatever the profile.
bound :: proc "contextless" (size:int) -> int {
    if size<0 || size>int(max(i32)) {return 0}
    return max(zstd.compress_bound(size),lz4.compress_bound(size),mdc_bound(size))
}

// src in the format of the profile into dst, of at least bound bytes. Deterministic.
encode :: proc(e:^Encoder,profile:Profile,src,dst:[]u8,open:=false) -> (size:int,error:Error) {
    if len(src)>int(max(i32)) {return 0,.Too_Large}
    if len(dst)<bound(len(src)) {return 0,.Output_Too_Small}
    allocator:=e.allocator if e.allocator.procedure!=nil else context.allocator
    if format(profile)==LZ4 {
        if len(src)==0 {return 0,.None}
        written,ok:=lz4.compress_hc(src,dst,lz4.HC_CLEVEL_MAX,allocator)
        return written,ok?.None:.Out_Of_Memory
    }
    levels:=[Profile]int{.Fast=3,.Speed=3,.Balanced=6,.Ultra=zstd.MAX_LEVEL}
    written,err:=zstd.compress(raw_data(dst),len(dst),raw_data(src),len(src),levels[profile],
        allocator=allocator)
    #partial switch err {
    case .None: return written,.None
    case .Memory_Allocation: return 0,.Out_Of_Memory
    }
    return 0,.Output_Too_Small
}

// What format wrote into src, into all of dst, which is its decoded size. Never reads or writes
// outside them, whatever src holds.
decode :: proc(d:^Decoder,format:Format,src,dst:[]u8) -> Error {
    if len(src)>int(max(i32)) || len(dst)>int(max(i32)) {return .Corrupt}
    switch format {
    case MDC1:
        return decode_mdc1(d,src,dst)
    case ZSTD:
        if d==nil || d.zstd==nil {return .Out_Of_Memory}
        written,err:=zstd.decompress_dctx(d.zstd,raw_data(dst),len(dst),raw_data(src),len(src))
        return .None if err==.None && written==len(dst) else .Corrupt
    case LZ4:
        if len(dst)==0 {return .None if len(src)==0 else .Corrupt}
        written,ok:=lz4.decompress_safe(src,dst)
        return .None if ok && written==len(dst) else .Corrupt
    }
    return .Unknown_Format
}
