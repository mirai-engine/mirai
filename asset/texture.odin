package asset

import "core:mem"
import "mirai:std/compressor/data"
import "mirai:std/base"

// .tex: an image ready for the GPU.
//
//   texture         Texture_Info, one row
//   mips            Texture_Mip: where each level is inside texels, level 0 first
//   texels   bulk   bytes of every level, the smallest first, each one starting at
//                   a multiple of 16, a stream: the small levels decode from its
//                   first pieces without the others (texture_decode)
//
// A level is half the one above, rounded down, and never smaller than 1. It
// holds its layers one after another: the images of an array, or the faces
// of its cubes. Block formats store 4x4 blocks: BC1 in 8 bytes, BC5, BC6H
// and BC7 in 16. With Fields, each mip stores the fields of its blocks in planes.

TEXTURE_VERSION :: 5
TEXTURE_MAX_SIZE :: 16384
TEXTURE_MAX_MIPS :: 15
// Of an array or of cube faces: the least every GPU Mirai runs on takes.
TEXTURE_MAX_LAYERS :: 256
TEXTURE_CUBE_FACES :: 6
TEXTURE_BULK_ALIGNMENT :: 16
// The side of the largest level of the tail: the levels a texture always holds, which every read
// of its levels takes together.
TEXTURE_TAIL :: 128

Texture_Format :: enum u8 {
    RGBA8,   // rows from the top of the image
    BC1,     // rgb: data maps without alpha
    BC5,     // two channels: tangent-space normals
    BC7,     // color or data maps with alpha
    RGBA16,  // 16-bit channels, linear: data that keeps its precision
    RGBA16F, // half floats, linear: HDR with alpha, negative values or kept uncompressed
    BC6H,    // rgb half floats without sign, linear: HDR light and color
    R8,      // one 8-bit channel, linear: masks and data, sampled as (r, 0, 0, 1)
}

Texture_Flag :: enum u8 {
    Srgb,       // color: stored as sRGB in RGBA8, BC1 and BC7, linear in the others; filtered as light
    Normal_Map, // levels are averaged as vectors and renormalized
    Cube,       // its layers are the faces +X, -X, +Y, -Y, +Z and -Z of cubes, sampled with a direction of the world
    Fast,       // blocks of the fast encode the editor imports with; a cook encodes them again from the source
    Fields,     // each level stores the fields of its blocks as planes, which compress smaller: the writer chooses it
}
Texture_Flags :: bit_set[Texture_Flag;u32]

Texture_Info :: struct {
    width:u32,
    height:u32,
    mip_count:u32,
    format:Texture_Format,
    flags:Texture_Flags,
    alpha_coverage:f32, // above 0: the cutoff of the masked material whose coverage every level keeps
    layers:u32,         // images of each level: one, those of an array, or six per cube
}

Texture_Mip :: struct {
    width:u32,
    height:u32,
    offset:u32, // into texels
    size:u32,   // stored bytes of all layers
}

Texture_Desc :: struct {
    id:base.Asset_Id,
    owner:base.Asset_Id, // the asset it is a part of: the prefab of the import that made it
    width,height:int,
    layers:int,          // 0: one
    format:Texture_Format,
    flags:Texture_Flags, // but Fields, which the writer chooses
    alpha_coverage:f32,
    mips:[][]u8,         // level 0 first, each with its layers one after another
    source:^Import_Info,
}

Texture_View :: struct {
    info:^Texture_Info,
    mips:[]Texture_Mip,
    texels:[]u8,
    source:^Import_Info,
    first,last:int, // [first,last) of decoded mips
    planes:bool,
    joined:bool,
    offsets:[TEXTURE_MAX_MIPS]int, // of the decoded mips, when joined
}

// Bytes of one image of a level of a size, in a format.
texture_level_size :: proc "contextless" (format:Texture_Format,width,height:int) -> int {
    switch format {
    case .R8: return width*height
    case .RGBA8: return width*height*4
    case .RGBA16,.RGBA16F: return width*height*8
    case .BC1: return ((width+3)/4)*((height+3)/4)*8
    case .BC5,.BC6H,.BC7: return ((width+3)/4)*((height+3)/4)*16
    }
    return 0
}

// Bytes of a 4x4 block of a block format; 0 for the others.
texture_block_bytes :: proc "contextless" (format:Texture_Format) -> int {
    #partial switch format {
    case .BC1: return 8
    case .BC5,.BC6H,.BC7: return 16
    }
    return 0
}

// Levels of a full chain down to 1x1.
texture_mip_count :: proc "contextless" (width,height:int) -> int {
    count:=1
    for size:=max(width,height);size>1;size>>=1 {count+=1}
    return count
}

// Whether a count of layers is one a texture of those flags holds: a cube is
// square and has whole cubes.
texture_layers_valid :: proc "contextless" (layers,width,height:int,flags:Texture_Flags) -> bool {
    if layers<1 || layers>TEXTURE_MAX_LAYERS {return false}
    return .Cube not_in flags || layers%TEXTURE_CUBE_FACES==0 && width==height
}

texture_document :: proc(doc:^Document,types:^Types,desc:Texture_Desc,
    allocator:=context.allocator,profile:=data.Profile.Fast) -> Error {
    if desc.width<=0 || desc.height<=0 || desc.width>TEXTURE_MAX_SIZE || desc.height>TEXTURE_MAX_SIZE {return .Invalid}
    if desc.format>max(Texture_Format) {return .Invalid}
    layers:=max(desc.layers,1)
    if desc.layers<0 || !texture_layers_valid(layers,desc.width,desc.height,desc.flags) {return .Invalid}
    if len(desc.mips)==0 || len(desc.mips)>texture_mip_count(desc.width,desc.height) || !finite(desc.alpha_coverage) {return .Invalid}
    info:=Texture_Info{width=u32(desc.width),height=u32(desc.height),mip_count=u32(len(desc.mips)),format=desc.format,flags=desc.flags-{.Fields},alpha_coverage=desc.alpha_coverage,layers=u32(layers)}
    mips:[TEXTURE_MAX_MIPS]Texture_Mip
    total:=0
    #reverse for level,i in desc.mips {
        width,height:=max(desc.width>>uint(i),1),max(desc.height>>uint(i),1)
        if len(level)!=texture_level_size(desc.format,width,height)*layers {return .Invalid}
        total=texture_mip_align(total)
        if total+len(level)>int(max(u32)) {return .Invalid}
        mips[i]={u32(width),u32(height),u32(total),u32(len(level))}
        total+=len(level)
    }
    document_init(doc,KIND_TEXTURE,desc.id,allocator)
    doc.owner=desc.owner
    doc.kind_version=TEXTURE_VERSION
    error:=texture_tables(doc,types,&info,mips[:len(desc.mips)],total,desc,profile)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
texture_tables :: proc(doc:^Document,types:^Types,info:^Texture_Info,mips:[]Texture_Mip,
    total_raw:int,desc:Texture_Desc,profile:data.Profile) -> Error {
    total:=total_raw
    byte,_:=document_type(doc,types,u8)
    split:[]u8
    defer delete(split,doc.allocator)
    if texture_fields_format(desc.format) && .Fast not_in desc.flags {
        candidate:[TEXTURE_MAX_MIPS]Texture_Mip
        size:=0
        #reverse for level,i in desc.mips {
            size=texture_mip_align(size)
            bytes:=texture_fields_size(desc.format,level)
            if size+bytes>int(max(u32)) {return .Too_Large}
            candidate[i]={mips[i].width,mips[i].height,u32(size),u32(bytes)}
            size+=bytes
        }
        smaller:=true
        if doc.codecs!=.None {
            no_room:mem.Allocator_Error
            split,no_room=make([]u8,size,doc.allocator)
            if no_room!=nil {return .Out_Of_Memory}
            texture_split_levels(desc,candidate[:len(mips)],split) or_return
            smaller=texture_fields_smaller(desc.mips,mips,total,split,doc.codecs,profile,
                doc.allocator) or_return
        }
        if smaller {
            info.flags+={.Fields}
            copy(mips,candidate[:len(mips)])
            total=size
        }
    }
    texels:=document_table_add(doc,"texels",{.Bulk}) or_return
    document_resize(doc,texels,total) or_return
    column:=document_column_add(doc,texels,"",byte,{},TEXTURE_BULK_ALIGNMENT) or_return
    bytes:=doc.tables[texels].columns[column].data[:]
    if .Fields in info.flags {
        if split!=nil {copy(bytes,split)}
        else {texture_split_levels(desc,mips,bytes) or_return}
    } else {
        for level,i in desc.mips {copy(bytes[mips[i].offset:],level)}
    }
    document_put_row(doc,types,"texture",info) or_return
    document_put(doc,types,"mips",mips) or_return
    import_put(doc,types,desc.source) or_return
    return .None
}

@(private="file")
texture_split_levels :: proc "contextless" (desc:Texture_Desc,mips:[]Texture_Mip,
    bytes:[]u8) -> Error {
    for level,i in desc.mips {
        mip:=mips[i]
        if !texture_fields_split(desc.format,level,bytes[mip.offset:][:mip.size]) {
            return .Invalid
        }
    }
    return .None
}

// Whether the field planes give a smaller stream at the profile of the write.
@(private="file")
texture_fields_smaller :: proc(levels:[][]u8,mips:[]Texture_Mip,total:int,split:[]u8,
    codecs:Codecs,profile:data.Profile,allocator:mem.Allocator) -> (smaller:bool,error:Error) {
    raw,raw_error:=make([]u8,total,allocator)
    if raw_error!=nil {return false,.Out_Of_Memory}
    defer delete(raw,allocator)
    for level,i in levels {copy(raw[mips[i].offset:],level)}
    out,out_error:=make([]u8,pack_bound(max(total,len(split))),allocator)
    if out_error!=nil {return false,.Out_Of_Memory}
    defer delete(out,allocator)
    encoder:Stream_Encoder
    stream_encoder_init(&encoder,allocator) or_return
    defer stream_encoder_destroy(&encoder)
    sizes:[2]int
    for bytes,i in ([2][]u8{raw,split}) {sizes[i]=pack(&encoder,profile,codecs,bytes,out) or_return}
    return sizes[1]<sizes[0],.None
}

@(private="file")
texture_mip_align :: proc "contextless" (offset:int) -> int {
    return (offset+TEXTURE_BULK_ALIGNMENT-1)&~int(TEXTURE_BULK_ALIGNMENT-1)
}

texture_save :: proc(path:string,types:^Types,desc:Texture_Desc,allocator:=context.allocator,profile:=data.Profile.Fast) -> Error {
    doc:Document
    texture_document(&doc,types,desc,allocator,profile) or_return
    defer document_destroy(&doc)
    return document_save(&doc,path,profile=profile)
}

// Rewrites a texture with the compression of types, preserving its mip bytes.
texture_repack :: proc(bytes:[]u8,types:^Types,profile:data.Profile,allocator:=context.allocator) -> (repacked:[]u8,error:Error) {
    file:Asset
    asset_open(&file,bytes,context.temp_allocator) or_return
    defer asset_close(&file)
    view:=texture_view(&file,types) or_return
    mips,mips_error:=make([][]u8,len(view.mips),context.temp_allocator)
    if mips_error!=nil {return nil,.Out_Of_Memory}
    for _,level in view.mips {mips[level]=texture_mip(view,level)}
    info:=view.info
    doc:Document
    desc:=Texture_Desc{id=file.blob.header.id,owner=file.blob.header.owner,width=int(info.width),
        height=int(info.height),layers=int(info.layers),format=info.format,flags=info.flags,
        alpha_coverage=info.alpha_coverage,mips=mips,source=view.source}
    texture_document(&doc,types,desc,context.temp_allocator,profile) or_return
    defer document_destroy(&doc)
    document_tables_carry(&doc,&file) or_return
    doc.flags=file.blob.header.flags
    return document_bytes(&doc,allocator,profile)
}

// The texture of an open asset with every level, in memory of the asset.
texture_view :: proc(a:^Asset,types:^Types) -> (view:Texture_View,error:Error) {
    view=texture_open(a,types) or_return
    texture_decode(a,types,&view,0) or_return
    return view,.None
}

// The texture of an open asset without its texels, whose levels
// texture_decode reads.
texture_open :: proc(a:^Asset,types:^Types) -> (view:Texture_View,error:Error) {
    kind_check(a,KIND_TEXTURE,TEXTURE_VERSION) or_return
    view.info=asset_row(a,types,"texture",Texture_Info,whole=true) or_return
    view.mips=asset_rows(a,types,"mips","",Texture_Mip) or_return
    view.source=import_info(a,types) or_return
    if !texture_levels_check(view.info,view.mips) {return {},.Corrupt}
    view.first,view.last=len(view.mips),len(view.mips)
    return view,.None
}

// Decodes [from,before) into memory of the asset. keep_fields exposes
// validated field planes through texture_mip.
texture_decode :: proc(a:^Asset,types:^Types,view:^Texture_View,from:int,
    before:=max(int),keep_fields:=false) -> Error {
    if !texture_levels_check(view.info,view.mips) {return .Invalid}
    mips,info:=view.mips,view.info
    from:=clamp(from,0,len(mips)-1)
    before:=min(before,len(mips))
    if before<=from {return .Invalid}
    table,found:=asset_table(a,"texels")
    if !found {return .Not_Found}
    column,column_found:=table_column(table,"")
    if !column_found {return .Not_Found}
    byte,known:=types_index(types,u8)
    if !known {return types.error}
    if !asset_column_matches(a,table,column,types.hashes[byte]) {return .Corrupt}
    chunk:=table.columns[column].chunk
    entry:=blob_chunk(&a.blob,chunk)
    if entry.uncompressed_size!=u64(table.rows) {return .Corrupt}
    if u64(mips[0].offset)+u64(mips[0].size)!=u64(table.rows) {return .Corrupt}
    texels:[]u8
    offsets:[TEXTURE_MAX_MIPS]int
    fields,joined:=false,false

    start:=int(mips[before-1].offset)
    end:=int(mips[from].offset)+int(mips[from].size)
    if .Fields in info.flags {
        plane_buffer:[]u8
        defer mem.free_bytes(plane_buffer,a.allocator)
        temporary:=&plane_buffer if !keep_fields else nil
        planes:=texels_read(a,table,column,start,end,TEXTURE_BULK_ALIGNMENT,temporary) or_return
        layout:=texture_field_layout(info.format)
        if keep_fields {
            if layout.modes>0 {
                for mip in mips[from:before] {
                    low:=int(mip.offset)-start
                    raw:=texture_mip_bytes(info,mip)
                    if _,ok:=texture_fields_index(&layout,planes[low:][:mip.size],raw/16);!ok {
                        return .Corrupt
                    }
                }
            }
            texels,fields=planes,true
        } else {
            total:=0
            #reverse for mip,relative in mips[from:before] {
                total=texture_mip_align(total)
                offsets[from+relative]=total
                total+=texture_mip_bytes(info,mip)
            }
            texels=asset_alloc(a,total,TEXTURE_BULK_ALIGNMENT) or_return
            for mip,relative in mips[from:before] {
                low:=int(mip.offset)-start
                dst:=texels[offsets[from+relative]:][:texture_mip_bytes(info,mip)]
                if !texture_fields_join(info.format,planes[low:][:mip.size],dst) {return .Corrupt}
            }
            joined=true
        }
    } else {
        texels=texels_read(a,table,column,start,end,TEXTURE_BULK_ALIGNMENT) or_return
    }
    view.texels,view.planes,view.joined=texels,fields,joined
    copy(view.offsets[:],offsets[:])
    view.first,view.last=from,before
    return .None
}

@(private="file")
texels_read :: proc(a:^Asset,table:^Asset_Table,column,start,end,alignment:int,
    temporary:^[]u8=nil) -> (data:[]u8,error:Error) {
    if start<0 || end<start || end>table.rows {return nil,.Corrupt}
    if start==end {return nil,.None}
    target:=&table.columns[column]
    if target.ready {return target.data[start:end],.None}
    chunk:=target.chunk
    if blob_chunk(&a.blob,chunk).compression==.None {
        if start==0 && end==table.rows && temporary==nil {
            return asset_column_data(a,table,column)
        }
        return asset_stored_range(a,chunk,start,end,alignment,temporary)
    }
    return asset_stream_range(a,chunk,start,end,alignment,temporary)
}

// The bytes of a mip, in the representation requested by texture_decode.
texture_mip :: proc(view:Texture_View,level:int) -> []u8 {
    if level<0 || level<view.first || level>=view.last || view.last>len(view.mips) ||
        level>=TEXTURE_MAX_MIPS || view.info==nil {return nil}
    mip:=view.mips[level]
    start,size:=int(mip.offset)-int(view.mips[view.last-1].offset),int(mip.size)
    if view.joined {
        start,size=view.offsets[level],texture_mip_bytes(view.info,mip)
    }
    if start<0 || start>len(view.texels) || size<0 || size>len(view.texels)-start {return nil}
    return view.texels[start:][:size]
}

// The bytes of one layer; empty outside the decoded range or the image count.
texture_layer :: proc(view:Texture_View,level,layer:int) -> []u8 {
    bytes:=texture_mip(view,level)
    if view.planes || len(bytes)==0 || layer<0 || layer>=int(view.info.layers) {return nil}
    size:=len(bytes)/int(view.info.layers)
    return bytes[layer*size:][:size]
}

@(private="file")
texture_mip_bytes :: proc "contextless" (info:^Texture_Info,mip:Texture_Mip) -> int {
    return texture_level_size(info.format,int(mip.width),int(mip.height))*int(info.layers)
}

// Whether the info and the levels of a texture agree: sizes, format, layers
// and the size of each level.
texture_levels_check :: proc(info:^Texture_Info,mips:[]Texture_Mip) -> bool {
    if info==nil || info.width==0 || info.height==0 || info.width>TEXTURE_MAX_SIZE || info.height>TEXTURE_MAX_SIZE {return false}
    if info.format>max(Texture_Format) || !finite(info.alpha_coverage) {return false}
    if !texture_layers_valid(int(info.layers),int(info.width),int(info.height),info.flags) {return false}
    if int(info.mip_count)!=len(mips) || len(mips)==0 || len(mips)>texture_mip_count(int(info.width),int(info.height)) {return false}
    header,floor,ceiling,pad,block:=0,0,0,0,texture_block_bytes(info.format)
    if .Fields in info.flags {
        if block==0 {return false}
        header,floor,ceiling,pad=texture_fields_bounds(info.format)
    }
    end:=u64(0)
    #reverse for mip,i in mips {
        width,height:=max(int(info.width)>>uint(i),1),max(int(info.height)>>uint(i),1)
        if int(mip.width)!=width || int(mip.height)!=height {return false}
        raw:=texture_mip_bytes(info,mip)
        low,high:=raw,raw
        if .Fields in info.flags {
            n:=raw/block
            low,high=header+floor*n,header+ceiling*n+pad
        }
        if int(mip.size)<low || int(mip.size)>high {return false}
        offset:=(end+TEXTURE_BULK_ALIGNMENT-1)&~u64(TEXTURE_BULK_ALIGNMENT-1)
        if u64(mip.offset)!=offset {return false}
        end=offset+u64(mip.size)
    }
    return end<=u64(max(u32))
}

texture_check :: proc(view:Texture_View) -> bool {
    if !texture_levels_check(view.info,view.mips) || view.first<0 ||
        view.last>len(view.mips) || view.first>=view.last {return false}
    for level in view.first..<view.last {
        if len(texture_mip(view,level))==0 {return false}
    }
    return true
}
