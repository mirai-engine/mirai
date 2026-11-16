package mirai_net

import "base:runtime"
import "core:mem"
import "core:sync"
import cnet "core:net"
import "mirai:std/base"

// Largest datagram the library sends or accepts: under the IPv6 minimum MTU
// once IP and UDP headers are added, so no hop fragments it.
PACKET_BYTES :: 1200

Address_Kind :: enum u8 {None,IP4,IP6,Memory}
// Memory addresses name an endpoint of a Sim_Network by its index in port.
Address :: struct {kind:Address_Kind,port:u16,ip:[16]u8}

address_ip4 :: proc "contextless" (a,b,c,d:u8,port:int) -> Address {
    return {kind=.IP4,port=u16(port),ip={0=a,1=b,2=c,3=d}}
}
address_loopback :: proc "contextless" (port:int) -> Address {return address_ip4(127,0,0,1,port)}
address_loopback6 :: proc "contextless" (port:int) -> Address {return {kind=.IP6,port=u16(port),ip={15=1}}}
// Every interface: bound with udp_open, it takes IPv6 and IPv4 peers on one socket.
address_any6 :: proc "contextless" (port:int) -> Address {return {kind=.IP6,port=u16(port)}}
address_memory :: proc "contextless" (endpoint:int) -> Address {return {kind=.Memory,port=u16(endpoint)}}

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
        address.kind=.IP6
        address.ip=transmute([16]u8)ip
        // An IPv4 peer of a dual-stack socket, ::ffff:a.b.c.d, is that IPv4 address.
        mapped:=true
        for b in address.ip[:10] {mapped&&=b==0}
        if mapped && address.ip[10]==0xff && address.ip[11]==0xff {
            address.kind=.IP4
            copy(address.ip[:4],address.ip[12:])
            for &b in address.ip[4:] {b=0}
        }
    }
    return address
}
address_to_endpoint :: proc "contextless" (address:Address) -> (endpoint:cnet.Endpoint,ok:bool) {
    #partial switch address.kind {
    case .IP4: return {cnet.IP4_Address{address.ip[0],address.ip[1],address.ip[2],address.ip[3]},int(address.port)},true
    case .IP6: return {transmute(cnet.IP6_Address)address.ip,int(address.port)},true
    }
    return {},false
}

// How a host exchanges datagrams. Neither procedure blocks: send drops what it
// cannot send now and receive returns ok=false when nothing is waiting.
Transport :: struct {
    data:rawptr,
    send:proc(data:rawptr,to:Address,bytes:[]u8) -> bool,
    receive:proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool),
}

Udp :: struct {socket:cnet.UDP_Socket,open,dual:bool,address:Address}

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
    u.socket,u.open,u.dual,u.address=socket,true,dual,bind
    if bound,bound_error:=cnet.bound_endpoint(socket);bound_error==nil {u.address.port=u16(bound.port)}
    return true
}
udp_close :: proc(u:^Udp) {
    if u.open {cnet.close(u.socket)}
    u^={}
}
udp_transport :: proc "contextless" (u:^Udp) -> Transport {return {u,udp_send,udp_receive}}

@(private)
udp_send :: proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
    u:=(^Udp)(data)
    target:=to
    if u.dual && to.kind==.IP4 {
        target={kind=.IP6,port=to.port,ip={10=0xff,11=0xff}}
        for i in 0..<4 {target.ip[12+i]=to.ip[i]}
    }
    endpoint,valid:=address_to_endpoint(target)
    if !u.open || !valid {return false}
    _,error:=cnet.send_udp(u.socket,bytes,endpoint)
    return error==nil
}
@(private)
udp_receive :: proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
    u:=(^Udp)(data)
    if !u.open {return}
    // An ICMP answer to an earlier send surfaces as an error on the next receive: skip those.
    for _ in 0..<8 {
        count,endpoint,error:=cnet.recv_udp(u.socket,buffer)
        if error==nil {return count,address_from_endpoint(endpoint),true}
        if error==.Would_Block || error==.Timeout {return}
    }
    return
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
    return {&n.endpoints[endpoint],sim_send,sim_receive}
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
sim_send :: proc(data:rawptr,to:Address,bytes:[]u8) -> bool {
    source:=(^Sim_Endpoint)(data)
    n:=source.network
    sync.mutex_guard(&n.lock)
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
sim_receive :: proc(data:rawptr,buffer:[]u8) -> (size:int,from:Address,ok:bool) {
    target:=(^Sim_Endpoint)(data)
    n:=target.network
    sync.mutex_guard(&n.lock)
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
