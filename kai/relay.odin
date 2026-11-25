package kai

import net "mirai:net"

// A relay node: rendezvous and the last rung of the connection ladder. It
// keeps where each admitted device's datagrams come from and the addresses
// the device announced (its global IPv6, its router's mapping), which it
// tells a device that asks for that peer, and forwards the opaque datagrams
// of the rest. What it forwards is net datagrams already sealed end to end:
// the relay reads only the envelope, the X25519 key of who it is for. Each
// sending device draws on its own token bucket of bytes.

RELAY_DEVICES_MAX :: 1024
RELAY_ENVELOPE :: 1+32    // RELAY_MAGIC, then the key of who it is for
RELAY_MAGIC :: u8('R')
RELAY_DATAGRAM_MAX :: 1+RUNNER_ROUTE+net.PACKET_BYTES // what it forwards: a net datagram with the runner's route
RELAY_ANNOUNCED :: 4

Relay_Device :: struct {
    dh:Dh_Key,
    observed:net.Address, // where its datagrams come from; none until it greets
    announced:[RELAY_ANNOUNCED]net.Address,
    announced_count:int,
    tokens:f64, // bytes it may send now
    refilled:f64,
    forwarded,dropped:u64,
}

Relay :: struct {
    devices:[dynamic]Relay_Device,
    rate:f64,  // bytes per second each device may send
    burst:f64, // bytes it may send at once
}

relay_init :: proc(r:^Relay,rate,burst:f64,allocator:=context.allocator) {
    r^={rate=rate,burst=burst}
    r.devices=make([dynamic]Relay_Device,allocator)
}

relay_destroy :: proc(r:^Relay) {
    delete(r.devices)
    r^={}
}

@(private)
relay_find :: proc(r:^Relay,dh:Dh_Key) -> int {
    for d,i in r.devices {
        if d.dh==dh {return i}
    }
    return -1
}

// Lets a device use the relay: a member's or a node's, as the org's log says.
relay_admit :: proc(r:^Relay,dh:Dh_Key,now:f64) -> Error {
    if relay_find(r,dh)>=0 {return .None}
    if len(r.devices)>=RELAY_DEVICES_MAX {return .Too_Large}
    if _,e:=append(&r.devices,Relay_Device{dh=dh,tokens=r.burst,refilled=now});e!=nil {return .Out_Of_Memory}
    return .None
}

// Drops a device: one removed from the org.
relay_remove :: proc(r:^Relay,dh:Dh_Key) {
    if k:=relay_find(r,dh);k>=0 {unordered_remove(&r.devices,k)}
}

// Records where a device's greeting came from and the addresses it announced.
relay_observe :: proc(r:^Relay,dh:Dh_Key,from:net.Address,announced:[]net.Address) -> bool {
    k:=relay_find(r,dh)
    if k<0 {return false}
    d:=&r.devices[k]
    d.observed=from
    d.announced_count=copy(d.announced[:],announced)
    return true
}

@(private)
dh_less :: proc "contextless" (a,b:Dh_Key) -> bool {
    for k in 0..<len(a) {
        if a[k]!=b[k] {return a[k]<b[k]}
    }
    return false
}

// Forwards an envelope from a device: who it is for and the datagram, as it
// came. Not ok when the sender or the receiver is not admitted, the envelope
// is malformed, or the sender's bucket lacks the bytes.
relay_forward :: proc(r:^Relay,from:Dh_Key,envelope:[]u8,now:f64) -> (to:Dh_Key,datagram:[]u8,ok:bool) {
    k:=relay_find(r,from)
    if k<0 {return}
    d:=&r.devices[k]
    if len(envelope)<=RELAY_ENVELOPE || len(envelope)>RELAY_ENVELOPE+RELAY_DATAGRAM_MAX || envelope[0]!=RELAY_MAGIC {
        d.dropped+=1
        return
    }
    copy(to[:],envelope[1:RELAY_ENVELOPE])
    if relay_find(r,to)<0 {
        d.dropped+=1
        return {},nil,false
    }
    d.tokens=min(r.burst,d.tokens+(now-d.refilled)*r.rate)
    d.refilled=now
    size:=f64(len(envelope)-RELAY_ENVELOPE)
    if d.tokens<size {
        d.dropped+=1
        return {},nil,false
    }
    d.tokens-=size
    d.forwarded+=u64(size)
    return to,envelope[RELAY_ENVELOPE:],true
}

