package api

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/serial"

@(test)
methods_reload_replaces_handlers_and_schemas_without_reopening_connections :: proc(t:^testing.T) {
    server:Server
    if error:=server_init(&server,{port=0});!testing.expect_value(t,error,Init_Error.None) {return}
    defer server_destroy(&server)
    port:=server_port(&server)
    testing.expect_value(t,method_register(&server,{name="reload.method",params=Add_Params,result=Add_Result,handler=add_handler}),Register_Error.None)
    testing.expect(t,server_methods_reset(&server))
    testing.expect_value(t,server_port(&server),port)
    testing.expect(t,method_find(&server,"reload.method")==nil)
    testing.expect(t,method_find(&server,"engine.describe")!=nil)
    defaults:=Echo_Params{times=3}
    testing.expect_value(t,method_register(&server,{name="reload.method",params=Echo_Params,result=Echo_Result,defaults=&defaults,handler=echo_handler}),Register_Error.None)
    out:serial.Writer
    serial.writer_init(&out,allocator=context.allocator)
    defer serial.writer_destroy(&out)
    method:=method_find(&server,"reload.method")
    error,ok:=method_execute(&server,method,`{"text":"new"}`,&out)
    testing.expectf(t,ok,"%v",error)
    result:=parse_json(t,string(serial.writer_bytes(&out)))
    testing.expect_value(t,string_of(at(result,"text")),"newnewnew")
    testing.expect_value(t,server.method_count,2)
}

@(test)
a_call_runs_the_handler_with_typed_params_and_result :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    reply:=rpc(t,&f,`{"jsonrpc":"2.0","id":7,"method":"test.add","params":{"a":2,"b":-5}}`)
    testing.expect_value(t,string_of(at(reply,"jsonrpc")),"2.0")
    testing.expect_value(t,integer(at(reply,"id")),7)
    testing.expect_value(t,integer(at(reply,"result","sum")),-3)
    reply=rpc(t,&f,strings.concatenate({`{"jsonrpc":"2.0","id":"abc`,U00E9,`","method":"test.add","params":{"a":2147483647,"b":2147483647}}`},context.temp_allocator))
    testing.expect_value(t,string_of(at(reply,"id")),"abcé")
    testing.expect_value(t,integer(at(reply,"result","sum")),4294967294)
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":null,"method":"test.add","params":{"a":1,"b":1}}`)
    testing.expect_value(t,integer(at(reply,"result","sum")),2)
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"b":1,"a":1}, "extra": [1,{"x":"y"}]}`)
    testing.expect_value(t,integer(at(reply,"result","sum")),2)
}

@(test)
absent_optional_fields_take_the_defaults :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    reply:=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"test.echo","params":{"text":"ab"}}`)
    testing.expect_value(t,string_of(at(reply,"result","text")),"ab")
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"test.echo","params":{"text":"ab","times":3}}`)
    testing.expect_value(t,string_of(at(reply,"result","text")),"ababab")
    reply=rpc(t,&f,strings.concatenate({`{"jsonrpc":"2.0","id":1,"method":"test.echo","params":{"text":"`,U00E9,BS,`n`,BS,`"q`,BS,`""}}`},context.temp_allocator))
    testing.expect_value(t,string_of(at(reply,"result","text")),"é\n\"q\"")
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"test.shapes","params":{"position":[1,2,3]}}`)
    testing.expect_value(t,string_of(at(reply,"result","mode")),"Walk")
    testing.expect_value(t,integer(at(reply,"result","position",1)),2)
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"test.shapes","params":{"position":[1,2,3],"mode":"Run","flags":["Ice","Wind"],"inner":{"x":9},"name":"ok","entity":"0x2a","asset":"000000000000000a000000000000000b","signed":-5,"wide":18446744073709551615}}`)
    testing.expect_value(t,string_of(at(reply,"result","mode")),"Run")
    testing.expect_value(t,len(at(reply,"result","flags").(json.Array)),2)
    testing.expect_value(t,integer(at(reply,"result","inner","x")),9)
    testing.expect_value(t,string_of(at(reply,"result","name")),"ok")
    testing.expect_value(t,string_of(at(reply,"result","entity")),"0x000000000000002a")
    testing.expect_value(t,string_of(at(reply,"result","asset")),"000000000000000a000000000000000b")
}

@(test)
unknown_methods_and_malformed_envelopes_are_rejected :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    Case :: struct {body:string,code:int,id:string}
    cases:=[]Case{
        {`{"jsonrpc":"2.0","id":5,"method":"nope"}`,METHOD_NOT_FOUND,"5"},
        {`{"jsonrpc":"2.0","id":"x","method":"test.add."}`,METHOD_NOT_FOUND,"x"},
        {`{"jsonrpc":"2.0","id":1,`,PARSE_ERROR,""},
        {`not json`,PARSE_ERROR,""},
        {`{"jsonrpc":"2.0","id":1,"method":"test.add"} trailing`,PARSE_ERROR,""},
        {`{"jsonrpc":"2.0","id":"unterminated}`,PARSE_ERROR,""},
        {``,PARSE_ERROR,""},
        {`{"id":1,"method":"test.add","params":{}}`,INVALID_REQUEST,"1"},
        {`{"jsonrpc":"1.0","id":2,"method":"test.add"}`,INVALID_REQUEST,"2"},
        {`{"jsonrpc":"2.0","id":3,"method":7}`,INVALID_REQUEST,"3"},
        {`{"jsonrpc":"2.0","id":4}`,INVALID_REQUEST,"4"},
        {`{"jsonrpc":"2.0","id":{"a":1},"method":"test.add"}`,INVALID_REQUEST,""},
        {`{"jsonrpc":"2.0","id":true,"method":"test.add"}`,INVALID_REQUEST,""},
        {`5`,INVALID_REQUEST,""},
        {`"text"`,INVALID_REQUEST,""},
        {`[]`,INVALID_REQUEST,""},
        {`{"jsonrpc":"2.0","id":6,"method":"test.add","params":[1,2]}`,INVALID_PARAMS,"6"},
        {`{"jsonrpc":"2.0","id":6,"method":"test.add","params":null}`,INVALID_PARAMS,"6"},
        {`{"jsonrpc":"2.0","id":6,"method":"test.add","params":"x"}`,INVALID_PARAMS,"6"},
    }
    for c in cases {
        reply:=rpc(t,&f,c.body)
        testing.expectf(t,integer(at(reply,"error","code"))==i64(c.code),"%s: %v",c.body,reply)
        if c.id!="" {
            testing.expectf(t,at(reply,"id")!=nil,"%s keeps its id",c.body)
        } else {
            _,is_null:=at(reply,"id").(json.Null)
            testing.expectf(t,is_null,"%s answers with a null id",c.body)
        }
        testing.expect(t,string_of(at(reply,"error","message"))!="","the error has a message")
    }
}

@(test)
invalid_params_are_reported_with_the_field_that_caused_them :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    Case :: struct {method,params,message:string}
    cases:=[]Case{
        {"test.add",`{"a":"x","b":1}`,"a: expected a number"},
        {"test.add",`{"a":1.5,"b":1}`,"expected an integer"},
        {"test.add",`{"a":3000000000,"b":1}`,"number out of range"},
        {"test.add",`{"a":1,"b":2,"c":3}`,`"c" is not a field: the fields are a, b`},
        {"test.add",`{"a":1}`,"b is required"},
        {"test.add",`{}`,"is required"},
        {"test.add",`{"a":null,"b":1}`,"expected a number"},
        {"test.echo",`{"text":"x","times":9}`,"times must be at most 4"},
        {"test.echo",`{"text":"x","times":0}`,"times must be at least 1"},
        {"test.echo",`{"text":"this text is longer than thirty-two bytes"}`,"text too long"},
        {"test.echo",`{"times":2}`,"text is required"},
        {"test.shapes",`{"position":[1,2]}`,"position must have 3 elements, not 2"},
        {"test.shapes",`{"position":[1,2,3,4]}`,"too many elements"},
        {"test.shapes",`{"position":[1,11,3]}`,"position[1] must be at most 10"},
        {"test.shapes",`{"position":["nan",0,0]}`,"position[0] must be finite"},
        {"test.shapes",`{"position":["inf",0,0]}`,"must be finite"},
        {"test.shapes",`{"position":[0,0,0],"mode":"Fly"}`,`mode: "Fly" is not one of its names`},
        {"test.shapes",`{"position":[0,0,0],"mode":7}`,"mode is not a member of its enum"},
        {"test.shapes",`{"position":[0,0,0],"flags":["Rain"]}`,`flags: "Rain" is not one of its names`},
        {"test.shapes",`{"position":[0,0,0],"flags":[5]}`,"flags has bits that are not members"},
        {"test.shapes",`{"position":[0,0,0],"inner":{}}`,"inner.x is required"},
        {"test.shapes",`{"position":[0,0,0],"inner":{"x":300}}`,"inner.x: number out of range"},
        {"test.shapes",`{"position":[0,0,0],"signed":6}`,"signed must be at most 5"},
        {"test.shapes",`{"position":[0,0,0],"entity":"zz"}`,"invalid id"},
        {"test.shapes",`{"position":[0,0,0],"asset":"1234"}`,"invalid id"},
        {"test.shapes",`{"position":[0,0,0],"name":"a name that is much too long"}`,"text too long"},
        {"test.shapes",`{"position":"here"}`,"expected an array"},
        {"test.shapes",`{"position":[0,0,0],"inner":[]}`,"expected an object"},
    }
    for c in cases {
        body:=strings.concatenate({`{"jsonrpc":"2.0","id":1,"method":"`,c.method,`","params":`,c.params,"}"},context.temp_allocator)
        reply:=rpc(t,&f,body)
        testing.expectf(t,integer(at(reply,"error","code"))==INVALID_PARAMS,"%s: %v",c.params,reply)
        message:=string_of(at(reply,"error","message"))
        testing.expectf(t,strings.contains(message,c.message),"%s: expected %q in %q",c.params,c.message,message)
    }
}

@(test)
handler_errors_carry_code_message_and_data :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    reply:=rpc(t,&f,`{"jsonrpc":"2.0","id":3,"method":"test.fail","params":{}}`)
    testing.expect_value(t,integer(at(reply,"error","code")),SERVER_ERROR)
    testing.expect_value(t,string_of(at(reply,"error","message")),"test failure")
    testing.expect_value(t,integer(at(reply,"error","data","attempt")),4)
    testing.expect_value(t,integer(at(reply,"id")),3)
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":3,"method":"test.fail","params":{"code":-32001}}`)
    testing.expect_value(t,integer(at(reply,"error","code")),-32001)
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":4,"method":"test.broken"}`)
    testing.expect_value(t,integer(at(reply,"error","code")),SERVER_ERROR)
    testing.expect(t,strings.has_prefix(string_of(at(reply,"error","message")),"broke after"),"the partial output is dropped")
    testing.expect(t,at(reply,"result")==nil,"an error has no result")
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":5,"method":"test.add","params":{"a":1,"b":1}}`)
    testing.expect_value(t,integer(at(reply,"result","sum")),2)
}

@(test)
free_form_methods_receive_the_params_and_write_json :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    reply:=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"test.raw","params":{"ops":[{"k":1},{"k":2}]}}`)
    testing.expect_value(t,integer(at(reply,"result","bytes")),len(`{"ops":[{"k":1},{"k":2}]}`))
    testing.expect_value(t,integer(at(reply,"result","echo","ops",1,"k")),2)
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"test.raw"}`)
    testing.expect_value(t,integer(at(reply,"result","bytes")),2)
}

@(test)
batches_answer_in_order_and_skip_notifications :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    reply:=rpc(t,&f,`[{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":2}},{"jsonrpc":"2.0","method":"test.add","params":{"a":1,"b":2}},{"jsonrpc":"2.0","id":3,"method":"nope"},5,{"jsonrpc":"2.0","id":"last","method":"test.add","params":{"a":10,"b":20}}]`)
    array,ok:=reply.(json.Array)
    testing.expect(t,ok && len(array)==4,"the notification has no answer")
    testing.expect_value(t,integer(at(reply,0,"result","sum")),3)
    testing.expect_value(t,integer(at(reply,1,"error","code")),METHOD_NOT_FOUND)
    testing.expect_value(t,integer(at(reply,2,"error","code")),INVALID_REQUEST)
    testing.expect_value(t,integer(at(reply,3,"result","sum")),30)
    status,body:=post(&f,"/rpc",`[{"jsonrpc":"2.0","method":"test.add","params":{"a":1,"b":2}},{"jsonrpc":"2.0","method":"nope"}]`)
    testing.expect_value(t,status,202)
    testing.expect_value(t,body,"")
    status,body=post(&f,"/rpc",`{"jsonrpc":"2.0","method":"test.add","params":{"a":1,"b":2}}`)
    testing.expect_value(t,status,202)
    reply=rpc(t,&f,`[{"jsonrpc":"2.0","id":1,"method":"test.fail"},{"jsonrpc":"2.0","id":2,"method":"test.add","params":{"a":1,"b":1}}]`)
    testing.expect_value(t,integer(at(reply,0,"error","code")),SERVER_ERROR)
    testing.expect_value(t,integer(at(reply,1,"result","sum")),2)
}

@(test)
a_response_larger_than_the_buffer_becomes_an_error :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t,{max_response=4096}) {return}
    defer fixture_finish(&f)
    reply:=rpc(t,&f,`{"jsonrpc":"2.0","id":9,"method":"test.big"}`)
    testing.expect_value(t,integer(at(reply,"error","code")),SERVER_ERROR)
    testing.expect_value(t,integer(at(reply,"id")),9)
    reply=rpc(t,&f,`[{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":1}},{"jsonrpc":"2.0","id":2,"method":"test.big"},{"jsonrpc":"2.0","id":3,"method":"test.add","params":{"a":2,"b":2}}]`)
    testing.expect_value(t,integer(at(reply,0,"result","sum")),2)
    testing.expect_value(t,integer(at(reply,1,"error","code")),SERVER_ERROR)
    testing.expect_value(t,integer(at(reply,2,"result","sum")),4)
    fixture_finish(&f)
    testing.expect_value(t,f.stats.oversized,2)
}

@(test)
oversized_requests_are_refused_before_their_body_is_read :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t,{max_request=1024}) {return}
    defer fixture_finish(&f)
    body,_:=strings.repeat("x",12*1024,context.temp_allocator)
    answer:=exchange(server_port(&f.server),http_request("/rpc",body))
    testing.expect(t,strings.has_prefix(answer,"HTTP/1.1 413 "),answer)
    testing.expect(t,strings.contains(answer,"request body too large"),"the answer says why")
    answer=exchange(server_port(&f.server),http_request("/rpc",strings.repeat(" ",1025,context.temp_allocator)))
    testing.expect(t,strings.has_prefix(answer,"HTTP/1.1 413 "),answer)
    status,response:=post(&f,"/rpc",`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":1}}`)
    testing.expect_value(t,status,200)
    testing.expect(t,strings.contains(response,`"sum": 2`),response)
}

@(test)
malformed_http_is_answered_with_a_status_and_never_crashes :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    port:=server_port(&f.server)
    Case :: struct {request:string,status:int}
    huge_header,_:=strings.repeat("X-Padding: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n",120,context.temp_allocator)
    cases:=[]Case{
        {"\x00\x01\x02garbage\r\n\r\n",400},
        {"POST\r\n\r\n",400},
        {"POST /rpc\r\n\r\n",400},
        {"POST /rpc HTTP/9.9\r\nContent-Length: 0\r\n\r\n",400},
        {"POST /rpc HTTP/1.1\r\nbroken header\r\n\r\n",400},
        {"POST /rpc HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: abc\r\n\r\n",400},
        {"POST /rpc HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: -1\r\n\r\n",400},
        {"POST /rpc HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}",400},
        {"GET /rpc HTTP/1.1\r\n\r\n",405},
        {"DELETE /mcp HTTP/1.1\r\n\r\n",405},
        {"POST /other HTTP/1.1\r\nContent-Length: 0\r\n\r\n",404},
        {"POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n",404},
        {"POST /rpc HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{}",411},
        {"POST /rpc HTTP/1.1\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n",411},
        {"POST /rpc HTTP/1.1\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}",415},
        {"POST /rpc HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}",415},
        {"POST /rpc HTTP/1.1\r\nContent-Type: application/json\r\nOrigin: http://evil.example\r\nContent-Length: 2\r\n\r\n{}",403},
        {"POST /rpc HTTP/1.1\r\nHost: evil.example\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}",403},
        {strings.concatenate({"POST /rpc HTTP/1.1\r\n",huge_header,"Content-Length: 0\r\n\r\n"},context.temp_allocator),431},
    }
    for c in cases {
        answer:=exchange(port,c.request)
        prefix:=strings.concatenate({"HTTP/1.1 ",tprint_int(c.status)," "},context.temp_allocator)
        testing.expectf(t,strings.has_prefix(answer,prefix),"%q gave %q",c.request[:min(len(c.request),60)],answer[:min(len(answer),60)])
        if c.status==405 {testing.expect(t,strings.contains(answer,"Allow: POST"),"405 names the method that works")}
    }
    ok_body:=`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":4,"b":5}}`
    answer:=exchange(port,fmt.tprintf("POST /rpc?x=1 HTTP/1.0\r\ncontent-TYPE: Application/JSON; charset=utf-8\r\nContent-Length: %d\r\nHost: localhost:1234\r\n\r\n%s ",len(ok_body),ok_body))
    testing.expect(t,strings.has_prefix(answer,"HTTP/1.1 200 ") && strings.contains(answer,`"sum": 9`),answer)
    status,_:=post(&f,"/rpc",`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":1}}`)
    testing.expect_value(t,status,200)
    fixture_finish(&f)
    testing.expect(t,f.stats.rejected>=u64(len(cases)),"every refusal is counted")
}

tprint_int :: proc(value:int) -> string {
    digits:[20]u8
    n:=len(digits)
    for v:=value;n==len(digits) || v>0;v/=10 {n-=1;digits[n]=u8('0'+v%10)}
    return strings.clone(string(digits[n:]),context.temp_allocator)
}

@(test)
hostile_bodies_are_bounded :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    deep,_:=strings.repeat("[",100000,context.temp_allocator)
    reply:=rpc(t,&f,deep)
    testing.expect_value(t,integer(at(reply,"error","code")),PARSE_ERROR)
    nested:=strings.concatenate({`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":`,deep,`}}`},context.temp_allocator)
    reply=rpc(t,&f,nested)
    testing.expect_value(t,integer(at(reply,"error","code")),PARSE_ERROR)
    long_id,_:=strings.repeat("i",MAX_ID+8,context.temp_allocator)
    reply=rpc(t,&f,strings.concatenate({`{"jsonrpc":"2.0","id":"`,long_id,`","method":"test.add"}`},context.temp_allocator))
    testing.expect_value(t,integer(at(reply,"error","code")),INVALID_REQUEST)
    long_name,_:=strings.repeat("n",100000,context.temp_allocator)
    reply=rpc(t,&f,strings.concatenate({`{"jsonrpc":"2.0","id":1,"method":"`,long_name,`"}`},context.temp_allocator))
    testing.expect_value(t,integer(at(reply,"error","code")),METHOD_NOT_FOUND)
    testing.expect(t,len(string_of(at(reply,"error","message")))<200,"names echoed in errors are cut")
    reply=rpc(t,&f,strings.concatenate({`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"`,long_name,`":1}}`},context.temp_allocator))
    testing.expect_value(t,integer(at(reply,"error","code")),INVALID_PARAMS)
    testing.expect(t,len(string_of(at(reply,"error","message")))<200,"field names echoed in errors are cut")
    escapes,_:=strings.repeat(strings.concatenate({U00E9,BS,`n`},context.temp_allocator),30000,context.temp_allocator)
    reply=rpc(t,&f,strings.concatenate({`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":1},"`,escapes,`":1}`},context.temp_allocator))
    testing.expect_value(t,integer(at(reply,"result","sum")),2)
    reply=rpc(t,&f,strings.concatenate({`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":1},"method":"`,escapes,`"}`},context.temp_allocator))
    testing.expect(t,at(reply,"error")!=nil,"a method name of 180 KB is an error, not a crash")
    status,_:=post(&f,"/rpc",`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":1}}`)
    testing.expect_value(t,status,200)
}

@(test)
silent_and_cut_short_clients_are_dropped :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t,{timeout_ms=150,max_connections=2}) {return}
    defer fixture_finish(&f)
    port:=server_port(&f.server)
    silent,_:=net.dial_tcp_from_address_and_port(net.IP4_Loopback,port)
    defer net.close(silent)
    partial,_:=net.dial_tcp_from_address_and_port(net.IP4_Loopback,port)
    defer net.close(partial)
    net.send_tcp(partial,transmute([]u8)string("POST /rpc HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 50\r\n\r\n{\"jsonrpc"))
    net.set_option(silent,.Receive_Timeout,2*time.Second)
    buffer:[64]u8
    n,_:=net.recv_tcp(silent,buffer[:])
    testing.expect_value(t,n,0)
    status,response:=post(&f,"/rpc",`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":1}}`)
    testing.expectf(t,status==200,"the slots of the dropped clients are free again: %d %s",status,response)
    fixture_finish(&f)
    testing.expect(t,f.stats.timeouts>=2,"timeouts are counted")
}

@(test)
several_clients_are_served_in_the_same_poll :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    port:=server_port(&f.server)
    CLIENTS :: 6
    sockets:[CLIENTS]net.TCP_Socket
    for &socket in sockets {
        socket,_=net.dial_tcp_from_address_and_port(net.IP4_Loopback,port)
        net.set_option(socket,.Receive_Timeout,3*time.Second)
    }
    for socket,i in sockets {
        body:=strings.concatenate({`{"jsonrpc":"2.0","id":`,tprint_int(i),`,"method":"test.add","params":{"a":`,tprint_int(i),`,"b":100}}`},context.temp_allocator)
        request:=http_request("/rpc",body)
        half:=len(request)/2
        net.send_tcp(socket,transmute([]u8)request[:half])
    }
    for socket,i in sockets {
        body:=strings.concatenate({`{"jsonrpc":"2.0","id":`,tprint_int(i),`,"method":"test.add","params":{"a":`,tprint_int(i),`,"b":100}}`},context.temp_allocator)
        request:=http_request("/rpc",body)
        net.send_tcp(socket,transmute([]u8)request[len(request)/2:])
    }
    for socket,i in sockets {
        answer:=read_all(socket)
        net.close(socket)
        expected:=strings.concatenate({`"id":`,tprint_int(i),`,"result":{"sum": `,tprint_int(100+i),`}`},context.temp_allocator)
        testing.expectf(t,strings.contains(answer,expected),"client %d got %s",i,answer)
    }
}

@(test)
connections_beyond_the_limit_wait_their_turn :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t,{max_connections=2}) {return}
    defer fixture_finish(&f)
    port:=server_port(&f.server)
    CLIENTS :: 7
    sockets:[CLIENTS]net.TCP_Socket
    for &socket in sockets {
        socket,_=net.dial_tcp_from_address_and_port(net.IP4_Loopback,port)
        net.set_option(socket,.Receive_Timeout,5*time.Second)
        net.send_tcp(socket,transmute([]u8)http_request("/rpc",`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":1}}`))
    }
    for socket in sockets {
        answer:=read_all(socket)
        net.close(socket)
        testing.expect(t,strings.contains(answer,`"sum": 2`),answer)
    }
}

@(test)
a_stable_poll_loop_allocates_nothing :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t,{timeout_ms=200}) {return}
    defer fixture_finish(&f)
    port:=server_port(&f.server)
    requests:=[]string{
        `{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":2}}`,
        `{"jsonrpc":"2.0","id":"s","method":"test.echo","params":{"text":"cafe \"quoted\"","times":2}}`,
        `{"jsonrpc":"2.0","id":2,"method":"test.shapes","params":{"position":[1,2,3],"flags":["Fire"],"name":"x"}}`,
        `{"jsonrpc":"2.0","id":3,"method":"test.fail"}`,
        `{"jsonrpc":"2.0","id":4,"method":"test.raw","params":{"a":[1,2,3]}}`,
        `{"jsonrpc":"2.0","id":5,"method":"engine.describe","params":{}}`,
        `{"jsonrpc":"2.0","id":6,"method":"engine.describe","params":{"methods":["test.shapes"]}}`,
        `[{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":2}},{"jsonrpc":"2.0","method":"nope"}]`,
        `{"jsonrpc":"2.0","id":7,"method":"test.add","params":{"a":"bad"}}`,
        `{"jsonrpc":"2.0","id":8,"method":"nope"}`,
        `not json`,
    }
    for body in requests {post(&f,"/rpc",body)}
    mcp:=[]string{
        `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`,
        `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`,
        `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"test_add","arguments":{"a":1,"b":2}}}`,
        `{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"test_fail","arguments":{}}}`,
    }
    for body in mcp {post(&f,"/mcp",body)}
    exchange(port,"GET /rpc HTTP/1.1\r\n\r\n")
    before:=f.tracking.total_allocation_count
    for _ in 0..<10 {
        for body in requests {post(&f,"/rpc",body)}
        for body in mcp {post(&f,"/mcp",body)}
        exchange(port,"GET /rpc HTTP/1.1\r\n\r\n")
    }
    exchange(port,"POST /rpc HTTP/1.1\r\nContent-Length: 4\r\nContent-Type: application/json\r\n\r\n{")
    testing.expect_value(t,f.tracking.total_allocation_count,before)
    testing.expect_value(t,f.tracking.current_memory_allocated,0)
}

@(test)
a_busy_server_keeps_polling_between_requests :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    start:=time.tick_now()
    for _ in 0..<50 {
        status,_:=post(&f,"/rpc",`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":1}}`)
        testing.expect_value(t,status,200)
    }
    elapsed:=time.tick_diff(start,time.tick_now())
    testing.expectf(t,elapsed<3*time.Second,"50 calls took %v",elapsed)
}

@(test)
a_waiting_server_wakes_as_a_request_arrives :: proc(t:^testing.T) {
    f:Fixture
    f.wait=500*time.Millisecond
    if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    for _ in 0..<10 {
        start:=time.tick_now()
        status,_:=post(&f,"/rpc",`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":1}}`)
        testing.expect_value(t,status,200)
        elapsed:=time.tick_diff(start,time.tick_now())
        testing.expectf(t,elapsed<100*time.Millisecond,"a call to a server waiting %v took %v",f.wait,elapsed)
    }
}

@(test)
a_large_response_is_sent_across_polls_while_other_clients_wait :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t,{max_response=4<<20}) {return}
    defer fixture_finish(&f)
    port:=server_port(&f.server)
    slow,_:=net.dial_tcp_from_address_and_port(net.IP4_Loopback,port)
    net.set_option(slow,.Receive_Timeout,5*time.Second)
    net.send_tcp(slow,transmute([]u8)http_request("/rpc",`{"jsonrpc":"2.0","id":1,"method":"test.huge"}`))
    time.sleep(100*time.Millisecond)
    other,_:=net.dial_tcp_from_address_and_port(net.IP4_Loopback,port)
    net.set_option(other,.Receive_Timeout,5*time.Second)
    net.send_tcp(other,transmute([]u8)http_request("/rpc",`{"jsonrpc":"2.0","id":2,"method":"test.add","params":{"a":1,"b":2}}`))
    time.sleep(100*time.Millisecond)
    answer:=read_all(slow)
    net.close(slow)
    testing.expect(t,strings.has_prefix(answer,"HTTP/1.1 200 "),"the whole response arrives")
    testing.expect(t,len(answer)>1_900_000 && strings.has_suffix(answer,`,0]}`),"nothing is cut or reordered")
    testing.expectf(t,strings.contains(answer,"Content-Length: 1900037\r\n"),"%s",answer[:min(len(answer),160)])
    answer=read_all(other)
    net.close(other)
    testing.expect(t,strings.contains(answer,`"sum": 3`),answer)
}
