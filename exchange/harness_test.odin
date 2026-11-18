package exchange

import "core:fmt"
import "core:testing"
import "mirai:std/base"
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
    requests:int,          // requests a scripted peer got
    held:int,              // Late_Done: Dones owed
    held_at:f64,           // when they are sent
    held_host:^wire.Host,
    held_connection:wire.Connection,
}

// What a scripted peer does with the requests it gets.
@(private)
Test_Lie :: enum {
    None,
    Table,      // a table that does not match the address
    Piece,      // pieces that do not match the table
    Size,       // a size the last piece contradicts
    Single,     // for a blob of several pieces, a size of half a piece and the address as its table
    Huge,       // a table larger than the receiver holds
    Size_First, // Size, without the last piece
    Hold,       // nothing, and an unrelated Lack every 0.1 s
    Late_Done,  // nothing, and a Done for each request 5.1 s later
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
}

@(private) TEST_STEP :: 0.001

@(private)
test_world :: proc(t:^testing.T,w:^Test_World,name:string,nodes:int,game:=false,desc:=Desc{}) -> bool {
    w.folder=base.test_folder(t,name)
    if w.folder=="" {return false}
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
    if d.max_blob_bytes==0 {d.max_blob_bytes=64<<20}
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

// Steps until every address is complete at node k or seconds pass.
@(private)
test_until_complete :: proc(w:^Test_World,k:int,addresses:[]store.Hash,seconds:f64) -> bool {
    end:=w.now+seconds
    for w.now<end {
        test_step(w)
        all:=true
        for a in addresses {
            if !store.has(&w.nodes[k].s,a) {all=false;break}
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
        buffer:[MSG_LACK_BYTES]u8
        unrelated:=store.address_of_bytes(test_bytes(8,u64(w.now*1000)))
        wire.message_send(n.held_host,n.held_connection,w.channel+LANE_DATA,buffer[:encode_lack(buffer[:],unrelated,0,0)])
    }
}

// A scripted peer that answers requests from n.source and lies as n.lie says.
@(private)
test_liar :: proc(w:^Test_World,n:^Test_Node,h:^wire.Host,command:wire.Command) {
    if command.kind!=.Message || int(command.channel)!=w.channel+LANE_CONTROL || len(command.data)<MSG_REQUEST_HEAD || command.data[0]!=MSG_REQUEST {return}
    n.requests+=1
    if n.lie==.Hold || n.lie==.Late_Done {
        n.held_host,n.held_connection=h,command.connection
        if n.lie==.Late_Done {
            if n.held==0 {n.held_at=w.now+5.1}
            n.held+=1
        }
        return
    }
    r:=Reader{data=command.data[MSG_REQUEST_HEAD:],ok=true}
    count:=int(get_u16(command.data[1:]))
    out:=make([]u8,MSG_TABLE_HEAD+4096*32+store.PIECE_BYTES,context.temp_allocator)
    for _ in 0..<count {
        kind:=read_u8(&r)
        address:=read_hash(&r)
        first:=int(read_u32(&r))
        n_pieces:=int(read_u32(&r))
        size,size_error:=store.blob_size(n.source,address)
        if size_error!=.None {continue}
        if kind==0 {
            pieces,_:=store.blob_table(n.source,address,context.temp_allocator)
            told:=size
            #partial switch n.lie {
            case .Size,.Size_First: told=size-100
            case .Table: pieces[1][3]~=0x40
            case .Single:
                told=store.PIECE_BYTES/2
                pieces=pieces[:1]
                pieces[0]=address
            case .Huge:
                told=128<<20
                pieces=make([]store.Hash,store.piece_count(told),context.temp_allocator)
            }
            wr:=Writer{data=out}
            write_u8(&wr,MSG_TABLE)
            write_bytes(&wr,address[:])
            write_u64(&wr,u64(told))
            for &p in pieces {write_bytes(&wr,p[:])}
            wire.message_send(h,command.connection,w.channel+LANE_DATA,out[:wr.n])
            if n.lie==.Single {
                encode_piece_head(out,address,0)
                piece:=out[MSG_PIECE_HEAD:][:told]
                store.read(n.source,address,0,piece)
                wire.message_send(h,command.connection,w.channel+LANE_DATA,out[:MSG_PIECE_HEAD+int(told)])
                continue
            }
        }
        last:=store.piece_count(size)-1
        for index in first..<min(first+n_pieces,last+1) {
            bytes:=store.piece_size(size,index)
            if n.lie==.Size_First && index==last {continue}
            if n.lie==.Size && index==last {bytes-=100}
            encode_piece_head(out,address,u32(index))
            piece:=out[MSG_PIECE_HEAD:][:bytes]
            store.read(n.source,address,i64(index)*store.PIECE_BYTES,piece)
            if n.lie==.Piece {piece[7]~=1}
            wire.message_send(h,command.connection,w.channel+LANE_DATA,out[:MSG_PIECE_HEAD+bytes])
        }
    }
    done:=[1]u8{MSG_DONE}
    wire.message_send(h,command.connection,w.channel+LANE_DATA,done[:])
}
