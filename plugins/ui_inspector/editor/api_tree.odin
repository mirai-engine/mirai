package ui_inspector_editor

import "core:strings"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// Agents author interfaces as the document does: ui.inspect gives a .ui, or
// one of its nodes, as a document and ui.write makes the file say what a
// document declares. The document is read and written below the editor
// (cook/author); here its methods find the file among the assets of the
// session and write it as a step of its history. A node is named by its name,
// or by "#row". Each call is one step of the history of the file, which waits
// for Save; a call that would leave a tree that does not load changes nothing
// and says why.

@(storage)
Ui_Tree_Api :: struct {provider:editor.Api_Provider}
ui_tree_api_default :: proc() -> Ui_Tree_Api {return {provider={register=tree_api_register}}}

@(private) TREE_ASSET_SCHEMA :: `"asset":{"type":"string","description":"the path of a .ui of the project (hud/hud.ui), or its id"}`
@(private) TREE_INSPECT_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["asset"],"properties":{` + TREE_ASSET_SCHEMA + `,"node":{"type":"string","description":"name or #row: that node and what it holds, with the styles and animations they take; absent: the whole file"}}}`
@(private) TREE_WRITE_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["asset","document"],"properties":{` + TREE_ASSET_SCHEMA + `,"node":{"type":"string","description":"name or #row: the document declares that node and what it holds, and nothing else of the file changes; absent: the whole file"},"document":{"type":"object","description":"as ui.inspect gives it: use (paths of the .ui it takes styles and tokens from, and widgets), params of the widget this file is (name to node.field, node.parameter of a use, or field of its root), tokens, styles and animations by name, and nodes nested, each {name, kind (a Node_Kind, or the name of the file of a widget it uses), text, translations (its text in the other languages of the game, language code to text), style, the keys of its layout (width, height, gap...), events, slot, children}; a use also the parameters of its widget. tokens, styles and animations it names become what it says, null takes one away, the others stay; the nodes of the file, or of node, become these, matched by name and kind. Without nodes, no node changes"},"save":{"type":"boolean","description":"writes the file now, as asset.save does, instead of leaving it for Save; a path that does not exist yet makes the .ui"}}}`

// Bytes of a text of a result that no capacity of its own bounds.
@(private) RESULT_TEXT_BYTES :: 256*1024

Ui_Ok :: struct {ok:bool}

Tree_Inspect :: struct {
    document:Tree_Document `mirai:"label=What ui.write takes back"`,
}
Tree_Document :: struct {
    use:serial.Json `mirai:"optional,label=The paths of the .ui it takes styles and tokens from and whose widgets its nodes name by the name of their file"`,
    params:serial.Json `mirai:"optional,label=What the widget of this file takes, by name: node.field, node.parameter of a use it holds, or the field of its root"`,
    tokens:serial.Json `mirai:"optional,label=By name: a color or a number that styles name"`,
    styles:serial.Json `mirai:"label=The named styles, or those its nodes take, by name: extends, family, defaults (the kinds whose new nodes take it), its keys (fill, size, width, shadow...), the states hover, focus, pressed, disabled, selected and over, variants by name, and rules {variant, states, tokens and the keys of a state}"`,
    animations:serial.Json `mirai:"label=By name: kind, loop, and from-to properties with seconds and ease, tracks of a Clip or parts of a Sequence or a Parallel"`,
    nodes:[]Tree_Document_Node `mirai:"label=The roots in order, each also with the keys of ui.Tree_Node and of its layout that differ from a new node of its kind, and a use with the parameters of its widget; with node, that node alone"`,
}
Tree_Document_Node :: struct {
    name:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,label=What ui.write matches it by"`,
    kind:serial.Json `mirai:"optional,label=A ui.Node_Kind, or the name of the file of a widget it uses"`,
    text:[RESULT_TEXT_BYTES]u8 `mirai:"text,optional,label=In the language interfaces are written in"`,
    style:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,optional,label=The named style it takes; empty: none, where its kind would take one; absent: the one its kind takes"`,
    look:serial.Json `mirai:"optional,label=Its own look, instead of style: a style without family; with extends it says what it changes of that style, which it follows otherwise"`,
    image:ui.Tree_Image `mirai:"optional"`,
    events:serial.Json `mirai:"optional,label=By trigger (shown, hovered, clicked, ...): the animation it plays"`,
    slot:bool `mirai:"optional,label=Whether it takes what a use of this widget holds"`,
    children:serial.Json `mirai:"optional,label=The nodes it holds, in order, as this one"`,
}

@(private)
tree_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="ui.inspect",summary="A .ui, or one of its nodes, as the document ui.write takes back: its nodes nested, each with what differs from a new node of its kind, and the styles and animations they take.",params_schema=TREE_INSPECT_SCHEMA,result=Tree_Inspect,result_info=type_info_of(Tree_Inspect),writes_result=true,flags={.Read_Only},run=api_tree_inspect})
    editor.api_method_register(s,{name="ui.write",summary="Makes a .ui, or one of its nodes, say what a document declares, as ui.inspect gives it; a widget is a .ui of its own and another uses it by name through use. Nodes are matched by name, the others are made and those it does not declare go; a node says its text in the other languages of the game in translations, by language code. A path its nodes bind that the game of this build lacks fails with what the game has there, and changes nothing. One step of history; the file waits for Save, or for save:true. On the command line document=@file reads it from a file, and a path that does not exist yet makes the .ui.",params_schema=TREE_WRITE_SCHEMA,result=Tree_Write_Answer,result_info=type_info_of(Tree_Write_Answer),run=api_tree_write})
    capture_api_register(s)
}

// ---------------------------------------------------------------- reading params

// What reads the params of a call below the editor; call_read gives the call
// what it failed with.
@(private)
call_reading :: proc(call:^api.Call) -> author.Reading {
    reading:=author.Reading{allocator=call.allocator,raw=call.raw}
    if call.server!=nil {reading.assets=call.server.assets}
    return reading
}

// False after failing the call with what the reading failed with.
@(private)
call_read :: proc(call:^api.Call,reading:^author.Reading) -> bool {
    if !reading.failed {return true}
    if !call.failed {api.call_fail(call,api.SERVER_ERROR if reading.internal else api.INVALID_PARAMS,reading.problem)}
    return false
}

@(private)
tree_args :: proc(s:^editor.Session,reading:^author.Reading) -> (args:author.Tree_Args,ok:bool) {
    return author.tree_args(reading,author.assets_of(s.app.assets),s.app.info)
}

// The records of the .ui the params name.
@(private)
tree_open :: proc(s:^editor.Session,call:^api.Call,args:^author.Tree_Args,records:^author.Records) -> (id:base.Asset_Id,ok:bool) {
    text,found,read:=author.tree_arg_string(args,"asset")
    if !read {return}
    if !found {api.call_fail(call,api.INVALID_PARAMS,"asset is required: the path of a .ui of the project or its id");return}
    problem:string
    if id,problem=editor.asset_resolve(s,tree_asset_path(text),".ui");problem!="" {api.call_failf(call,api.INVALID_PARAMS,"asset: %s",problem);return}
    if !author.records_read(author.assets_of(s.app.assets),id,records,context.temp_allocator) {
        api.call_failf(call,api.INVALID_PARAMS,"asset %s is not a .ui that loads; pass the path of a .ui of the project or its id",text)
        return
    }
    args.asset=id
    return id,true
}

// ---------------------------------------------------------------- inspect

@(private)
api_tree_inspect :: proc(s:^editor.Session,call:^api.Call) {
    reading:=call_reading(call)
    defer call_read(call,&reading)
    args,args_ok:=tree_args(s,&reading)
    if !args_ok {return}
    r:author.Records
    _,opened:=tree_open(s,call,&args,&r)
    if !opened {return}
    root,root_ok:=author.tree_arg_row(&args,&r,"node")
    if !root_ok {return}
    a:=author.assets_of(s.app.assets)
    out:=call.out
    libs:=author.doc_libs(&args,&r)
    serial.write_u8(out,'{')
    api.write_key(out,"document",true)
    author.document_write(out,a.types,&r,root,libs[:],a)
    serial.write_u8(out,'}')
}

Tree_Write_Answer :: struct {
    ok:bool,
    made:int `mirai:"label=Nodes the document made"`,
    removed:int `mirai:"label=Nodes it took away, with what they held"`,
}

@(private)
api_tree_write :: proc(s:^editor.Session,call:^api.Call) {
    reading:=call_reading(call)
    defer call_read(call,&reading)
    args,args_ok:=tree_args(s,&reading)
    if !args_ok {return}
    for key in args.keys {
        if key!="asset" && key!="node" && key!="document" && key!="save" {api.call_failf(call,api.INVALID_PARAMS,"ui.write has no '%s'; it has asset, node, document and save",key);return}
    }
    text,found:=author.tree_arg(&args,"document")
    if !found {api.call_fail(call,api.INVALID_PARAMS,"document is required: as ui.inspect gives it, with what it declares; on the command line document=@file reads it from a file");return}
    save,save_ok:=author.tree_arg_bool(&args,"save")
    if !save_ok {return}
    if save && !editor.api_guard(s,call) {return}
    // A path that names nothing yet makes the .ui, once its document reads
    // and its tree is known to load: a refused one leaves no file.
    path,fresh,named:=tree_asset_new(s,&args)
    if !named {return}
    r:author.Records
    id:base.Asset_Id
    if fresh {
        id=editor.asset_id_new(s)
        if !author.records_load(&r,author.ui_empty_data(),context.temp_allocator) {api.call_fail(call,api.SERVER_ERROR,"the .ui could not be made: memory ran out");return}
        args.asset=id
    } else {
        opened:bool
        if id,opened=tree_open(s,call,&args,&r);!opened {return}
    }
    root,root_ok:=author.tree_arg_row(&args,&r,"node")
    if !root_ok {return}
    made,removed,applied:=author.document_apply(&args,&r,root,text)
    if !applied {return}
    a:=author.assets_of(s.app.assets)
    api_flush(s)
    params:=author.widget_params(a,id)
    bytes,imports,loads:=author.document_bytes(&args,id,&r)
    if !loads {return}
    if fresh {
        if problem:=editor.asset_create(s,asset.KIND_UI,path,id);problem!="" {api.call_failf(call,api.INVALID_PARAMS,"asset: %s",problem);return}
    }
    if problem,written:=records_file_write(s,id,&r,bytes,imports,params,"Write");!written {api.call_failf(call,api.SERVER_ERROR,"%s. Nothing changed",problem);return}
    if save {
        record,recorded:=asset.registry_find(&s.app.assets.registry,id)
        if !recorded {api.call_fail(call,api.SERVER_ERROR,"the .ui it wrote is not in the assets");return}
        if _,failures:=editor.assets_write(s,{record.path});failures!="" {api.call_failf(call,api.SERVER_ERROR,"the .ui stays unsaved: %s",failures);return}
    }
    api.call_result(call,Tree_Write_Answer)^={ok=true,made=made,removed=removed}
}

// Whether the params name the path of a .ui that does not exist yet: the one
// the write makes. ok false after failing the call.
@(private)
tree_asset_new :: proc(s:^editor.Session,args:^author.Tree_Args) -> (path:string,fresh,ok:bool) {
    text,_,read:=author.tree_arg_string(args,"asset")
    if !read {return}
    path=tree_asset_path(text)
    if !strings.has_suffix(path,".ui") || strings.contains_rune(path,':') {return path,false,true}
    a:=s.app.assets
    if a==nil {return path,false,true}
    host.assets_scan(a)
    _,exists:=asset.registry_find_path(&a.registry,path)
    return path,!exists,true
}

// The path of a .ui as the registry names it: under the folder of the assets.
@(private)
tree_asset_path :: proc(path:string) -> string {return strings.trim_prefix(path,"assets/")}
