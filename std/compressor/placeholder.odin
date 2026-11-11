package compressor

// What the engine compiles against when the private codec is not in this checkout: declarations
// only, and every call says it is not there.
when !#exists("implemented.odin") {
    IMPLEMENTED :: false
    LEVEL_SUPER_FAST :: 1
    LEVEL_OPTIMAL1 :: 5
    LEVEL_OPTIMAL5 :: 9
    BLOCK_LEN :: 1<<18
    BLOCK_HEADER_SIZE :: 2
    QUANTUM_HEADER_SIZE :: 3
    Error :: enum u8 {None,Truncated,Corrupt,Unsupported,Output_Too_Small,Out_Of_Memory}
    Decoder :: struct {}
    Piece :: struct {src,dst:int}
    decoder_init :: proc(d:^Decoder,allocator:=context.allocator) -> Error {return .Unsupported}
    decoder_destroy :: proc(d:^Decoder) {}
    decompress :: proc(d:^Decoder,src:[]u8,dst:[]u8) -> (written:int,error:Error) {return 0,.Unsupported}
    pieces :: proc(src:[]u8,dst_len:int,out:[]Piece) -> (count:int,error:Error) {return 0,.Unsupported}
}
