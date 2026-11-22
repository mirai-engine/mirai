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

// Alice and Bob run their machines' agents, each on its own thread over
// 127.0.0.1, as `mirai kai agent` does. A cook of Alice's keeps a result in
// her cache, which publishes it as her signed derived data; a cook of Bob's
// misses the same result in his cache, asks his agent through its control,
// and loads what Alice built without building it.
@(test)
a_cook_takes_derived_data_a_peer_built :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-mesh-cook")
    if folder=="" {return}
    machines:=new([2]Mesh_Machine)
    defer free(machines)
    alice,bob:=&machines[0],&machines[1]
    for &m,k in machines {
        if !testing.expect_value(t,vcs.machine_open(&m.machine,fmt.tprintf("%s/m%d",folder,k)),vcs.Error.None) {return}
    }
    defer for &m in machines {
        if m.worker!=nil {
            sync.atomic_store(&m.stop,true)
            thread.join(m.worker)
            thread.destroy(m.worker)
        }
        if m.started {vcs.runner_stop(&m.runner)}
        vcs.machine_close(&m.machine)
    }
    buffer:[vcs.RECOVERY_TEXT]u8
    _,e:=vcs.machine_user_create(&alice.machine,"alice",&buffer)
    testing.expect_value(t,e,vcs.Error.None)
    _,e=vcs.machine_user_create(&bob.machine,"bob",&buffer)
    testing.expect_value(t,e,vcs.Error.None)
    org,oe:=vcs.machine_org_create(&alice.machine,"studio")
    testing.expect_value(t,oe,vcs.Error.None)
    l:vcs.Log
    vcs.log_init(&l,bob.machine.user,context.temp_allocator)
    vcs.log_open(&bob.machine.store,&l,bob.machine.user,.User)
    vcs.log_save(&alice.machine.store,&l)
    testing.expect_value(t,vcs.machine_member_add(&alice.machine,org,bob.machine.user,.Writer),vcs.Error.None)
    testing.expect_value(t,vcs.machine_org_join(&bob.machine,org),vcs.Error.None)
    // Bob's store holds the org as a pairing left it.
    for id in ([]vcs.Log_Id{org,alice.machine.user}) {
        kind:=id==org?vcs.Log_Kind.Org:.User
        x:vcs.Log
        vcs.log_init(&x,id,context.temp_allocator)
        vcs.log_open(&alice.machine.store,&x,id,kind)
        vcs.log_save(&bob.machine.store,&x)
    }

    for &m in machines {
        if !testing.expect_value(t,vcs.runner_start(&m.runner,{machine=&m.machine,bind=net.address_loopback(0),beacon=true,beacon_port=-1,control=true}),vcs.Error.None) {return}
        m.started=true
    }
    // Each one's beacons reach the other's socket.
    alice.target[0]=net.address_loopback(vcs.runner_port(&bob.runner))
    bob.target[0]=net.address_loopback(vcs.runner_port(&alice.runner))
    for &m in machines {
        m.runner.desc.beacon_targets=m.target[:]
        m.worker=thread.create(mesh_run)
        m.worker.data=&m
        m.worker.init_context=context
        thread.start(m.worker)
    }

    // The cooks are other machines of the same stores: they reach the agents
    // through the control, as another process would.
    cooks:=new([2]vcs.Machine)
    defer free(cooks)
    meshes:=new([2]Mesh_Cache)
    defer free(meshes)
    for k in 0..<2 {
        testing.expect_value(t,vcs.machine_open(&cooks[k],machines[k].machine.store.root),vcs.Error.None)
        testing.expect_value(t,mesh_cache_open(&meshes[k],&cooks[k],org),vcs.Error.None)
        cooks[k].changed=vcs.control_machine_changed(&meshes[k].control)
    }
    defer for k in 0..<2 {
        mesh_cache_close(&meshes[k])
        vcs.machine_close(&cooks[k])
    }
    connected:=false
    start:=time.tick_now()
    for !connected && time.duration_seconds(time.tick_since(start))<10 {
        peers:=make([dynamic]vcs.Runner_Peer_Info,context.temp_allocator)
        vcs.control_peers(&meshes[1].control,&peers)
        for p in peers {connected||=p.class==.Member}
        time.sleep(20*time.Millisecond)
    }
    if !testing.expect(t,connected,"bob's agent connects to alice's") {return}

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
}
