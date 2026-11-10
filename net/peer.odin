package mirai_net

import "core:crypto"
import "core:crypto/siphash"
import "core:hash/xxhash"
import "core:mem"
import "mirai:std/base"
import "mirai:std/serial"

// Connections. Every datagram starts with its type in one byte.
//
// Connecting takes four datagrams, each ending in a checksum keyed by the
// application, so strays and other applications are dropped before anything
// is parsed. The server answers a request with a cookie derived from the
// sender's address, its version and its lasting key, and keeps nothing. Only
// a client that returns the cookie, proving it receives at that address,
// costs the server a key exchange, and only one whose proof opens (the right
// invitation, the server it expects: see secure.odin) is answered again: a
// denial, or the acceptance and a connection slot. Anything else gets no
// answer, so nobody can make the host send datagrams to an address that did
// not return a cookie, nor learn from it whether an invitation was right.
// Requests and responses are padded to be larger than any answer to them.
//
// Data datagrams carry the low 16 bits of their sequence number and end in
// the tag of the cipher that authenticates them and hides everything after
// the sequence number (see secure.odin). Their body starts
// with the last sequence received and a bitfield of the ones before it, back
// to the oldest the other end may still wait for: what it had not resolved
// when it read the last acknowledgement it received, or SENT_WINDOW at most,
// more than it keeps in flight. A datagram older than the last one accepted
// is discarded, so "acknowledged" and "lost" are both final as soon as a
// later datagram is acknowledged: whatever was in a lost one is resent then.

MAX_CONNECTIONS :: 1024
@(private) SENT_WINDOW :: 256
@(private) ACK_WINDOW :: SENT_WINDOW-1 // datagrams before the last received an acknowledgement covers at most
@(private) LATE_WINDOW :: 32           // datagrams behind the last received that are still taken late
@(private) HANDSHAKE_BYTES :: 256
@(private) HANDSHAKE_INTERVAL :: 0.2
@(private) COOKIE_SECONDS :: 10
@(private) ACK_DELAY :: 0.03
@(private) SECTION_RESERVE :: 4 // bits kept free for the terminators of the sections still to come
@(private) DATA_HEADER :: 3     // bytes: type and sequence
@(private) CHECKSUM_BYTES :: 4
@(private) ACCEPT_BYTES :: 16   // server salt, object capacity and ticks of history, sealed
@(private) CANDIDATES :: 4      // addresses a client tries at once, and servers it proves itself to in one attempt
@(private) TRANSPORT_VERSION :: 5 // of the layout of the handshake and of the datagrams after it: raised when it changes

Connection_Stats :: struct {
    rtt,rtt_variance,jitter:f32, // seconds
    loss:f32,                    // share of sent datagrams found lost, smoothed
    send_rate,receive_rate:f32,  // bytes per second, smoothed
    packets_sent,packets_received,packets_acked,packets_lost:u64,
    packets_out_of_order:u64,    // received twice, or later than the window of acknowledgements, and discarded
    packets_late:u64,            // received late within that window: their reliable chunks and inputs taken
    packets_missed:u64,          // gaps in what was received
    packets_rejected:u64,        // came from its address and were not authentic
    bytes_sent,bytes_received:u64,
    messages_sent,messages_received,messages_dropped:u64,
    chunks_resent:u64,
    objects_in_scope:u32,
    object_bytes_sent,object_bytes_received:u64,
    objects_sent,objects_received:u64,
    inputs_received,inputs_missed:u64,
    inputs_early:u64,            // server: further ahead of its tick than the history, dropped
    budget_starved:u64,          // updates that left objects waiting for lack of budget
    send_limit:f32,              // bytes per second congestion control allows now
    send_limit_cuts:u64,         // times it cut the limit for congestion
    queue_free:[USER_CHANNELS]u32, // bytes free in the queue of each game channel; a message takes 4 more than its data
}

@(private) Packet_Type :: enum u8 {Request,Challenge,Response,Accepted,Denied,Data,Disconnect}
@(private) Peer_State :: enum u8 {Free,Requesting,Responding,Connected}
// A server that answered a request of the client's attempt.
@(private)
Challenger :: struct {
    address:Address,
    stamp,cookie:u64,
    server_key:Key, // the one the client pinned, or the one of the challenge
    shared:Key,     // what the client's key and server_key give
    proof:[TOKEN_BYTES+TAG_BYTES]u8, // the token, if any, and the tag, sealed with the proof key
    denied:bool,
}
// The connection attempt of a client: where it asks, and who answered. Each
// interval it asks every candidate that has not answered and presents its
// proof to every challenger; only the server with the invitation accepts it.
@(private)
Attempt :: struct {
    candidates:[CANDIDATES]Address,
    candidate_count:int,
    challengers:[CANDIDATES]Challenger,
    challenger_count:int,
    server_key:Key, // pinned; zero: none
    token:[TOKEN_BYTES]u8,
    denied:Disconnect_Reason, // why a challenger refused it, told when the attempt ends
}
@(private) Record_Kind :: enum u8 {Chunk,Create,Update,Destroy,Input}
@(private) Record :: struct {kind:Record_Kind,flags:u8,aux:u16,object:u32,mask:u64}
@(private) Sent :: struct {time:f64,known:u64,first:u32,count,bytes:u16} // known: what its acknowledgement settles
// Bit i: the datagram i+1 before the newest received or acknowledged arrived.
@(private) Ack_Bits :: [ACK_WINDOW/64+1]u64

@(private)
Peer :: struct {
    state:Peer_State,
    index,generation:u32,
    address:Address,
    client_salt,server_salt,cookie:u64,
    stamp:u64, // milliseconds of the server's clock when it made the cookie
    started,last_send,last_receive,next_handshake:f64,
    send_counter,recv_counter:u64, // datagrams sent; sequence of the newest one received
    send_seq,sent_tail:u16,
    recv_bits:Ack_Bits,
    late_bits:u32,  // received late and taken, the first LATE_WINDOW of recv_bits; never acknowledged
    ack_known:u64,  // the oldest datagram received that the other end may not have resolved yet
    recv_any,ack_pending,has_rtt:bool,
    recv_time:f64,
    sent:[SENT_WINDOW]Sent,
    records:[]Record,
    record_head,record_tail:u32,
    rtt,rtt_variance,jitter:f64,
    tokens,token_time:f64,
    // Congestion control: the rate the connection may send at, judged over intervals of two round trips.
    rate:f64,
    min_rtt,window_min,window_time:f64, // smallest RTT of the last window, and of the current one
    cc_time,cc_rtt:f64,                 // start of the interval and the sum of its RTT samples
    cc_acked,cc_lost:u64,               // acked and lost datagrams at its start
    cc_samples:int,
    cc_limited:bool,                    // the connection ran out of rate in it
    rate_time:f64,
    rate_sent,rate_received:u64,
    channels:[MAX_CHANNELS]Channel,
    stats:Connection_Stats,
    secure:Peer_Secure,
    repl:Peer_Repl,
}

@(private) seq_newer :: #force_inline proc "contextless" (a,b:u16) -> bool {return i16(a-b)>0}

@(private)
ack_bit :: #force_inline proc "contextless" (bits:^Ack_Bits,behind:u64) -> bool {
    return behind>=1 && behind<=ACK_WINDOW && bits[(behind-1)/64]&(1<<((behind-1)%64))!=0
}
// Moves the bits shift datagrams older and marks the one that was newest.
@(private)
ack_bits_advance :: proc "contextless" (bits:^Ack_Bits,shift:u64) {
    if shift>ACK_WINDOW {bits^={};return}
    words,rest:=int(shift/64),shift%64
    #reverse for &word,i in bits {
        from:=i-words
        word=from>=0?bits[from]<<rest:0
        if rest>0 && from>=1 {word|=bits[from-1]>>(64-rest)}
    }
    bits[(shift-1)/64]|=1<<((shift-1)%64)
}
@(private)
ack_bits_write :: proc(w:^serial.Bit_Writer,bits:^Ack_Bits,count:int) {
    serial.bit_write(w,u64(count),8)
    for i:=0;i<count;i+=64 {serial.bit_write(w,bits[i/64],min(count-i,64))}
}
@(private)
ack_bits_read :: proc(r:^serial.Bit_Reader) -> (bits:Ack_Bits,count:u64) {
    count=serial.bit_read(r,8)
    for i:=u64(0);i<count;i+=64 {bits[i/64]=serial.bit_read(r,int(min(count-i,64)))}
    return
}

// The sequence number nearest to reference whose low 16 bits are seq.
@(private)
counter_expand :: proc "contextless" (reference:u64,seq:u16) -> (counter:u64,ok:bool) {
    delta:=i64(i16(seq-u16(reference)))
    if delta<0 && u64(-delta)>reference {return 0,false}
    return u64(i64(reference)+delta),true
}

@(private)
peer_allocate :: proc(h:^Host,p:^Peer) {
    p.index=u32(mem.ptr_sub(p,&h.back.peers[0]))
    p.records=host_make(h,Record,h.desc.replication.records)
    for desc,i in h.channels {
        if i<h.channel_count || (i>=USER_CHANNELS && h.desc.protocol!=nil) {channel_allocate(h,&p.channels[i],desc)}
    }
    if h.desc.protocol!=nil {repl_peer_allocate(h,p)}
}
@(private)
peer_release :: proc(h:^Host,p:^Peer) {
    delete(p.records,h.allocator)
    for &c in p.channels {channel_release(h,&c)}
    repl_peer_release(h,p)
}
@(private)
peer_handle :: #force_inline proc(h:^Host,p:^Peer) -> Connection {return Connection(base.handle_make(p.index,p.generation))}
@(private)
peer_from :: proc(h:^Host,connection:Connection) -> ^Peer {
    index:=int(base.handle_index(base.Handle(connection)))
    if connection==0 || index>=len(h.back.peers) {return nil}
    p:=&h.back.peers[index]
    return p.state==.Connected && p.generation==base.handle_generation(base.Handle(connection))?p:nil
}
// The key of an address in Back.by_address: under the secret of the host, so
// a sender cannot choose where its datagrams look.
@(private)
address_key :: proc(b:^Back,address:Address) -> u64 {
    message:[19]u8
    address:=address
    message[0],message[1],message[2]=u8(address.kind),u8(address.port),u8(address.port>>8)
    copy(message[3:],address.ip[:])
    return siphash.sum_2_4(message[:],b.secret[:])
}
@(private)
peer_find :: proc(b:^Back,address:Address) -> ^Peer {
    index,listed:=base.hash_map_get(&b.by_address,address_key(b,address))
    if !listed {return nil}
    p:=&b.peers[index]
    return p if p.state!=.Free && p.address==address else nil
}
// A peer is listed under its address from when it leaves Free until it is
// Free again, and around a change of its address.
@(private)
peer_list :: proc(b:^Back,p:^Peer) {
    base.hash_map_set(&b.by_address,address_key(b,p.address),p.index)
}
@(private)
peer_unlist :: proc(b:^Back,p:^Peer) {
    key:=address_key(b,p.address)
    if index,listed:=base.hash_map_get(&b.by_address,key);listed && index==p.index {base.hash_map_remove(&b.by_address,key)}
}

@(private)
peer_reset :: proc(h:^Host,p:^Peer,address:Address) {
    now:=h.back.now
    p.address=address
    p.client_salt,p.server_salt,p.cookie,p.stamp=0,0,0,0
    p.started,p.last_send,p.last_receive,p.next_handshake=now,now,now,now
    p.send_counter,p.recv_counter,p.send_seq,p.sent_tail,p.recv_bits,p.late_bits,p.ack_known=0,0,0,0,{},0,0
    p.recv_any,p.ack_pending,p.has_rtt=false,false,false
    p.record_head,p.record_tail=0,0
    p.rtt,p.rtt_variance,p.jitter=0,0,0
    p.rate=f64(h.desc.send_rate)
    p.tokens,p.token_time=send_burst(h,p.rate),now
    p.min_rtt,p.window_min,p.window_time=0,0,now
    p.cc_time,p.cc_rtt,p.cc_acked,p.cc_lost,p.cc_samples,p.cc_limited=now,0,0,0,0,false
    p.rate_time,p.rate_sent,p.rate_received=now,0,0
    p.stats={}
    p.secure={}
    for &c in p.channels {
        if c.active {channel_reset(&c)}
    }
}

@(private)
peer_connect :: proc(h:^Host,request:^Connect_Request) {
    p:=&h.back.peers[0]
    if p.state!=.Free {peer_drop(h,p,.Closed,true)}
    peer_reset(h,p,request.candidates[0])
    p.client_salt=base.splitmix_next(&h.back.rng)
    p.state=.Requesting
    peer_list(&h.back,p)
    secure_client_begin(p,&request.credentials)
    a:=&h.back.attempt
    a.candidates,a.candidate_count=request.candidates,clamp(request.count,1,CANDIDATES)
    a.server_key,a.token=request.credentials.server_key,request.credentials.token
}
@(private)
challenger_find :: proc(a:^Attempt,address:Address) -> ^Challenger {
    for &c in a.challengers[:a.challenger_count] {
        if c.address==address {return &c}
    }
    return nil
}

@(private)
peer_established :: proc(h:^Host,p:^Peer,history:int) {
    if p.state==.Free {peer_list(&h.back,p)}
    p.state=.Connected
    p.last_receive=h.back.now
    command_push(h,{kind=.Connected,connection=peer_handle(h,p),client_id=p.secure.client_id,tick=u32(history)})
    repl_peer_connected(h,p)
}

// Frees the slot and reports the end of the connection, or of the attempt.
@(private)
peer_drop :: proc(h:^Host,p:^Peer,reason:Disconnect_Reason,notify:bool) {
    if p.state==.Free {return}
    if notify && p.state==.Connected {peer_notice(h,p,reason)}
    if p.state==.Connected {repl_peer_disconnected(h,p)}
    command_push(h,{kind=.Disconnected,connection=peer_handle(h,p),reason=reason})
    peer_unlist(&h.back,p)
    p.state=.Free
    p.generation+=1
    p.secure={}
    if h.desc.mode==.Client {crypto.zero_explicit(&h.back.attempt,size_of(Attempt))}
}

// Tells the other end why the connection ends, under the key of the connection.
@(private)
peer_notice :: proc(h:^Host,p:^Peer,reason:Disconnect_Reason) {
    w:serial.Bit_Writer
    data_begin(h,p,&w,.Disconnect)
    serial.bit_write(&w,u64(reason),8)
    bytes:=data_seal(h,p,&w)
    for _ in 0..<2 {transport_send(h,p.address,bytes)}
}

@(private)
peer_service :: proc(h:^Host,p:^Peer) {
    now:=h.back.now
    switch p.state {
    case .Free:
    case .Requesting,.Responding:
        if now-p.started>h.desc.connect_timeout {
            denied:=h.back.attempt.denied
            peer_drop(h,p,denied!=.None?denied:p.secure.refused?.Denied_Security:.Connect_Timeout,false)
            return
        }
        if now>=p.next_handshake {
            p.next_handshake=now+HANDSHAKE_INTERVAL
            handshake_attempt(h,p)
        }
    case .Connected:
        if now-p.last_receive>h.desc.timeout {peer_drop(h,p,.Timeout,true);return}
        if elapsed:=now-p.rate_time;elapsed>=0.5 {
            sent,received:=f32(f64(p.stats.bytes_sent-p.rate_sent)/elapsed),f32(f64(p.stats.bytes_received-p.rate_received)/elapsed)
            p.stats.send_rate+=(sent-p.stats.send_rate)*0.5
            p.stats.receive_rate+=(received-p.stats.receive_rate)*0.5
            p.rate_time,p.rate_sent,p.rate_received=now,p.stats.bytes_sent,p.stats.bytes_received
        }
        congestion_update(h,p)
    }
}

@(private) CC_QUEUE_DELAY :: 0.06 // s of RTT above the smallest that mean a queue is building on the path
@(private) CC_LOSS_SHARE :: 0.02  // share of an interval's datagrams lost that, with that queue, is congestion
@(private) CC_WINDOW :: 60.0      // s over which the smallest RTT is remembered: longer than any queue lasts

// Additive increase, multiplicative decrease of the byte rate, steered by the queue the connection builds
// on its path: the RTT of an interval above the smallest one of the last CC_WINDOW seconds. Losses alone do
// not cut the rate, so a link that drops datagrams at random keeps it. A queue cuts it by a tenth, before
// the buffer overflows; a queue with losses, by a quarter. An interval without a queue that wanted to send
// more than the rate allowed adds send_rate/128.
@(private)
congestion_update :: proc(h:^Host,p:^Peer) {
    now:=h.back.now
    if now-p.cc_time<max(2*p.rtt,0.1) {return}
    ceiling:=f64(h.desc.send_rate)
    floor:=min(f64(h.desc.min_send_rate),ceiling)
    acked,lost:=p.stats.packets_acked-p.cc_acked,p.stats.packets_lost-p.cc_lost
    queued:=p.cc_samples>0 && p.cc_rtt/f64(p.cc_samples)-p.min_rtt>CC_QUEUE_DELAY
    if queued {
        congested:=lost>0 && f64(lost)>CC_LOSS_SHARE*f64(acked+lost)
        p.rate=max(p.rate*(congested?0.75:0.9),floor)
        p.stats.send_limit_cuts+=1
    } else if p.cc_limited {
        p.rate=min(p.rate+ceiling/128,ceiling)
    }
    if now-p.window_time>CC_WINDOW {
        if p.window_min>0 {p.min_rtt=p.window_min}
        p.window_min,p.window_time=0,now
    }
    p.stats.send_limit=f32(p.rate)
    p.cc_time,p.cc_rtt,p.cc_samples,p.cc_limited=now,0,0,false
    p.cc_acked,p.cc_lost=p.stats.packets_acked,p.stats.packets_lost
}

// Tokens the bucket holds at most: one tick of the rate, so that a connection paces its datagrams over
// the updates of a tick instead of sending a burst after a quiet spell.
@(private)
send_burst :: proc "contextless" (h:^Host,rate:f64) -> f64 {
    return max(rate/f64(h.desc.tick_rate),PACKET_BYTES*2)
}

@(private)
transport_send :: proc(h:^Host,to:Address,bytes:[]u8) {
    h.back.stats.packets_sent+=1
    h.back.stats.bytes_sent+=u64(len(bytes))
    h.desc.transport.send(h.desc.transport.data,to,bytes)
}

// The checksum of a handshake datagram, keyed by the application: it filters strays, it does not authenticate.
@(private)
checksum_write :: proc(bytes:[]u8,key:u64) {
    end:=len(bytes)-CHECKSUM_BYTES
    sum:=u32le(u32(xxhash.XXH3_64_with_seed(bytes[:end],key)))
    mem.copy(&bytes[end],&sum,CHECKSUM_BYTES)
}
@(private)
checksum_check :: proc(bytes:[]u8,key:u64) -> bool {
    end:=len(bytes)-CHECKSUM_BYTES
    sum:u32le
    mem.copy(&sum,&bytes[end],CHECKSUM_BYTES)
    return u32(sum)==u32(xxhash.XXH3_64_with_seed(bytes[:end],key))
}

// A datagram of a connection: its type, its sequence, a body and the tag that authenticates the three.
@(private)
data_begin :: proc(h:^Host,p:^Peer,w:^serial.Bit_Writer,type:Packet_Type) {
    out:=h.back.outgoing[:]
    out[0],out[1],out[2]=u8(type),u8(p.send_counter),u8(p.send_counter>>8)
    serial.bit_writer_init(w,out[DATA_HEADER:PACKET_BYTES-TAG_BYTES])
}
@(private)
data_seal :: proc(h:^Host,p:^Peer,w:^serial.Bit_Writer) -> []u8 {
    out:=h.back.outgoing[:]
    end:=DATA_HEADER+len(serial.bit_writer_flush(w))
    secure_seal(h,p,out[:DATA_HEADER],out[DATA_HEADER:end],out[end:][:TAG_BYTES])
    return out[:end+TAG_BYTES]
}
// The body of a datagram of a connection and its whole sequence number. Not ok: it is not authentic.
@(private)
data_open :: proc(h:^Host,p:^Peer,bytes:[]u8) -> (body:[]u8,counter:u64,ok:bool) {
    end:=len(bytes)-TAG_BYTES
    if end<DATA_HEADER {return}
    counter=counter_expand(p.recv_counter,u16(bytes[1])|u16(bytes[2])<<8) or_return
    body=bytes[DATA_HEADER:end]
    ok=secure_open(h,p,counter,bytes[:DATA_HEADER],body,bytes[end:])
    return
}

@(private)
cookie_make :: proc(b:^Back,address:Address,salt,stamp:u64) -> u64 {
    message:[35]u8
    salt,stamp,address:=salt,stamp,address
    message[0],message[1],message[2]=u8(address.kind),u8(address.port),u8(address.port>>8)
    copy(message[3:19],address.ip[:])
    mem.copy(&message[19],&salt,8)
    mem.copy(&message[27],&stamp,8)
    return siphash.sum_2_4(message[:],b.secret[:])
}

@(private)
handshake_begin :: proc(h:^Host,w:^serial.Bit_Writer,type:Packet_Type,salt:u64) {
    out:=h.back.outgoing[:]
    out[0]=u8(type)
    serial.bit_writer_init(w,out[1:PACKET_BYTES-CHECKSUM_BYTES])
    serial.bit_write(w,salt,64)
}
@(private)
handshake_send :: proc(h:^Host,w:^serial.Bit_Writer,to:Address,pad:=0) {
    out:=h.back.outgoing[:]
    total:=1+len(serial.bit_writer_flush(w))+CHECKSUM_BYTES
    if total<pad {
        mem.zero_slice(out[total-CHECKSUM_BYTES:pad])
        total=pad
    }
    checksum_write(out[:total],h.back.key)
    transport_send(h,to,out[:total])
}
// Client: one interval of its attempt. A request to every candidate that has not answered, and the proof to every
// server that did and has not refused it.
@(private)
handshake_attempt :: proc(h:^Host,p:^Peer) {
    a:=&h.back.attempt
    for candidate in a.candidates[:a.candidate_count] {
        if challenger_find(a,candidate)==nil {handshake_request(h,p,candidate)}
    }
    for &c in a.challengers[:a.challenger_count] {
        if !c.denied {handshake_response(h,p,&c)}
    }
}
@(private)
handshake_request :: proc(h:^Host,p:^Peer,to:Address) {
    w:serial.Bit_Writer
    handshake_begin(h,&w,.Request,p.client_salt)
    handshake_send(h,&w,to,HANDSHAKE_BYTES)
}
@(private)
handshake_response :: proc(h:^Host,p:^Peer,c:^Challenger) {
    w:serial.Bit_Writer
    handshake_begin(h,&w,.Response,p.client_salt)
    serial.bit_write(&w,c.stamp,64)
    serial.bit_write(&w,c.cookie,64)
    serial.bit_write(&w,host_protocol_hash(h),64)
    s:=&p.secure
    serial.bit_write_bool(&w,s.has_token)
    serial.bit_write_align(&w)
    serial.bit_write_bytes(&w,s.public[:])
    serial.bit_write_bytes(&w,c.proof[:s.has_token?TOKEN_BYTES+TAG_BYTES:TAG_BYTES])
    handshake_send(h,&w,c.address,HANDSHAKE_BYTES)
}
@(private)
handshake_deny :: proc(h:^Host,to:Address,salt:u64,reason:Disconnect_Reason) {
    w:serial.Bit_Writer
    handshake_begin(h,&w,.Denied,salt)
    serial.bit_write(&w,u64(reason),8)
    handshake_send(h,&w,to)
    h.back.stats.handshakes_refused+=1
}
@(private)
handshake_accept :: proc(h:^Host,p:^Peer) {
    w:serial.Bit_Writer
    handshake_begin(h,&w,.Accepted,p.client_salt)
    s:=&p.secure
    sealed:[ACCEPT_BYTES+TAG_BYTES]u8
    salt,objects,history:=u64le(p.server_salt),u32le(h.desc.replication.max_objects),u32le(h.history)
    mem.copy(&sealed[0],&salt,8)
    mem.copy(&sealed[8],&objects,4)
    mem.copy(&sealed[12],&history,4)
    aead_seal(&s.accept,0,s.public[:],sealed[:ACCEPT_BYTES],sealed[ACCEPT_BYTES:])
    serial.bit_write_bytes(&w,s.public[:])
    serial.bit_write_bytes(&w,sealed[:])
    handshake_send(h,&w,p.address)
}

// What both ends must agree on besides the version: the layout of the
// datagrams, channels and replication protocol.
@(private)
host_protocol_hash :: proc(h:^Host) -> u64 {
    hash:=base.hash_combine(h.desc.protocol!=nil?h.desc.protocol.hash:0,TRANSPORT_VERSION)
    for c in h.channels[:USER_CHANNELS] {
        hash=base.hash_combine(hash,u64(c.kind)<<32|u64(c.max_message_bytes))
    }
    return hash
}

@(private)
packet_receive :: proc(h:^Host,bytes:[]u8,from:Address) {
    b:=&h.back
    if len(bytes)<DATA_HEADER+1+CHECKSUM_BYTES || len(bytes)>PACKET_BYTES || bytes[0]>u8(max(Packet_Type)) {b.stats.packets_invalid+=1;return}
    type:=Packet_Type(bytes[0])
    p:=peer_find(b,from)
    r:serial.Bit_Reader
    if type==.Data || type==.Disconnect {
        if p==nil || p.state!=.Connected {b.stats.packets_invalid+=1;return}
        body,counter,authentic:=data_open(h,p,bytes)
        if !authentic {
            b.stats.packets_invalid+=1
            p.stats.packets_rejected+=1
            return
        }
        serial.bit_reader_init(&r,body)
        if type==.Disconnect {
            reason:=serial.bit_read(&r,8)
            peer_drop(h,p,reason>u64(max(Disconnect_Reason)) || reason==0?.Closed:Disconnect_Reason(reason),false)
            return
        }
        p.stats.packets_received+=1
        p.stats.bytes_received+=u64(len(bytes))
        if !peer_receive(h,p,&r,counter) && p.state==.Connected {
            b.stats.packets_invalid+=1
            peer_drop(h,p,.Protocol_Error,true)
        }
        return
    }
    if !checksum_check(bytes,b.key) {b.stats.packets_invalid+=1;return}
    serial.bit_reader_init(&r,bytes[1:len(bytes)-CHECKSUM_BYTES])
    salt:=serial.bit_read(&r,64)
    server:=h.desc.mode==.Server
    // An answer to an attempt comes from wherever its server is: the address
    // asked, its own on the network behind a router that sends a datagram back
    // to the network it came from, or one that heard the broadcast. The salt
    // says it is to the attempt, which goes on with the address that accepts.
    if !server && (type==.Challenge || type==.Accepted || type==.Denied) {
        p=nil
        if attempt:=&b.peers[0];(attempt.state==.Requesting || attempt.state==.Responding) && attempt.client_salt==salt {p=attempt}
    }
    #partial switch type {
    case .Request:
        if !server || len(bytes)!=HANDSHAKE_BYTES || r.error {b.stats.packets_invalid+=1;return}
        // Every request gets the same answer, smaller than it: the version and the key are no secret.
        w:serial.Bit_Writer
        stamp:=u64(b.now*1000)
        handshake_begin(h,&w,.Challenge,salt)
        serial.bit_write(&w,stamp,64)
        serial.bit_write(&w,cookie_make(b,from,salt,stamp),64)
        serial.bit_write(&w,u64(h.desc.version),32)
        serial.bit_write_align(&w)
        serial.bit_write_bytes(&w,b.secure.public[:])
        handshake_send(h,&w,from)
    case .Response:
        stamp:=serial.bit_read(&r,64)
        cookie:=serial.bit_read(&r,64)
        hash:=serial.bit_read(&r,64)
        has_token:=serial.bit_read_bool(&r)
        serial.bit_read_align(&r)
        client_public:Key
        serial.bit_read_bytes(&r,client_public[:])
        proof:[TOKEN_BYTES+TAG_BYTES]u8
        sealed:=proof[:has_token?TOKEN_BYTES+TAG_BYTES:TAG_BYTES]
        serial.bit_read_bytes(&r,sealed)
        if !server || len(bytes)!=HANDSHAKE_BYTES || r.error {b.stats.packets_invalid+=1;return}
        now:=u64(b.now*1000)
        if stamp>now || now-stamp>COOKIE_SECONDS*1000 || cookie!=cookie_make(b,from,salt,stamp) {b.stats.handshakes_dropped+=1;return}
        if p!=nil {
            if p.client_salt==salt {handshake_accept(h,p);return}
            // Only a cookie made after the connection it would replace: an old response sent again does not end it.
            if stamp<=p.stamp {b.stats.handshakes_dropped+=1;return}
        }
        // The same attempt reached this server by another of its candidates: it is connected already.
        for &other in b.peers {
            if other.state==.Connected && &other!=p && other.client_salt==salt {b.stats.handshakes_dropped+=1;return}
        }
        if hash!=host_protocol_hash(h) {handshake_deny(h,from,salt,.Denied_Protocol);return}
        if b.secure.handshakes<=0 {b.stats.handshakes_deferred+=1;return}
        b.secure.handshakes-=1
        session:Peer_Secure
        reason,proven:=secure_server_accept(h,&session,salt,&client_public,has_token,sealed)
        // A wrong invitation, or a client that expects another server: no answer tells it which.
        if !proven {b.stats.handshakes_dropped+=1;return}
        if reason!=.None {handshake_deny(h,from,salt,reason);return}
        if session.client_id!=0 {
            for &other in b.peers {
                if other.state==.Connected && &other!=p && other.secure.client_id==session.client_id {peer_drop(h,&other,.Replaced,true)}
            }
        }
        slot:=p
        for &candidate in b.peers {
            if slot!=nil {break}
            if candidate.state==.Free {slot=&candidate}
        }
        if slot==nil {handshake_deny(h,from,salt,.Denied_Full);return}
        if p!=nil {peer_drop(h,p,.Closed,false)}
        peer_reset(h,slot,from)
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        slot.client_salt,slot.server_salt,slot.stamp=salt,base.splitmix_next(&b.rng),stamp
        slot.secure=session
        peer_established(h,slot,h.history)
        handshake_accept(h,slot)
    case .Challenge:
        stamp:=serial.bit_read(&r,64)
        cookie:=serial.bit_read(&r,64)
        version:=u32(serial.bit_read(&r,32))
        serial.bit_read_align(&r)
        server_key:Key
        serial.bit_read_bytes(&r,server_key[:])
        if server || r.error || p==nil {b.stats.packets_invalid+=1;return}
        a:=&b.attempt
        if challenger_find(a,from)!=nil {return}
        if a.challenger_count>=CANDIDATES {b.stats.packets_invalid+=1;return}
        // With several candidates, one of another version may be another server: the attempt goes on.
        if version!=h.desc.version {
            if a.candidate_count==1 {peer_drop(h,p,.Denied_Version,false)} else {a.denied=.Denied_Version}
            return
        }
        c:=&a.challengers[a.challenger_count]
        c^={address=from,stamp=stamp,cookie=cookie}
        if !secure_client_prove(h,p,c,&server_key) {
            p.secure.refused=true
            b.stats.packets_invalid+=1
            return
        }
        a.challenger_count+=1
        p.state=.Responding
        handshake_response(h,p,c)
    case .Accepted:
        server_public:Key
        sealed:[ACCEPT_BYTES+TAG_BYTES]u8
        serial.bit_read_bytes(&r,server_public[:])
        serial.bit_read_bytes(&r,sealed[:])
        c:=p!=nil?challenger_find(&b.attempt,from):nil
        if server || r.error || c==nil || c.denied || p.state!=.Responding {b.stats.packets_invalid+=1;return}
        if !secure_client_finish(h,p,c,&server_public,sealed[:]) {
            p.secure.refused=true
            b.stats.packets_invalid+=1
            return
        }
        crypto.zero_explicit(&b.attempt,size_of(Attempt))
        if from!=p.address {
            peer_unlist(b,p)
            p.address=from
            peer_list(b,p)
            b.stats.readdressed+=1
        }
        answer:=sealed[:ACCEPT_BYTES]
        server_salt:u64le
        objects,history:u32le
        mem.copy(&server_salt,&answer[0],8)
        mem.copy(&objects,&answer[8],4)
        mem.copy(&history,&answer[12],4)
        p.server_salt=u64(server_salt)
        // The history of the server is the client's: at most what this end would keep itself.
        if int(objects)>h.desc.replication.max_objects || history==0 || int(history)>history_ticks(HISTORY_MAX_SECONDS,h.desc.tick_rate) {
            // The server holds the connection already: it hears why, and this end never had it.
            peer_notice(h,p,.Capacity)
            peer_drop(h,p,.Capacity,false)
            return
        }
        peer_established(h,p,int(history))
    case .Denied:
        reason:=serial.bit_read(&r,8)
        c:=p!=nil?challenger_find(&b.attempt,from):nil
        if server || r.error || c==nil {b.stats.packets_invalid+=1;return}
        why:=reason>u64(max(Disconnect_Reason)) || reason==0?Disconnect_Reason.Closed:Disconnect_Reason(reason)
        // With several candidates the one that refused may be another server: the attempt ends with why when its time is up.
        if b.attempt.candidate_count==1 {peer_drop(h,p,why,false);return}
        c.denied,b.attempt.denied=true,why
    case:
        b.stats.packets_invalid+=1
    }
}

@(private)
record_push :: proc(p:^Peer,record:Record) -> bool {
    if p.record_tail-p.record_head>=u32(len(p.records)) {return false}
    p.records[p.record_tail%u32(len(p.records))]=record
    p.record_tail+=1
    return true
}

// The fate of datagram seq is known: tell whoever put something in it.
@(private)
peer_resolve :: proc(h:^Host,p:^Peer,seq:u16,received:bool) {
    sent:=&p.sent[seq%SENT_WINDOW]
    if received {p.stats.packets_acked+=1} else {p.stats.packets_lost+=1}
    p.stats.loss+=((received?0:1)-p.stats.loss)*0.02
    for i in sent.first..<sent.first+u32(sent.count) {
        record:=p.records[i%u32(len(p.records))]
        if record.kind==.Chunk {channel_resolve(p,record,received)} else {repl_resolve(h,p,record,seq,received)}
    }
    p.record_head=sent.first+u32(sent.count)
}

// False when the datagram is malformed: the caller closes the connection.
@(private)
peer_receive :: proc(h:^Host,p:^Peer,r:^serial.Bit_Reader,counter:u64) -> bool {
    now:=h.back.now
    has_ack:=serial.bit_read_bool(r)
    ack:=u16(serial.bit_read(r,16))
    ack_bits,ack_count:=ack_bits_read(r)
    delay:=f64(serial.bit_read(r,8))*0.001
    if r.error {return false}
    if p.recv_any && counter<=p.recv_counter {
        // Within the window of acknowledgements and not received before: it came late. What in it is safe
        // out of order is taken; it is not acknowledged, so the sender resends the rest as if it were lost.
        behind:=p.recv_counter-counter
        if behind==0 || behind>LATE_WINDOW || ack_bit(&p.recv_bits,behind) || p.late_bits&(1<<(behind-1))!=0 {p.stats.packets_out_of_order+=1;return true}
        p.late_bits|=1<<(behind-1)
        p.stats.packets_late+=1
        p.last_receive=now
        if !time_read(h,p,r,late=true) || p.state!=.Connected {return p.state!=.Connected}
        if !channels_read(h,p,r,late=true) || p.state!=.Connected {return p.state!=.Connected}
        return true
    }
    if has_ack && !seq_newer(p.send_seq,ack) {return false}
    if p.recv_any {
        shift:=counter-p.recv_counter
        ack_bits_advance(&p.recv_bits,shift)
        p.late_bits<<=shift
        p.stats.packets_missed+=shift-1
    }
    p.recv_counter,p.recv_any,p.ack_pending=counter,true,true
    p.last_receive,p.recv_time=now,now
    if has_ack {
        for p.sent_tail!=p.send_seq && !seq_newer(p.sent_tail,ack) {
            behind:=u16(ack-p.sent_tail)
            received:=behind==0 || (u64(behind)<=ack_count && ack_bit(&ack_bits,u64(behind)))
            if behind==0 {
                sample:=max(now-p.sent[ack%SENT_WINDOW].time-delay,0)
                if !p.has_rtt {
                    p.rtt,p.rtt_variance,p.has_rtt=sample,sample*0.5,true
                } else {
                    deviation:=abs(sample-p.rtt)
                    p.rtt_variance+=(deviation-p.rtt_variance)*0.25
                    p.jitter+=(deviation-p.jitter)*0.0625
                    p.rtt+=(sample-p.rtt)*0.125
                }
                p.stats.rtt,p.stats.rtt_variance,p.stats.jitter=f32(p.rtt),f32(p.rtt_variance),f32(p.jitter)
                if p.min_rtt==0 || sample<p.min_rtt {p.min_rtt=sample}
                if p.window_min==0 || sample<p.window_min {p.window_min=sample}
                p.cc_rtt+=sample
                p.cc_samples+=1
            }
            if received {p.ack_known=max(p.ack_known,p.sent[p.sent_tail%SENT_WINDOW].known)}
            peer_resolve(h,p,p.sent_tail,received)
            if p.state!=.Connected {return true}
            p.sent_tail+=1
        }
    }
    if !time_read(h,p,r) || p.state!=.Connected {return p.state!=.Connected}
    if !channels_read(h,p,r) || p.state!=.Connected {return p.state!=.Connected}
    if !objects_read(h,p,r) || p.state!=.Connected {return p.state!=.Connected}
    return !r.error
}

@(private)
peer_wants_send :: proc(h:^Host,p:^Peer) -> bool {
    b:=&h.back
    idle:=b.now-p.last_send
    if b.send_pending || b.clock_due {return true}
    if idle>=h.desc.keepalive || (p.ack_pending && idle>=ACK_DELAY) {return true}
    if idle>=1/f64(h.desc.tick_rate) && channels_pending(p) {return true}
    return p.sent_tail!=p.send_seq && idle>=clamp(p.rtt*2+p.rtt_variance*4,0.1,1)
}

@(private)
peer_send :: proc(h:^Host,p:^Peer) {
    b:=&h.back
    p.tokens=min(p.tokens+(b.now-p.token_time)*p.rate,send_burst(h,p.rate))
    p.token_time=b.now
    if p.tokens<=0 && b.now-p.last_send<0.25 {
        p.cc_limited=true
        return
    }
    for &c in p.channels {c.spent=0}
    budget:=repl_budget(h,p)
    for packet in 0..<h.desc.packets_per_update {
        if u16(p.send_seq-p.sent_tail)>=SENT_WINDOW-1 {break}
        if packet>0 && p.tokens<=0 {break}
        first_record:=p.record_tail
        seq:=p.send_seq
        w:serial.Bit_Writer
        data_begin(h,p,&w,.Data)
        serial.bit_write_bool(&w,p.recv_any)
        serial.bit_write(&w,u64(u16(p.recv_counter)),16)
        ack_bits_write(&w,&p.recv_bits,p.recv_any && p.recv_counter>p.ack_known?int(min(p.recv_counter-p.ack_known,ACK_WINDOW)):0)
        serial.bit_write(&w,u64(clamp((b.now-p.recv_time)*1000,0,255)),8)
        wrote:=time_write(h,p,&w,seq)
        if channels_write(h,p,&w,SECTION_RESERVE) {wrote=true}
        more:=false
        last:=packet+1>=h.desc.packets_per_update || u16(p.send_seq+1-p.sent_tail)>=SENT_WINDOW-1 || p.tokens<=PACKET_BYTES
        if objects_write(h,p,&w,seq,&budget,&more,last) {wrote=true}
        if packet>0 && !wrote {
            p.record_tail=first_record
            break
        }
        bytes:=data_seal(h,p,&w)
        p.sent[seq%SENT_WINDOW]={time=b.now,known=p.recv_any?p.recv_counter+1:0,first=first_record,count=u16(p.record_tail-first_record),bytes=u16(len(bytes))}
        p.send_seq+=1
        p.send_counter+=1
        p.tokens-=f64(len(bytes))
        p.last_send=b.now
        p.ack_pending=false
        p.stats.packets_sent+=1
        p.stats.bytes_sent+=u64(len(bytes))
        transport_send(h,p.address,bytes)
        if !more && !channels_pending(p) {break}
        if p.tokens<=0 {p.cc_limited=true}
    }
}
