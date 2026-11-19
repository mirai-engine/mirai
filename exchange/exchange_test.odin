package exchange

import "core:fmt"
import "core:os"
import "core:strings"
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

// A blob: an object and its alias, committed.
@(private)
test_put :: proc(t:^testing.T,s:^store.Store,size:int,seed:u64) -> store.Hash {
    hash,error:=store.put_bytes(s,test_bytes(size,seed))
    testing.expect_value(t,error,store.Error.None)
    return hash
}

// An object of bytes, committed: its root.
@(private)
test_object :: proc(t:^testing.T,s:^store.Store,data:[]u8) -> store.Hash {
    root,error:=store.put(s,data)
    testing.expect_value(t,error,store.Error.None)
    testing.expect_value(t,store.commit(s),store.Error.None)
    return root
}

// The bytes of an object read back from a store.
@(private)
test_read :: proc(s:^store.Store,root:store.Hash) -> ([]u8,bool) {
    o,error:=store.object_open(s,root)
    if error!=.None {return nil,false}
    defer store.object_close(&o)
    data:=make([]u8,int(store.object_size(&o)),context.temp_allocator)
    return data,store.object_read(&o,0,data)==.None
}

@(private)
test_peer :: proc(n:^Test_Node,host:=0) -> Peer_Progress {
    h:=n.hosts[host]
    for c in h.connection_handles {
        if c==0 {continue}
        p,_:=peer_progress(&n.x,h,c)
        return p
    }
    return {}
}

@(test)
objects_and_blobs_of_every_size_arrive_verified_under_loss_and_jitter :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_pair(t,&w,"exchange-loss") {return}
    M:=store.CHUNK_MAX
    sizes:=[]int{0,1,store.CHUNK_MIN-1,M,M+1,3*M+17,6<<20}
    addresses:=make([]store.Hash,2*len(sizes),context.temp_allocator)
    for size,k in sizes {
        addresses[2*k]=test_put(t,&w.nodes[0].s,size,u64(k)+1)
        addresses[2*k+1]=test_object(t,&w.nodes[0].s,test_bytes(size,u64(k)+100))
    }
    for e in w.nodes[0].endpoints[:1] {wire.sim_endpoint_conditions(&w.sim,e,{latency=0.02,jitter=0.005,loss=0.05})}
    wire.sim_endpoint_conditions(&w.sim,w.nodes[1].endpoints[0],{latency=0.02,jitter=0.005,loss=0.05})
    for a in addresses {testing.expect_value(t,want(&w.nodes[1].x,a),Error.None)}
    testing.expect(t,test_until_complete(&w,1,addresses,60),"everything arrives")
    s:=&w.nodes[1].s
    for size,k in sizes {
        blob:=addresses[2*k]
        testing.expect_value(t,store.verify(s,blob),store.Error.None)
        back:=make([]u8,size,context.temp_allocator)
        testing.expect_value(t,store.read(s,blob,0,back),store.Error.None)
        testing.expect(t,string(back)==string(test_bytes(size,u64(k)+1)),"the blob reads back its bytes")
        p,_:=progress(&w.nodes[1].x,blob)
        testing.expect(t,p.state==.Complete && p.here==i64(size) && p.total==i64(size),"progress counts the whole blob")
        data,ok:=test_read(s,addresses[2*k+1])
        testing.expect(t,ok && string(data)==string(test_bytes(size,u64(k)+100)),"the object reads back its bytes")
    }
    rate:=test_peer(&w.nodes[1])
    testing.expect(t,rate.received>=12<<20 && rate.receive_rate>0,"the peer's rate is measured")
}

// What matters most is asked first: a small want asked after a large one and
// raised above it completes long before it.
@(test)
a_high_priority_want_asked_later_completes_before_a_large_low_one :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_pair(t,&w,"exchange-priority") {return}
    large:=test_object(t,&w.nodes[0].s,test_bytes(24<<20,1))
    small:=test_object(t,&w.nodes[0].s,test_bytes(300<<10,2))
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
    first:=test_object(t,&w.nodes[0].s,test_bytes(8<<20,3))
    want(x,first)
    test_step(&w,600)
    before,_:=progress(x,first)
    testing.expect(t,before.here>0 && before.here<before.total,"part of the object is here")
    wire.host_disconnect(server,server.connection_handles[0])
    for _ in 0..<2000 {
        test_step(&w)
        if client.connection_handles[0]==0 {break}
    }
    test_step(&w,100)
    kept,_:=progress(x,first)
    testing.expect(t,kept.state==.Missing && kept.here>=before.here,"with no peer the want is missing and keeps what arrived")
    testing.expect(t,test_connect(&w,client,w.nodes[0].endpoints[0]),"the peers connect again")
    testing.expect(t,test_until_complete(&w,1,{first},30),"the object completes after the connection returns")

    TOTAL :: 8<<20
    second:=test_object(t,&w.nodes[0].s,test_bytes(TOTAL,4))
    want(x,second)
    test_step(&w,1500)
    part,_:=progress(x,second)
    testing.expect(t,part.here>0 && part.here<part.total,"part of the second object is here")
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
    test_step(&w)
    resumed,_:=progress(&n.x,second)
    testing.expectf(t,resumed.here>0,"the reopened store resumes from the chunks it committed: %d of %d before",resumed.here,part.here)
    testing.expect(t,test_until_complete(&w,1,{second},30),"the second object completes")
    got:=test_peer(n)
    data,_:=test_read(&n.s,second)
    testing.expect(t,string(data)==string(test_bytes(TOTAL,4)),"and reads back its bytes")
    // What it had is not asked again: the data it lacked and the nodes above it.
    testing.expectf(t,got.received<=u64(TOTAL-resumed.here)+u64(store.CHUNK_MAX),"after the reopen %d bytes arrive of the %d missing",got.received,TOTAL-resumed.here)
}

// Two sources, one of which lies; it is asked first, so its lie is met. A
// chunk that fails its address, or a blob's alias to another object or to no
// node, marks the liar for the want, never the honest peer, and the want
// still completes.
@(test)
a_liar_is_marked_and_the_object_still_arrives :: proc(t:^testing.T) {
    for lie in ([]Test_Lie{.Bytes,.Alias,.Nonsense}) {
        w:Test_World
        defer test_world_destroy(&w)
        if !test_world(t,&w,"exchange-liar",3) {return}
        test_host(&w,0,.Server)
        liar:=test_host(&w,1,.Client)
        honest:=test_host(&w,2,.Client)
        w.nodes[1].script,w.nodes[1].lie,w.nodes[1].source=test_liar,lie,&w.nodes[1].s
        size:=3*store.CHUNK_MAX+1000
        blob:=test_put(t,&w.nodes[1].s,size,9)
        w.nodes[1].other=test_object(t,&w.nodes[1].s,test_bytes(size,10))
        test_put(t,&w.nodes[2].s,size,9)
        if !testing.expect(t,test_connect(&w,liar,w.nodes[0].endpoints[0]) && test_connect(&w,honest,w.nodes[0].endpoints[0])) {return}
        r:=&w.nodes[0]
        want(&r.x,blob)
        testing.expectf(t,test_until_complete(&w,0,{blob},20),"%v: the blob arrives",lie)
        testing.expect_value(t,store.verify(&r.s,blob),store.Error.None)
        testing.expectf(t,test_received_by(&r.x,r.hosts[0])=={1,1},"%v: the liar is marked and the honest peer is not",lie)
    }
}

// Flips the byte at at of an object's bytes where a pack of the store at root
// holds it, as damage on the disk would leave it; false when no pack holds
// those bytes.
@(private="file")
pack_damage :: proc(root:string,data:[]u8,at:int) -> bool {
    start:=max(at-32,0)
    needle:=data[start:min(start+64,len(data))]
    entries,_:=os.read_all_directory_by_path(fmt.tprintf("%s/packs",root),context.temp_allocator)
    for e in entries {
        bytes,read_error:=os.read_entire_file(e.fullpath,context.temp_allocator)
        if read_error!=nil {continue}
        found:=strings.index(string(bytes),string(needle))
        if found<0 {continue}
        file,open_error:=os.open(e.fullpath,{.Read,.Write})
        if open_error!=nil {return false}
        defer os.close(file)
        flipped:=[1]u8{bytes[found+at-start]~0xff}
        _,write_error:=os.write_at(file,flipped[:],i64(found+at-start))
        return write_error==nil
    }
    return false
}

// A peer whose copy of a chunk was damaged on its disk serves it, since nothing
// is checked on serve; the receiver reports it, the peer checks its copy and
// tombstones it, so it lacks it from then on and fetches it again.
@(test)
a_receivers_bad_makes_the_server_repair_or_lack :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-damaged",3) {return}
    test_host(&w,0,.Server)
    damaged:=test_host(&w,1,.Client)
    honest:=test_host(&w,2,.Client)
    size:=3*store.CHUNK_MAX+1000
    data:=test_bytes(size,11)
    root:=test_object(t,&w.nodes[1].s,data)
    test_object(t,&w.nodes[2].s,data)
    testing.expect(t,pack_damage(w.nodes[1].s.root,data,size-5),"the damage lands in a pack")
    if !testing.expect(t,test_connect(&w,damaged,w.nodes[0].endpoints[0])) {return}
    r:=&w.nodes[0]
    want(&r.x,root)
    test_step(&w,500)
    testing.expect(t,!test_here(r,root),"the damaged chunk is not taken")
    if !testing.expect(t,test_connect(&w,honest,w.nodes[0].endpoints[0])) {return}
    testing.expect(t,test_until_complete(&w,0,{root},20),"the honest peer completes the object")
    back,_:=test_read(&r.s,root)
    testing.expect(t,string(back)==string(data),"which reads back its bytes")
    o,_:=store.object_open(&w.nodes[1].s,root)
    copy_ok:=store.object_read(&o,0,make([]u8,size,context.temp_allocator))
    store.object_close(&o)
    testing.expect(t,copy_ok!=.None,"the damaged copy is tombstoned: the peer no longer reads it")
    want(&w.nodes[1].x,root)
    testing.expect(t,test_until_complete(&w,1,{root},20),"and fetches it again")
    again,_:=test_read(&w.nodes[1].s,root)
    testing.expect(t,string(again)==string(data),"whole")
}

// A peer serves the chunks it has of an object it is still receiving.
@(test)
a_peer_still_receiving_an_object_serves_its_chunks_to_a_third :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-relay",3) {return}
    test_host(&w,0,.Server)
    b_client:=test_host(&w,1,.Client)
    test_host(&w,1,.Server)
    c_client:=test_host(&w,2,.Client)
    if !testing.expect(t,test_connect(&w,b_client,w.nodes[0].endpoints[0]) && test_connect(&w,c_client,w.nodes[1].endpoints[1])) {return}
    wire.sim_endpoint_conditions(&w.sim,w.nodes[0].endpoints[0],{latency=0.01,bandwidth=2e6})
    root:=test_object(t,&w.nodes[0].s,test_bytes(6<<20,5))
    want(&w.nodes[1].x,root)
    want(&w.nodes[2].x,root)
    relayed:=false
    for w.now<60 && !test_here(&w.nodes[2],root) {
        test_step(&w)
        c,_:=progress(&w.nodes[2].x,root)
        if c.here>0 && !test_here(&w.nodes[1],root) {relayed=true}
    }
    testing.expect(t,relayed,"the third peer receives chunks before the relay has the whole object")
    data,ok:=test_read(&w.nodes[2].s,root)
    testing.expect(t,ok && string(data)==string(test_bytes(6<<20,5)),"the third peer completes the object")
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

// A 60 Hz unreliable message from the source keeps its delay small while objects stream.
@(test)
a_game_channel_keeps_its_delay_small_during_a_transfer :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_pair(t,&w,"exchange-game",game=true) {return}
    latency:=0.02
    wire.sim_endpoint_conditions(&w.sim,w.nodes[0].endpoints[0],{latency=latency,bandwidth=12.5e6})
    wire.sim_endpoint_conditions(&w.sim,w.nodes[1].endpoints[0],{latency=latency})
    roots:=make([]store.Hash,6,context.temp_allocator)
    for &b,k in roots {b=test_object(t,&w.nodes[0].s,test_bytes(8<<20,u64(k)+1))}
    for b in roots {want(&w.nodes[1].x,b)}
    g:=&w.nodes[1].game
    g.latency,g.since=latency,w.now+1
    w.nodes[0].game.since=g.since
    complete:=test_until_complete(&w,1,roots,30)
    testing.expect(t,complete,"the objects arrive")
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

// A peer that was asked a want and then sends only unrelated data loses the
// reservation, and the honest peer serves the object.
@(test)
a_peer_that_holds_a_want_without_progress_loses_it :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-hold",3) {return}
    test_host(&w,0,.Server)
    holder:=test_scripted(t,&w,1,.Hold)
    honest:=test_host(&w,2,.Client)
    root:=test_object(t,&w.nodes[2].s,test_bytes(2*store.CHUNK_MAX+7,6))
    if !testing.expect(t,test_connect(&w,holder,w.nodes[0].endpoints[0]) && test_connect(&w,honest,w.nodes[0].endpoints[0])) {return}
    want(&w.nodes[0].x,root)
    testing.expect(t,test_until_complete(&w,0,{root},15),"the honest peer serves the object once the reservation lapses")
}

// What a peer was marked for leaves with it: the next peer in its slot is not
// blamed for the chunks the first one damaged.
@(test)
a_peer_in_a_freed_slot_is_not_blamed_for_its_predecessor :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-slot",3) {return}
    server:=test_host(&w,0,.Server)
    liar:=test_scripted(t,&w,1,.Bytes)
    honest:=test_host(&w,2,.Client)
    data:=test_bytes(4*store.CHUNK_MAX+1000,8)
    root:=test_object(t,&w.nodes[1].s,data)
    test_object(t,&w.nodes[2].s,data)
    if !testing.expect(t,test_connect(&w,liar,w.nodes[0].endpoints[0])) {return}
    r:=&w.nodes[0]
    want(&r.x,root)
    for _ in 0..<2000 {
        test_step(&w)
        if test_received_by(&r.x,server)[0]==1 {break}
    }
    testing.expect_value(t,test_received_by(&r.x,server),[2]int{1,0})
    wire.host_disconnect(liar)
    for _ in 0..<2000 {
        test_step(&w)
        if server.connection_handles[0]==0 && server.connection_handles[1]==0 {break}
    }
    if !testing.expect(t,test_connect(&w,honest,w.nodes[0].endpoints[0])) {return}
    testing.expect(t,test_until_complete(&w,0,{root},20),"the honest peer in the freed slot completes the object")
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

// The bytes of every chunk of an object in a store: what serving it once sends.
@(private)
test_object_bytes :: proc(s:^store.Store,root:store.Hash) -> (total:u64) {
    buffer:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
    bytes,error:=store.chunk_read(s,root,buffer)
    if error!=.None {return}
    total=u64(len(bytes))
    n,_:=store.node_parse(bytes)
    held:=make([]store.Entry,len(n.entries),context.temp_allocator)
    copy(held,n.entries)
    for e in held {total+=n.level==0?e.size:test_object_bytes(s,e.address)}
    return
}

// After a peer's flight lapses and its want goes to another, its late Done
// does not free what the other was asked: no chunk is served twice.
@(test)
a_late_done_does_not_release_what_another_peer_was_asked :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-late",3) {return}
    test_host(&w,0,.Server)
    late:=test_scripted(t,&w,1,.Late_Done)
    honest:=test_host(&w,2,.Client)
    root:=test_object(t,&w.nodes[2].s,test_bytes(2*store.CHUNK_MAX,3))
    if !testing.expect(t,test_connect(&w,late,w.nodes[0].endpoints[0]) && test_connect(&w,honest,w.nodes[0].endpoints[0])) {return}
    wire.sim_endpoint_conditions(&w.sim,w.nodes[2].endpoints[0],{latency=0.01,bandwidth=0.5e6})
    want(&w.nodes[0].x,root)
    testing.expect(t,test_until_complete(&w,0,{root},30),"the honest peer serves the object")
    served,_:=peer_progress(&w.nodes[2].x,honest,honest.connection_handles[0])
    whole:=test_object_bytes(&w.nodes[2].s,root)
    testing.expectf(t,served.sent==whole,"the honest peer serves %d bytes of %d",served.sent,whole)
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

// A connection that carried a transfer, past the start of its congestion
// window, at a round trip of rtt.
@(private)
test_warm_pair :: proc(t:^testing.T,w:^Test_World,name:string,rtt:f64) -> bool {
    if !test_pair(t,w,name) {return false}
    for e in ([]int{w.nodes[0].endpoints[0],w.nodes[1].endpoints[0]}) {wire.sim_endpoint_conditions(&w.sim,e,{latency=rtt/2})}
    warm:=test_object(t,&w.nodes[0].s,test_bytes(2<<20,1000))
    want(&w.nodes[1].x,warm)
    return testing.expect(t,test_until_complete(w,1,{warm},30),"the warming object arrives")
}

// Small objects wanted together on a connection in use arrive in a few round
// trips however many they are, and one alone in one.
@(test)
many_small_objects_wanted_together_take_round_trips_that_do_not_grow_with_their_count :: proc(t:^testing.T) {
    RTT :: 0.1
    for count in ([]int{1,8,120,250}) {
        w:Test_World
        defer test_world_destroy(&w)
        if !test_warm_pair(t,&w,"exchange-small",RTT) {return}
        roots:=make([]store.Hash,count,context.temp_allocator)
        for &b,k in roots {b=test_object(t,&w.nodes[0].s,test_bytes((1+k%5)*1000,u64(k)+1))}
        start:=w.now
        for b in roots {want(&w.nodes[1].x,b)}
        testing.expectf(t,test_until_complete(&w,1,roots,30),"%d objects arrive",count)
        trips:=(w.now-start)/RTT
        testing.expectf(t,trips<(count==1?1.2:4),"%d small objects take %.2f round trips",count,trips)
    }
}

// An object changed by one byte inserted sends only its new chunks and the
// nodes above them.
@(test)
a_one_byte_insert_sends_only_the_new_chunks :: proc(t:^testing.T) {
    SIZE :: 200<<20
    w:Test_World
    defer test_world_destroy(&w)
    if !test_pair(t,&w,"exchange-insert") {return}
    data:=test_bytes(SIZE+1,77)
    before:=data[:SIZE]
    test_object(t,&w.nodes[1].s,before)
    copy(data[SIZE/2+1:],before[SIZE/2:])
    data[SIZE/2]=0x5a
    after:=test_object(t,&w.nodes[0].s,data)
    want(&w.nodes[1].x,after)
    testing.expect(t,test_until_complete(&w,1,{after},60),"the changed object arrives")
    got:=test_peer(&w.nodes[1])
    fmt.printfln("a one-byte insert in %d bytes: %d bytes received",SIZE,got.received)
    testing.expectf(t,got.received<=512<<10,"%d bytes received",got.received)
    back,_:=test_read(&w.nodes[1].s,after)
    testing.expect(t,string(back)==string(data),"it reads back its bytes")
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
    testing.expectf(t,test_fetch(&w,&j,10) && j.error==.None,"a set of hits returns: %v",j.error)
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
