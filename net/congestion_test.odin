package mirai_net

import "core:testing"

@(private="file")
FLOOD_CHANNELS :: []Channel_Desc{{kind=.Unreliable,queue_bytes=16<<10}}

// A server that always has more to send than the path carries, over a link that narrows to a fifth of
// its capacity and widens again. Measured on the client: what arrives, per window of the phases.
@(test)
congestion_control_follows_a_link_that_narrows_and_recovers :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2,seed=5);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,channels=FLOOD_CHANNELS,send_rate=256<<10,packets_per_update=8})
    client:=test_host(&w,{mode=.Client,channels=FLOOD_CHANNELS})
    on_server,on_client:=test_connect(&w,server,client)
    testing.expect(t,on_server!=0 && on_client!=0)
    payload:[1000]u8
    Phase :: struct {bandwidth:f64,seconds:int}
    phases:=[3]Phase{{120<<10,6},{24<<10,12},{120<<10,12}}
    for phase,index in phases {
        sim_endpoint_conditions(&w.sim,0,{latency=0.02,bandwidth=phase.bandwidth})
        steps:=phase.seconds*60
        arrived:f64
        sent_before,lost_before:u64
        for step in 0..<steps {
            for _ in 0..<8 {message_send(server,on_server,0,payload[:])}
            test_step(&w)
            host_poll(server)
            for command in host_poll(client) {
                testing.expect(t,command.kind!=.Disconnected,"the connection collapsed")
                // The second half of the phase, once the rate had time to settle.
                if command.kind==.Message && step>=steps/2 {arrived+=f64(len(command.data))}
            }
            if step==steps/2 {
                stats,_:=connection_stats(server,on_server)
                sent_before,lost_before=stats.packets_acked+stats.packets_lost,stats.packets_lost
            }
        }
        stats,_:=connection_stats(server,on_server)
        throughput:=arrived/(f64(steps/2)/60)
        settled:=stats.packets_acked+stats.packets_lost-sent_before
        loss:=f64(stats.packets_lost-lost_before)/max(f64(settled),1)
        // Messages are most of each datagram; headers and tags take the rest of the capacity.
        testing.expectf(t,throughput>0.75*phase.bandwidth,"phase %d: %.0f B/s arrive over a link of %.0f",index,throughput,phase.bandwidth)
        testing.expectf(t,loss<0.15,"phase %d: %.0f%% of the datagrams lost once settled",index,loss*100)
        testing.expectf(t,f64(stats.send_limit)<2.5*phase.bandwidth,"phase %d: the limit stays at %.0f B/s",index,stats.send_limit)
        if index==1 {testing.expect(t,stats.send_limit_cuts>0)}
    }
}
