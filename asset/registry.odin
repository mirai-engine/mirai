package asset

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

// The assets of a project folder: which file holds which id, of what kind,
// and what it depends on. A scan reads the first bytes of every file, never
// its content, and remembers what it saw in a cache file: a file whose size
// and time did not change is not opened again. Whoever knows which files
// changed refreshes those paths instead of walking the folder.

REGISTRY_HEAD :: 4096
REGISTRY_MAX_DEPENDENCIES :: 1<<20
REGISTRY_CACHE_MAGIC :: u32('M')|u32('R')<<8|u32('E')<<16|u32('G')<<24
REGISTRY_CACHE_VERSION :: 4 // of its layout; a cache or index of another one, or of another container VERSION, is not read
// The packed index of a folder of cooked assets, inside it: what a scan of
// the folder would find, written by whoever cooked it. registry_load reads it
// instead of looking at the files.
REGISTRY_INDEX :: ".index"

Registry_State :: enum u8 {
    Other,  // not an asset
    Asset,
    Broken, // starts as an asset and contradicts itself: truncated, or with a directory that does not fit
}

Registry_File :: struct {
    path:string, // from the root of the registry, with forward slashes
    size:i64,
    time:i64,    // of its last change, nanoseconds since 1970
    state:Registry_State,
    id:base.Asset_Id,
    owner:base.Asset_Id, // the asset it is a part of; zero for one of its own
    kind:Fourcc,
    kind_version:u16,
    flags:Header_Flags,
    content_hash:u64, // of its header: what the asset holds, whatever its path or time
    first_dependency:u32,
    dependency_count:u32, // sorted, each id once
}

// The files that depend on an asset: a run of Registry.dependent_files.
Registry_Dependents :: struct {first,count:u32}

Registry_Duplicate :: struct {
    id:base.Asset_Id,
    first,second:u32, // files with the same id; lookups by id give the first
}

// A file that had the id of another, as a copy made outside an editor has:
// registry_duplicates_resolve gave it an id of its own in memory, until it is
// written, or the file changes or goes before it was edited.
Registry_Reassigned :: struct {
    path:string,     // the copy, newer than the original
    original:string, // the file that keeps the id
    from,to:base.Asset_Id,
    hash:u64,        // content_hash of what memory got: another one is an edit
}

Registry_Missing :: struct {
    file:u32,
    id:base.Asset_Id, // a dependency that no file of the registry is
}

Registry_Stats :: struct {
    files:int,   // seen by the last scan
    assets:int,
    opened:int,  // whose first bytes were read
    reused:int,  // taken from the cache or from the scan before
}

// A folder of assets seen under prefix/, beside the root: the assets of a
// plugin. A prefix that starts with a dot is of the program's own assets.
// A guest is a folder the program did not ship (registry_mount_guest).
Registry_Mount :: struct {folder,prefix:string,guest:bool}

// Whether lists of what a project has show a file: those under a mount whose
// prefix starts with a dot are the program's own, found by their path.
registry_listed :: proc "contextless" (file:^Registry_File) -> bool {return len(file.path)==0 || file.path[0]!='.'}

Registry :: struct {
    root:string,
    cache:string, // "" for none
    mounts:[dynamic]Registry_Mount,
    files:[dynamic]Registry_File, // every file, sorted by path
    folders:[dynamic]string,      // every folder the last scan saw, also without files, with a '/' at its end, sorted
    dependencies:[dynamic]base.Asset_Id,
    by_id:map[base.Asset_Id]u32,
    by_path:map[string]u32,
    dependents:map[base.Asset_Id]Registry_Dependents,
    dependent_files:[dynamic]u32, // a run per asset, each in the order of files
    duplicates:[dynamic]Registry_Duplicate,
    reassigned:[dynamic]Registry_Reassigned,
    stats:Registry_Stats,
    revision:u64, // advances before a scan, a refresh or a load replaces files and their paths
    memory:[dynamic]Registry_Memory, // files whose content is held in memory (registry_memory.odin)
    // With a cache: the ids of assets that no file is any more, also those that went while the
    // program was not running, for whoever keeps something per asset. Whoever reads them clears them.
    removed:[dynamic]base.Asset_Id,
    refused:[dynamic]string,         // files of guest mounts left out: another file of the registry has their id
    memory_time:i64,                 // of the last change in memory
    // Whether scans give the newer of two files with one id an id of its own
    // in memory (registry_duplicates_resolve): what an editor wants of a
    // folder people copy files into, and not a tool that only reads it.
    resolve_duplicates:bool,
    allocator:runtime.Allocator,
}

// False, with a registry of no folder that registry_destroy takes, without memory for it.
registry_init :: proc(r:^Registry,root:string,cache:="",allocator:=context.allocator) -> bool {
    r^={allocator=allocator}
    no_root,no_cache:runtime.Allocator_Error
    r.root,no_root=strings.clone(root,allocator)
    r.cache,no_cache=strings.clone(cache,allocator)
    if no_root!=nil || no_cache!=nil {
        delete(r.root,allocator)
        delete(r.cache,allocator)
        r.root,r.cache="",""
    }
    r.files=make([dynamic]Registry_File,allocator)
    r.folders=make([dynamic]string,allocator)
    r.dependencies=make([dynamic]base.Asset_Id,allocator)
    r.by_id=make(map[base.Asset_Id]u32,allocator)
    r.by_path=make(map[string]u32,allocator)
    r.dependents=make(map[base.Asset_Id]Registry_Dependents,allocator)
    r.dependent_files=make([dynamic]u32,allocator)
    r.duplicates=make([dynamic]Registry_Duplicate,allocator)
    r.reassigned=make([dynamic]Registry_Reassigned,allocator)
    r.mounts=make([dynamic]Registry_Mount,allocator)
    r.memory=make([dynamic]Registry_Memory,allocator)
    r.removed=make([dynamic]base.Asset_Id,allocator)
    r.refused=make([dynamic]string,allocator)
    return no_root==nil && no_cache==nil
}

@(private="file")
registry_mount_add :: proc(r:^Registry,folder,prefix:string,guest:bool) -> bool {
    kept_folder,no_folder:=strings.clone(folder,r.allocator)
    kept_prefix,no_prefix:=strings.clone(prefix,r.allocator)
    if no_folder==nil && no_prefix==nil {
        if _,no_room:=append(&r.mounts,Registry_Mount{kept_folder,kept_prefix,guest});no_room==nil {return true}
    }
    delete(kept_folder,r.allocator)
    delete(kept_prefix,r.allocator)
    return false
}

// Adds folder to what the next scan sees, its files under prefix/. The prefix
// is a relative path with '/' that names no folder of the root. False without
// memory for it.
registry_mount :: proc(r:^Registry,folder,prefix:string) -> bool {
    return registry_mount_add(r,folder,prefix,false)
}

// Mounts now a folder the program did not ship (what a player saved or
// downloaded) under prefix/, and reads its files, also over a packed index.
// What the program has wins: a file of a guest whose id another file of the
// registry has is left out and listed in refused, which counts those of this
// folder. Not_Found without the folder; Invalid for a prefix that is not a
// plain relative path (no dot first, no . or .. names), or that a mount or a
// file or folder of the root already takes.
registry_mount_guest :: proc(r:^Registry,folder,prefix:string) -> (refused:int,error:Error) {
    if !registry_prefix_valid(prefix) {return 0,.Invalid}
    for mount in r.mounts {
        if mount.prefix==prefix || registry_under(mount.prefix,prefix) || registry_under(prefix,mount.prefix) {return 0,.Invalid}
    }
    for file in r.files {
        if registry_under(file.path,prefix) {return 0,.Invalid}
    }
    if os.exists(strings.concatenate({r.root,"/",prefix},context.temp_allocator)) {return 0,.Invalid}
    if !os.is_directory(folder) {return 0,.Not_Found}
    if !registry_mount_add(r,folder,prefix,true) {return 0,.Out_Of_Memory}
    r.revision+=1
    mount:=r.mounts[len(r.mounts)-1]
    if error=registry_walk(r,mount,nil,nil,nil);error!=.None {
        registry_unmount(r,prefix)
        return
    }
    error=registry_index(r)
    slice.sort(r.folders[:])
    if r.cache!="" {registry_cache_write(r)}
    for path in r.refused {
        if registry_under(path,prefix) {refused+=1}
    }
    return
}

// Takes a guest mount out of the registry with its files, also those it
// refused. Not_Found when no guest has that prefix; Invalid while the
// registry holds in memory a file under it, an edit not written.
registry_unmount :: proc(r:^Registry,prefix:string) -> Error {
    at:=-1
    for mount,i in r.mounts {
        if mount.guest && mount.prefix==prefix {at=i;break}
    }
    if at<0 {return .Not_Found}
    for held in r.memory {
        if registry_under(held.path,prefix) {return .Invalid}
    }
    r.revision+=1
    gone:=make([dynamic]base.Asset_Id,context.temp_allocator)
    kept:=0
    for file in r.files {
        if registry_under(file.path,prefix) {
            if file.state==.Asset {append(&gone,file.id)}
            delete(file.path,r.allocator)
            continue
        }
        r.files[kept]=file
        kept+=1
    }
    base.truncate(&r.files,kept)
    kept=0
    for folder in r.folders {
        if registry_under(folder,prefix) {delete(folder,r.allocator);continue}
        r.folders[kept]=folder
        kept+=1
    }
    base.truncate(&r.folders,kept)
    registry_refused_clear(r,prefix)
    delete(r.mounts[at].folder,r.allocator);delete(r.mounts[at].prefix,r.allocator)
    ordered_remove(&r.mounts,at)
    indexed:=registry_index(r)
    if r.cache!="" {registry_cache_write(r)}
    for id in gone {registry_note_removed(r,id)}
    return indexed
}

// Whether a path of the registry is in a guest mount.
registry_guest :: proc(r:^Registry,path:string) -> bool {
    for mount in r.mounts {
        if mount.guest && registry_under(path,mount.prefix) {return true}
    }
    return false
}

// Whether path is under prefix/ (a folder path of the registry may end in '/').
@(private)
registry_under :: proc "contextless" (path,prefix:string) -> bool {
    return len(path)>len(prefix) && path[len(prefix)]=='/' && path[:len(prefix)]==prefix
}

@(private="file")
registry_prefix_valid :: proc(prefix:string) -> bool {
    if prefix=="" || prefix[0]=='.' || prefix[0]=='/' || prefix[len(prefix)-1]=='/' {return false}
    for c in transmute([]u8)prefix {
        if c=='\\' || c==':' || c<0x20 {return false}
    }
    for name in strings.split(prefix,"/",context.temp_allocator) {
        if name=="" || name=="." || name==".." {return false}
    }
    return true
}

// Forgets the refused files under prefix/, every one with "".
@(private)
registry_refused_clear :: proc(r:^Registry,prefix:string) {
    kept:=0
    for path in r.refused {
        if prefix=="" || registry_under(path,prefix) {delete(path,r.allocator);continue}
        r.refused[kept]=path
        kept+=1
    }
    base.truncate(&r.refused,kept)
}

// The file a path of the registry is: under the root, under the folder of
// the mount whose prefix it starts with, or itself when it is outside them.
// "" without memory for it.
registry_file_path :: proc(r:^Registry,path:string,allocator:=context.allocator) -> string {
    parts:=[3]string{r.root,"/",path}
    if registry_outside(path) {
        parts={path,"",""}
    } else {
        for mount in r.mounts {
            if registry_under(path,mount.prefix) {parts={mount.folder,path[len(mount.prefix):],""};break}
        }
    }
    file,error:=strings.concatenate(parts[:],allocator)
    if error!=nil {return ""}
    return file
}

// The path in the registry of a file, the inverse of registry_file_path: under
// the folder of a mount or under the root. False for a file outside them.
registry_relative :: proc(r:^Registry,file:string) -> (path:string,ok:bool) {
    if r==nil {return}
    for mount in r.mounts {
        if registry_under(file,mount.folder) {return strings.concatenate({mount.prefix,file[len(mount.folder):]},context.temp_allocator),true}
    }
    if registry_under(file,r.root) {return file[len(r.root)+1:],true}
    return
}

registry_destroy :: proc(r:^Registry) {
    for file in r.files {delete(file.path,r.allocator)}
    for folder in r.folders {delete(folder,r.allocator)}
    delete(r.files);delete(r.folders);delete(r.dependencies);delete(r.by_id);delete(r.by_path);delete(r.duplicates)
    for entry in r.reassigned {registry_reassigned_free(r,entry)}
    delete(r.reassigned)
    delete(r.dependents);delete(r.dependent_files)
    for mount in r.mounts {delete(mount.folder,r.allocator);delete(mount.prefix,r.allocator)}
    delete(r.mounts)
    for &held in r.memory {registry_memory_free(r,&held)}
    delete(r.memory)
    delete(r.removed)
    registry_refused_clear(r,"")
    delete(r.refused)
    delete(r.root,r.allocator);delete(r.cache,r.allocator)
    r^={}
}

registry_find :: proc(r:^Registry,id:base.Asset_Id) -> (file:^Registry_File,found:bool) {
    at:=r.by_id[id] or_return
    return &r.files[at],true
}
registry_find_path :: proc(r:^Registry,path:string) -> (file:^Registry_File,found:bool) {
    at:=r.by_path[path] or_return
    return &r.files[at],true
}
registry_dependencies :: proc(r:^Registry,file:^Registry_File) -> []base.Asset_Id {
    return r.dependencies[file.first_dependency:][:file.dependency_count]
}
// The files that depend on an asset, in the order of files: how many use it
// is its length. Valid until the revision advances.
registry_dependents :: proc(r:^Registry,id:base.Asset_Id) -> []u32 {
    run:=r.dependents[id] or_else {}
    return r.dependent_files[run.first:][:run.count]
}

// The skeleton a file depends on, as a skinned mesh does; zero for one that has none.
registry_skeleton :: proc(r:^Registry,file:^Registry_File) -> base.Asset_Id {
    for dependency in registry_dependencies(r,file) {
        if found,ok:=registry_find(r,dependency);ok && found.kind==KIND_SKELETON && found.state==.Asset {return dependency}
    }
    return {}
}
// The files whose header names owner as the asset they are a part of.
registry_parts :: proc(r:^Registry,owner:base.Asset_Id,out:^[dynamic]u32) {
    clear(out)
    if owner=={} {return}
    for &file,at in r.files {
        if file.state==.Asset && file.owner==owner {append(out,u32(at))}
    }
}
// Everything an asset needs, itself excluded: its dependencies and theirs.
// Ids that no file is are left out.
registry_closure :: proc(r:^Registry,id:base.Asset_Id,out:^[dynamic]u32) {
    clear(out)
    start,found:=r.by_id[id]
    if !found {return}
    seen:=make(map[u32]bool,r.allocator)
    defer delete(seen)
    seen[start]=true
    pending:=make([dynamic]u32,r.allocator)
    defer delete(pending)
    append(&pending,start)
    for len(pending)>0 {
        current:=pop(&pending)
        for dependency in registry_dependencies(r,&r.files[current]) {
            at,known:=r.by_id[dependency]
            if !known || at in seen {continue}
            seen[at]=true
            append(out,at)
            append(&pending,at)
        }
    }
    slice.sort(out[:])
}
registry_missing :: proc(r:^Registry,out:^[dynamic]Registry_Missing) {
    clear(out)
    for &file,at in r.files {
        for dependency in registry_dependencies(r,&file) {
            if !(dependency in r.by_id) {append(out,Registry_Missing{u32(at),dependency})}
        }
    }
}

// What the first bytes of a file say: of the file at full, or of data, a
// whole file held in memory. dependencies receives its ids, sorted and once.
// Out_Of_Memory when it had none to read them: the file stays Broken.
@(private)
registry_probe :: proc(r:^Registry,full:string,file:^Registry_File,dependencies:^[dynamic]base.Asset_Id,data:[]u8=nil) -> (error:Error) {
    head:[REGISTRY_HEAD]u8
    bytes,size:=data,i64(len(data))
    if data==nil {
        head_error:serial.File_Error
        bytes,size,head_error=serial.file_read_head(full,head[:])
        if head_error!=.None {return}
    }
    header,header_error:=header_read(bytes)
    if header_error==.Not_An_Asset || header_error==.Truncated && (len(bytes)<4 || intrinsics.unaligned_load((^u32)(raw_data(bytes)))!=MAGIC) {return}
    file.state=.Broken
    if header_error!=.None || header.total_size!=u64(size) {return}
    file.id,file.owner,file.kind,file.kind_version,file.flags,file.content_hash=header.id,header.owner,header.kind,header.kind_version,header.flags,header.content_hash
    entries,directory_error:=directory_read(full,bytes,header,r.allocator)
    if directory_error!=.None {return .Out_Of_Memory if directory_error==.Out_Of_Memory else .None}
    defer delete(entries,r.allocator)
    for entry in entries {
        if entry.tag!=TAG_DEPS {continue}
        count:=entry.uncompressed_size/size_of(base.Asset_Id)
        if entry.uncompressed_size%size_of(base.Asset_Id)!=0 || count>REGISTRY_MAX_DEPENDENCIES {return}
        // Writers store the dependencies as they are, so a scan reads them without decoding.
        if entry.compression!=.None {return}
        stored,no_stored:=make([]u8,int(entry.size),r.allocator)
        defer delete(stored,r.allocator)
        if no_stored!=nil {return .Out_Of_Memory}
        if entry.offset+entry.size<=u64(len(bytes)) {copy(stored,bytes[entry.offset:])}
        else if serial.file_read_range(full,i64(entry.offset),stored)!=.None {return}
        first:=len(dependencies)
        if resize(dependencies,first+int(count))!=nil {return .Out_Of_Memory}
        target:=mem.slice_to_bytes(dependencies[first:])
        copy(target,stored)
        listed:=dependencies[first:]
        slice.sort_by(listed,proc(a,b:base.Asset_Id) -> bool {return a[0]<b[0] || a[0]==b[0] && a[1]<b[1]})
        unique:=0
        for id in listed {
            if unique>0 && id==listed[unique-1] {continue}
            listed[unique]=id
            unique+=1
        }
        base.truncate(dependencies,first+unique)
        file.dependency_count=u32(unique)
    }
    file.state=.Asset
    return
}

// Walks the folder and brings the registry up to date. Files and folders
// whose name starts with a dot, and files being written, are left out.
registry_scan :: proc(r:^Registry) -> Error {
    r.revision+=1
    allocator:=r.allocator
    previous:=r.files
    previous_dependencies:=r.dependencies
    known:=make(map[string]u32,allocator)
    defer {
        for file in previous {delete(file.path,allocator)}
        delete(previous);delete(previous_dependencies);delete(known)
    }
    r.files=make([dynamic]Registry_File,allocator)
    r.dependencies=make([dynamic]base.Asset_Id,allocator)
    for folder in r.folders {delete(folder,allocator)}
    delete(r.folders)
    r.folders=make([dynamic]string,allocator)
    if len(previous)==0 && r.cache!="" {registry_cache_read(r.cache,&previous,&previous_dependencies,allocator)}
    for file,at in previous {known[file.path]=u32(at)}
    r.stats={}
    registry_refused_clear(r,"")

    if !os.is_directory(r.root) {return .Not_Found}
    if error:=registry_walk(r,{r.root,"",false},known,previous[:],previous_dependencies[:]);error!=.None {return error}
    for mount in r.mounts {
        if !os.is_directory(mount.folder) {continue}
        if error:=registry_walk(r,mount,known,previous[:],previous_dependencies[:]);error!=.None {return error}
    }
    indexed:=registry_index(r)
    slice.sort(r.folders[:])
    if r.cache!="" && (r.stats.opened>0 || len(previous)!=len(r.files)) {registry_cache_write(r)}
    // The copies given an id in memory are what their files are now; resolving gives it again.
    for at:=len(r.reassigned)-1;at>=0;at-=1 {registry_reassigned_forget(r,r.reassigned[at].path)}
    if len(r.memory)>0 {
        for &held in r.memory {
            if registry_memory_record(r,&held)!=.None {indexed=.Out_Of_Memory}
        }
        if again:=registry_index(r);again!=.None {indexed=again}
    }
    if r.resolve_duplicates {registry_duplicates_resolve(r)}
    for file in previous {
        if file.state==.Asset {registry_note_removed(r,file.id)}
    }
    return indexed
}

// Appends the files and folders of a folder under its prefix; a file that
// known says previous had with the same size and time is not opened again.
@(private="file")
registry_walk :: proc(r:^Registry,folder:Registry_Mount,known:map[string]u32,previous:[]Registry_File,previous_dependencies:[]base.Asset_Id) -> Error {
    root,root_error:=os.get_absolute_path(folder.folder,context.temp_allocator)
    if root_error!=nil {return .IO}
    relative:=make([dynamic]u8,context.temp_allocator)
    // Breadth first, each folder read and closed before the next: os.walker leaves the search
    // of the last folder it read open on Windows, which keeps that folder from being renamed
    // (odin-lang/Odin#8112).
    todo:=make([dynamic]string,context.temp_allocator)
    append(&todo,root)
    for next:=0;next<len(todo);next+=1 {
        handle,open_error:=os.open(todo[next])
        if open_error!=nil {continue}
        it:=os.read_directory_iterator_create(handle)
        defer {
            os.read_directory_iterator_destroy(&it)
            os.close(handle)
        }
        for info in os.read_directory_iterator(&it) {
            if strings.has_prefix(info.name,".") {continue}
            directory:=info.type==.Directory
            if directory {append(&todo,strings.clone(info.fullpath,context.temp_allocator))}
            if !directory && (info.type!=.Regular || strings.has_suffix(info.name,".tmp")) || len(info.fullpath)<=len(root) {continue}
            clear(&relative)
            if folder.prefix!="" {append(&relative,folder.prefix)}
            append(&relative,info.fullpath[len(root):])
            for &c in relative {
                if c=='\\' {c='/'}
            }
            path:=strings.trim_left(string(relative[:]),"/")
            if directory {
                listed,no_folder:=strings.concatenate({path,"/"},r.allocator)
                if no_folder!=nil {return .Out_Of_Memory}
                if _,no_room:=append(&r.folders,listed);no_room!=nil {
                    delete(listed,r.allocator)
                    return .Out_Of_Memory
                }
                continue
            }
            file:=Registry_File{size=info.size,time=time.time_to_unix_nano(info.modification_time)}
            r.stats.files+=1
            if at,seen:=known[path];seen && previous[at].size==file.size && previous[at].time==file.time {
                file=previous[at]
                file.first_dependency=u32(len(r.dependencies))
                append(&r.dependencies,..previous_dependencies[previous[at].first_dependency:][:previous[at].dependency_count])
                r.stats.reused+=1
            } else {
                file.first_dependency=u32(len(r.dependencies))
                registry_probe(r,info.fullpath,&file,&r.dependencies) or_return
                r.stats.opened+=1
            }
            registry_file_add(r,file,path) or_return
        }
    }
    return .None
}

// Gives every file with the id of an older one an id of its own, in memory:
// a copy made outside an editor is a new asset. The copy is no longer a part
// of the asset that owned it nor the output of an import (no owner, no import
// table, not Cooked) and keeps everything else. Its id is the same every
// time for the same copy at the same path, so it does not change before it is
// written (registry_memory_write). Files held in memory are edits and are
// left alone. Registry.reassigned tells which files it changed; a record goes
// once its file is no longer held in memory.
registry_duplicates_resolve :: proc(r:^Registry) {
    for at:=len(r.reassigned)-1;at>=0;at-=1 {
        if _,held:=registry_memory_find(r,r.reassigned[at].path);!held {
            registry_reassigned_free(r,r.reassigned[at])
            ordered_remove(&r.reassigned,at)
        }
    }
    Pair :: struct {copy,original:string,id:base.Asset_Id}
    pairs:=make([dynamic]Pair,context.temp_allocator)
    for duplicate,at in r.duplicates {
        // Each id once, with every file that has it: the oldest is the asset.
        seen:=false
        for earlier in r.duplicates[:at] {seen||=earlier.id==duplicate.id}
        if seen {continue}
        files:=make([dynamic]u32,context.temp_allocator)
        append(&files,duplicate.first)
        for other in r.duplicates[at:] {
            if other.id==duplicate.id {append(&files,other.second)}
        }
        original:=files[0]
        for file in files[1:] {
            if registry_newer(r,r.files[original].path,r.files[file].path) {original=file}
        }
        for file in files {
            if file==original {continue}
            if _,held:=registry_memory_find(r,r.files[file].path);held {continue}
            append(&pairs,Pair{strings.clone(r.files[file].path,context.temp_allocator),strings.clone(r.files[original].path,context.temp_allocator),duplicate.id})
        }
    }
    for pair in pairs {
        data,error:=asset_file_read(registry_file_path(r,pair.copy,context.temp_allocator),r.allocator)
        if error!=.None {continue}
        doc:Document
        error=document_read(&doc,data,r.allocator)
        mem.free_bytes(data,r.allocator)
        if error!=.None {continue}
        defer document_destroy(&doc)
        document_detach(&doc)
        doc.id=registry_copy_id(r,pair.id,pair.copy)
        bytes,write_error:=document_bytes(&doc,r.allocator)
        if write_error!=.None {continue}
        header,_:=header_read(bytes)
        error=registry_memory_set(r,pair.copy,bytes)
        mem.free_bytes(bytes,r.allocator)
        if error!=.None {continue}
        copied,no_copy:=strings.clone(pair.copy,r.allocator)
        original,no_original:=strings.clone(pair.original,r.allocator)
        if no_copy==nil && no_original==nil {
            if _,no_room:=append(&r.reassigned,Registry_Reassigned{copied,original,pair.id,doc.id,header.content_hash});no_room==nil {continue}
        }
        delete(copied,r.allocator)
        delete(original,r.allocator)
    }
}

// Lists file under a copy of path. Out_Of_Memory, with the files as they
// were, without memory for it.
@(private)
registry_file_add :: proc(r:^Registry,file:Registry_File,path:string) -> Error {
    file:=file
    no_path:runtime.Allocator_Error
    if file.path,no_path=strings.clone(path,r.allocator);no_path!=nil {return .Out_Of_Memory}
    if _,no_room:=append(&r.files,file);no_room!=nil {
        delete(file.path,r.allocator)
        return .Out_Of_Memory
    }
    return .None
}

@(private)
registry_reassigned_free :: proc(r:^Registry,entry:Registry_Reassigned) {
    delete(entry.path,r.allocator)
    delete(entry.original,r.allocator)
}

@(private="file")
registry_newer :: proc(r:^Registry,a,b:string) -> bool {
    return file_newer(registry_file_path(r,a,context.temp_allocator),registry_file_path(r,b,context.temp_allocator))
}

// Whether the file at path a came after the one at b, of two with one id: a
// is the copy. Created later, else changed later, else later by path.
file_newer :: proc(a,b:string) -> bool {
    stamp :: proc(path:string) -> (created,changed:i64) {
        info,error:=os.stat(path,context.temp_allocator)
        if error!=nil {return}
        return time.time_to_unix_nano(info.creation_time),time.time_to_unix_nano(info.modification_time)
    }
    a_created,a_changed:=stamp(a)
    b_created,b_changed:=stamp(b)
    if a_created!=b_created {return a_created>b_created}
    if a_changed!=b_changed {return a_changed>b_changed}
    return a>b
}

// The id of a copy: from the id it had and its path, and taken by no file.
@(private="file")
registry_copy_id :: proc(r:^Registry,id:base.Asset_Id,path:string) -> base.Asset_Id {
    id:=id
    key:=make([dynamic]u8,context.temp_allocator)
    append(&key,..mem.ptr_to_bytes(&id))
    append(&key,path)
    for seed:=u64(1);;seed+=1 {
        candidate:=base.Asset_Id(base.hash128(key[:],seed))
        if candidate!={} && !(candidate in r.by_id) {return candidate}
    }
}


// Brings the records of some paths up to date without walking the folder:
// the files an editor wrote or a watch saw change. A path that is no file
// now leaves the registry, one that is new joins it, and one whose size and
// time did not change is not opened. A path held in memory keeps what memory
// says, and names a scan leaves out are ignored.
registry_refresh :: proc(r:^Registry,paths:[]string) -> Error {
    if !os.is_directory(r.root) {return .Not_Found}
    changed,exhausted:=false,false
    r.stats.opened,r.stats.reused=0,0
    gone:=make([dynamic]base.Asset_Id,context.temp_allocator)
    // The paths may be strings of the registry, as those refused are, which the loop frees and moves.
    own,no_room:=make([]string,len(paths),context.temp_allocator)
    if no_room!=nil {return .Out_Of_Memory}
    for path,at in paths {own[at]=strings.clone(path,context.temp_allocator)}
    for path in own {
        if path=="" || registry_outside(path) || registry_skipped(path) {continue}
        // A file a guest mount refused comes in again: the index refuses it again if its id is taken.
        for listed,at in r.refused {
            if listed==path {delete(listed,r.allocator);ordered_remove(&r.refused,at);break}
        }
        forgot:=registry_reassigned_forget(r,path)
        if _,held:=registry_memory_find(r,path);held {continue}
        full:=registry_file_path(r,path,context.temp_allocator)
        info,stat_error:=os.stat(full,context.temp_allocator)
        present:=stat_error==nil && info.type==.Regular
        at,known:=r.by_path[path]
        if !present {
            if !known {continue}
            if !changed {r.revision+=1;changed=true}
            if r.files[at].state==.Asset {append(&gone,r.files[at].id)}
            // A gap the index closes; the path is out of the lookup until then.
            delete_key(&r.by_path,path)
            delete(r.files[at].path,r.allocator)
            r.files[at]={}
            r.stats.files-=1
            continue
        }
        file:=Registry_File{size=info.size,time=time.time_to_unix_nano(info.modification_time)}
        if known && !forgot && r.files[at].size==file.size && r.files[at].time==file.time {
            r.stats.reused+=1
            continue
        }
        if !changed {r.revision+=1;changed=true}
        file.first_dependency=u32(len(r.dependencies))
        if registry_probe(r,full,&file,&r.dependencies)!=.None {exhausted=true}
        r.stats.opened+=1
        if known {
            if r.files[at].state==.Asset {append(&gone,r.files[at].id)}
            file.path=r.files[at].path
            r.files[at]=file
        } else {
            if registry_file_add(r,file,path)!=.None {exhausted=true;continue}
            r.by_path[r.files[len(r.files)-1].path]=u32(len(r.files)-1)
            r.stats.files+=1
        }
    }
    if !changed {return .None}
    kept:=0
    for file in r.files {
        if file.path=="" {continue}
        r.files[kept]=file
        kept+=1
    }
    base.truncate(&r.files,kept)
    indexed:=registry_index(r)
    if r.cache!="" {registry_cache_write(r)}
    if r.resolve_duplicates {registry_duplicates_resolve(r)}
    for id in gone {registry_note_removed(r,id)}
    return .Out_Of_Memory if exhausted else indexed
}

// An id that no file of the registry is now goes to the removed ones, with a cache.
@(private)
registry_note_removed :: proc(r:^Registry,id:base.Asset_Id) {
    if r.cache!="" && id!={} && !(id in r.by_id) {append(&r.removed,id)}
}

// Whether a scan leaves a path out: a name of it starts with a dot, or the
// file is being written.
@(private)
registry_skipped :: proc(path:string) -> bool {
    if strings.has_suffix(path,".tmp") {return true}
    rest:=path
    for part in strings.split_iterator(&rest,"/") {
        if strings.has_prefix(part,".") {return true}
    }
    return false
}

// Sorts the files by path and rebuilds the lookups: by id, by path and the
// files that depend on each asset. The dependencies of files that went away
// are dropped once they are as many as the ones in use.
@(private)
registry_index :: proc(r:^Registry) -> (error:Error) {
    slice.sort_by(r.files[:],proc(a,b:Registry_File) -> bool {return a.path<b.path})
    registry_guests_refuse(r)
    clear(&r.by_id);clear(&r.by_path);clear(&r.duplicates)
    clear(&r.dependents);clear(&r.dependent_files)
    r.stats.assets=0
    used:=0
    for file,at in r.files {
        r.by_path[file.path]=u32(at)
        used+=int(file.dependency_count)
        if file.state!=.Asset {continue}
        r.stats.assets+=1
        if first,taken:=r.by_id[file.id];taken {append(&r.duplicates,Registry_Duplicate{file.id,first,u32(at)})}
        else {r.by_id[file.id]=u32(at)}
    }
    // Packing them only gives memory back: without memory for it they stay as they are.
    if len(r.dependencies)>2*used+64 {
        if packed,no_packed:=make([dynamic]base.Asset_Id,0,used,r.allocator);no_packed==nil {
            for &file in r.files {
                first:=u32(len(packed))
                append(&packed,..registry_dependencies(r,&file))
                file.first_dependency=first
            }
            delete(r.dependencies)
            r.dependencies=packed
        }
    }
    // A count per asset, the start of each run, and the runs filled in file order.
    for &file in r.files {
        for id in registry_dependencies(r,&file) {
            if _,run,_,error:=map_entry(&r.dependents,id);error==nil {run.count+=1}
        }
    }
    total:=u32(0)
    for _,&run in r.dependents {
        run.first=total
        total+=run.count
        run.count=0
    }
    if resize(&r.dependent_files,int(total))!=nil {
        clear(&r.dependents)
        return .Out_Of_Memory
    }
    for &file,at in r.files {
        for id in registry_dependencies(r,&file) {
            if _,run,_,error:=map_entry(&r.dependents,id);error==nil && run.first+run.count<total {
                r.dependent_files[run.first+run.count]=u32(at)
                run.count+=1
            }
        }
    }
    return
}

// Leaves out the files of guest mounts whose id a file outside them has, or
// one before them in path order, and lists them in refused.
@(private="file")
registry_guests_refuse :: proc(r:^Registry) {
    guests:=false
    for mount in r.mounts {guests||=mount.guest}
    if !guests {return}
    taken:=make(map[base.Asset_Id]struct{},context.temp_allocator)
    for file in r.files {
        if file.state==.Asset && !registry_guest(r,file.path) {taken[file.id]={}}
    }
    kept:=0
    for file in r.files {
        if file.state==.Asset && registry_guest(r,file.path) {
            if file.id in taken {
                listed:=false
                for path in r.refused {listed||=path==file.path}
                if listed {delete(file.path,r.allocator)}
                else {append(&r.refused,file.path)}
                continue
            }
            taken[file.id]={}
        }
        r.files[kept]=file
        kept+=1
    }
    base.truncate(&r.files,kept)
}

// Writes what the registry holds as a packed index or a cache: the files with
// their size, time, identity and dependencies. Files held in memory are what
// their content says and not what the disk has, and are left out.
registry_save :: proc(r:^Registry,path:string) -> bool {
    w:serial.Writer
    serial.writer_init(&w,allocator=r.allocator)
    defer serial.writer_destroy(&w)
    count:=0
    for file in r.files {
        if _,held:=registry_memory_find(r,file.path);!held {count+=1}
    }
    serial.write_u32(&w,REGISTRY_CACHE_MAGIC)
    serial.write_u32(&w,REGISTRY_CACHE_VERSION)
    serial.write_u32(&w,VERSION)
    serial.write_varint(&w,u64(count))
    for &file in r.files {
        if _,held:=registry_memory_find(r,file.path);held {continue}
        serial.write_string(&w,file.path)
        serial.write_svarint(&w,file.size)
        serial.write_svarint(&w,file.time)
        serial.write_u8(&w,u8(file.state))
        if file.state!=.Asset {continue}
        serial.write_u64(&w,file.id[0]);serial.write_u64(&w,file.id[1])
        serial.write_u64(&w,file.owner[0]);serial.write_u64(&w,file.owner[1])
        serial.write_u32(&w,u32(file.kind))
        serial.write_u16(&w,file.kind_version)
        serial.write_u32(&w,transmute(u32)file.flags)
        serial.write_u64(&w,file.content_hash)
        serial.write_varint(&w,u64(file.dependency_count))
        serial.write_bytes(&w,mem.slice_to_bytes(registry_dependencies(r,&file)))
    }
    return w.overflow==0 && serial.file_write_atomic(path,serial.writer_bytes(&w))==.None
}

// The cache, in a folder that is made when it is not there. One that cannot
// be written only costs the next scan its time.
@(private="file")
registry_cache_write :: proc(r:^Registry) {
    if slash:=strings.last_index_byte(r.cache,'/');slash>0 && !os.is_dir(r.cache[:slash]) {_=os.make_directory_all(r.cache[:slash])}
    registry_save(r,r.cache)
}

// Fills the registry with what a packed index says, without looking at the
// folder: the files are trusted to be there, and whoever opens one checks it.
// Not_Found without the index and Corrupt for one that cannot be read; the
// registry is then empty.
registry_load :: proc(r:^Registry,path:string) -> Error {
    r.revision+=1
    for file in r.files {delete(file.path,r.allocator)}
    clear(&r.files);clear(&r.dependencies)
    r.stats={}
    for folder in r.folders {delete(folder,r.allocator)}
    clear(&r.folders)
    registry_refused_clear(r,"")
    state:=registry_cache_read(path,&r.files,&r.dependencies,r.allocator)
    r.stats.files,r.stats.reused=len(r.files),len(r.files)
    for mount in r.mounts {
        if mount.guest && os.is_directory(mount.folder) {registry_walk(r,mount,nil,nil,nil)}
    }
    indexed:=registry_index(r)
    slice.sort(r.folders[:])
    return state if state!=.None else indexed
}

// Reads a cache into files and dependencies. Anything wrong with it leaves
// both empty: the scan reads every file again.
@(private="file")
registry_cache_read :: proc(path:string,files:^[dynamic]Registry_File,dependencies:^[dynamic]base.Asset_Id,allocator:runtime.Allocator) -> Error {
    data,error:=serial.file_read(path,allocator)
    if error!=.None {return error==.Not_Found?.Not_Found:.IO}
    defer delete(data,allocator)
    r:=serial.reader_init(data)
    // What a scan saw depends on how this build reads a header: a cache of another layout or
    // container version, as an older build writes it, is read again from the files.
    ok:=serial.read_u32(&r)==REGISTRY_CACHE_MAGIC && serial.read_u32(&r)==REGISTRY_CACHE_VERSION && serial.read_u32(&r)==VERSION
    count:=serial.read_count(&r,4)
    exhausted:=false
    for _ in 0..<count {
        if !ok {break}
        file:Registry_File
        path_text:=serial.read_string(&r)
        file.size,file.time=serial.read_svarint(&r),serial.read_svarint(&r)
        state:=serial.read_u8(&r)
        if r.failed || state>u8(max(Registry_State)) {ok=false;break}
        file.state=Registry_State(state)
        if file.state==.Asset {
            file.id={serial.read_u64(&r),serial.read_u64(&r)}
            file.owner={serial.read_u64(&r),serial.read_u64(&r)}
            file.kind=Fourcc(serial.read_u32(&r))
            file.kind_version=serial.read_u16(&r)
            file.flags=transmute(Header_Flags)serial.read_u32(&r)
            file.content_hash=serial.read_u64(&r)
            needed:=serial.read_count(&r,size_of(base.Asset_Id))
            bytes:=serial.read_bytes(&r,needed*size_of(base.Asset_Id))
            if r.failed {ok=false;break}
            file.first_dependency,file.dependency_count=u32(len(dependencies)),u32(needed)
            if resize(dependencies,len(dependencies)+needed)!=nil {ok,exhausted=false,true;break}
            copy(mem.slice_to_bytes(dependencies[file.first_dependency:]),bytes)
        }
        no_path:runtime.Allocator_Error
        if file.path,no_path=strings.clone(path_text,allocator);no_path!=nil {ok,exhausted=false,true;break}
        if _,no_room:=append(files,file);no_room!=nil {
            delete(file.path,allocator)
            ok,exhausted=false,true
            break
        }
    }
    if !ok || r.failed || serial.reader_remaining(&r)!=0 {
        for file in files {delete(file.path,allocator)}
        clear(files);clear(dependencies)
        return .Out_Of_Memory if exhausted else .Corrupt
    }
    return .None
}
