package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:editor/api"
import "mirai:project"

// Without an editor a project still lists something to call, and calling it
// says how to start that project's editor.
@(test)
a_project_without_an_editor_says_how_to_start_one :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    start:="mirai session start C:/games/mine"
    absent:=mcp_absent("",Connection{project="C:/games/mine"},{},{api.UNREACHABLE,no_editor_text("C:/games/mine"),""})
    reply,answered:=api.bridge_absent(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}`,absent,context.allocator)
    testing.expect(t,answered)
    result:=api.json_member(reply,"result")
    testing.expect_value(t,api.json_member(reply,"id"),"1")
    testing.expect_value(t,api.json_member(result,"protocolVersion"),`"2025-03-26"`)
    testing.expect_value(t,api.json_member(api.json_member(api.json_member(result,"capabilities"),"tools"),"listChanged"),"true")
    instructions,_:=api.json_string(api.json_member(result,"instructions"))
    testing.expect(t,strings.contains(instructions,start),instructions)

    reply,answered=api.bridge_absent(`{"jsonrpc":"2.0","id":"l","method":"tools/list"}`,absent,context.allocator)
    testing.expect(t,answered)
    tools,_:=api.json_elements(api.json_member(api.json_member(reply,"result"),"tools"))
    if testing.expect_value(t,len(tools),2) {
        name,_:=api.json_string(api.json_member(tools[1],"name"))
        testing.expect_value(t,name,api.MCP_CALL_TOOL)
        description,_:=api.json_string(api.json_member(tools[1],"description"))
        testing.expect(t,strings.contains(description,start),description)
        testing.expect(t,api.json_valid(context.allocator,api.json_member(tools[1],"inputSchema")))
    }

    reply,answered=api.bridge_absent(`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"scene_inspect"}}`,absent,context.allocator)
    testing.expect(t,answered)
    testing.expect_value(t,api.json_member(api.json_member(reply,"result"),"isError"),"true")
    content,_:=api.json_elements(api.json_member(api.json_member(reply,"result"),"content"))
    text,_:=api.json_string(api.json_member(content[0],"text"))
    message,_:=api.json_string(api.json_member(api.json_member(text,"error"),"message"))
    testing.expect(t,strings.contains(message,start),message)

    reply,answered=api.bridge_absent(`{"jsonrpc":"2.0","id":2,"method":"ping"}`,absent,context.allocator)
    testing.expect(t,answered && api.json_member(reply,"result")=="{}",reply)
    _,answered=api.bridge_absent(`{"jsonrpc":"2.0","method":"notifications/initialized"}`,absent,context.allocator)
    testing.expect(t,!answered,"a notification has no answer")
}

// A tool that opens a session is told by its method: the tool itself or what call names.
@(test)
a_tools_call_says_the_method_it_runs :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    cases:=[?]struct{message,method:string}{
        {`{"method":"tools/call","params":{"name":"ai_turn_end"}}`,"ai_turn_end"},
        {`{"method":"tools/call","params":{"name":"call","arguments":{"method":"engine.shutdown"}}}`,"engine.shutdown"},
        {`{"method":"tools/call","params":{"name":"call","arguments":{}}}`,""},
    }
    for c in cases {testing.expect_value(t,mcp_tool_method(c.message),c.method)}
}

// The port comes from the file of the project, read again each time: never the
// default one, and a client is told once per editor that differs from its list.
@(test)
a_project_follows_the_editor_its_port_file_names :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=fmt.tprintf("%s/mirai-mcp-%d",os.get_env("TEMP",context.temp_allocator),os.get_pid())
    folder:=project.path(root,".mirai",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(folder)==nil)
    defer os.remove_all(root)

    connection,ok:=connection_args({"--project",root},{})
    testing.expect(t,ok && connection.project!="" && len(connection.rest)==0)
    testing.expect_value(t,connection_editor(connection),Connection_Editor{})

    file:=project.path(folder,api.PORT_FILE,allocator=context.temp_allocator)
    write :: proc(t:^testing.T,file:string,port:int,loc:=#caller_location) {
        text:=fmt.tprintf(`{{"port":%d,"pid":%d}}`,port,os.get_pid())
        testing.expect(t,os.write_entire_file(file,transmute([]u8)text)==nil,loc=loc)
    }
    write(t,file,7951)
    first:=connection_editor(connection)
    testing.expect_value(t,first,Connection_Editor{7951,os.get_pid()})
    write(t,file,7952)
    moved:=connection_editor(connection)
    testing.expect_value(t,moved.port,7952)

    testing.expect(t,!mcp_list_stale(false,{},first),"nothing to change before the client asks for a list")
    testing.expect(t,mcp_list_stale(true,{},first),"the editor started")
    testing.expect(t,mcp_list_stale(true,first,moved),"the editor changed port")
    testing.expect(t,mcp_list_stale(true,first,{7951,first.pid+1}),"another process on the same port")
    testing.expect(t,!mcp_list_stale(true,first,first),"told once")
    testing.expect(t,!mcp_list_stale(true,first,{}),"an editor that closed changes no list until another one opens")

    editor_said:=`{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"tools":{"listChanged":false}}}}`
    testing.expect_value(t,api.json_member(api.json_member(api.json_member(mcp_lists_changes(editor_said),"result"),"capabilities"),"tools"),`{"listChanged":true}`)

    without,_:=connection_args({"scene.inspect"},{})
    testing.expect_value(t,without.project,"")
    testing.expect(t,connection_editor(without).port==without.port && connection_editor(without).pid==0,"without --project nothing is read")
}

// A path of --capture or --input is one of whoever runs the command; the
// player runs in the folder of the engine.
@(test)
play_makes_the_paths_of_its_arguments_absolute :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    here:=project.path_absolute("report/x.png")
    args:=play_arguments({"--headless","--capture","report/x.png","--scene","scenes/a.scene","--input","--frames"})
    testing.expect_value(t,args[2],here)
    testing.expect_value(t,args[4],"scenes/a.scene")
    testing.expect_value(t,args[6],project.path_absolute("--frames"))
    last:=play_arguments({"--capture"})
    testing.expect_value(t,last[0],"--capture")
    testing.expect(t,play_runs_headless({"--frames","3"}) && play_runs_headless({"--headless"}),"automation and --headless run without a window")
    testing.expect(t,!play_runs_headless({}) && !play_runs_headless({"--capture","a.png","--show-window"}),"a person runs a window, and --show-window keeps it")
}
