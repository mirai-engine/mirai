package mirai_net

import "core:log"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

@(test)
invitation_codes_round_trip_and_refuse_typos :: proc(t:^testing.T) {
    lan,public:=address_ip4(192,168,1,20,27500),address_ip4(203,0,113,7,41000)
    for invitation in ([]Invitation{{lan,public,0xa1b2c3d4},{lan,{},1},{{},public,0xffffffff}}) {
        code:=invite_encode(invitation,context.temp_allocator)
        testing.expect_value(t,len(code),INVITE_CHARACTERS+INVITE_CHARACTERS/INVITE_GROUP-1)
        got,ok:=invite_decode(code)
        testing.expectf(t,ok && got==invitation,"%v gave %s, read as %v",invitation,code,got)
        // Lowercase, spaces and the letters that look like digits are the same code.
        loose,_:=strings.replace_all(strings.to_lower(code,context.temp_allocator),"-"," ",context.temp_allocator)
        loose,_=strings.replace_all(loose,"0","o",context.temp_allocator)
        loose,_=strings.replace_all(loose,"1","l",context.temp_allocator)
        got,ok=invite_decode(loose)
        testing.expect(t,ok && got==invitation)
        // Any character changed to any other, or two neighbors swapped, is no code.
        changed:=transmute([]u8)strings.clone(code,context.temp_allocator)
        for i in 0..<len(code) {
            if code[i]=='-' {continue}
            for c in transmute([]u8)string(INVITE_ALPHABET) {
                if c==code[i] {continue}
                changed[i]=c
                _,wrong:=invite_decode(string(changed))
                testing.expectf(t,!wrong,"%s read as a code",string(changed))
            }
            changed[i]=code[i]
            next:=i+1<len(code) && code[i+1]=='-'?i+2:i+1
            if next>=len(code) || code[next]==code[i] {continue}
            changed[i],changed[next]=code[next],code[i]
            _,swapped:=invite_decode(string(changed))
            testing.expectf(t,!swapped,"%s read as a code",string(changed))
            changed[i],changed[next]=code[i],code[next]
        }
        for text in ([]string{code[:len(code)-1],strings.concatenate({code,"0"},context.temp_allocator),""}) {
            _,wrong:=invite_decode(text)
            testing.expectf(t,!wrong,"%q read as a code",text)
        }
    }
    // The code of the previous format, of one address, is too short.
    _,old:=invite_decode("K7Q2-9XMA-PL3F-0B2C")
    testing.expect(t,!old)
    wide:=Address{kind=.IP6,port=7950,ip={0=0x20,1=0x01,15=1}}
    for invitation in ([]Invitation{{lan,public,0},{{},{},7},{wide,{},7},{lan,{kind=.IP4,ip={0=1,1=2,2=3,3=4}},7},{address_memory(1),{},7}}) {
        testing.expectf(t,invite_encode(invitation,context.temp_allocator)=="","%v makes a code",invitation)
    }
    for _ in 0..<64 {
        token,made:=invite_token()
        testing.expect(t,made && token!=0)
    }
}

// A transport that counts what its host sends to each address, by type.
@(private="file")
Answers :: struct {inner:Transport,sent:[6][Packet_Type]int,all:[Packet_Type]int,only:Address,response:[PACKET_BYTES]u8,response_size:int}
@(private="file")
answers_transport :: proc(a:^Answers) -> Transport {
    return {a,proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
        a:=(^Answers)(data)
        if len(bytes)>0 && bytes[0]==u8(Packet_Type.Response) {a.response_size=copy(a.response[:],bytes)}
        if to==a.only && len(bytes)>0 && bytes[0]<=u8(max(Packet_Type)) {a.all[Packet_Type(bytes[0])]+=1}
        if to.kind==.Memory && int(to.port)<len(a.sent) && len(bytes)>0 && bytes[0]<=u8(max(Packet_Type)) {a.sent[to.port][Packet_Type(bytes[0])]+=1}
        return a.inner.send(a.inner.data,to,bytes)
    },proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
        a:=(^Answers)(data)
        return a.inner.receive(a.inner.data,buffer)
    }}
}

// The invitation is in every key of the connection: a client without the
// right one hears only the challenge every request gets, and its proof is
// dropped without an answer. So is a made-up proof, and a response replayed
// from another address.
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

    // A forger returns a cookie it got at its own address with a proof it made up, whole or cut short: nothing comes back.
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
    dropped,invalid:=host_stats(server).handshakes_dropped,host_stats(server).packets_invalid
    state:=u64(5)
    for round in 0..<4 {
        buffer[0]=u8(Packet_Type.Response)
        serial.bit_writer_init(&writer,buffer[1:])
        serial.bit_write(&writer,salt,64)
        serial.bit_write(&writer,stamp,64)
        serial.bit_write(&writer,cookie,64)
        serial.bit_write(&writer,host_protocol_hash(server),64)
        for _ in 0..<KEY_BYTES+TAG_BYTES {serial.bit_write(&writer,base.splitmix_next(&state)&0xff,8)}
        datagram:=test_handshake(buffer[:],&writer,server.back.key,HANDSHAKE_BYTES)
        if round%2==1 {datagram=datagram[:40];checksum_write(datagram,server.back.key)}
        forger.send(forger.data,address_memory(0),datagram)
    }
    test_step(&w,2)
    host_poll(server)
    _,_,answered:=forger.receive(forger.data,answer[:])
    testing.expect(t,!answered)
    testing.expect_value(t,host_stats(server).handshakes_dropped,dropped+2)
    testing.expect_value(t,host_stats(server).packets_invalid,invalid+2)

    // Who brings it connects; its response, replayed from elsewhere, is dropped and connects no one.
    captured:=Answers{inner=invited.desc.transport}
    invited.desc.transport=answers_transport(&captured)
    on_server,on_client:=test_connect(&w,server,invited)
    testing.expect(t,on_server!=0 && on_client!=0 && captured.response_size==HANDSHAKE_BYTES)
    dropped=host_stats(server).handshakes_dropped
    forger.send(forger.data,address_memory(0),captured.response[:captured.response_size])
    test_step(&w,2)
    for command in host_poll(server) {testing.expect(t,command.kind!=.Connected)}
    _,_,answered=forger.receive(forger.data,answer[:])
    testing.expect(t,!answered)
    testing.expect_value(t,host_stats(server).handshakes_dropped,dropped+1)
    testing.expect_value(t,host_stats(server).connections,1)
    testing.expect_value(t,host_stats(server).handshakes_refused,u64(0))
}

// The same over real UDP sockets on loopback, joining by the code: it connects
// at the address of the host on its network, and when that one does not answer,
// at the one its router mapped; a wrong invitation and none hear only the challenge.
@(test)
a_code_over_udp_reaches_the_host_at_either_of_its_addresses :: proc(t:^testing.T) {
    server_socket:Udp
    if !udp_open(&server_socket,address_loopback(0)) {testing.expect(t,false,"cannot bind a UDP socket on 127.0.0.1");return}
    defer udp_close(&server_socket)
    answers:=Answers{inner=udp_transport(&server_socket)}
    server:=new(Host)
    defer free(server)
    if !testing.expect_value(t,host_init(server,{mode=.Server,transport=answers_transport(&answers),channels={{kind=.Reliable}},invite=0x2b3c4d5e,protocol_id=91}),Error.None) {return}
    defer host_destroy(server)
    attempt :: proc(t:^testing.T,server:^Host,answers:^Answers,invitation:Invitation) -> (reason:Disconnect_Reason,at:Address,delivered:bool) {
        joined,read:=invite_decode(invite_encode(invitation,context.temp_allocator))
        if !testing.expect(t,read) {return}
        client_socket:Udp
        if !udp_open(&client_socket,address_ip4(0,0,0,0,0)) {testing.expect(t,false,"cannot bind a UDP socket");return}
        defer udp_close(&client_socket)
        client:=new(Host)
        defer free(client)
        if !testing.expect_value(t,host_init(client,{mode=.Client,transport=udp_transport(&client_socket),channels={{kind=.Reliable}},invite=joined.token,protocol_id=91,connect_timeout=1}),Error.None) {return}
        defer host_destroy(client)
        answers.all,answers.only={},address_loopback(int(client_socket.address.port))
        host_connect(client,joined.lan,joined.public)
        reason=.Timeout
        start:=host_time(server)
        for host_time(server)-start<3 && !delivered {
            now:=host_time(server)
            host_update(client,now);host_update(server,now)
            for command in host_poll(server) {
                if command.kind==.Message {delivered=true}
            }
            for command in host_poll(client) {
                if command.kind==.Connected {reason,at=.None,client.back.peers[0].address;message_send(client,command.connection,0,{1,2,3})}
                if command.kind==.Disconnected {return command.reason,{},false}
            }
            time.sleep(time.Millisecond)
        }
        return
    }
    port:=int(server_socket.address.port)
    here,unreachable:=address_loopback(port),address_ip4(192,0,2,1,port) // a documentation address
    for invitation in ([2]Invitation{{here,unreachable,0x2b3c4d5e},{unreachable,here,0x2b3c4d5e}}) {
        reason,at,delivered:=attempt(t,server,&answers,invitation)
        testing.expectf(t,reason==.None && at==here && delivered,"%v: %v at %v, a message delivered: %v",invitation,reason,at,delivered)
    }
    for token in ([2]u32{0x2b3c4d5f,1}) {
        reason,_,_:=attempt(t,server,&answers,{here,{},token})
        testing.expect_value(t,reason,Disconnect_Reason.Connect_Timeout)
        testing.expectf(t,answers.all[.Challenge]>0 && answers.all[.Accepted]==0 && answers.all[.Denied]==0 && answers.all[.Data]==0,"invitation %x: the server answered %v",token,answers.all)
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
    invitation:=invite_make(7,27500)
    testing.expect(t,invitation.lan==lan && invitation.public.kind==.None && invitation.token==7)
}
