package share

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "mirai:asset"
import "mirai:cook/import/sources"
import "mirai:exchange"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:store"
import wire "mirai:net"

// The libraries of the peers of a node: the packages each one's machine
// exposes (asset.REF_PACKAGES, with the builds of asset.REF_IMPORTS and
// asset.REF_IMPORTS_FAST, which node_expose already lets it read), and taking
// one of them into this machine's library, builds included, so a project then
// pins it as a package ingested here. Everything a peer names is fetched by
// address and read only through asset's checks of manifests and builds.

// A connected peer of the node.
Peer :: struct {
    host:^wire.Host,
    connection:wire.Connection,
    number:int, // given in order of arrival, as Event.peer
}

// The connected peers, into buffer.
node_peers :: proc(n:^Node,buffer:[]Peer) -> []Peer {
    sync.mutex_guard(&n.lock)
    count:=0
    for p in n.peers {
        if !p.used || count==len(buffer) {continue}
        buffer[count]={p.host,p.connection,p.number}
        count+=1
    }
    return buffer[:count]
}

// A package a peer's library exposes. bytes: of the objects of the build it
// has, -1 when unknown; built: it has a build this engine reads; here: this
// machine has its manifest and that build whole, so adding it fetches nothing.
Peer_Package :: struct {
    id:base.Asset_Id,
    manifest:store.Hash,
    name:string,
    origin:string, // where its source was on the machine that ingested it, which tells apart two of one name
    catalog_path:string,
    kinds:[]asset.Fourcc,
    assets:[]Peer_Package_Asset,
    root:store.Hash,      // the object its card shows (asset.build_shown) in the build it has; zero: none
    objects:[]store.Hash, // of every asset of that build, sorted

    bytes:i64,
    built,here:bool,
}

Peer_Package_Asset :: struct {
    id:base.Asset_Id,
    name:string,
    kind:asset.Fourcc,
}

@(private) LIBRARY_NAMES_MAX :: 1<<14 // names of one namespace a listing reads of a peer
@(private) SIZE_SECONDS :: 10.0      // the most a listing waits for the sizes of objects

// The packages the library of peer exposes, by name, with their builds; error
// says why there is none (the peer left, or answers nothing). For a thread
// other than the pump's. In allocator.
peer_library :: proc(n:^Node,peer:Peer,allocator:=context.allocator) -> (list:[]Peer_Package,error:string) {
    packages,packages_error:=peer_names(n,peer,asset.REF_PACKAGES)
    if packages_error!="" {return nil,packages_error}
    builds:=make([dynamic]exchange.Name,context.temp_allocator)
    for namespace in ([2]string{asset.REF_IMPORTS,asset.REF_IMPORTS_FAST}) {
        names,names_error:=peer_names(n,peer,namespace)
        if names_error!="" {return nil,names_error}
        append(&builds,..names)
    }
    // The manifests and the builds are small: fetched together. A manifest is
    // named by the hash of its text, its object by asset.REF_MANIFESTS.
    manifests_fetch(n,packages[:])
    wanted:=make([dynamic]store.Hash,context.temp_allocator)
    for b in builds {append(&wanted,b.address)}
    objects_fetch(&n.x,wanted[:])
    s:=n.s
    chosen:=make(map[base.Asset_Id]asset.Build,context.temp_allocator)
    for b in builds {
        if !asset.object_whole(s,b.address) {continue}
        build,build_error:=asset.build_get(s,b.address,context.temp_allocator)
        if build_error!=.None {continue}
        // Final over Fast.
        if had,known:=chosen[build.package_id];known && had.final {continue}
        chosen[build.package_id]=build
    }
    out:=make([dynamic]Peer_Package,allocator)
    sizes:=make([dynamic]store.Hash,context.temp_allocator)
    for named in packages {
        p,package_error:=asset.package_get(s,named.address,context.temp_allocator)
        if package_error!=.None {continue}
        kinds:=make([dynamic]asset.Fourcc,allocator)
        assets:=make([]Peer_Package_Asset,len(p.assets),allocator)
        for a,at in p.assets {
            assets[at]={a.id,strings.clone(a.name,allocator),a.kind}
            known:=false
            for k in kinds {known||=k==a.kind}
            if !known {append(&kinds,a.kind)}
        }
        entry:=Peer_Package{id=p.id,manifest=named.address,name=strings.clone(p.name,allocator),origin=strings.clone(p.origin.path,allocator),kinds=kinds[:],assets=assets,bytes=-1}
        entry.catalog_path=strings.clone(p.catalog_path,allocator)
        // Whether it is here is read before the sizes are asked, which may bring a small object whole.
        if b,built:=chosen[p.id];built {
            entry.built,entry.here=true,asset.build_whole(s,&b)
            objects:=make([]store.Hash,len(b.outputs),allocator)
            entry.root,_=asset.build_shown(&b,&p)
            for o,k in b.outputs {
                append(&sizes,o.object)
                objects[k]=o.object
            }
            append(&sizes,..b.programs[:])
            slice.sort_by(objects,proc(a,b:store.Hash) -> bool {
                a,b:=a,b
                return string(a[:])<string(b[:])
            })
            entry.objects=objects
        }
        append(&out,entry)
    }
    known:=objects_sizes(n,sizes[:])
    for &entry in out {
        b,built:=chosen[entry.id]
        if !built {continue}
        total:i64
        objects:=asset.Build_Objects{build=&b}
        for address in asset.build_object_next(&objects) {
            size,sized:=known[address]
            if !sized {total=-1;break}
            total+=size
        }
        entry.bytes=total
    }
    slice.sort_by(out[:],proc(a,b:Peer_Package) -> bool {return a.name<b.name || a.name==b.name && a.id[0]<b.id[0]})
    return out[:],""
}

// The manifests of packages this store lacks, from the peers, as a refresh asks them.
@(private)
manifests_fetch :: proc(n:^Node,packages:[]exchange.Name) {
    names:=make([dynamic]string,context.temp_allocator)
    for p in packages {
        digits:=new([64]u8,context.temp_allocator)
        name:=store.hex(p.address,digits)
        if _,error:=store.ref_get(n.s,asset.REF_MANIFESTS,name);error!=.None {append(&names,name)}
    }
    given:=make([]bool,len(names),context.temp_allocator)
    node_fetch(n,n.s,asset.REF_MANIFESTS,names[:],given)
}

// The names of namespace peer exposes, page by page.
@(private)
peer_names :: proc(n:^Node,peer:Peer,namespace:string) -> (names:[]exchange.Name,error:string) {
    out:=make([dynamic]exchange.Name,context.temp_allocator)
    after:=""
    for len(out)<LIBRARY_NAMES_MAX {
        q,ask_error:=exchange.names_ask(&n.x,peer.host,peer.connection,namespace,after)
        if ask_error!=.None {return nil,"the peer is not connected any more"}
        result:exchange.Query_Result
        for {
            r,ok:=exchange.query_result(&n.x,q)
            if !ok {return nil,"the question to the peer was lost"}
            if r.state!=.Waiting {result=r;break}
            if !node_peer_alive(n,peer) {
                exchange.query_end(&n.x,q)
                return nil,"the peer left"
            }
            if !node_wait(n,0.02) {return nil,"stopped"}
        }
        for name in result.names {append(&out,exchange.Name{strings.clone(name.name,context.temp_allocator),name.address})}
        more:=result.more && len(result.names)>0
        if more {after=out[len(out)-1].name}
        exchange.query_end(&n.x,q)
        if !more {break}
    }
    return out[:],""
}

@(private)
node_peer_alive :: proc(n:^Node,peer:Peer) -> bool {
    sync.mutex_guard(&n.lock)
    for p in n.peers {
        if p.used && p.host==peer.host && p.connection==peer.connection {return true}
    }
    return false
}

// The size of each object of addresses: here, or as its root says once it
// arrives from a peer (exchange.measure): nothing else of the object is fetched. Those whose root no
// peer sends within SIZE_SECONDS are left out.
@(private)
objects_sizes :: proc(n:^Node,addresses:[]store.Hash) -> map[store.Hash]i64 {
    sizes:=make(map[store.Hash]i64,context.temp_allocator)
    asking:=make([dynamic]store.Hash,context.temp_allocator)
    for address in addresses {
        if address in sizes {continue}
        if o,error:=store.object_open(n.s,address);error==.None {
            sizes[address]=i64(store.object_size(&o))
            store.object_close(&o)
            continue
        }
        // Its root alone: none of what the object holds is fetched to know its size.
        if exchange.measure(&n.x,address)==.None {append(&asking,address)}
    }
    defer for address in asking {exchange.forget(&n.x,address)}
    started:=node_now(n)
    for len(asking)>0 && node_now(n)-started<SIZE_SECONDS {
        for k:=0;k<len(asking); {
            p,_:=exchange.progress(&n.x,asking[k])
            if p.total>=0 || p.state==.Failed || p.state==.Complete {
                if p.total>=0 {sizes[asking[k]]=p.total}
                exchange.forget(&n.x,asking[k])
                unordered_remove(&asking,k)
                continue
            }
            k+=1
        }
        if len(asking)>0 && !node_wait(n,0.02) {break}
    }
    return sizes
}

// Takes the package of manifest from the peers into this machine's library:
// its manifest and the build of it this engine reads, Fast textures allowed,
// fetched as a join fetches the builds of a project, and its name under
// asset.REF_PACKAGES, so it stays in the library once the peers leave. root:
// the project it is for, whose plugins read a source should one be here.
// Nothing is pinned: on failure no project changed. For a thread other than
// the pump's.
package_take :: proc(n:^Node,manifest:store.Hash,root:string,library:sources.Library=nil,worker:=jobs.Worker_Ref{}) -> (error:string) {
    s:=n.s
    named:=[1]exchange.Name{{address=manifest}}
    manifests_fetch(n,named[:])
    p,package_error:=asset.package_get(s,manifest,context.temp_allocator)
    if package_error!=.None {
        digits:[64]u8
        if _,ref_error:=store.ref_get(s,asset.REF_MANIFESTS,store.hex(manifest,&digits));ref_error!=.None {return "no connected peer has its manifest any more: the peer that offered it left; add it again once it is back"}
        return fmt.tprintf("its manifest is not one this engine reads (%v): the peer runs another version of Mirai",package_error)
    }
    // A project of its own under the generated folder of root, which pins the
    // package and refreshes it from the peers, then goes: what it fetched stays in the store.
    digits:[64]u8
    scratch:=project.path(project.folder_path(root,.Generated,context.temp_allocator),"tmp",fmt.tprintf("share-take-%s",store.hex(manifest,&digits)[:16]),allocator=context.temp_allocator)
    base.remove_all(scratch)
    if os.make_directory_all(scratch)!=nil {return fmt.tprintf("%s could not be made: give this user access to %s",scratch,root)}
    defer base.remove_all(scratch)
    options:=sources.Library_Options{store=s,source=node_source(n),fast_textures=true,root=root,plugins=library,worker=worker}
    report:=sources.project_add(scratch,manifest,"",nil,options,context.temp_allocator)
    if len(report.failures)>0 {return report.failures[0]}
    if len(report.missing)>0 || report.fetched+report.ingested==0 && !package_built(s,manifest,&p) {
        return fmt.tprintf("%s: no connected peer gave its build any more, and its source is not on this machine: the peer that offered it left; add it again once it is back",p.name)
    }
    buffer:[base.ASSET_ID_TEXT]u8
    if store.ref_set(s,asset.REF_PACKAGES,base.asset_id_format(p.id,buffer[:]),manifest)!=.None {
        return fmt.tprintf("%s could not be kept in the library of the store at %s: free space there",p.name,s.root)
    }
    return ""
}

// Whether this machine has a build of p it chose and has whole.
@(private)
package_built :: proc(s:^store.Store,manifest:store.Hash,p:^asset.Package) -> bool {
    digits:[64]u8
    hash,ref_error:=store.ref_get(s,asset.REF_BUILDS,store.hex(asset.build_select(manifest,p),&digits))
    if ref_error!=.None {return false}
    b,error:=asset.build_get(s,hash,context.temp_allocator)
    if error!=.None {return false}
    return asset.build_whole(s,&b)
}

// A ref one peer names, and the small object it names, fetched without
// waiting: for derived data a peer has or lacks (a thumbnail), never asked of
// another peer, and never made on request. fetch_poll steps it from the thread
// that pumps; a peer that leaves ends it as Absent.
Fetch_State :: enum u8 {Asking,Fetching,Done,Absent}

Fetch :: struct {
    peer:Peer,
    namespace,name:string, // held by the caller while it fetches
    query:exchange.Query,
    address:store.Hash,
    state:Fetch_State,
}

fetch_start :: proc(n:^Node,peer:Peer,namespace,name:string) -> (f:Fetch) {
    f={peer=peer,namespace=namespace,name=name}
    if _,error:=store.ref_get(n.s,namespace,name);error==.None {
        f.state=.Done
        return
    }
    q,error:=exchange.ref_ask(&n.x,namespace,name,peer.host,peer.connection)
    if error!=.None {f.state=.Absent;return}
    f.query=q
    return
}

// One step of a fetch: the answer of the peer, then the object, which this
// store keeps under the same ref once it is here.
fetch_poll :: proc(n:^Node,f:^Fetch) -> Fetch_State {
    switch f.state {
    case .Done,.Absent:
    case .Asking:
        r,ok:=exchange.query_result(&n.x,f.query)
        if !ok || r.state==.Not_Found || r.state==.Waiting && !node_peer_alive(n,f.peer) {
            if ok {exchange.query_end(&n.x,f.query)}
            f.state=.Absent
            break
        }
        if r.state==.Waiting {break}
        f.address=r.address
        exchange.query_end(&n.x,f.query)
        if exchange.want(&n.x,f.address,1<<20)!=.None {f.state=.Absent;break}
        f.state=.Fetching
    case .Fetching:
        p,_:=exchange.progress(&n.x,f.address)
        #partial switch p.state {
        case .Complete:
            exchange.forget(&n.x,f.address)
            f.state=store.ref_set(n.s,f.namespace,f.name,f.address)==.None?.Done:.Absent
        case .Failed,.Missing:
            exchange.forget(&n.x,f.address)
            f.state=.Absent
        case:
            if !node_peer_alive(n,f.peer) {
                exchange.forget(&n.x,f.address)
                f.state=.Absent
            }
        }
    }
    return f.state
}

// Lets go of a fetch that did not end.
fetch_end :: proc(n:^Node,f:^Fetch) {
    #partial switch f.state {
    case .Asking: exchange.query_end(&n.x,f.query)
    case .Fetching: exchange.forget(&n.x,f.address)
    }
    f.state=.Absent
}
