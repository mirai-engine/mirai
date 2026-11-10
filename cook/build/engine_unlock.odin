package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:project"

// A program that runs holds the binaries it loaded: Windows neither replaces
// nor deletes them, but it does move them. Before a build writes, each binary
// of the folder that something runs moves to ENGINE_RETIRED and a copy takes
// its place, which the build replaces or keeps: what runs goes on with the
// binaries it started with, and what starts afterwards takes the new ones. A
// moved binary is deleted by a later build once nothing runs it.

ENGINE_RETIRED :: "retired"

// Moves aside each binary of folder that cannot be written, leaving a copy
// in its place, after deleting the ones moved before that nothing runs any
// more. ok is false, with the file, when one could not be moved or copied.
engine_unlock :: proc(folder:string) -> (file:string,ok:bool) {
    retired:=project.path(folder,ENGINE_RETIRED,allocator=context.temp_allocator)
    engine_retired_sweep(retired)
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return "",true}
    stamp:=time.time_to_unix_nano(time.now())
    for entry in entries {
        if entry.type!=.Regular || !engine_binary(entry.name) || engine_writable(entry.fullpath) {continue}
        if os.make_directory_all(retired)!=nil && !os.is_dir(retired) {return retired,false}
        moved:=project.path(retired,fmt.tprintf("%x-%s",stamp,entry.name),allocator=context.temp_allocator)
        if os.rename(entry.fullpath,moved)!=nil {return entry.fullpath,false}
        if os.copy_file(entry.fullpath,moved)!=nil {
            // Back where it was rather than missing: the build stops at it as before.
            _=os.rename(moved,entry.fullpath)
            return entry.fullpath,false
        }
    }
    return "",true
}

// Deletes the binaries moved aside that nothing runs; the others stay for a later build.
engine_retired_sweep :: proc(retired:string) {
    entries,error:=os.read_all_directory_by_path(retired,context.temp_allocator)
    if error!=nil {return}
    left:=false
    for entry in entries {
        if os.remove(entry.fullpath)!=nil {left=true}
    }
    if !left {_=os.remove(retired)}
}

// What a program loads or a debugger holds open: what a build writes and a
// running program keeps from being written.
@(private)
engine_binary :: proc(name:string) -> bool {
    // The copy a program loaded to take a library in place (host.engine_library_swap) is its own.
    if strings.contains(name,"-live-") {return false}
    for extension in ([?]string{".dll",".exe",".pdb",".so",".dylib"}) {
        if strings.has_suffix(name,extension) {return true}
    }
    return strings.index_byte(name,'.')<0 // a program of Linux or macOS
}

@(private)
engine_writable :: proc(path:string) -> bool {
    f,error:=os.open(path,{.Write})
    if error!=nil {return false}
    os.close(f)
    return true
}
