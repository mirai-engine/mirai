package api

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

mcp :: proc(t:^testing.T,f:^Fixture,body:string) -> json.Value {
    status,response:=post(f,"/mcp",body)
    testing.expectf(t,status==200,"HTTP %d: %s",status,response)
    return parse_json(t,response)
}

tool_text :: proc(t:^testing.T,reply:json.Value) -> json.Value {
    return parse_json(t,string_of(at(reply,"result","content",0,"text")))
}

@(private)
mcp_image_handler :: proc(call:^Call) {
    raw(call.out,`{"shown":true}`)
    call_image(call,(^string)(call.user)^)
}

@(test)
large_mcp_images_keep_the_complete_content_with_small_socket_buffers :: proc(t:^testing.T) {
    server:Server
    if !testing.expect_value(t,server_init(&server,{port=0,max_connections=1,timeout_ms=5000}),Init_Error.None) {return}
    defer server_destroy(&server)
    payload:=strings.repeat("AQID",230*1024,context.allocator)
    defer delete(payload)
    folder:=base.test_folder(t,"image")
    if folder=="" {return}
    file:=fmt.tprintf("%s/large.png",folder)
    bytes:=make([]u8,230*1024*3,context.temp_allocator)
    for i in 0..<len(bytes) {bytes[i]=u8(i%3+1)}
    testing.expect(t,os.write_entire_file(file,bytes)==nil)
    testing.expect_value(t,method_register(&server,{name="view.viewport",handler=mcp_image_handler,user=&file}),Register_Error.None)
    // The receiver window must be negotiated before the TCP handshake.
    receiver,listen_error:=net.listen_tcp({address=net.IP4_Loopback,port=0},1)
    if !testing.expect(t,listen_error==nil) {return}
    defer net.close(receiver)
    testing.expect(t,net.set_option(receiver,.Receive_Buffer_Size,8192)==nil)
    endpoint,endpoint_error:=net.bound_endpoint(receiver)
    if !testing.expect(t,endpoint_error==nil) {return}
    for _ in 0..<2 {
        writer,dial_error:=net.dial_tcp_from_address_and_port(net.IP4_Loopback,endpoint.port)
        if !testing.expect(t,dial_error==nil) {return}
        socket,_,accept_error:=net.accept_tcp(receiver)
        if !testing.expect(t,accept_error==nil) {net.close(writer);return}
        defer net.close(socket)
        testing.expect(t,net.set_option(writer,.Send_Buffer_Size,8192)==nil)
        testing.expect(t,net.set_blocking(writer,false)==nil)
        conn:=&server.conns[0]
        conn^={socket=writer,state=.Reading,buffer=conn.buffer,started=time.tick_now()}
        request:=http_request("/mcp",`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"view_viewport","arguments":{}}}`)
        _,send_error:=net.send_tcp(socket,transmute([]u8)request)
        testing.expect(t,send_error==nil)
        testing.expect(t,net.set_blocking(socket,false)==nil)
        responding:=time.tick_now()
        for server.sending<0 && server.conns[0].state!=.Free && time.tick_diff(responding,time.tick_now())<time.Second {
            server_poll(&server)
            if server.sending<0 {time.sleep(time.Millisecond)}
        }
        progressed:=server.sending==0?server.send_at>HEAD_ROOM && server.send_at<server.send_end:
            server.conns[0].state==.Free && server.send_at==server.send_end
        if !testing.expectf(t,progressed,"sending advances or finishes: state=%v sending=%d at=%d end=%d",
            server.conns[0].state,server.sending,server.send_at,server.send_end) {return}
        answer:[dynamic]u8
        answer.allocator=context.allocator
        defer delete(answer)
        chunk:[16384]u8
        deadline:=time.tick_now()
        closed:=false
        for time.tick_diff(deadline,time.tick_now())<5*time.Second {
            n,receive_error:=net.recv_tcp(socket,chunk[:])
            if n>0 {append(&answer,..chunk[:n])}
            if receive_error!=.Would_Block && (receive_error!=nil || n==0) {closed=true;break}
            server_poll(&server)
        }
        testing.expect(t,closed,"the complete response drains before the deadline")
        text:=string(answer[:])
        if !testing.expect(t,strings.has_prefix(text,"HTTP/1.1 200 ")) {return}
        head:=strings.index(text,"\r\n\r\n")
        if !testing.expect(t,head>=0) {return}
        body:=text[head+4:]
        _,declared_length,_:=response_head(text[:head])
        testing.expect_value(t,len(body),declared_length)
        if !testing.expect(t,!strings.contains(body,"HTTP/1.1"),"a partial send never repeats the HTTP header") {return}
        reply,parse_error:=json.parse(transmute([]u8)body,parse_integers=true,allocator=context.temp_allocator)
        if !testing.expect_value(t,parse_error,json.Error.None) {return}
        testing.expect_value(t,string_of(at(reply,"result","content",1,"type")),"image")
        received:=string_of(at(reply,"result","content",1,"data"))
        testing.expect_value(t,len(received),len(payload))
        testing.expect(t,received==payload,"the complete image data matches")
        testing.expect_value(t,string_of(at(reply,"result","content",1,"mimeType")),"image/png")
        testing.expect(t,is_bool(at(reply,"result","isError"),false))
    }
}

Image_Params :: struct {path:[256]u8 `mirai:"text"`}

@(private)
image_handler :: proc(call:^Call) {
    p,r:=call_params(call,Image_Params),call_result(call,Add_Result)
    r.sum=7
    call_image(call,string(cstring(raw_data(p.path[:]))))
}

@(test)
a_typed_result_carries_its_image_over_mcp_and_only_the_result_over_json_rpc :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t,{max_response=MIN_RESPONSE}) {return}
    defer fixture_finish(&f)
    testing.expect_value(t,method_register(&f.server,{name="shot.take",params=Image_Params,result=Add_Result,handler=image_handler}),Register_Error.None)
    folder:=base.test_folder(t,"image")
    if folder=="" {return}
    small:=fmt.tprintf("%s/small.png",folder)
    large:=fmt.tprintf("%s/large.png",folder)
    testing.expect(t,os.write_entire_file(small,[]u8{1,2,3,4})==nil)
    testing.expect(t,os.write_entire_file(large,make([]u8,MIN_RESPONSE,context.temp_allocator))==nil)
    call :: proc(path:string) -> string {return fmt.tprintf(`{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"shot_take","arguments":{{"path":%q}}}}}}`,path)}
    reply:=mcp(t,&f,call(small))
    testing.expect_value(t,integer(at(tool_text(t,reply),"sum")),7)
    testing.expect_value(t,string_of(at(reply,"result","content",1,"type")),"image")
    testing.expect_value(t,string_of(at(reply,"result","content",1,"data")),"AQIDBA==")
    testing.expect_value(t,string_of(at(reply,"result","content",1,"mimeType")),"image/png")
    selected:=mcp(t,&f,fmt.tprintf(`{{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{{"name":"shot_take","arguments":{{"path":%q,"_select":"sum"}}}}}}`,small))
    testing.expect_value(t,integer(at(tool_text(t,selected),"sum")),7)
    testing.expect_value(t,string_of(at(selected,"result","content",1,"type")),"image")
    direct:=rpc(t,&f,fmt.tprintf(`{{"jsonrpc":"2.0","id":2,"method":"shot.take","params":{{"path":%q}}}}`,small))
    testing.expect_value(t,integer(at(direct,"result","sum")),7)
    // One that does not fit says where it is, and the result stays.
    big:=mcp(t,&f,call(large))
    testing.expect_value(t,integer(at(tool_text(t,big),"sum")),7)
    testing.expect(t,strings.contains(string_of(at(big,"result","content",1,"text")),"large.png"))
    missing:=mcp(t,&f,call(fmt.tprintf("%s/none.png",folder)))
    testing.expect(t,strings.contains(string_of(at(missing,"result","content",1,"text")),"could not be read"))
    testing.expect(t,is_bool(at(missing,"result","isError"),false))
}

// A method of the plugin animation and the plugins the project finds.
@(private)
fixture_plugins :: proc(t:^testing.T,f:^Fixture) {
    testing.expect_value(t,method_register(&f.server,{name="anim.play",summary="Plays a clip.",plugin="animation",params=Add_Params,result=Add_Result,handler=add_handler}),Register_Error.None)
    server_plugins_set(&f.server,{{"animation",true},{"terrain",false}})
}

@(test)
describe_without_params_is_an_index_of_names_short_summaries_and_plugins :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    fixture_plugins(t,&f)
    reply:=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe"}`)
    testing.expect(t,at(reply,"result","methods")==nil,"no entries with schemas")
    testing.expect_value(t,string_of(at(reply,"result","server","name")),"mirai")
    core_methods,ok:=at(reply,"result","core").(json.Array)
    testing.expect(t,ok && len(core_methods)>=2,"the methods used most")
    testing.expect_value(t,string_of(at(core_methods[0],"name")),"engine.describe")
    testing.expect(t,len(string_of(at(core_methods[0],"summary")))<=DESCRIBE_BRIEF,"a short summary")
    testing.expect(t,at(core_methods[1],"params")==nil && at(core_methods[1],"flags")==nil && at(core_methods[1],"tool")==nil,"only the name and the summary")
    groups:=at(reply,"result","others").(json.Array)
    found:=false
    for group in groups {
        if string_of(at(group,"plugin"))=="animation" {found=strings.contains(string_of(at(group,"methods")),"anim.play")}
    }
    testing.expect(t,found,"the other methods go by name under their plugin")
    testing.expect_value(t,string_of(at(reply,"result","active_plugins",0)),"animation")
    testing.expect_value(t,string_of(at(reply,"result","other_plugins",0)),"terrain")
    testing.expect(t,strings.contains(string_of(at(reply,"result","more")),"methods"),"it says how to ask for the rest")
}

// The first sentence or clause, and a word boundary when that is too long.
@(test)
a_brief_summary_keeps_its_first_clause_and_cuts_at_a_word :: proc(t:^testing.T) {
    testing.expect_value(t,summary_brief("Lists them; methods gives more."),"Lists them")
    testing.expect_value(t,summary_brief("Moves scene.add around. Then more."),"Moves scene.add around")
    testing.expect_value(t,summary_brief("one two three four",9),"one two")
}

@(test)
describe_gives_schemas_of_named_methods_and_summaries_of_a_prefix_or_a_plugin :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    fixture_plugins(t,&f)
    reply:=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":{"prefix":"test."}}`)
    methods:=at(reply,"result","methods").(json.Array)
    testing.expect_value(t,len(methods),7)
    for method in methods {testing.expect(t,strings.has_prefix(string_of(at(method,"name")),"test.") && at(method,"summary")!=nil && at(method,"params")==nil,"an area gives its summaries")}
    testing.expect(t,at(reply,"result","core")==nil && at(reply,"result","active_plugins")==nil,"the index comes only without params")
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":{"methods":["test.add","test.raw"]}}`)
    add:=at(reply,"result","methods",0)
    testing.expect_value(t,string_of(at(add,"tool")),"test_add")
    testing.expect_value(t,string_of(at(add,"plugin")),"editor")
    testing.expect_value(t,string_of(at(add,"flags",0)),"read_only")
    testing.expect_value(t,string_of(at(add,"flags",1)),"idempotent")
    testing.expect_value(t,integer(at(add,"params","properties","a","minimum")),-2147483648)
    testing.expect_value(t,string_of(at(add,"params","required",1)),"b")
    testing.expect(t,is_bool(at(add,"params","additionalProperties"),false),"boolean flag")
    testing.expect_value(t,string_of(at(add,"result","properties","sum","type")),"integer")
    raw_method:=at(reply,"result","methods",1)
    testing.expect_value(t,string_of(at(raw_method,"name")),"test.raw")
    testing.expect(t,at(raw_method,"result")!=nil,"a free-form result is described as any JSON")
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":{"methods":["test.echo","test.add","test.echo"]}}`)
    testing.expect_value(t,len(at(reply,"result","methods").(json.Array)),2)
    testing.expect(t,at(reply,"result","methods",1,"params")!=nil,"each named method has its schema")
    echo:=at(reply,"result","methods",0)
    if string_of(at(echo,"name"))!="test.echo" {echo=at(reply,"result","methods",1)}
    testing.expect_value(t,integer(at(echo,"params","properties","times","default")),1)
    testing.expect_value(t,integer(at(echo,"params","properties","times","maximum")),4)
    testing.expect_value(t,integer(at(echo,"params","properties","text","maxLength")),32)
    testing.expect_value(t,len(at(echo,"params","required").(json.Array)),1)
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":{"plugin":"animation"}}`)
    testing.expect_value(t,len(at(reply,"result","methods").(json.Array)),1)
    testing.expect_value(t,string_of(at(reply,"result","methods",0,"name")),"anim.play")
    testing.expect_value(t,string_of(at(reply,"result","methods",0,"plugin")),"animation")
    testing.expect_value(t,string_of(at(reply,"result","methods",0,"params","type")),"object")
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":{"plugin":"editor","prefix":"engine."}}`)
    testing.expect_value(t,len(at(reply,"result","methods").(json.Array)),1)
    testing.expect_value(t,string_of(at(reply,"result","methods",0,"name")),"engine.describe")
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":{"plugin":"animation","prefix":"test."}}`)
    testing.expect_value(t,integer(at(reply,"error","code")),INVALID_PARAMS)
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":{"prefix":"scene."}}`)
    testing.expect_value(t,integer(at(reply,"error","code")),INVALID_PARAMS)
    testing.expect(t,strings.contains(string_of(at(reply,"error","message")),"without params"),"the error says how to list the names")
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":{"methods":["test.echo","missing","gone"]}}`)
    testing.expect(t,strings.contains(string_of(at(reply,"error","message")),`"missing", "gone"`),"the error names every unknown method")
    for params in ([]string{`{"methods":["test.echo"],"prefix":"test."}`,`{"methods":["test.echo"],"plugin":"editor"}`,`{"compact":true}`,`{"schemas":false}`,`{"methods":["missing"]}`,`{"verbose":true}`}) {
        reply=rpc(t,&f,strings.concatenate({`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":`,params,"}"},context.temp_allocator))
        testing.expectf(t,integer(at(reply,"error","code"))==INVALID_PARAMS,"%s is refused",params)
    }
}

@(test)
describe_of_a_plugin_without_methods_says_which_plugins_have_them :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    fixture_plugins(t,&f)
    reply:=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":{"plugin":"missing"}}`)
    testing.expect_value(t,integer(at(reply,"error","code")),INVALID_PARAMS)
    testing.expect_value(t,string_of(at(reply,"error","message")),`no plugin is named "missing"; the plugins with methods are: editor, animation`)
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":{"plugin":"terrain"}}`)
    testing.expect_value(t,integer(at(reply,"error","code")),INVALID_PARAMS)
    testing.expect(t,strings.has_prefix(string_of(at(reply,"error","message")),`plugin "terrain" is not active in the project`),string_of(at(reply,"error","message")))
}

@(test)
mcp_initialize_negotiates_the_protocol_version :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t,{name="mirai-test",version="9",instructions="Use describe."}) {return}
    defer fixture_finish(&f)
    reply:=mcp(t,&f,`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}`)
    testing.expect_value(t,string_of(at(reply,"result","protocolVersion")),"2025-03-26")
    testing.expect_value(t,string_of(at(reply,"result","serverInfo","name")),"mirai-test")
    testing.expect_value(t,string_of(at(reply,"result","serverInfo","version")),"9")
    testing.expect_value(t,string_of(at(reply,"result","instructions")),"Use describe.")
    testing.expect(t,at(reply,"result","capabilities","tools")!=nil,"it serves tools")
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}`)
    testing.expect_value(t,string_of(at(reply,"result","protocolVersion")),"2025-11-25")
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":3,"method":"initialize"}`)
    testing.expect_value(t,string_of(at(reply,"result","protocolVersion")),"2025-11-25")
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":7}}`)
    testing.expect_value(t,string_of(at(reply,"result","protocolVersion")),"2025-11-25")
}

@(test)
mcp_notifications_are_accepted_and_pings_answered :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    status,body:=post(&f,"/mcp",`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
    testing.expect_value(t,status,202)
    testing.expect_value(t,body,"")
    status,_=post(&f,"/mcp",`{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}`)
    testing.expect_value(t,status,202)
    status,_=post(&f,"/mcp",`{"jsonrpc":"2.0","id":3,"result":{}}`)
    testing.expect_value(t,status,202)
    reply:=mcp(t,&f,`{"jsonrpc":"2.0","id":9,"method":"ping"}`)
    testing.expect_value(t,integer(at(reply,"id")),9)
    testing.expect(t,at(reply,"result")!=nil,"ping answers")
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":10,"method":"resources/list"}`)
    testing.expect_value(t,integer(at(reply,"error","code")),METHOD_NOT_FOUND)
}

@(test)
mcp_lists_each_method_as_a_tool_with_its_input_and_object_output_schemas :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    reply:=mcp(t,&f,`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
    tools,ok:=at(reply,"result","tools").(json.Array)
    testing.expect(t,ok && len(tools)==9,"one tool per method of the core, and call")
    testing.expect_value(t,string_of(at(reply,"result","tools",8,"name")),MCP_CALL_TOOL)
    testing.expect(t,at(reply,"result","nextCursor")==nil,"everything fits in one page")
    testing.expect_value(t,string_of(at(reply,"result","tools",0,"name")),"engine_describe")
    add:=at(reply,"result","tools",1)
    testing.expect_value(t,string_of(at(add,"name")),"test_add")
    testing.expect_value(t,string_of(at(add,"description")),"Adds two integers.")
    testing.expect_value(t,string_of(at(add,"inputSchema","type")),"object")
    testing.expect_value(t,integer(at(add,"inputSchema","properties","a","maximum")),2147483647)
    testing.expect(t,at(add,"outputSchema")==nil,"a model reads a result as text")
    testing.expect(t,is_bool(at(add,"annotations","readOnlyHint"),true),"boolean flag")
    testing.expect(t,is_bool(at(add,"annotations","destructiveHint"),false),"boolean flag")
    testing.expect(t,is_bool(at(add,"annotations","idempotentHint"),true),"boolean flag")
    testing.expect(t,is_bool(at(reply,"result","tools",3,"annotations","destructiveHint"),true),"boolean flag")
    for tool in tools {
        testing.expect(t,!strings.contains(string_of(at(tool,"name")),"."),"tool names have no dots")
        testing.expect_value(t,string_of(at(tool,"inputSchema","type")),"object")
    }
}

@(test)
mcp_lists_the_tools_of_the_plugins_that_x_mirai_plugins_names :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    fixture_plugins(t,&f)
    testing.expect_value(t,method_register(&f.server,{name="body.push",summary="Pushes a body.",plugin="physics",handler=raw_handler}),Register_Error.None)
    names :: proc(t:^testing.T,f:^Fixture,plugins:string) -> []string {
        status,body,err:=client_post(server_port(&f.server),"/mcp",`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`,3000,context.temp_allocator,"",plugins)
        testing.expectf(t,err.code==0 && status==200,"HTTP %d %s: %s",status,err.message,string(body))
        tools,_:=at(parse_json(t,string(body)),"result","tools").(json.Array)
        out:=make([]string,len(tools),context.temp_allocator)
        for tool,i in tools {out[i]=string_of(at(tool,"name"))}
        return out
    }
    editor_only:=names(t,&f,"")
    testing.expect_value(t,len(editor_only),9)
    testing.expect(t,!slice.contains(editor_only,"anim_play") && !slice.contains(editor_only,"body_push"),"without the header only the tools of the editor")
    one:=names(t,&f,"animation")
    testing.expect_value(t,len(one),10)
    testing.expect(t,slice.contains(one,"anim_play") && !slice.contains(one,"body_push"))
    two:=names(t,&f,"physics, animation")
    testing.expect_value(t,len(two),11)
    testing.expect_value(t,len(names(t,&f,"*")),11)
    reply:=mcp(t,&f,`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"anim_play","arguments":{"a":1,"b":2}}}`)
    testing.expect_value(t,integer(at(tool_text(t,reply),"sum")),3)
    status,_,_:=client_post(server_port(&f.server),"/mcp",`{"jsonrpc":"2.0","id":3,"method":"tools/list"}`,3000,context.temp_allocator,"","anim;rm")
    testing.expect_value(t,status,400)
}

@(test)
mcp_lists_tools_in_pages_when_they_do_not_fit :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t,{max_response=4096}) {return}
    defer fixture_finish(&f)
    for i in 0..<10 {testing.expect_value(t,method_register(&f.server,{name=fmt.tprintf("bulk.%d",i),params=Shapes,result=Shapes,handler=shapes_handler,flags={.Core}}),Register_Error.None)}
    seen:[dynamic]string
    seen.allocator=context.temp_allocator
    cursor:=""
    pages:=0
    for {
        body:=cursor==""?`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`:strings.concatenate({`{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"`,cursor,`"}}`},context.temp_allocator)
        reply:=mcp(t,&f,body)
        tools,ok:=at(reply,"result","tools").(json.Array)
        testing.expect(t,ok && len(tools)>0,"every page has tools")
        for tool in tools {append(&seen,string_of(at(tool,"name")))}
        pages+=1
        cursor=string_of(at(reply,"result","nextCursor"))
        if cursor=="" || pages>20 {break}
    }
    testing.expect(t,pages>1,"the tools need several pages")
    testing.expect_value(t,len(seen),19)
    testing.expect_value(t,seen[7],"test_broken")
    testing.expect_value(t,seen[17],"bulk_9")
    reply:=mcp(t,&f,`{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"99"}}`)
    testing.expect_value(t,integer(at(reply,"error","code")),INVALID_PARAMS)
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"x"}}`)
    testing.expect_value(t,integer(at(reply,"error","code")),INVALID_PARAMS)
}

@(test)
mcp_calls_a_tool_and_returns_results_as_text :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    reply:=mcp(t,&f,`{"jsonrpc":"2.0","id":"c1","method":"tools/call","params":{"name":"test_add","arguments":{"a":40,"b":2}}}`)
    testing.expect_value(t,string_of(at(reply,"id")),"c1")
    testing.expect_value(t,string_of(at(reply,"result","content",0,"type")),"text")
    testing.expect(t,is_bool(at(reply,"result","isError"),false),"boolean flag")
    testing.expect_value(t,integer(at(tool_text(t,reply),"sum")),42)
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"test_echo","arguments":{"text":"say \"hi\"\n","times":2}}}`)
    testing.expect_value(t,string_of(at(tool_text(t,reply),"text")),"say \"hi\"\nsay \"hi\"\n")
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"engine_describe","arguments":{"methods":["test.add"]}}}`)
    testing.expect_value(t,string_of(at(tool_text(t,reply),"methods",0,"name")),"test.add")
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"test_raw"}}`)
    testing.expect_value(t,integer(at(tool_text(t,reply),"bytes")),2)
    reply=mcp(t,&f,`[{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"test_add","arguments":{"a":1,"b":1}}},{"jsonrpc":"2.0","method":"notifications/initialized"}]`)
    testing.expect_value(t,len(reply.(json.Array)),1)
}

@(test)
mcp_failures_are_tool_errors_and_misuse_is_a_protocol_error :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t,{max_response=4096}) {return}
    defer fixture_finish(&f)
    reply:=mcp(t,&f,`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"test_fail","arguments":{}}}`)
    testing.expect(t,is_bool(at(reply,"result","isError"),true),"boolean flag")
    testing.expect_value(t,integer(at(tool_text(t,reply),"error","code")),SERVER_ERROR)
    testing.expect_value(t,integer(at(tool_text(t,reply),"error","data","attempt")),4)
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"test_add","arguments":{"a":"x","b":1}}}`)
    testing.expect(t,is_bool(at(reply,"result","isError"),true),"boolean flag")
    testing.expect_value(t,integer(at(tool_text(t,reply),"error","code")),INVALID_PARAMS)
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"test_big"}}`)
    testing.expect(t,is_bool(at(reply,"result","isError"),true),"boolean flag")
    testing.expect_value(t,integer(at(tool_text(t,reply),"error","code")),SERVER_ERROR)
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"test_broken"}}`)
    testing.expect(t,is_bool(at(reply,"result","isError"),true),"boolean flag")
    misuse:=[]string{
        `{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}`,
        `{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":7}}`,
        `{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}`,
        `{"jsonrpc":"2.0","id":5,"method":"tools/call"}`,
        `{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"test_add","arguments":[1]}}`,
    }
    for body in misuse {
        reply=mcp(t,&f,body)
        testing.expectf(t,integer(at(reply,"error","code"))==INVALID_PARAMS,"%s: %v",body,reply)
    }
}

mcp_json_handler :: proc(call:^Call) {raw(call.out,(^string)(call.user)^)}

mcp_process_reply :: proc(t:^testing.T,s:^Server,body:string) -> json.Value {
    serial.writer_reset(&s.out)
    testing.expect(t,process(s,body,.Mcp))
    testing.expect_value(t,s.out.overflow,0)
    return parse_json(t,string(serial.writer_bytes(&s.out)))
}

// The editor serves the docs tool itself, from the documentation of its
// engine, the same one mirai mcp answers without an editor.
@(test)
mcp_serves_the_game_documentation_of_its_engine :: proc(t:^testing.T) {
    root:=base.test_folder(t,"mcp-docs")
    if root=="" {return}
    testing.expect(t,os.make_directory_all(fmt.tprintf("%s/%s",root,DOCS_FOLDER))==nil)
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/%s/core.md",root,DOCS_FOLDER),transmute([]u8)string("---\ndescription: Entities and tables.\n---\n# Core\n\nBody.\n"))==nil)
    testing.expect(t,os.make_directory_all(fmt.tprintf("%s/%s/core",root,DOCS_FOLDER))==nil)
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/%s/core/prefabs.md",root,DOCS_FOLDER),transmute([]u8)string("# Prefabs and spawning\n\nPage.\n"))==nil)
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    s.docs_root=strings.clone(root,s.allocator)
    reply:=mcp_process_reply(t,&s,`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
    testing.expect_value(t,string_of(at(reply,"result","tools",0,"name")),MCP_DOCS_TOOL)
    reply=mcp_process_reply(t,&s,`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"docs","arguments":{"topic":"core"}}}`)
    testing.expect(t,strings.contains(string_of(at(reply,"result","content",0,"text")),"Body."),string_of(at(reply,"result","content",0,"text")))
    reply=mcp_process_reply(t,&s,`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"docs","arguments":{"topic":"nope"}}}`)
    testing.expect(t,is_bool(at(reply,"result","isError"),true))
    reply=mcp_process_reply(t,&s,`{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}`)
    instructions:=string_of(at(reply,"result","instructions"))
    testing.expect(t,strings.contains(instructions,DOCS_INSTRUCTION))
    testing.expect(t,strings.contains(instructions,"- core: Entities and tables.\n  - core prefabs: Prefabs and spawning"),instructions)
    reply=mcp_process_reply(t,&s,`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"docs","arguments":{}}}`)
    index:=string_of(at(reply,"result","content",0,"text"))
    testing.expect(t,strings.contains(index,"Entities and tables.\n  core prefabs: Prefabs and spawning"),index)
}

@(test)
mcp_rejects_malformed_results :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    text:=`{"value":7}`
    testing.expect_value(t,method_register(&s,{name="free",handler=mcp_json_handler,user=&text}),Register_Error.None)
    values:=[]string{`[1,2]`,`"hello"`,`3`,`true`,`null`}
    for value in values {
        text=value
        reply:=mcp_process_reply(t,&s,`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"free"}}`)
        testing.expect(t,is_bool(at(reply,"result","isError"),false))
        testing.expect_value(t,string_of(at(reply,"result","content",0,"text")),value)
    }
    malformed:=[]string{`{"value":`,`{"value":7} false`,`not json`}
    for value in malformed {
        text=value
        reply:=mcp_process_reply(t,&s,`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"free"}}`)
        testing.expect(t,is_bool(at(reply,"result","isError"),true))
        testing.expect_value(t,integer(at(tool_text(t,reply),"error","code")),INTERNAL_ERROR)
    }
}

@(test)
mcp_results_remain_bounded_and_recover_after_scratch_failure_without_allocations :: proc(t:^testing.T) {
    s,ok:=test_server(t,{max_request=1024,max_response=4096});if !ok {return}
    defer server_destroy(&s)
    buffer:[3600]u8
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer[:])
    raw(&w,`{"value":"`)
    for _ in 0..<1700 {raw(&w,`\n`)}
    raw(&w,`"}`)
    text:=string(serial.writer_bytes(&w))
    testing.expect_value(t,method_register(&s,{name="object",result_schema=`{"type":"object"}`,handler=mcp_json_handler,user=&text}),Register_Error.None)
    saved_allocator:=context.allocator
    context.allocator=mem.nil_allocator()
    serial.writer_reset(&s.out)
    testing.expect(t,process(&s,`{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"object"}}`,.Mcp))
    context.allocator=saved_allocator
    reply:=parse_json(t,string(serial.writer_bytes(&s.out)))
    testing.expect_value(t,integer(at(reply,"id")),8)
    testing.expect_value(t,integer(at(reply,"error","code")),SERVER_ERROR)
    testing.expect(t,at(reply,"result")==nil,"a partial result is never sent")
    saved_scratch:=s.scratch.arena.data
    s.scratch.arena.data=saved_scratch[:64]
    context.allocator=mem.nil_allocator()
    serial.writer_reset(&s.out)
    testing.expect(t,process(&s,`{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"object"}}`,.Mcp))
    context.allocator=saved_allocator
    s.scratch.arena.data=saved_scratch
    reply=parse_json(t,string(serial.writer_bytes(&s.out)))
    testing.expect(t,is_bool(at(reply,"result","isError"),true))
    testing.expect_value(t,integer(at(tool_text(t,reply),"error","code")),INTERNAL_ERROR)
    testing.expect_value(t,s.stats.scratch_failures,1)
    text=`{"value":42}`
    context.allocator=mem.nil_allocator()
    serial.writer_reset(&s.out)
    testing.expect(t,process(&s,`{"jsonrpc":"2.0","id":10,"method":"tools/list"}`,.Mcp))
    serial.writer_reset(&s.out)
    testing.expect(t,process(&s,`{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"object"}}`,.Mcp))
    context.allocator=saved_allocator
    reply=parse_json(t,string(serial.writer_bytes(&s.out)))
    testing.expect(t,is_bool(at(reply,"result","isError"),false))
    testing.expect_value(t,integer(at(tool_text(t,reply),"value")),42)
}

is_bool :: proc(value:json.Value,want:bool) -> bool {
    flag,ok:=value.(json.Boolean)
    return ok && bool(flag)==want
}

@(test)
mcp_lists_the_core_and_call_runs_any_other_method_by_its_name :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    testing.expect_value(t,method_register(&f.server,{name="rare.sum",summary="Adds two integers.",params=Add_Params,result=Add_Result,handler=add_handler}),Register_Error.None)
    reply:=mcp(t,&f,`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
    tools,_:=at(reply,"result","tools").(json.Array)
    for tool in tools {testing.expect(t,string_of(at(tool,"name"))!="rare_sum","a method outside the core is not a tool of the list")}
    call:=at(reply,"result","tools",len(tools)-1)
    testing.expect(t,string_of(at(call,"name"))==MCP_CALL_TOOL && string_of(at(call,"inputSchema","required",0))=="method")
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"method":"rare.sum","params":{"a":2,"b":3}}}}`)
    testing.expect(t,is_bool(at(reply,"result","isError"),false))
    testing.expect_value(t,integer(at(tool_text(t,reply),"sum")),5)
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rare_sum","arguments":{"a":1,"b":1}}}`)
    testing.expect_value(t,integer(at(tool_text(t,reply),"sum")),2)
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"method":"missing.thing"}}}`)
    testing.expect(t,strings.contains(string_of(at(reply,"error","message")),"engine_describe lists the methods"),"an unknown method says where the methods are")
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"params":{}}}}`)
    testing.expect_value(t,integer(at(reply,"error","code")),INVALID_PARAMS)
}

@(test)
describe_gives_the_guides_of_the_methods_it_gives :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    fixture_plugins(t,&f)
    server_guides_set(&f.server,{{"animation","Animate by intent."},{"test.echo","Echo repeats."},{"terrain","Sculpt."}})
    reply:=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":{"plugin":"animation"}}`)
    guides,ok:=at(reply,"result","guides").(json.Array)
    testing.expect(t,ok && len(guides)==1 && string_of(guides[0])=="Animate by intent.","the guide of the plugin comes with its methods")
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":2,"method":"engine.describe","params":{"methods":["test.echo"]}}`)
    testing.expect_value(t,string_of(at(reply,"result","guides",0)),"Echo repeats.")
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":3,"method":"engine.describe","params":{"methods":["test.add"]}}`)
    testing.expect(t,at(reply,"result","guides")==nil,"a method without a guide comes alone")
    reply=rpc(t,&f,`{"jsonrpc":"2.0","id":4,"method":"engine.describe"}`)
    testing.expect(t,at(reply,"result","guides")==nil,"the list of every method carries no guide")
}

// Works for a little more than a second, telling its progress and stopping when cancelled.
@(private="file")
slow_handler :: proc(call:^Call) {
    s:=call.server
    for i in 0..<130 {
        if server_cancelled(s) {return}
        server_progress(s,"working",i,130)
        time.sleep(10*time.Millisecond)
    }
    raw(call.out,`{"done":true}`)
}

@(private="file")
Slow_Events :: struct {lines:[dynamic]string}

@(private="file")
slow_event :: proc(user:rawptr,line:string) {
    events:=(^Slow_Events)(user)
    append(&events.lines,strings.clone(line,context.temp_allocator))
}

@(private="file")
slow_call :: proc(meta:string) -> string {
    return strings.concatenate({`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"test_slow","arguments":{}`,meta,`}}`},context.temp_allocator)
}

// A call with a token answers as a stream of its progress and its answer last;
// without one, or without an Accept for it, it is one JSON as any other.
@(test)
a_call_with_a_progress_token_streams_its_progress_and_one_without_answers_as_always :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    if !fixture_start(f,t,{timeout_ms=5000}) {return}
    defer fixture_finish(f)
    testing.expect_value(t,method_register(&f.server,{name="test.slow",summary="Works for a while.",handler=slow_handler,flags={.Core}}),Register_Error.None)
    port:=server_port(&f.server)
    events:Slow_Events
    events.lines.allocator=context.temp_allocator
    body:=slow_call(`,"_meta":{"progressToken":"t1"}`)
    status,bytes,err:=client_post(port,"/mcp",body,5000,context.temp_allocator,events={&events,slow_event})
    testing.expectf(t,err.code==0 && status==200,"%d %v",status,err)
    testing.expectf(t,len(events.lines)>=2,"%v",events.lines)
    if len(events.lines)>0 {
        first:=parse_json(t,events.lines[0])
        testing.expect_value(t,string_of(at(first,"method")),"notifications/progress")
        testing.expect_value(t,string_of(at(first,"params","progressToken")),"t1")
        testing.expect_value(t,integer(at(first,"params","total")),130)
    }
    testing.expectf(t,strings.contains(string(bytes),`done`),"the answer comes last: %s",string(bytes))
    plain:=slow_call("")
    status,bytes,err=client_post(port,"/mcp",plain,5000,context.temp_allocator)
    testing.expectf(t,err.code==0 && status==200 && strings.contains(string(bytes),`done`),"%d %v %s",status,err,string(bytes))
    noted:=slow_call(`,"_meta":{"progressToken":"t2"}`)
    status,bytes,err=client_post(port,"/mcp",noted,5000,context.temp_allocator)
    testing.expectf(t,err.code==0 && status==200 && !strings.contains(string(bytes),"data:"),"no Accept, no stream: %s",string(bytes))
}

// A notifications/cancelled that arrives on another connection ends the wait at
// its safe point, and the call answers that it was cancelled.
@(test)
a_cancelled_call_stops_at_its_safe_point_and_says_so :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    if !fixture_start(f,t,{timeout_ms=5000}) {return}
    defer fixture_finish(f)
    testing.expect_value(t,method_register(&f.server,{name="test.slow",summary="Works for a while.",handler=slow_handler,flags={.Core}}),Register_Error.None)
    Canceller :: struct {port:int}
    canceller:=Canceller{server_port(&f.server)}
    cancel :: proc(c:^Canceller) {
        time.sleep(200*time.Millisecond)
        client_post(c.port,"/mcp",`{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"enough"}}`,3000,context.temp_allocator)
    }
    th:=thread.create_and_start_with_poly_data(&canceller,cancel)
    defer {thread.join(th);thread.destroy(th)}
    began:=time.tick_now()
    status,bytes,err:=client_post(canceller.port,"/mcp",slow_call(""),5000,context.temp_allocator)
    testing.expectf(t,err.code==0 && status==200,"%d %v",status,err)
    testing.expect(t,time.duration_seconds(time.tick_since(began))<1,"it did not run to its end")
    reply:=parse_json(t,string(bytes))
    testing.expect(t,at(reply,"result","isError").(json.Boolean),string(bytes))
    testing.expect_value(t,integer(at(tool_text(t,reply),"error","code")),CANCELLED)
}

// initialize says which editor answers, and the bridge what it knows without one.
@(test)
initialize_says_which_editor_answers_under_meta :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    if !fixture_start(f,t) {return}
    defer fixture_finish(f)
    f.server.instance={process=321,engine="9.9",project="demo",folder="C:/demo"}
    reply:=mcp(t,f,`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`)
    meta:=at(reply,"result","_meta")
    testing.expect_value(t,integer(at(meta,"process_id")),321)
    testing.expect_value(t,string_of(at(meta,"engine_version")),"9.9")
    testing.expect_value(t,string_of(at(meta,"project")),"demo")
    testing.expect_value(t,string_of(at(meta,"project_folder")),"C:/demo")
    text,_:=bridge_absent(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`,{instructions="none",instance={engine="9.9",project="demo",folder="C:/demo"}},context.temp_allocator)
    absent:=parse_json(t,text)
    testing.expect_value(t,string_of(at(absent,"result","_meta","project")),"demo")
    _,has_process:=at(absent,"result","_meta").(json.Object)["process_id"]
    testing.expect(t,!has_process,"no process while no editor answers")
}
