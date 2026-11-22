package kai

import net "mirai:net"

// A relay node: stateless rendezvous and the last rung of the connection
// ladder. It sees the reflexive address a device's datagrams come from on two
// of its ports, which tells a hard (symmetric) NAT from a cone one; it tells
// two cone devices when to punch at each other at once (the lower dh
// initiates), and forwards the opaque datagrams of the rest. What it forwards
// is net datagrams already sealed end to end: the relay reads only the
// envelope, the X25519 key of who it is for. Each sending device draws on its
// own token bucket of bytes.

RELAY_DEVICES_MAX :: 1024
RELAY_PUNCH_DELAY :: 0.25 // s from the plan to the punch, so both ends hear of it first
RELAY_ENVELOPE :: 1+32    // RELAY_MAGIC, then the key of who it is for
RELAY_MAGIC :: u8('R')

Nat_Kind :: enum u8 {
    Unknown,   // seen on fewer than two ports
    Cone,      // the same reflexive address on both: punching works
    Symmetric, // another port for each destination: punching is futile, relay
}

Relay_Device :: struct {
    dh:Dh_Key,
    observed:[2]net.Address,
    seen:[2]bool,
    tokens:f64, // bytes it may send now
    refilled:f64,
    forwarded,dropped:u64,
}

Relay :: struct {
    devices:[dynamic]Relay_Device,
    rate:f64,  // bytes per second each device may send
    burst:f64, // bytes it may send at once
}

// How two devices meet: punching at once at each other's reflexive address,
// or through the relay.
Punch_Plan :: struct {
    initiator,responder:Dh_Key,
    initiator_target,responder_target:net.Address, // where each one sends
    at:f64,
    relay:bool,
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

// Records the reflexive address a device's datagram came from on one of the
// relay's two ports.
relay_observe :: proc(r:^Relay,dh:Dh_Key,port:int,from:net.Address) -> bool {
    k:=relay_find(r,dh)
    if k<0 || port<0 || port>1 {return false}
    r.devices[k].observed[port],r.devices[k].seen[port]=from,true
    return true
}

relay_nat :: proc(r:^Relay,dh:Dh_Key) -> Nat_Kind {
    k:=relay_find(r,dh)
    if k<0 {return .Unknown}
    d:=&r.devices[k]
    if !d.seen[0] || !d.seen[1] {return .Unknown}
    if d.observed[0].kind==d.observed[1].kind && d.observed[0].ip==d.observed[1].ip && d.observed[0].port==d.observed[1].port {return .Cone}
    return .Symmetric
}

@(private)
dh_less :: proc "contextless" (a,b:Dh_Key) -> bool {
    for k in 0..<len(a) {
        if a[k]!=b[k] {return a[k]<b[k]}
    }
    return false
}

// How a and b should meet. Not ok when either is not admitted or was not
// seen yet.
relay_rendezvous :: proc(r:^Relay,a,b:Dh_Key,now:f64) -> (plan:Punch_Plan,ok:bool) {
    ka,kb:=relay_find(r,a),relay_find(r,b)
    if ka<0 || kb<0 || a==b || !r.devices[ka].seen[0] || !r.devices[kb].seen[0] {return}
    if dh_less(b,a) {ka,kb=kb,ka}
    first,second:=&r.devices[ka],&r.devices[kb]
    plan={initiator=first.dh,responder=second.dh,initiator_target=second.observed[0],responder_target=first.observed[0],at=now+RELAY_PUNCH_DELAY}
    plan.relay=relay_nat(r,first.dh)==.Symmetric || relay_nat(r,second.dh)==.Symmetric
    return plan,true
}

// An envelope of datagram for the device to, in out: its bytes.
relay_wrap :: proc(to:Dh_Key,datagram,out:[]u8) -> []u8 {
    if len(out)<RELAY_ENVELOPE+len(datagram) {return nil}
    out[0]=RELAY_MAGIC
    t:=to
    copy(out[1:],t[:])
    copy(out[RELAY_ENVELOPE:],datagram)
    return out[:RELAY_ENVELOPE+len(datagram)]
}

// Forwards an envelope from a device: who it is for and the datagram, as it
// came. Not ok when the sender or the receiver is not admitted, the envelope
// is malformed, or the sender's bucket lacks the bytes.
relay_forward :: proc(r:^Relay,from:Dh_Key,envelope:[]u8,now:f64) -> (to:Dh_Key,datagram:[]u8,ok:bool) {
    k:=relay_find(r,from)
    if k<0 {return}
    d:=&r.devices[k]
    if len(envelope)<=RELAY_ENVELOPE || len(envelope)>RELAY_ENVELOPE+net.PACKET_BYTES || envelope[0]!=RELAY_MAGIC {
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

