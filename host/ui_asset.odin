package host

import "base:runtime"
import "core:fmt"
import "mirai:asset"
import anim "mirai:std/anim"
import "mirai:std/base"
import "mirai:ui"

// The .ui asset: the records of ui.Tree_Data in the tables asset/ui.odin
// names. Here because this is where both packages are linked.

// A document with the records of a tree. .Invalid for records ui.tree_load
// would refuse: what is written always loads. imports: the records of the
// widgets its components name, as ui.tree_link takes them.
ui_tree_document :: proc(doc:^asset.Document,types:^asset.Types,id:base.Asset_Id,data:ui.Tree_Data,imports:[]ui.Tree_Data={},allocator:=context.allocator) -> asset.Error {
    for component in data.components {if component.widget=={} {return .Invalid}}
    linked,linked_ok:=ui.tree_link(data,imports)
    if !linked_ok {return .Invalid}
    textures:=make([]u32,len(linked.images),context.temp_allocator)
    fonts:=make([]u8,len(linked.fonts),context.temp_allocator)
    probe:ui.Widget_Tree
    if !ui.tree_load(&probe,linked,{textures=textures,fonts=fonts},allocator) {return .Invalid}
    ui.tree_destroy(&probe)
    asset.document_init(doc,asset.KIND_UI,id,allocator)
    doc.kind_version=asset.UI_VERSION
    error:=ui_tree_tables(doc,types,data)
    if error!=.None {asset.document_destroy(doc)}
    return error
}

@(private)
ui_tree_tables :: proc(doc:^asset.Document,types:^asset.Types,data:ui.Tree_Data) -> asset.Error {
    asset.document_put(doc,types,asset.UI_TABLE_NODES,data.nodes,{},.LZ) or_return
    asset.document_put(doc,types,asset.UI_TABLE_STYLES,data.styles) or_return
    asset.document_put(doc,types,asset.UI_TABLE_VARIANTS,data.variants) or_return
    asset.document_put(doc,types,asset.UI_TABLE_COMPONENTS,data.components) or_return
    asset.document_put(doc,types,asset.UI_TABLE_OVERRIDES,data.overrides) or_return
    asset.document_put(doc,types,asset.UI_TABLE_IMAGES,data.images) or_return
    asset.document_put(doc,types,asset.UI_TABLE_ANIMS,data.anims) or_return
    asset.document_put(doc,types,asset.UI_TABLE_TRACKS,data.tracks) or_return
    asset.document_put(doc,types,asset.UI_TABLE_KEYS,data.keys) or_return
    asset.document_put(doc,types,asset.UI_TABLE_PARTS,data.parts) or_return
    asset.document_put(doc,types,asset.UI_TABLE_ANIM_SETS,data.anim_sets) or_return
    asset.document_put(doc,types,asset.UI_TABLE_FONTS,data.fonts) or_return
    asset.document_put(doc,types,asset.UI_TABLE_STYLE_INFOS,data.style_infos) or_return
    asset.document_put(doc,types,asset.UI_TABLE_GRID_TRACKS,data.grid_tracks) or_return
    asset.document_put(doc,types,asset.UI_TABLE_TOKENS,data.tokens) or_return
    asset.document_put(doc,types,asset.UI_TABLE_TOKEN_USES,data.token_uses) or_return
    asset.document_put(doc,types,asset.UI_TABLE_PARAMS,data.params) or_return
    asset.document_put(doc,types,asset.UI_TABLE_TEXT,data.text,{.Bulk},.LZ) or_return
    return .None
}

// The bytes of the file of a tree, in allocator; .Invalid as ui_tree_document.
ui_tree_bytes :: proc(types:^asset.Types,id:base.Asset_Id,data:ui.Tree_Data,imports:[]ui.Tree_Data={},allocator:=context.allocator) -> (bytes:[]u8,error:asset.Error) {
    doc:asset.Document
    ui_tree_document(&doc,types,id,data,imports,allocator) or_return
    defer asset.document_destroy(&doc)
    return asset.document_bytes(&doc,allocator)
}

ui_tree_save :: proc(path:string,types:^asset.Types,id:base.Asset_Id,data:ui.Tree_Data,imports:[]ui.Tree_Data={},allocator:=context.allocator) -> asset.Error {
    doc:asset.Document
    ui_tree_document(&doc,types,id,data,imports,allocator) or_return
    defer asset.document_destroy(&doc)
    return asset.document_save(&doc,path)
}

// The records of a .ui: the file itself where it stores them as this build
// lays them out, copies the asset owns otherwise. A table the file lacks is
// empty. Nothing in them is checked: ui.tree_load does it.
ui_tree_view :: proc(a:^asset.Asset,types:^asset.Types) -> (data:ui.Tree_Data,error:asset.Error) {
    asset.kind_check(a,asset.KIND_UI,asset.UI_VERSION) or_return
    rows :: proc(a:^asset.Asset,types:^asset.Types,name:string,$T:typeid) -> ([]T,asset.Error) {
        if _,found:=asset.asset_table(a,name);!found {return nil,.None}
        return asset.asset_rows(a,types,name,"",T)
    }
    data.nodes=rows(a,types,asset.UI_TABLE_NODES,ui.Tree_Node) or_return
    data.styles=rows(a,types,asset.UI_TABLE_STYLES,ui.Node_Style) or_return
    data.variants=rows(a,types,asset.UI_TABLE_VARIANTS,ui.Tree_Style_Variant) or_return
    data.components=rows(a,types,asset.UI_TABLE_COMPONENTS,ui.Tree_Component) or_return
    data.overrides=rows(a,types,asset.UI_TABLE_OVERRIDES,ui.Tree_Override) or_return
    data.images=rows(a,types,asset.UI_TABLE_IMAGES,ui.Tree_Image) or_return
    data.anims=rows(a,types,asset.UI_TABLE_ANIMS,ui.Tree_Anim) or_return
    data.tracks=rows(a,types,asset.UI_TABLE_TRACKS,ui.Tree_Track) or_return
    data.keys=rows(a,types,asset.UI_TABLE_KEYS,anim.Keyframe) or_return
    data.parts=rows(a,types,asset.UI_TABLE_PARTS,ui.Anim) or_return
    data.anim_sets=rows(a,types,asset.UI_TABLE_ANIM_SETS,ui.Anim_Set) or_return
    data.fonts=rows(a,types,asset.UI_TABLE_FONTS,ui.Tree_Font) or_return
    data.style_infos=rows(a,types,asset.UI_TABLE_STYLE_INFOS,ui.Tree_Style_Info) or_return
    data.grid_tracks=rows(a,types,asset.UI_TABLE_GRID_TRACKS,ui.Grid_Tracks) or_return
    data.tokens=rows(a,types,asset.UI_TABLE_TOKENS,ui.Tree_Token) or_return
    data.token_uses=rows(a,types,asset.UI_TABLE_TOKEN_USES,ui.Tree_Token_Use) or_return
    data.params=rows(a,types,asset.UI_TABLE_PARAMS,ui.Tree_Param) or_return
    data.text=rows(a,types,asset.UI_TABLE_TEXT,u8) or_return
    return data,.None
}

// The records of the widgets the components of a tree name, by row of
// components, each linked already with the widgets it names, read from the
// assets as the registry holds them (unsaved files included). files gets the
// stamp of every file read, to load the tree again when one changes. A
// transaction: false when a widget is missing, is not a .ui, does not read,
// or names through others a file that names it.
ui_tree_imports :: proc(a:^Assets,data:ui.Tree_Data,files:^[dynamic]Content_Stamp=nil,allocator:=context.temp_allocator) -> (imports:[]ui.Tree_Data,ok:bool) {
    return ui_tree_imports_in(&a.registry,&a.types,data,files,allocator)
}

// ui_tree_imports for whoever has the registry of a project and the types of
// its assets without the assets of an application.
ui_tree_imports_in :: proc(registry:^asset.Registry,types:^asset.Types,data:ui.Tree_Data,files:^[dynamic]Content_Stamp=nil,allocator:=context.temp_allocator) -> (imports:[]ui.Tree_Data,ok:bool) {
    stack:[ui.TREE_DEPTH]base.Asset_Id
    return ui_tree_imports_of(registry,types,data,files,&stack,0,allocator)
}

@(private="file")
ui_tree_imports_of :: proc(registry:^asset.Registry,types:^asset.Types,data:ui.Tree_Data,files:^[dynamic]Content_Stamp,stack:^[ui.TREE_DEPTH]base.Asset_Id,depth:int,allocator:=context.temp_allocator) -> (imports:[]ui.Tree_Data,ok:bool) {
    widgets:=false
    for component in data.components {widgets|=component.widget!={}}
    if !widgets {return nil,true}
    if depth>=ui.TREE_DEPTH {return nil,false}
    allocation:runtime.Allocator_Error
    if imports,allocation=make([]ui.Tree_Data,len(data.components),allocator);allocation!=nil {return nil,false}
    for component,row in data.components {
        id:=component.widget
        if id=={} {continue}
        // Several components of a file read it once.
        seen:=false
        for earlier,i in data.components[:row] {
            if earlier.widget==id {imports[row]=imports[i];seen=true;break}
        }
        if seen {continue}
        for open in stack[:depth] {if open==id {return nil,false}}
        record,found:=asset.registry_find(registry,id)
        if !found || record.kind!=asset.KIND_UI {return nil,false}
        bytes,read:=asset.registry_read(registry,record.path,allocator)
        if read!=.None {return nil,false}
        file:asset.Asset
        if asset.asset_take(&file,bytes,allocator)!=.None || file.blob.header.id!=id {return nil,false}
        widget,error:=ui_tree_view(&file,types)
        if error!=.None {return nil,false}
        if files!=nil {append(files,Content_Stamp{id=id,size=record.size,time=record.time})}
        stack[depth]=id
        nested:=ui_tree_imports_of(registry,types,widget,files,stack,depth+1,allocator) or_return
        imports[row]=ui.tree_link(widget,nested,allocator) or_return
    }
    return imports,true
}
