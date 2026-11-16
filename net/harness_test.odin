package mirai_net

import "core:mem"
import "mirai:std/base"
import "mirai:std/serial"

// Several hosts on one simulated network, advanced together in fixed steps.
@(private)
Test_World :: struct {
    sim:Sim_Network,
    hosts:[80]^Host,
    count:int,
    now:f64,
}
@(private) TEST_STEP :: 1.0/60

// The tick of a client kept as the engine keeps it: each call adds the time
// since the last one, faster or slower by the dilation its clock asked for,
// and gives the ticks that time completes.
@(private)
Test_Ticks :: struct {
    local:f64,    // the client's tick, with fraction
    last:i64,     // the last tick handed out
    dilation:f64,
    now:f64,
    started:bool,
}
@(private)
test_ticks :: proc(x:^Test_Ticks,h:^Host,now:f64) -> (first:u32,steps:int) {
    if x.started {x.local+=(now-x.now)*f64(h.desc.tick_rate)*max(1+x.dilation,0)}
    x.now,x.started=now,true
    shift,dilation:=clock_advance(h,now,x.local)
    x.local+=f64(shift)
    x.last+=shift
    x.dilation=dilation
    first,steps=u32(x.last+1),int(max(i64(x.local)-x.last,0))
    x.last+=i64(steps)
    return
}

@(private)
test_world_init :: proc(w:^Test_World,endpoints:int,seed:u64=1,packets:=4096) {
    w^={}
    sim_network_init(&w.sim,{seed=seed,endpoints=endpoints,packets=packets})
}
@(private)
test_world_destroy :: proc(w:^Test_World) {
    for host in w.hosts[:w.count] {host_destroy(host);free(host)}
    sim_network_destroy(&w.sim)
}
// The host takes the next endpoint of the network: the first one added is endpoint 0.
@(private)
test_host :: proc(w:^Test_World,desc:Host_Desc) -> ^Host {
    desc:=desc
    desc.transport=sim_endpoint_transport(&w.sim,w.count)
    if desc.seed==0 {desc.seed=u64(1000+w.count)}
    if desc.protocol_id==0 {desc.protocol_id=77}
    host:=new(Host)
    if host_init(host,desc)!=.None {free(host);return nil}
    w.hosts[w.count]=host
    w.count+=1
    return host
}
@(private)
test_step :: proc(w:^Test_World,steps:=1) {
    for _ in 0..<steps {
        w.now+=TEST_STEP
        sim_network_advance(&w.sim,w.now)
        for host in w.hosts[:w.count] {host_update(host,w.now)}
    }
}
// Steps until the client reports a connection or gives up; returns both handles.
@(private)
test_connect :: proc(w:^Test_World,server,client:^Host,limit:=600) -> (on_server,on_client:Connection) {
    host_connect(client,address_memory(0))
    for _ in 0..<limit {
        test_step(w)
        for command in host_poll(server) {
            if command.kind==.Connected {on_server=command.connection}
        }
        for command in host_poll(client) {
            if command.kind==.Connected {on_client=command.connection}
            if command.kind==.Disconnected {return}
        }
        if on_server!=0 && on_client!=0 {return}
    }
    return
}

// A transport that hands the host datagrams damaged at random, with the
// checksum made valid again so they reach the parsers behind it.
@(private)
Test_Fuzz :: struct {inner:Transport,host:^Host,rng:u64,rate:f64,mutated:int,only:Address}
@(private)
test_fuzz_transport :: proc(f:^Test_Fuzz) -> Transport {
    return {f,proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
        f:=(^Test_Fuzz)(data)
        return f.inner.send(f.inner.data,to,bytes)
    },proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
        f:=(^Test_Fuzz)(data)
        size,from,ok=f.inner.receive(f.inner.data,buffer)
        if !ok || size<8 || (f.only.kind!=.None && from!=f.only) || rng_unit(&f.rng)>=f.rate {return}
        plain,opened:=test_unseal(f.host,buffer[:size],from)
        if !opened {return}
        f.mutated+=1
        switch base.splitmix_next(&f.rng)%4 {
        case 0,1:
            flips:=1+base.splitmix_next(&f.rng)%8
            for _ in 0..<flips {
                bit:=base.splitmix_next(&f.rng)%u64(plain*8)
                buffer[bit>>3]~=1<<(bit&7)
            }
        case 2:
            plain=1+int(base.splitmix_next(&f.rng)%u64(plain))
        case 3:
            plain=2+int(base.splitmix_next(&f.rng)%u64(len(buffer)-TAG_BYTES-2))
            for &b in buffer[1:plain] {b=u8(base.splitmix_next(&f.rng))}
        }
        size=test_reseal(f.host,buffer,plain,from)
        return
    }}
}
@(private)
test_packet_data :: proc(bytes:[]u8) -> bool {return bytes[0]==u8(Packet_Type.Data) || bytes[0]==u8(Packet_Type.Disconnect)}
// What comes before the checksum or the tag of a datagram, deciphered in place as the host would.
@(private)
test_unseal :: proc(h:^Host,bytes:[]u8,from:Address) -> (plain:int,ok:bool) {
    if !test_packet_data(bytes) {return len(bytes)-CHECKSUM_BYTES,true}
    p:=peer_find(&h.back,from)
    plain=len(bytes)-TAG_BYTES
    if p==nil || p.state!=.Connected || plain<DATA_HEADER {return}
    counter:=counter_expand(p.recv_counter,u16(bytes[1])|u16(bytes[2])<<8) or_return
    if counter/h.back.secure.rekey_interval!=p.secure.receive_epoch {return}
    ok=aead_open(&p.secure.receive,counter,bytes[:DATA_HEADER],bytes[DATA_HEADER:plain],bytes[plain:])
    return
}
// Makes the first plain bytes of the buffer a datagram the host takes for authentic, and returns its size.
@(private)
test_reseal :: proc(h:^Host,buffer:[]u8,plain:int,from:Address) -> int {
    p:=peer_find(&h.back,from)
    data:=test_packet_data(buffer)
    if data {
        if p!=nil && p.state==.Connected && plain>=DATA_HEADER {
            counter,valid:=counter_expand(p.recv_counter,u16(buffer[1])|u16(buffer[2])<<8)
            if valid && counter/h.back.secure.rekey_interval==p.secure.receive_epoch {
                aead_seal(&p.secure.receive,counter,buffer[:DATA_HEADER],buffer[DATA_HEADER:plain],buffer[plain:][:TAG_BYTES])
            }
        }
        return plain+TAG_BYTES
    }
    checksum_write(buffer[:plain+CHECKSUM_BYTES],h.back.key)
    return plain+CHECKSUM_BYTES
}
// Seals a handshake datagram written from buffer[1] on, as a host does.
@(private)
test_handshake :: proc(buffer:[]u8,w:^serial.Bit_Writer,key:u64,pad:=0) -> []u8 {
    total:=1+len(serial.bit_writer_flush(w))+CHECKSUM_BYTES
    if total<pad {
        mem.zero_slice(buffer[total-CHECKSUM_BYTES:pad])
        total=pad
    }
    checksum_write(buffer[:total],key)
    return buffer[:total]
}

@(private) Test_Team :: enum u8 {None,Red=3,Blue=7}
@(private) Test_Flag :: enum u8 {Burning,Frozen,Hidden}
@(private)
Test_Transform :: struct {
    position:[3]f32 `mirai:"precision=0.01"`,
    rotation:quaternion128 `mirai:"bits=12"`,
    velocity:[3]f32 `mirai:"precision=0.05"`,
}
@(private)
Test_Vitals :: struct {
    health:i32 `mirai:"min=0,max=1000"`,
    armor:u8,
    team:Test_Team,
    flags:bit_set[Test_Flag;u8],
    alive:bool,
    target:base.Entity,
    name:[16]u8 `mirai:"text"`,
    cache:u32 `mirai:"local"`,
    energy:f32 `mirai:"min=0,max=100,precision=0.1"`,
    raw:f32,
    big:u64,
    small:i16 `mirai:"bits=5"`,
}
@(private)
Test_Secret :: struct {ammo:u16,stamina:f32 `mirai:"precision=0.01"`}
@(private)
Test_Input :: struct {move:[2]f32 `mirai:"min=-1,max=1,precision=0.01"`,buttons:u8}
@(private)
Test_Hit :: struct {damage:i32,from:base.Entity,point:[3]f32 `mirai:"precision=0.01"`}
// 6 KB, 4 KB of it an array of bytes: more than a datagram carries.
@(private)
Test_Big :: struct {values:[511]u32,count:u32,bytes:[4096]u8}

@(private)
Test_Protocol :: struct {
    schema:serial.Schema,
    protocol:Protocol,
    actor,prop:Type_Id,
    hit,ping,use,notice,big:Event_Id,
}
// Actor: transform, vitals and an owner-only fragment. Prop: a transform.
@(private)
test_protocol_init :: proc(tp:^Test_Protocol) {
    serial.schema_init(&tp.schema)
    protocol_init(&tp.protocol)
    transform,_:=serial.schema_add(&tp.schema,Test_Transform)
    vitals,_:=serial.schema_add(&tp.schema,Test_Vitals)
    secret,_:=serial.schema_add(&tp.schema,Test_Secret)
    input,_:=serial.schema_add(&tp.schema,Test_Input)
    hit,_:=serial.schema_add(&tp.schema,Test_Hit)
    big,_:=serial.schema_add(&tp.schema,Test_Big)
    tp.actor,_=type_register(&tp.protocol,"Actor",{{schema=&tp.schema,type=transform},{schema=&tp.schema,type=vitals},{schema=&tp.schema,type=secret,condition=.Owner}})
    tp.prop,_=type_register(&tp.protocol,"Prop",{{schema=&tp.schema,type=transform}})
    tp.hit,_=event_register(&tp.protocol,"Hit",&tp.schema,hit,{.Reliable})
    tp.ping,_=event_register(&tp.protocol,"Ping",&tp.schema,hit,{.From_Client})
    tp.use,_=event_register(&tp.protocol,"Use",&tp.schema,hit,{.Reliable,.From_Client,.Owner_Only})
    tp.notice,_=event_register(&tp.protocol,"Notice",&tp.schema,hit,{.Reliable,.Held})
    tp.big,_=event_register(&tp.protocol,"Big",&tp.schema,big,{.Reliable,.From_Client})
    input_register(&tp.protocol,&tp.schema,input)
    protocol_seal(&tp.protocol)
}
@(private)
test_protocol_destroy :: proc(tp:^Test_Protocol) {
    protocol_destroy(&tp.protocol)
    serial.schema_destroy(&tp.schema)
}
// True when the client's replica of an object holds exactly the words the server holds, for the fields it receives.
@(private)
test_replica_matches :: proc(server,client:^Host,object:Object,owner:bool) -> bool {
    s,c:=&server.back.repl,&client.back.repl
    o:=int(base.handle_index(base.Handle(object)))
    if s.live[o]!=1 || c.live[o]!=1 || c.generation[o]!=s.generation[o] || c.type[o]!=s.type[o] {return false}
    if !pool_has(&s.states,o) || !pool_has(&c.states,o) {return false}
    type:=&s.protocol.types[s.type[o]]
    return state_diff(type,pool_words(&s.states,o),pool_words(&c.states,o),owner?type.owner:type.others)==0
}
// True when every baseline a link of the server holds as active is what the client kept in that slot, for the
// fields it receives: the server never deltas against a state the client does not have.
@(private)
test_baselines_match :: proc(server,client:^Host,connection:Connection) -> bool {
    s,c:=&server.back.repl,&client.back.repl
    p:=peer_from(server,connection)
    if p==nil {return false}
    pr:=&p.repl
    for o in 0..<s.high {
        active:=int(pr.active[o])
        if pr.link[o]!=.Created || active==0 {continue}
        if c.live[o]!=1 || !pool_has(&c.bases,o*2+active-1) || pr.base[active-1][o]==0 {return false}
        type:=&s.protocol.types[s.type[o]]
        mask:=s.owner[o]==connection?type.owner:type.others
        if state_diff(type,pool_words(&s.bases,int(pr.base[active-1][o]-1)),pool_words(&c.bases,o*2+active-1),mask)!=0 {return false}
    }
    return true
}
// True when each shared baseline of the server counts exactly the links that hold it, and only those have a block.
@(private)
test_baselines_counted :: proc(server:^Host) -> bool {
    r:=&server.back.repl
    refs:=make([]u16,len(r.base_refs))
    defer delete(refs)
    for &p in server.back.peers {
        for o in 0..<r.high {
            for slot in 0..<2 {
                if base:=p.repl.base[slot][o];base!=0 {refs[base-1]+=1}
            }
        }
    }
    held:=0
    for count,id in refs {
        if count!=r.base_refs[id] || (count>0)!=pool_has(&r.bases,id) {return false}
        held+=int(count>0)
    }
    return held+r.base_free_count==len(r.base_refs)
}
