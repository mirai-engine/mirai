package kai

import "core:fmt"
import cnet "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import net "mirai:net"
import "mirai:std/base"
import "mirai:std/blake3"
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
box_start :: proc(t:^testing.T,b:^Box,k:int,modes:=Node_Modes{},bind:=net.Address{kind=.IP4,ip={0=127,3=1}},beacon_port:=-1,tcp_port:=0,relay_tcp_port:=0) -> bool {
    b.machines[k].changed={}
    e:=runner_start(&b.runners[k],{machine=&b.machines[k],bind=bind,modes=modes,beacon=true,beacon_port=beacon_port,observe_port=0,host_seed=u64(1000+k*100),tcp_port=tcp_port,relay_tcp_port=relay_tcp_port})
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
    seed,why:=recovery_decode(text)
    testing.expect(t,why=="" && len(text)==RECOVERY_TEXT,"the recovery key reads back")
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

// A node that no address of the ticket reaches (the admin is behind a router)
// is paired through the admin's knocks at the node's own address: it asks
// where a knock of its ticket came from. A knock with another tag and a P2 of
// another ticket change nothing.
@(test)
a_node_no_ticket_address_reaches_is_paired_through_knocks :: proc(t:^testing.T) {
    b:=new(Box)
    defer free(b)
    if !box_open(t,b,"kai-runner-knock",2) {return}
    defer box_close(b)
    alice,node:=&b.machines[0],&b.machines[1]
    user_make(t,alice,"alice")
    org,e:=machine_org_create(alice,"studio")
    testing.expect_value(t,e,Error.None)
    if !box_start(t,b,0) || !box_start(t,b,1,{.Relay,.Seed}) {return}
    a,n:=&b.runners[0],&b.runners[1]
    ALICE,NODE:=0,1
    // Where nothing listens: a socket opened for its port and closed.
    dead:net.Udp
    testing.expect(t,net.udp_open(&dead,net.address_loopback(0)))
    nowhere:=dead.address
    net.udp_close(&dead)

    buffer,forged_buffer:[TICKET_TEXT]u8
    ticket,te:=runner_pair_offer(a,.Node,org,.None,{.Relay,.Seed},&buffer)
    testing.expect_value(t,te,Error.None)
    forged,_:=ticket_decode(ticket)
    forged.addresses[0],forged.address_count=nowhere,1
    testing.expect_value(t,runner_pair_join(n,ticket_encode(forged,&forged_buffer),"node"),Error.None)

    other:net.Udp
    testing.expect(t,net.udp_open(&other,net.address_loopback(0)))
    defer net.udp_close(&other)
    t2:=net.udp_transport(&other)
    wrong:[1+PAIR_HEAD]u8
    wrong[0],wrong[1]=FRAME_PAIR,u8(Pair_Message.Knock)
    raw:=forged.id
    copy(wrong[2:],raw[:])
    p2:[1+PAIR_HEAD+64]u8
    p2[0],p2[1]=FRAME_PAIR,u8(Pair_Message.P2)
    for frame in ([][]u8{wrong[:],p2[:]}) {
        out:=[1]net.Datagram{{b.addresses[1][0],frame}}
        t2.send(t2.data,out[:])
    }
    for _ in 0..<20 {box_step(b)}
    testing.expect(t,n.join.knock.kind==.None,"a knock with the ticket's id in place of its tag is not heard")
    testing.expect_value(t,runner_pair_progress(n).phase,Pair_Phase.Asking)
    _,shown:=runner_pair_request(a)
    testing.expect(t,!shown,"no ticket address reaches alice")

    // Alice knocks at the node's address: the node asks her there.
    a.offer.at=b.addresses[1][0]
    if !testing.expect(t,box_until(b,10,&ALICE,request_shown),"the node's request reaches alice through her knocks") {return}
    request,_:=runner_pair_request(a)
    testing.expect(t,request.mode==.Node && runner_pair_progress(n).code==request.code,"both ends show one code")
    testing.expect_value(t,runner_pair_answer(a,true,request.code),Error.None)
    testing.expect(t,box_until(b,5,&NODE,join_ended))
    testing.expect_value(t,runner_pair_progress(n).phase,Pair_Phase.Approved)
    testing.expect(t,len(node.orgs)==1 && node.orgs[0]==org)
    g:=Goal{k=1,dh=Dh_Key(alice.dh.public)}
    testing.expect(t,box_until(b,10,&g,connected_by),"the node connects to alice and is admitted")
}

// Alice makes a user and an org; Bob, on another machine with its own store,
// pairs as a member through the code over real UDP on 127.0.0.1. A wrong code
// is denied, and a middle that answers the ticket with its own key is
// refused. Then a change Alice snapshots and bookmarks arrives on Bob's
// machine with its whole closure, and an encrypted overlay arrives and opens
// for Bob, a reader of its scope, and for no other key, as it does on what
// Alice's new, describe, restore and rebase of the change write. A machine
// Alice links then opens it with no rotation. Once Alice removes Bob, his
// machine is disconnected and gets nothing newer.
@(test)
two_agents_pair_and_sync_a_change_over_loopback_udp :: proc(t:^testing.T) {
    b:=new(Box)
    defer free(b)
    if !box_open(t,b,"kai-runner-pair",3) {return}
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

    // Pairing a member again brings its machine back and changes no role.
    ticket,_=runner_pair_offer(a,.Member,org,.Reader,{},&buffer)
    testing.expect_value(t,runner_pair_join(c,ticket,"bob's laptop"),Error.None)
    if !testing.expect(t,box_until(b,10,&ALICE,request_shown)) {return}
    request,_=runner_pair_request(a)
    testing.expect_value(t,runner_pair_answer(a,true,request.code),Error.None)
    testing.expect(t,box_until(b,5,&BOB,join_ended))
    testing.expect_value(t,runner_pair_progress(c).phase,Pair_Phase.Approved)
    {
        again:Org_State
        if testing.expect_value(t,machine_org_open(alice,org,&again),Error.None) {
            testing.expect_value(t,org_role(&again.fold,bob.user),Role.Writer)
            org_state_destroy(&again)
        }
    }
    if !testing.expect(t,box_until(b,10,&g,connected_by),"bob's agent is connected to alice after the second pairing") {return}

    // A change alice snapshots and bookmarks arrives at bob's.
    project,pe:=machine_project_add(alice,org,random_id(Repo_Id),"game",false)
    testing.expect_value(t,pe,Error.None)
    g.project,g.device=project,alice.identity.key
    g.revision=test_change(t,&alice.store,&alice.identity,"alice's work")
    test_written(t,&alice.store,project,g.revision)
    testing.expect_value(t,machine_publish_refs(alice,project,{{"main",g.revision}}),Error.None)
    _,g.refs,_=device_refs_get(&alice.store,project,alice.identity.key,context.temp_allocator)
    if !testing.expectf(t,box_until(b,10,&g,refs_arrived),"the change reaches bob: %v",c.orgs[0].agent.stats) {return}

    // A proposal alice opens reaches bob open, and landed once she lands it.
    {
        proposed:=test_change(t,&alice.store,&alice.identity,"alice's next")
        test_written(t,&alice.store,project,proposed)
        change,_:=change_get(&alice.store,proposed,context.temp_allocator)
        proposal,oe:=machine_proposal_open(alice,project,"main","Next","why",{{change.id,proposed}})
        testing.expect_value(t,oe,Error.None)
        Proposal_Goal :: struct {project,proposal:Log_Id,status:Proposal_Status}
        pg:=Proposal_Goal{project,proposal,.Open}
        proposal_is :: proc(b:^Box,data:rawptr) -> bool {
            g:=(^Proposal_Goal)(data)
            ps:Project_State
            f,e:=machine_proposal_load(&b.machines[1],g.project,g.proposal,&ps)
            if e!=.None {return false}
            defer project_state_destroy(&ps)
            return f.status==g.status
        }
        if !testing.expect(t,box_until(b,10,&pg,proposal_is),"the proposal reaches bob") {return}
        testing.expect_value(t,machine_proposal_land(alice,project,proposal),Error.None)
        pg.status=.Landed
        if !testing.expect(t,box_until(b,10,&pg,proposal_is),"bob's machine learns the proposal landed") {return}
    }

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
    if !testing.expect_value(t,workspace_create(&w,root,&alice.store,alice.identity,overlay=&routing),Error.None) {return}
    defer workspace_close(&w)
    commit:=repo_working(&w.repo)
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
            if !object_whole(&b.machines[1].store,x,scratch_make()) {return false}
        }
        return object_whole(&b.machines[1].store,r.tree_root,scratch_make())
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

    // What each rewrite of alice's writes holds the change's private file (a restore, the one of
    // the change it restores from; a new change, its parent's), and bob, told of its record,
    // opens the same bytes there. Each round folds again what box_until let go.
    Rewrite_Kind :: enum {New,Describe,Restore,Rebase}
    held:=commit
    for kind in Rewrite_Kind {
        ao:Org_State
        testing.expect_value(t,org_state_load(&alice.store,org,&ao,context.temp_allocator),Error.None)
        alice_rings:=make([dynamic]^Keyring_Fold,context.temp_allocator)
        machine_keyrings(&alice.store,&ao,&alice_rings,context.temp_allocator)
        routing=Overlay_Routing{org=&ao.fold,project=project,keyrings=alice_rings[:],device=machine_overlay_device(alice)}
        rewritten:Revision
        re:Error
        switch kind {
        case .New: rewritten,re=change_new(&w.repo,{held},"next")
        case .Describe: rewritten,re=change_describe(&w.repo,held,"described")
        case .Restore: rewritten,re=change_restore(&w.repo,held,commit)
        case .Rebase: rewritten,re=change_rebase(&w.repo,held,{g.revision})
        }
        if !testing.expectf(t,re==.None,"%v: %v",kind,re) {break}
        runner_changed(a,overlay_namespace(project,scope,&ovl_ns),store.hex(rewritten,&hex))
        og.commit=rewritten
        if !testing.expectf(t,box_until(b,10,&og,arrived),"the record of what %v wrote reaches bob",kind) {break}
        testing.expect_value(t,org_state_load(&bob.store,org,&bo,context.temp_allocator),Error.None)
        bob_rings=make([dynamic]^Keyring_Fold,context.temp_allocator)
        machine_keyrings(&bob.store,&bo,&bob_rings,context.temp_allocator)
        if !testing.expect_value(t,len(bob_rings),1) {break}
        device:=machine_overlay_device(bob)
        ov:Overlay
        testing.expect_value(t,overlay_open(&ov,&bob.store,bob_rings[0],&device,rewritten,context.temp_allocator),Error.None)
        bytes,fe:=overlay_file(&ov,&bob.store,"secrets/key.txt",context.temp_allocator)
        testing.expectf(t,fe==.None && string(bytes)=="the private words","bob reads the private file of what %v wrote",kind)
        overlay_close(&ov)
        held=rewritten
    }
    w.repo.overlay=nil

    // Alice links a second machine: her agent wraps the scope's newest key for it, which opens the
    // private file as soon as the logs arrive, with no rotation.
    desktop:=&b.machines[2]
    if !box_start(t,b,2) {return}
    box_beacons(b,0,1,2)
    box_beacons(b,2,0)
    ticket,_=runner_pair_offer(a,.Device,{},.None,{},&buffer)
    testing.expect_value(t,runner_pair_join(&b.runners[2],ticket,"alice's desktop"),Error.None)
    if !testing.expect(t,box_until(b,10,&ALICE,request_shown)) {return}
    request,_=runner_pair_request(a)
    testing.expect_value(t,runner_pair_answer(a,true,request.code),Error.None)
    DESKTOP:=2
    testing.expect(t,box_until(b,5,&DESKTOP,join_ended))
    testing.expect(t,desktop.user==alice.user,"the second machine is alice's device")
    og.commit=held
    reads :: proc(b:^Box,data:rawptr) -> bool {
        g:=(^Overlay_Goal)(data)
        m:=&b.machines[2]
        if len(m.orgs)==0 {return false}
        o:Org_State
        if org_state_load(&m.store,m.orgs[0],&o,context.temp_allocator)!=.None {return false}
        rings:=make([dynamic]^Keyring_Fold,context.temp_allocator)
        machine_keyrings(&m.store,&o,&rings,context.temp_allocator)
        if len(rings)!=1 {return false}
        device:=machine_overlay_device(m)
        ov:Overlay
        if overlay_open(&ov,&m.store,rings[0],&device,g.commit,context.temp_allocator)!=.None {return false}
        defer overlay_close(&ov)
        bytes,e:=overlay_file(&ov,&m.store,"secrets/key.txt",context.temp_allocator)
        return e==.None && string(bytes)=="the private words" && rings[0].epoch==1
    }
    testing.expect(t,box_until(b,15,&og,reads),"alice's new machine reads the private file with no rotation")

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
    test_written(t,&alice.store,project,newer)
    testing.expect_value(t,machine_publish_refs(alice,project,{{"main",newer}}),Error.None)
    box_steps(b,2)
    testing.expect(t,!object_present(&bob.store,newer),"bob gets nothing newer")
}

// A node in relay and seed mode on 127.0.0.1. Alice publishes a change while
// Bob is away; the node mirrors it, Alice closes, and Bob takes it from the
// node alone. Then Alice comes back with every direct path between the two
// blocked: the node plans a hole punch, which fails, and relays them. With UDP
// to the node blocked too, both reach it over its relay's TCP port, which
// relays them as well; once the node answers over UDP again, Alice leaves TCP.
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
    if !box_start(t,b,2,{.Relay,.Seed},tcp_port=-1) {return}
    tcp_port:=runner_tcp_port(&b.runners[2])
    testing.expect(t,tcp_port>0,"the node listens for its relay over TCP")
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
    test_written(t,&alice.store,project,first.revision)
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
    if !testing.expectf(t,box_until(b,20,&relayed,connected_by),"the node relays the two: %v %v",ladder_of(&b.runners[lower],Dh_Key(b.machines[1-lower].dh.public)),b.runners[2].relay.devices[:]) {return}
    relayed.k=1-lower
    relayed.dh=Dh_Key(b.machines[lower].dh.public)
    testing.expect(t,box_until(b,5,&relayed,connected_by),"each end sees the connection relayed")
    second:=Goal{k=1,project=project,device=alice.identity.key}
    second.revision=test_change(t,&alice.store,&alice.identity,"while blocked")
    test_written(t,&alice.store,project,second.revision)
    testing.expect_value(t,machine_publish_refs(alice,project,{{"main",second.revision}}),Error.None)
    _,second.refs,_=device_refs_get(&alice.store,project,alice.identity.key,context.temp_allocator)
    testing.expect(t,box_until(b,10,&second,refs_arrived),"a change crosses")
    stats:=b.runners[2].relay.devices
    forwarded:=u64(0)
    for d in stats {forwarded+=d.forwarded}
    testing.expect(t,forwarded>0,"the node forwarded datagrams")

    // UDP to the node is blocked as well: each comes back, the one that is
    // dialed first.
    for k in ([]int{1-lower,lower}) {
        box_stop(b,k)
        if !box_start(t,b,k,relay_tcp_port=tcp_port) {return}
        b.blocked[k][0],b.blocked[k][1]=b.addresses[1-k][0],b.addresses[2][0]
        b.runners[k].desc.blocked=b.blocked[k][:2]
        over_tcp:=Goal{k=k,dh=Dh_Key(node.dh.public),rung=.Tcp}
        if !testing.expectf(t,box_until(b,20,&over_tcp,connected_by),"%d reaches the node over TCP: %v",k,ladder_of(&b.runners[k],Dh_Key(node.dh.public))) {return}
    }
    relayed.k,relayed.dh,relayed.rung=lower,Dh_Key(b.machines[1-lower].dh.public),.Tcp
    if !testing.expectf(t,box_until(b,20,&relayed,connected_by),"the node relays the two over TCP: %v",ladder_of(&b.runners[lower],Dh_Key(b.machines[1-lower].dh.public))) {return}
    third:=Goal{k=1,project=project,device=alice.identity.key}
    third.revision=test_change(t,&alice.store,&alice.identity,"over tcp")
    test_written(t,&alice.store,project,third.revision)
    testing.expect_value(t,machine_publish_refs(alice,project,{{"main",third.revision}}),Error.None)
    _,third.refs,_=device_refs_get(&alice.store,project,alice.identity.key,context.temp_allocator)
    testing.expect(t,box_until(b,10,&third,refs_arrived),"a change crosses over TCP")

    // UDP to the node opens again for Alice: its next probe takes her back.
    b.runners[0].desc.blocked=b.blocked[0][:1]
    for s in b.runners[0].tcp {s.probed=-TCP_PROBE_SECONDS}
    back:=Goal{k=0,dh=Dh_Key(node.dh.public),rung=.LAN}
    testing.expectf(t,box_until(b,10,&back,connected_by),"alice reaches the node over UDP again: %v",ladder_of(&b.runners[0],Dh_Key(node.dh.public)))
}

// The relay's TCP port of a node: a wrong magic, a frame past its bounds, a
// magic or frame that stops coming, and more connections from one address
// than it takes are refused within their bounds; random frames are dropped
// as random datagrams are, and the node goes on.
@(test)
a_relay_node_refuses_hostile_and_slow_tcp :: proc(t:^testing.T) {
    b:=new(Box)
    defer free(b)
    if !box_open(t,b,"kai-runner-tcp",1) {return}
    defer box_close(b)
    if !box_start(t,b,0,{.Relay},tcp_port=-1) {return}
    r:=&b.runners[0]
    endpoint:=cnet.Endpoint{cnet.IP4_Loopback,runner_tcp_port(r)}
    open :: proc(endpoint:cnet.Endpoint,bytes:[]u8) -> cnet.TCP_Socket {
        socket,e:=cnet.dial_tcp(endpoint)
        if e!=nil {return {}}
        cnet.send_tcp(socket,bytes)
        return socket
    }
    streams :: proc(r:^Runner) -> int {
        n:=0
        for s in r.tcp {
            if !s.failed {n+=1}
        }
        return n
    }
    settle :: proc(b:^Box) {
        for _ in 0..<20 {
            box_step(b)
            time.sleep(time.Millisecond)
        }
    }
    magic:=RELAY_TCP_MAGIC
    frame :: proc(size:int,head:u8,out:[]u8) -> []u8 {
        out[0],out[1]=u8(size>>8),u8(size)
        for &x,i in out[2:][:min(size,len(out)-2)] {x=u8(i*31)}
        if size>0 {out[2]=head}
        return out[:2+min(size,len(out)-2)]
    }
    Case :: struct {name:string,bytes:[]u8}
    cut:[64]u8
    big:[8]u8
    small:[8]u8
    cases:=[]Case{
        {"a TLS hello is no magic",{0x16,3,1,0,5}},
        {"a wrong magic",transmute([]u8)string("GET / HTTP/1.1\r\n")},
        {"a frame past FRAME_MAX",frame(FRAME_MAX+1,FRAME_SERVER,big[:])},
        {"a frame under two bytes",frame(1,FRAME_SERVER,small[:])},
    }
    for c in cases {
        bytes:=make([dynamic]u8,context.temp_allocator)
        if c.name!=cases[0].name && c.name!=cases[1].name {append(&bytes,..transmute([]u8)magic)}
        append(&bytes,..c.bytes)
        socket:=open(endpoint,bytes[:])
        defer cnet.close(socket)
        settle(b)
        testing.expectf(t,streams(r)==0,"%s ends the connection",c.name)
    }
    // A magic, then a frame, that stop coming end at their deadlines.
    for stalled in 0..<2 {
        bytes:=make([dynamic]u8,context.temp_allocator)
        append(&bytes,..transmute([]u8)magic[:stalled==0?4:len(magic)])
        if stalled==1 {append(&bytes,..frame(40,FRAME_SERVER,cut[:])[:10])}
        socket:=open(endpoint,bytes[:])
        defer cnet.close(socket)
        settle(b)
        testing.expect(t,streams(r)==1,"a connection that is on its way is held")
        for s in r.tcp {
            s.opened-=TCP_MAGIC_SECONDS+1
            s.active-=TCP_IDLE_SECONDS+1
        }
        settle(b)
        testing.expectf(t,streams(r)==0,"a connection stalled at %d ends",stalled)
    }
    // Random frames are dropped; the connection and the node go on.
    sockets:[TCP_PER_ADDRESS+2]cnet.TCP_Socket
    state:=u64(0x9e3779b97f4a7c15)
    for &socket,i in sockets {
        socket=open(endpoint,transmute([]u8)magic)
        if i>0 {continue}
        kinds:=[]u8{FRAME_SERVER,FRAME_CLIENT,FRAME_RELAY,FRAME_FROM,FRAME_RENDEZVOUS,FRAME_BEACON,FRAME_PAIR,FRAME_LOCAL,0}
        for round in 0..<300 {
            state=state*6364136223846793005+1442695040888963407
            out:[2+FRAME_MAX]u8
            f:=frame(2+int(state>>33)%(FRAME_MAX-1),kinds[round%len(kinds)],out[:])
            for &x in f[3:] {
                state=state*6364136223846793005+1442695040888963407
                x=u8(state>>56)
            }
            cnet.send_tcp(socket,f)
            if round%50==0 {box_step(b)}
        }
    }
    settle(b)
    defer for socket in sockets {cnet.close(socket)}
    testing.expectf(t,streams(r)==TCP_PER_ADDRESS,"one address holds at most %d connections: %d",TCP_PER_ADDRESS,streams(r))
    // What a peer does not read is queued up to its bound, then dropped.
    s:=r.tcp[0]
    datagram:[FRAME_MAX]u8
    for _ in 0..<2*TCP_OUTPUT_MAX/FRAME_MAX {
        testing.expect(t,runner_tcp_send(r,s.address,datagram[:]),"the connection carries what goes to its address")
    }
    testing.expect(t,s.output_len<=TCP_OUTPUT_MAX,"the queue stays within its bound")
    testing.expect(t,len(r.orgs)==0 && r.has_tcp,"the node goes on")
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

// A node keeps an org a user made on its web view for others: it takes no
// derived data of it, whatever its Node_Add says, and once what it holds of
// the org reaches its bound it takes nothing more the org publishes, and its
// Welcome tells the publishing machine, which says how to fix it. The org its
// operator paired it into is bound by neither, and the node serves both.
@(test)
a_hosted_org_keeps_no_derived_data_and_stops_at_its_bound :: proc(t:^testing.T) {
    b:=new(Box)
    defer free(b)
    if !box_open(t,b,"kai-runner-hosted",2) {return}
    defer box_close(b)
    alice,node:=&b.machines[0],&b.machines[1]
    user_make(t,alice,"alice")
    hosted,e:=machine_org_create(alice,"hosted")
    testing.expect_value(t,e,Error.None)
    own,oe:=machine_org_create(alice,"own")
    testing.expect_value(t,oe,Error.None)
    if !box_start(t,b,1,{.Relay,.Seed,.DDC}) {return}
    b.runners[1].desc.hosted_quota=64<<10
    projects:[2]Log_Id
    for org,i in ([2]Log_Id{hosted,own}) {
        testing.expect_value(t,machine_node_add(alice,org,node.identity.key,Dh_Key(node.dh.public),{.Relay,.Seed,.DDC},b.addresses[1][:]),Error.None)
        pe:Error
        projects[i],pe=machine_project_add(alice,org,random_id(Repo_Id),"game",false)
        testing.expect_value(t,pe,Error.None)
        log_copy(t,&alice.store,&node.store,org,.Org)
    }
    log_copy(t,&alice.store,&node.store,alice.user,.User)
    testing.expect_value(t,machine_org_host(node,hosted,alice.user),Error.None)
    testing.expect_value(t,machine_org_join(node,own),Error.None)
    _,is_hosted:=store_org_hosted(&node.store,hosted)
    _,is_own:=store_org_hosted(&node.store,own)
    testing.expect(t,is_hosted && !is_own && store_hosted_count(&node.store,alice.user)==1,"the node marks the hosted org alone, by who made it")
    if !box_start(t,b,0) {return}
    Said :: struct {text:[1024]u8,count:int}
    said:Said
    b.runners[0].desc.event={&said,proc(data:rawptr,text:string) {
        s:=(^Said)(data)
        if strings.contains(text,"full") {s.count=copy(s.text[:],text)}
    }}

    // Derived data of both orgs, and a change past the bound in each project.
    key:=store.Hash{0=7}
    output,pe:=store.put(&alice.store,transmute([]u8)string("built"))
    testing.expect_value(t,pe,store.Error.None)
    big:=strings.repeat("x",128<<10,context.temp_allocator)
    goals:[2]Goal
    for org,i in ([2]Log_Id{hosted,own}) {
        _,de:=machine_publish_ddc(alice,org,key,{output},nil)
        testing.expect_value(t,de,Error.None)
        goals[i]=Goal{k=1,project=projects[i],device=alice.identity.key}
        goals[i].revision=test_change(t,&alice.store,&alice.identity,big)
        test_written(t,&alice.store,projects[i],goals[i].revision)
        testing.expect_value(t,machine_publish_refs(alice,projects[i],{{"main",goals[i].revision}}),Error.None)
        _,goals[i].refs,_=device_refs_get(&alice.store,projects[i],alice.identity.key,context.temp_allocator)
    }
    for &g,i in goals {
        if !testing.expectf(t,box_until(b,15,&g,refs_arrived),"the node mirrors the first change of org %d",i) {return}
    }
    ddc_held :: proc(s:^store.Store,org:Log_Id,key:store.Hash) -> bool {
        ns:[len(DDC_PREFIX)+64]u8
        name:[64]u8
        _,e:=store.ref_get(s,ddc_namespace(org,&ns),store.hex(key,&name))
        return e==.None
    }
    Held :: struct {s:^store.Store,org:Log_Id,key:store.Hash}
    held:=Held{&node.store,own,key}
    testing.expect(t,box_until(b,10,&held,proc(b:^Box,data:rawptr) -> bool {
        h:=(^Held)(data)
        return ddc_held(h.s,h.org,h.key)
    }),"the operator's org takes derived data")
    testing.expect(t,!ddc_held(&node.store,hosted,key),"the hosted org takes none, whatever its Node_Add says")
    var_hosted,var_own:^Runner_Org
    for o in b.runners[1].orgs {
        if o.id==hosted {var_hosted=o}
        if o.id==own {var_own=o}
    }
    if !testing.expect(t,var_hosted!=nil && var_own!=nil,"the node serves both orgs") {return}
    testing.expectf(t,agent_full(&var_hosted.agent) && var_hosted.agent.members.stored>=64<<10,"the hosted org is at its bound: %d bytes",var_hosted.agent.members.stored)
    testing.expect(t,!agent_full(&var_own.agent),"the operator's org has none")

    // A second change: the operator's org takes it, the hosted one refuses it and says so.
    for org,i in ([2]Log_Id{hosted,own}) {
        goals[i].revision=test_change(t,&alice.store,&alice.identity,"after the bound")
        test_written(t,&alice.store,projects[i],goals[i].revision)
        testing.expect_value(t,machine_publish_refs(alice,projects[i],{{"main",goals[i].revision}}),Error.None)
        _,goals[i].refs,_=device_refs_get(&alice.store,projects[i],alice.identity.key,context.temp_allocator)
        _=org
    }
    if !testing.expect(t,box_until(b,15,&goals[1],refs_arrived),"the operator's org takes what comes past the bound") {return}
    box_steps(b,1)
    testing.expect(t,!refs_arrived(b,&goals[0]),"the hosted org takes nothing past its bound")
    b.runners[0].hello_at=-1
    Full :: struct {org:Log_Id}
    full:=Full{hosted}
    testing.expect(t,box_until(b,10,&full,proc(b:^Box,data:rawptr) -> bool {
        infos:=make([dynamic]Runner_Org_Info,context.temp_allocator)
        runner_orgs_info(&b.runners[0],&infos)
        for x in infos {
            if x.org==(^Full)(data).org && x.full {return true}
        }
        return false
    }),"the node's Welcome tells the publishing machine the hosted org is full")
    infos:=make([dynamic]Runner_Org_Info,context.temp_allocator)
    runner_orgs_info(&b.runners[0],&infos)
    for x in infos {
        if x.org==own {testing.expect(t,!x.full,"the operator's org is not")}
    }
    text:=string(said.text[:said.count])
    testing.expectf(t,strings.contains(text,"is full") && strings.contains(text,"mirai kai pair offer node"),"the machine is told how to fix it: %s",text)
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
            shared:=runner_shared(r,Dh_Key(alice.dh.public))
            key:=shared.key
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
        orgs:=make([dynamic]Runner_Org_Info,context.temp_allocator)
        peers_parse(answer,&list,&orgs)
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

// What a store must hold of a lone owner's org for a recovery to find all of
// it: the org's, project's, keyring's and proposal's logs, the keyring's
// envelopes, the closure of commit, which main names, and its overlay.
@(private="file")
Org_Goal :: struct {k:int,org,project,proposal:Log_Id,scope:Scope_Id,commit:Revision,user:Log_Id}

@(private="file")
org_held :: proc(b:^Box,data:rawptr) -> bool {
    g:=(^Org_Goal)(data)
    s:=&b.machines[g.k].store
    o:Org_State
    if org_state_load(s,g.org,&o,context.temp_allocator)!=.None || org_project_index(&o.fold,g.project)<0 {return false}
    name:[64]u8
    for id in ([]Log_Id{g.project,g.proposal}) {
        if _,e:=store.ref_get(s,LOG_NAMESPACE,log_name(id,&name));e!=.None {return false}
    }
    rings:=make([dynamic]^Keyring_Fold,context.temp_allocator)
    machine_keyrings(s,&o,&rings,context.temp_allocator)
    if len(rings)!=1 || rings[0].epoch==0 {return false}
    scratch:=scratch_make()
    for e in 1..=rings[0].epoch {
        body,ok:=keyring_epoch(rings[0],e)
        if !ok || !object_whole(s,body.envelopes,scratch) {return false}
    }
    present:=make([dynamic]store.Hash,context.temp_allocator)
    missing:=make([dynamic]store.Hash,context.temp_allocator)
    closure_walk(s,{g.commit},&present,&missing)
    if len(missing)>0 || len(present)==0 {return false}
    r,_,re:=overlay_record_get(s,g.project,g.scope,g.commit,context.temp_allocator)
    if re!=.None || !object_whole(s,r.tree_root,scratch) {return false}
    for x in r.objects {
        if !object_whole(s,x,scratch) {return false}
    }
    return true
}

// Whether the org's log of the store of g.k witnesses every revocation of
// g.user's log.
@(private="file")
lost_witnessed :: proc(b:^Box,data:rawptr) -> bool {
    g:=(^Org_Goal)(data)
    s:=&b.machines[g.k].store
    u,o:Log
    log_init(&u,g.user,context.temp_allocator)
    log_init(&o,g.org,context.temp_allocator)
    if log_open(s,&u,g.user,.User)!=.None || log_open(s,&o,g.org,.Org)!=.None {return false}
    revokes:=0
    for &item in u.items {
        if item.entry.type!=.Device_Revoke {continue}
        revokes+=1
        found:=false
        for &x in o.items {found||=x.entry.type==.Witness && bytes_equal(x.entry.body,witness_body(g.user,item.address))}
        if !found {return false}
    }
    return revokes>0
}

// A user alone in its org loses its only device. The org has a seed node,
// which mirrored the org's logs, a project with a shared bookmark, an open
// proposal and a private scope with a file. A recovery pairing the node offers
// brings the user's log over loopback UDP to a fresh store, after a wrong code
// is denied; the recovery key signs the new device in and revokes the lost
// one; mistyped keys say what is wrong with them and another user's is
// refused. Admitted, the new device fetches the org and witnesses the
// revocation on the org's heads, though the lost device signed every entry
// there; the user still owns the org, the project, the proposal and the
// keyring, and the recovery key's envelope gives the new device the scope's
// key: it reads the private file, a new epoch shuts the lost device out, and
// it moves the bookmark. Once the key is rotated, what the old one signs on
// parents that skip the rotation counts for nothing.
@(test)
a_user_recovers_onto_a_new_device_with_its_recovery_key :: proc(t:^testing.T) {
    b:=new(Box)
    defer free(b)
    if !box_open(t,b,"kai-runner-recover",4) {return}
    defer box_close(b)
    lost,fresh,node,other:=&b.machines[0],&b.machines[1],&b.machines[2],&b.machines[3]
    LOST,FRESH,NODE:=0,1,2
    buffer:[RECOVERY_TEXT]u8
    text,e:=machine_user_create(lost,"alice",&buffer)
    testing.expect_value(t,e,Error.None)
    key:=strings.clone(text)
    defer delete(key)
    other_text,_:=machine_user_create(other,"bob",&buffer)
    other_key:=strings.clone(other_text)
    defer delete(other_key)
    user:=lost.user

    // Alice's org, with no other member: a seed node, a project, a private scope with a file,
    // the shared bookmark main and an open proposal, every entry signed by her one device.
    org,oe:=machine_org_create(lost,"studio")
    testing.expect_value(t,oe,Error.None)
    if !box_start(t,b,LOST) || !box_start(t,b,NODE,{.Seed}) {return}
    box_beacons(b,LOST,NODE)
    box_beacons(b,NODE,LOST)
    testing.expect_value(t,machine_node_add(lost,org,node.identity.key,Dh_Key(node.dh.public),{.Seed},b.addresses[NODE][:]),Error.None)
    testing.expect_value(t,machine_org_join(node,org),Error.None)
    project,pe:=machine_project_add(lost,org,random_id(Repo_Id),"game",false)
    testing.expect_value(t,pe,Error.None)
    scope,se:=machine_scope_add(lost,org,project,{"secrets/**"},.Reader,true)
    testing.expect_value(t,se,Error.None)
    commit:Revision
    {
        o:Org_State
        testing.expect_value(t,org_state_load(&lost.store,org,&o,context.temp_allocator),Error.None)
        rings:=make([dynamic]^Keyring_Fold,context.temp_allocator)
        machine_keyrings(&lost.store,&o,&rings,context.temp_allocator)
        if !testing.expect_value(t,len(rings),1) {return}
        root:=fmt.tprintf("%s/ws",b.folder)
        os.make_directory_all(fmt.tprintf("%s/secrets",root))
        _=os.write_entire_file(fmt.tprintf("%s/readme.txt",root),transmute([]u8)string("public"))
        _=os.write_entire_file(fmt.tprintf("%s/secrets/key.txt",root),transmute([]u8)string("the private words"))
        routing:=Overlay_Routing{org=&o.fold,project=project,keyrings=rings[:],device=machine_overlay_device(lost)}
        w:Workspace
        if !testing.expect_value(t,workspace_create(&w,root,&lost.store,lost.identity,overlay=&routing),Error.None) {return}
        commit=repo_working(&w.repo)
        w.repo.overlay=nil
        workspace_close(&w)
    }
    proposed:=test_change(t,&lost.store,&lost.identity,"proposed")
    test_written(t,&lost.store,project,commit,proposed)
    testing.expect_value(t,machine_bookmark_move(lost,project,"main",commit),Error.None)
    change,ce:=change_get(&lost.store,proposed,context.temp_allocator)
    testing.expect_value(t,ce,Error.None)
    proposal,ppe:=machine_proposal_open(lost,project,"main","Keep the key","why",{{change.id,proposed}})
    testing.expect_value(t,ppe,Error.None)
    ovl_ns:[len(OVERLAY_PREFIX)+64+1+32]u8
    hex:[64]u8
    runner_changed(&b.runners[LOST],overlay_namespace(project,scope,&ovl_ns),store.hex(commit,&hex))
    goal:=Org_Goal{NODE,org,project,proposal,scope,commit,user}
    if !testing.expect(t,box_until(b,15,&goal,org_held),"the seed node mirrors the org") {return}

    // Alice's machine is gone: the node offers the recovery.
    box_stop(b,LOST)
    if !box_start(t,b,FRESH) {return}
    box_beacons(b,FRESH,NODE)
    box_beacons(b,NODE,FRESH)
    ticket_buffer:[TICKET_TEXT]u8
    testing.expect_value(t,runner_pair_join(&b.runners[FRESH],"not a ticket","spare"),Error.Corrupt)
    _,offered:=runner_pair_offer(&b.runners[FRESH],.Recover,org,.None,{},&ticket_buffer)
    testing.expect_value(t,offered,Error.Invalid_Argument)
    for wrong in ([]bool{true,false}) {
        ticket,te:=runner_pair_offer(&b.runners[NODE],.Recover,org,.None,{},&ticket_buffer)
        testing.expect_value(t,te,Error.None)
        testing.expect_value(t,runner_pair_join(&b.runners[FRESH],ticket,"spare"),Error.None)
        if !testing.expect(t,box_until(b,10,&NODE,request_shown),"the recovery request reaches the node") {return}
        request,_:=runner_pair_request(&b.runners[NODE])
        testing.expect(t,request.mode==.Recover && request.name=="spare" && request.user=={},"a recovery names no user")
        testing.expect(t,runner_pair_progress(&b.runners[FRESH]).code==request.code,"both ends show one code")
        if wrong {
            testing.expect_value(t,runner_pair_answer(&b.runners[NODE],true,"0000-0000"),Error.Unauthorized)
        } else {
            testing.expect_value(t,runner_pair_answer(&b.runners[NODE],true,request.code),Error.None)
        }
        testing.expect(t,box_until(b,5,&FRESH,join_ended))
        testing.expect_value(t,runner_pair_progress(&b.runners[FRESH]).phase,wrong?Pair_Phase.Denied:Pair_Phase.Approved)
        testing.expect_value(t,len(fresh.orgs),wrong?0:1)
    }
    if !testing.expect(t,fresh.user=={} && len(fresh.orgs)==1 && fresh.orgs[0]==org,"the recovering device reaches the org with no user") {return}
    // A peer not admitted reads the user logs alone: the user's arrives, the org's does not.
    user_here :: proc(b:^Box,data:rawptr) -> bool {
        name:[64]u8
        _,e:=store.ref_get(&b.machines[1].store,USER_NAMESPACE,log_name((^Log_Id)(data)^,&name))
        return e==.None
    }
    if !testing.expect(t,box_until(b,10,&user,user_here),"the user's log reaches the recovering device") {return}
    org_name:[64]u8
    _,held:=store.ref_get(&fresh.store,LOG_NAMESPACE,log_name(org,&org_name))
    testing.expect_value(t,held,store.Error.Missing)
    found,fe:=machine_user_find(fresh,store.hex(user,&[64]u8{})[:12])
    testing.expect(t,fe==.None && found==user,"a user is found by the start of its id")

    // Mistyped keys, each with what is wrong.
    swapped:=transmute([]u8)strings.clone(key,context.temp_allocator)
    swapped[0]=swapped[0]=='0'?'2':'0'
    Mistyped :: struct {text,why:string}
    for c in ([]Mistyped{
        {string(swapped),"checksum"},
        {key[5:],"digits"},
        {strings.concatenate({key,"-ABCD"},context.temp_allocator),"digits"},
        {strings.concatenate({"U",key[1:]},context.temp_allocator),"U"},
        {strings.concatenate({"*",key[1:]},context.temp_allocator),"digit 1"},
    }) {
        testing.expect_value(t,machine_recover(fresh,user,c.text),Error.Invalid_Argument)
        testing.expectf(t,strings.contains(fresh.why,c.why),"%q says %q",c.text,fresh.why)
        testing.expect(t,!strings.contains(fresh.why,c.text),"the why never holds the key")
    }
    testing.expect_value(t,machine_recover(fresh,user,other_key),Error.Unauthorized)
    testing.expect(t,fresh.user=={})

    // The right key, typed in lower case with spaces: the org's logs are not here yet.
    typed:=strings.to_lower(strings.join(strings.split(key,"-",context.temp_allocator)," ",context.temp_allocator),context.temp_allocator)
    report:Recover_Report
    testing.expect_value(t,machine_recover(fresh,user,typed,"spare",&report),Error.None)
    testing.expect(t,fresh.user==user && report.waiting==1 && report.opened==0,"the org waits for the agent")
    l:Log
    f:User_Fold
    testing.expect_value(t,machine_user_open(fresh,&l,&f),Error.None)
    testing.expect(t,user_device_active(&f,fresh.identity.key) && !user_device_active(&f,lost.identity.key),"the new device is in and the lost one is revoked")
    k:=user_device_index(&f,fresh.identity.key)
    fresh_kem:=machine_kem_public(fresh)
    testing.expect(t,k>=0 && bytes_equal(user_device_kem(&f,f.devices[k]),fresh_kem[:]))
    user_fold_destroy(&f)

    // Admitted as the user's device, the recovered one takes the org from the node and witnesses
    // the lost device's revocation on the org's heads, though that device signed all of them.
    goal.k=FRESH
    if !testing.expect(t,box_until(b,15,&goal,org_held),"the org reaches the recovered device") {return}
    if !testing.expect(t,box_until(b,10,&goal,lost_witnessed),"the org's log witnesses the lost device's revocation") {return}
    goal.k=NODE
    testing.expect(t,box_until(b,10,&goal,lost_witnessed),"the witness reaches the node")

    // Run again with the key, the recovery opens the private scope: the recovery key's envelope
    // gives the device the key, and a new epoch shuts the lost device out.
    testing.expect_value(t,machine_recover(fresh,user,key,"",&report),Error.None)
    testing.expectf(t,report.opened==1 && report.waiting==0 && len(report.lost)==0,"%v",report)
    o:Org_State
    testing.expect_value(t,org_state_load(&fresh.store,org,&o,context.temp_allocator),Error.None)
    testing.expect(t,o.fold.owner==user && org_role(&o.fold,user)==.Owner && org_project_index(&o.fold,project)>=0,"the user still owns the org and its project")
    rings:=make([dynamic]^Keyring_Fold,context.temp_allocator)
    machine_keyrings(&fresh.store,&o,&rings,context.temp_allocator)
    if testing.expect_value(t,len(rings),1) {
        device:=machine_overlay_device(fresh)
        ov:Overlay
        testing.expect_value(t,overlay_open(&ov,&fresh.store,rings[0],&device,commit,context.temp_allocator),Error.None)
        bytes,re:=overlay_file(&ov,&fresh.store,"secrets/key.txt",context.temp_allocator)
        testing.expect(t,re==.None && string(bytes)=="the private words","the recovered device reads the private file")
        overlay_close(&ov)
        testing.expect(t,rings[0].epoch==2 && rings[0].valid[0],"the keyring stands, with a new epoch")
        old:=machine_overlay_device(lost)
        _,le:=keyring_epoch_key(rings[0],&old,2)
        testing.expect_value(t,le,Error.Unauthorized)
    }
    ps:Project_State
    testing.expect_value(t,machine_project_open(fresh,project,&ps),Error.None)
    p:=project_state_proposal(&ps,proposal)
    testing.expect(t,p!=nil && p.status==.Open && p.revision==proposed,"the proposal stands")
    next:=test_change(t,&fresh.store,&fresh.identity,"after the recovery")
    project_state_destroy(&ps)
    testing.expect_value(t,machine_bookmark_move(fresh,project,"main",next),Error.None)
    testing.expect_value(t,machine_project_open(fresh,project,&ps),Error.None)
    targets:=make([dynamic]Revision,context.temp_allocator)
    project_bookmark(&ps.fold,"main",&targets)
    testing.expect(t,len(targets)==1 && targets[0]==next,"the recovered device moves the bookmark")
    project_state_destroy(&ps)
    box_stop(b,FRESH)
    box_stop(b,NODE)

    // Rotated, the old key signs nothing beside the rotation: a device it adds
    // on the genesis alone, concurrent with the rotation, is no device.
    rotated,rre:=machine_recovery_rotate(fresh,key,&buffer)
    testing.expect(t,rre==.None && rotated!="")
    seed,why:=recovery_decode(key)
    testing.expect_value(t,why,"")
    old:=Identity{seed=seed}
    identity_derive(&old)
    log_init(&l,user,context.temp_allocator)
    testing.expect_value(t,log_open(&fresh.store,&l,user,.User),Error.None)
    rogue:=identity_make()
    rogue_dh,_:=net.dh_key()
    rogue_seed:=random_id([KEM_SEED]u8)
    rogue_kem,_:=kem_public(&rogue_seed)
    body:=body_make(Device_Add_Body{device=rogue.key,dh=Dh_Key(rogue_dh.public),kem=rogue_kem,proof=device_proof(&rogue,transmute([32]u8)user,Dh_Key(rogue_dh.public),blake3.hash(rogue_kem[:]))},transmute([]u8)string("rogue"))
    _,e=log_append(&l,.Device_Add,body,&old,machine_now(),{},{},{user})
    testing.expect_value(t,e,Error.None)
    testing.expect_value(t,user_fold(&f,&l,context.temp_allocator),Error.None)
    testing.expect(t,user_device_index(&f,rogue.key)<0,"what the rotated key signs beside its rotation is void")
    testing.expect(t,user_device_active(&f,fresh.identity.key))
    user_fold_destroy(&f)
}

// A lookup gives up DDC_SECONDS after the last thing that came, not after it
// began: the record, an object of its output whole, or bytes of one. An
// output larger than the link carries in DDC_SECONDS still comes whole, and
// one nothing delivers is a miss in that time.
@(test)
a_lookup_waits_while_its_output_arrives :: proc(t:^testing.T) {
    Step :: struct {
        at:f64,      // seconds since the lookup began
        lacking:int,
        here:i64,
        stalled:bool,
    }
    cases:=[][]Step{
        // No record ever comes.
        {{1,-1,0,false},{DDC_SECONDS-1,-1,0,false},{DDC_SECONDS+1,-1,0,true}},
        // The record comes late, then bytes of one large object keep coming.
        {{DDC_SECONDS-1,3,0,false},{2*DDC_SECONDS-2,3,1<<20,false},{3*DDC_SECONDS-3,3,2<<20,false},{4*DDC_SECONDS-4,3,3<<20,false}},
        // Objects come whole one by one, the bytes of those left falling with each.
        {{DDC_SECONDS-1,3,4<<20,false},{2*DDC_SECONDS-2,2,1<<20,false},{3*DDC_SECONDS-3,1,0,false},{4*DDC_SECONDS-2,1,0,true}},
        // The peer that had it stops delivering.
        {{1,2,1<<20,false},{DDC_SECONDS,2,1<<20,false},{DDC_SECONDS+2,2,1<<20,true}},
    }
    for steps,k in cases {
        l:=DDC_Lookup{started=100,lacking=-1}
        for s,i in steps {
            testing.expectf(t,ddc_lookup_stalled(&l,s.lacking,s.here,100+s.at)==s.stalled,"case %d step %d: stalled is not %v",k,i,s.stalled)
        }
    }
}
