package tls

// ACME (RFC 8555) with the TLS-ALPN-01 challenge (RFC 8737): a server that holds only its TLS
// port proves each name by presenting there, to connections that negotiate acme-tls/1, a
// self-signed certificate of the name that carries the SHA-256 of the challenge's key
// authorization. acme_order runs one order to its certificate chain; whoever serves the port
// presents the challenge credential while serve says so. renewal_due says when to order again.

import "base:runtime"
import "core:crypto/ecdsa"
import "core:crypto/hash"
import "core:crypto/x509"
import "core:encoding/asn1"
import "core:encoding/base64"
import "core:encoding/json"
import "core:encoding/pem"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:std/base"

Acme :: struct {
    directory:string, // the URL of the directory, https
    roots:[]^x509.Certificate, // the trust anchors of the directory's HTTPS
    transport:Transport,
    account_key:^ecdsa.Private_Key, // P-256: the account is this key
    contact:[]string, // "mailto:" addresses of the account, or none
    time:time.Time, // when the chains of the directory must be valid; zero is now
    data:rawptr,
    // Presents credential, which answers acme-tls/1 for one name, on the server while serving
    // is true.
    serve:proc(data:rawptr,credential:^Credential,serving:bool),
    // Waits seconds between polls; nil sleeps.
    wait:proc(data:rawptr,seconds:int),
    // What the directory said when it refused (Refused) or a challenge failed (Invalid).
    problem:[256]u8,
    problem_len:int,
}

Acme_Error :: enum u8 {
    None,
    Out_Of_Memory,
    Bad_Config,
    Transport, // a stream could not be opened, written or read
    Tls, // the HTTPS connection failed
    Malformed, // the directory answered what this client cannot read
    Refused, // the directory answered with a problem (acme_problem)
    Invalid, // an authorization or the order became invalid
    Timeout, // polls ran out before the directory decided
}

@(private) ACME_POLLS :: 30
@(private) ACME_WAIT_MAX :: 60
// The acmeIdentifier extension, 1.3.6.1.5.5.7.1.31 (RFC 8737, 6.1).
@(private) OID_ACME_IDENTIFIER :: [?]u8{0x2b,0x06,0x01,0x05,0x05,0x07,0x01,0x1f}
@(private) ACME_ALPN :: "acme-tls/1"

// The problem of the last Refused or Invalid.
acme_problem :: proc(a:^Acme) -> string {return string(a.problem[:a.problem_len])}

// Orders a certificate for domains whose key is certificate_key (P-256) and returns its chain,
// DER, leaf first, in allocator: one slice of chain and one of each certificate.
acme_order :: proc(a:^Acme,domains:[]string,certificate_key:^ecdsa.Private_Key,allocator:=context.allocator) -> (chain:[][]u8,err:Acme_Error) {
    if len(domains)==0 || a.account_key==nil || ecdsa.curve(a.account_key)!=.SECP256R1 || ecdsa.curve(certificate_key)!=.SECP256R1 || a.transport.dial==nil || a.serve==nil {
        return nil,.Bad_Config
    }
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena,allocator,allocator)
    defer mem.dynamic_arena_destroy(&arena)
    s:=Acme_Session{acme=a,allocator=base.dynamic_arena_allocator(&arena),scratch=allocator}
    a.problem_len=0
    acme_start(&s) or_return
    order_url,order:=acme_new_order(&s,domains) or_return
    for url in order.authorizations {acme_authorize(&s,url) or_return}
    der:=acme_finalize(&s,order_url,order,domains,certificate_key) or_return
    return chain_copy(der,certificate_key,allocator)
}

// Whether a certificate is due for renewal at now: a third of its lifetime or less is left.
renewal_due :: proc(certificate:^x509.Certificate,now:time.Time) -> bool {
    life:=time.diff(certificate.not_before,certificate.not_after)
    return time.diff(now,certificate.not_after)<=life/3
}

@(private)
Acme_Session :: struct {
    acme:^Acme,
    allocator:runtime.Allocator, // the arena of the order
    scratch:runtime.Allocator, // the TLS connections
    new_nonce,new_account,new_order:string,
    nonce:string,
    kid:string,
    jwk:string,
    thumbprint:string,
}

@(private) Acme_Directory :: struct {new_nonce:string `json:"newNonce"`,new_account:string `json:"newAccount"`,new_order:string `json:"newOrder"`}
@(private) Acme_Order :: struct {status:string,authorizations:[]string,finalize:string,certificate:string}
@(private) Acme_Identifier :: struct {kind:string `json:"type"`,value:string}
@(private) Acme_Challenge :: struct {kind:string `json:"type"`,url:string,token:string,status:string,error:Acme_Problem}
@(private) Acme_Authorization :: struct {status:string,identifier:Acme_Identifier,challenges:[]Acme_Challenge}
@(private) Acme_Problem :: struct {kind:string `json:"type"`,detail:string}

@(private)
acme_start :: proc(s:^Acme_Session) -> Acme_Error {
    r:=acme_http(s,"GET",s.acme.directory,nil) or_return
    if r.status!=200 {return .Malformed}
    d:Acme_Directory
    acme_json(s,r.body,&d) or_return
    if d.new_nonce=="" || d.new_account=="" || d.new_order=="" {return .Malformed}
    s.new_nonce,s.new_account,s.new_order=d.new_nonce,d.new_account,d.new_order

    public:[65]u8
    ecdsa.private_key_public_bytes(s.acme.account_key,public[:])
    x:=base64url(s,public[1:33]) or_return
    y:=base64url(s,public[33:]) or_return
    // The members in the order RFC 7638 hashes them.
    s.jwk=strings.concatenate({`{"crv":"P-256","kty":"EC","x":"`,x,`","y":"`,y,`"}`},s.allocator) or_else ""
    if s.jwk=="" {return .Out_Of_Memory}
    digest:[32]u8
    hash.hash_string_to_buffer(.SHA256,s.jwk,digest[:])
    s.thumbprint=base64url(s,digest[:]) or_return

    j:=json_begin(s) or_return
    json_raw(&j,`{"termsOfServiceAgreed":true`)
    if len(s.acme.contact)>0 {
        json_raw(&j,`,"contact":[`)
        for c,i in s.acme.contact {
            if i>0 {json_raw(&j,",")}
            json_text(&j,c)
        }
        json_raw(&j,"]")
    }
    json_raw(&j,"}")
    payload:=json_end(&j) or_return
    account:=acme_post(s,s.new_account,payload,true) or_return
    if account.status!=200 && account.status!=201 {return .Malformed}
    s.kid,_=header_value(account.headers,"Location")
    if s.kid=="" {return .Malformed}
    return nil
}

@(private)
acme_new_order :: proc(s:^Acme_Session,domains:[]string) -> (url:string,order:Acme_Order,err:Acme_Error) {
    j:=json_begin(s) or_return
    json_raw(&j,`{"identifiers":[`)
    for d,i in domains {
        if i>0 {json_raw(&j,",")}
        json_raw(&j,`{"type":"dns","value":`)
        json_text(&j,d)
        json_raw(&j,"}")
    }
    json_raw(&j,"]}")
    payload:=json_end(&j) or_return
    r:=acme_post(s,s.new_order,payload,false) or_return
    if r.status!=201 {return "",{},.Malformed}
    url,_=header_value(r.headers,"Location")
    acme_json(s,r.body,&order) or_return
    if url=="" || order.finalize=="" || len(order.authorizations)!=len(domains) {return "",{},.Malformed}
    return url,order,nil
}

// Proves the name of an authorization with TLS-ALPN-01, unless it is valid already.
@(private)
acme_authorize :: proc(s:^Acme_Session,url:string) -> Acme_Error {
    authorization:Acme_Authorization
    r:=acme_post(s,url,nil,false) or_return
    acme_json(s,r.body,&authorization) or_return
    if authorization.status=="valid" {return nil}
    challenge:^Acme_Challenge
    for &c in authorization.challenges {
        if c.kind=="tls-alpn-01" {challenge=&c}
    }
    if challenge==nil || challenge.token=="" || challenge.url=="" || authorization.identifier.kind!="dns" {return .Malformed}

    key:ecdsa.Private_Key
    if !ecdsa.private_key_generate(&key,.SECP256R1) {return .Out_Of_Memory}
    defer ecdsa.private_key_clear(&key)
    authorization_key:=strings.concatenate({challenge.token,".",s.thumbprint},s.allocator) or_else ""
    if authorization_key=="" {return .Out_Of_Memory}
    digest:[32]u8
    hash.hash_string_to_buffer(.SHA256,authorization_key,digest[:])
    oid:=OID_ACME_IDENTIFIER
    extension,aerr:=asn1.marshal(asn1.sequence({asn1.object_identifier(oid[:]),asn1.boolean(true),asn1.octet_string_wrap({asn1.octet_string(digest[:])})}),s.allocator)
    if aerr!=nil {return .Out_Of_Memory}
    public:[65]u8
    ecdsa.private_key_public_bytes(&key,public[:])
    now:=acme_now(s)
    names:=[]string{authorization.identifier.value}
    extensions:=[][]u8{extension}
    der,cerr:=certificate_make({names=names,public_key=public[:],not_before=time.time_add(now,-time.Hour),not_after=time.time_add(now,7*24*time.Hour),issuer=&key,extensions=extensions},s.allocator)
    if cerr!=nil {return .Out_Of_Memory if cerr==.Out_Of_Memory else .Malformed}
    chain,merr:=make([][]u8,1,s.allocator)
    if merr!=nil {return .Out_Of_Memory}
    chain[0]=der
    credential,ierr:=credential_init(chain,&key,ACME_ALPN,s.allocator)
    if ierr!=nil {return .Out_Of_Memory if ierr==.Out_Of_Memory else .Malformed}
    defer credential_destroy(&credential,s.allocator)
    s.acme.serve(s.acme.data,&credential,true)
    defer s.acme.serve(s.acme.data,&credential,false)

    acme_post(s,challenge.url,transmute([]u8)string("{}"),false) or_return
    for _ in 0..<ACME_POLLS {
        r=acme_post(s,url,nil,false) or_return
        authorization={}
        acme_json(s,r.body,&authorization) or_return
        switch authorization.status {
        case "valid":
            return nil
        case "invalid":
            for c in authorization.challenges {
                if c.kind=="tls-alpn-01" {acme_problem_set(s.acme,c.error)}
            }
            return .Invalid
        }
        acme_wait(s,r)
    }
    return .Timeout
}

// Sends the CSR, waits for the order to be valid and downloads its chain.
@(private)
acme_finalize :: proc(s:^Acme_Session,url:string,order:Acme_Order,domains:[]string,key:^ecdsa.Private_Key) -> (der:[][]u8,err:Acme_Error) {
    public:[65]u8
    ecdsa.private_key_public_bytes(key,public[:])
    san,e:=x509.marshal_ext_san(domains,nil,false,s.allocator)
    if e!=.None {return nil,.Out_Of_Memory}
    subject:=[]x509.DN_Attribute{{type=.Common_Name,value=domains[0]}}
    extensions:=[][]u8{san}
    info:[]u8
    info,e=x509.marshal_csr_info(subject,{algorithm=.ECDSA_P256,ec_point=public[:]},extensions,s.allocator)
    if e!=.None {return nil,.Out_Of_Memory}
    signature,signed:=ecdsa.sign_asn1(key,.SHA256,info,s.allocator)
    if !signed {return nil,.Out_Of_Memory}
    csr:[]u8
    csr,e=x509.marshal_csr(info,.ECDSA_SHA256,signature,s.allocator)
    if e!=.None {return nil,.Out_Of_Memory}
    csr_text:=base64url(s,csr) or_return
    j:=json_begin(s) or_return
    json_raw(&j,`{"csr":"`)
    json_raw(&j,csr_text)
    json_raw(&j,`"}`)
    payload:=json_end(&j) or_return

    current:=order
    r:=acme_post(s,order.finalize,payload,false) or_return
    for poll:=0;;poll+=1 {
        current={}
        acme_json(s,r.body,&current) or_return
        if current.status=="valid" && current.certificate!="" {break}
        if current.status=="invalid" {return nil,.Invalid}
        if poll==ACME_POLLS {return nil,.Timeout}
        acme_wait(s,r)
        r=acme_post(s,url,nil,false) or_return
    }
    r=acme_post(s,current.certificate,nil,false) or_return
    if r.status!=200 {return nil,.Malformed}
    list:[dynamic][]u8
    list.allocator=s.allocator
    rest:=r.body
    for {
        block,remaining,perr:=pem.decode(rest,s.allocator)
        if perr!=nil {return nil,.Malformed}
        if block==nil {break}
        if block.label==pem.LABEL_CERTIFICATE {
            if _,aerr:=append(&list,block.data[:]);aerr!=nil {return nil,.Out_Of_Memory}
        }
        rest=remaining
    }
    if len(list)==0 {return nil,.Malformed}
    return list[:],nil
}

// The chain in allocator, once its leaf holds the certificate's key.
@(private)
chain_copy :: proc(der:[][]u8,key:^ecdsa.Private_Key,allocator:runtime.Allocator) -> (chain:[][]u8,err:Acme_Error) {
    leaf,perr:=x509.parse(der[0],allocator)
    defer x509.destroy(&leaf,allocator)
    public:[65]u8
    ecdsa.private_key_public_bytes(key,public[:])
    if perr!=.None || leaf.public_key_algorithm!=.ECDSA_P256 || string(leaf.ec_point)!=string(public[:]) {return nil,.Malformed}
    merr:runtime.Allocator_Error
    chain,merr=make([][]u8,len(der),allocator)
    if merr!=nil {return nil,.Out_Of_Memory}
    for d,i in der {
        chain[i],merr=make([]u8,len(d),allocator)
        if merr!=nil {
            for c in chain[:i] {delete(c,allocator)}
            delete(chain,allocator)
            return nil,.Out_Of_Memory
        }
        copy(chain[i],d)
    }
    return chain,nil
}

@(private)
acme_now :: proc(s:^Acme_Session) -> time.Time {
    return s.acme.time if s.acme.time!=({}) else time.now()
}

// Waits what the directory asks in Retry-After, a second without it.
@(private)
acme_wait :: proc(s:^Acme_Session,r:Response) {
    seconds:=1
    if text,found:=header_value(r.headers,"Retry-After");found {
        if n,ok:=strconv.parse_int(text,10);ok {seconds=clamp(n,0,ACME_WAIT_MAX)}
    }
    if s.acme.wait!=nil {
        s.acme.wait(s.acme.data,seconds)
    } else {
        time.sleep(time.Duration(seconds)*time.Second)
    }
}

@(private)
acme_http :: proc(s:^Acme_Session,method,url:string,body:[]u8) -> (r:Response,err:Acme_Error) {
    a:=s.acme
    e:Http_Error
    r,e=https_request(a.transport,a.roots,a.time,method,url,body,"application/jose+json",s.allocator,s.scratch)
    switch e {
    case .None: return r,nil
    case .Out_Of_Memory: return r,.Out_Of_Memory
    case .Transport: return r,.Transport
    case .Tls: return r,.Tls
    case .Malformed: return r,.Malformed
    }
    return r,.Malformed
}

// A request signed by the account (RFC 8555, 6.2): with its key (jwk) for newAccount, else with
// its URL. A nil payload is a POST-as-GET. A badNonce is retried once with the new nonce.
@(private)
acme_post :: proc(s:^Acme_Session,url:string,payload:[]u8,jwk:bool) -> (r:Response,err:Acme_Error) {
    for attempt in 0..<2 {
        if s.nonce=="" {
            head:=acme_http(s,"HEAD",s.new_nonce,nil) or_return
            s.nonce,_=header_value(head.headers,"Replay-Nonce")
            if s.nonce=="" {return {},.Malformed}
        }
        body:=jws_make(s,url,payload,jwk) or_return
        r=acme_http(s,"POST",url,body) or_return
        s.nonce,_=header_value(r.headers,"Replay-Nonce")
        if r.status<400 {return r,nil}
        problem:Acme_Problem
        _=json.unmarshal(r.body,&problem,allocator=s.allocator)
        if attempt==0 && problem.kind=="urn:ietf:params:acme:error:badNonce" {continue}
        acme_problem_set(s.acme,problem)
        return r,.Refused
    }
    return r,.Refused
}

@(private)
acme_problem_set :: proc(a:^Acme,problem:Acme_Problem) {
    text:=fmt.bprintf(a.problem[:],"%s: %s",problem.kind,problem.detail)
    a.problem_len=len(text)
}

@(private)
jws_make :: proc(s:^Acme_Session,url:string,payload:[]u8,jwk:bool) -> (body:[]u8,err:Acme_Error) {
    j:=json_begin(s) or_return
    json_raw(&j,`{"alg":"ES256",`)
    if jwk {
        json_raw(&j,`"jwk":`)
        json_raw(&j,s.jwk)
    } else {
        json_raw(&j,`"kid":`)
        json_text(&j,s.kid)
    }
    json_raw(&j,`,"nonce":`)
    json_text(&j,s.nonce)
    json_raw(&j,`,"url":`)
    json_text(&j,url)
    json_raw(&j,"}")
    protected:=base64url(s,json_end(&j) or_return) or_return
    encoded:=base64url(s,payload) or_return
    signing_input:=strings.concatenate({protected,".",encoded},s.allocator) or_else ""
    if signing_input=="" {return nil,.Out_Of_Memory}
    signature:[64]u8
    if !ecdsa.sign_raw(s.acme.account_key,.SHA256,transmute([]u8)signing_input,signature[:]) {return nil,.Out_Of_Memory}
    signature_text:=base64url(s,signature[:]) or_return
    j=json_begin(s) or_return
    json_raw(&j,`{"protected":"`)
    json_raw(&j,protected)
    json_raw(&j,`","payload":"`)
    json_raw(&j,encoded)
    json_raw(&j,`","signature":"`)
    json_raw(&j,signature_text)
    json_raw(&j,`"}`)
    return json_end(&j)
}

@(private)
acme_json :: proc(s:^Acme_Session,body:[]u8,out:^$T) -> Acme_Error {
    e:=json.unmarshal(body,out,allocator=s.allocator)
    if e==nil {return nil}
    if code,is_error:=e.(json.Error);is_error && code==.Out_Of_Memory {return .Out_Of_Memory}
    return .Malformed
}

@(private)
base64url :: proc(s:^Acme_Session,data:[]u8) -> (text:string,err:Acme_Error) {
    if len(data)==0 {return "",nil}
    e:runtime.Allocator_Error
    text,e=base64.encode(data,base64.ENC_URL_TABLE,s.allocator,{.No_Padding})
    return text,nil if e==nil else .Out_Of_Memory
}

// JSON text written in the arena of the order.
@(private)
Json :: struct {out:[dynamic]u8,failed:bool}

@(private)
json_begin :: proc(s:^Acme_Session) -> (j:Json,err:Acme_Error) {
    e:runtime.Allocator_Error
    j.out,e=make([dynamic]u8,0,512,s.allocator)
    return j,nil if e==nil else .Out_Of_Memory
}

@(private)
json_raw :: proc(j:^Json,text:string) {
    if _,e:=append(&j.out,text);e!=nil {j.failed=true}
}

// A JSON string of text, quoted and escaped.
@(private)
json_text :: proc(j:^Json,text:string) {
    hex:="0123456789abcdef"
    json_raw(j,`"`)
    for b in transmute([]u8)text {
        switch {
        case b=='"' || b=='\\':
            json_raw(j,`\`)
            if _,e:=append(&j.out,b);e!=nil {j.failed=true}
        case b<0x20:
            escape:=[6]u8{'\\','u','0','0',hex[b>>4],hex[b&15]}
            json_raw(j,string(escape[:]))
        case:
            if _,e:=append(&j.out,b);e!=nil {j.failed=true}
        }
    }
    json_raw(j,`"`)
}

@(private)
json_end :: proc(j:^Json) -> (text:[]u8,err:Acme_Error) {
    if j.failed {return nil,.Out_Of_Memory}
    return j.out[:],nil
}
