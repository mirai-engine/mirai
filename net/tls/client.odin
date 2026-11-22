package tls

import "core:crypto"
import "core:crypto/ecdsa"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:crypto/rsa"
import "core:crypto/x509"
import "core:mem"
import "core:net"
import "core:time"

// "DOWNGRD" and a version byte end the random of a server that negotiates TLS 1.2 or lower
// with a client that offered TLS 1.3 (RFC 8446, 4.1.3).
@(private) DOWNGRADE :: "DOWNGRD"

@(private)
client_message :: proc(c:^Conn,message:[]u8) -> Error {
    kind:=Message(message[0])
    #partial switch c.state {
    case .Wait_Server_Hello:
        if kind==.Server_Hello {return client_server_hello(c,message)}
    case .Wait_Encrypted_Extensions:
        if kind==.Encrypted_Extensions {return client_encrypted_extensions(c,message)}
    case .Wait_Certificate_Or_Request:
        if kind==.Certificate_Request {return client_certificate_request(c,message)}
        if kind==.Certificate {return client_certificate(c,message)}
    case .Wait_Certificate:
        if kind==.Certificate {return client_certificate(c,message)}
    case .Wait_Certificate_Verify:
        if kind==.Certificate_Verify {return client_certificate_verify(c,message)}
    case .Wait_Server_Finished:
        if kind==.Finished {return client_finished(c,message)}
    case .Connected:
        if kind==.Key_Update {return key_update_receive(c,message[4:])}
        if kind==.New_Session_Ticket {
            idle_record(c) or_return
            return client_ticket(message[4:])
        }
    }
    return .Unexpected_Message
}

// The ClientHello, the first one or the one after a HelloRetryRequest, which differs only by
// its key share and cookie.
@(private)
client_hello_send :: proc(c:^Conn) -> Error {
    if !c.retried {crypto.rand_bytes(c.random[:])}
    public_buffer:[65]u8
    public:=key_share_make(c,&public_buffer) or_return
    w:=Writer{data=c.scratch}
    body:=message_open(&w,.Client_Hello)
    put_u16(&w,VERSION_TLS12)
    put_bytes(&w,c.random[:])
    put_u8(&w,0) // no session id
    suites:=vector_open(&w,2)
    for s in Suite {
        if s in c.config.suites {put_u16(&w,suite_code(s))}
    }
    vector_close(&w,suites,2)
    put_u8(&w,1);put_u8(&w,0)
    extensions:=vector_open(&w,2)
    if net.parse_address(c.config.host)==nil {
        put_u16(&w,EXT_SERVER_NAME)
        outer:=vector_open(&w,2)
        list:=vector_open(&w,2)
        put_u8(&w,0)
        put_vector(&w,2,transmute([]u8)c.config.host)
        vector_close(&w,list,2)
        vector_close(&w,outer,2)
    }
    put_u16(&w,EXT_SUPPORTED_GROUPS)
    outer:=vector_open(&w,2)
    list:=vector_open(&w,2)
    for g in Group {
        if g in c.config.groups {put_u16(&w,group_code(g))}
    }
    vector_close(&w,list,2)
    vector_close(&w,outer,2)
    put_u16(&w,EXT_SIGNATURE_ALGORITHMS)
    outer=vector_open(&w,2)
    list=vector_open(&w,2)
    for scheme in SIGNATURE_SCHEMES {put_u16(&w,int(scheme))}
    vector_close(&w,list,2)
    vector_close(&w,outer,2)
    put_u16(&w,EXT_SUPPORTED_VERSIONS);put_u16(&w,3);put_u8(&w,2);put_u16(&w,VERSION_TLS13)
    put_u16(&w,EXT_KEY_SHARE)
    outer=vector_open(&w,2)
    list=vector_open(&w,2)
    put_u16(&w,group_code(c.group))
    put_vector(&w,2,public)
    vector_close(&w,list,2)
    vector_close(&w,outer,2)
    if len(c.config.alpn)>0 {
        put_u16(&w,EXT_ALPN)
        outer=vector_open(&w,2)
        list=vector_open(&w,2)
        for name in c.config.alpn {put_vector(&w,1,transmute([]u8)name)}
        vector_close(&w,list,2)
        vector_close(&w,outer,2)
    }
    if c.cookie_len>0 {
        put_u16(&w,EXT_COOKIE)
        outer=vector_open(&w,2)
        put_vector(&w,2,c.cookie[:c.cookie_len])
        vector_close(&w,outer,2)
    }
    vector_close(&w,extensions,2)
    vector_close(&w,body,3)
    if w.bad {return .Internal}
    return handshake_send(c,w.data[:w.at])
}

// The extensions this client's hellos carry.
@(private)
client_offered :: proc(c:^Conn,dst:^[8]int) -> []int {
    n:=0
    for kind in ([?]int{EXT_SUPPORTED_GROUPS,EXT_SIGNATURE_ALGORITHMS,EXT_SUPPORTED_VERSIONS,EXT_KEY_SHARE}) {
        dst[n]=kind
        n+=1
    }
    if net.parse_address(c.config.host)==nil {dst[n]=EXT_SERVER_NAME;n+=1}
    if len(c.config.alpn)>0 {dst[n]=EXT_ALPN;n+=1}
    if c.cookie_len>0 {dst[n]=EXT_COOKIE;n+=1}
    return dst[:n]
}

@(private)
client_server_hello :: proc(c:^Conn,message:[]u8) -> Error {
    r:=Reader{data=message[4:]}
    legacy:=read_u16(&r)
    random:=read_bytes(&r,32)
    session_id:=read_vector(&r,1,0,32)
    code:=read_u16(&r)
    compression:=read_u8(&r)
    extensions:Extensions
    if !r.bad && r.at<len(r.data) {
        extensions_data:=read_vector(&r,2,0,0xffff)
        if !read_done(&r) {return .Decode}
        extensions_parse(extensions_data,&extensions) or_return
    }
    if r.bad {return .Decode}
    versions,has_versions:=extension_find(&extensions,EXT_SUPPORTED_VERSIONS)
    if !has_versions {
        if string(random[24:31])==DOWNGRADE {return .Illegal_Parameter}
        return .Protocol_Version
    }
    if legacy!=VERSION_TLS12 {return .Protocol_Version}
    if len(versions)!=2 || int(versions[0])<<8|int(versions[1])!=VERSION_TLS13 {return .Illegal_Parameter}
    retry_random:=RETRY_RANDOM
    retry:=crypto_equal(random,retry_random[:])
    // Only a HelloRetryRequest may carry a cookie this client did not send.
    allowed:=[3]int{EXT_SUPPORTED_VERSIONS,EXT_KEY_SHARE,EXT_COOKIE}
    offered:[8]int
    extensions_allowed(&extensions,allowed[:3 if retry else 2],client_offered(c,&offered)) or_return
    if len(session_id)!=0 || compression!=0 {return .Illegal_Parameter}
    suite,known:=suite_of(code)
    if !known || suite not_in c.config.suites || c.retried && suite!=c.suite {return .Illegal_Parameter}
    c.suite,c.digest=suite,suite_hash(suite)
    share,has_share:=extension_find(&extensions,EXT_KEY_SHARE)
    if !has_share {return .Missing_Extension}

    if retry {
        if c.retried {return .Unexpected_Message}
        if len(share)!=2 {return .Decode}
        group,ok:=group_of(int(share[0])<<8|int(share[1]))
        if !ok || group not_in c.config.groups || group==c.group {return .Illegal_Parameter}
        if cookie,has_cookie:=extension_find(&extensions,EXT_COOKIE);has_cookie {
            cr:=Reader{data=cookie}
            value:=read_vector(&cr,2,1,0xffff)
            if !read_done(&cr) {return .Decode}
            if len(value)>COOKIE_MAX {return .Handshake_Failure}
            copy(c.cookie[:],value)
            c.cookie_len=len(value)
        }
        transcript_restart(c)
        transcript_add(c,message)
        c.group,c.retried=group,true
        return client_hello_send(c)
    }

    sr:=Reader{data=share}
    code=read_u16(&sr)
    peer:=read_vector(&sr,2,1,0xffff)
    if !read_done(&sr) {return .Decode}
    if code!=group_code(c.group) {return .Illegal_Parameter}
    shared_buffer:[HASH_MAX]u8
    shared:=key_exchange(c,peer,&shared_buffer) or_return
    defer wipe(shared_buffer[:])
    transcript_add(c,message)
    schedule_handshake(c,shared)
    direction_set(&c.read,c.suite,c.server_traffic[:])
    direction_set(&c.write,c.suite,c.client_traffic[:])
    c.state=.Wait_Encrypted_Extensions
    return nil
}

@(private)
client_encrypted_extensions :: proc(c:^Conn,message:[]u8) -> Error {
    r:=Reader{data=message[4:]}
    data:=read_vector(&r,2,0,0xffff)
    if !read_done(&r) {return .Decode}
    extensions:Extensions
    extensions_parse(data,&extensions) or_return
    offered:[8]int
    extensions_allowed(&extensions,{EXT_SERVER_NAME,EXT_SUPPORTED_GROUPS,EXT_ALPN},client_offered(c,&offered)) or_return
    if name,found:=extension_find(&extensions,EXT_SERVER_NAME);found {
        if net.parse_address(c.config.host)!=nil {return .Unsupported_Extension}
        if len(name)!=0 {return .Decode}
    }
    if alpn,found:=extension_find(&extensions,EXT_ALPN);found {
        if len(c.config.alpn)==0 {return .Unsupported_Extension}
        ar:=Reader{data=alpn}
        lr:=Reader{data=read_vector(&ar,2,2,0xffff)}
        name:=read_vector(&lr,1,1,0xff)
        if !read_done(&ar) || !read_done(&lr) {return .Decode}
        for offered in c.config.alpn {
            if offered==string(name) {c.selected_alpn=offered}
        }
        if c.selected_alpn=="" {return .Illegal_Parameter}
    }
    transcript_add(c,message)
    c.state=.Wait_Certificate_Or_Request
    return nil
}

@(private)
client_certificate_request :: proc(c:^Conn,message:[]u8) -> Error {
    r:=Reader{data=message[4:]}
    request_context:=read_vector(&r,1,0,0xff)
    _=read_vector(&r,2,2,0xffff)
    if !read_done(&r) {return .Decode}
    copy(c.request_context[:],request_context)
    c.request_context_len=len(request_context)
    c.certificate_requested=true
    transcript_add(c,message)
    c.state=.Wait_Certificate
    return nil
}

// Verifies the server's chain against the roots and the host, and keeps the leaf's key.
@(private)
client_certificate :: proc(c:^Conn,message:[]u8) -> Error {
    r:=Reader{data=message[4:]}
    if len(read_vector(&r,1,0,0xff))!=0 && !r.bad {return .Illegal_Parameter}
    list:=Reader{data=read_vector(&r,3,1,0xffffff)}
    if !read_done(&r) {return .Decode}
    ders:[CERTIFICATES_MAX][]u8
    count:=0
    for list.at<len(list.data) {
        der:=read_vector(&list,3,1,0xffffff)
        entry_extensions:=read_vector(&list,2,0,0xffff)
        if list.bad {return .Decode}
        // This client asks for no OCSP status nor timestamps: an entry carries none.
        if len(entry_extensions)>0 {return .Unsupported_Extension}
        if count==CERTIFICATES_MAX {return .Bad_Certificate}
        ders[count]=der
        count+=1
    }
    arena:mem.Arena
    mem.arena_init(&arena,c.scratch)
    allocator:=mem.arena_allocator(&arena)
    certificates,cerr:=make([]x509.Certificate,count,allocator)
    if cerr!=nil {return .Internal}
    chain,perr:=make([]^x509.Certificate,count,allocator)
    if perr!=nil {return .Internal}
    for der,i in ders[:count] {
        e:x509.Error
        certificates[i],e=x509.parse(der,allocator)
        if e==.Allocation_Failed {return .Internal}
        if e!=.None {return .Bad_Certificate}
        chain[i]=&certificates[i]
    }
    now:=c.config.time
    if now==({}) {now=time.now()}
    options:=x509.Verify_Options{roots=c.config.roots,intermediates=chain[1:],current_time=now,dns_name=c.config.host,required_eku=.Server_Auth}
    _,verr:=x509.verify_chain(chain[0],options,allocator)
    #partial switch verr {
    case .None:
    case .Expired,.Not_Yet_Valid: return .Certificate_Expired
    case .Unknown_Authority: return .Unknown_CA
    case .Unsupported_Algorithm: return .Unsupported_Certificate
    case .Allocation_Failed: return .Internal
    case: return .Bad_Certificate
    }
    leaf:=chain[0]
    #partial switch leaf.public_key_algorithm {
    case .ECDSA_P256,.ECDSA_P384:
        c.peer_key=ecdsa.Public_Key{}
        curve:ecdsa.Curve=.SECP256R1 if leaf.public_key_algorithm==.ECDSA_P256 else .SECP384R1
        if !ecdsa.public_key_set_bytes(&c.peer_key.(ecdsa.Public_Key),curve,leaf.ec_point) {return .Bad_Certificate}
    case .RSA:
        c.peer_key=rsa.Public_Key{}
        if !rsa.public_key_set_bytes(&c.peer_key.(rsa.Public_Key),leaf.rsa_n,leaf.rsa_e) {return .Unsupported_Certificate}
    case .Ed25519:
        c.peer_key=ed25519.Public_Key{}
        if !ed25519.public_key_set_bytes(&c.peer_key.(ed25519.Public_Key),leaf.ec_point) {return .Bad_Certificate}
    case:
        return .Unsupported_Certificate
    }
    transcript_add(c,message)
    c.state=.Wait_Certificate_Verify
    return nil
}

@(private)
client_certificate_verify :: proc(c:^Conn,message:[]u8) -> Error {
    r:=Reader{data=message[4:]}
    scheme:=read_u16(&r)
    signature:=read_vector(&r,2,1,0xffff)
    if !read_done(&r) {return .Decode}
    th:[HASH_MAX]u8
    content_buffer:[VERIFY_CONTENT_MAX]u8
    content:=verify_content(transcript_hash(c,&th),&content_buffer)
    valid:bool
    switch &key in c.peer_key {
    case ecdsa.Public_Key:
        p256:=ecdsa.curve(&key)==.SECP256R1
        switch {
        case scheme==ECDSA_P256_SHA256 && p256: valid=ecdsa.verify_asn1(&key,.SHA256,content,signature)
        case scheme==ECDSA_P384_SHA384 && !p256: valid=ecdsa.verify_asn1(&key,.SHA384,content,signature)
        case: return .Illegal_Parameter
        }
    case rsa.Public_Key:
        h:hash.Algorithm
        switch scheme {
        case RSA_PSS_RSAE_SHA256: h=.SHA256
        case RSA_PSS_RSAE_SHA384: h=.SHA384
        case RSA_PSS_RSAE_SHA512: h=.SHA512
        case: return .Illegal_Parameter
        }
        valid=rsa.verify_pss(&key,h,hash.DIGEST_SIZES[h],content,signature)
    case ed25519.Public_Key:
        if scheme!=ED25519 {return .Illegal_Parameter}
        valid=ed25519.verify(&key,content,signature)
    case:
        return .Unexpected_Message
    }
    if !valid {return .Decrypt_Error}
    transcript_add(c,message)
    c.state=.Wait_Server_Finished
    return nil
}

@(private)
client_finished :: proc(c:^Conn,message:[]u8) -> Error {
    size:=hash.DIGEST_SIZES[c.digest]
    if len(message)!=4+size {return .Decode}
    th,verify:[HASH_MAX]u8
    finished_compute(c.digest,c.read.secret[:],transcript_hash(c,&th),verify[:])
    if !crypto_equal(message[4:],verify[:size]) {return .Decrypt_Error}
    transcript_add(c,message)
    schedule_application(c)
    if c.certificate_requested {
        w:=Writer{data=c.scratch}
        body:=message_open(&w,.Certificate)
        put_vector(&w,1,c.request_context[:c.request_context_len])
        put_uint(&w,0,3)
        vector_close(&w,body,3)
        handshake_send(c,w.data[:w.at]) or_return
    }
    finished_compute(c.digest,c.write.secret[:],transcript_hash(c,&th),verify[:])
    w:=Writer{data=c.scratch}
    body:=message_open(&w,.Finished)
    put_bytes(&w,verify[:size])
    vector_close(&w,body,3)
    handshake_send(c,w.data[:w.at]) or_return
    direction_set(&c.read,c.suite,c.server_traffic[:])
    direction_set(&c.write,c.suite,c.client_traffic[:])
    wipe(c.client_traffic[:])
    wipe(c.server_traffic[:])
    c.peer_key=nil
    c.state=.Connected
    return nil
}

// A NewSessionTicket, read through and dropped: this package does not resume.
@(private)
client_ticket :: proc(body:[]u8) -> Error {
    r:=Reader{data=body}
    _=read_bytes(&r,8)
    _=read_vector(&r,1,0,0xff)
    _=read_vector(&r,2,1,0xffff)
    _=read_vector(&r,2,0,0xffff)
    return nil if read_done(&r) else .Decode
}
