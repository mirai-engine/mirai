package store

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:std/blake3"

@(private)
test_bytes :: proc(size:int,seed:u64) -> []u8 {
    data:=make([]u8,size,context.temp_allocator)
    h:=base.Hostile{state=seed}
    for &b in data {b=u8(base.hostile_next(&h))}
    return data
}

@(private)
test_address :: proc(data:[]u8) -> Hash {
    return address_of_bytes(data)
}

@(private)
test_piece :: proc(data:[]u8,index:int) -> []u8 {
    return data[index*PIECE_BYTES:min((index+1)*PIECE_BYTES,len(data))]
}

@(private)
test_table :: proc(data:[]u8) -> []Hash {
    pieces:=make([]Hash,piece_count(i64(len(data))),context.temp_allocator)
    for &piece,i in pieces {piece=piece_value(test_piece(data,i),i,i64(len(data)))}
    return pieces
}

@(private)
test_store :: proc(t:^testing.T,root:string,loc:=#caller_location) -> (Store,bool) {
    s,error:=open(root)
    return s,testing.expect_value(t,error,Error.None,loc=loc)
}

@(test)
address_is_the_same_through_put_bytes_put_file_and_receiving :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-address");if folder=="" {return}
    Case :: struct {size:int}
    cases:=[]Case{{0},{1},{PIECE_BYTES-1},{PIECE_BYTES},{PIECE_BYTES+1},{3*PIECE_BYTES+17}}
    for c,n in cases {
        data:=test_bytes(c.size,u64(n)+1)
        root:=folder
        a,ok:=test_store(t,join_test(root,"a",n));if !ok {return}
        defer close(&a)
        b,_:=test_store(t,join_test(root,"b",n))
        defer close(&b)
        r,_:=test_store(t,join_test(root,"r",n))
        defer close(&r)
        put,put_error:=put_bytes(&a,data)
        testing.expect_value(t,put_error,Error.None)
        testing.expect(t,put==test_address(data),"put bytes gives the address of the bytes")
        testing.expect(t,put==Hash(blake3.hash(data)),"the address is the BLAKE3 hash of the bytes")
        testing.expect(t,put==address_value(i64(c.size),test_table(data)),"the address is that of the table")
        source:=join_test(root,"source",n)
        testing.expect(t,os.write_entire_file(source,data)==nil)
        from_file,file_size,file_error:=address_of_file(source)
        testing.expect(t,file_error==.None && from_file==put && file_size==i64(c.size),"the address of the file is the address of its bytes")
        filed,filed_error:=put_file(&b,source)
        testing.expect(t,filed_error==.None && filed==put,"put file gives the same address")
        pieces,table_error:=blob_table(&a,put,context.temp_allocator)
        testing.expect_value(t,table_error,Error.None)
        testing.expect_value(t,receive_begin(&r,put,i64(c.size),pieces),Error.None)
        for index:=len(pieces)-1;index>=0;index-=1 {
            testing.expect_value(t,receive_piece(&r,put,index,test_piece(data,index)),Error.None)
        }
        for s in ([]^Store{&a,&b,&r}) {
            testing.expect(t,has(s,put),"every path ends with the blob")
            testing.expect_value(t,verify(s,put),Error.None)
            size,size_error:=blob_size(s,put)
            testing.expect(t,size_error==.None && size==i64(c.size))
            back:=make([]u8,c.size,context.temp_allocator)
            testing.expect_value(t,read(s,put,0,back),Error.None)
            testing.expect(t,string(back)==string(data),"the blob reads back its bytes")
            path,path_error:=blob_path(s,put,context.temp_allocator)
            testing.expect_value(t,path_error,Error.None)
            on_disk,_:=os.read_entire_file(path,context.temp_allocator)
            testing.expect(t,string(on_disk)==string(data),"the blob file holds the raw bytes")
        }
        again,again_error:=put_bytes(&a,data)
        testing.expect(t,again_error==.None && again==put)
        total,_:=usage(&a)
        testing.expect_value(t,total,Usage{bytes=i64(c.size),blobs=1})
    }
}

@(private)
join_test :: proc(root,name:string,n:int) -> string {
    buffer:=make([]u8,len(root)+len(name)+8,context.temp_allocator)
    copy(buffer,root)
    copy(buffer[len(root):],"/")
    copy(buffer[len(root)+1:],name)
    buffer[len(root)+1+len(name)]='-'
    buffer[len(root)+2+len(name)]=u8('0'+n%10)
    return string(buffer[:len(root)+3+len(name)])
}

@(test)
a_wrong_table_or_piece_is_refused_and_leaves_no_blob :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-wrong");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    data:=test_bytes(2*PIECE_BYTES+5,7)
    hash:=test_address(data)
    pieces:=test_table(data)
    wrong:=make([]Hash,len(pieces),context.temp_allocator)
    copy(wrong,pieces)
    wrong[1][0]~=1
    testing.expect_value(t,receive_begin(&s,hash,i64(len(data)),wrong),Error.Corrupt)
    testing.expect_value(t,receive_begin(&s,hash,i64(len(data))+PIECE_BYTES,pieces),Error.Invalid_Argument)
    testing.expect_value(t,receive_begin(&s,hash,i64(len(data)),pieces[:2]),Error.Invalid_Argument)
    testing.expect_value(t,receive_begin(&s,hash,-1,nil),Error.Invalid_Argument)
    _,missing_error:=receive_missing(&s,hash,context.temp_allocator)
    testing.expect_value(t,missing_error,Error.Missing)
    testing.expect(t,!has(&s,hash),"a refused table keeps nothing")
    testing.expect_value(t,receive_begin(&s,hash,i64(len(data)),pieces),Error.None)
    bad:=make([]u8,PIECE_BYTES,context.temp_allocator)
    copy(bad,test_piece(data,0))
    bad[100]~=0xff
    testing.expect_value(t,receive_piece(&s,hash,0,bad),Error.Corrupt)
    testing.expect_value(t,receive_piece(&s,hash,1,test_piece(data,0)),Error.Corrupt)
    testing.expect_value(t,receive_piece(&s,hash,2,test_piece(data,1)),Error.Invalid_Argument)
    testing.expect_value(t,receive_piece(&s,hash,3,test_piece(data,2)),Error.Invalid_Argument)
    testing.expect_value(t,receive_piece(&s,hash,-1,test_piece(data,0)),Error.Invalid_Argument)
    missing,_:=receive_missing(&s,hash,context.temp_allocator)
    testing.expect_value(t,len(missing),3)
    testing.expect(t,!has(&s,hash),"refused pieces complete nothing")
    total,_:=usage(&s)
    testing.expect_value(t,total.blobs,0)
    partial,partial_error:=blob_table(&s,hash,context.temp_allocator)
    testing.expect(t,partial_error==.None && string(mem.slice_to_bytes(partial))==string(mem.slice_to_bytes(pieces)),"a blob being received serves the table it began with")
    // The table does not hold the length of the last piece: a size that keeps
    // the piece count is taken, and then the true last piece proves it wrong.
    testing.expect_value(t,remove(&s,hash),Error.None)
    _,gone_error:=blob_table(&s,hash,context.temp_allocator)
    testing.expect_value(t,gone_error,Error.Missing)
    testing.expect_value(t,receive_begin(&s,hash,i64(len(data))-1,pieces),Error.None)
    last:=len(pieces)-1
    for index in 0..<last {testing.expect_value(t,receive_piece(&s,hash,index,test_piece(data,index)),Error.None)}
    testing.expect_value(t,receive_piece(&s,hash,last,test_piece(data,last)),Error.Wrong_Size)
    testing.expect_value(t,receive_piece(&s,hash,last,test_piece(data,last)[2:]),Error.Invalid_Argument)
    testing.expect(t,!has(&s,hash),"a wrong size publishes nothing")
    testing.expect_value(t,remove(&s,hash),Error.None)
    testing.expect_value(t,receive_begin(&s,hash,i64(len(data)),pieces),Error.None)
    testing.expect_value(t,receive_piece(&s,hash,last,test_piece(data,last)),Error.None)
}

@(test)
receiving_resumes_after_reopening_and_reads_the_pieces_it_has :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-resume");if folder=="" {return}
    data:=test_bytes(3*PIECE_BYTES+100,11)
    hash:=test_address(data)
    {
        s,ok:=test_store(t,folder);if !ok {return}
        defer close(&s)
        testing.expect_value(t,receive_begin(&s,hash,i64(len(data)),test_table(data)),Error.None)
        testing.expect_value(t,receive_piece(&s,hash,0,test_piece(data,0)),Error.None)
        testing.expect_value(t,receive_piece(&s,hash,2,test_piece(data,2)),Error.None)
        testing.expect_value(t,receive_piece(&s,hash,2,test_piece(data,2)),Error.None)
    }
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    missing,missing_error:=receive_missing(&s,hash,context.temp_allocator)
    testing.expect_value(t,missing_error,Error.None)
    testing.expect(t,len(missing)==2 && missing[0]==1 && missing[1]==3,"the pieces it had survive a reopen")
    size,_:=blob_size(&s,hash)
    testing.expect_value(t,size,i64(len(data)))
    Range :: struct {offset,count:int,error:Error}
    ranges:=[]Range{
        {10,500,.None},
        {2*PIECE_BYTES,PIECE_BYTES,.None},
        {PIECE_BYTES-10,20,.Not_Here_Yet},
        {3*PIECE_BYTES,100,.Not_Here_Yet},
        {0,len(data),.Not_Here_Yet},
        {len(data)-10,20,.Invalid_Argument},
    }
    for r in ranges {
        buffer:=make([]u8,r.count,context.temp_allocator)
        error:=read(&s,hash,i64(r.offset),buffer)
        testing.expectf(t,error==r.error,"range %d+%d: %v",r.offset,r.count,error)
        if r.error==.None {testing.expect(t,string(buffer)==string(data[r.offset:r.offset+r.count]))}
    }
    testing.expect(t,!has(&s,hash))
    testing.expect_value(t,receive_piece(&s,hash,3,test_piece(data,3)),Error.None)
    testing.expect_value(t,receive_piece(&s,hash,1,test_piece(data,1)),Error.None)
    testing.expect(t,has(&s,hash),"the last piece completes the blob")
    testing.expect_value(t,verify(&s,hash),Error.None)
    testing.expect_value(t,receive_piece(&s,hash,1,test_piece(data,1)),Error.None)
    partials,_:=os.read_all_directory_by_path(strings.concatenate({folder,"/partial"},context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,len(partials),0)
}

@(test)
sweep_keeps_exactly_the_live_blobs :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-sweep");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    hashes:[5]Hash
    bytes:i64
    for &hash,i in hashes {
        data:=test_bytes(1000*(i+1),u64(i)+20)
        hash,_=put_bytes(&s,data)
        bytes+=i64(len(data))
    }
    partial:=test_bytes(PIECE_BYTES+1,30)
    partial_hash:=test_address(partial)
    testing.expect_value(t,receive_begin(&s,partial_hash,i64(len(partial)),test_table(partial)),Error.None)
    total,_:=usage(&s)
    testing.expect_value(t,total,Usage{bytes=bytes,blobs=5})
    stale,fresh:=join_test(folder,"tmp/stale",0),join_test(folder,"tmp/fresh",0)
    testing.expect(t,os.write_entire_file(stale,[]u8{1})==nil && os.write_entire_file(fresh,[]u8{1})==nil)
    old:=os.modification_time_by_path(stale) or_else {}
    testing.expect(t,os.change_times(stale,old,{_nsec=old._nsec-2*i64(TMP_STALE)})==nil)
    unknown:Hash
    unknown[0]=0xee
    freed,error:=sweep(&s,{hashes[3],unknown,hashes[1]})
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,freed,Usage{bytes=1000+3000+5000,blobs=3})
    for hash,i in hashes {testing.expectf(t,has(&s,hash)==(i==1 || i==3),"blob %d",i)}
    total,_=usage(&s)
    testing.expect_value(t,total,Usage{bytes=2000+4000,blobs=2})
    _,missing_error:=receive_missing(&s,partial_hash,context.temp_allocator)
    testing.expect_value(t,missing_error,Error.None)
    testing.expect(t,!os.exists(stale) && os.exists(fresh),"sweep removes only stale temporary files")
    testing.expect_value(t,remove(&s,hashes[1]),Error.None)
    testing.expect_value(t,remove(&s,hashes[1]),Error.Missing)
    testing.expect_value(t,remove(&s,partial_hash),Error.None)
    _,missing_error=receive_missing(&s,partial_hash,context.temp_allocator)
    testing.expect_value(t,missing_error,Error.Missing)
}

// Receives every piece but piece 0, whose bytes and mark are then written as
// a receiver killed before completing would leave them.
@(private)
test_full_unfinished :: proc(t:^testing.T,s:^Store,data:[]u8) -> Hash {
    hash:=test_address(data)
    pieces:=test_table(data)
    testing.expect_value(t,receive_begin(s,hash,i64(len(data)),pieces),Error.None)
    for index in 1..<len(pieces) {testing.expect_value(t,receive_piece(s,hash,index,test_piece(data,index)),Error.None)}
    name:[64]u8
    folder:=strings.concatenate({s.root,"/partial/",hex(hash,&name)},context.temp_allocator)
    data_file,_:=os.open(strings.concatenate({folder,"/data"},context.temp_allocator),{.Write})
    os.write_at(data_file,test_piece(data,0),0)
    os.close(data_file)
    have_file,_:=os.open(strings.concatenate({folder,"/have"},context.temp_allocator),{.Write})
    os.write_at(have_file,[]u8{1},0)
    os.close(have_file)
    testing.expect(t,!has(s,hash))
    return hash
}

@(test)
a_full_partial_is_completed_by_whoever_finds_it :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-full");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    Finder :: enum {Begin,Missing,Duplicate}
    for finder,n in Finder {
        data:=test_bytes(2*PIECE_BYTES+n+1,u64(n)+50)
        hash:=test_full_unfinished(t,&s,data)
        switch finder {
        case .Begin: testing.expect_value(t,receive_begin(&s,hash,i64(len(data)),test_table(data)),Error.None)
        case .Missing:
            missing,error:=receive_missing(&s,hash,context.temp_allocator)
            testing.expect(t,error==.None && len(missing)==0)
        case .Duplicate: testing.expect_value(t,receive_piece(&s,hash,1,test_piece(data,1)),Error.None)
        }
        testing.expectf(t,has(&s,hash),"%v completes a partial with every piece",finder)
        testing.expect_value(t,verify(&s,hash),Error.None)
    }
}

@(test)
completion_publishes_only_the_bytes_it_checked :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-claim");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    data:=test_bytes(3*PIECE_BYTES+3,60)
    hash:=test_full_unfinished(t,&s,data)
    c:Claim
    testing.expect_value(t,partial_claim(&s,hash,&c),Error.None)
    complete,error:=claim_verify(&s,hash,&c)
    testing.expect(t,error==.None && complete)
    // Meanwhile another receiver completes it, a sweep removes it and a third begins again.
    _,put_error:=put_bytes(&s,data)
    testing.expect_value(t,put_error,Error.None)
    _,sweep_error:=sweep(&s,nil)
    testing.expect_value(t,sweep_error,Error.None)
    testing.expect_value(t,receive_begin(&s,hash,i64(len(data)),test_table(data)),Error.None)
    testing.expect_value(t,receive_piece(&s,hash,2,test_piece(data,2)),Error.None)
    testing.expect_value(t,claim_publish(&s,hash,&c),Error.None)
    claim_end(&s,hash,&c)
    testing.expect(t,has(&s,hash))
    testing.expect_value(t,verify(&s,hash),Error.None)
    testing.expect_value(t,receive_piece(&s,hash,0,test_piece(data,0)),Error.None)
    missing,missing_error:=receive_missing(&s,hash,context.temp_allocator)
    testing.expect(t,missing_error==.None && len(missing)==0,"the receiver that began again finds the blob complete")
    partials,_:=os.read_all_directory_by_path(strings.concatenate({folder,"/partial"},context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,len(partials),0)
}

@(test)
a_failed_placement_loses_nothing_and_is_retried :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-place");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    data:=test_bytes(2*PIECE_BYTES+9,70)
    hash:=test_address(data)
    name:[64]u8
    shard:=strings.concatenate({folder,"/blobs/",hex(hash,&name)[:2]},context.temp_allocator)
    testing.expect(t,os.make_directory(shard)==nil)
    testing.expect(t,os.change_mode(shard,os.perm_number(0o555))==nil)
    testing.expect_value(t,receive_begin(&s,hash,i64(len(data)),test_table(data)),Error.None)
    testing.expect_value(t,receive_piece(&s,hash,0,test_piece(data,0)),Error.None)
    testing.expect_value(t,receive_piece(&s,hash,2,test_piece(data,2)),Error.None)
    testing.expect_value(t,receive_piece(&s,hash,1,test_piece(data,1)),Error.Io)
    testing.expect(t,!has(&s,hash))
    _,missing_error:=receive_missing(&s,hash,context.temp_allocator)
    testing.expect_value(t,missing_error,Error.Io)
    testing.expect(t,os.change_mode(shard,os.perm_number(0o755))==nil)
    missing,error:=receive_missing(&s,hash,context.temp_allocator)
    testing.expect(t,error==.None && len(missing)==0)
    testing.expect(t,has(&s,hash),"the pieces kept through a failed placement complete the blob later")
    testing.expect_value(t,verify(&s,hash),Error.None)
}

@(test)
a_complete_blob_serves_its_kept_table_and_a_reader :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-serve");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    data:=test_bytes(2*PIECE_BYTES+11,80)
    hash,_:=put_bytes(&s,data)
    first,_:=blob_table(&s,hash,context.temp_allocator)
    name:[64]u8
    kept:=strings.concatenate({folder,"/tables/",hex(hash,&name)[:2],"/",hex(hash,&name)},context.temp_allocator)
    testing.expect(t,os.is_file(kept),"the first table served is kept")
    testing.expect(t,os.write_entire_file(kept,[]u8{1,2,3})==nil)
    again,error:=blob_table(&s,hash,context.temp_allocator)
    testing.expect(t,error==.None && len(again)==len(first) && again[2]==first[2],"a damaged kept table is hashed again")
    r,open_error:=reader_open(&s,hash)
    testing.expect_value(t,open_error,Error.None)
    Range :: struct {offset,count:int,error:Error}
    for c in ([]Range{{0,10,.None},{PIECE_BYTES-5,10,.None},{len(data)-1,1,.None},{len(data),1,.Invalid_Argument},{-1,1,.Invalid_Argument}}) {
        buffer:=make([]u8,c.count,context.temp_allocator)
        testing.expect_value(t,reader_read(&r,i64(c.offset),buffer),c.error)
        if c.error==.None {testing.expect(t,string(buffer)==string(data[c.offset:][:c.count]))}
    }
    reader_close(&r)
    testing.expect_value(t,reader_read(&r,0,nil),Error.Invalid_Argument)
    unknown:Hash
    _,unknown_error:=reader_open(&s,unknown)
    testing.expect_value(t,unknown_error,Error.Missing)
    received:=test_full_unfinished(t,&s,test_bytes(PIECE_BYTES+1,81))
    testing.expect_value(t,receive_begin(&s,received,PIECE_BYTES+1,test_table(test_bytes(PIECE_BYTES+1,81))),Error.None)
    received_kept:=strings.concatenate({folder,"/tables/",hex(received,&name)[:2],"/",hex(received,&name)},context.temp_allocator)
    testing.expect(t,os.is_file(received_kept),"a received blob keeps the table it was checked with")
    testing.expect_value(t,remove(&s,hash),Error.None)
    testing.expect(t,!os.is_file(kept))
}
