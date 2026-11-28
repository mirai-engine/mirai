package kai

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:crypto/mlkem"
import "core:crypto/sha2"
import "core:crypto/x25519"

// The handshake of a Kai connection: Noise NNhfs (the KEM extension for
// hybrid forward secrecy) with X25519 and ML-KEM-768, ChaChaPoly and SHA-256,
// whose responder and initiator each prove their Ed25519 device key in the
// payload of their last message by signing the handshake hash at that point:
//
//   -> e, e1
//   <- e, ee, ekem1    payload: responder key, signature of h
//   ->                 payload: initiator key, signature of h, invite proof
//
// The session keys come from both the X25519 and the ML-KEM secret, so a
// recording of the stream stays closed unless both break. A man in the middle
// holds two handshake hashes and no signature of either side over its own; an
// invite's proof is an HMAC of h under its secret, which never travels. No I/O
// here: wire.odin frames the three messages over TCP.

NOISE_PROTOCOL :: "Noise_NNhfs_25519+MLKEM768_ChaChaPoly_SHA256"
NOISE_PROLOGUE :: "kai/3"
NOISE_TAG :: chacha20poly1305.TAG_SIZE
KEM_PUBLIC :: 1184
KEM_CIPHERTEXT :: 1088
NOISE_MSG1 :: 32+KEM_PUBLIC
NOISE_MSG2 :: 32+KEM_CIPHERTEXT+NOISE_TAG+size_of(Key)+size_of(Signature)+NOISE_TAG
NOISE_MSG3 :: size_of(Key)+size_of(Signature)+32+NOISE_TAG

@(private="file")
SIGN_LABEL :: "kai/3 handshake "

@(private)
Symmetric :: struct {
    ck,h,k:[32]u8,
    n:u64,
}

// Where a handshake is: each message is taken once and in its order, by the
// side it belongs to; a failed or out-of-order step fails it for good.
Handshake_Phase :: enum u8 {
    Start,
    Wrote_1, // the initiator waits for message 2
    Wrote_2, // the responder waits for message 3
    Done,    // handshake_split may give the session
    Failed,
}

Handshake :: struct {
    sym:Symmetric,
    phase:Handshake_Phase,
    initiator:bool,
    identity:Identity,
    e:[32]u8,  // private
    re:[32]u8, // the peer's ephemeral public key
    kem:mlkem.Decapsulation_Key,
    peer:Key,  // the peer's device key, once proven
    secret:[32]u8, // the invite's, when the initiator joins by one
    proof:[32]u8,  // what the initiator proved, for the responder to check
    proved:[32]u8, // the handshake hash its proof covers
}

// One direction of a session: ChaChaPoly under key with a counter nonce.
Cipher :: struct {
    ctx:chacha20poly1305.Context,
    n:u64,
}

handshake_init :: proc(hs:^Handshake,initiator:bool,identity:Identity) {
    hs^={initiator=initiator,identity=identity}
    #assert(len(NOISE_PROTOCOL)>32)
    hash.hash_string_to_buffer(.SHA256,NOISE_PROTOCOL,hs.sym.h[:])
    hs.sym.ck=hs.sym.h
    mix_hash(&hs.sym,transmute([]u8)string(NOISE_PROLOGUE))
}

handshake_destroy :: proc(hs:^Handshake) {
    mlkem.decapsulation_key_clear(&hs.kem)
    crypto.zero_explicit(hs,size_of(Handshake))
}

// Message 1 of the initiator into out (NOISE_MSG1 bytes).
handshake_write_1 :: proc(hs:^Handshake,out:[]u8) -> bool {
    return handshake_step(hs,hs.initiator && len(out)==NOISE_MSG1,.Start) && handshake_end(hs,write_1(hs,out),.Wrote_1)
}

// Reads message 1 and writes message 2 of the responder into out.
handshake_read_1 :: proc(hs:^Handshake,message,out:[]u8) -> bool {
    return handshake_step(hs,!hs.initiator && len(message)==NOISE_MSG1 && len(out)==NOISE_MSG2,.Start) && handshake_end(hs,read_1(hs,message,out),.Wrote_2)
}

// Reads message 2, checks the responder's proof (against expect when it is not
// zero) and writes message 3 into out.
handshake_read_2 :: proc(hs:^Handshake,message,out:[]u8,expect:Key) -> bool {
    return handshake_step(hs,hs.initiator && len(message)==NOISE_MSG2 && len(out)==NOISE_MSG3,.Wrote_1) && handshake_end(hs,read_2(hs,message,out,expect),.Done)
}

// Reads message 3: the initiator's key into hs.peer, its invite proof into
// hs.proof (zero when it joins by none).
handshake_read_3 :: proc(hs:^Handshake,message:[]u8) -> bool {
    return handshake_step(hs,!hs.initiator && len(message)==NOISE_MSG3,.Wrote_2) && handshake_end(hs,read_3(hs,message),.Done)
}

// Whether a step may run: its side and sizes hold and the handshake is where
// it comes; any other call fails the handshake.
@(private="file")
handshake_step :: proc(hs:^Handshake,valid:bool,from:Handshake_Phase) -> bool {
    if valid && hs.phase==from {return true}
    hs.phase=.Failed
    return false
}

@(private="file")
handshake_end :: proc(hs:^Handshake,ok:bool,next:Handshake_Phase) -> bool {
    hs.phase=ok?next:.Failed
    return ok
}

@(private="file")
write_1 :: proc(hs:^Handshake,out:[]u8) -> bool {
    crypto.rand_bytes(hs.e[:])
    x25519.scalarmult_basepoint(out[:32],hs.e[:])
    mix_hash(&hs.sym,out[:32])
    if !mlkem.decapsulation_key_generate(&hs.kem,.ML_KEM_768) {return false}
    mlkem.decapsulation_key_encaps_bytes(&hs.kem,out[32:])
    mix_hash(&hs.sym,out[32:]) // e1 before any key: in the clear
    mix_hash(&hs.sym,nil)      // the empty payload
    return true
}

@(private="file")
read_1 :: proc(hs:^Handshake,message,out:[]u8) -> bool {
    copy(hs.re[:],message[:32])
    mix_hash(&hs.sym,message[:32])
    mix_hash(&hs.sym,message[32:])
    mix_hash(&hs.sym,nil)
    crypto.rand_bytes(hs.e[:])
    x25519.scalarmult_basepoint(out[:32],hs.e[:])
    mix_hash(&hs.sym,out[:32])
    shared:[32]u8
    defer crypto.zero_explicit(&shared,32)
    if !dh(&shared,hs.e[:],hs.re[:]) {return false}
    mix_key(&hs.sym,shared[:])
    ss:[mlkem.SHARED_SECRET_SIZE]u8
    defer crypto.zero_explicit(&ss,len(ss))
    ct:[KEM_CIPHERTEXT]u8
    if !mlkem.encaps_ek_raw_bytes(.ML_KEM_768,message[32:],ss[:],ct[:]) {return false}
    at:=32
    encrypt_and_hash(&hs.sym,ct[:],out[at:][:KEM_CIPHERTEXT+NOISE_TAG])
    at+=KEM_CIPHERTEXT+NOISE_TAG
    mix_key(&hs.sym,ss[:])
    payload:[size_of(Key)+size_of(Signature)]u8
    proof_sign(hs,payload[:])
    encrypt_and_hash(&hs.sym,payload[:],out[at:])
    return true
}

@(private="file")
read_2 :: proc(hs:^Handshake,message,out:[]u8,expect:Key) -> bool {
    copy(hs.re[:],message[:32])
    mix_hash(&hs.sym,message[:32])
    shared:[32]u8
    defer crypto.zero_explicit(&shared,32)
    if !dh(&shared,hs.e[:],hs.re[:]) {return false}
    mix_key(&hs.sym,shared[:])
    at:=32
    ct:[KEM_CIPHERTEXT]u8
    if !decrypt_and_hash(&hs.sym,message[at:][:KEM_CIPHERTEXT+NOISE_TAG],ct[:]) {return false}
    at+=KEM_CIPHERTEXT+NOISE_TAG
    ss:[mlkem.SHARED_SECRET_SIZE]u8
    defer crypto.zero_explicit(&ss,len(ss))
    if !mlkem.decaps(&hs.kem,ct[:],ss[:]) {return false}
    mix_key(&hs.sym,ss[:])
    signed:=hs.sym.h
    payload:[size_of(Key)+size_of(Signature)]u8
    if !decrypt_and_hash(&hs.sym,message[at:],payload[:]) {return false}
    if !proof_check(hs,payload[:],signed) || (expect!={} && hs.peer!=expect) {return false}
    p:[size_of(Key)+size_of(Signature)+32]u8
    if hs.secret!={} {hmac.sum(.SHA256,p[len(p)-32:],hs.sym.h[:],hs.secret[:])}
    proof_sign(hs,p[:size_of(Key)+size_of(Signature)])
    encrypt_and_hash(&hs.sym,p[:],out)
    return true
}

@(private="file")
read_3 :: proc(hs:^Handshake,message:[]u8) -> bool {
    signed:=hs.sym.h
    p:[size_of(Key)+size_of(Signature)+32]u8
    if !decrypt_and_hash(&hs.sym,message,p[:]) {return false}
    if !proof_check(hs,p[:size_of(Key)+size_of(Signature)],signed) {return false}
    copy(hs.proof[:],p[len(p)-32:])
    hs.proved=signed
    return true
}

// Whether proof is the HMAC of the handshake hash proved (what the initiator
// sent in message 3 and the responder kept) under secret.
handshake_invited :: proc(proof,proved,secret:[32]u8) -> bool {
    p,h,k:=proof,proved,secret
    return hmac.verify(.SHA256,p[:],h[:],k[:])
}

// The two directions of the session, once the handshake is Done.
handshake_split :: proc(hs:^Handshake) -> (send,receive:Cipher,ok:bool) {
    if hs.phase!=.Done {return}
    k1,k2:[32]u8
    defer crypto.zero_explicit(&k1,32)
    defer crypto.zero_explicit(&k2,32)
    hkdf2(hs.sym.ck[:],nil,&k1,&k2)
    a,b:=&send,&receive
    if !hs.initiator {a,b=b,a}
    chacha20poly1305.init(&a.ctx,k1[:])
    chacha20poly1305.init(&b.ctx,k2[:])
    return send,receive,true
}

// Seals plain into out (len(plain)+NOISE_TAG bytes); false once the
// counter is spent, which never wraps to a nonce used before.
cipher_seal :: proc(c:^Cipher,plain,out:[]u8) -> bool {
    if c.n==max(u64) {return false}
    iv:=nonce(c.n)
    c.n+=1
    chacha20poly1305.seal(&c.ctx,out[:len(plain)],out[len(plain):][:NOISE_TAG],iv[:],nil,plain)
    return true
}

// Opens sealed into out (len(sealed)-NOISE_TAG bytes).
cipher_open :: proc(c:^Cipher,sealed,out:[]u8) -> bool {
    if len(sealed)<NOISE_TAG || c.n==max(u64) {return false}
    iv:=nonce(c.n)
    c.n+=1
    n:=len(sealed)-NOISE_TAG
    return chacha20poly1305.open(&c.ctx,out[:n],iv[:],nil,sealed[:n],sealed[n:])
}

@(private="file")
proof_sign :: proc(hs:^Handshake,out:[]u8) {
    message:[len(SIGN_LABEL)+32]u8
    copy(message[:],SIGN_LABEL)
    copy(message[len(SIGN_LABEL):],hs.sym.h[:])
    signature:=sign(&hs.identity,message[:])
    copy(out,hs.identity.key[:])
    copy(out[size_of(Key):],signature[:])
}

@(private="file")
proof_check :: proc(hs:^Handshake,payload:[]u8,signed:[32]u8) -> bool {
    message:[len(SIGN_LABEL)+32]u8
    copy(message[:],SIGN_LABEL)
    h:=signed
    copy(message[len(SIGN_LABEL):],h[:])
    key:Key
    signature:Signature
    copy(key[:],payload[:size_of(Key)])
    copy(signature[:],payload[size_of(Key):])
    if !signature_valid(key,message[:],signature) {return false}
    hs.peer=key
    return true
}

@(private="file")
dh :: proc(out:^[32]u8,private,public:[]u8) -> bool {
    x25519.scalarmult(out[:],private,public)
    return !zero(out[:]) // a low-order point
}

@(private="file")
nonce :: proc(n:u64) -> (iv:[chacha20poly1305.IV_SIZE]u8) {
    for k in 0..<8 {iv[4+k]=u8(n>>(8*uint(k)))}
    return
}

@(private="file")
mix_hash :: proc(s:^Symmetric,data:[]u8) {
    ctx:sha2.Context_256
    sha2.init_256(&ctx)
    sha2.update(&ctx,s.h[:])
    sha2.update(&ctx,data)
    sha2.final(&ctx,s.h[:])
}

@(private="file")
mix_key :: proc(s:^Symmetric,ikm:[]u8) {
    hkdf2(s.ck[:],ikm,&s.ck,&s.k)
    s.n=0
}

// Noise's HKDF with two outputs, HMAC-SHA256.
@(private="file")
hkdf2 :: proc(ck,ikm:[]u8,out1,out2:^[32]u8) {
    temp:[32]u8
    defer crypto.zero_explicit(&temp,32)
    hmac.sum(.SHA256,temp[:],ikm,ck)
    one:=[1]u8{1}
    o1:[32]u8
    hmac.sum(.SHA256,o1[:],one[:],temp[:])
    two:[33]u8
    copy(two[:],o1[:])
    two[32]=2
    hmac.sum(.SHA256,out2[:],two[:],temp[:])
    out1^=o1
}

@(private="file")
encrypt_and_hash :: proc(s:^Symmetric,plain,out:[]u8) {
    ctx:chacha20poly1305.Context
    chacha20poly1305.init(&ctx,s.k[:])
    defer chacha20poly1305.reset(&ctx)
    iv:=nonce(s.n)
    s.n+=1
    chacha20poly1305.seal(&ctx,out[:len(plain)],out[len(plain):][:NOISE_TAG],iv[:],s.h[:],plain)
    mix_hash(s,out[:len(plain)+NOISE_TAG])
}

@(private="file")
decrypt_and_hash :: proc(s:^Symmetric,sealed,out:[]u8) -> bool {
    if len(sealed)!=len(out)+NOISE_TAG {return false}
    ctx:chacha20poly1305.Context
    chacha20poly1305.init(&ctx,s.k[:])
    defer chacha20poly1305.reset(&ctx)
    iv:=nonce(s.n)
    s.n+=1
    if !chacha20poly1305.open(&ctx,out,iv[:],s.h[:],sealed[:len(out)],sealed[len(out):]) {return false}
    mix_hash(s,sealed)
    return true
}
