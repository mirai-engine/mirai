package asset

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"

// An asset in memory, to build, read and edit: the tables of record.odin with
// everything they hold owned by the document. Writing one is a function of
// its content alone, so reading a file and writing it again gives the same
// bytes. Dependencies are not stored in the document: they are the asset ids
// its values hold, collected when it is written.

Doc_Column :: struct {
    name:string,
    type:serial.Type_Index,
    size:int, // of one row
    flags:serial.Field_Flags,
    ref:int,  // the table whose rows its values index, or -1
    alignment:int,
    compression:Compression,
    data:[]u8,    // rows*size, aligned to alignment and to 16
    capacity:int, // bytes reserved behind data
}

// Sets the size of the data of a column. Bytes past the old size are zero.
@(private)
column_size :: proc(doc:^Document,column:^Doc_Column,size:int) -> Error {
    if size>column.capacity {
        capacity:=max(size,column.capacity*2,64)
        block,error:=mem.alloc_bytes_non_zeroed(capacity,max(column.alignment,16),doc.allocator)
        if error!=nil {return .Out_Of_Memory}
        copy(block,column.data)
        mem.free_bytes(raw_data(column.data)[:column.capacity],doc.allocator)
        column.data,column.capacity=block[:len(column.data)],capacity
    }
    old:=len(column.data)
    column.data=raw_data(column.data)[:size]
    if size>old {mem.zero_slice(column.data[old:])}
    return .None
}

Doc_Table :: struct {
    name:string,
    name_hash:u64,
    flags:Table_Flags,
    rows:int,
    key:int, // column, or -1
    columns:[dynamic]Doc_Column,
}

Document :: struct {
    kind:Fourcc,
    kind_version:u16,
    id:base.Asset_Id,
    owner:base.Asset_Id, // the asset it is a part of (Header.owner)
    flags:Header_Flags,
    schema:serial.Schema,
    hashes:[dynamic]u64,
    tables:[dynamic]Doc_Table,
    allocator:runtime.Allocator,
}

document_init :: proc(doc:^Document,kind:Fourcc,id:base.Asset_Id,allocator:=context.allocator) {
    doc^={kind=kind,id=id,allocator=allocator}
    serial.schema_init(&doc.schema,allocator)
    doc.hashes=make([dynamic]u64,allocator)
    doc.tables=make([dynamic]Doc_Table,allocator)
}

document_destroy :: proc(doc:^Document) {
    if doc.allocator.procedure==nil {return}
    for &table in doc.tables {table_destroy(doc,&table)}
    delete(doc.tables);delete(doc.hashes)
    if doc.schema.allocator.procedure!=nil {serial.schema_destroy(&doc.schema)}
    doc^={}
}

@(private)
table_destroy :: proc(doc:^Document,table:^Doc_Table) {
    for column in table.columns {
        delete(column.name,doc.allocator)
        mem.free_bytes(raw_data(column.data)[:column.capacity],doc.allocator)
    }
    delete(table.columns)
    delete(table.name,doc.allocator)
}

// Starts copying types of another schema into the one of the document.
document_import_begin :: proc(doc:^Document,link:^serial.Schema_Import,source:^serial.Schema) {
    serial.schema_import_init(link,&doc.schema,&doc.hashes,source,doc.allocator)
}
document_import :: proc(doc:^Document,link:^serial.Schema_Import,type:serial.Type_Index) -> serial.Type_Index {
    link.dst,link.dst_hashes=&doc.schema,&doc.hashes
    return serial.schema_import(link,type)
}
// The type of the document that describes T.
document_type :: proc(doc:^Document,types:^Types,$T:typeid) -> (type:serial.Type_Index,ok:bool) {
    index:=types_index(types,T) or_return
    link:serial.Schema_Import
    document_import_begin(doc,&link,&types.schema)
    defer serial.schema_import_destroy(&link)
    type=document_import(doc,&link,index)
    return type,type!=serial.TYPE_NONE
}

document_table :: proc(doc:^Document,name:string) -> (table:int,found:bool) {
    hash:=base.name_hash(name)
    for candidate,at in doc.tables {
        if candidate.name_hash==hash && candidate.name==name {return at,true}
    }
    return -1,false
}
document_column :: proc(doc:^Document,table:int,name:string) -> (column:int,found:bool) {
    for candidate,at in doc.tables[table].columns {
        if candidate.name==name {return at,true}
    }
    return -1,false
}

document_table_add :: proc(doc:^Document,name:string,flags:=Table_Flags{}) -> (table:int,error:Error) {
    if !name_valid(name) || len(doc.tables)>=MAX_TABLES {return -1,.Invalid}
    if _,exists:=document_table(doc,name);exists {return -1,.Invalid}
    copied,no_name:=strings.clone(name,doc.allocator)
    if no_name!=nil {return -1,.Out_Of_Memory}
    added:=Doc_Table{name=copied,name_hash=base.name_hash(name),flags=flags,key=-1}
    added.rows=.Single in flags?1:0
    added.columns=make([dynamic]Doc_Column,doc.allocator)
    if append(&doc.tables,added)!=1 {delete(added.name,doc.allocator);delete(added.columns);return -1,.Out_Of_Memory}
    return len(doc.tables)-1,.None
}

// Removes a table. Columns of other tables that indexed its rows index nothing.
document_table_remove :: proc(doc:^Document,table:int) {
    table_destroy(doc,&doc.tables[table])
    ordered_remove(&doc.tables,table)
    for &other in doc.tables {
        for &column in other.columns {
            if column.ref==table {column.ref=-1}
            else if column.ref>table {column.ref-=1}
        }
    }
}

// Adds a column of a type of the schema of the document, with every row zero.
// alignment 0 is the one of the type.
document_column_add :: proc(doc:^Document,table:int,name:string,type:serial.Type_Index,flags:=serial.Field_Flags{},compression:=Compression.None,alignment:=0) -> (column:int,error:Error) {
    target:=&doc.tables[table]
    if int(type)>=len(doc.schema.types) || len(target.columns)>=MAX_COLUMNS {return -1,.Invalid}
    if name=="" ? len(target.columns)!=0 : !name_valid(name) {return -1,.Invalid}
    if len(target.columns)==1 && target.columns[0].name=="" {return -1,.Invalid}
    if _,exists:=document_column(doc,table,name);exists {return -1,.Invalid}
    stored:=doc.schema.types[type]
    wanted:=max(alignment,int(stored.align),1)
    if wanted&(wanted-1)!=0 || wanted>1<<MAX_ALIGNMENT_LOG2 {return -1,.Invalid}
    copied,no_name:=strings.clone(name,doc.allocator)
    if no_name!=nil {return -1,.Out_Of_Memory}
    added:=Doc_Column{name=copied,type=type,size=int(stored.size),flags=flags,ref=-1,alignment=wanted,compression=compression}
    if error=column_size(doc,&added,target.rows*added.size);error!=.None {
        delete(added.name,doc.allocator)
        return -1,error
    }
    if append(&target.columns,added)!=1 {delete(added.name,doc.allocator);mem.free_bytes(raw_data(added.data)[:added.capacity],doc.allocator);return -1,.Out_Of_Memory}
    return len(target.columns)-1,.None
}

// Changes the number of rows. New rows are zero.
document_resize :: proc(doc:^Document,table:int,rows:int) -> Error {
    target:=&doc.tables[table]
    if rows<0 || rows>MAX_ROWS || .Single in target.flags && rows!=1 {return .Invalid}
    for &column,at in target.columns {
        if error:=column_size(doc,&column,rows*column.size);error!=.None {
            // The columns that grew go back to the rows the table has: no memory is asked for that.
            for &grown in target.columns[:at] {_=column_size(doc,&grown,target.rows*grown.size)}
            return error
        }
    }
    target.rows=rows
    return .None
}

// Opens count zero rows before row `at`.
document_rows_insert :: proc(doc:^Document,table:int,at:int,count:int) -> Error {
    target:=&doc.tables[table]
    rows:=target.rows
    if at<0 || at>rows || count<0 {return .Invalid}
    document_resize(doc,table,rows+count) or_return
    for &column in target.columns {
        size:=column.size
        if size==0 {continue}
        copy(column.data[(at+count)*size:],column.data[at*size:rows*size])
        mem.zero_slice(column.data[at*size:][:count*size])
    }
    return .None
}

document_rows_remove :: proc(doc:^Document,table:int,at:int,count:int) -> Error {
    target:=&doc.tables[table]
    if at<0 || count<0 || at+count>target.rows || .Single in target.flags && count>0 {return .Invalid}
    for &column in target.columns {
        size:=column.size
        copy(column.data[at*size:],column.data[(at+count)*size:])
        column_size(doc,&column,(target.rows-count)*size)
    }
    target.rows-=count
    return .None
}

// The bytes of one row of a column.
document_cell :: #force_inline proc(doc:^Document,table,column,row:int) -> []u8 {
    target:=&doc.tables[table].columns[column]
    return target.data[row*target.size:][:target.size]
}

// A table of one column without name: the images of values, one per row.
document_put :: proc(doc:^Document,types:^Types,name:string,values:[]$T,flags:=Table_Flags{},compression:=Compression.None,alignment:=0) -> (table:int,error:Error) {
    table=document_table_add(doc,name,flags) or_return
    error=document_resize(doc,table,len(values))
    if error==.None {_,error=document_column_put(doc,types,table,"",values,{},compression,alignment)}
    if error!=.None {
        document_table_remove(doc,table)
        return -1,error
    }
    return table,.None
}
// A table of one row.
document_put_row :: proc(doc:^Document,types:^Types,name:string,value:^$T,flags:=Table_Flags{}) -> (table:int,error:Error) {
    return document_put(doc,types,name,([^]T)(value)[:1],flags+{.Single})
}
// Adds a column with one value per row of its table.
document_column_put :: proc(doc:^Document,types:^Types,table:int,name:string,values:[]$T,flags:=serial.Field_Flags{},compression:=Compression.None,alignment:=0) -> (column:int,error:Error) {
    if len(values)!=doc.tables[table].rows {return -1,.Invalid}
    index,known:=types_index(types,T)
    if !known {return -1,types.error}
    type,imported:=document_type(doc,types,T)
    layout:=types_layout(types,index)
    if !imported || layout==nil {return -1,.Out_Of_Memory}
    column=document_column_add(doc,table,name,type,flags,compression,alignment) or_return
    serial.value_write(layout,doc.tables[table].columns[column].data,raw_data(values),len(values))
    return column,.None
}

// Every asset the values of the document refer to: sorted, once each.
document_dependencies :: proc(doc:^Document,out:^[dynamic]base.Asset_Id) -> Error {
    clear(out)
    refs:=make([dynamic]serial.Ref,doc.allocator)
    defer delete(refs)
    for table in doc.tables {
        for column in table.columns {
            clear(&refs)
            if !serial.refs_collect(&doc.schema,column.type,&refs,MAX_REFS) {return .Invalid}
            if len(refs)==0 {continue}
            for row in 0..<table.rows {
                for ref in refs {
                    if ref.kind!=.Asset {continue}
                    id:=intrinsics.unaligned_load((^base.Asset_Id)(&column.data[row*column.size+int(ref.offset)]))
                    if id!={} {append(out,id)}
                }
            }
        }
    }
    slice.sort_by(out[:],proc(a,b:base.Asset_Id) -> bool {return a[0]<b[0] || a[0]==b[0] && a[1]<b[1]})
    unique:=0
    for id,at in out {
        if at>0 && id==out[unique-1] {continue}
        out[unique]=id
        unique+=1
    }
    base.truncate(out,unique)
    return .None
}

// The most references one row of a column may hold.
MAX_REFS :: 1<<16

// What a file cannot hold, before anything is written.
document_check :: proc(doc:^Document) -> Error {
    if len(doc.tables)>MAX_TABLES {return .Invalid}
    for table in doc.tables {
        if !name_valid(table.name) || table.rows<0 || table.rows>MAX_ROWS || len(table.columns)>MAX_COLUMNS {return .Invalid}
        if .Single in table.flags && table.rows!=1 {return .Invalid}
        if table.key>=len(table.columns) || !rows_backed(table.rows,table.columns[:]) {return .Invalid}
        for column in table.columns {
            if int(column.type)>=len(doc.schema.types) || column.ref>=len(doc.tables) {return .Invalid}
            stored:=doc.schema.types[column.type]
            if column.size!=int(stored.size) || len(column.data)!=table.rows*column.size {return .Invalid}
            if column.name=="" ? len(table.columns)!=1 : !name_valid(column.name) {return .Invalid}
            if column.ref>=0 && (stored.kind!=.Uint || stored.size>8) {return .Invalid}
            if column.alignment<=0 || column.alignment&(column.alignment-1)!=0 || column.alignment>1<<MAX_ALIGNMENT_LOG2 {return .Invalid}
        }
    }
    return .None
}

// Renames a choice of the types that move by name, as a renamed input action
// (serial.schema_choice_rename): the values stay, and read by the new name.
// How many types it renamed it in.
document_choice_rename :: proc(doc:^Document,old,name:string) -> int {
    renamed:=serial.schema_choice_rename(&doc.schema,old,name)
    if renamed>0 {
        clear(&doc.hashes)
        serial.schema_hashes_update(&doc.schema,&doc.hashes)
    }
    return renamed
}

// Writes the document as a file into w, which has to be empty, compressed as p says.
document_write :: proc(doc:^Document,w:^serial.Writer,p:=PACK_EDIT,worker:=jobs.Worker_Ref{}) -> Error {
    document_check(doc) or_return
    allocator:=doc.allocator
    dependencies:=make([dynamic]base.Asset_Id,allocator);defer delete(dependencies)
    document_dependencies(doc,&dependencies) or_return

    names,schema,directory:serial.Writer
    serial.writer_init(&names,allocator=allocator);defer serial.writer_destroy(&names)
    serial.writer_init(&schema,allocator=allocator);defer serial.writer_destroy(&schema)
    serial.writer_init(&directory,allocator=allocator);defer serial.writer_destroy(&directory)
    serial.schema_write(&schema,&doc.schema)

    // Each name once, in the order tables and columns first use it.
    Name :: struct {text:string,offset:int}
    interned:=make([dynamic]Name,allocator);defer delete(interned)
    name_write :: proc(directory,names:^serial.Writer,interned:^[dynamic]Name,text:string) {
        offset:=-1
        for name in interned {
            if name.text==text {offset=name.offset;break}
        }
        if offset<0 {
            offset=names.count
            serial.write_bytes(names,transmute([]u8)text)
            append(interned,Name{text,offset})
        }
        serial.write_varint(directory,u64(offset))
        serial.write_varint(directory,u64(len(text)))
    }

    chunks:=make([dynamic]Build_Chunk,allocator);defer delete(chunks)
    append(&chunks,Build_Chunk{tag=TAG_DEPS,alignment=align_of(base.Asset_Id),data=mem.slice_to_bytes(dependencies[:])})
    append(&chunks,Build_Chunk{tag=TAG_STRS,alignment=1})
    append(&chunks,Build_Chunk{tag=TAG_SCHM,alignment=1})
    append(&chunks,Build_Chunk{tag=TAG_TDIR,alignment=1})
    // Records first and bulk last: what describes the asset is at its start.
    columns:=0
    for table in doc.tables {columns+=len(table.columns)}
    if len(chunks)+columns>MAX_CHUNKS {return .Invalid}
    first_chunk,no_first:=make([]int,len(doc.tables),allocator);defer delete(first_chunk,allocator)
    if no_first!=nil {return .Out_Of_Memory}
    counts:[3]u16
    for bulk in ([]bool{false,true}) {
        for table,t in doc.tables {
            if (.Bulk in table.flags)!=bulk {continue}
            tag,counter:=TAG_RECS,0
            if .Import in table.flags {tag,counter=TAG_IMPT,2}
            else if bulk {tag,counter=TAG_BULK,1}
            first_chunk[t]=len(chunks)
            for column in table.columns {
                append(&chunks,Build_Chunk{tag=tag,index=counts[counter],alignment=column.alignment,compression=column.compression,data=column.data})
                counts[counter]+=1
            }
        }
    }
    serial.write_varint(&directory,u64(len(doc.tables)))
    for table,t in doc.tables {
        name_write(&directory,&names,&interned,table.name)
        serial.write_u8(&directory,transmute(u8)table.flags)
        serial.write_varint(&directory,u64(table.rows))
        serial.write_varint(&directory,u64(table.key+1))
        serial.write_varint(&directory,u64(len(table.columns)))
        for column,c in table.columns {
            name_write(&directory,&names,&interned,column.name)
            serial.write_varint(&directory,u64(column.type))
            serial.write_u8(&directory,transmute(u8)column.flags)
            serial.write_varint(&directory,u64(column.ref+1))
            serial.write_varint(&directory,u64(first_chunk[t]+c))
        }
    }
    chunks[1].data=serial.writer_bytes(&names)
    chunks[2].data=serial.writer_bytes(&schema)
    chunks[3].data=serial.writer_bytes(&directory)
    if names.overflow!=0 || schema.overflow!=0 || directory.overflow!=0 {return .Out_Of_Memory}
    scratch:=make([dynamic]u8,allocator);defer delete(scratch)
    flags:=doc.flags-{.One_Root}
    if doc.kind==KIND_SCENE && document_one_root(doc) {flags+={.One_Root}}
    return blob_build(w,doc.kind,doc.kind_version,doc.id,doc.owner,flags,chunks[:],&scratch,p,worker)
}

// Writes the document to a file, whole or not at all.
document_save :: proc(doc:^Document,path:string,sync:=false,p:=PACK_EDIT) -> Error {
    data:=document_bytes(doc,doc.allocator,p) or_return
    defer mem.free_bytes(data,doc.allocator)
    return serial.file_write_atomic(path,data,sync)==.None?.None:.IO
}

// The file the document is, as bytes from allocator, aligned for its chunks.
document_bytes :: proc(doc:^Document,allocator:=context.allocator,p:=PACK_EDIT,worker:=jobs.Worker_Ref{}) -> (data:[]u8,error:Error) {
    w:serial.Writer
    serial.writer_init(&w,allocator=allocator)
    if error=document_write(doc,&w,p,worker);error!=.None {
        serial.writer_destroy(&w)
        return
    }
    return serial.writer_take(&w),.None
}

// A copy of an open asset that owns everything it holds.
document_from_asset :: proc(doc:^Document,a:^Asset,allocator:=context.allocator) -> Error {
    doc^={kind=a.blob.header.kind,kind_version=a.blob.header.kind_version,id=a.blob.header.id,owner=a.blob.header.owner,flags=a.blob.header.flags,allocator=allocator}
    if serial.schema_clone(&doc.schema,&a.schema,allocator)!=.None {document_destroy(doc);return .Out_Of_Memory}
    doc.hashes=make([dynamic]u64,allocator)
    if !serial.schema_hashes_update(&doc.schema,&doc.hashes) {document_destroy(doc);return .Out_Of_Memory}
    no_tables:runtime.Allocator_Error
    if doc.tables,no_tables=make([dynamic]Doc_Table,0,len(a.tables),allocator);no_tables!=nil {document_destroy(doc);return .Out_Of_Memory}
    for &source in a.tables {
        table:=Doc_Table{name_hash=source.name_hash,flags=source.flags,rows=source.rows,key=source.key}
        no_name,no_columns:runtime.Allocator_Error
        table.name,no_name=strings.clone(source.name,allocator)
        table.columns,no_columns=make([dynamic]Doc_Column,0,len(source.columns),allocator)
        if _,no_table:=append(&doc.tables,table);no_table!=nil {
            delete(table.name,allocator);delete(table.columns)
            document_destroy(doc)
            return .Out_Of_Memory
        }
        if no_name!=nil || no_columns!=nil {document_destroy(doc);return .Out_Of_Memory}
        target:=&doc.tables[len(doc.tables)-1]
        for from,at in source.columns {
            entry:=blob_chunk(&a.blob,from.chunk)
            column:=Doc_Column{type=from.type,size=from.size,flags=from.flags,ref=from.ref,alignment=1<<entry.alignment_log2,compression=entry.compression}
            no_column_name:runtime.Allocator_Error
            column.name,no_column_name=strings.clone(from.name,allocator)
            error:=column_size(doc,&column,source.rows*from.size)
            append(&target.columns,column)
            if no_column_name!=nil {error=.Out_Of_Memory}
            decoder:^Decoder
            if error==.None && entry.compression!=.None {decoder,error=asset_decoder(a)}
            if error==.None {error=blob_read(&a.blob,entry,target.columns[at].data,decoder)}
            if error!=.None {
                document_destroy(doc)
                return error
            }
        }
    }
    return .None
}

// The file data is, written again as p packs it: the same content with its
// chunks, and the pages of a mesh, compressed again. Cooking a shipped game
// writes its assets with Ship; with a worker, the pieces of a large chunk are
// compressed on the workers of its job system.
document_repack :: proc(data:[]u8,p:Pack,allocator:=context.allocator,worker:=jobs.Worker_Ref{}) -> (repacked:[]u8,error:Error) {
    doc:Document
    document_read(&doc,data,allocator) or_return
    defer document_destroy(&doc)
    if doc.kind==KIND_MESH {mesh_pages_repack(&doc,p) or_return}
    return document_bytes(&doc,allocator,p,worker)
}

document_read :: proc(doc:^Document,data:[]u8,allocator:=context.allocator,limit:=u64(DEFAULT_MEMORY_LIMIT)) -> Error {
    doc^={}
    a:Asset
    asset_open(&a,data,allocator,limit) or_return
    defer asset_close(&a)
    return document_from_asset(doc,&a,allocator)
}

document_load :: proc(doc:^Document,path:string,allocator:=context.allocator,limit:=u64(DEFAULT_MEMORY_LIMIT)) -> Error {
    doc^={}
    a:Asset
    asset_load(&a,path,allocator,limit) or_return
    defer asset_close(&a)
    return document_from_asset(doc,&a,allocator)
}

// The rows of a table of one column without name, as values of T: converted
// by field names when the document stores another layout.
document_rows :: proc(doc:^Document,types:^Types,name:string,out:^[dynamic]$T,default:^T=nil) -> Error {
    clear(out)
    table,found:=document_table(doc,name)
    if !found {return .Not_Found}
    target:=&doc.tables[table]
    if len(target.columns)!=1 || target.columns[0].name!="" {return .Invalid}
    index,known:=types_index(types,T)
    if !known {return types.error}
    if resize(out,target.rows)!=nil {return .Out_Of_Memory}
    migration:serial.Migration
    migration_error:=serial.migration_init(&migration,&doc.schema,target.columns[0].type,&types.schema,index,doc.allocator)
    defer serial.migration_destroy(&migration)
    if migration_error!=.None {clear(out);return migration_error==.Out_Of_Memory?.Out_Of_Memory:.Invalid}
    serial.value_read(&migration,raw_data(out^),target.columns[0].data,target.rows,default)
    return .None
}

// Makes a column hold values of T, converting what it holds by field names.
document_column_convert :: proc(doc:^Document,types:^Types,table,column:int,$T:typeid) -> Error {
    index,known:=types_index(types,T)
    if !known {return types.error}
    if doc.hashes[doc.tables[table].columns[column].type]==types.hashes[index] {return .None}
    return document_column_retype(doc,table,column,&types.schema,index)
}

// Makes a column hold values of a type of another schema, converting what it holds by field names. A field
// the column did not hold takes its value in default, one value of that type, or zero without it.
document_column_retype :: proc(doc:^Document,table,column:int,source:^serial.Schema,type:serial.Type_Index,default:[]u8=nil) -> Error {
    if int(type)>=len(source.types) || default!=nil && len(default)<int(source.types[type].size) {return .Invalid}
    link:serial.Schema_Import
    document_import_begin(doc,&link,source)
    defer serial.schema_import_destroy(&link)
    imported:=document_import(doc,&link,type)
    if imported==serial.TYPE_NONE {return .Out_Of_Memory}
    target:=&doc.tables[table].columns[column]
    if doc.hashes[imported]==doc.hashes[target.type] {return .None}
    rows:=doc.tables[table].rows
    stored:=doc.schema.types[imported]
    size:=int(stored.size)
    converted:=Doc_Column{name=target.name,type=imported,size=size,flags=target.flags,ref=target.ref,alignment=max(target.alignment,int(stored.align)),compression=target.compression}
    column_size(doc,&converted,rows*size) or_return
    migration:serial.Migration
    migration_error:=serial.migration_init(&migration,&doc.schema,target.type,&doc.schema,imported,doc.allocator)
    defer serial.migration_destroy(&migration)
    if migration_error!=.None {
        mem.free_bytes(raw_data(converted.data)[:converted.capacity],doc.allocator)
        return migration_error==.Out_Of_Memory?.Out_Of_Memory:.Invalid
    }
    serial.migration_apply(&migration,converted.data,target.data,rows,default)
    mem.free_bytes(raw_data(target.data)[:target.capacity],doc.allocator)
    target^=converted
    return .None
}
