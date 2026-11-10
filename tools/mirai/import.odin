package main

import "core:fmt"
import "core:os"
import "mirai:cook/build"
import "mirai:cook/workspace"
import "mirai:project"

// mirai import: the import runs in the import program of the engine
// (cook/import/sources.command), which the build of the engine makes next to
// the editor and the player: the importers and the prefab they write are
// engine code, and the tool builds without it. The engine is built first
// unless it is current, in the mode of --dev or --release (the one built last
// otherwise), taking its turn only then; what that build says goes to stderr, so stdout holds the report
// of the import alone. The program runs in the current folder with the other
// arguments, and its exit code is the command's. --project <folder> imports
// every source of a project and of its active plugins whose outputs are
// missing or stale (cook/import/sources.sync).

cmd_import :: proc(root:string,args:[]string) -> int {
    mode,rest,ok:=build_mode_take(args)
    if !ok {fmt.eprintln("mirai import: --dev and --release do not go together; pass one of them");return 2}
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
    for at:=0;at<len(rest);at+=1 {
        if rest[at]!="--project" {
            append(&command,rest[at])
            continue
        }
        // Every source of the project and of its active plugins: a root each.
        at+=1
        if at>=len(rest) {fmt.eprintln("mirai import: --project needs the folder of a project");return 2}
        p,error:=project.open(rest[at],root,context.temp_allocator)
        if error.code!=.None {
            fmt.eprintfln("mirai import: %s",project_error_text(rest[at],error))
            return 1
        }
        for folder in build.imports_roots(&p,context.temp_allocator) {append(&command,"--sync",folder)}
    }
    return run(here,command[:])
}
