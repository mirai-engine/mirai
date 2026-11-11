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

// Bytes of a text of a result that no capacity of its own bounds.
@(private) RESULT_TEXT_BYTES :: 256*1024

Ui_Ok :: struct {ok:bool}

Tree_Inspect :: struct {
    document:serial.Json `mirai:"label=What ui.write takes back, in the grammar of the .ui as text: use (the paths of the .ui it takes styles, tokens and widgets from), params of the widget of this file, tokens, styles and animations by name, and nodes: the roots in order, each with name, kind (a ui.Node_Kind or the file of a widget it uses), text, key (the key of the .strings it shows), style or look, image, events, slot and children, and the keys of ui.Tree_Node and of its layout that differ from a new node of its kind"`,
}

Ui_Inspect_Params :: struct {
    asset:string `mirai:"label=the path of a .ui of the project (hud/hud.ui), or its id"`,
    node:string `mirai:"optional,label=name or #row: that node and what it holds, with the styles and animations they take; absent: the whole file"`,
}

Ui_Write_Params :: struct {
    asset:string `mirai:"label=the path of a .ui of the project (hud/hud.ui), or its id"`,
    node:string `mirai:"optional,label=name or #row: the document declares that node and what it holds, and nothing else of the file changes; absent: the whole file"`,
    document:serial.Json `mirai:"label=as ui.inspect gives it: use (paths of the .ui it takes styles and tokens from, and widgets), params of the widget this file is (name to node.field, node.parameter of a use, or field of its root), tokens, styles and animations by name, and nodes nested, each {name, kind (a Node_Kind, or the name of the file of a widget it uses), text (in the language texts are written in), key (the key of the .strings it shows, which then says that text; '' makes one from the text; absent: the same text in every language), style, look (its own style instead), image, the keys of its layout (width, height, gap...), events, slot, children}; a use also the parameters of its widget. tokens, styles and animations it names become what it says, null takes one away, the others stay; the nodes of the file, or of node, become these, matched by name and kind. Without nodes, no node changes"`,
    save:bool `mirai:"optional,label=writes the file now, as asset.save does, instead of leaving it for Save; a path that does not exist yet makes the .ui"`,
}

@(private)
tree_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="ui.inspect",summary="A .ui, or one of its nodes, as the document ui.write takes back: its nodes nested, each with what differs from a new node of its kind, and the styles and animations they take.",params=type_info_of(Ui_Inspect_Params),result=type_info_of(Tree_Inspect),flags={.Read_Only},run=api_tree_inspect})
    editor.api_method_register(s,{name="ui.write",summary="Makes a .ui, or one of its nodes, say what a document declares, as ui.inspect gives it; a widget is a .ui of its own and another uses it by name through use. Nodes are matched by name, the others are made and those it does not declare go; a node with key shows that key of the .strings of the project, and its text is what the key says in the language texts are written in. A path its nodes bind that the game of this build lacks fails with what the game has there, and changes nothing. One step of history; the file waits for Save, or for save:true. On the command line document=@file reads it from a file, and a path that does not exist yet makes the .ui.",params=type_info_of(Ui_Write_Params),result=type_info_of(Tree_Write_Answer),run=api_tree_write})
    capture_api_register(s)
    nodes_bind(s)
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

// texts: those of the project, which a document reads the text of a key from and sets it in.
@(private)
tree_args :: proc(s:^editor.Session,reading:^author.Reading,texts:^author.Texts) -> (args:author.Tree_Args,ok:bool) {
    texts^=editor.texts_open(s)
    return author.tree_args(reading,author.assets_of(s.app.assets),s.app.info,texts)
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
    texts:author.Texts
    args,args_ok:=tree_args(s,&reading,&texts)
    if !args_ok {return}
    r:author.Records
    _,opened:=tree_open(s,call,&args,&r)
    if !opened {return}
    root,root_ok:=author.tree_arg_row(&args,&r,"node")
    if !root_ok {return}
    a:=author.assets_of(s.app.assets)
    libs:=author.doc_libs(&args,&r)
    document:serial.Writer
    serial.writer_init(&document,0,call.allocator)
    author.document_write(&document,a.types,&r,root,libs[:],a,&texts)
    api.call_result(call,Tree_Inspect).document=serial.Json(string(serial.writer_bytes(&document)))
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
    texts:author.Texts
    args,args_ok:=tree_args(s,&reading,&texts)
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
    if problem:=editor.texts_write(s,&texts,"Write");problem!="" {api.call_fail(call,api.SERVER_ERROR,problem);return}
    if save {
        record,recorded:=asset.registry_find(&s.app.assets.registry,id)
        if !recorded {api.call_fail(call,api.SERVER_ERROR,"the .ui it wrote is not in the assets");return}
        paths:=make([dynamic]string,context.temp_allocator)
        append(&paths,record.path)
        for file in texts.files {if file.changed {append(&paths,file.path)}}
        if _,failures:=editor.assets_write(s,paths[:]);failures!="" {api.call_failf(call,api.SERVER_ERROR,"the .ui stays unsaved: %s",failures);return}
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
