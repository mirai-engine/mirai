package mirai_net

import "core:mem"
import "core:time"
import "core:testing"
import "mirai:std/serial"
import "mirai:std/base"

@(private="file")
CHANNELS :: []Channel_Desc{{kind=.Reliable,queue_bytes=64<<10},{kind=.Unreliable},{kind=.Sequenced}}

@(test)
client_connects_through_the_challenge_and_both_ends_report_it :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,channels=CHANNELS})
    client:=test_host(&w,{mode=.Client,channels=CHANNELS})
    testing.expect(t,server!=nil && client!=nil)
    testing.expect_value(t,host_connect(server,address_memory(1)),Error.Invalid)
    on_server,on_client:=test_connect(&w,server,client)
    testing.expect(t,on_server!=0 && on_client!=0)
    test_step(&w,120)
    host_poll(server);host_poll(client)
    stats,ok:=connection_stats(server,on_server)
    testing.expect(t,ok && stats.packets_received>0 && stats.packets_acked>0)
    testing.expect_value(t,host_stats(server).connections,1)
    _,stale:=connection_stats(server,Connection(u64(on_server)+1<<32))
    testing.expect(t,!stale)
}

// An invitation carries the host's address on its network and the one its
// router mapped: the client asks both at once and goes on with the one that
// accepts. The other may be nobody, or another machine of the client's own
// network at that address, whose answers do not end the attempt while the
// host may still answer.
@(test)
a_client_goes_on_with_the_candidate_that_accepts :: proc(t:^testing.T) {
    Case :: struct {lan,public:Address,decoy:Host_Desc,want:Disconnect_Reason}
    other_version:=Host_Desc{mode=.Server,channels=CHANNELS,invite=0x5a5a,version=3}
    other_invite:=Host_Desc{mode=.Server,channels=CHANNELS,invite=0x6b6b,version=2}
    for c in ([]Case{
        {address_memory(0),address_memory(5),other_version,.None},
        {address_memory(5),address_memory(0),other_version,.None},
        {address_memory(1),address_memory(0),other_version,.None},
        {address_memory(1),address_memory(0),other_invite,.None},
        {address_memory(1),address_memory(5),other_version,.Denied_Version},
    }) {
        w:Test_World;test_world_init(&w,3)
        defer test_world_destroy(&w)
        server:=test_host(&w,{mode=.Server,channels=CHANNELS,invite=0x5a5a,version=2})
        test_host(&w,c.decoy)
        client:=test_host(&w,{mode=.Client,channels=CHANNELS,invite=0x5a5a,version=2,connect_timeout=1})
        testing.expect_value(t,host_connect(client,c.lan,c.public),Error.None)
        on_server,on_client:Connection
        reason:Disconnect_Reason
        for _ in 0..<120 {
            test_step(&w)
            for command in host_poll(server) {if command.kind==.Connected {on_server=command.connection}}
            for command in host_poll(client) {
                if command.kind==.Connected {on_client=command.connection}
                if command.kind==.Disconnected {reason=command.reason}
            }
            if on_server!=0 && on_client!=0 || reason!=.None {break}
        }
        if c.want!=.None {
            testing.expectf(t,on_client==0 && reason==c.want,"%v: %v",c,reason)
            continue
        }
        testing.expectf(t,on_server!=0 && on_client!=0 && client.back.peers[0].address==address_memory(0),"%v: %v",c,reason)
        message:=[3]u8{1,2,3}
        testing.expect_value(t,message_send(client,on_client,0,message[:]),Error.None)
        arrived:=false
        for _ in 0..<60 {
            test_step(&w)
            for command in host_poll(server) {arrived||=command.kind==.Message && len(command.data)==3}
            host_poll(client)
            if arrived {break}
        }
        testing.expectf(t,arrived,"%v: the connection carries messages",c)
    }
    w:Test_World;test_world_init(&w,1);defer test_world_destroy(&w)
    client:=test_host(&w,{mode=.Client})
    testing.expect_value(t,host_connect(client),Error.Invalid)
    testing.expect_value(t,host_connect(client,{}),Error.Invalid)
    testing.expect_value(t,host_connect(client,address_memory(1),address_memory(2),address_memory(3)),Error.Invalid)
}

@(test)
handshake_gives_a_spoofed_address_nothing_to_amplify_or_allocate :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,3);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server})
    forger:=sim_endpoint_transport(&w.sim,2)
    buffer:[PACKET_BYTES]u8
    writer:serial.Bit_Writer

    buffer[0]=u8(Packet_Type.Request)
    serial.bit_writer_init(&writer,buffer[1:])
    serial.bit_write(&writer,0x1234,64)
    request:=test_handshake(buffer[:],&writer,server.back.key,HANDSHAKE_BYTES)
    forger.send(forger.data,address_memory(0),request)
    forger.send(forger.data,address_memory(0),request[:HANDSHAKE_BYTES-1])
    test_step(&w,2)
    answer:[PACKET_BYTES]u8
    size,_,ok:=forger.receive(forger.data,answer[:])
    testing.expect(t,ok && size*3<HANDSHAKE_BYTES)
    _,_,again:=forger.receive(forger.data,answer[:])
    testing.expect(t,!again)
    testing.expect_value(t,Packet_Type(answer[0]),Packet_Type.Challenge)

    // A response whose cookie was not issued to this address gets no answer.
    buffer[0]=u8(Packet_Type.Response)
    serial.bit_writer_init(&writer,buffer[1:])
    serial.bit_write(&writer,0x1234,64)
    serial.bit_write(&writer,u64(w.now*1000),64)
    serial.bit_write(&writer,0xdeadbeef,64)
    serial.bit_write(&writer,host_protocol_hash(server),64)
    forger.send(forger.data,address_memory(0),test_handshake(buffer[:],&writer,server.back.key,HANDSHAKE_BYTES))
    test_step(&w,2)
    _,_,answered:=forger.receive(forger.data,answer[:])
    testing.expect(t,!answered)
    for peer in server.back.peers {testing.expect_value(t,peer.state,Peer_State.Free)}
    testing.expect_value(t,len(host_poll(server)),0)
    testing.expect(t,host_stats(server).handshakes_dropped==1 && host_stats(server).handshakes_refused==0 && host_stats(server).packets_invalid==1)
}

@(test)
connections_are_denied_for_version_protocol_and_capacity :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,6);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,max_connections=1,version=3,channels=CHANNELS})
    old:=test_host(&w,{mode=.Client,version=2,channels=CHANNELS})
    fewer:=CHANNELS
    other:=test_host(&w,{mode=.Client,version=3,channels=fewer[:2]})
    first:=test_host(&w,{mode=.Client,version=3,channels=CHANNELS})
    second:=test_host(&w,{mode=.Client,version=3,channels=CHANNELS})
    expect_denied :: proc(t:^testing.T,w:^Test_World,client:^Host,reason:Disconnect_Reason) {
        host_connect(client,address_memory(0))
        for _ in 0..<120 {
            test_step(w)
            for command in host_poll(client) {
                testing.expect_value(t,command.kind,Command_Kind.Disconnected)
                testing.expect_value(t,command.reason,reason)
                return
            }
        }
        testing.expect(t,false,"no answer");return
    }
    expect_denied(t,&w,old,.Denied_Version)
    expect_denied(t,&w,other,.Denied_Protocol)
    _,connected:=test_connect(&w,server,first)
    testing.expect(t,connected!=0)
    expect_denied(t,&w,second,.Denied_Full)
    stranger:=test_host(&w,{mode=.Client,version=3,protocol_id=5,channels=CHANNELS,connect_timeout=0.5})
    expect_denied(t,&w,stranger,.Connect_Timeout)
}

// A client with room for fewer objects than its server never connects: both
// ends end the attempt with Capacity, and the slot of the server is free again.
@(test)
a_client_with_too_few_objects_never_connects_and_the_server_hears_why :: proc(t:^testing.T) {
    tp:Test_Protocol;test_protocol_init(&tp);defer test_protocol_destroy(&tp)
    w:Test_World;test_world_init(&w,3);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,protocol=&tp.protocol,max_connections=1,replication={max_objects=64}})
    small:=test_host(&w,{mode=.Client,protocol=&tp.protocol,replication={max_objects=8}})
    host_connect(small,address_memory(0))
    told,heard:Disconnect_Reason
    connected:=false
    for _ in 0..<120 {
        test_step(&w)
        for command in host_poll(small) {
            connected||=command.kind==.Connected
            if command.kind==.Disconnected {told=command.reason}
        }
        for command in host_poll(server) {if command.kind==.Disconnected {heard=command.reason}}
    }
    testing.expect(t,!connected && told==.Capacity && heard==.Capacity)
    enough:=test_host(&w,{mode=.Client,protocol=&tp.protocol,replication={max_objects=64}})
    _,on_client:=test_connect(&w,server,enough)
    testing.expect(t,on_client!=0)
}

// A server announces its history when it accepts, and its client takes it in place of its
// own; the server keeps input that far ahead of the tick it published last and drops what
// comes further, at every tick rate.
@(test)
a_client_takes_the_history_of_its_server_and_the_input_fits_it :: proc(t:^testing.T) {
    for rate in ([]int{60,240,480}) {
        c:=struct{rate:int}{rate}
        tp:Test_Protocol;test_protocol_init(&tp);defer test_protocol_destroy(&tp)
        w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
        server:=test_host(&w,{mode=.Server,protocol=&tp.protocol,tick_rate=c.rate})
        client:=test_host(&w,{mode=.Client,protocol=&tp.protocol,tick_rate=c.rate,replication={history_seconds=0.1}})
        depth:=int(HISTORY_SECONDS*f32(c.rate))
        testing.expectf(t,host_history(server)==depth && host_history(client)==history_ticks(0.1,c.rate),"%d Hz: histories %d and %d",c.rate,host_history(server),host_history(client))
        on_server,on_client:=test_connect(&w,server,client)
        if !testing.expectf(t,on_server!=0 && on_client!=0,"%d Hz: the client connects",c.rate) {continue}
        testing.expectf(t,host_history(client)==depth,"%d Hz: the client keeps %d ticks, not the server's %d",c.rate,host_history(client),depth)
        host_publish(server,1)
        input:=Test_Input{buttons=1}
        for tick in u32(1+depth)..=u32(2+depth) {testing.expect_value(t,input_submit(client,tick,&input),Error.None)}
        host_publish(client,1)
        test_step(&w,8)
        host_poll(server)
        stats,_:=connection_stats(server,on_server)
        got:Test_Input
        kept:=input_take(server,on_server,u32(1+depth),&got)
        testing.expectf(t,kept==.Fresh && got.buttons==1,"%d Hz: the input %d ticks ahead is kept (%v)",c.rate,depth,kept)
        early:=input_take(server,on_server,u32(2+depth),&got)
        testing.expectf(t,early!=.Fresh && stats.inputs_early==1,"%d Hz: the input %d ticks ahead is dropped (%v, %d early)",c.rate,depth+1,early,stats.inputs_early)
    }
}

@(test)
disconnects_and_timeouts_reach_both_ends_with_their_reason :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,3);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,timeout=1})
    a:=test_host(&w,{mode=.Client,timeout=1})
    b:=test_host(&w,{mode=.Client,timeout=1})
    a_on_server,_:=test_connect(&w,server,a)
    b_on_server,_:=test_connect(&w,server,b)
    testing.expect(t,a_on_server!=0 && b_on_server!=0)
    // Every connection is found by its address, and only while it lasts.
    listed :: proc(h:^Host,expected:int) -> bool {
        count:=0
        for &p in h.back.peers {
            if p.state==.Free {continue}
            count+=1
            if peer_find(&h.back,p.address)!=&p {return false}
        }
        return count==expected && h.back.by_address.count==expected
    }
    testing.expect(t,listed(server,2) && listed(a,1))
    host_disconnect(server,a_on_server,.Kicked)
    test_step(&w,4)
    kicked:=host_poll(a)
    testing.expect(t,len(kicked)==1 && kicked[0].kind==.Disconnected && kicked[0].reason==.Kicked)
    told:=host_poll(server)
    testing.expect(t,len(told)==1 && told[0].connection==a_on_server && told[0].reason==.Kicked)
    testing.expect(t,listed(server,1) && listed(a,0))

    // b goes silent: only the server keeps running.
    silent:=w.hosts[2]
    w.count=2
    seen:=false
    for _ in 0..<90 {
        test_step(&w)
        for command in host_poll(server) {
            seen=command.kind==.Disconnected && command.connection==b_on_server && command.reason==.Timeout
        }
    }
    testing.expect(t,seen && listed(server,0))
    w.count=3
    testing.expect(t,silent==b)
    _,again:=test_connect(&w,server,a)
    testing.expect(t,again!=0 && listed(server,1) && listed(a,1))
}

@(test)
reliable_messages_arrive_once_in_order_under_loss_reordering_and_duplication :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2,seed=42);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,channels=CHANNELS})
    client:=test_host(&w,{mode=.Client,channels=CHANNELS})
    on_server,on_client:=test_connect(&w,server,client)
    testing.expect(t,on_server!=0 && on_client!=0)
    harsh:=Sim_Conditions{latency=0.04,jitter=0.03,loss=0.3,duplicate=0.1,reorder=0.2,reorder_delay=0.05}
    sim_endpoint_conditions(&w.sim,0,harsh)
    sim_endpoint_conditions(&w.sim,1,harsh)

    MESSAGES :: 300
    payload:=make([]u8,20000);defer delete(payload)
    size_of_message :: proc(i:int) -> int {return i%37==0?12000+i*13:(i*7919)%700}
    fill :: proc(payload:[]u8,i:int) {
        for &b,k in payload {b=u8(i*31+k*7)}
    }
    sent,to_server,to_client:=0,0,0
    state:=u64(5)
    for step in 0..<6000 {
        if sent<MESSAGES && base.splitmix_next(&state)%3==0 {
            size:=size_of_message(sent)
            fill(payload[:size],sent)
            testing.expect_value(t,message_send(client,on_client,0,payload[:size]),Error.None)
            fill(payload[:size],sent+1000)
            testing.expect_value(t,message_send(server,on_server,0,payload[:size]),Error.None)
            sent+=1
        }
        test_step(&w)
        check :: proc(t:^testing.T,commands:[]Command,next:^int,salt:int) {
            for command in commands {
                if command.kind!=.Message {testing.expect(t,false,"connection lost");return}
                size:=size_of_message(next^)
                if len(command.data)!=size {testing.expect(t,false,"wrong size or order");return}
                for b,k in command.data {
                    if b!=u8((next^+salt)*31+k*7) {testing.expect(t,false,"wrong contents");return}
                }
                next^+=1
            }
        }
        check(t,host_poll(server),&to_server,0)
        check(t,host_poll(client),&to_client,1000)
        if to_server==MESSAGES && to_client==MESSAGES {break}
    }
    testing.expect_value(t,to_server,MESSAGES)
    testing.expect_value(t,to_client,MESSAGES)
    stats,_:=connection_stats(client,on_client)
    testing.expect(t,stats.loss>0.15 && stats.loss<0.6)
    testing.expect(t,stats.chunks_resent>0 && stats.packets_out_of_order>0)
    testing.expect(t,stats.rtt>0.05 && stats.rtt<0.4)
}

@(test)
unreliable_messages_arrive_at_most_once_and_sequenced_ones_keep_only_the_latest :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2,seed=7);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,channels=CHANNELS})
    client:=test_host(&w,{mode=.Client,channels=CHANNELS})
    _,on_client:=test_connect(&w,server,client)
    sim_endpoint_conditions(&w.sim,1,{latency=0.02,jitter=0.015,loss=0.2,duplicate=0.5})
    seen:[400]bool
    received,last:=0,-1
    for i in 0..<400 {
        value:=u32(i)
        testing.expect_value(t,message_send(client,on_client,1,mem.ptr_to_bytes(&value)),Error.None)
        test_step(&w)
        for command in host_poll(server) {
            testing.expect_value(t,command.channel,u8(1))
            got:=int((^u32)(raw_data(command.data))^)
            testing.expect(t,!seen[got] && got>last)
            seen[got]=true
            last=got
            received+=1
        }
        host_poll(client)
    }
    testing.expect(t,received>250 && received<380)

    sim_endpoint_conditions(&w.sim,1,{})
    test_step(&w,10)
    host_poll(server)
    for i in 0..<5 {
        value:=u32(100+i)
        message_send(client,on_client,2,mem.ptr_to_bytes(&value))
        message_send(client,on_client,1,mem.ptr_to_bytes(&value))
    }
    test_step(&w,3)
    sequenced,plain:=0,0
    for command in host_poll(server) {
        if command.channel==2 {
            sequenced+=1
            testing.expect_value(t,(^u32)(raw_data(command.data))^,u32(104))
        } else {
            plain+=1
        }
    }
    testing.expect_value(t,sequenced,1)
    testing.expect_value(t,plain,5)
    big:[MAX_UNRELIABLE_BYTES+1]u8
    testing.expect_value(t,message_send(client,on_client,1,big[:]),Error.Too_Large)
    testing.expect_value(t,message_send(client,on_client,1,big[:MAX_UNRELIABLE_BYTES]),Error.None)
    testing.expect_value(t,message_send(client,on_client,3,big[:4]),Error.Invalid)
    test_step(&w,3)
    testing.expect_value(t,len(host_poll(server)),1)
}

// More than the queue holds, sent while nothing is acknowledged: message_send
// answers Full, the connection stays and everything arrives in order.
@(test)
a_full_reliable_queue_refuses_messages_instead_of_closing_the_connection :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    channels:=[]Channel_Desc{{kind=.Reliable,queue_bytes=256<<10}}
    server:=test_host(&w,{mode=.Server,channels=channels})
    client:=test_host(&w,{mode=.Client,channels=channels})
    on_server,_:=test_connect(&w,server,client)
    sim_endpoint_conditions(&w.sim,1,{loss=1})
    MESSAGES :: 64
    block:=make([]u8,16<<10);defer delete(block)
    sent,received,refused:=0,0,0
    for step in 0..<3000 {
        if step==120 {sim_endpoint_conditions(&w.sim,1,{})}
        for sent<MESSAGES {
            for &b,k in block {b=u8(sent*31+k*7)}
            error:=message_send(server,sent%2==0?0:on_server,0,block)
            if error==.Full {refused+=1;break}
            testing.expect_value(t,error,Error.None)
            sent+=1
        }
        test_step(&w)
        for command in host_poll(server) {
            testing.expect(t,command.kind!=.Disconnected,"the server keeps the connection")
        }
        for command in host_poll(client) {
            if command.kind!=.Message {testing.expect(t,false,"the client keeps the connection");return}
            ok:=len(command.data)==len(block)
            for b,k in command.data {
                if !ok {break}
                ok=b==u8(received*31+k*7)
            }
            testing.expect(t,ok,"every message arrives whole and in order")
            received+=1
        }
        if received==MESSAGES {break}
    }
    testing.expect(t,refused>0,"the queue filled while nothing was acknowledged")
    testing.expect_value(t,received,MESSAGES)
    stats,_:=connection_stats(server,on_server)
    testing.expect_value(t,stats.messages_dropped,0)
}

// A reliable message larger than its queue streams in as the window drains
// it, under loss, and arrives whole and in order in pieces; the channel takes
// no other message until it is in.
@(test)
a_reliable_message_larger_than_its_queue_streams_and_arrives_in_pieces :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    channels:=[]Channel_Desc{{kind=.Reliable,queue_bytes=8<<10}}
    server:=test_host(&w,{mode=.Server,channels=channels})
    client:=test_host(&w,{mode=.Client,channels=channels})
    on_server,_:=test_connect(&w,server,client)
    sim_endpoint_conditions(&w.sim,1,{loss=0.2})
    blob:=make([]u8,300000);defer delete(blob)
    for &b,i in blob {b=u8(i*7+i/251)}
    tail:=[3]u8{9,8,7}
    sent,got,pieces:=0,0,0
    whole,after:=false,false
    for step in 0..<6000 {
        if sent<len(blob) {
            message_send(server,on_server,0,blob,&sent)
            if sent<len(blob) {testing.expect_value(t,message_send(server,on_server,0,tail[:]),Error.Full)}
        } else if !after {
            after=message_send(server,on_server,0,tail[:])==.None
        }
        test_step(&w)
        host_poll(server)
        for command in host_poll(client) {
            if command.kind!=.Message {testing.expect(t,false,"the client keeps the connection");return}
            if whole {
                testing.expect(t,string(command.data)==string(tail[:]),"the next message follows the streamed one")
                return
            }
            pieces+=1
            testing.expect(t,len(command.data)<=PIECE_BYTES)
            for b,k in command.data {
                if b!=blob[got+k] {testing.expect(t,false,"the pieces are the message, in order");return}
            }
            got+=len(command.data)
            whole=!command.more
        }
        _=step
    }
    testing.expect(t,false,"the message and the one after it arrive")
}

@(test)
send_rate_limits_the_bytes_a_connection_puts_on_the_wire :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,2);defer test_world_destroy(&w)
    channels:=[]Channel_Desc{{kind=.Reliable,queue_bytes=1<<20}}
    server:=test_host(&w,{mode=.Server,channels=channels,command_bytes=4<<20})
    client:=test_host(&w,{mode=.Client,channels=channels,send_rate=20000,command_bytes=4<<20,frame_bytes=1<<20})
    _,on_client:=test_connect(&w,server,client)
    blob:=make([]u8,200000);defer delete(blob)
    for &b,i in blob {b=u8(i)}
    testing.expect_value(t,message_send(client,on_client,0,blob),Error.None)
    test_step(&w,30)
    host_poll(client);host_poll(server)
    before,_:=connection_stats(client,on_client)
    arrived:=false
    steps,got:=0,0
    for !arrived && steps<1200 {
        test_step(&w)
        steps+=1
        host_poll(client)
        for command in host_poll(server) {
            if command.kind!=.Message {continue}
            got+=len(command.data)
            arrived=!command.more && got==len(blob)
        }
    }
    testing.expect(t,arrived)
    after,_:=connection_stats(client,on_client)
    rate:=f64(after.bytes_sent-before.bytes_sent)/(f64(steps)*TEST_STEP)
    testing.expect(t,rate<22000 && rate>15000)
    testing.expect(t,after.send_rate>10000 && after.send_rate<24000)
}

// A transport that keeps the last datagram of a connection its host sent.
@(private="file")
Capture :: struct {inner:Transport,last:[PACKET_BYTES]u8,size:int}
@(private="file")
capture_transport :: proc(c:^Capture) -> Transport {
    return {c,proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
        c:=(^Capture)(data)
        if test_packet_data(bytes) {c.size=copy(c.last[:],bytes)}
        return c.inner.send(c.inner.data,to,bytes)
    },proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
        c:=(^Capture)(data)
        return c.inner.receive(c.inner.data,buffer)
    }}
}
// A message each way, stepped until both arrive. False when an end lost the connection or they did not.
@(private="file")
both_ways :: proc(server,client:^Host,on_server,on_client:Connection,step:proc(data:rawptr),data:rawptr) -> bool {
    message_send(server,on_server,0,{1})
    message_send(client,on_client,0,{2})
    server_got,client_got:=false,false
    for _ in 0..<300 {
        step(data)
        for command in host_poll(server) {
            if command.kind==.Disconnected {return false}
            if command.kind==.Message && command.connection==on_server {server_got=true}
        }
        for command in host_poll(client) {
            if command.kind==.Disconnected {return false}
            if command.kind==.Message {client_got=true}
        }
        if server_got && client_got {return true}
    }
    return false
}

// A router that changes the port of a client mid-session: the connection
// follows it on its first datagram from there, which opens under its key, and
// keeps its handle. That datagram, or any other, replayed by someone else from
// another address moves nothing. Over the in-memory network and real UDP.
@(test)
a_connection_follows_its_client_to_a_new_port_and_a_replay_moves_nothing :: proc(t:^testing.T) {
    {
        w:Test_World;test_world_init(&w,4,seed=5);defer test_world_destroy(&w)
        server:=test_host(&w,{mode=.Server,channels=CHANNELS})
        client:=test_host(&w,{mode=.Client,channels=CHANNELS})
        capture:=Capture{inner=client.desc.transport}
        client.desc.transport=capture_transport(&capture)
        on_server,on_client:=test_connect(&w,server,client)
        sim_step :: proc(data:rawptr) {test_step((^Test_World)(data))}
        testing.expect(t,on_server!=0 && both_ways(server,client,on_server,on_client,sim_step,&w))
        capture.inner=sim_endpoint_transport(&w.sim,2)
        testing.expect(t,both_ways(server,client,on_server,on_client,sim_step,&w),"the connection goes on from the new port")
        p:=peer_from(server,on_server)
        testing.expect(t,p!=nil && p.address==address_memory(2))
        forger:=sim_endpoint_transport(&w.sim,3)
        forger.send(forger.data,address_memory(0),capture.last[:capture.size])
        testing.expect(t,both_ways(server,client,on_server,on_client,sim_step,&w))
        testing.expect(t,p.address==address_memory(2),"a replay moved the connection")
        testing.expect_value(t,host_stats(server).connections,1)
    }
    Pair :: struct {server,client:^Host}
    sockets:[4]Udp
    if !udp_open(&sockets[0],address_loopback(0)) {testing.expect(t,false,"cannot bind a UDP socket on 127.0.0.1");return}
    for &socket in sockets[1:] {
        if !udp_open(&socket,address_loopback(0)) {testing.expect(t,false,"cannot bind a UDP socket on 127.0.0.1");return}
    }
    defer for &socket in sockets {udp_close(&socket)}
    pair:Pair={new(Host),new(Host)}
    defer {free(pair.server);free(pair.client)}
    capture:=Capture{inner=udp_transport(&sockets[1])}
    if !testing.expect_value(t,host_init(pair.server,{mode=.Server,transport=udp_transport(&sockets[0]),channels=CHANNELS,protocol_id=93}),Error.None) {return}
    defer host_destroy(pair.server)
    if !testing.expect_value(t,host_init(pair.client,{mode=.Client,transport=capture_transport(&capture),channels=CHANNELS,protocol_id=93}),Error.None) {return}
    defer host_destroy(pair.client)
    udp_step :: proc(data:rawptr) {
        pair:=(^Pair)(data)
        now:=host_time(pair.server)
        host_update(pair.client,now);host_update(pair.server,now)
        time.sleep(time.Millisecond)
    }
    host_connect(pair.client,address_loopback(int(sockets[0].address.port)))
    on_server,on_client:Connection
    for _ in 0..<3000 {
        udp_step(&pair)
        for command in host_poll(pair.server) {
            if command.kind==.Connected {on_server=command.connection}
        }
        for command in host_poll(pair.client) {
            if command.kind==.Connected {on_client=command.connection}
        }
        if on_server!=0 && on_client!=0 {break}
    }
    testing.expect(t,on_server!=0 && both_ways(pair.server,pair.client,on_server,on_client,udp_step,&pair))
    capture.inner=udp_transport(&sockets[2])
    testing.expect(t,both_ways(pair.server,pair.client,on_server,on_client,udp_step,&pair),"the connection goes on from the new port")
    moved:=address_loopback(int(sockets[2].address.port))
    p:=peer_from(pair.server,on_server)
    testing.expect(t,p!=nil && p.address==moved)
    forger:=udp_transport(&sockets[3])
    forger.send(forger.data,address_loopback(int(sockets[0].address.port)),capture.last[:capture.size])
    testing.expect(t,both_ways(pair.server,pair.client,on_server,on_client,udp_step,&pair))
    testing.expect(t,p.address==moved,"a replay moved the connection")
}

@(test)
hostile_datagrams_never_crash_a_host_nor_reach_the_game_as_data :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,3,seed=99);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,channels=CHANNELS,max_connections=4})
    client:=test_host(&w,{mode=.Client,channels=CHANNELS})
    on_server,on_client:=test_connect(&w,server,client)
    testing.expect(t,on_server!=0 && on_client!=0)

    // Garbage of every size from an address that never connected.
    forger:=sim_endpoint_transport(&w.sim,2)
    state:=u64(3)
    junk:[PACKET_BYTES]u8
    for round in 0..<3000 {
        size:=int(base.splitmix_next(&state)%PACKET_BYTES)+1
        for &b in junk[:size] {b=u8(base.splitmix_next(&state))}
        if round%2==0 && size>=8 {
            junk[0]&=7
            checksum_write(junk[:size],server.back.key)
        }
        forger.send(forger.data,address_memory(0),junk[:size])
        if round%16==0 {test_step(&w)}
    }
    // Every type at the lengths around the limits, straight to the parsers of both ends, with
    // the checksum of a handshake made valid where it fits: from a stranger and from the peer.
    big:[PACKET_BYTES+64]u8
    for size in ([]int{0,1,DATA_HEADER,DATA_HEADER+CHECKSUM_BYTES,DATA_HEADER+TAG_BYTES,HANDSHAKE_BYTES-1,HANDSHAKE_BYTES,PACKET_BYTES,PACKET_BYTES+1,len(big)}) {
        for type in Packet_Type {
            for &b in big[1:] {b=u8(base.splitmix_next(&state))}
            // A datagram of a connection names its slot: the live one or a free one, which a stranger cannot move.
            big[0],big[3],big[4]=u8(type),u8(size&1),0
            if size>=DATA_HEADER+1+CHECKSUM_BYTES && size<=PACKET_BYTES && type!=.Data && type!=.Disconnect {checksum_write(big[:size],server.back.key)}
            for from in ([2]Address{address_memory(2),address_memory(1)}) {
                buffer:=big
                packet_receive(server,buffer[:size],from)
            }
            buffer:=big
            packet_receive(client,buffer[:size],address_memory(0))
        }
    }
    test_step(&w,4)
    for command in host_poll(server) {testing.expect(t,command.kind!=.Connected)}
    testing.expect(t,host_stats(server).packets_invalid>1000)
    testing.expect_value(t,host_stats(server).connections,1)

    // Datagrams of a live connection damaged in transit, checksum repaired.
    fuzz_server:=Test_Fuzz{inner=server.desc.transport,host=server,rng=11,rate=0.05}
    fuzz_client:=Test_Fuzz{inner=client.desc.transport,host=client,rng=12,rate=0.05}
    server.desc.transport=test_fuzz_transport(&fuzz_server)
    client.desc.transport=test_fuzz_transport(&fuzz_client)
    payload:[600]u8
    reconnects:=0
    for step in 0..<8000 {
        if on_client!=0 {
            message_send(client,on_client,int(base.splitmix_next(&state)%3),payload[:base.splitmix_next(&state)%600])
            message_send(server,0,int(base.splitmix_next(&state)%3),payload[:base.splitmix_next(&state)%600])
        }
        test_step(&w)
        for command in host_poll(server) {
            if command.kind==.Message {testing.expect(t,len(command.data)<=20000)}
        }
        for command in host_poll(client) {
            if command.kind==.Disconnected {on_client=0;host_connect(client,address_memory(0));reconnects+=1}
            if command.kind==.Connected {on_client=command.connection}
        }
    }
    testing.expectf(t,fuzz_server.mutated>150 && fuzz_client.mutated>150,"mutated %v %v reconnects %v",fuzz_server.mutated,fuzz_client.mutated,reconnects)
    testing.expect(t,reconnects>0)
    server.desc.transport,client.desc.transport=fuzz_server.inner,fuzz_client.inner
    // A damaged Disconnect leaves the client connected to a server that let it go, until it times out.
    if on_client==0 || host_stats(server).connections==0 {
        for _ in 0..<900 {
            test_step(&w)
            host_poll(server)
            for command in host_poll(client) {
                if command.kind==.Connected {on_client=command.connection}
                if command.kind==.Disconnected {on_client=0;host_connect(client,address_memory(0))}
            }
            if on_client!=0 && host_stats(server).connections==1 {break}
        }
    }
    testing.expect(t,on_client!=0)
    message_send(client,on_client,0,payload[:10])
    delivered:=false
    for _ in 0..<60 {
        test_step(&w)
        host_poll(client)
        for command in host_poll(server) {
            if command.kind==.Message && len(command.data)==10 {delivered=true}
        }
    }
    testing.expect(t,delivered)
}

@(test)
udp_sockets_carry_a_connection_on_localhost :: proc(t:^testing.T) {
    server_socket,client_socket:Udp
    if !udp_open(&server_socket,address_loopback(0)) || !udp_open(&client_socket,address_loopback(0)) {
        testing.expect(t,false,"cannot bind a UDP socket on 127.0.0.1");return
    }
    defer udp_close(&server_socket)
    defer udp_close(&client_socket)
    testing.expect(t,server_socket.address.port!=0)
    parsed,parsed_ok:=address_parse("127.0.0.1:7777")
    testing.expect(t,parsed_ok && parsed==address_loopback(7777))
    channels:=[]Channel_Desc{{kind=.Reliable}}
    server,client:=new(Host),new(Host)
    defer {host_destroy(server);host_destroy(client);free(server);free(client)}
    testing.expect_value(t,host_init(server,{mode=.Server,transport=udp_transport(&server_socket),channels=channels,seed=1}),Error.None)
    testing.expect_value(t,host_init(client,{mode=.Client,transport=udp_transport(&client_socket),channels=channels,seed=2}),Error.None)
    host_connect(client,server_socket.address)
    on_client,on_server:Connection
    echoed:=false
    text:="hola por UDP"
    for _ in 0..<2000 {
        now:=host_time(server)
        host_update(client,now);host_update(server,now)
        for command in host_poll(server) {
            #partial switch command.kind {
            case .Connected: on_server=command.connection
            case .Message:   message_send(server,on_server,0,command.data)
            }
        }
        for command in host_poll(client) {
            #partial switch command.kind {
            case .Connected:
                on_client=command.connection
                message_send(client,on_client,0,transmute([]u8)text)
            case .Message:
                echoed=string(command.data)==text
            }
        }
        if echoed {break}
        time.sleep(time.Millisecond)
    }
    testing.expect(t,echoed)
    stats,_:=connection_stats(client,on_client)
    testing.expect(t,stats.packets_received>0)
}
