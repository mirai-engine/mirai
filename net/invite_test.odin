package mirai_net

import "core:log"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

@(test)
invitation_codes_round_trip_and_refuse_typos :: proc(t:^testing.T) {
    address:=address_ip4(203,0,113,7,27500)
    code:=invite_encode(address,0xa1b2c3,context.temp_allocator)
    testing.expect_value(t,len(code),16+3)
    got,token,ok:=invite_decode(code)
    testing.expect(t,ok && got==address && token==0xa1b2c3)
    // Lowercase, spaces and the letters that look like digits are the same code.
    loose,_:=strings.replace_all(strings.to_lower(code,context.temp_allocator),"-"," ",context.temp_allocator)
    loose,_=strings.replace_all(loose,"0","o",context.temp_allocator)
    got,token,ok=invite_decode(loose)
    testing.expect(t,ok && got==address && token==0xa1b2c3)
    // A character changed or left out is no code.
    for i in 0..<len(code) {
        if code[i]=='-' {continue}
        changed:=transmute([]u8)strings.clone(code,context.temp_allocator)
        changed[i]=changed[i]=='Z'?'Y':'Z'
        _,_,wrong:=invite_decode(string(changed))
        testing.expect(t,!wrong)
    }
    _,_,short:=invite_decode(code[:len(code)-1])
    testing.expect(t,!short)
    _,_,empty:=invite_decode("")
    testing.expect(t,!empty)
    testing.expect_value(t,invite_encode(address,0,context.temp_allocator),"")
    testing.expect_value(t,invite_encode(address,1<<INVITE_TOKEN_BITS,context.temp_allocator),"")

    wide:=Address{kind=.IP6,port=7950,ip={0=0x20,1=0x01,2=0x0d,3=0xb8,15=1}}
    long:=invite_encode(wide,7,context.temp_allocator)
    testing.expect_value(t,len(long),36+8)
    got,token,ok=invite_decode(long)
    testing.expect(t,ok && got==wide && token==7)
    for _ in 0..<64 {
        token,made:=invite_token()
        testing.expect(t,made && token!=0 && token<1<<INVITE_TOKEN_BITS)
    }
}

// A transport that counts what its host sends to each address, by type.
@(private="file")
Answers :: struct {inner:Transport,sent:[4][Packet_Type]int,all:[Packet_Type]int,only:Address}
@(private="file")
answers_transport :: proc(a:^Answers) -> Transport {
    return {a,proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
        a:=(^Answers)(data)
        if to==a.only && len(bytes)>0 && bytes[0]<=u8(max(Packet_Type)) {a.all[Packet_Type(bytes[0])]+=1}
        if to.kind==.Memory && int(to.port)<len(a.sent) && len(bytes)>0 && bytes[0]<=u8(max(Packet_Type)) {a.sent[to.port][Packet_Type(bytes[0])]+=1}
        return a.inner.send(a.inner.data,to,bytes)
    },proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
        a:=(^Answers)(data)
        return a.inner.receive(a.inner.data,buffer)
    }}
}

// The invitation is in every key of the connection: a client without the
// right one, or that pinned another server's key, hears only the challenge
// every request gets, and its proof is dropped without an answer.
@(test)
a_server_with_an_invitation_answers_only_who_brings_it :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,5);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,invite=0x123456})
    answers:=Answers{inner=server.desc.transport}
    server.desc.transport=answers_transport(&answers)
    none:=test_host(&w,{mode=.Client,connect_timeout=1})
    other:=test_host(&w,{mode=.Client,invite=0x654321,connect_timeout=1})
    invited:=test_host(&w,{mode=.Client,invite=0x123456})
    for client,i in ([2]^Host{none,other}) {
        host_connect(client,address_memory(0))
        reason:Disconnect_Reason
        for _ in 0..<120 {
            test_step(&w)
            for command in host_poll(client) {
                if command.kind==.Disconnected {reason=command.reason}
                testing.expect(t,command.kind!=.Connected)
            }
            for command in host_poll(server) {testing.expect(t,command.kind!=.Connected)}
            if reason!=.None {break}
        }
        testing.expect_value(t,reason,Disconnect_Reason.Connect_Timeout)
        sent:=answers.sent[1+i]
        testing.expectf(t,sent[.Challenge]>0 && sent[.Accepted]==0 && sent[.Denied]==0 && sent[.Data]==0,"the server answered %v",sent)
    }
    stats:=host_stats(server)
    testing.expect(t,stats.handshakes_dropped>=2 && stats.handshakes_refused==0)

    // A forger returns a cookie it got at its own address with a proof it made up: nothing comes back.
    forger:=sim_endpoint_transport(&w.sim,4)
    buffer,answer:[PACKET_BYTES]u8
    writer:serial.Bit_Writer
    buffer[0]=u8(Packet_Type.Request)
    serial.bit_writer_init(&writer,buffer[1:])
    serial.bit_write(&writer,0x77,64)
    forger.send(forger.data,address_memory(0),test_handshake(buffer[:],&writer,server.back.key,HANDSHAKE_BYTES))
    test_step(&w,2)
    host_poll(server)
    size,_,challenged:=forger.receive(forger.data,answer[:])
    testing.expect(t,challenged && Packet_Type(answer[0])==.Challenge)
    reader:serial.Bit_Reader
    serial.bit_reader_init(&reader,answer[1:size-CHECKSUM_BYTES])
    salt,stamp,cookie:=serial.bit_read(&reader,64),serial.bit_read(&reader,64),serial.bit_read(&reader,64)
    dropped:=host_stats(server).handshakes_dropped
    state:=u64(5)
    for round in 0..<4 {
        buffer[0]=u8(Packet_Type.Response)
        serial.bit_writer_init(&writer,buffer[1:])
        serial.bit_write(&writer,salt,64)
        serial.bit_write(&writer,stamp,64)
        serial.bit_write(&writer,cookie,64)
        serial.bit_write(&writer,host_protocol_hash(server),64)
        serial.bit_write_bool(&writer,round%2==1)
        serial.bit_write_align(&writer)
        for _ in 0..<KEY_BYTES+TOKEN_BYTES+TAG_BYTES {serial.bit_write(&writer,base.splitmix_next(&state)&0xff,8)}
        forger.send(forger.data,address_memory(0),test_handshake(buffer[:],&writer,server.back.key,HANDSHAKE_BYTES))
    }
    test_step(&w,2)
    host_poll(server)
    _,_,answered:=forger.receive(forger.data,answer[:])
    testing.expect(t,!answered)
    testing.expect_value(t,host_stats(server).handshakes_dropped,dropped+4)

    on_server,on_client:=test_connect(&w,server,invited)
    testing.expect(t,on_server!=0 && on_client!=0)
    testing.expect_value(t,host_stats(server).handshakes_refused,u64(0))
}

// The same over real UDP sockets on loopback: the right invitation connects
// and carries a message; a wrong one and none hear only the challenge.
@(test)
an_invitation_over_udp_on_loopback_answers_only_who_brings_it :: proc(t:^testing.T) {
    server_socket:Udp
    if !udp_open(&server_socket,address_loopback(0)) {testing.expect(t,false,"cannot bind a UDP socket on 127.0.0.1");return}
    defer udp_close(&server_socket)
    answers:=Answers{inner=udp_transport(&server_socket)}
    server:=new(Host)
    defer free(server)
    if !testing.expect_value(t,host_init(server,{mode=.Server,transport=answers_transport(&answers),channels={{kind=.Reliable}},invite=0x2b3c4d,protocol_id=91}),Error.None) {return}
    defer host_destroy(server)
    attempt :: proc(t:^testing.T,server:^Host,answers:^Answers,address:Address,invite:u32) -> (reason:Disconnect_Reason,delivered:bool) {
        client_socket:Udp
        if !udp_open(&client_socket,address_loopback(0)) {testing.expect(t,false,"cannot bind a UDP socket on 127.0.0.1");return}
        defer udp_close(&client_socket)
        client:=new(Host)
        defer free(client)
        if !testing.expect_value(t,host_init(client,{mode=.Client,transport=udp_transport(&client_socket),channels={{kind=.Reliable}},invite=invite,protocol_id=91,connect_timeout=1}),Error.None) {return}
        defer host_destroy(client)
        answers.all,answers.only={},client_socket.address
        host_connect(client,address)
        reason=.Timeout
        start:=host_time(server)
        for host_time(server)-start<3 {
            now:=host_time(server)
            host_update(client,now);host_update(server,now)
            for command in host_poll(server) {
                if command.kind==.Message {delivered=true}
            }
            for command in host_poll(client) {
                if command.kind==.Connected {reason=.None;message_send(client,command.connection,0,{1,2,3})}
                if command.kind==.Disconnected {return command.reason,delivered}
            }
            if delivered {return}
            time.sleep(time.Millisecond)
        }
        return
    }
    reason,delivered:=attempt(t,server,&answers,server_socket.address,0x2b3c4d)
    testing.expect(t,reason==.None && delivered,"the right invitation connects and carries a message")
    for invite in ([2]u32{0x2b3c4e,0}) {
        reason,_=attempt(t,server,&answers,server_socket.address,invite)
        testing.expect_value(t,reason,Disconnect_Reason.Connect_Timeout)
        testing.expectf(t,answers.all[.Challenge]>0 && answers.all[.Accepted]==0 && answers.all[.Denied]==0 && answers.all[.Data]==0,"invitation %x: the server answered %v",invite,answers.all)
    }
}

// The address of this machine on its network is the one of its route to the
// internet, which a test machine with a network has; never a link-local one.
@(test)
the_address_on_the_network_is_the_routed_one :: proc(t:^testing.T) {
    lan:=address_lan(27500)
    testing.expect_value(t,lan.kind,Address_Kind.IP4)
    testing.expect_value(t,lan.port,u16(27500))
    testing.expect(t,!(lan.ip[0]==169 && lan.ip[1]==254))
    routed:=portmap_gateway()
    testing.expect(t,routed.kind==.None || lan.ip[0]!=127,"with a gateway there is an address on the network")
    log.infof("address on the network: %d.%d.%d.%d, gateway %v",lan.ip[0],lan.ip[1],lan.ip[2],lan.ip[3],routed.ip[:4])
}
