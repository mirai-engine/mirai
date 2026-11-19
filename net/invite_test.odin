package mirai_net

import "core:log"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/base"

@(private="file")
INVITE_CHANNELS :: []Channel_Desc{{kind=.Reliable,queue_bytes=64<<10},{kind=.Unreliable}}

// The X25519 keys of small order (and their encodings past the prime), which leave nothing secret.
@(private)
TEST_SMALL_ORDER :: [?]Key{
    {},
    {0=1},
    {0xe0,0xeb,0x7a,0x7c,0x3b,0x41,0xb8,0xae,0x16,0x56,0xe3,0xfa,0xf1,0x9f,0xc4,0x6a,0xda,0x09,0x8d,0xeb,0x9c,0x32,0xb1,0xfd,0x86,0x62,0x05,0x16,0x5f,0x49,0xb8,0x00},
    {0x5f,0x9c,0x95,0xbc,0xa3,0x50,0x8c,0x24,0xb1,0xd0,0xb1,0x55,0x9c,0x83,0xef,0x5b,0x04,0x44,0x5c,0xc4,0x58,0x1c,0x8e,0x86,0xd8,0x22,0x4e,0xdd,0xd0,0x9f,0x11,0x57},
    {0=0xec,1..<31=0xff,31=0x7f},
    {0=0xed,1..<31=0xff,31=0x7f},
    {0=0xee,1..<31=0xff,31=0x7f},
}

// The characters of a code of any version and contents, without dashes.
@(private="file")
code_of :: proc(version:u64,invitation:Invitation) -> string {
    invitation:=invitation
    alphabet:=INVITE_ALPHABET
    bits:[(INVITE_DATA_BITS+INVITE_CHECK_BITS+7)/8]u8
    at:=0
    invite_put(bits[:],&at,version,INVITE_VERSION_BITS)
    for address in ([2]Address{invitation.lan,invitation.public}) {
        address:=address
        for b in address.ip[:4] {invite_put(bits[:],&at,u64(b),8)}
        invite_put(bits[:],&at,u64(address.port),16)
    }
    for b in invitation.key.public[:31] {invite_put(bits[:],&at,u64(b),8)}
    invite_put(bits[:],&at,u64(invitation.key.public[31]),7)
    invite_put(bits[:],&at,invitation.key.secret,64)
    invite_put(bits[:],&at,u64(invite_check(bits[:],INVITE_DATA_BITS)),INVITE_CHECK_BITS)
    text:=make([]u8,INVITE_CHARACTERS,context.temp_allocator)
    at=0
    for &c in text {c=alphabet[invite_get(bits[:],&at,5)]}
    return string(text)
}

@(test)
invitation_codes_round_trip_and_refuse_typos_old_codes_and_bad_keys :: proc(t:^testing.T) {
    lan,public:=address_ip4(192,168,1,20,27500),address_ip4(203,0,113,7,41000)
    key:=test_invited(test_key(0xa1b2c3d4e5f60718))
    for invitation in ([]Invitation{{lan,public,key},{lan,{},{public=key.public,secret=1}},{{},public,{public=key.public,secret=max(u64)}}}) {
        code:=invite_encode(invitation,context.temp_allocator)
        testing.expect_value(t,len(code),INVITE_CHARACTERS+(INVITE_CHARACTERS-1)/INVITE_GROUP)
        got,error:=invite_decode(code)
        testing.expectf(t,error==.None && got==invitation,"%v gave %s, read as %v (%v)",invitation,code,got,error)
        // Lowercase, spaces and the letters that look like digits are the same code.
        loose,_:=strings.replace_all(strings.to_lower(code,context.temp_allocator),"-"," ",context.temp_allocator)
        loose,_=strings.replace_all(loose,"0","o",context.temp_allocator)
        loose,_=strings.replace_all(loose,"1","l",context.temp_allocator)
        got,error=invite_decode(loose)
        testing.expect(t,error==.None && got==invitation)
        // Any character changed to any other, or two neighbors swapped, is no code.
        changed:=transmute([]u8)strings.clone(code,context.temp_allocator)
        for i in 0..<len(code) {
            if code[i]=='-' {continue}
            for c in transmute([]u8)string(INVITE_ALPHABET) {
                if c==code[i] {continue}
                changed[i]=c
                _,wrong:=invite_decode(string(changed))
                testing.expectf(t,wrong==.Check,"%s read as %v",string(changed),wrong)
            }
            changed[i]=code[i]
            next:=i+1<len(code) && code[i+1]=='-'?i+2:i+1
            if next>=len(code) || code[next]==code[i] {continue}
            changed[i],changed[next]=code[next],code[i]
            _,swapped:=invite_decode(string(changed))
            testing.expectf(t,swapped==.Check,"%s read as %v",string(changed),swapped)
            changed[i],changed[next]=code[i],code[next]
        }
        for text in ([]string{code[:len(code)-1],strings.concatenate({code,"0"},context.temp_allocator),""}) {
            _,wrong:=invite_decode(text)
            testing.expectf(t,wrong==.Length,"%q read as %v",text,wrong)
        }
    }
    // A code of the earlier format, without the key, and one of another layout say so.
    _,old:=invite_decode("R2M0-253B-DK5G-0W87-M0MA-3CP3-TKJZ-C1RR-EJT")
    testing.expect_value(t,old,Invite_Error.Old)
    _,other:=invite_decode(code_of(INVITE_VERSION+1,{lan,public,key}))
    testing.expect_value(t,other,Invite_Error.Version)
    _,odd:=invite_decode("R2M0-253B-DK5G-0W87-M0MA-3CP3-TKJZ-C1RR-EJT#")
    testing.expect_value(t,odd,Invite_Error.Character)
    // A key of small order, a zero secret or no address is no invitation, written or read.
    smalls:=TEST_SMALL_ORDER
    for small in smalls {
        bad:=Invitation{lan,public,{public=small,secret=7}}
        bad.key.public[31]&=0x7f
        testing.expectf(t,!key_usable(&bad.key.public),"%v is usable",small)
        testing.expect(t,invite_encode(bad,context.temp_allocator)=="")
        _,refused:=invite_decode(code_of(INVITE_VERSION,bad))
        testing.expectf(t,refused==.Invalid,"a code with the key %v read as %v",small,refused)
    }
    for bad in ([]Invitation{{lan,public,{public=key.public}},{{},{},key}}) {
        _,refused:=invite_decode(code_of(INVITE_VERSION,bad))
        testing.expect_value(t,refused,Invite_Error.Invalid)
    }
    wide:=Address{kind=.IP6,port=7950,ip={0=0x20,1=0x01,15=1}}
    for invitation in ([]Invitation{{lan,public,{public=key.public}},{{},{},key},{wide,{},key},{lan,{kind=.IP4,ip={0=1,1=2,2=3,3=4}},key},{address_memory(1),{},key}}) {
        testing.expectf(t,invite_encode(invitation,context.temp_allocator)=="","%v makes a code",invitation)
    }
    // Random text of the right length and alphabet is refused or read, never more.
    state:=u64(17)
    for _ in 0..<2000 {
        text:=make([]u8,INVITE_CHARACTERS,context.temp_allocator)
        alphabet:=INVITE_ALPHABET
        for &c in text {c=alphabet[base.splitmix_next(&state)%32]}
        if got,error:=invite_decode(string(text));error==.None {testing.expect(t,got.key.secret!=0 && key_usable(&got.key.public))}
    }
    for error in Invite_Error {testing.expect(t,(error==.None)==(invite_error_text(error)==""))}
    // Every key is new, and a host refuses the key of a share made otherwise.
    previous:Invite_Key
    for _ in 0..<64 {
        made,ok:=invite_key()
        testing.expect(t,ok && made.secret!=0 && key_usable(&made.public) && made!=previous && made==invite_key_from(&made.private,made.secret))
        previous=made
    }
    w:Test_World;test_world_init(&w,1);defer test_world_destroy(&w)
    h:=new(Host);defer free(h)
    for refused in ([]struct{desc:Host_Desc,field:string}{
        {{mode=.Client,invite={public=TEST_SMALL_ORDER[2],secret=1}},"invite.public"},
        {{mode=.Client,invite={public=key.public}},"invite.secret"},
        {{mode=.Server,invite=key},"invite"},
    }) {
        desc:=refused.desc
        desc.transport=sim_endpoint_transport(&w.sim,0)
        testing.expect_value(t,host_init(h,desc),Error.Invalid)
        testing.expect_value(t,h.refused.field,refused.field)
    }
}

// A transport that counts the datagrams and bytes its host sends to each address, by type, and keeps
// the first Initiate.
@(private="file")
Answers :: struct {
    inner:Transport,
    sent:[8][Packet_Type]int,
    bytes:[8]int,
    only:Address,          // what all counts
    all:int,
    swallow:bool,          // nothing reaches the network
    initiate:[PACKET_BYTES]u8,
    initiate_size:int,
}
@(private="file")
answers_transport :: proc(a:^Answers) -> Transport {
    return {data=a,send=proc(data:rawptr,batch:[]Datagram) -> int {return test_send_each(data,batch,proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
        a:=(^Answers)(data)
        if len(bytes)>0 && bytes[0]==u8(Packet_Type.Initiate) && a.initiate_size==0 {a.initiate_size=copy(a.initiate[:],bytes)}
        if to.kind==.Memory && int(to.port)<len(a.sent) && len(bytes)>0 && bytes[0]<=u8(max(Packet_Type)) {
            a.sent[to.port][Packet_Type(bytes[0])]+=1
            a.bytes[to.port]+=len(bytes)
        }
        if to==a.only {a.all+=1}
        return a.swallow || test_send_one(a.inner,to,bytes)
    })},receive=proc(data:rawptr,batch:[]Datagram) -> int {return test_receive_each(data,batch,proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
        a:=(^Answers)(data)
        return test_receive_one(a.inner,buffer)
    })}}
}
@(private="file")
answers_total :: proc(a:^Answers,to:int) -> (count:int) {
    for n in a.sent[to] {count+=n}
    return
}

// Round trips before the first byte of the game reaches the server. With an
// invitation the first datagram carries it, half a round trip after the
// client connects: none before it. Without one, after a Hello and its Key:
// one. The handshake before took two (a request and its challenge, a proof and
// its acceptance) before the client could send anything.
@(test)
the_first_datagram_carries_data_that_arrives_before_any_answer :: proc(t:^testing.T) {
    LATENCY :: 0.05
    for invited in ([2]bool{true,false}) {
        w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
        for endpoint in 0..<2 {sim_endpoint_conditions(&w.sim,endpoint,{latency=LATENCY})}
        key:=test_key(9)
        server:=test_host(&w,{mode=.Server,channels=INVITE_CHANNELS,invite=invited?key:{}})
        client:=test_host(&w,{mode=.Client,channels=INVITE_CHANNELS,invite=invited?test_invited(key):{}})
        answers:=Answers{inner=server.desc.transport}
        server.desc.transport=answers_transport(&answers)
        testing.expect_value(t,host_connect(client,address_memory(0)),Error.None)
        testing.expect_value(t,message_send(client,0,0,{'h','i'}),Error.None)
        testing.expect_value(t,message_send(client,0,1,{'u'}),Error.None)
        started:=w.now
        arrived:=-1.0
        reliable,unreliable,before:=0,0,0
        on_server:Connection
        for _ in 0..<120 {
            // What the server had sent the client before the update in which the data reached it.
            answered:=answers.sent[1][.Key]+answers.sent[1][.Response]
            test_step(&w)
            for command in host_poll(server) {
                #partial switch command.kind {
                case .Connected: on_server=command.connection
                case .Message:
                    testing.expect(t,command.connection==on_server)
                    if string(command.data)=="hi" {reliable+=1}
                    if string(command.data)=="u" {unreliable+=1}
                    if arrived<0 {arrived,before=w.now-started,answered}
                }
            }
            host_poll(client)
        }
        log.infof("invited %v: the first byte arrived after %.3f s at %.0f ms each way, %d answers before it",invited,arrived,LATENCY*1000,before)
        testing.expectf(t,reliable==1 && unreliable==1,"invited %v: %d reliable and %d unreliable arrived",invited,reliable,unreliable)
        if invited {
            testing.expectf(t,arrived>0 && arrived<2*LATENCY && before==0,"with an invitation it arrived after %.3f s, %d answers before",arrived,before)
        } else {
            testing.expectf(t,arrived>3*LATENCY-TEST_STEP && arrived<5*LATENCY && before==1,"without one it arrived after %.3f s, %d answers before",arrived,before)
        }
    }
}

// The invitation is in every key: a client without the right one, or with
// none, hears nothing at all from a host that has one, and its Initiates cost
// the host one key exchange each within the allowance of its address.
@(test)
a_server_with_an_invitation_answers_only_who_brings_it :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,5);defer test_world_destroy(&w)
    key:=test_key(0x123456)
    server:=test_host(&w,{mode=.Server,invite=key})
    answers:=Answers{inner=server.desc.transport}
    server.desc.transport=answers_transport(&answers)
    other_secret:=test_invited(key)
    other_secret.secret+=1
    none:=test_host(&w,{mode=.Client,connect_timeout=1})
    other:=test_host(&w,{mode=.Client,invite=other_secret,connect_timeout=1})
    stranger:=test_host(&w,{mode=.Client,invite=test_invited(test_key(0x654321)),connect_timeout=1})
    for client,i in ([3]^Host{none,other,stranger}) {
        host_connect(client,address_memory(0))
        message_send(client,0,0,{1})
        reason:Disconnect_Reason
        for _ in 0..<120 {
            test_step(&w)
            for command in host_poll(client) {
                if command.kind==.Disconnected {reason=command.reason}
                testing.expect(t,command.kind!=.Connected)
            }
            for command in host_poll(server) {testing.expect(t,command.kind!=.Connected && command.kind!=.Message)}
            if reason!=.None {break}
        }
        testing.expect_value(t,reason,Disconnect_Reason.Connect_Timeout)
        testing.expectf(t,answers_total(&answers,1+i)==0,"the server answered %v",answers.sent[1+i])
    }
    stats:=host_stats(server)
    testing.expect(t,stats.handshakes_dropped>=3 && stats.handshakes_refused==0 && stats.connections==0)
    for peer in server.back.peers {testing.expect_value(t,peer.state,Peer_State.Free)}
}

// A replayed Initiate opens nothing: not while its connection lives, from its
// address or another, nor after it ended; it costs no key exchange and hears at
// most a Retry, smaller than it. The game hears of the connection and of what
// its first datagram carried once.
@(test)
a_replayed_initiate_makes_no_second_connection_and_delivers_nothing_again :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,3);defer test_world_destroy(&w)
    key:=test_key(5)
    server:=test_host(&w,{mode=.Server,channels=INVITE_CHANNELS,invite=key})
    client:=test_host(&w,{mode=.Client,channels=INVITE_CHANNELS,invite=test_invited(key)})
    kept:=Answers{inner=client.desc.transport}
    client.desc.transport=answers_transport(&kept)
    forger:=sim_endpoint_transport(&w.sim,2)
    connected,early,ended:=0,0,0
    watch :: proc(server:^Host,connected,early,ended:^int) {
        for command in host_poll(server) {
            #partial switch command.kind {
            case .Connected:    connected^+=1
            case .Message:      if string(command.data)=="early" {early^+=1}
            case .Disconnected: ended^+=1
            }
        }
    }
    host_connect(client,address_memory(0))
    message_send(client,0,0,transmute([]u8)string("early"))
    on_client:Connection
    for _ in 0..<60 {
        test_step(&w)
        watch(server,&connected,&early,&ended)
        for command in host_poll(client) {if command.kind==.Connected {on_client=command.connection}}
    }
    testing.expect(t,on_client!=0 && connected==1 && early==1 && kept.initiate_size>=HANDSHAKE_BYTES)
    replay :: proc(w:^Test_World,server:^Host,forger:Transport,kept:^Answers) {
        buffer:[PACKET_BYTES]u8
        test_send_one(forger,address_memory(0),kept.initiate[:kept.initiate_size])
        copy(buffer[:],kept.initiate[:kept.initiate_size])
        packet_receive(server,buffer[:kept.initiate_size],address_memory(1))
        test_step(w,2)
    }
    exchanges:=server.back.secure.exchanges
    replay(&w,server,forger,&kept)
    watch(server,&connected,&early,&ended)
    testing.expect(t,connected==1 && early==1 && ended==0 && host_stats(server).connections==1)
    testing.expect_value(t,server.back.secure.exchanges,exchanges)
    host_disconnect(client)
    test_step(&w,4)
    watch(server,&connected,&early,&ended)
    testing.expect(t,ended==1 && host_stats(server).connections==0)
    replay(&w,server,forger,&kept)
    test_step(&w,60)
    watch(server,&connected,&early,&ended)
    testing.expectf(t,connected==1 && early==1 && ended==1,"%d connections, %d early messages, %d ends",connected,early,ended)
    for peer in server.back.peers {testing.expect_value(t,peer.state,Peer_State.Free)}
    answer:[PACKET_BYTES]u8
    for {
        size,_,answered:=test_receive_one(forger,answer[:])
        if !answered {break}
        testing.expect(t,Packet_Type(answer[0])==.Retry && size<kept.initiate_size)
    }
    testing.expect_value(t,server.back.secure.exchanges,exchanges)
}

// Until a datagram under the keys of the connection comes from an address, the
// server sends it no more than it received from it: one Response for each copy
// of the Initiate, nothing of what the game queues and no Disconnect when it
// gives up. Without an invitation a Hello gets a smaller Key, and an Initiate
// whose cookie is not of its address gets nothing.
@(test)
an_unconfirmed_address_never_hears_more_than_it_sent :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,4);defer test_world_destroy(&w)
    key:=test_key(11)
    server:=test_host(&w,{mode=.Server,channels=INVITE_CHANNELS,invite=key,connect_timeout=1})
    answers:=Answers{inner=server.desc.transport}
    server.desc.transport=answers_transport(&answers)
    // An Initiate that never reached the server from its client, sent from another address.
    client:=test_host(&w,{mode=.Client,channels=INVITE_CHANNELS,invite=test_invited(key)})
    kept:=Answers{inner=client.desc.transport,swallow=true}
    client.desc.transport=answers_transport(&kept)
    host_connect(client,address_memory(0))
    message_send(client,0,0,{9})
    test_step(&w)
    testing.expect(t,kept.initiate_size>=HANDSHAKE_BYTES)
    forger:=sim_endpoint_transport(&w.sim,2)
    on_server:Connection
    received:=0
    for copy in 0..<3 {
        test_send_one(forger,address_memory(0),kept.initiate[:kept.initiate_size])
        received+=kept.initiate_size
        test_step(&w,2)
        for command in host_poll(server) {
            if command.kind==.Connected {on_server=command.connection}
        }
        if on_server!=0 {message_send(server,on_server,0,make([]u8,600,context.temp_allocator))}
        testing.expectf(t,answers.sent[2][.Response]==copy+1 && answers.bytes[2]<=received,"copy %d: %v, %d bytes for %d",copy,answers.sent[2],answers.bytes[2],received)
    }
    // From another address the same Initiate gets a Retry at most.
    test_send_one(sim_endpoint_transport(&w.sim,3),address_memory(0),kept.initiate[:kept.initiate_size])
    gone:=false
    for _ in 0..<90 {
        test_step(&w)
        for command in host_poll(server) {gone||=command.kind==.Disconnected && command.connection==on_server && command.reason==.Connect_Timeout}
    }
    testing.expect(t,on_server!=0 && gone && host_stats(server).connections==0)
    testing.expectf(t,answers_total(&answers,2)==3 && answers.bytes[2]<=received && answers_total(&answers,3)==answers.sent[3][.Retry] && answers.bytes[3]<kept.initiate_size,"sent %v and %v",answers.sent[2],answers.sent[3])

    // Without an invitation.
    answer:[PACKET_BYTES]u8
    for {
        _,_,more:=test_receive_one(forger,answer[:])
        if !more {break}
    }
    open:=new(Host);defer free(open)
    if !testing.expect_value(t,host_init(open,{mode=.Server,transport=sim_endpoint_transport(&w.sim,3),protocol_id=77}),Error.None) {return}
    defer host_destroy(open)
    buffer:[PACKET_BYTES]u8
    buffer[0]=u8(Packet_Type.Hello)
    hello:=buffer[:HANDSHAKE_BYTES]
    checksum_write(hello,open.back.key)
    test_send_one(forger,address_memory(3),hello)
    test_send_one(forger,address_memory(3),hello[:HANDSHAKE_BYTES-1])
    for _ in 0..<2 {w.now+=TEST_STEP;sim_network_advance(&w.sim,w.now);host_update(open,w.now)}
    size,_,keyed:=test_receive_one(forger,answer[:])
    testing.expect(t,keyed && Packet_Type(answer[0])==.Key && size<HANDSHAKE_BYTES)
    _,_,again:=test_receive_one(forger,answer[:])
    testing.expect(t,!again)
    initiate:=kept.initiate
    initiate[21]~=1 // a stamp the server never gave
    checksum_write(initiate[:kept.initiate_size],open.back.key)
    test_send_one(forger,address_memory(3),initiate[:kept.initiate_size])
    for _ in 0..<2 {w.now+=TEST_STEP;sim_network_advance(&w.sim,w.now);host_update(open,w.now)}
    _,_,answered:=test_receive_one(forger,answer[:])
    testing.expect(t,!answered)
    for peer in open.back.peers {testing.expect_value(t,peer.state,Peer_State.Free)}
    testing.expect_value(t,len(host_poll(open)),0)
    testing.expect_value(t,host_stats(open).handshakes_dropped,u64(1))
}

// An Initiate of a sender that holds the key: header, a key e and a payload, sealed with what it makes up.
@(private="file")
forged_initiate :: proc(h:^Host,buffer:[]u8,salt:u64,state:^u64,e:^Key=nil,mac:=true) -> []u8 {
    buffer[0]=u8(Packet_Type.Initiate)
    for &b in buffer[1:INITIATE_HEADER] {b=0}
    for k in 0..<8 {buffer[1+k]=u8(salt>>(8*uint(k)))}
    for k in 0..<4 {buffer[9+k]=u8(h.desc.version>>(8*uint(k)))}
    hash:=host_protocol_hash(h)
    for k in 0..<8 {buffer[13+k]=u8(hash>>(8*uint(k)))}
    for &b in buffer[INITIATE_HEADER:HANDSHAKE_BYTES] {b=u8(base.splitmix_next(state))}
    if e!=nil {copy(buffer[INITIATE_HEADER:],e[:])}
    if mac {
        at:=HANDSHAKE_BYTES-CHECKSUM_BYTES-MAC_BYTES
        sum:=mac_of(&h.back.secure.mac,buffer[:at])
        copy(buffer[at:],sum[:])
    }
    checksum_write(buffer[:HANDSHAKE_BYTES],h.back.key)
    return buffer[:HANDSHAKE_BYTES]
}

// An Initiate without the MAC of the invitation costs no key exchange and gets
// no answer. One with it that does not open costs its address: 100,000 of them
// from 1,000 addresses get no answer and at most the burst and one per interval
// of key exchanges each, and nothing is kept per guess; who brings the
// invitation joins meanwhile as fast as with nobody guessing. Keys of small
// order, damaged Initiates and random bytes are refused the same, never more
// than the budget of an update at a time, and hear at most a Retry.
@(test)
wrong_initiates_cost_their_address_and_the_invited_join_meanwhile :: proc(t:^testing.T) {
    ADDRESSES :: 1000
    ROUNDS :: 100
    w:Test_World;test_world_init(&w,ADDRESSES+4);defer test_world_destroy(&w)
    key:=test_key(0x5eed5eed5eed5eed)
    server:=test_host(&w,{mode=.Server,invite=key,handshakes_per_update=1<<20})
    calm:=test_host(&w,{mode=.Client,invite=test_invited(key)})
    invited:=test_host(&w,{mode=.Client,invite=test_invited(key)})
    hostile:=test_host(&w,{mode=.Server,invite=key,handshakes_per_update=2})
    join_steps :: proc(w:^Test_World,server,client:^Host,forge:proc(w:^Test_World,round:int)=nil) -> (steps:int) {
        host_connect(client,address_memory(0))
        for steps=1;steps<300;steps+=1 {
            if forge!=nil {forge(w,steps)}
            test_step(w)
            host_poll(server)
            for command in host_poll(client) {
                if command.kind==.Connected {return}
            }
        }
        return
    }
    calm_steps:=join_steps(&w,server,calm)
    Attack :: struct {server:^Host,state:u64,mac:bool}
    attack:=Attack{server,7,false}
    context.user_ptr=&attack
    forge :: proc(w:^Test_World,round:int) {
        a:=(^Attack)(context.user_ptr)
        buffer:[PACKET_BYTES]u8
        for i in 0..<ADDRESSES {
            test_send_one(sim_endpoint_transport(&w.sim,4+i),address_memory(0),forged_initiate(a.server,buffer[:],u64(0x10000+i),&a.state,mac=a.mac))
        }
    }
    strangers:=server.back.secure.exchanges
    for round in 0..<5 {
        forge(&w,round)
        test_step(&w)
        host_poll(server)
    }
    testing.expect_value(t,server.back.secure.exchanges,strangers)
    attack.mac=true
    before:=host_stats(server)
    before_exchanges:=server.back.secure.exchanges
    for round in 0..<ROUNDS/2 {
        forge(&w,round)
        test_step(&w)
        host_poll(server)
    }
    invited_steps:=join_steps(&w,server,invited,forge)
    for round in ROUNDS/2+invited_steps..<ROUNDS {
        forge(&w,round)
        test_step(&w)
        host_poll(server)
    }
    test_step(&w)
    host_poll(server)
    after:=host_stats(server)
    // The invited one's Initiate is the only one that opened.
    exchanged,put_off:=server.back.secure.exchanges-before_exchanges-1,after.handshakes_deferred-before.handshakes_deferred
    elapsed:=f64(ROUNDS+1)*TEST_STEP
    budget:=u64(ADDRESSES*(FAILED_BURST+int(elapsed/FAILED_INTERVAL)+1))
    testing.expectf(t,exchanged+put_off==ADDRESSES*ROUNDS,"%d exchanged and %d put off of %d",exchanged,put_off,ADDRESSES*ROUNDS)
    testing.expectf(t,exchanged<=budget,"%d key exchanges for wrong Initiates, more than %d",exchanged,budget)
    testing.expect_value(t,after.handshakes_refused,u64(0))
    answer:[PACKET_BYTES]u8
    for i in 0..<ADDRESSES {
        _,_,answered:=test_receive_one(sim_endpoint_transport(&w.sim,4+i),answer[:])
        if !testing.expectf(t,!answered,"forger %d heard an answer",i) {break}
    }
    testing.expectf(t,calm_steps<300 && invited_steps<=calm_steps+1,"the invited joined in %d steps, with nobody guessing in %d",invited_steps,calm_steps)
    testing.expect_value(t,after.connections,2)

    // Within the budget of an update: keys of small order, cut short, damaged and random.
    forger:=sim_endpoint_transport(&w.sim,4)
    state:=u64(23)
    buffer:[PACKET_BYTES]u8
    for round in 0..<40 {
        start:=hostile.back.secure.exchanges
        sent:=0
        smalls:=TEST_SMALL_ORDER
        for &small in smalls {
            test_send_one(forger,address_memory(3),forged_initiate(hostile,buffer[:],u64(round),&state,&small))
            test_send_one(forger,address_memory(3),forged_initiate(hostile,buffer[:],u64(round),&state))
            datagram:=forged_initiate(hostile,buffer[:],u64(round),&state)
            cut:=datagram[:INITIATE_HEADER+int(base.splitmix_next(&state)%u64(HANDSHAKE_BYTES-INITIATE_HEADER))]
            checksum_write(cut,hostile.back.key)
            test_send_one(forger,address_memory(3),cut)
            sent+=1
        }
        for &b in buffer {b=u8(base.splitmix_next(&state))}
        buffer[0]=u8(Packet_Type.Initiate)
        test_send_one(forger,address_memory(3),buffer[:])
        test_step(&w)
        host_poll(hostile)
        spent:=hostile.back.secure.exchanges-start
        testing.expectf(t,spent<=2,"round %d: %d key exchanges in an update of 2",round,spent)
    }
    testing.expect_value(t,host_stats(hostile).connections,0)
    testing.expect_value(t,host_stats(hostile).handshakes_refused,u64(0))
    for peer in hostile.back.peers {testing.expect_value(t,peer.state,Peer_State.Free)}
    for {
        _,_,answered:=test_receive_one(forger,answer[:])
        if !answered {break}
        testing.expectf(t,Packet_Type(answer[0])==.Retry,"a hostile Initiate got %v",Packet_Type(answer[0]))
    }
}

// Every invited peer that connects at once is a connection of its own, which
// takes its own first datagram and hears only what is sent to it.
@(test)
a_host_tells_its_invited_peers_apart :: proc(t:^testing.T) {
    PEERS :: 8
    w:Test_World;test_world_init(&w,PEERS+1);defer test_world_destroy(&w)
    key:=test_key(31)
    server:=test_host(&w,{mode=.Server,channels=INVITE_CHANNELS,invite=key,max_connections=PEERS})
    clients:[PEERS]^Host
    for &client,i in clients {
        client=test_host(&w,{mode=.Client,channels=INVITE_CHANNELS,invite=test_invited(key)})
        host_connect(client,address_memory(0))
        message_send(client,0,0,{u8(i)})
    }
    first:[PEERS]Connection
    heard:[PEERS]int
    for _ in 0..<60 {
        test_step(&w)
        for command in host_poll(server) {
            if command.kind!=.Message {continue}
            p:=peer_from(server,command.connection)
            if !testing.expect(t,p!=nil && len(command.data)==1) {continue}
            i:=int(command.data[0])
            testing.expectf(t,i<PEERS && p.address==address_memory(1+i) && first[i]==0,"the first datagram of %d came on the connection of %v",i,p.address)
            first[i]=command.connection
            message_send(server,command.connection,0,{u8(i)})
        }
        for client,i in clients {
            for command in host_poll(client) {
                if command.kind!=.Message {continue}
                testing.expect(t,len(command.data)==1 && int(command.data[0])==i)
                heard[i]+=1
            }
        }
    }
    for i in 0..<PEERS {testing.expectf(t,first[i]!=0 && heard[i]==1,"peer %d: connection %v, heard %d",i,first[i],heard[i])}
    testing.expect_value(t,host_stats(server).connections,PEERS)
}

// The same over real UDP sockets on loopback, joining by the code: it connects
// at the address of the host on its network, and when that one does not answer,
// at the one its router mapped; a wrong invitation and none hear nothing.
@(test)
a_code_over_udp_reaches_the_host_at_either_of_its_addresses :: proc(t:^testing.T) {
    server_socket:Udp
    if !udp_open(&server_socket,address_loopback(0)) {testing.expect(t,false,"cannot bind a UDP socket on 127.0.0.1");return}
    defer udp_close(&server_socket)
    answers:=Answers{inner=udp_transport(&server_socket)}
    server:=new(Host)
    defer free(server)
    key:=test_key(0x2b3c4d5e)
    if !testing.expect_value(t,host_init(server,{mode=.Server,transport=answers_transport(&answers),channels={{kind=.Reliable}},invite=key,protocol_id=91}),Error.None) {return}
    defer host_destroy(server)
    attempt :: proc(t:^testing.T,server:^Host,answers:^Answers,invitation:Invitation) -> (reason:Disconnect_Reason,at:Address,delivered:bool) {
        joined,error:=invite_decode(invite_encode(invitation,context.temp_allocator))
        if !testing.expect_value(t,error,Invite_Error.None) {return}
        client_socket:Udp
        if !udp_open(&client_socket,address_ip4(0,0,0,0,0)) {testing.expect(t,false,"cannot bind a UDP socket");return}
        defer udp_close(&client_socket)
        client:=new(Host)
        defer free(client)
        if !testing.expect_value(t,host_init(client,{mode=.Client,transport=udp_transport(&client_socket),channels={{kind=.Reliable}},invite=joined.key,protocol_id=91,connect_timeout=1}),Error.None) {return}
        defer host_destroy(client)
        answers.all,answers.only=0,address_loopback(int(client_socket.address.port))
        host_connect(client,joined.lan,joined.public)
        message_send(client,0,0,{1,2,3})
        reason=.Timeout
        start:=host_time(server)
        for host_time(server)-start<3 && !(delivered && reason==.None) {
            now:=host_time(server)
            host_update(client,now);host_update(server,now)
            for command in host_poll(server) {
                if command.kind==.Message {delivered=true}
            }
            for command in host_poll(client) {
                if command.kind==.Connected {reason,at=.None,client.back.peers[0].address}
                if command.kind==.Disconnected {return command.reason,{},false}
            }
            time.sleep(time.Millisecond)
        }
        return
    }
    port:=int(server_socket.address.port)
    here,unreachable:=address_loopback(port),address_ip4(192,0,2,1,port) // a documentation address
    invited:=test_invited(key)
    for invitation in ([2]Invitation{{here,unreachable,invited},{unreachable,here,invited}}) {
        reason,at,delivered:=attempt(t,server,&answers,invitation)
        testing.expectf(t,at==here && delivered,"%v: %v at %v, a message delivered: %v",invitation,reason,at,delivered)
    }
    other_secret,other_key:=invited,test_invited(test_key(0x2b3c4d5f))
    other_secret.secret+=1
    for wrong in ([2]Invite_Key{other_secret,other_key}) {
        reason,_,delivered:=attempt(t,server,&answers,{here,{},wrong})
        testing.expect(t,reason==.Connect_Timeout && !delivered)
        testing.expectf(t,answers.all==0,"a wrong invitation was answered %d times",answers.all)
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
    key:=test_key(7)
    invitation:=invite_make(key,27500)
    testing.expect(t,invitation.lan==lan && invitation.public.kind==.None && invitation.key==test_invited(key))
}

// An Initiate the server opened and then refused for want of room is never
// taken later: replayed once a slot frees, it makes no connection.
@(test)
an_initiate_refused_for_room_is_never_taken_later :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,4);defer test_world_destroy(&w)
    key:=test_key(41)
    server:=test_host(&w,{mode=.Server,channels=INVITE_CHANNELS,invite=key,max_connections=1})
    first:=test_host(&w,{mode=.Client,channels=INVITE_CHANNELS,invite=test_invited(key)})
    second:=test_host(&w,{mode=.Client,channels=INVITE_CHANNELS,invite=test_invited(key)})
    kept:=Answers{inner=second.desc.transport}
    second.desc.transport=answers_transport(&kept)
    on_server,_:=test_connect(&w,server,first)
    testing.expect(t,on_server!=0)
    host_connect(second,address_memory(0))
    message_send(second,0,0,{7})
    refused:Disconnect_Reason
    for _ in 0..<60 {
        test_step(&w)
        host_poll(server)
        for command in host_poll(second) {if command.kind==.Disconnected {refused=command.reason}}
        if refused!=.None {break}
    }
    testing.expect_value(t,refused,Disconnect_Reason.Denied_Full)
    host_disconnect(first)
    test_step(&w,4)
    host_poll(server)
    testing.expect_value(t,host_stats(server).connections,0)
    test_send_one(sim_endpoint_transport(&w.sim,3),address_memory(0),kept.initiate[:kept.initiate_size])
    for _ in 0..<10 {
        test_step(&w)
        for command in host_poll(server) {testing.expect(t,command.kind!=.Connected && command.kind!=.Message)}
    }
    testing.expect_value(t,host_stats(server).connections,0)
}

// The header of an Initiate with its MAC and checksum made again, as its sender would.
@(private="file")
initiate_reseal :: proc(h:^Host,datagram:[]u8,mac:bool) {
    at:=len(datagram)-CHECKSUM_BYTES-MAC_BYTES
    if mac {
        sum:=mac_of(&h.back.secure.mac,datagram[:at])
        copy(datagram[at:],sum[:])
    }
    checksum_write(datagram,h.back.key)
}

// A host with an invitation says nothing to whoever cannot prove it holds the
// invitation, not even that it is of another version: only an Initiate with the
// MAC of its key and secret hears Denied_Version.
@(test)
a_server_with_an_invitation_denies_only_who_proves_it_holds_it :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,invite=test_key(43),version=3})
    forger:=sim_endpoint_transport(&w.sim,1)
    state:=u64(9)
    buffer,answer:[PACKET_BYTES]u8
    for mac in ([2]bool{false,true}) {
        datagram:=forged_initiate(server,buffer[:],1,&state,mac=false)
        datagram[9]=2
        initiate_reseal(server,datagram,mac)
        test_send_one(forger,address_memory(0),datagram)
        test_step(&w,2)
        host_poll(server)
        size,_,answered:=test_receive_one(forger,answer[:])
        if mac {
            testing.expect(t,answered && Packet_Type(answer[0])==.Denied && size<len(datagram))
        } else {
            testing.expect(t,!answered)
        }
    }
    testing.expect_value(t,host_stats(server).handshakes_refused,u64(1))
    testing.expect_value(t,server.back.secure.exchanges,u64(0))
}

// Initiates of a holder of the invitation from hundreds of spoofed addresses
// take every key exchange of an update; the server then asks for a cookie,
// which spoofed senders never return, and the real client, which does, joins
// one round trip later instead of timing out.
@(test)
spoofed_initiates_leave_the_key_exchanges_to_a_client_that_returns_the_cookie :: proc(t:^testing.T) {
    SPOOFED :: 300
    w:Test_World;test_world_init(&w,SPOOFED+2);defer test_world_destroy(&w)
    key:=test_key(47)
    server:=test_host(&w,{mode=.Server,invite=key,handshakes_per_update=2})
    client:=test_host(&w,{mode=.Client,invite=test_invited(key),connect_timeout=3})
    answers:=Answers{inner=server.desc.transport}
    server.desc.transport=answers_transport(&answers)
    state:=u64(13)
    buffer:[PACKET_BYTES]u8
    host_connect(client,address_memory(0))
    joined,ended:=-1,false
    for step in 0..<120 {
        for i in 0..<SPOOFED {test_send_one(sim_endpoint_transport(&w.sim,2+i),address_memory(0),forged_initiate(server,buffer[:],u64(i),&state))}
        test_step(&w)
        host_poll(server)
        for command in host_poll(client) {
            if command.kind==.Connected {joined=step}
            if command.kind==.Disconnected {ended=true}
        }
        if joined>=0 || ended {break}
    }
    testing.expectf(t,joined>=0 && joined<20,"the client joined at step %d (ended: %v)",joined,ended)
    testing.expect(t,answers.sent[1][.Retry]>=1 && answers.bytes[1]<PACKET_BYTES)
}

// A full filter of Initiates, or one that holds a client's e by mistake, costs
// that client one round trip: it gets a Retry and joins with another e.
@(test)
a_full_filter_of_initiates_costs_a_round_trip_and_drops_no_one :: proc(t:^testing.T) {
    for full in ([2]bool{true,false}) {
        w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
        key:=test_key(53)
        server:=test_host(&w,{mode=.Server,invite=key})
        client:=test_host(&w,{mode=.Client,invite=test_invited(key)})
        answers:=Answers{inner=server.desc.transport}
        server.desc.transport=answers_transport(&answers)
        lasting:=&server.back.secure
        if full {lasting.seen_count[SEEN_LASTING]=SEEN_LIMIT} else {for &word in lasting.seen[SEEN_LASTING] {word=max(u64)}}
        on_server,on_client:=test_connect(&w,server,client,60)
        testing.expectf(t,on_server!=0 && on_client!=0 && answers.sent[1][.Retry]>=1,"full %v: joined %v, %v",full,on_client!=0,answers.sent[1])
    }
}
