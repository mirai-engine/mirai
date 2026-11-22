package kai

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import net "mirai:net"
import "mirai:std/base"
import "mirai:store"

// Machines of one test, each with its store and its runner on 127.0.0.1,
// stepped together.
@(private="file")
Box :: struct {
    folder:string,
    machines:[4]Machine,
    runners:[4]Runner,
    open:[4]bool,
    running:[4]bool,
    addresses:[4][1]net.Address,
    blocked:[4][4]net.Address,
    targets:[4][4]net.Address,
}

@(private="file")
box_open :: proc(t:^testing.T,b:^Box,name:string,count:int) -> bool {
    b.folder=base.test_folder(t,name)
    if b.folder=="" {return false}
    for k in 0..<count {
        if !testing.expect_value(t,machine_open(&b.machines[k],fmt.tprintf("%s/m%d",b.folder,k)),Error.None) {return false}
        b.open[k]=true
    }
    return true
}

@(private="file")
box_close :: proc(b:^Box) {
    for k in 0..<4 {
        if b.running[k] {runner_stop(&b.runners[k])}
        if b.open[k] {machine_close(&b.machines[k])}
    }
}

@(private="file")
box_start :: proc(t:^testing.T,b:^Box,k:int,modes:=Node_Modes{},bind:=net.Address{kind=.IP4,ip={0=127,3=1}},beacon_port:=-1) -> bool {
    b.machines[k].changed={}
    e:=runner_start(&b.runners[k],{machine=&b.machines[k],bind=bind,modes=modes,beacon=true,beacon_port=beacon_port,observe_port=0,host_seed=u64(1000+k*100)})
    if !testing.expect_value(t,e,Error.None) {return false}
    b.running[k]=true
    r:=&b.runners[k]
    b.addresses[k][0]=bind
    b.addresses[k][0].port=u16(runner_port(r))
    r.desc.addresses=b.addresses[k][:]
    return true
}

@(private="file")
box_stop :: proc(b:^Box,k:int) {
    if b.running[k] {runner_stop(&b.runners[k])}
    b.running[k]=false
    b.machines[k].changed={}
}

// Beacons of k go to the sockets of the others.
@(private="file")
box_beacons :: proc(b:^Box,k:int,others:..int) {
    n:=0
    for o in others {
        b.targets[k][n]=b.addresses[o][0]
        n+=1
    }
    b.runners[k].desc.beacon_targets=b.targets[k][:n]
}

@(private="file")
box_block :: proc(b:^Box,k:int,others:..int) {
    n:=0
    for o in others {
        b.blocked[k][n]=b.addresses[o][0]
        n+=1
    }
    b.runners[k].desc.blocked=b.blocked[k][:n]
}

@(private="file")
box_step :: proc(b:^Box) {
    for k in 0..<4 {
        if b.running[k] {runner_update(&b.runners[k],0.001)}
    }
}

@(private="file")
box_until :: proc(b:^Box,seconds:f64,data:rawptr,done:proc(b:^Box,data:rawptr) -> bool) -> bool {
    start:=time.tick_now()
    for time.duration_seconds(time.tick_since(start))<seconds {
        box_step(b)
        if done(b,data) {return true}
        free_all(context.temp_allocator)
    }
    return false
}

@(private="file")
box_steps :: proc(b:^Box,seconds:f64) {
    start:=time.tick_now()
    for time.duration_seconds(time.tick_since(start))<seconds {
        box_step(b)
        free_all(context.temp_allocator)
    }
}

// Copies the log of id from one store to another, as a pairing would bring it.
@(private="file")
log_copy :: proc(t:^testing.T,from,to:^store.Store,id:Log_Id,kind:Log_Kind) {
    l:Log
    log_init(&l,id,context.temp_allocator)
    testing.expect_value(t,log_open(from,&l,id,kind),Error.None)
    _,e:=log_save(to,&l)
    testing.expect_value(t,e,Error.None)
}

@(private="file")
user_make :: proc(t:^testing.T,m:^Machine,name:string) {
    buffer:[RECOVERY_TEXT]u8
    text,e:=machine_user_create(m,name,&buffer)
    testing.expect_value(t,e,Error.None)
    seed,ok:=recovery_decode(text)
    testing.expect(t,ok && len(text)==RECOVERY_TEXT,"the recovery key reads back")
    r:=Identity{seed=seed}
    identity_derive(&r)
    l:Log
    log_init(&l,m.user,context.temp_allocator)
    log_open(&m.store,&l,m.user,.User)
    f:User_Fold
    testing.expect_value(t,user_fold(&f,&l,context.temp_allocator),Error.None)
    testing.expect(t,f.recovery==r.key,"the key printed is the user's recovery key")
}

@(private="file")
Goal :: struct {
    k:int,
    project:Log_Id,
    device:Key,
    refs:store.Hash,
    revision:Revision,
    dh:Dh_Key,
    rung:Rung,
}

@(private="file")
refs_arrived :: proc(b:^Box,data:rawptr) -> bool {
    g:=(^Goal)(data)
    s:=&b.machines[g.k].store
    ns:[len(REFS_PREFIX)+64]u8
    name:[32]u8
    held,e:=store.ref_get(s,refs_namespace(g.project,&ns),refs_name(g.device,&name))
    if e!=.None || held!=g.refs {return false}
    present:=make([dynamic]store.Hash,context.temp_allocator)
    missing:=make([dynamic]store.Hash,context.temp_allocator)
    closure_walk(s,{g.revision},&present,&missing)
    return len(missing)==0 && len(present)>=3
}

@(private="file")
connected_by :: proc(b:^Box,data:rawptr) -> bool {
    g:=(^Goal)(data)
    list:=make([dynamic]Runner_Peer_Info,context.temp_allocator)
    runner_peers(&b.runners[g.k],&list)
    for p in list {
        if p.dh==g.dh && (p.class==.Member || p.class==.Node) && (g.rung==.None || p.rung==g.rung) {return true}
    }
    return false
}

@(private="file")
request_shown :: proc(b:^Box,data:rawptr) -> bool {
    _,ok:=runner_pair_request(&b.runners[(^int)(data)^])
    return ok
}

@(private="file")
join_ended :: proc(b:^Box,data:rawptr) -> bool {
    p:=runner_pair_progress(&b.runners[(^int)(data)^])
    return p.phase==.Approved || p.phase==.Denied || p.phase==.Failed
}

// Alice makes a user and an org; Bob, on another machine with its own store,
// pairs as a member through the code over real UDP on 127.0.0.1. A wrong code
// is denied, and a middle that answers the ticket with its own key is
// refused. Then a change Alice snapshots and bookmarks arrives on Bob's
// machine with its whole closure, and an encrypted overlay arrives and opens
// for Bob, a reader of its scope, and for no other key. Once Alice removes
// Bob, his machine is disconnected and gets nothing newer.
@(test)
two_agents_pair_and_sync_a_change_over_loopback_udp :: proc(t:^testing.T) {
    b:=new(Box)
    defer free(b)
    if !box_open(t,b,"kai-runner-pair",2) {return}
    defer box_close(b)
    alice,bob:=&b.machines[0],&b.machines[1]
    user_make(t,alice,"alice")
    user_make(t,bob,"bob")
    org,e:=machine_org_create(alice,"studio")
    testing.expect_value(t,e,Error.None)
    if !box_start(t,b,0) || !box_start(t,b,1) {return}
    box_beacons(b,0,1)
    box_beacons(b,1,0)
    a,c:=&b.runners[0],&b.runners[1]
    ALICE,BOB:=0,1

    // A wrong code denies the request.
    buffer:[TICKET_TEXT]u8
    ticket,te:=runner_pair_offer(a,.Member,org,.Writer,{},&buffer)
    testing.expect_value(t,te,Error.None)
    testing.expect_value(t,runner_pair_join(c,ticket,"bob's laptop"),Error.None)
    if !testing.expect(t,box_until(b,10,&ALICE,request_shown),"the request reaches alice") {return}
    request,_:=runner_pair_request(a)
    testing.expect(t,request.mode==.Member && request.name=="bob's laptop" && request.user==bob.user)
    testing.expect(t,runner_pair_progress(c).code==request.code,"both ends show one code")
    testing.expect_value(t,runner_pair_answer(a,true,"0000-0000"),Error.Unauthorized)
    testing.expect(t,box_until(b,5,&BOB,join_ended))
    testing.expect_value(t,runner_pair_progress(c).phase,Pair_Phase.Denied)
    testing.expect(t,len(bob.orgs)==0)

    // A middle with its own key answers bob's P1: bob refuses it at P2.
    {
        middle:net.Udp
        testing.expect(t,net.udp_open(&middle,net.address_loopback(0)))
        defer net.udp_close(&middle)
        ticket,_=runner_pair_offer(a,.Member,org,.Writer,{},&buffer)
        forged,_:=ticket_decode(ticket)
        forged.addresses[0]=middle.address
        forged_buffer:[TICKET_TEXT]u8
        testing.expect_value(t,runner_pair_join(c,ticket_encode(forged,&forged_buffer),"bob"),Error.None)
        middle_key,_:=net.dh_key()
        p:Pair
        answered:=false
        start:=time.tick_now()
        for time.duration_seconds(time.tick_since(start))<5 && !answered {
            box_step(b)
            t2:=net.udp_transport(&middle)
            frame:[FRAME_MAX]u8
            batch:=[1]net.Datagram{{bytes=frame[:]}}
            if t2.receive(t2.data,batch[:])==0 {continue}
            pair_init(&p,false,middle_key,forged.id)
            if pair_read_p1(&p,batch[0].bytes[1:])!=.None {continue}
            out:[FRAME_MAX]u8
            out[0]=FRAME_PAIR
            p2,_:=pair_write_p2(&p,nil,out[1:])
            reply:=[1]net.Datagram{{batch[0].address,out[:1+len(p2)]}}
            t2.send(t2.data,reply[:])
            answered=true
        }
        testing.expect(t,answered)
        testing.expect(t,box_until(b,5,&BOB,join_ended))
        progress:=runner_pair_progress(c)
        testing.expectf(t,progress.phase==.Failed && progress.why==pair_error_text(.Ticket),"%v %s",progress.phase,progress.why)
        pair_end(&p)
    }

    // The right code pairs bob as a member.
    ticket,_=runner_pair_offer(a,.Member,org,.Writer,{},&buffer)
    testing.expect_value(t,runner_pair_join(c,ticket,"bob's laptop"),Error.None)
    if !testing.expect(t,box_until(b,10,&ALICE,request_shown)) {return}
    request,_=runner_pair_request(a)
    testing.expect_value(t,runner_pair_answer(a,true,request.code),Error.None)
    testing.expect(t,box_until(b,5,&BOB,join_ended))
    testing.expect_value(t,runner_pair_progress(c).phase,Pair_Phase.Approved)
    testing.expect(t,len(bob.orgs)==1 && bob.orgs[0]==org)
    g:=Goal{k=1,dh=Dh_Key(alice.dh.public)}
    if !testing.expect(t,box_until(b,10,&g,connected_by),"bob's agent connects to alice and is admitted") {return}

    // A change alice snapshots and bookmarks arrives at bob's.
    project,pe:=machine_project_add(alice,org,random_id(Repo_Id),"game",false)
    testing.expect_value(t,pe,Error.None)
    g.project,g.device=project,alice.identity.key
    g.revision=test_change(t,&alice.store,&alice.identity,"alice's work")
    testing.expect_value(t,machine_publish_refs(alice,project,{{"main",g.revision}}),Error.None)
    _,g.refs,_=device_refs_get(&alice.store,project,alice.identity.key,context.temp_allocator)
    if !testing.expectf(t,box_until(b,10,&g,refs_arrived),"the change reaches bob: %v",c.orgs[0].agent.stats) {return}

    // An overlay of a scope bob reads arrives and opens for him alone.
    scope,se:=machine_scope_add(alice,org,project,{"secrets/**"},.Reader,false)
    testing.expect_value(t,se,Error.None)
    o:Org_State
    testing.expect_value(t,org_state_load(&alice.store,org,&o,context.temp_allocator),Error.None)
    keyrings:=make([dynamic]^Keyring_Fold,context.temp_allocator)
    testing.expect_value(t,machine_keyrings(&alice.store,&o,&keyrings,context.temp_allocator),Error.None)
    if !testing.expect_value(t,len(keyrings),1) {return}
    root:=fmt.tprintf("%s/ws",b.folder)
    os.make_directory_all(fmt.tprintf("%s/secrets",root))
    _=os.write_entire_file(fmt.tprintf("%s/readme.txt",root),transmute([]u8)string("public"))
    _=os.write_entire_file(fmt.tprintf("%s/secrets/key.txt",root),transmute([]u8)string("the private words"))
    routing:=Overlay_Routing{org=&o.fold,project=project,keyrings=keyrings[:],device=machine_overlay_device(alice)}
    w:Workspace
    if !testing.expect_value(t,workspace_create(&w,root,&alice.store,alice.identity,{overlay=&routing}),Error.None) {return}
    commit:=repo_working(&w.repo)
    workspace_close(&w)
    ovl_ns:[len(OVERLAY_PREFIX)+64+1+32]u8
    hex:[64]u8
    runner_changed(a,overlay_namespace(project,scope,&ovl_ns),store.hex(commit,&hex))
    Overlay_Goal :: struct {project:Log_Id,scope:Scope_Id,commit:Revision}
    og:=Overlay_Goal{project,scope,commit}
    arrived :: proc(b:^Box,data:rawptr) -> bool {
        g:=(^Overlay_Goal)(data)
        r,_,e:=overlay_record_get(&b.machines[1].store,g.project,g.scope,g.commit,context.temp_allocator)
        if e!=.None {return false}
        for x in r.objects {
            if !object_whole(&b.machines[1].store,x) {return false}
        }
        return object_whole(&b.machines[1].store,r.tree_root)
    }
    if !testing.expect(t,box_until(b,10,&og,arrived),"the overlay's ciphertext reaches bob") {return}
    bo:Org_State
    testing.expect_value(t,org_state_load(&bob.store,org,&bo,context.temp_allocator),Error.None)
    bob_rings:=make([dynamic]^Keyring_Fold,context.temp_allocator)
    machine_keyrings(&bob.store,&bo,&bob_rings,context.temp_allocator)
    if testing.expect_value(t,len(bob_rings),1) {
        device:=machine_overlay_device(bob)
        ov:Overlay
        testing.expect_value(t,overlay_open(&ov,&bob.store,bob_rings[0],&device,commit,context.temp_allocator),Error.None)
        bytes,fe:=overlay_file(&ov,&bob.store,"secrets/key.txt",context.temp_allocator)
        testing.expect(t,fe==.None && string(bytes)=="the private words","bob reads the private file")
        overlay_close(&ov)
        stranger:=Overlay_Device{identity=identity_make()}
        key,_:=net.dh_key()
        stranger.dh,stranger.dh_secret=Dh_Key(key.public),key.private
        other:Overlay
        testing.expect(t,overlay_open(&other,&bob.store,bob_rings[0],&stranger,commit,context.temp_allocator)!=.None,"a key no envelope names opens nothing")
    }

    // Bob is removed: alice's agent drops him and he gets nothing newer.
    testing.expect_value(t,machine_member_remove(alice,org,bob.user),Error.None)
    gone :: proc(b:^Box,data:rawptr) -> bool {
        bob:=(^Dh_Key)(data)
        for p in b.runners[0].orgs[0].agent.peers {
            if p.used && p.dh==bob^ {return false}
        }
        return true
    }
    bob_dh:=Dh_Key(bob.dh.public)
    testing.expect(t,box_until(b,5,&bob_dh,gone),"a removed member's connection is revoked")
    newer:=test_change(t,&alice.store,&alice.identity,"after bob left")
    testing.expect_value(t,machine_publish_refs(alice,project,{{"main",newer}}),Error.None)
    box_steps(b,2)
    testing.expect(t,!object_present(&bob.store,newer),"bob gets nothing newer")
}

// A node in relay and seed mode on 127.0.0.1. Alice publishes a change while
// Bob is away; the node mirrors it, Alice closes, and Bob takes it from the
// node alone. Then Alice comes back with every direct path between the two
// blocked: the node plans a hole punch, which fails, and relays them.
@(test)
a_relay_node_joins_two_agents_that_cannot_reach_each_other :: proc(t:^testing.T) {
    b:=new(Box)
    defer free(b)
    if !box_open(t,b,"kai-runner-relay",3) {return}
    defer box_close(b)
    alice,bob,node:=&b.machines[0],&b.machines[1],&b.machines[2]
    user_make(t,alice,"alice")
    user_make(t,bob,"bob")
    org,e:=machine_org_create(alice,"studio")
    testing.expect_value(t,e,Error.None)
    log_copy(t,&bob.store,&alice.store,bob.user,.User)
    testing.expect_value(t,machine_member_add(alice,org,bob.user,.Writer),Error.None)
    if !box_start(t,b,2,{.Relay,.Seed}) {return}
    testing.expect_value(t,machine_node_add(alice,org,node.identity.key,Dh_Key(node.dh.public),{.Relay,.Seed},b.addresses[2][:]),Error.None)
    testing.expect_value(t,machine_org_join(node,org),Error.None)
    for id in ([]Log_Id{org,alice.user}) {log_copy(t,&alice.store,&bob.store,id,id==org?.Org:.User)}
    testing.expect_value(t,machine_org_join(bob,org),Error.None)
    project,pe:=machine_project_add(alice,org,random_id(Repo_Id),"game",true)
    testing.expect_value(t,pe,Error.None)

    // Alice publishes while bob is away; the seed takes the whole closure.
    if !box_start(t,b,0) {return}
    first:=Goal{k=2,project=project,device=alice.identity.key}
    first.revision=test_change(t,&alice.store,&alice.identity,"before bob came")
    testing.expect_value(t,machine_publish_refs(alice,project,{{"main",first.revision}}),Error.None)
    _,first.refs,_=device_refs_get(&alice.store,project,alice.identity.key,context.temp_allocator)
    if !testing.expectf(t,box_until(b,10,&first,refs_arrived),"the seed mirrors: node %v folded %v projects %d peers %v",b.runners[2].orgs[0].agent.stats,b.runners[2].orgs[0].agent.folded,len(b.runners[2].orgs[0].agent.org.projects),node_classes(&b.runners[2])) {return}
    box_stop(b,0)
    if !box_start(t,b,1) {return}
    first.k=1
    if !testing.expect(t,box_until(b,15,&first,refs_arrived),"bob takes it from the seed with alice gone") {return}

    // Alice comes back; nothing passes between the two but through the node.
    if !box_start(t,b,0) {return}
    box_block(b,0,1)
    box_block(b,1,0)
    lower:=dh_less(Dh_Key(alice.dh.public),Dh_Key(bob.dh.public))?0:1
    relayed:=Goal{k=lower,dh=Dh_Key(b.machines[1-lower].dh.public),rung=.Relayed}
    if !testing.expectf(t,box_until(b,20,&relayed,connected_by),"the node relays the two: %v %v %v",ladder_of(&b.runners[lower],Dh_Key(b.machines[1-lower].dh.public)),b.runners[2].relay.devices[:],b.runners[lower].observe_ports[:]) {return}
    relayed.k=1-lower
    relayed.dh=Dh_Key(b.machines[lower].dh.public)
    testing.expect(t,box_until(b,5,&relayed,connected_by),"each end sees the connection relayed")
    second:=Goal{k=1,project=project,device=alice.identity.key}
    second.revision=test_change(t,&alice.store,&alice.identity,"while blocked")
    testing.expect_value(t,machine_publish_refs(alice,project,{{"main",second.revision}}),Error.None)
    _,second.refs,_=device_refs_get(&alice.store,project,alice.identity.key,context.temp_allocator)
    testing.expect(t,box_until(b,10,&second,refs_arrived),"a change crosses")
    stats:=b.runners[2].relay.devices
    forwarded:=u64(0)
    for d in stats {forwarded+=d.forwarded}
    testing.expect(t,forwarded>0,"the node forwarded datagrams")
}

// Two members on ::1 alone. Bob's beacon reaches Alice's IPv6 beacon socket,
// which reads it as the IPv4 one does; Alice's reaches Bob's socket the same
// way, and they connect on the LAN rung over IPv6.
@(test)
an_ipv6_beacon_joins_two_members_over_loopback :: proc(t:^testing.T) {
    b:=new(Box)
    defer free(b)
    if !box_open(t,b,"kai-runner-beacon6",2) {return}
    defer box_close(b)
    alice,bob:=&b.machines[0],&b.machines[1]
    user_make(t,alice,"alice")
    user_make(t,bob,"bob")
    org,e:=machine_org_create(alice,"studio")
    testing.expect_value(t,e,Error.None)
    log_copy(t,&bob.store,&alice.store,bob.user,.User)
    testing.expect_value(t,machine_member_add(alice,org,bob.user,.Writer),Error.None)
    for id in ([]Log_Id{org,alice.user}) {log_copy(t,&alice.store,&bob.store,id,id==org?.Org:.User)}
    testing.expect_value(t,machine_org_join(bob,org),Error.None)

    probe:net.Udp
    if !testing.expect(t,net.udp_open(&probe,net.address_loopback6(0)),"::1 opens") {return}
    port:=int(probe.address.port)
    net.udp_close(&probe)
    if !box_start(t,b,0,bind=net.address_loopback6(0),beacon_port=port) || !box_start(t,b,1,bind=net.address_loopback6(0)) {return}
    testing.expect(t,b.runners[0].has_beacon_socket6,"alice listens for IPv6 beacons")
    b.targets[0][0]=b.addresses[1][0]
    b.targets[1][0]=net.address_loopback6(port)
    b.runners[0].desc.beacon_targets=b.targets[0][:1]
    b.runners[1].desc.beacon_targets=b.targets[1][:1]
    for k in 0..<2 {
        g:=Goal{k=k,dh=Dh_Key(b.machines[1-k].dh.public),rung=.LAN}
        if !testing.expectf(t,box_until(b,10,&g,connected_by),"%d connects on the LAN rung",k) {return}
    }
    o:=b.runners[0].orgs[0]
    k:=runner_peer_index(o,Dh_Key(bob.dh.public))
    testing.expect(t,k>=0 && o.peers[k].lan==b.addresses[1][0],"alice took bob's [::1] from his beacon")
}

// Every message a runner reads from its socket or a local process: random
// bytes, cuts and lengths past their bounds are dropped or refused, under the
// memory tracker, and the runner goes on.
@(test)
runner_refuses_hostile_datagrams :: proc(t:^testing.T) {
    b:=new(Box)
    defer free(b)
    if !box_open(t,b,"kai-runner-hostile",2) {return}
    defer box_close(b)
    alice:=&b.machines[0]
    user_make(t,alice,"alice")
    org,_:=machine_org_create(alice,"studio")
    if !box_start(t,b,0,{}) || !box_start(t,b,1,{.Relay}) {return}
    for k in 0..<2 {
        r:=&b.runners[k]
        r.control.locked=true
        r.control.token={1=1}
        box_step(b)
        from:=net.address_loopback(9)
        state:=u64(0x9e3779b97f4a7c15)
        next :: proc(state:^u64) -> u64 {
            state^=state^*6364136223846793005+1442695040888963407
            return state^>>33
        }
        frame:[FRAME_MAX+64]u8
        kinds:=[]u8{FRAME_SERVER,FRAME_CLIENT,FRAME_RELAY,FRAME_FROM,FRAME_RENDEZVOUS,FRAME_BEACON,FRAME_PAIR,FRAME_LOCAL,FRAME_ANSWER,0,255}
        for round in 0..<4000 {
            size:=int(next(&state)%u64(len(frame)))
            for &x in frame[:size] {x=u8(next(&state))}
            if size>0 {frame[0]=kinds[round%len(kinds)]}
            if size>1 && frame[0]==FRAME_PAIR {frame[1]=u8(next(&state)%5)}
            if size>CONTROL_HEAD && frame[0]==FRAME_LOCAL && round%2==0 {
                copy(frame[1:],r.control.token[:])
                frame[CONTROL_HEAD-1]=u8(next(&state)%12)
            }
            for port in 0..<3 {runner_frame(r,from,frame[:size],port)}
            if round%500==0 {box_step(b)}
        }
        // A rendezvous message under the right key, its body cut and too long.
        if k==1 {
            key,_:=runner_shared(r,Dh_Key(alice.dh.public))
            for type in Z_Type {
                for size in ([]int{0,1,2,size_of(Z_Plan)-1,size_of(Z_Plan),size_of(Z_Plan)+3,200}) {
                    out:[size_of(Z_Head)+256+Z_MAC]u8
                    head:=Z_Head{frame=FRAME_RENDEZVOUS,type=type,from=Dh_Key(alice.dh.public),time=time.now()._nsec}
                    copy(out[:],(cast([^]u8)&head)[:size_of(Z_Head)])
                    for &x in out[size_of(Z_Head):][:size] {x=u8(next(&state))}
                    if size>0 {out[size_of(Z_Head)]=0}
                    if size>1 {out[size_of(Z_Head)+1]=u8(next(&state)%6)}
                    mac:=keyed_hash(key[:],out[:size_of(Z_Head)+size])
                    copy(out[size_of(Z_Head)+size:],mac[:Z_MAC])
                    runner_frame(r,from,out[:size_of(Z_Head)+size+Z_MAC],0)
                    runner_frame(r,from,out[:size_of(Z_Head)+size+Z_MAC],1)
                }
            }
        }
    }
    // What an approved pairing carries, cut and out of bounds.
    c:=&b.runners[1]
    for size in ([]int{0,1,31,33,64,32*(MACHINE_ORGS_MAX+3)}) {
        payload:=make([]u8,size,context.temp_allocator)
        c.join.active=true
        c.join.ticket.mode=.Member
        testing.expect(t,!runner_pair_take(c,payload),"zero ids and lengths out of shape are refused")
    }
    // Tickets, recovery keys and the runner's answers to a local process that do not read.
    state:=u64(7)
    alphabet:="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_!"
    for _ in 0..<2000 {
        state=state*6364136223846793005+1442695040888963407
        text:[TICKET_TEXT+4]u8
        n:=int(state>>40)%len(text)
        for &x in text[:n] {
            state=state*6364136223846793005+1442695040888963407
            x=alphabet[(state>>33)%65]
        }
        ticket_decode(string(text[:n]))
        recovery_decode(string(text[:n]))
        answer:=transmute([]u8)string(text[:n])
        list:=make([dynamic]Runner_Peer_Info,context.temp_allocator)
        peers_parse(answer,&list)
        pair_request_parse(answer)
        pair_progress_parse(answer)
        ddc_answer_parse(answer)
        take_text(answer)
    }
    peers:=make([dynamic]Runner_Peer_Info,context.temp_allocator)
    runner_peers(&b.runners[0],&peers)
    testing.expect(t,len(b.runners[0].orgs)==1 && b.runners[0].orgs[0].id==org,"the runner goes on")
}

@(private="file")
node_classes :: proc(r:^Runner) -> [dynamic]Agent_Class {
    out:=make([dynamic]Agent_Class,context.temp_allocator)
    for p in r.orgs[0].agent.peers {
        if p.used {append(&out,p.class)}
    }
    return out
}

@(private="file")
ladder_of :: proc(r:^Runner,dh:Dh_Key) -> [5]f64 {
    for p in r.orgs[0].peers {
        if p.dh==dh {return {f64(p.stage),p.planned,p.asked,f64(p.attempt),f64(p.relay.kind)}}
    }
    return {-1,-1,-1,-1,-1}
}
