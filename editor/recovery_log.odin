package editor

import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:core"
import "mirai:editor/history"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"

// The recovery log: what each step, undo or redo of the document left in its
// rows, appended to a file of the project as the journal takes it, so that a
// crash loses no step done. The rows go by Id, as collaboration sends them
// (collab_ops_pack), and a start after a crash puts them back over a base:
// the copy of recovery (autosave.scene, the periodic copy that bounds what is
// put back) or the saved file of the document when the log began with it
// clean. Neither writes over an asset: what is not saved stays out of the
// project until Save.
//
// A log is a chain of generations, <Generated>/autosave-<slot>-<n>.log, each a
// header (with the layout of every table it logs, so that a start on another
// build converts the rows by the names of their fields) and records of the bytes of an Edit message with their size and CRC:
// a copy names the generation that follows it, a new copy makes the older
// generations useless, and a record cut by a crash ends the chain. Writes
// reach the operating system as the steps are done; the disk, within
// RECOVERY_LOG_SYNC, in a job. Each document has its chain, under its slot.

RECOVERY_LOG_SYNC :: u64(100_000_000)        // ns
RECOVERY_COPY_INTERVAL :: u64(60_000_000_000) // ns: a copy follows a change it lacks after this
RECOVERY_LOG_BYTES :: 16<<20                 // a log of the copy this long asks for a copy at once
@(private) RECOVERY_LOG_MAGIC :: u32(0x4c52494d)
@(private) RECOVERY_LOG_VERSION :: u32(3)

// What a generation follows: a copy of recovery that names it, or the saved file of the document.
Recovery_Base :: enum u8 {Copy,Source}

Recovery_Log :: struct {
    file:^os.File,
    generation:u64,      // of the file written
    base:Recovery_Base,  // of the chain
    world:rawptr,        // the history the chain follows: World, epoch and layout
    epoch:u64,
    info:^core.World_Info,
    following,keep:bool, // keep: the next history continues the chain (a recovery took it)
    bytes:int,           // written since the last copy
    since:u64,           // ns of the first change no copy holds; 0: none
    records:int,         // of the chain since its base
    sync_due:u64,        // ns: when what was written goes to the disk; 0: nothing to
    sync:Recovery_Sync,
    failed:bool,          // a write failed: the copies go back to every second
}

@(private)
Recovery_Sync :: struct {busy:bool,file:^os.File,error:os.Error,counter:jobs.Counter}

@(private)
recovery_log_path :: proc(s:^Session,slot:int,generation:u64) -> string {
    return project.path(project.folder_path(s.project_root,.Generated,context.temp_allocator),fmt.tprintf("autosave-%d-%d.log",slot,generation),allocator=context.temp_allocator)
}

// The generations of the log of a slot, in order.
@(private)
recovery_log_generations :: proc(s:^Session,slot:int) -> []u64 {
    found:=make([dynamic]u64,context.temp_allocator)
    folder:=project.folder_path(s.project_root,.Generated,context.temp_allocator)
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return found[:]}
    prefix:=fmt.tprintf("autosave-%d-",slot)
    for entry in entries {
        name:=entry.name
        if !strings.has_prefix(name,prefix) || !strings.has_suffix(name,".log") {continue}
        if n,ok:=strconv.parse_u64(name[len(prefix):len(name)-len(".log")]);ok && n>0 {append(&found,n)}
    }
    slice.sort(found[:])
    return found[:]
}

@(private)
recovery_log_tables :: proc(s:^Session) -> ^Collab_State {
    r:=&s.recovery
    if r.tables!=nil && r.tables_info==s.info {return r.tables}
    recovery_log_tables_free(s)
    r.tables,r.tables_info=new(Collab_State),s.info
    collab_tables_build(s,r.tables)
    return r.tables
}

@(private)
recovery_log_tables_free :: proc(s:^Session) {
    r:=&s.recovery
    if r.tables==nil {return}
    collab_tables_free(r.tables)
    free(r.tables)
    r.tables,r.tables_info=nil,nil
}

@(private)
recovery_log_sync_run :: proc(sync:^Recovery_Sync,worker:int) {
    sync.error=os.sync(sync.file)
}

// Takes a sync that ended; with wait, waits for it.
@(private)
recovery_log_sync_collect :: proc(s:^Session,wait:bool) {
    sync:=&s.recovery.log.sync
    if !sync.busy {return}
    if wait {jobs.wait(&s.app.jobs,jobs.OWNER,&sync.counter)} else if jobs.pending(&sync.counter) {return}
    sync.busy=false
    if sync.error!=nil {recovery_log_failed(s)}
}

@(private)
recovery_log_failed :: proc(s:^Session) {
    l:=&s.recovery.log
    if l.failed {return}
    l.failed=true
    notify(s,"The recovery log could not be written: the copy of recovery is kept every second")
}

@(private)
recovery_log_close :: proc(s:^Session) {
    l:=&s.recovery.log
    recovery_log_sync_collect(s,true)
    if l.file==nil {return}
    os.close(l.file)
    l.file=nil
}

// Starts generation generation of the chain, after the one written.
@(private)
recovery_log_open :: proc(s:^Session,generation:u64,base:Recovery_Base) -> bool {
    l:=&s.recovery.log
    recovery_log_close(s)
    ws:=s.info.schema
    if ws==nil {recovery_log_failed(s);return false}
    path:=recovery_log_path(s,recovery_slot(s),generation)
    if folder:=project.folder_path(s.project_root,.Generated,context.temp_allocator);!os.is_dir(folder) {_=os.make_directory_all(folder)}
    file,error:=os.open(path,{.Write,.Create,.Trunc})
    if error!=nil {recovery_log_failed(s);return false}
    l.file,l.generation=file,generation
    w:serial.Writer
    serial.writer_init(&w,64,context.temp_allocator)
    serial.write_scalar(&w,RECOVERY_LOG_MAGIC)
    serial.write_scalar(&w,RECOVERY_LOG_VERSION)
    serial.write_scalar(&w,u8(base))
    if base==.Source {
        source:=document_file(s.document)
        serial.write_scalar(&w,u16(len(source)))
        serial.write_bytes(&w,transmute([]u8)source)
    }
    serial.schema_write(&w,&ws.schema)
    st:=recovery_log_tables(s)
    logged:=0
    for t in st.tables {if t.used {logged+=1}}
    serial.write_scalar(&w,u32(logged))
    for t,i in st.tables {
        if !t.used {continue}
        serial.write_string(&w,s.info.tables[i].name)
        serial.write_scalar(&w,core.type_layout_hash(s.info.tables[i].info))
        serial.write_scalar(&w,ws.tables[i].type)
    }
    if _,write_error:=os.write(file,serial.writer_bytes(&w));write_error!=nil {recovery_log_failed(s);return false}
    l.sync_due=platform.clock_ns()+RECOVERY_LOG_SYNC
    return true
}

// Removes the generations of the chain in front below generation, and with all every one.
@(private)
recovery_logs_remove :: proc(s:^Session,below:u64,all:=false) {
    if all {recovery_log_close(s)}
    slot:=s.recovery.slot
    if slot==0 {return}
    for generation in recovery_log_generations(s,slot) {
        if !all && generation>=below {continue}
        _=os.remove(recovery_log_path(s,slot,generation))
    }
}

// A chain for the history of the document as it is now: the saved file is
// its base while the document is clean, a copy taken at once otherwise.
@(private)
recovery_log_begin :: proc(s:^Session) {
    l:=&s.recovery.log
    w:=edited_world(s)
    keep:=l.keep
    l.world,l.epoch,l.info,l.following,l.keep=s.edits.world,s.edits.epoch,s.info,true,false
    l.bytes,l.since=0,0
    history.journal_logging(s.edits,true)
    next:=u64(1)
    if generations:=recovery_log_generations(s,recovery_slot(s));len(generations)>0 {next=generations[len(generations)-1]+1}
    if keep {
        // What a recovery put back follows the chain it came from until a copy holds it.
        l.base=.Copy
        if recovery_log_open(s,next,.Copy) {s.recovery.deadline=platform.clock_ns()}
        return
    }
    recovery_logs_remove(s,0,all=true)
    if s.recovery.owned {recovery_remove(s)}
    l.records=0
    next=1
    if !document_dirty(s) && document_file(s.document)!="" && w.data==s.edits.world {
        l.base=.Source
        recovery_log_open(s,next,.Source)
        return
    }
    // Without a file, or with changes the file does not have, the base is a copy.
    l.base=.Copy
    if recovery_log_open(s,next,.Copy) && document_dirty(s) {s.recovery.deadline=platform.clock_ns()}
}

// The rows the journal took since the log read it, as they are now, by Id:
// the Ids that are born first, those that go last.
@(private)
recovery_log_write :: proc(s:^Session) {
    l:=&s.recovery.log
    edits:=s.edits
    w:=edited_world(s)
    end:=edits.changes_first+u64(len(edits.changes))
    if edits.logged>=end || l.file==nil || w.data!=edits.world {return}
    st:=recovery_log_tables(s)
    cursor:=edits.logged
    changes:=history.journal_read(edits,&cursor)
    Key :: struct {table:i32,entity:core.Entity}
    seen:=make(map[Key]base.Entity_Id,len(changes),context.temp_allocator)
    for change in changes {
        key:=Key{change.table,change.entity}
        if key not_in seen {seen[key]=change.id}
    }
    id_table:=history.journal_id_table(w)
    present:=make(map[Collab_Row]bool,len(seen),context.temp_allocator)
    for key,before in seen {
        if int(key.table)>=len(st.tables) || !st.tables[key.table].used {continue}
        id:=history.journal_id(edits,w,id_table,key.entity)
        if id==0 {id=before}
        if history.journal_row(&edits.image[key.table],key.entity)>=0 {present[{key.table,id}]=true}
    }
    ops:Collab_Ops
    collab_ops_begin(&ops)
    for key,before in seen {
        if int(key.table)>=len(st.tables) || !st.tables[key.table].used {continue}
        t:=&st.tables[key.table]
        image:=&edits.image[key.table]
        id:=history.journal_id(edits,w,id_table,key.entity)
        if id==0 {id=before}
        if id==0 {continue}
        is_ids:=int(key.table)==id_table
        if row:=history.journal_row(image,key.entity);row>=0 {
            current:=make([]u8,max(t.size,1),context.temp_allocator)
            collab_normalize(w,t,history.journal_value(image,t.size,row),current)
            collab_op_write(&ops,is_ids?&ops.head:&ops.body,.Set,t.hash,id,current[:t.size])
            if !is_ids {
                turn:=[1]u8{u8(image.off[row])}
                collab_op_write(&ops,&ops.body,.Turn,t.hash,id,turn[:])
            }
        } else if !present[{key.table,id}] {
            collab_op_write(&ops,is_ids?&ops.tail:&ops.body,.Remove,t.hash,id,nil)
        }
    }
    history.journal_log_done(edits,cursor)
    if ops.count==0 {return}
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    message:=collab_ops_pack(&ops,.Edit,0)
    serial.write_scalar(&out,u32(len(message)))
    serial.write_scalar(&out,hash.crc32(message))
    serial.write_bytes(&out,message)
    l.records+=1
    bytes:=serial.writer_bytes(&out)
    if _,error:=os.write(l.file,bytes);error!=nil {recovery_log_failed(s);return}
    l.bytes+=len(bytes)
    now:=platform.clock_ns()
    if l.since==0 {l.since=now}
    if l.sync_due==0 {l.sync_due=now+RECOVERY_LOG_SYNC}
}

// Between frames: follows the history of the document, writes what it did
// and sends what was written to the disk once the window passed.
@(private)
recovery_log_update :: proc(s:^Session) {
    l:=&s.recovery.log
    recovery_log_sync_collect(s,false)
    if s.project_root=="" || s.edits==nil {return}
    if !l.following || l.world!=s.edits.world || l.epoch!=s.edits.epoch || l.info!=s.info || !s.edits.logging {recovery_log_begin(s)}
    recovery_log_write(s)
    if l.sync_due!=0 && platform.clock_ns()>=l.sync_due && !l.sync.busy && l.file!=nil {
        l.sync_due=0
        l.sync={busy=true,file=l.file}
        jobs.run(&s.app.jobs,jobs.OWNER,.Background,recovery_log_sync_run,&l.sync,&l.sync.counter)
        if jobs.worker_count(&s.app.jobs)==1 {recovery_log_sync_collect(s,true)}
    }
}

// Every step done is in the log: written and, with sync, on the disk.
@(private)
recovery_log_flush :: proc(s:^Session,sync:bool) -> bool {
    l:=&s.recovery.log
    recovery_log_update(s)
    if l.failed || l.file==nil {return false}
    if sync {
        recovery_log_sync_collect(s,true)
        if os.sync(l.file)!=nil {recovery_log_failed(s);return false}
        l.sync_due=0
    }
    return true
}

// A copy of recovery begins: what follows goes to the next generation, which
// the copy names. 0 when the log cannot follow it.
@(private)
recovery_log_copy_begin :: proc(s:^Session) -> u64 {
    l:=&s.recovery.log
    if !l.following {return 0}
    recovery_log_write(s)
    next:=l.generation+1
    if !recovery_log_open(s,next,.Copy) {return 0}
    l.base=.Copy
    l.bytes,l.since=0,0
    return next
}

// A copy that names generation is written: the generations before it go.
@(private)
recovery_log_copy_done :: proc(s:^Session,generation:u64) {
    if generation==0 {return}
    recovery_logs_remove(s,generation)
}

// The log stops following the document: the next history begins a chain.
@(private)
recovery_log_end :: proc(s:^Session,remove:bool) {
    l:=&s.recovery.log
    if remove {recovery_logs_remove(s,0,all=true)} else {recovery_log_close(s)}
    if s.edits!=nil {history.journal_logging(s.edits,false)}
    l.following=false
}

recovery_log_destroy :: proc(s:^Session) {
    recovery_log_close(s)
    recovery_log_tables_free(s)
    delete(s.recovery.found)
    delete(s.recovery.assets)
    s.recovery.found,s.recovery.assets=nil,nil
}

// ---------------------------------------------------------------- putting back

// A generation as it was read: its base and its records, which end at the
// first that a crash cut.
@(private)
Recovery_Log_File :: struct {
    generation:u64,
    base:Recovery_Base,
    source:string,
    schema:serial.Schema,
    tables:[]Recovery_Log_Table,
    records:[dynamic][]u8,
}

// A table of a log as the build that wrote it laid it out.
@(private)
Recovery_Log_Table :: struct {
    name:string,
    layout:u64,              // core.type_layout_hash
    type:serial.Type_Index,  // in the schema of its file
}

@(private)
recovery_log_read :: proc(s:^Session,slot:int,generation:u64) -> (file:Recovery_Log_File,ok:bool) {
    data,error:=os.read_entire_file(recovery_log_path(s,slot,generation),context.temp_allocator)
    if error!=nil {return}
    r:=serial.reader_init(data)
    if serial.read_u32(&r)!=RECOVERY_LOG_MAGIC || serial.read_u32(&r)!=RECOVERY_LOG_VERSION || r.failed {return}
    file.generation=generation
    file.base=Recovery_Base(serial.read_u8(&r))
    if file.base==.Source {
        size:=int(serial.read_u16(&r))
        file.source=string(serial.read_bytes(&r,size))
    }
    if r.failed || file.base>max(Recovery_Base) {return}
    if serial.schema_read(&r,&file.schema,context.temp_allocator)!=.None {return}
    logged:=int(serial.read_u32(&r))
    if r.failed || logged>serial.reader_remaining(&r) {return}
    file.tables=make([]Recovery_Log_Table,logged,context.temp_allocator)
    for &t in file.tables {
        t.name=serial.read_string(&r)
        t.layout=serial.read_u64(&r)
        t.type=serial.Type_Index(serial.read_u16(&r))
    }
    if r.failed {return}
    file.records=make([dynamic][]u8,context.temp_allocator)
    for {
        size:=int(serial.read_u32(&r))
        crc:=serial.read_u32(&r)
        if r.failed || size<=0 {break}
        bytes:=serial.read_bytes(&r,size)
        if r.failed || hash.crc32(bytes)!=crc {break}
        append(&file.records,bytes)
    }
    return file,true
}

// The chain of a slot a start after a crash puts back: from the generation
// the copy names, or from a log over the saved file without a copy. A gap
// ends it.
@(private)
recovery_log_chain :: proc(s:^Session,slot:int,copy_generation:u64) -> (chain:[]Recovery_Log_File,records:int) {
    files:=make([dynamic]Recovery_Log_File,context.temp_allocator)
    for generation in recovery_log_generations(s,slot) {
        if len(files)==0 {
            if copy_generation!=0 && generation<copy_generation {continue}
            file,ok:=recovery_log_read(s,slot,generation)
            if !ok {continue}
            if copy_generation!=0 ? generation!=copy_generation : file.base!=.Source {continue}
            append(&files,file);records+=len(file.records)
            continue
        }
        if generation!=files[len(files)-1].generation+1 {break}
        file,ok:=recovery_log_read(s,slot,generation)
        if !ok {break}
        append(&files,file);records+=len(file.records)
    }
    return files[:],records
}

// Puts the records of a chain back over the document as it is, as the rows
// of another editor are taken: the journal takes them without a step. The
// rows of a table this build lays out otherwise convert by the names of their
// fields; lost counts the changes that cannot (their component is gone, or
// not plain data), and names says of which components.
@(private)
recovery_log_replay :: proc(s:^Session,chain:[]Recovery_Log_File) -> (applied,lost:int,names:string) {
    st:=new(Collab_State)
    defer free(st)
    collab_tables_build(s,st)
    defer collab_tables_free(st)
    w:=edited_world(s)
    ws:=s.info.schema
    gone:=make([dynamic]string,context.temp_allocator)
    for &file in chain {
        tables:=make(map[u64]Recovery_Log_Convert,len(file.tables),context.temp_allocator)
        same:=true
        for logged in file.tables {
            c:=Recovery_Log_Convert{table=-1,name=logged.name}
            hash:=base.name_hash(logged.name)
            if i,found:=core.world_table_index_of_hash(w,hash);found && ws!=nil && st.tables[i].used {
                switch {
                case core.type_layout_hash(s.info.tables[i].info)==logged.layout: c.table=i
                case logged.type!=serial.TYPE_NONE && ws.tables[i].type!=serial.TYPE_NONE:
                    m:=new(serial.Migration,context.temp_allocator)
                    if serial.migration_init(m,&file.schema,logged.type,&ws.schema,ws.tables[i].type,context.temp_allocator)==.None {c.table,c.migration=i,m}
                }
            }
            same&&=c.table>=0 && c.migration==nil && st.tables[c.table].hash==hash
            tables[hash]=c
        }
        for record in file.records {
            bytes:=record
            if !same {bytes=recovery_log_convert(s,st,tables,record,&lost,&gone)}
            collab_edit_apply(s,st,bytes)
            applied+=1
        }
    }
    return applied,lost,strings.join(gone[:],", ",context.temp_allocator)
}

// What a table of a log is in this build: its table, -1 when it has none,
// and the migration of its values when it lays them out otherwise.
@(private)
Recovery_Log_Convert :: struct {
    table:int,
    migration:^serial.Migration,
    name:string,
}

// A record of a log as this build lays its rows out; what it cannot convert
// counts in lost, and the name of its component goes once to gone.
@(private)
recovery_log_convert :: proc(s:^Session,st:^Collab_State,tables:map[u64]Recovery_Log_Convert,record:[]u8,lost:^int,gone:^[dynamic]string) -> []u8 {
    w:=edited_world(s)
    r:=serial.reader_init(record)
    serial.read_u8(&r)
    serial.read_u8(&r)
    count:=int(serial.read_u32(&r))
    ops:Collab_Ops
    collab_ops_begin(&ops)
    for _ in 0..<count {
        kind:=Collab_Op(serial.read_u8(&r))
        hash:=serial.read_u64(&r)
        id:=base.Entity_Id(serial.read_u64(&r))
        bytes:=serial.read_bytes(&r,int(serial.read_u16(&r)))
        if r.failed {break}
        c,known:=tables[hash]
        if !known || c.table<0 {
            lost^+=1
            if known && !slice.contains(gone[:],c.name) {append(gone,c.name)}
            continue
        }
        t:=&st.tables[c.table]
        if kind==.Set && c.migration!=nil {
            info:=&s.info.tables[c.table]
            // A field the old layout lacks keeps what the row has, or starts as a new row does.
            default,value:=make([]u8,max(t.size,1),context.temp_allocator),make([]u8,max(t.size,1),context.temp_allocator)
            e:=core.entity_of(core.world_entities(w),id)
            if current:=core.raw_find(core.world_table_at(w,info),info.info,e);e!=core.NONE && current!=nil {
                collab_normalize(w,t,current,default)
            } else if info.default!=nil && t.size>0 {
                info.default(raw_data(default))
            }
            serial.migration_apply(c.migration,value,bytes,1,default)
            bytes=value[:t.size]
        }
        collab_op_write(&ops,&ops.body,kind,t.hash,id,bytes)
    }
    return collab_ops_pack(&ops,.Edit,0)
}

