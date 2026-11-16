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
import "mirai:editor/records"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The methods of the tables of game data (.records) by code: records.types,
// create, inspect, set, add, remove, rename and move, the columns of a type
// (records.column.add, set and remove), and their exchange with the CSV
// files of a spreadsheet (records.import and records.export). Rows and
// columns go by name; a change of a table is one step of the history.

// What a core.Record(T) holds, for any T.
Records_Api_Ref :: struct {table:base.Asset_Id,row:core.Record_Id}
#assert(size_of(Records_Api_Ref)==size_of(core.Record(Records_Api_Ref)))

Records_Api_Ref_Type :: struct {
    type:serial.Type_Index, // of core.Record(T) in the schema
    record:string,          // T
}

// A table whose rows a core.Record names.
Records_Api_Rows :: struct {
    record:string, // the type of its rows
    id:base.Asset_Id,
    path:string, // under the assets folder
    ids:[]u64,
    names:[]asset.Records_Name,
}

// What reading and writing the rows of a table by text needs.
Records_Api_Context :: struct {
    schema:^serial.Schema,
    type:serial.Type_Index,  // of the rows
    name:string,             // the type of the rows
    refs:[]Records_Api_Ref_Type,
    tables:[]Records_Api_Rows,
    edit:^records.Edit,      // the table that changes: its rows stand for those of its file in tables
    registry:^asset.Registry, // nil: assets go by id only
    default:[]u8,            // a new row of the type; nil: zeros
}

Records_Api_Leaf_Kind :: enum u8 {
    Value,  // a number, bool, enum, entity or asset, by its path
    Bytes,  // a text field ([N]u8 mirai:"text")
    Ref,    // a core.Record
    Member, // of a bit set, as a bool
}

// A value of a row that is one cell of a CSV.
Records_Api_Leaf :: struct {
    path:string, // as serial paths write it
    kind:Records_Api_Leaf_Kind,
    type:serial.Type_Index,
    offset:int,
    record:string, // Ref: the type of the rows it names
}

Records_Api_Column :: struct {
    title:string,
    leaf:int, // -1: the name of the row
}

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

// ---------------------------------------------------------------- the shape of a row

// The record type a core.Record of the schema names; "" for another type.
records_api_ref_record :: proc(c:^Records_Api_Context,type:serial.Type_Index) -> string {
    for r in c.refs {
        if r.type==type {return r.record}
    }
    return ""
}

// Every value of a row that is a cell of a CSV, in the order of its fields.
records_api_leaves :: proc(c:^Records_Api_Context,allocator:=context.temp_allocator) -> []Records_Api_Leaf {
    out:=make([dynamic]Records_Api_Leaf,allocator)
    add :: proc(c:^Records_Api_Context,type:serial.Type_Index,path:string,offset:int,text:bool,out:^[dynamic]Records_Api_Leaf,depth:int) {
        s:=c.schema
        if depth>16 || !serial.type_valid(s,type) {return}
        if record:=records_api_ref_record(c,type);record!="" {
            append(out,Records_Api_Leaf{path=path,kind=.Ref,type=type,offset=offset,record=record})
            return
        }
        if text && serial.type_is_bytes(s,type) {
            append(out,Records_Api_Leaf{path=path,kind=.Bytes,type=type,offset=offset})
            return
        }
        t:=s.types[type]
        #partial switch records_api_kind(t) {
        case .Struct:
            for field in serial.schema_fields(s,type) {
                if .Transient in field.flags {continue}
                child:=path=="" ? field.name : fmt.aprintf("%s.%s",path,field.name,allocator=context.allocator)
                add(c,field.type,child,offset+int(field.offset),.Text in field.flags,out,depth+1)
            }
        case .Array:
            size:=int(s.types[t.elem].size)
            for i in 0..<int(t.count) {add(c,t.elem,fmt.aprintf("%s[%d]",path,i,allocator=context.allocator),offset+i*size,text,out,depth+1)}
        case .Bit_Set:
            for choice in records_api_choices(s,type) {
                append(out,Records_Api_Leaf{path=fmt.aprintf("%s.%s",path,choice.name,allocator=context.allocator),kind=.Member,type=type,offset=offset})
            }
        case:
            append(out,Records_Api_Leaf{path=path,kind=.Value,type=type,offset=offset})
        }
    }
    context.allocator=allocator
    add(c,c.type,"",0,false,&out,0)
    return out[:]
}

// The kind a type is read and written as: a @(names) integer as an enum or a bit set.
records_api_kind :: proc(t:serial.Type) -> serial.Type_Kind {
    switch t.named {
    case .None:
    case .Values: return .Enum
    case .Bits:   return .Bit_Set
    }
    return t.kind
}

// The names of the values of an enum or a @(names) integer, or of the bits of
// a bit set or a mask.
records_api_choices :: proc(s:^serial.Schema,type:serial.Type_Index) -> []serial.Choice {
    if !serial.type_valid(s,type) {return nil}
    t:=s.types[type]
    #partial switch records_api_kind(t) {
    case .Enum,.Bit_Set: return s.choices[t.first:][:t.count]
    }
    return nil
}

records_api_leaf_find :: proc(leaves:[]Records_Api_Leaf,path:string) -> int {
    for leaf,i in leaves {
        if leaf.path==path {return i}
    }
    return -1
}

// ---------------------------------------------------------------- references and assets

records_api_rows :: proc(c:^Records_Api_Context,t:^Records_Api_Rows) -> (ids:[]u64,names:[]asset.Records_Name) {
    if c.edit!=nil && t.id==c.edit.id {return c.edit.ids[:],c.edit.names[:]}
    return t.ids,t.names
}

records_api_path_bare :: proc(path:string) -> string {return strings.trim_suffix(path,".records")}

// The row a text names among the tables of a record type: "name" when one
// of them has it, "table/name" with the path of the table, with or without
// .records, or the serial form {"table":...,"row":...}.
records_api_ref_parse :: proc(c:^Records_Api_Context,record:string,text:string) -> (ref:Records_Api_Ref,message:string) {
    text:=strings.trim_space(text)
    type_name:=record
    if strings.has_prefix(text,"{") {
        values:[2]string
        if !api.object_values(context.temp_allocator,text,{"table","row"},values[:]) {return {},fmt.tprintf("%q is not a reference: give the name of a row of %s",text,type_name)}
        table,named:=api.string_value(context.temp_allocator,values[0])
        id,valid:=serial.text_parse_asset_id(table)
        row,number:=strconv.parse_u64(values[1])
        if !named || !valid || !number {return {},fmt.tprintf("%q is not a reference: %s, or the name of a row of %s",text,`{"table":"<32 hex digits>","row":<id>}`,type_name)}
        return {id,core.Record_Id(row)},""
    }
    tables:=make([dynamic]string,context.temp_allocator)
    for &t in c.tables {
        if t.record==record {append(&tables,records_api_path_bare(t.path))}
    }
    if len(tables)==0 {return {},fmt.tprintf("%s has no tables to name a row of: records.create makes one",type_name)}
    if slash:=strings.last_index_byte(text,'/');slash>=0 {
        table,name:=text[:slash],text[slash+1:]
        for &t in c.tables {
            if t.record!=record || records_api_path_bare(t.path)!=records_api_path_bare(table) {continue}
            ids,names:=records_api_rows(c,&t)
            for &n,i in names {
                if serial.text_field(n[:])==name {return {t.id,core.Record_Id(ids[i])},""}
            }
            return {},fmt.tprintf("%s has no row %s: records.inspect of %s lists its rows",t.path,name,t.path)
        }
        return {},fmt.tprintf("%s is not a table of %s: they are %s",table,type_name,strings.join(tables[:],", ",context.temp_allocator))
    }
    found:Records_Api_Ref
    holders:=make([dynamic]string,context.temp_allocator)
    for &t in c.tables {
        if t.record!=record {continue}
        ids,names:=records_api_rows(c,&t)
        for &n,i in names {
            if serial.text_field(n[:])!=text {continue}
            found={t.id,core.Record_Id(ids[i])}
            append(&holders,records_api_path_bare(t.path))
            break
        }
    }
    switch len(holders) {
    case 1: return found,""
    case 0: return {},fmt.tprintf("no table of %s has a row %q: records.inspect of %s lists their rows",type_name,text,strings.join(tables[:],", ",context.temp_allocator))
    }
    return {},fmt.tprintf("%s is a row of %d tables of %s: write its table too, as %s/%s",text,len(holders),type_name,holders[0],text)
}

// A reference as records_api_ref_parse reads it: the name of the row, with
// its table when another table of the type has a row of that name.
records_api_ref_text :: proc(c:^Records_Api_Context,record:string,ref:Records_Api_Ref) -> string {
    if ref=={} {return ""}
    for &t in c.tables {
        if t.record!=record || t.id!=ref.table {continue}
        ids,names:=records_api_rows(c,&t)
        for id,i in ids {
            if id!=u64(ref.row) {continue}
            name:=serial.text_field(names[i][:])
            holders:=0
            for &other in c.tables {
                if other.record!=record {continue}
                _,other_names:=records_api_rows(c,&other)
                for &n in other_names {
                    if serial.text_field(n[:])==name {holders+=1;break}
                }
            }
            return holders==1 ? name : fmt.tprintf("%s/%s",records_api_path_bare(t.path),name)
        }
    }
    out:serial.Writer
    serial.writer_init(&out,64,context.temp_allocator)
    records_api_ref_write(&out,ref)
    return string(serial.writer_bytes(&out))
}

records_api_ref_write :: proc(out:^serial.Writer,ref:Records_Api_Ref) {
    serial.text_write_raw(out,`{"table":"`)
    serial.text_write_asset_id(out,ref.table)
    serial.text_write_raw(out,`","row":`)
    serial.text_write_uint(out,u64(ref.row))
    serial.write_u8(out,'}')
}

records_api_asset_parse :: proc(c:^Records_Api_Context,text:string) -> (id:base.Asset_Id,message:string) {
    text:=strings.trim_space(text)
    if parsed,is_id:=serial.text_parse_asset_id(text);is_id {return parsed,""}
    if c.registry!=nil {
        if file,found:=asset.registry_find_path(c.registry,text);found {return file.id,""}
    }
    return {},fmt.tprintf("%q is not an asset: give its path under the assets folder, as asset.list lists it, or its id",text)
}

records_api_asset_text :: proc(c:^Records_Api_Context,id:base.Asset_Id) -> string {
    if id=={} {return ""}
    if c.registry!=nil {
        if file,found:=asset.registry_find(c.registry,id);found {return file.path}
    }
    return fmt.tprintf("%016x%016x",id[0],id[1])
}

// ---------------------------------------------------------------- cells

records_api_bool :: proc(text:string) -> (value,ok:bool) {
    switch {
    case strings.equal_fold(text,"true"):  return true,true
    case strings.equal_fold(text,"false"): return false,true
    }
    return
}

// Puts the text of a cell into the value at a leaf of a row.
records_api_cell_read :: proc(c:^Records_Api_Context,leaf:^Records_Api_Leaf,row:[]u8,cell:string) -> (message:string) {
    s:=c.schema
    t:=s.types[leaf.type]
    switch leaf.kind {
    case .Bytes:
        if len(cell)>int(t.size) {return fmt.tprintf("the text is longer than its %d bytes",t.size)}
        part:=row[leaf.offset:][:t.size]
        mem.zero_slice(part)
        copy(part,cell)
        return ""
    case .Ref:
        ref:Records_Api_Ref
        if ref,message=records_api_ref_parse(c,leaf.record,cell);message!="" {return}
        copy(row[leaf.offset:][:size_of(Records_Api_Ref)],mem.ptr_to_bytes(&ref))
        return ""
    case .Member:
        flag,ok:=records_api_bool(strings.trim_space(cell))
        if !ok {return fmt.tprintf("%q is not true or false",cell)}
        return records_api_path_error(c,leaf,cell,serial.value_set(s,c.type,row,leaf.path,flag))
    case .Value:
    }
    text:=strings.trim_space(cell)
    value:serial.Value
    #partial switch records_api_kind(t) {
    case .Bool:
        flag,ok:=records_api_bool(text)
        if !ok {return fmt.tprintf("%q is not true or false",cell)}
        value=flag
    case .Int:
        if t.size>8 {return "a 128-bit integer is set with records.set"}
        number,ok:=strconv.parse_i64(text)
        if !ok {return fmt.tprintf("%q is not a whole number",cell)}
        value=number
    case .Uint:
        if t.size>8 {return "a 128-bit integer is set with records.set"}
        number,ok:=strconv.parse_u64(text)
        if !ok {return fmt.tprintf("%q is not a whole number of zero or more",cell)}
        value=number
    case .Float:
        number,ok:=strconv.parse_f64(text)
        if !ok || number-number!=0 {return fmt.tprintf("%q is not a number",cell)}
        value=number
    case .Enum:
        value=text
    case .Entity,.Entity_Id:
        number,ok:=serial.text_parse_hex(text)
        if !ok {return fmt.tprintf("%q is not the id of an entity: hexadecimal digits",cell)}
        value=t.kind==.Entity ? serial.Value(base.Entity(number)) : serial.Value(base.Entity_Id(number))
    case .Asset:
        id:base.Asset_Id
        if id,message=records_api_asset_parse(c,text);message!="" {return}
        value=id
    case:
        return "it is not one value"
    }
    return records_api_path_error(c,leaf,cell,serial.value_set(s,c.type,row,leaf.path,value))
}

@(private)
records_api_path_error :: proc(c:^Records_Api_Context,leaf:^Records_Api_Leaf,cell:string,error:serial.Path_Error) -> string {
    #partial switch error {
    case .None: return ""
    case .Out_Of_Range: return fmt.tprintf("%q is out of the range of the field",cell)
    case .Too_Long: return fmt.tprintf("%q is longer than the field",cell)
    case .Unknown_Member:
        names:=make([dynamic]string,context.temp_allocator)
        for choice in records_api_choices(c.schema,leaf.type) {append(&names,choice.name)}
        return fmt.tprintf("%q is not one of %s",cell,strings.join(names[:],", ",context.temp_allocator))
    }
    return fmt.tprintf("%q does not fit the field: %v",cell,error)
}

// The text of the value at a leaf of a row, as records_api_cell_read reads it.
records_api_cell_text :: proc(c:^Records_Api_Context,leaf:^Records_Api_Leaf,row:[]u8) -> string {
    s:=c.schema
    t:=s.types[leaf.type]
    switch leaf.kind {
    case .Bytes: return serial.text_field(row[leaf.offset:][:t.size])
    case .Ref:
        ref:Records_Api_Ref
        copy(mem.ptr_to_bytes(&ref),row[leaf.offset:][:size_of(Records_Api_Ref)])
        return records_api_ref_text(c,leaf.record,ref)
    case .Member,.Value:
    }
    if leaf.kind==.Value && (t.kind==.Int || t.kind==.Uint) && t.size>8 {return ""}
    value,error:=serial.value_get(s,c.type,row,leaf.path)
    if error!=.None {return ""}
    switch v in value {
    case bool:   return v ? "true" : "false"
    case i64:    return fmt.tprint(v)
    case u64:    return fmt.tprint(v)
    case f64:    return t.size==8 ? fmt.tprint(v) : fmt.tprint(f32(v))
    case string: return v
    case base.Entity:    return fmt.tprintf("%x",u64(v))
    case base.Entity_Id: return fmt.tprintf("%x",u64(v))
    case base.Asset_Id:  return records_api_asset_text(c,v)
    }
    return ""
}

// ---------------------------------------------------------------- CSV

// The columns the first row of a CSV names; message says which one is wrong
// and which there are.
records_api_header :: proc(c:^Records_Api_Context,leaves:[]Records_Api_Leaf,header:[]string) -> (columns:[]Records_Api_Column,message:string) {
    out:=make([]Records_Api_Column,len(header),context.temp_allocator)
    named:=false
    for cell,i in header {
        title:=strings.trim_space(cell)
        column:=Records_Api_Column{title=title,leaf=-1}
        if title=="name" {
            if named {return nil,"two columns are name: keep one"}
            named=true
        } else {
            column.leaf=records_api_leaf_find(leaves,title)
            if column.leaf<0 {return nil,fmt.tprintf("column %d %q is not a field of %s; the columns are %s",i+1,title,c.name,records_api_columns_text(leaves))}
            for earlier,j in out[:i] {
                if earlier.leaf==column.leaf {return nil,fmt.tprintf("columns %d and %d are both %s: keep one",j+1,i+1,title)}
            }
        }
        out[i]=column
    }
    if !named {return nil,fmt.tprintf("the first row names the columns and none is name: write name and the fields of %s, as %s",c.name,records_api_columns_text(leaves))}
    return out,""
}

// The columns there are, for a message.
records_api_columns_text :: proc(leaves:[]Records_Api_Leaf) -> string {
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"name")
    for leaf in leaves {
        fmt.sbprintf(&b,", %s",leaf.path)
    }
    return strings.to_string(b)
}

// Puts the cells of a record of a CSV into a row; an empty cell leaves its value.
records_api_row_cells :: proc(c:^Records_Api_Context,leaves:[]Records_Api_Leaf,columns:[]Records_Api_Column,record:[]string,row:[]u8) -> (message:string) {
    for column,i in columns {
        if column.leaf<0 || i>=len(record) || record[i]=="" {continue}
        leaf:=&leaves[column.leaf]
        if message=records_api_cell_read(c,leaf,row,record[i]);message!="" {return fmt.tprintf("column %s: %s",column.title,message)}
    }
    return ""
}

// Updates the rows of the table c.edit that the records of a CSV name and adds
// the others at the end, a row at a time: a record with a cell that does not
// read changes nothing. default: the bytes of a new row.
records_api_import_rows :: proc(s:^Session,c:^Records_Api_Context,leaves:[]Records_Api_Leaf,columns:[]Records_Api_Column,parsed:[][]string,lines:[]int,default:[]u8) -> (updated,added:int,rejected:[]Records_Api_Rejected) {
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
        if message:=records_api_row_cells(c,leaves,columns,record,scratch);message!="" {
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

// The CSV of every row of c.edit that records_api_import_rows reads: name
// and every value.
records_api_csv :: proc(c:^Records_Api_Context,leaves:[]Records_Api_Leaf) -> (text:string,columns:int) {
    e:=c.edit
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"name")
    columns=1
    for leaf in leaves {
        strings.write_byte(&b,',')
        importer.csv_cell(&b,leaf.path)
        columns+=1
    }
    strings.write_byte(&b,'\n')
    for row in 0..<records.row_count(e) {
        bytes:=records.row_bytes(e,row)
        importer.csv_cell(&b,records.row_name(e,row))
        for &leaf in leaves {
            strings.write_byte(&b,',')
            importer.csv_cell(&b,records_api_cell_text(c,&leaf,bytes))
        }
        strings.write_byte(&b,'\n')
    }
    return strings.to_string(b),columns
}

// ---------------------------------------------------------------- values by JSON

records_api_json_error :: proc(r:^serial.Text_Reader,what:string) -> string {
    offset:=r.error.offset if r.error.code!=.None else r.offset
    line,column:=serial.text_position(r.text,offset)
    return fmt.tprintf("%s is not valid JSON at line %d, column %d",what,line,column)
}

// Copies the JSON of a value of type into out, with the core.Record fields
// given as a string turned into their serial form.
records_api_rewrite :: proc(c:^Records_Api_Context,r:^serial.Text_Reader,type:serial.Type_Index,path:string,out:^serial.Writer) -> (message:string) {
    s:=c.schema
    peek:=serial.text_peek(r)
    if peek=='"' && serial.type_valid(s,type) {
        if record:=records_api_ref_record(c,type);record!="" {
            text,read:=serial.text_string(r)
            if !read {return records_api_json_error(r,"values")}
            ref,problem:=records_api_ref_parse(c,record,text)
            if problem!="" {return fmt.tprintf("values.%s: %s",path,problem)}
            records_api_ref_write(out,ref)
            return ""
        }
    }
    kind:=serial.type_valid(s,type) ? records_api_kind(s.types[type]) : serial.Type_Kind.Bool
    switch {
    case kind==.Struct && peek=='{':
        serial.text_accept(r,'{')
        serial.write_u8(out,'{')
        if serial.text_accept(r,'}') {
            serial.write_u8(out,'}')
            return ""
        }
        for {
            key,read:=serial.text_string(r)
            if !read || !serial.text_expect(r,':') {return records_api_json_error(r,"values")}
            key=strings.clone(key,context.temp_allocator)
            serial.text_write_string(out,key)
            serial.write_u8(out,':')
            field:^serial.Field
            for &each in serial.schema_fields(s,type) {
                if each.name==key {field=&each;break}
            }
            if field==nil {
                if message=records_api_copy(r,out);message!="" {return}
            } else {
                if message=records_api_rewrite(c,r,field.type,path=="" ? key : fmt.tprintf("%s.%s",path,key),out);message!="" {return}
            }
            if serial.text_accept(r,',') {
                serial.write_u8(out,',')
                continue
            }
            if !serial.text_expect(r,'}') {return records_api_json_error(r,"values")}
            serial.write_u8(out,'}')
            return ""
        }
    case kind==.Array && peek=='[' && !serial.type_is_bytes(s,type):
        serial.text_accept(r,'[')
        serial.write_u8(out,'[')
        if serial.text_accept(r,']') {
            serial.write_u8(out,']')
            return ""
        }
        for i:=0;;i+=1 {
            if message=records_api_rewrite(c,r,s.types[type].elem,fmt.tprintf("%s[%d]",path,i),out);message!="" {return}
            if serial.text_accept(r,',') {
                serial.write_u8(out,',')
                continue
            }
            if !serial.text_expect(r,']') {return records_api_json_error(r,"values")}
            serial.write_u8(out,']')
            return ""
        }
    }
    return records_api_copy(r,out)
}

@(private)
records_api_copy :: proc(r:^serial.Text_Reader,out:^serial.Writer) -> (message:string) {
    serial.text_space(r)
    start:=r.offset
    if !serial.text_skip(r) {return records_api_json_error(r,"values")}
    serial.text_write_raw(out,r.text[start:r.offset])
    return ""
}

// Puts the values of the params over a row. Each key is a field of the row or
// the path of a part of one (stats.speed, windows[2].to), and its value is
// that part whole: an object or a list leaves what it does not give at the
// default of the row type (zeros where the type has none), while the fields
// and parts no key names keep what they have. core.Record fields may be named
// by their rows.
records_api_values_put :: proc(c:^Records_Api_Context,row:[]u8,values:string) -> (message:string) {
    if values=="" {return ""}
    r:serial.Text_Reader
    serial.text_reader_init(&r,values,context.temp_allocator)
    if !serial.text_accept(&r,'{') {return "values must be an object of fields of the row"}
    if !serial.text_accept(&r,'}') {
        for {
            key,read:=serial.text_string(&r)
            if !read || !serial.text_expect(&r,':') {return records_api_json_error(&r,"values")}
            key=strings.clone(key,context.temp_allocator)
            if message=records_api_value_put(c,&r,row,key);message!="" {return}
            if serial.text_accept(&r,',') {continue}
            if !serial.text_expect(&r,'}') {return records_api_json_error(&r,"values")}
            break
        }
    }
    if !serial.text_end(&r) {return records_api_json_error(&r,"values")}
    return ""
}

// The value of one key of values, read from r into the part of row that key
// names.
@(private)
records_api_value_put :: proc(c:^Records_Api_Context,r:^serial.Text_Reader,row:[]u8,key:string) -> (message:string) {
    s:=c.schema
    target,error,at:=serial.path_resolve(s,c.type,key)
    if error==.None && target.bit>=0 {error=.Not_A_Struct}
    if error!=.None {
        parent:=strings.trim_right(key[:at],".")
        fields:=make([dynamic]string,context.temp_allocator)
        if within,_,_:=serial.path_resolve(s,c.type,parent);serial.type_valid(s,within.type) && records_api_kind(s.types[within.type])==.Struct {
            for field in serial.schema_fields(s,within.type) {append(&fields,field.name)}
        }
        if len(fields)==0 {return fmt.tprintf("values.%s is not a field of %s nor the path of a part of one (stats.speed, windows[2].to)",key,c.name)}
        return fmt.tprintf("values.%s names no part of %s: the fields there are %s",key,c.name,strings.join(fields[:],", ",context.temp_allocator))
    }
    // An object or a list is the whole part: what it leaves out goes back to the default.
    serial.text_space(r)
    peek:=serial.text_peek(r)
    whole:=peek=='{' || peek=='['
    out:serial.Writer
    serial.writer_init(&out,64,context.temp_allocator)
    if message=records_api_rewrite(c,r,target.type,key,&out);message!="" {return}
    part:=row[target.offset:][:s.types[target.type].size]
    if whole {
        if len(c.default)>=len(row) {copy(part,c.default[target.offset:][:len(part)])} else {mem.zero_slice(part)}
    }
    rewritten:serial.Text_Reader
    serial.text_reader_init(&rewritten,string(serial.writer_bytes(&out)),context.temp_allocator)
    if !serial.text_read(&rewritten,s,target.type,part,target.text) || !serial.text_end(&rewritten) {
        return serial.text_error_message(&rewritten,fmt.tprintf("values.%s",key),context.temp_allocator)
    }
    return ""
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
records_api_context :: proc(s:^Session,e:^records.Edit) -> (c:Records_Api_Context,leaves:[]Records_Api_Leaf) {
    c={schema=&e.schema,type=e.type,name=records.type_name(e),edit=e,registry=&s.app.assets.registry,default=e.defaults}
    refs:=make([dynamic]Records_Api_Ref_Type,context.temp_allocator)
    for &column,at in e.columns {
        if column.kind!=.Record {continue}
        field,_:=records.column_field(e,at)
        type:=field.type
        if column.count>0 {type=e.schema.types[type].elem}
        append(&refs,Records_Api_Ref_Type{type,serial.text_field(column.type[:])})
    }
    // References inside the types of the code: core.Record(T) of a type the build has.
    if info:=s.app.info;info!=nil {
        for &r in info.records {
            if t,found:=e.schema.lookup[r.ref];found {append(&refs,Records_Api_Ref_Type{t,r.name})}
        }
    }
    c.refs=refs[:]
    leaves=records_api_leaves(&c)
    tables:=make([dynamic]Records_Api_Rows,context.temp_allocator)
    for &leaf in leaves {
        if leaf.kind!=.Ref {continue}
        listed:=false
        for &t in tables {
            if t.record==leaf.record {listed=true;break}
        }
        if listed {continue}
        for &file in records_tables(s,leaf.record) {
            entry:=Records_Api_Rows{record=leaf.record,id=file.id,path=file.path}
            if file.id!=e.id {
                ok:bool
                if entry.ids,entry.names,ok=records.rows_read(&s.app.assets.registry,&s.app.assets.types,file.id);!ok {continue}
            }
            append(&tables,entry)
        }
    }
    c.tables=tables[:]
    return
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
    values:serial.Writer
    serial.writer_init(&values,256,allocator)
    serial.text_write(&values,&e.schema,e.type,records.row_bytes(e,row),.Line)
    return {e.ids[row],strings.clone(records.row_name(e,row),allocator),serial.Json(serial.writer_bytes(&values))}
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
    if message=records_api_values_put(&c,e.defaults,text);message!="" {return fmt.tprintf("default: %s",message)}
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
records_api_row_put :: proc(call:^api.Call,c:^Records_Api_Context,row:int,values:serial.Json) -> bool {
    value:=slice.clone(records.row_bytes(c.edit,row),context.temp_allocator)
    if message:=records_api_values_put(c,value,string(values));message!="" {
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
    columns,message:=records_api_header(&c,leaves,parsed[0])
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
    text,columns:=records_api_csv(&c,leaves)
    if serial.file_write_atomic(file,transmute([]u8)text)!=.None {
        api.call_failf(call,api.INVALID_PARAMS,"%s could not be written; its folder has to exist",file)
        return
    }
    api.call_result(call,Api_Records_Export)^={e.id,asset_path(s,e.id),file,records.row_count(&e),columns}
}
