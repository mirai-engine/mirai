package main

import "core:fmt"
import "core:os"
import "mirai:cook/build"
import "mirai:cook/workspace"

// mirai import: the import runs in the import program of the engine
// (cook/import/sources.command), which the build of the engine makes next to
// the editor and the player: the importers and the prefab they write are
// engine code, and the tool builds without it. The engine is built first
// unless it is current, in the mode of build_mode_take,
// taking its turn only then; what that build says goes to stderr, so stdout holds the report
// of the import alone. The program runs in the current folder with the other
// arguments, and its exit code is the command's.

cmd_import :: proc(root:string,args:[]string) -> int {
    mode,rest:=build_mode_take(args)
    mode=build.engine_mode_resolve(root,mode)
    if !c_libraries_current(root) || !build.engine_current(root,mode) {
        lock:=build_lock(root,"import")
        defer workspace.lock_release(&lock)
        if !ensure_runtime_dependencies(root) {return 1}
        if code:=engine_report(build.engine_build({engine_root=root,mode=mode}),root,os.stderr);code!=0 {return code}
    }
    here,_:=os.get_working_directory(context.temp_allocator)
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,build.engine_paths(root,mode,context.temp_allocator).import_program)
    append(&command,..rest)
    return run(here,command[:])
}
