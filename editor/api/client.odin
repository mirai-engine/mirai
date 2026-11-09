package api

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:std/serial"

// A blocking client for a Server on this machine, for the command line. What
// it returns is allocated with the allocator it is given: pass an arena.

CLIENT_MAX_RESPONSE :: 32<<20
CLIENT_POLL_MS :: 1000      // between looks at the editor while no answer comes
CLIENT_HUNG_SECONDS :: 30   // without any CPU use by the editor: it hung, it is not busy
CLIENT_NOTICE_SECONDS :: 30 // between the notices of a call that goes on waiting

// What a client knows of the editor it waits for, to tell one that works from
// one that ended or hung. Zero for a wait bound only by its timeout.
Client_Watch :: struct {
    pid:int,      // 0: unknown, only the connection tells
    log:string,   // of that editor; "" when it has none
    label:string, // what the notices of a long wait name; "": no notices
}

// What the system says of a process. work grows while any of its threads
// runs; its unit depends on the system, so only whether it changed counts.
@(private)
Process_Sample :: struct {
    work:u64,
    known,gone:bool, // known: work was read; gone: the process ended
}

// The wait of one call for its answer.
@(private)
Client_Waiting :: struct {
    started,quiet:time.Tick, // when it began; when work last changed
    work:u64,
    sampled:bool,            // work holds a reading
    noticed:int,             // the seconds its last notice said
}

client_error :: proc(allocator:runtime.Allocator,code:int,format:string,args:..any) -> Error {
    return {code,format_text(allocator,format,..args),""}
}

// POST of a JSON body, in the turn of an AI task when task is not empty.
// plugins: the X-Mirai-Plugins of the request, or nothing; client: the
// X-Mirai-Client. timeout_ms bounds the whole wait for the answer; with a
// watch an editor that ended or hung fails it at once. status is 0 when no
// answer arrived.
client_post :: proc(port:int,path,body:string,timeout_ms:int,allocator:runtime.Allocator,task:string="",plugins:string="",client:string="",watch:=Client_Watch{}) -> (status:int,response:[]u8,error:Error) {
    socket,dial_error:=net.dial_tcp_from_address_and_port(net.IP4_Loopback,port)
    if dial_error!=nil {return 0,nil,client_error(allocator,UNREACHABLE,"cannot reach the Mirai editor at 127.0.0.1:%d (%v)",port,dial_error)}
    defer net.close(socket)
    timeout:=time.Duration(timeout_ms)*time.Millisecond
    net.set_option(socket,.Receive_Timeout,timeout)
    net.set_option(socket,.Send_Timeout,timeout)
    turn:=fmt.aprintf("X-Mirai-Ai-Task: %s\r\n",task,allocator=allocator) if task!="" else ""
    named:=fmt.aprintf("X-Mirai-Plugins: %s\r\n",plugins,allocator=allocator) if plugins!="" else ""
    caller:=fmt.aprintf("X-Mirai-Client: %s\r\n",client,allocator=allocator) if client!="" && task=="" else ""
    request:=fmt.aprintf("POST %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Type: application/json\r\n%s%s%sContent-Length: %d\r\nConnection: close\r\n\r\n%s",path,port,turn,named,caller,len(body),body,allocator=allocator)
    for sent:=0;sent<len(request); {
        n,err:=net.send_tcp(socket,transmute([]u8)request[sent:])
        if timed_out(err) {return 0,nil,client_error(allocator,TIMEOUT,"the Mirai editor at 127.0.0.1:%d did not take the request in %d ms",port,timeout_ms)}
        if err!=nil || n==0 {return 0,nil,client_error(allocator,UNREACHABLE,"the Mirai editor at 127.0.0.1:%d closed the connection while receiving the request",port)}
        sent+=n
    }
    data:[dynamic]u8
    data.allocator=allocator
    chunk:[16384]u8
    head_end,length:=-1,-1
    waiting:=Client_Waiting{started=time.tick_now()}
    for {
        if wait_error:=client_wait(socket,port,timeout_ms,watch,&waiting,allocator);wait_error.code!=0 {return 0,nil,wait_error}
        n,err:=net.recv_tcp(socket,chunk[:])
        if timed_out(err) {return 0,nil,client_error(allocator,TIMEOUT,"the Mirai editor at 127.0.0.1:%d did not answer in %d ms",port,timeout_ms)}
        if err!=nil || n==0 {break}
        append(&data,..chunk[:n])
        if len(data)>CLIENT_MAX_RESPONSE {return 0,nil,client_error(allocator,BAD_RESPONSE,"the answer exceeds %d bytes",CLIENT_MAX_RESPONSE)}
        if head_end<0 {
            if end:=strings.index(string(data[:]),"\r\n\r\n");end>=0 {
                head_end=end+4
                status,length=response_head(string(data[:end]))
                if status==0 {return 0,nil,client_error(allocator,BAD_RESPONSE,"the answer is not HTTP")}
            }
        }
        if head_end>=0 && length>=0 && len(data)>=head_end+length {break}
    }
    if len(data)==0 {
        if watch.pid!=0 && process_sample(watch.pid).gone {return 0,nil,client_ended(allocator,port,watch)}
        return 0,nil,client_error(allocator,CLOSED,"the Mirai editor at 127.0.0.1:%d closed the connection without answering",port)
    }
    if head_end<0 {return 0,nil,client_error(allocator,BAD_RESPONSE,"the Mirai editor at 127.0.0.1:%d closed the connection in the middle of its answer",port)}
    available:=len(data)-head_end
    if length>=0 && available<length {return 0,nil,client_error(allocator,BAD_RESPONSE,"the answer was cut short")}
    count:=length>=0?length:available
    response=make([]u8,count,allocator)
    copy(response,data[head_end:][:count])
    delete(data)
    return
}

// Blocks until the socket has something to read, for as long as the editor is
// alive and working and timeout_ms allows; an Error says why it stopped.
@(private)
client_wait :: proc(socket:net.TCP_Socket,port,timeout_ms:int,watch:Client_Watch,waiting:^Client_Waiting,allocator:runtime.Allocator) -> Error {
    sockets:=[1]net.TCP_Socket{socket}
    for {
        elapsed:=int(time.duration_milliseconds(time.tick_since(waiting.started)))
        if elapsed>=timeout_ms {return client_error(allocator,TIMEOUT,"the Mirai editor at 127.0.0.1:%d did not answer in %d ms",port,timeout_ms)}
        if sockets_wait(sockets[:],time.Duration(min(CLIENT_POLL_MS,timeout_ms-elapsed))*time.Millisecond) {return {}}
        if watch.pid!=0 {
            sample:=process_sample(watch.pid)
            if sample.gone {return client_ended(allocator,port,watch)}
            if sample.known && client_hung(waiting,sample.work,time.tick_now()) {return client_hung_error(allocator,port,watch)}
        }
        if seconds:=elapsed/1000;watch.label!="" && seconds>=waiting.noticed+CLIENT_NOTICE_SECONDS {
            waiting.noticed=seconds
            who:=watch.pid!=0?fmt.tprintf("the editor (pid %d) is working",watch.pid):fmt.tprintf("the editor at 127.0.0.1:%d has not answered",port)
            fmt.eprintfln("%s: still waiting, %d s so far: %s; --timeout S limits the wait",watch.label,seconds,who)
        }
    }
}

// Whether the process has used no CPU for CLIENT_HUNG_SECONDS up to now, with
// work its reading at that moment.
@(private)
client_hung :: proc(waiting:^Client_Waiting,work:u64,now:time.Tick) -> bool {
    if !waiting.sampled || work!=waiting.work {
        waiting.work,waiting.sampled,waiting.quiet=work,true,now
        return false
    }
    return time.duration_seconds(time.tick_diff(waiting.quiet,now))>=CLIENT_HUNG_SECONDS
}

@(private)
client_log_text :: proc(watch:Client_Watch) -> string {
    return watch.log!=""?fmt.tprintf("; its log: %s",watch.log):""
}

@(private)
client_ended :: proc(allocator:runtime.Allocator,port:int,watch:Client_Watch) -> Error {
    return client_error(allocator,CLOSED,"the Mirai editor at 127.0.0.1:%d (pid %d) ended before answering%s",port,watch.pid,client_log_text(watch))
}

@(private)
client_hung_error :: proc(allocator:runtime.Allocator,port:int,watch:Client_Watch) -> Error {
    err:=client_error(allocator,HUNG,"the Mirai editor at 127.0.0.1:%d (pid %d) is hung: it has used no CPU for %d s and has not answered%s; end the process to go on",port,watch.pid,CLIENT_HUNG_SECONDS,client_log_text(watch))
    err.data=fmt.aprintf(`{{"pid":%d,"log":%s}}`,watch.pid,serial.text_quote(watch.log),allocator=allocator)
    return err
}

// An expired socket timeout is Timeout on Windows (WSAETIMEDOUT) and Would_Block
// on POSIX (EAGAIN). A closed connection is another error or a read of 0 bytes.
@(private)
timed_out :: proc(err:net.Network_Error) -> bool {
    #partial switch e in err {
    case net.TCP_Send_Error: return e==.Timeout || e==.Would_Block
    case net.TCP_Recv_Error: return e==.Timeout || e==.Would_Block
    }
    return false
}

@(private)
response_head :: proc(head:string) -> (status,length:int) {
    rest:=head
    line,_:=strings.split_lines_iterator(&rest)
    if len(line)<12 || !strings.has_prefix(line,"HTTP/1.") {return 0,-1}
    status,_=strconv.parse_int(line[9:12],10)
    length=-1
    for header in strings.split_lines_iterator(&rest) {
        name,value,ok:=header_value(header)
        if ok && strings.equal_fold(name,"content-length") {
            parsed,valid:=strconv.parse_int(value,10)
            if valid {length=parsed}
        }
    }
    return
}

// The fields of a JSON-RPC response: result and error are JSON text.
@(private)
Envelope :: struct {id,result,error:string}

@(private)
envelope_read :: proc(allocator:runtime.Allocator,text:string) -> (envelope:Envelope,ok:bool) {
    values:[4]string
    if !object_values(allocator,text,{"jsonrpc","id","result","error"},values[:]) {return {},false}
    if values[0]!=`"2.0"` {return {},false}
    return {values[1],values[2],values[3]},true
}

@(private)
error_read :: proc(allocator:runtime.Allocator,text:string) -> Error {
    values:[3]string
    if !object_values(allocator,text,{"code","message","data"},values[:]) {return {BAD_RESPONSE,"the error of the answer is malformed",""}}
    code,_:=strconv.parse_int(values[0],10)
    message,_:=string_value(allocator,values[1])
    return {code,message,values[2]}
}

// Calls a method of the server on port, in the turn of an AI task when task
// is not empty, or as the agent client names. params is a JSON object. The
// result is JSON text. watch tells an editor that ended or hung from one that works.
rpc_call :: proc(port:int,method,params:string,id:int,timeout_ms:int,allocator:runtime.Allocator,task:string="",client:string="",watch:=Client_Watch{}) -> (result:string,error:Error,ok:bool) {
    w:serial.Writer
    serial.writer_init(&w,len(params)+128,allocator)
    raw(&w,`{"jsonrpc":"2.0","id":`);serial.text_write_int(&w,i64(id))
    raw(&w,`,"method":`);serial.text_write_string(&w,method)
    raw(&w,`,"params":`);raw(&w,params==""?"{}":params);raw(&w,"}")
    status,body,post_error:=client_post(port,"/rpc",string(serial.writer_bytes(&w)),timeout_ms,allocator,task,"",client,watch)
    if post_error.code!=0 {return "",post_error,false}
    envelope,valid:=envelope_read(allocator,string(body))
    if !valid {
        return "",client_error(allocator,BAD_RESPONSE,"HTTP %d: the answer is not a JSON-RPC response",status),false
    }
    if envelope.error!="" {return "",error_read(allocator,envelope.error),false}
    expected:=fmt.aprintf("%d",id,allocator=allocator)
    if envelope.id!=expected || envelope.result=="" {
        return "",client_error(allocator,BAD_RESPONSE,"the answer does not match the request"),false
    }
    return envelope.result,{},true
}

// The JSON text indented two spaces per level, with its objects in the order it has them.
json_pretty :: proc(text:string,allocator:runtime.Allocator) -> string {
    w:serial.Writer
    serial.writer_init(&w,len(text)*2+64,allocator)
    depth,i:=0,0
    for i<len(text) {
        c:=text[i]
        switch c {
        case ' ','\t','\n','\r':
        case '"':
            end:=i+1
            for end<len(text) && text[end]!='"' {end+=text[end]=='\\'?2:1}
            end=min(end+1,len(text))
            serial.write_bytes(&w,transmute([]u8)text[i:end])
            i=end-1
        case '{','[':
            close:=u8(c=='{'?'}':']')
            next:=i+1
            for next<len(text) && (text[next]==' ' || text[next]=='\n' || text[next]=='\r' || text[next]=='\t') {next+=1}
            if next<len(text) && text[next]==close {
                serial.write_u8(&w,c);serial.write_u8(&w,close)
                i=next
            } else {
                serial.write_u8(&w,c)
                depth+=1
                serial.text_write_break(&w,depth)
            }
        case '}',']':
            depth=max(depth-1,0)
            serial.text_write_break(&w,depth)
            serial.write_u8(&w,c)
        case ',':
            serial.write_u8(&w,',')
            serial.text_write_break(&w,depth)
        case ':':
            serial.text_write_raw(&w,": ")
        case:
            serial.write_u8(&w,c)
        }
        i+=1
    }
    return string(serial.writer_bytes(&w))
}

// JSON text on one line: outside strings a line break is only formatting.
json_single_line :: proc(text:string,allocator:runtime.Allocator) -> string {
    if strings.index_byte(text,'\n')<0 && strings.index_byte(text,'\r')<0 {return text}
    out:=make([]u8,len(text),allocator)
    n:=0
    for c in transmute([]u8)text {
        if c=='\n' || c=='\r' {continue}
        out[n]=c
        n+=1
    }
    return string(out[:n])
}

// {"error":{code,message,data}}, the form `mirai rpc` prints on stderr.
error_text :: proc(err:Error,allocator:runtime.Allocator) -> string {
    w:serial.Writer
    serial.writer_init(&w,256,allocator)
    raw(&w,`{"error":`);write_error_object(allocator,&w,err);raw(&w,"}")
    return string(serial.writer_bytes(&w))
}
