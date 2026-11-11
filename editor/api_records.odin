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
// create, inspect, set, add, remove, rename and move, and their exchange with
// the CSV files of a spreadsheet (records.import and records.export). Rows go
// by name; a change of a table is one step of the history.

// What a core.Record(T) holds, for any T.
Records_Api_Ref :: struct {table:base.Asset_Id,row:core.Record_Id}
#assert(size_of(Records_Api_Ref)==size_of(core.Record(Records_Api_Ref)))

Records_Api_Ref_Type :: struct {
    type:serial.Type_Index, // of core.Record(T) in the schema
    record:int,             // T, in World_Info.records
    name:string,            // "library.Name" of T
}

// A table whose rows a core.Record names.
Records_Api_Rows :: struct {
    record:int,
    id:base.Asset_Id,
    path:string, // under the assets folder
    ids:[]u64,
    names:[]asset.Records_Name,
}

// What reading and writing the rows of a table by text needs.
Records_Api_Context :: struct {
    schema:^serial.Schema,
    type:serial.Type_Index,  // of the rows
    name:string,             // "library.Name" of the rows
    text:serial.Type_Index,  // of core.Text; TYPE_NONE when the schema has none
    refs:[]Records_Api_Ref_Type,
    tables:[]Records_Api_Rows,
    edit:^records.Edit,      // the table that changes: its rows stand for those of its file in tables
    registry:^asset.Registry, // nil: assets go by id only
    default:[]u8,            // a new row of the type; nil: zeros
}

Records_Api_Leaf_Kind :: enum u8 {
    Value,  // a number, bool, enum, entity or asset, by its path
    Bytes,  // a text field ([N]u8 mirai:"text")
    Text,   // a core.Text
    Ref,    // a core.Record
    Member, // of a bit set, as a bool
}

// A value of a row that is one cell of a CSV.
Records_Api_Leaf :: struct {
    path:string, // as serial paths write it
    kind:Records_Api_Leaf_Kind,
    type:serial.Type_Index,
    offset:int,
    record:int, // Ref: the type of the rows it names
}

Records_Api_Column :: struct {
    title:string,
    leaf:int,        // -1: the name of the row
    language:string, // of a Text column; "": its source text
}

// A text of a core.Text field the params give.
Records_Api_Text :: struct {
    path,language,text:string,
}

Records_Api_Rejected :: struct {
    line:int,
    name:string,
    reason:string,
}

// ---------------------------------------------------------------- results

@(private)
Api_Records_Types :: struct {
    types:[1]Api_Records_Type `mirai:"list"`,
}
@(private)
Api_Records_Type :: struct {
    type:[asset.RECORDS_TYPE]u8 `mirai:"text,label=library.Name: what records.create takes"`,
    description:[1024]u8 `mirai:"text,optional"`,
    fields:[1]Api_Records_Field `mirai:"list,label=The fields of its rows"`,
    tables:[1]Api_Records_Table_Entry `mirai:"list,label=Its .records in the assets"`,
}
@(private)
Api_Records_Field :: struct {
    name:[64]u8 `mirai:"text"`,
    type:[128]u8 `mirai:"text,label=As the code writes it"`,
    options:[1][64]u8 `mirai:"text,list,optional,label=Of an enum: the names it takes"`,
    records:[asset.RECORDS_TYPE]u8 `mirai:"text,optional,label=Of a core.Record: the type of the rows it names"`,
    description:[1024]u8 `mirai:"text,optional"`,
}
@(private)
Api_Records_Table_Entry :: struct {
    records:base.Asset_Id,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=Under the assets folder"`,
    rows:int,
}
@(private)
Api_Records_Table :: struct {
    records:base.Asset_Id,
    path:[API_PATH_BYTES]u8 `mirai:"text,optional,label=Under the assets folder"`,
    type:[asset.RECORDS_TYPE]u8 `mirai:"text,label=library.Name of its rows"`,
    rows:[1]Api_Records_Row `mirai:"list"`,
}
@(private)
Api_Records_Row :: struct {
    id:u64 `mirai:"label=What a core.Record keeps"`,
    name:[asset.RECORDS_NAME]u8 `mirai:"text"`,
    values:u8 `mirai:"any,label=The row as records.set takes it; a core.Text is its id and a core.Record its table and row"`,
    texts:u8 `mirai:"any,optional,label=By path of each core.Text field with a text: its text by language code; the key \"\" is the language the game is written in"`,
}
@(private)
Api_Records_Removed :: struct {
    records:base.Asset_Id,
    path:[API_PATH_BYTES]u8 `mirai:"text,optional"`,
    removed:[1][asset.RECORDS_NAME]u8 `mirai:"text,list"`,
}
@(private)
Api_Records_Import :: struct {
    records:base.Asset_Id,
    path:[API_PATH_BYTES]u8 `mirai:"text,optional"`,
    updated:int `mirai:"label=Rows of the table the file changed"`,
    added:int `mirai:"label=Rows the file added at the end"`,
    rejected:[1]Api_Records_Rejected `mirai:"list,label=Rows of the file that changed nothing"`,
}
@(private)
Api_Records_Rejected :: struct {
    line:int `mirai:"label=Of the file, from 1"`,
    row:[asset.RECORDS_NAME]u8 `mirai:"text,optional"`,
    reason:[512]u8 `mirai:"text"`,
}
@(private)
Api_Records_Export :: struct {
    records:base.Asset_Id,
    path:[API_PATH_BYTES]u8 `mirai:"text,optional"`,
    file:[API_PATH_BYTES]u8 `mirai:"text,label=Absolute"`,
    rows:int,
    columns:int,
}

// ---------------------------------------------------------------- params

@(private) RECORDS_API_P_RECORDS :: `"records":{"type":"string","description":"A table of game data: its path under the assets folder, with or without .records, or its id; records.types lists them"}`
@(private) RECORDS_API_P_ROW :: `"row":{"type":"string","description":"The name of a row, as records.inspect lists them"}`
@(private) RECORDS_API_P_VALUES :: `"values":{"type":"object","description":"Fields of the row, as records.inspect shows them, or paths of a part of one (\"stats.speed\", \"windows[2].to\"); each is set whole: an object or a list leaves what it does not give at the default of the type, and what no key names keeps its value. A core.Record field also takes the name of a row (\"sword\") or its table and name (\"data/weapons/sword\"); a core.Text field also takes its source text"}`
@(private) RECORDS_API_P_TEXTS :: `"texts":{"type":"object","description":"Texts of core.Text fields by field path, each by language code, as {\"title\":{\"\":\"Sword\",\"es\":\"Espada\"}}; \"\" is the language the game is written in and an empty translation removes it"}`

@(private) RECORDS_API_CREATE_SCHEMA :: `{"type":"object","properties":{"path":{"type":"string","description":"Where the new table goes, under the assets folder; .records is added when missing"},"type":{"type":"string","description":"The type of its rows as library.Name, as records.types lists them"}},"required":["path","type"],"additionalProperties":false}`
@(private) RECORDS_API_INSPECT_SCHEMA :: `{"type":"object","properties":{` + RECORDS_API_P_RECORDS + `,"rows":{"type":"array","items":{"type":"string"},"description":"Only these rows, by name"}},"required":["records"],"additionalProperties":false}`
@(private) RECORDS_API_SET_SCHEMA :: `{"type":"object","properties":{` + RECORDS_API_P_RECORDS + `,` + RECORDS_API_P_ROW + `,` + RECORDS_API_P_VALUES + `,` + RECORDS_API_P_TEXTS + `,"name":{"type":"string","description":"A new name for the row"}},"required":["records","row"],"additionalProperties":false}`
@(private) RECORDS_API_ADD_SCHEMA :: `{"type":"object","properties":{` + RECORDS_API_P_RECORDS + `,"name":{"type":"string","description":"The name of the new row: a word of ASCII letters, digits and _, unique in the table"},` + RECORDS_API_P_VALUES + `,` + RECORDS_API_P_TEXTS + `,"after":{"type":"string","description":"The row it goes after; without it, at the end"}},"required":["records","name"],"additionalProperties":false}`
@(private) RECORDS_API_REMOVE_SCHEMA :: `{"type":"object","properties":{` + RECORDS_API_P_RECORDS + `,"rows":{"type":"array","items":{"type":"string"},"description":"The names of the rows to remove"}},"required":["records","rows"],"additionalProperties":false}`
@(private) RECORDS_API_MOVE_SCHEMA :: `{"type":"object","properties":{` + RECORDS_API_P_RECORDS + `,` + RECORDS_API_P_ROW + `,"after":{"type":"string","description":"The row it goes right after; empty: it goes first"}},"required":["records","row","after"],"additionalProperties":false}`
@(private) RECORDS_API_IMPORT_SCHEMA :: `{"type":"object","properties":{` + RECORDS_API_P_RECORDS + `,"file":{"type":"string","description":"A CSV file (UTF-8, comma separated, its first row the columns as records.export writes them): its path from the root of the project, or absolute"}},"required":["records","file"],"additionalProperties":false}`
@(private) RECORDS_API_EXPORT_SCHEMA :: `{"type":"object","properties":{` + RECORDS_API_P_RECORDS + `,"file":{"type":"string","description":"The CSV file to write: its path from the root of the project, or absolute; an existing one is replaced"}},"required":["records","file"],"additionalProperties":false}`

Records_Api_Key :: enum u8 {Records,Path,Type,Row,Name,After,File,Values,Texts,Rows}
Records_Api_Keys :: bit_set[Records_Api_Key;u16]

@(private)
RECORDS_API_KEY_NAMES :: [Records_Api_Key]string{
    .Records="records",.Path="path",.Type="type",.Row="row",.Name="name",.After="after",
    .File="file",.Values="values",.Texts="texts",.Rows="rows",
}

@(private)
RECORDS_API_KEY_HINTS :: [Records_Api_Key]string{
    .Records="the table, by its path under the assets folder or its id; records.types lists the tables",
    .Path="where the new table goes, under the assets folder",
    .Type="the type of its rows as library.Name; records.types lists them",
    .Row="the name of the row; records.inspect lists them",
    .Name="the name of the row, a word of ASCII letters, digits and _",
    .After="the row it goes after",
    .File="the CSV file, by its path from the root of the project or absolute",
    .Values="the fields of the row",
    .Texts="the texts of its core.Text fields",
    .Rows="a list of names of rows",
}

Records_Api_Params :: struct {
    records,path,type,row,name,after,file:string,
    values,texts:string, // the text of the object
    rows:[]string,
    given:Records_Api_Keys,
}

@(private)
records_api_params :: proc(call:^api.Call,method:string,keys,required:Records_Api_Keys) -> (p:Records_Api_Params,ok:bool) {
    names:=RECORDS_API_KEY_NAMES
    hints:=RECORDS_API_KEY_HINTS
    a:Rpc_Args
    rpc_init(&a,call,call.raw)
    if !rpc_object_begin(&a,"params") {return}
    o:Rpc_Object
    for {
        key,more:=rpc_next(&a,&o)
        if !more {break}
        found:Maybe(Records_Api_Key)
        for k in keys {
            if names[k]==key {found=k;break}
        }
        k,known:=found.?
        if !known {
            taken:=make([dynamic]string,context.temp_allocator)
            for each in keys {append(&taken,names[each])}
            rpc_fail_type(&a,"%s is not a parameter of %s: it takes %s",key,method,strings.join(taken[:],", ",context.temp_allocator))
            return
        }
        p.given+={k}
        #partial switch k {
        case .Values,.Texts:
            text:=rpc_raw(&a) or_return
            if k==.Values {p.values=text} else {p.texts=text}
        case .Rows:
            list:=make([dynamic]string,context.temp_allocator)
            if !serial.text_accept(&a.r,'[') {return p,rpc_fail(&a,"rows must be a list of names of rows")}
            if !serial.text_accept(&a.r,']') {
                for {
                    text,read:=serial.text_string(&a.r)
                    if !read {return p,rpc_fail(&a,"rows must be a list of names of rows")}
                    append(&list,strings.clone(text,context.temp_allocator))
                    if serial.text_accept(&a.r,',') {continue}
                    if !serial.text_accept(&a.r,']') {return p,rpc_fail(&a,"rows must be a list of names of rows")}
                    break
                }
            }
            p.rows=list[:]
        case:
            text,read:=serial.text_string(&a.r)
            if !read {return p,rpc_fail_type(&a,"%s must be a string: %s",names[k],hints[k])}
            text=strings.clone(text,context.temp_allocator)
            #partial switch k {
            case .Records: p.records=text
            case .Path:    p.path=text
            case .Type:    p.type=text
            case .Row:     p.row=text
            case .Name:    p.name=text
            case .After:   p.after=text
            case .File:    p.file=text
            }
        }
    }
    if a.failed {return}
    for k in required {
        if k not_in p.given {
            api.call_failf(call,api.INVALID_PARAMS,"%s needs %s: %s",method,names[k],hints[k])
            return
        }
    }
    return p,true
}

// ---------------------------------------------------------------- the shape of a row

records_api_ref_record :: proc(c:^Records_Api_Context,type:serial.Type_Index) -> int {
    for r in c.refs {
        if r.type==type {return r.record}
    }
    return -1
}

records_api_ref_name :: proc(c:^Records_Api_Context,record:int) -> string {
    for r in c.refs {
        if r.record==record {return r.name}
    }
    return "?"
}

// Every value of a row that is a cell of a CSV, in the order of its fields.
records_api_leaves :: proc(c:^Records_Api_Context,allocator:=context.temp_allocator) -> []Records_Api_Leaf {
    out:=make([dynamic]Records_Api_Leaf,allocator)
    add :: proc(c:^Records_Api_Context,type:serial.Type_Index,path:string,offset:int,text:bool,out:^[dynamic]Records_Api_Leaf,depth:int) {
        s:=c.schema
        if depth>16 || !serial.type_valid(s,type) {return}
        if c.text!=serial.TYPE_NONE && type==c.text {
            append(out,Records_Api_Leaf{path=path,kind=.Text,type=type,offset=offset,record=-1})
            return
        }
        if record:=records_api_ref_record(c,type);record>=0 {
            append(out,Records_Api_Leaf{path=path,kind=.Ref,type=type,offset=offset,record=record})
            return
        }
        if text && serial.type_is_bytes(s,type) {
            append(out,Records_Api_Leaf{path=path,kind=.Bytes,type=type,offset=offset,record=-1})
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
                append(out,Records_Api_Leaf{path=fmt.aprintf("%s.%s",path,choice.name,allocator=context.allocator),kind=.Member,type=type,offset=offset,record=-1})
            }
        case:
            append(out,Records_Api_Leaf{path=path,kind=.Value,type=type,offset=offset,record=-1})
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

// The paths of the core.Text fields, for a message.
records_api_text_paths :: proc(leaves:[]Records_Api_Leaf) -> string {
    paths:=make([dynamic]string,context.temp_allocator)
    for leaf in leaves {
        if leaf.kind==.Text {append(&paths,leaf.path)}
    }
    if len(paths)==0 {return "it has none"}
    return fmt.tprintf("they are %s",strings.join(paths[:],", ",context.temp_allocator))
}

// A language code of a .records: letters, digits, - and _; "" is the source.
records_api_language_valid :: proc(code:string) -> bool {
    if len(code)>=asset.RECORDS_LANGUAGE {return false}
    for c in transmute([]u8)code {
        switch c {
        case 'a'..='z','A'..='Z','0'..='9','-','_':
        case: return false
        }
    }
    return true
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
records_api_ref_parse :: proc(c:^Records_Api_Context,record:int,text:string) -> (ref:Records_Api_Ref,message:string) {
    text:=strings.trim_space(text)
    type_name:=records_api_ref_name(c,record)
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
records_api_ref_text :: proc(c:^Records_Api_Context,record:int,ref:Records_Api_Ref) -> string {
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

// Puts the text of a cell into the value at a leaf of a row. A core.Text is
// not a value of the row: its texts go through records_text_set.
records_api_cell_read :: proc(c:^Records_Api_Context,leaf:^Records_Api_Leaf,row:[]u8,cell:string) -> (message:string) {
    s:=c.schema
    t:=s.types[leaf.type]
    switch leaf.kind {
    case .Text:
        return "a core.Text takes its texts by language"
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
    case .Text: return ""
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
            path,language:=title,""
            at:=strings.last_index_byte(title,'@')
            if at>=0 {path,language=title[:at],title[at+1:]}
            column.leaf=records_api_leaf_find(leaves,path)
            if column.leaf<0 {return nil,fmt.tprintf("column %d %q is not a field of %s; the columns are %s",i+1,title,c.name,records_api_columns_text(leaves))}
            if at>=0 {
                if leaves[column.leaf].kind!=.Text {return nil,fmt.tprintf("column %d %q: %s is not a core.Text, which has no translations; write it as %s",i+1,title,path,path)}
                if language=="" || !records_api_language_valid(language) {return nil,fmt.tprintf("column %d %q: %q is not the code of a language: letters, digits, - and _, shorter than %d bytes, as es or pt-BR; %s alone is its source text",i+1,title,language,asset.RECORDS_LANGUAGE,path)}
                column.language=language
            }
            for earlier,j in out[:i] {
                if earlier.leaf==column.leaf && earlier.language==column.language {return nil,fmt.tprintf("columns %d and %d are both %s: keep one",j+1,i+1,title)}
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
        if leaf.kind==.Text {fmt.sbprintf(&b,", %s@<language>",leaf.path)}
    }
    return strings.to_string(b)
}

// Puts the cells of a record of a CSV but its texts into a row; an empty
// cell leaves its value.
records_api_row_cells :: proc(c:^Records_Api_Context,leaves:[]Records_Api_Leaf,columns:[]Records_Api_Column,record:[]string,row:[]u8) -> (message:string) {
    for column,i in columns {
        if column.leaf<0 || i>=len(record) || record[i]=="" {continue}
        leaf:=&leaves[column.leaf]
        if leaf.kind==.Text {continue}
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
    scratch:=make([]u8,e.info.size,context.temp_allocator)
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
        for column,i in columns {
            if column.leaf<0 || i>=len(record) || record[i]=="" || leaves[column.leaf].kind!=.Text {continue}
            records.text_set(e,&s.id_state,row,leaves[column.leaf].offset,column.language,record[i])
        }
    }
    return updated,added,out[:]
}

records_api_csv_cell :: proc(b:^strings.Builder,cell:string) {
    if !strings.contains_any(cell,",\"\r\n") {
        strings.write_string(b,cell)
        return
    }
    strings.write_byte(b,'"')
    for i in 0..<len(cell) {
        if cell[i]=='"' {strings.write_byte(b,'"')}
        strings.write_byte(b,cell[i])
    }
    strings.write_byte(b,'"')
}

// The languages of the translations of a table, in order.
records_api_languages :: proc(e:^records.Edit) -> []string {
    out:=make([dynamic]string,context.temp_allocator)
    for &entry in e.texts {
        language:=serial.text_field(entry.language[:])
        if language!="" && !slice.contains(out[:],language) {append(&out,language)}
    }
    slice.sort(out[:])
    return out[:]
}

// The CSV of every row of c.edit that records_api_import_rows reads: name,
// every value and, for each core.Text, its source text and a column per
// language it has.
records_api_csv :: proc(c:^Records_Api_Context,leaves:[]Records_Api_Leaf) -> (text:string,columns:int) {
    e:=c.edit
    languages:=records_api_languages(e)
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"name")
    columns=1
    for leaf in leaves {
        strings.write_byte(&b,',')
        records_api_csv_cell(&b,leaf.path)
        columns+=1
        if leaf.kind!=.Text {continue}
        for language in languages {
            strings.write_byte(&b,',')
            records_api_csv_cell(&b,fmt.tprintf("%s@%s",leaf.path,language))
            columns+=1
        }
    }
    strings.write_byte(&b,'\n')
    for row in 0..<records.row_count(e) {
        bytes:=records.row_bytes(e,row)
        records_api_csv_cell(&b,records.row_name(e,row))
        for &leaf in leaves {
            strings.write_byte(&b,',')
            if leaf.kind!=.Text {
                records_api_csv_cell(&b,records_api_cell_text(c,&leaf,bytes))
                continue
            }
            id:=(cast(^core.Text)&bytes[leaf.offset]).id
            source,_:=records.text_get(e,id,"")
            if id!=0 {records_api_csv_cell(&b,source)}
            for language in languages {
                strings.write_byte(&b,',')
                if id==0 {continue}
                translated,_:=records.text_get(e,id,language)
                records_api_csv_cell(&b,translated)
            }
        }
        strings.write_byte(&b,'\n')
    }
    return strings.to_string(b),columns
}

// ---------------------------------------------------------------- values and texts by JSON

records_api_json_error :: proc(r:^serial.Text_Reader,what:string) -> string {
    offset:=r.error.offset if r.error.code!=.None else r.offset
    line,column:=serial.text_position(r.text,offset)
    return fmt.tprintf("%s is not valid JSON at line %d, column %d",what,line,column)
}

// Copies the JSON of a value of type into out, with the core.Record fields
// given as a string turned into their serial form, and the core.Text fields
// given as a string taken out into texts as their source text.
records_api_rewrite :: proc(c:^Records_Api_Context,r:^serial.Text_Reader,type:serial.Type_Index,path:string,out:^serial.Writer,texts:^[dynamic]Records_Api_Text) -> (message:string) {
    s:=c.schema
    peek:=serial.text_peek(r)
    if peek=='"' && serial.type_valid(s,type) {
        if c.text!=serial.TYPE_NONE && type==c.text {
            text,read:=serial.text_string(r)
            if !read {return records_api_json_error(r,"values")}
            append(texts,Records_Api_Text{path=path,text=strings.clone(text,context.temp_allocator)})
            serial.text_write_raw(out,"{}")
            return ""
        }
        if record:=records_api_ref_record(c,type);record>=0 {
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
                if message=records_api_rewrite(c,r,field.type,path=="" ? key : fmt.tprintf("%s.%s",path,key),out,texts);message!="" {return}
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
            if message=records_api_rewrite(c,r,s.types[type].elem,fmt.tprintf("%s[%d]",path,i),out,texts);message!="" {return}
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
// by their rows and core.Text fields by their source text, which go to texts.
records_api_values_put :: proc(c:^Records_Api_Context,row:[]u8,values:string,texts:^[dynamic]Records_Api_Text) -> (message:string) {
    if values=="" {return ""}
    r:serial.Text_Reader
    serial.text_reader_init(&r,values,context.temp_allocator)
    if !serial.text_accept(&r,'{') {return "values must be an object of fields of the row"}
    if !serial.text_accept(&r,'}') {
        for {
            key,read:=serial.text_string(&r)
            if !read || !serial.text_expect(&r,':') {return records_api_json_error(&r,"values")}
            key=strings.clone(key,context.temp_allocator)
            if message=records_api_value_put(c,&r,row,key,texts);message!="" {return}
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
records_api_value_put :: proc(c:^Records_Api_Context,r:^serial.Text_Reader,row:[]u8,key:string,texts:^[dynamic]Records_Api_Text) -> (message:string) {
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
    whole:=(peek=='{' || peek=='[') && !(c.text!=serial.TYPE_NONE && target.type==c.text)
    out:serial.Writer
    serial.writer_init(&out,64,context.temp_allocator)
    if message=records_api_rewrite(c,r,target.type,key,&out,texts);message!="" {return}
    part:=row[target.offset:][:s.types[target.type].size]
    before:=slice.clone(part,context.temp_allocator)
    if whole {
        if len(c.default)>=len(row) {copy(part,c.default[target.offset:][:len(part)])} else {mem.zero_slice(part)}
    }
    rewritten:serial.Text_Reader
    serial.text_reader_init(&rewritten,string(serial.writer_bytes(&out)),context.temp_allocator)
    if !serial.text_read(&rewritten,s,target.type,part,target.text) || !serial.text_end(&rewritten) {
        return serial.text_error_message(&rewritten,fmt.tprintf("values.%s",key),context.temp_allocator)
    }
    // The texts of a part given whole stay its texts: they change through texts or a source text.
    if whole && c.text!=serial.TYPE_NONE {
        for leaf in records_api_leaves(c) {
            if leaf.kind!=.Text || leaf.offset<target.offset || leaf.offset+size_of(core.Text)>target.offset+len(part) {continue}
            text:=cast(^core.Text)&row[leaf.offset]
            if text.id==0 {text^=(cast(^core.Text)&before[leaf.offset-target.offset])^}
        }
    }
    return ""
}

// The texts of the params: an object of field paths, each an object of
// language codes and texts.
records_api_texts_read :: proc(text:string,out:^[dynamic]Records_Api_Text) -> (message:string) {
    if text=="" {return ""}
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    shape :: `texts is an object of core.Text fields, each an object of texts by language code: {"title":{"":"Sword","es":"Espada"}}`
    if !serial.text_accept(&r,'{') {return shape}
    if serial.text_accept(&r,'}') {return ""}
    for {
        path,read:=serial.text_string(&r)
        if !read || !serial.text_expect(&r,':') {return shape}
        path=strings.clone(path,context.temp_allocator)
        if !serial.text_accept(&r,'{') {return shape}
        if !serial.text_accept(&r,'}') {
            for {
                language,named:=serial.text_string(&r)
                if !named || !serial.text_expect(&r,':') {return shape}
                language=strings.clone(language,context.temp_allocator)
                value,given:=serial.text_string(&r)
                if !given {return fmt.tprintf("texts.%s.%s must be a string",path,language)}
                if !records_api_language_valid(language) {return fmt.tprintf("texts.%s: %q is not the code of a language: letters, digits, - and _, shorter than %d bytes, as es or pt-BR; \"\" is the language the game is written in",path,language,asset.RECORDS_LANGUAGE)}
                append(out,Records_Api_Text{path=path,language=language,text=strings.clone(value,context.temp_allocator)})
                if serial.text_accept(&r,',') {continue}
                if !serial.text_expect(&r,'}') {return shape}
                break
            }
        }
        if serial.text_accept(&r,',') {continue}
        if !serial.text_expect(&r,'}') || !serial.text_end(&r) {return shape}
        return ""
    }
}

// Why the texts cannot be set on rows of c; "" when they can.
records_api_texts_check :: proc(c:^Records_Api_Context,leaves:[]Records_Api_Leaf,texts:[]Records_Api_Text) -> string {
    for text in texts {
        at:=records_api_leaf_find(leaves,text.path)
        if at<0 || leaves[at].kind!=.Text {return fmt.tprintf("texts: %s is not a core.Text field of %s; %s",text.path,c.name,records_api_text_paths(leaves))}
    }
    return ""
}

records_api_texts_put :: proc(s:^Session,c:^Records_Api_Context,leaves:[]Records_Api_Leaf,row:int,texts:[]Records_Api_Text) {
    for text in texts {
        at:=records_api_leaf_find(leaves,text.path)
        if at<0 {continue}
        records.text_set(c.edit,&s.id_state,row,leaves[at].offset,text.language,text.text)
    }
}

// ---------------------------------------------------------------- the session

// The table the params name: its path under the assets folder, with or
// without .records, or its id; loaded as it is now into e.
@(private)
records_api_open :: proc(s:^Session,call:^api.Call,name:string,e:^records.Edit) -> bool {
    a:=s.app.assets
    if a==nil || s.app.info==nil || s.app.info.schema==nil {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no project with a world: open one to edit its tables")
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

// What the rows of e read and write by: the schema of the world and the
// tables of every type a field of them names.
@(private)
records_api_context :: proc(s:^Session,e:^records.Edit) -> (c:Records_Api_Context,leaves:[]Records_Api_Leaf) {
    info:=s.app.info
    ws:=info.schema
    c={schema=&ws.schema,type=ws.records[e.record].type,name=records.type_name(info,e.record),text=serial.TYPE_NONE,edit=e,registry=&s.app.assets.registry}
    if t,found:=ws.schema.lookup[core.Text];found {c.text=t}
    refs:=make([dynamic]Records_Api_Ref_Type,context.temp_allocator)
    for &r,i in info.records {
        if t,found:=ws.schema.lookup[r.ref];found {append(&refs,Records_Api_Ref_Type{t,i,records.type_name(info,i)})}
    }
    c.refs=refs[:]
    c.default=records_api_default(s,e)
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
                loaded:records.Edit
                if records_edit_load(s,file.id,&loaded,context.temp_allocator)!="" {continue}
                entry.ids,entry.names=loaded.ids[:],loaded.names[:]
            }
            append(&tables,entry)
        }
    }
    c.tables=tables[:]
    return
}

// The bytes of a new row of the table's type: its default, or zeros.
@(private)
records_api_default :: proc(s:^Session,e:^records.Edit) -> []u8 {
    default:=make([]u8,e.info.size,context.temp_allocator)
    if r:=&s.app.info.records[e.record];r.default!=nil {
        aligned,_:=mem.alloc_bytes(max(e.info.size,1),max(e.info.align,16),context.temp_allocator)
        r.default(raw_data(aligned))
        copy(default,aligned)
    }
    return default
}

// The table as records.inspect gives it, with the rows at the places given;
// nil: every row.
@(private)
records_api_table_write :: proc(s:^Session,out:^serial.Writer,c:^Records_Api_Context,leaves:[]Records_Api_Leaf,rows:[]int,all:bool) {
    e:=c.edit
    asset_named_write(s,out,"records",e.id)
    api.write_text(out,"type",c.name)
    api.write_key(out,"rows")
    serial.write_u8(out,'[')
    count:=all ? records.row_count(e) : len(rows)
    for i in 0..<count {
        if i>0 {serial.write_u8(out,',')}
        records_api_row_write(out,c,leaves,all ? i : rows[i])
    }
    serial.text_write_raw(out,"]}")
}

records_api_row_write :: proc(out:^serial.Writer,c:^Records_Api_Context,leaves:[]Records_Api_Leaf,row:int) {
    e:=c.edit
    bytes:=records.row_bytes(e,row)
    serial.text_write_raw(out,`{"id":`)
    serial.text_write_uint(out,e.ids[row])
    api.write_text(out,"name",records.row_name(e,row))
    api.write_key(out,"values")
    serial.text_write(out,c.schema,c.type,bytes,.Line)
    first:=true
    for &leaf in leaves {
        if leaf.kind!=.Text {continue}
        id:=(cast(^core.Text)&bytes[leaf.offset]).id
        if id==0 {continue}
        started:=false
        for &entry in e.texts {
            if entry.text!=id {continue}
            if first {
                api.write_key(out,"texts")
                serial.write_u8(out,'{')
            }
            if !started {
                if !first {serial.write_u8(out,',')}
                serial.text_write_string(out,leaf.path)
                serial.text_write_raw(out,":{")
            } else {
                serial.write_u8(out,',')
            }
            first,started=false,true
            serial.text_write_string(out,serial.text_field(entry.language[:]))
            serial.write_u8(out,':')
            serial.text_write_string(out,string(e.text[entry.offset:][:entry.length]))
        }
        if started {serial.write_u8(out,'}')}
    }
    if !first {serial.write_u8(out,'}')}
    serial.write_u8(out,'}')
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
    api_register(s,st,{name="records.types",summary="The record types of the project (structs marked @(record)) with their fields and their .records tables.",result=Api_Records_Types,writes_result=true,flags={.Read_Only},run=api_records_types})
    api_register(s,st,{name="records.create",params_schema=RECORDS_API_CREATE_SCHEMA,summary="Makes a new empty table (.records) of a record type at a path under the assets folder.",result=Api_Records_Table,writes_result=true,run=api_records_create})
    api_register(s,st,{name="records.inspect",params_schema=RECORDS_API_INSPECT_SCHEMA,summary="The rows of a table of game data (.records) with their ids, names, values and texts by language.",result=Api_Records_Table,writes_result=true,flags={.Read_Only},run=api_records_inspect})
    api_register(s,st,{name="records.set",params_schema=RECORDS_API_SET_SCHEMA,summary="Changes the values, the texts or the name of a row of a table of game data.",result=Api_Records_Table,writes_result=true,run=api_records_set})
    api_register(s,st,{name="records.add",params_schema=RECORDS_API_ADD_SCHEMA,summary="Adds a row to a table of game data with the defaults of its type and the values and texts given.",result=Api_Records_Table,writes_result=true,run=api_records_add})
    api_register(s,st,{name="records.remove",params_schema=RECORDS_API_REMOVE_SCHEMA,summary="Removes rows of a table of game data by name; the references to them are left as they are.",result=Api_Records_Removed,writes_result=true,flags={.Destructive},run=api_records_remove})
    api_register(s,st,{name="records.move",params_schema=RECORDS_API_MOVE_SCHEMA,summary="Moves a row of a table of game data to another place of its order; its id stays.",result=Api_Records_Table,writes_result=true,run=api_records_move})
    api_register(s,st,{name="records.import",params_schema=RECORDS_API_IMPORT_SCHEMA,summary="Updates the rows of a table of game data from a CSV file by their names and adds the rows it lacks, as one step of the history.",result=Api_Records_Import,writes_result=true,run=api_records_import})
    api_register(s,st,{name="records.export",params_schema=RECORDS_API_EXPORT_SCHEMA,summary="Writes the rows of a table of game data to a CSV file that records.import reads back.",result=Api_Records_Export,writes_result=true,flags={.Idempotent},run=api_records_export})
}

@(private)
api_records_types :: proc(s:^Session,call:^api.Call) {
    out:=call.out
    info:=s.app.info
    if s.app.assets!=nil {host.assets_scan(s.app.assets)}
    serial.text_write_raw(out,`{"types":[`)
    if info!=nil && info.schema!=nil {
        ws:=info.schema
        for &r,index in info.records {
            if index>0 {serial.write_u8(out,',')}
            serial.text_write_raw(out,`{"type":`)
            serial.text_write_string(out,records.type_name(info,index))
            if r.description!="" {api.write_text(out,"description",r.description)}
            api.write_key(out,"fields")
            serial.write_u8(out,'[')
            if v,is_struct:=runtime.type_info_base(r.info).variant.(runtime.Type_Info_Struct);is_struct {
                fields:=serial.schema_fields(&ws.schema,ws.records[index].type)
                for i in 0..<int(v.field_count) {
                    if i>0 {serial.write_u8(out,',')}
                    name:=v.names[i]
                    serial.text_write_raw(out,`{"name":`)
                    serial.text_write_string(out,name)
                    api.write_text(out,"type",serial.type_label(v.types[i]))
                    for field in fields {
                        if field.name!=name {continue}
                        if choices:=records_api_choices(&ws.schema,field.type);len(choices)>0 && records_api_kind(ws.schema.types[field.type])==.Enum {
                            api.write_key(out,"options")
                            serial.write_u8(out,'[')
                            for choice,j in choices {
                                if j>0 {serial.write_u8(out,',')}
                                serial.text_write_string(out,choice.name)
                            }
                            serial.write_u8(out,']')
                        }
                        break
                    }
                    if named:=core.record_of_ref(info,v.types[i].id);named>=0 {api.write_text(out,"records",records.type_name(info,named))}
                    for description in r.fields {
                        if description.name==name && description.text!="" {api.write_text(out,"description",description.text)}
                    }
                    serial.write_u8(out,'}')
                }
            }
            serial.write_u8(out,']')
            api.write_key(out,"tables")
            serial.write_u8(out,'[')
            if s.app.assets!=nil {
                for &file,i in records_tables(s,index) {
                    if i>0 {serial.write_u8(out,',')}
                    serial.text_write_raw(out,`{"records":"`)
                    serial.text_write_asset_id(out,file.id)
                    serial.write_u8(out,'"')
                    api.write_text(out,"path",file.path)
                    loaded:records.Edit
                    rows:=0
                    if records_edit_load(s,file.id,&loaded,context.temp_allocator)=="" {rows=records.row_count(&loaded)}
                    api.write_int(out,"rows",i64(rows))
                    serial.write_u8(out,'}')
                }
            }
            serial.text_write_raw(out,"]}")
        }
    }
    serial.text_write_raw(out,"]}")
}

@(private)
api_records_create :: proc(s:^Session,call:^api.Call) {
    p,read:=records_api_params(call,"records.create",{.Path,.Type},{.Path,.Type})
    if !read {return}
    info:=s.app.info
    if s.app.assets==nil || info==nil || info.schema==nil || !s.has_project {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no project with a world: open one to make tables")
        return
    }
    index:=records.type_index(info,p.type)
    if index<0 {
        api.call_failf(call,api.INVALID_PARAMS,"%q is not a record type of the project: records.types lists them as library.Name; a struct marked @(record) is one once the project builds",p.type)
        return
    }
    path:=strings.has_suffix(p.path,".records") ? p.path : fmt.tprintf("%s.records",p.path)
    file:=scene_file(s,path)
    if file=="" {
        api.call_failf(call,api.INVALID_PARAMS,"%s: %s",path,document_error_text(.Bad_Path))
        return
    }
    if file_exists(s,file) {
        api.call_failf(call,api.INVALID_PARAMS,"%s already exists: records.set and records.add change it",path)
        return
    }
    e:records.Edit
    records.create(s.app.info,index,asset_id_new(s),file,&e,context.temp_allocator)
    if !records_api_publish(s,call,&e,"Create records") {return}
    host.assets_scan(s.app.assets)
    c,leaves:=records_api_context(s,&e)
    records_api_table_write(s,call.out,&c,leaves,nil,true)
}

@(private)
api_records_inspect :: proc(s:^Session,call:^api.Call) {
    p,read:=records_api_params(call,"records.inspect",{.Records,.Rows},{.Records})
    if !read {return}
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) {return}
    c,leaves:=records_api_context(s,&e)
    rows:=make([dynamic]int,context.temp_allocator)
    for name in p.rows {
        row:=records_api_row_named(call,&e,name)
        if row<0 {return}
        append(&rows,row)
    }
    records_api_table_write(s,call.out,&c,leaves,rows[:],.Rows not_in p.given)
}

// Puts the values and texts of the params over a row; false with the call failed.
@(private)
records_api_row_put :: proc(s:^Session,call:^api.Call,c:^Records_Api_Context,leaves:[]Records_Api_Leaf,row:int,p:^Records_Api_Params) -> bool {
    texts:=make([dynamic]Records_Api_Text,context.temp_allocator)
    value:=slice.clone(records.row_bytes(c.edit,row),context.temp_allocator)
    message:=records_api_values_put(c,value,p.values,&texts)
    if message=="" {message=records_api_texts_read(p.texts,&texts)}
    if message=="" {message=records_api_texts_check(c,leaves,texts[:])}
    if message!="" {
        api.call_failf(call,api.INVALID_PARAMS,"row %s: %s",records.row_name(c.edit,row),message)
        return false
    }
    copy(records.row_bytes(c.edit,row),value)
    records_api_texts_put(s,c,leaves,row,texts[:])
    return true
}

@(private)
api_records_set :: proc(s:^Session,call:^api.Call) {
    p,read:=records_api_params(call,"records.set",{.Records,.Row,.Values,.Texts,.Name},{.Records,.Row})
    if !read {return}
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) {return}
    row:=records_api_row_named(call,&e,p.row)
    if row<0 {return}
    c,leaves:=records_api_context(s,&e)
    if !records_api_row_put(s,call,&c,leaves,row,&p) {return}
    if .Name in p.given && p.name!=p.row {
        if message:=records.row_rename(&e,row,p.name);message!="" {
            api.call_fail(call,api.INVALID_PARAMS,message)
            return
        }
    }
    if !records_api_publish(s,call,&e,"Records") {return}
    records_api_table_write(s,call.out,&c,leaves,[]int{row},false)
}

@(private)
api_records_add :: proc(s:^Session,call:^api.Call) {
    p,read:=records_api_params(call,"records.add",{.Records,.Name,.Values,.Texts,.After},{.Records,.Name})
    if !read {return}
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) {return}
    after:=-1
    if .After in p.given {
        if after=records_api_row_named(call,&e,p.after);after<0 {return}
    }
    row,message:=records.row_add(&e,&s.id_state,p.name,nil,after,s.app.info.records[e.record].default)
    if message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    c,leaves:=records_api_context(s,&e)
    if !records_api_row_put(s,call,&c,leaves,row,&p) {return}
    if !records_api_publish(s,call,&e,"Add record") {return}
    records_api_table_write(s,call.out,&c,leaves,[]int{row},false)
}

@(private)
api_records_remove :: proc(s:^Session,call:^api.Call) {
    p,read:=records_api_params(call,"records.remove",{.Records,.Rows},{.Records,.Rows})
    if !read {return}
    e:records.Edit
    if !records_api_open(s,call,p.records,&e) {return}
    for name in p.rows {
        if records_api_row_named(call,&e,name)<0 {return}
    }
    for name in p.rows {
        if row:=records.row_find(&e,name);row>=0 {records.row_remove(&e,row)}
    }
    if len(p.rows)>0 && !records_api_publish(s,call,&e,"Remove records") {return}
    out:=call.out
    asset_named_write(s,out,"records",e.id)
    api.write_key(out,"removed")
    serial.write_u8(out,'[')
    for name,i in p.rows {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_string(out,name)
    }
    serial.text_write_raw(out,"]}")
}

// The index a row ends at, moved right after the row at another index.
@(private)
records_move_place :: proc "contextless" (row,after:int) -> int {return after+1 if after<row else after}

@(private)
api_records_move :: proc(s:^Session,call:^api.Call) {
    p,read:=records_api_params(call,"records.move",{.Records,.Row,.After},{.Records,.Row,.After})
    if !read {return}
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
    c,leaves:=records_api_context(s,&e)
    records_api_table_write(s,call.out,&c,leaves,[]int{to},false)
}

@(private)
api_records_import :: proc(s:^Session,call:^api.Call) {
    p,read:=records_api_params(call,"records.import",{.Records,.File},{.Records,.File})
    if !read {return}
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
    out:=call.out
    asset_named_write(s,out,"records",e.id)
    api.write_int(out,"updated",i64(updated))
    api.write_int(out,"added",i64(added))
    api.write_key(out,"rejected")
    serial.write_u8(out,'[')
    for each,i in rejected {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_raw(out,`{"line":`)
        serial.text_write_int(out,i64(each.line))
        if each.name!="" {api.write_text(out,"row",each.name)}
        api.write_text(out,"reason",each.reason)
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]}")
}

@(private)
api_records_export :: proc(s:^Session,call:^api.Call) {
    p,read:=records_api_params(call,"records.export",{.Records,.File},{.Records,.File})
    if !read {return}
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
    out:=call.out
    asset_named_write(s,out,"records",e.id)
    api.write_text(out,"file",file)
    api.write_int(out,"rows",i64(records.row_count(&e)))
    api.write_int(out,"columns",i64(columns))
    serial.write_u8(out,'}')
}
