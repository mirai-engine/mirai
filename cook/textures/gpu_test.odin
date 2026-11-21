package textures

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:testing"
import "core:time"
import data "compressor_open:data"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"
import "mirai:rhi"
import "mirai:rhi/shared_device"

@(test)
gpu_blocks_decode_and_keep_alpha_coverage :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t)
    if device==nil {return}
    gpu:Gpu_Context
    root,_:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !testing.expect_value(t,gpu_context_init(&gpu,device,root),Error.None) {return}
    defer gpu_context_destroy(&gpu)

    W :: 69
    H :: 11
    rgba:[W*H*4]u8
    hdr:[W*H*4]f32
    for y in 0..<H do for x in 0..<W {
        i:=4*(y*W+x)
        rgba[i+0]=u8(100+x%9*5+y*3)
        rgba[i+1]=u8(110+x%11*4-y*2)
        rgba[i+2]=u8(120+x%5*8+y*5)
        rgba[i+3]=255
        hdr[i+0]=0.6+f32(x%9)*0.2
        hdr[i+1]=2+f32(x%5)*0.3+f32(y)*0.2
        hdr[i+2]=0.1+f32(y)*0.2
        hdr[i+3]=1
    }
    source:=rgba8(rgba[:],W,H)
    half:=Source{width=W,height=H,layers=1,format=.RGBA16F}
    linear:=transfer_make(false)
    half.texels=make([]u8,W*H*8,context.temp_allocator)
    for i in 0..<W*H {
        value:[4]f32
        copy(value[:],hdr[4*i:][:4])
        texel_write(half.texels,.RGBA16F,i,value,&linear)
    }
    full:=Source{width=W,height=H,layers=1,format=.RGBA32F,
        texels=mem.slice_to_bytes(hdr[:])}
    Case :: struct {format:asset.Texture_Format, options:Build_Options, source:Source}
    cases:=[5]Case{
        {.BC1,{},source},
        {.BC5,{normal_map=true},source},
        {.BC6H,{},half},
        {.BC6H,{},full},
        {.BC7,{srgb=true,alpha_coverage=0.5},source},
    }
    for entry in cases {
        for speed in ([2]Encode_Speed{.Fast,.Final}) {
            if entry.format==.BC7 {
                alpha:=[6]u8{0,18,126,128,230,255}
                for i in 0..<W*H {rgba[4*i+3]=alpha[(i+i/W*3)%len(alpha)]}
            }
            options:=entry.options
            options.speed=speed
            reference:Built
            if entry.format==.BC7 {
                raw:=options
                raw.encoding=.Uncompressed
                raw_error:Error
                reference,raw_error=build(entry.source,raw)
                if !testing.expect_value(t,raw_error,Error.None) {continue}
            }
            defer built_destroy(&reference)
            built,err:=build(entry.source,options,context.temp_allocator,gpu=&gpu)
            if !testing.expectf(t,err==.None,"%v %v: %v %s",
                entry.format,speed,err,rhi.device_error(device)) {continue}
            defer built_destroy(&built)
            if !testing.expect_value(t,built.format,entry.format) {continue}
            for bytes,level in built.mips {
                w,h:=max(W>>uint(level),1),max(H>>uint(level),1)
                if entry.format==.BC6H {
                    out:=make([]u8,w*h*8,context.temp_allocator)
                    if !testing.expect(t,asset.texture_level_rgba16f(.BC6H,bytes,w,h,out)) {
                        continue
                    }
                    for i in 0..<w*h {
                        value:=texel_read(out,.RGBA16F,i,&linear)
                        if !testing.expect(t,value.g>1 && value.g<7 && value.a==1) {break}
                    }
                    if level==0 {
                        quality:=demo_quality(t,entry.source,&built)
                        testing.expectf(t,quality>28,"%v %v PSNR %.2f",
                            entry.source.format,speed,quality)
                    }
                    continue
                }
                out:=make([]u8,w*h*4,context.temp_allocator)
                if !testing.expect(t,asset.texture_level_rgba8(entry.format,bytes,w,h,out)) {
                    continue
                }
                if entry.format==.BC7 {
                    raw:=reference.mips[level]
                    for i in 0..<w*h {
                        a,b:=raw[4*i+3],out[4*i+3]
                        if !testing.expectf(t,(a>=128)==(b>=128) &&
                            ((a>0 && a<255) || a==b),
                            "%v level %d texel %d: alpha %d decoded as %d",
                            speed,level,i,a,b) {break}
                    }
                }
                if level!=0 {continue}
                limit:=3
                if entry.format==.BC5 {limit=2}
                sum:f64
                for i in 0..<w*h {
                    for channel in 0..<limit {
                        d:=f64(rgba[4*i+channel])-f64(out[4*i+channel])
                        sum+=d*d
                    }
                    if entry.format!=.BC7 &&
                        !testing.expect_value(t,out[4*i+3],u8(255)) {break}
                }
                psnr:=10*math.log10(f64(w*h*limit)*255*255/max(sum,1))
                testing.expectf(t,psnr>27,"%v %v PSNR %.2f",entry.format,speed,psnr)
            }
        }
    }
}

@(test)
gpu_tile_reuses_blocks_in_final_cooks :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t)
    if device==nil {return}
    gpu:Gpu_Context
    root,_:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !testing.expect_value(t,gpu_context_init(&gpu,device,root),Error.None) {return}
    defer gpu_context_destroy(&gpu)
    W :: 128
    H :: 4
    pixels:[W*H*4]u8
    for y in 0..<H do for x in 0..<W {
        i:=4*(y*W+x)
        shift:=x/4
        pixels[i+0]=u8(120+shift+8*(y%4))
        pixels[i+1]=u8(90+shift+8*(y%4))
        pixels[i+2]=u8(80+shift+8*(y%4))
        pixels[i+3]=255
    }
    source:=rgba8(pixels[:],W,H)
    base,base_error:=build(source,{srgb=true,rdo_lambda=-1},gpu=&gpu)
    if !testing.expect_value(t,base_error,Error.None) {return}
    defer built_destroy(&base)
    final,final_error:=build(source,{srgb=true,rdo_lambda=100},gpu=&gpu)
    if !testing.expect_value(t,final_error,Error.None) {return}
    defer built_destroy(&final)
    unique :: proc(blocks:[]u8) -> int {
        seen:=make(map[[16]u8]bool,context.temp_allocator)
        for at:=0;at<len(blocks);at+=16 {
            key:[16]u8
            copy(key[:],blocks[at:][:16])
            seen[key]=true
        }
        return len(seen)
    }
    testing.expectf(t,unique(final.mips[0])<unique(base.mips[0]),
        "rate optimization should reuse block contents: %d against %d unique blocks",
        unique(final.mips[0]),unique(base.mips[0]))
    out: [W*H*4]u8
    if testing.expect(t,asset.texture_level_rgba8(.BC7,final.mips[0],W,H,out[:])) {
        for i in 0..<W*H {
            if !testing.expect_value(t,out[4*i+3],u8(255)) {break}
        }
    }
}

GPU_BENCH :: #config(COOK_GPU_BENCH,false)

@(test)
bench_gpu_blocks_on_demo_textures :: proc(t:^testing.T) {
    if !GPU_BENCH {return}
    device:=shared_device.take_or_skip(t)
    if device==nil {return}
    root,_:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    gpu:Gpu_Context
    if !testing.expect_value(t,gpu_context_init(&gpu,device,root),Error.None) {return}
    defer gpu_context_destroy(&gpu)

    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    types.codecs=.Open
    Case :: struct {path:string,options:Build_Options}
    cases:=[5]Case{
        {"surfaces/bricks/bricks_color.png",{srgb=true}},
        {"forest/leaves_color.png",{srgb=true,alpha_coverage=0.5}},
        {"surfaces/cobblestone/cobblestone_color.png",{}},
        {"surfaces/cobblestone/cobblestone_normal.png",{normal_map=true}},
        {"sky/sky_day.hdr",{}},
    }
    fmt.println("image,format,width,height,speed,encoder,mip_ms,quality,zstd_tex,mdc1_tex")
    for entry in cases {
        image:=project.path(root,"demo/assets",entry.path,allocator=context.temp_allocator)
        bytes,read_error:=os.read_entire_file(image,context.allocator)
        if !testing.expect(t,read_error==nil,image) {continue}
        source,error:=source_decode(bytes)
        delete(bytes)
        if !testing.expect_value(t,error,Error.None) {continue}
        defer source_destroy(&source)
        for speed in ([2]Encode_Speed{.Fast,.Final}) {
            options:=entry.options
            options.speed=speed
            format:=stored_format(source,options)
            if !testing.expect(t,gpu_pipeline(&gpu,format,.Encode)!=0,
                rhi.device_error(device)) {continue}
            if speed==.Final {
                if !testing.expect(t,gpu_pipeline(&gpu,format,.Rdo)!=0,
                    rhi.device_error(device)) {continue}
            }
            for encoder in ([2]string{"cpu","gpu"}) {
                use:=&gpu if encoder=="gpu" else nil
                started:=time.tick_now()
                built,build_error:=build(source,options,gpu=use)
                elapsed:=time.duration_milliseconds(time.tick_since(started))
                if !testing.expectf(t,build_error==.None,"%s %s: %v %s",
                    entry.path,encoder,build_error,rhi.device_error(device)) {continue}
                quality:=demo_quality(t,source,&built)
                zstd,mdc:=demo_tex_sizes(t,&types,&built)
                fmt.printfln("%s,%v,%d,%d,%v,%s,%.3f,%.4f,%d,%d",
                    entry.path,format,source.width,source.height,speed,encoder,
                    elapsed,quality,zstd,mdc)
                built_destroy(&built)
            }
        }
    }
}

@(private="file")
demo_quality :: proc(t:^testing.T,source:Source,built:^Built) -> f64 {
    w,h:=source.width,source.height
    a:=context.allocator
    channels:=3
    texel:=4
    if built.format==.BC7 {channels=4}
    if built.format==.BC6H {texel=8}
    decoded:=make([]u8,w*h*texel,a)
    defer delete(decoded,a)
    if built.format==.BC6H {
        if !testing.expect(t,asset.texture_level_rgba16f(.BC6H,built.mips[0],w,h,decoded)) {
            return 0
        }
        linear:=transfer_make(false)
        e,peak:f64
        for i in 0..<w*h {
            s:=texel_read(source.texels,source.format,i,&linear)
            d:=texel_read(decoded,.RGBA16F,i,&linear)
            for c in 0..<3 {
                value:=math.log2(1+max(f64(s[c]),0))
                q:=value-math.log2(1+max(f64(d[c]),0))
                peak=max(peak,value)
                e+=q*q
            }
        }
        return 10*math.log10(peak*peak*f64(w*h*3)/e)
    }
    if !testing.expect(t,asset.texture_level_rgba8(built.format,built.mips[0],w,h,decoded)) {
        return 0
    }
    e:f64
    for i in 0..<w*h {
        s,d:=source.texels[4*i:],decoded[4*i:]
        if built.format==.BC5 {
            normal :: proc(p:[]u8) -> [3]f64 {
                x,y:=2*f64(p[0])/255-1,2*f64(p[1])/255-1
                z2:=1-x*x-y*y
                if z2>=0 {return {x,y,math.sqrt(z2)}}
                length:=math.sqrt(1-z2)
                return {x/length,y/length,0}
            }
            v:=normal(s)*normal(d)
            angle:=math.acos(clamp(v.x+v.y+v.z,-1,1))
            e+=angle*angle
        } else {
            for c in 0..<channels {
                difference:=f64(s[c])-f64(d[c])
                e+=difference*difference
            }
        }
    }
    if built.format==.BC5 {return math.sqrt(e/f64(w*h))*180/math.PI}
    return 10*math.log10(255*255*f64(w*h*channels)/e)
}

@(private="file")
demo_tex_sizes :: proc(t:^testing.T,types:^asset.Types,built:^Built) -> (zstd,mdc1:int) {
    a:=context.allocator
    doc:asset.Document
    if !testing.expect_value(t,asset.texture_document(&doc,types,
        built_desc(built,base.Asset_Id{7,1},nil)),asset.Error.None) {return}
    defer asset.document_destroy(&doc)
    file,error:=asset.document_bytes(&doc)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    defer delete(file)
    blob,open_error:=asset.blob_open(file)
    if !testing.expect_value(t,open_error,asset.Error.None) {return}
    zstd=len(file)
    mdc1=zstd
    // The texel column is the last chunk and the only one eligible for compression.
    // Substitute an MDC1 stream in the same layout, including its piece directory.
    chunk:=asset.blob_chunk(&blob,int(blob.header.chunk_count)-1)
    raw:[]u8
    for table in doc.tables {
        if table.name=="texels" {raw=table.columns[0].data[:];break}
    }
    if !testing.expect(t,chunk.uncompressed_size==u64(len(raw))) {return}
    scratch:=make([]u8,data.bound(min(len(raw),asset.PACK_PIECE)),a)
    defer delete(scratch,a)
    encoder:data.Encoder
    if !testing.expect_value(t,data.encoder_init(&encoder,a),data.Error.None) {return}
    defer data.encoder_destroy(&encoder)
    pieces:=max(1,(len(raw)+asset.PACK_PIECE-1)/asset.PACK_PIECE)
    size:=size_of(u8)+size_of(u32)*(2+pieces)
    for at:=0;at<len(raw);at+=asset.PACK_PIECE {
        written,encode_error:=data.encode_mdc1(&encoder,.Fast,
            raw[at:min(at+asset.PACK_PIECE,len(raw))],scratch)
        if !testing.expect_value(t,encode_error,data.Error.None) {return}
        size+=written
    }
    mdc1=zstd-int(chunk.size)+min(size,len(raw))
    return
}
