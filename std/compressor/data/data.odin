package data

import "base:runtime"

Profile :: enum u8 {
    Fast,     // the least time to write: what the editor and a running game save
    Speed,    // the least time to read: what streams while playing
    Balanced, // between the two: what a development cook writes
    Ultra,    // the smallest: what a shipped game loads once
}

// Four characters, stored beside what a format wrote so that a read finds what decodes it.
Format :: distinct u32

MDC2 :: Format(u32('M')|u32('D')<<8|u32('C')<<16|u32('2')<<24)

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
    mdc:^Decode_Work,
    allocator:runtime.Allocator,
}

encoder_init :: proc(e:^Encoder,allocator:=context.allocator) -> Error {
    e^={allocator=allocator}
    return .None
}

encoder_destroy :: proc(e:^Encoder) {
    if e.mdc!=nil {
        delete(e.mdc.paths,e.allocator)
        delete(e.mdc.long_previous,e.allocator)
        delete(e.mdc.previous,e.allocator)
        delete(e.mdc.offset_counts,e.allocator)
        free(e.mdc,e.allocator)
    }
    e^={}
}

decoder_init :: proc(d:^Decoder,allocator:=context.allocator) -> Error {
    d^={}
    work,allocation:=new(Decode_Work,allocator)
    if allocation!=nil {return .Out_Of_Memory}
    d^={mdc=work,allocator=allocator}
    return .None
}

decoder_destroy :: proc(d:^Decoder) {
    if d.mdc!=nil {free(d.mdc,d.allocator)}
    d^={}
}

// The format a profile writes.
format :: proc "contextless" (profile:Profile) -> Format {
    return MDC2
}

// The most encode writes for size bytes, whatever the profile.
bound :: proc "contextless" (size:int) -> int {
    if size<=0 || size>MAX_BYTES {return 0}
    return size+1+4*((size-1)/BLOCK_BYTES)
}

// What format wrote into src, into all of dst, which is its decoded size. Never reads or writes
// outside them, whatever src holds.
decode :: proc(d:^Decoder,format:Format,src,dst:[]u8) -> Error {
    if format!=MDC2 {return .Unknown_Format}
    if len(dst)>MAX_BYTES {return .Corrupt}
    return decode_mdc2(d,src,dst)
}
