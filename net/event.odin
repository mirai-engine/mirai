package mirai_net

import "core:mem"
import "mirai:std/base"
import "mirai:std/serial"

// Events and the requests of delegated authority travel as messages on two
// channels the library keeps for itself: a reliable one and an unreliable
// one. An event names its object by handle, so it is independent of the
// object stream: a reliable event that reaches a client before the replica
// it is about waits for it, for a few seconds at most.

@(private) EVENT_HOLD_SECONDS :: 5.0
@(private) AUTHORITY_MESSAGE_BYTES :: 9 // the kind and the handle of the object

@(private) Event_Fate :: enum u8 {Delivered,Missing,Bad}

@(private)
event_deliver :: proc(h:^Host,p:^Peer,channel:int,rd:^serial.Bit_Reader) -> Event_Fate {
    r:=&h.back.repl
    id:=int(serial.bit_read(rd,16))
    object:=serial.bit_read(rd,64)
    tick:=r.server?r.remote_tick:u32(serial.bit_read(rd,32))
    if rd.error || id>=len(r.protocol.events) {return .Bad}
    type:=&r.protocol.events[id]
    if (r.server && .From_Client not_in type.flags) || (.Reliable in type.flags)!=(channel==CHANNEL_SYSTEM) {return .Bad}
    words:=r.words[:type.desc.words]
    mem.zero_slice(words)
    if !state_read(rd,&type.desc,type.desc.all,words,nil) {return .Bad}
    handle:=peer_handle(h,p)
    if object!=0 {
        index:=int(base.handle_index(base.Handle(object)))
        if r.server {
            o,alive:=object_from(r,object)
            if !alive || (.Owner_Only in type.flags && r.owner[o]!=handle) {return .Delivered}
        } else {
            if index>=r.max {return .Bad}
            if r.live[index]!=1 || u64(object_handle(r,index))!=object {return .Missing}
        }
    }
    command:=command_push(h,{kind=.Event,event=Event_Id(id),object=Object(object),connection=handle,tick=tick},nil,type.desc.words)
    if command!=nil {copy(command.words,words)}
    return .Delivered
}

// A message of one of the library's channels. False when it cannot be parsed.
@(private)
repl_message :: proc(h:^Host,p:^Peer,channel:int,data:[]u8) -> bool {
    r:=&h.back.repl
    rd:serial.Bit_Reader
    serial.bit_reader_init(&rd,data)
    kind:=serial.bit_read(&rd,3)
    handle:=peer_handle(h,p)
    switch kind {
    case u64(System_Message.Event):
        switch event_deliver(h,p,channel,&rd) {
        case .Delivered:
        case .Bad:
            return false
        case .Missing:
            if channel!=CHANNEL_SYSTEM {return true}
            now:=h.back.now
            for r.events.used+12+len(data)>len(r.events.data) && r.events.used>0 {event_pop(r,nil)}
            if 12+len(data)<=len(r.events.data) {
                ring_write(&r.events,mem.ptr_to_bytes(&now))
                ring_write_message(&r.events,data)
            }
        }
    case u64(System_Message.Authority_Request):
        o,alive:=object_from(r,serial.bit_read(&rd,64))
        if !r.server || channel!=CHANNEL_SYSTEM || rd.error {return false}
        if !alive || r.simulation[o]!=.Lent || r.holder[o]==handle {return true}
        if r.auto[o] && r.holder[o]==0 {
            authority_set(h,o,handle,0)
        } else {
            command_push(h,{kind=.Authority_Requested,object=object_handle(r,o),connection=handle})
        }
    case u64(System_Message.Authority_Release):
        o,alive:=object_from(r,serial.bit_read(&rd,64))
        if !r.server || channel!=CHANNEL_SYSTEM || rd.error {return false}
        if alive && r.holder[o]==handle {authority_set(h,o,0,0)}
    case:
        return false
    }
    return true
}

// Takes the oldest held event out of the ring, into out when given.
@(private)
event_pop :: proc(r:^Repl,out:[]u8) -> (time:f64,size:int) {
    ring_read(&r.events,mem.ptr_to_bytes(&time))
    size=ring_peek_size(&r.events)
    ring_skip(&r.events,4)
    if out!=nil && size<=len(out) {ring_read(&r.events,out[:size])} else {ring_skip(&r.events,size)}
    return
}

// A replica arrived: deliver the events that waited for it and forget the ones that waited too long.
@(private)
events_flush :: proc(h:^Host,p:^Peer) {
    r:=&h.back.repl
    left:=r.events.used
    buffer:[RELIABLE_EVENT_MAX_BYTES+32]u8
    for left>0 {
        time,size:=event_pop(r,buffer[:])
        left-=12+size
        if size>len(buffer) || h.back.now-time>EVENT_HOLD_SECONDS {continue}
        rd:serial.Bit_Reader
        serial.bit_reader_init(&rd,buffer[:size])
        serial.bit_read(&rd,3)
        if event_deliver(h,p,CHANNEL_SYSTEM,&rd)==.Missing {
            ring_write(&r.events,mem.ptr_to_bytes(&time))
            ring_write_message(&r.events,buffer[:size])
        }
    }
}

// Queues an event on the connections it is for: one or all, and on a server
// only those that have the object, and that are not held unless it is Held.
// sent: bit 0, Reliable; bit 1, Held.
@(private)
event_fanout :: proc(h:^Host,to,object:u64,sent:u8,data:[]u8) {
    r:=&h.back.repl
    reliable,held:=sent&1!=0,sent&2!=0
    // What event_send counted leaves its count here, whether it reaches someone or not.
    if reliable {
        size:=u64(4+len(data))
        if to==0 {h.back.applied_all[CHANNEL_SYSTEM]+=size}
        for &p in h.back.peers {
            if to!=0 && p.state==.Connected && u64(peer_handle(h,&p))==to {p.channels[CHANNEL_SYSTEM].applied+=size}
        }
    }
    o,about:=object_from(r,object)
    if r.server && object!=0 && !about {return}
    for &p in h.back.peers {
        if p.state!=.Connected || (to!=0 && u64(peer_handle(h,&p))!=to) || r.server && p.repl.held && !held {continue}
        if r.server && about {
            if p.repl.link[o]==.None || p.repl.link[o]>=.Pending_Destroy {continue}
            p.repl.flags[o]|=LINK_TICK
            if p.repl.link[o]==.Created {bitset_set(p.repl.work,o)}
        }
        channel_queue(h,&p,reliable?CHANNEL_SYSTEM:CHANNEL_EVENTS,data)
    }
}

// Scope was evaluated: send the events that waited for it.
@(private)
events_replay :: proc(h:^Host) {
    r:=&h.back.repl
    buffer:[RELIABLE_EVENT_MAX_BYTES+32]u8
    for r.deferred.used>0 {
        header:[3]u64
        ring_read(&r.deferred,mem.slice_data_cast([]u8,header[:]))
        size:=ring_peek_size(&r.deferred)
        ring_skip(&r.deferred,4)
        ring_read(&r.deferred,buffer[:size])
        event_fanout(h,header[0],header[1],u8(header[2]),buffer[:size])
    }
}
