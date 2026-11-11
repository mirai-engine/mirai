package editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"

// The scene being edited: the file the World was opened from or saved to,
// the document it was read as (what the World cannot hold: the order of its
// roots, tables of libraries the project does not have) and
// the state of the history it was saved at. Opening and creating replace the
// World and start a new history.

SCENE_EXTENSION :: ".scene"
DOCUMENT_PATH_BYTES :: 1024
@(private) DIALOG_OPEN :: u32(0x4d4f5045)
@(private) DIALOG_SAVE :: u32(0x4d534156)

Document_Error :: enum u8 {
    None,
    No_Assets,   // the application has no assets folder
    Not_Found,
    Not_A_Scene, // unreadable, or not a scene
    Rejected,    // the World could not take it
    Write_Failed,
    Out_Of_Memory, // the World could not be copied out to be written
    Capture_Failed,
    Bad_Path,    // rooted without a drive on Windows: it names no folder
    Importing,   // an import writes assets now
    Not_One_Root, // a prefab with no root or several
}

@(storage)
Document :: struct {
    path:[DOCUMENT_PATH_BYTES]u8, // as given: relative to the assets folder when inside it; empty for a scene never saved
    path_length:int,
    file:[DOCUMENT_PATH_BYTES]u8, // absolute
    file_length:int,
    id:base.Asset_Id,
    previous:^asset.Scene,        // the document of the file; nil for a new scene
    saved:u64,                    // the state of the history when it was saved or opened
    unsaved:bool,                 // changes from before a restart, or a section Save could not write
    prefab:bool,                  // its kind: a prefab, shown in the studio light and placed by its one root; chosen when it is made, changed by scene.write kind
    source_stamp:[2]i64,
    sections:Document_Sections,
}

Document_Kind :: enum u8 {Scene,Prefab}

document_path :: proc(d:^Document) -> string {return string(d.path[:d.path_length])}
document_file :: proc(d:^Document) -> string {return string(d.file[:d.file_length])}

// The folder of the file of the open scene, absolute: a new asset of the scene
// goes beside it, so assets stay together by what they belong to. otherwise
// while the scene has no file.
scene_folder :: proc(s:^Session,otherwise:string) -> string {
    if s.document!=nil {
        file:=document_file(s.document)
        if at:=strings.last_index_byte(file,'/');at>0 {return file[:at]}
    }
    return otherwise
}

document_dirty :: proc(s:^Session) -> bool {return s.document.unsaved || history.edits_scene_state(s.edits)!=s.document.saved}

// The name a person reads for the scene.
document_title :: proc(d:^Document) -> string {
    path:=document_path(d)
    if path=="" {return "Untitled"}
    name:=filepath.base(path)
    if strings.has_suffix(name,SCENE_EXTENSION) {name=name[:len(name)-len(SCENE_EXTENSION)]}
    return name
}

document_error_text :: proc(error:Document_Error) -> string {
    switch error {
    case .None:         return ""
    case .No_Assets:    return "the project has no assets folder"
    case .Not_Found:    return "no such file"
    case .Not_A_Scene:  return "not a scene"
    case .Rejected:     return "the world could not take it"
    case .Write_Failed: return "the file could not be written"
    case .Out_Of_Memory: return "there is not enough memory to copy the scene out of the World; the file was not changed"
    case .Capture_Failed: return "the scene could not be copied out of the World: engine.diagnostics says why; the file was not changed"
    case .Bad_Path:     return "the path has a root and no drive, so it names no folder; write it with its drive, as C:/..."
    case .Importing:    return "an import writes assets now; save when it ends (asset.import_status)"
    case .Not_One_Root: return "a prefab has exactly one root: put its entities under one (Group), or make it a scene (File > Make scene)"
    }
    return ""
}

// The file a path names: itself when it is absolute or exists, otherwise
// inside the assets folder. Absolute, with forward slashes; "" for a path that
// names no folder (project.path_native).
scene_file :: proc(s:^Session,path:string,allocator:=context.temp_allocator) -> string {
    path,native:=project.path_native(path)
    if !native {return ""}
    if filepath.is_abs(path) || os.exists(path) {return project.path_absolute(path,allocator)}
    return project.path_absolute(project.path(s.assets_root,path,allocator=context.temp_allocator),allocator)
}

// A file as the document names it: relative to the assets folder when it is inside.
scene_path :: proc(s:^Session,file:string) -> string {
    root:=s.assets_root
    if len(file)>len(root) && file[len(root)]=='/' && project.path_same(file[:len(root)],root) {return file[len(root)+1:]}
    return file
}

// Replaces the edited World with a scene, by file or by a path
// inside the assets folder. A Play is stopped first. On failure the World
// stays as it was only when the file could not be read.
scene_open :: proc(s:^Session,path:string) -> Document_Error {
    a:=s.app.assets
    if a==nil {return .No_Assets}
    file:=scene_file(s,path)
    if file=="" {return .Bad_Path}
    host.load_open(s.app,.Scene,scene_path(s,file))
    stopping:=host.load_phase_begin(s.app,.Editor)
    runs_stop(s)
    host.load_phase_end(s.app,stopping)
    loaded,error:=scene_load_file(s,file)
    if error!=.None {
        if loaded!=nil {asset.scene_destroy(loaded);free(loaded)}
        host.load_fail(s.app,.Scene,document_error_text(error))
        return error
    }
    opening:=host.load_phase_begin(s.app,.Editor)
    defer host.load_ready(s.app,.Scene,core.world_entities(edited_world(s)).alive)
    defer host.load_phase_end(s.app,opening)
    d:=s.document
    if document_file(d)!=file {ai_document_closed(s,s.edit_world)}
    document_previous_free(d)
    d.previous=loaded
    d.id=loaded.doc.id
    d.prefab=.Prefab in loaded.doc.flags
    document_name(d,scene_path(s,file),file)
    document_opened(s)
    if !document_is_prefab(s) {thumbnail_scene_opened(s,d.id)}
    log.infof("opened %s",file)
    return .None
}

// A document never saved: a scene with a sky and a sun, or a prefab with its one root.
scene_new :: proc(s:^Session,prefab:=false) {
    runs_stop(s)
    tools_release(s)
    w:=edited_world(s)
    if !core.world_clear(w.info,w.data) {
        notify(s,"There is not enough memory for a new scene; this one stays open")
        return
    }
    ai_document_closed(s,s.edit_world)
    if prefab {
        entity_make(s,w,{preset=.Empty,name="Prefab",named=true})
    } else {
        sky:=entity_make(s,w,{preset=.Empty,name="Sky",named=true})
        if t:=core.world_table_of(w,erender.Sky);t!=nil && sky!=core.NONE {core.add(t,sky,erender.SKY_DEFAULT)}
        entity_make(s,w,{preset=.Sun,name="Sun",named=true})
    }
    core.world_settle(w)
    document_reset(s)
    s.document.prefab=prefab
    document_opened(s)
}

// Saves the scene: to its file, or to path when given (a new file is
// another asset, with an id of its own). Without either it asks for a file.
scene_save :: proc(s:^Session,path:="") -> Document_Error {
    if import_busy(s)!="" {return .Importing}
    tool_preview_cancel(s)
    d:=s.document
    target:=path
    if target=="" {target=document_path(d)}
    if target=="" {
        dialog_save(s)
        return .None
    }
    file:=scene_file(s,target)
    if file=="" {return .Bad_Path}
    if !strings.has_suffix(file,SCENE_EXTENSION) {file=strings.concatenate({file,SCENE_EXTENSION},context.temp_allocator)}
    if !history.edits_commit(s.edits,edited_world(s),document_selection(s)) && s.edits.error!=.No_Change {return .Rejected}
    if file!=document_file(d) || d.id=={} {d.id=asset_id_new(s)}
    if error:=document_write(s,file,true);error!=.None {return error}
    // What memory held of the file, unsaved (a prefab an operation made), is of before this save.
    if r:=files_registry(s);r!=nil {
        if relative,inside:=asset.registry_relative(r,file);inside {_,_=asset.registry_memory_drop(r,relative)}
    }
    // A section that could not be written keeps the document unsaved.
    if !sections_save(s) {d.unsaved=true}
    owned:=make([dynamic]string,context.temp_allocator)
    world_owned_unsaved(s,edited_world(s),&owned)
    if _,saved:=assets_save(s,owned[:]);!saved {notify(s,"Assets the scene makes could not be saved; they stay unsaved")}
    document_name(d,scene_path(s,file),file)
    assets_wrote(s,file)
    document_source_stamp(s)
    if !d.unsaved {notify(s,fmt.tprintf("Saved %s",document_title(d)))}
    return .None
}

// The edited World as a scene, with the overrides of its prefab instances
// as a file keeps them.
@(private)
document_capture :: proc(s:^Session,captured:^asset.Scene,id:base.Asset_Id,recovery:^Recovery_Info=nil,allocator:=context.allocator) -> Document_Error {
    tool_preview_cancel(s)
    a:=s.app.assets
    if a==nil {return .No_Assets}
    if _,error:=scene.capture(edited_world(s),captured,&a.types,{previous=s.document.previous,id=id},allocator);error!=.None {
        log.errorf("the scene could not be captured: %s",scene.error_text(error))
        return error==.Out_Of_Memory?.Out_Of_Memory:.Capture_Failed
    }
    captured.doc.flags-={.Prefab}
    if s.document.prefab {captured.doc.flags+={.Prefab}}
    kept:[]asset.Override
    if previous:=s.document.previous;previous!=nil {kept=previous.overrides[:]}
    if error:=prefab_overrides_put(s,captured,kept);error!=.None {
        log.errorf("the overrides of the prefab instances could not be derived: %s",prefab_error_text(error))
        asset.scene_destroy(captured)
        return error==.Out_Of_Memory?.Out_Of_Memory:.Capture_Failed
    }
    if recovery!=nil {
        if _,error:=asset.document_put_row(&captured.doc,&a.types,RECOVERY_TABLE,recovery);error!=.None {asset.scene_destroy(captured);return .Capture_Failed}
    }
    return .None
}

// Writes the edited World to a file. As the document, it becomes the file
// the scene is saved in; otherwise it is a copy (the recovery, the restart).
document_write :: proc(s:^Session,file:string,as_document:bool) -> Document_Error {
    tool_preview_cancel(s)
    a:=s.app.assets
    if a==nil {return .No_Assets}
    d:=s.document
    folder:=filepath.dir(file)
    if !os.is_dir(folder) {_=os.make_directory_all(folder)}
    id:=d.id
    if id=={} {id=asset_id_new(s)}
    captured:asset.Scene
    document_capture(s,&captured,id) or_return
    defer asset.scene_destroy(&captured)
    if as_document && d.prefab && asset.prefab_refused(&captured)!="" {return .Not_One_Root}
    if asset.scene_save(&captured,file)!=.None {return .Write_Failed}
    if !as_document {return .None}
    // What was written is what the next save carries from.
    if saved:=new(asset.Scene);asset.scene_load(saved,&a.types,file)==.None {
        document_previous_free(d)
        d.previous=saved
    } else {
        free(saved)
    }
    d.id=id
    d.saved=history.edits_scene_state(s.edits)
    d.unsaved=false
    return .None
}

// The scene a restart left: the World as it was, with the path and the
// unsaved changes of the document that was open.
document_restore :: proc(s:^Session,file,path:string,unsaved:bool) -> Document_Error {
    loaded,error:=scene_load_file(s,project.path_absolute(file,context.temp_allocator))
    if error!=.None {
        if loaded!=nil {asset.scene_destroy(loaded);free(loaded)}
        return error
    }
    d:=s.document
    document_previous_free(d)
    d.previous=loaded
    d.id=loaded.doc.id
    d.prefab=.Prefab in loaded.doc.flags
    if path!="" {document_name(d,path,scene_file(s,path))} else {document_name(d,"","")}
    document_opened(s)
    d.unsaved=unsaved
    return .None
}

document_previous_free :: proc(d:^Document) {
    if d.previous==nil {return}
    asset.scene_destroy(d.previous)
    free(d.previous)
    d.previous=nil
}

// Forgets the file: the document of a scene never saved.
document_reset :: proc(s:^Session) {
    d:=s.document
    document_previous_free(d)
    d.id={}
    d.unsaved=false
    d.prefab=false
    d.saved=history.edits_scene_state(s.edits)
    document_name(d,"","")
}

// ---------------------------------------------------------------- what asks first

// What waits for the answer about unsaved changes. The question also lists
// unsaved assets (Editor_Ui.confirm_assets): Save writes them and Discard
// gives them back what their files hold, except before the game of a plugin
// (Play_Provider), which goes on without them. Closing an asset document
// asks about its asset alone.
Pending :: enum u8 {None,New,Close,Quit,Play_Plugin,Asset_Close,Open_Scene}

// Whether the question comes before the game of a plugin, whose players read the saved files.
@(private)
pending_plugin :: proc(pending:Pending) -> bool {return pending==.Play_Plugin}

Choice :: enum u8 {Save,Discard,Cancel}

file_new :: proc(s:^Session,prefab:=false) {
    tool_preview_cancel(s)
    s.new_prefab=prefab
    assets:=document_closing_assets(s)
    if document_dirty(s) || len(assets)>0 || scene_switch_interrupts(s) {confirm_open(s,.New,assets);return}
    s.requests+={.New}
}

// Saves the scene. When it uses unsaved assets it first asks whether to save
// them with it (Modal.Save_Changes); those it owns are saved with it.
save_request :: proc(s:^Session) {
    tool_preview_cancel(s)
    used:=make([dynamic]string,context.temp_allocator)
    owned:=make([dynamic]string,context.temp_allocator)
    world_unsaved_assets(s,edited_world(s),&used)
    world_owned_unsaved(s,edited_world(s),&owned)
    #reverse for path,i in used {
        if slice.contains(owned[:],path) {ordered_remove(&used,i)}
    }
    if len(used)>0 {
        confirm_assets_set(s.gui,used[:])
        s.gui.modal=.Save_Changes
        return
    }
    if error:=scene_save(s);error!=.None {notify(s,fmt.tprintf("The scene could not be saved: %s",document_error_text(error)))}
}

// The answer to Save_Changes: the scene with its unsaved assets, or alone.
save_changes_resolve :: proc(s:^Session,with_assets:bool) {
    g:=s.gui
    g.modal=.None
    if with_assets {
        if _,ok:=assets_save(s,g.confirm_assets[:]);!ok {notify(s,"Some assets could not be saved; they stay unsaved")}
    }
    confirm_assets_set(g,nil)
    if error:=scene_save(s);error!=.None {notify(s,fmt.tprintf("The scene could not be saved: %s",document_error_text(error)))}
}

// Saves the unsaved assets and every document with changes that has a file.
save_all :: proc(s:^Session) {
    tool_preview_cancel(s)
    saved,ok:=assets_save_all(s)
    if !ok {notify(s,"Some assets could not be saved; they stay unsaved")}
    documents_ensure(s)
    active:=s.active_document
    untitled:=0
    for index in 0..<len(s.documents) {
        tab:=&s.documents[index]
        d:=index==active?s.document:&tab.document
        e:=index==active?s.edits:&tab.edits
        if !d.unsaved && history.edits_scene_state(e)==d.saved {continue}
        if document_path(d)=="" {untitled+=1;continue}
        document_activate(s,index)
        if scene_save(s)!=.None {notify(s,"A scene could not be saved")}
        saved+=1
    }
    document_activate(s,active)
    if untitled>0 {notify(s,untitled==1?"An untitled scene was not saved: Save as gives it a file":fmt.tprintf("%d untitled scenes were not saved: Save as gives them a file",untitled))} else if ok {notify(s,fmt.tprintf("Saved %d %s",saved,saved==1?"file":"files"))}
}

file_open :: proc(s:^Session) {
    tool_preview_cancel(s)
    dialog_open(s)
}

// Opens a file in its own document tab at the end of the frame.
file_open_path :: proc(s:^Session,path:string) {
    tool_preview_cancel(s)
    s.open_length=copy(s.open_path[:],path)
    s.requests+={.Open}
}

confirm_open :: proc(s:^Session,pending:Pending,assets:[]string=nil) {
    g:=s.gui
    confirm_assets_set(g,assets)
    g.pending=pending
    g.modal=.Confirm
}

// The unsaved assets a question lists, as copies it owns.
confirm_assets_set :: proc(g:^Editor_Ui,assets:[]string) {
    for path in g.confirm_assets {delete(path)}
    clear(&g.confirm_assets)
    for path in assets {append(&g.confirm_assets,strings.clone(path))}
}

// Closes the dialog open, unanswered, with what it asked about.
modal_close :: proc(g:^Editor_Ui) {
    g.modal=.None
    confirm_assets_set(g,nil)
    g.delete_asset={}
    g.discard_path={}
}

// The answer to the question about unsaved changes.
confirm_resolve :: proc(s:^Session,choice:Choice) {
    g:=s.gui
    g.modal=.None
    pending:=g.pending
    if choice==.Cancel {
        if pending==.Quit {projects_next_cancel(s)}
        g.pending=.None
        confirm_assets_set(g,nil)
        return
    }
    // The agents still working stop first: what they did is saved or discarded
    // with the rest. They work on the scene, which closing an asset keeps.
    if !pending_plugin(pending) && pending!=.Asset_Close {ai_working_stop(s)}
    if choice==.Save {
        if _,ok:=assets_save(s,g.confirm_assets[:]);!ok {
            notify(s,"Some assets could not be saved; they stay unsaved")
            g.pending=.None
            confirm_assets_set(g,nil)
            return
        }
    } else if !pending_plugin(pending) {
        assets_discard(s,g.confirm_assets[:])
    }
    confirm_assets_set(g,nil)
    if choice==.Save && !pending_plugin(pending) && pending!=.Asset_Close && document_dirty(s) {
        if document_path(s.document)=="" {
            g.save_then=true
            dialog_save(s)
            return
        }
        if scene_save(s)!=.None {
            notify(s,"The scene could not be saved")
            g.pending=.None
            return
        }
    }
    pending_continue(s,pending)
}

@(private)
pending_continue :: proc(s:^Session,pending:Pending) {
    s.gui.pending=.None
    switch pending {
    case .None:
    case .New:         s.requests+={.New}
    case .Close:       s.requests+={.Document_Discard}
    case .Quit:
        documents_ensure(s)
        s.documents[s.active_document].quit_approved=true
        s.requests+={.Quit_Check}
    case .Play_Plugin:
        if p:=providers(s);p.plays && p.play.confirmed!=nil {p.play.confirmed(s)}
    case .Asset_Close: s.requests+={.Asset_Discard}
    case .Open_Scene:
        s.open_confirmed=true
        s.requests+={.Open}
    }
}

@(private)
dialog_open :: proc(s:^Session) {
    filters:=[1]platform.Dialog_Filter{{"Scene","scene"}}
    if !platform.dialog_show(s.app.platform,{kind=.Open_File,tag=DIALOG_OPEN,filters=filters[:],location=s.assets_root}) {notify(s,"A file dialog is already open")}
}

@(private)
dialog_save :: proc(s:^Session) {
    tool_preview_cancel(s)
    filters:=[1]platform.Dialog_Filter{{"Scene","scene"}}
    location:=document_file(s.document)
    if location=="" {location=s.assets_root}
    if !platform.dialog_show(s.app.platform,{kind=.Save_File,tag=DIALOG_SAVE,filters=filters[:],location=location}) {notify(s,"A file dialog is already open")}
}

// Answers of the file dialogs the editor opened.
@(private)
dialogs_answer :: proc(s:^Session) {
    result:=platform.dialog_result(s.app.platform)
    if result.state==.None || result.tag!=DIALOG_OPEN && result.tag!=DIALOG_SAVE {return}
    g:=s.gui
    switch result.state {
    case .None:
    case .Accepted:
        if result.tag==DIALOG_OPEN {
            s.open_length=copy(s.open_path[:],result.path)
            s.requests+={.Open}
            return
        }
        if scene_save(s,result.path)!=.None {
            notify(s,"The scene could not be saved")
            g.save_then,g.pending=false,.None
            return
        }
        if g.save_then {
            g.save_then=false
            pending_continue(s,g.pending)
        }
    case .Cancelled:
        if result.tag==DIALOG_SAVE {g.save_then,g.pending=false,.None}
    case .Failed:
        g.save_then,g.pending=false,.None
        notify(s,"The system file dialog is not available")
    }
}

// ---------------------------------------------------------------- inside

@(private)
scene_load_file :: proc(s:^Session,file:string) -> (loaded:^asset.Scene,error:Document_Error) {
    a:=s.app.assets
    if a==nil {return nil,.No_Assets}
    reading:=host.load_phase_begin(s.app,.Read)
    read:=false
    defer if !read {host.load_phase_end(s.app,reading,1)}
    // A file of the assets as the registry holds it, unsaved, else the disk.
    source:asset.Asset
    opened:asset.Error
    if relative,inside:=asset.registry_relative(&a.registry,file);inside {
        data,read_error:=asset.registry_read(&a.registry,relative)
        opened=read_error==.None?asset.asset_take(&source,data):read_error
    } else {
        opened=asset.asset_load(&source,file)
    }
    #partial switch opened {
    case .None:
    case .Not_Found: return nil,.Not_Found
    case:            return nil,.Not_A_Scene
    }
    defer asset.asset_close(&source)
    kind:=source.blob.header.kind
    if kind!=asset.KIND_SCENE {return nil,.Not_A_Scene}
    loaded=new(asset.Scene)
    if asset.scene_from_asset(loaded,&a.types,&source)!=.None {
        free(loaded)
        return nil,.Not_A_Scene
    }
    // Its instances follow their prefabs before the World takes them: no step holds that, and the
    // document is as its file until it is saved.
    resolved:asset.Asset
    defer asset.asset_close(&resolved)
    document:=&source
    {
        reader:Prefab_Reader
        prefab_reader_begin(s,&reader)
        defer prefab_reader_end(&reader)
        if changed,_:=asset.scene_resolve(&reader.resolver,loaded);changed {
            data,encoded:=asset.scene_bytes(loaded)
            if encoded!=.None || asset.asset_take(&resolved,data)!=.None {
                asset.scene_destroy(loaded)
                free(loaded)
                return nil,.Not_A_Scene
            }
            document=&resolved
        }
    }
    host.load_phase_end(s.app,reading,1)
    read=true
    tools_release(s)
    w:=edited_world(s)
    stored:=make([dynamic]scene.Stored,context.temp_allocator)
    if _,replaced:=scene.replace(w,s.app,document,&a.types,stored=&stored);replaced!=.None {
        log.errorf("%s: %s",file,scene.error_text(replaced))
        return loaded,.Rejected
    }
    stored_log(s,stored[:])
    settling:=host.load_phase_begin(s.app,.Settle)
    core.problems_clear(host.app_world_storage(s.app,w.data,core.Problems))
    core.world_settle(w)
    host.load_phase_end(s.app,settling)
    return loaded,.None
}

// Says in the console what the scenes of a load store otherwise than the
// world reads them: a warning when a save loses values or nothing reads them.
stored_log :: proc(s:^Session,stored:[]scene.Stored) {
    for entry in stored {
        name:="a scene"
        if file,found:=asset.registry_find(&s.app.assets.registry,entry.scene);found {name=file.path}
        text,warning:=scene.stored_text(entry,name)
        if warning {log.warn(text)} else {log.info(text)}
    }
}

// After the World was replaced: a history of its own, nothing selected.
@(private)
document_opened :: proc(s:^Session) {
    w:=edited_world(s)
    history.edits_reset(s.edits,w)
    prefabs_opened(s)
    s.document.saved=history.edits_scene_state(s.edits)
    s.document.unsaved=false
    s.document.sections={}
    if views:=core.world_storage_of(w,scene.Section_Views);views!=nil {clear(&views.items)}
    if u:=core.world_storage_of(w,scene.Unresolved_References);u!=nil {s.edits.resolved=u.written}
    history.selection_clear(s.selection)
    outliner_reset(s.outliner)
    s.viewport.exposure={}
    if s.viewport.exposure_source==.Camera {s.viewport.exposure_source=.Scene}
    s.view_cut=true
    // Opened with another world on screen, what was kept of this one's light is not of this scene.
    erender.world_light_forget(s.app.renderer,host.app_world_id(s.app,w.data))
    document_source_stamp(s)
    // What Play will play compresses meanwhile.
    play_animations_load(s,wait=false)
    ai_reviews_reconcile(s,s.ai)
    // A scene a merge waits for shows the choices made.
    if s.git!=nil && s.git.merge.loaded {git_merge_preview(s)}
}

document_source_stamp :: proc(s:^Session) {
    d:=s.document
    d.source_stamp={}
    if s.app.assets!=nil {
        if file,found:=asset.registry_find(&s.app.assets.registry,d.id);found {d.source_stamp={file.size,file.time}}
    }
}

@(private)
document_name :: proc(d:^Document,path,file:string) {
    d.path_length=copy(d.path[:],path)
    d.file_length=copy(d.file[:],file)
}

// A new id for an asset made in the editor.
asset_id_new :: proc(s:^Session) -> base.Asset_Id {
    s.id_state~=platform.clock_ns()
    return {base.splitmix_next(&s.id_state),base.splitmix_next(&s.id_state)}
}
