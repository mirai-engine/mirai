package core

import "base:runtime"
import "mirai:std/base"

// Game data the code declares and the editor fills: a struct marked
// @(record) is the row of the tables of .records assets. The rows are read
// only while the game runs and live outside the World: a Play, a copy and a
// rollback leave them as they are, and what changes in a run lives in
// components that name rows.

Record_Id :: distinct u64

// A row of a table of T: the .records asset and the id of the row in it,
// never a position. The zero value names no row.
Record :: struct($T:typeid) {table:base.Asset_Id,row:Record_Id}

// A text a player reads, as a field of a row or of a component: its key in
// the .strings of the game. Empty: no text.
Text :: struct {key:[TEXT_KEY]u8 `mirai:"text"`}

TEXT_KEY :: 64 // bytes of a key, its NUL included

// Every .strings of the assets as one table: what a function of the loop
// receives to show a text. The generator binds it.
Texts :: base.Texts

// What a text says in a language, by the name_hash of its code (that of
// gui.ui_language), and in the language its key was written in when that one
// lacks it. found is false for a key no .strings has, and for no text.
text :: proc{text_of,base.text}

text_of :: proc "contextless" (texts:^Texts,text:Text,language:u64) -> (value:string,found:bool) {
    text:=text
    return base.text(texts,base.text_get(text.key[:]),language)
}

RECORD_NAME :: 64 // bytes of the name of a row, its NUL included

Record_Info :: struct {
    name:string,    // the type, as the API names it
    library:string, // the package that declares it; a .records names its type as "library.name"
    type:typeid,
    info:^runtime.Type_Info, // from the library that declares the type
    ref:typeid, // of Record(T): how the editor knows which rows a field offers, as reflection does not know the T of a Record
    default:proc(dst:rawptr), // writes the value a new row starts with; nil: zero
    description:string,
    fields:[]Field_Description, // of the fields of its struct that have a comment on their line
    game:bool, // the game of the project declares it, not the engine or a plugin
}

// The rows of every table of one record type, as the application loaded
// them with the layout of this program; host fills it and nothing else
// writes it. rows and values are in the order of the tables and of their
// rows; index orders rows by table and id.
Record_Set :: struct {
    size:int, // of a row
    tables:[]Record_Table,
    rows:[]Record_Row,
    index:[]u32,
    values:[]u8,
    generation:u32,      // changes with every load
}

Record_Table :: struct {
    id:base.Asset_Id,
    name:[RECORD_NAME]u8, // its path, to name it in a problem
}

Record_Row :: struct {
    table:base.Asset_Id,
    row:Record_Id,
    name:[RECORD_NAME]u8,
}

// What a function of the loop receives to read the rows of T: every table of
// T in the assets. The generator binds it; a nil set has no rows.
Records :: struct($T:typeid) {set:^Record_Set}

// The row a reference names; found is false when no table has it, and for
// the zero reference.
record_get :: proc "contextless" (r:Records($T),ref:Record(T)) -> (value:T,found:bool) {
    at:=record_index(r.set,ref.table,ref.row,size_of(T))
    if at<0 {return}
    return (cast(^T)&r.set.values[at*size_of(T)])^,true
}

// The row a reference names, or a problem of the entity that holds it when
// the table or the row is not there. The zero reference is no row and no
// problem: a field that names none.
record :: proc(r:Records($T),ref:Record(T),problems:^Problems,entity:Entity) -> (value:T,found:bool) {
    if value,found=record_get(r,ref);found || ref=={} {return}
    type:="a record"
    if named,is_named:=type_info_of(T).variant.(runtime.Type_Info_Named);is_named {type=named.name}
    record_missing(r.set,ref.table,ref.row,type,problems,entity)
    return
}

// How many rows the tables of T have, for records_at.
records_count :: proc "contextless" (r:Records($T)) -> int {
    if r.set==nil || r.set.size!=size_of(T) {return 0}
    return len(r.set.rows)
}

// Changes every time the rows load again: what a function makes of them is
// made again when it changes. 0 before the first load.
records_generation :: proc "contextless" (r:Records($T)) -> u32 {
    if r.set==nil {return 0}
    return r.set.generation
}

// A row by its place among every row of T, in the order of the tables and of
// their rows, with the reference that names it.
records_at :: proc "contextless" (r:Records($T),at:int) -> (value:T,ref:Record(T)) {
    if at<0 || at>=records_count(r) {return}
    row:=r.set.rows[at]
    return (cast(^T)&r.set.values[at*size_of(T)])^,{row.table,row.row}
}

// The name a row has in its table: the editor and the API name rows by it.
record_name :: proc "contextless" (r:Records($T),ref:Record(T)) -> string {
    at:=record_index(r.set,ref.table,ref.row,size_of(T))
    if at<0 {return ""}
    return base.text_get(r.set.rows[at].name[:])
}

// The place of a row in a set; -1 without it or when the rows have another size.
record_index :: proc "contextless" (set:^Record_Set,table:base.Asset_Id,row:Record_Id,size:int) -> int {
    if set==nil || set.size!=size || len(set.index)!=len(set.rows) {return -1}
    lo,hi:=0,len(set.index)
    for lo<hi {
        mid:=(lo+hi)/2
        at:=set.index[mid]
        if int(at)>=len(set.rows) {return -1}
        if record_before(set.rows[at].table,set.rows[at].row,table,row) {lo=mid+1} else {hi=mid}
    }
    if lo<len(set.index) {
        at:=set.index[lo]
        if set.rows[at].table==table && set.rows[at].row==row {return int(at)}
    }
    return -1
}

// The record type whose Record(T) a type is; -1 for none.
record_of_ref :: proc "contextless" (info:^World_Info,type:typeid) -> int {
    if info==nil {return -1}
    for r,i in info.records {
        if r.ref==type {return i}
    }
    return -1
}

// The order of index: by table, then by row.
record_before :: proc "contextless" (table:base.Asset_Id,row:Record_Id,other_table:base.Asset_Id,other_row:Record_Id) -> bool {
    if table[0]!=other_table[0] {return table[0]<other_table[0]}
    if table[1]!=other_table[1] {return table[1]<other_table[1]}
    return row<other_row
}

// Reports a reference to a row no table has, with what to do.
record_missing :: proc(set:^Record_Set,table:base.Asset_Id,row:Record_Id,type:string,problems:^Problems,entity:Entity) {
    if set!=nil {
        for &t in set.tables {
            if t.id!=table {continue}
            report(problems,entity,"records.missing","names the row %d of %s, which that table does not have: choose another row of %s for the field, or put the row back in the table",u64(row),base.text_get(t.name[:]),type)
            return
        }
    }
    text:[base.ASSET_ID_TEXT]u8
    report(problems,entity,"records.missing","names a row of the table %s, which is not a .records of %s in the assets: choose a row of a table of %s for the field",base.asset_id_format(table,text[:]),type,type)
}
