package main

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:project"

// mirai session sync <copy> <path>...: brings the files named from the
// project into a copy that session start --copy made, and only those, so a
// file another session is editing in the project does not reach the copy. A
// path is relative to the project, with forward slashes; one gone from the
// project is deleted from the copy. When code or the manifest changed the
// session of the copy is restarted (built and opened again with its
// arguments); assets its editor reads again by itself at its next call.
// --no-build copies and does not restart it.

// What a sync copies, deletes and then does.
Session_Sync :: struct {
    copy,delete:[dynamic]string, // relative paths, in the temp allocator
    rebuild:bool,                // something other than assets changed
}

// The plan of a sync from the project at folder into the copy; problem says
// which path is refused and why.
session_sync_plan :: proc(folder,copy:string,paths:[]string) -> (plan:Session_Sync,problem:string) {
    plan.copy=make([dynamic]string,context.temp_allocator)
    plan.delete=make([dynamic]string,context.temp_allocator)
    assets_folder:=project.FOLDER_NAMES[.Assets]
    for given in paths {
        relative,_:=strings.replace_all(given,"\\","/",context.temp_allocator)
        relative=strings.trim_prefix(relative,"./")
        switch {
        case relative=="" || strings.has_prefix(relative,"/") || len(relative)>1 && relative[1]==':':
            return {},fmt.tprintf("%s: name the file by its path relative to the project",given)
        case relative==".." || strings.has_prefix(relative,"../") || strings.contains(relative,"/../") || strings.has_suffix(relative,"/.."):
            return {},fmt.tprintf("%s: the path leaves the project",given)
        case session_copy_skips(relative):
            return {},fmt.tprintf("%s: a copy does not take it (git history, locks and what the editor generates)",given)
        }
        source:=project.path(folder,relative,allocator=context.temp_allocator)
        if os.is_dir(source) {return {},fmt.tprintf("%s is a folder: name its files",given)}
        if os.is_file(source) {append(&plan.copy,relative)} else if os.is_file(project.path(copy,relative,allocator=context.temp_allocator)) {append(&plan.delete,relative)} else {
            return {},fmt.tprintf("%s is neither in the project nor in the copy",given)
        }
        if inside,_,rest:=strings.partition(relative,"/");inside!=assets_folder || rest=="" {plan.rebuild=true}
    }
    if len(paths)==0 {return {},"name the files to bring into the copy"}
    return plan,""
}

// Copies and deletes what the plan says; problem says what failed.
session_sync_apply :: proc(folder,copy:string,plan:Session_Sync) -> (problem:string) {
    for relative in plan.copy {
        to:=project.path(copy,relative,allocator=context.temp_allocator)
        if error:=os.make_directory_all(os.dir(to));error!=nil && error!=.Exist {return fmt.tprintf("could not create the folder of %s (%v)",to,error)}
        _=os.remove(to)
        if error:=os.copy_file(to,project.path(folder,relative,allocator=context.temp_allocator));error!=nil {return fmt.tprintf("could not copy %s (%v)",relative,error)}
    }
    for relative in plan.delete {
        if error:=os.remove(project.path(copy,relative,allocator=context.temp_allocator));error!=nil {return fmt.tprintf("could not delete %s from the copy (%v)",relative,error)}
    }
    return ""
}

session_sync :: proc(root,copy:string,args:[]string) -> int {
    no_build:=false
    paths:=make([dynamic]string,context.temp_allocator)
    for arg in args {
        switch {
        case arg=="--no-build": no_build=true
        case strings.has_prefix(arg,"--"): fmt.eprintfln("mirai session sync: %s is not an option of sync. Usage: mirai session sync <copy> <path>... [--no-build]",arg);return 2
        case: append(&paths,arg)
        }
    }
    if !session_copied(copy) {
        fmt.eprintfln("mirai session sync: %s is not a copy that mirai session start --copy made; pass the folder it printed",copy)
        return 2
    }
    // <project>/.mirai/tmp/session-copy-*
    folder:=os.dir(os.dir(os.dir(copy)))
    plan,problem:=session_sync_plan(folder,copy,paths[:])
    if problem!="" {fmt.eprintfln("mirai session sync: %s",problem);return 2}
    if problem=session_sync_apply(folder,copy,plan);problem!="" {fmt.eprintfln("mirai session sync: %s",problem);return 1}
    fmt.printfln("Copied %d and deleted %d files into %s.",len(plan.copy),len(plan.delete),copy)
    if !no_build && plan.rebuild {return cmd_session(root,{"restart",copy})}
    return 0
}
