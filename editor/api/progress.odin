package api

import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

// A tools/call that takes long stays alive and can be stopped. With
// _meta.progressToken and an Accept of text/event-stream, the answer of its POST
// is a stream of server-sent events: notifications/progress as the work goes
// and its answer last. Without them it is one JSON, as any other. While a
// handler waits, server_cancelled reads what has arrived, as only a cancellation
// can be answered then; the handler ends at its next safe point and the call
// answers CANCELLED.

@(private) PROGRESS_INTERVAL :: time.Second
@(private) CANCEL_POLL :: 100*time.Millisecond
@(private) STREAM_SEND_TRIES :: 2000 // of 1 ms, for a client slow to read
@(private) STREAM_HEAD :: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
@(private) STREAM_DATA :: "event: message\ndata: "

// The call that runs, while its handler holds the server.
Running :: struct {
    active:bool,
    conn:int,
    id,token:[128]u8,    // their JSON
    streamed:bool,       // the head of the answer is on its way
    sent:int,            // progress notifications
    last_sent,last_polled:time.Tick,
    polled:bool,         // other connections were read meanwhile
    stopped:bool,        // the client cancelled it and the handler is told
    lost:bool,           // the stream of its client broke
}

// Starts the call of a tools/call: its id, and its token when it streams.
@(private)
running_begin :: proc(s:^Server,req:^Request) {
    r:=&s.running
    conn:=r.conn
    r^={conn=conn}
    if !req.has_id || len(req.id)>=len(r.id) {return}
    base.text_set(r.id[:],req.id)
    r.active=true
    values:[1]string
    if !object_values(context.temp_allocator,req.params,{"_meta"},values[:]) || values[0]=="" {return}
    token:[1]string
    if object_values(context.temp_allocator,values[0],{"progressToken"},token[:]) && len(token[0])<len(r.token) {base.text_set(r.token[:],token[0])}
}

// Whether a new progress notification would be sent now.
server_progress_due :: proc(s:^Server) -> bool {
    r:=&s.running
    if !r.active || r.token[0]==0 || r.lost || !s.conns[r.conn].stream {return false}
    return r.sent==0 || time.tick_since(r.last_sent)>=PROGRESS_INTERVAL
}

// Tells the client of the running call what is happening; done and total, when
// known, in units of the work.
server_progress :: proc(s:^Server,message:string,done:=-1,total:=-1) {
    if !server_progress_due(s) {return}
    r:=&s.running
    r.last_sent=time.tick_now()
    r.sent+=1
    b:=strings.builder_make(context.temp_allocator)
    if !r.streamed {strings.write_string(&b,STREAM_HEAD)}
    fmt.sbprintf(&b,`%s{{"jsonrpc":"2.0","method":"notifications/progress","params":{{"progressToken":%s,"progress":%d`,STREAM_DATA,base.text_get(r.token[:]),done>=0?done:r.sent)
    if total>=0 {fmt.sbprintf(&b,`,"total":%d`,total)}
    fmt.sbprintf(&b,`,"message":%s}}}}`+"\n\n",serial.text_quote(message,context.temp_allocator))
    r.streamed=true
    if !stream_send(&s.conns[r.conn],transmute([]u8)strings.to_string(b)) {r.lost=true}
}

@(private)
stream_send :: proc(conn:^Conn,bytes:[]u8) -> bool {
    at,tries:=0,0
    for at<len(bytes) {
        n,err:=net.send_tcp(conn.socket,bytes[at:])
        at+=n
        if err==.Would_Block {
            if tries>=STREAM_SEND_TRIES {return false}
            tries+=1
            time.sleep(time.Millisecond)
            continue
        }
        if err!=nil || n==0 {return false}
    }
    return true
}

// Whether the client cancelled the running call. Reads what arrived at most
// every CANCEL_POLL; true once, and for the rest of the call. It runs inside a
// handler, so it never dispatches a request: it answers a cancellation and
// nothing else, and any other request stays in its buffer, whole, for
// server_poll to answer after the handler ends.
server_cancelled :: proc(s:^Server) -> bool {
    r:=&s.running
    if !r.active {return false}
    if r.stopped {return true}
    now:=time.tick_now()
    if r.polled && time.tick_diff(r.last_polled,now)<CANCEL_POLL {return false}
    r.last_polled,r.polled=now,true
    for &conn in s.conns {
        if conn.state==.Free && !conn_accept(s,&conn) {break}
    }
    for &conn,i in s.conns {
        if i==r.conn {continue}
        if conn.state==.Reading {conn_read(s,&conn,now)}
        if conn.state==.Ready && conn.reject==0 && conn.route==.Mcp {cancel_take(s,&conn)}
    }
    return r.stopped
}

// A notifications/cancelled of a connection, answered and gone; another request stays.
@(private)
cancel_take :: proc(s:^Server,conn:^Conn) {
    body:=string(conn.buffer[conn.head:][:conn.length])
    values:[2]string
    if !object_values(context.temp_allocator,body,{"method","params"},values[:]) {return}
    if method,_:=string_value(context.temp_allocator,values[0]);method!="notifications/cancelled" {return}
    id:[1]string
    if object_values(context.temp_allocator,values[1],{"requestId"},id[:]) && id[0]==base.text_get(s.running.id[:]) {s.running.stopped=true}
    stream_send(conn,transmute([]u8)string("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
    conn_close(conn)
}

// What the server did for the running call once it ended: connections read
// meanwhile count their time from now.
@(private)
running_end :: proc(s:^Server) {
    r:=&s.running
    r.active=false
    if !r.polled {return}
    now:=time.tick_now()
    for &conn,i in s.conns {
        if i!=r.conn && conn.state!=.Free {conn.started=now}
    }
}
