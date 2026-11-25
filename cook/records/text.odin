package records

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"

// The rows of a table by text: the values of a row as JSON, as the records.*
// methods of the editor, mirai records and content tools give and take them,
// and as the cells of a CSV. A core.Record field is named by its row.

// What a core.Record(T) holds, for any T.
Ref :: struct {table:base.Asset_Id,row:core.Record_Id}
#assert(size_of(Ref)==size_of(core.Record(Ref)))

Ref_Type :: struct {
    type:serial.Type_Index, // of core.Record(T) in the schema
    record:string,          // T
}

// A table whose rows a core.Record names.
Rows :: struct {
    record:string, // the type of its rows
    id:base.Asset_Id,
    path:string, // under the assets folder
    ids:[]u64,
    names:[]asset.Records_Name,
}

// What reading and writing the rows of a table by text needs.
Context :: struct {
    schema:^serial.Schema,
    type:serial.Type_Index,  // of the rows
    name:string,             // the type of the rows
    refs:[]Ref_Type,
    tables:[]Rows,
    edit:^Edit,      // the table that changes: its rows stand for those of its file in tables
    registry:^asset.Registry, // nil: assets go by id only
    default:[]u8,            // a new row of the type; nil: zeros
}

Leaf_Kind :: enum u8 {
    Value,  // a number, bool, enum, entity or asset, by its path
    Bytes,  // a text field ([N]u8 mirai:"text")
    Ref,    // a core.Record
    Member, // of a bit set, as a bool
}

// A value of a row that is one cell of a CSV.
Leaf :: struct {
    path:string, // as serial paths write it
    kind:Leaf_Kind,
    type:serial.Type_Index,
    offset:int,
    record:string, // Ref: the type of the rows it names
}

Csv_Column :: struct {
    title:string,
    leaf:int, // -1: the name of the row
}


// ---------------------------------------------------------------- the shape of a row

// The record type a core.Record of the schema names; "" for another type.
ref_record :: proc(c:^Context,type:serial.Type_Index) -> string {
    for r in c.refs {
        if r.type==type {return r.record}
    }
    return ""
}

// A .records of the assets: its path under the assets folder and the record
// type of its rows.
Table_File :: struct {
    id:base.Asset_Id,
    path:string,
    type:string,
    declares:bool, // its columns are the type
}

// The .records of a registry, in the order of its files; those that do not
// read are left out.
tables_scan :: proc(registry:^asset.Registry,types:^asset.Types,allocator:=context.temp_allocator) -> []Table_File {
    out:=make([dynamic]Table_File,allocator)
    for &f in registry.files {
        if f.kind!=asset.KIND_RECORDS || f.id=={} {continue}
        data,error:=asset.registry_read(registry,f.path,context.temp_allocator)
        if error!=.None {continue}
        a:asset.Asset
        if asset.asset_take(&a,data,context.temp_allocator)!=.None {continue}
        if view,viewed:=asset.records_view(&a,types);viewed==.None {
            append(&out,Table_File{id=f.id,path=strings.clone(f.path,allocator),type=strings.clone(asset.records_type(view),allocator),declares=view.info.declares})
        }
        asset.asset_close(&a)
    }
    return out[:]
}

// What the rows of e read and write by: the schema its columns make and the
// rows of every table among files of a type a reference of them names. info:
// the types the build has, whose core.Record fields name rows too; nil: none.
context_make :: proc(e:^Edit,info:^core.World_Info,registry:^asset.Registry,types:^asset.Types,files:[]Table_File) -> (c:Context,leaves:[]Leaf) {
    c={schema=&e.schema,type=e.type,name=type_name(e),edit=e,registry=registry,default=e.defaults}
    refs:=make([dynamic]Ref_Type,context.temp_allocator)
    for &column,at in e.columns {
        if column.kind!=.Record {continue}
        field,_:=column_field(e,at)
        type:=field.type
        if column.count>0 {type=e.schema.types[type].elem}
        append(&refs,Ref_Type{type,serial.text_field(column.type[:])})
    }
    // References inside the types of the code: core.Record(T) of a type the build has.
    if info!=nil {
        for &r in info.records {
            if t,found:=e.schema.lookup[r.ref];found {append(&refs,Ref_Type{t,r.name})}
        }
    }
    c.refs=refs[:]
    leaves=leaves_of(&c)
    tables:=make([dynamic]Rows,context.temp_allocator)
    for &leaf in leaves {
        if leaf.kind!=.Ref {continue}
        listed:=false
        for &t in tables {
            if t.record==leaf.record {listed=true;break}
        }
        if listed {continue}
        for &file in files {
            if file.type!=leaf.record {continue}
            entry:=Rows{record=leaf.record,id=file.id,path=file.path}
            if file.id!=e.id {
                ok:bool
                if entry.ids,entry.names,ok=rows_read(registry,types,file.id);!ok {continue}
            }
            append(&tables,entry)
        }
    }
    c.tables=tables[:]
    return
}

// The values of a row as JSON on one line, as values_put reads them back.
row_text :: proc(e:^Edit,row:int,allocator:=context.temp_allocator) -> string {
    values:serial.Writer
    serial.writer_init(&values,256,allocator)
    serial.text_write(&values,&e.schema,e.type,row_bytes(e,row),.Line)
    return string(serial.writer_bytes(&values))
}

// Every value of a row that is a cell of a CSV, in the order of its fields.
leaves_of :: proc(c:^Context,allocator:=context.temp_allocator) -> []Leaf {
    out:=make([dynamic]Leaf,allocator)
    add :: proc(c:^Context,type:serial.Type_Index,path:string,offset:int,text:bool,out:^[dynamic]Leaf,depth:int) {
        s:=c.schema
        if depth>16 || !serial.type_valid(s,type) {return}
        if record:=ref_record(c,type);record!="" {
            append(out,Leaf{path=path,kind=.Ref,type=type,offset=offset,record=record})
            return
        }
        if text && serial.type_is_bytes(s,type) {
            append(out,Leaf{path=path,kind=.Bytes,type=type,offset=offset})
            return
        }
        t:=s.types[type]
        #partial switch value_kind(t) {
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
            for choice in choices(s,type) {
                append(out,Leaf{path=fmt.aprintf("%s.%s",path,choice.name,allocator=context.allocator),kind=.Member,type=type,offset=offset})
            }
        case:
            append(out,Leaf{path=path,kind=.Value,type=type,offset=offset})
        }
    }
    context.allocator=allocator
    add(c,c.type,"",0,false,&out,0)
    return out[:]
}

// The kind a type is read and written as: a @(names) integer as an enum or a bit set.
value_kind :: proc(t:serial.Type) -> serial.Type_Kind {
    switch t.named {
    case .None:
    case .Values: return .Enum
    case .Bits:   return .Bit_Set
    }
    return t.kind
}

// The names of the values of an enum or a @(names) integer, or of the bits of
// a bit set or a mask.
choices :: proc(s:^serial.Schema,type:serial.Type_Index) -> []serial.Choice {
    if !serial.type_valid(s,type) {return nil}
    t:=s.types[type]
    #partial switch value_kind(t) {
    case .Enum,.Bit_Set: return s.choices[t.first:][:t.count]
    }
    return nil
}

leaf_find :: proc(leaves:[]Leaf,path:string) -> int {
    for leaf,i in leaves {
        if leaf.path==path {return i}
    }
    return -1
}

// ---------------------------------------------------------------- references and assets

table_rows :: proc(c:^Context,t:^Rows) -> (ids:[]u64,names:[]asset.Records_Name) {
    if c.edit!=nil && t.id==c.edit.id {return c.edit.ids[:],c.edit.names[:]}
    return t.ids,t.names
}

path_bare :: proc(path:string) -> string {return strings.trim_suffix(path,".records")}

// The row a text names among the tables of a record type: "name" when one
// of them has it, "table/name" with the path of the table, with or without
// .records, or the serial form {"table":...,"row":...}.
ref_parse :: proc(c:^Context,record:string,text:string) -> (ref:Ref,message:string) {
    text:=strings.trim_space(text)
    type_name:=record
    if strings.has_prefix(text,"{") {
        given:struct {table:string,row:u64}
        if serial.text_decode(text,&given,context.temp_allocator)!="" {return {},fmt.tprintf("%q is not a reference: give the name of a row of %s",text,type_name)}
        id,valid:=serial.text_parse_asset_id(given.table)
        if !valid || given.row==0 {return {},fmt.tprintf("%q is not a reference: %s, or the name of a row of %s",text,`{"table":"<32 hex digits>","row":<id>}`,type_name)}
        return {id,core.Record_Id(given.row)},""
    }
    tables:=make([dynamic]string,context.temp_allocator)
    for &t in c.tables {
        if t.record==record {append(&tables,path_bare(t.path))}
    }
    if len(tables)==0 {return {},fmt.tprintf("%s has no tables to name a row of: records.create makes one",type_name)}
    if slash:=strings.last_index_byte(text,'/');slash>=0 {
        table,name:=text[:slash],text[slash+1:]
        for &t in c.tables {
            if t.record!=record || path_bare(t.path)!=path_bare(table) {continue}
            ids,names:=table_rows(c,&t)
            for &n,i in names {
                if serial.text_field(n[:])==name {return {t.id,core.Record_Id(ids[i])},""}
            }
            return {},fmt.tprintf("%s has no row %s: records.inspect of %s lists its rows",t.path,name,t.path)
        }
        return {},fmt.tprintf("%s is not a table of %s: they are %s",table,type_name,strings.join(tables[:],", ",context.temp_allocator))
    }
    found:Ref
    holders:=make([dynamic]string,context.temp_allocator)
    for &t in c.tables {
        if t.record!=record {continue}
        ids,names:=table_rows(c,&t)
        for &n,i in names {
            if serial.text_field(n[:])!=text {continue}
            found={t.id,core.Record_Id(ids[i])}
            append(&holders,path_bare(t.path))
            break
        }
    }
    switch len(holders) {
    case 1: return found,""
    case 0: return {},fmt.tprintf("no table of %s has a row %q: records.inspect of %s lists their rows",type_name,text,strings.join(tables[:],", ",context.temp_allocator))
    }
    return {},fmt.tprintf("%s is a row of %d tables of %s: write its table too, as %s/%s",text,len(holders),type_name,holders[0],text)
}

// A reference as ref_parse reads it: the name of the row, with
// its table when another table of the type has a row of that name.
ref_text :: proc(c:^Context,record:string,ref:Ref) -> string {
    if ref=={} {return ""}
    for &t in c.tables {
        if t.record!=record || t.id!=ref.table {continue}
        ids,names:=table_rows(c,&t)
        for id,i in ids {
            if id!=u64(ref.row) {continue}
            name:=serial.text_field(names[i][:])
            holders:=0
            for &other in c.tables {
                if other.record!=record {continue}
                _,other_names:=table_rows(c,&other)
                for &n in other_names {
                    if serial.text_field(n[:])==name {holders+=1;break}
                }
            }
            return holders==1 ? name : fmt.tprintf("%s/%s",path_bare(t.path),name)
        }
    }
    out:serial.Writer
    serial.writer_init(&out,64,context.temp_allocator)
    ref_write(&out,ref)
    return string(serial.writer_bytes(&out))
}

ref_write :: proc(out:^serial.Writer,ref:Ref) {
    serial.text_write_raw(out,`{"table":"`)
    serial.text_write_asset_id(out,ref.table)
    serial.text_write_raw(out,`","row":`)
    serial.text_write_uint(out,u64(ref.row))
    serial.write_u8(out,'}')
}

asset_parse :: proc(c:^Context,text:string) -> (id:base.Asset_Id,message:string) {
    text:=strings.trim_space(text)
    if parsed,is_id:=serial.text_parse_asset_id(text);is_id {return parsed,""}
    if c.registry!=nil {
        if file,found:=asset.registry_find_path(c.registry,text);found {return file.id,""}
    }
    return {},fmt.tprintf("%q is not an asset: give its path under the assets folder, as asset.list lists it, or its id",text)
}

asset_text :: proc(c:^Context,id:base.Asset_Id) -> string {
    if id=={} {return ""}
    if c.registry!=nil {
        if file,found:=asset.registry_find(c.registry,id);found {return file.path}
    }
    return fmt.tprintf("%016x%016x",id[0],id[1])
}

// ---------------------------------------------------------------- cells

bool_parse :: proc(text:string) -> (value,ok:bool) {
    switch {
    case strings.equal_fold(text,"true"):  return true,true
    case strings.equal_fold(text,"false"): return false,true
    }
    return
}

// Puts the text of a cell into the value at a leaf of a row.
cell_read :: proc(c:^Context,leaf:^Leaf,row:[]u8,cell:string) -> (message:string) {
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
        ref:Ref
        if ref,message=ref_parse(c,leaf.record,cell);message!="" {return}
        copy(row[leaf.offset:][:size_of(Ref)],mem.ptr_to_bytes(&ref))
        return ""
    case .Member:
        flag,ok:=bool_parse(strings.trim_space(cell))
        if !ok {return fmt.tprintf("%q is not true or false",cell)}
        return path_error(c,leaf,cell,serial.value_set(s,c.type,row,leaf.path,flag))
    case .Value:
    }
    text:=strings.trim_space(cell)
    value:serial.Value
    #partial switch value_kind(t) {
    case .Bool:
        flag,ok:=bool_parse(text)
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
        if id,message=asset_parse(c,text);message!="" {return}
        value=id
    case:
        return "it is not one value"
    }
    return path_error(c,leaf,cell,serial.value_set(s,c.type,row,leaf.path,value))
}

@(private)
path_error :: proc(c:^Context,leaf:^Leaf,cell:string,error:serial.Path_Error) -> string {
    #partial switch error {
    case .None: return ""
    case .Out_Of_Range: return fmt.tprintf("%q is out of the range of the field",cell)
    case .Too_Long: return fmt.tprintf("%q is longer than the field",cell)
    case .Unknown_Member:
        names:=make([dynamic]string,context.temp_allocator)
        for choice in choices(c.schema,leaf.type) {append(&names,choice.name)}
        return fmt.tprintf("%q is not one of %s",cell,strings.join(names[:],", ",context.temp_allocator))
    }
    return fmt.tprintf("%q does not fit the field: %v",cell,error)
}

// The text of the value at a leaf of a row, as cell_read reads it.
cell_text :: proc(c:^Context,leaf:^Leaf,row:[]u8) -> string {
    s:=c.schema
    t:=s.types[leaf.type]
    switch leaf.kind {
    case .Bytes: return serial.text_field(row[leaf.offset:][:t.size])
    case .Ref:
        ref:Ref
        copy(mem.ptr_to_bytes(&ref),row[leaf.offset:][:size_of(Ref)])
        return ref_text(c,leaf.record,ref)
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
    case base.Asset_Id:  return asset_text(c,v)
    }
    return ""
}

// ---------------------------------------------------------------- CSV

// The columns the first row of a CSV names; message says which one is wrong
// and which there are.
csv_header :: proc(c:^Context,leaves:[]Leaf,header:[]string) -> (columns:[]Csv_Column,message:string) {
    out:=make([]Csv_Column,len(header),context.temp_allocator)
    named:=false
    for cell,i in header {
        title:=strings.trim_space(cell)
        column:=Csv_Column{title=title,leaf=-1}
        if title=="name" {
            if named {return nil,"two columns are name: keep one"}
            named=true
        } else {
            column.leaf=leaf_find(leaves,title)
            if column.leaf<0 {return nil,fmt.tprintf("column %d %q is not a field of %s; the columns are %s",i+1,title,c.name,columns_text(leaves))}
            for earlier,j in out[:i] {
                if earlier.leaf==column.leaf {return nil,fmt.tprintf("columns %d and %d are both %s: keep one",j+1,i+1,title)}
            }
        }
        out[i]=column
    }
    if !named {return nil,fmt.tprintf("the first row names the columns and none is name: write name and the fields of %s, as %s",c.name,columns_text(leaves))}
    return out,""
}

// The columns there are, for a message.
columns_text :: proc(leaves:[]Leaf) -> string {
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"name")
    for leaf in leaves {
        fmt.sbprintf(&b,", %s",leaf.path)
    }
    return strings.to_string(b)
}

// Puts the cells of a record of a CSV into a row; an empty cell leaves its value.
row_cells :: proc(c:^Context,leaves:[]Leaf,columns:[]Csv_Column,record:[]string,row:[]u8) -> (message:string) {
    for column,i in columns {
        if column.leaf<0 || i>=len(record) || record[i]=="" {continue}
        leaf:=&leaves[column.leaf]
        if message=cell_read(c,leaf,row,record[i]);message!="" {return fmt.tprintf("column %s: %s",column.title,message)}
    }
    return ""
}

// The CSV of every row of c.edit that the records.import method of the editor reads: name
// and every value.
csv_text :: proc(c:^Context,leaves:[]Leaf) -> (text:string,columns:int) {
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
    for row in 0..<row_count(e) {
        bytes:=row_bytes(e,row)
        importer.csv_cell(&b,row_name(e,row))
        for &leaf in leaves {
            strings.write_byte(&b,',')
            importer.csv_cell(&b,cell_text(c,&leaf,bytes))
        }
        strings.write_byte(&b,'\n')
    }
    return strings.to_string(b),columns
}

// ---------------------------------------------------------------- values by JSON

json_error :: proc(r:^serial.Text_Reader,what:string) -> string {
    offset:=r.error.offset if r.error.code!=.None else r.offset
    line,column:=serial.text_position(r.text,offset)
    return fmt.tprintf("%s is not valid JSON at line %d, column %d",what,line,column)
}

// Copies the JSON of a value of type into out, with the core.Record fields
// given as a string turned into their serial form.
rewrite :: proc(c:^Context,r:^serial.Text_Reader,type:serial.Type_Index,path:string,out:^serial.Writer) -> (message:string) {
    s:=c.schema
    peek:=serial.text_peek(r)
    if peek=='"' && serial.type_valid(s,type) {
        if record:=ref_record(c,type);record!="" {
            text,read:=serial.text_string(r)
            if !read {return json_error(r,"values")}
            ref,problem:=ref_parse(c,record,text)
            if problem!="" {return fmt.tprintf("values.%s: %s",path,problem)}
            ref_write(out,ref)
            return ""
        }
    }
    kind:=serial.type_valid(s,type) ? value_kind(s.types[type]) : serial.Type_Kind.Bool
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
            if !read || !serial.text_expect(r,':') {return json_error(r,"values")}
            key=strings.clone(key,context.temp_allocator)
            serial.text_write_string(out,key)
            serial.write_u8(out,':')
            field:^serial.Field
            for &each in serial.schema_fields(s,type) {
                if each.name==key {field=&each;break}
            }
            if field==nil {
                if message=json_copy(r,out);message!="" {return}
            } else {
                if message=rewrite(c,r,field.type,path=="" ? key : fmt.tprintf("%s.%s",path,key),out);message!="" {return}
            }
            if serial.text_accept(r,',') {
                serial.write_u8(out,',')
                continue
            }
            if !serial.text_expect(r,'}') {return json_error(r,"values")}
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
            if message=rewrite(c,r,s.types[type].elem,fmt.tprintf("%s[%d]",path,i),out);message!="" {return}
            if serial.text_accept(r,',') {
                serial.write_u8(out,',')
                continue
            }
            if !serial.text_expect(r,']') {return json_error(r,"values")}
            serial.write_u8(out,']')
            return ""
        }
    }
    return json_copy(r,out)
}

@(private)
json_copy :: proc(r:^serial.Text_Reader,out:^serial.Writer) -> (message:string) {
    serial.text_space(r)
    start:=r.offset
    if !serial.text_skip(r) {return json_error(r,"values")}
    serial.text_write_raw(out,r.text[start:r.offset])
    return ""
}

// Puts the values of the params over a row. Each key is a field of the row or
// the path of a part of one (stats.speed, windows[2].to), and its value is
// that part whole: an object or a list leaves what it does not give at the
// default of the row type (zeros where the type has none), while the fields
// and parts no key names keep what they have. core.Record fields may be named
// by their rows.
values_put :: proc(c:^Context,row:[]u8,values:string) -> (message:string) {
    if values=="" {return ""}
    r:serial.Text_Reader
    serial.text_reader_init(&r,values,context.temp_allocator)
    if !serial.text_accept(&r,'{') {return "values must be an object of fields of the row"}
    if !serial.text_accept(&r,'}') {
        for {
            key,read:=serial.text_string(&r)
            if !read || !serial.text_expect(&r,':') {return json_error(&r,"values")}
            key=strings.clone(key,context.temp_allocator)
            if message=value_put(c,&r,row,key);message!="" {return}
            if serial.text_accept(&r,',') {continue}
            if !serial.text_expect(&r,'}') {return json_error(&r,"values")}
            break
        }
    }
    if !serial.text_end(&r) {return json_error(&r,"values")}
    return ""
}

// The value of one key of values, read from r into the part of row that key
// names.
@(private)
value_put :: proc(c:^Context,r:^serial.Text_Reader,row:[]u8,key:string) -> (message:string) {
    s:=c.schema
    target,error,at:=serial.path_resolve(s,c.type,key)
    if error==.None && target.bit>=0 {error=.Not_A_Struct}
    if error!=.None {
        parent:=strings.trim_right(key[:at],".")
        fields:=make([dynamic]string,context.temp_allocator)
        if within,_,_:=serial.path_resolve(s,c.type,parent);serial.type_valid(s,within.type) && value_kind(s.types[within.type])==.Struct {
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
    if message=rewrite(c,r,target.type,key,&out);message!="" {return}
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

