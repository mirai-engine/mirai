package hub

import "base:runtime"
import "core:crypto"
import "core:crypto/x509"
import "core:net"
import "core:strings"
import "core:time"
import "mirai:kai"
import "mirai:net/tls"

// KaiHub: the web view of a Kai node, served by the node itself. Browsers
// speak HTTP/1.1 over TLS 1.3 (net/tls), with certificates ordered and renewed
// by ACME on the same port; plain HTTP is served only on loopback, for
// development and tests. The hub runs in the node's thread, between steps of
// its runner, and reads what the runner's agents hold: the logs and their
// folds, the refs of the projects and the objects of their closures. A public
// project is readable by anyone; a private one only by a session of a member
// of its org. The server never holds a scope key, so private overlays stay
// ciphertext and no route reads them.
//
// A session starts with a passkey's assertion of a challenge the server gave,
// or with an approval a device of the user signs (mirai kai web approve). A
// write is an entry of a log signed by the browser's passkey over the BLAKE3
// of its bytes, or by the device that approves it; the server checks it as
// every peer does, appends it and tells the peers. It signs nothing itself.

CONNECTIONS_MAX :: 128
CONNECTIONS_PER_ADDRESS :: 16
HEAD_SECONDS :: 10.0     // a request's head must arrive whole within this
BODY_SECONDS :: 30.0     // and its body
IDLE_SECONDS :: 60.0     // a connection between requests
WRITE_SECONDS :: 60.0    // an answer the peer does not take
RESPONSE_SECONDS :: 180.0 // an answer must be taken whole within this
HANDSHAKE_SECONDS :: 10.0
SESSIONS_MAX :: 1024
SESSION_SECONDS :: 12*3600.0
SESSION_IDLE_SECONDS :: 2*3600.0
CHALLENGES_MAX :: 256
CHALLENGE_SECONDS :: 120.0
APPROVALS_MAX :: 64
APPROVALS_PER_ADDRESS :: 4 // waiting approvals one address asks without a session
APPROVAL_SECONDS :: 600.0
RATES_MAX :: 4096
COOKIE :: "__Host-kai"

Hub_Desc :: struct {
    runner:^kai.Runner,            // whose machine and agents the hub reads; it must outlive the hub
    rp_id:string,                  // the relying party of passkeys: the node's domain
    http_port:int,                 // plain HTTP on 127.0.0.1; 0: none, -1: a port the system picks
    https_port:int,                // TLS on every interface; 0: none, -1: a port the system picks
    https_loopback:bool,           // tests: TLS on 127.0.0.1 only
    credentials:[]tls.Credential,  // what TLS presents when no ACME runs (tests); the caller keeps them
    domains:[]string,              // names ACME orders certificates for
    acme_directory:string,         // "": Let's Encrypt's
    acme_roots:[]^x509.Certificate, // trust anchors of the directory; nil: the ISRG roots
    clock:Clock,                   // tests: the hub's seconds; none: the monotonic clock
    event:kai.Runner_Event,        // what it did, as a line of text
    allocator:runtime.Allocator,   // nil: context.allocator
}

Hub :: struct {
    desc:Hub_Desc,
    allocator:runtime.Allocator,
    start:time.Tick,
    now:f64,
    plain:net.TCP_Socket,
    has_plain:bool,
    secure:net.TCP_Socket,
    has_secure:bool,
    http_port,https_port:int,
    origin:string,                 // what browsers name: https://rp_id, with the port when it is not 443
    conns:[CONNECTIONS_MAX]^Conn,
    sessions:[SESSIONS_MAX]Session,
    challenges:[CHALLENGES_MAX]Challenge,
    approvals:[APPROVALS_MAX]Approval,
    approvals_made:u64,
    waiting:[WAITING_MAX]Waiting,
    waiting_loaded:bool,
    waiting_checked:f64,
    rates:[]Rate,
    graphs:[dynamic]Project_Graph,
    certs:Certs,
    stats:Hub_Stats,
}

Hub_Stats :: struct {
    requests,refused,connections:int,
    ddc_found,ddc_missing:int,
}

Session :: struct {
    used:bool,
    token:[32]u8,
    user:kai.Log_Id,
    web_key:kai.Key,   // the passkey that started it; zero when a device approved it
    device:kai.Key,    // the device that approved it
    credential:[255]u8,
    credential_len:int,
    created,seen:f64,
}

Challenge :: struct {
    used:bool,
    value:[32]u8,
    expires:f64,
}

// The start of a hub: its listeners. desc.runner must be running.
hub_start :: proc(h:^Hub,desc:Hub_Desc) -> (why:string) {
    if desc.runner==nil || desc.runner.machine==nil {return "the hub needs the node's runner"}
    if desc.http_port==0 && desc.https_port==0 {return "give --http or --domain: the hub has no port to listen on"}
    h^={desc=desc}
    h.allocator=desc.allocator.procedure==nil?context.allocator:desc.allocator
    // The hub keeps its own names: the caller's may be temporary.
    h.desc.rp_id=strings.clone(desc.rp_id,h.allocator)
    h.desc.domains=make([]string,len(desc.domains),h.allocator)
    for d,i in desc.domains {h.desc.domains[i]=strings.clone(d,h.allocator)}
    h.desc.acme_directory=strings.clone(desc.acme_directory,h.allocator)
    h.start=time.tick_now()
    h.graphs=make([dynamic]Project_Graph,h.allocator)
    rates,e:=make([]Rate,RATES_MAX,h.allocator)
    if e!=nil {return "out of memory"}
    h.rates=rates
    if desc.http_port!=0 {
        port:=max(desc.http_port,0)
        socket,le:=net.listen_tcp({net.IP4_Loopback,port})
        if le!=nil {
            hub_stop(h)
            return "the HTTP port does not open on 127.0.0.1: another program holds it, give another with --http"
        }
        h.plain,h.has_plain=socket,true
        net.set_blocking(socket,false)
        h.http_port=bound_port(socket)
    }
    if desc.https_port!=0 {
        port:=max(desc.https_port,0)
        address:net.Address=net.IP6_Any
        if desc.https_loopback {address=net.IP4_Loopback}
        socket,le:=net.listen_tcp({address,port})
        if le!=nil && !desc.https_loopback {socket,le=net.listen_tcp({net.IP4_Any,port})}
        if le!=nil {
            hub_stop(h)
            return "the HTTPS port does not open: another program holds it, or this user may not bind it (give another with --https, or let the service bind ports below 1024)"
        }
        h.secure,h.has_secure=socket,true
        net.set_blocking(socket,false)
        h.https_port=bound_port(socket)
    }
    h.origin=origin_of(desc.rp_id,h.has_secure?h.https_port:0,h.http_port,h.allocator)
    if why=certs_start(h);why!="" {
        hub_stop(h)
        return why
    }
    return ""
}

@(private)
bound_port :: proc(socket:net.TCP_Socket) -> int {
    endpoint,_:=net.bound_endpoint(socket)
    return endpoint.port
}

@(private)
origin_of :: proc(rp_id:string,https_port,http_port:int,allocator:runtime.Allocator) -> string {
    switch {
    case https_port==443: return concat(allocator,"https://",rp_id)
    case https_port>0: return concat(allocator,"https://",rp_id,":",itoa(https_port))
    }
    return concat(allocator,"http://127.0.0.1:",itoa(http_port))
}

hub_stop :: proc(h:^Hub) {
    for &c in h.conns {
        if c!=nil {conn_free(h,c)}
        c=nil
    }
    if h.has_plain {net.close(h.plain)}
    if h.has_secure {net.close(h.secure)}
    for &a in h.approvals {approval_clear(&a)}
    for &g in h.graphs {kai.graph_destroy(&g.graph)}
    delete(h.graphs)
    delete(h.rates,h.allocator)
    certs_stop(h)
    delete(h.origin,h.allocator)
    delete(h.desc.rp_id,h.allocator)
    for d in h.desc.domains {delete(d,h.allocator)}
    delete(h.desc.domains,h.allocator)
    delete(h.desc.acme_directory,h.allocator)
    crypto.zero_explicit(&h.sessions,size_of(h.sessions))
    h^={}
}

Clock :: struct {
    data:rawptr,
    procedure:proc(data:rawptr) -> f64,
}

hub_clock :: proc(h:^Hub) -> f64 {
    if h.desc.clock.procedure!=nil {return h.desc.clock.procedure(h.desc.clock.data)}
    return time.duration_seconds(time.tick_since(h.start))
}

// One step: the connections that came, what arrived, the answers, the
// timeouts and the certificates. It does not wait.
hub_update :: proc(h:^Hub) -> (busy:bool) {
    busy=hub_step(h)
    free_all(context.temp_allocator)
    return
}

@(private)
hub_step :: proc(h:^Hub) -> (busy:bool) {
    h.now=hub_clock(h)
    if h.has_plain {busy|=accept_all(h,h.plain,false)}
    if h.has_secure {busy|=accept_all(h,h.secure,true)}
    for &c,i in h.conns {
        if c==nil {continue}
        busy|=conn_step(h,c)
        if c.closed {
            conn_free(h,c)
            c=nil
        }
        _=i
    }
    waiting_load(h)
    waiting_step(h)
    certs_step(h)
    return
}

// Runs the runner and the hub until stop is set: the runner waits on its
// socket while the hub is idle.
hub_run :: proc(h:^Hub,stop:^bool) {
    for !stop^ {
        busy:=hub_update(h)
        kai.runner_update(h.desc.runner,busy?0:0.01)
    }
}
