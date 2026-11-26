package cache

import "core:fmt"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"
import "mirai:store"

// What an import or a cook built, kept by what it was made from in the
// machine store, so that building it again reads it instead, here or on
// another machine that shares the store's objects with this one. A result is
// the file of an asset, kept as an object (asset.object_put), whose id is its
// key and the version of what built it; the ref (cache-<name>,
// <key>-<version>) names it (asset.cache_namespace, ref_name), so a builder that gives
// other bytes misses every earlier result. A ref whose object is not here
// whole or does not read is a miss. The store owns space and checks its
// chunks (its scrub): the cache removes nothing.

// Asked on a miss before building: for each of names, makes the object of the
// ref (namespace, name) whole in into and sets the ref there; given (as
// long as names, all false when asked) says for which it did. Names known
// together are asked together, so a source that asks peers waits for them once.
Fetch :: #type proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool)

// Told after a result was kept under the ref (namespace, name): a source that
// shares results publishes it. from: the files it was made from, absolute,
// which decide who may read it; none known: empty.
Kept :: #type proc(user:rawptr,namespace,name:string,object:store.Hash,from:[]string)

Source :: struct {
    fetch:Fetch, // nil: none
    kept:Kept,   // nil: none
    here:Kept,   // nil: none. Told of a result found here that no source was told it kept (made before the project shared, or with none): one that shares publishes it when its peers have none
    user:rawptr,
}

Cache :: struct {
    store:^store.Store, // nil: nothing is kept
    source:Source,
    from:[]string, // the files what put keeps is made from, absolute, told to the source's kept
}

// The layout of what a result is: raised when results are kept otherwise, so a
// result of another layout is never read. 3: an object of the store, as Codecs.None writes it.
RESULTS_VERSION :: 3

// The id of the file of key, built by version.
id :: proc "contextless" (key,version:u64) -> base.Asset_Id {return {key,version}}

// The file of key built by version in the cache name, open in file for the
// caller to close; it reads nothing more of the store. On a miss the source is
// asked once. False without one, or with one that does not read whole.
load :: proc(c:Cache,name:string,key,version:u64,file:^asset.Asset,allocator:=context.allocator) -> bool {
    namespace_buffer:[store.NAME_MAX]u8
    ref_buffer:[REF_BYTES]u8
    namespace,ref,ok:=names(c,name,key,version,&namespace_buffer,&ref_buffer)
    if !ok {return false}
    if load_here(c.store,namespace,ref,key,version,file,allocator) {return true}
    return fetched(c,namespace,ref) && load_here(c.store,namespace,ref,key,version,file,allocator)
}

// Whether the cache name keeps a whole object for key built by version,
// without reading it; the source is asked on a miss.
has :: proc(c:Cache,name:string,key,version:u64) -> bool {
    namespace_buffer:[store.NAME_MAX]u8
    ref_buffer:[REF_BYTES]u8
    namespace,ref,ok:=names(c,name,key,version,&namespace_buffer,&ref_buffer)
    if !ok {return false}
    if has_here(c.store,namespace,ref) {return true}
    return fetched(c,namespace,ref) && has_here(c.store,namespace,ref)
}

// Which of keys, each built by version, the cache name keeps whole, into
// here (as long as keys): what is not here is asked of the source in one
// fetch. What a pass needs is looked up so, once, and its builds then load
// with a cache without source.
lookup :: proc(c:Cache,name:string,keys:[]u64,version:u64,here:[]bool) {
    for &h in here {h=false}
    if len(here)!=len(keys) {return}
    namespace_buffer:[store.NAME_MAX]u8
    ref_buffer:[REF_BYTES]u8
    namespace,_,ok:=names(c,name,0,version,&namespace_buffer,&ref_buffer)
    if !ok {return}
    lacking:=make([dynamic]string,context.temp_allocator)
    at:=make([dynamic]int,context.temp_allocator)
    for key,k in keys {
        name_buffer:[REF_BYTES]u8
        ref:=strings.clone(ref_name(key,version,&name_buffer),context.temp_allocator)
        if here[k]=has_here(c.store,namespace,ref);here[k] {continue}
        if _,no_room:=append(&lacking,ref);no_room!=nil {return}
        if _,no_room:=append(&at,k);no_room!=nil {return}
    }
    if len(lacking)==0 || c.source.fetch==nil {return}
    given:=make([]bool,len(lacking),context.temp_allocator)
    c.source.fetch(c.source.user,c.store,namespace,lacking[:],given)
    for ref,i in lacking {
        if given[i] {here[at[i]]=has_here(c.store,namespace,ref)}
    }
}

// Keeps bytes, the file of an asset whose id is id(key,version), as the
// result of key in the cache name, committed. False when it cannot be kept,
// which costs only the time of building it the next time.
put :: proc(c:Cache,name:string,key,version:u64,bytes:[]u8) -> bool {
    namespace_buffer:[store.NAME_MAX]u8
    ref_buffer:[REF_BYTES]u8
    namespace,ref,ok:=names(c,name,key,version,&namespace_buffer,&ref_buffer)
    if !ok {return false}
    object,error:=asset.object_put(c.store,bytes)
    if error!=.None || store.ref_set(c.store,namespace,ref,object)!=.None {return false}
    if c.source.kept!=nil {c.source.kept(c.source.user,namespace,ref,object,c.from)}
    return true
}

// What gives the imports and cooks of the project at root what the peers of
// its org built and takes what they build, through the runner of the store at
// store_root (cook/kai.peers_open, which the programs that import and cook pass
// down). close says how many results went each way; nil when the project
// shares with no peers.
Peers_Open :: #type proc(store_root,root:string) -> (source:Source,close:Peers_Close)
Peers_Close :: #type proc(source:Source) -> (taken,published:int)

// Two sources as one: a miss asks first, then second for what first did not
// give; what is kept is told to both. Lives while it is asked.
Chain :: struct {first,second:Source}

chain_source :: proc(c:^Chain) -> Source {
    if c.first.fetch==nil && c.first.kept==nil {return c.second}
    if c.second.fetch==nil && c.second.kept==nil {return c.first}
    fetch :: proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool) {
        c:=(^Chain)(user)
        if c.first.fetch!=nil {c.first.fetch(c.first.user,into,namespace,names,given)}
        if c.second.fetch==nil {return}
        lacking:=make([dynamic]string,context.temp_allocator)
        at:=make([dynamic]int,context.temp_allocator)
        for name,k in names {
            if given[k] {continue}
            append(&lacking,name)
            append(&at,k)
        }
        if len(lacking)==0 {return}
        second:=make([]bool,len(lacking),context.temp_allocator)
        c.second.fetch(c.second.user,into,namespace,lacking[:],second)
        for k,i in at {given[k]=second[i]}
    }
    kept :: proc(user:rawptr,namespace,name:string,object:store.Hash,from:[]string) {
        c:=(^Chain)(user)
        if c.first.kept!=nil {c.first.kept(c.first.user,namespace,name,object,from)}
        if c.second.kept!=nil {c.second.kept(c.second.user,namespace,name,object,from)}
    }
    here :: proc(user:rawptr,namespace,name:string,object:store.Hash,from:[]string) {
        c:=(^Chain)(user)
        if c.first.here!=nil {c.first.here(c.first.user,namespace,name,object,from)}
        if c.second.here!=nil {c.second.here(c.second.user,namespace,name,object,from)}
    }
    return {fetch=fetch,kept=kept,here=here,user=c}
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
    return namespace,ref_name(key,version,ref_buffer),true
}

// <key>-<version>, the version combined with RESULTS_VERSION.
@(private)
ref_name :: proc(key,version:u64,buffer:^[REF_BYTES]u8) -> string {
    return fmt.bprintf(buffer[:],"%016x-%016x",key,base.hash_combine(version,RESULTS_VERSION))
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
    object,error:=store.ref_get(s,namespace,ref)
    return error==.None && asset.object_whole(s,object)
}

@(private)
load_here :: proc(s:^store.Store,namespace,ref:string,key,version:u64,file:^asset.Asset,allocator:=context.allocator) -> bool {
    object,error:=store.ref_get(s,namespace,ref)
    if error!=.None {return false}
    if asset.asset_open_object(file,s,object,allocator)!=.None {return false}
    if file.blob.header.id==id(key,version) && asset.asset_object_settle(file)==.None {return true}
    asset.asset_close(file)
    return false
}

// A source that copies from the store at from, a second root of objects and
// refs: the object of the ref and, for a build (asset.REF_IMPORTS,
// asset.REF_IMPORTS_FAST or asset.REF_BUILDS), every object it lists. What a peer gives, and what an installed engine gives from
// the store of the builds of its plugins.
store_source :: proc(from:^store.Store) -> Source {
    fetch :: proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool) {
        from:=(^store.Store)(user)
        source:=store.read_index(from)
        target:=store.read_index(into)
        scratch,no_room:=make([]u8,COPY_SCRATCH)
        defer delete(scratch)
        for name,k in names {given[k]=no_room==nil && copy_ref(&source,&target,namespace,name,scratch)}
    }
    copy_ref :: proc(from,into:^store.Store,namespace,name:string,scratch:[]u8) -> bool {
        object,error:=store.ref_get(from,namespace,name)
        if error!=.None || object_copy(from,into,object,scratch)!=.None {return false}
        if namespace==asset.REF_IMPORTS || namespace==asset.REF_IMPORTS_FAST || namespace==asset.REF_BUILDS {
            b,build_error:=asset.build_get(from,object,context.temp_allocator)
            if build_error!=.None {return false}
            objects:=asset.Build_Objects{build=&b,with_thumbnails=true}
            for address in asset.build_object_next(&objects) {
                if object_copy(from,into,address,scratch)!=.None {return false}
            }
        }
        return store.ref_set(into,namespace,name,object)==.None
    }
    return {fetch=fetch,user=from}
}

// What object_copy reads chunks into, a slot per level of a walk, since a
// node's entries point into its slot: a walk over many objects allocates it
// once.
COPY_SCRATCH :: (store.NODE_LEVEL_MAX+2)*store.CHUNK_MAX

// Copies into the batch of into every chunk of the object at address that into
// lacks, nodes and data, from from: the ref that names it commits it.
object_copy :: proc(from,into:^store.Store,address:store.Hash,scratch:[]u8) -> store.Error {
    if asset.object_whole(into,address) {return .None}
    copy_chunk :: proc(from,into:^store.Store,address:store.Hash,level:int,scratch:[]u8) -> store.Error {
        if len(scratch)<store.CHUNK_MAX {return .Corrupt}
        bytes:=store.chunk_read(from,address,scratch[:store.CHUNK_MAX]) or_return
        if store.address_of_bytes(bytes)!=address {return .Corrupt}
        if !store.chunk_here(into,address) {store.chunk_put(into,address,bytes) or_return}
        if level<0 {return .None}
        n:=store.node_parse(bytes) or_return
        if level!=DATA_OR_ANY && n.level!=level {return .Corrupt}
        for e in n.entries {copy_chunk(from,into,e.address,n.level-1 if n.level>0 else -1,scratch[store.CHUNK_MAX:]) or_return}
        return .None
    }
    return copy_chunk(from,into,address,DATA_OR_ANY,scratch)
}

@(private="file")
DATA_OR_ANY :: 1<<20 // the root: a node of any level
