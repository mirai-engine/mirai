package ui_inspector_editor

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:engine/gui"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The document of a .ui, in a tab next to the scenes: the interface as the
// game builds it and the properties of the node chosen, with its nodes in
// the Hierarchy of the left panel.
// What the document changes goes to the file of the asset in memory,
// unsaved, as a step of the history of the document once the UI lets go of
// it (a drag, a typed value, a popup); undo, redo and Save are those of every
// asset document. The file is read again when it or the history changes and
// nothing waits to be written: after undo, redo, Save or a change from
// outside. What waits goes to its document before another comes to the
// front, Play starts or the API reads a .ui.

SCOPE :: ui.Id(0x75696e73)
NODE_ROW :: f32(24)
LABEL_CAPACITY :: 48
TEXT_EDIT :: 1024 // bytes of a text the document edits in a row or in place
UI_VIEWS :: 8     // .ui whose node chosen, scrolls and stage the document keeps while another is in front
UI_RENAMES :: 8   // nodes of the tree renamed before a write, which the .ui that instance it follow

@(storage)
Ui_Documents :: struct {provider:editor.Asset_Document_Provider}
ui_documents_default :: proc() -> Ui_Documents {
    return {provider={kinds={0=asset.KIND_UI},count=1,hierarchy={0},flat={0},creates={0},create=ui_create,actions={.Copy,.Paste,.Duplicate,.Delete,.Rename}}}
}

// The records of a new .ui, in the temporary allocator: a root Box that grows
// to the surface, and style 0.
ui_empty_data :: proc() -> ui.Tree_Data {
    nodes:=make([]ui.Tree_Node,1,context.temp_allocator)
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes[0]=ui.tree_node_record(&texts,-1,{kind=.Box,name="root",layout={width=ui.GROW,height=ui.GROW},float={to=.Surface}})
    return {nodes=nodes,styles=make([]ui.Node_Style,1,context.temp_allocator)}
}

// The bytes of the empty .ui Create of the content browser and asset.create make.
ui_create :: proc(s:^editor.Session,kind:asset.Fourcc,id:base.Asset_Id) -> []u8 {
    a:=s.app.assets
    if a==nil || kind!=asset.KIND_UI {return nil}
    bytes,error:=host.ui_tree_bytes(&a.types,id,ui_empty_data(),allocator=context.temp_allocator)
    return bytes if error==.None else nil
}

Section :: enum u8 {Node,Layout,Floating,Focus,Style,Events,Image,Animations,Component,Parameters,Fonts,Styles}

@(storage,free="ui_inspector_free")
Ui_Inspector :: struct {
    allocator:runtime.Allocator,
    id:base.Asset_Id,      // the .ui of the document in front
    read:bool,             // records hold what its file holds
    failed:bool,           // the file could not be read
    stamp:[2]i64,          // size and time of the file when the records were read or written
    cursor:int,            // of the history of the document then
    records:Records,
    pending:bool,          // the records changed and the file does not have it yet
    label:[LABEL_CAPACITY]u8, // the step of history the change becomes
    change:u64,            // advances with every change of the records
    selected:int,          // row of the nodes; -1: none
    preview:Preview,
    stage:Stage,
    nodes_scroll,properties_scroll,add_scroll:[2]f32,
    scrolled:int,          // the node properties_scroll is of: another starts at the top
    views:[UI_VIEWS]Ui_View,
    view_clock:u64,
    search:[64]u8,         // of the properties
    search_length:int,
    style_rename:bool,     // the name of style_renamed is typed
    style_renamed:int,
    style_name:[ui.TREE_NAME_CAPACITY]u8,
    style_name_length:int,
    open:[Section]bool,
    advanced:[Section]bool, // the Advanced fold of each card is open
    event_open:[8]bool,    // the parts of the card Events open, by happening
    overrides_closed:bool, // the part Overrides of an instance is closed
    state_open:[Node_State]bool, // the fold of each state in the Style card is open
    state_shown:Node_State,      // the state Edit shows the selected node in: the fold opened last
    variant_rename:bool,   // the name of the variant of the node chosen is typed
    variant_name:[ui.TREE_NAME_CAPACITY]u8,
    variant_name_length:int,
    anim:int,              // the animation the Animations section shows; -1: none
    editing:Inline_Edit,
    input:Preview_Input,
    clip:Clip_Nodes,       // what Copy copied
    renames:[UI_RENAMES]Node_Rename,
    rename_count:int,
    imports:Imports_Cache, // the widgets the records of the document name
    drag:Node_Drag,
    request_seen:u64,      // the last Asset_Document.request_serial run
    texts:Texts_Edit,      // what the popup of texts of a localized node edits
    pick_prefix:[ui.TREE_PATH_CAPACITY]u8, // the path the list of a binding walked so far
    pick_length:int,
    pick_scroll:[2]f32,
    bind_types:Bind_Types,
    problems:[dynamic]Bind_Problem, // of the .ui of the project, against the game of checked_info
    checked:[dynamic]Ui_Checked,    // the .ui those problems are of, as they were read
    checked_uses:[dynamic]base.Asset_Id,
    checked_info:^core.World_Info,
    checked_revision:u64,
    problem:[BIND_PROBLEMS]Bind_Problem, // of the document in front, for change, problem_assets and problem_info
    problem_count:int,
    problem_change,problem_assets:u64,
    problem_info:^core.World_Info,
    widget_scope:Path_Scope, // where the @ paths of the document start, for widget_scope_id
    widget_scope_id:base.Asset_Id,
    widget_scope_revision:u64,
    widget_scope_info:^core.World_Info,
    ux:Ux,                 // the hierarchy, the stage and the cards as a person handles them (nodes.odin)
}

ui_inspector_free :: proc(u:^Ui_Inspector) {
    records_destroy(&u.records)
    preview_free(&u.preview)
    clip_destroy(&u.clip)
    imports_free(&u.imports)
    delete(u.input.actions)
    bind_types_free(&u.bind_types)
    delete(u.problems);delete(u.checked);delete(u.checked_uses)
    ux_free(&u.ux)
    u^={}
}

@(step="ui",after="editor_panels")
ui_inspector_document :: proc(s:^editor.Session,u:^Ui_Inspector,app:^host.App,input:core.Frame_Input) {
    g:=s.gui
    d:=editor.asset_document_active(s)
    if u.pending && (d==nil || d.id!=u.id || d.kind!=asset.KIND_UI || editor.playing(s)) {inspector_flush(s,u)}
    if !g.begun || editor.playing(s) {return}
    if d==nil || d.kind!=asset.KIND_UI {return}
    a:=app.assets
    if a==nil {return}
    if u.allocator.procedure==nil {
        u.allocator=app.allocator
        u.selected,u.anim=-1,-1
        for open in ([]Section{.Node,.Layout,.Style,.Component}) {u.open[open]=true}
        u.stage=STAGE_DEFAULT
        u.drag.row=-1
        u.request_seen=d.request_serial
    }
    inspector_sync(s,u,a,d.id,d.history.cursor)
    // What it binds that the game does not have, once a gesture ends and after each build.
    if u.read && !u.pending && app.info!=nil && (u.problem_change!=u.change || u.problem_assets!=a.revision || u.problem_info!=app.info) {
        u.problem_change,u.problem_assets,u.problem_info=u.change,a.revision,app.info
        data:=records_data(&u.records)
        imports,imported:=imports_cached(&u.imports,a,data,u.allocator)
        u.problem_count=bind_check(&u.bind_types,u.allocator,a,app.info,data,imports,imported,u.problem[:])
        for &problem in u.problem[:u.problem_count] {problem.asset=u.id}
    }
    // What the AI is told the user picked: the node chosen, by name, or by kind and row.
    if n:=selected_node(u);n!=nil {
        labels:=KIND_LABELS
        name:=serial.text_field(n.name[:])
        editor.asset_document_pick(d,{fmt.tprintf("%s (%s)",name,labels[n.kind]) if name!="" else fmt.tprintf("%s %d",labels[n.kind],u.selected)})
    } else {editor.asset_document_pick(d,nil)}
    ctx:=g.ctx
    // Auto: the prompts of the device used last, as a game shows them.
    if !u.stage.fixed {
        gamepads:=input.gamepads
        gui.family_update(&u.stage.family,input.device,gamepads[:],true,-1)
    }
    stage_toolbar(s,u)
    hierarchy_build(s,u,a)
    nodes_actions(s,u,a,d)
    document,details,room:=editor.asset_workspace_details(s)
    id:=ui.id_derive(ctx,SCOPE,"document")
    if ui.panel(ctx,id,document) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW,align_x=.Center,align_y=.Center}) {
            switch {
            case u.failed:          ui.label(ctx,"The file cannot be read",ctx.theme.font_small,ctx.theme.text_muted)
            case !u.read:
            case:                   preview_column(s,u,app)
            }
        }
    }
    // The properties, as Details shows an entity.
    properties_id:=ui.id_derive(ctx,SCOPE,"properties")
    if u.read {
        if ui.panel(ctx,properties_id,details) {
            ui.id_push(ctx,properties_id)
            defer ui.id_pop(ctx)
            properties_head(s,u)
            origin:=editor.ai_provenance_asset_row(s)
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(editor.SEARCH_BAR),padding={8,0,8,6},align_y=.Center}) {
                if editor.search_field(s,ui.id(ctx,"search"),u.search[:],&u.search_length,"Search properties") {u.properties_scroll=0}
                editor.scroll_shadow(s,u.properties_scroll.y>0)
            }
            // What another node shows has another length: kept, the offset could show nothing.
            if u.scrolled!=u.selected {u.properties_scroll,u.scrolled={},u.selected}
            if ui.scroll_area(ctx,ui.id(ctx,"properties"),&u.properties_scroll,{height=ui.FIT,max_height=max(room-editor.INSPECTOR_HEAD-origin-editor.SEARCH_BAR,40),padding={8,7,8,8},gap=7,fade=ctx.theme.panel}) {
                properties(s,u,a,details.width.value)
            }
        }
        // Over the editor, out of the clip of the panels.
        if n:=selected_node(u);n!=nil {texts_window(s,u,n)}
    }
    inspector_commit(s,u,a,d)
}

// The nodes of the document.
scope_nodes :: proc(u:^Ui_Inspector) -> []ui.Tree_Node {return u.records.nodes[:]}

// The node chosen; nil for none.
selected_node :: proc(u:^Ui_Inspector) -> ^ui.Tree_Node {
    if u.selected<0 || u.selected>=len(u.records.nodes) {return nil}
    return &u.records.nodes[u.selected]
}

// The records changed: they go to the file once nothing holds them, as a
// step called label.
changed :: proc(u:^Ui_Inspector,label:string) {
    if !u.pending {ui.tree_text_set(u.label[:],label)}
    u.pending=true
    u.change+=1
}

@(private)
inspector_sync :: proc(s:^editor.Session,u:^Ui_Inspector,a:^host.Assets,id:base.Asset_Id,cursor:int) {
    if u.id!=id {
        view_keep(u)
        records_destroy(&u.records)
        preview_free(&u.preview)
        u.id,u.read,u.failed,u.pending,u.rename_count=id,false,false,false,0
        u.anim=-1
        u.editing={}
        u.texts.open=false
        view_take(u)
    }
    // An undo or a redo moves the history, also when the file keeps its stamp.
    stamp:=file_stamp(a,id)
    if u.pending || (u.read || u.failed) && u.stamp==stamp && u.cursor==cursor {return}
    file:asset.Asset
    if host.assets_file(a,id,asset.KIND_UI,&file)!=.None {u.failed=true;u.stamp,u.cursor=stamp,cursor;return}
    defer asset.asset_close(&file)
    data,error:=host.ui_tree_view(&file,&a.types)
    records:Records
    if error!=.None || !records_load(&records,data,u.allocator) {u.failed=true;u.stamp,u.cursor=stamp,cursor;return}
    first:=!u.read
    // What an undo or a redo changed is chosen, as in a scene; records read
    // from the file, as these are, compare byte by byte.
    if !first {
        if row:=records_changed_row(&u.records,&records,u.selected);row>=0 {u.selected=row}
    }
    records_destroy(&u.records)
    u.records=records
    u.read,u.failed,u.stamp,u.cursor,u.rename_count=true,false,stamp,cursor,0
    u.change+=1
    if first && u.selected<0 && len(u.records.nodes)>0 {u.selected=0}
    u.selected=min(u.selected,len(scope_nodes(u))-1)
    u.anim=min(u.anim,len(u.records.anims)-1)
}

// The size and time of the file of an asset, which change with every write.
@(private)
file_stamp :: proc(a:^host.Assets,id:base.Asset_Id) -> [2]i64 {
    if file,found:=asset.registry_find(&a.registry,id);found {return {file.size,file.time}}
    return {}
}

// Where a .ui was left: the node chosen, the scrolls and the stage.
Ui_View :: struct {
    id:base.Asset_Id,
    selected:int,
    nodes_scroll,properties_scroll:[2]f32,
    stage:Stage,
    used:u64, // view_clock when it was left; the oldest gives its place
}

// Keeps where the .ui of the document was left, in its place or the oldest.
@(private)
view_keep :: proc(u:^Ui_Inspector) {
    if u.id=={} {return}
    at:=0
    for &v,i in u.views {
        if v.id==u.id {at=i;break}
        if v.used<u.views[at].used {at=i}
    }
    u.view_clock+=1
    u.views[at]={u.id,u.selected,u.nodes_scroll,u.properties_scroll,u.stage,u.view_clock}
}

// Where the .ui of the document was left; the first time nothing is chosen
// and the stage is as it starts.
@(private)
view_take :: proc(u:^Ui_Inspector) {
    u.selected,u.nodes_scroll,u.properties_scroll,u.stage=-1,0,0,STAGE_DEFAULT
    for &v in u.views {
        if v.id==u.id {u.selected,u.nodes_scroll,u.properties_scroll,u.stage=v.selected,v.nodes_scroll,v.properties_scroll,v.stage}
    }
    u.scrolled=u.selected
}

// Writes the records into the file once nothing holds them.
@(private)
inspector_commit :: proc(s:^editor.Session,u:^Ui_Inspector,a:^host.Assets,d:^editor.Asset_Document) {
    if !u.pending || u.id=={} {return}
    ctx:=s.gui.ctx
    if ctx.active!=0 || ctx.edit.id!=0 || ctx.popup.count>0 || u.editing.row>=0 && u.editing.open {return}
    inspector_write(s,u,a,d)
}

// What the records hold unwritten goes to the document of their .ui, in
// front or not; it is lost when that document closed.
inspector_flush :: proc(s:^editor.Session,u:^Ui_Inspector) {
    a:=s.app.assets
    if !u.pending || a==nil {return}
    for &d in s.asset_documents {
        if d.id==u.id && d.kind==asset.KIND_UI {
            inspector_write(s,u,a,&d)
            return
        }
    }
    u.pending=false
}

// Before the API reads or writes a .ui, what the document holds unwritten goes to its file.
api_flush :: proc(s:^editor.Session) {
    if s.editor_world==nil || s.info==nil {return}
    if u:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Ui_Inspector);u!=nil {inspector_flush(s,u)}
}

// Writes the records into the file, tidied (keys in order, no row nothing
// uses), as a step of the history of d. Records that would not load go back
// to what the file has. The .ui that instance it follow the nodes renamed.
@(private)
inspector_write :: proc(s:^editor.Session,u:^Ui_Inspector,a:^host.Assets,d:^editor.Asset_Document) -> bool {
    u.pending=false
    renames,count:=u.renames,u.rename_count
    u.rename_count=0
    record,found:=asset.registry_find(&a.registry,u.id)
    if !found {return false}
    path:=asset.registry_file_path(&a.registry,record.path,context.temp_allocator)
    records_tidy(&u.records)
    params:=widget_params(a,u.id)
    imports,imported:=imports_cached(&u.imports,a,records_data(&u.records),u.allocator)
    bytes:[]u8
    error:=asset.Error.Invalid
    if imported {bytes,error=records_commit(&a.types,u.id,&u.records,imports)}
    data:=records_data(&u.records)
    if error!=.None {
        why:=load_why(a,data,imports) if imported else widget_why(a,data)
        editor.notify(s,fmt.tprintf("That change leaves an interface that does not load (%s): it was undone",why) if error==.Invalid else fmt.tprintf("The interface could not be written: %v",error))
        u.read=false
        return false
    }
    label:=string(u.label[:])
    for c,i in u.label {if c==0 {label=string(u.label[:i]);break}}
    if !editor.asset_document_write(s,d,path,bytes,label) {u.read=false;return false}
    u.stamp,u.cursor=file_stamp(a,u.id),d.history.cursor
    u.change+=1
    for &rename in renames[:count] {widget_rename_follow(s,u.id,serial.text_field(rename.from[:]),serial.text_field(rename.to[:]))}
    widget_params_follow(s,a,u.id,params_changes(params,data_params(data,imports)),0)
    return true
}

// ---------------------------------------------------------------- widgets

// The parameters of a .ui as its file has them now, flat; none when it does not read.
widget_params :: proc(a:^host.Assets,id:base.Asset_Id) -> []ui.Tree_Param {
    lib,ok:=doc_lib_read(a,id,context.temp_allocator)
    return lib.linked.params if ok else nil
}

// The parameters of records, linked with the widgets they use: flat.
data_params :: proc(data:ui.Tree_Data,imports:[]ui.Tree_Data) -> []ui.Tree_Param {
    linked,ok:=ui.tree_link(data,imports)
    return linked.params if ok else data.params
}

// A parameter of a widget that went somewhere else, or went: after is empty.
Param_Change :: struct {before,after:ui.Tree_Param}

// What changed between two versions of the flat parameters of a widget. One
// that has another name now and goes to the same place changed nothing: a use
// says it by its name, read from the widget.
params_changes :: proc(before,after:[]ui.Tree_Param) -> []Param_Change {
    changes:=make([dynamic]Param_Change,context.temp_allocator)
    for &old in before {
        now:^ui.Tree_Param
        same_place:=false
        for &p in after {
            if p.name==old.name {now=&p;break}
            if p.node==old.node && p.field==old.field {same_place=true}
        }
        if now==nil {
            if !same_place {append(&changes,Param_Change{before=old})}
            continue
        }
        if now.node!=old.node || now.field!=old.field {append(&changes,Param_Change{before=old,after=now^})}
    }
    return changes[:]
}

// What the uses of a widget gave follows where its parameters go now, in the
// .ui of the project and, past a parameter of a widget that goes to the use,
// the uses of that one: one step of history for each file changed.
widget_params_follow :: proc(s:^editor.Session,a:^host.Assets,id:base.Asset_Id,changes:[]Param_Change,depth:int) {
    if len(changes)==0 || depth>=ui.TREE_DEPTH {return}
    for &file in a.registry.files {
        if file.kind!=asset.KIND_UI || file.id=={} || file.id==id {continue}
        records:Records
        if !records_read(a,file.id,&records,context.temp_allocator) {continue}
        derived:=records_params_follow(a,&records,id,changes)
        if !derived.changed {continue}
        records_write(s,file.id,&records,"Follow widget")
        widget_params_follow(s,a,file.id,derived.through[:],depth+1)
    }
}

// What a file does when the parameters of a widget it uses change.
Param_Follow :: struct {
    changed:bool,
    through:[dynamic]Param_Change, // of its own parameters, the ones that go to those uses
}

// Moves what the uses of widget in records give; gone, it is taken away.
records_params_follow :: proc(a:^host.Assets,records:^Records,widget:base.Asset_Id,changes:[]Param_Change) -> (follow:Param_Follow) {
    follow.through=make([dynamic]Param_Change,context.temp_allocator)
    lib,lib_ok:=doc_lib_read(a,widget,context.temp_allocator)
    if !lib_ok {return}
    node_at :: proc(lib:^Doc_Lib,path:string) -> (node:ui.Tree_Node,source:^Records) {
        source=new(Records,context.temp_allocator)
        records_load(source,lib.linked,context.temp_allocator)
        expanded,ok:=ui.tree_expand(lib.linked,context.temp_allocator)
        if ok {for &e in expanded {if serial.text_field(e.name[:])==path {return e,source}}}
        return {},source
    }
    w:=Doc_Write{r=records,list=records.nodes[:]}
    for &n,row in records.nodes {
        if n.kind!=.Component || int(n.component)==0 || int(n.component)>len(records.components) || records.components[n.component-1].widget!=widget {continue}
        name:=serial.text_field(n.name[:])
        for &c in changes {
            if value,has:=doc_param_value(&w,row,&c.before);has {
                follow.changed=true
                records_param_clear(records,row,&c.before,lib.linked.params)
                if c.after.name!={} {
                    node,source:=node_at(&lib,serial.text_field(c.after.node[:]))
                    records_param_give(a,records,row,&c.after,value,source,node)
                }
            }
            // A parameter of this file that goes to this one, through this use.
            for &p in records.params {
                if serial.text_field(p.node[:])!=name || serial.text_field(p.param[:])!=serial.text_field(c.before.name[:]) {continue}
                outer:=Param_Change{before=p}
                flatten :: proc(flat:^ui.Tree_Param,use:string,inner:^ui.Tree_Param) {
                    flat.param,flat.field={},inner.field
                    ui.tree_text_set(flat.node[:],strings.join({use,serial.text_field(inner.node[:])},"/",context.temp_allocator) if inner.node[0]!=0 else use)
                }
                flatten(&outer.before,name,&c.before)
                if c.after.name!={} {
                    outer.after=p
                    flatten(&outer.after,name,&c.after)
                }
                append(&follow.through,outer)
            }
        }
    }
    return
}

// Takes away of the use at row the value a parameter gave, unless another
// parameter of the widget goes to the same part of the same node.
records_param_clear :: proc(r:^Records,row:int,p:^ui.Tree_Param,all:[]ui.Tree_Param) {
    group:=doc_param_group(p.field)
    keep:=false
    for &other in all {if other.name!=p.name && other.node==p.node && doc_param_group(other.field)==group {keep=true}}
    node:=serial.text_field(p.node[:])
    if node=="" {
        if !keep {r.nodes[row].component_fields-={group}} else if slot:=doc_param_slot(&r.nodes[row],p.field);slot!=nil {ui.tree_text_set(slot,"")}
        return
    }
    for i:=len(r.overrides)-1;i>=0;i-=1 {
        o:=&r.overrides[i]
        if int(o.instance)!=row || serial.text_field(o.node[:])!=node || group not_in o.fields {continue}
        if keep {
            if slot:=doc_param_slot(&o.values,p.field);slot!=nil {ui.tree_text_set(slot,"")}
        } else {
            o.fields-={group}
            if o.fields=={} {ordered_remove(&r.overrides,i)}
        }
    }
}

// The widgets the records of the document name, as host.ui_tree_imports read
// them, while their files keep their stamps: they are read again when one
// changes or the records name others.
Imports_Cache :: struct {
    arena:virtual.Arena,
    ready:bool,
    widgets:[dynamic]base.Asset_Id, // by row of components
    stamps:[dynamic]host.Content_Stamp,
    imports:[]ui.Tree_Data,
    ok:bool,
    revision:u64, // of the assets when they did not read: they are read again when it changes
}

imports_free :: proc(c:^Imports_Cache) {
    if c.ready {virtual.arena_destroy(&c.arena)}
    delete(c.widgets);delete(c.stamps)
    c^={}
}

imports_cached :: proc(c:^Imports_Cache,a:^host.Assets,data:ui.Tree_Data,allocator:runtime.Allocator) -> ([]ui.Tree_Data,bool) {
    same:=c.ready && len(c.widgets)==len(data.components) && (c.ok || c.revision==a.revision)
    for component,i in data.components {
        if !same {break}
        same=component.widget==c.widgets[i]
    }
    for stamp in c.stamps {
        if !same {break}
        file,found:=asset.registry_find(&a.registry,stamp.id)
        same=found && file.size==stamp.size && file.time==stamp.time
    }
    if same {return c.imports,c.ok}
    imports_free(c)
    if virtual.arena_init_growing(&c.arena)!=nil {return host.ui_tree_imports(a,data)}
    c.ready,c.revision=true,a.revision
    c.widgets=make([dynamic]base.Asset_Id,0,len(data.components),allocator)
    c.stamps=make([dynamic]host.Content_Stamp,allocator)
    for component in data.components {append(&c.widgets,component.widget)}
    c.imports,c.ok=host.ui_tree_imports(a,data,&c.stamps,virtual.arena_allocator(&c.arena))
    return c.imports,c.ok
}

// The node a path of names ("slot/icon") reaches from nodes of data, as an
// override names it: a name of nodes, or past the name of an instance the
// name of a node of its widget, whose root the name of the instance is.
@(private)
data_node :: proc(data:ui.Tree_Data,nodes:[]ui.Tree_Node,path:string) -> (node:ui.Tree_Node,ok:bool) {
    for &n in nodes {
        name:=serial.text_field(n.name[:])
        if name=="" || !strings.has_prefix(path,name) || len(path)>len(name) && path[len(name)]!='/' {continue}
        if n.kind!=.Component {
            if len(path)==len(name) {return n,true}
            continue
        }
        inner:=data_template(data,int(n.component))
        if len(inner)==0 {return}
        if len(path)==len(name) {return inner[0],true}
        rest:=path[len(name)+1:]
        for &child in inner[1:] {if serial.text_field(child.name[:])==rest {return child,true}}
        return
    }
    return
}

// The nodes of a component of data (row plus one); none outside it.
@(private)
data_template :: proc(data:ui.Tree_Data,component:int) -> []ui.Tree_Node {
    if component<=0 || component>len(data.components) {return nil}
    c:=data.components[component-1]
    if u64(c.first)+u64(c.count)>u64(len(data.component_nodes)) {return nil}
    return data.component_nodes[c.first:][:c.count]
}

// The records an instance of the tree is made of, linked, and their nodes
// its overrides name.
@(private)
override_nodes :: proc(u:^Ui_Inspector,a:^host.Assets,instance:int) -> (data:ui.Tree_Data,nodes:[]ui.Tree_Node,ok:bool) {
    r:=&u.records
    if instance<0 || instance>=len(r.nodes) || r.nodes[instance].kind!=.Component {return}
    c:=int(r.nodes[instance].component)-1
    if c<0 || c>=len(r.components) {return}
    imports,imported:=imports_cached(&u.imports,a,records_data(r),u.allocator)
    if !imported || c>=len(imports) {return}
    return imports[c],imports[c].nodes,true
}

// The names an override of an instance of the tree can reach: the nodes of
// its widget and, past an instance of another widget there, the nodes of
// that one.
override_targets :: proc(u:^Ui_Inspector,a:^host.Assets,instance:int) -> []string {
    names:=make([dynamic]string,context.temp_allocator)
    data,nodes,ok:=override_nodes(u,a,instance)
    if !ok {return nil}
    for &n in nodes {
        name:=serial.text_field(n.name[:])
        if name=="" {continue}
        append(&names,name)
        if n.kind!=.Component {continue}
        inner:=data_template(data,int(n.component))
        for &child in inner[min(1,len(inner)):] {
            if child_name:=serial.text_field(child.name[:]);child_name!="" {append(&names,fmt.tprintf("%s/%s",name,child_name))}
        }
    }
    return names[:]
}

// Turns a field of an override on or off; on, it takes what the node it
// names has, so it changes nothing until a value changes.
override_field_set :: proc(u:^Ui_Inspector,a:^host.Assets,override:int,field:ui.Node_Field,on:bool) {
    r:=&u.records
    if override<0 || override>=len(r.overrides) {return}
    o:=&r.overrides[override]
    data,nodes,ok:=override_nodes(u,a,int(o.instance))
    node:ui.Tree_Node
    found:=false
    if ok {
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        named,named_found:=data_node(data,nodes,serial.text_field(o.node[:]))
        node=named;found=named_found
    }
    if !found {
        if on {o.fields+={field}} else {o.fields-={field}}
        return
    }
    source:^Records
    if r.components[int(r.nodes[o.instance].component)-1].widget!={} {
        source=new(Records,context.temp_allocator)
        if !records_load(source,data,context.temp_allocator) {return}
    }
    records_override_field(r,override,field,on,source,node)
}

// A node of the tree renamed from one name to another, which the overrides
// of the .ui that instance it follow.
Node_Rename :: struct {from,to:[ui.TREE_NAME_CAPACITY]u8}

// The overrides of the .ui of the project that name node from of the .ui id,
// also through instances of widgets that instance it, name it to: one step
// of history for each file changed.
widget_rename_follow :: proc(s:^editor.Session,id:base.Asset_Id,from,to:string) {
    a:=s.app.assets
    if a==nil || from=="" || to=="" {return}
    for &file in a.registry.files {
        if file.kind!=asset.KIND_UI || file.id=={} || file.id==id {continue}
        records:Records
        if !records_read(a,file.id,&records,context.temp_allocator) {continue}
        if records_rename_follow(a,&records,id,from,to)>0 {records_write(s,file.id,&records,"Rename node")}
    }
}

// Renames from to to in the overrides of records that name node from of
// the .ui id, as widget_rename_follow does in each file; how many changed.
@(private)
records_rename_follow :: proc(a:^host.Assets,records:^Records,id:base.Asset_Id,from,to:string) -> (count:int) {
    for &o in records.overrides {
        c:=int(records.nodes[o.instance].component)-1 if int(o.instance)<len(records.nodes) else -1
        if c<0 || c>=len(records.components) {continue}
        count+=int(override_rename(a,o.node[:],records.components[c].widget,id,from,to))
    }
    return
}

// Renames from in the path of an override of an instance of widget where it
// names a node of the .ui id: each name past one of an instance is of the
// widget of that instance.
@(private)
override_rename :: proc(a:^host.Assets,field:[]u8,widget,id:base.Asset_Id,from,to:string) -> bool {
    path:=serial.text_field(field)
    w,start:=widget,0
    for depth:=0;w!={} && start<len(path) && depth<ui.TREE_DEPTH;depth+=1 {
        if w==id {return path_part_rename(field,start,from,to)}
        end:=strings.index_byte(path[start:],'/')
        end=len(path) if end<0 else start+end
        records:Records
        if !records_read(a,w,&records,context.temp_allocator) {return false}
        next:base.Asset_Id
        for &n in records.nodes {
            if serial.text_field(n.name[:])!=path[start:end] || n.kind!=.Component {continue}
            if c:=int(n.component)-1;c>=0 && c<len(records.components) {next=records.components[c].widget}
            break
        }
        w,start=next,end+1
    }
    return false
}
