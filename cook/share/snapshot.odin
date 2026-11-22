package share

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import importer "mirai:cook/import"
import "mirai:project"
import vcs "mirai:kai"
import "mirai:std/jobs"
import "mirai:store"

// A snapshot: the files of a project as a tree of Kai (kai.tree_build), the
// one format of versioning and sharing. What each machine makes
// (project.own_path) is left out, and so are the sources a caller names
// (Built_Sources). The name of the project travels in the offer.
//
// In memory, and as the base a joined folder keeps, a snapshot is its files
// by path, sorted bytewise.

NAME_MAX :: 64 // bytes of the name of the project an offer carries

Snapshot :: struct {
    name:string,         // of the project, the folder a join makes by default
    entries:[]vcs.File,  // sorted by path, each a File or an Executable
}

// Puts the folders of snap in s, the files' objects being there already, and
// commits: the address of its root. Each folder put is added to folders.
snapshot_put :: proc(s:^store.Store,snap:^Snapshot,folders:^[dynamic]store.Hash=nil) -> (root:store.Hash,error:vcs.Error) {
    root=vcs.tree_build(s,snap.entries,folders) or_return
    return root,vcs.store_error(store.commit(s))
}

// What reading a tree asks before it reads a set of folders, which it reads
// only once the procedure returns true: the joiner fetches them.
Tree_Fetch :: struct {
    procedure:proc(data:rawptr,addresses:[]store.Hash) -> bool,
    data:rawptr,
}

// The snapshot of the project name whose tree has its root at root, read
// from the root down: fetch, when given, is asked for the folders the store
// lacks, a depth at a time. The tree may come from anyone: kai.tree_files
// checks every name, size and count against what each parent declares, and
// every file must be the project's own. Each folder read is added to folders.
// In allocator.
snapshot_read :: proc(s:^store.Store,root:store.Hash,name:string,fetch:=Tree_Fetch{},folders:^[dynamic]store.Hash=nil,allocator:=context.allocator) -> (snap:Snapshot,error:vcs.Error) {
    for fetch.procedure!=nil {
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        vcs.tree_files(s,root,nil,context.temp_allocator,missing=&missing) or_return
        if len(missing)==0 {break}
        if !fetch.procedure(fetch.data,missing[:]) {return {},.Missing}
    }
    files:=make([dynamic]vcs.File,allocator)
    vcs.tree_files(s,root,&files,allocator,folders) or_return
    for f in files {
        if f.kind==.Conflict || f.size>u64(max(i64)) || !path_valid(f.path) {return {},.Corrupt}
    }
    return {name=name,entries=files[:]},.None
}

// Whether a path of a snapshot can be written under any folder of any system
// (kai.path_valid) and is the project's own.
path_valid :: proc(path:string) -> bool {
    return vcs.path_valid(path) && project.own_path(path)
}

// Whether the project name can be a folder: one valid part, not empty.
name_valid :: proc(name:string) -> bool {
    return len(name)<=NAME_MAX && vcs.part_valid(name) && name!=".mirai"
}

// The entry of path in a sorted snapshot.
snapshot_find :: proc(snap:^Snapshot,path:string) -> (^vcs.File,bool) {
    at,found:=slice.binary_search_by(snap.entries,path,proc(e:vcs.File,path:string) -> slice.Ordering {return slice.cmp(e.path,path)})
    if !found {return nil,false}
    return &snap.entries[at],true
}

// The base a joined folder keeps (<folder>/.mirai/share/snapshot): the
// snapshot its last join took, by path.
@(private) BASE_MAGIC :: "mirai share base 3\n"

snapshot_encode :: proc(snap:Snapshot,allocator:=context.allocator) -> []u8 {
    size:=len(BASE_MAGIC)+2+len(snap.name)+4
    for e in snap.entries {size+=2+len(e.path)+32+8+1}
    made,make_error:=make([]u8,size,allocator)
    if make_error!=nil {return nil}
    w:=Writer{data=made}
    write_bytes(&w,transmute([]u8)string(BASE_MAGIC))
    write_uint(&w,u64(len(snap.name)),2)
    write_bytes(&w,transmute([]u8)snap.name)
    write_uint(&w,u64(len(snap.entries)),4)
    for e in snap.entries {
        address:=e.address
        write_uint(&w,u64(len(e.path)),2)
        write_bytes(&w,transmute([]u8)e.path)
        write_bytes(&w,address[:])
        write_uint(&w,e.size,8)
        write_uint(&w,u64(e.kind),1)
    }
    return made
}

// The base of bytes, every path, size and name checked; their order and case
// are checked when it is put (snapshot_put). The strings point into bytes.
snapshot_decode :: proc(bytes:[]u8,allocator:=context.allocator) -> (snap:Snapshot,ok:bool) {
    r:=Reader{data=bytes}
    if string(read_bytes(&r,len(BASE_MAGIC)))!=BASE_MAGIC {return}
    name:=string(read_bytes(&r,int(read_uint(&r,2))))
    count:=int(read_uint(&r,4))
    // Each entry takes at least 44 bytes: a count that the bytes cannot hold is a lie.
    if r.short || !name_valid(name) || count>vcs.FILES_MAX || count>(len(bytes)-r.at)/44 {return}
    entries,make_error:=make([]vcs.File,count,allocator)
    if make_error!=nil {return}
    empty:=vcs.empty_address()
    for &e in entries {
        e.path=string(read_bytes(&r,int(read_uint(&r,2))))
        copy(e.address[:],read_bytes(&r,32))
        e.size=read_uint(&r,8)
        kind:=read_uint(&r,1)
        if r.short || !path_valid(e.path) || kind>u64(vcs.Entry_Kind.Executable) || e.size==0 && e.address!=empty {return}
        e.kind=vcs.Entry_Kind(kind)
    }
    if r.at!=len(bytes) {return}
    return {name=name,entries=entries},true
}

// What a machine knows of the files of a folder (<folder>/.mirai/share/index):
// the address of each file as it was when last read or written, by its size and
// modification time, so a file that did not change is not read again.
Known :: struct {size,modified:i64,address:store.Hash}
Index :: map[string]Known

@(private) INDEX_MAGIC :: "mirai share index 2\n"
@(private) SHARE_FOLDER :: "share" // under the generated folder of a project: what sharing keeps on this machine

share_path :: proc(root,name:string,allocator:=context.allocator) -> string {
    return project.path(project.folder_path(root,.Generated,context.temp_allocator),SHARE_FOLDER,name,allocator=allocator)
}

// The index of root, empty when it does not read.
index_load :: proc(root:string,allocator:=context.allocator) -> Index {
    index:=make(Index,allocator)
    data,error:=os.read_entire_file(share_path(root,"index",context.temp_allocator),context.temp_allocator)
    if error!=nil || len(data)<len(INDEX_MAGIC) || string(data[:len(INDEX_MAGIC)])!=INDEX_MAGIC {return index}
    r:=Reader{data=data,at=len(INDEX_MAGIC)}
    for r.at<len(data) {
        path:=string(read_bytes(&r,int(read_uint(&r,2))))
        k:Known
        k.size,k.modified=i64(read_uint(&r,8)),i64(read_uint(&r,8))
        copy(k.address[:],read_bytes(&r,32))
        if r.short {break}
        index[strings.clone(path,allocator)]=k
    }
    return index
}

index_save :: proc(root:string,index:^Index) -> bool {
    size:=len(INDEX_MAGIC)
    for path in index {size+=2+len(path)+48}
    data:=make([]u8,size,context.temp_allocator)
    w:=Writer{data=data}
    write_bytes(&w,transmute([]u8)string(INDEX_MAGIC))
    for path,k in index {
        address:=k.address
        write_uint(&w,u64(len(path)),2)
        write_bytes(&w,transmute([]u8)path)
        write_uint(&w,u64(k.size),8)
        write_uint(&w,u64(k.modified),8)
        write_bytes(&w,address[:])
    }
    return file_save(share_path(root,"index",context.temp_allocator),data)
}

// The address of the file at path, from the index when its size and time are
// the ones it knows; the index learns it otherwise. False when it does not read.
index_address :: proc(index:^Index,relative,path:string) -> (address:store.Hash,size:i64,ok:bool) {
    info,error:=os.stat(path,context.temp_allocator)
    if error!=nil || info.type!=.Regular {return}
    modified:=time.to_unix_nanoseconds(info.modification_time)
    if k,known:=index[relative];known && k.size==info.size && k.modified==modified {return k.address,k.size,true}
    hashed,hashed_size,hashed_ok:=file_address(path)
    if !hashed_ok || hashed_size!=info.size {return}
    index_learn(index,relative,info,hashed)
    return hashed,hashed_size,true
}

// Learns the address of a file whose size and time are those of info, unless
// it was modified too close to now (importer.SETTLED_NANOSECONDS): a change
// within the same time would not be seen.
@(private)
index_learn :: proc(index:^Index,relative:string,info:os.File_Info,address:store.Hash) {
    entry:=Known{size=info.size,modified=time.to_unix_nanoseconds(info.modification_time),address=address}
    if time.to_unix_nanoseconds(time.now())-entry.modified<=importer.SETTLED_NANOSECONDS {return}
    if _,known:=index[relative];known {
        index[relative]=entry
    } else {
        index[strings.clone(relative,index.allocator)]=entry
    }
}

@(private) READ_BYTES :: 1<<20 // of a file read at once

// The address of the object of the file at path, read once and cut as the
// store cuts it, without putting it anywhere.
file_address :: proc(path:string) -> (address:store.Hash,size:i64,ok:bool) {
    w:store.Object_Writer
    if store.object_writer_init(&w,{procedure=proc(data:rawptr,kind:store.Chunk_Kind,address:store.Hash,bytes:[]u8) -> store.Error {return .None}})!=.None {return}
    defer store.object_writer_destroy(&w)
    size,ok=file_stream(path,proc(data:rawptr,bytes:[]u8) -> bool {return store.object_write((^store.Object_Writer)(data),bytes)==.None},&w)
    if !ok {return}
    root,_,error:=store.object_finish(&w)
    return root,size,error==.None
}

// Puts the file at path in s as an object, read once, its chunks hashed and
// appended by jobs of worker when given: its address and the bytes put, which
// are those the file had when the read reached its end.
file_put_object :: proc(
    s:^store.Store,path:string,worker:=jobs.Worker_Ref{},cancel:^bool=nil,
) -> (address:store.Hash,size:i64,error:store.Error) {
    p:=store.put_begin(s,nil,worker) or_return
    Put_Read :: struct {p:^store.Put,error:store.Error}
    put_read:=Put_Read{p=&p}
    ok:bool
    size,ok=file_stream(path,proc(data:rawptr,bytes:[]u8) -> bool {
        r:=(^Put_Read)(data)
        r.error=store.put_write(r.p,bytes)
        return r.error==.None
    },&put_read,cancel)
    if !ok {
        store.put_abandon(&p)
        return {},0,put_read.error!=.None?put_read.error:.Io
    }
    address,_=store.put_finish(&p) or_return
    return address,size,.None
}

// Gives the bytes of the file at path to each in pieces of at most
// READ_BYTES, up to its end: the bytes given. False when it does not read or
// each refuses a piece.
@(private)
file_stream :: proc(
    path:string,each:proc(data:rawptr,bytes:[]u8) -> bool,data:rawptr,cancel:^bool=nil,
) -> (size:i64,ok:bool) {
    file,open_error:=os.open(path)
    if open_error!=nil {return}
    defer os.close(file)
    buffer,make_error:=make([]u8,READ_BYTES,context.temp_allocator)
    if make_error!=nil {return}
    defer delete(buffer,context.temp_allocator)
    for {
        if offer_cancelled(cancel) {return}
        n,read_error:=os.read(file,buffer)
        if n>0 {
            if !each(data,buffer[:n]) {return}
            size+=i64(n)
        }
        if read_error==.EOF || n==0 && read_error==nil {return size,true}
        if read_error!=nil {return}
    }
}

@(private)
OFFER_CANCELLED :: "the project offer was stopped"

@(private)
offer_cancelled :: proc(cancel:^bool) -> bool {return cancel!=nil && sync.atomic_load(cancel)}

Take_Report :: struct {
    files:int,
    bytes:i64,
    put:int,           // files read into the store now: the others were current
    sources:int,       // files and folders left out as the sources of built packages
    skipped:[]string,  // what was left out, why and how to share it
}

// The sources of the packages a project pins whose build the store has whole,
// by path relative to the project in lower case, files and folders: a joiner
// takes their builds from the peers, so a snapshot leaves them out.
Built_Sources :: map[string]bool

// The snapshot of the project at root: every file of its own but built, put in
// s (one the index knows unchanged and the store has is not read again), then
// its folders; address is its root. Each folder put is added to folders. Jobs
// of worker, when given, hash and append the chunks of a file. In allocator.
snapshot_take :: proc(
    s:^store.Store,root,name:string,folders:^[dynamic]store.Hash=nil,
    worker:=jobs.Worker_Ref{},allocator:=context.allocator,cancel:^bool=nil,built:^Built_Sources=nil,
) -> (snap:Snapshot,address:store.Hash,report:Take_Report,error:string) {
    index:=index_load(root,allocator)
    // The root read once: each file then asks only what this value knows.
    store.chunk_has(s,{})
    entries:=make([dynamic]vcs.File,allocator)
    skipped:=make([dynamic]string,allocator)
    todo:=make([dynamic]string,context.temp_allocator)
    append(&todo,"")
    for next:=0;next<len(todo);next+=1 {
        if offer_cancelled(cancel) {return {},{},{},OFFER_CANCELLED}
        folder:=todo[next]
        listed,list_error:=os.read_all_directory_by_path(folder==""?root:project.path(root,folder,allocator=context.temp_allocator),context.temp_allocator)
        if list_error!=nil {
            append(&skipped,fmt.aprintf("%s: the folder does not read (%v): give this user access to it",folder==""?root:folder,list_error,allocator=allocator))
            continue
        }
        for info in listed {
            if offer_cancelled(cancel) {return {},{},{},OFFER_CANCELLED}
            relative:=folder==""?strings.clone(info.name,context.temp_allocator):fmt.tprintf("%s/%s",folder,info.name)
            if !project.own_path(relative) {continue}
            if built!=nil && strings.to_lower(relative,context.temp_allocator) in built {
                report.sources+=1
                continue
            }
            #partial switch info.type {
            case .Directory:
                append(&todo,relative)
                continue
            case .Regular:
            case:
                append(&skipped,fmt.aprintf("%s: a link or a special file is not shared: replace it with the file it points to",relative,allocator=allocator))
                continue
            }
            if !path_valid(relative) {
                append(&skipped,fmt.aprintf("%s: some system cannot write this name (a device of Windows, a colon, a name that ends in a dot or a space): rename it",relative,allocator=allocator))
                continue
            }
            e,put,put_error:=entry_take(s,&index,root,relative,info,worker,allocator,cancel)
            if put_error!=.None {
                if put_error==.Missing {continue}
                append(&skipped,fmt.aprintf("%s: it could not be put in the store at %s (%v): free space there, or close what holds the file",relative,s.root,put_error,allocator=allocator))
                continue
            }
            if put {report.put+=1}
            append(&entries,e)
            report.bytes+=i64(e.size)
        }
    }
    if offer_cancelled(cancel) {return {},{},{},OFFER_CANCELLED}
    slice.sort_by(entries[:],proc(a,b:vcs.File) -> bool {return a.path<b.path})
    snap={name=name,entries=entries[:]}
    report.files,report.skipped=len(entries),skipped[:]
    tree_error:vcs.Error
    address,tree_error=snapshot_put(s,&snap,folders)
    if offer_cancelled(cancel) {return {},{},{},OFFER_CANCELLED}
    #partial switch tree_error {
    case .None:
    case .Invalid_Argument:
        return snap,{},report,fmt.aprintf("%s has two files whose names differ only in case, which a system that folds case cannot hold: rename one",root,allocator=allocator)
    case .Too_Large:
        return snap,{},report,fmt.aprintf("%s has more files than a snapshot holds: at most %d, at most %d in one folder, folders at most %d deep",root,vcs.FILES_MAX,vcs.FOLDER_ENTRIES_MAX,vcs.DEPTH_MAX,allocator=allocator)
    case:
        return snap,{},report,fmt.aprintf("the snapshot could not be put in the store at %s (%v): free space there",s.root,tree_error,allocator=allocator)
    }
    index_save(root,&index)
    return snap,address,report,""
}

// The entry of the file at relative under root, listed with info: its address
// from the index when it knows the file unchanged and s has its object, or put
// in s now. Its size is that of what was put, which a joiner checks against
// the object, also when the file changed after it was listed; the index learns
// it only when the file still has the size and time it was listed with.
@(private)
entry_take :: proc(
    s:^store.Store,index:^Index,root,relative:string,info:os.File_Info,
    worker:=jobs.Worker_Ref{},allocator:=context.allocator,cancel:^bool=nil,
) -> (e:vcs.File,put:bool,error:store.Error) {
    path:=project.path(root,relative,allocator=context.temp_allocator)
    modified:=time.to_unix_nanoseconds(info.modification_time)
    e=vcs.File{path=strings.clone(relative,allocator),size=u64(info.size),kind=info.mode&os.Permissions_Execute_All!={}?.Executable:.File}
    if k,known:=index[relative];known && k.size==info.size && k.modified==modified && store.chunk_here(s,k.address) {
        e.address=k.address
        return
    }
    size:i64
    e.address,size=file_put_object(s,path,worker,cancel) or_return
    e.size=u64(size)
    if after,stat_error:=os.stat(path,context.temp_allocator);stat_error==nil && after.size==size && after.size==info.size && time.to_unix_nanoseconds(after.modification_time)==modified {
        index_learn(index,relative,after,e.address)
    }
    return e,true,.None
}

// Writes data whole at path through a rename, making its folder.
file_save :: proc(path:string,data:[]u8) -> bool {
    folder,_:=os.split_path(path)
    os.make_directory_all(folder)
    temp:=fmt.tprintf("%s.%d.tmp",path,os.get_pid())
    if os.write_entire_file(temp,data)!=nil {
        os.remove(temp)
        return false
    }
    if os.rename(temp,path)!=nil {
        os.remove(temp)
        return false
    }
    return true
}

@(private)
Writer :: struct {data:[]u8,at:int}

@(private)
write_bytes :: proc(w:^Writer,bytes:[]u8) {
    copy(w.data[w.at:],bytes)
    w.at+=len(bytes)
}

@(private)
write_uint :: proc(w:^Writer,value:u64,size:int) {
    for k in 0..<size {w.data[w.at+k]=u8(value>>(8*uint(k)))}
    w.at+=size
}

@(private)
Reader :: struct {data:[]u8,at:int,short:bool}

@(private)
read_bytes :: proc(r:^Reader,count:int) -> []u8 {
    if r.short || count<0 || count>len(r.data)-r.at {
        r.short=true
        return nil
    }
    bytes:=r.data[r.at:][:count]
    r.at+=count
    return bytes
}

@(private)
read_uint :: proc(r:^Reader,size:int) -> (value:u64) {
    bytes:=read_bytes(r,size)
    for b,k in bytes {value|=u64(b)<<(8*uint(k))}
    return
}
