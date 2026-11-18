package store

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"

@(private)
test_bytes :: proc(size:int,seed:u64) -> []u8 {
    data:=make([]u8,size,context.temp_allocator)
    h:=base.Hostile{state=seed}
    for &b in data {b=u8(base.hostile_next(&h))}
    return data
}

@(private)
test_piece :: proc(data:[]u8,index:int) -> []u8 {
    return data[index*PIECE_BYTES:min((index+1)*PIECE_BYTES,len(data))]
}

@(private)
test_table :: proc(data:[]u8) -> []Hash {
    pieces:=make([]Hash,piece_count(i64(len(data))),context.temp_allocator)
    for &piece,i in pieces {piece=piece_value(test_piece(data,i),i)}
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
        testing.expect(t,put==address_of_bytes(data),"put bytes gives the address of the bytes")
        testing.expect(t,put==table_address(i64(c.size),test_table(data)),"the address is that of the table")
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
    hash:=address_of_bytes(data)
    pieces:=test_table(data)
    wrong:=make([]Hash,len(pieces),context.temp_allocator)
    copy(wrong,pieces)
    wrong[1][0]~=1
    testing.expect_value(t,receive_begin(&s,hash,i64(len(data)),wrong),Error.Corrupt)
    testing.expect_value(t,receive_begin(&s,hash,i64(len(data))+1,pieces),Error.Corrupt)
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
}

@(test)
receiving_resumes_after_reopening_and_reads_the_pieces_it_has :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-resume");if folder=="" {return}
    data:=test_bytes(3*PIECE_BYTES+100,11)
    hash:=address_of_bytes(data)
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
    partial_hash:=address_of_bytes(partial)
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
