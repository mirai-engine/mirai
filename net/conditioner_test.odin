package mirai_net

import "core:testing"

@(test)
a_conditioned_transport_delays_both_ways_and_loses_what_it_is_told :: proc(t:^testing.T) {
    wire:Sim_Network
    testing.expect(t,sim_network_init(&wire,{seed=1,endpoints=2}))
    defer sim_network_destroy(&wire)
    now:f64
    clock :: proc(data:rawptr) -> f64 {return (^f64)(data)^}
    c:Conditioner
    testing.expect(t,conditioner_init(&c,sim_endpoint_transport(&wire,0),{latency=0.05},{seed=2,clock=clock,clock_data=&now}))
    defer conditioner_destroy(&c)
    client,server:=conditioner_transport(&c),sim_endpoint_transport(&wire,1)
    buffer:[PACKET_BYTES]u8
    ping:=[3]u8{1,2,3}
    // Out: held 50 ms before it reaches the wire.
    testing.expect(t,test_send_one(client,address_memory(1),ping[:]))
    _,_,early:=test_receive_one(server,buffer[:])
    testing.expect(t,!early,"nothing arrives before the latency")
    now=0.051
    _,_,_=test_receive_one(client,buffer[:])
    size,from,arrived:=test_receive_one(server,buffer[:])
    testing.expect(t,arrived && size==3 && from==address_memory(0) && buffer[2]==3)
    // Back: held 50 ms after it reaches this end.
    testing.expect(t,test_send_one(server,address_memory(0),ping[:2]))
    _,_,soon:=test_receive_one(client,buffer[:])
    testing.expect(t,!soon,"what comes back waits the latency too")
    now=0.102
    size,from,arrived=test_receive_one(client,buffer[:])
    testing.expect(t,arrived && size==2 && from==address_memory(1))
    // A link that loses everything delivers nothing, either way.
    c.conditions={loss=1}
    for _ in 0..<10 {test_send_one(client,address_memory(1),ping[:])}
    now=1
    _,_,_=test_receive_one(client,buffer[:])
    _,_,lost:=test_receive_one(server,buffer[:])
    testing.expect(t,!lost)
    stats:=conditioner_stats(&c)
    testing.expect(t,stats.lost==10 && stats.sent==12)
}

// Destroyed, it sends what it was holding: the goodbye of a closing end.
@(test)
a_conditioner_sends_what_it_holds_when_destroyed :: proc(t:^testing.T) {
    wire:Sim_Network
    testing.expect(t,sim_network_init(&wire,{seed=1,endpoints=2}))
    defer sim_network_destroy(&wire)
    now:f64
    clock :: proc(data:rawptr) -> f64 {return (^f64)(data)^}
    c:Conditioner
    testing.expect(t,conditioner_init(&c,sim_endpoint_transport(&wire,0),{latency=0.5},{seed=2,clock=clock,clock_data=&now}))
    client,server:=conditioner_transport(&c),sim_endpoint_transport(&wire,1)
    buffer:[PACKET_BYTES]u8
    bye:=[2]u8{7,8}
    testing.expect(t,test_send_one(client,address_memory(1),bye[:]))
    conditioner_destroy(&c)
    size,_,arrived:=test_receive_one(server,buffer[:])
    testing.expect(t,arrived && size==2 && buffer[1]==8,"what it held arrives")
}
