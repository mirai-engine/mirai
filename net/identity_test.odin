package mirai_net

import "base:runtime"
import "core:encoding/endian"
import "core:testing"
import "mirai:std/base"

@(private="file")
IDENTITY_CHANNELS :: []Channel_Desc{{kind=.Reliable,queue_bytes=64<<10},{kind=.Unreliable}}
@(private="file")
CLAIM :: "org"

// The identities an authorize of a test admits, with what it says of each, for the claim CLAIM.
@(private="file")
Members :: struct {keys:[4]Key,verdicts:[4]Authorization,count:int,calls:int}
@(private="file")
members_authorize :: proc(m:^Members) -> Authorize {
    return {data=m,check=proc(data:rawptr,peer:Key,claim:[]u8) -> Authorization {
        m:=(^Members)(data)
        m.calls+=1
        for key,i in m.keys[:m.count] {
            if key==peer && string(claim)==CLAIM {return m.verdicts[i]}
        }
        return {}
    }}
}
@(private="file")
test_dh :: proc(n:u64) -> Dh_Key {
    private:Key
    state:=n
    for &b in private {b=u8(base.splitmix_next(&state))}
    return dh_key_from(&private)
}

// What a host sees of its connections in a run of steps.
@(private="file")
Seen :: struct {
    connected:[4]Connection,
    authorization:[4]Authorization,
    identity:[4]Key,
    connected_count:int,
    ended:[4]Connection,
    reasons:[4]Disconnect_Reason,
    ended_count:int,
    authorized:[dynamic;4]Authorization,
    early:int, // messages "early" that arrived
    early_before_connected:bool,
}
@(private="file")
seen_poll :: proc(h:^Host,s:^Seen) {
    for command in host_poll(h) {
        #partial switch command.kind {
        case .Connected:
            if s.connected_count<len(s.connected) {
                s.connected[s.connected_count],s.authorization[s.connected_count]=command.connection,command.authorization
                copy(s.identity[s.connected_count][:],command.data)
            }
            s.connected_count+=1
        case .Disconnected:
            if s.ended_count<len(s.ended) {s.ended[s.ended_count],s.reasons[s.ended_count]=command.connection,command.reason}
            s.ended_count+=1
        case .Authorized:
            append(&s.authorized,command.authorization)
        case .Message:
            if string(command.data)=="early" {
                s.early+=1
                if s.connected_count==0 {s.early_before_connected=true}
            }
        }
    }
}
@(private="file")
steps :: proc(w:^Test_World,count:int,hosts:[]^Host,seen:[]Seen) {
    for _ in 0..<count {
        test_step(w)
        for h,i in hosts {seen_poll(h,&seen[i])}
    }
}

// A server with an identity admits only what its authorize accepts, once the client proved it holds
// its keys: the game hears of the connection with its class and identity, then of what its first
// datagram carried. Who authorize refuses ends with Unauthorized and the game never hears of it; a
// second connection of an identity replaces the first; asked again after the membership changed,
// authorize revokes the connections it refuses now, at both ends.
@(test)
net_ik_authorize_and_revoke :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,5);defer test_world_destroy(&w)
    server_id,member,stranger:=test_dh(1),test_dh(2),test_dh(3)
    members:=Members{count=1}
    members.keys[0],members.verdicts[0]=member.public,{.Accept,.Member}
    server:=test_host(&w,{mode=.Server,channels=IDENTITY_CHANNELS,identity=server_id,authorize=members_authorize(&members)})
    first:=test_host(&w,{mode=.Client,channels=IDENTITY_CHANNELS,identity=member})
    other:=test_host(&w,{mode=.Client,channels=IDENTITY_CHANNELS,identity=stranger})
    again:=test_host(&w,{mode=.Client,channels=IDENTITY_CHANNELS,identity=member})
    if !testing.expect(t,server!=nil && first!=nil && other!=nil && again!=nil) {return}
    hosts:=[]^Host{server,first,other,again}
    seen:[4]Seen
    claim:=transmute([]u8)string(CLAIM)

    testing.expect_value(t,host_connect_identity(first,server_id.public,claim,address_memory(0)),Error.None)
    message_send(first,0,0,transmute([]u8)string("early"))
    steps(&w,30,hosts,seen[:])
    testing.expect(t,seen[0].connected_count==1 && seen[1].connected_count==1)
    testing.expect_value(t,seen[0].authorization[0],Authorization{.Accept,.Member})
    testing.expect(t,seen[0].identity[0]==member.public && seen[1].identity[0]==server_id.public)
    testing.expect(t,seen[0].early==1 && !seen[0].early_before_connected)
    testing.expect_value(t,members.calls,1)

    testing.expect_value(t,host_connect_identity(other,server_id.public,claim,address_memory(0)),Error.None)
    message_send(other,0,0,transmute([]u8)string("early"))
    steps(&w,30,hosts,seen[:])
    testing.expect(t,seen[2].ended_count==1 && seen[2].reasons[0]==.Unauthorized)
    testing.expect(t,seen[0].connected_count==1 && seen[0].ended_count==0 && seen[0].early==1)
    testing.expect_value(t,host_stats(server).connections,1)

    testing.expect_value(t,host_connect_identity(again,server_id.public,claim,address_memory(0)),Error.None)
    steps(&w,30,hosts,seen[:])
    testing.expect(t,seen[0].connected_count==2 && seen[0].ended_count==1 && seen[0].reasons[0]==.Replaced && seen[0].ended[0]==seen[0].connected[0])
    testing.expect(t,seen[1].ended_count==1 && seen[1].reasons[0]==.Replaced && seen[3].connected_count==1)

    members.count=0
    testing.expect_value(t,host_authorize(server),Error.None)
    steps(&w,10,hosts,seen[:])
    testing.expect(t,seen[0].ended_count==2 && seen[0].reasons[1]==.Revoked && seen[0].ended[1]==seen[0].connected[1])
    testing.expect(t,seen[3].ended_count==1 && seen[3].reasons[0]==.Revoked)
    testing.expect_value(t,host_stats(server).connections,0)
    for peer in server.back.peers {testing.expect_value(t,peer.state,Peer_State.Free)}

    // What a host with an identity is given is checked when it starts.
    refusals:=[]Host_Desc{
        {mode=.Server,identity=server_id},
        {mode=.Server,authorize=members_authorize(&members)},
        {mode=.Server,identity={private=server_id.private,public=member.public},authorize=members_authorize(&members)},
        {mode=.Client,identity=member,authorize=members_authorize(&members)},
    }
    for desc in refusals {testing.expect(t,test_host(&w,desc)==nil)}
    testing.expect_value(t,host_connect_identity(first,server_id.public,make([]u8,CLAIM_BYTES+1,context.temp_allocator),address_memory(0)),Error.Invalid)
    testing.expect_value(t,host_connect_identity(first,TEST_SMALL_ORDER[1],claim,address_memory(0)),Error.Invalid)
    testing.expect_value(t,host_authorize(first),Error.Invalid)
}

// A connection authorize leaves Pending reaches the game as Pending; asked again, an answer that
// changed comes as Authorized, one that did not comes as nothing, and the connection goes on.
@(test)
a_pending_identity_is_upgraded_to_accept_when_asked_again :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    server_id,member:=test_dh(4),test_dh(5)
    members:=Members{count=1}
    members.keys[0],members.verdicts[0]=member.public,{.Pending,.Node}
    server:=test_host(&w,{mode=.Server,channels=IDENTITY_CHANNELS,identity=server_id,authorize=members_authorize(&members)})
    client:=test_host(&w,{mode=.Client,channels=IDENTITY_CHANNELS,identity=member})
    hosts:=[]^Host{server,client}
    seen:[2]Seen
    host_connect_identity(client,server_id.public,transmute([]u8)string(CLAIM),address_memory(0))
    steps(&w,30,hosts,seen[:])
    if !testing.expect(t,seen[0].connected_count==1 && seen[1].connected_count==1) {return}
    testing.expect_value(t,seen[0].authorization[0],Authorization{.Pending,.Node})
    host_authorize(server,seen[0].connected[0])
    steps(&w,4,hosts,seen[:])
    testing.expect_value(t,len(seen[0].authorized),0)
    members.verdicts[0]={.Accept,.Node}
    host_authorize(server)
    steps(&w,4,hosts,seen[:])
    testing.expect(t,len(seen[0].authorized)==1 && seen[0].authorized[0]==Authorization{.Accept,.Node})
    message_send(client,seen[1].connected[0],0,transmute([]u8)string("early"))
    steps(&w,10,hosts,seen[:])
    testing.expect(t,seen[0].early==1 && seen[0].ended_count==0 && seen[1].ended_count==0)
}

// A transport that keeps the first Initiate_Identity its host sends.
@(private="file")
Kept_Initiate :: struct {inner:Transport,bytes:[PACKET_BYTES]u8,size:int}
@(private="file")
kept_initiate_transport :: proc(k:^Kept_Initiate) -> Transport {
    return {data=k,send=proc(data:rawptr,batch:[]Datagram) -> int {return test_send_each(data,batch,proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
        k:=(^Kept_Initiate)(data)
        if k.size==0 && bytes[0]==u8(Packet_Type.Initiate_Identity) {k.size=copy(k.bytes[:],bytes)}
        return test_send_one(k.inner,to,bytes)
    })},receive=proc(data:rawptr,batch:[]Datagram) -> int {return test_receive_each(data,batch,proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
        k:=(^Kept_Initiate)(data)
        return test_receive_one(k.inner,buffer)
    })}}
}

// An Initiate_Identity whose MAC is not keyed by the server's identity costs nothing and hears
// nothing. A copy of one that opened opens nothing while the server lives; once the server started
// again with the same identity, a copy opens and is answered, but without the client's keys it is
// never confirmed: authorize is not asked, the game hears nothing, and its slot frees.
@(test)
identity_initiates_with_a_bad_mac_or_replayed_reach_no_game :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,3);defer test_world_destroy(&w)
    server_id,member:=test_dh(6),test_dh(7)
    members:=Members{count=1}
    members.keys[0],members.verdicts[0]=member.public,{.Accept,.Member}
    desc:=Host_Desc{mode=.Server,channels=IDENTITY_CHANNELS,identity=server_id,authorize=members_authorize(&members),connect_timeout=1}
    server:=test_host(&w,desc)
    client:=test_host(&w,{mode=.Client,channels=IDENTITY_CHANNELS,identity=member})
    kept:=Kept_Initiate{inner=client.desc.transport}
    client.desc.transport=kept_initiate_transport(&kept)
    hosts:=[]^Host{server,client}
    seen:[2]Seen
    host_connect_identity(client,server_id.public,transmute([]u8)string(CLAIM),address_memory(0))
    message_send(client,0,0,transmute([]u8)string("early"))
    steps(&w,30,hosts,seen[:])
    if !testing.expect(t,seen[0].connected_count==1 && kept.size>=IDENTITY_INITIATE_BYTES) {return}
    buffer:[PACKET_BYTES]u8
    forged:=address_memory(2)
    exchanges,dropped:=server.back.secure.exchanges,server.back.stats.handshakes_dropped
    // Damaged MAC, and a MAC keyed by another identity.
    mac_at:=kept.size-CHECKSUM_BYTES-MAC_BYTES
    copy(buffer[:],kept.bytes[:kept.size])
    buffer[mac_at]~=1
    checksum_write(buffer[:kept.size],server.back.key)
    packet_receive(server,buffer[:kept.size],forged)
    copy(buffer[:],kept.bytes[:kept.size])
    other_key:=identity_mac_key(&member.public)
    mac:=mac_of(&other_key,buffer[:mac_at])
    copy(buffer[mac_at:],mac[:])
    checksum_write(buffer[:kept.size],server.back.key)
    packet_receive(server,buffer[:kept.size],forged)
    testing.expect_value(t,server.back.stats.handshakes_dropped,dropped+2)
    testing.expect_value(t,server.back.secure.exchanges,exchanges)
    // Replayed while the server lives, from the client's address and from another.
    for from in ([2]Address{address_memory(1),forged}) {
        copy(buffer[:],kept.bytes[:kept.size])
        packet_receive(server,buffer[:kept.size],from)
    }
    steps(&w,10,hosts,seen[:])
    testing.expect(t,seen[0].connected_count==1 && seen[0].early==1 && seen[0].ended_count==0 && members.calls==1)
    testing.expect_value(t,server.back.secure.exchanges,exchanges)

    // The server again, with the same identity and nothing remembered.
    w2:Test_World;test_world_init(&w2,2);defer test_world_destroy(&w2)
    restarted:=test_host(&w2,desc)
    test_step(&w2)
    copy(buffer[:],kept.bytes[:kept.size])
    packet_receive(restarted,buffer[:kept.size],address_memory(1))
    testing.expect_value(t,restarted.back.secure.exchanges,u64(1))
    confirming:=0
    for peer in restarted.back.peers {confirming+=int(peer.state==.Confirming)}
    testing.expect_value(t,confirming,1)
    again:[1]Seen
    for _ in 0..<90 {
        test_step(&w2)
        seen_poll(restarted,&again[0])
    }
    testing.expect(t,again[0].connected_count==0 && again[0].ended_count==0 && again[0].early==0 && members.calls==1)
    for peer in restarted.back.peers {testing.expect_value(t,peer.state,Peer_State.Free)}
}

// An allocator that counts what its owner is asked for.
@(private="file")
Counted :: struct {owner:runtime.Allocator,requests:int}
@(private="file")
counted_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    c:=(^Counted)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {c.requests+=1}
    return c.owner.procedure(c.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// An Initiate_Identity as a client with identity writes it, with payload as its claim and datagram 0,
// in out. Its MAC and checksum are those of the server; e, when given, replaces the one written.
@(private="file")
identity_forge :: proc(server:^Host,identity:^Dh_Key,payload:[]u8,out:[]u8,e:^Key=nil) -> []u8 {
    for &b in out {b=0}
    out[0]=u8(Packet_Type.Initiate_Identity)
    endian.unchecked_put_u64le(out[1:],0x5a17)
    endian.unchecked_put_u32le(out[9:],server.desc.version)
    endian.unchecked_put_u64le(out[13:],host_protocol_hash(server))
    at:=INITIATE_HEADER+KEY_BYTES+SEALED_KEY_BYTES
    copy(out[at:],payload)
    total:=at+len(payload)+TAG_BYTES+MAC_BYTES+CHECKSUM_BYTES
    mac_at:=total-CHECKSUM_BYTES-MAC_BYTES
    prologue:=initiate_prologue(server,out[:INITIATE_HEADER])
    n:Noise
    ephemeral:Key
    noise_initiate(&n,&ephemeral,prologue[:],&server.desc.identity.public,nil,identity,out[INITIATE_HEADER:mac_at])
    if e!=nil {copy(out[INITIATE_HEADER:],e[:])}
    key:=identity_mac_key(&server.desc.identity.public)
    mac:=mac_of(&key,out[:mac_at])
    copy(out[mac_at:],mac[:])
    checksum_write(out[:total],server.back.key)
    return out[:total]
}

// Initiate_Identity datagrams that are garbage under a valid MAC, that open with a claim longer than
// it may be or than what carries it, or that bring an e or an s of small order, are dropped as
// invalid: no connection, no authorize, no game, and not one request to the host's allocator.
@(test)
hostile_identity_initiates_are_refused_without_allocating :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    counted:=Counted{owner=context.allocator}
    members:=Members{count=1}
    server_id:=test_dh(8)
    members.keys[0],members.verdicts[0]=test_dh(9).public,{.Accept,.Member}
    server:=test_host(&w,{mode=.Server,channels=IDENTITY_CHANNELS,identity=server_id,authorize=members_authorize(&members),handshakes_per_update=1<<20,allocator={counted_proc,&counted}})
    if !testing.expect(t,server!=nil) {return}
    test_step(&w)
    requests:=counted.requests
    invalid,dropped:=server.back.stats.packets_invalid,server.back.stats.handshakes_dropped
    state:=u64(17)
    buffer:[PACKET_BYTES+8]u8
    sender:=0
    from :: proc(sender:^int) -> Address {
        sender^+=1
        return address_memory(100+sender^)
    }
    // Garbage under a valid MAC and checksum, at every size from the least to the most.
    key:=identity_mac_key(&server_id.public)
    for size in IDENTITY_INITIATE_BYTES-1..=PACKET_BYTES+1 {
        if size%7!=0 && size!=IDENTITY_INITIATE_BYTES && size<PACKET_BYTES {continue}
        for &b in buffer {b=u8(base.splitmix_next(&state))}
        bytes:=buffer[:size]
        bytes[0]=u8(Packet_Type.Initiate_Identity)
        endian.unchecked_put_u32le(bytes[9:],server.desc.version)
        endian.unchecked_put_u64le(bytes[13:],host_protocol_hash(server))
        for &b in bytes[21:INITIATE_HEADER] {b=0}
        if len(bytes)>=IDENTITY_INITIATE_BYTES {
            mac_at:=len(bytes)-CHECKSUM_BYTES-MAC_BYTES
            mac:=mac_of(&key,bytes[:mac_at])
            copy(bytes[mac_at:],mac[:])
            checksum_write(bytes,server.back.key)
        }
        packet_receive(server,bytes,from(&sender))
    }
    testing.expect_value(t,server.back.stats.packets_invalid,invalid+2) // the sizes past the limits
    invalid=server.back.stats.packets_invalid
    // Authentic, with a claim that does not fit.
    client:=test_dh(9)
    payload:[64]u8
    for size in ([]u16{CLAIM_BYTES+1,0xffff,63}) {
        endian.unchecked_put_u16le(payload[:],size)
        packet_receive(server,identity_forge(server,&client,payload[:],buffer[:]),from(&sender))
    }
    testing.expect_value(t,server.back.stats.packets_invalid,invalid+3)
    // Of small order: e, and s.
    for small_order in TEST_SMALL_ORDER {
        small:=small_order
        packet_receive(server,identity_forge(server,&client,payload[:2],buffer[:],&small),from(&sender))
        weak:=Dh_Key{private=client.private,public=small}
        packet_receive(server,identity_forge(server,&weak,payload[:2],buffer[:]),from(&sender))
    }
    test_step(&w,2)
    for command in host_poll(server) {testing.expect(t,command.kind!=.Connected && command.kind!=.Message)}
    for peer in server.back.peers {testing.expect_value(t,peer.state,Peer_State.Free)}
    testing.expect(t,server.back.stats.handshakes_dropped>=dropped+2*len(TEST_SMALL_ORDER))
    testing.expect_value(t,server.back.stats.packets_invalid,invalid+3)
    testing.expect_value(t,members.calls,0)
    testing.expect_value(t,counted.requests,requests)
}
