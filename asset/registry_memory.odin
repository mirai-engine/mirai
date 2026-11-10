package asset

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

// Files of the folder whose content is held in memory and not on disk: what
// an editor changed and did not write. Until it is written or dropped, a file
// in memory is what the registry and registry_read answer for its path, and a
// removed one is a file that is not there. Scans keep them; the record of a
// file in memory takes the size of its content and the time it last changed.
// A file outside the folders, named by its absolute path (the Slang source of
// a program), is held the same way but is no file of the registry: no record,
// scan or lookup by id sees it.

Registry_Memory :: struct {
    path:string, // as Registry_File.path
    data:[]u8,   // the whole file, aligned for its chunks; nil when removed
    removed:bool,
}

// path holds data in memory: a copy of it. Out_Of_Memory leaves it as it was.
registry_memory_set :: proc(r:^Registry,path:string,data:[]u8) -> Error {
    copied:=asset_bytes_clone(data,r.allocator) or_return
    held:=registry_memory_take(r,path) or_return
    registry_memory_free_data(r,held)
    held.data,held.removed=copied,false
    return registry_memory_changed(r,held)
}

// path is not there in memory: no file answers for it until it is written or
// dropped.
registry_memory_remove :: proc(r:^Registry,path:string) -> Error {
    held:=registry_memory_take(r,path) or_return
    registry_memory_free_data(r,held)
    held.data,held.removed=nil,true
    return registry_memory_changed(r,held)
}

// Forgets what memory holds for path: the file on disk answers again, or no
// file when there is none. Not dropped when memory held nothing for it;
// Out_Of_Memory when it is dropped and the records had none to follow.
registry_memory_drop :: proc(r:^Registry,path:string) -> (dropped:bool,error:Error) {
    path:=strings.clone(path,context.temp_allocator) // it may be the one memory holds, which forgetting frees
    if !registry_memory_forget(r,path) {return false,.None}
    if registry_outside(path) {
        r.revision+=1
        return true,.None
    }
    previous:=registry_path_id(r,path)
    registry_file_remove(r,path)
    full:=registry_file_path(r,path,context.temp_allocator)
    if info,stat_error:=os.stat(full,context.temp_allocator);stat_error==nil && info.type==.Regular {
        file:=Registry_File{size=info.size,time=time.time_to_unix_nano(info.modification_time),first_dependency=u32(len(r.dependencies))}
        error=registry_probe(r,full,&file,&r.dependencies)
        if added:=registry_file_add(r,file,path);added!=.None {error=added}
    }
    r.revision+=1
    if indexed:=registry_index(r);indexed!=.None {error=indexed}
    if r.resolve_duplicates {registry_duplicates_resolve(r)}
    registry_note_removed(r,previous)
    return true,error
}

// Forgets what memory holds for path and nothing else: the caller brings the
// records up to date.
@(private)
registry_memory_forget :: proc(r:^Registry,path:string) -> bool {
    for &held,at in r.memory {
        if held.path!=path {continue}
        registry_memory_free(r,&held)
        ordered_remove(&r.memory,at)
        return true
    }
    return false
}

// Forgets the copy at path that registry_duplicates_resolve gave an id in
// memory, unless it was edited since: its file says again what it is. False
// for any other path.
@(private)
registry_reassigned_forget :: proc(r:^Registry,path:string) -> bool {
    for entry,at in r.reassigned {
        if entry.path!=path {continue}
        held,found:=registry_memory_find(r,path)
        if found {
            if held.removed {return false}
            if header,error:=header_read(held.data);error!=.None || header.content_hash!=entry.hash {return false}
            registry_memory_forget(r,path)
        }
        registry_reassigned_free(r,entry)
        ordered_remove(&r.reassigned,at)
        return true
    }
    return false
}

// Whether a path of memory names a file outside the folders: an absolute one.
registry_outside :: proc(path:string) -> bool {return filepath.is_abs(path)}

registry_memory_find :: proc(r:^Registry,path:string) -> (held:^Registry_Memory,found:bool) {
    for &entry in r.memory {
        if entry.path==path {return &entry,true}
    }
    return nil,false
}

// Writes what memory holds for path to its file, whole or not at all, or
// removes the file of a removed one, and forgets it: the file answers again.
registry_memory_write :: proc(r:^Registry,path:string) -> Error {
    held,found:=registry_memory_find(r,path)
    if !found {return .Not_Found}
    full:=registry_file_path(r,path,context.temp_allocator)
    if held.removed {
        if os.exists(full) && os.remove(full)!=nil {return .IO}
    } else {
        if folder:=filepath.dir(full);!os.is_dir(folder) && os.make_directory_all(folder)!=nil {return .IO}
        if serial.file_write_atomic(full,held.data)!=.None {return .IO}
    }
    _,error:=registry_memory_drop(r,path)
    return error
}

// What a file of the registry holds now: its content in memory, or the file
// on disk, aligned for the chunks of the asset it is. Not_Found for a removed
// file and for one that is not there.
registry_read :: proc(r:^Registry,path:string,allocator:=context.allocator,limit:=u64(DEFAULT_MEMORY_LIMIT)) -> (data:[]u8,error:Error) {
    if held,found:=registry_memory_find(r,path);found {
        if held.removed {return nil,.Not_Found}
        if u64(len(held.data))>limit {return nil,.Too_Large}
        return asset_bytes_clone(held.data,allocator)
    }
    full:=registry_file_path(r,path,context.temp_allocator)
    if full=="" {return nil,.Out_Of_Memory}
    return asset_file_read(full,allocator,limit)
}

// The record of a file in memory: what its content says, in place of what
// the disk has; none for a removed one.
@(private)
registry_memory_record :: proc(r:^Registry,held:^Registry_Memory) -> (error:Error) {
    if registry_outside(held.path) {return}
    registry_file_remove(r,held.path)
    if held.removed {return}
    file:=Registry_File{size=i64(len(held.data)),time=r.memory_time,first_dependency=u32(len(r.dependencies))}
    error=registry_probe(r,"",&file,&r.dependencies,held.data)
    if added:=registry_file_add(r,file,held.path);added!=.None {error=added}
    return
}

@(private)
registry_memory_free :: proc(r:^Registry,held:^Registry_Memory) {
    registry_memory_free_data(r,held)
    delete(held.path,r.allocator)
    held^={}
}

@(private="file")
registry_memory_free_data :: proc(r:^Registry,held:^Registry_Memory) {
    if held.data!=nil {mem.free_bytes(held.data,r.allocator)}
    held.data=nil
}

// The entry of path in memory, added when it has none.
@(private="file")
registry_memory_take :: proc(r:^Registry,path:string) -> (held:^Registry_Memory,error:Error) {
    if found,known:=registry_memory_find(r,path);known {return found,.None}
    entry:Registry_Memory
    no_path:mem.Allocator_Error
    if entry.path,no_path=strings.clone(path,r.allocator);no_path!=nil {return nil,.Out_Of_Memory}
    if _,appended:=append(&r.memory,entry);appended!=nil {
        delete(entry.path,r.allocator)
        return nil,.Out_Of_Memory
    }
    return &r.memory[len(r.memory)-1],.None
}

// The record of a file in memory follows its new content, with a time that
// no earlier change of it had.
@(private="file")
registry_memory_changed :: proc(r:^Registry,held:^Registry_Memory) -> Error {
    r.memory_time=max(time.time_to_unix_nano(time.now()),r.memory_time+1)
    previous:=registry_path_id(r,held.path)
    recorded:=registry_memory_record(r,held)
    r.revision+=1
    indexed:=registry_index(r)
    registry_note_removed(r,previous)
    return recorded if recorded!=.None else indexed
}

// The asset a path of the registry is now; zero for none.
@(private="file")
registry_path_id :: proc(r:^Registry,path:string) -> base.Asset_Id {
    if at,found:=r.by_path[path];found && r.files[at].state==.Asset {return r.files[at].id}
    return {}
}

@(private="file")
registry_file_remove :: proc(r:^Registry,path:string) {
    for file,at in r.files {
        if file.path!=path {continue}
        delete(file.path,r.allocator)
        ordered_remove(&r.files,at)
        return
    }
}
