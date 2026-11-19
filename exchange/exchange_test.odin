package exchange

import "core:slice"
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
blobs_around_the_piece_boundaries_and_a_large_one_arrive_verified_under_loss_and_jitter :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_pair(t,&w,"exchange-loss") {return}
    P:=store.PIECE_BYTES
    sizes:=[]int{0,1,P-1,P,P+1,2*P,3*P+17,6<<20}
    addresses:=make([]store.Hash,len(sizes),context.temp_allocator)
    for size,k in sizes {addresses[k]=test_put(t,&w.nodes[0].s,size,u64(k)+1)}
    for e in w.nodes[0].endpoints[:1] {wire.sim_endpoint_conditions(&w.sim,e,{latency=0.02,jitter=0.005,loss=0.05})}
    wire.sim_endpoint_conditions(&w.sim,w.nodes[1].endpoints[0],{latency=0.02,jitter=0.005,loss=0.05})
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

// Two sources, one of which lies; it is asked first, so its lie is met. A
// table of one piece for a blob of several, or one larger than the receiver
// holds, fails the liar for the blob, never the honest peer or the want.
@(test)
a_liar_in_the_table_a_piece_or_the_size_is_marked_and_the_blob_still_arrives :: proc(t:^testing.T) {
    for lie in ([]Test_Lie{.Table,.Piece,.Size,.Single,.Huge}) {
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
Test_Job :: struct {
    x:^Exchange,
    address:store.Hash,
    namespace,name:string,
    addresses:[]store.Hash, // fetch_all, or what fetch_refs found for names
    names:[]string,
    error:Error,
    found:store.Hash,
    done:bool,
}

@(private)
test_job :: proc(j:^Test_Job) {
    if j.names!=nil {
        j.error=fetch_refs(j.x,j.namespace,j.names,j.addresses)
    } else if j.addresses!=nil {
        j.error=fetch_all(j.x,j.addresses)
    } else if j.namespace!="" {
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
    // A want kept complete whose blob a sweep removed is fetched again: success is what the store says.
    want(x,hit)
    store.remove(&w.nodes[1].s,hit)
    j={x=x,address=hit}
    testing.expect(t,test_fetch(&w,&j,10) && j.error==.None && store.has(&w.nodes[1].s,hit),"a swept blob is fetched again")
    forget(x,hit)
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

// A scripted peer at node k that answers as lie says, connected to the server at node 0.
@(private)
test_scripted :: proc(t:^testing.T,w:^Test_World,k:int,lie:Test_Lie) -> ^wire.Host {
    h:=test_host(w,k,.Client)
    w.nodes[k].script,w.nodes[k].lie,w.nodes[k].source=test_liar,lie,&w.nodes[k].s
    return h
}

@(private)
test_received_by :: proc(x:^Exchange,h:^wire.Host) -> (lies:[2]int) {
    for c in h.connection_handles {
        if c==0 {continue}
        p,_:=peer_progress(x,h,c)
        lies[0 if p.lies>0 else 1]+=1
    }
    return
}

// The true last piece proves a begun size wrong after another process
// published the blob: the published blob stays.
@(test)
a_wrong_size_found_after_another_process_published_the_blob_keeps_it :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-published",2) {return}
    server:=test_host(&w,0,.Server)
    silent:=test_scripted(t,&w,1,.Hold)
    if !testing.expect(t,test_connect(&w,silent,w.nodes[0].endpoints[0])) {return}
    size:=FIRST_PIECES*store.PIECE_BYTES+1000
    data:=test_bytes(size,4)
    blob:=store.address_of_bytes(data)
    r:=&w.nodes[0]
    want(&r.x,blob)
    test_step(&w,20)
    c:=server.connection_handles[0]
    pieces:=make([]store.Hash,FIRST_PIECES+1,context.temp_allocator)
    {
        other,_:=store.open(w.folder)
        defer store.close(&other)
        store.put_bytes(&other,data)
        table,_:=store.blob_table(&other,blob,context.temp_allocator)
        copy(pieces,table)
        store.remove(&other,blob)
    }
    told:=test_message({MSG_TABLE},blob[:],test_le(u64(size-100),8),slice.to_bytes(pieces))
    receive(&r.x,server,{kind=.Message,channel=u8(LANE_DATA),connection=c,data=told})
    test_step(&w,20)
    p,_:=progress(&r.x,blob)
    testing.expect(t,p.total==i64(size-100),"the told size is begun")
    another,_:=store.open(r.s.root)
    defer store.close(&another)
    store.put_bytes(&another,data)
    last:=test_message({MSG_PIECE},blob[:],test_le(FIRST_PIECES,4),data[FIRST_PIECES*store.PIECE_BYTES:])
    receive(&r.x,server,{kind=.Message,channel=u8(LANE_DATA),connection=c,data=last})
    testing.expect(t,store.has(&r.s,blob) && store.verify(&r.s,blob)==.None,"the published blob stays")
    testing.expect_value(t,test_state(&r.x,blob),State.Complete)
}

// A peer that reserved a want and then sends only unrelated data loses the
// reservation, and the honest peer serves the blob.
@(test)
a_peer_that_holds_a_want_without_progress_loses_it :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-hold",3) {return}
    test_host(&w,0,.Server)
    holder:=test_scripted(t,&w,1,.Hold)
    honest:=test_host(&w,2,.Client)
    blob:=test_put(t,&w.nodes[2].s,2*store.PIECE_BYTES+7,6)
    if !testing.expect(t,test_connect(&w,holder,w.nodes[0].endpoints[0]) && test_connect(&w,honest,w.nodes[0].endpoints[0])) {return}
    want(&w.nodes[0].x,blob)
    testing.expect(t,test_until_complete(&w,0,{blob},15),"the honest peer serves the blob once the reservation lapses")
}

// What a peer was marked for leaves with it: the next peer in its slot is not
// blamed for the size the first one gave.
@(test)
a_peer_in_a_freed_slot_is_not_blamed_for_its_predecessor :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-slot",3) {return}
    server:=test_host(&w,0,.Server)
    liar:=test_scripted(t,&w,1,.Size_First)
    honest:=test_host(&w,2,.Client)
    size:=4*store.PIECE_BYTES+1000
    blob:=test_put(t,&w.nodes[1].s,size,8)
    test_put(t,&w.nodes[2].s,size,8)
    if !testing.expect(t,test_connect(&w,liar,w.nodes[0].endpoints[0])) {return}
    r:=&w.nodes[0]
    want(&r.x,blob)
    for _ in 0..<2000 {
        test_step(&w)
        if p,_:=progress(&r.x,blob);p.total>0 && p.here==i64(size-store.PIECE_BYTES) {break}
    }
    p,_:=progress(&r.x,blob)
    testing.expect(t,p.total==i64(size-100),"the liar's size is begun with every piece but the last")
    wire.host_disconnect(liar)
    for _ in 0..<2000 {
        test_step(&w)
        if server.connection_handles[0]==0 && server.connection_handles[1]==0 {break}
    }
    if !testing.expect(t,test_connect(&w,honest,w.nodes[0].endpoints[0])) {return}
    testing.expect(t,test_until_complete(&w,0,{blob},20),"the honest peer in the freed slot completes the blob")
    testing.expect_value(t,test_received_by(&r.x,server),[2]int{0,1})
}

// A lookup answered by a fast peer leaves the slow peer's credits to return
// with its late answers, so a later lookup that needs the slow peer finds it.
@(test)
late_ref_answers_return_their_credits :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-credits",3,desc={expose=test_expose_lib}) {return}
    test_host(&w,0,.Server)
    fast:=test_host(&w,1,.Client)
    slow:=test_host(&w,2,.Client)
    if !testing.expect(t,test_connect(&w,fast,w.nodes[0].endpoints[0]) && test_connect(&w,slow,w.nodes[0].endpoints[0])) {return}
    wire.sim_endpoint_conditions(&w.sim,w.nodes[2].endpoints[0],{latency=1})
    blob:=test_put(t,&w.nodes[2].s,100,1)
    store.ref_set(&w.nodes[2].s,"lib","only",blob)
    names:=[]string{"ka","kb","kc","kd"}
    for name in names {
        store.ref_set(&w.nodes[1].s,"lib",name,blob)
        store.ref_set(&w.nodes[2].s,"lib",name,blob)
    }
    x:=&w.nodes[0].x
    for name in names {
        q,_:=ref_ask(x,"lib",name)
        for _ in 0..<500 {
            test_step(&w)
            if r,_:=query_result(x,q);r.state!=.Waiting {break}
        }
        r,_:=query_result(x,q)
        testing.expectf(t,r.state==.Found,"%s is found by the fast peer",name)
        query_end(x,q)
    }
    q,_:=ref_ask(x,"lib","only")
    found:=false
    for _ in 0..<8000 {
        test_step(&w)
        if r,_:=query_result(x,q);r.state!=.Waiting {found=r.state==.Found;break}
    }
    testing.expect(t,found,"the slow peer is asked and names it")
}

// After a peer's flight lapses and its want goes to another, its late Done
// does not free what the other was asked: no piece is served twice.
@(test)
a_late_done_does_not_release_what_another_peer_was_asked :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-late",3) {return}
    test_host(&w,0,.Server)
    late:=test_scripted(t,&w,1,.Late_Done)
    honest:=test_host(&w,2,.Client)
    // Two pieces, both asked with the table: the honest peer has a request free when the late Done comes.
    size:=2*store.PIECE_BYTES
    blob:=test_put(t,&w.nodes[2].s,size,3)
    if !testing.expect(t,test_connect(&w,late,w.nodes[0].endpoints[0]) && test_connect(&w,honest,w.nodes[0].endpoints[0])) {return}
    wire.sim_endpoint_conditions(&w.sim,w.nodes[2].endpoints[0],{latency=0.01,bandwidth=0.5e6})
    want(&w.nodes[0].x,blob)
    testing.expect(t,test_until_complete(&w,0,{blob},30),"the honest peer serves the blob")
    served,_:=peer_progress(&w.nodes[2].x,honest,honest.connection_handles[0])
    testing.expectf(t,served.sent==u64(size),"the honest peer serves %d bytes of %d",served.sent,size)
    testing.expectf(t,w.nodes[1].requests==1,"the late peer is asked %d times",w.nodes[1].requests)
}

// Destroying the exchange wakes a fetch waiting on a job with Closed, and
// frees only once it left.
@(test)
destroy_wakes_a_waiting_fetch :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-destroy",2) {return}
    test_host(&w,0,.Server)
    silent:=test_scripted(t,&w,1,.Hold)
    if !testing.expect(t,test_connect(&w,silent,w.nodes[0].endpoints[0])) {return}
    n:=&w.nodes[0]
    j:=Test_Job{x=&n.x,address=store.address_of_bytes(test_bytes(10,5))}
    th:=thread.create_and_start_with_poly_data(&j,test_job)
    test_step(&w,200)
    testing.expect(t,!sync.atomic_load(&j.done),"the fetch waits on the silent peer")
    destroy(&n.x)
    n.open=false
    thread.join(th)
    thread.destroy(th)
    testing.expect_value(t,j.error,Error.Closed)
}

// A server whose largest blob is one piece still answers a request for a
// blob's table and first pieces.
@(test)
a_server_with_the_smallest_cap_serves_an_honest_request :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-cap",2) {return}
    test_node_close(&w.nodes[0])
    if !testing.expect(t,test_node_open(&w,0,{max_blob_bytes=store.PIECE_BYTES})) {return}
    test_host(&w,0,.Server)
    client:=test_host(&w,1,.Client)
    if !testing.expect(t,test_connect(&w,client,w.nodes[0].endpoints[0])) {return}
    blob:=test_put(t,&w.nodes[0].s,1000,2)
    want(&w.nodes[1].x,blob)
    testing.expect(t,test_until_complete(&w,1,{blob},5),"the blob arrives")
    p,_:=peer_progress(&w.nodes[0].x,w.nodes[0].hosts[0],w.nodes[0].hosts[0].connection_handles[0])
    testing.expect(t,!p.bad,"the server keeps the requester")
}

// Small blobs wanted together on a connection in use arrive in a few round
// trips however many they are.
@(test)
many_small_blobs_wanted_together_take_round_trips_that_do_not_grow_with_their_count :: proc(t:^testing.T) {
    RTT :: 0.1
    for count in ([]int{8,120}) {
        w:Test_World
        defer test_world_destroy(&w)
        if !test_pair(t,&w,"exchange-small") {return}
        for e in ([]int{w.nodes[0].endpoints[0],w.nodes[1].endpoints[0]}) {wire.sim_endpoint_conditions(&w.sim,e,{latency=RTT/2})}
        // A connection that carried a transfer, past the start of its congestion window.
        warm:=test_put(t,&w.nodes[0].s,2<<20,1000)
        want(&w.nodes[1].x,warm)
        testing.expect(t,test_until_complete(&w,1,{warm},30))
        blobs:=make([]store.Hash,count,context.temp_allocator)
        for &b,k in blobs {b=test_put(t,&w.nodes[0].s,(1+k%5)*1000,u64(k)+1)}
        start:=w.now
        for b in blobs {want(&w.nodes[1].x,b)}
        testing.expectf(t,test_until_complete(&w,1,blobs,30),"%d blobs arrive",count)
        trips:=(w.now-start)/RTT
        testing.expectf(t,trips<4,"%d small blobs take %.1f round trips",count,trips)
    }
}

// fetch_all and fetch_refs return once all is here, at a miss among hits, and
// at a disconnect.
@(test)
the_batch_blocking_forms_return_for_a_hit_a_partial_miss_and_a_disconnect :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-fetch-all",2,desc={expose=test_expose_lib}) {return}
    test_host(&w,0,.Server)
    client:=test_host(&w,1,.Client)
    if !testing.expect(t,test_connect(&w,client,w.nodes[0].endpoints[0])) {return}
    x,here:=&w.nodes[1].x,&w.nodes[1].s
    blobs:=make([]store.Hash,40,context.temp_allocator)
    for &b,k in blobs {b=test_put(t,&w.nodes[0].s,(k%7)*30000+1,u64(k)+1)}
    j:=Test_Job{x=x,addresses=blobs}
    testing.expect(t,test_fetch(&w,&j,10) && j.error==.None,"a set of hits returns")
    for b in blobs {
        testing.expect(t,store.has(here,b),"every blob is here")
        _,still:=progress(x,b)
        testing.expect(t,!still,"a fetch_all leaves no want behind")
    }
    // More names than query slots, so the form waits for slots to free.
    names:=[]string{"a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t"}
    for name,k in names {store.ref_set(&w.nodes[0].s,"lib",name,test_put(t,&w.nodes[0].s,5000*(k+1),u64(100+k)))}
    j={x=x,namespace="lib",names=names,addresses=make([]store.Hash,len(names),context.temp_allocator)}
    testing.expect(t,test_fetch(&w,&j,10) && j.error==.None,"a set of ref hits returns")
    for a in j.addresses {testing.expect(t,a!={} && store.has(here,a),"each ref's blob is here")}
    absent:=store.address_of_bytes(test_bytes(10,99))
    fresh:=[]store.Hash{test_put(t,&w.nodes[0].s,3000,200),absent,test_put(t,&w.nodes[0].s,4000,201)}
    j={x=x,addresses=fresh}
    testing.expect(t,test_fetch(&w,&j,10) && j.error==.Missing,"a miss among hits returns Missing")
    j={x=x,namespace="lib",names={"a","absent"},addresses=make([]store.Hash,2,context.temp_allocator)}
    testing.expect(t,test_fetch(&w,&j,10) && j.error==.Missing && j.addresses[1]=={},"a ref miss returns Missing")
    wire.sim_endpoint_conditions(&w.sim,w.nodes[0].endpoints[0],{latency=0.01,bandwidth=2e6})
    big:=[]store.Hash{test_put(t,&w.nodes[0].s,4<<20,300),test_put(t,&w.nodes[0].s,4<<20,301)}
    j={x=x,addresses=big}
    testing.expect(t,test_fetch(&w,&j,20,proc(w:^Test_World) {
        client:=w.nodes[1].hosts[0]
        if client.connection_handles[0]==0 {return}
        if p,ok:=peer_progress(&w.nodes[1].x,client,client.connection_handles[0]);ok && p.received>1<<20 {wire.host_disconnect(w.nodes[0].hosts[0])}
    }) && j.error==.Missing,"a disconnect returns Missing")
    testing.expect(t,!store.has(here,big[0]) || !store.has(here,big[1]),"the disconnect came before the blobs")
}
