package mirai_net

import "base:runtime"
import "core:mem"
import "core:sync"
import cnet "core:net"
import "mirai:std/base"

// Largest datagram the library sends or accepts: under the IPv6 minimum MTU
// once IP and UDP headers are added, so no hop fragments it.
PACKET_BYTES :: 1200

Address_Kind :: enum u8 {None,IP4,IP6,Memory,Relay}
// Memory addresses name an endpoint of a Sim_Network by its index in port. A Relay address is a
// peer that a relay node forwards to: ip and port are the node's (an IPv4 node as ::ffff:a.b.c.d)
// and peer is the static key of the peer behind it; peer is zero in every other kind. zone is the
// interface a link-local or multicast IPv6 address is on (its scope id), zero for any other.
Address :: struct {kind:Address_Kind,port:u16,ip:[16]u8,peer:Key,zone:u32}

address_ip4 :: proc "contextless" (a,b,c,d:u8,port:int) -> Address {
    return {kind=.IP4,port=u16(port),ip={0=a,1=b,2=c,3=d}}
}
address_loopback :: proc "contextless" (port:int) -> Address {return address_ip4(127,0,0,1,port)}
address_loopback6 :: proc "contextless" (port:int) -> Address {return {kind=.IP6,port=u16(port),ip={15=1}}}
// Every interface: bound with udp_open, it takes IPv6 and IPv4 peers on one socket.
address_any6 :: proc "contextless" (port:int) -> Address {return {kind=.IP6,port=u16(port)}}
address_memory :: proc "contextless" (endpoint:int) -> Address {return {kind=.Memory,port=u16(endpoint)}}
// The peer of static key peer through the relay node at node, which is IPv4 or IPv6 with a port.
address_relay :: proc "contextless" (node:Address,peer:Key) -> (relay:Address,ok:bool) {
    if node.kind!=.IP4 && node.kind!=.IP6 || node.port==0 || peer==(Key{}) {return}
    relay={kind=.Relay,port=node.port,ip=node.ip,peer=peer}
    if node.kind==.IP4 {relay.ip={10=0xff,11=0xff,12=node.ip[0],13=node.ip[1],14=node.ip[2],15=node.ip[3]}}
    return relay,true
}
// The relay node of a Relay address and the static key of the peer behind it.
address_relay_node :: proc "contextless" (relay:Address) -> (node:Address,peer:Key,ok:bool) {
    if relay.kind!=.Relay {return}
    return address_unmap(relay.ip,relay.port),relay.peer,true
}
// Whether an address is reachable across the internet: a public IPv4 address, or a global
// unicast IPv6 one (2000::/3).
address_global :: proc "contextless" (a:Address) -> bool {
    if a.kind==.IP4 {
        ip:=a.ip
        return ip[0]!=0 && ip[0]!=10 && ip[0]!=127 && ip[0]<224 &&
            !(ip[0]==100 && ip[1]>=64 && ip[1]<=127) && !(ip[0]==169 && ip[1]==254) &&
            !(ip[0]==172 && ip[1]>=16 && ip[1]<=31) && !(ip[0]==192 && ip[1]==168) &&
            !(ip[0]==192 && ip[1]==0 && (ip[2]==0 || ip[2]==2)) &&
            !(ip[0]==198 && ((ip[1]==18 || ip[1]==19) || (ip[1]==51 && ip[2]==100))) &&
            !(ip[0]==203 && ip[1]==0 && ip[2]==113)
    }
    return a.kind==.IP6 && a.ip[0]&0xe0==0x20
}
// A global IPv6 address of this machine with a port: the first global unicast one of an interface
// that is up, which reaches it without a mapping; none without one.
address_global6 :: proc(port:int) -> Address {
    interfaces,error:=cnet.enumerate_interfaces(context.temp_allocator)
    if error!=nil {return {}}
    for interface in interfaces {
        if cnet.Link_States.Up not_in interface.link.state {continue}
        for lease in interface.unicast {
            ip,is_ip6:=lease.address.(cnet.IP6_Address)
            if !is_ip6 {continue}
            a:=Address{kind=.IP6,port=u16(port),ip=transmute([16]u8)ip}
            if address_global(a) {return a}
        }
    }
    return {}
}

// "1.2.3.4:7777", "[::1]:7777" or "[2001:db8::1]:7777". A host name is not an address: see resolve_start.
address_parse :: proc(text:string) -> (Address,bool) {
    endpoint,ok:=cnet.parse_endpoint(text)
    if !ok {return {},false}
    return address_from_endpoint(endpoint),true
}
address_from_endpoint :: proc "contextless" (endpoint:cnet.Endpoint) -> Address {
    address:=Address{port=u16(endpoint.port)}
    switch ip in endpoint.address {
    case cnet.IP4_Address:
        address.kind=.IP4
        for b,i in ip {address.ip[i]=b}
    case cnet.IP6_Address:
        address=address_unmap(transmute([16]u8)ip,address.port)
    }
    return address
}
// An IPv6 address with a port; ::ffff:a.b.c.d, as a dual-stack socket shows an IPv4 peer, is that
// IPv4 address.
@(private)
address_unmap :: proc "contextless" (ip:[16]u8,port:u16) -> Address {
    mapped:=ip[10]==0xff && ip[11]==0xff
    for i in 0..<10 {mapped&&=ip[i]==0}
    if mapped {return address_ip4(ip[12],ip[13],ip[14],ip[15],int(port))}
    return {kind=.IP6,port=port,ip=ip}
}
address_to_endpoint :: proc "contextless" (address:Address) -> (endpoint:cnet.Endpoint,ok:bool) {
    #partial switch address.kind {
    case .IP4: return {cnet.IP4_Address{address.ip[0],address.ip[1],address.ip[2],address.ip[3]},int(address.port)},true
    case .IP6: return {transmute(cnet.IP6_Address)address.ip,int(address.port)},true
    }
    return {},false
}

// A datagram of a batch. To send: bytes go to address. To receive: bytes is the buffer to fill, and
// comes back cut to what arrived from address.
Datagram :: struct {address:Address,bytes:[]u8}

// How a host exchanges datagrams, a batch at a time. send and receive never block: send returns how
// many of the batch went, in order, and drops the rest; receive fills the first datagrams of the
// batch with what waits and returns how many, 0 when nothing does. wait blocks until a datagram waits,
// wake was called since the last wait, or seconds pass; wake may come from any thread. A worker needs
// both (worker_start); a host the caller updates uses neither.
Transport :: struct {
    data:rawptr,
    send:proc(data:rawptr,batch:[]Datagram) -> int,
    receive:proc(data:rawptr,batch:[]Datagram) -> int,
    wait:proc(data:rawptr,seconds:f64),
    wake:proc(data:rawptr),
}

UDP_BUFFER_BYTES :: 4<<20 // asked for the receive and send buffers of a socket

// waker: a socket on 127.0.0.1 that wake sends a byte to, so that wait returns.
Udp :: struct {socket,waker:cnet.UDP_Socket,open,dual:bool,address:Address,waker_endpoint:cnet.Endpoint}

// Binds a non-blocking socket. Port 0 lets the system choose; u.address holds the result. Bound to
// address_any6 the socket is dual-stack: IPv4 peers reach it too and appear with IPv4 addresses.
udp_open :: proc(u:^Udp,bind:Address) -> bool {
    u^={}
    endpoint,valid:=address_to_endpoint(bind)
    if !valid {return false}
    socket,error:=cnet.make_unbound_udp_socket(bind.kind==.IP6?.IP6:.IP4)
    if error!=nil {return false}
    dual:=bind.kind==.IP6 && bind.ip==[16]u8{}
    if (dual && !udp_dual_stack(socket)) || cnet.bind(socket,endpoint)!=nil || cnet.set_blocking(socket,false)!=nil {
        cnet.close(socket)
        return false
    }
    waker,waker_error:=cnet.make_unbound_udp_socket(.IP4)
    if waker_error!=nil {cnet.close(socket);return false}
    loopback,_:=address_to_endpoint(address_loopback(0))
    if cnet.bind(waker,loopback)!=nil || cnet.set_blocking(waker,false)!=nil {
        cnet.close(socket);cnet.close(waker)
        return false
    }
    // A bulk transfer outruns the system's default buffers between two polls; less than asked,
    // or a refusal, keeps what the system gives.
    cnet.set_option(socket,.Receive_Buffer_Size,UDP_BUFFER_BYTES)
    cnet.set_option(socket,.Send_Buffer_Size,UDP_BUFFER_BYTES)
    u.socket,u.waker,u.open,u.dual,u.address=socket,waker,true,dual,bind
    if bound,bound_error:=cnet.bound_endpoint(socket);bound_error==nil {u.address.port=u16(bound.port)}
    if bound,bound_error:=cnet.bound_endpoint(waker);bound_error==nil {u.waker_endpoint=bound}
    return true
}
udp_close :: proc(u:^Udp) {
    if u.open {cnet.close(u.socket);cnet.close(u.waker)}
    u^={}
}
udp_transport :: proc "contextless" (u:^Udp) -> Transport {return {u,udp_transport_send,udp_transport_receive,udp_wait,udp_wake}}

// Where a datagram to `to` goes from this socket: an IPv4 peer of a dual-stack socket as ::ffff:a.b.c.d.
@(private)
udp_target :: proc "contextless" (u:^Udp,to:Address) -> Address {
    if !u.dual || to.kind!=.IP4 {return to}
    target:=Address{kind=.IP6,port=to.port,ip={10=0xff,11=0xff}}
    for i in 0..<4 {target.ip[12+i]=to.ip[i]}
    return target
}
@(private)
udp_transport_send :: proc(data:rawptr,batch:[]Datagram) -> int {
    u:=(^Udp)(data)
    if !u.open {return 0}
    return udp_send_batch(u,batch)
}
@(private)
udp_transport_receive :: proc(data:rawptr,batch:[]Datagram) -> int {
    u:=(^Udp)(data)
    if !u.open {return 0}
    return udp_receive_batch(u,batch)
}
// One datagram, for what talks to a router or a test.
@(private)
udp_send :: proc(u:^Udp,to:Address,bytes:[]u8) -> bool {
    batch:=[1]Datagram{{to,bytes}}
    return udp_transport_send(u,batch[:])==1
}
@(private)
udp_receive :: proc(u:^Udp,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
    batch:=[1]Datagram{{bytes=buffer}}
    if udp_transport_receive(u,batch[:])==0 {return}
    return len(batch[0].bytes),batch[0].address,true
}
@(private)
udp_wait :: proc(data:rawptr,seconds:f64) {
    u:=(^Udp)(data)
    if !u.open || !(seconds>0) {return}
    if !udp_poll(u,int(min(seconds,1)*1000+0.999)) {return}
    drain:[16]u8
    for {
        if _,_,error:=cnet.recv_udp(u.waker,drain[:]);error!=nil {break}
    }
}
@(private)
udp_wake :: proc(data:rawptr) {
    u:=(^Udp)(data)
    if !u.open {return}
    signal:=[1]u8{1}
    cnet.send_udp(u.waker,signal[:],u.waker_endpoint)
}

// What a simulated link does to the datagrams an endpoint sends.
Sim_Conditions :: struct {
    latency:f64,       // seconds
    jitter:f64,        // seconds, added or removed at random
    loss:f32,          // probability, 0 to 1
    duplicate:f32,     // probability of delivering a second copy
    reorder:f32,       // probability of holding a datagram back by reorder_delay
    reorder_delay:f64, // seconds
    bandwidth:f64,     // bytes per second the link carries, in order; 0 is no limit
    queue:f64,         // seconds of datagrams the link holds waiting for bandwidth, 0.2 when zero; more are dropped
}

Sim_Network_Desc :: struct {
    seed:u64,
    endpoints:int,
    packets:int, // datagrams in flight across the whole network
    allocator:runtime.Allocator,
}
Sim_Stats :: struct {sent,delivered,lost,duplicated,reordered,dropped_full,dropped_queue:u64}

@(private)
Sim_Packet :: struct {time:f64,order:u64,from:u16,size:u16}
@(private)
Sim_Endpoint :: struct {network:^Sim_Network,index:u16,conditions:Sim_Conditions,heap:[]u32,count:int,link_free:f64}

// In-memory network with seeded latency, jitter, loss, duplication and
// reordering. Deterministic for a given seed and sequence of calls; safe to
// use from several threads. Time only moves through sim_network_advance.
Sim_Network :: struct {
    lock:sync.Mutex,
    now:f64,
    rng:u64,
    order:u64,
    endpoints:[]Sim_Endpoint,
    packets:[]Sim_Packet,
    data:[]u8,
    free:[]u32,
    free_count:int,
    stats:Sim_Stats,
    allocator:runtime.Allocator,
}

sim_network_init :: proc(n:^Sim_Network,desc:Sim_Network_Desc) -> bool {
    allocator:=desc.allocator.procedure==nil?context.allocator:desc.allocator
    endpoints,packets:=max(desc.endpoints,2),max(desc.packets,64)
    n^={rng=desc.seed,allocator=allocator}
    error:mem.Allocator_Error
    if n.endpoints,error=make([]Sim_Endpoint,endpoints,allocator);error!=nil {sim_network_destroy(n);return false}
    if n.packets,error=make([]Sim_Packet,packets,allocator);error!=nil {sim_network_destroy(n);return false}
    if n.data,error=make([]u8,packets*PACKET_BYTES,allocator);error!=nil {sim_network_destroy(n);return false}
    if n.free,error=make([]u32,packets,allocator);error!=nil {sim_network_destroy(n);return false}
    for &endpoint,i in n.endpoints {
        endpoint={network=n,index=u16(i)}
        if endpoint.heap,error=make([]u32,packets,allocator);error!=nil {sim_network_destroy(n);return false}
    }
    for &slot,i in n.free {slot=u32(packets-1-i)}
    n.free_count=packets
    return true
}
sim_network_destroy :: proc(n:^Sim_Network) {
    for endpoint in n.endpoints {delete(endpoint.heap,n.allocator)}
    delete(n.endpoints,n.allocator);delete(n.packets,n.allocator);delete(n.data,n.allocator);delete(n.free,n.allocator)
    n^={}
}
sim_network_advance :: proc(n:^Sim_Network,now:f64) {
    sync.mutex_guard(&n.lock)
    n.now=max(n.now,now)
}
// Conditions of everything the endpoint sends from now on.
sim_endpoint_conditions :: proc(n:^Sim_Network,endpoint:int,conditions:Sim_Conditions) {
    sync.mutex_guard(&n.lock)
    n.endpoints[endpoint].conditions=conditions
}
sim_endpoint_transport :: proc(n:^Sim_Network,endpoint:int) -> Transport {
    return {data=&n.endpoints[endpoint],send=sim_send,receive=sim_receive}
}

@(private)
rng_unit :: proc "contextless" (state:^u64) -> f64 {return f64(base.splitmix_next(state)>>11)/f64(u64(1)<<53)}

@(private)
sim_before :: proc "contextless" (n:^Sim_Network,a,b:u32) -> bool {
    pa,pb:=n.packets[a],n.packets[b]
    return pa.time<pb.time || (pa.time==pb.time && pa.order<pb.order)
}
@(private)
sim_enqueue :: proc(n:^Sim_Network,target:^Sim_Endpoint,from:u16,bytes:[]u8,delay:f64) {
    if n.free_count==0 {n.stats.dropped_full+=1;return}
    n.free_count-=1
    slot:=n.free[n.free_count]
    n.packets[slot]={time=n.now+max(delay,0),order=n.order,from=from,size=u16(len(bytes))}
    n.order+=1
    copy(n.data[int(slot)*PACKET_BYTES:],bytes)
    heap:=target.heap
    i:=target.count
    target.count+=1
    for i>0 {
        parent:=(i-1)/2
        if !sim_before(n,slot,heap[parent]) {break}
        heap[i]=heap[parent]
        i=parent
    }
    heap[i]=slot
}
@(private)
sim_send :: proc(data:rawptr,batch:[]Datagram) -> int {
    source:=(^Sim_Endpoint)(data)
    n:=source.network
    sync.mutex_guard(&n.lock)
    sent:=0
    for datagram in batch {
        if sim_send_one(n,source,datagram.address,datagram.bytes) {sent+=1}
    }
    return sent
}
@(private)
sim_send_one :: proc(n:^Sim_Network,source:^Sim_Endpoint,to:Address,bytes:[]u8) -> bool {
    if to.kind!=.Memory || int(to.port)>=len(n.endpoints) || len(bytes)>PACKET_BYTES {return false}
    n.stats.sent+=1
    c:=source.conditions
    if rng_unit(&n.rng)<f64(c.loss) {n.stats.lost+=1;return true}
    // A narrow link sends one datagram after another and drops what would wait longer than its queue.
    queued:f64
    if c.bandwidth>0 {
        start:=max(n.now,source.link_free)
        if start-n.now>(c.queue>0?c.queue:0.2) {n.stats.dropped_queue+=1;return true}
        source.link_free=start+f64(len(bytes))/c.bandwidth
        queued=source.link_free-n.now
    }
    target:=&n.endpoints[to.port]
    delay:=queued+c.latency+c.jitter*(rng_unit(&n.rng)*2-1)
    if rng_unit(&n.rng)<f64(c.reorder) {delay+=c.reorder_delay;n.stats.reordered+=1}
    sim_enqueue(n,target,source.index,bytes,delay)
    if rng_unit(&n.rng)<f64(c.duplicate) {
        n.stats.duplicated+=1
        sim_enqueue(n,target,source.index,bytes,c.latency+c.jitter*(rng_unit(&n.rng)*2-1))
    }
    return true
}
@(private)
sim_receive :: proc(data:rawptr,batch:[]Datagram) -> int {
    target:=(^Sim_Endpoint)(data)
    n:=target.network
    sync.mutex_guard(&n.lock)
    for &datagram,i in batch {
        size,from,ok:=sim_receive_one(n,target,datagram.bytes)
        if !ok {return i}
        datagram={from,datagram.bytes[:size]}
    }
    return len(batch)
}
@(private)
sim_receive_one :: proc(n:^Sim_Network,target:^Sim_Endpoint,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
    if target.count==0 {return}
    heap:=target.heap
    slot:=heap[0]
    packet:=n.packets[slot]
    if packet.time>n.now {return}
    target.count-=1
    last:=heap[target.count]
    i:=0
    for {
        child:=i*2+1
        if child>=target.count {break}
        if child+1<target.count && sim_before(n,heap[child+1],heap[child]) {child+=1}
        if !sim_before(n,heap[child],last) {break}
        heap[i]=heap[child]
        i=child
    }
    if target.count>0 {heap[i]=last}
    n.free[n.free_count]=slot
    n.free_count+=1
    n.stats.delivered+=1
    size=min(int(packet.size),len(buffer))
    copy(buffer,n.data[int(slot)*PACKET_BYTES:][:size])
    return size,address_memory(int(packet.from)),true
}
