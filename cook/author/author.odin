package author

import "base:runtime"
import "core:fmt"
import "mirai:asset"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// What an agent authors an interface or a scene with: the nested documents
// the API of the editor exchanges (ui.inspect and ui.write, scene.inspect
// with root and scene.write), between their text and the records of an asset,
// with no editor. The editor reads and writes them through this package, and
// so does the program of mirai ui and mirai scene (command.odin).

// The files of a project a document names and reads: the registry that finds
// them, unsaved ones included, and the types of their tables. Zero: none.
Assets :: struct {
    registry:^asset.Registry,
    types:^asset.Types,
}

assets_of :: proc(a:^host.Assets) -> Assets {
    if a==nil {return {}}
    return {&a.registry,&a.types}
}

// One reading of a document: the scratch its texts live in and, once it
// fails, what is wrong with it.
Reading :: struct {
    allocator:runtime.Allocator,
    raw:string,                // the text a malformed place is told in
    assets:serial.Text_Assets, // how a document names an asset by its path
    problem:string,
    failed:bool,
    internal:bool,             // what failed is not of the document: memory, the types of the build
}

reading_fail :: proc(reading:^Reading,message:string) {
    reading.failed,reading.internal=true,false
    reading.problem=fmt.aprintf("%s",message,allocator=reading.allocator)
}
reading_failf :: proc(reading:^Reading,format:string,args:..any) {
    reading.failed,reading.internal=true,false
    reading.problem=fmt.aprintf(format,..args,allocator=reading.allocator)
}
reading_broke :: proc(reading:^Reading,message:string) {
    reading_fail(reading,message)
    reading.internal=true
}
reading_brokef :: proc(reading:^Reading,format:string,args:..any) {
    reading_failf(reading,format,..args)
    reading.internal=true
}

// A reader of text of a document: asset fields take a path as well as an id.
reading_reader :: proc(reading:^Reading,r:^serial.Text_Reader,text:string) {
    serial.text_reader_init(r,text,reading.allocator)
    r.loose_names=true
    r.assets=reading.assets
}

// How a reading names assets with nothing but the registry of a project.
registry_assets :: proc(registry:^asset.Registry) -> serial.Text_Assets {
    return {user=registry,resolve=proc(user:rawptr,name,kinds:string) -> (id:base.Asset_Id,problem:string) {
        return asset.registry_resolve((^asset.Registry)(user),name,kinds)
    }}
}

// The records of the widgets the components of a tree name, as
// host.ui_tree_imports gives them.
tree_imports :: proc(a:Assets,data:ui.Tree_Data,files:^[dynamic]host.Content_Stamp=nil,allocator:=context.temp_allocator) -> (imports:[]ui.Tree_Data,ok:bool) {
    if a.registry==nil {return nil,false}
    return host.ui_tree_imports_in(a.registry,a.types,data,files,allocator)
}

// The name of a file of the assets as people read it; missing for one the
// registry does not have.
file_name_of :: proc(a:Assets,id:base.Asset_Id,missing:="") -> string {
    if a.registry==nil || id=={} {return ""}
    return doc_use_name(a,id,missing)
}

// The records of a new .ui, in the temporary allocator: a root Box that grows
// to the surface, and style 0.
ui_empty_data :: proc() -> ui.Tree_Data {
    nodes:=make([]ui.Tree_Node,1,context.temp_allocator)
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes[0]=ui.tree_node_record(&texts,-1,{kind=.Box,name="root",layout={width=ui.GROW,height=ui.GROW},float={to=.Surface}})
    return {nodes=nodes,styles=make([]ui.Node_Style,1,context.temp_allocator)}
}

// The parameters of a .ui as its file has them now, flat; none when it does not read.
widget_params :: proc(a:Assets,id:base.Asset_Id) -> []ui.Tree_Param {
    lib,ok:=doc_lib_read(a,id,context.temp_allocator)
    return lib.linked.params if ok else nil
}

// The parameters of records, linked with the widgets they use: flat.
data_params :: proc(data:ui.Tree_Data,imports:[]ui.Tree_Data) -> []ui.Tree_Param {
    linked,ok:=ui.tree_link(data,imports)
    return linked.params if ok else data.params
}

// The nodes of a component of data (row plus one); none outside it.
data_template :: proc(data:ui.Tree_Data,component:int) -> []ui.Tree_Node {
    if component<=0 || component>len(data.components) {return nil}
    c:=data.components[component-1]
    if u64(c.first)+u64(c.count)>u64(len(data.component_nodes)) {return nil}
    return data.component_nodes[c.first:][:c.count]
}

// The nodes a node of the tree counts as when its components are expanded.
tree_node_count :: proc(data:ui.Tree_Data,node:ui.Tree_Node,depth:int) -> int {
    if node.kind!=.Component {return 1}
    if node.component==0 || int(node.component)>len(data.components) || depth>ui.TREE_DEPTH {return 0}
    c:=data.components[node.component-1]
    if u64(c.first)+u64(c.count)>u64(len(data.component_nodes)) {return 0}
    total:=0
    for n in data.component_nodes[c.first:][:c.count] {total+=tree_node_count(data,n,depth+1)}
    return total
}
