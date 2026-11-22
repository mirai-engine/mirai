package kai

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "mirai:exchange"
import net "mirai:net"
import "mirai:store"

// The sync agent of one machine: one identity host others connect to, client
// hosts for the connections it makes, and one exchange over all of them. A
// connection presents the org's id as its claim; authorize admits the
// devices of members and the nodes the org's log names, the holder of a grant
// the log carries as Grant, leaves an identity it does not know yet Pending,
// and an empty claim Anonymous. What each class reads, by namespace:
//
//   kai-user              User_Logs: Pending, Member, Node, Grant (they prove who is a member)
//   kai-log               Org, Project, Proposal and Keyring logs: Member, Node, Grant
//   kai-refs-<project>    device refs: Member, Node; Grant of read, write or check on it;
//                         Anonymous for a public project
//   kai-ddc-<org>         derived data: Member, Node; Grant of ddc
//   kai-ovl-<project>-<scope>  overlay records, ciphertext only: Member, Node
//
// Pending, Anonymous and Grant peers are restricted: they get only the chunks
// of the user logs, of the public closure, or of what the grant covers. A
// grant covers the user logs, the org's log and those of its project and the
// project's proposals; with read, write or check, the project's device refs
// and every change under them, but of each tree only the files its path scope
// covers (grant_covers), the conflicts at such paths and the folders on the
// way to them; with ddc, the DDC records and their untainted outputs. Chunks
// are content-addressed, so this is a set of addresses, made as the public
// closure is. A holder writes its refs only under the write right, and only
// changes inside its path scope (device_refs_accept); it is cut off with
// Revoked once its grant is revoked or expires, at that moment. On connect each end asks the other's
// names; a ref that differs is fetched and merged (logs by union of verified
// entries, refs and DDC by their rules), and every change is told to the
// peers that read it, so nothing polls. When the logs change, authorize runs
// again: a Pending peer becomes a member, a removed one is Revoked, and each
// end tells the peer it admitted every ref the peer may now read.

AGENT_PROTOCOL :: u32(0x3149414b) // "KAI1"
AGENT_PEERS :: 16
AGENT_CLIENTS :: 8
AGENT_LOGS :: 256
AGENT_FETCHES :: 256
AGENT_QUERIES :: 64
AGENT_HINTS :: 256
USER_NAMESPACE :: "kai-user"

Agent_Desc :: struct {
    store:^store.Store,
    identity:Identity,          // this device's signing key
    dh:net.Dh_Key,              // its X25519 key, as its User_Log names it
    user:Log_Id,                // its User_Log
    org:Log_Id,
    server:net.Transport,       // what other agents connect to
    seed:bool,                  // fetch the whole closure of every bookmark of the org's projects
    host_seed:u64,              // of the hosts' salts; 0 takes it from the system
    connect_timeout:f64,        // seconds a connection the agent makes may take; 0: net's default
    allocator:runtime.Allocator, // nil: context.allocator
}

Agent_Class :: enum u8 {None,Pending,Member,Node,Anonymous,Grant}

@(private)
Agent_Peer :: struct {
    used:bool,
    host:^net.Host,
    connection:net.Connection,
    tag:u64,
    dh:Dh_Key,
    class:Agent_Class,
    client:int, // the client host it is on, -1 on the server
}

@(private)
Fetch_Kind :: enum u8 {None,User,Log,Refs,DDC,Overlay,Object}

@(private)
Agent_Fetch :: struct {
    kind:Fetch_Kind,
    address:store.Hash,
    namespace:[store.NAME_MAX]u8,
    namespace_len:int,
    name:[store.NAME_MAX]u8,
    name_len:int,
}

@(private)
Agent_Query :: struct {
    used:bool,
    query:exchange.Query,
    peer:int,
    namespace:[store.NAME_MAX]u8,
    namespace_len:int,
}

@(private)
Allowed :: struct {dh:Dh_Key,class:Agent_Class,project:Log_Id,rights:Rights,entry:int} // project, rights and the entry in the org's log: a Grant's

// The chunks restricted peers may get: those of the user logs for Pending
// ones, those of the public projects' closures for Anonymous ones, what its
// grant covers for a Grant one. Read by the serve jobs, so it is swapped under
// the agent's lock.
Public_Closure :: struct {
    identity:[dynamic]store.Hash, // sorted
    public:[dynamic]store.Hash,   // sorted
    grants:[dynamic]Grant_Closure,
}

Grant_Closure :: struct {
    dh:Dh_Key,
    chunks:[dynamic]store.Hash, // sorted
}

Agent :: struct {
    desc:Agent_Desc,
    x:exchange.Exchange,
    channels:[exchange.CHANNELS]net.Channel_Desc,
    server:net.Host,
    clients:[AGENT_CLIENTS]net.Host,
    client_count:int,
    client_busy:[AGENT_CLIENTS]bool,
    client_anonymous:[AGENT_CLIENTS]bool,
    peers:[AGENT_PEERS]Agent_Peer,
    tags:u64,
    logs:[dynamic]^Log,
    user_folds:[dynamic]^User_Fold,
    user_list:[dynamic]^User_Fold,
    org:Org_Fold,
    folded:bool,                // org holds a fold
    lock:sync.Mutex,            // allowed, closure and the classes of peers, which other threads read
    allowed:[dynamic]Allowed,
    closure:Public_Closure,
    fetches:[dynamic]Agent_Fetch,
    queries:[AGENT_QUERIES]Agent_Query,
    hints:[dynamic]Agent_Fetch, // what peers told, taken in agent_update
    deferred:[dynamic]Agent_Fetch, // logs that came before this end could place them, and a grant holder's refs whose changes are still coming
    grants_turn:i64, // ns: the next time a grant of the log starts or ends, 0 for none
    now:f64,
    dirty:bool, // a seed walks its closure again
    stats:Agent_Stats,
}

Agent_Stats :: struct {
    logs_merged,refs_accepted,ddc_accepted,overlays_accepted,objects_fetched:int,
    refused:int, // records a peer gave that did not hold: bad signature, no right, rollback
    refolds:int,
}

@(private)
agent_channels :: proc(a:^Agent) {
    descs:=exchange.CHANNEL_DESCS
    for d,i in descs {a.channels[i]=d}
}

// Starts the agent; clients are the transports of the connections it makes,
// one each, at most AGENT_CLIENTS. The agent stays where it was started.
agent_init :: proc(a:^Agent,desc:Agent_Desc,clients:[]net.Transport) -> Error {
    if desc.store==nil || desc.org=={} || len(clients)>AGENT_CLIENTS {return .Invalid_Argument}
    a^={desc=desc}
    if a.desc.allocator.procedure==nil {a.desc.allocator=context.allocator}
    allocator:=a.desc.allocator
    a.logs=make([dynamic]^Log,allocator)
    a.user_folds=make([dynamic]^User_Fold,allocator)
    a.user_list=make([dynamic]^User_Fold,allocator)
    a.allowed=make([dynamic]Allowed,allocator)
    a.closure.identity=make([dynamic]store.Hash,allocator)
    a.closure.public=make([dynamic]store.Hash,allocator)
    a.closure.grants=make([dynamic]Grant_Closure,allocator)
    a.fetches=make([dynamic]Agent_Fetch,allocator)
    a.hints=make([dynamic]Agent_Fetch,allocator)
    a.deferred=make([dynamic]Agent_Fetch,allocator)
    if reserve(&a.fetches,AGENT_FETCHES)!=nil || reserve(&a.hints,AGENT_HINTS)!=nil || reserve(&a.deferred,AGENT_FETCHES)!=nil {
        agent_destroy(a)
        return .Out_Of_Memory
    }
    agent_channels(a)
    if exchange.init(&a.x,{
        store=desc.store,channel=0,peers=AGENT_PEERS,hints=AGENT_HINTS,
        expose=agent_expose,serve=agent_serve,hint=agent_hint,user=a,allocator=allocator,
    })!=.None {
        agent_destroy(a)
        return .Out_Of_Memory
    }
    if net.host_init(&a.server,{
        mode=.Server,transport=desc.server,channels=a.channels[:],protocol_id=AGENT_PROTOCOL,seed=desc.host_seed,
        identity=desc.dh,authorize={data=a,check=agent_authorize},max_connections=AGENT_PEERS,allocator=allocator,
    })!=.None {
        exchange.destroy(&a.x)
        agent_destroy(a)
        return .Invalid_Argument
    }
    for t,i in clients {
        if net.host_init(&a.clients[i],{
            mode=.Client,transport=t,channels=a.channels[:],protocol_id=AGENT_PROTOCOL,seed=desc.host_seed==0?0:desc.host_seed+u64(i)+1,
            identity=desc.dh,connect_timeout=desc.connect_timeout,allocator=allocator,
        })!=.None {
            a.client_count=i
            agent_close(a)
            return .Invalid_Argument
        }
    }
    a.client_count=len(clients)
    agent_load(a)
    agent_refold(a)
    return .None
}

// Stops the hosts and the exchange and frees the agent.
agent_close :: proc(a:^Agent) {
    exchange.destroy(&a.x)
    net.host_destroy(&a.server)
    for &c in a.clients[:a.client_count] {net.host_destroy(&c)}
    agent_destroy(a)
}

@(private)
agent_destroy :: proc(a:^Agent) {
    agent_folds_drop(a)
    for l in a.logs {
        log_destroy(l)
        free(l,a.desc.allocator)
    }
    delete(a.logs)
    delete(a.user_folds)
    delete(a.user_list)
    delete(a.allowed)
    delete(a.closure.identity)
    delete(a.closure.public)
    for g in a.closure.grants {delete(g.chunks)}
    delete(a.closure.grants)
    delete(a.fetches)
    delete(a.hints)
    delete(a.deferred)
}

@(private)
agent_folds_drop :: proc(a:^Agent) {
    if a.folded {org_fold_destroy(&a.org)}
    a.folded=false
    for f in a.user_folds {
        user_fold_destroy(f)
        free(f,a.desc.allocator)
    }
    clear(&a.user_folds)
    clear(&a.user_list)
}

// The log of id this agent holds, nil when it has none.
agent_log :: proc(a:^Agent,id:Log_Id) -> ^Log {
    for l in a.logs {
        if l.id==id {return l}
    }
    return nil
}

@(private)
agent_log_take :: proc(a:^Agent,id:Log_Id) -> ^Log {
    if l:=agent_log(a,id);l!=nil {return l}
    if len(a.logs)>=AGENT_LOGS {return nil}
    l,e:=new(Log,a.desc.allocator)
    if e!=nil {return nil}
    log_init(l,id,a.desc.allocator)
    if _,append_error:=append(&a.logs,l);append_error!=nil {
        free(l,a.desc.allocator)
        return nil
    }
    return l
}

// Reads the logs the store holds.
@(private)
agent_load :: proc(a:^Agent) {
    for namespace in ([2]string{USER_NAMESPACE,LOG_NAMESPACE}) {
        refs,e:=store.ref_list(a.desc.store,namespace,context.temp_allocator)
        if e!=.None {continue}
        for ref in refs {
            id,ok:=store.parse_hex(ref.name)
            if !ok {continue}
            if l:=agent_log_take(a,id);l!=nil {
                _,_=log_load(a.desc.store,l,ref.hash,false)
            }
        }
    }
}

// Folds the logs again and lets the hosts and peers know who is who now.
@(private)
agent_refold :: proc(a:^Agent) {
    a.stats.refolds+=1
    a.dirty=true
    a.grants_turn=0
    agent_folds_drop(a)
    for l in a.logs {
        if l.kind!=.User || len(l.items)==0 {continue}
        f,e:=new(User_Fold,a.desc.allocator)
        if e!=nil {continue}
        if user_fold(f,l,a.desc.allocator)!=.None {
            user_fold_destroy(f)
            free(f,a.desc.allocator)
            continue
        }
        append(&a.user_folds,f)
        append(&a.user_list,f)
    }
    if l:=agent_log(a,a.desc.org);l!=nil && len(l.items)>0 {
        if org_fold(&a.org,l,a.user_list[:],a.desc.allocator)==.None {
            a.folded=true
        } else {
            org_fold_destroy(&a.org)
        }
    }
    sync.mutex_lock(&a.lock)
    clear(&a.allowed)
    // A member's active device is admitted; a revoked one, or any device of
    // a user the log removed, is refused. A user this end cannot place yet
    // (its logs may be behind) stays Pending.
    if a.folded {
        for u in a.user_list {
            member:=org_role(&a.org,u.log.id)!=.None
            removed:=!member && slice.contains(a.org.removed[:],u.log.id)
            for d in u.devices {
                if member {
                    append(&a.allowed,Allowed{dh=d.dh,class=d.revoked?.None:.Member})
                } else if removed {
                    append(&a.allowed,Allowed{dh=d.dh,class=.None})
                }
            }
        }
        for n in a.org.nodes {append(&a.allowed,Allowed{dh=n.dh,class=.Node})}
        // A grant in force admits its holder; one revoked or expired refuses
        // it. When the next one starts or ends, agent_update folds again.
        now:=time.now()._nsec
        for item,i in a.org.log.items {
            if !a.org.valid[i] || item.entry.type!=.Grant {continue}
            g,e:=grant_verify(&a.org,item.entry.body,now)
            if e==.Corrupt {continue}
            turn:=e==.None?g.not_after:(e==.Expired && now<g.not_before?g.not_before:0)
            if turn!=0 && (a.grants_turn==0 || turn<a.grants_turn) {a.grants_turn=turn}
            held:=false
            for x in a.allowed {held||=x.dh==g.subject_dh}
            if held {continue}
            append(&a.allowed,e==.None?Allowed{dh=g.subject_dh,class=.Grant,project=g.project,rights=g.rights,entry=i}:Allowed{dh=g.subject_dh,class=.None})
        }
    }
    sync.mutex_unlock(&a.lock)
    agent_closure(a)
    net.host_authorize(&a.server)
    // What this end makes of the servers it connected to.
    for &p,i in a.peers {
        if !p.used || p.client<0 || a.client_anonymous[p.client] {continue}
        class:=agent_class_of(a,p.dh)
        if class==p.class {continue}
        if class==.None || ((p.class==.Member || p.class==.Node) && class==.Pending) {
            net.host_disconnect(p.host,p.connection,.Revoked)
            continue
        }
        agent_reclass(a,i,class)
    }
    for i in 0..<AGENT_PEERS {
        if a.peers[i].used {agent_ask(a,i)}
    }
    agent_retry(a,.None)
}

// Merges again what was deferred, of kind or of every kind for None.
@(private)
agent_retry :: proc(a:^Agent,kind:Fetch_Kind) {
    retry:=make([dynamic]Agent_Fetch,context.temp_allocator)
    for k:=0;k<len(a.deferred); {
        if kind!=.None && a.deferred[k].kind!=kind {
            k+=1
            continue
        }
        append(&retry,a.deferred[k])
        unordered_remove(&a.deferred,k)
    }
    for &f in retry {agent_merge(a,&f)}
}

@(private)
agent_defer :: proc(a:^Agent,f:^Agent_Fetch) {
    for d in a.deferred {
        if d.kind==f.kind && d.address==f.address {return}
    }
    if len(a.deferred)<AGENT_FETCHES {append(&a.deferred,f^)}
}

@(private)
agent_class_of :: proc(a:^Agent,dh:Dh_Key) -> Agent_Class {
    return agent_allowed(a,dh).class
}

@(private)
agent_allowed :: proc(a:^Agent,dh:Dh_Key) -> Allowed {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    for x in a.allowed {
        if x.dh==dh {return x}
    }
    return {dh=dh,class=.Pending}
}

@(private)
agent_authorize :: proc(data:rawptr,peer:net.Key,claim:[]u8) -> net.Authorization {
    a:=(^Agent)(data)
    if len(claim)==0 {return {.Accept,.Anonymous}}
    if len(claim)!=size_of(Log_Id) || !bytes_equal(claim,a.desc.org[:]) {return {.Refuse,.Anonymous}}
    switch agent_class_of(a,Dh_Key(peer)) {
    case .Member: return {.Accept,.Member}
    case .Node: return {.Accept,.Node}
    case .Grant: return {.Accept,.Grant}
    case .None: return {.Refuse,.Anonymous}
    case .Pending,.Anonymous:
    }
    return {.Pending,.Anonymous}
}

// Connects to the agent with the X25519 key peer at addresses, as a member
// of the org, or anonymously to read public projects.
agent_connect :: proc(a:^Agent,peer:Dh_Key,anonymous:bool,addresses:..net.Address) -> Error {
    _,e:=agent_dial(a,peer,anonymous,..addresses)
    return e
}

// Connects as agent_connect does: the client host the connection is on, which
// is free again once it ended or failed (agent_client_busy).
agent_dial :: proc(a:^Agent,peer:Dh_Key,anonymous:bool,addresses:..net.Address) -> (client:int,error:Error) {
    for k in 0..<a.client_count {
        if a.client_busy[k] {continue}
        claim:=anonymous?nil:a.desc.org[:]
        p:=peer
        if net.host_connect_identity(&a.clients[k],net.Key(p),claim,..addresses)!=.None {return -1,.Invalid_Argument}
        a.client_busy[k],a.client_anonymous[k]=true,anonymous
        return k,.None
    }
    return -1,.Too_Large
}

// Whether the client host k has a connection or an attempt.
agent_client_busy :: proc(a:^Agent,k:int) -> bool {return k>=0 && k<a.client_count && a.client_busy[k]}

// Closes the connection to peer i.
agent_drop :: proc(a:^Agent,i:int) {
    p:=&a.peers[i]
    if p.used {net.host_disconnect(p.host,p.connection)}
}

// Takes a ref this machine wrote outside the agent (another process, or an
// operation of the machine): a log is read again and folded, anything else is
// told to the peers that read it.
agent_changed :: proc(a:^Agent,namespace,name:string) {
    kind:=fetch_kind(a,namespace)
    address,e:=store.ref_get(a.desc.store,namespace,name)
    if kind==.None || e!=.None {return}
    #partial switch kind {
    case .User,.Log:
        id,ok:=store.parse_hex(name)
        if !ok {return}
        l:=agent_log_take(a,id)
        if l==nil {return}
        changed,_:=log_load(a.desc.store,l,address,false)
        exchange.ref_changed(&a.x,namespace,name,address)
        if changed {agent_refold(a)}
    case .Refs:
        exchange.ref_changed(&a.x,namespace,name,address)
        a.dirty=true
        agent_closure(a)
    case:
        exchange.ref_changed(&a.x,namespace,name,address)
    }
}

// The peers connected now, and how many of them are members or nodes.
agent_peers :: proc(a:^Agent) -> (connected,admitted:int) {
    for p in a.peers {
        if !p.used {continue}
        connected+=1
        if p.class==.Member || p.class==.Node {admitted+=1}
    }
    return
}

@(private)
agent_peer_find :: proc(a:^Agent,tag:u64) -> int {
    for p,i in a.peers {
        if p.used && p.tag==tag {return i}
    }
    return -1
}

@(private)
agent_restricted :: proc "contextless" (class:Agent_Class) -> bool {return class!=.Member && class!=.Node}

@(private)
agent_peer_add :: proc(a:^Agent,h:^net.Host,connection:net.Connection,client:int,dh:Dh_Key,class:Agent_Class) {
    for &p,i in a.peers {
        if p.used {continue}
        a.tags+=1
        sync.mutex_lock(&a.lock)
        p={used=true,host=h,connection=connection,tag=a.tags,dh=dh,class=class,client=client}
        sync.mutex_unlock(&a.lock)
        if exchange.peer_add(&a.x,h,connection,p.tag,agent_restricted(class))!=.None {
            p.used=false
            net.host_disconnect(h,connection)
            return
        }
        agent_ask(a,i)
        return
    }
    net.host_disconnect(h,connection)
}

// Gives peer i a new class: the exchange takes it again, restricted or not,
// and an admitted peer hears of every ref it may read now.
@(private)
agent_reclass :: proc(a:^Agent,i:int,class:Agent_Class) {
    p:=&a.peers[i]
    // What was asked of the peer goes with its exchange peer: it is asked again below.
    agent_queries_end(a,i)
    exchange.peer_remove(&a.x,p.host,p.connection)
    a.tags+=1
    sync.mutex_lock(&a.lock)
    p.class,p.tag=class,a.tags
    sync.mutex_unlock(&a.lock)
    if exchange.peer_add(&a.x,p.host,p.connection,p.tag,agent_restricted(class))!=.None {
        net.host_disconnect(p.host,p.connection)
        return
    }
    if !agent_restricted(class) {agent_tell_all(a)}
    a.dirty=true
    agent_ask(a,i)
}

@(private)
agent_peer_drop :: proc(a:^Agent,h:^net.Host,connection:net.Connection) {
    for &p,i in a.peers {
        if !p.used || p.host!=h || p.connection!=connection {continue}
        agent_queries_end(a,i)
        exchange.peer_remove(&a.x,h,connection)
        if p.client>=0 {a.client_busy[p.client]=false}
        sync.mutex_lock(&a.lock)
        p={}
        sync.mutex_unlock(&a.lock)
        return
    }
    for k in 0..<a.client_count {
        if h==&a.clients[k] {a.client_busy[k]=false}
    }
}

@(private)
agent_queries_end :: proc(a:^Agent,i:int) {
    for &q in a.queries {
        if q.used && q.peer==i {
            exchange.query_end(&a.x,q.query)
            q.used=false
        }
    }
}

// The namespaces this end reads from its peers.
@(private)
agent_namespaces :: proc(a:^Agent,out:^[dynamic]string) {
    append(out,USER_NAMESPACE,LOG_NAMESPACE)
    if !a.folded {return}
    for p in a.org.projects {
        buffer:=new([len(REFS_PREFIX)+64]u8,context.temp_allocator)
        append(out,refs_namespace(p.id,buffer))
    }
    buffer:=new([len(DDC_PREFIX)+64]u8,context.temp_allocator)
    append(out,ddc_namespace(a.desc.org,buffer))
    for sc in a.org.scopes {
        ns:=new([len(OVERLAY_PREFIX)+64+1+32]u8,context.temp_allocator)
        append(out,overlay_namespace(sc.project,sc.scope,ns))
    }
}

// Asks peer i for the names of every namespace it may let this end read.
@(private)
agent_ask :: proc(a:^Agent,i:int) {
    p:=&a.peers[i]
    namespaces:=make([dynamic]string,context.temp_allocator)
    if p.client>=0 && a.client_anonymous[p.client] {
        if a.folded {
            for project in a.org.projects {
                buffer:=new([len(REFS_PREFIX)+64]u8,context.temp_allocator)
                append(&namespaces,refs_namespace(project.id,buffer))
            }
        }
    } else {
        agent_namespaces(a,&namespaces)
    }
    for ns in namespaces {agent_query(a,i,ns,"")}
}

@(private)
agent_query :: proc(a:^Agent,i:int,namespace,after:string) {
    for &q in a.queries {
        if q.used && q.peer==i && string(q.namespace[:q.namespace_len])==namespace {return}
    }
    for &q in a.queries {
        if q.used {continue}
        query,e:=exchange.names_ask(&a.x,a.peers[i].host,a.peers[i].connection,namespace,after)
        if e!=.None {return}
        q={used=true,query=query,peer=i}
        q.namespace_len=copy(q.namespace[:],namespace)
        return
    }
}

@(private)
agent_expose :: proc(user:rawptr,peer:exchange.Peer_Id,namespace:string) -> bool {
    a:=(^Agent)(user)
    k:=agent_peer_find(a,peer.tag)
    if k<0 {return false}
    class:=a.peers[k].class
    admitted:=class==.Member || class==.Node
    grant:Allowed
    if class==.Grant {grant=agent_allowed(a,a.peers[k].dh)}
    switch {
    case namespace==USER_NAMESPACE: return admitted || class==.Pending || class==.Grant
    case namespace==LOG_NAMESPACE: return admitted || class==.Grant
    case strings.has_prefix(namespace,REFS_PREFIX):
        id,ok:=store.parse_hex(namespace[len(REFS_PREFIX):])
        if !ok || !a.folded {return false}
        k:=org_project_index(&a.org,id)
        if k<0 {return false}
        granted:=class==.Grant && (grant.project=={} || grant.project==id) && grant.rights&{.Read,.Write,.Check}!={}
        return admitted || granted || (class==.Anonymous && a.org.projects[k].public)
    case strings.has_prefix(namespace,DDC_PREFIX):
        buffer:[len(DDC_PREFIX)+64]u8
        return (admitted || (class==.Grant && .DDC in grant.rights)) && namespace==ddc_namespace(a.desc.org,&buffer)
    case strings.has_prefix(namespace,OVERLAY_PREFIX):
        project,scope,ok:=overlay_namespace_parse(namespace)
        if !ok || !admitted || !a.folded {return false}
        for sc in a.org.scopes {
            if sc.project==project && sc.scope==scope {return true}
        }
    }
    return false
}

@(private)
agent_serve :: proc(user:rawptr,peer:exchange.Peer_Id,address:store.Hash) -> bool {
    a:=(^Agent)(user)
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    class:=Agent_Class.None
    dh:Dh_Key
    for p in a.peers {
        if p.used && p.tag==peer.tag {class,dh=p.class,p.dh}
    }
    #partial switch class {
    case .Pending: return closure_has(a.closure.identity[:],address)
    case .Anonymous: return closure_has(a.closure.public[:],address)
    case .Grant:
        for g in a.closure.grants {
            if g.dh==dh {return closure_has(g.chunks[:],address)}
        }
    case .Member,.Node: return true
    }
    return false
}

@(private)
agent_hint :: proc(user:rawptr,peer:exchange.Peer_Id,namespace,name:string,address:store.Hash) {
    a:=(^Agent)(user)
    if address=={} || len(a.hints)>=AGENT_HINTS {return}
    h:Agent_Fetch
    h.address=address
    h.namespace_len=copy(h.namespace[:],namespace)
    h.name_len=copy(h.name[:],name)
    append(&a.hints,h)
}

@(private)
fetch_kind :: proc(a:^Agent,namespace:string) -> Fetch_Kind {
    switch {
    case namespace==USER_NAMESPACE: return .User
    case namespace==LOG_NAMESPACE: return .Log
    case strings.has_prefix(namespace,REFS_PREFIX): return .Refs
    case strings.has_prefix(namespace,DDC_PREFIX): return .DDC
    case strings.has_prefix(namespace,OVERLAY_PREFIX): return .Overlay
    }
    return .None
}

// Fetches what a peer's ref names when it differs from the one held.
@(private)
agent_want :: proc(a:^Agent,namespace,name:string,address:store.Hash) {
    kind:=fetch_kind(a,namespace)
    if kind==.None || address=={} {return}
    if held,e:=store.ref_get(a.desc.store,namespace,name);e==.None && held==address {return}
    for &f in a.fetches {
        if f.address==address && string(f.name[:f.name_len])==name {return}
    }
    if len(a.fetches)>=AGENT_FETCHES || exchange.want(&a.x,address)!=.None {return}
    f:=Agent_Fetch{kind=kind,address=address}
    f.namespace_len=copy(f.namespace[:],namespace)
    f.name_len=copy(f.name[:],name)
    append(&a.fetches,f)
}

@(private)
agent_want_object :: proc(a:^Agent,address:store.Hash) {
    for f in a.fetches {
        if f.address==address {return}
    }
    if len(a.fetches)>=AGENT_FETCHES || exchange.want(&a.x,address)!=.None {return}
    append(&a.fetches,Agent_Fetch{kind=.Object,address=address})
}

// Tells every peer of every ref this end holds in the namespaces it serves:
// a peer just admitted hears what it could not read before.
@(private)
agent_tell_all :: proc(a:^Agent) {
    namespaces:=make([dynamic]string,context.temp_allocator)
    agent_namespaces(a,&namespaces)
    for ns in namespaces {
        refs,e:=store.ref_list(a.desc.store,ns,context.temp_allocator)
        if e!=.None {continue}
        for r in refs {exchange.ref_changed(&a.x,ns,r.name,r.hash)}
    }
}

@(private)
agent_tell :: proc(a:^Agent,namespace,name:string) {
    if address,e:=store.ref_get(a.desc.store,namespace,name);e==.None {
        exchange.ref_changed(&a.x,namespace,name,address)
    }
}

// Appends an entry this device signs to the log of id, saves it, tells the
// peers and folds again: the entry's address.
agent_append :: proc(a:^Agent,id:Log_Id,type:Entry_Type,body:[]u8,time:i64) -> (address:store.Hash,error:Error) {
    l:=agent_log(a,id)
    if l==nil {return {},.Missing}
    identity:=a.desc.identity
    ctx:store.Hash
    if u:=agent_log(a,a.desc.user);u!=nil {
        heads:=make([dynamic]store.Hash,context.temp_allocator)
        if log_heads(u,&heads)==.None && len(heads)>0 {ctx=heads[0]}
    }
    address=log_append(l,type,body,&identity,time,ctx) or_return
    agent_saved(a,l) or_return
    return
}

// Takes a log changed outside the agent (made, or given by a pairing): saves
// it, tells the peers and folds again.
agent_log_add :: proc(a:^Agent,l:^Log) -> Error {
    own:=agent_log_take(a,l.id)
    if own==nil {return .Too_Large}
    for item in l.items {
        if _,e:=log_add(own,item.bytes,true);e!=.None {return e}
    }
    return agent_saved(a,own)
}

@(private)
agent_saved :: proc(a:^Agent,l:^Log) -> Error {
    address:=log_save(a.desc.store,l) or_return
    name:[64]u8
    exchange.ref_changed(&a.x,l.kind==.User?USER_NAMESPACE:LOG_NAMESPACE,log_name(l.id,&name),address)
    agent_refold(a)
    return .None
}

// Publishes this device's refs of a project and tells the peers.
agent_publish_refs :: proc(a:^Agent,project:Log_Id,refs:[]Bookmark_Ref,time:i64) -> (address:store.Hash,error:Error) {
    identity:=a.desc.identity
    address=device_refs_publish(a.desc.store,project,&identity,refs,time) or_return
    ns:[len(REFS_PREFIX)+64]u8
    name:[32]u8
    exchange.ref_changed(&a.x,refs_namespace(project,&ns),refs_name(identity.key,&name),address)
    agent_closure(a)
    return
}

// Publishes what this device built for key and tells the peers.
agent_publish_ddc :: proc(a:^Agent,key,output:store.Hash,tainted:[]Scope_Id,time:i64) -> (nondeterministic:bool,error:Error) {
    identity:=a.desc.identity
    nondeterministic=ddc_publish(a.desc.store,a.desc.org,&identity,key,output,tainted,time) or_return
    ns:[len(DDC_PREFIX)+64]u8
    name:[64]u8
    agent_tell(a,ddc_namespace(a.desc.org,&ns),store.hex(key,&name))
    return
}

// Merges what arrived.
@(private)
agent_merge :: proc(a:^Agent,f:^Agent_Fetch) {
    namespace,name:=string(f.namespace[:f.namespace_len]),string(f.name[:f.name_len])
    switch f.kind {
    case .None:
    case .User,.Log:
        id,ok:=store.parse_hex(name)
        if !ok {return}
        if f.kind==.Log && id!=a.desc.org && !(a.folded && (org_project_index(&a.org,id)>=0 || keyring_of_org(a.desc.store,&a.org,id,f.address) || proposal_of_org(a.desc.store,&a.org,id,f.address))) {
            agent_defer(a,f)
            return
        }
        l:=agent_log_take(a,id)
        if l==nil {return}
        changed,e:=log_merge(a.desc.store,l,f.address)
        if e!=.None && !changed {
            a.stats.refused+=1
            return
        }
        if changed {
            a.stats.logs_merged+=1
            agent_tell(a,namespace,name)
            agent_refold(a)
        }
    case .Refs:
        project,ok:=store.parse_hex(namespace[len(REFS_PREFIX):])
        if !ok || !a.folded {return}
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        changed,e:=device_refs_accept(a.desc.store,&a.org,project,name,f.address,time.now()._nsec,&missing)
        if e==.Missing && len(missing)>0 {
            // A grant holder's changes are checked against its path scope once they are here.
            for m in missing {agent_want_object(a,m)}
            agent_defer(a,f)
            return
        }
        if e!=.None {
            a.stats.refused+=1
            return
        }
        if changed {
            a.stats.refs_accepted+=1
            a.dirty=true
            exchange.ref_changed(&a.x,namespace,name,f.address)
            agent_closure(a)
        }
    case .DDC:
        key,ok:=store.parse_hex(name)
        if !ok || !a.folded {return}
        grants:=make([dynamic][]u8,context.temp_allocator)
        for item,i in a.org.log.items {
            if a.org.valid[i] && item.entry.type==.Grant {append(&grants,item.entry.body)}
        }
        changed,_,e:=ddc_accept(a.desc.store,&a.org,key,f.address,grants[:],time.now()._nsec)
        if e!=.None {
            a.stats.refused+=1
            return
        }
        if changed {
            a.stats.ddc_accepted+=1
            agent_tell(a,namespace,name)
        }
    case .Overlay:
        if !a.folded {return}
        r,changed,e:=overlay_accept(a.desc.store,&a.org,namespace,name,f.address)
        if e!=.None {
            a.stats.refused+=1
            return
        }
        if changed {
            a.stats.overlays_accepted+=1
            agent_want_object(a,r.tree_root)
            for o in r.objects {agent_want_object(a,o)}
            exchange.ref_changed(&a.x,namespace,name,f.address)
        }
    case .Object:
        a.stats.objects_fetched+=1
        a.dirty=true
        agent_closure(a)
        agent_retry(a,.Refs)
    }
}

// Runs the agent: the hosts, the exchange, and what peers told or gave.
agent_update :: proc(a:^Agent,now:f64) {
    a.now=now
    if a.grants_turn!=0 && time.now()._nsec>a.grants_turn {agent_refold(a)}
    agent_poll(a,&a.server,-1)
    for k in 0..<a.client_count {agent_poll(a,&a.clients[k],k)}
    for &q in a.queries {
        if !q.used {continue}
        result,known:=exchange.query_result(&a.x,q.query)
        if !known || result.state==.Waiting {continue}
        namespace:=string(q.namespace[:q.namespace_len])
        last:=""
        for n in result.names {
            agent_want(a,namespace,n.name,n.address)
            last=n.name
        }
        more,peer:=result.more,q.peer
        after:[store.NAME_MAX]u8
        after_len:=copy(after[:],last)
        exchange.query_end(&a.x,q.query)
        q.used=false
        if more {agent_query(a,peer,namespace,string(after[:after_len]))}
    }
    // A peer tells every ref when it admits this end: what it held back may come now.
    told:=len(a.hints)>0
    for len(a.hints)>0 {
        h:=pop(&a.hints)
        agent_want(a,string(h.namespace[:h.namespace_len]),string(h.name[:h.name_len]),h.address)
    }
    for k:=0;k<len(a.fetches); {
        progress,known:=exchange.progress(&a.x,a.fetches[k].address)
        // An object a seed lacks stays wanted: the exchange asks again when a peer joins.
        if known && (progress.state==.Asking || (progress.state==.Missing && a.fetches[k].kind==.Object && !told)) {
            k+=1
            continue
        }
        f:=a.fetches[k]
        unordered_remove(&a.fetches,k)
        exchange.forget(&a.x,f.address)
        if known && progress.state==.Complete {agent_merge(a,&f)}
        if f.kind==.Object {a.dirty=true}
    }
    if a.desc.seed && a.dirty {
        a.dirty=false
        agent_seed(a)
    }
    exchange.update(&a.x,now)
    net.host_update(&a.server,now)
    for k in 0..<a.client_count {net.host_update(&a.clients[k],now)}
}

@(private)
agent_poll :: proc(a:^Agent,h:^net.Host,client:int) {
    for command in net.host_poll(h) {
        #partial switch command.kind {
        case .Connected:
            dh:Dh_Key
            copy(dh[:],command.data)
            class:Agent_Class
            if client>=0 {
                class=a.client_anonymous[client]?.Anonymous:agent_class_of(a,dh)
            } else {
                class=agent_class_from(command.authorization)
            }
            agent_peer_add(a,h,command.connection,client,dh,class)
        case .Authorized:
            for p,i in a.peers {
                if p.used && p.host==h && p.connection==command.connection {
                    if class:=agent_class_from(command.authorization);class!=p.class {agent_reclass(a,i,class)}
                }
            }
        case .Disconnected: agent_peer_drop(a,h,command.connection)
        case .Message: exchange.receive(&a.x,h,command)
        }
    }
}

@(private)
agent_class_from :: proc "contextless" (z:net.Authorization) -> Agent_Class {
    if z.verdict==.Pending {return .Pending}
    #partial switch z.class {
    case .Member: return .Member
    case .Node: return .Node
    case .Grant: return .Grant
    }
    return .Anonymous
}

// The revisions every device's refs of the projects name and the moves of
// their shared bookmarks a writer signed, public projects only when public,
// only project unless it is zero.
@(private)
agent_targets :: proc(a:^Agent,project:Log_Id,public:bool,out:^[dynamic]Revision,refs_objects:^[dynamic]store.Hash) {
    if !a.folded {return}
    for p in a.org.projects {
        if (public && !p.public) || (project!={} && p.id!=project) {continue}
        if l:=agent_log(a,p.id);l!=nil {
            for item in l.items {
                if item.entry.type!=.Bookmark_Move {continue}
                if _,role:=org_device_role(&a.org,item.entry.author);role<.Writer {continue}
                b,_,_:=body_head(item.entry.body,Bookmark_Move_Body)
                append(out,b.to)
            }
        }
        ns:[len(REFS_PREFIX)+64]u8
        refs,e:=store.ref_list(a.desc.store,refs_namespace(p.id,&ns),context.temp_allocator)
        if e!=.None {continue}
        for r in refs {
            append(refs_objects,r.hash)
            bytes,get_error:=object_get(a.desc.store,r.hash,.Device_Refs,context.temp_allocator)
            if get_error!=.None {continue}
            d,decode_error:=device_refs_decode(bytes,context.temp_allocator)
            if decode_error!=.None {continue}
            for b in d.refs {append(out,b.target)}
        }
    }
    // Every stack a proposal of a project of the org was revised to: reviewers read them.
    if public {return}
    for l in a.logs {
        if l.kind!=.Proposal {continue}
        k:=log_find(l,l.id)
        if k<0 || l.items[k].entry.type!=.Proposal_Open {continue}
        if b,_,_:=body_head(l.items[k].entry.body,Proposal_Open_Body);org_project_index(&a.org,b.project)<0 || (project!={} && b.project!=project) {continue}
        for item in l.items {
            if item.entry.type!=.Proposal_Revise {continue}
            _,tail,_:=body_head(item.entry.body,Proposal_Revise_Body)
            for st in slice.reinterpret([]Stack_Item,tail) {append(out,st.revision)}
        }
    }
}

// Rebuilds the chunks restricted peers may get.
@(private)
agent_closure :: proc(a:^Agent) {
    identity:=make([dynamic]store.Hash,context.temp_allocator)
    if refs,e:=store.ref_list(a.desc.store,USER_NAMESPACE,context.temp_allocator);e==.None {
        for r in refs {object_chunks(a.desc.store,r.hash,&identity)}
    }
    public:=make([dynamic]store.Hash,context.temp_allocator)
    targets:=make([dynamic]Revision,context.temp_allocator)
    roots:=make([dynamic]store.Hash,context.temp_allocator)
    agent_targets(a,{},true,&targets,&roots)
    present:=make([dynamic]store.Hash,context.temp_allocator)
    missing:=make([dynamic]store.Hash,context.temp_allocator)
    closure_walk(a.desc.store,targets[:],&present,&missing)
    append(&roots,..present[:])
    for r in roots {object_chunks(a.desc.store,r,&public)}
    slice.sort_by(identity[:],hash_less)
    slice.sort_by(public[:],hash_less)
    grants:=make([dynamic]Grant_Closure,context.temp_allocator)
    for x in a.allowed {
        if x.class!=.Grant {continue}
        g:=Grant_Closure{dh=x.dh,chunks=make([dynamic]store.Hash,context.temp_allocator)}
        append(&g.chunks,..identity[:])
        agent_grant_chunks(a,x,&g.chunks)
        slice.sort_by(g.chunks[:],hash_less)
        append(&grants,g)
    }
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    clear(&a.closure.identity)
    clear(&a.closure.public)
    append(&a.closure.identity,..identity[:])
    append(&a.closure.public,..public[:])
    for g in a.closure.grants {delete(g.chunks)}
    clear(&a.closure.grants)
    for g in grants {
        own:=Grant_Closure{dh=g.dh,chunks=make([dynamic]store.Hash,a.desc.allocator)}
        if _,e:=append(&own.chunks,..g.chunks[:]);e!=nil {
            delete(own.chunks)
            continue
        }
        append(&a.closure.grants,own)
    }
}

// The chunks the grant of x covers besides the user logs (see the head of
// this file).
@(private)
agent_grant_chunks :: proc(a:^Agent,x:Allowed,out:^[dynamic]store.Hash) {
    if !a.folded || x.entry<0 || x.entry>=len(a.org.log.items) {return}
    g,e:=grant_decode(a.org.log.items[x.entry].entry.body)
    if e!=.None {return}
    ours :: proc(a:^Agent,g:^Grant,project:Log_Id) -> bool {
        return org_project_index(&a.org,project)>=0 && (g.project=={} || g.project==project)
    }
    name:[64]u8
    for l in a.logs {
        keep:=false
        #partial switch l.kind {
        case .Org: keep=l.id==a.desc.org
        case .Project: keep=ours(a,&g,l.id)
        case .Proposal:
            if k:=log_find(l,l.id);k>=0 && l.items[k].entry.type==.Proposal_Open {
                b,_,_:=body_head(l.items[k].entry.body,Proposal_Open_Body)
                keep=ours(a,&g,b.project)
            }
        }
        if !keep {continue}
        if address,ref_error:=store.ref_get(a.desc.store,LOG_NAMESPACE,log_name(l.id,&name));ref_error==.None {
            object_chunks(a.desc.store,address,out)
        }
    }
    if g.rights&{.Read,.Write,.Check}!={} {
        targets:=make([dynamic]Revision,context.temp_allocator)
        roots:=make([dynamic]store.Hash,context.temp_allocator)
        agent_targets(a,g.project,false,&targets,&roots)
        closure_walk_scoped(a.desc.store,targets[:],g.path,&roots)
        for r in roots {object_chunks(a.desc.store,r,out)}
    }
    if .DDC in g.rights {
        ns:[len(DDC_PREFIX)+64]u8
        refs,ref_error:=store.ref_list(a.desc.store,ddc_namespace(a.desc.org,&ns),context.temp_allocator)
        if ref_error!=.None {return}
        records:=make([dynamic][]u8,context.temp_allocator)
        for r in refs {
            object_chunks(a.desc.store,r.hash,out)
            clear(&records)
            if ddc_set_read(a.desc.store,r.hash,&records)!=.None {continue}
            for bytes in records {
                if d,de:=ddc_record_decode(bytes);de==.None && d.tainted==0 {object_chunks(a.desc.store,d.output,out)}
            }
        }
    }
}

// A seed fetches what the closure of every bookmark lacks.
@(private)
agent_seed :: proc(a:^Agent) {
    targets:=make([dynamic]Revision,context.temp_allocator)
    roots:=make([dynamic]store.Hash,context.temp_allocator)
    agent_targets(a,{},false,&targets,&roots)
    present:=make([dynamic]store.Hash,context.temp_allocator)
    missing:=make([dynamic]store.Hash,context.temp_allocator)
    closure_walk(a.desc.store,targets[:],&present,&missing)
    for m in missing {agent_want_object(a,m)}
}

closure_has :: proc(sorted:[]store.Hash,address:store.Hash) -> bool {
    _,found:=slice.binary_search_by(sorted,address,proc(item:store.Hash,a:store.Hash) -> slice.Ordering {
        if item==a {return .Equal}
        return hash_less(item,a)?.Less:.Greater
    })
    return found
}

@(private)
object_present :: proc(s:^store.Store,address:store.Hash) -> bool {
    o,e:=store.object_open(s,address)
    if e!=.None {return false}
    store.object_close(&o)
    return true
}

@(private)
Walk_Kind :: enum u8 {Change,Folder,Conflict,File}

// The Kai objects reachable from revisions: changes, their parents, their
// trees, folders, conflicts and files. present gets those in the store,
// missing those that are not (what lies under them is not walked).
closure_walk :: proc(s:^store.Store,revisions:[]Revision,present,missing:^[dynamic]store.Hash) {
    Item :: struct {address:store.Hash,kind:Walk_Kind}
    stack:=make([dynamic]Item,context.temp_allocator)
    seen:=make(map[store.Hash]bool,context.temp_allocator)
    for r in revisions {append(&stack,Item{r,.Change})}
    empty:=empty_address()
    entries:=make([dynamic]Tree_Entry,context.temp_allocator)
    terms:=terms_make(Term,context.temp_allocator)
    for len(stack)>0 {
        item:=pop(&stack)
        if item.address=={} || seen[item.address] {continue}
        seen[item.address]=true
        if !object_present(s,item.address) {
            if item.address!=empty {append(missing,item.address)}
            continue
        }
        append(present,item.address)
        switch item.kind {
        case .Change:
            c,e:=change_get(s,item.address,context.temp_allocator)
            if e!=.None {continue}
            for p in c.parents {append(&stack,Item{p,.Change})}
            append(&stack,Item{c.tree,.Folder})
        case .Folder:
            clear(&entries)
            if _,e:=folder_get(s,item.address,&entries,nil,context.temp_allocator);e!=.None {continue}
            for entry in entries {
                kind:Walk_Kind
                switch entry.kind {
                case .File,.Executable: kind=.File
                case .Folder: kind=.Folder
                case .Conflict: kind=.Conflict
                }
                append(&stack,Item{entry.address,kind})
            }
        case .Conflict:
            clear(&terms.adds)
            clear(&terms.removes)
            if _,e:=conflict_get(s,item.address,&terms);e!=.None {continue}
            for list in ([2][]Term{terms.adds[:],terms.removes[:]}) {
                for t in list {append(&stack,Item{t.address,t.kind==.Folder?.Folder:.File})}
            }
        case .File:
        }
    }
}

// The Kai objects under revisions that a grant of path scope reads: every
// change and its parents, the files scope covers with the conflicts at such
// paths and what they name, and the folders on the way to them. A folder
// that holds nothing scope covers is left out, as is every file it does not
// cover. An empty scope covers all of it (closure_walk).
closure_walk_scoped :: proc(s:^store.Store,revisions:[]Revision,scope:string,present:^[dynamic]store.Hash) {
    if scope=="" {
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        closure_walk(s,revisions,present,&missing)
        return
    }
    stack:=make([dynamic]Revision,context.temp_allocator)
    seen:=make(map[Revision]bool,context.temp_allocator)
    folders:=make(map[[2]store.Hash]bool,context.temp_allocator)
    append(&stack,..revisions)
    for len(stack)>0 {
        r:=pop(&stack)
        if r=={} || seen[r] {continue}
        seen[r]=true
        c,e:=change_get(s,r,context.temp_allocator)
        if e!=.None {continue}
        append(present,r)
        append(&stack,..c.parents)
        scoped_folder(s,c.tree,"",scope,0,present,&folders)
    }
}

// Whether the folder at address, at path prefix, holds something scope
// covers; what it does goes to present. folders keeps the answer for each
// folder and path.
@(private)
scoped_folder :: proc(s:^store.Store,address:store.Hash,prefix,scope:string,depth:int,present:^[dynamic]store.Hash,folders:^map[[2]store.Hash]bool) -> bool {
    if depth>DEPTH_MAX {return false}
    key:=[2]store.Hash{address,store.address_of_bytes(transmute([]u8)prefix)}
    if held,ok:=folders[key];ok {return held}
    folders[key]=false
    entries:=make([dynamic]Tree_Entry,context.temp_allocator)
    if _,e:=folder_get(s,address,&entries,nil,context.temp_allocator);e!=.None {return false}
    terms:=terms_make(Term,context.temp_allocator)
    covered:=false
    for entry in entries {
        path,pe:=path_join(prefix,entry.name,context.temp_allocator)
        if pe!=.None {continue}
        switch entry.kind {
        case .Folder: covered|=scoped_folder(s,entry.address,path,scope,depth+1,present,folders)
        case .File,.Executable:
            if !grant_covers(scope,path) {continue}
            append(present,entry.address)
            covered=true
        case .Conflict:
            if !grant_covers(scope,path) {continue}
            clear(&terms.adds)
            clear(&terms.removes)
            if _,ce:=conflict_get(s,entry.address,&terms);ce!=.None {continue}
            append(present,entry.address)
            covered=true
            for list in ([2][]Term{terms.adds[:],terms.removes[:]}) {
                for t in list {
                    if t.kind==.Folder {
                        scoped_folder(s,t.address,path,scope,depth+1,present,folders)
                    } else {
                        append(present,t.address)
                    }
                }
            }
        }
    }
    if covered {append(present,address)}
    folders[key]=covered
    return covered
}

// The addresses of every chunk of the object at address: its nodes and data.
object_chunks :: proc(s:^store.Store,address:store.Hash,out:^[dynamic]store.Hash) {
    buffer,e:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
    if e!=nil {return}
    node_chunks(s,address,buffer,out,0)
}

@(private)
node_chunks :: proc(s:^store.Store,address:store.Hash,buffer:[]u8,out:^[dynamic]store.Hash,depth:int) {
    if depth>store.NODE_LEVEL_MAX {return}
    bytes,e:=store.chunk_read(s,address,buffer)
    if e!=.None {return}
    n,parse_error:=store.node_parse(bytes)
    if parse_error!=.None {return}
    append(out,address)
    entries,clone_error:=slice.clone(n.entries,context.temp_allocator)
    if clone_error!=nil {return}
    level:=n.level
    for entry in entries {
        if level==0 {
            append(out,entry.address)
        } else {
            node_chunks(s,entry.address,buffer,out,depth+1)
        }
    }
}
