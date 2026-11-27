package build

import "core:os"
import "core:strings"
import "mirai:project"
import "mirai:std/base"

// Whether a copy of a project takes a path of its generated folder (relative
// to it, with forward slashes) as what a build of the project left: the
// generated world, the work of the builds (what each compile read, its stamp
// and its objects), the plugin libraries with their stages and stamps, and the
// library of every target but the game. The build of the copy checks them as
// a build checks its own, the paths of a project counting relative to it
// (fingerprint), so it keeps what its sources still give and builds the rest.
// Locks are never taken.
build_state_kept :: proc(relative:string) -> bool {
    if strings.has_suffix(relative,".lock") || strings.has_suffix(relative,".owner") {return false}
    first,_,_:=strings.partition(relative,"/")
    switch first {
    case "build","gen","plugins": return true
    }
    names:=TARGET_NAMES
    for name,target in names {
        if target!=.Game && relative==project.library_file(name,context.temp_allocator) {return true}
    }
    return false
}

// Writes the project at source as its copy at copy in the build state
// build_state_kept took into copy: what each compile read, the stamps and the
// commands of the links name files by their whole path. False when a file
// could not be read or written again.
build_state_rebase :: proc(source,copy:string) -> bool {
    from,to:=slashes(source,context.temp_allocator),slashes(copy,context.temp_allocator)
    if from==to {return true}
    generated:=project.folder_path(copy,.Generated,context.temp_allocator)
    for folder in ([]string{"build","plugins"}) {
        root:=project.path(generated,folder,allocator=context.temp_allocator)
        if !os.is_dir(root) {continue}
        walker:=os.walker_create(root)
        defer os.walker_destroy(&walker)
        for info in os.walker_walk(&walker) {
            if info.type!=.Regular || !(strings.has_suffix(info.name,".json") || strings.has_suffix(info.name,".stamp") || strings.has_suffix(info.name,".link")) {continue}
            data,error:=os.read_entire_file(info.fullpath,context.temp_allocator)
            if error!=nil {return false}
            text,changed:=strings.replace_all(string(data),from,to,context.temp_allocator)
            when ODIN_OS==.Windows {
                // A record of the compiler names them with escaped backslashes.
                escaped:=[2]string{}
                escaped[0],_=strings.replace_all(from,"/",`\\`,context.temp_allocator)
                escaped[1],_=strings.replace_all(to,"/",`\\`,context.temp_allocator)
                more:bool
                text,more=strings.replace_all(text,escaped[0],escaped[1],context.temp_allocator)
                changed||=more
            }
            if changed && os.write_entire_file(info.fullpath,text)!=nil {return false}
        }
        if _,error:=os.walker_error(&walker);error!=nil {return false}
    }
    return true
}

// What of a project's generated folder a build, a refresh of its assets and
// its shaders make again: the folders cache_clean removes, beside the
// libraries of every target but the game. Its Kai workspace (kai), its locks
// and what an editor keeps for a person (chats, thumbnails, the session) are
// not among them.
CACHE_FOLDERS :: [?]string{"build","gen","plugins","shaders","shader-cache","cache"}

// Removes what a build of the project at root left (CACHE_FOLDERS and the
// libraries), so its next opening makes them all again: how many it removed,
// or the error of the first that could not be removed.
cache_clean :: proc(root:string) -> (removed:int,error:os.Error) {
    generated:=project.folder_path(root,.Generated,context.temp_allocator)
    entries:=make([dynamic]string,context.temp_allocator)
    for folder in CACHE_FOLDERS {append(&entries,folder)}
    names:=TARGET_NAMES
    for name,target in names {
        if target!=.Game {append(&entries,project.library_file(name,context.temp_allocator))}
    }
    for entry in entries {
        path:=project.path(generated,entry,allocator=context.temp_allocator)
        if !os.exists(path) {continue}
        base.remove_all(path) or_return
        removed+=1
    }
    return
}
