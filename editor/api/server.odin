package api

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

HEAD_MAX :: 8192
HEAD_ROOM :: 192

MIN_RESPONSE :: 4096

@(private)
or_default :: #force_inline proc(value,default:int) -> int {return value>0?value:default}

server_init :: proc(s:^Server,desc:Server_Desc) -> Init_Error {
    s^={}
    allocator:=desc.allocator
    if allocator.procedure==nil {allocator=context.allocator}
    s.allocator=allocator
    s.max_request=or_default(desc.max_request,256*1024)
    s.max_response=max(or_default(desc.max_response,1<<20),MIN_RESPONSE)
    max_methods:=or_default(desc.max_methods,256)
    max_connections:=or_default(desc.max_connections,8)
    s.timeout=time.Duration(or_default(desc.timeout_ms,5000))*time.Millisecond
    s.sending=-1
    stride:=HEAD_MAX+s.max_request
    s.methods=make([]Method,max_methods,allocator)
    s.conns=make([]Conn,max_connections,allocator)
    s.conn_memory=make([]u8,max_connections*stride,allocator)
    s.response=make([]u8,HEAD_ROOM+s.max_response,allocator)
    s.staging=make([]u8,s.max_response,allocator)
    if s.methods==nil || s.conns==nil || s.conn_memory==nil || s.response==nil || s.staging==nil {server_destroy(s);return .Out_Of_Memory}
    for &conn,i in s.conns {conn.buffer=s.conn_memory[i*stride:][:stride]}
    if !base.arena_init(&s.scratch,max(or_default(desc.scratch,2<<20),2*s.max_request+64*1024),allocator) {server_destroy(s);return .Out_Of_Memory}
    if !base.arena_init(&s.text,2*s.max_request+4096,allocator) {server_destroy(s);return .Out_Of_Memory}
    serial.schema_init(&s.schema,allocator)
    s.tags=make([dynamic]Field_Tags,allocator)
    s.keys=make([dynamic]string,allocator)
    s.name=clone_text(allocator,desc.name!=""?desc.name:"mirai")
    s.version=clone_text(allocator,desc.version!=""?desc.version:"1")
    s.instructions=clone_text(allocator,desc.instructions!=""?desc.instructions:"engine_describe lists the methods and the plugins of the project; the tools of a plugin come with mirai mcp --plugins <names>.")
    s.docs_root=clone_text(allocator,desc.docs_root)
    serial.writer_init_fixed(&s.out,s.response[HEAD_ROOM:])
    serial.writer_init_fixed(&s.stage,s.staging)
    if !desc.local {
        err:net.Network_Error
        s.listener,err=net.listen_tcp({address=net.IP4_Loopback,port=desc.port},16)
        if err!=nil {server_destroy(s);return .Bind_Failed}
        s.listening=true
        socket_private(s.listener)
        if net.set_blocking(s.listener,false)!=nil {server_destroy(s);return .Bind_Failed}
        endpoint,_:=net.bound_endpoint(s.listener)
        s.port=endpoint.port
    }
    if !describe_register(s) {server_destroy(s);return .Out_Of_Memory}
    return .None
}

server_destroy :: proc(s:^Server) {
    for &conn in s.conns {if conn.state!=.Free {net.close(conn.socket)}}
    if s.listening {net.close(s.listener)}
    for &method in s.methods[:s.method_count] {
        delete(method.name,s.allocator);delete(method.summary,s.allocator);delete(method.plugin,s.allocator);delete(method.defaults,s.allocator)
        delete(method.params_schema,s.allocator);delete(method.result_schema,s.allocator)
    }
    delete(s.name,s.allocator);delete(s.version,s.allocator);delete(s.instructions,s.allocator);delete(s.docs_root,s.allocator)
    plugins_free(s)
    guides_free(s)
    delete(s.methods,s.allocator);delete(s.conns,s.allocator);delete(s.conn_memory,s.allocator)
    delete(s.response,s.allocator);delete(s.staging,s.allocator)
    delete(s.tags)
    for key in s.keys {delete(key,s.allocator)}
    delete(s.keys)
    base.arena_destroy(&s.scratch);base.arena_destroy(&s.text)
    if s.schema.types!=nil {serial.schema_destroy(&s.schema)}
    s^={}
}

server_port :: #force_inline proc(s:^Server) -> int {return s.port}

// The plugins the project finds, which engine.describe lists. Copied.
server_plugins_set :: proc(s:^Server,plugins:[]Plugin) {
    plugins_free(s)
    if len(plugins)==0 {return}
    s.plugins=make([]Plugin,len(plugins),s.allocator)
    for plugin,i in plugins {s.plugins[i]={clone_text(s.allocator,plugin.name),plugin.active}}
}

// The guides engine.describe gives with the methods they are about.
server_guides_set :: proc(s:^Server,guides:[]Guide) {
    guides_free(s)
    if len(guides)==0 {return}
    s.guides=make([]Guide,len(guides),s.allocator)
    for guide,i in guides {s.guides[i]={clone_text(s.allocator,guide.topic),clone_text(s.allocator,guide.text)}}
}

@(private)
guides_free :: proc(s:^Server) {
    for guide in s.guides {delete(guide.topic,s.allocator);delete(guide.text,s.allocator)}
    delete(s.guides,s.allocator)
    s.guides=nil
}

@(private)
plugins_free :: proc(s:^Server) {
    for plugin in s.plugins {delete(plugin.name,s.allocator)}
    delete(s.plugins,s.allocator)
    s.plugins=nil
}

// Between calls, after a library reload. Connections and response buffers stay valid.
server_methods_reset :: proc(s:^Server) -> bool {
    for &method in s.methods[:s.method_count] {
        delete(method.name,s.allocator);delete(method.summary,s.allocator);delete(method.plugin,s.allocator);delete(method.defaults,s.allocator)
        delete(method.params_schema,s.allocator);delete(method.result_schema,s.allocator)
        method={}
    }
    s.method_count=0
    serial.schema_destroy(&s.schema)
    serial.schema_init(&s.schema,s.allocator)
    clear(&s.tags)
    for key in s.keys {delete(key,s.allocator)}
    clear(&s.keys)
    return describe_register(s)
}

// Accepts connections, reads requests and answers the ones that are complete.
// Returns how many it answered. Nothing blocks and nothing is allocated.
server_poll :: proc(s:^Server) -> int {
    if !s.listening {return 0}
    now:=time.tick_now()
    answered:=0
    if s.sending>=0 {send_progress(s,now)}
    for &conn in s.conns {
        if conn.state==.Free && !conn_accept(s,&conn) {break}
    }
    for &conn,i in s.conns {
        switch conn.state {
        case .Reading: conn_read(s,&conn,now)
        case .Draining: conn_drain(s,&conn,now)
        case .Ready:
            if time.tick_diff(conn.started,now)>s.timeout && s.sending!=i {s.stats.timeouts+=1;conn_close(&conn)}
        case .Free:
        }
        if conn.state==.Ready && s.sending<0 {
            conn_answer(s,&conn,i)
            answered+=1
            if s.sending>=0 {send_progress(s,now)}
        }
        if s.sending==i && time.tick_diff(conn.started,now)>s.timeout {
            s.stats.timeouts+=1;conn_close(&conn);s.sending=-1
        }
    }
    return answered
}

// Sockets server_wait watches: the listener and the connections being read.
WAIT_SOCKETS :: 32

// Waits until a request can be read or timeout passes: an idle server wakes
// as a request arrives, not at the next tick of the timer of the system. It
// does not wait while an answer is pending.
server_wait :: proc(s:^Server,timeout:time.Duration) {
    if !s.listening || s.sending>=0 {return}
    sockets:[WAIT_SOCKETS]net.TCP_Socket
    sockets[0]=s.listener
    count:=1
    for conn in s.conns {
        switch conn.state {
        case .Ready: return
        case .Reading,.Draining:
            if count<len(sockets) {sockets[count]=conn.socket;count+=1}
        case .Free:
        }
    }
    sockets_wait(sockets[:count],timeout)
}

@(private)
conn_accept :: proc(s:^Server,conn:^Conn) -> bool {
    socket,_,err:=net.accept_tcp(s.listener)
    if err!=nil {return false}
    if net.set_blocking(socket,false)!=nil {net.close(socket);return true}
    socket_private(socket)
    s.stats.connections+=1
    conn^={socket=socket,state=.Reading,buffer=conn.buffer,started=time.tick_now()}
    return true
}

@(private)
conn_close :: proc(conn:^Conn) {
    net.close(conn.socket)
    conn^={buffer=conn.buffer}
}

@(private)
conn_reject :: proc(s:^Server,conn:^Conn,status:int,message:string,now:time.Tick) {
    conn.reject,conn.reject_message=status,message
    conn.state=.Ready
    conn.started=now
    s.stats.rejected+=1
}

@(private)
conn_read :: proc(s:^Server,conn:^Conn,now:time.Tick) {
    // A connection a client keeps between requests waits for it without limit.
    idle:=conn.keep && conn.used==0
    if !idle && time.tick_diff(conn.started,now)>s.timeout {s.stats.timeouts+=1;conn_close(conn);return}
    for conn.state==.Reading {
        if conn.used>=len(conn.buffer) {conn_reject(s,conn,431,"request header too large",now);return}
        n,err:=net.recv_tcp(conn.socket,conn.buffer[conn.used:])
        if err==.Would_Block {return}
        if err!=nil || n==0 {conn_close(conn);return}
        scanned:=max(conn.used-3,0)
        conn.used+=n
        if conn.head==0 {
            end:=strings.index(string(conn.buffer[scanned:conn.used]),"\r\n\r\n")
            if end<0 {
                if conn.used>HEAD_MAX {conn_reject(s,conn,431,"request header too large",now);return}
                continue
            }
            end+=scanned
            if end+4>HEAD_MAX {conn_reject(s,conn,431,"request header too large",now);return}
            status,message:=head_parse(s,conn,string(conn.buffer[:end]))
            if status!=0 {conn_reject(s,conn,status,message,now);return}
            conn.head=end+4
        }
        if conn.used>=conn.head+conn.length {
            conn.state=.Ready
            conn.started=now
        }
    }
}

@(private)
conn_drain :: proc(s:^Server,conn:^Conn,now:time.Tick) {
    limit:=len(conn.buffer)*2
    if time.tick_diff(conn.started,now)>min(s.timeout,time.Second) || conn.drained>limit {conn_close(conn);return}
    for {
        n,err:=net.recv_tcp(conn.socket,conn.buffer)
        if err==.Would_Block {return}
        if err!=nil || n==0 {conn_close(conn);return}
        conn.drained+=n
        if conn.drained>limit {conn_close(conn);return}
    }
}

HTTP_STATUS :: [?]struct{code:int,text:string}{
    {200,"OK"},{202,"Accepted"},{400,"Bad Request"},{403,"Forbidden"},{404,"Not Found"},{405,"Method Not Allowed"},
    {411,"Length Required"},{413,"Payload Too Large"},{415,"Unsupported Media Type"},{431,"Request Header Fields Too Large"},
}

@(private)
header_value :: proc(line:string) -> (name,value:string,ok:bool) {
    colon:=strings.index_byte(line,':')
    if colon<=0 {return "","",false}
    return strings.trim_space(line[:colon]),strings.trim_space(line[colon+1:]),true
}

@(private)
host_is_loopback :: proc(host:string) -> bool {
    name:=host
    if len(name)>0 && name[0]=='[' {
        end:=strings.index_byte(name,']')
        if end<0 {return false}
        name=name[:end+1]
    } else if colon:=strings.index_byte(name,':');colon>=0 {
        name=name[:colon]
    }
    return name=="127.0.0.1" || name=="localhost" || name=="[::1]"
}

// The request line and the headers, without the blank line that ends them.
@(private)
head_parse :: proc(s:^Server,conn:^Conn,head:string) -> (status:int,message:string) {
    rest:=head
    line,_:=strings.split_lines_iterator(&rest)
    first:=strings.index_byte(line,' ')
    last:=strings.last_index_byte(line,' ')
    if first<=0 || last<=first {return 400,"malformed request line"}
    method,target,version:=line[:first],line[first+1:last],line[last+1:]
    if version!="HTTP/1.1" && version!="HTTP/1.0" {return 400,"unsupported HTTP version"}
    if query:=strings.index_byte(target,'?');query>=0 {target=target[:query]}
    switch target {
    case "/rpc": conn.route=.Rpc
    case "/mcp": conn.route=.Mcp
    case: return 404,"unknown path: POST /rpc or /mcp"
    }
    if method!="POST" {return 405,"only POST is allowed"}
    length,has_length,json_type:=-1,false,false
    for header in strings.split_lines_iterator(&rest) {
        name,value,ok:=header_value(header)
        if !ok {return 400,"malformed header"}
        switch {
        case strings.equal_fold(name,"content-length"):
            parsed,valid:=strconv.parse_int(value,10)
            if !valid || parsed<0 || (has_length && parsed!=length) {return 400,"invalid Content-Length"}
            length,has_length=parsed,true
        case strings.equal_fold(name,"transfer-encoding"):
            return 411,"Content-Length is required; chunked bodies are not accepted"
        case strings.equal_fold(name,"connection"):
            conn.keep=strings.equal_fold(value,"keep-alive")
        case strings.equal_fold(name,"accept"):
            conn.stream=strings.contains(value,"text/event-stream")
        case strings.equal_fold(name,"content-type"):
            kind:=value
            if semicolon:=strings.index_byte(kind,';');semicolon>=0 {kind=strings.trim_space(kind[:semicolon])}
            json_type=strings.equal_fold(kind,"application/json")
        case strings.equal_fold(name,"origin"):
            return 403,"requests from web pages are not accepted"
        case strings.equal_fold(name,"host"):
            if !host_is_loopback(value) {return 403,"the host must be loopback"}
        case strings.equal_fold(name,"x-mirai-ai-task"):
            if len(value)==0 || len(value)>=len(conn.client_tag) {return 400,"invalid task context"}
            if previous:=base.text_get(conn.client_tag[:]);previous!="" && previous!=value {return 400,"conflicting task context"}
            for byte in value {if byte<33 || byte>126 {return 400,"invalid task context"}}
            base.text_set(conn.client_tag[:],value)
        case strings.equal_fold(name,"x-mirai-client"):
            if !client_name_valid(value) {return 400,"invalid X-Mirai-Client: up to 31 letters, digits, '.', '_' or '-'"}
            if previous:=base.text_get(conn.client_name[:]);previous!="" && previous!=value {return 400,"conflicting X-Mirai-Client"}
            base.text_set(conn.client_name[:],value)
        case strings.equal_fold(name,"x-mirai-measure"):
            if len(value)==0 || len(value)>=len(conn.measure) {return 400,"invalid X-Mirai-Measure: the pid of the measurement"}
            for byte in value {if byte<'0' || byte>'9' {return 400,"invalid X-Mirai-Measure: the pid of the measurement"}}
            base.text_set(conn.measure[:],value)
        case strings.equal_fold(name,"x-mirai-plugins"):
            if len(value)==0 || len(value)>=len(conn.plugins) {return 400,"invalid X-Mirai-Plugins: names of plugins separated by commas, or *"}
            if previous:=base.text_get(conn.plugins[:]);previous!="" && previous!=value {return 400,"conflicting X-Mirai-Plugins"}
            for byte in value {
                if !(byte>='a' && byte<='z' || byte>='A' && byte<='Z' || byte>='0' && byte<='9' || byte=='_' || byte=='-' || byte=='.' || byte==',' || byte==' ' || byte=='*') {
                    return 400,"invalid X-Mirai-Plugins: names of plugins separated by commas, or *"
                }
            }
            base.text_set(conn.plugins[:],value)
        }
    }
    if !has_length {return 411,"Content-Length is required"}
    if length>s.max_request {return 413,"request body too large"}
    if !json_type {return 415,"Content-Type must be application/json"}
    conn.length=length
    return 0,""
}

// Runs the request of the connection into s.response and starts sending it.
@(private)
conn_answer :: proc(s:^Server,conn:^Conn,index:int) {
    serial.writer_reset(&s.out)
    status:=200
    has_body:=true
    if conn.reject!=0 {
        status=conn.reject
        write_error_envelope(base.arena_allocator(&s.scratch),&s.out,"",{INVALID_REQUEST,conn.reject_message,""})
    } else {
        body:=string(conn.buffer[conn.head:][:conn.length])
        s.running={conn=index}
        has_body=process(s,body,conn.route,base.text_get(conn.client_tag[:]),base.text_get(conn.plugins[:]),base.text_get(conn.client_name[:]),base.text_get(conn.measure[:]))
        running_end(s)
        if !has_body {status=202}
    }
    if s.running.streamed && has_body {
        // The answer is the last event of the stream its progress opened.
        serial.text_write_raw(&s.out,"\n\n")
        conn.keep=false
        start:=HEAD_ROOM-len(STREAM_DATA)
        copy(s.response[start:],STREAM_DATA)
        s.sending,s.send_at,s.send_end=index,start,HEAD_ROOM+len(serial.writer_bytes(&s.out))
        conn.started=time.tick_now()
        return
    }
    body_bytes:=serial.writer_bytes(&s.out)
    if !has_body {body_bytes=nil}
    head_buffer:[HEAD_ROOM]u8
    text:string
    for entry in HTTP_STATUS {if entry.code==status {text=entry.text}}
    allow:=status==405?"Allow: POST\r\n":""
    keep:=conn.keep && conn.reject==0 && conn.used==conn.head+conn.length
    conn.keep=keep
    head:=fmt.bprintf(head_buffer[:],"HTTP/1.1 %d %s\r\n%sContent-Type: application/json\r\nContent-Length: %d\r\nConnection: %s\r\n\r\n",status,text,allow,len(body_bytes),keep?"keep-alive":"close")
    start:=HEAD_ROOM-len(head)
    copy(s.response[start:],head)
    s.sending=index
    s.send_at=start
    s.send_end=HEAD_ROOM+len(body_bytes)
    conn.started=time.tick_now()
}

@(private)
send_progress :: proc(s:^Server,now:time.Tick) {
    conn:=&s.conns[s.sending]
    for s.send_at<s.send_end {
        n,err:=net.send_tcp(conn.socket,s.response[s.send_at:s.send_end])
        s.send_at+=n
        if err==.Would_Block {return}
        if err!=nil || n==0 {conn_close(conn);s.sending=-1;return}
    }
    s.sending=-1
    if conn.keep {
        // The next request of the same client: everything per-request starts over.
        conn^={socket=conn.socket,state=.Reading,buffer=conn.buffer,started=now,keep=true}
        return
    }
    if conn.reject!=0 || conn.used>conn.head+conn.length {
        net.shutdown(conn.socket,.Send)
        conn.state=.Draining
        conn.started=now
        conn.drained=0
    } else {
        conn_close(conn)
    }
}
