package multiplayer

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import inp "mirai:engine/input"
import "mirai:host"
import wire "mirai:net"
import phys "plugins:physics/runtime"

// The test world of this package with mounts and what they derive.
@(private)
@(test_world)
Mount_Net_World :: struct {
    using world:Test_World,
    using net:Net_Test_Tables,
    mounts:core.Table(inp.Mount),
    seat_requests:inp.Seat_Requests,
    contexts:inp.Input_Contexts,
    mount_events:inp.Mount_Events,
    jumps:core.Jumps,
    slot_views:inp.Slot_Views,
    run:inp.Run_Players,
}

@(private="file") MOUNT_SPEED :: f32(3) // m/s a whole push moves what a seat drives

// A tick of an end: the network, the seats, who rides what, and what a seat
// drives going along +X by its push, where this end decides it.
@(private="file")
mount_net_fixed :: proc(world,shared,editor,application:rawptr) {
    w:=cast(^Mount_Net_World)world
    sh:=cast(^Net_Test_Shared)shared
    app:=cast(^host.App)application
    ref:=core.world_ref(w,sh.info)
    core.revisions_moved(w.storage_revisions[:])
    net_tick_head(ref,app,sh.session,&w.remote,nil,nil,sh.session.problems)
    core.settle(sh.info,w,nil)
    net_seats({entities=&w.entities},&w.seats,&w.nets,&w.seat_runtime,&w.absents,&w.disabled,&w.objects,&w.transforms,nil,core.read(&w.links),core.read(&w.remotes),
        core.ref(&w.bindings),core.ref(&w.remote),core.ref(&w.network),{},w.time)
    core.settle(sh.info,w,nil)
    inp.input_seat_index(core.ref(&w.entities),core.read(&w.seats),&w.seat_state,nil)
    net_input_take(sh.session,core.read(&w.seats),&w.seat_runtime,w.time)
    inp.input_seats({entities=&w.entities},app,&w.seats,&w.seat_state,&w.run,&w.seat_runtime,w.input,core.ref(&w.slot_views),core.ref(&w.bindings),core.ref(&w.network),nil,w.time)
    net_input_delay(sh.session,core.read(&w.seats),&w.seat_runtime,core.ref(&w.bindings),w.time,sh.session.problems)
    core.settle(sh.info,w,nil)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
    exits:=inp.Mount_Exits{core.read(&w.transforms),core.read(&w.parents),{},{}}
    inp.input_drive(core.ref(&w.entities),&w.move_inputs,&w.seats,&w.seat_state,&w.seat_runtime,&w.seat_requests,core.ref(&w.network),core.read(&w.remotes),
        &w.mounts,core.read(&w.carried),exits,sh.session.problems)
    core.settle(sh.info,w,nil)
    inp.input_mounts(core.ref(&w.entities),core.read(&w.mounts),&w.carried,&w.parents,&w.transforms,&w.body_places,&w.jumps,{},{},&w.seat_state,&w.contexts,&w.mount_events,sh.session.problems)
    clear(&w.jumps.queue.items)
    core.settle(sh.info,w,nil)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
    for row in 0..<core.count(&w.move_inputs) {
        e:=core.entity_at(&w.move_inputs,row)
        if !core.owned(core.read(&w.remotes),e) {continue}
        seat:=inp.driver_of(core.ref(&w.seat_state),e)
        push:=seat!=core.NONE?inp.seat_action(core.ref(&w.seat_runtime),seat,NET_TEST_PUSH).value:0
        if move:=core.at(&w.move_inputs,row).move;move.x!=push {core.edit_at(&w.move_inputs,row).move={push,0,0}}
    }
    core.settle(sh.info,w,nil)
    for row in 0..<core.count(&w.move_inputs) {
        e:=core.entity_at(&w.move_inputs,row)
        if !core.owned(core.read(&w.remotes),e) || core.has(&w.carried,e) {continue}
        if step:=core.at(&w.move_inputs,row).move*MOUNT_SPEED*w.time.dt;step!={} {core.edit(&w.transforms,e).position+=step}
    }
    core.settle(sh.info,w,nil)
    outbox:Net_Outbox
    net_tick_tail(ref,sh.session,&outbox,&w.made,sh.session.problems)
    core.value_free(&outbox,type_info_of(Net_Outbox))
}

// A player at a client walks its diver, enters the hatch of a boat, drives the
// boat for a second and gets off, with the sync test of the client on and the
// client going back over the tick it entered: both ends agree on who rides
// and drives what and where the diver and the boat are, and the sync test
// finds nothing that differs.
@(test)
a_client_enters_drives_and_leaves_a_boat_alike_on_both_ends :: proc(t:^testing.T) {
    info,described:=test_info(t,Mount_Net_World)
    if !described {return}
    defer test_info_destroy(&info)
    info.loops[.Game][.Fixed]=mount_net_fixed
    worlds:=new([2]Mount_Net_World)
    defer free(worlds)
    shares:[2]Net_Test_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    divers,hulls,hatches:[2]core.Entity
    for &world,index in worlds {
        net_test_init(&world,&info)
        world.network.role=index==0?.Server:.Client
        // The scene of both ends: a diver at the origin, a boat 4 m along +X with a hatch on its deck.
        divers[index],hulls[index],hatches[index]=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
        core.add(&world.identities,divers[index],core.Id{1})
        core.add(&world.transforms,divers[index],core.TRANSFORM_IDENTITY)
        core.add(&world.move_inputs,divers[index],inp.Move_Input{})
        core.add(&world.identities,hulls[index],core.Id{2})
        core.add(&world.transforms,hulls[index],core.Transform{{4,0,0},1,{1,1,1}})
        core.add(&world.move_inputs,hulls[index],inp.Move_Input{frame=.Body})
        core.add(&world.identities,hatches[index],core.Id{3})
        core.add(&world.transforms,hatches[index],core.Transform{{0,1,0},1,{1,1,1}})
        core.add(&world.parents,hatches[index],core.Parent{entity=hulls[index]})
        core.add(&world.mounts,hatches[index],inp.Mount{drives=hulls[index],exits={0={0,-1,2}},exit_count=1})
        core.settle(&info,&world,nil)
        core.hierarchy_settle(&world.hierarchy,core.read(&world.parents),&world.entities)
        shares[index].info=&info
        apps[index]={info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
    }
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
    defer for &app in apps {host.app_world_scratch_free(&app);delete(app.worlds)}
    defer for &share in shares {phys.collider_meshes_destroy(&share.colliders)}
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=91,endpoints=2,packets=1024})) {return}
    defer wire.sim_network_destroy(&network)
    for &session,index in sessions {
        settings:=Net_Settings{max_objects=8,predicted_capacity=8,replication={history_seconds=0.25},resimulate_budget=600,sync_test=index==1?4:0}
        if !testing.expect(t,net_test_session(&session,&worlds[index],&info,&apps[index],&network,index,index==0?.Server:.Client,settings=settings)) {return}
        shares[index].session=&session
    }
    defer for &session in sessions {session_destroy(&session)}
    problems:[2]core.Problems
    sessions[0].problems,sessions[1].problems=&problems[0],&problems[1]
    testing.expect_value(t,wire.host_connect(&sessions[1].host,wire.address_memory(0)),wire.Error.None)
    for index in 0..<2 {wire.sim_endpoint_conditions(&network,index,{latency=0.03})}
    server,client:=&worlds[0],&worlds[1]
    connected:Connection
    server_seat:core.Entity
    driving,entered,left,rolled:=0,-1,-1,false
    rode_on_client:=false
    for tick in 1..<540 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],core.world_ref(server,&info),nil,wire.host_poll(&sessions[0].host),&server.remote)
        for event in net_test_arrived(&sessions[0]) {
            if event.kind!=.Connected {continue}
            // The server seats the player of the connection in the diver, which every client sees.
            connected=event.connection
            server_seat=core.create(&server.entities)
            core.add(&server.seats,server_seat,inp.Seat{remote=true,body=divers[0]})
            core.add(&server.nets,server_seat,Net_Seat{connection=connected})
            core.add(&server.transforms,server_seat,core.TRANSFORM_IDENTITY)
            for e in ([4]core.Entity{server_seat,divers[0],hulls[0],hatches[0]}) {core.add(&server.objects,e,net_test_replicate(audience=.Always))}
            core.settle(&info,server,nil)
        }
        client_sync_test(&sessions[1],core.world_ref(client,&info),&apps[1])
        client_commands(&sessions[1],core.world_ref(client,&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host))
        client_reconcile(&sessions[1],core.world_ref(client,&info),&apps[1],1.0/60)
        own:=inp.local_seat(core.read(&client.seats),0)
        body:=inp.body_of(core.read(&client.seats),own)
        client.input.keys_down={}
        if own!=core.NONE && (body==divers[1] || body==hulls[1]) {driving+=1}
        // The game of the server: the player enters a while after it plays, and gets off after a second at the helm.
        if driving==40 && entered<0 {
            inp.mount(&server.seat_requests,server_seat,hatches[0])
            entered=tick
        }
        if entered>0 && tick==entered+120 {
            inp.dismount(&server.seat_requests,server_seat)
            left=tick
        }
        // At the helm the player pushes the boat along +X for a second, and lets go before it gets off.
        if body==hulls[1] && tick<entered+90 {client.input.keys_down={.Right}}
        if carried,ok:=core.get(&client.carried,divers[1]);ok && carried.by==hatches[1] {
            rode_on_client=true
            // The client goes back over the ticks since it learned it rides, once.
            if !rolled {
                rolled=true
                testing.expect(t,client_rollback(&sessions[1],core.world_ref(client,&info),&apps[1],u32(client.time.tick)-6),"the client goes back over the mount")
            }
        }
        for &world,index in worlds {
            core.settle(&info,&world,nil)
            world.time.tick=u64(tick+(index==1?8:0))
            mount_net_fixed(&world,&shares[index],nil,&apps[index])
        }
        for &session in sessions {wire.host_update(&session.host,now)}
    }
    testing.expect(t,connected!=0 && sessions[1].status==.Connected)
    testing.expect(t,entered>0 && left>0,"the player entered and left")
    testing.expect(t,rode_on_client && rolled,"the client saw its diver ride, and went back over it")
    for &world,index in worlds {
        seat:=index==0?server_seat:inp.local_seat(core.read(&world.seats),0)
        testing.expectf(t,inp.body_of(core.read(&world.seats),seat)==divers[index],"end %d: the seat drives the diver again",index)
        value,_:=core.get(&world.mounts,hatches[index])
        testing.expectf(t,value.rider==core.NONE && !core.has(&world.carried,divers[index]) && !core.has(&world.parents,divers[index]),"end %d: nobody rides the hatch",index)
    }
    server_hull,_:=core.get(&server.transforms,hulls[0])
    client_hull,_:=core.get(&client.transforms,hulls[1])
    server_diver,_:=core.get(&server.transforms,divers[0])
    client_diver,_:=core.get(&client.transforms,divers[1])
    testing.expectf(t,server_hull.position.x>4+0.8*MOUNT_SPEED,"the boat went along +X: %v",server_hull.position)
    testing.expectf(t,linalg.length(server_hull.position-client_hull.position)<0.01,"the boat: server %v client %v",server_hull.position,client_hull.position)
    testing.expectf(t,linalg.length(server_diver.position-(server_hull.position+{0,0,2}))<0.01,"the diver got off at the exit of the hatch: %v by the boat at %v",server_diver.position,server_hull.position)
    testing.expectf(t,linalg.length(server_diver.position-client_diver.position)<0.01,"the diver: server %v client %v",server_diver.position,client_diver.position)
    testing.expect(t,sessions[1].stats.sync_tested>0,"the sync test ran")
    testing.expect(t,core.problem_find(&problems[1],core.NONE,"net.sync_test")==nil)
    for &found in problems {
        for &p in core.problems_list(&found) {testing.expectf(t,false,"%s: %s",core.problem_code(&p),core.problem_text(&p))}
    }
}
