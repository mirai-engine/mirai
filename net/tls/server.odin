package tls

import "core:crypto"
import "core:crypto/ecdsa"
import "core:crypto/hash"
import "core:crypto/x509"
import "core:mem"

@(private)
server_message :: proc(c:^Conn,message:[]u8) -> Error {
    kind:=Message(message[0])
    #partial switch c.state {
    case .Wait_Client_Hello:
        if kind==.Client_Hello {return server_client_hello(c,message)}
    case .Wait_Client_Finished:
        if kind==.Finished {return server_finished(c,message)}
    case .Connected:
        if kind==.Key_Update {return key_update_receive(c,message[4:])}
    }
    return .Unexpected_Message
}

@(private)
server_client_hello :: proc(c:^Conn,message:[]u8) -> Error {
    r:=Reader{data=message[4:]}
    _=read_u16(&r) // legacy_version: supported_versions decides (RFC 8446, 4.2.1)
    _=read_bytes(&r,32)
    session_id:=read_vector(&r,1,0,32)
    suites:=read_vector(&r,2,2,0xfffe)
    compression:=read_vector(&r,1,1,0xff)
    if !r.bad && r.at==len(r.data) {return .Protocol_Version} // a hello of TLS 1.2 or older
    extensions_data:=read_vector(&r,2,0,0xffff)
    if !read_done(&r) || len(suites)%2!=0 {return .Decode}
    extensions:Extensions
    extensions_parse(extensions_data,&extensions) or_return
    versions,has_versions:=extension_find(&extensions,EXT_SUPPORTED_VERSIONS)
    if !has_versions || !versions_include(versions) {return .Protocol_Version}
    if len(compression)!=1 || compression[0]!=0 {return .Illegal_Parameter}
    if _,psk:=extension_find(&extensions,EXT_PRE_SHARED_KEY);psk && extensions.list[extensions.count-1].kind!=EXT_PRE_SHARED_KEY {
        return .Illegal_Parameter
    }
    _,early:=extension_find(&extensions,EXT_EARLY_DATA)
    if c.retried {
        if early || len(session_id)!=c.session_id_len || !crypto_equal(session_id,c.session_id[:c.session_id_len]) {return .Illegal_Parameter}
    } else {
        copy(c.session_id[:],session_id)
        c.session_id_len=len(session_id)
        if early {c.early_skip=EARLY_SKIP_MAX}
    }

    if !c.retried {
        chosen:=false
        for s in Suite {
            if s in c.config.suites && codes_include(suites,suite_code(s)) {
                c.suite,chosen=s,true
                break
            }
        }
        if !chosen {return .Handshake_Failure}
        c.digest=suite_hash(c.suite)
    } else if !codes_include(suites,suite_code(c.suite)) {
        return .Illegal_Parameter
    }

    schemes,has_schemes:=extension_find(&extensions,EXT_SIGNATURE_ALGORITHMS)
    if !has_schemes {return .Missing_Extension}
    {
        sr:=Reader{data=schemes}
        list:=read_vector(&sr,2,2,0xfffe)
        if !read_done(&sr) || len(list)%2!=0 {return .Decode}
        if !codes_include(list,ECDSA_P256_SHA256) {return .Handshake_Failure}
    }

    share,retry,err:=server_key_share(c,&extensions)
    if err!=nil {return err}
    server_name_take(c,&extensions) or_return
    server_alpn_take(c,&extensions) or_return
    credential:=credential_select(c)
    if credential==nil {return .Unrecognized_Name}

    transcript_add(c,message)
    if retry {return server_retry(c)}
    return server_flight(c,share,credential)
}

// The client's key share the server takes; retry when it has to ask for another group.
@(private)
server_key_share :: proc(c:^Conn,extensions:^Extensions) -> (share:[]u8,retry:bool,err:Error) {
    groups_data,has_groups:=extension_find(extensions,EXT_SUPPORTED_GROUPS)
    shares_data,has_shares:=extension_find(extensions,EXT_KEY_SHARE)
    if !has_groups || !has_shares {return nil,false,.Missing_Extension}
    gr:=Reader{data=groups_data}
    groups:=read_vector(&gr,2,2,0xfffe)
    if !read_done(&gr) || len(groups)%2!=0 {return nil,false,.Decode}
    sr:=Reader{data=shares_data}
    list:=Reader{data=read_vector(&sr,2,0,0xffff)}
    if !read_done(&sr) {return nil,false,.Decode}
    shares:[Group][]u8
    count:=0
    codes:[EXTENSIONS_MAX]int
    for list.at<len(list.data) {
        code:=read_u16(&list)
        key:=read_vector(&list,2,1,0xffff)
        if list.bad {return nil,false,.Decode}
        if count==len(codes) {return nil,false,.Decode}
        for x in codes[:count] {
            if x==code {return nil,false,.Illegal_Parameter}
        }
        codes[count]=code
        count+=1
        if !codes_include(groups,code) {return nil,false,.Illegal_Parameter}
        if g,known:=group_of(code);known {shares[g]=key}
    }
    if c.retried {
        // The second hello carries a share for the group asked for, and only that one.
        if count!=1 || shares[c.group]==nil {return nil,false,.Illegal_Parameter}
        return shares[c.group],false,nil
    }
    for g in Group {
        if g in c.config.groups && shares[g]!=nil {
            c.group=g
            return shares[g],false,nil
        }
    }
    for g in Group {
        if g in c.config.groups && codes_include(groups,group_code(g)) {
            c.group=g
            return nil,true,nil
        }
    }
    return nil,false,.Handshake_Failure
}

@(private)
server_name_take :: proc(c:^Conn,extensions:^Extensions) -> Error {
    data,found:=extension_find(extensions,EXT_SERVER_NAME)
    if !found {return nil}
    r:=Reader{data=data}
    list:=Reader{data=read_vector(&r,2,1,0xffff)}
    if !read_done(&r) {return .Decode}
    c.server_name_len=0
    for list.at<len(list.data) {
        kind:=read_u8(&list)
        name:=read_vector(&list,2,1,0xffff)
        if list.bad {return .Decode}
        if kind!=0 || c.server_name_len>0 {continue}
        if len(name)>len(c.server_name) {return .Unrecognized_Name}
        for b,i in name {
            if b<=' ' || b>=0x7f {return .Illegal_Parameter}
            c.server_name[i]=b+32 if b>='A' && b<='Z' else b
        }
        c.server_name_len=len(name)
        if c.server_name[c.server_name_len-1]=='.' {c.server_name_len-=1}
    }
    return nil
}

@(private)
server_alpn_take :: proc(c:^Conn,extensions:^Extensions) -> Error {
    data,found:=extension_find(extensions,EXT_ALPN)
    if !found || len(c.config.alpn)==0 {return nil}
    r:=Reader{data=data}
    list:=read_vector(&r,2,2,0xffff)
    if !read_done(&r) {return .Decode}
    for name in c.config.alpn {
        lr:=Reader{data=list}
        for lr.at<len(lr.data) {
            offered:=read_vector(&lr,1,1,0xff)
            if lr.bad {return .Decode}
            if string(offered)==name {
                c.selected_alpn=name
                return nil
            }
        }
    }
    return .No_Application_Protocol
}

// The credential for the name and protocol of the connection: one made for its protocol when
// there is one, else the first whose leaf holds the name, else the first of all.
@(private)
credential_select :: proc(c:^Conn) -> ^Credential {
    name:=server_name(c)
    own:=credential_for_protocol(c)
    fallback:^Credential
    for &cred in c.config.credentials {
        if own!=(cred.alpn!="") || own && cred.alpn!=c.selected_alpn {continue}
        if len(cred.chain)==0 || ecdsa.curve(&cred.key)!=.SECP256R1 {continue}
        if name=="" || x509.verify_hostname(&cred.leaf,name)==.None {return &cred}
        if fallback==nil && !own {fallback=&cred}
    }
    return fallback
}

// Whether the protocol of the connection is served only with its own credentials.
@(private)
credential_for_protocol :: proc(c:^Conn) -> bool {
    if c.selected_alpn=="" {return false}
    for cred in c.config.credentials {
        if cred.alpn==c.selected_alpn {return true}
    }
    return false
}

@(private)
server_retry :: proc(c:^Conn) -> Error {
    transcript_restart(c)
    w:=Writer{data=c.scratch}
    body:=message_open(&w,.Server_Hello)
    server_hello_head(c,&w,RETRY_RANDOM)
    extensions:=vector_open(&w,2)
    put_u16(&w,EXT_SUPPORTED_VERSIONS);put_u16(&w,2);put_u16(&w,VERSION_TLS13)
    put_u16(&w,EXT_KEY_SHARE);put_u16(&w,2);put_u16(&w,group_code(c.group))
    vector_close(&w,extensions,2)
    vector_close(&w,body,3)
    if w.bad {return .Internal}
    handshake_send(c,w.data[:w.at]) or_return
    if c.session_id_len>0 {record_seal(c,.Change_Cipher_Spec,{1}) or_return}
    c.retried=true
    return nil
}

@(private)
server_hello_head :: proc(c:^Conn,w:^Writer,random:[32]u8) {
    random:=random
    put_u16(w,VERSION_TLS12)
    put_bytes(w,random[:])
    put_vector(w,1,c.session_id[:c.session_id_len])
    put_u16(w,suite_code(c.suite))
    put_u8(w,0)
}

// ServerHello to Finished, after the client's hello, with the credential it picked.
@(private)
server_flight :: proc(c:^Conn,share:[]u8,credential:^Credential) -> Error {
    public_buffer:[65]u8
    public:=key_share_make(c,&public_buffer) or_return
    shared_buffer:[HASH_MAX]u8
    shared:=key_exchange(c,share,&shared_buffer) or_return
    defer wipe(shared_buffer[:])

    w:=Writer{data=c.scratch}
    random:[32]u8
    crypto.rand_bytes(random[:])
    body:=message_open(&w,.Server_Hello)
    server_hello_head(c,&w,random)
    extensions:=vector_open(&w,2)
    put_u16(&w,EXT_SUPPORTED_VERSIONS);put_u16(&w,2);put_u16(&w,VERSION_TLS13)
    put_u16(&w,EXT_KEY_SHARE)
    entry:=vector_open(&w,2)
    put_u16(&w,group_code(c.group))
    put_vector(&w,2,public)
    vector_close(&w,entry,2)
    vector_close(&w,extensions,2)
    vector_close(&w,body,3)
    if w.bad {return .Internal}
    handshake_send(c,w.data[:w.at]) or_return
    if c.session_id_len>0 && !c.retried {record_seal(c,.Change_Cipher_Spec,{1}) or_return}

    schedule_handshake(c,shared)
    direction_set(&c.write,c.suite,c.server_traffic[:])
    direction_set(&c.read,c.suite,c.client_traffic[:])

    w=Writer{data=c.scratch}
    body=message_open(&w,.Encrypted_Extensions)
    extensions=vector_open(&w,2)
    if c.selected_alpn!="" {
        put_u16(&w,EXT_ALPN)
        outer:=vector_open(&w,2)
        list:=vector_open(&w,2)
        put_vector(&w,1,transmute([]u8)c.selected_alpn)
        vector_close(&w,list,2)
        vector_close(&w,outer,2)
    }
    vector_close(&w,extensions,2)
    vector_close(&w,body,3)
    if w.bad {return .Internal}
    handshake_send(c,w.data[:w.at]) or_return

    w=Writer{data=c.scratch}
    body=message_open(&w,.Certificate)
    put_u8(&w,0)
    list:=vector_open(&w,3)
    for der in credential.chain {
        put_vector(&w,3,der)
        put_u16(&w,0)
    }
    vector_close(&w,list,3)
    vector_close(&w,body,3)
    if w.bad {return .Internal}
    handshake_send(c,w.data[:w.at]) or_return

    th:[HASH_MAX]u8
    content_buffer:[VERIFY_CONTENT_MAX]u8
    content:=verify_content(transcript_hash(c,&th),&content_buffer)
    signature_memory:[256]u8
    arena:mem.Arena
    mem.arena_init(&arena,signature_memory[:])
    signature,signed:=ecdsa.sign_asn1(&credential.key,.SHA256,content,mem.arena_allocator(&arena))
    if !signed {return .Internal}
    w=Writer{data=c.scratch}
    body=message_open(&w,.Certificate_Verify)
    put_u16(&w,ECDSA_P256_SHA256)
    put_vector(&w,2,signature)
    vector_close(&w,body,3)
    if w.bad {return .Internal}
    handshake_send(c,w.data[:w.at]) or_return

    size:=hash.DIGEST_SIZES[c.digest]
    verify:[HASH_MAX]u8
    finished_compute(c.digest,c.write.secret[:],transcript_hash(c,&th),verify[:])
    w=Writer{data=c.scratch}
    body=message_open(&w,.Finished)
    put_bytes(&w,verify[:size])
    vector_close(&w,body,3)
    handshake_send(c,w.data[:w.at]) or_return

    schedule_application(c)
    direction_set(&c.write,c.suite,c.server_traffic[:])
    c.state=.Wait_Client_Finished
    return nil
}

@(private)
server_finished :: proc(c:^Conn,message:[]u8) -> Error {
    size:=hash.DIGEST_SIZES[c.digest]
    if len(message)!=4+size {return .Decode}
    th,expected:[HASH_MAX]u8
    finished_compute(c.digest,c.read.secret[:],transcript_hash(c,&th),expected[:])
    if !crypto_equal(message[4:],expected[:size]) {return .Decrypt_Error}
    transcript_add(c,message)
    direction_set(&c.read,c.suite,c.client_traffic[:])
    wipe(c.client_traffic[:])
    wipe(c.server_traffic[:])
    c.early_skip=0
    c.state=.Connected
    return nil
}

@(private)
versions_include :: proc(data:[]u8) -> bool {
    r:=Reader{data=data}
    list:=read_vector(&r,1,2,0xfe)
    return read_done(&r) && len(list)%2==0 && codes_include(list,VERSION_TLS13)
}

// Whether a list of 16-bit codes holds code.
@(private)
codes_include :: proc(list:[]u8,code:int) -> bool {
    for i:=0;i+1<len(list);i+=2 {
        if int(list[i])<<8|int(list[i+1])==code {return true}
    }
    return false
}
