package editor

import "core:fmt"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:ui"

// Assets open in tabs next to the scenes. The
// document in front takes the place of the scene: the scene that was active
// stays loaded under it, with its history, its Play stopped and its tools
// quiet, and the API and the agents keep working on it. The left panel stays;
// Details and the tools of the viewport leave. A document has its own
// history: the files its UI writes outside a gesture of the scene are steps
// of it (file_write), and Save writes its asset. What is unsaved is what the
// registry holds in memory (assets_unsaved.odin), so the dot of a tab, Save
// all and the questions about unsaved changes are those of every asset.
//
// The editor draws the documents of materials, and of the source of a program
// alone; a plugin opens the kinds its storage declares with an
// Asset_Document_Provider and draws them from a step of the ui phase into
// asset_workspace, with what plays in asset_toolbar.

ASSET_DOCUMENT_KINDS :: 8         // of a provider
ASSET_HISTORY_BYTES :: 64<<20     // the steps of a document may hold

Asset_Step :: struct {
    label:[history.EDIT_LABEL_BYTES]u8,
    files:[dynamic]history.Edit_File,
    bytes:int,
}

// The undo of an asset document: steps of the files its UI changed.
Asset_History :: struct {
    steps:[dynamic]Asset_Step,
    cursor:int,                // undo goes back through steps[:cursor], redo forward through steps[cursor:]
    open:bool,                 // a gesture is open: what it changes is one step
    label:[history.EDIT_LABEL_BYTES]u8,
    files:[dynamic]history.Edit_File,  // the open gesture changed them
    registry:^asset.Registry,
    touched:[dynamic]string,   // changed since files_settle loaded them again
    files_kept:int,            // changed outside the editor, they kept their content
    bytes:int,
}

Asset_Document :: struct {
    id:base.Asset_Id,   // zero: the source of a program alone
    kind:asset.Fourcc,  // of the asset; a program alone is a material document
    path:[512]u8,       // absolute, of the source of a program alone
    history:Asset_History,
    part:[64]u8,        // what of the asset to show when it comes to the front: a clip of a library; its document takes it and clears it
    // What the user picked in it, by name, for the context of the AI: the
    // plugin of its kind writes it while the document is in front.
    picked:[ASSET_DOCUMENT_PICKS][64]u8,
    picked_count:int,
    // What it shows now, in a line, for the context of the AI: the clip and
    // its time of an animation. The plugin of its kind writes it while the
    // document is in front.
    shown:[256]u8,
    // The last entry run on it of those its documents take in place of the
    // scene (Asset_Document_Provider.takes), by its name: its plugin runs it
    // once for each serial.
    request:string,
    request_serial:u64,
}
ASSET_DOCUMENT_PICKS :: 8
ASSET_DOCUMENT_TAKES :: 8

// A storage of an editor package whose sole field is this declares, in its
// default, the kinds of asset its steps draw as documents, of those the ones
// whose hierarchy it builds in hierarchy_room and the ones that draw no
// world (flat: the bar leaves Graphics out), the ones Create of the content
// browser and asset.create make (creates: kinds of asset.KINDS, whose empty
// file create gives, made with the id it is given; nil: it could not), and the
// entries that work on the scene its documents take instead (copy, paste,
// duplicate, delete, rename, select_all, deselect), by their names: with one
// in front their keys work on what the document has chosen, inside its panel,
// and reach its plugin as Asset_Document.request. between, when given, runs between frames while one
// of its documents is in front: what needs frames of its own (a world drawn
// into a texture, host.app_world_draw).
Asset_Document_Provider :: struct {
    kinds:[ASSET_DOCUMENT_KINDS]asset.Fourcc,
    count:int,
    hierarchy:bit_set[0..<ASSET_DOCUMENT_KINDS],
    flat:bit_set[0..<ASSET_DOCUMENT_KINDS],
    creates:bit_set[0..<ASSET_DOCUMENT_KINDS],
    create:proc(s:^Session,kind:asset.Fourcc,id:base.Asset_Id) -> []u8, // in the temporary allocator
    takes:[ASSET_DOCUMENT_TAKES]string,
    between:proc(s:^Session,d:^Asset_Document),
}

// ---------------------------------------------------------------- history

@(private)
asset_step_free :: proc(step:^Asset_Step) {
    for &file in step.files {history.edit_file_free(&file)}
    delete(step.files)
    step^={}
}

asset_history_free :: proc(h:^Asset_History) {
    for &step in h.steps {asset_step_free(&step)}
    delete(h.steps)
    history.files_free(&h.files,&h.touched)
    h^={}
}

// Opens a gesture: what changes until asset_history_end is one step, named
// label. False when one was open, which the change joins.
asset_history_begin :: proc(h:^Asset_History,label:string) -> bool {
    if h.open {return false}
    h.open=true
    history.text_put(h.label[:],label)
    return true
}

// Ends the gesture: what it changed is a step, which drops what redo had.
asset_history_end :: proc(h:^Asset_History) {
    if !h.open {return}
    h.open=false
    if len(h.files)==0 {return}
    for &step in h.steps[h.cursor:] {
        h.bytes-=step.bytes
        asset_step_free(&step)
    }
    resize(&h.steps,h.cursor)
    step:=Asset_Step{label=h.label,files=h.files}
    for &file in step.files {step.bytes+=history.edit_file_bytes(&file)}
    h.files=nil
    if _,error:=append(&h.steps,step);error!=nil {
        asset_step_free(&step)
        return
    }
    h.cursor=len(h.steps)
    h.bytes+=step.bytes
    for len(h.steps)>1 && (len(h.steps)>history.EDITS_STEP_CAPACITY || h.bytes>ASSET_HISTORY_BYTES) {
        h.bytes-=h.steps[0].bytes
        asset_step_free(&h.steps[0])
        ordered_remove(&h.steps,0)
        h.cursor-=1
    }
}

// Puts back what the open gesture changed and closes it.
asset_history_cancel :: proc(h:^Asset_History) {
    history.files_restore(h.registry,&h.files,&h.touched,&h.files_kept)
    h.open=false
}

asset_history_undo :: proc(h:^Asset_History) -> bool {
    if h.open {asset_history_cancel(h)}
    if h.cursor==0 {return false}
    step:=&h.steps[h.cursor-1]
    history.files_swap(h.registry,step.files[:],&h.touched,&h.files_kept)
    h.cursor-=1
    return true
}

asset_history_redo :: proc(h:^Asset_History) -> bool {
    if h.open {asset_history_cancel(h)}
    if h.cursor>=len(h.steps) {return false}
    step:=&h.steps[h.cursor]
    history.files_swap(h.registry,step.files[:],&h.touched,&h.files_kept)
    h.cursor+=1
    return true
}

// The label of the step undo would take back; empty without one.
asset_history_undo_label :: proc(h:^Asset_History) -> string {
    if h.cursor==0 {return ""}
    return history.cstring_text(h.steps[h.cursor-1].label[:])
}
asset_history_redo_label :: proc(h:^Asset_History) -> string {
    if h.cursor>=len(h.steps) {return ""}
    return history.cstring_text(h.steps[h.cursor].label[:])
}

// The history that takes a file an edit writes now: that of the asset
// document in front, unless a gesture of the scene is open (the API, a tool),
// which keeps it.
asset_history_front :: proc(s:^Session) -> ^Asset_History {
    d:=asset_document_active(s)
    if d==nil || playing(s) || s.edits!=nil && s.edits.open {return nil}
    return &d.history
}

// file_write into the history of a document: in its open gesture or in a
// step of its own named label.
@(private)
asset_history_write :: proc(s:^Session,h:^Asset_History,path:string,bytes:[]u8,label:string,remove:bool) -> bool {
    r:=files_registry(s)
    before,present,readable:=history.file_contents(r,path,context.temp_allocator)
    if !readable {
        notify(s,"The file could not be read before changing it")
        return false
    }
    h.registry=r
    opened:=asset_history_begin(h,label)
    written:=history.file_put(r,path,!remove,bytes)
    if written {
        file_changed(s,path)
        if !history.files_record(&h.files,path,present,before,!remove,remove?nil:bytes) {notify(s,"The file changed without a step of undo")}
    }
    if opened {asset_history_end(h)}
    return written
}

// file_write into the history of a document, in front or not: what its
// plugin held unwritten when another came to the front.
asset_document_write :: proc(s:^Session,d:^Asset_Document,path:string,bytes:[]u8,label:string) -> bool {
    if len(bytes)>history.EDITS_FILE_BYTES {return file_set(s,path,bytes)}
    return asset_history_write(s,&d.history,path,bytes,label,false)
}

// ---------------------------------------------------------------- documents

// The asset document in front of the scenes; nil while a scene is.
asset_document_active :: proc "contextless" (s:^Session) -> ^Asset_Document {
    if s.asset_shown<=0 || s.asset_shown>len(s.asset_documents) {return nil}
    return &s.asset_documents[s.asset_shown-1]
}

// An asset document in front covers the scene: it is not drawn and its tools,
// picking and edits by hand wait.
scene_covered :: proc "contextless" (s:^Session) -> bool {return asset_document_active(s)!=nil}

// The path its unsaved changes are kept by: in the registry, or the absolute
// one of the source of a program alone. Empty for an asset that is gone.
// What the plugin of a document says it shows now (Asset_Document.shown).
asset_document_show_say :: proc(d:^Asset_Document,text:string) {base.text_set(d.shown[:],text)}

// What the plugin of a document says the user picked in it (Asset_Document.picked).
asset_document_pick :: proc(d:^Asset_Document,names:[]string) {
    d.picked_count=min(len(names),len(d.picked))
    for name,i in names[:d.picked_count] {base.text_set(d.picked[i][:],name)}
}

// The document in front that is not the scene, outside Play: what the AI
// talks about instead of the entities of the scene.
asset_document_in_front :: proc(s:^Session) -> ^Asset_Document {
    if playing(s) {return nil}
    return asset_document_active(s)
}

asset_document_path :: proc(s:^Session,d:^Asset_Document) -> string {
    if d.id=={} {return base.text_get(d.path[:])}
    if s.app==nil || s.app.assets==nil {return ""}
    if file,found:=asset.registry_find(&s.app.assets.registry,d.id);found {return file.path}
    return ""
}

asset_document_title :: proc(s:^Session,d:^Asset_Document) -> string {
    path:=asset_document_path(s,d)
    if path=="" {return "Missing asset"}
    return asset_name(path)
}

asset_document_dirty :: proc(s:^Session,d:^Asset_Document) -> bool {
    for path in asset_document_paths(s,d) {
        for held in assets_unsaved(s) {
            if held.path==path {return true}
        }
    }
    return false
}

// What Save writes of a document: its file, and the others its steps
// changed (the texts a .ui edits in their languages), by registry path.
asset_document_paths :: proc(s:^Session,d:^Asset_Document) -> []string {
    paths:=make([dynamic]string,context.temp_allocator)
    path:=asset_document_path(s,d)
    if path=="" {return nil}
    append(&paths,path)
    if s.app==nil || s.app.assets==nil {return paths[:]}
    r:=&s.app.assets.registry
    add :: proc(paths:^[dynamic]string,r:^asset.Registry,files:[]history.Edit_File) {
        for &file in files {
            relative,ok:=asset.registry_relative(r,file.path)
            if !ok || slice.contains(paths[:],relative) {continue}
            append(paths,relative)
        }
    }
    for &step in d.history.steps {add(&paths,r,step.files[:])}
    add(&paths,r,d.history.files[:])
    return paths[:]
}

asset_document_icon :: proc(s:^Session,d:^Asset_Document) -> ui.Icon {
    if d.id=={} {return .Material}
    icon,_:=asset_icon(s,d.kind)
    return icon
}

// Whether a kind of asset opens as a document: the materials, or a kind a
// provider declares.
asset_document_opens :: proc(s:^Session,kind:asset.Fourcc) -> bool {
    return kind==asset.KIND_MATERIAL || slice.contains(asset_document_kinds(s),kind)
}

// The kinds the plugins open as documents (Asset_Document_Provider).
asset_document_kinds :: proc(s:^Session,allocator:=context.temp_allocator) -> []asset.Fourcc {
    kinds:=make([dynamic]asset.Fourcc,allocator)
    if s.info==nil {return kinds[:]}
    found:[PROVIDER_CAPACITY]Asset_Document_Provider
    for &provider in found[:provided_all(s,found[:])] {
        append(&kinds,..provider.kinds[:clamp(provider.count,0,len(provider.kinds))])
    }
    return kinds[:]
}

// Whether the documents of a kind take an entry that works on the scene.
asset_document_takes :: proc(s:^Session,kind:asset.Fourcc,name:string) -> bool {
    if s.info==nil {return false}
    found:[PROVIDER_CAPACITY]Asset_Document_Provider
    for &provider in found[:provided_all(s,found[:])] {
        for i in 0..<clamp(provider.count,0,len(provider.kinds)) {
            if provider.kinds[i]==kind && slice.contains(provider.takes[:],name) {return true}
        }
    }
    return false
}

// Whether the documents of a kind show a hierarchy their plugin builds.
asset_document_hierarchy :: proc(s:^Session,kind:asset.Fourcc) -> bool {
    if s.info==nil {return false}
    found:[PROVIDER_CAPACITY]Asset_Document_Provider
    for &provider in found[:provided_all(s,found[:])] {
        for i in 0..<clamp(provider.count,0,len(provider.kinds)) {
            if provider.kinds[i]==kind && i in provider.hierarchy {return true}
        }
    }
    return false
}

// What the provider of the document in front does between frames.
@(private)
asset_document_between :: proc(s:^Session) {
    d:=asset_document_active(s)
    if d==nil || s.info==nil {return}
    found:[PROVIDER_CAPACITY]Asset_Document_Provider
    for &provider in found[:provided_all(s,found[:])] {
        if provider.between!=nil && slice.contains(provider.kinds[:clamp(provider.count,0,len(provider.kinds))],d.kind) {provider.between(s,d)}
    }
}

// Whether the documents of a kind draw no world: no graphics apply to them.
asset_document_flat :: proc(s:^Session,kind:asset.Fourcc) -> bool {
    if s.info==nil {return false}
    found:[PROVIDER_CAPACITY]Asset_Document_Provider
    for &provider in found[:provided_all(s,found[:])] {
        for i in 0..<clamp(provider.count,0,len(provider.kinds)) {
            if provider.kinds[i]==kind && i in provider.flat {return true}
        }
    }
    return false
}

// The room the Hierarchy of the left panel leaves to the document in front,
// as the last frame laid it out: its plugin builds its hierarchy in a box
// that floats over it.
hierarchy_room :: proc(g:^Editor_Ui) -> (rect:ui.Rect,ok:bool) {
    if !g.layout.left_open || g.layout.library_tab!=.Hierarchy {return}
    return ui.widget_rect(g.ctx,shell_id(g,"hierarchy_room"))
}

// Opens an asset in its document, or brings the one it has to the front, at
// the end of the frame. False for an asset that is not there or a kind that
// opens no document.
asset_document_open :: proc(s:^Session,id:base.Asset_Id,part:="") -> bool {
    if s.app==nil || s.app.assets==nil || id=={} {return false}
    file,found:=asset.registry_find(&s.app.assets.registry,id)
    if !found || !asset_document_opens(s,file.kind) {return false}
    for &d,index in s.asset_documents {
        if d.id==id {
            base.text_set(d.part[:],part)
            asset_document_request(s,index)
            return true
        }
    }
    if front:=asset_document_reusable(s,file.kind);front!=nil {
        front.id,front.path=id,{}
        base.text_set(front.part[:],part)
        asset_document_reused(s)
        return true
    }
    append(&s.asset_documents,Asset_Document{id=id,kind=file.kind})
    base.text_set(s.asset_documents[len(s.asset_documents)-1].part[:],part)
    asset_document_request(s,len(s.asset_documents)-1)
    return true
}

// An asset let go over an entity of the scene that the editor does nothing
// with itself, such as a clip of a library: the plugin of its kind takes it
// (asset_drop_take) in that frame or the next.
Asset_Drop :: struct {
    id:base.Asset_Id,
    kind:asset.Fourcc,
    part:[64]u8, // the clip of a library; empty: the whole asset
    entity:core.Entity,
    frame:u64,   // of the editor when it was let go; 0: none
}

asset_drop_take :: proc(s:^Session,kind:asset.Fourcc) -> (drop:Asset_Drop,ok:bool) {
    d:=&s.dropped
    if d.frame==0 || d.kind!=kind || s.frame>d.frame+1 {return}
    drop,ok=d^,true
    d^={}
    return
}

// The document in front when another asset of its kind may take its tab: it
// has nothing unsaved and no history.
@(private)
asset_document_reusable :: proc(s:^Session,kind:asset.Fourcc) -> ^Asset_Document {
    front:=asset_document_active(s)
    if front==nil || front.kind!=kind || asset_document_dirty(s,front) {return nil}
    if front.history.open || len(front.history.steps)>0 {return nil}
    return front
}

// The document in front took another asset: what shows it follows.
@(private)
asset_document_reused :: proc(s:^Session) {
    d:=asset_document_active(s)
    asset_history_free(&d.history)
    if s.gui!=nil {s.gui.documents_reveal=true}
    material_document_follow(s)
}

// The document of the source of a program alone, by its absolute path.
asset_document_open_program :: proc(s:^Session,path:string) -> bool {
    if path=="" || len(path)>=len(Asset_Document{}.path) {return false}
    for &d,index in s.asset_documents {
        if d.id=={} && base.text_get(d.path[:])==path {
            asset_document_request(s,index)
            return true
        }
    }
    if front:=asset_document_reusable(s,asset.KIND_MATERIAL);front!=nil {
        front.id={}
        base.text_set(front.path[:],path)
        asset_document_reused(s)
        return true
    }
    d:=Asset_Document{kind=asset.KIND_MATERIAL}
    base.text_set(d.path[:],path)
    append(&s.asset_documents,d)
    asset_document_request(s,len(s.asset_documents)-1)
    return true
}

// The asset of a file of the project, by its path under the project.
@(private)
asset_document_file :: proc(s:^Session,path:string) -> (file:^asset.Registry_File,found:bool) {
    a:=s.app.assets
    if a==nil {return}
    full:=project.path(s.project_root,path,allocator=context.temp_allocator)
    relative,ok:=asset.registry_relative(&a.registry,full)
    if !ok {relative=path}
    return asset.registry_find_path(&a.registry,relative)
}

// Whether a file of the project opens as a document: the .slang of a program,
// or an asset of a kind that opens one.
asset_document_file_opens :: proc(s:^Session,path:string) -> bool {
    if strings.has_suffix(path,".slang") {return true}
    file,found:=asset_document_file(s,path)
    return found && asset_document_opens(s,file.kind)
}

// Opens a file of the project as a document: an asset of a kind that opens
// one, or the .slang of a program alone. False when it opens none.
asset_document_open_file :: proc(s:^Session,path:string) -> bool {
    if strings.has_suffix(path,".slang") {
        full:=project.path(s.project_root,path,allocator=context.temp_allocator)
        data,read:=file_read(s,full)
        if !read || program_declared(string(data))=="" {return false}
        return asset_document_open_program(s,full)
    }
    if file,found:=asset_document_file(s,path);found {return asset_document_open(s,file.id)}
    return false
}

// Opens an asset in its document and brings it to the front now, between
// frames: for the API and for tests.
asset_document_show :: proc(s:^Session,id:base.Asset_Id) -> bool {
    if !asset_document_open(s,id) {return false}
    s.requests-={.Asset_Switch}
    asset_document_activate(s,s.asset_request)
    return true
}

@(private)
asset_document_request :: proc(s:^Session,index:int) {
    s.asset_request=index
    s.requests+={.Asset_Switch}
}

// Brings a document to the front, or the scene with -1. Between frames: what
// the user plays stops, the tools let go and the gestures end.
asset_document_activate :: proc(s:^Session,index:int) {
    shown:=index>=0 && index<len(s.asset_documents)?index+1:0
    if shown==s.asset_shown {return}
    if s.inspector!=nil && s.inspector.gesture!=0 {gesture_end(s,s.inspector.gesture)}
    if d:=asset_document_active(s);d!=nil {asset_history_end(&d.history)}
    if s.edits!=nil && s.edits.commit {history.edits_commit(s.edits,edited_world(s),s.selection)}
    if shown>0 {
        if s.mode==.Watch {watch_stop(s)}
        if playing(s) {play_stop(s)}
        if play_plugin_active(s) {play_plugin_stop(s)}
        tools_release(s)
    }
    s.asset_shown=shown
    if s.gui!=nil {
        s.gui.documents_reveal=true
        s.gui.drag,s.gui.placement={},{}
        if s.gui.ctx!=nil {s.gui.ctx.edit={};s.gui.ctx.scrub={}}
    }
    if s.inspector!=nil {s.inspector.picker,s.inspector.list={},{}}
    if s.materials!=nil {s.materials.color,s.materials.list={},{}}
    material_document_follow(s)
}

// Closes a document, asking first about its asset when it is unsaved and no
// open scene uses it: what a scene uses stays unsaved.
asset_document_close :: proc(s:^Session,index:int) {
    if index<0 || index>=len(s.asset_documents) {return}
    d:=&s.asset_documents[index]
    if asset_document_dirty(s,d) && !asset_document_used(s,d) {
        s.asset_request=index
        path:=[1]string{asset_document_path(s,d)}
        confirm_open(s,.Asset_Close,path[:])
        return
    }
    asset_document_close_now(s,index)
}

// Whether a document of a scene shows the unsaved asset of a document.
@(private)
asset_document_used :: proc(s:^Session,d:^Asset_Document) -> bool {
    path:=asset_document_path(s,d)
    used:=make([dynamic]string,context.temp_allocator)
    for index in 0..<max(len(s.documents),1) {
        world:=s.edit_world
        if index!=s.active_document {
            if index>=len(s.documents) || s.documents[index].world==nil {continue}
            world=s.documents[index].world
        }
        if world==nil {continue}
        world_unsaved_assets(s,{data=world,info=s.info},&used)
        for held in used {
            if held==path {return true}
        }
    }
    return false
}

// Closes a document without asking. The one before it comes to the front,
// or the scene after the last.
asset_document_close_now :: proc(s:^Session,index:int) {
    if index<0 || index>=len(s.asset_documents) {return}
    shown:=s.asset_shown
    if shown==index+1 {asset_document_activate(s,-1)}
    asset_history_free(&s.asset_documents[index].history)
    ordered_remove(&s.asset_documents,index)
    switch {
    case shown==index+1: if len(s.asset_documents)>0 {asset_document_activate(s,len(s.asset_documents)-1)}
    case shown>index+1:  s.asset_shown-=1
    }
    if len(s.asset_documents)==0 {
        delete(s.asset_documents)
        s.asset_documents=nil
    }
}

asset_documents_free :: proc(s:^Session) {
    for &d in s.asset_documents {asset_history_free(&d.history)}
    delete(s.asset_documents)
    s.asset_documents,s.asset_shown=nil,0
}

// Writes the unsaved asset of the document in front.
asset_document_save :: proc(s:^Session) {
    d:=asset_document_active(s)
    if d==nil {return}
    asset_history_end(&d.history)
    paths:=asset_document_paths(s,d)
    if len(paths)==0 {return}
    switch saved,ok:=assets_save(s,paths);{
    case !ok:     notify(s,fmt.tprintf("%s could not be saved; it stays unsaved",asset_document_title(s,d)))
    case saved>0: notify(s,fmt.tprintf("Saved %s",asset_document_title(s,d)))
    }
}

// Documents whose asset left the registry close: deleted or moved away.
@(private)
asset_documents_prune :: proc(s:^Session) {
    if s.app==nil || s.app.assets==nil {return}
    for i:=len(s.asset_documents)-1;i>=0;i-=1 {
        d:=&s.asset_documents[i]
        if d.id=={} {continue}
        if _,found:=asset.registry_find(&s.app.assets.registry,d.id);!found {asset_document_close_now(s,i)}
    }
}

// ---------------------------------------------------------------- where it is drawn

// The part of the window a document takes: from a little under the left
// panel, as the scene, so its rounded corners show the document, to the edge
// and the bottom of the window, under the bars. The panels float over it.
asset_workspace_rect :: proc(g:^Editor_Ui) -> ui.Rect {
    ctx:=g.ctx
    x0:f32
    if r:=g.rects.left;r.w>0 && r.h>0 {x0=r.x+r.w-asset_workspace_under(g)}
    y0:=ui.metric(ctx,"bar_height")+toolbar_height(g)
    return {x0,y0,max(ctx.size.x-x0,120),max(ctx.size.y-y0,120)}
}

// What of the left of a document the left panel covers: a canvas runs under
// it, and what must be read starts past it.
asset_workspace_under :: proc(g:^Editor_Ui) -> f32 {return g.rects.left.w>RAIL_WIDTH?LEFT_UNDER:0}

// What of the bottom of a document the bottom panel covers.
@(private)
asset_workspace_bottom :: proc(g:^Editor_Ui) -> f32 {
    if r:=g.rects.bottom;r.w>0 && r.h>0 {return max(g.ctx.size.y-r.y,0)}
    return 0
}

// The panel of the document in front, for ui.panel, laid out as a column,
// its content where no panel covers it.
asset_workspace :: proc(g:^Editor_Ui) -> ui.Panel_Float {
    r:=asset_workspace_rect(g)
    return {width=ui.fixed(r.w),height=ui.fixed(r.h),padding={asset_workspace_under(g),0,0,asset_workspace_bottom(g)},anchor=.Top_Left,pivot=.Top_Left,offset={r.x,r.y},docked=true,backdrop=true}
}

// A document with Details at its right, as a scene shows its entity: Details
// floats over the panel of the document as high as its content up to
// max_height or, docked, takes its edge and the document what is left. The
// panel runs under the left panel: its canvas does, and what is read in it
// starts after asset_workspace_under.
asset_workspace_details :: proc(s:^Session) -> (document,details:ui.Panel_Float,max_height:f32) {
    g:=s.gui
    ctx:=g.ctx
    r:=asset_workspace_rect(g)
    bottom:=asset_workspace_bottom(g)
    room:=max(r.h-bottom,120)
    document={width=ui.fixed(r.w),height=ui.fixed(r.h),padding={0,0,0,bottom},anchor=.Top_Left,pivot=.Top_Left,offset={r.x,r.y},docked=true,backdrop=true}
    if panel_mode(&g.layout,.Asset)==.Docked && ctx.size.x>=760 {
        width:=dock_right_width(s)
        document.width=ui.fixed(max(r.w-width,120))
        details={width=ui.fixed(width),height=ui.fixed(room),anchor=.Top_Right,pivot=.Top_Right,offset={0,r.y},docked=true}
        dock_edge(s,width,r.y,room)
        return document,details,room
    }
    radius:=ui.metric(ctx,"radius_panel")
    details={width=ui.fixed(width_of(RIGHT_WIDTH,ctx.size.x)),height=ui.FIT,anchor=.Top_Right,pivot=.Top_Right,offset={-DETAILS_MARGIN,r.y+DETAILS_MARGIN},docked=true,corners={radius,radius,radius,radius}}
    return document,details,max(room-2*DETAILS_MARGIN,120)
}

// The room the toolbar leaves to the document in front, after save, undo
// and redo, as the last frame laid it out: a plugin builds what plays there
// in a box that floats over it.
asset_toolbar :: proc(g:^Editor_Ui) -> (rect:ui.Rect,ok:bool) {
    return ui.widget_rect(g.ctx,shell_id(g,"asset_toolbar"))
}

// The whole toolbar under the tabs, as the last frame laid it out: a plugin
// centers in it what chooses how its document shows the asset.
asset_toolbar_whole :: proc(g:^Editor_Ui) -> (rect:ui.Rect,ok:bool) {
    return ui.widget_rect(g.ctx,shell_id(g,"document_toolbar"))
}

ASSET_HEADING :: f32(33)

// The row of the heading of a part of a document:
// the caller fills it, and asset_heading_end draws the line under it.
asset_heading_box :: proc(ctx:^ui.Context,id:ui.Id=0) -> ui.Box {
    return {id=id,width=ui.GROW,height=ui.fixed(ASSET_HEADING-1),padding={12,0,12,0},gap=8,align_y=.Center,fill=ui.tone(ctx,"card")}
}
asset_heading_end :: proc(ctx:^ui.Context) {
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=ui.tone(ctx,"border")}) {}
}

// A heading with its title and, at the right, a note.
asset_heading :: proc(ctx:^ui.Context,title:string,note:="") {
    if ui.box(ctx,asset_heading_box(ctx)) {
        ui.label(ctx,title,ui.metric(ctx,"font"),ui.tone(ctx,"text"),font=ui.FONT_MEDIUM)
        ui.spacer(ctx)
        if note!="" {ui.label(ctx,note,ui.metric(ctx,"font_label"),ui.tone(ctx,"text_muted"))}
    }
    asset_heading_end(ctx)
}

// What the editor keeps loaded besides what its Worlds name (host.app_assets_mark):
// the assets and scenes open as documents.
@(private)
asset_documents_retain :: proc(s:^Session) {
    a:=s.app.assets
    if a==nil {return}
    ids:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for d in s.asset_documents {if d.id!={} {append(&ids,d.id)}}
    for &tab in s.documents {if tab.document.id!={} {append(&ids,tab.document.id)}}
    scope:=host.assets_scope_of(a,s)
    if !slice.equal(host.assets_scope_ids(a,scope),ids[:]) {host.assets_scope_set(a,scope,ids[:])}
}
