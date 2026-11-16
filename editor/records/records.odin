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

// A table of game data (.records) as the editor changes it: its columns and
// its rows with the layout the columns make, never the one of the program,
// so a column is editable before the game is built again. A change writes
// the file back whole as an edit of the file. What the grid of its document
// and the records.* methods share.

ID_BITS :: 53 // ids of rows: whole in the numbers of JSON

Edit :: struct {
    id:base.Asset_Id,
    file:string,   // absolute
    folder:string, // the assets it is among: "" for the project's, plugins/<name> for a plugin's
    info:asset.Records_Info,
    columns:[dynamic]asset.Records_Column, // of its type: its own, or those of the table that declares it
    declaring:base.Asset_Id, // a table that does not declare its type: the one that does; {} when none does
    schema:serial.Schema,    // of a row, made from the columns
    named:[]serial.Choice,   // the names of the @(names) types schema holds
    type:serial.Type_Index,  // of a row in schema
    layout:serial.Layout,
    defaults:[]u8, // a new row
    ids:[dynamic]u64,
    names:[dynamic]asset.Records_Name,
    values:[]u8,   // a row of type per row, aligned for it
    allocator:runtime.Allocator,
}

destroy :: proc(e:^Edit) {
    if e.allocator.procedure==nil {return}
    delete(e.ids);delete(e.names);delete(e.columns)
    mem.free_bytes(e.values,e.allocator)
    mem.free_bytes(e.defaults,e.allocator)
    schema_free(e)
    delete(e.file,e.allocator);delete(e.folder,e.allocator)
    e^={}
}

@(private)
schema_free :: proc(e:^Edit) {
    serial.layout_destroy(&e.layout)
    if e.schema.allocator.procedure!=nil {
        delete(e.schema.named)
        serial.schema_destroy(&e.schema)
    }
    delete(e.named,e.allocator)
    e.named=nil
}

type_name :: proc(e:^Edit) -> string {return serial.text_field(e.info.type[:])}
description :: proc(e:^Edit) -> string {return serial.text_field(e.info.description[:])}
column_name :: proc(c:^asset.Records_Column) -> string {return serial.text_field(c.name[:])}

row_size :: proc(e:^Edit) -> int {return int(e.schema.types[e.type].size) if serial.type_valid(&e.schema,e.type) else 0}
row_align :: proc(e:^Edit) -> int {return max(int(e.schema.types[e.type].align) if serial.type_valid(&e.schema,e.type) else 1,16)}
row_count :: proc(e:^Edit) -> int {return len(e.ids)}

// The bytes of a row, with the layout of the columns.
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

column_find :: proc(e:^Edit,name:string) -> int {
    for &c,at in e.columns {
        if column_name(&c)==name {return at}
    }
    return -1
}

// The field of a column in the schema of a row: its offset and its type.
column_field :: proc(e:^Edit,at:int) -> (field:serial.Field,ok:bool) {
    fields:=serial.schema_fields(&e.schema,e.type)
    if at<0 || at>=len(fields) {return}
    return fields[at],true
}

// The folder of the assets a path among them is of: "" or plugins/<name>.
folder_of :: proc(path:string) -> string {
    if !strings.has_prefix(path,"plugins/") {return ""}
    rest:=path[len("plugins/"):]
    slash:=strings.index_byte(rest,'/')
    return slash<0 ? "" : path[:len("plugins/")+slash]
}

// The name a table takes for the type of its rows from its file: items.records, Items.
type_of_file :: proc(file:string,allocator:=context.temp_allocator) -> string {
    name:=file
    if slash:=strings.last_index_any(name,"/\\");slash>=0 {name=name[slash+1:]}
    name=strings.trim_suffix(name,".records")
    b:=strings.builder_make(allocator)
    upper:=true
    for c in transmute([]u8)name {
        switch c {
        case 'a'..='z':
            strings.write_byte(&b,upper ? c-'a'+'A' : c)
            upper=false
        case 'A'..='Z','0'..='9':
            if strings.builder_len(b)==0 && c<='9' {strings.write_string(&b,"T_")}
            strings.write_byte(&b,c)
            upper=false
        case:
            if strings.builder_len(b)>0 && !upper {strings.write_byte(&b,'_')}
            upper=true
        }
    }
    text:=strings.trim_right(strings.to_string(b),"_")
    return text if asset.records_type_problem(text)=="" else "Record"
}

// A table as its file says now, in the memory of the registry or on disk;
// message says why it cannot be changed when it cannot. info gives the types
// of the code a column of kind Type holds and the rows a Record offers.
load :: proc(registry:^asset.Registry,types:^asset.Types,info:^core.World_Info,id:base.Asset_Id,e:^Edit,allocator:=context.allocator) -> (message:string) {
    record,found:=asset.registry_find(registry,id)
    if !found || record.kind!=asset.KIND_RECORDS {return "It is not a .records of the assets: asset.list with kind Records lists them"}
    file:asset.Asset
    data,read_error:=asset.registry_read(registry,record.path,context.temp_allocator)
    if read_error!=.None || asset.asset_take(&file,data,context.temp_allocator)!=.None {return fmt.tprintf("%s could not be read",record.path)}
    defer asset.asset_close(&file)
    view,error:=asset.records_view(&file,types)
    if error!=.None {return fmt.tprintf("%s is damaged or of an older engine (%v): mirai asset verify says more",record.path,error)}
    e^={id=id,info=view.info^,allocator=allocator}
    e.file=asset.registry_file_path(registry,record.path,allocator)
    e.folder=strings.clone(folder_of(record.path),allocator)
    e.columns=make([dynamic]asset.Records_Column,allocator)
    e.ids=make([dynamic]u64,allocator)
    e.names=make([dynamic]asset.Records_Name,allocator)
    // The type of a table that does not declare it is that of the table that does.
    declaring:asset.Asset
    declared:=view
    declared_file:=&file
    if !view.info.declares {
        at,declaring_path:=declaring_find(registry,types,asset.records_type(view))
        if at=={} {
            destroy(e)
            return fmt.tprintf("%s holds rows of %s, and no .records declares that type: make its table, or records.types lists the types there are",record.path,asset.records_type(view))
        }
        e.declaring=at
        bytes,read:=asset.registry_read(registry,declaring_path,context.temp_allocator)
        if read!=.None || asset.asset_take(&declaring,bytes,context.temp_allocator)!=.None {
            destroy(e)
            return fmt.tprintf("%s, which declares %s, could not be read",declaring_path,asset.records_type(view))
        }
        if declared,error=asset.records_view(&declaring,types);error!=.None {
            asset.asset_close(&declaring)
            destroy(e)
            return fmt.tprintf("%s, which declares %s, is damaged: mirai asset verify says more",declaring_path,asset.records_type(view))
        }
        declared_file=&declaring
    }
    defer if !view.info.declares {asset.asset_close(&declaring)}
    append(&e.columns,..declared.columns)
    stored:=declared.defaults.columns[0].type if declared.defaults!=nil else serial.TYPE_NONE
    if message=schema_make(e,info,&declared_file.schema,stored);message!="" {
        destroy(e)
        return fmt.tprintf("%s: %s",record.path,message)
    }
    if e.defaults,message=values_alloc(e,1);message!="" {destroy(e);return}
    if declared.defaults!=nil {asset.records_defaults(declared_file,declared,&e.schema,e.type,e.defaults)}
    if e.values,message=values_alloc(e,len(view.ids));message!="" {destroy(e);return}
    if len(view.ids)>0 && asset.records_values(&file,view,&e.schema,e.type,e.values,e.defaults)!=.None {
        destroy(e)
        return fmt.tprintf("the rows of %s do not read as its columns say",record.path)
    }
    append(&e.ids,..view.ids)
    append(&e.names,..view.names)
    return ""
}

// The ids and names of the rows of a table, in the temporary allocator; ok
// is false when it does not read.
rows_read :: proc(registry:^asset.Registry,types:^asset.Types,id:base.Asset_Id) -> (ids:[]u64,names:[]asset.Records_Name,ok:bool) {
    record,found:=asset.registry_find(registry,id)
    if !found {return}
    data,error:=asset.registry_read(registry,record.path,context.temp_allocator)
    if error!=.None {return}
    a:asset.Asset
    if asset.asset_take(&a,data,context.temp_allocator)!=.None {return}
    defer asset.asset_close(&a)
    view,viewed:=asset.records_view(&a,types)
    if viewed!=.None {return}
    return slice.clone(view.ids,context.temp_allocator),slice.clone(view.names,context.temp_allocator),true
}

// The table that declares a type, among the .records of the registry; {} when none does.
declaring_find :: proc(registry:^asset.Registry,types:^asset.Types,type:string) -> (id:base.Asset_Id,path:string) {
    for &f in registry.files {
        if f.kind!=asset.KIND_RECORDS || f.id=={} {continue}
        data,error:=asset.registry_read(registry,f.path,context.temp_allocator)
        if error!=.None {continue}
        a:asset.Asset
        if asset.asset_take(&a,data,context.temp_allocator)!=.None {continue}
        view,viewed:=asset.records_view(&a,types)
        if viewed==.None && view.info.declares && asset.records_type(view)==type {
            asset.asset_close(&a)
            return f.id,f.path
        }
        asset.asset_close(&a)
    }
    return
}

@(private)
values_alloc :: proc(e:^Edit,rows:int) -> (values:[]u8,message:string) {
    size:=row_size(e)
    block,error:=mem.alloc_bytes(max(rows*size,1),row_align(e),e.allocator)
    if error!=nil {return nil,"out of memory"}
    return block[:rows*size],""
}

// A new table that declares its type, with no columns and no rows, to write at file.
create :: proc(id:base.Asset_Id,file,folder,type:string,e:^Edit,allocator:=context.allocator) -> (message:string) {
    if message=asset.records_type_problem(type);message!="" {return}
    e^={id=id,allocator=allocator,file=strings.clone(file,allocator),folder=strings.clone(folder,allocator)}
    base.text_set(e.info.type[:],type)
    e.info.declares=true
    e.columns=make([dynamic]asset.Records_Column,allocator)
    e.ids=make([dynamic]u64,allocator)
    e.names=make([dynamic]asset.Records_Name,allocator)
    if message=schema_make(e,nil,nil,serial.TYPE_NONE);message!="" {destroy(e);return}
    if e.defaults,message=values_alloc(e,1);message!="" {destroy(e);return}
    if e.values,message=values_alloc(e,0);message!="" {destroy(e);return}
    return ""
}

// The bytes of the file of the table as it is, in the temporary allocator;
// message says why it cannot be written when it cannot.
file_bytes :: proc(e:^Edit,types:^asset.Types) -> (bytes:[]u8,message:string) {
    columns:=e.columns[:] if e.info.declares else nil
    view:=asset.Records_View{info=&e.info,columns=columns,ids=e.ids[:],names=e.names[:]}
    if row,problem:=asset.records_problem(view);problem!="" {
        if row>=0 {return nil,fmt.tprintf("row %d (%s): %s",row,row_name(e,row),problem)}
        return nil,problem
    }
    rows:=len(e.ids)
    images:=make([]u8,len(e.values),context.temp_allocator)
    if rows>0 {serial.value_write(&e.layout,images,raw_data(e.values),rows)}
    defaults:[]u8
    if e.info.declares {
        defaults=make([]u8,row_size(e),context.temp_allocator)
        serial.value_write(&e.layout,defaults,raw_data(e.defaults),1)
    }
    desc:=asset.Records_Desc{
        id=e.id,info=e.info,columns=columns,
        ids=e.ids[:],names=e.names[:],
        schema=&e.schema,value_type=e.type,images=images,defaults=defaults,
    }
    error:asset.Error
    if bytes,error=asset.records_bytes(types,desc,context.temp_allocator);error!=.None {return nil,fmt.tprintf("the table could not be written: %v",error)}
    return bytes,""
}

// ---------------------------------------------------------------- the schema of a row

// Makes the schema of a row from the columns: the layout Odin gives the
// struct the build generates from them. A column of kind Type takes the type
// of the code from info, or as stored holds it when the build has it no
// more. message says which column cannot be made, and why.
@(private)
schema_make :: proc(e:^Edit,info:^core.World_Info,stored:^serial.Schema,stored_type:serial.Type_Index) -> (message:string) {
    s:=&e.schema
    serial.schema_init(s,e.allocator)
    if info!=nil {
        ok:bool
        if e.named,ok=core.schema_named(s,info,e.allocator);!ok {return "out of memory"}
    } else {
        s.named=make(map[typeid]serial.Named,e.allocator)
    }
    fields:=make([dynamic]serial.Field,0,len(e.columns),context.temp_allocator)
    offset,align:=u32(0),u32(1)
    for &c in e.columns {
        name:=column_name(&c)
        type:serial.Type_Index
        if type,message=column_type(e,info,&c,stored,stored_type);message!="" {return fmt.tprintf("column %s: %s",name,message)}
        if c.count>0 {
            elem:=s.types[type]
            ok:bool
            if type,ok=serial.schema_type_add(s,{kind=.Array,elem=type,count=u32(c.count),size=elem.size*u32(c.count),align=elem.align});!ok {return "out of memory"}
        }
        t:=s.types[type]
        offset=(offset+t.align-1)/t.align*t.align
        field:=serial.Field{name=name,type=type,offset=offset}
        #partial switch c.kind {
        case .Int,.Float:
            field.has_min,field.has_max,field.min,field.max=c.has_min,c.has_max,c.min,c.max
            field.unit=serial.text_field(c.unit[:])
        case .Asset:
            field.asset_kinds=serial.text_field(c.asset_kind[:])
        case .String:
            field.flags+={.Text}
        }
        field.description=serial.text_field(c.description[:])
        field.was=serial.text_field(c.was[:])
        append(&fields,field)
        offset+=t.size
        align=max(align,t.align)
    }
    size:=(offset+align-1)/align*align
    ok:bool
    if e.type,ok=serial.schema_type_add(s,{kind=.Struct,name=type_name(e),size=size,align=align,elem=serial.TYPE_NONE},fields[:]);!ok {return "out of memory"}
    serial.layout_init(&e.layout,s,e.type,e.allocator)
    return ""
}

@(private)
column_type :: proc(e:^Edit,info:^core.World_Info,c:^asset.Records_Column,stored:^serial.Schema,stored_type:serial.Type_Index) -> (type:serial.Type_Index,message:string) {
    s:=&e.schema
    add :: proc(s:^serial.Schema,info:^runtime.Type_Info) -> (serial.Type_Index,string) {
        type,ok:=serial.schema_add_type_info(s,info)
        return type,ok ? "" : "out of memory"
    }
    named:=serial.text_field(c.type[:])
    switch c.kind {
    case .Int:   return add(s,type_info_of(i32))
    case .Float: return add(s,type_info_of(f32))
    case .Bool:  return add(s,type_info_of(bool))
    case .Asset: return add(s,type_info_of(base.Asset_Id))
    case .Text:  return add(s,type_info_of(core.Text))
    case .String:
        byte_type,problem:=add(s,type_info_of(u8))
        if problem!="" {return byte_type,problem}
        array,ok:=serial.schema_type_add(s,{kind=.Array,elem=byte_type,count=u32(c.length),size=u32(c.length),align=1})
        return array,ok ? "" : "out of memory"
    case .Enum:
        choices:=make([dynamic]serial.Choice,context.temp_allocator)
        rest:=serial.text_field(c.values[:])
        for value in strings.fields_iterator(&rest) {append(&choices,serial.Choice{value,i64(len(choices))})}
        enum_type,ok:=serial.schema_type_add(s,{kind=.Enum,name=named,size=1,align=1,elem=serial.TYPE_NONE},nil,choices[:])
        return enum_type,ok ? "" : "out of memory"
    case .Record:
        // The type of core.Record(T) once the build has T: the rows it offers.
        ref:typeid
        if info!=nil {
            for &r in info.records {
                if r.name==named {ref=r.ref}
            }
        }
        if index,found:=s.lookup[ref];ref!=nil && found {return index,""}
        table,problem:=add(s,type_info_of(base.Asset_Id))
        if problem!="" {return table,problem}
        row,row_problem:=add(s,type_info_of(core.Record_Id))
        if row_problem!="" {return row,row_problem}
        fields:=[2]serial.Field{{name="table",type=table,offset=0},{name="row",type=row,offset=size_of(base.Asset_Id)}}
        record,ok:=serial.schema_type_add(s,{kind=.Struct,name="Record",size=size_of(core.Record(int)),align=align_of(core.Record(int)),elem=serial.TYPE_NONE,id=ref},fields[:])
        return record,ok ? "" : "out of memory"
    case .Type:
        if info!=nil {
            for &code in info.record_codes {
                if code.name!=named || code.folder!=e.folder {continue}
                index,ok:=serial.schema_add_type_info(s,code.info)
                if !ok {return serial.TYPE_NONE,fmt.tprintf("%s is not plain data a row keeps: %s",named,s.error)}
                return index,""
            }
        }
        // What the file holds, while the build does not have the type.
        if stored!=nil {
            if field:=serial.schema_field(stored,stored_type,base.name_hash(column_name(c)));field!=nil {
                elem:=field.type
                if c.count>0 && stored.types[elem].kind==.Array {elem=stored.types[elem].elem}
                hashes:=make([dynamic]u64,context.temp_allocator)
                link:serial.Schema_Import
                serial.schema_import_init(&link,s,&hashes,stored,context.temp_allocator)
                defer serial.schema_import_destroy(&link)
                if index:=serial.schema_import(&link,elem);index!=serial.TYPE_NONE {return index,""}
            }
        }
        return serial.TYPE_NONE,fmt.tprintf("%s is not a type the code of its package declares: name a struct, enum or bit set of it, or build the game after adding it",named)
    }
    return serial.TYPE_NONE,"its kind is not one there is"
}

// Gives the table other columns: the rows and the default of a new row keep
// what each column held, by its name or a name it had (its was), and a new
// column starts at its default. message says why not, and nothing changes.
columns_set :: proc(e:^Edit,info:^core.World_Info,columns:[]asset.Records_Column) -> (message:string) {
    if !e.info.declares {return "its columns are those of the table that declares its type: change them there"}
    if at,problem:=asset.records_columns_problem(columns);problem!="" {return fmt.tprintf("column %d: %s",at+1,problem)}
    next:=Edit{id=e.id,info=e.info,folder=e.folder,allocator=e.allocator}
    next.columns=make([dynamic]asset.Records_Column,0,len(columns),e.allocator)
    append(&next.columns,..columns)
    if message=schema_make(&next,info,&e.schema,e.type);message!="" {
        delete(next.columns)
        schema_free(&next)
        return
    }
    rows:=len(e.ids)
    defaults,values:[]u8
    defaults,message=values_alloc(&next,1)
    if message=="" {values,message=values_alloc(&next,rows)}
    migration:serial.Migration
    if message=="" && serial.migration_init(&migration,&e.schema,e.type,&next.schema,next.type,context.temp_allocator)!=.None {message="out of memory"}
    if message!="" {
        mem.free_bytes(defaults,e.allocator);mem.free_bytes(values,e.allocator)
        delete(next.columns)
        schema_free(&next)
        return
    }
    defer serial.migration_destroy(&migration)
    serial.migration_apply(&migration,defaults,e.defaults,1)
    if rows>0 {serial.migration_apply(&migration,values,e.values,rows,defaults)}
    mem.free_bytes(e.defaults,e.allocator);mem.free_bytes(e.values,e.allocator)
    delete(e.columns)
    schema_free(e)
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    e.columns=next.columns
    e.schema=next.schema
    e.named=next.named
    e.type=next.type
    e.layout=next.layout
    e.defaults=defaults
    e.values=values
    return ""
}

// The columns with one more at at (at the end when out of them).
column_add :: proc(e:^Edit,info:^core.World_Info,column:asset.Records_Column,at:=-1) -> (message:string) {
    columns:=slice.clone_to_dynamic(e.columns[:],context.temp_allocator)
    inject_at(&columns,at<0 || at>len(columns) ? len(columns) : at,column)
    return columns_set(e,info,columns[:])
}

// Changes the column at at; a new name keeps its values, as the name it had
// goes to its was.
column_change :: proc(e:^Edit,info:^core.World_Info,at:int,column:asset.Records_Column) -> (message:string) {
    if at<0 || at>=len(e.columns) {return fmt.tprintf("there is no column %d",at+1)}
    columns:=slice.clone(e.columns[:],context.temp_allocator)
    changed:=column
    before:=column_name(&e.columns[at])
    if name:=column_name(&changed);name!=before {
        was:=make([dynamic]string,context.temp_allocator)
        rest:=serial.text_field(changed.was[:])
        for each in strings.fields_iterator(&rest) {
            if each!=name && each!=before {append(&was,each)}
        }
        append(&was,before)
        text:=strings.join(was[:]," ",context.temp_allocator)
        // The oldest names go first when they no longer fit.
        for len(text)>=asset.RECORDS_WAS && len(was)>1 {
            ordered_remove(&was,0)
            text=strings.join(was[:]," ",context.temp_allocator)
        }
        changed.was={}
        base.text_set(changed.was[:],text)
    }
    columns[at]=changed
    return columns_set(e,info,columns)
}

column_remove :: proc(e:^Edit,info:^core.World_Info,at:int) -> (message:string) {
    if at<0 || at>=len(e.columns) {return fmt.tprintf("there is no column %d",at+1)}
    columns:=slice.clone_to_dynamic(e.columns[:],context.temp_allocator)
    ordered_remove(&columns,at)
    return columns_set(e,info,columns[:])
}

// Moves a column to another place; its values go with it.
column_move :: proc(e:^Edit,info:^core.World_Info,from,to:int) -> (message:string) {
    if from<0 || from>=len(e.columns) || to<0 || to>=len(e.columns) {return "there is no such column"}
    columns:=slice.clone_to_dynamic(e.columns[:],context.temp_allocator)
    column:=columns[from]
    ordered_remove(&columns,from)
    inject_at(&columns,to,column)
    return columns_set(e,info,columns[:])
}

// A column of a kind as a new one starts: a name no other column has, from base_name.
column_new :: proc(e:^Edit,kind:asset.Records_Kind,base_name:="column") -> (c:asset.Records_Column) {
    name:=base_name
    for n:=2;column_find(e,name)>=0;n+=1 {name=fmt.tprintf("%s_%d",base_name,n)}
    base.text_set(c.name[:],name)
    kind_set(e,&c,kind)
    return
}

// Gives a column another kind, with the options a new column of it starts
// with: the name of its enum, or of a type, is that of the kind it had no more.
kind_set :: proc(e:^Edit,c:^asset.Records_Column,kind:asset.Records_Kind) {
    changed:=c.kind!=kind
    c.kind=kind
    if changed {c.type={}}
    #partial switch kind {
    case .Enum:
        if c.type[0]==0 {base.text_set(c.type[:],fmt.tprintf("%s_%s",type_name(e),enum_suffix(column_name(c))))}
        if c.values[0]==0 {base.text_set(c.values[:],"First Second")}
    case .String:
        if c.length<2 {c.length=32}
    case .Record:
        if c.type[0]==0 {base.text_set(c.type[:],type_name(e))}
    }
}

// The name of a column as the end of the name of a type: rarity, Rarity.
@(private)
enum_suffix :: proc(name:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    upper:=true
    for c in transmute([]u8)name {
        if c=='_' {
            strings.write_byte(&b,'_')
            upper=true
            continue
        }
        strings.write_byte(&b,upper && c>='a' && c<='z' ? c-'a'+'A' : c)
        upper=false
    }
    return strings.to_string(b)
}

// Gives the table's type another name; message says why it cannot be that one.
type_rename :: proc(e:^Edit,name:string) -> (message:string) {
    if !e.info.declares {return "its type is the one of the table that declares it"}
    if message=asset.records_type_problem(name);message!="" {return}
    e.info.type={}
    base.text_set(e.info.type[:],name)
    return ""
}

description_set :: proc(e:^Edit,text:string) {
    e.info.description={}
    base.text_set(e.info.description[:],text)
}

// ---------------------------------------------------------------- rows

// A new id for a row or a text, the next of the sequence ids: not 0, within
// ID_BITS, and not one of taken.
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

// Grows the values for more rows, aligned for the type.
@(private)
values_grow :: proc(e:^Edit,rows:int) -> bool {
    size:=row_size(e)
    if rows*size<=len(e.values) {return true}
    block,error:=mem.alloc_bytes(max(rows*size,1),row_align(e),e.allocator)
    if error!=nil {return false}
    copy(block,e.values)
    mem.free_bytes(e.values,e.allocator)
    e.values=block[:rows*size]
    return true
}

// Adds a row at the end, or after `after`, with the bytes of value or the
// defaults of the columns, and an id of the sequence ids; returns its place,
// or a message that says why not.
row_add :: proc(e:^Edit,ids:^u64,name:string,value:[]u8=nil,after:=-1) -> (row:int,message:string) {
    if message=name_refusal(e,name);message!="" {return -1,message}
    rows:=len(e.ids)
    if !values_grow(e,rows+1) {return -1,"out of memory"}
    size:=row_size(e)
    row=rows if after<0 || after>=rows else after+1
    copy(e.values[(row+1)*size:],e.values[row*size:rows*size])
    cell:=e.values[row*size:][:size]
    copy(cell,value if len(value)==size else e.defaults)
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
    size:=row_size(e)
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
    size:=row_size(e)
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
