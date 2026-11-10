package build

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:project"
import "mirai:std/subprocess"

// Brings the imported folder of each root (a project, a plugin) up to date
// with the sources of its source folder (cook/import/sources.sync), with the
// import program of the engine: the tool builds without the importers. A root
// without sources asks nothing of the program. message, in the temp
// allocator: what it did, or why it failed.
imports_sync :: proc(import_program:string,roots:[]string) -> (ok:bool,message:string) {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,import_program)
    for root in roots {
        if os.is_dir(project.folder_path(root,.Source,context.temp_allocator)) {append(&command,"--sync",root)}
    }
    if len(command)==1 {return true,""}
    if !os.is_file(import_program) {
        return false,"the import program of the engine is missing: build the editor once (`mirai build editor`) and build again"
    }
    state,output,errors,error:=subprocess.exec({command=command[:]},context.temp_allocator)
    if error!=nil {return false,fmt.tprintf("the import program could not run: %v",error)}
    if state.exit_code!=0 {return false,strings.trim_space(string(errors))}
    return true,strings.trim_space(string(output))
}
