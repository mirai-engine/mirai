package kai_assets

import "base:runtime"
import "core:crypto"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import "mirai:asset"
import "mirai:cook/cache"
import "mirai:std/blake3"
import "mirai:store"
import vcs "mirai:kai"

// What a project's imports and cooks share through the Kai mesh. A miss of
// cook/cache or of the library asks the machine's runner, through its control,
// for a signed DDC_Record a peer of the project's org published (the runner
// asks LAN peers before the others and keeps only what ddc_accept takes:
// writers, DDC nodes and ddc grant holders), and takes its output whole once
// the runner has every object the record lists; what an import or a cook keeps
// is published as this device's record, listing the object of the ref and, for
// a build, every object the build lists. The key of a result is the hash of
// its cache ref.
//
// A result made from a file of one of the project's scopes inherits those
// scopes (vcs.overlay_taint): its record names them as tainted and its output
// is one sealed blob of the chunks of its objects (vcs.Blob_Sealer),
// which only a device that reads every one of those scopes opens. Nodes,
// grant holders and members below the scopes' readers hold ciphertext at most.

LABEL_DDC_CACHE :: "kai-1/ddc-cache"
MESH_WAIT :: 10.0 // seconds a miss waits for peers
SEALED_VERSION :: 1 // of the chunks a sealed output holds

Mesh_Cache :: struct {
    machine:^vcs.Machine, // signs what is published; its store is the runner's
    control:vcs.Control,
    org:vcs.Log_Id,
    project:vcs.Log_Id, // whose scopes taint what is published; zero: no scope applies
    root:string,        // the project's folder, which its scopes' paths are under
    state:vcs.Org_State,
    keyrings:[dynamic]^vcs.Keyring_Fold,
    scoped:bool,        // keyrings are held
    stated:bool,        // state is held
    connected:bool,
    lock:sync.Mutex,    // the control and the machine are asked by one thread at a time
    taken,published:int, // results taken from peers and published since it opened
    allocator:runtime.Allocator,
}

// The key a cache ref is published under.
ddc_key :: proc(namespace,name:string) -> store.Hash {
    h:blake3.Hasher
    blake3.init(&h)
    blake3.update(&h,transmute([]u8)string(LABEL_DDC_CACHE))
    blake3.update(&h,transmute([]u8)namespace)
    zero:=[1]u8{0}
    blake3.update(&h,zero[:])
    blake3.update(&h,transmute([]u8)name)
    return store.Hash(blake3.final(&h))
}

// Shares the cache of the org's project through the runner of the machine's
// store, which hears through the control what m changes, so what is published
// reaches the peers at once; c stays where it is while open. Missing when no
// runner runs: the cook then builds alone. With
// project, the files under root what is kept is made from decide its scopes;
// when the org's scopes do not read, nothing is published.
mesh_cache_open :: proc(c:^Mesh_Cache,m:^vcs.Machine,org:vcs.Log_Id,project:=vcs.Log_Id{},root:="",allocator:=context.allocator) -> vcs.Error {
    c^={machine=m,org=org,project=project,allocator=allocator}
    vcs.control_open(&c.control,m.store.root) or_return
    c.connected=true
    m.changed=vcs.control_machine_changed(&c.control)
    if project=={} {return .None}
    c.root=strings.clone(root,allocator)
    if vcs.org_state_load(&m.store,org,&c.state,allocator)!=.None {
        vcs.org_state_destroy(&c.state)
        c.state={}
        return .None
    }
    c.stated=true
    c.keyrings=make([dynamic]^vcs.Keyring_Fold,allocator)
    c.scoped=vcs.machine_keyrings(&m.store,&c.state,&c.keyrings,allocator)==.None
    return .None
}

mesh_cache_close :: proc(c:^Mesh_Cache) {
    if c.connected {
        c.machine.changed={}
        vcs.control_close(&c.control)
    }
    for k in c.keyrings {
        l:=k.log
        vcs.keyring_fold_destroy(k)
        if l!=nil {
            vcs.log_destroy(l)
            free(l,c.allocator)
        }
        free(k,c.allocator)
    }
    delete(c.keyrings)
    if c.stated {vcs.org_state_destroy(&c.state)}
    delete(c.root,c.allocator)
    c^={}
}

// The source a cache.Cache of the machine's store takes.
mesh_source :: proc(c:^Mesh_Cache) -> cache.Source {
    return {fetch=mesh_fetch,kept=mesh_kept,user=c}
}

// What the imports and cooks of the project at root take from and give to
// its org's peers, through the runner of the store at store_root
// (cache.Peers_Open): when root is a workspace of a project of an org on this
// machine and the runner runs. Otherwise no source, and close is nil: the
// imports and cooks work alone, as without Kai.
peers_open :: proc(store_root,root:string) -> (source:cache.Source,close:cache.Peers_Close) {
    allocator:=context.allocator
    if store_root=="" || root=="" {return}
    repo,workspace:=vcs.workspace_repo_of(root)
    if !workspace {return}
    p:=new(Peers,allocator)
    if p==nil {return}
    p.allocator=allocator
    if vcs.machine_open(&p.machine,store_root,allocator)!=.None {
        free(p,allocator)
        return
    }
    folder,_:=filepath.abs(root,context.temp_allocator)
    project,org,linked:=vcs.machine_project_of(&p.machine,repo)
    if !linked || mesh_cache_open(&p.cache,&p.machine,org,project,folder,allocator)!=.None {
        peers_free(p)
        return
    }
    return mesh_source(&p.cache),peers_close
}

@(private="file")
Peers :: struct {
    cache:Mesh_Cache, // first: the user of the source is the Peers
    machine:vcs.Machine,
    allocator:runtime.Allocator,
}

@(private="file")
peers_close :: proc(source:cache.Source) -> (taken,published:int) {
    p:=(^Peers)(source.user)
    taken,published=p.cache.taken,p.cache.published
    peers_free(p)
    return
}

@(private="file")
peers_free :: proc(p:^Peers) {
    mesh_cache_close(&p.cache)
    vcs.machine_close(&p.machine)
    free(p,p.allocator)
}

@(private)
mesh_fetch :: proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool) {
    c:=(^Mesh_Cache)(user)
    if !c.connected {return}
    sync.mutex_lock(&c.lock)
    defer sync.mutex_unlock(&c.lock)
    Wanted :: struct {key,output_root:store.Hash,state:vcs.DDC_State}
    wanted:=make([]Wanted,len(names),context.temp_allocator)
    for name,k in names {wanted[k]={key=ddc_key(namespace,name),state=.Waiting}}
    start:=time.tick_now()
    for time.duration_seconds(time.tick_since(start))<MESH_WAIT {
        waiting:=false
        for &w in wanted {
            if w.state!=.Waiting {continue}
            state,output_root,e:=vcs.control_ddc_ask(&c.control,c.org,w.key)
            if e!=.None {return}
            w.state,w.output_root=state,output_root
            waiting||=w.state==.Waiting
        }
        if !waiting {break}
        time.sleep(20*time.Millisecond)
    }
    from:=store.read_index(&c.machine.store)
    for &w,k in wanted {
        if w.state!=.Found {continue}
        objects,e:=vcs.ddc_output_get(&from,w.output_root,context.temp_allocator)
        if e!=.None || len(objects)==0 {continue}
        if output_tainted(&from,c.org,w.key,w.output_root) {
            if objects,e=output_unseal(c,&from,into,objects[0]);e!=.None || len(objects)==0 {continue}
        } else if into.root!=from.root {
            whole:=true
            for o in objects {whole&&=cache.object_copy(&from,into,o)==.None}
            if !whole {continue}
        }
        given[k]=store.ref_set(into,namespace,names[k],objects[0])==.None
        if given[k] {c.taken+=1}
    }
}

// Publishes what the cache kept: the object of the ref and, for a build
// (asset.REF_IMPORTS, asset.REF_IMPORTS_FAST or asset.REF_BUILDS), every
// object the build lists, which must come with it; sealed when what it was
// made from falls in scopes of the project.
@(private)
mesh_kept :: proc(user:rawptr,namespace,name:string,object:store.Hash,from:[]string) {
    c:=(^Mesh_Cache)(user)
    if !c.connected {return}
    sync.mutex_lock(&c.lock)
    defer sync.mutex_unlock(&c.lock)
    s:=store.read_index(&c.machine.store)
    objects:=make([dynamic]store.Hash,context.temp_allocator)
    append(&objects,object)
    if namespace==asset.REF_IMPORTS || namespace==asset.REF_IMPORTS_FAST || namespace==asset.REF_BUILDS {
        b,e:=asset.build_get(&s,object,context.temp_allocator)
        if e!=.None {return}
        listed:=asset.Build_Objects{build=&b,with_thumbnails=true}
        for address in asset.build_object_next(&listed) {append(&objects,address)}
    }
    tainted:=make([dynamic]vcs.Scope_Id,context.temp_allocator)
    if c.project!={} {
        // Whose scopes cannot be told is not published.
        if !c.scoped {return}
        paths:=make([dynamic]string,context.temp_allocator)
        for file in from {
            if path,under:=project_path(c.root,file);under {append(&paths,path)}
        }
        if vcs.overlay_taint(&c.state.fold,c.project,paths[:],&tainted)!=.None {return}
    }
    if len(tainted)>0 {
        sealed,e:=output_seal(c,&s,objects[:],tainted[:])
        if e!=.None {return}
        clear(&objects)
        append(&objects,sealed)
    }
    if _,e:=vcs.machine_publish_ddc(c.machine,c.org,ddc_key(namespace,name),objects[:],tainted[:]);e==.None {c.published+=1}
}

// The path of file under the folder root, with forward slashes; false outside it.
@(private)
project_path :: proc(root,file:string) -> (path:string,under:bool) {
    if root=="" {return}
    slashed,_:=strings.replace_all(file,"\\","/",context.temp_allocator)
    top,_:=strings.replace_all(root,"\\","/",context.temp_allocator)
    top=strings.trim_right(top,"/")
    if !strings.has_prefix(slashed,top) || len(slashed)<=len(top)+1 || slashed[len(top)]!='/' {return}
    return slashed[len(top)+1:],true
}

// Whether the record of key whose output is output_root names tainted scopes.
@(private)
output_tainted :: proc(s:^store.Store,org:vcs.Log_Id,key,output_root:store.Hash) -> bool {
    records:=make([dynamic]vcs.DDC_Record,context.temp_allocator)
    vcs.ddc_lookup(s,org,key,&records)
    for d in records {
        if d.output_root==output_root {return len(d.tainted_scopes)>0}
    }
    return false
}

// One sealed blob of every chunk of objects, nodes and data, after the list of
// objects: u32 version, u32 objects, the objects, then each chunk as its
// address, u32 size and bytes, sealed as it is walked.
@(private)
output_seal :: proc(c:^Mesh_Cache,s:^store.Store,objects:[]store.Hash,tainted:[]vcs.Scope_Id) -> (sealed:store.Hash,error:vcs.Error) {
    device:=vcs.machine_device_of(&c.machine.store) or_return
    defer crypto.zero_explicit(&device,size_of(device))
    b:vcs.Blob_Sealer
    vcs.overlay_blob_begin(&b,&c.machine.store,c.keyrings[:],&device,c.project,tainted) or_return
    head:=[2]u32le{SEALED_VERSION,u32le(len(objects))}
    vcs.overlay_blob_write(&b,mem.slice_to_bytes(head[:]))
    vcs.overlay_blob_write(&b,mem.slice_to_bytes(objects))
    seen:=make(map[store.Hash]bool,context.temp_allocator)
    buffer:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
    walk :: proc(s:^store.Store,address:store.Hash,level,depth:int,buffer:[]u8,b:^vcs.Blob_Sealer,seen:^map[store.Hash]bool) -> vcs.Error {
        if depth>store.NODE_LEVEL_MAX+1 {return .Corrupt}
        if address in seen^ {return .None}
        seen^[address]=true
        chunk,e:=store.chunk_read(s,address,buffer)
        if e!=.None || store.address_of_bytes(chunk)!=address {return .Corrupt}
        a:=address
        size:=u32le(len(chunk))
        vcs.overlay_blob_write(b,a[:])
        vcs.overlay_blob_write(b,mem.ptr_to_bytes(&size))
        vcs.overlay_blob_write(b,chunk)
        if level<0 {return .None}
        n,pe:=store.node_parse(chunk)
        if pe!=.None || level!=ROOT_LEVEL && n.level!=level {return .Corrupt}
        entries:=make([]store.Entry,len(n.entries),context.temp_allocator)
        copy(entries,n.entries)
        below:=n.level-1 if n.level>0 else -1
        for x in entries {walk(s,x.address,below,depth+1,buffer,b,seen) or_return}
        return .None
    }
    for o in objects {
        if e:=walk(s,o,ROOT_LEVEL,0,buffer,&b,&seen);e!=.None {
            vcs.overlay_blob_abandon(&b)
            return {},e
        }
    }
    return vcs.overlay_blob_finish(&b)
}

// Opens the sealed blob of an output into the batch of into, chunk by chunk,
// each checked against its address: the objects it holds, the first the one
// the cache ref names. What it holds at once is one record and one opened chunk.
@(private)
output_unseal :: proc(c:^Mesh_Cache,from,into:^store.Store,sealed:store.Hash) -> (objects:[]store.Hash,error:vcs.Error) {
    if !c.scoped {return nil,.Unauthorized}
    device:=vcs.machine_device_of(&c.machine.store) or_return
    defer crypto.zero_explicit(&device,size_of(device))
    r:vcs.Blob_Reader
    vcs.overlay_blob_open(&r,from,c.keyrings[:],&device,sealed) or_return
    defer vcs.overlay_blob_close(&r)
    RECORD :: size_of(store.Hash)+4
    pending:=make([]u8,RECORD+store.CHUNK_MAX+vcs.OVERLAY_CHUNK_MAX,context.temp_allocator)
    have:=0
    count:=-1
    listed:=make([dynamic]store.Hash,context.temp_allocator)
    for {
        plain:=vcs.overlay_blob_next(&r) or_return
        if len(plain)==0 {break}
        have+=copy(pending[have:],plain)
        at:=0
        for {
            rest:=pending[at:have]
            if count<0 {
                if len(rest)<8 {break}
                head:=(^[2]u32le)(raw_data(rest))^
                if head[0]!=SEALED_VERSION || head[1]==0 || int(head[1])>vcs.DDC_OUTPUT_MAX {return nil,.Corrupt}
                count=int(head[1])
                at+=8
            } else if len(listed)<count {
                if len(rest)<size_of(store.Hash) {break}
                o:store.Hash
                copy(o[:],rest)
                append(&listed,o)
                at+=size_of(store.Hash)
            } else {
                if len(rest)<RECORD {break}
                size:=int((^u32le)(raw_data(rest[size_of(store.Hash):]))^)
                if size==0 || size>store.CHUNK_MAX {return nil,.Corrupt}
                if len(rest)<RECORD+size {break}
                address:store.Hash
                copy(address[:],rest)
                chunk:=rest[RECORD:][:size]
                if store.address_of_bytes(chunk)!=address {return nil,.Corrupt}
                if !store.chunk_here(into,address) && store.chunk_put(into,address,chunk)!=.None {return nil,.Io}
                at+=RECORD+size
            }
        }
        copy(pending,pending[at:have])
        have-=at
    }
    if have!=0 || count<0 || len(listed)!=count {return nil,.Corrupt}
    for o in listed {
        if !asset.object_whole(into,o,false) {return nil,.Corrupt}
    }
    return listed[:],.None
}

@(private="file")
ROOT_LEVEL :: 1<<20 // the root of an object: a node of any level

// Publishes the bookmarks of a workspace as this device's signed refs of its
// project, when the repository is a project of an org: the mesh sends them
// to the org's peers at once. Nothing when it is not.
bookmarks_publish :: proc(p:^Project,m:^vcs.Machine) -> vcs.Error {
    r:=&p.workspace.repo
    project,_,ok:=vcs.machine_project_of(m,r.id)
    if !ok {return .None}
    refs:=make([dynamic]vcs.Bookmark_Ref,context.temp_allocator)
    for &b in r.view.bookmarks {
        if target,resolved:=vcs.terms_resolved(&b.terms);resolved && target!={} {
            append(&refs,vcs.Bookmark_Ref{name=b.name,target=target})
        }
    }
    return vcs.machine_publish_refs(m,project,refs[:])
}

// The identity of this machine: the seed kept in the root of the store, made
// the first time (vcs.machine_identity).
identity_load :: proc(s:^store.Store) -> (identity:vcs.Identity,error:vcs.Error) {
    return vcs.machine_identity(s)
}
