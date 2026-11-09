package editor

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import "mirai:cook/build"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// Git from the editor, with the git installed: the project in a repository,
// its changes, commit, push and pull. An operation is a list of git commands
// that run one after another as child processes without stopping a frame
// (git_poll); what they leave is read back with status and log. A pull that
// leaves files in conflict puts the editor in merge mode: the conflicts are
// resolved in git_merge.odin. The kinds of asset that are documents merge and
// diff through mirai (cook/build/git.odin): the editor writes their lines of
// .gitattributes on Initialize and keeps the drivers in the configuration of
// the clone.

GIT_PATH_BYTES :: 260
GIT_MESSAGE_BYTES :: 1024
GIT_HISTORY :: 12
GIT_OUTPUT_LIMIT :: 1<<22 // what a command may write before the editor stops reading it
GIT_FETCH_SECONDS :: 120  // how often an editor with a window brings what the remote has

Git_Change :: struct {
    path:[GIT_PATH_BYTES]u8, // from the root of the repository, with forward slashes
    status:u8,               // 'M' changed, 'A' added, 'D' removed, 'U' in conflict
    left_out:bool,           // the next commit leaves it out
    tracked:bool,            // the last commit has it: discarding puts that back; otherwise the file goes to the trash
    staged:bool,             // added to the index without being in the last commit
}

Git_Commit :: struct {
    hash:[16]u8,
    author:[48]u8,
    age:[32]u8, // how long ago, as git says it
    subject:[128]u8,
}

Git_Operation :: enum u8 {None,Check,Refresh,Init,Commit,Commit_Push,Push,Pull,Abort,Finish,Load,Fetch,Discard}

@(storage)
Git :: struct {
    checked:bool,    // git --version ran once
    available:bool,
    repository:bool, // the project is inside a work tree
    root:[GIT_PATH_BYTES]u8,   // of the work tree, with forward slashes
    prefix:[GIT_PATH_BYTES]u8, // the folder of the project inside it, ending in "/"; "" at its root
    branch:[96]u8,
    upstream:bool,
    ahead,behind:int,
    remote:[GIT_PATH_BYTES]u8, // the url of origin; "" without one
    merging:bool,               // a merge waits for its conflicts to be resolved
    init_later:bool,            // Initialize runs once the check says git is there and the project is no repository
    history_scroll:[2]f32,
    history_drag:[2]f32,        // the height of the history and the pointer when its edge was pressed
    changes:[dynamic]Git_Change,
    history:[dynamic]Git_Commit,
    message:[GIT_MESSAGE_BYTES]u8,message_length:int,
    remote_field:[GIT_PATH_BYTES]u8,remote_length:int,
    lfs:bool,              // Initialize sets up Git LFS for heavy binaries
    settings_stale:u8,     // the settings of build.git_settings the last read found missing or with another value, a bit each
    operation:Git_Operation,
    step:int,
    process:platform.Process,
    out,err:[dynamic]u8,
    finish_paths:[dynamic]string, // the files a merge resolved, for Finish
    discard_paths:[dynamic]string,   // what Discard takes back to the last commit
    discard_staged:[dynamic]string,  // what Discard takes out of the index
    discard_trashed:[dynamic]string, // what Discard sends to the trash once git is done
    error:[512]u8,         // what the last operation that failed said
    scroll:[2]f32,         // of the list of changes
    merge:Git_Merge,
    refreshed:f64,         // platform clock of the last refresh
    fetched:f64,           // platform clock of the last fetch; 0: none yet
    stale:bool,            // something the tab shows may have changed: it is read again when shown
    seen:[2]u64,           // the revisions of the registry and of the reviews of agents the last read saw
    panel_frame:u64,       // the frame the tab was last built in
    panel_shown:bool,
}

// The kinds of asset of the plugins the project uses, as their manifests declare them.
@(private)
git_plugin_kinds :: proc(s:^Session) -> []build.Git_Kind {
    kinds,_:=build.git_plugin_kinds(s.engine_root,{s.project_root},context.temp_allocator)
    return kinds
}

// Whether an operation runs now.
git_busy :: proc(g:^Git) -> bool {return g.operation!=.None}

// An operation that changes something runs: a read gives way to whatever the
// user asks, and runs again after it.
git_working :: proc(g:^Git) -> bool {return g.operation!=.None && g.operation!=.Check && g.operation!=.Refresh && g.operation!=.Load && g.operation!=.Fetch}

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
    if s.ai!=nil {signals[1]=s.ai.scene_serial}
    if signals!=g.seen {g.seen,g.stale=signals,true}
    if !s.headless && platform.input_frame(s.app.platform).window.focus_gained {g.stale=true}
    shown:=g.panel_frame!=0 && s.frame-g.panel_frame<=1
    if shown && !g.panel_shown {g.stale=true}
    g.panel_shown=shown
    now:=platform.clock_seconds()
    if !s.headless && g.repository && !g.merging && base.text_get(g.remote[:])!="" && (g.fetched==0 || now-g.fetched>=GIT_FETCH_SECONDS) {
        g.fetched=now
        git_start(s,.Fetch)
        return
    }
    if g.stale && shown {
        g.stale=false
        git_start(s,.Refresh)
    }
}

// The path of a change from the folder of the project.
git_change_path :: proc(g:^Git,change:^Git_Change) -> string {
    return strings.trim_prefix(base.text_get(change.path[:]),base.text_get(g.prefix[:]))
}

// Reads the state of the repository again; nothing when an operation runs.
git_refresh :: proc(s:^Session) {
    g:=s.git
    if g==nil || git_busy(g) || !s.has_project {return}
    git_start(s,g.checked?.Refresh:.Check)
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
    if git_working(g) {return "Wait for git to finish"}
    if !g.available {return "Git was not found"}
    if g.repository {return "The project is already in a repository"}
    ignore:=project.path(s.project_root,".gitignore",allocator=context.temp_allocator)
    if !os.exists(ignore) && serial.file_write_atomic(ignore,transmute([]u8)string(".mirai/\n"))!=.None {return "The .gitignore could not be written"}
    attributes:=project.path(s.project_root,".gitattributes",allocator=context.temp_allocator)
    existing,_:=os.read_entire_file(attributes,context.temp_allocator)
    if text,changed:=build.git_attributes(git_plugin_kinds(s),g.lfs,string(existing),context.temp_allocator);changed {
        if serial.file_write_atomic(attributes,transmute([]u8)text)!=.None {return "The .gitattributes could not be written"}
    }
    git_start(s,.Init)
    return ""
}

// Commits the changes not left out with the message typed, and pushes them
// after when push is set.
git_commit :: proc(s:^Session,push:bool) -> string {
    g:=s.git
    if git_working(g) {return "Wait for git to finish"}
    if g.merging {return "Resolve the conflicts of the merge first"}
    if strings.trim_space(string(g.message[:g.message_length]))=="" {return "Write a message for the commit"}
    included,left_out:=0,0
    for change in g.changes {
        if change.left_out {left_out+=1} else {included+=1}
    }
    if left_out>0 && included==0 {return "Every change is left out"}
    if documents_dirty(s) || len(assets_unsaved(s))>0 {return "Save first: a commit takes the files as they are saved"}
    git_start(s,push?.Commit_Push:.Commit)
    return ""
}

git_push :: proc(s:^Session) -> string {
    g:=s.git
    if git_working(g) {return "Wait for git to finish"}
    if base.text_get(g.remote[:])=="" {return "The repository has no remote to push to"}
    git_start(s,.Push)
    return ""
}

// Brings the commits of the remote. With changes not committed it does not:
// every conflict is then between two commits, which the merge of assets
// resolves field by field.
git_pull :: proc(s:^Session) -> string {
    g:=s.git
    if git_working(g) {return "Wait for git to finish"}
    if g.merging {return "Resolve the conflicts of the merge first"}
    if base.text_get(g.remote[:])=="" {return "The repository has no remote to pull from"}
    if documents_dirty(s) || len(assets_unsaved(s))>0 {return "Save first"}
    if len(g.changes)>0 {return "Commit your changes before pulling"}
    git_start(s,.Pull)
    return ""
}

// Puts the changes of some files back as the last commit has them, or all
// of them with paths empty; a file git does not track goes to the trash.
// With unsaved work it does not: what memory holds would be written again.
git_discard :: proc(s:^Session,paths:[]string) -> string {
    g:=s.git
    if git_working(g) {return "Wait for git to finish"}
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
    git_start(s,.Discard)
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

// Leaves the merge: the files go back to the commit before the pull.
git_abort :: proc(s:^Session) -> string {
    g:=s.git
    if git_working(g) {return "Wait for git to finish"}
    if !g.merging {return "No merge to abort"}
    git_start(s,.Abort)
    return ""
}

@(private)
git_start :: proc(s:^Session,operation:Git_Operation) {
    g:=s.git
    if g.process!=0 {platform.process_release(s.app.platform,g.process);g.process=0}
    g.operation,g.step=operation,0
    g.error={}
    git_next(s)
}

// Starts the command of the step the operation is at, skipping steps without
// one; with none left, the operation ends.
@(private)
git_next :: proc(s:^Session) {
    g:=s.git
    for g.operation!=.None {
        command:=git_command(s,g.operation,g.step)
        if command==nil {
            g.step+=1
            if g.step>=git_steps(g) {git_end(s);return}
            continue
        }
        working:=base.text_get(g.root[:])
        if working=="" || g.operation==.Check || g.operation==.Init || g.operation==.Refresh && g.step==0 {working=s.project_root}
        full:=make([dynamic]string,context.temp_allocator)
        append(&full,"git")
        append(&full,..command)
        clear(&g.out);clear(&g.err)
        // A fetch nobody asked for never opens a window of the credential manager.
        environment:=[]string{"GIT_TERMINAL_PROMPT=0","LC_ALL=C","GIT_EDITOR=true","GCM_INTERACTIVE=never"}
        if g.operation!=.Fetch {environment=environment[:3]}
        process,error:=platform.process_start(s.app.platform,{command=full[:],working_directory=working,environment=environment})
        if error!=.None {
            if g.operation==.Check {g.checked,g.available=true,false;g.operation=.None;return}
            git_fail(s,"Git could not be started")
            return
        }
        g.process=process
        return
    }
}

// The most steps an operation has.
@(private)
GIT_STEPS :: 5+build.GIT_SETTINGS

// The step of Initialize that sets up Git LFS, after the settings of the drivers.
@(private)
GIT_INIT_LFS :: 1+build.GIT_SETTINGS

@(private)
git_steps :: proc(g:^Git) -> int {return g.operation==.Load?3*len(g.merge.files):GIT_STEPS}

// The arguments of a step of an operation, or nil when it has none.
@(private)
git_command :: proc(s:^Session,operation:Git_Operation,step:int) -> []string {
    g:=s.git
    a:=context.temp_allocator
    scope:=base.text_get(g.prefix[:])
    if scope=="" {scope="."}
    list :: proc(values:..string) -> []string {
        out:=make([]string,len(values),context.temp_allocator)
        copy(out,values)
        return out
    }
    #partial switch operation {
    case .Check:
        if step==0 {return list("--version")}
    case .Refresh:
        switch step {
        case 0: return list("rev-parse","--show-toplevel","--show-prefix")
        case 1: return list("status","--porcelain=v2","--branch","-z","--untracked-files=all","--",scope)
        case 2: return list("log","-n","12","--format=%h%x1f%an%x1f%ar%x1f%s","--",scope)
        case 3: return list("remote","get-url","origin")
        case 4: return list("config","--local","--get-regexp",build.GIT_SETTINGS_PATTERN)
        case 5..<5+build.GIT_SETTINGS:
            // A clone, or an engine that moved: what the last step found missing is set.
            if g.settings_stale&(1<<uint(step-5))==0 {return nil}
            setting:=build.git_settings(s.engine_root,base.text_get(g.root[:]),a)[step-5]
            return list("config","--local",setting.key,setting.value)
        }
    case .Init:
        switch step {
        case 0: return list("init","-b","main")
        case 1..<GIT_INIT_LFS:
            setting:=build.git_settings(s.engine_root,s.project_root,a)[step-1]
            return list("config","--local",setting.key,setting.value)
        case GIT_INIT_LFS: if g.lfs {return list("lfs","install","--local")}
        case GIT_INIT_LFS+1:
            remote:=strings.trim_space(string(g.remote_field[:g.remote_length]))
            if remote!="" {return list("remote","add","origin",strings.clone(remote,a))}
        }
    case .Commit,.Commit_Push:
        // Everything under the project, or only what is not left out: what was
        // saved since the last refresh goes in with the rest.
        paths:=make([dynamic]string,a)
        left_out:=false
        for &change in g.changes {
            if change.left_out {left_out=true} else {append(&paths,strings.clone(base.text_get(change.path[:]),a))}
        }
        if !left_out {clear(&paths);append(&paths,scope)}
        switch step {
        case 0:
            command:=make([dynamic]string,a)
            append(&command,"add","-A","--")
            append(&command,..paths[:])
            return command[:]
        case 1:
            command:=make([dynamic]string,a)
            append(&command,"commit","-m",strings.clone(strings.trim_space(string(g.message[:g.message_length])),a),"--")
            append(&command,..paths[:])
            return command[:]
        case 2: if operation==.Commit_Push {return git_push_command(g)}
        }
    case .Push:
        if step==0 {return git_push_command(g)}
    case .Fetch:
        if step==0 {return list("fetch","--quiet","origin")}
    case .Discard:
        switch step {
        case 0:
            if len(g.discard_paths)==0 {return nil}
            command:=make([dynamic]string,a)
            append(&command,"restore","--source=HEAD","--staged","--worktree","--")
            append(&command,..g.discard_paths[:])
            return command[:]
        case 1:
            if len(g.discard_staged)==0 {return nil}
            command:=make([dynamic]string,a)
            append(&command,"rm","--cached","--quiet","--")
            append(&command,..g.discard_staged[:])
            return command[:]
        }
    case .Pull:
        if step==0 {return list("pull","--no-rebase","--no-edit")}
    case .Abort:
        if step==0 {return list("merge","--abort")}
    case .Finish:
        switch step {
        case 0:
            command:=make([dynamic]string,a)
            append(&command,"add","--")
            append(&command,..g.finish_paths[:])
            return command[:]
        case 1: return list("commit","--no-edit")
        }
    case .Load:
        return git_merge_load_command(g,step)
    }
    return nil
}

@(private)
git_push_command :: proc(g:^Git) -> []string {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,"push")
    if !g.upstream {append(&command,"-u","origin",strings.clone(base.text_get(g.branch[:]),context.temp_allocator))}
    return command[:]
}

// Follows the command that runs; between frames.
git_poll :: proc(s:^Session) {
    g:=s.git
    if g!=nil && g.operation==.None {git_schedule(s)}
    if g==nil || g.operation==.None || g.process==0 {return}
    buffer:[8192]u8
    for stream in platform.Process_Stream {
        into:=stream==.Stdout?&g.out:&g.err
        for _ in 0..<64 {
            count,_:=platform.process_read(s.app.platform,g.process,stream,buffer[:])
            if count==0 {break}
            if len(into)+count<=GIT_OUTPUT_LIMIT {append(into,..buffer[:count])}
        }
    }
    exited,code:=platform.process_poll(s.app.platform,g.process)
    if !exited {return}
    for stream in platform.Process_Stream {
        into:=stream==.Stdout?&g.out:&g.err
        for {
            count,_:=platform.process_read(s.app.platform,g.process,stream,buffer[:])
            if count==0 {break}
            if len(into)+count<=GIT_OUTPUT_LIMIT {append(into,..buffer[:count])}
        }
    }
    platform.process_release(s.app.platform,g.process)
    g.process=0
    if !git_step_done(s,code) {return}
    g.step+=1
    if g.step>=git_steps(g) {git_end(s);return}
    git_next(s)
}

// Reads what a step left. False when the operation ended here.
@(private)
git_step_done :: proc(s:^Session,code:int) -> bool {
    g:=s.git
    out:=string(g.out[:])
    #partial switch g.operation {
    case .Load:
        git_merge_load_done(s,g.step,code)
        return true
    case .Fetch:
        // Without the network or credentials it says nothing: the next one tries again.
        return true
    case .Check:
        g.checked,g.available=true,code==0
        if code!=0 {g.operation=.None;return false}
        // Then what the repository holds.
        g.operation,g.step=.Refresh,-1
        return true
    case .Refresh:
        switch g.step {
        case 0:
            if code!=0 {
                g.repository,g.merging=false,false
                clear(&g.changes);clear(&g.history)
                g.root,g.prefix,g.branch,g.remote={},{},{},{}
                git_end(s)
                return false
            }
            g.repository=true
            lines:=strings.split_lines(strings.trim_right_space(out),context.temp_allocator)
            base.text_set(g.root[:],len(lines)>0?lines[0]:"")
            base.text_set(g.prefix[:],len(lines)>1?strings.trim_space(lines[1]):"")
        case 1:
            if code!=0 {git_fail(s,"Git could not read the changes of the project");return false}
            git_status_read(g,out)
        case 2:
            clear(&g.history)
            if code==0 {git_log_read(g,out)}
        case 3:
            base.text_set(g.remote[:],code==0?strings.trim_space(out):"")
        case 4:
            unset,other:=build.git_settings_state(build.git_settings(s.engine_root,base.text_get(g.root[:]),context.temp_allocator),out)
            g.settings_stale=unset|other
        }
        return true
    case .Pull:
        if code!=0 {
            // A merge with conflicts leaves them for the editor; anything else failed.
            g.operation,g.step=.Refresh,-1
            if !strings.contains(out,"CONFLICT") && !strings.contains(string(g.err[:]),"CONFLICT") {
                git_fail_text(g,string(g.err[:]),"The pull failed")
                g.operation,g.step=.Refresh,-1
            }
            return true
        }
    case:
        if code!=0 && !(g.operation==.Init && g.step==GIT_INIT_LFS) {
            message:="Git failed"
            #partial switch g.operation {
            case .Init: message="The repository could not be made"
            case .Commit,.Commit_Push: message="The commit failed"
            case .Push: message="The push failed"
            case .Abort: message="The merge could not be aborted"
            case .Finish: message="The merge could not be finished"
            case .Discard: message="The changes could not be discarded"
            }
            git_fail_text(g,string(g.err[:]),message)
            g.operation,g.step=.Refresh,-1
            return true
        }
        if (g.operation==.Commit || g.operation==.Commit_Push) && g.step==1 {
            g.message={};g.message_length=0
        }
    }
    return true
}

// The operation ends and the state is read again, unless it was the reading.
// A merge that waits is read from git once; one committed or aborted goes.
@(private)
git_end :: proc(s:^Session) {
    g:=s.git
    finished:=g.operation
    failed:=base.text_get(g.error[:])!=""
    g.operation,g.step=.None,0
    g.refreshed=platform.clock_seconds()
    switch finished {
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
        git_start(s,.Refresh)
    case .Discard:
        git_discarded(s,!failed)
        git_start(s,.Refresh)
    case .None,.Init,.Commit,.Commit_Push,.Push,.Pull,.Abort,.Fetch:
        git_start(s,.Refresh)
    }
}

@(private)
git_fail :: proc(s:^Session,message:string) {
    g:=s.git
    base.text_set(g.error[:],message)
    g.operation,g.step=.None,0
    if g.process!=0 {platform.process_release(s.app.platform,g.process);g.process=0}
}

// The first line git wrote that says what went wrong, after what the editor says.
@(private)
git_fail_text :: proc(g:^Git,text:string,message:string) {
    detail:=""
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        trimmed:=strings.trim_space(line)
        if trimmed=="" || strings.has_prefix(trimmed,"hint:") {continue}
        detail=strings.trim_prefix(strings.trim_prefix(trimmed,"fatal: "),"error: ")
        break
    }
    if detail=="" {base.text_set(g.error[:],message);return}
    base.text_set(g.error[:],strings.concatenate({message,": ",detail},context.temp_allocator))
}

// git status --porcelain=v2 --branch -z: the branch, how far from its
// upstream, and one entry per file changed, added, removed or in conflict.
git_status_read :: proc(g:^Git,out:string) {
    kept:=make(map[string]bool,context.temp_allocator)
    for &change in g.changes {
        if change.left_out {kept[strings.clone(base.text_get(change.path[:]),context.temp_allocator)]=true}
    }
    clear(&g.changes)
    g.branch,g.upstream,g.ahead,g.behind,g.merging={},false,0,0,false
    rest:=out
    for entry in strings.split_iterator(&rest,"\x00") {
        if entry=="" {continue}
        switch entry[0] {
        case '#':
            if strings.has_prefix(entry,"# branch.head ") {base.text_set(g.branch[:],entry[len("# branch.head "):])}
            if strings.has_prefix(entry,"# branch.upstream ") {g.upstream=true}
            if strings.has_prefix(entry,"# branch.ab ") {
                fields:=strings.fields(entry[len("# branch.ab "):],context.temp_allocator)
                if len(fields)==2 {
                    g.ahead,_=strconv.parse_int(strings.trim_prefix(fields[0],"+"))
                    g.behind,_=strconv.parse_int(strings.trim_prefix(fields[1],"-"))
                }
            }
        case '1','2','u','?':
            fields:=strings.split_n(entry," ",entry[0]=='1'?9:entry[0]=='2'?10:entry[0]=='u'?11:2,context.temp_allocator)
            path:=fields[len(fields)-1]
            status:u8='M'
            switch entry[0] {
            case '?': status='A'
            case 'u': status='U';g.merging=true
            case:
                xy:=fields[1]
                if xy[0]=='D' || xy[1]=='D' {status='D'} else if xy[0]=='A' {status='A'}
            }
            if entry[0]=='2' {
                // The original path follows as its own entry.
                _,_=strings.split_iterator(&rest,"\x00")
            }
            change:=Git_Change{status=status,left_out=status!='U' && kept[path]}
            change.tracked=entry[0]!='?' && !(entry[0]=='1' && fields[1][0]=='A')
            change.staged=entry[0]=='1' && fields[1][0]=='A'
            base.text_set(change.path[:],path)
            append(&g.changes,change)
        }
    }
}

// git log --format=%h%x1f%an%x1f%ar%x1f%s: one commit per line.
git_log_read :: proc(g:^Git,out:string) {
    rest:=out
    for line in strings.split_lines_iterator(&rest) {
        if len(g.history)>=GIT_HISTORY {break}
        parts:=strings.split(line,"\x1f",context.temp_allocator)
        if len(parts)!=4 {continue}
        commit:Git_Commit
        base.text_set(commit.hash[:],parts[0])
        base.text_set(commit.author[:],parts[1])
        base.text_set(commit.age[:],parts[2])
        base.text_set(commit.subject[:],parts[3])
        append(&g.history,commit)
    }
}
