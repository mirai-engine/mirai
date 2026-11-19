package store

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/base"

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

// An object of data put and committed at now: its root.
@(private)
test_put :: proc(s:^Store,data:[]u8,now:Maybe(time.Time)=nil) -> (root:Hash,error:Error) {
    root=put(s,data,now) or_return
    return root,commit(s,now)
}

// Whether the object at root is here whole and holds data.
@(private)
test_holds :: proc(s:^Store,root:Hash,data:[]u8) -> bool {
    o,error:=object_open(s,root)
    if error!=.None {return false}
    defer object_close(&o)
    back:=make([]u8,int(object_size(&o)),context.temp_allocator)
    return object_read(&o,0,back)==.None && string(back)==string(data)
}

@(private)
test_store :: proc(t:^testing.T,root:string,loc:=#caller_location) -> (Store,bool) {
    s,error:=open(root)
    return s,testing.expect_value(t,error,Error.None,loc=loc)
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
}

// Flips the byte at at of an object's bytes in the chunk of this store that holds it.
@(private)
test_damage :: proc(s:^Store,data:[]u8,at:int) -> bool {
    start:=max(at-32,0)
    needle:=string(data[start:min(start+64,len(data))])
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
