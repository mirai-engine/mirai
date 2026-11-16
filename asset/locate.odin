package asset

import "base:intrinsics"
import "core:mem"
import "mirai:std/base"
import "mirai:std/serial"

// A path into a document, as tools and the editor API write it:
//
//   mesh.bounds_min[0]                     a table of one row: the value and a path inside it
//   submeshes[2].index_count               a row by its position
//   entities[@0x000000000000001f].name     a row by its key
//   Transform[@0x1f].value.position        a row by the key of the row its table refers to
//   Transform                              a whole table
//   Transform[3]                           a whole row
//
// After the row comes the name of a column, unless the only column of the
// table has no name, and then a path inside its value as std/serial reads it.

Locate_Error :: enum u8 {
    None,
    Syntax,
    Unknown_Table,
    Unknown_Column,
    Missing_Row,      // the table has several rows and the path names none
    Row_Out_Of_Range,
    Invalid_Key,      // text that is not a key of the table
    Unknown_Key,      // no row has that key
    Value,            // the path inside the value is wrong: see value_error
}

Location :: struct {
    table:int,
    row:int,    // -1: every row
    column:int, // -1: every column
    type:serial.Type_Index,
    bytes:[]u8, // the part named, when it is inside one column
    inside:string, // the path inside the value of the column
    is_text:bool,
    bit:int,    // >=0: one member of a bit set
    value_error:serial.Path_Error,
    at:int,     // where in the path the error is
}

// The column that identifies the rows of a table: its key, or else a column
// that refers to the rows of a table with a key.
@(private)
identity_column :: proc(doc:^Document,table:int) -> (column:int,through:int) {
    target:=&doc.tables[table]
    if target.key>=0 {return target.key,-1}
    for candidate,at in target.columns {
        if candidate.ref>=0 && candidate.ref!=table && doc.tables[candidate.ref].key>=0 {return at,candidate.ref}
    }
    return -1,-1
}

// The row of a table with a key written as text.
@(private)
key_row :: proc(doc:^Document,table:int,text:string) -> (row:int,error:Locate_Error) {
    target:=&doc.tables[table]
    column:=&target.columns[target.key]
    type:=doc.schema.types[column.type]
    needle:[16]u8
    size:=column.size
    #partial switch type.kind {
    case .Entity,.Entity_Id,.Uint,.Int:
        value,ok:=serial.text_parse_hex(text)
        if !ok || size>8 {return -1,.Invalid_Key}
        intrinsics.mem_copy_non_overlapping(&needle,&value,size)
    case .Asset:
        id,ok:=serial.text_parse_asset_id(text)
        if !ok {return -1,.Invalid_Key}
        intrinsics.mem_copy_non_overlapping(&needle,&id,size)
    case .Array:
        if .Text not_in column.flags || !serial.type_is_bytes(&doc.schema,column.type) {return -1,.Invalid_Key}
        for at in 0..<target.rows {
            if serial.text_field(column.data[at*size:][:size])==text {return at,.None}
        }
        return -1,.Unknown_Key
    case:
        return -1,.Invalid_Key
    }
    for at in 0..<target.rows {
        if mem.compare_ptrs(raw_data(column.data[at*size:]),&needle,size)==0 {return at,.None}
    }
    return -1,.Unknown_Key
}

document_locate :: proc(doc:^Document,path:string) -> (location:Location,error:Locate_Error) {
    location={table=-1,row=-1,column=-1,type=serial.TYPE_NONE,bit=-1}
    i:=0
    for i<len(path) && path[i]!='.' && path[i]!='[' {i+=1}
    table,found:=document_table(doc,path[:i])
    if !found {return location,.Unknown_Table}
    location.table=table
    target:=&doc.tables[table]
    if i<len(path) && path[i]=='[' && (.Single not_in target.flags || i+1<len(path) && path[i+1]=='@') {
        start:=i
        i+=1
        close:=i
        for close<len(path) && path[close]!=']' {close+=1}
        if close>=len(path) || close==i {location.at=i;return location,.Syntax}
        if path[i]=='@' {
            column,through:=identity_column(doc,table)
            if column<0 {location.at=start;return location,.Invalid_Key}
            row,key_error:=key_row(doc,through>=0?through:table,path[i+1:close])
            if key_error!=.None {location.at=i+1;return location,key_error}
            if through>=0 {
                // The row of this table that refers to the row the key names.
                refs:=&target.columns[column]
                row_found:=-1
                for at in 0..<target.rows {
                    if int(index_load(refs.data,at,refs.size))==row {row_found=at;break}
                }
                if row_found<0 {location.at=i+1;return location,.Unknown_Key}
                row=row_found
            }
            location.row=row
        } else {
            index:=0
            for c in transmute([]u8)path[i:close] {
                if c<'0' || c>'9' || index>MAX_ROWS {location.at=i;return location,.Syntax}
                index=index*10+int(c-'0')
            }
            if index>=target.rows {location.at=start;return location,.Row_Out_Of_Range}
            location.row=index
        }
        i=close+1
    } else if .Single in target.flags {
        location.row=0
    }
    unnamed:=len(target.columns)==1 && target.columns[0].name==""
    if location.row<0 {
        if i<len(path) {location.at=i;return location,.Missing_Row}
        return location,.None
    }
    rest:=path[i:]
    if unnamed {
        location.column=0
        if len(rest)>0 && rest[0]=='.' {rest=rest[1:];i+=1}
    } else {
        if len(rest)==0 {return location,.None}
        if rest[0]!='.' {location.at=i;return location,.Syntax}
        rest=rest[1:];i+=1
        end:=0
        for end<len(rest) && rest[end]!='.' && rest[end]!='[' {end+=1}
        column,column_found:=document_column(doc,table,rest[:end])
        if !column_found {location.at=i;return location,.Unknown_Column}
        location.column=column
        rest=rest[end:];i+=end
        if len(rest)>0 && rest[0]=='.' {rest=rest[1:];i+=1}
    }
    column:=&target.columns[location.column]
    cell:=document_cell(doc,table,location.column,location.row)
    part,value_error,at:=serial.path_resolve(&doc.schema,column.type,rest)
    if value_error!=.None {
        location.value_error,location.at=value_error,i+at
        return location,.Value
    }
    location.type,location.bit,location.inside=part.type,part.bit,rest
    location.bytes=cell[part.offset:][:doc.schema.types[part.type].size]
    location.is_text=part.text || rest=="" && .Text in column.flags && serial.type_is_bytes(&doc.schema,column.type)
    return location,.None
}

// The key of a row, written as document_locate reads it after "@". With
// neither a key nor a table to take one from, the position of the row.
@(private)
row_identity :: proc(doc:^Document,table:int,row:int,w:^serial.Writer) {
    column,through:=identity_column(doc,table)
    if column<0 {
        serial.text_write_int(w,i64(row))
        return
    }
    source,source_row:=table,row
    if through>=0 {
        refs:=&doc.tables[table].columns[column]
        source,source_row=through,int(index_load(refs.data,row,refs.size))
        if source_row>=doc.tables[source].rows {
            serial.text_write_int(w,i64(row))
            return
        }
    }
    key:=&doc.tables[source].columns[doc.tables[source].key]
    bytes:=key.data[source_row*key.size:][:key.size]
    serial.write_u8(w,'@')
    #partial switch doc.schema.types[key.type].kind {
    case .Asset:
        serial.text_write_asset_id(w,intrinsics.unaligned_load((^base.Asset_Id)(raw_data(bytes))))
    case .Array:
        serial.write_bytes(w,transmute([]u8)serial.text_field(bytes))
    case:
        value:u64
        intrinsics.mem_copy_non_overlapping(&value,raw_data(bytes),min(len(bytes),8))
        serial.text_write_hex(w,value)
    }
}

// The value at a path as a scalar: what an editor shows in a field.
document_get :: proc(doc:^Document,path:string) -> (value:serial.Value,location:Location,error:Locate_Error) {
    location,error=document_locate(doc,path)
    if error!=.None {return}
    if location.column<0 {
        location.value_error=.Not_A_Value
        return nil,location,.Value
    }
    column:=&doc.tables[location.table].columns[location.column]
    if location.inside=="" && location.is_text {return serial.text_field(location.bytes),location,.None}
    value,location.value_error=serial.value_get(&doc.schema,column.type,document_cell(doc,location.table,location.column,location.row),location.inside)
    return value,location,location.value_error==.None?.None:.Value
}

// Writes a scalar at a path. A number has to fit its field exactly.
document_set :: proc(doc:^Document,path:string,value:serial.Value) -> (location:Location,error:Locate_Error) {
    location,error=document_locate(doc,path)
    if error!=.None {return}
    if location.column<0 {
        location.value_error=.Not_A_Value
        return location,.Value
    }
    column:=&doc.tables[location.table].columns[location.column]
    if location.inside=="" && location.is_text {
        text,is_string:=value.(string)
        switch {
        case !is_string: location.value_error=.Wrong_Type
        case len(text)>len(location.bytes): location.value_error=.Too_Long
        case:
            mem.zero_slice(location.bytes)
            copy(location.bytes,text)
        }
    } else {
        location.value_error=serial.value_set(&doc.schema,column.type,document_cell(doc,location.table,location.column,location.row),location.inside,value)
    }
    return location,location.value_error==.None?.None:.Value
}
