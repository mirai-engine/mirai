package multiplayer

import "core:testing"
import "mirai:core"
import "mirai:host"
import wire "mirai:net"
import "mirai:platform"

// A client whose server closes while its game is paused ends its session as
// net_begin does: its ticks go at the pace of the frames again.
@(test)
a_paused_client_whose_server_closes_runs_its_ticks_at_the_pace_of_the_frames :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    worlds:[2]Net_Test_World
    shares:[2]Net_Test_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    for &world,index in worlds {
        net_test_init(&world,&info)
        shares[index].info=&info
        apps[index]={info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
    }
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
    defer for &app in apps {host.app_world_scratch_free(&app);delete(app.worlds)}
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=5,endpoints=2,packets=256})) {return}
    defer wire.sim_network_destroy(&network)
    for &session,index in sessions {
        if !testing.expect(t,net_test_session(&session,&worlds[index],&info,&apps[index],&network,index,index==0?.Server:.Client)) {return}
    }
    defer for &session in sessions {session_destroy(&session)}
    defer delete(sessions[1].reason_text)
    testing.expect_value(t,wire.host_connect(&sessions[1].host,wire.address_memory(0)),wire.Error.None)
    server,client:=&worlds[0],&worlds[1]
    now:f64
    for tick in 1..<60 {
        now=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        server_commands(&sessions[0],core.world_ref(server,&info),nil,wire.host_poll(&sessions[0].host),&server.remote)
        client_commands(&sessions[1],core.world_ref(client,&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host))
        if sessions[1].status==.Connected {break}
    }
    if !testing.expect(t,sessions[1].status==.Connected,"the client connects") {return}
    testing.expect_value(t,wire.host_disconnect(&sessions[0].host),wire.Error.None)
    wire.host_update(&sessions[0].host,now)
    client.frame.dilation=0.5
    apps[1].start_ns=platform.clock_ns()-u64(now*1e9)
    for _ in 0..<8 {
        wire.sim_network_advance(&network,host.app_seconds(&apps[1]))
        pump(&sessions[1],core.world_ref(client,&info),&apps[1])
        if !sessions[1].host_ready {break}
    }
    testing.expect(t,sessions[1].ended && !sessions[1].host_ready,"the session of the client ends")
    testing.expect_value(t,sessions[1].reason,wire.Disconnect_Reason.Closed)
    testing.expect_value(t,client.frame.dilation,f32(0))
}
