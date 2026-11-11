package multiplayer

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/base"
import "mirai:std/compressor/lz"

@(private="file") TOY_JOURNAL :: u32(0x746f79)
@(private="file") TOY_KEY :: Journal_Key{1,0}
@(private="file") TOY_PADDING :: 12000 // what a base of the toy carries besides its value: more than JOURNAL_BUDGET

// One end of the library of these tests: a value its operations fold in
// order (value*31+amount, so one applied twice or out of order shows), and
// what a base carries besides it.
@(private="file")
Toy :: struct {
    journal:Journal,
    value:u32,
    padding:[TOY_PADDING]u8,
    applied:int,
}

// Server: an operation of its game, applied and published.
@(private="file")
toy_publish :: proc(toy:^Toy,outbox:^Net_Outbox,time:core.Time,amount:u32) {
    toy.value=toy.value*31+amount
    op:=Journal_Op{key=TOY_KEY,check=u64(toy.value),low={0,0,0},high={-1,-1,-1}}
    (^u32)(&op.body)^=amount
    journal_publish(&toy.journal,outbox,op,time)
}

// Server: the base of the toy, to whoever entered or asked.
@(private="file")
toy_serve :: proc(toy:^Toy,outbox:^Net_Outbox,time:core.Time) {
    for sv in journal_serves(&toy.journal,outbox,time) {
        sv.whole=true
        raw,ok:=journal_buffer(&toy.journal,4+TOY_PADDING)
        if !ok {continue}
        (^u32)(raw_data(raw))^=toy.value
        copy(raw[4:],toy.padding[:])
        journal_part(&toy.journal,sv,raw,true)
    }
}

// Client: what the journal hands, applied at once.
@(private="file")
toy_follow :: proc(toy:^Toy,time:core.Time) {
    for due in journal_due(&toy.journal,TOY_KEY,time,0) {
        if due.part!=nil {
            if len(due.part.bytes)!=4+TOY_PADDING {journal_result(&toy.journal,due.tag,.Failed,0,time);continue}
            toy.value=(^u32)(raw_data(due.part.bytes))^
            copy(toy.padding[:],due.part.bytes[4:])
        } else {
            toy.value=toy.value*31+(^u32)(&due.op.body)^
            toy.applied+=1
        }
        journal_result(&toy.journal,due.tag,.Done,u64(toy.value),time)
    }
}

// A server and a client of the toy over a session, on the in-memory network or UDP.
@(private="file")
Toy_Pair :: struct {
    info:core.World_Info,
    worlds:[2]Net_Test_World,
    shares:[2]Net_Test_Shared,
    apps:[2]host.App,
    sessions:[2]Net_Session,
    problems:[2]core.Problems,
    toys:[2]Toy,
    network:wire.Sim_Network,
    sockets:[2]wire.Udp,
    udp:bool,
    base:f64,
    rewinds:Net_Rewinds,
    sent:[dynamic]u64, // server: JOURNAL bytes sent by tick
    seen:u64,          // server: the cursor of its connection events, as a generated call keeps it
}

@(private="file")
pair_init :: proc(t:^testing.T,p:^Toy_Pair,udp:bool) -> bool {
    described:bool
    if p.info,described=net_test_info(t);!described {return false}
    p.info.messages=slice.clone([]core.Message_Info{
        {name="Net_Journal_Op",library="multiplayer",type=Net_Journal_Op,info=type_info_of(Net_Journal_Op),from=.Server,reliable=true},
        {name="Net_Journal_Part",library="multiplayer",type=Net_Journal_Part,info=type_info_of(Net_Journal_Part),from=.Server,reliable=true},
        {name="Net_Journal_Resync",library="multiplayer",type=Net_Journal_Resync,info=type_info_of(Net_Journal_Resync),from=.Client,reliable=true},
        {name="Net_Journal_Ask",library="multiplayer",type=Net_Journal_Ask,info=type_info_of(Net_Journal_Ask),from=.Client,reliable=true},
        {name="Net_Journal_Refused",library="multiplayer",type=Net_Journal_Refused,info=type_info_of(Net_Journal_Refused),from=.Server,reliable=true},
    })
    for &world,index in p.worlds {
        if !net_test_init(&world,&p.info) {return false}
        p.shares[index].info=&p.info
        p.apps[index]={info=&p.info,allocator=context.allocator,tick_dt=1.0/60,shared=&p.shares[index]}
        p.toys[index].journal.id=TOY_JOURNAL
    }
    p.udp=udp
    if udp {
        for &socket in p.sockets {
            if !testing.expect(t,wire.udp_open(&socket,wire.address_loopback(0)),"a UDP socket on localhost") {return false}
        }
    } else if !wire.sim_network_init(&p.network,{seed=31,endpoints=2,packets=4096}) {
        return false
    }
    for &session,index in p.sessions {
        exchange:wire.Transport
        if udp {exchange=wire.udp_transport(&p.sockets[index])}
        if !net_test_session(&session,&p.worlds[index],&p.info,&p.apps[index],&p.network,index,index==0?.Server:.Client,exchange) {return false}
        session.problems=&p.problems[index]
        p.shares[index].session=&session
    }
    if udp {p.base=wire.host_time(&p.sessions[0].host)}
    return true
}

@(private="file")
pair_destroy :: proc(p:^Toy_Pair) {
    for &session in p.sessions {if session.host_ready {session_destroy(&session)}}
    for &toy in p.toys {journal_free(&toy.journal)}
    for &world in p.worlds {core.world_destroy(&p.info,.World,&world)}
    for &app in p.apps {host.app_world_scratch_free(&app);delete(app.worlds)}
    for &socket in p.sockets {wire.udp_close(&socket)}
    if !p.udp {wire.sim_network_destroy(&p.network)}
    delete(p.rewinds.queue.items)
    delete(p.sent)
    delete(p.info.messages)
    core.test_info_destroy(&p.info)
}

// A tick of both ends: the network, the head of the tick, the toy and the
// tail. The server publishes amount when it is not 0; the client runs lead
// ticks ahead.
@(private="file")
pair_tick :: proc(p:^Toy_Pair,tick:u64,amount:u32) {
    now:=p.base+f64(tick)/60
    if !p.udp {wire.sim_network_advance(&p.network,now)}
    for &session in p.sessions {wire.host_update(&session.host,now)}
    server_commands(&p.sessions[0],core.world_ref(&p.worlds[0],&p.info),nil,wire.host_poll(&p.sessions[0].host),&p.worlds[0].remote)
    client_commands(&p.sessions[1],core.world_ref(&p.worlds[1],&p.info),p.apps[1].assets,p.apps[1].allocator,wire.host_poll(&p.sessions[1].host))
    before:=p.toys[0].journal.stats.bytes_sent
    for index in 0..<2 {
        w:=&p.worlds[index]
        ref:=core.world_ref(w,&p.info)
        w.time.tick=tick+(index==1?8:0)
        net_tick_head(ref,&p.apps[index],&p.sessions[index],&w.remote,&w.connections,&w.messages,&p.problems[index])
        toy:=&p.toys[index]
        // By their places in the messages of pair_init.
        m:=&w.messages
        inbox:=Journal_Inbox{core.inbox(m,0,Net_Journal_Op),core.inbox(m,1,Net_Journal_Part),core.inbox(m,4,Net_Journal_Refused),core.inbox(m,3,Net_Journal_Ask),core.inbox(m,2,Net_Journal_Resync)}
        journal_receive(&toy.journal,inbox,index==0,own_connection(core.ref(&p.sessions[index])),w.time,&p.rewinds,true,0,&p.problems[index])
        if index==0 {
            if amount!=0 {toy_publish(toy,&w.outbox,w.time,amount)}
            // The view of the log a step that reads Net_Connections is handed: what came since it last ran.
            connections:=w.connections
            core.events_read(&connections.events,&p.seen)
            journal_connections(&toy.journal,core.ref(&connections))
            for event in connections.events.items {
                if event.kind==.Entered {journal_offer(&toy.journal,event.connection,TOY_KEY,true)}
            }
            toy_serve(toy,&w.outbox,w.time)
        } else {
            toy_follow(toy,w.time)
            journal_flush(&toy.journal,&w.outbox,w.time,core.ref(&p.sessions[index]))
        }
        net_tick_tail(ref,&p.sessions[index],&w.outbox,&w.made,&p.problems[index])
    }
    append(&p.sent,p.toys[0].journal.stats.bytes_sent-before)
    for &session in p.sessions {wire.host_update(&session.host,now)}
}

// Until the handshake is done: on UDP in real time.
@(private="file")
pair_connect :: proc(t:^testing.T,p:^Toy_Pair,tick:^u64) -> bool {
    endpoint:=p.udp?p.sockets[0].address:wire.address_memory(0)
    if !testing.expect_value(t,wire.host_connect(&p.sessions[1].host,endpoint),wire.Error.None) {return false}
    if !p.udp {
        for end:=tick^+200;p.sessions[1].status!=.Connected && tick^<end; {tick^+=1;pair_tick(p,tick^,0)}
        return testing.expect(t,p.sessions[1].status==.Connected,"the client connects")
    }
    start:=time.tick_now()
    for time.duration_seconds(time.tick_since(start))<2 && p.sessions[1].status!=.Connected {
        now:=wire.host_time(&p.sessions[0].host)
        for &session in p.sessions {wire.host_update(&session.host,now)}
        server_commands(&p.sessions[0],core.world_ref(&p.worlds[0],&p.info),nil,wire.host_poll(&p.sessions[0].host),&p.worlds[0].remote)
        client_commands(&p.sessions[1],core.world_ref(&p.worlds[1],&p.info),p.apps[1].assets,p.apps[1].allocator,wire.host_poll(&p.sessions[1].host))
        time.sleep(time.Millisecond)
    }
    p.base=wire.host_time(&p.sessions[0].host)
    return testing.expect(t,p.sessions[1].status==.Connected,"the UDP handshake ends within two seconds")
}

// The operations a server applies reach a client once and in its order, on a
// network that loses, duplicates and reorders datagrams and over UDP; one
// that joins late gets the base of what was applied before, sent within the
// budget of each tick, and the operations after it as any other.
@(test)
operations_reach_a_client_once_and_in_order_and_a_late_one_gets_the_base_within_the_budget :: proc(t:^testing.T) {
    Case :: struct {udp:bool,late:bool}
    for c in ([]Case{{false,false},{false,true},{true,false}}) {
        p:=new(Toy_Pair)
        defer free(p)
        defer pair_destroy(p)
        if !testing.expect(t,pair_init(t,p,c.udp)) {return}
        noise:=u64(9)
        for &b in p.toys[0].padding {b=u8(base.splitmix_next(&noise))}
        if !c.udp {for index in 0..<2 {wire.sim_endpoint_conditions(&p.network,index,{latency=0.05,jitter=0.01,loss=0.2,duplicate=0.1,reorder=0.1,reorder_delay=0.03})}}
        tick:u64
        // Before a late one connects, the server applies what only a base brings.
        if c.late {for tick<40 {tick+=1;pair_tick(p,tick,u32(tick))}}
        if !pair_connect(t,p,&tick) {return}
        published:=0
        for _ in 0..<600 {
            tick+=1
            amount:=u32(0)
            if published<60 && tick%3==0 {amount=u32(tick*7+1);published+=1}
            pair_tick(p,tick,amount)
            if published==60 && p.toys[1].value==p.toys[0].value && p.toys[1].journal.stats.received>=60 {break}
        }
        server,client:=&p.toys[0],&p.toys[1]
        testing.expectf(t,client.value==server.value,"%v: the client folds what the server did in its order: %x, server %x",c,client.value,server.value)
        testing.expectf(t,client.applied==60,"%v: each operation after the client joined applies once: %d",c,client.applied)
        testing.expectf(t,client.journal.stats.desyncs==0,"%v: nothing differs: %d",c,client.journal.stats.desyncs)
        if c.late {
            testing.expect(t,client.padding==server.padding,"the base brings what the server holds")
            testing.expect(t,client.journal.stats.parts_applied==1 && server.journal.stats.parts_sent==1,"one base")
            ticks:=0
            for bytes in p.sent {
                testing.expectf(t,bytes<=JOURNAL_BUDGET+JOURNAL_PIECE,"a tick sends %d bytes of parts",bytes)
                ticks+=int(bytes>0)
            }
            testing.expectf(t,ticks>1,"a base larger than the budget goes over %d ticks",ticks)
        }
        testing.expect_value(t,p.problems[0].count,0)
        testing.expect_value(t,p.problems[1].count,0)
    }
}

// A correction that brings the client back before operations it applied
// hands them again at the ticks they were first applied at, once each: the
// value it ends with is the one before it went back. One that arrives for a
// tick it already ran asks to go back to that tick.
@(test)
a_correction_hands_each_operation_again_at_its_tick_and_never_twice :: proc(t:^testing.T) {
    server,client:^Toy=new(Toy),new(Toy)
    defer {journal_free(&server.journal);journal_free(&client.journal);free(server);free(client)}
    server.journal.id,client.journal.id=TOY_JOURNAL,TOY_JOURNAL
    outbox:Net_Outbox
    rewinds:Net_Rewinds
    problems:core.Problems
    defer {core.value_free(&outbox,type_info_of(Net_Outbox));delete(rewinds.queue.items)}
    // The operations the server queued, as the client hears them.
    deliver :: proc(outbox:^Net_Outbox) -> Journal_Inbox {
        ops:=make([dynamic]core.Message(Net_Journal_Op),context.temp_allocator)
        for item in core.take(&outbox.queue) {
            op:core.Message(Net_Journal_Op)
            if item.type==Net_Journal_Op {mem.copy(&op.value,&outbox.bytes[item.at],size_of(op.value));append(&ops,op)}
        }
        clear(&outbox.bytes)
        return {ops={ops[:]}}
    }
    for tick in u64(1)..=6 {toy_publish(server,&outbox,{tick=tick},u32(tick))}
    journal_receive(&client.journal,deliver(&outbox),false,0,{tick=1},&rewinds,true,0,&problems)
    saved:=client.value
    for tick in u64(1)..=10 {toy_follow(client,{tick=tick})}
    present,applied:=client.value,client.applied
    testing.expect_value(t,applied,6)
    // Back to before tick 1, and every tick again.
    client.value=saved
    for tick in u64(1)..=10 {toy_follow(client,{tick=tick,resimulating=true})}
    testing.expect_value(t,client.value,present)
    testing.expect_value(t,client.applied,applied+6)
    // Back to between the third and the fourth.
    client.value=saved
    for tick in u64(1)..=3 {client.value=client.value*31+u32(tick)}
    for tick in u64(4)..=10 {toy_follow(client,{tick=tick,resimulating=true})}
    testing.expect_value(t,client.value,present)
    // An operation of a tick the client ran.
    toy_publish(server,&outbox,{tick=7},9)
    journal_receive(&client.journal,deliver(&outbox),false,0,{tick=11},&rewinds,true,0,&problems)
    asked:=core.take(&rewinds.queue)
    testing.expect(t,len(asked)==1 && asked[0]==7,"a late operation asks to go back to its tick")
    testing.expect_value(t,client.journal.stats.desyncs,0)
}

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private="file")
Memory_Limit :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
memory_limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    limit:=(^Memory_Limit)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if limit.remaining<=0 {return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// What a client receives with the memory ending at each request in turn: an
// operation that opens the log, one past its end and one before its start,
// and a part in one piece and in two. Each is left out with a problem and
// nothing stands half written; with memory enough each stands.
@(test)
what_a_client_receives_without_memory_is_left_out_and_reported :: proc(t:^testing.T) {
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    j:Journal
    defer journal_free(&j)
    j.id=TOY_JOURNAL
    // The event is in its queue before the memory ends.
    take :: proc(j:^Journal,inbox:Journal_Inbox,problems:^core.Problems,limit:^Memory_Limit,served:int) {
        rewinds:Net_Rewinds
        owner:=context.allocator
        limit.remaining=served
        context.allocator={memory_limit_proc,limit}
        journal_receive(j,inbox,false,0,{tick=1},&rewinds,false,0,problems)
        context.allocator=owner
        delete(rewinds.queue.items)
    }
    one :: proc(value:$T) -> core.Inbox(T) {
        items:=make([]core.Message(T),1,context.temp_allocator)
        items[0].value=value
        return {items}
    }
    for sequence in ([]u32{5,9,3}) {
        logged,refused:=false,false
        for served in 0..<8 {
            problems:core.Problems
            take(&j,{ops=one(Net_Journal_Op{journal=TOY_JOURNAL,op={key=TOY_KEY,sequence=sequence}})},&problems,&limit,served)
            if logged=len(j.streams)==1 && entry_at(&j.streams[0],sequence)!=nil;logged {break}
            refused=true
            testing.expectf(t,problems.count==1,"operation %d with %d requests served is left out without a problem",sequence,served)
        }
        testing.expectf(t,logged && refused,"operation %d: left out without memory, and logged with it",sequence)
    }
    s:=&j.streams[0]
    testing.expect(t,s.first==3 && len(s.log)==7 && s.newest==9)
    encoder:lz.Encoder
    defer lz.encoder_destroy(&encoder)
    for total in ([]u32{64,JOURNAL_PIECE+8}) {
        raw:=make([]u8,int(total),context.temp_allocator)
        for &b,i in raw {b=u8(i*13)}
        packed:=make([]u8,asset.pack_bound(int(total)),context.temp_allocator)
        size,_:=asset.pack(&encoder,asset.PACK_EDIT,raw,packed)
        stood,refused:=false,false
        for served in 0..<8 {
            problems:core.Problems
            parts:=len(s.parts)
            for offset,left:=0,served;offset==0 || offset<size;offset+=JOURNAL_PIECE {
                piece:=Net_Journal_Part{journal=TOY_JOURNAL,key=TOY_KEY,first=true,last=true,base=true,raw=total,total=u32(size),offset=u32(offset),count=u16(min(size-offset,JOURNAL_PIECE))}
                copy(piece.bytes[:],packed[offset:][:piece.count])
                take(&j,{parts=one(piece)},&problems,&limit,left)
                left=limit.remaining
                s=&j.streams[0]
            }
            if len(s.parts)>parts && s.parts[len(s.parts)-1].complete && !s.parts[len(s.parts)-1].broken {
                stood=testing.expectf(t,len(s.parts[len(s.parts)-1].bytes)==int(total) && problems.count==0,"part of %d bytes with %d requests served stands with a problem",total,served)
                break
            }
            refused=true
            testing.expectf(t,problems.count>0 || len(s.parts)>parts && s.parts[len(s.parts)-1].broken,"part of %d bytes with %d requests served is neither held nor told",total,served)
            for len(s.parts)>parts {delete(s.parts[len(s.parts)-1].bytes);pop(&s.parts)}
        }
        testing.expectf(t,stood && refused,"part of %d bytes: left out without memory, and it stands with it",total)
    }
}
