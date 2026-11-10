package build

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:project"
import "mirai:std/subprocess"

// Brings the imported folder of each root (a project, a plugin) up to date
// with the sources of its source folder (cook/import/sources.sync), with the
// import program of the engine at engine_root, which is built first when it
// is not current: the tool builds without the importers. message, in the temp allocator: what it did, or
// why it failed.
imports_sync :: proc(engine_root:string,mode:Engine_Mode,roots:[]string) -> (ok:bool,message:string) {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,engine_paths(engine_root,mode,context.temp_allocator).import_program)
    for root in roots {append(&command,"--sync",root)}
    if len(roots)==0 {return true,""}
    if !engine_current(engine_root,mode) {
        if built:=engine_build({engine_root=engine_root,mode=mode});built.status==.Failed {
            return false,fmt.tprintf("the engine, whose import program imports the sources, did not build: %s %s",built.step,built.text)
        }
    }
    state,output,errors,error:=subprocess.exec({command=command[:]},context.temp_allocator)
    if error!=nil {return false,fmt.tprintf("the import program could not run: %v",error)}
    if state.exit_code!=0 {return false,strings.trim_space(string(errors))}
    return true,strings.trim_space(string(output))
}

// The roots of a project whose sources its builds import: the project and
// its active plugins with assets, those with a source folder. In the temp allocator.
imports_roots :: proc(p:^project.Project) -> []string {
    roots:=make([dynamic]string,context.temp_allocator)
    append(&roots,p.root)
    for folder in project.asset_folders(p,context.temp_allocator) {
        if folder.prefix!="" {append(&roots,folder.root)}
    }
    kept:=0
    for root in roots {
        if os.is_dir(project.folder_path(root,.Source,context.temp_allocator)) {roots[kept]=root;kept+=1}
    }
    return roots[:kept]
}
