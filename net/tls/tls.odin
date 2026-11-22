package tls

// TLS 1.3 (RFC 8446) without I/O. The caller hands a connection the bytes it
// received (receive) and sends the bytes the connection gives (pending, then
// sent); between the two it writes and reads application data. A connection
// takes one block of memory at creation and allocates nothing after it: a
// record is decrypted in place in the input buffer and its data waits there
// until read takes it, and receive takes no more bytes until then, nor while
// the output has no room for an answer.
//
// Only TLS 1.3: no renegotiation, compression or early data (a server skips
// the early data of a client without reading it), no resumption, and the
// server asks for no client certificate. A server presents ECDSA P-256
// chains; a client verifies a chain against the trust anchors of its Config
// and the host it connects to.

import "base:runtime"
import "core:crypto"
import "core:crypto/aead"
import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:crypto/rsa"
import "core:crypto/x509"
import "core:mem"
import "core:time"

Role :: enum u8 {Client,Server}

Suite :: enum u8 {AES_128_GCM_SHA256,AES_256_GCM_SHA384,CHACHA20_POLY1305_SHA256}
Suites :: bit_set[Suite;u8]
// Key exchange groups. A client sends a key share for the first of its groups.
Group :: enum u8 {X25519,P256}
Groups :: bit_set[Group;u8]

// A certificate chain a server presents and the key of its leaf (credential_init).
Credential :: struct {
    chain:[][]u8, // DER, leaf first; the caller keeps the bytes alive
    key:ecdsa.Private_Key, // P-256
    // When set, the chain is presented only on connections that negotiate this protocol
    // (the challenge certificate of acme-tls/1), and those get no other.
    alpn:string,
    leaf:x509.Certificate,
}

// What a connection may negotiate. A zero set of suites or groups is all of them. The slices
// are read during the handshake: they outlive the connections that use the Config.
Config :: struct {
    suites:Suites,
    groups:Groups,
    // Application protocols: a client offers them, a server picks the first of its own that
    // the client offers.
    alpn:[]string,
    // Server: picked at each ClientHello by the name the client asks for (SNI) and the
    // protocol, and used only while that hello is answered. An entry without a chain is
    // skipped: the owner of the slice may clear or fill entries while connections use it.
    credentials:[]Credential,
    // Client: the name the server's leaf must hold, sent as SNI unless it is an IP address.
    host:string,
    roots:[]^x509.Certificate,
    time:time.Time, // when the server chain must be valid; zero is now
}

Error :: enum u8 {
    None,
    Out_Of_Memory,
    Closed, // the connection ended: by close_notify or by a call on a closed connection
    Alert_Received, // the peer ended the connection with Conn.alert
    Bad_Config, // no credential, no suite or group, or a client without roots or host
    Decode,
    Unexpected_Message,
    Bad_Record_Mac,
    Record_Overflow,
    Protocol_Version,
    Illegal_Parameter,
    Handshake_Failure,
    Bad_Certificate,
    Unsupported_Certificate,
    Certificate_Expired,
    Unknown_CA,
    Decrypt_Error,
    Missing_Extension,
    Unsupported_Extension,
    Unrecognized_Name,
    No_Application_Protocol,
    Internal,
}

// The alert descriptions of RFC 8446, 6.
Alert :: enum u8 {
    Close_Notify = 0,
    Unexpected_Message = 10,
    Bad_Record_Mac = 20,
    Record_Overflow = 22,
    Handshake_Failure = 40,
    Bad_Certificate = 42,
    Unsupported_Certificate = 43,
    Certificate_Revoked = 44,
    Certificate_Expired = 45,
    Certificate_Unknown = 46,
    Illegal_Parameter = 47,
    Unknown_CA = 48,
    Access_Denied = 49,
    Decode_Error = 50,
    Decrypt_Error = 51,
    Protocol_Version = 70,
    Insufficient_Security = 71,
    Internal_Error = 80,
    Inappropriate_Fallback = 86,
    User_Canceled = 90,
    Missing_Extension = 109,
    Unsupported_Extension = 110,
    Unrecognized_Name = 112,
    Bad_Certificate_Status_Response = 113,
    Unknown_PSK_Identity = 115,
    Certificate_Required = 116,
    No_Application_Protocol = 120,
}

// The alert a connection sends when it fails with each error.
@(private)
ALERT_OF :: [Error]Alert{
    .None = .Close_Notify,
    .Out_Of_Memory = .Internal_Error,
    .Closed = .Close_Notify,
    .Alert_Received = .Close_Notify,
    .Bad_Config = .Internal_Error,
    .Decode = .Decode_Error,
    .Unexpected_Message = .Unexpected_Message,
    .Bad_Record_Mac = .Bad_Record_Mac,
    .Record_Overflow = .Record_Overflow,
    .Protocol_Version = .Protocol_Version,
    .Illegal_Parameter = .Illegal_Parameter,
    .Handshake_Failure = .Handshake_Failure,
    .Bad_Certificate = .Bad_Certificate,
    .Unsupported_Certificate = .Unsupported_Certificate,
    .Certificate_Expired = .Certificate_Expired,
    .Unknown_CA = .Unknown_CA,
    .Decrypt_Error = .Decrypt_Error,
    .Missing_Extension = .Missing_Extension,
    .Unsupported_Extension = .Unsupported_Extension,
    .Unrecognized_Name = .Unrecognized_Name,
    .No_Application_Protocol = .No_Application_Protocol,
    .Internal = .Internal_Error,
}

@(private)
State :: enum u8 {
    Wait_Server_Hello,
    Wait_Encrypted_Extensions,
    Wait_Certificate_Or_Request,
    Wait_Certificate,
    Wait_Certificate_Verify,
    Wait_Server_Finished,
    Wait_Client_Hello,
    Wait_Client_Finished,
    Connected,
    Closed,
    Failed,
}

PLAINTEXT_MAX :: 1<<14
@(private) CIPHERTEXT_MAX :: PLAINTEXT_MAX+256
@(private) HEADER_BYTES :: 5
@(private) RECORD_BYTES :: HEADER_BYTES+CIPHERTEXT_MAX
@(private) TAG_BYTES :: 16
@(private) IV_BYTES :: 12
@(private) HASH_MAX :: 48
// The largest handshake message a connection takes or composes: a certificate chain fits.
HANDSHAKE_MAX :: 32<<10
// The output keeps this room free for what an answer to the peer needs (an alert, a KeyUpdate).
@(private) ANSWER_BYTES :: 2*(HEADER_BYTES+64)
@(private) OUTPUT_BYTES :: HANDSHAKE_MAX+4*(HEADER_BYTES+1+TAG_BYTES)+RECORD_BYTES
// Bytes of a client's early data a server skips without its keys.
@(private) EARLY_SKIP_MAX :: 4*RECORD_BYTES
@(private) CERTIFICATES_MAX :: 10
@(private) COOKIE_MAX :: 512

// The keys of one direction of a connection.
@(private)
Direction :: struct {
    aead:aead.Context,
    iv:[IV_BYTES]u8,
    seq:u64,
    secret:[HASH_MAX]u8, // the traffic secret, which KeyUpdate advances
    active:bool,
    epoch:u8, // counts the keys set
}

// The public key of a server's leaf, between its Certificate and its CertificateVerify.
@(private)
Peer_Key :: union {ecdsa.Public_Key,rsa.Public_Key,ed25519.Public_Key}

Conn :: struct {
    allocator:runtime.Allocator,
    memory:[]u8,
    config:Config,
    role:Role,
    state:State,
    error:Error,
    alert:Alert, // the alert the peer ended the connection with (Alert_Received)
    peer_closed:bool, // close_notify received: read gives the data before it and then nothing
    close_sent:bool,
    // One record at a time, decrypted in place; plain is the part of it read has not taken.
    input:[]u8,
    input_len:int,
    plain_at,plain_len:int,
    // Handshake messages until they are whole.
    handshake:[]u8,
    handshake_len:int,
    // What the peer has to receive, from output_at to output_len.
    output:[]u8,
    output_at,output_len:int,
    // Where messages are composed and where a client parses the server's chain.
    scratch:[]u8,
    read,write:Direction,
    suite:Suite,
    digest:hash.Algorithm, // of the suite
    // The transcript under SHA-256 and SHA-384 until the suite says which one counts.
    transcript:[2]hash.Context,
    handshake_secret,master_secret:[HASH_MAX]u8,
    client_traffic,server_traffic:[HASH_MAX]u8, // handshake, then application traffic secrets
    group:Group,
    key_share:ecdh.Private_Key,
    retried:bool, // HelloRetryRequest sent or received
    early_skip:int, // server: bytes of early data it may still skip
    owe_key_update:bool,
    change_cipher_spec:bool, // the compatibility record was received
    // Records in a row that carried no application data after the handshake: KeyUpdates,
    // tickets, empty records and user_canceled alerts.
    idle_records:int,
    session_id:[32]u8,
    session_id_len:int,
    selected_alpn:string,
    server_name:[255]u8,
    server_name_len:int,
    // Client
    random:[32]u8, // of both its hellos
    certificate_requested:bool,
    request_context:[255]u8,
    request_context_len:int,
    cookie:[COOKIE_MAX]u8,
    cookie_len:int,
    peer_key:Peer_Key,
}

// The memory of a connection, a multiple of CONN_ALIGN: what create takes, or what a caller that
// keeps its connections in a pool gives create_at.
CONN_BYTES :: (size_of(Conn)+RECORD_BYTES+HANDSHAKE_MAX+OUTPUT_BYTES+HANDSHAKE_MAX+CONN_ALIGN-1)&~(CONN_ALIGN-1)
CONN_ALIGN :: 64
#assert(align_of(Conn)<=CONN_ALIGN)

// A connection for role, which writes its first flight at once (a client its ClientHello).
// Only this call allocates; destroy frees what it took.
create :: proc(config:Config,role:Role,allocator:=context.allocator) -> (c:^Conn,err:Error) {
    if !config_valid(config,role) {return nil,.Bad_Config}
    memory,merr:=mem.make_aligned([]u8,CONN_BYTES,CONN_ALIGN,allocator)
    if merr!=nil {return nil,.Out_Of_Memory}
    return conn_init(memory,config,role,allocator)
}

// A connection in memory the caller keeps: CONN_BYTES at an address aligned to CONN_ALIGN, zero
// or wiped by the destroy of the connection before. It allocates nothing, and destroy wipes it
// and frees nothing.
create_at :: proc(memory:[]u8,config:Config,role:Role) -> (c:^Conn,err:Error) {
    if !config_valid(config,role) || len(memory)<CONN_BYTES || uintptr(raw_data(memory))%CONN_ALIGN!=0 {return nil,.Bad_Config}
    return conn_init(memory[:CONN_BYTES],config,role,{})
}

@(private)
conn_init :: proc(memory:[]u8,config:Config,role:Role,allocator:runtime.Allocator) -> (c:^Conn,err:Error) {
    c=(^Conn)(raw_data(memory))
    c^={}
    c.allocator,c.memory,c.config,c.role=allocator,memory,config,role
    if c.config.suites=={} {c.config.suites=ALL_SUITES}
    if c.config.groups=={} {c.config.groups=ALL_GROUPS}
    at:=size_of(Conn)
    c.input=memory[at:][:RECORD_BYTES];at+=RECORD_BYTES
    c.handshake=memory[at:][:HANDSHAKE_MAX];at+=HANDSHAKE_MAX
    c.output=memory[at:][:OUTPUT_BYTES];at+=OUTPUT_BYTES
    c.scratch=memory[at:][:HANDSHAKE_MAX]
    hash.init(&c.transcript[0],.SHA256)
    hash.init(&c.transcript[1],.SHA384)
    if role==.Server {
        c.state=.Wait_Client_Hello
        return c,nil
    }
    c.state=.Wait_Server_Hello
    c.group=.X25519 if .X25519 in c.config.groups else .P256
    if err=client_hello_send(c);err!=nil {
        destroy(c)
        return nil,err
    }
    return c,nil
}

// Wipes the keys and the memory of a connection, and frees it when create took it.
destroy :: proc(c:^Conn) {
    if c==nil {return}
    aead.reset(&c.read.aead)
    aead.reset(&c.write.aead)
    hash.reset(&c.transcript[0])
    hash.reset(&c.transcript[1])
    ecdh.private_key_clear(&c.key_share)
    memory,allocator:=c.memory,c.allocator
    crypto.zero_explicit(raw_data(memory),len(memory))
    if allocator.procedure!=nil {_=mem.free_bytes(memory,allocator)}
}

// Hands the connection bytes received from the peer. taken can be fewer than len(bytes): the
// connection takes no more while decrypted data waits for read or its output has no room for
// an answer; the rest is handed again after read or sent. Once it fails, every call returns its
// error, and pending holds the alert for the peer.
receive :: proc(c:^Conn,bytes:[]u8) -> (taken:int,err:Error) {
    if c.state==.Failed {return 0,c.error}
    for {
        if c.plain_len>0 || c.peer_closed || c.state==.Failed {break}
        if c.owe_key_update && !key_update_flush(c) {break}
        if output_room(c)<ANSWER_BYTES {break}
        if c.input_len<HEADER_BYTES {
            n:=min(HEADER_BYTES-c.input_len,len(bytes)-taken)
            copy(c.input[c.input_len:],bytes[taken:][:n])
            c.input_len+=n
            taken+=n
            if c.input_len<HEADER_BYTES {break}
            if e:=record_header_check(c);e!=nil {return taken,fail(c,e)}
        }
        total:=HEADER_BYTES+record_length(c)
        n:=min(total-c.input_len,len(bytes)-taken)
        copy(c.input[c.input_len:],bytes[taken:][:n])
        c.input_len+=n
        taken+=n
        if c.input_len<total {break}
        e:=record_receive(c)
        c.input_len=0
        if e!=nil {return taken,fail(c,e)}
    }
    return taken,nil
}

// Copies decrypted application data into buffer and returns how much. After a close_notify, 0
// with the error Closed once the data before it was read.
read :: proc(c:^Conn,buffer:[]u8) -> (count:int,err:Error) {
    if c.state==.Failed {return 0,c.error}
    count=min(len(buffer),c.plain_len)
    copy(buffer,c.input[c.plain_at:][:count])
    c.plain_at+=count
    c.plain_len-=count
    if count==0 && c.peer_closed {return 0,.Closed}
    return count,nil
}

// Encrypts application data for the peer and returns how much it took, which the room of the
// output limits. Only once connected.
write :: proc(c:^Conn,data:[]u8) -> (taken:int,err:Error) {
    if c.state==.Failed {return 0,c.error}
    if c.close_sent || c.state==.Closed {return 0,.Closed}
    if c.state!=.Connected {return 0,nil}
    if c.owe_key_update && !key_update_flush(c) {return 0,nil}
    for taken<len(data) {
        if c.write.seq>=KEY_UPDATE_RECORDS {
            if !key_update_send(c,false) {break}
        }
        n:=min(len(data)-taken,PLAINTEXT_MAX,output_room(c)-HEADER_BYTES-1-TAG_BYTES-ANSWER_BYTES)
        if n<=0 {break}
        if e:=record_seal(c,.Application_Data,data[taken:][:n]);e!=nil {return taken,fail(c,e)}
        taken+=n
    }
    return taken,nil
}

// The bytes the peer has to receive; after sending some, sent says how many.
pending :: proc(c:^Conn) -> []u8 {return c.output[c.output_at:c.output_len]}

sent :: proc(c:^Conn,n:int) {
    c.output_at+=clamp(n,0,c.output_len-c.output_at)
    if c.output_at==c.output_len {c.output_at,c.output_len=0,0}
}

// Ends this side with close_notify. The peer may still send until its own.
close :: proc(c:^Conn) {
    if c.state==.Failed || c.close_sent {return}
    c.close_sent=true
    alert_send(c,.Close_Notify)
    if c.state!=.Connected {c.state=.Closed}
}

// Sends KeyUpdate: new keys for what this side writes, and with request for what the peer does.
key_update :: proc(c:^Conn,request:bool) -> Error {
    if c.state==.Failed {return c.error}
    if c.state!=.Connected || c.close_sent {return .Closed}
    if !key_update_send(c,request) {return .Out_Of_Memory}
    return nil
}

// Whether the handshake ended and application data flows.
connected :: proc(c:^Conn) -> bool {return c.state==.Connected}

// The protocol both ends agreed on through ALPN, "" without one.
protocol :: proc(c:^Conn) -> string {return c.selected_alpn}

// Server: the name the client asked for, "" when it asked for none.
server_name :: proc(c:^Conn) -> string {return string(c.server_name[:c.server_name_len])}

// The certificate chain and key a server presents. The leaf must hold the public key of key
// (P-256). The chain bytes stay the caller's; credential_destroy frees what this allocates.
credential_init :: proc(chain:[][]u8,key:^ecdsa.Private_Key,alpn:="",allocator:=context.allocator) -> (cred:Credential,err:Error) {
    if len(chain)==0 || ecdsa.curve(key)!=.SECP256R1 {return {},.Bad_Config}
    leaf,perr:=x509.parse(chain[0],allocator)
    if perr==.Allocation_Failed {return {},.Out_Of_Memory}
    if perr!=.None {return {},.Bad_Certificate}
    public:[65]u8
    ecdsa.private_key_public_bytes(key,public[:])
    if leaf.public_key_algorithm!=.ECDSA_P256 || !crypto_equal(leaf.ec_point,public[:]) {
        x509.destroy(&leaf,allocator)
        return {},.Bad_Certificate
    }
    cred.chain,cred.alpn,cred.leaf=chain,alpn,leaf
    ecdsa.private_key_set(&cred.key,key)
    return cred,nil
}

credential_destroy :: proc(cred:^Credential,allocator:=context.allocator) {
    x509.destroy(&cred.leaf,allocator)
    ecdsa.private_key_clear(&cred.key)
    cred^={}
}

@(private)
config_valid :: proc(config:Config,role:Role) -> bool {
    groups:=config.groups if config.groups!={} else ALL_GROUPS
    suites:=config.suites if config.suites!={} else ALL_SUITES
    if groups&ALL_GROUPS=={} || suites&ALL_SUITES=={} {return false}
    for name in config.alpn {
        if len(name)==0 || len(name)>255 {return false}
    }
    if role==.Server {return len(config.credentials)>0}
    for root in config.roots {
        if root==nil {return false}
    }
    return len(config.roots)>0 && len(config.host)>0 && len(config.host)<=255
}

@(private)
wipe :: proc(b:[]u8) {crypto.zero_explicit(raw_data(b),len(b))}

@(private)
crypto_equal :: proc(a,b:[]u8) -> bool {
    return len(a)==len(b) && crypto.compare_constant_time(a,b)==1
}

// Ends the connection with err and queues its alert for the peer.
@(private)
fail :: proc(c:^Conn,err:Error) -> Error {
    if c.state==.Failed {return c.error}
    if err!=.Alert_Received && err!=.Closed {alerts:=ALERT_OF;alert_send(c,alerts[err])}
    c.state,c.error=.Failed,err
    c.plain_len=0
    return err
}
