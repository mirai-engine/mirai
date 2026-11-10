package asset

import "core:mem"
import "core:reflect"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// A document as JSON: what `mirai asset dump` prints, and what `unpack`
// writes and `pack` reads back into the same bytes.
//
//   {
//     "mirai_asset": 1,
//     "kind": "MESH", "kind_version": 1, "id": "<32 hex>", "owner": "<32 hex>", "flags": ["Cooked"],
//     "dependencies": ["<32 hex>", ...],
//     "schema": [ {"kind": "Struct", "name": "...", "size": n, "align": n, "fields": [...]}, ... ],
//     "tables": [
//       {"name": "...", "flags": [...], "rows": n, "key": column or -1,
//        "columns": [{"name": "...", "type": index, "type_name": "...", "size": n, "alignment": n,
//                     "compression": "None", "flags": [...], "ref": "table or empty"}],
//        "data": [ row, ... ]}
//     ]
//   }
//
// A row is the value of the column when the table has one column without
// name, and an object with a value per column otherwise. The data of a table
// marked Bulk is not text: with Files every column names a file that holds
// its bytes, and with Summary only its size is told.
//
// With diff the text is the one a diff of two versions reads, and pack does
// not read it back: a row names the row it refers to by the key of that row,
// and a column does not tell the index of its type, so a row or a type added
// before them changes neither.
//
// Reading takes "schema" before "tables", and in a table "columns" before
// "data". Keys it does not know, type_name, size and dependencies are
// ignored: dependencies follow from the values.

TEXT_FORMAT :: 1

Text_Bulk :: enum u8 {
    Summary,
    Files,
}

Text_Options :: struct {
    schema:bool, // write the types
    bulk:Text_Bulk,
    diff:bool,   // rows refer to rows by key and columns leave out the index of their type
}

// The file that holds a bulk column, next to the text.
bulk_file_name :: proc(table,column:string) -> string {
    if column=="" {return strings.concatenate({table,".bin"},context.temp_allocator)}
    return strings.concatenate({table,".",column,".bin"},context.temp_allocator)
}

@(private="file")
write_names :: proc(w:^serial.Writer,set:$S/bit_set[$E;$B]) {
    serial.write_u8(w,'[')
    first:=true
    for member in E {
        if member not_in set {continue}
        if !first {serial.text_write_raw(w,", ")}
        first=false
        serial.text_write_string(w,reflect.enum_string(member))
    }
    serial.write_u8(w,']')
}

@(private="file")
write_key :: proc(w:^serial.Writer,depth:int,name:string,first:=false) {
    if !first {serial.write_u8(w,',')}
    if depth>=0 {serial.text_write_break(w,depth)}
    else if !first {serial.write_u8(w,' ')}
    serial.text_write_string(w,name)
    serial.text_write_raw(w,": ")
}

@(private="file")
kind_printable :: proc(kind:Fourcc) -> bool {
    for i in 0..<4 {
        c:=u8(u32(kind)>>(uint(i)*8))
        if c<0x20 || c>=0x7f || c=='"' || c=='\\' {return false}
    }
    return true
}

schema_text_write :: proc(w:^serial.Writer,s:^serial.Schema,depth:int) {
    serial.write_u8(w,'[')
    for type,index in s.types {
        if index>0 {serial.write_u8(w,',')}
        serial.text_write_break(w,depth+1)
        serial.text_write_raw(w,`{"kind": `)
        serial.text_write_string(w,reflect.enum_string(type.kind))
        if type.name!="" {write_key(w,-1,"name");serial.text_write_string(w,type.name)}
        write_key(w,-1,"size");serial.text_write_uint(w,u64(type.size))
        write_key(w,-1,"align");serial.text_write_uint(w,u64(type.align))
        #partial switch type.kind {
        case .Array:
            write_key(w,-1,"elem");serial.text_write_uint(w,u64(type.elem))
            write_key(w,-1,"count");serial.text_write_uint(w,u64(type.count))
        case .Enum,.Bit_Set,.Int,.Uint:
            if type.kind==.Int || type.kind==.Uint {
                if type.named==.None {break}
                write_key(w,-1,"named");serial.text_write_string(w,reflect.enum_string(type.named))
                if type.by_name {write_key(w,-1,"by_name");serial.text_write_raw(w,"true")}
            }
            write_key(w,-1,"choices");serial.write_u8(w,'[')
            for choice,at in s.choices[type.first:][:type.count] {
                if at>0 {serial.text_write_raw(w,", ")}
                serial.text_write_raw(w,`{"name": `);serial.text_write_string(w,choice.name)
                serial.text_write_raw(w,`, "value": `);serial.text_write_int(w,choice.value)
                serial.write_u8(w,'}')
            }
            serial.write_u8(w,']')
        case .Struct:
            write_key(w,-1,"fields");serial.write_u8(w,'[')
            for field,at in s.fields[type.first:][:type.count] {
                if at>0 {serial.write_u8(w,',')}
                serial.text_write_break(w,depth+2)
                serial.text_write_raw(w,`{"name": `);serial.text_write_string(w,field.name)
                write_key(w,-1,"type");serial.text_write_uint(w,u64(field.type))
                write_key(w,-1,"offset");serial.text_write_uint(w,u64(field.offset))
                if field.flags!={} {write_key(w,-1,"flags");write_names(w,field.flags)}
                if field.has_min {write_key(w,-1,"min");serial.text_write_float(w,transmute(u64)field.min,8)}
                if field.has_max {write_key(w,-1,"max");serial.text_write_float(w,transmute(u64)field.max,8)}
                if field.step!=0 {write_key(w,-1,"step");serial.text_write_float(w,transmute(u64)field.step,8)}
                if field.precision!=0 {write_key(w,-1,"precision");serial.text_write_float(w,u64(transmute(u32)field.precision),4)}
                if field.bits!=0 {write_key(w,-1,"bits");serial.text_write_uint(w,u64(field.bits))}
                if field.label!="" {write_key(w,-1,"label");serial.text_write_string(w,field.label)}
                if field.unit!="" {write_key(w,-1,"unit");serial.text_write_string(w,field.unit)}
                serial.write_u8(w,'}')
            }
            if type.count>0 {serial.text_write_break(w,depth+1)}
            serial.write_u8(w,']')
        }
        serial.write_u8(w,'}')
    }
    if len(s.types)>0 {serial.text_write_break(w,depth)}
    serial.write_u8(w,']')
}

// One row of a table, on one line. by_key: a column that refers to a row of a
// table with a key holds the key of that row, not its position.
document_row_write :: proc(doc:^Document,w:^serial.Writer,table,row:int,by_key:=false) {
    target:=&doc.tables[table]
    if len(target.columns)==1 && target.columns[0].name=="" {
        column:=&target.columns[0]
        serial.text_write(w,&doc.schema,column.type,document_cell(doc,table,0,row),.Line,0,.Text in column.flags)
        return
    }
    serial.write_u8(w,'{')
    for &column,at in target.columns {
        if at>0 {serial.text_write_raw(w,", ")}
        serial.text_write_string(w,column.name)
        serial.text_write_raw(w,": ")
        if by_key && column.ref>=0 && doc.tables[column.ref].key>=0 {
            referred:=&doc.tables[column.ref]
            if index:=index_load(column.data,row,column.size);index<u64(referred.rows) {
                key:=&referred.columns[referred.key]
                serial.text_write(w,&doc.schema,key.type,document_cell(doc,column.ref,referred.key,int(index)),.Line,0,.Text in key.flags)
                continue
            }
        }
        serial.text_write(w,&doc.schema,column.type,document_cell(doc,table,at,row),.Line,0,.Text in column.flags)
    }
    serial.write_u8(w,'}')
}

// The rows of a table, one per line, between brackets.
document_rows_write :: proc(doc:^Document,w:^serial.Writer,table:int,depth:int,by_key:=false) {
    serial.write_u8(w,'[')
    for row in 0..<doc.tables[table].rows {
        if row>0 {serial.write_u8(w,',')}
        serial.text_write_break(w,depth+1)
        document_row_write(doc,w,table,row,by_key)
    }
    if doc.tables[table].rows>0 {serial.text_write_break(w,depth)}
    serial.write_u8(w,']')
}

document_text_write :: proc(doc:^Document,w:^serial.Writer,options:=Text_Options{}) -> Error {
    dependencies:=make([dynamic]base.Asset_Id,doc.allocator)
    defer delete(dependencies)
    document_dependencies(doc,&dependencies) or_return
    serial.write_u8(w,'{')
    write_key(w,1,"mirai_asset",true);serial.text_write_uint(w,TEXT_FORMAT)
    write_key(w,1,"kind")
    if kind_printable(doc.kind) {
        buffer:[4]u8
        serial.text_write_string(w,fourcc_text(doc.kind,&buffer))
    } else {
        serial.text_write_uint(w,u64(doc.kind))
    }
    write_key(w,1,"kind_version");serial.text_write_uint(w,u64(doc.kind_version))
    write_key(w,1,"id");serial.write_u8(w,'"');serial.text_write_asset_id(w,doc.id);serial.write_u8(w,'"')
    if doc.owner!={} {write_key(w,1,"owner");serial.write_u8(w,'"');serial.text_write_asset_id(w,doc.owner);serial.write_u8(w,'"')}
    write_key(w,1,"flags");write_names(w,doc.flags)
    write_key(w,1,"dependencies");serial.write_u8(w,'[')
    for id,at in dependencies {
        if at>0 {serial.write_u8(w,',')}
        serial.text_write_break(w,2)
        serial.write_u8(w,'"');serial.text_write_asset_id(w,id);serial.write_u8(w,'"')
    }
    if len(dependencies)>0 {serial.text_write_break(w,1)}
    serial.write_u8(w,']')
    if options.schema {
        write_key(w,1,"schema")
        schema_text_write(w,&doc.schema,1)
    }
    write_key(w,1,"tables");serial.write_u8(w,'[')
    for &table,t in doc.tables {
        if t>0 {serial.write_u8(w,',')}
        serial.text_write_break(w,2)
        serial.write_u8(w,'{')
        write_key(w,3,"name",true);serial.text_write_string(w,table.name)
        write_key(w,3,"flags");write_names(w,table.flags)
        write_key(w,3,"rows");serial.text_write_uint(w,u64(table.rows))
        write_key(w,3,"key");serial.text_write_int(w,i64(table.key))
        write_key(w,3,"columns");serial.write_u8(w,'[')
        for &column,c in table.columns {
            if c>0 {serial.write_u8(w,',')}
            serial.text_write_break(w,4)
            serial.text_write_raw(w,`{"name": `);serial.text_write_string(w,column.name)
            if !options.diff {write_key(w,-1,"type");serial.text_write_uint(w,u64(column.type))}
            if name:=doc.schema.types[column.type].name;name!="" {write_key(w,-1,"type_name");serial.text_write_string(w,name)}
            write_key(w,-1,"size");serial.text_write_uint(w,u64(column.size))
            write_key(w,-1,"alignment");serial.text_write_uint(w,u64(column.alignment))
            write_key(w,-1,"compression");serial.text_write_string(w,reflect.enum_string(column.compression))
            write_key(w,-1,"flags");write_names(w,column.flags)
            write_key(w,-1,"ref");serial.text_write_string(w,column.ref>=0?doc.tables[column.ref].name:"")
            if .Bulk in table.flags && options.bulk==.Files {
                write_key(w,-1,"file");serial.text_write_string(w,bulk_file_name(table.name,column.name))
            }
            serial.write_u8(w,'}')
        }
        if len(table.columns)>0 {serial.text_write_break(w,3)}
        serial.write_u8(w,']')
        if .Bulk not_in table.flags {
            write_key(w,3,"data")
            document_rows_write(doc,w,t,3,options.diff)
        }
        serial.text_write_break(w,2)
        serial.write_u8(w,'}')
    }
    if len(doc.tables)>0 {serial.text_write_break(w,1)}
    serial.text_write_raw(w,"]\n}\n")
    return w.overflow==0?.None:.Out_Of_Memory
}

// ------------------------------------------------------------------ reading

// A rule of this format that a text broke.
Text_Rule :: enum u8 {
    None,
    Not_An_Asset,        // no "mirai_asset"
    Version,             // a version of the text form this build does not read
    Kind,                // a kind is four characters, or a number
    Id,                  // an id is 32 hexadecimal digits
    Unknown_Flag,
    Number_Out_Of_Range,
    Schema_First,        // "schema" comes before "tables", once
    Kind_First,          // in a type, "kind" comes before "fields", "named" and "choices", and "named" before "by_name"
    Unknown_Type_Kind,
    Too_Many_Types,
    Schema_Invalid,      // the types contradict each other
    Table_Name,          // missing, not valid, or repeated
    Columns_Order,       // in a table, "name" comes before "columns", once
    Data_Order,          // in a table, "columns" comes before "data", once
    Column,              // a name, type or alignment that is not valid
    Unknown_Compression,
    Unknown_Column,      // a row names a column its table does not have
    Unknown_Ref,         // a column refers to a table that is not there
    Key,                 // a key that is not a column of its table
    Rows,                // "rows" is not the number of rows of "data"
    Bulk_File,           // a bulk column without a file of rows*size bytes
    Tables_Invalid,      // the tables contradict each other
    Out_Of_Memory,
}

// What was wrong with a text and where: an error of the JSON or of a value
// (code), or a rule of this format (rule).
Text_Problem :: struct {
    code:serial.Text_Error_Code,
    rule:Text_Rule,
    offset:int,
}

// Gives the bytes of a bulk file, in memory of the allocator.
Bulk_Loader :: struct {
    procedure:proc(user:rawptr,name:string,allocator:mem.Allocator) -> (data:[]u8,ok:bool),
    user:rawptr,
}

@(private="file")
Text_State :: struct {
    doc:^Document,
    r:serial.Text_Reader,
    loader:Bulk_Loader,
    rule:Text_Rule,
    rule_offset:int,
    refs:[dynamic]Pending_Ref,
    has_schema:bool,
}
@(private="file")
Pending_Ref :: struct {table,column:int,name:string,offset:int}

@(private)
fail :: proc(state:^Text_State,rule:Text_Rule,offset:=-1) -> bool {
    if state.rule==.None && state.r.error.code==.None {state.rule,state.rule_offset=rule,offset<0?state.r.offset:offset}
    return false
}

// Puts a copy of text in target, which lets go of what it held.
@(private="file")
text_keep :: proc(state:^Text_State,target:^string,text:string,allocator:mem.Allocator) -> bool {
    delete(target^,allocator)
    error:mem.Allocator_Error
    if target^,error=strings.clone(text,allocator);error!=nil {return fail(state,.Out_Of_Memory)}
    return true
}

@(private="file")
read_uint :: proc(state:^Text_State,limit:u64) -> (value:u64,ok:bool) {
    serial.text_space(&state.r)
    start:=state.r.offset
    negative,magnitude:=serial.text_integer(&state.r) or_return
    if negative || magnitude>limit {return 0,fail(state,.Number_Out_Of_Range,start)}
    return magnitude,true
}

@(private="file")
read_names :: proc(state:^Text_State,$S:typeid/bit_set[$E;$B]) -> (set:S,ok:bool) {
    r:=&state.r
    serial.text_expect(r,'[') or_return
    if serial.text_accept(r,']') {return set,true}
    for {
        serial.text_space(r)
        start:=r.offset
        name:=serial.text_string(r) or_return
        member,known:=reflect.enum_from_name(E,name)
        if !known {return set,fail(state,.Unknown_Flag,start)}
        set+={member}
        if serial.text_accept(r,',') {continue}
        return set,serial.text_expect(r,']')
    }
}

@(private="file")
read_f64 :: proc(state:^Text_State) -> (value:f64,ok:bool) {
    bits:=serial.text_read_float(&state.r,8) or_return
    return transmute(f64)bits,true
}

@(private="file")
schema_text_read :: proc(state:^Text_State) -> bool {
    r,doc:=&state.r,state.doc
    s:=&doc.schema
    serial.text_expect(r,'[') or_return
    if !serial.text_accept(r,']') {
        for {
            serial.text_space(r)
            start:=r.offset
            if len(s.types)>=int(serial.TYPE_NONE)-1 {return fail(state,.Too_Many_Types,start)}
            // Appended at once, so a failure further on leaves its name to the schema.
            append(&s.types,serial.Type{elem=serial.TYPE_NONE})
            type:=&s.types[len(s.types)-1]
            serial.text_expect(r,'{') or_return
            type.first=u32(len(s.fields))
            for {
                key:=serial.text_string(r) or_return
                serial.text_expect(r,':') or_return
                switch key {
                case "kind":
                    name:=serial.text_string(r) or_return
                    kind,known:=reflect.enum_from_name(serial.Type_Kind,name)
                    if !known {return fail(state,.Unknown_Type_Kind,start)}
                    type.kind=kind
                    if kind==.Enum || kind==.Bit_Set {type.first=u32(len(s.choices))}
                case "name":
                    name:=serial.text_string(r) or_return
                    text_keep(state,&type.name,name,s.allocator) or_return
                    type.name_hash=base.name_hash(name)
                case "size": type.size=u32(read_uint(state,u64(max(u32))) or_return)
                case "align": type.align=u32(read_uint(state,serial.SCHEMA_MAX_ALIGN) or_return)
                case "elem": type.elem=serial.Type_Index(read_uint(state,u64(serial.TYPE_NONE)-1) or_return)
                case "count": type.count=u32(read_uint(state,u64(max(u32))) or_return)
                case "named":
                    if type.kind!=.Int && type.kind!=.Uint {return fail(state,.Kind_First,start)}
                    name:=serial.text_string(r) or_return
                    named,known:=reflect.enum_from_name(serial.Named_Kind,name)
                    if !known {return fail(state,.Unknown_Type_Kind,start)}
                    type.named=named
                    type.first=u32(len(s.choices))
                case "by_name":
                    if type.named==.None {return fail(state,.Kind_First,start)}
                    switch {
                    case serial.text_keyword(r,"true"):  type.by_name=true
                    case serial.text_keyword(r,"false"): type.by_name=false
                    case: return serial.text_fail(r,.Syntax)
                    }
                case "choices":
                    if type.kind!=.Enum && type.kind!=.Bit_Set && type.named==.None {return fail(state,.Kind_First,start)}
                    serial.text_expect(r,'[') or_return
                    if !serial.text_accept(r,']') {
                        for {
                            append(&s.choices,serial.Choice{})
                            type.count+=1
                            choice:=&s.choices[len(s.choices)-1]
                            serial.text_expect(r,'{') or_return
                            for {
                                field:=serial.text_string(r) or_return
                                serial.text_expect(r,':') or_return
                                switch field {
                                case "name":
                                    name:=serial.text_string(r) or_return
                                    text_keep(state,&choice.name,name,s.allocator) or_return
                                case "value":
                                    negative,magnitude:=serial.text_integer(r) or_return
                                    choice.value=negative?-i64(magnitude-1)-1:i64(magnitude)
                                case: serial.text_skip(r) or_return
                                }
                                if serial.text_accept(r,',') {continue}
                                serial.text_expect(r,'}') or_return
                                break
                            }
                            if serial.text_accept(r,',') {continue}
                            serial.text_expect(r,']') or_return
                            break
                        }
                    }
                case "fields":
                    if type.kind!=.Struct {return fail(state,.Kind_First,start)}
                    serial.text_expect(r,'[') or_return
                    if !serial.text_accept(r,']') {
                        for {
                            field:serial.Field
                            // Appended at once, so a failure further on leaves its strings to the schema.
                            append(&s.fields,field)
                            type.count+=1
                            target:=&s.fields[len(s.fields)-1]
                            serial.text_expect(r,'{') or_return
                            for {
                                name:=serial.text_string(r) or_return
                                serial.text_expect(r,':') or_return
                                switch name {
                                case "name":
                                    text:=serial.text_string(r) or_return
                                    text_keep(state,&target.name,text,s.allocator) or_return
                                    target.name_hash=base.name_hash(text)
                                case "type": target.type=serial.Type_Index(read_uint(state,u64(serial.TYPE_NONE)-1) or_return)
                                case "offset": target.offset=u32(read_uint(state,u64(max(u32))) or_return)
                                case "flags": target.flags=read_names(state,serial.Field_Flags) or_return
                                case "min": target.min=read_f64(state) or_return;target.has_min=true
                                case "max": target.max=read_f64(state) or_return;target.has_max=true
                                case "step": target.step=read_f64(state) or_return
                                case "precision":
                                    bits:=serial.text_read_float(r,4) or_return
                                    target.precision=transmute(f32)u32(bits)
                                case "bits": target.bits=u8(read_uint(state,255) or_return)
                                case "label":
                                    text:=serial.text_string(r) or_return
                                    text_keep(state,&target.label,text,s.allocator) or_return
                                case "unit":
                                    text:=serial.text_string(r) or_return
                                    text_keep(state,&target.unit,text,s.allocator) or_return
                                case: serial.text_skip(r) or_return
                                }
                                if serial.text_accept(r,',') {continue}
                                serial.text_expect(r,'}') or_return
                                break
                            }
                            if serial.text_accept(r,',') {continue}
                            serial.text_expect(r,']') or_return
                            break
                        }
                    }
                case: serial.text_skip(r) or_return
                }
                if serial.text_accept(r,',') {continue}
                serial.text_expect(r,'}') or_return
                break
            }
            if type.kind!=.Struct && type.kind!=.Enum && type.kind!=.Bit_Set && type.named==.None {type.first=0}
            if serial.text_accept(r,',') {continue}
            serial.text_expect(r,']') or_return
            break
        }
    }
    if error:=serial.schema_validate(s);error!=.None {return fail(state,error==.Out_Of_Memory?.Out_Of_Memory:.Schema_Invalid)}
    if !serial.schema_hashes_update(s,&doc.hashes) {return fail(state,.Out_Of_Memory)}
    state.has_schema=true
    return true
}

@(private="file")
table_text_read :: proc(state:^Text_State) -> bool {
    r,doc:=&state.r,state.doc
    serial.text_space(r)
    start:=r.offset
    serial.text_expect(r,'{') or_return
    table:=-1
    flags:Table_Flags
    declared:=u64(0)
    key:=-1
    has_columns,has_data:=false,false
    for {
        name:=serial.text_string(r) or_return
        serial.text_expect(r,':') or_return
        switch name {
        case "name":
            serial.text_space(r)
            at:=r.offset
            text:=serial.text_string(r) or_return
            if table>=0 {return fail(state,.Table_Name,at)}
            added,error:=document_table_add(doc,text)
            if error!=.None {return fail(state,.Table_Name,at)}
            table=added
        case "flags": flags=read_names(state,Table_Flags) or_return
        case "rows": declared=read_uint(state,MAX_ROWS) or_return
        case "key":
            negative,magnitude:=serial.text_integer(r) or_return
            key=negative?-1:int(min(magnitude,MAX_COLUMNS))
        case "columns":
            if table<0 || has_columns {return fail(state,.Columns_Order)}
            has_columns=true
            doc.tables[table].flags=flags
            serial.text_expect(r,'[') or_return
            if serial.text_accept(r,']') {break}
            for {
                column_read(state,table,int(declared)) or_return
                if serial.text_accept(r,',') {continue}
                serial.text_expect(r,']') or_return
                break
            }
        case "data":
            if !has_columns || has_data {return fail(state,.Data_Order)}
            has_data=true
            serial.text_expect(r,'[') or_return
            if serial.text_accept(r,']') {break}
            for {
                row_read(state,table) or_return
                if serial.text_accept(r,',') {continue}
                serial.text_expect(r,']') or_return
                break
            }
        case: serial.text_skip(r) or_return
        }
        if serial.text_accept(r,',') {continue}
        serial.text_expect(r,'}') or_return
        break
    }
    if table<0 {return fail(state,.Table_Name,start)}
    target:=&doc.tables[table]
    target.flags=flags
    if key>=len(target.columns) {return fail(state,.Key,start)}
    target.key=key
    if .Bulk in flags && !has_data {
        // Each column brought its file; they have to agree on the rows.
        for column in target.columns {
            if len(column.data)!=int(declared)*column.size {return fail(state,.Bulk_File,start)}
        }
        target.rows=int(declared)
    }
    if u64(target.rows)!=declared {return fail(state,.Rows,start)}
    return true
}

@(private="file")
column_read :: proc(state:^Text_State,table:int,declared:int) -> bool {
    r,doc:=&state.r,state.doc
    serial.text_space(r)
    start:=r.offset
    serial.text_expect(r,'{') or_return
    name,ref,file:string
    type:=u64(max(u64))
    alignment:=u64(0)
    compression:=Compression.None
    flags:serial.Field_Flags
    for {
        key:=serial.text_string(r) or_return
        serial.text_expect(r,':') or_return
        // Names are kept until the column exists: the reader reuses its scratch.
        switch key {
        case "name": name=strings.clone(serial.text_string(r) or_return,context.temp_allocator)
        case "type": type=read_uint(state,u64(serial.TYPE_NONE)-1) or_return
        case "alignment": alignment=read_uint(state,1<<MAX_ALIGNMENT_LOG2) or_return
        case "compression":
            serial.text_space(r)
            at:=r.offset
            text:=serial.text_string(r) or_return
            value,known:=reflect.enum_from_name(Compression,text)
            if !known {return fail(state,.Unknown_Compression,at)}
            compression=value
        case "flags": flags=read_names(state,serial.Field_Flags) or_return
        case "ref": ref=strings.clone(serial.text_string(r) or_return,context.temp_allocator)
        case "file": file=strings.clone(serial.text_string(r) or_return,context.temp_allocator)
        case: serial.text_skip(r) or_return
        }
        if serial.text_accept(r,',') {continue}
        serial.text_expect(r,'}') or_return
        break
    }
    if !state.has_schema {return fail(state,.Schema_First,start)}
    column,error:=document_column_add(doc,table,name,serial.Type_Index(min(type,u64(serial.TYPE_NONE))),flags,compression,int(alignment))
    if error!=.None {return fail(state,.Column,start)}
    if ref!="" {append(&state.refs,Pending_Ref{table,column,ref,start})}
    if file=="" {return true}
    if state.loader.procedure==nil {return fail(state,.Bulk_File,start)}
    data,ok:=state.loader.procedure(state.loader.user,file,doc.allocator)
    defer delete(data,doc.allocator)
    target:=&doc.tables[table].columns[column]
    if !ok || len(data)!=declared*target.size {return fail(state,.Bulk_File,start)}
    if column_size(doc,target,len(data))!=.None {return fail(state,.Out_Of_Memory,start)}
    copy(target.data,data)
    return true
}

@(private="file")
row_read :: proc(state:^Text_State,table:int) -> bool {
    r,doc:=&state.r,state.doc
    target:=&doc.tables[table]
    row:=target.rows
    if document_resize(doc,table,row+1)!=.None {return fail(state,.Rows)}
    if len(target.columns)==1 && target.columns[0].name=="" {
        column:=&target.columns[0]
        return serial.text_read(r,&doc.schema,column.type,document_cell(doc,table,0,row),.Text in column.flags)
    }
    serial.text_expect(r,'{') or_return
    if serial.text_accept(r,'}') {return true}
    for {
        serial.text_space(r)
        at:=r.offset
        name:=serial.text_string(r) or_return
        column,found:=document_column(doc,table,name)
        if !found {return fail(state,.Unknown_Column,at)}
        serial.text_expect(r,':') or_return
        serial.text_read(r,&doc.schema,target.columns[column].type,document_cell(doc,table,column,row),.Text in target.columns[column].flags) or_return
        if serial.text_accept(r,',') {continue}
        return serial.text_expect(r,'}')
    }
}

// Builds a document from its text. On failure the document is left empty
// and the problem says where and why.
document_text_read :: proc(doc:^Document,text:string,loader:=Bulk_Loader{},allocator:=context.allocator) -> (problem:Text_Problem,ok:bool) {
    document_init(doc,0,{},allocator)
    state:=Text_State{doc=doc,loader=loader}
    serial.text_reader_init(&state.r,text,allocator)
    state.refs=make([dynamic]Pending_Ref,allocator)
    defer {
        serial.text_reader_destroy(&state.r)
        delete(state.refs)
    }
    ok=document_text_parse(&state) && serial.text_end(&state.r)
    if !ok || state.r.error.code!=.None || state.rule!=.None {
        document_destroy(doc)
        if state.r.error.code!=.None {return {code=state.r.error.code,offset=state.r.error.offset},false}
        return {rule=state.rule,offset=state.rule_offset},false
    }
    return {},true
}

@(private="file")
document_text_parse :: proc(state:^Text_State) -> bool {
    r,doc:=&state.r,state.doc
    serial.text_expect(r,'{') or_return
    versioned:=false
    for {
        key:=serial.text_string(r) or_return
        serial.text_expect(r,':') or_return
        switch key {
        case "mirai_asset":
            if (read_uint(state,max(u64)) or_return)!=TEXT_FORMAT {return fail(state,.Version)}
            versioned=true
        case "kind":
            if serial.text_peek(r)=='"' {
                serial.text_space(r)
                at:=r.offset
                text:=serial.text_string(r) or_return
                if len(text)!=4 {return fail(state,.Kind,at)}
                doc.kind=fourcc(text)
            } else {
                doc.kind=Fourcc(read_uint(state,u64(max(u32))) or_return)
            }
        case "kind_version": doc.kind_version=u16(read_uint(state,u64(max(u16))) or_return)
        case "id":
            serial.text_space(r)
            at:=r.offset
            text:=serial.text_string(r) or_return
            id,valid:=serial.text_parse_asset_id(text)
            if !valid {return fail(state,.Id,at)}
            doc.id=id
        case "owner":
            serial.text_space(r)
            at:=r.offset
            text:=serial.text_string(r) or_return
            owner,valid:=serial.text_parse_asset_id(text)
            if !valid {return fail(state,.Id,at)}
            doc.owner=owner
        case "flags": doc.flags=read_names(state,Header_Flags) or_return
        case "schema":
            if state.has_schema {return fail(state,.Schema_First)}
            schema_text_read(state) or_return
        case "tables":
            if !state.has_schema {return fail(state,.Schema_First)}
            serial.text_expect(r,'[') or_return
            if serial.text_accept(r,']') {break}
            for {
                table_text_read(state) or_return
                if serial.text_accept(r,',') {continue}
                serial.text_expect(r,']') or_return
                break
            }
        case: serial.text_skip(r) or_return
        }
        if serial.text_accept(r,',') {continue}
        serial.text_expect(r,'}') or_return
        break
    }
    if !versioned {return fail(state,.Not_An_Asset,0)}
    for pending in state.refs {
        table,found:=document_table(doc,pending.name)
        if !found {return fail(state,.Unknown_Ref,pending.offset)}
        doc.tables[pending.table].columns[pending.column].ref=table
    }
    if document_check(doc)!=.None {return fail(state,.Tables_Invalid,0)}
    return true
}
