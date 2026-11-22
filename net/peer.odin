package mirai_net

import "core:crypto"
import "core:crypto/siphash"
import "core:encoding/endian"
import "base:intrinsics"
import "core:hash/xxhash"
import "core:math"
import "core:mem"
import "core:slice"
import "mirai:std/base"
import "mirai:std/serial"

// Connections. Every datagram starts with its type in one byte.
//
// Connecting is the handshake of secure.odin: an Initiate and its Response,
// each handshake datagram ending in a checksum keyed by the application, so
// strays and other applications are dropped before anything is parsed. The
// Initiate carries the client's first datagram of data, so what it queued
// while connecting reaches the server before anything comes back. A server
// with an invitation answers nothing else; one without first answers a Hello
// with its key and a cookie derived from the sender's address, and keeps
// nothing until the Initiate returns that cookie. An Initiate that does not
// open, or that the server accepted before, gets no answer at all; one that
// opens makes a connection and gets the Response, and so does every copy of
// it from the same address until the client answers under the keys of the
// connection. Until then the server sends that address nothing else but the
// Disconnect of a game that closes it, and the Initiate and the Hello are
// padded to be larger than any answer to them.
//
// Data datagrams carry the low 16 bits of their sequence number and the slot
// of their connection at the receiver, and end in the tag of the cipher that
// authenticates them and hides everything after the header (see secure.odin).
// A connection follows its other end to a new address on the first datagram
// from there that opens under its key and is newer than any it accepted, as
// WireGuard roams: a router that changed the port loses nothing, and a
// datagram replayed from elsewhere moves nothing. Their body starts
// with the last sequence received and which of the ones before it arrived,
// back to the oldest the other end may still wait for: what it had not
// resolved when it read the last acknowledgement it received, or SENT_WINDOW
// at most, more than it keeps in flight. That record goes as runs of arrived
// and missing datagrams, so a long stream with few losses costs a few bytes.
// A receiver acknowledges at once every ACK_EVERY datagrams that carried
// reliable chunks, and otherwise within ACK_DELAY or with what it sends anyway.
// A datagram older than the last one accepted
// is discarded, so "acknowledged" and "lost" are both final as soon as a
// later datagram is acknowledged: whatever was in a lost one is resent then.

MAX_CONNECTIONS :: 1024
@(private) SENT_WINDOW :: 4096         // datagrams in flight: twice what 100 Mbit/s holds over 120 ms, and more
@(private) ACK_WINDOW :: SENT_WINDOW-1 // datagrams before the last received an acknowledgement covers at most
@(private) RECORD_WINDOW :: SENT_WINDOW-1-64 // datagrams in flight past which only one a keepalive goes
@(private) ACK_COUNT_BITS :: 12        // of how many datagrams an acknowledgement covers: up to ACK_WINDOW
@(private) LATE_WINDOW :: 32           // behind the last received, taken late with something skipped
@(private) NO_REACK :: max(u64)
@(private) REORDER_COUNT :: 3          // datagrams acknowledged after one before it is taken as lost
@(private) HANDSHAKE_BYTES :: 128 // the least a Hello and an Initiate take: more than any answer to them
@(private) HANDSHAKE_INTERVAL :: 0.2
@(private) COOKIE_SECONDS :: 10
@(private) INITIATE_HEADER :: 37  // type, salt, version, protocol hash, and the stamp and cookie of a Key (zero with an invitation)
@(private) IDENTITY_BYTES :: SEALED_KEY_BYTES+2 // what an Initiate_Identity adds before its claim: s sealed, and the size of the claim
@(private) IDENTITY_INITIATE_BYTES :: INITIATE_HEADER+KEY_BYTES+IDENTITY_BYTES+TAG_BYTES+MAC_BYTES+CHECKSUM_BYTES // the least an Initiate_Identity takes
@(private) EARLY_BYTES :: PACKET_BYTES-INITIATE_HEADER-KEY_BYTES-TAG_BYTES-MAC_BYTES-CHECKSUM_BYTES // the most of a body an Initiate carries
@(private) ACK_DELAY :: 0.03
@(private) ACK_KEPT :: 320 // bits of runs an acknowledgement keeps to while a lost chunk waits: what chunk_longest leaves
@(private) ACK_EVERY :: 4 // datagrams with reliable chunks after which a receiver acknowledges without waiting
@(private) SECTION_RESERVE :: 4 // bits kept free for the terminators of the sections still to come
@(private) DATA_HEADER :: 5     // bytes: type, sequence and the slot of the connection at the receiver
@(private) CHECKSUM_BYTES :: 4
@(private) ACCEPT_BYTES :: 10   // object capacity, ticks of history and the slot of the connection: the payload of a Response
@(private) RESPONSE_BYTES :: 1+8+KEY_BYTES+ACCEPT_BYTES+TAG_BYTES+CHECKSUM_BYTES
@(private) CANDIDATES :: 2      // addresses a client asks at once: those of an invitation
@(private) TRANSPORT_VERSION :: 14 // of the layout of the handshake and of the datagrams after it: raised when it changes

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
    bytes_resent:u64,            // of those chunks
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

@(private) Packet_Type :: enum u8 {Hello,Key,Initiate,Response,Denied,Retry,Data,Disconnect,Initiate_Identity}
// Confirming: a server's identity connection whose client has not answered under its keys yet; its
// game does not know it.
@(private) Peer_State :: enum u8 {Free,Connecting,Connected,Confirming}
// The connection attempt of a client: where it asks, and its handshake. With
// an invitation the same Initiate goes to every candidate each interval and
// the first Response that opens is the connection; without one, a Hello goes
// to every candidate until one answers with its Key, and the Initiate goes to
// that one. With an identity, as with an invitation. Answers count only from
// a candidate.
@(private)
Attempt :: struct {
    candidates:[CANDIDATES]Address,
    candidate_count:int,
    denied:[CANDIDATES]bool,
    why:Disconnect_Reason, // why a candidate refused it: the attempt ends with it once every candidate did, or when its time is up
    keyed:bool,            // without an invitation: a server answered with its Key
    identity:bool,         // an Initiate_Identity, from Host_Desc.identity to the identity server
    at:Address,            // that server
    stamp,cookie:u64,      // of its Key
    server:Key,            // its s, or its identity
    mac:Key,               // of the MAC of its Initiates
    claim:[CLAIM_BYTES]u8, // what an Initiate_Identity presents
    claim_size:int,
    noise:Noise,           // the handshake after the Initiate
    ephemeral:Key,         // its e
    early:[EARLY_BYTES]u8, // its datagram 0, which every Initiate carries, also one written again for a Retry
    early_size:int,
    initiate:[PACKET_BYTES]u8,
    initiate_size:int,     // 0: not written yet
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
    remote:u16, // the slot of the connection at the other end, which its datagrams carry
    address:Address,
    salt:u64, // of the attempt, which the handshake datagrams of both ends carry
    started,last_send,last_receive,next_handshake:f64,
    send_counter,recv_counter:u64, // datagrams sent; sequence of the newest one received
    send_seq,sent_tail:u16,
    recv_bits:Ack_Bits,
    late_bits:u32,  // received late and taken, the first LATE_WINDOW of recv_bits; never acknowledged
    ack_known:u64,  // the oldest datagram received that the other end may not have resolved yet
    // Datagrams that came late and that the acknowledgement must cover until the other end read one that
    // does: the oldest that one of this end's datagrams from reack_seq on carries, and the oldest of
    // those that came after, which the datagrams from reack_next_seq on carry. NO_REACK when none.
    reack,reack_next:u64,
    reack_seq,reack_next_seq:u16,
    recv_any,ack_pending,has_rtt:bool,
    flush:bool,     // the owner queued messages: they go as the tokens allow, not once a tick
    ack_chunks:int, // datagrams with reliable chunks received since this end last sent
    recv_time:f64,     // when the newest datagram received arrived
    last_arrival:u64,  // the datagram acknowledged that arrived last, which the other end takes its RTT from
    last_time:f64,     // and when
    sent:[SENT_WINDOW]Sent,
    sent_acked,sent_lost:[SENT_WINDOW/64]u64, // per slot of sent: its datagram was acknowledged, or taken as lost
    largest_acked:u16,                        // the newest datagram acknowledged, once acked_any
    acked_any:bool,
    records:[]Record,
    record_head,record_tail:u32,
    rtt,rtt_variance,jitter:f64,
    latest_rtt:f64, // the last sample
    reorder:f64,    // s past the round trip that the latest arrival of a datagram taken as lost showed, fading
    tokens,token_time:f64,
    // Congestion control: the rate the connection may send at, judged over intervals of two round trips.
    rate:f64,
    starting:bool,                      // doubling the rate each interval until the path shows a queue
    min_rtt,window_min,window_time:f64, // lowest mean RTT of an interval in the last window, and in the current one
    cc_time,cc_rtt,cc_rtt2:f64,         // start of the interval, the sum of its RTT samples and of their squares
    cc_samples:int,
    cc_acked,cc_lost:u64,               // acked and lost datagrams at its start
    delivered,cc_delivered:u64,         // bytes of datagrams acknowledged, and at the interval's start
    cc_limited:bool,                    // the connection ran out of rate in it
    rate_time:f64,
    rate_sent,rate_received:u64,
    channels:[MAX_CHANNELS]Channel,
    channel_turn:int, // the reliable game channel that takes the first chunk of the next datagram
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
// Which of the count datagrams before the acknowledged one arrived: whether the first did, then the
// lengths of the runs of arrived and missing ones in turn, each in Elias gamma code. Within budget bits:
// the runs that do not fit are left out, and the other end takes those datagrams as lost.
@(private)
ack_bits_write :: proc(w:^serial.Bit_Writer,bits:^Ack_Bits,count,budget:int) -> int {
    count:=ack_fit(bits,count,budget)
    serial.bit_write(w,u64(count),ACK_COUNT_BITS)
    if count==0 {return 0}
    set:=ack_bit(bits,1)
    serial.bit_write_bool(w,set)
    for at:=0;at<count;set=!set {
        run:=ack_run(bits,at,count,set)
        width:=uint(63-intrinsics.count_leading_zeros(u64(run)))
        serial.bit_write(w,0,int(width))
        serial.bit_write(w,1,1)
        serial.bit_write(w,u64(run)&(1<<width-1),int(width))
        at+=run
    }
    return count
}
// The most of count datagrams whose runs fit in budget bits, at the end of a run.
@(private)
ack_fit :: proc "contextless" (bits:^Ack_Bits,count,budget:int) -> int {
    used:=ACK_COUNT_BITS+1
    set:=ack_bit(bits,1)
    for at:=0;at<count;set=!set {
        run:=ack_run(bits,at,count,set)
        used+=2*int(63-intrinsics.count_leading_zeros(u64(run)))+1
        if used>budget {return at}
        at+=run
    }
    return count
}
// How many bits from bit at on, below count, equal set.
@(private)
ack_run :: proc "contextless" (bits:^Ack_Bits,at,count:int,set:bool) -> int {
    i:=at
    for i<count {
        offset:=uint(i%64)
        word:=bits[i/64]
        if !set {word=~word}
        run:=int(intrinsics.count_trailing_zeros(~(word>>offset)))
        i+=run
        if run<64-int(offset) {break}
    }
    return min(i,count)-at
}
// Not ok: a count past ACK_WINDOW, or runs that are empty, too long or do not add up to the count.
@(private)
ack_bits_read :: proc(r:^serial.Bit_Reader) -> (bits:Ack_Bits,count:u64,ok:bool) {
    count=serial.bit_read(r,ACK_COUNT_BITS)
    if r.error || count>ACK_WINDOW {return}
    if count==0 {return bits,0,true}
    set:=serial.bit_read_bool(r)
    for at:=u64(0);at<count;set=!set {
        width:=0
        for !serial.bit_read_bool(r) {
            width+=1
            if r.error || width>=ACK_COUNT_BITS {return}
        }
        run:=u64(1)<<uint(width)|serial.bit_read(r,width)
        if r.error || run>count-at {return}
        if set {
            for i:=at;i<at+run; {
                offset:=i%64
                take:=min(64-offset,at+run-i)
                bits[i/64]|=(take==64?max(u64):(u64(1)<<take-1))<<offset
                i+=take
            }
        }
        at+=run
    }
    return bits,count,true
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
    p.records=host_make(h,Record,h.records)
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
    message:[19+KEY_BYTES]u8
    address:=address
    message[0],message[1],message[2]=u8(address.kind),u8(address.port),u8(address.port>>8)
    copy(message[3:],address.ip[:])
    copy(message[19:],address.peer[:])
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
peer_readdress :: proc(b:^Back,p:^Peer,address:Address) {
    if address==p.address {return}
    peer_unlist(b,p)
    p.address=address
    peer_list(b,p)
}

@(private)
peer_reset :: proc(h:^Host,p:^Peer,address:Address) {
    now:=h.back.now
    p.address,p.remote=address,0
    p.salt=0
    p.started,p.last_send,p.last_receive,p.next_handshake=now,now,now,now
    p.send_counter,p.recv_counter,p.send_seq,p.sent_tail,p.recv_bits,p.late_bits,p.ack_known=0,0,0,0,{},0,0
    p.recv_any,p.ack_pending,p.has_rtt,p.ack_chunks=false,false,false,0
    p.record_head,p.record_tail=0,0
    p.rtt,p.rtt_variance,p.jitter,p.latest_rtt,p.reorder=0,0,0,0,0
    p.sent_acked,p.sent_lost,p.largest_acked,p.acked_any={},{},0,false
    p.last_arrival,p.last_time=0,0
    p.reack,p.reack_next,p.reack_seq,p.reack_next_seq=NO_REACK,NO_REACK,0,0
    p.rate,p.starting=CC_START_RATE,true
    p.tokens,p.token_time=send_burst(h,p.rate),now
    p.min_rtt,p.window_min,p.window_time=0,0,now
    p.cc_time,p.cc_rtt,p.cc_rtt2,p.cc_samples,p.cc_acked,p.cc_lost,p.cc_limited=now,0,0,0,0,0,false
    p.delivered,p.cc_delivered,p.channel_turn=0,0,0
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
    p.salt=base.splitmix_next(&h.back.rng)
    p.state=.Connecting
    peer_list(&h.back,p)
    repl_peer_connected(h,p)
    a:=&h.back.attempt
    a^={}
    a.candidate_count=clamp(request.count,1,CANDIDATES)
    for i in 0..<a.candidate_count {a.candidates[i]=request.candidates[i]}
    a.server,a.mac=h.back.secure.public,h.back.secure.mac
    if request.identity {
        a.identity,a.server,a.mac=true,request.peer,identity_mac_key(&request.peer)
        a.claim_size=clamp(request.claim_size,0,CLAIM_BYTES)
        copy(a.claim[:a.claim_size],request.claim[:a.claim_size])
    }
}
// The candidate of the attempt at address, -1 if none.
@(private)
candidate_find :: proc(a:^Attempt,address:Address) -> int {
    for candidate,i in a.candidates[:a.candidate_count] {
        if candidate==address {return i}
    }
    return -1
}
// A candidate refused the attempt: it ends with why once every candidate did,
// or when the server that gave its Key did.
@(private)
candidate_deny :: proc(h:^Host,p:^Peer,i:int,why:Disconnect_Reason) {
    a:=&h.back.attempt
    a.denied[i],a.why=true,why
    every:=true
    for denied in a.denied[:a.candidate_count] {every&&=denied}
    if every || a.keyed && a.candidates[i]==a.at {peer_drop(h,p,why,false)}
}

// The connection is made. A client took its replication state when it began.
@(private)
peer_established :: proc(h:^Host,p:^Peer,history:int) {
    if p.state==.Free {peer_list(&h.back,p)}
    p.state=.Connected
    p.last_receive=h.back.now
    s:=&p.secure
    if s.peer=={} || h.desc.mode==.Client {s.authorization={verdict=.Accept}}
    command_push(h,{kind=.Connected,connection=peer_handle(h,p),tick=u32(history),authorization=s.authorization},s.peer=={}?nil:s.peer[:])
    if h.desc.mode==.Server {repl_peer_connected(h,p)}
}

// Server: the client of an identity connection answered under its keys, so it holds its e and its s:
// authorize decides whether the connection reaches the game, and its datagram 0 with it. Another
// connection of that identity gives way to it. False when it ended.
@(private)
peer_admit :: proc(h:^Host,p:^Peer) -> bool {
    s:=&p.secure
    s.authorization=authorize_check(h,p)
    if s.authorization.verdict==.Refuse {
        peer_notice(h,p,.Unauthorized)
        peer_drop(h,p,.Unauthorized,false)
        h.back.stats.handshakes_refused+=1
        return false
    }
    for &other in h.back.peers {
        if &other!=p && other.state==.Connected && other.secure.peer==s.peer {peer_drop(h,&other,.Replaced,true)}
    }
    peer_established(h,p,h.history)
    r:serial.Bit_Reader
    serial.bit_reader_init(&r,s.early[:s.early_size])
    p.stats.packets_received+=1
    p.stats.bytes_received+=u64(s.early_size)
    received:=peer_receive(h,p,&r,0)
    crypto.zero_explicit(&s.early,size_of(s.early))
    s.early_size=0
    if !received && p.state==.Connected {
        h.back.stats.packets_invalid+=1
        peer_drop(h,p,.Protocol_Error,true)
    }
    return p.state==.Connected
}
// Server: authorize again about an identity connection (host_authorize).
@(private)
peer_reauthorize :: proc(h:^Host,p:^Peer) {
    was:=p.secure.authorization
    now:=authorize_check(h,p)
    if now.verdict==.Refuse {
        peer_drop(h,p,.Revoked,true)
        return
    }
    p.secure.authorization=now
    if now!=was {command_push(h,{kind=.Authorized,connection=peer_handle(h,p),authorization=now})}
}
// What authorize says of the identity and claim of a connection: Refuse for what is not a verdict.
@(private)
authorize_check :: proc(h:^Host,p:^Peer) -> Authorization {
    a:=h.desc.authorize
    s:=&p.secure
    result:=a.check(a.data,s.peer,s.claim[:s.claim_size])
    if result.verdict>max(Verdict) || result.class>max(Peer_Class) {return {}}
    return result
}

// Frees the slot and reports the end of the connection, or of the attempt.
@(private)
peer_drop :: proc(h:^Host,p:^Peer,reason:Disconnect_Reason,notify:bool) {
    if p.state==.Free {return}
    if notify && p.state==.Connected {peer_notice(h,p,reason)}
    if p.state==.Connected {repl_peer_disconnected(h,p)}
    // The game never heard of a connection that was confirming.
    if p.state!=.Confirming {command_push(h,{kind=.Disconnected,connection=peer_handle(h,p),reason=reason})}
    peer_unlist(&h.back,p)
    p.state=.Free
    p.generation+=1
    p.secure={}
    if h.desc.mode==.Client {crypto.zero_explicit(&h.back.attempt,size_of(Attempt))}
}

// Tells the other end why the connection ends, under the key of the connection.
// To an address that has not answered under it yet, the two and its Response
// are still less than the Initiate.
@(private)
peer_notice :: proc(h:^Host,p:^Peer,reason:Disconnect_Reason) {
    for _ in 0..<2 {
        w:serial.Bit_Writer
        data_begin(h,p,&w,.Disconnect)
        serial.bit_write(&w,u64(reason),8)
        transport_send(h,p.address,data_seal(h,p,&w))
    }
}

@(private)
peer_service :: proc(h:^Host,p:^Peer) {
    now:=h.back.now
    switch p.state {
    case .Free:
    case .Confirming:
        // A replay, or a client that left.
        if now-p.started>h.desc.connect_timeout {peer_drop(h,p,.Connect_Timeout,false)}
    case .Connecting:
        if now-p.started>h.desc.connect_timeout {
            denied:=h.back.attempt.why
            peer_drop(h,p,denied!=.None?denied:p.secure.refused?.Denied_Security:.Connect_Timeout,false)
            return
        }
        if now>=p.next_handshake {
            p.next_handshake=now+HANDSHAKE_INTERVAL
            handshake_attempt(h,p)
        }
    case .Connected:
        // A server's connection whose client never answered under its keys: a replay, or a client that left.
        if !p.secure.confirmed {
            if now-p.started>h.desc.connect_timeout {peer_drop(h,p,.Connect_Timeout,false)}
            return
        }
        if now-p.last_receive>h.desc.timeout {peer_drop(h,p,.Timeout,true);return}
        if elapsed:=now-p.rate_time;elapsed>=0.5 {
            sent,received:=f32(f64(p.stats.bytes_sent-p.rate_sent)/elapsed),f32(f64(p.stats.bytes_received-p.rate_received)/elapsed)
            p.stats.send_rate+=(sent-p.stats.send_rate)*0.5
            p.stats.receive_rate+=(received-p.stats.receive_rate)*0.5
            p.rate_time,p.rate_sent,p.rate_received=now,p.stats.bytes_sent,p.stats.bytes_received
        }
        peer_settle(h,p)
        if p.state!=.Connected {return}
        congestion_update(h,p)
    }
}

@(private) CC_START_RATE :: 256<<10 // bytes per second a connection starts at
@(private) CC_MIN_RATE :: 16<<10    // bytes per second congestion control does not go below
@(private) CC_MAX_RATE :: 1<<30
@(private) CC_GROWTH :: 2<<20       // bytes per second gained each second that wants more and finds no queue
@(private) CC_QUEUE_DELAY :: 0.02   // s of RTT above the smallest, besides two datagrams at the rate, that is a queue
@(private) CC_LOSS_SHARE :: 0.02    // share of an interval's datagrams lost that, with that queue, is congestion
@(private) CC_OVERRUN_SHARE :: 0.2  // share lost that is congestion with or without a queue: a buffer overflows
@(private) CC_WINDOW :: 60.0        // s over which the smallest RTT is remembered: longer than any queue lasts

// The rate starts low and doubles each interval that wanted more than it allowed, until the path shows a
// queue: the mean RTT of an interval above the smallest of the last CC_WINDOW seconds. Then the rate
// drops below what the path delivered in that interval, by a fifth, or by more with the losses of a
// buffer that overflows, and from there grows by the same CC_GROWTH a second while it wants more and
// finds no queue: connections that share a path converge to equal shares, and the queue stays short for
// what else travels on it. A slow path grows by at most a quarter of its rate each interval. Losses
// without a queue do not cut the rate, so a link that drops datagrams at random keeps it. An
// interval that delivered next to nothing, as after an outage, starts again.
@(private)
congestion_update :: proc(h:^Host,p:^Peer) {
    now:=h.back.now
    elapsed:=now-p.cc_time
    // Long enough to see the effect of the last change, and a few datagrams at the rate.
    if elapsed<(p.has_rtt?max(2*p.rtt,0.02,4*PACKET_BYTES/p.rate):0.1) {return}
    // A loss taken back in this interval may have been counted in an earlier one.
    acked,lost:=p.stats.packets_acked-p.cc_acked,u64(max(i64(p.stats.packets_lost)-i64(p.cc_lost),0))
    delivered:=f64(p.delivered-p.cc_delivered)/elapsed
    // Two datagrams at the rate are not a queue: a slow link takes that long to carry them.
    // Jitter spreads the samples around their mean, and the far end of that spread is not a queue: the
    // floor is the lowest mean of an interval, and a mean counts with the uncertainty that its spread
    // and its number of samples leave, above when it sets the floor and below when it is judged.
    n:=f64(p.cc_samples)
    mean:=n>0?p.cc_rtt/n:0
    spread:=n>1?math.sqrt(max(p.cc_rtt2-n*mean*mean,0)/(n-1)/n):p.rtt_variance
    if n>0 {
        if p.min_rtt==0 || mean+spread<p.min_rtt {p.min_rtt=mean+spread}
        if p.window_min==0 || mean+spread<p.window_min {p.window_min=mean+spread}
    }
    queued:=n>0 && mean-spread-p.min_rtt>CC_QUEUE_DELAY+2*PACKET_BYTES/p.rate
    overrun:=acked+lost>=16 && f64(lost)>CC_OVERRUN_SHARE*f64(acked+lost)
    if queued || overrun {
        congested:=overrun || lost>0 && f64(lost)>CC_LOSS_SHARE*f64(acked+lost)
        p.rate=clamp(min(p.rate,delivered)*(congested?0.7:0.8),CC_MIN_RATE,CC_MAX_RATE)
        // Nothing delivered is an outage, not a path that narrowed: start again.
        p.starting=delivered<CC_MIN_RATE
        if p.starting {p.rate=CC_START_RATE}
        p.stats.send_limit_cuts+=1
    } else if p.cc_limited && acked>0 {
        p.rate=min(p.starting?p.rate*2:p.rate+min(CC_GROWTH*min(elapsed,1),p.rate/4),CC_MAX_RATE)
    }
    if now-p.window_time>CC_WINDOW {
        if p.window_min>0 {p.min_rtt=p.window_min}
        p.window_min,p.window_time=0,now
    }
    p.reorder-=p.reorder*min(elapsed/8,1)
    for &c in p.channels {
        if c.active && c.kind==.Reliable {channel_window(&c,p.rtt+loss_delay(p),p.rate)}
    }
    p.stats.send_limit=f32(p.rate)
    p.cc_time,p.cc_rtt,p.cc_rtt2,p.cc_samples,p.cc_limited=now,0,0,0,false
    p.cc_acked,p.cc_lost,p.cc_delivered=p.stats.packets_acked,p.stats.packets_lost,p.delivered
}

// Tokens the bucket holds at most: one tick of the rate, so that a connection paces its datagrams over
// the updates of a tick instead of sending a burst after a quiet spell.
@(private)
send_burst :: proc "contextless" (h:^Host,rate:f64) -> f64 {
    return max(rate/f64(h.desc.tick_rate),PACKET_BYTES*2)
}

// Queues a datagram built in the next slot of Back.outgoing; a full batch goes at once, the rest at
// the end of the update (transport_flush).
@(private)
transport_send :: proc(h:^Host,to:Address,bytes:[]u8) {
    b:=&h.back
    b.stats.packets_sent+=1
    b.stats.bytes_sent+=u64(len(bytes))
    b.out[b.out_count]={to,bytes}
    b.out_count+=1
    if b.out_count==BATCH {transport_flush(h)}
}
@(private)
transport_flush :: proc(h:^Host) {
    b:=&h.back
    if b.out_count>0 {h.desc.transport.send(h.desc.transport.data,b.out[:b.out_count])}
    b.out_count=0
}
// The slot the next datagram is built in.
@(private)
outgoing_slot :: #force_inline proc(h:^Host) -> []u8 {return h.back.outgoing[h.back.out_count][:]}

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
    out:=outgoing_slot(h)
    out[0],out[1],out[2],out[3],out[4]=u8(type),u8(p.send_counter),u8(p.send_counter>>8),u8(p.remote),u8(p.remote>>8)
    serial.bit_writer_init(w,out[DATA_HEADER:PACKET_BYTES-TAG_BYTES])
}
@(private)
data_seal :: proc(h:^Host,p:^Peer,w:^serial.Bit_Writer) -> []u8 {
    out:=outgoing_slot(h)
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
    message:[35+KEY_BYTES]u8
    salt,stamp,address:=salt,stamp,address
    message[0],message[1],message[2]=u8(address.kind),u8(address.port),u8(address.port>>8)
    copy(message[3:19],address.ip[:])
    mem.copy(&message[19],&salt,8)
    mem.copy(&message[27],&stamp,8)
    copy(message[35:],address.peer[:])
    return siphash.sum_2_4(message[:],b.secret[:])
}

@(private)
handshake_begin :: proc(h:^Host,w:^serial.Bit_Writer,type:Packet_Type,salt:u64) {
    out:=outgoing_slot(h)
    out[0]=u8(type)
    serial.bit_writer_init(w,out[1:PACKET_BYTES-CHECKSUM_BYTES])
    serial.bit_write(w,salt,64)
}
@(private)
handshake_send :: proc(h:^Host,w:^serial.Bit_Writer,to:Address,pad:=0) {
    out:=outgoing_slot(h)
    total:=1+len(serial.bit_writer_flush(w))+CHECKSUM_BYTES
    if total<pad {
        mem.zero_slice(out[total-CHECKSUM_BYTES:pad])
        total=pad
    }
    checksum_write(out[:total],h.back.key)
    transport_send(h,to,out[:total])
}
// Client: one interval of its attempt. With an invitation, or once a server
// gave its Key, the Initiate; before, a Hello to every candidate that has not
// refused it.
@(private)
handshake_attempt :: proc(h:^Host,p:^Peer) {
    a:=&h.back.attempt
    if !h.back.secure.invited && !a.identity && !a.keyed {
        for candidate,i in a.candidates[:a.candidate_count] {
            if a.denied[i] {continue}
            w:serial.Bit_Writer
            handshake_begin(h,&w,.Hello,p.salt)
            handshake_send(h,&w,candidate,HANDSHAKE_BYTES)
        }
        return
    }
    if a.initiate_size==0 && !initiate_write(h,p) {
        p.secure.refused=true
        return
    }
    for candidate,i in a.candidates[:a.candidate_count] {
        if !a.denied[i] && (!a.keyed || candidate==a.at) {transport_send_copy(h,candidate,a.initiate[:a.initiate_size])}
    }
}
@(private)
transport_send_copy :: proc(h:^Host,to:Address,bytes:[]u8) {
    out:=outgoing_slot(h)
    transport_send(h,to,out[:copy(out,bytes)])
}
// What the Noise handshake of an Initiate is bound to: the application and the header, which says the
// attempt, the version, the protocol and the cookie.
@(private)
initiate_prologue :: proc(h:^Host,header:[]u8) -> (prologue:[4+INITIATE_HEADER]u8) {
    endian.unchecked_put_u32le(prologue[:],h.desc.protocol_id)
    copy(prologue[4:],header)
    return
}
// Client: the Initiate of its attempt, with what it queued as datagram 0 of the connection, the first
// time. False when the server's key leaves nothing secret.
@(private)
initiate_write :: proc(h:^Host,p:^Peer) -> bool {
    a:=&h.back.attempt
    w:serial.Bit_Writer
    serial.bit_writer_init(&w,a.early[:EARLY_BYTES-(a.identity?IDENTITY_BYTES+a.claim_size:0)])
    first:=p.record_tail
    budget,more:=repl_budget(h,p),false
    body_write(h,p,&w,p.send_seq,&budget,&more,true)
    a.early_size=len(serial.bit_writer_flush(&w))
    if !initiate_seal(h,p) {return false}
    sent_record(h,p,first,a.initiate_size)
    return true
}
// Client: seals the Initiate with the stamp and cookie the attempt has and a new e: one header, one e.
@(private)
initiate_seal :: proc(h:^Host,p:^Peer) -> bool {
    a:=&h.back.attempt
    out:=a.initiate[:]
    out[0]=u8(a.identity?Packet_Type.Initiate_Identity:Packet_Type.Initiate)
    endian.unchecked_put_u64le(out[1:],p.salt)
    endian.unchecked_put_u32le(out[9:],h.desc.version)
    endian.unchecked_put_u64le(out[13:],host_protocol_hash(h))
    endian.unchecked_put_u64le(out[21:],a.stamp)
    endian.unchecked_put_u64le(out[29:],a.cookie)
    at:=INITIATE_HEADER+KEY_BYTES
    if a.identity {
        at+=SEALED_KEY_BYTES
        endian.unchecked_put_u16le(out[at:],u16(a.claim_size))
        at+=2+copy(out[at+2:],a.claim[:a.claim_size])
    }
    total:=max(at+a.early_size+TAG_BYTES+MAC_BYTES+CHECKSUM_BYTES,HANDSHAKE_BYTES)
    copy(out[at:],a.early[:a.early_size])
    mem.zero_slice(out[at+a.early_size:total])
    prologue:=initiate_prologue(h,out[:INITIATE_HEADER])
    mac_at:=total-CHECKSUM_BYTES-MAC_BYTES
    if !noise_initiate(&a.noise,&a.ephemeral,prologue[:],&a.server,&h.back.secure.psk,a.identity?&h.desc.identity:nil,out[INITIATE_HEADER:mac_at]) {return false}
    mac:=mac_of(&a.mac,out[:mac_at])
    copy(out[mac_at:],mac[:])
    checksum_write(out[:total],h.back.key)
    a.initiate_size=total
    return true
}
// Server: a cookie for the address, which an Initiate brings back to be taken.
@(private)
initiate_retry :: proc(h:^Host,to:Address,salt:u64) {
    w:serial.Bit_Writer
    stamp:=max(u64(h.back.now*1000),1)
    handshake_begin(h,&w,.Retry,salt)
    serial.bit_write(&w,stamp,64)
    serial.bit_write(&w,cookie_make(&h.back,to,salt,stamp),64)
    handshake_send(h,&w,to)
}
@(private)
handshake_deny :: proc(h:^Host,to:Address,salt:u64,reason:Disconnect_Reason) {
    w:serial.Bit_Writer
    handshake_begin(h,&w,.Denied,salt)
    serial.bit_write(&w,u64(reason),8)
    handshake_send(h,&w,to)
    h.back.stats.handshakes_refused+=1
}

// What both ends must agree on besides the version: the layout of the
// datagrams, channels and replication protocol.
@(private)
host_protocol_hash :: proc(h:^Host) -> u64 {
    hash:=base.hash_combine(h.desc.protocol!=nil?h.desc.protocol.hash:0,TRANSPORT_VERSION)
    for c in h.channels[:USER_CHANNELS] {
        hash=base.hash_combine(base.hash_combine(hash,u64(c.kind)<<32|u64(c.max_message_bytes)),u64(c.kind==.Reliable?c.queue_bytes:0))
    }
    return hash
}

@(private)
packet_receive :: proc(h:^Host,bytes:[]u8,from:Address) {
    b:=&h.back
    if len(bytes)<DATA_HEADER+1+CHECKSUM_BYTES || len(bytes)>PACKET_BYTES || bytes[0]>u8(max(Packet_Type)) {b.stats.packets_invalid+=1;return}
    type:=Packet_Type(bytes[0])
    r:serial.Bit_Reader
    if type==.Data || type==.Disconnect {
        // The connection of the slot it names; from another address, only if it opens under its key.
        slot:=int(bytes[3])|int(bytes[4])<<8
        p:=slot<len(b.peers)?&b.peers[slot]:nil
        if p==nil || p.state!=.Connected && p.state!=.Confirming {b.stats.packets_invalid+=1;return}
        roamed:=p.address!=from
        body,counter,authentic:=data_open(h,p,bytes)
        if !authentic || roamed && p.recv_any && counter<=p.recv_counter {
            b.stats.packets_invalid+=1
            if !roamed {p.stats.packets_rejected+=1}
            return
        }
        if roamed {peer_readdress(b,p,from)}
        // Only the client that wrote the Initiate has these keys: it receives where it says.
        if !p.secure.confirmed {
            p.secure.confirmed=true
            p.secure.initiator,p.secure.response={},{}
            if p.state==.Confirming && !peer_admit(h,p) {return}
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
    server:=h.desc.mode==.Server
    if type==.Initiate || type==.Initiate_Identity {
        if !server || len(bytes)<(type==.Initiate?HANDSHAKE_BYTES:IDENTITY_INITIATE_BYTES) {b.stats.packets_invalid+=1;return}
        initiate_receive(h,bytes,from)
        return
    }
    serial.bit_reader_init(&r,bytes[1:len(bytes)-CHECKSUM_BYTES])
    salt:=serial.bit_read(&r,64)
    // An answer to an attempt comes from one of its candidates, with its salt.
    p:^Peer
    candidate:=-1
    if !server && (type==.Key || type==.Retry || type==.Response || type==.Denied) {
        attempt:=&b.peers[0]
        candidate=candidate_find(&b.attempt,from)
        if candidate>=0 && attempt.state==.Connecting && attempt.salt==salt {p=attempt}
    }
    #partial switch type {
    case .Hello:
        if !server || len(bytes)!=HANDSHAKE_BYTES || r.error {b.stats.packets_invalid+=1;return}
        // Only who brings the invitation hears from a host that has one.
        if b.secure.invited {b.stats.handshakes_dropped+=1;return}
        // Every Hello gets the same answer, smaller than it: the version and the key are no secret.
        w:serial.Bit_Writer
        stamp:=max(u64(b.now*1000),1)
        handshake_begin(h,&w,.Key,salt)
        serial.bit_write(&w,stamp,64)
        serial.bit_write(&w,cookie_make(b,from,salt,stamp),64)
        serial.bit_write(&w,u64(h.desc.version),32)
        serial.bit_write_bytes(&w,b.secure.public[:])
        handshake_send(h,&w,from)
    case .Key:
        stamp:=serial.bit_read(&r,64)
        cookie:=serial.bit_read(&r,64)
        version:=u32(serial.bit_read(&r,32))
        key:Key
        serial.bit_read_bytes(&r,key[:])
        if server || r.error || p==nil {b.stats.packets_invalid+=1;return}
        a:=&b.attempt
        if b.secure.invited || a.identity || a.keyed || a.denied[candidate] {return}
        // The other candidate may be the server: one of another version is another machine.
        if version!=h.desc.version {candidate_deny(h,p,candidate,.Denied_Version);return}
        if !key_usable(&key) {
            p.secure.refused=true
            b.stats.packets_invalid+=1
            return
        }
        a.keyed,a.at,a.stamp,a.cookie,a.server=true,from,stamp,cookie,key
        a.mac=mac_key(&key,&b.secure.psk)
        handshake_attempt(h,p)
    case .Retry:
        stamp:=serial.bit_read(&r,64)
        cookie:=serial.bit_read(&r,64)
        if server || r.error || p==nil {b.stats.packets_invalid+=1;return}
        // The same datagram 0, under the server's cookie and a new e, to the address that gave it.
        a:=&b.attempt
        if !b.secure.invited && !a.identity || a.initiate_size==0 || stamp==0 || stamp==a.stamp {return}
        a.stamp,a.cookie=stamp,cookie
        if !initiate_seal(h,p) {return}
        transport_send_copy(h,from,a.initiate[:a.initiate_size])
    case .Response:
        if server || r.error || p==nil || len(bytes)!=RESPONSE_BYTES || b.attempt.initiate_size==0 || b.attempt.keyed && from!=b.attempt.at {b.stats.packets_invalid+=1;return}
        a:=&b.attempt
        noise:=a.noise
        defer crypto.zero_explicit(&noise,size_of(Noise))
        session:Peer_Secure
        message:=bytes[9:RESPONSE_BYTES-CHECKSUM_BYTES]
        if !noise_finish(&noise,&a.ephemeral,message,&session,a.identity?&h.desc.identity.private:nil) {
            p.secure.refused=true
            b.stats.packets_invalid+=1
            return
        }
        session.confirmed=true
        if a.identity {session.peer=a.server}
        p.secure=session
        crypto.zero_explicit(a,size_of(Attempt))
        peer_readdress(b,p,from)
        answer:=message[KEY_BYTES:][:ACCEPT_BYTES]
        objects,history:=endian.unchecked_get_u32le(answer[0:]),endian.unchecked_get_u32le(answer[4:])
        p.remote=endian.unchecked_get_u16le(answer[8:])
        // The history of the server is the client's: at most what this end would keep itself.
        if int(objects)>h.desc.replication.max_objects || history==0 || int(history)>history_ticks(HISTORY_MAX_SECONDS,h.desc.tick_rate) {
            // The server holds the connection already: it hears why, and this end never had it.
            peer_notice(h,p,.Capacity)
            peer_drop(h,p,.Capacity,false)
            return
        }
        peer_established(h,p,int(history))
        // At once: the server sends nothing more until a datagram under these keys confirms this address.
        p.ack_pending,p.ack_chunks=true,ACK_EVERY
    case .Denied:
        reason:=serial.bit_read(&r,8)
        if server || r.error || p==nil {b.stats.packets_invalid+=1;return}
        candidate_deny(h,p,candidate,reason>u64(max(Disconnect_Reason)) || reason==0?Disconnect_Reason.Closed:Disconnect_Reason(reason))
    case:
        b.stats.packets_invalid+=1
    }
}

// Server: an Initiate. Its MAC says its sender knew s and the secret (an
// Initiate_Identity: the server's identity): what does not have it hears
// nothing. A copy of one that made a connection still waiting for its client
// gets its Response again, from that address only. Without a cookie, while the
// server is busy, when the filter of those is full or holds it, the sender gets
// a Retry with a cookie instead; with a cookie, one the filter holds gets a
// fresh one. One that opens enters the filter whatever comes next, makes the
// connection and answers. An Initiate hands the game what its payload carries at
// once; an Initiate_Identity, whose copies outlive the filter with the
// identity, waits Confirming until its client answers under its keys
// (peer_admit), and only replaces a connection from its address that is
// confirming too.
@(private)
initiate_receive :: proc(h:^Host,bytes:[]u8,from:Address) {
    b:=&h.back
    identity:=Packet_Type(bytes[0])==.Initiate_Identity
    header:=bytes[:INITIATE_HEADER]
    salt:=endian.unchecked_get_u64le(header[1:])
    version:=endian.unchecked_get_u32le(header[9:])
    hash:=endian.unchecked_get_u64le(header[13:])
    stamp:=endian.unchecked_get_u64le(header[21:])
    cookie:=endian.unchecked_get_u64le(header[29:])
    if identity && h.desc.identity=={} {b.stats.handshakes_dropped+=1;return}
    mac_at:=len(bytes)-CHECKSUM_BYTES-MAC_BYTES
    mac:=mac_of(identity?&b.secure.identity_mac:&b.secure.mac,bytes[:mac_at])
    if crypto.compare_constant_time(mac[:],bytes[mac_at:][:MAC_BYTES])!=1 {b.stats.handshakes_dropped+=1;return}
    if version!=h.desc.version {handshake_deny(h,from,salt,.Denied_Version);return}
    now:=u64(b.now*1000)
    cookied:=stamp!=0 || cookie!=0
    if cookied && (stamp>now || now-stamp>COOKIE_SECONDS*1000 || cookie!=cookie_make(b,from,salt,stamp)) || !cookied && !b.secure.invited && !identity {b.stats.handshakes_dropped+=1;return}
    message:=bytes[INITIATE_HEADER:mac_at]
    initiator:=(^Key)(raw_data(message))^
    p:=peer_find(b,from)
    if p!=nil && (p.state==.Connected || p.state==.Confirming) && !p.secure.confirmed && p.secure.initiator==initiator {
        transport_send_copy(h,from,p.secure.response[:])
        return
    }
    seen:=seen_hash(b,&initiator)
    _,room:=seen_filter(&b.secure,cookied)
    if !cookied {
        if b.secure.handshakes<=0 {b.secure.busy_until=b.now+BUSY_SECONDS}
        if b.now<b.secure.busy_until || !room || seen_has(&b.secure,seen,false) {
            initiate_retry(h,from,salt)
            return
        }
    } else if seen_has(&b.secure,seen,true) {
        initiate_retry(h,from,salt)
        return
    }
    failed:=failed_record(b,from)
    if !room || b.secure.handshakes<=0 || failed.due-b.now>(FAILED_BURST-1)*FAILED_INTERVAL {b.stats.handshakes_deferred+=1;return}
    b.secure.handshakes-=1
    b.secure.exchanges+=1
    noise:Noise
    defer crypto.zero_explicit(&noise,size_of(Noise))
    prologue:=initiate_prologue(h,header)
    peer:Key
    opened:bool
    if identity {
        opened=noise_accept(&noise,prologue[:],&h.desc.identity.private,&h.desc.identity.public,nil,message,&peer)
    } else {
        opened=noise_accept(&noise,prologue[:],&b.secure.private,&b.secure.public,&b.secure.psk,message)
    }
    // A made-up key or damage: no answer tells it so, and the address waits for its next try.
    if !opened {
        failed.due=max(failed.due,b.now)+FAILED_INTERVAL
        b.stats.handshakes_dropped+=1
        return
    }
    // Opened, it is never taken again, also if it is refused now.
    seen_add(&b.secure,seen,cookied)
    payload:=message[KEY_BYTES:len(message)-TAG_BYTES]
    claim:[]u8
    if identity {
        payload=payload[SEALED_KEY_BYTES:]
        size:=int(endian.unchecked_get_u16le(payload))
        if size>CLAIM_BYTES || 2+size>len(payload) {b.stats.packets_invalid+=1;return}
        claim,payload=payload[2:][:size],payload[2+size:]
    }
    if hash!=host_protocol_hash(h) {handshake_deny(h,from,salt,.Denied_Protocol);return}
    // A confirmed connection from the address gives way only to one that is confirmed in turn.
    replaced:=p
    if identity && p!=nil && p.state==.Connected {replaced=nil}
    slot:=replaced
    for &candidate in b.peers {
        if slot!=nil {break}
        if candidate.state==.Free {slot=&candidate}
    }
    if slot==nil {handshake_deny(h,from,salt,.Denied_Full);return}
    // A new attempt from the address of a connection replaces it.
    if replaced!=nil {peer_drop(h,replaced,.Closed,false)}
    peer_reset(h,slot,from)
    slot.salt=salt
    slot.secure.initiator=initiator
    out:=slot.secure.response[:]
    out[0]=u8(Packet_Type.Response)
    endian.unchecked_put_u64le(out[1:],salt)
    answer:=out[9+KEY_BYTES:][:ACCEPT_BYTES]
    endian.unchecked_put_u32le(answer[0:],u32(h.desc.replication.max_objects))
    endian.unchecked_put_u32le(answer[4:],u32(h.history))
    endian.unchecked_put_u16le(answer[8:],u16(slot.index))
    if !noise_respond(&noise,&slot.secure.initiator,out[9:RESPONSE_BYTES-CHECKSUM_BYTES],&slot.secure,identity?&peer:nil) {return}
    checksum_write(out,b.key)
    if identity {
        s:=&slot.secure
        s.peer=peer
        s.claim_size=copy(s.claim[:],claim)
        s.early_size=copy(s.early[:],payload)
        slot.state=.Confirming
        peer_list(b,slot)
        transport_send_copy(h,from,out)
        return
    }
    peer_established(h,slot,h.history)
    transport_send_copy(h,from,out)
    // The payload is datagram 0 of the client.
    r:serial.Bit_Reader
    serial.bit_reader_init(&r,payload)
    slot.stats.packets_received+=1
    slot.stats.bytes_received+=u64(len(bytes))
    if !peer_receive(h,slot,&r,0) && slot.state==.Connected {
        b.stats.packets_invalid+=1
        peer_drop(h,slot,.Protocol_Error,false)
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
    if received {
        p.stats.packets_acked+=1
        p.delivered+=u64(sent.bytes)
    } else {
        p.stats.packets_lost+=1
    }
    p.stats.loss+=((received?0:1)-p.stats.loss)*0.02
    for i in sent.first..<sent.first+u32(sent.count) {
        record:=p.records[i%u32(len(p.records))]
        if record.kind==.Chunk {channel_resolve(p,record,received)} else {repl_resolve(h,p,record,seq,received)}
    }
}

@(private) sent_flag :: #force_inline proc "contextless" (bits:^[SENT_WINDOW/64]u64,seq:u16) -> bool {
    slot:=int(seq)%SENT_WINDOW
    return bits[slot/64]&(1<<uint(slot%64))!=0
}
@(private) sent_mark :: #force_inline proc "contextless" (bits:^[SENT_WINDOW/64]u64,seq:u16,set:bool) {
    slot:=int(seq)%SENT_WINDOW
    if set {bits[slot/64]|=1<<uint(slot%64)} else {bits[slot/64]&~=1<<uint(slot%64)}
}

// How long a datagram may be out before it is lost, once datagrams sent after it were acknowledged.
@(private)
loss_delay :: proc "contextless" (p:^Peer) -> f64 {
    return max(p.rtt,p.latest_rtt)+max(4*p.rtt_variance,p.rtt/8,p.reorder,0.001)
}

// A datagram is taken as lost only once reordering cannot explain its absence: REORDER_COUNT datagrams
// sent after it were acknowledged, and it has been out longer than a round trip and the window that
// the variation of the round trip gives, as RACK and QUIC judge it. The tail of what is in flight
// moves past what is settled; the records stay until the oldest datagram that holds them is.
@(private)
peer_settle :: proc(h:^Host,p:^Peer) {
    now:=h.back.now
    window:=loss_delay(p)
    for p.sent_tail!=p.send_seq {
        seq:=p.sent_tail
        if !sent_flag(&p.sent_acked,seq) && !sent_flag(&p.sent_lost,seq) {
            if !p.acked_any || i16(p.largest_acked-seq)<REORDER_COUNT || now-p.sent[seq%SENT_WINDOW].time<window {break}
            sent_mark(&p.sent_lost,seq,true)
            peer_resolve(h,p,seq,false)
            if p.state!=.Connected {return}
        }
        p.sent_tail+=1
    }
    p.record_head=p.sent_tail==p.send_seq?p.record_tail:p.sent[p.sent_tail%SENT_WINDOW].first
}

// Every datagram the acknowledgement says arrived, from the newest back while its slot still holds it:
// one in flight is resolved as received, and one already taken as lost came late, which takes back its
// loss; what was resent for it is a duplicate the receiver drops. An acknowledgement that came late
// still says what arrived. False when the connection closed.
@(private)
acks_take :: proc(h:^Host,p:^Peer,ack:u16,ack_bits:^Ack_Bits,ack_count,arrival:u64,delay:f64) -> bool {
    now:=h.back.now
    in_flight:=u16(p.send_seq-p.sent_tail)
    for behind:u64=0;behind<=ack_count;behind+=1 {
        seq:=ack-u16(behind)
        if u16(p.send_seq-seq)>SENT_WINDOW {break}
        if behind>0 && !ack_bit(ack_bits,behind) || sent_flag(&p.sent_acked,seq) {continue}
        sent_mark(&p.sent_acked,seq,true)
        if behind==arrival {
            sample:=max(now-p.sent[seq%SENT_WINDOW].time-delay,0)
            if !p.has_rtt {
                p.rtt,p.rtt_variance,p.has_rtt=sample,sample*0.5,true
            } else {
                deviation:=abs(sample-p.rtt)
                p.rtt_variance+=(deviation-p.rtt_variance)*0.25
                p.jitter+=(deviation-p.jitter)*0.0625
                p.rtt+=(sample-p.rtt)*0.125
            }
            p.latest_rtt=sample
            p.stats.rtt,p.stats.rtt_variance,p.stats.jitter=f32(p.rtt),f32(p.rtt_variance),f32(p.jitter)
            p.cc_rtt+=sample
            p.cc_rtt2+=sample*sample
            p.cc_samples+=1
        }
        if sent_flag(&p.sent_lost,seq) {
            // The window grows to what this one needed, with a margin, so the next does not repeat it.
            sent_mark(&p.sent_lost,seq,false)
            p.stats.packets_lost-=1
            p.reorder=min(max(p.reorder,1.25*(now-p.sent[seq%SENT_WINDOW].time-max(p.rtt,p.latest_rtt))),1)
            continue
        }
        if u16(seq-p.sent_tail)>=in_flight {continue}
        if !p.acked_any || seq_newer(seq,p.largest_acked) {p.largest_acked,p.acked_any=seq,true}
        p.ack_known=max(p.ack_known,p.sent[seq%SENT_WINDOW].known)
        for p.reack!=NO_REACK && !seq_newer(p.reack_seq,seq) {
            p.reack,p.reack_seq,p.reack_next=p.reack_next,p.reack_next_seq,NO_REACK
        }
        peer_resolve(h,p,seq,true)
        if p.state!=.Connected {return false}
    }
    peer_settle(h,p)
    return p.state==.Connected
}

// False when the datagram is malformed: the caller closes the connection.
@(private)
peer_receive :: proc(h:^Host,p:^Peer,r:^serial.Bit_Reader,counter:u64) -> bool {
    now:=h.back.now
    has_ack:=serial.bit_read_bool(r)
    ack:=u16(serial.bit_read(r,16))
    ack_bits,ack_count,acks_ok:=ack_bits_read(r)
    arrival:=serial.bit_read_bool(r)?serial.bit_read(r,ACK_COUNT_BITS):0
    delay:=f64(serial.bit_read(r,8))*0.001
    if !acks_ok || r.error || arrival>ack_count || arrival>0 && !ack_bit(&ack_bits,arrival) {return false}
    if p.recv_any && counter<=p.recv_counter {
        // Within the window of acknowledgements and not received before: it came late. Its
        // acknowledgement and what in it is safe out of order are taken.
        behind:=p.recv_counter-counter
        if behind==0 || behind>ACK_WINDOW || ack_bit(&p.recv_bits,behind) || behind<=LATE_WINDOW && p.late_bits&(1<<(behind-1))!=0 {p.stats.packets_out_of_order+=1;return true}
        if has_ack && !seq_newer(p.send_seq,ack) {return false}
        p.stats.packets_late+=1
        p.last_receive=now
        if has_ack && !acks_take(h,p,ack,&ack_bits,ack_count,arrival,delay) {return true}
        if !time_read(h,p,r,late=true) || p.state!=.Connected {return p.state!=.Connected}
        skipped:bool
        if !channels_read(h,p,r,counter,late=true,skipped=&skipped) || p.state!=.Connected {return p.state!=.Connected}
        // Everything in it that a resend would bring again was taken: it is acknowledged, from as far
        // back as it lies, so that the sender knows it arrived even if it already took it as lost.
        if !skipped && (h.back.repl.protocol==nil || !serial.bit_read_bool(r)) && !r.error {
            p.recv_bits[(behind-1)/64]|=1<<((behind-1)%64)
            if p.reack==NO_REACK {
                p.reack,p.reack_seq=counter,p.send_seq
            } else {
                p.reack_next,p.reack_next_seq=min(p.reack_next,counter),p.send_seq
            }
            // At once, as a receiver acks a segment that fills a gap: the sender waits for it.
            p.ack_pending,p.ack_chunks,p.last_arrival,p.last_time=true,ACK_EVERY,counter,now
        } else if behind<=LATE_WINDOW {
            p.late_bits|=1<<(behind-1)
        }
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
    p.last_receive,p.recv_time,p.last_arrival,p.last_time=now,now,counter,now
    if has_ack {
        if !acks_take(h,p,ack,&ack_bits,ack_count,arrival,delay) {return true}
    }
    if !time_read(h,p,r) || p.state!=.Connected {return p.state!=.Connected}
    if !channels_read(h,p,r,counter) || p.state!=.Connected {return p.state!=.Connected}
    if !objects_read(h,p,r) || p.state!=.Connected {return p.state!=.Connected}
    return !r.error
}

@(private)
peer_wants_send :: proc(h:^Host,p:^Peer) -> bool {
    b:=&h.back
    if !p.secure.confirmed {return false}
    idle:=b.now-p.last_send
    if b.send_pending || b.clock_due {return true}
    if idle>=h.desc.keepalive || (p.ack_pending && (idle>=ACK_DELAY || p.ack_chunks>=ACK_EVERY)) {return true}
    if p.flush || idle>=1/f64(h.desc.tick_rate) {
        if channels_pending(p) {return true}
        p.flush=false
    }
    if u16(p.send_seq-p.sent_tail)<RECORD_WINDOW && min(p.tokens+(b.now-p.token_time)*p.rate,send_burst(h,p.rate))>=PACKET_BYTES && channels_streaming(p) {return true}
    return p.sent_tail!=p.send_seq && idle>=clamp(p.rtt*2+p.rtt_variance*4,0.1,1)
}

// The body of a datagram of a connection: the acknowledgement, the clock or the inputs, the channels and
// the objects. False when it carries nothing but the acknowledgement.
@(private)
body_write :: proc(h:^Host,p:^Peer,w:^serial.Bit_Writer,seq:u16,budget:^int,more:^bool,last:bool) -> (wrote:bool) {
    b:=&h.back
    serial.bit_write_bool(w,p.recv_any)
    serial.bit_write(w,u64(u16(p.recv_counter)),16)
    // What must go after it bounds the acknowledgement: its delay, the clock or the inputs, and the ends of
    // the sections.
    ack_budget:=serial.bit_writer_remaining(w)-1-ACK_COUNT_BITS-8-time_max_bits(h)-SECTION_RESERVE
    if channels_resending(p) {ack_budget=min(ack_budget,ACK_KEPT)}
    from:=min(p.ack_known,p.reack,p.reack_next)
    covered:=ack_bits_write(w,&p.recv_bits,p.recv_any && p.recv_counter>from?int(min(p.recv_counter-from,ACK_WINDOW)):0,ack_budget)
    // The datagram that arrived last, and how long ago: on a path that reorders, the newest one received is
    // the one that came fastest, and an RTT taken only from it reads short.
    arrival,arrived:=u64(0),p.recv_time
    if p.recv_counter-p.last_arrival<=u64(covered) {arrival,arrived=p.recv_counter-p.last_arrival,p.last_time}
    serial.bit_write_bool(w,arrival>0)
    if arrival>0 {serial.bit_write(w,arrival,ACK_COUNT_BITS)}
    serial.bit_write(w,u64(clamp((b.now-arrived)*1000,0,255)),8)
    wrote=time_write(h,p,w,seq)
    yield:=b.repl.key_cursor<b.repl.key_count && budget^>0?min(budget^,PACKET_BYTES*4):0
    if channels_write(h,p,w,SECTION_RESERVE,yield) {wrote=true}
    if objects_write(h,p,w,seq,budget,more,last) {wrote=true}
    return
}

// Datagram seq went out with bytes and the records from first.
@(private)
sent_record :: proc(h:^Host,p:^Peer,first:u32,bytes:int) {
    seq:=p.send_seq
    sent_mark(&p.sent_acked,seq,false)
    sent_mark(&p.sent_lost,seq,false)
    p.sent[seq%SENT_WINDOW]={time=h.back.now,known=p.recv_any?p.recv_counter+1:0,first=first,count=u16(p.record_tail-first),bytes=u16(bytes)}
    p.send_seq+=1
    p.send_counter+=1
    p.tokens-=f64(bytes)
    p.last_send=h.back.now
    p.ack_pending,p.ack_chunks=false,0
    p.stats.packets_sent+=1
    p.stats.bytes_sent+=u64(bytes)
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
    for packet:=0;;packet+=1 {
        // Past RECORD_WINDOW only a datagram a keepalive goes: if every one in flight was lost, the
        // acknowledgement of a newer one settles them.
        if u16(p.send_seq-p.sent_tail)>=RECORD_WINDOW && (packet>0 || b.now-p.last_send<h.desc.keepalive || u16(p.send_seq-p.sent_tail)>=SENT_WINDOW-1) {break}
        if packet>0 && p.tokens<=0 {break}
        first_record:=p.record_tail
        w:serial.Bit_Writer
        data_begin(h,p,&w,.Data)
        more:=false
        last:=u16(p.send_seq+1-p.sent_tail)>=RECORD_WINDOW || p.tokens<=PACKET_BYTES
        if !body_write(h,p,&w,p.send_seq,&budget,&more,last) && packet>0 {
            p.record_tail=first_record
            break
        }
        bytes:=data_seal(h,p,&w)
        sent_record(h,p,first_record,len(bytes))
        transport_send(h,p.address,bytes)
        if !more && !channels_pending(p) {break}
        if p.tokens<=0 {p.cc_limited=true}
    }
}
