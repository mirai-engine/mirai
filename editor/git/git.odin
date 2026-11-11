package git

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:cook/build"
import "mirai:std/base"
import "mirai:std/subprocess"

// Git as child processes, with the git installed. An operation is a list of
// git commands that run one after another without stopping a frame: poll
// follows the command that runs and advance reads what it left and starts
// the next one. What they leave is read back with status and log. The index
// is the base of what the editor wrote: a file is pending while the work tree
// has what the index does not, and keeping it adds it to the index. The kinds
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
    pending:bool,        // the work tree has what the index does not
    kept:bool,           // the index has what the last commit does not: the next commit takes it
    tracked:bool,        // the index has it: discarding puts that back; otherwise the file goes to the trash
}

Commit :: struct {
    hash:[16]u8,
    author:[48]u8,
    age:[32]u8, // how long ago, as git says it
    subject:[128]u8,
}

Operation :: enum u8 {None,Check,Refresh,Init,Commit,Commit_Push,Push,Pull,Abort,Finish,Load,Fetch,Keep,Unkeep,Discard,Base}

// The folders a command needs: that of the engine, for the drivers of the
// assets, and that of the project.
Roots :: struct {engine,project:string}

Repository :: struct {
    checked:bool,    // git answered once whether the project is in a repository, or is not there
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
    process:subprocess.Process,
    out,err:[dynamic]u8,
    error:[512]u8,         // what the last operation that failed said
    finished:Operation,    // the operation that ended and ended has not given yet
    finished_failed:bool,

    // What the commands of an operation take, set before it starts.
    message:[MESSAGE_BYTES]u8,message_length:int, // of Commit
    remote_field:[PATH_BYTES]u8,remote_length:int, // of Init
    lfs:bool,                     // Init sets up Git LFS for heavy binaries
    finish_paths:[dynamic]string, // the files a merge resolved, for Finish
    paths:[dynamic]string,        // what Keep adds to the index, Unkeep takes out of it and Discard puts back from it; none: everything under the project
    load_paths:[dynamic]string,   // the files in conflict whose three stages Load reads, one per step
    base_path:[PATH_BYTES]u8,     // the file whose kept version Base reads into out, from the root of the repository
    base_found:bool,              // the index has that file
}

// Whether an operation runs now.
busy :: proc(r:^Repository) -> bool {return r.operation!=.None}

// An operation that changes something runs: a read gives way to whatever the
// user asks, and runs again after it.
working :: proc(r:^Repository) -> bool {return r.operation!=.None && r.operation!=.Check && r.operation!=.Refresh && r.operation!=.Load && r.operation!=.Fetch && r.operation!=.Base}

// The path of a change from the folder of the project.
change_path :: proc(r:^Repository,change:^Change) -> string {
    return strings.trim_prefix(base.text_get(change.path[:]),base.text_get(r.prefix[:]))
}

push :: proc(r:^Repository,roots:Roots) -> string {
    if working(r) {return "Wait for git to finish"}
    if base.text_get(r.remote[:])=="" {return "The repository has no remote to push to"}
    start(r,roots,.Push)
    return ""
}

// Leaves the merge: the files go back to the commit before the pull.
abort :: proc(r:^Repository,roots:Roots) -> string {
    if working(r) {return "Wait for git to finish"}
    if !r.merging {return "No merge to abort"}
    start(r,roots,.Abort)
    return ""
}

start :: proc(r:^Repository,roots:Roots,operation:Operation) {
    subprocess.release(&r.process)
    r.operation,r.step=operation,0
    r.error={}
    next(r,roots)
}

// Starts the command of the step the operation is at, skipping steps without
// one; with none left, the operation ends.
@(private)
next :: proc(r:^Repository,roots:Roots) {
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
        settings:=[]string{"GIT_TERMINAL_PROMPT=0","LC_ALL=C","GIT_EDITOR=true","GCM_INTERACTIVE=never"}
        if r.operation!=.Fetch {settings=settings[:3]}
        inherited,_:=os.environ(context.temp_allocator)
        environment:=slice.concatenate([][]string{inherited,settings},context.temp_allocator)
        process,error:=subprocess.start({command=full[:],working_dir=folder,env=environment},pipes=.Separate)
        if error!=nil {
            if r.operation==.Check {r.checked,r.available=true,false;r.operation=.None;return}
            fail(r,"Git could not be started")
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
        case 1: return status_command(scope)
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
        // What the project holds is the base: nothing of it is pending.
        case INIT_LFS+2: return list("add","-A","--",".")
        }
    case .Commit,.Commit_Push:
        switch step {
        case 0:
            // What is kept, or everything under the project when nothing is.
            for &change in r.changes {if change.kept {return nil}}
            return list("add","-A","--",scope)
        case 1: return list("commit","-m",strings.clone(strings.trim_space(string(r.message[:r.message_length])),a))
        case 2: if operation==.Commit_Push {return push_command(r)}
        }
    case .Keep,.Unkeep,.Discard:
        // The changes are read first: the command names those of its paths it applies to.
        switch step {
        case 0: return status_command(scope)
        case 1:
            arguments:=make([dynamic]string,a)
            #partial switch operation {
            case .Keep:    append(&arguments,"add","-A","--")
            case .Unkeep:  append(&arguments,"reset","--quiet","--")
            case .Discard: append(&arguments,"restore","--worktree","--")
            }
            named:=len(arguments)
            for &change in r.changes {
                if takes(r,&change) && (operation!=.Discard || change.tracked) {append(&arguments,strings.clone(base.text_get(change.path[:]),a))}
            }
            if len(arguments)>named {return arguments[:]}
        }
    case .Push:
        if step==0 {return push_command(r)}
    case .Fetch:
        if step==0 {return list("fetch","--quiet","origin")}
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
    case .Base:
        if step==0 {return list("show",fmt.tprintf(":%s",base.text_get(r.base_path[:])))}
    case .Load:
        // Step k is stage k%3+1 (base, ours, theirs) of file k/3.
        if step>=3*len(r.load_paths) {return nil}
        return list("show",fmt.tprintf(":%d:%s",step%3+1,r.load_paths[step/3]))
    }
    return nil
}

@(private)
status_command :: proc(scope:string) -> []string {
    out:=make([]string,7,context.temp_allocator)
    out[0],out[1],out[2],out[3],out[4],out[5],out[6]="status","--porcelain=v2","--branch","-z","--untracked-files=all","--",scope
    return out
}

// Whether the operation that runs applies to a change: one of its paths, or
// with none any under the project, that Keep and Discard find pending and
// Unkeep kept. A file in conflict is the merge's.
takes :: proc(r:^Repository,change:^Change) -> bool {
    if change.status=='U' || !(r.operation==.Unkeep?change.kept:change.pending) {return false}
    if len(r.paths)==0 {return true}
    path:=base.text_get(change.path[:])
    for wanted in r.paths {if wanted==path {return true}}
    return false
}

// Starts reading into out what the index holds of a file, by its path from
// the root of the repository: ended gives Base, and base_found whether the
// index has it.
start_base :: proc(r:^Repository,roots:Roots,path:string) {
    base.text_set(r.base_path[:],path)
    r.base_found=false
    start(r,roots,.Base)
}

// Starts Keep, Unkeep or Discard of some paths from the root of the
// repository, or of everything under the project with none.
start_paths :: proc(r:^Repository,roots:Roots,operation:Operation,paths:[]string) {
    for path in r.paths {delete(path)}
    clear(&r.paths)
    for path in paths {append(&r.paths,strings.clone(path))}
    start(r,roots,operation)
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
poll :: proc(r:^Repository) -> (exited:bool,code:int) {
    if r.operation==.None || r.process.pid==0 {return}
    buffer:[8192]u8
    for stream in subprocess.Stream {
        into:=stream==.Stdout?&r.out:&r.err
        for _ in 0..<64 {
            count,_:=subprocess.read(&r.process,stream,buffer[:])
            if count==0 {break}
            if len(into)+count<=OUTPUT_LIMIT {append(into,..buffer[:count])}
        }
    }
    state,_:=subprocess.wait(&r.process,0)
    if !state.exited {return}
    for stream in subprocess.Stream {
        into:=stream==.Stdout?&r.out:&r.err
        for {
            count,_:=subprocess.read(&r.process,stream,buffer[:])
            if count==0 {break}
            if len(into)+count<=OUTPUT_LIMIT {append(into,..buffer[:count])}
        }
    }
    subprocess.release(&r.process)
    return true,state.exit_code
}

// After the command of a step exited with code: reads what it left and
// starts the next one, or ends the operation.
advance :: proc(r:^Repository,roots:Roots,code:int) {
    if !step_done(r,roots,code) {return}
    r.step+=1
    if r.step>=steps(r) {end(r);return}
    next(r,roots)
}

// Reads what a step left. False when the operation ended here.
@(private)
step_done :: proc(r:^Repository,roots:Roots,code:int) -> bool {
    out:=string(r.out[:])
    #partial switch r.operation {
    case .Load,.Fetch:
        // A fetch without the network or credentials says nothing: the next one tries again.
        return true
    case .Base:
        r.base_found=code==0 && len(r.out)<OUTPUT_LIMIT-8192
        return true
    case .Check:
        r.available=code==0
        if code!=0 {r.checked=true;r.operation=.None;return false}
        // Then what the repository holds.
        r.operation,r.step=.Refresh,-1
        return true
    case .Refresh:
        switch r.step {
        case 0:
            r.checked=true
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
            if code!=0 {fail(r,"Git could not read the changes of the project");return false}
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
    case .Keep,.Unkeep,.Discard:
        if r.step==0 {
            if code!=0 {fail(r,"Git could not read the changes of the project");return false}
            status_read(r,out)
            return true
        }
        if code!=0 {
            fail_text(r,string(r.err[:]),r.operation==.Keep?"The changes could not be kept":r.operation==.Unkeep?"The changes could not be taken out of what is kept":"The changes could not be discarded")
            r.operation,r.step=.Refresh,-1
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
fail :: proc(r:^Repository,message:string) {
    base.text_set(r.error[:],message)
    r.operation,r.step=.None,0
    subprocess.release(&r.process)
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
// upstream, and one entry per file changed, added, removed or in conflict,
// with which side of the index holds the change.
status_read :: proc(r:^Repository,out:string) {
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
            change:=Change{status=status,tracked=entry[0]!='?',pending=entry[0]=='?'}
            if entry[0]=='1' || entry[0]=='2' {change.kept,change.pending=fields[1][0]!='.',fields[1][1]!='.'}
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
