package host

import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"

// The rows of the record types of the world (core.Records): every .records
// of the assets whose rows are of a type the world declares, loaded the
// first time a function asks for that type and again once one of its files
// changes, on disk or in memory, appears or goes. One set per type for the
// whole application: every World reads the same rows, so a Play, a copy and
// a rollback leave them as they are.

App_Records :: struct {
    sets:[]Record_Load, // by World_Info.records
    files:[dynamic]Record_File,
    revision:u64, // of the registry when files was made
    scanned:bool,
}

Record_Load :: struct {
    set:core.Record_Set,
    stamp:u64,    // of the files it was loaded from: their ids and content hashes
    revision:u64, // of App_Records when the stamp was last compared
    loaded:bool,
    failed:int, // tables of its type that did not load: damaged, or rows that do not migrate
}

// A .records of the assets: the type of its rows, read once for each content.
Record_File :: struct {
    id:base.Asset_Id,
    content_hash:u64,
    path:string,
    type:[asset.RECORDS_TYPE]u8,
}

#assert(asset.RECORDS_NAME==core.RECORD_NAME)

// The rows of the record type at index in World_Info.records, loaded or
// brought up to date with the files of the assets; nil for an index the
// world does not have, without assets or without memory.
app_record_set :: proc(app:^App,index:int) -> ^core.Record_Set {
    if app==nil || app.info==nil || app.assets==nil || index<0 || index>=len(app.info.records) {return nil}
    r:=&app.records
    if len(r.sets)!=len(app.info.records) {
        records_free(app)
        sets,error:=make([]Record_Load,len(app.info.records),app.allocator)
        if error!=nil {return nil}
        r.sets=sets
        r.files=make([dynamic]Record_File,app.allocator)
    }
    if (!r.scanned || r.revision!=app.assets.registry.revision) && !records_scan(app) {return nil}
    load:=&r.sets[index]
    if load.loaded && load.revision==r.revision {return &load.set}
    load.revision=r.revision
    stamp:=records_stamp(app,index)
    if !load.loaded || load.stamp!=stamp {
        if records_load(app,index) {load.stamp,load.loaded=stamp,true}
    }
    return &load.set
}

// The .records of the assets whose rows are of the type at index, as the
// registry has them now, by path.
app_record_tables :: proc(app:^App,index:int,allocator:=context.temp_allocator) -> []Record_File {
    if app_record_set(app,index)==nil {return nil}
    out:=make([dynamic]Record_File,allocator)
    for &file in app.records.files {
        if records_type_matches(&app.info.records[index],file.type[:]) {append(&out,file)}
    }
    return out[:]
}

// How many tables of the type at index did not load the last time.
app_records_failed :: proc(app:^App,index:int) -> int {
    if index<0 || index>=len(app.records.sets) {return 0}
    return app.records.sets[index].failed
}

app_records_destroy :: proc(app:^App) {
    records_free(app)
}

@(private="file")
records_free :: proc(app:^App) {
    r:=&app.records
    for &load in r.sets {record_set_free(app,&load.set)}
    delete(r.sets,app.allocator)
    for file in r.files {delete(file.path,app.allocator)}
    delete(r.files)
    r^={}
}

@(private="file")
record_set_free :: proc(app:^App,set:^core.Record_Set) {
    delete(set.tables,app.allocator);delete(set.rows,app.allocator);delete(set.index,app.allocator)
    mem.free_bytes(set.values,app.allocator)
    generation:=set.generation
    set^={generation=generation}
}

// The .records of the registry and the type of each: a file read before
// with the same content keeps the type it had. False without memory: the
// files stay as they were, to be scanned again.
@(private="file")
records_scan :: proc(app:^App) -> bool {
    r:=&app.records
    registry:=&app.assets.registry
    kept,error:=make([dynamic]Record_File,0,len(r.files),app.allocator)
    if error!=nil {return false}
    for &file in registry.files {
        if file.kind!=asset.KIND_RECORDS || file.id=={} {continue}
        entry:Record_File
        for &known in r.files {
            if known.id==file.id && known.content_hash==file.content_hash && known.path==file.path {
                entry=known
                known.path=""
                break
            }
        }
        if entry.path=="" {
            entry={id=file.id,content_hash=file.content_hash}
            if !records_type_read(app,file.path,&entry.type) {continue}
            entry.path=clone_string(file.path,app.allocator)
        }
        append(&kept,entry)
    }
    for file in r.files {delete(file.path,app.allocator)}
    delete(r.files)
    r.files=kept
    r.revision,r.scanned=registry.revision,true
    return true
}

@(private="file")
clone_string :: proc(text:string,allocator:=context.allocator) -> string {
    bytes,error:=make([]u8,len(text),allocator)
    if error!=nil {return ""}
    copy(bytes,text)
    return string(bytes)
}

@(private="file")
records_open :: proc(app:^App,path:string,file:^asset.Asset) -> (view:asset.Records_View,ok:bool) {
    a:=app.assets
    data,error:=asset.registry_read(&a.registry,path,a.allocator)
    if error!=.None || asset.asset_take(file,data,a.allocator,codecs=a.codecs)!=.None {return}
    if !asset.blob_verify_hash(&file.blob) {
        asset.asset_close(file)
        return
    }
    read:asset.Error
    if view,read=asset.records_view(file,&a.types);read!=.None {
        asset.asset_close(file)
        return
    }
    return view,true
}

@(private="file")
records_type_read :: proc(app:^App,path:string,type:^[asset.RECORDS_TYPE]u8) -> bool {
    file:asset.Asset
    view:=records_open(app,path,&file) or_return
    defer asset.asset_close(&file)
    type^=view.info.type
    return true
}

// The name a .records gives the type of its rows: "library.Name".
@(private="file")
records_type_matches :: proc(info:^core.Record_Info,type:[]u8) -> bool {
    text:=serial.text_field(type)
    return len(text)==len(info.library)+1+len(info.name) && text[:len(info.library)]==info.library && text[len(info.library)]=='.' && text[len(info.library)+1:]==info.name
}

@(private="file")
records_stamp :: proc(app:^App,index:int) -> u64 {
    info:=&app.info.records[index]
    stamp:=u64(len(app.records.files))
    for &file in app.records.files {
        if !records_type_matches(info,file.type[:]) {continue}
        stamp=base.hash_combine(stamp,base.hash_combine(base.hash_combine(file.id[0],file.id[1]),file.content_hash))
    }
    return stamp
}

// Loads every table of a type into a new set, which replaces the one it had
// only once it is whole. A table that does not load is left out.
@(private="file")
records_load :: proc(app:^App,index:int) -> bool {
    info:=&app.info.records[index]
    schema:=app.info.schema
    if schema==nil || index>=len(schema.records) || schema.records[index].type==serial.TYPE_NONE {return false}
    value_type:=schema.records[index].type
    size:=info.info.size
    default:[]u8
    if info.default!=nil {
        block,error:=mem.alloc_bytes(size,info.info.align,context.temp_allocator)
        if error!=nil {return false}
        info.default(raw_data(block))
        default=block
    }
    files:=make([dynamic]^Record_File,context.temp_allocator)
    for &file in app.records.files {
        if records_type_matches(info,file.type[:]) {append(&files,&file)}
    }
    tables:=make([dynamic]core.Record_Table,app.allocator)
    rows:=make([dynamic]core.Record_Row,app.allocator)
    values:=make([dynamic]u8,app.allocator)
    failed:=0
    for file in files {
        a:asset.Asset
        view,opened:=records_open(app,file.path,&a)
        if !opened {failed+=1;continue}
        defer asset.asset_close(&a)
        at:=len(values)
        if resize(&values,at+len(view.ids)*size)!=nil {failed+=1;continue}
        if asset.records_values(&a,view,&schema.schema,value_type,values[at:],default)!=.None {
            base.truncate(&values,at)
            failed+=1
            continue
        }
        table:core.Record_Table={id=file.id}
        base.text_set(table.name[:],file.path)
        append(&tables,table)
        for id,row in view.ids {append(&rows,core.Record_Row{table=file.id,row=core.Record_Id(id),name=view.names[row]})}
    }
    // Rows are read in place as values of T: their block has its alignment.
    defer delete(values)
    block,block_error:=mem.alloc_bytes_non_zeroed(len(values),max(info.info.align,16),app.allocator)
    order,error:=records_index(rows[:],app.allocator)
    if error!=nil || block_error!=nil {
        delete(tables);delete(rows);delete(order,app.allocator)
        mem.free_bytes(block,app.allocator)
        return false
    }
    copy(block,values[:])
    load:=&app.records.sets[index]
    record_set_free(app,&load.set)
    load.set.size=size
    load.set.tables,load.set.rows,load.set.index=tables[:],rows[:],order
    load.set.values=block
    load.set.generation+=1
    load.failed=failed
    return true
}

// The places of the rows ordered by table and row, as core.record_index searches them.
@(private="file")
records_index :: proc(rows:[]core.Record_Row,allocator:=context.allocator) -> (order:[]u32,error:mem.Allocator_Error) {
    Key :: struct {table:base.Asset_Id,row:core.Record_Id,at:u32}
    keys:=make([]Key,len(rows),context.temp_allocator) or_return
    for row,i in rows {keys[i]={row.table,row.row,u32(i)}}
    slice.sort_by(keys,proc(a,b:Key) -> bool {return core.record_before(a.table,a.row,b.table,b.row)})
    order=make([]u32,len(rows),allocator) or_return
    for key,i in keys {order[i]=key.at}
    return
}
