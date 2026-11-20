package store

import "base:intrinsics"
import "base:runtime"
import "core:crypto"
import "core:os"
import "core:sync"
import "core:time"

// A content-addressed store of the machine. Chunks live in append-only packs,
// each appended only by the writer that made it; an object is a tree of chunks
// named by its root; a ref names an address. Several Store values and
// processes share one root: readers take a pack's frames only up to its last
// commit, and an index generation, written only by a sweep, folds the sealed
// packs.

// The first line of the root's LAYOUT file; another one is refused.
LAYOUT :: "mirai store 4\n"
ROOT_MAX :: 1024 // bytes of a root path
NAME_MAX :: 128  // bytes of a ref namespace or name

GRACE :: time.Hour   // a chunk written or touched within it is kept by a sweep
PACK_MAX :: 256<<20  // bytes after which a writer seals its pack and begins another
BATCH_MAX :: 16<<20  // bytes written since the last commit that commit on their own

@(private)
PATH_BYTES :: ROOT_MAX+256

Error :: enum u8 {
    None,
    Missing,            // no chunk, object or ref with that name; from commit: a chunk the batch named went missing beside a sweep, so the batch was dropped and is put again
    Corrupt,            // bytes that do not match their address, or a damaged file of the root
    Invalid_Argument,
    Out_Of_Memory,
    Io,
    No_Space,           // the volume is full, or the user's quota is spent: a sweep or freeing space there lets it go on
    Unsupported_Layout, // a root written by another layout of the store
}

// What an error means for whoever keeps the root, and how to go on.
error_text :: proc(error:Error) -> string {
    switch error {
    case .None: return "no error"
    case .Missing: return "it is not in the store: put or fetch it again"
    case .Corrupt: return "the store holds bytes that do not match their address: a sweep and a scrub drop them, and putting or fetching it again mends it"
    case .Invalid_Argument: return "an argument out of its range"
    case .Out_Of_Memory: return "memory ran out"
    case .Io: return "the file system refused an operation on the store's folder: give this user access to it"
    case .No_Space: return "the volume of the store is full: free space there, or let a sweep remove what is no longer used"
    case .Unsupported_Layout: return "the store was written by another version of Mirai: remove that folder, whose content is fetched or built again, or open another"
    }
    return ""
}

Store :: struct {
    root:string, // owned, without a trailing separator
    allocator:runtime.Allocator, // of root
    state:^State,
    read_index:Maybe(Error),
    retired_scanned:bool,
}

// What a Store value knows of its root, shared by its copies and guarded by
// lock: the packs, the current generation, the chunks and refs of the packs
// the generation does not hold, and its own writer.
@(private)
State :: struct {
    allocator:runtime.Allocator, // the heap: of everything the state holds and the store's own scratch
    lock:sync.Mutex,
    written:sync.Cond, // signalled when a write in flight lands
    packs:[dynamic]Pack,
    pack_index:map[Pack_Id]int,
    generation:Generation,
    table:Table,
    retired:Table, // chunks of the packs of retired/ this value read, only to read what a commit still names
    refs:map[string]Ref_Value, // the newest ref frame of each name in the packs the generation does not hold
    tombs:map[Tomb_Key]struct{},
    touched:map[Hash]i64, // newest Touch of a chunk in the packs the generation does not hold
    writer:Writer,
    stages:[dynamic]^Stage,
    builders:[dynamic]^Object_Writer,
    recent:[dynamic]Recent, // frames other writers committed while a sweep records them
    recording:bool,
    scrub_pack:int,
    scrub_at:int,
    hooks:^Hooks,
    decodes:Codecs, // the codecs this value reads: this build's and a test's hook
    write:u8,       // the codec its puts encode frames with
    hook:Codec_Hook,
    coders:[dynamic]^Coder,
}

// What a test counts and decides of a store's file operations.
@(private)
Hooks :: struct {
    creates,opens,renames,flushes,writes,listings:int,
    limited:bool,
    undeletable:bool, // removing a file fails, as one mapped by a process on Windows
    space:i64, // bytes the volume still takes while limited
    step:proc(data:rawptr,step:Sweep_Step),
    flushing:proc(data:rawptr), // before each flush
    data:rawptr,
}

// Opens the store at root, making its folders the first time.
open :: proc(root:string,allocator:=context.allocator) -> (s:Store,error:Error) {
    trimmed:=root
    for len(trimmed)>1 && (trimmed[len(trimmed)-1]=='/' || trimmed[len(trimmed)-1]=='\\') {trimmed=trimmed[:len(trimmed)-1]}
    if trimmed=="" || len(trimmed)>ROOT_MAX {return {},.Invalid_Argument}
    for c in transmute([]u8)trimmed {
        if c==0 {return {},.Invalid_Argument}
    }
    folder_make(trimmed) or_return
    fresh:=layout_check(trimmed) or_return
    buffer:[PATH_BYTES]u8
    for folder in ([?]string{"packs","index","retired","leases","tmp",SWEEP_FOLDER}) {
        folder_make(join(&buffer,trimmed,folder) or_return) or_return
    }
    if fresh {
        layout_buffer:[PATH_BYTES]u8
        file_write(nil,trimmed,join(&layout_buffer,trimmed,"LAYOUT") or_return,{transmute([]u8)string(LAYOUT)}) or_return
    }
    cloned,clone_error:=make([]u8,len(trimmed),allocator)
    if clone_error!=nil {return {},.Out_Of_Memory}
    copy(cloned,trimmed)
    // The state outlives the calls and crosses the threads of whoever opened
    // the store, whatever allocator it gave: it lives on the heap.
    state,state_error:=new(State,runtime.heap_allocator())
    if state_error!=nil {
        delete(cloned,allocator)
        return {},.Out_Of_Memory
    }
    state.allocator=runtime.heap_allocator()
    s={root=string(cloned),allocator=allocator,state=state}
    state_init(&s)
    sync.mutex_lock(&state.lock)
    error=refresh_locked(&s)
    sync.mutex_unlock(&state.lock)
    if error!=.None {
        state_destroy(&s)
        delete(s.root,allocator)
        return {},error
    }
    return s,.None
}

// Commits what this value wrote, seals its pack and lets the root go.
close :: proc(s:^Store) {
    if s!=nil && s.read_index!=nil {s^={};return}
    if s==nil || s.state==nil {
        if s!=nil {s^={}}
        return
    }
    sync.mutex_lock(&s.state.lock)
    writer_close_locked(s)
    sync.mutex_unlock(&s.state.lock)
    state_destroy(s)
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

// A root holds LAYOUT; one that holds the lowercase layout file of the store
// before packs, or a LAYOUT of another line, is refused. fresh: the root has
// neither, and gets LAYOUT once its folders are made.
@(private)
layout_check :: proc(root:string) -> (fresh:bool,error:Error) {
    buffer:[PATH_BYTES]u8
    path:=join(&buffer,root,"LAYOUT") or_return
    file,open_error:=file_open(path)
    if open_error==nil {
        defer os.close(file)
        read:[len(LAYOUT)+1]u8
        n,_:=os.read_at(file,read[:],0)
        if n!=len(LAYOUT) || string(read[:n])!=LAYOUT {return false,.Unsupported_Layout}
        return false,.None
    }
    if open_error!=.Not_Exist {return false,.Io}
    old_buffer:[PATH_BYTES]u8
    for old in ([?]string{"layout","blobs"}) {
        if os.exists(join(&old_buffer,root,old) or_return) {return false,.Unsupported_Layout}
    }
    return true,.None
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
    return .No_Space if no_space(error) else .Io
}

// Writes chunks to a file of the root's tmp folder, syncs it and renames it to
// path, which then holds all of it or what it held before.
@(private)
file_write :: proc(s:^Store,root,path:string,chunks:[][]u8,modified:Maybe(time.Time)=nil) -> Error {
    temp_buffer:[PATH_BYTES]u8
    temp,file:=temp_create(s,root,&temp_buffer) or_return
    error:Error
    at:i64
    for chunk in chunks {
        if error=io_write_at(s,file,chunk,at);error!=.None {break}
        at+=i64(len(chunk))
    }
    if error==.None {error=io_sync(s,file)}
    os.close(file)
    if when_,ok:=modified.?;ok && error==.None {error=os_error(os.change_times(temp,when_,when_))}
    if error==.None {error=io_rename(s,temp,path)}
    if error!=.None {file_remove(temp)}
    return error
}

// file_write that never replaces path: taken is true when path was there.
@(private)
file_publish :: proc(s:^Store,path:string,chunks:[][]u8) -> (taken:bool,error:Error) {
    temp_buffer:[PATH_BYTES]u8
    temp,file:=temp_create(s,s.root,&temp_buffer) or_return
    at:i64
    for chunk in chunks {
        if error=io_write_at(s,file,chunk,at);error!=.None {break}
        at+=i64(len(chunk))
    }
    if error==.None {error=io_sync(s,file)}
    os.close(file)
    if error==.None {
        if h:=hooks_of(s);h!=nil {h.renames+=1}
        taken,error=rename_new(temp,path)
    }
    if error!=.None || taken {file_remove(temp)}
    return
}

// A new file of the root's tmp folder, open to write; its path is in buffer.
@(private)
temp_create :: proc(s:^Store,root:string,buffer:^[PATH_BYTES]u8) -> (path:string,file:^os.File,error:Error) {
    for _ in 0..<TEMP_ATTEMPTS {
        path=temp_name(root,"write-",buffer) or_return
        created,create_error:=io_create(s,path)
        if create_error==.None {return path,created,.None}
        if create_error!=.Invalid_Argument {return "",nil,create_error}
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

// The file operations a test counts and can refuse as a full volume. A store
// value of nil counts nothing.

// Creates path, which must not exist; Invalid_Argument when it does.
@(private)
io_create :: proc(s:^Store,path:string) -> (^os.File,Error) {
    if h:=hooks_of(s);h!=nil {intrinsics.atomic_add(&h.creates,1)}
    file,error:=file_open(path,{.Read,.Write,.Create,.Excl})
    if error==.Exist {return nil,.Invalid_Argument}
    if error!=nil {return nil,os_error(error)}
    return file,.None
}

@(private)
io_open :: proc(s:^Store,path:string,flags:=os.File_Flags{.Read}) -> (^os.File,Error) {
    if h:=hooks_of(s);h!=nil {intrinsics.atomic_add(&h.opens,1)}
    file,error:=file_open(path,flags)
    if error!=nil {return nil,os_error(error)}
    return file,.None
}

@(private)
io_write_at :: proc(s:^Store,file:^os.File,bytes:[]u8,offset:i64) -> Error {
    if h:=hooks_of(s);h!=nil {
        intrinsics.atomic_add(&h.writes,1)
        if h.limited {
            // The end this write reaches is taken from the volume at once, whatever other threads take.
            size,_:=os.file_size(file)
            grows:=max(offset+i64(len(bytes))-size,0)
            for {
                space:=intrinsics.atomic_load(&h.space)
                if grows>space {return .No_Space}
                if _,ok:=intrinsics.atomic_compare_exchange_strong(&h.space,space,space-grows);ok {break}
            }
        }
    }
    n,error:=os.write_at(file,bytes,offset)
    if error!=nil {return os_error(error)}
    if n!=len(bytes) {return .Io}
    return .None
}

@(private)
io_sync :: proc(s:^Store,file:^os.File) -> Error {
    if h:=hooks_of(s);h!=nil {
        intrinsics.atomic_add(&h.flushes,1)
        if h.flushing!=nil {h.flushing(h.data)}
    }
    return os_error(os.sync(file))
}

@(private)
io_rename :: proc(s:^Store,from,to:string) -> Error {
    if h:=hooks_of(s);h!=nil {intrinsics.atomic_add(&h.renames,1)}
    return os_error(rename_replace(from,to))
}

// Removes path, giving its bytes back to a limited volume.
@(private)
io_remove :: proc(s:^Store,path:string) -> Error {
    h:=hooks_of(s)
    if h!=nil && h.undeletable {return .Io}
    size:i64
    if h!=nil && h.limited {
        if info,error:=os.stat(path,context.temp_allocator);error==nil {size=info.size}
    }
    removed:=file_remove(path)
    if removed!=nil {return os_error(removed)}
    if h!=nil && h.limited {intrinsics.atomic_add(&h.space,size)}
    return .None
}

@(private)
io_list :: proc(s:^Store,path:string) -> ([]os.File_Info,Error) {
    if h:=hooks_of(s);h!=nil {intrinsics.atomic_add(&h.listings,1)}
    entries,error:=os.read_all_directory_by_path(path,s.state.allocator)
    if error!=nil {return nil,os_error(error)}
    return entries,.None
}

@(private)
hooks_of :: proc "contextless" (s:^Store) -> ^Hooks {
    if s==nil || s.state==nil {return nil}
    return s.state.hooks
}
