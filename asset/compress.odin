package asset

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:strings"
import "compressor:data"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"

// What a write may compress with, as the project of what it writes allows (build.compression).
// Types.codecs says it for the documents made with them.
Codecs :: enum u8 {
    Open, // the formats of the open compressor, which every build reads
    Best, // the best the compressor of this build has
    None, // nothing is compressed
}

// What the assets of the project at root, built with the engine at engine_root, are compressed
// with (build.compression): Best only where the games of that engine have the private compressor,
// since what a game does not decode it cannot ship. A folder without a project, as the assets of
// the engine and of its plugins: Open.
project_codecs :: proc(root,engine_root:string) -> Codecs {
    m,error:=project.manifest_read(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator))
    if error.code!=.None {return .Open}
    switch base.text_get(m.build.compression[:]) {
    case project.COMPRESSION_NONE: return .None
    case project.COMPRESSION_OPEN: return .Open
    }
    _,private:=project.compressor_folder(engine_root,context.temp_allocator)
    return .Best if private else .Open
}

// What a write of what streams while playing compresses with in place of profile.
profile_streamed :: proc "contextless" (profile:data.Profile) -> data.Profile {return .Speed if profile==.Ultra else profile}

// A stream: what a chunk that compresses stores, and each block of a table of blocks.
//
//   u8 STREAM_VERSION
//   u32 the format of its pieces (data.Format; STORED: the bytes as they are)
//   u32 count of pieces, u32 stored size of each
//   the pieces, each PACK_PIECE raw bytes but the last, decoding without the others; one when STORED
STREAM_VERSION :: 0
@(private) STREAM_HEAD :: 9
STORED :: data.Format(u32('N')|u32('O')<<8|u32('N')<<16|u32('E')<<24)

// What a stream takes: a larger chunk is stored as it is.
@(private) PACK_MAX :: 1<<30
// A larger stream is written in pieces of this many raw bytes, each decoding without the others:
// those of a chunk decode at once on the workers of a Piece_Decoders.
PACK_PIECE :: 4<<20
@(private) PACK_MAX_PIECES :: PACK_MAX/PACK_PIECE

// The scratch of the reads of streams of one thread. The decoder of the compressor is behind a
// pointer: its size is that of the compressor a binary was built with, which programs that share
// this type may not share.
Stream_Decoder :: struct {
    data:^data.Decoder,
    allocator:runtime.Allocator,
}

stream_decoder_init :: proc(d:^Stream_Decoder,allocator:=context.allocator) -> Error {
    d^={allocator=allocator}
    made,allocation:=new(data.Decoder,allocator)
    if allocation!=nil {return .Out_Of_Memory}
    if data.decoder_init(made,allocator)!=.None {
        free(made,allocator)
        return .Out_Of_Memory
    }
    d.data=made
    return .None
}

stream_decoder_destroy :: proc(d:^Stream_Decoder) {
    if d==nil || d.data==nil {return}
    data.decoder_destroy(d.data)
    free(d.data,d.allocator)
    d^={}
}

// The scratch of the writes of streams of one thread, as Stream_Decoder.
Stream_Encoder :: struct {
    data:^data.Encoder,
    allocator:runtime.Allocator,
}

stream_encoder_init :: proc(e:^Stream_Encoder,allocator:=context.allocator) -> Error {
    e^={allocator=allocator}
    made,allocation:=new(data.Encoder,allocator)
    if allocation!=nil {return .Out_Of_Memory}
    if data.encoder_init(made,allocator)!=.None {
        free(made,allocator)
        return .Out_Of_Memory
    }
    e.data=made
    return .None
}

stream_encoder_destroy :: proc(e:^Stream_Encoder) {
    if e==nil || e.data==nil {return}
    data.encoder_destroy(e.data)
    free(e.data,e.allocator)
    e^={}
}

@(private)
u32_read :: #force_inline proc "contextless" (p:[^]u8) -> u32 {
    return u32(p[0])|u32(p[1])<<8|u32(p[2])<<16|u32(p[3])<<24
}

@(private)
u32_write :: #force_inline proc "contextless" (p:[^]u8,value:u32) {
    p[0],p[1],p[2],p[3]=u8(value),u8(value>>8),u8(value>>16),u8(value>>24)
}

@(private)
stream_head_write :: proc "contextless" (dst:[]u8,format:data.Format,count:int) {
    dst[0]=STREAM_VERSION
    u32_write(&dst[1],u32(format))
    u32_write(&dst[5],u32(count))
}

@(private)
stream_pieces :: proc "contextless" (size:int) -> int {return max((size+PACK_PIECE-1)/PACK_PIECE,1)}

@(private)
error_of :: proc "contextless" (error:data.Error) -> Error {
    switch error {
    case .None: return .None
    case .Unknown_Format: return .Codec_Missing
    case .Corrupt: return .Corrupt
    case .Out_Of_Memory: return .Out_Of_Memory
    case .Too_Large: return .Too_Large
    case .Output_Too_Small: return .Invalid
    }
    return .Invalid
}

// The format of the pieces a write with profile and codecs makes.
stream_format :: proc "contextless" (profile:data.Profile,codecs:Codecs) -> data.Format {
    return STORED if codecs==.None else data.format(profile,codecs==.Open)
}

// The largest stream pack writes for size bytes.
pack_bound :: proc "contextless" (size:int) -> int {
    if size<0 {return 0}
    count:=stream_pieces(size)
    total:=STREAM_HEAD+count*4
    for piece in 0..<count {
        raw:=min(size-piece*PACK_PIECE,PACK_PIECE)
        total+=max(data.bound(raw),raw)
    }
    return max(total,STREAM_HEAD+4+size)
}

// src as a stream into dst, of at least pack_bound bytes, with the encoder of the writer. With a
// worker of a job system the pieces are compressed at once on its workers, into the same bytes.
pack :: proc(e:^Stream_Encoder,profile:data.Profile,codecs:Codecs,src,dst:[]u8,worker:=jobs.Worker_Ref{}) -> (size:int,error:Error) {
    if len(src)>=PACK_MAX {return 0,.Too_Large}
    if len(dst)<pack_bound(len(src)) {return 0,.Invalid}
    format:=stream_format(profile,codecs)
    if format==STORED {
        stream_head_write(dst,STORED,1)
        u32_write(&dst[STREAM_HEAD],u32(len(src)))
        copy(dst[STREAM_HEAD+4:],src)
        return STREAM_HEAD+4+len(src),.None
    }
    if e==nil || e.data==nil {return 0,.Invalid}
    count:=stream_pieces(len(src))
    stream_head_write(dst,format,count)
    at:=STREAM_HEAD+count*4
    if worker.system==nil || count==1 {
        for piece in 0..<count {
            from:=src[piece*PACK_PIECE:min(len(src),(piece+1)*PACK_PIECE)]
            written,encode_error:=data.encode(e.data,profile,from,dst[at:],codecs==.Open)
            if encode_error!=.None {return 0,error_of(encode_error)}
            u32_write(&dst[STREAM_HEAD+piece*4],u32(written))
            at+=written
        }
        return at,.None
    }
    heap:=runtime.heap_allocator()
    work:=Pack_Work{profile=profile,open=codecs==.Open,src=src}
    a,b,c:mem.Allocator_Error
    work.out,a=make([][]u8,count,heap)
    work.sizes,b=make([]int,count,heap)
    work.errors,c=make([]data.Error,count,heap)
    defer {
        for out in work.out {delete(out,heap)}
        delete(work.out,heap);delete(work.sizes,heap);delete(work.errors,heap)
    }
    if a!=nil || b!=nil || c!=nil {return 0,.Out_Of_Memory}
    jobs.parallel_for(worker.system,worker.worker,count,1,piece_pack,&work)
    for piece in 0..<count {
        if work.errors[piece]!=.None {return 0,error_of(work.errors[piece])}
        if work.sizes[piece]>len(dst)-at {return 0,.Invalid}
        u32_write(&dst[STREAM_HEAD+piece*4],u32(work.sizes[piece]))
        at+=copy(dst[at:],work.out[piece][:work.sizes[piece]])
    }
    return at,.None
}

@(private="file")
Pack_Work :: struct {
    profile:data.Profile,
    open:bool,
    src:[]u8,
    out:[][]u8,
    sizes:[]int,
    errors:[]data.Error,
}

// The pieces of a stream compressed on the workers of a job system, each with an encoder of its
// own, from the heap.
@(private="file")
piece_pack :: proc(work:^Pack_Work,first,last:int,worker:int) {
    heap:=runtime.heap_allocator()
    e:data.Encoder
    if error:=data.encoder_init(&e,heap);error!=.None {
        for piece in first..<last {work.errors[piece]=error}
        return
    }
    defer data.encoder_destroy(&e)
    for piece in first..<last {
        from:=work.src[piece*PACK_PIECE:min(len(work.src),(piece+1)*PACK_PIECE)]
        out,failed:=make([]u8,data.bound(len(from)),heap)
        if failed!=nil {work.errors[piece]=.Out_Of_Memory;continue}
        work.out[piece]=out
        work.sizes[piece],work.errors[piece]=data.encode(&e,work.profile,from,out,work.open)
    }
}

// Whether block is a stream a write with profile and codecs would make, so that the write may
// keep it as it is.
pack_matches :: proc "contextless" (block:[]u8,profile:data.Profile,codecs:Codecs) -> bool {
    return len(block)>=STREAM_HEAD && block[0]==STREAM_VERSION && data.Format(u32_read(&block[1]))==stream_format(profile,codecs)
}

// A run of pages of a table of `<name>_pages` over the bytes of the table `<name>_blocks`: what a
// kind of asset stores in blocks it reads alone, and that a cook compresses again as its project
// says. count pages that hold fill alone, or one page with its block.
Block_Record :: struct {
    count:u32,
    fill:u32,
    offset:u64,
    size:u64,  // of the block; 0: none
    hash:u64,  // base.hash64 of the block
    raw:u32,   // of the block once decoded
}

// The blocks of the block tables of a document compressed again as the profile of what streams
// and codecs say.
@(private)
document_blocks_repack :: proc(doc:^Document,profile:data.Profile,codecs:Codecs) -> Error {
    PAGES :: "_pages"
    for &table in doc.tables {
        if !strings.has_suffix(table.name,PAGES) || len(table.columns)!=1 || table.columns[0].size!=size_of(Block_Record) {continue}
        blocks_name:=strings.concatenate({table.name[:len(table.name)-len(PAGES)],"_blocks"},context.temp_allocator)
        blocks_table,found:=document_table(doc,blocks_name)
        if !found || len(doc.tables[blocks_table].columns)!=1 || doc.tables[blocks_table].columns[0].size!=1 {continue}
        records:=mem.slice_data_cast([]Block_Record,table.columns[0].data)
        old:=doc.tables[blocks_table].columns[0].data
        largest:=0
        for record in records {
            if record.size==0 {continue}
            if record.offset>u64(len(old)) || record.size>u64(len(old))-record.offset || int(record.raw)>=PACK_MAX {return .Corrupt}
            largest=max(largest,int(record.raw))
        }
        if largest==0 {continue}
        streamed:=profile_streamed(profile)
        encoder:Stream_Encoder
        stream_encoder_init(&encoder,context.temp_allocator) or_return
        defer stream_encoder_destroy(&encoder)
        decoder:Stream_Decoder
        stream_decoder_init(&decoder,context.temp_allocator) or_return
        defer stream_decoder_destroy(&decoder)
        raw:=make([]u8,largest,context.temp_allocator)
        blocks:=make([dynamic]u8,0,len(old),context.temp_allocator)
        if raw==nil || blocks==nil {return .Out_Of_Memory}
        for &record in records {
            if record.size==0 {continue}
            at:=len(blocks)
            unpack(&decoder,old[record.offset:][:record.size],raw[:record.raw]) or_return
            if resize(&blocks,at+pack_bound(int(record.raw)))!=nil {return .Out_Of_Memory}
            size:=pack(&encoder,streamed,codecs,raw[:record.raw],blocks[at:]) or_return
            resize(&blocks,at+size)
            record.offset,record.size,record.hash=u64(at),u64(size),base.hash64(blocks[at:])
        }
        document_resize(doc,blocks_table,len(blocks)) or_return
        copy(doc.tables[blocks_table].columns[0].data,blocks[:])
    }
    return .None
}

// A stream into all of dst, which is its decoded size.
unpack :: proc(d:^Stream_Decoder,src,dst:[]u8) -> Error {
    if d==nil {return .Invalid}
    return stream_unpack(d,src,dst,len(dst))
}

@(private)
Stream :: struct {
    format:data.Format,
    count:int,
    table:[^]u8, // of count sizes
    first:int,   // where the first piece starts
}

@(private)
stream_read :: proc "contextless" (src:[]u8,total:int) -> (s:Stream,error:Error) {
    if len(src)<STREAM_HEAD || src[0]!=STREAM_VERSION || total<0 || total>=PACK_MAX {return {},.Corrupt}
    s.format=data.Format(u32_read(&src[1]))
    s.count=int(u32_read(&src[5]))
    if s.count!=(1 if s.format==STORED else stream_pieces(total)) {return {},.Corrupt}
    s.first=STREAM_HEAD+s.count*4
    if s.first>len(src) {return {},.Corrupt}
    s.table=([^]u8)(&src[STREAM_HEAD])
    sum:=u64(s.first)
    for piece in 0..<s.count {sum+=u64(u32_read(s.table[piece*4:]))}
    if sum!=u64(len(src)) {return {},.Corrupt}
    return s,.None
}

// The pieces of a stream of total raw bytes that dst holds whole, from the first.
@(private)
stream_unpack :: proc(d:^Stream_Decoder,src,dst:[]u8,total:int) -> Error {
    s:=stream_read(src,total) or_return
    if len(dst)>total {return .Invalid}
    if s.format==STORED {
        if len(src)-s.first!=total {return .Corrupt}
        copy(dst,src[s.first:])
        return .None
    }
    if d.data==nil {return .Invalid}
    at:=s.first
    for piece in 0..<s.count {
        raw:=min(total-piece*PACK_PIECE,PACK_PIECE)
        if piece*PACK_PIECE+raw>len(dst) {break}
        size:=int(u32_read(s.table[piece*4:]))
        if raw>0 {
            if error:=data.decode(d.data,s.format,src[at:][:size],dst[piece*PACK_PIECE:][:raw]);error!=.None {return error_of(error)}
        }
        at+=size
    }
    return .None
}

// A decoder for each worker of a job system, by worker index, that decodes pieces of
// chunks: made the first time its worker decodes one, kept until destroyed.
Piece_Decoders :: struct {
    system:^jobs.Job_System,
    decoders:[]Stream_Decoder,
    allocator:runtime.Allocator,
}

piece_decoders_init :: proc(p:^Piece_Decoders,system:^jobs.Job_System,allocator:=context.allocator) -> Error {
    p^={system=system,allocator=allocator}
    decoders,allocation:=make([]Stream_Decoder,jobs.worker_count(system),allocator)
    if allocation!=nil {return .Out_Of_Memory}
    p.decoders=decoders
    return .None
}

piece_decoders_destroy :: proc(p:^Piece_Decoders) {
    if p==nil || p.decoders==nil {return}
    for &d in p.decoders {stream_decoder_destroy(&d)}
    delete(p.decoders,p.allocator)
    p^={}
}

// A chunk that is a stream, its pieces at once with the piece decoders of d.
@(private)
stream_chunk :: proc(d:^Decoder,src,dst:[]u8) -> Error {
    s:=stream_read(src,len(dst)) or_return
    if d.pieces==nil || s.count<=1 || d.worker<0 || d.worker>=len(d.pieces.decoders) {return stream_unpack(&d.stream,src,dst,len(dst))}
    work:=Stream_Work{src=src,dst=dst,decoders=d.pieces}
    at:=s.first
    for piece in 0..<s.count {
        work.starts[piece]=at
        at+=int(u32_read(s.table[piece*4:]))
    }
    work.starts[s.count]=at
    work.stream=s
    jobs.parallel_for(d.pieces.system,d.worker,s.count,1,stream_piece_decode,&work)
    return work.error
}

@(private="file")
Stream_Work :: struct {
    src,dst:[]u8,
    stream:Stream,
    starts:[PACK_MAX_PIECES+1]int,
    decoders:^Piece_Decoders,
    error:Error,
}

@(private="file")
stream_piece_decode :: proc(work:^Stream_Work,first,last:int,worker:int) {
    d:=&work.decoders.decoders[worker]
    if d.data==nil && stream_decoder_init(d,work.decoders.allocator)!=.None {
        intrinsics.atomic_store(&work.error,Error.Out_Of_Memory)
        return
    }
    for piece in first..<last {
        raw:=min(len(work.dst)-piece*PACK_PIECE,PACK_PIECE)
        error:=data.decode(d.data,work.stream.format,work.src[work.starts[piece]:work.starts[piece+1]],work.dst[piece*PACK_PIECE:][:raw])
        if error!=.None {intrinsics.atomic_store(&work.error,error_of(error))}
    }
}
