package asset

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:strings"
import "mirai:std/base"
import "mirai:std/codec"
import "mirai:std/compressor"
import "mirai:std/compressor/lz"
import "mirai:std/jobs"

// Whether this program holds the private LZ and BC7Split: a checkout with them, unless the game
// is built without them, and then nothing of the two reaches its binary.
ASSET_LZ :: compressor.IMPLEMENTED && #config(ASSET_LZ,true)

// What a chunk that compresses is stored as, when nothing else is asked for.
COMPRESSION_PACKED :: Compression.LZ when ASSET_LZ else Compression.Codec

// What a stream that is not LZ looks like. An LZ stream never starts with STREAM_ESCAPE:
//
//   STREAM_ESCAPE, then the id of the codec (CODEC_NONE: the bytes as they are)
//   u32 count of pieces, u32 stored size of each
//   the pieces, each PACK_PIECE raw bytes but the last, decoding without the others
//
// A stream says what decodes it, so what stores blocks outside a chunk keeps its format.
@(private) STREAM_ESCAPE :: u8(0)
@(private) STREAM_HEAD :: 9
CODEC_NONE :: codec.Id(u32('N')|u32('O')<<8|u32('N')<<16|u32('E')<<24)

// What a write compresses with in place of LZ: a cook that ships with something else.
Pack_Codecs :: struct {
    none:bool, // nothing is compressed
    general,streamed:codec.Encode,
}

// The scratch of the decoders of the streams of one thread.
Stream_Decoder :: struct {
    lz:compressor.Decoder,
    codecs:^codec.Table,
    scratch:[codec.MAX+OPEN_COUNT]rawptr, // of each of codecs and of the open ones after them, made the first time it decodes
    made:bool,
}

stream_decoder_init :: proc(d:^Stream_Decoder,allocator:=context.allocator,codecs:^codec.Table=nil) -> Error {
    d^={codecs=codecs,made=true}
    when ASSET_LZ {
        if compressor.decoder_init(&d.lz,allocator)!=.None {
            d^={}
            return .Out_Of_Memory
        }
    }
    return .None
}

stream_decoder_destroy :: proc(d:^Stream_Decoder) {
    if d==nil || !d.made {return}
    when ASSET_LZ {compressor.decoder_destroy(&d.lz)}
    if d.codecs!=nil {
        for i in 0..<min(d.codecs.count,codec.MAX) {
            if d.scratch[i]!=nil && d.codecs.list[i].scratch_free!=nil {d.codecs.list[i].scratch_free(d.scratch[i])}
        }
    }
    when ASSET_OPEN {
        open:=open_decoders()
        for i in 0..<open.count {
            if d.scratch[codec.MAX+i]!=nil && open.list[i].scratch_free!=nil {open.list[i].scratch_free(d.scratch[codec.MAX+i])}
        }
    }
    d^={}
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
stream_head_write :: proc "contextless" (dst:[]u8,id:codec.Id,count:int) {
    dst[0]=STREAM_ESCAPE
    u32_write(&dst[1],u32(id))
    u32_write(&dst[5],u32(count))
}

@(private)
stream_pieces :: proc "contextless" (size:int) -> int {return max((size+PACK_PIECE-1)/PACK_PIECE,1)}

// The bytes of src as they are, as a stream into dst, of at least stream_store_bound bytes.
@(private)
stream_store_bound :: proc "contextless" (size:int) -> int {return STREAM_HEAD+4+size}

@(private)
stream_store :: proc "contextless" (src,dst:[]u8) -> int {
    stream_head_write(dst,CODEC_NONE,1)
    u32_write(&dst[STREAM_HEAD],u32(len(src)))
    copy(dst[STREAM_HEAD+4:],src)
    return STREAM_HEAD+4+len(src)
}

// The largest stream codec_pack writes for size bytes.
codec_pack_bound :: proc(e:^codec.Encode,size:int) -> int {
    count:=stream_pieces(size)
    total:=STREAM_HEAD+count*4
    for piece in 0..<count {total+=int(e.bound(uint(min(size-piece*PACK_PIECE,PACK_PIECE))))}
    return total
}

// The level of a codec that stands for a pack, which names its own by a level of LZ: those of a
// cook are the optimal ones, the highest to ship.
@(private)
codec_level :: proc "contextless" (e:^codec.Encode,p:Pack) -> i32 {
    switch {
    case p.level>=compressor.LEVEL_OPTIMAL5: return e.ship
    case p.level>=compressor.LEVEL_OPTIMAL1: return e.quick
    }
    return e.edit
}

// src as a stream of a codec into dst, of at least codec_pack_bound bytes. With a worker of a job
// system the pieces are compressed at once on its workers, into the same bytes.
codec_pack :: proc(e:^codec.Encode,p:Pack,src,dst:[]u8,worker:=jobs.Worker_Ref{}) -> (size:int,error:Error) {
    count:=stream_pieces(len(src))
    if len(dst)<STREAM_HEAD+count*4 || e==nil || e.encode==nil || len(src)>=PACK_MAX {return 0,.Invalid}
    stream_head_write(dst,e.id,count)
    at:=STREAM_HEAD+count*4
    level:=codec_level(e,p)
    if worker.system==nil || count==1 {
        for piece in 0..<count {
            from:=src[piece*PACK_PIECE:min(len(src),(piece+1)*PACK_PIECE)]
            capacity:=len(dst)-at
            written:=int(e.encode(level,raw_data(from),uint(len(from)),raw_data(dst[at:]),uint(capacity)))
            if written==0 && len(from)>0 {return 0,.Invalid}
            u32_write(&dst[STREAM_HEAD+piece*4],u32(written))
            at+=written
        }
        return at,.None
    }
    heap:=runtime.heap_allocator()
    work:=Codec_Pack{e=e,level=level,src=src}
    a,b:mem.Allocator_Error
    work.out,a=make([][]u8,count,heap)
    work.sizes,b=make([]int,count,heap)
    defer {
        for out in work.out {delete(out,heap)}
        delete(work.out,heap);delete(work.sizes,heap)
    }
    if a!=nil || b!=nil {return 0,.Out_Of_Memory}
    jobs.parallel_for(worker.system,worker.worker,count,1,codec_piece_pack,&work)
    for piece in 0..<count {
        if work.sizes[piece]<0 {return 0,.Out_Of_Memory}
        if work.sizes[piece]==0 || work.sizes[piece]>len(dst)-at {return 0,.Invalid}
        u32_write(&dst[STREAM_HEAD+piece*4],u32(work.sizes[piece]))
        at+=copy(dst[at:],work.out[piece][:work.sizes[piece]])
    }
    return at,.None
}

@(private="file")
Codec_Pack :: struct {
    e:^codec.Encode,
    level:i32,
    src:[]u8,
    out:[][]u8,
    sizes:[]int, // -1: no memory
}

@(private="file")
codec_piece_pack :: proc(work:^Codec_Pack,first,last:int,worker:int) {
    heap:=runtime.heap_allocator()
    for piece in first..<last {
        from:=work.src[piece*PACK_PIECE:min(len(work.src),(piece+1)*PACK_PIECE)]
        out,failed:=make([]u8,int(work.e.bound(uint(len(from)))),heap)
        if failed!=nil {work.sizes[piece]=-1;continue}
        work.out[piece]=out
        work.sizes[piece]=int(work.e.encode(work.level,raw_data(from),uint(len(from)),raw_data(out),uint(len(out))))
    }
}

// The largest block_pack writes for size bytes.
block_bound :: proc(codecs:^Pack_Codecs,size:int,general:=false) -> int {
    if codecs==nil {
        when ASSET_LZ {
            return pack_bound(size)
        } else when ASSET_OPEN {
            e:=open_general() if general else open_streamed()
            return codec_pack_bound(&e,size)
        } else {
            return stream_store_bound(size)
        }
    }
    if codecs.none {return stream_store_bound(size)}
    return codec_pack_bound(&codecs.general if general else &codecs.streamed,size)
}

// A block as codecs say: LZ when there are none and the program has it. general: of what loads
// once, or travels, rather than of what streams while playing.
block_pack :: proc(encoder:^lz.Encoder,p:Pack,codecs:^Pack_Codecs,src,dst:[]u8,general:=false,worker:=jobs.Worker_Ref{}) -> (size:int,error:Error) {
    if codecs==nil {
        when ASSET_LZ {
            return pack(encoder,p,src,dst,worker)
        } else when ASSET_OPEN {
            e:=open_general() if general else open_streamed()
            return codec_pack(&e,p,src,dst,worker)
        } else {
            return stream_store(src,dst),.None
        }
    }
    if codecs.none {return stream_store(src,dst),.None}
    return codec_pack(&codecs.general if general else &codecs.streamed,p,src,dst,worker)
}

// What writes blocks at run time, as block_pack: the LZ encoder is made only in a program with LZ.
Block_Encoder :: struct {
    lz:lz.Encoder,
    codecs:^Pack_Codecs,
}

block_encoder_init :: proc(e:^Block_Encoder,allocator:=context.allocator,codecs:^Pack_Codecs=nil) {
    e^={codecs=codecs}
    when ASSET_LZ {lz.encoder_init(&e.lz,allocator)}
}

block_encoder_destroy :: proc(e:^Block_Encoder) {
    when ASSET_LZ {lz.encoder_destroy(&e.lz)}
    e^={}
}

block_encode :: proc(e:^Block_Encoder,p:Pack,src,dst:[]u8,general:=false,worker:=jobs.Worker_Ref{}) -> (size:int,error:Error) {
    return block_pack(&e.lz,p,e.codecs,src,dst,general,worker)
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

// The blocks of the block tables of a document compressed again as codecs say.
@(private)
document_blocks_repack :: proc(doc:^Document,p:Pack,codecs:^Pack_Codecs) -> Error {
    PAGES :: "_pages"
    for &table in doc.tables {
        if !strings.has_suffix(table.name,PAGES) || len(table.columns)!=1 {continue}
        blocks_name:=strings.concatenate({table.name[:len(table.name)-len(PAGES)],"_blocks"},context.temp_allocator)
        blocks_table,found:=document_table(doc,blocks_name)
        if !found || len(doc.tables[blocks_table].columns)!=1 || doc.tables[blocks_table].columns[0].size!=1 {continue}
        column:=&table.columns[0]
        if column.size!=size_of(Block_Record) {
            if codecs!=nil && len(doc.tables[blocks_table].columns[0].data)>0 {return .Blocks_Old}
            continue
        }
        records:=mem.slice_data_cast([]Block_Record,column.data)
        old:=doc.tables[blocks_table].columns[0].data
        largest:=0
        for record in records {
            if record.size==0 {continue}
            if record.offset>u64(len(old)) || record.size>u64(len(old))-record.offset {return .Corrupt}
            // Without codecs the blocks go to LZ, and what already is LZ stays as it is.
            if codecs==nil && old[record.offset]!=STREAM_ESCAPE {continue}
            if record.raw==0 {return .Blocks_Old}
            if int(record.raw)>=PACK_MAX {return .Corrupt}
            largest=max(largest,int(record.raw))
        }
        if largest==0 {continue}
        when ASSET_LZ {
            encoder:lz.Encoder
            lz.encoder_init(&encoder,context.temp_allocator)
            defer lz.encoder_destroy(&encoder)
        } else {
            encoder:lz.Encoder
        }
        decoder:Stream_Decoder
        stream_decoder_init(&decoder,context.temp_allocator) or_return
        defer stream_decoder_destroy(&decoder)
        raw:=make([]u8,largest,context.temp_allocator)
        data:=make([dynamic]u8,0,len(old),context.temp_allocator)
        if raw==nil || data==nil {return .Out_Of_Memory}
        for &record in records {
            if record.size==0 {continue}
            at:=len(data)
            if codecs==nil && old[record.offset]!=STREAM_ESCAPE {
                append(&data,..old[record.offset:][:record.size])
                record.offset=u64(at)
                continue
            }
            unpack(&decoder,old[record.offset:][:record.size],raw[:record.raw]) or_return
            if resize(&data,at+block_bound(codecs,int(record.raw)))!=nil {return .Out_Of_Memory}
            size:=block_pack(&encoder,PACK_EDIT if codecs==nil else p,codecs,raw[:record.raw],data[at:]) or_return
            resize(&data,at+size)
            record.offset,record.size,record.hash=u64(at),u64(size),base.hash64(data[at:])
        }
        document_resize(doc,blocks_table,len(data)) or_return
        copy(doc.tables[blocks_table].columns[0].data,data[:])
    }
    return .None
}

// A stream into all of dst, which is its decoded size: LZ or of a codec.
unpack :: proc(d:^Stream_Decoder,src,dst:[]u8) -> Error {
    if d==nil {return .Invalid}
    if len(src)>0 && src[0]==STREAM_ESCAPE {return stream_unpack(d,src,dst,len(dst))}
    when ASSET_LZ {return lz_unpack(&d.lz,src,dst)} else {return .Codec_Missing}
}

@(private)
Stream :: struct {
    id:codec.Id,
    count:int,
    table:[^]u8, // of count sizes
    first:int,   // where the first piece starts
}

@(private)
stream_read :: proc "contextless" (src:[]u8,total:int) -> (s:Stream,error:Error) {
    if len(src)<STREAM_HEAD || src[0]!=STREAM_ESCAPE || total<0 {return {},.Corrupt}
    s.id=codec.Id(u32_read(&src[1]))
    s.count=int(u32_read(&src[5]))
    if s.count!=(s.id==CODEC_NONE?1:stream_pieces(total)) {return {},.Corrupt}
    s.first=STREAM_HEAD+s.count*4
    if s.first>len(src) {return {},.Corrupt}
    s.table=([^]u8)(&src[STREAM_HEAD])
    sum:=u64(s.first)
    for piece in 0..<s.count {sum+=u64(u32_read(s.table[piece*4:]))}
    if sum!=u64(len(src)) {return {},.Corrupt}
    return s,.None
}

@(private)
codec_find :: proc "contextless" (codecs:^codec.Table,id:codec.Id) -> (index:int,found:bool) {
    if codecs==nil {return}
    for i in 0..<min(codecs.count,codec.MAX) {
        if codecs.list[i].id==id {return i,true}
    }
    return
}

// What decodes id: a codec the program was given or one the engine holds.
@(private)
stream_codec :: proc "contextless" (d:^Stream_Decoder,id:codec.Id) -> (c:codec.Decode,index:int,found:bool) {
    if index,found=codec_find(d.codecs,id);found {return d.codecs.list[index],index,true}
    when ASSET_OPEN {
        open:=open_decoders()
        for i in 0..<open.count {
            if open.list[i].id==id {return open.list[i],codec.MAX+i,true}
        }
    }
    return {},0,false
}

@(private)
stream_scratch :: proc(d:^Stream_Decoder,c:codec.Decode,index:int) -> (scratch:rawptr,error:Error) {
    if d.scratch[index]==nil && c.scratch_make!=nil {
        d.scratch[index]=c.scratch_make()
        if d.scratch[index]==nil {return nil,.Out_Of_Memory}
    }
    return d.scratch[index],.None
}

// The pieces of a stream of total raw bytes that dst holds whole, from the first.
@(private)
stream_unpack :: proc(d:^Stream_Decoder,src,dst:[]u8,total:int) -> Error {
    s:=stream_read(src,total) or_return
    if s.id==CODEC_NONE {
        if len(src)-s.first!=total || len(dst)>total {return .Corrupt}
        copy(dst,src[s.first:])
        return .None
    }
    c,index,found:=stream_codec(d,s.id)
    if !found {return .Codec_Missing}
    scratch:=stream_scratch(d,c,index) or_return
    at:=s.first
    for piece in 0..<s.count {
        raw:=min(total-piece*PACK_PIECE,PACK_PIECE)
        if piece*PACK_PIECE+raw>len(dst) {break}
        size:=int(u32_read(s.table[piece*4:]))
        if raw>0 && !c.decode(scratch,raw_data(src[at:]),uint(size),raw_data(dst[piece*PACK_PIECE:]),uint(raw)) {return .Corrupt}
        at+=size
    }
    return .None
}

// A chunk that is a stream of a codec, its pieces at once with the piece decoders of d.
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
    if !d.made && stream_decoder_init(d,work.decoders.allocator,work.decoders.codecs)!=.None {
        intrinsics.atomic_store(&work.error,Error.Out_Of_Memory)
        return
    }
    c,index,found:=stream_codec(d,work.stream.id)
    if !found {
        intrinsics.atomic_store(&work.error,Error.Codec_Missing)
        return
    }
    scratch,error:=stream_scratch(d,c,index)
    if error!=.None {
        intrinsics.atomic_store(&work.error,error)
        return
    }
    for piece in first..<last {
        raw:=min(len(work.dst)-piece*PACK_PIECE,PACK_PIECE)
        if !c.decode(scratch,raw_data(work.src[work.starts[piece]:]),uint(work.starts[piece+1]-work.starts[piece]),raw_data(work.dst[piece*PACK_PIECE:]),uint(raw)) {
            intrinsics.atomic_store(&work.error,Error.Corrupt)
        }
    }
}
