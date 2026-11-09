package api

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Count_Result :: struct {value:int,name:[8]u8 `mirai:"text"`}

@(private="file")
count_handler :: proc(call:^Call) {
    count:=(^int)(call.user)
    count^+=1
    call_result(call,Count_Result).value=count^
}

// Every method takes the reserved params, over both routes and in its schema.
@(test)
select_keeps_the_fields_it_names_and_tools_keep_the_whole_structured_result :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    reply:=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"test.shapes","params":{"position":[1,2,3],"mode":"Run","_select":"mode,position[1]"}}`)
    testing.expect_value(t,string_of(at(reply,"result","mode")),"Run")
    testing.expect_value(t,integer(at(reply,"result","position[1]")),2)
    testing.expect(t,at(reply,"result","flags")==nil,"only what it names")
    missing:=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"test.shapes","params":{"position":[1,2,3],"mode":"Run","_select":"mode,total"}}`)
    testing.expect(t,at(missing,"error")==nil,"the call ran: a field it does not have is not an error")
    testing.expect_value(t,string_of(at(missing,"result","mode")),"Run")
    testing.expect(t,at(missing,"result","position")==nil,"only the fields it found, never the whole result")
    note:=string_of(at(missing,"note"))
    testing.expect(t,strings.contains(note,"has no 'total'; it has:") && strings.contains(note,"position"),note)
    many:=rpc(t,&f,strings.concatenate({`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":1,"_select":"`,strings.repeat("x,",1024,context.temp_allocator),`y"}}`},context.temp_allocator))
    testing.expect(t,len(string_of(at(many,"note")))<2*NOTE_BYTES,"what it says is bounded")
    malformed:=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":1,"_wait_until":"sum"}}`)
    testing.expect_value(t,integer(at(malformed,"error","code")),i64(INVALID_PARAMS))

    tool:=mcp(t,&f,`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"test_shapes","arguments":{"position":[1,2,3],"_select":"mode"}}}`)
    testing.expect_value(t,string_of(at(tool_text(t,tool),"mode")),"Walk")
    testing.expect(t,at(tool_text(t,tool),"position")==nil,"the text keeps what it names")
    testing.expect(t,at(tool,"result","structuredContent")==nil,"the selection is all a model gets")
    unknown:=mcp(t,&f,`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"test_add","arguments":{"a":1,"b":1,"_select":"total"}}}`)
    testing.expect(t,is_bool(at(unknown,"result","isError"),false),"a tool that ran is not a tool error")
    testing.expect(t,at(tool_text(t,unknown),"sum")==nil,"nothing was found")
    content:=at(unknown,"result","content").(json.Array)
    testing.expect(t,len(content)==2 && strings.contains(string_of(at(content[1],"text")),"has no 'total'"),"the note follows what it found")

    described:=rpc(t,&f,`{"jsonrpc":"2.0","id":3,"method":"engine.describe","params":{"methods":["test.add"]}}`)
    properties:=at(described,"result","methods",0,"params","properties")
    testing.expect(t,at(properties,"_select")!=nil && at(properties,"_wait_until")!=nil && at(properties,"a")!=nil,"the schema lists them")
}

@(test)
wait_until_calls_the_method_again_until_its_result_meets_the_condition :: proc(t:^testing.T) {
    server:Server
    if !testing.expect_value(t,server_init(&server,{port=0}),Init_Error.None) {return}
    defer server_destroy(&server)
    count:=0
    testing.expect_value(t,method_register(&server,{name="count",result=Count_Result,handler=count_handler,user=&count}),Register_Error.None)
    pause :: proc(s:^Server,seconds:f64) -> bool {return true}
    server.pause=pause
    out:serial.Writer
    serial.writer_init(&out,allocator=context.allocator)
    defer serial.writer_destroy(&out)
    method:=method_find(&server,"count")
    error,ok,selected,_:=method_call(&server,method,`{"_wait_until":"value>=3","_select":"value"}`,&out)
    testing.expectf(t,ok,"%v",error)
    testing.expect_value(t,count,3)
    testing.expect_value(t,selected,`{"value":3}`)
    base.arena_reset(&server.scratch)
    error,ok,_,_=method_call(&server,method,`{"_wait_until":"value<0","_wait_seconds":0.01}`,&out)
    testing.expect(t,!ok && error.code==TIMEOUT && strings.contains(error.message,"did not meet"),error.message)
    base.arena_reset(&server.scratch)
    error,ok,_,_=method_call(&server,method,`{"_wait_until":"value<0","_wait_seconds":1e999}`,&out)
    testing.expect(t,!ok && error.code==INVALID_PARAMS,error.message)
    base.arena_reset(&server.scratch)
    ending :: proc(s:^Server,seconds:f64) -> bool {return false}
    server.pause=ending
    error,ok,_,_=method_call(&server,method,`{"_wait_until":"value<0"}`,&out)
    testing.expect(t,!ok && error.code==CLOSED && strings.contains(error.message,"ending"),error.message)
}
