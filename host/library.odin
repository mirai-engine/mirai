package host

import "base:intrinsics"
import "core:dynlib"
import "core:fmt"
import "core:math/rand"
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

Library_Error :: enum u8 {None,Missing,Copy_Failed,Load_Failed,Not_A_Project,Out_Of_Memory,Other_Tables}

// Loads the library at path from a copy of its own.
project_library_load :: proc(path:string,allocator:=context.allocator) -> (library:Project_Library,error:Library_Error) {
    // The libraries of the engine's plugins the library links sit in a folder beside it.
    library_dependencies_where(project.path(path[:max(strings.last_index_byte(path,'/'),0)],project.PLUGIN_LIBRARIES,allocator=context.temp_allocator))
    library.handle,library.copy=library_copy_load(path,allocator) or_return
    address,found:=dynlib.symbol_address(library.handle,PROJECT_INFO_SYMBOL)
    if !found {
        project_library_unload(&library,allocator)
        return {},.Not_A_Project
    }
    info_proc:=cast(proc() -> core.World_Info)address
    library.info=info_proc()
    return library,.None
}

@(private)
library_copy_load :: proc(path:string,allocator:=context.allocator) -> (handle:dynlib.Library,copy:string,error:Library_Error) {
    if !os.is_file(path) {return nil,"",.Missing}
    copy=library_copy_name(path,allocator)
    if copy=="" {return nil,"",.Out_Of_Memory}
    if os.copy_file(copy,path)!=nil {
        delete(copy,allocator)
        return nil,"",.Copy_Failed
    }
    loaded:bool
    if handle,loaded=dynlib.load_library(copy);!loaded {
        _=os.remove(copy)
        delete(copy,allocator)
        return nil,"",.Load_Failed
    }
    return handle,copy,.None
}

// How the loader names a library of the engine the program already runs.
@(private="file")
LIBRARY_LOADED_PREFIX :: "@rpath/" when ODIN_OS==.Darwin else ""

// Takes in place a library of the engine a build left in folder, when the
// build made it to be (project.LIBRARY_SLOTS): a copy of it loads beside the
// one the program runs, and the table of each of its packages goes over the
// table of the library the program started with, which is the one every
// caller reaches. From then on a call into the library runs the new
// procedures. The one that ran stays loaded, as does every copy: procedures
// kept in data, threads and whatever is on a stack go on in the code they
// started in. Other_Tables, with nothing changed, when a package does not
// export what the running one does: its declarations are others.
engine_library_swap :: proc(folder,file:string,packages:[]string,allocator:=context.allocator) -> (library:Project_Library,error:Library_Error) {
    name:=project.library_file(file,context.temp_allocator)
    running,found:=dynlib.load_library(strings.concatenate({LIBRARY_LOADED_PREFIX,name},context.temp_allocator))
    if !found {return {},.Load_Failed}
    library.handle,library.copy=library_copy_load(project.path(folder,name,allocator=context.temp_allocator),allocator) or_return
    tables:=make([dynamic][2][]rawptr,0,len(packages),context.temp_allocator)
    for path in packages {
        dotted,_:=strings.replace_all(path,"/",".",context.temp_allocator)
        symbol:=fmt.tprintf("mirai.%s%s",dotted,project.LIBRARY_SLOTS)
        old,has_old:=dynlib.symbol_address(running,symbol)
        new,has_new:=dynlib.symbol_address(library.handle,symbol)
        // A package that exports no procedure has no table.
        if !has_old && !has_new {continue}
        table:[2][]rawptr
        keys:[2]u64
        if has_old && has_new {
            table[0],keys[0]=(cast(project.Library_Slots)old)()
            table[1],keys[1]=(cast(project.Library_Slots)new)()
        }
        if keys[0]!=keys[1] || len(table[0])!=len(table[1]) || len(table[0])==0 {
            project_library_unload(&library,allocator)
            return {},.Other_Tables
        }
        append(&tables,table)
    }
    // A slot at a time: a thread that calls through one finds a whole procedure, the one before or the new one.
    for table in tables {
        for value,slot in table[1] {intrinsics.atomic_store(&table[0][slot],value)}
    }
    return library,.None
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
    case .Other_Tables:  return fmt.tprintf("%s does not export what the library that runs does: it declares something else",path)
    }
    return ""
}

// <folder>/<name>-live-<pid>-<random><ext>, a name no other load takes:
// Windows can neither remove nor write over a copy that is loaded, and a
// process may load one library more than once (the editor and its imports).
// The copies a process that ended left behind are removed first. "" without
// memory for it.
@(private)
library_copy_name :: proc(path:string,allocator:=context.allocator) -> string {
    folder:=filepath.dir(path)
    file:=filepath.base(path)
    extension:=filepath.ext(file)
    stem:=strings.trim_suffix(file,extension)
    prefix:=fmt.tprintf("%s-live-",stem)
    entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    // The copy of another process that runs is in use: several players of
    // a project start at once (a server and its clients), and so do editors.
    // Those of this process go when they are unloaded.
    alive,_:=os.process_list(context.temp_allocator)
    for entry in entries {
        if !strings.has_prefix(entry.name,prefix) {continue}
        owner,_,_:=strings.partition(entry.name[len(prefix):],"-")
        if pid,numeric:=strconv.parse_int(owner,10);numeric && (pid==os.get_pid() || slice.contains(alive,pid)) {continue}
        _=os.remove(entry.fullpath)
    }
    name,error:=strings.clone(fmt.tprintf("%s/%s-live-%d-%016x%s",folder,stem,os.get_pid(),rand.uint64(),extension),allocator)
    if error!=nil {return ""}
    return name
}
