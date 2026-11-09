package asset

import "core:unicode/utf8"
import "mirai:std/base"
import "mirai:std/serial"

// .records: a table of game data, whose rows are values of one struct of the
// code marked @(record). The file carries the schema of its rows, so a tool
// reads them without the code and the code reads them by field names.
//
//   records  Records_Info, one row: the type of its rows
//   rows     columns id (the key, what a reference keeps), name (unique in
//            the table) and value (the row, a type of the schema of the file)
//   texts    Records_Text: a text of the rows in a language, by text and language
//   text     bulk u8: the texts, UTF-8, one after the other
//
// A row is found by its id, never by its place: two branches that add or
// change different rows merge. A text of a row is a core.Text whose id is
// the text of its entries; a language it lacks has none.

RECORDS_VERSION :: 1
RECORDS_NAME :: 64     // bytes of the name of a row, its NUL included: core.RECORD_NAME
RECORDS_TYPE :: 128    // bytes of the name of the type of the rows
RECORDS_LANGUAGE :: 16 // bytes of the code of a language

TABLE_RECORDS :: "records"
TABLE_ROWS :: "rows"
TABLE_RECORD_TEXTS :: "texts"
TABLE_RECORD_TEXT :: "text"

Records_Info :: struct {
    type:[RECORDS_TYPE]u8 `mirai:"text"`, // "library.Name" of the struct of its rows
}

Records_Name :: [RECORDS_NAME]u8

Records_Text :: struct {
    text:u64,                                      // the id of a core.Text
    language:[RECORDS_LANGUAGE]u8 `mirai:"text"`, // its code ("es", "pt-BR"); "": the language the game is written in
    offset,length:u32,                             // bytes of text
}

// A table to write: its rows are images (serial.value_write) of type in schema.
Records_Desc :: struct {
    id:base.Asset_Id,
    type:string,
    ids:[]u64,
    names:[]Records_Name,
    schema:^serial.Schema,
    value_type:serial.Type_Index,
    images:[]u8,
    texts:[]Records_Text,
    text:[]u8,
}

Records_View :: struct {
    info:^Records_Info,
    ids:[]u64,
    names:[]Records_Name,
    texts:[]Records_Text,
    text:[]u8,
    rows:^Asset_Table, // its column value holds the rows, with the type of the file
    value:int,
}

@(private="file") ROWS_ID :: 0
@(private="file") ROWS_NAME :: 1
@(private="file") ROWS_VALUE :: 2

records_document :: proc(doc:^Document,types:^Types,desc:Records_Desc,allocator:=context.allocator) -> Error {
    if desc.schema==nil || int(desc.value_type)>=len(desc.schema.types) {return .Invalid}
    size:=int(desc.schema.types[desc.value_type].size)
    if len(desc.names)!=len(desc.ids) || len(desc.images)!=len(desc.ids)*size {return .Invalid}
    info:Records_Info
    if !base.text_set(info.type[:],desc.type) {return .Invalid}
    if _,problem:=records_problem({info=&info,ids=desc.ids,names=desc.names,texts=desc.texts,text=desc.text});problem!="" {return .Invalid}
    document_init(doc,KIND_RECORDS,desc.id,allocator)
    doc.kind_version=RECORDS_VERSION
    error:=records_tables(doc,types,desc,&info)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
records_tables :: proc(doc:^Document,types:^Types,desc:Records_Desc,info:^Records_Info) -> Error {
    document_put_row(doc,types,TABLE_RECORDS,info) or_return
    table:=document_table_add(doc,TABLE_ROWS) or_return
    document_resize(doc,table,len(desc.ids)) or_return
    document_column_put(doc,types,table,"id",desc.ids,{},.LZ) or_return
    document_column_put(doc,types,table,"name",desc.names,{.Text},.LZ) or_return
    link:serial.Schema_Import
    document_import_begin(doc,&link,desc.schema)
    defer serial.schema_import_destroy(&link)
    type:=document_import(doc,&link,desc.value_type)
    if type==serial.TYPE_NONE {return .Out_Of_Memory}
    value:=document_column_add(doc,table,"value",type,{},.LZ) or_return
    copy(doc.tables[table].columns[value].data,desc.images)
    doc.tables[table].key=ROWS_ID
    document_put(doc,types,TABLE_RECORD_TEXTS,desc.texts,{},.LZ) or_return
    document_put(doc,types,TABLE_RECORD_TEXT,desc.text,{.Bulk},.LZ) or_return
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
    view.ids=asset_rows(a,types,TABLE_ROWS,"id",u64) or_return
    view.names=asset_rows(a,types,TABLE_ROWS,"name",Records_Name) or_return
    view.texts=table_rows(a,types,TABLE_RECORD_TEXTS,Records_Text) or_return
    view.text=table_rows(a,types,TABLE_RECORD_TEXT,u8) or_return
    found:bool
    view.rows,found=asset_table(a,TABLE_ROWS)
    if !found {return {},.Corrupt}
    view.value,found=table_column(view.rows,"value")
    if !found || view.rows.rows!=len(view.ids) {return {},.Corrupt}
    if _,problem:=records_problem(view);problem!="" {return {},.Corrupt}
    return view,.None
}

// The rows of a table as values of a type of another schema, migrated by
// field names when the file stores another layout; default holds the value a
// field the file lacks takes.
records_values :: proc(a:^Asset,view:Records_View,schema:^serial.Schema,type:serial.Type_Index,dst:[]u8,default:[]u8=nil) -> Error {
    return asset_column_read(a,view.rows,view.value,schema,type,dst,default)
}

// The name of the type of the rows of a table.
records_type :: proc(view:Records_View) -> string {return serial.text_field(view.info.type[:])}

// What makes a table invalid, as a message that says how to fix it, and the
// row it is about (-1: none); "" for a valid one. A name is a word of ASCII
// letters, digits and _, unique in the table; an id is not 0 and is unique;
// every text is UTF-8 inside text, ordered by text and language, once each.
records_problem :: proc(view:Records_View) -> (row:int,message:string) {
    if view.info==nil || serial.text_field(view.info.type[:])=="" {return -1,"the table names no type of rows"}
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
    for &entry,at in view.texts {
        language:=serial.text_field(entry.language[:])
        if entry.text==0 || len(language)>=RECORDS_LANGUAGE {return -1,"a text has the id 0 or a code of language too long"}
        if u64(entry.offset)+u64(entry.length)>u64(len(view.text)) || !utf8.valid_string(string(view.text[entry.offset:][:entry.length])) {return -1,"a text is outside the texts or not UTF-8"}
        if at>0 {
            previous:=&view.texts[at-1]
            if previous.text>entry.text || previous.text==entry.text && serial.text_field(previous.language[:])>=language {return -1,"the texts are not ordered by text and language, once each"}
        }
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
