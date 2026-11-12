package asset

import "base:intrinsics"
import "base:runtime"
import "core:hash/xxhash"
import "core:mem"
import "compressor:data"
import "compressor:texture"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"

// The container every binary asset shares, little endian:
//
//   Header                       80 bytes
//   Chunk_Entry * chunk_count    the directory, right after the header
//   chunks                       each at a multiple of its alignment
//
// A chunk is stored as it is or as a stream (compress.odin). Reading the first bytes of
// a file is enough to know what it is, which asset it is and where each
// chunk lies; blob_open validates all of it before anything is used.

MAGIC :: u32('M')|u32('I')<<8|u32('R')<<16|u32('A')<<24
VERSION :: 3
HEADER_SIZE :: 80
CHUNK_ENTRY_SIZE :: 32
MAX_CHUNKS :: 1<<16
MAX_ALIGNMENT_LOG2 :: 12
// What the chunks of one file may take once decompressed, unless the caller says otherwise.
DEFAULT_MEMORY_LIMIT :: 4<<30

Fourcc :: distinct u32

fourcc :: proc "contextless" (text:string) -> Fourcc {
    value:u32
    for i in 0..<min(len(text),4) {value|=u32(text[i])<<(uint(i)*8)}
    for i in len(text)..<4 {value|=u32(' ')<<(uint(i)*8)}
    return Fourcc(value)
}
// The four characters, with anything that is not printable as '?'.
fourcc_text :: proc "contextless" (value:Fourcc,buffer:^[4]u8) -> string {
    for i in 0..<4 {
        c:=u8(u32(value)>>(uint(i)*8))
        buffer[i]=c>=0x20 && c<0x7f?c:'?'
    }
    return string(buffer[:])
}

// How a chunk is stored: as it is, or as a stream.
Compression :: enum u8 {None,Stream=2}

// The scratch of the decoders a read uses, of streams and of the layouts of blocks of textures.
// Whoever reads keeps one per thread and lends it to the assets it opens; an asset opened without
// one makes its own the first time it needs it.
Decoder :: struct {
    using stream:Stream_Decoder,
    layout:^texture.Layout_Decoder, // behind a pointer, as Stream_Decoder.data
    // With them, the pieces of a chunk decode at once on the workers of their job system: worker
    // is the one that reads with this decoder.
    pieces:^Piece_Decoders,
    worker:int,
}

decoder_init :: proc(d:^Decoder,allocator:=context.allocator) -> Error {
    d^={}
    stream_decoder_init(&d.stream,allocator) or_return
    allocation:mem.Allocator_Error
    if d.layout,allocation=new(texture.Layout_Decoder,allocator);allocation!=nil || texture.layout_decoder_init(d.layout,allocator)!=.None {
        free(d.layout,allocator)
        d.layout=nil
        decoder_destroy(d)
        return .Out_Of_Memory
    }
    return .None
}

decoder_destroy :: proc(d:^Decoder) {
    if d==nil || d.allocator.procedure==nil {return}
    if d.layout!=nil {
        texture.layout_decoder_destroy(d.layout)
        free(d.layout,d.allocator)
    }
    stream_decoder_destroy(&d.stream)
    d^={}
}

Header_Flag :: enum u32 {
    Cooked,   // built by an importer from a source file: edits belong in the source
    Prefab,   // a scene placed as instances, with exactly one root: what whoever made it chose, never derived from its entities
}
Header_Flags :: bit_set[Header_Flag;u32]

Header :: struct {
    magic:u32,
    kind:Fourcc,
    version:u16,      // of the container
    kind_version:u16, // of what the kind stores
    flags:Header_Flags,
    id:base.Asset_Id,
    owner:base.Asset_Id, // the asset it is a part of, which made it (the scene of an import); zero for one of its own
    chunk_count:u32,
    alignment:u32,    // the largest alignment of a chunk: a file held in memory aligned to it gives aligned chunks
    directory_offset:u64,
    total_size:u64,
    content_hash:u64, // XXH3-64 of everything after the header
}
#assert(size_of(Header)==HEADER_SIZE)

Chunk_Entry :: struct {
    tag:Fourcc,
    index:u16, // which one of its tag
    compression:Compression,
    alignment_log2:u8,
    offset:u64,
    size:u64,              // as stored
    uncompressed_size:u64,
}
#assert(size_of(Chunk_Entry)==CHUNK_ENTRY_SIZE)

Error :: enum u8 {
    None,
    Truncated,      // shorter than its header says, or than a header
    Not_An_Asset,   // another magic
    Version,        // a container or kind version this build does not read (kind_check)
    Corrupt,        // a directory, a chunk or a table that contradicts itself
    Hash,           // the content does not match its hash
    Too_Large,      // more memory than the limit of the caller
    Schema,         // the schema table is not valid
    Out_Of_Memory,
    Not_Found,      // no such file, table or column
    IO,             // a file could not be read or written
    Invalid,        // an argument that the format cannot hold
    Codec_Missing,  // a stream of a format the compressor of this build does not decode
}

Blob :: struct {
    data:[]u8,
    header:Header,
}

// The header at the start of data, checked on its own: what a scan needs.
header_read :: proc(data:[]u8) -> (header:Header,error:Error) {
    if len(data)<HEADER_SIZE {return {},.Truncated}
    header=intrinsics.unaligned_load((^Header)(raw_data(data)))
    if header.magic!=MAGIC {return {},.Not_An_Asset}
    if header.version!=VERSION {return header,.Version}
    directory_end:=header.directory_offset+u64(header.chunk_count)*CHUNK_ENTRY_SIZE
    if header.chunk_count>MAX_CHUNKS || header.directory_offset!=HEADER_SIZE || header.total_size<directory_end {return header,.Corrupt}
    if header.alignment==0 || header.alignment&(header.alignment-1)!=0 || header.alignment>1<<MAX_ALIGNMENT_LOG2 {return header,.Corrupt}
    return header,.None
}

// Writes owner into the header of a file held in data. The content and its
// hash do not change.
header_owner_set :: proc(data:[]u8,owner:base.Asset_Id) -> Error {
    header:=header_read(data) or_return
    header.owner=owner
    intrinsics.unaligned_store((^Header)(raw_data(data)),header)
    return .None
}

// Writes owner into the header of the asset file at path, whole or not at all.
file_owner_set :: proc(path:string,owner:base.Asset_Id) -> Error {
    data,read_error:=serial.file_read(path,context.temp_allocator)
    if read_error!=.None {return read_error==.Not_Found?.Not_Found:.IO}
    header_owner_set(data,owner) or_return
    return serial.file_write_atomic(path,data)==.None?.None:.IO
}

// One entry of the directory, checked against the file: inside it, aligned,
// and with a decompressed size a stream holds.
@(private)
chunk_entry_check :: proc(header:Header,entry:Chunk_Entry) -> bool {
    directory_end:=header.directory_offset+u64(header.chunk_count)*CHUNK_ENTRY_SIZE
    if entry.alignment_log2>MAX_ALIGNMENT_LOG2 || u32(1)<<entry.alignment_log2>header.alignment {return false}
    if entry.offset<directory_end || entry.offset>header.total_size || entry.size>header.total_size-entry.offset {return false}
    if entry.offset&(u64(1)<<entry.alignment_log2-1)!=0 {return false}
    switch entry.compression {
    case .None: return entry.uncompressed_size==entry.size
    case .Stream: return entry.uncompressed_size<PACK_MAX && entry.size>=STREAM_HEAD
    }
    return false
}

// The directory of the asset file at path whose first bytes are head, every
// entry checked against header: read from head, or from the file when it
// does not fit in it.
@(private)
directory_read :: proc(path:string,head:[]u8,header:Header,allocator:=context.allocator) -> (entries:[]Chunk_Entry,error:Error) {
    size:=int(header.chunk_count)*CHUNK_ENTRY_SIZE
    allocation:mem.Allocator_Error
    entries,allocation=make([]Chunk_Entry,int(header.chunk_count),allocator)
    if allocation!=nil {return nil,.Out_Of_Memory}
    target:=mem.slice_to_bytes(entries)
    if HEADER_SIZE+size<=len(head) {copy(target,head[HEADER_SIZE:])}
    else if serial.file_read_range(path,HEADER_SIZE,target)!=.None {
        delete(entries,allocator)
        return nil,.IO
    }
    for entry in entries {
        if !chunk_entry_check(header,entry) {
            delete(entries,allocator)
            return nil,.Corrupt
        }
    }
    return entries,.None
}

// Validates a whole file held in memory. limit: the most its chunks may take
// once decompressed.
blob_open :: proc(data:[]u8,limit:=u64(DEFAULT_MEMORY_LIMIT)) -> (blob:Blob,error:Error) {
    header:=header_read(data) or_return
    if header.total_size>u64(len(data)) {return {},.Truncated}
    if header.total_size<u64(len(data)) {return {},.Corrupt}
    blob={data=data,header=header}
    total:=u64(0)
    for i in 0..<int(header.chunk_count) {
        entry:=blob_chunk(&blob,i)
        if !chunk_entry_check(header,entry) {return {},.Corrupt}
        total+=entry.uncompressed_size
        if total>limit {return {},.Too_Large}
    }
    return blob,.None
}

blob_chunk :: #force_inline proc(blob:^Blob,index:int) -> Chunk_Entry {
    return intrinsics.unaligned_load((^Chunk_Entry)(raw_data(blob.data[HEADER_SIZE+index*CHUNK_ENTRY_SIZE:])))
}
blob_find :: proc(blob:^Blob,tag:Fourcc,index:=0) -> (chunk:int,found:bool) {
    for i in 0..<int(blob.header.chunk_count) {
        entry:=blob_chunk(blob,i)
        if entry.tag==tag && int(entry.index)==index {return i,true}
    }
    return -1,false
}
// The bytes of a chunk as the file stores them.
blob_stored :: proc(blob:^Blob,entry:Chunk_Entry) -> []u8 {
    return blob.data[entry.offset:][:entry.size]
}
// The content of a chunk, into dst of its uncompressed size, with the decoder of the reader.
blob_read :: proc(blob:^Blob,entry:Chunk_Entry,dst:[]u8,decoder:^Decoder) -> Error {
    if u64(len(dst))!=entry.uncompressed_size {return .Invalid}
    stored:=blob_stored(blob,entry)
    switch entry.compression {
    case .None:
        copy(dst,stored)
    case .Stream:
        if decoder==nil {return .Invalid}
        return stream_chunk(decoder,stored,dst)
    }
    return .None
}
blob_hash :: proc(data:[]u8) -> u64 {
    return len(data)>HEADER_SIZE?xxhash.XXH3_64_default(data[HEADER_SIZE:]):0
}
blob_verify_hash :: proc(blob:^Blob) -> bool {
    return blob_hash(blob.data)==blob.header.content_hash
}

// A chunk to store. Compression is kept only when it makes the chunk smaller.
Build_Chunk :: struct {
    tag:Fourcc,
    index:u16,
    alignment:int, // a power of two, up to 4096
    compression:Compression,
    data:[]u8,
}

// Writes a whole file into w, which has to be empty, compressed with profile as codecs allow.
// scratch holds a chunk while it is compressed.
blob_build :: proc(w:^serial.Writer,kind:Fourcc,kind_version:u16,id,owner:base.Asset_Id,flags:Header_Flags,chunks:[]Build_Chunk,scratch:^[dynamic]u8,profile:=data.Profile.Fast,codecs:=Codecs.Open,worker:=jobs.Worker_Ref{}) -> Error {
    if w.count!=0 || len(chunks)>MAX_CHUNKS {return .Invalid}
    encoder:Stream_Encoder
    if codecs!=.None {stream_encoder_init(&encoder,scratch.allocator if scratch.allocator.procedure!=nil else context.allocator) or_return}
    defer stream_encoder_destroy(&encoder)
    header:=Header{magic=MAGIC,kind=kind,version=VERSION,kind_version=kind_version,flags=flags,id=id,owner=owner,chunk_count=u32(len(chunks)),alignment=1,directory_offset=HEADER_SIZE}
    serial.write_zeros(w,HEADER_SIZE+len(chunks)*CHUNK_ENTRY_SIZE)
    for chunk,i in chunks {
        if chunk.alignment<=0 || chunk.alignment&(chunk.alignment-1)!=0 || chunk.alignment>1<<MAX_ALIGNMENT_LOG2 {return .Invalid}
        header.alignment=max(header.alignment,u32(chunk.alignment))
        serial.write_align(w,chunk.alignment)
        entry:=Chunk_Entry{tag=chunk.tag,index=chunk.index,alignment_log2=u8(intrinsics.count_trailing_zeros(u32(chunk.alignment))),offset=u64(w.count),size=u64(len(chunk.data)),uncompressed_size=u64(len(chunk.data))}
        stored:=chunk.data
        // Stored as they are, the bytes of a chunk are already what a stream of none would hold.
        if chunk.compression!=.None && codecs!=.None && len(chunk.data)>0 && len(chunk.data)<PACK_MAX {
            if resize(scratch,pack_bound(len(chunk.data)))!=nil {return .Out_Of_Memory}
            size:=pack(&encoder,profile,codecs,chunk.data,scratch[:],worker) or_return
            if size<len(chunk.data) {
                stored=scratch[:size]
                entry.compression,entry.size=.Stream,u64(size)
            }
        }
        serial.write_bytes(w,stored)
        if !serial.writer_patch(w,HEADER_SIZE+i*CHUNK_ENTRY_SIZE,mem.ptr_to_bytes(&entry)) {return .Out_Of_Memory}
    }
    if w.overflow!=0 {return .Out_Of_Memory}
    header.total_size=u64(w.count)
    header.content_hash=blob_hash(serial.writer_bytes(w))
    serial.writer_patch(w,0,mem.ptr_to_bytes(&header))
    return .None
}
