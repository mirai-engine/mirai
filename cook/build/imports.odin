package build

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:project"
import "mirai:std/subprocess"

// What the imports of a project build that nobody edits is not versioned: a
// build brings it up to date from the sources and their sidecars before it
// compiles or cooks (cook/import/sources.sync). The importers are engine
// code, which the tool builds without: the import program of the engine runs
// them, in a process of its own.

// The roots whose sources a build of the project imports: the project and
// each active plugin with assets.
imports_roots :: proc(p:^project.Project,allocator:=context.allocator) -> []string {
    roots:=make([dynamic]string,allocator)
    append(&roots,strings.clone(p.root,allocator))
    for folder in project.asset_folders(p,allocator) {
        if folder.prefix!="" {append(&roots,folder.root)}
    }
    return roots[:]
}

// Whether a root has the sidecar of an import: what sync has to look at.
imports_any :: proc(roots:[]string) -> bool {
    for root in roots {
        todo:=make([dynamic]string,context.temp_allocator)
        append(&todo,root)
        for next:=0;next<len(todo);next+=1 {
            entries,error:=os.read_all_directory_by_path(todo[next],context.temp_allocator)
            if error!=nil {continue}
            for entry in entries {
                if strings.has_prefix(entry.name,".") {continue}
                if entry.type==.Directory {append(&todo,fmt.tprintf("%s/%s",todo[next],entry.name))}
                else if strings.has_suffix(entry.name,".import") {return true}
            }
        }
    }
    return false
}

// Brings the imported folder of each root up to date with the import program
// of the engine (mirai import --sync). message, in the temp allocator: what it
// did, or why it failed.
imports_sync :: proc(import_program:string,roots:[]string,texture_cache:="",mesh_cache:="") -> (ok:bool,message:string) {
    if !os.is_file(import_program) {
        return false,"the import program of the engine is missing: build the editor once (`mirai build editor`) and build again"
    }
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,import_program)
    for root in roots {append(&command,"--sync",root)}
    if texture_cache!="" {append(&command,"--texture-cache",texture_cache)}
    if mesh_cache!="" {append(&command,"--mesh-cache",mesh_cache)}
    state,output,errors,error:=subprocess.exec({command=command[:]},context.temp_allocator)
    if error!=nil {return false,fmt.tprintf("the import program could not run: %v",error)}
    if state.exit_code!=0 {return false,strings.trim_space(string(errors))}
    return true,strings.trim_space(string(output))
}
