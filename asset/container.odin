package asset

import "base:intrinsics"
import "base:runtime"
import "core:hash/xxhash"
import "core:mem"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/compressor"
import "mirai:std/compressor/bc7split"
import "mirai:std/compressor/lz"
import "mirai:std/serial"

// The container every binary asset shares, little endian:
//
//   Header                       80 bytes
//   Chunk_Entry * chunk_count    the directory, right after the header
//   chunks                       each at a multiple of its alignment
//
// A chunk is stored as it is or as one LZ stream. Reading the first bytes of
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

Compression :: enum u8 {None,LZ}

// How hard a write compresses. A program writes with PACK_EDIT, in the time of a save or an
// import; a cook writes with the packs of cook/compressor/lz (SHIP and QUICK), which carry the
// parser of their levels: a game does not compile it.
Pack :: lz.Mode
PACK_EDIT :: Pack{level=compressor.LEVEL_SUPER_FAST}

// What the encoder takes in one call: a larger chunk is stored as it is.
@(private) PACK_MAX :: 1<<30
// A larger stream is written in pieces of this many raw bytes, each decoding without the others:
// those of a chunk decode at once on the workers of a Piece_Decoders.
PACK_PIECE :: 4<<20
@(private) PACK_MAX_PIECES :: PACK_MAX/PACK_PIECE
// The least a stream spends on each block it decodes: a block header and a quantum header with
// the byte of a memset.
@(private) PACK_BLOCK_MIN :: compressor.BLOCK_HEADER_SIZE+compressor.QUANTUM_HEADER_SIZE+1

// The scratch of the decoders a read uses, of LZ chunks and of BC7Split texels. Whoever reads
// keeps one per thread and lends it to the assets it opens; an asset opened without one makes its
// own the first time it needs it.
Decoder :: struct {
    lz:compressor.Decoder,
    bc7split:^bc7split.Decoder,
    allocator:runtime.Allocator,
    // With them, the pieces of a chunk decode at once on the workers of their job system: worker
    // is the one that reads with this decoder.
    pieces:^Piece_Decoders,
    worker:int,
}

// An LZ decoder for each worker of a job system, by worker index, that decodes pieces of
// chunks: made the first time its worker decodes one, kept until destroyed.
Piece_Decoders :: struct {
    system:^jobs.Job_System,
    decoders:[]compressor.Decoder,
    allocator:runtime.Allocator,
}

piece_decoders_init :: proc(p:^Piece_Decoders,system:^jobs.Job_System,allocator:=context.allocator) -> Error {
    p^={system=system,allocator=allocator}
    decoders,allocation:=make([]compressor.Decoder,jobs.worker_count(system),allocator)
    if allocation!=nil {return .Out_Of_Memory}
    p.decoders=decoders
    return .None
}

piece_decoders_destroy :: proc(p:^Piece_Decoders) {
    if p==nil || p.decoders==nil {return}
    for &d in p.decoders {compressor.decoder_destroy(&d)}
    delete(p.decoders,p.allocator)
    p^={}
}

decoder_init :: proc(d:^Decoder,allocator:=context.allocator) -> Error {
    d^={allocator=allocator}
    if compressor.decoder_init(&d.lz,allocator)!=.None {return .Out_Of_Memory}
    allocation:mem.Allocator_Error
    if d.bc7split,allocation=new(bc7split.Decoder,allocator);allocation!=nil {
        decoder_destroy(d)
        return .Out_Of_Memory
    }
    return .None
}

decoder_destroy :: proc(d:^Decoder) {
    if d==nil || d.allocator.procedure==nil {return}
    compressor.decoder_destroy(&d.lz)
    free(d.bc7split,d.allocator)
    d^={}
}

// The largest stream pack writes for size bytes.
pack_bound :: proc "contextless" (size:int) -> int {return lz.compress_bound(size)}

// src as an LZ stream into dst, of at least pack_bound bytes, with an encoder of the writer.
// With a worker of a job system the pieces of a larger src are compressed at once on its
// workers, into the same bytes.
pack :: proc(e:^lz.Encoder,p:Pack,src,dst:[]u8,worker:=jobs.Worker_Ref{}) -> (size:int,error:Error) {
    if len(src)>=PACK_MAX {return 0,.Too_Large}
    if worker.system!=nil && len(src)>PACK_PIECE {return pack_pieces(p,src,dst,worker)}
    written,encode_error:=lz.compress(e,p,src,dst,PACK_PIECE)
    switch encode_error {
    case .None:
    case .Out_Of_Memory: return 0,.Out_Of_Memory
    case .Output_Too_Small,.Invalid: return 0,.Invalid
    }
    return written,.None
}

@(private="file")
Pack_Pieces :: struct {
    pack:Pack,
    src:[]u8,
    out:[][]u8,
    sizes:[]int,
    errors:[]lz.Error,
}

// The pieces of src compressed on the workers of worker, each with an encoder of its own, then
// put in order into dst.
@(private="file")
pack_pieces :: proc(p:Pack,src,dst:[]u8,worker:jobs.Worker_Ref) -> (size:int,error:Error) {
    heap:=runtime.heap_allocator()
    count:=(len(src)+PACK_PIECE-1)/PACK_PIECE
    work:=Pack_Pieces{pack=p,src=src}
    a,b,c:mem.Allocator_Error
    work.out,a=make([][]u8,count,heap)
    work.sizes,b=make([]int,count,heap)
    work.errors,c=make([]lz.Error,count,heap)
    defer {
        for out in work.out {delete(out,heap)}
        delete(work.out,heap);delete(work.sizes,heap);delete(work.errors,heap)
    }
    if a!=nil || b!=nil || c!=nil {return 0,.Out_Of_Memory}
    piece :: proc(work:^Pack_Pieces,first,last:int,worker:int) {
        heap:=runtime.heap_allocator()
        for i in first..<last {
            from:=work.src[i*PACK_PIECE:min(len(work.src),(i+1)*PACK_PIECE)]
            out,failed:=make([]u8,lz.compress_bound(len(from)),heap)
            if failed!=nil {work.errors[i]=.Out_Of_Memory;continue}
            work.out[i]=out
            e:lz.Encoder
            lz.encoder_init(&e,heap)
            work.sizes[i],work.errors[i]=lz.compress_piece(&e,work.pack,from,out)
            lz.encoder_destroy(&e)
        }
    }
    jobs.parallel_for(worker.system,worker.worker,count,1,piece,&work)
    for i in 0..<count {
        #partial switch work.errors[i] {
        case .None:
        case .Out_Of_Memory: return 0,.Out_Of_Memory
        case: return 0,.Invalid
        }
        if work.sizes[i]>len(dst)-size {return 0,.Invalid}
        size+=copy(dst[size:],work.out[i][:work.sizes[i]])
    }
    return size,.None
}

// An LZ stream of src into all of dst, which is its decoded size.
unpack :: proc(d:^compressor.Decoder,src,dst:[]u8) -> Error {
    if d==nil {return .Invalid}
    if u64(len(dst))>pack_reach(u64(len(src))) {return .Corrupt}
    written,error:=compressor.decompress(d,src,dst)
    #partial switch error {
    case .None: return written==len(dst)?.None:.Corrupt
    case .Out_Of_Memory: return .Out_Of_Memory
    }
    return .Corrupt
}

// unpack of a chunk, whose pieces decode at once with the piece decoders of d.
@(private)
unpack_chunk :: proc(d:^Decoder,src,dst:[]u8) -> Error {
    if d.pieces==nil || len(dst)<=PACK_PIECE || d.worker<0 || d.worker>=len(d.pieces.decoders) {return unpack(&d.lz,src,dst)}
    if u64(len(dst))>pack_reach(u64(len(src))) {return .Corrupt}
    found:[PACK_MAX_PIECES]compressor.Piece
    count,error:=compressor.pieces(src,len(dst),found[:])
    if error!=.None {return .Corrupt}
    if count<=1 {return unpack(&d.lz,src,dst)}
    // Pieces past those it holds decode with the last.
    work:=Piece_Work{src=src,dst=dst,pieces=found[:min(count,len(found))],decoders=d.pieces}
    jobs.parallel_for(d.pieces.system,d.worker,len(work.pieces),1,piece_decode,&work)
    return work.error
}

@(private)
Piece_Work :: struct {
    src,dst:[]u8,
    pieces:[]compressor.Piece,
    decoders:^Piece_Decoders,
    error:Error,
}

@(private)
piece_decode :: proc(work:^Piece_Work,first,last:int,worker:int) {
    d:=&work.decoders.decoders[worker]
    if d.scratch==nil && compressor.decoder_init(d,work.decoders.allocator)!=.None {
        intrinsics.atomic_store(&work.error,Error.Out_Of_Memory)
        return
    }
    for i in first..<last {
        piece:=work.pieces[i]
        src_end,dst_end:=len(work.src),len(work.dst)
        if i+1<len(work.pieces) {src_end,dst_end=work.pieces[i+1].src,work.pieces[i+1].dst}
        written,error:=compressor.decompress(d,work.src[piece.src:src_end],work.dst[piece.dst:dst_end])
        if error!=.None || written!=dst_end-piece.dst {intrinsics.atomic_store(&work.error,Error.Corrupt)}
    }
}

// The most an LZ stream of size bytes decodes to.
@(private)
pack_reach :: proc "contextless" (size:u64) -> u64 {return size/PACK_BLOCK_MIN*compressor.BLOCK_LEN}

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
// and with a decompressed size that an LZ stream of its size can reach.
@(private)
chunk_entry_check :: proc(header:Header,entry:Chunk_Entry) -> bool {
    directory_end:=header.directory_offset+u64(header.chunk_count)*CHUNK_ENTRY_SIZE
    if entry.alignment_log2>MAX_ALIGNMENT_LOG2 || u32(1)<<entry.alignment_log2>header.alignment {return false}
    if entry.offset<directory_end || entry.offset>header.total_size || entry.size>header.total_size-entry.offset {return false}
    if entry.offset&(u64(1)<<entry.alignment_log2-1)!=0 {return false}
    switch entry.compression {
    case .None: return entry.uncompressed_size==entry.size
    case .LZ: return entry.uncompressed_size<=pack_reach(entry.size) && entry.uncompressed_size<PACK_MAX
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
    case .LZ:
        if decoder==nil {return .Invalid}
        return unpack_chunk(decoder,stored,dst)
    }
    return .None
}
blob_hash :: proc(data:[]u8) -> u64 {
    return len(data)>HEADER_SIZE?xxhash.XXH3_64_default(data[HEADER_SIZE:]):0
}
blob_verify_hash :: proc(blob:^Blob) -> bool {
    return blob_hash(blob.data)==blob.header.content_hash
}

// A chunk to store. LZ is kept only when it makes the chunk smaller.
Build_Chunk :: struct {
    tag:Fourcc,
    index:u16,
    alignment:int, // a power of two, up to 4096
    compression:Compression,
    data:[]u8,
}

// Writes a whole file into w, which has to be empty. scratch holds a chunk
// while it is compressed.
blob_build :: proc(w:^serial.Writer,kind:Fourcc,kind_version:u16,id,owner:base.Asset_Id,flags:Header_Flags,chunks:[]Build_Chunk,scratch:^[dynamic]u8,p:=PACK_EDIT,worker:=jobs.Worker_Ref{}) -> Error {
    encoder:lz.Encoder
    lz.encoder_init(&encoder,scratch.allocator if scratch.allocator.procedure!=nil else context.allocator)
    defer lz.encoder_destroy(&encoder)
    if w.count!=0 || len(chunks)>MAX_CHUNKS {return .Invalid}
    header:=Header{magic=MAGIC,kind=kind,version=VERSION,kind_version=kind_version,flags=flags,id=id,owner=owner,chunk_count=u32(len(chunks)),alignment=1,directory_offset=HEADER_SIZE}
    serial.write_zeros(w,HEADER_SIZE+len(chunks)*CHUNK_ENTRY_SIZE)
    for chunk,i in chunks {
        if chunk.alignment<=0 || chunk.alignment&(chunk.alignment-1)!=0 || chunk.alignment>1<<MAX_ALIGNMENT_LOG2 {return .Invalid}
        header.alignment=max(header.alignment,u32(chunk.alignment))
        serial.write_align(w,chunk.alignment)
        entry:=Chunk_Entry{tag=chunk.tag,index=chunk.index,alignment_log2=u8(intrinsics.count_trailing_zeros(u32(chunk.alignment))),offset=u64(w.count),size=u64(len(chunk.data)),uncompressed_size=u64(len(chunk.data))}
        stored:=chunk.data
        if chunk.compression==.LZ && len(chunk.data)>0 && len(chunk.data)<PACK_MAX {
            if resize(scratch,pack_bound(len(chunk.data)))!=nil {return .Out_Of_Memory}
            size:=pack(&encoder,p,chunk.data,scratch[:],worker) or_return
            if size<len(chunk.data) {
                stored=scratch[:size]
                entry.compression,entry.size=.LZ,u64(size)
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
