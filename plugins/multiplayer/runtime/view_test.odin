package multiplayer

import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import cam "mirai:engine/camera"
import inp "mirai:engine/input"
import "mirai:engine/render"
import "mirai:host"
import wire "mirai:net"
import phys "plugins:physics/runtime"
import mm "mirai:std/math"

// The test world of this package with the cameras a seat sees its body through.
@(private)
@(test_world)
View_Net_World :: struct {
    using world:Test_World,
    using net:Net_Test_Tables,
    follows:core.Table(cam.Camera_Follow),
    cameras:core.Table(render.Camera),
    shown:cam.Cameras,
    slot_views:inp.Slot_Views,
    run:inp.Run_Players,
}

@(private="file") VIEW_MOVE :: inp.Action(0)
@(private="file") VIEW_LOOK :: inp.Action(1)
@(private="file") VIEW_SPEED :: f32(3) // m/s a body goes at a whole move

// A tick of an end as the loop runs it: the network, the seats, what they ask
// of their bodies through the cameras they see, and a body that goes where
// its Move_Input asks, where this end decides it.
@(private="file")
view_net_fixed :: proc(world,shared,editor,application:rawptr) {
    w:=cast(^View_Net_World)world
    sh:=cast(^Net_Test_Shared)shared
    app:=cast(^host.App)application
    ref:=core.world_ref(w,sh.info)
    core.revisions_moved(w.storage_revisions[:])
    net_tick_head(ref,app,sh.session,&w.remote,nil,nil,sh.session.problems)
    core.settle(sh.info,w,nil)
    core.pose_targets_place(core.read(&w.replicas),&w.transforms,&w.places,nil)
    net_seats({entities=&w.entities},&w.seats,&w.nets,&w.seat_runtime,&w.absents,&w.disabled,&w.objects,&w.transforms,nil,core.read(&w.links),core.read(&w.remotes),
        core.ref(&w.bindings),core.ref(&w.remote),core.ref(&w.network),{},w.time)
    core.settle(sh.info,w,nil)
    inp.input_seat_index(core.ref(&w.entities),core.read(&w.seats),&w.seat_state,nil)
    net_input_take(sh.session,core.read(&w.seats),&w.seat_runtime,w.time)
    inp.input_seats({entities=&w.entities},app,&w.seats,&w.seat_state,&w.run,&w.seat_runtime,w.input,core.ref(&w.slot_views),core.ref(&w.bindings),core.ref(&w.network),nil,w.time)
    net_input_delay(sh.session,core.read(&w.seats),&w.seat_runtime,core.ref(&w.bindings),w.time,sh.session.problems)
    core.settle(sh.info,w,nil)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
    seats:=core.read(&w.seats)
    cam.camera_drive(&w.move_inputs,
        {state=core.ref(&w.seat_state),runtime=core.ref(&w.seat_runtime),seats=seats,base=VIEW_MOVE},
        {state=core.ref(&w.seat_state),runtime=core.ref(&w.seat_runtime),seats=seats,base=VIEW_LOOK},
        core.ref(&w.bindings),
        {sight={shown=core.ref(&w.shown),seats=seats,seat_state=core.ref(&w.seat_state),cameras=core.read(&w.cameras),hierarchy=core.ref(&w.hierarchy),worlds=core.read(&w.worlds)},
         follows=core.read(&w.follows),parents=core.read(&w.parents),locals=core.read(&w.transforms),verticals=core.read(&w.verticals)},
        core.read(&w.remotes),sh.session.problems)
    core.settle(sh.info,w,nil)
    remote_look(core.ref(sh.session),&w.remote,seats,core.read(&w.nets),&w.move_inputs,w.time)
    for row in 0..<core.count(&w.move_inputs) {
        e:=core.entity_at(&w.move_inputs,row)
        if !core.owned(core.read(&w.remotes),e) {continue}
        if placed:=core.edit(&w.transforms,e);placed!=nil {placed.position+=core.at(&w.move_inputs,row).move*VIEW_SPEED*w.time.dt}
    }
    core.settle(sh.info,w,nil)
    outbox:Net_Outbox
    net_tick_tail(ref,sh.session,&outbox,&w.made,sh.session.problems)
    core.value_free(&outbox,type_info_of(Net_Outbox))
}

// A player at a client turns its Third_Person camera, a free Orbit, a quarter
// turn to the right and holds forward: where the server and a tick the client
// runs again move its body is where the camera of that player looked, the view
// its client sent with its actions, whatever the cameras of each end did. Its
// body goes along +X on both ends and they agree, without a correction: the
// client notes none and ran nothing again, and both ends measure their link.
@(test)
a_free_orbit_turned_by_its_player_moves_the_body_alike_on_both_ends :: proc(t:^testing.T) {
    info,described:=test_info(t,View_Net_World)
    if !described {return}
    defer test_info_destroy(&info)
    info.loops[.Game][.Fixed]=view_net_fixed
    worlds:=new([2]View_Net_World)
    defer free(worlds)
    shares:[2]Net_Test_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    bodies,eyes:[2]core.Entity
    third:=cam.camera_preset(.Third_Person).follow
    if !testing.expect(t,third.mode==.Orbit && third.turn && !third.aim,"Third_Person is a free Orbit") {return}
    for &world,index in worlds {
        net_test_init(&world,&info)
        world.network.role=index==0?.Server:.Client
        inp.input_map_action(&world.bindings,VIEW_MOVE,.Axis2)
        inp.input_map_bind(&world.bindings,VIEW_MOVE,inp.binding_keys(.A,.D,.S,.W))
        inp.input_map_action(&world.bindings,VIEW_LOOK,.Axis2)
        inp.input_map_bind(&world.bindings,VIEW_LOOK,inp.binding_mouse_delta())
        inp.input_map_compile(&world.bindings)
        // The body of the scene, which the client takes as the replica of the server's, and a camera of each end.
        bodies[index]=core.create(&world.entities)
        core.add(&world.identities,bodies[index],core.Id{1})
        core.add(&world.transforms,bodies[index],core.TRANSFORM_IDENTITY)
        core.add(&world.move_inputs,bodies[index],inp.Move_Input{})
        eyes[index]=core.create(&world.entities)
        core.add(&world.parents,eyes[index],core.Parent{entity=bodies[index]})
        core.add(&world.transforms,eyes[index],core.TRANSFORM_IDENTITY)
        core.add(&world.cameras,eyes[index],render.CAMERA_DEFAULT)
        core.add(&world.follows,eyes[index],third)
        // As its late step left it: the camera of the client turned a quarter to the right, the server's never.
        turned:=index==1?mm.quat_axis_angle({0,1,0},-math.PI/2):mm.QUAT_IDENTITY
        core.add(&world.worlds,eyes[index],core.World_Transform{transform={rotation=turned,scale=1}})
        core.settle(&info,&world,nil)
        shares[index].info=&info
        apps[index]={info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
    }
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
    defer for &app in apps {host.app_world_scratch_free(&app);delete(app.worlds)}
    defer for &share in shares {phys.collider_meshes_destroy(&share.colliders)}
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=77,endpoints=2,packets=1024})) {return}
    defer wire.sim_network_destroy(&network)
    for &session,index in sessions {
        if !testing.expect(t,net_test_session(&session,&worlds[index],&info,&apps[index],&network,index,index==0?.Server:.Client)) {return}
        shares[index].session=&session
    }
    defer for &session in sessions {session_destroy(&session)}
    problems:[2]core.Problems
    sessions[0].problems,sessions[1].problems=&problems[0],&problems[1]
    testing.expect_value(t,wire.host_connect(&sessions[1].host,wire.address_memory(0)),wire.Error.None)
    for index in 0..<2 {wire.sim_endpoint_conditions(&network,index,{latency=0.03})}
    server,client:=&worlds[0],&worlds[1]
    connected:Connection
    drove,held:=0,0
    // A quarter turn to the right, a little up, from a camera behind and above the body.
    sent:=inp.Seat_View{yaw=-math.PI/2,pitch=0.25,eye={0,1.5,2},kind=.Apart}
    for tick in 1..<360 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],core.world_ref(server,&info),nil,wire.host_poll(&sessions[0].host),&server.remote)
        for event in net_test_arrived(&sessions[0]) {
            if event.kind!=.Connected {continue}
            // The server seats the player of the connection in the body, which every client sees.
            connected=event.connection
            seat:=core.create(&server.entities)
            core.add(&server.seats,seat,inp.Seat{remote=true,body=bodies[0]})
            core.add(&server.nets,seat,Net_Seat{connection=connected})
            core.add(&server.transforms,seat,core.TRANSFORM_IDENTITY)
            for e in ([2]core.Entity{seat,bodies[0]}) {core.add(&server.objects,e,net_test_replicate(audience=.Always))}
            core.settle(&info,server,nil)
        }
        client_commands(&sessions[1],core.world_ref(client,&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host))
        client_reconcile(&sessions[1],core.world_ref(client,&info),&apps[1],1.0/60)
        // Once its seat drives its body and its input delay settled, the player holds forward for a
        // second, through the turned camera.
        own:=inp.local_seat(core.read(&client.seats),0)
        driving:=own!=core.NONE && inp.body_of(core.read(&client.seats),own)==bodies[1]
        client.input.keys_down={}
        client.slot_views.views[0]={}
        if driving {
            client.slot_views.views[0]=sent
            drove+=1
            if drove>60 && held<60 {
                client.input.keys_down={.W}
                held+=1
            }
        }
        for &world,index in worlds {
            core.settle(&info,&world,nil)
            world.time.tick=u64(tick+(index==1?8:0))
            view_net_fixed(&world,&shares[index],nil,&apps[index])
        }
        for &session in sessions {wire.host_update(&session.host,now)}
    }
    testing.expect(t,connected!=0 && sessions[1].status==.Connected)
    testing.expect_value(t,held,60)
    server_pose,_:=core.get(&server.transforms,bodies[0])
    client_pose,_:=core.get(&client.transforms,bodies[1])
    // A second at VIEW_SPEED along +X, the input delay and the lead aside.
    testing.expectf(t,server_pose.position.x>0.8*VIEW_SPEED && abs(server_pose.position.z)<0.01,"the server moved the body along where its player looked: %v",server_pose.position)
    testing.expectf(t,linalg.length(server_pose.position-client_pose.position)<0.01,"server %v client %v",server_pose.position,client_pose.position)
    // The server aims for the remote seat along the view its client sent, from where its camera was,
    // as the client aims for its own: its cameras never turned.
    aim_of :: proc(w:^View_Net_World,body:core.Entity) -> (origin,direction:[3]f32,ok:bool) {
        origin,direction,_,ok=inp.aim({core.ref(&w.seat_state),core.ref(&w.seat_runtime),core.read(&w.worlds),core.read(&w.verticals)},body)
        return
    }
    // Where each body is, as propagation leaves it.
    for &world,index in worlds {
        pose,_:=core.get(&world.transforms,bodies[index])
        core.add(&world.worlds,bodies[index],core.World_Transform{transform={position=pose.position,rotation=pose.rotation,scale=1}})
        core.settle(&info,&world,nil)
    }
    server_origin,server_direction,server_aimed:=aim_of(server,bodies[0])
    client_origin,client_direction,client_aimed:=aim_of(client,bodies[1])
    server_body,_:=core.get(&server.worlds,bodies[0])
    wanted:=[3]f32{math.cos(sent.pitch),math.sin(sent.pitch),0}
    testing.expectf(t,server_aimed && linalg.length(server_direction-wanted)<1e-3,"the server aims along the sent view: %v, not %v",server_direction,wanted)
    testing.expectf(t,linalg.length(server_origin-(server_body.position+sent.eye))<0.01,"the server aims from the sent eye: %v from the body at %v",server_origin,server_body.position)
    testing.expectf(t,client_aimed && linalg.length(client_direction-server_direction)<1e-3 && linalg.length(client_origin-server_origin)<0.02,"both ends aim alike: client %v %v, server %v %v",client_origin,client_direction,server_origin,server_direction)
    testing.expect_value(t,sessions[1].stats.corrected,u64(0))
    testing.expect(t,sessions[1].stats.confirmed>0,"the client compared its prediction")
    testing.expect_value(t,sessions[1].diagnostics.correction_count,u64(0))
    testing.expect_value(t,sessions[1].diagnostics.resimulation_count,u64(0))
    for &session,index in sessions {
        out:[4]Link_Stats
        seen:=links(&session,out[:])
        if !testing.expectf(t,len(seen)==1,"end %d has %d links",index,len(seen)) {continue}
        link:=seen[0]
        // 30 ms each way, measured on frames of 1/60 s.
        testing.expectf(t,link.rtt>0.05 && link.rtt<0.1 && link.jitter>=0 && link.jitter<0.05,"end %d: rtt %v jitter %v",index,link.rtt,link.jitter)
        testing.expectf(t,link.loss>=0 && link.loss<=0.01,"end %d: loss %v on a link that loses nothing",index,link.loss)
    }
    testing.expect_value(t,problems[0].count,0)
    testing.expect_value(t,problems[1].count,0)
}
