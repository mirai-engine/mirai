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

// The scene being edited: its file, the document it was read as (what the
// World cannot hold: the order of its roots, tables of libraries the project
// does not have) and the state of the history its file holds. The file is
// written when a step ends (document_flush): it is what the editor has.
// Opening and creating replace the World and start a new history.

SCENE_EXTENSION :: ".scene"
DOCUMENT_PATH_BYTES :: 1024
@(private) DIALOG_OPEN :: u32(0x4d4f5045)

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
    path:[DOCUMENT_PATH_BYTES]u8, // as given: relative to the assets folder when inside it; empty until its first step gives it a file
    path_length:int,
    file:[DOCUMENT_PATH_BYTES]u8, // absolute
    file_length:int,
    id:base.Asset_Id,
    previous:^asset.Scene,        // the document of the file; nil for a new scene
    written:u64,                  // the state of the history its file holds
    stale:bool,                   // the World holds what no step does and the file lacks: of a peer, a merge, a section that could not be written
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
    case .Importing:    return "an import writes assets now; the file is written when it ends (asset.import_status)"
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

// A document without a file yet: a scene with a sky and a sun, or a prefab with its one root.
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
        entity_make(s,w,{name="Prefab",named=true})
    } else {
        sky:=entity_make(s,w,{name="Sky",named=true})
        if t:=core.world_table_of(w,erender.Sky);t!=nil && sky!=core.NONE {core.add(t,sky,erender.SKY_DEFAULT)}
        entity_make(s,w,{recipe="sun",name="Sun",named=true})
    }
    core.world_settle(w)
    document_reset(s)
    s.document.prefab=prefab
    document_opened(s)
}

// The end of a step for the document in front: its file takes the World
// when the history is not where the file left it. A document without a file
// gets one at its first step, in the assets folder. .None when the file holds
// the document.
@(private)
document_flush :: proc(s:^Session) -> Document_Error {
    d:=s.document
    if s.app.assets==nil || s.edits.world!=s.edit_world || !d.stale && history.edits_scene_state(s.edits)==d.written {return .None}
    if import_busy(s)!="" {return .Importing}
    file:=document_file(d)
    if file=="" {
        if !s.has_project {return .None}
        _,file=asset_new_file(s,s.assets_root,d.prefab?"Prefab":"Untitled",SCENE_EXTENSION,false)
        d.id=asset_id_new(s)
    }
    document_write(s,file,true) or_return
    // A section that could not be written is tried again with the next flush.
    d.stale=!sections_save(s)
    document_name(d,scene_path(s,file),file)
    assets_wrote(s,file)
    document_source_stamp(s)
    return .Write_Failed if d.stale else .None
}

// The edited World as a scene, with the overrides of its prefab instances
// as a file keeps them.
@(private)
document_capture :: proc(s:^Session,captured:^asset.Scene,id:base.Asset_Id,allocator:=context.allocator) -> Document_Error {
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
    return .None
}

// Writes the edited World to a file. As the document, it becomes the file
// of the scene; otherwise it is a copy (what the players of a game read).
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
    // What was written is what the next write carries from.
    if saved:=new(asset.Scene);asset.scene_load(saved,&a.types,file)==.None {
        document_previous_free(d)
        d.previous=saved
    } else {
        free(saved)
    }
    d.id=id
    d.written=history.edits_scene_state(s.edits)
    d.stale=false
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
    d.stale=false
    d.prefab=false
    d.written=history.edits_scene_state(s.edits)
    document_name(d,"","")
}

// ---------------------------------------------------------------- what asks first

// What waits for the answer of a question: changing the scene while others
// lose what they do in it (a shared session, agents at work), or quitting
// while agents work.
Pending :: enum u8 {None,New,Quit,Open_Scene}

file_new :: proc(s:^Session,prefab:=false) {
    tool_preview_cancel(s)
    s.new_prefab=prefab
    if scene_switch_interrupts(s) {confirm_open(s,.New);return}
    s.requests+={.New}
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

confirm_open :: proc(s:^Session,pending:Pending) {
    s.gui.pending=pending
    s.gui.modal=.Confirm
}

// Closes the dialog open, unanswered, with what it asked about.
modal_close :: proc(g:^Editor_Ui) {
    g.modal=.None
    g.delete_asset={}
    g.discard_path={}
}

// The answer to a question: the agents still working stop and what waited goes on.
confirm_resolve :: proc(s:^Session,go_on:bool) {
    g:=s.gui
    g.modal=.None
    pending:=g.pending
    g.pending=.None
    if !go_on {
        if pending==.Quit {projects_next_cancel(s)}
        return
    }
    ai_working_stop(s)
    switch pending {
    case .None:
    case .New:  s.requests+={.New}
    case .Quit: documents_quit(s,true)
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

// The answer of the file dialog the editor opened.
@(private)
dialogs_answer :: proc(s:^Session) {
    result:=platform.dialog_result(s.app.platform)
    if result.tag!=DIALOG_OPEN {return}
    switch result.state {
    case .None,.Cancelled:
    case .Accepted:
        s.open_length=copy(s.open_path[:],result.path)
        s.requests+={.Open}
    case .Failed:
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
    // A file of the assets as the registry holds it: what an open gesture wrote, else the disk.
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
            if moved:=reader.resolver.reparented;moved>0 {log.warnf("%s: %d entities it added under members its prefabs removed hang from the nearest member left now",file,moved)}
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
    s.document.written=history.edits_scene_state(s.edits)
    s.document.stale=false
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
