package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"

// A table of game data (.records) as the editor changes it: its rows with
// the layout of the program, which a change writes back whole as an edit of
// the file, a step of the history like any other. What the grid of its
// document and the records.* methods share.

RECORD_ID_BITS :: 53 // ids of rows and texts: whole in the numbers of JSON

Records_Edit :: struct {
    id:base.Asset_Id,
    record:int,   // its type, in World_Info.records
    info:^runtime.Type_Info, // of that type
    file:string,  // absolute
    ids:[dynamic]u64,
    names:[dynamic]asset.Records_Name,
    values:[]u8,  // size_of the type per row, aligned for it
    texts:[dynamic]asset.Records_Text,
    text:[dynamic]u8,
    allocator:runtime.Allocator,
}

records_edit_destroy :: proc(e:^Records_Edit) {
    delete(e.ids);delete(e.names);delete(e.texts);delete(e.text)
    mem.free_bytes(e.values,e.allocator)
    e^={}
}

// The index in World_Info.records of the type a .records names; -1 when the
// world declares none such.
records_type_index :: proc(info:^core.World_Info,type:string) -> int {
    if info==nil {return -1}
    for &r,i in info.records {
        if len(type)==len(r.library)+1+len(r.name) && strings.has_prefix(type,r.library) && type[len(r.library)]=='.' && strings.has_suffix(type,r.name) {return i}
    }
    return -1
}

// The name a .records gives the type at index: "library.Name".
records_type_name :: proc(info:^core.World_Info,index:int,allocator:=context.temp_allocator) -> string {
    r:=&info.records[index]
    return fmt.aprintf("%s.%s",r.library,r.name,allocator=allocator)
}

records_size :: proc(e:^Records_Edit) -> int {return e.info.size}
records_count :: proc(e:^Records_Edit) -> int {return len(e.ids)}

// The bytes of a row, with the layout of the program.
records_row :: proc(e:^Records_Edit,row:int) -> []u8 {
    size:=records_size(e)
    return e.values[row*size:][:size]
}

records_name :: proc(e:^Records_Edit,row:int) -> string {return serial.text_field(e.names[row][:])}

records_find :: proc(e:^Records_Edit,name:string) -> int {
    for &n,row in e.names {
        if serial.text_field(n[:])==name {return row}
    }
    return -1
}

// A table as its file says now, unsaved in memory or on disk; message says
// why it cannot be changed when it cannot.
records_edit_load :: proc(s:^Session,id:base.Asset_Id,e:^Records_Edit,allocator:=context.allocator) -> (message:string) {
    a:=s.app.assets
    if a==nil || s.app.info==nil {return "The editor has no assets or no project"}
    record,found:=asset.registry_find(&a.registry,id)
    if !found || record.kind!=asset.KIND_RECORDS {return "It is not a .records of the assets: asset.list with kind Records lists them"}
    file:asset.Asset
    if !asset_read(s,record.path,&file) {return fmt.tprintf("%s could not be read",record.path)}
    defer asset.asset_close(&file)
    view,error:=asset.records_view(&file,&a.types)
    if error!=.None {return fmt.tprintf("%s is damaged: %v; mirai asset verify says more",record.path,error)}
    type:=asset.records_type(view)
    index:=records_type_index(s.app.info,type)
    if index<0 {return fmt.tprintf("%s holds rows of %s, which the code does not declare: declare it with @(record) and build, or records.types lists the types there are",record.path,type)}
    ws:=s.app.info.schema
    info:=&s.app.info.records[index]
    e^={id=id,record=index,info=info.info,allocator=allocator}
    e.file=asset.registry_file_path(&a.registry,record.path,allocator)
    if e.values,message=records_values_alloc(info,len(view.ids),allocator);message!="" {return}
    default:[]u8
    if info.default!=nil {
        if default,message=records_values_alloc(info,1,context.temp_allocator);message!="" {
            records_edit_destroy(e)
            return
        }
        info.default(raw_data(default))
    }
    if asset.records_values(&file,view,&ws.schema,ws.records[index].type,e.values,default)!=.None {
        records_edit_destroy(e)
        return fmt.tprintf("the rows of %s do not read as %s",record.path,type)
    }
    e.ids=make([dynamic]u64,allocator)
    e.names=make([dynamic]asset.Records_Name,allocator)
    e.texts=make([dynamic]asset.Records_Text,allocator)
    e.text=make([dynamic]u8,allocator)
    append(&e.ids,..view.ids)
    append(&e.names,..view.names)
    append(&e.texts,..view.texts)
    append(&e.text,..view.text)
    return ""
}

@(private="file")
records_values_alloc :: proc(info:^core.Record_Info,rows:int,allocator:runtime.Allocator) -> (values:[]u8,message:string) {
    block,error:=mem.alloc_bytes(max(rows*info.info.size,1),max(info.info.align,16),allocator)
    if error!=nil {return nil,"out of memory"}
    return block[:rows*info.info.size],""
}

// A new table of the type at index, with no rows, to write at file.
records_edit_new :: proc(s:^Session,index:int,id:base.Asset_Id,file:string,e:^Records_Edit,allocator:=context.allocator) {
    e^={id=id,record=index,info=s.app.info.records[index].info,allocator=allocator,file=strings.clone(file,allocator)}
    e.values,_=records_values_alloc(&s.app.info.records[index],0,allocator)
    e.ids=make([dynamic]u64,allocator)
    e.names=make([dynamic]asset.Records_Name,allocator)
    e.texts=make([dynamic]asset.Records_Text,allocator)
    e.text=make([dynamic]u8,allocator)
}

// Writes the table into its file as an edit, in the open gesture or in a
// step named label; message says why it was not written.
records_edit_publish :: proc(s:^Session,e:^Records_Edit,label:string) -> (message:string) {
    a:=s.app.assets
    ws:=s.app.info.schema
    if a==nil || ws==nil {return "The editor has no assets or no project"}
    view:=asset.Records_View{ids=e.ids[:],names=e.names[:]}
    info:asset.Records_Info
    base.text_set(info.type[:],records_type_name(s.app.info,e.record))
    view.info=&info
    if row,problem:=asset.records_problem(view);problem!="" {
        if row>=0 {return fmt.tprintf("row %d (%s): %s",row,records_name(e,row),problem)}
        return problem
    }
    texts,text:=records_texts_compact(e)
    rows:=len(e.ids)
    images:=make([]u8,len(e.values),context.temp_allocator)
    if rows>0 {serial.value_write(&ws.records[e.record].layout,images,raw_data(e.values),rows)}
    desc:=asset.Records_Desc{
        id=e.id,type=records_type_name(s.app.info,e.record),
        ids=e.ids[:],names=e.names[:],
        schema=&ws.schema,value_type=ws.records[e.record].type,images=images,
        texts=texts,text=text,
    }
    bytes,error:=asset.records_bytes(&a.types,desc,context.temp_allocator)
    if error!=.None {return fmt.tprintf("the table could not be written: %v",error)}
    if !file_write(s,e.file,bytes,label) {return "the table could not be written"}
    return ""
}

// The texts the rows still name, their bytes one after the other.
@(private="file")
records_texts_compact :: proc(e:^Records_Edit) -> (texts:[]asset.Records_Text,text:[]u8) {
    named:=make(map[u64]bool,context.temp_allocator)
    for row in 0..<len(e.ids) {records_text_ids(e,row,&named)}
    kept:=make([dynamic]asset.Records_Text,context.temp_allocator)
    bytes:=make([dynamic]u8,context.temp_allocator)
    for &entry in e.texts {
        if !named[entry.text] || entry.length==0 && serial.text_field(entry.language[:])!="" {continue}
        copied:=entry
        copied.offset=u32(len(bytes))
        append(&bytes,..e.text[entry.offset:][:entry.length])
        append(&kept,copied)
    }
    return kept[:],bytes[:]
}

// The ids of the texts a row names.
@(private="file")
records_text_ids :: proc(e:^Records_Edit,row:int,out:^map[u64]bool) {
    for offset in records_text_offsets(e.info) {
        id:=(cast(^core.Text)&e.values[row*e.info.size+offset]).id
        if id!=0 {out[id]=true}
    }
}

// The offsets of the core.Text fields of a type, in its fields, structs and arrays.
records_text_offsets :: proc(info:^runtime.Type_Info,allocator:=context.temp_allocator) -> []int {
    out:=make([dynamic]int,allocator)
    walk :: proc(info:^runtime.Type_Info,offset:int,out:^[dynamic]int,depth:int) {
        if depth>16 {return}
        if info.id==core.Text {append(out,offset);return}
        if info.id==base.Asset_Id {return}
        #partial switch v in runtime.type_info_base(info).variant {
        case runtime.Type_Info_Struct:
            for i in 0..<int(v.field_count) {walk(v.types[i],offset+int(v.offsets[i]),out,depth+1)}
        case runtime.Type_Info_Array:
            for at in 0..<v.count {walk(v.elem,offset+at*v.elem_size,out,depth+1)}
        }
    }
    walk(info,0,&out,0)
    return out[:]
}

// A new id for a row or a text: not 0, within RECORD_ID_BITS, and not one of taken.
records_id_new :: proc(s:^Session,taken:[]u64) -> u64 {
    for {
        id:=asset_id_new(s)[0]&(1<<RECORD_ID_BITS-1)
        if id!=0 && !slice.contains(taken,id) {return id}
    }
}

// Why a name cannot be the one of a row other than except; "" when it can.
records_name_refusal :: proc(e:^Records_Edit,name:string,except:=-1) -> string {
    if !asset.records_name_valid(name) || len(name)>=asset.RECORDS_NAME {return fmt.tprintf("%q is not a name of a row: a word of ASCII letters, digits and _, shorter than %d bytes",name,asset.RECORDS_NAME)}
    if at:=records_find(e,name);at>=0 && at!=except {return fmt.tprintf("a row is already named %s: give another name",name)}
    return ""
}

// Grows the values for one more row, aligned for the type.
@(private="file")
records_values_grow :: proc(e:^Records_Edit,rows:int) -> bool {
    size:=e.info.size
    if rows*size<=len(e.values) {return true}
    block,error:=mem.alloc_bytes(max(rows*size,1),max(e.info.align,16),e.allocator)
    if error!=nil {return false}
    copy(block,e.values)
    mem.free_bytes(e.values,e.allocator)
    e.values=block[:rows*size]
    return true
}

// Adds a row at the end, or after `after`, with the default of its type, or
// the bytes of value; returns its place, or a message that says why not.
records_row_add :: proc(s:^Session,e:^Records_Edit,name:string,value:[]u8=nil,after:=-1) -> (row:int,message:string) {
    if message=records_name_refusal(e,name);message!="" {return -1,message}
    rows:=len(e.ids)
    if !records_values_grow(e,rows+1) {return -1,"out of memory"}
    size:=e.info.size
    row=rows if after<0 || after>=rows else after+1
    copy(e.values[(row+1)*size:],e.values[row*size:rows*size])
    cell:=e.values[row*size:][:size]
    if len(value)==size {
        copy(cell,value)
    } else {
        mem.zero_slice(cell)
        if r:=&s.app.info.records[e.record];r.default!=nil {r.default(raw_data(cell))}
    }
    id:=records_id_new(s,e.ids[:])
    name_bytes:asset.Records_Name
    base.text_set(name_bytes[:],name)
    inject_at(&e.ids,row,id)
    inject_at(&e.names,row,name_bytes)
    return row,""
}

// A copy of a row after it, under name: its texts are copied under new ids,
// so changing one does not change the other.
records_row_duplicate :: proc(s:^Session,e:^Records_Edit,row:int,name:string) -> (copied:int,message:string) {
    value:=slice.clone(records_row(e,row),context.temp_allocator)
    if copied,message=records_row_add(s,e,name,value,row);message!="" {return}
    for offset in records_text_offsets(e.info) {
        text:=cast(^core.Text)&e.values[copied*e.info.size+offset]
        if text.id==0 {continue}
        old:=text.id
        text.id=records_text_id_new(s,e)
        for i in 0..<len(e.texts) {
            entry:=e.texts[i]
            if entry.text!=old {continue}
            language:=serial.text_field(entry.language[:])
            records_text_put(e,text.id,strings.clone(language,context.temp_allocator),strings.clone(string(e.text[entry.offset:][:entry.length]),context.temp_allocator))
        }
    }
    return copied,""
}

records_row_remove :: proc(e:^Records_Edit,row:int) {
    size:=e.info.size
    rows:=len(e.ids)
    copy(e.values[row*size:],e.values[(row+1)*size:rows*size])
    e.values=e.values[:(rows-1)*size]
    ordered_remove(&e.ids,row)
    ordered_remove(&e.names,row)
}

records_row_rename :: proc(e:^Records_Edit,row:int,name:string) -> (message:string) {
    if message=records_name_refusal(e,name,row);message!="" {return}
    base.text_set(e.names[row][:],name)
    return ""
}

// Moves a row to another place of the grid; its id stays.
records_row_move :: proc(e:^Records_Edit,from,to:int) {
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

// A new id of a text, one no text of the table has.
records_text_id_new :: proc(s:^Session,e:^Records_Edit) -> u64 {
    taken:=make([dynamic]u64,context.temp_allocator)
    for entry in e.texts {append(&taken,entry.text)}
    for row in 0..<len(e.ids) {
        for offset in records_text_offsets(e.info) {append(&taken,(cast(^core.Text)&e.values[row*e.info.size+offset]).id)}
    }
    return records_id_new(s,taken[:])
}

// The text of a core.Text in a language ("" for the one the game is written in).
records_text_get :: proc(e:^Records_Edit,text:u64,language:string) -> (value:string,found:bool) {
    for &entry in e.texts {
        if entry.text==text && serial.text_field(entry.language[:])==language {return string(e.text[entry.offset:][:entry.length]),true}
    }
    return
}

// Puts the text of a core.Text in a language, in the order of the texts.
records_text_put :: proc(e:^Records_Edit,text:u64,language:string,value:string) {
    offset:=u32(len(e.text))
    append(&e.text,..transmute([]u8)value)
    for &entry,at in e.texts {
        entry_language:=serial.text_field(entry.language[:])
        if entry.text==text && entry_language==language {
            entry.offset,entry.length=offset,u32(len(value))
            return
        }
        if entry.text>text || entry.text==text && entry_language>language {
            added:=asset.Records_Text{text=text,offset=offset,length=u32(len(value))}
            base.text_set(added.language[:],language)
            inject_at(&e.texts,at,added)
            return
        }
    }
    added:=asset.Records_Text{text=text,offset=offset,length=u32(len(value))}
    base.text_set(added.language[:],language)
    append(&e.texts,added)
}

// Writes the text of the core.Text at an offset of a row in a language,
// giving the field a text of its own the first time.
records_text_set :: proc(s:^Session,e:^Records_Edit,row,offset:int,language:string,value:string) -> (message:string) {
    if len(language)>=asset.RECORDS_LANGUAGE {return fmt.tprintf("%q is not a code of a language: \"es\", \"pt-BR\"",language)}
    text:=cast(^core.Text)&e.values[row*e.info.size+offset]
    if text.id==0 {text.id=records_text_id_new(s,e)}
    records_text_put(e,text.id,language,value)
    return ""
}

// The tables of the type at index in the assets, by their paths.
records_tables :: proc(s:^Session,index:int,allocator:=context.temp_allocator) -> []host.Record_File {
    return host.app_record_tables(s.app,index,allocator)
}
