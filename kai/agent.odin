package kai

import "base:runtime"
import "core:crypto"
import "core:crypto/hash"
import "core:fmt"
import "core:net"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import wire "mirai:net"
import "mirai:store"

// The agent: what keeps a machine's orgs in sync with their other machines,
// in the editor, `mirai kai agent` or `mirai kai serve`. It listens on TCP
// (KAI_PORT), says on the LAN where (beacon) and dials every member of its
// orgs it knows an address of. Each connection (wire.odin) has three threads:
// the reader takes every message and stores the chunks that arrive, the
// server answers wants, and the puller fetches what the other end told it
// holds: newer org records, newer shared bookmarks and then every chunk of
// what they reach that is not whole here, for the repositories this machine
// keeps (those a workspace links, or all of them on a node). A chunk is asked
// by address and checked against it before the store keeps it; a pull goes as
// deep as the trees go, a round trip per level, many chunks in flight.
//
// What a peer reads: the chunks of an org whose member it is, from that org's
// store (a server keeps each org apart, Tenants), and the heads of that org.
// A head another process of this machine wrote reaches the peers within
// LOOK_SECONDS; one this process wrote, at once (agent_changed). An editor
// reads the agent's state and events under its lock, never over a socket.

AGENT_EVENTS_MAX :: 64
FETCH_WINDOW :: 2048  // chunks one fetch has asked and not had answered
FETCH_SECONDS :: 30   // a fetch with nothing answered for this long gives up on its peer
LOOK_SECONDS :: 1     // between two looks at the heads the store holds
REDIAL_SECONDS :: 15  // between two tries of a member that is not connected
DIAL_ADDRESSES :: 8   // addresses of one member one dial tries, in turn
WEB_LOGIN_SECONDS :: 15 // a server that does not answer a web sign-in for this long is given up
BEACON_SECONDS :: 5
BEACON_MAGIC :: "KAI2"
PEERS_MAX :: 256
REQUESTS_BYTES_MAX :: 1<<20 // of wants and asks a peer keeps waiting: past it its connection ends
TOLD_MAX :: 1<<16   // heads a peer may tell this end of

Agent_Options :: struct {
    port:int,       // TCP port to listen at: 0 for KAI_PORT, or any free port if it is taken; -1 listens at none
    host:string,    // the address to listen at; "" for every interface
    beacon:bool,    // say on the LAN where it listens, and dial the members that say it
    node:bool,      // keep every repository of its orgs whole and the derived data its writers publish
    max_orgs:int,   // orgs admins may self-register on this node; 0 disables self-registration
    peers:[]string, // host:port to dial besides the addresses it knows
    public:string,  // host:port where every member reaches this machine (a server's): what an org it joins lists
    portmap:bool,   // asks the router (PCP, NAT-PMP or UPnP) to forward its TCP port, so machines on other networks reach it with no server
    gateway:string, // host:port of the router portmap asks: "" for the default route's
    web_login:proc(data:rawptr,org_member:Key,name,password:string) -> bool, // a server's web view: a member names its sign-in
    web_data:rawptr,
}

// How far a repository's pull is.
Pull :: struct {
    org:Org_Id,
    repo:Repo_Id,
    chunks:int,  // arrived since the agent started
    left:int,    // asked or found and not here yet
    bytes:i64,   // arrived since the agent started
    whole:bool,  // every object its shared bookmarks reach is here
}

Peer_Info :: struct {
    key:Key,
    name,device:string, // as it says, in the caller's allocator
    address:string,     // host:port
    dialed:bool,
}

Agent :: struct {
    team:Team, // its own copy: strings owned by its allocator
    options:Agent_Options,
    lock:sync.Mutex,
    wake:sync.Cond,
    stopping:bool,
    listener:net.TCP_Socket,
    listening:bool,
    listen_host:net.IP4_Address, // what the listener is bound to
    port:int,
    dials:int,               // dial threads running, which agent_stop waits for
    threads:[dynamic]^thread.Thread,
    peers:[dynamic]^Peer,
    dialing:map[Key]i64,     // when a dial of each key (or, for a peer of the options, of its address) began, ns
    beacons:map[Key]string,  // where each member's beacon said it listens
    told:map[Tell_Key]store.Hash, // the heads the peers were told last
    events:[dynamic]string,
    mapping:wire.Port_Mapping,
    mapping_on:bool,
    pulls:[dynamic]Pull,
    waits:[dynamic]^Ddc_Wait,
    changed:bool,
    redial:bool,
    generation:u64, // one more each time what agent_peers, agent_pulls, agent_events or the heads give changes
    allocator:runtime.Allocator,
}

@(private)
Tell_Key :: struct {kind:Tell_Kind,org:Org_Id,id:store.Hash}

@(private)
Peer :: struct {
    agent:^Agent,
    conn:^Conn,
    dialed:string,          // the address it was dialed at; "" when it dialed this end
    socket:net.TCP_Socket,  // before the handshake of an accepted one
    remote:net.Endpoint,
    lock:sync.Mutex,        // of everything below
    cond:sync.Cond,
    name,device:[NAME_MAX]u8,
    name_len,device_len:int,
    port:int,
    told:map[Tell_Key]store.Hash, // what it holds
    dirty:bool,
    requests:[dynamic][]u8, // wants and asks waiting, their kind first
    requested:int,          // bytes of requests
    fetches:[dynamic]^Fetch,
    welcome:store.Hash,
    welcome_admission:store.Hash,
    ready:bool,             // its handshake held
    done:bool,              // its reader ended
    reader,server,puller:^thread.Thread,
    refs:int,               // under the agent's lock: callers holding it, which the reaper waits for
}

@(private)
Fetch :: struct {
    s:^store.Store,
    pending:map[store.Hash]struct{},
    arrived:[dynamic]Arrival,
}

@(private)
Arrival :: struct {address:store.Hash,lacked:bool,bytes:int}

@(private)
Ddc_Wait :: struct {
    org:Org_Id,
    key:store.Hash,
    found:store.Hash,
    from:^Peer,
    answers:int,
}

// Starts the agent of team's machine. The agent keeps its own copy of team.
agent_start :: proc(a:^Agent,team:^Team,options:Agent_Options,allocator:=context.allocator) -> Error {
    a^={options=options,allocator=allocator}
    a.team=team^
    name,ne:=strings.clone(team.name,allocator)
    device,de:=strings.clone(team.device,allocator)
    a.team.name,a.team.device=name,device
    if ne!=nil || de!=nil {
        agent_free(a)
        return .Out_Of_Memory
    }
    a.dialing=make(map[Key]i64,allocator)
    a.beacons=make(map[Key]string,allocator)
    a.told=make(map[Tell_Key]store.Hash,allocator)
    a.peers=make([dynamic]^Peer,allocator)
    a.threads=make([dynamic]^thread.Thread,allocator)
    if options.port>=0 {
        host:=net.IP4_Any
        if options.host!="" {
            if address,ok:=net.parse_ip4_address(options.host);ok {host=address} else {return team_fail(&a.team,.Invalid_Argument,"the address to listen at is no IPv4 address")}
        }
        // Loopback-only agents (tests) take an ephemeral port directly so they never
        // collide on macOS with a wildcard :7350 listener on another editor.
        port:=options.port==0?(host==net.IP4_Loopback?0:KAI_PORT):options.port
        socket,e:=net.listen_tcp({host,port})
        if e!=nil && options.port==0 {socket,e=net.listen_tcp({host,0})}
        if e!=nil {
            agent_free(a)
            return team_fail(&a.team,.Io,fmt.tprintf("port %d is taken: stop the other Kai agent or choose another port",port))
        }
        a.listener,a.listening,a.listen_host=socket,true,host
        if bound,be:=net.bound_endpoint(socket);be==nil {a.port=bound.port}
        if options.portmap {
            gateway:wire.Address
            if options.gateway!="" {
                ok:bool
                if gateway,ok=wire.address_parse(options.gateway);!ok {
                    net.close(socket)
                    agent_free(a)
                    return team_fail(&a.team,.Invalid_Argument,"the router's address is no host:port")
                }
            }
            a.mapping_on=wire.mapping_start(&a.mapping,u16(a.port),allocator,gateway,protocol=.TCP)
        }
        agent_thread(a,agent_accept_run)
    }
    agent_thread(a,agent_look_run)
    if options.beacon && a.listening {agent_thread(a,agent_beacon_run)}
    return .None
}

@(private)
agent_thread :: proc(a:^Agent,run:proc(a:^Agent)) {
    if t:=thread.create_and_start_with_poly_data(a,run,agent_context(a));t!=nil {append(&a.threads,t)}
}

// The context of a thread of the agent: the agent's allocator, the caller's
// logger and a temp allocator of the thread's own, which it frees as it ends
// (thread_end). Never the caller's context: its temp allocator is another
// thread's, and an editor's call may give an allocator that ends with it.
@(private)
agent_context :: proc(a:^Agent) -> runtime.Context {
    c:=runtime.default_context()
    c.allocator=a.allocator
    c.logger=context.logger
    return c
}

// What a thread of the agent frees as it ends: its temp allocator.
thread_end :: proc() {
    runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
}

// Stops the agent: closes every connection and waits for its threads.
agent_stop :: proc(a:^Agent) {
    context.allocator=a.allocator
    sync.mutex_lock(&a.lock)
    sync.atomic_store(&a.stopping,true)
    sync.cond_broadcast(&a.wake)
    sync.mutex_unlock(&a.lock)
    if a.listening {
        // accept wakes for a connection: one to itself, where it listens.
        host:=a.listen_host==net.IP4_Any?net.IP4_Loopback:a.listen_host
        if s,e:=net.dial_tcp_from_address_and_port(host,a.port);e==nil {net.close(s)}
    }
    for t in a.threads {
        thread.join(t)
        thread.destroy(t)
    }
    // The dials see stopping within a few milliseconds; then no thread adds a peer.
    sync.mutex_lock(&a.lock)
    for a.dials>0 {sync.cond_wait_with_timeout(&a.wake,&a.lock,10*time.Millisecond)}
    peers:=make([]^Peer,len(a.peers),context.temp_allocator)
    copy(peers,a.peers[:])
    sync.mutex_unlock(&a.lock)
    for p in peers {peer_end(p)}
    // A caller that still holds a peer (a join, an ask) lets go once its connection ended.
    sync.mutex_lock(&a.lock)
    for {
        held:=false
        for p in peers {held||=p.refs>0}
        if !held {break}
        sync.cond_wait_with_timeout(&a.wake,&a.lock,10*time.Millisecond)
    }
    sync.mutex_unlock(&a.lock)
    for p in peers {peer_free(p)}
    if a.listening {net.close(a.listener)}
    if a.mapping_on {
        wire.mapping_stop(&a.mapping)
        wire.mapping_close(&a.mapping)
    }
    agent_free(a)
}

@(private)
agent_free :: proc(a:^Agent) {
    for e in a.events {delete(e,a.allocator)}
    delete(a.events)
    for _,address in a.beacons {delete(address,a.allocator)}
    delete(a.beacons)
    delete(a.dialing)
    delete(a.told)
    delete(a.peers)
    delete(a.threads)
    delete(a.pulls)
    delete(a.waits)
    delete(a.team.name,a.allocator)
    delete(a.team.device,a.allocator)
    a.team={}
}

// Tells the agent that this process wrote heads: they go to the peers now,
// and what a workspace now links is pulled.
agent_changed :: proc(a:^Agent) {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    a.changed=true
    for p in a.peers {
        sync.mutex_lock(&p.lock)
        p.dirty=true
        sync.cond_broadcast(&p.cond)
        sync.mutex_unlock(&p.lock)
    }
    sync.cond_broadcast(&a.wake)
}

// Wakes the agent to immediately retry disconnected peers and sync heads.
agent_sync_now :: proc(a:^Agent) {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    clear(&a.dialing)
    a.redial=true
    a.changed=true
    for p in a.peers {
        sync.mutex_lock(&p.lock)
        p.dirty=true
        sync.cond_broadcast(&p.cond)
        sync.mutex_unlock(&p.lock)
    }
    sync.cond_broadcast(&a.wake)
}

// The port it listens at, 0 when none.
agent_port :: proc(a:^Agent) -> int {return a.port}

// What changes each time the peers, the pulls, the events or the heads this
// machine holds change: a view reads the agent again only when it moved.
agent_generation :: proc(a:^Agent) -> u64 {return sync.atomic_load(&a.generation)}

@(private)
agent_moved :: proc(a:^Agent) {sync.atomic_add(&a.generation,1)}

// How machines on other networks reach this one.
Reach :: enum u8 {
    Local,      // only on its LAN: the router forwards no port, or was not asked
    Connecting, // the router has not answered yet
    Online,     // at the address the router forwards
}

// How machines on other networks reach this one, and where when Online:
// host:port in allocator.
agent_reach :: proc(a:^Agent,allocator:=context.allocator) -> (reach:Reach,at:string) {
    if !a.listening || !a.mapping_on {return .Local,""}
    status:=wire.mapping_poll(&a.mapping)
    #partial switch status.phase {
    case .Pending: return .Connecting,""
    case .Mapped:
        if status.external.kind!=.IP4 {break}
        ip:=status.external.ip
        bytes:[ADDRESS_MAX]u8
        text,e:=strings.clone(fmt.bprintf(bytes[:],"%d.%d.%d.%d:%d",ip[0],ip[1],ip[2],ip[3],status.external.port),allocator)
        return .Online,e==nil?text:""
    }
    return .Local,""
}

// Waits up to timeout while the router has not answered, or until the agent
// stops: an invite made as the agent starts then carries the router's address.
agent_reach_wait :: proc(a:^Agent,timeout:time.Duration) -> Reach {
    started:=time.tick_now()
    sync.mutex_lock(&a.lock)
    for !a.stopping && a.listening && a.mapping_on && wire.mapping_poll(&a.mapping).phase==.Pending && time.tick_since(started)<timeout {
        sync.cond_wait_with_timeout(&a.wake,&a.lock,20*time.Millisecond)
    }
    sync.mutex_unlock(&a.lock)
    reach,_:=agent_reach(a,context.temp_allocator)
    return reach
}

// Where this machine listens, host:port, in allocator: what an invite
// carries. The router's address first when it forwards the port (portmap),
// then the LAN's; a machine outside the LAN reaches it only through the first.
agent_addresses :: proc(a:^Agent,allocator:=context.allocator) -> []string {
    out:=make([dynamic]string,allocator)
    if !a.listening {return out[:]}
    if a.mapping_on {
        if status:=wire.mapping_poll(&a.mapping);status.phase==.Mapped && status.external.kind==.IP4 {
            ip:=status.external.ip
            text_add(&out,fmt.tprintf("%d.%d.%d.%d:%d",ip[0],ip[1],ip[2],ip[3],status.external.port),allocator)
        }
    }
    if a.options.host!="" && a.options.host!="0.0.0.0" {
        text_add(&out,fmt.tprintf("%s:%d",a.options.host,a.port),allocator)
        return out[:]
    }
    interfaces,e:=net.enumerate_interfaces(context.temp_allocator)
    if e==nil {
        for interface in interfaces {
            if net.Link_States.Up not_in interface.link.state {continue}
            for lease in interface.unicast {
                ip,is_ip4:=lease.address.(net.IP4_Address)
                if !is_ip4 || ip[0]==127 || ip[0]==169 && ip[1]==254 {continue}
                text_add(&out,fmt.tprintf("%d.%d.%d.%d:%d",ip[0],ip[1],ip[2],ip[3],a.port),allocator)
            }
        }
    }
    if len(out)==0 {text_add(&out,fmt.tprintf("127.0.0.1:%d",a.port),allocator)}
    return out[:]
}

// Appends a copy of text in allocator, unless memory ran out.
@(private)
text_add :: proc(out:^[dynamic]string,text:string,allocator:runtime.Allocator) {
    if copied,e:=strings.clone(text,allocator);e==nil {append(out,copied)}
}

// Takes the events since the last call, oldest first, into out (allocator's).
agent_events :: proc(a:^Agent,out:^[dynamic]string,allocator:=context.allocator) {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    for e in a.events {
        text_add(out,e,allocator)
        delete(e,a.allocator)
    }
    clear(&a.events)
}

// The connected peers, into out, their texts in allocator.
agent_peers :: proc(a:^Agent,out:^[dynamic]Peer_Info,allocator:=context.allocator) {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    for p in a.peers {
        sync.mutex_lock(&p.lock)
        if p.ready && !p.done {
            host:=net.address_to_string(p.remote.address,context.temp_allocator)
            texts:=make([dynamic]string,context.temp_allocator)
            text_add(&texts,string(p.name[:p.name_len]),allocator)
            text_add(&texts,string(p.device[:p.device_len]),allocator)
            text_add(&texts,fmt.tprintf("%s:%d",host,p.port>0?p.port:p.remote.port),allocator)
            if len(texts)==3 {append(out,Peer_Info{key=p.conn.peer,name=texts[0],device=texts[1],address=texts[2],dialed=p.dialed!=""})}
        }
        sync.mutex_unlock(&p.lock)
    }
}

// How far each repository's pull is, into out.
agent_pulls :: proc(a:^Agent,out:^[dynamic]Pull) {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    append(out,..a.pulls[:])
}

// How far one repository's pull is, without allocating.
agent_pull_of :: proc(a:^Agent,org:Org_Id,repo:Repo_Id) -> (pull:Pull,ok:bool) {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    for x in a.pulls {
        if x.org==org && x.repo==repo {return x,true}
    }
    return {},false
}

@(private)
agent_event :: proc(a:^Agent,format:string,args:..any) {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    if len(a.events)>=AGENT_EVENTS_MAX {
        delete(a.events[0],a.allocator)
        ordered_remove(&a.events,0)
    }
    text_add(&a.events,fmt.tprintf(format,..args),a.allocator)
    agent_moved(a)
}

// --- Connections ---

@(private)
agent_accept_run :: proc(a:^Agent) {
    defer thread_end()
    for {
        socket,remote,e:=net.accept_tcp(a.listener)
        sync.mutex_lock(&a.lock)
        stopping:=a.stopping
        sync.mutex_unlock(&a.lock)
        if stopping {
            if e==nil {net.close(socket)}
            return
        }
        if e!=nil {
            time.sleep(100*time.Millisecond)
            continue
        }
        p,pe:=new(Peer)
        if pe!=nil {
            net.close(socket)
            continue
        }
        p.agent,p.socket,p.remote=a,socket,remote
        if !peer_add(a,p) {
            net.close(socket)
            free(p)
        }
    }
}

// Dials address and adds the peer once its handshake held: expect, when not
// zero, the key it must prove; secret, an invite's. The peer comes held
// (peer_unpin lets it go).
@(private)
agent_dial :: proc(a:^Agent,address:string,expect:Key,secret:[32]u8={}) -> (p:^Peer,error:Error) {
    context.allocator=a.allocator
    c,e:=conn_dial(address,a.team.identity,expect,secret,&a.stopping)
    if e!=.None {return nil,e}
    pe,de:runtime.Allocator_Error
    p,pe=new(Peer)
    if pe==nil {p.dialed,de=strings.clone(address)}
    if pe!=nil || de!=nil {
        conn_free(c)
        if p!=nil {free(p)}
        return nil,.Out_Of_Memory
    }
    p.agent,p.conn,p.remote=a,c,c.remote
    if !peer_add(a,p) {
        conn_free(c)
        delete(p.dialed)
        free(p)
        return nil,.Invalid_Argument
    }
    return p,.None
}

// Adds a peer and starts its reader; a dialed one comes held.
@(private)
peer_add :: proc(a:^Agent,p:^Peer) -> bool {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    if a.stopping || len(a.peers)>=PEERS_MAX {return false}
    p.told=make(map[Tell_Key]store.Hash)
    p.reader=thread.create_and_start_with_poly_data(p,peer_read_run,agent_context(a))
    if p.reader==nil {
        delete(p.told)
        return false
    }
    if p.dialed!="" {p.refs=1}
    append(&a.peers,p)
    return true
}

// Holds p: the reaper does not free it until peer_unpin.
@(private)
peer_pin :: proc(a:^Agent,p:^Peer) {
    sync.mutex_lock(&a.lock)
    p.refs+=1
    sync.mutex_unlock(&a.lock)
}

@(private)
peer_unpin :: proc(a:^Agent,p:^Peer) {
    sync.mutex_lock(&a.lock)
    p.refs-=1
    sync.cond_broadcast(&a.wake)
    sync.mutex_unlock(&a.lock)
}

// The peers whose handshake held and whose reader runs, each held: a caller
// sends to them outside the agent's lock and lets them go (peers_unpin).
@(private)
peers_live :: proc(a:^Agent) -> []^Peer {
    out:=make([dynamic]^Peer,context.temp_allocator)
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    for p in a.peers {
        sync.mutex_lock(&p.lock)
        live:=p.ready && !p.done
        sync.mutex_unlock(&p.lock)
        if !live {continue}
        p.refs+=1
        append(&out,p)
    }
    return out[:]
}

@(private)
peers_unpin :: proc(a:^Agent,peers:[]^Peer) {
    for p in peers {peer_unpin(a,p)}
}

// Ends a peer's connection, so its threads end.
@(private)
peer_end :: proc(p:^Peer) {
    sync.mutex_lock(&p.lock)
    p.done=true
    sync.cond_broadcast(&p.cond)
    c:=p.conn
    if c==nil {net.shutdown(p.socket,.Both)}
    sync.mutex_unlock(&p.lock)
    if c!=nil {conn_close(c)}
}

@(private)
// Frees an ended peer: its reader first, which alone starts the other two.
// An accepted socket whose handshake failed is the peer's to close.
peer_free :: proc(p:^Peer) {
    thread.join(p.reader)
    thread.destroy(p.reader)
    sync.mutex_lock(&p.lock)
    others:=[2]^thread.Thread{p.server,p.puller}
    sync.mutex_unlock(&p.lock)
    for t in others {
        if t==nil {continue}
        thread.join(t)
        thread.destroy(t)
    }
    if p.conn!=nil {conn_free(p.conn)} else {net.close(p.socket)}
    for r in p.requests {delete(r)}
    delete(p.requests)
    delete(p.fetches)
    delete(p.told)
    delete(p.dialed)
    free(p)
}

// The role key has in org (including verified offline admissions); ok false
// when it is no member or the org is not held.
@(private)
agent_role :: proc(a:^Agent,org:Org_Id,key:Key) -> (role:Role,ok:bool) {
    s,e:=team_store(&a.team,org)
    if e!=.None {return}
    o,_,he:=org_effective_head(s,org,context.temp_allocator)
    if he!=.None {return}
    return org_role(&o,key)
}

// Whether key is a member of any org this machine holds.
@(private)
agent_knows :: proc(a:^Agent,key:Key) -> bool {
    for id in team_org_ids(&a.team) {
        if _,ok:=agent_role(a,id,key);ok {return true}
    }
    return false
}

// The heads of every org this machine holds whose member key is: its record,
// verified offline admissions, its repositories' shared bookmarks and, for a
// server of the org (or every one, key zero), the derived data sets it holds.
@(private)
agent_heads :: proc(a:^Agent,key:Key,out:^[dynamic]Tell_Entry) {
    for id in team_org_ids(&a.team) {
        s,e:=team_store(&a.team,id)
        if e!=.None {continue}
        o,address,he:=org_effective_head(s,id,context.temp_allocator)
        if he!=.None {continue}
        role,member:=org_role(&o,key)
        if key!={} && !member {continue}
        if key=={} || role==.Node {
            ns:[len(DDC_PREFIX)+32]u8
            refs,_:=store.ref_list(s,ddc_namespace(id,&ns),context.temp_allocator)
            for ref in refs {
                k,ok:=store.parse_hex(ref.name)
                if ok {append(out,Tell_Entry{kind=.Ddc,org=id,id=k,address=ref.hash})}
            }
        }
        append(out,Tell_Entry{kind=.Org,org=id,address=address})
        ans:[len(ADMIT_PREFIX)+32]u8
        if arefs,ae:=store.ref_list(s,admit_namespace(id,&ans),context.temp_allocator);ae==.None {
            for ref in arefs {
                k:store.Hash
                if hex_parse(ref.name,k[:]) {append(out,Tell_Entry{kind=.Admit,org=id,id=k,address=ref.hash})}
            }
        }
        for r in o.repos {
            _,refs,re:=repo_refs_head(s,id,r.id,context.temp_allocator)
            if re!=.None {continue}
            entry:=Tell_Entry{kind=.Repo,org=id,address=refs}
            repo:=r.id
            copy(entry.id[:16],repo[:])
            append(out,entry)
        }
    }
}

@(private)
peer_tell :: proc(p:^Peer,entries:[]Tell_Entry,kind:=Msg.Tell) -> bool {
    a:=p.agent
    k:=kind
    at:=0
    for {
        part:=entries[at:min(len(entries),at+1000)]
        count:=u16(len(part))
        body:=make([dynamic]u8,context.temp_allocator)
        if k==.Hello {
            write_text(&body,a.team.name)
            write_text(&body,a.team.device)
            port:=u16(a.port)
            append(&body,u8(port),u8(port>>8))
        }
        append(&body,u8(count),u8(count>>8))
        for &e in part {
            bytes:=transmute([size_of(Tell_Entry)]u8)e
            append(&body,..bytes[:])
        }
        if !conn_send(p.conn,k,body[:]) {return false}
        k=.Tell
        at+=len(part)
        if at>=len(entries) {return true}
    }
}

@(private)
write_text :: proc(out:^[dynamic]u8,text:string) {
    n:=min(len(text),255)
    append(out,u8(n))
    append(out,..transmute([]u8)text[:n])
}

// The reader: the handshake of an accepted connection, the Hello both ends
// send first, then every message until the connection ends.
@(private)
peer_read_run :: proc(p:^Peer) {
    defer thread_end()
    a:=p.agent
    defer {
        sync.mutex_lock(&p.lock)
        p.done=true
        sync.cond_broadcast(&p.cond)
        sync.mutex_unlock(&p.lock)
        if p.conn!=nil {conn_close(p.conn)}
        sync.mutex_lock(&a.lock)
        sync.cond_broadcast(&a.wake)
        sync.mutex_unlock(&a.lock)
        agent_moved(a)
    }
    if p.conn==nil {
        c,e:=conn_accept(p.socket,p.remote,a.team.identity)
        if e!=.None {return}
        sync.mutex_lock(&p.lock)
        p.conn=c
        sync.mutex_unlock(&p.lock)
    }
    c:=p.conn
    joining:=c.proof!={}
    // A peer this machine's records do not list yet may hold a newer record
    // that does: it stays when its Hello names an org held here, and reads
    // nothing until a record lists it (agent_role, at every request).
    vouched:=joining || p.dialed!="" || agent_knows(a,c.peer)
    buffer,be:=make([]u8,FRAME_MAX+NOISE_TAG)
    if be!=nil {return}
    defer delete(buffer)
    // An initiator's first message: control RPCs (web sign-in, server attach,
    // offline invite grant/revoke) run on their own short connection so they
    // never disrupt the sync connection kept to the peer's key.
    first:Msg
    first_body:[]u8
    if p.dialed=="" {
        ok:bool
        if first,first_body,ok=conn_receive(c,buffer);!ok {return}
        #partial switch first {
        case .Web_Login:
            r:=Reader{data=first_body}
            name:=tail_string(&r)
            password:=tail_string(&r)
            if r.short {return}
            signed:=a.options.web_login!=nil && agent_knows(a,c.peer) && a.options.web_login(a.options.web_data,c.peer,name,password)
            conn_send(c,.Bye,transmute([]u8)string(signed?"web sign-in set":"this server keeps no web view for that device"))
            return
        case .Server_Info:
            agent_serve_server_info(a,c,buffer)
            return
        case .Org_Register:
            agent_handle_org_register(a,c,first_body)
            return
        case .Invite_Grant:
            agent_handle_invite_grant(a,c,first_body)
            return
        case .Invite_Revoke:
            agent_handle_invite_revoke(a,c,first_body)
            return
        }
    }
    if !peer_unique(a,p) {return}
    heads:=make([dynamic]Tell_Entry,context.temp_allocator)
    agent_heads(a,c.peer,&heads)
    if !peer_tell(p,heads[:],.Hello) {return}
    // The other two start only while the peer runs: one ended meanwhile starts none.
    sync.mutex_lock(&p.lock)
    if p.done {
        sync.mutex_unlock(&p.lock)
        return
    }
    p.ready=true
    p.server=thread.create_and_start_with_poly_data(p,peer_serve_run,agent_context(a))
    p.puller=thread.create_and_start_with_poly_data(p,peer_pull_run,agent_context(a))
    started:=p.server!=nil && p.puller!=nil
    sync.mutex_unlock(&p.lock)
    if !started {return}
    agent_moved(a)
    raw,re:=make([]u8,store.CHUNK_MAX)
    if re!=nil {return}
    defer delete(raw)
    for {
        free_all(context.temp_allocator)
        kind,body:=first,first_body
        if kind==.None {
            ok:bool
            if kind,body,ok=conn_receive(c,buffer);!ok {return}
        }
        first=.None
        r:=Reader{data=body}
        switch kind {
        case .None:
        case .Hello:
            name:=tail_string(&r)
            device:=tail_string(&r)
            port:=int(read_value(&r,u16le))
            if r.short {return}
            sync.mutex_lock(&p.lock)
            p.name_len=copy(p.name[:],name)
            p.device_len=copy(p.device[:],device)
            p.port=port
            sync.mutex_unlock(&p.lock)
            if port>0 && agent_knows(a,c.peer) {
                host:=net.address_to_string(p.remote.address,context.temp_allocator)
                team_peer_seen(&a.team,c.peer,fmt.tprintf("%s:%d",host,port))
            }
            at:=r.at
            if !vouched && !hello_names_an_org(a,&r) {
                conn_send(c,.Bye,transmute([]u8)string("this device is no member of an org this machine keeps: join with an invite from an admin"))
                return
            }
            r.at=at
            if !peer_told(p,&r) {return}
        case .Tell:
            if !peer_told(p,&r) {return}
        case .Want,.Ddc_Ask:
            copied,ce:=make([]u8,len(body)+1)
            if ce!=nil {return}
            copied[0]=u8(kind)
            copy(copied[1:],body)
            sync.mutex_lock(&p.lock)
            // An asker keeps at most FETCH_WINDOW chunks asked: far less than this.
            full:=p.requested+len(copied)>REQUESTS_BYTES_MAX
            if !full {
                append(&p.requests,copied)
                p.requested+=len(copied)
            }
            sync.cond_broadcast(&p.cond)
            sync.mutex_unlock(&p.lock)
            if full {
                delete(copied)
                return
            }
        case .Chunks:
            if !peer_chunks(p,&r,raw) {return}
        case .Lack:
            count:=int(read_value(&r,u16le))
            for _ in 0..<count {
                address:=read_value(&r,store.Hash)
                if r.short {return}
                peer_arrived(p,address,true,0)
            }
        case .Join:
            org:=read_value(&r,Org_Id)
            name:=tail_string(&r)
            device:=tail_string(&r)
            public:=tail_string(&r)
            claim:[]u8
            if !r.short && r.at<len(body) {
                clen:=int(read_value(&r,u16le))
                claim=read_bytes(&r,clen)
            }
            if r.short || !joining {return}
            if !agent_admit(a,p,org,name,device,public,claim) {return}
        case .Welcome:
            org:=read_value(&r,Org_Id)
            address:=read_value(&r,store.Hash)
            admission:store.Hash
            if !r.short && r.at<len(body) {admission=read_value(&r,store.Hash)}
            if r.short {return}
            _=org
            sync.mutex_lock(&p.lock)
            p.welcome=address
            p.welcome_admission=admission
            sync.cond_broadcast(&p.cond)
            sync.mutex_unlock(&p.lock)
        case .Bye:
            agent_event(a,"%s left: %s",peer_text(p),string(body[:min(len(body),300)]))
            return
        case .Web_Login,.Server_Info,.Org_Register,.Invite_Grant,.Invite_Revoke:
            return // only as an initiator's first message
        }
    }
}

// Whether the Tell's body at r names an org this machine holds.
@(private)
hello_names_an_org :: proc(a:^Agent,r:^Reader) -> bool {
    count:=int(read_value(r,u16le))
    if !count_fits(r,u64(count),size_of(Tell_Entry)) {return false}
    held:=team_org_ids(&a.team)
    for _ in 0..<count {
        e:=read_value(r,Tell_Entry)
        for id in held {if e.kind==.Org && id==e.org {return true}}
    }
    return false
}

// Whether p is the one connection kept to its key: of two, the one whose
// dialing end has the lower key, which both ends choose alike.
@(private)
peer_unique :: proc(a:^Agent,p:^Peer) -> bool {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    own:=a.team.identity.key
    key:=p.conn.peer // set before this reader runs it, by its own thread
    for q in a.peers {
        if q==p {continue}
        sync.mutex_lock(&q.lock)
        live:=q.ready && !q.done && q.conn!=nil && q.conn.peer==key
        sync.mutex_unlock(&q.lock)
        if !live {continue}
        initiator :: proc(x:^Peer,own,key:Key) -> Key {return x.dialed!=""?own:key}
        if key_less(initiator(q,own,key),initiator(p,own,key)) {return false}
        peer_end(q)
    }
    return true
}

@(private)
peer_text :: proc(p:^Peer) -> string {
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    if p.device_len>0 {return fmt.tprintf("%s (%s)",string(p.device[:p.device_len]),string(p.name[:p.name_len]))}
    return net.address_to_string(p.remote.address,context.temp_allocator)
}

// Takes a Tell: what the peer holds now, for the orgs both are in.
@(private)
peer_told :: proc(p:^Peer,r:^Reader) -> bool {
    a:=p.agent
    count:=int(read_value(r,u16le))
    if !count_fits(r,u64(count),size_of(Tell_Entry)) {return false}
    for _ in 0..<count {
        e:=read_value(r,Tell_Entry)
        if e.kind>max(Tell_Kind) {return false}
        if e.kind==.Ddc {
            sync.mutex_lock(&a.lock)
            for w in a.waits {
                if w.org!=e.org || w.key!=e.id {continue}
                w.answers+=1
                if e.address!={} && w.found=={} {
                    w.found,w.from=e.address,p
                    p.refs+=1 // the asker lets it go
                }
            }
            sync.cond_broadcast(&a.wake)
            sync.mutex_unlock(&a.lock)
            if !a.options.node || e.address=={} {continue}
        }
        sync.mutex_lock(&p.lock)
        k:=Tell_Key{e.kind,e.org,e.id}
        full:=len(p.told)>=TOLD_MAX && k not_in p.told
        if !full {
            p.told[k]=e.address
            p.dirty=true
        }
        sync.cond_broadcast(&p.cond)
        sync.mutex_unlock(&p.lock)
        if full {return false}
    }
    return true
}

// Stores the chunks of a Chunks message that a fetch of this peer asked.
@(private)
peer_chunks :: proc(p:^Peer,r:^Reader,raw:[]u8) -> bool {
    count:=int(read_value(r,u16le))
    for _ in 0..<count {
        address:=read_value(r,store.Hash)
        codec:=read_value(r,u8)
        size:=int(read_value(r,u32le))
        stored_size:=int(read_value(r,u32le))
        stored:=read_bytes(r,stored_size)
        if r.short || size<=0 || size>store.CHUNK_MAX {return false}
        s:=peer_fetch_store(p,address)
        if s==nil {continue}
        e:store.Error
        if codec==store.CODEC_NONE {
            if store.address_of_bytes(stored)!=address || stored_size!=size {return false}
            e=store.chunk_put(s,address,stored)
        } else {
            e=store.chunk_put_frame(s,address,codec,stored,raw[:size])
        }
        if e==.Corrupt || e==.Invalid_Argument {return false}
        peer_arrived(p,address,e!=.None,size)
    }
    return true
}

@(private)
peer_fetch_store :: proc(p:^Peer,address:store.Hash) -> ^store.Store {
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    for f in p.fetches {
        if address in f.pending {return f.s}
    }
    return nil
}

@(private)
peer_arrived :: proc(p:^Peer,address:store.Hash,lacked:bool,bytes:int) {
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    for f in p.fetches {
        if address not_in f.pending {continue}
        delete_key(&f.pending,address)
        append(&f.arrived,Arrival{address,lacked,bytes})
        sync.cond_broadcast(&p.cond)
        return
    }
}

// --- Serving ---

@(private)
peer_serve_run :: proc(p:^Peer) {
    defer thread_end()
    a:=p.agent
    buffer,be:=make([]u8,FRAME_MAX)
    if be!=nil {return}
    defer delete(buffer)
    chunk,ce:=make([]u8,store.CHUNK_MAX)
    if ce!=nil {return}
    defer delete(chunk)
    for {
        free_all(context.temp_allocator)
        sync.mutex_lock(&p.lock)
        for len(p.requests)==0 && !p.done {sync.cond_wait(&p.cond,&p.lock)}
        if p.done {
            sync.mutex_unlock(&p.lock)
            return
        }
        request:=p.requests[0]
        ordered_remove(&p.requests,0)
        p.requested-=len(request)
        sync.mutex_unlock(&p.lock)
        defer delete(request)
        r:=Reader{data=request[1:]}
        org:=read_value(&r,Org_Id)
        if r.short {return}
        _,member:=agent_role(a,org,p.conn.peer)
        s,se:=team_store(&a.team,org)
        if !member || se!=.None {
            conn_send(p.conn,.Bye,transmute([]u8)string("this device is no member of that org here"))
            peer_end(p)
            return
        }
        if Msg(request[0])==.Ddc_Ask {
            key:=read_value(&r,store.Hash)
            if r.short {return}
            entry:=Tell_Entry{kind=.Ddc,org=org,id=key}
            ns:[len(DDC_PREFIX)+32]u8
            name:[64]u8
            entry.address,_=store.ref_get(s,ddc_namespace(org,&ns),store.hex(key,&name))
            if !peer_tell(p,{entry}) {return}
            continue
        }
        count:=int(read_value(&r,u16le))
        if count>WANT_MAX || !count_fits(&r,u64(count),size_of(store.Hash)) {return}
        lacking:=make([dynamic]store.Hash,context.temp_allocator)
        at,n:=2,0
        for _ in 0..<count {
            address:=read_value(&r,store.Hash)
            bytes,codec,size,e:=store.chunk_read_frame(s,address,chunk)
            if e!=.None {
                append(&lacking,address)
                continue
            }
            if at+32+1+8+len(bytes)>FRAME_FILL {
                if !serve_flush(p,buffer,at,n) {return}
                at,n=2,0
            }
            copy(buffer[at:],address[:])
            buffer[at+32]=codec
            put_u32(buffer[at+33:],u32(size))
            put_u32(buffer[at+37:],u32(len(bytes)))
            copy(buffer[at+41:],bytes)
            at+=41+len(bytes)
            n+=1
        }
        if n>0 && !serve_flush(p,buffer,at,n) {return}
        for k:=0;k<len(lacking);k+=1000 {
            part:=lacking[k:min(len(lacking),k+1000)]
            head:=[2]u8{u8(len(part)),u8(len(part)>>8)}
            if !conn_send(p.conn,.Lack,head[:],slice.to_bytes(part)) {return}
        }
    }
}

@(private)
serve_flush :: proc(p:^Peer,buffer:[]u8,at,n:int) -> bool {
    buffer[0],buffer[1]=u8(n),u8(n>>8)
    return conn_send(p.conn,.Chunks,buffer[:at])
}

@(private)
put_u32 :: proc(out:[]u8,v:u32) {
    for k in 0..<4 {out[k]=u8(v>>(8*uint(k)))}
}

// --- Pulling ---

@(private)
peer_pull_run :: proc(p:^Peer) {
    defer thread_end()
    for {
        free_all(context.temp_allocator)
        sync.mutex_lock(&p.lock)
        for !p.dirty && !p.done {sync.cond_wait(&p.cond,&p.lock)}
        if p.done {
            sync.mutex_unlock(&p.lock)
            return
        }
        p.dirty=false
        told:=make([dynamic]Tell_Entry,context.temp_allocator)
        for k,address in p.told {append(&told,Tell_Entry{kind=k.kind,org=k.org,id=k.id,address=address})}
        sync.mutex_unlock(&p.lock)
        if peer_pull(p,told[:]) {agent_changed(p.agent)}
    }
}

// Fetches what the peer told it holds and this machine keeps; changed when a
// head here moved.
@(private)
peer_pull :: proc(p:^Peer,told:[]Tell_Entry) -> (changed:bool) {
    a:=p.agent
    for e in told {
        if e.kind!=.Org {continue}
        if _,member:=agent_role(a,e.org,a.team.identity.key);!member {continue}
        moved,_:=agent_org_pull(a,p,e.org,e.address)
        changed||=moved
    }
    for e in told {
        if e.kind!=.Admit {continue}
        if _,member:=agent_role(a,e.org,a.team.identity.key);!member {continue}
        s,se:=team_store(&a.team,e.org)
        if se!=.None {continue}
        o,_,oe:=org_head(s,e.org,context.temp_allocator)
        if oe!=.None {continue}
        if !peer_fetch(p,e.org,s,{e.address},nil) {continue}
        moved,ae:=admission_accept(s,&o,e.address)
        if ae==.None && moved {
            store.commit(s)
            changed=true
            if role,ok:=org_role(&o,a.team.identity.key);ok && role==.Admin {
                sync.mutex_lock(&a.lock)
                team_admissions_merge(&a.team,e.org)
                sync.mutex_unlock(&a.lock)
            }
        }
    }
    for e in told {
        if e.kind==.Org || e.kind==.Admit {continue}
        s,se:=team_store(&a.team,e.org)
        if se!=.None {continue}
        o,_,oe:=org_effective_head(s,e.org,context.temp_allocator)
        if oe!=.None || org_member(&o,a.team.identity.key)<0 {continue}
        switch e.kind {
        case .Org,.Admit:
        case .Repo:
            if !peer_fetch(p,e.org,s,{e.address},nil) {continue}
            moved,_:=repo_refs_accept(s,&o,e.address)
            changed||=moved
        case .Ddc:
            _,moved:=peer_ddc_take(p,&o,s,e.id,e.address)
            changed||=moved
        }
    }
    // The repositories this machine keeps whole.
    links:=team_links(&a.team)
    for id in team_org_ids(&a.team) {
        s,se:=team_store(&a.team,id)
        if se!=.None {continue}
        o,_,oe:=org_effective_head(s,id,context.temp_allocator)
        if oe!=.None {continue}
        if _,member:=agent_role(a,id,p.conn.peer);!member {continue}
        for r in o.repos {
            kept:=a.options.node
            for l in links {kept||=l.org==id && l.repo==r.id}
            if !kept {continue}
            refs,_,re:=repo_refs_head(s,id,r.id,context.temp_allocator)
            if re!=.None {continue}
            roots:=make([dynamic]Walk_Item,context.temp_allocator)
            for b in refs.bookmarks {append(&roots,Walk_Item{b.target,.Change})}
            pull:=agent_pull_get(a,id,r.id)
            before:=pull.chunks
            whole:=peer_whole(p,id,s,roots[:],&pull)
            pull.whole,pull.left=whole,whole?0:pull.left
            agent_pull_set(a,pull)
            if whole && pull.chunks>before {
                agent_event(a,"pulled %s from %s: %d chunks, %d bytes",r.name,peer_text(p),pull.chunks,pull.bytes)
                changed=true
            }
        }
    }
    return
}

// Takes the derived data set of key at address from p: the set, then whole
// the outputs of its records the org allows, and only then the key's ref.
// whole when they are here, changed when the ref moved.
@(private)
peer_ddc_take :: proc(p:^Peer,org:^Org,s:^store.Store,key,address:store.Hash) -> (whole,changed:bool) {
    if !peer_fetch(p,org.id,s,{address},nil) {return}
    records:=make([dynamic][]u8,context.temp_allocator)
    if ddc_set_read(s,address,&records)!=.None {return}
    roots:=make([dynamic]Walk_Item,context.temp_allocator)
    for record in records {
        if d,ok:=ddc_record_allowed(org,key,record);ok {append(&roots,Walk_Item{d.output_root,.Output})}
    }
    if len(roots)==0 || !peer_whole(p,org.id,s,roots[:],nil) {return}
    moved,_,e:=ddc_accept(s,org,key,address) // its ref_set commits
    return e==.None,moved
}

// Fetches from p every object roots reach that is not whole in s, a level at
// a time; whole when nothing is missing any more.
@(private)
peer_whole :: proc(p:^Peer,org:Org_Id,s:^store.Store,roots:[]Walk_Item,pull:^Pull) -> bool {
    for {
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        walk_missing(s,roots,nil,&missing)
        if len(missing)==0 {return true}
        if !peer_fetch(p,org,s,missing[:],pull) {return false}
    }
}

@(private)
agent_pull_get :: proc(a:^Agent,org:Org_Id,repo:Repo_Id) -> Pull {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    for x in a.pulls {
        if x.org==org && x.repo==repo {return x}
    }
    return {org=org,repo=repo}
}

@(private)
agent_pull_set :: proc(a:^Agent,pull:Pull) {
    agent_moved(a)
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    for &x in a.pulls {
        if x.org==pull.org && x.repo==pull.repo {
            x=pull
            return
        }
    }
    append(&a.pulls,pull)
}

// Fetches the org's records from p back to one held, then takes the newest.
// create makes the org's store on a server: only a join does.
@(private)
agent_org_pull :: proc(a:^Agent,p:^Peer,org:Org_Id,address:store.Hash,create:=false) -> (changed:bool,error:Error) {
    s:=team_store(&a.team,org,create) or_return
    for _ in 0..<ORG_CHAIN_MAX {
        moved,need,e:=org_accept(s,org,address)
        if e!=.Missing {
            store.commit(s)
            return moved,e
        }
        if !peer_fetch(p,org,s,{need},nil) {return false,.Missing}
    }
    return false,.Too_Large
}

// Fetches every chunk of the objects at roots that s lacks from p, many in
// flight; ok when all came. pull, when given, counts what arrived.
@(private)
peer_fetch :: proc(p:^Peer,org:Org_Id,s:^store.Store,roots:[]store.Hash,pull:^Pull) -> (ok:bool) {
    f,fe:=new(Fetch)
    if fe!=nil {return false}
    defer free(f)
    f.s=s
    f.pending=make(map[store.Hash]struct{})
    defer delete(f.pending)
    defer delete(f.arrived)
    sync.mutex_lock(&p.lock)
    append(&p.fetches,f)
    sync.mutex_unlock(&p.lock)
    defer {
        sync.mutex_lock(&p.lock)
        for x,k in p.fetches {
            if x==f {
                unordered_remove(&p.fetches,k)
                break
            }
        }
        sync.mutex_unlock(&p.lock)
        store.commit(s)
    }
    Want :: struct {address:store.Hash,node:bool}
    queue:=make([dynamic]Want,context.temp_allocator)
    nodes:=make(map[store.Hash]bool,context.temp_allocator)
    for r in roots {append(&queue,Want{r,true})}
    buffer,be:=make([]u8,store.CHUNK_MAX)
    if be!=nil {return false}
    defer delete(buffer)
    inflight:=0
    lacked:=false
    batch:=make([dynamic]store.Hash,context.temp_allocator)
    for len(queue)>0 || inflight>0 {
        for len(queue)>0 && inflight<FETCH_WINDOW {
            clear(&batch)
            sync.mutex_lock(&p.lock)
            for len(queue)>0 && len(batch)<WANT_MAX && inflight+len(batch)<FETCH_WINDOW {
                w:=pop(&queue)
                if w.address in nodes || store.chunk_here(s,w.address) && !w.node {continue}
                if w.node && store.chunk_here(s,w.address) {
                    // A node here: its children may not be.
                    nodes[w.address]=true
                    sync.mutex_unlock(&p.lock)
                    fetch_children(s,w.address,buffer,&queue)
                    sync.mutex_lock(&p.lock)
                    continue
                }
                nodes[w.address]=w.node
                f.pending[w.address]={}
                append(&batch,w.address)
            }
            sync.mutex_unlock(&p.lock)
            if len(batch)==0 {break}
            head:=[2]u8{u8(len(batch)),u8(len(batch)>>8)}
            o:=org
            if !conn_send(p.conn,.Want,o[:],head[:],slice.to_bytes(batch[:])) {return false}
            inflight+=len(batch)
        }
        if inflight==0 {break}
        sync.mutex_lock(&p.lock)
        deadline:=time.tick_now()
        for len(f.arrived)==0 && !p.done {
            if time.tick_since(deadline)>FETCH_SECONDS*time.Second {
                sync.mutex_unlock(&p.lock)
                return false
            }
            sync.cond_wait_with_timeout(&p.cond,&p.lock,time.Second)
        }
        if p.done {
            sync.mutex_unlock(&p.lock)
            return false
        }
        arrived:=make([]Arrival,len(f.arrived),context.temp_allocator)
        copy(arrived,f.arrived[:])
        clear(&f.arrived)
        sync.mutex_unlock(&p.lock)
        for x in arrived {
            inflight-=1
            if x.lacked {
                lacked=true
                continue
            }
            if pull!=nil {
                pull.chunks+=1
                pull.bytes+=i64(x.bytes)
                pull.left=len(queue)+inflight
            }
            if nodes[x.address] {fetch_children(s,x.address,buffer,&queue)}
        }
        if pull!=nil {agent_pull_set(p.agent,pull^)}
    }
    return !lacked
}

// Queues the children of the node at address that s lacks.
@(private)
fetch_children :: proc(s:^store.Store,address:store.Hash,buffer:[]u8,queue:^[dynamic]$W) {
    bytes,e:=store.chunk_read(s,address,buffer)
    if e!=.None {return}
    n,pe:=store.node_parse(bytes)
    if pe!=.None {return}
    for entry in n.entries {
        if n.level>0 {
            append(queue,W{entry.address,true})
        } else if !store.chunk_here(s,entry.address) {
            append(queue,W{entry.address,false})
        }
    }
}

// --- Joining ---

// Joins the org of an invite: dials its addresses until the inviting device
// (or the org's server for an offline invite) answers, proves the invite and
// waits until this machine holds the org's record (and admission, if offline)
// that lists it.
agent_join :: proc(a:^Agent,text:string) -> (org:Org_Id,error:Error) {
    token,e:=invite_parse(text,context.temp_allocator)
    if e!=.None {return {},team_fail(&a.team,e,"that is no Kai invite: copy all of it, it begins with kai2")}
    if a.team.name=="" {return {},team_fail(&a.team,.Invalid_Argument,"name yourself and this machine first")}
    p:^Peer
    for address in token.addresses {
        p,e=agent_dial(a,address,token.key,token.secret)
        if e==.None {break}
    }
    if p==nil {
        if e==.Unauthorized {return {},team_fail(&a.team,e,"the machine at the invite's address is not the one that invited: ask for a new invite")}
        return {},team_fail(&a.team,.Unreachable,fmt.tprintf("Could not reach %s. Make sure the inviter has Mirai open and is reachable from your network.",len(token.addresses)>0?token.addresses[0]:"the inviting machine"))
    }
    defer peer_unpin(a,p)
    claim:=Invite_Claim{
        org=token.org,secret=token.secret,key=a.team.identity.key,
        name=a.team.name,device=a.team.device,public=a.options.public,
    }
    claim_bytes,ce:=invite_claim_encode(&claim,&a.team.identity,context.temp_allocator)
    if ce!=.None {return {},team_fail(&a.team,ce,"could not sign the invite claim")}
    body:=make([dynamic]u8,context.temp_allocator)
    o:=token.org
    append(&body,..o[:])
    write_text(&body,a.team.name)
    write_text(&body,a.team.device)
    write_text(&body,a.options.public)
    clen:=u16(len(claim_bytes))
    append(&body,u8(clen),u8(clen>>8))
    append(&body,..claim_bytes)
    for {
        sync.mutex_lock(&p.lock)
        ready,done:=p.ready,p.done
        sync.mutex_unlock(&p.lock)
        if ready || done {break}
        time.sleep(10*time.Millisecond)
    }
    if !conn_send(p.conn,.Join,body[:]) {return {},team_fail(&a.team,.Unreachable,"the inviting machine closed the connection")}
    welcome,welcome_admission:store.Hash
    sync.mutex_lock(&p.lock)
    started:=time.tick_now()
    for p.welcome=={} && !p.done && time.tick_since(started)<30*time.Second {sync.cond_wait_with_timeout(&p.cond,&p.lock,time.Second)}
    welcome,welcome_admission=p.welcome,p.welcome_admission
    sync.mutex_unlock(&p.lock)
    if welcome=={} {return {},team_fail(&a.team,.Expired,"the inviting machine refused the invite: it is used or past its time, ask for a new one")}
    if _,pe:=agent_org_pull(a,p,token.org,welcome,true);pe!=.None {return {},team_fail(&a.team,pe,"the org's record from the inviting machine does not hold: ask for a new invite")}
    if welcome_admission!={} {
        s,se:=team_store(&a.team,token.org)
        if se!=.None || !peer_fetch(p,token.org,s,{welcome_admission},nil) {return {},team_fail(&a.team,.Missing,"the admission from the server did not arrive: ask for a new invite")}
        raw_org,_,oe:=org_head(s,token.org,context.temp_allocator)
        if oe!=.None {return {},team_fail(&a.team,oe,"the org's record does not read")}
        if _,ae:=admission_accept(s,&raw_org,welcome_admission);ae!=.None {return {},team_fail(&a.team,ae,"the admission from the server does not verify: ask for a new invite")}
        store.commit(s)
    }
    if _,member:=agent_role(a,token.org,a.team.identity.key);!member {return {},team_fail(&a.team,.Unauthorized,"the org's record does not list this machine: ask for a new invite")}
    if p.dialed!="" {team_peer_seen(&a.team,token.key,p.dialed)}
    agent_event(a,"joined the org through %s",peer_text(p))
    agent_changed(a)
    return token.org,.None
}

// The inviting end (admin online, or org server redeeming a 1-use grant):
// takes an invite the peer proved and admits it.
@(private)
agent_admit :: proc(a:^Agent,p:^Peer,org:Org_Id,name,device,public:string,claim_bytes:[]u8) -> bool {
    // What the joining end names itself is checked before the invite is spent.
    if !name_valid(name) || !name_valid(device) || len(public)>255 {
        conn_send(p.conn,.Bye,transmute([]u8)string("name yourself and this machine with 1 to 64 bytes of UTF-8 without control characters"))
        return false
    }
    sync.mutex_lock(&p.lock)
    port:=p.port
    sync.mutex_unlock(&p.lock)
    admission_addr:store.Hash
    sync.mutex_lock(&a.lock)
    role,invited,e:=team_invite_take(&a.team,org,p.conn.proof,p.conn.proved)
    if e==.None {
        address:=public
        // A server that names no address is reached where it dialed from, at the port it listens on.
        if address=="" && role==.Node && port>0 {address=fmt.tprintf("%s:%d",net.address_to_string(p.remote.address,context.temp_allocator),port)}
        member:=Member{key=p.conn.peer,role=role,name=invited!=""?invited:name,device=device,address=address}
        e=team_member_set(&a.team,org,member)
    } else if a.options.node && len(claim_bytes)>0 {
        claim,ce:=invite_claim_decode(claim_bytes)
        if ce==.None && claim.org==org && claim.key==p.conn.peer && claim.name==name && claim.device==device && claim.public==public && handshake_invited(p.conn.proof,p.conn.proved,claim.secret) {
            if s,se:=team_store(&a.team,org);se==.None {
                if raw_org,_,oe:=org_head(s,org,context.temp_allocator);oe==.None {
                    if grant_bytes,ge:=grant_take(s,&raw_org,claim.secret,time.now()._nsec,context.temp_allocator);ge==.None {
                        if ad_bytes,ae:=admission_encode(grant_bytes,claim_bytes,context.temp_allocator);ae==.None {
                            if ad_addr,pe:=object_put(s,.Admission,ad_bytes);pe==.None {
                                if _,ace:=admission_accept(s,&raw_org,ad_addr);ace==.None {
                                    store.commit(s)
                                    admission_addr=ad_addr
                                    e=.None
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    crypto.zero_explicit(&p.conn.proof,64)
    sync.mutex_unlock(&a.lock)
    if e!=.None {
        conn_send(p.conn,.Bye,transmute([]u8)string("the invite is used or past its time: ask for a new one"))
        return false
    }
    if port>0 {
        host:=net.address_to_string(p.remote.address,context.temp_allocator)
        team_peer_seen(&a.team,p.conn.peer,fmt.tprintf("%s:%d",host,port))
    }
    _,address,_:=team_org(&a.team,org)
    body:=make([dynamic]u8,context.temp_allocator)
    o:=org
    append(&body,..o[:])
    append(&body,..address[:])
    append(&body,..admission_addr[:])
    if !conn_send(p.conn,.Welcome,body[:]) {return false}
    heads:=make([dynamic]Tell_Entry,context.temp_allocator)
    agent_heads(a,p.conn.peer,&heads)
    agent_event(a,"%s (%s) joined",device,name)
    agent_changed(a)
    return peer_tell(p,heads[:])
}

// Attaches an org to a central Kai server at address (zero-SSH registration):
// learns the server's key and public address, adds it as .Node in the org
// record, pushes the org chain and starts syncing immediately.
agent_server_attach :: proc(a:^Agent,org:Org_Id,address:string) -> Error {
    if address=="" || len(address)>ADDRESS_MAX {return team_fail(&a.team,.Invalid_Argument,"give the server's host:port")}
    {
        sync.mutex_lock(&a.lock)
        defer sync.mutex_unlock(&a.lock)
        o,_,oe:=team_org(&a.team,org)
        if oe!=.None {return oe}
        if role,ok:=org_role(&o,a.team.identity.key);!ok || role!=.Admin {
            return team_fail(&a.team,.Unauthorized,"only an admin of the org attaches a server")
        }
    }
    c,e:=conn_dial(address,a.team.identity,{},{},&a.stopping)
    if e!=.None {return team_fail(&a.team,e,"no Kai server answered at that address")}
    defer conn_free(c)
    net.set_option(c.socket,.Receive_Timeout,WEB_LOGIN_SECONDS*time.Second)
    if !conn_send(c,.Server_Info) {return team_fail(&a.team,.Unreachable,"the server closed the connection")}
    buffer,be:=make([]u8,FRAME_MAX+NOISE_TAG)
    if be!=nil {return .Out_Of_Memory}
    defer delete(buffer)
    kind,reply,ok:=conn_receive(c,buffer)
    if !ok {return team_fail(&a.team,.Unreachable,"the server closed the connection")}
    if kind==.Bye {return team_fail(&a.team,.Unauthorized,strings.clone(string(reply),context.temp_allocator))}
    if kind!=.Server_Info {return team_fail(&a.team,.Corrupt,"unexpected answer from the server")}
    r:=Reader{data=reply}
    srv_name:=strings.clone(tail_string(&r),context.temp_allocator)
    srv_device:=strings.clone(tail_string(&r),context.temp_allocator)
    srv_public:=strings.clone(tail_string(&r),context.temp_allocator)
    if r.short || !name_valid(srv_name) || !name_valid(srv_device) {return team_fail(&a.team,.Corrupt,"the server's identity is invalid")}
    server_addr:=srv_public!=""?srv_public:address
    if len(server_addr)>ADDRESS_MAX {return team_fail(&a.team,.Corrupt,"the server's public address is too long")}

    chain:=make([dynamic][]u8,context.temp_allocator)
    next_bytes:[]u8
    {
        sync.mutex_lock(&a.lock)
        defer sync.mutex_unlock(&a.lock)
        s,se:=team_store(&a.team,org)
        if se!=.None {return se}
        held,held_addr,he:=org_head(s,org,context.temp_allocator)
        if he!=.None {return he}
        if role,member:=org_role(&held,a.team.identity.key);!member || role!=.Admin {
            return team_fail(&a.team,.Unauthorized,"only an admin of the org attaches a server")
        }
        rev:=make([dynamic][]u8,context.temp_allocator)
        for x:=held_addr;x!={}; {
            b,ge:=object_get(s,x,.Org,context.temp_allocator)
            if ge!=.None {return ge}
            rec,de:=org_decode(b,context.temp_allocator)
            if de!=.None {return de}
            append(&rev,b)
            x=rec.prev
        }
        for k:=len(rev)-1;k>=0;k-=1 {append(&chain,rev[k])}
        already:=false
        if i:=org_member(&held,c.peer);i>=0 && held.members[i].role==.Node && held.members[i].address==server_addr {already=true}
        if !already {
            eff,_:=org_effective(s,&held,context.temp_allocator)
            members:=make([dynamic]Member,0,len(eff.members)+1,context.temp_allocator)
            append(&members,..eff.members)
            replaced:=false
            node:=Member{key=c.peer,role=.Node,name=srv_name,device=srv_device,address=server_addr}
            for &m in members {
                if m.key==c.peer {
                    m=node
                    replaced=true
                    break
                }
            }
            if !replaced {
                if len(members)>=MEMBERS_MAX {return team_fail(&a.team,.Too_Large,"the org has as many members as it may")}
                append(&members,node)
            }
            slice.sort_by(members[:],proc(a,b:Member) -> bool {return key_less(a.key,b.key)})
            next:=held
            next.version,next.prev,next.signer,next.time,next.members=held.version+1,held_addr,a.team.identity.key,time.now()._nsec,members[:]
            ne:Error
            next_bytes,ne=org_encode(&next,&a.team.identity,context.temp_allocator)
            if ne!=.None {return ne}
            append(&chain,next_bytes)
        }
    }
    body:=make([dynamic]u8,context.temp_allocator)
    o:=org
    append(&body,..o[:])
    count:=u16(len(chain))
    append(&body,u8(count),u8(count>>8))
    for b in chain {
        n:=u32(len(b))
        append(&body,u8(n),u8(n>>8),u8(n>>16),u8(n>>24))
        append(&body,..b)
    }
    if len(body)>FRAME_MAX-1 {return team_fail(&a.team,.Too_Large,"the org history is larger than one registration frame")}
    if !conn_send(c,.Org_Register,body[:]) {return team_fail(&a.team,.Unreachable,"the server closed the connection")}
    kind,reply,ok=conn_receive(c,buffer)
    if !ok {return team_fail(&a.team,.Unreachable,"the server closed the connection")}
    if kind==.Bye {return team_fail(&a.team,.Unauthorized,strings.clone(string(reply),context.temp_allocator))}
    if kind!=.Welcome {return team_fail(&a.team,.Corrupt,"unexpected answer from the server")}
    {
        sync.mutex_lock(&a.lock)
        defer sync.mutex_unlock(&a.lock)
        if next_bytes!=nil {
            if s,se:=team_store(&a.team,org);se==.None {
                if addr,pe:=object_put(s,.Org,next_bytes);pe==.None {
                    org_accept(s,org,addr)
                    store.commit(s)
                }
            }
        }
        team_peer_seen(&a.team,c.peer,server_addr)
    }
    agent_event(a,"attached server %s",server_addr)
    agent_sync_now(a)
    return .None
}

// Opens a 1-use invite to org. When org has a server (.Node with an address)
// and it accepts an admin-signed Invite_Grant, the token targets the server so
// the invitee joins even while this machine is off (via_server = true).
// Otherwise falls back to a local invite on fallback_addresses.
agent_invite :: proc(a:^Agent,org:Org_Id,role:Role,name:string,fallback_addresses:[]string,allocator:=context.allocator) -> (text:string,via_server:bool,error:Error) {
    o,_,oe:=team_org(&a.team,org)
    if oe!=.None {return "",false,oe}
    if r,ok:=org_role(&o,a.team.identity.key);!ok || r!=.Admin {
        return "",false,team_fail(&a.team,.Unauthorized,"only an admin of the org invites: ask one")
    }
    if name!="" && !name_valid(name) {
        return "",false,team_fail(&a.team,.Invalid_Argument,"a name has 1 to 64 bytes of UTF-8 without control characters")
    }
    if server_key,server_addr,has_server:=org_server(&o);has_server {
        secret:[32]u8
        crypto.rand_bytes(secret[:])
        defer crypto.zero_explicit(&secret,32)
        grant:=Invite_Grant{
            org=org,secret_hash=secret_digest(secret),role=role,
            revoke_epoch=o.revoke_epoch,
            expires=time.now()._nsec+i64(INVITE_HOURS)*i64(time.Hour),
            signer=a.team.identity.key,name=name,
        }
        if grant_bytes,ge:=invite_grant_encode(&grant,&a.team.identity,context.temp_allocator);ge==.None {
            if c,de:=conn_dial(server_addr,a.team.identity,server_key,{},&a.stopping);de==.None {
                defer conn_free(c)
                net.set_option(c.socket,.Receive_Timeout,WEB_LOGIN_SECONDS*time.Second)
                if conn_send(c,.Invite_Grant,grant_bytes) {
                    if buffer,be:=make([]u8,FRAME_MAX+NOISE_TAG);be==nil {
                        defer delete(buffer)
                        if kind,reply,ok:=conn_receive(c,buffer);ok && kind==.Bye && string(reply)=="ok" {
                            addrs:=[1]string{server_addr}
                            token:=Invite_Token{org=org,key=server_key,secret=secret,addresses=addrs[:]}
                            made,te:=invite_text(&token,allocator)
                            return made,te==.None,te
                        }
                    }
                }
            }
        }
    }
    made,te:=team_invite(&a.team,org,role,name,fallback_addresses,allocator)
    return made,false,te
}

// Revokes every open invite of org: removes local invites, bumps revoke_epoch
// on the org record and notifies the org's server to drop pending grants.
agent_invites_revoke :: proc(a:^Agent,org:Org_Id) -> (cleared:int,error:Error) {
    sync.mutex_lock(&a.lock)
    cleared,error=team_invites_clear(&a.team,org)
    sync.mutex_unlock(&a.lock)
    if error!=.None {return}
    agent_changed(a)
    o,_,oe:=team_org(&a.team,org)
    if oe!=.None {return}
    server_key,server_addr,has_server:=org_server(&o)
    if !has_server {return}
    c,de:=conn_dial(server_addr,a.team.identity,server_key,{},&a.stopping)
    if de!=.None {return}
    defer conn_free(c)
    net.set_option(c.socket,.Receive_Timeout,WEB_LOGIN_SECONDS*time.Second)
    body:[size_of(Org_Id)+8]u8
    id:=org
    copy(body[:],id[:])
    epoch:=u64le(o.revoke_epoch)
    ep:=transmute([8]u8)epoch
    copy(body[size_of(Org_Id):],ep[:])
    if !conn_send(c,.Invite_Revoke,body[:]) {return}
    if buffer,be:=make([]u8,FRAME_MAX+NOISE_TAG);be==nil {
        defer delete(buffer)
        conn_receive(c,buffer)
    }
    return cleared,.None
}

@(private)
agent_serve_server_info :: proc(a:^Agent,c:^Conn,buffer:[]u8) {
    if !a.options.node || a.options.max_orgs<=0 {
        conn_send(c,.Bye,transmute([]u8)string("this Kai agent does not host orgs"))
        return
    }
    body:=make([dynamic]u8,context.temp_allocator)
    write_text(&body,a.team.name)
    write_text(&body,a.team.device)
    write_text(&body,a.options.public)
    if !conn_send(c,.Server_Info,body[:]) {return}
    net.set_option(c.socket,.Receive_Timeout,WEB_LOGIN_SECONDS*time.Second)
    kind,next_body,ok:=conn_receive(c,buffer)
    if ok && kind==.Org_Register {agent_handle_org_register(a,c,next_body)}
}

@(private)
agent_handle_org_register :: proc(a:^Agent,c:^Conn,body:[]u8) {
    if !a.options.node || a.options.max_orgs<=0 {
        conn_send(c,.Bye,transmute([]u8)string("this Kai agent does not host orgs"))
        return
    }
    r:=Reader{data=body}
    org:=read_value(&r,Org_Id)
    count:=int(read_value(&r,u16le))
    if r.short || org=={} || count==0 || count>ORG_CHAIN_MAX {
        conn_send(c,.Bye,transmute([]u8)string("invalid org registration"))
        return
    }
    raws:=make([dynamic][]u8,0,count,context.temp_allocator)
    recs:=make([dynamic]Org,0,count,context.temp_allocator)
    for k in 0..<count {
        n:=int(read_value(&r,u32le))
        rec_bytes:=read_bytes(&r,n)
        if r.short || len(rec_bytes)==0 {
            conn_send(c,.Bye,transmute([]u8)string("invalid org record chain"))
            return
        }
        rec,de:=org_decode(rec_bytes,context.temp_allocator)
        if de!=.None || rec.id!=org {
            conn_send(c,.Bye,transmute([]u8)string("corrupt org record in chain"))
            return
        }
        if !org_signs(k==0?nil:&recs[k-1],&rec) {
            conn_send(c,.Bye,transmute([]u8)string("org record signatures do not hold"))
            return
        }
        append(&raws,rec_bytes)
        append(&recs,rec)
    }
    if r.at!=len(body) {
        conn_send(c,.Bye,transmute([]u8)string("trailing bytes in org registration"))
        return
    }
    newest:=&recs[count-1]
    caller_role,caller_ok:=org_role(newest,c.peer)
    self_role,self_ok:=org_role(newest,a.team.identity.key)
    if !caller_ok || caller_role!=.Admin || !self_ok || self_role!=.Node {
        conn_send(c,.Bye,transmute([]u8)string("an org admin must list this server as a node to register"))
        return
    }
    head_addr:store.Hash
    sync.mutex_lock(&a.lock)
    s0,existing_err:=team_store(&a.team,org,false)
    created_store:=existing_err!=.None
    existing:=false
    if !created_store {
        _,_,he0:=org_head(s0,org,context.temp_allocator)
        existing=he0==.None
    }
    if !existing && len(team_org_ids(&a.team))>=a.options.max_orgs {
        sync.mutex_unlock(&a.lock)
        conn_send(c,.Bye,transmute([]u8)string("this server hosts as many orgs as it allows"))
        return
    }
    s,se:=team_store(&a.team,org,true)
    if se!=.None {
        sync.mutex_unlock(&a.lock)
        conn_send(c,.Bye,transmute([]u8)string("the server could not open the org store"))
        return
    }
    accept_err:Error
    for rec_bytes in raws {
        head_addr,accept_err=object_put(s,.Org,rec_bytes)
        if accept_err!=.None {break}
    }
    if accept_err==.None {_,_,accept_err=org_accept(s,org,head_addr)}
    if accept_err!=.None {
        if created_store {tenants_remove(a.team.tenants,org)}
        sync.mutex_unlock(&a.lock)
        conn_send(c,.Bye,transmute([]u8)string("the org record chain does not hold"))
        return
    }
    store.commit(s)
    sync.mutex_unlock(&a.lock)
    welcome:=make([dynamic]u8,context.temp_allocator)
    o:=org
    zero_hash:store.Hash
    append(&welcome,..o[:])
    append(&welcome,..head_addr[:])
    append(&welcome,..zero_hash[:])
    conn_send(c,.Welcome,welcome[:])
    agent_event(a,"registered org %s",newest.name)
    agent_changed(a)
}

@(private)
agent_handle_invite_grant :: proc(a:^Agent,c:^Conn,body:[]u8) {
    if !a.options.node {
        conn_send(c,.Bye,transmute([]u8)string("this agent does not hold offline invites"))
        return
    }
    grant,ge:=invite_grant_decode(body)
    if ge!=.None || grant.signer!=c.peer {
        conn_send(c,.Bye,transmute([]u8)string("invalid invite grant"))
        return
    }
    sync.mutex_lock(&a.lock)
    e:Error=.Missing
    if s,se:=team_store(&a.team,grant.org);se==.None {
        if o,_,oe:=org_head(s,grant.org,context.temp_allocator);oe==.None {
            e=grant_put(s,&o,body,time.now()._nsec)
            if e==.None {store.commit(s)}
        }
    }
    sync.mutex_unlock(&a.lock)
    conn_send(c,.Bye,transmute([]u8)string(e==.None?"ok":"the server refused the invite grant"))
}

@(private)
agent_handle_invite_revoke :: proc(a:^Agent,c:^Conn,body:[]u8) {
    if !a.options.node {
        conn_send(c,.Bye,transmute([]u8)string("this agent does not hold offline invites"))
        return
    }
    r:=Reader{data=body}
    org:=read_value(&r,Org_Id)
    epoch:=u64(read_value(&r,u64le))
    if r.short || r.at!=len(body) {
        conn_send(c,.Bye,transmute([]u8)string("invalid invite revoke"))
        return
    }
    sync.mutex_lock(&a.lock)
    ok:=false
    if s,se:=team_store(&a.team,org);se==.None {
        if o,_,oe:=org_head(s,org,context.temp_allocator);oe==.None {
            if role,member:=org_role(&o,c.peer);member && role==.Admin {
                grants_revoke(s,org,epoch)
                store.commit(s)
                ok=true
            }
        }
    }
    sync.mutex_unlock(&a.lock)
    conn_send(c,.Bye,transmute([]u8)string(ok?"ok":"only an admin revokes invites"))
}

// Sets the web sign-in of this device on the server at address: a server of
// one of its orgs, which must prove its key, so the password reaches no other
// machine. The server is the one whose address is that, else the one server
// its orgs list.
agent_web_login :: proc(a:^Agent,address,name,password:string) -> Error {
    matched,only:Key
    servers:=0 // distinct servers its orgs list, counted to two
    for id in team_org_ids(&a.team) {
        o,_,oe:=team_org(&a.team,id)
        if oe!=.None {continue}
        for m in o.members {
            if m.role!=.Node {continue}
            if m.address!="" && m.address==address {matched=m.key}
            if servers==0 {only,servers=m.key,1} else if m.key!=only {servers=2}
        }
    }
    expect:=matched!={}?matched:only
    if matched=={} && servers!=1 {return team_fail(&a.team,.Invalid_Argument,"no single server of your orgs is at that address: give the address your org lists for its server")}
    c,e:=conn_dial(address,a.team.identity,expect,{},&a.stopping)
    if e==.Unauthorized {return team_fail(&a.team,e,"the machine at that address is not your org's server")}
    if e!=.None {return team_fail(&a.team,e,"no Kai server answered at that address")}
    defer conn_free(c)
    net.set_option(c.socket,.Receive_Timeout,WEB_LOGIN_SECONDS*time.Second)
    body:=make([dynamic]u8,context.temp_allocator)
    write_text(&body,name)
    write_text(&body,password)
    if !conn_send(c,.Web_Login,body[:]) {return .Unreachable}
    buffer,be:=make([]u8,FRAME_MAX+NOISE_TAG)
    if be!=nil {return .Out_Of_Memory}
    defer delete(buffer)
    for {
        kind,reply,ok:=conn_receive(c,buffer)
        if !ok {return team_fail(&a.team,.Unreachable,"the server closed the connection")}
        if kind!=.Bye {continue}
        if string(reply)!="web sign-in set" {return team_fail(&a.team,.Unauthorized,strings.clone(string(reply),context.temp_allocator))}
        return .None
    }
}

// --- Derived data ---

// Asks the connected members of org for the derived data set of key and
// fetches it whole from the first that holds one; found when it is here.
agent_ddc_ask :: proc(a:^Agent,org:Org_Id,key:store.Hash,timeout:=5*time.Second) -> (found:bool) {
    w,we:=new(Ddc_Wait)
    if we!=nil {return false}
    defer free(w)
    w.org,w.key=org,key
    sync.mutex_lock(&a.lock)
    append(&a.waits,w)
    asked:=0
    body:=make([dynamic]u8,context.temp_allocator)
    o,k:=org,key
    append(&body,..o[:])
    append(&body,..k[:])
    sync.mutex_unlock(&a.lock)
    peers:=peers_live(a)
    for p in peers {
        if conn_send(p.conn,.Ddc_Ask,body[:]) {asked+=1}
    }
    peers_unpin(a,peers)
    sync.mutex_lock(&a.lock)
    started:=time.tick_now()
    for asked>0 && w.found=={} && w.answers<asked && time.tick_since(started)<timeout {sync.cond_wait_with_timeout(&a.wake,&a.lock,100*time.Millisecond)}
    for x,i in a.waits {
        if x==w {
            unordered_remove(&a.waits,i)
            break
        }
    }
    from,address:=w.from,w.found
    sync.mutex_unlock(&a.lock)
    if from==nil {return false}
    defer peer_unpin(a,from)
    s,se:=team_store(&a.team,org)
    if se!=.None {return false}
    held,_,oe:=org_effective_head(s,org,context.temp_allocator)
    if oe!=.None {return false}
    found,_=peer_ddc_take(from,&held,s,key,address)
    return
}

// Tells the connected nodes of org that this machine published the derived
// data set of key, so they keep it.
agent_ddc_published :: proc(a:^Agent,org:Org_Id,key:store.Hash,address:store.Hash) {
    entry:=Tell_Entry{kind=.Ddc,org=org,id=key,address=address}
    peers:=peers_live(a)
    defer peers_unpin(a,peers)
    for p in peers {
        if role,ok:=agent_role(a,org,p.conn.peer);ok && role==.Node {peer_tell(p,{entry})}
    }
}

// --- Looking, dialing, reaping ---

@(private)
agent_look_run :: proc(a:^Agent) {
    defer thread_end()
    last_dial:i64
    mapped:=wire.Port_Mapping_Phase.Pending
    for {
        free_all(context.temp_allocator)
        sync.mutex_lock(&a.lock)
        if !a.stopping && !a.changed && !a.redial {sync.cond_wait_with_timeout(&a.wake,&a.lock,LOOK_SECONDS*time.Second)}
        if a.stopping {
            sync.mutex_unlock(&a.lock)
            return
        }
        changed,redial:=a.changed,a.redial
        a.changed,a.redial=false,false
        // Reap the peers whose reader ended and that no caller holds.
        dead:=make([dynamic]^Peer,context.temp_allocator)
        for k:=0;k<len(a.peers); {
            p:=a.peers[k]
            sync.mutex_lock(&p.lock)
            done:=p.done
            sync.mutex_unlock(&p.lock)
            if done && p.refs==0 {
                append(&dead,p)
                unordered_remove(&a.peers,k)
            } else {
                k+=1
            }
        }
        sync.mutex_unlock(&a.lock)
        for p in dead {
            peer_end(p)
            peer_free(p)
        }
        agent_tell_changes(a)
        // The router's answer changes what an invite carries.
        if a.mapping_on {
            if phase:=wire.mapping_poll(&a.mapping).phase;phase!=mapped {
                mapped=phase
                agent_moved(a)
            }
        }
        now:=time.now()._nsec
        if redial || now-last_dial>=REDIAL_SECONDS*i64(time.Second) {
            last_dial=now
            agent_dial_members(a)
        } else if changed {
            agent_dial_members(a)
        }
    }
}

// Tells each peer the heads that moved since it was told last.
@(private)
agent_tell_changes :: proc(a:^Agent) {
    heads:=make([dynamic]Tell_Entry,context.temp_allocator)
    agent_heads(a,{},&heads)
    moved:=make([dynamic]Tell_Entry,context.temp_allocator)
    sync.mutex_lock(&a.lock)
    for h in heads {
        k:=Tell_Key{h.kind,h.org,h.id}
        if held,ok:=a.told[k];ok && held==h.address {continue}
        a.told[k]=h.address
        append(&moved,h)
    }
    sync.mutex_unlock(&a.lock)
    if len(moved)==0 {return}
    agent_moved(a)
    peers:=peers_live(a)
    defer peers_unpin(a,peers)
    for p in peers {
        theirs:=make([dynamic]Tell_Entry,context.temp_allocator)
        for m in moved {
            // Derived data goes to the org's servers alone: a member asks for what it needs.
            if role,ok:=agent_role(a,m.org,p.conn.peer);ok && (m.kind!=.Ddc || role==.Node) {append(&theirs,m)}
        }
        if len(theirs)>0 {peer_tell(p,theirs[:])}
    }
}

// Dials every member of its orgs that is not connected, at the addresses it
// was reached at or its beacon said, and the peers the options name: one
// thread per member tries its addresses in turn, at most once every
// REDIAL_SECONDS; a peer of the options goes by its address.
@(private)
agent_dial_members :: proc(a:^Agent) {
    Target :: struct {
        expect:Key,   // the key it must prove: zero for a peer of the options
        throttle:Key, // what a.dialing keeps it under
        address:string,
    }
    targets:=make([dynamic]Target,context.temp_allocator)
    own:=a.team.identity.key
    for id in team_org_ids(&a.team) {
        o,_,e:=team_org(&a.team,id)
        if e!=.None {continue}
        for m in o.members {
            if m.key==own {continue}
            if m.address!="" {append(&targets,Target{m.key,m.key,strings.clone(m.address,context.temp_allocator)})}
            for address in team_peer_addresses(&a.team,m.key) {append(&targets,Target{m.key,m.key,address})}
            sync.mutex_lock(&a.lock)
            if b,ok:=a.beacons[m.key];ok {append(&targets,Target{m.key,m.key,strings.clone(b,context.temp_allocator)})}
            sync.mutex_unlock(&a.lock)
        }
    }
    for address in a.options.peers {append(&targets,Target{{},options_key(address),address})}
    Dial :: struct {
        a:^Agent,
        expect:Key,
        addresses:[DIAL_ADDRESSES][ADDRESS_MAX]u8,
        lengths:[DIAL_ADDRESSES]int,
        count:int,
    }
    Group :: struct {throttle:Key,dial:Dial,skip:bool}
    groups:=make([dynamic]Group,context.temp_allocator)
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    if a.stopping {return}
    now:=time.now()._nsec
    next: for t in targets {
        if len(t.address)>ADDRESS_MAX {continue}
        for &g in groups {
            if g.throttle!=t.throttle {continue}
            if !g.skip && g.dial.count<DIAL_ADDRESSES {
                g.dial.lengths[g.dial.count]=copy(g.dial.addresses[g.dial.count][:],t.address)
                g.dial.count+=1
            }
            continue next
        }
        connected:=false
        for p in a.peers {
            sync.mutex_lock(&p.lock)
            connected||=!p.done && (t.expect=={}?p.dialed==t.address:p.conn!=nil && p.conn.peer==t.expect)
            sync.mutex_unlock(&p.lock)
        }
        at,dialing:=a.dialing[t.throttle]
        g:=Group{throttle=t.throttle,skip=connected || dialing && now-at<REDIAL_SECONDS*i64(time.Second)}
        g.dial.a,g.dial.expect=a,t.expect
        g.dial.lengths[0]=copy(g.dial.addresses[0][:],t.address)
        g.dial.count=1
        append(&groups,g)
    }
    for g in groups {
        if g.skip {continue}
        d,de:=new(Dial,a.allocator)
        if de!=nil {continue}
        d^=g.dial
        a.dialing[g.throttle]=now
        a.dials+=1
        th:=thread.create_and_start_with_poly_data(d,proc(d:^Dial) {
            defer thread_end()
            a:=d.a
            for k in 0..<d.count {
                if sync.atomic_load(&a.stopping) {break}
                if p,e:=agent_dial(a,string(d.addresses[k][:d.lengths[k]]),d.expect);e==.None {
                    peer_unpin(a,p)
                    break
                }
            }
            free(d,a.allocator)
            sync.mutex_lock(&a.lock)
            a.dials-=1
            sync.cond_broadcast(&a.wake)
            sync.mutex_unlock(&a.lock)
        },agent_context(a),self_cleanup=true)
        if th==nil {
            a.dials-=1
            free(d,a.allocator)
        }
    }
}

// The key a peer of the options is throttled under, dialed by its address:
// no member's key.
@(private)
options_key :: proc(address:string) -> (key:Key) {
    digest:[32]u8
    hash.hash_string_to_buffer(.SHA256,address,digest[:])
    copy(key[:],digest[:])
    return
}

// --- Beacon ---

// Says every BEACON_SECONDS on the broadcast of each IPv4 network where this
// agent listens, and keeps where the members' beacons say they do. Who a
// beacon names proves itself in the handshake, so a beacon proves nothing.
@(private)
agent_beacon_run :: proc(a:^Agent) {
    defer thread_end()
    socket,e:=net.make_unbound_udp_socket(.IP4)
    if e!=nil {return}
    defer net.close(socket)
    socket_share_port(socket)
    net.set_option(socket,.Broadcast,true)
    net.set_option(socket,.Receive_Timeout,time.Second)
    if net.bind(socket,{net.IP4_Any,KAI_PORT})!=nil {return}
    said:i64
    message:[len(BEACON_MAGIC)+size_of(Key)+2]u8
    copy(message[:],BEACON_MAGIC)
    own:=a.team.identity.key
    copy(message[len(BEACON_MAGIC):],own[:])
    message[len(message)-2],message[len(message)-1]=u8(a.port),u8(a.port>>8)
    buffer:[64]u8
    for {
        free_all(context.temp_allocator)
        if sync.atomic_load(&a.stopping) {return}
        if now:=time.now()._nsec;now-said>=BEACON_SECONDS*i64(time.Second) {
            said=now
            broadcasts:=make([dynamic][4]u8,context.temp_allocator)
            broadcasts4(&broadcasts)
            for b in broadcasts {net.send_udp(socket,message[:],{net.IP4_Address(b),KAI_PORT})}
        }
        n,from,re:=net.recv_udp(socket,buffer[:])
        if re!=nil || n!=len(message) || string(buffer[:len(BEACON_MAGIC)])!=BEACON_MAGIC {continue}
        key:Key
        copy(key[:],buffer[len(BEACON_MAGIC):])
        port:=int(buffer[n-2])|int(buffer[n-1])<<8
        if key==own || port==0 || !agent_knows(a,key) {continue}
        address:=fmt.tprintf("%s:%d",net.address_to_string(from.address,context.temp_allocator),port)
        sync.mutex_lock(&a.lock)
        if held,ok:=a.beacons[key];!ok || held!=address {
            if copied,ce:=strings.clone(address,a.allocator);ce==nil {
                if ok {delete(held,a.allocator)}
                a.beacons[key]=copied
            }
            a.changed=true
            delete_key(&a.dialing,key)
            sync.cond_broadcast(&a.wake)
        }
        sync.mutex_unlock(&a.lock)
    }
}

// Adds the broadcast address of the network of ip under mask, once.
@(private)
broadcast4_add :: proc(out:^[dynamic][4]u8,ip:[4]u8,mask:u32be) {
    if ip[0]==127 || mask==0 {return}
    b:=transmute([4]u8)(transmute(u32be)ip | ~mask)
    for x in out {if x==b {return}}
    append(out,b)
}
