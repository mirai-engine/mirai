package kai

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:std/jobs"
import "mirai:store"

// A workspace: a folder whose files are the working copy of one change of a
// repository. What it keeps lives in <root>/.mirai/kai: its state (the
// repository, its id, the tree on disk, a switch under way and the conflicts
// it wrote) and a lock one process holds while it works there. The stat index
// says the address of each file by its size, time and inode, so a snapshot
// hashes only files that changed; a file modified within SETTLED_NANOSECONDS
// of being read is marked racy and hashed again, since a change within the
// same tick of its time would not show. A switch writes the files that differ
// through a temporary file and a rename, and its target is recorded first, so
// one cut midway is finished by the next status or snapshot.

SETTLED_NANOSECONDS :: 2_000_000_000
STATE_FOLDER :: ".mirai/kai"

Stat_Row :: struct #packed {
    size:u64,
    mtime_ns:i64,
    inode:u64,
    address:store.Hash,
    path_at:u32,
    path_len:u16,
    flags:u16, // STAT_EXECUTABLE, STAT_RACY
}

STAT_EXECUTABLE :: u16(1)
STAT_RACY :: u16(2)
@(private) STAT_FLAGS :: STAT_EXECUTABLE|STAT_RACY

Stat_Head :: struct #packed {
    magic:u32,
    version:u16,
    reserved:u16,
    rows:u32,
    pool:u32,
} // + [rows]Stat_Row sorted by path, pool

// The index in memory: rows sorted by path, their paths in pool.
Stat_Index :: struct {
    rows:[dynamic]Stat_Row,
    pool:[dynamic]u8,
}

stat_path :: proc(index:^Stat_Index,row:Stat_Row) -> string {
    return string(index.pool[row.path_at:][:row.path_len])
}

stat_encode :: proc(index:^Stat_Index,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(index.rows)>FILES_MAX {return nil,.Too_Large}
    w:=writer_make(allocator)
    write_value(&w,Stat_Head{magic=KAI_MAGIC,version=VERSION,rows=u32(len(index.rows)),pool=u32(len(index.pool))})
    for row in index.rows {write_value(&w,row)}
    write_bytes(&w,index.pool[:])
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

// The index of bytes into index, checked: paths valid, sorted, inside the pool.
stat_decode :: proc(bytes:[]u8,index:^Stat_Index) -> Error {
    clear(&index.rows)
    clear(&index.pool)
    r:=Reader{data=bytes}
    head:=read_value(&r,Stat_Head)
    if r.short || head.magic!=KAI_MAGIC || head.version!=VERSION || head.reserved!=0 || head.rows>FILES_MAX {return .Corrupt}
    if u64(len(bytes))!=u64(size_of(Stat_Head))+u64(head.rows)*size_of(Stat_Row)+u64(head.pool) {return .Corrupt}
    pool:=bytes[len(bytes)-int(head.pool):]
    if _,e:=append(&index.pool,..pool);e!=nil {return .Out_Of_Memory}
    if reserve(&index.rows,int(head.rows))!=nil {return .Out_Of_Memory}
    empty:=empty_address()
    previous:string
    for k in 0..<int(head.rows) {
        row:=read_value(&r,Stat_Row)
        if row.flags&~STAT_FLAGS!=0 || u64(row.path_at)+u64(row.path_len)>u64(len(pool)) || row.size>u64(max(i64)) {return .Corrupt}
        if row.address=={} || (row.size==0 && row.address!=empty) {return .Corrupt}
        path:=string(pool[row.path_at:][:row.path_len])
        if !path_valid(path) || (k>0 && path<=previous) {return .Corrupt}
        previous=path
        if _,e:=append(&index.rows,row);e!=nil {return .Out_Of_Memory}
    }
    return .None
}

@(private)
stat_find :: proc(index:^Stat_Index,path:string) -> (row:^Stat_Row,found:bool) {
    lo,hi:=0,len(index.rows)
    for lo<hi {
        mid:=(lo+hi)/2
        p:=stat_path(index,index.rows[mid])
        switch {
        case p<path: lo=mid+1
        case p>path: hi=mid
        case: return &index.rows[mid],true
        }
    }
    return nil,false
}

// A conflict a checkout wrote at path: while the file there still has the
// address written (zero: nothing was written and the path is still empty),
// a snapshot keeps the conflict; any edit resolves it.
Materialized :: struct {
    path:string,
    conflict:store.Hash,
    written:store.Hash,
}

State_Head :: struct #packed {
    magic:u32,
    version:u16,
    reserved:u16,
    repo:Repo_Id,
    id:Workspace_Id,
    op:store.Hash,     // the operation whose working copy is on disk
    tree:store.Hash,   // the tree on disk
    target:store.Hash, // the tree a switch under way writes; zero for none
    conflicts:u32,
    pool:u32,
} // + [conflicts]Conflict_Record sorted by path, pool

Conflict_Record :: struct #packed {
    path_at:u32,
    path_len:u16,
    reserved:u16,
    conflict:store.Hash,
    written:store.Hash,
}

Workspace_State :: struct {
    repo:Repo_Id,
    id:Workspace_Id,
    op:store.Hash,
    tree:store.Hash,
    target:store.Hash,
    conflicts:[dynamic]Materialized, // paths in the workspace's allocator
}

state_encode :: proc(st:^Workspace_State,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    slice.sort_by(st.conflicts[:],proc(a,b:Materialized) -> bool {return a.path<b.path})
    pool:=0
    for m in st.conflicts {pool+=len(m.path)}
    w:=writer_make(allocator)
    write_value(&w,State_Head{magic=KAI_MAGIC,version=VERSION,repo=st.repo,id=st.id,op=st.op,tree=st.tree,target=st.target,
        conflicts=u32(len(st.conflicts)),pool=u32(pool)})
    at:=0
    for m in st.conflicts {
        write_value(&w,Conflict_Record{path_at=u32(at),path_len=u16(len(m.path)),conflict=m.conflict,written=m.written})
        at+=len(m.path)
    }
    for m in st.conflicts {write_string(&w,m.path)}
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

// The state of bytes into st; paths in allocator.
state_decode :: proc(bytes:[]u8,st:^Workspace_State,allocator:=context.allocator) -> Error {
    r:=Reader{data=bytes}
    head:=read_value(&r,State_Head)
    if r.short || head.magic!=KAI_MAGIC || head.version!=VERSION || head.reserved!=0 || head.tree=={} || head.op=={} || head.conflicts>FILES_MAX {return .Corrupt}
    if u64(len(bytes))!=u64(size_of(State_Head))+u64(head.conflicts)*size_of(Conflict_Record)+u64(head.pool) {return .Corrupt}
    st.repo,st.id,st.op,st.tree,st.target=head.repo,head.id,head.op,head.tree,head.target
    pool:=bytes[len(bytes)-int(head.pool):]
    previous:string
    for k in 0..<int(head.conflicts) {
        rec:=read_value(&r,Conflict_Record)
        if rec.reserved!=0 || rec.conflict=={} || u64(rec.path_at)+u64(rec.path_len)>u64(len(pool)) {return .Corrupt}
        path:=string(pool[rec.path_at:][:rec.path_len])
        if !path_valid(path) || (k>0 && path<=previous) {return .Corrupt}
        previous=path
        cloned,e:=strings.clone(path,allocator)
        if e!=nil {return .Out_Of_Memory}
        if _,f:=append(&st.conflicts,Materialized{cloned,rec.conflict,rec.written});f!=nil {
            delete(cloned,allocator)
            return .Out_Of_Memory
        }
    }
    return .None
}

// Which paths a workspace tracks besides its own folder .mirai/kai, which it
// never tracks.
Filter :: struct {
    procedure:proc(data:rawptr,path:string) -> bool,
    data:rawptr,
}

Workspace_Options :: struct {
    filter:Filter,
    drivers:[]Driver,
    worker:jobs.Worker_Ref, // hashes changed files in parallel when given
    sibling:string,         // a workspace of the same repository whose clean files a switch clones
    overlay:^Overlay_Routing, // routes private paths into encrypted overlays; nil applies only the deny set
}

Workspace :: struct {
    repo:Repo,
    root:string,
    lock:Lock,
    state:Workspace_State,
    index:Stat_Index,
    touched:[dynamic]string,  // paths the editor reported changed since the last snapshot
    touched_all:bool,         // the touched set is complete: a snapshot stats only those
    options:Workspace_Options,
    cut_after:int,            // a test cuts a switch after this many files; <0 never
    allocator:runtime.Allocator,
}

Snapshot_Report :: struct {
    files:int,
    hashed:int,  // files read and hashed: the others were current in the index
    skipped:int, // links and special files, never tracked
    revision:Revision,
}

@(private)
workspace_init :: proc(w:^Workspace,root:string,options:Workspace_Options,allocator:runtime.Allocator) -> Error {
    w^={options=options,cut_after=-1,allocator=allocator}
    trimmed:=strings.trim_right(root,"/\\")
    cloned,e:=strings.clone(trimmed,allocator)
    if e!=nil {return .Out_Of_Memory}
    w.root=cloned
    w.state.conflicts=make([dynamic]Materialized,allocator)
    w.index.rows=make([dynamic]Stat_Row,allocator)
    w.index.pool=make([dynamic]u8,allocator)
    w.touched=make([dynamic]string,allocator)
    folder:=workspace_path(w,STATE_FOLDER)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return .Io}
    w.lock=lock_take(workspace_path(w,STATE_FOLDER+"/lock")) or_return
    return .None
}

// A new repository whose first workspace is root, with its files as they are
// snapshot into its first change.
workspace_create :: proc(w:^Workspace,root:string,s:^store.Store,identity:Identity,options:=Workspace_Options{},allocator:=context.allocator) -> (error:Error) {
    workspace_init(w,root,options,allocator) or_return
    defer if error!=.None {workspace_close(w)}
    if os.exists(workspace_path(w,STATE_FOLDER+"/workspace")) {return .Invalid_Argument}
    repo_create(&w.repo,s,identity,random_id(Workspace_Id),options.drivers,allocator) or_return
    working:=change_get(s,repo_working(&w.repo),context.temp_allocator) or_return
    w.state.repo,w.state.id,w.state.op,w.state.tree=w.repo.id,w.repo.workspace,w.repo.op,working.tree
    state_save(w) or_return
    _=workspace_snapshot(w) or_return
    return .None
}

// Another workspace of the repository of from at root, an empty folder: a new
// change on the parent of from's working copy, written there.
workspace_add :: proc(w:^Workspace,root:string,from:^Workspace,identity:Identity,options:=Workspace_Options{},allocator:=context.allocator) -> (error:Error) {
    workspace_init(w,root,options,allocator) or_return
    defer if error!=.None {workspace_close(w)}
    s:=from.repo.s
    repo_open(&w.repo,s,from.repo.id,random_id(Workspace_Id),identity,options.drivers,allocator) or_return
    working:=change_get(s,view_workspace(&w.repo.view,from.repo.workspace),context.temp_allocator) or_return
    parent:=len(working.parents)>0 ? working.parents[0] : view_workspace(&w.repo.view,from.repo.workspace)
    revision:=workspace_add_to_view(&w.repo,w.repo.workspace,parent) or_return
    empty:=tree_empty(s) or_return
    w.state.repo,w.state.id,w.state.op,w.state.tree=w.repo.id,w.repo.workspace,w.repo.op,empty
    state_save(w) or_return
    c:=change_get(s,revision,context.temp_allocator) or_return
    return checkout(w,c.tree)
}

// Opens the workspace at root, taking its lock: Locked while another process
// holds it.
workspace_open :: proc(w:^Workspace,root:string,s:^store.Store,identity:Identity,options:=Workspace_Options{},allocator:=context.allocator) -> (error:Error) {
    workspace_init(w,root,options,allocator) or_return
    defer if error!=.None {workspace_close(w)}
    bytes,read_error:=os.read_entire_file(workspace_path(w,STATE_FOLDER+"/workspace"),context.temp_allocator)
    if read_error!=nil {return .Missing}
    state_decode(bytes,&w.state,allocator) or_return
    if e:=repo_open(&w.repo,s,w.state.repo,w.state.id,identity,options.drivers,allocator);e!=.None {return e==.Missing?.Other_Store:e}
    index_load(w)
    return .None
}

workspace_close :: proc(w:^Workspace) {
    if w.repo.s!=nil {repo_close(&w.repo)}
    for m in w.state.conflicts {delete(m.path,w.allocator)}
    delete(w.state.conflicts)
    delete(w.index.rows)
    delete(w.index.pool)
    for p in w.touched {delete(p,w.allocator)}
    delete(w.touched)
    lock_release(&w.lock)
    delete(w.root,w.allocator)
    w^={}
}

// Records paths an editor changed, so the next snapshot with complete set
// stats only those: O(changed paths), no scan.
workspace_touched :: proc(w:^Workspace,paths:[]string,complete:=true) -> Error {
    for p in paths {
        cloned,e:=strings.clone(p,w.allocator)
        if e!=nil {return .Out_Of_Memory}
        if _,f:=append(&w.touched,cloned);f!=nil {
            delete(cloned,w.allocator)
            return .Out_Of_Memory
        }
    }
    w.touched_all=complete
    return .None
}

@(private)
workspace_path :: proc(w:^Workspace,relative:string) -> string {
    return strings.concatenate({w.root,"/",relative},context.temp_allocator)
}

@(private)
state_save :: proc(w:^Workspace) -> Error {
    bytes:=state_encode(&w.state,context.temp_allocator) or_return
    return file_replace(workspace_path(w,STATE_FOLDER+"/workspace"),bytes,false)
}

@(private)
index_ref :: proc(w:^Workspace,buffer:^[64]u8) -> string {
    copy(buffer[:],"index-")
    id:=w.repo.workspace
    return string(buffer[:6+len(hex_text(id[:],buffer[6:]))])
}

// The stat index this workspace last saved; empty when it does not read.
@(private)
index_load :: proc(w:^Workspace) {
    buffer:[64]u8
    address,e:=store.ref_get(w.repo.s,w.repo.namespace,index_ref(w,&buffer))
    if e!=.None {return}
    bytes,f:=object_get(w.repo.s,address,.Stat_Index,context.temp_allocator)
    if f!=.None || stat_decode(bytes,&w.index)!=.None {
        clear(&w.index.rows)
        clear(&w.index.pool)
    }
}

@(private)
index_save :: proc(w:^Workspace) -> Error {
    bytes:=stat_encode(&w.index,context.temp_allocator) or_return
    address:=object_put(w.repo.s,.Stat_Index,bytes) or_return
    buffer:[64]u8
    return store_error(store.ref_set(w.repo.s,w.repo.namespace,index_ref(w,&buffer),address))
}

// A file found on disk.
@(private)
Found :: struct {
    path:string,
    size:u64,
    mtime_ns:i64,
    inode:u64,
    executable:bool,
    address:store.Hash,
    hash:bool,  // to be read and hashed
    racy:bool,
    error:Error,
}

// Records what the files are now as this workspace's working copy: only the
// files that changed are read, hashed and put. A switch cut midway is finished
// first.
workspace_snapshot :: proc(w:^Workspace) -> (report:Snapshot_Report,error:Error) {
    recover(w) or_return
    repo_refresh(&w.repo) or_return
    found:=make([dynamic]Found,context.temp_allocator)
    now:=time.now()._nsec
    if w.touched_all && len(w.index.rows)>0 {
        touched_scan(w,&found,&report) or_return
    } else {
        folder_scan(w,"",0,&found,&report) or_return
    }
    for p in w.touched {delete(p,w.allocator)}
    clear(&w.touched)
    w.touched_all=false
    slice.sort_by(found[:],proc(a,b:Found) -> bool {return a.path<b.path})
    plan:Overlay_Plan
    defer overlay_plan_end(&plan)
    overlay_route(w.options.overlay,w.repo.s,w.root,overlay_previous(&w.repo),&found,&plan) or_return
    // Reuse what the index knows; hash the rest, in parallel when a worker is given.
    changed:=make([dynamic]^Found,context.temp_allocator)
    for &f in found {
        row,known:=stat_find(&w.index,f.path)
        if known && row.flags&STAT_RACY==0 && row.size==f.size && row.mtime_ns==f.mtime_ns && row.inode==f.inode && (row.flags&STAT_EXECUTABLE!=0)==f.executable {
            f.address=row.address
            continue
        }
        f.hash=true
        if _,e:=append(&changed,&f);e!=nil {return report,.Out_Of_Memory}
    }
    hash_files(w,changed[:])
    for f in changed {
        if f.error!=.None {return report,f.error}
    }
    report.hashed=len(changed)
    report.files=len(found)
    // The new index; a file modified too close to now is hashed again next time.
    clear(&w.index.rows)
    clear(&w.index.pool)
    files:=make([dynamic]File,context.temp_allocator)
    for f in found {
        flags:=f.executable ? STAT_EXECUTABLE : 0
        if f.racy || now-f.mtime_ns<=SETTLED_NANOSECONDS {flags|=STAT_RACY}
        at:=len(w.index.pool)
        if _,e:=append(&w.index.pool,f.path);e!=nil {return report,.Out_Of_Memory}
        row:=Stat_Row{size=f.size,mtime_ns=f.mtime_ns,inode=f.inode,address=f.address,path_at=u32(at),path_len=u16(len(f.path)),flags=flags}
        if _,e:=append(&w.index.rows,row);e!=nil {return report,.Out_Of_Memory}
        if _,e:=append(&files,File{path=f.path,kind=f.executable?.Executable:.File,address=f.address,size=f.size});e!=nil {return report,.Out_Of_Memory}
    }
    conflicts_apply(w,&files) or_return
    root:=tree_build(w.repo.s,files[:]) or_return
    report.revision=change_snapshot(&w.repo,root) or_return
    overlay_publish(w.options.overlay,w.repo.s,&plan,report.revision) or_return
    index_save(w) or_return
    w.state.op,w.state.tree=w.repo.op,root
    state_save(w) or_return
    return report,.None
}

// Keeps each conflict whose path still holds what the checkout wrote; drops
// the ones an edit resolved.
@(private)
conflicts_apply :: proc(w:^Workspace,files:^[dynamic]File) -> Error {
    for k:=0;k<len(w.state.conflicts); {
        m:=w.state.conflicts[k]
        at,found:=slice.binary_search_by(files[:],m.path,proc(f:File,path:string) -> slice.Ordering {return slice.cmp(f.path,path)})
        under:=false
        prefix:=strings.concatenate({m.path,"/"},context.temp_allocator)
        for i in at..<len(files) {
            if found && i==at {continue}
            if strings.has_prefix(files[i].path,prefix) {under=true}
            break
        }
        kept:=!under && (found ? files[at].address==m.written && m.written!={} : m.written=={})
        if !kept {
            delete(m.path,w.allocator)
            ordered_remove(&w.state.conflicts,k)
            continue
        }
        entry:=File{path=m.path,kind=.Conflict,address=m.conflict}
        if found {
            files[at]=entry
        } else {
            if _,e:=inject_at(files,at,entry);e!=nil {return .Out_Of_Memory}
        }
        k+=1
    }
    return .None
}

@(private)
own_path :: proc(w:^Workspace,relative:string) -> bool {
    if relative==".mirai/kai" || strings.has_prefix(relative,".mirai/kai/") {return false}
    if w.options.filter.procedure!=nil {return w.options.filter.procedure(w.options.filter.data,relative)}
    return true
}

@(private)
folder_scan :: proc(w:^Workspace,folder:string,depth:int,out:^[dynamic]Found,report:^Snapshot_Report) -> Error {
    if depth>DEPTH_MAX {return .Too_Large}
    listed,e:=os.read_all_directory_by_path(folder=="" ? w.root : workspace_path(w,folder),context.temp_allocator)
    if e!=nil {return .Io}
    for info in listed {
        relative:=folder=="" ? info.name : strings.concatenate({folder,"/",info.name},context.temp_allocator)
        if !own_path(w,relative) {continue}
        #partial switch info.type {
        case .Directory:
            folder_scan(w,relative,depth+1,out,report) or_return
        case .Regular:
            if !path_valid(relative) {
                report.skipped+=1
                continue
            }
            if _,f:=append(out,found_of(relative,info));f!=nil {return .Out_Of_Memory}
        case:
            report.skipped+=1
        }
    }
    return .None
}

@(private)
found_of :: proc(relative:string,info:os.File_Info) -> Found {
    return {path=relative,size=u64(max(info.size,0)),mtime_ns=time.to_unix_nanoseconds(info.modification_time),inode=u64(info.inode),
        executable=info.mode&os.Permissions_Execute_All!={}}
}

// The files of the index with only the touched paths stated again.
@(private)
touched_scan :: proc(w:^Workspace,out:^[dynamic]Found,report:^Snapshot_Report) -> Error {
    for row in w.index.rows {
        path:=stat_path(&w.index,row)
        hit:=false
        for t in w.touched {
            if path==t || (strings.has_prefix(path,t) && len(path)>len(t) && path[len(t)]=='/') {hit=true;break}
        }
        if hit {continue}
        f:=Found{path=path,size=row.size,mtime_ns=row.mtime_ns,inode=row.inode,executable=row.flags&STAT_EXECUTABLE!=0}
        if _,e:=append(out,f);e!=nil {return .Out_Of_Memory}
    }
    for t,k in w.touched {
        if slice.contains(w.touched[:k],t) || !own_path(w,t) || !path_valid(t) {continue}
        info,e:=os.lstat(workspace_path(w,t),context.temp_allocator)
        if e!=nil {continue}
        #partial switch info.type {
        case .Directory:
            folder_scan(w,t,strings.count(t,"/")+1,out,report) or_return
        case .Regular:
            path,f:=strings.clone(t,context.temp_allocator)
            if f!=nil {return .Out_Of_Memory}
            if _,g:=append(out,found_of(path,info));g!=nil {return .Out_Of_Memory}
        case:
            report.skipped+=1
        }
    }
    // A path touched inside a touched folder is listed twice.
    slice.sort_by(out[:],proc(a,b:Found) -> bool {return a.path<b.path})
    for k:=1;k<len(out); {
        if out[k].path==out[k-1].path {ordered_remove(out,k);continue}
        k+=1
    }
    return .None
}

@(private)
Hash_Job :: struct {
    w:^Workspace,
    files:[]^Found,
}

// Reads and puts each file, in parallel over the jobs of the workspace's
// worker when it has one.
@(private)
hash_files :: proc(w:^Workspace,files:[]^Found) {
    job:=Hash_Job{w,files}
    run :: proc(job:^Hash_Job,first,last:int,worker:int) {
        for k in first..<last {
            f:=job.files[k]
            path:=strings.concatenate({job.w.root,"/",f.path},context.temp_allocator)
            size:u64
            f.address,size,f.error=file_put(job.w.repo.s,path)
            if f.error!=.None {continue}
            // A file that changed while it was read is read again next time.
            if size!=f.size {f.racy=true}
            f.size=size
            if info,e:=os.lstat(path,context.temp_allocator);e!=nil || u64(info.size)!=size || time.to_unix_nanoseconds(info.modification_time)!=f.mtime_ns {f.racy=true}
        }
    }
    if w.options.worker.system!=nil && len(files)>1 {
        jobs.parallel_for(w.options.worker.system,w.options.worker.worker,len(files),1,run,&job)
    } else {
        run(&job,0,len(files),0)
    }
}

@(private) READ_BYTES :: 1<<20

// Puts the file at path as an object, read once: its address and the bytes put.
file_put :: proc(s:^store.Store,path:string) -> (address:store.Hash,size:u64,error:Error) {
    file,open_error:=os.open(path)
    if open_error!=nil {return {},0,.Io}
    defer os.close(file)
    buffer,made:=make([]u8,READ_BYTES,context.temp_allocator)
    if made!=nil {return {},0,.Out_Of_Memory}
    p,begin:=store.put_begin(s)
    if begin!=.None {return {},0,store_error(begin)}
    for {
        n,read_error:=os.read(file,buffer)
        if n>0 {
            if e:=store.put_write(&p,buffer[:n]);e!=.None {
                store.put_abandon(&p)
                return {},0,store_error(e)
            }
            size+=u64(n)
        }
        if read_error==.EOF || (n==0 && read_error==nil) {break}
        if read_error!=nil {
            store.put_abandon(&p)
            return {},0,.Io
        }
    }
    a,_,e:=store.put_finish(&p)
    return a,size,store_error(e)
}

// Writes bytes at path whole through a temporary file and a rename.
@(private)
file_replace :: proc(path:string,bytes:[]u8,executable:bool) -> Error {
    temp:=temp_path(path)
    perm:=os.Permissions_Read_All+{.Write_User}
    if executable {perm+=os.Permissions_Execute_All}
    if os.write_entire_file(temp,bytes,perm)!=nil {
        os.remove(temp)
        return .Io
    }
    if os.rename(temp,path)!=nil {
        os.remove(temp)
        return .Io
    }
    return .None
}

@(private)
temp_path :: proc(path:string) -> string {
    id:=random_id([8]u8)
    buffer:[16]u8
    return strings.concatenate({path,".",hex_text(id[:],buffer[:]),".kai-tmp"},context.temp_allocator)
}

// Writes the object at address to path through a temporary file and a rename,
// cloning the file of a sibling workspace when it holds the same bytes.
@(private)
file_write_object :: proc(w:^Workspace,address:store.Hash,path:string,relative:string,executable:bool) -> Error {
    if dir,_:=os.split_path(path);dir!="" {
        if os.make_directory_all(dir)!=nil && !os.is_dir(dir) {return .Io}
    }
    temp:=temp_path(path)
    if sibling_clone(w,relative,address,temp) {
        if os.rename(temp,path)==nil {return .None}
        os.remove(temp)
    }
    o,open:=store.object_open(w.repo.s,address)
    if open!=.None {return store_error(open)}
    defer store.object_close(&o)
    perm:=os.Permissions_Read_All+{.Write_User}
    if executable {perm+=os.Permissions_Execute_All}
    file,e:=os.open(temp,{.Write,.Create,.Trunc},perm)
    if e!=nil {return .Io}
    buffer,made:=make([]u8,READ_BYTES,context.temp_allocator)
    if made!=nil {
        os.close(file)
        os.remove(temp)
        return .Out_Of_Memory
    }
    total:=store.object_size(&o)
    failed:Error
    for at:=u64(0);at<total; {
        n:=min(u64(len(buffer)),total-at)
        if r:=store.object_read(&o,at,buffer[:n]);r!=.None {failed=store_error(r);break}
        if written,f:=os.write(file,buffer[:n]);f!=nil || written!=int(n) {failed=.Io;break}
        at+=n
    }
    os.close(file)
    if failed==.None && os.rename(temp,path)!=nil {failed=.Io}
    if failed!=.None {os.remove(temp)}
    return failed
}

// Clones the file at relative of the sibling workspace into temp when the
// sibling's index says it holds address and is settled.
@(private)
sibling_clone :: proc(w:^Workspace,relative:string,address:store.Hash,temp:string) -> bool {
    if w.options.sibling=="" {return false}
    path:=strings.concatenate({w.options.sibling,"/",relative},context.temp_allocator)
    info,e:=os.lstat(path,context.temp_allocator)
    if e!=nil || info.type!=.Regular {return false}
    // The sibling's own file must still be what it was hashed as: check its bytes' address.
    a,_,f:=file_address(path)
    if f!=.None || a!=address {return false}
    return file_clone(path,temp)==.None
}

// The address of the file at path as a put would name it, without putting it.
file_address :: proc(path:string) -> (address:store.Hash,size:u64,error:Error) {
    wr:store.Object_Writer
    if store.object_writer_init(&wr,{procedure=proc(data:rawptr,kind:store.Chunk_Kind,address:store.Hash,bytes:[]u8) -> store.Error {return .None}})!=.None {return {},0,.Out_Of_Memory}
    defer store.object_writer_destroy(&wr)
    file,open_error:=os.open(path)
    if open_error!=nil {return {},0,.Io}
    defer os.close(file)
    buffer,made:=make([]u8,READ_BYTES,context.temp_allocator)
    if made!=nil {return {},0,.Out_Of_Memory}
    for {
        n,read_error:=os.read(file,buffer)
        if n>0 {
            if store.object_write(&wr,buffer[:n])!=.None {return {},0,.Out_Of_Memory}
            size+=u64(n)
        }
        if read_error==.EOF || (n==0 && read_error==nil) {break}
        if read_error!=nil {return {},0,.Io}
    }
    root,_,e:=store.object_finish(&wr)
    return root,size,store_error(e)
}

// Finishes a switch a cut stopped midway: true when there was one.
@(private)
recover :: proc(w:^Workspace) -> (recovered:bool,error:Error) {
    if w.state.target=={} {return false,.None}
    checkout(w,w.state.target) or_return
    return true,.None
}

// Writes the files that differ from the tree on disk to target: the target is
// saved first, so a cut midway is finished by recover.
@(private)
checkout :: proc(w:^Workspace,target:store.Hash) -> Error {
    w.state.target=target
    state_save(w) or_return
    changes:=make([dynamic]Diff,context.temp_allocator)
    tree_diff(w.repo.s,w.state.tree,target,&changes,context.temp_allocator) or_return
    content:=make([dynamic]u8,context.temp_allocator)
    written:=0
    now:=time.now()._nsec
    for d in changes {
        if w.cut_after>=0 && written>=w.cut_after {return .Io}
        path:=workspace_path(w,d.path)
        // A conflict this path held is replaced.
        for m,k in w.state.conflicts {
            if m.path!=d.path {continue}
            delete(m.path,w.allocator)
            ordered_remove(&w.state.conflicts,k)
            break
        }
        address:=d.after.address
        executable:=d.after.kind==.Executable
        switch {
        case address=={}:
            if e:=os.remove(path);e!=nil && os.exists(path) {return .Io}
            folders_prune(w,d.path)
        case d.after.kind==.Conflict:
            kind,has,e:=conflict_materialize(&w.repo.merger,address,d.path,&content)
            if e!=.None {return e}
            m:=Materialized{conflict=address}
            if has {
                if dir,_:=os.split_path(path);dir!="" {
                    if os.make_directory_all(dir)!=nil && !os.is_dir(dir) {return .Io}
                }
                file_replace(path,content[:],kind==.Executable) or_return
                put,f:=store.put(w.repo.s,content[:])
                if f!=.None {return store_error(f)}
                m.written=put
            } else if os.exists(path) && !os.is_dir(path) {
                os.remove(path)
            }
            cloned,f:=strings.clone(d.path,w.allocator)
            if f!=nil {return .Out_Of_Memory}
            m.path=cloned
            if _,g:=append(&w.state.conflicts,m);g!=nil {
                delete(cloned,w.allocator)
                return .Out_Of_Memory
            }
        case:
            if os.is_dir(path) {
                if os.remove_all(path)!=nil {return .Io}
            }
            file_write_object(w,address,path,d.path,executable) or_return
        }
        written+=1
        index_update(w,d.path,address,d.after.kind,now) or_return
    }
    w.state.tree,w.state.target,w.state.op=target,{},w.repo.op
    index_save(w) or_return
    return state_save(w)
}

// Removes the folders a deleted file leaves empty.
@(private)
folders_prune :: proc(w:^Workspace,relative:string) {
    rest:=relative
    for {
        slash:=strings.last_index_byte(rest,'/')
        if slash<0 {return}
        rest=rest[:slash]
        listed,e:=os.read_all_directory_by_path(workspace_path(w,rest),context.temp_allocator)
        if e!=nil || len(listed)>0 {return}
        os.remove(workspace_path(w,rest))
    }
}

// Updates the row of a file a checkout wrote: racy, since it was written now.
@(private)
index_update :: proc(w:^Workspace,relative:string,address:store.Hash,kind:Entry_Kind,now:i64) -> Error {
    row,known:=stat_find(&w.index,relative)
    if address=={} || kind==.Conflict {
        if known {
            at:=(uintptr(row)-uintptr(raw_data(w.index.rows)))/size_of(Stat_Row)
            ordered_remove(&w.index.rows,int(at))
        }
        return .None
    }
    info,e:=os.lstat(workspace_path(w,relative),context.temp_allocator)
    if e!=nil {return .Io}
    updated:=Stat_Row{size=u64(info.size),mtime_ns=time.to_unix_nanoseconds(info.modification_time),inode=u64(info.inode),address=address,flags=STAT_RACY}
    if kind==.Executable {updated.flags|=STAT_EXECUTABLE}
    if known {
        updated.path_at,updated.path_len=row.path_at,row.path_len
        row^=updated
        return .None
    }
    updated.path_at,updated.path_len=u32(len(w.index.pool)),u16(len(relative))
    if _,f:=append(&w.index.pool,relative);f!=nil {return .Out_Of_Memory}
    at:=0
    for at<len(w.index.rows) && stat_path(&w.index,w.index.rows[at])<relative {at+=1}
    if _,f:=inject_at(&w.index.rows,at,updated);f!=nil {return .Out_Of_Memory}
    _=now
    return .None
}

// Makes revision this workspace's working copy and writes its files, after a
// snapshot keeps what was on disk.
workspace_switch :: proc(w:^Workspace,revision:Revision) -> Error {
    workspace_snapshot(w) or_return
    c:=change_get(w.repo.s,revision,context.temp_allocator) or_return
    tx:=tx_begin(&w.repo) or_return
    workspace_point(&tx,w.repo.workspace,revision) or_return
    tx_commit(&tx,.Workspace,"switch workspace") or_return
    return checkout(w,c.tree)
}

// A new empty change on parents as this workspace's working copy, written.
workspace_new :: proc(w:^Workspace,parents:[]Revision,description:="") -> (revision:Revision,error:Error) {
    workspace_snapshot(w) or_return
    revision=change_new(&w.repo,parents,description) or_return
    c:=change_get(w.repo.s,revision,context.temp_allocator) or_return
    checkout(w,c.tree) or_return
    return
}

// Writes the working copy's tree again over the files that differ from it:
// what an undo or another workspace changed in the view.
workspace_update :: proc(w:^Workspace) -> Error {
    recover(w) or_return
    working:=repo_working(&w.repo)
    if working=={} {return .Stale}
    c:=change_get(w.repo.s,working,context.temp_allocator) or_return
    if c.tree==w.state.tree {return .None}
    return checkout(w,c.tree)
}

Status :: struct {
    recovered:bool,    // a switch a cut stopped was finished
    revision:Revision, // the working copy
    conflicts:u32,
    changes:[dynamic]Diff, // what the working copy changed from its parents
    report:Snapshot_Report,
}

// Finishes a switch cut midway, snapshots and says what the working copy
// changed; changes in allocator.
workspace_status :: proc(w:^Workspace,allocator:=context.allocator) -> (status:Status,error:Error) {
    status.recovered=recover(w) or_return
    status.report=workspace_snapshot(w) or_return
    status.revision=status.report.revision
    c:=change_get(w.repo.s,status.revision,context.temp_allocator) or_return
    totals:=tree_totals(w.repo.s,c.tree) or_return
    status.conflicts=totals.conflicts
    base:=parents_tree(&w.repo,c.parents) or_return
    status.changes=make([dynamic]Diff,allocator)
    tree_diff(w.repo.s,base,c.tree,&status.changes,allocator) or_return
    return
}
