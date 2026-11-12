package asset

import "core:mem"
import "compressor:data"
import "compressor:texture"
import "mirai:std/base"

// .tex: an image ready for the GPU.
//
//   texture         Texture_Info, one row
//   mips            Texture_Mip: where each level is inside texels, level 0 first
//   texels   bulk   bytes of every level, the smallest first, each one starting at
//                   a multiple of 16, a stream: the small levels decode from its
//                   first pieces without the others (texture_decode)
//   layouts         Texture_Layout_Run, of a texture whose texels are payloads of
//                   layouts of the compressor (texture.Layout), each of a run of
//                   levels: by their largest level, level 0 first; in texels the
//                   smallest first, one after another
//
// A level is half the one above, rounded down, and never smaller than 1. It
// holds its layers one after another: the images of an array, or the faces
// of its cubes. Block formats store 4x4 blocks: BC1 in 8 bytes, BC3, BC5,
// BC6H and BC7 in 16. With the flag Fields, each level of BC1, BC3 or BC5
// stores the fields of its blocks one plane after another
// (texture_fields_split).

TEXTURE_VERSION :: 3
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
    BC3,     // rgba: data maps with alpha
    BC5,     // two channels: tangent-space normals
    BC7,     // color, with or without alpha
    RGBA16,  // 16-bit channels, linear: data that keeps its precision
    RGBA16F, // half floats, linear: HDR with alpha, negative values or kept uncompressed
    BC6H,    // rgb half floats without sign, linear: HDR light and color
}

Texture_Flag :: enum u8 {
    Srgb,       // color: stored as sRGB in RGBA8, BC1, BC3 and BC7, linear in the others; filtered as light
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
    size:u32,   // of every layer
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
    layouts:[]Texture_Layout, // its runs of levels by their largest level, from blocks.layout_encode of the compressor: only for a document that compresses with the best codecs
}

// The blocks of a run of levels as a layout of the compressor rearranges them so that they
// compress smaller, stored in place of the blocks: from level down to the one above the level of
// the next run, the smallest first. A layout restores only whole, so the levels a read takes
// together share one.
Texture_Layout :: struct {
    layout:texture.Layout,
    header:texture.Layout_Header,
    level:int,
    payload:[]u8,
}

Texture_Layout_Run :: struct {
    layout:texture.Layout,
    level:u32,
    header:texture.Layout_Header,
}

Texture_View :: struct {
    info:^Texture_Info,
    mips:[]Texture_Mip,
    texels:[]u8,
    source:^Import_Info,
    first:int, // the first level texels holds: those before it were not decoded
}

// Bytes of one image of a level of a size, in a format.
texture_level_size :: proc "contextless" (format:Texture_Format,width,height:int) -> int {
    switch format {
    case .RGBA8: return width*height*4
    case .RGBA16,.RGBA16F: return width*height*8
    case .BC1: return ((width+3)/4)*((height+3)/4)*8
    case .BC3,.BC5,.BC6H,.BC7: return ((width+3)/4)*((height+3)/4)*16
    }
    return 0
}

// Bytes of a 4x4 block of a block format; 0 for the others.
texture_block_bytes :: proc "contextless" (format:Texture_Format) -> int {
    #partial switch format {
    case .BC1: return 8
    case .BC3,.BC5,.BC6H,.BC7: return 16
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

texture_document :: proc(doc:^Document,types:^Types,desc:Texture_Desc,allocator:=context.allocator) -> Error {
    if desc.width<=0 || desc.height<=0 || desc.width>TEXTURE_MAX_SIZE || desc.height>TEXTURE_MAX_SIZE {return .Invalid}
    layers:=max(desc.layers,1)
    if desc.layers<0 || !texture_layers_valid(layers,desc.width,desc.height,desc.flags) {return .Invalid}
    if len(desc.mips)==0 || len(desc.mips)>texture_mip_count(desc.width,desc.height) || !finite(desc.alpha_coverage) {return .Invalid}
    info:=Texture_Info{width=u32(desc.width),height=u32(desc.height),mip_count=u32(len(desc.mips)),format=desc.format,flags=desc.flags-{.Fields},alpha_coverage=desc.alpha_coverage,layers=u32(layers)}
    mips:[TEXTURE_MAX_MIPS]Texture_Mip
    total:=0
    #reverse for level,i in desc.mips {
        width,height:=max(desc.width>>uint(i),1),max(desc.height>>uint(i),1)
        if len(level)!=texture_level_size(desc.format,width,height)*layers {return .Invalid}
        total=(total+TEXTURE_BULK_ALIGNMENT-1)&~int(TEXTURE_BULK_ALIGNMENT-1)
        if total+len(level)>int(max(u32)) {return .Invalid}
        mips[i]={u32(width),u32(height),u32(total),u32(len(level))}
        total+=len(level)
    }
    if len(desc.layouts)>0 {
        if texture_block_bytes(desc.format)!=16 || len(desc.layouts)>len(desc.mips) || desc.layouts[0].level!=0 {return .Invalid}
        total=0
        for run,i in desc.layouts {
            last:=desc.layouts[i+1].level-1 if i+1<len(desc.layouts) else len(desc.mips)-1
            if run.level<0 || run.level>last || last>=len(desc.mips) {return .Invalid}
            blocks,size,read_error:=texture.layout_read(run.layout,run.header)
            span:=0
            for level in desc.mips[run.level:last+1] {span+=len(level)}
            if read_error!=.None || blocks*16!=span || size!=len(run.payload) {return .Invalid}
            total+=size
        }
    }
    document_init(doc,KIND_TEXTURE,desc.id,allocator)
    doc.owner=desc.owner
    doc.kind_version=TEXTURE_VERSION
    error:=texture_tables(doc,types,&info,mips[:len(desc.mips)],total,desc)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
texture_tables :: proc(doc:^Document,types:^Types,info:^Texture_Info,mips:[]Texture_Mip,total:int,desc:Texture_Desc) -> Error {
    texels:=document_table_add(doc,"texels",{.Bulk}) or_return
    document_resize(doc,texels,total) or_return
    byte,_:=document_type(doc,types,u8)
    // Layouts restore only with the compressor that wrote them.
    laid:=len(desc.layouts)>0
    if laid && doc.codecs!=.Best {return .Invalid}
    column:=document_column_add(doc,texels,"",byte,{},.Stream,TEXTURE_BULK_ALIGNMENT) or_return
    bytes:=doc.tables[texels].columns[column].data[:]
    if laid {
        at:=0
        #reverse for run in desc.layouts {at+=copy(bytes[at:],run.payload)}
    } else {
        for level,i in desc.mips {copy(bytes[mips[i].offset:],level)}
        if doc.codecs!=.None && texture_fields_format(desc.format) && .Fast not_in desc.flags && (texture_fields_smaller(desc.format,mips,bytes,doc.codecs,doc.allocator) or_return) {
            info.flags+={.Fields}
            for level,i in desc.mips {texture_fields_split(desc.format,level,bytes[mips[i].offset:][:mips[i].size])}
        }
    }
    document_put_row(doc,types,"texture",info) or_return
    document_put(doc,types,"mips",mips) or_return
    import_put(doc,types,desc.source) or_return
    if laid {
        runs,alloc_error:=make([]Texture_Layout_Run,len(desc.layouts),doc.allocator)
        if alloc_error!=nil {return .Out_Of_Memory}
        defer delete(runs,doc.allocator)
        for run,i in desc.layouts {runs[i]={run.layout,u32(run.level),run.header}}
        document_put(doc,types,TEXTURE_TABLE_LAYOUTS,runs) or_return
    }
    return .None
}

// Whether the levels of texels, laid out as mips say, compress smaller as planes of their fields
// in what an edit with codecs writes, which picks what a cook writes too in all but a few. A tie
// keeps the blocks.
@(private="file")
texture_fields_smaller :: proc(format:Texture_Format,mips:[]Texture_Mip,texels:[]u8,codecs:Codecs,allocator:mem.Allocator) -> (smaller:bool,error:Error) {
    if len(texels)==0 {return false,.None}
    split,split_error:=make([]u8,len(texels),allocator)
    if split_error!=nil {return false,.Out_Of_Memory}
    defer delete(split,allocator)
    copy(split,texels)
    for mip in mips {texture_fields_split(format,texels[mip.offset:][:mip.size],split[mip.offset:][:mip.size])}
    out,out_error:=make([]u8,pack_bound(len(texels)),allocator)
    if out_error!=nil {return false,.Out_Of_Memory}
    defer delete(out,allocator)
    encoder:Stream_Encoder
    stream_encoder_init(&encoder,allocator) or_return
    defer stream_encoder_destroy(&encoder)
    sizes:[2]int
    for bytes,i in ([2][]u8{texels,split}) {sizes[i]=pack(&encoder,.Fast,codecs,bytes,out) or_return}
    return sizes[1]<sizes[0],.None
}

texture_save :: proc(path:string,types:^Types,desc:Texture_Desc,allocator:=context.allocator,profile:=data.Profile.Fast) -> Error {
    doc:Document
    texture_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_save(&doc,path,profile=profile)
}

// The file of a texture with its blocks as they are, without layouts of the compressor, the planes
// of their fields where those compress smaller, compressed with profile as the codecs of types
// allow. bytes is the file it is now.
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
    texture_document(&doc,types,{id=file.blob.header.id,owner=file.blob.header.owner,width=int(info.width),height=int(info.height),layers=int(info.layers),format=info.format,flags=info.flags,alpha_coverage=info.alpha_coverage,mips=mips,source=view.source},context.temp_allocator) or_return
    defer document_destroy(&doc)
    doc.flags=file.blob.header.flags
    return document_bytes(&doc,allocator,profile)
}

TEXTURE_TABLE_LAYOUTS :: "layouts"

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
    view.first=len(view.mips)
    return view,.None
}

// Decodes into memory of the asset the levels of an open texture from the
// level from to the last, its smallest: those lie at the start of the stream,
// and only the pieces that hold them decode. Restores the blocks of their
// fields and of their layouts, which restore whole: one that holds from
// restores from its largest level, which becomes view.first.
texture_decode :: proc(a:^Asset,types:^Types,view:^Texture_View,from:int) -> Error {
    if !texture_levels_check(view.info,view.mips) {return .Invalid}
    from:=clamp(from,0,len(view.mips)-1)
    mips,info:=view.mips,view.info
    table,found:=asset_table(a,"texels")
    if !found {return .Not_Found}
    column,column_found:=table_column(table,"")
    if !column_found {return .Not_Found}
    byte,known:=types_index(types,u8)
    if !known {return types.error}
    if !asset_column_matches(a,table,column,types.hashes[byte]) {return .Corrupt}
    // The bytes the levels from `from` take once restored, and those of the stream that hold them.
    end:=0
    for mip in mips[from:] {end=max(end,int(mip.offset)+int(mip.size))}
    stored:=end
    runs:[]Texture_Layout_Run
    // Of each run: where its payload starts in texels, its size, and where its blocks start and
    // how many bytes they take once restored.
    payloads,sizes,restores,spans:[TEXTURE_MAX_MIPS]int
    if _,laid:=asset_table(a,TEXTURE_TABLE_LAYOUTS);laid {
        runs=asset_rows(a,types,TEXTURE_TABLE_LAYOUTS,"",Texture_Layout_Run) or_return
        if texture_block_bytes(info.format)!=16 || .Fields in info.flags || len(runs)==0 || len(runs)>len(mips) || runs[0].level!=0 {return .Corrupt}
        at:=0
        #reverse for run,i in runs {
            last:=int(runs[i+1].level)-1 if i+1<len(runs) else len(mips)-1
            if int(run.level)>last {return .Corrupt}
            // Levels of blocks of 16 bytes are whole multiples of 16: a run of them lies with no gap between.
            largest,smallest:=mips[run.level],mips[last]
            blocks,size,read_error:=texture.layout_read(run.layout,run.header)
            if read_error==.Unknown_Format {return .Codec_Missing}
            if read_error!=.None || u64(smallest.offset)+u64(blocks)*16!=u64(largest.offset)+u64(largest.size) {return .Corrupt}
            payloads[i],sizes[i],restores[i],spans[i]=at,size,int(smallest.offset),blocks*16
            at+=size
            if int(run.level)<=from && from<=last {
                from=int(run.level)
                stored,end=at,int(largest.offset)+int(largest.size)
            }
        }
        if at!=table.rows {return .Corrupt}
    } else if end>table.rows {return .Corrupt}
    if .Fields in info.flags && !texture_fields_format(info.format) {return .Corrupt}
    data,owned:=texels_read(a,table,column,stored) or_return
    switch {
    case runs!=nil:
        restored:=asset_alloc(a,end,TEXTURE_BULK_ALIGNMENT) or_return
        decoder:=asset_decoder(a) or_return
        for run,i in runs {
            if int(run.level)<from {continue}
            switch texture.layout_decode(decoder.layout,run.layout,run.header,data[payloads[i]:][:sizes[i]],restored[restores[i]:][:spans[i]]) {
            case .None:
            case .Unknown_Format: return .Codec_Missing
            case .Out_Of_Memory: return .Out_Of_Memory
            case .Corrupt: return .Corrupt
            }
        }
        data=restored
    case .Fields in info.flags && owned:
        largest:=0
        for mip in mips[from:] {largest=max(largest,int(mip.size))}
        planes,alloc_error:=make([]u8,largest,a.allocator)
        if alloc_error!=nil {return .Out_Of_Memory}
        defer delete(planes,a.allocator)
        for mip in mips[from:] {
            level:=data[mip.offset:][:mip.size]
            copy(planes,level)
            texture_fields_join(info.format,planes[:mip.size],level)
        }
    case .Fields in info.flags:
        joined:=asset_alloc(a,end,TEXTURE_BULK_ALIGNMENT) or_return
        for mip in mips[from:] {texture_fields_join(info.format,data[mip.offset:][:mip.size],joined[mip.offset:][:mip.size])}
        data=joined
    }
    view.texels,view.first=data[:end],from
    return .None
}

// The first size bytes of the texels column: when the chunk is a stream and
// they are fewer than all, only the pieces that hold them decode. owned: the
// bytes are memory of the asset that nothing else reads.
@(private="file")
texels_read :: proc(a:^Asset,table:^Asset_Table,column:int,size:int) -> (data:[]u8,owned:bool,error:Error) {
    if size==0 {return nil,false,.None}
    entry:=blob_chunk(&a.blob,table.columns[column].chunk)
    if entry.compression==.None || table.columns[column].ready {
        data=asset_column_data(a,table,column) or_return
        return data[:size],false,.None
    }
    if entry.offset+entry.size>u64(len(a.blob.data)) {return nil,false,.Truncated}
    total:=int(entry.uncompressed_size)
    if total!=table.rows || size>total {return nil,false,.Corrupt}
    decoded:=total
    // A stream restores whole pieces.
    if size<total {decoded=min(total,(size+PACK_PIECE-1)/PACK_PIECE*PACK_PIECE)}
    data=asset_alloc(a,decoded,TEXTURE_BULK_ALIGNMENT) or_return
    decoder:=asset_decoder(a) or_return
    if decoded==total {blob_read(&a.blob,entry,data,decoder) or_return}
    else {stream_unpack(&decoder.stream,blob_stored(&a.blob,entry),data,total) or_return}
    return data[:size],true,.None
}

// The bytes of a level, with every layer; empty for one before view.first.
texture_mip :: proc(view:Texture_View,level:int) -> []u8 {
    if level<view.first {return nil}
    mip:=view.mips[level]
    return view.texels[mip.offset:][:mip.size]
}

// The bytes of one layer of a level; empty for one before view.first.
texture_layer :: proc(view:Texture_View,level,layer:int) -> []u8 {
    if level<view.first {return nil}
    mip:=view.mips[level]
    size:=int(mip.size)/int(view.info.layers)
    return view.texels[int(mip.offset)+layer*size:][:size]
}

// Whether the info and the levels of a texture agree: sizes, format, layers
// and the size of each level.
texture_levels_check :: proc(info:^Texture_Info,mips:[]Texture_Mip) -> bool {
    if info==nil || info.width==0 || info.height==0 || info.width>TEXTURE_MAX_SIZE || info.height>TEXTURE_MAX_SIZE {return false}
    if info.format>max(Texture_Format) || !finite(info.alpha_coverage) {return false}
    if !texture_layers_valid(int(info.layers),int(info.width),int(info.height),info.flags) {return false}
    if int(info.mip_count)!=len(mips) || len(mips)==0 || len(mips)>texture_mip_count(int(info.width),int(info.height)) {return false}
    for mip,i in mips {
        width,height:=max(int(info.width)>>uint(i),1),max(int(info.height)>>uint(i),1)
        if int(mip.width)!=width || int(mip.height)!=height || int(mip.size)!=texture_level_size(info.format,width,height)*int(info.layers) {return false}
    }
    return true
}

// texture_levels_check, and the levels from view.first inside the texels.
texture_check :: proc(view:Texture_View) -> bool {
    if !texture_levels_check(view.info,view.mips) || view.first<0 || view.first>=len(view.mips) {return false}
    for mip in view.mips[view.first:] {
        if u64(mip.offset)+u64(mip.size)>u64(len(view.texels)) {return false}
    }
    return true
}
