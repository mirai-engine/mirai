package author

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "mirai:asset"
import "mirai:cook/records"
import "mirai:std/serial"

// mirai records: the tables of game data (.records) of a project read,
// written, made and checked with no editor, through the code the records.*
// methods of the editor use (cook/records), against the types of the game as
// it was built last.
//
//   create <table> [<document>]  makes a table: the document is what
//                                records.create takes (type, description,
//                                columns, rows_of); without one, a table that
//                                declares a type named from its file
//   read <table> [--out <file>]  the table as records.inspect gives it
//   write <table> <document>     makes the table hold the rows of the
//                                document ({"rows":[{"name":...,"values":{...}}]},
//                                what read gives): rows by name, in order
//   check [<table>...]           what the tables, all without one, would fail
//                                with in the game

// What mirai records write takes, and read gives.
Records_Document :: struct {
    records:string, // the id of the table
    path:string,
    type:string,
    rows:[]Records_Document_Row,
}

Records_Document_Row :: struct {
    id:u64,
    name:string,
    values:serial.Json,
}

// What mirai records create takes: the params of records.create.
Records_Create :: struct {
    type:string,
    description:string,
    columns:[]records.Column_Params,
    rows_of:string,
}

@(private)
records_command :: proc(p:^Project,args:[]string,output,errors:io.Writer) -> int {
    if len(args)==0 {fmt.wprintln(errors,COMMAND_USAGE);return 2}
    verb:=args[0]
    problem:string
    switch verb {
    case "read":
        out:=""
        named:=""
        for at:=1;at<len(args);at+=1 {
            if args[at]=="--out" && at+1<len(args) {out=args[at+1];at+=1;continue}
            named=args[at]
        }
        if named=="" {fmt.wprintln(errors,COMMAND_USAGE);return 2}
        text:string
        if text,problem=table_read(p,named);problem=="" {
            if out=="" {fmt.wprintln(output,text)}
            else if serial.file_write_atomic(out,transmute([]u8)text)!=.None {problem=fmt.tprintf("%s could not be written",out)}
        }
    case "write":
        if len(args)!=3 {fmt.wprintln(errors,COMMAND_USAGE);return 2}
        document,read:=os.read_entire_file(args[2],context.temp_allocator)
        if read!=nil {problem=fmt.tprintf("%s could not be read",args[2])} else {
            written:Written
            if written,problem=table_write(p,args[1],string(document));problem=="" {fmt.wprintfln(output,"%s %s",written.path,written.same?"unchanged":"written")}
        }
    case "create":
        if len(args)<2 || len(args)>3 {fmt.wprintln(errors,COMMAND_USAGE);return 2}
        document:=""
        if len(args)==3 {
            bytes,read:=os.read_entire_file(args[2],context.temp_allocator)
            if read!=nil {problem=fmt.tprintf("%s could not be read",args[2])}
            document=string(bytes)
        }
        if problem=="" {
            written:Written
            if written,problem=table_create(p,args[1],document);problem=="" {fmt.wprintfln(output,"%s written",written.path)}
        }
    case "check":
        failed:=0
        for line in table_check(p,args[1:]) {
            fmt.wprintln(errors,line)
            failed+=1
        }
        return 1 if failed>0 else 0
    case:
        fmt.wprintfln(errors,"mirai records: there is no '%s'; it has create, read, write and check\n%s",verb,COMMAND_USAGE)
        return 2
    }
    if problem!="" {
        fmt.wprintfln(errors,"mirai records %s: %s",verb,problem)
        return 1
    }
    return 0
}

// The path under the assets of the table a name gives: with or without
// assets/ and .records, or its id. exists: a file has it.
@(private="file")
table_named :: proc(p:^Project,named:string) -> (path:string,exists:bool,problem:string) {
    path=asset_path(named)
    if !strings.has_suffix(path,".records") {
        if id,is_id:=serial.text_parse_asset_id(path);is_id {
            file,found:=asset.registry_find(&p.registry,id)
            if !found || file.kind!=asset.KIND_RECORDS {return "",false,fmt.tprintf("%s is no .records of the project",named)}
            return strings.clone(file.path,context.temp_allocator),true,""
        }
        path=fmt.tprintf("%s.records",path)
    }
    _,exists=asset.registry_find_path(&p.registry,path)
    return
}

@(private="file")
table_open :: proc(p:^Project,named:string,e:^records.Edit) -> (path,problem:string) {
    exists:bool
    if path,exists,problem=table_named(p,named);problem!="" {return}
    if !exists {return "",fmt.tprintf("%s is no table of the project: mirai records create makes one",path)}
    file,_:=asset.registry_find_path(&p.registry,path)
    problem=records.load(&p.registry,&p.types,p.info,file.id,e,context.temp_allocator)
    return
}

// The table as JSON on one line: its id, path, type and rows with their ids,
// names and values, as records.inspect gives them.
table_read :: proc(p:^Project,named:string) -> (text,problem:string) {
    e:records.Edit
    path:string
    if path,problem=table_open(p,named,&e);problem!="" {return}
    defer records.destroy(&e)
    document:=Records_Document{records=fmt.tprintf("%016x%016x",e.id[0],e.id[1]),path=path,type=records.type_name(&e)}
    rows:=make([]Records_Document_Row,records.row_count(&e),context.temp_allocator)
    for &row,i in rows {row={e.ids[i],records.row_name(&e,i),serial.Json(records.row_text(&e,i))}}
    document.rows=rows
    encoded,ok:=serial.text_encode(document,.Line,context.temp_allocator)
    if !ok {return "","out of memory"}
    return string(encoded),""
}

// Makes a table hold the rows of a document, as a content tool writes them
// (records.rows_replace); a file that already holds them is left as it is.
table_write :: proc(p:^Project,named,document:string) -> (written:Written,problem:string) {
    given:Records_Document
    if failed:=serial.text_decode(document,&given,context.temp_allocator,skip_unknown=true);failed!="" {return {},fmt.tprintf("the document is not {\"rows\":[{\"name\":...,\"values\":{...}}]}: %s",failed)}
    e:records.Edit
    path:string
    if path,problem=table_open(p,named,&e);problem!="" {return}
    defer records.destroy(&e)
    names:=make([]string,len(given.rows),context.temp_allocator)
    values:=make([]string,len(given.rows),context.temp_allocator)
    for row,i in given.rows {names[i],values[i]=row.name,string(row.values)}
    c,_:=records.context_make(&e,p.info,&p.registry,&p.types,records.tables_scan(&p.registry,&p.types))
    if problem=records.rows_replace(&e,&c,names,values);problem!="" {return}
    return table_put(p,&e,path)
}

// Makes a table: one that declares a type with the columns of the document
// (the params of records.create), or holds rows of a type another declares.
table_create :: proc(p:^Project,named,document:string) -> (written:Written,problem:string) {
    path,exists,unknown:=table_named(p,named)
    if unknown!="" {return {},unknown}
    if exists {return {},fmt.tprintf("%s already exists: mirai records write changes its rows",path)}
    given:Records_Create
    if document!="" {
        if failed:=serial.text_decode(document,&given,context.temp_allocator);failed!="" {return {},fmt.tprintf("the document is not the params of records.create: %s",failed)}
    }
    file:=fmt.tprintf("%s/%s",p.assets_root,path)
    id:=asset.content_id(p.name,"records",path)
    e:records.Edit
    defer records.destroy(&e)
    if given.rows_of!="" {
        if given.type!="" || len(given.columns)>0 {return {},"rows_of makes a table of rows of a type another declares, which has no type or columns of its own: give rows_of alone, or type and columns"}
        if problem=records.rows_of_make(&p.registry,&p.types,p.info,given.rows_of,id,file,path,&e,context.temp_allocator);problem!="" {return}
        return table_put(p,&e,path)
    }
    type:=given.type if given.type!="" else records.type_of_file(path)
    if other,_:=records.declaring_find(&p.registry,&p.types,type);other!={} {return {},fmt.tprintf("a table already declares %s: give another type, or rows_of %s to hold rows of it",type,type)}
    if problem=records.create(id,file,records.folder_of(path),type,&e,context.temp_allocator);problem!="" {return {},fmt.tprintf("type: %s",problem)}
    records.description_set(&e,given.description)
    files:=records.tables_scan(&p.registry,&p.types)
    for &column,i in given.columns {
        if column.name=="" || column.kind=="" {return {},fmt.tprintf("columns[%d]: a column needs a name and a kind",i)}
        c:asset.Records_Column
        message:=records.column_put(&c,&e,&column,nil,true)
        if message=="" {message=records.column_add(&e,p.info,c)}
        if message=="" {message=records.column_default(&e,p.info,&p.registry,&p.types,files,column.name,column.default,false)}
        if message!="" {return {},fmt.tprintf("columns[%d] (%s): %s",i,column.name,message)}
    }
    return table_put(p,&e,path)
}

@(private="file")
table_put :: proc(p:^Project,e:^records.Edit,path:string) -> (written:Written,problem:string) {
    bytes:[]u8
    if bytes,problem=records.file_bytes(e,&p.types);problem!="" {return}
    written.path=path
    problem=file_put(p,e.file,path,bytes,&written)
    return
}

// What the tables named, all without one, would fail with in the game: each
// as "<path>: <problem>".
table_check :: proc(p:^Project,named:[]string) -> []string {
    out:=make([dynamic]string,context.temp_allocator)
    paths:=make([dynamic]string,context.temp_allocator)
    if len(named)==0 {
        for &f in p.registry.files {
            if f.kind==asset.KIND_RECORDS && f.id!={} {append(&paths,f.path)}
        }
    }
    for name in named {
        path,exists,problem:=table_named(p,name)
        if problem!="" {append(&out,fmt.tprintf("%s: %s",name,problem));continue}
        if !exists {append(&out,fmt.tprintf("%s: no table of the project",path));continue}
        append(&paths,path)
    }
    for path in paths {
        e:records.Edit
        file,_:=asset.registry_find_path(&p.registry,path)
        if problem:=records.load(&p.registry,&p.types,p.info,file.id,&e,context.temp_allocator);problem!="" {
            append(&out,fmt.tprintf("%s: %s",path,problem))
            continue
        }
        if _,problem:=records.file_bytes(&e,&p.types);problem!="" {append(&out,fmt.tprintf("%s: %s",path,problem))}
        if p.info!=nil {
            built:=false
            for &r in p.info.records {built||=r.name==records.type_name(&e)}
            if !built {append(&out,fmt.tprintf("%s: the game library has no type %s: mirai build editor builds it",path,records.type_name(&e)))}
        }
        records.destroy(&e)
    }
    return out[:]
}
