package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/serial"

MCP_MAX_LINE :: 16<<20
MCP_USAGE :: "mcp [--project P|--port N] [--timeout S] [--plugins A,B|*] [--client NAME]"
MCP_PROJECT_POLL :: 1 // seconds between readings of the port file of --project

// stdout is written by the messages and by the watcher of the editor.
Mcp_Bridge :: struct {
    root:string,
    connection:Connection,
    lock:sync.Mutex,
    unlisted:bool, // the client holds a list without the tools of the editor
    plugins:string, // whose tools the client is given besides those of the editor: names separated by commas, or *
    client:string,  // X-Mirai-Client: --client, the name its initialize gives, or that of the shell it runs in
    named:bool,     // by --client
    asked:bool,        // with --project: the client has asked for the list of tools
    listed:Connection_Editor, // with --project: the editor that list came from; zero: none answered it
    queue:[dynamic]string,    // messages of stdio waiting for the worker
    arrived:sync.Cond,
    closed:bool,              // stdin ended
}

// MCP over stdio, one JSON message per line, forwarded to the editor.
cmd_mcp :: proc(root:string,args:[]string) -> int {
    connection,ok:=connection_args(args,agent_environment())
    plugins:=""
    rest:=connection.rest[:]
    if ok && len(rest)==2 && rest[0]=="--plugins" && rest[1]!="" {plugins,rest=rest[1],rest[2:]}
    if ok && len(rest)>0 {return argument_unknown("mcp",rest[0])}
    if !ok {
        fmt.eprintfln("Usage: mirai %s",MCP_USAGE)
        return 2
    }
    connection.root=root
    bridge:=Mcp_Bridge{root=root,connection=connection,plugins=plugins,client=connection.client}
    bridge.named=bridge.client!=""
    if !bridge.named {bridge.client=client_environment()}
    thread.create_and_start_with_poly_data(&bridge,mcp_watch,self_cleanup=true)
    worker:=thread.create_and_start_with_poly_data(&bridge,mcp_work)
    pending:[dynamic]u8
    chunk:[64*1024]u8
    for {
        n,error:=os.read(os.stdin,chunk[:])
        if n>0 {append(&pending,..chunk[:n])}
        for {
            end:=-1
            for c,i in pending {if c=='\n' {end=i;break}}
            if end<0 {break}
            mcp_arrived(&bridge,string(pending[:end]))
            remove_range(&pending,0,end+1)
        }
        if len(pending)>MCP_MAX_LINE {
            fmt.eprintln("mirai mcp: a message exceeds",MCP_MAX_LINE,"bytes")
            clear(&pending)
        }
        if error!=nil || n==0 {break}
    }
    if len(pending)>0 {mcp_arrived(&bridge,string(pending[:]))}
    sync.lock(&bridge.lock)
    bridge.closed=true
    sync.cond_signal(&bridge.arrived)
    sync.unlock(&bridge.lock)
    thread.join(worker)
    thread.destroy(worker)
    return 0
}

// A message that came on stdio: a cancellation goes to the editor at once,
// while the call it stops still holds the worker; the rest wait their turn.
mcp_arrived :: proc(bridge:^Mcp_Bridge,line:string) {
    method,_:=api.json_string(api.json_member(line,"method"))
    if method=="notifications/cancelled" {
        if port:=connection_editor(bridge.connection).port;port!=0 {
            api.client_post(port,"/mcp",line,api.WAIT_TIMEOUT_MS,context.temp_allocator)
            free_all(context.temp_allocator)
        }
        return
    }
    sync.guard(&bridge.lock)
    append(&bridge.queue,strings.clone(line))
    sync.cond_signal(&bridge.arrived)
}

// Answers the messages of stdio one after the other, as they came.
mcp_work :: proc(bridge:^Mcp_Bridge) {
    for {
        sync.lock(&bridge.lock)
        for len(bridge.queue)==0 && !bridge.closed {sync.cond_wait(&bridge.arrived,&bridge.lock)}
        if len(bridge.queue)==0 {sync.unlock(&bridge.lock);return}
        line:=pop_front(&bridge.queue)
        sync.unlock(&bridge.lock)
        mcp_message(bridge,line)
        delete(line)
    }
}

mcp_message :: proc(bridge:^Mcp_Bridge,line:string) {
    defer free_all(context.temp_allocator)
    text:=line
    for len(text)>0 && (text[len(text)-1]=='\r' || text[len(text)-1]==' ') {text=text[:len(text)-1]}
    for len(text)>0 && (text[0]==' ' || text[0]=='\t') {text=text[1:]}
    if text=="" {return}
    if name:=api.bridge_client_name(context.temp_allocator,text);name!="" && !bridge.named {bridge.client=strings.clone(name)}
    c:=bridge.connection
    method,_:=api.json_string(api.json_member(text,"method"))
    called:=method=="tools/call"?mcp_tool_method(text):""
    reply:string
    answer:bool
    failed:api.Error
    editor:Connection_Editor
    if method=="tools/call" {reply,answer=mcp_docs_call(bridge.root,text)}
    for retried:=false;!answer;retried=true {
        editor,failed=connection_ready(c,called)
        if c.project=="" || editor.port!=0 {
            watch:=connection_watch(c,editor,fmt.tprintf("mirai mcp %s",method))
            reply,answer,failed=api.bridge_handle(editor.port,c.timeout_ms,text,context.temp_allocator,connection_task(c,editor.port),bridge.plugins,bridge.client,watch,{bridge,mcp_event})
            if !retried && connection_ended(c,called,failed) {continue}
            if answer && c.project!="" && method=="initialize" {reply=mcp_lists_changes(reply)}
        }
        if failed.code!=0 {reply,answer=api.bridge_absent(text,mcp_absent(bridge.root,c,editor,failed),context.temp_allocator)}
        break
    }
    if !answer {return}
    unlisted:=failed.code!=0 && method=="tools/list"
    sync.guard(&bridge.lock)
    if unlisted {bridge.unlisted=true}
    if method=="tools/list" {bridge.asked,bridge.listed=true,unlisted?Connection_Editor{}:editor}
    os.write_string(os.stdout,reply)
    os.write_string(os.stdout,"\n")
}

// The method a tools/call runs: its tool, or the method the tool call names.
mcp_tool_method :: proc(message:string) -> string {
    params:=api.json_member(message,"params")
    name,_:=api.json_string(api.json_member(params,"name"))
    if name!=api.MCP_CALL_TOOL {return name}
    method,_:=api.json_string(api.json_member(api.json_member(params,"arguments"),"method"))
    return method
}

// An editor that answers an initialize says its tools do not change; with
// --project they do, as the editor starts or restarts.
mcp_lists_changes :: proc(reply:string) -> string {
    changed,_:=strings.replace(reply,`"listChanged":false`,`"listChanged":true`,1,context.temp_allocator)
    return changed
}

// The answer to a call of the docs tool, the same with or without an editor,
// which never reaches it; answered is false for any other tool.
mcp_docs_call :: proc(root,message:string) -> (reply:string,answered:bool) {
    id:=api.json_member(message,"id")
    params:=api.json_member(message,"params")
    name,_:=api.json_string(api.json_member(params,"name"))
    if id=="" || name!=api.MCP_DOCS_TOOL {return}
    w:serial.Writer
    serial.writer_init(&w,4096,context.temp_allocator)
    api.docs_tool_write(&w,root,api.json_member(params,"arguments"))
    return fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":%s}}`,id,string(serial.writer_bytes(&w))),true
}

// What is answered while no editor does: why and the docs tool, which needs
// none. With --project also one tool whose call starts the session of the
// project, so that a client has something to call; a port that stopped
// answering says how to start it.
mcp_absent :: proc(root:string,c:Connection,editor:Connection_Editor,failed:api.Error) -> api.Bridge_Absent {
    instructions:=fmt.tprintf("%s. Open the editor; the tools are listed when it runs.",failed.message)
    tools:=api.MCP_DOCS_ENTRY
    if c.project!="" {
        hint:=editor.port==0?failed.message:no_editor_text(c.project)
        instructions=fmt.tprintf("%s. The tools are listed when it runs.",hint)
        description:=serial.text_quote(fmt.tprintf("%s. Calling a method through this starts it; the tools of the editor are listed when it runs.",hint))
        tools=fmt.tprintf(`%s,{{"name":"%s","description":%s,"inputSchema":%s}}`,tools,api.MCP_CALL_TOOL,description,api.MCP_CALL_SCHEMA)
    }
    if compact:=api.docs_compact(root);compact!="" {instructions=fmt.tprintf("%s\n\n%s",instructions,compact)}
    instance:=api.Instance{engine=project.ENGINE_VERSION,project=c.project!=""?os.base(c.project):"",folder=c.project}
    return {instructions,tools,failed,instance}
}

// A notification of a call that goes on, as it arrives.
mcp_event :: proc(user:rawptr,line:string) {
    bridge:=(^Mcp_Bridge)(user)
    sync.guard(&bridge.lock)
    os.write_string(os.stdout,line)
    os.write_string(os.stdout,"\n")
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
        reachable:=unlisted && api.bridge_reachable(connection_editor(bridge.connection).port,context.temp_allocator)
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
mcp_list_stale :: proc(asked:bool,listed,now:Connection_Editor) -> bool {
    return asked && now.port!=0 && now!=listed
}

// Tells the client when the editor of --project differs from the one its
// list came from, once that editor answers.
mcp_watch_project :: proc(bridge:^Mcp_Bridge) {
    for {
        time.sleep(MCP_PROJECT_POLL*time.Second)
        editor:=connection_editor(bridge.connection)
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
