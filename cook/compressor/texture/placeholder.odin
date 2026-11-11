package texture

import "mirai:std/jobs"

// See std/compressor/placeholder.odin. cook/textures encodes with cook/encoders without it.
when !#exists("implemented.odin") {
    IMPLEMENTED :: false
    Effort :: enum u8 {Default,Low,Normal,High}
    Format :: enum u8 {BC1,BC3,BC4,BC5,BC6H,BC7}
    Pixel_Format :: enum u8 {RGBA8,RGBA16F,RGBA32F}
    Metric :: enum u8 {Perceptual,RMSE}
    Surface :: struct {pixels:[]u8,width,height,stride:int,format:Pixel_Format}
    Options :: struct {effort:Effort,lambda:int,metric:Metric,ignore_alpha,preserve_extremes:bool}
    Error :: enum u8 {None,Invalid_Format,Out_Of_Memory}
    encode :: proc(format:Format,src:Surface,options:Options,dst:[]u8,allocator:=context.allocator,worker:=jobs.Worker_Ref{}) -> Error {return .Invalid_Format}
}
