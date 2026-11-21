package asset

import "base:intrinsics"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:store"

// A native asset of a package lives in the store as an object: one group per
// container chunk in the order of the directory, cut where the format has
// pieces it reads alone, and the header and the directory as the meta of the
// root. The object holds its file as a write with Codecs.None makes it: no
// chunk, block or page goes through a stage of a compressor, and each kind's
// own modeling (BC blocks, planes of their fields, the coding of mesh pages and
// of terrain pages) is chosen without one; the store compresses each chunk
// where it rests. So the same asset is the same object for every compressor.
// The file is the meta, then each group at the offset of its chunk with zeros
// between them: loading the object and saving a file gives the bytes that were
// put once written so.

// The most chunks an asset of the store has: its header and directory fit in the meta of a root.
OBJECT_CHUNKS_MAX :: (int(max(u16))-HEADER_SIZE)/CHUNK_ENTRY_SIZE

// The object an Asset reads its chunks from, each the first time it is asked for.
@(private)
Asset_Object :: struct {
    object:store.Object,
    stored:[][]u8, // of each chunk once read whole: a slice of a mapped pack, or memory of the asset
    here:[]bool,
}

// Puts the file of an asset held in data as an object into the batch of s,
// without committing. The file is checked whole, its hash too, before any
// of it goes in.
object_put :: proc(s:^store.Store,original:[]u8) -> (address:store.Hash,error:Error) {
    if s==nil {return {},.Invalid}
    data:=original
    // The file as it arrived is checked: what is written again from it carries a hash of its own.
    {
        arrived:Blob
        arrived,error=blob_open(original)
        if error!=.None {return}
        if !blob_verify_hash(&arrived) {return {},.Hash}
    }
    if !(object_raw(data) or_return) {
        data=object_raw_write(data) or_return
    }
    defer if raw_data(data)!=raw_data(original) {mem.free_bytes(data,context.temp_allocator)}
    a:Asset
    asset_open(&a,data,context.temp_allocator) or_return
    defer asset_close(&a)
    if !blob_verify_hash(&a.blob) {return {},.Hash}
    count:=int(a.blob.header.chunk_count)
    if count>OBJECT_CHUNKS_MAX {return {},.Too_Large}
    types:Types
    types_init(&types,context.temp_allocator)
    defer types_destroy(&types)
    cuts:=make([dynamic]int,context.temp_allocator)
    p,begin_error:=store.put_begin(s)
    if begin_error!=.None {return {},store_error(begin_error)}
    for i in 0..<count {
        entry:=blob_chunk(&a.blob,i)
        stored:=blob_stored(&a.blob,entry)
        clear(&cuts)
        if e:=object_cuts(&a,&types,i,entry,stored,&cuts);e!=.None {
            store.put_abandon(&p)
            return {},e
        }
        if e:=store.put_native(&p,u32(entry.tag),u32(entry.index),entry.alignment_log2,stored,cuts[:]);e!=.None {
            store.put_abandon(&p)
            return {},store_error(e)
        }
    }
    root,_,finish_error:=store.put_finish(&p,data[:HEADER_SIZE+count*CHUNK_ENTRY_SIZE])
    return root,store_error(finish_error)
}

// Whether a file is as a write with Codecs.None makes it: no chunk is a
// stream, every page of a mesh is stored as it is, and a texture has no layouts and the planes the kind chooses.
@(private="file")
object_raw :: proc(data:[]u8) -> (raw:bool,error:Error) {
    a:Asset
    asset_open(&a,data,context.temp_allocator) or_return
    defer asset_close(&a)
    for i in 0..<int(a.blob.header.chunk_count) {
        if blob_chunk(&a.blob,i).compression!=.None {return false,.None}
    }
    types:Types
    types_init(&types,context.temp_allocator)
    defer types_destroy(&types)
    switch a.blob.header.kind {
    case KIND_TEXTURE:
        if _,laid:=asset_table(&a,TEXTURE_TABLE_LAYOUTS);laid {return false,.None}
        info:=asset_row(&a,&types,"texture",Texture_Info) or_return
        planes:=texture_fields_format(info.format) && .Fast not_in info.flags
        return planes==(.Fields in info.flags),.None
    case KIND_MESH:
        pages:=table_rows(&a,&types,"pages",Mesh_Page) or_return
        page_data:=table_rows(&a,&types,"page_data",u8) or_return
        for page in pages {
            if u64(page.data_offset)+u64(page.data_bytes)>u64(len(page_data)) {return false,.Corrupt}
            if page.data_bytes>0 && !pack_matches(page_data[page.data_offset:][:page.data_bytes],.Fast,.None) {return false,.None}
        }
    }
    return true,.None
}

// A file written again as Codecs.None writes it, in the temporary allocator.
@(private="file")
object_raw_write :: proc(data:[]u8) -> (raw:[]u8,error:Error) {
    header:=header_read(data) or_return
    if header.kind==KIND_TEXTURE {
        types:Types
        types_init(&types,context.temp_allocator)
        defer types_destroy(&types)
        return texture_repack(data,&types,.Fast,context.temp_allocator)
    }
    return document_repack(data,.Fast,.None,context.temp_allocator)
}

// object_put of the file at path.
object_put_file :: proc(s:^store.Store,path:string) -> (address:store.Hash,error:Error) {
    data:=asset_file_read(path,context.temp_allocator) or_return
    defer mem.free_bytes(data,context.temp_allocator)
    return object_put(s,data)
}

// Where a container chunk is cut, as offsets of its stored bytes: between the
// pieces of a stream, which decode alone; between the levels of the texels of
// a texture stored as they are, smallest first; between the blocks of the
// pages of a mesh and of a table of blocks (Block_Record).
@(private="file")
object_cuts :: proc(a:^Asset,types:^Types,index:int,entry:Chunk_Entry,stored:[]u8,cuts:^[dynamic]int) -> Error {
    add :: proc(cuts:^[dynamic]int,at:u64) -> Error {
        if _,no_room:=append(cuts,int(at));no_room!=nil {return .Out_Of_Memory}
        return .None
    }
    if entry.compression==.Stream {
        s:=stream_read(stored,int(entry.uncompressed_size)) or_return
        at:=u64(s.first)
        add(cuts,at) or_return
        for piece in 0..<s.count {
            at+=u64(u32_read(s.table[piece*4:]))
            add(cuts,at) or_return
        }
    } else {
        table:=object_table_of(a,index)
        switch {
        case table==nil:
        case a.blob.header.kind==KIND_TEXTURE && table.name=="texels":
            mips:=asset_rows(a,types,"mips","",Texture_Mip) or_return
            for mip in mips {add(cuts,u64(mip.offset)) or_return}
        case a.blob.header.kind==KIND_MESH && table.name=="page_data":
            pages:=asset_rows(a,types,"pages","",Mesh_Page) or_return
            for page in pages {add(cuts,u64(page.data_offset)) or_return}
        case len(table.name)>len("_blocks") && table.name[len(table.name)-len("_blocks"):]=="_blocks":
            name:=table.name[:len(table.name)-len("_blocks")]
            records,found:=asset_table(a,strings.concatenate({name,"_pages"},context.temp_allocator))
            if !found || len(records.columns)!=1 || records.columns[0].size!=size_of(Block_Record) {break}
            bytes:=asset_column_data(a,records,0) or_return
            if len(bytes)%size_of(Block_Record)!=0 {return .Corrupt}
            for at:=0;at<len(bytes);at+=size_of(Block_Record) {
                record:=intrinsics.unaligned_load((^Block_Record)(raw_data(bytes[at:])))
                if record.size>0 {add(cuts,record.offset) or_return}
            }
        }
    }
    // What the store takes: offsets inside the bytes, ascending, each once.
    slice.sort(cuts[:])
    kept:=0
    for cut in cuts {
        if cut<=0 || cut>=len(stored) || kept>0 && cuts[kept-1]==cut {continue}
        cuts[kept]=cut
        kept+=1
    }
    base.truncate(cuts,kept)
    return .None
}

// The table one of whose columns is the chunk index; nil for another chunk.
@(private="file")
object_table_of :: proc(a:^Asset,index:int) -> ^Asset_Table {
    for &t in a.tables {
        for c in t.columns {
            if c.chunk==index {return &t}
        }
    }
    return nil
}

// Opens the asset of the store at address: its header, directory and tables
// from the meta and the chunks of the front, and every other chunk when it is
// first read, so a read of a part reads only the chunks that hold it. The store
// is borrowed and outlives the Asset; so is decoder. A chunk the store does not
// hold yet is Not_Here to whoever reads it.
asset_open_object :: proc(a:^Asset,s:^store.Store,address:store.Hash,allocator:=context.allocator,limit:=u64(DEFAULT_MEMORY_LIMIT),decoder:^Decoder=nil) -> Error {
    a^={allocator=allocator,decoder=decoder}
    a.owned=make([dynamic][]u8,allocator)
    a.hashes=make([dynamic]u64,allocator)
    error:=object_attach(a,s,address)
    if error==.None {error=asset_parse(a,store.object_meta(&a.object.object),limit,object=true)}
    if error!=.None {asset_close(a)}
    return error
}

@(private="file")
object_attach :: proc(a:^Asset,s:^store.Store,address:store.Hash) -> Error {
    if s==nil {return .Invalid}
    allocation:mem.Allocator_Error
    if a.object,allocation=new(Asset_Object,a.allocator);allocation!=nil {return .Out_Of_Memory}
    o,open_error:=store.object_open(s,address)
    if open_error!=.None {return object_error(open_error)}
    a.object.object=o
    return .None
}

// What a read of the store meets, as an asset error: a chunk it does not hold is Not_Here.
@(private)
object_error :: proc(error:store.Error) -> Error {
    switch error {
    case .None: return .None
    case .Missing: return .Not_Here
    case .Corrupt,.Invalid_Argument,.Unsupported_Layout: return .Corrupt
    case .Out_Of_Memory: return .Out_Of_Memory
    case .Io,.No_Space: return .IO
    }
    return .IO
}

// The meta and the groups of an object against each other: a directory of
// entries inside the file, ascending and apart, each with the group of its
// tag and index holding its stored bytes, and a file that ends with its last
// chunk. Every size the meta declares is bounded by the groups before anything
// is allocated.
@(private)
object_check :: proc(a:^Asset,limit:u64) -> Error {
    header:=a.blob.header
    count:=int(header.chunk_count)
    if len(a.blob.data)!=HEADER_SIZE+count*CHUNK_ENTRY_SIZE {return .Corrupt}
    o:=&a.object.object
    groups:=store.object_groups(o)
    if len(groups)!=count {return .Corrupt}
    total:=u64(0)
    end:=u64(HEADER_SIZE+count*CHUNK_ENTRY_SIZE)
    for i in 0..<count {
        entry:=blob_chunk(&a.blob,i)
        if !chunk_entry_check(header,entry) || entry.offset<end {return .Corrupt}
        end=entry.offset+entry.size
        g:=groups[i]
        next:=groups[i+1].offset if i+1<count else store.object_size(o)
        if g.tag!=u32(entry.tag) || g.index!=u32(entry.index) || next<g.offset || next-g.offset!=entry.size {return .Corrupt}
        total+=entry.uncompressed_size
        if total>limit {return .Too_Large}
    }
    // The file ends where its last chunk does: its size is what the groups hold.
    if header.total_size!=end {return .Corrupt}
    allocation:mem.Allocator_Error
    if a.object.stored,allocation=make([][]u8,count,a.allocator);allocation!=nil {return .Out_Of_Memory}
    if a.object.here,allocation=make([]bool,count,a.allocator);allocation!=nil {return .Out_Of_Memory}
    return .None
}

// Reads every chunk of an asset of the store that is not read yet and lets go
// of its object: the Asset reads nothing more of the store, whose mapped packs
// its chunks may still be slices of while the store is open. Nothing for a file.
asset_object_settle :: proc(a:^Asset) -> Error {
    if a.object==nil || a.object.object.s==nil {return .None}
    for i in 0..<int(a.blob.header.chunk_count) {asset_stored(a,i) or_return}
    meta,allocation:=mem.alloc_bytes_non_zeroed(len(a.blob.data),16,a.allocator)
    if allocation!=nil {return .Out_Of_Memory}
    copy(meta,a.blob.data)
    append(&a.owned,meta)
    a.blob.data=meta
    store.object_close(&a.object.object)
    return .None
}

@(private)
object_detach :: proc(a:^Asset) {
    if a.object==nil {return}
    store.object_close(&a.object.object)
    delete(a.object.stored,a.allocator)
    delete(a.object.here,a.allocator)
    free(a.object,a.allocator)
    a.object=nil
}

// The bytes of a chunk as the file stores them: of the file, or read from the
// store the first time, a slice of the mapped pack when it is one chunk there
// and memory of the asset otherwise.
@(private)
asset_stored :: proc(a:^Asset,index:int) -> (stored:[]u8,error:Error) {
    entry:=blob_chunk(&a.blob,index)
    if a.object==nil {
        // The front of a file (asset_open_front) holds only the chunks it was read for.
        if entry.offset+entry.size>u64(len(a.blob.data)) {return nil,.Truncated}
        return blob_stored(&a.blob,entry),.None
    }
    o:=a.object
    if o.here[index] || entry.size==0 {return o.stored[index],.None}
    if o.object.s==nil {return nil,.Invalid}
    groups:=store.object_groups(&o.object)
    if groups[index].count==1 {
        bytes,at,chunk_error:=store.group_chunk(&o.object,index,0)
        if chunk_error!=.None {return nil,object_error(chunk_error)}
        if at!=0 || u64(len(bytes))!=entry.size {return nil,.Corrupt}
        // A chunk of a pack not sealed yet is read into a buffer of the object the next read reuses.
        if inside(bytes,o.object.chunk) || inside(bytes,o.object.nodes[0]) || inside(bytes,o.object.nodes[1]) {
            copied:=asset_alloc(a,len(bytes),1<<entry.alignment_log2) or_return
            copy(copied,bytes)
            bytes=copied
        }
        stored=bytes
    } else {
        stored=asset_alloc(a,int(entry.size),1<<entry.alignment_log2) or_return
        if e:=store.group_read(&o.object,index,0,stored);e!=.None {return nil,object_error(e)}
    }
    o.stored[index],o.here[index]=stored,true
    return stored,.None
}

@(private="file")
inside :: proc "contextless" (bytes,buffer:[]u8) -> bool {
    if len(buffer)==0 {return false}
    at,start:=uintptr(raw_data(bytes)),uintptr(raw_data(buffer))
    return at>=start && at<start+uintptr(len(buffer))
}

// The Store reads only the leaves covering the requested bytes.
@(private)
asset_stored_range :: proc(a:^Asset,index,start,end:int,alignment:=1,temporary:^[]u8=nil) ->
    (bytes:[]u8,error:Error) {
    entry:=blob_chunk(&a.blob,index)
    if start<0 || end<start || u64(end)>entry.size {return nil,.Corrupt}
    size:=end-start
    if size==0 {return nil,.None}
    stored:[]u8
    if a.object==nil {
        if entry.offset+u64(end)>u64(len(a.blob.data)) {return nil,.Truncated}
        stored=a.blob.data[entry.offset+u64(start):][:size]
    } else if a.object.here[index] {
        stored=a.object.stored[index][start:end]
    }
    if stored!=nil && uintptr(raw_data(stored))&uintptr(alignment-1)==0 {
        return stored,.None
    }
    bytes=asset_range_alloc(a,size,alignment,temporary) or_return
    if stored!=nil {
        copy(bytes,stored)
    } else if e:=store.group_read(&a.object.object,index,u64(start),bytes);e!=.None {
        return nil,object_error(e)
    }
    return bytes,.None
}

@(private="file")
asset_range_alloc :: proc(a:^Asset,size,alignment:int,temporary:^[]u8) ->
    (bytes:[]u8,error:Error) {
    if temporary==nil {return asset_alloc(a,size,alignment)}
    allocation:mem.Allocator_Error
    bytes,allocation=mem.alloc_bytes_non_zeroed(size,alignment,a.allocator)
    if allocation!=nil {return nil,.Out_Of_Memory}
    temporary^=bytes
    return bytes,.None
}

// The decoded range of a stream, reading only its directory and covering pieces.
@(private)
asset_stream_range :: proc(a:^Asset,index,start,end:int,alignment:int,temporary:^[]u8) ->
    (bytes:[]u8,error:Error) {
    entry:=blob_chunk(&a.blob,index)
    total:=int(entry.uncompressed_size)
    if start<0 || end<=start || end>total || entry.size<STREAM_HEAD {return nil,.Corrupt}
    head:[STREAM_HEAD+PACK_MAX_PIECES*4]u8
    if a.object!=nil && !a.object.here[index] {
        if e:=store.group_read(&a.object.object,index,0,head[:STREAM_HEAD]);e!=.None {
            return nil,object_error(e)
        }
    } else {
        prefix:=asset_stored_range(a,index,0,STREAM_HEAD) or_return
        copy(head[:STREAM_HEAD],prefix)
    }
    count:=int(u32_read(&head[5]))
    if count<1 || count>PACK_MAX_PIECES {return nil,.Corrupt}
    first_byte:=STREAM_HEAD+count*4
    if u64(first_byte)>entry.size {return nil,.Corrupt}
    if a.object!=nil && !a.object.here[index] {
        if e:=store.group_read(&a.object.object,index,STREAM_HEAD,head[STREAM_HEAD:first_byte]);
            e!=.None {return nil,object_error(e)}
    } else {
        table:=asset_stored_range(a,index,STREAM_HEAD,first_byte) or_return
        copy(head[STREAM_HEAD:first_byte],table)
    }
    stream:=stream_read(head[:first_byte],total,int(entry.size)) or_return
    if stream.format==STORED {
        return asset_stored_range(a,index,stream.first+start,stream.first+end,alignment,temporary)
    }

    first,last:=start/PACK_PIECE,(end-1)/PACK_PIECE+1
    offset:=stream.first
    for piece in 0..<first {offset+=int(u32_read(stream.table[piece*4:]))}
    limit:=offset
    for piece in first..<last {limit+=int(u32_read(stream.table[piece*4:]))}
    payload_buffer:[]u8
    defer mem.free_bytes(payload_buffer,a.allocator)
    payload:=asset_stored_range(a,index,offset,limit,temporary=&payload_buffer) or_return
    raw_start,raw_end:=first*PACK_PIECE,min(total,last*PACK_PIECE)
    decoded:=asset_range_alloc(a,raw_end-raw_start,alignment,temporary) or_return
    decoder:=asset_decoder(a) or_return
    if first==0 && last==stream.count {
        stream_chunk_pieces(decoder,stream,payload,decoded) or_return
    } else {
        stream_decode_pieces(&decoder.stream,stream,payload,decoded,total,first,last) or_return
    }
    return decoded[start-raw_start:end-raw_start],.None
}

// The file of the asset of the store at address, as loading it and saving it
// gives, in memory aligned for its chunks.
object_file :: proc(s:^store.Store,address:store.Hash,allocator:=context.allocator) -> (data:[]u8,error:Error) {
    a:Asset
    asset_open_object(&a,s,address,context.temp_allocator) or_return
    defer asset_close(&a)
    header:=a.blob.header
    allocation:mem.Allocator_Error
    data,allocation=mem.alloc_bytes(int(header.total_size),asset_alignment(header),allocator)
    if allocation!=nil {return nil,.Out_Of_Memory}
    copy(data,a.blob.data)
    for i in 0..<int(header.chunk_count) {
        entry:=blob_chunk(&a.blob,i)
        if entry.size==0 {continue}
        if e:=store.group_read(&a.object.object,i,0,data[entry.offset:][:entry.size]);e!=.None {
            mem.free_bytes(data,allocator)
            return nil,object_error(e)
        }
    }
    return data,.None
}

// Writes the file of the asset of the store at address at path, whole or not at all.
object_file_write :: proc(s:^store.Store,address:store.Hash,path:string) -> Error {
    data:=object_file(s,address,context.temp_allocator) or_return
    defer mem.free_bytes(data,context.temp_allocator)
    return serial.file_write_atomic(path,data)==.None?.None:.IO
}

// What the front of the asset of the store at address says, as import_peek of a file.
object_peek :: proc(s:^store.Store,address:store.Hash,types:^Types,dependencies:^[dynamic]base.Asset_Id=nil) -> (header:Header,info:Import_Info,found:bool,error:Error) {
    a:Asset
    asset_open_object(&a,s,address,context.temp_allocator) or_return
    defer asset_close(&a)
    header=a.blob.header
    if dependencies!=nil {append(dependencies,..a.dependencies)}
    if .Cooked not_in header.flags {return header,{},false,.None}
    row:=import_info(&a,types) or_return
    if row==nil {return header,{},false,.None}
    return header,row^,true,.None
}

// The header of the stored asset, optionally copying its dependencies.
object_header :: proc(s:^store.Store,address:store.Hash,
    dependencies:^[dynamic]base.Asset_Id=nil) -> (header:Header,error:Error) {
    a:Asset
    asset_open_object(&a,s,address) or_return
    defer asset_close(&a)
    if dependencies!=nil {
        if _,no_room:=append(dependencies,..a.dependencies);no_room!=nil {return {},.Out_Of_Memory}
    }
    return a.blob.header,.None
}

// Whether the store holds every chunk. A batch that refreshed the index can reuse it.
object_whole :: proc(s:^store.Store,address:store.Hash,refresh:=true) -> bool {
    if !(store.chunk_has(s,address) if refresh else store.chunk_here(s,address)) {return false}
    o,error:=store.object_open(s,address)
    if error!=.None {return false}
    defer store.object_close(&o)
    walk :: proc(s:^store.Store,n:store.Node_View,buffer:[]u8) -> bool {
        if n.level==0 {
            for e in n.entries {
                if !store.chunk_here(s,e.address) {return false}
            }
            return true
        }
        for e in n.entries {
            bytes,read_error:=store.chunk_read(s,e.address,buffer[:store.CHUNK_MAX])
            if read_error!=.None {return false}
            child,parse_error:=store.node_parse(bytes)
            if parse_error!=.None || child.level!=n.level-1 {return false}
            if !walk(s,child,buffer[store.CHUNK_MAX:]) {return false}
        }
        return true
    }
    if o.root.level==0 {return walk(s,o.root,nil)}
    buffer,no_room:=mem.alloc_bytes_non_zeroed(o.root.level*store.CHUNK_MAX)
    if no_room!=nil {return false}
    defer delete(buffer)
    return walk(s,o.root,buffer)
}
