package editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import build "mirai:cook/build"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// A Build takes what was built since the editor loaded it, while the editor
// runs. The libraries of the engine built again are taken in place when they
// declare what they did (engine_take). The library of the project: when
// the new one lays its worlds out as the loaded one, its procedures take over
// the same memory. Otherwise every struct of the worlds migrates, where it
// is, to the new layout (core.place_migrate, host.app_worlds_migrate): the
// scenes, the history, the Play and the runs of the agents go on, and so do
// the agents. The editor restarts with the scene as it is only when the
// migration cannot keep what the engine holds in place: a storage of the
// engine that would move, or a struct past the room it has. Libraries stay loaded until the
// editor ends: what a world holds can point into them.

Library_Reload :: enum u8 {
    Reloaded,
    Wait,    // something runs that the migration cannot move: a call of the API, a load
    Restart, // the editor starts again on the new library
    Refused, // the new library leaves out components the open documents hold: the next build tries again
}

@(private)
library_reload :: proc(s:^Session) -> Library_Reload {
    if library_busy(s) {return .Wait}
    taken,goes_on:=engine_take(s)
    if !goes_on {return .Restart}
    stamp:=library_stamp_here(s,context.temp_allocator)
    if stamp==s.library_stamp {
        if taken {s.library_generation+=1}
        return .Reloaded
    }
    tool_preview_cancel(s)
    path:=project.project_library(s.project_root,"editor")
    s.library_generation+=1
    library,error:=host.project_library_load(path,s.library_generation)
    if error!=.None {
        log.errorf("%s",host.library_error_text(error,path))
        return .Restart
    }
    if core.world_layout_hash(&library.info)!=core.world_layout_hash(s.info) {
        if outcome:=library_migrate(s,&library);outcome!=.Reloaded {
            host.project_library_unload(&library)
            return outcome
        }
    } else {
        s.info^=library.info
    }
    if len(s.app.step_ns)!=len(s.info.steps) {
        delete(s.app.step_ns,s.app.allocator)
        s.app.step_ns=make([]u64,len(s.info.steps),s.app.allocator)
    }
    append(&s.libraries,library)
    delete(s.library_stamp)
    s.library_stamp=strings.clone(stamp)
    log.infof("code reloaded from %s",path)
    notify(s,"Code reloaded")
    return .Reloaded
}

// Takes in place the libraries of the engine a build left since this editor
// loaded the ones it runs (build.engine_swap): only bodies of their
// procedures changed, so the worlds, the documents, the Play and every thread
// go on and the next call into them runs the new code. goes_on is false,
// having said why in a line, when the editor has to start again on them.
@(private)
engine_take :: proc(s:^Session) -> (taken,goes_on:bool) {
    folder:=engine_folder_here(s)
    now:=build.engine_stamp_of(folder,context.temp_allocator)
    if s.engine_stamp=="" || now==s.engine_stamp {return false,true}
    libraries,restart:=build.engine_swap(build.ENGINE_MODE_HERE,s.engine_stamp,now,context.temp_allocator)
    names:=strings.builder_make(context.temp_allocator)
    for library in libraries {
        s.library_generation+=1
        loaded,error:=host.engine_library_swap(folder,library.file,library.packages,s.library_generation)
        if error!=.None {
            restart=host.library_error_text(error,library.file)
            break
        }
        append(&s.libraries,loaded)
        fmt.sbprintf(&names,"%s%s",strings.builder_len(names)>0?", ":"",library.file)
    }
    if restart!="" {
        log.infof("the engine was built again and the editor restarts on it: %s",restart)
        return false,false
    }
    delete(s.engine_stamp)
    s.engine_stamp=strings.clone(now)
    if len(libraries)==0 {return false,true}
    log.infof("engine code reloaded: %s",strings.to_string(names))
    notify(s,"Engine code reloaded")
    return true,true
}

// The folder this editor started from, with forward slashes: where the
// binaries of a build of its engine are, also once a build moved the ones it
// runs aside (build.engine_unlock), which some systems then name as its
// executable.
engine_folder_here :: proc(s:^Session) -> string {
    return s.program[:max(strings.last_index_byte(s.program,'/'),0)]
}

// The program of the engine named beside this editor: the player, the importer.
engine_program_here :: proc(s:^Session,name:string) -> string {
    file:=strings.concatenate({name,project.EXECUTABLE_SUFFIX},context.temp_allocator)
    return project.path(engine_folder_here(s),file,allocator=context.temp_allocator)
}

// The stamp beside the binaries this editor started from, as it is now.
engine_stamp_here :: proc(s:^Session,allocator:=context.allocator) -> string {
    return build.engine_stamp_of(engine_folder_here(s),allocator)
}

// The stamp of the library of the project the last build left.
library_stamp_here :: proc(s:^Session,allocator:=context.allocator) -> string {
    return build.target_stamp_of(s.project_root,.Editor,allocator)
}

// Whether a build left binaries, of the engine or of the project, that this editor has not loaded.
library_stale :: proc(s:^Session) -> bool {
    return s.engine_stamp!="" && engine_stamp_here(s,context.temp_allocator)!=s.engine_stamp || library_stamp_here(s,context.temp_allocator)!=s.library_stamp
}

// The record mirai session keeps of the editor it opened (api.SESSION_FILE)
// follows this one to the editor it starts in its place, so that the session
// stays the project's after a restart.
@(private)
session_record_follow :: proc(s:^Session,pid:int) {
    if !s.has_project {return}
    path:=project.path(s.project_root,".mirai",api.SESSION_FILE,allocator=context.temp_allocator)
    data,error:=os.read_entire_file(path,context.temp_allocator)
    record:api.Session_Record
    if error!=nil || serial.text_decode(string(data),&record,context.temp_allocator)!="" || record.pid!=os.get_pid() {return}
    record.pid=pid
    if written,encoded:=serial.text_encode(record,.Pretty,context.temp_allocator);encoded {
        _=serial.file_write_atomic(path,written)
    }
}

// What keeps the worlds from migrating now: a call of the API that runs frames holds them on its
// stack (one of the editor in api_wait does not; one of a plugin runs its library's code), and a
// scene or a section that loads fills one over frames.
@(private)
library_busy :: proc(s:^Session) -> bool {
    if st:=api_state(s);st!=nil && (st.provided_calls>0 || st.waiting==0 && (st.in_call>0 || st.stepping)) {return true}
    app:=s.app
    if loads:=core.world_storage_of(core.world_ref(app.shared,s.info,.Shared),scene.Scene_Loads);loads!=nil && loads.job!=nil {return true}
    for slot in app.worlds {
        if slot.data==nil {continue}
        if sections:=host.app_world_storage(app,slot.data,scene.Section_Loads);sections!=nil {
            for item in sections.items {if item.job!=nil {return true}}
            for item in sections.far {if item.job!=nil {return true}}
        }
    }
    return false
}

// The worlds move to the layout of library. Restart, with nothing changed,
// when the engine would not keep its storages where they are; Refused when
// the open documents hold rows of a component library leaves out.
@(private)
library_migrate :: proc(s:^Session,library:^host.Project_Library) -> Library_Reload {
    info:=new(core.World_Info)
    info^=library.info
    m:core.World_Migration
    if !core.world_migration_make(&m,s.info,info) {
        core.world_migration_destroy(&m)
        free(info)
        return .Restart
    }
    defer core.world_migration_destroy(&m)
    if dropped:=library_rows_dropped(s,&m);dropped!="" {
        log.warnf("%s",dropped)
        notify(s,dropped)
        if s.build.play.pending {base.text_set(s.build.play_error[:],dropped)}
        free(info)
        return .Refused
    }
    // The editor and the engine hold their storages by address across frames.
    for &t,i in info.storages {
        if t.place==.World || t.plugin!="" || t.game || m.storages[i]!=.Move {continue}
        if m.from.storages[m.storage_sources[i]].offset!=t.offset {
            log.infof("the layout of the world changed and %s would move: restarting",t.name)
            free(info)
            return .Restart
        }
    }
    // What holds worlds of another layout or rows by table elsewhere ends first.
    if s.mode==.Watch {watch_stop(s)}
    play_plugin_stop(s)
    for &r in s.runs {
        if r.world!=nil && r.player>0 {run_free(s,&r)}
        // Its copies of the World are of the old layout: its past starts again.
        if r.world!=nil {history_free(s,&r)}
    }
    replay_free(s)
    collab_leave(s)
    history.edits_commit(s.edits,edited_world(s),s.selection)
    for slot in s.app.worlds {
        if slot.data!=nil {core.world_settle(core.world_ref(slot.data,s.info))}
    }
    if !host.app_worlds_migrate(s.app,&m,s.editor_world) {
        log.info("the worlds of the new layout do not fit the room they have: restarting")
        free(info)
        return .Restart
    }
    s.info=info
    session_bind(s)
    // The history and the reviews name tables by index and hold their values.
    edits_relayout(s.edits,edited_world(s),&m)
    for &tab,i in s.documents {
        if i==s.active_document || tab.world==nil {continue}
        edits_relayout(&tab.edits,core.world_ref(tab.world,info),&m)
    }
    for &task in ai_tasks(s.ai) {
        for &set in task.review.transactions {change_rows_relayout(&set,&m)}
    }
    sections_relayout(s,&m)
    log.infof("the layout of the world changed: its worlds moved to it")
    return .Reloaded
}

// What taking the layout of m would drop of the open documents: the
// components it leaves out that they hold rows of. "" when none.
@(private)
library_rows_dropped :: proc(s:^Session,m:^core.World_Migration) -> string {
    dropped:=make([dynamic]int,context.temp_allocator)
    rows,documents:=0,0
    for i in -1..<len(s.documents) {
        world:=s.edit_world if i<0 else s.documents[i].world
        if i==s.active_document || world==nil {continue}
        held:=false
        for &t,j in m.from.tables {
            if m.table_map[j]>=0 || t.derived || t.place!=.World {continue}
            count:=len(core.world_table_at(core.world_ref(world,m.from),&t).entities)
            if count==0 {continue}
            rows+=count
            held=true
            if !slice.contains(dropped[:],j) {append(&dropped,j)}
        }
        if held {documents+=1}
    }
    if rows==0 {return ""}
    names:=strings.builder_make(context.temp_allocator)
    for j,at in dropped {fmt.sbprintf(&names,"%s%s",at>0?", ":"",m.from.tables[j].name)}
    return fmt.tprintf("The build was not taken: it leaves out %s, which the open documents hold (%d rows in %d documents). Remove those components or close those documents, or keep the type (one renamed names the old name with @(component,was=)); the next build tries again",strings.to_string(names),rows,documents)
}
