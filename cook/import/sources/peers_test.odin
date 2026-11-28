package sources

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:cook/cache"
import ka "mirai:cook/kai"
import "mirai:std/base"
import "mirai:store"
import vcs "mirai:kai"

@(private="file")
Peer_Machine :: struct {
    s:store.Store,
    team:vcs.Team,
    agent:vcs.Agent,
    mesh:ka.Mesh_Cache,
    running:bool,
}

@(private="file")
peer_open :: proc(t:^testing.T,m:^Peer_Machine,folder,name:string,port:int,node:=false) -> bool {
    e:store.Error
    m.s,e=store.open(strings.concatenate({folder,"/",name},context.temp_allocator))
    if !testing.expect_value(t,e,store.Error.None) {return false}
    if !testing.expect_value(t,vcs.team_open(&m.team,&m.s),vcs.Error.None) {return false}
    vcs.team_profile_set(&m.team,name,"laptop")
    if !testing.expect_value(t,vcs.agent_start(&m.agent,&m.team,{port=port,host="127.0.0.1",node=node}),vcs.Error.None) {return false}
    m.running=true
    return true
}

@(private="file")
peer_close :: proc(m:^Peer_Machine) {
    if m.running {vcs.agent_stop(&m.agent)}
    m.running=false
    vcs.team_close(&m.team)
    store.close(&m.s)
}

@(private="file")
until :: proc(seconds:f64,data:rawptr,done:proc(data:rawptr) -> bool) -> bool {
    start:=time.tick_now()
    for time.duration_seconds(time.tick_since(start))<seconds {
        if done(data) {return true}
        time.sleep(20*time.Millisecond)
    }
    return done(data)
}

// A cook takes what a writer of its org built: Alice's cache keeps a texture
// and publishes it, Bob's miss asks the connected machines and takes it
// whole, and a server of the org keeps it, also what Alice built before the
// server joined, so Bob takes the next one from it while Alice is off. What Alice kept before she shared is published once
// when her cook finds it; what nobody built is a miss.
@(test)
a_cook_takes_derived_data_a_peer_built :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-peers-ddc")
    if folder=="" {return}
    alice,bob,server:Peer_Machine
    if !peer_open(t,&alice,folder,"alice",0) || !peer_open(t,&bob,folder,"bob",-1) || !peer_open(t,&server,folder,"server",0,node=true) {return}
    defer peer_close(&alice)
    defer peer_close(&bob)
    defer peer_close(&server)
    org,_:=vcs.team_org_create(&alice.team,"studio")
    address:=fmt.tprintf("127.0.0.1:%d",vcs.agent_port(&alice.agent))
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    texture :: proc(t:^testing.T,types:^asset.Types,key:u64) -> []u8 {
        pixels:=make([]u8,4*4*4,context.temp_allocator)
        for &p,i in pixels {p=u8(i)+u8(key)}
        mips:=[1][]u8{pixels}
        doc:asset.Document
        testing.expect_value(t,asset.texture_document(&doc,types,{id=cache.id(key,3),width=4,height=4,format=.RGBA8,mips=mips[:]},context.temp_allocator),asset.Error.None)
        bytes,_:=asset.document_bytes(&doc,context.temp_allocator)
        asset.document_destroy(&doc)
        return bytes
    }
    KEY,VERSION :: 0x5eed,3
    // What alice built before the org had a server reaches the server once it joins.
    alice.mesh={team=&alice.team,agent=&alice.agent,org=org}
    early_build:=cache.Cache{store=&alice.s,source=ka.mesh_source(&alice.mesh)}
    testing.expect(t,cache.put(early_build,"textures",KEY+5,VERSION,texture(t,&types,KEY+5)),"alice builds before the server joins")
    for x in ([]struct{m:^Peer_Machine,role:vcs.Role}{{&server,.Node},{&bob,.Writer}}) {
        text,_:=vcs.team_invite(&alice.team,org,x.role,"",{address},context.temp_allocator)
        why:string
        _,e:=vcs.agent_join(&x.m.agent,text,&why)
        if !testing.expectf(t,e==.None,"%s joins: %s",x.m.team.name,why) {return}
    }
    bob.mesh={team=&bob.team,agent=&bob.agent,org=org}
    built:=cache.Cache{store=&alice.s,source=ka.mesh_source(&alice.mesh)}
    testing.expect(t,cache.put(built,"textures",KEY,VERSION,texture(t,&types,KEY)),"alice's cook keeps and publishes its result")
    taken:=cache.Cache{store=&bob.s,source=ka.mesh_source(&bob.mesh)}
    file:asset.Asset
    if !testing.expect(t,cache.load(taken,"textures",KEY,VERSION,&file),"bob's cook takes what alice built") {return}
    testing.expect(t,file.blob.header.id==cache.id(KEY,VERSION))
    asset.asset_close(&file)
    testing.expect(t,!cache.has(taken,"textures",KEY+1,VERSION),"what nobody built is a miss")

    // What Alice kept before she shared is published when her cook finds it, once.
    early,_:=store.put(&alice.s,transmute([]u8)string("kept before the org"))
    store.ref_set(&alice.s,"textures-early","one",early)
    source:=ka.mesh_source(&alice.mesh)
    before:=alice.mesh.published
    source.here(source.user,"textures-early","one",early,nil)
    source.here(source.user,"textures-early","one",early,nil)
    testing.expect_value(t,alice.mesh.published,before+1)

    // A second result reaches the server, which keeps it; Alice goes, and Bob takes it from the server.
    testing.expect(t,cache.put(built,"textures",KEY+2,VERSION,texture(t,&types,KEY+2)),"alice publishes another")
    Kept :: struct {team:^vcs.Team,org:vcs.Org_Id}
    kept:=Kept{&server.team,org}
    on_server:=until(15,&kept,proc(data:rawptr) -> bool {
        x:=(^Kept)(data)
        s,_:=vcs.team_store(x.team,x.org)
        ns:[len(vcs.DDC_PREFIX)+32]u8
        refs,e:=store.ref_list(s,vcs.ddc_namespace(x.org,&ns),context.temp_allocator)
        if e!=.None || len(refs)<4 {return false}
        records:=make([dynamic]vcs.DDC_Record,context.temp_allocator)
        lacking:=make([dynamic]store.Hash,context.temp_allocator)
        for ref in refs {
            key,_:=store.parse_hex(ref.name)
            if vcs.ddc_lookup(s,x.org,key,&records)!=.None || len(records)==0 {return false}
            if _,le:=vcs.ddc_output_lacking(s,records[0].output_root,&lacking);le!=.None || len(lacking)>0 {return false}
        }
        return true
    })
    if !testing.expect(t,on_server,"the server keeps what a writer publishes") {return}
    vcs.agent_stop(&alice.agent)
    alice.running=false
    vcs.agent_changed(&bob.agent)
    Connected :: struct {a:^vcs.Agent}
    c:=Connected{&bob.agent}
    until(15,&c,proc(data:rawptr) -> bool {
        peers:=make([dynamic]vcs.Peer_Info,context.temp_allocator)
        vcs.agent_peers((^Connected)(data).a,&peers,context.temp_allocator)
        for p in peers {if p.device=="laptop" && p.name=="server" {return true}}
        return false
    })
    testing.expect(t,cache.load(taken,"textures",KEY+2,VERSION,&file),"bob takes it from the server while alice is off")
    asset.asset_close(&file)
}

// A refresh of a project of an org takes the build of a package from the
// org's server through peers_open, sharing the caller's store, while the
// Launcher's agent, of the same device key, stays connected to the server:
// neither connection ends the other, the build comes whole and nothing is
// imported. Again with the build's records already in the store, it is
// taken from them.
@(test)
a_refresh_takes_a_build_from_the_server_beside_an_agent_of_its_key :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-peers-refresh")
    if folder=="" {return}
    defer free_all(context.temp_allocator)
    alice,launcher,server:Peer_Machine
    if !peer_open(t,&alice,folder,"alice",0) || !peer_open(t,&launcher,folder,"bob",-1) || !peer_open(t,&server,folder,"server",0,node=true) {return}
    defer peer_close(&alice)
    defer peer_close(&launcher)
    defer peer_close(&server)
    org,_:=vcs.team_org_create(&alice.team,"studio")
    address:=fmt.tprintf("127.0.0.1:%d",vcs.agent_port(&alice.agent))
    for x in ([]struct{m:^Peer_Machine,role:vcs.Role}{{&server,.Node},{&launcher,.Writer}}) {
        text,_:=vcs.team_invite(&alice.team,org,x.role,"",{address},context.temp_allocator)
        why:string
        _,e:=vcs.agent_join(&x.m.agent,text,&why)
        if !testing.expectf(t,e==.None,"%s joins: %s",x.m.team.name,why) {return}
    }

    // Alice ingests the package and publishes its manifest and build; the server keeps them.
    game:=fmt.tprintf("%s/game",folder)
    os.make_directory_all(fmt.tprintf("%s/assets",game))
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/project.mirai",game),transmute([]u8)string("{\"name\": \"Game\"}\n"))==nil)
    brush:=fmt.tprintf("%s/assets/soft.png",game)
    testing.expect(t,os.write_entire_file(brush,png_bytes(8,8,{40,200,40}))==nil)
    options:=Library_Options{store=&alice.s,root=game}
    report,error:=ingest(brush,options,allocator=context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    added:=project_add(game,report.manifest,"",nil,options,context.temp_allocator)
    if !testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v",added) {return}
    digits,key_digits:[64]u8
    manifest_name:=store.hex(report.manifest,&digits)
    key_name:=store.hex(report.key,&key_digits)
    manifest_object,_:=store.ref_get(&alice.s,asset.REF_MANIFESTS,manifest_name)
    for x in ([]struct{namespace,name:string,object:store.Hash}{{asset.REF_MANIFESTS,manifest_name,manifest_object},{asset.REF_IMPORTS,key_name,report.build}}) {
        key,at,published:=ka.ddc_share(&alice.team,org,&alice.s,x.namespace,x.name,x.object,false)
        if !testing.expectf(t,published,"alice publishes %s",x.namespace) {return}
        vcs.agent_ddc_published(&alice.agent,org,key,at)
    }
    Kept :: struct {team:^vcs.Team,org:vcs.Org_Id}
    kept:=Kept{&server.team,org}
    on_server:=until(15,&kept,proc(data:rawptr) -> bool {
        x:=(^Kept)(data)
        s,_:=vcs.team_store(x.team,x.org)
        ns:[len(vcs.DDC_PREFIX)+32]u8
        refs,e:=store.ref_list(s,vcs.ddc_namespace(x.org,&ns),context.temp_allocator)
        if e!=.None || len(refs)<2 {return false}
        records:=make([dynamic]vcs.DDC_Record,context.temp_allocator)
        lacking:=make([dynamic]store.Hash,context.temp_allocator)
        for ref in refs {
            key,_:=store.parse_hex(ref.name)
            if vcs.ddc_lookup(s,x.org,key,&records)!=.None || len(records)==0 {return false}
            if _,le:=vcs.ddc_output_lacking(s,records[0].output_root,&lacking);le!=.None || len(lacking)>0 {return false}
        }
        return true
    })
    if !testing.expect(t,on_server,"the server keeps the manifest and the build") {return}
    vcs.agent_stop(&alice.agent)
    alice.running=false

    // Bob's copy, a workspace of the org's repository, without the source.
    bob:=fmt.tprintf("%s/bob-game",folder)
    folder_copy(game,bob)
    testing.expect(t,os.remove(fmt.tprintf("%s/assets/soft.png",bob))==nil)
    p:ka.Project
    if !testing.expect_value(t,ka.project_create(&p,bob,&launcher.s),vcs.Error.None) {return}
    local:=p.workspace.repo.id
    ka.project_close(&p)
    testing.expect_value(t,vcs.team_link(&launcher.team,{local=local,org=org,repo=vcs.random_id(vcs.Repo_Id)}),vcs.Error.None)
    Count :: struct {server:^vcs.Agent,key:vcs.Key,want:int}
    count :: proc(data:rawptr) -> bool {
        x:=(^Count)(data)
        peers:=make([dynamic]vcs.Peer_Info,context.temp_allocator)
        vcs.agent_peers(x.server,&peers,context.temp_allocator)
        n:=0
        for q in peers {if q.key==x.key {n+=1}}
        return n==x.want
    }
    vcs.agent_sync_now(&launcher.agent)
    one:=Count{&server.agent,launcher.team.identity.key,1}
    if !testing.expect(t,until(15,&one,count),"the Launcher's agent is connected to the server") {return}

    for pass in 0..<2 {
        shared,close:=ka.peers_open(&launcher.s,bob)
        if !testing.expectf(t,close!=nil,"pass %d: the project shares with its org",pass) {return}
        two:=Count{&server.agent,launcher.team.identity.key,2}
        testing.expectf(t,until(5,&two,count),"pass %d: the server keeps both agents of the key",pass)
        refreshed:=project_refresh(bob,{store=&launcher.s,root=bob,source=shared},context.temp_allocator)
        testing.expectf(t,refreshed.fetched==1 && refreshed.ingested==0 && len(refreshed.failures)==0 && len(refreshed.missing)==0,"pass %d: %v",pass,refreshed)
        testing.expectf(t,count(&two),"pass %d: neither agent of the key ended the other",pass)
        close(shared)
        resolved,resolve_error:=asset.root_packages_in(&launcher.s,bob,context.temp_allocator)
        testing.expectf(t,resolve_error==.None && len(resolved.listed)==1 && resolved.listed[0].state==.Built,"pass %d: %v",pass,resolved)
        // The refs go, the build's objects and records stay: a retry takes it from them.
        p,_:=asset.package_get(&launcher.s,report.manifest,context.temp_allocator)
        select_digits:[64]u8
        store.ref_remove(&launcher.s,asset.REF_IMPORTS,key_name)
        store.ref_remove(&launcher.s,asset.REF_BUILDS,store.hex(asset.build_select(report.manifest,&p),&select_digits))
        testing.expect_value(t,store.commit(&launcher.s),store.Error.None)
    }
}
