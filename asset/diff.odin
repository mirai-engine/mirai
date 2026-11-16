package asset

import "core:mem"
import "mirai:std/base"
import "mirai:std/serial"

// What changed between two documents, one line per difference:
//
//   ~ Transform[@0x000000000000001f].value.position[1]: 0 -> 2.5
//   - Light[@0x0000000000000020]                 a row only the first has
//   + entities[@0x0000000000000031]              a row only the second has
//   - Light.value.range: 10                      a field only the first has
//   + fog                                        a table only the second has
//
// Rows are matched by their key, or by the key of the row they refer to, so
// two scenes with the same entities in another order do not differ; a table
// with neither is matched by position. Fields are matched by name through
// the schema of each document, and values compared as their text. A table
// marked Bulk is compared whole.

@(private="file")
Diff :: struct {
    a,b:^Document,
    w:^serial.Writer,
    path:[dynamic]u8,
    left,right:serial.Writer,
    count:int,
    exhausted:bool, // no memory to match the rows of a table
}

@(private="file")
line :: proc(d:^Diff,mark:u8) {
    d.count+=1
    serial.write_u8(d.w,mark)
    serial.write_u8(d.w,' ')
    serial.write_bytes(d.w,d.path[:])
}
@(private="file")
line_end :: proc(d:^Diff) {serial.write_u8(d.w,'\n')}

@(private="file")
value_text :: proc(doc:^Document,w:^serial.Writer,type:serial.Type_Index,bytes:[]u8,is_text:bool) -> string {
    serial.writer_reset(w)
    serial.text_write(w,&doc.schema,type,bytes,.Line,0,is_text)
    return string(serial.writer_bytes(w))
}

// A line for a part only one document has, with its value.
@(private="file")
only :: proc(d:^Diff,mark:u8,doc:^Document,type:serial.Type_Index,bytes:[]u8,is_text:bool) {
    line(d,mark)
    serial.text_write_raw(d.w,": ")
    serial.write_bytes(d.w,transmute([]u8)value_text(doc,&d.left,type,bytes,is_text))
    line_end(d)
}

@(private="file")
diff_value :: proc(d:^Diff,type_a:serial.Type_Index,bytes_a:[]u8,text_a:bool,type_b:serial.Type_Index,bytes_b:[]u8,text_b:bool) {
    sa,sb:=&d.a.schema,&d.b.schema
    ta,tb:=sa.types[type_a],sb.types[type_b]
    if d.a.hashes[type_a]==d.b.hashes[type_b] && text_a==text_b && mem.compare(bytes_a,bytes_b)==0 {return}
    base_length:=len(d.path)
    defer base.truncate(&d.path,base_length)
    if ta.kind==.Struct && tb.kind==.Struct {
        fields_b:=sb.fields[tb.first:][:tb.count]
        for &field in sa.fields[ta.first:][:ta.count] {
            if .Transient in field.flags {continue}
            base.truncate(&d.path,base_length)
            append(&d.path,'.');append(&d.path,field.name)
            part:=bytes_a[field.offset:][:sa.types[field.type].size]
            is_text:=.Text in field.flags && serial.type_is_bytes(sa,field.type)
            other:^serial.Field
            for &candidate in fields_b {
                if candidate.name==field.name {other=&candidate;break}
            }
            if other==nil || .Transient in other.flags {
                only(d,'-',d.a,field.type,part,is_text)
                continue
            }
            diff_value(d,field.type,part,is_text,other.type,bytes_b[other.offset:][:sb.types[other.type].size],.Text in other.flags && serial.type_is_bytes(sb,other.type))
        }
        for &field in fields_b {
            if .Transient in field.flags {continue}
            known:=false
            for &candidate in sa.fields[ta.first:][:ta.count] {
                if candidate.name==field.name && .Transient not_in candidate.flags {known=true;break}
            }
            if known {continue}
            base.truncate(&d.path,base_length)
            append(&d.path,'.');append(&d.path,field.name)
            only(d,'+',d.b,field.type,bytes_b[field.offset:][:sb.types[field.type].size],.Text in field.flags && serial.type_is_bytes(sb,field.type))
        }
        return
    }
    if ta.kind==.Array && tb.kind==.Array && !text_a && !text_b {
        size_a,size_b:=int(sa.types[ta.elem].size),int(sb.types[tb.elem].size)
        buffer:[24]u8
        for i in 0..<int(max(ta.count,tb.count)) {
            base.truncate(&d.path,base_length)
            append(&d.path,'[');append(&d.path,index_text(buffer[:],i));append(&d.path,']')
            switch {
            case i>=int(tb.count): only(d,'-',d.a,ta.elem,bytes_a[i*size_a:][:size_a],false)
            case i>=int(ta.count): only(d,'+',d.b,tb.elem,bytes_b[i*size_b:][:size_b],false)
            case: diff_value(d,ta.elem,bytes_a[i*size_a:][:size_a],false,tb.elem,bytes_b[i*size_b:][:size_b],false)
            }
        }
        return
    }
    left:=value_text(d.a,&d.left,type_a,bytes_a,text_a)
    right:=value_text(d.b,&d.right,type_b,bytes_b,text_b)
    if left==right {return}
    line(d,'~')
    serial.text_write_raw(d.w,": ")
    serial.text_write_raw(d.w,left)
    serial.text_write_raw(d.w," -> ")
    serial.text_write_raw(d.w,right)
    line_end(d)
}

@(private="file")
index_text :: proc(buffer:[]u8,value:int) -> string {
    at:=len(buffer)
    rest:=value
    for {
        at-=1
        buffer[at]=u8('0'+rest%10)
        rest/=10
        if rest==0 {break}
    }
    return string(buffer[at:])
}

// The bytes that identify a row across documents, or nil when the table has
// to be matched by position.
@(private)
identity :: proc(doc:^Document,table:int,row:int) -> []u8 {
    column,through:=identity_column(doc,table)
    if column<0 {return nil}
    source,source_row:=table,row
    if through>=0 {
        refs:=&doc.tables[table].columns[column]
        source,source_row=through,int(index_load(refs.data,row,refs.size))
        if source_row>=doc.tables[source].rows {return nil}
    }
    key:=&doc.tables[source].columns[doc.tables[source].key]
    if key.size==0 {return nil}
    return key.data[source_row*key.size:][:key.size]
}

@(private="file")
keyed :: proc(doc:^Document,table:int) -> bool {
    for row in 0..<doc.tables[table].rows {
        if identity(doc,table,row)==nil {return false}
    }
    return doc.tables[table].rows>0
}

@(private="file")
path_row :: proc(d:^Diff,doc:^Document,table:int,row:int) {
    target:=&doc.tables[table]
    clear(&d.path)
    append(&d.path,target.name)
    if .Single in target.flags {return}
    serial.writer_reset(&d.left)
    row_identity(doc,table,row,&d.left)
    append(&d.path,'[');append(&d.path,..serial.writer_bytes(&d.left));append(&d.path,']')
}

@(private="file")
diff_rows :: proc(d:^Diff,table_a,row_a,table_b,row_b:int) {
    ta,tb:=&d.a.tables[table_a],&d.b.tables[table_b]
    path_row(d,d.a,table_a,row_a)
    base_length:=len(d.path)
    for &column,at in ta.columns {
        other,found:=document_column(d.b,table_b,column.name)
        if !found || column.ref>=0 {continue}
        base.truncate(&d.path,base_length)
        if column.name!="" {append(&d.path,'.');append(&d.path,column.name)}
        diff_value(d,column.type,document_cell(d.a,table_a,at,row_a),.Text in column.flags && serial.type_is_bytes(&d.a.schema,column.type),
            tb.columns[other].type,document_cell(d.b,table_b,other,row_b),.Text in tb.columns[other].flags && serial.type_is_bytes(&d.b.schema,tb.columns[other].type))
    }
}

@(private="file")
diff_tables :: proc(d:^Diff,table_a,table_b:int) {
    a,b:=d.a,d.b
    ta,tb:=&a.tables[table_a],&b.tables[table_b]
    for column in ta.columns {
        if _,found:=document_column(b,table_b,column.name);found {continue}
        clear(&d.path);append(&d.path,ta.name);append(&d.path,'.');append(&d.path,column.name)
        line(d,'-');line_end(d)
    }
    for column in tb.columns {
        if _,found:=document_column(a,table_a,column.name);found {continue}
        clear(&d.path);append(&d.path,tb.name);append(&d.path,'.');append(&d.path,column.name)
        line(d,'+');line_end(d)
    }
    if .Bulk in ta.flags || .Bulk in tb.flags {
        for &column in ta.columns {
            other,found:=document_column(b,table_b,column.name)
            if !found {continue}
            theirs:=&tb.columns[other]
            if a.hashes[column.type]==b.hashes[theirs.type] && mem.compare(column.data,theirs.data)==0 {continue}
            clear(&d.path);append(&d.path,ta.name)
            if column.name!="" {append(&d.path,'.');append(&d.path,column.name)}
            line(d,'~')
            for side in 0..<2 {
                data,rows:=side==0?column.data:theirs.data,side==0?ta.rows:tb.rows
                serial.text_write_raw(d.w,side==0?": ":" -> ")
                serial.text_write_int(d.w,i64(rows))
                serial.text_write_raw(d.w," rows, ")
                serial.text_write_int(d.w,i64(len(data)))
                serial.text_write_raw(d.w," bytes, hash ")
                serial.text_write_hex(d.w,base.hash64(data),16,false)
            }
            line_end(d)
        }
        return
    }
    if !keyed(a,table_a) || !keyed(b,table_b) {
        for row in 0..<max(ta.rows,tb.rows) {
            switch {
            case row>=tb.rows: path_row(d,a,table_a,row);line(d,'-');line_end(d)
            case row>=ta.rows: path_row(d,b,table_b,row);line(d,'+');line_end(d)
            case: diff_rows(d,table_a,row,table_b,row)
            }
        }
        return
    }
    rows_b,no_rows:=make(map[string]int,tb.rows,a.allocator)
    defer delete(rows_b)
    matched,no_matched:=make([]bool,tb.rows,a.allocator)
    defer delete(matched,a.allocator)
    if no_rows!=nil || no_matched!=nil {d.exhausted=true;return}
    for row in 0..<tb.rows {
        key:=string(identity(b,table_b,row))
        if !(key in rows_b) {rows_b[key]=row}
    }
    for row in 0..<ta.rows {
        other,found:=rows_b[string(identity(a,table_a,row))]
        if !found || matched[other] {
            path_row(d,a,table_a,row);line(d,'-');line_end(d)
            continue
        }
        matched[other]=true
        diff_rows(d,table_a,row,table_b,other)
    }
    for row in 0..<tb.rows {
        if matched[row] {continue}
        path_row(d,b,table_b,row);line(d,'+');line_end(d)
    }
}

// Writes the differences into w and returns how many there are; Out_Of_Memory
// when w or the matching of the rows had none, and then they are not all there.
document_diff :: proc(a,b:^Document,w:^serial.Writer) -> (count:int,error:Error) {
    d:=Diff{a=a,b=b,w=w}
    d.path=make([dynamic]u8,a.allocator)
    serial.writer_init(&d.left,allocator=a.allocator)
    serial.writer_init(&d.right,allocator=a.allocator)
    defer {
        delete(d.path)
        serial.writer_destroy(&d.left);serial.writer_destroy(&d.right)
    }
    header :: proc(d:^Diff,name:string,left,right:u64,digits:int) {
        if left==right {return}
        clear(&d.path);append(&d.path,name)
        line(d,'~')
        serial.text_write_raw(d.w,": ")
        if digits>0 {serial.text_write_hex(d.w,left,digits)} else {serial.text_write_uint(d.w,left)}
        serial.text_write_raw(d.w," -> ")
        if digits>0 {serial.text_write_hex(d.w,right,digits)} else {serial.text_write_uint(d.w,right)}
        line_end(d)
    }
    header(&d,"kind",u64(a.kind),u64(b.kind),8)
    header(&d,"kind_version",u64(a.kind_version),u64(b.kind_version),0)
    if a.id!=b.id {
        clear(&d.path);append(&d.path,"id")
        line(&d,'~')
        serial.text_write_raw(w,": ");serial.text_write_asset_id(w,a.id)
        serial.text_write_raw(w," -> ");serial.text_write_asset_id(w,b.id)
        line_end(&d)
    }
    header(&d,"flags",u64(transmute(u32)a.flags),u64(transmute(u32)b.flags),8)
    for table,at in a.tables {
        other,found:=document_table(b,table.name)
        if !found {
            clear(&d.path);append(&d.path,table.name)
            line(&d,'-');line_end(&d)
            continue
        }
        diff_tables(&d,at,other)
    }
    for table in b.tables {
        if _,found:=document_table(a,table.name);found {continue}
        clear(&d.path);append(&d.path,table.name)
        line(&d,'+');line_end(&d)
    }
    return d.count,.Out_Of_Memory if d.exhausted || w.overflow!=0 else .None
}

