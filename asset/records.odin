package asset

import "core:fmt"
import "core:math"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// .records: a table of game data, a typed CSV. A table that declares its
// type holds the type itself, its columns in order, and the build generates
// the Odin struct of its rows from them; one that does not holds rows of a
// type another table declares. Every table carries the schema of its rows,
// so a tool reads them without the code and the code reads them by field
// names.
//
//   records   Records_Info, one row: the name of the type of its rows
//   columns   Records_Column per column, in order (none when it does not declare)
//   defaults  one row, column value: what a new row starts as (only when it declares)
//   rows      columns id (the key, what a reference keeps), name (unique in
//             the table) and value (the row, a type of the schema of the file)
//
// A row is found by its id, never by its place: two branches that add or
// change different rows merge. A text of a row is a core.Text: a key of the
// .strings of the game.

RECORDS_VERSION :: 3
RECORDS_NAME :: 64     // bytes of the name of a row or a column, its NUL included: core.RECORD_NAME
RECORDS_TYPE :: 128    // bytes of the name of a type
RECORDS_DESCRIPTION :: 512
RECORDS_VALUES :: 512  // bytes of the names of the values of an enum
RECORDS_UNIT :: 32
RECORDS_WAS :: 256
RECORDS_COLUMNS :: 128 // columns a table declares at most
RECORDS_COUNT :: 256   // values a column of many holds at most
RECORDS_LENGTH :: 1024 // bytes of a String column at most, its NUL included
RECORDS_CHOICES :: 256 // values of an enum at most

TABLE_RECORDS :: "records"
TABLE_COLUMNS :: "columns"
TABLE_DEFAULTS :: "defaults"
TABLE_ROWS :: "rows"

Records_Info :: struct {
    type:[RECORDS_TYPE]u8 `mirai:"text"`, // the Odin name of the struct of its rows
    description:[RECORDS_DESCRIPTION]u8 `mirai:"text"`,
    declares:bool, // its columns are the type; false: its rows are of a type another table declares
}

// What a column holds, as the generated struct writes it.
Records_Kind :: enum u8 {
    Int,    // i32
    Float,  // f32
    Bool,
    Enum,   // an enum the build generates: type names it, values are its members
    Asset,  // base.Asset_Id of the kinds asset_kind says
    Text,   // core.Text: a key of the .strings of the game
    String, // [length]u8, a text of the row itself
    Record, // core.Record(type): a row of a table of that record type
    Type,   // a type the code of the package declares, by its name in type
}

Records_Column :: struct {
    name:[RECORDS_NAME]u8 `mirai:"text"`, // the name of the field
    kind:Records_Kind,
    count:u16,  // 0: one value; more: a fixed array of that many
    length:u16, // String: bytes, its NUL included
    has_min,has_max:bool,
    min,max:f64, // Int and Float
    unit:[RECORDS_UNIT]u8 `mirai:"text"`, // Int and Float
    type:[RECORDS_TYPE]u8 `mirai:"text"`, // Enum: the name of its enum; Record: the record type it names; Type: the type of the code
    values:[RECORDS_VALUES]u8 `mirai:"text"`, // Enum: the names of its members, separated by spaces
    asset_kind:[RECORDS_UNIT]u8 `mirai:"text"`, // Asset: the extensions it takes, separated by spaces (.tex)
    description:[RECORDS_DESCRIPTION]u8 `mirai:"text"`,
    was:[RECORDS_WAS]u8 `mirai:"text"`, // the names it had, separated by spaces: a row stored under one of them keeps its value
}

Records_Name :: [RECORDS_NAME]u8

// A table to write: its rows and its defaults are images (serial.value_write)
// of value_type in schema.
Records_Desc :: struct {
    id:base.Asset_Id,
    info:Records_Info,
    columns:[]Records_Column, // when it declares
    ids:[]u64,
    names:[]Records_Name,
    schema:^serial.Schema,
    value_type:serial.Type_Index,
    images:[]u8,
    defaults:[]u8, // one image, when it declares
}

Records_View :: struct {
    info:^Records_Info,
    columns:[]Records_Column,
    ids:[]u64,
    names:[]Records_Name,
    rows:^Asset_Table, // its column value holds the rows, with the type of the file
    value:int,
    defaults:^Asset_Table, // nil when it does not declare
}

@(private="file") ROWS_ID :: 0

records_document :: proc(doc:^Document,types:^Types,desc:Records_Desc,allocator:=context.allocator) -> Error {
    if desc.schema==nil || int(desc.value_type)>=len(desc.schema.types) {return .Invalid}
    size:=int(desc.schema.types[desc.value_type].size)
    if len(desc.names)!=len(desc.ids) || len(desc.images)!=len(desc.ids)*size {return .Invalid}
    if desc.info.declares && len(desc.defaults)!=size {return .Invalid}
    info:=desc.info
    if _,problem:=records_problem({info=&info,columns=desc.columns,ids=desc.ids,names=desc.names});problem!="" {return .Invalid}
    document_init(doc,KIND_RECORDS,desc.id,allocator)
    doc.kind_version=RECORDS_VERSION
    error:=records_tables(doc,types,desc,&info)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
records_tables :: proc(doc:^Document,types:^Types,desc:Records_Desc,info:^Records_Info) -> Error {
    document_put_row(doc,types,TABLE_RECORDS,info) or_return
    document_put(doc,types,TABLE_COLUMNS,desc.info.declares?desc.columns:nil) or_return
    link:serial.Schema_Import
    document_import_begin(doc,&link,desc.schema)
    defer serial.schema_import_destroy(&link)
    type:=document_import(doc,&link,desc.value_type)
    if type==serial.TYPE_NONE {return .Out_Of_Memory}
    if desc.info.declares {
        defaults:=document_table_add(doc,TABLE_DEFAULTS,{.Single}) or_return
        value:=document_column_add(doc,defaults,"value",type) or_return
        copy(doc.tables[defaults].columns[value].data,desc.defaults)
    }
    table:=document_table_add(doc,TABLE_ROWS) or_return
    document_resize(doc,table,len(desc.ids)) or_return
    document_column_put(doc,types,table,"id",desc.ids,{},.LZ) or_return
    document_column_put(doc,types,table,"name",desc.names,{.Text},.LZ) or_return
    value:=document_column_add(doc,table,"value",type,{},.LZ) or_return
    copy(doc.tables[table].columns[value].data,desc.images)
    doc.tables[table].key=ROWS_ID
    return .None
}

records_bytes :: proc(types:^Types,desc:Records_Desc,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    doc:Document
    records_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_bytes(&doc,allocator)
}

records_view :: proc(a:^Asset,types:^Types) -> (view:Records_View,error:Error) {
    kind_check(a,KIND_RECORDS,RECORDS_VERSION) or_return
    view.info=asset_row(a,types,TABLE_RECORDS,Records_Info) or_return
    view.columns=asset_rows(a,types,TABLE_COLUMNS,"",Records_Column) or_return
    view.ids=asset_rows(a,types,TABLE_ROWS,"id",u64) or_return
    view.names=asset_rows(a,types,TABLE_ROWS,"name",Records_Name) or_return
    found:bool
    view.rows,found=asset_table(a,TABLE_ROWS)
    if !found {return {},.Corrupt}
    view.value,found=table_column(view.rows,"value")
    if !found || view.rows.rows!=len(view.ids) {return {},.Corrupt}
    if view.info.declares {
        view.defaults,found=asset_table(a,TABLE_DEFAULTS)
        if !found || view.defaults.rows!=1 || len(view.defaults.columns)!=1 || view.defaults.columns[0].name!="value" {return {},.Corrupt}
    }
    if _,problem:=records_problem(view);problem!="" {return {},.Corrupt}
    return view,.None
}

// The rows of a table as values of a type of another schema, migrated by
// field names when the file stores another layout; default holds the value a
// field the file lacks takes.
records_values :: proc(a:^Asset,view:Records_View,schema:^serial.Schema,type:serial.Type_Index,dst:[]u8,default:[]u8=nil) -> Error {
    return asset_column_read(a,view.rows,view.value,schema,type,dst,default)
}

// What a new row of a table that declares its type starts as, as a value of
// a type of another schema; .Not_Found for a table that does not declare.
records_defaults :: proc(a:^Asset,view:Records_View,schema:^serial.Schema,type:serial.Type_Index,dst:[]u8) -> Error {
    if view.defaults==nil {return .Not_Found}
    return asset_column_read(a,view.defaults,0,schema,type,dst)
}

// The name of the type of the rows of a table.
records_type :: proc(view:Records_View) -> string {return serial.text_field(view.info.type[:])}

// What makes a table invalid, as a message that says how to fix it, and the
// row it is about (-1: none); "" for a valid one. A name is a word of ASCII
// letters, digits and _, unique in the table; an id is not 0 and is unique.
records_problem :: proc(view:Records_View) -> (row:int,message:string) {
    if view.info==nil {return -1,"the table names no type of rows"}
    if problem:=records_type_problem(serial.text_field(view.info.type[:]));problem!="" {return -1,problem}
    if !view.info.declares && len(view.columns)>0 {return -1,"a table that holds rows of a type another declares has no columns of its own"}
    if view.info.declares {
        if column,problem:=records_columns_problem(view.columns);problem!="" {return -1,fmt.tprintf("column %d: %s",column+1,problem)}
    }
    if len(view.names)!=len(view.ids) {return -1,"the table has as many names as ids"}
    seen_ids:=make(map[u64]bool,len(view.ids),context.temp_allocator)
    seen_names:=make(map[string]bool,len(view.ids),context.temp_allocator)
    for id,at in view.ids {
        if id==0 {return at,"a row has the id 0: give it another"}
        if seen_ids[id] {return at,"two rows have one id: give one of them another"}
        seen_ids[id]=true
        name:=serial.text_field(view.names[at][:])
        if !records_name_valid(name) || len(name)>=RECORDS_NAME {return at,"the name of a row is a word of ASCII letters, digits and _, shorter than 64 bytes"}
        if seen_names[name] {return at,"two rows have one name: rename one of them"}
        seen_names[name]=true
    }
    return -1,""
}

records_name_valid :: proc(name:string) -> bool {
    if name=="" {return false}
    for c in transmute([]u8)name {
        switch c {
        case 'a'..='z','A'..='Z','0'..='9','_':
        case: return false
        }
    }
    return true
}

// Odin's keywords, which no generated name may be.
@(private="file")
KEYWORDS :: [?]string{"asm","auto_cast","bit_field","bit_set","break","case","cast","context","continue","defer","distinct","do","dynamic","else","enum","fallthrough","false","for","foreign","if","import","in","map","matrix","nil","not_in","or_break","or_continue","or_else","or_return","package","proc","return","struct","switch","transmute","true","typeid","union","using","when","where"}

// Whether a name is one Odin takes for a field, a type or a member: a
// letter or _ and then letters, digits and _, and no keyword.
records_identifier :: proc(name:string) -> bool {
    if name=="" || name=="_" || name[0]>='0' && name[0]<='9' || !records_name_valid(name) {return false}
    for keyword in KEYWORDS {
        if name==keyword {return false}
    }
    return true
}

// Why a name cannot be the one of a type of rows; "" when it can.
records_type_problem :: proc(name:string) -> string {
    if !records_identifier(name) || len(name)>=RECORDS_TYPE {return fmt.tprintf("%q is not a name of a type: a word of ASCII letters, digits and _ that starts with a letter, as Item or Horde_Wave",name)}
    return ""
}

// What makes the columns of a type invalid, as a message that says how to
// fix it, and the column it is about; "" for valid ones.
records_columns_problem :: proc(columns:[]Records_Column) -> (column:int,message:string) {
    if len(columns)>RECORDS_COLUMNS {return len(columns)-1,fmt.tprintf("a type has at most %d columns",RECORDS_COLUMNS)}
    for &c,at in columns {
        name:=serial.text_field(c.name[:])
        if !records_identifier(name) {return at,fmt.tprintf("%q is not a name of a column: a word of ASCII letters, digits and _ that starts with a letter, and no keyword of Odin",name)}
        for &other in columns[:at] {
            if serial.text_field(other.name[:])==name {return at,fmt.tprintf("two columns are named %s: rename one of them",name)}
        }
        for &other,j in columns {
            if j==at {continue}
            rest:=serial.text_field(other.was[:])
            for was in strings.fields_iterator(&rest) {
                if was==name {return at,fmt.tprintf("%s is the name column %s had: a stored value would go to both; name it otherwise",name,serial.text_field(other.name[:]))}
            }
        }
        rest:=serial.text_field(c.was[:])
        for was in strings.fields_iterator(&rest) {
            if !records_identifier(was) {return at,fmt.tprintf("%q, a name column %s had, is not a name of a column",was,name)}
        }
        if problem:=records_column_problem(&c);problem!="" {return at,fmt.tprintf("%s: %s",name,problem)}
    }
    return -1,""
}

// Why the options of a column do not fit its kind; "" when they do.
records_column_problem :: proc(c:^Records_Column) -> string {
    if int(c.count)>RECORDS_COUNT {return fmt.tprintf("a column holds at most %d values; count 0 is one value",RECORDS_COUNT)}
    if c.kind>max(Records_Kind) {return "its kind is not one there is"}
    type:=serial.text_field(c.type[:])
    #partial switch c.kind {
    case .Int,.Float:
        if c.has_min && (math.is_nan(c.min) || math.is_inf(c.min)) || c.has_max && (math.is_nan(c.max) || math.is_inf(c.max)) {return "min and max are finite numbers"}
        if c.has_min && c.has_max && c.min>c.max {return "min is more than max: swap them"}
    case .Enum:
        if !records_identifier(type) {return fmt.tprintf("%q is not a name of its enum: a word that starts with a letter, as Item_Rarity",type)}
        values:=serial.text_field(c.values[:])
        count:=0
        rest:=values
        for value in strings.fields_iterator(&rest) {
            if !records_identifier(value) {return fmt.tprintf("%q is not a name of a value: a word that starts with a letter, as Common",value)}
            again:=values
            seen:=0
            for other in strings.fields_iterator(&again) {
                if other==value {seen+=1}
            }
            if seen>1 {return fmt.tprintf("the value %s is there twice",value)}
            count+=1
        }
        if count==0 {return "an enum has values: write their names, separated by spaces"}
        if count>RECORDS_CHOICES {return fmt.tprintf("an enum has at most %d values",RECORDS_CHOICES)}
    case .String:
        if c.length<2 || int(c.length)>RECORDS_LENGTH {return fmt.tprintf("a text of the row takes from 2 to %d bytes, its end included",RECORDS_LENGTH)}
    case .Record:
        if records_type_problem(type)!="" {return fmt.tprintf("%q is not a record type: name the type of the rows it picks, as Item",type)}
    case .Type:
        if !records_identifier(type) {return fmt.tprintf("%q is not a type of the code: name one the package declares, as Ability_Input",type)}
    }
    return ""
}
