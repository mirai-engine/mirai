package kai

import "core:fmt"
import "core:slice"
import "core:testing"
import "core:time"
import "mirai:exchange"
import net "mirai:net"
import "mirai:std/base"
import "mirai:store"

// Agents of one simulated network, each with its store, a server endpoint and
// MESH_CLIENTS client endpoints, stepped together every millisecond.
@(private="file") MESH_CLIENTS :: 2
@(private="file") MESH_STEP :: 0.001

@(private="file")
Mesh :: struct {
    sim:net.Sim_Network,
    now:f64,
    folder:string,
    stores:[3]store.Store,
    open:[3]bool,
    agents:[3]Agent,
    running:[3]bool,
}

@(private="file")
mesh_init :: proc(t:^testing.T,m:^Mesh,name:string) -> bool {
    m.folder=base.test_folder(t,name)
    if m.folder=="" {return false}
    net.sim_network_init(&m.sim,{seed=11,endpoints=3*(1+MESH_CLIENTS),packets=1<<16})
    for k in 0..<3 {
        e:store.Error
        m.stores[k],e=store.open(fmt.tprintf("%s/node-%d",m.folder,k))
        if !testing.expect_value(t,e,store.Error.None) {return false}
        m.open[k]=true
    }
    return true
}

@(private="file")
mesh_destroy :: proc(m:^Mesh) {
    for k in 0..<3 {
        if m.running[k] {agent_close(&m.agents[k])}
        if m.open[k] {store.close(&m.stores[k])}
    }
    net.sim_network_destroy(&m.sim)
}

@(private="file")
mesh_endpoint :: proc "contextless" (k:int) -> int {return k*(1+MESH_CLIENTS)}

@(private="file")
mesh_start :: proc(t:^testing.T,m:^Mesh,k:int,identity:Identity,dh:net.Dh_Key,user,org:Log_Id,seed:=false) -> bool {
    clients:[MESH_CLIENTS]net.Transport
    for c in 0..<MESH_CLIENTS {clients[c]=net.sim_endpoint_transport(&m.sim,mesh_endpoint(k)+1+c)}
    e:=agent_init(&m.agents[k],{
        store=&m.stores[k],identity=identity,dh=dh,user=user,org=org,seed=seed,host_seed=u64(100+k*10),
        server=net.sim_endpoint_transport(&m.sim,mesh_endpoint(k)),
    },clients[:])
    m.running[k]=e==.None
    return testing.expect_value(t,e,Error.None)
}

@(private="file")
mesh_step :: proc(m:^Mesh) {
    m.now+=MESH_STEP
    net.sim_network_advance(&m.sim,m.now)
    for k in 0..<3 {
        if m.running[k] {agent_update(&m.agents[k],m.now)}
    }
}

// Steps until done says so or seconds pass.
@(private="file")
mesh_until :: proc(m:^Mesh,seconds:f64,data:rawptr,done:proc(m:^Mesh,data:rawptr) -> bool) -> bool {
    end:=m.now+seconds
    for m.now<end {
        mesh_step(m)
        if done(m,data) {return true}
    }
    return false
}

@(private="file")
ref_is :: proc(s:^store.Store,namespace,name:string,address:store.Hash) -> bool {
    held,e:=store.ref_get(s,namespace,name)
    return e==.None && held==address
}

@(private="file")
Mesh_Goal :: struct {
    project,org:Log_Id,
    alice,bob:Key,
    alice_refs,bob_refs:store.Hash,
    ddc_key:store.Hash,
    changes:[2]Revision,
}

@(private="file")
mesh_synced :: proc(m:^Mesh,data:rawptr) -> bool {
    g:=(^Mesh_Goal)(data)
    ns:[len(REFS_PREFIX)+64]u8
    refs:=refs_namespace(g.project,&ns)
    a_name,b_name:[32]u8
    alice,bob:=refs_name(g.alice,&a_name),refs_name(g.bob,&b_name)
    dns:[len(DDC_PREFIX)+64]u8
    key:[64]u8
    bob_ddc,e:=store.ref_get(&m.stores[1],ddc_namespace(g.org,&dns),store.hex(g.ddc_key,&key))
    if e!=.None {return false}
    if !ref_is(&m.stores[0],refs,bob,g.bob_refs) || !ref_is(&m.stores[1],refs,alice,g.alice_refs) {return false}
    if !ref_is(&m.stores[0],ddc_namespace(g.org,&dns),store.hex(g.ddc_key,&key),bob_ddc) {return false}
    if !m.agents[1].folded || !m.agents[2].folded {return false}
    for c in g.changes {
        present:=make([dynamic]store.Hash,context.temp_allocator)
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        closure_walk(&m.stores[2],{c},&present,&missing)
        if len(missing)>0 || len(present)<3 {return false}
    }
    _,admitted:=agent_peers(&m.agents[2])
    return admitted==2
}

// Alice (owner) and Bob (a writer she added) each run an agent; a seed node
// runs a third. Bob knows only the org's id and his own User_Log: as a
// Pending peer he proves who he is through it, alice admits him, and both
// then hear every ref the other may read. Each takes the other's signed
// device refs and Bob's derived data; the seed, which holds no user, takes the
// whole closure of both bookmarks from the two of them. Once alice removes
// Bob, his connection to her is revoked.
@(test)
org_members_sync_refs_and_ddc_over_sim_network :: proc(t:^testing.T) {
    m:=new(Mesh)
    defer free(m)
    if !mesh_init(t,m,"kai-mesh") {return}
    defer mesh_destroy(m)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    seed_identity:=identity_make()
    seed_dh,_:=net.dh_key()
    log_append(&o.org,.Node_Add,body_make(Node_Add_Body{node=seed_identity.key,dh=Dh_Key(seed_dh.public),modes={.Seed}}),&o.alice.devices[0],20)

    // Alice's store holds her log, bob's, the org's and the project's; bob's only his.
    for l in ([]^Log{&o.alice.log,&o.bob.log,&o.org,&o.project}) {
        _,e:=log_save(&m.stores[0],l)
        testing.expect_value(t,e,Error.None)
    }
    _,e:=log_save(&m.stores[1],&o.bob.log)
    testing.expect_value(t,e,Error.None)

    g:=Mesh_Goal{project=o.project.id,org=o.org.id,alice=o.alice.devices[0].key,bob=o.bob.devices[0].key}
    g.changes[0]=test_change(t,&m.stores[0],&o.alice.devices[0],"alice's work")
    g.changes[1]=test_change(t,&m.stores[1],&o.bob.devices[0],"bob's work")
    test_written(t,&m.stores[0],o.project.id,g.changes[0])
    test_written(t,&m.stores[1],o.project.id,g.changes[1])
    if !mesh_start(t,m,0,o.alice.devices[0],o.alice.dhs[0],o.alice.log.id,o.org.id) {return}
    if !mesh_start(t,m,1,o.bob.devices[0],o.bob.dhs[0],o.bob.log.id,o.org.id) {return}
    if !mesh_start(t,m,2,seed_identity,seed_dh,{},o.org.id,seed=true) {return}
    a,b,s:=&m.agents[0],&m.agents[1],&m.agents[2]
    g.alice_refs,e=agent_publish_refs(a,o.project.id,{{"main",g.changes[0]}},1)
    testing.expect_value(t,e,Error.None)
    g.bob_refs,e=agent_publish_refs(b,o.project.id,{{"main",g.changes[1]}},1)
    testing.expect_value(t,e,Error.None)
    g.ddc_key=store.address_of_bytes(transmute([]u8)string("cook key"))
    _,e=agent_publish_ddc(b,g.ddc_key,{store.Hash{0=7}},nil,1)
    testing.expect_value(t,e,Error.None)

    testing.expect_value(t,agent_connect(b,Dh_Key(o.alice.dhs[0].public),false,net.address_memory(mesh_endpoint(0))),Error.None)
    testing.expect_value(t,agent_connect(s,Dh_Key(o.alice.dhs[0].public),false,net.address_memory(mesh_endpoint(0))),Error.None)
    testing.expect_value(t,agent_connect(s,Dh_Key(o.bob.dhs[0].public),false,net.address_memory(mesh_endpoint(1))),Error.None)
    if !testing.expectf(t,mesh_until(m,10,&g,mesh_synced),"not synced: alice %v, bob %v, seed %v",a.stats,b.stats,s.stats) {return}
    testing.expect_value(t,a.stats.refused+b.stats.refused+s.stats.refused,0)
    _,admitted:=agent_peers(a)
    testing.expect_value(t,admitted,2)

    // Bob is removed: alice's server revokes him, and his refs are no longer taken.
    _,e=agent_append(a,o.org.id,.Member_Remove,body_make(Subject_Body{subject=o.bob.log.id}),30)
    testing.expect_value(t,e,Error.None)
    gone :: proc(m:^Mesh,data:rawptr) -> bool {
        bob:=(^Dh_Key)(data)
        for p in m.agents[0].peers {
            if p.used && p.dh==bob^ {return false}
        }
        return true
    }
    bob_dh:=Dh_Key(o.bob.dhs[0].public)
    testing.expect(t,mesh_until(m,5,&bob_dh,gone),"a removed member's connection is revoked")
    _,e=agent_publish_refs(b,o.project.id,{{"main",g.changes[0]}},2)
    testing.expect_value(t,e,Error.None)
    for _ in 0..<500 {mesh_step(m)}
    ns:[len(REFS_PREFIX)+64]u8
    name:[32]u8
    testing.expect(t,ref_is(&m.stores[0],refs_namespace(o.project.id,&ns),refs_name(o.bob.devices[0].key,&name),g.bob_refs))
}

// An anonymous reader of a public project gets the chunks of what its shared
// bookmarks reach and nothing else: a change only a device's ref names is
// neither listed nor served, though the store holds it, until a move of the
// project's log reaches it; and it never reads the org's logs.
@(test)
anonymous_peer_gets_only_the_public_closure :: proc(t:^testing.T) {
    m:=new(Mesh)
    defer free(m)
    if !mesh_init(t,m,"kai-mesh-public") {return}
    defer mesh_destroy(m)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    for l in ([]^Log{&o.alice.log,&o.bob.log,&o.carol.log,&o.org,&o.project}) {log_save(&m.stores[0],l)}
    work:=test_change(t,&m.stores[0],&o.alice.devices[0],"work in progress")
    private:=test_change(t,&m.stores[0],&o.alice.devices[0],"not published")
    test_written(t,&m.stores[0],o.project.id,work,private)
    if !mesh_start(t,m,0,o.alice.devices[0],o.alice.dhs[0],o.alice.log.id,o.org.id) {return}
    stranger:=identity_make()
    stranger_dh,_:=net.dh_key()
    if !mesh_start(t,m,1,stranger,stranger_dh,{},o.org.id) {return}
    a,c:=&m.agents[0],&m.agents[1]
    _,e:=agent_publish_refs(a,o.project.id,{{"main",work}},1)
    testing.expect_value(t,e,Error.None)
    testing.expect(t,!closure_has(a.closure.public[:],work) && !closure_has(a.closure.public[:],private),"a device's ref publishes nothing")

    testing.expect_value(t,agent_connect(c,Dh_Key(o.alice.dhs[0].public),true,net.address_memory(mesh_endpoint(0))),Error.None)
    connected :: proc(m:^Mesh,data:rawptr) -> bool {
        n,_:=agent_peers(&m.agents[1])
        return n==1
    }
    if !testing.expect(t,mesh_until(m,5,nil,connected)) {return}
    peer:^Agent_Peer
    for &p in c.peers {
        if p.used {peer=&p}
    }
    ns:[len(REFS_PREFIX)+64]u8
    name:[32]u8
    q,qe:=exchange.ref_ask(&c.x,refs_namespace(o.project.id,&ns),refs_name(o.alice.devices[0].key,&name),peer.host,peer.connection)
    testing.expect_value(t,qe,exchange.Error.None)
    log_name_buffer:[64]u8
    ql,_:=exchange.ref_ask(&c.x,LOG_NAMESPACE,log_name(o.org.id,&log_name_buffer),peer.host,peer.connection)
    Answers :: struct {x:^exchange.Exchange,q,ql:exchange.Query,ref,log:exchange.Query_Result}
    answers:=Answers{x=&c.x,q=q,ql=ql}
    answered :: proc(m:^Mesh,data:rawptr) -> bool {
        w:=(^Answers)(data)
        r,_:=exchange.query_result(w.x,w.q)
        l,_:=exchange.query_result(w.x,w.ql)
        w.ref,w.log=r,l
        return r.state!=.Waiting && l.state!=.Waiting
    }
    testing.expect(t,mesh_until(m,5,&answers,answered))
    testing.expect_value(t,answers.ref.state,exchange.Query_State.Not_Found)
    testing.expect_value(t,answers.log.state,exchange.Query_State.Not_Found)
    exchange.query_end(&c.x,q)
    exchange.query_end(&c.x,ql)

    Wanted :: struct {addresses:[2]Revision,states:[2]exchange.State}
    settled :: proc(m:^Mesh,data:rawptr) -> bool {
        w:=(^Wanted)(data)
        for address,k in w.addresses {
            p,_:=exchange.progress(&m.agents[1].x,address)
            if p.state!=w.states[k] {return false}
        }
        return true
    }
    for address in ([]Revision{work,private}) {testing.expect_value(t,exchange.want(&c.x,address),exchange.Error.None)}
    w:=Wanted{{work,private},{.Missing,.Missing}}
    testing.expect(t,mesh_until(m,5,&w,settled),"work in progress is missing by its address too")
    for address in ([]Revision{work,private}) {exchange.forget(&c.x,address)}

    // A shared bookmark reaches the work: now it is served, the other change still is not.
    _,e=agent_append(a,o.project.id,.Bookmark_Move,body_make(Bookmark_Move_Body{to=work},transmute([]u8)string("main")),2)
    testing.expect_value(t,e,Error.None)
    testing.expect(t,closure_has(a.closure.public[:],work) && !closure_has(a.closure.public[:],private))
    for address in ([]Revision{work,private}) {testing.expect_value(t,exchange.want(&c.x,address),exchange.Error.None)}
    w.states={.Complete,.Missing}
    testing.expect(t,mesh_until(m,5,&w,settled),"the shared change arrives, the other is missing")
    testing.expect(t,!object_present(&m.stores[1],private))
}

// A member is served what its org reaches and nothing else of the store: a
// change a device's ref names, derived data and every object its output
// lists, and a change a ref names later, once it does; never a change of the
// store no ref of the org names (another org's, a repository in no org) nor
// a blob a cook kept, though the member asks by their addresses. A member who
// signs refs naming another org's change on the machine, or one of a
// repository in no org, gets nothing for it: the change did not come from
// the org, so it is one this machine lacks for it.
@(test)
a_member_gets_only_what_its_org_reaches :: proc(t:^testing.T) {
    m:=new(Mesh)
    defer free(m)
    if !mesh_init(t,m,"kai-mesh-member") {return}
    defer mesh_destroy(m)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    scope:=Scope_Id{0=5}
    scope_add(t,&o,scope,.Writer,false,14,"*.env")
    for k in 0..<2 {
        for l in ([]^Log{&o.alice.log,&o.bob.log,&o.carol.log,&o.org,&o.project}) {log_save(&m.stores[k],l)}
    }
    alice:=&o.alice.devices[0]
    // Signed records of the org that name objects it does not own: a keyring's epoch whose
    // envelopes are another object, an overlay record whose tree and files are, and derived data
    // whose output no peer of the org sent.
    stray :: proc(t:^testing.T,s:^store.Store,text:string) -> store.Hash {
        address,e:=store.put(s,transmute([]u8)text)
        testing.expect_value(t,e,store.Error.None)
        return address
    }
    named_envelopes,named_tree,named_file,named_built:=stray(t,&m.stores[0],"named as envelopes"),stray(t,&m.stores[0],"named as a sealed tree"),stray(t,&m.stores[0],"named as a sealed file"),stray(t,&m.stores[0],"another org's output")
    keyring:Log
    log_init(&keyring);defer log_destroy(&keyring)
    _,ke1:=log_append(&keyring,.Keyring_Genesis,body_make(Keyring_Genesis_Body{org=o.org.id,project=o.project.id,scope=scope}),alice,15,{},o.org.items[0].address)
    _,ke2:=log_append(&keyring,.Epoch_Add,body_make(Epoch_Add_Body{epoch=1,devices=1,envelopes=named_envelopes}),&o.bob.devices[0],16,{},o.org.items[0].address)
    testing.expect(t,ke1==.None && ke2==.None)
    log_save(&m.stores[0],&keyring)
    overlay:=Overlay_Record{head={commit={0=3},project=o.project.id,scope=scope,epoch=1,tree_root=named_tree,time=1},objects={named_file}}
    overlay_address,oe:=overlay_record_write(&m.stores[0],&o.bob.devices[0],&overlay,{},0)
    testing.expect_value(t,oe,Error.None)
    other_output,ooe:=ddc_output_put(&m.stores[0],{named_built})
    testing.expect_value(t,ooe,Error.None)
    other_record:=DDC_Record{head={org=o.org.id,key={0=4},output_root=other_output,producer=o.bob.devices[0].key,time=1}}
    other_bytes,ore:=ddc_record_encode(&other_record,&o.bob.devices[0],context.temp_allocator)
    testing.expect_value(t,ore,Error.None)
    _,dse:=ddc_set_write(&m.stores[0],o.org.id,{0=4},{other_bytes})
    testing.expect_value(t,dse,Error.None)
    // What a change attaches reaches the peers it is served to, as its tree does.
    attached,ae:=store.put(&m.stores[0],transmute([]u8)string("an agent's turn"))
    testing.expect_value(t,ae,store.Error.None)
    work_change:=change_get(&m.stores[0],test_change(t,&m.stores[0],alice,"published work"),context.temp_allocator) or_else Change{}
    work_change.attachments={{1,attached}}
    work,we:=change_put(&m.stores[0],&work_change,alice)
    testing.expect_value(t,we,Error.None)
    elsewhere:=test_change(t,&m.stores[0],alice,"another org's work")
    loose:=test_change(t,&m.stores[0],alice,"a repository in no org")
    later:=test_change(t,&m.stores[0],alice,"published later")
    test_written(t,&m.stores[0],o.project.id,work,later)
    // A second org on the machine, whose project's workspace wrote elsewhere.
    other:Test_Org
    test_org_make(t,&other);defer test_org_destroy(&other)
    for l in ([]^Log{&other.org,&other.project}) {log_save(&m.stores[0],l)}
    test_written(t,&m.stores[0],other.project.id,elsewhere)
    built,be:=store.put(&m.stores[0],transmute([]u8)string("a cook's output"))
    testing.expect_value(t,be,store.Error.None)
    kept,ke:=store.put(&m.stores[0],transmute([]u8)string("what a cook kept for itself"))
    testing.expect_value(t,ke,store.Error.None)
    testing.expect_value(t,store.commit(&m.stores[0]),store.Error.None)
    if !mesh_start(t,m,0,o.alice.devices[0],o.alice.dhs[0],o.alice.log.id,o.org.id) {return}
    if !mesh_start(t,m,1,o.bob.devices[0],o.bob.dhs[0],o.bob.log.id,o.org.id) {return}
    a,b:=&m.agents[0],&m.agents[1]
    _,e:=agent_publish_refs(a,o.project.id,{{"main",work}},1)
    testing.expect_value(t,e,Error.None)
    _,e=agent_publish_ddc(a,store.address_of_bytes(transmute([]u8)string("cook key")),{built},nil,1)
    testing.expect_value(t,e,Error.None)
    testing.expect_value(t,agent_connect(b,Dh_Key(o.alice.dhs[0].public),false,net.address_memory(mesh_endpoint(0))),Error.None)
    admitted :: proc(m:^Mesh,data:rawptr) -> bool {
        _,n:=agent_peers(&m.agents[0])
        return n==1
    }
    if !testing.expect(t,mesh_until(m,5,nil,admitted),"alice admits bob") {return}

    Wanted :: struct {addresses:[]store.Hash,states:[]exchange.State}
    settled :: proc(m:^Mesh,data:rawptr) -> bool {
        w:=(^Wanted)(data)
        for address,k in w.addresses {
            p,_:=exchange.progress(&m.agents[1].x,address)
            if p.state!=w.states[k] {return false}
        }
        return true
    }
    w:=Wanted{{work,attached,built,elsewhere,kept,later},{.Complete,.Complete,.Complete,.Missing,.Missing,.Missing}}
    for address in w.addresses {testing.expect_value(t,exchange.want(&b.x,address),exchange.Error.None)}
    testing.expectf(t,mesh_until(m,5,&w,settled),"a member gets what the org reaches only: %v",a.stats)
    for address in w.addresses {exchange.forget(&b.x,address)}
    for address in ([]store.Hash{elsewhere,kept,later}) {testing.expect(t,!object_present(&m.stores[1],address))}
    testing.expect(t,overlay_address in a.members.chunks,"the org's overlay record is served")
    for address in ([]store.Hash{named_envelopes,named_tree,named_file,other_output,named_built}) {
        testing.expectf(t,!(address in a.members.chunks),"%v: what a record names is served only as the kind it says, and an output only from the org",address)
    }
    // A holder of a ddc grant is served the org's derived data, and no output that did not come from it.
    holder:=identity_make()
    holder_dh,_:=net.dh_key()
    grant_issue(t,a,&o,holder.key,Dh_Key(holder_dh.public),{.DDC},"",time.now()._nsec+i64(time.Hour))
    agent_closure(a)
    granted:[]store.Hash
    for g in a.closure.grants {
        if g.dh==Dh_Key(holder_dh.public) {granted=g.chunks[:]}
    }
    testing.expect(t,closure_has(granted,built),"a ddc grant is served the org's output")
    testing.expect(t,!closure_has(granted,other_output) && !closure_has(granted,named_built),"a ddc grant is not served an output that did not come from the org")

    // A ref that moves to it brings the later change into what bob is served.
    _,e=agent_publish_refs(a,o.project.id,{{"main",later}},2)
    testing.expect_value(t,e,Error.None)
    testing.expect_value(t,exchange.want(&b.x,later),exchange.Error.None)
    l:=Wanted{{later},{.Complete}}
    testing.expect(t,mesh_until(m,5,&l,settled),"what a moved ref reaches is served")
    exchange.forget(&b.x,later)

    // Bob signs refs that name the other org's change and the loose one: alice takes them, and
    // serves neither.
    bob_refs,be2:=agent_publish_refs(b,o.project.id,{{"theirs",elsewhere},{"loose",loose}},1)
    testing.expect_value(t,be2,Error.None)
    Taken :: struct {project:Log_Id,device:Key,refs:store.Hash}
    taken:=Taken{o.project.id,o.bob.devices[0].key,bob_refs}
    accepted :: proc(m:^Mesh,data:rawptr) -> bool {
        w:=(^Taken)(data)
        ns:[len(REFS_PREFIX)+64]u8
        name:[32]u8
        return ref_is(&m.stores[0],refs_namespace(w.project,&ns),refs_name(w.device,&name),w.refs)
    }
    if !testing.expect(t,mesh_until(m,5,&taken,accepted),"alice takes bob's refs") {return}
    named:=Wanted{{elsewhere,loose},{.Missing,.Missing}}
    for address in named.addresses {testing.expect_value(t,exchange.want(&b.x,address),exchange.Error.None)}
    testing.expect(t,mesh_until(m,5,&named,settled),"no member of the org is served another org's change or a loose one")
    testing.expect(t,!(elsewhere in a.members.chunks) && !(loose in a.members.chunks) && !closure_has(a.closure.public[:],elsewhere))
    testing.expect(t,!object_present(&m.stores[1],elsewhere) && !object_present(&m.stores[1],loose))
}

// An agent that closes tells its peers: they drop it at once, not after the
// silence that ends a connection, and ask others for what they wanted of it.
@(test)
a_closed_agent_leaves_its_peers_at_once :: proc(t:^testing.T) {
    m:=new(Mesh)
    defer free(m)
    if !mesh_init(t,m,"kai-mesh-leave") {return}
    defer mesh_destroy(m)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    for k in 0..<2 {
        for l in ([]^Log{&o.alice.log,&o.bob.log,&o.carol.log,&o.org,&o.project}) {log_save(&m.stores[k],l)}
    }
    if !mesh_start(t,m,0,o.alice.devices[0],o.alice.dhs[0],o.alice.log.id,o.org.id) {return}
    if !mesh_start(t,m,1,o.bob.devices[0],o.bob.dhs[0],o.bob.log.id,o.org.id) {return}
    testing.expect_value(t,agent_connect(&m.agents[1],Dh_Key(o.alice.dhs[0].public),false,net.address_memory(mesh_endpoint(0))),Error.None)
    connected :: proc(m:^Mesh,data:rawptr) -> bool {
        _,n:=agent_peers(&m.agents[1])
        return n==1
    }
    if !testing.expect(t,mesh_until(m,5,nil,connected),"bob connects to alice") {return}
    agent_close(&m.agents[0])
    m.running[0]=false
    left :: proc(m:^Mesh,data:rawptr) -> bool {
        n,_:=agent_peers(&m.agents[1])
        return n==0
    }
    testing.expect(t,mesh_until(m,0.5,nil,left),"bob drops alice as soon as she closes")
}

@(private="file")
grant_issue :: proc(t:^testing.T,a:^Agent,o:^Test_Org,holder:Key,dh:Dh_Key,rights:Rights,path:string,not_after:i64) {
    g:=Grant{head={org=o.org.id,org_head=test_heads(agent_log(a,o.org.id))[0],issuer=o.alice.devices[0].key,subject_dh=dh,subject_key=holder,rights=rights,project=o.project.id,not_before=time.now()._nsec-i64(time.Second),not_after=not_after},path=path}
    bytes,e:=grant_encode(&g,&o.alice.devices[0],context.temp_allocator)
    testing.expect_value(t,e,Error.None)
    _,e=agent_append(a,o.org.id,.Grant,bytes,40)
    testing.expect_value(t,e,Error.None)
}

@(private="file")
peer_class :: proc(a:^Agent,dh:Dh_Key) -> Agent_Class {
    for p in a.peers {
        if p.used && p.dh==dh {return p.class}
    }
    return .None
}

// A change of the files of paths, each with its text, over parent.
@(private="file")
grant_change :: proc(t:^testing.T,s:^store.Store,author:^Identity,parent:Revision,paths:[]string,texts:[]string) -> Revision {
    files:=make([dynamic]File,context.temp_allocator)
    for p,i in paths {
        address,e:=store.put(s,transmute([]u8)texts[i])
        testing.expect_value(t,e,store.Error.None)
        append(&files,File{path=p,kind=.File,address=address,size=u64(len(texts[i]))})
    }
    root,te:=tree_build(s,files[:])
    testing.expect_value(t,te,Error.None)
    parents:=[]Revision{parent}
    c:=Change{id=random_id(Change_Id),tree=root,author=author.key,created=1,written=1,parents=parent=={}?nil:parents,description="work"}
    revision,ce:=change_put(s,&c,author)
    testing.expect_value(t,ce,Error.None)
    testing.expect_value(t,store.commit(s),store.Error.None)
    return revision
}

// A holder outside the org, admitted under a grant of read and write on the
// project's docs/ folder, gets the project's changes and the files under
// docs/, never one outside it; alice takes its refs while its changes stay
// under docs/ and refuses them once one does not. A second holder, whose
// grant ends two seconds after it is issued, is cut off at that moment.
@(test)
a_grant_holder_reads_and_writes_only_its_scope_until_it_ends :: proc(t:^testing.T) {
    m:=new(Mesh)
    defer free(m)
    if !mesh_init(t,m,"kai-mesh-grant") {return}
    defer mesh_destroy(m)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    for l in ([]^Log{&o.alice.log,&o.bob.log,&o.carol.log,&o.org,&o.project}) {log_save(&m.stores[0],l)}
    alice:=&o.alice.devices[0]
    base:=grant_change(t,&m.stores[0],alice,{},{"docs/guide.txt","secret/plan.txt"},{"the guide","the plan"})
    test_written(t,&m.stores[0],o.project.id,base)
    files:=make([dynamic]File,context.temp_allocator)
    c,ce:=change_get(&m.stores[0],base,context.temp_allocator)
    testing.expect_value(t,ce,Error.None)
    testing.expect_value(t,tree_files(&m.stores[0],c.tree,&files,context.temp_allocator),Error.None)
    guide,plan:=files[0].address,files[1].address
    holder,late:=identity_make(),identity_make()
    holder_dh,_:=net.dh_key()
    late_dh,_:=net.dh_key()
    if !mesh_start(t,m,0,alice^,o.alice.dhs[0],o.alice.log.id,o.org.id) {return}
    if !mesh_start(t,m,1,holder,holder_dh,{},o.org.id) {return}
    if !mesh_start(t,m,2,late,late_dh,{},o.org.id) {return}
    a,h:=&m.agents[0],&m.agents[1]
    _,e:=agent_publish_refs(a,o.project.id,{{"main",base}},1)
    testing.expect_value(t,e,Error.None)
    grant_issue(t,a,&o,holder.key,Dh_Key(holder_dh.public),{.Read,.Write},"docs/",time.now()._nsec+i64(time.Hour))

    testing.expect_value(t,agent_connect(h,Dh_Key(o.alice.dhs[0].public),false,net.address_memory(mesh_endpoint(0))),Error.None)
    admitted :: proc(m:^Mesh,data:rawptr) -> bool {
        return m.agents[1].folded && peer_class(&m.agents[0],(^Dh_Key)(data)^)==.Grant
    }
    holder_key:=Dh_Key(holder_dh.public)
    if !testing.expect(t,mesh_until(m,10,&holder_key,admitted),"the holder is admitted as Grant and reads the logs") {return}

    for address in ([3]store.Hash{base,guide,plan}) {testing.expect_value(t,exchange.want(&h.x,address),exchange.Error.None)}
    read :: proc(m:^Mesh,data:rawptr) -> bool {
        w:=(^[3]store.Hash)(data)
        base,_:=exchange.progress(&m.agents[1].x,w[0])
        guide,_:=exchange.progress(&m.agents[1].x,w[1])
        plan,_:=exchange.progress(&m.agents[1].x,w[2])
        return base.state==.Complete && guide.state==.Complete && plan.state==.Missing
    }
    wanted:=[3]store.Hash{base,guide,plan}
    testing.expect(t,mesh_until(m,5,&wanted,read),"the change and docs/guide.txt arrive; secret/plan.txt does not")
    testing.expect(t,!object_present(&m.stores[1],plan))
    for address in wanted {exchange.forget(&h.x,address)}

    // Its edit under docs/ is taken; one that changes secret/ is not.
    inside:=grant_change(t,&m.stores[1],&holder,base,{"docs/guide.txt","secret/plan.txt"},{"a better guide","the plan"})
    outside:=grant_change(t,&m.stores[1],&holder,inside,{"docs/guide.txt","secret/plan.txt"},{"a better guide","another plan"})
    test_written(t,&m.stores[1],o.project.id,inside,outside)
    first,pe:=agent_publish_refs(h,o.project.id,{{"main",inside}},1)
    testing.expect_value(t,pe,Error.None)
    Taken :: struct {project:Log_Id,holder:Key,refs:store.Hash}
    taken:=Taken{o.project.id,holder.key,first}
    accepted :: proc(m:^Mesh,data:rawptr) -> bool {
        w:=(^Taken)(data)
        ns:[len(REFS_PREFIX)+64]u8
        name:[32]u8
        return ref_is(&m.stores[0],refs_namespace(w.project,&ns),refs_name(w.holder,&name),w.refs)
    }
    testing.expect(t,mesh_until(m,5,&taken,accepted),"alice takes refs whose changes stay under docs/")
    refused:=a.stats.refused
    _,pe=agent_publish_refs(h,o.project.id,{{"main",outside}},2)
    testing.expect_value(t,pe,Error.None)
    more :: proc(m:^Mesh,data:rawptr) -> bool {return m.agents[0].stats.refused>(^int)(data)^}
    testing.expect(t,mesh_until(m,5,&refused,more),"alice refuses refs with a change outside docs/")
    ns:[len(REFS_PREFIX)+64]u8
    name:[32]u8
    testing.expect(t,ref_is(&m.stores[0],refs_namespace(o.project.id,&ns),refs_name(holder.key,&name),first),"the refs stay at the last taken")

    // The late holder's grant ends two seconds from now: it is admitted, then
    // cut off when the grant ends, not at the next change of the logs.
    end:=time.now()._nsec+2*i64(time.Second)
    grant_issue(t,a,&o,late.key,Dh_Key(late_dh.public),{.Read},"",end)
    testing.expect_value(t,agent_connect(&m.agents[2],Dh_Key(o.alice.dhs[0].public),false,net.address_memory(mesh_endpoint(0))),Error.None)
    late_key:=Dh_Key(late_dh.public)
    granted :: proc(m:^Mesh,data:rawptr) -> bool {return peer_class(&m.agents[0],(^Dh_Key)(data)^)==.Grant}
    if !testing.expect(t,mesh_until(m,10,&late_key,granted),"the late holder is admitted") {return}
    testing.expect(t,time.now()._nsec<end,"admitted before its grant ends")
    for time.now()._nsec<end+i64(time.Second) && peer_class(a,late_key)!=.None {mesh_step(m)}
    testing.expect(t,time.now()._nsec>=end,"not cut off before its grant ends")
    testing.expect_value(t,peer_class(a,late_key),Agent_Class.None)
}

// An agent holds the logs of an org loaded, but not its settled proposals: a
// closed one stays in the store until a view asks for it, and the next fold
// lets it go again.
@(test)
a_settled_proposal_stays_in_the_store_until_asked_for :: proc(t:^testing.T) {
    m:=new(Mesh)
    defer free(m)
    if !mesh_init(t,m,"kai-mesh-settled") {return}
    defer mesh_destroy(m)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    bob:=&o.bob.devices[0]
    ctx:=test_heads(&o.org)[0]
    open,closed:Log
    log_init(&open);defer log_destroy(&open)
    log_init(&closed);defer log_destroy(&closed)
    proposal_open(&open,o.project.id,"main","Open","",bob,20,{},ctx)
    proposal_open(&closed,o.project.id,"main","Closed","",bob,20,{},ctx)
    proposal_close(&closed,bob,21,{},ctx)
    for l in ([]^Log{&o.alice.log,&o.bob.log,&o.carol.log,&o.org,&o.project,&open,&closed}) {
        _,e:=log_save(&m.stores[0],l)
        testing.expect_value(t,e,Error.None)
    }
    testing.expect_value(t,store.commit(&m.stores[0]),store.Error.None)
    if !mesh_start(t,m,0,o.alice.devices[0],o.alice.dhs[0],o.alice.log.id,o.org.id) {return}
    a:=&m.agents[0]
    testing.expect(t,agent_log(a,open.id)!=nil,"an open proposal is held")
    testing.expect(t,agent_log(a,closed.id)==nil,"a closed one is not in memory")
    l:=agent_log_open(a,closed.id)
    testing.expect(t,l!=nil && len(l.items)==2,"it loads when asked for")
    agent_refold(a)
    testing.expect(t,agent_log(a,closed.id)==nil,"and goes at the next fold")
}

// What a withholding node gives carol: the logs before alice removed bob,
// alice's device refs signed after it, naming the org's heads she had (the
// removal among them, or a head that exists nowhere when forged), and bob's
// refs. Agent 0 is the node, agent 1 carol, who reaches the org only through
// it.
@(private="file")
Behind_Setup :: struct {
    o:Test_Org,
    node:Identity,
    node_dh:net.Dh_Key,
    alice_refs,bob_refs:store.Hash,
    refs:[len(REFS_PREFIX)+64]u8,
}

@(private="file")
behind_setup :: proc(t:^testing.T,m:^Mesh,s:^Behind_Setup,forged:bool) -> bool {
    o:=&s.o
    test_org_make(t,o)
    s.node=identity_make()
    s.node_dh,_=net.dh_key()
    log_append(&o.org,.Node_Add,body_make(Node_Add_Body{node=s.node.key,dh=Dh_Key(s.node_dh.public),modes={.Seed}}),&o.alice.devices[0],20)
    for k in 0..<2 {
        for l in ([]^Log{&o.alice.log,&o.bob.log,&o.carol.log,&o.org,&o.project}) {
            _,e:=log_save(&m.stores[k],l)
            testing.expect_value(t,e,Error.None)
        }
    }
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    if forged {
        append(&heads,..test_heads(&o.org))
        append(&heads,random_id(store.Hash))
    } else {
        _,e:=log_append(&o.org,.Member_Remove,body_make(Subject_Body{subject=o.bob.log.id}),&o.alice.devices[0],30)
        testing.expect_value(t,e,Error.None)
        append(&heads,..test_heads(&o.org))
    }
    slice.sort_by(heads[:],hash_less)
    namespace:=refs_namespace(o.project.id,&s.refs)
    r:=Device_Refs{project=o.project.id,device=o.alice.devices[0].key,seq=1,time=40,refs={{"main",test_change(t,&m.stores[0],&o.alice.devices[0],"alice's work")}},org_heads=heads[:]}
    bytes,e:=device_refs_encode(&r,&o.alice.devices[0],context.temp_allocator)
    testing.expect_value(t,e,Error.None)
    s.alice_refs,e=object_put(&m.stores[0],.Device_Refs,bytes)
    name:[32]u8
    testing.expect_value(t,store.ref_set(&m.stores[0],namespace,refs_name(o.alice.devices[0].key,&name),s.alice_refs),store.Error.None)
    if !mesh_start(t,m,0,s.node,s.node_dh,{},o.org.id,seed=true) {return false}
    if !mesh_start(t,m,1,o.carol.devices[0],o.carol.dhs[0],o.carol.log.id,o.org.id) {return false}
    return testing.expect_value(t,agent_connect(&m.agents[1],Dh_Key(s.node_dh.public),false,net.address_memory(mesh_endpoint(0))),Error.None)
}

@(private="file")
carol_behind :: proc(m:^Mesh,data:rawptr) -> bool {
    return agent_is_behind(&m.agents[1]) && len(m.agents[1].deferred)>=1
}

// Bob's refs, which the node relays once carol has heard alice's.
@(private="file")
behind_bob_writes :: proc(t:^testing.T,m:^Mesh,s:^Behind_Setup) {
    e:Error
    s.bob_refs,e=device_refs_publish(&m.stores[0],s.o.project.id,&s.o.bob.devices[0],{{"main",test_change(t,&m.stores[0],&s.o.bob.devices[0],"bob's work")}},41)
    testing.expect_value(t,e,Error.None)
    name:[32]u8
    agent_changed(&m.agents[0],string(s.refs[:]),refs_name(s.o.bob.devices[0].key,&name))
    mesh_until(m,3,nil,proc(m:^Mesh,data:rawptr) -> bool {return len(m.agents[1].deferred)>=2})
}

// Carol reaches the org only through a node that withholds alice's removal
// of bob. Alice's device refs name the removal among the org's heads: carol
// learns she is behind, and while she is she takes no write, so bob's refs,
// signed after his removal and relayed by the node, are not taken; nor are
// alice's, until the removal comes.
@(test)
a_peer_fed_a_stale_org_log_learns_it_is_behind :: proc(t:^testing.T) {
    m:=new(Mesh)
    defer free(m)
    if !mesh_init(t,m,"kai-mesh-behind") {return}
    defer mesh_destroy(m)
    s:=new(Behind_Setup)
    defer free(s)
    defer test_org_destroy(&s.o)
    if !behind_setup(t,m,s,false) {return}
    c:=&m.agents[1]
    if !testing.expectf(t,mesh_until(m,10,nil,carol_behind),"carol is not behind: %v, %d deferred",c.stats,len(c.deferred)) {return}
    behind_bob_writes(t,m,s)
    testing.expect(t,agent_is_behind(c) && c.stats.behind>=1 && len(c.deferred)>=2,"carol says she is behind, and bob's write waits")
    name:[32]u8
    namespace:=string(s.refs[:])
    _,e:=store.ref_get(&m.stores[1],namespace,refs_name(s.o.bob.devices[0].key,&name))
    testing.expect_value(t,e,store.Error.Missing)
    _,e=store.ref_get(&m.stores[1],namespace,refs_name(s.o.alice.devices[0].key,&name))
    testing.expect_value(t,e,store.Error.Missing)
    testing.expect_value(t,c.stats.refs_accepted,0)
    // The removal reaches her: she is not behind, takes alice's refs and refuses bob's.
    testing.expect_value(t,agent_log_add(c,&s.o.org),Error.None)
    testing.expect(t,!agent_is_behind(c),"the removal came")
    held,ae:=store.ref_get(&m.stores[1],namespace,refs_name(s.o.alice.devices[0].key,&name))
    testing.expect(t,ae==.None && held==s.alice_refs,"alice's refs are taken once the removal is here")
    _,e=store.ref_get(&m.stores[1],namespace,refs_name(s.o.bob.devices[0].key,&name))
    testing.expect_value(t,e,store.Error.Missing)
    testing.expect(t,c.stats.refused>=1,"bob's refs are refused")
}

// A head that exists nowhere, named by alice's refs, holds carol behind
// for BEHIND_SECONDS and no longer: then she lets it go, takes the writes
// that waited, and alice's devices make her behind no more.
@(test)
a_forged_org_head_stalls_a_peer_no_longer_than_its_bound :: proc(t:^testing.T) {
    m:=new(Mesh)
    defer free(m)
    if !mesh_init(t,m,"kai-mesh-forged-head") {return}
    defer mesh_destroy(m)
    s:=new(Behind_Setup)
    defer free(s)
    defer test_org_destroy(&s.o)
    if !behind_setup(t,m,s,true) {return}
    c:=&m.agents[1]
    if !testing.expectf(t,mesh_until(m,10,nil,carol_behind),"carol is not behind: %v, %d deferred",c.stats,len(c.deferred)) {return}
    behind_bob_writes(t,m,s)
    m.now+=BEHIND_SECONDS/2
    mesh_step(m)
    testing.expect(t,agent_is_behind(c),"within the bound she waits")
    m.now+=BEHIND_SECONDS/2
    mesh_step(m)
    testing.expect(t,!agent_is_behind(c) && c.stats.unfound>=1,"past the bound the head is let go")
    name:[32]u8
    namespace:=string(s.refs[:])
    for device,i in ([]Key{s.o.alice.devices[0].key,s.o.bob.devices[0].key}) {
        held,e:=store.ref_get(&m.stores[1],namespace,refs_name(device,&name))
        testing.expect(t,e==.None && held==([]store.Hash{s.alice_refs,s.bob_refs})[i],"the writes that waited are taken")
    }
    testing.expect(t,slice.contains(c.unfound[:],s.o.alice.log.id),"alice's devices make carol behind no more")
}

// Appends an entry this device signs to the log of id, saves it, tells the
// peers and folds again: the entry's address.
agent_append :: proc(a:^Agent,id:Log_Id,type:Entry_Type,body:[]u8,time:i64) -> (address:store.Hash,error:Error) {
    l:=agent_log(a,id)
    if l==nil {return {},.Missing}
    identity:=a.desc.identity
    ctx,org_ctx:store.Hash
    if u:=agent_log(a,a.desc.user);u!=nil {
        heads:=make([dynamic]store.Hash,context.temp_allocator)
        if log_heads(u,&heads)==.None && len(heads)>0 {ctx=heads[0]}
    }
    if org_bound(l.kind) && a.folded {org_ctx=org_context(&a.org,a.desc.user)}
    address=log_append(l,type,body,&identity,time,ctx,org_ctx) or_return
    agent_saved(a,l) or_return
    return
}

// Publishes this device's refs of a project and tells the peers.
agent_publish_refs :: proc(a:^Agent,project:Log_Id,refs:[]Bookmark_Ref,time:i64) -> (address:store.Hash,error:Error) {
    identity:=a.desc.identity
    address=device_refs_publish(a.desc.store,project,&identity,refs,time) or_return
    ns:[len(REFS_PREFIX)+64]u8
    name:[32]u8
    namespace:=refs_namespace(project,&ns)
    exchange.ref_changed(&a.x,namespace,refs_name(identity.key,&name),address)
    agent_closure(a)
    members_ref(a,.Refs,namespace,address)
    return
}

// Publishes what this device built for key and tells the peers.
agent_publish_ddc :: proc(a:^Agent,key:store.Hash,objects:[]store.Hash,tainted:[]Scope_Id,time:i64) -> (nondeterministic:bool,error:Error) {
    identity:=a.desc.identity
    nondeterministic=ddc_publish(a.desc.store,a.desc.org,&identity,key,objects,tainted,time) or_return
    ns:[len(DDC_PREFIX)+64]u8
    name:[64]u8
    namespace,hex:=ddc_namespace(a.desc.org,&ns),store.hex(key,&name)
    agent_tell(a,namespace,hex)
    if address,e:=store.ref_get(a.desc.store,namespace,hex);e==.None {members_ref(a,.DDC,namespace,address)}
    return
}
