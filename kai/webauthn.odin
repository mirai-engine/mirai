package kai

import "core:crypto/ecdsa"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:encoding/asn1"
import "core:encoding/base64"
import "core:encoding/cbor"
import "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"
import "mirai:store"

// Passkeys, verified offline. A browser signs with a WebAuthn assertion: its
// authenticator signs authenticatorData || SHA-256(clientDataJSON), and the
// client data carries the challenge. A login's challenge is the server's; an
// entry's is the BLAKE3 of the entry's bytes before its assertion, so the
// server that relays it can change nothing of it. The key is a COSE key a
// Web_Key_Add of the user's log records; its web key id, the entry's author,
// is the BLAKE3 of that key and its relying party, so an entry carries both
// and verifies alone, and the fold says whose key it is. A login needs the
// user present; a write also needs the user verified (PIN or biometric), and
// an ES256 write carries the low S of the two that verify, so a signature has
// one encoding and an entry one address.

Cose_Alg :: enum u8 {EdDSA,ES256}

Cose_Key :: struct {
    alg:Cose_Alg,
    public:[65]u8, // EdDSA: the 32 bytes of the key; ES256: 0x04 || X || Y
}

Web_Assertion :: struct {
    authenticator_data:[]u8,
    client_data_json:[]u8,
    signature:[]u8, // EdDSA: 64 bytes; ES256: ASN.1 DER
}

Webauthn_Failure :: enum u8 {None,Malformed,Key,Type,Challenge,Origin,Rp_Id,Presence,Verification,Signature}

webauthn_failure_text :: proc(failure:Webauthn_Failure) -> string {
    switch failure {
    case .None: return "the assertion holds"
    case .Malformed: return "the assertion does not read: sign again in the browser"
    case .Key: return "the passkey is not an Ed25519 or P-256 COSE key: register a passkey of those"
    case .Type: return "the client data is not of a webauthn.get: sign with navigator.credentials.get"
    case .Challenge: return "the assertion signs another challenge: sign the challenge given"
    case .Origin: return "the assertion comes from another origin: sign on https://<relying party id>"
    case .Rp_Id: return "the authenticator signed for another relying party: use the passkey of this site"
    case .Presence: return "the authenticator saw no user present: touch it when it asks"
    case .Verification: return "the authenticator did not verify the user: a write needs the passkey's PIN or biometric"
    case .Signature: return "the signature is not the passkey's: sign again with the passkey registered"
    }
    return ""
}

COSE_KEY_MAX :: 256
RP_ID_MAX :: 253          // a DNS name
CLIENT_DATA_MAX :: 1024
AUTHENTICATOR_DATA_MIN :: 37 // rpIdHash, flags and the sign counter
AUTHENTICATOR_DATA_MAX :: 1024
FLAG_USER_PRESENT :: 0x01
FLAG_USER_VERIFIED :: 0x04

// What follows an entry's u16 length when it is signed by WebAuthn.
Assertion_Head :: struct #packed {cose:u16,rp:u8,authenticator:u16,client:u16,signature:u8} // + cose, rp id, authenticatorData, clientDataJSON, signature

// The key of a COSE_Key map: OKP Ed25519 with alg -8, or EC2 P-256 with alg -7.
cose_key_parse :: proc(cose:[]u8) -> (key:Cose_Key,ok:bool) {
    if len(cose)==0 || len(cose)>COSE_KEY_MAX {return}
    r:strings.Reader
    strings.reader_init(&r,string(cose))
    value,e:=cbor.decode_from_reader(strings.reader_to_stream(&r),{.Disallow_Streaming},context.temp_allocator)
    if e!=nil || strings.reader_length(&r)!=0 {return}
    m,is_map:=value.(^cbor.Map)
    if !is_map {return}
    kty,alg,crv:i64
    x,y:[]u8
    seen:bit_set[0..<5]
    for item in m^ {
        label,is_int:=cbor_int(item.key)
        if !is_int {continue}
        field:int
        switch label {
        case 1: field=0
        case 3: field=1
        case -1: field=2
        case -2: field=3
        case -3: field=4
        case: continue
        }
        if field in seen {return}
        seen+={field}
        switch field {
        case 0: kty,ok=cbor_int(item.value)
        case 1: alg,ok=cbor_int(item.value)
        case 2: crv,ok=cbor_int(item.value)
        case 3,4:
            b,is_bytes:=item.value.(^cbor.Bytes)
            if !is_bytes {return {},false}
            if field==3 {x=b^} else {y=b^}
            ok=true
        }
        if !ok {return}
    }
    switch {
    case kty==1 && alg==-8 && crv==6 && len(x)==32 && 4 not_in seen:
        key.alg=.EdDSA
        copy(key.public[:],x)
        public:ed25519.Public_Key
        return key,ed25519.public_key_set_bytes(&public,key.public[:32])
    case kty==2 && alg==-7 && crv==1 && len(x)==32 && len(y)==32:
        key.alg=.ES256
        key.public[0]=0x04
        copy(key.public[1:],x)
        copy(key.public[33:],y)
        public:ecdsa.Public_Key
        return key,ecdsa.public_key_set_bytes(&public,.SECP256R1,key.public[:])
    }
    return {},false
}

@(private)
cbor_int :: proc(v:cbor.Value) -> (value:i64,ok:bool) {
    #partial switch n in v {
    case u8: return i64(n),true
    case u16: return i64(n),true
    case u32: return i64(n),true
    case u64: return i64(n),n<=u64(max(i64))
    case cbor.Negative_U8: return -1-i64(n),true
    case cbor.Negative_U16: return -1-i64(n),true
    case cbor.Negative_U32: return -1-i64(n),true
    case cbor.Negative_U64: return -1-i64(n),u64(n)<u64(max(i64))
    }
    return 0,false
}

// Checks an assertion of key for the relying party rp_id over challenge: a
// webauthn.get on https://<rp_id>, on any port, naming the challenge,
// authenticator data for rp_id with the user present, and the key's signature
// over both. A write's also has the user verified and a low S.
webauthn_verify :: proc(key:^Cose_Key,rp_id:string,challenge:[]u8,a:^Web_Assertion,write:bool) -> Webauthn_Failure {
    data,client:=a.authenticator_data,a.client_data_json
    if len(rp_id)==0 || len(rp_id)>RP_ID_MAX || len(data)<AUTHENTICATOR_DATA_MIN || len(data)>AUTHENTICATOR_DATA_MAX {return .Malformed}
    if len(client)==0 || len(client)>CLIENT_DATA_MAX || !utf8.valid_string(string(client)) {return .Malformed}
    Client_Data :: struct {
        kind:string `json:"type"`,
        challenge:string `json:"challenge"`,
        origin:string `json:"origin"`,
        cross_origin:bool `json:"crossOrigin"`,
    }
    c:Client_Data
    if json.unmarshal(client,&c,.JSON,context.temp_allocator)!=nil {return .Malformed}
    if c.kind!="webauthn.get" {return .Type}
    expected,encode_error:=base64.encode(challenge,base64.ENC_URL_TABLE,context.temp_allocator,{.No_Padding})
    if encode_error!=nil {return .Malformed}
    if c.challenge!=expected {return .Challenge}
    if c.cross_origin || !origin_of_rp(c.origin,rp_id) {return .Origin}
    rp_hash:[32]u8
    hash.hash_string_to_buffer(.SHA256,rp_id,rp_hash[:])
    if string(data[:32])!=string(rp_hash[:]) {return .Rp_Id}
    if data[32]&FLAG_USER_PRESENT==0 {return .Presence}
    if write && data[32]&FLAG_USER_VERIFIED==0 {return .Verification}
    message,made:=make([]u8,len(data)+32,context.temp_allocator)
    if made!=nil {return .Malformed}
    copy(message,data)
    hash.hash_bytes_to_buffer(.SHA256,client,message[len(data):])
    switch key.alg {
    case .EdDSA:
        public:ed25519.Public_Key
        if len(a.signature)!=ed25519.SIGNATURE_SIZE || !ed25519.public_key_set_bytes(&public,key.public[:32]) {return .Signature}
        if !ed25519.verify(&public,message,a.signature) {return .Signature}
    case .ES256:
        public:ecdsa.Public_Key
        if !ecdsa.public_key_set_bytes(&public,.SECP256R1,key.public[:]) {return .Key}
        if write {
            _,low,canonical:=es256_low_s(a.signature,context.temp_allocator)
            if !canonical || string(low)!=string(a.signature) {return .Signature}
        }
        if !ecdsa.verify_asn1(&public,.SHA256,message,a.signature) {return .Signature}
    }
    return .None
}

// Whether origin is https://<rp_id>, with a port or without.
@(private)
origin_of_rp :: proc(origin,rp_id:string) -> bool {
    if !strings.has_prefix(origin,"https://") {return false}
    rest:=origin[len("https://"):]
    if !strings.has_prefix(rest,rp_id) {return false}
    port:=rest[len(rp_id):]
    if port=="" {return true}
    if port[0]!=':' || len(port)<2 || len(port)>6 || port[1]=='0' {return false}
    for c in transmute([]u8)port[1:] {
        if c<'0' || c>'9' {return false}
    }
    return true
}

// The order n of P-256 and n/2, big-endian.
@(private) P256_ORDER :: [32]u8{0xff,0xff,0xff,0xff,0,0,0,0,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xbc,0xe6,0xfa,0xad,0xa7,0x17,0x9e,0x84,0xf3,0xb9,0xca,0xc2,0xfc,0x63,0x25,0x51}
@(private) P256_HALF_ORDER :: [32]u8{0x7f,0xff,0xff,0xff,0x80,0,0,0,0x7f,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xde,0x73,0x7d,0x56,0xd3,0x8b,0xcf,0x42,0x79,0xdc,0xe5,0x61,0x7e,0x31,0x92,0xa8}

// The DER of an ES256 signature with s replaced by n-s when it is above n/2,
// in allocator: high tells it was; canonical that the signature read as DER
// of two integers below n.
@(private)
es256_low_s :: proc(signature:[]u8,allocator:=context.allocator) -> (high:bool,low:[]u8,canonical:bool) {
    cursor:asn1.Cursor
    asn1.cursor_init(&cursor,signature)
    sequence,e:=asn1.read_sequence(&cursor)
    if e!=.None || asn1.done(&cursor)!=.None {return}
    r_bytes,re:=asn1.read_unsigned_integer_bytes(&sequence)
    s_bytes,se:=asn1.read_unsigned_integer_bytes(&sequence)
    if re!=.None || se!=.None || asn1.done(&sequence)!=.None || len(r_bytes)>32 || len(s_bytes)>32 {return}
    r,s:[32]u8
    copy(r[32-len(r_bytes):],r_bytes)
    copy(s[32-len(s_bytes):],s_bytes)
    order,half:=P256_ORDER,P256_HALF_ORDER
    if string(r[:])>=string(order[:]) || string(s[:])>=string(order[:]) {return}
    if string(s[:])>string(half[:]) {
        high=true
        borrow:=0
        for i:=31;i>=0;i-=1 {
            d:=int(order[i])-int(s[i])-borrow
            borrow=d<0?1:0
            s[i]=u8(d+256*borrow)
        }
    }
    trim :: proc(b:[]u8) -> []u8 {
        b:=b
        for len(b)>1 && b[0]==0 {b=b[1:]}
        return b
    }
    out,me:=asn1.marshal(asn1.sequence({asn1.integer_unsigned(trim(r[:])),asn1.integer_unsigned(trim(s[:]))}),allocator)
    if me!=.None {return}
    return high,out,true
}

// The web key id of a COSE key for a relying party: what entries it signs
// name as their author.
web_key_id :: proc(cose:[]u8,rp_id:string) -> Key {
    bytes:=make([dynamic]u8,0,2+len(cose)+len(rp_id),context.temp_allocator)
    length:=u16(min(len(cose),int(max(u16))))
    append(&bytes,u8(length),u8(length>>8))
    append(&bytes,..cose)
    append(&bytes,rp_id)
    return Key(store.address_of_bytes(bytes[:]))
}

// A body of Web_Key_Add for a passkey: its credential id, its COSE key and the
// relying party it signs for.
web_key_add_body :: proc(credential:[]u8,cose:[]u8,rp_id:string) -> (body:[]u8,error:Error) {
    if len(credential)==0 || len(credential)>255 || len(rp_id)==0 || len(rp_id)>RP_ID_MAX || !utf8.valid_string(rp_id) {return nil,.Invalid_Argument}
    if _,ok:=cose_key_parse(cose);!ok {return nil,.Invalid_Argument}
    body=body_make(Web_Key_Add_Body{credential=u8(len(credential)),cose=u16(len(cose)),rp=u8(len(rp_id))},credential,cose,transmute([]u8)rp_id)
    return body,body==nil?.Out_Of_Memory:.None
}

// The web key id a Web_Key_Add or Passkey_Genesis body records, when its key
// reads.
@(private)
web_key_of :: proc(body:[]u8) -> (key:Key,ok:bool) {
    _,cose,rp_id,_,read:=passkey_parts(body)
    if !read {return}
    if _,parsed:=cose_key_parse(cose);!parsed {return}
    return web_key_id(cose,rp_id),true
}

// What a passkey signs for d: the entry's bytes by the web key before its
// assertion, in allocator, and the challenge, their BLAKE3.
entry_webauthn_begin :: proc(d:^Draft,web_key:Key,allocator:=context.allocator) -> (unsigned:[]u8,challenge:store.Hash,error:Error) {
    w:=entry_unsigned(d,web_key,.WebAuthn,allocator) or_return
    return w.data[:],store.address_of_bytes(w.data[:]),.None
}

// The entry of unsigned with the assertion of the passkey of cose for rp_id,
// checked: its bytes in allocator and its address.
entry_webauthn_finish :: proc(unsigned:[]u8,cose:[]u8,rp_id:string,a:^Web_Assertion,allocator:=context.allocator) -> (bytes:[]u8,address:store.Hash,error:Error) {
    if len(cose)>COSE_KEY_MAX || len(rp_id)>RP_ID_MAX || len(a.authenticator_data)>AUTHENTICATOR_DATA_MAX || len(a.client_data_json)>CLIENT_DATA_MAX || len(a.signature)>255 {return nil,{},.Too_Large}
    a:=a^
    if key,parsed:=cose_key_parse(cose);parsed && key.alg==.ES256 {
        if _,low,canonical:=es256_low_s(a.signature,context.temp_allocator);canonical {a.signature=low}
    }
    size:=size_of(Assertion_Head)+len(cose)+len(rp_id)+len(a.authenticator_data)+len(a.client_data_json)+len(a.signature)
    if size>ASSERTION_MAX {return nil,{},.Too_Large}
    w:=writer_make(allocator)
    write_bytes(&w,unsigned)
    write_value(&w,u16(size))
    write_value(&w,Assertion_Head{u16(len(cose)),u8(len(rp_id)),u16(len(a.authenticator_data)),u16(len(a.client_data_json)),u8(len(a.signature))})
    write_bytes(&w,cose)
    write_string(&w,rp_id)
    write_bytes(&w,a.authenticator_data)
    write_bytes(&w,a.client_data_json)
    write_bytes(&w,a.signature)
    if w.failed {
        delete(w.data)
        return nil,{},.Out_Of_Memory
    }
    e,decode:=entry_decode(w.data[:])
    if decode!=.None || e.sig_kind!=.WebAuthn || !entry_verify(w.data[:],&e) {
        delete(w.data)
        return nil,{},decode!=.None?.Invalid_Argument:.Unauthorized
    }
    return w.data[:],store.address_of_bytes(w.data[:]),.None
}

// Whether the assertion of e is by the passkey its author names, over signed.
@(private)
entry_assertion_valid :: proc(signed:[]u8,e:^Entry) -> bool {
    r:=Reader{data=e.assertion}
    head:=read_value(&r,Assertion_Head)
    cose:=read_bytes(&r,int(head.cose))
    rp_id:=string(read_bytes(&r,int(head.rp)))
    a:=Web_Assertion{read_bytes(&r,int(head.authenticator)),read_bytes(&r,int(head.client)),read_bytes(&r,int(head.signature))}
    if r.short || r.at!=len(e.assertion) || web_key_id(cose,rp_id)!=e.author {return false}
    key,ok:=cose_key_parse(cose)
    if !ok {return false}
    challenge:=store.address_of_bytes(signed)
    return webauthn_verify(&key,rp_id,challenge[:],&a,true)==.None
}
