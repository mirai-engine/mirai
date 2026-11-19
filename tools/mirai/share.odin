package main

import "core:os"
import "mirai:cook/build"
import "mirai:cook/workspace"

// mirai share and mirai join run in the import program of the engine
// (cook/share.command), as mirai import does: a join refreshes the packages of
// the project with the importers of the engine. The engine is built first
// unless it is current; the program runs in the current folder with the other
// arguments, and its exit code is the command's.

SHARE_USAGE :: "share [project] [--port N] [--store <folder>]"
JOIN_USAGE :: "join <invitation> [folder] [--address <ip:port>] [--port N] [--store <folder>]"

cmd_share :: proc(root:string,args:[]string) -> int {return share_run(root,"share",args)}
cmd_join :: proc(root:string,args:[]string) -> int {return share_run(root,"join",args)}

share_run :: proc(root,verb:string,args:[]string) -> int {
    mode,rest:=build_mode_take(args)
    mode=build.engine_mode_resolve(root,mode)
    if !c_libraries_current(root) || !build.engine_current(root,mode) {
        lock:=build_lock(root,verb)
        defer workspace.lock_release(&lock)
        if !ensure_runtime_dependencies(root) {return 1}
        if code:=engine_report(build.engine_build({engine_root=root,mode=mode}),root,os.stderr);code!=0 {return code}
    }
    here,_:=os.get_working_directory(context.temp_allocator)
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,build.engine_paths(root,mode,context.temp_allocator).import_program,verb)
    append(&command,..rest)
    return run(here,command[:])
}
