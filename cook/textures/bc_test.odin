package textures

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
    pixels:[5*3*4]u8
    for &b,i in pixels {b=u8(i*7)}
    transfer:=transfer_make(false)
    for format in ([]asset.Texture_Format{.BC1,.BC3,.BC5,.BC7}) {
        blocks,error:=level_store(rgba8(pixels[:],5,3),format,&transfer,{lambda=RDO_LAMBDA_DEFAULT},context.allocator,{})
        defer delete(blocks)
        testing.expect(t,error==.None && len(blocks)==asset.texture_level_size(format,5,3))
    }
    // One texel repeated over its block: both channels exact.
    one,_:=level_store(rgba8(pixels[:4],1,1),.BC5,&transfer,{lambda=RDO_LAMBDA_DEFAULT},context.allocator,{})
    defer delete(one)
    decoded:[4]u8
    testing.expect(t,asset.texture_level_rgba8(.BC5,one,1,1,decoded[:]) && decoded[0]==pixels[0] && decoded[1]==pixels[1])

    // A built texture has every level down to one texel, compressed or not.
    image:[16*8*4]u8
    for &b in image {b=255}
    built,error:=build(rgba8(image[:],16,8),{max_size=8,srgb=true})
    defer built_destroy(&built)
    testing.expect(t,error==.None && built.format==.BC7 && .Srgb in built.flags && built.width==8 && built.height==4)
    testing.expect(t,len(built.mips)==4 && len(built.mips[0])==2*1*16 && len(built.mips[3])==16)
    data,_:=build(rgba8(image[:],16,8),{max_size=8})
    defer built_destroy(&data)
    testing.expect(t,data.format==.BC1 && len(data.mips[0])==2*1*8 && len(data.mips[3])==8)
    image[3]=0
    holed,_:=build(rgba8(image[:],16,8),{max_size=64})
    defer built_destroy(&holed)
    testing.expect_value(t,holed.format,asset.Texture_Format.BC3)
    normals,_:=build(rgba8(image[:],16,8),{max_size=64,normal_map=true})
    defer built_destroy(&normals)
    plain_built,_:=build(rgba8(image[:],16,8),{max_size=64,encoding=.Uncompressed})
    defer built_destroy(&plain_built)
    testing.expect(t,normals.format==.BC5 && plain_built.format==.RGBA8 && len(plain_built.mips[0])==16*8*4)
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

// What the file keeps of the blocks, saved with the best codecs and the layouts they have, and
// what the blocks keep of the image without RDO: the error RDO trades is the encoder's own.
@(test)
a_compressed_texture_survives_the_file_within_what_a_block_keeps :: proc(t:^testing.T) {
    SIZE :: 64
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    types.codecs=.Best
    folder:=base.test_folder(t,"bc")
    if folder=="" {return}
    cases:=[?]struct{name:string,options:Build_Options,alpha:bool,format:asset.Texture_Format,channels:int,tolerance:int}{
        {"color",{srgb=true,rdo_lambda=-1},false,.BC7,4,12},
        {"color with alpha",{srgb=true,rdo_lambda=-1},true,.BC7,4,12},
        {"data",{rdo_lambda=-1},false,.BC1,4,12},
        {"data with alpha",{rdo_lambda=-1},true,.BC3,4,12},
        {"normal map",{normal_map=true,rdo_lambda=-1},false,.BC5,2,6},
        {"plain",{srgb=true,encoding=.Uncompressed},true,.RGBA8,4,0},
    }
    for entry,index in cases {
        pixels:=smooth_image(SIZE,entry.alpha);defer delete(pixels)
        built,error:=build(rgba8(pixels,SIZE,SIZE),entry.options)
        defer built_destroy(&built)
        testing.expect_value(t,error,Error.None)
        testing.expect_value(t,built.format,entry.format)
        again,_:=build(rgba8(pixels,SIZE,SIZE),entry.options)
        defer built_destroy(&again)
        for level,i in built.mips {testing.expectf(t,string(level)==string(again.mips[i]),"%s: level %d is not the same in a second build",entry.name,i)}

        path:=fmt.tprintf("%s/%d.tex",folder,index)
        desc:=built_desc(&built,base.Asset_Id{9,u64(index)+1},nil,layouts=true)
        testing.expect_value(t,asset.texture_save(path,&types,desc),asset.Error.None)
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None) {continue}
        defer asset.asset_close(&a)
        view,view_error:=asset.texture_view(&a,&types)
        testing.expect_value(t,view_error,asset.Error.None)
        testing.expect(t,view.info.format==entry.format && int(view.info.mip_count)==asset.texture_mip_count(SIZE,SIZE) && view.info.width==SIZE)
        for level in 0..<int(view.info.mip_count) {
            side:=max(SIZE>>uint(level),1)
            testing.expectf(t,same_level(entry.format,asset.texture_mip(view,level),built.mips[level],side,side),"%s: the file holds the built level %d",entry.name,level)
        }
        _,laid:=asset.asset_table(&a,asset.TEXTURE_TABLE_LAYOUTS)
        testing.expectf(t,laid==(len(desc.layouts)>0),"%s: the file keeps the layouts of its blocks",entry.name)
        // The levels from the third, as a far texture reads them: all of the tail for a layout,
        // which restores whole.
        far:asset.Asset
        if testing.expect_value(t,asset.asset_load(&far,path),asset.Error.None) {
            defer asset.asset_close(&far)
            tail,tail_error:=asset.texture_open(&far,&types)
            testing.expect(t,tail_error==.None && asset.texture_decode(&far,&types,&tail,2)==.None && tail.first==(0 if laid else 2))
            for level in 2..<int(view.info.mip_count) {
                side:=max(SIZE>>uint(level),1)
                testing.expectf(t,same_level(entry.format,asset.texture_mip(tail,level),built.mips[level],side,side),"%s: a read from level 2 holds level %d",entry.name,level)
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
    SIZE :: 128
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
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
        exact.rdo_lambda,rdo.rdo_lambda,off.rdo_lambda=-1,40,RDO_LAMBDA_MAX+1
        least,_:=build(rgba8(pixels,SIZE,SIZE),exact);defer built_destroy(&least)
        traded,_:=build(rgba8(pixels,SIZE,SIZE),rdo);defer built_destroy(&traded)
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
        quick,_:=build(rgba8(pixels,SIZE,SIZE),fast);defer built_destroy(&quick)
        testing.expect(t,.Fast in quick.flags && .Fast not_in traded.flags && .Fast not_in least.flags)
        testing.expectf(t,file_bytes(t,&types,path,&quick)>traded_bytes,"%v: Fast is not traded for size",quick.format)
        testing.expect(t,settings_hash(fast)!=settings_hash(rdo) && settings_hash(fast)!=settings_hash(exact),"Fast is built and cached apart")
    }
}

@(test)
blocks_in_parallel_are_the_same_bytes :: proc(t:^testing.T) {
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
        {.BC6H,{texels=floats,width=SIZE,height=SIZE,format=.RGBA32F}},
    }
    for entry in cases {
        serial,serial_error:=level_store(entry.level,entry.format,&linear,{lambda=RDO_LAMBDA_DEFAULT},context.temp_allocator,{})
        parallel,parallel_error:=level_store(entry.level,entry.format,&linear,{lambda=RDO_LAMBDA_DEFAULT},context.temp_allocator,{&js,jobs.OWNER,nil})
        testing.expect(t,serial_error==.None && parallel_error==.None && len(serial)==asset.texture_level_size(entry.format,SIZE,SIZE)*max(entry.level.layers,1))
        testing.expectf(t,string(serial)==string(parallel),"%v: blocks in other threads give the same bytes",entry.format)
    }
}

@(test)
color_is_bc7_data_maps_bc1_or_bc3_and_hdr_bc6h :: proc(t:^testing.T) {
    opaque:=[]u8{10,20,30,255,40,50,60,255}
    cutout:=[]u8{10,20,30,255,40,50,60,0}
    stored :: proc(texels:[]u8,format:Source_Format,options:Build_Options) -> asset.Texture_Format {
        return stored_format({texels=texels,width=2,height=1,format=format},options)
    }
    testing.expect_value(t,stored(opaque,.RGBA8,{srgb=true}),asset.Texture_Format.BC7)
    testing.expect_value(t,stored(cutout,.RGBA8,{srgb=true}),asset.Texture_Format.BC7)
    testing.expect_value(t,stored(opaque,.RGBA8,{}),asset.Texture_Format.BC1)
    testing.expect_value(t,stored(cutout,.RGBA8,{}),asset.Texture_Format.BC3)
    testing.expect_value(t,stored(cutout,.RGBA8,{srgb=true,normal_map=true}),asset.Texture_Format.BC5)
    testing.expect_value(t,stored(opaque,.RGBA8,{srgb=true,keep_precision=true}),asset.Texture_Format.BC7)
    testing.expect_value(t,stored(opaque,.RGBA8,{encoding=.Uncompressed}),asset.Texture_Format.RGBA8)

    floats :: proc(values:[2][4]f32) -> []u8 {
        texels:=make([]u8,32,context.temp_allocator)
        linear:=transfer_make(false)
        for value,at in values {texel_write(texels,.RGBA32F,at,value,&linear)}
        return texels
    }
    bright:=floats({{40,2,0.5,1},{0,0,0,1}})
    testing.expect_value(t,stored(bright,.RGBA32F,{srgb=true}),asset.Texture_Format.BC6H)
    testing.expect_value(t,stored(floats({{40,2,0.5,0.5},{0,0,0,1}}),.RGBA32F,{}),asset.Texture_Format.RGBA16F)
    testing.expect_value(t,stored(floats({{40,-2,0.5,1},{0,0,0,1}}),.RGBA32F,{}),asset.Texture_Format.RGBA16F)
    testing.expect_value(t,stored(bright,.RGBA32F,{keep_precision=true}),asset.Texture_Format.RGBA16F)
    testing.expect_value(t,stored(bright,.RGBA32F,{normal_map=true}),asset.Texture_Format.BC5)
    wide:=make([]u8,16,context.temp_allocator)
    for &b in wide {b=0xff}
    testing.expect_value(t,stored(wide,.RGBA16,{}),asset.Texture_Format.BC1)
    testing.expect_value(t,stored(wide,.RGBA16,{keep_precision=true}),asset.Texture_Format.RGBA16)
    testing.expect_value(t,stored(wide,.RGBA16,{encoding=.Uncompressed}),asset.Texture_Format.RGBA16)
}

@(test)
an_odd_sized_level_decodes_every_texel_of_its_last_blocks :: proc(t:^testing.T) {
    pixels:[5*3*4]u8
    for i in 0..<5*3 {pixels[i*4],pixels[i*4+1],pixels[i*4+2],pixels[i*4+3]=90,140,200,255}
    transfer:=transfer_make(false)
    for format in ([]asset.Texture_Format{.BC1,.BC3,.BC5,.BC7}) {
        blocks,_:=level_store(rgba8(pixels[:],5,3),format,&transfer,{lambda=RDO_LAMBDA_DEFAULT},context.allocator,{});defer delete(blocks)
        decoded:[5*3*4]u8
        testing.expect(t,asset.texture_level_rgba8(format,blocks,5,3,decoded[:]))
        for i in 0..<5*3 {
            testing.expectf(t,abs(int(decoded[i*4])-90)<=4 && abs(int(decoded[i*4+1])-140)<=4 && decoded[i*4+3]==255,"%v texel %d is %v",format,i,decoded[i*4:i*4+4])
        }
    }
}

// A level as a file gives it back: the same bytes, and for BC7 the same
// texels, as a layout may restore a solid block as another block of its texels.
@(private)
same_level :: proc(format:asset.Texture_Format,a,b:[]u8,width,height:int) -> bool {
    if format!=.BC7 {return string(a)==string(b)}
    if len(a)!=len(b) {return false}
    pa:=make([]u8,width*height*4,context.temp_allocator)
    pb:=make([]u8,width*height*4,context.temp_allocator)
    return asset.texture_level_rgba8(format,a,width,height,pa) && asset.texture_level_rgba8(format,b,width,height,pb) && string(pa)==string(pb)
}

// Of a compressor with layouts of BC7 blocks: the tail restores without the larger levels.
@(test)
a_bc7_texture_restores_its_tail_without_its_larger_levels :: proc(t:^testing.T) {
    SIZE :: 2*asset.TEXTURE_TAIL
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    types.codecs=.Best
    pixels:=smooth_image(SIZE,false);defer delete(pixels)
    built,error:=build(rgba8(pixels,SIZE,SIZE),{srgb=true,speed=.Fast})
    defer built_destroy(&built)
    testing.expect(t,error==.None && built.format==.BC7)
    desc:=built_desc(&built,{9,99},nil,layouts=true)
    if len(desc.layouts)==0 {return}
    testing.expect(t,len(desc.layouts)==2 && desc.layouts[0].level==0 && desc.layouts[1].level==1,"the level above the tail and the tail, apart")
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
        testing.expectf(t,view.first==min(from,1),"a read from level %d restores from level %d",from,view.first)
        testing.expect(t,view.first==0 || asset.texture_mip(view,0)==nil)
        for level in view.first..<len(built.mips) {testing.expectf(t,string(asset.texture_mip(view,level))==string(built.mips[level]),"level %d read from %d",level,from)}
        asset.asset_close(&a)
    }
    free_all(context.temp_allocator)
}
