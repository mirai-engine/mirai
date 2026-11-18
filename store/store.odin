package store

import "base:runtime"
import "core:crypto"
import "core:os"
import "core:time"

// A content-addressed store of the machine: blobs named by their address and
// refs, mutable names of an address. Several Store values and processes share
// one root without locks: every file appears whole through a rename.

// The first line of the root's layout file; another one is refused.
LAYOUT :: "mirai store 2\n"
ROOT_MAX :: 1024 // bytes of a root path
NAME_MAX :: 128  // bytes of a ref namespace or name

@(private)
PATH_BYTES :: ROOT_MAX+256

Error :: enum u8 {
    None,
    Missing,            // no blob, partial blob or ref with that name
    Not_Here_Yet,       // a range of a partial blob whose pieces have not arrived
    Corrupt,            // bytes that do not match their address or table, or a damaged file of the root
    Wrong_Size,         // the last piece of a blob being received matches its table at another length than the size it began with: that size was wrong
    Invalid_Argument,
    Out_Of_Memory,
    Io,
    Unsupported_Layout, // a root written by another layout of the store
}

Store :: struct {
    root:string, // owned, without a trailing separator
    allocator:runtime.Allocator,
}

// Opens the store at root, making its folders the first time.
open :: proc(root:string,allocator:=context.allocator) -> (s:Store,error:Error) {
    trimmed:=root
    for len(trimmed)>1 && (trimmed[len(trimmed)-1]=='/' || trimmed[len(trimmed)-1]=='\\') {trimmed=trimmed[:len(trimmed)-1]}
    if trimmed=="" || len(trimmed)>ROOT_MAX {return {},.Invalid_Argument}
    for c in transmute([]u8)trimmed {
        if c==0 {return {},.Invalid_Argument}
    }
    buffer:[PATH_BYTES]u8
    folder_make(trimmed) or_return
    for folder in ([6]string{"blobs","tables","partial","refs","leases","tmp"}) {
        folder_make(join(&buffer,trimmed,folder) or_return) or_return
    }
    layout_check(trimmed) or_return
    cloned,clone_error:=make([]u8,len(trimmed),allocator)
    if clone_error!=nil {return {},.Out_Of_Memory}
    copy(cloned,trimmed)
    return {root=string(cloned),allocator=allocator},.None
}

close :: proc(s:^Store) {
    delete(s.root,s.allocator)
    s^={}
}

// The root every program of this machine shares: <user data>/Mirai/store, with
// forward slashes; "" when the system has no user data folder.
default_root :: proc(allocator:=context.allocator) -> string {
    data,error:=os.user_data_dir(context.temp_allocator)
    if error!=nil || data=="" {return ""}
    suffix:="/Mirai/store"
    joined,join_error:=make([]u8,len(data)+len(suffix),allocator)
    if join_error!=nil {return ""}
    copy(joined,data)
    copy(joined[len(data):],suffix)
    for &c in joined {
        if c=='\\' {c='/'}
    }
    return string(joined)
}

@(private)
layout_check :: proc(root:string) -> Error {
    buffer:[PATH_BYTES]u8
    path:=join(&buffer,root,"layout") or_return
    file,open_error:=os.open(path)
    if open_error==nil {
        defer os.close(file)
        read:[len(LAYOUT)+1]u8
        n,_:=os.read_at(file,read[:],0)
        size,size_error:=os.file_size(file)
        if size_error!=nil {return .Io}
        if size!=len(LAYOUT) || n!=len(LAYOUT) || string(read[:n])!=LAYOUT {return .Unsupported_Layout}
        return .None
    }
    if open_error!=.Not_Exist {return .Io}
    return file_write(root,path,{transmute([]u8)string(LAYOUT)})
}

// Copies parts joined by '/' into buffer.
@(private)
join :: proc(buffer:^[PATH_BYTES]u8,parts:..string) -> (string,Error) {
    n:=0
    for part,i in parts {
        if i>0 {
            if n>=len(buffer) {return "",.Invalid_Argument}
            buffer[n]='/'
            n+=1
        }
        if len(part)>len(buffer)-n {return "",.Invalid_Argument}
        copy(buffer[n:],part)
        n+=len(part)
    }
    return string(buffer[:n]),.None
}

@(private)
folder_make :: proc(path:string) -> Error {
    if os.is_directory(path) {return .None}
    made:=os.make_directory_all(path)
    if made!=nil && !os.is_directory(path) {return os_error(made)}
    return .None
}

@(private)
os_error :: proc(error:os.Error) -> Error {
    if error==nil {return .None}
    #partial switch e in error {
    case runtime.Allocator_Error:
        return .Out_Of_Memory
    case os.General_Error:
        if e==.Not_Exist {return .Missing}
    }
    return .Io
}

// Writes chunks to a file of the root's tmp folder and renames it to path,
// which then holds all of it or what it held before.
@(private)
file_write :: proc(root,path:string,chunks:[][]u8,modified:Maybe(time.Time)=nil) -> Error {
    temp_buffer:[PATH_BYTES]u8
    temp,file:=temp_create(root,&temp_buffer) or_return
    write_error:Error
    for chunk in chunks {
        if write_error==.None {
            n,error:=os.write(file,chunk)
            write_error=os_error(error)
            if error==nil && n!=len(chunk) {write_error=.Io}
        }
    }
    sync_error:=os.sync(file)
    os.close(file)
    if write_error!=.None || sync_error!=nil {
        os.remove(temp)
        return write_error if write_error!=.None else .Io
    }
    if at,ok:=modified.?;ok {
        if time_error:=os.change_times(temp,at,at);time_error!=nil {
            os.remove(temp)
            return os_error(time_error)
        }
    }
    if os.rename(temp,path)!=nil {
        os.remove(temp)
        return .Io
    }
    return .None
}

// A new file of the root's tmp folder, open to write; its path is in buffer.
@(private)
temp_create :: proc(root:string,buffer:^[PATH_BYTES]u8) -> (path:string,file:^os.File,error:Error) {
    for _ in 0..<TEMP_ATTEMPTS {
        path=temp_name(root,"write-",buffer) or_return
        created,create_error:=os.open(path,{.Read,.Write,.Create,.Excl})
        if create_error==nil {return path,created,.None}
        if create_error!=.Exist {return "",nil,os_error(create_error)}
    }
    return "",nil,.Io
}

// A new folder of the root's tmp folder; its path is in buffer.
@(private)
temp_folder :: proc(root,prefix:string,buffer:^[PATH_BYTES]u8) -> (path:string,error:Error) {
    for _ in 0..<TEMP_ATTEMPTS {
        path=temp_name(root,prefix,buffer) or_return
        made:=os.make_directory(path)
        if made==nil {return path,.None}
        if made!=.Exist {return "",os_error(made)}
    }
    return "",.Io
}

@(private)
TEMP_ATTEMPTS :: 8

// tmp/<prefix><random hex>, random from the system so that processes sharing
// the root do not collide.
@(private)
temp_name :: proc(root,prefix:string,buffer:^[PATH_BYTES]u8) -> (string,Error) {
    random:Hash
    crypto.rand_bytes(random[:16])
    text:[64]u8
    name:[96]u8
    if len(prefix)>len(name)-32 {return "",.Invalid_Argument}
    copy(name[:],prefix)
    copy(name[len(prefix):],hex(random,&text)[:32])
    return join(buffer,root,"tmp",string(name[:len(prefix)+32]))
}
