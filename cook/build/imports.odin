package build

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:asset"
import "mirai:project"
import "mirai:std/subprocess"

// Brings the packages each root (a project, a plugin) pins in its
// packages.mirai to builds this engine reads (cook/import/sources.project_refresh)
// in the store at store_root ("": the machine's), with the import program of
// the engine (Engine_Paths.import_program, of the defines the engine was
// built with), which reads the formats the plugins of the project add from
// the library of its editor: the tool builds without the importers. A build
// is taken from the store, then from the store at from ("": none; an
// installed engine adds the store of the builds of its plugins), then built
// from its source when the source is on this machine; a package none of them
// gives fails by name. Textures are required Final for a build that cooks
// them and taken Fast, as the editor imports them, for one that does not
// (fast). What the program says of each source it imports goes to the output
// of this process as it says it: a large source imports for minutes.
// message, in the temp allocator: why it failed.
imports_refresh :: proc(program:string,roots:[]string,fast:bool,store_root:string,from:="") -> (ok:bool,message:string) {
    if len(roots)==0 {return true,""}
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,program)
    if fast {append(&command,"--fast")}
    if store_root!="" {append(&command,"--store",store_root)}
    if from!="" {append(&command,"--from",from)}
    for root in roots {append(&command,"--refresh",root)}
    state,_,errors,error:=subprocess.exec({command=command[:]},context.temp_allocator,echo=os.to_writer(os.stdout))
    if error!=nil {return false,fmt.tprintf("the import program could not run: %v",error)}
    if state.exit_code!=0 {return false,strings.trim_space(string(errors))}
    return true,""
}

// The roots of a project whose packages its builds refresh: the project and
// its active plugins, those with a packages.mirai. In the temp allocator.
imports_roots :: proc(p:^project.Project) -> []string {
    roots:=make([dynamic]string,context.temp_allocator)
    for folder in project.asset_folders(p,context.temp_allocator) {
        if os.is_file(project.path(folder.root,asset.PACKAGES_FILE,allocator=context.temp_allocator)) {append(&roots,folder.root)}
    }
    return roots[:]
}
