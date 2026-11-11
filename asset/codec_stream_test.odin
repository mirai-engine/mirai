package asset

import "core:testing"
import "mirai:std/base"
import "mirai:std/codec"
import "mirai:std/compressor"
import "mirai:std/compressor/lz"
import "mirai:std/jobs"
import "mirai:std/serial"

// The pack of a cook that ships, as cook/compressor/lz names it.
@(private="file")
SHIP :: Pack{level=compressor.LEVEL_OPTIMAL5}

// A codec of runs of a byte: small and strict enough to tell what the container does with one.
@(private="file")
RUNS :: codec.Id(u32('R')|u32('U')<<8|u32('N')<<16|u32('S')<<24)

@(private="file")
runs_bound :: proc "c" (size:uint) -> uint {return size*2+2}

@(private="file")
runs_encode :: proc "c" (level:i32,src:[^]u8,src_bytes:uint,dst:[^]u8,capacity:uint) -> uint {
    written:=uint(0)
    for at:=uint(0);at<src_bytes; {
        run:=uint(1)
        for at+run<src_bytes && run<255 && src[at+run]==src[at] {run+=1}
        if written+2>capacity {return 0}
        dst[written],dst[written+1]=src[at],u8(run)
        written+=2
        at+=run
    }
    return written
}

@(private="file")
runs_decode :: proc "c" (scratch:rawptr,src:[^]u8,src_bytes:uint,dst:[^]u8,dst_bytes:uint) -> bool {
    if src_bytes%2!=0 {return false}
    written:=uint(0)
    for at:=uint(0);at<src_bytes;at+=2 {
        run:=uint(src[at+1])
        if run==0 || written+run>dst_bytes {return false}
        for i in 0..<run {dst[written+i]=src[at]}
        written+=run
    }
    return written==dst_bytes
}

@(private="file")
runs_codecs :: proc "contextless" () -> (writes:Pack_Codecs,reads:codec.Table) {
    encode:=codec.Encode{id=RUNS,bound=runs_bound,encode=runs_encode}
    writes.general,writes.streamed=encode,encode
    reads.list[0]={id=RUNS,decode=runs_decode}
    reads.count=1
    return
}

@(private="file")
chunk_write :: proc(data:[]u8,codecs:^Pack_Codecs,worker:=jobs.Worker_Ref{}) -> []u8 {
    w:serial.Writer
    serial.writer_init(&w,allocator=context.temp_allocator)
    scratch:=make([dynamic]u8,context.temp_allocator)
    chunks:=[?]Build_Chunk{{tag=fourcc("DATA"),alignment=16,compression=.LZ,data=data}}
    if blob_build(&w,fourcc("TEST"),1,{},{},{},chunks[:],&scratch,SHIP,worker,codecs)!=.None {return nil}
    return serial.writer_bytes(&w)
}

@(test)
a_chunk_of_a_codec_says_what_decodes_it_and_decodes_the_same_in_pieces :: proc(t:^testing.T) {
    writes,reads:=runs_codecs()
    data:=make([]u8,2*PACK_PIECE+1000,context.temp_allocator)
    for &b,i in data {b=u8(i/700)}
    file:=chunk_write(data,&writes)
    blob,error:=blob_open(file)
    testing.expect_value(t,error,Error.None)
    entry:=blob_chunk(&blob,0)
    testing.expect(t,entry.compression==.Codec && entry.size<entry.uncompressed_size)

    js:jobs.Job_System
    testing.expect(t,jobs.system_init(&js,{threads=3}))
    defer jobs.system_destroy(&js)
    testing.expect(t,string(chunk_write(data,&writes,{&js,jobs.OWNER,nil}))==string(file),"the same bytes with workers")

    pieces:Piece_Decoders
    testing.expect_value(t,piece_decoders_init(&pieces,&js,context.temp_allocator,&reads),Error.None)
    defer piece_decoders_destroy(&pieces)
    for parallel in ([2]bool{false,true}) {
        decoder:Decoder
        testing.expect_value(t,decoder_init(&decoder,context.temp_allocator,&reads),Error.None)
        defer decoder_destroy(&decoder)
        if parallel {decoder.pieces,decoder.worker=&pieces,jobs.OWNER}
        out:=make([]u8,len(data),context.temp_allocator)
        testing.expect_value(t,blob_read(&blob,entry,out,&decoder),Error.None)
        testing.expect(t,string(out)==string(data))
    }

    without:Decoder
    testing.expect_value(t,decoder_init(&without,context.temp_allocator),Error.None)
    defer decoder_destroy(&without)
    out:=make([]u8,len(data),context.temp_allocator)
    testing.expect_value(t,blob_read(&blob,entry,out,&without),Error.Codec_Missing)
}

@(test)
nothing_is_compressed_when_a_write_says_none :: proc(t:^testing.T) {
    data:=make([]u8,4000,context.temp_allocator)
    none:=Pack_Codecs{none=true}
    blob,error:=blob_open(chunk_write(data,&none))
    testing.expect_value(t,error,Error.None)
    entry:=blob_chunk(&blob,0)
    testing.expect(t,entry.compression==.None && entry.size==entry.uncompressed_size)
}

@(test)
a_block_says_what_decodes_it_whatever_wrote_it :: proc(t:^testing.T) {
    writes,reads:=runs_codecs()
    none:=Pack_Codecs{none=true}
    data:=make([]u8,3000,context.temp_allocator)
    for &b,i in data {b=u8(i/9)}
    decoder:Stream_Decoder
    testing.expect_value(t,stream_decoder_init(&decoder,context.temp_allocator,&reads),Error.None)
    defer stream_decoder_destroy(&decoder)
    encoder:lz.Encoder
    lz.encoder_init(&encoder,context.temp_allocator)
    defer lz.encoder_destroy(&encoder)
    for codecs in ([3]^Pack_Codecs{nil,&none,&writes}) {
        packed:=make([]u8,block_bound(codecs,len(data)),context.temp_allocator)
        size,error:=block_pack(&encoder,PACK_EDIT,codecs,data,packed)
        testing.expect_value(t,error,Error.None)
        out:=make([]u8,len(data),context.temp_allocator)
        testing.expect_value(t,unpack(&decoder,packed[:size],out),Error.None)
        testing.expect(t,string(out)==string(data))
    }
}

@(test)
a_stream_that_lies_about_its_pieces_is_refused :: proc(t:^testing.T) {
    writes,reads:=runs_codecs()
    data:=make([]u8,PACK_PIECE+50,context.temp_allocator)
    packed:=make([]u8,codec_pack_bound(&writes.general,len(data)),context.temp_allocator)
    size,error:=codec_pack(&writes.general,SHIP,data,packed)
    testing.expect_value(t,error,Error.None)
    stream:=packed[:size]
    decoder:Stream_Decoder
    testing.expect_value(t,stream_decoder_init(&decoder,context.temp_allocator,&reads),Error.None)
    defer stream_decoder_destroy(&decoder)
    out:=make([]u8,len(data),context.temp_allocator)
    testing.expect_value(t,unpack(&decoder,stream,out),Error.None)
    for cut in ([?]int{0,1,4,STREAM_HEAD,STREAM_HEAD+3,size-1}) {
        testing.expectf(t,unpack(&decoder,stream[:cut],out)!=.None || cut==0,"cut at %d",cut)
    }
    state:=u64(9)
    for _ in 0..<4000 {
        mutated:=make([]u8,size,context.temp_allocator)
        copy(mutated,stream)
        for _ in 0..<3 {mutated[test_random(&state)%u64(STREAM_HEAD+16)]=u8(test_random(&state))}
        unpack(&decoder,mutated,out)
    }
}

@(test)
a_document_writes_with_what_the_types_it_was_made_with_say :: proc(t:^testing.T) {
    writes,reads:=runs_codecs()
    types:Types
    types_init(&types,context.temp_allocator)
    types.writes=&writes
    doc:Document
    document_init(&doc,fourcc("TEST"),{1,2},context.temp_allocator)
    data:=make([]u8,4000,context.temp_allocator)
    _,put:=document_put(&doc,&types,"values",data,{.Bulk},.LZ)
    testing.expect_value(t,put,Error.None)
    bytes,error:=document_bytes(&doc,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    a:Asset
    testing.expect_value(t,asset_open(&a,bytes,context.temp_allocator,codecs=&reads),Error.None)
    defer asset_close(&a)
    table,_:=asset_table(&a,"values")
    testing.expect(t,blob_chunk(&a.blob,table.columns[0].chunk).compression==.Codec)
    values,read:=asset_rows(&a,&types,"values","",u8)
    testing.expect_value(t,read,Error.None)
    testing.expect_value(t,len(values),len(data))
}

@(test)
a_cook_compresses_again_the_blocks_a_document_reads_alone :: proc(t:^testing.T) {
    writes,reads:=runs_codecs()
    types:Types
    types_init(&types,context.temp_allocator)
    decoder:Stream_Decoder
    testing.expect_value(t,stream_decoder_init(&decoder,context.temp_allocator,&reads),Error.None)
    defer stream_decoder_destroy(&decoder)
    encoder:lz.Encoder
    lz.encoder_init(&encoder,context.temp_allocator)
    defer lz.encoder_destroy(&encoder)
    raw:=make([]u8,2000,context.temp_allocator)
    for &b,i in raw {b=u8(i/100)}
    block:=make([]u8,block_bound(nil,len(raw)),context.temp_allocator)
    size,packed:=block_pack(&encoder,PACK_EDIT,nil,raw,block)
    testing.expect_value(t,packed,Error.None)
    write :: proc(types:^Types,record:Block_Record,block:[]u8) -> []u8 {
        doc:Document
        document_init(&doc,fourcc("TEST"),{1,2},context.temp_allocator)
        records:=[1]Block_Record{record}
        document_put(&doc,types,"grid_pages",records[:])
        document_put(&doc,types,"grid_blocks",block,{.Bulk},.None)
        bytes,_:=document_bytes(&doc,context.temp_allocator)
        return bytes
    }
    record:=Block_Record{count=1,size=u64(size),hash=base.hash64(block[:size]),raw=u32(len(raw))}
    cooked,error:=document_repack(write(&types,record,block[:size]),SHIP,context.temp_allocator,codecs=&writes)
    testing.expect_value(t,error,Error.None)
    a:Asset
    testing.expect_value(t,asset_open(&a,cooked,context.temp_allocator,codecs=&reads),Error.None)
    defer asset_close(&a)
    records,rows:=asset_rows(&a,&types,"grid_pages","",Block_Record)
    testing.expect_value(t,rows,Error.None)
    blocks,bytes:=asset_rows(&a,&types,"grid_blocks","",u8)
    testing.expect_value(t,bytes,Error.None)
    stored:=blocks[records[0].offset:][:records[0].size]
    testing.expect_value(t,records[0].hash,base.hash64(stored))
    out:=make([]u8,len(raw),context.temp_allocator)
    testing.expect_value(t,unpack(&decoder,stored,out),Error.None)
    testing.expect(t,string(out)==string(raw))
    record.raw=0
    _,old:=document_repack(write(&types,record,block[:size]),SHIP,context.temp_allocator,codecs=&writes)
    testing.expect_value(t,old,Error.Blocks_Old)
}
