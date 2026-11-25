package tls

import "core:crypto/aead"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/hmac"
import "core:encoding/endian"

@(private)
Content :: enum u8 {Change_Cipher_Spec=20,Alert=21,Handshake=22,Application_Data=23}

// Records one key seals before the writer moves to the next (KeyUpdate): far below the limit
// of AES-GCM (RFC 8446, 5.5).
@(private) KEY_UPDATE_RECORDS :: 1<<24
// Records a key may protect, in either direction: 2^24.5 for AES-GCM (RFC 8446, 5.5), and
// short of the wrap of the sequence number for ChaCha20-Poly1305.
@(private) RECORDS_PER_KEY :: [Suite]u64{.AES_128_GCM_SHA256=23_726_566,.AES_256_GCM_SHA384=23_726_566,.CHACHA20_POLY1305_SHA256=max(u64)-1}
@(private) records_per_key :: proc(s:Suite) -> u64 {t:=RECORDS_PER_KEY;return t[s]}
// Records in a row without application data a connection takes from its peer.
@(private) IDLE_RECORDS_MAX :: 32

@(private) SUITE_CODE :: [Suite]u16{.AES_128_GCM_SHA256=0x1301,.AES_256_GCM_SHA384=0x1302,.CHACHA20_POLY1305_SHA256=0x1303}
@(private) SUITE_HASH :: [Suite]hash.Algorithm{.AES_128_GCM_SHA256=.SHA256,.AES_256_GCM_SHA384=.SHA384,.CHACHA20_POLY1305_SHA256=.SHA256}
@(private) SUITE_AEAD :: [Suite]aead.Algorithm{.AES_128_GCM_SHA256=.AES_GCM_128,.AES_256_GCM_SHA384=.AES_GCM_256,.CHACHA20_POLY1305_SHA256=.CHACHA20POLY1305}
@(private) suite_code :: proc(s:Suite) -> int {t:=SUITE_CODE;return int(t[s])}
@(private) suite_hash :: proc(s:Suite) -> hash.Algorithm {t:=SUITE_HASH;return t[s]}
@(private) suite_aead :: proc(s:Suite) -> aead.Algorithm {t:=SUITE_AEAD;return t[s]}
@(private) ALL_SUITES :: Suites{.AES_128_GCM_SHA256,.AES_256_GCM_SHA384,.CHACHA20_POLY1305_SHA256}
@(private) ALL_GROUPS :: Groups{.X25519,.P256}

@(private)
record_length :: proc(c:^Conn) -> int {return int(c.input[3])<<8|int(c.input[4])}

@(private)
record_header_check :: proc(c:^Conn) -> Error {
    content:=c.input[0]
    if content<u8(Content.Change_Cipher_Spec) || content>u8(Content.Application_Data) || c.input[1]!=3 {
        return .Unexpected_Message if content>=20 && content<=23 else .Decode
    }
    limit:=CIPHERTEXT_MAX if Content(content)==.Application_Data else PLAINTEXT_MAX
    if record_length(c)>limit {return .Record_Overflow}
    return nil
}

// Takes the whole record in input.
@(private)
record_receive :: proc(c:^Conn) -> Error {
    n:=record_length(c)
    body:=c.input[HEADER_BYTES:][:n]
    #partial switch Content(c.input[0]) {
    case .Change_Cipher_Spec:
        // The compatibility record of RFC 8446, D.4 and 5: once, unprotected, after the first
        // ClientHello and before the peer's Finished.
        first_hello:=c.role==.Server && c.state==.Wait_Client_Hello && !c.retried
        if c.state>=.Connected || first_hello || c.change_cipher_spec || n!=1 || body[0]!=1 {return .Unexpected_Message}
        c.change_cipher_spec=true
        return nil
    case .Application_Data:
        // Protected or skipped as early data, a record holds at least its tag (RFC 8446, 5.2).
        if n==0 {return .Bad_Record_Mac}
        if !c.read.active {
            // Early data of a client that offered it, before the server reads under keys.
            if c.early_skip<n {return .Unexpected_Message}
            c.early_skip-=n
            return nil
        }
        if c.read.seq>=records_per_key(c.suite) {return .Unexpected_Message}
        inner,ok:=record_open(&c.read,c.input[:HEADER_BYTES],body)
        if !ok {
            if c.early_skip<n {return .Bad_Record_Mac}
            c.early_skip-=n
            return nil
        }
        c.early_skip=0
        end:=len(inner)
        for end>0 && inner[end-1]==0 {end-=1}
        if end==0 {return .Unexpected_Message}
        if end-1>PLAINTEXT_MAX {return .Record_Overflow}
        return record_content(c,Content(inner[end-1]),HEADER_BYTES,end-1)
    }
    if c.read.active {return .Unexpected_Message}
    return record_content(c,Content(c.input[0]),HEADER_BYTES,n)
}

// The content of a record, at input[at:][:n].
@(private)
record_content :: proc(c:^Conn,content:Content,at,n:int) -> Error {
    data:=c.input[at:][:n]
    #partial switch content {
    case .Alert:
        if n!=2 {return .Decode}
        if c.handshake_len>0 {return .Unexpected_Message}
        alert:=Alert(data[1])
        if alert==.User_Canceled {return idle_record(c)}
        if alert==.Close_Notify {
            c.peer_closed=true
            return nil if c.state==.Connected else .Closed
        }
        c.alert=alert
        return .Alert_Received
    case .Handshake:
        if n==0 {return .Unexpected_Message}
        if c.handshake_len+n>len(c.handshake) {return .Illegal_Parameter}
        copy(c.handshake[c.handshake_len:],data)
        c.handshake_len+=n
        return handshake_process(c)
    case .Application_Data:
        if c.state!=.Connected || c.handshake_len>0 {return .Unexpected_Message}
        if n==0 {return idle_record(c)}
        c.idle_records=0
        c.plain_at,c.plain_len=at,n
        return nil
    }
    return .Unexpected_Message
}

// Counts a record that carried no application data: past IDLE_RECORDS_MAX in a row the peer
// only spends this side's time.
@(private)
idle_record :: proc(c:^Conn) -> Error {
    c.idle_records+=1
    return .Unexpected_Message if c.idle_records>IDLE_RECORDS_MAX else nil
}

// Takes the whole handshake messages of the handshake buffer, in order.
@(private)
handshake_process :: proc(c:^Conn) -> Error {
    for c.handshake_len>=4 {
        size:=4+(int(c.handshake[1])<<16|int(c.handshake[2])<<8|int(c.handshake[3]))
        if size>len(c.handshake) {return .Illegal_Parameter}
        if c.handshake_len<size {break}
        keys:=c.read.epoch
        err:=c.role==.Server ? server_message(c,c.handshake[:size]) : client_message(c,c.handshake[:size])
        copy(c.handshake,c.handshake[size:c.handshake_len])
        c.handshake_len-=size
        if err!=nil {return err}
        // A message before new keys ends its record (RFC 8446, 5.1).
        if keys!=c.read.epoch && c.handshake_len>0 {return .Unexpected_Message}
        if c.state==.Failed {return c.error}
    }
    return nil
}

@(private)
output_room :: proc(c:^Conn) -> int {
    if c.output_at>0 {
        copy(c.output,c.output[c.output_at:c.output_len])
        c.output_len-=c.output_at
        c.output_at=0
    }
    return len(c.output)-c.output_len
}

// One record of payload, sealed once this side writes under keys.
@(private)
record_seal :: proc(c:^Conn,content:Content,payload:[]u8) -> Error {
    sealed:=c.write.active
    size:=len(payload)+(1+TAG_BYTES if sealed else 0)
    if output_room(c)<HEADER_BYTES+size {return .Internal}
    out:=c.output[c.output_len:][:HEADER_BYTES+size]
    out[0]=u8(Content.Application_Data) if sealed else u8(content)
    // The first ClientHello carries 0x0301 for old middleboxes (RFC 8446, 5.1).
    out[1],out[2]=3,1 if c.state==.Wait_Server_Hello && !c.retried && !sealed else 3
    endian.unchecked_put_u16be(out[3:],u16(size))
    copy(out[HEADER_BYTES:],payload)
    if sealed && c.write.seq>=records_per_key(c.suite) {return .Internal}
    if sealed {
        out[HEADER_BYTES+len(payload)]=u8(content)
        inner:=out[HEADER_BYTES:][:len(payload)+1]
        nonce:=record_nonce(&c.write)
        aead.seal_ctx(&c.write.aead,inner,out[HEADER_BYTES+len(inner):][:TAG_BYTES],nonce[:],out[:HEADER_BYTES],inner)
        c.write.seq+=1
    }
    c.output_len+=HEADER_BYTES+size
    return nil
}

@(private)
record_open :: proc(d:^Direction,header,body:[]u8) -> (inner:[]u8,ok:bool) {
    if len(body)<TAG_BYTES+1 {return nil,false}
    inner=body[:len(body)-TAG_BYTES]
    nonce:=record_nonce(d)
    if !aead.open_ctx(&d.aead,inner,nonce[:],header,inner,body[len(inner):]) {return nil,false}
    d.seq+=1
    return inner,true
}

@(private)
record_nonce :: proc(d:^Direction) -> (nonce:[IV_BYTES]u8) {
    nonce=d.iv
    seq:[8]u8
    endian.unchecked_put_u64be(seq[:],d.seq)
    for i in 0..<8 {nonce[IV_BYTES-8+i]~=seq[i]}
    return
}

// Queues an alert; one the output has no room for is dropped.
@(private)
alert_send :: proc(c:^Conn,alert:Alert) {
    level:u8=1 if alert==.Close_Notify || alert==.User_Canceled else 2
    _=record_seal(c,.Alert,{level,u8(alert)})
}

// A handshake message to the peer: in the transcript, then in records.
@(private)
handshake_send :: proc(c:^Conn,message:[]u8) -> Error {
    transcript_add(c,message)
    for at:=0;at<len(message);at+=PLAINTEXT_MAX {
        record_seal(c,.Handshake,message[at:][:min(PLAINTEXT_MAX,len(message)-at)]) or_return
    }
    return nil
}

@(private)
key_update_send :: proc(c:^Conn,request:bool) -> bool {
    if output_room(c)<HEADER_BYTES+5+1+TAG_BYTES {return false}
    if record_seal(c,.Handshake,{24,0,0,1,1 if request else 0})!=nil {return false}
    direction_advance(&c.write,c.suite)
    return true
}

@(private)
key_update_flush :: proc(c:^Conn) -> bool {
    if c.owe_key_update && key_update_send(c,false) {c.owe_key_update=false}
    return !c.owe_key_update
}

// KeyUpdate from the peer, after the handshake.
@(private)
key_update_receive :: proc(c:^Conn,body:[]u8) -> Error {
    if len(body)!=1 {return .Decode}
    if body[0]>1 {return .Illegal_Parameter}
    idle_record(c) or_return
    direction_advance(&c.read,c.suite)
    if body[0]==1 && !c.close_sent {
        c.owe_key_update=true
        _=key_update_flush(c)
    }
    return nil
}

// HKDF-Expand-Label (RFC 8446, 7.1).
@(private)
expand_label :: proc(h:hash.Algorithm,secret:[]u8,label:string,ctx:[]u8,dst:[]u8) {
    info:[2+1+255+1+HASH_MAX]u8
    full:=len("tls13 ")+len(label)
    endian.unchecked_put_u16be(info[:],u16(len(dst)))
    info[2]=u8(full)
    copy(info[3:],"tls13 ")
    copy(info[3+len("tls13 "):],label)
    info[3+full]=u8(len(ctx))
    copy(info[4+full:],ctx)
    hkdf.expand(h,secret,info[:4+full+len(ctx)],dst)
}

@(private)
derive_secret :: proc(h:hash.Algorithm,secret:[]u8,label:string,transcript:[]u8,dst:[]u8) {
    expand_label(h,secret,label,transcript,dst[:hash.DIGEST_SIZES[h]])
}

// The keys of a direction from a traffic secret.
@(private)
direction_set :: proc(d:^Direction,suite:Suite,secret:[]u8) {
    h:=suite_hash(suite)
    algorithm:=suite_aead(suite)
    key:[32]u8
    copy(d.secret[:],secret[:hash.DIGEST_SIZES[h]])
    expand_label(h,d.secret[:hash.DIGEST_SIZES[h]],"key",nil,key[:aead.KEY_SIZES[algorithm]])
    expand_label(h,d.secret[:hash.DIGEST_SIZES[h]],"iv",nil,d.iv[:])
    aead.init(&d.aead,algorithm,key[:aead.KEY_SIZES[algorithm]])
    wipe(key[:])
    d.seq=0
    d.active=true
    d.epoch+=1
}

// The next traffic secret of a direction (KeyUpdate).
@(private)
direction_advance :: proc(d:^Direction,suite:Suite) {
    h:=suite_hash(suite)
    size:=hash.DIGEST_SIZES[h]
    next:[HASH_MAX]u8
    expand_label(h,d.secret[:size],"traffic upd",nil,next[:size])
    direction_set(d,suite,next[:size])
    wipe(next[:])
}

// The verify_data of Finished from the traffic secret of its sender and the transcript.
@(private)
finished_compute :: proc(h:hash.Algorithm,base:[]u8,transcript:[]u8,dst:[]u8) {
    size:=hash.DIGEST_SIZES[h]
    key:[HASH_MAX]u8
    expand_label(h,base[:size],"finished",nil,key[:size])
    hmac.sum(h,dst[:size],transcript,key[:size])
    wipe(key[:])
}

@(private)
transcript_add :: proc(c:^Conn,message:[]u8) {
    hash.update(&c.transcript[0],message)
    hash.update(&c.transcript[1],message)
}

@(private)
transcript_hash :: proc(c:^Conn,dst:^[HASH_MAX]u8) -> []u8 {
    size:=hash.DIGEST_SIZES[c.digest]
    hash.final(&c.transcript[0 if c.digest==.SHA256 else 1],dst[:size],true)
    return dst[:size]
}

// Replaces the first ClientHello of the transcript with its hash (RFC 8446, 4.4.1).
@(private)
transcript_restart :: proc(c:^Conn) {
    for &t,i in c.transcript {
        h:hash.Algorithm=.SHA256 if i==0 else .SHA384
        size:=hash.DIGEST_SIZES[h]
        digest:[HASH_MAX]u8
        hash.final(&t,digest[:size])
        hash.init(&t,h)
        hash.update(&t,{254,0,0,u8(size)})
        hash.update(&t,digest[:size])
    }
}

// The handshake secrets once the transcript holds ServerHello.
@(private)
schedule_handshake :: proc(c:^Conn,shared:[]u8) {
    h:=c.digest
    size:=hash.DIGEST_SIZES[h]
    zeros,early,derived,empty,th:[HASH_MAX]u8
    hkdf.extract(h,zeros[:size],zeros[:size],early[:size])
    hash.hash_bytes_to_buffer(h,nil,empty[:size])
    derive_secret(h,early[:size],"derived",empty[:size],derived[:])
    hkdf.extract(h,derived[:size],shared,c.handshake_secret[:size])
    transcript_hash(c,&th)
    derive_secret(h,c.handshake_secret[:size],"c hs traffic",th[:size],c.client_traffic[:])
    derive_secret(h,c.handshake_secret[:size],"s hs traffic",th[:size],c.server_traffic[:])
    derive_secret(h,c.handshake_secret[:size],"derived",empty[:size],derived[:])
    hkdf.extract(h,derived[:size],zeros[:size],c.master_secret[:size])
    wipe(early[:]);wipe(derived[:])
}

// The application secrets once the transcript holds the server's Finished; the handshake
// secrets they replace are kept in the directions that still use them.
@(private)
schedule_application :: proc(c:^Conn) {
    h:=c.digest
    th:[HASH_MAX]u8
    transcript_hash(c,&th)
    size:=hash.DIGEST_SIZES[h]
    derive_secret(h,c.master_secret[:size],"c ap traffic",th[:size],c.client_traffic[:])
    derive_secret(h,c.master_secret[:size],"s ap traffic",th[:size],c.server_traffic[:])
    wipe(c.master_secret[:])
    wipe(c.handshake_secret[:])
}
