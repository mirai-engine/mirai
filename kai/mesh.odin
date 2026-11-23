package kai

import "base:runtime"
import "core:crypto"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:exchange"
import "mirai:std/base"
import "mirai:std/blake3"
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
//   kai-refs-<project>    device refs: Member, Node; Grant of read, write or check on it
//   kai-ddc-<org>         derived data: Member, Node; Grant of ddc
//   kai-ovl-<project>-<scope>  overlay records, ciphertext only: Member, Node
//
// Members and nodes get the chunks of what the org reaches (Members); Pending,
// Anonymous and Grant peers are restricted: they get only the chunks
// of the user logs, of the public closure, or of what the grant covers. The
// public closure is what the shared bookmarks of the public projects reach,
// the moves of their logs a writer signed and the policy allowed: never a
// device's refs or a proposal's stack, and an Anonymous peer is listed no
// ref, so it asks by address what a node's public view shows it. A
// grant covers the user logs, the org's log and those of its project and the
// project's proposals; with read, write or check, the project's device refs
// and every change under them, but of each tree only the files its path scope
// covers (grant_covers), the conflicts at such paths and the folders on the
// way to them; with ddc, the DDC records and every object their untainted
// outputs list, as far as they are here. Chunks
// are content-addressed, so this is a set of addresses, made as the public
// closure is. A holder writes its refs only under the write right, and only
// changes inside its path scope (device_refs_accept); it is cut off with
// Revoked once its grant is revoked or expires, at that moment. On connect each end asks the other's
// names; a ref that differs is fetched and merged (logs by union of verified
// entries, refs and DDC by their rules), and every change is told to the
// peers that read it, so nothing polls. When the logs change, authorize runs
// again: a Pending peer becomes a member, a removed one is Revoked, and each
// end tells the peer it admitted every ref the peer may now read.
//
// Behind: a peer that reaches the org only through a peer that withholds a
// removal would take what the removed key signs. A device's refs name the
// heads of the org's log its device had, and an org's Witness names the
// removal in a user's log: a signed record of a writer, or a valid witness,
// that names an entry this end lacks makes it behind. It asks every peer for
// the logs again, says so (Agent_Stats.behind), and takes no write while it
// is (a log of a project, a proposal or a keyring, device refs, derived data
// or an overlay record): they wait, deferred, and are fetched again once it
// is not. A signer's time and heads are its own claims, so what was signed
// after the point cannot be told from what was before: every write waits.
// An entry named that does not come within BEHIND_SECONDS is let go, and the
// user whose device named it stalls this end no more: a member who names
// heads that do not exist holds it once, for that long, and never again; a
// peer cut off longer than that takes writes again, and still says it let
// entries go (Agent_Stats.unfound).

AGENT_PROTOCOL :: u32(0x3149414b) // "KAI1"
AGENT_PEERS :: 16
AGENT_CLIENTS :: 8
AGENT_LOGS :: 4096 // logs an agent holds loaded at once: closed and landed proposals load when asked for
AGENT_FETCHES :: 256
AGENT_QUERIES :: 64
AGENT_HINTS :: 256
AGENT_ASKED :: 1024 // the last chunks peers asked for, which a ddc node keeps while they are fetched
BEHIND_SECONDS :: 600.0 // an entry a peer named waits this long to come, then is let go
BEHIND_MAX :: 64        // entries named and lacking an agent waits for at once
USER_NAMESPACE :: "kai-user"

Agent_Desc :: struct {
    store:^store.Store,
    identity:Identity,          // this device's signing key
    dh:net.Dh_Key,              // its X25519 key, as its User_Log names it
    user:Log_Id,                // its User_Log
    org:Log_Id,
    server:net.Transport,       // what other agents connect to
    seed:bool,                  // fetch the whole closure of every bookmark of the org's projects
    hosted:bool,                // a node keeps the org for others: no derived data, and at most quota bytes (node.odin)
    quota:i64,                  // hosted: bytes of the members' set past which it takes no new object; 0: no bound
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
// grant covers for a Grant one.
Public_Closure :: struct {
    identity:[dynamic]store.Hash, // sorted
    public:[dynamic]store.Hash,   // sorted
    grants:[dynamic]Grant_Closure,
}

Grant_Closure :: struct {
    dh:Dh_Key,
    chunks:[dynamic]store.Hash, // sorted
}

// The chunks a member or a node may get: what the org reaches, as far as it
// is here. That is the user logs and the org's logs (its own, its projects',
// their proposals' and its keyrings'), the closures of what its projects'
// shared bookmarks, device refs and proposals' stacks name, the device refs,
// the records and ciphertext of its overlays, and its derived data with every
// object an output lists. Nothing else of the store is served, whoever asks:
// not another org's, nor a repository in no org, nor what a cook kept.
//
// A change or an output a ref names is walked only when it came from the org
// (provenance.odin); one that did not waits in the frontier as one not here.
// It grows as refs move: a ref that changed is walked from its object, down
// to what the set already holds (a change brings the overlay records its
// scopes keep for it, whose refs no one tells), and an object the walk reaches that is not
// here waits in the frontier until it arrives. It is built whole when the
// agent starts and when the org's projects or scopes change.
Members :: struct {
    chunks:map[store.Hash]struct{},
    frontier:map[store.Hash]Walk_Item, // what is not here yet, or not from the org yet
    shape:store.Hash, // of the projects and scopes it was built for
    stored:i64,       // hosted: bytes of the objects it holds
    provenance:Provenance,
}

// One thread touches an agent: the one that calls agent_update. Its exchange
// has no worker, so the serve jobs, expose, serve, hint and asked run on that
// thread too, inside exchange.update and exchange.receive.
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
    user_list:[dynamic]^User_Fold,
    org:Org_Fold,
    folded:bool,                // org holds a fold
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
    members:Members,
    asked:[AGENT_ASKED]Agent_Asked, // a ring: what peers asked for last, at asked_next-1
    asked_next:int,
    behind:[dynamic]Agent_Behind,
    unfound:[dynamic]Log_Id, // users whose devices named an entry that never came: they make this end behind no more
}

Agent_Asked :: struct {address:store.Hash,at:i64} // ns

// An entry a record or a witness named that this end lacks: of the org's log,
// or the removal of a user's log a witness names.
@(private)
Agent_Behind :: struct {entry:store.Hash,log:Log_Id,named_by:Log_Id,since:f64} // named_by: the user whose device named it

Agent_Stats :: struct {
    logs_merged,refs_accepted,ddc_accepted,overlays_accepted,objects_fetched:int,
    refused:int, // records a peer gave that did not hold: bad signature, no right, rollback
    refolds:int,
    behind:int,  // entries of the org's logs peers named that are not here yet: writes wait
    unfound:int, // entries named that did not come in time and were let go
    logs_refused:int, // logs past AGENT_LOGS loaded at once, left in the store: land or close proposals, or split the org
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
    // In place: the agent is over a megabyte, more than a thread's stack holds as a temporary.
    runtime.mem_zero(a,size_of(Agent))
    a.desc=desc
    if a.desc.allocator.procedure==nil {a.desc.allocator=context.allocator}
    allocator:=a.desc.allocator
    a.logs=make([dynamic]^Log,allocator)
    a.user_list=make([dynamic]^User_Fold,allocator)
    a.allowed=make([dynamic]Allowed,allocator)
    a.closure.identity=make([dynamic]store.Hash,allocator)
    a.closure.public=make([dynamic]store.Hash,allocator)
    a.closure.grants=make([dynamic]Grant_Closure,allocator)
    a.members.chunks=make(map[store.Hash]struct{},allocator)
    a.members.frontier=make(map[store.Hash]Walk_Item,allocator)
    provenance_init(&a.members.provenance,allocator)
    a.fetches=make([dynamic]Agent_Fetch,allocator)
    a.hints=make([dynamic]Agent_Fetch,allocator)
    a.deferred=make([dynamic]Agent_Fetch,allocator)
    a.behind=make([dynamic]Agent_Behind,allocator)
    a.unfound=make([dynamic]Log_Id,allocator)
    if reserve(&a.fetches,AGENT_FETCHES)!=nil || reserve(&a.hints,AGENT_HINTS)!=nil || reserve(&a.deferred,AGENT_FETCHES)!=nil || reserve(&a.behind,BEHIND_MAX)!=nil || reserve(&a.unfound,BEHIND_MAX)!=nil {
        agent_destroy(a)
        return .Out_Of_Memory
    }
    provenance_load(&a.members.provenance,desc.store,desc.org)
    agent_channels(a)
    if exchange.init(&a.x,{
        store=desc.store,channel=0,peers=AGENT_PEERS,hints=AGENT_HINTS,
        expose=agent_expose,serve=agent_serve,hint=agent_hint,asked=agent_asked,user=a,allocator=allocator,
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

// Stops the hosts and the exchange and frees the agent. Its peers are told it
// leaves, so they ask others at once instead of waiting for its silence.
agent_close :: proc(a:^Agent) {
    _=provenance_save(&a.members.provenance,a.desc.store,a.desc.org)
    net.host_disconnect(&a.server)
    net.host_update(&a.server,a.now)
    for &c in a.clients[:a.client_count] {
        net.host_disconnect(&c)
        net.host_update(&c,a.now)
    }
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
    delete(a.user_list)
    delete(a.allowed)
    delete(a.behind)
    delete(a.unfound)
    delete(a.closure.identity)
    delete(a.closure.public)
    for g in a.closure.grants {delete(g.chunks)}
    delete(a.closure.grants)
    delete(a.members.chunks)
    delete(a.members.frontier)
    provenance_destroy(&a.members.provenance)
    delete(a.fetches)
    delete(a.hints)
    delete(a.deferred)
}

@(private)
agent_folds_drop :: proc(a:^Agent) {
    if a.folded {org_fold_destroy(&a.org)}
    a.folded=false
    for f in a.user_list {
        user_fold_destroy(f)
        free(f,a.desc.allocator)
    }
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
    if len(a.logs)>=AGENT_LOGS {agent_unload_settled(a)}
    if len(a.logs)>=AGENT_LOGS {
        a.stats.logs_refused+=1
        return nil
    }
    l,e:=new(Log,a.desc.allocator)
    if e!=nil {return nil}
    log_init(l,id,a.desc.allocator)
    if _,append_error:=append(&a.logs,l);append_error!=nil {
        free(l,a.desc.allocator)
        return nil
    }
    return l
}

// The log of id, loaded from the store when this agent does not hold it: a
// closed or landed proposal, which the next fold unloads again.
agent_log_open :: proc(a:^Agent,id:Log_Id) -> ^Log {
    if l:=agent_log(a,id);l!=nil {return l}
    name:[64]u8
    for namespace in ([2]string{LOG_NAMESPACE,USER_NAMESPACE}) {
        address,e:=store.ref_get(a.desc.store,namespace,log_name(id,&name))
        if e!=.None {continue}
        l:=agent_log_take(a,id)
        if l==nil {return nil}
        if _,le:=log_load(a.desc.store,l,address,false);le!=.None && le!=.Missing {return nil}
        return l
    }
    return nil
}

// Loads every proposal of project the store holds, open or not: what a view
// of them all reads, until the next fold unloads the settled ones.
agent_proposals_open :: proc(a:^Agent,project:Log_Id) {
    refs,e:=store.ref_list(a.desc.store,LOG_NAMESPACE,context.temp_allocator)
    if e!=.None {return}
    for r in refs {
        id,ok:=store.parse_hex(r.name)
        if !ok || agent_log(a,id)!=nil {continue}
        if head,_,he:=log_index_read(a.desc.store,r.hash);he!=.None || head.kind!=.Proposal {continue}
        bytes,found,_:=log_entry_get(a.desc.store,r.hash,id)
        if !found {continue}
        if entry,de:=entry_decode(bytes);de==.None && entry.type==.Proposal_Open {
            if b,_,_:=body_head(entry.body,Proposal_Open_Body);b.project==project {agent_log_open(a,id)}
        }
    }
}

// Unloads the proposals that are closed or landed: they stay in the store.
@(private)
agent_unload_settled :: proc(a:^Agent) {
    if !a.folded {return}
    for k:=len(a.logs)-1;k>=0;k-=1 {
        l:=a.logs[k]
        if l.kind!=.Proposal || len(l.items)==0 {continue}
        f:Proposal_Fold
        if proposal_fold(&f,l,&a.org,context.temp_allocator)!=.None {continue}
        settled:=f.status!=.Open
        proposal_fold_destroy(&f)
        if !settled {continue}
        log_destroy(l)
        free(l,a.desc.allocator)
        ordered_remove(&a.logs,k)
    }
}

// Writes, in each log of the org this agent holds and its user has a right
// in, a Witness of each removal that reached this end and not that log yet
// (witnesses_due): what stops a removed key there. It builds on what other
// keys signed (witness_parents), except for a revocation of a device of its
// own user, which it witnesses on every head it knows, as the machine that
// revoked does: the user vouches for what its devices signed until then, and
// where they signed all of the log, as a lone owner's did, there is nothing
// else to build on.
@(private)
agent_witnesses :: proc(a:^Agent) {
    if !a.folded || a.desc.user=={} {return}
    role:=org_role(&a.org,a.desc.user)
    if role==.None {return}
    identity:=a.desc.identity
    due:=make([dynamic]Witness_Due,context.temp_allocator)
    parents:=make([dynamic]store.Hash,context.temp_allocator)
    written:=false
    logs: for l in a.logs {
        if len(l.items)==0 || (l.kind!=.Org && !org_bound(l.kind)) || (l.kind==.Org && l.id!=a.desc.org) {continue}
        if (l.kind==.Project || l.kind==.Keyring) && role<.Writer {continue}
        if l.kind==.Project && org_project_index(&a.org,l.id)<0 {continue}
        clear(&due)
        if witnesses_due(&a.org,l,&due)!=.None {continue}
        for d in due {
            if d.log==a.desc.user {
                clear(&parents)
                if log_heads(l,&parents)!=.None || len(parents)==0 {continue}
                if len(parents)>ENTRY_PARENTS_MAX {resize(&parents,ENTRY_PARENTS_MAX)}
            } else if witness_parents(l,d.keys,&parents)!=.None || len(parents)==0 {continue}
            user:store.Hash
            if u:=agent_log(a,a.desc.user);u!=nil && len(u.heads)>0 {user=u.items[u.heads[0]].address}
            org_ctx:=org_bound(l.kind)?org_context(&a.org,a.desc.user):{}
            if _,e:=log_append(l,.Witness,witness_body(d.log,d.removal),&identity,time.now()._nsec,user,org_ctx,parents[:]);e!=.None {continue}
            if address,se:=log_save(a.desc.store,l);se==.None {
                name:[64]u8
                exchange.ref_changed(&a.x,log_namespace(l.kind),log_name(l.id,&name),address)
                written=true
            }
            // The org's fold is of the log before the witness: the refold below writes the rest.
            if l.kind==.Org {break logs}
        }
    }
    if written {agent_refold(a)}
}

// Wraps the newest key of each scope this device reads for the readers of
// it that have none yet (keyring_share): a device the user's log just linked,
// or a member the org just let read the scope, reads its files with no
// rotation. The device's secrets are read only when one lacks an envelope.
@(private)
agent_share :: proc(a:^Agent) {
    if !a.folded || a.desc.user=={} || agent_is_behind(a) {return}
    device:=Overlay_Device{identity=a.desc.identity,dh=Dh_Key(a.desc.dh.public)}
    defer crypto.zero_explicit(&device,size_of(device))
    loaded,written:=false,false
    readers:=make([dynamic]Scope_Reader,context.temp_allocator)
    for l in a.logs {
        if l.kind!=.Keyring || len(l.items)==0 {continue}
        k:Keyring_Fold
        if keyring_fold(&k,l,&a.org,a.desc.store,context.temp_allocator)!=.None {continue}
        scope,ok:=keyring_scope(&k)
        if !ok || k.epoch==0 || !device_reads(&a.org,scope,&device) {continue}
        clear(&readers)
        if scope_readers(&a.org,scope,&readers)!=.None {continue}
        lacking:=false
        for r in readers {lacking||=!keyring_wraps(&k,k.epoch,r.dh)}
        if !lacking {continue}
        if !loaded {
            held,e:=machine_device_of(a.desc.store)
            if e!=.None {return}
            device,loaded=held,true
        }
        added,e:=keyring_share(&k,&device,time.now()._nsec)
        if e!=.None || added==0 {continue}
        if address,se:=log_save(a.desc.store,l);se==.None {
            name:[64]u8
            exchange.ref_changed(&a.x,log_namespace(l.kind),log_name(l.id,&name),address)
            written=true
        }
    }
    // What members are served takes the new pages in.
    if written {agent_refold(a)}
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
        append(&a.user_list,f)
    }
    if l:=agent_log(a,a.desc.org);l!=nil && len(l.items)>0 {
        if org_fold(&a.org,l,a.user_list[:],a.desc.allocator)==.None {
            a.folded=true
        } else {
            org_fold_destroy(&a.org)
        }
    }
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
    members_refold(a)
    // After the members' set took them: the entry that settles a proposal is
    // in objects its peers still ask this end for.
    agent_unload_settled(a)
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
    agent_behind_witnesses(a)
    agent_behind_settle(a)
    agent_retry(a,.None)
    agent_witnesses(a)
    agent_share(a)
}

// Whether a node keeps no more of the org it hosts: its members' set reached
// the bound (node.odin).
agent_full :: proc(a:^Agent) -> bool {return a.desc.hosted && a.desc.quota>0 && a.members.stored>=a.desc.quota}

// Whether this end is behind: an entry a peer named is not here yet, so it
// takes no write (see the head of this file).
agent_is_behind :: proc(a:^Agent) -> bool {return len(a.behind)>0}

// Notes that a device of the user named_by named entry of log, which this end
// lacks, and asks every peer for the logs again. A user whose devices named
// one that never came is not heard again.
@(private)
agent_behind_add :: proc(a:^Agent,entry:store.Hash,log:Log_Id,named_by:Log_Id) {
    if named_by=={} || slice.contains(a.unfound[:],named_by) || len(a.behind)>=BEHIND_MAX {return}
    for b in a.behind {
        if b.entry==entry {return}
    }
    append(&a.behind,Agent_Behind{entry,log,named_by,a.now})
    a.stats.behind=len(a.behind)
    for &p,i in a.peers {
        if !p.used || (p.client>=0 && a.client_anonymous[p.client]) {continue}
        agent_query(a,i,LOG_NAMESPACE,"")
        agent_query(a,i,USER_NAMESPACE,"")
    }
}

// Lets go of what came and of what waited past BEHIND_SECONDS; once nothing
// waits, the writes held back merge and every peer is asked again for what
// did not fit the deferred list.
@(private)
agent_behind_settle :: proc(a:^Agent) {
    if len(a.behind)==0 {return}
    for k:=0;k<len(a.behind); {
        b:=a.behind[k]
        l:=agent_log(a,b.log)
        if l!=nil && log_find(l,b.entry)>=0 {
            unordered_remove(&a.behind,k)
            continue
        }
        if a.now-b.since>BEHIND_SECONDS {
            if !slice.contains(a.unfound[:],b.named_by) {
                if len(a.unfound)>=BEHIND_MAX {ordered_remove(&a.unfound,0)}
                append(&a.unfound,b.named_by)
            }
            a.stats.unfound+=1
            unordered_remove(&a.behind,k)
            continue
        }
        k+=1
    }
    a.stats.behind=len(a.behind)
    if len(a.behind)>0 {return}
    agent_retry(a,.None)
    for i in 0..<AGENT_PEERS {
        if a.peers[i].used {agent_ask(a,i)}
    }
}

// The removals in users' logs that the org's witnesses name and this end
// lacks: a witness of a member's device that names one.
@(private)
agent_behind_witnesses :: proc(a:^Agent) {
    if !a.folded {return}
    for item in a.org.log.items {
        if item.entry.type!=.Witness {continue}
        b,_,ok:=body_head(item.entry.body,Witness_Body)
        if !ok || b.log==a.desc.org {continue}
        user,role:=org_device_role(&a.org,item.entry.author)
        if role==.None {continue}
        if l:=agent_log(a,b.log);l!=nil && log_find(l,b.removal)>=0 {continue}
        agent_behind_add(a,b.removal,b.log,user)
    }
}

// Whether the device refs at address, signed by a device that may write the
// project, name heads of the org's log this end lacks: it is behind then.
@(private)
agent_refs_behind :: proc(a:^Agent,project:Log_Id,address:store.Hash) -> bool {
    bytes,e:=object_get(a.desc.store,address,.Device_Refs,context.temp_allocator)
    if e!=.None {return false}
    r,de:=device_refs_decode(bytes,context.temp_allocator)
    if de!=.None || r.project!=project || !signed_valid(bytes,r.device) {return false}
    user,_:=org_device_role(&a.org,r.device)
    if _,writer:=device_may_write(&a.org,project,r.device,time.now()._nsec);!writer || user=={} || slice.contains(a.unfound[:],user) {return false}
    lacking:=false
    for h in r.org_heads {
        if log_find(a.org.log,h)>=0 {continue}
        agent_behind_add(a,h,a.desc.org,user)
        lacking=true
    }
    return lacking
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
        members_ref(a,kind,namespace,address)
    case:
        exchange.ref_changed(&a.x,namespace,name,address)
        members_ref(a,kind,namespace,address)
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
        p={used=true,host=h,connection=connection,tag=a.tags,dh=dh,class=class,client=client}
        if exchange.peer_add(&a.x,h,connection,p.tag,true)!=.None {
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
    // Its names are asked again below; its exchange peer keeps what is under
    // way on the connection, under a new tag that what was served for the old
    // class does not match.
    agent_queries_end(a,i)
    a.tags+=1
    p.class,p.tag=class,a.tags
    if exchange.peer_set(&a.x,p.host,p.connection,p.tag,true)!=.None {
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
        p={}
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
    // An anonymous end is listed nothing: it asks by address.
    if p.client>=0 && a.client_anonymous[p.client] {return}
    namespaces:=make([dynamic]string,context.temp_allocator)
    agent_namespaces(a,&namespaces)
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
        return admitted || granted
    case strings.has_prefix(namespace,DDC_PREFIX):
        buffer:[len(DDC_PREFIX)+64]u8
        return (admitted || (class==.Grant && .DDC in grant.rights)) && !a.desc.hosted && namespace==ddc_namespace(a.desc.org,&buffer)
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
    case .Member,.Node: return address in a.members.chunks
    }
    return false
}

@(private)
agent_asked :: proc(user:rawptr,peer:exchange.Peer_Id,address:store.Hash) {
    a:=(^Agent)(user)
    a.asked[a.asked_next%AGENT_ASKED]={address,time.now()._nsec}
    a.asked_next+=1
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

// Fetches what a peer's ref names when it differs from the one held. A
// hosted org takes no derived data, and past its bound only the org's log and
// the users' logs.
@(private)
agent_want :: proc(a:^Agent,namespace,name:string,address:store.Hash) {
    kind:=fetch_kind(a,namespace)
    if kind==.None || address=={} {return}
    if a.desc.hosted && kind==.DDC {return}
    if agent_full(a) && kind!=.User {
        id,ok:=store.parse_hex(name)
        if kind!=.Log || !ok || id!=a.desc.org {return}
    }
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

// Merges what arrived.
@(private)
agent_merge :: proc(a:^Agent,f:^Agent_Fetch) {
    namespace,name:=string(f.namespace[:f.namespace_len]),string(f.name[:f.name_len])
    switch f.kind {
    case .None:
    case .User,.Log:
        id,ok:=store.parse_hex(name)
        if !ok {return}
        if f.kind==.Log && id!=a.desc.org && agent_is_behind(a) {
            agent_defer(a,f)
            return
        }
        if f.kind==.Log && id!=a.desc.org && !(a.folded && (org_project_index(&a.org,id)>=0 || keyring_of_org(a.desc.store,&a.org,id,f.address) || proposal_of_org(a.desc.store,&a.org,id,f.address))) {
            // Its genesis may be in pages still to come: they are fetched, and the log placed then.
            pages:=make([dynamic]store.Hash,context.temp_allocator)
            log_pages_missing(a.desc.store,f.address,&pages)
            for m in pages {agent_want_object(a,m)}
            agent_defer(a,f)
            return
        }
        l:=agent_log_open(a,id)
        if l==nil {l=agent_log_take(a,id)}
        if l==nil {return}
        // The pages a peer's log has that this store lacks come as objects, then the merge runs again.
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        changed,e:=log_merge(a.desc.store,l,f.address,&missing)
        if e==.Missing && len(missing)>0 {
            for m in missing {agent_want_object(a,m)}
            agent_defer(a,f)
        } else if e!=.None && !changed {
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
        if agent_refs_behind(a,project,f.address) || agent_is_behind(a) {
            agent_defer(a,f)
            return
        }
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
            members_ref(a,.Refs,namespace,f.address)
        }
    case .DDC:
        key,ok:=store.parse_hex(name)
        if !ok || !a.folded {return}
        if agent_is_behind(a) {
            agent_defer(a,f)
            return
        }
        changed,_,e:=ddc_accept(a.desc.store,&a.org,key,f.address,time.now()._nsec)
        if e!=.None {
            a.stats.refused+=1
            return
        }
        if changed {
            a.stats.ddc_accepted+=1
            agent_tell(a,namespace,name)
            agent_closure(a)
            if address,re:=store.ref_get(a.desc.store,namespace,name);re==.None {members_ref(a,.DDC,namespace,address)}
        }
    case .Overlay:
        if !a.folded {return}
        if agent_is_behind(a) {
            agent_defer(a,f)
            return
        }
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
            members_ref(a,.Overlay,namespace,f.address)
        }
    case .Object:
        a.stats.objects_fetched+=1
        a.dirty=true
        provenance_received(&a.members.provenance,a.desc.store,f.address)
        agent_closure(a)
        if item,waiting:=a.members.frontier[f.address];waiting {members_walk(a,{item})}
        agent_retry(a,.None)
    }
}

// Runs the agent: the hosts, the exchange, and what peers told or gave.
agent_update :: proc(a:^Agent,now:f64) {
    a.now=now
    if a.grants_turn!=0 && time.now()._nsec>a.grants_turn {agent_refold(a)}
    agent_behind_settle(a)
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
    if p:=&a.members.provenance;p.dirty && now-p.saved>=PROVENANCE_SAVE_SECONDS {
        p.saved=now
        _=provenance_save(p,a.desc.store,a.desc.org)
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
// their shared bookmarks the project's fold holds, only project unless it is
// zero.
// When public, only what the shared bookmarks of the public projects name.
// With proven, only those that came from the org (provenance_has): what a
// closure served from them reaches.
@(private)
agent_targets :: proc(a:^Agent,project:Log_Id,public:bool,out:^[dynamic]Revision,refs_objects:^[dynamic]store.Hash,proven:=false) {
    if !a.folded {return}
    at:=len(out)
    defer if proven {
        p:=&a.members.provenance
        k:=at
        for r in out[at:] {
            if provenance_has(p,r) {
                out[k]=r
                k+=1
            }
        }
        base.truncate(out,k)
    }
    for p in a.org.projects {
        if (public && !p.public) || (project!={} && p.id!=project) {continue}
        if public {
            shared:=make([dynamic]Bookmark_Target,context.temp_allocator)
            agent_shared_bookmarks(a,p.id,&shared)
            for b in shared {append(out,b.target)}
            continue
        }
        f:Project_Fold
        if l:=agent_log(a,p.id);agent_project_fold(a,l,&f) {
            moves:=make([dynamic]Walk_Item,context.temp_allocator)
            for &item,e in l.items {
                if f.valid[e] {entry_names(&item.entry,&moves)}
            }
            for m in moves {append(out,m.address)}
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

// The shared bookmarks of a project the agent holds the log of: the moves a
// writer signed and its policy allowed, each landing checked against its
// proposal as the move names it (project_snapshots). Their names live in the
// temp allocator.
agent_shared_bookmarks :: proc(a:^Agent,project:Log_Id,out:^[dynamic]Bookmark_Target) {
    f:Project_Fold
    if agent_project_fold(a,agent_log(a,project),&f) {append(out,..f.bookmarks[:])}
}

// The fold of the project's log l, in the temp allocator, with the proposals
// its moves land as each move names them: the one source of which moves hold
// and where the shared bookmarks are.
@(private)
agent_project_fold :: proc(a:^Agent,l:^Log,f:^Project_Fold) -> bool {
    if !a.folded || l==nil || len(l.items)==0 {return false}
    proposals:=make([dynamic]^Proposal_Fold,context.temp_allocator)
    if project_snapshots(a.desc.store,l,&a.org,&proposals,context.temp_allocator)!=.None {return false}
    if project_fold(f,l,&a.org,proposals[:],context.temp_allocator)!=.None {return false}
    _=landings_keep(a.desc.store,f)
    return true
}

// Rebuilds the chunks restricted peers may get.
@(private)
agent_closure :: proc(a:^Agent) {
    scratch:=scratch_make()
    identity:=make([dynamic]store.Hash,context.temp_allocator)
    if refs,e:=store.ref_list(a.desc.store,USER_NAMESPACE,context.temp_allocator);e==.None {
        for r in refs {log_objects(a.desc.store,r.hash,&identity,scratch)}
    }
    public:=make([dynamic]store.Hash,context.temp_allocator)
    targets:=make([dynamic]Revision,context.temp_allocator)
    roots:=make([dynamic]store.Hash,context.temp_allocator)
    agent_provenance(a)
    agent_targets(a,{},true,&targets,&roots,proven=true)
    present:=make([dynamic]store.Hash,context.temp_allocator)
    missing:=make([dynamic]store.Hash,context.temp_allocator)
    closure_walk(a.desc.store,targets[:],&present,&missing)
    append(&roots,..present[:])
    for r in roots {object_chunks(a.desc.store,r,&public,scratch)}
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

// Proves what the newest operations of the workspaces of the org's projects
// on this machine name, before a set served from refs is walked.
@(private)
agent_provenance :: proc(a:^Agent) {
    if a.folded {provenance_local(&a.members.provenance,a.desc.store,&a.org,false)}
}

// What the org's projects and scopes are: the members' set is built again
// when it changes.
@(private)
members_shape :: proc(a:^Agent) -> store.Hash {
    h:blake3.Hasher
    blake3.init(&h)
    if a.folded {
        for p in a.org.projects {blake3.update(&h,slice.to_bytes([]Log_Id{p.id}))}
        for sc in a.org.scopes {
            blake3.update(&h,slice.to_bytes([]Log_Id{sc.project}))
            blake3.update(&h,slice.to_bytes([]Scope_Id{sc.scope}))
        }
    }
    return store.Hash(blake3.final(&h))
}

// After a fold: the whole set again when the org's projects or scopes
// changed, or the first time; otherwise what the logs reach now and what of
// the frontier arrived.
@(private)
members_refold :: proc(a:^Agent) {
    m:=&a.members
    roots:=make([dynamic]Walk_Item,context.temp_allocator)
    if shape:=members_shape(a);shape!=m.shape || len(m.chunks)==0 {
        m.shape=shape
        m.stored=0
        clear(&m.chunks)
        clear(&m.frontier)
        if a.folded {provenance_rebuild(&m.provenance,a.desc.store,&a.org)}
        members_logs(a,&roots)
        if a.folded {
            members_settled(a,&roots)
            for p in a.org.projects {
                ns:[len(REFS_PREFIX)+64]u8
                members_namespace(a,.Refs,refs_namespace(p.id,&ns),&roots)
            }
            ns:[len(DDC_PREFIX)+64]u8
            if !a.desc.hosted {members_namespace(a,.DDC,ddc_namespace(a.desc.org,&ns),&roots)}
            for sc in a.org.scopes {
                ns:[len(OVERLAY_PREFIX)+64+1+32]u8
                members_namespace(a,.Overlay,overlay_namespace(sc.project,sc.scope,&ns),&roots)
            }
        }
    } else {
        agent_provenance(a)
        members_logs(a,&roots)
        for _,item in m.frontier {append(&roots,item)}
    }
    members_walk(a,roots[:])
}

// The objects of the logs of the org and of every user, and the revisions
// the moves of its projects' logs (a writer's) and its proposals' stacks name.
@(private)
members_logs :: proc(a:^Agent,out:^[dynamic]Walk_Item) {
    for l in a.logs {members_log(a,l,out)}
}

// The same of the settled proposals of the org's projects, which the agent
// does not hold: each is read from the store, and let go.
@(private)
members_settled :: proc(a:^Agent,out:^[dynamic]Walk_Item) {
    refs,e:=store.ref_list(a.desc.store,LOG_NAMESPACE,context.temp_allocator)
    if e!=.None {return}
    for r in refs {
        id,ok:=store.parse_hex(r.name)
        if !ok || agent_log(a,id)!=nil {continue}
        if head,_,he:=log_index_read(a.desc.store,r.hash);he!=.None || head.kind!=.Proposal {continue}
        l:Log
        log_init(&l,id,context.temp_allocator)
        if _,le:=log_load(a.desc.store,&l,r.hash,false);le==.None {members_log(a,&l,out)}
        log_destroy(&l)
    }
}

// What the log l gives the members' set: its index and pages, which are
// objects of their own, and what the entries its fold holds name
// (entry_names): a project's moves, a proposal's stacks and a keyring's
// envelopes.
@(private)
members_log :: proc(a:^Agent,l:^Log,out:^[dynamic]Walk_Item) {
    scratch:=scratch_make()
    if len(l.items)==0 {return}
    namespace:=LOG_NAMESPACE
    switch l.kind {
    case .User: namespace=USER_NAMESPACE
    case .Org: if l.id!=a.desc.org {return}
    case .Project:
        if !a.folded || org_project_index(&a.org,l.id)<0 {return}
        f:Project_Fold
        if agent_project_fold(a,l,&f) {
            for &item,e in l.items {
                if f.valid[e] {entry_names(&item.entry,out)}
            }
        }
    case .Proposal:
        k:=log_find(l,l.id)
        if !a.folded || k<0 || l.items[k].entry.type!=.Proposal_Open {return}
        if b,_,_:=body_head(l.items[k].entry.body,Proposal_Open_Body);org_project_index(&a.org,b.project)<0 {return}
        for &item in l.items {entry_names(&item.entry,out)}
    case .Keyring:
        k:=log_find(l,l.id)
        if !a.folded || k<0 || l.items[k].entry.type!=.Keyring_Genesis {return}
        b,_,_:=body_head(l.items[k].entry.body,Keyring_Genesis_Body)
        known:=false
        for sc in a.org.scopes {known||=sc.project==b.project && sc.scope==b.scope}
        if b.org!=a.desc.org || !known {return}
        // The envelopes of each epoch are an object of their own, fetched with the log.
        at:=len(out)
        for &item in l.items {entry_names(&item.entry,out)}
        for x in out[at:] {
            if x.kind==.Envelopes && !object_present(a.desc.store,x.address) {agent_want_object(a,x.address)}
        }
    }
    name:[64]u8
    if address,e:=store.ref_get(a.desc.store,namespace,log_name(l.id,&name));e==.None {append(out,Walk_Item{address,.Log,false})}
}

// What every ref of namespace reaches.
@(private)
members_namespace :: proc(a:^Agent,kind:Fetch_Kind,namespace:string,out:^[dynamic]Walk_Item) {
    refs,e:=store.ref_list(a.desc.store,namespace,context.temp_allocator)
    if e!=.None {return}
    for r in refs {members_roots(a,kind,namespace,r.hash,out)}
}

// Walks what the ref of namespace at address reaches into the members' set.
@(private)
members_ref :: proc(a:^Agent,kind:Fetch_Kind,namespace:string,address:store.Hash) {
    roots:=make([dynamic]Walk_Item,context.temp_allocator)
    agent_provenance(a)
    members_roots(a,kind,namespace,address,&roots)
    members_walk(a,roots[:])
}

// The item a ref of the org's namespace at address is, whose walk gives what
// it names: device refs, a DDC set, an overlay's record. Nothing for a
// namespace that is not the org's.
@(private)
members_roots :: proc(a:^Agent,kind:Fetch_Kind,namespace:string,address:store.Hash,out:^[dynamic]Walk_Item) {
    if !a.folded || address=={} {return}
    #partial switch kind {
    case .Refs:
        project,ok:=store.parse_hex(namespace[len(REFS_PREFIX):])
        if !ok || org_project_index(&a.org,project)<0 {return}
        append(out,Walk_Item{address,.Refs,false})
    case .DDC:
        buffer:[len(DDC_PREFIX)+64]u8
        if namespace!=ddc_namespace(a.desc.org,&buffer) {return}
        append(out,Walk_Item{address,.DDC_Set,false})
    case .Overlay:
        project,scope,ok:=overlay_namespace_parse(namespace)
        if !ok {return}
        known:=false
        for sc in a.org.scopes {known||=sc.project==project && sc.scope==scope}
        if !known {return}
        append(out,Walk_Item{address,.Overlay,false})
    }
}

// Adds to the members' set the chunks of what roots reach, down to what it
// holds; an object that is not here, or not whole, or a root that did not
// come from the org yet, waits in the frontier (walk_admits).
@(private)
members_walk :: proc(a:^Agent,roots:[]Walk_Item) {
    scratch:=scratch_make()
    m:=&a.members
    stack:=make([dynamic]Walk_Item,context.temp_allocator)
    append(&stack,..roots)
    seen:=make(map[store.Hash]bool,context.temp_allocator)
    added:=make([dynamic]store.Hash,context.temp_allocator)
    empty:=empty_address()
    w:=walk_make(a.desc.store)
    w.proven,w.own=&m.provenance,a.desc.identity.key
    for len(stack)>0 {
        item:=pop(&stack)
        if item.address=={} || item.address in m.chunks || seen[item.address] {continue}
        admit:=walk_admits(&w,item)
        if admit==.No {continue}
        if admit==.Wait {
            if item.address!=empty {m.frontier[item.address]=item}
            continue
        }
        seen[item.address]=true
        at:=len(added)
        if !object_chunks(a.desc.store,item.address,&added,scratch) {
            resize(&added,at)
            if item.address!=empty {m.frontier[item.address]=item}
            continue
        }
        delete_key(&m.frontier,item.address)
        if a.desc.hosted {m.stored+=object_bytes(a.desc.store,item.address)}
        walk_children(&w,item,&stack)
        // A change's overlays: a snapshot writes their refs without telling the
        // agent, which tells the peers that read them here.
        if item.kind!=.Change || !a.folded {continue}
        name:[64]u8
        for sc in a.org.scopes {
            ns:[len(OVERLAY_PREFIX)+64+1+32]u8
            namespace:=overlay_namespace(sc.project,sc.scope,&ns)
            if record,e:=store.ref_get(a.desc.store,namespace,store.hex(item.address,&name));e==.None {
                members_roots(a,.Overlay,namespace,record,&stack)
                exchange.ref_changed(&a.x,namespace,store.hex(item.address,&name),record)
            }
        }
    }
    if len(added)==0 {return}
    for c in added {m.chunks[c]={}}
}

// The chunks the grant of x covers besides the user logs (see the head of
// this file).
@(private)
agent_grant_chunks :: proc(a:^Agent,x:Allowed,out:^[dynamic]store.Hash) {
    scratch:=scratch_make()
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
            log_objects(a.desc.store,address,out,scratch)
        }
    }
    if g.rights&{.Read,.Write,.Check}!={} {
        targets:=make([dynamic]Revision,context.temp_allocator)
        roots:=make([dynamic]store.Hash,context.temp_allocator)
        agent_targets(a,g.project,false,&targets,&roots,proven=true)
        closure_walk_scoped(a.desc.store,targets[:],g.path,&roots)
        for r in roots {object_chunks(a.desc.store,r,out,scratch)}
    }
    // The untainted derived data whose outputs came from the org, as the members' set takes it.
    if .DDC in g.rights {
        ns:[len(DDC_PREFIX)+64]u8
        refs,ref_error:=store.ref_list(a.desc.store,ddc_namespace(a.desc.org,&ns),context.temp_allocator)
        if ref_error!=.None {return}
        roots:=make([dynamic]Walk_Item,context.temp_allocator)
        for r in refs {append(&roots,Walk_Item{r.hash,.DDC_Set,false})}
        w:=walk_make(a.desc.store)
        w.untainted,w.proven,w.own=true,&a.members.provenance,a.desc.identity.key
        present:=make([dynamic]store.Hash,context.temp_allocator)
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        walk_all(&w,roots[:],&present,&missing)
        for o in present {object_chunks(a.desc.store,o,out,scratch)}
    }
}

// A seed fetches what the closure of every bookmark lacks.
@(private)
agent_seed :: proc(a:^Agent) {
    if agent_full(a) {return}
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

// The Kai objects under revisions that a grant of path scope reads: every
// change, its parents and what it attaches, the files scope covers with the conflicts at such
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
        for a in c.attachments {append(present,a.object)}
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
        path,pe:=path_join(prefix,entry.name)
        if pe!=nil {continue}
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
            if ce:=conflict_get(s,entry.address,&terms);ce!=.None {continue}
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
// whole: every node of it was read. Its nodes are read into scratch
// (store.CHUNK_MAX bytes, scratch_make), which a walk allocates once.
object_chunks :: proc(s:^store.Store,address:store.Hash,out:^[dynamic]store.Hash,scratch:[]u8) -> (whole:bool) {
    return len(scratch)>=store.CHUNK_MAX && node_chunks(s,address,scratch,out,0)
}

// Whether every chunk of the object at address is in the store; scratch as
// object_chunks takes it.
object_whole :: proc(s:^store.Store,address:store.Hash,scratch:[]u8) -> bool {
    return len(scratch)>=store.CHUNK_MAX && node_chunks(s,address,scratch,nil,0)
}

scratch_make :: proc() -> []u8 {
    buffer,_:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
    return buffer
}

@(private)
node_chunks :: proc(s:^store.Store,address:store.Hash,buffer:[]u8,out:^[dynamic]store.Hash,depth:int) -> bool {
    if depth>store.NODE_LEVEL_MAX {return false}
    bytes,e:=store.chunk_read(s,address,buffer)
    if e!=.None {return false}
    n,parse_error:=store.node_parse(bytes)
    if parse_error!=.None {return false}
    // Without out, whether the leaves are here too.
    if out!=nil {append(out,address)}
    entries,clone_error:=slice.clone(n.entries,context.temp_allocator)
    if clone_error!=nil {return false}
    level:=n.level
    whole:=true
    for entry in entries {
        if level>0 {
            whole&=node_chunks(s,entry.address,buffer,out,depth+1)
        } else if out!=nil {
            append(out,entry.address)
        } else {
            whole&=store.chunk_here(s,entry.address)
        }
        if !whole && out==nil {return false}
    }
    return whole
}
