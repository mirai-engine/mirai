package kai

import "base:runtime"
import "core:crypto"
import "core:net"
import "core:sync"
import "core:time"
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

// The kinds of messages, each a byte and its body (agent.odin reads them).
Msg :: enum u8 {
    None,
    Hello,   // name, device, port u16, then a Tell's body: who this end is and what it holds
    Tell,    // count u16 × Tell_Entry: heads this end holds now
    Want,    // org, count u16 × address: send these chunks
    Chunks,  // count u16 × (address, codec u8, raw u32, stored u32, bytes): the chunks asked, in order
    Lack,    // count u16 × address: chunks asked that this end does not have
    Ddc_Ask, // org, key: the derived data set of key, answered by a Tell
    Join,    // org, name, device: the initiator proved an invite of org
    Welcome, // org, address: the org's record that now lists the joining device
    Bye,     // why, as text
    Web_Login, // name, password: a server's web view signs in as this device
}

// A head one end holds: an org's record, a repository's shared bookmarks or
// the derived data set of a key (address zero: none, the answer to an ask).
Tell_Kind :: enum u8 {Org,Repo,Ddc}

Tell_Entry :: struct #packed {
    kind:Tell_Kind,
    org:Org_Id,
    id:store.Hash,      // a repository's id in its first 16 bytes, or a derived data key
    address:store.Hash,
}

Conn :: struct {
    socket:net.TCP_Socket,
    send:Cipher,
    receive:Cipher,
    send_lock:sync.Mutex,
    plain:[]u8, // FRAME_MAX bytes, under send_lock
    out:[]u8,   // FRAME_MAX+NOISE_TAG+4 bytes, under send_lock
    peer:Key,
    hs:Handshake, // kept after it ends for its invite proof, its keys zeroed
    remote:net.Endpoint,
    closed:bool,
}

// The bytes a connection keeps.
@(private)
conn_buffers :: proc(c:^Conn) -> bool {
    plain,pe:=make([]u8,FRAME_MAX)
    out,oe:=make([]u8,FRAME_MAX+NOISE_TAG+4)
    c.plain,c.out=plain,out
    return pe==nil && oe==nil
}

conn_free :: proc(c:^Conn) {
    if !c.closed {net.close(c.socket)}
    crypto.zero_explicit(&c.send,size_of(Cipher))
    crypto.zero_explicit(&c.receive,size_of(Cipher))
    handshake_destroy(&c.hs)
    delete(c.plain)
    delete(c.out)
    free(c)
}

// Closes the socket, so a thread reading it wakes.
conn_close :: proc(c:^Conn) {
    sync.mutex_lock(&c.send_lock)
    defer sync.mutex_unlock(&c.send_lock)
    if c.closed {return}
    c.closed=true
    net.shutdown(c.socket,.Both)
    net.close(c.socket)
}

@(private)
socket_tune :: proc(socket:net.TCP_Socket) {
    net.set_option(socket,.TCP_Nodelay,true)
    net.set_option(socket,.Keep_Alive,true)
    net.set_option(socket,.Send_Buffer_Size,4<<20)
    net.set_option(socket,.Receive_Buffer_Size,4<<20)
    when ODIN_OS==.Darwin {net.set_option(socket,.No_SIGPIPE_From_EPIPE,true)}
}

// Dials address (host:port) and runs the handshake as initiator: expect, when
// not zero, is the key the other end must prove; secret, an invite's.
conn_dial :: proc(address:string,identity:Identity,expect:Key,secret:[32]u8={},timeout:=10*time.Second) -> (c:^Conn,error:Error) {
    socket,e:=net.dial_tcp_from_hostname_and_port_string(address)
    if e!=nil {return nil,.Unreachable}
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
    net.set_option(socket,.Receive_Timeout,timeout)
    handshake_init(&c.hs,true,identity)
    c.hs.secret=secret
    m1:[NOISE_MSG1]u8
    m2:[NOISE_MSG2]u8
    m3:[NOISE_MSG3]u8
    ok:=handshake_write_1(&c.hs,m1[:]) && raw_send(socket,m1[:]) &&
        raw_receive(socket,m2[:]) && handshake_read_2(&c.hs,m2[:],m3[:],expect) && raw_send(socket,m3[:])
    if !ok {
        conn_free(c)
        return nil,.Unauthorized
    }
    c.peer=c.hs.peer
    c.send,c.receive=handshake_split(&c.hs)
    net.set_option(socket,.Receive_Timeout,time.Duration(0))
    return c,.None
}

// Runs the handshake as responder on an accepted socket.
conn_accept :: proc(socket:net.TCP_Socket,remote:net.Endpoint,identity:Identity,timeout:=10*time.Second) -> (c:^Conn,error:Error) {
    socket_tune(socket)
    me:runtime.Allocator_Error
    if c,me=new(Conn);me!=nil {return nil,.Out_Of_Memory}
    c.socket,c.remote=socket,remote
    if !conn_buffers(c) {
        conn_free(c)
        return nil,.Out_Of_Memory
    }
    net.set_option(socket,.Receive_Timeout,timeout)
    handshake_init(&c.hs,false,identity)
    m1:[NOISE_MSG1]u8
    m2:[NOISE_MSG2]u8
    m3:[NOISE_MSG3]u8
    ok:=raw_receive(socket,m1[:]) && handshake_read_1(&c.hs,m1[:],m2[:]) && raw_send(socket,m2[:]) &&
        raw_receive(socket,m3[:]) && handshake_read_3(&c.hs,m3[:])
    if !ok {
        conn_free(c)
        return nil,.Unauthorized
    }
    c.peer=c.hs.peer
    c.send,c.receive=handshake_split(&c.hs)
    net.set_option(socket,.Receive_Timeout,time.Duration(0))
    return c,.None
}

// Sends one message: kind and body, sealed as one frame.
conn_send :: proc(c:^Conn,kind:Msg,body:..[]u8) -> bool {
    sync.mutex_lock(&c.send_lock)
    defer sync.mutex_unlock(&c.send_lock)
    n:=1
    for b in body {n+=len(b)}
    if c.closed || n>FRAME_MAX {return false}
    c.plain[0]=u8(kind)
    at:=1
    for b in body {
        copy(c.plain[at:],b)
        at+=len(b)
    }
    length:=u32(n+NOISE_TAG)
    for k in 0..<4 {c.out[k]=u8(length>>(8*uint(k)))}
    cipher_seal(&c.send,c.plain[:n],c.out[4:][:n+NOISE_TAG])
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
