package mirai_net

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/ed25519"
import "core:crypto/hkdf"
import "core:crypto/x25519"
import "core:encoding/endian"
import "core:time"

// Every connection is sealed.
//
// The server answers a request with its lasting X25519 key next to the
// cookie. The client mixes the exchange of a key made for that attempt with
// the server's key (the one it pinned, or the one the answer brought) and the
// key of the invitation into a proof key, and seals with it what it presents:
// a server answers only a proof that opens, so a wrong invitation or a client
// that expects another server gets no answer at all, and only who holds the
// exchange can try invitations offline. The server then makes its own key for
// the connection, and the session keys come from both exchanges and the
// invitation. Every datagram after that is sealed with ChaCha20-Poly1305: one
// key per direction, the sequence number of the datagram as nonce, and a new
// key derived from the old one every rekey_interval datagrams, long before a
// nonce could repeat.
//
// A server may also demand a connect token: a blob that the backend of the
// game signs with Ed25519, naming the client, the servers it may join and
// until when. It travels sealed with the proof key, which is why only a
// client that pinned the server's key may send one.

KEY_BYTES :: 32
Key :: [KEY_BYTES]u8
TOKEN_ADDRESSES :: 4
TOKEN_BYTES :: TOKEN_SIGNED_BYTES+ed25519.SIGNATURE_SIZE
@(private) TOKEN_ADDRESS_BYTES :: 19
@(private) TOKEN_SIGNED_BYTES :: 21+TOKEN_ADDRESSES*TOKEN_ADDRESS_BYTES
@(private) TOKEN_FORMAT :: 1
@(private) TAG_BYTES :: chacha20poly1305.TAG_SIZE
@(private) REKEY_INTERVAL :: 1<<24
@(private) LABEL_SESSION :: "mirai-net-2 session"
@(private) LABEL_PROOF :: "mirai-net-2 proof"
@(private) LABEL_INVITE :: "mirai-net-2 invite"
@(private) LABEL_REKEY :: "mirai-net-2 rekey"

Security_Desc :: struct {
    private_key:Key,           // server: its X25519 key. Zero makes one for this run, which no client can know beforehand
    token_key:Key,             // server: Ed25519 public key of whoever issues connect tokens. Zero: tokens are not looked at
    require_token:bool,        // server: refuse a client without a valid token
    addresses:[TOKEN_ADDRESSES]Address, // server: where clients reach it; a token must name one of them. All empty: any
    handshakes_per_update:int, // server: key exchanges computed in one update, default 8
}

// What a client presents to a server.
Credentials :: struct {
    server_key:Key,        // X25519 public key of the server. Zero: the one its answer brings, so any server with the invitation
    token:[TOKEN_BYTES]u8, // as token_issue made it
    has_token:bool,
}

Token :: struct {
    protocol_id:u32,
    client_id:u64,  // reaches the server's game with the Connected command; not zero
    expires:i64,    // Unix seconds
    addresses:[TOKEN_ADDRESSES]Address, // servers it is good for
}

@(private)
Host_Secure :: struct {
    private,public:Key,
    invite:Key, // what Host_Desc.invite gives: every key of a connection depends on it
    token_key:ed25519.Public_Key,
    has_token_key:bool,
    rekey_interval:u64,
    handshakes:int, // key exchanges left in this update
}

@(private)
Peer_Secure :: struct {
    client_id:u64,
    pinned,has_token,has_old:bool,
    refused:bool, // client: an answer came that the expected server could not have sent
    ephemeral:Key,  // client, until accepted: its secret
    public:Key,     // the public key this end made for the connection
    server_key:Key, // client: the key it expects the server to hold
    shared:Key,     // client, until accepted: what its secret and server_key give
    proof:[TOKEN_BYTES+TAG_BYTES]u8, // client: the token, if any, and the tag, sealed with the proof key
    accept,send,receive,receive_old:Key,
    send_epoch,receive_epoch:u64,
}

// A key pair for a server: private goes in its Security_Desc, public to its clients.
key_generate :: proc(private,public:^Key) -> bool {
    when crypto.HAS_RAND_BYTES {
        crypto.rand_bytes(private[:])
        x25519.scalarmult_basepoint(public[:],private[:])
        return true
    } else {
        return false
    }
}

// A key pair for whoever issues tokens: public is the token_key of the servers.
token_key_generate :: proc(private,public:^Key) -> bool {
    key:ed25519.Private_Key
    if !ed25519.private_key_generate(&key) {return false}
    ed25519.private_key_bytes(&key,private[:])
    ed25519.private_key_public_bytes(&key,public[:])
    ed25519.private_key_clear(&key)
    return true
}

// Signs a token. The blob is TOKEN_FORMAT, protocol_id, client_id and expires
// in little endian, TOKEN_ADDRESSES addresses of 19 bytes (kind, port, ip)
// and the Ed25519 signature of all of that.
token_issue :: proc(token:Token,private:Key) -> (blob:[TOKEN_BYTES]u8,ok:bool) {
    token:=token
    private:=private
    key:ed25519.Private_Key
    if token.client_id==0 || !ed25519.private_key_set_bytes(&key,private[:]) {return}
    blob[0]=TOKEN_FORMAT
    endian.unchecked_put_u32le(blob[1:],token.protocol_id)
    endian.unchecked_put_u64le(blob[5:],token.client_id)
    endian.unchecked_put_u64le(blob[13:],u64(token.expires))
    for &address,i in token.addresses {
        at:=21+i*TOKEN_ADDRESS_BYTES
        blob[at]=u8(address.kind)
        endian.unchecked_put_u16le(blob[at+1:],address.port)
        copy(blob[at+3:][:16],address.ip[:])
    }
    ed25519.sign(&key,blob[:TOKEN_SIGNED_BYTES],blob[TOKEN_SIGNED_BYTES:])
    ed25519.private_key_clear(&key)
    return blob,true
}

@(private)
token_verify :: proc(s:^Host_Secure,blob:[]u8) -> (token:Token,ok:bool) {
    if blob[0]!=TOKEN_FORMAT || !ed25519.verify(&s.token_key,blob[:TOKEN_SIGNED_BYTES],blob[TOKEN_SIGNED_BYTES:]) {return}
    token.protocol_id=endian.unchecked_get_u32le(blob[1:])
    token.client_id=endian.unchecked_get_u64le(blob[5:])
    token.expires=i64(endian.unchecked_get_u64le(blob[13:]))
    for &address,i in token.addresses {
        at:=21+i*TOKEN_ADDRESS_BYTES
        if blob[at]>u8(max(Address_Kind)) {return}
        address.kind=Address_Kind(blob[at])
        address.port=endian.unchecked_get_u16le(blob[at+1:])
        copy(address.ip[:],blob[at+3:][:16])
    }
    return token,token.client_id!=0
}

@(private)
secure_host_init :: proc(h:^Host) -> bool {
    s:=&h.back.secure
    d:=&h.desc.security
    s.rekey_interval=REKEY_INTERVAL
    if d.handshakes_per_update<=0 {d.handshakes_per_update=8}
    invite:[4]u8
    endian.unchecked_put_u32le(invite[:],h.desc.invite)
    info:[len(LABEL_INVITE)+4]u8
    endian.unchecked_put_u32le(info[copy(info[:],LABEL_INVITE):],h.desc.protocol_id)
    hkdf.extract_and_expand(.SHA256,nil,invite[:],info[:],s.invite[:])
    zero:Key
    if h.desc.mode==.Server {
        s.private=d.private_key
        if s.private==zero {crypto.rand_bytes(s.private[:])}
        x25519.scalarmult_basepoint(s.public[:],s.private[:])
        if d.token_key!=zero {
            if !ed25519.public_key_set_bytes(&s.token_key,d.token_key[:]) {return false}
            s.has_token_key=true
        }
        if d.require_token && !s.has_token_key {return false}
    }
    crypto.zero_explicit(&d.private_key,KEY_BYTES)
    return true
}

// The public key of a server: what its clients may put in Credentials.server_key.
host_public_key :: proc(h:^Host) -> Key {return h.back.secure.public}

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
proof_key :: proc(h:^Host,key,shared,client_public,server_key:^Key,salt:u64,has_token:bool) {
    info:[len(LABEL_PROOF)+25+KEY_BYTES*2]u8
    at:=secure_info(h,info[:],LABEL_PROOF,salt,client_public,server_key)
    info[at]=u8(has_token)
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

// Client: makes the key of a connection attempt and keeps what it will present.
@(private)
secure_client_begin :: proc(p:^Peer,credentials:^Credentials) {
    s:=&p.secure
    s^={}
    zero:Key
    crypto.rand_bytes(s.ephemeral[:])
    x25519.scalarmult_basepoint(s.public[:],s.ephemeral[:])
    s.pinned,s.has_token=credentials.server_key!=zero,credentials.has_token
    s.server_key=credentials.server_key
    if s.has_token {copy(s.proof[:],credentials.token[:])}
}

// Client: seals what it presents for the server whose answer brought
// server_key, or for the one it pinned. False when that key leaves nothing secret.
@(private)
secure_client_prove :: proc(h:^Host,p:^Peer,server_key:^Key) -> bool {
    s:=&p.secure
    if !s.pinned {s.server_key=server_key^}
    if !secure_exchange(&s.shared,&s.ephemeral,&s.server_key) {return false}
    key:Key
    defer crypto.zero_explicit(&key,KEY_BYTES)
    proof_key(h,&key,&s.shared,&s.public,&s.server_key,p.client_salt,s.has_token)
    body:=s.proof[:s.has_token?TOKEN_BYTES:0]
    aead_seal(&key,0,s.public[:],body,s.proof[len(body):][:TAG_BYTES])
    return true
}

// Client: the keys of the connection from the server's answer. False when the answer is not from who the client expects.
@(private)
secure_client_finish :: proc(h:^Host,p:^Peer,server_public:^Key,sealed:[]u8) -> bool {
    s:=&p.secure
    exchanged:Key
    defer crypto.zero_explicit(&exchanged,KEY_BYTES)
    if !secure_exchange(&exchanged,&s.ephemeral,server_public) {return false}
    secure_session(h,s,p.client_salt,&exchanged,&s.shared,&s.public,server_public,&s.server_key)
    if !aead_open(&s.accept,0,server_public[:],sealed[:len(sealed)-TAG_BYTES],sealed[len(sealed)-TAG_BYTES:]) {return false}
    crypto.zero_explicit(&s.ephemeral,KEY_BYTES)
    crypto.zero_explicit(&s.shared,KEY_BYTES)
    return true
}

// Server: opens what a client presented, checks it and makes the keys of its
// connection. Not proven: it gets no answer. Proven: None when it may come in,
// or why not.
@(private)
secure_server_accept :: proc(h:^Host,s:^Peer_Secure,salt:u64,client_public:^Key,has_token:bool,proof:[]u8) -> (reason:Disconnect_Reason,proven:bool) {
    hs:=&h.back.secure
    d:=&h.desc.security
    s^={has_token=has_token}
    secret,exchanged,static,key:Key
    defer {
        crypto.zero_explicit(&secret,KEY_BYTES)
        crypto.zero_explicit(&exchanged,KEY_BYTES)
        crypto.zero_explicit(&static,KEY_BYTES)
        crypto.zero_explicit(&key,KEY_BYTES)
    }
    if !secure_exchange(&static,&hs.private,client_public) {return}
    proof_key(h,&key,&static,client_public,&hs.public,salt,has_token)
    body:=proof[:has_token?TOKEN_BYTES:0]
    if !aead_open(&key,0,client_public[:],body,proof[len(body):][:TAG_BYTES]) {return}
    if d.require_token && !has_token {return .Denied_Token,true}
    if has_token && hs.has_token_key {
        token,valid:=token_verify(hs,body)
        if !valid || token.protocol_id!=h.desc.protocol_id {return .Denied_Token,true}
        if token.expires<=time.to_unix_seconds(time.now()) {return .Denied_Token_Expired,true}
        declared,named:=false,false
        for own in d.addresses {
            if own.kind==.None {continue}
            declared=true
            for address in token.addresses {
                if address==own {named=true}
            }
        }
        if declared && !named {return .Denied_Token,true}
        s.client_id=token.client_id
    }
    crypto.rand_bytes(secret[:])
    x25519.scalarmult_basepoint(s.public[:],secret[:])
    if !secure_exchange(&exchanged,&secret,client_public) {return .Denied_Security,true}
    secure_session(h,s,salt,&exchanged,&static,client_public,&s.public,&hs.public)
    return .None,true
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
