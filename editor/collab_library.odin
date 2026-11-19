package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "mirai:asset"
import "mirai:cook/share"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"
import "mirai:store"
import "mirai:ui"

// The libraries of the other editors of a session (cook/share/library.odin):
// the packages each one's machine exposes over the session, beside this
// machine's library (library.odin). Listing them and taking one run on threads
// of their own that wait on the node; a package taken is in this machine's
// library from then on, and is then added as one of it is.

COLLAB_LIBRARY_SECONDS :: 10.0 // a listing older than this is read again when it is shown

@(private)
Collab_Library :: struct {
    peer:int,           // in Collab_State.peers
    node:share.Peer,
    list:[]share.Peer_Package,
    error:string,
}

@(private)
Collab_Libraries :: struct {
    thread:^thread.Thread,
    done:bool,
    node:^share.Node,
    arena:mem.Dynamic_Arena,
    allocator:runtime.Allocator,
    libraries:[COLLAB_PEERS]Collab_Library,
    count:int,
    at:f64,
}

@(private)
Collab_Take :: struct {
    thread:^thread.Thread,
    done:bool,
    node:^share.Node,
    manifest:store.Hash,
    id:base.Asset_Id,
    name:[64]u8,
    root:string,
    folder:string,
    error:string,
    received:u64, // of the node when it began
    arena:mem.Dynamic_Arena,
    allocator:runtime.Allocator,
}

// The peers of the node, each with the place in the session of its editor.
@(private)
collab_library_peers :: proc(st:^Collab_State,into:[]Collab_Library) -> int {
    buffer:[share.PEERS]share.Peer
    count:=0
    for p in share.node_peers(st.node,buffer[:]) {
        for &peer,i in st.peers {
            if i==int(st.self) || !peer.used || peer.connection!=p.connection {continue}
            if count<len(into) {into[count]={peer=i,node=p};count+=1}
        }
    }
    return count
}

// Starts reading the libraries of the peers again, unless a reading runs or
// the last is younger than COLLAB_LIBRARY_SECONDS; force: in any case but the first.
@(private)
collab_libraries_read :: proc(st:^Collab_State,force:=false) {
    if st.node==nil || st.phase!=.Joined {return}
    collab_libraries_promote(st)
    if st.reading!=nil {return}
    now:=collab_now(st)
    if l:=st.libraries;l!=nil && !force && now-l.at<COLLAB_LIBRARY_SECONDS {return}
    l:=new(Collab_Libraries)
    mem.dynamic_arena_init(&l.arena,runtime.heap_allocator(),runtime.heap_allocator())
    l.allocator=base.dynamic_arena_allocator(&l.arena)
    l.node,l.at=st.node,now
    l.count=collab_library_peers(st,l.libraries[:])
    st.reading=l
    l.thread=thread.create_and_start_with_poly_data(l,proc(l:^Collab_Libraries) {
        defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
        for &library in l.libraries[:l.count] {
            library.list,library.error=share.peer_library(l.node,library.node,l.allocator)
            library.error=strings.clone(library.error,l.allocator)
            free_all(context.temp_allocator)
        }
        sync.atomic_store(&l.done,true)
    })
    if l.thread==nil {sync.atomic_store(&l.done,true)}
}

// A reading that ended replaces what is shown, which stays meanwhile.
@(private)
collab_libraries_promote :: proc(st:^Collab_State) {
    r:=st.reading
    if r==nil || !sync.atomic_load(&r.done) {return}
    if st.libraries!=nil {collab_libraries_free(st.libraries)}
    st.libraries,st.reading=r,nil
}

@(private)
collab_libraries_free :: proc(l:^Collab_Libraries) {
    if l.thread!=nil {
        thread.join(l.thread)
        thread.destroy(l.thread)
    }
    mem.dynamic_arena_destroy(&l.arena)
    free(l)
}

@(private)
collab_take_free :: proc(t:^Collab_Take) {
    if t.thread!=nil {
        thread.join(t.thread)
        thread.destroy(t.thread)
    }
    mem.dynamic_arena_destroy(&t.arena)
    free(t)
}

// The package of a peer's library, by its id or its name; what failed, as how to fix it.
@(private)
collab_library_find :: proc(s:^Session,st:^Collab_State,peer:int,named:string) -> (p:share.Peer_Package,problem:string) {
    collab_libraries_promote(st)
    l:=st.libraries
    if l==nil {return {},"the libraries of the peers are being read: call packages.peers until listing is false"}
    wanted:=strings.trim_space(named)
    id,is_id:=serial.text_parse_asset_id(wanted)
    for &library in l.libraries[:l.count] {
        if library.peer!=peer {continue}
        found:=-1
        for &q,at in library.list {
            if !(is_id && q.id==id || !is_id && q.name==wanted) {continue}
            if found>=0 {return {},fmt.tprintf("name: more than one package of that library is named %q: give its id, as packages.peers lists them",wanted)}
            found=at
        }
        if found<0 {return {},fmt.tprintf("name: the library of %s has no package %q: packages.peers lists it",collab_peer_name(s,peer),wanted)}
        return library.list[found],""
    }
    return {},fmt.tprintf("peer: %d is not an editor of the session whose library is listed: packages.peers lists them",peer)
}

// Takes a package of a peer's library into this machine's, then adds it to
// folder as one of this machine's library is added. What failed, as how to fix it.
@(private)
collab_library_add :: proc(s:^Session,peer:int,named,folder:string) -> string {
    st:=collab_state(s)
    if st==nil || st.node==nil || st.phase!=.Joined {return "this editor is in no session: the libraries of others are those of the editors of a session (collab.host or collab.join)"}
    if st.take!=nil && !sync.atomic_load(&st.take.done) {return "a package of a peer is being added: wait for it, as packages.peers says"}
    if busy:=import_busy(s);busy!="" {return busy}
    p,problem:=collab_library_find(s,st,peer,named)
    if problem!="" {return problem}
    if st.take!=nil {collab_take_free(st.take)}
    t:=new(Collab_Take)
    mem.dynamic_arena_init(&t.arena,runtime.heap_allocator(),runtime.heap_allocator())
    t.allocator=base.dynamic_arena_allocator(&t.arena)
    t.node,t.manifest,t.id=st.node,p.manifest,p.id
    base.text_set(t.name[:],p.name)
    t.root=strings.clone(s.project_root,t.allocator)
    t.folder=strings.clone(folder,t.allocator)
    t.received=share.node_totals(st.node).received
    st.take=t
    t.thread=thread.create_and_start_with_poly_data(t,proc(t:^Collab_Take) {
        defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
        js:jobs.Job_System
        threaded:=jobs.system_init(&js,{threads=max(os.get_processor_core_count()-2,0),allocator=runtime.heap_allocator()})
        worker:=jobs.Worker_Ref{}
        if threaded {worker={system=&js,worker=jobs.OWNER}}
        t.error=strings.clone(share.package_take(t.node,t.manifest,t.root,import_library,worker),t.allocator)
        if threaded {jobs.system_destroy(&js)}
        sync.atomic_store(&t.done,true)
    })
    if t.thread==nil {
        sync.atomic_store(&t.done,true)
        t.error="no thread could be started to fetch it"
    }
    return ""
}

// The end of a take, on the editor's thread: added as a package of this machine.
@(private)
collab_take_update :: proc(s:^Session,st:^Collab_State) {
    t:=st.take
    if t==nil || t.thread==nil || !sync.atomic_load(&t.done) {return}
    thread.join(t.thread)
    thread.destroy(t.thread)
    t.thread=nil
    name:=base.text_get(t.name[:])
    if t.error!="" {
        notify(s,fmt.tprintf("%s was not added: %s",name,t.error))
        return
    }
    buffer:[base.ASSET_ID_TEXT]u8
    if problem:=library_add(s,base.asset_id_format(t.id,buffer[:]),nil,t.folder);problem!="" {
        t.error=strings.clone(problem,t.allocator)
        notify(s,fmt.tprintf("%s is in this machine's library now but was not added: %s",name,problem))
    }
    // Read again: it is here now.
    if st.libraries!=nil {st.libraries.at=-COLLAB_LIBRARY_SECONDS}
}

// Stops what reads and takes from the peers; the node was closed, so they end at once.
@(private)
collab_library_destroy :: proc(st:^Collab_State) {
    if st.libraries!=nil {collab_libraries_free(st.libraries)}
    if st.reading!=nil {collab_libraries_free(st.reading)}
    if st.take!=nil {collab_take_free(st.take)}
    st.libraries,st.reading,st.take=nil,nil,nil
}

// ---------------------------------------------------------------- packages.peers, packages.peer_add

Api_Packages_Peers_Params :: struct {
    refresh:bool `mirai:"optional,label=Read the libraries again now"`,
    seconds:int `mirai:"optional,min=0,max=600,unit=s,label=How long it waits for the reading to end; 0: it answers at once"`,
}

Api_Peer_Package :: struct {
    id:base.Asset_Id,
    name:string,
    kinds:[]string,
    assets:int,
    bytes:i64 `mirai:"label=Of the build the peer has; -1: unknown"`,
    built:bool `mirai:"label=The peer has a build of it this engine reads"`,
    here:bool `mirai:"label=This machine has it with that build: adding it fetches nothing"`,
    pinned:bool `mirai:"label=The project pins it"`,
}

Api_Peer_Library :: struct {
    peer:u8 `mirai:"label=The id of the editor in the session, as collab.status gives it"`,
    name:string,
    error:string `mirai:"label=Why its library could not be read"`,
    packages:[]Api_Peer_Package,
}

Api_Peer_Adding :: struct {
    name:string,
    adding:bool `mirai:"label=Its fetch runs"`,
    received:u64 `mirai:"label=Chunk bytes received since it began"`,
    error:string `mirai:"label=Why it was not added; the project did not change"`,
}

Api_Packages_Peers_Result :: struct {
    listing:bool `mirai:"label=The libraries are being read"`,
    libraries:[]Api_Peer_Library `mirai:"label=Of the editors of the session that are connected; one that left is not listed"`,
    adding:Api_Peer_Adding `mirai:"label=The last package taken from a peer"`,
}

Api_Packages_Peer_Add_Params :: struct {
    peer:int `mirai:"min=0,max=7,label=The editor whose library has it, as packages.peers lists it"`,
    name:string `mirai:"label=The package: its id or its name, as packages.peers lists them"`,
    folder:string `mirai:"optional,label=The folder under the asset folder it is listed in; none: the root of the assets"`,
    seconds:int `mirai:"optional,min=1,max=7200,unit=s,label=How long it waits for the end of the add; past that it answers adding and the add goes on"`,
}

@(private)
collab_library_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="packages.peers",summary="The packages the machines of the other editors of the session expose in their libraries, by editor, each with its size and whether this machine has it. Read on a thread: with seconds it waits for the reading.",params=type_info_of(Api_Packages_Peers_Params),result=type_info_of(Api_Packages_Peers_Result),run=api_packages_peers})
    api_register(s,st,{name="packages.peer_add",summary="Takes a package of a peer's library into this machine's, its build included, and adds it to the project as packages.add does; if the peer leaves before it is here, the project does not change and adding says why.",params=type_info_of(Api_Packages_Peer_Add_Params),result=type_info_of(Api_Packages_Peers_Result),run=api_packages_peer_add})
}

@(private)
api_packages_peers_answer :: proc(s:^Session,call:^api.Call) {
    r:=api.call_result(call,Api_Packages_Peers_Result)
    st:=collab_state(s)
    if st==nil {return}
    a:=call.allocator
    pinned:=make(map[base.Asset_Id]bool,context.temp_allocator)
    if list,_,error:=asset.packages_load(s.project_root,context.temp_allocator);error==.None {
        for entry in list.packages {pinned[entry.id]=true}
    }
    collab_libraries_promote(st)
    r.listing=st.reading!=nil
    if l:=st.libraries;l!=nil {
        {
            out:=make([dynamic]Api_Peer_Library,a)
            for &library in l.libraries[:l.count] {
                if !st.peers[library.peer].used {continue}
                entry:=Api_Peer_Library{peer=u8(library.peer),name=strings.clone(collab_peer_name(s,library.peer),a),error=strings.clone(library.error,a)}
                packages:=make([]Api_Peer_Package,len(library.list),a)
                for &p,k in library.list {
                    kinds:=make([]string,len(p.kinds),a)
                    for kind,i in p.kinds {
                        kinds[i]="other"
                        if info,known:=asset.kind_info(kind);known {kinds[i]=strings.clone(info.name,a)}
                    }
                    packages[k]={id=p.id,name=strings.clone(p.name,a),kinds=kinds,assets=p.assets,bytes=p.bytes,built=p.built,here=p.here,pinned=pinned[p.id]}
                }
                entry.packages=packages
                append(&out,entry)
            }
            r.libraries=out[:]
        }
    }
    if t:=st.take;t!=nil {
        done:=sync.atomic_load(&t.done)
        r.adding={name=strings.clone(base.text_get(t.name[:]),a),adding=!done,received=share.node_totals(st.node).received-t.received}
        if done {r.adding.error=strings.clone(t.error,a)}
    }
}

@(private)
api_packages_peers :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Packages_Peers_Params)
    st:=collab_state(s)
    if st==nil || st.node==nil || st.phase!=.Joined {
        api.call_fail(call,api.INVALID_PARAMS,"this editor is in no session: the libraries of others are those of the editors of a session (collab.host or collab.join)")
        return
    }
    collab_libraries_read(st,params.refresh)
    listing :: proc(s:^Session,user:rawptr) -> bool {
        st:=collab_state(s)
        if st==nil {return false}
        collab_libraries_promote(st)
        return st.reading!=nil
    }
    if params.seconds>0 {api_wait(s,f64(params.seconds),nil,listing,"listing")}
    api_packages_peers_answer(s,call)
}

@(private)
api_packages_peer_add :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Packages_Peer_Add_Params)
    if problem:=collab_library_add(s,params.peer,params.name,params.folder);problem!="" {
        api.call_fail(call,api.INVALID_PARAMS,problem)
        return
    }
    adding :: proc(s:^Session,user:rawptr) -> bool {
        st:=collab_state(s)
        return st!=nil && st.take!=nil && (st.take.thread!=nil || s.importer.running!=nil)
    }
    api_wait(s,f64(params.seconds>0?params.seconds:600),nil,adding,"adding")
    api_packages_peers_answer(s,call)
}
