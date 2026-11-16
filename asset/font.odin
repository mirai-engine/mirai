package asset

import "mirai:std/base"

// .font: a font for the interfaces of a game.
//
//   font   Font_Info, one row
//   file   bulk   the bytes of a TrueType or OpenType file: one font, not a collection
//
// The interfaces keep the bytes while they show the font (ui.font_add).

FONT_VERSION :: 1
FONT_BULK_ALIGNMENT :: 4

Font_Outlines :: enum u8 {
    TrueType, // glyf: sfnt version 0x00010000 or 'true'
    CFF,      // PostScript: sfnt version 'OTTO'
}

Font_Info :: struct {
    outlines:Font_Outlines,
}

Font_Desc :: struct {
    id:base.Asset_Id,
    owner:base.Asset_Id,
    file:[]u8,
    source:^Import_Info,
    compression:Compression,
}

Font_View :: struct {
    info:^Font_Info,
    file:[]u8,
    source:^Import_Info,
}

// What the first bytes of a font file say its outlines are. found is false
// for anything else, a collection ('ttcf') among them.
font_outlines :: proc "contextless" (file:[]u8) -> (outlines:Font_Outlines,found:bool) {
    if len(file)<12 {return}
    switch string(file[:4]) {
    case "\x00\x01\x00\x00","true": return .TrueType,true
    case "OTTO":                     return .CFF,true
    }
    return
}

font_document :: proc(doc:^Document,types:^Types,desc:Font_Desc,allocator:=context.allocator) -> Error {
    outlines,found:=font_outlines(desc.file)
    if !found {return .Invalid}
    info:=Font_Info{outlines=outlines}
    document_init(doc,KIND_FONT,desc.id,allocator)
    doc.owner=desc.owner
    doc.kind_version=FONT_VERSION
    error:=font_tables(doc,types,&info,desc)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
font_tables :: proc(doc:^Document,types:^Types,info:^Font_Info,desc:Font_Desc) -> Error {
    document_put_row(doc,types,"font",info) or_return
    import_put(doc,types,desc.source) or_return
    document_put(doc,types,"file",desc.file,{.Bulk},desc.compression,FONT_BULK_ALIGNMENT) or_return
    return .None
}

font_bytes :: proc(types:^Types,desc:Font_Desc,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    doc:Document
    font_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_bytes(&doc,allocator)
}

font_save :: proc(path:string,types:^Types,desc:Font_Desc,allocator:=context.allocator) -> Error {
    doc:Document
    font_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_save(&doc,path)
}

font_view :: proc(a:^Asset,types:^Types) -> (view:Font_View,error:Error) {
    kind_check(a,KIND_FONT,FONT_VERSION) or_return
    view.info=asset_row(a,types,"font",Font_Info) or_return
    view.file=table_rows(a,types,"file",u8) or_return
    view.source=import_info(a,types) or_return
    if !font_check(view) {return {},.Corrupt}
    return view,.None
}

// Whether the file is a font of the outlines the row says.
font_check :: proc(view:Font_View) -> bool {
    if view.info==nil {return false}
    outlines,found:=font_outlines(view.file)
    return found && outlines==view.info.outlines
}
