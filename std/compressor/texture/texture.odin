package texture

// The layouts of runs of blocks of textures, the contract every implementation of the collection
// compressor keeps: a layout stores a run of blocks rearranged so that it compresses smaller, and
// a read restores it by the layout its write returned (blocks.layout_encode). This one has no
// layout; the private one has the same declarations.

// How a run of blocks is stored, four characters; NO_LAYOUT: as the blocks are.
Layout :: distinct u32
NO_LAYOUT :: Layout(0)

// What a layout keeps beside its payload.
Layout_Header :: [12]u32

Error :: enum u8 {
    None,
    Unknown_Format, // a layout this implementation does not restore
    Corrupt,        // a header or a payload that contradicts itself
    Out_Of_Memory,
}

// What a layout holds: the blocks it restores and the bytes of its payload.
layout_read :: proc "contextless" (layout:Layout,header:Layout_Header) -> (blocks:int,size:int,error:Error) {
    return 0,0,.Unknown_Format
}

// What the restores of one thread keep, made once by whoever reads.
Layout_Decoder :: struct {}

layout_decoder_init :: proc(d:^Layout_Decoder,allocator:=context.allocator) -> Error {return .None}

layout_decoder_destroy :: proc(d:^Layout_Decoder) {}

// The blocks of a payload into dst, of the blocks layout_read says. Never reads or writes outside
// src and dst, whatever they hold.
layout_decode :: proc(d:^Layout_Decoder,layout:Layout,header:Layout_Header,src,dst:[]u8) -> Error {
    return .Unknown_Format
}
