package host

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:core"
import "mirai:project"

// A library of a project loaded from a copy of its own, so that the build
// that made it can replace the file while it is loaded and a newer one can be
// loaded beside it. A copy stays loaded until the program ends: what its
// world holds (names, procedures) points into it.
Project_Library :: struct {
    handle:dynlib.Library,
    copy:string,          // the file that is loaded
    info:core.World_Info,
}

// The procedure every library of a project exports (cook/build generates it).
PROJECT_INFO_SYMBOL :: "mirai_project_info"

Library_Error :: enum u8 {None,Missing,Copy_Failed,Load_Failed,Not_A_Project,Out_Of_Memory}

// Loads the library at path as its generation-th copy of this process.
project_library_load :: proc(path:string,generation:int,allocator:=context.allocator) -> (library:Project_Library,error:Library_Error) {
    if !os.is_file(path) {return {},.Missing}
    copy:=library_copy_name(path,generation,allocator)
    if copy=="" {return {},.Out_Of_Memory}
    _=os.remove(copy)
    if os.copy_file(copy,path)!=nil {
        delete(copy,allocator)
        return {},.Copy_Failed
    }
    // The libraries of the engine's plugins the library links sit in a folder beside it.
    library_dependencies_where(project.path(path[:max(strings.last_index_byte(path,'/'),0)],project.PLUGIN_LIBRARIES,allocator=context.temp_allocator))
    handle,loaded:=dynlib.load_library(copy)
    if !loaded {
        _=os.remove(copy)
        delete(copy,allocator)
        return {},.Load_Failed
    }
    address,found:=dynlib.symbol_address(handle,PROJECT_INFO_SYMBOL)
    if !found {
        _=dynlib.unload_library(handle)
        _=os.remove(copy)
        delete(copy,allocator)
        return {},.Not_A_Project
    }
    info_proc:=cast(proc() -> core.World_Info)address
    return {handle=handle,copy=copy,info=info_proc()},.None
}

// Unloads a copy and removes its file. Only when nothing of its world is left.
project_library_unload :: proc(library:^Project_Library,allocator:=context.allocator) {
    if library.handle!=nil {_=dynlib.unload_library(library.handle)}
    if library.copy!="" {
        _=os.remove(library.copy)
        delete(library.copy,allocator)
    }
    library^={}
}

// Why a library of the project could not be loaded, in words.
library_error_text :: proc(error:Library_Error,path:string) -> string {
    switch error {
    case .None:          return ""
    case .Missing:       return fmt.tprintf("%s does not exist: build the project first",path)
    case .Copy_Failed:   return fmt.tprintf("%s could not be copied to be loaded",path)
    case .Load_Failed:   return fmt.tprintf("%s could not be loaded: %s",path,dynlib.last_error())
    case .Not_A_Project: return fmt.tprintf("%s exports no %s: it is not a library of a project",path,PROJECT_INFO_SYMBOL)
    case .Out_Of_Memory: return fmt.tprintf("there is no memory to load %s: free memory and try again",path)
    }
    return ""
}

// <folder>/<name>-live-<pid>-<generation><ext>. Copies a process that ended
// badly left behind are removed first. "" without memory for it.
@(private="file")
library_copy_name :: proc(path:string,generation:int,allocator:=context.allocator) -> string {
    folder:=filepath.dir(path)
    file:=filepath.base(path)
    extension:=filepath.ext(file)
    stem:=strings.trim_suffix(file,extension)
    if generation==0 {
        prefix:=fmt.tprintf("%s-live-",stem)
        entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
        // The copy of another process that runs is in use: several players of
        // a project start at once (a server and its clients), and so do editors.
        alive,_:=os.process_list(context.temp_allocator)
        for entry in entries {
            if !strings.has_prefix(entry.name,prefix) {continue}
            owner,_,_:=strings.partition(entry.name[len(prefix):],"-")
            if pid,numeric:=strconv.parse_int(owner,10);numeric && pid!=os.get_pid() && slice.contains(alive,pid) {continue}
            _=os.remove(entry.fullpath)
        }
    }
    name,error:=strings.clone(fmt.tprintf("%s/%s-live-%d-%d%s",folder,stem,os.get_pid(),generation,extension),allocator)
    if error!=nil {return ""}
    return name
}
