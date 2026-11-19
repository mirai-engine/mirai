package api

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
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

// A method takes the reserved params over both routes and in its schema.
@(test)
a_wait_that_runs_out_repeats_a_long_value_cut_and_a_short_one_whole :: proc(t:^testing.T) {
    short:=`{"a":1}`
    testing.expect_value(t,wait_value_brief(context.temp_allocator,short),short)
    long:=strings.concatenate({`"`,strings.repeat("x",4*WAIT_VALUE_BYTES,context.temp_allocator),`"`},context.temp_allocator)
    brief:=wait_value_brief(context.temp_allocator,long)
    testing.expect(t,len(brief)<2*WAIT_VALUE_BYTES && json_valid(context.temp_allocator,brief),brief)
    testing.expect(t,json_member(brief,"omitted_bytes")!="",brief)
}

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

    described:=rpc(t,&f,`{"jsonrpc":"2.0","id":3,"method":"engine.describe","params":{"methods":["test.add","test.shapes"]}}`)
    for read_only,i in ([]bool{true,false}) {
        properties:=at(described,"result","methods",i,"params","properties")
        testing.expect(t,at(properties,"_select")!=nil,"the schema of every method lists _select")
        for name in ([]string{PARAM_WAIT_UNTIL,PARAM_WAIT_SECONDS}) {
            testing.expectf(t,(at(properties,name)!=nil)==read_only,"the schema lists %s only for a method that changes nothing",name)
        }
    }
}

// A request that waits for its condition while another one arrives, and what it was answered.
@(private="file")
Waiter :: struct {
    port:int,
    body:string,
    status:int,
    response:[1024]u8,
    length:int,
}

@(private="file")
waiter_post :: proc(w:^Waiter) {
    status,bytes,_:=client_post(w.port,"/rpc",w.body,5000,context.allocator)
    w.status,w.length=status,copy(w.response[:],bytes)
    delete(bytes)
}

// _wait_until calls the method again until its result meets the condition or
// the wait runs out, waiting on its connection: the server answers the other
// requests meanwhile.
@(test)
a_wait_until_waits_on_its_connection_while_the_server_answers_the_others :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    if !fixture_start(f,t,{timeout_ms=5000}) {return}
    defer fixture_finish(f)
    count,changes:=0,0
    testing.expect_value(t,method_register(&f.server,{name="count",result=type_info_of(Count_Result),handler=count_handler,user=&count,flags={.Read_Only}}),Register_Error.None)
    testing.expect_value(t,method_register(&f.server,{name="change",result=type_info_of(Count_Result),handler=count_handler,user=&changes}),Register_Error.None)
    met:=rpc(t,f,`{"jsonrpc":"2.0","id":1,"method":"count","params":{"_wait_until":"value>=3","_select":"value"}}`)
    testing.expect_value(t,integer(at(met,"result","value")),3)
    testing.expect_value(t,count,3)
    waiter:=Waiter{port=server_port(&f.server),body=`{"jsonrpc":"2.0","id":2,"method":"count","params":{"_wait_until":"value<0","_wait_seconds":1}}`}
    th:=thread.create_and_start_with_poly_data(&waiter,waiter_post)
    time.sleep(200*time.Millisecond)
    began:=time.tick_now()
    other:=rpc(t,f,`{"jsonrpc":"2.0","id":3,"method":"test.add","params":{"a":2,"b":3}}`)
    testing.expect_value(t,integer(at(other,"result","sum")),5)
    testing.expect(t,time.duration_seconds(time.tick_since(began))<0.5,"another request is answered while one waits")
    thread.join(th);thread.destroy(th)
    ran_out:=parse_json(t,string(waiter.response[:waiter.length]))
    testing.expect_value(t,integer(at(ran_out,"error","code")),TIMEOUT)
    testing.expect(t,strings.contains(string_of(at(ran_out,"error","message")),"did not meet"),string(waiter.response[:waiter.length]))
    _,batched:=post(f,"/rpc",`[{"jsonrpc":"2.0","id":4,"method":"count","params":{"_wait_until":"value>=0"}},{"jsonrpc":"2.0","id":5,"method":"test.add","params":{"a":1,"b":1}}]`)
    in_batch:=parse_json(t,batched)
    testing.expect_value(t,integer(at(in_batch,0,"error","code")),INVALID_PARAMS)
    testing.expect(t,strings.contains(string_of(at(in_batch,0,"error","message")),"request of its own"),batched)
    testing.expect_value(t,integer(at(in_batch,1,"result","sum")),2)
    endless:=rpc(t,f,`{"jsonrpc":"2.0","id":6,"method":"count","params":{"_wait_until":"value<0","_wait_seconds":1e999}}`)
    testing.expect_value(t,integer(at(endless,"error","code")),INVALID_PARAMS)
    for params in ([]string{`{"_wait_until":"value>=3"}`,`{"_wait_seconds":1}`,`{"_wait_until":"value>=3","_wait_seconds":1,"_select":"value"}`}) {
        refused:=rpc(t,f,strings.concatenate({`{"jsonrpc":"2.0","id":7,"method":"change","params":`,params,`}`},context.temp_allocator))
        message:=string_of(at(refused,"error","message"))
        testing.expectf(t,integer(at(refused,"error","code"))==INVALID_PARAMS && strings.contains(message,"change changes things") && strings.contains(message,"read-only method"),"%s: %s",params,message)
    }
    testing.expect_value(t,changes,0)
    once:=rpc(t,f,`{"jsonrpc":"2.0","id":8,"method":"change","params":{"_select":"value"}}`)
    testing.expectf(t,changes==1 && integer(at(once,"result","value"))==1,"a method that changes things runs once and still takes _select: %v",once)
}
