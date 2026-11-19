package mirai_net

import "core:testing"
import "core:crypto/chacha20poly1305"
import "core:crypto/ecdh"
import "core:crypto/noise"
import "core:crypto/x25519"
import "core:fmt"
import "core:time"

@(private="file")
SECURE_CHANNELS :: []Channel_Desc{{kind=.Reliable,queue_bytes=64<<10},{kind=.Unreliable}}

// A transport that keeps a copy of the last datagrams it delivered and can hold one back.
@(private="file")
Capture :: struct {inner:Transport,last:[2][PACKET_BYTES]u8,sizes:[2]int,count:int,hold:bool,held:[PACKET_BYTES]u8,held_size:int}
@(private="file")
capture_transport :: proc(c:^Capture) -> Transport {
    return {data=c,send=proc(data:rawptr,batch:[]Datagram) -> int {return test_send_each(data,batch,proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
        c:=(^Capture)(data)
        return test_send_one(c.inner,to,bytes)
    })},receive=proc(data:rawptr,batch:[]Datagram) -> int {return test_receive_each(data,batch,proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
        c:=(^Capture)(data)
        size,from,ok=test_receive_one(c.inner,buffer)
        if !ok || !test_packet_data(buffer[:size]) || buffer[0]!=u8(Packet_Type.Data) {return}
        if c.hold && c.held_size==0 {
            copy(c.held[:],buffer[:size])
            c.held_size=size
            return test_receive_one(c.inner,buffer)
        }
        slot:=c.count%2
        copy(c.last[slot][:],buffer[:size])
        c.sizes[slot]=size
        c.count+=1
        return
    })}}
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
    return {data=k,send=proc(data:rawptr,batch:[]Datagram) -> int {return test_send_each(data,batch,proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
        k:=(^Kept)(data)
        if !k.keep {return test_send_one(k.inner,to,bytes)}
        if k.count<len(k.datagrams) {
            copy(k.datagrams[k.count][:],bytes)
            k.sizes[k.count]=len(bytes)
            k.count+=1
        }
        return true
    })},receive=proc(data:rawptr,batch:[]Datagram) -> int {return test_receive_each(data,batch,proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
        k:=(^Kept)(data)
        return test_receive_one(k.inner,buffer)
    })}}
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
    // Until a step in which the client sent nothing: no datagram of it is on the way.
    for sent:=u64(0);sent!=client.back.peers[0].stats.packets_sent; {
        sent=client.back.peers[0].stats.packets_sent
        test_step(&w)
    }
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

// The handshake is Noise NKpsk0 as the Noise framework defines it: an Initiate
// and a Response of ours are read by core:crypto/noise and the other way
// around, and both take the same two keys from Split.
@(test)
the_handshake_is_noise_nkpsk0_and_both_ends_take_the_keys_it_splits :: proc(t:^testing.T) {
    static,public,psk:Key
    for &b,i in static {b=u8(i*13+5)}
    for &b,i in psk {b=u8(i*7+1)}
    x25519.scalarmult_basepoint(public[:],static[:])
    prologue:=[]u8{1,2,3,4}
    s_key:ecdh.Private_Key
    testing.expect(t,ecdh.private_key_set_bytes(&s_key,.X25519,static[:]))
    rs:ecdh.Public_Key
    testing.expect(t,ecdh.public_key_set_bytes(&rs,.X25519,public[:]))
    // The transport keys of both: what one seals the other opens.
    agree :: proc(t:^testing.T,cs:^noise.Cipher_States,ours:^Peer_Secure) {
        sealed:[1+TAG_BYTES]u8
        _,status:=noise.seal_message(cs,nil,{'x'},sealed[:])
        testing.expect_value(t,status,noise.Status.Ok)
        key:=ours.receive
        ctx:chacha20poly1305.Context
        iv:=noise_iv(0)
        chacha20poly1305.init(&ctx,key[:])
        plain:[1]u8
        testing.expect(t,chacha20poly1305.open(&ctx,plain[:],iv[:],nil,sealed[:1],sealed[1:]) && plain[0]=='x')
        key=ours.send
        chacha20poly1305.init(&ctx,key[:])
        mine:[1+TAG_BYTES]u8
        chacha20poly1305.seal(&ctx,mine[:1],mine[1:],iv[:],nil,{'y'})
        opened:[1]u8
        _,status=noise.open_message(cs,nil,mine[:],opened[:])
        testing.expect(t,status==.Ok && opened[0]=='y')
    }
    {
        n:Noise
        e:Key
        message:[KEY_BYTES+5+TAG_BYTES]u8
        copy(message[KEY_BYTES:],"hello")
        testing.expect(t,noise_initiate(&n,&e,prologue,&public,&psk,message[:]))
        hs:noise.Handshake_State
        testing.expect_value(t,noise.handshake_init(&hs,false,prologue,&s_key,nil,NOISE_PROTOCOL,psk[:]),noise.Status.Ok)
        buffer:[256]u8
        reply,payload,status:=noise.handshake_responder_step(&hs,message[:],{'o','k'},buffer[:])
        testing.expect(t,status==.Handshake_Complete && string(payload)=="hello")
        response:[KEY_BYTES+2+TAG_BYTES]u8
        testing.expect_value(t,copy(response[:],reply),len(response))
        ours:Peer_Secure
        testing.expect(t,noise_finish(&n,&e,response[:],&ours) && string(response[KEY_BYTES:][:2])=="ok")
        cs:noise.Cipher_States
        testing.expect_value(t,noise.handshake_split(&hs,&cs),noise.Status.Ok)
        agree(t,&cs,&ours)
        testing.expect(t,ours.send!=ours.receive)
    }
    {
        hs:noise.Handshake_State
        testing.expect_value(t,noise.handshake_init(&hs,true,prologue,nil,&rs,NOISE_PROTOCOL,psk[:]),noise.Status.Ok)
        buffer:[256]u8
        first,_,status:=noise.handshake_initiator_step(&hs,nil,{'h','i'},buffer[:])
        testing.expect_value(t,status,noise.Status.Handshake_Pending)
        message:[KEY_BYTES+2+TAG_BYTES]u8
        testing.expect_value(t,copy(message[:],first),len(message))
        n:Noise
        testing.expect(t,noise_accept(&n,prologue,&static,&public,&psk,message[:]) && string(message[KEY_BYTES:][:2])=="hi")
        ours:Peer_Secure
        initiator:=(^Key)(&message[0])^
        response:[KEY_BYTES+TAG_BYTES]u8
        testing.expect(t,noise_respond(&n,&initiator,response[:],&ours))
        more:[64]u8
        _,payload,done:=noise.handshake_initiator_step(&hs,response[:],nil,more[:])
        testing.expect(t,done==.Handshake_Complete && len(payload)==0)
        cs:noise.Cipher_States
        testing.expect_value(t,noise.handshake_split(&hs,&cs),noise.Status.Ok)
        agree(t,&cs,&ours)
    }
}

// What a recorded connection gives whoever lacks its keys. Its Initiate opens
// only with s, so without s the right secret fails like any other: there is
// nothing to try secrets against. With s and the secret its Initiate opens, but
// what follows the Response does not: it takes the two ephemeral keys, which
// die with the handshake, and s dies with the share, when its host goes.
@(test)
recorded_traffic_neither_tests_the_secret_nor_opens_once_its_keys_are_gone :: proc(t:^testing.T) {
    key:=test_key(77)
    psk:=invite_psk(key.secret,77)
    prologue:=[]u8{9,9}
    client,server:Noise
    e:Key
    initiate:[KEY_BYTES+5+TAG_BYTES]u8
    copy(initiate[KEY_BYTES:],"early")
    testing.expect(t,noise_initiate(&client,&e,prologue,&key.public,&psk,initiate[:]))
    recorded:=initiate
    testing.expect(t,noise_accept(&server,prologue,&key.private,&key.public,&psk,initiate[:]) && string(initiate[KEY_BYTES:][:5])=="early")
    on_server,on_client:Peer_Secure
    initiator:=(^Key)(&recorded[0])^
    response:[KEY_BYTES+TAG_BYTES]u8
    testing.expect(t,noise_respond(&server,&initiator,response[:],&on_server))
    recorded_response:=response
    testing.expect(t,noise_finish(&client,&e,response[:],&on_client))
    testing.expect(t,on_client.send==on_server.receive && on_client.receive==on_server.send)
    datagram:[DATA_HEADER+4+TAG_BYTES]u8
    copy(datagram[DATA_HEADER:],"data")
    aead_seal(&on_client.send,1,datagram[:DATA_HEADER],datagram[DATA_HEADER:][:4],datagram[DATA_HEADER+4:])

    other:Key
    for &b,i in other {b=u8(i+100)}
    for secret in ([]u64{key.secret,key.secret+1,7}) {
        guess:=invite_psk(secret,77)
        copied:=recorded
        n:Noise
        testing.expectf(t,!noise_accept(&n,prologue,&other,&key.public,&guess,copied[:]),"without s the secret %x was tested",secret)
    }
    // With s and the secret: the Initiate, not the Response nor what follows.
    copied:=recorded
    n:Noise
    testing.expect(t,noise_accept(&n,prologue,&key.private,&key.public,&psk,copied[:]))
    after:=n
    guess:Peer_Secure
    fresh:[KEY_BYTES+TAG_BYTES]u8
    testing.expect(t,noise_respond(&n,&initiator,fresh[:],&guess))
    body:=datagram
    testing.expect(t,!aead_open(&guess.receive,1,body[:DATA_HEADER],body[DATA_HEADER:][:4],body[DATA_HEADER+4:]))
    other_e:Key
    for &b,i in other_e {b=u8(i*3)}
    reply:=recorded_response
    testing.expect(t,!noise_finish(&after,&other_e,reply[:],&guess))

    w:Test_World;test_world_init(&w,1);defer test_world_destroy(&w)
    h:=test_host(&w,{mode=.Server,invite=key})
    testing.expect(t,h.back.secure.private==key.private && h.back.secure.invited)
    secure_host_destroy(h)
    testing.expect(t,h.back.secure.private==Key{} && h.back.secure.psk==Key{})
    secure_host_init(h)
}

// The keys a handshake splits take the place of the old ones in the ratchet:
// the client's datagram 0 is its Initiate, so its first under AEGIS is 1; a key
// is derived every rekey_interval datagrams at both ends; the receiver keeps
// the previous key for late datagrams and refuses one two epochs back.
@(test)
the_ratchet_runs_on_the_keys_the_handshake_splits :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    key:=test_key(3)
    server:=test_host(&w,{mode=.Server,channels=SECURE_CHANNELS,invite=key})
    client:=test_host(&w,{mode=.Client,channels=SECURE_CHANNELS,invite=test_invited(key)})
    server.back.secure.rekey_interval,client.back.secure.rekey_interval=4,4
    capture:=Capture{inner=server.desc.transport}
    server.desc.transport=capture_transport(&capture)
    host_connect(client,address_memory(0))
    message_send(client,0,0,{0})
    on_server,on_client:Connection
    first:=-1
    received,sent:=0,1
    for step in 0..<200 {
        if on_client!=0 && step%2==0 {
            message_send(client,on_client,0,{u8(step)})
            message_send(server,on_server,1,{u8(step)})
            sent+=1
        }
        test_step(&w)
        if first<0 && capture.count>0 {first=int(capture.last[0][1])|int(capture.last[0][2])<<8}
        for command in host_poll(server) {
            if command.kind==.Connected {on_server=command.connection}
            if command.kind==.Message {received+=1}
        }
        for command in host_poll(client) {if command.kind==.Connected {on_client=command.connection}}
    }
    p,q:=peer_from(server,on_server),peer_from(client,on_client)
    if !testing.expect(t,p!=nil && q!=nil) {return}
    testing.expect_value(t,first,1)
    testing.expectf(t,received==sent && q.secure.send_epoch>=10 && p.secure.receive_epoch==q.secure.send_epoch,"%d messages of %d, epochs %d and %d",received,sent,q.secure.send_epoch,p.secure.receive_epoch)
    testing.expect(t,p.secure.send_epoch>=10 && q.secure.receive_epoch==p.secure.send_epoch && q.secure.has_old)
    stale:[DATA_HEADER+1+TAG_BYTES]u8
    counter:=(p.secure.receive_epoch-2)*4
    testing.expect(t,!secure_open(server,p,counter,stale[:DATA_HEADER],stale[DATA_HEADER:][:1],stale[DATA_HEADER+1:]))
}
