package exchange

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:std/base"
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

// An object of size bytes of seed, committed: its root.
@(private)
test_put :: proc(t:^testing.T,s:^store.Store,size:int,seed:u64) -> store.Hash {
    return test_object(t,s,test_bytes(size,seed))
}

// An object of bytes, committed: its root.
@(private)
test_object :: proc(t:^testing.T,s:^store.Store,data:[]u8) -> store.Hash {
    root,error:=store.put(s,data)
    testing.expect_value(t,error,store.Error.None)
    testing.expect_value(t,store.commit(s),store.Error.None)
    return root
}

// Whether the object at root reads whole from a store.
@(private)
test_whole :: proc(s:^store.Store,root:store.Hash) -> bool {
    _,whole:=test_read(s,root)
    return whole
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
objects_of_every_size_arrive_verified_under_loss_and_jitter :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_pair(t,&w,"exchange-loss") {return}
    M:=store.CHUNK_MAX
    sizes:=[]int{0,1,store.CHUNK_MIN-1,M,M+1,3*M+17,6<<20}
    addresses:=make([]store.Hash,len(sizes),context.temp_allocator)
    for size,k in sizes {addresses[k]=test_put(t,&w.nodes[0].s,size,u64(k)+1)}
    for e in w.nodes[0].endpoints[:1] {wire.sim_endpoint_conditions(&w.sim,e,{latency=0.02,jitter=0.005,loss=0.05})}
    wire.sim_endpoint_conditions(&w.sim,w.nodes[1].endpoints[0],{latency=0.02,jitter=0.005,loss=0.05})
    for a in addresses {testing.expect_value(t,want(&w.nodes[1].x,a),Error.None)}
    testing.expect(t,test_until_complete(&w,1,addresses,60),"everything arrives")
    s:=&w.nodes[1].s
    for size,k in sizes {
        data,ok:=test_read(s,addresses[k])
        testing.expect(t,ok && string(data)==string(test_bytes(size,u64(k)+1)),"the object reads back its bytes")
        p,_:=progress(&w.nodes[1].x,addresses[k])
        testing.expect(t,p.state==.Complete && p.here==i64(size) && p.total==i64(size),"progress counts the whole object")
    }
    rate:=test_peer(&w.nodes[1])
    testing.expect(t,rate.received>=6<<20 && rate.receive_rate>0,"the peer's rate is measured")
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
    test_step(&w,3)
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
// chunk that fails its address marks the liar for the want, never the honest
// peer, and the want still completes.
@(test)
a_liar_is_marked_and_the_object_still_arrives :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-liar",3) {return}
    test_host(&w,0,.Server)
    liar:=test_host(&w,1,.Client)
    honest:=test_host(&w,2,.Client)
    w.nodes[1].script,w.nodes[1].lie,w.nodes[1].source=test_liar,.Bytes,&w.nodes[1].s
    size:=3*store.CHUNK_MAX+1000
    object:=test_put(t,&w.nodes[1].s,size,9)
    test_put(t,&w.nodes[2].s,size,9)
    if !testing.expect(t,test_connect(&w,liar,w.nodes[0].endpoints[0]) && test_connect(&w,honest,w.nodes[0].endpoints[0])) {return}
    r:=&w.nodes[0]
    want(&r.x,object)
    testing.expect(t,test_until_complete(&w,0,{object},20),"the object arrives")
    data,ok:=test_read(&r.s,object)
    testing.expect(t,ok && string(data)==string(test_bytes(size,9)),"with its bytes")
    testing.expect(t,test_received_by(&r.x,r.hosts[0])=={1,1},"the liar is marked and the honest peer is not")
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
test_expose_lib :: proc(user:rawptr,peer:Peer_Id,namespace:string) -> bool {return namespace=="lib"}

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
    cancel:bool,
    done:bool,
}

@(private)
test_job :: proc(j:^Test_Job) {
    if j.names!=nil {
        j.error=fetch_refs(j.x,j.namespace,j.names,j.addresses,cancel=&j.cancel)
    } else if j.addresses!=nil {
        j.error=fetch_all(j.x,j.addresses,cancel=&j.cancel)
    } else if j.namespace!="" {
        j.found,j.error=fetch_ref(j.x,j.namespace,j.name,cancel=&j.cancel)
    } else {
        j.error=fetch(j.x,j.address,cancel=&j.cancel)
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
    testing.expect(t,test_fetch(&w,&j,10) && j.error==.None && test_whole(&w.nodes[1].s,hit),"a hit returns once the object is here")
    _,still:=progress(x,hit)
    testing.expect(t,!still,"a fetch leaves no want behind")
    // A want kept complete whose object a sweep removed is fetched again: success is what the store says.
    want(x,hit)
    _,swept:=store.sweep(&w.nodes[1].s,nil,time.time_add(time.now(),2*store.GRACE))
    testing.expect(t,swept==.None && !store.chunk_has(&w.nodes[1].s,hit),"a sweep removes the object")
    j={x=x,address=hit}
    testing.expect(t,test_fetch(&w,&j,10) && j.error==.None && test_whole(&w.nodes[1].s,hit),"a swept object is fetched again")
    forget(x,hit)
    keyed:=test_put(t,&w.nodes[0].s,3000,2)
    store.ref_set(&w.nodes[0].s,"lib","derived",keyed)
    j={x=x,namespace="lib",name="derived"}
    testing.expect(t,test_fetch(&w,&j,10) && j.error==.None && j.found==keyed && test_whole(&w.nodes[1].s,keyed),"a ref hit returns its object")
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
    testing.expect(t,!test_whole(&w.nodes[1].s,big),"the disconnect came before the object")
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

// A connected peer that never answers a question is taken to know nothing of
// it in bounded time, and its credits come back: questions after the first
// credits' worth end too.
@(test)
a_question_a_silent_peer_never_answers_ends :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-silent-question",2) {return}
    test_host(&w,0,.Server)
    silent:=test_scripted(t,&w,1,.Hold)
    if !testing.expect(t,test_connect(&w,silent,w.nodes[0].endpoints[0])) {return}
    x:=&w.nodes[0].x
    for round in 0..<QUERY_CREDITS+2 {
        q,_:=ref_ask(x,"lib",fmt.tprintf("name-%d",round))
        started:=w.now
        r:Query_Result
        for w.now-started<4*QUERY_SECONDS {
            test_step(&w)
            if r,_=query_result(x,q);r.state!=.Waiting {break}
        }
        query_end(x,q)
        if !testing.expectf(t,r.state==.Not_Found,"question %d ends: %v after %.1f s",round,r.state,w.now-started) {return}
    }
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
    // The thread may start late on a loaded machine: destroy comes once it waits.
    for _ in 0..<10000 {
        sync.mutex_lock(&n.x.lock)
        waiting:=n.x.waiting
        sync.mutex_unlock(&n.x.lock)
        if waiting>0 {break}
        time.sleep(time.Millisecond)
    }
    testing.expect(t,!sync.atomic_load(&j.done),"the fetch waits on the silent peer")
    destroy(&n.x)
    n.open=false
    thread.join(th)
    thread.destroy(th)
    testing.expect_value(t,j.error,Error.Closed)
}

// A cancel wakes a fetch that waits on a peer that never answers, of an
// object or of a ref: it returns Cancelled and leaves no want or question.
@(test)
a_cancel_wakes_a_waiting_fetch :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-cancel",2) {return}
    test_host(&w,0,.Server)
    silent:=test_scripted(t,&w,1,.Hold)
    if !testing.expect(t,test_connect(&w,silent,w.nodes[0].endpoints[0])) {return}
    n:=&w.nodes[0]
    for by_ref in ([2]bool{false,true}) {
        j:=Test_Job{x=&n.x,address=store.address_of_bytes(test_bytes(10,5))}
        if by_ref {j.namespace,j.name="lib","held"}
        th:=thread.create_and_start_with_poly_data(&j,test_job)
        for _ in 0..<10000 {
            test_step(&w)
            sync.mutex_lock(&n.x.lock)
            waiting:=n.x.waiting
            sync.mutex_unlock(&n.x.lock)
            if waiting>0 {break}
        }
        test_step(&w,200)
        testing.expect(t,!sync.atomic_load(&j.done),"the fetch waits on the silent peer")
        fetch_cancel(&n.x,&j.cancel)
        thread.join(th)
        thread.destroy(th)
        testing.expect_value(t,j.error,Error.Cancelled)
        _,still:=progress(&n.x,j.address)
        testing.expect(t,!still,"no want is left behind")
    }
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
    objects:=make([]store.Hash,40,context.temp_allocator)
    for &o,k in objects {o=test_put(t,&w.nodes[0].s,(k%7)*30000+1,u64(k)+1)}
    j:=Test_Job{x=x,addresses=objects}
    testing.expectf(t,test_fetch(&w,&j,10) && j.error==.None,"a set of hits returns: %v",j.error)
    for b in objects {
        testing.expect(t,test_whole(here,b),"every object is here")
        _,still:=progress(x,b)
        testing.expect(t,!still,"a fetch_all leaves no want behind")
    }
    // More names than query slots, so the form waits for slots to free.
    names:=[]string{"a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t"}
    for name,k in names {store.ref_set(&w.nodes[0].s,"lib",name,test_put(t,&w.nodes[0].s,5000*(k+1),u64(100+k)))}
    j={x=x,namespace="lib",names=names,addresses=make([]store.Hash,len(names),context.temp_allocator)}
    testing.expect(t,test_fetch(&w,&j,10) && j.error==.None,"a set of ref hits returns")
    for a in j.addresses {testing.expect(t,a!={} && test_whole(here,a),"each ref's object is here")}
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
    testing.expect(t,!test_whole(here,big[0]) || !test_whole(here,big[1]),"the disconnect came before the objects")
}

// A batch of refs that came back missing leaves its query slots to free as
// their answers arrive: the next batch, asked at once, waits for them and
// finds what it names instead of failing as full.
@(test)
a_batch_of_refs_waits_for_the_slots_of_the_last :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-refs-full",2,desc={expose=test_expose_lib}) {return}
    test_host(&w,0,.Server)
    client:=test_host(&w,1,.Client)
    if !testing.expect(t,test_connect(&w,client,w.nodes[0].endpoints[0])) {return}
    present:=test_put(t,&w.nodes[0].s,3000,7)
    store.ref_set(&w.nodes[0].s,"lib","present",present)
    x:=&w.nodes[1].x
    // Every slot holds a question asked and ended whose answer is on its way.
    wire.sim_endpoint_conditions(&w.sim,w.nodes[0].endpoints[0],{latency=0.1})
    asked:=make([]Query,len(x.queries),context.temp_allocator)
    for &q,k in asked {q,_=ref_ask(x,"lib",fmt.tprintf("absent-%d",k))}
    test_step(&w,2)
    for q in asked {query_end(x,q)}
    j:=Test_Job{x=x,namespace="lib",names={"present"},addresses=make([]store.Hash,1,context.temp_allocator)}
    th:=thread.create_and_start_with_poly_data(&j,test_job)
    defer {thread.join(th);thread.destroy(th)}
    // Nothing steps until the job returned or waits: no slot frees before it asks.
    for !sync.atomic_load(&j.done) {
        sync.mutex_lock(&x.lock)
        waiting:=x.waiting>0
        sync.mutex_unlock(&x.lock)
        if waiting {break}
        thread.yield()
    }
    for step:=0;!sync.atomic_load(&j.done) && step<10_000;step+=1 {test_step(&w)}
    testing.expectf(t,sync.atomic_load(&j.done) && j.error==.None && j.addresses[0]==present,"the batch finds its ref: %v",j.error)
}

// An object of ten gigabytes moves with the memory of each side bounded by
// its window, not by the object: its leaves are a pool of distinct chunks, each
// used many times in an order that makes every leaf node differ, so the walk
// covers every entry while the disks hold only the pool.
@(test)
a_ten_gigabyte_object_moves_within_bounded_memory :: proc(t:^testing.T) {
    SIZE :: u64(10_000_000_000)
    POOL :: 8192
    CHUNK :: 64<<10
    w:Test_World
    defer test_world_destroy(&w)
    if !test_pair(t,&w,"exchange-large") {return}
    s:=&w.nodes[0].s
    pool:=make([]store.Hash,POOL)
    defer delete(pool)
    for &a,k in pool {
        bytes:=test_bytes(CHUNK,u64(k)+1)
        a=store.address_of_bytes(bytes)
        testing.expect_value(t,store.chunk_put(s,a,bytes),store.Error.None)
        free_all(context.temp_allocator)
    }
    tree:store.Tree
    store.tree_init(&tree,{procedure=proc(data:rawptr,kind:store.Chunk_Kind,address:store.Hash,bytes:[]u8) -> store.Error {
        return store.chunk_put((^store.Store)(data),address,bytes)
    },data=s})
    defer store.tree_destroy(&tree)
    store.tree_group(&tree,0,0)
    for p:=u64(0);p*CHUNK<SIZE;p+=1 {
        size:=min(u64(CHUNK),SIZE-p*CHUNK)
        h:=p*0x9e3779b97f4a7c15
        h~=h>>29
        a:=pool[h%POOL]
        if size<CHUNK {
            tail:=test_bytes(int(size),99)
            a=store.address_of_bytes(tail)
            store.chunk_put(s,a,tail)
        }
        if !testing.expect_value(t,store.tree_put_leaf(&tree,a,size),store.Error.None) {return}
    }
    root,total,error:=store.tree_finish(&tree)
    testing.expect(t,error==.None && total==SIZE,"the object is built")
    testing.expect_value(t,store.commit(s),store.Error.None)
    free_all(context.temp_allocator)
    base_mem:=base.process_memory().private
    peak:=base_mem
    x:=&w.nodes[1].x
    want(x,root)
    for step:=0;w.now<600 && test_state(x,root)!=.Complete;step+=1 {
        test_step(&w)
        if step%100==0 {
            peak=max(peak,base.process_memory().private)
            free_all(context.temp_allocator)
        }
    }
    p,_:=progress(x,root)
    testing.expectf(t,p.state==.Complete && p.total==i64(SIZE),"the object arrives: %v",p)
    got:=test_peer(&w.nodes[1])
    fmt.printfln("10 GB object: %d bytes received, peak growth %d bytes on both sides together",got.received,peak-base_mem)
    // The footprint is the process's, where other tests running beside this one count:
    // the bound is checked with -define:ODIN_TEST_THREADS=1.
    when #config(ODIN_TEST_THREADS,0)==1 {
        testing.expectf(t,base==0 || peak-base<=64<<20,"peak growth %d bytes",peak-base)
    }
}

// Bytes that compress: runs of a few values.
@(private="file")
compressible :: proc(size:int,seed:u64) -> []u8 {
    bytes:=make([]u8,size,context.temp_allocator)
    state:=seed
    for at:=0;at<size; {
        state=state*6364136223846793005+1442695040888963407
        value,run:=u8(state>>61),1+int(state>>58)
        for k in 0..<min(run,size-at) {bytes[at+k]=value}
        at+=run
    }
    return bytes
}

// Peers exchange compressed chunks both ways and recover the original objects.
@(test)
peers_exchange_compressed_objects_both_ways :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_pair(t,&w,"exchange-codecs") {return}
    other:=&w.nodes[1]
    size:=3*store.CHUNK_MAX+11
    mine,theirs:=compressible(size,1),compressible(size,2)
    a:=test_object(t,&w.nodes[0].s,mine)
    b:=test_object(t,&other.s,theirs)
    testing.expect_value(t,want(&other.x,a),Error.None)
    testing.expect_value(t,want(&w.nodes[0].x,b),Error.None)
    testing.expect(t,test_until_complete(&w,1,{a},30) && test_until_complete(&w,0,{b},30),"both objects arrive")
    for n in ([]^Test_Node{&w.nodes[0],other}) {
        got_a,whole_a:=test_read(&n.s,a)
        got_b,whole_b:=test_read(&n.s,b)
        testing.expect(t,whole_a && whole_b && string(got_a)==string(mine) && string(got_b)==string(theirs),"each store reads both")
        testing.expectf(t,test_peer(n).received<u64(size),"its chunks came encoded: %d bytes for %d",test_peer(n).received,size)
    }
}

// A walk that finds more chunks than the table of needs takes has passed
// them: the want walks again for them, and is complete only once its object
// reads whole. Wants whose roots find the table full ask them once it has room.
@(test)
wants_past_a_full_table_of_needs_complete_whole :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_world(t,&w,"exchange-needs-full",2,desc={needs=64}) {return}
    server:=test_host(&w,0,.Server)
    client:=test_host(&w,1,.Client)
    if !testing.expect(t,server!=nil && client!=nil && test_connect(&w,client,w.nodes[0].endpoints[0])) {return}
    // Two objects whose roots the receiver has: their walks find their data at once.
    walked:[2]store.Hash
    buffer:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
    for &root,k in walked {
        root=test_put(t,&w.nodes[0].s,48*store.CHUNK_AVG,u64(k)+41)
        bytes,read_error:=store.chunk_read(&w.nodes[0].s,root,buffer)
        if !testing.expect_value(t,read_error,store.Error.None) {return}
        testing.expect_value(t,store.chunk_put(&w.nodes[1].s,root,bytes),store.Error.None)
    }
    testing.expect_value(t,store.commit(&w.nodes[1].s),store.Error.None)
    // More small objects than the table holds needs.
    small:[80]store.Hash
    for &root,k in small {root=test_put(t,&w.nodes[0].s,100,u64(k)+500)}
    all:=make([dynamic]store.Hash,context.temp_allocator)
    append(&all,..walked[:])
    append(&all,..small[:])
    for root in all {testing.expect_value(t,want(&w.nodes[1].x,root),Error.None)}
    testing.expect(t,test_until_complete(&w,1,all[:],60),"every want completes")
    for root,k in all {testing.expectf(t,test_whole(&w.nodes[1].s,root),"object %d reads whole once complete",k)}
}

// A server node 0 and clients 1 and 2 connected in that order, which the
// server tags 1 and 2; restricted: the tags it adds restricted, a bit each.
@(private)
test_star :: proc(t:^testing.T,w:^Test_World,name:string,desc:Desc,restricted:=u64(0)) -> bool {
    if !test_world(t,w,name,3,desc=desc) {return false}
    w.nodes[0].restricted=restricted
    server:=test_host(w,0,.Server)
    a:=test_host(w,1,.Client)
    b:=test_host(w,2,.Client)
    if server==nil || a==nil || b==nil {return testing.expect(t,false,"the hosts open")}
    return testing.expect(t,test_connect(w,a,w.nodes[0].endpoints[0]) && test_connect(w,b,w.nodes[0].endpoints[0]),"the peers connect")
}

@(private)
test_query :: proc(w:^Test_World,x:^Exchange,q:Query) -> Query_Result {
    for _ in 0..<2000 {
        test_step(w)
        if r,_:=query_result(x,q);r.state!=.Waiting {return r}
    }
    return {}
}

// lib for every peer, team only for the first one added.
@(private)
test_expose_by_tag :: proc(user:rawptr,peer:Peer_Id,namespace:string) -> bool {
    return namespace=="lib" || namespace=="team" && peer.tag==1
}

// Keeps what a peer told in the node whose host heard it; user is the Test_World.
@(private)
test_hint :: proc(user:rawptr,peer:Peer_Id,namespace,name:string,address:store.Hash) {
    w:=(^Test_World)(user)
    for &n in w.nodes[:w.count] {
        for h in n.hosts[:n.host_count] {
            if h!=peer.host || n.heard_count==len(n.heard) {continue}
            n.heard[n.heard_count]={peer.tag,strings.clone(namespace,context.temp_allocator),strings.clone(name,context.temp_allocator),address}
            n.heard_count+=1
        }
    }
}

@(test)
peer_aware_expose_gates_namespaces_by_peer :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_star(t,&w,"exchange-expose-peer",{expose=test_expose_by_tag}) {return}
    s:=&w.nodes[0].s
    blob:=test_put(t,s,1000,1)
    store.ref_set(s,"lib","a",blob)
    store.ref_set(s,"team","a",blob)
    for k in 1..=2 {
        x:=&w.nodes[k].x
        h:=w.nodes[k].hosts[0]
        q,_:=ref_ask(x,"team","a")
        r:=test_query(&w,x,q)
        testing.expectf(t,(r.state==.Found)==(k==1),"client %d reads team: %v",k,r.state)
        query_end(x,q)
        q,_=names_ask(x,h,h.connection_handles[0],"team")
        r=test_query(&w,x,q)
        testing.expectf(t,r.state==.Found && len(r.names)==(k==1?1:0),"client %d lists %d names of team",k,len(r.names))
        query_end(x,q)
        q,_=ref_ask(x,"lib","a")
        testing.expectf(t,test_query(&w,x,q).state==.Found,"client %d reads lib",k)
        query_end(x,q)
    }
}

// A change reaches the peers that may read its namespace, and no other, as
// soon as it is told; changes of one ref not yet sent go as the last. The
// peer fetches what the hint names without asking for the ref.
@(test)
ref_changed_hint_wakes_peer :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    if !test_star(t,&w,"exchange-hint",{expose=test_expose_by_tag,hint=test_hint,user=&w}) {return}
    x:=&w.nodes[0].x
    s:=&w.nodes[0].s
    old:=test_put(t,s,1000,1)
    blob:=test_put(t,s,3*store.CHUNK_MAX+5,2)
    testing.expect_value(t,ref_changed(x,"lib","a",old),Error.None)
    testing.expect_value(t,ref_changed(x,"lib","a",blob),Error.None)
    testing.expect_value(t,ref_changed(x,"team","b",blob),Error.None)
    testing.expect_value(t,ref_changed(x,"Team","b",blob),Error.Invalid)
    testing.expect_value(t,ref_changed(x,"lib","",blob),Error.Invalid)
    a,b:=&w.nodes[1],&w.nodes[2]
    steps:=0
    for ;steps<1000 && (a.heard_count<2 || b.heard_count<1);steps+=1 {test_step(&w)}
    testing.expectf(t,steps<200,"the hints arrive in %d ms",steps)
    test_step(&w,200)
    testing.expect(t,a.heard_count==2 && a.heard[0]==Test_Heard{1,"lib","a",blob} && a.heard[1]==Test_Heard{1,"team","b",blob},"a peer that may read both namespaces hears the last change of each")
    testing.expect(t,b.heard_count==1 && b.heard[0]==Test_Heard{1,"lib","a",blob},"a peer that may not read a namespace hears nothing of it")
    testing.expect_value(t,w.nodes[0].heard_count,0)
    want(&a.x,a.heard[0].address)
    testing.expect(t,test_until_complete(&w,1,{blob},5),"the peer fetches what the hint names")
}

// Allowed addresses of test_serve, fixed while the exchange runs.
@(private)
Test_Allowed :: struct {addresses,asked:[dynamic]store.Hash}

@(private)
test_asked :: proc(user:rawptr,peer:Peer_Id,address:store.Hash) {
    append(&(^Test_Allowed)(user).asked,address)
}

@(private)
test_serve :: proc(user:rawptr,peer:Peer_Id,address:store.Hash) -> bool {
    for a in (^Test_Allowed)(user).addresses {
        if a==address {return true}
    }
    return false
}

// The root and every chunk under it.
@(private)
test_closure :: proc(s:^store.Store,root:store.Hash,out:^[dynamic]store.Hash) {
    append(out,root)
    bytes,error:=store.chunk_read(s,root,make([]u8,store.CHUNK_MAX,context.temp_allocator))
    if error!=.None {return}
    n,parse_error:=store.node_parse(bytes)
    if parse_error!=.None {return}
    for e in n.entries {
        if n.level>0 {test_closure(s,e.address,out)} else {append(out,e.address)}
    }
}

// A restricted peer gets only what the serve filter allows, also as a
// descendant streamed under an allowed root; the rest is lacked as if
// missing and never reaches its store. A peer that is not restricted gets all.
@(test)
anonymous_peer_cannot_fetch_unexposed_chunks :: proc(t:^testing.T) {
    w:Test_World
    defer test_world_destroy(&w)
    allowed:Test_Allowed
    allowed.addresses=make([dynamic]store.Hash,context.temp_allocator)
    allowed.asked=make([dynamic]store.Hash,context.temp_allocator)
    if !test_star(t,&w,"exchange-serve",{serve=test_serve,asked=test_asked,user=&allowed},restricted=1<<1) {return}
    s:=&w.nodes[0].s
    public:=test_put(t,s,200<<10,1)
    private:=test_put(t,s,200<<10,2)
    half:=test_put(t,s,200<<10,3) // its root alone is allowed
    test_closure(s,public,&allowed.addresses)
    append(&allowed.addresses,half)
    hidden:=make([dynamic]store.Hash,context.temp_allocator)
    test_closure(s,private,&hidden)
    under:=len(hidden)
    test_closure(s,half,&hidden)
    testing.expect(t,len(hidden)-under>2,"the root that is allowed has chunks under it")
    anonymous:=&w.nodes[1]
    want(&anonymous.x,public)
    testing.expect(t,test_until_complete(&w,1,{public},5),"what the filter allows arrives whole")
    want(&anonymous.x,private)
    want(&anonymous.x,half)
    for _ in 0..<5000 {
        test_step(&w)
        if test_state(&anonymous.x,private)!=.Asking && test_state(&anonymous.x,half)!=.Asking {break}
    }
    testing.expect_value(t,test_state(&anonymous.x,private),State.Missing)
    testing.expect_value(t,test_state(&anonymous.x,half),State.Missing)
    for a,k in hidden {
        if a==half {continue}
        testing.expectf(t,!store.chunk_has(&anonymous.s,a),"chunk %d the filter does not allow stays out of the store",k)
    }
    want(&w.nodes[2].x,private)
    want(&w.nodes[2].x,half)
    testing.expect(t,test_until_complete(&w,2,{private,half},5),"a peer that is not restricted gets every chunk")
    told:=false
    for a in allowed.asked {told||=a==private}
    testing.expect(t,told,"the end that serves is told what its peers ask")
}
