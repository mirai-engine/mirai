package store

import "core:crypto"
import "core:mem"
import "core:os"

LEASE_MAX_HASHES :: 1<<20 // an editor with a large map open holds tens of thousands

@(private)
LEASE_MAGIC :: "mirai lease 4\n"

// A lease keeps what it names, at every level, from a sweep while the process
// that opened it runs: leases/<id> holds its addresses, and its holder keeps
// the file locked, which the system lets go when the process ends, however it
// ends. A sweep removes a lease whose lock it can take. What a lease names
// that is stored when lease_open or lease_update returns stays stored.
Lease :: struct {
    store:^Store,
    live:[]Hash, // of the store's allocator
    id:[16]u8,
    file:^os.File, // locked while the lease holds
}

// The holder keeps the store open through lease_release.
lease_open :: proc(s:^Store,live:[]Hash) -> (lease:Lease,error:Error) {
    if s==nil || s.state==nil {return {},.Invalid_Argument}
    lease.store=s
    crypto.rand_bytes(lease.id[:])
    lease_update(&lease,live) or_return
    return lease,.None
}

// Replaces what the lease names. A new file, locked, takes the place of the
// old one at once, so a sweep reads one or the other whole, and never runs
// meanwhile.
lease_update :: proc(lease:^Lease,live:[]Hash) -> Error {
    if lease==nil || lease.store==nil || len(live)>LEASE_MAX_HASHES {return .Invalid_Argument}
    s:=lease.store
    held,make_error:=make([]Hash,len(live),s.allocator)
    if make_error!=nil {return .Out_Of_Memory}
    copy(held,live)
    batch_enter(s) or_return
    defer batch_leave(s)
    temp_buffer,path_buffer:[PATH_BYTES]u8
    temp,file,error:=temp_create(s,s.root,&temp_buffer)
    path:string
    if error==.None {_,error=file_lock(file,.Exclusive,false)}
    if error==.None {error=io_write_at(s,file,transmute([]u8)string(LEASE_MAGIC),0)}
    if error==.None {error=io_write_at(s,file,mem.slice_to_bytes(held),len(LEASE_MAGIC))}
    if error==.None {path,error=lease_path(lease,&path_buffer)}
    if error==.None {error=io_rename(s,temp,path)}
    if error!=.None {
        if file!=nil {
            os.close(file)
            file_remove(temp)
        }
        delete(held,s.allocator)
        return error
    }
    if lease.file!=nil {os.close(lease.file)}
    delete(lease.live,s.allocator)
    lease.file,lease.live=file,held
    return .None
}

lease_release :: proc(lease:^Lease) -> Error {
    if lease==nil || lease.store==nil {return .Invalid_Argument}
    buffer:[PATH_BYTES]u8
    error:Error
    if path,path_error:=lease_path(lease,&buffer);path_error==.None {error=os_error(file_remove(path))}
    if lease.file!=nil {os.close(lease.file)}
    delete(lease.live,lease.store.allocator)
    lease^={}
    return .None if error==.Missing else error
}

@(private)
lease_path :: proc(lease:^Lease,buffer:^[PATH_BYTES]u8) -> (string,Error) {
    text:[64]u8
    return join(buffer,lease.store.root,"leases",writer_text(lease.id,&text))
}

// Adds the addresses of every lease whose holder runs; removes the others.
@(private)
leases_collect :: proc(s:^Store,live:^Live_Set) -> Error {
    buffer:[PATH_BYTES]u8
    entries:=io_list(s,join(&buffer,s.root,"leases") or_return) or_return
    defer os.file_info_slice_delete(entries,s.state.allocator)
    for entry in entries {
        if entry.type==.Regular {lease_collect(s,live,entry.fullpath) or_return}
    }
    return .None
}

// Adds what the lease at path holds while its holder keeps it locked; one
// whose lock is free is removed. A file that is not a lease adds nothing.
@(private)
lease_collect :: proc(s:^Store,live:^Live_Set,path:string) -> Error {
    // Opened to write: an exclusive lock on a handle only read can be denied
    // on Windows.
    file,open_error:=io_open(s,path,{.Read,.Write})
    if open_error==.Missing {return .None}
    open_error or_return
    defer os.close(file)
    ended:=file_lock(file,.Exclusive,false) or_return
    if ended {
        file_unlock(file)
        io_remove(s,path)
        return .None
    }
    size,size_error:=os.file_size(file)
    if size_error!=nil {return os_error(size_error)}
    bytes:=size-len(LEASE_MAGIC)
    if bytes<0 || bytes>LEASE_MAX_HASHES*size_of(Hash) || bytes%size_of(Hash)!=0 {return .None}
    magic:[len(LEASE_MAGIC)]u8
    if read_exact(file,magic[:],0)!=.None || string(magic[:])!=LEASE_MAGIC {return .None}
    hashes,make_error:=make([]Hash,int(bytes/size_of(Hash)),s.state.allocator)
    if make_error!=nil {return .Out_Of_Memory}
    defer delete(hashes,s.state.allocator)
    if read_exact(file,mem.slice_to_bytes(hashes),len(LEASE_MAGIC))!=.None {return .None}
    return live_add(live,hashes)
}
