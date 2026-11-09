package api

import "base:runtime"
import "mirai:std/serial"

// What `mirai mcp` does with each message that arrives on stdio: forward it
// to POST /mcp of the editor. The editor answers everything but what a client
// needs while the editor is not running: initialize, ping and tools/list
// (empty) are answered here, a tool call fails as a tool error, and anything
// else with an id fails with UNREACHABLE.

BRIDGE_RETRY :: 10 // seconds between attempts to reach the editor after an empty list
BRIDGE_LIST_CHANGED :: `{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}`

// The line to write to stdout; ok is false when no answer is due. unlisted:
// the client was given an empty list, so it is told when the editor runs.
// plugins: the plugins whose tools are listed besides those of the editor.
// client: the name of the MCP client, sent as X-Mirai-Client.
bridge_handle :: proc(port,timeout_ms:int,message:string,allocator:runtime.Allocator,task:string="",plugins:string="",client:string="",watch:=Client_Watch{}) -> (reply:string,ok,unlisted:bool) {
    values:[3]string
    object:=object_values(allocator,message,{"id","method","params"},values[:])
    if !object && !json_valid(allocator,message) {
        return bridge_error(allocator,"",{PARSE_ERROR,"parse error",""}),true,false
    }
    status,body,post_error:=client_post(port,"/mcp",message,timeout_ms,allocator,task,plugins,client,watch)
    if post_error.code==0 {
        if status==202 {return "",false,false}
        if status==200 {return json_single_line(string(body),allocator),true,false}
        envelope,valid:=envelope_read(allocator,string(body))
        if valid && envelope.error!="" {return bridge_error(allocator,values[0],error_read(allocator,envelope.error)),true,false}
        return bridge_error(allocator,values[0],client_error(allocator,BAD_RESPONSE,"the editor answered HTTP %d",status)),true,false
    }
    if !object || values[0]=="" {return "",false,false}
    method,_:=string_value(allocator,values[1])
    w:serial.Writer
    serial.writer_init(&w,512,allocator)
    switch method {
    case "initialize":
        raw(&w,`{"jsonrpc":"2.0","id":`);raw(&w,values[0]);raw(&w,`,"result":`)
        requested:string
        if params:[1]string;object_values(allocator,values[2],{"protocolVersion"},params[:]) && params[0]!="" {requested,_=string_value(allocator,params[0])}
        mcp_initialize_write(&w,requested,"mirai","1",format_text(allocator,"%s. Open the editor; the tools are listed when it runs.",post_error.message),true)
        raw(&w,"}")
        return string(serial.writer_bytes(&w)),true,false
    case "ping":
        raw(&w,`{"jsonrpc":"2.0","id":`);raw(&w,values[0]);raw(&w,`,"result":{}}`)
        return string(serial.writer_bytes(&w)),true,false
    case "tools/list":
        raw(&w,`{"jsonrpc":"2.0","id":`);raw(&w,values[0]);raw(&w,`,"result":{"tools":[]}}`)
        return string(serial.writer_bytes(&w)),true,true
    case "tools/call":
        raw(&w,`{"jsonrpc":"2.0","id":`);raw(&w,values[0])
        raw(&w,`,"result":{"content":[{"type":"text","text":`)
        inner:serial.Writer
        serial.writer_init(&inner,256,allocator)
        raw(&inner,`{"error":`);write_error_object(allocator,&inner,post_error);raw(&inner,"}")
        serial.text_write_string(&w,string(serial.writer_bytes(&inner)))
        raw(&w,`}],"isError":true}}`)
        return string(serial.writer_bytes(&w)),true,false
    }
    return bridge_error(allocator,values[0],post_error),true,false
}

// The name an MCP initialize gives its client (params.clientInfo.name) as
// X-Mirai-Client takes it: lowercase, what is not a letter or a digit a '-',
// cut to fit; "" for another message or one without it.
bridge_client_name :: proc(allocator:runtime.Allocator,message:string) -> string {
    values:[2]string
    if !object_values(allocator,message,{"method","params"},values[:]) {return ""}
    if method,_:=string_value(allocator,values[0]);method!="initialize" {return ""}
    info:[1]string
    if !object_values(allocator,values[1],{"clientInfo"},info[:]) {return ""}
    name:[1]string
    if !object_values(allocator,info[0],{"name"},name[:]) {return ""}
    text,_:=string_value(allocator,name[0])
    out:=make([]u8,min(len(text),CLIENT_NAME_BYTES-1),allocator)
    for &c,i in out {
        b:=text[i]
        switch {
        case b>='A' && b<='Z': c=b+32
        case b>='a' && b<='z' || b>='0' && b<='9' || b=='.' || b=='_' || b=='-': c=b
        case: c='-'
        }
    }
    return string(out)
}

// A name of X-Mirai-Client: letters, digits, '.', '_' and '-', shorter than CLIENT_NAME_BYTES.
client_name_valid :: proc "contextless" (name:string) -> bool {
    if len(name)==0 || len(name)>=CLIENT_NAME_BYTES {return false}
    for b in transmute([]u8)name {
        if !(b>='a' && b<='z' || b>='A' && b<='Z' || b>='0' && b<='9' || b=='.' || b=='_' || b=='-') {return false}
    }
    return true
}

// Whether the editor answers on port.
bridge_reachable :: proc(port:int,allocator:runtime.Allocator) -> bool {
    status,_,post_error:=client_post(port,"/mcp",`{"jsonrpc":"2.0","id":0,"method":"ping"}`,2000,allocator)
    return post_error.code==0 && status==200
}

@(private)
bridge_error :: proc(allocator:runtime.Allocator,id:string,err:Error) -> string {
    w:serial.Writer
    serial.writer_init(&w,256,allocator)
    write_error_envelope(allocator,&w,id,err)
    return string(serial.writer_bytes(&w))
}
