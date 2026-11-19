package cache

import "core:fmt"
import "mirai:asset"
import "mirai:std/base"
import "mirai:store"

// What an import or a cook built, kept by what it was made from in the
// machine store, so that building it again reads it instead, here or on
// another machine that shares blobs with this one. A result is the file of an
// asset, kept as a blob, whose id is its key and the version of what built
// it; the ref (cache-<name>, <key>-<version>) names it (asset.cache_namespace),
// so a builder that gives other bytes misses every earlier result. A ref
// whose blob is missing or does not read back whole is a miss, and a blob that
// no longer has the bytes of its address is removed so that building again
// replaces it. The store owns space: the cache removes nothing it can read.

// Asked on a miss before building: for each of names, makes the blob of the
// ref (namespace, name) complete in into and sets the ref there; given (as
// long as names, all false when asked) says for which it did. Names known together are asked
// together, so a source that asks peers waits for them once.
Fetch :: #type proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool)

Source :: struct {
    fetch:Fetch, // nil: none
    user:rawptr,
}

Cache :: struct {
    store:^store.Store, // nil: nothing is kept
    source:Source,
}

// The id of the file of key, built by version.
id :: proc "contextless" (key,version:u64) -> base.Asset_Id {return {key,version}}

// The file of key built by version in the cache name, open in file for the
// caller to close. On a miss the source is asked once. False without one, or
// with one that does not read back whole.
load :: proc(c:Cache,name:string,key,version:u64,file:^asset.Asset,allocator:=context.allocator) -> bool {
    namespace_buffer:[store.NAME_MAX]u8
    ref_buffer:[REF_BYTES]u8
    namespace,ref,ok:=names(c,name,key,version,&namespace_buffer,&ref_buffer)
    if !ok {return false}
    if load_here(c.store,namespace,ref,key,version,file,allocator) {return true}
    return fetched(c,namespace,ref) && load_here(c.store,namespace,ref,key,version,file,allocator)
}

// Whether the cache name keeps a complete blob for key built by version,
// without reading it; the source is asked on a miss.
has :: proc(c:Cache,name:string,key,version:u64) -> bool {
    namespace_buffer:[store.NAME_MAX]u8
    ref_buffer:[REF_BYTES]u8
    namespace,ref,ok:=names(c,name,key,version,&namespace_buffer,&ref_buffer)
    if !ok {return false}
    if has_here(c.store,namespace,ref) {return true}
    return fetched(c,namespace,ref) && has_here(c.store,namespace,ref)
}

// Keeps bytes, the file of an asset whose id is id(key,version), as the
// result of key in the cache name. False when it cannot be kept, which costs
// only the time of building it the next time.
put :: proc(c:Cache,name:string,key,version:u64,bytes:[]u8) -> bool {
    namespace_buffer:[store.NAME_MAX]u8
    ref_buffer:[REF_BYTES]u8
    namespace,ref,ok:=names(c,name,key,version,&namespace_buffer,&ref_buffer)
    if !ok {return false}
    hash,error:=store.put_bytes(c.store,bytes)
    return error==.None && store.ref_set(c.store,namespace,ref,hash)==.None
}

@(private)
REF_BYTES :: 33 // <key>-<version>, each 16 hex digits

// The namespace and the name of the ref of key built by version; not ok
// without a store or for a name the store refuses.
@(private)
names :: proc(c:Cache,name:string,key,version:u64,namespace_buffer:^[store.NAME_MAX]u8,ref_buffer:^[REF_BYTES]u8) -> (namespace,ref:string,ok:bool) {
    if c.store==nil || name=="" {return}
    namespace=asset.cache_namespace(name,namespace_buffer)
    if !store.name_valid(namespace) {return}
    return namespace,fmt.bprintf(ref_buffer[:],"%016x-%016x",key,version),true
}

@(private)
fetched :: proc(c:Cache,namespace,ref:string) -> bool {
    return source_fetch(c.source,c.store,namespace,ref)
}

// Asks source for the one ref (namespace, name); false without a source.
source_fetch :: proc(source:Source,into:^store.Store,namespace,name:string) -> bool {
    if source.fetch==nil {return false}
    names:=[1]string{name}
    given:[1]bool
    source.fetch(source.user,into,namespace,names[:],given[:])
    return given[0]
}

@(private)
has_here :: proc(s:^store.Store,namespace,ref:string) -> bool {
    hash,error:=store.ref_get(s,namespace,ref)
    return error==.None && store.has(s,hash)
}

@(private)
load_here :: proc(s:^store.Store,namespace,ref:string,key,version:u64,file:^asset.Asset,allocator:=context.allocator) -> bool {
    hash,error:=store.ref_get(s,namespace,ref)
    if error!=.None || !store.has(s,hash) {return false}
    path,path_error:=store.blob_path(s,hash,context.temp_allocator)
    if path_error!=.None {return false}
    if asset.asset_load(file,path,allocator)==.None {
        if file.blob.header.id==id(key,version) && asset.blob_verify_hash(&file.blob) {return true}
        asset.asset_close(file)
    }
    if store.verify(s,hash)==.Corrupt {_=store.remove(s,hash)}
    return false
}

// A source that copies from the store at from, a second root of blobs and
// refs: the blob of the ref and, for a build (asset.REF_IMPORTS), every blob
// it lists. What a peer gives, and what an installed engine gives from the
// store of the builds of its plugins.
store_source :: proc(from:^store.Store) -> Source {
    fetch :: proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool) {
        from:=(^store.Store)(user)
        for name,k in names {given[k]=copy_ref(from,into,namespace,name)}
    }
    copy_ref :: proc(from,into:^store.Store,namespace,name:string) -> bool {
        hash,error:=store.ref_get(from,namespace,name)
        if error!=.None || !blob_copy(from,into,hash) {return false}
        if namespace==asset.REF_IMPORTS {
            b,build_error:=asset.build_get(from,hash,context.temp_allocator)
            if build_error!=.None {return false}
            for o in b.outputs {
                if !blob_copy(from,into,o.blob) {return false}
            }
        }
        return store.ref_set(into,namespace,name,hash)==.None
    }
    return {fetch=fetch,user=from}
}

@(private="file")
blob_copy :: proc(from,into:^store.Store,hash:store.Hash) -> bool {
    if store.has(into,hash) {return true}
    path,path_error:=store.blob_path(from,hash,context.temp_allocator)
    if path_error!=.None {return false}
    put,put_error:=store.put_file(into,path)
    return put_error==.None && put==hash
}
