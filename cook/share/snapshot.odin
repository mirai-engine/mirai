package share

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import importer "mirai:cook/import"
import "mirai:project"
import "mirai:std/jobs"
import "mirai:store"

// A snapshot: the files of a project as a tree of objects of the store. A
// file is an object of its bytes, cut on content, so a changed file shares
// the chunks the change did not touch. A folder is an object whose bytes list
// its entries sorted by name, each a file (with its executable bit) or a
// folder, by the address and size of its object; a folder entry also carries
// the files and bytes under it. The meta of every folder is SNAPSHOT_MAGIC and
// the length of a name, the project's in the root and none below it. Two
// snapshots that differ in one file share every folder off its path. What
// each machine makes (project.own_path) is left out, and a folder holds at
// least one file. The same files give the same tree.
//
// In memory, and as the base a joined folder keeps, a snapshot is its files
// by path, sorted bytewise.

SNAPSHOT_MAGIC :: "mirai snapshot 2\n"
FILES_MAX :: 1<<22          // files of a snapshot
FOLDER_ENTRIES_MAX :: 1<<16 // entries of one folder
DEPTH_MAX :: 64             // folders on the path of a file
PATH_MAX :: 1024            // bytes of a path of a snapshot
NAME_MAX :: 64              // bytes of the name of the project it carries
@(private) RECORD_MAX :: 1+1+255+32+8+4 // kind, name, address, size, files
LISTING_MAX :: FOLDER_ENTRIES_MAX*RECORD_MAX // bytes of the object of one folder

@(private) KIND_FILE :: 0
@(private) KIND_EXECUTABLE :: 1
@(private) KIND_FOLDER :: 2

Entry :: struct {
    path:string,
    address:store.Hash, // of the file's object
    size:i64,
    executable:bool,
}

Snapshot :: struct {
    name:string,     // of the project, the folder a join makes by default
    entries:[]Entry, // sorted by path
}

Snapshot_Error :: enum u8 {
    None,
    Truncated,     // the bytes end before what they say
    Not_Snapshot,  // another magic or meta, bytes after the last entry, an unknown kind
    Too_Large,     // more files, entries of a folder or bytes than the bounds above
    Path,          // a name or path that would leave the folder, is absolute, names a device or the generated folder
    Duplicate,     // two names that name one file where case is folded, or out of order
    Size,          // a size or count out of range or unlike what is under it, or an empty file whose address is not that of no bytes
    Name,          // a name of the project that is not a folder name
    Depth,         // folders nested deeper than DEPTH_MAX
    Cycle,         // a folder inside itself
    Unavailable,   // an object of the tree is not in the store, or could not be fetched
    Out_Of_Memory,
}

// The address of the object of no bytes: an empty file's.
empty_address :: proc() -> store.Hash {
    groups:=[1]store.Group{{}}
    buffer:[size_of(store.Node)+size_of(store.Group)]u8
    bytes,_:=store.node_encode(buffer[:],0,nil,groups[:])
    return store.address_of_bytes(bytes)
}

// An entry of a folder.
@(private)
Item :: struct {
    name:string,
    kind:u8,
    address:store.Hash,
    size:i64,  // a file's bytes; the bytes of the files under a folder
    files:i64, // under a folder
}

// Puts the folders of snap in s, the files' objects being there already:
// the address of its root. Each folder put is added to folders.
snapshot_put :: proc(s:^store.Store,snap:^Snapshot,folders:^[dynamic]store.Hash=nil) -> (root:store.Hash,error:Snapshot_Error,store_error:store.Error) {
    if !name_valid(snap.name) {return {},.Name,.None}
    if len(snap.entries)>FILES_MAX {return {},.Too_Large,.None}
    built:Item
    built,error,store_error=folder_put(s,snap.entries,0,snap.name,folders,0)
    if error==.None && store_error==.None {store_error=store.commit(s)}
    return built.address,error,store_error
}

// The folder of entries, all under the same path of prefix bytes (and a
// slash), with its subfolders put first.
@(private)
folder_put :: proc(s:^store.Store,entries:[]Entry,prefix:int,name:string,folders:^[dynamic]store.Hash,depth:int) -> (folder:Item,error:Snapshot_Error,store_error:store.Error) {
    if depth>DEPTH_MAX {return {},.Depth,.None}
    items:=make([dynamic]Item,context.temp_allocator)
    for i:=0;i<len(entries); {
        e:=&entries[i]
        rest:=e.path[prefix:]
        slash:=strings.index_byte(rest,'/')
        if slash<0 {
            append(&items,Item{name=rest,kind=e.executable?KIND_EXECUTABLE:KIND_FILE,address=e.address,size=e.size})
            i+=1
            continue
        }
        under:=e.path[:prefix+slash+1]
        j:=i+1
        for j<len(entries) && strings.has_prefix(entries[j].path,under) {j+=1}
        child:Item
        child,error,store_error=folder_put(s,entries[i:j],prefix+slash+1,"",folders,depth+1)
        if error!=.None || store_error!=.None {return}
        child.name=rest[:slash]
        append(&items,child)
        i=j
    }
    if len(items)>FOLDER_ENTRIES_MAX {return {},.Too_Large,.None}
    slice.sort_by(items[:],proc(a,b:Item) -> bool {return a.name<b.name})
    for item in items {
        folder.files+=item.kind==KIND_FOLDER?item.files:1
        folder.size+=item.size
    }
    folder.kind=KIND_FOLDER
    p,begin_error:=store.put_begin(s)
    if begin_error!=.None {return {},.None,begin_error}
    buffer:[64<<10]u8
    w:=Writer{data=buffer[:]}
    for item in items {
        if len(buffer)-w.at<RECORD_MAX {
            if store_error=store.put_write(&p,buffer[:w.at]);store_error!=.None {
                store.put_abandon(&p)
                return
            }
            w.at=0
        }
        address:=item.address
        write_uint(&w,u64(item.kind),1)
        write_uint(&w,u64(len(item.name)),1)
        write_bytes(&w,transmute([]u8)item.name)
        write_bytes(&w,address[:])
        write_uint(&w,u64(item.size),8)
        if item.kind==KIND_FOLDER {write_uint(&w,u64(item.files),4)}
    }
    if store_error=store.put_write(&p,buffer[:w.at]);store_error!=.None {
        store.put_abandon(&p)
        return
    }
    meta:[len(SNAPSHOT_MAGIC)+1+NAME_MAX]u8
    copy(meta[:],SNAPSHOT_MAGIC)
    meta[len(SNAPSHOT_MAGIC)]=u8(len(name))
    copy(meta[len(SNAPSHOT_MAGIC)+1:],name)
    folder.address,_,store_error=store.put_finish(&p,meta[:len(SNAPSHOT_MAGIC)+1+len(name)])
    if store_error==.None && folders!=nil {append(folders,folder.address)}
    return
}

// What reading a tree asks before it reads a set of folders, which it reads
// only once the procedure returns true: the joiner fetches them.
Tree_Fetch :: struct {
    procedure:proc(data:rawptr,addresses:[]store.Hash) -> bool,
    data:rawptr,
}

// The name of the project the snapshot at root carries, from the meta of its
// root folder.
snapshot_name :: proc(s:^store.Store,root:store.Hash,allocator:=context.allocator) -> (name:string,error:Snapshot_Error) {
    o,open_error:=store.object_open(s,root)
    if open_error!=.None {return "",open_error==.Missing?.Unavailable:.Not_Snapshot}
    defer store.object_close(&o)
    name=meta_name(store.object_meta(&o),true) or_return
    return strings.clone(name,allocator),.None
}

@(private)
meta_name :: proc(meta:[]u8,root:bool) -> (name:string,error:Snapshot_Error) {
    if len(meta)<len(SNAPSHOT_MAGIC)+1 || string(meta[:len(SNAPSHOT_MAGIC)])!=SNAPSHOT_MAGIC {return "",.Not_Snapshot}
    if int(meta[len(SNAPSHOT_MAGIC)])!=len(meta)-len(SNAPSHOT_MAGIC)-1 {return "",.Not_Snapshot}
    name=string(meta[len(SNAPSHOT_MAGIC)+1:])
    if root && !name_valid(name) {return "",.Name}
    if !root && name!="" {return "",.Not_Snapshot}
    return name,.None
}

// The snapshot whose tree has its root at root, read folder by folder, from
// the root down a depth at a time: fetch, when given, is asked for the folders
// of each depth before they are read. The tree may come from anyone: every
// name, path, kind, size and count is checked, and the files of every folder
// must be those its parent declares, so the files read never exceed
// FILES_MAX. Each folder read is added to folders. In allocator.
snapshot_read :: proc(s:^store.Store,root:store.Hash,fetch:=Tree_Fetch{},folders:^[dynamic]store.Hash=nil,allocator:=context.allocator) -> (snap:Snapshot,error:Snapshot_Error) {
    t:=Tree_Read{
        s=s,
        visits=make([dynamic]Visit,context.temp_allocator),
        entries=make([dynamic]Entry,allocator),
        allocator=allocator,
    }
    append(&t.visits,Visit{address=root,files=-1,parent=-1})
    addresses:=make([dynamic]store.Hash,context.temp_allocator)
    for start:=0;start<len(t.visits); {
        end:=len(t.visits)
        if fetch.procedure!=nil {
            clear(&addresses)
            for v in t.visits[start:end] {append(&addresses,v.address)}
            if !fetch.procedure(fetch.data,addresses[:]) {return {},.Unavailable}
        }
        for k in start..<end {
            folder_read(&t,k) or_return
            if folders!=nil {append(folders,t.visits[k].address)}
        }
        start=end
    }
    slice.sort_by(t.entries[:],proc(a,b:Entry) -> bool {return a.path<b.path})
    snap.name=strings.clone(t.name,allocator)
    snap.entries=t.entries[:]
    return snap,.None
}

@(private)
Visit :: struct {
    path:string,
    address:store.Hash,
    files,size:i64, // declared by its parent; -1: the root
    depth:int,
    parent:int,
}

@(private)
Tree_Read :: struct {
    s:^store.Store,
    visits:[dynamic]Visit,
    entries:[dynamic]Entry,
    name:string,
    allocator:runtime.Allocator,
}

// Reads the folder of visit k: its files join the entries and its folders the
// visits of the next depth.
@(private)
folder_read :: proc(t:^Tree_Read,k:int) -> Snapshot_Error {
    v:=t.visits[k]
    o,open_error:=store.object_open(t.s,v.address)
    #partial switch open_error {
    case .None:
    case .Missing: return .Unavailable
    case .Out_Of_Memory: return .Out_Of_Memory
    case: return .Not_Snapshot
    }
    defer store.object_close(&o)
    name:=meta_name(store.object_meta(&o),v.parent<0) or_return
    if v.parent<0 {t.name=strings.clone(name,context.temp_allocator)}
    total:=store.object_size(&o)
    if total>LISTING_MAX {return .Too_Large}
    if total==0 && v.parent>=0 {return .Size}
    buffer:[64<<10+RECORD_MAX]u8
    r:=Reader{data=buffer[:0]}
    at:u64
    // The name before, kept apart from the buffer, which is refilled.
    previous_bytes:[255]u8
    previous:string
    folded:=make(map[string]bool,context.temp_allocator)
    files,size,count:i64
    empty:=empty_address()
    for {
        // Room for one whole record of any size before it is read.
        if len(r.data)-r.at<RECORD_MAX && at<total {
            left:=len(r.data)-r.at
            copy(buffer[:],r.data[r.at:])
            more:=min(u64(len(buffer)-left),total-at)
            if read_error:=store.object_read(&o,at,buffer[left:][:more]);read_error!=.None {
                return read_error==.Missing?.Unavailable:.Not_Snapshot
            }
            at+=more
            r=Reader{data=buffer[:left+int(more)]}
        }
        if r.at==len(r.data) {break}
        kind:=u8(read_uint(&r,1))
        item_name:=string(read_bytes(&r,int(read_uint(&r,1))))
        address:store.Hash
        copy(address[:],read_bytes(&r,32))
        item_size:=read_uint(&r,8)
        item_files:u64
        if kind==KIND_FOLDER {item_files=read_uint(&r,4)}
        if r.short {return .Truncated}
        if kind>KIND_FOLDER {return .Not_Snapshot}
        count+=1
        if count>FOLDER_ENTRIES_MAX {return .Too_Large}
        if !part_valid(item_name) {return .Path}
        if item_name<=previous && count>1 {return .Duplicate}
        lower:=strings.to_lower(item_name,context.temp_allocator)
        if lower in folded {return .Duplicate}
        folded[lower]=true
        previous=string(previous_bytes[:copy(previous_bytes[:],item_name)])
        path:=v.path==""?strings.clone(item_name,context.temp_allocator):fmt.tprintf("%s/%s",v.path,item_name)
        if !path_valid(path) {return .Path}
        if item_size>u64(max(i64)) || i64(item_size)>max(i64)-size {return .Size}
        size+=i64(item_size)
        if kind!=KIND_FOLDER {
            if item_size==0 && address!=empty {return .Size}
            files+=1
            if v.parent<0 && files>FILES_MAX {return .Too_Large}
            append(&t.entries,Entry{path=strings.clone(path,t.allocator),address=address,size=i64(item_size),executable=kind==KIND_EXECUTABLE})
            continue
        }
        if item_files==0 {return .Size}
        if v.depth+1>DEPTH_MAX {return .Depth}
        for a:=k;a>=0;a=t.visits[a].parent {
            if t.visits[a].address==address {return .Cycle}
        }
        files+=i64(item_files)
        if v.parent<0 && files>FILES_MAX {return .Too_Large}
        append(&t.visits,Visit{path=path,address=address,files=i64(item_files),size=i64(item_size),depth=v.depth+1,parent=k})
    }
    if v.parent>=0 && (files!=v.files || size!=v.size) {return .Size}
    return .None
}

// Whether a path of a snapshot can be written under any folder of any
// system: relative, with forward slashes, no empty, . or .. part, no part
// a system reserves (a device of Windows, a name that ends in a dot or a
// space, a colon, a control character), and not under what is not the
// project's own.
path_valid :: proc(path:string) -> bool {
    if path=="" || len(path)>PATH_MAX || !project.own_path(path) {return false}
    start:=0
    for i in 0..=len(path) {
        if i<len(path) && path[i]!='/' {continue}
        if !part_valid(path[start:i]) {return false}
        start=i+1
    }
    return true
}

@(private)
part_valid :: proc(part:string) -> bool {
    if part=="" || part=="." || part==".." || len(part)>255 {return false}
    for c in transmute([]u8)part {
        switch c {
        case 0..<0x20,0x7f,'/','\\',':','*','?','"','<','>','|': return false
        }
    }
    last:=part[len(part)-1]
    if last=='.' || last==' ' {return false}
    // A device of Windows, also with an extension: CON, PRN, AUX, NUL, COM1-9, LPT1-9.
    stem:=part
    if dot:=strings.index_byte(part,'.');dot>=0 {stem=part[:dot]}
    stem=strings.trim_right(stem," ")
    upper:[4]u8
    if len(stem)==3 || len(stem)==4 {
        for c,i in transmute([]u8)stem {upper[i]=c>='a' && c<='z'?c-'a'+'A':c}
        word:=string(upper[:len(stem)])
        switch word[:3] {
        case "CON","PRN","AUX","NUL": if len(word)==3 {return false}
        case "COM","LPT": if len(word)==4 && word[3]>='1' && word[3]<='9' {return false}
        }
    }
    return true
}

// Whether the project name can be a folder: one valid part, not empty.
name_valid :: proc(name:string) -> bool {
    return name!="" && len(name)<=NAME_MAX && part_valid(name) && name!=".mirai"
}

// No two paths name one file on a system that folds case, and no file is a
// folder of another.
@(private)
distinct_files :: proc(entries:[]Entry,allocator:=context.allocator) -> bool {
    folded:=make(map[string]bool,len(entries),context.temp_allocator)
    for e in entries {
        lower:=strings.to_lower(e.path,context.temp_allocator)
        if lower in folded {return false}
        folded[lower]=false
    }
    for e in entries {
        lower:=strings.to_lower(e.path,context.temp_allocator)
        for at:=strings.last_index_byte(lower,'/');at>0;at=strings.last_index_byte(lower[:at],'/') {
            if lower[:at] in folded {return false}
        }
    }
    return true
}

// The entry of path in a sorted snapshot.
snapshot_find :: proc(snap:^Snapshot,path:string) -> (^Entry,bool) {
    at,found:=slice.binary_search_by(snap.entries,path,proc(e:Entry,path:string) -> slice.Ordering {return slice.cmp(e.path,path)})
    if !found {return nil,false}
    return &snap.entries[at],true
}

// The base a joined folder keeps (<folder>/.mirai/share/snapshot): the
// snapshot its last join took, by path.
@(private) BASE_MAGIC :: "mirai share base 2\n"

snapshot_encode :: proc(snap:Snapshot,allocator:=context.allocator) -> (bytes:[]u8,error:Snapshot_Error) {
    if len(snap.entries)>FILES_MAX {return nil,.Too_Large}
    size:=len(BASE_MAGIC)+2+len(snap.name)+4
    for e in snap.entries {size+=2+len(e.path)+32+8+1}
    made,make_error:=make([]u8,size,allocator)
    if make_error!=nil {return nil,.Out_Of_Memory}
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
        write_uint(&w,u64(e.size),8)
        write_uint(&w,e.executable?1:0,1)
    }
    return made,.None
}

// The base of bytes: every path, size and name is checked, and the paths
// must be sorted and name distinct files. The strings point into bytes.
snapshot_decode :: proc(bytes:[]u8,allocator:=context.allocator) -> (snap:Snapshot,error:Snapshot_Error) {
    r:=Reader{data=bytes}
    magic:=read_bytes(&r,len(BASE_MAGIC))
    if r.short {return {},.Truncated}
    if string(magic)!=BASE_MAGIC {return {},.Not_Snapshot}
    snap.name=string(read_bytes(&r,int(read_uint(&r,2))))
    count:=int(read_uint(&r,4))
    if r.short {return {},.Truncated}
    if !name_valid(snap.name) {return {},.Name}
    if count>FILES_MAX {return {},.Too_Large}
    // Each entry takes at least 44 bytes: a count that the bytes cannot hold is a lie.
    if count>(len(bytes)-r.at)/44 {return {},.Truncated}
    entries,make_error:=make([]Entry,count,allocator)
    if make_error!=nil {return {},.Out_Of_Memory}
    empty:=empty_address()
    for &e in entries {
        e.path=string(read_bytes(&r,int(read_uint(&r,2))))
        copy(e.address[:],read_bytes(&r,32))
        size:=read_uint(&r,8)
        flags:=read_uint(&r,1)
        if r.short {return {},.Truncated}
        if !path_valid(e.path) {return {},.Path}
        if size>u64(max(i64)) || flags>1 || size==0 && e.address!=empty {return {},.Size}
        e.size,e.executable=i64(size),flags==1
    }
    if r.at!=len(bytes) {return {},.Not_Snapshot}
    for k in 1..<len(entries) {
        if entries[k-1].path>=entries[k].path {return {},.Duplicate}
    }
    if !distinct_files(entries,allocator) {return {},.Duplicate}
    snap.entries=entries
    return snap,.None
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
file_put_object :: proc(s:^store.Store,path:string,worker:=jobs.Worker_Ref{}) -> (address:store.Hash,size:i64,error:store.Error) {
    p:=store.put_begin(s,nil,worker) or_return
    Put_Read :: struct {p:^store.Put,error:store.Error}
    put_read:=Put_Read{p=&p}
    ok:bool
    size,ok=file_stream(path,proc(data:rawptr,bytes:[]u8) -> bool {
        r:=(^Put_Read)(data)
        r.error=store.put_write(r.p,bytes)
        return r.error==.None
    },&put_read)
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
file_stream :: proc(path:string,each:proc(data:rawptr,bytes:[]u8) -> bool,data:rawptr) -> (size:i64,ok:bool) {
    file,open_error:=os.open(path)
    if open_error!=nil {return}
    defer os.close(file)
    buffer,make_error:=make([]u8,READ_BYTES,context.temp_allocator)
    if make_error!=nil {return}
    defer delete(buffer,context.temp_allocator)
    for {
        n,read_error:=os.read(file,buffer)
        if n>0 {
            if !each(data,buffer[:n]) {return}
            size+=i64(n)
        }
        if read_error==.EOF || n==0 && read_error==nil {return size,true}
        if read_error!=nil {return}
    }
}

Take_Report :: struct {
    files:int,
    bytes:i64,
    put:int,           // files read into the store now: the others were current
    skipped:[]string,  // what was left out, why and how to share it
}

// The snapshot of the project at root: every file of its own put in s (one
// the index knows unchanged and the store has is not read again), then its
// folders; address is its root. Each folder put is added to folders. Jobs of
// worker, when given, hash and append the chunks of a file. In allocator.
snapshot_take :: proc(s:^store.Store,root,name:string,folders:^[dynamic]store.Hash=nil,worker:=jobs.Worker_Ref{},allocator:=context.allocator) -> (snap:Snapshot,address:store.Hash,report:Take_Report,error:string) {
    index:=index_load(root,allocator)
    // The root read once: each file then asks only what this value knows.
    store.chunk_has(s,{})
    entries:=make([dynamic]Entry,allocator)
    skipped:=make([dynamic]string,allocator)
    todo:=make([dynamic]string,context.temp_allocator)
    append(&todo,"")
    for next:=0;next<len(todo);next+=1 {
        folder:=todo[next]
        listed,list_error:=os.read_all_directory_by_path(folder==""?root:project.path(root,folder,allocator=context.temp_allocator),context.temp_allocator)
        if list_error!=nil {
            append(&skipped,fmt.aprintf("%s: the folder does not read (%v): give this user access to it",folder==""?root:folder,list_error,allocator=allocator))
            continue
        }
        for info in listed {
            relative:=folder==""?strings.clone(info.name,context.temp_allocator):fmt.tprintf("%s/%s",folder,info.name)
            if !project.own_path(relative) {continue}
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
            e,put,put_error:=entry_take(s,&index,root,relative,info,worker,allocator)
            if put_error!=.None {
                if put_error==.Missing {continue}
                append(&skipped,fmt.aprintf("%s: it could not be put in the store at %s (%v): free space there, or close what holds the file",relative,s.root,put_error,allocator=allocator))
                continue
            }
            if put {report.put+=1}
            append(&entries,e)
            report.bytes+=e.size
        }
    }
    slice.sort_by(entries[:],proc(a,b:Entry) -> bool {return a.path<b.path})
    snap={name=name,entries=entries[:]}
    report.files,report.skipped=len(entries),skipped[:]
    if !distinct_files(snap.entries) {
        return snap,{},report,fmt.aprintf("%s has two files whose names differ only in case, which a system that folds case cannot hold: rename one",root,allocator=allocator)
    }
    tree_error:Snapshot_Error
    put_error:store.Error
    address,tree_error,put_error=snapshot_put(s,&snap,folders)
    switch {
    case tree_error==.Too_Large:
        return snap,{},report,fmt.aprintf("%s has more files than a snapshot holds: at most %d, at most %d in one folder, folders at most %d deep",root,FILES_MAX,FOLDER_ENTRIES_MAX,DEPTH_MAX,allocator=allocator)
    case tree_error==.Depth:
        return snap,{},report,fmt.aprintf("%s has folders more than %d deep, which a snapshot does not hold",root,DEPTH_MAX,allocator=allocator)
    case tree_error!=.None:
        return snap,{},report,fmt.aprintf("the snapshot of %s could not be made (%v)",root,tree_error,allocator=allocator)
    case put_error!=.None:
        return snap,{},report,fmt.aprintf("the snapshot could not be put in the store at %s (%v): free space there",s.root,put_error,allocator=allocator)
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
entry_take :: proc(s:^store.Store,index:^Index,root,relative:string,info:os.File_Info,worker:=jobs.Worker_Ref{},allocator:=context.allocator) -> (e:Entry,put:bool,error:store.Error) {
    path:=project.path(root,relative,allocator=context.temp_allocator)
    modified:=time.to_unix_nanoseconds(info.modification_time)
    e=Entry{path=strings.clone(relative,allocator),size=info.size,executable=info.mode&os.Permissions_Execute_All!={}}
    if k,known:=index[relative];known && k.size==info.size && k.modified==modified && store.chunk_here(s,k.address) {
        e.address=k.address
        return
    }
    e.address,e.size=file_put_object(s,path,worker) or_return
    if after,stat_error:=os.stat(path,context.temp_allocator);stat_error==nil && after.size==e.size && after.size==info.size && time.to_unix_nanoseconds(after.modification_time)==modified {
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
