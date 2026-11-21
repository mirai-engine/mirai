package textures

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/jobs"

@(private="file")
Random :: struct {state:u64}

@(private="file")
next :: proc(r:^Random,below:int) -> int {
    r.state=r.state*6364136223846793005+1442695040888963407
    return int((r.state>>33)%u64(below))
}

@(test)
blocks_cover_any_size :: proc(t:^testing.T) {
    gpu:Gpu_Context
    if !test_gpu_context(t,&gpu) {return}
    defer gpu_context_destroy(&gpu)
    pixels:[5*3*4]u8
    for &b,i in pixels {b=u8(i*7)}
    for format in ([]asset.Texture_Format{.BC1,.BC5,.BC7}) {
        level:=rgba8(pixels[:],5,3)
        mips:[1][]u8
        error:=gpu_chain(&gpu,{level},mips[:],format,{rdo_lambda=-1},context.allocator)
        blocks:=mips[0]
        defer delete(blocks)
        testing.expect(t,error==.None && len(blocks)==asset.texture_level_size(format,5,3))
    }
    // One texel repeated over its block: both channels exact.
    mips:[1][]u8
    one_error:=gpu_chain(&gpu,{rgba8(pixels[:4],1,1)},mips[:],.BC5,{},context.allocator)
    if !testing.expect_value(t,one_error,Error.None) {return}
    one:=mips[0]
    defer delete(one)
    decoded:[4]u8
    testing.expect(t,asset.texture_level_rgba8(.BC5,one,1,1,decoded[:]) && decoded[0]==pixels[0] && decoded[1]==pixels[1])

    // A built texture has every level down to one texel, compressed or not.
    image:[8*4*4]u8
    for &b in image {b=255}
    built,error:=build(rgba8(image[:],8,4),{srgb=true},gpu=&gpu)
    defer built_destroy(&built)
    testing.expect(t,error==.None && built.format==.BC7 && .Srgb in built.flags && built.width==8 && built.height==4)
    testing.expect(t,len(built.mips)==4 && len(built.mips[0])==2*1*16 && len(built.mips[3])==16)
    data,_:=build(rgba8(image[:],8,4),{},gpu=&gpu)
    defer built_destroy(&data)
    testing.expect(t,data.format==.BC1 && len(data.mips[0])==2*1*8 && len(data.mips[3])==8)
    image[3]=0
    holed,_:=build(rgba8(image[:],8,4),{},gpu=&gpu)
    defer built_destroy(&holed)
    testing.expect(t,holed.format==.BC7 && .Srgb not_in holed.flags)
    normals,_:=build(rgba8(image[:],8,4),{normal_map=true},gpu=&gpu)
    defer built_destroy(&normals)
    plain_built,_:=build(rgba8(image[:],8,4),{encoding=.Uncompressed})
    defer built_destroy(&plain_built)
    testing.expect(t,normals.format==.BC5 && plain_built.format==.RGBA8 && len(plain_built.mips[0])==8*4*4)
    testing.expect(t,settings_hash({srgb=true})!=settings_hash({srgb=true,encoding=.Uncompressed}),"the encoding is a setting of the import")
}

@(private="file")
smooth_image :: proc(size:int,alpha:bool) -> []u8 {
    pixels:=make([]u8,size*size*4)
    quadrants:=[4][3]f32{{0.9,0.2,0.1},{0.1,0.8,0.2},{0.2,0.3,0.9},{0.6,0.6,0.6}}
    for y in 0..<size {
        for x in 0..<size {
            color:=quadrants[(y/(size/2))*2+x/(size/2)]*(0.8+0.2*f32((x+y)%(size/2))/f32(size/2))
            at:=(y*size+x)*4
            pixels[at],pixels[at+1],pixels[at+2]=u8(color.r*255),u8(color.g*255),u8(color.b*255)
            pixels[at+3]=u8(40+x*3) if alpha else 255
        }
    }
    return pixels
}

// What the file keeps of the blocks, saved with MDC2, and
// what the blocks keep of the image without RDO: the error RDO trades is the encoder's own.
@(test)
a_compressed_texture_survives_the_file_within_what_a_block_keeps :: proc(t:^testing.T) {
    gpu:Gpu_Context
    if !test_gpu_context(t,&gpu) {return}
    defer gpu_context_destroy(&gpu)
    SIZE :: 64
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    types.codecs=.Compressed
    folder:=base.test_folder(t,"bc")
    if folder=="" {return}
    cases:=[?]struct{name:string,options:Build_Options,alpha:bool,format:asset.Texture_Format,channels:int,tolerance:int}{
        {"color",{srgb=true,rdo_lambda=-1},false,.BC7,4,12},
        {"color with alpha",{srgb=true,rdo_lambda=-1},true,.BC7,4,12},
        {"data",{rdo_lambda=-1},false,.BC1,4,12},
        {"data with alpha",{rdo_lambda=-1},true,.BC7,4,12},
        {"normal map",{normal_map=true,rdo_lambda=-1},false,.BC5,2,6},
        {"plain",{srgb=true,encoding=.Uncompressed},true,.RGBA8,4,0},
    }
    for entry,index in cases {
        pixels:=smooth_image(SIZE,entry.alpha);defer delete(pixels)
        built,error:=build(rgba8(pixels,SIZE,SIZE),entry.options,gpu=&gpu)
        defer built_destroy(&built)
        testing.expect_value(t,error,Error.None)
        testing.expect_value(t,built.format,entry.format)
        again,_:=build(rgba8(pixels,SIZE,SIZE),entry.options,gpu=&gpu)
        defer built_destroy(&again)
        for level,i in built.mips {testing.expectf(t,string(level)==string(again.mips[i]),"%s: level %d is not the same in a second build",entry.name,i)}

        path:=fmt.tprintf("%s/%d.tex",folder,index)
        desc:=built_desc(&built,base.Asset_Id{9,u64(index)+1},nil)
        testing.expect_value(t,asset.texture_save(path,&types,desc),asset.Error.None)
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None) {continue}
        defer asset.asset_close(&a)
        view,view_error:=asset.texture_view(&a,&types)
        testing.expect_value(t,view_error,asset.Error.None)
        testing.expect(t,view.info.format==entry.format && int(view.info.mip_count)==asset.texture_mip_count(SIZE,SIZE) && view.info.width==SIZE)
        for level in 0..<int(view.info.mip_count) {
            testing.expectf(t,string(asset.texture_mip(view,level))==string(built.mips[level]),"%s: the file holds the built level %d",entry.name,level)
        }
        // The levels from the third, as a far texture reads them.
        far:asset.Asset
        if testing.expect_value(t,asset.asset_load(&far,path),asset.Error.None) {
            defer asset.asset_close(&far)
            tail,tail_error:=asset.texture_open(&far,&types)
            testing.expect(t,tail_error==.None && asset.texture_decode(&far,&types,&tail,2)==.None && tail.first==2)
            for level in 2..<int(view.info.mip_count) {
                testing.expectf(t,string(asset.texture_mip(tail,level))==string(built.mips[level]),"%s: a read from level 2 holds level %d",entry.name,level)
            }
        }

        // Each level against the one of the plain chain, away from the steps
        // between quadrants, where a block holds two ramps.
        plain_options:=entry.options
        plain_options.encoding=.Uncompressed
        plain,_:=build(rgba8(pixels,SIZE,SIZE),plain_options)
        defer built_destroy(&plain)
        for level in 0..<3 {
            side:=SIZE>>uint(level)
            decoded:=make([]u8,side*side*4);defer delete(decoded)
            testing.expect(t,asset.texture_level_rgba8(view.info.format,asset.texture_mip(view,level),side,side,decoded))
            half:=side/2
            edge:=4 if entry.format!=.RGBA8 else 0
            worst:=0
            for y in 0..<side {
                for x in 0..<side {
                    if x%half<edge || x%half>=half-edge || y%half<edge || y%half>=half-edge {continue}
                    at:=(y*side+x)*4
                    for channel in 0..<entry.channels {worst=max(worst,abs(int(decoded[at+channel])-int(plain.mips[level][at+channel])))}
                }
            }
            testing.expectf(t,worst<=entry.tolerance,"%s: level %d is off by %d",entry.name,level,worst)
        }
        testing.expect(t,!asset.texture_level_rgba8(view.info.format,asset.texture_mip(view,0),SIZE,SIZE,built.mips[1][:0]),"a slice of another size is refused")
    }
}

// Error of a level of RGBA8 pixels in dB, over its channels.
@(private="file")
psnr :: proc(format:asset.Texture_Format,blocks,pixels:[]u8,size,channels:int) -> f64 {
    decoded:=make([]u8,size*size*4,context.temp_allocator)
    asset.texture_level_rgba8(format,blocks,size,size,decoded)
    total:f64
    for i in 0..<size*size {
        for c in 0..<channels {
            d:=f64(decoded[i*4+c])-f64(pixels[i*4+c])
            total+=d*d
        }
    }
    return 10*math.log10(255*255/max(total/f64(size*size*channels),1e-10))
}

@(test)
the_rdo_lambda_trades_error_for_files_that_compress_smaller :: proc(t:^testing.T) {
    gpu:Gpu_Context
    if !test_gpu_context(t,&gpu) {return}
    defer gpu_context_destroy(&gpu)
    SIZE :: 128
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    types.codecs=.Compressed // the files a cook ships, which RDO makes smaller
    folder:=base.test_folder(t,"rdo")
    if folder=="" {return}
    pixels:=smooth_image(SIZE,true);defer delete(pixels)
    r:=Random{state=5}
    for &p in pixels {p=u8(clamp(int(p)+next(&r,9)-4,0,255))}
    file_bytes :: proc(t:^testing.T,types:^asset.Types,path:string,built:^Built) -> int {
        testing.expect_value(t,asset.texture_save(path,types,built_desc(built,base.Asset_Id{9,1},nil)),asset.Error.None)
        data,_:=os.read_entire_file(path,context.temp_allocator)
        return len(data)
    }
    for options in ([]Build_Options{{srgb=true},{}}) {
        exact,rdo,off:=options,options,options
        exact.rdo_lambda,rdo.rdo_lambda,off.rdo_lambda=-1,RDO_LAMBDA_DEFAULT,RDO_LAMBDA_MAX+1
        least,_:=build(rgba8(pixels,SIZE,SIZE),exact,gpu=&gpu);defer built_destroy(&least)
        traded,_:=build(rgba8(pixels,SIZE,SIZE),rdo,gpu=&gpu);defer built_destroy(&traded)
        path:=fmt.tprintf("%s/rdo.tex",folder)
        least_bytes,traded_bytes:=file_bytes(t,&types,path,&least),file_bytes(t,&types,path,&traded)
        testing.expectf(t,traded_bytes<least_bytes,"%v: RDO writes %d bytes and the least error %d",least.format,traded_bytes,least_bytes)
        least_db,traded_db:=psnr(least.format,least.mips[0],pixels,SIZE,4),psnr(least.format,traded.mips[0],pixels,SIZE,4)
        testing.expectf(t,least_db>=traded_db && traded_db>least_db-6,"%v: %.2f dB with RDO, %.2f without",least.format,traded_db,least_db)
        testing.expect(t,settings_hash(exact)!=settings_hash(rdo) && settings_hash(options)==settings_hash({srgb=options.srgb,rdo_lambda=RDO_LAMBDA_DEFAULT}),"the lambda is a setting of the import")
        _,refused:=build(rgba8(pixels,SIZE,SIZE),off)
        testing.expect_value(t,refused,Error.Invalid)
        // Fast: no RDO whatever the lambda, marked for the cook, and kept apart from Final.
        fast:=rdo
        fast.speed=.Fast
        quick,_:=build(rgba8(pixels,SIZE,SIZE),fast,gpu=&gpu);defer built_destroy(&quick)
        testing.expect(t,.Fast in quick.flags && .Fast not_in traded.flags && .Fast not_in least.flags)
        testing.expectf(t,file_bytes(t,&types,path,&quick)>traded_bytes,"%v: Fast is not traded for size",quick.format)
        testing.expect(t,settings_hash(fast)!=settings_hash(rdo) && settings_hash(fast)!=settings_hash(exact),"Fast is built and cached apart")
    }
}

@(test)
blocks_in_parallel_are_the_same_bytes :: proc(t:^testing.T) {
    gpu:Gpu_Context
    if !test_gpu_context(t,&gpu) {return}
    defer gpu_context_destroy(&gpu)
    SIZE :: 130 // not a multiple of four: the last blocks repeat the edge
    pixels:=make([]u8,SIZE*SIZE*4*2,context.temp_allocator)
    r:=Random{state=3}
    for &p,i in pixels {p=u8((i*7+next(&r,32))%256)}
    floats:=make([]u8,SIZE*SIZE*16,context.temp_allocator)
    linear:=transfer_make(false)
    for at in 0..<SIZE*SIZE {texel_write(floats,.RGBA32F,at,{f32(next(&r,1000))/50,f32(at%SIZE)/8,0.5,1},&linear)}
    js:jobs.Job_System
    testing.expect(t,jobs.system_init(&js,{threads=3}))
    defer jobs.system_destroy(&js)
    cases:=[?]struct{format:asset.Texture_Format,level:Source}{
        {.BC7,{texels=pixels,width=SIZE,height=SIZE,layers=2}},
        {.BC1,{texels=pixels,width=SIZE,height=SIZE,layers=2}},
        {.BC6H,{texels=floats,width=SIZE,height=SIZE,layers=1,format=.RGBA32F}},
    }
    for entry in cases {
        Work :: struct {
            gpu:^Gpu_Context, level:Source, format:asset.Texture_Format,
            mips:[4][]u8, errors:[4]Error,
        }
        work:=Work{gpu=&gpu,level=entry.level,format=entry.format}
        jobs.parallel_for(&js,jobs.OWNER,len(work.mips),1,
            proc(w:^Work,first,last,_:int) {
                for i in first..<last {
                    w.errors[i]=gpu_chain(w.gpu,{w.level},w.mips[i:][:1],w.format,{},
                        runtime.heap_allocator())
                }
            },&work)
        defer for blocks in work.mips {delete(blocks,runtime.heap_allocator())}
        for blocks,i in work.mips {
            testing.expect_value(t,work.errors[i],Error.None)
            testing.expect_value(t,len(blocks),
                asset.texture_level_size(entry.format,SIZE,SIZE)*max(entry.level.layers,1))
            testing.expectf(t,string(blocks)==string(work.mips[0]),
                "%v: blocks from other threads give the same bytes",entry.format)
        }
    }
}

@(test)
an_odd_sized_level_decodes_every_texel_of_its_last_blocks :: proc(t:^testing.T) {
    gpu:Gpu_Context
    if !test_gpu_context(t,&gpu) {return}
    defer gpu_context_destroy(&gpu)
    pixels:[5*3*4]u8
    for i in 0..<5*3 {pixels[i*4],pixels[i*4+1],pixels[i*4+2],pixels[i*4+3]=90,140,200,255}
    for format in ([]asset.Texture_Format{.BC1,.BC5,.BC7}) {
        mips:[1][]u8
        error:=gpu_chain(&gpu,{rgba8(pixels[:],5,3)},mips[:],format,{rdo_lambda=-1},context.allocator)
        if !testing.expect_value(t,error,Error.None) {continue}
        blocks:=mips[0]
        defer delete(blocks)
        decoded:[5*3*4]u8
        testing.expect(t,asset.texture_level_rgba8(format,blocks,5,3,decoded[:]))
        for i in 0..<5*3 {
            testing.expectf(t,abs(int(decoded[i*4])-90)<=4 && abs(int(decoded[i*4+1])-140)<=4 && decoded[i*4+3]==255,"%v texel %d is %v",format,i,decoded[i*4:i*4+4])
        }
    }
}

@(test)
a_bc7_texture_restores_its_tail_without_its_larger_levels :: proc(t:^testing.T) {
    gpu:Gpu_Context
    if !test_gpu_context(t,&gpu) {return}
    defer gpu_context_destroy(&gpu)
    SIZE :: 2*asset.TEXTURE_TAIL
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    types.codecs=.Compressed
    pixels:=smooth_image(SIZE,false);defer delete(pixels)
    built,error:=build(rgba8(pixels,SIZE,SIZE),{srgb=true,speed=.Fast},gpu=&gpu)
    defer built_destroy(&built)
    testing.expect(t,error==.None && built.format==.BC7)
    desc:=built_desc(&built,{9,99},nil)
    doc:asset.Document
    testing.expect_value(t,asset.texture_document(&doc,&types,desc),asset.Error.None)
    bytes,bytes_error:=asset.document_bytes(&doc,context.temp_allocator)
    asset.document_destroy(&doc)
    testing.expect_value(t,bytes_error,asset.Error.None)
    for from in 0..<len(built.mips) {
        a:asset.Asset
        testing.expect_value(t,asset.asset_open(&a,bytes),asset.Error.None)
        view,view_error:=asset.texture_open(&a,&types)
        testing.expect(t,view_error==.None && asset.texture_decode(&a,&types,&view,from)==.None)
        testing.expectf(t,view.first==from,"a read from level %d restores from level %d",from,view.first)
        testing.expect(t,view.first==0 || asset.texture_mip(view,0)==nil)
        for level in view.first..<len(built.mips) {testing.expectf(t,string(asset.texture_mip(view,level))==string(built.mips[level]),"level %d read from %d",level,from)}
        if from+1<len(built.mips) {
            testing.expect_value(t,asset.texture_decode(&a,&types,&view,from,from+1),asset.Error.None)
            testing.expect(t,asset.texture_check(view) && asset.texture_mip(view,from+1)==nil)
            testing.expect(t,string(asset.texture_mip(view,from))==string(built.mips[from]))
        }
        asset.asset_close(&a)
    }
    free_all(context.temp_allocator)
}
