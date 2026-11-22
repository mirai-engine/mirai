package kai_assets

import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:asset"
import "mirai:cook/cache"
import net "mirai:net"
import "mirai:std/base"
import "mirai:store"
import vcs "mirai:kai"

@(private="file")
Mesh_Machine :: struct {
    machine:vcs.Machine,
    runner:vcs.Runner,
    started:bool,
    stop:bool,
    worker:^thread.Thread,
    target:[1]net.Address,
}

@(private="file")
mesh_run :: proc(t:^thread.Thread) {
    m:=(^Mesh_Machine)(t.data)
    for !sync.atomic_load(&m.stop) {
        vcs.runner_update(&m.runner,0.01)
        free_all(context.temp_allocator)
    }
}

@(private="file")
mesh_start :: proc(m:^Mesh_Machine) {
    m.worker=thread.create(mesh_run)
    m.worker.data=m
    m.worker.init_context=context
    thread.start(m.worker)
}

@(private="file")
mesh_stop :: proc(m:^Mesh_Machine) {
    if m.worker!=nil {
        sync.atomic_store(&m.stop,true)
        thread.join(m.worker)
        thread.destroy(m.worker)
        m.worker=nil
    }
    if m.started {vcs.runner_stop(&m.runner)}
    m.started=false
}

@(private="file")
until :: proc(seconds:f64,data:rawptr,done:proc(data:rawptr) -> bool) -> bool {
    start:=time.tick_now()
    for time.duration_seconds(time.tick_since(start))<seconds {
        if done(data) {return true}
        free_all(context.temp_allocator)
        time.sleep(20*time.Millisecond)
    }
    return false
}

@(private="file")
Peer_Goal :: struct {control:^vcs.Control,class:vcs.Agent_Class,node:bool}

@(private="file")
peer_connected :: proc(data:rawptr) -> bool {
    g:=(^Peer_Goal)(data)
    peers:=make([dynamic]vcs.Runner_Peer_Info,context.temp_allocator)
    vcs.control_peers(g.control,&peers)
    for p in peers {
        if p.class==g.class && p.node==g.node {return true}
    }
    return false
}

// Alice and Bob run their machines' agents, each on its own thread over
// 127.0.0.1, as `mirai kai agent` does, with a seed+ddc node beside them. A
// cook of Alice's keeps a result in her cache, which publishes it as her
// signed derived data; a cook of Bob's misses the same result in his cache,
// asks his agent through its control, and loads what Alice built without
// building it. A build Alice publishes lists the objects that come with it:
// the node mirrors all of them, and once Alice is gone Bob and Carol, who
// holds only a ddc grant, take the whole build from the node. A record that
// lists an object nobody has is no result.
@(test)
a_cook_takes_derived_data_a_peer_built :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-mesh-cook")
    if folder=="" {return}
    machines:=new([4]Mesh_Machine)
    defer free(machines)
    alice,bob,node,carol:=&machines[0],&machines[1],&machines[2],&machines[3]
    for &m,k in machines {
        if !testing.expect_value(t,vcs.machine_open(&m.machine,fmt.tprintf("%s/m%d",folder,k)),vcs.Error.None) {return}
    }
    defer for &m in machines {
        mesh_stop(&m)
        vcs.machine_close(&m.machine)
    }
    buffer:[vcs.RECOVERY_TEXT]u8
    names:=[]string{"alice","bob","carol"}
    for x,k in ([]^Mesh_Machine{alice,bob,carol}) {
        _,e:=vcs.machine_user_create(&x.machine,names[k],&buffer)
        testing.expect_value(t,e,vcs.Error.None)
    }
    org,oe:=vcs.machine_org_create(&alice.machine,"studio")
    testing.expect_value(t,oe,vcs.Error.None)
    l:vcs.Log
    vcs.log_init(&l,bob.machine.user,context.temp_allocator)
    vcs.log_open(&bob.machine.store,&l,bob.machine.user,.User)
    vcs.log_save(&alice.machine.store,&l)
    testing.expect_value(t,vcs.machine_member_add(&alice.machine,org,bob.machine.user,.Writer),vcs.Error.None)
    modes:=vcs.Node_Modes{.Relay,.Seed,.DDC}
    if !testing.expect_value(t,vcs.runner_start(&node.runner,{machine=&node.machine,bind=net.address_loopback(0),modes=modes,observe_port=0,beacon_port=-1}),vcs.Error.None) {return}
    node.started=true
    node.target[0]=net.address_loopback(vcs.runner_port(&node.runner))
    testing.expect_value(t,vcs.machine_node_add(&alice.machine,org,node.machine.identity.key,vcs.Dh_Key(node.machine.dh.public),modes,node.target[:]),vcs.Error.None)
    // Bob's store and the node's hold the org as a pairing left them.
    for x in ([]^Mesh_Machine{bob,node}) {
        for id in ([]vcs.Log_Id{org,alice.machine.user}) {
            kind:=id==org?vcs.Log_Kind.Org:.User
            y:vcs.Log
            vcs.log_init(&y,id,context.temp_allocator)
            vcs.log_open(&alice.machine.store,&y,id,kind)
            vcs.log_save(&x.machine.store,&y)
        }
        testing.expect_value(t,vcs.machine_org_join(&x.machine,org),vcs.Error.None)
    }
    vcs.runner_reload(&node.runner)

    for x in ([]^Mesh_Machine{alice,bob}) {
        if !testing.expect_value(t,vcs.runner_start(&x.runner,{machine=&x.machine,bind=net.address_loopback(0),beacon=true,beacon_port=-1,control=true}),vcs.Error.None) {return}
        x.started=true
    }
    // Each one's beacons reach the other's socket.
    alice.target[0]=net.address_loopback(vcs.runner_port(&bob.runner))
    bob.target[0]=net.address_loopback(vcs.runner_port(&alice.runner))
    alice.runner.desc.beacon_targets=alice.target[:]
    bob.runner.desc.beacon_targets=bob.target[:]
    // Carol holds a grant of the ddc right only.
    issued,ie:=vcs.machine_grant_issue(&alice.machine,org,vcs.Dh_Key(carol.machine.dh.public),carol.machine.identity.key,{.DDC},{},"",7,{net.address_loopback(vcs.runner_port(&alice.runner))},context.temp_allocator)
    if !testing.expectf(t,ie==.None,"alice issues: %s",alice.machine.why) {return}
    _,le:=vcs.machine_grant_load(&carol.machine,issued)
    if !testing.expectf(t,le==.None,"carol loads: %s",carol.machine.why) {return}
    if !testing.expect_value(t,vcs.runner_start(&carol.runner,{machine=&carol.machine,bind=net.address_loopback(0),beacon_port=-1,control=true}),vcs.Error.None) {return}
    carol.started=true
    for &m in machines {mesh_start(&m)}

    // The cooks are other machines of the same stores: they reach the agents
    // through the control, as another process would.
    cooks:=new([4]vcs.Machine)
    defer free(cooks)
    meshes:=new([4]Mesh_Cache)
    defer free(meshes)
    for k in 0..<4 {testing.expect_value(t,vcs.machine_open(&cooks[k],machines[k].machine.store.root),vcs.Error.None)}
    for k in ([]int{0,1,3}) {
        testing.expect_value(t,mesh_cache_open(&meshes[k],&cooks[k],org),vcs.Error.None)
        cooks[k].changed=vcs.control_machine_changed(&meshes[k].control)
    }
    defer for k in 0..<4 {
        mesh_cache_close(&meshes[k])
        vcs.machine_close(&cooks[k])
    }
    g:=Peer_Goal{control=&meshes[1].control,class=.Member}
    if !testing.expect(t,until(10,&g,peer_connected),"bob's agent connects to alice's") {return}
    g.class,g.node=.Node,true
    if !testing.expect(t,until(10,&g,peer_connected),"bob's agent connects to the node") {return}
    g.control=&meshes[3].control
    if !testing.expect(t,until(15,&g,peer_connected),"carol's agent reaches the node through alice's") {return}

    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    KEY,VERSION :: 0x5eed,3
    pixels:=make([]u8,4*4*4,context.temp_allocator)
    for &p,i in pixels {p=u8(i)}
    mips:=[1][]u8{pixels}
    doc:asset.Document
    testing.expect_value(t,asset.texture_document(&doc,&types,{id=cache.id(KEY,VERSION),width=4,height=4,format=.RGBA8,mips=mips[:]},context.temp_allocator),asset.Error.None)
    bytes,_:=asset.document_bytes(&doc,context.temp_allocator)
    asset.document_destroy(&doc)

    built:=cache.Cache{store=&cooks[0].store,source=mesh_source(&meshes[0])}
    testing.expect(t,cache.put(built,"textures",KEY,VERSION,bytes),"alice's cook keeps and publishes its result")
    taken:=cache.Cache{store=&cooks[1].store,source=mesh_source(&meshes[1])}
    file:asset.Asset
    if !testing.expect(t,cache.load(taken,"textures",KEY,VERSION,&file),"bob's cook takes what alice built") {return}
    defer asset.asset_close(&file)
    testing.expect(t,file.blob.header.id==cache.id(KEY,VERSION))
    other:=cache.Cache{store=&cooks[1].store,source=mesh_source(&meshes[1])}
    testing.expect(t,!cache.has(other,"textures",KEY+1,VERSION),"what no peer built is a miss")

    // A build of Alice's: the object of its ref lists the texture with it.
    texture,te:=asset.object_put(&cooks[0].store,bytes)
    testing.expect_value(t,te,asset.Error.None)
    b:=asset.Build{package_id=cache.id(KEY,1),key=store.Hash{0=9},final=true}
    b.outputs=make([dynamic]asset.Build_Output,context.temp_allocator)
    append(&b.outputs,asset.Build_Output{id=cache.id(KEY,VERSION),kind=asset.KIND_TEXTURE,object=texture})
    build,be:=asset.build_put(&cooks[0].store,&b)
    testing.expect_value(t,be,asset.Error.None)
    digits:[64]u8
    name:=store.hex(b.key,&digits)
    testing.expect_value(t,store.ref_set(&cooks[0].store,asset.REF_IMPORTS,name,build),store.Error.None)
    source:=mesh_source(&meshes[0])
    source.kept(source.user,asset.REF_IMPORTS,name,build)
    // And a record that lists an object nobody has.
    broken:=ddc_key(asset.REF_IMPORTS,"broken")
    _,pe:=vcs.machine_publish_ddc(&cooks[0],org,broken,{build,store.Hash{0=0xee,31=1}},nil)
    testing.expect_value(t,pe,vcs.Error.None)

    // The node mirrors every object of the build, then Alice goes.
    Mirror :: struct {s:^store.Store,org:vcs.Log_Id,key:store.Hash}
    mirror:=Mirror{s=&cooks[2].store,org=org,key=ddc_key(asset.REF_IMPORTS,name)}
    mirrored :: proc(data:rawptr) -> bool {
        m:=(^Mirror)(data)
        records:=make([dynamic]vcs.DDC_Record,context.temp_allocator)
        if vcs.ddc_lookup(m.s,m.org,m.key,&records)!=.None || len(records)==0 {return false}
        lacking:=make([dynamic]store.Hash,context.temp_allocator)
        objects,e:=vcs.ddc_output_lacking(m.s,records[0].output_root,&lacking)
        return e==.None && len(lacking)==0 && len(objects)==2
    }
    if !testing.expect(t,until(15,&mirror,mirrored),"the node mirrors the build and what it lists") {return}
    mesh_stop(alice)

    for k in ([]int{1,3}) {
        fetched:=cache.source_fetch(mesh_source(&meshes[k]),&cooks[k].store,asset.REF_IMPORTS,name)
        if !testing.expectf(t,fetched,"machine %d takes the build from the node",k) {continue}
        object,re:=store.ref_get(&cooks[k].store,asset.REF_IMPORTS,name)
        got,ge:=asset.build_get(&cooks[k].store,object,context.temp_allocator)
        testing.expectf(t,re==.None && object==build && ge==.None && asset.build_whole(&cooks[k].store,&got,true),"machine %d holds the whole build",k)
    }
    testing.expect(t,!cache.source_fetch(mesh_source(&meshes[1]),&cooks[1].store,asset.REF_IMPORTS,"broken") ,"a record whose objects are not all here is no result")
}
