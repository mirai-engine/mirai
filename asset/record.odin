package asset

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "mirai:std/codec"
import "mirai:std/base"
import "mirai:std/serial"

// Typed records over the container. Whatever its kind, an asset is a set of
// tables; a table is a set of columns of equal length; a column holds the
// images of values of one type of the schema the file carries. A kind is a
// fourcc and the tables it expects, so a new one needs no container code and
// every tool reads it through its schema.
//
//   DEPS  the assets this one refers to: ids, sorted
//   STRS  the names of tables and columns
//   SCHM  the schema, in the binary form of std/serial
//   TDIR  the tables: name, flags, rows, key, and for every column its name,
//         type, flags, the table its values index, and its chunk
//   RECS  a column of records
//   BULK  a column of a table marked Bulk: vertices, indices, texels
//   IMPT  a column of the table marked Import
//
// A column without a name is the row itself; it is the only column of its
// table. The key of a table is the column that identifies its rows.

TAG_DEPS :: Fourcc(u32('D')|u32('E')<<8|u32('P')<<16|u32('S')<<24)
TAG_STRS :: Fourcc(u32('S')|u32('T')<<8|u32('R')<<16|u32('S')<<24)
TAG_SCHM :: Fourcc(u32('S')|u32('C')<<8|u32('H')<<16|u32('M')<<24)
TAG_TDIR :: Fourcc(u32('T')|u32('D')<<8|u32('I')<<16|u32('R')<<24)
TAG_RECS :: Fourcc(u32('R')|u32('E')<<8|u32('C')<<16|u32('S')<<24)
TAG_BULK :: Fourcc(u32('B')|u32('U')<<8|u32('L')<<16|u32('K')<<24)
TAG_IMPT :: Fourcc(u32('I')|u32('M')<<8|u32('P')<<16|u32('T')<<24)

MAX_TABLES :: 4096
MAX_COLUMNS :: 256
MAX_ROWS :: 1<<31
MAX_NAME :: 127

Table_Flag :: enum u8 {
    Single, // one row, read and written without a row index
    Bulk,   // heavy data for direct use: tools summarize it instead of listing it
    Import, // where the asset came from
}
Table_Flags :: bit_set[Table_Flag;u8]

// Names of tables and columns are words a path can hold: no dots, brackets,
// quotes, spaces or control characters.
name_valid :: proc(name:string) -> bool {
    if len(name)==0 || len(name)>MAX_NAME {return false}
    for c in transmute([]u8)name {
        switch c {
        case 0..=0x20,'.','[',']','@','=','"','\\',0x7f: return false
        }
    }
    return true
}

Asset_Column :: struct {
    name:string,
    type:serial.Type_Index,
    size:int, // of one row
    flags:serial.Field_Flags,
    ref:int,  // the table whose rows its values index, or -1
    chunk:int,
    data:[]u8, // its rows once asked for: inside the file, or memory of the asset
    ready:bool,
}

Asset_Table :: struct {
    name:string,
    name_hash:u64,
    flags:Table_Flags,
    rows:int,
    key:int, // column, or -1
    columns:[]Asset_Column,
}

// An asset open for reading. Names and columns stored as they are point into
// the file, which has to outlive the Asset; a column that is compressed, not
// aligned or of another layout is brought into memory the Asset owns.
Asset :: struct {
    blob:Blob,
    schema:serial.Schema, // of the file
    hashes:[dynamic]u64,
    tables:[]Asset_Table,
    dependencies:[]base.Asset_Id,
    file:[]u8,            // the file, when asset_load read it
    owned:[dynamic][]u8,
    allocator:runtime.Allocator,
    view:Scene_View,      // of a scene or prefab, read once with view_types
    view_types:^Types,
    decoder:^Decoder,     // lent by whoever reads, else made by asset_decoder and owned
    lacking:[2]string,    // the table and the field of a row a whole read refused: the file does not store that field
    decoder_owned:bool,
    codecs:^codec.Table,  // what a decoder asset_decoder makes reads the streams of a plugin with
}

// Opens an asset held in memory. data is borrowed, and so is decoder, which
// decodes its compressed chunks.
asset_open :: proc(a:^Asset,data:[]u8,allocator:=context.allocator,limit:=u64(DEFAULT_MEMORY_LIMIT),decoder:^Decoder=nil,codecs:^codec.Table=nil) -> Error {
    a^={allocator=allocator,decoder=decoder,codecs=codecs}
    a.owned=make([dynamic][]u8,allocator)
    a.hashes=make([dynamic]u64,allocator)
    error:=asset_parse(a,data,limit)
    if error!=.None {asset_close(a)}
    return error
}

// Reads a file into memory aligned for its chunks and opens it.
asset_load :: proc(a:^Asset,path:string,allocator:=context.allocator,limit:=u64(DEFAULT_MEMORY_LIMIT),decoder:^Decoder=nil,codecs:^codec.Table=nil) -> Error {
    a^={}
    file:=asset_file_read(path,allocator,limit) or_return
    return asset_take(a,file,allocator,limit,decoder,codecs)
}

// Opens an asset held in memory that it takes: asset_close frees data, and so
// does a failure. data comes from allocator, aligned for its chunks.
asset_take :: proc(a:^Asset,data:[]u8,allocator:=context.allocator,limit:=u64(DEFAULT_MEMORY_LIMIT),decoder:^Decoder=nil,codecs:^codec.Table=nil) -> Error {
    error:=asset_open(a,data,allocator,limit,decoder,codecs)
    if error!=.None {
        mem.free_bytes(data,allocator)
        return error
    }
    a.file=data
    return .None
}

// The bytes of the file of an asset, aligned for its chunks.
asset_file_read :: proc(path:string,allocator:=context.allocator,limit:=u64(DEFAULT_MEMORY_LIMIT)) -> (data:[]u8,error:Error) {
    head:[HEADER_SIZE]u8
    bytes,_,head_error:=serial.file_read_head(path,head[:])
    if head_error!=.None {return nil,head_error==.Not_Found?.Not_Found:.IO}
    header:=header_read(bytes) or_return
    file,file_error:=serial.file_read(path,allocator,asset_alignment(header),i64(min(limit,u64(max(i64)))))
    #partial switch file_error {
    case .None:
    case .Too_Large: return nil,.Too_Large
    case .Out_Of_Memory: return nil,.Out_Of_Memory
    case .Not_Found: return nil,.Not_Found
    case: return nil,.IO
    }
    return file,.None
}

// A copy of the bytes of a file, aligned for the chunks of the asset they are.
asset_bytes_clone :: proc(data:[]u8,allocator:=context.allocator) -> (copied:[]u8,error:Error) {
    alignment:=serial.WRITER_ALIGNMENT
    if header,read:=header_read(data);read==.None {alignment=asset_alignment(header)}
    block,allocation:=mem.alloc_bytes_non_zeroed(len(data),alignment,allocator)
    if allocation!=nil {return nil,.Out_Of_Memory}
    copy(block,data)
    return block,.None
}

@(private)
asset_alignment :: proc "contextless" (header:Header) -> int {return max(int(header.alignment),serial.WRITER_ALIGNMENT)}

asset_close :: proc(a:^Asset) {
    if a.allocator.procedure==nil {return}
    for block in a.owned {mem.free_bytes(block,a.allocator)}
    for table in a.tables {delete(table.columns,a.allocator)}
    delete(a.tables,a.allocator)
    delete(a.owned);delete(a.hashes)
    if a.schema.allocator.procedure!=nil {serial.schema_destroy(&a.schema)}
    mem.free_bytes(a.file,a.allocator)
    if a.decoder_owned {
        decoder_destroy(a.decoder)
        free(a.decoder,a.allocator)
    }
    a^={}
}

// The decoder of the asset: the one it was lent, or its own, made the first
// time it is needed.
asset_decoder :: proc(a:^Asset) -> (decoder:^Decoder,error:Error) {
    if a.decoder!=nil {return a.decoder,.None}
    allocation:mem.Allocator_Error
    if decoder,allocation=new(Decoder,a.allocator);allocation!=nil {return nil,.Out_Of_Memory}
    if error=decoder_init(decoder,a.allocator,a.codecs);error!=.None {
        free(decoder,a.allocator)
        return nil,error
    }
    a.decoder,a.decoder_owned=decoder,true
    return decoder,.None
}

@(private)
asset_alloc :: proc(a:^Asset,size:int,alignment:int) -> (block:[]u8,error:Error) {
    if size==0 {return nil,.None}
    bytes,alloc_error:=mem.alloc_bytes_non_zeroed(size,max(alignment,16),a.allocator)
    if alloc_error!=nil {return nil,.Out_Of_Memory}
    append(&a.owned,bytes)
    return bytes,.None
}

// The content of a chunk: in place when it is stored as it is and aligned in
// memory, else in memory of the asset.
@(private)
asset_chunk :: proc(a:^Asset,index:int,alignment:int) -> (data:[]u8,error:Error) {
    entry:=blob_chunk(&a.blob,index)
    // The front of a file (asset_open_front) holds only the chunks it was read for.
    if entry.offset+entry.size>u64(len(a.blob.data)) {return nil,.Truncated}
    if entry.compression==.None {
        stored:=blob_stored(&a.blob,entry)
        if len(stored)==0 || uintptr(raw_data(stored))&uintptr(alignment-1)==0 {return stored,.None}
    }
    data=asset_alloc(a,int(entry.uncompressed_size),alignment) or_return
    decoder:^Decoder
    if entry.compression!=.None {decoder=asset_decoder(a) or_return}
    blob_read(&a.blob,entry,data,decoder) or_return
    return data,.None
}

// Opens the front of an asset file: everything up to the chunks a caller
// reads, which the bulk data follows. Reaching a chunk past it is Truncated.
@(private)
asset_open_front :: proc(a:^Asset,data:[]u8,allocator:=context.allocator,decoder:^Decoder=nil,codecs:^codec.Table=nil) -> Error {
    a^={allocator=allocator,decoder=decoder,codecs=codecs}
    a.owned=make([dynamic][]u8,allocator)
    a.hashes=make([dynamic]u64,allocator)
    error:=asset_parse(a,data,DEFAULT_MEMORY_LIMIT,front=true)
    if error!=.None {asset_close(a)}
    return error
}

// Reads the front of an asset file, everything but its bulk columns: those
// stay in the file, to be read by range at the offset of their chunk.
// Reaching a bulk column is Truncated, and the content hash is not checked.
asset_load_front :: proc(a:^Asset,path:string,allocator:=context.allocator,decoder:^Decoder=nil,codecs:^codec.Table=nil) -> Error {
    a^={}
    head:[REGISTRY_HEAD]u8
    bytes,size,read_error:=serial.file_read_head(path,head[:])
    if read_error!=.None {return read_error==.Not_Found?.Not_Found:.IO}
    header:=header_read(bytes) or_return
    if header.total_size!=u64(size) {return .Truncated}
    front:=front_read(path,bytes,header,true,allocator) or_return
    if error:=asset_open_front(a,front,allocator,decoder,codecs);error!=.None {mem.free_bytes(front,allocator);return error}
    a.file=front
    return .None
}

// The front of an asset file from the head read of it: the header, the
// directory and, aligned for them in allocator, the chunks of the schema,
// the tables, the strings, the dependencies and the import record, with
// every other chunk but the bulk ones when all is set.
@(private)
front_read :: proc(path:string,head:[]u8,header:Header,all:bool,allocator:=context.allocator) -> (front:[]u8,error:Error) {
    entries:=directory_read(path,head,header,context.temp_allocator) or_return
    end:=u64(HEADER_SIZE+len(entries)*CHUNK_ENTRY_SIZE)
    for entry in entries {
        switch entry.tag {
        case TAG_BULK:
        case TAG_DEPS,TAG_STRS,TAG_SCHM,TAG_TDIR,TAG_IMPT: end=max(end,entry.offset+entry.size)
        case: if all {end=max(end,entry.offset+entry.size)}
        }
    }
    allocation:mem.Allocator_Error
    front,allocation=mem.alloc_bytes_non_zeroed(int(end),asset_alignment(header),allocator)
    if allocation!=nil {return nil,.Out_Of_Memory}
    if end<=u64(len(head)) {copy(front,head[:end])} else if serial.file_read_range(path,0,front)!=.None {mem.free_bytes(front,allocator);return nil,.IO}
    return front,.None
}

@(private)
asset_parse :: proc(a:^Asset,data:[]u8,limit:u64,front:=false) -> Error {
    if front {
        header:=header_read(data) or_return
        if u64(len(data))>header.total_size || len(data)<HEADER_SIZE+int(header.chunk_count)*CHUNK_ENTRY_SIZE {return .Truncated}
        a.blob={data=data,header=header}
        for i in 0..<int(header.chunk_count) {
            if !chunk_entry_check(header,blob_chunk(&a.blob,i)) {return .Corrupt}
        }
    } else {
        a.blob=blob_open(data,limit) or_return
    }
    blob:=&a.blob
    schema_chunk,has_schema:=blob_find(blob,TAG_SCHM)
    tables_chunk,has_tables:=blob_find(blob,TAG_TDIR)
    if !has_schema || !has_tables {return .Corrupt}
    {
        bytes:=asset_chunk(a,schema_chunk,1) or_return
        reader:=serial.reader_init(bytes)
        if error:=serial.schema_read(&reader,&a.schema,a.allocator);error!=.None {return .Out_Of_Memory if error==.Out_Of_Memory else .Schema}
        if serial.reader_remaining(&reader)!=0 {return .Schema}
        if !serial.schema_hashes_update(&a.schema,&a.hashes) {return .Out_Of_Memory}
    }
    if chunk,found:=blob_find(blob,TAG_DEPS);found {
        bytes:=asset_chunk(a,chunk,align_of(base.Asset_Id)) or_return
        if len(bytes)%size_of(base.Asset_Id)!=0 {return .Corrupt}
        a.dependencies=mem.slice_data_cast([]base.Asset_Id,bytes)
    }
    names:[]u8
    if chunk,found:=blob_find(blob,TAG_STRS);found {names=asset_chunk(a,chunk,1) or_return}
    directory:=asset_chunk(a,tables_chunk,1) or_return
    r:=serial.reader_init(directory)
    name_read :: proc(r:^serial.Reader,names:[]u8) -> (name:string,ok:bool) {
        offset,size:=serial.read_varint(r),serial.read_varint(r)
        if r.failed || offset>u64(len(names)) || size>u64(len(names))-offset {return "",false}
        return string(names[offset:][:size]),true
    }
    table_count:=serial.read_count(&r,6)
    if r.failed || table_count>MAX_TABLES {return .Corrupt}
    tables,tables_error:=make([]Asset_Table,table_count,a.allocator)
    if tables_error!=nil {return .Out_Of_Memory}
    a.tables=tables
    for &table in a.tables {
        name:=name_read(&r,names) or_else ""
        flags:=serial.read_u8(&r)
        rows,key:=serial.read_varint(&r),serial.read_varint(&r)
        column_count:=serial.read_count(&r,6)
        if r.failed || !name_valid(name) || flags>=1<<len(Table_Flag) || rows>MAX_ROWS || column_count>MAX_COLUMNS || key>u64(column_count) {return .Corrupt}
        table.name,table.name_hash=name,base.name_hash(name)
        table.flags=transmute(Table_Flags)flags
        table.rows,table.key=int(rows),int(key)-1
        if .Single in table.flags && rows!=1 {return .Corrupt}
        columns,columns_error:=make([]Asset_Column,column_count,a.allocator)
        if columns_error!=nil {return .Out_Of_Memory}
        table.columns=columns
        for &column,at in table.columns {
            column_name,name_ok:=name_read(&r,names)
            type:=serial.read_varint(&r)
            field_flags:=serial.read_u8(&r)
            ref,chunk:=serial.read_varint(&r),serial.read_varint(&r)
            if r.failed || !name_ok || type>=u64(len(a.schema.types)) || ref>u64(table_count) || chunk>=u64(blob.header.chunk_count) {return .Corrupt}
            if column_name=="" ? column_count!=1 : !name_valid(column_name) {return .Corrupt}
            for previous in table.columns[:at] {
                if previous.name==column_name {return .Corrupt}
            }
            stored:=a.schema.types[type]
            column.name,column.type,column.size=column_name,serial.Type_Index(type),int(stored.size)
            column.flags=transmute(serial.Field_Flags)field_flags
            column.ref,column.chunk=int(ref)-1,int(chunk)
            if column.ref>=0 && (stored.kind!=.Uint || stored.size>8) {return .Corrupt}
            if blob_chunk(blob,column.chunk).uncompressed_size!=u64(table.rows)*u64(stored.size) {return .Corrupt}
        }
        if !rows_backed(table.rows,table.columns) {return .Corrupt}
    }
    if serial.reader_remaining(&r)!=0 {return .Corrupt}
    for table,at in a.tables {
        for previous in a.tables[:at] {
            if previous.name_hash==table.name_hash && previous.name==table.name {return .Corrupt}
        }
    }
    return .None
}

asset_table :: proc(a:^Asset,name:string) -> (table:^Asset_Table,found:bool) {
    hash:=base.name_hash(name)
    for &candidate in a.tables {
        if candidate.name_hash==hash && candidate.name==name {return &candidate,true}
    }
    return nil,false
}
asset_table_by_hash :: proc(a:^Asset,name_hash:u64) -> (table:^Asset_Table,found:bool) {
    for &candidate in a.tables {
        if candidate.name_hash==name_hash {return &candidate,true}
    }
    return nil,false
}
table_column :: proc(table:^Asset_Table,name:string) -> (column:int,found:bool) {
    for candidate,at in table.columns {
        if candidate.name==name {return at,true}
    }
    return -1,false
}

// The rows of a column as the file holds them: rows*size bytes, aligned as
// the type and the chunk ask.
asset_column_data :: proc(a:^Asset,table:^Asset_Table,column:int) -> (data:[]u8,error:Error) {
    target:=&table.columns[column]
    if !target.ready {
        alignment:=max(int(a.schema.types[target.type].align),1<<blob_chunk(&a.blob,target.chunk).alignment_log2)
        target.data=asset_chunk(a,target.chunk,alignment) or_return
        target.ready=true
    }
    return target.data,.None
}

// Whether the rows of a column have the layout of a type of another schema.
asset_column_matches :: proc(a:^Asset,table:^Asset_Table,column:int,layout_hash:u64) -> bool {
    return a.hashes[table.columns[column].type]==layout_hash
}

// Reads the rows of a column into dst as values of a type of another schema:
// one copy with the same layout, a migration by field names otherwise. whole
// refuses, with Version, a column that does not store a field of the type: the
// rows of a kind of asset, which hold every field of its version.
asset_column_read :: proc(a:^Asset,table:^Asset_Table,column:int,schema:^serial.Schema,type:serial.Type_Index,dst:[]u8,default:[]u8=nil,whole:=false) -> Error {
    size:=int(schema.types[type].size)
    if len(dst)!=table.rows*size {return .Invalid}
    data:=asset_column_data(a,table,column) or_return
    migration:serial.Migration
    migration_error:=serial.migration_init(&migration,&a.schema,table.columns[column].type,schema,type,a.allocator)
    defer serial.migration_destroy(&migration)
    if migration_error!=.None {return migration_error==.Out_Of_Memory?.Out_Of_Memory:.Invalid}
    if whole && migration.added>0 {
        a.lacking={table.name,migration.lacking}
        return .Version
    }
    serial.migration_apply(&migration,dst,data,table.rows,default)
    return .None
}

// The rows of a column as values of T: the file itself when T has the layout
// the file stores, a migrated copy the asset owns otherwise.
asset_rows :: proc(a:^Asset,types:^Types,table_name,column_name:string,$T:typeid,default:^T=nil,whole:=false) -> (rows:[]T,error:Error) {
    table,found:=asset_table(a,table_name)
    if !found {return nil,.Not_Found}
    column,column_found:=table_column(table,column_name)
    if !column_found {return nil,.Not_Found}
    index,known:=types_index(types,T)
    if !known {return nil,types.error}
    if table.rows==0 || size_of(T)==0 {return nil,.None}
    if asset_column_matches(a,table,column,types.hashes[index]) && !types.transient[index] {
        data:=asset_column_data(a,table,column) or_return
        if uintptr(raw_data(data))&uintptr(align_of(T)-1)==0 {return mem.slice_data_cast([]T,data),.None}
    }
    block:=asset_alloc(a,table.rows*size_of(T),align_of(T)) or_return
    asset_column_read(a,table,column,&types.schema,index,block,default==nil?nil:mem.ptr_to_bytes(default),whole) or_return
    return mem.slice_data_cast([]T,block),.None
}

// The row of a table of one row.
asset_row :: proc(a:^Asset,types:^Types,table_name:string,$T:typeid,default:^T=nil,whole:=false) -> (row:^T,error:Error) {
    rows:=asset_rows(a,types,table_name,"",T,default,whole) or_return
    if len(rows)!=1 {return nil,.Corrupt}
    return &rows[0],.None
}

// More than one row needs a column that takes room: a count of rows is
// never larger than the data that backs it.
@(private)
rows_backed :: proc(rows:int,columns:[]$C) -> bool {
    if rows<=1 {return true}
    for column in columns {
        if column.size>0 {return true}
    }
    return false
}

// A row index stored in size bytes.
@(private)
index_load :: #force_inline proc "contextless" (data:[]u8,row:int,size:int) -> u64 {
    value:u64
    intrinsics.mem_copy_non_overlapping(&value,raw_data(data[row*size:]),size)
    return value
}
@(private)
index_store :: #force_inline proc "contextless" (data:[]u8,row:int,size:int,value:u64) {
    value:=value
    intrinsics.mem_copy_non_overlapping(raw_data(data[row*size:]),&value,size)
}
