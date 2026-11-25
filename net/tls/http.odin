package tls

import "base:runtime"
import "core:crypto/x509"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

// A byte stream to a host, over which acme_order talks HTTPS (tcp_transport is the system's).
// read waits for bytes: 0 bytes with ok is the end of the stream.
Transport :: struct {
    data:rawptr,
    dial:proc(data:rawptr,host:string,port:int) -> (stream:uintptr,ok:bool),
    read:proc(data:rawptr,stream:uintptr,buffer:[]u8) -> (count:int,ok:bool),
    write:proc(data:rawptr,stream:uintptr,bytes:[]u8) -> bool,
    close:proc(data:rawptr,stream:uintptr),
}

// The largest response a request takes.
RESPONSE_MAX :: 4<<20

Http_Error :: enum u8 {None,Out_Of_Memory,Transport,Tls,Malformed}

Http_Request :: struct {
    method,url:string, // https://host[:port]/path, or http:// without TLS
    body:[]u8,         // nil: none
    content_type:string,
    headers:string,    // more header lines, each ending in \r\n
    roots:[]^x509.Certificate, // what an https:// server's chain is checked against
    time:time.Time,    // when that chain must be valid; zero is now
}

Response :: struct {
    status:int,
    headers:string, // the header lines, after the status line
    body:[]u8,
}

// A request of HTTP/1.1 on a connection of its own, which the response ends: what ACME and
// `mirai kai web approve` send. The response is in allocator; TLS takes its memory from
// scratch.
http_request :: proc(transport:Transport,request:Http_Request,allocator,scratch:runtime.Allocator) -> (response:Response,err:Http_Error) {
    host,port,path,ok:=url_split(request.url)
    if !ok {return {},.Malformed}
    secure:=strings.has_prefix(request.url,"https://")
    method:=request.method
    memory,merr:=make([]u8,len(method)+len(path)+len(host)+len(request.content_type)+len(request.headers)+len(request.body)+256,allocator)
    if merr!=nil {return {},.Out_Of_Memory}
    b:=strings.builder_from_bytes(memory)
    fmt.sbprintf(&b,"%s %s HTTP/1.1\r\nHost: ",method,path)
    if strings.index_byte(host,':')>=0 {fmt.sbprintf(&b,"[%s]",host)} else {strings.write_string(&b,host)}
    if port!=(secure?443:80) {fmt.sbprintf(&b,":%d",port)}
    fmt.sbprintf(&b,"\r\nUser-Agent: mirai\r\nAccept: */*\r\nConnection: close\r\n%s",request.headers)
    if request.body!=nil {fmt.sbprintf(&b,"Content-Type: %s\r\nContent-Length: %d\r\n",request.content_type,len(request.body))}
    strings.write_string(&b,"\r\n")
    head:=len(b.buf)
    copy(memory[head:],request.body)
    out:=memory[:head+len(request.body)]

    stream,dialed:=transport.dial(transport.data,host,port)
    if !dialed {return {},.Transport}
    defer transport.close(transport.data,stream)
    received:[dynamic]u8
    if received,err=make_received(allocator);err!=nil {return}
    buffer:[16<<10]u8
    if !secure {
        if !transport.write(transport.data,stream,out) {return {},.Transport}
        for !response_complete(received[:],method=="HEAD") {
            n,read_ok:=transport.read(transport.data,stream,buffer[:])
            if !read_ok {return {},.Transport}
            if n==0 {break}
            if len(received)+n>RESPONSE_MAX {return {},.Malformed}
            if _,aerr:=append(&received,..buffer[:n]);aerr!=nil {return {},.Out_Of_Memory}
        }
        return response_parse(received[:],method=="HEAD",allocator)
    }
    conn,cerr:=create({host=host,roots=request.roots,alpn={"http/1.1"},time=request.time},.Client,scratch)
    if cerr==.Out_Of_Memory {return {},.Out_Of_Memory}
    if cerr!=nil {return {},.Tls}
    defer destroy(conn)
    written:=0
    loop: for {
        if connected(conn) && written<len(out) {
            n,_:=write(conn,out[written:])
            written+=n
        }
        for p:=pending(conn);len(p)>0;p=pending(conn) {
            if !transport.write(transport.data,stream,p) {return {},.Transport}
            sent(conn,len(p))
        }
        if written==len(out) && response_complete(received[:],method=="HEAD") {break}
        n,read_ok:=transport.read(transport.data,stream,buffer[:])
        if !read_ok {return {},.Transport}
        if n==0 {
            if !connected(conn) {return {},.Tls}
            break
        }
        for at:=0;at<n; {
            taken,e:=receive(conn,buffer[at:n])
            at+=taken
            plain:[4096]u8
            for {
                m,re:=read(conn,plain[:])
                if m==0 {
                    if re==.Closed {break loop}
                    break
                }
                if len(received)+m>RESPONSE_MAX {return {},.Malformed}
                if _,aerr:=append(&received,..plain[:m]);aerr!=nil {return {},.Out_Of_Memory}
            }
            if e==.Closed {break loop}
            if e!=nil {return {},.Tls}
            for p:=pending(conn);len(p)>0;p=pending(conn) {
                if !transport.write(transport.data,stream,p) {return {},.Transport}
                sent(conn,len(p))
            }
        }
    }
    close(conn)
    for p:=pending(conn);len(p)>0;p=pending(conn) {
        if !transport.write(transport.data,stream,p) {break}
        sent(conn,len(p))
    }
    return response_parse(received[:],method=="HEAD",allocator)
}

@(private)
make_received :: proc(allocator:runtime.Allocator) -> ([dynamic]u8,Http_Error) {
    received,err:=make([dynamic]u8,0,4096,allocator)
    return received,nil if err==nil else .Out_Of_Memory
}

// "https://host[:port]/path" or "http://...": its parts, the port 443 or 80 when it says none.
url_split :: proc(url:string) -> (host:string,port:int,path:string,ok:bool) {
    rest:string
    switch {
    case strings.has_prefix(url,"https://"): rest,port=url[len("https://"):],443
    case strings.has_prefix(url,"http://"): rest,port=url[len("http://"):],80
    case: return
    }
    slash:=strings.index_byte(rest,'/')
    authority:=rest if slash<0 else rest[:slash]
    path="/" if slash<0 else rest[slash:]
    host=authority
    if strings.has_prefix(authority,"[") {
        end:=strings.index_byte(authority,']')
        if end<0 {return}
        host=authority[1:end]
        if tail:=authority[end+1:];tail!="" {
            if tail[0]!=':' {return}
            port=strconv.parse_int(tail[1:],10) or_return
        }
    } else if colon:=strings.index_byte(authority,':');colon>=0 {
        host=authority[:colon]
        port=strconv.parse_int(authority[colon+1:],10) or_return
    }
    if host=="" || port<=0 || port>0xffff {return}
    for b in transmute([]u8)host {
        switch b {
        case 'a'..='z','A'..='Z','0'..='9','-','.',':','_':
        case: return
        }
    }
    for b in transmute([]u8)path {
        if b<=' ' || b>=0x7f {return}
    }
    return host,port,path,true
}

// Whether received holds the whole response, as its headers say.
@(private)
response_complete :: proc(received:[]u8,head:bool) -> bool {
    end:=strings.index(string(received),"\r\n\r\n")
    if end<0 {return false}
    if head {return true}
    headers:=string(received[:end])
    length,found:=header_value(headers,"Content-Length")
    if !found {return false}
    n,ok:=strconv.parse_int(length,10)
    return ok && len(received)-end-4>=n
}

@(private)
response_parse :: proc(received:[]u8,head:bool,allocator:runtime.Allocator) -> (response:Response,err:Http_Error) {
    text:=string(received)
    end:=strings.index(text,"\r\n\r\n")
    if end<0 {return {},.Malformed}
    line_end:=strings.index(text,"\r\n")
    status_line:=text[:line_end]
    if !strings.has_prefix(status_line,"HTTP/1.") || len(status_line)<12 || status_line[8]!=' ' {return {},.Malformed}
    status,ok:=strconv.parse_int(status_line[9:12],10)
    if !ok || status<100 {return {},.Malformed}
    response.status=status
    response.headers=text[line_end+2:end] if line_end<end else ""
    body:=received[end+4:]
    if head {return response,nil}
    if encoding,found:=header_value(response.headers,"Transfer-Encoding");found && strings.equal_fold(encoding,"chunked") {
        response.body,err=chunked_decode(body,allocator)
        return
    }
    if length,found:=header_value(response.headers,"Content-Length");found {
        n,valid:=strconv.parse_int(length,10)
        if !valid || n<0 || n>len(body) {return {},.Malformed}
        body=body[:n]
    }
    response.body=body
    return response,nil
}

@(private)
chunked_decode :: proc(data:[]u8,allocator:runtime.Allocator) -> (body:[]u8,err:Http_Error) {
    out,merr:=make([dynamic]u8,0,len(data),allocator)
    if merr!=nil {return nil,.Out_Of_Memory}
    rest:=string(data)
    for {
        line_end:=strings.index(rest,"\r\n")
        if line_end<0 {return nil,.Malformed}
        size_text:=rest[:line_end]
        if semicolon:=strings.index_byte(size_text,';');semicolon>=0 {size_text=size_text[:semicolon]}
        size,ok:=strconv.parse_int(strings.trim_space(size_text),16)
        if !ok || size<0 || size>len(rest)-line_end-2 {return nil,.Malformed}
        rest=rest[line_end+2:]
        if size==0 {return out[:],nil}
        if _,aerr:=append(&out,..transmute([]u8)rest[:size]);aerr!=nil {return nil,.Out_Of_Memory}
        rest=rest[size:]
        if !strings.has_prefix(rest,"\r\n") {return nil,.Malformed}
        rest=rest[2:]
    }
}

// The value of a header, by its name in any case.
header_value :: proc(headers,name:string) -> (value:string,found:bool) {
    rest:=headers
    for rest!="" {
        line:=rest
        if end:=strings.index(rest,"\r\n");end>=0 {
            line,rest=rest[:end],rest[end+2:]
        } else {
            rest=""
        }
        colon:=strings.index_byte(line,':')
        if colon>0 && strings.equal_fold(line[:colon],name) {return strings.trim_space(line[colon+1:]),true}
    }
    return "",false
}
