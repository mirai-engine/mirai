package main

import "core:fmt"
import "core:os"
import "mirai:cook/build"
import "mirai:cook/workspace"
import "mirai:project"

UI_USAGE :: "ui read <asset> [--out <file>] | read --sources | write <asset> <document> | write <file|folder>... | check [<asset>...] [--project P]"
TEXTS_USAGE :: "texts list | missing | set <key> <language> <text> | export <file.csv> | import <file.csv> [--project P]"
SCENE_USAGE :: "scene read <asset> [--out <file>] | read --sources | write <asset> <document> | write <file|folder>... | check [<asset>...] [--project P]"

// mirai ui, mirai scene and mirai texts: the documents of the interfaces,
// the scenes and the prefabs of a project and the texts of its .strings,
// read, checked and written with no editor. They
// run in the author program of the engine (cook/author.command), which the
// build of the engine makes next to the editor and the player: the documents
// and the assets they write are engine code, and the tool builds without it.
// The engine is built first unless it is current, as mirai import does; what
// that build says goes to stderr. The project is not built: a command that
// reads the types of its game (all but ui read and texts) refuses, with what builds it,
// a project that was never built or whose code changed since. The project is the one of --project, or the
// one the current folder is in; the program runs in the current folder, so
// the files it is given are named from there, and its exit code is the
// command's.

cmd_ui :: proc(root:string,args:[]string) -> int {return author_run(root,"ui",UI_USAGE,args)}
cmd_scene :: proc(root:string,args:[]string) -> int {return author_run(root,"scene",SCENE_USAGE,args)}
cmd_texts :: proc(root:string,args:[]string) -> int {return author_run(root,"texts",TEXTS_USAGE,args)}

// What the author program takes besides the arguments of the command: the
// project and the engine it belongs to.
author_command :: proc(program,root,owner,kind:string,rest:[]string) -> [dynamic]string {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,program,"--project",owner,"--engine",root,kind)
    append(&command,..rest)
    return command
}

// Takes --project P out of args; ok false when it has no value.
author_project_take :: proc(args:[]string) -> (folder:string,rest:[]string,ok:bool) {
    list:=make([dynamic]string,context.temp_allocator)
    folder="."
    for at:=0;at<len(args);at+=1 {
        if args[at]!="--project" {append(&list,args[at]);continue}
        if at+1>=len(args) {return}
        folder=args[at+1]
        at+=1
    }
    return folder,list[:],true
}

// Whether a command reads the types of the game: all but reading an interface and the texts.
author_needs_library :: proc(kind:string,rest:[]string) -> bool {return kind!="texts" && !(kind=="ui" && rest[0]=="read")}

// What keeps a command from reading the types of the game from the library of
// the editor of the project, with the command that builds it; "" when the
// library is the one its code gives now.
author_library_problem :: proc(state:build.Target_State,owner:string,dev:bool) -> string {
    fix:=fmt.tprintf(`mirai build editor "%s" %s`,owner,dev?"--dev":"--release")
    switch state {
    case .Missing: return fmt.tprintf("the project was never built, and its documents are checked against the types of its game: %s builds its library",fix)
    case .Stale:   return fmt.tprintf("the code of the project changed since its library was built, and its documents are checked against the types of its game: %s builds it again",fix)
    case .Current:
    }
    return ""
}

@(private="file")
author_run :: proc(root,kind,usage:string,args:[]string) -> int {
    mode,without_mode,ok:=build_mode_take(args)
    if !ok {fmt.eprintfln("mirai %s: --dev and --release do not go together; pass one of them",kind);return 2}
    folder,rest,named:=author_project_take(without_mode)
    if !named || len(rest)==0 {
        fmt.eprintfln("Usage: mirai %s",usage)
        return 2
    }
    owner:=project_of(folder)
    if owner=="" {
        fmt.eprintfln("mirai %s: %s is not inside a project (no folder above has %s); pass --project <folder>",kind,folder,project.PROJECT_FILE)
        return 1
    }
    mode=build.engine_mode_resolve(root,mode)
    if !c_libraries_current(root) || !build.engine_current(root,mode) {
        lock:=build_lock(root,kind)
        defer workspace.lock_release(&lock)
        if !ensure_runtime_dependencies(root) {return 1}
        if code:=engine_report(build.engine_build({engine_root=root,mode=mode}),root,os.stderr);code!=0 {return code}
    }
    if author_needs_library(kind,rest) {
        p,error:=project.open(owner,root,context.temp_allocator)
        if error.code!=.None {
            fmt.eprintfln("mirai %s: %s",kind,project.error_text(owner,error,context.temp_allocator))
            return 1
        }
        if problem:=author_library_problem(build.target_state(&p,.Editor,"",mode==.Dev,mode),owner,mode==.Dev);problem!="" {
            fmt.eprintfln("mirai %s %s: %s",kind,rest[0],problem)
            return 1
        }
    }
    here,_:=os.get_working_directory(context.temp_allocator)
    command:=author_command(build.engine_paths(root,mode,context.temp_allocator).author_program,root,owner,kind,rest)
    return run(here,command[:])
}
