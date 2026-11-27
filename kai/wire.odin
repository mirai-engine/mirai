package kai

import "base:runtime"
import "core:crypto"
import "core:net"
import "core:slice"
import "core:sync"
import "core:time"
import wire "mirai:net"
import "mirai:store"

// One Kai connection: a TCP stream between two machines, the same between two
// peers on a LAN and between a machine and a server, that the kernel's own
// congestion control runs at the link's speed. The three handshake messages
// (noise.odin) have fixed sizes, so neither end reads a length it did not
// authenticate; every frame after them is a u32 length, little endian, and
// that many bytes: ChaChaPoly of one message of at most FRAME_MAX bytes, its
// kind first. Nothing here is trusted: a length past its
// bound, a frame that does not open or a message that does not parse ends the
// connection.

KAI_PORT :: 7350 // TCP of the agent, UDP of its beacon
FRAME_MAX :: 1<<20+64<<10 // a message: a reply of chunks fills up to FRAME_FILL
FRAME_FILL :: 1<<20
WANT_MAX :: 4096 // addresses one want names
GOSSIP_MAX :: 1024 // entries one Peers message names

// The kinds of messages, each a byte and its body (agent.odin reads them).
Msg :: enum u8 {
    None,
    Hello,         // name, device, port u16, then a Tell's body: who this end is and what it holds
    Tell,          // count u16 × Tell_Entry: heads this end holds now
    Want,          // org, count u16 × address: send these chunks
    Chunks,        // count u16 × (address, codec u8, raw u32, stored u32, bytes): the chunks asked, in order
    Lack,          // count u16 × address: chunks asked that this end does not have
    Ddc_Ask,       // org, key: the derived data set of key, answered by a Tell
    Join,          // org, name, device, public, claim_len u16, claim_bytes: joining by invite
    Welcome,       // org, address, admission: the org's record (and optional admission) listing the joining device
    Bye,           // why, as text
    Web_Login,     // name, password: a server's web view signs in as this device; a connection's first and only message
    Server_Info,   // empty request; answered by Server_Info(name, device, public) or Bye
    Org_Register,  // org, count u16 × (u32 len, org record) oldest-to-newest: an admin attaches a server to its org
    Invite_Grant,  // Invite_Grant bytes: an admin registers a 1-use offline invite on its org's server
    Peers,         // count u16 × Gossip_Entry: where this end and the members it is connected to listen
}

// A head one end holds: an org's record, a repository's shared bookmarks,
// the derived data set of a key (address zero: none, the answer to an ask),
// or a verified offline admission.
Tell_Kind :: enum u8 {Org,Repo,Ddc,Admit}

Tell_Entry :: struct #packed {
    kind:Tell_Kind,
    org:Org_Id,
    id:store.Hash,      // a repository's id in its first 16 bytes, a derived data key, or an admission's secret_hash
    address:store.Hash,
}

// Where a machine listens: an IPv4 address and a TCP port.
Peer_At :: struct #packed {
    ip:[4]u8,
    port:u16le,
}

// A member of an org both ends share, and one address it listens at: what it
// says of itself, or where the sending end sees it. The handshake proves the
// key at that address, so an entry proves nothing.
Gossip_Entry :: struct #packed {
    key:Key,
    at:Peer_At,
}

// The entries of a Peers message: ok false when its count passes GOSSIP_MAX,
// its length is not that of count entries or an entry names port zero.
gossip_parse :: proc(body:[]u8) -> (entries:[]Gossip_Entry,ok:bool) {
    if len(body)<2 {return}
    count:=int(body[0])|int(body[1])<<8
    if count>GOSSIP_MAX || len(body)!=2+count*size_of(Gossip_Entry) {return}
    entries=slice.reinterpret([]Gossip_Entry,body[2:])
    for e in entries {
        if e.at.port==0 {return nil,false}
    }
    return entries,true
}

Conn :: struct {
    socket:net.TCP_Socket,
    send:Cipher,
    receive:Cipher,
    send_lock:sync.Mutex,
    plain:[]u8, // FRAME_MAX bytes, under send_lock
    out:[]u8,   // FRAME_MAX+NOISE_TAG+4 bytes, under send_lock
    peer:Key,
    proof:[32]u8,  // of the invite the initiator proved, zero when none (handshake_invited)
    proved:[32]u8, // the handshake hash the proof covers
    remote:net.Endpoint,
    closed:bool,   // atomic: shut down, so a thread blocked on it wakes
}

DIAL_SECONDS :: 5    // a connect that takes longer is given up
SEND_SECONDS :: 30   // a send the other end takes nothing of for this long ends the connection
HANDSHAKE_SECONDS :: 10

// The bytes a connection keeps.
@(private)
conn_buffers :: proc(c:^Conn) -> bool {
    plain,pe:=make([]u8,FRAME_MAX)
    out,oe:=make([]u8,FRAME_MAX+NOISE_TAG+4)
    c.plain,c.out=plain,out
    return pe==nil && oe==nil
}

// Frees a connection and closes its socket, once no thread uses it.
conn_free :: proc(c:^Conn) {
    net.close(c.socket)
    conn_release(c)
}

// Frees a connection, leaving its socket to whoever gave it.
@(private)
conn_release :: proc(c:^Conn) {
    crypto.zero_explicit(&c.send,size_of(Cipher))
    crypto.zero_explicit(&c.receive,size_of(Cipher))
    crypto.zero_explicit(&c.proof,64)
    delete(c.plain)
    delete(c.out)
    free(c)
}

// Shuts the socket down, so a thread reading or writing it wakes; conn_free
// closes it. It takes no lock: a send blocked on a full window holds one.
conn_close :: proc(c:^Conn) {
    if sync.atomic_exchange(&c.closed,true) {return}
    net.shutdown(c.socket,.Both)
}

@(private)
socket_tune :: proc(socket:net.TCP_Socket) {
    net.set_option(socket,.TCP_Nodelay,true)
    net.set_option(socket,.Keep_Alive,true)
    net.set_option(socket,.Send_Buffer_Size,4<<20)
    net.set_option(socket,.Receive_Buffer_Size,4<<20)
    net.set_option(socket,.Send_Timeout,SEND_SECONDS*time.Second)
    when ODIN_OS==.Darwin {net.set_option(socket,.No_SIGPIPE_From_EPIPE,true)}
}

// Connects to address (host:port) within DIAL_SECONDS, sooner given up once
// cancel is set.
@(private)
socket_dial :: proc(address:string,cancel:^bool) -> (socket:net.TCP_Socket,ok:bool) {
    endpoint,re:=net.resolve_ip4(address)
    if re!=nil {return}
    any,ce:=net.create_socket(.IP4,.TCP)
    if ce!=nil {return}
    socket=any.(net.TCP_Socket)
    if net.set_blocking(socket,false)!=nil || !wire.socket_connect(net.Socket(socket),wire.address_from_endpoint(endpoint)) {
        net.close(socket)
        return {},false
    }
    started:=time.tick_now()
    for {
        ready,connected:=wire.socket_connected(net.Socket(socket))
        if ready && connected {break}
        if ready || time.tick_since(started)>DIAL_SECONDS*time.Second || cancel!=nil && sync.atomic_load(cancel) {
            net.close(socket)
            return {},false
        }
        time.sleep(5*time.Millisecond)
    }
    if net.set_blocking(socket,true)!=nil {
        net.close(socket)
        return {},false
    }
    return socket,true
}

// Dials address (host:port) and runs the handshake as initiator: expect, when
// not zero, is the key the other end must prove; secret, an invite's. The
// handshake's keys live on this stack and are zeroed before it returns.
conn_dial :: proc(address:string,identity:Identity,expect:Key,secret:[32]u8={},cancel:^bool=nil) -> (c:^Conn,error:Error) {
    socket,dialed:=socket_dial(address,cancel)
    if !dialed {return nil,.Unreachable}
    socket_tune(socket)
    me:runtime.Allocator_Error
    if c,me=new(Conn);me!=nil {
        net.close(socket)
        return nil,.Out_Of_Memory
    }
    c.socket=socket
    c.remote,_=net.peer_endpoint(socket)
    if !conn_buffers(c) {
        conn_free(c)
        return nil,.Out_Of_Memory
    }
    net.set_option(socket,.Receive_Timeout,HANDSHAKE_SECONDS*time.Second)
    hs:Handshake
    handshake_init(&hs,true,identity)
    defer handshake_destroy(&hs)
    hs.secret=secret
    m1:[NOISE_MSG1]u8
    m2:[NOISE_MSG2]u8
    m3:[NOISE_MSG3]u8
    ok:=handshake_write_1(&hs,m1[:]) && raw_send(socket,m1[:]) &&
        raw_receive(socket,m2[:]) && handshake_read_2(&hs,m2[:],m3[:],expect) && raw_send(socket,m3[:])
    if !ok {
        conn_free(c)
        return nil,.Unauthorized
    }
    c.peer=hs.peer
    c.send,c.receive=handshake_split(&hs)
    net.set_option(socket,.Receive_Timeout,time.Duration(0))
    return c,.None
}

// Runs the handshake as responder on an accepted socket, which stays its
// caller's when it fails. The handshake's keys live on this stack and are
// zeroed before it returns; what an invite needs is kept (proof, proved).
conn_accept :: proc(socket:net.TCP_Socket,remote:net.Endpoint,identity:Identity) -> (c:^Conn,error:Error) {
    socket_tune(socket)
    me:runtime.Allocator_Error
    if c,me=new(Conn);me!=nil {return nil,.Out_Of_Memory}
    c.socket,c.remote=socket,remote
    if !conn_buffers(c) {
        conn_release(c)
        return nil,.Out_Of_Memory
    }
    net.set_option(socket,.Receive_Timeout,HANDSHAKE_SECONDS*time.Second)
    hs:Handshake
    handshake_init(&hs,false,identity)
    defer handshake_destroy(&hs)
    m1:[NOISE_MSG1]u8
    m2:[NOISE_MSG2]u8
    m3:[NOISE_MSG3]u8
    ok:=raw_receive(socket,m1[:]) && handshake_read_1(&hs,m1[:],m2[:]) && raw_send(socket,m2[:]) &&
        raw_receive(socket,m3[:]) && handshake_read_3(&hs,m3[:])
    if !ok {
        conn_release(c)
        return nil,.Unauthorized
    }
    c.peer=hs.peer
    c.proof,c.proved=hs.proof,hs.proved
    c.send,c.receive=handshake_split(&hs)
    net.set_option(socket,.Receive_Timeout,time.Duration(0))
    return c,.None
}

// Sends one message: kind and body, sealed as one frame.
conn_send :: proc(c:^Conn,kind:Msg,body:..[]u8) -> bool {
    sync.mutex_lock(&c.send_lock)
    defer sync.mutex_unlock(&c.send_lock)
    n:=1
    for b in body {n+=len(b)}
    if sync.atomic_load(&c.closed) || n>FRAME_MAX {return false}
    c.plain[0]=u8(kind)
    at:=1
    for b in body {
        copy(c.plain[at:],b)
        at+=len(b)
    }
    length:=u32(n+NOISE_TAG)
    for k in 0..<4 {c.out[k]=u8(length>>(8*uint(k)))}
    if !cipher_seal(&c.send,c.plain[:n],c.out[4:][:n+NOISE_TAG]) {return false}
    return raw_send(c.socket,c.out[:4+n+NOISE_TAG])
}

// Receives one message into buffer (FRAME_MAX+NOISE_TAG bytes): its kind and body.
conn_receive :: proc(c:^Conn,buffer:[]u8) -> (kind:Msg,body:[]u8,ok:bool) {
    head:[4]u8
    if !raw_receive(c.socket,head[:]) {return}
    length:=int(u32(head[0])|u32(head[1])<<8|u32(head[2])<<16|u32(head[3])<<24)
    if length<1+NOISE_TAG || length>FRAME_MAX+NOISE_TAG || length>len(buffer) {return}
    sealed:=buffer[:length]
    if !raw_receive(c.socket,sealed) {return}
    plain:=buffer[:length-NOISE_TAG]
    if !cipher_open(&c.receive,sealed,plain) {return}
    if plain[0]==0 || plain[0]>u8(max(Msg)) {return}
    return Msg(plain[0]),plain[1:],true
}

@(private)
raw_send :: proc(socket:net.TCP_Socket,bytes:[]u8) -> bool {
    at:=0
    for at<len(bytes) {
        n,e:=net.send_tcp(socket,bytes[at:])
        if e!=nil || n<=0 {return false}
        at+=n
    }
    return true
}

@(private)
raw_receive :: proc(socket:net.TCP_Socket,bytes:[]u8) -> bool {
    at:=0
    for at<len(bytes) {
        n,e:=net.recv_tcp(socket,bytes[at:])
        if e!=nil || n<=0 {return false}
        at+=n
    }
    return true
}
