package main

import "core:fmt"
import "core:os"
import "core:slice"
import "mirai:cook/build"
import "mirai:cook/workspace"
import "mirai:project"

// mirai import: the import runs in the import program of the engine
// (cook/import/sources.command), which the build of the engine makes next to
// the editor and the player: the importers and the prefab they write are
// engine code, and the tool builds without it. The engine is built first
// unless it is current, in the mode of build_mode_take,
// taking its turn only then; what that build says goes to stderr, so stdout holds the report
// of the import alone. The program loads the editor library of the project
// of what it imports (its importers and the types of its game): one built
// from other sources, of the engine or of the project, is built again first,
// as mirai build editor does, and never loaded. The program runs in the
// current folder with the other arguments, and its exit code is the command's.

cmd_import :: proc(root:string,args:[]string) -> int {
    mode,rest:=build_mode_take(args)
    mode=build.engine_mode_resolve(root,mode)
    for folder in import_libraries_stale(root,rest,mode) {
        fmt.eprintfln("mirai import: the editor library of %s was not built from the sources there are now: building it as mirai build editor does",folder)
        self,error:=os.get_executable_path(context.temp_allocator)
        if error!=nil {fmt.eprintfln("mirai import: mirai build editor \"%s\" builds it",folder);return 1}
        command:=make([dynamic]string,context.temp_allocator)
        append(&command,self,"build","editor",folder)
        if mode==.Release {append(&command,"--release")}
        if code:=run_with(root,command[:],os.stderr);code!=0 {return code}
    }
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

// The projects of what the arguments of an import name (the file and the
// roots of --sync, the paths that are there) whose editor library a build in
// mode would compile: missing, or built from other sources. The folders of
// the caches are not imported.
import_libraries_stale :: proc(root:string,args:[]string,mode:Build_Mode) -> []string {
    stale:=make([dynamic]string,context.temp_allocator)
    for i:=0;i<len(args);i+=1 {
        if args[i]=="--texture-cache" || args[i]=="--mesh-cache" {i+=1;continue}
        if !os.exists(args[i]) {continue}
        folder:=project_of(os.is_dir(args[i])?args[i]:os.dir(args[i]))
        if folder=="" || slice.contains(stale[:],folder) {continue}
        p,error:=project.open(folder,root,context.temp_allocator)
        if error.code!=.None {continue}
        if build.target_state(&p,.Editor,"",mode==.Dev,mode)!=.Current {append(&stale,folder)}
    }
    return stale[:]
}
