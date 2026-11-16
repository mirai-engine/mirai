package blocks

import "mirai:std/jobs"
import "../texture"
import "bc6h"
import "rdo"

// The block encoders of textures, the contract every implementation of the collection compressor
// keeps: the blocks of an image, and the layout that stores a run of them smallest
// (texture.Layout). This one encodes with bc7enc, rgbcx and bc6h and has no layout; the private
// one has the same declarations. What only a cook runs: a game does not import it.

// Names the blocks this implementation makes in caches and in the keys of imports.
NAME :: "open"

Block_Format :: enum u8 {BC1,BC3,BC5,BC6H,BC7}

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

// The lambda of Options that stands for a lambda of 1 in the RDO of rdo.
@(private="file")
LAMBDA_ONE :: 30

// The blocks of src into dst, ceil(width/4)*ceil(height/4) of them: BC6H from RGBA16F, the
// others from RGBA8. Alpha keeps its exact 0 and 255. Deterministic; with a worker of a job system
// the rows go on its workers.
encode :: proc(format:Block_Format,src:Surface,options:Options,dst:[]u8,allocator:=context.allocator,worker:=jobs.Worker_Ref{}) -> Error {
    if src.width<=0 || src.height<=0 {return .Invalid}
    blocks:=((src.width+3)/4)*((src.height+3)/4)
    pixel:=8 if src.format==.RGBA16F else 4
    if (format==.BC6H)!=(src.format==.RGBA16F) || len(src.pixels)<src.width*src.height*pixel {return .Invalid}
    if len(dst)<blocks*(8 if format==.BC1 else 16) {return .Output_Too_Small}
    if format==.BC6H {
        settings:=bc6h.settings_of(.Very_Fast if options.fast else .Basic)
        pixels:=([^]u16)(raw_data(src.pixels))[:src.width*src.height*4]
        return .None if bc6h.encode_image(&settings,pixels,src.width,src.height,dst,worker) else .Out_Of_Memory
    }
    params:=rdo.params_default()
    params.rdo_lambda=f32(options.lambda)/LAMBDA_ONE
    params.perceptual=options.srgb
    if options.fast {
        params.bc7_uber_level=0
        params.bc1_quality_level=4
        params.use_hq_bc345=false
    }
    formats:=#partial [Block_Format]rdo.Format{.BC1=.BC1,.BC3=.BC3,.BC5=.BC5,.BC7=.BC7}
    return .None if rdo.encode(formats[format],src.pixels[:src.width*src.height*4],src.width,src.height,params,dst,worker,allocator) else .Out_Of_Memory
}

// The most layout_encode writes for a run of that many blocks.
layout_bound :: proc "contextless" (blocks:int) -> int {return 0}

// The blocks of a run, the smallest level first, in the layout that stores them smallest into
// dst, of at least layout_bound bytes: texture.NO_LAYOUT when none does better than the blocks.
layout_encode :: proc(format:Block_Format,blocks:[]u8,dst:[]u8,allocator:=context.allocator) -> (layout:texture.Layout,header:texture.Layout_Header,size:int,error:Error) {
    return texture.NO_LAYOUT,{},0,.None
}
