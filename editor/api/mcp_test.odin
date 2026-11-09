package api

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
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
    raw(call.out,`{"content":[{"type":"image","data":"`)
    raw(call.out,call.user!=nil?(^string)(call.user)^:"c2F2ZWQ=")
    raw(call.out,`","mimeType":"image/png"}],"isError":false}`)
}

@(test)
large_mcp_images_keep_the_complete_content_with_small_socket_buffers :: proc(t:^testing.T) {
    server:Server
    if !testing.expect_value(t,server_init(&server,{port=0,max_connections=1,timeout_ms=5000}),Init_Error.None) {return}
    defer server_destroy(&server)
    payload:=strings.repeat("AQID",230*1024,context.allocator)
    defer delete(payload)
    testing.expect_value(t,method_register(&server,{name="view.viewport",handler=mcp_image_handler,mcp_content=true,user=&payload}),Register_Error.None)
    // The receiver window must be negotiated before the TCP handshake.
    receiver,listen_error:=net.listen_tcp({address=net.IP4_Loopback,port=0},1)
    if !testing.expect(t,listen_error==nil) {return}
    defer net.close(receiver)
    testing.expect(t,net.set_option(receiver,.Receive_Buffer_Size,8192)==nil)
    endpoint,endpoint_error:=net.bound_endpoint(receiver)
    if !testing.expect(t,endpoint_error==nil) {return}
    paths:=[2]string{"/rpc","/mcp"}
    requests:=[2]string{
        `{"jsonrpc":"2.0","id":1,"method":"view.viewport"}`,
        `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"view_viewport","arguments":{}}}`,
    }
    for path,index in paths {
        writer,dial_error:=net.dial_tcp_from_address_and_port(net.IP4_Loopback,endpoint.port)
        if !testing.expect(t,dial_error==nil) {return}
        socket,_,accept_error:=net.accept_tcp(receiver)
        if !testing.expect(t,accept_error==nil) {net.close(writer);return}
        defer net.close(socket)
        testing.expect(t,net.set_option(writer,.Send_Buffer_Size,8192)==nil)
        testing.expect(t,net.set_blocking(writer,false)==nil)
        conn:=&server.conns[0]
        conn^={socket=writer,state=.Reading,buffer=conn.buffer,started=time.tick_now()}
        request:=http_request(path,requests[index])
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
        _,declared_length:=response_head(text[:head])
        testing.expect_value(t,len(body),declared_length)
        if !testing.expect(t,!strings.contains(body,"HTTP/1.1"),"a partial send never repeats the HTTP header") {return}
        reply,parse_error:=json.parse(transmute([]u8)body,parse_integers=true,allocator=context.temp_allocator)
        if !testing.expect_value(t,parse_error,json.Error.None) {return}
        testing.expect_value(t,string_of(at(reply,"result","content",0,"type")),"image")
        received:=string_of(at(reply,"result","content",0,"data"))
        testing.expect_value(t,len(received),len(payload))
        testing.expect(t,received==payload,"the complete image data matches")
        testing.expect_value(t,string_of(at(reply,"result","content",0,"mimeType")),"image/png")
        testing.expect(t,is_bool(at(reply,"result","isError"),false))
    }
}

@(test)
mcp_image_results_remain_content_and_failures_remain_tool_errors :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    testing.expect_value(t,method_register(&f.server,{name="view.viewport",handler=mcp_image_handler,mcp_content=true}),Register_Error.None)
    testing.expect_value(t,method_register(&f.server,{name="view.error",params=Fail_Params,handler=fail_handler,mcp_content=true}),Register_Error.None)
    reply:=mcp(t,&f,`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"view_viewport","arguments":{}}}`)
    testing.expect_value(t,string_of(at(reply,"result","content",0,"type")),"image")
    testing.expect_value(t,string_of(at(reply,"result","content",0,"data")),"c2F2ZWQ=")
    testing.expect_value(t,string_of(at(reply,"result","content",0,"mimeType")),"image/png")
    testing.expect(t,is_bool(at(reply,"result","isError"),false))
    direct:=rpc(t,&f,`{"jsonrpc":"2.0","id":2,"method":"view.viewport"}`)
    testing.expect_value(t,string_of(at(direct,"result","content",0,"type")),"image")
    failed:=mcp(t,&f,`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"view_error","arguments":{}}}`)
    testing.expect(t,is_bool(at(failed,"result","isError"),true))
    testing.expect_value(t,integer(at(tool_text(t,failed),"error","code")),SERVER_ERROR)
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
    folder,_:=os.make_directory_temp("","mirai-image-*",context.allocator)
    defer {os.remove_all(folder);delete(folder)}
    small:=fmt.tprintf("%s/small.png",folder)
    large:=fmt.tprintf("%s/large.png",folder)
    testing.expect(t,os.write_entire_file(small,[]u8{1,2,3,4})==nil)
    testing.expect(t,os.write_entire_file(large,make([]u8,MIN_RESPONSE,context.temp_allocator))==nil)
    call :: proc(path:string) -> string {return fmt.tprintf(`{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"shot_take","arguments":{{"path":%q}}}}}}`,path)}
    reply:=mcp(t,&f,call(small))
    testing.expect_value(t,integer(at(tool_text(t,reply),"sum")),7)
    testing.expect_value(t,integer(at(reply,"result","structuredContent","sum")),7)
    testing.expect_value(t,string_of(at(reply,"result","content",1,"type")),"image")
    testing.expect_value(t,string_of(at(reply,"result","content",1,"data")),"AQIDBA==")
    testing.expect_value(t,string_of(at(reply,"result","content",1,"mimeType")),"image/png")
    direct:=rpc(t,&f,fmt.tprintf(`{{"jsonrpc":"2.0","id":2,"method":"shot.take","params":{{"path":%q}}}}`,small))
    testing.expect_value(t,integer(at(direct,"result","sum")),7)
    // One that does not fit says where it is, and the result stays.
    big:=mcp(t,&f,call(large))
    testing.expect_value(t,integer(at(big,"result","structuredContent","sum")),7)
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
describe_without_params_lists_each_method_with_its_plugin_and_the_plugins_found :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    fixture_plugins(t,&f)
    reply:=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe"}`)
    methods,ok:=at(reply,"result","methods").(json.Array)
    testing.expect(t,ok && len(methods)==9,"the built-in method, the seven samples and the one of the plugin")
    testing.expect_value(t,string_of(at(reply,"result","server","name")),"mirai")
    testing.expect_value(t,string_of(at(methods[0],"name")),"engine.describe")
    testing.expect_value(t,string_of(at(methods[0],"plugin")),"editor")
    testing.expect_value(t,string_of(at(methods[1],"summary")),"Adds two integers.")
    testing.expect(t,at(methods[1],"params")==nil && at(methods[1],"flags")==nil && at(methods[1],"tool")==nil,"only the name, the summary and the plugin")
    testing.expect_value(t,string_of(at(methods[8],"name")),"anim.play")
    testing.expect_value(t,string_of(at(methods[8],"plugin")),"animation")
    testing.expect_value(t,len(at(reply,"result","plugins").(json.Array)),2)
    testing.expect_value(t,string_of(at(reply,"result","plugins",0,"name")),"animation")
    testing.expect(t,is_bool(at(reply,"result","plugins",0,"active"),true))
    testing.expect(t,is_bool(at(reply,"result","plugins",1,"active"),false),"a plugin the project does not use is listed too")
}

@(test)
describe_gives_whole_entries_of_named_methods_a_prefix_or_a_plugin :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    fixture_plugins(t,&f)
    reply:=rpc(t,&f,`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":{"prefix":"test."}}`)
    methods:=at(reply,"result","methods").(json.Array)
    testing.expect_value(t,len(methods),7)
    for method in methods {testing.expect(t,strings.has_prefix(string_of(at(method,"name")),"test.") && at(method,"params")!=nil)}
    testing.expect(t,at(reply,"result","plugins")==nil,"the plugins come only with the list")
    add:=at(reply,"result","methods",0)
    testing.expect_value(t,string_of(at(add,"tool")),"test_add")
    testing.expect_value(t,string_of(at(add,"plugin")),"editor")
    testing.expect_value(t,string_of(at(add,"flags",0)),"read_only")
    testing.expect_value(t,string_of(at(add,"flags",1)),"idempotent")
    testing.expect_value(t,integer(at(add,"params","properties","a","minimum")),-2147483648)
    testing.expect_value(t,string_of(at(add,"params","required",1)),"b")
    testing.expect(t,is_bool(at(add,"params","additionalProperties"),false),"boolean flag")
    testing.expect_value(t,string_of(at(add,"result","properties","sum","type")),"integer")
    raw_method:=at(reply,"result","methods",4)
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
    testing.expect_value(t,string_of(at(add,"outputSchema","type")),"object")
    testing.expect_value(t,string_of(at(add,"outputSchema","properties","sum","type")),"integer")
    testing.expect_value(t,string_of(at(add,"outputSchema","required",0)),"sum")
    testing.expect(t,at(reply,"result","tools",5,"outputSchema")==nil,"free-form results do not promise a schema")
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
    testing.expect_value(t,integer(at(reply,"result","structuredContent","sum")),3)
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
mcp_calls_a_tool_and_returns_object_results_as_text_and_structured_content :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    reply:=mcp(t,&f,`{"jsonrpc":"2.0","id":"c1","method":"tools/call","params":{"name":"test_add","arguments":{"a":40,"b":2}}}`)
    testing.expect_value(t,string_of(at(reply,"id")),"c1")
    testing.expect_value(t,string_of(at(reply,"result","content",0,"type")),"text")
    testing.expect(t,is_bool(at(reply,"result","isError"),false),"boolean flag")
    testing.expect_value(t,integer(at(tool_text(t,reply),"sum")),42)
    testing.expect_value(t,integer(at(reply,"result","structuredContent","sum")),42)
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"test_echo","arguments":{"text":"say \"hi\"\n","times":2}}}`)
    testing.expect_value(t,string_of(at(tool_text(t,reply),"text")),"say \"hi\"\nsay \"hi\"\n")
    testing.expect_value(t,string_of(at(reply,"result","structuredContent","text")),"say \"hi\"\nsay \"hi\"\n")
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"engine_describe","arguments":{"methods":["test.add"]}}}`)
    testing.expect_value(t,string_of(at(tool_text(t,reply),"methods",0,"name")),"test.add")
    testing.expect_value(t,string_of(at(reply,"result","structuredContent","methods",0,"name")),"test.add")
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"test_raw"}}`)
    testing.expect_value(t,integer(at(tool_text(t,reply),"bytes")),2)
    testing.expect_value(t,integer(at(reply,"result","structuredContent","bytes")),2)
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
    testing.expect(t,at(reply,"result","structuredContent")==nil,"tool errors do not claim to conform to the success schema")
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
    root:=fmt.tprintf(".mirai/test-mcp-docs-%d",os.get_pid())
    defer os.remove_all(root)
    testing.expect(t,os.make_directory_all(fmt.tprintf("%s/%s",root,DOCS_FOLDER))==nil)
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/%s/core.md",root,DOCS_FOLDER),transmute([]u8)string("---\ndescription: Entities and tables.\n---\n# Core\n\nBody.\n"))==nil)
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
    testing.expect(t,strings.contains(string_of(at(reply,"result","instructions")),DOCS_INSTRUCTION))
}

@(test)
mcp_explicit_object_output_schemas_share_the_method_contract :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    OBJECT :: `{"type":"object","properties":{"value":{"type":"integer"}},"required":["value"],"additionalProperties":false}`
    text:=` {"value":7} `
    testing.expect_value(t,method_register(&s,{name="object",result_schema=OBJECT,handler=mcp_json_handler,user=&text,flags={.Core}}),Register_Error.None)
    testing.expect_value(t,method_register(&s,{name="array",result_schema=`{"type":"array"}`,handler=mcp_json_handler,user=&text}),Register_Error.None)
    testing.expect_value(t,method_register(&s,{name="any",result_schema=`{}`,handler=mcp_json_handler,user=&text}),Register_Error.None)
    testing.expect_value(t,method_register(&s,{name="invalid",result_schema=`{"type":`,handler=mcp_json_handler,user=&text}),Register_Error.Invalid_Schema)
    reply:=mcp_process_reply(t,&s,`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
    schema:=at(reply,"result","tools",1,"outputSchema")
    testing.expect_value(t,string_of(at(schema,"type")),"object")
    testing.expect_value(t,string_of(at(schema,"properties","value","type")),"integer")
    testing.expect_value(t,string_of(at(schema,"required",0)),"value")
    testing.expect(t,is_bool(at(schema,"additionalProperties"),false))
    testing.expect(t,at(reply,"result","tools",2,"outputSchema")==nil)
    testing.expect(t,at(reply,"result","tools",3,"outputSchema")==nil)
    reply=mcp_process_reply(t,&s,`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"object"}}`)
    testing.expect_value(t,integer(at(reply,"result","structuredContent","value")),7)
    testing.expect_value(t,integer(at(tool_text(t,reply),"value")),7)
    testing.expect_value(t,string_of(at(reply,"result","content",0,"text")),text)
}

@(test)
mcp_rejects_malformed_results_and_object_schema_type_mismatches :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    text:=`{"value":7}`
    testing.expect_value(t,method_register(&s,{name="free",handler=mcp_json_handler,user=&text}),Register_Error.None)
    testing.expect_value(t,method_register(&s,{name="object",result_schema=`{"type":"object"}`,handler=mcp_json_handler,user=&text}),Register_Error.None)
    values:=[]string{`[1,2]`,`"hello"`,`3`,`true`,`null`}
    for value in values {
        text=value
        reply:=mcp_process_reply(t,&s,`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"free"}}`)
        testing.expect(t,is_bool(at(reply,"result","isError"),false))
        testing.expect(t,at(reply,"result","structuredContent")==nil,"MCP 2025 structured content is an object")
        testing.expect_value(t,string_of(at(reply,"result","content",0,"text")),value)
        reply=mcp_process_reply(t,&s,`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"object"}}`)
        testing.expect(t,is_bool(at(reply,"result","isError"),true))
        testing.expect_value(t,integer(at(tool_text(t,reply),"error","code")),INTERNAL_ERROR)
        testing.expect(t,at(reply,"result","structuredContent")==nil)
    }
    malformed:=[]string{`{"value":`,`{"value":7} false`,`not json`}
    for value in malformed {
        text=value
        reply:=mcp_process_reply(t,&s,`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"free"}}`)
        testing.expect(t,is_bool(at(reply,"result","isError"),true))
        testing.expect_value(t,integer(at(tool_text(t,reply),"error","code")),INTERNAL_ERROR)
        testing.expect(t,at(reply,"result","structuredContent")==nil)
    }
}

@(test)
mcp_structured_results_remain_bounded_and_recover_after_scratch_failure_without_allocations :: proc(t:^testing.T) {
    s,ok:=test_server(t,{max_request=1024,max_response=4096});if !ok {return}
    defer server_destroy(&s)
    buffer:[3600]u8
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer[:])
    raw(&w,`{"value":"`)
    for _ in 0..<1300 {raw(&w,`\n`)}
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
    testing.expect(t,at(reply,"result")==nil,"a partial structured result is never sent")
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
    testing.expect(t,at(reply,"result","structuredContent")==nil)
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
    testing.expect_value(t,integer(at(reply,"result","structuredContent","value")),42)
    serial.writer_reset(&w)
    raw(&w,`{"type":"object","description":"`)
    for _ in 0..<1300 {raw(&w,`\n`)}
    raw(&w,`"}`)
    testing.expect_value(t,method_register(&s,{name="schema",result_schema=string(serial.writer_bytes(&w)),handler=mcp_json_handler,user=&text,flags={.Core}}),Register_Error.None)
    s.scratch.arena.data=saved_scratch[:64]
    context.allocator=mem.nil_allocator()
    serial.writer_reset(&s.out)
    testing.expect(t,process(&s,`{"jsonrpc":"2.0","id":12,"method":"tools/list"}`,.Mcp))
    context.allocator=saved_allocator
    s.scratch.arena.data=saved_scratch
    reply=parse_json(t,string(serial.writer_bytes(&s.out)))
    testing.expect_value(t,integer(at(reply,"id")),12)
    testing.expect_value(t,integer(at(reply,"error","code")),INTERNAL_ERROR)
    testing.expect_value(t,s.stats.scratch_failures,2)
    context.allocator=mem.nil_allocator()
    serial.writer_reset(&s.out)
    testing.expect(t,process(&s,`{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"schema"}}`,.Mcp))
    context.allocator=saved_allocator
    reply=parse_json(t,string(serial.writer_bytes(&s.out)))
    testing.expect(t,is_bool(at(reply,"result","isError"),false))
    testing.expect_value(t,integer(at(reply,"result","structuredContent","value")),42)
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
    testing.expect_value(t,integer(at(reply,"result","structuredContent","sum")),5)
    reply=mcp(t,&f,`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rare_sum","arguments":{"a":1,"b":1}}}`)
    testing.expect_value(t,integer(at(reply,"result","structuredContent","sum")),2)
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
