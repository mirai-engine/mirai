package multiplayer

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:engine/scene"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/base"
import "mirai:std/jobs"

// A copy the server spawned arrives at a client that has not read its
// prefab: the replica is the root, at once, without reading a file in the
// tick, with what the server sent; jobs read the prefab and the replica takes
// what it places, the lid that hangs from it, keeping what the server sent.
@(test)
a_replica_of_a_spawned_copy_is_filled_when_its_prefab_arrives :: proc(t:^testing.T) {
    CRATE :: base.Asset_Id{0xc7,1}
    folder:=base.test_folder(t,"net-prefab")
    if folder=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    crate:asset.Scene;asset.scene_init(&crate,&types,CRATE)
    asset.scene_entity_add(&crate,1,0,"Crate")
    asset.scene_entity_add(&crate,2,1,"Lid")
    asset.scene_set(&crate,1,"Net_Test_Late",&Net_Test_Late{level=3})
    testing.expect_value(t,asset.scene_save(&crate,fmt.tprintf("%s/crate.scene",folder)),asset.Error.None)
    asset.scene_destroy(&crate)

    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    worlds:[2]Net_Test_World
    shares:[2]Net_Test_Shared
    assets:[2]host.Assets
    apps:[2]host.App
    sessions:[2]Net_Session
    for &world,index in worlds {
        net_test_init(&world,&info)
        shares[index].info=&info
        if !testing.expect(t,host.assets_init(&assets[index],{root=folder,capacity=16})) {return}
        apps[index]={info=&info,assets=&assets[index],allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
    }
    if !testing.expect(t,jobs.system_init(&apps[1].jobs,{threads=2})) {return}
    defer {
        for &world in worlds {core.world_destroy(&info,.World,&world)}
        for &app in apps {
            host.app_assets_releases_stop(&app)
            if jobs.worker_count(&app.jobs)>0 {jobs.system_destroy(&app.jobs)}
        }
        for &a in assets {host.assets_destroy(&a)}
    }
    warms:[2]scene.Prefab_Warms
    defer for &w in warms {scene.prefab_warms_free(&w)}
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=13,endpoints=2,packets=1024})) {return}
    defer wire.sim_network_destroy(&network)
    for &session,index in sessions {
        if !testing.expect(t,net_test_session(&session,&worlds[index],&info,&apps[index],&network,index,index==0?.Server:.Client)) {return}
    }
    defer for &session in sessions {session_destroy(&session)}
    problems:[2]core.Problems
    sessions[0].problems,sessions[1].problems=&problems[0],&problems[1]
    testing.expect_value(t,wire.host_connect(&sessions[1].host,wire.address_memory(0)),wire.Error.None)
    outbox:Net_Outbox;defer core.value_free(&outbox,type_info_of(Net_Outbox))
    server,client:=&worlds[0],&worlds[1]
    server_ref,client_ref:=core.world_ref(server,&info),core.world_ref(client,&info)

    copy:=core.NONE
    replica:=core.NONE
    reads:=0
    for tick in 1..<240 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],server_ref,nil,wire.host_poll(&sessions[0].host),&server.remote)
        before:=assets[1].stats.loads
        client_commands(&sessions[1],client_ref,&assets[1],apps[1].allocator,wire.host_poll(&sessions[1].host))
        if replica==core.NONE {
            for r in sessions[1].client.replicas[:sessions[1].client.replica_high] {if r.object!=0 {replica=r.entity}}
            if replica!=core.NONE {
                reads=assets[1].stats.loads-before
                core.settle(&info,client,nil)
                testing.expect(t,core.raw_row(core.raw(&client.pendings),replica)>=0 && !host.assets_loaded(&assets[1],CRATE),"the replica comes at once and waits for its prefab")
            }
        }
        core.settle(&info,client,nil)
        apps[1].stats.frames+=1
        scene.spawns_fill(client_ref,&apps[1],&warms[1],&problems[1])
        core.settle(&info,client,nil)
        if tick==10 {
            spawner:=scene.Spawner{core.commands_of(server_ref),&assets[0],&problems[0]}
            copy=scene.spawn(spawner,CRATE,{position={1,0,0}})
            core.settle(&info,server,nil)
            scene.spawns_fill(server_ref,&apps[0],&warms[0],&problems[0],all=true)
            core.settle(&info,server,nil)
            core.add(&server.objects,copy,net_test_replicate(audience=.Always))
        }
        core.settle(&info,server,nil)
        server_publish(&sessions[0],server_ref,&outbox,u32(tick))
        if replica!=core.NONE && core.raw_row(core.raw(&client.pendings),replica)<0 {break}
    }
    if !testing.expect(t,copy!=core.NONE && replica!=core.NONE,"the copy reached the client") {return}
    testing.expect_value(t,reads,0)
    testing.expect(t,core.raw_row(core.raw(&client.pendings),replica)<0,"the replica is filled")
    late,has_late:=core.get(&client.lates,replica)
    testing.expect(t,has_late && late.level==3 && core.has(&client.links,replica),"with what its prefab places, and what the network gave it")
    lid:=core.first_child(core.ref(&client.hierarchy),replica)
    name,_:=core.get(&client.names,lid)
    testing.expect(t,lid!=core.NONE && base.text_get(name.text[:])=="Lid","the lid hangs from it")
    testing.expect_value(t,problems[1].count,0)
}
