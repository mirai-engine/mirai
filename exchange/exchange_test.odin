package exchange

import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"
import "mirai:store"
import wire "mirai:net"

// A server node 0 and a client node 1 connected; false if they are not.
@(private)
test_pair :: proc(t:^testing.T,w:^Test_World,name:string,game:=false) -> bool {
    if !test_world(t,w,name,2,game) {return false}
    server:=test_host(w,0,.Server)
    client:=test_host(w,1,.Client)
    return testing.expect(t,server!=nil && client!=nil && test_connect(w,client,w.nodes[0].endpoints[0]),"the peers connect")
}

@(private)
test_put :: proc(t:^testing.T,s:^store.Store,size:int,seed:u64) -> store.Hash {
    hash,error:=store.put_bytes(s,test_bytes(size,seed))
    testing.expect_value(t,error,store.Error.None)
    return hash
}

@(test)
blobs_around_the_piece_boundaries_and_a_large_one_arrive_verified_under_loss :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_pair(t,&w,"exchange-loss") {return}
    P:=store.PIECE_BYTES
    sizes:=[]int{0,1,P-1,P,P+1,2*P,3*P+17,6<<20}
    addresses:=make([]store.Hash,len(sizes),context.temp_allocator)
    for size,k in sizes {addresses[k]=test_put(t,&w.nodes[0].s,size,u64(k)+1)}
    for e in w.nodes[0].endpoints[:1] {wire.sim_endpoint_conditions(&w.sim,e,{latency=0.02,loss=0.05})}
    wire.sim_endpoint_conditions(&w.sim,w.nodes[1].endpoints[0],{latency=0.02,loss=0.05})
    for a in addresses {testing.expect_value(t,want(&w.nodes[1].x,a),Error.None)}
    testing.expect(t,test_until_complete(&w,1,addresses,60),"every blob arrives")
    for a,k in addresses {
        testing.expect_value(t,store.verify(&w.nodes[1].s,a),store.Error.None)
        back:=make([]u8,sizes[k],context.temp_allocator)
        testing.expect_value(t,store.read(&w.nodes[1].s,a,0,back),store.Error.None)
        testing.expect(t,string(back)==string(test_bytes(sizes[k],u64(k)+1)),"the blob reads back its bytes")
        p,_:=progress(&w.nodes[1].x,a)
        testing.expect(t,p.state==.Complete && p.here==i64(sizes[k]) && p.total==i64(sizes[k]),"progress counts the whole blob")
    }
    rate,_:=peer_progress(&w.nodes[1].x,w.nodes[1].hosts[0],w.nodes[1].hosts[0].connection_handles[0])
    testing.expect(t,rate.received>=6<<20 && rate.receive_rate>0,"the peer's rate is measured")
}

// What matters most is asked first: a small want asked after a large one and
// raised above it completes long before it.
@(test)
a_high_priority_want_asked_later_completes_before_a_large_low_one :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_pair(t,&w,"exchange-priority") {return}
    large:=test_put(t,&w.nodes[0].s,24<<20,1)
    small:=test_put(t,&w.nodes[0].s,300<<10,2)
    wire.sim_endpoint_conditions(&w.sim,w.nodes[0].endpoints[0],{latency=0.01,bandwidth=4e6})
    x:=&w.nodes[1].x
    want(x,large)
    test_step(&w,300)
    want(x,small)
    want(x,small,10)
    small_done,large_done:f64
    for w.now<60 && large_done==0 {
        test_step(&w)
        if small_done==0 && test_state(x,small)==.Complete {small_done=w.now}
        if test_state(x,large)==.Complete {large_done=w.now}
    }
    testing.expectf(t,small_done>0 && large_done>0,"both arrive: %.2f and %.2f s",small_done,large_done)
    testing.expectf(t,small_done<large_done/3,"the raised want completes at %.2f s, the large one at %.2f s",small_done,large_done)
}

@(test)
a_transfer_resumes_after_the_connection_drops_and_after_the_store_reopens :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_pair(t,&w,"exchange-resume") {return}
    wire.sim_endpoint_conditions(&w.sim,w.nodes[0].endpoints[0],{latency=0.01,bandwidth=4e6})
    server,client:=w.nodes[0].hosts[0],w.nodes[1].hosts[0]
    x:=&w.nodes[1].x
    blob:=test_put(t,&w.nodes[0].s,8<<20,3)
    want(x,blob)
    test_step(&w,600)
    before,_:=progress(x,blob)
    testing.expect(t,before.here>0 && before.here<before.total,"part of the blob is here")
    wire.host_disconnect(server,server.connection_handles[0])
    for _ in 0..<2000 {
        test_step(&w)
        if client.connection_handles[0]==0 {break}
    }
    test_step(&w,100)
    kept,_:=progress(x,blob)
    testing.expect(t,kept.state==.Missing && kept.here>=before.here,"with no peer the want is missing and keeps what arrived")
    testing.expect(t,test_connect(&w,client,w.nodes[0].endpoints[0]),"the peers connect again")
    testing.expect(t,test_until_complete(&w,1,{blob},30),"the blob completes after the connection returns")
    testing.expect_value(t,store.verify(&w.nodes[1].s,blob),store.Error.None)

    second:=test_put(t,&w.nodes[0].s,8<<20,4)
    want(x,second)
    test_step(&w,600)
    part,_:=progress(x,second)
    testing.expect(t,part.here>0 && part.here<part.total,"part of the second blob is here")
    // The receiving process ends and starts again: a new store value, exchange and connection.
    n:=&w.nodes[1]
    test_node_close(n)
    wire.host_disconnect(client)
    for _ in 0..<2000 {
        test_step(&w)
        if client.connection_handles[0]==0 {break}
    }
    if !testing.expect(t,test_node_open(&w,1),"the store reopens") {return}
    testing.expect(t,test_connect(&w,client,w.nodes[0].endpoints[0]),"the peers connect again")
    want(&n.x,second)
    resumed,_:=progress(&n.x,second)
    testing.expect(t,resumed.here>=part.here,"the reopened store resumes from the pieces it has")
    testing.expect(t,test_until_complete(&w,1,{second},30),"the second blob completes")
    got,_:=peer_progress(&n.x,client,client.connection_handles[0])
    testing.expectf(t,got.received<=u64(8<<20)-u64(part.here)+u64(4*store.PIECE_BYTES),"after the reopen %d bytes arrive of the %d missing",got.received,(8<<20)-part.here)
}

// Two sources, one of which lies; it is asked first, so its lie is met.
@(test)
a_liar_in_the_table_a_piece_or_the_size_is_marked_and_the_blob_still_arrives :: proc(t:^testing.T) {
    for lie in ([]Test_Lie{.Table,.Piece,.Size}) {
        w:Test_World
        defer test_world_destroy(&w)
        if !test_world(t,&w,"exchange-liar",3) {return}
        test_host(&w,0,.Server)
        liar:=test_host(&w,1,.Client)
        honest:=test_host(&w,2,.Client)
        w.nodes[1].script,w.nodes[1].lie,w.nodes[1].source=test_liar,lie,&w.nodes[1].s
        size:=5*store.PIECE_BYTES+1000
        blob:=test_put(t,&w.nodes[1].s,size,9)
        test_put(t,&w.nodes[2].s,size,9)
        if !testing.expect(t,test_connect(&w,liar,w.nodes[0].endpoints[0]) && test_connect(&w,honest,w.nodes[0].endpoints[0])) {return}
        r:=&w.nodes[0]
        want(&r.x,blob)
        testing.expectf(t,test_until_complete(&w,0,{blob},20),"%v: the blob arrives",lie)
        testing.expect_value(t,store.verify(&r.s,blob),store.Error.None)
        server:=r.hosts[0]
        lies:=[2]int{}
        for c in server.connection_handles {
            if c==0 {continue}
            p,_:=peer_progress(&r.x,server,c)
            lies[0 if p.lies>0 else 1]+=1
        }
        testing.expectf(t,lies=={1,1},"%v: the liar is marked and the honest peer is not: %v",lie,lies)
    }
}

// A peer serves the pieces it has of a blob it is still receiving.
@(test)
a_peer_still_receiving_a_blob_serves_its_pieces_to_a_third :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-relay",3) {return}
    test_host(&w,0,.Server)
    b_client:=test_host(&w,1,.Client)
    test_host(&w,1,.Server)
    c_client:=test_host(&w,2,.Client)
    if !testing.expect(t,test_connect(&w,b_client,w.nodes[0].endpoints[0]) && test_connect(&w,c_client,w.nodes[1].endpoints[1])) {return}
    wire.sim_endpoint_conditions(&w.sim,w.nodes[0].endpoints[0],{latency=0.01,bandwidth=2e6})
    blob:=test_put(t,&w.nodes[0].s,6<<20,5)
    want(&w.nodes[1].x,blob)
    want(&w.nodes[2].x,blob)
    relayed:=false
    for w.now<60 && !store.has(&w.nodes[2].s,blob) {
        test_step(&w)
        c,_:=progress(&w.nodes[2].x,blob)
        if c.here>0 && !store.has(&w.nodes[1].s,blob) {relayed=true}
    }
    testing.expect(t,relayed,"the third peer receives pieces before the relay has the whole blob")
    testing.expect(t,store.has(&w.nodes[2].s,blob) && store.verify(&w.nodes[2].s,blob)==.None,"the third peer completes the blob")
}

@(private)
test_expose_lib :: proc(user:rawptr,namespace:string) -> bool {return namespace=="lib"}

@(test)
refs_are_asked_and_listed_and_a_namespace_not_exposed_gives_nothing :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-refs",2,desc={expose=test_expose_lib}) {return}
    test_host(&w,0,.Server)
    client:=test_host(&w,1,.Client)
    if !testing.expect(t,test_connect(&w,client,w.nodes[0].endpoints[0])) {return}
    s:=&w.nodes[0].s
    blob:=test_put(t,s,1000,1)
    names:=make([]string,NAMES_PER_REPLY+5,context.temp_allocator)
    for &name,k in names {
        buffer:=make([]u8,4,context.temp_allocator)
        buffer[0],buffer[1],buffer[2],buffer[3]='p',u8('a'+k/26/26%26),u8('a'+k/26%26),u8('a'+k%26)
        name=string(buffer)
        store.ref_set(s,"lib",name,blob)
    }
    store.ref_set(s,"secret","key",blob)
    x:=&w.nodes[1].x
    ask :: proc(w:^Test_World,x:^Exchange,q:Query) -> Query_Result {
        for _ in 0..<2000 {
            test_step(w)
            if r,_:=query_result(x,q);r.state!=.Waiting {return r}
        }
        return {}
    }
    q,_:=ref_ask(x,"lib","pabc")
    r:=ask(&w,x,q)
    testing.expect(t,r.state==.Found && r.address==blob,"an exposed ref gives its address")
    query_end(x,q)
    q,_=ref_ask(x,"secret","key")
    r=ask(&w,x,q)
    testing.expect_value(t,r.state,Query_State.Not_Found)
    query_end(x,q)
    q,_=ref_ask(x,"lib","nothing")
    testing.expect_value(t,ask(&w,x,q).state,Query_State.Not_Found)
    query_end(x,q)
    q,_=names_ask(x,client,client.connection_handles[0],"lib")
    r=ask(&w,x,q)
    testing.expect(t,r.state==.Found && len(r.names)==NAMES_PER_REPLY && r.more,"the first page of names")
    last:=""
    for n,k in r.names {
        testing.expect(t,n.name==names[k] && n.address==blob,"names come sorted with their addresses")
        last=n.name
    }
    after:=make([]u8,len(last),context.temp_allocator)
    copy(after,last)
    query_end(x,q)
    q,_=names_ask(x,client,client.connection_handles[0],"lib",string(after))
    r=ask(&w,x,q)
    testing.expect(t,r.state==.Found && len(r.names)==5 && !r.more && r.names[0].name==names[NAMES_PER_REPLY],"the page after the last name")
    query_end(x,q)
    q,_=names_ask(x,client,client.connection_handles[0],"secret")
    r=ask(&w,x,q)
    testing.expect(t,r.state==.Found && len(r.names)==0,"a namespace not exposed lists nothing")
    query_end(x,q)
}

@(private)
Test_Job :: struct {x:^Exchange,address:store.Hash,namespace,name:string,error:Error,found:store.Hash,done:bool}

@(private)
test_job :: proc(j:^Test_Job) {
    if j.namespace!="" {
        j.found,j.error=fetch_ref(j.x,j.namespace,j.name)
    } else {
        j.error=fetch(j.x,j.address)
    }
    sync.atomic_store(&j.done,true)
}

// Runs a fetch on a thread while the owner pumps; false if it does not return within seconds.
@(private)
test_fetch :: proc(w:^Test_World,j:^Test_Job,seconds:f64,during:proc(w:^Test_World)=nil) -> bool {
    th:=thread.create_and_start_with_poly_data(j,test_job)
    defer {thread.join(th);thread.destroy(th)}
    end:=w.now+seconds
    for w.now<end {
        test_step(w)
        if during!=nil {during(w)}
        if sync.atomic_load(&j.done) {return true}
    }
    // Let the job return: no peer has it once the connections close.
    for &n in w.nodes[:w.count] {
        for h in n.hosts[:n.host_count] {wire.host_disconnect(h)}
    }
    for !sync.atomic_load(&j.done) {test_step(w)}
    return false
}

@(test)
the_blocking_form_returns_for_a_hit_a_miss_and_a_disconnect :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-fetch",2,desc={expose=test_expose_lib}) {return}
    test_host(&w,0,.Server)
    client:=test_host(&w,1,.Client)
    if !testing.expect(t,test_connect(&w,client,w.nodes[0].endpoints[0])) {return}
    x:=&w.nodes[1].x
    hit:=test_put(t,&w.nodes[0].s,200<<10,1)
    j:=Test_Job{x=x,address=hit}
    testing.expect(t,test_fetch(&w,&j,10) && j.error==.None && store.has(&w.nodes[1].s,hit),"a hit returns once the blob is here")
    _,still:=progress(x,hit)
    testing.expect(t,!still,"a fetch leaves no want behind")
    keyed:=test_put(t,&w.nodes[0].s,3000,2)
    store.ref_set(&w.nodes[0].s,"lib","derived",keyed)
    j={x=x,namespace="lib",name="derived"}
    testing.expect(t,test_fetch(&w,&j,10) && j.error==.None && j.found==keyed && store.has(&w.nodes[1].s,keyed),"a ref hit returns its blob")
    j={x=x,address=store.address_of_bytes(test_bytes(10,99))}
    testing.expect(t,test_fetch(&w,&j,10) && j.error==.Missing,"a miss returns Missing")
    j={x=x,namespace="lib",name="absent"}
    testing.expect(t,test_fetch(&w,&j,10) && j.error==.Missing,"a ref miss returns Missing")
    wire.sim_endpoint_conditions(&w.sim,w.nodes[0].endpoints[0],{latency=0.01,bandwidth=2e6})
    big:=test_put(t,&w.nodes[0].s,8<<20,3)
    j={x=x,address=big}
    testing.expect(t,test_fetch(&w,&j,20,proc(w:^Test_World) {
        client:=w.nodes[1].hosts[0]
        if client.connection_handles[0]==0 {return}
        if p,ok:=peer_progress(&w.nodes[1].x,client,client.connection_handles[0]);ok && p.received>1<<20 {wire.host_disconnect(w.nodes[0].hosts[0])}
    }) && j.error==.Missing,"a disconnect returns Missing")
    testing.expect(t,!store.has(&w.nodes[1].s,big),"the disconnect came before the blob")
}

// A 60 Hz unreliable message from the source keeps its delay small while blobs stream.
@(test)
a_game_channel_keeps_its_delay_small_during_a_transfer :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_pair(t,&w,"exchange-game",game=true) {return}
    latency:=0.02
    wire.sim_endpoint_conditions(&w.sim,w.nodes[0].endpoints[0],{latency=latency,bandwidth=12.5e6})
    wire.sim_endpoint_conditions(&w.sim,w.nodes[1].endpoints[0],{latency=latency})
    blobs:=make([]store.Hash,6,context.temp_allocator)
    for &b,k in blobs {b=test_put(t,&w.nodes[0].s,8<<20,u64(k)+1)}
    for b in blobs {want(&w.nodes[1].x,b)}
    g:=&w.nodes[1].game
    g.latency,g.since=latency,w.now+1
    w.nodes[0].game.since=g.since
    complete:=test_until_complete(&w,1,blobs,30)
    testing.expect(t,complete,"the blobs arrive")
    sent:=w.nodes[0].game.sent
    testing.expectf(t,g.got>=sent*9/10 && sent>100,"%d of %d game messages arrive",g.got,sent)
    mean:=g.mean/f64(max(g.got,1))
    testing.expectf(t,mean<0.03 && g.worst<0.08,"game messages take %.0f ms more than the latency on average, %.0f at worst",mean*1000,g.worst*1000)
}
