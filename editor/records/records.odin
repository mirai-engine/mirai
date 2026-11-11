package records

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"

// A table of game data (.records) as the editor changes it: its rows with
// the layout of the program, which a change writes back whole as an edit of
// the file. What the grid of its document and the records.* methods share.

ID_BITS :: 53 // ids of rows: whole in the numbers of JSON

Edit :: struct {
    id:base.Asset_Id,
    record:int,   // its type, in World_Info.records
    info:^runtime.Type_Info, // of that type
    file:string,  // absolute
    ids:[dynamic]u64,
    names:[dynamic]asset.Records_Name,
    values:[]u8,  // size_of the type per row, aligned for it
    allocator:runtime.Allocator,
}

destroy :: proc(e:^Edit) {
    delete(e.ids);delete(e.names)
    mem.free_bytes(e.values,e.allocator)
    e^={}
}

// The index in World_Info.records of the type a .records names; -1 when the
// world declares none such.
type_index :: proc(info:^core.World_Info,type:string) -> int {
    if info==nil {return -1}
    for &r,i in info.records {
        if len(type)==len(r.library)+1+len(r.name) && strings.has_prefix(type,r.library) && type[len(r.library)]=='.' && strings.has_suffix(type,r.name) {return i}
    }
    return -1
}

// The name a .records gives the type at index: "library.Name".
type_name :: proc(info:^core.World_Info,index:int,allocator:=context.temp_allocator) -> string {
    r:=&info.records[index]
    return fmt.aprintf("%s.%s",r.library,r.name,allocator=allocator)
}

row_size :: proc(e:^Edit) -> int {return e.info.size}
row_count :: proc(e:^Edit) -> int {return len(e.ids)}

// The bytes of a row, with the layout of the program.
row_bytes :: proc(e:^Edit,row:int) -> []u8 {
    size:=row_size(e)
    return e.values[row*size:][:size]
}

row_name :: proc(e:^Edit,row:int) -> string {return serial.text_field(e.names[row][:])}

row_find :: proc(e:^Edit,name:string) -> int {
    for &n,row in e.names {
        if serial.text_field(n[:])==name {return row}
    }
    return -1
}

// A table as its file says now, in the memory of the registry or on disk; message says why it cannot be changed when it cannot.
load :: proc(registry:^asset.Registry,types:^asset.Types,info:^core.World_Info,id:base.Asset_Id,e:^Edit,allocator:=context.allocator) -> (message:string) {
    record,found:=asset.registry_find(registry,id)
    if !found || record.kind!=asset.KIND_RECORDS {return "It is not a .records of the assets: asset.list with kind Records lists them"}
    file:asset.Asset
    data,read_error:=asset.registry_read(registry,record.path,context.temp_allocator)
    if read_error!=.None || asset.asset_take(&file,data,context.temp_allocator)!=.None {return fmt.tprintf("%s could not be read",record.path)}
    defer asset.asset_close(&file)
    view,error:=asset.records_view(&file,types)
    if error!=.None {return fmt.tprintf("%s is damaged: %v; mirai asset verify says more",record.path,error)}
    type:=asset.records_type(view)
    index:=type_index(info,type)
    if index<0 {return fmt.tprintf("%s holds rows of %s, which the code does not declare: declare it with @(record) and build, or records.types lists the types there are",record.path,type)}
    ws:=info.schema
    declared:=&info.records[index]
    e^={id=id,record=index,info=declared.info,allocator=allocator}
    e.file=asset.registry_file_path(registry,record.path,allocator)
    if e.values,message=values_alloc(declared,len(view.ids),allocator);message!="" {return}
    default:[]u8
    if declared.default!=nil {
        if default,message=values_alloc(declared,1,context.temp_allocator);message!="" {
            destroy(e)
            return
        }
        declared.default(raw_data(default))
    }
    if asset.records_values(&file,view,&ws.schema,ws.records[index].type,e.values,default)!=.None {
        destroy(e)
        return fmt.tprintf("the rows of %s do not read as %s",record.path,type)
    }
    e.ids=make([dynamic]u64,allocator)
    e.names=make([dynamic]asset.Records_Name,allocator)
    append(&e.ids,..view.ids)
    append(&e.names,..view.names)
    return ""
}

@(private)
values_alloc :: proc(info:^core.Record_Info,rows:int,allocator:runtime.Allocator) -> (values:[]u8,message:string) {
    block,error:=mem.alloc_bytes(max(rows*info.info.size,1),max(info.info.align,16),allocator)
    if error!=nil {return nil,"out of memory"}
    return block[:rows*info.info.size],""
}

// A new table of the type at index, with no rows, to write at file.
create :: proc(info:^core.World_Info,index:int,id:base.Asset_Id,file:string,e:^Edit,allocator:=context.allocator) {
    e^={id=id,record=index,info=info.records[index].info,allocator=allocator,file=strings.clone(file,allocator)}
    e.values,_=values_alloc(&info.records[index],0,allocator)
    e.ids=make([dynamic]u64,allocator)
    e.names=make([dynamic]asset.Records_Name,allocator)
}

// The bytes of the file of the table as it is, in the temporary allocator;
// message says why it cannot be written when it cannot.
file_bytes :: proc(e:^Edit,types:^asset.Types,info:^core.World_Info) -> (bytes:[]u8,message:string) {
    ws:=info.schema
    view:=asset.Records_View{ids=e.ids[:],names=e.names[:]}
    header:asset.Records_Info
    base.text_set(header.type[:],type_name(info,e.record))
    view.info=&header
    if row,problem:=asset.records_problem(view);problem!="" {
        if row>=0 {return nil,fmt.tprintf("row %d (%s): %s",row,row_name(e,row),problem)}
        return nil,problem
    }
    rows:=len(e.ids)
    images:=make([]u8,len(e.values),context.temp_allocator)
    if rows>0 {serial.value_write(&ws.records[e.record].layout,images,raw_data(e.values),rows)}
    desc:=asset.Records_Desc{
        id=e.id,type=type_name(info,e.record),
        ids=e.ids[:],names=e.names[:],
        schema=&ws.schema,value_type=ws.records[e.record].type,images=images,
    }
    error:asset.Error
    if bytes,error=asset.records_bytes(types,desc,context.temp_allocator);error!=.None {return nil,fmt.tprintf("the table could not be written: %v",error)}
    return bytes,""
}

// A new id for a row or a text, the next of the sequence ids: not 0, within
// RECORD_ID_BITS, and not one of taken.
id_new :: proc(ids:^u64,taken:[]u64) -> u64 {
    for {
        id:=u64(base.entity_id_next(ids))&(1<<ID_BITS-1)
        if id!=0 && !slice.contains(taken,id) {return id}
    }
}

// Why a name cannot be the one of a row other than except; "" when it can.
name_refusal :: proc(e:^Edit,name:string,except:=-1) -> string {
    if !asset.records_name_valid(name) || len(name)>=asset.RECORDS_NAME {return fmt.tprintf("%q is not a name of a row: a word of ASCII letters, digits and _, shorter than %d bytes",name,asset.RECORDS_NAME)}
    if at:=row_find(e,name);at>=0 && at!=except {return fmt.tprintf("a row is already named %s: give another name",name)}
    return ""
}

// Grows the values for one more row, aligned for the type.
@(private)
values_grow :: proc(e:^Edit,rows:int) -> bool {
    size:=e.info.size
    if rows*size<=len(e.values) {return true}
    block,error:=mem.alloc_bytes(max(rows*size,1),max(e.info.align,16),e.allocator)
    if error!=nil {return false}
    copy(block,e.values)
    mem.free_bytes(e.values,e.allocator)
    e.values=block[:rows*size]
    return true
}

// Adds a row at the end, or after `after`, with the bytes of value, or what
// default writes over zero (core.Record_Info.default of its type), and an id
// of the sequence ids; returns its place, or a message that says why not.
row_add :: proc(e:^Edit,ids:^u64,name:string,value:[]u8=nil,after:=-1,default:proc(dst:rawptr)=nil) -> (row:int,message:string) {
    if message=name_refusal(e,name);message!="" {return -1,message}
    rows:=len(e.ids)
    if !values_grow(e,rows+1) {return -1,"out of memory"}
    size:=e.info.size
    row=rows if after<0 || after>=rows else after+1
    copy(e.values[(row+1)*size:],e.values[row*size:rows*size])
    cell:=e.values[row*size:][:size]
    if len(value)==size {
        copy(cell,value)
    } else {
        mem.zero_slice(cell)
        if default!=nil {default(raw_data(cell))}
    }
    id:=id_new(ids,e.ids[:])
    name_bytes:asset.Records_Name
    base.text_set(name_bytes[:],name)
    inject_at(&e.ids,row,id)
    inject_at(&e.names,row,name_bytes)
    return row,""
}

// A copy of a row after it, under name.
row_duplicate :: proc(e:^Edit,ids:^u64,row:int,name:string) -> (copied:int,message:string) {
    return row_add(e,ids,name,slice.clone(row_bytes(e,row),context.temp_allocator),row)
}

row_remove :: proc(e:^Edit,row:int) {
    size:=e.info.size
    rows:=len(e.ids)
    copy(e.values[row*size:],e.values[(row+1)*size:rows*size])
    e.values=e.values[:(rows-1)*size]
    ordered_remove(&e.ids,row)
    ordered_remove(&e.names,row)
}

row_rename :: proc(e:^Edit,row:int,name:string) -> (message:string) {
    if message=name_refusal(e,name,row);message!="" {return}
    base.text_set(e.names[row][:],name)
    return ""
}

// Moves a row to another place of the grid; its id stays.
row_move :: proc(e:^Edit,from,to:int) {
    rows:=len(e.ids)
    if from==to || from<0 || to<0 || from>=rows || to>=rows {return}
    size:=e.info.size
    value:=slice.clone(e.values[from*size:][:size],context.temp_allocator)
    if from<to {
        copy(e.values[from*size:],e.values[(from+1)*size:(to+1)*size])
    } else {
        copy(e.values[(to+1)*size:],e.values[to*size:from*size])
    }
    copy(e.values[to*size:],value)
    id,name:=e.ids[from],e.names[from]
    ordered_remove(&e.ids,from)
    ordered_remove(&e.names,from)
    inject_at(&e.ids,to,id)
    inject_at(&e.names,to,name)
}

