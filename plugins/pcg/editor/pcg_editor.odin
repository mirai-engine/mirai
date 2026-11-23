package pcg_editor

import "base:runtime"
import "core:fmt"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import "mirai:editor/kit"
import volume "mirai:engine/volume"
import "mirai:host"
import "mirai:std/base"
import pcg_lib "mirai:std/pcg"
import "mirai:ui"
import pcg "plugins:pcg/runtime"

// What pcg gives the editor: the layers of a .pcg as flat rows, in Details
// under a Pcg_Graph, in the panel of the PCG tool and in the document of the
// asset, with their field and grammar texts compiled as they are typed; the
// density brush of the tool (pcg_brush.odin), the refresh of the cells an
// edit of the world moves (pcg_follow.odin), the inspection overlays
// (pcg_view.odin) and the pcg.* methods (pcg_api.odin). There is no node
// graph. A change of a source under a graph is a step of undo: the source
// goes to its file outside the history (editor.file_set) and the step keeps
// the revision of the Pcg_Graph that show it; the tool keeps the source of
// each revision, which undo and redo put back.

TOOL :: "pcg"
PANEL_SCOPE :: ui.Id(0x70636765)
TEXT_FIELD_BYTES :: 4096 // of a text the rows edit; a longer one is edited through pcg.layer
MESSAGE_BYTES :: 160
SCROLL_GUTTER :: ui.SCROLL_BAR+4

@(storage,free="pcg_tool_free")
Pcg_Tool :: struct {
    ready,active,over,begin:bool,
    using brush:Brush,
    adjust:editor.Brush_Adjust,
    stroke:Stroke,
    edit:Edit,
    using history:Revisions,
    draft:Draft,
    diagnostics:[dynamic]Diagnostic,
    open:[dynamic]u32,  // the ids of the layers whose rows are unfolded
    dirty:bool,         // a row of a layer changed while a drag holds it
    document:Document_Source,
    seen:[dynamic]Zone_Seen, // where the zones were at the last follow (pcg_follow.odin)
    scroll:[2]f32,
}

// The source the tool edits, read at the revision its graphs show.
Edit :: struct {
    entity:core.Entity,
    id:base.Asset_Id,
    revision:u32,
    stamp:pcg.Pcg_File_Stamp, // of the file it holds
    source:pcg.Pcg_Source,
    issue:pcg.Pcg_Issue,      // of the last read
    ready:bool,
}

// A text of a layer being typed that does not compile yet, or that waits to
// be kept: the rows show it with where it fails.
Draft :: struct {
    layer:u32,
    grammar:bool,
    active:bool,
    text:[TEXT_FIELD_BYTES]u8,
    length:int,
}

// What compiling a text of a layer said, made again when the text changes.
Diagnostic :: struct {
    layer:u32,
    grammar:bool,
    hash:u64,      // of the text and, for a grammar, of its symbols
    ok:bool,
    offset,length:int,
    message:[MESSAGE_BYTES]u8,
}

// The .pcg of the document in front, read again when its file changes.
Document_Source :: struct {
    id:base.Asset_Id,
    stamp:pcg.Pcg_File_Stamp,
    source:pcg.Pcg_Source,
    issue:pcg.Pcg_Issue,
    ready:bool,
    dirty:bool, // a row changes while a drag or a field holds it
}

pcg_tool_free :: proc(t:^Pcg_Tool) {
    pcg.source_destroy(&t.edit.source)
    pcg.source_destroy(&t.document.source)
    editor.revision_history_destroy(&t.history,REVISIONS)
    delete(t.diagnostics);delete(t.open);delete(t.seen)
    t^={}
}

tool_ready :: proc(t:^Pcg_Tool) {
    if t.ready {return}
    t.ready=true
    t.brush=BRUSH_DEFAULT
}

// The tool of the editor of a session; nil without the plugin.
tool_of :: proc(s:^editor.Session) -> ^Pcg_Tool {
    if s.editor_world==nil || s.info==nil {return nil}
    t:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Pcg_Tool)
    if t!=nil {tool_ready(t)}
    return t
}

pcg_file :: proc(a:^host.Assets,id:base.Asset_Id,allocator:=context.temp_allocator) -> (path:string,found:bool) {
    file:=asset.registry_find(&a.registry,id) or_return
    return asset.registry_file_path(&a.registry,file.path,allocator),true
}

// Puts a source in its file, outside the history of the editor (pcg_history.odin).
pcg_write :: proc(s:^editor.Session,a:^host.Assets,id:base.Asset_Id,source:^pcg.Pcg_Source) -> bool {
    path,found:=pcg_file(a,id)
    if !found {return false}
    bytes,error:=pcg.source_bytes(source,id,&a.types,a.allocator)
    if error!=.None {return false}
    defer delete(bytes,a.allocator)
    return editor.file_set(s,path,bytes)
}

// What makes a source not valid, as people read it.
issue_text :: proc(issue:pcg.Pcg_Issue,allocator:=context.temp_allocator) -> string {
    switch issue.kind {
    case .None:   return ""
    case .Unread: return "the .pcg cannot be read: it is missing, of another kind or version, or damaged"
    case .Memory: return "there is no memory to compile the layers: free memory, or give the source fewer layers"
    case .Info:   return fmt.aprintf("its cell size is out of %v to %v m, or it holds more than %d layers",pcg.CELL_SIZE_MIN,pcg.CELL_SIZE_MAX,pcg.LAYERS_MAX,allocator=allocator)
    case .Layer:  return fmt.aprintf("layer %d holds a value out of its range: densities and distances at least 0, scales from low to high above 0, align and weight from 0 to 1, a radius at most a quarter of the cell, a Cascade after its Scatter parent of a tier not after it",issue.layer,allocator=allocator)
    case .Field:  return fmt.aprintf("the field expression of layer %d does not compile at byte %d: %s",issue.layer,issue.field.offset,issue.field.message,allocator=allocator)
    case .Grammar:
        if issue.grammar.kind==.Unexpected_End && issue.grammar.offset==0 {return fmt.aprintf("Grammar layer %d needs a grammar and its symbols",issue.layer,allocator=allocator)}
        return fmt.aprintf("the grammar of layer %d does not compile at byte %d: %v",issue.layer,issue.grammar.offset,issue.grammar.kind,allocator=allocator)
    case .Cell:   return "a painted cell is out of range or of another size"
    }
    return ""
}

// The source of a graph, read again when it shows another source, another
// revision or its file changed. False when it cannot be read, with why in
// edit.issue.
edit_prepare :: proc(t:^Pcg_Tool,assets:^host.Assets,allocator:runtime.Allocator,graphs:^core.Table(pcg.Pcg_Graph,$A),e:core.Entity) -> bool {
    a:=assets
    graph,known:=core.get(graphs,e)
    if a==nil || !known || graph.source=={} {return false}
    edit:=&t.edit
    stamp:=pcg.data_stamp(a,graph.source)
    if !stamp.found {edit.issue={kind=.Unread};return false}
    if !edit.ready || edit.id!=graph.source || edit.revision!=graph.revision || edit.stamp!=stamp {
        next:pcg.Pcg_Source
        if issue:=pcg.data_read(&next,a,graph.source,allocator);issue.kind!=.None {
            pcg.source_destroy(&next)
            edit.issue=issue
            edit.ready=false
            return false
        }
        pcg.source_destroy(&edit.source)
        edit.source=next
        if edit.id!=graph.source {t.draft={}}
        edit.id,edit.revision,edit.ready=graph.source,graph.revision,true
        edit.stamp=stamp
        edit.issue={}
    }
    edit.entity=e
    return true
}

// The head of the source of the edit at its revision, before the edit
// changes: the first edit of a revision makes it, a copy of the source.
edit_baseline :: proc(t:^Pcg_Tool) -> bool {
    edit:=&t.edit
    entry:=editor.revision_applied(&t.history,edit.id)
    if entry==nil {
        append(&t.applied,Applied{source=edit.id,revision=edit.revision,stamp=edit.stamp})
        entry=&t.applied[len(t.applied)-1]
    }
    if entry.held && entry.revision==edit.revision {return true}
    pcg.source_destroy(&entry.head)
    if !pcg.source_copy(&entry.head,&edit.source,edit.source.allocator) {entry.held=false;return false}
    entry.held,entry.revision=true,edit.revision
    return true
}

// Shows what the edit holds before it is a step: the file in the memory of
// the registry, which the runtime reads again.
edit_preview :: proc(s:^editor.Session,t:^Pcg_Tool,assets:^host.Assets) -> bool {
    if !pcg_write(s,assets,t.edit.id,&t.edit.source) {return false}
    t.edit.stamp=pcg.data_stamp(assets,t.edit.id)
    if held:=editor.revision_applied(&t.history,t.edit.id);held!=nil {held.stamp=t.edit.stamp}
    return true
}

// Puts back the revision the edit started from: its head, and its file when
// a preview changed it.
edit_cancel :: proc(s:^editor.Session,t:^Pcg_Tool,assets:^host.Assets,previewed:=false) {
    head:=editor.revision_head(&t.history,t.edit.id,t.edit.revision)
    if head==nil {return}
    pcg.source_copy(&t.edit.source,head,t.edit.source.allocator)
    if previewed {edit_preview(s,t,assets)}
}

// The edit as one step of undo: the next revision in the file and in the
// Pcg_Graph that show the source, and what it changed in the history. False,
// changing nothing, with a notice, when it is not valid or cannot be written.
edit_commit :: proc(s:^editor.Session,t:^Pcg_Tool,world:core.World_Ref,assets:^host.Assets,label:string,previewed:=false) -> bool {
    a:=assets
    table:=core.world_table_of(world,pcg.Pcg_Graph)
    if a==nil || table==nil {return false}
    edit:=&t.edit
    if !edit_baseline(t) {editor.notify(s,"There is no memory to keep the PCG history");edit_cancel(s,t,a,previewed);return false}
    head:=editor.revision_head(&t.history,edit.id,edit.revision)
    if head==nil {return false}
    next:=edit.revision+1
    edit.source.info.revision=next
    if issue:=pcg.source_issue(&edit.source);issue.kind!=.None {
        editor.notify(s,fmt.tprintf("The PCG source is not kept: %s",issue_text(issue)))
        edit_cancel(s,t,a,previewed)
        return false
    }
    step:=Step{source=edit.id,from=edit.revision,to=next}
    if !step_make(&step,head,&edit.source) {editor.notify(s,"The PCG history could not be stored");edit_cancel(s,t,a,previewed);return false}
    if !pcg_write(s,a,edit.id,head) {
        step_apply(&step,head);step_destroy(&step)
        editor.notify(s,"The PCG source could not be written")
        edit_cancel(s,t,a,previewed)
        return false
    }
    editor.revision_push(&t.history,&step,step_destroy)
    edit.stamp=pcg.data_stamp(a,edit.id)
    history.edits_begin(s.edits,editor.document_selection(s),label)
    for value,row in table.values[:core.count(table)] {if value.source==edit.id {core.edit_at(table,row).revision=next}}
    history.edits_end(s.edits)
    edit.revision=next
    if held:=editor.revision_applied(&t.history,edit.id);held!=nil {held.revision,held.stamp=next,edit.stamp}
    t.dirty=false
    return true
}

// Undo and redo put back the revision of a source their step holds, and
// what changes the file outside the tool (git, the document of the asset) is
// the source of the revision its graphs show.
@(step="frame",stage="begin",after="editor_tools")
pcg_sync :: proc(s:^editor.Session,tool:^Pcg_Tool,graphs:^core.Table(pcg.Pcg_Graph,.Read),assets:^host.Assets) {
    tool_ready(tool)
    if assets==nil || tool.stroke.active || tool.dirty || editor.playing(s) {return}
    editor.revision_sync(s,&tool.history,graphs,assets,REVISIONS)
}

// The graph the tool and the rows edit: the last selected.
target :: proc(s:^editor.Session,graphs:^core.Table(pcg.Pcg_Graph,$A)) -> core.Entity {
    #reverse for e in s.selection.entities {if core.has(graphs,e) {return e}}
    return core.NONE
}

// ---------------------------------------------------------------- providers

@(storage)
Pcg_Documents :: struct {provider:editor.Asset_Document_Provider}
PCG_DOCUMENTS_DEFAULT :: Pcg_Documents{provider={kinds={0=pcg.PCG_KIND},count=1,flat={0},creates={0},create=pcg_create_bytes}}

// The empty source Create and asset.create make: no layers, a seed of its id.
@(private)
pcg_create_bytes :: proc(s:^editor.Session,kind:asset.Fourcc,id:base.Asset_Id) -> []u8 {
    if s.app==nil || s.app.assets==nil {return nil}
    source:pcg.Pcg_Source
    pcg.source_init(&source,context.temp_allocator)
    source.info.seed,source.info.revision=u32(base.hash_u64(id[0]~id[1])),1
    bytes,error:=pcg.source_bytes(&source,id,&s.app.assets.types,context.temp_allocator)
    pcg.source_destroy(&source)
    return bytes if error==.None else nil
}

@(storage)
Pcg_Inspector :: struct {provider:editor.Inspector_Provider}
PCG_INSPECTOR_DEFAULT :: Pcg_Inspector{provider={component=pcg_sections}}

@(storage)
Pcg_Components :: struct {provider:editor.Component_Provider}
PCG_COMPONENTS_DEFAULT :: Pcg_Components{provider={added=pcg_companion}}

// A Pcg_Zone given to an entity with neither a Volume nor a Spline takes a
// Volume: what it holds is where it weighs.
@(private)
pcg_companion :: proc(s:^editor.Session,e:core.Entity,t:^core.Table_Info) {
    if t==nil || t.type!=pcg.Pcg_Zone {return}
    w:=editor.edited_world(s)
    if editor.entity_has(w,e,volume.Volume) || editor.entity_has(w,e,volume.Spline) {return}
    shape:=volume.VOLUME_DEFAULT
    editor.component_add(s,e,editor.component_table(s,"Volume"),&shape)
}

// The section of a Pcg_Graph in Details: its fields, and for one graph, how
// its source stands and the rows of its layers.
@(private)
pcg_sections :: proc(c:editor.Inspector_Context) -> bool {
    if c.table==nil || c.table.type!=pcg.Pcg_Graph || len(c.entities)==0 {return false}
    s:=c.session
    editor.inspector_fields(c)
    t:=tool_of(s)
    graphs:=core.world_table_of(c.world,pcg.Pcg_Graph)
    if t==nil || graphs==nil || len(c.entities)!=1 || editor.playing(s) || s.app==nil {return true}
    e:=c.entities[0]
    graph,_:=core.get(graphs,e)
    if graph.source=={} {
        ctx:=s.gui.ctx
        if ui.button(ctx,ui.id(ctx,"pcg_new_source"),{label="New PCG source",variant="field",width=-1,center=true}).clicked {graph_source_new(s,t,c.world,s.app.assets,e)}
        return true
    }
    if !edit_prepare(t,s.app.assets,s.app.allocator,graphs,e) {
        ui.label(s.gui.ctx,fmt.tprintf("The source cannot be edited: %s",issue_text(t.edit.issue)),ui.metric(s.gui.ctx,"font_small"),ui.tone(s.gui.ctx,"danger"))
        return true
    }
    graph_rows(s,t,c.world)
    return true
}

// The rows of the source of the graph the edit holds, kept as a step.
graph_rows :: proc(s:^editor.Session,t:^Pcg_Tool,world:core.World_Ref) {
    if !edit_baseline(t) {return}
    result:=layers_rows(s,t,&t.edit.source,u64(t.edit.id[0]),&t.dirty)
    if result.cancel {edit_cancel(s,t,s.app.assets);return}
    if result.label!="" {edit_commit(s,t,world,s.app.assets,result.label)}
}

// A new .pcg of no layers for a graph without a source, in the same step.
graph_source_new :: proc(s:^editor.Session,t:^Pcg_Tool,world:core.World_Ref,assets:^host.Assets,e:core.Entity) -> bool {
    graphs:=core.world_table_of(world,pcg.Pcg_Graph)
    if assets==nil || graphs==nil {return false}
    history.edits_begin(s.edits,editor.document_selection(s),"New PCG source")
    id,made:=source_file_new(s,t,assets,editor.entity_label(world,e),false,0,pcg.CELL_SIZE_DEFAULT)
    if !made {history.edits_cancel(s.edits,world);return false}
    if g:=core.edit(graphs,e);g!=nil {g.source,g.revision=id,1}
    history.edits_end(s.edits)
    return true
}

// A new .pcg of no layers beside the scene, in the step that is open. Its
// id, and whether it was made.
source_file_new :: proc(s:^editor.Session,t:^Pcg_Tool,a:^host.Assets,name:string,named:bool,seed:u32,cell_size:f32) -> (id:base.Asset_Id,ok:bool) {
    _,path:=editor.asset_new_file(s,fmt.tprintf("%s/pcg",a.registry.root),name!=""?name:"PCG",pcg.PCG_EXTENSION,named)
    h:=base.hash_combine(base.name_hash(path),s.id_state+1)
    s.id_state+=1
    id=base.Asset_Id{h,base.hash_combine(h,base.name_hash("pcg"))}
    source:pcg.Pcg_Source
    pcg.source_init(&source,context.temp_allocator)
    source.info.seed=seed!=0?seed:u32(h)
    source.info.cell_size,source.info.revision=cell_size,1
    bytes,error:=pcg.source_bytes(&source,id,&a.types,context.temp_allocator)
    pcg.source_destroy(&source)
    if error!=.None {editor.notify(s,"The PCG source could not be written");return}
    if !editor.file_write(s,path,bytes,"New PCG source") {editor.notify(s,"The PCG source could not be written");return}
    append(&t.applied,Applied{source=id,revision=1,stamp=pcg.data_stamp(a,id)})
    return id,true
}

// ---------------------------------------------------------------- rows of the layers

// What the rows did this frame: label names the step of a change that
// settled; cancel, a value that settled is not valid.
Rows_Result :: struct {
    label:string,
    cancel:bool,
}

@(rodata) KIND_NAMES := [pcg.Pcg_Layer_Kind]string{.Scatter="Scatter",.Cascade="Cascade",.Grammar="Grammar"}
@(rodata) TIER_NAMES := [pcg.Pcg_Tier]string{.Macro="Macro",.Meso="Meso",.Micro="Micro"}

// The fields of a layer the rows show, in their order.
@(rodata) LAYER_FIELDS := [?]string{"tier","asset","density","radius","scale","height","yaw","tilt","align","offset","parent_layer","channel","collides","filler","dither_group","cull_distance","fade_distance","impostor_distance","ground_rule"}

// The flat rows of the layers of a source: add, take out and move each,
// its values, and its field and grammar texts compiled as they are typed.
// They change source in place; the caller keeps what they report. dirty
// holds, from frame to frame, that a value changes while a drag or a field
// holds it.
layers_rows :: proc(s:^editor.Session,t:^Pcg_Tool,source:^pcg.Pcg_Source,scope:u64,dirty:^bool) -> (result:Rows_Result) {
    ctx:=s.gui.ctx
    ui.id_push(ctx,ui.Id(scope|1));defer ui.id_pop(ctx)
    kit.section(ctx,"Layers",fmt.tprintf("%d",len(source.layers)),40)
    if kit.segments(ctx,ui.GROW,ui.metric(ctx,"control")) {
        for kind in pcg.Pcg_Layer_Kind {
            if ui.button(ctx,ui.id(ctx,"add",int(kind)+1),{label=fmt.tprintf("+ %s",KIND_NAMES[kind]),variant="tab",width=-1,height=ui.metric(ctx,"control")-4,size=ui.metric(ctx,"font_small")}).clicked {
                if layer_add(source,kind)!=nil {result.label="Add PCG layer"} else {editor.notify(s,"The source holds as many layers as it can")}
            }
        }
    }
    moved,removed:=-1,u32(0)
    up:=false
    for &l,i in source.layers {
        open:=slice.contains(t.open[:],l.id)
        was:=open
        title:=fmt.tprintf("%d · %s · %s",l.id,KIND_NAMES[l.kind],TIER_NAMES[l.tier])
        folded:=kit.collapsible(ctx,ui.id(ctx,"layer",int(l.id)),title,&open,{removable=true,note=layer_note(s,t,&l)})
        if open!=was {
            if open {append(&t.open,l.id)} else if at,found:=slice.linear_search(t.open[:],l.id);found {unordered_remove(&t.open,at)}
        }
        if folded.removed {removed=l.id}
        if !folded.open {continue}
        ui.id_push(ctx,ui.Id(u64(l.id)<<8|0x55));defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
            if ui.button(ctx,ui.id(ctx,"up"),{icon=.Chevron_Up,variant="ghost",width=24,disabled=i==0}).clicked {moved,up=i,true}
            if ui.button(ctx,ui.id(ctx,"down"),{icon=.Chevron_Down,variant="ghost",width=24,disabled=i==len(source.layers)-1}).clicked {moved,up=i,false}
        }
        defaults:=pcg.PCG_LAYER_DEFAULT
        h:=editor.Held_Values{key=u64(PANEL_SCOPE)<<32|u64(l.id),info=type_info_of(pcg.Pcg_Layer_Params),value=&l.params,defaults=&defaults}
        for field in LAYER_FIELDS {
            if field=="parent_layer" && l.kind!=.Cascade {continue}
            if field=="channel" && l.kind!=.Grammar {continue}
            if field=="dither_group" && l.kind!=.Scatter {continue}
            if editor.held_field_row(s,h,field) {dirty^=true}
        }
        if text,changed:=text_row(s,t,&l,false);changed {
            if pcg.source_layer_texts(source,l.id,text,l.grammar_expr,l.grammar_symbols) {result.label="PCG field expression"}
        }
        if l.kind==.Grammar {
            if text,changed:=text_row(s,t,&l,true);changed {
                if pcg.source_layer_texts(source,l.id,l.field_expr,text,l.grammar_symbols) {result.label="PCG grammar"}
            }
            if label,held:=symbols_rows(s,source,&l);label!="" {result.label=label} else if held {dirty^=true}
        }
    }
    if removed!=0 {
        if pcg.source_layer_remove(source,removed) {result.label="Remove PCG layer"}
    } else if moved>=0 {
        other:=moved-1 if up else moved+1
        held:=source.layers[moved]
        source.layers[moved]=source.layers[other]
        source.layers[other]=held
        pcg.source_compiled_free(source)
        result.label="Move PCG layer"
    }
    // A value dragged or typed is kept once it settles; one out of its range goes back.
    if result.label=="" && dirty^ && !pointer_held(ctx) && ctx.edit.id==0 {
        if issue:=pcg.source_issue(source);issue.kind==.None {result.label="PCG layer"} else {
            editor.notify(s,fmt.tprintf("The value is not kept: %s",issue_text(issue)))
            result.cancel=true
        }
    }
    if result.label!="" || result.cancel {dirty^=false}
    return
}

// A new layer of a kind at the end, with what it needs to be valid: a
// Cascade grows around the last Scatter layer, a Grammar has one module.
layer_add :: proc(source:^pcg.Pcg_Source,kind:pcg.Pcg_Layer_Kind) -> ^pcg.Pcg_Layer {
    parent:u32
    if kind==.Cascade {
        #reverse for l in source.layers {if l.kind==.Scatter {parent=l.id;break}}
        if parent==0 {return nil}
    }
    l:=pcg.source_layer_add(source,kind)
    if l==nil {return nil}
    id:=l.id
    switch kind {
    case .Scatter:
    case .Cascade: l.parent_layer,l.density=parent,2
    case .Grammar:
        symbols:=[1]pcg.Grammar_Symbol_Def{pcg.grammar_symbol("bay",4,true)}
        if !pcg.source_layer_texts(source,id,"","[bay]*",symbols[:]) {pcg.source_layer_remove(source,id);return nil}
    }
    found,_:=pcg.source_layer(source,id)
    return found
}

// What the title of a layer notes: why its texts do not compile.
@(private)
layer_note :: proc(s:^editor.Session,t:^Pcg_Tool,l:^pcg.Pcg_Layer) -> string {
    if d:=diagnostic_of(t,l,false,l.field_expr);!d.ok {return "field fails"}
    if l.kind==.Grammar {if d:=diagnostic_of(t,l,true,l.grammar_expr);!d.ok {return "grammar fails"}}
    return ""
}

// The field expression or the grammar of a layer: what is typed compiles at
// each key, and what fails says where. The text, once it compiles and the
// typing ends.
@(private)
text_row :: proc(s:^editor.Session,t:^Pcg_Tool,l:^pcg.Pcg_Layer,grammar:bool) -> (text:string,changed:bool) {
    ctx:=s.gui.ctx
    id:=ui.id(ctx,"grammar" if grammar else "field")
    kept:=l.grammar_expr if grammar else l.field_expr
    d:=&t.draft
    mine:=d.active && d.layer==l.id && d.grammar==grammar
    if !mine && ctx.edit.id==id {
        d^={layer=l.id,grammar=grammar,active=true}
        d.length=copy(d.text[:],kept)
        mine=true
    }
    shown:=string(d.text[:d.length]) if mine else kept
    diagnostic:=diagnostic_of(t,l,grammar,shown)
    kit.column_label(ctx,"Grammar" if grammar else "Field")
    buffer:[]u8
    length:int
    if mine {buffer,length=d.text[:],d.length} else {
        buffer=make([]u8,TEXT_FIELD_BYTES,context.temp_allocator)
        length=copy(buffer,kept)
    }
    r:=ui.text_field(ctx,id,buffer,&length,{live=true,multiline=true,rows=2,keep_caret=true,placeholder="1 everywhere" if !grammar else "[bay]*",disabled=len(kept)>=TEXT_FIELD_BYTES,strip=ui.tone(ctx,"danger") if !diagnostic.ok else {}})
    if mine {d.length=length}
    if !diagnostic.ok {
        message:=base.text_get(diagnostic.message[:])
        ui.label(ctx,fmt.tprintf("byte %d: %s",diagnostic.offset,message),ui.metric(ctx,"font_small"),ui.tone(ctx,"danger"))
    }
    if mine && (r.committed || r.cancelled || ctx.edit.id!=id) {
        typed:=string(d.text[:d.length])
        valid:=diagnostic_of(t,l,grammar,typed).ok
        if r.cancelled {d^={};return}
        // A text that fails stays a draft until it compiles.
        if !valid {return}
        d.active=false
        if typed!=kept {return typed,true}
    }
    return
}

// What compiling a text of a layer says, from the cache while it is the same.
diagnostic_of :: proc(t:^Pcg_Tool,l:^pcg.Pcg_Layer,grammar:bool,text:string) -> Diagnostic {
    hash:=base.hash64(transmute([]u8)text)
    if grammar {hash=base.hash64(mem_bytes(l.grammar_symbols),hash)}
    for &d in t.diagnostics {if d.layer==l.id && d.grammar==grammar {
        if d.hash==hash {return d}
        d=text_compile(l,grammar,text)
        d.hash=hash
        return d
    }}
    d:=text_compile(l,grammar,text)
    d.hash=hash
    append(&t.diagnostics,d)
    return d
}

@(private)
pointer_held :: proc "contextless" (ctx:^ui.Context) -> bool {return ctx.input.down!={}}

@(private)
mem_bytes :: proc(symbols:[]pcg.Grammar_Symbol_Def) -> []u8 {return ([^]u8)(raw_data(symbols))[:len(symbols)*size_of(pcg.Grammar_Symbol_Def)]}

// Compiles a text as the field or the grammar of a layer, and says how it went.
text_compile :: proc(l:^pcg.Pcg_Layer,grammar:bool,text:string) -> (d:Diagnostic) {
    d.layer,d.grammar,d.ok=l.id,grammar,true
    if !grammar {
        if text=="" {return}
        program,err:=pcg_lib.field_compile(text,context.temp_allocator)
        pcg_lib.field_program_destroy(&program)
        if err.kind==.None {return}
        d.ok,d.offset,d.length=false,err.offset,err.length
        base.text_set(d.message[:],err.message!=""?err.message:fmt.tprint(err.kind))
        return
    }
    symbols:=make([]pcg_lib.Grammar_Symbol,len(l.grammar_symbols),context.temp_allocator)
    for &def,i in l.grammar_symbols {symbols[i]={name=base.text_get(def.name[:]),unit_size=def.unit_size,scalable=def.scalable}}
    if text=="" || len(symbols)==0 {
        d.ok=false
        base.text_set(d.message[:],"a Grammar layer needs a grammar and at least one symbol")
        return
    }
    program,err:=pcg_lib.grammar_compile(text,symbols,context.temp_allocator)
    pcg_lib.grammar_destroy(&program)
    if err.kind==.None {return}
    d.ok,d.offset=false,err.offset
    base.text_set(d.message[:],err.symbol>=0?fmt.tprintf("%v (symbol %d)",err.kind,err.symbol+1):fmt.tprint(err.kind))
    return
}

// The symbols of a Grammar layer, each with its name, unit size, whether it
// stretches and what it places; one more, or one less.
@(private)
symbols_rows :: proc(s:^editor.Session,source:^pcg.Pcg_Source,l:^pcg.Pcg_Layer) -> (label:string,dirty:bool) {
    ctx:=s.gui.ctx
    kit.section(ctx,"Symbols",fmt.tprintf("%d",len(l.grammar_symbols)),40)
    removed:=-1
    defaults:=pcg.Grammar_Symbol_Def{unit_size=1}
    for &def,i in l.grammar_symbols {
        ui.id_push(ctx,ui.Id(u64(i)+1<<20));defer ui.id_pop(ctx)
        h:=editor.Held_Values{key=u64(PANEL_SCOPE)<<32|u64(l.id)<<12|u64(i+1),info=type_info_of(pcg.Grammar_Symbol_Def),value=&def,defaults=&defaults}
        for field in ([?]string{"name","unit_size","scalable","asset"}) {if editor.held_field_row(s,h,field) {dirty=true}}
        if ui.button(ctx,ui.id(ctx,"remove_symbol"),{label="Remove symbol",variant="field",width=-1,center=true,disabled=len(l.grammar_symbols)<=1}).clicked {removed=i}
    }
    if len(l.grammar_symbols)<pcg.SYMBOLS_MAX && ui.button(ctx,ui.id(ctx,"add_symbol"),{label="Add symbol",variant="field",width=-1,center=true}).clicked {
        symbols:=make([dynamic]pcg.Grammar_Symbol_Def,0,len(l.grammar_symbols)+1,context.temp_allocator)
        append(&symbols,..l.grammar_symbols)
        append(&symbols,pcg.grammar_symbol(fmt.tprintf("s%d",len(symbols)+1),1))
        if pcg.source_layer_texts(source,l.id,l.field_expr,l.grammar_expr,symbols[:]) {label="Add PCG symbol"}
    }
    if removed>=0 {
        symbols:=make([dynamic]pcg.Grammar_Symbol_Def,0,len(l.grammar_symbols),context.temp_allocator)
        append(&symbols,..l.grammar_symbols)
        ordered_remove(&symbols,removed)
        if pcg.source_layer_texts(source,l.id,l.field_expr,l.grammar_expr,symbols[:]) {label="Remove PCG symbol"}
    }
    return
}

// ---------------------------------------------------------------- the document of a .pcg

// The document of a .pcg in front: its info and the rows of its layers,
// whose changes are steps of the history of the document (editor.file_write).
@(step="ui",after="editor_panels")
pcg_document :: proc(s:^editor.Session,tool:^Pcg_Tool,assets:^host.Assets,allocator:runtime.Allocator) {
    g:=s.gui
    d:=editor.asset_document_active(s)
    if d==nil || d.kind!=pcg.PCG_KIND || editor.playing(s) || !g.begun || assets==nil {return}
    tool_ready(tool)
    doc:=&tool.document
    stamp:=pcg.data_stamp(assets,d.id)
    if !doc.ready || doc.id!=d.id || doc.stamp!=stamp {
        next:pcg.Pcg_Source
        doc.issue=pcg.data_read(&next,assets,d.id,allocator)
        if doc.issue.kind==.None {pcg.source_destroy(&doc.source);doc.source=next} else {pcg.source_destroy(&next)}
        doc.id,doc.stamp,doc.ready=d.id,stamp,doc.issue.kind==.None
    }
    ctx:=g.ctx
    id:=ui.id_derive(ctx,PANEL_SCOPE,"document")
    _,details,room:=editor.asset_workspace_details(s)
    if ui.panel(ctx,id,details) {
        ui.id_push(ctx,id);defer ui.id_pop(ctx)
        if ui.scroll_area(ctx,ui.id(ctx,"scroll"),&tool.scroll,{height=ui.FIT,max_height=room,gap=8,padding={0,0,SCROLL_GUTTER,0}}) {
            if !doc.ready {
                ui.label(ctx,fmt.tprintf("The source cannot be edited: %s",issue_text(doc.issue)),ui.metric(ctx,"font_small"),ui.tone(ctx,"danger"))
                return
            }
            source:=&doc.source
            kit.section(ctx,"Source",fmt.tprintf("revision %d",source.info.revision),100)
            info_defaults:=pcg.Pcg_Info{cell_size=pcg.CELL_SIZE_DEFAULT,next_layer=1}
            held:=source.info
            h:=editor.Held_Values{key=u64(PANEL_SCOPE)<<32|0xffff_0000,info=type_info_of(pcg.Pcg_Info),value=&held,defaults=&info_defaults}
            changed:=false
            for field in ([?]string{"seed","cell_size","ecotopes"}) {changed|=editor.held_field_row(s,h,field)}
            if changed {
                source.info.seed,source.info.cell_size,source.info.ecotopes=held.seed,held.cell_size,held.ecotopes
                pcg.source_compiled_free(source)
                doc.dirty=true
            }
            result:=layers_rows(s,tool,source,u64(d.id[0])|2,&doc.dirty)
            label:=result.label
            if result.cancel {doc.ready=false;return}
            if label=="" {return}
            if issue:=pcg.source_issue(source);issue.kind!=.None {
                editor.notify(s,fmt.tprintf("The PCG source is not kept: %s",issue_text(issue)))
                doc.ready=false
                return
            }
            source.info.revision+=1
            path,found:=pcg_file(assets,d.id)
            bytes,error:=pcg.source_bytes(source,d.id,&assets.types,context.temp_allocator)
            if !found || error!=.None || !editor.file_write(s,path,bytes,label) {editor.notify(s,"The PCG source could not be written")}
            doc.ready=false
        }
    }
}
