package tls

import "core:crypto"
import "core:crypto/ecdsa"
import "core:crypto/hash"
import "core:crypto/x509"
import "core:encoding/asn1"
import "core:encoding/base64"
import "core:encoding/json"
import "core:encoding/pem"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

// The server that holds port 443 of the names being ordered: a credential of its own and the
// challenge credentials acme_order asks it to serve.
@(private="file")
Site :: struct {
    own:Test_Identity,
    credentials:[4]Credential,
    count:int,
    served:int, // challenge credentials it was asked to serve
}

@(private="file")
site_serve :: proc(data:rawptr,credential:^Credential,serving:bool) {
    f:=(^Fake)(data)
    s:=&f.site
    if serving {
        s.credentials[s.count]=credential^
        s.count+=1
        s.served+=1
        return
    }
    for i in 0..<s.count {
        if s.credentials[i].leaf.raw_tbs==nil || raw_data(s.credentials[i].chain)!=raw_data(credential.chain) {continue}
        s.credentials[i]=s.credentials[s.count-1]
        s.count-=1
        return
    }
}

@(private="file")
Fake_Stream :: struct {conn:^Conn,request:[dynamic]u8,answered:bool}

@(private="file")
Fake_Authorization :: struct {domain:string,token:string,status:string,polls:int}

@(private="file")
Fake_Order :: struct {domains:[dynamic]string,authorizations:[dynamic]int,status:string,polls:int,chain:[]u8}

// An ACME directory at https://acme.test over in-memory streams: one account, its orders and
// their authorizations, which it validates against the site by TLS-ALPN-01.
@(private="file")
Fake :: struct {
    t:^testing.T,
    ca,https:Test_Identity,
    https_credentials:[1]Credential,
    https_alpn:[1]string,
    site:Site,
    streams:[16]Fake_Stream,
    nonces_issued:int,
    nonces_used:[512]bool,
    account:ecdsa.Public_Key,
    account_jwk:string,
    has_account:bool,
    orders:[dynamic]Fake_Order,
    authorizations:[dynamic]Fake_Authorization,
    lifetime:time.Duration,
    bad_nonce_sent:bool,
    validations:int,
    waits:int,
}

@(private="file") BASE :: "https://acme.test"

@(private="file")
fake_transport :: proc(f:^Fake) -> Transport {
    return {
        data=f,
        dial=proc(data:rawptr,host:string,port:int) -> (uintptr,bool) {
            f:=(^Fake)(data)
            if host!="acme.test" || port!=443 {return 0,false}
            for &s,i in f.streams {
                if s.conn!=nil {continue}
                c,err:=create({credentials=f.https_credentials[:],alpn=f.https_alpn[:]},.Server)
                if err!=nil {return 0,false}
                s={conn=c}
                return uintptr(i),true
            }
            return 0,false
        },
        read=proc(data:rawptr,stream:uintptr,buffer:[]u8) -> (int,bool) {
            s:=&(^Fake)(data).streams[stream]
            out:=pending(s.conn)
            if len(out)==0 {return 0,s.answered}
            n:=copy(buffer,out)
            sent(s.conn,n)
            return n,true
        },
        write=proc(data:rawptr,stream:uintptr,bytes:[]u8) -> bool {
            f:=(^Fake)(data)
            s:=&f.streams[stream]
            for at:=0;at<len(bytes); {
                taken,err:=receive(s.conn,bytes[at:])
                at+=taken
                plain:[4096]u8
                for {
                    n,_:=read(s.conn,plain[:])
                    if n==0 {break}
                    append(&s.request,..plain[:n])
                }
                if err!=nil {return err==.Closed}
                if taken==0 {break}
            }
            if !s.answered && fake_request_complete(s.request[:]) {
                fake_answer(f,s)
                s.answered=true
            }
            return true
        },
        close=proc(data:rawptr,stream:uintptr) {
            s:=&(^Fake)(data).streams[stream]
            destroy(s.conn)
            delete(s.request)
            s^={}
        },
    }
}

@(private="file")
fake_request_complete :: proc(request:[]u8) -> bool {
    return response_complete(request,!strings.has_prefix(string(request),"POST"))
}

@(private="file")
Fake_Reply :: struct {status:int,location:string,content_type:string,retry_after:bool,body:string}

@(private="file")
fake_answer :: proc(f:^Fake,s:^Fake_Stream) {
    text:=string(s.request[:])
    end:=strings.index(text,"\r\n\r\n")
    line:=strings.split(text[:strings.index(text,"\r\n")]," ",context.temp_allocator)
    method,path:=line[0],line[1]
    body:=s.request[end+4:]
    reply:=fake_route(f,method,path,body)
    nonce:=fmt.tprintf("nonce-%d",f.nonces_issued)
    f.nonces_issued+=1
    response:=fmt.tprintf("HTTP/1.1 %d X\r\nReplay-Nonce: %s\r\nContent-Type: %s\r\n%s%sContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        reply.status,nonce,reply.content_type if reply.content_type!="" else "application/json",
        fmt.tprintf("Location: %s\r\n",reply.location) if reply.location!="" else "",
        "Retry-After: 0\r\n" if reply.retry_after else "",
        len(reply.body),reply.body if method!="HEAD" else "")
    for at:=0;at<len(response); {
        n,err:=write(s.conn,transmute([]u8)response[at:])
        if err!=nil {break}
        at+=n
        if n==0 {break}
    }
    close(s.conn)
}

@(private="file")
problem :: proc(kind,detail:string) -> Fake_Reply {
    return {status=400,content_type="application/problem+json",body=fmt.tprintf(`{{"type":"urn:ietf:params:acme:error:%s","detail":"%s"}}`,kind,detail)}
}

@(private="file")
fake_route :: proc(f:^Fake,method,path:string,body:[]u8) -> Fake_Reply {
    t:=f.t
    switch {
    case method=="GET" && path=="/directory":
        return {status=200,body=`{"newNonce":"`+BASE+`/nonce","newAccount":"`+BASE+`/account","newOrder":"`+BASE+`/order","meta":{"termsOfService":"x"}}`}
    case method=="HEAD" && path=="/nonce":
        return {status=200}
    case method!="POST":
        return {status=405}
    }
    payload,valid,fresh:=fake_jws(f,path,body)
    if !fresh {return problem("badNonce","the nonce is not one this directory gave")}
    if !valid {return problem("malformed","the request is not signed by the account")}
    switch {
    case path=="/account":
        return {status=201,location=BASE+"/acct/1",body=`{"status":"valid"}`}
    case path=="/order":
        if !f.bad_nonce_sent {
            f.bad_nonce_sent=true
            return problem("badNonce","retry with the new nonce")
        }
        Request :: struct {identifiers:[]Acme_Identifier}
        r:Request
        if json.unmarshal(payload,&r,allocator=context.temp_allocator)!=nil || len(r.identifiers)==0 {return problem("malformed","no identifiers")}
        order:Fake_Order
        order.status="pending"
        for id in r.identifiers {
            token:[16]u8
            crypto.rand_bytes(token[:])
            append(&order.domains,strings.clone(id.value))
            append(&order.authorizations,len(f.authorizations))
            append(&f.authorizations,Fake_Authorization{domain=strings.clone(id.value),token=base64.encode(token[:],base64.ENC_URL_TABLE,options={.No_Padding}),status="pending"})
        }
        append(&f.orders,order)
        return {status=201,location=fmt.tprintf("%s/order/%d",BASE,len(f.orders)-1),body=fake_order_json(f,len(f.orders)-1)}
    case strings.has_prefix(path,"/authz/"):
        i:=fake_index(path,len(f.authorizations)) or_else -1
        if i<0 {return {status=404}}
        a:=&f.authorizations[i]
        reply:=Fake_Reply{status=200}
        if a.status=="processing" {
            // The first poll after the challenge finds it still working.
            a.polls+=1
            if a.polls>1 {a.status="valid"}
            reply.retry_after=true
        }
        status:=a.status if a.status!="processing" else "pending"
        reply.body=fmt.tprintf(`{{"status":"%s","identifier":{{"type":"dns","value":"%s"}},"challenges":[{{"type":"http-01","url":"%s/x","token":"t","status":"pending"}},{{"type":"tls-alpn-01","url":"%s/chal/%d","token":"%s","status":"%s"}}]}}`,
            status,a.domain,BASE,BASE,i,a.token,status)
        return reply
    case strings.has_prefix(path,"/chal/"):
        i:=fake_index(path,len(f.authorizations)) or_else -1
        if i<0 {return {status=404}}
        a:=&f.authorizations[i]
        if a.status=="pending" {a.status="processing" if fake_validate(f,a) else "invalid"}
        return {status=200,body=fmt.tprintf(`{{"type":"tls-alpn-01","status":"processing","token":"%s"}}`,a.token)}
    case strings.has_prefix(path,"/finalize/"):
        i:=fake_index(path,len(f.orders)) or_else -1
        if i<0 {return {status=404}}
        return fake_finalize(f,i,payload)
    case strings.has_prefix(path,"/order/"):
        i:=fake_index(path,len(f.orders)) or_else -1
        if i<0 {return {status=404}}
        o:=&f.orders[i]
        if o.status=="processing" {o.status="valid"}
        return {status=200,body=fake_order_json(f,i)}
    case strings.has_prefix(path,"/cert/"):
        i:=fake_index(path,len(f.orders)) or_else -1
        if i<0 || f.orders[i].chain==nil {return {status=404}}
        return {status=200,content_type="application/pem-certificate-chain",body=string(f.orders[i].chain)}
    }
    testing.expectf(t,false,"the fake directory has no %s",path)
    return {status=404}
}

@(private="file")
fake_index :: proc(path:string,count:int) -> (int,bool) {
    i,ok:=strconv.parse_int(path[strings.last_index_byte(path,'/')+1:],10)
    return i,ok && i>=0 && i<count
}

@(private="file")
fake_order_json :: proc(f:^Fake,i:int) -> string {
    o:=&f.orders[i]
    all_valid:=true
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,`{"authorizations":[`)
    for a,k in o.authorizations {
        if k>0 {strings.write_byte(&b,',')}
        fmt.sbprintf(&b,`"%s/authz/%d"`,BASE,a)
        if f.authorizations[a].status!="valid" {all_valid=false}
    }
    if o.status=="pending" && all_valid {o.status="ready"}
    fmt.sbprintf(&b,`],"finalize":"%s/finalize/%d","status":"%s"`,BASE,i,o.status)
    if o.status=="valid" {fmt.sbprintf(&b,`,"certificate":"%s/cert/%d"`,BASE,i)}
    strings.write_byte(&b,'}')
    return strings.to_string(b)
}

// Checks the JWS of a request: its nonce, its URL and the account's signature.
@(private="file")
fake_jws :: proc(f:^Fake,path:string,body:[]u8) -> (payload:[]u8,valid,fresh:bool) {
    Jws :: struct {protected,payload,signature:string}
    Jwk :: struct {crv,kty,x,y:string}
    Protected :: struct {alg,nonce,url,kid:string,jwk:Jwk}
    jws:Jws
    if json.unmarshal(body,&jws,allocator=context.temp_allocator)!=nil {return}
    header_bytes:=decode64(jws.protected) or_return
    header:Protected
    if json.unmarshal(header_bytes,&header,allocator=context.temp_allocator)!=nil {return}
    n,parsed:=strconv.parse_int(strings.trim_prefix(header.nonce,"nonce-"),10)
    if !parsed || n<0 || n>=f.nonces_issued || f.nonces_used[n] {return nil,false,false}
    f.nonces_used[n]=true
    fresh=true
    if header.alg!="ES256" || header.url!=strings.concatenate({BASE,path},context.temp_allocator) {return}
    if path=="/account" {
        x:=decode64(header.jwk.x) or_return
        y:=decode64(header.jwk.y) or_return
        point:=make([]u8,65,context.temp_allocator)
        point[0]=4
        copy(point[1:],x)
        copy(point[33:],y)
        if header.jwk.crv!="P-256" || len(x)!=32 || len(y)!=32 || !ecdsa.public_key_set_bytes(&f.account,.SECP256R1,point) {return}
        delete(f.account_jwk)
        f.account_jwk=fmt.aprintf(`{{"crv":"P-256","kty":"EC","x":"%s","y":"%s"}}`,header.jwk.x,header.jwk.y)
        f.has_account=true
    } else if !f.has_account || header.kid!=BASE+"/acct/1" {
        return
    }
    signature:=decode64(jws.signature) or_return
    signed:=strings.concatenate({jws.protected,".",jws.payload},context.temp_allocator)
    if !ecdsa.verify_raw(&f.account,.SHA256,transmute([]u8)signed,signature) {return}
    if jws.payload=="" {return nil,true,true}
    payload=decode64(jws.payload) or_return
    return payload,true,true
}

@(private="file")
decode64 :: proc(text:string) -> ([]u8,bool) {
    b,err:=base64.decode(text,base64.DEC_URL_TABLE,allocator=context.temp_allocator,options={.No_Padding})
    return b,err==nil
}

// TLS-ALPN-01 (RFC 8737, 3): a connection to the site for the name and acme-tls/1 must get a
// certificate of that name with the hash of the key authorization in a critical acmeIdentifier.
@(private="file")
fake_validate :: proc(f:^Fake,a:^Fake_Authorization) -> bool {
    f.validations+=1
    server,_:=create({credentials=f.site.credentials[:f.site.count],alpn={"http/1.1","acme-tls/1"}},.Server)
    defer destroy(server)
    // A validator trusts no chain but the extension, while this package's client refuses the
    // critical acmeIdentifier it does not interpret: the client stops at the certificate, which
    // is what the validation reads.
    client,_:=create({host=a.domain,roots={&f.ca.certificate},alpn={"acme-tls/1"}},.Client)
    defer destroy(client)
    if pump(client,server)!=.Bad_Certificate || protocol(server)!=ACME_ALPN {return false}
    presented:=credential_select(server)
    if presented==nil {return false}
    leaf:=&presented.leaf
    if x509.verify_hostname(leaf,a.domain)!=.None {return false}
    key_authorization:=strings.concatenate({a.token,".",thumbprint(f.account_jwk)},context.temp_allocator)
    digest:[32]u8
    hash.hash_string_to_buffer(.SHA256,key_authorization,digest[:])
    oid:=OID_ACME_IDENTIFIER
    for e in leaf.extensions {
        if string(e.oid)!=string(oid[:]) {continue}
        cursor:asn1.Cursor
        asn1.cursor_init(&cursor,e.value)
        value,err:=asn1.read_octet_string(&cursor)
        return e.critical && err==.None && string(value)==string(digest[:])
    }
    return false
}

@(private="file")
thumbprint :: proc(jwk:string) -> string {
    digest:[32]u8
    hash.hash_string_to_buffer(.SHA256,jwk,digest[:])
    return base64.encode(digest[:],base64.ENC_URL_TABLE,context.temp_allocator,{.No_Padding})
}

// Issues the certificate of an order from the key of its CSR.
@(private="file")
fake_finalize :: proc(f:^Fake,i:int,payload:[]u8) -> Fake_Reply {
    o:=&f.orders[i]
    _=fake_order_json(f,i)
    if o.status!="ready" {return problem("orderNotReady","the authorizations are not valid")}
    Request :: struct {csr:string}
    r:Request
    if json.unmarshal(payload,&r,allocator=context.temp_allocator)!=nil {return problem("malformed","no csr")}
    csr,ok:=decode64(r.csr)
    if !ok {return problem("badCSR","not base64url")}
    // CertificationRequest { info { version, subject, spki { algorithm, key }, ... }, ... }
    c:asn1.Cursor
    asn1.cursor_init(&c,csr)
    outer,_:=asn1.read_sequence(&c)
    info,_:=asn1.read_sequence(&outer)
    _,_=asn1.read_i64(&info)
    _=asn1.skip(&info)
    spki,_:=asn1.read_sequence(&info)
    _=asn1.skip(&spki)
    point,err:=asn1.read_bit_string_octets(&spki)
    if err!=.None || len(point)!=65 {return problem("badCSR","no P-256 key")}
    now:=time.now()
    der,cerr:=certificate_make({names=o.domains[:],public_key=point,not_before=time.time_add(now,-time.Minute),not_after=time.time_add(now,f.lifetime),issuer=&f.ca.key,issuer_name="Test CA"},context.temp_allocator)
    if cerr!=nil {return problem("serverInternal","could not issue")}
    leaf_pem,_:=pem.encode(pem.LABEL_CERTIFICATE,der,true,context.temp_allocator)
    ca_pem,_:=pem.encode(pem.LABEL_CERTIFICATE,f.ca.der,true,context.temp_allocator)
    o.chain=transmute([]u8)strings.concatenate({string(leaf_pem),string(ca_pem)})
    o.status="processing"
    return {status=200,retry_after=true,body=fake_order_json(f,i)}
}

@(private="file")
fake_destroy :: proc(f:^Fake) {
    for &o in f.orders {
        for d in o.domains {delete(d)}
        delete(o.domains)
        delete(o.authorizations)
        delete(o.chain)
    }
    delete(f.orders)
    for a in f.authorizations {
        delete(a.domain)
        delete(a.token)
    }
    delete(f.authorizations)
    delete(f.account_jwk)
    test_identity_destroy(&f.site.own)
    test_identity_destroy(&f.https)
    test_identity_destroy(&f.ca)
}

@(test)
acme_orders_a_certificate_by_tls_alpn_from_a_fake_directory :: proc(t:^testing.T) {
    f:Fake
    f.t=t
    f.lifetime=90*24*time.Hour
    defer fake_destroy(&f)
    if !test_identity(t,&f.ca,{"Test CA"},authority=true) {return}
    if !test_identity(t,&f.https,{"acme.test"},&f.ca) {return}
    f.https_credentials[0]=f.https.credential
    f.https_alpn[0]="http/1.1"
    if !test_identity(t,&f.site.own,{"site.test","www.site.test"}) {return}
    f.site.credentials[0]=f.site.own.credential
    f.site.count=1

    account,certificate_key:ecdsa.Private_Key
    testing.expect(t,ecdsa.private_key_generate(&account,.SECP256R1))
    testing.expect(t,ecdsa.private_key_generate(&certificate_key,.SECP256R1))
    roots:=[]^x509.Certificate{&f.ca.certificate}
    a:=Acme{
        directory=BASE+"/directory",
        roots=roots,
        transport=fake_transport(&f),
        account_key=&account,
        contact={"mailto:ops@site.test"},
        data=&f,
        serve=site_serve,
        wait=proc(data:rawptr,seconds:int) {(^Fake)(data).waits+=1},
    }
    domains:=[]string{"site.test","www.site.test"}
    chain,err:=acme_order(&a,domains,&certificate_key)
    if !testing.expectf(t,err==nil,"the order fails: %v %s",err,acme_problem(&a)) {return}
    defer {
        for c in chain {delete(c)}
        delete(chain)
    }
    testing.expect(t,f.bad_nonce_sent && f.validations==2 && f.site.served==2 && f.waits>=2,"the order skipped a step")
    testing.expect_value(t,f.site.count,1)

    expect_chain :: proc(t:^testing.T,chain:[][]u8,roots:[]^x509.Certificate) -> (leaf:x509.Certificate,ok:bool) {
        if !testing.expect_value(t,len(chain),2) {return}
        e:x509.Error
        leaf,e=x509.parse(chain[0])
        if !testing.expect_value(t,e,x509.Error.None) {return}
        intermediate,ie:=x509.parse(chain[1])
        defer x509.destroy(&intermediate)
        testing.expect_value(t,ie,x509.Error.None)
        verified,ve:=x509.verify_chain(&leaf,{roots=roots,intermediates={&intermediate},current_time=time.now(),dns_name="www.site.test"})
        delete(verified)
        return leaf,testing.expect_value(t,ve,x509.Error.None)
    }
    leaf,ok:=expect_chain(t,chain,roots)
    defer x509.destroy(&leaf)
    if !ok {return}

    // Renewal: not due at issuance, due once a third of the lifetime is left, and a new order
    // with the same account gets a new certificate.
    testing.expect(t,!renewal_due(&leaf,time.now()),"due at issuance")
    life:=time.diff(leaf.not_before,leaf.not_after)
    testing.expect(t,!renewal_due(&leaf,time.time_add(leaf.not_before,life/2)),"due at half its lifetime")
    testing.expect(t,renewal_due(&leaf,time.time_add(leaf.not_before,life*2/3+time.Minute)),"not due with a third left")
    renewed,rerr:=acme_order(&a,domains,&certificate_key)
    if !testing.expectf(t,rerr==nil,"the renewal fails: %v %s",rerr,acme_problem(&a)) {return}
    defer {
        for c in renewed {delete(c)}
        delete(renewed)
    }
    next,next_ok:=expect_chain(t,renewed,roots)
    defer x509.destroy(&next)
    testing.expect(t,next_ok && string(next.serial)!=string(leaf.serial),"the renewal is the same certificate")
    testing.expect_value(t,f.validations,4)

    // A URL whose host could end the request line or add a header does not split.
    for url in ([?]string{"https://a.test\r\nX: 1/p","https://a.test\n/p","https://a b/p","https://a@b/p","https://a.test:443\r\n/p"}) {
        _,_,_,split:=url_split(url)
        testing.expectf(t,!split,"%q splits",url)
    }
    _,_,_,split:=url_split("https://[::1]:8443/directory")
    testing.expect(t,split,"an IPv6 host splits")

    // A site that does not serve the challenge fails the authorization.
    a.serve=proc(data:rawptr,credential:^Credential,serving:bool) {}
    _,ferr:=acme_order(&a,{"other.test"},&certificate_key)
    testing.expect_value(t,ferr,Acme_Error.Invalid)
    ecdsa.private_key_clear(&account)
    ecdsa.private_key_clear(&certificate_key)
}
