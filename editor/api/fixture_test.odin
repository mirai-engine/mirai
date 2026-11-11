package api

import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

Add_Params :: struct {a,b:i32}
Add_Result :: struct {sum:i64}
Echo_Params :: struct {
    text:[32]u8 `mirai:"text"`,
    times:i32 `mirai:"optional,min=1,max=4"`,
}
Echo_Result :: struct {text:[160]u8 `mirai:"text"`}
Fail_Params :: struct {code:i32 `mirai:"optional"`}

// What the test methods that write their own answer take, and what they declare of it.
Raw_Params :: struct {ops,a,text:serial.Json `mirai:"optional"`}
Raw_Result :: struct {}

add_handler :: proc(call:^Call) {
    p,r:=call_params(call,Add_Params),call_result(call,Add_Result)
    r.sum=i64(p.a)+i64(p.b)
}
echo_handler :: proc(call:^Call) {
    p,r:=call_params(call,Echo_Params),call_result(call,Echo_Result)
    text:=base.text_get(p.text[:])
    for _ in 0..<p.times {base.text_append(r.text[:],text)}
}
fail_handler :: proc(call:^Call) {
    p:=call_params(call,Fail_Params)
    call_fail(call,p.code!=0?int(p.code):SERVER_ERROR,"test failure",`{"attempt":4}`)
}
shapes_handler :: proc(call:^Call) {
    call_result(call,Shapes)^=call_params(call,Shapes)^
}
raw_handler :: proc(call:^Call) {
    raw(call.out,`{"bytes":`)
    count:=len(call.raw)
    digits:[20]u8
    n:=len(digits)
    for ;n==len(digits) || count>0;count/=10 {n-=1;digits[n]=u8('0'+count%10)}
    raw(call.out,string(digits[n:]))
    raw(call.out,`,"echo":`);raw(call.out,call.raw);raw(call.out,"}")
}
big_handler :: proc(call:^Call) {
    raw(call.out,"[")
    for _ in 0..<2000 {raw(call.out,`"0123456789abcdef",`)}
    raw(call.out,"0]")
}
failing_raw_handler :: proc(call:^Call) {
    raw(call.out,`{"partial":`)
    call_failf(call,SERVER_ERROR,"broke after %d bytes",call.out.count)
}

Fixture :: struct {
    server:Server,
    thread:^thread.Thread,
    stop:bool,
    tracking:mem.Tracking_Allocator,
    stats:Server_Stats,
    finished:bool,
    wait:time.Duration, // between polls without requests, server_wait instead of a yield
}

fixture_run :: proc(t:^thread.Thread) {
    f:=(^Fixture)(t.data)
    context.allocator=mem.tracking_allocator(&f.tracking)
    for !intrinsics.atomic_load(&f.stop) {
        if server_poll(&f.server)>0 {continue}
        if f.wait>0 {server_wait(&f.server,f.wait)} else {thread.yield()}
    }
}

fixture_start :: proc(f:^Fixture,t:^testing.T,desc:Server_Desc={}) -> bool {
    desc:=desc
    desc.port=0
    if desc.timeout_ms==0 {desc.timeout_ms=3000}
    err:=server_init(&f.server,desc)
    testing.expect_value(t,err,Init_Error.None)
    if err!=.None {return false}
    defaults:=Echo_Params{times=1}
    shapes_defaults:=Shapes{mode=.Walk}
    ok:=true
    ok&&=method_register(&f.server,{name="batch",summary=BATCH_SUMMARY,params=type_info_of(Batch_Params),result=type_info_of(Batch_Result),handler=batch})==.None
    ok&&=method_register(&f.server,{name="test.add",summary="Adds two integers.",params=type_info_of(Add_Params),result=type_info_of(Add_Result),handler=add_handler,flags={.Read_Only,.Idempotent,.Core}})==.None
    ok&&=method_register(&f.server,{name="test.echo",summary="Repeats a text.",params=type_info_of(Echo_Params),result=type_info_of(Echo_Result),defaults=&defaults,handler=echo_handler,flags={.Core}})==.None
    ok&&=method_register(&f.server,{name="test.fail",summary="Always fails.",params=type_info_of(Fail_Params),handler=fail_handler,flags={.Destructive,.Core}})==.None
    ok&&=method_register(&f.server,{name="test.shapes",summary="Returns its params.",params=type_info_of(Shapes),result=type_info_of(Shapes),defaults=&shapes_defaults,handler=shapes_handler,flags={.Core}})==.None
    ok&&=method_register(&f.server,{name="test.raw",summary="Wraps its params.",params=type_info_of(Raw_Params),result=type_info_of(Raw_Result),writes_result=true,handler=raw_handler,flags={.Core}})==.None
    ok&&=method_register(&f.server,{name="test.big",summary="Writes a large array.",result=type_info_of(Raw_Result),writes_result=true,handler=big_handler,flags={.Core}})==.None
    if desc.max_response>=4<<20 {ok&&=method_register(&f.server,{name="test.huge",summary="Writes a very large array.",result=type_info_of(Raw_Result),writes_result=true,handler=huge_handler,flags={.Core}})==.None}
    ok&&=method_register(&f.server,{name="test.broken",summary="Fails after writing.",result=type_info_of(Raw_Result),writes_result=true,handler=failing_raw_handler,flags={.Core}})==.None
    testing.expect(t,ok,"the sample methods register")
    mem.tracking_allocator_init(&f.tracking,context.allocator)
    f.thread=thread.create(fixture_run)
    f.thread.data=f
    thread.start(f.thread)
    return ok
}

fixture_finish :: proc(f:^Fixture) {
    if f.finished || f.thread==nil {return}
    f.finished=true
    intrinsics.atomic_store(&f.stop,true)
    thread.join(f.thread)
    thread.destroy(f.thread)
    f.stats=f.server.stats
    mem.tracking_allocator_destroy(&f.tracking)
    server_destroy(&f.server)
}

post :: proc(f:^Fixture,path,body:string) -> (status:int,response:string) {
    code,bytes,err:=client_post(server_port(&f.server),path,body,3000,context.temp_allocator)
    if err.code!=0 {return 0,err.message}
    return code,string(bytes)
}

parse_json :: proc(t:^testing.T,text:string) -> json.Value {
    value,err:=json.parse(transmute([]u8)text,parse_integers=true,allocator=context.temp_allocator)
    testing.expectf(t,err==.None,"not JSON (%v): %s",err,text)
    return value
}

at :: proc(value:json.Value,keys:..any) -> json.Value {
    current:=value
    for key in keys {
        switch k in key {
        case string:
            object,ok:=current.(json.Object)
            if !ok {return nil}
            current=object[k]
        case int:
            array,ok:=current.(json.Array)
            if !ok || k>=len(array) {return nil}
            current=array[k]
        }
    }
    return current
}
integer :: proc(value:json.Value) -> i64 {
    if v,ok:=value.(json.Integer);ok {return i64(v)}
    return min(i64)
}
string_of :: proc(value:json.Value) -> string {
    if v,ok:=value.(json.String);ok {return string(v)}
    return ""
}

rpc :: proc(t:^testing.T,f:^Fixture,body:string) -> json.Value {
    status,response:=post(f,"/rpc",body)
    testing.expectf(t,status==200,"HTTP %d: %s",status,response)
    return parse_json(t,response)
}

// Sends bytes on a fresh connection and reads until the server closes it.
exchange :: proc(port:int,data:string,wait_ms:=3000) -> string {
    socket,err:=net.dial_tcp_from_address_and_port(net.IP4_Loopback,port)
    if err!=nil {return ""}
    defer net.close(socket)
    net.set_option(socket,.Receive_Timeout,time.Duration(wait_ms)*time.Millisecond)
    for sent:=0;sent<len(data); {
        n,send_error:=net.send_tcp(socket,transmute([]u8)data[sent:])
        if send_error!=nil || n==0 {break}
        sent+=n
    }
    return read_all(socket)
}

read_all :: proc(socket:net.TCP_Socket) -> string {
    out:[dynamic]u8
    out.allocator=context.temp_allocator
    chunk:[4096]u8
    for {
        n,err:=net.recv_tcp(socket,chunk[:])
        if err!=nil || n==0 {break}
        append(&out,..chunk[:n])
    }
    return string(out[:])
}
http_request :: proc(path,body:string,headers:="Content-Type: application/json\r\n",method:="POST") -> string {
    return fmt.tprintf("%s %s HTTP/1.1\r\nHost: 127.0.0.1\r\n%sContent-Length: %d\r\nConnection: close\r\n\r\n%s",method,path,headers,len(body),body)
}
U00E9 :: "\\" + "u00e9"
BS :: "\\"

huge_handler :: proc(call:^Call) {
    raw(call.out,"[")
    for _ in 0..<100000 {raw(call.out,`"0123456789abcdef",`)}
    raw(call.out,"0]")
}
