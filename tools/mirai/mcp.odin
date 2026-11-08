package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "mirai:editor/api"
import "mirai:std/serial"

MCP_MAX_LINE :: 16<<20
MCP_USAGE :: "mcp [--project P|--port N] [--timeout S] [--plugins A,B|*] [--client NAME]"
MCP_PROJECT_POLL :: 1 // seconds between readings of the port file of --project
MCP_NO_EDITOR_SCHEMA :: `{"type":"object","properties":{"method":{"type":"string"},"params":{"type":"object"}},"additionalProperties":true}`
MCP_DOCS_TOOL :: "docs"
MCP_DOCS_ENTRY :: `{"name":"docs","description":"Reads the game documentation of this engine, with or without an editor. Without arguments, the index of topics; with topic, that topic; with section too, one heading of it by its anchor or one of its task files (a link core/wiring.md is topic core, section wiring).","inputSchema":{"type":"object","properties":{"topic":{"type":"string"},"section":{"type":"string"}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"openWorldHint":false}}`

// An editor of a project, as its port file names it; zero when it has none.
Mcp_Editor :: struct {port,pid:int}

// stdout is written by the messages and by the watcher of the editor.
Mcp_Bridge :: struct {
    root:string,
    connection:Connection,
    lock:sync.Mutex,
    unlisted:bool, // the client holds an empty list of tools
    plugins:string, // whose tools the client is given besides those of the editor: names separated by commas, or *
    client:string,  // X-Mirai-Client: --client, the name its initialize gives, or that of the shell it runs in
    named:bool,     // by --client
    asked:bool,        // with --project: the client has asked for the list of tools
    listed:Mcp_Editor, // with --project: the editor that list came from; zero: none answered it
}

// MCP over stdio, one JSON message per line, forwarded to the editor.
cmd_mcp :: proc(root:string,args:[]string) -> int {
    connection,ok:=connection_args(args,agent_environment())
    plugins:=""
    rest:=connection.rest[:]
    if ok && len(rest)==2 && rest[0]=="--plugins" && rest[1]!="" {plugins,rest=rest[1],rest[2:]}
    if !ok || len(rest)>0 {
        fmt.eprintfln("Usage: mirai %s",MCP_USAGE)
        return 2
    }
    bridge:=Mcp_Bridge{root=root,connection=connection,plugins=plugins,client=connection.client}
    bridge.named=bridge.client!=""
    if !bridge.named {bridge.client=client_environment()}
    thread.create_and_start_with_poly_data(&bridge,mcp_watch,self_cleanup=true)
    pending:[dynamic]u8
    chunk:[64*1024]u8
    for {
        n,error:=os.read(os.stdin,chunk[:])
        if n>0 {append(&pending,..chunk[:n])}
        for {
            end:=-1
            for c,i in pending {if c=='\n' {end=i;break}}
            if end<0 {break}
            mcp_message(&bridge,string(pending[:end]))
            remove_range(&pending,0,end+1)
        }
        if len(pending)>MCP_MAX_LINE {
            fmt.eprintln("mirai mcp: a message exceeds",MCP_MAX_LINE,"bytes")
            clear(&pending)
        }
        if error!=nil || n==0 {break}
    }
    if len(pending)>0 {mcp_message(&bridge,string(pending[:]))}
    return 0
}

mcp_message :: proc(bridge:^Mcp_Bridge,line:string) {
    defer free_all(context.temp_allocator)
    text:=line
    for len(text)>0 && (text[len(text)-1]=='\r' || text[len(text)-1]==' ') {text=text[:len(text)-1]}
    for len(text)>0 && (text[0]==' ' || text[0]=='\t') {text=text[1:]}
    if text=="" {return}
    if name:=api.bridge_client_name(context.temp_allocator,text);name!="" && !bridge.named {bridge.client=strings.clone(name)}
    c:=bridge.connection
    editor:=mcp_editor(c)
    method,_:=json_string(json_member(text,"method"))
    reply:string
    answer,unlisted:bool
    if method=="tools/call" {reply,answer=mcp_docs_call(bridge.root,text)}
    if !answer && c.project!="" && editor.port==0 {reply,answer=mcp_no_editor(c.project,text)}
    if !answer {
        reply,answer,unlisted=api.bridge_handle(editor.port,c.timeout_ms,text,context.temp_allocator,connection_task(c,editor.port),bridge.plugins,bridge.client)
        if unlisted && c.project!="" {reply,_=mcp_no_editor(c.project,text)}
        if c.project!="" && method=="initialize" {reply=mcp_lists_changes(reply)}
    }
    if !answer {return}
    switch method {
    case "initialize": reply=mcp_docs_instructions(bridge.root,reply)
    case "tools/list": reply=mcp_docs_listed(reply,text)
    }
    sync.guard(&bridge.lock)
    if unlisted {bridge.unlisted=true}
    if method=="tools/list" {bridge.asked,bridge.listed=true,unlisted?Mcp_Editor{}:editor}
    os.write_string(os.stdout,reply)
    os.write_string(os.stdout,"\n")
}

// The editor messages go to now: with --project, the one its port file names.
mcp_editor :: proc(connection:Connection) -> Mcp_Editor {
    if connection.project=="" {return {port=connection.port}}
    file,alive:=session_find(connection.project)
    return alive?Mcp_Editor{file.port,file.pid}:Mcp_Editor{}
}

// An editor that answers an initialize says its tools do not change; with
// --project they do, as the editor starts or restarts.
mcp_lists_changes :: proc(reply:string) -> string {
    changed,_:=strings.replace(reply,`"listChanged":false`,`"listChanged":true`,1,context.temp_allocator)
    return changed
}

// The answer to a call of the docs tool, which never reaches an editor;
// answered is false for any other tool.
mcp_docs_call :: proc(root,message:string) -> (reply:string,answered:bool) {
    id:=json_member(message,"id")
    params:=json_member(message,"params")
    name,_:=json_string(json_member(params,"name"))
    if id=="" || name!=MCP_DOCS_TOOL {return}
    arguments:=json_member(params,"arguments")
    values:[2]string
    text:=""
    ok:=true
    for field,i in ([2]string{"topic","section"}) {
        value:=json_member(arguments,field)
        if value=="" || value=="null" {continue}
        if values[i],ok=json_string(value);!ok {text=fmt.tprintf("%s must be a string",field);break}
    }
    if ok {text,ok=docs_answer(root,values[0],values[1])}
    return fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":{{"content":[{{"type":"text","text":%s}}],"isError":%s}}}}`,id,serial.text_quote(text),ok?"false":"true"),true
}

// The answer to a tools/list with the docs tool first; on the first page only.
mcp_docs_listed :: proc(reply,message:string) -> string {
    if json_member(json_member(message,"params"),"cursor")!="" {return reply}
    KEY :: `"tools":[`
    at:=strings.index(reply,KEY)+len(KEY)
    if at<len(KEY) || at>=len(reply) {return reply}
    return strings.concatenate({reply[:at],MCP_DOCS_ENTRY,reply[at]==']'?"":",",reply[at:]},context.temp_allocator)
}

// The answer to an initialize with the index of the documentation after what
// it says of the editor.
mcp_docs_instructions :: proc(root,reply:string) -> string {
    quoted:=json_member(json_member(reply,"result"),"instructions")
    compact:=docs_compact(root)
    if quoted=="" || compact=="" {return reply}
    instructions,_:=json_string(quoted)
    KEY :: `"instructions":`
    added:=serial.text_quote(strings.trim_space(fmt.tprintf("%s\n\n%s",instructions,compact)))
    changed,_:=strings.replace(reply,strings.concatenate({KEY,quoted},context.temp_allocator),strings.concatenate({KEY,added},context.temp_allocator),1,context.temp_allocator)
    return changed
}

// What mirai mcp --project answers itself while its project has no editor:
// one tool, so that a client has something to call, and an error on calling
// it that says how to start the editor. answered is false for what
// api.bridge_handle answers the same with or without a project.
mcp_no_editor :: proc(project,message:string) -> (reply:string,answered:bool) {
    id:=json_member(message,"id")
    if id=="" {return}
    method,_:=json_string(json_member(message,"method"))
    hint:=no_editor_text(project)
    switch method {
    case "initialize":
        requested,_:=json_string(json_member(json_member(message,"params"),"protocolVersion"))
        w:serial.Writer
        serial.writer_init(&w,512,context.temp_allocator)
        api.mcp_initialize_write(&w,requested,"mirai","1",fmt.tprintf("%s. The tools are listed when it runs.",hint),true)
        return fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":%s}}`,id,string(serial.writer_bytes(&w))),true
    case "tools/list":
        description:=serial.text_quote(fmt.tprintf("%s. Calling this says so; the tools of the editor are listed when it runs.",hint))
        return fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":{{"tools":[{{"name":"%s","description":%s,"inputSchema":%s}}]}}}}`,id,api.MCP_CALL_TOOL,description,MCP_NO_EDITOR_SCHEMA),true
    case "tools/call":
        text:=serial.text_quote(api.error_text({api.UNREACHABLE,hint,""},context.temp_allocator))
        return fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":{{"content":[{{"type":"text","text":%s}}],"isError":true}}}}`,id,text),true
    }
    return
}

// While the client holds an empty list, tries the editor every
// BRIDGE_RETRY seconds and tells the client when it answers.
mcp_watch :: proc(bridge:^Mcp_Bridge) {
    if bridge.connection.project!="" {
        mcp_watch_project(bridge)
        return
    }
    for {
        time.sleep(api.BRIDGE_RETRY*time.Second)
        sync.lock(&bridge.lock)
        unlisted:=bridge.unlisted
        sync.unlock(&bridge.lock)
        reachable:=unlisted && api.bridge_reachable(connection_port(bridge.connection),context.temp_allocator)
        free_all(context.temp_allocator)
        if !reachable {continue}
        sync.guard(&bridge.lock)
        bridge.unlisted=false
        os.write_string(os.stdout,api.BRIDGE_LIST_CHANGED+"\n")
    }
}

// Whether the list the client holds came from another editor than the one
// there is now: it started, restarted or changed port. An editor that closes
// changes nothing until another one opens.
mcp_list_stale :: proc(asked:bool,listed,now:Mcp_Editor) -> bool {
    return asked && now.port!=0 && now!=listed
}

// Tells the client when the editor of --project differs from the one its
// list came from, once that editor answers.
mcp_watch_project :: proc(bridge:^Mcp_Bridge) {
    for {
        time.sleep(MCP_PROJECT_POLL*time.Second)
        editor:=mcp_editor(bridge.connection)
        sync.lock(&bridge.lock)
        stale:=mcp_list_stale(bridge.asked,bridge.listed,editor)
        sync.unlock(&bridge.lock)
        reachable:=stale && api.bridge_reachable(editor.port,context.temp_allocator)
        free_all(context.temp_allocator)
        if !reachable {continue}
        sync.guard(&bridge.lock)
        bridge.listed=editor
        os.write_string(os.stdout,api.BRIDGE_LIST_CHANGED+"\n")
    }
}
