package api

import "core:os"
import "core:strconv"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// The Model Context Protocol over streamable HTTP, without sessions: every POST
// /mcp carries one JSON-RPC message (or a batch) and gets one JSON answer, or 202
// when it is a notification; a tools/call that asks for progress answers as a
// stream of events (progress.odin). Each
// method is a tool named like it with dots as underscores; its input schema
// is the JSON Schema of its params. A result is its JSON as text, what models
// read; a failed call is a tool error carrying {"error":{code,message,data}}.
// tools/list gives the tool docs, the basic tools of the editor (Core: what
// an agent uses most) and the tool call, which runs any method by its name with its params, and
// with them those of the plugins the header X-Mirai-Plugins names (* for
// every method). An agent asks engine_describe for the schema of the rest:
// each tool listed costs its schema in every turn of its model. tools/call
// takes any of them by name too. Every tool also takes _select, and one
// that is read-only _wait_until (fields.odin).

MCP_VERSIONS :: [?]string{"2025-11-25","2025-06-18","2025-03-26","2024-11-05"}

@(private)
TOOLS_RESERVE :: 512

// The tool that runs any method by its name: those of the plugins and of the
// editor that tools/list does not give.
MCP_CALL_TOOL :: "call"
@(private)
MCP_CALL_DESCRIPTION :: "Runs any method of the editor or of a plugin by its name (such as animation.request or panel.save) with its params. engine_describe is a short index of the methods; with methods (a list of names) it gives the JSON Schema of their params and result, and with plugin or prefix the summaries and guides of an area. Every method also takes _select (fields of its result to keep, such as a.b,c[0].d), and a read-only one _wait_until (a condition such as phase=Built, which it is called again until); a method that changes things is called once, and the wait goes on its status method."
MCP_CALL_SCHEMA :: `{"type":"object","properties":{"method":{"type":"string","description":"The name of the method, such as terrain.sculpt"},"params":{"type":"object","description":"Its params, as engine_describe gives their schema"}},"required":["method"],"additionalProperties":false}`

@(private)
mcp_dispatch :: proc(s:^Server,req:^Request,w:^serial.Writer) -> (Error,bool) {
    switch req.method {
    case "initialize": return mcp_initialize(s,req,w)
    case "ping": raw(w,"{}");return {},true
    case "tools/list": return mcp_tools_list(s,req,w)
    case "tools/call": return mcp_tools_call(s,req,w)
    }
    return {METHOD_NOT_FOUND,format_text(base.arena_allocator(&s.scratch),"unknown method %q",shorten(req.method)),""},false
}

// The version of the protocol to speak: the client's when this server knows
// it, otherwise the newest.
mcp_version :: proc(requested:string) -> string {
    versions:=MCP_VERSIONS
    for version in versions {if version==requested {return version}}
    return versions[0]
}

// list_changed: the client is told when the tools change.
mcp_initialize_write :: proc(w:^serial.Writer,requested,name,version,instructions:string,list_changed:=false,instance:=Instance{}) {
    raw(w,`{"protocolVersion":`);serial.text_write_string(w,mcp_version(requested))
    raw(w,`,"capabilities":{"tools":{"listChanged":`);raw(w,list_changed?"true":"false")
    raw(w,`}},"serverInfo":{"name":`);serial.text_write_string(w,name)
    raw(w,`,"version":`);serial.text_write_string(w,version)
    raw(w,`},"instructions":`);serial.text_write_string(w,instructions)
    raw(w,`,"_meta":{"engine_version":`);serial.text_write_string(w,instance.engine)
    if instance.process!=0 {raw(w,`,"process_id":`);serial.text_write_int(w,i64(instance.process))}
    raw(w,`,"project":`);serial.text_write_string(w,instance.project)
    raw(w,`,"project_folder":`);serial.text_write_string(w,instance.folder)
    raw(w,"}}")
}

// Which editor answers an initialize, for an agent with several: what the
// bridge knows when none does yet.
Instance :: struct {
    process:int, // 0: no editor answers
    engine,project,folder:string,
}

@(private)
mcp_initialize :: proc(s:^Server,req:^Request,w:^serial.Writer) -> (Error,bool) {
    values:[1]string
    requested:string
    if req.has_params && object_values(base.arena_allocator(&s.scratch),req.params,{"protocolVersion"},values[:]) && values[0]!="" {
        requested,_=string_value(base.arena_allocator(&s.scratch),values[0])
    }
    instructions:=s.instructions
    if s.docs_root!="" {
        if compact:=docs_compact(s.docs_root);compact!="" {instructions=format_text(base.arena_allocator(&s.scratch),"%s\n\n%s",instructions,compact)}
    }
    mcp_initialize_write(w,requested,s.name,s.version,instructions,instance=s.instance)
    return {},true
}

@(private)
mcp_tools_list :: proc(s:^Server,req:^Request,w:^serial.Writer) -> (Error,bool) {
    values:[1]string
    start:=0
    if req.has_params && object_values(base.arena_allocator(&s.scratch),req.params,{"cursor"},values[:]) && values[0]!="" {
        cursor,ok:=string_value(base.arena_allocator(&s.scratch),values[0])
        parsed,valid:=strconv.parse_int(cursor,10)
        if !ok || !valid || parsed<0 || parsed>s.method_count {return {INVALID_PARAMS,"invalid cursor",""},false}
        start=parsed
    }
    raw(w,`{"tools":[`)
    buffer:[MAX_NAME]u8
    next:=-1
    listed:=0
    if start==0 && s.docs_root!="" {
        raw(w,MCP_DOCS_ENTRY)
        listed=1
    }
    for i in start..<s.method_count {
        method:=&s.methods[i]
        if !mcp_listed(method,s.client_plugins) || .Turn in method.flags && s.client_tag=="" {continue}
        mark:=w.count
        if listed>0 {raw(w,",")}
        raw(w,`{"name":`);serial.text_write_string(w,tool_name(method.name,buffer[:]))
        raw(w,`,"description":`);serial.text_write_string(w,method.summary)
        raw(w,`,"inputSchema":`);method_schema_write(w,s,method,false)
        raw(w,`,"annotations":{"readOnlyHint":`);raw(w,.Read_Only in method.flags?"true":"false")
        raw(w,`,"destructiveHint":`);raw(w,.Destructive in method.flags?"true":"false")
        raw(w,`,"idempotentHint":`);raw(w,.Idempotent in method.flags?"true":"false")
        raw(w,`,"openWorldHint":false}}`)
        if w.overflow>0 || w.count>len(w.data)-TOOLS_RESERVE {
            rewind(w,mark)
            if listed==0 {return {SERVER_ERROR,"a tool does not fit in the response buffer",""},false}
            next=i
            break
        }
        listed+=1
    }
    if next<0 {
        if listed>0 {raw(w,",")}
        raw(w,`{"name":"`);raw(w,MCP_CALL_TOOL);raw(w,`","description":`);serial.text_write_string(w,MCP_CALL_DESCRIPTION)
        raw(w,`,"inputSchema":`);raw(w,MCP_CALL_SCHEMA);raw(w,`,"annotations":{"openWorldHint":false}}`)
    }
    raw(w,"]")
    if next>=0 {
        raw(w,`,"nextCursor":"`);serial.text_write_int(w,i64(next));raw(w,`"`)
    }
    raw(w,"}")
    return {},true
}

// Whether tools/list gives the tool of method: a basic one of the editor,
// one of a plugin that plugins (X-Mirai-Plugins) names, or any with *.
@(private)
mcp_listed :: proc(method:^Method,plugins:string) -> bool {
    rest:=plugins
    for name in strings.split_iterator(&rest,",") {
        trimmed:=strings.trim_space(name)
        if trimmed=="*" || method.plugin!="" && trimmed==method.plugin {return true}
    }
    return method.plugin=="" && .Core in method.flags
}

@(private)
mcp_tools_call :: proc(s:^Server,req:^Request,w:^serial.Writer) -> (Error,bool) {
    values:[2]string
    if !req.has_params || !object_values(base.arena_allocator(&s.scratch),req.params,{"name","arguments"},values[:]) || values[0]=="" {
        return {INVALID_PARAMS,"params must be an object with the name of a tool",""},false
    }
    name,named:=string_value(base.arena_allocator(&s.scratch),values[0])
    if !named {return {INVALID_PARAMS,"name must be a string",""},false}
    arguments:="{}"
    if values[1]!="" {
        if values[1][0]!='{' {return {INVALID_PARAMS,"arguments must be an object",""},false}
        arguments=values[1]
    }
    if name==MCP_DOCS_TOOL && s.docs_root!="" {
        docs_tool_write(w,s.docs_root,values[1])
        return {},true
    }
    // The tool call names the method in its arguments and gives it their params.
    if name==MCP_CALL_TOOL {
        call:[2]string
        if !object_values(base.arena_allocator(&s.scratch),arguments,{"method","params"},call[:]) || call[0]=="" {return {INVALID_PARAMS,"call takes the name of a method in method, and its params in params",""},false}
        method_name,valid:=string_value(base.arena_allocator(&s.scratch),call[0])
        if !valid {return {INVALID_PARAMS,"method must be a string",""},false}
        if call[1]!="" && call[1][0]!='{' {return {INVALID_PARAMS,"params must be an object",""},false}
        name,arguments=method_name,call[1]!=""?call[1]:"{}"
    }
    method:=tool_find(s,name)
    if method==nil {return {INVALID_PARAMS,format_text(base.arena_allocator(&s.scratch),"unknown tool or method %q%s; engine_describe lists the methods",shorten(name),methods_similar(s,tool_as_method(name))),""},false}
    serial.writer_reset(&s.stage)
    running_begin(s,req)
    err,ok,selected,note:=method_call(s,method,arguments,&s.stage)
    if s.running.stopped {err,ok={CANCELLED,"the client cancelled the call: it stopped at a safe point and what it did before stands",""},false}
    if ok && s.stage.overflow>0 {
        s.stats.oversized+=1
        err,ok={SERVER_ERROR,"the result does not fit in the response buffer",""},false
    }
    if ok {
        result:=string(serial.writer_bytes(&s.stage))
        mark:=base.arena_mark(&s.scratch)
        failed:=s.scratch.failed
        r:serial.Text_Reader
        serial.text_reader_init(&r,result,base.arena_allocator(&s.scratch))
        valid:=serial.text_skip(&r) && serial.text_end(&r)
        base.arena_rewind(&s.scratch,mark)
        if s.scratch.failed!=failed {
            s.stats.scratch_failures+=1
            err,ok={INTERNAL_ERROR,"the result needs more scratch memory than the server has",""},false
        } else if !valid {
            err,ok={INTERNAL_ERROR,"the tool returned an invalid result",""},false
        }
    }
    if !ok {
        serial.writer_reset(&s.stage)
        s.stats.errors+=1
        raw(&s.stage,`{"error":`);write_error_object(base.arena_allocator(&s.scratch),&s.stage,err);raw(&s.stage,"}")
    }
    raw(w,`{"content":[{"type":"text","text":`)
    serial.text_write_string(w,ok && selected!=""?selected:string(serial.writer_bytes(&s.stage)))
    raw(w,`}`)
    if ok && note!="" {raw(w,`,{"type":"text","text":`);serial.text_write_string(w,note);raw(w,`}`)}
    if ok && s.image!="" {mcp_image_write(s,w,s.image)}
    raw(w,`]`)
    raw(w,`,"isError":`);raw(w,ok?"false":"true");raw(w,"}")
    return {},true
}

// A name of a tool as the method it may mean: its first underscore a dot.
@(private)
tool_as_method :: proc(name:string) -> string {
    if strings.contains_rune(name,'.') {return name}
    named,_:=strings.replace(name,"_",".",1,context.temp_allocator)
    return named
}

@(private)
BASE64 :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

// The PNG at path as an image content item, encoded straight into w; a text
// item that says where it is when it cannot be read or does not fit beside
// the rest of the answer.
@(private)
mcp_image_write :: proc(s:^Server,w:^serial.Writer,path:string) {
    note :: proc(s:^Server,w:^serial.Writer,format:string,args:..any) {
        raw(w,`,{"type":"text","text":`)
        serial.text_write_string(w,format_text(base.arena_allocator(&s.scratch),format,..args))
        raw(w,`}`)
    }
    data,error:=os.read_entire_file(path,s.allocator)
    if error!=nil {note(s,w,"The image %s could not be read: %v",path,error);return}
    defer delete(data,s.allocator)
    encoded:=(len(data)+2)/3*4
    room:=len(w.data)-w.count-256
    if encoded>room {
        note(s,w,"The image of %d bytes does not fit in the answer (%d bytes at most); it is at %s",len(data),max(room/4*3,0),path)
        return
    }
    raw(w,`,{"type":"image","data":"`)
    out:=w.data[w.count:][:encoded]
    table:=BASE64
    for i:=0;i<len(data);i+=3 {
        n:=min(len(data)-i,3)
        v:=u32(data[i])<<16
        if n>1 {v|=u32(data[i+1])<<8}
        if n>2 {v|=u32(data[i+2])}
        o:=out[i/3*4:][:4]
        o[0],o[1]=table[v>>18&63],table[v>>12&63]
        o[2]=n>1?table[v>>6&63]:'='
        o[3]=n>2?table[v&63]:'='
    }
    w.count+=encoded
    raw(w,`","mimeType":"image/png"}`)
}
