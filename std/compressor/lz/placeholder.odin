package lz

// See std/compressor/placeholder.odin.
when !#exists("implemented.odin") {
    IMPLEMENTED :: false
    Level :: enum i8 {SuperFast=1,VeryFast,Fast,Normal}
    Mode :: struct {level:i32}
    Error :: enum u8 {None,Output_Too_Small,Out_Of_Memory,Invalid}
    Encoder :: struct {}
    mode :: proc "contextless" (level:Level) -> Mode {return {level=i32(level)}}
    encoder_init :: proc(e:^Encoder,allocator:=context.allocator) -> Error {return .Invalid}
    encoder_destroy :: proc(e:^Encoder) {}
    compress_bound :: proc "contextless" (size:int) -> int {return 0}
    compress :: proc(e:^Encoder,mode:Mode,src:[]u8,dst:[]u8,piece_len:=0) -> (size:int,error:Error) {return 0,.Invalid}
    compress_piece :: proc(e:^Encoder,mode:Mode,src:[]u8,dst:[]u8) -> (size:int,error:Error) {return 0,.Invalid}
}
