package store

import "core:hash"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/compressor/data"
import "mirai:std/base"

// Bytes that compress: runs of a few values.
@(private)
test_compressible :: proc(size:int,seed:u64) -> []u8 {
    bytes:=make([]u8,size,context.temp_allocator)
    h:=base.Hostile{state=seed}
    for at:=0;at<size; {
        value,run:=u8(base.hostile_next(&h)&7),1+int(base.hostile_next(&h)%64)
        for k in 0..<min(run,size-at) {bytes[at+k]=value}
        at+=run
    }
    return bytes
}

@(private="file")
packs_bytes :: proc(root:string) -> (total:i64) {
    entries,_:=os.read_all_directory_by_path(strings.concatenate({root,"/packs"},context.temp_allocator),context.temp_allocator)
    for e in entries {total+=e.size}
    return
}

// Compressed chunks keep their addresses and decode identically after sealing.
@(test)
frames_compress_and_addresses_are_of_the_bytes :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-codec");if folder=="" {return}
    bytes:=test_compressible(3*CHUNK_MAX+77,3)
    s,ok:=test_store(t,folder);if !ok {return}
    root,_:=test_put(&s,bytes)
    testing.expect(t,test_holds(&s,root,bytes),"the object reads as its bytes")
    close(&s)
    testing.expect(t,packs_bytes(folder)<i64(len(bytes))/2,"the frames are smaller than the bytes")
    again,opened:=test_store(t,folder);if !opened {return}
    defer close(&again)
    testing.expect(t,test_holds(&again,root,bytes),"the object reads from its sealed pack")
    duplicate,_:=test_put(&again,bytes)
    testing.expect_value(t,duplicate,root)
}

// A frame whose encoded bytes are damaged is a damaged chunk: reads fail, a scrub tombstones it,
// and a put mends it.
@(test)
a_damaged_encoded_frame_is_a_damaged_chunk :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-codec-damage");if folder=="" {return}
    chunk:=test_compressible(CHUNK_MAX/2,5)
    address:=address_of_bytes(chunk)
    {
        s,ok:=test_store(t,folder);if !ok {return}
        testing.expect_value(t,chunk_put(&s,address,chunk),Error.None)
        close(&s)
    }
    // The pack's one chunk frame: its data, past the head, gets every byte of a run flipped.
    entries,_:=os.read_all_directory_by_path(strings.concatenate({folder,"/packs"},context.temp_allocator),context.temp_allocator)
    if !testing.expect_value(t,len(entries),1) {return}
    bytes,_:=os.read_entire_file(entries[0].fullpath,context.temp_allocator)
    at:=size_of(Pack_Head)
    for at+size_of(Frame_Head)<len(bytes) && !head_valid((^Frame_Head)(raw_data(bytes[at:]))) {at+=8}
    head:=(^Frame_Head)(raw_data(bytes[at:]))^
    if !testing.expect(t,head.kind==.Chunk && head.codec!=CODEC_NONE,"the chunk is stored encoded") {return}
    body:=int(head_data_at(i64(at),head))
    for k in 0..<int(head.stored)/2 {bytes[body+k]~=0x5a}
    testing.expect(t,os.write_entire_file(entries[0].fullpath,bytes)==nil)
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    buffer:=make([]u8,CHUNK_MAX,context.temp_allocator)
    _,read_error:=chunk_read(&s,address,buffer)
    testing.expect_value(t,read_error,Error.Corrupt)
    result,scrub_error:=scrub(&s,1<<30)
    testing.expect_value(t,scrub_error,Error.None)
    testing.expect_value(t,result.damaged,1)
    testing.expect(t,!chunk_has(&s,address),"the damaged copy is no longer read")
    testing.expect_value(t,chunk_put(&s,address,chunk),Error.None)
    back,back_error:=chunk_read(&s,address,buffer)
    testing.expect(t,back_error==.None && string(back)==string(chunk),"a put mends it")
}

// Chunk frames whose codec or sizes lie are refused as damage, whatever their check.
@(test)
hostile_chunk_frames_are_refused :: proc(t:^testing.T) {
    Case :: struct {codec:u8,stored,raw:u32,valid:bool}
    cases:=[]Case{
        {CODEC_NONE,100,100,true},
        {CODEC_MDC2,100,200,true},
        {3,100,200,false},
        {255,100,200,false},
        {CODEC_NONE,100,101,false},
        {CODEC_MDC2,200,200,false}, // encoded no smaller
        {CODEC_MDC2,200,100,false},
        {CODEC_MDC2,100,CHUNK_MAX+1,false},
        {CODEC_MDC2,0,100,false},
        {CODEC_MDC2,max(u32),max(u32),false},
        {CODEC_NONE,CHUNK_MAX+1,CHUNK_MAX+1,false},
        {CODEC_MDC2,1,max(u32),false},
    }
    for c in cases {
        head:=Frame_Head{kind=.Chunk,codec=c.codec,align=ALIGN_SMALL,stored=c.stored,raw=c.raw}
        head.check=hash.crc32(mem.ptr_to_bytes(&head)[:44])
        testing.expectf(t,head_valid(&head)==c.valid,"%v",c)
    }
    for kind in ([]Frame_Kind{.Ref,.Touch,.Tombstone,.Commit}) {
        head:=Frame_Head{kind=kind,codec=CODEC_MDC2,align=ALIGN_FRAME}
        head.check=hash.crc32(mem.ptr_to_bytes(&head)[:44])
        testing.expectf(t,!head_valid(&head),"a %v frame has no codec",kind)
    }
    folder:=base.test_folder(t,"store-codec-hostile");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    chunk:=test_compressible(1000,6)
    stored:=chunk[:10]
    address:=address_of_bytes(chunk)
    raw:=make([]u8,len(chunk),context.temp_allocator)
    testing.expect_value(t,chunk_put_frame(&s,address,255,stored,raw),Error.Invalid_Argument)
    testing.expect_value(t,chunk_put_frame(&s,address,CODEC_MDC2,chunk,raw),Error.Invalid_Argument)
    testing.expect_value(t,chunk_put_frame(&s,address,CODEC_NONE,stored,raw),Error.Invalid_Argument)
    // A valid frame of other bytes, offered for this address, is refused and nothing is kept.
    other:=test_compressible(len(chunk),9)
    e:data.Encoder
    data.encoder_init(&e)
    defer data.encoder_destroy(&e)
    encoded:=make([]u8,data.bound(len(other)),context.temp_allocator)
    size,encode_error:=data.encode(&e,.Fast,other,encoded)
    if !testing.expect_value(t,encode_error,data.Error.None) {return}
    testing.expect_value(t,chunk_put_frame(&s,address,CODEC_MDC2,encoded[:size],raw),Error.Corrupt)
    testing.expect_value(t,commit(&s),Error.None)
    _,read_error:=chunk_read(&s,address,make([]u8,CHUNK_MAX,context.temp_allocator))
    testing.expect_value(t,read_error,Error.Missing)
    mine:=make([]u8,data.bound(len(chunk)),context.temp_allocator)
    mine_size,mine_error:=data.encode(&e,.Fast,chunk,mine)
    if !testing.expect_value(t,mine_error,data.Error.None) {return}
    testing.expect_value(t,chunk_put_frame(&s,address,CODEC_MDC2,mine[:mine_size],raw),Error.None)
    back,back_error:=chunk_read(&s,address,make([]u8,CHUNK_MAX,context.temp_allocator))
    testing.expect(t,back_error==.None && string(back)==string(chunk),"its own frame is kept")
    // A peer's frame that does not decode to the bytes is never kept as it is.
    bad:=make([]u8,len(stored),context.temp_allocator)
    decoded:=make([]u8,len(chunk),context.temp_allocator)
    testing.expect_value(t,chunk_decode(&s,CODEC_MDC2,bad,decoded),Error.Corrupt)
    testing.expect_value(t,chunk_decode(&s,3,bad,decoded),Error.Corrupt)
}
