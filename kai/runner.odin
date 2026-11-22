package kai

import "base:runtime"
import "core:crypto"
import "core:crypto/x25519"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:time"
import cnet "core:net"
import "mirai:exchange"
import net "mirai:net"
import "mirai:std/blake3"
import "mirai:store"

// The runner: the mesh of one machine over one UDP socket. It holds one
// agent (mesh.odin) per org the machine serves and gives each agent's hosts a
// virtual transport over the socket; every datagram on the socket opens with
// a byte that says what it is:
//
//   S route datagram       net, to the server host of the org of route
//   C route datagram       net, to the client host that sent to this address
//   R to datagram          to a relay node: forward to the device of key to
//   F from datagram        from a relay node: what the device of key from sent
//   Z type from time body mac   rendezvous between a device and a node
//   B beacon               the LAN beacon of beacon.odin
//   P message              pairing (pair.odin)
//   L token id op body     a request of a local process (control.odin), A its answer
//
// route is the first RUNNER_ROUTE bytes of a hash of the org's id, so one
// socket serves every org. A device reaches a peer by the ladder of rungs,
// best first: a LAN address a beacon gave, the global IPv6 and mapped
// addresses a node passed on, the reflexive address a node saw (both ends
// punch at once), then the node's relay, then the node's relay over TCP
// (tcp.odin) when UDP to the node is blocked. A connection on a worse rung is
// replaced when a better one appears. A node is the same runner with modes:
// relay (rendezvous, NAT kind on two ports, forwarding under per-device
// quotas, over UDP and TCP), seed (it mirrors every closure and overlay
// ciphertext) and ddc (it keeps derived data). Nothing polls: data moves by
// the exchange's hints.

RUNNER_ROUTE :: 8
FRAME_MAX :: 1+RELAY_ENVELOPE+1+RUNNER_ROUTE+net.PACKET_BYTES // the longest datagram of the socket
FRAME_SERVER :: u8('S')
FRAME_CLIENT :: u8('C')
FRAME_RELAY :: RELAY_MAGIC
FRAME_FROM :: u8('F')
FRAME_RENDEZVOUS :: u8('Z')
FRAME_BEACON :: u8('B')
FRAME_PAIR :: u8('P')
FRAME_LOCAL :: u8('L')
FRAME_ANSWER :: u8('A')
BEACON_PORT :: 47913
LABEL_ROUTE :: "kai-1/route"
LABEL_RENDEZVOUS :: "kai-1/rendezvous"
RUNNER_ORGS :: MACHINE_ORGS_MAX
RUNNER_PEERS :: 64             // devices and nodes of one org the runner reaches for
HELLO_SECONDS :: 15            // a device greets its nodes, which keeps its NAT mapping open
RETRY_SECONDS :: 30            // after the whole ladder failed
DIAL_SECONDS :: 2              // what a direct rung may take
PLAN_WAIT :: 1.5               // seconds a device waits for a node's plan
RENDEZVOUS_SKEW :: i64(120)*1_000_000_000 // ns a Z message's time may be off
RELAY_RATE :: 4<<20            // bytes per second each device may send through a relay node
RELAY_BURST :: 16<<20
PAIR_RESEND :: 1.0             // seconds between repeats of a pairing message
PAIR_JOIN_SECONDS :: 30        // a joiner gives up on a responder that does not answer
PAIR_TICKET_SECONDS :: 10*60   // a ticket lasts
IDLE_SECONDS :: 120            // an agent with nothing to do for this long may exit

@(private) VIRTUAL_QUEUE :: 128
@(private) BATCH :: 32
@(private) Z_MAC :: 16

Rung :: enum u8 {None,LAN,IPv6,Punched,Relayed,Tcp}

rung_text :: proc(r:Rung) -> string {
    switch r {
    case .None: return "connecting"
    case .LAN: return "lan"
    case .IPv6: return "ipv6"
    case .Punched: return "punched"
    case .Relayed: return "relayed"
    case .Tcp: return "relayed over tcp"
    }
    return ""
}

Runner_Desc :: struct {
    machine:^Machine,            // its store and keys; the runner must not outlive it
    bind:net.Address,            // where the socket listens; zero: every interface (address_any6) at port
    port:int,                    // with a zero bind; 0 lets the system choose
    modes:Node_Modes,            // empty: a device; else what this node serves
    observe_port:int,            // a relay node's second port, which tells a hard NAT; 0 lets the system choose
    beacon:bool,                 // send LAN beacons and listen for them on beacon_port
    beacon_port:int,             // 0: BEACON_PORT; -1: no socket of its own, beacons go through the main one
    beacon_targets:[]net.Address, // where beacons go; empty: the IPv4 broadcast and BEACON_GROUP6 on every interface, at beacon_port
    portmap:bool,                // ask the router for a mapping of the port
    addresses:[]net.Address,     // what tickets and nodes advertise; empty: found from the interfaces
    blocked:[]net.Address,       // tests: addresses the socket neither sends to nor hears from
    control:bool,                // let local processes reach it (control.odin): one runner per store
    host_seed:u64,               // tests: salts of the hosts; 0 from the system
    ddc_quota:i64,               // a ddc node: bytes of derived data outputs it keeps; 0: no bound (node.odin)
    tcp_port:int,                // a relay node: where its relay over TCP listens when no HTTPS listener shares the port (tcp.odin); 0: none, -1: the system picks
    relay_tcp_port:int,          // tests: the TCP port of relay nodes; 0: RELAY_TCP_PORT
    event:Runner_Event,          // what it did, as a line of text
    allocator:runtime.Allocator, // nil: context.allocator
}

Runner_Event :: struct {
    data:rawptr,
    procedure:proc(data:rawptr,text:string),
}

@(private)
Virtual :: struct {
    runner:^Runner,
    org:^Runner_Org,
    client:bool,
    data:[]u8, // VIRTUAL_QUEUE datagrams of FRAME_MAX
    sizes:[VIRTUAL_QUEUE]u16,
    from:[VIRTUAL_QUEUE]net.Address,
    head,count:int,
    sent:[4]net.Address, // where a client host sent last: whose answers are its
    sent_next:int,
}

// A device or node of an org the runner reaches for, and how.
Runner_Peer :: struct {
    dh:Dh_Key,
    node:bool,
    modes:Node_Modes,
    addresses:[NODE_ADDRESSES_MAX]net.Address, // a node's, from its Node_Add
    address_count:int,
    lan:net.Address,      // from its beacon
    lan_seen:f64,
    answered:f64,         // when this end last answered its beacon
    announced:[4]net.Address, // global IPv6 and mapped, from a node's plan
    announced_count:int,
    target:net.Address,   // its reflexive address, from a node's plan
    relay:net.Address,    // the relay address through the node that planned
    planned:f64,
    hard:bool,            // the plan found a hard NAT: punching is futile
    asked:f64,            // when this end asked a node for a plan
    attempt:int,          // the client host of the attempt in flight, -1
    attempt_rung:Rung,
    rung:Rung,            // of the connection this end made
    stage:int,            // the next rung to try
    next_try:f64,
    first:bool,           // this end connects first, whatever the keys: it paired with it
}

Runner_Org :: struct {
    id:Log_Id,
    route:[RUNNER_ROUTE]u8,
    agent:Agent,
    running:bool,
    virtuals:[1+AGENT_CLIENTS]Virtual,
    secret:[32]u8,       // D
    has_secret:bool,
    beacon_secret:[32]u8, // the D its last beacon was keyed by
    refolds:int,         // agent.stats.refolds when the peers were last read
    peers:[dynamic]Runner_Peer,
    beacon_devices:[dynamic]Dh_Key,
    stats:Agent_Stats,   // as last told
    connected:[AGENT_PEERS]bool,
}

@(private)
Shared_Key :: struct {dh:Dh_Key,key:[32]u8}

@(private)
Relay_Seen :: struct {dh:Dh_Key,announced:[4]net.Address,announced_count:int}

@(private)
Relay_Want :: struct {from,peer:Dh_Key,at:f64}

WANT_SECONDS :: 60 // a node plans a meeting for a device that shows up this long after it was asked

Runner :: struct {
    desc:Runner_Desc,
    machine:^Machine,
    allocator:runtime.Allocator,
    udp:net.Udp,
    transport:net.Transport,
    observe:net.Udp,            // a relay node's second port
    beacon_socket:net.Udp,  // IPv4
    beacon_socket6:net.Udp, // IPv6
    has_beacon_socket:bool,
    has_beacon_socket6:bool,
    port:u16,
    start:time.Tick,
    now:f64,
    orgs:[dynamic]^Runner_Org,
    user:Log_Id,                // of the machine when the agents started
    receive:[BATCH][FRAME_MAX]u8,
    keys:[dynamic]Shared_Key,
    relay:Relay,
    relay_seen:[dynamic]Relay_Seen,
    wants:[dynamic]Relay_Want,  // a relay node: who asked for a device not seen yet
    mapping:net.Port_Mapping,
    mapping_on:bool,
    beacon_at:f64,
    hello_at:f64,
    observe_ports:[dynamic]Node_Observe,
    offer:Pair_Offer,
    join:Pair_Join,
    ddc:[dynamic]DDC_Lookup,    // lookups under way, at most DDC_LOOKUPS_MAX
    control:Control_Server,
    active:f64,                 // when it last had something to do
    ddc_use:[dynamic]DDC_Use,   // a ddc node: when each key was last asked through it, at most DDC_USES_MAX
    ddc_found,ddc_missing:int,  // lookups through this runner that ended
    ddc_swept:f64,
    tcp:[dynamic]^Tcp_Stream,   // the relay over TCP: a node's connections from devices, a device's to its nodes
    tcp_listener:cnet.TCP_Socket,
    has_tcp:bool,
    tcp_port:int,
    over_udp:bool,              // what runner_frame reads came over the UDP socket
}

@(private)
Node_Observe :: struct {node:Dh_Key,address:net.Address}

// What a request to pair this machine's user, org or node shows the person
// who answers it.
Pair_Request :: struct {
    mode:Pair_Mode,
    code:string,
    name:string,        // what the other end calls itself
    user:Log_Id,        // Member: the user that joins
    device:Key,
}

Pair_Phase :: enum u8 {None,Asking,Waiting,Approved,Denied,Failed}

// How a pairing this machine joins goes.
Pair_Progress :: struct {
    phase:Pair_Phase,
    code:string,        // once both ends have it
    why:string,         // Failed: what failed and how to fix it
}

@(private)
Pair_Offer :: struct {
    active:bool,
    ticket:Ticket,
    org:Log_Id,
    role:Role,
    modes:Node_Modes,
    gate:Pair_Gate,
    pair:Pair,
    from:net.Address,
    step:Pair_Message,   // what was read last
    shown:bool,          // the code waits for an answer
    last:[FRAME_MAX+PAIR_PAYLOAD_MAX]u8,
    last_len:int,
    name:[NAME_MAX]u8,
    name_len:int,
    info:Pair_Info,
    closes:f64,          // a finished pairing answers repeats until then
}

@(private)
Pair_Join :: struct {
    active:bool,
    ticket:Ticket,
    pair:Pair,
    phase:Pair_Phase,
    to:net.Address,      // the responder, once it answered
    last:[FRAME_MAX]u8,
    last_len:int,
    keys:[PAIR_KEM_PARTS][1+PAIR_K_SIZE]u8, // a device's K frames, sent with each repeat of P3
    key_frames:int,
    sent:f64,
    started:f64,
    name:[NAME_MAX]u8,
    name_len:int,
    why:string,
    code:[PAIR_CODE_TEXT]u8,
}

DDC_State :: enum u8 {Waiting,Found,Missing}

@(private)
DDC_Lookup :: struct {
    org:Log_Id,
    key:store.Hash,
    started:f64,
    asked:bool,
    lan_done:bool,
    queries:[AGENT_PEERS]exchange.Query,
    query_used:[AGENT_PEERS]bool,
    output:store.Hash, // the output_root of a record that came
}

DDC_SECONDS :: 10.0 // a lookup gives up
DDC_LOOKUPS_MAX :: 64 // lookups at once; one more is a miss

// Starts the runner of the machine: its socket, an agent for every org it
// serves, and the control others reach it by.
runner_start :: proc(r:^Runner,desc:Runner_Desc) -> (error:Error) {
    if desc.machine==nil {return .Invalid_Argument}
    r^={desc=desc,machine=desc.machine}
    r.allocator=desc.allocator.procedure==nil?context.allocator:desc.allocator
    allocator:=r.allocator
    r.orgs=make([dynamic]^Runner_Org,allocator)
    r.keys=make([dynamic]Shared_Key,allocator)
    r.relay_seen=make([dynamic]Relay_Seen,allocator)
    r.wants=make([dynamic]Relay_Want,allocator)
    r.observe_ports=make([dynamic]Node_Observe,allocator)
    ddc_error,use_error:runtime.Allocator_Error
    r.ddc,ddc_error=make([dynamic]DDC_Lookup,0,DDC_LOOKUPS_MAX,allocator)
    r.ddc_use,use_error=make([dynamic]DDC_Use,0,DDC_USES_MAX,allocator)
    r.tcp=make([dynamic]^Tcp_Stream,allocator)
    if ddc_error!=nil || use_error!=nil {
        runner_free(r)
        return .Out_Of_Memory
    }
    relay_init(&r.relay,RELAY_RATE,RELAY_BURST,allocator)
    r.start=time.tick_now()
    m:=r.machine
    if desc.control {
        if e:=control_serve(&r.control,&m.store);e!=.None {
            runner_free(r)
            m.why=e==.Locked?"a Kai agent runs for this store already: mirai kai commands reach it":"the agent's lock file does not open: give this user access to the store"
            return e
        }
    }
    bind:=desc.bind
    if bind.kind==.None {bind=net.address_any6(desc.port)}
    if !net.udp_open(&r.udp,bind) {
        runner_free(r)
        m.why="the UDP port does not open: another program holds it, give another with --port"
        return .Io
    }
    r.port=r.udp.address.port
    r.transport=net.udp_transport(&r.udp)
    if .Relay in desc.modes {
        observe:=bind
        observe.port=u16(desc.observe_port)
        if !net.udp_open(&r.observe,observe) {
            runner_free(r)
            m.why="the relay's second UDP port does not open: give another"
            return .Io
        }
    }
    if .Relay in desc.modes && desc.tcp_port!=0 {runner_tcp_listen(r,bind)}
    if desc.beacon && desc.beacon_port>=0 {
        port:=desc.beacon_port==0?BEACON_PORT:desc.beacon_port
        r.has_beacon_socket=beacon_socket_open(&r.beacon_socket,port,false)
        r.has_beacon_socket6=beacon_socket_open(&r.beacon_socket6,port,true)
    }
    if m.changed.procedure==nil {m.changed=runner_machine_changed(r)}
    if desc.portmap && desc.modes=={} {r.mapping_on=net.mapping_start(&r.mapping,r.port,allocator)}
    if desc.control {control_publish(&r.control,r.port)}
    runner_reload(r)
    r.beacon_at=-1
    r.hello_at=-1
    return .None
}

runner_stop :: proc(r:^Runner) {
    for o in r.orgs {runner_org_close(r,o)}
    runner_free(r)
}

@(private)
runner_free :: proc(r:^Runner) {
    if r.mapping_on {net.mapping_close(&r.mapping)}
    net.udp_close(&r.udp)
    net.udp_close(&r.observe)
    net.udp_close(&r.beacon_socket)
    net.udp_close(&r.beacon_socket6)
    control_end(&r.control)
    pair_end(&r.offer.pair)
    pair_end(&r.join.pair)
    relay_destroy(&r.relay)
    runner_tcp_close(r)
    delete(r.orgs)
    delete(r.keys)
    delete(r.relay_seen)
    delete(r.wants)
    delete(r.observe_ports)
    delete(r.ddc)
    delete(r.ddc_use)
    r^={}
}

// The port the socket listens on.
runner_port :: proc(r:^Runner) -> int {return int(r.port)}

@(private)
runner_event :: proc(r:^Runner,format:string,args:..any) {
    if r.desc.event.procedure==nil {return}
    r.desc.event.procedure(r.desc.event.data,fmt.tprintf(format,..args))
}

@(private)
route_of :: proc(org:Log_Id) -> (route:[RUNNER_ROUTE]u8) {
    h:blake3.Hasher
    blake3.init(&h)
    blake3.update(&h,transmute([]u8)string(LABEL_ROUTE))
    id:=org
    blake3.update(&h,id[:])
    sum:=blake3.final(&h)
    copy(route[:],sum[:RUNNER_ROUTE])
    return
}

// Starts an agent for every org the machine serves now, and stops those of
// the orgs it left; all of them when the machine's user changed.
runner_reload :: proc(r:^Runner) {
    m:=r.machine
    // The machines this end paired with stay its first peers when its user changes (a recovery).
    kept:=make([dynamic]struct{org:Log_Id,peer:Runner_Peer},context.temp_allocator)
    if m.user!=r.user {
        for o in r.orgs {
            for p in o.peers {
                if p.first {append(&kept,struct{org:Log_Id,peer:Runner_Peer}{o.id,Runner_Peer{dh=p.dh,first=true,lan=p.lan,lan_seen=p.lan_seen,attempt=-1}})}
            }
            runner_org_close(r,o)
        }
        clear(&r.orgs)
        r.user=m.user
    }
    for k:=0;k<len(r.orgs); {
        if slice.contains(m.orgs[:],r.orgs[k].id) {
            k+=1
            continue
        }
        runner_org_close(r,r.orgs[k])
        ordered_remove(&r.orgs,k)
    }
    for id in m.orgs {
        found:=false
        for o in r.orgs {found||=o.id==id}
        if found || len(r.orgs)>=RUNNER_ORGS {continue}
        if o:=runner_org_open(r,id);o!=nil {append(&r.orgs,o)}
    }
    for k in kept {
        for o in r.orgs {
            if o.id==k.org && runner_peer_index(o,k.peer.dh)<0 && len(o.peers)<RUNNER_PEERS {append(&o.peers,k.peer)}
        }
    }
}

@(private)
runner_org_open :: proc(r:^Runner,id:Log_Id) -> ^Runner_Org {
    allocator:=r.allocator
    o,e0:=new(Runner_Org,allocator)
    if e0!=nil {return nil}
    o.id,o.route=id,route_of(id)
    o.peers=make([dynamic]Runner_Peer,allocator)
    o.beacon_devices=make([dynamic]Dh_Key,allocator)
    clients:[AGENT_CLIENTS]net.Transport
    for &v,k in o.virtuals {
        v={runner=r,org=o,client=k>0}
        data,e:=make([]u8,VIRTUAL_QUEUE*FRAME_MAX,allocator)
        if e!=nil {
            runner_org_free(r,o)
            return nil
        }
        v.data=data
        if k>0 {clients[k-1]=virtual_transport(&v)}
    }
    m:=r.machine
    e:=agent_init(&o.agent,{
        store=&m.store,identity=m.identity,dh=m.dh,user=m.user,org=id,server=virtual_transport(&o.virtuals[0]),
        seed=r.desc.modes=={} || .Seed in r.desc.modes,host_seed=r.desc.host_seed,connect_timeout=DIAL_SECONDS,allocator=allocator,
    },clients[:])
    if e!=.None {
        runner_org_free(r,o)
        return nil
    }
    o.running=true
    hex:[64]u8
    runner_event(r,"serving org %s",store.hex(id,&hex)[:12])
    return o
}

@(private)
runner_org_close :: proc(r:^Runner,o:^Runner_Org) {
    if o.running {agent_close(&o.agent)}
    runner_org_free(r,o)
}

@(private)
runner_org_free :: proc(r:^Runner,o:^Runner_Org) {
    for &v in o.virtuals {delete(v.data,r.allocator)}
    delete(o.peers)
    delete(o.beacon_devices)
    free(o,r.allocator)
}

// A ref this machine wrote: the agents read it again and tell their peers.
runner_changed :: proc(r:^Runner,namespace,name:string) {
    r.active=r.now
    if namespace==MACHINE_NAMESPACE {
        machine_reload(r.machine)
        runner_reload(r)
        return
    }
    for o in r.orgs {agent_changed(&o.agent,namespace,name)}
}

// What Machine.changed calls when the machine is the runner's own: it reaches
// the agents directly, so only the runner's thread writes through that machine.
runner_machine_changed :: proc(r:^Runner) -> Machine_Changed {
    return {data=r,procedure=proc(data:rawptr,namespace,name:string) {runner_changed((^Runner)(data),namespace,name)}}
}

// One step: what arrived, the agents, the ladder, beacons and pairing. It
// waits for the socket up to wait seconds first.
runner_update :: proc(r:^Runner,wait:f64=0) {
    if wait>0 {r.transport.wait(r.transport.data,wait)}
    r.now=time.duration_seconds(time.tick_since(r.start))
    runner_receive(r,&r.udp,0)
    runner_tcp_step(r)
    if .Relay in r.desc.modes {runner_receive(r,&r.observe,1)}
    if r.has_beacon_socket {runner_receive(r,&r.beacon_socket,2)}
    if r.has_beacon_socket6 {runner_receive(r,&r.beacon_socket6,2)}
    for o in r.orgs {
        agent_update(&o.agent,r.now)
        runner_org_watch(r,o)
        if r.desc.modes=={} {runner_ladder(r,o)}
    }
    runner_beacons(r)
    runner_hellos(r)
    runner_pair_step(r)
    runner_ddc_step(r)
    runner_ddc_quota(r)
    if r.offer.active || r.join.active || len(r.ddc)>0 {r.active=r.now}
    for o in r.orgs {
        n,_:=agent_peers(&o.agent)
        if n>0 {r.active=r.now}
    }
}

// Runs until stop is set, or until it was idle IDLE_SECONDS when idle_exit.
runner_run :: proc(r:^Runner,stop:^bool,idle_exit:bool) {
    for !stop^ {
        runner_update(r,0.02)
        if idle_exit && r.now-r.active>IDLE_SECONDS {return}
    }
}

// What changed in the agent of org o, as events: peers that came and went,
// and what it took from them.
@(private)
runner_org_watch :: proc(r:^Runner,o:^Runner_Org) {
    a:=&o.agent
    if a.stats.refolds!=o.refolds {
        o.refolds=a.stats.refolds
        runner_org_peers(r,o)
    }
    for p,i in a.peers {
        if p.used==o.connected[i] {continue}
        o.connected[i]=p.used
        hex:[64]u8
        d:=p.dh
        if p.used {
            r.hello_at=-1
            runner_event(r,"peer %s connected (%s, %v)",store.hex(transmute(store.Hash)d,&hex)[:12],rung_text(runner_peer_rung(r,o,i)),p.class)
        } else {
            runner_event(r,"peer %s left",store.hex(transmute(store.Hash)d,&hex)[:12])
        }
    }
    s:=a.stats
    if s.refs_accepted!=o.stats.refs_accepted {runner_event(r,"took %d device refs",s.refs_accepted-o.stats.refs_accepted)}
    if s.logs_merged!=o.stats.logs_merged {runner_event(r,"merged %d logs",s.logs_merged-o.stats.logs_merged)}
    if s.ddc_accepted!=o.stats.ddc_accepted {runner_event(r,"took %d derived data records",s.ddc_accepted-o.stats.ddc_accepted)}
    if s.overlays_accepted!=o.stats.overlays_accepted {runner_event(r,"took %d private overlays",s.overlays_accepted-o.stats.overlays_accepted)}
    if s.behind!=o.stats.behind {
        if s.behind>0 {
            runner_event(r,"behind the org's logs: %d entries peers named are not here yet; their writes wait until a peer gives them",s.behind)
        } else {
            runner_event(r,"no longer behind the org's logs")
        }
    }
    if s.unfound!=o.stats.unfound {runner_event(r,"let go of %d entries peers named that never came",s.unfound-o.stats.unfound)}
    if s.refs_accepted!=o.stats.refs_accepted || s.objects_fetched!=o.stats.objects_fetched {runner_bookmarks_event(r,o)}
    if (s.ddc_accepted!=o.stats.ddc_accepted || s.objects_fetched!=o.stats.objects_fetched) && .DDC in r.desc.modes {runner_ddc_mirror(r,o)}
    o.stats=s
}

// A ddc node keeps every object of the outputs of the derived data it holds,
// so members take them when their producer is away.
@(private)
runner_ddc_mirror :: proc(r:^Runner,o:^Runner_Org) {
    ns:[len(DDC_PREFIX)+64]u8
    refs,e:=store.ref_list(&r.machine.store,ddc_namespace(o.id,&ns),context.temp_allocator)
    if e!=.None {return}
    records:=make([dynamic][]u8,context.temp_allocator)
    lacking:=make([dynamic]store.Hash,context.temp_allocator)
    for ref in refs {
        clear(&records)
        if ddc_set_read(&r.machine.store,ref.hash,&records)!=.None {continue}
        for bytes in records {
            d,de:=ddc_record_decode(bytes)
            if de!=.None {continue}
            clear(&lacking)
            ddc_output_lacking(&r.machine.store,d.output_root,&lacking)
            for l in lacking {agent_want_object(&o.agent,l)}
        }
    }
}

// The bookmarks of other devices the store holds, and whether each change is
// whole here.
@(private)
runner_bookmarks_event :: proc(r:^Runner,o:^Runner_Org) {
    a:=&o.agent
    if !a.folded || r.desc.event.procedure==nil {return}
    for p in a.org.projects {
        ns:[len(REFS_PREFIX)+64]u8
        refs,e:=store.ref_list(a.desc.store,refs_namespace(p.id,&ns),context.temp_allocator)
        if e!=.None {continue}
        for ref in refs {
            bytes,ge:=object_get(a.desc.store,ref.hash,.Device_Refs,context.temp_allocator)
            if ge!=.None {continue}
            d,de:=device_refs_decode(bytes,context.temp_allocator)
            if de!=.None || d.device==r.machine.identity.key {continue}
            for b in d.refs {
                present:=make([dynamic]store.Hash,context.temp_allocator)
                missing:=make([dynamic]store.Hash,context.temp_allocator)
                closure_walk(a.desc.store,{b.target},&present,&missing)
                c,ce:=change_get(a.desc.store,b.target,context.temp_allocator)
                id:=c.id
                hex,project,device:[64]u8
                pid,dk:=p.id,d.device
                runner_event(r,"project %s device %s: %s -> change %s %s",store.hex(pid,&project)[:12],store.hex(transmute(store.Hash)dk,&device)[:12],b.name,ce==.None?hex_text(id[:6],hex[:]):"(not here)",len(missing)==0?"whole":fmt.tprintf("fetching, %d objects missing",len(missing)))
            }
        }
    }
}

// Who the org's log says this runner reaches for: every active device of a
// member but its own, and every node; the beacon's devices with them. A
// machine that holds a grant of the org reaches first for its issuer, and,
// being no member, connects to every peer itself.
@(private)
runner_org_peers :: proc(r:^Runner,o:^Runner_Org) {
    a:=&o.agent
    clear(&o.beacon_devices)
    o.has_secret=a.folded
    issuers:=make([dynamic]Runner_Peer,context.temp_allocator)
    held:=make([dynamic]Held_Grant,context.temp_allocator)
    machine_grants_held(&r.machine.store,&held)
    now:=time.now()._nsec
    for &h in held {
        if h.grant.org!=o.id || now>h.grant.not_after {continue}
        p:=Runner_Peer{dh=h.text.issuer,attempt=-1,first=true}
        p.address_count=copy(p.addresses[:],h.text.addresses[:h.text.address_count])
        append(&issuers,p)
    }
    if !a.folded {
        for p in issuers {
            if runner_peer_index(o,p.dh)<0 && len(o.peers)<RUNNER_PEERS {append(&o.peers,p)}
        }
        return
    }
    o.secret=org_discovery(&a.org)
    mine:=Dh_Key(r.machine.dh.public)
    holder:=r.machine.user=={} || org_role(&a.org,r.machine.user)==.None
    wanted:=make([dynamic]Runner_Peer,context.temp_allocator)
    for u in a.user_list {
        if org_role(&a.org,u.log.id)==.None {continue}
        for d in u.devices {
            if d.revoked {continue}
            append(&o.beacon_devices,d.dh)
            if d.dh!=mine {append(&wanted,Runner_Peer{dh=d.dh,attempt=-1,first=holder})}
        }
    }
    for n in a.org.nodes {
        append(&o.beacon_devices,n.dh)
        if n.dh==mine {continue}
        p:=Runner_Peer{dh=n.dh,node=true,modes=n.modes,attempt=-1,first=holder}
        list:=make([dynamic]net.Address,context.temp_allocator)
        org_node_addresses(&a.org,n,&list)
        p.address_count=copy(p.addresses[:],list[:])
        append(&wanted,p)
    }
    for &p in issuers {
        k:=-1
        for w,i in wanted {
            if w.dh==p.dh {k=i}
        }
        if k<0 {
            append(&wanted,p)
        } else if wanted[k].address_count==0 {
            wanted[k].address_count=copy(wanted[k].addresses[:],p.addresses[:p.address_count])
        }
    }
    // What was learned of a peer that stays stays.
    for &w in wanted {
        for old in o.peers {
            if old.dh!=w.dh {continue}
            // One store per value until odin-lang/Odin#7937.
            fresh:=w
            w=old
            w.addresses=fresh.addresses
            w.address_count=fresh.address_count
            w.node=fresh.node
            w.modes=fresh.modes
            w.first=fresh.first || old.first
        }
    }
    clear(&o.peers)
    for w in wanted {
        if len(o.peers)<RUNNER_PEERS {append(&o.peers,w)}
    }
    r.hello_at=-1
}

@(private)
runner_peer_index :: proc(o:^Runner_Org,dh:Dh_Key) -> int {
    for p,i in o.peers {
        if p.dh==dh {return i}
    }
    return -1
}

// The rung of the agent's peer i: the one its attempt took, or what the
// address of a connection the other end made says.
@(private)
runner_peer_rung :: proc(r:^Runner,o:^Runner_Org,i:int) -> Rung {
    p:=&o.agent.peers[i]
    if !p.used {return .None}
    if p.client>=0 {
        for q in o.peers {
            if q.dh!=p.dh || q.rung==.None {continue}
            if q.rung==.Relayed && runner_tcp_carries(r,q.relay) {return .Tcp}
            return q.rung
        }
    }
    stats,ok:=net.connection_stats(p.host,p.connection)
    if !ok {return .None}
    if runner_tcp_carries(r,stats.address) {return .Tcp}
    return rung_of(stats.address)
}

// Whether a connection of the relay over TCP carries what goes to address:
// to a node, or to a peer it relays to.
@(private)
runner_tcp_carries :: proc(r:^Runner,address:net.Address) -> bool {
    to:=address
    if address.kind==.Relay {
        node,_,ok:=net.address_relay_node(address)
        if !ok {return false}
        to=node
    }
    for s in r.tcp {
        if !s.failed && s.address==to && (s.link || s.greeted) {return true}
    }
    return false
}

// An address as IPv4 a.b.c.d:port or [IPv6]:port.
address_text :: proc(a:net.Address) -> string {
    endpoint,ok:=net.address_to_endpoint(a)
    if !ok {return "?"}
    return cnet.endpoint_to_string(endpoint,context.temp_allocator)
}

@(private)
rung_of :: proc "contextless" (a:net.Address) -> Rung {
    switch {
    case a.kind==.Relay: return .Relayed
    case a.kind==.IP6 && net.address_global(a): return .IPv6
    case net.address_global(a): return .Punched
    }
    return .LAN
}

// The connection the agent has to dh: its peer index and whether this end made it.
@(private)
runner_connection :: proc(o:^Runner_Org,dh:Dh_Key) -> (index:int,found:bool) {
    best:=-1
    for p,i in o.agent.peers {
        if !p.used || p.dh!=dh {continue}
        if best<0 || p.client>=0 {best=i}
    }
    return best,best>=0
}

// The ladder: for each peer this end connects to, the next rung to try, and
// a better rung over the one it holds.
@(private)
runner_ladder :: proc(r:^Runner,o:^Runner_Org) {
    for &p in o.peers {runner_ladder_peer(r,o,&p)}
}

@(private)
runner_ladder_peer :: proc(r:^Runner,o:^Runner_Org,p:^Runner_Peer) {
    a:=&o.agent
    if p.attempt>=0 {
        for q,i in a.peers {
            if !q.used || q.client!=p.attempt {continue}
            // The new connection holds: the one it replaces goes.
            for old,k in a.peers {
                if k!=i && old.used && old.dh==p.dh && old.client>=0 {agent_drop(a,k)}
            }
            p.rung,p.attempt,p.stage=p.attempt_rung,-1,0
            return
        }
        if !agent_client_busy(a,p.attempt) {
            p.attempt=-1
            p.stage+=1
        }
        return
    }
    lan_fresh:=p.lan.kind!=.None && r.now-p.lan_seen<3*BEACON_SECONDS
    if k,connected:=runner_connection(o,p.dh);connected {
        if a.peers[k].client>=0 && p.rung>.LAN && lan_fresh {runner_dial(r,o,p,rung_of(p.lan),p.lan)}
        return
    }
    p.rung=.None
    if !p.node && !p.first && !dh_less(Dh_Key(r.machine.dh.public),p.dh) {return}
    if r.now<p.next_try {return}
    planned:=p.planned>0 && r.now-p.planned<RETRY_SECONDS
    for p.stage<=int(Rung.Tcp) {
        dialed:=false
        switch Rung(p.stage) {
        case .None:
        case .LAN:
            if lan_fresh {
                dialed=runner_dial(r,o,p,rung_of(p.lan),p.lan)
            } else if p.address_count>0 {
                // What goes to a node its TCP connection carries is the TCP rung.
                if l:=runner_tcp_link(r,p.addresses[0]);l!=nil && !l.failed {break}
                dialed=runner_dial(r,o,p,rung_of(p.addresses[0]),..p.addresses[:min(p.address_count,2)])
            }
        case .IPv6:
            if p.node {break}
            // A node of the org plans: where the peer says it is, and where it saw it.
            if !planned {
                if p.asked>0 && r.now-p.asked<PLAN_WAIT {return}
                if p.asked<=p.planned {
                    sent,waiting:=runner_want(r,o,p.dh)
                    if sent {p.asked=max(r.now,1e-6)}
                    if sent || waiting {return}
                }
            }
            if p.announced_count>0 {dialed=runner_dial(r,o,p,rung_of(p.announced[0]),..p.announced[:min(p.announced_count,2)])}
        case .Punched:
            if !p.node && !p.hard && p.target.kind!=.None && planned {dialed=runner_dial(r,o,p,.Punched,p.target)}
        case .Relayed:
            if !p.node && p.relay.kind==.Relay && planned {dialed=runner_dial(r,o,p,.Relayed,p.relay)}
        case .Tcp:
            // UDP to the relay node failed: its relay over TCP.
            if !p.node || .Relay not_in p.modes || p.address_count==0 {break}
            l:=runner_tcp_link(r,p.addresses[0])
            if l!=nil && l.failed {
                runner_tcp_drop(r,l)
                break
            }
            if l==nil {
                if !runner_tcp_open(r,p.dh,p.addresses[0]) {break}
                return
            }
            if l.connecting {return}
            dialed=runner_dial(r,o,p,.Tcp,p.addresses[0])
        }
        if dialed {return}
        p.stage+=1
    }
    p.stage=0
    p.asked=0
    p.next_try=r.now+RETRY_SECONDS
}

@(private)
runner_dial :: proc(r:^Runner,o:^Runner_Org,p:^Runner_Peer,rung:Rung,addresses:..net.Address) -> bool {
    if p.attempt>=0 {return false}
    k,e:=agent_dial(&o.agent,p.dh,false,..addresses)
    if e!=.None {return false}
    p.attempt,p.attempt_rung=k,rung
    return true
}

// Asks a relay node of the org to plan how this end meets dh; waiting while
// the org has one this end is still connecting to.
@(private)
runner_want :: proc(r:^Runner,o:^Runner_Org,dh:Dh_Key) -> (sent,waiting:bool) {
    for p in o.peers {
        if !p.node || .Relay not_in p.modes || p.address_count==0 {continue}
        k,connected:=runner_connection(o,p.dh)
        if !connected || o.agent.peers[k].class!=.Node {
            waiting||=p.attempt>=0 || p.next_try<=r.now
            continue
        }
        body:=dh
        runner_z_send(r,p.dh,p.addresses[0],.Want,mem.ptr_to_bytes(&body))
        return true,false
    }
    return false,waiting
}

// The beacons of every org this device serves, every BEACON_SECONDS.
@(private)
runner_beacons :: proc(r:^Runner) {
    if !r.desc.beacon || r.desc.modes!={} {return}
    fresh:=false
    for o in r.orgs {fresh||=o.has_secret && o.secret!=o.beacon_secret}
    if !fresh && r.beacon_at>=0 && r.now-r.beacon_at<BEACON_SECONDS {return}
    r.beacon_at=r.now
    unix:=time.now()._nsec/1_000_000_000
    targets:=r.desc.beacon_targets
    if len(targets)==0 {
        // The IPv4 broadcast, and the link-local multicast of every interface
        // with IPv6, which reaches a LAN without IPv4 or that drops broadcasts.
        port:=r.desc.beacon_port<=0?BEACON_PORT:r.desc.beacon_port
        all:=make([dynamic]net.Address,context.temp_allocator)
        append(&all,net.address_ip4(255,255,255,255,port))
        indexes:=make([dynamic]u32,context.temp_allocator)
        interfaces6(&indexes)
        for index in indexes {append(&all,net.Address{kind=.IP6,port=u16(port),ip=BEACON_GROUP6,zone=index})}
        targets=all[:]
    }
    for o in r.orgs {
        if !o.has_secret {continue}
        o.beacon_secret=o.secret
        b:=beacon_make(&o.secret,Dh_Key(r.machine.dh.public),r.port,unix)
        frame:[1+BEACON_BYTES]u8
        frame[0]=FRAME_BEACON
        copy(frame[1:],b[:])
        for t in targets {
            switch {
            case t.kind==.IP4 && r.has_beacon_socket: runner_send_on(r,&r.beacon_socket,t,frame[:])
            case t.kind==.IP6 && r.has_beacon_socket6: runner_send_on(r,&r.beacon_socket6,t,frame[:])
            case: runner_send(r,t,frame[:])
            }
        }
    }
}

@(private)
runner_beacon_read :: proc(r:^Runner,from:net.Address,bytes:[]u8) {
    unix:=time.now()._nsec/1_000_000_000
    for o in r.orgs {
        if !o.has_secret {continue}
        k,port,found:=beacon_read(&o.secret,o.beacon_devices[:],bytes,unix)
        if !found || o.beacon_devices[k]==Dh_Key(r.machine.dh.public) {continue}
        i:=runner_peer_index(o,o.beacon_devices[k])
        if i<0 {continue}
        p:=&o.peers[i]
        lan:=from
        lan.port=port
        // A device heard over IPv4 and IPv6 keeps the address it was heard
        // at first while that one is fresh.
        if p.lan.kind!=.None && p.lan.kind!=lan.kind && r.now-p.lan_seen<2*BEACON_SECONDS {lan=p.lan}
        if p.lan!=lan {
            hex:[64]u8
            d:=p.dh
            runner_event(r,"beacon of %s at %s",store.hex(transmute(store.Hash)d,&hex)[:12],address_text(lan))
            if p.attempt<0 && p.rung!=.LAN {p.stage,p.next_try=0,0}
        }
        p.lan,p.lan_seen=lan,r.now
        // The end that does not dial answers, so a beacon the other missed does not wait a round.
        _,connected:=runner_connection(o,p.dh)
        if !connected && dh_less(p.dh,Dh_Key(r.machine.dh.public)) && (p.answered==0 || r.now-p.answered>BEACON_SECONDS) {
            p.answered=r.now
            frame:[1+BEACON_BYTES]u8
            frame[0]=FRAME_BEACON
            b:=beacon_make(&o.secret,Dh_Key(r.machine.dh.public),r.port,unix)
            copy(frame[1:],b[:])
            runner_send(r,lan,frame[:])
        }
    }
}

// A device greets the relay nodes of its orgs, on both of their ports.
@(private)
runner_hellos :: proc(r:^Runner) {
    if r.desc.modes!={} {return}
    if r.hello_at>=0 && r.now-r.hello_at<HELLO_SECONDS {return}
    r.hello_at=r.now
    announced:=runner_announced(r)
    for o in r.orgs {
        for p in o.peers {
            if !p.node || .Relay not_in p.modes || p.address_count==0 {continue}
            runner_hello(r,p.dh,p.addresses[0],0,announced[:])
            for ob in r.observe_ports {
                if ob.node==p.dh {runner_hello(r,p.dh,ob.address,1,announced[:])}
            }
        }
    }
}

@(private)
runner_hello :: proc(r:^Runner,node:Dh_Key,to:net.Address,port:u8,announced:[]Node_Address) {
    body:[2+4*size_of(Node_Address)]u8
    body[0],body[1]=port,u8(len(announced))
    copy(body[2:],slice.to_bytes(announced))
    runner_z_send(r,node,to,.Hello,body[:2+len(announced)*size_of(Node_Address)])
}

// The addresses this device tells its nodes others may reach it at: its
// global IPv6 and its mapping.
@(private)
runner_announced :: proc(r:^Runner) -> [dynamic]Node_Address {
    out:=make([dynamic]Node_Address,context.temp_allocator)
    if len(r.desc.addresses)>0 {
        for a in r.desc.addresses {
            if n,ok:=node_address_of(a);ok && len(out)<4 {append(&out,n)}
        }
        return out
    }
    if g:=net.address_global6(int(r.port));g.kind!=.None {
        if n,ok:=node_address_of(g);ok {append(&out,n)}
    }
    if r.mapping_on {
        status:=net.mapping_poll(&r.mapping)
        if status.phase==.Mapped {
            if n,ok:=node_address_of(status.external);ok {append(&out,n)}
        }
    }
    return out
}

// What tickets advertise: the given addresses, or this machine's loopback,
// LAN and global ones with the socket's port. Loopback comes first: a system
// firewall that holds a new program's incoming traffic until someone allows
// it (macOS does) never holds it, so two stores of one machine pair anyway.
runner_addresses :: proc(r:^Runner,out:^[dynamic]net.Address) {
    if len(r.desc.addresses)>0 {
        append(out,..r.desc.addresses)
        return
    }
    append(out,net.address_loopback(int(r.port)))
    interfaces,e:=cnet.enumerate_interfaces(context.temp_allocator)
    if e==nil {
        for interface in interfaces {
            if cnet.Link_States.Up not_in interface.link.state {continue}
            for lease in interface.unicast {
                ip4,is_ip4:=lease.address.(cnet.IP4_Address)
                if !is_ip4 || ip4[0]==127 {continue}
                append(out,net.address_ip4(ip4[0],ip4[1],ip4[2],ip4[3],int(r.port)))
            }
        }
    }
    if g:=net.address_global6(int(r.port));g.kind!=.None {append(out,g)}
    if r.mapping_on {
        if status:=net.mapping_poll(&r.mapping);status.phase==.Mapped {append(out,status.external)}
    }
}

// Datagrams of the socket u (0 main, 1 a relay node's second port, 2 beacons).
@(private)
runner_receive :: proc(r:^Runner,u:^net.Udp,port:int) {
    t:=net.udp_transport(u)
    r.over_udp=port==0
    defer r.over_udp=false
    for {
        batch:[BATCH]net.Datagram
        for &d,i in batch {d.bytes=r.receive[i][:]}
        n:=t.receive(t.data,batch[:])
        for d in batch[:n] {
            if runner_blocked(r,d.address) {continue}
            runner_frame(r,d.address,d.bytes,port)
        }
        if n<BATCH {return}
    }
}

@(private)
runner_blocked :: proc(r:^Runner,a:net.Address) -> bool {
    for b in r.desc.blocked {
        if b.kind==a.kind && b.ip==a.ip && b.port==a.port {return true}
    }
    return false
}

// One datagram of the socket: hostile bytes are dropped.
runner_frame :: proc(r:^Runner,from:net.Address,bytes:[]u8,port:int) {
    if len(bytes)<2 || len(bytes)>FRAME_MAX {return}
    switch bytes[0] {
    case FRAME_SERVER,FRAME_CLIENT:
        if port!=0 || len(bytes)<1+RUNNER_ROUTE+1 {return}
        runner_deliver(r,from,bytes[0]==FRAME_SERVER,bytes[1:1+RUNNER_ROUTE],bytes[1+RUNNER_ROUTE:])
    case FRAME_RELAY:
        if port==0 && .Relay in r.desc.modes {runner_forward(r,from,bytes)}
    case FRAME_FROM:
        if port!=0 || len(bytes)<1+32+1+RUNNER_ROUTE+1 {return}
        inner:=bytes[33:]
        if inner[0]!=FRAME_SERVER && inner[0]!=FRAME_CLIENT {return}
        peer:net.Key
        copy(peer[:],bytes[1:33])
        relayed,ok:=net.address_relay(from,peer)
        if !ok {return}
        runner_deliver(r,relayed,inner[0]==FRAME_SERVER,inner[1:1+RUNNER_ROUTE],inner[1+RUNNER_ROUTE:])
    case FRAME_RENDEZVOUS: runner_z_read(r,from,bytes,port)
    case FRAME_BEACON:
        if len(bytes)==1+BEACON_BYTES {runner_beacon_read(r,from,bytes[1:])}
    case FRAME_PAIR:
        if port==0 {runner_pair_read(r,from,bytes[1:])}
    case FRAME_LOCAL:
        if port==0 {control_read(r,from,bytes)}
    }
}

// Hands a net datagram to the host it is for.
@(private)
runner_deliver :: proc(r:^Runner,from:net.Address,server:bool,route,datagram:[]u8) {
    if len(datagram)>net.PACKET_BYTES {return}
    for o in r.orgs {
        if !bytes_equal(o.route[:],route) {continue}
        if server {
            virtual_push(&o.virtuals[0],from,datagram)
            return
        }
        for &v in o.virtuals[1:] {
            if slice.contains(v.sent[:],from) {
                virtual_push(&v,from,datagram)
                return
            }
        }
        return
    }
}

// Sends over the relay's TCP connection that stands for to, else over UDP.
@(private)
runner_send :: proc(r:^Runner,to:net.Address,bytes:[]u8) {
    if len(r.tcp)>0 && runner_tcp_send(r,to,bytes) {return}
    runner_send_on(r,&r.udp,to,bytes)
}

@(private)
runner_send_on :: proc(r:^Runner,u:^net.Udp,to:net.Address,bytes:[]u8) {
    if runner_blocked(r,to) {return}
    t:=net.udp_transport(u)
    batch:=[1]net.Datagram{{to,bytes}}
    t.send(t.data,batch[:])
}

@(private)
virtual_transport :: proc(v:^Virtual) -> net.Transport {
    return {data=v,send=virtual_send,receive=virtual_receive}
}

@(private)
virtual_push :: proc(v:^Virtual,from:net.Address,datagram:[]u8) {
    if v.count==VIRTUAL_QUEUE {return}
    k:=(v.head+v.count)%VIRTUAL_QUEUE
    copy(v.data[k*FRAME_MAX:][:FRAME_MAX],datagram)
    v.sizes[k],v.from[k]=u16(len(datagram)),from
    v.count+=1
}

@(private)
virtual_receive :: proc(data:rawptr,batch:[]net.Datagram) -> int {
    v:=(^Virtual)(data)
    n:=0
    for n<len(batch) && v.count>0 {
        size:=int(v.sizes[v.head])
        if size>len(batch[n].bytes) {size=len(batch[n].bytes)}
        copy(batch[n].bytes,v.data[v.head*FRAME_MAX:][:size])
        batch[n].bytes=batch[n].bytes[:size]
        batch[n].address=v.from[v.head]
        v.head=(v.head+1)%VIRTUAL_QUEUE
        v.count-=1
        n+=1
    }
    return n
}

@(private)
virtual_send :: proc(data:rawptr,batch:[]net.Datagram) -> int {
    v:=(^Virtual)(data)
    r:=v.runner
    frame:[FRAME_MAX]u8
    for d in batch {
        if len(d.bytes)>net.PACKET_BYTES {continue}
        if v.client && !slice.contains(v.sent[:],d.address) {
            v.sent[v.sent_next]=d.address
            v.sent_next=(v.sent_next+1)%len(v.sent)
        }
        inner:=frame[RELAY_ENVELOPE:]
        inner[0]=v.client?FRAME_SERVER:FRAME_CLIENT
        copy(inner[1:],v.org.route[:])
        copy(inner[1+RUNNER_ROUTE:],d.bytes)
        size:=1+RUNNER_ROUTE+len(d.bytes)
        if d.address.kind==.Relay {
            node,peer,ok:=net.address_relay_node(d.address)
            if !ok {continue}
            frame[0]=FRAME_RELAY
            copy(frame[1:],peer[:])
            runner_send(r,node,frame[:RELAY_ENVELOPE+size])
        } else {
            runner_send(r,d.address,inner[:size])
        }
    }
    return len(batch)
}

// A relay node forwards what a device it admitted sent to another.
@(private)
runner_forward :: proc(r:^Runner,from:net.Address,bytes:[]u8) {
    sender:Dh_Key
    known:=false
    for d in r.relay.devices {
        if d.seen[0] && d.observed[0]==from {
            sender,known=d.dh,true
            break
        }
    }
    if !known {return}
    to,datagram,ok:=relay_forward(&r.relay,sender,bytes,r.now)
    if !ok || len(datagram)<1+RUNNER_ROUTE+1 {return}
    k:=relay_find(&r.relay,to)
    if k<0 || !r.relay.devices[k].seen[0] {return}
    frame:[FRAME_MAX]u8
    frame[0]=FRAME_FROM
    s:=sender
    copy(frame[1:],s[:])
    n:=copy(frame[33:],datagram)
    runner_send(r,r.relay.devices[k].observed[0],frame[:33+n])
}

Z_Type :: enum u8 {None,Hello,Welcome,Want,Plan,Punch,Probe}

@(private)
Z_Head :: struct #packed {
    frame:u8,
    type:Z_Type,
    from:Dh_Key,
    time:i64,
}

@(private)
Z_Plan :: struct #packed {
    peer:Dh_Key,
    initiator:b8,
    hard:b8,
    target:Node_Address,
    count:u8,
} // + [count]Node_Address announced

@(private)
Z_Welcome :: struct #packed {
    observe_port:u16,
    observed:Node_Address,
}

// The key a device and a node authenticate rendezvous messages under.
@(private)
runner_shared :: proc(r:^Runner,dh:Dh_Key) -> (key:[32]u8,ok:bool) {
    for k in r.keys {
        if k.dh==dh {return k.key,true}
    }
    shared:[32]u8
    defer crypto.zero_explicit(&shared,32)
    d:=dh
    x25519.scalarmult(shared[:],r.machine.dh.private[:],d[:])
    zero:[32]u8
    if crypto.compare_constant_time(shared[:],zero[:])==1 {return {},false}
    h:blake3.Hasher
    blake3.init(&h)
    blake3.update(&h,shared[:])
    blake3.update(&h,transmute([]u8)string(LABEL_RENDEZVOUS))
    key=blake3.final(&h)
    if len(r.keys)>=1024 {clear(&r.keys)}
    append(&r.keys,Shared_Key{dh,key})
    return key,true
}

@(private)
runner_z_send :: proc(r:^Runner,to_dh:Dh_Key,to:net.Address,type:Z_Type,body:[]u8,udp:=false) {
    key,ok:=runner_shared(r,to_dh)
    if !ok || len(body)>512 {return}
    frame:[size_of(Z_Head)+512+Z_MAC]u8
    head:=Z_Head{frame=FRAME_RENDEZVOUS,type=type,from=Dh_Key(r.machine.dh.public),time=time.now()._nsec}
    copy(frame[:],mem.ptr_to_bytes(&head))
    copy(frame[size_of(Z_Head):],body)
    size:=size_of(Z_Head)+len(body)
    mac:=keyed_hash(key[:],frame[:size])
    copy(frame[size:],mac[:Z_MAC])
    if udp {
        runner_send_on(r,&r.udp,to,frame[:size+Z_MAC])
    } else {
        runner_send(r,to,frame[:size+Z_MAC])
    }
}

@(private)
runner_z_read :: proc(r:^Runner,from:net.Address,bytes:[]u8,port:int) {
    if len(bytes)<size_of(Z_Head)+Z_MAC {return}
    head:=(^Z_Head)(raw_data(bytes))^
    if head.type==.Punch || head.type<.Hello || head.type>.Probe {return}
    now:=time.now()._nsec
    if abs(now-head.time)>RENDEZVOUS_SKEW {return}
    key,ok:=runner_shared(r,head.from)
    if !ok {return}
    size:=len(bytes)-Z_MAC
    mac:=keyed_hash(key[:],bytes[:size])
    if crypto.compare_constant_time(mac[:Z_MAC],bytes[size:])!=1 {return}
    body:=bytes[size_of(Z_Head):size]
    if .Relay in r.desc.modes {
        runner_node_z(r,from,head,body,port)
    } else if port==0 && runner_is_node(r,head.from) {
        runner_device_z(r,from,head,body)
    }
}

// Whether dh is a relay node of an org this device serves.
@(private)
runner_is_node :: proc(r:^Runner,dh:Dh_Key) -> bool {
    for o in r.orgs {
        for p in o.peers {
            if p.dh==dh && p.node && .Relay in p.modes {return true}
        }
    }
    return false
}

// Whether dh is a member's device or a node of an org this node serves.
@(private)
runner_admitted :: proc(r:^Runner,dh:Dh_Key) -> bool {
    for o in r.orgs {
        class:=agent_class_of(&o.agent,dh)
        if class==.Member || class==.Node {return true}
    }
    return false
}

@(private)
runner_node_z :: proc(r:^Runner,from:net.Address,head:Z_Head,body:[]u8,port:int) {
    #partial switch head.type {
    case .Probe:
        // Answered the way it came: over UDP, a device on TCP learns UDP works again.
        if len(body)==0 && port==0 && runner_admitted(r,head.from) {runner_z_send(r,head.from,from,.Probe,nil)}
    case .Hello:
        if len(body)<2 || body[0]!=u8(port) || len(body)!=2+int(body[1])*size_of(Node_Address) || body[1]>4 {return}
        if !runner_admitted(r,head.from) {
            relay_remove(&r.relay,head.from)
            return
        }
        if relay_admit(&r.relay,head.from,r.now)!=.None {return}
        relay_observe(&r.relay,head.from,port,from)
        if port!=0 {return}
        seen:Relay_Seen
        seen.dh=head.from
        for a in slice.reinterpret([]Node_Address,body[2:]) {
            if n,ok:=node_address_net(a);ok && seen.announced_count<len(seen.announced) {
                seen.announced[seen.announced_count]=n
                seen.announced_count+=1
            }
        }
        found:=false
        for &s in r.relay_seen {
            if s.dh==head.from {
                // One store per value until odin-lang/Odin#7937.
                s=seen
                found=true
            }
        }
        if !found && len(r.relay_seen)<RELAY_DEVICES_MAX {append(&r.relay_seen,seen)}
        welcome:=Z_Welcome{observe_port=r.observe.address.port}
        welcome.observed,_=node_address_of(from)
        runner_z_send(r,head.from,from,.Welcome,mem.ptr_to_bytes(&welcome))
        // Who waited for this device meets it now.
        for k:=0;k<len(r.wants); {
            w:=r.wants[k]
            if r.now-w.at>WANT_SECONDS || w.peer==head.from {
                unordered_remove(&r.wants,k)
                if w.peer==head.from && r.now-w.at<=WANT_SECONDS {runner_plan(r,w.from,w.peer)}
                continue
            }
            k+=1
        }
    case .Want:
        if port!=0 || len(body)!=size_of(Dh_Key) {return}
        peer:=(^Dh_Key)(raw_data(body))^
        if runner_plan(r,head.from,peer) || relay_find(&r.relay,head.from)<0 {return}
        for w in r.wants {
            if w.from==head.from && w.peer==peer {return}
        }
        if len(r.wants)<RELAY_DEVICES_MAX {append(&r.wants,Relay_Want{head.from,peer,r.now})}
    }
}

// Tells a and b how to meet; false while either was not seen.
@(private)
runner_plan :: proc(r:^Runner,a,b:Dh_Key) -> bool {
    plan,ok:=relay_rendezvous(&r.relay,a,b)
    if !ok {return false}
    {
        for side in 0..<2 {
            me:=side==0?plan.initiator:plan.responder
            other:=side==0?plan.responder:plan.initiator
            k:=relay_find(&r.relay,me)
            if k<0 {continue}
            z:Z_Plan
            z.peer,z.initiator,z.hard=other,b8(side==0),b8(plan.relay)
            z.target,_=node_address_of(side==0?plan.initiator_target:plan.responder_target)
            out:[size_of(Z_Plan)+4*size_of(Node_Address)]u8
            for &s in r.relay_seen {
                if s.dh!=other {continue}
                for a in s.announced[:s.announced_count] {
                    if n,valid:=node_address_of(a);valid {
                        copy(out[size_of(Z_Plan)+int(z.count)*size_of(Node_Address):],mem.ptr_to_bytes(&n))
                        z.count+=1
                    }
                }
            }
            copy(out[:],mem.ptr_to_bytes(&z))
            runner_z_send(r,me,r.relay.devices[k].observed[0],.Plan,out[:size_of(Z_Plan)+int(z.count)*size_of(Node_Address)])
        }
    }
    return true
}

@(private)
runner_device_z :: proc(r:^Runner,from:net.Address,head:Z_Head,body:[]u8) {
    #partial switch head.type {
    case .Probe:
        if len(body)!=0 || !r.over_udp {return}
        if l:=runner_tcp_link(r,from);l!=nil && !l.failed && l.node==head.from {runner_tcp_upgrade(r,l)}
    case .Welcome:
        if len(body)!=size_of(Z_Welcome) {return}
        w:=(^Z_Welcome)(raw_data(body))^
        if w.observe_port==0 {return}
        observe:=from
        observe.port=w.observe_port
        for &ob in r.observe_ports {
            if ob.node==head.from {
                if ob.address!=observe {
                    ob.address=observe
                    runner_hello(r,head.from,observe,1,runner_announced(r)[:])
                }
                return
            }
        }
        if len(r.observe_ports)<RUNNER_ORGS*4 {
            append(&r.observe_ports,Node_Observe{head.from,observe})
            runner_hello(r,head.from,observe,1,runner_announced(r)[:])
        }
    case .Plan:
        if len(body)<size_of(Z_Plan) {return}
        z:=(^Z_Plan)(raw_data(body))^
        if z.count>4 || len(body)!=size_of(Z_Plan)+int(z.count)*size_of(Node_Address) {return}
        target,_:=node_address_net(z.target)
        relayed,_:=net.address_relay(from,net.Key(z.peer))
        for o in r.orgs {
            k:=runner_peer_index(o,z.peer)
            if k<0 {continue}
            p:=&o.peers[k]
            p.target,p.hard,p.relay,p.planned=target,bool(z.hard),relayed,r.now
            p.announced_count=0
            for a in slice.reinterpret([]Node_Address,body[size_of(Z_Plan):]) {
                if n,ok:=node_address_net(a);ok {
                    p.announced[p.announced_count]=n
                    p.announced_count+=1
                }
            }
            if !bool(z.initiator) && !bool(z.hard) && target.kind!=.None {
                // The responder opens its NAT toward the initiator.
                punch:=Z_Head{frame=FRAME_RENDEZVOUS,type=.Punch,from=Dh_Key(r.machine.dh.public)}
                for _ in 0..<3 {runner_send(r,target,mem.ptr_to_bytes(&punch))}
            }
            // A fresh plan starts the ladder again past the LAN rung.
            if bool(z.initiator) && p.attempt<0 {p.stage,p.next_try=int(Rung.IPv6),0}
        }
    }
}

// The peers of every org, and how each is reached.
Runner_Peer_Info :: struct {
    org:Log_Id,
    dh:Dh_Key,
    class:Agent_Class,
    rung:Rung,
    node:bool,
}

// How current an org's agent is: the entries of the org's logs peers named
// that are not here yet (writes wait while there are any), and those let go
// after BEHIND_SECONDS.
Runner_Org_Info :: struct {org:Log_Id,behind,unfound:int}

runner_orgs_info :: proc(r:^Runner,out:^[dynamic]Runner_Org_Info) {
    for o in r.orgs {append(out,Runner_Org_Info{o.id,o.agent.stats.behind,o.agent.stats.unfound})}
}

runner_peers :: proc(r:^Runner,out:^[dynamic]Runner_Peer_Info) {
    for o in r.orgs {
        for p,i in o.agent.peers {
            if !p.used {continue}
            info:=Runner_Peer_Info{org=o.id,dh=p.dh,class=p.class,rung=runner_peer_rung(r,o,i)}
            if k:=runner_peer_index(o,p.dh);k>=0 {info.node=o.peers[k].node}
            append(out,info)
        }
    }
}

// Offers a pairing: the ticket the other device takes, valid for
// PAIR_TICKET_SECONDS. Device links a second device of this machine's user;
// Member adds a user to org with role; Node adds a node with modes.
runner_pair_offer :: proc(r:^Runner,mode:Pair_Mode,org:Log_Id,role:Role,modes:Node_Modes,buffer:^[TICKET_TEXT]u8) -> (ticket:string,error:Error) {
    m:=r.machine
    switch mode {
    case .Device:
        if m.user=={} {return "",machine_fail(m,.Invalid_Argument,"this device has no user to link another device to: mirai kai identity makes one")}
    case .Member:
        if !role_valid(role) {return "",machine_fail(m,.Invalid_Argument,"a member's role is reader, writer or admin")}
        if !slice.contains(m.orgs[:],org) {return "",machine_fail(m,.Invalid_Argument,"this machine does not serve that org")}
    case .Node:
        if modes=={} {return "",machine_fail(m,.Invalid_Argument,"a node serves relay, seed or ddc")}
        if !slice.contains(m.orgs[:],org) {return "",machine_fail(m,.Invalid_Argument,"this machine does not serve that org")}
    case .Recover:
        if !slice.contains(m.orgs[:],org) {return "",machine_fail(m,.Invalid_Argument,"this machine does not serve that org")}
    }
    if r.offer.active && r.offer.shown {return "",machine_fail(m,.Locked,"another pairing request waits for an answer: answer it first")}
    pair_end(&r.offer.pair)
    gate:=r.offer.gate
    r.offer={active=true,org=org,role=role,modes=modes,gate=gate}
    t:=&r.offer.ticket
    t.id=random_id([16]u8)
    t.responder=Dh_Key(m.dh.public)
    t.mode=mode
    t.expires=time.now()._nsec+i64(PAIR_TICKET_SECONDS)*1_000_000_000
    list:=make([dynamic]net.Address,context.temp_allocator)
    runner_addresses(r,&list)
    // A node or a device on this same machine reaches it by loopback, which
    // a host firewall lets through where it drops the LAN address.
    if loopback:=net.address_ip4(127,0,0,1,int(r.port));!slice.contains(list[:],loopback) {
        inject_at(&list,min(len(list),TICKET_ADDRESSES-1),loopback)
    }
    t.address_count=copy(t.addresses[:],list[:])
    return ticket_encode(t^,buffer),.None
}

// The open request, once the other end revealed its keys and the code exists.
runner_pair_request :: proc(r:^Runner) -> (request:Pair_Request,ok:bool) {
    o:=&r.offer
    if !o.active || !o.shown {return}
    return {mode=o.ticket.mode,code=pair_code(&o.pair),name=string(o.name[:o.name_len]),user=o.info.log_id,device=o.info.device},true
}

// The person's answer to the open request; when code is given it must be the
// one shown, or the request is denied.
runner_pair_answer :: proc(r:^Runner,approve:bool,code:string="") -> Error {
    m:=r.machine
    o:=&r.offer
    if !o.active || !o.shown {return machine_fail(m,.Missing,"no pairing request waits for an answer")}
    now:=time.now()._nsec
    yes:=approve && (code=="" || code==pair_code(&o.pair))
    payload:=make([dynamic]u8,context.temp_allocator)
    if yes {
        switch o.ticket.mode {
        case .Device:
            l:Log
            log_init(&l,m.user,context.temp_allocator)
            if e:=log_open(&m.store,&l,m.user,.User);e!=.None {return machine_fail(m,e,"this device's User_Log is not in its store")}
            if _,e:=pair_approve_device(&o.pair,&l,&m.identity,now);e!=.None {return machine_fail(m,e,"the device's proof does not hold: pair again")}
            machine_log_save(m,&l) or_return
            id:=m.user
            append(&payload,..id[:])
            for org in m.orgs {
                g:=org
                append(&payload,..g[:])
            }
        case .Member:
            machine_member_add(m,o.org,o.info.log_id,o.role) or_return
            id:=o.org
            append(&payload,..id[:])
        case .Node:
            machine_node_add(m,o.org,o.info.device,pair_remote(&o.pair),o.modes,{o.from}) or_return
            id:=o.org
            append(&payload,..id[:])
        case .Recover:
            // Nothing is signed: the other machine reaches the org as a peer
            // not admitted, which reads the user logs alone, until its user
            // is recovered onto it.
            id:=o.org
            append(&payload,..id[:])
        }
    }
    runner_pair_finish(r,yes?.Approved:.Denied,payload[:])
    if approve && !yes {return machine_fail(m,.Unauthorized,"the code is not the one the other device shows: the request is denied, pair again")}
    return .None
}

@(private)
runner_pair_finish :: proc(r:^Runner,status:Pair_Status,payload:[]u8) {
    o:=&r.offer
    message,e:=pair_write_p4(&o.pair,status,payload,o.last[1:])
    if e==.None {
        o.last[0]=FRAME_PAIR
        o.last_len=1+len(message)
        runner_send(r,o.from,o.last[:o.last_len])
    }
    pair_gate_close(&o.gate,status==.Approved,time.now()._nsec)
    o.shown=false
    o.closes=r.now+PAIR_JOIN_SECONDS
    runner_event(r,"pairing %v",status)
}

// Joins a pairing with the ticket another machine offered; name is what this
// end calls itself. runner_pair_progress tells how it goes.
runner_pair_join :: proc(r:^Runner,text:string,name:string) -> Error {
    m:=r.machine
    t,ok:=ticket_decode(strings.trim_space(text))
    if !ok {return machine_fail(m,.Corrupt,"the ticket does not read: copy it again, whole")}
    if t.expires<time.now()._nsec {return machine_fail(m,.Expired,"the ticket expired: ask for a new one")}
    if t.address_count==0 {return machine_fail(m,.Invalid_Argument,"the ticket names no address to reach the other machine at")}
    if !name_valid(name) {return machine_fail(m,.Invalid_Argument,"a name is 1 to 64 bytes of text")}
    switch t.mode {
    case .Device: if m.user!={} {return machine_fail(m,.Invalid_Argument,"this device belongs to a user already: only a device without one is linked")}
    case .Member: if m.user=={} {return machine_fail(m,.Invalid_Argument,"this device has no user: mirai kai identity makes one first")}
    case .Recover: if m.user!={} {return machine_fail(m,.Invalid_Argument,"this device belongs to a user already: a user is recovered onto a device that has none")}
    case .Node:
    }
    if r.join.active {return machine_fail(m,.Locked,"this machine is joining another pairing: wait for it to end")}
    pair_end(&r.join.pair)
    r.join={active=true,ticket=t,phase=.Asking,started=r.now}
    r.join.name_len=copy(r.join.name[:],name)
    pair_init(&r.join.pair,true,m.dh,t.id,t.responder)
    message,e:=pair_write_p1(&r.join.pair,r.join.last[1:])
    if e!=.None {return machine_fail(m,.Invalid_Argument,pair_error_text(e))}
    r.join.last[0]=FRAME_PAIR
    r.join.last_len=1+len(message)
    runner_pair_resend(r)
    return .None
}

runner_pair_progress :: proc(r:^Runner) -> Pair_Progress {
    j:=&r.join
    p:=Pair_Progress{phase=j.phase,why=j.why}
    if j.code[0]!=0 {p.code=string(j.code[:])}
    return p
}

@(private)
runner_pair_resend :: proc(r:^Runner) {
    j:=&r.join
    j.sent=r.now
    if j.to.kind!=.None {
        runner_send(r,j.to,j.last[:j.last_len])
        for k in 0..<j.key_frames {runner_send(r,j.to,j.keys[k][:])}
        return
    }
    for a in j.ticket.addresses[:j.ticket.address_count] {runner_send(r,a,j.last[:j.last_len])}
}

@(private)
runner_pair_fail :: proc(r:^Runner,why:string) {
    j:=&r.join
    j.phase,j.why,j.active=.Failed,why,false
    pair_end(&j.pair)
    runner_event(r,"pairing failed: %s",why)
}

@(private)
runner_pair_step :: proc(r:^Runner) {
    j:=&r.join
    if j.active {
        limit:=j.phase==.Waiting?f64(PAIR_TIMEOUT/1_000_000_000):PAIR_JOIN_SECONDS
        if r.now-j.started>limit {
            runner_pair_fail(r,"the other machine did not answer: check that its agent runs and the ticket's addresses reach it")
        } else if r.now-j.sent>PAIR_RESEND {
            runner_pair_resend(r)
        }
    }
    o:=&r.offer
    if o.active {
        now:=time.now()._nsec
        if o.shown && pair_gate_expire(&o.gate,now) {
            runner_pair_finish(r,.Denied,nil)
        }
        if !o.shown && o.closes>0 && r.now>o.closes {o.active=false}
        if now>o.ticket.expires && !o.shown {o.active=false}
    }
}

// A pairing message from from.
@(private)
runner_pair_read :: proc(r:^Runner,from:net.Address,message:[]u8) {
    if len(message)<PAIR_HEAD {return}
    switch Pair_Message(message[0]) {
    case .None:
    case .P1,.P3,.K: runner_pair_responder(r,from,message)
    case .P2,.P4: runner_pair_initiator(r,from,message)
    }
}

@(private)
runner_pair_responder :: proc(r:^Runner,from:net.Address,message:[]u8) {
    m:=r.machine
    o:=&r.offer
    if !o.active || !bytes_equal(message[1:PAIR_HEAD],o.ticket.id[:]) {return}
    now:=time.now()._nsec
    // A repeat of what was answered gets the same answer.
    if o.step>=Pair_Message(message[0]) && from==o.from {
        if o.last_len>0 {runner_send(r,from,o.last[:o.last_len])}
        return
    }
    if o.closes>0 {return}
    switch Pair_Message(message[0]) {
    case .P1:
        if now>o.ticket.expires || o.step!=.None {return}
        if pair_gate_open(&o.gate,o.ticket.id,now)!=.None {return}
        pair_init(&o.pair,false,m.dh,o.ticket.id)
        if pair_read_p1(&o.pair,message)!=.None {
            pair_gate_close(&o.gate,false,now)
            pair_end(&o.pair)
            return
        }
        info:=Pair_Info{mode=o.ticket.mode,log_id=o.ticket.mode==.Device?m.user:o.org,device=m.identity.key}
        buffer:[PAIR_INFO_MAX]u8
        out,e:=pair_write_p2(&o.pair,pair_info_encode(info,"",&buffer),o.last[1:])
        if e!=.None {return}
        o.last[0]=FRAME_PAIR
        o.last_len=1+len(out)
        o.from,o.step=from,.P1
        runner_send(r,from,o.last[:o.last_len])
    case .P3:
        if o.step!=.P1 || from!=o.from {return}
        e:=pair_read_p3(&o.pair,message)
        if e!=.None {
            runner_event(r,"pairing refused: %s",pair_error_text(e))
            pair_gate_close(&o.gate,false,now)
            pair_end(&o.pair)
            o.step=.None
            return
        }
        info,name,ok:=pair_info_decode(pair_info(&o.pair))
        if !ok || info.mode!=o.ticket.mode || (info.mode==.Member && info.log_id=={}) {
            pair_gate_close(&o.gate,false,now)
            pair_end(&o.pair)
            o.step=.None
            return
        }
        o.info=info
        o.name_len=copy(o.name[:],name)
        o.step=.P3
        // A device shows once its ML-KEM key came whole in the K frames.
        if info.mode!=.Device {runner_pair_show(r)}
    case .K:
        if o.step!=.P3 || from!=o.from {return}
        if o.shown {
            runner_send(r,from,o.last[:o.last_len])
            return
        }
        complete,e:=pair_read_key(&o.pair,message,o.info.kem)
        if e==.Key {
            runner_event(r,"pairing refused: %s",pair_error_text(e))
            pair_gate_close(&o.gate,false,now)
            pair_end(&o.pair)
            o.step=.None
            return
        }
        if complete {runner_pair_show(r)}
    case .None,.P2,.P4:
    }
}

// Shows the open request: its code waits for the person's answer.
@(private)
runner_pair_show :: proc(r:^Runner) {
    o:=&r.offer
    o.shown=true
    runner_event(r,"pairing request from %s: code %s",string(o.name[:o.name_len]),pair_code(&o.pair))
    out,_:=pair_write_p4(&o.pair,.Pending,nil,o.last[1:])
    o.last[0]=FRAME_PAIR
    o.last_len=1+len(out)
    runner_send(r,o.from,o.last[:o.last_len])
}

@(private)
runner_pair_initiator :: proc(r:^Runner,from:net.Address,message:[]u8) {
    m:=r.machine
    j:=&r.join
    if !j.active {return}
    switch Pair_Message(message[0]) {
    case .P2:
        if j.phase!=.Asking || j.pair.step!=.P1 {return}
        if e:=pair_read_p2(&j.pair,message);e!=.None {
            runner_pair_fail(r,pair_error_text(e))
            return
        }
        remote,_,ok:=pair_info_decode(pair_info(&j.pair))
        if !ok || remote.mode!=j.ticket.mode {
            runner_pair_fail(r,"the other machine answers another kind of pairing: ask for a new ticket")
            return
        }
        info:=Pair_Info{mode=j.ticket.mode,device=m.identity.key}
        switch j.ticket.mode {
        case .Device:
            info.kem=machine_kem_hash(m)
            info.proof=device_proof(&m.identity,transmute([32]u8)remote.log_id,Dh_Key(m.dh.public),info.kem)
        case .Member: info.log_id=m.user
        case .Node,.Recover:
        }
        buffer:[PAIR_INFO_MAX]u8
        out,e:=pair_write_p3(&j.pair,pair_info_encode(info,string(j.name[:j.name_len]),&buffer),j.last[1:])
        if e!=.None {
            runner_pair_fail(r,pair_error_text(e))
            return
        }
        j.last_len=1+len(out)
        if j.ticket.mode==.Device {
            kem:=machine_kem_public(m)
            for k in 0..<PAIR_KEM_PARTS {
                j.keys[k][0]=FRAME_PAIR
                pair_write_key(&j.pair,&kem,k,j.keys[k][1:])
            }
            j.key_frames=PAIR_KEM_PARTS
        }
        j.to,j.phase,j.code=from,.Waiting,j.pair.code
        runner_pair_resend(r)
        runner_event(r,"pairing code %s: check that the other machine shows the same",string(j.code[:]))
    case .P4:
        if j.phase!=.Waiting || from!=j.to {return}
        status,payload,e:=pair_read_p4(&j.pair,message)
        if e!=.None {return}
        switch status {
        case .Pending: j.started=r.now
        case .Denied:
            runner_pair_fail(r,"the other machine denied the pairing: compare the codes and pair again")
            j.phase=.Denied
        case .Approved:
            if runner_pair_take(r,payload) {
                j.phase,j.active=.Approved,false
                runner_event(r,"pairing approved")
            }
        }
    case .None,.P1,.P3,.K:
    }
}

// What an approved pairing gave: the user this device joins and its orgs,
// or the org this member or node joins.
@(private)
runner_pair_take :: proc(r:^Runner,payload:[]u8) -> bool {
    m:=r.machine
    j:=&r.join
    if len(payload)<32 || len(payload)%32!=0 || len(payload)/32>MACHINE_ORGS_MAX+1 {
        runner_pair_fail(r,"the other machine's answer does not read: pair again")
        return false
    }
    ids:=slice.reinterpret([]Log_Id,payload)
    orgs:=ids
    if j.ticket.mode==.Device {
        if machine_user_set(m,ids[0])!=.None {
            runner_pair_fail(r,m.why)
            return false
        }
        orgs=ids[1:]
    }
    for id in orgs {
        if machine_org_join(m,id)!=.None {
            runner_pair_fail(r,m.why)
            return false
        }
    }
    runner_reload(r)
    // This end connects to the machine it paired with, whatever the keys say.
    for o in r.orgs {
        if !slice.contains(orgs,o.id) {continue}
        k:=runner_peer_index(o,j.ticket.responder)
        if k<0 && len(o.peers)<RUNNER_PEERS {
            append(&o.peers,Runner_Peer{dh=j.ticket.responder,attempt=-1})
            k=len(o.peers)-1
        }
        if k<0 {continue}
        p:=&o.peers[k]
        p.first,p.lan,p.lan_seen,p.stage,p.next_try=true,j.to,r.now,0,0
    }
    return true
}

// Looks for what a peer built for key in the org: what the store holds, then
// LAN peers, then the rest; once a record is here every object its output
// lists is fetched. Found with the record's output_root once they are all
// whole here; Missing when DDC_SECONDS pass, or when no peer has one of them.
runner_ddc_ask :: proc(r:^Runner,org:Log_Id,key:store.Hash) -> (state:DDC_State,output_root:store.Hash) {
    served:^Runner_Org
    for o in r.orgs {
        if o.id==org {served=o}
    }
    if served==nil {return .Missing,{}}
    if .DDC in r.desc.modes {runner_ddc_touch(r,org,key)}
    records:=make([dynamic]DDC_Record,context.temp_allocator)
    ddc_lookup(&r.machine.store,org,key,&records)
    // The first output whole here, else what the first one that reads lacks.
    lacking:=make([dynamic]store.Hash,context.temp_allocator)
    wanted:store.Hash
    for d in records {
        clear(&lacking)
        if _,e:=ddc_output_lacking(&r.machine.store,d.output_root,&lacking);e!=.None {continue}
        if len(lacking)==0 {
            runner_ddc_end(r,org,key)
            r.ddc_found+=1
            return .Found,d.output_root
        }
        wanted=d.output_root
        break
    }
    for &l in r.ddc {
        if l.org!=org || l.key!=key {continue}
        if r.now-l.started>DDC_SECONDS {
            runner_ddc_end(r,org,key)
            r.ddc_missing+=1
            return .Missing,{}
        }
        if wanted!={} {
            l.output=wanted
            given_up:=true
            for m in lacking {
                agent_want_object(&served.agent,m)
                progress,known:=exchange.progress(&served.agent.x,m)
                given_up&&=known && progress.state==.Missing
            }
            // Every peer was asked for what the output lacks and none has it.
            if given_up {
                runner_ddc_end(r,org,key)
                r.ddc_missing+=1
                return .Missing,{}
            }
        }
        // Every peer answered and none had it, nor is a record on its way.
        if l.output=={} && l.lan_done && len(served.agent.fetches)==0 {
            asking:=false
            for used in l.query_used {asking||=used}
            if !asking {
                runner_ddc_end(r,org,key)
                r.ddc_missing+=1
                return .Missing,{}
            }
        }
        return .Waiting,{}
    }
    if len(r.ddc)>=DDC_LOOKUPS_MAX {
        runner_event(r,"a derived data lookup is refused: %d run at once, so the cook makes it itself",DDC_LOOKUPS_MAX)
        r.ddc_missing+=1
        return .Missing,{}
    }
    l:=DDC_Lookup{org=org,key=key,started=r.now,output=wanted}
    for m in lacking {agent_want_object(&served.agent,m)}
    append(&r.ddc,l)
    return .Waiting,{}
}

// Asks the org's peers for the object at address: true once it is whole here.
runner_object_ask :: proc(r:^Runner,org:Log_Id,address:store.Hash) -> bool {
    if address=={} {return false}
    if object_whole(&r.machine.store,address) {return true}
    for o in r.orgs {
        if o.id==org {agent_want_object(&o.agent,address)}
    }
    return false
}

// Whether every chunk of the object at address is in the store.
object_whole :: proc(s:^store.Store,address:store.Hash) -> bool {
    buffer,e:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
    if e!=nil {return false}
    return chunk_whole(s,address,buffer,0)
}

@(private)
chunk_whole :: proc(s:^store.Store,address:store.Hash,buffer:[]u8,depth:int) -> bool {
    if depth>store.NODE_LEVEL_MAX {return false}
    bytes,e:=store.chunk_read(s,address,buffer)
    if e!=.None {return false}
    n,parse_error:=store.node_parse(bytes)
    if parse_error!=.None {return false}
    entries,clone_error:=slice.clone(n.entries,context.temp_allocator)
    if clone_error!=nil {return false}
    level:=n.level
    for entry in entries {
        if level==0 {
            if !store.chunk_here(s,entry.address) {return false}
        } else if !chunk_whole(s,entry.address,buffer,depth+1) {
            return false
        }
    }
    return true
}

@(private)
runner_ddc_end :: proc(r:^Runner,org:Log_Id,key:store.Hash) {
    for k:=0;k<len(r.ddc);k+=1 {
        l:=&r.ddc[k]
        if l.org!=org || l.key!=key {continue}
        for o in r.orgs {
            if o.id!=org {continue}
            for &q,i in l.queries {
                if l.query_used[i] {exchange.query_end(&o.agent.x,q)}
            }
        }
        unordered_remove(&r.ddc,k)
        return
    }
}

// The asks of lookups that have no record yet: LAN peers first, the rest
// when none of those had one.
@(private)
runner_ddc_step :: proc(r:^Runner) {
    for &l in r.ddc {
        if l.output!={} {continue}
        o:^Runner_Org
        for x in r.orgs {
            if x.id==l.org {o=x}
        }
        if o==nil {continue}
        a:=&o.agent
        ns_buffer:[len(DDC_PREFIX)+64]u8
        ns:=ddc_namespace(l.org,&ns_buffer)
        name_buffer:[64]u8
        name:=store.hex(l.key,&name_buffer)
        waiting:=false
        for &q,i in l.queries {
            if !l.query_used[i] {continue}
            result,known:=exchange.query_result(&a.x,q)
            if known && result.state==.Waiting {
                waiting=true
                continue
            }
            if known && result.state==.Found {agent_want(a,ns,name,result.address)}
            exchange.query_end(&a.x,q)
            l.query_used[i]=false
        }
        if waiting {continue}
        if l.asked && l.lan_done {continue}
        lan:=!l.asked
        for p,i in a.peers {
            if !p.used || (p.class!=.Member && p.class!=.Node) {continue}
            if (runner_peer_rung(r,o,i)==.LAN)!=lan {continue}
            q,e:=exchange.ref_ask(&a.x,ns,name,p.host,p.connection)
            if e!=.None {continue}
            l.queries[i],l.query_used[i]=q,true
        }
        if l.asked {l.lan_done=true}
        l.asked=true
    }
}

// The beacon socket of IPv4, which takes the broadcast, or of IPv6, which
// takes BEACON_GROUP6 on every interface. Two processes of one user share the
// port, as a broadcast or a multicast reaches every one. Both feed one path,
// runner_frame.
@(private)
beacon_socket_open :: proc(u:^net.Udp,port:int,ip6:bool) -> bool {
    u^={}
    socket,e:=cnet.make_unbound_udp_socket(ip6?.IP6:.IP4)
    if e!=nil {return false}
    cnet.set_option(socket,.Reuse_Address,true)
    socket_share_port(socket)
    bound:net.Address
    if ip6 {
        bound=net.address_any6(port)
        if !socket_ip6_only(socket) {
            cnet.close(socket)
            return false
        }
    } else {
        bound=net.address_ip4(0,0,0,0,port)
        cnet.set_option(socket,.Broadcast,true)
    }
    endpoint,_:=net.address_to_endpoint(bound)
    if cnet.bind(socket,endpoint)!=nil || cnet.set_blocking(socket,false)!=nil {
        cnet.close(socket)
        return false
    }
    if ip6 {
        // An interface that refuses the group still sends there.
        indexes:=make([dynamic]u32,context.temp_allocator)
        interfaces6(&indexes)
        for index in indexes {socket_join6(socket,BEACON_GROUP6,index)}
    }
    waker,waker_error:=cnet.make_unbound_udp_socket(.IP4)
    if waker_error!=nil {
        cnet.close(socket)
        return false
    }
    u.socket,u.waker,u.open,u.address=socket,waker,true,bound
    return true
}
