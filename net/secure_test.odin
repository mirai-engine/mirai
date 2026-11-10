package mirai_net

import "core:testing"
import "core:crypto/x25519"
import "core:fmt"
import "core:time"

@(private="file")
SECURE_CHANNELS :: []Channel_Desc{{kind=.Reliable,max_message_bytes=4000,queue_bytes=64<<10},{kind=.Unreliable}}

// A transport that keeps a copy of the last datagrams it delivered and can hold one back.
@(private="file")
Capture :: struct {inner:Transport,last:[2][PACKET_BYTES]u8,sizes:[2]int,count:int,hold:bool,held:[PACKET_BYTES]u8,held_size:int}
@(private="file")
capture_transport :: proc(c:^Capture) -> Transport {
    return {c,proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
        c:=(^Capture)(data)
        return c.inner.send(c.inner.data,to,bytes)
    },proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
        c:=(^Capture)(data)
        size,from,ok=c.inner.receive(c.inner.data,buffer)
        if !ok || !test_packet_data(buffer[:size]) || buffer[0]!=u8(Packet_Type.Data) {return}
        if c.hold && c.held_size==0 {
            copy(c.held[:],buffer[:size])
            c.held_size=size
            return c.inner.receive(c.inner.data,buffer)
        }
        slot:=c.count%2
        copy(c.last[slot][:],buffer[:size])
        c.sizes[slot]=size
        c.count+=1
        return
    }}
}

@(test)
encrypted_traffic_drops_and_counts_tampered_replayed_truncated_and_late_datagrams :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,channels=SECURE_CHANNELS})
    client:=test_host(&w,{mode=.Client,channels=SECURE_CHANNELS})
    capture:=Capture{inner=server.desc.transport}
    server.desc.transport=capture_transport(&capture)
    on_server,on_client:=test_connect(&w,server,client)
    testing.expect(t,on_server!=0 && on_client!=0)
    talk :: proc(w:^Test_World,client,server:^Host,on_client:Connection,steps:int) {
        for _ in 0..<steps {
            message_send(client,on_client,1,{7})
            test_step(w)
            host_poll(server);host_poll(client)
        }
    }
    talk(&w,client,server,on_client,10)
    testing.expect(t,capture.count>2)
    from:=address_memory(1)
    p:=peer_find(&server.back,from)
    before:=p.stats
    copy_of :: proc(c:^Capture,buffer:^[PACKET_BYTES]u8) -> []u8 {
        slot:=(c.count-1)%2
        copy(buffer[:],c.last[slot][:c.sizes[slot]])
        return buffer[:c.sizes[slot]]
    }
    buffer:[PACKET_BYTES]u8
    // Replayed: authentic but already seen.
    packet_receive(server,copy_of(&capture,&buffer),from)
    // Tampered in the body, in the header and in the tag; cut short.
    for at in ([3]int{DATA_HEADER+2,1,-3}) {
        bytes:=copy_of(&capture,&buffer)
        bytes[at if at>=0 else len(bytes)+at]~=0x10
        packet_receive(server,bytes,from)
    }
    bytes:=copy_of(&capture,&buffer)
    packet_receive(server,bytes[:len(bytes)-5],from)
    after:=p.stats
    testing.expect_value(t,after.packets_rejected-before.packets_rejected,u64(4))
    testing.expect_value(t,after.packets_out_of_order-before.packets_out_of_order,u64(1))
    // Late: one held back arrives after newer ones and is taken as late, once; a copy of it is dropped.
    capture.hold=true
    for capture.held_size==0 {talk(&w,client,server,on_client,1)}
    talk(&w,client,server,on_client,3)
    late,twice:=p.stats.packets_late,p.stats.packets_out_of_order
    // The host opens a datagram in place: each delivery gets its own copy.
    for _ in 0..<2 {
        copy(buffer[:],capture.held[:capture.held_size])
        packet_receive(server,buffer[:capture.held_size],from)
    }
    testing.expect_value(t,p.stats.packets_late,late+1)
    testing.expect_value(t,p.stats.packets_out_of_order,twice+1)
    // The connection lives on and still carries messages.
    message_send(client,on_client,0,{1,2,3})
    got:=false
    for _ in 0..<60 {
        test_step(&w)
        for command in host_poll(server) {
            if command.kind==.Message {got=true}
            testing.expect(t,command.kind!=.Disconnected)
        }
        host_poll(client)
    }
    testing.expect(t,got)
}

// Opt-in: mirai test net cost_of_sealing_a_datagram --release -define:NET_BENCHMARK=true
@(test)
cost_of_sealing_a_datagram :: proc(t:^testing.T) {
    when !#config(NET_BENCHMARK,false) {return}
    ROUNDS :: 20000
    key:Key
    for &b,i in key {b=u8(i*7+1)}
    packet:[PACKET_BYTES]u8
    for &b,i in packet {b=u8(i)}
    body:=packet[DATA_HEADER:PACKET_BYTES-TAG_BYTES]
    tag:=packet[PACKET_BYTES-TAG_BYTES:]
    start:=time.tick_now()
    for i in 0..<ROUNDS {aead_seal(&key,u64(i),packet[:DATA_HEADER],body,tag)}
    seal:=time.duration_microseconds(time.tick_since(start))/ROUNDS
    start=time.tick_now()
    opened:=0
    for _ in 0..<ROUNDS {
        aead_seal(&key,7,packet[:DATA_HEADER],body,tag)
        if aead_open(&key,7,packet[:DATA_HEADER],body,tag) {opened+=1}
    }
    both:=time.duration_microseconds(time.tick_since(start))/ROUNDS
    start=time.tick_now()
    for _ in 0..<ROUNDS {
        checksum_write(packet[:],0x1234)
        if checksum_check(packet[:],0x1234) {opened+=1}
    }
    plain:=time.duration_microseconds(time.tick_since(start))/ROUNDS
    a,bp,shared:Key
    for &byte,i in a {byte=u8(i*5+3)}
    x25519.scalarmult_basepoint(bp[:],a[:])
    start=time.tick_now()
    for _ in 0..<200 {secure_exchange(&shared,&a,&bp)}
    exchange:=time.duration_microseconds(time.tick_since(start))/200
    testing.expect_value(t,opened,2*ROUNDS)
    fmt.printfln("NET_BENCH_SECURE,datagram_bytes=%v,seal_us=%.2f,seal_and_open_us=%.2f,checksum_write_and_check_us=%.3f,x25519_exchange_us=%.1f",PACKET_BYTES,seal,both,plain,exchange)
}

// A transport that keeps what its host sends instead of putting it on the network.
@(private="file")
Kept :: struct {inner:Transport,keep:bool,datagrams:[200][PACKET_BYTES]u8,sizes:[200]int,count:int}
@(private="file")
kept_transport :: proc(k:^Kept) -> Transport {
    return {k,proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
        k:=(^Kept)(data)
        if !k.keep {return k.inner.send(k.inner.data,to,bytes)}
        if k.count<len(k.datagrams) {
            copy(k.datagrams[k.count][:],bytes)
            k.sizes[k.count]=len(bytes)
            k.count+=1
        }
        return true
    },proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
        k:=(^Kept)(data)
        return k.inner.receive(k.inner.data,buffer)
    }}
}

// Opt-in: mirai test net cost_of_connecting_and_of_each_datagram -define:NET_BENCHMARK=true
// The CPU of a handshake on the in-memory network and the updates it takes, and the CPU of the host
// per datagram of 1000 bytes of message: the client's update that sends it and the server's reading.
@(test)
cost_of_connecting_and_of_each_datagram :: proc(t:^testing.T) {
    when !#config(NET_BENCHMARK,false) {return}
    CONNECTS :: 100
    connect_us:f64
    rounds:=0
    for _ in 0..<CONNECTS {
        w:Test_World;test_world_init(&w,2)
        server:=test_host(&w,{mode=.Server,channels=SECURE_CHANNELS})
        client:=test_host(&w,{mode=.Client,channels=SECURE_CHANNELS})
        host_connect(client,address_memory(0))
        start:=time.tick_now()
        for round in 1..=100 {
            w.now+=0.001
            sim_network_advance(&w.sim,w.now)
            host_update(client,w.now)
            host_update(server,w.now)
            connected:=false
            for command in host_poll(client) {connected||=command.kind==.Connected}
            if connected {rounds+=round;break}
        }
        connect_us+=time.duration_microseconds(time.tick_since(start))
        test_world_destroy(&w)
    }
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,channels=SECURE_CHANNELS})
    client:=test_host(&w,{mode=.Client,channels=SECURE_CHANNELS})
    kept:=Kept{inner=client.desc.transport}
    client.desc.transport=kept_transport(&kept)
    _,on_client:=test_connect(&w,server,client)
    testing.expect(t,on_client!=0)
    payload:[1000]u8
    send_us,receive_us:f64
    datagrams:=0
    for _ in 0..<20 {
        kept.keep,kept.count=true,0
        for _ in 0..<len(kept.datagrams) {
            message_send(client,on_client,1,payload[:])
            w.now+=TEST_STEP
            start:=time.tick_now()
            host_update(client,w.now)
            send_us+=time.duration_microseconds(time.tick_since(start))
        }
        buffer:[PACKET_BYTES]u8
        start:=time.tick_now()
        for i in 0..<kept.count {
            copy(buffer[:],kept.datagrams[i][:kept.sizes[i]])
            packet_receive(server,buffer[:kept.sizes[i]],address_memory(1))
        }
        receive_us+=time.duration_microseconds(time.tick_since(start))
        datagrams+=kept.count
        kept.keep=false
        test_step(&w,2)
        host_poll(server);host_poll(client)
    }
    testing.expect(t,datagrams>0 && host_stats(server).connections==1)
    fmt.printfln("NET_BENCH_LINK,connect_us=%.1f,connect_updates=%.1f,send_us_per_datagram=%.2f,receive_us_per_datagram=%.2f,datagrams=%d",
        connect_us/CONNECTS,f64(rounds)/CONNECTS,send_us/f64(datagrams),receive_us/f64(datagrams),datagrams)
}

@(test)
a_late_datagram_delivers_its_reliable_chunks_and_skips_the_rest :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,channels=SECURE_CHANNELS})
    client:=test_host(&w,{mode=.Client,channels=SECURE_CHANNELS})
    capture:=Capture{inner=server.desc.transport}
    server.desc.transport=capture_transport(&capture)
    on_server,on_client:=test_connect(&w,server,client)
    testing.expect(t,on_server!=0 && on_client!=0)
    test_step(&w,10)
    host_poll(server);host_poll(client)
    // The datagram with both messages is held back; the next one goes through.
    capture.hold=true
    message_send(client,on_client,0,{'R'})
    message_send(client,on_client,1,{'U'})
    for capture.held_size==0 {test_step(&w);host_poll(server);host_poll(client)}
    seen:=capture.count
    for capture.count==seen {
        message_send(client,on_client,1,{7})
        test_step(&w)
        for command in host_poll(server) {testing.expect(t,command.kind!=.Message || command.data[0]==7)}
        host_poll(client)
    }
    // Before the client learns that it went missing, it arrives.
    p:=peer_find(&server.back,address_memory(1))
    late:=p.stats.packets_late
    buffer:[PACKET_BYTES]u8
    copy(buffer[:],capture.held[:capture.held_size])
    packet_receive(server,buffer[:capture.held_size],address_memory(1))
    testing.expect_value(t,p.stats.packets_late,late+1)
    // The reliable message arrives once, although the client also resends it; the unreliable one never.
    reliable,unreliable:=0,0
    for _ in 0..<30 {
        test_step(&w)
        for command in host_poll(server) {
            if command.kind!=.Message {continue}
            if command.data[0]=='R' {reliable+=1}
            if command.data[0]=='U' {unreliable+=1}
        }
        host_poll(client)
    }
    testing.expectf(t,reliable==1 && unreliable==0,"reliable %d, unreliable %d",reliable,unreliable)
}
