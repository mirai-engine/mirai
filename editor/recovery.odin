package editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"

@(private) RECOVERY_TABLE :: "editor_recovery"
@(private) RECOVERY_DELAY :: u64(1_000_000_000)
@(private) RECOVERY_TABS :: "recovery-tabs"

Recovery_Info :: struct {
    source:[DOCUMENT_PATH_BYTES]u8 `mirai:"text"`,
    log:u64, // the generation of the recovery log that follows the copy (recovery_log.odin); 0: none
}

// The recovery of a document: its log (recovery_log.odin) and its copy of
// recovery, the periodic copy (the autosave) that bounds how much of the log
// a start puts back: every RECOVERY_COPY_INTERVAL after a change it lacks, or
// every second while the log cannot be written. Each document has its chain,
// under a slot of its own; that of the document in front is in Recovery, and
// the others stay with their tabs as they were left, every step on the disk
// (recovery_park).
Recovery_Chain :: struct {
    slot:int,   // of its files (recovery_file, recovery_log_path); 0: none yet
    owned:bool, // its copy is written
    saved,deadline:u64,
    write:Recovery_Write,
    log:Recovery_Log,
}

// What a start finds of a document with changes an editor did not end.
Recovery_Found :: struct {
    slot:int,
    scene:bool, // a copy of the document is there
    info:Recovery_Info,
    records:int, // the steps of the log put back after the copy or the saved file
    source:[DOCUMENT_PATH_BYTES]u8, // without a copy: the saved file the log follows
}

Recovery :: struct {
    pending:bool,
    found:[dynamic]Recovery_Found, // pending: one per document
    assets:bool, // pending: copies of unsaved assets are there (recovery_assets_folder)
    tabs:bool,   // pending: every tab of an editor that ended for its GPU (recovery_tabs_keep)
    assets_owned:bool,
    assets_revision,assets_deadline:u64, // of the registry when the assets were last kept
    tables:^Collab_State,         // the tables as their rows travel, for every log
    tables_info:^core.World_Info,
    using chain:Recovery_Chain,   // of the document in front
}

// A capture of the document that a job writes beside the frames. It owns
// what it writes, in the allocator of the app, which jobs can share.
@(private)
Recovery_Write :: struct {
    busy:bool,
    scene:asset.Scene,
    path:string,
    saved:u64, // the edits it holds
    log:u64,   // the generation of the log that follows it
    error:asset.Error,
    counter:jobs.Counter,
}

@(private)
recovery_file :: proc(s:^Session,slot:int) -> string {
    return project.path(project.folder_path(s.project_root,.Generated,context.temp_allocator),fmt.tprintf("autosave-%d.scene",slot),allocator=context.temp_allocator)
}

// The slots that have files of a chain, in order.
@(private)
recovery_slots :: proc(s:^Session) -> []int {
    found:=make([dynamic]int,context.temp_allocator)
    entries,error:=os.read_all_directory_by_path(project.folder_path(s.project_root,.Generated,context.temp_allocator),context.temp_allocator)
    if error!=nil {return found[:]}
    for entry in entries {
        name:=entry.name
        if !strings.has_prefix(name,"autosave-") {continue}
        name=name[len("autosave-"):]
        if strings.has_suffix(name,".scene") {
            name=name[:len(name)-len(".scene")]
        } else if dash:=strings.index_byte(name,'-');dash>0 && strings.has_suffix(name,".log") {
            name=name[:dash]
        } else {continue}
        slot,ok:=strconv.parse_int(name,10)
        if ok && slot>0 && !slice.contains(found[:],slot) {append(&found,slot)}
    }
    slice.sort(found[:])
    return found[:]
}

// The slot of the chain in front, given at its first use: one no tab holds
// and no file of an earlier editor has, so a start still finds those.
@(private)
recovery_slot :: proc(s:^Session) -> int {
    r:=&s.recovery
    if r.slot!=0 {return r.slot}
    used:=make(map[int]bool,context.temp_allocator)
    for slot in recovery_slots(s) {used[slot]=true}
    for &tab,index in s.documents {
        if index!=s.active_document {used[tab.recovery.slot]=true}
    }
    r.slot=1
    for used[r.slot] {r.slot+=1}
    return r.slot
}

// Removes the copy and the log of a slot. False when the copy stays.
@(private)
recovery_slot_remove :: proc(s:^Session,slot:int) -> bool {
    for generation in recovery_log_generations(s,slot) {_=os.remove(recovery_log_path(s,slot,generation))}
    file:=recovery_file(s,slot)
    return !os.exists(file) || os.remove(file)==nil
}

// The copies of the unsaved assets a recovery keeps (assets_unsaved_store).
@(private)
recovery_assets_folder :: proc(s:^Session) -> string {
    return project.path(project.folder_path(s.project_root,.Generated,context.temp_allocator),"recovery-assets",allocator=context.temp_allocator)
}

// The tabs an editor that ended for its GPU kept (recovery_tabs_keep).
@(private)
recovery_tabs_folder :: proc(s:^Session) -> string {
    return project.path(project.folder_path(s.project_root,.Generated,context.temp_allocator),RECOVERY_TABS,allocator=context.temp_allocator)
}

@(private)
recovery_open :: proc(s:^Session) {
    r:=&s.recovery
    r.tabs=os.is_file(project.path(recovery_tabs_folder(s),"restart-documents.json",allocator=context.temp_allocator))
    r.assets=assets_unsaved_kept(recovery_assets_folder(s))
    for slot in recovery_slots(s) {
        found:=Recovery_Found{slot=slot}
        source:asset.Asset
        if asset.asset_load(&source,recovery_file(s,slot))==.None {
            info,error:=asset.asset_row(&source,&s.app.assets.types,RECOVERY_TABLE,Recovery_Info)
            view,view_error:=asset.scene_view(&source,&s.app.assets.types)
            if error==.None && view_error==.None && asset.scene_view_check(view) {
                found.info=info^
                found.scene=true
            }
            asset.asset_close(&source)
        }
        // The steps the log has after the copy, or after the saved file without one.
        if !found.scene || found.info.log!=0 {
            chain,records:=recovery_log_chain(s,slot,found.scene?found.info.log:0)
            found.records=records
            if !found.scene {
                if len(chain)>0 && records>0 && len(chain[0].source)<len(found.source) {base.text_set(found.source[:],chain[0].source)} else {found.records=0}
            }
        }
        if found.scene || found.records>0 {append(&r.found,found)} else {recovery_slot_remove(s,slot)}
    }
    if len(r.found)==0 && !r.assets && !r.tabs {return}
    r.pending=true
    s.gui.modal=.Recovery
}

// Starts writing the recovery copy beside the frames. False when the World
// could not be captured; recovery_wait says whether it was written.
document_recovery :: proc(s:^Session) -> bool {
    r:=&s.recovery
    if r.pending || !recovery_wait(s) {return false}
    w:=&r.write
    info:Recovery_Info
    copy(info.source[:],document_file(s.document))
    // What changes from now on goes to the generation of the log the copy names.
    w.log=recovery_log_copy_begin(s)
    info.log=w.log
    slot:=recovery_slot(s)
    allocator:=s.app.allocator
    if document_capture(s,&w.scene,s.document.id,&info,allocator)!=.None {
        recovery_failed(s)
        return false
    }
    if asset.scene_records_put(&w.scene)!=.None {
        asset.scene_destroy(&w.scene)
        recovery_failed(s)
        return false
    }
    file:=recovery_file(s,slot)
    if folder:=project.folder_path(s.project_root,.Generated,context.temp_allocator);!os.is_dir(folder) {_=os.make_directory_all(folder)}
    w.path=strings.clone(file,allocator)
    w.saved,w.error,w.busy=edits_scene_state(s.edits),.None,true
    jobs.run(&s.app.jobs,jobs.OWNER,recovery_write,w,&w.counter)
    // Without threads a job runs when it is waited for.
    if jobs.worker_count(&s.app.jobs)==1 {return recovery_wait(s)}
    return true
}

@(private)
recovery_write :: proc(w:^Recovery_Write,worker:int) {
    w.error=asset.document_save(&w.scene.doc,w.path)
}

// Takes a write that finished: the recovery copy is written, or the next
// attempt waits. True unless it failed.
@(private)
recovery_collect :: proc(s:^Session) -> bool {
    r:=&s.recovery
    w:=&r.write
    if !w.busy || jobs.pending(&w.counter) {return true}
    w.busy=false
    asset.scene_destroy(&w.scene)
    delete(w.path,s.app.allocator)
    w.path=""
    if w.error!=.None {
        recovery_failed(s)
        r.deadline=platform.clock_ns()+RECOVERY_DELAY
        return false
    }
    r.owned=true
    r.saved,r.deadline=w.saved,0
    recovery_log_copy_done(s,w.log)
    return true
}

// Finishes the write in flight, if any. False when it failed.
@(private)
recovery_wait :: proc(s:^Session) -> bool {
    w:=&s.recovery.write
    if !w.busy {return true}
    jobs.wait(&s.app.jobs,jobs.OWNER,&w.counter)
    return recovery_collect(s)
}

@(private)
recovery_failed :: proc(s:^Session) {
    log.error("the recovery copy could not be written")
    notify(s,"The recovery copy could not be written")
}

// Removes the copy of the chain in front.
@(private)
recovery_remove :: proc(s:^Session) -> bool {
    recovery_wait(s)
    if s.recovery.slot!=0 {
        file:=recovery_file(s,s.recovery.slot)
        if os.exists(file) && os.remove(file)!=nil {return false}
    }
    s.recovery.owned=false
    return true
}

// Before the chain in front goes back with its tab: nothing of it in
// flight, every step on the disk and, when the log does not hold the changes
// over a base a start finds, a copy. A tab at the back writes nothing.
@(private)
recovery_park :: proc(s:^Session) {
    r:=&s.recovery
    l:=&r.log
    if r.pending || s.edits==nil || s.project_root=="" {return}
    recovery_wait(s)
    if l.following && l.world==s.edits.world && l.epoch==s.edits.epoch {recovery_log_write(s)}
    covered:=l.following && !l.failed && (l.base==.Source || r.owned)
    if document_dirty(s) && !covered && r.saved!=edits_scene_state(s.edits) {
        document_recovery(s)
        recovery_wait(s)
    }
    recovery_log_sync_collect(s,true)
    if l.file!=nil && l.sync_due!=0 {
        if os.sync(l.file)!=nil {recovery_log_failed(s)}
        l.sync_due=0
    }
}

// The chain of a tab at the back: its log closed and, with remove, its files gone.
@(private)
recovery_chain_close :: proc(s:^Session,chain:^Recovery_Chain,remove:bool) {
    if chain.log.file!=nil {
        os.close(chain.log.file)
        chain.log.file=nil
    }
    if remove && chain.slot!=0 {recovery_slot_remove(s,chain.slot)}
    chain.owned,chain.log.following=false,false
}

// Every chain of the editor, as it ends: closed and, with remove, their files gone.
@(private)
recovery_chains_close :: proc(s:^Session,remove:bool) {
    recovery_wait(s)
    for &tab,index in s.documents {
        if index!=s.active_document {recovery_chain_close(s,&tab.recovery,remove)}
    }
    if remove {
        recovery_log_end(s,true)
        recovery_remove(s)
    }
    recovery_log_close(s)
}

// Before what may end the editor (a Play, a Simulate): every change of the
// document is where a start after a crash finds it, in the log or in a copy.
@(private)
recovery_protect :: proc(s:^Session) -> bool {
    r:=&s.recovery
    if !document_dirty(s) {return true}
    if r.log.following && !r.log.failed && r.deadline==0 && recovery_log_flush(s,false) {return true}
    return document_recovery(s) && recovery_wait(s)
}

// What an editor that ends for its GPU leaves for the next start: every tab
// as it is and the unsaved assets, as a restart keeps them. Without them,
// the copy of the active document.
@(private)
recovery_tabs_keep :: proc(s:^Session) {
    r:=&s.recovery
    folder:=recovery_tabs_folder(s)
    os.remove_all(folder)
    _=os.make_directory_all(folder)
    if _,kept:=documents_save_restart(s,folder);kept {
        recovery_chains_close(s,true)
        return
    }
    os.remove_all(folder)
    if document_dirty(s) {document_recovery(s)}
    recovery_wait(s)
    recovery_log_flush(s,true)
    if len(assets_unsaved(s))>0 {assets_unsaved_store(s,recovery_assets_folder(s))}
    r.owned,r.assets_owned=false,false
}

// Keeps the unsaved assets beside the copy of the document, a while after
// they last changed, and removes them when none is left.
@(private)
recovery_assets_update :: proc(s:^Session) {
    r:=&s.recovery
    if s.app==nil || s.app.assets==nil {return}
    revision:=s.app.assets.registry.revision
    if len(assets_unsaved(s))==0 {
        if r.assets_owned {
            os.remove_all(recovery_assets_folder(s))
            r.assets_owned=false
        }
        r.assets_revision,r.assets_deadline=revision,0
        return
    }
    if r.assets_owned && r.assets_revision==revision {return}
    now:=platform.clock_ns()
    if r.assets_deadline==0 {r.assets_deadline=now+RECOVERY_DELAY;return}
    if now<r.assets_deadline {return}
    if assets_unsaved_store(s,recovery_assets_folder(s)) {
        r.assets_owned,r.assets_revision,r.assets_deadline=true,revision,0
    } else {
        recovery_failed(s)
        r.assets_deadline=now+RECOVERY_DELAY
    }
}

@(private)
recovery_update :: proc(s:^Session) {
    r:=&s.recovery
    recovery_collect(s)
    events_steps(s)
    if s.project_root=="" || r.pending {return}
    recovery_log_update(s)
    if playing(s) || s.edits.open || s.edits.preview || r.write.busy {return}
    recovery_assets_update(s)
    l:=&r.log
    if !document_dirty(s) {
        if r.owned {recovery_remove(s)}
        // A clean document begins a chain over its saved file.
        if l.following && (l.records>0 || l.base!=.Source && document_file(s.document)!="") {recovery_log_end(s,true)}
        r.saved,r.deadline=edits_scene_state(s.edits),0
        return
    }
    now:=platform.clock_ns()
    due:=r.deadline
    if l.failed || !l.following {
        // Without the log, the copy follows every change after a second, as it did before it.
        if r.saved==edits_scene_state(s.edits) {return}
        if due==0 {r.deadline=now+RECOVERY_DELAY;return}
    } else {
        // A chain over a copy not written yet (a document without a file) has no base a start finds.
        if due==0 && l.base==.Copy && !r.owned {due=now}
        if due==0 && l.since!=0 {due=l.since+RECOVERY_COPY_INTERVAL}
        if l.bytes>=RECOVERY_LOG_BYTES {due=now}
        if due==0 {return}
    }
    if now>=due && !document_recovery(s) {r.deadline=now+RECOVERY_DELAY}
}

// Between frames: restoring replaces the documents and their histories, and
// puts back in memory the unsaved assets, before the documents that may show
// them.
recovery_resolve :: proc(s:^Session,discard:bool) -> bool {
    r:=&s.recovery
    if !r.pending {return false}
    if discard {
        for slot in recovery_slots(s) {
            if !recovery_slot_remove(s,slot) {notify(s,"The recovery copy could not be removed");return false}
        }
        os.remove_all(recovery_assets_folder(s))
        os.remove_all(recovery_tabs_folder(s))
    } else if r.tabs {
        // Every tab, with its unsaved assets; the copies and the logs of before are older.
        if !documents_restore(s,project.path(recovery_tabs_folder(s),"restart-documents.json",allocator=context.temp_allocator)) {
            notify(s,"The tabs could not all be recovered; their copies are kept")
            return false
        }
        os.remove_all(recovery_tabs_folder(s))
        for slot in recovery_slots(s) {recovery_slot_remove(s,slot)}
        os.remove_all(recovery_assets_folder(s))
    } else {
        if r.assets {
            if _,restored:=assets_unsaved_restore(s,recovery_assets_folder(s));!restored {notify(s,"The unsaved assets could not be recovered")}
        }
        // A scene takes the tab of the scene; a prefab, or another scene, opens beside it.
        documents_ensure(s)
        scene,front:=false,-1
        for &found in r.found {
            source:=base.text_get(found.scene?found.info.source[:]:found.source[:])
            previous:=s.active_document
            beside:=scene || path_is_prefab(source) || document_scene_tab(s)<0
            if beside {
                if !document_tab_new(s) {notify(s,"A recovered document could not be opened");continue}
            } else {
                document_activate(s,document_scene_tab(s))
            }
            if !recovery_found_restore(s,&found) {
                notify(s,found.scene?"A recovery copy could not be opened; it is kept":"The scene a recovery log follows could not be opened; its log is kept")
                if beside {document_tab_drop_last(s,previous)}
                continue
            }
            scene||=!path_is_prefab(source)
            if front<0 {front=s.active_document}
        }
        if front>=0 {document_activate(s,front)}
    }
    r.assets,r.tabs=false,false
    clear(&r.found)
    r.pending=false
    s.gui.modal=.None
    return true
}

// Puts a document back in the tab in front, with its copy or the saved file
// its log follows and the steps of its log, and goes on with its chain until
// a copy holds what it put back.
@(private)
recovery_found_restore :: proc(s:^Session,found:^Recovery_Found) -> bool {
    r:=&s.recovery
    file,source:=recovery_file(s,found.slot),base.text_get(found.info.source[:])
    if !found.scene {file,source=base.text_get(found.source[:]),base.text_get(found.source[:])}
    if document_restore(s,file,source,true)!=.None {return false}
    if s.document.previous!=nil {
        if table,has:=asset.document_table(&s.document.previous.doc,RECOVERY_TABLE);has {
            asset.document_table_remove(&s.document.previous.doc,table)
        }
    }
    if found.records>0 {
        chain,_:=recovery_log_chain(s,found.slot,found.scene?found.info.log:0)
        recovery_log_replay(s,chain)
    }
    r.slot,r.owned=found.slot,found.scene
    r.log.keep,r.log.following=true,false
    r.saved,r.deadline=edits_scene_state(s.edits),platform.clock_ns()
    return true
}

@(private)
api_recover :: proc(s:^Session,call:^api.Call) {
    discard:=api.call_params(call,Api_Recovery_Params).discard
    if discard && api_turn_refused(s,call,"discard the recovery copy of unsaved changes") {return}
    if !recovery_resolve(s,discard) {
        api.call_failf(call,api.SERVER_ERROR,"The pending recovery could not be resolved: %s",string(s.toast[:s.toast_length]))
        return
    }
    api_file_result(s,call)
}

@(private)
Api_Recovery_Params :: struct {discard:bool `mirai:"optional"`}
