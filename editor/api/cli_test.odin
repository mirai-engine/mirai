package api

import "core:encoding/json"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:std/base"
import "mirai:std/subprocess"

Tool :: struct {
    exe,root:string,
}

// Builds tools/mirai as the repository does and returns the executable.
tool_build :: proc(t:^testing.T) -> (tool:Tool,ok:bool) {
    root,_:=filepath.join({#directory,"..",".."},context.temp_allocator)
    tool.root=root
    out_dir,_:=filepath.join({root,"bin","tests"},context.temp_allocator)
    os.make_directory_all(out_dir)
    tool.exe,_=filepath.join({out_dir,"api_mirai"+EXE},context.temp_allocator)
    odin,found:=os.lookup_env("MIRAI_ODIN",context.temp_allocator)
    if !found || odin=="" {odin="odin"}
    collection:=strings.concatenate({"-collection:mirai=",root},context.temp_allocator)
    output:=strings.concatenate({"-out:",tool.exe},context.temp_allocator)
    state,stdout,stderr,err:=subprocess.exec({working_dir=root,command={odin,"build","tools/mirai",collection,"-ignore-unknown-attributes","-o:minimal",output}},context.temp_allocator)
    testing.expectf(t,err==nil && state.exit_code==0,"building tools/mirai failed (%v): %s%s",err,string(stdout),string(stderr))
    return tool,err==nil && state.exit_code==0
}

EXE :: ".exe" when ODIN_OS==.Windows else ""

// Runs the tool to the end. stdin: what it reads, or nothing.
run_tool :: proc(tool:Tool,stdin:string,args:..string) -> (code:int,stdout,stderr:string) {
    command:[dynamic]string
    command.allocator=context.temp_allocator
    append(&command,tool.exe)
    append(&command,..args)
    input:^os.File
    if stdin!="" {
        reader,writer,error:=os.pipe()
        if error!=nil {return -1,"",""}
        os.write_string(writer,stdin)
        os.close(writer)
        input=reader
    }
    defer if input!=nil {os.close(input)}
    state,out,err_bytes,err:=subprocess.exec({working_dir=tool.root,command=command[:],stdin=input},context.temp_allocator)
    if err!=nil {return -1,"",""}
    return state.exit_code,string(out),string(err_bytes)
}

Session :: struct {
    process:os.Process,
    stdin,stdout,stderr:^os.File,
    pending:[dynamic]u8,
}

session_start :: proc(tool:Tool,args:..string) -> (s:Session,ok:bool) {
    stdin_r,stdin_w,out_r,out_w,err_r,err_w:^os.File
    error:os.Error
    stdin_r,stdin_w,error=os.pipe();if error!=nil {return}
    out_r,out_w,error=os.pipe();if error!=nil {return}
    err_r,err_w,error=os.pipe();if error!=nil {return}
    command:[dynamic]string
    command.allocator=context.temp_allocator
    append(&command,tool.exe)
    append(&command,..args)
    s.process,error=subprocess.start({working_dir=tool.root,command=command[:],stdin=stdin_r,stdout=out_w,stderr=err_w})
    os.close(stdin_r);os.close(out_w);os.close(err_w)
    s.stdin,s.stdout,s.stderr=stdin_w,out_r,err_r
    s.pending.allocator=context.temp_allocator
    return s,error==nil
}

session_send :: proc(s:^Session,line:string) {
    os.write_string(s.stdin,line)
    os.write_string(s.stdin,"\n")
}

// The next line the tool wrote to stdout; "" when none came in time.
session_read :: proc(s:^Session,wait:=10*time.Second) -> string {
    deadline:=time.tick_now()
    chunk:[4096]u8
    for {
        for c,i in s.pending {
            if c=='\n' {
                line:=strings.clone(string(s.pending[:i]),context.temp_allocator)
                remove_range(&s.pending,0,i+1)
                return line
            }
        }
        if time.tick_diff(deadline,time.tick_now())>wait {return ""}
        if has,_:=os.pipe_has_data(s.stdout);has {
            n,_:=os.read(s.stdout,chunk[:])
            append(&s.pending,..chunk[:n])
        } else {
            time.sleep(2*time.Millisecond)
        }
    }
}

session_stop :: proc(s:^Session) {
    _=os.process_kill(s.process)
    _,_=os.process_wait(s.process)
    os.close(s.stdin);os.close(s.stdout);os.close(s.stderr)
}

@(test)
the_rpc_and_mcp_commands_drive_the_server :: proc(t:^testing.T) {
    tool,built:=tool_build(t)
    if !built {return}
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    port:=tprint_int(server_port(&f.server))
    rpc_command_cases(t,tool,&f,port)
    mcp_session_cases(t,tool,port)
    editor_not_running_cases(t,tool)
}

rpc_command_cases :: proc(t:^testing.T,tool:Tool,f:^Fixture,port:string) {
    code,out,err:=run_tool(tool,"","rpc","test.add",`{"a":2,"b":3}`,"--port",port)
    testing.expect_value(t,code,0)
    testing.expect_value(t,out,"{\n  \"sum\": 5\n}\n")
    testing.expect_value(t,err,"")
    code,out,_=run_tool(tool,"","rpc","test.shapes",`{"position":[1,2,3],"flags":["Ice"]}`,"--port",port)
    testing.expect_value(t,code,0)
    testing.expect(t,strings.contains(out,"\"position\": [\n    1,\n    2,\n    3\n  ]"),out)
    code,out,_=run_tool(tool,"","rpc","engine.describe",`{"methods":["test.add"]}`,"--port",port,"--timeout","5")
    testing.expect_value(t,code,0)
    testing.expect(t,strings.contains(out,`"tool": "test_add"`),out)
    code,out,err=run_tool(tool,"","rpc","test.fail","--port",port)
    testing.expect_value(t,code,1)
    testing.expect_value(t,out,"")
    error:=parse_json(t,err)
    testing.expect_value(t,integer(at(error,"error","code")),SERVER_ERROR)
    testing.expect_value(t,string_of(at(error,"error","message")),"test failure")
    testing.expect_value(t,integer(at(error,"error","data","attempt")),4)
    code,_,err=run_tool(tool,"","rpc","test.add",`{"a":1}`,"--port",port)
    testing.expect_value(t,code,1)
    testing.expect_value(t,integer(at(parse_json(t,err),"error","code")),INVALID_PARAMS)
    testing.expect(t,strings.contains(err,"b is required"),err)
    code,_,err=run_tool(tool,"","rpc","missing.method","--port",port)
    testing.expect_value(t,code,1)
    testing.expect_value(t,integer(at(parse_json(t,err),"error","code")),METHOD_NOT_FOUND)
    code,_,err=run_tool(tool,"","rpc","test.add","[1]","--port",port)
    testing.expect_value(t,code,1)
    testing.expect_value(t,integer(at(parse_json(t,err),"error","code")),INVALID_PARAMS)
    code,_,err=run_tool(tool,"","rpc","test.add","{not json","--port",port)
    testing.expect_value(t,code,1)
    testing.expect_value(t,integer(at(parse_json(t,err),"error","code")),INVALID_PARAMS)
    for usage in ([][]string{{"rpc"},{"rpc","a","{}","c"},{"rpc","test.add","--port"},{"rpc","test.add","--port","abc"},{"rpc","test.add","--port","70000"},{"mcp","extra"}}) {
        args:[dynamic]string
        args.allocator=context.temp_allocator
        append(&args,..usage)
        code,_,err=run_tool(tool,"",..args[:])
        testing.expectf(t,code==2 && strings.contains(err,"Usage:"),"%v: %d %s",usage,code,err)
    }
    code,out,err=run_tool(tool,"{\"a\": 20,\n \"b\": 22}\n","rpc","test.add","-","--port",port)
    testing.expect_value(t,err,"")
    testing.expect_value(t,code,0)
    testing.expect_value(t,out,"{\n  \"sum\": 42\n}\n")
    rpc_result_cases(t,tool,port)
    rpc_batch_cases(t,tool,f,port)
}

// --batch sends the lines of a file or of stdin as the calls of one batch: a
// call can name a result of the one before it, and the first that fails says
// which one it is and what the ones before it answered.
rpc_batch_cases :: proc(t:^testing.T,tool:Tool,f:^Fixture,port:string) {
    folder:=base.test_folder(t,"batch")
    if folder=="" {return}
    file:=strings.concatenate({folder,"/calls.jsonl"},context.temp_allocator)
    write :: proc(file,text:string) {_=os.write_entire_file(file,transmute([]u8)text)}
    write(file,`{"method":"test.add","params":{"a":2,"b":3}}`+"\n"+`{"method":"test.add","params":{"a":"$0.sum","b":10}}`+"\n"+`{"method":"test.shapes","params":{"position":["$0.sum",0,0]}}`+"\n")
    code,out,err:=run_tool(tool,"","rpc","--batch",file,"--port",port)
    testing.expectf(t,code==0,"%d %s %s",code,out,err)
    answers:=parse_json(t,out)
    testing.expect_value(t,integer(at(answers,"results",1,"result","sum")),15)
    testing.expect_value(t,integer(at(answers,"results",2,"result","position",0)),5)
    connections:=f.server.stats.connections
    code,out,err=run_tool(tool,`{"method":"test.add","params":{"a":4,"b":5}}`+"\n\n"+`{"method":"missing.method"}`+"\n"+`{"method":"test.add"}`+"\n","rpc","--batch","-","--port",port)
    testing.expectf(t,code==1,"%d %s %s",code,out,err)
    failed:=parse_json(t,err)
    testing.expect(t,strings.contains(err,"calls[1] missing.method: "),err)
    testing.expect_value(t,integer(at(failed,"error","data","failed")),1)
    testing.expect_value(t,integer(at(failed,"error","data","results",0,"result","sum")),9)
    testing.expect_value(t,f.server.stats.connections-connections,1)
    code,out,err=run_tool(tool,"not a call\n","rpc","--batch","-","--port",port)
    testing.expect_value(t,code,1)
    testing.expect(t,strings.contains(err,"line 1 is not a call"),err)
    write(file,`{"method":"test.add","params":{"a":2,"b":3}}`+"\n"+`{"method":"test.add","params":{"a":"$0.total","b":1}}`+"\n")
    code,out,err=run_tool(tool,"","rpc","--batch",file,"--port",port)
    testing.expect_value(t,code,1)
    testing.expect(t,strings.contains(err,"$0.total") && strings.contains(err,"calls[1] test.add"),err)
    write(file,`{"method":"test.add","params":{"a":"$1.sum","b":1}}`+"\n")
    code,out,err=run_tool(tool,"","rpc","--batch",file,"--port",port)
    testing.expect_value(t,code,1)
    testing.expect(t,strings.contains(err,"$1.sum: the batch has 0 results"),err)
    code,out,err=run_tool(tool,`{"method":"test.add","params":{"a":1,"b":1}}`+"\n","rpc","batch",`{"transaction":true,"calls":[{"method":"test.add","params":{"a":1,"b":1}}]}`,"--port",port)
    testing.expect(t,code==1 && strings.contains(err,"transaction is of a server that edits a scene"),err)
}

// --select, --wait-until, describe and the hints of the errors.
rpc_result_cases :: proc(t:^testing.T,tool:Tool,port:string) {
    code,out,err:=run_tool(tool,"","rpc","test.add",`{"a":2,"b":3}`,"--port",port,"--select","sum")
    testing.expectf(t,code==0 && out=="5\n","%d %q %s",code,out,err)
    code,out,err=run_tool(tool,"","rpc","test.shapes",`{"position":[1,2,3],"flags":["Ice"]}`,"--select","position[-1],flags","--port",port)
    testing.expectf(t,code==0 && out=="3\n[\n  \"Ice\"\n]\n","%d %q %s",code,out,err)
    code,out,err=run_tool(tool,"","rpc","test.add",`{"a":2,"b":3}`,"--port",port,"--select","total")
    testing.expectf(t,code==0 && out=="","the call ran and has nothing to print: %d %q %s",code,out,err)
    testing.expect(t,strings.contains(err,"has no 'total'; it has: sum") && strings.count(err,"\n")==1,err)
    code,out,err=run_tool(tool,"","rpc","test.add",`{"a":2,"b":3}`,"--port",port,"--select","total,sum")
    testing.expectf(t,code==0 && out=="5\n","only what it found: %d %q %s",code,out,err)
    code,_,err=run_tool(tool,"","rpc","test.add",`{"a":2,"b":3}`,"--port",port,"--select","a..b")
    testing.expect_value(t,code,1)
    testing.expect_value(t,integer(at(parse_json(t,err),"error","code")),INVALID_PARAMS)
    testing.expect(t,strings.contains(err,"a..b"),err)
    code,out,err=run_tool(tool,"","rpc","test.add","a=2","b=3","--port",port,"--select","sum")
    testing.expectf(t,code==0 && out=="5\n","key=value arguments: %d %q %s",code,out,err)
    code,out,err=run_tool(tool,"","rpc","test.add",`{"a":2,"b":3}`,"--port",port,"--wait-until","sum>=5","--select","sum")
    testing.expectf(t,code==0 && out=="5\n","%d %q %s",code,out,err)
    code,_,err=run_tool(tool,"","rpc","test.echo","text=x","--port",port,"--wait-until","text=x")
    testing.expectf(t,code==1 && integer(at(parse_json(t,err),"error","code"))==INVALID_PARAMS && strings.contains(err,"test.echo changes things"),"a wait on a method that is not read-only is the refusal of the server: %d %s",code,err)
    code,out,err=run_tool(tool,"","rpc","test.add",`{"a":2,"b":3}`,"--port",port,"--wait-until","sum=6","--timeout","1")
    testing.expect_value(t,code,1)
    testing.expect_value(t,out,"")
    waited:=parse_json(t,err)
    testing.expect_value(t,integer(at(waited,"error","code")),TIMEOUT)
    testing.expect(t,strings.contains(string_of(at(waited,"error","message")),"sum is 5"),err)
    testing.expect_value(t,integer(at(waited,"error","data","value")),5)
    rpc_restart_case(t,tool)
    code,out,err=run_tool(tool,"","rpc","describe","test.echo","--port",port)
    testing.expectf(t,code==0,"%d %s",code,err)
    for line in ([]string{"test.echo (core)\n","    times: integer 1..4, default 1\n","  example: mirai rpc test.echo text=x\n","    text: string up to 160\n"}) {
        testing.expectf(t,strings.contains(out,line),"%q in:\n%s",line,out)
    }
    code,out,err=run_tool(tool,"","rpc","describe","test.echo","test.add","--port",port)
    testing.expectf(t,code==0 && strings.contains(out,"test.echo (core)\n") && strings.contains(out,"example: mirai rpc test.add"),"%d %s %s",code,out,err)
    code,out,_=run_tool(tool,"","rpc","describe","--port",port)
    testing.expectf(t,code==0 && strings.contains(out,"Adds two integers") && !strings.contains(out,"example"),"%d %s",code,out)
    code,_,err=run_tool(tool,"","rpc","describe","scene.","--port",port)
    testing.expect_value(t,code,1)
    testing.expect(t,strings.contains(err,"no method starts with 'scene.'"),err)
    code,_,err=run_tool(tool,"","rpc","test.ad","--port",port)
    testing.expect_value(t,code,1)
    testing.expect_value(t,integer(at(parse_json(t,err),"error","code")),METHOD_NOT_FOUND)
    testing.expect(t,strings.contains(err,"similar: test.add"),err)
}

@(private="file")
Restarting_Editor :: struct {listener:net.TCP_Socket,asked:bool}

// Closes its first connection, as an editor that restarts during a wait, and
// answers the second with what the server keeps of a selection.
@(private="file")
restarting_editor_run :: proc(worker:^thread.Thread) {
    editor:=(^Restarting_Editor)(worker.data)
    read :: proc(socket:net.TCP_Socket) -> string {
        data:[dynamic]u8
        data.allocator=context.temp_allocator
        chunk:[4096]u8
        for !strings.has_suffix(string(data[:]),"}") {
            n,err:=net.recv_tcp(socket,chunk[:])
            if err!=nil || n==0 {break}
            append(&data,..chunk[:n])
        }
        return string(data[:])
    }
    first,_,first_error:=net.accept_tcp(editor.listener)
    if first_error!=nil {return}
    read(first)
    net.close(first)
    second,_,second_error:=net.accept_tcp(editor.listener)
    if second_error!=nil {return}
    defer net.close(second)
    request:=read(second)
    editor.asked=strings.contains(request,`"_wait_until":"a=1"`) && strings.contains(request,`"_select":"a"`)
    body:=`{"jsonrpc":"2.0","id":2,"result":{"a":1}}`
    net.send_tcp(second,transmute([]u8)strings.concatenate({"HTTP/1.1 200 OK\r\nContent-Length: ",tprint_int(len(body)),"\r\nConnection: close\r\n\r\n",body},context.temp_allocator))
}

// The server does the wait; the client only calls again when its editor restarts.
rpc_restart_case :: proc(t:^testing.T,tool:Tool) {
    listener,listen_error:=net.listen_tcp({address=net.IP4_Loopback,port=0},2)
    if !testing.expect(t,listen_error==nil) {return}
    defer net.close(listener)
    endpoint,_:=net.bound_endpoint(listener)
    editor:=Restarting_Editor{listener=listener}
    worker:=thread.create(restarting_editor_run)
    worker.data=&editor
    thread.start(worker)
    defer thread.destroy(worker)
    code,out,err:=run_tool(tool,"","rpc","test.add","--port",tprint_int(endpoint.port),"--wait-until","a=1","--select","a","--timeout","20")
    thread.join(worker)
    testing.expectf(t,code==0 && out=="1\n","%d %q %s",code,out,err)
    testing.expect(t,editor.asked,"the call carries the reserved params to the server")
}

mcp_session_cases :: proc(t:^testing.T,tool:Tool,port:string) {
    s,ok:=session_start(tool,"mcp","--port",port)
    if !ok {testing.expect(t,false,"the mcp command did not start");return}
    defer session_stop(&s)
    session_send(&s,`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}`)
    reply:=parse_json(t,session_read(&s))
    testing.expect_value(t,integer(at(reply,"id")),1)
    testing.expect_value(t,string_of(at(reply,"result","protocolVersion")),"2025-06-18")
    session_send(&s,`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
    session_send(&s,`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
    reply=parse_json(t,session_read(&s))
    testing.expect_value(t,integer(at(reply,"id")),2)
    testing.expect_value(t,len(at(reply,"result","tools").(json.Array)),9)
    session_send(&s,`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"test_add","arguments":{"a":40,"b":2}}}`)
    reply=parse_json(t,session_read(&s))
    testing.expect_value(t,integer(at(reply,"id")),3)
    testing.expect_value(t,integer(at(tool_text(t,reply),"sum")),42)
    session_send(&s,"  {\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"test_fail\",\"arguments\":{}}}\r")
    reply=parse_json(t,session_read(&s))
    testing.expect(t,is_bool(at(reply,"result","isError"),true),"a failing tool is a tool error")
    testing.expect_value(t,integer(at(tool_text(t,reply),"error","code")),SERVER_ERROR)
    session_send(&s,"")
    session_send(&s,`{"jsonrpc":"2.0","id":5,"method":"ping"}`)
    reply=parse_json(t,session_read(&s))
    testing.expect_value(t,integer(at(reply,"id")),5)
    session_send(&s,`not json`)
    reply=parse_json(t,session_read(&s))
    testing.expect_value(t,integer(at(reply,"error","code")),PARSE_ERROR)
    session_send(&s,`{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope"}}`)
    reply=parse_json(t,session_read(&s))
    testing.expect_value(t,integer(at(reply,"id")),6)
    testing.expect_value(t,integer(at(reply,"error","code")),INVALID_PARAMS)
}

editor_not_running_cases :: proc(t:^testing.T,tool:Tool) {
    code,out,err:=run_tool(tool,"","rpc","test.add","{}","--port","1")
    testing.expect_value(t,code,1)
    testing.expect_value(t,out,"")
    testing.expect_value(t,integer(at(parse_json(t,err),"error","code")),UNREACHABLE)
    testing.expect(t,strings.contains(err,"cannot reach the Mirai editor at 127.0.0.1:1"),err)
    s,ok:=session_start(tool,"mcp","--port","1")
    if !ok {testing.expect(t,false,"the mcp command did not start");return}
    defer session_stop(&s)
    session_send(&s,`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}`)
    reply:=parse_json(t,session_read(&s))
    testing.expect_value(t,string_of(at(reply,"result","protocolVersion")),"2025-03-26")
    testing.expect_value(t,string_of(at(reply,"result","serverInfo","name")),"mirai")
    testing.expect(t,strings.contains(string_of(at(reply,"result","instructions")),"cannot reach the Mirai editor"),"initialize says where the editor is not")
    testing.expect(t,is_bool(at(reply,"result","capabilities","tools","listChanged"),true),"the client is told when the editor runs")
    session_send(&s,`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
    session_send(&s,`{"jsonrpc":"2.0","id":2,"method":"ping"}`)
    reply=parse_json(t,session_read(&s))
    testing.expect_value(t,integer(at(reply,"id")),2)
    testing.expect(t,at(reply,"result")!=nil,"ping is answered without the editor")
    session_send(&s,`{"jsonrpc":"2.0","id":3,"method":"tools/list"}`)
    reply=parse_json(t,session_read(&s))
    testing.expect_value(t,integer(at(reply,"id")),3)
    testing.expect_value(t,len(at(reply,"result","tools").(json.Array)),1) // docs, served without an editor
    session_send(&s,`{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"scene_inspect","arguments":{}}}`)
    reply=parse_json(t,session_read(&s))
    testing.expect_value(t,string_of(at(reply,"id")),"call")
    testing.expect(t,is_bool(at(reply,"result","isError"),true),"a call without the editor is a tool error")
    testing.expect_value(t,integer(at(tool_text(t,reply),"error","code")),UNREACHABLE)
}
