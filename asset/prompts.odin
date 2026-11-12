package asset

import "mirai:std/base"
import "mirai:std/serial"

// .prompts: a pack of the images of the prompts of inputs, as the devices of
// each family show them.
//
//   prompts   Prompt_Image: the part of a texture that shows an input of a family
//
// Keys and the mouse are of the family Keyboard. A family and an input are
// stored as numbers: those of ui.Prompt_Family and ui.Prompt_Input, which
// this package does not import (host/content.odin checks that they match).

PROMPTS_VERSION :: 1
PROMPT_FAMILIES :: 4 // len(ui.Prompt_Family)
PROMPT_INPUTS :: 26  // len(ui.Prompt_Input)
PROMPT_INPUT_KEY :: 0 // ui.Prompt_Input.Key: the input that names a key

Prompt_Uv :: struct {x,y,w,h:f32}

Prompt_Image :: struct {
    family:u8,                 // ui.Prompt_Family
    input:u8,                  // ui.Prompt_Input
    key:[32]u8 `mirai:"text"`, // of the input Key: the name of a core.Key ("A", "Space", "Left_Shift")
    texture:base.Asset_Id,
    uv:Prompt_Uv,              // the part of the texture, from its top left, in [0,1]
    aspect:f32,                // width over height of that part, in pixels
}

Prompts_Desc :: struct {
    id:base.Asset_Id,
    owner:base.Asset_Id,
    images:[]Prompt_Image,
    source:^Import_Info,
}

Prompts_View :: struct {
    images:[]Prompt_Image,
    source:^Import_Info,
}

prompts_document :: proc(doc:^Document,types:^Types,desc:Prompts_Desc,allocator:=context.allocator) -> Error {
    if !prompts_check({images=desc.images}) {return .Invalid}
    document_init(doc,KIND_PROMPTS,desc.id,allocator)
    doc.owner=desc.owner
    doc.kind_version=PROMPTS_VERSION
    error:=prompts_tables(doc,types,desc)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
prompts_tables :: proc(doc:^Document,types:^Types,desc:Prompts_Desc) -> Error {
    document_put(doc,types,"prompts",desc.images,{},.Stream) or_return
    return import_put(doc,types,desc.source)
}

prompts_save :: proc(path:string,types:^Types,desc:Prompts_Desc,allocator:=context.allocator) -> Error {
    doc:Document
    prompts_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_save(&doc,path)
}

prompts_view :: proc(a:^Asset,types:^Types) -> (view:Prompts_View,error:Error) {
    kind_check(a,KIND_PROMPTS,PROMPTS_VERSION) or_return
    view.images=table_rows(a,types,"prompts",Prompt_Image) or_return
    view.source=import_info(a,types) or_return
    if !prompts_check(view) {return {},.Corrupt}
    return view,.None
}

// Whether every image is of a family and an input that exist, names a key
// for the input Key and none for the others, shows a part of a texture with
// an aspect, and no two show the same input.
prompts_check :: proc(view:Prompts_View) -> bool {
    for &image,at in view.images {
        if image.family>=PROMPT_FAMILIES || image.input>=PROMPT_INPUTS || image.texture=={} {return false}
        key:=serial.text_field(image.key[:])
        if len(key)>=len(image.key) || (key!="")!=(image.input==PROMPT_INPUT_KEY) {return false}
        uv:=image.uv
        if !finite(uv.x,uv.y,uv.w,uv.h,image.aspect) || uv.x<0 || uv.y<0 || uv.w<=0 || uv.h<=0 || uv.x+uv.w>1 || uv.y+uv.h>1 || image.aspect<=0 {return false}
        for &earlier in view.images[:at] {
            if earlier.family==image.family && earlier.input==image.input && serial.text_field(earlier.key[:])==key {return false}
        }
    }
    return true
}
