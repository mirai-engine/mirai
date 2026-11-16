package movie

import "core:compress/deflate"

// The files of a recording: a sequence of images, each an OpenEXR of half
// floats or a PNG of 16 bits a channel, and the sound beside it in a WAV of
// 32-bit floats. Images come as RGBA 32-bit float, rows from the top; their
// alpha is not written.

Error :: enum u8 {
    None,
    Invalid,      // a size or a buffer that do not agree
    Out_Of_Memory,
    Write_Failed,
}

error_message :: proc(error:Error) -> string {
    switch error {
    case .None:          return "no error"
    case .Invalid:       return "the size of the image and its pixels do not agree"
    case .Out_Of_Memory: return "out of memory"
    case .Write_Failed:  return "the file could not be written"
    }
    return ""
}

// A zlib stream of data appended to out; false without memory.
@(private)
deflate_append :: proc(out:^[dynamic]u8,data:[]u8) -> bool {
    bound:=deflate.deflate_bound(len(data))
    start:=len(out)
    if bound<0 || non_zero_resize(out,start+bound)!=nil {return false}
    s:=new(deflate.Deflate)
    if s==nil {return false}
    defer free(s)
    written,error:=deflate.deflate_zlib_to_slice(s,out[start:],data)
    resize(out,start+written)
    return error==nil
}

@(private)
put_u32_le :: proc(out:^[dynamic]u8,v:u32) {append(out,u8(v),u8(v>>8),u8(v>>16),u8(v>>24))}
@(private)
put_u32_be :: proc(out:^[dynamic]u8,v:u32) {append(out,u8(v>>24),u8(v>>16),u8(v>>8),u8(v))}
