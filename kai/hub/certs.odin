package hub

import "core:crypto"
import "core:fmt"
import "core:crypto/ecdsa"
import "core:crypto/x509"
import "core:encoding/pem"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:kai"
import "mirai:net/tls"

// The certificates of the hub's TLS: given by the caller (tests), or ordered
// by ACME TLS-ALPN-01 for --domain on the TLS port itself and renewed when a
// third of their life is left. The certificate's key, its chain and the ACME
// account key are kept owner-only at the root of the store, beside the
// device's keys. The directory's HTTPS is checked against the ISRG roots
// embedded here, whatever the system trusts.

WEB_KEY_FILE :: "kai-web-key"          // the P-256 scalar of the certificate's key
WEB_CHAIN_FILE :: "kai-web-chain.pem"  // its chain, leaf first
WEB_ACCOUNT_FILE :: "kai-web-account"  // the P-256 scalar of the ACME account
LETS_ENCRYPT :: "https://acme-v02.api.letsencrypt.org/directory"
CERT_CHECK_SECONDS :: 12*3600.0
CERT_RETRY_SECONDS :: 3600.0
ALPN_HTTP :: "http/1.1"
ALPN_ACME :: "acme-tls/1"

ISRG_ROOTS :: [?]string{#load("roots/isrg_root_x1.pem",string),#load("roots/isrg_root_x2.pem",string)}

Certs :: struct {
    acme:bool,                 // this hub orders its certificates
    key:ecdsa.Private_Key,
    chain:[][]u8,              // in the hub's allocator
    credential:tls.Credential,
    has:bool,
    old_chain:[][]u8,          // the previous ones, kept while connections made before may use them
    old_credential:tls.Credential,
    has_old:bool,
    challenge:tls.Credential,  // while ACME validates a name
    serving:bool,
    list:[4]tls.Credential,    // what a new connection may present
    count:int,
    alpn:[2]string,
    roots:[len(ISRG_ROOTS)]x509.Certificate,
    root_list:[len(ISRG_ROOTS)]^x509.Certificate,
    roots_count:int,
    next:f64,
    ordering:bool,
}

@(private)
certs_start :: proc(h:^Hub) -> string {
    c:=&h.certs
    c.alpn={ALPN_HTTP,ALPN_ACME}
    if !h.has_secure {return ""}
    if len(h.desc.credentials)>0 {
        certs_list(h)
        return ""
    }
    if len(h.desc.domains)==0 {return "TLS needs --domain: the names ACME orders a certificate for"}
    c.acme=true
    for text,i in ISRG_ROOTS {
        block,_,e:=pem.decode(transmute([]u8)text,context.temp_allocator)
        if e!=nil {return "an embedded root certificate does not read"}
        cert,pe:=x509.parse(pem.block_bytes(block),h.allocator)
        if pe!=.None {return "an embedded root certificate does not parse"}
        c.roots[i]=cert
        c.root_list[i]=&c.roots[i]
        c.roots_count=i+1
    }
    if certs_load(h) {
        event(h,"TLS certificate for %s loaded from the store",h.desc.domains[0])
    }
    certs_list(h)
    return ""
}

@(private)
certs_stop :: proc(h:^Hub) {
    c:=&h.certs
    if c.has {
        tls.credential_destroy(&c.credential,h.allocator)
        chain_free(h,c.chain)
    }
    if c.has_old {
        tls.credential_destroy(&c.old_credential,h.allocator)
        chain_free(h,c.old_chain)
    }
    for &r in c.roots[:c.roots_count] {x509.destroy(&r,h.allocator)}
    ecdsa.private_key_clear(&c.key)
}

@(private)
chain_free :: proc(h:^Hub,chain:[][]u8) {
    for d in chain {delete(d,h.allocator)}
    delete(chain,h.allocator)
}

// The credentials a new connection may present.
@(private)
certs_list :: proc(h:^Hub) {
    c:=&h.certs
    c.count=0
    for cred in h.desc.credentials {
        if c.count<len(c.list) {
            c.list[c.count]=cred
            c.count+=1
        }
    }
    if c.has {
        c.list[c.count]=c.credential
        c.count+=1
    }
    if c.serving {
        c.list[c.count]=c.challenge
        c.count+=1
    }
}

certs_config :: proc(h:^Hub) -> tls.Config {
    c:=&h.certs
    return {credentials=c.list[:c.count],alpn=c.alpn[:]}
}

@(private)
store_file :: proc(h:^Hub,name:string) -> string {
    return strings.concatenate({store_of(h).root,"/",name},context.temp_allocator)
}

// Writes bytes owner-only, whole or not at all.
@(private)
secret_write :: proc(path:string,bytes:[]u8) -> bool {
    temp:=strings.concatenate({path,".tmp"},context.temp_allocator)
    if os.write_entire_file(temp,bytes,{.Read_User,.Write_User})!=nil {return false}
    if os.rename(temp,path)!=nil {
        os.remove(temp)
        return false
    }
    return true
}

// The key and chain the store keeps, when they serve every domain and are not due.
@(private)
certs_load :: proc(h:^Hub) -> bool {
    key_bytes,ke:=os.read_entire_file(store_file(h,WEB_KEY_FILE),context.temp_allocator)
    chain_text,ce:=os.read_entire_file(store_file(h,WEB_CHAIN_FILE),context.temp_allocator)
    if ke!=nil || ce!=nil {return false}
    defer crypto.zero_explicit(raw_data(key_bytes),len(key_bytes))
    key:ecdsa.Private_Key
    if !ecdsa.private_key_set_bytes(&key,.SECP256R1,key_bytes) {return false}
    chain:=make([dynamic][]u8,h.allocator)
    rest:=chain_text
    for len(rest)>0 && len(chain)<8 {
        block,remaining,e:=pem.decode(rest,context.temp_allocator)
        if e!=nil {break}
        der:=make([]u8,len(pem.block_bytes(block)),h.allocator)
        copy(der,pem.block_bytes(block))
        append(&chain,der)
        rest=remaining
    }
    if !certs_take(h,&key,chain[:]) {
        chain_free(h,chain[:])
        ecdsa.private_key_clear(&key)
        return false
    }
    return true
}

// Makes chain with key the hub's credential when it serves every domain and
// is not due; the previous one is kept until the next renewal.
@(private)
certs_take :: proc(h:^Hub,key:^ecdsa.Private_Key,chain:[][]u8) -> bool {
    c:=&h.certs
    if len(chain)==0 {return false}
    cred,e:=tls.credential_init(chain,key,"",h.allocator)
    if e!=nil {return false}
    for d in h.desc.domains {
        if x509.verify_hostname(&cred.leaf,d)!=.None {
            tls.credential_destroy(&cred,h.allocator)
            return false
        }
    }
    if tls.renewal_due(&cred.leaf,time.now()) {
        tls.credential_destroy(&cred,h.allocator)
        return false
    }
    if c.has_old {
        tls.credential_destroy(&c.old_credential,h.allocator)
        chain_free(h,c.old_chain)
    }
    c.old_credential,c.old_chain,c.has_old=c.credential,c.chain,c.has
    c.credential,c.chain,c.has=cred,chain,true
    c.key=key^
    certs_list(h)
    return true
}

// Orders a certificate when none serves or the one served is due.
@(private)
certs_step :: proc(h:^Hub) {
    c:=&h.certs
    if !c.acme || c.ordering || h.now<c.next {return}
    c.next=h.now+CERT_CHECK_SECONDS
    if c.has && !tls.renewal_due(&c.credential.leaf,time.now()) {return}
    c.ordering=true
    defer c.ordering=false
    event(h,"ordering a TLS certificate for %s by ACME",strings.join(h.desc.domains,", ",context.temp_allocator))
    account:ecdsa.Private_Key
    defer ecdsa.private_key_clear(&account)
    if !p256_secret(h,WEB_ACCOUNT_FILE,&account) {
        event(h,"the ACME account key does not write to the store: give this user access to it")
        c.next=h.now+CERT_RETRY_SECONDS
        return
    }
    key:ecdsa.Private_Key
    if !ecdsa.private_key_generate(&key,.SECP256R1) {
        c.next=h.now+CERT_RETRY_SECONDS
        return
    }
    directory:=h.desc.acme_directory!=""?h.desc.acme_directory:LETS_ENCRYPT
    roots:=h.desc.acme_roots
    if roots==nil {roots=c.root_list[:c.roots_count]}
    a:=tls.Acme{directory=directory,roots=roots,transport=tls.TCP_TRANSPORT,account_key=&account,data=h,serve=acme_serve,wait=acme_wait}
    chain,e:=tls.acme_order(&a,h.desc.domains,&key,h.allocator)
    if e!=.None {
        event(h,"the ACME order failed (%v %s): it is tried again in an hour; the domain must point at this machine and its TLS port must be reachable on 443",e,tls.acme_problem(&a))
        ecdsa.private_key_clear(&key)
        c.next=h.now+CERT_RETRY_SECONDS
        return
    }
    scalar:[32]u8
    ecdsa.private_key_bytes(&key,scalar[:])
    text:=make([dynamic]u8,context.temp_allocator)
    for der in chain {
        block,_:=pem.encode("CERTIFICATE",der,false,context.temp_allocator)
        append(&text,..block)
    }
    saved:=secret_write(store_file(h,WEB_KEY_FILE),scalar[:]) && secret_write(store_file(h,WEB_CHAIN_FILE),text[:])
    crypto.zero_explicit(&scalar,32)
    if !certs_take(h,&key,chain) {
        event(h,"the certificate ACME gave does not serve every domain")
        chain_free(h,chain)
        c.next=h.now+CERT_RETRY_SECONDS
        return
    }
    event(h,saved?"TLS certificate ordered and kept in the store":"TLS certificate ordered; it does not write to the store, so it is ordered again at the next start")
}

// The P-256 key whose scalar the store keeps in name, made the first time.
@(private)
p256_secret :: proc(h:^Hub,name:string,key:^ecdsa.Private_Key) -> bool {
    path:=store_file(h,name)
    if bytes,e:=os.read_entire_file(path,context.temp_allocator);e==nil {
        defer crypto.zero_explicit(raw_data(bytes),len(bytes))
        return ecdsa.private_key_set_bytes(key,.SECP256R1,bytes)
    }
    if !ecdsa.private_key_generate(key,.SECP256R1) {return false}
    scalar:[32]u8
    defer crypto.zero_explicit(&scalar,32)
    ecdsa.private_key_bytes(key,scalar[:])
    return secret_write(path,scalar[:])
}

@(private)
acme_serve :: proc(data:rawptr,credential:^tls.Credential,serving:bool) {
    h:=(^Hub)(data)
    h.certs.serving=serving
    if serving {h.certs.challenge=credential^}
    certs_list(h)
}

// Between ACME's polls the hub and the runner go on: the validation
// connection of the directory is answered here.
@(private)
acme_wait :: proc(data:rawptr,seconds:int) {
    h:=(^Hub)(data)
    start:=time.tick_now()
    for time.duration_seconds(time.tick_since(start))<f64(seconds) {
        busy:=hub_step(h)
        kai.runner_update(h.desc.runner,busy?0:0.01)
    }
}

event :: proc(h:^Hub,format:string,args:..any) {
    e:=h.desc.event
    if e.procedure==nil {return}
    e.procedure(e.data,fmt.tprintf(format,..args))
}


// The DER of the first PEM block of text, in the temp allocator.
pem_decode :: proc(text:string) -> (der:[]u8,rest:string,ok:bool) {
    block,remaining,e:=pem.decode(transmute([]u8)text,context.temp_allocator)
    if e!=nil {return}
    return pem.block_bytes(block),string(remaining),true
}
