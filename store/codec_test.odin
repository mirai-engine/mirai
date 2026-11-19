package store

import "core:hash"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "compressor:data"
import "mirai:std/base"

// A codec no build has, as a build with another compressor writes: Zstandard under an id of
// its own.
@(private)
TEST_CODEC :: 15

@(private)
test_codec_hook :: proc() -> Codec_Hook {
    return {codec=TEST_CODEC,encode=proc(src,dst:[]u8) -> int {
        e:data.Encoder
        data.encoder_init(&e)
        defer data.encoder_destroy(&e)
        size,error:=data.encode(&e,.Fast,src,dst)
        return size if error==.None else 0
    },decode=proc(src,dst:[]u8) -> bool {
        d:data.Decoder
        if data.decoder_init(&d)!=.None {return false}
        defer data.decoder_destroy(&d)
        return data.decode(&d,data.ZSTD,src,dst)==.None
    }}
}

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

// A chunk that shrinks is stored encoded and read as its bytes; its address, and the object's,
// are of the bytes whatever the codec: a value of another codec puts the same objects.
@(test)
frames_compress_and_addresses_are_of_the_bytes :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-codec");if folder=="" {return}
    data:=test_compressible(3*CHUNK_MAX+77,3)
    roots:[2]Hash
    for &root,i in roots {
        s,ok:=test_store(t,join_test(folder,"root",i));if !ok {return}
        if i==1 {testing.expect_value(t,codec_hook(&s,test_codec_hook()),Error.None)}
        root,_=test_put(&s,data)
        testing.expect(t,test_holds(&s,root,data),"the object reads as its bytes")
        close(&s)
        testing.expectf(t,packs_bytes(join_test(folder,"root",i))<i64(len(data))/2,"the frames are smaller than the bytes (%d)",i)
        // Read again from the sealed pack, mapped.
        again,_:=test_store(t,join_test(folder,"root",i))
        if i==1 {codec_hook(&again,test_codec_hook())}
        testing.expect(t,test_holds(&again,root,data),"and reads from its sealed pack")
        close(&again)
    }
    testing.expect_value(t,roots[0],roots[1])
}

// A root written by a build with a codec this one lacks: what its frames hold is missing here,
// and a put of the same bytes appends frames this build reads, while the other build's frames
// stay and still read for it; a sweep of either keeps a copy both read.
@(test)
a_codec_this_build_lacks_reads_as_missing_and_a_put_repairs_it :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-codec-lacks");if folder=="" {return}
    data:=test_compressible(2*CHUNK_MAX+5,4)
    other,ok:=test_store(t,folder);if !ok {return}
    defer close(&other)
    testing.expect_value(t,codec_hook(&other,test_codec_hook()),Error.None)
    root,_:=test_put(&other,data)
    testing.expect_value(t,ref_set(&other,"keep","data",root),Error.None)
    here,here_ok:=test_store(t,folder);if !here_ok {return}
    defer close(&here)
    testing.expect(t,TEST_CODEC not_in codecs_read(&here),"this value lacks the codec")
    testing.expect(t,chunk_has(&here,root),"the root, a node, is stored as it is")
    testing.expect(t,!test_holds(&here,root,data),"what the other codec's frames hold is missing here")
    o,_:=object_open(&here,root)
    buffer:=make([]u8,64,context.temp_allocator)
    testing.expect_value(t,object_read(&o,0,buffer),Error.Missing)
    object_close(&o)
    before:=packs_bytes(folder)
    again,_:=test_put(&here,data)
    testing.expect_value(t,again,root)
    testing.expect(t,test_holds(&here,root,data),"a put of the same bytes repairs it")
    testing.expect(t,packs_bytes(folder)>before,"in frames of its own")
    testing.expect(t,test_holds(&other,root,data),"the other build still reads it")
    for s in ([]^Store{&here,&other}) {
        _,sweep_error:=sweep(s,nil)
        testing.expect_value(t,sweep_error,Error.None)
        testing.expect(t,test_holds(&here,root,data) && test_holds(&other,root,data),"a sweep keeps a copy both read")
    }
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
        {1,100,200,true},
        {TEST_CODEC,100,200,true}, // a codec no build here has: valid, and not read
        {CODECS_MAX,100,200,false},
        {255,100,200,false},
        {CODEC_NONE,100,101,false},
        {1,200,200,false},          // encoded no smaller
        {1,200,100,false},
        {1,100,CHUNK_MAX+1,false},
        {1,0,100,false},
        {1,max(u32),max(u32),false},
        {CODEC_NONE,CHUNK_MAX+1,CHUNK_MAX+1,false},
        {1,1,max(u32),false},
    }
    for c in cases {
        head:=Frame_Head{kind=.Chunk,codec=c.codec,align=ALIGN_SMALL,stored=c.stored,raw=c.raw}
        head.check=hash.crc32(mem.ptr_to_bytes(&head)[:44])
        testing.expectf(t,head_valid(&head)==c.valid,"%v",c)
    }
    for kind in ([]Frame_Kind{.Ref,.Touch,.Tombstone,.Commit}) {
        head:=Frame_Head{kind=kind,codec=1,align=ALIGN_FRAME}
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
    testing.expect_value(t,chunk_put_frame(&s,address,CODECS_MAX,stored,raw),Error.Invalid_Argument)
    testing.expect_value(t,chunk_put_frame(&s,address,1,chunk,raw),Error.Invalid_Argument)
    testing.expect_value(t,chunk_put_frame(&s,address,CODEC_NONE,stored,raw),Error.Invalid_Argument)
    // A valid frame of other bytes, offered for this address, is refused and nothing is kept.
    other:=test_compressible(len(chunk),9)
    e:data.Encoder
    data.encoder_init(&e)
    defer data.encoder_destroy(&e)
    encoded:=make([]u8,data.bound(len(other)),context.temp_allocator)
    size,_:=data.encode(&e,.Fast,other,encoded)
    testing.expect_value(t,chunk_put_frame(&s,address,1,encoded[:size],raw),Error.Corrupt)
    testing.expect_value(t,commit(&s),Error.None)
    _,read_error:=chunk_read(&s,address,make([]u8,CHUNK_MAX,context.temp_allocator))
    testing.expect_value(t,read_error,Error.Missing)
    mine:=make([]u8,data.bound(len(chunk)),context.temp_allocator)
    mine_size,_:=data.encode(&e,.Fast,chunk,mine)
    testing.expect_value(t,chunk_put_frame(&s,address,1,mine[:mine_size],raw),Error.None)
    back,back_error:=chunk_read(&s,address,make([]u8,CHUNK_MAX,context.temp_allocator))
    testing.expect(t,back_error==.None && string(back)==string(chunk),"its own frame is kept")
    // A peer's frame that does not decode to the bytes is never kept as it is.
    bad:=make([]u8,len(stored),context.temp_allocator)
    testing.expect_value(t,chunk_decode(&s,1,bad,make([]u8,len(chunk),context.temp_allocator)),Error.Corrupt)
    testing.expect_value(t,chunk_decode(&s,TEST_CODEC,bad,make([]u8,len(chunk),context.temp_allocator)),Error.Missing)
}

// A small object stored with a codec the other build lacks, swept into a generation, then put
// again by this build and swept with both packs sealed: compaction keeps a copy every build
// reads, the generation indexes it, and once the retired packs go both builds read the object.
@(test)
a_sweep_of_copies_of_two_codecs_keeps_one_every_build_reads :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-codec-sweep");if folder=="" {return}
    data:=test_compressible(5000,7)
    root:Hash
    {
        other,ok:=test_store(t,folder);if !ok {return}
        testing.expect_value(t,codec_hook(&other,test_codec_hook()),Error.None)
        root,_=test_put(&other,data)
        testing.expect_value(t,ref_set(&other,"keep","data",root),Error.None)
        _,first:=sweep(&other,nil)
        testing.expect_value(t,first,Error.None)
        close(&other)
    }
    {
        here,ok:=test_store(t,folder);if !ok {return}
        again,_:=test_put(&here,data)
        testing.expect_value(t,again,root)
        close(&here) // seals its pack
    }
    {
        here,ok:=test_store(t,folder);if !ok {return}
        for _ in 0..<2 {
            _,error:=sweep(&here,nil)
            testing.expect_value(t,error,Error.None)
        }
        close(&here)
    }
    retired,_:=os.read_all_directory_by_path(strings.concatenate({folder,"/retired"},context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,len(retired),0)
    fresh,fresh_ok:=test_store(t,folder);if !fresh_ok {return}
    defer close(&fresh)
    testing.expect(t,test_holds(&fresh,root,data),"a build that lacks the other codec reads it")
    hooked,hooked_ok:=test_store(t,folder);if !hooked_ok {return}
    defer close(&hooked)
    codec_hook(&hooked,test_codec_hook())
    testing.expect(t,test_holds(&hooked,root,data),"the other build reads it")
}

// A build that lacks the codec of an object's leaves holds the object whole all the same: a ref
// and a lease it sets on it keep it, and a sweep keeps it, though it reads and serves none of
// those leaves.
@(test)
a_ref_on_an_object_of_a_codec_this_build_lacks_is_kept :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-codec-ref");if folder=="" {return}
    data:=test_compressible(3*CHUNK_MAX,8)
    root:Hash
    {
        other,ok:=test_store(t,folder);if !ok {return}
        testing.expect_value(t,codec_hook(&other,test_codec_hook()),Error.None)
        root,_=test_put(&other,data)
        testing.expect_value(t,ref_set(&other,"other","data",root),Error.None)
        _,error:=sweep(&other,nil)
        testing.expect_value(t,error,Error.None)
        close(&other)
    }
    here,ok:=test_store(t,folder);if !ok {return}
    defer close(&here)
    testing.expect_value(t,ref_set(&here,"keep","data",root),Error.None)
    lease,lease_error:=lease_open(&here,"reader",{root})
    testing.expect_value(t,lease_error,Error.None)
    defer lease_release(&lease)
    _,sweep_error:=sweep(&here,nil)
    testing.expect_value(t,sweep_error,Error.None)
    hooked,hooked_ok:=test_store(t,folder);if !hooked_ok {return}
    defer close(&hooked)
    codec_hook(&hooked,test_codec_hook())
    testing.expect(t,test_holds(&hooked,root,data),"the object stays whole for the build that reads it")
}
