package host

import "core:fmt"
import "core:os"
import "mirai:project"

// mirai-player [--project <folder>] [options]: plays the game of the library
// of a project built against the binaries of the engine (mirai play), the one
// an editor loads, whose settings of the machine it reads. Its World_Info
// makes the game World: editor packages declare nothing of the World and no
// step of the game loop.
launch :: proc(args:[]string) -> int {
    root:=project_argument(args)
    path:=project.project_library(root,"editor")
    library,error:=project_library_load(path,0)
    if error!=.None {
        fmt.eprintfln("mirai: %s",library_error_text(error,path))
        return PLAYER_USAGE
    }
    defer project_library_unload(&library)
    return player_run(&library.info,root,project.engine_root_find("",context.temp_allocator),args)
}

// The folder of the project the arguments name with --project; the working
// folder otherwise. Absolute: once told where the libraries a library links
// are, Windows no longer looks for a relative one in the working folder.
project_argument :: proc(args:[]string) -> string {
    for arg,i in args {
        if arg=="--project" && i+1<len(args) {return project.path_absolute(args[i+1])}
    }
    folder,_:=os.get_working_directory(context.allocator)
    return folder
}
