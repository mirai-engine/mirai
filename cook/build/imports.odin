package build

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:project"
import "mirai:std/subprocess"

// Brings the imported folder of each root (a project, a plugin) up to date
// with the sources of its assets folder (cook/import/sources.sync), with the
// import program of the engine (Engine_Paths.import_program, of the defines
// the engine was built with), which reads the formats the plugins of the
// project add from the library of its editor: the tool builds without the
// importers. Textures are built Final for a build that cooks them and Fast,
// as the editor imports them, for one that does not (fast). What the program
// says of each source it imports goes to the output of this process as it
// says it: a large source imports for minutes. message, in the temp
// allocator: why it failed.
imports_sync :: proc(program:string,roots:[]string,fast:bool) -> (ok:bool,message:string) {
    if len(roots)==0 {return true,""}
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,program)
    if fast {append(&command,"--fast")}
    for root in roots {append(&command,"--sync",root)}
    state,_,errors,error:=subprocess.exec({command=command[:]},context.temp_allocator,echo=os.to_writer(os.stdout))
    if error!=nil {return false,fmt.tprintf("the import program could not run: %v",error)}
    if state.exit_code!=0 {return false,strings.trim_space(string(errors))}
    return true,""
}

// The roots of a project whose sources its builds import: the project and
// its active plugins, those with an assets folder. In the temp allocator.
imports_roots :: proc(p:^project.Project) -> []string {
    roots:=make([dynamic]string,context.temp_allocator)
    for folder in project.asset_folders(p,context.temp_allocator) {append(&roots,folder.root)}
    return roots[:]
}
