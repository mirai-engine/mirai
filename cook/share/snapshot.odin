package share

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:project"
import "mirai:store"

// A snapshot: the files of a project as one blob of the store, each by its
// path under the root, the address of its bytes, its size and whether it is
// executable. It holds every file under the root that is the project's own
// (project.own_path); what each machine makes is left out. Paths are sorted
// bytewise, so the same files give the same blob.

SNAPSHOT_MAGIC :: "mirai snapshot 1\n"
SNAPSHOT_MAX_BYTES :: 64<<20
SNAPSHOT_MAX_ENTRIES :: 1<<20
PATH_MAX :: 1024        // bytes of a path of a snapshot
NAME_MAX :: 64          // bytes of the name of the project it carries
FILE_MAX_BYTES :: 4<<30 // the largest file shared, and the largest blob a peer takes

Entry :: struct {
    path:string,
    address:store.Hash,
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
    Not_Snapshot,  // another magic, or bytes after the last entry
    Too_Large,     // more bytes or entries than SNAPSHOT_MAX_BYTES or SNAPSHOT_MAX_ENTRIES
    Path,          // a path that would leave the folder, is absolute, names a device or the generated folder
    Duplicate,     // two paths that name one file where case is folded, or a file inside another
    Size,          // a size out of range, or an empty file whose address is not that of no bytes
    Name,          // a name of the project that is not a folder name
    Out_Of_Memory,
}

// The bytes of a snapshot.
snapshot_encode :: proc(snap:Snapshot,allocator:=context.allocator) -> (bytes:[]u8,error:Snapshot_Error) {
    size:=len(SNAPSHOT_MAGIC)+2+len(snap.name)+4
    for e in snap.entries {size+=2+len(e.path)+32+8+1}
    if size>SNAPSHOT_MAX_BYTES || len(snap.entries)>SNAPSHOT_MAX_ENTRIES {return nil,.Too_Large}
    made,make_error:=make([]u8,size,allocator)
    if make_error!=nil {return nil,.Out_Of_Memory}
    w:=Writer{data=made}
    write_bytes(&w,transmute([]u8)string(SNAPSHOT_MAGIC))
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

// The snapshot of bytes, which may come from anyone: every path, size and
// name is checked, and the paths must be sorted and name distinct files. The
// strings point into bytes.
snapshot_decode :: proc(bytes:[]u8,allocator:=context.allocator) -> (snap:Snapshot,error:Snapshot_Error) {
    if len(bytes)>SNAPSHOT_MAX_BYTES {return {},.Too_Large}
    r:=Reader{data=bytes}
    magic:=read_bytes(&r,len(SNAPSHOT_MAGIC))
    if r.short {return {},.Truncated}
    if string(magic)!=SNAPSHOT_MAGIC {return {},.Not_Snapshot}
    snap.name=string(read_bytes(&r,int(read_uint(&r,2))))
    count:=int(read_uint(&r,4))
    if r.short {return {},.Truncated}
    if !name_valid(snap.name) {return {},.Name}
    if count>SNAPSHOT_MAX_ENTRIES {return {},.Too_Large}
    // Each entry takes at least 43 bytes: a count that the bytes cannot hold is a lie.
    if count>(len(bytes)-r.at)/43 {return {},.Truncated}
    entries,make_error:=make([]Entry,count,allocator)
    if make_error!=nil {return {},.Out_Of_Memory}
    empty:=store.address_of_bytes(nil)
    for &e in entries {
        e.path=string(read_bytes(&r,int(read_uint(&r,2))))
        copy(e.address[:],read_bytes(&r,32))
        size:=read_uint(&r,8)
        flags:=read_uint(&r,1)
        if r.short {return {},.Truncated}
        if !path_valid(e.path) {return {},.Path}
        if size>FILE_MAX_BYTES || flags>1 || size==0 && e.address!=empty {return {},.Size}
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
        case 0..<0x20,0x7f,'\\',':','*','?','"','<','>','|': return false
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

// What a machine knows of the files of a folder (<folder>/.mirai/share/index):
// the address of each file as it was when last read or written, by its size and
// modification time, so a file that did not change is not read again.
Known :: struct {size,modified:i64,address:store.Hash}
Index :: map[string]Known

@(private) INDEX_MAGIC :: "mirai share index 1\n"
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
    hashed,hashed_size,hash_error:=store.address_of_file(path,context.temp_allocator)
    if hash_error!=.None || hashed_size!=info.size {return}
    index_learn(index,relative,info,hashed)
    return hashed,hashed_size,true
}

@(private)
index_learn :: proc(index:^Index,relative:string,info:os.File_Info,address:store.Hash) {
    entry:=Known{size=info.size,modified=time.to_unix_nanoseconds(info.modification_time),address=address}
    if _,known:=index[relative];known {
        index[relative]=entry
    } else {
        index[strings.clone(relative,index.allocator)]=entry
    }
}

Take_Report :: struct {
    files:int,
    bytes:i64,
    put:int,           // files read into the store now: the others were current
    skipped:[]string,  // what was left out, why and how to share it
}

// The snapshot of the project at root: every file of its own put in s (one
// the index knows unchanged and the store has is not read again), the
// snapshot itself put as a blob. In allocator.
snapshot_take :: proc(s:^store.Store,root,name:string,allocator:=context.allocator) -> (snap:Snapshot,address:store.Hash,report:Take_Report,error:string) {
    index:=index_load(root,allocator)
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
            if info.size>FILE_MAX_BYTES {
                append(&skipped,fmt.aprintf("%s: %d bytes, more than the %d a file shares: import it into the library, whose builds are shared by key, or split it",relative,info.size,i64(FILE_MAX_BYTES),allocator=allocator))
                continue
            }
            path:=project.path(root,relative,allocator=context.temp_allocator)
            modified:=time.to_unix_nanoseconds(info.modification_time)
            e:=Entry{path=strings.clone(relative,allocator),size=info.size,executable=info.mode&os.Permissions_Execute_All!={}}
            if k,known:=index[relative];known && k.size==info.size && k.modified==modified && store.has(s,k.address) {
                e.address=k.address
            } else {
                hash,put_error:=store.put_file(s,path)
                if put_error!=.None {
                    if put_error==.Missing {continue}
                    append(&skipped,fmt.aprintf("%s: it could not be put in the store at %s (%v): free space there, or close what holds the file",relative,s.root,put_error,allocator=allocator))
                    continue
                }
                e.address=hash
                index_learn(&index,relative,info,hash)
                report.put+=1
            }
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
    bytes,encode_error:=snapshot_encode(snap,context.temp_allocator)
    if encode_error!=.None {
        return snap,{},report,fmt.aprintf("%s has more files than a snapshot holds (%d, at most %d entries in %d bytes)",root,len(entries),SNAPSHOT_MAX_ENTRIES,SNAPSHOT_MAX_BYTES,allocator=allocator)
    }
    put_error:store.Error
    if address,put_error=store.put_bytes(s,bytes);put_error!=.None {
        return snap,{},report,fmt.aprintf("the snapshot could not be put in the store at %s (%v): free space there",s.root,put_error,allocator=allocator)
    }
    index_save(root,&index)
    return snap,address,report,""
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
