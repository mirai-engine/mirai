package mirai_net

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/hkdf"
import "core:crypto/x25519"
import "core:encoding/endian"
import "core:mem"

// Every connection is sealed.
//
// The server answers a request with its lasting X25519 key next to the
// cookie. The client mixes the exchange of a key made for that attempt with
// that server key and the key of the invitation into a proof key, and seals
// with it what it presents: a server answers only a proof that opens, so a
// wrong invitation gets no answer at all, and only who holds the exchange can
// try invitations offline. The server then makes its own key for the
// connection, and the session keys come from both exchanges and the
// invitation. Every datagram after that is sealed with ChaCha20-Poly1305: one
// key per direction, the sequence number of the datagram as nonce, and a new
// key derived from the old one every rekey_interval datagrams, long before a
// nonce could repeat.

KEY_BYTES :: 32
Key :: [KEY_BYTES]u8
@(private) TAG_BYTES :: chacha20poly1305.TAG_SIZE
@(private) REKEY_INTERVAL :: 1<<24
@(private) LABEL_SESSION :: "mirai-net-2 session"
@(private) LABEL_PROOF :: "mirai-net-2 proof"
@(private) LABEL_INVITE :: "mirai-net-2 invite"
@(private) LABEL_REKEY :: "mirai-net-2 rekey"

// A wrong proof costs its sender: an address (its IP, an IPv6 /64) presents
// FAILED_BURST of them back to back and then one every FAILED_INTERVAL; the
// server drops what comes sooner before any key exchange. It is the rate of a
// token bucket kept as the time the address has spent its allowance up to
// (due), in a table of fixed size: nothing is kept per guess.
@(private) FAILED_WAYS :: 8
@(private) FAILED_SETS :: 512
@(private) FAILED_BURST :: 4
@(private) FAILED_INTERVAL :: 1.0 // s
@(private) Failed :: struct {key:u64,due:f64}

@(private)
Host_Secure :: struct {
    private,public:Key,
    invite:Key, // what Host_Desc.invite gives: every key of a connection depends on it
    rekey_interval:u64,
    handshakes:int, // key exchanges left in this update
    failed:[]Failed, // server: FAILED_SETS sets of FAILED_WAYS, by the address_key of the address
}

@(private)
Peer_Secure :: struct {
    has_old:bool,
    refused:bool, // client: an answer came that the server could not have sent
    ephemeral:Key,  // client, until accepted: its secret
    public:Key,     // the public key this end made for the connection
    accept,send,receive,receive_old:Key,
    send_epoch,receive_epoch:u64,
}

@(private)
secure_host_init :: proc(h:^Host) {
    s:=&h.back.secure
    s.rekey_interval=REKEY_INTERVAL
    if h.desc.handshakes_per_update<=0 {h.desc.handshakes_per_update=8}
    invite:[8]u8
    endian.unchecked_put_u64le(invite[:],h.desc.invite)
    info:[len(LABEL_INVITE)+4]u8
    endian.unchecked_put_u32le(info[copy(info[:],LABEL_INVITE):],h.desc.protocol_id)
    hkdf.extract_and_expand(.SHA256,nil,invite[:],info[:],s.invite[:])
    if h.desc.mode==.Server {
        crypto.rand_bytes(s.private[:])
        x25519.scalarmult_basepoint(s.public[:],s.private[:])
        s.failed=host_make(h,Failed,FAILED_SETS*FAILED_WAYS)
    }
}

// The record of the wrong proofs of an address: its own, a free one of its
// set, or else the one of its set that frees soonest, so a crowd of guessers
// never shuts out a newcomer who brings the right invitation.
@(private)
failed_record :: proc(b:^Back,from:Address) -> ^Failed {
    sender:=from
    if sender.kind!=.Memory {sender.port=0}
    if sender.kind==.IP6 {mem.zero_slice(sender.ip[8:])}
    key:=address_key(b,sender)
    set:=b.secure.failed[key%FAILED_SETS*FAILED_WAYS:][:FAILED_WAYS]
    record:=&set[0]
    for &other in set {
        if other.key==key {return &other}
        if other.due<record.due {record=&other}
    }
    record^={key=key,due=b.now}
    return record
}

// False when the other end sent a point that leaves nothing secret.
@(private)
secure_exchange :: proc(out,scalar,point:^Key) -> bool {
    x25519.scalarmult(out[:],scalar[:],point[:])
    zero:Key
    return crypto.compare_constant_time(out[:],zero[:])==0
}

@(private)
aead_nonce :: #force_inline proc "contextless" (counter:u64) -> (nonce:[chacha20poly1305.IV_SIZE]u8) {
    endian.unchecked_put_u64le(nonce[4:],counter)
    return
}
@(private)
aead_seal :: proc(key:^Key,counter:u64,aad,body,tag:[]u8) {
    ctx:chacha20poly1305.Context
    nonce:=aead_nonce(counter)
    chacha20poly1305.init(&ctx,key[:])
    chacha20poly1305.seal(&ctx,body,tag,nonce[:],aad,body)
    chacha20poly1305.reset(&ctx)
}
// Opens in place. A body that is not authentic comes back zeroed.
@(private)
aead_open :: proc(key:^Key,counter:u64,aad,body,tag:[]u8) -> bool {
    ctx:chacha20poly1305.Context
    nonce:=aead_nonce(counter)
    chacha20poly1305.init(&ctx,key[:])
    ok:=chacha20poly1305.open(&ctx,body,nonce[:],aad,body,tag)
    chacha20poly1305.reset(&ctx)
    return ok
}

// What the keys of an attempt are bound to: the application, its version and
// protocol, the attempt, the client's key and the server's lasting key.
@(private)
secure_info :: proc(h:^Host,info:[]u8,label:string,salt:u64,client_public,server_key:^Key) -> int {
    at:=copy(info,label)
    endian.unchecked_put_u32le(info[at:],h.desc.protocol_id)
    endian.unchecked_put_u32le(info[at+4:],h.desc.version)
    endian.unchecked_put_u64le(info[at+8:],host_protocol_hash(h))
    endian.unchecked_put_u64le(info[at+16:],salt)
    at+=24
    at+=copy(info[at:],client_public[:])
    at+=copy(info[at:],server_key[:])
    return at
}

// The key that seals what a client presents: only who holds the exchange of
// the client's key with the server's lasting key, and the invitation, makes it.
@(private)
proof_key :: proc(h:^Host,key,shared,client_public,server_key:^Key,salt:u64) {
    info:[len(LABEL_PROOF)+24+KEY_BYTES*2]u8
    secure_info(h,info[:],LABEL_PROOF,salt,client_public,server_key)
    hkdf.extract_and_expand(.SHA256,h.back.secure.invite[:],shared[:],info[:],key[:])
}

// The keys of a connection: from the exchange of the two keys made for it,
// that of the client's key with the server's lasting one, and the invitation.
@(private)
secure_session :: proc(h:^Host,s:^Peer_Secure,salt:u64,exchanged,static,client_public,server_public,server_key:^Key) {
    material:[KEY_BYTES*2]u8
    copy(material[:],exchanged[:])
    copy(material[KEY_BYTES:],static[:])
    info:[len(LABEL_SESSION)+24+KEY_BYTES*3]u8
    at:=secure_info(h,info[:],LABEL_SESSION,salt,client_public,server_key)
    copy(info[at:],server_public[:])
    keys:[KEY_BYTES*3]u8
    hkdf.extract_and_expand(.SHA256,h.back.secure.invite[:],material[:],info[:],keys[:])
    client:=h.desc.mode==.Client
    copy(s.accept[:],keys[:KEY_BYTES])
    copy(client?s.send[:]:s.receive[:],keys[KEY_BYTES:][:KEY_BYTES])
    copy(client?s.receive[:]:s.send[:],keys[KEY_BYTES*2:])
    s.send_epoch,s.receive_epoch,s.has_old=0,0,false
    crypto.zero_explicit(&material,size_of(material))
    crypto.zero_explicit(&keys,size_of(keys))
}

// Client: makes the key of a connection attempt.
@(private)
secure_client_begin :: proc(p:^Peer) {
    s:=&p.secure
    s^={}
    crypto.rand_bytes(s.ephemeral[:])
    x25519.scalarmult_basepoint(s.public[:],s.ephemeral[:])
}

// Client: seals what it presents for a server that answered with server_key.
// False when that key leaves nothing secret.
@(private)
secure_client_prove :: proc(h:^Host,p:^Peer,c:^Challenger,server_key:^Key) -> bool {
    s:=&p.secure
    c.server_key=server_key^
    if !secure_exchange(&c.shared,&s.ephemeral,&c.server_key) {return false}
    key:Key
    defer crypto.zero_explicit(&key,KEY_BYTES)
    proof_key(h,&key,&c.shared,&s.public,&c.server_key,p.client_salt)
    aead_seal(&key,0,s.public[:],nil,c.proof[:])
    return true
}

// Client: the keys of the connection from the answer of the server it proved
// itself to. False when the answer is not from that server.
@(private)
secure_client_finish :: proc(h:^Host,p:^Peer,c:^Challenger,server_public:^Key,sealed:[]u8) -> bool {
    s:=&p.secure
    exchanged:Key
    defer crypto.zero_explicit(&exchanged,KEY_BYTES)
    if !secure_exchange(&exchanged,&s.ephemeral,server_public) {return false}
    secure_session(h,s,p.client_salt,&exchanged,&c.shared,&s.public,server_public,&c.server_key)
    if !aead_open(&s.accept,0,server_public[:],sealed[:len(sealed)-TAG_BYTES],sealed[len(sealed)-TAG_BYTES:]) {return false}
    crypto.zero_explicit(&s.ephemeral,KEY_BYTES)
    return true
}

// Server: opens the proof a client presented and makes the keys of its
// connection. False when it does not open: it gets no answer.
@(private)
secure_server_accept :: proc(h:^Host,s:^Peer_Secure,salt:u64,client_public:^Key,proof:[]u8) -> bool {
    hs:=&h.back.secure
    s^={}
    secret,exchanged,static,key:Key
    defer {
        crypto.zero_explicit(&secret,KEY_BYTES)
        crypto.zero_explicit(&exchanged,KEY_BYTES)
        crypto.zero_explicit(&static,KEY_BYTES)
        crypto.zero_explicit(&key,KEY_BYTES)
    }
    if !secure_exchange(&static,&hs.private,client_public) {return false}
    proof_key(h,&key,&static,client_public,&hs.public,salt)
    if !aead_open(&key,0,client_public[:],nil,proof) {return false}
    // The client's key gave a secret with the lasting key, so it gives one with this one too.
    crypto.rand_bytes(secret[:])
    x25519.scalarmult_basepoint(s.public[:],secret[:])
    x25519.scalarmult(exchanged[:],secret[:],client_public[:])
    secure_session(h,s,salt,&exchanged,&static,client_public,&s.public,&hs.public)
    return true
}

@(private)
key_ratchet :: proc(key:^Key) {
    next:Key
    hkdf.expand(.SHA256,key[:],transmute([]u8)string(LABEL_REKEY),next[:])
    key^=next
}

@(private)
secure_seal :: proc(h:^Host,p:^Peer,aad,body,tag:[]u8) {
    s:=&p.secure
    for epoch:=p.send_counter/h.back.secure.rekey_interval;s.send_epoch<epoch;s.send_epoch+=1 {key_ratchet(&s.send)}
    aead_seal(&s.send,p.send_counter,aad,body,tag)
}

// The key of a later epoch is only kept once a datagram sealed with it proved authentic.
@(private)
secure_open :: proc(h:^Host,p:^Peer,counter:u64,aad,body,tag:[]u8) -> bool {
    s:=&p.secure
    epoch:=counter/h.back.secure.rekey_interval
    switch {
    case epoch==s.receive_epoch:
        return aead_open(&s.receive,counter,aad,body,tag)
    case epoch+1==s.receive_epoch && s.has_old:
        return aead_open(&s.receive_old,counter,aad,body,tag)
    case epoch==s.receive_epoch+1:
        next:=s.receive
        key_ratchet(&next)
        if !aead_open(&next,counter,aad,body,tag) {return false}
        s.receive_old,s.receive,s.receive_epoch,s.has_old=s.receive,next,epoch,true
        return true
    }
    return false
}
