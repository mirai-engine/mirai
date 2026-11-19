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
test_entry :: proc(kind:u8,address:store.Hash,first,count:u32) -> []u8 {
    address:=address
    return test_message({kind},address[:],test_le(u64(first),4),test_le(u64(count),4))
}

@(private)
test_request :: proc(entries:..[]u8) -> []u8 {
    return test_message({MSG_REQUEST},test_le(u64(len(entries)),2),test_message(..entries))
}

// Every message a peer could send is validated: the malformed ones mark the
// peer bad, the well formed ones nobody asked for are ignored, and a peer
// cannot queue more than BATCHES requests. None crashes, and random bytes on
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
    blob:=test_put(t,&w.nodes[0].s,3*store.PIECE_BYTES+5,1)
    other:=store.address_of_bytes(test_bytes(5,2))
    want(x,other)
    zero:store.Hash
    big:=make([]u8,store.PIECE_BYTES+1,context.temp_allocator)
    Case :: struct {lane:int,data:[]u8,bad:bool}
    cases:=[]Case{
        {LANE_CONTROL,nil,true},
        {LANE_CONTROL,{99},true},
        {LANE_DATA,{99},true},
        {LANE_CONTROL,{MSG_REQUEST},true},
        {LANE_CONTROL,test_request(),true},
        {LANE_CONTROL,test_message({MSG_REQUEST},test_le(65,2)),true},
        {LANE_CONTROL,test_message(test_request(test_entry(1,blob,0,1)),{0}),true},
        {LANE_CONTROL,test_request(test_entry(2,blob,0,1)),true},
        {LANE_CONTROL,test_request(test_entry(1,blob,0,0)),true},
        {LANE_CONTROL,test_request(test_entry(1,blob,max(u32),2)),true},
        {LANE_CONTROL,test_request(test_entry(1,blob,0,REQUEST_PIECES+1)),true},
        {LANE_CONTROL,test_request(test_entry(1,blob,0,REQUEST_PIECES),test_entry(1,blob,0,1)),true},
        {LANE_CONTROL,test_message({MSG_REF_GET},test_name("lib")),true},
        {LANE_CONTROL,test_message({MSG_REF_GET},test_name("Lib"),test_name("a")),true},
        {LANE_CONTROL,test_message({MSG_REF_GET},test_name("lib"),{200},big[:10]),true},
        {LANE_CONTROL,test_message({MSG_NAMES_GET},test_name("lib"),test_name("../x")),true},
        {LANE_CONTROL,test_message({MSG_REF},test_name("lib"),test_name("a"),{2},zero[:]),true},
        {LANE_CONTROL,test_message({MSG_NAMES},test_name("lib"),{0},{0},test_le(3,2)),true},
        {LANE_CONTROL,test_message({MSG_NAMES},test_name("lib"),{0},{0},test_le(1,2),test_name("a")),true},
        {LANE_DATA,test_message({MSG_TABLE},blob[:]),true},
        {LANE_DATA,test_message({MSG_PIECE},blob[:],test_le(0,4)),true},
        {LANE_DATA,test_message({MSG_PIECE},blob[:],test_le(0,4),big),true},
        {LANE_DATA,test_message({MSG_PIECE},blob[:2]),true},
        {LANE_DATA,test_message({MSG_LACK},blob[:],test_le(0,4)),true},
        {LANE_DATA,{MSG_DONE},true},
        {LANE_DATA,{MSG_DONE,0},true},
        {LANE_DATA,test_message({MSG_WHOLE},blob[:5]),true},
        // Nobody asked: ignored, counted against the peer.
        {LANE_DATA,test_message({MSG_TABLE},blob[:],test_le(1<<62,8)),false},
        {LANE_DATA,test_message({MSG_TABLE},blob[:],test_le(2*store.PIECE_BYTES,8),zero[:]),false},
        {LANE_CONTROL,test_message({MSG_REF},test_name("lib"),test_name("a"),{1},zero[:]),false},
        {LANE_CONTROL,test_message({MSG_NAMES},test_name("lib"),{0},{0},test_le(0,2)),false},
        {LANE_DATA,test_message({MSG_PIECE},blob[:],test_le(9,4),big[:100]),false},
        {LANE_DATA,test_message({MSG_PIECE},other[:],test_le(1<<31,4),big[:100]),false},
        {LANE_DATA,test_message({MSG_TABLE},zero[:],test_le(10,8),zero[:]),false},
        {LANE_DATA,test_message({MSG_WHOLE},other[:],big[:5]),false},
        {LANE_DATA,test_message({MSG_LACK},zero[:],test_le(0,4),test_le(0,4)),false},
        {LANE_CONTROL,test_message({MSG_REF_GET},test_name("secret"),test_name("a")),false},
        {LANE_CONTROL,test_message({MSG_NAMES_GET},test_name("lib"),{0}),false},
        {LANE_CONTROL,test_request(test_entry(0,blob,0,2),test_entry(1,zero,0,3)),false},
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
    // A table of a wanted blob that nobody asked that peer for, also one too
    // large for this end, leaves the want as it was.
    q,_:=progress(x,other)
    testing.expect(t,q.state==.Asking && q.total==-1,"an unasked table is not taken")
    huge:=make([]u8,wire.PIECE_BYTES,context.temp_allocator)
    copy(huge,test_message({MSG_TABLE},other[:],test_le(1<<30,8)))
    for _ in 0..<8 {receive(x,server,{kind=.Message,channel=u8(w.channel+LANE_DATA),connection=c,data=huge,more=true})}
    receive(x,server,{kind=.Message,channel=u8(w.channel+LANE_DATA),connection=c,data=huge[:1]})
    q,_=progress(x,other)
    testing.expect(t,q.state!=.Failed,"an unasked oversized table does not fail the want")
    // A message that arrives in pieces past what this end holds.
    piece:=make([]u8,wire.PIECE_BYTES,context.temp_allocator)
    piece[0]=MSG_NAMES
    for _ in 0..<8 {receive(x,server,{kind=.Message,channel=u8(w.channel+LANE_CONTROL),connection=c,data=piece,more=true})}
    receive(x,server,{kind=.Message,channel=u8(w.channel+LANE_CONTROL),connection=c,data=piece[:1]})
    p,_:=peer_progress(x,server,c)
    testing.expect(t,p.bad,"an oversized message marks the peer")
    peer_remove(x,server,c)
    peer_add(x,server,c)
    // At most BATCHES requests queue; the next is refused, not served.
    full:=make([][]u8,REQUEST_ENTRIES,context.temp_allocator)
    for &e in full {e=test_entry(1,blob,0,1)}
    request:=test_request(..full)
    for _ in 0..<BATCHES+1 {receive(x,server,{kind=.Message,channel=u8(w.channel+LANE_CONTROL),connection=c,data=request})}
    p,_=peer_progress(x,server,c)
    testing.expect(t,!p.bad && p.refused==1,"a request past the ones in flight is refused")
    // Random bytes on both channels.
    h:=base.Hostile{state=5}
    data:=make([]u8,600,context.temp_allocator)
    for _ in 0..<4000 {
        n:=base.hostile_int(&h,len(data))
        for &b in data[:n] {b=u8(base.hostile_next(&h))}
        if n>0 && base.hostile_int(&h,2)==0 {data[0]=u8(1+base.hostile_int(&h,5))}
        receive(x,server,{kind=.Message,channel=u8(w.channel+base.hostile_int(&h,CHANNELS)),connection=c,data=data[:n],more=base.hostile_int(&h,8)==0})
        if p,_=peer_progress(x,server,c);p.bad {
            peer_remove(x,server,c)
            peer_add(x,server,c)
        }
    }
    test_step(&w,500)
    testing.expect(t,!store.has(&w.nodes[0].s,other),"nothing unverified completes a blob")
}
