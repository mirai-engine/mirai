package exchange

import "core:testing"
import "mirai:std/base"
import "mirai:store"
import wire "mirai:net"

@(private)
test_message :: proc(parts:..[]u8) -> []u8 {
    n:=0
    for p in parts {n+=len(p)}
    out:=make([]u8,n,context.temp_allocator)
    at:=0
    for p in parts {copy(out[at:],p);at+=len(p)}
    return out
}

@(private)
test_le :: proc(v:u64,bytes:int) -> []u8 {
    out:=make([]u8,bytes,context.temp_allocator)
    for i in 0..<bytes {out[i]=u8(v>>(8*uint(i)))}
    return out
}

@(private)
test_name :: proc(s:string) -> []u8 {return test_message({u8(len(s))},transmute([]u8)s)}

@(private)
test_ask :: proc(entries:..store.Hash) -> []u8 {
    out:=test_message({MSG_ASK},test_le(u64(len(entries)),2))
    for e in entries {
        e:=e
        out=test_message(out,e[:],test_le(0,4))
    }
    return out
}

@(private)
test_chunk :: proc(address:store.Hash,codec:u8,raw:int,bytes:[]u8) -> []u8 {
    address:=address
    return test_message({MSG_CHUNK},address[:],{codec},test_le(u64(raw),4),bytes)
}

// Every message a peer could send is validated: the malformed ones mark the
// peer bad, the well formed ones nobody asked for are ignored, and a peer
// cannot queue more than BATCHES asks. None crashes, and random bytes on
// both channels do not either.
@(test)
hostile_messages_are_refused_without_a_crash :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-hostile",2,desc={expose=test_expose_lib}) {return}
    server:=test_host(&w,0,.Server)
    client:=test_host(&w,1,.Client)
    if !testing.expect(t,test_connect(&w,client,w.nodes[0].endpoints[0])) {return}
    x:=&w.nodes[0].x
    c:=server.connection_handles[0]
    if c==0 {c=server.connection_handles[1]}
    data:=test_bytes(3*store.CHUNK_MAX+5,1)
    root:=test_object(t,&w.nodes[0].s,data)
    other:=store.address_of_bytes(test_bytes(5,2))
    want(x,other)
    zero:store.Hash
    big:=make([]u8,store.CHUNK_MAX+1,context.temp_allocator)
    Case :: struct {lane:int,data:[]u8,bad:bool}
    cases:=[]Case{
        {LANE_CONTROL,nil,true},
        {LANE_CONTROL,{99},true},
        {LANE_DATA,{99},true},
        {LANE_CONTROL,{MSG_ASK},true},
        {LANE_CONTROL,test_ask(),true},
        {LANE_CONTROL,test_message({MSG_ASK},test_le(ASK_ENTRIES+1,2)),true},
        {LANE_CONTROL,test_message(test_ask(root),{0}),true},
        {LANE_CONTROL,test_message({MSG_BAD},root[:5]),true},
        {LANE_CONTROL,test_message({MSG_BAD},root[:],{0}),true},
        {LANE_CONTROL,test_message({MSG_REF_GET},test_name("lib")),true},
        {LANE_CONTROL,test_message({MSG_REF_GET},test_name("Lib"),test_name("a")),true},
        {LANE_CONTROL,test_message({MSG_REF_GET},test_name("lib"),{200},big[:10]),true},
        {LANE_CONTROL,test_message({MSG_NAMES_GET},test_name("lib"),test_name("../x")),true},
        {LANE_CONTROL,test_message({MSG_REF},test_name("lib"),test_name("a"),{2},zero[:]),true},
        {LANE_CONTROL,test_message({MSG_NAMES},test_name("lib"),{0},{0},test_le(3,2)),true},
        {LANE_CONTROL,test_message({MSG_NAMES},test_name("lib"),{0},{0},test_le(1,2),test_name("a")),true},
        {LANE_DATA,test_message({MSG_CHUNK},root[:]),true},
        {LANE_DATA,test_chunk(root,1,10,big[:10]),true},
        {LANE_DATA,test_chunk(root,0,11,big[:10]),true},
        {LANE_DATA,test_chunk(root,0,0,nil),true},
        {LANE_DATA,test_chunk(root,0,len(big),big),true},
        {LANE_DATA,test_message({MSG_LACK},root[:4]),true},
        {LANE_DATA,test_message({MSG_LACK},root[:],{0}),true},
        {LANE_DATA,test_message({4},root[:],root[:]),true}, // an unknown kind
        {LANE_DATA,{MSG_DONE},true},
        {LANE_DATA,{MSG_DONE,0},true},
        // Nobody asked: ignored, counted against the peer.
        {LANE_DATA,test_chunk(root,0,10,big[:10]),false},
        {LANE_DATA,test_chunk(other,0,5,test_bytes(5,2)),false},
        {LANE_DATA,test_message({MSG_LACK},other[:]),false},
        {LANE_CONTROL,test_message({MSG_REF},test_name("lib"),test_name("a"),{1},zero[:]),false},
        {LANE_CONTROL,test_message({MSG_NAMES},test_name("lib"),{0},{0},test_le(0,2)),false},
        {LANE_CONTROL,test_message({MSG_REF_GET},test_name("secret"),test_name("a")),false},
        {LANE_CONTROL,test_message({MSG_NAMES_GET},test_name("lib"),{0}),false},
        {LANE_CONTROL,test_message({MSG_BAD},other[:]),false},
        {LANE_CONTROL,test_ask(root,zero),false},
    }
    for c_,k in cases {
        receive(x,server,{kind=.Message,channel=u8(w.channel+c_.lane),connection=c,data=c_.data})
        p,_:=peer_progress(x,server,c)
        testing.expectf(t,p.bad==c_.bad,"case %d: bad %v",k,p.bad)
        if p.bad {
            peer_remove(x,server,c)
            peer_add(x,server,c)
        }
    }
    q,_:=progress(x,other)
    testing.expect(t,q.state==.Asking && q.total==-1,"an unasked chunk is not taken")
    // A message that arrives in pieces past what this end holds.
    piece:=make([]u8,wire.PIECE_BYTES,context.temp_allocator)
    piece[0]=MSG_NAMES
    for _ in 0..<8 {receive(x,server,{kind=.Message,channel=u8(w.channel+LANE_CONTROL),connection=c,data=piece,more=true})}
    receive(x,server,{kind=.Message,channel=u8(w.channel+LANE_CONTROL),connection=c,data=piece[:1]})
    p,_:=peer_progress(x,server,c)
    testing.expect(t,p.bad,"an oversized message marks the peer")
    peer_remove(x,server,c)
    peer_add(x,server,c)
    // At most BATCHES asks queue; the next is refused, not served.
    full:=make([]store.Hash,ASK_ENTRIES,context.temp_allocator)
    for &e in full {e=root}
    ask:=test_ask(..full)
    for _ in 0..<BATCHES+1 {receive(x,server,{kind=.Message,channel=u8(w.channel+LANE_CONTROL),connection=c,data=ask})}
    p,_=peer_progress(x,server,c)
    testing.expect(t,!p.bad && p.refused==1,"an ask past the ones in flight is refused")
    // Random bytes on both channels.
    h:=base.Hostile{state=5}
    noise:=make([]u8,600,context.temp_allocator)
    for _ in 0..<4000 {
        n:=base.hostile_int(&h,len(noise))
        for &b in noise[:n] {b=u8(base.hostile_next(&h))}
        if n>0 && base.hostile_int(&h,2)==0 {noise[0]=u8(1+base.hostile_int(&h,6))}
        receive(x,server,{kind=.Message,channel=u8(w.channel+base.hostile_int(&h,CHANNELS)),connection=c,data=noise[:n],more=base.hostile_int(&h,8)==0})
        if p,_=peer_progress(x,server,c);p.bad {
            peer_remove(x,server,c)
            peer_add(x,server,c)
        }
    }
    test_step(&w,500)
    testing.expect(t,!test_here(&w.nodes[0],other),"nothing unverified completes a want")
}

// Trees a peer holds whose chunks hash to their addresses but do not hold
// together: a node of the wrong level, or whose bytes disagree with its
// parent, or a wanted root that is no node, fails the want.
@(test)
hostile_trees_fail_the_want_without_a_crash :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_pair(t,&w,"exchange-trees") {return}
    s:=&w.nodes[0].s
    put :: proc(s:^store.Store,bytes:[]u8) -> store.Hash {
        address:=store.address_of_bytes(bytes)
        store.chunk_put(s,address,bytes)
        return address
    }
    node :: proc(s:^store.Store,level:int,entries:[]store.Entry,groups:[]store.Group={}) -> (store.Hash,u64) {
        buffer:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
        bytes,_:=store.node_encode(buffer,level,entries,groups)
        total:u64
        for e in entries {total+=e.size}
        return put(s,bytes),total
    }
    junk:=test_bytes(300,3)
    nonsense:=put(s,junk)
    data:=test_bytes(1000,4)
    leaf_chunk:=put(s,data)
    leaf,leaf_total:=node(s,0,{{address=leaf_chunk,size=1000}})
    // A level-2 root over a node of level 0.
    skipped,_:=node(s,2,{{address=leaf,size=leaf_total}},{{count=1}})
    // A level-1 root whose entry says more bytes than its child holds.
    wrong_size,_:=node(s,1,{{address=leaf,size=leaf_total+1}},{{count=1}})
    // A leaf whose chunk is shorter than its entry says.
    short,_:=node(s,0,{{address=leaf_chunk,size=999}},{{count=1}})
    store.commit(s)
    x:=&w.nodes[1].x
    for a in ([]store.Hash{nonsense,skipped,wrong_size,short}) {want(x,a)}
    test_step(&w,1000)
    for a in ([]store.Hash{nonsense,skipped,wrong_size,short}) {
        p,_:=progress(x,a)
        testing.expectf(t,p.state==.Failed && p.store_error==.Corrupt,"a tree that does not hold together fails: %v",p)
    }
    testing.expect(t,!test_peer(&w.nodes[1]).bad,"the peer that holds them is not bad: its chunks make their addresses")
}

// A peer that sends descendants past the budget of an ask is bad.
@(test)
a_peer_past_the_budget_of_an_ask_is_bad :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-budget",2) {return}
    server:=test_host(&w,0,.Server)
    flood:=test_scripted(t,&w,1,.Over_Budget)
    if !testing.expect(t,test_connect(&w,flood,w.nodes[0].endpoints[0])) {return}
    root:=test_object(t,&w.nodes[1].s,test_bytes(2<<20,5))
    want(&w.nodes[0].x,root)
    test_step(&w,500)
    p,_:=peer_progress(&w.nodes[0].x,server,server.connection_handles[0])
    testing.expect(t,p.bad,"the flooding peer is bad")
    testing.expect(t,!test_here(&w.nodes[0],root),"and what it sent past the budget is not taken whole")
}
