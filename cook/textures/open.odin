package textures

import "base:runtime"
import "mirai:cook/encoders/bc6h"
import "mirai:cook/encoders/rdo"
import "mirai:std/codec"
import "mirai:std/jobs"

// The value of the lambda of Build_Options that stands for a lambda of 1 in the RDO of cook/encoders.
@(private="file")
OPEN_LAMBDA_ONE :: 30

// An image of at least this many texels is encoded on a job system of its own.
@(private="file")
OPEN_PARALLEL_TEXELS :: 256*256

// Names what the open encoders write in the caches.
@(private)
OPEN_ID :: 0x6f70656e00000001

open_external :: proc "contextless" () -> External {return {encode=open_encode,id=OPEN_ID}}

// The blocks of one image by cook/encoders. fast: for what an import in the editor makes, without
// RDO and with the least search.
@(private)
open_encode_image :: proc(format:codec.Texture_Format,pixels:[^]u8,width,height,lambda:int,srgb,fast:bool,out:[]u8,worker:jobs.Worker_Ref) -> bool {
    if format==.BC6H {
        settings:=bc6h.settings_of(.Very_Fast if fast else .Basic)
        return bc6h.encode_image(&settings,([^]u16)(pixels)[:width*height*4],width,height,out,worker)
    }
    params:=rdo.params_default()
    params.rdo_lambda=f32(lambda)/OPEN_LAMBDA_ONE
    params.perceptual=srgb
    if fast {
        params.bc7_uber_level=0
        params.bc1_quality_level=4
        params.use_hq_bc345=false
    }
    formats:=#partial [codec.Texture_Format]rdo.Format{.BC1=.BC1,.BC3=.BC3,.BC5=.BC5,.BC7=.BC7}
    return rdo.encode(formats[format],pixels[:width*height*4],width,height,params,out,worker)
}

// As a plugin's encoder: what a program that holds other encoders calls to make these.
@(private="file")
open_encode :: proc "c" (format:codec.Texture_Format,pixels:[^]u8,width,height,lambda:i32,srgb:bool,out:[^]u8,out_bytes:uint) -> bool {
    context=runtime.default_context()
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    if width<=0 || height<=0 || pixels==nil || out==nil {return false}
    js:jobs.Job_System
    on:jobs.Worker_Ref
    if int(width)*int(height)>=OPEN_PARALLEL_TEXELS && jobs.system_init(&js,{threads=jobs.THREADS_AUTO}) {on={&js,jobs.OWNER,nil}}
    defer if on.system!=nil {jobs.system_destroy(&js)}
    return open_encode_image(format,pixels,int(width),int(height),int(lambda),srgb,false,out[:out_bytes],on)
}
