package editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:cook/build"
import "mirai:editor/git"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// Git from the editor: the project in a repository, its changes, what is kept
// of them (the index), commit, push and pull. The commands run in editor/git; here is what they need of the
// session (the files of the project, the assets read again) and what starts
// them. A pull that leaves files in conflict puts the editor in
// merge mode: the conflicts are resolved in git_merge.odin. The editor writes
// the lines of .gitattributes of the kinds of asset on Initialize.

GIT_FETCH_SECONDS :: 120 // how often an editor with a window brings what the remote has
GIT_STATUS_SECONDS :: 1  // how often the changes are read again while the Git tab is hidden

// Why the pending changes are listed: the editor found them when it opened, or it ends.
Git_Notice :: enum u8 {None,Open,Quit}

@(storage)
Git :: struct {
    using repo:git.Repository,
    init_later:bool,            // Initialize runs once the check says git is there and the project is no repository
    notice:Git_Notice,          // what Modal.Pending asks about
    told:bool,                  // the pending changes the editor found when it opened were told
    quits:bool,                 // the editor ends once the changes are kept or discarded
    warned:bool,                // a headless editor said its project is no repository
    history_scroll:[2]f32,
    history_drag:[2]f32,        // the height of the history and the pointer when its edge was pressed
    scroll:f32,            // of the list of changes
    merge:Git_Merge,
    entities:Git_Entities,
    refreshed:f64,         // platform clock of the last refresh
    fetched:f64,           // platform clock of the last fetch; 0: none yet
    stale:bool,            // something it shows may have changed: it is read again
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
    // The tabs show what is pending too: read again with the tab hidden, less often.
    if g.stale && g.repository && (shown || now-g.refreshed>=GIT_STATUS_SECONDS) {
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

// Commits what is kept with the message typed, or every change when nothing
// is kept, and pushes after when push is set.
git_commit :: proc(s:^Session,push:bool) -> string {
    g:=s.git
    if git.working(g) {return "Wait for git to finish"}
    if g.merging {return "Resolve the conflicts of the merge first"}
    if strings.trim_space(string(g.message[:g.message_length]))=="" {return "Write a message for the commit"}
    files_flush(s,true)
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
    if len(g.changes)>0 {return "Commit your changes before pulling"}
    git.start(g,git_roots(s),.Pull)
    return ""
}

// The path of a file of the project from the root of the repository, as
// git.Change names it; "" for one outside it.
git_path :: proc(s:^Session,file:string) -> string {
    root:=base.text_get(s.git.root[:])
    if root=="" || len(file)<=len(root)+1 || file[len(root)]!='/' || !project.path_same(file[:len(root)],root) {return ""}
    return file[len(root)+1:]
}

// Whether a file of the project has what the index does not, as git last said.
git_pending :: proc(s:^Session,file:string) -> bool {
    g:=s.git
    if g==nil || file=="" {return false}
    path:=git_path(s,file)
    for &change in g.changes {
        if change.pending && project.path_same(base.text_get(change.path[:]),path) {return true}
    }
    return false
}

// How many files of the project are pending, as git last said.
git_pending_count :: proc(s:^Session) -> (count:int) {
    if s.git==nil {return}
    for change in s.git.changes {count+=int(change.pending && change.status!='U')}
    return
}

// Keeps (adds to the index), takes out of what is kept, or discards (puts
// back from the index; a file git does not track goes to the trash) the
// changes of some files, by their paths from the root of the repository, or
// all of them with none.
git_changes_run :: proc(s:^Session,operation:git.Operation,paths:[]string) -> string {
    g:=s.git
    if git.working(g) {return "Wait for git to finish"}
    if !g.repository {return "The project is not in a repository"}
    if g.merging {return "Resolve the conflicts of the merge first"}
    files_flush(s,true)
    git.start_paths(g,git_roots(s),operation,paths)
    return ""
}

// Keeps the document in front and the files its steps wrote.
git_keep_front :: proc(s:^Session) -> string {
    files:=make([dynamic]string,context.temp_allocator)
    add :: proc(s:^Session,files:^[dynamic]string,file:string) {
        if path:=git_path(s,file);path!="" && !slice.contains(files[:],path) {append(files,path)}
    }
    if d:=asset_document_active(s);d!=nil {
        path:=asset_document_path(s,d)
        if r:=files_registry(s);r!=nil && path!="" && !asset.registry_outside(path) {path=asset.registry_file_path(r,path,context.temp_allocator)}
        add(s,&files,path)
        for &step in d.history.steps {for &file in step.files {add(s,&files,file.path)}}
    } else {
        add(s,&files,document_file(s.document))
        for &step in s.edits.steps {for &file in step.files {add(s,&files,file.path)}}
    }
    if len(files)==0 {return "The document in front has no file of the repository"}
    return git_changes_run(s,.Keep,files[:])
}

// After git put the files back: those it does not track go to the trash and
// the assets are read again; the documents follow their files with the next
// flush, and the one in front whose file is gone closes.
@(private)
git_discarded :: proc(s:^Session,ok:bool) {
    g:=s.git
    root:=base.text_get(g.root[:])
    files:=make([dynamic]string,context.temp_allocator)
    for &change in g.changes {
        if !git.takes(g,&change) {continue}
        path:=base.text_get(change.path[:])
        absolute:=project.path(root,path,allocator=context.temp_allocator)
        if ok && !change.tracked && !platform.trash(absolute) {notify(s,fmt.tprintf("%s could not be moved to the trash",path))}
        append(&files,absolute)
    }
    if s.app!=nil && s.app.assets!=nil {
        assets_wrote(s,..files[:])
        for file in files {
            if relative,inside:=asset.registry_relative(&s.app.assets.registry,file);inside {host.app_asset_changed(s.app,relative)}
        }
    }
    if open:=document_file(s.document);open!="" && !os.exists(open) {
        for file in files {
            if project.path_same(file,open) {document_close_active(s);break}
        }
    }
}

// Why the editor edits nothing in its project: git is not there, or the
// project is in no repository. "" when it can, and before git answered.
git_missing :: proc(s:^Session) -> string {
    g:=s.git
    if g==nil || !s.has_project || !g.checked || g.init_later || g.operation==.Init {return ""}
    if !g.available {return "Git was not found: the editor keeps the changes of a project with it. Install git and open the project again"}
    if !g.repository {return "The project is not in a git repository: git.init makes it one, or `git init` in its folder"}
    return ""
}

// The state of the repository was read: what the editor says once of it, and
// the dialog that stands while the project is in no repository.
@(private)
git_read :: proc(s:^Session) {
    g:=s.git
    windowed:=s.gui!=nil && !s.headless && !(s.projects!=nil && s.projects.launcher)
    if missing:=git_missing(s);missing!="" {
        if windowed && s.gui.modal==.None {s.gui.modal=.No_Repository}
        if !windowed && !g.warned {
            g.warned=true
            fmt.eprintfln("mirai: %s: %s",s.project_root,missing)
        }
        return
    }
    if s.gui!=nil && s.gui.modal==.No_Repository {s.gui.modal=.None}
    if g.told || !g.repository {return}
    g.told=true
    if windowed && s.gui.modal==.None && git_pending_count(s)>0 {
        g.notice=.Open
        s.gui.modal=.Pending
    }
}

// The editor is asked to end with pending changes: it lists them first.
// False when there is nothing to ask.
git_quit_ask :: proc(s:^Session) -> bool {
    g:=s.git
    if g==nil || s.gui==nil || s.headless || !g.repository || g.merging || git_pending_count(s)==0 {return false}
    g.notice=.Quit
    s.gui.modal=.Pending
    return true
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
        git_read(s)
        if g.init_later {
            g.init_later=false
            if g.available && !g.repository {
                if message:=git_init(s);message!="" {notify(s,message)}
            }
        }
    case .Finish:
        if !failed {git_merge_finished(s)}
        git.start(g,git_roots(s),.Refresh)
    case .Base:
        git_entities_read(s)
    case .Keep,.Discard:
        if finished==.Discard {git_discarded(s,!failed)}
        quits:=g.quits && !failed
        g.quits=false
        git.start(g,git_roots(s),.Refresh)
        if quits {documents_quit(s,true,true)}
    case:
        git.start(g,git_roots(s),.Refresh)
    }
}
