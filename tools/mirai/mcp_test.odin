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
    reply,answered:=mcp_no_editor("C:/games/mine",`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}`)
    testing.expect(t,answered)
    result:=json_member(reply,"result")
    testing.expect_value(t,json_member(reply,"id"),"1")
    testing.expect_value(t,json_member(result,"protocolVersion"),`"2025-03-26"`)
    testing.expect_value(t,json_member(json_member(json_member(result,"capabilities"),"tools"),"listChanged"),"true")
    instructions,_:=json_string(json_member(result,"instructions"))
    testing.expect(t,strings.contains(instructions,start),instructions)

    reply,answered=mcp_no_editor("C:/games/mine",`{"jsonrpc":"2.0","id":"l","method":"tools/list"}`)
    testing.expect(t,answered)
    tools,_:=json_elements(json_member(json_member(reply,"result"),"tools"))
    if testing.expect_value(t,len(tools),1) {
        name,_:=json_string(json_member(tools[0],"name"))
        testing.expect_value(t,name,api.MCP_CALL_TOOL)
        description,_:=json_string(json_member(tools[0],"description"))
        testing.expect(t,strings.contains(description,start),description)
        testing.expect(t,api.json_valid(context.allocator,json_member(tools[0],"inputSchema")))
    }

    reply,answered=mcp_no_editor("C:/games/mine",`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"scene_inspect"}}`)
    testing.expect(t,answered)
    testing.expect_value(t,json_member(json_member(reply,"result"),"isError"),"true")
    content,_:=json_elements(json_member(json_member(reply,"result"),"content"))
    text,_:=json_string(json_member(content[0],"text"))
    message,_:=json_string(json_member(json_member(text,"error"),"message"))
    testing.expect(t,strings.contains(message,start),message)

    for other in ([]string{`{"jsonrpc":"2.0","id":2,"method":"ping"}`,`{"jsonrpc":"2.0","method":"notifications/initialized"}`,`not json`}) {
        _,answered=mcp_no_editor("C:/games/mine",other)
        testing.expect(t,!answered,other)
    }
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
    testing.expect_value(t,mcp_editor(connection),Mcp_Editor{})
    testing.expect_value(t,connection_port(connection),0)

    file:=project.path(folder,api.PORT_FILE,allocator=context.temp_allocator)
    write :: proc(t:^testing.T,file:string,port:int,loc:=#caller_location) {
        text:=fmt.tprintf(`{{"port":%d,"pid":%d}}`,port,os.get_pid())
        testing.expect(t,os.write_entire_file(file,transmute([]u8)text)==nil,loc=loc)
    }
    write(t,file,7951)
    first:=mcp_editor(connection)
    testing.expect_value(t,first,Mcp_Editor{7951,os.get_pid()})
    write(t,file,7952)
    moved:=mcp_editor(connection)
    testing.expect_value(t,moved.port,7952)

    testing.expect(t,!mcp_list_stale(false,{},first),"nothing to change before the client asks for a list")
    testing.expect(t,mcp_list_stale(true,{},first),"the editor started")
    testing.expect(t,mcp_list_stale(true,first,moved),"the editor changed port")
    testing.expect(t,mcp_list_stale(true,first,{7951,first.pid+1}),"another process on the same port")
    testing.expect(t,!mcp_list_stale(true,first,first),"told once")
    testing.expect(t,!mcp_list_stale(true,first,{}),"an editor that closed changes no list until another one opens")

    editor_said:=`{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"tools":{"listChanged":false}}}}`
    testing.expect_value(t,json_member(json_member(json_member(mcp_lists_changes(editor_said),"result"),"capabilities"),"tools"),`{"listChanged":true}`)

    without,_:=connection_args({"scene.inspect"},{})
    testing.expect_value(t,without.project,"")
    testing.expect(t,mcp_editor(without).port==without.port && mcp_editor(without).pid==0,"without --project nothing is read")
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
}
