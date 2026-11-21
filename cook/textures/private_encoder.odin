package textures

import "base:runtime"
import "core:mem"
import "compressor:blocks"
import "mirai:asset"
import "mirai:std/jobs"

when !OPEN_BLOCK_ENCODER {
    // Texels of a level from which build encodes its blocks on a job system of
    // its own, when the caller gives none.
    PARALLEL_TEXELS :: 128*128

    // How the blocks of a level are encoded.
    @(private)
    block_encode :: proc "contextless" (options:Build_Options) -> blocks.Options {
        return {lambda=rdo_lambda(options),fast=options.speed==.Fast,srgb=options.srgb}
    }

    // The blocks of a level, each layer apart, by the private compressor with the
    // lambda, effort and metric of encode: BC6H from half floats, the others from
    // RGBA8. Alpha keeps its exact 0 and 255, and a BC7 layer whose texels are all
    // opaque is encoded without alpha, which then decodes 255. On a worker the
    // blocks go in parallel, with scratch from the heap.
    @(private)
    level_encode :: proc(
        level:Source,format:asset.Texture_Format,transfer:^Transfer,encode:blocks.Options,
        allocator:mem.Allocator,worker:jobs.Worker_Ref,
    ) -> (out:[]u8,error:Error) {
        layers:=max(level.layers,1)
        texels:=level
        texels.layers=layers
        pixel:=blocks.Pixel_Format.RGBA8
        owned:=false
        defer if owned {delete(texels.texels,allocator)}
        alloc_error:mem.Allocator_Error
        if format==.BC6H {
            // Through texel_write, which clamps light to what half floats hold and makes a NaN 0.
            texels.format,pixel,owned=.RGBA16F,.RGBA16F,true
            texels.texels,alloc_error=make([]u8,source_bytes(texels),allocator)
            if alloc_error!=nil {return nil,.Out_Of_Memory}
            for at in 0..<level.width*level.height*layers {
                value:=texel_read(level.texels,level.format,at,transfer)
                texel_write(texels.texels,.RGBA16F,at,value,transfer)
            }
        } else if level.format!=.RGBA8 {
            texels.format,owned=.RGBA8,true
            texels.texels,alloc_error=level_convert(level,.RGBA8,transfer,transfer,allocator)
            if alloc_error!=nil {return nil,.Out_Of_Memory}
        }
        size:=asset.texture_level_size(format,level.width,level.height)
        if out,alloc_error=make([]u8,size*layers,allocator);alloc_error!=nil {return nil,.Out_Of_Memory}
        formats:=#partial [asset.Texture_Format]blocks.Block_Format{
            .BC1=.BC1,.BC5=.BC5,.BC6H=.BC6H,.BC7=.BC7,
        }
        scratch:=allocator if worker.system==nil else runtime.heap_allocator()
        image:=source_bytes(texels)/layers
        for layer in 0..<layers {
            pixels:=texels.texels[layer*image:][:image]
            options:=encode
            options.ignore_alpha=format==.BC7 && opaque(pixels)
            surface:=blocks.Surface{
                pixels=pixels,width=level.width,height=level.height,format=pixel,
            }
            result:=blocks.encode(formats[format],surface,options,out[layer*size:][:size],
                scratch,worker)
            if result!=.None {
                delete(out,allocator)
                return nil,.Out_Of_Memory if result==.Out_Of_Memory else .Invalid
            }
        }
        return out,.None
    }

    // Whether every texel of RGBA8 pixels is opaque.
    @(private="file")
    opaque :: proc(pixels:[]u8) -> bool {
        for i:=3;i<len(pixels);i+=4 {if pixels[i]!=255 {return false}}
        return true
    }

    // A job system of its own for the levels of a texture in blocks whose first
    // level is large, so a build in any thread uses every core; false for one
    // that goes in the calling thread.
    @(private)
    encode_jobs_begin :: proc(
        js:^jobs.Job_System,format:asset.Texture_Format,width,height:int,
    ) -> bool {
        #partial switch format {
        case .BC1,.BC5,.BC6H,.BC7: if width*height<PARALLEL_TEXELS {return false}
        case: return false
        }
        return jobs.system_init(js,{threads=jobs.THREADS_AUTO})
    }
}
