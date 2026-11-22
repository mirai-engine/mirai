package kai

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:mem"
import net "mirai:net"
import "mirai:std/blake3"
import "mirai:store"

// Pairing a device, a member or a node: Noise_XX_25519_ChaChaPoly_SHA256 with
// a commitment, so the eight digits both screens show cannot be ground by a
// man in the middle. The initiator I commits to its static key and nonce in
// its first message; the responder R answers with its own, and checks the
// commitment when I reveals them, before any code exists. The code hashes only
// values each side fixed before it saw the other's nonce: no label, no info
// and no transcript hash enter it, so a middle has nothing left to vary.
//
//   P1 I->R: ticket | e_I | commit        commit = BLAKE3(LABEL_PAIR_COMMIT || s_I || N_I)
//   P2 R->I: ticket | e_R | enc(s_R) | enc(N_R || R_info)
//   P3 I->R: ticket | enc(s_I) | enc(N_I || I_info)
//   code   = BLAKE3(LABEL_PAIR_CODE || e_I || e_R || s_I || s_R || N_I || N_R) mod 10^8
//   K  I->R: ticket | part | sealed(part of I's ML-KEM key), PAIR_KEM_PARTS of them
//   P4 R->I: ticket | counter | sealed(Pending | Approved | Denied, signed entries)
//
// A device's ML-KEM key does not fit P3: P3's info carries its BLAKE3, which
// the device's proof signs too, and the key follows in K frames sealed under
// the keys the handshake split. R takes the key only when the parts hash to
// what P3 said, and shows the request only then. The code covers what it
// covered before; a middle that swaps the key must swap the hash in P3,
// which only an end of the Noise session can write, and its own session's
// code differs from the other end's.
//
// R takes one request at a time; a person must approve it (nothing is the
// default), an unanswered one is denied after PAIR_TIMEOUT, and PAIR_DENIALS
// denials in a row pause pairing for PAIR_PAUSE.

PAIR_PROTOCOL :: "Noise_XX_25519_ChaChaPoly_SHA256"
LABEL_PAIR_PROLOGUE :: "kai-1/pair"
LABEL_PAIR_COMMIT :: "kai-1/pair-commit"
LABEL_PAIR_CODE :: "kai-1/pair-code"
LABEL_TICKET :: "kai-1/ticket"
PAIR_INFO_MAX :: 512
PAIR_PAYLOAD_MAX :: 32<<10 // the entries a P4 carries
PAIR_TIMEOUT :: i64(5*60)*1_000_000_000
PAIR_PAUSE :: i64(10*60)*1_000_000_000
PAIR_DENIALS :: 5
PAIR_CODE_TEXT :: 9 // dddd-dddd

@(private) PAIR_KEY :: 32
@(private) PAIR_TAG :: chacha20poly1305.TAG_SIZE
@(private) PAIR_NONCE :: 32
@(private) PAIR_HEAD :: 1+16 // type and ticket id
PAIR_KEM_PARTS :: 2
PAIR_KEM_PART :: KEM_PUBLIC/PAIR_KEM_PARTS
PAIR_K_SIZE :: PAIR_HEAD+1+PAIR_KEM_PART+PAIR_TAG
#assert(PAIR_KEM_PART*PAIR_KEM_PARTS==KEM_PUBLIC)

Pair_Message :: enum u8 {None,P1,P2,P3,P4,K}
Pair_Mode :: enum u8 {Device,Member,Node,Recover} // Recover: a machine with no user reaches the org, to fetch the user logs it recovers from
Pair_Status :: enum u8 {Pending,Approved,Denied}

Pair_Error :: enum u8 {
    None,
    Corrupt,      // not a message of this step, or it does not open
    Ticket,       // another ticket, or a responder that is not the one the ticket names
    Commitment,   // the initiator revealed a static key or nonce it did not commit to
    Weak_Key,     // a key that leaves nothing secret
    Busy,         // another request is being answered
    Paused,       // too many denials: pairing waits
    Too_Large,
    Key,          // a device's ML-KEM key that is not the one its handshake named
}

pair_error_text :: proc(error:Pair_Error) -> string {
    switch error {
    case .None: return "no error"
    case .Corrupt: return "a pairing message does not read: start pairing again"
    case .Ticket: return "the pairing ticket is not this device's: scan or paste the ticket again"
    case .Commitment: return "the other device revealed keys it had not committed to: someone may be in the middle, pair again on a network you trust"
    case .Weak_Key: return "the other device sent a key that leaves nothing secret: pair again"
    case .Busy: return "another pairing request is open: answer it first"
    case .Paused: return "too many pairing requests were denied: wait ten minutes"
    case .Too_Large: return "a pairing message is past its bound"
    case .Key: return "the device's ML-KEM key is not the one its handshake named: pair again"
    }
    return ""
}

// What a ticket hands the initiator out of band: which pairing, against which
// responder key, until when, and where the responder listens.
Ticket :: struct {
    id:[16]u8,
    responder:Dh_Key,
    mode:Pair_Mode,
    expires:i64, // ns
    addresses:[TICKET_ADDRESSES]net.Address, // IPv4 or IPv6 with a port
    address_count:int,
}

TICKET_ADDRESSES :: 4
@(private) TICKET_VERSION :: 3
@(private) TICKET_HEAD :: 1+1+16+32+8
@(private) TICKET_BYTES_MAX :: TICKET_HEAD+1+TICKET_ADDRESSES*CARRIED_ADDRESS+4
TICKET_TEXT :: (TICKET_BYTES_MAX*4+2)/3 // the longest a ticket's text is

ticket_encode :: proc(t:Ticket,buffer:^[TICKET_TEXT]u8) -> string {
    head:[TICKET_HEAD]u8
    head[0],head[1]=TICKET_VERSION,u8(t.mode)
    id,responder,addresses:=t.id,t.responder,t.addresses
    copy(head[2:],id[:])
    copy(head[18:],responder[:])
    endian.unchecked_put_u64le(head[50:],u64(t.expires))
    scratch:[TICKET_BYTES_MAX]u8
    return carried_encode(LABEL_TICKET,head[:],addresses[:clamp(t.address_count,0,TICKET_ADDRESSES)],nil,scratch[:],buffer[:])
}

ticket_decode :: proc(text:string) -> (t:Ticket,ok:bool) {
    scratch:[TICKET_BYTES_MAX]u8
    head,count,tail,read:=carried_decode(LABEL_TICKET,text,TICKET_HEAD,&t.addresses,scratch[:])
    if !read || len(tail)!=0 || head[0]!=TICKET_VERSION || head[1]>u8(max(Pair_Mode)) {return {},false}
    t.mode=Pair_Mode(head[1])
    copy(t.id[:],head[2:18])
    copy(t.responder[:],head[18:50])
    t.expires=i64(endian.unchecked_get_u64le(head[50:]))
    t.address_count=count
    return t,true
}

// A text a person carries between machines, a ticket or a grant's: head (its
// version first), how many addresses follow, the addresses, tail, and four
// bytes of the BLAKE3 keyed by label of all that, in base64url.
@(private) CARRIED_ADDRESS :: 1+2+16

@(private)
carried_encode :: proc(label:string,head:[]u8,addresses:[]net.Address,tail:[]u8,scratch,out:[]u8) -> string {
    at:=copy(scratch,head)
    count:=at
    scratch[count]=0
    at+=1
    for a in addresses[:min(len(addresses),TICKET_ADDRESSES)] {
        if a.kind!=.IP4 && a.kind!=.IP6 {continue}
        scratch[at]=u8(a.kind)
        endian.unchecked_put_u16le(scratch[at+1:],a.port)
        ip:=a.ip
        copy(scratch[at+3:],ip[:])
        at+=CARRIED_ADDRESS
        scratch[count]+=1
    }
    at+=copy(scratch[at:],tail)
    sum:=keyed_hash(transmute([]u8)label,scratch[:at])
    at+=copy(scratch[at:],sum[:4])
    text,_:=base64.encode_into_buf(out,scratch[:at],base64.ENC_URL_TABLE,{.No_Padding})
    return string(text)
}

// The head, addresses and tail of a carried text whose head is head_size
// bytes, in scratch; false when it does not read or its sum differs.
@(private)
carried_decode :: proc(label,text:string,head_size:int,addresses:^[TICKET_ADDRESSES]net.Address,scratch:[]u8) -> (head:[]u8,count:int,tail:[]u8,ok:bool) {
    if len(text)>(len(scratch)*4+2)/3 {return}
    bytes,e:=base64.decode_into_buf(scratch,text,base64.DEC_URL_TABLE,{.Strict,.No_Padding})
    if e!=nil || len(bytes)<head_size+1+4 {return}
    sum:=keyed_hash(transmute([]u8)label,bytes[:len(bytes)-4])
    if !bytes_equal(sum[:4],bytes[len(bytes)-4:]) {return}
    count=int(bytes[head_size])
    at:=head_size+1
    if count>TICKET_ADDRESSES || len(bytes)-4<at+count*CARRIED_ADDRESS {return}
    for k in 0..<count {
        kind:=net.Address_Kind(bytes[at])
        if kind!=.IP4 && kind!=.IP6 {return}
        addresses[k]={kind=kind,port=endian.unchecked_get_u16le(bytes[at+1:])}
        copy(addresses[k].ip[:],bytes[at+3:at+CARRIED_ADDRESS])
        at+=CARRIED_ADDRESS
    }
    return bytes[:head_size],count,bytes[at:len(bytes)-4],true
}

// One end of a pairing handshake.
Pair :: struct {
    initiator:bool,
    step:Pair_Message, // the last message written or read
    ticket:[16]u8,
    expect:Dh_Key,     // initiator: the responder key of the ticket
    noise:net.Noise,
    s:net.Dh_Key,      // this end's static key
    e:net.Dh_Key,      // its ephemeral
    re,rs:[PAIR_KEY]u8,
    nonce,remote_nonce:[PAIR_NONCE]u8,
    commit:[32]u8,     // the initiator's
    info:[PAIR_INFO_MAX]u8, // what the other end said of itself
    info_len:int,
    send,receive:[PAIR_KEY]u8, // after the handshake
    sent,received:u64,
    code:[PAIR_CODE_TEXT]u8,
    kem:[KEM_PUBLIC]u8, // responder: the initiator's ML-KEM key, as its K parts came
    kem_parts:u8,       // the parts that came, a bit each
}

// Starts one end. seed, when given, makes the ephemeral key and the nonce
// from its 64 bytes instead of from the system: for tests.
pair_init :: proc(p:^Pair,initiator:bool,s:net.Dh_Key,ticket_id:[16]u8,expect:Dh_Key={},seed:^[64]u8=nil) {
    ticket:=ticket_id
    p^={initiator=initiator,ticket=ticket,expect=expect,s=s}
    private:net.Key
    if seed!=nil {
        copy(private[:],seed[:32])
        copy(p.nonce[:],seed[32:])
    } else {
        crypto.rand_bytes(private[:])
        crypto.rand_bytes(p.nonce[:])
    }
    p.e=net.dh_key_from(&private)
    crypto.zero_explicit(&private,size_of(private))
    prologue:[len(LABEL_PAIR_PROLOGUE)+16]u8
    copy(prologue[:],LABEL_PAIR_PROLOGUE)
    copy(prologue[len(LABEL_PAIR_PROLOGUE):],ticket[:])
    net.noise_init(&p.noise,PAIR_PROTOCOL,prologue[:])
}

// Wipes the keys of p.
pair_end :: proc(p:^Pair) {crypto.zero_explicit(p,size_of(Pair))}

// The other end's info, once the handshake gave it.
pair_info :: proc(p:^Pair) -> []u8 {return p.info[:p.info_len]}

// The other end's static key.
pair_remote :: proc(p:^Pair) -> Dh_Key {return Dh_Key(p.rs)}

// The code both screens show, once P3 was read or written.
pair_code :: proc(p:^Pair) -> string {
    if p.step<.P3 {return ""}
    return string(p.code[:])
}

// The commitment of a static key and a nonce.
pair_commitment :: proc(s:[32]u8,nonce:[PAIR_NONCE]u8) -> [32]u8 {
    h:blake3.Hasher
    blake3.init(&h)
    a,b:=s,nonce
    blake3.update(&h,transmute([]u8)string(LABEL_PAIR_COMMIT))
    blake3.update(&h,a[:])
    blake3.update(&h,b[:])
    return blake3.final(&h)
}

// The eight digits of a pairing, from the values each side fixed before it saw the other's nonce.
pair_code_of :: proc(e_i,e_r,s_i,s_r:[32]u8,n_i,n_r:[PAIR_NONCE]u8) -> (code:[PAIR_CODE_TEXT]u8) {
    h:blake3.Hasher
    blake3.init(&h)
    blake3.update(&h,transmute([]u8)string(LABEL_PAIR_CODE))
    parts:=[6][32]u8{e_i,e_r,s_i,s_r,n_i,n_r}
    for &part in parts {blake3.update(&h,part[:])}
    sum:=blake3.final(&h)
    value:=endian.unchecked_get_u64le(sum[:])%100_000_000
    for k:=PAIR_CODE_TEXT-1;k>=0;k-=1 {
        if k==4 {
            code[k]='-'
            continue
        }
        code[k]=u8('0'+value%10)
        value/=10
    }
    return
}

@(private)
pair_mix_hash :: proc(p:^Pair,data:[]u8) {net.noise_mix_hash(&p.noise,data)}

@(private)
pair_mix_key :: proc(p:^Pair,scalar,point:^net.Key) -> bool {
    shared:net.Key
    defer crypto.zero_explicit(&shared,size_of(shared))
    if !net.secure_exchange(&shared,scalar,point) {return false}
    net.noise_mix_key(&p.noise,shared[:])
    return true
}

// Seals plain into out, which takes PAIR_TAG more bytes.
@(private)
pair_encrypt :: proc(p:^Pair,plain,out:[]u8) {
    copy(out,plain)
    net.noise_encrypt(&p.noise,out[:len(plain)],out[len(plain):][:PAIR_TAG])
}

@(private)
pair_decrypt :: proc(p:^Pair,sealed,out:[]u8) -> bool {
    if len(sealed)<PAIR_TAG || len(out)<len(sealed)-PAIR_TAG {return false}
    size:=len(sealed)-PAIR_TAG
    copy(out[:size],sealed[:size])
    return net.noise_decrypt(&p.noise,out[:size],sealed[size:])
}

@(private)
pair_split :: proc(p:^Pair) {
    if p.initiator {
        net.noise_split(&p.noise,&p.send,&p.receive)
    } else {
        net.noise_split(&p.noise,&p.receive,&p.send)
    }
}

@(private)
pair_head :: proc(p:^Pair,out:[]u8,type:Pair_Message) {
    out[0]=u8(type)
    copy(out[1:],p.ticket[:])
}

@(private)
pair_head_valid :: proc(p:^Pair,message:[]u8,type:Pair_Message) -> Pair_Error {
    if len(message)<PAIR_HEAD || message[0]!=u8(type) {return .Corrupt}
    if !bytes_equal(message[1:PAIR_HEAD],p.ticket[:]) {return .Ticket}
    if p.step!=Pair_Message(u8(type)-1) {return .Corrupt}
    return .None
}

// The size of each message with info of size n.
pair_p1_size :: proc "contextless" () -> int {return PAIR_HEAD+2*PAIR_KEY}
pair_p2_size :: proc "contextless" (n:int) -> int {return PAIR_HEAD+PAIR_KEY+PAIR_KEY+PAIR_TAG+PAIR_NONCE+n+PAIR_TAG}
pair_p3_size :: proc "contextless" (n:int) -> int {return PAIR_HEAD+PAIR_KEY+PAIR_TAG+PAIR_NONCE+n+PAIR_TAG}

// Initiator: P1, -> e with the commitment as its payload.
pair_write_p1 :: proc(p:^Pair,out:[]u8) -> (message:[]u8,error:Pair_Error) {
    if !p.initiator || p.step!=.None {return nil,.Corrupt}
    if len(out)<pair_p1_size() {return nil,.Too_Large}
    pair_head(p,out,.P1)
    copy(out[PAIR_HEAD:],p.e.public[:])
    pair_mix_hash(p,p.e.public[:])
    p.commit=pair_commitment(p.s.public,p.nonce)
    copy(out[PAIR_HEAD+PAIR_KEY:],p.commit[:])
    pair_mix_hash(p,p.commit[:])
    p.step=.P1
    return out[:pair_p1_size()],.None
}

// Responder: reads P1.
pair_read_p1 :: proc(p:^Pair,message:[]u8) -> Pair_Error {
    if p.initiator {return .Corrupt}
    pair_head_valid(p,message,.P1) or_return
    if len(message)!=pair_p1_size() {return .Corrupt}
    copy(p.re[:],message[PAIR_HEAD:][:PAIR_KEY])
    pair_mix_hash(p,p.re[:])
    copy(p.commit[:],message[PAIR_HEAD+PAIR_KEY:][:32])
    pair_mix_hash(p,p.commit[:])
    p.step=.P1
    return .None
}

// Responder: P2, <- e, ee, s, es with its nonce and info as the payload.
pair_write_p2 :: proc(p:^Pair,info:[]u8,out:[]u8) -> (message:[]u8,error:Pair_Error) {
    if p.initiator || p.step!=.P1 {return nil,.Corrupt}
    if len(info)>PAIR_INFO_MAX {return nil,.Too_Large}
    size:=pair_p2_size(len(info))
    if len(out)<size {return nil,.Too_Large}
    pair_head(p,out,.P2)
    at:=PAIR_HEAD
    copy(out[at:],p.e.public[:])
    pair_mix_hash(p,p.e.public[:])
    at+=PAIR_KEY
    if !pair_mix_key(p,&p.e.private,&p.re) {return nil,.Weak_Key}
    pair_encrypt(p,p.s.public[:],out[at:])
    at+=PAIR_KEY+PAIR_TAG
    if !pair_mix_key(p,&p.s.private,&p.re) {return nil,.Weak_Key}
    plain:[PAIR_NONCE+PAIR_INFO_MAX]u8
    copy(plain[:],p.nonce[:])
    copy(plain[PAIR_NONCE:],info)
    pair_encrypt(p,plain[:PAIR_NONCE+len(info)],out[at:])
    p.step=.P2
    return out[:size],.None
}

// Initiator: reads P2; the responder's key must be the ticket's.
pair_read_p2 :: proc(p:^Pair,message:[]u8) -> Pair_Error {
    if !p.initiator {return .Corrupt}
    pair_head_valid(p,message,.P2) or_return
    if len(message)<pair_p2_size(0) || len(message)>pair_p2_size(PAIR_INFO_MAX) {return .Corrupt}
    at:=PAIR_HEAD
    copy(p.re[:],message[at:][:PAIR_KEY])
    pair_mix_hash(p,p.re[:])
    at+=PAIR_KEY
    if !pair_mix_key(p,&p.e.private,&p.re) {return .Weak_Key}
    if !pair_decrypt(p,message[at:][:PAIR_KEY+PAIR_TAG],p.rs[:]) {return .Corrupt}
    at+=PAIR_KEY+PAIR_TAG
    if p.expect!={} && Dh_Key(p.rs)!=p.expect {return .Ticket}
    if !pair_mix_key(p,&p.e.private,&p.rs) {return .Weak_Key}
    plain:[PAIR_NONCE+PAIR_INFO_MAX]u8
    sealed:=message[at:]
    if !pair_decrypt(p,sealed,plain[:]) {return .Corrupt}
    copy(p.remote_nonce[:],plain[:PAIR_NONCE])
    p.info_len=copy(p.info[:],plain[PAIR_NONCE:len(sealed)-PAIR_TAG])
    p.step=.P2
    return .None
}

// Initiator: P3, -> s, se revealing what it committed to; the code is fixed.
pair_write_p3 :: proc(p:^Pair,info:[]u8,out:[]u8) -> (message:[]u8,error:Pair_Error) {
    if !p.initiator || p.step!=.P2 {return nil,.Corrupt}
    if len(info)>PAIR_INFO_MAX {return nil,.Too_Large}
    size:=pair_p3_size(len(info))
    if len(out)<size {return nil,.Too_Large}
    pair_head(p,out,.P3)
    at:=PAIR_HEAD
    pair_encrypt(p,p.s.public[:],out[at:])
    at+=PAIR_KEY+PAIR_TAG
    if !pair_mix_key(p,&p.s.private,&p.re) {return nil,.Weak_Key}
    plain:[PAIR_NONCE+PAIR_INFO_MAX]u8
    copy(plain[:],p.nonce[:])
    copy(plain[PAIR_NONCE:],info)
    pair_encrypt(p,plain[:PAIR_NONCE+len(info)],out[at:])
    pair_split(p)
    p.code=pair_code_of(p.e.public,p.re,p.s.public,p.rs,p.nonce,p.remote_nonce)
    p.step=.P3
    return out[:size],.None
}

// Responder: reads P3, and checks the commitment before there is a code.
pair_read_p3 :: proc(p:^Pair,message:[]u8) -> Pair_Error {
    if p.initiator {return .Corrupt}
    pair_head_valid(p,message,.P3) or_return
    if len(message)<pair_p3_size(0) || len(message)>pair_p3_size(PAIR_INFO_MAX) {return .Corrupt}
    at:=PAIR_HEAD
    if !pair_decrypt(p,message[at:][:PAIR_KEY+PAIR_TAG],p.rs[:]) {return .Corrupt}
    at+=PAIR_KEY+PAIR_TAG
    if !pair_mix_key(p,&p.e.private,&p.rs) {return .Weak_Key}
    plain:[PAIR_NONCE+PAIR_INFO_MAX]u8
    sealed:=message[at:]
    if !pair_decrypt(p,sealed,plain[:]) {return .Corrupt}
    copy(p.remote_nonce[:],plain[:PAIR_NONCE])
    if pair_commitment(p.rs,p.remote_nonce)!=p.commit {
        pair_end(p)
        return .Commitment
    }
    p.info_len=copy(p.info[:],plain[PAIR_NONCE:len(sealed)-PAIR_TAG])
    pair_split(p)
    p.code=pair_code_of(p.re,p.e.public,p.rs,p.s.public,p.remote_nonce,p.nonce)
    p.step=.P3
    return .None
}

// Responder: P4, the answer and what it carries (signed entries), sealed.
// Pending may be sent before the final answer.
pair_write_p4 :: proc(p:^Pair,status:Pair_Status,payload:[]u8,out:[]u8) -> (message:[]u8,error:Pair_Error) {
    if p.initiator || p.step!=.P3 {return nil,.Corrupt}
    if len(payload)>PAIR_PAYLOAD_MAX {return nil,.Too_Large}
    size:=PAIR_HEAD+8+1+len(payload)+PAIR_TAG
    if len(out)<size {return nil,.Too_Large}
    pair_head(p,out,.P4)
    endian.unchecked_put_u64le(out[PAIR_HEAD:],p.sent)
    out[PAIR_HEAD+8]=u8(status)
    copy(out[PAIR_HEAD+9:],payload)
    body:=out[PAIR_HEAD+8:][:1+len(payload)]
    ctx:chacha20poly1305.Context
    iv:=net.noise_iv(p.sent)
    chacha20poly1305.init(&ctx,p.send[:])
    chacha20poly1305.seal(&ctx,body,out[PAIR_HEAD+9+len(payload):][:PAIR_TAG],iv[:],out[:PAIR_HEAD+8],body)
    chacha20poly1305.reset(&ctx)
    p.sent+=1
    return out[:size],.None
}

// Initiator: opens a P4 in place; payload points into message.
pair_read_p4 :: proc(p:^Pair,message:[]u8) -> (status:Pair_Status,payload:[]u8,error:Pair_Error) {
    if !p.initiator || p.step!=.P3 {return {},nil,.Corrupt}
    if len(message)<PAIR_HEAD+8+1+PAIR_TAG || message[0]!=u8(Pair_Message.P4) {return {},nil,.Corrupt}
    if !bytes_equal(message[1:PAIR_HEAD],p.ticket[:]) {return {},nil,.Ticket}
    // A P4 lost on the way is skipped: only one older than the last taken is a replay.
    counter:=endian.unchecked_get_u64le(message[PAIR_HEAD:])
    if counter<p.received {return {},nil,.Corrupt}
    size:=len(message)-PAIR_HEAD-8-PAIR_TAG
    body:=message[PAIR_HEAD+8:][:size]
    ctx:chacha20poly1305.Context
    iv:=net.noise_iv(counter)
    chacha20poly1305.init(&ctx,p.receive[:])
    ok:=chacha20poly1305.open(&ctx,body,iv[:],message[:PAIR_HEAD+8],body,message[len(message)-PAIR_TAG:])
    chacha20poly1305.reset(&ctx)
    if !ok || body[0]>u8(max(Pair_Status)) {return {},nil,.Corrupt}
    p.received=counter+1
    return Pair_Status(body[0]),body[1:],.None
}

// Initiator: K part of its ML-KEM key kem, sealed under the handshake's keys.
pair_write_key :: proc(p:^Pair,kem:^[KEM_PUBLIC]u8,part:int,out:[]u8) -> (message:[]u8,error:Pair_Error) {
    if !p.initiator || p.step<.P3 || part<0 || part>=PAIR_KEM_PARTS {return nil,.Corrupt}
    if len(out)<PAIR_K_SIZE {return nil,.Too_Large}
    pair_head(p,out,.K)
    out[PAIR_HEAD]=u8(part)
    body:=out[PAIR_HEAD+1:][:PAIR_KEM_PART]
    copy(body,kem[part*PAIR_KEM_PART:][:PAIR_KEM_PART])
    ctx:chacha20poly1305.Context
    iv:=net.noise_iv(u64(part))
    chacha20poly1305.init(&ctx,p.send[:])
    chacha20poly1305.seal(&ctx,body,out[PAIR_HEAD+1+PAIR_KEM_PART:][:PAIR_TAG],iv[:],out[:PAIR_HEAD+1],body)
    chacha20poly1305.reset(&ctx)
    return out[:PAIR_K_SIZE],.None
}

// Responder: takes a K part; complete is true once every part came and they
// hash to kem_hash, what P3's info said; Key when they hash to another.
pair_read_key :: proc(p:^Pair,message:[]u8,kem_hash:[32]u8) -> (complete:bool,error:Pair_Error) {
    if p.initiator || p.step!=.P3 {return false,.Corrupt}
    if len(message)!=PAIR_K_SIZE || message[0]!=u8(Pair_Message.K) {return false,.Corrupt}
    if !bytes_equal(message[1:PAIR_HEAD],p.ticket[:]) {return false,.Ticket}
    part:=int(message[PAIR_HEAD])
    if part>=PAIR_KEM_PARTS {return false,.Corrupt}
    if p.kem_parts&(1<<uint(part))==0 {
        sealed:[PAIR_KEM_PART]u8
        copy(sealed[:],message[PAIR_HEAD+1:][:PAIR_KEM_PART])
        ctx:chacha20poly1305.Context
        iv:=net.noise_iv(u64(part))
        chacha20poly1305.init(&ctx,p.receive[:])
        ok:=chacha20poly1305.open(&ctx,p.kem[part*PAIR_KEM_PART:][:PAIR_KEM_PART],iv[:],message[:PAIR_HEAD+1],sealed[:],message[PAIR_HEAD+1+PAIR_KEM_PART:][:PAIR_TAG])
        chacha20poly1305.reset(&ctx)
        if !ok {return false,.Corrupt}
        p.kem_parts|=1<<uint(part)
    }
    if p.kem_parts!=(1<<PAIR_KEM_PARTS)-1 {return false,.None}
    if blake3.hash(p.kem[:])!=kem_hash {return false,.Key}
    return true,.None
}

// What each end says of itself in its payload: the mode, the log it speaks
// for (R: the user log a device joins or the org; I: its own user log when it
// joins as a member), its signing key and, for a device, the BLAKE3 of its
// ML-KEM key, which K frames carry, and the proof it holds its keys over the
// user log it joins. A name follows.
Pair_Info :: struct #packed {
    mode:Pair_Mode,
    log_id:Log_Id,
    device:Key,
    kem:[32]u8,
    proof:Signature,
}

pair_info_encode :: proc(info:Pair_Info,name:string,buffer:^[PAIR_INFO_MAX]u8) -> []u8 {
    i:=info
    copy(buffer[:],mem.ptr_to_bytes(&i))
    n:=copy(buffer[size_of(Pair_Info):],name[:min(len(name),NAME_MAX)])
    return buffer[:size_of(Pair_Info)+n]
}

pair_info_decode :: proc(bytes:[]u8) -> (info:Pair_Info,name:string,ok:bool) {
    tail:[]u8
    read:bool
    info,tail,read=body_head(bytes,Pair_Info)
    if !read || info.mode>max(Pair_Mode) || !name_valid(string(tail),true) {return {},"",false}
    return info,string(tail),true
}

// The responder's gate: one request at a time, a deadline, and a pause after
// denials in a row.
Pair_Gate :: struct {
    active:bool,
    ticket:[16]u8,
    started:i64,
    denials:int,
    paused_until:i64,
}

pair_gate_open :: proc(g:^Pair_Gate,ticket:[16]u8,now:i64) -> Pair_Error {
    pair_gate_expire(g,now)
    if now<g.paused_until {return .Paused}
    if g.active {return .Busy}
    g.active,g.ticket,g.started=true,ticket,now
    return .None
}

// Closes the open request with the person's answer: approved, or denied.
pair_gate_close :: proc(g:^Pair_Gate,approved:bool,now:i64) {
    if !g.active {return}
    g.active=false
    if approved {
        g.denials=0
        return
    }
    g.denials+=1
    if g.denials>=PAIR_DENIALS {
        g.denials=0
        g.paused_until=now+PAIR_PAUSE
    }
}

// Denies the open request when it waited past PAIR_TIMEOUT: true then.
pair_gate_expire :: proc(g:^Pair_Gate,now:i64) -> bool {
    if !g.active || now-g.started<PAIR_TIMEOUT {return false}
    pair_gate_close(g,false,now)
    return true
}

// The entry that links the device the pairing p met to the user's log, with
// the ML-KEM key its K frames carried, signed by approver, an active device
// or the recovery key of the user.
pair_approve_device :: proc(p:^Pair,user:^Log,approver:^Identity,time:i64) -> (address:store.Hash,error:Error) {
    info,name,ok:=pair_info_decode(pair_info(p))
    if !ok || info.mode!=.Device || p.step!=.P3 || user.kind!=.User {return {},.Invalid_Argument}
    if p.kem_parts!=(1<<PAIR_KEM_PARTS)-1 || blake3.hash(p.kem[:])!=info.kem {return {},.Invalid_Argument}
    body:=body_make(Device_Add_Body{device=info.device,dh=pair_remote(p),kem=p.kem,proof=info.proof},transmute([]u8)name)
    return log_append(user,.Device_Add,body,approver,time)
}

@(private)
bytes_equal :: proc "contextless" (a,b:[]u8) -> bool {
    if len(a)!=len(b) {return false}
    for x,i in a {
        if x!=b[i] {return false}
    }
    return true
}
