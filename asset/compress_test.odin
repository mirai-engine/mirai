package asset

import "core:testing"
import "compressor:data"
import "mirai:std/base"

// Every profile a write may compress with, as every codecs allow, makes a stream of the format
// they say that decodes to what was written; with None, the bytes as they are.
@(test)
a_stream_is_of_the_format_its_write_says_and_decodes_to_what_was_written :: proc(t:^testing.T) {
    raw:=make([]u8,PACK_PIECE+3000,context.temp_allocator)
    state:=u64(3)
    for &b,i in raw {b=u8(i/9) if i%5!=0 else u8(test_random(&state))}
    encoder:Stream_Encoder
    testing.expect_value(t,stream_encoder_init(&encoder),Error.None)
    defer stream_encoder_destroy(&encoder)
    decoder:Stream_Decoder
    testing.expect_value(t,stream_decoder_init(&decoder),Error.None)
    defer stream_decoder_destroy(&decoder)
    for codecs in Codecs {
        for profile in data.Profile {
            packed:=make([]u8,pack_bound(len(raw)),context.temp_allocator)
            size,error:=pack(&encoder,profile,codecs,raw,packed)
            if !testing.expectf(t,error==.None,"%v %v: %v",codecs,profile,error) {continue}
            testing.expectf(t,pack_matches(packed[:size],profile,codecs),"%v %v",codecs,profile)
            testing.expect(t,(codecs==.None)==(stream_format(profile,codecs)==STORED))
            out:=make([]u8,len(raw),context.temp_allocator)
            testing.expect_value(t,unpack(&decoder,packed[:size],out),Error.None)
            testing.expectf(t,string(out)==string(raw),"%v %v decodes to what was written",codecs,profile)
        }
    }
    free_all(context.temp_allocator)
}

// A stream cut, or whose header and table of pieces are changed, is refused or decodes without
// reaching outside its bytes; one of a format nothing decodes says so.
@(test)
a_stream_that_lies_about_its_pieces_is_refused :: proc(t:^testing.T) {
    raw:=make([]u8,PACK_PIECE+50,context.temp_allocator)
    for &b,i in raw {b=u8(i/7)}
    encoder:Stream_Encoder
    testing.expect_value(t,stream_encoder_init(&encoder),Error.None)
    defer stream_encoder_destroy(&encoder)
    packed:=make([]u8,pack_bound(len(raw)),context.temp_allocator)
    size,error:=pack(&encoder,.Fast,.Open,raw,packed)
    testing.expect_value(t,error,Error.None)
    stream:=packed[:size]
    decoder:Stream_Decoder
    testing.expect_value(t,stream_decoder_init(&decoder),Error.None)
    defer stream_decoder_destroy(&decoder)
    out:=make([]u8,len(raw),context.temp_allocator)
    testing.expect_value(t,unpack(&decoder,stream,out),Error.None)
    for cut in ([?]int{0,1,4,STREAM_HEAD,STREAM_HEAD+3,size-1}) {
        testing.expectf(t,unpack(&decoder,stream[:cut],out)!=.None,"cut at %d",cut)
    }
    unknown:=make([]u8,size,context.temp_allocator)
    copy(unknown,stream)
    u32_write(&unknown[1],u32('?'))
    testing.expect_value(t,unpack(&decoder,unknown,out),Error.Codec_Missing)
    state:=u64(9)
    for _ in 0..<4000 {
        mutated:=make([]u8,size,context.temp_allocator)
        copy(mutated,stream)
        for _ in 0..<3 {mutated[test_random(&state)%u64(STREAM_HEAD+16)]=u8(test_random(&state))}
        unpack(&decoder,mutated,out)
    }
    free_all(context.temp_allocator)
}

// A document compresses with the codecs of the Types it was made with.
@(test)
a_document_writes_with_what_the_types_it_was_made_with_say :: proc(t:^testing.T) {
    for codecs in Codecs {
        types:Types
        types_init(&types,context.temp_allocator)
        types.codecs=codecs
        doc:Document
        document_init(&doc,fourcc("TEST"),{1,2},context.temp_allocator)
        values:=make([]u8,4000,context.temp_allocator)
        _,put:=document_put(&doc,&types,"values",values,{.Bulk},.Stream)
        testing.expect_value(t,put,Error.None)
        bytes,error:=document_bytes(&doc,context.temp_allocator,.Ultra)
        testing.expect_value(t,error,Error.None)
        a:Asset
        testing.expect_value(t,asset_open(&a,bytes,context.temp_allocator),Error.None)
        table,_:=asset_table(&a,"values")
        entry:=blob_chunk(&a.blob,table.columns[0].chunk)
        testing.expect(t,(entry.compression==.None)==(codecs==.None))
        testing.expect(t,codecs==.None || pack_matches(blob_stored(&a.blob,entry),.Ultra,codecs))
        read,rows:=asset_rows(&a,&types,"values","",u8)
        testing.expect(t,rows==.None && len(read)==len(values))
        asset_close(&a)
    }
    free_all(context.temp_allocator)
}

// A cook writes again each block of a table of blocks as its profile of what streams says; a
// record whose block lies outside the table is refused.
@(test)
a_cook_compresses_again_the_blocks_a_document_reads_alone :: proc(t:^testing.T) {
    types:Types
    types_init(&types,context.temp_allocator)
    decoder:Stream_Decoder
    testing.expect_value(t,stream_decoder_init(&decoder),Error.None)
    defer stream_decoder_destroy(&decoder)
    encoder:Stream_Encoder
    testing.expect_value(t,stream_encoder_init(&encoder),Error.None)
    defer stream_encoder_destroy(&encoder)
    raw:=make([]u8,2000,context.temp_allocator)
    for &b,i in raw {b=u8(i/100)}
    block:=make([]u8,pack_bound(len(raw)),context.temp_allocator)
    size,packed:=pack(&encoder,.Fast,.Open,raw,block)
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
    cooked,error:=document_repack(write(&types,record,block[:size]),.Ultra,.Open,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    a:Asset
    testing.expect_value(t,asset_open(&a,cooked,context.temp_allocator),Error.None)
    defer asset_close(&a)
    records,rows:=asset_rows(&a,&types,"grid_pages","",Block_Record)
    testing.expect_value(t,rows,Error.None)
    blocks,bytes:=asset_rows(&a,&types,"grid_blocks","",u8)
    testing.expect_value(t,bytes,Error.None)
    stored:=blocks[records[0].offset:][:records[0].size]
    testing.expect_value(t,records[0].hash,base.hash64(stored))
    testing.expect(t,pack_matches(stored,.Speed,.Open),"a block streams: the profile Speed")
    out:=make([]u8,len(raw),context.temp_allocator)
    testing.expect_value(t,unpack(&decoder,stored,out),Error.None)
    testing.expect(t,string(out)==string(raw))
    record.size+=1
    _,outside:=document_repack(write(&types,record,block[:size]),.Ultra,.Open,context.temp_allocator)
    testing.expect_value(t,outside,Error.Corrupt)
}
