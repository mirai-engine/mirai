package git

import "core:fmt"
import "core:strconv"
import "core:strings"
import "mirai:cook/build"
import "mirai:platform"
import "mirai:std/base"

// Git as child processes, with the git installed. An operation is a list of
// git commands that run one after another without stopping a frame: poll
// follows the command that runs and advance reads what it left and starts
// the next one. What they leave is read back with status and log. The kinds
// of asset that are documents merge and diff through mirai
// (cook/build/git.odin): the drivers are kept in the configuration of the
// clone.

PATH_BYTES :: 260
MESSAGE_BYTES :: 1024
HISTORY :: 12
OUTPUT_LIMIT :: 1<<22 // what a command may write before it stops being read

Change :: struct {
    path:[PATH_BYTES]u8, // from the root of the repository, with forward slashes
    status:u8,           // 'M' changed, 'A' added, 'D' removed, 'U' in conflict
    left_out:bool,       // the next commit leaves it out
    tracked:bool,        // the last commit has it: discarding puts that back; otherwise the file goes to the trash
    staged:bool,         // added to the index without being in the last commit
}

Commit :: struct {
    hash:[16]u8,
    author:[48]u8,
    age:[32]u8, // how long ago, as git says it
    subject:[128]u8,
}

Operation :: enum u8 {None,Check,Refresh,Init,Commit,Commit_Push,Push,Pull,Abort,Finish,Load,Fetch,Discard}

// The folders a command needs: that of the engine, for the drivers of the
// assets, and that of the project.
Roots :: struct {engine,project:string}

Repository :: struct {
    checked:bool,    // git --version ran once
    available:bool,
    repository:bool, // the project is inside a work tree
    root:[PATH_BYTES]u8,   // of the work tree, with forward slashes
    prefix:[PATH_BYTES]u8, // the folder of the project inside it, ending in "/"; "" at its root
    branch:[96]u8,
    upstream:bool,
    ahead,behind:int,
    remote:[PATH_BYTES]u8, // the url of origin; "" without one
    merging:bool,          // a merge waits for its conflicts to be resolved
    changes:[dynamic]Change,
    history:[dynamic]Commit,
    settings_stale:u8,     // the settings of build.git_settings the last read found missing or with another value, a bit each
    operation:Operation,
    step:int,
    process:platform.Process,
    out,err:[dynamic]u8,
    error:[512]u8,         // what the last operation that failed said
    finished:Operation,    // the operation that ended and ended has not given yet
    finished_failed:bool,

    // What the commands of an operation take, set before it starts.
    message:[MESSAGE_BYTES]u8,message_length:int, // of Commit
    remote_field:[PATH_BYTES]u8,remote_length:int, // of Init
    lfs:bool,                     // Init sets up Git LFS for heavy binaries
    finish_paths:[dynamic]string, // the files a merge resolved, for Finish
    discard_paths:[dynamic]string,  // what Discard takes back to the last commit
    discard_staged:[dynamic]string, // what Discard takes out of the index
    load_paths:[dynamic]string,   // the files in conflict whose three stages Load reads, one per step
}

// Whether an operation runs now.
busy :: proc(r:^Repository) -> bool {return r.operation!=.None}

// An operation that changes something runs: a read gives way to whatever the
// user asks, and runs again after it.
working :: proc(r:^Repository) -> bool {return r.operation!=.None && r.operation!=.Check && r.operation!=.Refresh && r.operation!=.Load && r.operation!=.Fetch}

// The path of a change from the folder of the project.
change_path :: proc(r:^Repository,change:^Change) -> string {
    return strings.trim_prefix(base.text_get(change.path[:]),base.text_get(r.prefix[:]))
}

push :: proc(r:^Repository,p:^platform.Platform,roots:Roots) -> string {
    if working(r) {return "Wait for git to finish"}
    if base.text_get(r.remote[:])=="" {return "The repository has no remote to push to"}
    start(r,p,roots,.Push)
    return ""
}

// Leaves the merge: the files go back to the commit before the pull.
abort :: proc(r:^Repository,p:^platform.Platform,roots:Roots) -> string {
    if working(r) {return "Wait for git to finish"}
    if !r.merging {return "No merge to abort"}
    start(r,p,roots,.Abort)
    return ""
}

start :: proc(r:^Repository,p:^platform.Platform,roots:Roots,operation:Operation) {
    if r.process!=0 {platform.process_release(p,r.process);r.process=0}
    r.operation,r.step=operation,0
    r.error={}
    next(r,p,roots)
}

// Starts the command of the step the operation is at, skipping steps without
// one; with none left, the operation ends.
@(private)
next :: proc(r:^Repository,p:^platform.Platform,roots:Roots) {
    for r.operation!=.None {
        arguments:=command(r,roots,r.operation,r.step)
        if arguments==nil {
            r.step+=1
            if r.step>=steps(r) {end(r);return}
            continue
        }
        folder:=base.text_get(r.root[:])
        if folder=="" || r.operation==.Check || r.operation==.Init || r.operation==.Refresh && r.step==0 {folder=roots.project}
        full:=make([dynamic]string,context.temp_allocator)
        append(&full,"git")
        append(&full,..arguments)
        clear(&r.out);clear(&r.err)
        // A fetch nobody asked for never opens a window of the credential manager.
        environment:=[]string{"GIT_TERMINAL_PROMPT=0","LC_ALL=C","GIT_EDITOR=true","GCM_INTERACTIVE=never"}
        if r.operation!=.Fetch {environment=environment[:3]}
        process,error:=platform.process_start(p,{command=full[:],working_directory=folder,environment=environment})
        if error!=.None {
            if r.operation==.Check {r.checked,r.available=true,false;r.operation=.None;return}
            fail(r,p,"Git could not be started")
            return
        }
        r.process=process
        return
    }
}

// The most steps an operation has.
@(private)
STEPS :: 5+build.GIT_SETTINGS

// The step of Init that sets up Git LFS, after the settings of the drivers.
@(private)
INIT_LFS :: 1+build.GIT_SETTINGS

@(private)
steps :: proc(r:^Repository) -> int {return r.operation==.Load?3*len(r.load_paths):STEPS}

// The arguments of a step of an operation, or nil when it has none.
@(private)
command :: proc(r:^Repository,roots:Roots,operation:Operation,step:int) -> []string {
    a:=context.temp_allocator
    scope:=base.text_get(r.prefix[:])
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
            if r.settings_stale&(1<<uint(step-5))==0 {return nil}
            setting:=build.git_settings(roots.engine,base.text_get(r.root[:]),a)[step-5]
            return list("config","--local",setting.key,setting.value)
        }
    case .Init:
        switch step {
        case 0: return list("init","-b","main")
        case 1..<INIT_LFS:
            setting:=build.git_settings(roots.engine,roots.project,a)[step-1]
            return list("config","--local",setting.key,setting.value)
        case INIT_LFS: if r.lfs {return list("lfs","install","--local")}
        case INIT_LFS+1:
            remote:=strings.trim_space(string(r.remote_field[:r.remote_length]))
            if remote!="" {return list("remote","add","origin",strings.clone(remote,a))}
        }
    case .Commit,.Commit_Push:
        // Everything under the project, or only what is not left out: what was
        // saved since the last refresh goes in with the rest.
        paths:=make([dynamic]string,a)
        left_out:=false
        for &change in r.changes {
            if change.left_out {left_out=true} else {append(&paths,strings.clone(base.text_get(change.path[:]),a))}
        }
        if !left_out {clear(&paths);append(&paths,scope)}
        switch step {
        case 0:
            arguments:=make([dynamic]string,a)
            append(&arguments,"add","-A","--")
            append(&arguments,..paths[:])
            return arguments[:]
        case 1:
            arguments:=make([dynamic]string,a)
            append(&arguments,"commit","-m",strings.clone(strings.trim_space(string(r.message[:r.message_length])),a),"--")
            append(&arguments,..paths[:])
            return arguments[:]
        case 2: if operation==.Commit_Push {return push_command(r)}
        }
    case .Push:
        if step==0 {return push_command(r)}
    case .Fetch:
        if step==0 {return list("fetch","--quiet","origin")}
    case .Discard:
        switch step {
        case 0:
            if len(r.discard_paths)==0 {return nil}
            arguments:=make([dynamic]string,a)
            append(&arguments,"restore","--source=HEAD","--staged","--worktree","--")
            append(&arguments,..r.discard_paths[:])
            return arguments[:]
        case 1:
            if len(r.discard_staged)==0 {return nil}
            arguments:=make([dynamic]string,a)
            append(&arguments,"rm","--cached","--quiet","--")
            append(&arguments,..r.discard_staged[:])
            return arguments[:]
        }
    case .Pull:
        if step==0 {return list("pull","--no-rebase","--no-edit")}
    case .Abort:
        if step==0 {return list("merge","--abort")}
    case .Finish:
        switch step {
        case 0:
            arguments:=make([dynamic]string,a)
            append(&arguments,"add","--")
            append(&arguments,..r.finish_paths[:])
            return arguments[:]
        case 1: return list("commit","--no-edit")
        }
    case .Load:
        // Step k is stage k%3+1 (base, ours, theirs) of file k/3.
        if step>=3*len(r.load_paths) {return nil}
        return list("show",fmt.tprintf(":%d:%s",step%3+1,r.load_paths[step/3]))
    }
    return nil
}

@(private)
push_command :: proc(r:^Repository) -> []string {
    arguments:=make([dynamic]string,context.temp_allocator)
    append(&arguments,"push")
    if !r.upstream {append(&arguments,"-u","origin",strings.clone(base.text_get(r.branch[:]),context.temp_allocator))}
    return arguments[:]
}

// Reads what the command that runs wrote. Once it exited, its output is in
// out and err until advance, which the caller owes it.
poll :: proc(r:^Repository,p:^platform.Platform) -> (exited:bool,code:int) {
    if r.operation==.None || r.process==0 {return}
    buffer:[8192]u8
    for stream in platform.Process_Stream {
        into:=stream==.Stdout?&r.out:&r.err
        for _ in 0..<64 {
            count,_:=platform.process_read(p,r.process,stream,buffer[:])
            if count==0 {break}
            if len(into)+count<=OUTPUT_LIMIT {append(into,..buffer[:count])}
        }
    }
    exited,code=platform.process_poll(p,r.process)
    if !exited {return}
    for stream in platform.Process_Stream {
        into:=stream==.Stdout?&r.out:&r.err
        for {
            count,_:=platform.process_read(p,r.process,stream,buffer[:])
            if count==0 {break}
            if len(into)+count<=OUTPUT_LIMIT {append(into,..buffer[:count])}
        }
    }
    platform.process_release(p,r.process)
    r.process=0
    return
}

// After the command of a step exited with code: reads what it left and
// starts the next one, or ends the operation.
advance :: proc(r:^Repository,p:^platform.Platform,roots:Roots,code:int) {
    if !step_done(r,p,roots,code) {return}
    r.step+=1
    if r.step>=steps(r) {end(r);return}
    next(r,p,roots)
}

// Reads what a step left. False when the operation ended here.
@(private)
step_done :: proc(r:^Repository,p:^platform.Platform,roots:Roots,code:int) -> bool {
    out:=string(r.out[:])
    #partial switch r.operation {
    case .Load,.Fetch:
        // A fetch without the network or credentials says nothing: the next one tries again.
        return true
    case .Check:
        r.checked,r.available=true,code==0
        if code!=0 {r.operation=.None;return false}
        // Then what the repository holds.
        r.operation,r.step=.Refresh,-1
        return true
    case .Refresh:
        switch r.step {
        case 0:
            if code!=0 {
                r.repository,r.merging=false,false
                clear(&r.changes);clear(&r.history)
                r.root,r.prefix,r.branch,r.remote={},{},{},{}
                end(r)
                return false
            }
            r.repository=true
            lines:=strings.split_lines(strings.trim_right_space(out),context.temp_allocator)
            base.text_set(r.root[:],len(lines)>0?lines[0]:"")
            base.text_set(r.prefix[:],len(lines)>1?strings.trim_space(lines[1]):"")
        case 1:
            if code!=0 {fail(r,p,"Git could not read the changes of the project");return false}
            status_read(r,out)
        case 2:
            clear(&r.history)
            if code==0 {log_read(r,out)}
        case 3:
            base.text_set(r.remote[:],code==0?strings.trim_space(out):"")
        case 4:
            unset,other:=build.git_settings_state(build.git_settings(roots.engine,base.text_get(r.root[:]),context.temp_allocator),out)
            r.settings_stale=unset|other
        }
        return true
    case .Pull:
        if code!=0 {
            // A merge with conflicts leaves them for whoever resolves them; anything else failed.
            if !strings.contains(out,"CONFLICT") && !strings.contains(string(r.err[:]),"CONFLICT") {
                fail_text(r,string(r.err[:]),"The pull failed")
            }
            r.operation,r.step=.Refresh,-1
            return true
        }
    case:
        if code!=0 && !(r.operation==.Init && r.step==INIT_LFS) {
            message:="Git failed"
            #partial switch r.operation {
            case .Init: message="The repository could not be made"
            case .Commit,.Commit_Push: message="The commit failed"
            case .Push: message="The push failed"
            case .Abort: message="The merge could not be aborted"
            case .Finish: message="The merge could not be finished"
            case .Discard: message="The changes could not be discarded"
            }
            fail_text(r,string(r.err[:]),message)
            r.operation,r.step=.Refresh,-1
            return true
        }
        if (r.operation==.Commit || r.operation==.Commit_Push) && r.step==1 {
            r.message={};r.message_length=0
        }
    }
    return true
}

@(private)
end :: proc(r:^Repository) {
    r.finished,r.finished_failed=r.operation,base.text_get(r.error[:])!=""
    r.operation,r.step=.None,0
}

// The operation that ended since the last call, .None without one, and
// whether it failed: its caller reads the state again, unless it was the reading.
ended :: proc(r:^Repository) -> (operation:Operation,failed:bool) {
    operation,failed=r.finished,r.finished_failed
    r.finished,r.finished_failed=.None,false
    return
}

@(private)
fail :: proc(r:^Repository,p:^platform.Platform,message:string) {
    base.text_set(r.error[:],message)
    r.operation,r.step=.None,0
    if r.process!=0 {platform.process_release(p,r.process);r.process=0}
}

// The first line git wrote that says what went wrong, after what the editor says.
@(private)
fail_text :: proc(r:^Repository,text:string,message:string) {
    detail:=""
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        trimmed:=strings.trim_space(line)
        if trimmed=="" || strings.has_prefix(trimmed,"hint:") {continue}
        detail=strings.trim_prefix(strings.trim_prefix(trimmed,"fatal: "),"error: ")
        break
    }
    if detail=="" {base.text_set(r.error[:],message);return}
    base.text_set(r.error[:],strings.concatenate({message,": ",detail},context.temp_allocator))
}

// git status --porcelain=v2 --branch -z: the branch, how far from its
// upstream, and one entry per file changed, added, removed or in conflict.
status_read :: proc(r:^Repository,out:string) {
    kept:=make(map[string]bool,context.temp_allocator)
    for &change in r.changes {
        if change.left_out {kept[strings.clone(base.text_get(change.path[:]),context.temp_allocator)]=true}
    }
    clear(&r.changes)
    r.branch,r.upstream,r.ahead,r.behind,r.merging={},false,0,0,false
    rest:=out
    for entry in strings.split_iterator(&rest,"\x00") {
        if entry=="" {continue}
        switch entry[0] {
        case '#':
            if strings.has_prefix(entry,"# branch.head ") {base.text_set(r.branch[:],entry[len("# branch.head "):])}
            if strings.has_prefix(entry,"# branch.upstream ") {r.upstream=true}
            if strings.has_prefix(entry,"# branch.ab ") {
                fields:=strings.fields(entry[len("# branch.ab "):],context.temp_allocator)
                if len(fields)==2 {
                    r.ahead,_=strconv.parse_int(strings.trim_prefix(fields[0],"+"))
                    r.behind,_=strconv.parse_int(strings.trim_prefix(fields[1],"-"))
                }
            }
        case '1','2','u','?':
            fields:=strings.split_n(entry," ",entry[0]=='1'?9:entry[0]=='2'?10:entry[0]=='u'?11:2,context.temp_allocator)
            path:=fields[len(fields)-1]
            status:u8='M'
            switch entry[0] {
            case '?': status='A'
            case 'u': status='U';r.merging=true
            case:
                xy:=fields[1]
                if xy[0]=='D' || xy[1]=='D' {status='D'} else if xy[0]=='A' {status='A'}
            }
            if entry[0]=='2' {
                // The original path follows as its own entry.
                _,_=strings.split_iterator(&rest,"\x00")
            }
            change:=Change{status=status,left_out=status!='U' && kept[path]}
            change.tracked=entry[0]!='?' && !(entry[0]=='1' && fields[1][0]=='A')
            change.staged=entry[0]=='1' && fields[1][0]=='A'
            base.text_set(change.path[:],path)
            append(&r.changes,change)
        }
    }
}

// git log --format=%h%x1f%an%x1f%ar%x1f%s: one commit per line.
log_read :: proc(r:^Repository,out:string) {
    rest:=out
    for line in strings.split_lines_iterator(&rest) {
        if len(r.history)>=HISTORY {break}
        parts:=strings.split(line,"\x1f",context.temp_allocator)
        if len(parts)!=4 {continue}
        commit:Commit
        base.text_set(commit.hash[:],parts[0])
        base.text_set(commit.author[:],parts[1])
        base.text_set(commit.age[:],parts[2])
        base.text_set(commit.subject[:],parts[3])
        append(&r.history,commit)
    }
}
