package store

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
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

// Copies every chunk of an object, nodes before what they name, as a receiver
// takes them.
@(private)
test_copy :: proc(from,into:^Store,address:Hash) -> Error {
    buffer:=make([]u8,CHUNK_MAX,context.temp_allocator)
    bytes:=chunk_read(from,address,buffer) or_return
    chunk_put(into,address,bytes) or_return
    n,parse_error:=node_parse(bytes)
    if parse_error!=.None {return .None}
    entries:=make([]Entry,len(n.entries),context.temp_allocator)
    copy(entries,n.entries)
    for e in entries {
        if n.level>0 {
            test_copy(from,into,e.address) or_return
        } else {
            data:=chunk_read(from,e.address,buffer) or_return
            chunk_put(into,e.address,data) or_return
        }
    }
    return .None
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
    cases:=[]Case{{0},{1},{CHUNK_MIN-1},{CHUNK_MAX},{CHUNK_MAX+1},{3*CHUNK_MAX+17}}
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
        source:=join_test(root,"source",n)
        testing.expect(t,os.write_entire_file(source,data)==nil)
        from_file,file_size,file_error:=address_of_file(source)
        testing.expect(t,file_error==.None && from_file==put && file_size==i64(c.size),"the address of the file is the address of its bytes")
        filed,filed_error:=put_file(&b,source)
        testing.expect(t,filed_error==.None && filed==put,"put file gives the same address")
        object,found:=blob_root(&a,put)
        testing.expect(t,found,"the blob names its object")
        testing.expect_value(t,test_copy(&a,&r,object),Error.None)
        testing.expect_value(t,blob_alias(&r,put,object),Error.None)
        testing.expect_value(t,commit(&r),Error.None)
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
            testing.expect(t,string(on_disk)==string(data),"the file of blob_path holds the raw bytes")
        }
        again,again_error:=put_bytes(&a,data)
        testing.expect(t,again_error==.None && again==put)
        again_file,_:=put_file(&b,source)
        testing.expect(t,again_file==put && has(&b,put),"a put of what is here keeps it")
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

// A received object is named a blob only once its bytes hash to the blob's
// address, and a range of a blob reads its bytes.
@(test)
a_received_object_is_named_a_blob_only_when_its_bytes_make_it :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-alias");if folder=="" {return}
    a,ok:=test_store(t,join_test(folder,"a",0));if !ok {return}
    defer close(&a)
    r,_:=test_store(t,join_test(folder,"r",0))
    defer close(&r)
    data:=test_bytes(2*CHUNK_MAX+11,80)
    hash,_:=put_bytes(&a,data)
    other,_:=put(&a,test_bytes(2*CHUNK_MAX+11,81))
    commit(&a)
    root,_:=blob_root(&a,hash)
    testing.expect_value(t,test_copy(&a,&r,other),Error.None)
    testing.expect_value(t,blob_alias(&r,hash,other),Error.Corrupt)
    testing.expect(t,!has(&r,hash),"an object of other bytes is not the blob")
    testing.expect_value(t,test_copy(&a,&r,root),Error.None)
    testing.expect_value(t,blob_alias(&r,hash,root),Error.None)
    testing.expect_value(t,commit(&r),Error.None)
    testing.expect(t,has(&r,hash),"the object of its bytes is")
    Range :: struct {offset,count:int,error:Error}
    for c in ([]Range{{0,10,.None},{CHUNK_MAX-5,10,.None},{len(data)-1,1,.None},{len(data),1,.Invalid_Argument},{-1,1,.Invalid_Argument}}) {
        buffer:=make([]u8,c.count,context.temp_allocator)
        testing.expect_value(t,read(&r,hash,i64(c.offset),buffer),c.error)
        if c.error==.None {testing.expect(t,string(buffer)==string(data[c.offset:][:c.count]))}
    }
    unknown:Hash
    testing.expect_value(t,read(&r,unknown,0,nil),Error.Missing)
}

// A receiver's report has the store check one chunk: a damaged copy is
// tombstoned and no longer read; a good one stays.
@(test)
a_chunk_check_tombstones_a_damaged_copy :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-check");if folder=="" {return}
    s,ok:=test_store(t,folder);if !ok {return}
    defer close(&s)
    good:=test_bytes(1000,83)
    other:=test_bytes(1000,84)
    a,b:=address_of_bytes(good),address_of_bytes(other)
    chunk_put(&s,a,good)
    chunk_put(&s,b,other)
    commit(&s)
    testing.expect(t,test_damage(&s,good,500),"the damage lands in a pack")
    testing.expect_value(t,chunk_check(&s,a),Error.Corrupt)
    testing.expect(t,!chunk_has(&s,a),"the damaged copy is no longer read")
    testing.expect_value(t,chunk_check(&s,b),Error.None)
    testing.expect(t,chunk_has(&s,b),"a good copy stays")
    testing.expect_value(t,chunk_check(&s,a),Error.Missing)
    testing.expect_value(t,chunk_put(&s,a,good),Error.None)
    testing.expect(t,chunk_has(&s,a),"and the chunk can be put again")
    // verify finds a damaged blob, tombstones it and removes it.
    size:=3*CHUNK_MAX+4
    data:=test_bytes(size,85)
    hash,_:=put_bytes(&s,data)
    testing.expect(t,test_damage(&s,data,size-2),"the damage lands in a pack")
    testing.expect_value(t,verify(&s,hash),Error.Corrupt)
    testing.expect(t,!has(&s,hash),"a damaged blob is removed")
    again,_:=put_bytes(&s,data)
    back:=make([]u8,size,context.temp_allocator)
    testing.expect(t,again==hash && read(&s,again,0,back)==.None && string(back)==string(data),"and put again")
}

// Flips the byte at at of a blob's bytes in the chunk of this store that holds it.
@(private)
test_damage :: proc(s:^Store,blob:[]u8,at:int) -> bool {
    start:=max(at-32,0)
    needle:=string(blob[start:min(start+64,len(blob))])
    entries,_:=os.read_all_directory_by_path(strings.concatenate({s.root,"/packs"},context.temp_allocator),context.temp_allocator)
    for e in entries {
        bytes,read_error:=os.read_entire_file(e.fullpath,context.temp_allocator)
        if read_error!=nil {continue}
        found:=strings.index(string(bytes),needle)
        if found<0 {continue}
        file,open_error:=os.open(e.fullpath,{.Read,.Write})
        if open_error!=nil {return false}
        defer os.close(file)
        flipped:=[1]u8{bytes[found+at-start]~0xff}
        _,write_error:=os.write_at(file,flipped[:],i64(found+at-start))
        return write_error==nil
    }
    return false
}

@(private)
test_set_time :: proc(t:^testing.T,path:string,at:time.Time,loc:=#caller_location) {
    testing.expect(t,os.change_times(path,at,at)==nil,loc=loc)
}
