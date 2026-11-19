package cache

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:store"

@(private="file")
NAME :: "textures"

// The file of a result: a small texture whose id is that of key built by version.
@(private="file")
result_bytes :: proc(types:^asset.Types,key,version:u64,fill:u8) -> []u8 {
    pixels:=make([]u8,4*4*4,context.temp_allocator)
    for &value in pixels {value=fill}
    mips:=[1][]u8{pixels}
    doc:asset.Document
    if asset.texture_document(&doc,types,{id=id(key,version),width=4,height=4,format=.RGBA8,mips=mips[:]},context.temp_allocator)!=.None {return nil}
    defer asset.document_destroy(&doc)
    bytes,_:=asset.document_bytes(&doc,context.temp_allocator)
    return bytes
}

@(private="file")
store_at :: proc(t:^testing.T,root:string,loc:=#caller_location) -> (s:store.Store,ok:bool) {
    error:store.Error
    s,error=store.open(root,context.temp_allocator)
    return s,testing.expect_value(t,error,store.Error.None,loc=loc)
}

// Copies what the store at user keeps, as a peer would give it.
@(private="file")
copy_fetch :: proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool) {
    store_source((^store.Store)(user)).fetch(user,into,namespace,names,given)
}

@(private="file")
object_of :: proc(s:^store.Store,key,version:u64) -> store.Hash {
    namespace:[store.NAME_MAX]u8
    name:[REF_BYTES]u8
    hash,_:=store.ref_get(s,asset.cache_namespace(NAME,&namespace),ref_name(key,version,&name))
    return hash
}

@(test)
a_result_is_found_by_its_ref_through_any_store_of_its_root_and_a_source_fills_a_miss :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cache-refs")
    if folder=="" {return}
    root:=fmt.tprintf("%s/a",folder)
    writer,writer_ok:=store_at(t,root)
    reader,reader_ok:=store_at(t,root)
    peer,peer_ok:=store_at(t,fmt.tprintf("%s/b",folder))
    if !writer_ok || !reader_ok || !peer_ok {return}
    KEY,VERSION :: 0x1234,7
    file:asset.Asset

    // Kept through one Store value, found through another on the same root.
    testing.expect(t,!load({store=&reader},NAME,KEY,VERSION,&file),"an empty cache has nothing")
    testing.expect(t,put({store=&writer},NAME,KEY,VERSION,result_bytes(&types,KEY,VERSION,1)))
    if testing.expect(t,load({store=&reader},NAME,KEY,VERSION,&file,context.temp_allocator)) {
        testing.expect(t,file.blob.header.id==id(KEY,VERSION))
        asset.asset_close(&file)
    }
    testing.expect(t,has({store=&reader},NAME,KEY,VERSION) && !has({store=&reader},NAME,KEY,VERSION+1),"another version is another result")

    // A miss asks the source, which makes the blob present and sets the ref; one that has none is a miss.
    from_writer:=Cache{store=&peer,source={fetch=copy_fetch,user=&writer}}
    testing.expect(t,!load({store=&peer},NAME,KEY,VERSION,&file),"without a source the peer's result is not here")
    if testing.expect(t,load(from_writer,NAME,KEY,VERSION,&file,context.temp_allocator)) {asset.asset_close(&file)}
    testing.expect(t,has({store=&peer},NAME,KEY,VERSION),"what the source gave stays")
    testing.expect(t,!load(from_writer,NAME,KEY+1,VERSION,&file) && !has(from_writer,NAME,KEY+1,VERSION))

    // A ref whose object is not here is a miss, and keeping the result again mends it.
    namespace:[store.NAME_MAX]u8
    name:[REF_BYTES]u8
    testing.expect_value(t,store.ref_set(&writer,asset.cache_namespace(NAME,&namespace),ref_name(KEY,VERSION,&name),store.address_of_bytes(transmute([]u8)string("absent"))),store.Error.None)
    testing.expect(t,!load({store=&reader},NAME,KEY,VERSION,&file) && !has({store=&reader},NAME,KEY,VERSION))
    testing.expect(t,put({store=&writer},NAME,KEY,VERSION,result_bytes(&types,KEY,VERSION,1)))
    if testing.expect(t,load({store=&reader},NAME,KEY,VERSION,&file,context.temp_allocator)) {asset.asset_close(&file)}

    // A whole object of another result under the ref is a miss, and stays: it is whole.
    other:=result_bytes(&types,KEY+1,VERSION,2)
    testing.expect(t,put({store=&writer},NAME,KEY,VERSION,other))
    testing.expect(t,!load({store=&reader},NAME,KEY,VERSION,&file))
    testing.expect(t,asset.object_whole(&reader,object_of(&reader,KEY,VERSION)))
}

// A lookup of many keys asks the source once for all it lacks, and says which
// are here after it.
@(test)
a_lookup_of_many_keys_asks_the_source_once :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cache-lookup")
    if folder=="" {return}
    here,here_ok:=store_at(t,fmt.tprintf("%s/here",folder))
    peer,peer_ok:=store_at(t,fmt.tprintf("%s/peer",folder))
    if !here_ok || !peer_ok {return}
    VERSION :: 3
    keys:=[]u64{10,11,12,13,14}
    testing.expect(t,put({store=&peer},NAME,10,VERSION,result_bytes(&types,10,VERSION,1)))
    testing.expect(t,put({store=&here},NAME,11,VERSION,result_bytes(&types,11,VERSION,2)))
    testing.expect(t,put({store=&peer},NAME,12,VERSION,result_bytes(&types,12,VERSION,3)))
    Counted :: struct {from:^store.Store,calls,names:int}
    counted:=Counted{from=&peer}
    fetch :: proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool) {
        c:=(^Counted)(user)
        c.calls+=1
        c.names+=len(names)
        copy_fetch(c.from,into,namespace,names,given)
    }
    found:=make([]bool,len(keys),context.temp_allocator)
    lookup({store=&here,source={fetch=fetch,user=&counted}},NAME,keys,VERSION,found)
    testing.expectf(t,counted.calls==1 && counted.names==4,"one fetch of what is not here: %v",counted)
    testing.expectf(t,slice.equal(found,[]bool{true,true,true,false,false}),"%v",found)
    file:asset.Asset
    if testing.expect(t,load({store=&here},NAME,12,VERSION,&file,context.temp_allocator)) {asset.asset_close(&file)}
    lookup({store=&here,source={fetch=fetch,user=&counted}},NAME,keys[:3],VERSION,found[:3])
    testing.expectf(t,counted.calls==1,"what is here asks nothing: %v",counted)
}

@(test)
hostile_names_are_refused_and_any_key_is_kept_without_a_crash :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cache-hostile")
    if folder=="" {return}
    s,ok:=store_at(t,folder)
    if !ok {return}
    c:=Cache{store=&s,source={fetch=copy_fetch,user=&s}}
    bytes:=result_bytes(&types,1,1,3)
    file:asset.Asset
    for name in ([]string{"","Textures","../up","a/b","a\\b","nul\x00","..",strings.repeat("x",store.NAME_MAX,context.temp_allocator)}) {
        testing.expectf(t,!put(c,name,1,1,bytes) && !load(c,name,1,1,&file) && !has(c,name,1,1),"%q is refused",name)
    }
    for key in ([]u64{0,1,max(u64)}) {
        for version in ([]u64{0,max(u64)}) {
            kept:=result_bytes(&types,key,version,4)
            testing.expect(t,put(c,NAME,key,version,kept))
            if testing.expectf(t,load(c,NAME,key,version,&file,context.temp_allocator),"%x-%x",key,version) {asset.asset_close(&file)}
        }
    }
    testing.expect(t,!put({},NAME,1,1,bytes) && !load({},NAME,1,1,&file) && !has({},NAME,1,1),"without a store nothing is kept")
    _=put(c,NAME,9,9,nil)
    testing.expect(t,!load(c,NAME,9,9,&file),"bytes that are no asset are no result")
}
