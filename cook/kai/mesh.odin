package kai_assets

import "core:time"
import "mirai:asset"
import "mirai:cook/cache"
import "mirai:std/blake3"
import "mirai:store"
import vcs "mirai:kai"

// What a project's cook shares through the Kai mesh. A miss of cook/cache
// asks the machine's runner, through its control, for a signed DDC_Record a
// peer of the project's org published (the runner asks LAN peers before the
// others and keeps only what ddc_accept takes: writers, DDC nodes and ddc
// grant holders), and takes its output; what a build keeps is published as
// this device's record. The key of a result is the hash of its cache ref.

LABEL_DDC_CACHE :: "kai-1/ddc-cache"
MESH_WAIT :: 10.0 // seconds a miss waits for peers

Mesh_Cache :: struct {
    machine:^vcs.Machine, // signs what is published; its store is the runner's
    control:vcs.Control,
    org:vcs.Log_Id,
    connected:bool,
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
// store. Missing when no runner runs: the cook then builds alone.
mesh_cache_open :: proc(c:^Mesh_Cache,m:^vcs.Machine,org:vcs.Log_Id) -> vcs.Error {
    c^={machine=m,org=org}
    vcs.control_open(&c.control,m.store.root) or_return
    c.connected=true
    return .None
}

mesh_cache_close :: proc(c:^Mesh_Cache) {
    if c.connected {vcs.control_close(&c.control)}
    c^={}
}

// The source a cache.Cache of the machine's store takes.
mesh_source :: proc(c:^Mesh_Cache) -> cache.Source {
    return {fetch=mesh_fetch,kept=mesh_kept,user=c}
}

@(private)
mesh_fetch :: proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool) {
    c:=(^Mesh_Cache)(user)
    if !c.connected {return}
    Wanted :: struct {key,output:store.Hash,state:vcs.DDC_State,objects:[dynamic]store.Hash}
    wanted:=make([]Wanted,len(names),context.temp_allocator)
    for name,k in names {wanted[k]={key=ddc_key(namespace,name),state=.Waiting}}
    start:=time.tick_now()
    for time.duration_seconds(time.tick_since(start))<MESH_WAIT {
        waiting:=false
        for &w in wanted {
            if w.state!=.Waiting {continue}
            if w.output=={} {
                state,output,e:=vcs.control_ddc_ask(&c.control,c.org,w.key)
                if e!=.None {return}
                w.state=state
                if state==.Found {
                    w.output,w.state=output,.Waiting
                    mesh_listed(c,into,namespace,output,&w.objects)
                }
            } else {
                // The objects a build lists come with it.
                w.state=.Found
                for o in w.objects {
                    state,e:=vcs.control_object_ask(&c.control,c.org,o)
                    if e!=.None {return}
                    if state==.Missing {w.state=.Missing}
                    if state==.Waiting && w.state==.Found {w.state=.Waiting}
                }
            }
            waiting||=w.state==.Waiting
        }
        if !waiting {break}
        time.sleep(20*time.Millisecond)
    }
    for &w,k in wanted {
        if w.state!=.Found {continue}
        if into.root!=c.machine.store.root {
            if cache.object_copy(&c.machine.store,into,w.output)!=.None {continue}
            for o in w.objects {
                if cache.object_copy(&c.machine.store,into,o)!=.None {continue}
            }
        }
        given[k]=store.ref_set(into,namespace,names[k],w.output)==.None
    }
}

// The objects a build at object lists, which must be here with it.
@(private)
mesh_listed :: proc(c:^Mesh_Cache,s:^store.Store,namespace:string,object:store.Hash,out:^[dynamic]store.Hash) {
    out^=make([dynamic]store.Hash,context.temp_allocator)
    if namespace!=asset.REF_IMPORTS && namespace!=asset.REF_IMPORTS_FAST && namespace!=asset.REF_BUILDS {return}
    b,e:=asset.build_get(&c.machine.store,object,context.temp_allocator)
    if e!=.None {return}
    objects:=asset.Build_Objects{build=&b,with_thumbnails=true}
    for address in asset.build_object_next(&objects) {append(out,address)}
}

@(private)
mesh_kept :: proc(user:rawptr,namespace,name:string,object:store.Hash) {
    c:=(^Mesh_Cache)(user)
    vcs.machine_publish_ddc(c.machine,c.org,ddc_key(namespace,name),object,nil)
}

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
