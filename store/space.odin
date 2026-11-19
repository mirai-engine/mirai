package store

import "core:os"
import "core:strings"
import "core:time"
import "mirai:std/base"

BLOB_GRACE_AGE :: time.Hour
BLOB_REFRESH_AGE :: BLOB_GRACE_AGE/4

PARTIAL_GRACE_AGE :: 24*time.Hour // a blob being received that no lease names and that took no piece for this long is removed

@(private)
TMP_STALE :: time.Hour

// Where a sweep claims what it judges, made with the root so that a full
// volume leaves a sweep room to work: tmp/sweep/<kind>-<name>.
@(private)
SWEEP_FOLDER :: "tmp/sweep"

@(private)
Claim_Kind :: enum u8 {Blob,Table,Lease,Partial}

@(private)
CLAIM_PREFIXES :: [Claim_Kind]string{.Blob="b-",.Table="t-",.Lease="l-",.Partial="p-"}

Usage :: struct {
    bytes:i64,
    blobs:int,
}

Sweep_Result :: struct {
    using freed:Usage, // complete blobs, and the bytes of partial ones
    partials:int,      // partial blobs removed
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
    claims_settle(s,at) or_return
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
    error=partials_sweep(&state)
    if error!=.None {return state.result,error}

    buffer:[PATH_BYTES]u8
    tmp:=join(&buffer,s.root,"tmp") or_return
    entries,read_error:=os.read_all_directory_by_path(tmp,s.allocator)
    if read_error!=nil {return state.result,os_error(read_error)}
    defer os.file_info_slice_delete(entries,s.allocator)
    for entry in entries {
        if entry.name=="sweep" || !older_than(entry.modification_time,at,TMP_STALE) {continue}
        base.remove_all(entry.fullpath)
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
    name:[64]u8
    claimed,error:=sweep_claim(state.s,file.fullpath,.Table if state.tables else .Blob,hex(hash,&name),&buffer)
    if error!=.None {
        if !state.tables {state.result.skipped+=1}
        return
    }
    keep:=state.tables && has(state.s,hash)
    removed,finish_error:=sweep_finish(state.s,file.fullpath,claimed,state.now,keep)
    if state.tables {return}
    if finish_error!=.None {state.result.skipped+=1}
    if removed {
        state.result.bytes+=file.size
        state.result.blobs+=1
    }
}

// Removes the partial blobs outside the live set whose marks took no piece
// for PARTIAL_GRACE_AGE, and gives back the claimed folder of a completion
// that ended without finishing.
@(private)
partials_sweep :: proc(state:^Sweep) -> Error {
    s:=state.s
    buffer:[PATH_BYTES]u8
    folder:=join(&buffer,s.root,"partial") or_return
    entries,read_error:=os.read_all_directory_by_path(folder,s.allocator)
    if read_error!=nil {return os_error(read_error)}
    defer os.file_info_slice_delete(entries,s.allocator)
    for entry in entries {
        if entry.type!=.Directory {continue}
        name:=entry.name
        claimed:=strings.has_suffix(name,CLAIMED)
        if claimed {name=name[:len(name)-len(CLAIMED)]}
        hash,ok:=parse_hex(name)
        if !ok || hash in state.live {continue}
        path:=entry.fullpath
        back_buffer:[PATH_BYTES]u8
        if claimed {
            if !older_than(entry.modification_time,state.now,TMP_STALE) {continue}
            path=partial_folder(s,hash,&back_buffer) or_continue
            if rename_folder(entry.fullpath,path)!=nil {continue}
        }
        if !partial_old(s,path,state.now) {continue}
        claim_buffer:[PATH_BYTES]u8
        held,claim_error:=sweep_claim(s,path,.Partial,name,&claim_buffer)
        if claim_error!=.None {
            state.result.skipped+=1
            continue
        }
        if !partial_old(s,held,state.now) {
            sweep_restore(path,held)
            continue
        }
        data_buffer:[PATH_BYTES]u8
        bytes:i64
        if data,data_error:=join(&data_buffer,held,"data");data_error==.None {
            if info,stat_error:=os.lstat(data,s.allocator);stat_error==nil {
                bytes=info.size
                os.file_info_delete(info,s.allocator)
            }
        }
        if base.remove_all(held)!=nil {
            state.result.skipped+=1
            continue
        }
        state.result.bytes+=bytes
        state.result.partials+=1
    }
    return .None
}

// Whether the marks of the partial folder took no piece for PARTIAL_GRACE_AGE.
@(private)
partial_old :: proc(s:^Store,folder:string,now:time.Time) -> bool {
    buffer:[PATH_BYTES]u8
    have,error:=join(&buffer,folder,"have")
    if error!=.None {return false}
    info,stat_error:=os.lstat(have,s.allocator)
    if stat_error!=nil {
        // A folder without marks is a begin that never finished: judged by its own time.
        folder_info,folder_error:=os.lstat(folder,s.allocator)
        if folder_error!=nil {return false}
        defer os.file_info_delete(folder_info,s.allocator)
        return older_than(folder_info.modification_time,now,PARTIAL_GRACE_AGE)
    }
    defer os.file_info_delete(info,s.allocator)
    return older_than(info.modification_time,now,PARTIAL_GRACE_AGE)
}

@(private)
older_than :: proc(at,now:time.Time,age:time.Duration) -> bool {
    return at._nsec<now._nsec && u64(now._nsec)-u64(at._nsec)>u64(age)
}

// The time and size of the regular file at path.
@(private)
regular_info :: proc(s:^Store,path:string) -> (at:time.Time,size:i64,error:Error) {
    info,stat_error:=os.lstat(path,s.allocator)
    if stat_error!=nil {return {},0,os_error(stat_error)}
    defer os.file_info_delete(info,s.allocator)
    if info.type!=.Regular {return {},0,.Io}
    return info.modification_time,info.size,.None
}

// Moves path to tmp/sweep/<kind>-<name>, never over another claim: the
// sweep judges it there, away from writers. Nothing is created, so a full
// volume does not stop it.
@(private)
sweep_claim :: proc(s:^Store,path:string,kind:Claim_Kind,name:string,claim_buffer:^[PATH_BYTES]u8) ->
    (claimed:string,error:Error) {
    prefixes:=CLAIM_PREFIXES
    entry:[2+NAME_MAX]u8
    if len(name)>NAME_MAX {return "",.Invalid_Argument}
    copy(entry[:],prefixes[kind])
    copy(entry[2:],name)
    claimed=join(claim_buffer,s.root,SWEEP_FOLDER,string(entry[:2+len(name)])) or_return
    exists:=rename_new(path,claimed) or_return
    if exists {return "",.Io}
    return claimed,.None
}

@(private)
sweep_finish :: proc(s:^Store,path,claimed:string,now:time.Time,keep:=false) -> (bool,Error) {
    at,_,error:=regular_info(s,claimed)
    if error==.None && !keep && older_than(at,now,BLOB_GRACE_AGE) {
        error=os_error(file_remove(claimed))
        if error==.None {return true,.None}
    }
    restored:=sweep_restore(path,claimed)
    return false,error if error!=.None else restored
}

@(private)
sweep_restore :: proc(path,claimed:string) -> Error {
    exists:=rename_new(claimed,path) or_return
    if exists {
        if os.is_directory(claimed) {return os_error(base.remove_all(claimed))}
        return os_error(file_remove(claimed))
    }
    return .None
}

// Settles what a sweep that stopped left claimed: blobs and tables old
// enough are removed, as that sweep would have, and the rest goes back.
@(private)
claims_settle :: proc(s:^Store,now:time.Time) -> Error {
    buffer:[PATH_BYTES]u8
    folder:=join(&buffer,s.root,SWEEP_FOLDER) or_return
    entries,read_error:=os.read_all_directory_by_path(folder,s.allocator)
    if read_error!=nil {return os_error(read_error)}
    defer os.file_info_slice_delete(entries,s.allocator)
    prefixes:=CLAIM_PREFIXES
    for entry in entries {
        if len(entry.name)<3 {continue}
        kind,found:=Claim_Kind(0),false
        for prefix,k in prefixes {
            if strings.has_prefix(entry.name,prefix) {kind,found=k,true}
        }
        if !found {continue}
        name:=entry.name[2:]
        origin_buffer:[PATH_BYTES]u8
        origin:string
        origin_error:Error
        switch kind {
        case .Blob,.Table:
            hash,ok:=parse_hex(name)
            if !ok {continue}
            if kind==.Blob {
                origin,origin_error=blob_file(s,hash,&origin_buffer)
            } else {
                origin,origin_error=table_file(s,hash,&origin_buffer)
            }
            if origin_error==.None && older_than(entry.modification_time,now,BLOB_GRACE_AGE) {
                file_remove(entry.fullpath)
                continue
            }
        case .Lease:
            if !name_valid(name) {continue}
            origin,origin_error=join(&origin_buffer,s.root,"leases",name)
        case .Partial:
            hash,ok:=parse_hex(name)
            if !ok {continue}
            origin,origin_error=partial_folder(s,hash,&origin_buffer)
        }
        if origin_error!=.None {continue}
        if kind==.Blob || kind==.Table {
            name_buffer:[64]u8
            folder_buffer:[PATH_BYTES]u8
            if shard,shard_error:=join(&folder_buffer,s.root,"blobs" if kind==.Blob else "tables",hex(parse_hex(name) or_else {},&name_buffer)[:2]);shard_error==.None {folder_make(shard)}
        }
        sweep_restore(origin,entry.fullpath)
    }
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
