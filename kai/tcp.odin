package kai

import cnet "core:net"
import net "mirai:net"

// The relay over TCP, the last rung when UDP to a relay node is blocked: one
// TCP connection from a device to the node, on port 443 beside the node's
// HTTPS, carries what the runner's UDP socket would (net datagrams already
// sealed end to end, rendezvous messages, relay envelopes) as frames of a
// big-endian u16 length and the bytes, after the device's magic: no TLS and
// no HTTP. The node tells it apart from TLS by the first byte, which a TLS
// record never starts with; the hub that holds the port hands such a
// connection over (runner_tcp_adopt). To the runner a connection is the
// address its datagrams come from, so the node forwards relay envelopes
// through it under the per-device byte quotas of the UDP relay. A device
// opens one only once the UDP rungs to the node failed, and drops it when the
// node answers a probe over UDP: the ladder then takes a better rung.
//
// Bounds of a node: TCP_STREAMS_MAX connections, TCP_PER_ADDRESS from one IP,
// the magic within TCP_MAGIC_SECONDS, frames of 2 to FRAME_MAX bytes, a whole
// frame or the send of what is queued within TCP_IDLE_SECONDS, and at most
// TCP_OUTPUT_MAX bytes queued for a peer: a frame past it is dropped, as UDP
// drops a datagram.

RELAY_TCP_PORT :: 443
RELAY_TCP_MAGIC :: "KAI-RELAY-1\n"
TCP_STREAMS_MAX :: 256
TCP_PER_ADDRESS :: 8
TCP_MAGIC_SECONDS :: 10.0
TCP_IDLE_SECONDS :: 4*HELLO_SECONDS
TCP_CONNECT_SECONDS :: 5.0
TCP_PROBE_SECONDS :: f64(RETRY_SECONDS) // a device asks its node over UDP again
TCP_OUTPUT_MAX :: 64<<10

Tcp_Stream :: struct {
    socket:cnet.TCP_Socket,
    address:net.Address, // a node's: the device's TCP address; a device's: the node's UDP address it stands for
    link:bool,           // a device's connection to its node
    node:Dh_Key,         // a device's: the node's key
    connecting:bool,
    greeted:bool,        // a node's: the magic arrived
    failed:bool,
    opened,active,sent,probed:f64,
    input:[2+FRAME_MAX]u8,
    input_len:int,
    output:[]u8,         // TCP_OUTPUT_MAX
    output_len:int,
}

// Listens for the relay over TCP: on desc.tcp_port of the bound address. A
// port that does not open leaves the node on UDP alone, which it says.
@(private)
runner_tcp_listen :: proc(r:^Runner,bind:net.Address) {
    port:=max(r.desc.tcp_port,0)
    at:=bind
    at.port=u16(port)
    endpoint,ok:=net.address_to_endpoint(at)
    if !ok {return}
    socket,e:=cnet.listen_tcp(endpoint)
    if e!=nil && bind.kind==.IP6 && bind.ip==([16]u8{}) {socket,e=cnet.listen_tcp({cnet.IP4_Any,port})}
    if e!=nil || cnet.set_blocking(socket,false)!=nil {
        if e==nil {cnet.close(socket)}
        runner_event(r,"the relay's TCP port %d does not open: devices whose UDP is blocked do not reach this node (let the service bind ports below 1024)",port)
        return
    }
    r.tcp_listener,r.has_tcp=socket,true
    bound,_:=cnet.bound_endpoint(socket)
    r.tcp_port=bound.port
}

// The TCP port the relay listens on itself; 0 when it does not.
runner_tcp_port :: proc(r:^Runner) -> int {return r.tcp_port}

// Takes a connection the node's HTTPS listener accepted whose first bytes,
// in bytes, are no TLS record: the relay's, which the runner reads from now
// on. Past the bounds of the node it is closed. The socket is the runner's
// either way.
runner_tcp_adopt :: proc(r:^Runner,socket:cnet.TCP_Socket,source:cnet.Endpoint,bytes:[]u8) -> bool {
    address:=net.address_from_endpoint(source)
    same,total:=0,0
    for s in r.tcp {
        if s.link {continue}
        total+=1
        if s.address.kind==address.kind && s.address.ip==address.ip {same+=1}
    }
    if .Relay not_in r.desc.modes || len(bytes)>2+FRAME_MAX || total>=TCP_STREAMS_MAX || same>=TCP_PER_ADDRESS || cnet.set_blocking(socket,false)!=nil {
        cnet.close(socket)
        return false
    }
    s:=tcp_stream_new(r,socket,address,false)
    if s==nil {return false}
    s.input_len=copy(s.input[:],bytes)
    tcp_frames(r,s)
    return true
}

// Opens a device's connection to the relay node at address, its UDP
// address: to its IP at the node's TCP port.
@(private)
runner_tcp_open :: proc(r:^Runner,node:Dh_Key,address:net.Address) -> bool {
    to:=address
    to.port=u16(r.desc.relay_tcp_port>0?r.desc.relay_tcp_port:RELAY_TCP_PORT)
    if runner_blocked(r,to) || (to.kind!=.IP4 && to.kind!=.IP6) {return false}
    any,e:=cnet.create_socket(to.kind==.IP4?.IP4:.IP6,.TCP)
    if e!=nil {return false}
    socket:=any.(cnet.TCP_Socket)
    if cnet.set_blocking(socket,false)!=nil || !net.socket_connect(cnet.Socket(socket),to) {
        cnet.close(socket)
        return false
    }
    s:=tcp_stream_new(r,socket,address,true)
    if s==nil {return false}
    s.connecting,s.node=true,node
    copy(s.output,RELAY_TCP_MAGIC)
    s.output_len=len(RELAY_TCP_MAGIC)
    return true
}

@(private)
tcp_stream_new :: proc(r:^Runner,socket:cnet.TCP_Socket,address:net.Address,link:bool) -> ^Tcp_Stream {
    s,e:=new(Tcp_Stream,r.allocator)
    if e!=nil {
        cnet.close(socket)
        return nil
    }
    output,oe:=make([]u8,TCP_OUTPUT_MAX,r.allocator)
    if oe!=nil || len(r.tcp)>=2*TCP_STREAMS_MAX {
        delete(output,r.allocator)
        free(s,r.allocator)
        cnet.close(socket)
        return nil
    }
    s.socket,s.address,s.link,s.output=socket,address,link,output
    s.opened,s.active,s.sent,s.probed=r.now,r.now,r.now,r.now
    if _,ae:=append(&r.tcp,s);ae!=nil {
        tcp_stream_free(r,s)
        return nil
    }
    return s
}

@(private)
tcp_stream_free :: proc(r:^Runner,s:^Tcp_Stream) {
    if !s.failed {cnet.close(s.socket)}
    delete(s.output,r.allocator)
    free(s,r.allocator)
}

@(private)
tcp_fail :: proc(s:^Tcp_Stream) {
    if s.failed {return}
    cnet.close(s.socket)
    s.failed=true
}

// Closes every connection and the listener.
@(private)
runner_tcp_close :: proc(r:^Runner) {
    for s in r.tcp {tcp_stream_free(r,s)}
    delete(r.tcp)
    if r.has_tcp {cnet.close(r.tcp_listener)}
    r.has_tcp=false
}

// The device's connection to the node at address, its UDP address.
@(private)
runner_tcp_link :: proc(r:^Runner,address:net.Address) -> ^Tcp_Stream {
    for s in r.tcp {
        if s.link && s.address==address {return s}
    }
    return nil
}

// Drops a device's connection to a node: the ladder takes UDP again.
@(private)
runner_tcp_drop :: proc(r:^Runner,s:^Tcp_Stream) {
    for x,k in r.tcp {
        if x!=s {continue}
        tcp_stream_free(r,s)
        ordered_remove(&r.tcp,k)
        return
    }
}

// The node of link answered a probe over UDP: the link goes, with the
// connection to the node it carried, and the ladder dials UDP at once. The
// device's next hellos tell the node where to forward.
@(private)
runner_tcp_upgrade :: proc(r:^Runner,link:^Tcp_Stream) {
    tcp_fail(link)
    link.active=r.now-2*RETRY_SECONDS
    for o in r.orgs {
        for &p in o.peers {
            if p.dh!=link.node {continue}
            if k,connected:=runner_connection(o,p.dh);connected && o.agent.peers[k].client>=0 {agent_drop(&o.agent,k)}
            p.stage,p.next_try,p.rung=0,0,.None
        }
    }
    r.hello_at=-1
    runner_event(r,"a relay node answers over UDP again: its relay over TCP ends")
}

// Queues bytes as a frame of the connection that stands for to; false when
// none does, and the runner sends them over UDP.
@(private)
runner_tcp_send :: proc(r:^Runner,to:net.Address,bytes:[]u8) -> bool {
    for s in r.tcp {
        if s.failed || s.address!=to || (!s.link && !s.greeted) {continue}
        if len(bytes)>=2 && len(bytes)<=FRAME_MAX && s.output_len+2+len(bytes)<=len(s.output) {
            s.output[s.output_len],s.output[s.output_len+1]=u8(len(bytes)>>8),u8(len(bytes))
            copy(s.output[s.output_len+2:],bytes)
            if s.output_len==0 {s.sent=r.now}
            s.output_len+=2+len(bytes)
        }
        return true
    }
    return false
}

// One step of every connection: what the listener accepted, what arrived,
// what is queued, and the deadlines.
@(private)
runner_tcp_step :: proc(r:^Runner) {
    if r.has_tcp {
        for _ in 0..<16 {
            socket,source,e:=cnet.accept_tcp(r.tcp_listener)
            if e!=nil {break}
            runner_tcp_adopt(r,socket,source,nil)
        }
    }
    for k:=0;k<len(r.tcp); {
        s:=r.tcp[k]
        if !s.failed {tcp_pump(r,s)}
        if s.link && !s.failed && !s.connecting && r.now-s.probed>TCP_PROBE_SECONDS {
            s.probed=r.now
            runner_z_send(r,s.node,s.address,.Probe,nil,udp=true)
        }
        // A link that failed stays until the ladder reads it, or a while.
        if s.failed && (!s.link || r.now-s.active>RETRY_SECONDS) {
            tcp_stream_free(r,s)
            ordered_remove(&r.tcp,k)
            continue
        }
        k+=1
    }
}

@(private)
tcp_pump :: proc(r:^Runner,s:^Tcp_Stream) {
    if s.connecting {
        ready,ok:=net.socket_connected(cnet.Socket(s.socket))
        if !ready {
            if r.now-s.opened>TCP_CONNECT_SECONDS {tcp_fail(s)}
            return
        }
        if !ok {
            tcp_fail(s)
            return
        }
        s.connecting=false
        s.active,s.sent=r.now,r.now
        // The node learns at once where to reach this device.
        r.hello_at=-1
    }
    for _ in 0..<8 {
        n,e:=cnet.recv_tcp(s.socket,s.input[s.input_len:])
        if e!=nil {
            if e!=.Would_Block && e!=.Interrupted {tcp_fail(s)}
            break
        }
        if n==0 {
            tcp_fail(s)
            return
        }
        s.input_len+=n
        tcp_frames(r,s)
        if s.failed {return}
    }
    if s.output_len>0 {
        n,e:=cnet.send_tcp(s.socket,s.output[:s.output_len])
        if n>0 {
            copy(s.output,s.output[n:s.output_len])
            s.output_len-=n
            s.sent=r.now
        }
        if e!=nil && e!=.Would_Block && e!=.Interrupted {
            tcp_fail(s)
            return
        }
    }
    switch {
    case !s.link && !s.greeted && r.now-s.opened>TCP_MAGIC_SECONDS: tcp_fail(s)
    case r.now-s.active>TCP_IDLE_SECONDS: tcp_fail(s)
    case s.output_len>0 && r.now-s.sent>TCP_IDLE_SECONDS: tcp_fail(s)
    }
}

// Reads the magic and every whole frame the input holds; hostile framing
// ends the connection.
@(private)
tcp_frames :: proc(r:^Runner,s:^Tcp_Stream) {
    at:=0
    defer {
        if !s.failed {
            copy(s.input[:],s.input[at:s.input_len])
            s.input_len-=at
        }
    }
    if !s.link && !s.greeted {
        magic:=RELAY_TCP_MAGIC
        n:=min(s.input_len,len(magic))
        if string(s.input[:n])!=magic[:n] {
            tcp_fail(s)
            return
        }
        if n<len(RELAY_TCP_MAGIC) {return}
        s.greeted=true
        at=n
    }
    for s.input_len-at>=2 {
        size:=int(s.input[at])<<8|int(s.input[at+1])
        if size<2 || size>FRAME_MAX {
            tcp_fail(s)
            return
        }
        if s.input_len-at<2+size {return}
        s.active=r.now
        runner_frame(r,s.address,s.input[at+2:][:size],0)
        at+=2+size
        if s.failed {return}
    }
}
