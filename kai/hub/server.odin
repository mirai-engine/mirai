package hub

import "core:net"
import "core:strings"
import "mirai:kai"
import "mirai:net/tls"

// The connections of the hub over the system's TCP, without blocking: each
// step takes what a socket holds, hands it to TLS when the connection is
// secure, parses requests one at a time and sends what the answer and TLS
// give. A connection ends on any refusal, past its deadlines or after
// REQUESTS_PER_CONNECTION requests. The secure port is the node's relay over
// TCP too: a connection whose first byte is the relay's magic, never that of
// a TLS record, goes to the runner (kai.runner_tcp_adopt).

INPUT_MAX :: HEAD_MAX+BODY_MAX
@(private) RAW_MAX :: 16<<10

Conn :: struct {
    socket:net.TCP_Socket,
    address:[16]u8,       // of the peer, IPv4 as IPv4-mapped
    source:net.Endpoint,
    secure:bool,
    sniffed:bool,         // its first byte was read
    given:bool,           // the runner holds the socket
    tls:^tls.Conn,
    raw:[RAW_MAX]u8,      // received, not yet taken by TLS
    raw_len:int,
    input:[INPUT_MAX]u8,  // plaintext of the requests
    input_len:int,
    output:[dynamic]u8,   // the answer being sent
    output_at:int,
    plain_end:bool,       // the peer ended its side
    closing:bool,         // close once the output is sent
    closed:bool,
    opened,request_at,active:f64,
    requests:int,
    continued:bool,       // 100 Continue sent for the request in progress
}

@(private)
accept_all :: proc(h:^Hub,listener:net.TCP_Socket,secure:bool) -> (busy:bool) {
    for _ in 0..<64 {
        socket,source,e:=net.accept_tcp(listener)
        if e!=nil {return}
        busy=true
        net.set_blocking(socket,false)
        address:=address_bytes(source.address)
        slot,same:=-1,0
        for c,i in h.conns {
            if c==nil {
                if slot<0 {slot=i}
                continue
            }
            if c.address==address {same+=1}
        }
        if slot<0 || same>=CONNECTIONS_PER_ADDRESS {
            h.stats.refused+=1
            net.close(socket)
            continue
        }
        c,ne:=new(Conn,h.allocator)
        if ne!=nil {
            net.close(socket)
            continue
        }
        c.socket,c.address,c.source,c.secure=socket,address,source,secure
        c.opened,c.active=h.now,h.now
        c.output=make([dynamic]u8,h.allocator)
        if secure {
            conn,te:=tls.create(certs_config(h),.Server,h.allocator)
            if te!=nil {
                net.close(socket)
                delete(c.output)
                free(c,h.allocator)
                continue
            }
            c.tls=conn
        }
        h.conns[slot]=c
        h.stats.connections+=1
    }
    return
}

address_bytes :: proc(a:net.Address) -> (out:[16]u8) {
    switch v in a {
    case net.IP4_Address:
        out[10],out[11]=0xff,0xff
        x:=v
        copy(out[12:],x[:])
    case net.IP6_Address:
        b:=transmute([16]u8)v
        out=b
    }
    return
}

conn_free :: proc(h:^Hub,c:^Conn) {
    if !c.given {net.close(c.socket)}
    if c.tls!=nil {tls.destroy(c.tls)}
    delete(c.output)
    free(c,h.allocator)
}

// What the connection does in one step; busy when anything moved.
@(private)
conn_step :: proc(h:^Hub,c:^Conn) -> (busy:bool) {
    busy|=conn_receive(h,c)
    if c.closed {return}
    busy|=conn_serve(h,c)
    busy|=conn_send(h,c)
    if c.closed {return}
    if busy {c.active=h.now}
    // Deadlines: the handshake, a request's head and body, idle keep-alive and a stalled answer.
    switch {
    case c.tls!=nil && !tls.connected(c.tls) && h.now-c.opened>HANDSHAKE_SECONDS: c.closed=true
    case c.input_len>0 && h.now-c.request_at>BODY_SECONDS: c.closed=true
    case c.input_len>0 && !head_whole(c) && h.now-c.request_at>HEAD_SECONDS: c.closed=true
    case len(c.output)>c.output_at && h.now-c.active>WRITE_SECONDS: c.closed=true
    case c.input_len==0 && len(c.output)==c.output_at && h.now-c.active>IDLE_SECONDS: c.closed=true
    }
    if c.closing && len(c.output)==c.output_at && (c.tls==nil || len(tls.pending(c.tls))==0) {c.closed=true}
    if c.plain_end && len(c.output)==c.output_at && c.input_len==0 {c.closed=true}
    return
}

@(private)
head_whole :: proc(c:^Conn) -> bool {
    return strings.index(string(c.input[:min(c.input_len,HEAD_MAX)]),"\r\n\r\n")>=0
}

// Takes what the socket holds into the plaintext input.
@(private)
conn_receive :: proc(h:^Hub,c:^Conn) -> (busy:bool) {
    for _ in 0..<8 {
        room:=c.secure?RAW_MAX-c.raw_len:INPUT_MAX-c.input_len
        if room==0 || c.plain_end || c.closing {break}
        target:=c.secure?c.raw[c.raw_len:]:c.input[c.input_len:]
        n,e:=net.recv_tcp(c.socket,target[:room])
        if e!=nil {
            if e!=.Would_Block && e!=.Interrupted {c.closed=true}
            break
        }
        if n==0 {
            c.plain_end=true
            break
        }
        busy=true
        if c.secure {
            c.raw_len+=n
        } else {
            if c.input_len==0 {c.request_at=h.now}
            c.input_len+=n
        }
    }
    if c.secure && !c.closed && !c.sniffed && c.raw_len>0 {
        c.sniffed=true
        if c.raw[0]==kai.RELAY_TCP_MAGIC[0] {
            kai.runner_tcp_adopt(h.desc.runner,c.socket,c.source,c.raw[:c.raw_len])
            c.given,c.closed=true,true
            return true
        }
    }
    if c.secure && !c.closed {busy|=conn_tls_in(h,c)}
    return
}

@(private)
conn_tls_in :: proc(h:^Hub,c:^Conn) -> (busy:bool) {
    for {
        moved:=false
        if c.raw_len>0 {
            taken,e:=tls.receive(c.tls,c.raw[:c.raw_len])
            if taken>0 {
                copy(c.raw[:],c.raw[taken:c.raw_len])
                c.raw_len-=taken
                moved=true
            }
            if e!=nil && e!=.Closed {
                conn_flush_tls(c)
                c.closed=true
                return true
            }
            if e==.Closed {c.plain_end=true}
        }
        for c.input_len<INPUT_MAX {
            n,_:=tls.read(c.tls,c.input[c.input_len:])
            if n==0 {break}
            if c.input_len==0 {c.request_at=h.now}
            c.input_len+=n
            moved=true
        }
        busy|=moved
        if !moved {break}
    }
    return
}

// Answers the requests the input holds whole, one at a time.
@(private)
conn_serve :: proc(h:^Hub,c:^Conn) -> (busy:bool) {
    for c.input_len>0 && len(c.output)==c.output_at && !c.closing {
        p:=request_parse(c.input[:c.input_len])
        if p.status==0 {
            if p.head_done && p.request.expect_continue && !c.continued {
                c.continued=true
                conn_queue(c,transmute([]u8)string("HTTP/1.1 100 Continue\r\n\r\n"))
                return true
            }
            if c.input_len==INPUT_MAX {conn_refuse(h,c,413)}
            return
        }
        busy=true
        h.stats.requests+=1
        if p.status!=200 {
            conn_refuse(h,c,p.status)
            return
        }
        r:=&p.request
        c.requests+=1
        keep:=r.keep_alive && c.requests<REQUESTS_PER_CONNECTION
        response:=dispatch(h,c,r)
        response.close|=!keep
        conn_answer(h,c,r.method,&response)
        size:=r.size
        copy(c.input[:],c.input[size:c.input_len])
        c.input_len-=size
        c.continued=false
        c.request_at=h.now
        if response.close {c.closing=true}
    }
    return
}

@(private)
conn_refuse :: proc(h:^Hub,c:^Conn,status:int) {
    h.stats.refused+=1
    response:=error_response(status,reason(status))
    response.close=true
    conn_answer(h,c,.GET,&response)
    c.closing=true
    c.input_len=0
}

@(private)
conn_queue :: proc(c:^Conn,bytes:[]u8) {
    if c.output_at==len(c.output) {
        clear(&c.output)
        c.output_at=0
    }
    if _,e:=append(&c.output,..bytes);e!=nil {c.closed=true}
}

// Sends what the answer holds, through TLS when the connection is secure.
@(private)
conn_send :: proc(h:^Hub,c:^Conn) -> (busy:bool) {
    if c.tls!=nil {
        for c.output_at<len(c.output) && tls.connected(c.tls) {
            n,e:=tls.write(c.tls,c.output[c.output_at:])
            if e!=nil {
                c.closed=true
                return true
            }
            if n==0 {break}
            c.output_at+=n
            busy=true
        }
        if c.closing && c.output_at==len(c.output) && tls.connected(c.tls) {tls.close(c.tls)}
        busy|=conn_flush_tls(c)
        if c.output_at<len(c.output) && !busy {
            // The TLS output was full: it drains as the socket takes it.
            busy|=conn_flush_tls(c)
        }
        return
    }
    for c.output_at<len(c.output) {
        n,e:=net.send_tcp(c.socket,c.output[c.output_at:])
        c.output_at+=n
        if n>0 {busy=true}
        if e!=nil {
            if e!=.Would_Block && e!=.Interrupted {c.closed=true}
            break
        }
    }
    if c.output_at==len(c.output) && c.output_at>0 {
        clear(&c.output)
        c.output_at=0
    }
    return
}

@(private)
conn_flush_tls :: proc(c:^Conn) -> (busy:bool) {
    for p:=tls.pending(c.tls);len(p)>0;p=tls.pending(c.tls) {
        n,e:=net.send_tcp(c.socket,p)
        if n>0 {
            tls.sent(c.tls,n)
            busy=true
        }
        if e!=nil {
            if e!=.Would_Block && e!=.Interrupted {c.closed=true}
            break
        }
        if n==0 {break}
    }
    return
}

// Writes the status line, the headers and the body of response.
@(private)
conn_answer :: proc(h:^Hub,c:^Conn,method:Method,response:^Response) {
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"HTTP/1.1 ")
    strings.write_int(&b,response.status)
    strings.write_byte(&b,' ')
    strings.write_string(&b,reason(response.status))
    strings.write_string(&b,"\r\n")
    strings.write_string(&b,SECURITY_HEADERS)
    if c.secure {strings.write_string(&b,"Strict-Transport-Security: max-age=63072000\r\n")}
    if response.content_type!="" {
        strings.write_string(&b,"Content-Type: ")
        strings.write_string(&b,response.content_type)
        strings.write_string(&b,"\r\n")
    }
    if response.cache=="" {response.cache="no-store"}
    strings.write_string(&b,"Cache-Control: ")
    strings.write_string(&b,response.cache)
    strings.write_string(&b,"\r\n")
    strings.write_string(&b,response.headers)
    strings.write_string(&b,"Content-Length: ")
    strings.write_int(&b,len(response.body))
    strings.write_string(&b,"\r\n")
    if response.close {strings.write_string(&b,"Connection: close\r\n")}
    strings.write_string(&b,"\r\n")
    conn_queue(c,b.buf[:])
    if method!=.HEAD {conn_queue(c,response.body)}
}
