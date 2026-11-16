package asset

import "mirai:std/base"

// .sound: audio ready to play.
//
//   sound            Sound_Info, one row
//   lossless  bulk   16 bit samples coded without loss (audio/lossless.odin)
//   file      bulk   bytes of a WAV or Ogg Vorbis file
//
// A sound has one of the two bulk tables. Either is decoded whole when the
// sound loads, or a little ahead of what plays when it has the Stream flag.

SOUND_VERSION :: 3
SOUND_BULK_ALIGNMENT :: 16
SOUND_MAX_SAMPLE_RATE :: 384000

Sound_Encoding :: enum u8 {
    Lossless, // lossless
    File,     // file
}
Sound_Flag :: enum u8 {
    Stream, // decoded a little ahead of what plays instead of whole when loaded
}
Sound_Flags :: bit_set[Sound_Flag;u32]

Sound_Info :: struct {
    channels:u32,    // 1 or 2
    sample_rate:u32, // Hz
    frames:u32,      // 0: a file that does not say
    loop_start:u32,  // the frame a loop goes back to at the end: the body after an intro; 0 loops it whole
    encoding:Sound_Encoding,
    flags:Sound_Flags,
}

Sound_Desc :: struct {
    id:base.Asset_Id,
    owner:base.Asset_Id, // the asset it is a part of: the prefab of the import that made it
    channels,sample_rate,frames:int,
    loop_start:int,
    lossless:[]u8, // Lossless: what audio.lossless_encode wrote
    file:[]u8,     // File
    flags:Sound_Flags,
    source:^Import_Info,
    compression:Compression,
}

Sound_View :: struct {
    info:^Sound_Info,
    lossless:[]u8,
    file:[]u8,
    source:^Import_Info,
}

sound_document :: proc(doc:^Document,types:^Types,desc:Sound_Desc,allocator:=context.allocator) -> Error {
    if desc.frames<0 || desc.frames>int(max(u32)) || desc.loop_start<0 || desc.loop_start>int(max(u32)) || desc.sample_rate<0 || desc.sample_rate>SOUND_MAX_SAMPLE_RATE || desc.channels<0 || desc.channels>2 {return .Invalid}
    info:=Sound_Info{channels=u32(desc.channels),sample_rate=u32(desc.sample_rate),frames=u32(desc.frames),loop_start=u32(desc.loop_start),flags=desc.flags,encoding=len(desc.file)>0?.File:.Lossless}
    if !sound_check({info=&info,lossless=desc.lossless,file=desc.file}) {return .Invalid}
    document_init(doc,KIND_SOUND,desc.id,allocator)
    doc.owner=desc.owner
    doc.kind_version=SOUND_VERSION
    error:=sound_tables(doc,types,&info,desc)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
sound_tables :: proc(doc:^Document,types:^Types,info:^Sound_Info,desc:Sound_Desc) -> Error {
    document_put_row(doc,types,"sound",info) or_return
    import_put(doc,types,desc.source) or_return
    if info.encoding==.File {
        document_put(doc,types,"file",desc.file,{.Bulk},desc.compression,SOUND_BULK_ALIGNMENT) or_return
    } else {
        document_put(doc,types,"lossless",desc.lossless,{.Bulk},desc.compression,SOUND_BULK_ALIGNMENT) or_return
    }
    return .None
}

sound_save :: proc(path:string,types:^Types,desc:Sound_Desc,allocator:=context.allocator) -> Error {
    doc:Document
    sound_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_save(&doc,path)
}

sound_view :: proc(a:^Asset,types:^Types) -> (view:Sound_View,error:Error) {
    kind_check(a,KIND_SOUND,SOUND_VERSION) or_return
    view.info=asset_row(a,types,"sound",Sound_Info) or_return
    view.lossless=table_rows(a,types,"lossless",u8) or_return
    view.file=table_rows(a,types,"file",u8) or_return
    view.source=import_info(a,types) or_return
    if !sound_check(view) {return {},.Corrupt}
    return view,.None
}

sound_check :: proc(view:Sound_View) -> bool {
    info:=view.info
    if info==nil || info.channels<1 || info.channels>2 || info.sample_rate==0 || info.sample_rate>SOUND_MAX_SAMPLE_RATE {return false}
    if info.frames>0 && info.loop_start>=info.frames {return false}
    switch info.encoding {
    case .Lossless:
        // The coding checks the rest as it opens.
        return len(view.file)==0 && len(view.lossless)>=4 && string(view.lossless[:4])=="MLPC"
    case .File:
        if len(view.lossless)!=0 || len(view.file)<12 {return false}
        head:=string(view.file[:4])
        return head=="OggS" || head=="RIFF" && string(view.file[8:12])=="WAVE"
    }
    return false
}
