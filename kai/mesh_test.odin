package kai

import "core:fmt"
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

// An anonymous reader of a public project gets the chunks of its closure and
// nothing else: a change no ref names is missing to it, though the store
// holds it; and it never reads the org's logs.
@(test)
anonymous_peer_gets_only_the_public_closure :: proc(t:^testing.T) {
    m:=new(Mesh)
    defer free(m)
    if !mesh_init(t,m,"kai-mesh-public") {return}
    defer mesh_destroy(m)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    for l in ([]^Log{&o.alice.log,&o.bob.log,&o.carol.log,&o.org,&o.project}) {log_save(&m.stores[0],l)}
    public:=test_change(t,&m.stores[0],&o.alice.devices[0],"public work")
    private:=test_change(t,&m.stores[0],&o.alice.devices[0],"not published")
    if !mesh_start(t,m,0,o.alice.devices[0],o.alice.dhs[0],o.alice.log.id,o.org.id) {return}
    stranger:=identity_make()
    stranger_dh,_:=net.dh_key()
    if !mesh_start(t,m,1,stranger,stranger_dh,{},o.org.id) {return}
    a,c:=&m.agents[0],&m.agents[1]
    refs,e:=agent_publish_refs(a,o.project.id,{{"main",public}},1)
    testing.expect_value(t,e,Error.None)
    testing.expect(t,closure_has(a.closure.public[:],public) && !closure_has(a.closure.public[:],private))

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
    testing.expect(t,answers.ref.state==.Found && answers.ref.address==refs)
    testing.expect_value(t,answers.log.state,exchange.Query_State.Not_Found)
    exchange.query_end(&c.x,q)
    exchange.query_end(&c.x,ql)

    testing.expect_value(t,exchange.want(&c.x,public),exchange.Error.None)
    testing.expect_value(t,exchange.want(&c.x,private),exchange.Error.None)
    settled :: proc(m:^Mesh,data:rawptr) -> bool {
        x:=&m.agents[1].x
        addresses:=(^[2]Revision)(data)
        p,_:=exchange.progress(x,addresses[0])
        q,_:=exchange.progress(x,addresses[1])
        return p.state==.Complete && q.state==.Missing
    }
    wanted:=[2]Revision{public,private}
    testing.expect(t,mesh_until(m,5,&wanted,settled),"the public change arrives, the other is missing")
    testing.expect(t,!object_present(&m.stores[1],private))
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
