package kai_assets

import "base:runtime"
import "core:sync"
import "core:time"
import "mirai:asset"
import "mirai:cook/cache"
import "mirai:std/blake3"
import "mirai:store"
import vcs "mirai:kai"

// What a project's imports and cooks share with its org's machines. A miss of
// cook/cache or of the library asks the connected members of the project's
// org, through an agent of this process, for a signed DDC_Record a writer
// published (ddc_accept keeps only writers' records), and takes its output
// whole; what an import or a cook keeps is published as this device's record,
// listing the object of the ref and, for a build, every object the build
// lists, and told to the org's nodes, which keep it. The key of a result is
// the hash of its cache ref. A build found here that the org has no record of
// (kept before the project was the org's) is published the same way, so the
// builds a project came with reach the machines that pull it.

LABEL_DDC_CACHE :: "kai-1/ddc-cache"
PEERS_WAIT :: 2*time.Second // a cook waits this long for the org's machines to connect

Mesh_Cache :: struct {
    team:^vcs.Team,   // signs what is published
    agent:^vcs.Agent, // asks the org's connected machines
    org:vcs.Org_Id,
    lock:sync.Mutex,
    taken,published:int, // results taken from peers and published since it opened
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

// The source a cache.Cache of the org's store takes.
mesh_source :: proc(c:^Mesh_Cache) -> cache.Source {
    return {fetch=mesh_fetch,kept=mesh_kept,here=mesh_here,user=c}
}

// What the imports and cooks of the project at root take from and give to
// its org's machines (cache.Peers_Open): when root is a workspace of an org's
// repository on the machine of the store at store_root, an agent of this
// process that dials the org's members. Otherwise no source, and close is
// nil: the imports and cooks work alone, as without Kai.
peers_open :: proc(store_root,root:string) -> (source:cache.Source,close:cache.Peers_Close) {
    allocator:=context.allocator
    if store_root=="" || root=="" {return}
    repo,workspace:=vcs.workspace_repo_of(root)
    if !workspace {return}
    p,pe:=new(Peers,allocator)
    if pe!=nil {return}
    p.allocator=allocator
    se:store.Error
    if p.s,se=store.open(store_root,allocator);se!=.None {
        free(p,allocator)
        return
    }
    if vcs.team_open(&p.team,&p.s,allocator)!=.None {
        store.close(&p.s)
        free(p,allocator)
        return
    }
    l,linked:=vcs.team_link_of(&p.team,repo)
    if !linked || vcs.agent_start(&p.agent,&p.team,{port=-1},allocator)!=.None {
        vcs.team_close(&p.team)
        store.close(&p.s)
        free(p,allocator)
        return
    }
    p.cache={team=&p.team,agent=&p.agent,org=l.org}
    started:=time.tick_now()
    for time.tick_since(started)<PEERS_WAIT {
        peers:=make([dynamic]vcs.Peer_Info,context.temp_allocator)
        vcs.agent_peers(&p.agent,&peers,context.temp_allocator)
        if len(peers)>0 {break}
        time.sleep(20*time.Millisecond)
    }
    return mesh_source(&p.cache),peers_close
}

@(private="file")
Peers :: struct {
    cache:Mesh_Cache,
    s:store.Store,
    team:vcs.Team,
    agent:vcs.Agent,
    allocator:runtime.Allocator,
}

@(private="file")
peers_close :: proc(source:cache.Source) -> (taken,published:int) {
    p:=(^Peers)(source.user)
    taken,published=p.cache.taken,p.cache.published
    vcs.agent_stop(&p.agent)
    vcs.team_close(&p.team)
    store.close(&p.s)
    free(p,p.allocator)
    return
}

@(private)
mesh_fetch :: proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool) {
    c:=(^Mesh_Cache)(user)
    s,se:=vcs.team_store(c.team,c.org)
    if se!=.None {return}
    records:=make([dynamic]vcs.DDC_Record,context.temp_allocator)
    scratch:[]u8
    for name,k in names {
        key:=ddc_key(namespace,name)
        if vcs.ddc_lookup(s,c.org,key,&records)!=.None || len(records)==0 {
            if !vcs.agent_ddc_ask(c.agent,c.org,key) {continue}
            if vcs.ddc_lookup(s,c.org,key,&records)!=.None || len(records)==0 {continue}
        }
        objects,e:=vcs.ddc_output_get(s,records[0].output_root,context.temp_allocator)
        if e!=.None || len(objects)==0 {continue}
        if into.root!=s.root {
            whole:=true
            if scratch==nil {scratch=make([]u8,cache.COPY_SCRATCH,context.temp_allocator)}
            for o in objects {whole&&=cache.object_copy(s,into,o,scratch)==.None}
            if !whole {continue}
        }
        given[k]=store.ref_set(into,namespace,names[k],objects[0])==.None
        if given[k] {
            sync.mutex_lock(&c.lock)
            c.taken+=1
            sync.mutex_unlock(&c.lock)
        }
    }
}

// Publishes what the cache kept: the object of the ref and, for a build
// (asset.REF_IMPORTS, asset.REF_IMPORTS_FAST or asset.REF_BUILDS), every
// object the build lists, which must come with it.
@(private)
mesh_kept :: proc(user:rawptr,namespace,name:string,object:store.Hash,from:[]string) {
    c:=(^Mesh_Cache)(user)
    s,se:=vcs.team_store(c.team,c.org)
    if se!=.None {return}
    objects:=make([dynamic]store.Hash,context.temp_allocator)
    append(&objects,object)
    if namespace==asset.REF_IMPORTS || namespace==asset.REF_IMPORTS_FAST || namespace==asset.REF_BUILDS {
        b,e:=asset.build_get(s,object,context.temp_allocator)
        if e!=.None {return}
        listed:=asset.Build_Objects{build=&b,with_thumbnails=true}
        for address in asset.build_object_next(&listed) {append(&objects,address)}
    }
    key:=ddc_key(namespace,name)
    if _,e:=vcs.ddc_publish(s,c.org,&c.team.identity,key,objects[:],time.now()._nsec);e!=.None {return}
    if store.commit(s)!=.None {return}
    ns:[len(vcs.DDC_PREFIX)+32]u8
    hex:[64]u8
    if address,e:=store.ref_get(s,vcs.ddc_namespace(c.org,&ns),store.hex(key,&hex));e==.None {vcs.agent_ddc_published(c.agent,c.org,key,address)}
    sync.mutex_lock(&c.lock)
    c.published+=1
    sync.mutex_unlock(&c.lock)
}

// Publishes a result found here unless a record of its key names an output
// this store holds whole, which it then serves.
@(private)
mesh_here :: proc(user:rawptr,namespace,name:string,object:store.Hash,from:[]string) {
    c:=(^Mesh_Cache)(user)
    s,se:=vcs.team_store(c.team,c.org)
    if se!=.None {return}
    records:=make([dynamic]vcs.DDC_Record,context.temp_allocator)
    vcs.ddc_lookup(s,c.org,ddc_key(namespace,name),&records)
    lacking:=make([dynamic]store.Hash,context.temp_allocator)
    for d in records {
        clear(&lacking)
        if _,e:=vcs.ddc_output_lacking(s,d.output_root,&lacking);e==.None && len(lacking)==0 {return}
    }
    mesh_kept(user,namespace,name,object,from)
}

// The identity of this machine: the seed kept in the root of the store, made
// the first time (vcs.machine_identity).
identity_load :: proc(s:^store.Store) -> (identity:vcs.Identity,error:vcs.Error) {
    return vcs.machine_identity(s)
}
