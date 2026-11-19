package store

import "core:mem"
import "core:os"
import "core:time"

LEASE_MAX_AGE :: 5*time.Minute // of a lease whose holder cannot be asked: one of another machine on a shared root
LEASE_MAX_HASHES :: 1<<20 // an editor with a large map open holds tens of thousands

@(private)
LEASE_MAGIC :: "mirai lease 2\n"

@(private)
HOST_BYTES :: 64

// The process that holds a lease: its machine, its pid and when it started,
// which tells a pid the system gave again apart.
@(private)
Holder :: struct #packed {
    host:[HOST_BYTES]u8,
    pid:u64le,
    start:u64le,
}

@(private)
LEASE_HEADER :: len(LEASE_MAGIC)+size_of(Holder)+size_of(Hash)

// A lease keeps its addresses from a sweep while its holder runs on this
// machine, whatever the clock says and however long the machine slept, and
// stops at once when the holder ends. A lease of another machine on a shared
// root keeps them while it is younger than LEASE_MAX_AGE.
Lease :: struct {
    store:^Store,
    name:[NAME_MAX]u8,
    name_len:int,
    live:[]Hash,
    holder:Holder,
}

// The holder supplies a unique name and keeps the store open through release.
lease_open :: proc(s:^Store,name:string,live:[]Hash,now:Maybe(time.Time)=nil) ->
    (lease:Lease,error:Error) {
    if s==nil || s.root=="" || !name_valid(name) {return {},.Invalid_Argument}
    lease.store=s
    lease.name_len=copy(lease.name[:],name)
    lease.holder=holder_self()
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
    if error:=lease_write(lease.store.root,path,lease.holder,held,now.? or_else time.now());error!=.None {
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
    return lease_write(lease.store.root,path,lease.holder,lease.live,now.? or_else time.now())
}

lease_release :: proc(lease:^Lease) -> Error {
    buffer:[PATH_BYTES]u8
    path:=lease_path(lease,&buffer) or_return
    error:=os_error(file_remove(path))
    delete(lease.live,lease.store.allocator)
    lease^={}
    return .None if error==.Missing else error
}

@(private)
holder_self :: proc() -> (h:Holder) {
    host_name(&h.host)
    pid:=u64(os.get_pid())
    start,_:=process_start(pid)
    h.pid,h.start=u64le(pid),u64le(start)
    return
}

@(private)
Holder_State :: enum u8 {Unknown,Running,Ended}

// Whether the holder runs, asked of this machine; Unknown for another one.
@(private)
holder_state :: proc(h:Holder,self:Holder) -> Holder_State {
    if h.host!=self.host || h.host==({}) {return .Unknown}
    start,alive:=process_start(u64(h.pid))
    return .Running if alive && start==u64(h.start) else .Ended
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
lease_write :: proc(root,path:string,holder:Holder,live:[]Hash,now:time.Time) -> Error {
    if len(live)>LEASE_MAX_HASHES {return .Invalid_Argument}
    holder:=holder
    who:=mem.ptr_to_bytes(&holder)
    payload:=mem.slice_to_bytes(live)
    checksum:=address_of_parts({who,payload})
    return file_write(root,path,{transmute([]u8)string(LEASE_MAGIC),who,checksum[:],payload},now)
}

// Adds the addresses of every lease that holds: its holder runs here, or
// it is of another machine and fresh. The others are removed.
@(private)
leases_collect :: proc(s:^Store,live:^Live_Set,now:time.Time) -> Error {
    buffer:[PATH_BYTES]u8
    folder:=join(&buffer,s.root,"leases") or_return
    entries,read_error:=os.read_all_directory_by_path(folder,s.allocator)
    if read_error==.Not_Exist {return .None}
    if read_error!=nil {return os_error(read_error)}
    defer os.file_info_slice_delete(entries,s.allocator)
    self:=holder_self()
    for entry in entries {
        if entry.type!=.Regular || !name_valid(entry.name) {continue}
        holds,error:=lease_collect(s,live,entry.fullpath,now,self)
        if error!=.None {return error}
        if !holds {lease_drop(s,entry.fullpath,entry.name,now,self) or_return}
    }
    return .None
}

// Claims a lease that does not hold and removes it, unless what it holds
// changed meanwhile: then it goes back.
@(private)
lease_drop :: proc(s:^Store,path,name:string,now:time.Time,self:Holder) -> Error {
    buffer:[PATH_BYTES]u8
    claimed,claim_error:=sweep_claim(s,path,.Lease,name,&buffer)
    if claim_error!=.None {return .None}
    scratch:Live_Set
    defer delete(scratch)
    scratch.allocator=s.allocator
    holds,error:=lease_collect(s,&scratch,claimed,now,self)
    if error==.None && !holds && file_remove(claimed)==nil {return .None}
    restored:=sweep_restore(path,claimed)
    return error if error!=.None else restored
}

// Adds what the lease at path holds; holds is false for a lease that no
// longer protects: its holder ended, it is of another machine and stale, or
// it is not a lease. Only the addresses of one that holds are added.
@(private)
lease_collect :: proc(s:^Store,live:^Live_Set,path:string,now:time.Time,self:Holder) -> (holds:bool,error:Error) {
    file,open_error:=file_open(path)
    if open_error==.Not_Exist {return true,.None}
    if open_error!=nil {return true,os_error(open_error)}
    defer os.close(file)
    info,stat_error:=os.fstat(file,s.allocator)
    if stat_error!=nil {return true,os_error(stat_error)}
    defer os.file_info_delete(info,s.allocator)
    if info.type!=.Regular || info.size<LEASE_HEADER || info.size>LEASE_HEADER+LEASE_MAX_HASHES*size_of(Hash) {
        return false,.None
    }
    bytes:=info.size-LEASE_HEADER
    if bytes%size_of(Hash)!=0 {return false,.None}
    header:[LEASE_HEADER]u8
    if read_exact(file,header[:],0)!=.None || string(header[:len(LEASE_MAGIC)])!=LEASE_MAGIC {
        return false,.None
    }
    holder:=(^Holder)(&header[len(LEASE_MAGIC)])^
    switch holder_state(holder,self) {
    case .Running:
    case .Ended: return false,.None
    case .Unknown: if older_than(info.modification_time,now,LEASE_MAX_AGE) {return false,.None}
    }
    hashes,make_error:=make([]Hash,int(bytes/size_of(Hash)),s.allocator)
    if make_error!=nil {return true,.Out_Of_Memory}
    defer delete(hashes,s.allocator)
    payload:=mem.slice_to_bytes(hashes)
    if read_exact(file,payload,LEASE_HEADER)!=.None {return false,.None}
    checksum:=address_of_parts({header[len(LEASE_MAGIC):][:size_of(Holder)],payload})
    if mem.compare(checksum[:],header[len(LEASE_MAGIC)+size_of(Holder):][:size_of(Hash)])!=0 {return false,.None}
    return true,live_add(live,hashes)
}
