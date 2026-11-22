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

// The largest response an HTTPS request takes.
@(private) RESPONSE_MAX :: 1<<20

@(private)
Http_Error :: enum u8 {None,Out_Of_Memory,Transport,Tls,Malformed}

@(private)
Response :: struct {
    status:int,
    headers:string, // the header lines, after the status line
    body:[]u8,
}

// An HTTPS request of HTTP/1.1 on a connection of its own, which the response ends. The
// response is in allocator; the connection takes its memory from scratch.
@(private)
https_request :: proc(transport:Transport,roots:[]^x509.Certificate,now:time.Time,method,url:string,body:[]u8,content_type:string,allocator,scratch:runtime.Allocator) -> (response:Response,err:Http_Error) {
    host,port,path,ok:=url_split(url)
    if !ok {return {},.Malformed}
    memory,merr:=make([]u8,len(method)+len(path)+len(host)+len(content_type)+len(body)+256,allocator)
    if merr!=nil {return {},.Out_Of_Memory}
    head:string
    if body==nil {
        head=fmt.bprintf(memory,"%s %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: mirai-acme\r\nAccept: */*\r\nConnection: close\r\n\r\n",method,path,host)
    } else {
        head=fmt.bprintf(memory,"%s %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: mirai-acme\r\nAccept: */*\r\nConnection: close\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n",method,path,host,content_type,len(body))
    }
    copy(memory[len(head):],body)
    out:=memory[:len(head)+len(body)]

    stream,dialed:=transport.dial(transport.data,host,port)
    if !dialed {return {},.Transport}
    defer transport.close(transport.data,stream)
    conn,cerr:=create({host=host,roots=roots,alpn={"http/1.1"},time=now},.Client,scratch)
    if cerr==.Out_Of_Memory {return {},.Out_Of_Memory}
    if cerr!=nil {return {},.Tls}
    defer destroy(conn)
    received:[dynamic]u8
    if received,err=make_received(allocator);err!=nil {return}
    written:=0
    buffer:[16<<10]u8
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

// "https://host[:port]/path": its parts, the port 443 when it says none.
@(private)
url_split :: proc(url:string) -> (host:string,port:int,path:string,ok:bool) {
    if !strings.has_prefix(url,"https://") {return}
    rest:=url[len("https://"):]
    slash:=strings.index_byte(rest,'/')
    authority:=rest if slash<0 else rest[:slash]
    path="/" if slash<0 else rest[slash:]
    port=443
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
@(private)
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
