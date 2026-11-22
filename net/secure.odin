package mirai_net

import "core:crypto"
import "core:crypto/aegis"
import "core:crypto/chacha20poly1305"
import "core:crypto/hkdf"
import "core:crypto/hmac"
import "core:crypto/sha2"
import "core:crypto/siphash"
import "core:crypto/x25519"
import "core:encoding/endian"
import "core:mem"
import "mirai:std/blake3"

// Every connection is sealed, and its first datagram already carries data.
//
// A connection is the Noise handshake NKpsk0 (Noise_NKpsk0_25519_ChaChaPoly_SHA256):
//
//     <- s
//     ...
//     -> psk, e, es    Initiate: the payload is the client's first datagram of data
//     <- e, ee         Response
//
// The client knows the server's key s before it writes anything: from the
// invitation, or from the Key a server without one answers a Hello with. The
// pre-shared key comes from the invitation's secret (from zero without one).
// An Initiate opens only for the holder of s, and only if its sender knew s
// and the secret, so its payload is hidden and authentic from the first
// datagram; trying secrets against a recorded one takes s. The Response proves
// to the client that it talks to the holder of s and the secret, and the keys
// that follow ee die with the two ephemeral keys. The server learns nothing of
// the client but that it holds the invitation, and that it receives at its
// address only once a datagram under those keys comes from there.
//
// After the handshake every datagram is sealed with AEGIS-128L, on the AES
// instructions where the processor has them: one key per direction (the first
// half of each key Split gives), the sequence number of the datagram as nonce,
// and a new key derived from the old one every rekey_interval datagrams, long
// before a nonce could repeat and far below what one key may seal. The client's
// datagram 0 is the payload of its Initiate, so its AEGIS key starts at 1.
//
// A connection between identities is the Noise handshake IK
// (Noise_IK_25519_ChaChaPoly_SHA256), against the server's identity
// (Host_Desc.identity), which the client knows before it writes anything:
//
//     <- s
//     ...
//     -> e, es, s, ss  Initiate_Identity: the payload is the client's claim and its datagram 0
//     <- e, ee, se     Response
//
// Its Initiate shows the client's identity only to the holder of the
// server's, and its MAC is keyed by the server's public key alone: it keeps out
// whoever does not know where it talks, nothing else, and the same rate,
// filters and cookies as an Initiate stand behind it. That Initiate can be
// replayed once the server forgot it, so the server answers it but hands its
// game nothing until a datagram under the keys of the connection proves the
// client holds its e and its s: only then does authorize read the claim, and
// the connection and its datagram 0 reach the game.

KEY_BYTES :: 32
Key :: [KEY_BYTES]u8
@(private) TAG_BYTES :: aegis.TAG_SIZE_128 // also the tag of ChaCha20-Poly1305 in the handshake
@(private) REKEY_INTERVAL :: 1<<24
@(private) NOISE_NK :: "Noise_NKpsk0_25519_ChaChaPoly_SHA256"
@(private) NOISE_IK :: "Noise_IK_25519_ChaChaPoly_SHA256"
@(private) LABEL_IDENTITY_MAC :: "kai-1/mac"
@(private) SEALED_KEY_BYTES :: KEY_BYTES+TAG_BYTES // s in an Initiate_Identity

// The X25519 static key pair of an identity.
Dh_Key :: struct {private,public:Key}

// What a server's authorize says of the identity of a connection that proved it holds its keys.
// Pending: the connection reaches the game, which serves it only what lets the two catch up
// (host_authorize asks again); Refuse ends it with Unauthorized, or with Revoked once admitted.
Verdict :: enum u8 {Refuse,Pending,Accept}
Peer_Class :: enum u8 {Anonymous,Member,Node,Grant}
Authorization :: struct {verdict:Verdict,class:Peer_Class}
// Decides who a server with an identity admits: peer is the client's identity and claim what it
// presented with it. check runs on the network half (the worker thread when one runs), when the
// connection is confirmed and on host_authorize; it reads only what it is given and what that thread
// may read.
Authorize :: struct {
    data:rawptr,
    check:proc(data:rawptr,peer:Key,claim:[]u8) -> Authorization,
}
CLAIM_BYTES :: 256 // the most a claim takes

// A new identity. Not ok when the system gives no secure random bytes.
dh_key :: proc() -> (key:Dh_Key,ok:bool) {
    when !crypto.HAS_RAND_BYTES {return}
    private:Key
    defer crypto.zero_explicit(&private,KEY_BYTES)
    crypto.rand_bytes(private[:])
    return dh_key_from(&private),true
}
// The identity of a private key.
dh_key_from :: proc(private:^Key) -> (key:Dh_Key) {
    key.private=private^
    x25519.scalarmult_basepoint(key.public[:],key.private[:])
    return
}
@(private) LABEL_SECRET :: "mirai-net-3 secret"
@(private) LABEL_REKEY :: "mirai-net-3 rekey"

// A wrong Initiate costs its sender: an address (its IP, an IPv6 /64) presents
// FAILED_BURST of them back to back and then one every FAILED_INTERVAL; the
// server drops what comes sooner before any key exchange. It is the rate of a
// token bucket kept as the time the address has spent its allowance up to
// (due), in a table of fixed size: nothing is kept per guess.
@(private) FAILED_WAYS :: 8
@(private) FAILED_SETS :: 512
@(private) FAILED_BURST :: 4
@(private) FAILED_INTERVAL :: 1.0 // s
@(private) Failed :: struct {key:u64,due:f64}

// The Initiates a server opened, by their key e, in Bloom filters: a copy that
// comes later opens nothing. Those without a cookie (only with an invitation)
// go to a filter that lasts as long as the host, which is as long as its key s;
// those with one, to two generations that turn every COOKIE_SECONDS, as long as
// a cookie is good. A filter takes at most SEEN_LIMIT, which keeps a false
// positive under one in 10^4; past it, or on a hit, the client gets a Retry
// with a cookie and tries again with another e: a full filter costs a round
// trip, never a connection. A generation that is full puts off what comes until
// it turns.
@(private) SEEN_BITS :: 1<<20
@(private) SEEN_HASHES :: 3
@(private) SEEN_LIMIT :: 1<<14
@(private) SEEN_LASTING :: 0 // the filter of Initiates without a cookie; 1 and 2 are the generations of those with one
// With an invitation, an update that ran out of key exchanges makes Initiates
// without a cookie get a Retry instead for BUSY_SECONDS: spoofed senders never
// return the cookie, and the exchanges are left for those who do.
@(private) BUSY_SECONDS :: 1.0
@(private) MAC_BYTES :: 16
@(private) LABEL_MAC :: "mirai-net-3 mac"

@(private)
Host_Secure :: struct {
    private,public:Key, // server: s, the key its connections are made against. Client: s of the invitation
    psk:Key,            // the invitation's secret, as the handshake mixes it
    invited:bool,       // s and the secret come from an invitation: no Hello is answered, no cookie asked
    rekey_interval:u64,
    handshakes:int,     // key exchanges left in this update
    exchanges:u64,      // server: Initiates it tried to open
    failed:[]Failed,    // server: FAILED_SETS sets of FAILED_WAYS, by the address_key of the address
    seen:[3][]u64,      // server: the filters of Initiates (SEEN_LASTING and the two generations)
    seen_count:[3]int,  // what each one took
    seen_current:int,   // the generation that takes now: 1 or 2
    seen_since:f64,
    busy_until:f64,     // server with an invitation: until then an Initiate needs a cookie
    mac:Key,            // the key of the MAC that ends an Initiate: whoever knows s and the secret has it
    identity_mac:Key,   // server with an identity: that of an Initiate_Identity, which whoever knows its public key has
}

@(private)
Peer_Secure :: struct {
    has_old:bool,
    refused:bool,   // client: an answer came that the server could not have sent
    confirmed:bool, // server: a datagram under the keys of the connection came from it; a client is from the Response on
    initiator:Key,  // server: e of the Initiate, until confirmed
    response:[RESPONSE_BYTES]u8, // server: the Response, again for every copy of that Initiate until confirmed
    send,receive,receive_old:Key,
    send_epoch,receive_epoch:u64,
    peer:Key,       // the identity of the other end of an identity connection; zero for any other
    authorization:Authorization,
    claim:[CLAIM_BYTES]u8, // server: what the client of an identity connection presented
    claim_size:int,
    early:[EARLY_BYTES]u8, // server: its datagram 0, until confirmed
    early_size:int,
}

// The symmetric state of a handshake (Noise, section 5.2): its primitives are those of every
// pattern of the engine, the NK and IK of a connection here and the XX of a pairing in kai.
Noise :: struct {ck,h,k:Key,n:u64}

@(private)
secure_host_init :: proc(h:^Host) {
    s:=&h.back.secure
    d:=&h.desc
    s.rekey_interval=REKEY_INTERVAL
    if d.handshakes_per_update<=0 {d.handshakes_per_update=8}
    s.psk=invite_psk(d.invite.secret,d.protocol_id)
    s.seen_current=1
    if d.mode==.Server {
        s.invited=d.invite.private!={}
        s.private=d.invite.private
        if !s.invited {crypto.rand_bytes(s.private[:])}
        x25519.scalarmult_basepoint(s.public[:],s.private[:])
        s.failed=host_make(h,Failed,FAILED_SETS*FAILED_WAYS)
        for &generation in s.seen {generation=host_make(h,u64,SEEN_BITS/64)}
    } else {
        s.invited=d.invite.public!={}
        s.public=d.invite.public
    }
    s.mac=mac_key(&s.public,&s.psk)
    if d.mode==.Server && d.identity!={} {s.identity_mac=identity_mac_key(&d.identity.public)}
}

// The key of the MAC of an Initiate_Identity to the server of identity public.
@(private)
identity_mac_key :: proc(public:^Key) -> Key {
    hasher:blake3.Hasher
    blake3.init(&hasher)
    blake3.update(&hasher,transmute([]u8)string(LABEL_IDENTITY_MAC))
    blake3.update(&hasher,public[:])
    return Key(blake3.final(&hasher))
}

// The key of the MAC of an Initiate to the server of key s, with the pre-shared key psk.
@(private)
mac_key :: proc(public,psk:^Key) -> (key:Key) {
    ctx:sha2.Context_256
    sha2.init_256(&ctx)
    sha2.update(&ctx,transmute([]u8)string(LABEL_MAC))
    sha2.update(&ctx,public[:])
    sha2.update(&ctx,psk[:])
    sha2.final(&ctx,key[:])
    return
}
// The MAC of what comes before it in an Initiate.
@(private)
mac_of :: proc(key:^Key,bytes:[]u8) -> (mac:[MAC_BYTES]u8) {
    sum:[32]u8
    hmac.sum(.SHA256,sum[:],bytes,key[:])
    copy(mac[:],sum[:MAC_BYTES])
    return
}

// The pre-shared key of the handshake: the secret of the invitation, for the application.
@(private)
invite_psk :: proc(secret:u64,protocol_id:u32) -> (psk:Key) {
    bytes:[8]u8
    endian.unchecked_put_u64le(bytes[:],secret)
    info:[len(LABEL_SECRET)+4]u8
    endian.unchecked_put_u32le(info[copy(info[:],LABEL_SECRET):],protocol_id)
    hkdf.extract_and_expand(.SHA256,nil,bytes[:],info[:],psk[:])
    return
}

@(private)
secure_host_destroy :: proc(h:^Host) {
    s:=&h.back.secure
    delete(s.failed,h.allocator)
    for generation in s.seen {delete(generation,h.allocator)}
    crypto.zero_explicit(s,size_of(Host_Secure))
}

// The key of an invitation is not a point of small order, which would leave nothing secret.
@(private)
key_usable :: proc(public:^Key) -> bool {
    probe,shared:Key
    probe[0]=9
    return secure_exchange(&shared,&probe,public)
}

// The record of the wrong Initiates of an address: its own, a free one of its
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

@(private)
seen_hash :: proc(b:^Back,initiator:^Key) -> u64 {return siphash.sum_2_4(initiator[:],b.secret[:])}
// Whether the filter (SEEN_LASTING, or the generations when cookied) holds hash.
@(private)
seen_has :: proc(s:^Host_Secure,hash:u64,cookied:bool) -> bool {
    filters: for filter in (cookied?s.seen[1:]:s.seen[:1]) {
        for i in 0..<SEEN_HASHES {
            bit:=hash>>(20*uint(i))&(SEEN_BITS-1)
            if filter[bit/64]&(1<<(bit%64))==0 {continue filters}
        }
        return true
    }
    return false
}
// The filter an Initiate goes to, and whether it has room.
@(private)
seen_filter :: proc(s:^Host_Secure,cookied:bool) -> (index:int,room:bool) {
    index=cookied?s.seen_current:SEEN_LASTING
    return index,s.seen_count[index]<SEEN_LIMIT
}
@(private)
seen_add :: proc(s:^Host_Secure,hash:u64,cookied:bool) {
    index,_:=seen_filter(s,cookied)
    for i in 0..<SEEN_HASHES {
        bit:=hash>>(20*uint(i))&(SEEN_BITS-1)
        s.seen[index][bit/64]|=1<<(bit%64)
    }
    s.seen_count[index]+=1
}
@(private)
seen_turn :: proc(s:^Host_Secure,now:f64) {
    if now-s.seen_since<COOKIE_SECONDS {return}
    s.seen_current=3-s.seen_current
    mem.zero_slice(s.seen[s.seen_current])
    s.seen_count[s.seen_current]=0
    s.seen_since=now
}

// False when the other end sent a point that leaves nothing secret.
secure_exchange :: proc(out,scalar,point:^Key) -> bool {
    x25519.scalarmult(out[:],scalar[:],point[:])
    zero:Key
    return crypto.compare_constant_time(out[:],zero[:])==0
}

// h starts as the name of the protocol, padded with zeros, or as its hash when it is longer than
// one; then the prologue and, when the pattern has it before its messages, the responder's key.
noise_init :: proc(n:^Noise,name:string,prologue:[]u8,responder:^Key=nil) {
    n^={}
    if len(name)<=KEY_BYTES {
        copy(n.h[:],name)
    } else {
        ctx:sha2.Context_256
        sha2.init_256(&ctx)
        sha2.update(&ctx,transmute([]u8)string(name))
        sha2.final(&ctx,n.h[:])
    }
    n.ck=n.h
    noise_mix_hash(n,prologue)
    if responder!=nil {noise_mix_hash(n,responder[:])}
}
noise_mix_hash :: proc(n:^Noise,data:[]u8,more:[]u8=nil) {
    ctx:sha2.Context_256
    sha2.init_256(&ctx)
    sha2.update(&ctx,n.h[:])
    sha2.update(&ctx,data)
    sha2.update(&ctx,more)
    sha2.final(&ctx,n.h[:])
}
noise_mix_key :: proc(n:^Noise,material:[]u8) {
    out:[KEY_BYTES*2]u8
    hkdf.extract_and_expand(.SHA256,n.ck[:],material,nil,out[:])
    copy(n.ck[:],out[:KEY_BYTES])
    copy(n.k[:],out[KEY_BYTES:])
    n.n=0
    crypto.zero_explicit(&out,size_of(out))
}
noise_mix_key_and_hash :: proc(n:^Noise,material:[]u8) {
    out:[KEY_BYTES*3]u8
    hkdf.extract_and_expand(.SHA256,n.ck[:],material,nil,out[:])
    copy(n.ck[:],out[:KEY_BYTES])
    noise_mix_hash(n,out[KEY_BYTES:][:KEY_BYTES])
    copy(n.k[:],out[KEY_BYTES*2:])
    n.n=0
    crypto.zero_explicit(&out,size_of(out))
}
noise_iv :: proc "contextless" (n:u64) -> (iv:[chacha20poly1305.IV_SIZE]u8) {
    endian.unchecked_put_u64le(iv[4:],n)
    return
}
// Seals body in place, with the hash as associated data.
noise_encrypt :: proc(n:^Noise,body,tag:[]u8) {
    ctx:chacha20poly1305.Context
    iv:=noise_iv(n.n)
    chacha20poly1305.init(&ctx,n.k[:])
    chacha20poly1305.seal(&ctx,body,tag,iv[:],n.h[:],body)
    chacha20poly1305.reset(&ctx)
    n.n+=1
    noise_mix_hash(n,body,tag)
}
// Opens body in place. A body that is not authentic comes back zeroed.
noise_decrypt :: proc(n:^Noise,body,tag:[]u8) -> bool {
    h:=n.h
    noise_mix_hash(n,body,tag)
    ctx:chacha20poly1305.Context
    iv:=noise_iv(n.n)
    chacha20poly1305.init(&ctx,n.k[:])
    ok:=chacha20poly1305.open(&ctx,body,iv[:],h[:],body,tag)
    chacha20poly1305.reset(&ctx)
    n.n+=1
    return ok
}
// The keys of the initiator's and the responder's messages; the state is wiped.
noise_split :: proc(n:^Noise,initiator,responder:^Key) {
    out:[KEY_BYTES*2]u8
    hkdf.extract_and_expand(.SHA256,n.ck[:],nil,nil,out[:])
    copy(initiator[:],out[:KEY_BYTES])
    copy(responder[:],out[KEY_BYTES:])
    crypto.zero_explicit(&out,size_of(out))
    crypto.zero_explicit(n,size_of(Noise))
}

// Client: -> psk, e, es with the pre-shared key psk, or with its identity -> e, es, s, ss. The
// message is e, then s sealed with an identity, then the payload, sealed in place, then its tag.
// False when a key of the server leaves nothing secret.
@(private)
noise_initiate :: proc(n:^Noise,ephemeral:^Key,prologue:[]u8,server:^Key,psk:^Key,identity:^Dh_Key,message:[]u8) -> bool {
    noise_init(n,identity==nil?NOISE_NK:NOISE_IK,prologue,server)
    if identity==nil {noise_mix_key_and_hash(n,psk[:])}
    crypto.rand_bytes(ephemeral[:])
    x25519.scalarmult_basepoint(message[:KEY_BYTES],ephemeral[:])
    noise_mix_hash(n,message[:KEY_BYTES])
    if identity==nil {noise_mix_key(n,message[:KEY_BYTES])}
    shared:Key
    defer crypto.zero_explicit(&shared,KEY_BYTES)
    if !secure_exchange(&shared,ephemeral,server) {return false}
    noise_mix_key(n,shared[:])
    at:=KEY_BYTES
    if identity!=nil {
        copy(message[at:],identity.public[:])
        noise_encrypt(n,message[at:][:KEY_BYTES],message[at+KEY_BYTES:][:TAG_BYTES])
        at+=SEALED_KEY_BYTES
        if !secure_exchange(&shared,&identity.private,server) {return false}
        noise_mix_key(n,shared[:])
    }
    end:=len(message)-TAG_BYTES
    noise_encrypt(n,message[at:end],message[end:])
    return true
}

// Server: opens an Initiate's message in place; with peer, an Initiate_Identity, whose client's
// identity goes to peer. False when it does not open: another s or secret, a point of small order,
// or damage.
@(private)
noise_accept :: proc(n:^Noise,prologue:[]u8,private,public,psk:^Key,message:[]u8,peer:^Key=nil) -> bool {
    noise_init(n,peer==nil?NOISE_NK:NOISE_IK,prologue,public)
    if peer==nil {noise_mix_key_and_hash(n,psk[:])}
    initiator:=(^Key)(raw_data(message))
    noise_mix_hash(n,initiator[:])
    if peer==nil {noise_mix_key(n,initiator[:])}
    shared:Key
    defer crypto.zero_explicit(&shared,KEY_BYTES)
    if !secure_exchange(&shared,private,initiator) {return false}
    noise_mix_key(n,shared[:])
    at:=KEY_BYTES
    if peer!=nil {
        if !noise_decrypt(n,message[at:][:KEY_BYTES],message[at+KEY_BYTES:][:TAG_BYTES]) {return false}
        peer^=(^Key)(&message[at])^
        at+=SEALED_KEY_BYTES
        if !secure_exchange(&shared,private,peer) {return false}
        noise_mix_key(n,shared[:])
    }
    end:=len(message)-TAG_BYTES
    return noise_decrypt(n,message[at:end],message[end:])
}

// Server: <- e, ee, and se to the client's identity peer when there is one. The message is e, then the
// payload, sealed in place, then its tag; the keys of the connection go to s.
@(private)
noise_respond :: proc(n:^Noise,initiator:^Key,message:[]u8,s:^Peer_Secure,peer:^Key=nil) -> bool {
    ephemeral,shared:Key
    defer {
        crypto.zero_explicit(&ephemeral,KEY_BYTES)
        crypto.zero_explicit(&shared,KEY_BYTES)
    }
    crypto.rand_bytes(ephemeral[:])
    x25519.scalarmult_basepoint(message[:KEY_BYTES],ephemeral[:])
    noise_mix_hash(n,message[:KEY_BYTES])
    if peer==nil {noise_mix_key(n,message[:KEY_BYTES])}
    if !secure_exchange(&shared,&ephemeral,initiator) {return false}
    noise_mix_key(n,shared[:])
    if peer!=nil {
        if !secure_exchange(&shared,&ephemeral,peer) {return false}
        noise_mix_key(n,shared[:])
    }
    end:=len(message)-TAG_BYTES
    noise_encrypt(n,message[KEY_BYTES:end],message[end:])
    noise_split(n,&s.receive,&s.send)
    s.send_epoch,s.receive_epoch,s.has_old=0,0,false
    return true
}

// Client: reads a Response in place, with the private key of its identity when it presented one; the keys
// of the connection go to s. False when it is not from the holder of s and the secret, or of the
// server's identity.
@(private)
noise_finish :: proc(n:^Noise,ephemeral:^Key,message:[]u8,s:^Peer_Secure,identity:^Key=nil) -> bool {
    responder:=(^Key)(raw_data(message))
    noise_mix_hash(n,responder[:])
    if identity==nil {noise_mix_key(n,responder[:])}
    shared:Key
    defer crypto.zero_explicit(&shared,KEY_BYTES)
    if !secure_exchange(&shared,ephemeral,responder) {return false}
    noise_mix_key(n,shared[:])
    if identity!=nil {
        if !secure_exchange(&shared,identity,responder) {return false}
        noise_mix_key(n,shared[:])
    }
    end:=len(message)-TAG_BYTES
    if !noise_decrypt(n,message[KEY_BYTES:end],message[end:]) {return false}
    noise_split(n,&s.send,&s.receive)
    s.send_epoch,s.receive_epoch,s.has_old=0,0,false
    return true
}

@(private)
aead_nonce :: #force_inline proc "contextless" (counter:u64) -> (nonce:[aegis.IV_SIZE_128L]u8) {
    endian.unchecked_put_u64le(nonce[:],counter)
    return
}
@(private)
aead_seal :: proc(key:^Key,counter:u64,aad,body,tag:[]u8) {
    ctx:aegis.Context
    nonce:=aead_nonce(counter)
    aegis.init(&ctx,key[:aegis.KEY_SIZE_128L])
    aegis.seal(&ctx,body,tag,nonce[:],aad,body)
    aegis.reset(&ctx)
}
// Opens in place. A body that is not authentic comes back zeroed.
@(private)
aead_open :: proc(key:^Key,counter:u64,aad,body,tag:[]u8) -> bool {
    ctx:aegis.Context
    nonce:=aead_nonce(counter)
    aegis.init(&ctx,key[:aegis.KEY_SIZE_128L])
    ok:=aegis.open(&ctx,body,nonce[:],aad,body,tag)
    aegis.reset(&ctx)
    return ok
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
