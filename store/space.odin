package store

import "core:os"
import "core:strings"
import "core:time"
import "mirai:std/base"

BLOB_GRACE_AGE :: time.Hour
BLOB_REFRESH_AGE :: BLOB_GRACE_AGE/4

@(private)
TMP_STALE :: time.Hour

@(private)
SWEEP_PREFIX :: "sweep-"

Usage :: struct {
    bytes:i64,
    blobs:int,
}

Sweep_Result :: struct {
    using freed:Usage,
    skipped:int,
}

@(private)
Live_Set :: map[Hash]struct{}

@(private)
Sweep :: struct {
    s:^Store,
    live:Live_Set,
    now:time.Time,
    result:Sweep_Result,
    tables:bool,
}

usage :: proc(s:^Store) -> (total:Usage,error:Error) {
    error=blobs_walk(s,"blobs",proc(user:rawptr,file:os.File_Info,hash:Hash) {
        total:=(^Usage)(user)
        total.bytes+=file.size
        total.blobs+=1
    },&total)
    return
}

sweep :: proc(s:^Store,live:[]Hash,now:Maybe(time.Time)=nil) -> (result:Sweep_Result,error:Error) {
    if s==nil || s.root=="" {return {},.Invalid_Argument}
    at:=now.? or_else time.now()
    set,make_error:=make(Live_Set,len(live),s.allocator)
    if make_error!=nil {return {},.Out_Of_Memory}
    defer delete(set)
    live_add(&set,live) or_return
    leases_collect(s,&set,at) or_return
    state:=Sweep{s=s,live=set,now=at}
    error=blobs_walk(s,"blobs",sweep_entry,&state)
    if error!=.None {return state.result,error}
    state.tables=true
    error=blobs_walk(s,"tables",sweep_entry,&state)
    if error!=.None {return state.result,error}

    buffer:[PATH_BYTES]u8
    tmp:=join(&buffer,s.root,"tmp") or_return
    entries,read_error:=os.read_all_directory_by_path(tmp,s.allocator)
    if read_error!=nil {return state.result,os_error(read_error)}
    defer os.file_info_slice_delete(entries,s.allocator)
    for entry in entries {
        if !older_than(entry.modification_time,at,TMP_STALE) {continue}
        if entry.type==.Directory && strings.has_prefix(entry.name,SWEEP_PREFIX) {
            claimed,path_error:=join(&buffer,entry.fullpath,"file")
            if path_error!=.None {continue}
            modified,stat_error:=regular_time(s,claimed)
            if stat_error==.None && older_than(modified,at,BLOB_GRACE_AGE) {os.remove(claimed)}
            os.remove(entry.fullpath)
        } else {
            base.remove_all(entry.fullpath)
        }
    }
    return state.result,.None
}

@(private)
live_add :: proc(set:^Live_Set,hashes:[]Hash) -> Error {
    for hash in hashes {
        if _,error:=map_insert(set,hash,{});error!=nil {return .Out_Of_Memory}
    }
    return .None
}

@(private)
sweep_entry :: proc(user:rawptr,file:os.File_Info,hash:Hash) {
    state:=(^Sweep)(user)
    if hash in state.live || !older_than(file.modification_time,state.now,BLOB_GRACE_AGE) {return}
    if state.tables && has(state.s,hash) {return}
    buffer:[PATH_BYTES]u8
    claimed,error:=sweep_claim(state.s,file.fullpath,&buffer)
    if error!=.None {
        if !state.tables {state.result.skipped+=1}
        return
    }
    defer os.remove(os.dir(claimed))
    keep:=state.tables && has(state.s,hash)
    removed,finish_error:=sweep_finish(state.s,file.fullpath,claimed,state.now,keep)
    if state.tables {return}
    if finish_error!=.None {state.result.skipped+=1}
    if removed {
        state.result.bytes+=file.size
        state.result.blobs+=1
    }
}

@(private)
older_than :: proc(at,now:time.Time,age:time.Duration) -> bool {
    return at._nsec<now._nsec && u64(now._nsec)-u64(at._nsec)>u64(age)
}

@(private)
regular_time :: proc(s:^Store,path:string) -> (time.Time,Error) {
    info,error:=os.lstat(path,s.allocator)
    if error!=nil {return {},os_error(error)}
    defer os.file_info_delete(info,s.allocator)
    if info.type!=.Regular {return {},.Io}
    return info.modification_time,.None
}

// The directory dates the claim independently of the file moved into it.
@(private)
sweep_claim :: proc(s:^Store,path:string,claim_buffer:^[PATH_BYTES]u8) ->
    (claimed:string,error:Error) {
    folder_buffer:[PATH_BYTES]u8
    folder:=temp_folder(s.root,SWEEP_PREFIX,&folder_buffer) or_return
    claimed,error=join(claim_buffer,folder,"file")
    if error==.None {error=os_error(os.rename(path,claimed))}
    if error!=.None {os.remove(folder);return "",error}
    return claimed,.None
}

@(private)
sweep_finish :: proc(s:^Store,path,claimed:string,now:time.Time,keep:=false) -> (bool,Error) {
    at,error:=regular_time(s,claimed)
    if error==.None && !keep && older_than(at,now,BLOB_GRACE_AGE) {
        error=os_error(os.remove(claimed))
        if error==.None {return true,.None}
    }
    restored:=sweep_restore(path,claimed)
    return false,error if error!=.None else restored
}

@(private)
sweep_restore :: proc(path,claimed:string) -> Error {
    exists:=rename_new(claimed,path) or_return
    if exists {return os_error(os.remove(claimed))}
    return .None
}

// Visits the regular files named by an address in blobs/ or tables/.
@(private)
blobs_walk :: proc(s:^Store,kind:string,
    visit:proc(user:rawptr,file:os.File_Info,hash:Hash),user:rawptr) -> Error {
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
            visit(user,file,hash)
        }
    }
    return .None
}
