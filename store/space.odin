package store

import "core:mem"
import "core:os"
import "core:slice"
import "core:time"
import "mirai:std/base"

// Temporary files left by a process that ended before renaming them; a
// younger one may still be written.
@(private)
TMP_STALE :: time.Hour

Usage :: struct {
    bytes:i64,
    blobs:int,
}

// What the complete blobs take.
usage :: proc(s:^Store) -> (total:Usage,error:Error) {
    error=blobs_walk(s,"blobs",proc(user:rawptr,path:string,hash:Hash,size:i64) -> Error {
        total:=(^Usage)(user)
        total.bytes+=size
        total.blobs+=1
        return .None
    },&total)
    return
}

// Removes every complete blob whose address is not in live, with its kept
// table, and the stale files of tmp: what it freed. The caller decides what is live.
sweep :: proc(s:^Store,live:[]Hash) -> (freed:Usage,error:Error) {
    Sweep :: struct {live:[]Hash,freed:Usage,tables:bool}
    sorted,make_error:=make([]Hash,len(live),s.allocator)
    if make_error!=nil {return {},.Out_Of_Memory}
    defer delete(sorted,s.allocator)
    copy(sorted,live)
    slice.sort_by(sorted,proc(a,b:Hash) -> bool {
        a,b:=a,b
        return mem.compare(a[:],b[:])<0
    })
    state:=Sweep{live=sorted}
    visit:=proc(user:rawptr,path:string,hash:Hash,size:i64) -> Error {
        state:=(^Sweep)(user)
        _,found:=slice.binary_search_by(state.live,hash,proc(a,b:Hash) -> slice.Ordering {
            a,b:=a,b
            return slice.Ordering(mem.compare(a[:],b[:]))
        })
        if found {return .None}
        removed:=os.remove(path)
        if removed==.Not_Exist {return .None}
        if removed!=nil {return os_error(removed)}
        if !state.tables {
            state.freed.bytes+=size
            state.freed.blobs+=1
        }
        return .None
    }
    error=blobs_walk(s,"blobs",visit,&state)
    if error!=.None {return state.freed,error}
    state.tables=true
    error=blobs_walk(s,"tables",visit,&state)
    if error!=.None {return state.freed,error}
    buffer:[PATH_BYTES]u8
    tmp:=join(&buffer,s.root,"tmp") or_return
    entries,read_error:=os.read_all_directory_by_path(tmp,s.allocator)
    if read_error!=nil {return state.freed,os_error(read_error)}
    defer os.file_info_slice_delete(entries,s.allocator)
    now:=time.now()
    for entry in entries {
        if time.diff(entry.modification_time,now)>TMP_STALE {base.remove_all(entry.fullpath)}
    }
    return state.freed,.None
}

// Visits every file of <kind>/<first byte>/ named by an address: the complete
// blobs, or the kept tables.
@(private)
blobs_walk :: proc(s:^Store,kind:string,visit:proc(user:rawptr,path:string,hash:Hash,size:i64) -> Error,user:rawptr) -> Error {
    buffer:[PATH_BYTES]u8
    blobs:=join(&buffer,s.root,kind) or_return
    folders,folders_error:=os.read_all_directory_by_path(blobs,s.allocator)
    if folders_error!=nil {return os_error(folders_error)}
    defer os.file_info_slice_delete(folders,s.allocator)
    for folder in folders {
        if folder.type!=.Directory || len(folder.name)!=2 {continue}
        files,files_error:=os.read_all_directory_by_path(folder.fullpath,s.allocator)
        if files_error==.Not_Exist {continue}
        if files_error!=nil {return os_error(files_error)}
        defer os.file_info_slice_delete(files,s.allocator)
        for file in files {
            hash,ok:=parse_hex(file.name)
            if !ok || file.type!=.Regular || file.name[:2]!=folder.name {continue}
            visit(user,file.fullpath,hash,file.size) or_return
        }
    }
    return .None
}
