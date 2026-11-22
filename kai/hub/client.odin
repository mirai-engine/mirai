package hub

import "core:crypto/x509"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:net/tls"

// One HTTP/1.1 request to a hub, on a connection of its own, blocking: what
// `mirai kai web approve` and the tests use. https:// is checked against the
// ISRG roots, or the roots given; http:// is taken only for loopback.

CLIENT_RESPONSE_MAX :: 4<<20
CLIENT_TIMEOUT :: 20*time.Second

Client_Response :: struct {
    status:int,
    headers:string,
    body:[]u8,
}

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
client_call :: proc(origin,method,path:string,body:[]u8,roots:[]^x509.Certificate=nil,cookie:="",dial:="",dial_port:=0) -> (r:Client_Response,why:string) {
    o,ok:=origin_parse(origin)
    if !ok {return {},"the origin is https://host[:port], or http:// on loopback"}
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,method)
    strings.write_byte(&b,' ')
    strings.write_string(&b,path)
    strings.write_string(&b," HTTP/1.1\r\nHost: ")
    strings.write_string(&b,o.host)
    if (o.secure && o.port!=443) || (!o.secure && o.port!=80) {
        strings.write_byte(&b,':')
        strings.write_int(&b,o.port)
    }
    strings.write_string(&b,"\r\nUser-Agent: mirai-kai\r\nAccept: application/json\r\nConnection: close\r\nOrigin: ")
    strings.write_string(&b,origin)
    strings.write_string(&b,"\r\n")
    if cookie!="" {
        strings.write_string(&b,"Cookie: ")
        strings.write_string(&b,cookie)
        strings.write_string(&b,"\r\n")
    }
    if method=="POST" {
        strings.write_string(&b,"Content-Type: application/json\r\nContent-Length: ")
        strings.write_int(&b,len(body))
        strings.write_string(&b,"\r\n")
    }
    strings.write_string(&b,"\r\n")
    strings.write_bytes(&b,body)
    out:=b.buf[:]
    socket,de:=net.dial_tcp_from_hostname_with_port_override(dial!=""?dial:o.host,dial_port!=0?dial_port:o.port)
    if de!=nil {return {},"the hub does not answer at that origin"}
    defer net.close(socket)
    net.set_option(socket,.Receive_Timeout,CLIENT_TIMEOUT)
    net.set_option(socket,.Send_Timeout,CLIENT_TIMEOUT)
    received:=make([dynamic]u8,context.temp_allocator)
    buffer:[16<<10]u8
    if !o.secure {
        if _,se:=net.send_tcp(socket,out);se!=nil {return {},"the request does not send"}
        for len(received)<CLIENT_RESPONSE_MAX {
            n,re:=net.recv_tcp(socket,buffer[:])
            if re!=nil || n==0 {break}
            append(&received,..buffer[:n])
            if response_whole(received[:]) {break}
        }
        return response_read(received[:])
    }
    trust:=roots
    parsed:[len(ISRG_ROOTS)]x509.Certificate
    list:[len(ISRG_ROOTS)]^x509.Certificate
    if trust==nil {
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
    defer if roots==nil {for &cert in parsed {x509.destroy(&cert,context.temp_allocator)}}
    conn,ce:=tls.create({host=o.host,roots=trust,alpn={ALPN_HTTP}},.Client,context.temp_allocator)
    if ce!=nil {return {},"TLS does not start"}
    defer tls.destroy(conn)
    written:=0
    for len(received)<CLIENT_RESPONSE_MAX {
        if tls.connected(conn) && written<len(out) {
            n,_:=tls.write(conn,out[written:])
            written+=n
        }
        for p:=tls.pending(conn);len(p)>0;p=tls.pending(conn) {
            n,se:=net.send_tcp(socket,p)
            if se!=nil {return {},"the connection broke"}
            tls.sent(conn,n)
        }
        if written==len(out) && response_whole(received[:]) {break}
        n,re:=net.recv_tcp(socket,buffer[:])
        if re!=nil || n==0 {
            if !tls.connected(conn) {return {},"the TLS handshake failed: the hub's certificate is not trusted for that name"}
            break
        }
        for at:=0;at<n; {
            taken,e:=tls.receive(conn,buffer[at:n])
            at+=taken
            for {
                plain:[4096]u8
                m,_:=tls.read(conn,plain[:])
                if m==0 {break}
                append(&received,..plain[:m])
            }
            if e!=nil && e!=.Closed {return {},"the TLS handshake failed: the hub's certificate is not trusted for that name"}
            if e==.Closed || taken==0 {break}
        }
    }
    return response_read(received[:])
}

@(private)
root_parse :: proc(text:string) -> (cert:x509.Certificate,ok:bool) {
    block,_,e:=pem_decode(text)
    if !e {return}
    parsed,pe:=x509.parse(block,context.temp_allocator)
    return parsed,pe==.None
}

@(private)
response_whole :: proc(received:[]u8) -> bool {
    text:=string(received)
    end:=strings.index(text,"\r\n\r\n")
    if end<0 {return false}
    length,found:=header_length(text[:end])
    return found && len(received)>=end+4+length
}

@(private)
header_length :: proc(head:string) -> (length:int,found:bool) {
    rest:=head
    for line in strings.split_lines_iterator(&rest) {
        colon:=strings.index_byte(line,':')
        if colon<0 || !strings.equal_fold(line[:colon],"content-length") {continue}
        n,ok:=strconv.parse_int(strings.trim_space(line[colon+1:]),10)
        if ok && n>=0 {return n,true}
    }
    return
}

@(private)
response_read :: proc(received:[]u8) -> (r:Client_Response,why:string) {
    text:=string(received)
    end:=strings.index(text,"\r\n\r\n")
    if end<0 || !strings.has_prefix(text,"HTTP/1.1 ") || len(text)<12 {return {},"the hub's answer does not read"}
    status,ok:=strconv.parse_int(text[9:12],10)
    if !ok {return {},"the hub's answer does not read"}
    length,_:=header_length(text[:end])
    if len(received)<end+4+length {return {},"the hub's answer was cut"}
    return {status=status,headers=text[:end],body=received[end+4:][:length]},""
}
