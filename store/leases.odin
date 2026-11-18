package store

import "core:mem"
import "core:os"
import "core:time"

LEASE_MAX_AGE :: 5*time.Minute
LEASE_MAX_HASHES :: 1<<20 // an editor with a large map open holds tens of thousands

@(private)
LEASE_MAGIC :: "mirai lease 1\n"

Lease :: struct {
    store:^Store,
    name:[NAME_MAX]u8,
    name_len:int,
    live:[]Hash,
}

// The holder supplies a unique name and keeps the store open through release.
lease_open :: proc(s:^Store,name:string,live:[]Hash,now:Maybe(time.Time)=nil) ->
    (lease:Lease,error:Error) {
    if s==nil || s.root=="" || !name_valid(name) {return {},.Invalid_Argument}
    lease.store=s
    lease.name_len=copy(lease.name[:],name)
    error=lease_update(&lease,live,now)
    if error!=.None {return {},error}
    return lease,.None
}

lease_update :: proc(lease:^Lease,live:[]Hash,now:Maybe(time.Time)=nil) -> Error {
    if lease==nil || lease.store==nil || len(live)>LEASE_MAX_HASHES {return .Invalid_Argument}
    buffer:[PATH_BYTES]u8
    path:=lease_path(lease,&buffer) or_return
    allocator:=lease.store.allocator
    held,make_error:=make([]Hash,len(live),allocator)
    if make_error!=nil {return .Out_Of_Memory}
    copy(held,live)
    if error:=lease_write(lease.store.root,path,held,now.? or_else time.now());error!=.None {
        delete(held,allocator)
        return error
    }
    delete(lease.live,allocator)
    lease.live=held
    return .None
}

lease_refresh :: proc(lease:^Lease,now:Maybe(time.Time)=nil) -> Error {
    buffer:[PATH_BYTES]u8
    path:=lease_path(lease,&buffer) or_return
    return lease_write(lease.store.root,path,lease.live,now.? or_else time.now())
}

lease_release :: proc(lease:^Lease) -> Error {
    buffer:[PATH_BYTES]u8
    path:=lease_path(lease,&buffer) or_return
    error:=os_error(os.remove(path))
    delete(lease.live,lease.store.allocator)
    lease^={}
    return .None if error==.Missing else error
}

@(private)
lease_path :: proc(lease:^Lease,buffer:^[PATH_BYTES]u8) -> (string,Error) {
    if lease==nil || lease.store==nil || lease.store.root=="" ||
        lease.name_len<1 || lease.name_len>len(lease.name) {
        return "",.Invalid_Argument
    }
    name:=string(lease.name[:lease.name_len])
    if !name_valid(name) {return "",.Invalid_Argument}
    return join(buffer,lease.store.root,"leases",name)
}

@(private)
lease_write :: proc(root,path:string,live:[]Hash,now:time.Time) -> Error {
    if len(live)>LEASE_MAX_HASHES {return .Invalid_Argument}
    payload:=mem.slice_to_bytes(live)
    checksum:=address_of_bytes(payload)
    return file_write(root,path,{transmute([]u8)string(LEASE_MAGIC),checksum[:],payload},now)
}

@(private)
leases_collect :: proc(s:^Store,live:^Live_Set,now:time.Time) -> Error {
    buffer:[PATH_BYTES]u8
    folder:=join(&buffer,s.root,"leases") or_return
    entries,read_error:=os.read_all_directory_by_path(folder,s.allocator)
    if read_error==.Not_Exist {return .None}
    if read_error!=nil {return os_error(read_error)}
    defer os.file_info_slice_delete(entries,s.allocator)
    for entry in entries {
        if entry.type!=.Regular || !name_valid(entry.name) {continue}
        if older_than(entry.modification_time,now,LEASE_MAX_AGE) {
            lease_collect_stale(s,live,entry.fullpath,now) or_return
        }
        lease_collect(s,live,entry.fullpath,now) or_return
    }
    return .None
}

@(private)
lease_collect_stale :: proc(s:^Store,live:^Live_Set,path:string,now:time.Time) -> Error {
    buffer:[PATH_BYTES]u8
    claimed,claim_error:=sweep_claim(s,path,&buffer)
    if claim_error!=.None {return .None}
    defer os.remove(os.dir(claimed))
    at,time_error:=regular_time(s,claimed)
    if time_error==.None && older_than(at,now,LEASE_MAX_AGE) {
        if os.remove(claimed)==nil {return .None}
    }
    collected:=lease_collect(s,live,claimed,now)
    restored:=sweep_restore(path,claimed)
    return collected if collected!=.None else restored
}

@(private)
lease_collect :: proc(s:^Store,live:^Live_Set,path:string,now:time.Time) -> Error {
    file,open_error:=os.open(path)
    if open_error==.Not_Exist {return .None}
    if open_error!=nil {return os_error(open_error)}
    defer os.close(file)
    info,stat_error:=os.fstat(file,s.allocator)
    if stat_error!=nil {return os_error(stat_error)}
    defer os.file_info_delete(info,s.allocator)
    if info.type!=.Regular || older_than(info.modification_time,now,LEASE_MAX_AGE) {return .None}

    HEADER_BYTES :: len(LEASE_MAGIC)+size_of(Hash)
    if info.size<HEADER_BYTES || info.size>HEADER_BYTES+LEASE_MAX_HASHES*size_of(Hash) {
        return .None
    }
    bytes:=info.size-HEADER_BYTES
    if bytes%size_of(Hash)!=0 {return .None}
    header:[HEADER_BYTES]u8
    if read_exact(file,header[:],0)!=.None || string(header[:len(LEASE_MAGIC)])!=LEASE_MAGIC {
        return .None
    }
    hashes,make_error:=make([]Hash,int(bytes/size_of(Hash)),s.allocator)
    if make_error!=nil {return .Out_Of_Memory}
    defer delete(hashes,s.allocator)
    payload:=mem.slice_to_bytes(hashes)
    if read_exact(file,payload,HEADER_BYTES)!=.None {return .None}
    checksum:=address_of_bytes(payload)
    if mem.compare(checksum[:],header[len(LEASE_MAGIC):])!=0 {return .None}
    return live_add(live,hashes)
}
