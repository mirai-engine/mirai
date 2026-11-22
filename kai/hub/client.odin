package hub

import "core:crypto/x509"
import "core:net"
import "core:strconv"
import "core:strings"
import "mirai:net/tls"

// One HTTP/1.1 request to a hub, on a connection of its own, blocking: what
// `mirai kai web approve` and the tests use. https:// is checked against the
// ISRG roots, or the roots given; http:// is taken only for loopback.

Origin :: struct {secure:bool,host:string,port:int}

origin_parse :: proc(text:string) -> (o:Origin,ok:bool) {
    rest:string
    switch {
    case strings.has_prefix(text,"https://"): o.secure,o.port,rest=true,443,text[len("https://"):]
    case strings.has_prefix(text,"http://"): o.port,rest=80,text[len("http://"):]
    case: return
    }
    if rest=="" || strings.index_any(rest,"/?#@ ")>=0 {return}
    o.host=rest
    if cut:=strings.last_index_byte(rest,':');cut>=0 && !strings.has_suffix(rest,"]") {
        n,parsed:=strconv.parse_int(rest[cut+1:],10)
        if !parsed || n<=0 || n>65535 {return}
        o.host,o.port=rest[:cut],n
    }
    if !o.secure {
        address:=net.parse_address(strings.trim(o.host,"[]"))
        loopback:=o.host=="localhost"
        switch a in address {
        case net.IP4_Address: loopback=a[0]==127
        case net.IP6_Address: loopback=a==net.IP6_Loopback
        }
        if !loopback {return}
    }
    return o,o.host!=""
}

// A request with a JSON body or none; roots nil trusts the ISRG roots.
// dial, when given, is the host to connect to in place of the origin's (tests).
client_call :: proc(origin,method,path:string,body:[]u8,roots:[]^x509.Certificate=nil,cookie:="",dial:="",dial_port:=0) -> (r:tls.Response,why:string) {
    o,ok:=origin_parse(origin)
    if !ok {return {},"the origin is https://host[:port], or http:// on loopback"}
    if !strings.has_prefix(path,"/") {return {},"the path starts with /"}
    headers:=strings.concatenate({"Origin: ",origin,"\r\n"},context.temp_allocator)
    if cookie!="" {headers=strings.concatenate({headers,"Cookie: ",cookie,"\r\n"},context.temp_allocator)}
    trust:=roots
    parsed:[len(ISRG_ROOTS)]x509.Certificate
    list:[len(ISRG_ROOTS)]^x509.Certificate
    if trust==nil && o.secure {
        count:=0
        for text,i in ISRG_ROOTS {
            if cert,ok_root:=root_parse(text);ok_root {
                parsed[i]=cert
                list[count]=&parsed[i]
                count+=1
            }
        }
        trust=list[:count]
    }
    target:=tls.Tcp_Target{dial,dial_port}
    transport:=tls.tcp_transport(&target if dial!="" else nil)
    request:=tls.Http_Request{method=method,url=strings.concatenate({origin,path},context.temp_allocator),headers=headers,roots=trust}
    if method=="POST" {request.body,request.content_type=body if body!=nil else []u8{},"application/json"}
    e:tls.Http_Error
    r,e=tls.http_request(transport,request,context.temp_allocator,context.temp_allocator)
    switch e {
    case .None: return r,""
    case .Out_Of_Memory: return {},"out of memory"
    case .Transport: return {},"the hub does not answer at that origin, or the connection broke"
    case .Tls: return {},"the TLS handshake failed: the hub's certificate is not trusted for that name"
    case .Malformed: return {},"the hub's answer does not read"
    }
    return {},"the hub's answer does not read"
}

@(private)
root_parse :: proc(text:string) -> (cert:x509.Certificate,ok:bool) {
    block,_,e:=pem_decode(text)
    if !e {return}
    parsed,pe:=x509.parse(block,context.temp_allocator)
    return parsed,pe==.None
}
