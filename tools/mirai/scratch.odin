package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/base"

// <folder>/.mirai/tmp is scratch, of the engine and of whoever works in the
// folder. What a command makes there for its own run it removes when it
// ends: a session copy when its session stops, the scenes render check edits
// (render-<pid>) when its editor closes, the project a package take refreshes
// and the temporary files of a join. What outlives its command, and what a
// command that was killed left, goes with scratch_sweep, which mirai test
// runs for the engine and the commands that make session copies for their
// project:
//
//   a session copy   once no session start holds it and no editor of it runs
//   anything else    once no lock in it is held (a .lock file at its top or
//                    in its .mirai/, or <name>.lock beside a file) and
//                    nothing in it changed for SCRATCH_AGE
//
// What must stay longer belongs elsewhere: bin/, or a folder of the project.
SCRATCH_AGE :: 3*24*time.Hour

// <folder>/.mirai/tmp/<SCRATCH_LOCK>: held while a session copy is made and
// its lock taken, and while the scratch is swept, so that a sweep never sees
// a copy before its lock.
SCRATCH_LOCK :: "sweep.lock"

scratch_folder :: proc(folder:string) -> string {
    return project.path(folder,".mirai","tmp",allocator=context.temp_allocator)
}

// Removes the entries of the scratch of folder that its rules give up at
// now. kept: those that could not be removed while a process holds their
// files. Nothing when another sweep runs.
scratch_sweep :: proc(folder:string,now:=time.Time{}) -> (swept,kept:int) {
    now:=now
    if now=={} {now=time.now()}
    temporary:=scratch_folder(folder)
    if !os.is_dir(temporary) {return}
    sweep,taken,_,_:=workspace.lock_take(project.path(temporary,SCRATCH_LOCK,allocator=context.temp_allocator),fmt.tprintf("pid %d, mirai sweeping scratch",os.get_pid()))
    if !taken {return}
    defer workspace.lock_release(&sweep)
    entries,error:=os.read_directory_by_path(temporary,-1,context.temp_allocator)
    if error!=nil {return}
    for entry in entries {
        if strings.has_prefix(entry.name,SCRATCH_LOCK) {continue}
        path:=project.path_absolute(entry.fullpath)
        if entry.type==.Directory && strings.has_prefix(entry.name,SESSION_COPY_PREFIX) {
            if session_copy_live(path) {continue}
        } else if scratch_held(path,entry.type==.Directory) || scratch_changed_since(path,time.time_add(now,-SCRATCH_AGE)) {
            continue
        }
        if base.remove_all(path)!=nil {kept+=1;continue}
        swept+=1
    }
    return
}

// Says what scratch_sweep removed of folder, for command.
scratch_sweep_say :: proc(folder,command:string) {
    swept,kept:=scratch_sweep(folder)
    if swept==0 && kept==0 {return}
    fmt.eprintfln("mirai %s: deleted %d entries of %s that no process holds and that its rules give up%s",command,swept,scratch_folder(folder),kept>0?fmt.tprintf("; %d could not be deleted while a process holds their files",kept):"")
}

// Whether a lock that keeps an entry is held: in a folder, a .lock file at
// its top or in its .mirai/; beside a file, <name>.lock; a lock itself, and
// the owner file of one.
@(private="file")
scratch_held :: proc(path:string,folder:bool) -> bool {
    held :: proc(lock:string) -> bool {return os.is_file(lock) && !workspace.lock_wait(lock,limit=1)}
    if !folder {
        if lock,owner:=strings.has_suffix(path,".lock"),strings.has_suffix(path,".lock.owner");lock || owner {
            return held(owner?path[:len(path)-len(".owner")]:path)
        }
        return held(strings.concatenate({path,".lock"},context.temp_allocator))
    }
    for inside in ([2]string{path,project.path(path,".mirai",allocator=context.temp_allocator)}) {
        entries,error:=os.read_directory_by_path(inside,-1,context.temp_allocator)
        if error!=nil {continue}
        for entry in entries {
            if entry.type!=.Directory && strings.has_suffix(entry.name,".lock") && held(entry.fullpath) {return true}
        }
    }
    return false
}

// Whether path, or anything under it, changed after since; one that cannot
// be read did.
@(private="file")
scratch_changed_since :: proc(path:string,since:time.Time) -> bool {
    info,error:=os.lstat(path,context.temp_allocator)
    if error!=nil || time.diff(since,info.modification_time)>=0 {return true}
    if info.type!=.Directory {return false}
    walker:=os.walker_create(path)
    defer os.walker_destroy(&walker)
    for inner in os.walker_walk(&walker) {
        if time.diff(since,inner.modification_time)>=0 {return true}
    }
    _,walk_error:=os.walker_error(&walker)
    return walk_error!=nil
}
