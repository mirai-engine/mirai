package textures

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import stbi "vendor:stb/image"
import "compressor:blocks"
import "compressor:texture"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

// Source texels to .tex records: decoding, the mip chain of every layer and
// what the renderer expects of each level, stored by what the texture is used
// for and by what its source holds (stored_format), block compressed by the
// collection compressor (compressor:blocks) unless the import asks for it
// uncompressed.

MAX_SOURCE_SIDE :: 1<<15
MAX_SOURCE_PIXELS :: 1<<28
// Changes when build would give other bytes for the same image and options.
BUILD_VERSION :: 6
RDO_LAMBDA_DEFAULT :: 30
RDO_LAMBDA_MAX :: 100
// Texels of a level from which build encodes its blocks on a job system of
// its own, when the caller gives none.
PARALLEL_TEXELS :: 128*128

Error :: enum u8 {
    None,
    Unsupported, // not an image stb can decode
    Too_Large,   // a side above asset.TEXTURE_MAX_SIZE
    Out_Of_Memory,
    Invalid,     // texels that do not fill the size and layers they claim
}

// An image as RGBA8 rows from the top, whatever the file holds: what the
// importers look at.
Image :: struct {
    pixels:[]u8, // RGBA8, rows from the top
    width,height:int,
    allocator:mem.Allocator,
}

image_destroy :: proc(image:^Image) {
    delete(image.pixels,image.allocator)
    image^={}
}

image_decode :: proc(bytes:[]u8,allocator:=context.allocator) -> (image:Image,error:Error) {
    x,y:=image_size(bytes) or_return
    decoded:=stbi.load_from_memory(raw_data(bytes),c.int(len(bytes)),&x,&y,nil,4)
    if decoded==nil {return {},.Unsupported}
    defer stbi.image_free(decoded)
    count:=int(x)*int(y)*4
    pixels,alloc_error:=make([]u8,count,allocator)
    if alloc_error!=nil {return {},.Out_Of_Memory}
    copy(pixels,decoded[:count])
    return {pixels=pixels,width=int(x),height=int(y),allocator=allocator},.None
}

@(private="file")
image_size :: proc(bytes:[]u8) -> (x,y:c.int,error:Error) {
    if len(bytes)==0 || len(bytes)>int(max(c.int)) {return 0,0,.Unsupported}
    components:c.int
    if stbi.info_from_memory(raw_data(bytes),c.int(len(bytes)),&x,&y,&components)==0 {return 0,0,.Unsupported}
    if x<=0 || y<=0 || int(x)>MAX_SOURCE_SIDE || int(y)>MAX_SOURCE_SIDE || int(x)*int(y)>MAX_SOURCE_PIXELS {return 0,0,.Too_Large}
    return
}

// What the texels of a source hold, each texel RGBA.
Source_Format :: enum u8 {
    RGBA8,   // under Build_Options.srgb, the sRGB curve; else linear
    RGBA16,  // the same, in 16 bits
    RGBA16F, // linear half floats: HDR
    RGBA32F, // linear floats: HDR
}

SOURCE_TEXEL_BYTES :: [Source_Format]int{.RGBA8=4,.RGBA16=8,.RGBA16F=8,.RGBA32F=16}

// Texels a texture is built from.
Source :: struct {
    texels:[]u8, // rows from the top, image after image
    width,height:int,
    layers:int,  // images: 0 or 1 for one, those of an array, or six per cube
    format:Source_Format,
    cube:bool,   // its images are faces of cubes, as asset.Texture_Flag.Cube orders and turns them
    allocator:mem.Allocator, // of texels, when the source owns them
}

source_destroy :: proc(source:^Source) {
    if source.allocator.procedure!=nil {delete(source.texels,source.allocator)}
    source^={}
}

// The source of RGBA8 pixels, rows from the top, that it does not own.
rgba8 :: proc "contextless" (pixels:[]u8,width,height:int) -> Source {
    return {texels=pixels,width=width,height=height,layers=1}
}

// Bytes the texels of a source hold.
source_bytes :: proc "contextless" (source:Source) -> int {
    sizes:=SOURCE_TEXEL_BYTES
    return source.width*source.height*max(source.layers,1)*sizes[source.format]
}

// Float texels: values of light, above 1 too.
source_hdr :: proc "contextless" (format:Source_Format) -> bool {return format==.RGBA16F || format==.RGBA32F}

// The texels of an image file: a Radiance .hdr as RGBA32F, a PNG of 16 bits
// per channel as RGBA16, any other image stb decodes as RGBA8.
source_decode :: proc(bytes:[]u8,allocator:=context.allocator) -> (source:Source,error:Error) {
    x,y:=image_size(bytes) or_return
    size:=c.int(len(bytes))
    format:Source_Format
    raw:rawptr
    switch {
    case stbi.is_hdr_from_memory(raw_data(bytes),size)!=0:
        format,raw=.RGBA32F,stbi.loadf_from_memory(raw_data(bytes),size,&x,&y,nil,4)
    case stbi.is_16_bit_from_memory(raw_data(bytes),size)!=0:
        format,raw=.RGBA16,stbi.load_16_from_memory(raw_data(bytes),size,&x,&y,nil,4)
    case:
        format,raw=.RGBA8,stbi.load_from_memory(raw_data(bytes),size,&x,&y,nil,4)
    }
    if raw==nil {return {},.Unsupported}
    defer stbi.image_free(raw)
    source={width=int(x),height=int(y),layers=1,format=format,allocator=allocator}
    alloc_error:mem.Allocator_Error
    source.texels,alloc_error=make([]u8,source_bytes(source),allocator)
    if alloc_error!=nil {return {},.Out_Of_Memory}
    copy(source.texels,([^]u8)(raw)[:len(source.texels)])
    return source,.None
}

// Whether an image file holds more than 8 bits per channel: what source_decode
// keeps and image_decode rounds.
source_wide :: proc(bytes:[]u8) -> bool {
    if len(bytes)==0 || len(bytes)>int(max(c.int)) {return false}
    size:=c.int(len(bytes))
    return stbi.is_hdr_from_memory(raw_data(bytes),size)!=0 || stbi.is_16_bit_from_memory(raw_data(bytes),size)!=0
}

// How the texels of a format of a source become linear values: the sRGB
// curve of 8 and 16 bits under srgb.
Transfer :: struct {
    srgb:bool,
    table:[256]f32, // of each 8-bit value
}

transfer_make :: proc "contextless" (srgb:bool) -> (transfer:Transfer) {
    transfer.srgb=srgb
    for &value,i in transfer.table {
        value=f32(i)/255
        if srgb {value=mm.srgb_to_linear(value)}
    }
    return
}

// The linear value of texel `at`.
texel_read :: proc "contextless" (texels:[]u8,format:Source_Format,at:int,transfer:^Transfer) -> (value:[4]f32) #no_bounds_check {
    switch format {
    case .RGBA8:
        t:=texels[at*4:]
        return {transfer.table[t[0]],transfer.table[t[1]],transfer.table[t[2]],f32(t[3])/255}
    case .RGBA16:
        for c in 0..<4 {value[c]=f32(u16(texels[at*8+c*2])|u16(texels[at*8+c*2+1])<<8)/65535}
        if transfer.srgb {value.rgb={mm.srgb_to_linear(value.r),mm.srgb_to_linear(value.g),mm.srgb_to_linear(value.b)}}
    case .RGBA16F:
        for c in 0..<4 {value[c]=f32(transmute(f16)(u16(texels[at*8+c*2])|u16(texels[at*8+c*2+1])<<8))}
    case .RGBA32F:
        for c in 0..<4 {value[c]=transmute(f32)(u32(texels[at*16+c*4])|u32(texels[at*16+c*4+1])<<8|u32(texels[at*16+c*4+2])<<16|u32(texels[at*16+c*4+3])<<24)}
    }
    return
}

// Writes a linear value to texel `at`: 8 and 16 bits clamp to 0..1 (with the
// sRGB curve under transfer), half floats to their range, and a NaN is 0.
texel_write :: proc "contextless" (texels:[]u8,format:Source_Format,at:int,value:[4]f32,transfer:^Transfer) #no_bounds_check {
    value:=value
    for &v in value {if v!=v {v=0}}
    if transfer.srgb && (format==.RGBA8 || format==.RGBA16) {value.rgb={mm.linear_to_srgb(value.r),mm.linear_to_srgb(value.g),mm.linear_to_srgb(value.b)}}
    switch format {
    case .RGBA8:
        for c in 0..<4 {texels[at*4+c]=to_byte(value[c])}
    case .RGBA16:
        for c in 0..<4 {
            bits:=u16(clamp(value[c],0,1)*65535+0.5)
            texels[at*8+c*2],texels[at*8+c*2+1]=u8(bits),u8(bits>>8)
        }
    case .RGBA16F:
        for c in 0..<4 {
            bits:=transmute(u16)f16(clamp(value[c],-65504,65504))
            texels[at*8+c*2],texels[at*8+c*2+1]=u8(bits),u8(bits>>8)
        }
    case .RGBA32F:
        for c in 0..<4 {
            bits:=transmute(u32)value[c]
            for b in 0..<4 {texels[at*16+c*4+b]=u8(bits>>(u32(b)*8))}
        }
    }
}

Encoding :: enum u8 {
    Blocks,       // BC1, BC3, BC5, BC6H or BC7 by use (stored_format)
    Uncompressed, // RGBA8, RGBA16 or RGBA16F, by what the source holds
}

// How hard the blocks of a texture are encoded. A texture of Fast blocks
// carries asset.Texture_Flag.Fast, and a cook encodes it again as Final.
Encode_Speed :: enum u8 {
    Final, // rate-distortion optimization with the lambda of the options: what a game ships
    Fast,  // without RDO and at the encoder's low effort: what the editor imports in its session
}

// Where a channel of a built texture comes from: the same channel of the
// image, another of its channels, or a constant.
Channel :: enum u8 {Same,R,G,B,A,Zero,One}

// The channels of a built texture made of those of its image, each inverted
// (1 - x) when invert holds it: a gloss map in red becomes the roughness in
// the green of a metallic-roughness texture with {from={.One,.R,.One,.One},
// invert={1}}. The zero value keeps the image's channels.
Channels :: struct {
    from:[4]Channel,
    invert:bit_set[0..<4;u8],
}

Build_Options :: struct {
    srgb:bool,           // color: averaged as light, stored as sRGB in the formats of 8 bits
    normal_map:bool,     // averaged as vectors and renormalized
    green_down:bool,     // of a normal map whose green points down the image, as DirectX writes them: inverted, so that +Y points up as the renderer reads it
    alpha_coverage:f32,  // above 0: the cutoff of a masked material whose coverage every level keeps
    keep_precision:bool, // a source of 16 bits or floats is stored uncompressed whatever the encoding: heights, displacement, data floats
    encoding:Encoding,
    rdo_lambda:int,      // of blocks, up to RDO_LAMBDA_MAX: how much error the rate-distortion optimization trades for blocks that compress smaller. 0: RDO_LAMBDA_DEFAULT; below 0: none, the least error
    speed:Encode_Speed,
    channels:Channels,   // what each channel is made of, before anything else; the zero value keeps them
}

// What names the blocks the encoders of this build make in the caches and in the key of an
// import: checkouts with and without the private compressor share the caches.
encoders_id :: proc "contextless" () -> u64 {return base.name_hash(blocks.NAME)}

// The lambda of the RDO of options, 0 for none.
rdo_lambda :: proc "contextless" (options:Build_Options) -> int {
    if options.rdo_lambda<0 || options.speed==.Fast {return 0}
    return options.rdo_lambda if options.rdo_lambda>0 else RDO_LAMBDA_DEFAULT
}

// How the blocks of a level are encoded.
@(private)
block_encode :: proc "contextless" (options:Build_Options) -> blocks.Options {
    return {lambda=rdo_lambda(options),fast=options.speed==.Fast,srgb=options.srgb}
}

Built :: struct {
    width,height:int, // of the first level
    layers:int,       // of every level
    format:asset.Texture_Format,
    flags:asset.Texture_Flags,
    alpha_coverage:f32,
    mips:[][]u8,      // level 0 first, in format, each with its layers
    allocator:mem.Allocator,
}

built_destroy :: proc(built:^Built) {
    for level in built.mips {delete(level,built.allocator)}
    delete(built.mips,built.allocator)
    built^={}
}

// The description asset.texture_save takes; the levels stay owned by built.
// With layouts, for a document that compresses with the best codecs, a
// texture of blocks of 16 bytes stores the layouts of the compressor that do
// better than its blocks, in the temporary allocator: one of its tail
// (asset.TEXTURE_TAIL), which a read of the small levels restores alone, and
// one of the larger levels; one per level would compress larger. Without
// memory for them the blocks are stored as they are.
built_desc :: proc(built:^Built,id:base.Asset_Id,source:^asset.Import_Info,layouts:=false) -> asset.Texture_Desc {
    desc:=asset.Texture_Desc{id=id,width=built.width,height=built.height,layers=built.layers,format=built.format,flags=built.flags,alpha_coverage=built.alpha_coverage,mips=built.mips,source=source}
    if !layouts || asset.texture_block_bytes(built.format)!=16 || len(built.mips)==0 {return desc}
    formats:=#partial [asset.Texture_Format]blocks.Block_Format{.BC3=.BC3,.BC5=.BC5,.BC6H=.BC6H,.BC7=.BC7}
    tail:=0
    for tail+1<len(built.mips) && max(built.width>>uint(tail),built.height>>uint(tail))>asset.TEXTURE_TAIL {tail+=1}
    runs:=[2][2]int{{0,tail},{tail,len(built.mips)}}
    total:=0
    for level in built.mips {total+=len(level)}
    // A compressor without layouts writes none.
    bound:=blocks.layout_bound(total/16)
    if bound==0 {return desc}
    laid:=make([]asset.Texture_Layout,2,context.temp_allocator)
    run_blocks:=make([]u8,total,context.temp_allocator)
    payload:=make([]u8,bound,context.temp_allocator)
    if laid==nil || run_blocks==nil || payload==nil {return desc}
    count,at:=0,0
    for run in runs {
        if run[0]==run[1] {continue}
        // Its levels the smallest first, as the texels hold them.
        size:=0
        #reverse for level in built.mips[run[0]:run[1]] {size+=copy(run_blocks[size:],level)}
        layout,header,written,error:=blocks.layout_encode(formats[built.format],run_blocks[:size],payload[at:],context.temp_allocator)
        if error!=.None || layout==texture.NO_LAYOUT {return desc}
        laid[count]={layout=layout,header=header,level=run[0],payload=payload[at:][:written]}
        count+=1
        at+=written
    }
    desc.layouts=laid[:count]
    return desc
}

// What decides the bytes build gives for an image: the settings hash an
// import records, so a texture is built again when one of them changes. Fast
// is another hash; Final is the hash of the settings alone.
settings_hash :: proc(options:Build_Options) -> u64 {
    kind:=u64(options.srgb)|u64(options.normal_map)<<1|u64(options.encoding)<<2|u64(options.green_down)<<4|u64(options.keep_precision)<<5|u64(BUILD_VERSION)<<8
    hash:=base.hash_combine(kind,u64(transmute(u32)options.alpha_coverage))
    final:=options
    final.speed=.Final
    hash=base.hash_combine(hash,u64(rdo_lambda(final)))
    hash=base.hash_combine(hash,encoders_id())
    if options.channels!={} {
        c:=options.channels
        packed:=u64(c.from[0])|u64(c.from[1])<<8|u64(c.from[2])<<16|u64(c.from[3])<<24|u64(transmute(u8)c.invert)<<32
        hash=base.hash_combine(hash,packed)
    }
    return base.hash_combine(hash,0x66617374) if options.speed==.Fast else hash
}

// The format a texture is stored in, by what it is used for and what its
// source holds. Uncompressed (or a source of more than 8 bits that keeps its
// precision) stores what the source holds: RGBA8, RGBA16, or RGBA16F for
// floats. In blocks: a normal map keeps its two first channels (BC5, the
// shader rebuilds the third); floats are HDR, BC6H unless some texel is not
// opaque or has a negative channel, which BC6H cannot keep (RGBA16F); other
// color is BC7 with or without alpha, and a data map (occlusion, roughness,
// metallic) is BC1, or BC3 when some texel is not opaque.
stored_format :: proc(source:Source,options:Build_Options) -> asset.Texture_Format {
    if options.encoding==.Uncompressed || options.keep_precision && source.format!=.RGBA8 {
        switch source.format {
        case .RGBA8: return .RGBA8
        case .RGBA16: return .RGBA16
        case .RGBA16F,.RGBA32F: return .RGBA16F
        }
    }
    if options.normal_map {return .BC5}
    hdr:=source_hdr(source.format)
    if !hdr && options.srgb {return .BC7}
    transfer:=transfer_make(false)
    count:=source.width*source.height*max(source.layers,1)
    for at in 0..<count {
        value:=texel_read(source.texels,source.format,at,&transfer)
        if value.a<1 || hdr && (value.r<0 || value.g<0 || value.b<0) {return .RGBA16F if hdr else .BC3}
    }
    return .BC6H if hdr else .BC1
}

// Every level down to 1x1 of each layer of a source, with the rules of its
// kind: color is averaged in linear light, normal maps as vectors that are
// renormalized, and a masked texture keeps the share of texels above its
// cutoff. A level is reduced from the one above in the format of the source
// and stored (stored_format) from it. The blocks of a level are compressed on
// the job system of worker, when it has one; else long ones on a system of
// their own.
build :: proc(source:Source,options:Build_Options,allocator:=context.allocator,worker:=jobs.Worker_Ref{}) -> (built:Built,error:Error) {
    layers:=max(source.layers,1)
    if source.width<=0 || source.height<=0 || source.layers<0 || source.format>max(Source_Format) || !(options.alpha_coverage>=0 && options.alpha_coverage<=1) || options.rdo_lambda>RDO_LAMBDA_MAX || options.speed>max(Encode_Speed) {return {},.Invalid}
    flags:=asset.Texture_Flags{}
    if source.cube {flags+={.Cube}}
    if !asset.texture_layers_valid(layers,source.width,source.height,flags) || len(source.texels)<source_bytes(source) {return {},.Invalid}
    if source.width>asset.TEXTURE_MAX_SIZE || source.height>asset.TEXTURE_MAX_SIZE {return {},.Too_Large}
    transfer:=transfer_make(options.srgb && !source_hdr(source.format))
    level:=source
    level.layers,level.allocator=layers,{}
    level.texels=source.texels[:source_bytes(level)]
    coverage:=f32(0)
    if options.alpha_coverage>0 {coverage=alpha_coverage_of(level,options.alpha_coverage,1)}
    mips:[dynamic][]u8
    mips.allocator=allocator
    fail :: proc(mips:^[dynamic][]u8,owned:^Source) -> Error {
        for level in mips {delete(level,mips.allocator)}
        delete(mips^)
        source_destroy(owned)
        return .Out_Of_Memory
    }
    owned:Source
    if options.channels!={} {
        if options.channels.from[0]>max(Channel) || options.channels.from[1]>max(Channel) || options.channels.from[2]>max(Channel) || options.channels.from[3]>max(Channel) {return {},.Invalid}
        alloc_error:mem.Allocator_Error
        owned=level
        owned.allocator=allocator
        if owned.texels,alloc_error=make([]u8,len(level.texels),allocator);alloc_error!=nil {return {},fail(&mips,&owned)}
        linear:=transfer_make(false)
        for at in 0..<owned.width*owned.height*layers {
            value:=channels_apply(options.channels,texel_read(level.texels,level.format,at,&linear))
            texel_write(owned.texels,owned.format,at,value,&linear)
        }
        level=owned
    }
    if options.green_down {
        alloc_error:mem.Allocator_Error
        previous:=owned
        defer source_destroy(&previous)
        owned=level
        owned.allocator=allocator
        if owned.texels,alloc_error=make([]u8,len(level.texels),allocator);alloc_error!=nil {return {},fail(&mips,&owned)}
        copy(owned.texels,level.texels)
        linear:=transfer_make(false)
        for at in 0..<owned.width*owned.height*layers {
            value:=texel_read(owned.texels,owned.format,at,&linear)
            value.g=1-value.g
            texel_write(owned.texels,owned.format,at,value,&linear)
        }
        level=owned
    }
    next :: proc(level:Source,transfer:^Transfer,options:Build_Options,coverage:f32,allocator:mem.Allocator) -> (reduced:Source,ok:bool) {
        reduced={width=max(level.width/2,1),height=max(level.height/2,1),layers=level.layers,format=level.format,cube=level.cube,allocator=allocator}
        alloc_error:mem.Allocator_Error
        if reduced.texels,alloc_error=make([]u8,source_bytes(reduced),allocator);alloc_error!=nil {return {},false}
        reduce(level,reduced,transfer,options.normal_map)
        if options.alpha_coverage>0 {alpha_coverage_keep(reduced,options.alpha_coverage,coverage)}
        return reduced,true
    }
    built.width,built.height,built.layers=level.width,level.height,layers
    built.format=stored_format(source,options)
    js:jobs.Job_System
    parallel:=worker.system==nil && encode_jobs_begin(&js,built.format,level.width,level.height*layers)
    defer if parallel {jobs.system_destroy(&js)}
    on:=worker
    if parallel {on={&js,jobs.OWNER,nil}}
    encode:=block_encode(options)
    for {
        encode_zone:=jobs.worker_zone_begin(worker,"texture.encode")
        stored,store_error:=level_store(level,built.format,&transfer,encode,allocator,on)
        base.profile_end(encode_zone)
        if store_error!=.None {
            fail(&mips,&owned)
            return {},store_error
        }
        append(&mips,stored)
        if level.width==1 && level.height==1 {break}
        reduced,ok:=next(level,&transfer,options,coverage,allocator)
        if !ok {return {},fail(&mips,&owned)}
        source_destroy(&owned)
        owned,level=reduced,reduced
    }
    source_destroy(&owned)
    built.mips=mips[:]
    built.allocator=allocator
    built.alpha_coverage=options.alpha_coverage
    built.flags=flags
    if options.srgb {built.flags+={.Srgb}}
    if options.normal_map {built.flags+={.Normal_Map}}
    #partial switch built.format {
    case .BC1,.BC3,.BC5,.BC6H,.BC7: if options.speed==.Fast {built.flags+={.Fast}}
    }
    return built,.None
}

// Decodes the bytes of an image file (source_decode) and builds its levels.
from_bytes :: proc(bytes:[]u8,options:Build_Options,allocator:=context.allocator,worker:=jobs.Worker_Ref{}) -> (built:Built,error:Error) {
    decode_zone:=jobs.worker_zone_begin(worker,"image.decode")
    source,decode_error:=source_decode(bytes,allocator)
    base.profile_end(decode_zone)
    if decode_error!=.None {return {},decode_error}
    defer source_destroy(&source)
    return build(source,options,allocator,worker)
}

// A level of a source, every layer, in the format it is stored in: the
// formats of 8 bits take it as sRGB under transfer, RGBA16, RGBA16F and BC6H
// linear. In allocator.
@(private)
level_store :: proc(level:Source,format:asset.Texture_Format,transfer:^Transfer,encode:blocks.Options,allocator:mem.Allocator,worker:jobs.Worker_Ref) -> (out:[]u8,error:Error) {
    alloc_error:mem.Allocator_Error
    switch format {
    case .RGBA8: out,alloc_error=level_convert(level,.RGBA8,transfer,transfer,allocator)
    case .RGBA16:
        linear:=transfer_make(false)
        out,alloc_error=level_convert(level,.RGBA16,transfer,&linear,allocator)
    case .RGBA16F: out,alloc_error=level_convert(level,.RGBA16F,transfer,transfer,allocator)
    case .BC1,.BC3,.BC5,.BC6H,.BC7: return level_encode(level,format,transfer,encode,allocator,worker)
    }
    if alloc_error!=nil {return nil,.Out_Of_Memory}
    return out,.None
}

// The blocks of a level, each layer apart, by compressor:blocks with the
// lambda, effort and metric of encode: BC6H from half floats, the others from
// RGBA8. Alpha keeps its exact 0 and 255, and a BC7 layer whose texels are all
// opaque is encoded without alpha, which then decodes 255. On a worker the
// blocks go in parallel, with scratch from the heap.
@(private)
level_encode :: proc(level:Source,format:asset.Texture_Format,transfer:^Transfer,encode:blocks.Options,allocator:mem.Allocator,worker:jobs.Worker_Ref) -> (out:[]u8,error:Error) {
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
        if texels.texels,alloc_error=make([]u8,source_bytes(texels),allocator);alloc_error!=nil {return nil,.Out_Of_Memory}
        for at in 0..<level.width*level.height*layers {texel_write(texels.texels,.RGBA16F,at,texel_read(level.texels,level.format,at,transfer),transfer)}
    } else if level.format!=.RGBA8 {
        texels.format,owned=.RGBA8,true
        if texels.texels,alloc_error=level_convert(level,.RGBA8,transfer,transfer,allocator);alloc_error!=nil {return nil,.Out_Of_Memory}
    }
    size:=asset.texture_level_size(format,level.width,level.height)
    if out,alloc_error=make([]u8,size*layers,allocator);alloc_error!=nil {return nil,.Out_Of_Memory}
    formats:=#partial [asset.Texture_Format]blocks.Block_Format{.BC1=.BC1,.BC3=.BC3,.BC5=.BC5,.BC6H=.BC6H,.BC7=.BC7}
    scratch:=allocator if worker.system==nil else runtime.heap_allocator()
    image:=source_bytes(texels)/layers
    for layer in 0..<layers {
        pixels:=texels.texels[layer*image:][:image]
        options:=encode
        options.ignore_alpha=format==.BC7 && opaque(pixels)
        result:=blocks.encode(formats[format],{pixels=pixels,width=level.width,height=level.height,format=pixel},options,out[layer*size:][:size],scratch,worker)
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
encode_jobs_begin :: proc(js:^jobs.Job_System,format:asset.Texture_Format,width,height:int) -> bool {
    #partial switch format {
    case .BC1,.BC3,.BC5,.BC6H,.BC7: if width*height<PARALLEL_TEXELS {return false}
    case: return false
    }
    return jobs.system_init(js,{threads=jobs.THREADS_AUTO})
}

// One image of a source as RGBA8 rows from the top, to look at: with the
// sRGB curve under srgb, and light above 1 clipped.
source_image_rgba8 :: proc(source:Source,layer:int,srgb:bool,allocator:=context.allocator) -> (pixels:[]u8,error:mem.Allocator_Error) {
    image:=source
    image.layers=1
    size:=source_bytes(image)
    image.texels=source.texels[layer*size:][:size]
    from,to:=transfer_make(srgb && !source_hdr(source.format)),transfer_make(srgb)
    return level_convert(image,.RGBA8,&from,&to,allocator)
}

// The texels of a level in another format, from linear values: to's
// transfer writes them. A level already in that format with the same
// transfer is copied.
@(private)
level_convert :: proc(level:Source,format:Source_Format,from,to:^Transfer,allocator:mem.Allocator) -> (out:[]u8,error:mem.Allocator_Error) {
    target:=level
    target.format=format
    out=make([]u8,source_bytes(target),allocator) or_return
    if level.format==format && (from.srgb==to.srgb || format==.RGBA16F || format==.RGBA32F) {
        copy(out,level.texels[:len(out)])
        return
    }
    for at in 0..<level.width*level.height*max(level.layers,1) {texel_write(out,format,at,texel_read(level.texels,level.format,at,from),to)}
    return
}

@(private="file")
to_byte :: proc "contextless" (value:f32) -> u8 {return u8(clamp(value,0,1)*255+0.5)}

// Source texels a destination texel covers along one axis, with the share of
// each. A level is half the one above, rounded down: an odd size leaves every
// texel covering a little more than two.
@(private="file")
Taps :: struct {
    first,count:int,
    weights:[3]f32,
}

@(private="file")
reduce_taps :: proc(source,target,index:int) -> (taps:Taps) {
    scale:=f32(source)/f32(target)
    start:=f32(index)*scale
    end:=start+scale
    taps.first=int(start)
    last:=min(int(math.ceil(end))-1,source-1)
    taps.count=min(last-taps.first+1,len(taps.weights))
    for i in 0..<taps.count {
        lo:=max(f32(taps.first+i),start)
        hi:=min(f32(taps.first+i+1),end)
        taps.weights[i]=max(hi-lo,0)/scale
    }
    return
}

// The next level of each layer of src into dst, of the same format and layers.
@(private="file")
reduce :: proc(src,dst:Source,transfer:^Transfer,normal_map:bool) {
    sw,sh,dw,dh:=src.width,src.height,dst.width,dst.height
    for layer in 0..<max(src.layers,1) {
        from,to:=layer*sw*sh,layer*dw*dh
        for y in 0..<dh {
            rows:=reduce_taps(sh,dh,y)
            for x in 0..<dw {
                columns:=reduce_taps(sw,dw,x)
                sum:[4]f32
                for j in 0..<rows.count {
                    for i in 0..<columns.count {
                        sum+=texel_read(src.texels,src.format,from+(rows.first+j)*sw+columns.first+i,transfer)*(rows.weights[j]*columns.weights[i])
                    }
                }
                if normal_map {
                    n:=[3]f32{sum.r,sum.g,sum.b}*2-1
                    length:=math.sqrt(n.x*n.x+n.y*n.y+n.z*n.z)
                    n=n/length if length>1e-6 else [3]f32{0,0,1}
                    sum.r,sum.g,sum.b=n.x*0.5+0.5,n.y*0.5+0.5,n.z*0.5+0.5
                }
                texel_write(dst.texels,dst.format,to+y*dw+x,sum,transfer)
            }
        }
    }
}

// Share of the texels of every layer whose alpha, scaled, reaches the cutoff.
alpha_coverage_of :: proc(level:Source,cutoff,scale:f32) -> f32 {
    count:=level.width*level.height*max(level.layers,1)
    covered:=0
    if level.format==.RGBA8 {
        for i:=3;i<count*4;i+=4 {
            if f32(level.texels[i])*scale>=cutoff*255 {covered+=1}
        }
    } else {
        linear:=transfer_make(false)
        for at in 0..<count {
            if texel_read(level.texels,level.format,at,&linear).a*scale>=cutoff {covered+=1}
        }
    }
    return f32(covered)/f32(max(count,1))
}

// Averaging thins a cutout: fewer texels of each smaller level pass the test,
// and foliage or a fence fades away with distance. Scaling the alpha of the
// level brings its coverage back to the one of the image.
@(private="file")
alpha_coverage_keep :: proc(level:Source,cutoff,wanted:f32) {
    lo,hi:=f32(0),f32(8)
    for _ in 0..<12 {
        scale:=(lo+hi)*0.5
        if alpha_coverage_of(level,cutoff,scale)<wanted {lo=scale} else {hi=scale}
    }
    scale:=(lo+hi)*0.5
    count:=level.width*level.height*max(level.layers,1)
    if level.format==.RGBA8 {
        for i:=3;i<count*4;i+=4 {level.texels[i]=u8(min(f32(level.texels[i])*scale+0.5,255))}
        return
    }
    linear:=transfer_make(false)
    for at in 0..<count {
        value:=texel_read(level.texels,level.format,at,&linear)
        value.a=min(value.a*scale,1)
        texel_write(level.texels,level.format,at,value,&linear)
    }
}

// The texture of an asset that stores RGBA8, in the blocks of its use
// (stored_format): each of its levels and layers compressed as it is, so the
// chain is the one the asset has. False, with nothing, for a texture in
// another format, which keeps it: blocks already, or more than 8 bits. The
// blocks are encoded on the job system of worker, else on one of their own;
// without rdo, with the least error, for a game that compresses nothing.
blocks_of :: proc(view:asset.Texture_View,allocator:=context.allocator,worker:=jobs.Worker_Ref{},rdo:=true) -> (built:Built,ok:bool) {
    info:=view.info
    if info==nil || info.format!=.RGBA8 || len(view.mips)==0 {return}
    layers:=int(info.layers)
    plane :: proc(view:asset.Texture_View,level:int) -> Source {
        mip:=view.mips[level]
        return {texels=asset.texture_mip(view,level),width=int(mip.width),height=int(mip.height),layers=int(view.info.layers),format=.RGBA8,cube=.Cube in view.info.flags}
    }
    options:=Build_Options{srgb=.Srgb in info.flags,normal_map=.Normal_Map in info.flags,rdo_lambda=0 if rdo else -1}
    format:=stored_format(plane(view,0),options)
    built={width=int(info.width),height=int(info.height),layers=layers,format=format,flags=info.flags,alpha_coverage=info.alpha_coverage,allocator=allocator}
    built.mips=make([][]u8,len(view.mips),allocator)
    js:jobs.Job_System
    parallel:=worker.system==nil && encode_jobs_begin(&js,format,built.width,built.height*layers)
    defer if parallel {jobs.system_destroy(&js)}
    on:=worker
    if parallel {on={&js,jobs.OWNER,nil}}
    transfer:=transfer_make(options.srgb)
    for _,level in view.mips {
        blocks,error:=level_store(plane(view,level),format,&transfer,block_encode(options),allocator,on)
        if error!=.None {
            built_destroy(&built)
            return {},false
        }
        built.mips[level]=blocks
    }
    return built,true
}

// A texel of an image as Channels make it.
@(private)
channels_apply :: proc "contextless" (c:Channels,value:[4]f32) -> (out:[4]f32) {
    for i in 0..<4 {
        switch c.from[i] {
        case .Same: out[i]=value[i]
        case .R: out[i]=value[0]
        case .G: out[i]=value[1]
        case .B: out[i]=value[2]
        case .A: out[i]=value[3]
        case .Zero: out[i]=0
        case .One: out[i]=1
        }
        if i in c.invert {out[i]=1-out[i]}
    }
    return
}
