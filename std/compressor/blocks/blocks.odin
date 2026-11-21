package blocks

import "mirai:std/jobs"
import "../texture"

// Open cooks encode in cook/textures. The private collection can encode and lay out blocks.
NAME :: "open"

Block_Format :: enum u8 {BC1,BC5,BC6H,BC7}

Pixel_Format :: enum u8 {RGBA8,RGBA16F}

// width*height pixels, rows from the top.
Surface :: struct {
    pixels:[]u8,
    width,height:int,
    format:Pixel_Format,
}

Options :: struct {
    lambda:int,        // of the rate-distortion optimization, up to 100: how much error buys blocks that compress smaller. 0: none
    fast:bool,         // the least search: what the editor imports in its session
    srgb:bool,         // color: the error is weighed as it is seen
    ignore_alpha:bool, // BC7 of an opaque image: alpha decodes 255
}

Error :: enum u8 {
    None,
    Invalid,          // a surface or a format the encoder does not take
    Output_Too_Small,
    Out_Of_Memory,
}

encode :: proc(
    format:Block_Format,src:Surface,options:Options,dst:[]u8,
    allocator:=context.allocator,worker:=jobs.Worker_Ref{},
) -> Error {return .Invalid}

// The most layout_encode writes for a run of that many blocks.
layout_bound :: proc "contextless" (blocks:int) -> int {return 0}

// The blocks of a run, the smallest level first, in the layout that stores them smallest into
// dst, of at least layout_bound bytes: texture.NO_LAYOUT when none does better than the blocks.
layout_encode :: proc(format:Block_Format,blocks:[]u8,dst:[]u8,allocator:=context.allocator) -> (layout:texture.Layout,header:texture.Layout_Header,size:int,error:Error) {
    return texture.NO_LAYOUT,{},0,.None
}
