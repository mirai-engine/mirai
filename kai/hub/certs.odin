package hub

import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:crypto/ecdsa"
import "core:crypto/x509"
import "core:encoding/pem"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:kai"
import "mirai:net/tls"

// The certificates of the hub's TLS: given by the caller (tests), or ordered
// by ACME TLS-ALPN-01 for --domain on the TLS port itself and renewed when a
// third of their life is left. While an order waits for the directory, a poll
// or a socket, the hub and the runner go on stepping, so the directory's
// validation connection is answered and serving does not stall. The
// certificate's key, its chain and the ACME account key are kept owner-only
// at the root of the store, beside the device's keys.
// The directory's HTTPS is checked against the ISRG roots embedded here,
// whatever the system trusts.

WEB_KEY_FILE :: "kai-web-key"          // the P-256 scalar of the certificate's key
WEB_CHAIN_FILE :: "kai-web-chain.pem"  // its chain, leaf first
WEB_ACCOUNT_FILE :: "kai-web-account"  // the P-256 scalar of the ACME account
LETS_ENCRYPT :: "https://acme-v02.api.letsencrypt.org/directory"
CERT_CHECK_SECONDS :: 12*3600.0
CERT_RETRY_SECONDS :: 3600.0
CHAIN_MAX :: 8
ALPN_HTTP :: "http/1.1"
ALPN_ACME :: "acme-tls/1"

ISRG_ROOTS :: [?]string{#load("roots/isrg_root_x1.pem",string),#load("roots/isrg_root_x2.pem",string)}

Certs :: struct {
    acme:bool,                 // this hub orders its certificates
    credential:tls.Credential, // what the hub presents; its chain in the hub's allocator
    chain:[][]u8,
    has:bool,
    challenge:tls.Credential,  // a copy of the one ACME offers while it validates a name
    serving:bool,
    // What a connection may present, picked at its ClientHello; an entry without a chain is
    // empty. Connections read it through their Config, so it is rewritten in place.
    list:[4]tls.Credential,
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
        if len(h.desc.credentials)>len(c.list) {return "TLS takes at most four credentials"}
        certs_list(h)
        return ""
    }
    if len(h.desc.domains)==0 {return "TLS needs --domain: the names ACME orders a certificate for"}
    c.acme=true
    for text,i in ISRG_ROOTS {
        der,_,ok:=pem_decode(text)
        if !ok {return "an embedded root certificate does not read"}
        cert,pe:=x509.parse(der,h.allocator)
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
    for &r in c.roots[:c.roots_count] {x509.destroy(&r,h.allocator)}
    crypto.zero_explicit(&c.challenge,size_of(c.challenge))
    crypto.zero_explicit(&c.list,size_of(c.list))
}

@(private)
chain_free :: proc(h:^Hub,chain:[][]u8) {
    for d in chain {delete(d,h.allocator)}
    delete(chain,h.allocator)
}

// Writes what a new ClientHello may pick from; the copies it replaces are wiped.
@(private)
certs_list :: proc(h:^Hub) {
    c:=&h.certs
    crypto.zero_explicit(&c.list,size_of(c.list))
    count:=0
    for cred in h.desc.credentials[:min(len(h.desc.credentials),len(c.list))] {
        c.list[count]=cred
        count+=1
    }
    if c.has && count<len(c.list) {
        c.list[count]=c.credential
        count+=1
    }
    if c.serving && count<len(c.list) {c.list[count]=c.challenge}
}

certs_config :: proc(h:^Hub) -> tls.Config {
    c:=&h.certs
    return {credentials=c.list[:],alpn=c.alpn[:]}
}

@(private)
store_file :: proc(h:^Hub,name:string) -> string {
    return strings.concatenate({store_of(h).root,"/",name},context.temp_allocator)
}

// Writes bytes owner-only, whole or not at all, and on the disk before it answers.
@(private)
secret_write :: proc(path:string,bytes:[]u8) -> bool {
    temp:=strings.concatenate({path,".tmp"},context.temp_allocator)
    os.remove(temp)
    f,e:=os.open(temp,{.Write,.Create,.Excl},{.Read_User,.Write_User})
    if e!=nil {return false}
    _,we:=os.write(f,bytes)
    se:=os.sync(f)
    ce:=os.close(f)
    if we!=nil || se!=nil || ce!=nil || os.rename(temp,path)!=nil {
        os.remove(temp)
        return false
    }
    return true
}

// Keeps the key and chain of the hub's certificate in the store: the chain as PEM, one
// block after another.
@(private)
certs_save :: proc(h:^Hub,key:^ecdsa.Private_Key,chain:[][]u8) -> bool {
    scalar:[32]u8
    defer crypto.zero_explicit(&scalar,32)
    ecdsa.private_key_bytes(key,scalar[:])
    text:=make([dynamic]u8,context.temp_allocator)
    for der in chain {
        block,e:=pem.encode("CERTIFICATE",der,true,context.temp_allocator)
        if e!=nil {return false}
        append(&text,..block)
    }
    return secret_write(store_file(h,WEB_KEY_FILE),scalar[:]) && secret_write(store_file(h,WEB_CHAIN_FILE),text[:])
}

// The key and chain the store keeps, when they serve every domain and are not due.
@(private)
certs_load :: proc(h:^Hub) -> bool {
    key_bytes,ke:=os.read_entire_file(store_file(h,WEB_KEY_FILE),context.temp_allocator)
    chain_text,ce:=os.read_entire_file(store_file(h,WEB_CHAIN_FILE),context.temp_allocator)
    if ke!=nil || ce!=nil {return false}
    defer crypto.zero_explicit(raw_data(key_bytes),len(key_bytes))
    key:ecdsa.Private_Key
    defer ecdsa.private_key_clear(&key)
    if !ecdsa.private_key_set_bytes(&key,.SECP256R1,key_bytes) {return false}
    chain:=make([dynamic][]u8,h.allocator)
    rest:=string(chain_text)
    for len(chain)<=CHAIN_MAX {
        der,remaining,ok:=pem_decode(rest)
        if !ok {break}
        copied,me:=make([]u8,len(der),h.allocator)
        if me!=nil {break}
        copy(copied,der)
        append(&chain,copied)
        rest=remaining
    }
    if len(chain)>CHAIN_MAX || !certs_take(h,&key,chain[:]) {
        chain_free(h,chain[:])
        return false
    }
    return true
}

// Makes chain with key the hub's credential when it serves every domain and
// is not due, and frees the one it replaces: a connection holds a credential
// only while its ClientHello is answered.
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
    if c.has {
        tls.credential_destroy(&c.credential,h.allocator)
        chain_free(h,c.chain)
    }
    c.credential,c.chain,c.has=cred,chain,true
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
    account,key:ecdsa.Private_Key
    defer ecdsa.private_key_clear(&account)
    defer ecdsa.private_key_clear(&key)
    if !p256_secret(h,WEB_ACCOUNT_FILE,&account) {
        event(h,"the ACME account key does not write to the store: give this user access to it")
        c.next=h.now+CERT_RETRY_SECONDS
        return
    }
    if !ecdsa.private_key_generate(&key,.SECP256R1) {
        c.next=h.now+CERT_RETRY_SECONDS
        return
    }
    directory:=h.desc.acme_directory!=""?h.desc.acme_directory:LETS_ENCRYPT
    roots:=h.desc.acme_roots
    if roots==nil {roots=c.root_list[:c.roots_count]}
    transport:=tls.Transport{data=h,dial=order_dial,read=order_read,write=order_write,close=order_close}
    a:=tls.Acme{directory=directory,roots=roots,transport=transport,account_key=&account,data=h,serve=acme_serve,wait=acme_wait}
    chain,e:=tls.acme_order(&a,h.desc.domains,&key,h.allocator)
    if e!=.None {
        event(h,"the ACME order failed (%v %s): it is tried again in an hour; the domain must point at this machine and its TLS port must be reachable on 443",e,tls.acme_problem(&a))
        c.next=h.now+CERT_RETRY_SECONDS
        return
    }
    saved:=certs_save(h,&key,chain)
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

// Presents ACME's challenge credential, or withdraws it and wipes the copy
// before ACME frees it.
@(private)
acme_serve :: proc(data:rawptr,credential:^tls.Credential,serving:bool) {
    h:=(^Hub)(data)
    c:=&h.certs
    crypto.zero_explicit(&c.challenge,size_of(c.challenge))
    c.serving=serving
    if serving {c.challenge=credential^}
    certs_list(h)
}

// One step of the hub and the runner while ACME waits, with the temporary
// memory of the step freed after it.
@(private)
order_step :: proc(h:^Hub) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    busy:=hub_step(h)
    kai.runner_update(h.desc.runner,busy?0:0.01)
}

@(private)
acme_wait :: proc(data:rawptr,seconds:int) {
    h:=(^Hub)(data)
    start:=time.tick_now()
    for time.duration_seconds(time.tick_since(start))<f64(seconds) {order_step(h)}
}

// The system's TCP for ACME, without blocking: while a socket would block, the
// hub steps, for at most ORDER_SOCKET_SECONDS.
@(private) ORDER_SOCKET_SECONDS :: 30.0

@(private)
order_dial :: proc(data:rawptr,host:string,port:int) -> (stream:uintptr,ok:bool) {
    socket,err:=net.dial_tcp_from_hostname_with_port_override(host,port)
    if err!=nil {return 0,false}
    if net.set_blocking(socket,false)!=nil {
        net.close(socket)
        return 0,false
    }
    return uintptr(socket),true
}

@(private)
order_read :: proc(data:rawptr,stream:uintptr,buffer:[]u8) -> (count:int,ok:bool) {
    start:=time.tick_now()
    for time.duration_seconds(time.tick_since(start))<ORDER_SOCKET_SECONDS {
        n,err:=net.recv_tcp(net.TCP_Socket(stream),buffer)
        if err==nil {return n,true}
        if err!=.Would_Block && err!=.Interrupted {return 0,false}
        order_step((^Hub)(data))
    }
    return 0,false
}

@(private)
order_write :: proc(data:rawptr,stream:uintptr,bytes:[]u8) -> bool {
    start:=time.tick_now()
    for at:=0;at<len(bytes); {
        n,err:=net.send_tcp(net.TCP_Socket(stream),bytes[at:])
        at+=max(n,0)
        if err==.Would_Block || err==.Interrupted {
            if time.duration_seconds(time.tick_since(start))>ORDER_SOCKET_SECONDS {return false}
            order_step((^Hub)(data))
            continue
        }
        if err!=nil {return false}
    }
    return true
}

@(private)
order_close :: proc(data:rawptr,stream:uintptr) {net.close(net.TCP_Socket(stream))}

event :: proc(h:^Hub,format:string,args:..any) {
    e:=h.desc.event
    if e.procedure==nil {return}
    e.procedure(e.data,fmt.tprintf(format,..args))
}

// The DER of the first CERTIFICATE block of text, in the temp allocator, and the text after
// it: not ok when text holds none.
pem_decode :: proc(text:string) -> (der:[]u8,rest:string,ok:bool) {
    block,remaining,e:=pem.decode(transmute([]u8)text,context.temp_allocator)
    if e!=nil || block==nil || block.label!="CERTIFICATE" || len(pem.block_bytes(block))==0 {return}
    return pem.block_bytes(block),string(remaining),true
}
