package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:core"
import "mirai:editor/api"
import "mirai:cook/records"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The methods of the tables of game data (.records) by code: records.types,
// create, inspect, set, add, remove, rename and move, the columns of a type
// (records.column.add, set and remove), and their exchange with the CSV
// files of a spreadsheet (records.import and records.export). Rows and
// columns go by name; a change of a table is one step of the history.

Records_Api_Rejected :: struct {
    line:int,
    name:string,
    reason:string,
}

// ---------------------------------------------------------------- results

@(private)
Api_Records_Types :: struct {
    types:[]Api_Records_Type,
}
@(private)
Api_Records_Type :: struct {
    type:string `mirai:"label=The name of the struct of its rows: what a column of kind record and rows_of of records.create take"`,
    description:string `mirai:"optional"`,
    declared:string `mirai:"label=The .records that declares it, under the assets folder: where its columns change"`,
    built:bool `mirai:"label=The game library has the type; a change of its columns reaches the game once it builds again"`,
    columns:[]Api_Records_Column,
    tables:[]Api_Records_Table_Entry `mirai:"label=Its .records in the assets: the one that declares it and those that hold rows of it"`,
}
@(private)
Api_Records_Column :: struct {
    name:string,
    kind:string `mirai:"label=int, float, bool, enum, asset, text, string, record or type"`,
    count:int `mirai:"optional,label=Values it holds; none: one"`,
    length:int `mirai:"optional,label=Of a string: its bytes, its end included"`,
    min:serial.Json `mirai:"optional"`,
    max:serial.Json `mirai:"optional"`,
    unit:string `mirai:"optional"`,
    type:string `mirai:"optional,label=Of an enum: the name of its enum; of a record: the record type of the rows it names; of a type: the type of the code"`,
    values:[]string `mirai:"optional,label=Of an enum: its values, in order"`,
    asset_kind:string `mirai:"optional,label=Of an asset: the extensions it takes"`,
    description:string `mirai:"optional"`,
    was:string `mirai:"optional,label=Names it had: rows stored under them keep their values"`,
    default:serial.Json `mirai:"optional,label=What a new row holds in it"`,
}
@(private)
Api_Records_Table_Entry :: struct {
    records:base.Asset_Id,
    path:string `mirai:"label=Under the assets folder"`,
    rows:int,
}
@(private)
Api_Records_Table :: struct {
    records:base.Asset_Id,
    path:string `mirai:"optional,label=Under the assets folder"`,
    type:string `mirai:"label=The record type of its rows"`,
    rows:[]Api_Records_Row,
}
@(private)
Api_Records_Columns :: struct {
    records:base.Asset_Id,
    path:string `mirai:"optional,label=Under the assets folder"`,
    type:string `mirai:"label=The record type it declares"`,
    columns:[]Api_Records_Column,
}
@(private)
Api_Records_Row :: struct {
    id:u64 `mirai:"label=What a core.Record keeps"`,
    name:string,
    values:serial.Json `mirai:"label=The row as records.set takes it; a core.Text is the key of the texts of the game it shows (texts.set writes what it says) and a core.Record its table and row"`,
}
@(private)
Api_Records_Removed :: struct {
    records:base.Asset_Id,
    path:string `mirai:"optional"`,
    removed:[]string,
}
@(private)
Api_Records_Import :: struct {
    records:base.Asset_Id,
    path:string `mirai:"optional"`,
    updated:int `mirai:"label=Rows of the table the file changed"`,
    added:int `mirai:"label=Rows the file added at the end"`,
    rejected:[]Api_Records_Rejected `mirai:"label=Rows of the file that changed nothing"`,
}
@(private)
Api_Records_Rejected :: struct {
    line:int `mirai:"label=Of the file, from 1"`,
    row:string `mirai:"optional"`,
    reason:string,
}
@(private)
Api_Records_Export :: struct {
    records:base.Asset_Id,
    path:string `mirai:"optional"`,
    file:string `mirai:"label=Absolute"`,
    rows:int,
    columns:int,
}

// A column as records.create, records.column.add and records.column.set take it.
Api_Records_Column_Params :: struct {
    name:string `mirai:"optional,label=The name of the field: a word of ASCII letters, digits and _ that starts with a letter; a new name keeps the values of the rows"`,
    kind:string `mirai:"optional,label=int, float, bool, enum, asset, text (a key of the .strings of the game), string (a text of the row itself), record (a row of a table) or type (a type the code of its package declares)"`,
    count:int `mirai:"optional,label=A fixed array of this many values; 0: one value"`,
    length:int `mirai:"optional,label=Of a string: its bytes, its end included"`,
    min:serial.Json `mirai:"optional,label=Of an int or a float: the least value; null: none"`,
    max:serial.Json `mirai:"optional,label=Of an int or a float: the most value; null: none"`,
    unit:string `mirai:"optional,label=Of an int or a float: what it counts, as s or m/s"`,
    type:string `mirai:"optional,label=Of an enum: the name of its enum (Item_Rarity); of a record: the record type of the rows it names; of a type: a struct, enum or bit set the code of the package declares"`,
    values:[]string `mirai:"optional,label=Of an enum: the names of its values, in order; a row keeps its value by its name"`,
    asset_kind:string `mirai:"optional,label=Of an asset: the extensions it takes, separated by spaces (.tex)"`,
    description:string `mirai:"optional"`,
    default:serial.Json `mirai:"optional,label=What a new row holds in it, as records.set takes the field; a column added gives it to the rows there are too"`,
}

Api_Records_Create_Params :: struct {
    path:string `mirai:"label=Where the new table goes, under the assets folder; .records is added when missing"`,
    type:string `mirai:"optional,label=The name of the type it declares (Item, Horde_Wave): a word that starts with a letter; none: one made from the name of the file"`,
    description:string `mirai:"optional,label=What a row of the type is"`,
    columns:[]Api_Records_Column_Params `mirai:"optional,label=The columns of the type, in order; records.column.add adds more"`,
    rows_of:string `mirai:"optional,label=Instead of declaring a type: the type another table declares (of a plugin, as Ability), whose rows this one holds; records.types lists them"`,
}
Api_Records_Inspect_Params :: struct {
    records:string `mirai:"label=A table of game data: its path under the assets folder, with or without .records, or its id; records.types lists them"`,
    rows:[]string `mirai:"optional,label=Only these rows, by name"`,
}
Api_Records_Set_Params :: struct {
    records:string `mirai:"label=A table of game data: its path under the assets folder, with or without .records, or its id; records.types lists them"`,
    row:string `mirai:"label=The name of a row, as records.inspect lists them"`,
    values:serial.Json `mirai:"optional,label=Fields of the row, as records.inspect shows them, or paths of a part of one ('stats.speed', 'windows[2].to'); each is set whole: an object or a list leaves what it does not give at the default of the type, and what no key names keeps its value. A core.Record field also takes the name of a row ('sword') or its table and name ('data/weapons/sword'); a core.Text field is the key of the texts of the game it shows, as {'key':'item.sword'}: texts.set writes what the key says"`,
    name:string `mirai:"optional,label=A new name for the row"`,
}
Api_Records_Add_Params :: struct {
    records:string `mirai:"label=A table of game data: its path under the assets folder, with or without .records, or its id; records.types lists them"`,
    name:string `mirai:"label=The name of the new row: a word of ASCII letters, digits and _, unique in the table"`,
    values:serial.Json `mirai:"optional,label=Fields of the row, as records.inspect shows them, or paths of a part of one ('stats.speed', 'windows[2].to'); each is set whole: an object or a list leaves what it does not give at the default of the type, and what no key names keeps its value. A core.Record field also takes the name of a row ('sword') or its table and name ('data/weapons/sword'); a core.Text field is the key of the texts of the game it shows, as {'key':'item.sword'}: texts.set writes what the key says"`,
    after:string `mirai:"optional,label=The row it goes after; without it, at the end"`,
}
Api_Records_Remove_Params :: struct {
    records:string `mirai:"label=A table of game data: its path under the assets folder, with or without .records, or its id; records.types lists them"`,
    rows:[]string `mirai:"label=The names of the rows to remove"`,
}
Api_Records_Move_Params :: struct {
    records:string `mirai:"label=A table of game data: its path under the assets folder, with or without .records, or its id; records.types lists them"`,
    row:string `mirai:"label=The name of a row, as records.inspect lists them"`,
    after:string `mirai:"label=The row it goes right after; empty: it goes first"`,
}
Api_Records_Import_Params :: struct {
    records:string `mirai:"label=A table of game data: its path under the assets folder, with or without .records, or its id; records.types lists them"`,
    file:string `mirai:"label=A CSV file (UTF-8, comma separated, its first row the columns as records.export writes them): its path from the root of the project, or absolute"`,
}
Api_Records_Export_Params :: struct {
    records:string `mirai:"label=A table of game data: its path under the assets folder, with or without .records, or its id; records.types lists them"`,
    file:string `mirai:"label=The CSV file to write: its path from the root of the project, or absolute; an existing one is replaced"`,
}
Api_Records_Column_Add_Params :: struct {
    records:string `mirai:"label=A table that declares its type: its path under the assets folder, with or without .records, or its id"`,
    using column:Api_Records_Column_Params `mirai:"inline"`,
    after:string `mirai:"optional,label=The column it goes after; without it, at the end"`,
}
Api_Records_Column_Set_Params :: struct {
    records:string `mirai:"label=A table that declares its type: its path under the assets folder, with or without .records, or its id"`,
    column:string `mirai:"label=The name of the column, as records.types lists them"`,
    using change:Api_Records_Column_Params `mirai:"inline"`,
}
Api_Records_Column_Remove_Params :: struct {
    records:string `mirai:"label=A table that declares its type: its path under the assets folder, with or without .records, or its id"`,
    column:string `mirai:"label=The name of the column; the values of the rows in it go with it"`,
}

// Updates the rows of the table c.edit that the records of a CSV name and adds
// the others at the end, a row at a time: a record with a cell that does not
// read changes nothing. default: the bytes of a new row.
records_api_import_rows :: proc(s:^Session,c:^records.Context,leaves:[]records.Leaf,columns:[]records.Csv_Column,parsed:[][]string,lines:[]int,default:[]u8) -> (updated,added:int,rejected:[]Records_Api_Rejected) {
    e:=c.edit
    out:=make([dynamic]Records_Api_Rejected,context.temp_allocator)
    name_column:=0
    for column,i in columns {
        if column.leaf<0 {name_column=i}
    }
    scratch:=make([]u8,records.row_size(e),context.temp_allocator)
    for record,at in parsed {
        line:=lines[at]
        name:=strings.trim_space(record[name_column]) if name_column<len(record) else ""
        if name=="" {
            append(&out,Records_Api_Rejected{line,"","the row has no name: write it in the name column"})
            continue
        }
        if len(record)>len(columns) {
            append(&out,Records_Api_Rejected{line,name,fmt.tprintf("it has %d cells and the first row %d: put the text of a cell with commas in double quotes",len(record),len(columns))})
            continue
        }
        row:=records.row_find(e,name)
        if row>=0 {copy(scratch,records.row_bytes(e,row))} else {copy(scratch,default)}
        if message:=records.row_cells(c,leaves,columns,record,scratch);message!="" {
            append(&out,Records_Api_Rejected{line,name,message})
            continue
        }
        if row<0 {
            message:string
            if row,message=records.row_add(e,&s.id_state,name,scratch);message!="" {
                append(&out,Records_Api_Rejected{line,name,message})
                continue
            }
            added+=1
        } else {
            copy(records.row_bytes(e,row),scratch)
            updated+=1
        }
    }
    return updated,added,out[:]
}

// ---------------------------------------------------------------- the session

// The table the params name: its path under the assets folder, with or
// without .records, or its id; loaded as it is now into e.
@(private)
records_api_open :: proc(s:^Session,call:^api.Call,name:string,e:^records.Edit) -> bool {
    a:=s.app.assets
    if a==nil || s.app.info==nil || !s.has_project {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no project: open one to edit its tables")
        return false
    }
    host.assets_scan(a)
    id:base.Asset_Id
    found:=false
    if parsed,is_id:=serial.text_parse_asset_id(name);is_id {
        if file,known:=asset.registry_find(&a.registry,parsed);known && file.kind==asset.KIND_RECORDS {id,found=parsed,true}
    }
    for candidate in ([2]string{name,fmt.tprintf("%s.records",name)}) {
        if found {break}
        if file,known:=asset.registry_find_path(&a.registry,candidate);known && file.kind==asset.KIND_RECORDS {id,found=file.id,true}
    }
    if !found {
        api.call_failf(call,api.INVALID_PARAMS,"%q is not a .records of the assets: records.types lists the tables of each type",name)
        return false
    }
    if message:=records_edit_load(s,id,e,context.temp_allocator);message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return false
    }
    return true
}

// What the rows of e read and write by: the schema its columns make and the
// tables of every type a reference of them names.
@(private)
records_api_context :: proc(s:^Session,e:^records.Edit) -> (c:records.Context,leaves:[]records.Leaf) {
    files:=host.app_record_files(s.app)
    tables:=make([]records.Table_File,len(files),context.temp_allocator)
    for &file,i in files {tables[i]={id=file.id,path=file.path,type=serial.text_field(file.type[:]),declares=file.declares}}
    return records.context_make(e,s.app.info,&s.app.assets.registry,&s.app.assets.types,tables)
}

// The table as records.inspect gives it, with the rows at the places given;
// nil: every row.
@(private)
records_api_table :: proc(s:^Session,call:^api.Call,e:^records.Edit,rows:[]int,all:bool) {
    count:=all ? records.row_count(e) : len(rows)
    shown:=make([]Api_Records_Row,count,call.allocator)
    for &row,i in shown {row=records_api_row(e,all ? i : rows[i],call.allocator)}
    api.call_result(call,Api_Records_Table)^={e.id,asset_path(s,e.id),strings.clone(records.type_name(e),call.allocator),shown}
}

records_api_row :: proc(e:^records.Edit,row:int,allocator:=context.temp_allocator) -> Api_Records_Row {
    return {e.ids[row],strings.clone(records.row_name(e,row),allocator),serial.Json(records.row_text(e,row,allocator))}
}

// Writes the table as one step of the history; false with the call failed.
@(private)
records_api_publish :: proc(s:^Session,call:^api.Call,e:^records.Edit,label:string) -> bool {
    if !api_edit_begin(s,call,label) {return false}
    problem:=records_edit_publish(s,e,label)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem)}
    return api_edit_end(s,call,problem=="")
}

@(private)
records_api_row_named :: proc(call:^api.Call,e:^records.Edit,name:string) -> int {
    row:=records.row_find(e,name)
    if row<0 {api.call_failf(call,api.INVALID_PARAMS,"the table has no row %q: records.inspect lists its rows",name)}
    return row
}

// A file the params name: from the root of the project, or absolute; "" when
// it names no folder.
@(private)
records_api_file :: proc(s:^Session,path:string) -> string {
    native,ok:=project.path_native(path)
    if !ok || native=="" {return ""}
    if filepath.is_abs(native) {return project.path_absolute(native,context.temp_allocator)}
    if s.project_root=="" {return ""}
    return project.path_absolute(project.path(s.project_root,native,allocator=context.temp_allocator),context.temp_allocator)
}

@(private)
records_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="records.types",summary="The record types the .records of the project declare: their columns, whether the game library has them built, and their tables.",result=type_info_of(Api_Records_Types),flags={.Read_Only},run=api_records_types})
    api_register(s,st,{name="records.create",params=type_info_of(Api_Records_Create_Params),summary="Makes a new table (.records) under the assets folder: one that declares a record type with the columns given, which the build generates as the struct of its rows, or one that holds rows of a type another table declares.",result=type_info_of(Api_Records_Columns),run=api_records_create})
    api_register(s,st,{name="records.inspect",params=type_info_of(Api_Records_Inspect_Params),summary="The rows of a table of game data (.records) with their ids, names and values.",result=type_info_of(Api_Records_Table),flags={.Read_Only},run=api_records_inspect})
    api_register(s,st,{name="records.set",params=type_info_of(Api_Records_Set_Params),summary="Changes the values or the name of a row of a table of game data.",result=type_info_of(Api_Records_Table),run=api_records_set})
    api_register(s,st,{name="records.add",params=type_info_of(Api_Records_Add_Params),summary="Adds a row to a table of game data with the defaults of its columns and the values given.",result=type_info_of(Api_Records_Table),run=api_records_add})
    api_register(s,st,{name="records.remove",params=type_info_of(Api_Records_Remove_Params),summary="Removes rows of a table of game data by name; the references to them are left as they are.",result=type_info_of(Api_Records_Removed),flags={.Destructive},run=api_records_remove})
    api_register(s,st,{name="records.move",params=type_info_of(Api_Records_Move_Params),summary="Moves a row of a table of game data to another place of its order; its id stays.",result=type_info_of(Api_Records_Table),run=api_records_move})
    api_register(s,st,{name="records.import",params=type_info_of(Api_Records_Import_Params),summary="Updates the rows of a table of game data from a CSV file by their names and adds the rows it lacks, as one step of the history.",result=type_info_of(Api_Records_Import),run=api_records_import})
    api_register(s,st,{name="records.export",params=type_info_of(Api_Records_Export_Params),summary="Writes the rows of a table of game data to a CSV file that records.import reads back.",result=type_info_of(Api_Records_Export),flags={.Idempotent},run=api_records_export})
    api_register(s,st,{name="records.column.add",params=type_info_of(Api_Records_Column_Add_Params),summary="Adds a column to the type a table declares; its rows take its default. The game reads it once it builds again.",result=type_info_of(Api_Records_Columns),run=api_records_column_add})
    api_register(s,st,{name="records.column.set",params=type_info_of(Api_Records_Column_Set_Params),summary="Changes a column of the type a table declares: its name (the rows keep their values), kind, options, default or description.",result=type_info_of(Api_Records_Columns),run=api_records_column_set})
    api_register(s,st,{name="records.column.remove",params=type_info_of(Api_Records_Column_Remove_Params),summary="Removes a column of the type a table declares, with the values of its rows.",result=type_info_of(Api_Records_Columns),flags={.Destructive},run=api_records_column_remove})
}

// ---------------------------------------------------------------- columns

@(private)
RECORDS_API_KINDS :: [asset.Records_Kind]string{.Int="int",.Float="float",.Bool="bool",.Enum="enum",.Asset="asset",.Text="text",.String="string",.Record="record",.Type="type"}

// The columns of a table as the methods answer them.
@(private)
records_api_columns :: proc(e:^records.Edit,allocator:=context.temp_allocator) -> []Api_Records_Column {
    kinds:=RECORDS_API_KINDS
    out:=make([]Api_Records_Column,len(e.columns),allocator)
    for &c,at in e.columns {
        shown:=&out[at]
        shown.name=strings.clone(records.column_name(&c),allocator)
        shown.kind=kinds[c.kind]
        shown.count=int(c.count)
        if c.kind==.String {shown.length=int(c.length)}
        if c.has_min {shown.min=serial.Json(fmt.aprint(c.min,allocator=allocator))}
        if c.has_max {shown.max=serial.Json(fmt.aprint(c.max,allocator=allocator))}
        shown.unit=strings.clone(serial.text_field(c.unit[:]),allocator)
        shown.type=strings.clone(serial.text_field(c.type[:]),allocator)
        if c.kind==.Enum {shown.values=strings.fields(serial.text_field(c.values[:]),allocator) or_else nil}
        shown.asset_kind=strings.clone(serial.text_field(c.asset_kind[:]),allocator)
        shown.description=strings.clone(serial.text_field(c.description[:]),allocator)
        shown.was=strings.clone(serial.text_field(c.was[:]),allocator)
        if field,found:=records.column_field(e,at);found && e.defaults!=nil {
            part:=e.defaults[field.offset:][:e.schema.types[field.type].size]
            if !mem.check_zero(part) {
                w:serial.Writer
                serial.writer_init(&w,64,allocator)
                serial.text_write(&w,&e.schema,field.type,part,.Line,is_text=.Text in field.flags)
                shown.default=serial.Json(serial.writer_bytes(&w))
            }
        }
    }
    return out
}

@(private)
records_api_columns_result :: proc(s:^Session,call:^api.Call,e:^records.Edit) {
    api.call_result(call,Api_Records_Columns)^={e.id,asset_path(s,e.id),strings.clone(records.type_name(e),call.allocator),records_api_columns(e,call.allocator)}
}

// The options of params over a column, those given: by name in the call
// (given), or set when the column is new. message says which does not fit
// and how to fix it.
@(private)
records_api_column_put :: proc(c:^asset.Records_Column,e:^records.Edit,p:^Api_Records_Column_Params,call:^api.Call,new:bool) -> (message:string) {
    given :: proc(call:^api.Call,name:string,new:bool,set:bool) -> bool {return new ? set : api.call_given(call,name)}
    if given(call,"name",new,p.name!="") {
        c.name={}
        if !base.text_set(c.name[:],p.name) {return fmt.tprintf("name %q is longer than %d bytes",p.name,asset.RECORDS_NAME-1)}
    }
    if given(call,"kind",new,p.kind!="") {
        kinds:=RECORDS_API_KINDS
        found:=false
        for name,kind in kinds {
            if strings.equal_fold(name,strings.trim_space(p.kind)) {
                records.kind_set(e,c,kind)
                found=true
            }
        }
        if !found {return fmt.tprintf("kind %q is not one there is: give int, float, bool, enum, asset, text, string, record or type",p.kind)}
    }
    if given(call,"count",new,p.count!=0) {
        if p.count<0 || p.count>asset.RECORDS_COUNT {return fmt.tprintf("count %d is not from 0 (one value) to %d",p.count,asset.RECORDS_COUNT)}
        c.count=u16(p.count)
    }
    if given(call,"length",new,p.length!=0) {
        if p.length<2 || p.length>asset.RECORDS_LENGTH {return fmt.tprintf("length %d is not from 2 to %d bytes",p.length,asset.RECORDS_LENGTH)}
        c.length=u16(p.length)
    }
    bound :: proc(text:serial.Json,has:^bool,value:^f64,name:string) -> string {
        trimmed:=strings.trim_space(string(text))
        if trimmed=="" || trimmed=="null" {
            has^=false
            return ""
        }
        number,ok:=strconv.parse_f64(trimmed)
        if !ok {return fmt.tprintf("%s %s is not a number, nor null for none",name,trimmed)}
        has^,value^=true,number
        return ""
    }
    if new ? p.min!="" : json_member_given(call,"min") {
        if message=bound(p.min,&c.has_min,&c.min,"min");message!="" {return}
    }
    if new ? p.max!="" : json_member_given(call,"max") {
        if message=bound(p.max,&c.has_max,&c.max,"max");message!="" {return}
    }
    text :: proc(field:[]u8,value,name:string) -> string {
        mem.zero_slice(field)
        if !base.text_set(field,value) {return fmt.tprintf("%s is longer than %d bytes",name,len(field)-1)}
        return ""
    }
    if given(call,"unit",new,p.unit!="") {if message=text(c.unit[:],p.unit,"unit");message!="" {return}}
    if given(call,"type",new,p.type!="") {if message=text(c.type[:],p.type,"type");message!="" {return}}
    if given(call,"values",new,len(p.values)>0) {if message=text(c.values[:],strings.join(p.values," ",context.temp_allocator),"values");message!="" {return}}
    if given(call,"asset_kind",new,p.asset_kind!="") {if message=text(c.asset_kind[:],p.asset_kind,"asset_kind");message!="" {return}}
    if given(call,"description",new,p.description!="") {if message=text(c.description[:],p.description,"description");message!="" {return}}
    return ""
}

// Whether the params of the call have a key, also when it is null.
@(private)
json_member_given :: proc(call:^api.Call,name:string) -> bool {
    return api.json_member(call.raw,name)!=""
}

// Puts the default params give a column in the defaults of the table; with
// rows, the rows there are take it too.
@(private)
records_api_column_default :: proc(s:^Session,e:^records.Edit,name:string,value:serial.Json,rows:bool) -> (message:string) {
    if strings.trim_space(string(value))=="" {return ""}
    at:=records.column_find(e,name)
    field,_:=records.column_field(e,at)
    c,_:=records_api_context(s,e)
    text:=fmt.tprintf(`{{%q:%s}}`,name,string(value))
    if message=records.values_put(&c,e.defaults,text);message!="" {return fmt.tprintf("default: %s",message)}
    if rows {
        size:=int(e.schema.types[field.type].size)
        for row in 0..<records.row_count(e) {copy(records.row_bytes(e,row)[field.offset:][:size],e.defaults[field.offset:][:size])}
    }
    return ""
}

// A table that declares its type; false with the call failed for one that
// holds rows of another's.
@(private)
records_api_declares :: proc(s:^Session,call:^api.Call,e:^records.Edit) -> bool {
    if e.info.declares {return true}
    api.call_failf(call,api.INVALID_PARAMS,"%s holds rows of %s, which %s declares: change its columns there",asset_path(s,e.id),records.type_name(e),asset_path(s,e.declaring))
    return false
}

@(private)
records_api_column_named :: proc(call:^api.Call,e:^records.Edit,name:string) -> int {
    at:=records.column_find(e,name)
    if at<0 {
        names:=make([dynamic]string,context.temp_allocator)
        for &c in e.columns {append(&names,records.column_name(&c))}
        api.call_failf(call,api.INVALID_PARAMS,"%s has no column %q: its columns are %s",records.type_name(e),name,len(names)>0 ? strings.join(names[:],", ",context.temp_allocator) : "none yet; records.column.add adds one")
    }
    return at
}

@(private)
api_records_column_add :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Records_Column_Add_Params)
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) || !records_api_declares(s,call,&e) {return}
    if p.column.name=="" || p.column.kind=="" {
        api.call_fail(call,api.INVALID_PARAMS,"a column needs a name and a kind: give both, as {\"name\":\"damage\",\"kind\":\"float\"}")
        return
    }
    c:asset.Records_Column
    if message:=records_api_column_put(&c,&e,&p.column,call,true);message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    at:=-1
    if p.after!="" {
        if at=records_api_column_named(call,&e,p.after);at<0 {return}
        at+=1
    }
    if message:=records.column_add(&e,s.app.info,c,at);message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    if message:=records_api_column_default(s,&e,p.column.name,p.column.default,true);message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    if !records_api_publish(s,call,&e,"Add column") {return}
    records_api_columns_result(s,call,&e)
}

@(private)
api_records_column_set :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Records_Column_Set_Params)
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) || !records_api_declares(s,call,&e) {return}
    at:=records_api_column_named(call,&e,p.column)
    if at<0 {return}
    c:=e.columns[at]
    if message:=records_api_column_put(&c,&e,&p.change,call,false);message!="" {
        api.call_failf(call,api.INVALID_PARAMS,"column %s: %s",p.column,message)
        return
    }
    if message:=records.column_change(&e,s.app.info,at,c);message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    if message:=records_api_column_default(s,&e,records.column_name(&e.columns[at]),p.change.default,false);message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    if !records_api_publish(s,call,&e,"Change column") {return}
    records_api_columns_result(s,call,&e)
}

@(private)
api_records_column_remove :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Records_Column_Remove_Params)
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) || !records_api_declares(s,call,&e) {return}
    at:=records_api_column_named(call,&e,p.column)
    if at<0 {return}
    if message:=records.column_remove(&e,s.app.info,at);message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    if !records_api_publish(s,call,&e,"Remove column") {return}
    records_api_columns_result(s,call,&e)
}

// ---------------------------------------------------------------- tables

@(private)
api_records_types :: proc(s:^Session,call:^api.Call) {
    if s.app.assets!=nil {host.assets_scan(s.app.assets)}
    types:=make([dynamic]Api_Records_Type,call.allocator)
    for &file in host.app_record_files(s.app) {
        if !file.declares {continue}
        e:records.Edit
        if records_edit_load(s,file.id,&e,context.temp_allocator)!="" {continue}
        name:=records.type_name(&e)
        shown:=Api_Records_Type{type=strings.clone(name,call.allocator),description=strings.clone(records.description(&e),call.allocator),declared=strings.clone(file.path,call.allocator),built=records_built(s,name)>=0}
        shown.columns=records_api_columns(&e,call.allocator)
        tables:=make([dynamic]Api_Records_Table_Entry,call.allocator)
        for &table in records_tables(s,name) {
            ids,_,ok:=records.rows_read(&s.app.assets.registry,&s.app.assets.types,table.id)
            append(&tables,Api_Records_Table_Entry{table.id,strings.clone(table.path,call.allocator),len(ids) if ok else 0})
        }
        shown.tables=tables[:]
        append(&types,shown)
    }
    api.call_result(call,Api_Records_Types).types=types[:]
}

@(private)
api_records_create :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Records_Create_Params)
    if s.app.assets==nil || !s.has_project {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no project: open one to make tables")
        return
    }
    host.assets_scan(s.app.assets)
    path:=strings.has_suffix(p.path,".records") ? p.path : fmt.tprintf("%s.records",p.path)
    file:=scene_file(s,path)
    if file=="" {
        api.call_failf(call,api.INVALID_PARAMS,"%s: %s",path,document_error_text(.Bad_Path))
        return
    }
    if file_exists(s,file) {
        api.call_failf(call,api.INVALID_PARAMS,"%s already exists: records.set and records.add change its rows, records.column.add its columns",path)
        return
    }
    e:records.Edit
    if p.rows_of!="" {
        if p.type!="" || len(p.columns)>0 {
            api.call_fail(call,api.INVALID_PARAMS,"rows_of makes a table of rows of a type another declares, which has no type or columns of its own: give rows_of alone, or type and columns")
            return
        }
        declaring:=records_declaring(s,p.rows_of)
        if declaring.id=={} {
            api.call_failf(call,api.INVALID_PARAMS,"no .records declares %s: records.types lists the record types there are",p.rows_of)
            return
        }
        if message:=records_edit_load(s,declaring.id,&e,context.temp_allocator);message!="" {
            api.call_fail(call,api.INVALID_PARAMS,message)
            return
        }
        e.id,e.file,e.declaring=asset_id_new(s),file,declaring.id
        e.info.declares=false
        e.info.description={}
        clear(&e.ids);clear(&e.names)
        e.values=e.values[:0]
    } else {
        type:=p.type if p.type!="" else records.type_of_file(path)
        if other:=records_declaring(s,type);other.id!={} {
            api.call_failf(call,api.INVALID_PARAMS,"%s already declares %s: give another type, or rows_of %s to hold rows of it",other.path,type,type)
            return
        }
        if message:=records.create(asset_id_new(s),file,records.folder_of(path),type,&e,context.temp_allocator);message!="" {
            api.call_failf(call,api.INVALID_PARAMS,"type: %s",message)
            return
        }
        records.description_set(&e,p.description)
        for &column,i in p.columns {
            if column.name=="" || column.kind=="" {
                api.call_failf(call,api.INVALID_PARAMS,"columns[%d]: a column needs a name and a kind",i)
                return
            }
            c:asset.Records_Column
            message:=records_api_column_put(&c,&e,&column,call,true)
            if message=="" {message=records.column_add(&e,s.app.info,c)}
            if message=="" {message=records_api_column_default(s,&e,column.name,column.default,false)}
            if message!="" {
                api.call_failf(call,api.INVALID_PARAMS,"columns[%d] (%s): %s",i,column.name,message)
                return
            }
        }
    }
    if !records_api_publish(s,call,&e,"Create records") {return}
    host.assets_scan(s.app.assets)
    records_api_columns_result(s,call,&e)
}

@(private)
api_records_inspect :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Records_Inspect_Params)
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) {return}
    rows:=make([dynamic]int,context.temp_allocator)
    for name in p.rows {
        row:=records_api_row_named(call,&e,name)
        if row<0 {return}
        append(&rows,row)
    }
    records_api_table(s,call,&e,rows[:],!api.call_given(call,"rows"))
}

// Puts the values of the params over a row; false with the call failed.
@(private)
records_api_row_put :: proc(call:^api.Call,c:^records.Context,row:int,values:serial.Json) -> bool {
    value:=slice.clone(records.row_bytes(c.edit,row),context.temp_allocator)
    if message:=records.values_put(c,value,string(values));message!="" {
        api.call_failf(call,api.INVALID_PARAMS,"row %s: %s",records.row_name(c.edit,row),message)
        return false
    }
    copy(records.row_bytes(c.edit,row),value)
    return true
}

@(private)
api_records_set :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Records_Set_Params)
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) {return}
    row:=records_api_row_named(call,&e,p.row)
    if row<0 {return}
    c,_:=records_api_context(s,&e)
    if !records_api_row_put(call,&c,row,p.values) {return}
    if api.call_given(call,"name") && p.name!=p.row {
        if message:=records.row_rename(&e,row,p.name);message!="" {
            api.call_fail(call,api.INVALID_PARAMS,message)
            return
        }
    }
    if !records_api_publish(s,call,&e,"Records") {return}
    records_api_table(s,call,&e,[]int{row},false)
}

@(private)
api_records_add :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Records_Add_Params)
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) {return}
    after:=-1
    if api.call_given(call,"after") {
        if after=records_api_row_named(call,&e,p.after);after<0 {return}
    }
    row,message:=records.row_add(&e,&s.id_state,p.name,nil,after)
    if message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    c,_:=records_api_context(s,&e)
    if !records_api_row_put(call,&c,row,p.values) {return}
    if !records_api_publish(s,call,&e,"Add record") {return}
    records_api_table(s,call,&e,[]int{row},false)
}

@(private)
api_records_remove :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Records_Remove_Params)
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) {return}
    for name in p.rows {
        if records_api_row_named(call,&e,name)<0 {return}
    }
    for name in p.rows {
        if row:=records.row_find(&e,name);row>=0 {records.row_remove(&e,row)}
    }
    if len(p.rows)>0 && !records_api_publish(s,call,&e,"Remove records") {return}
    api.call_result(call,Api_Records_Removed)^={e.id,asset_path(s,e.id),p.rows}
}

// The index a row ends at, moved right after the row at another index.
@(private)
records_move_place :: proc "contextless" (row,after:int) -> int {return after+1 if after<row else after}

@(private)
api_records_move :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Records_Move_Params)
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) {return}
    row:=records_api_row_named(call,&e,p.row)
    if row<0 {return}
    to:=0
    if p.after!="" {
        after:=records_api_row_named(call,&e,p.after)
        if after<0 {return}
        if after==row {
            api.call_failf(call,api.INVALID_PARAMS,"after names the row that moves: %q",p.after)
            return
        }
        to=records_move_place(row,after)
    }
    records.row_move(&e,row,to)
    if !records_api_publish(s,call,&e,"Move record") {return}
    records_api_table(s,call,&e,[]int{to},false)
}

@(private)
api_records_import :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Records_Import_Params)
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) {return}
    file:=records_api_file(s,p.file)
    if file=="" {
        api.call_failf(call,api.INVALID_PARAMS,"file %q names no folder: give its path from the root of the project, or absolute",p.file)
        return
    }
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if error!=nil {
        api.call_failf(call,api.INVALID_PARAMS,"%s could not be read: %v",file,error)
        return
    }
    text:=string(data)
    if !utf8.valid_string(text) {
        api.call_failf(call,api.INVALID_PARAMS,"%s is not UTF-8: save it from the spreadsheet as CSV UTF-8",file)
        return
    }
    parsed,lines,failure:=importer.csv_records(text,context.temp_allocator)
    if failure!="" {
        api.call_failf(call,api.INVALID_PARAMS,"%s: %s",file,failure)
        return
    }
    if len(parsed)==0 {
        api.call_failf(call,api.INVALID_PARAMS,"%s is empty: its first row names the columns, as records.export writes them",file)
        return
    }
    c,leaves:=records_api_context(s,&e)
    columns,message:=records.csv_header(&c,leaves,parsed[0])
    if message!="" {
        api.call_failf(call,api.INVALID_PARAMS,"%s, line %d: %s",file,lines[0],message)
        return
    }
    updated,added,rejected:=records_api_import_rows(s,&c,leaves,columns,parsed[1:],lines[1:],c.default)
    if updated+added>0 && !records_api_publish(s,call,&e,"Import records") {return}
    shown:=make([]Api_Records_Rejected,len(rejected),call.allocator)
    for each,i in rejected {shown[i]={each.line,each.name,each.reason}}
    api.call_result(call,Api_Records_Import)^={e.id,asset_path(s,e.id),updated,added,shown}
}

@(private)
api_records_export :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Records_Export_Params)
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) {return}
    file:=records_api_file(s,p.file)
    if file=="" {
        api.call_failf(call,api.INVALID_PARAMS,"file %q names no folder: give its path from the root of the project, or absolute",p.file)
        return
    }
    c,leaves:=records_api_context(s,&e)
    text,columns:=records.csv_text(&c,leaves)
    if serial.file_write_atomic(file,transmute([]u8)text)!=.None {
        api.call_failf(call,api.INVALID_PARAMS,"%s could not be written; its folder has to exist",file)
        return
    }
    api.call_result(call,Api_Records_Export)^={e.id,asset_path(s,e.id),file,records.row_count(&e),columns}
}
