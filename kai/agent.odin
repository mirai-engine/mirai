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
HEARD_MAX :: 1024   // members whose addresses peers told of that the agent keeps

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

// How far a repository's pull is, from every peer it comes from.
Pull :: struct {
    org:Org_Id,
    repo:Repo_Id,
    chunks:int,  // arrived since the agent started
    left:int,    // asked or found and not here yet
    bytes:i64,   // arrived since the agent started
    whole:bool,  // every chunk of every object its shared bookmarks reach is here
}

Peer_Info :: struct {
    key:Key,
    name,device:string, // as it says, in the caller's allocator
    address:string,     // host:port
    dialed:bool,
}

Agent :: struct {
    team:Team, // its own copy: strings owned by its allocator; its why stays "", a call says why to its caller
    options:Agent_Options,
    lock:sync.Mutex,
    wake:sync.Cond,
    stopping:bool, // atomic, set once under lock: every thread ends and no dial or peer begins
    listener:net.TCP_Socket,
    listening:bool,
    listen_host:net.IP4_Address, // what the listener is bound to
    port:int,
    threads:[dynamic]^thread.Thread,
    peers:[dynamic]^Peer,
    dialing:map[Key]Dial_Entry, // each key dialed (or, for a peer of the options, its address): agent_stop waits for the running ones
    beacons:map[Key]string,  // where each member's beacon said it listens
    told:map[Tell_Key]store.Hash, // the heads the peers were told last
    events:[dynamic]string,
    mapping:wire.Port_Mapping,
    mapping_on:bool,
    pulls:[dynamic]Pull,
    waits:[dynamic]^Ddc_Wait,
    fetches:[dynamic]^Fetch,  // every fetch running, of every peer
    claims:map[Claim]^Fetch,  // the chunk each fetch asked and has not had answered: no two fetches ask one
    heard:map[Key]Heard,      // where peers said members listen (Peers)
    loopback:bool,            // listens and dials on loopback alone (tests): other addresses peers tell are ignored
    served:int,               // chunks sent to peers, atomic
    transfers:[TRANSFERS_MAX]Transfer_Slot, // what moves with each peer (transfer.odin)
    roots:map[store.Hash]Transfer_Root,     // the heads a pull starts from, and what each is for (agent_roots)
    asked:i64,                // atomic, tick ns: when a peer last asked or was answered, or a node was told of derived data (agent_drain)
    wakes:bit_set[Agent_Wake], // what the look thread does at its next turn
    generation:u64, // one more each time what agent_peers, agent_pulls, agent_events or the heads give changes
    instance:u64,   // random, not zero, said in its Hello: tells apart two agents of one device key (an editor's and an import's)
    dialed:bool,    // under lock: the look thread began its first dial of the members (agent_org_wait)
    allocator:runtime.Allocator,
}

// Why the look thread (agent_look_run) turns before LOOK_SECONDS pass.
@(private)
Agent_Wake :: enum u8 {
    Changed, // this process wrote heads, or a peer told where a member listens: dial who is not connected
    Redial,  // dial every member now, past REDIAL_SECONDS
    Gossip,  // tell the peers again where the members listen
}

// A dial of one key: while Running no other begins; once it ends, the next
// waits REDIAL_SECONDS from when it began unless something says where the
// member listens anew (Cooling entries are dropped then).
@(private)
Dial_Entry :: struct {
    phase:enum u8 {Running,Cooling},
    began:i64, // ns
}

@(private)
Tell_Key :: struct {kind:Tell_Kind,org:Org_Id,id:store.Hash}

@(private)
Claim :: struct {s:^store.Store,address:store.Hash}

// The last DIAL_ADDRESSES addresses peers said a member listens at.
@(private)
Heard :: struct {
    at:[DIAL_ADDRESSES]Peer_At,
    count,next:int,
}

// Where a connection is. A dialed peer comes Connecting with its handshake
// held; an accepted one runs its handshake there. Each change is made under
// the peer's lock and broadcast on its cond.
@(private)
Peer_Phase :: enum u8 {
    Connecting, // the handshake runs (accepted) or held, and the Hellos cross; not yet the one connection kept to its agent
    Hello,      // kept to its agent (peer_unique): its reader starts the other two
    Live,       // its server and puller run
    Ended,      // its connection ends: its threads end and the reaper frees it
}

// Who began a connection: this end at an address, or the other end at a
// socket, which is the peer's until its handshake holds (conn_accept).
@(private)
Peer_Dialed :: struct {address:string} // owned by the agent's allocator
@(private)
Peer_Accepted :: struct {socket:net.TCP_Socket}
@(private)
Peer_Origin :: union #no_nil {Peer_Accepted,Peer_Dialed}

// What the inviting end answered a Join: the org's record and, for an offline
// invite, the admission the server signed (zero when none).
@(private)
Welcome :: struct {record,admission:store.Hash}

// What a peer's wants were last for, and when (agent_serving).
@(private)
Peer_Serving :: struct {root:Transfer_Root,at:i64} // tick ns

@(private)
Peer :: struct {
    agent:^Agent,
    conn:^Conn,             // set once by its reader, before its phase leaves Connecting
    origin:Peer_Origin,
    remote:net.Endpoint,
    lock:sync.Mutex,        // of everything below
    cond:sync.Cond,
    phase:Peer_Phase,
    name,device:[NAME_MAX]u8,
    name_len,device_len:int,
    port:int,
    instance:u64,           // of the other end's agent, from its Hello, set by its reader before it leaves Connecting
    told:map[Tell_Key]store.Hash, // what it holds
    dirty:bool,
    requests:[dynamic][]u8, // wants and asks waiting, their kind first
    requested:int,          // bytes of requests
    fetches:[dynamic]^Fetch,
    welcome:Maybe(Welcome), // a dialed join's answer
    gossiped:bool,          // a Peers message came from it
    reader,server,puller:^thread.Thread,
    refs:int,               // under the agent's lock: callers holding it, which the reaper waits for
    serving:Maybe(Peer_Serving),
}

@(private)
Fetch :: struct {
    s:^store.Store,
    org:Org_Id,
    repo:Repo_Id,                    // the repository whose pull counts what arrives; zero when none
    kind:Transfer_Kind,              // what the transfer it counts in moves
    left:int,                        // under the agent's lock: chunks it queued or asked and has not had
    pending:map[store.Hash]struct{}, // under its peer's lock: asked and not answered
    arrived:[dynamic]Arrival,        // under its peer's lock
}

@(private)
Fetch_Want :: struct {address:store.Hash,node:bool}

@(private)
Arrival :: struct {address:store.Hash,lacked:bool,bytes:int}

// An ask of derived data (agent_ddc_ask), under the agent's lock: the peers
// asked, held until it ends, and which answered. It ends at the first that
// holds the set or once every one asked answered, each once.
@(private)
Ddc_Wait :: struct {
    org:Org_Id,
    key:store.Hash,
    asked:[]^Peer,
    answered:[]bool, // of asked
    hit:Maybe(Ddc_Hit),
}

@(private)
Ddc_Hit :: struct {address:store.Hash,from:^Peer}

// Starts the agent of team's machine. The agent keeps its own copy of team;
// a failure says why in team.why.
agent_start :: proc(a:^Agent,team:^Team,options:Agent_Options,allocator:=context.allocator) -> Error {
    a^={options=options,allocator=allocator}
    a.team=team^
    a.team.why=""
    name,ne:=strings.clone(team.name,allocator)
    device,de:=strings.clone(team.device,allocator)
    a.team.name=name
    a.team.device=device
    if ne!=nil || de!=nil {
        agent_free(a)
        return .Out_Of_Memory
    }
    a.dialing=make(map[Key]Dial_Entry,allocator)
    a.beacons=make(map[Key]string,allocator)
    a.told=make(map[Tell_Key]store.Hash,allocator)
    a.peers=make([dynamic]^Peer,allocator)
    a.threads=make([dynamic]^thread.Thread,allocator)
    a.fetches=make([dynamic]^Fetch,allocator)
    a.claims=make(map[Claim]^Fetch,allocator)
    a.heard=make(map[Key]Heard,allocator)
    a.roots=make(map[store.Hash]Transfer_Root,allocator)
    for a.instance==0 {crypto.rand_bytes(slice.bytes_from_ptr(&a.instance,size_of(a.instance)))}
    if address,ok:=net.parse_ip4_address(options.host);ok {a.loopback=address[0]==127}
    if options.port>=0 {
        host:=net.IP4_Any
        if options.host!="" {
            address,ok:=net.parse_ip4_address(options.host)
            if !ok {
                agent_free(a)
                return team_fail(team,.Invalid_Argument,"the address to listen at is no IPv4 address")
            }
            host=address
        }
        // Loopback-only agents (tests) take an ephemeral port directly so they never
        // collide on macOS with a wildcard :7350 listener on another editor.
        port:=options.port==0?(host==net.IP4_Loopback?0:KAI_PORT):options.port
        socket,e:=net.listen_tcp({host,port})
        if e!=nil && options.port==0 {socket,e=net.listen_tcp({host,0})}
        if e!=nil {
            agent_free(a)
            return team_fail(team,.Io,fmt.tprintf("port %d is taken: stop the other Kai agent or choose another port",port))
        }
        socket_cloexec(socket)
        a.listener,a.listening,a.listen_host=socket,true,host
        if bound,be:=net.bound_endpoint(socket);be==nil {a.port=bound.port}
        if options.portmap {
            gateway:wire.Address
            if options.gateway!="" {
                ok:bool
                if gateway,ok=wire.address_parse(options.gateway);!ok {
                    net.close(socket)
                    agent_free(a)
                    return team_fail(team,.Invalid_Argument,"the router's address is no host:port")
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
    // The dials see stopping between their tries; then no thread adds a peer.
    sync.mutex_lock(&a.lock)
    for agent_dials_running(a) {sync.cond_wait(&a.wake,&a.lock)}
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
        sync.cond_wait(&a.wake,&a.lock) // peer_unpin broadcasts
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

// Whether a dial thread runs. Under the agent's lock.
@(private)
agent_dials_running :: proc(a:^Agent) -> bool {
    for _,d in a.dialing {
        if d.phase==.Running {return true}
    }
    return false
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
    delete(a.fetches)
    delete(a.claims)
    delete(a.heard)
    delete(a.roots)
    delete(a.team.name,a.allocator)
    delete(a.team.device,a.allocator)
    a.team={}
}

// Tells the agent that this process wrote heads: they go to the peers now,
// and what a workspace now links is pulled.
agent_changed :: proc(a:^Agent) {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    agent_wake_locked(a,{.Changed})
}

// Wakes the agent to immediately retry disconnected peers and sync heads.
agent_sync_now :: proc(a:^Agent) {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    dial_cooldowns_drop(a)
    agent_wake_locked(a,{.Changed,.Redial})
}

// Wakes the look thread for wakes, and with Changed every puller. Under the
// agent's lock.
@(private)
agent_wake_locked :: proc(a:^Agent,wakes:bit_set[Agent_Wake]) {
    a.wakes+=wakes
    if .Changed in wakes {
        for p in a.peers {
            sync.mutex_lock(&p.lock)
            p.dirty=true
            sync.cond_broadcast(&p.cond)
            sync.mutex_unlock(&p.lock)
        }
    }
    sync.cond_broadcast(&a.wake)
}

// Lets every key whose dial ended be dialed again at once; a running dial
// stays the one. Under the agent's lock.
@(private)
dial_cooldowns_drop :: proc(a:^Agent) {
    cooling:=make([dynamic]Key,context.temp_allocator)
    for key,d in a.dialing {
        if d.phase==.Cooling {append(&cooling,key)}
    }
    for key in cooling {delete_key(&a.dialing,key)}
}

// Lets one key be dialed again at once, unless its dial runs. Under the
// agent's lock.
@(private)
dial_cooldown_drop :: proc(a:^Agent,key:Key) {
    if d,ok:=a.dialing[key];ok && d.phase==.Cooling {delete_key(&a.dialing,key)}
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
    for !sync.atomic_load(&a.stopping) && a.listening && a.mapping_on && wire.mapping_poll(&a.mapping).phase==.Pending && time.tick_since(started)<timeout {
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
        if p.phase==.Live {
            host:=net.address_to_string(p.remote.address,context.temp_allocator)
            texts:=make([dynamic]string,context.temp_allocator)
            text_add(&texts,string(p.name[:p.name_len]),allocator)
            text_add(&texts,string(p.device[:p.device_len]),allocator)
            text_add(&texts,fmt.tprintf("%s:%d",host,p.port>0?p.port:p.remote.port),allocator)
            _,dialed:=p.origin.(Peer_Dialed)
            if len(texts)==3 {append(out,Peer_Info{key=p.conn.peer,name=texts[0],device=texts[1],address=texts[2],dialed=dialed})}
        }
        sync.mutex_unlock(&p.lock)
    }
}

// Waits, at most timeout, for the members of org a process that just started
// asks first: every node of the org connected, or with no node, one other
// member. It waits less once nothing more can connect soon: the first dial of
// the members ended, no dial runs and no connection is in its handshake (the
// next try is REDIAL_SECONDS away), or the org has no other member. Whether
// they are connected.
agent_org_wait :: proc(a:^Agent,org:Org_Id,timeout:time.Duration) -> bool {
    o,_,e:=team_org(&a.team,org)
    if e!=.None {return false}
    own:=a.team.identity.key
    wanted:=make([dynamic]Key,context.temp_allocator)
    for m in o.members {
        if m.key!=own && m.role==.Node {append(&wanted,m.key)}
    }
    nodes:=len(wanted)>0
    if !nodes {
        for m in o.members {
            if m.key!=own {append(&wanted,m.key)}
        }
    }
    if len(wanted)==0 {return true}
    started:=time.tick_now()
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    live:=make([]bool,len(wanted),context.temp_allocator)
    for {
        settling:=false // a connection in its handshake or its Hellos
        for p in a.peers {
            sync.mutex_lock(&p.lock)
            switch p.phase {
            case .Connecting,.Hello: settling=true
            case .Live: if at,found:=slice.linear_search(wanted[:],p.conn.peer);found {live[at]=true}
            case .Ended:
            }
            sync.mutex_unlock(&p.lock)
        }
        connected:=0
        for x in live {if x {connected+=1}}
        if nodes ? connected==len(wanted) : connected>0 {return true}
        slice.fill(live,false)
        if a.dialed && !settling && !agent_dials_running(a) {return false}
        if sync.atomic_load(&a.stopping) || time.tick_since(started)>=timeout {return false}
        sync.cond_wait_with_timeout(&a.wake,&a.lock,20*time.Millisecond)
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
        if sync.atomic_load(&a.stopping) {
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
        p.agent,p.origin,p.remote=a,Peer_Accepted{socket},remote
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
    dialed:string
    p,pe=new(Peer)
    if pe==nil {dialed,de=strings.clone(address)}
    if pe!=nil || de!=nil {
        conn_free(c)
        if p!=nil {free(p)}
        return nil,.Out_Of_Memory
    }
    p.agent,p.conn,p.origin,p.remote=a,c,Peer_Dialed{dialed},c.remote
    if !peer_add(a,p) {
        conn_free(c)
        delete(dialed)
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
    if sync.atomic_load(&a.stopping) || len(a.peers)>=PEERS_MAX {return false}
    p.told=make(map[Tell_Key]store.Hash)
    p.reader=thread.create_and_start_with_poly_data(p,peer_read_run,agent_context(a))
    if p.reader==nil {
        delete(p.told)
        return false
    }
    if _,dialed:=p.origin.(Peer_Dialed);dialed {p.refs=1}
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

// The peers that are Live, each held: a caller sends to them outside the
// agent's lock and lets them go (peers_unpin).
@(private)
peers_live :: proc(a:^Agent) -> []^Peer {
    out:=make([dynamic]^Peer,context.temp_allocator)
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    for p in a.peers {
        if peer_phase(p)!=.Live {continue}
        p.refs+=1
        append(&out,p)
    }
    return out[:]
}

@(private)
peers_unpin :: proc(a:^Agent,peers:[]^Peer) {
    for p in peers {peer_unpin(a,p)}
}

@(private)
peer_phase :: proc(p:^Peer) -> Peer_Phase {
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    return p.phase
}

// Moves p to phase and wakes who waits on it. Under the peer's lock; Ended
// stays.
@(private)
peer_phase_set_locked :: proc(p:^Peer,phase:Peer_Phase) {
    if p.phase==.Ended {return}
    p.phase=phase
    sync.cond_broadcast(&p.cond)
}

// Ends a peer's connection, so its threads end. During an accepted
// handshake the socket is shut down; the reader sees Ended once it holds.
@(private)
peer_end :: proc(p:^Peer) {
    sync.mutex_lock(&p.lock)
    peer_phase_set_locked(p,.Ended)
    c:=p.conn
    if accepted,ok:=p.origin.(Peer_Accepted);ok && c==nil {net.shutdown(accepted.socket,.Both)}
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
    switch origin in p.origin {
    case Peer_Accepted: if p.conn==nil {net.close(origin.socket)}
    case Peer_Dialed: delete(origin.address)
    }
    if p.conn!=nil {conn_free(p.conn)}
    for r in p.requests {delete(r)}
    delete(p.requests)
    delete(p.fetches)
    delete(p.told)
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
            instance:=transmute([8]u8)u64le(a.instance)
            append(&body,..instance[:])
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
        peer_phase_set_locked(p,.Ended)
        sync.mutex_unlock(&p.lock)
        if p.conn!=nil {conn_close(p.conn)}
        sync.mutex_lock(&a.lock)
        sync.cond_broadcast(&a.wake)
        sync.mutex_unlock(&a.lock)
        agent_moved(a)
    }
    _,dialed:=p.origin.(Peer_Dialed)
    if accepted,ok:=p.origin.(Peer_Accepted);ok {
        c,e:=conn_accept(accepted.socket,p.remote,a.team.identity)
        if e!=.None {return}
        // A peer_end during the handshake shut the socket: the connection ends here.
        sync.mutex_lock(&p.lock)
        p.conn=c
        ended:=p.phase==.Ended
        sync.mutex_unlock(&p.lock)
        if ended {return}
    }
    c:=p.conn
    // What an invite the other end proved in its handshake allows: one Join.
    join:enum u8 {None,Proved,Spent}=c.proof!={}?.Proved:.None
    // A peer this machine's records do not list yet may hold a newer record
    // that does: it stays when its Hello names an org held here, and reads
    // nothing until a record lists it (agent_role, at every request).
    vouched:=join==.Proved || dialed || agent_knows(a,c.peer)
    buffer,be:=make([]u8,FRAME_MAX+NOISE_TAG)
    if be!=nil {return}
    defer delete(buffer)
    // An initiator's first message: control RPCs (web sign-in, server attach,
    // offline invite grant) run on their own short connection so they
    // never disrupt the sync connection kept to the peer's key.
    first:Msg
    first_body:[]u8
    if !dialed {
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
        }
    }
    // Both ends say Hello before reading the other's, the dialing end first:
    // the connection kept to the other end's agent is chosen once both are.
    heads:=make([dynamic]Tell_Entry,context.temp_allocator)
    agent_heads(a,c.peer,&heads)
    if dialed {
        if !peer_tell(p,heads[:],.Hello) {return}
        ok:bool
        if first,first_body,ok=conn_receive(c,buffer);!ok {return}
    }
    instance,said:=hello_instance(first,first_body)
    if !said {return}
    sync.mutex_lock(&p.lock)
    p.instance=instance
    sync.mutex_unlock(&p.lock)
    if !peer_unique(a,p) {return}
    if !dialed && !peer_tell(p,heads[:],.Hello) {return}
    // The other two start only while the peer runs: one ended meanwhile starts
    // none. It is Live once both run; if one does not start, it ends.
    sync.mutex_lock(&p.lock)
    if p.phase==.Ended {
        sync.mutex_unlock(&p.lock)
        return
    }
    p.server=thread.create_and_start_with_poly_data(p,peer_serve_run,agent_context(a))
    p.puller=thread.create_and_start_with_poly_data(p,peer_pull_run,agent_context(a))
    started:=p.server!=nil && p.puller!=nil
    if started {peer_phase_set_locked(p,.Live)}
    sync.mutex_unlock(&p.lock)
    if !started {return}
    agent_moved(a)
    // The other peers learn where it listens, and it where they do.
    sync.mutex_lock(&a.lock)
    agent_wake_locked(a,{.Gossip})
    sync.mutex_unlock(&a.lock)
    raw,re:=make([]u8,store.CHUNK_MAX)
    if re!=nil {return}
    defer delete(raw)
    greeted:=false
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
            if greeted {return}
            greeted=true
            name:=tail_string(&r)
            device:=tail_string(&r)
            port:=int(read_value(&r,u16le))
            _=read_value(&r,u64le) // its instance, taken before
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
                sync.atomic_store(&a.asked,transfer_now())
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
            // One Join per proved invite: another, or one with none, ends the connection.
            if r.short || join!=.Proved {return}
            join=.Spent
            if !agent_admit(a,p,org,name,device,public,claim) {return}
        case .Welcome:
            _=read_value(&r,Org_Id)
            w:Welcome
            w.record=read_value(&r,store.Hash)
            if !r.short && r.at<len(body) {w.admission=read_value(&r,store.Hash)}
            // Only a dialed end that joins is welcomed, once.
            if r.short || !dialed || w.record=={} {return}
            sync.mutex_lock(&p.lock)
            again:=p.welcome!=nil
            if !again {
                p.welcome=w
                sync.cond_broadcast(&p.cond)
            }
            sync.mutex_unlock(&p.lock)
            if again {return}
        case .Bye:
            agent_event(a,"%s left: %s",peer_text(p),string(body[:min(len(body),300)]))
            return
        case .Peers:
            entries,ok:=gossip_parse(body)
            if !ok {return}
            if vouched || agent_knows(a,c.peer) {agent_heard(a,p,entries)}
        case .Web_Login,.Server_Info,.Org_Register,.Invite_Grant:
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

// The agent instance a connection's first message, its Hello, says; said
// false for any other message or one that does not parse.
@(private)
hello_instance :: proc(kind:Msg,body:[]u8) -> (instance:u64,said:bool) {
    if kind!=.Hello {return}
    r:=Reader{data=body}
    _=tail_string(&r)
    _=tail_string(&r)
    _=read_value(&r,u16le)
    instance=u64(read_value(&r,u64le))
    return instance,!r.short && instance!=0
}

// Whether p is the one connection kept to the agent at its other end, its
// key and the instance its Hello said: of two, the one whose dialing end has
// the lower key, then instance, which both ends choose alike. Two agents of
// one key (an editor's and an import's of one machine) keep a connection
// each. Two readers that run it at once (both ends dialed each other) see
// each other's choice: it is made under the agent's lock.
@(private)
peer_unique :: proc(a:^Agent,p:^Peer) -> bool {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    // Both set before this reader runs it, by its own thread.
    key,instance:=p.conn.peer,p.instance
    for q in a.peers {
        if q==p {continue}
        sync.mutex_lock(&q.lock)
        kept:=(q.phase==.Hello || q.phase==.Live) && q.conn.peer==key && q.instance==instance
        sync.mutex_unlock(&q.lock)
        if !kept {continue}
        if dialer_before(a,q,p) {return false}
        peer_end(q)
    }
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    if p.phase==.Ended {return false}
    peer_phase_set_locked(p,.Hello)
    return true
}

// Whether the agent that dialed x comes before the one that dialed y, by key
// then instance. Both are kept to their agent: their instance is set.
@(private="file")
dialer_before :: proc(a:^Agent,x,y:^Peer) -> bool {
    Dialer :: struct {key:Key,instance:u64}
    of :: proc(a:^Agent,p:^Peer) -> Dialer {
        if _,dialed:=p.origin.(Peer_Dialed);dialed {return {a.team.identity.key,a.instance}}
        return {p.conn.peer,p.instance}
    }
    dx,dy:=of(a,x),of(a,y)
    if dx.key!=dy.key {return key_less(dx.key,dy.key)}
    return dx.instance<dy.instance
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
                if w.org==e.org && w.key==e.id {ddc_wait_answer(w,p,e.address)}
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
        for len(p.requests)==0 && p.phase!=.Ended {sync.cond_wait(&p.cond,&p.lock)}
        if p.phase==.Ended {
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
        // A device no record here lists yet may bring the one that does
        // (peer_read_run): it reads nothing until then. A member of another
        // org that asks this one's is cut off.
        _,member:=agent_role(a,org,p.conn.peer)
        s,se:=team_store(&a.team,org)
        if se!=.None || !member && agent_knows(a,p.conn.peer) {
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
            if member {entry.address,_=store.ref_get(s,ddc_namespace(org,&ns),store.hex(key,&name))}
            if !peer_tell(p,{entry}) {return}
            continue
        }
        count:=int(read_value(&r,u16le))
        if count>WANT_MAX || !count_fits(&r,u64(count),size_of(store.Hash)) {return}
        lacking:=make([dynamic]store.Hash,context.temp_allocator)
        at,n:=2,0
        served,served_bytes:=0,i64(0)
        for _ in 0..<count {
            address:=read_value(&r,store.Hash)
            if !member {
                append(&lacking,address)
                continue
            }
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
            served+=1
            served_bytes+=i64(size)
            sync.atomic_add(&a.served,1)
        }
        if n>0 && !serve_flush(p,buffer,at,n) {return}
        if served>0 {
            asked:=slice.reinterpret([]store.Hash,request[1+size_of(Org_Id)+2:][:count*size_of(store.Hash)])
            agent_transfer(a,p,.Upload,agent_serving(a,p,org,asked),served,served_bytes,0)
        }
        sync.atomic_store(&a.asked,transfer_now())
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
        for !p.dirty && p.phase!=.Ended {sync.cond_wait(&p.cond,&p.lock)}
        if p.phase==.Ended {
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
        if !peer_fetch(p,e.org,s,{e.address}) {continue}
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
            if !peer_fetch(p,e.org,s,{e.address}) {continue}
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
            if !kept {
                if refs,_,re:=repo_refs_head(s,id,r.id,context.temp_allocator);re==.None {
                    for b in refs.bookmarks {
                        if b.name!="main" {continue}
                        c,ce:=change_get(s,b.target,context.temp_allocator)
                        if ce!=.None {
                            if !peer_fetch(p,id,s,{b.target}) {continue}
                            changed=true
                            c,ce=change_get(s,b.target,context.temp_allocator)
                            if ce!=.None {continue}
                        }
                        if c.tree!={} {
                            if _,te:=tree_totals(s,c.tree);te!=.None {
                                if peer_fetch(p,id,s,{c.tree}) {changed=true}
                            }
                        }
                    }
                }
                continue
            }
            refs,_,re:=repo_refs_head(s,id,r.id,context.temp_allocator)
            if re!=.None {continue}
            roots:=make([dynamic]Walk_Item,context.temp_allocator)
            for b in refs.bookmarks {append(&roots,Walk_Item{b.target,.Change})}
            before:=agent_pull_chunks(a,id,r.id)
            whole:=peer_whole(p,id,s,roots[:],r.id,agent_sources(a,id,r.id))
            seen:=agent_pull_chunks(a,id,r.id)
            if !whole {
                // What this peer lacked another may have brought.
                missing:=make([dynamic]store.Hash,context.temp_allocator)
                walk_missing(s,roots[:],nil,&missing)
                whole=len(missing)==0
            }
            pull:=agent_pull_end(a,id,r.id,whole,seen)
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
    if !peer_fetch(p,org.id,s,{address},kind=.Ddc) {return}
    records:=make([dynamic][]u8,context.temp_allocator)
    if ddc_set_read(s,address,&records)!=.None {return}
    roots:=make([dynamic]Walk_Item,context.temp_allocator)
    for record in records {
        if d,ok:=ddc_record_allowed(org,key,record);ok {append(&roots,Walk_Item{d.output_root,.Output})}
    }
    if len(roots)==0 || !peer_whole(p,org.id,s,roots[:],kind=.Ddc) {return}
    moved,_,e:=ddc_accept(s,org,key,address) // its ref_set commits
    return e==.None,moved
}

// Fetches from p every object roots reach that is not whole in s, a level at
// a time; whole when nothing is missing any more. repo and sources are
// peer_fetch's.
@(private)
peer_whole :: proc(p:^Peer,org:Org_Id,s:^store.Store,roots:[]Walk_Item,repo:Repo_Id={},sources:=1,kind:=Transfer_Kind.Sync) -> bool {
    for {
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        walk_missing(s,roots,nil,&missing)
        if len(missing)==0 {return true}
        if !peer_fetch(p,org,s,missing[:],repo,sources,kind) {return false}
    }
}

// How many connected peers told of the repository's shared bookmarks: those a
// pull of it splits among.
@(private)
agent_sources :: proc(a:^Agent,org:Org_Id,repo:Repo_Id) -> int {
    k:=Tell_Key{kind=.Repo,org=org}
    id:=repo
    copy(k.id[:16],id[:])
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    n:=0
    for p in a.peers {
        sync.mutex_lock(&p.lock)
        if p.phase==.Live && k in p.told {n+=1}
        sync.mutex_unlock(&p.lock)
    }
    return max(n,1)
}

// The pull of a repository, made when there is none; nil when memory ran
// out. Under the agent's lock.
@(private)
pull_locked :: proc(a:^Agent,org:Org_Id,repo:Repo_Id) -> ^Pull {
    for &x in a.pulls {
        if x.org==org && x.repo==repo {return &x}
    }
    if _,e:=append(&a.pulls,Pull{org=org,repo=repo});e!=nil {return nil}
    return &a.pulls[len(a.pulls)-1]
}

// The chunks a repository's pull took so far, 0 while there is none: what a
// pass reads before and after it, without making the pull.
@(private)
agent_pull_chunks :: proc(a:^Agent,org:Org_Id,repo:Repo_Id) -> int {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    for x in a.pulls {
        if x.org==org && x.repo==repo {return x.chunks}
    }
    return 0
}

// Says whether the pull of a repository is whole, as a pass of one peer found
// it, and gives it. A pass that finds it not whole says so only when no chunk
// arrived since seen (the pull's chunks when it looked): one that came from
// another peer meanwhile is that peer's pass to judge.
@(private)
agent_pull_end :: proc(a:^Agent,org:Org_Id,repo:Repo_Id,whole:bool,seen:int) -> Pull {
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    x:=pull_locked(a,org,repo)
    if x==nil {return {org=org,repo=repo}}
    if whole {
        x.whole,x.left=true,0
    } else if x.chunks==seen {
        x.whole=false
    }
    agent_moved(a)
    return x^
}

// Counts what a fetch of a repository's pull took and what every fetch of it
// has left. Under the agent's lock.
@(private)
pull_count_locked :: proc(a:^Agent,f:^Fetch,chunks:int,bytes:i64) {
    x:=pull_locked(a,f.org,f.repo)
    if x==nil {return}
    x.chunks+=chunks
    x.bytes+=bytes
    if chunks>0 {x.whole=false}
    x.left=0
    for g in a.fetches {
        if g.org==f.org && g.repo==f.repo {x.left+=g.left}
    }
    agent_moved(a)
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
        if !peer_fetch(p,org,s,{need}) {return false,.Missing}
    }
    return false,.Too_Large
}

// Fetches every chunk of the objects at roots that s lacks from p, many in
// flight; ok when all came. A chunk another fetch of the agent asked (another
// peer's) is left to it: once that fetch has it, lacks it, fails or ends, the
// claim goes (fetch_release) and this one takes the chunk or asks it itself.
// repo, when not zero, is the repository whose pull counts what arrives;
// sources, how many peers hold it: each takes its share of a level of few
// chunks, and a fast one takes what is left. kind: what the transfer it
// counts in moves, Project with a repo.
@(private)
peer_fetch :: proc(p:^Peer,org:Org_Id,s:^store.Store,roots:[]store.Hash,repo:Repo_Id={},sources:=1,kind:=Transfer_Kind.Sync) -> (ok:bool) {
    a:=p.agent
    f,fe:=new(Fetch)
    if fe!=nil {return false}
    defer free(f)
    f.s,f.org,f.repo,f.kind=s,org,repo,repo!={}?.Project:kind
    f.pending=make(map[store.Hash]struct{})
    defer delete(f.pending)
    defer delete(f.arrived)
    sync.mutex_lock(&a.lock)
    _,ae:=append(&a.fetches,f)
    sync.mutex_unlock(&a.lock)
    if ae!=nil {return false}
    sync.mutex_lock(&p.lock)
    _,pe:=append(&p.fetches,f)
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
        // The reader finds it no more: what it asked and did not have goes to the other fetches.
        sync.mutex_lock(&a.lock)
        for address in f.pending {fetch_release(a,f,address)}
        for x in f.arrived {fetch_release(a,f,x.address)}
        for x,k in a.fetches {
            if x==f {
                unordered_remove(&a.fetches,k)
                break
            }
        }
        if repo!={} {pull_count_locked(a,f,0,0)}
        sync.cond_broadcast(&a.wake)
        sync.mutex_unlock(&a.lock)
        store.commit(s)
    }
    if pe!=nil {return false}
    queue:=make([dynamic]Fetch_Want,context.temp_allocator)
    deferred:=make([dynamic]Fetch_Want,context.temp_allocator) // asked by another fetch
    nodes:=make(map[store.Hash]bool,context.temp_allocator)
    for r in roots {append(&queue,Fetch_Want{r,true})}
    buffer,be:=make([]u8,store.CHUNK_MAX)
    if be!=nil {return false}
    defer delete(buffer)
    inflight:=0
    lacked:=false
    batch:=make([dynamic]store.Hash,context.temp_allocator)
    for len(queue)>0 || inflight>0 || len(deferred)>0 {
        budget:=max(int)
        if sources>1 {budget=max(1,(len(queue)+sources-1)/sources)}
        for len(queue)>0 && inflight<FETCH_WINDOW && budget>0 {
            clear(&batch)
            sync.mutex_lock(&a.lock)
            for len(queue)>0 && len(batch)<min(WANT_MAX,budget) && inflight+len(batch)<FETCH_WINDOW {
                w:=pop(&queue)
                if w.address in nodes || store.chunk_here(s,w.address) && !w.node {continue}
                if w.node && store.chunk_here(s,w.address) {
                    // A node here: its children may not be.
                    nodes[w.address]=true
                    sync.mutex_unlock(&a.lock)
                    fetch_children(s,w.address,buffer,&queue)
                    sync.mutex_lock(&a.lock)
                    continue
                }
                claim:=Claim{s,w.address}
                if owner,claimed:=a.claims[claim];claimed && owner!=f {
                    append(&deferred,w)
                    continue
                }
                if _,ce:=map_insert(&a.claims,claim,f);ce!=nil {
                    sync.mutex_unlock(&a.lock)
                    return false
                }
                nodes[w.address]=w.node
                append(&batch,w.address)
            }
            sync.mutex_unlock(&a.lock)
            if len(batch)==0 {break}
            sync.mutex_lock(&p.lock)
            for address in batch {f.pending[address]={}}
            sync.mutex_unlock(&p.lock)
            head:=[2]u8{u8(len(batch)),u8(len(batch)>>8)}
            o:=org
            if !conn_send(p.conn,.Want,o[:],head[:],slice.to_bytes(batch[:])) {return false}
            inflight+=len(batch)
            budget-=len(batch)
        }
        if inflight==0 {
            // The queue is empty: what is left another fetch asked.
            if len(deferred)==0 {break}
            if !fetch_wait(p,f,&deferred,&queue) {return false}
            continue
        }
        sync.mutex_lock(&p.lock)
        deadline:=time.tick_now()
        for len(f.arrived)==0 && p.phase!=.Ended {
            if time.tick_since(deadline)>FETCH_SECONDS*time.Second {
                sync.mutex_unlock(&p.lock)
                return false
            }
            sync.cond_wait_with_timeout(&p.cond,&p.lock,time.Second)
        }
        if p.phase==.Ended {
            sync.mutex_unlock(&p.lock)
            return false
        }
        arrived:=make([]Arrival,len(f.arrived),context.temp_allocator)
        copy(arrived,f.arrived[:])
        clear(&f.arrived)
        sync.mutex_unlock(&p.lock)
        chunks,bytes:=0,i64(0)
        sync.mutex_lock(&a.lock)
        for x in arrived {
            fetch_release(a,f,x.address)
            if !x.lacked {
                chunks+=1
                bytes+=i64(x.bytes)
            }
        }
        inflight-=len(arrived)
        f.left=len(queue)+inflight
        if repo!={} {pull_count_locked(a,f,chunks,bytes)}
        left:=f.left
        sync.cond_broadcast(&a.wake)
        sync.mutex_unlock(&a.lock)
        agent_transfer(a,p,.Download,{kind=f.kind,org=org,repo=repo},chunks,bytes,left)
        for x in arrived {
            if x.lacked {
                lacked=true
                continue
            }
            if nodes[x.address] {fetch_children(s,x.address,buffer,&queue)}
        }
    }
    return !lacked
}

// Lets go of a chunk f asked, so another fetch may ask it. Under the agent's lock.
@(private)
fetch_release :: proc(a:^Agent,f:^Fetch,address:store.Hash) {
    claim:=Claim{f.s,address}
    if owner,ok:=a.claims[claim];ok && owner==f {delete_key(&a.claims,claim)}
}

// Waits until another fetch lets go of a chunk f left to it, which goes back
// to the queue; false when the peer or the agent ends meanwhile.
@(private)
fetch_wait :: proc(p:^Peer,f:^Fetch,deferred,queue:^[dynamic]Fetch_Want) -> bool {
    a:=p.agent
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    for {
        for k:=0;k<len(deferred); {
            if owner,claimed:=a.claims[Claim{f.s,deferred[k].address}];claimed && owner!=f {
                k+=1
                continue
            }
            append(queue,deferred[k])
            unordered_remove(deferred,k)
        }
        if len(queue)>0 {return true}
        if peer_phase(p)==.Ended || sync.atomic_load(&a.stopping) {return false}
        sync.cond_wait_with_timeout(&a.wake,&a.lock,100*time.Millisecond)
    }
}

// Queues the children of the node at address that s lacks.
@(private)
fetch_children :: proc(s:^store.Store,address:store.Hash,buffer:[]u8,queue:^[dynamic]Fetch_Want) {
    bytes,e:=store.chunk_read(s,address,buffer)
    if e!=.None {return}
    n,pe:=store.node_parse(bytes)
    if pe!=.None {return}
    for entry in n.entries {
        if n.level>0 {
            append(queue,Fetch_Want{entry.address,true})
        } else if !store.chunk_here(s,entry.address) {
            append(queue,Fetch_Want{entry.address,false})
        }
    }
}

// --- Joining ---

// Joins the org of an invite: dials its addresses until the inviting device
// (or the org's server for an offline invite) answers, proves the invite and
// waits until this machine holds the org's record (and admission, if offline)
// that lists it. A failure says why in why, when given.
agent_join :: proc(a:^Agent,text:string,why:^string=nil) -> (org:Org_Id,error:Error) {
    token,e:=invite_parse(text,context.temp_allocator)
    if e!=.None {return {},agent_fail(why,e,"that is no Kai invite: copy all of it, it begins with kai2")}
    if a.team.name=="" {return {},agent_fail(why,.Invalid_Argument,"name yourself and this machine first")}
    p:^Peer
    for address in token.addresses {
        p,e=agent_dial(a,address,token.key,token.secret)
        if e==.None {break}
    }
    if p==nil {
        if e==.Unauthorized {return {},agent_fail(why,e,"the machine at the invite's address is not the one that invited: ask for a new invite")}
        return {},agent_fail(why,.Unreachable,fmt.tprintf("Could not reach %s. Make sure the inviter has Mirai open and is reachable from your network.",len(token.addresses)>0?token.addresses[0]:"the inviting machine"))
    }
    defer peer_unpin(a,p)
    claim:=Invite_Claim{
        org=token.org,secret=token.secret,key=a.team.identity.key,
        name=a.team.name,device=a.team.device,public=a.options.public,
    }
    claim_bytes,ce:=invite_claim_encode(&claim,&a.team.identity,context.temp_allocator)
    if ce!=.None {return {},agent_fail(why,ce,"could not sign the invite claim")}
    body:=make([dynamic]u8,context.temp_allocator)
    o:=token.org
    append(&body,..o[:])
    write_text(&body,a.team.name)
    write_text(&body,a.team.device)
    write_text(&body,a.options.public)
    clen:=u16(len(claim_bytes))
    append(&body,u8(clen),u8(clen>>8))
    append(&body,..claim_bytes)
    // The Join goes once the peer is Live: its reader sent the Hello first.
    sync.mutex_lock(&p.lock)
    for p.phase!=.Live && p.phase!=.Ended {sync.cond_wait(&p.cond,&p.lock)}
    live:=p.phase==.Live
    sync.mutex_unlock(&p.lock)
    if !live || !conn_send(p.conn,.Join,body[:]) {return {},agent_fail(why,.Unreachable,"the inviting machine closed the connection")}
    sync.mutex_lock(&p.lock)
    started:=time.tick_now()
    for p.welcome==nil && p.phase!=.Ended && time.tick_since(started)<30*time.Second {sync.cond_wait_with_timeout(&p.cond,&p.lock,time.Second)}
    welcome,welcomed:=p.welcome.?
    sync.mutex_unlock(&p.lock)
    if !welcomed {return {},agent_fail(why,.Expired,"the inviting machine refused the invite: it is used or past its time, ask for a new one")}
    if _,pe:=agent_org_pull(a,p,token.org,welcome.record,true);pe!=.None {return {},agent_fail(why,pe,"the org's record from the inviting machine does not hold: ask for a new invite")}
    if welcome.admission!={} {
        s,se:=team_store(&a.team,token.org)
        if se!=.None || !peer_fetch(p,token.org,s,{welcome.admission}) {return {},agent_fail(why,.Missing,"the admission from the server did not arrive: ask for a new invite")}
        raw_org,_,oe:=org_head(s,token.org,context.temp_allocator)
        if oe!=.None {return {},agent_fail(why,oe,"the org's record does not read")}
        if _,ae:=admission_accept(s,&raw_org,welcome.admission);ae!=.None {return {},agent_fail(why,ae,"the admission from the server does not verify: ask for a new invite")}
        store.commit(s)
    }
    if _,member:=agent_role(a,token.org,a.team.identity.key);!member {return {},agent_fail(why,.Unauthorized,"the org's record does not list this machine: ask for a new invite")}
    if dialed,ok:=p.origin.(Peer_Dialed);ok {team_peer_seen(&a.team,token.key,dialed.address)}
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
    t:=a.team // what fails here says why in this copy: the agent's team is every thread's
    role,invited,e:=team_invite_take(&t,org,p.conn.proof,p.conn.proved)
    if e==.None {
        address:=public
        // A server that names no address is reached where it dialed from, at the port it listens on.
        if address=="" && role==.Node && port>0 {address=fmt.tprintf("%s:%d",net.address_to_string(p.remote.address,context.temp_allocator),port)}
        member:=Member{key=p.conn.peer,role=role,name=invited!=""?invited:name,device=device,address=address}
        e=team_member_set(&t,org,member)
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
// record, pushes the org chain and starts syncing immediately. A failure
// says why in why, when given.
agent_server_attach :: proc(a:^Agent,org:Org_Id,address:string,why:^string=nil) -> Error {
    if address=="" || len(address)>ADDRESS_MAX {return agent_fail(why,.Invalid_Argument,"give the server's host:port")}
    {
        sync.mutex_lock(&a.lock)
        defer sync.mutex_unlock(&a.lock)
        o,_,oe:=team_org(&a.team,org)
        if oe!=.None {return oe}
        if role,ok:=org_role(&o,a.team.identity.key);!ok || role!=.Admin {
            return agent_fail(why,.Unauthorized,"only an admin of the org attaches a server")
        }
    }
    c,e:=conn_dial(address,a.team.identity,{},{},&a.stopping)
    if e!=.None {return agent_fail(why,e,"no Kai server answered at that address")}
    defer conn_free(c)
    net.set_option(c.socket,.Receive_Timeout,WEB_LOGIN_SECONDS*time.Second)
    if !conn_send(c,.Server_Info) {return agent_fail(why,.Unreachable,"the server closed the connection")}
    buffer,be:=make([]u8,FRAME_MAX+NOISE_TAG)
    if be!=nil {return .Out_Of_Memory}
    defer delete(buffer)
    kind,reply,ok:=conn_receive(c,buffer)
    if !ok {return agent_fail(why,.Unreachable,"the server closed the connection")}
    if kind==.Bye {return agent_fail(why,.Unauthorized,strings.clone(string(reply),context.temp_allocator))}
    if kind!=.Server_Info {return agent_fail(why,.Corrupt,"unexpected answer from the server")}
    r:=Reader{data=reply}
    srv_name:=strings.clone(tail_string(&r),context.temp_allocator)
    srv_device:=strings.clone(tail_string(&r),context.temp_allocator)
    srv_public:=strings.clone(tail_string(&r),context.temp_allocator)
    if r.short || !name_valid(srv_name) || !name_valid(srv_device) {return agent_fail(why,.Corrupt,"the server's identity is invalid")}
    server_addr:=srv_public!=""?srv_public:address
    if len(server_addr)>ADDRESS_MAX {return agent_fail(why,.Corrupt,"the server's public address is too long")}

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
            return agent_fail(why,.Unauthorized,"only an admin of the org attaches a server")
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
                if len(members)>=MEMBERS_MAX {return agent_fail(why,.Too_Large,"the org has as many members as it may")}
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
    if len(body)>FRAME_MAX-1 {return agent_fail(why,.Too_Large,"the org history is larger than one registration frame")}
    if !conn_send(c,.Org_Register,body[:]) {return agent_fail(why,.Unreachable,"the server closed the connection")}
    kind,reply,ok=conn_receive(c,buffer)
    if !ok {return agent_fail(why,.Unreachable,"the server closed the connection")}
    if kind==.Bye {return agent_fail(why,.Unauthorized,strings.clone(string(reply),context.temp_allocator))}
    if kind!=.Welcome {return agent_fail(why,.Corrupt,"unexpected answer from the server")}
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
// Otherwise falls back to a local invite on fallback_addresses. A failure
// says why in why, when given.
agent_invite :: proc(a:^Agent,org:Org_Id,role:Role,name:string,fallback_addresses:[]string,allocator:=context.allocator,why:^string=nil) -> (text:string,via_server:bool,error:Error) {
    o,_,oe:=team_org(&a.team,org)
    if oe!=.None {return "",false,oe}
    if r,ok:=org_role(&o,a.team.identity.key);!ok || r!=.Admin {
        return "",false,agent_fail(why,.Unauthorized,"only an admin of the org invites: ask one")
    }
    if name!="" && !name_valid(name) {
        return "",false,agent_fail(why,.Invalid_Argument,"a name has 1 to 64 bytes of UTF-8 without control characters")
    }
    if server_key,server_addr,has_server:=org_server(&o);has_server {
        secret:[32]u8
        crypto.rand_bytes(secret[:])
        defer crypto.zero_explicit(&secret,32)
        grant:=Invite_Grant{
            org=org,secret_hash=secret_digest(secret),role=role,
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
    t:=a.team // its why is this call's
    made,te:=team_invite(&t,org,role,name,fallback_addresses,allocator)
    if te!=.None && why!=nil {why^=t.why}
    return made,false,te
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

// Sets the web sign-in of this device on the server at address: a server of
// one of its orgs, which must prove its key, so the password reaches no other
// machine. The server is the one whose address is that, else the one server
// its orgs list. A failure says why in why, when given.
agent_web_login :: proc(a:^Agent,address,name,password:string,why:^string=nil) -> Error {
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
    if matched=={} && servers!=1 {return agent_fail(why,.Invalid_Argument,"no single server of your orgs is at that address: give the address your org lists for its server")}
    c,e:=conn_dial(address,a.team.identity,expect,{},&a.stopping)
    if e==.Unauthorized {return agent_fail(why,e,"the machine at that address is not your org's server")}
    if e!=.None {return agent_fail(why,e,"no Kai server answered at that address")}
    defer conn_free(c)
    net.set_option(c.socket,.Receive_Timeout,WEB_LOGIN_SECONDS*time.Second)
    body:=make([dynamic]u8,context.temp_allocator)
    write_text(&body,name)
    write_text(&body,password)
    if !conn_send(c,.Web_Login,body[:]) {return agent_fail(why,.Unreachable,"the server closed the connection")}
    buffer,be:=make([]u8,FRAME_MAX+NOISE_TAG)
    if be!=nil {return .Out_Of_Memory}
    defer delete(buffer)
    for {
        kind,reply,ok:=conn_receive(c,buffer)
        if !ok {return agent_fail(why,.Unreachable,"the server closed the connection")}
        if kind!=.Bye {continue}
        if string(reply)!="web sign-in set" {return agent_fail(why,.Unauthorized,strings.clone(string(reply),context.temp_allocator))}
        return .None
    }
}

// Says why a call of the agent failed to its caller, when it asks.
@(private)
agent_fail :: proc(why:^string,e:Error,text:string) -> Error {
    if why!=nil {why^=text}
    return e
}

// --- Derived data ---

// What an ask of derived data (agent_ddc_ask) came to.
Ddc_Answer :: enum u8 {
    Missing, // every member that could hold the set answered, and none does: the org has no other member, or each one connected answered none
    Taken,   // a peer held the set, and it is whole here
    Failed,  // unknown: no other member of the org was connected, one asked did not answer in time or left, or the set did not come whole
}

// Asks the connected members of org for the derived data set of key and
// fetches it whole from the first that holds one.
agent_ddc_ask :: proc(a:^Agent,org:Org_Id,key:store.Hash,timeout:=5*time.Second) -> Ddc_Answer {
    s,se:=team_store(&a.team,org)
    if se!=.None {return .Failed}
    held,_,oe:=org_effective_head(s,org,context.temp_allocator)
    if oe!=.None {return .Failed}
    others:=false
    for m in held.members {others||=m.key!=a.team.identity.key}
    if !others {return .Missing}
    body:=make([dynamic]u8,context.temp_allocator)
    o,k:=org,key
    append(&body,..o[:])
    append(&body,..k[:])
    // The members of org connected, held until the wait ends: what answers is one of them.
    live:=peers_live(a)
    peers:=make([dynamic]^Peer,0,len(live),context.temp_allocator)
    for p in live {
        if _,member:=org_role(&held,p.conn.peer);member {append(&peers,p)} else {peer_unpin(a,p)}
    }
    if len(peers)==0 {return .Failed}
    w:=Ddc_Wait{org=org,key=key,asked=peers[:],answered=make([]bool,len(peers),context.temp_allocator)}
    sync.mutex_lock(&a.lock)
    _,ae:=append(&a.waits,&w)
    sync.mutex_unlock(&a.lock)
    if ae!=nil {
        peers_unpin(a,peers[:])
        return .Failed
    }
    silent:=false // a peer asked that will not answer
    for p,i in peers {
        if !conn_send(p.conn,.Ddc_Ask,body[:]) {
            sync.mutex_lock(&a.lock)
            w.answered[i],silent=true,true
            sync.mutex_unlock(&a.lock)
        }
    }
    sync.mutex_lock(&a.lock)
    started:=time.tick_now()
    for !ddc_wait_done(&w) && time.tick_since(started)<timeout {
        // One whose connection ended will not answer: the wait does not wait for it.
        for p,i in peers {
            if !w.answered[i] && peer_phase(p)==.Ended {w.answered[i],silent=true,true}
        }
        if ddc_wait_done(&w) {break}
        sync.cond_wait_with_timeout(&a.wake,&a.lock,100*time.Millisecond)
    }
    all:=ddc_wait_done(&w)
    for x,i in a.waits {
        if x==&w {
            unordered_remove(&a.waits,i)
            break
        }
    }
    hit,ok:=w.hit.?
    sync.mutex_unlock(&a.lock)
    for p in peers {
        if !ok || p!=hit.from {peer_unpin(a,p)}
    }
    if !ok {return all && !silent ? .Missing : .Failed}
    defer peer_unpin(a,hit.from)
    whole,_:=peer_ddc_take(hit.from,&held,s,key,hit.address)
    return whole ? .Taken : .Failed
}

// Takes the answer of p to w: the first that names a set is the hit; each
// peer asked answers once, and a peer not asked is not heard. Under the
// agent's lock.
@(private)
ddc_wait_answer :: proc(w:^Ddc_Wait,p:^Peer,address:store.Hash) {
    for q,i in w.asked {
        if q!=p || w.answered[i] {continue}
        w.answered[i]=true
        if address!={} && w.hit==nil {w.hit=Ddc_Hit{address,p}}
        return
    }
}

// Whether w has its hit or every peer it asked answered. Under the agent's lock.
@(private)
ddc_wait_done :: proc(w:^Ddc_Wait) -> bool {
    if w.hit!=nil {return true}
    for answered in w.answered {
        if !answered {return false}
    }
    return true
}

// Tells the connected nodes of org that this machine published the derived
// data set of key, so they keep it.
agent_ddc_published :: proc(a:^Agent,org:Org_Id,key:store.Hash,address:store.Hash) {
    entry:=Tell_Entry{kind=.Ddc,org=org,id=key,address=address}
    peers:=peers_live(a)
    defer peers_unpin(a,peers)
    for p in peers {
        if role,ok:=agent_role(a,org,p.conn.peer);ok && role==.Node && peer_tell(p,{entry}) {sync.atomic_store(&a.asked,transfer_now())}
    }
}

// --- Looking, dialing, reaping ---

@(private)
agent_look_run :: proc(a:^Agent) {
    defer thread_end()
    last_dial:i64
    mapped:=wire.Port_Mapping_Phase.Pending
    // The first turn dials at once: a process that just started asks its peers soon.
    for first:=true;;first=false {
        free_all(context.temp_allocator)
        sync.mutex_lock(&a.lock)
        if !first && !sync.atomic_load(&a.stopping) && a.wakes=={} {sync.cond_wait_with_timeout(&a.wake,&a.lock,LOOK_SECONDS*time.Second)}
        if sync.atomic_load(&a.stopping) {
            sync.mutex_unlock(&a.lock)
            return
        }
        wakes:=a.wakes
        a.wakes={}
        // Reap the peers whose reader ended and that no caller holds.
        dead:=make([dynamic]^Peer,context.temp_allocator)
        for k:=0;k<len(a.peers); {
            p:=a.peers[k]
            if peer_phase(p)==.Ended && p.refs==0 {
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
        // Who is a member changes whom the peers are told of.
        if agent_tell_changes(a) {wakes+={.Gossip}}
        // The router's answer changes what an invite carries and where this machine is reached.
        if a.mapping_on {
            if phase:=wire.mapping_poll(&a.mapping).phase;phase!=mapped {
                mapped=phase
                wakes+={.Gossip}
                agent_moved(a)
            }
        }
        if .Gossip in wakes {agent_gossip(a)}
        now:=time.now()._nsec
        if .Redial in wakes || now-last_dial>=REDIAL_SECONDS*i64(time.Second) {
            last_dial=now
            agent_dial_members(a)
        } else if .Changed in wakes {
            agent_dial_members(a)
        }
    }
}

// Tells each peer the heads that moved since it was told last; members when
// an org's record or admissions moved.
@(private)
agent_tell_changes :: proc(a:^Agent) -> (members:bool) {
    heads:=make([dynamic]Tell_Entry,context.temp_allocator)
    agent_heads(a,{},&heads)
    moved:=make([dynamic]Tell_Entry,context.temp_allocator)
    sync.mutex_lock(&a.lock)
    for h in heads {
        k:=Tell_Key{h.kind,h.org,h.id}
        if held,ok:=a.told[k];ok && held==h.address {continue}
        a.told[k]=h.address
        append(&moved,h)
        members||=h.kind==.Org || h.kind==.Admit
    }
    sync.mutex_unlock(&a.lock)
    if len(moved)==0 {return}
    agent_roots(a,heads[:])
    agent_moved(a)
    peers:=peers_live(a)
    defer peers_unpin(a,peers)
    for p in peers {
        theirs:=make([dynamic]Tell_Entry,context.temp_allocator)
        if members {
            // A peer a record lists now was told nothing of that org at its
            // Hello: it is told every head it reads.
            agent_heads(a,p.conn.peer,&theirs)
        } else {
            for m in moved {
                // Derived data goes to the org's servers alone: a member asks for what it needs.
                if role,ok:=agent_role(a,m.org,p.conn.peer);ok && (m.kind!=.Ddc || role==.Node) {append(&theirs,m)}
            }
        }
        if len(theirs)>0 {peer_tell(p,theirs[:])}
    }
    return
}

// Tells each peer where this machine listens (agent_addresses, --public) and
// where the peers it is connected to that share an org with it listen: as
// each said (Peers) and as this end sees it (its address and the port of its
// Hello). Sent when a peer connects or first tells, when who is a member
// moves and when the router answers, never in answer to every Peers, so the
// telling ends.
@(private)
agent_gossip :: proc(a:^Agent) {
    peers:=peers_live(a)
    defer peers_unpin(a,peers)
    if len(peers)==0 {return}
    ids:=team_org_ids(&a.team)
    member:=make([]bool,len(peers)*len(ids),context.temp_allocator)
    for id,k in ids {
        s,e:=team_store(&a.team,id)
        if e!=.None {continue}
        o,_,he:=org_effective_head(s,id,context.temp_allocator)
        if he!=.None {continue}
        for p,i in peers {_,member[i*len(ids)+k]=org_role(&o,p.conn.peer)}
    }
    shares :: proc(member:[]bool,orgs,i,j:int) -> bool {
        for k in 0..<orgs {if member[i*orgs+k] && member[j*orgs+k] {return true}}
        return false
    }
    own:=make([dynamic]Peer_At,context.temp_allocator)
    if a.listening {
        texts:=make([dynamic]string,context.temp_allocator)
        append(&texts,..agent_addresses(a,context.temp_allocator))
        append(&texts,a.options.public)
        for text in texts {
            if at,ok:=peer_at(text);ok && !slice.contains(own[:],at) && len(own)<DIAL_ADDRESSES {append(&own,at)}
        }
    }
    seen:=make([]Peer_At,len(peers),context.temp_allocator)
    for p,i in peers {
        sync.mutex_lock(&p.lock)
        port:=p.port
        sync.mutex_unlock(&p.lock)
        if ip,ok:=p.remote.address.(net.IP4_Address);ok && port>0 && port<=65535 {seen[i]=Peer_At{cast([4]u8)ip,u16le(port)}}
    }
    entries:=make([dynamic]Gossip_Entry,context.temp_allocator)
    for p,i in peers {
        if !shares(member,len(ids),i,i) {continue}
        clear(&entries)
        for at in own {append(&entries,Gossip_Entry{a.team.identity.key,at})}
        for q,j in peers {
            if j==i || !shares(member,len(ids),i,j) {continue}
            key:=q.conn.peer
            if seen[j].port!=0 {append(&entries,Gossip_Entry{key,seen[j]})}
            sync.mutex_lock(&a.lock)
            if h,ok:=a.heard[key];ok {
                for at in h.at[:h.count] {append(&entries,Gossip_Entry{key,at})}
            }
            sync.mutex_unlock(&a.lock)
        }
        n:=min(len(entries),GOSSIP_MAX)
        if n==0 {continue}
        head:=[2]u8{u8(n),u8(n>>8)}
        conn_send(p.conn,.Peers,head[:],slice.to_bytes(entries[:n]))
    }
}

// Keeps where the members a Peers message names listen, for
// agent_dial_members, and wakes it. The handshake proves the key at each, so
// an address proves nothing; a loopback one holds only from a peer on this
// machine, and a loopback agent keeps no other. A peer's first Peers is told
// on, since the other peers learn from it where it says it listens.
@(private)
agent_heard :: proc(a:^Agent,p:^Peer,entries:[]Gossip_Entry) {
    near:=false
    if ip,ok:=p.remote.address.(net.IP4_Address);ok {near=ip[0]==127}
    sync.mutex_lock(&p.lock)
    first:=!p.gossiped
    p.gossiped=true
    sync.mutex_unlock(&p.lock)
    own:=a.team.identity.key
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    wakes:bit_set[Agent_Wake]
    if first {wakes+={.Gossip}}
    for e in entries {
        ip:=e.at.ip
        if e.key==own || ip[0]==0 || ip[0]>=224 {continue}
        if ip[0]==127 {
            if !near {continue}
        } else if a.loopback {
            continue
        }
        h,held:=a.heard[e.key]
        if !held && len(a.heard)>=HEARD_MAX {continue}
        if slice.contains(h.at[:h.count],e.at) {continue}
        h.at[h.next]=e.at
        h.next=(h.next+1)%DIAL_ADDRESSES
        h.count=min(h.count+1,DIAL_ADDRESSES)
        a.heard[e.key]=h
        dial_cooldown_drop(a,e.key)
        wakes+={.Changed}
    }
    a.wakes+=wakes
    sync.cond_broadcast(&a.wake)
}

// The IPv4 address and port of host:port; ok false for anything else.
@(private)
peer_at :: proc(text:string) -> (at:Peer_At,ok:bool) {
    endpoint,parsed:=net.parse_endpoint(text)
    ip,is_ip4:=endpoint.address.(net.IP4_Address)
    if !parsed || !is_ip4 || endpoint.port<=0 || endpoint.port>65535 {return}
    return Peer_At{cast([4]u8)ip,u16le(endpoint.port)},true
}

// Dials every member of its orgs that is not connected, at the addresses it
// was reached at or its beacon said, and the peers the options name: one
// thread per member tries its addresses in turn, never two at once, and at
// most once every REDIAL_SECONDS; a peer of the options goes by its address.
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
            if h,ok:=a.heard[m.key];ok {
                for at in h.at[:h.count] {
                    append(&targets,Target{m.key,m.key,fmt.tprintf("%d.%d.%d.%d:%d",at.ip[0],at.ip[1],at.ip[2],at.ip[3],at.port)})
                }
            }
            sync.mutex_unlock(&a.lock)
        }
    }
    for address in a.options.peers {append(&targets,Target{{},options_key(address),address})}
    Dial :: struct {
        a:^Agent,
        expect:Key,
        throttle:Key,
        addresses:[DIAL_ADDRESSES][ADDRESS_MAX]u8,
        lengths:[DIAL_ADDRESSES]int,
        count:int,
    }
    Group :: struct {throttle:Key,dial:Dial,skip:bool}
    groups:=make([dynamic]Group,context.temp_allocator)
    sync.mutex_lock(&a.lock)
    defer sync.mutex_unlock(&a.lock)
    if sync.atomic_load(&a.stopping) {return}
    // Seen with the dials of this pass Running: the lock is held until they are.
    a.dialed=true
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
            if p.phase!=.Ended {
                if t.expect=={} {
                    dialed,ok:=p.origin.(Peer_Dialed)
                    connected||=ok && dialed.address==t.address
                } else {
                    connected||=p.conn!=nil && p.conn.peer==t.expect
                }
            }
            sync.mutex_unlock(&p.lock)
        }
        d,dialing:=a.dialing[t.throttle]
        waits:=dialing && (d.phase==.Running || now-d.began<REDIAL_SECONDS*i64(time.Second))
        g:=Group{throttle=t.throttle,skip=connected || waits}
        g.dial.a,g.dial.expect,g.dial.throttle=a,t.expect,t.throttle
        g.dial.lengths[0]=copy(g.dial.addresses[0][:],t.address)
        g.dial.count=1
        append(&groups,g)
    }
    for g in groups {
        if g.skip {continue}
        d,de:=new(Dial,a.allocator)
        if de!=nil {continue}
        d^=g.dial
        a.dialing[g.throttle]=Dial_Entry{phase=.Running,began=now}
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
            sync.mutex_lock(&a.lock)
            if x,ok:=&a.dialing[d.throttle];ok {x.phase=.Cooling}
            sync.cond_broadcast(&a.wake)
            sync.mutex_unlock(&a.lock)
            free(d,a.allocator)
        },agent_context(a),self_cleanup=true)
        if th==nil {
            a.dialing[g.throttle]=Dial_Entry{phase=.Cooling,began=now}
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
            dial_cooldown_drop(a,key)
            a.wakes+={.Changed}
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
