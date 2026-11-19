package exchange

import "core:fmt"
import "core:testing"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:store"
import wire "mirai:net"

// Peers of one simulated network, each with its store and exchange and up to
// two hosts, stepped together at the worker's cadence of 1 ms.
@(private)
Test_Node :: struct {
    s:store.Store,
    x:Exchange,
    open:bool, // the exchange runs: a scripted peer has none
    hosts:[2]^wire.Host,
    endpoints:[2]int,
    host_count:int,
    script:proc(w:^Test_World,n:^Test_Node,h:^wire.Host,command:wire.Command), // a peer that answers by hand
    lie:Test_Lie,
    source:^store.Store, // what the scripted peer serves
    game:Test_Game,
    requests:int,          // asks a scripted peer got
    held:int,              // Late_Done: Dones owed
    held_at:f64,           // when they are sent
    held_host:^wire.Host,
    held_connection:wire.Connection,
}

// What a scripted peer does with the asks it gets.
@(private)
Test_Lie :: enum {
    None,
    Bytes,       // data chunks with a byte flipped
    Over_Budget, // every descendant of each entry, whatever its budget
    Hold,        // nothing, and an unrelated Lack every 0.1 s
    Late_Done,   // nothing, and a Done for each ask 5.1 s later
}

// A 60 Hz unreliable message from the server to the client on channel 0.
@(private)
Test_Game :: struct {sent,got:int,mean,worst,latency,since:f64}

@(private)
Test_World :: struct {
    sim:wire.Sim_Network,
    now:f64,
    nodes:[4]Test_Node,
    count,endpoints:int,
    channels:[]wire.Channel_Desc,
    channel:int,
    folder:string,
    js:jobs.Job_System, // the test thread is its owner: every exchange runs its jobs there
}

@(private) TEST_STEP :: 0.001

@(private)
test_world :: proc(t:^testing.T,w:^Test_World,name:string,nodes:int,game:=false,desc:=Desc{}) -> bool {
    w.folder=base.test_folder(t,name)
    if w.folder=="" {return false}
    if !testing.expect(t,jobs.system_init(&w.js,{threads=2})) {return false}
    wire.sim_network_init(&w.sim,{seed=7,endpoints=8,packets=1<<16})
    ours:=channels()
    if game {
        w.channels=make([]wire.Channel_Desc,3,context.temp_allocator)
        w.channels[0]={kind=.Unreliable}
        w.channels[1],w.channels[2]=ours[0],ours[1]
        w.channel=1
    } else {
        w.channels=make([]wire.Channel_Desc,2,context.temp_allocator)
        w.channels[0],w.channels[1]=ours[0],ours[1]
    }
    w.count=nodes
    for k in 0..<nodes {
        if !testing.expect(t,test_node_open(w,k,desc)) {return false}
    }
    return true
}

@(private)
test_node_open :: proc(w:^Test_World,k:int,desc:=Desc{}) -> bool {
    n:=&w.nodes[k]
    error:store.Error
    n.s,error=store.open(fmt.tprintf("%s/node-%d",w.folder,k))
    if error!=.None {return false}
    d:=desc
    d.store,d.channel=&n.s,w.channel
    // Opt-in: -define:EXCHANGE_TEST_JOBS=true runs every exchange's jobs on the
    // job system; by default they run on the pump, so virtual time steps fast.
    if #config(EXCHANGE_TEST_JOBS,false) {d.worker={system=&w.js,worker=jobs.OWNER}}
    if d.peers==0 {d.peers=4}
    n.open=init(&n.x,d)==.None
    return n.open
}

@(private)
test_node_close :: proc(n:^Test_Node) {
    if n.open {destroy(&n.x)}
    store.close(&n.s)
    n.open=false
}

@(private)
test_world_destroy :: proc(w:^Test_World) {
    for &n in w.nodes[:w.count] {
        test_node_close(&n)
        for h in n.hosts[:n.host_count] {wire.host_destroy(h);free(h)}
    }
    wire.sim_network_destroy(&w.sim)
    jobs.system_destroy(&w.js)
}

@(private)
test_host :: proc(w:^Test_World,k:int,mode:wire.Mode) -> ^wire.Host {
    n:=&w.nodes[k]
    h:=new(wire.Host)
    endpoint:=w.endpoints
    w.endpoints+=1
    if wire.host_init(h,{mode=mode,transport=wire.sim_endpoint_transport(&w.sim,endpoint),channels=w.channels,protocol_id=91,seed=u64(100+endpoint)})!=.None {
        free(h)
        return nil
    }
    n.hosts[n.host_count]=h
    n.endpoints[n.host_count]=endpoint
    n.host_count+=1
    return h
}

// Connects the client host of node k to the server host at endpoint; false if it does not within 5 s.
@(private)
test_connect :: proc(w:^Test_World,client:^wire.Host,endpoint:int) -> bool {
    wire.host_connect(client,wire.address_memory(endpoint))
    for _ in 0..<5000 {
        test_step(w)
        if stats,ok:=wire.connection_stats(client,client.connection_handles[0]);ok && client.connection_handles[0]!=0 {
            _=stats
            return true
        }
    }
    return false
}

@(private)
test_step :: proc(w:^Test_World,steps:=1) {
    for _ in 0..<steps {
        w.now+=TEST_STEP
        wire.sim_network_advance(&w.sim,w.now)
        for &n in w.nodes[:w.count] {
            for h in n.hosts[:n.host_count] {
                for command in wire.host_poll(h) {test_command(w,&n,h,command)}
                if h.desc.mode==.Server && w.channel==1 {test_game_send(w,&n,h)}
            }
            if n.script!=nil {test_script_tick(w,&n)}
            if n.open {update(&n.x,w.now)}
            for h in n.hosts[:n.host_count] {wire.host_update(h,w.now)}
        }
        // The jobs end within the step, so virtual time does not run ahead of them.
        for &n in w.nodes[:w.count] {
            if n.open {work_wait_all(&n.x)}
        }
    }
}

@(private)
test_command :: proc(w:^Test_World,n:^Test_Node,h:^wire.Host,command:wire.Command) {
    if n.script!=nil {
        n.script(w,n,h,command)
        return
    }
    if !n.open {return}
    #partial switch command.kind {
    case .Connected: peer_add(&n.x,h,command.connection)
    case .Disconnected: peer_remove(&n.x,h,command.connection)
    case .Message:
        if receive(&n.x,h,command) {return}
        if command.channel==0 && len(command.data)==8 {
            stamp:=(^f64)(raw_data(command.data))^
            if stamp<n.game.since {return}
            late:=w.now-stamp-n.game.latency
            n.game.mean+=late
            n.game.worst=max(n.game.worst,late)
            n.game.got+=1
        }
    }
}

@(private)
test_game_send :: proc(w:^Test_World,n:^Test_Node,h:^wire.Host) {
    if int(w.now*1000)%16!=0 {return}
    for c in h.connection_handles {
        if c==0 {continue}
        stamp:=w.now
        if wire.message_send(h,c,0,([^]u8)(&stamp)[:8])==.None && stamp>=n.game.since {n.game.sent+=1}
    }
}

@(private)
test_bytes :: proc(size:int,seed:u64) -> []u8 {
    data:=make([]u8,size,context.temp_allocator)
    h:=base.Hostile{state=seed}
    for &b in data {b=u8(base.hostile_next(&h))}
    return data
}

// Whether node k holds the object at address whole: as its want says once
// committed, or read whole from its store.
@(private)
test_here :: proc(n:^Test_Node,address:store.Hash) -> bool {
    if n.open {
        if p,known:=progress(&n.x,address);known {return p.state==.Complete}
    }
    _,whole:=test_read(&n.s,address)
    return whole
}

// Steps until every address is complete at node k or seconds pass.
@(private)
test_until_complete :: proc(w:^Test_World,k:int,addresses:[]store.Hash,seconds:f64) -> bool {
    end:=w.now+seconds
    for w.now<end {
        test_step(w)
        all:=true
        for a in addresses {
            if !test_here(&w.nodes[k],a) {all=false;break}
        }
        if all {return true}
    }
    return false
}

@(private)
test_state :: proc(x:^Exchange,address:store.Hash) -> State {
    p,_:=progress(x,address)
    return p.state
}

@(private)
test_script_tick :: proc(w:^Test_World,n:^Test_Node) {
    if n.lie==.Late_Done && n.held>0 && w.now>=n.held_at {
        done:=[1]u8{MSG_DONE}
        for _ in 0..<n.held {wire.message_send(n.held_host,n.held_connection,w.channel+LANE_DATA,done[:])}
        n.held=0
    }
    if n.lie==.Hold && n.held_host!=nil && int(w.now*1000)%100==0 {
        buffer:[MSG_ADDRESS_BYTES]u8
        unrelated:=store.address_of_bytes(test_bytes(8,u64(w.now*1000)))
        wire.message_send(n.held_host,n.held_connection,w.channel+LANE_DATA,buffer[:encode_address(buffer[:],MSG_LACK,unrelated)])
    }
}

// A scripted peer that answers asks from n.source and lies as n.lie says.
@(private)
test_liar :: proc(w:^Test_World,n:^Test_Node,h:^wire.Host,command:wire.Command) {
    if command.kind!=.Message || int(command.channel)!=w.channel+LANE_CONTROL || len(command.data)<MSG_ASK_HEAD || command.data[0]!=MSG_ASK {return}
    n.requests+=1
    if n.lie==.Hold || n.lie==.Late_Done {
        n.held_host,n.held_connection=h,command.connection
        if n.lie==.Late_Done {
            if n.held==0 {n.held_at=w.now+5.1}
            n.held+=1
        }
        return
    }
    Script :: struct {w:^Test_World,n:^Test_Node,h:^wire.Host,c:wire.Connection,out:[]u8,sent:i64,budget:i64}
    send_chunk :: proc(sc:^Script,address:store.Hash,bytes:[]u8) {
        encode_chunk_head(sc.out,address,store.CODEC_NONE,len(bytes))
        copy(sc.out[MSG_CHUNK_HEAD:],bytes)
        if sc.n.lie==.Bytes {
            if _,e:=store.node_parse(bytes);e!=.None {sc.out[MSG_CHUNK_HEAD+len(bytes)/2]~=1}
        }
        wire.message_send(sc.h,sc.c,sc.w.channel+LANE_DATA,sc.out[:MSG_CHUNK_HEAD+len(bytes)])
    }
    descend :: proc(sc:^Script,bytes:[]u8,depth:int) -> bool {
        node,error:=store.node_parse(bytes)
        if error!=.None || depth>store.NODE_LEVEL_MAX {return true}
        held:=make([]u8,len(bytes),context.temp_allocator)
        copy(held,bytes)
        node,_=store.node_parse(held)
        buffer:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
        for e in node.entries {
            child,read_error:=store.chunk_read(sc.n.source,e.address,buffer)
            if read_error!=.None {return false}
            if sc.n.lie!=.Over_Budget && sc.sent+i64(len(child))>sc.budget {return false}
            sc.sent+=i64(len(child))
            send_chunk(sc,e.address,child)
            if node.level>0 && !descend(sc,child,depth+1) {return false}
        }
        return true
    }
    r:=Reader{data=command.data[MSG_ASK_HEAD:],ok=true}
    count:=int(get_u16(command.data[1:]))
    sc:=Script{w=w,n=n,h=h,c=command.connection,out=make([]u8,MSG_CHUNK_MAX,context.temp_allocator)}
    buffer:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
    for _ in 0..<count {
        address:=read_hash(&r)
        sc.budget,sc.sent=i64(read_u32(&r)),0
        bytes,error:=store.chunk_read(n.source,address,buffer)
        if error!=.None {
            lack:[MSG_ADDRESS_BYTES]u8
            wire.message_send(h,command.connection,w.channel+LANE_DATA,lack[:encode_address(lack[:],MSG_LACK,address)])
            continue
        }
        send_chunk(&sc,address,bytes)
        if sc.budget>0 || n.lie==.Over_Budget {descend(&sc,bytes,0)}
    }
    done:=[1]u8{MSG_DONE}
    wire.message_send(h,command.connection,w.channel+LANE_DATA,done[:])
}
