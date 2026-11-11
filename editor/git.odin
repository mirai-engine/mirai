package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:asset"
import "mirai:cook/build"
import "mirai:editor/git"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// Git from the editor: the project in a repository, its changes, commit, push
// and pull. The commands run in editor/git; here is what they need of the
// session (unsaved work, the files of the project, the assets read again) and
// what starts them. A pull that leaves files in conflict puts the editor in
// merge mode: the conflicts are resolved in git_merge.odin. The editor writes
// the lines of .gitattributes of the kinds of asset on Initialize.

GIT_FETCH_SECONDS :: 120 // how often an editor with a window brings what the remote has

@(storage)
Git :: struct {
    using repo:git.Repository,
    init_later:bool,            // Initialize runs once the check says git is there and the project is no repository
    history_scroll:[2]f32,
    history_drag:[2]f32,        // the height of the history and the pointer when its edge was pressed
    discard_trashed:[dynamic]string, // what Discard sends to the trash once git is done
    scroll:[2]f32,         // of the list of changes
    merge:Git_Merge,
    refreshed:f64,         // platform clock of the last refresh
    fetched:f64,           // platform clock of the last fetch; 0: none yet
    stale:bool,            // something the tab shows may have changed: it is read again when shown
    seen:[2]u64,           // the revisions of the registry and of the reviews of agents the last read saw
    panel_frame:u64,       // the frame the tab was last built in
    panel_shown:bool,
}

@(private)
git_roots :: proc(s:^Session) -> git.Roots {return {engine=s.engine_root,project=s.project_root}}

// The kinds of asset of the plugins the project uses, as their manifests declare them.
@(private)
git_plugin_kinds :: proc(roots:git.Roots) -> []build.Git_Kind {
    kinds,_:=build.git_plugin_kinds(roots.engine,{roots.project},context.temp_allocator)
    return kinds
}

// What starts git on its own between operations: the first check, a fetch
// every GIT_FETCH_SECONDS in an editor with a window, and a read when the tab
// is shown and something it shows may have changed (a file of the registry,
// a review of an agent, the window back in focus, the tab opened).
git_schedule :: proc(s:^Session) {
    g:=s.git
    if g==nil || g.operation!=.None || !s.has_project || s.app==nil {return}
    if !g.checked {git_refresh(s);return}
    if !g.available {return}
    signals:=[2]u64{}
    if s.app.assets!=nil {signals[0]=s.app.assets.registry.revision}
    signals[1]=ai_scene_serial(s.ai)
    if signals!=g.seen {g.seen,g.stale=signals,true}
    if !s.headless && platform.input_frame(s.app.platform).window.focus_gained {g.stale=true}
    shown:=g.panel_frame!=0 && s.frame-g.panel_frame<=1
    if shown && !g.panel_shown {g.stale=true}
    g.panel_shown=shown
    now:=platform.clock_seconds()
    if !s.headless && g.repository && !g.merging && base.text_get(g.remote[:])!="" && (g.fetched==0 || now-g.fetched>=GIT_FETCH_SECONDS) {
        g.fetched=now
        git.start(g,git_roots(s),.Fetch)
        return
    }
    if g.stale && shown {
        g.stale=false
        git.start(g,git_roots(s),.Refresh)
    }
}

// Reads the state of the repository again; nothing when an operation runs.
git_refresh :: proc(s:^Session) {
    g:=s.git
    if g==nil || git.busy(g) || !s.has_project {return}
    git.start(g,git_roots(s),g.checked?.Refresh:.Check)
}

// A project created with Initialize Git repository: the editor started on it
// makes the repository once git has answered.
git_init_later :: proc(s:^Session,remote:string,lfs:bool) {
    g:=s.git
    g.init_later,g.lfs=true,lfs
    g.remote_length=copy(g.remote_field[:],remote)
    git_refresh(s)
}

// Makes the folder of the project a repository: a .gitignore without .mirai,
// the .gitattributes of the kinds of asset of the engine and of the plugins
// the project uses (build.git_attributes), which with LFS keeps heavy binaries
// out of the history, and the remote when one is given.
git_init :: proc(s:^Session) -> string {
    g:=s.git
    if git.working(g) {return "Wait for git to finish"}
    if !g.available {return "Git was not found"}
    if g.repository {return "The project is already in a repository"}
    ignore:=project.path(s.project_root,".gitignore",allocator=context.temp_allocator)
    if !os.exists(ignore) && serial.file_write_atomic(ignore,transmute([]u8)string(".mirai/\n"))!=.None {return "The .gitignore could not be written"}
    attributes:=project.path(s.project_root,".gitattributes",allocator=context.temp_allocator)
    existing,_:=os.read_entire_file(attributes,context.temp_allocator)
    if text,changed:=build.git_attributes(git_plugin_kinds(git_roots(s)),g.lfs,string(existing),context.temp_allocator);changed {
        if serial.file_write_atomic(attributes,transmute([]u8)text)!=.None {return "The .gitattributes could not be written"}
    }
    git.start(g,git_roots(s),.Init)
    return ""
}

// Commits the changes not left out with the message typed, and pushes them
// after when push is set.
git_commit :: proc(s:^Session,push:bool) -> string {
    g:=s.git
    if git.working(g) {return "Wait for git to finish"}
    if g.merging {return "Resolve the conflicts of the merge first"}
    if strings.trim_space(string(g.message[:g.message_length]))=="" {return "Write a message for the commit"}
    included,left_out:=0,0
    for change in g.changes {
        if change.left_out {left_out+=1} else {included+=1}
    }
    if left_out>0 && included==0 {return "Every change is left out"}
    if documents_dirty(s) || len(assets_unsaved(s))>0 {return "Save first: a commit takes the files as they are saved"}
    git.start(g,git_roots(s),push?.Commit_Push:.Commit)
    return ""
}

// Brings the commits of the remote. With changes not committed it does not:
// every conflict is then between two commits, which the merge of assets
// resolves field by field.
git_pull :: proc(s:^Session) -> string {
    g:=s.git
    if git.working(g) {return "Wait for git to finish"}
    if g.merging {return "Resolve the conflicts of the merge first"}
    if base.text_get(g.remote[:])=="" {return "The repository has no remote to pull from"}
    if documents_dirty(s) || len(assets_unsaved(s))>0 {return "Save first"}
    if len(g.changes)>0 {return "Commit your changes before pulling"}
    git.start(g,git_roots(s),.Pull)
    return ""
}

// Puts the changes of some files back as the last commit has them, or all
// of them with paths empty; a file git does not track goes to the trash.
// With unsaved work it does not: what memory holds would be written again.
git_discard :: proc(s:^Session,paths:[]string) -> string {
    g:=s.git
    if git.working(g) {return "Wait for git to finish"}
    if g.merging {return "Resolve the conflicts of the merge first"}
    if documents_dirty(s) || len(assets_unsaved(s))>0 {return "Save or discard the unsaved changes first"}
    for list in ([3]^[dynamic]string{&g.discard_paths,&g.discard_staged,&g.discard_trashed}) {
        for path in list {delete(path)}
        clear(list)
    }
    for &change in g.changes {
        path:=base.text_get(change.path[:])
        if change.status=='U' {continue}
        if len(paths)>0 {
            wanted:=false
            for p in paths {if p==path {wanted=true;break}}
            if !wanted {continue}
        }
        switch {
        case change.tracked: append(&g.discard_paths,strings.clone(path))
        case change.staged:  append(&g.discard_staged,strings.clone(path));append(&g.discard_trashed,strings.clone(path))
        case:                append(&g.discard_trashed,strings.clone(path))
        }
    }
    if len(g.discard_paths)+len(g.discard_trashed)==0 {return "Nothing to discard"}
    git.start(g,git_roots(s),.Discard)
    return ""
}

// After git put the files back: those it does not track go to the trash,
// the assets are read again, and the scene open in a tab reads its file again.
@(private)
git_discarded :: proc(s:^Session,ok:bool) {
    g:=s.git
    root:=base.text_get(g.root[:])
    if ok {
        for path in g.discard_trashed {
            if !platform.trash(project.path(root,path,allocator=context.temp_allocator)) {notify(s,fmt.tprintf("%s could not be moved to the trash",path))}
        }
    }
    open:=document_file(s.document)
    reopen:=false
    files:=make([dynamic]string,context.temp_allocator)
    for list in ([2]^[dynamic]string{&g.discard_paths,&g.discard_trashed}) {
        for path in list {
            absolute:=project.path(root,path,allocator=context.temp_allocator)
            if project.path_same(absolute,open) {reopen=true}
            append(&files,absolute)
        }
    }
    if s.app!=nil && s.app.assets!=nil {
        assets_wrote(s,..files[:])
        for file in files {
            if relative,inside:=asset.registry_relative(&s.app.assets.registry,file);inside {host.app_asset_changed(s.app,relative)}
        }
    }
    if reopen && os.exists(open) {scene_open(s,open)}
}

// Follows the command that runs, between frames, and starts what git does on its own.
git_poll :: proc(s:^Session) {
    g:=s.git
    if g==nil {return}
    git_ended(s)
    if g.operation==.None {git_schedule(s)}
    if g.operation==.None || g.process.pid==0 {return}
    exited,code:=git.poll(g)
    if !exited {return}
    if g.operation==.Load {git_merge_load_done(g,g.step,code)}
    git.advance(g,git_roots(s),code)
    git_ended(s)
}

// An operation ended: the state is read again, unless it was the reading. A
// merge that waits is read from git once; one committed or aborted goes.
@(private)
git_ended :: proc(s:^Session) {
    g:=s.git
    finished,failed:=git.ended(g)
    if finished==.None {return}
    g.refreshed=platform.clock_seconds()
    #partial switch finished {
    case .Load:
        git_merge_compute(s)
    case .Refresh,.Check:
        if g.merging && !g.merge.loaded {git_merge_load_start(s)}
        else if !g.merging && g.merge.loaded {git_merge_clear(g)}
        if g.init_later {
            g.init_later=false
            if g.available && !g.repository {
                if message:=git_init(s);message!="" {notify(s,message)}
            }
        }
    case .Finish:
        if !failed {git_merge_finished(s)}
        git.start(g,git_roots(s),.Refresh)
    case .Discard:
        git_discarded(s,!failed)
        git.start(g,git_roots(s),.Refresh)
    case:
        git.start(g,git_roots(s),.Refresh)
    }
}
