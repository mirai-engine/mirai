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
// What published, the agent of peers_open waits for the org's nodes to take
// it: until they ask nothing for DRAIN_IDLE, at most DRAIN_MAX.
DRAIN_IDLE :: 2*time.Second
DRAIN_MAX :: 2*time.Minute

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
    if published>0 {vcs.agent_drain(&p.agent,DRAIN_IDLE,DRAIN_MAX)}
    vcs.agent_stop(&p.agent)
    vcs.team_close(&p.team)
    store.close(&p.s)
    free(p,p.allocator)
    return
}

// Gives each ref of names from a record of the org, taking its output whole.
// A record whose output into holds whole under the ref already is passed
// over: the caller asks for what it lacks, so that result is not one it
// takes (a build another ingest made under the same key). With no record
// here that gives it, the connected machines are asked once.
@(private)
mesh_fetch :: proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool) {
    c:=(^Mesh_Cache)(user)
    s,se:=vcs.team_store(c.team,c.org)
    if se!=.None {return}
    records:=make([dynamic]vcs.DDC_Record,context.temp_allocator)
    scratch:[]u8
    for name,k in names {
        key:=ddc_key(namespace,name)
        held,_:=store.ref_get(into,namespace,name)
        for asked:=false;;asked=true {
            if vcs.ddc_lookup(s,c.org,key,&records)!=.None {clear(&records)}
            for &record in records {
                objects,e:=vcs.ddc_output_get(s,record.output_root,context.temp_allocator)
                if e!=.None || len(objects)==0 {continue}
                if held==objects[0] && objects_whole(into,objects) {continue}
                if into.root!=s.root {
                    whole:=true
                    if scratch==nil {scratch=make([]u8,cache.COPY_SCRATCH,context.temp_allocator)}
                    for o in objects {whole&&=cache.object_copy(s,into,o,scratch)==.None}
                    if !whole {continue}
                }
                if given[k]=store.ref_set(into,namespace,name,objects[0])==.None;given[k] {break}
            }
            if given[k] || asked || !vcs.agent_ddc_ask(c.agent,c.org,key) {break}
        }
        if given[k] {
            sync.mutex_lock(&c.lock)
            c.taken+=1
            sync.mutex_unlock(&c.lock)
        }
    }
}

@(private="file")
objects_whole :: proc(s:^store.Store,objects:[]store.Hash) -> bool {
    for o in objects {
        if !asset.object_whole(s,o) {return false}
    }
    return true
}

// Publishes what the cache kept and tells the org's connected nodes.
@(private)
mesh_kept :: proc(user:rawptr,namespace,name:string,object:store.Hash,from:[]string) {
    mesh_share(user,namespace,name,object,false)
}

// Publishes a result found here unless a record of its key names an output
// this store holds whole, which it then serves.
@(private)
mesh_here :: proc(user:rawptr,namespace,name:string,object:store.Hash,from:[]string) {
    mesh_share(user,namespace,name,object,true)
}

@(private="file")
mesh_share :: proc(user:rawptr,namespace,name:string,object:store.Hash,here:bool) {
    c:=(^Mesh_Cache)(user)
    s,se:=vcs.team_store(c.team,c.org)
    if se!=.None {return}
    key,address,published:=ddc_share(c.team,c.org,s,namespace,name,object,here)
    if !published {return}
    vcs.agent_ddc_published(c.agent,c.org,key,address)
    sync.mutex_lock(&c.lock)
    c.published+=1
    sync.mutex_unlock(&c.lock)
}

// Publishes the result of the cache ref (namespace, name) as this device's
// record in org's derived data: object and, for a build (asset.REF_IMPORTS,
// asset.REF_IMPORTS_FAST or asset.REF_BUILDS), every object the build lists,
// which must come with it. Nothing when a record of the key names that same
// output, or with here, any output this store holds whole. published: the
// key and the address of its set then.
ddc_share :: proc(t:^vcs.Team,org:vcs.Org_Id,s:^store.Store,namespace,name:string,object:store.Hash,here:bool) -> (key,address:store.Hash,published:bool) {
    objects:=make([dynamic]store.Hash,context.temp_allocator)
    append(&objects,object)
    if namespace==asset.REF_IMPORTS || namespace==asset.REF_IMPORTS_FAST || namespace==asset.REF_BUILDS {
        b,e:=asset.build_get(s,object,context.temp_allocator)
        if e!=.None {return}
        listed:=asset.Build_Objects{build=&b,with_thumbnails=true}
        for address in asset.build_object_next(&listed) {append(&objects,address)}
    }
    key=ddc_key(namespace,name)
    records:=make([dynamic]vcs.DDC_Record,context.temp_allocator)
    vcs.ddc_lookup(s,org,key,&records)
    if len(records)>0 {
        output,oe:=vcs.ddc_output_put(s,objects[:])
        if oe!=.None {return}
        for d in records {
            if d.output_root==output {return}
        }
        if here {
            lacking:=make([dynamic]store.Hash,context.temp_allocator)
            for d in records {
                clear(&lacking)
                if _,e:=vcs.ddc_output_lacking(s,d.output_root,&lacking);e==.None && len(lacking)==0 {return}
            }
        }
    }
    if _,e:=vcs.ddc_publish(s,org,&t.identity,key,objects[:],time.now()._nsec);e!=.None {return}
    if store.commit(s)!=.None {return}
    ns:[len(vcs.DDC_PREFIX)+32]u8
    hex:[64]u8
    e:store.Error
    if address,e=store.ref_get(s,vcs.ddc_namespace(org,&ns),store.hex(key,&hex));e!=.None {return}
    return key,address,true
}

// The identity of this machine: the seed kept in the root of the store, made
// the first time (vcs.machine_identity).
identity_load :: proc(s:^store.Store) -> (identity:vcs.Identity,error:vcs.Error) {
    return vcs.machine_identity(s)
}
