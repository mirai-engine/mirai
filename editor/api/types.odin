package api

import "base:runtime"
import "core:net"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

// JSON-RPC 2.0 and MCP over HTTP on 127.0.0.1, served by whoever owns the
// Server: it polls once per frame, so every handler runs on that thread
// between frames. Methods take and return plain structs described by a
// serial.Schema; their JSON Schemas are generated from the same description.
//
// Convention for parameters: a field is required unless its struct tag has
// `optional` (`mirai:"optional,min=0,max=10"`). An absent optional field keeps
// the value of Method_Desc.defaults, or zero without it. Text is a [N]u8 field
// tagged `text`; N bytes is the longest value. Ranges come from the tags
// min and max, which also bound each element of an array field. A result a
// handler writes itself describes a list of any length with an array tagged
// `list`, any JSON value with a field tagged `any`, and a key that cannot be
// the name of a field (an Odin keyword such as where) with `key=where`. A
// param tagged `any` takes any JSON too; its handler reads it from Call.raw.
// An integer param that only bounds how much a method answers is tagged
// `clamp`: past its max it takes the max and the answer says so in _clamped.

DEFAULT_PORT :: 7940

// The editor starts each AI agent with the port of its API and the context
// of its turns, and the commands the agent runs inherit them: mirai rpc sends
// that context as X-Mirai-Ai-Task to that port.
AI_TASK_VARIABLE :: "MIRAI_AI_TASK"
// An agent outside the editor names itself with X-Mirai-Client: mirai mcp
// sends the name of its MCP client, and mirai rpc that of --client or of this.
CLIENT_VARIABLE :: "MIRAI_CLIENT"
CLIENT_NAME_BYTES :: 32
PORT_VARIABLE :: "MIRAI_API_PORT"

// <project>/.mirai/api.json names the port and the process of the editor that
// serves the API of the project: mirai rpc, mcp and session find it there,
// and with the binaries it runs, whether they are the last ones built.
PORT_FILE :: "api.json"
Port_File :: struct {
    port:int,
    pid:int,
    project:string,
    engine:string, // the folder of the binaries of the engine it runs
    stamp:string,  // the stamp of those binaries when it started
    library:string, // the stamp of the library of the project it loaded last
    manual:bool,   // headless, driven by the API frame by frame; false for an editor with a window
}

// <project>/.mirai/session.json: the editor mirai session opened last in the
// project, with the mode of its binaries and its arguments, which restart
// repeats. An editor that it and the port file name was opened by mirai
// session; one that restarts by itself names there the one it starts.
SESSION_FILE :: "session.json"
Session_Record :: struct {
    pid:int,
    mode:string, // "dev" or "release"
    args:[]string,
}

PARSE_ERROR       :: -32700
INVALID_REQUEST   :: -32600
METHOD_NOT_FOUND  :: -32601
INVALID_PARAMS    :: -32602
INTERNAL_ERROR    :: -32603
SERVER_ERROR      :: -32000 // a handler failed without a code of its own
HUNG              :: -32095 // client side: the process of the editor is alive and has used no CPU for a while: it will not answer
CLOSED            :: -32096 // the editor closed the connection without a byte of answer, or is ending during a _wait_until: it ended or restarted, perhaps after running the call
TIMEOUT           :: -32097 // client side: no answer in time
BAD_RESPONSE      :: -32098 // client side: the answer is not a JSON-RPC response
UNREACHABLE       :: -32099 // client side: nobody listens

Error :: struct {
    code:int,
    message:string,
    data:string, // JSON text; "" when there is none
}

Method_Flag :: enum u8 {
    Read_Only,
    Destructive,
    Idempotent,
    Core,      // tools/list gives it always: what agents use most, as each costs its schema every turn; the rest go through the tool call
    Turn,      // only for the turn of an agent of the editor: tools/list does not give it to another request
}
Method_Flags :: bit_set[Method_Flag;u8]

// A handler reads call.params and fills call.result, or calls call_fail. A
// method without params or result type is free-form: it reads call.raw and
// writes JSON into call.out.
Handler :: #type proc(call:^Call)

Method_Desc :: struct {
    name,summary:string,
    plugin:string,        // the plugin that registers it; empty for the editor
    params,result:typeid, // structs; nil: free-form JSON
    params_info,result_info:^runtime.Type_Info, // of params and result, from the binary that declares them when it is not this one
    params_schema,result_schema:string,         // a JSON Schema written by hand for free-form params or result
    defaults:rawptr,      // a params value; absent optional fields take its values
    handler:Handler,
    user:rawptr,
    flags:Method_Flags,
    writes_result:bool,   // the handler writes the result as JSON into call.out; result only gives its schema
}

Method :: struct {
    name,summary:string,
    plugin:string,
    name_hash:u64,
    params,result:serial.Type_Index, // TYPE_NONE: free-form
    params_id,result_id:typeid,
    params_schema,result_schema:string,
    defaults:[]u8,
    handler:Handler,
    user:rawptr,
    flags:Method_Flags,
    writes_result:bool,
    clamps:bool, // a field of its params is tagged clamp
}

// What the tag of a field tells the API beyond std/serial.
Field_Tag :: enum u8 {Optional,List,Any,Clamp}
Field_Tags :: bit_set[Field_Tag;u8]

Call :: struct {
    server:^Server,
    method:^Method,
    user:rawptr,
    raw:string,                   // the params as received: a JSON object
    client_tag:string,
    client_name:string,           // X-Mirai-Client: the agent outside the editor that calls, or ""
    params:rawptr,                // validated; nil when free-form
    result:rawptr,                // zeroed; nil when the handler writes the result
    out:^serial.Writer,           // the result the handler writes; nil when typed
    allocator:runtime.Allocator,  // scratch that lives until the response is written
    error:Error,
    failed:bool,
    image:string,                 // a PNG file the result shows: MCP gives it as image content after the text
}

Register_Error :: enum u8 {
    None,
    Full,
    Duplicate,
    Invalid_Name,
    Invalid_Handler,
    Invalid_Type, // the reason is in schema.error, or the type is not a struct
    Invalid_Schema, // a schema written by hand is not JSON, or the method has a type for it
    Too_Large,
}

Init_Error :: enum u8 {
    None,
    Out_Of_Memory,
    Bind_Failed,
}

// Zero fields take the default.
Server_Desc :: struct {
    port:int,                    // 0: the system picks one
    name,version,instructions:string,
    docs_root:string,            // the engine whose game documentation the MCP tool docs reads; "": no such tool
    max_methods:int,             // 256
    max_connections:int,         // 8
    max_request:int,             // body bytes: 256 KiB
    max_response:int,            // body bytes: 1 MiB
    scratch:int,                 // per request: 2 MiB
    timeout_ms:int,              // 5000
    allocator:runtime.Allocator,
}

Server_Stats :: struct {
    connections:u64,
    requests:u64,         // JSON-RPC messages answered or run
    calls:u64,            // methods run
    errors:u64,           // calls and messages that ended in an error
    rejected:u64,         // HTTP requests refused before reaching JSON-RPC
    timeouts:u64,
    methods_refused:u64,  // registrations that did not fit
    scratch_failures:u64, // requests that ran out of scratch
    oversized:u64,        // responses that did not fit
    peak_scratch:int,
}

Conn_State :: enum u8 {Free,Reading,Ready,Draining}
Route :: enum u8 {Rpc,Mcp}

Conn :: struct {
    socket:net.TCP_Socket,
    state:Conn_State,
    buffer:[]u8,
    used,head,length:int,
    route:Route,
    reject:int, // HTTP status to answer instead of running the request
    reject_message:string,
    started:time.Tick,
    drained:int,
    keep:bool, // Connection: keep-alive: a request after another on the same connection
    client_tag:[64]u8,
    client_name:[CLIENT_NAME_BYTES]u8,
    plugins:[512]u8, // X-Mirai-Plugins: the plugins whose tools tools/list adds to those of the editor
}

Server :: struct {
    allocator:runtime.Allocator,
    name,version,instructions,docs_root:string,
    listener:net.TCP_Socket,
    listening:bool,
    port:int,
    timeout:time.Duration,
    schema:serial.Schema,
    tags:[dynamic]Field_Tags, // per field of the schema
    keys:[dynamic]string,     // per field of the schema: its key=, or ""

    methods:[]Method,
    method_count:int,
    conns:[]Conn,
    conn_memory:[]u8,
    response:[]u8,
    staging:[]u8,
    out,stage:serial.Writer,
    scratch,text:base.Arena,
    sending:int, // index of the connection that is being answered, or -1
    send_at,send_end:int,
    max_request,max_response:int,
    stats:Server_Stats,
    client_tag:string,
    client_name:string,
    client_plugins:string, // of the request that runs
    image:string,          // Call.image of the call that ran last; in its scratch
    clamped:string,        // what the params read last asked past a maximum, as members of _clamped; in its scratch
    plugins:[]Plugin,
    guides:[]Guide,
    assets:serial.Text_Assets, // how params take a path where an Asset_Id goes
    entities:serial.Text_Entities, // how params take a name where an Entity_Id goes
    pause:proc(s:^Server,seconds:f64)->bool, // keeps what owns the server going between two calls of _wait_until; false: it is ending
    user:rawptr,                             // of pause
}

// A plugin the project finds; active: the project uses it.
Plugin :: struct {
    name:string,
    active:bool,
}

// How to use a family of methods: those of the plugin named topic, the method
// named topic, or those whose names start with topic and a dot.
// engine.describe gives it with them.
Guide :: struct {topic,text:string}

method_find :: proc(s:^Server,name:string) -> ^Method {
    hash:=base.name_hash(name)
    for &method in s.methods[:s.method_count] {
        if method.name_hash==hash && method.name==name {return &method}
    }
    return nil
}

// A reader of text that came with a call: asset fields take a path as well as an id.
call_reader_init :: proc(call:^Call,r:^serial.Text_Reader,text:string) {
    serial.text_reader_init(r,text,call.allocator)
    r.loose_names=true
    if call.server!=nil {r.assets=call.server.assets}
}

call_params :: #force_inline proc(call:^Call,$T:typeid) -> ^T {
    assert(call.method.params_id==T)
    return (^T)(call.params)
}
call_result :: #force_inline proc(call:^Call,$T:typeid) -> ^T {
    assert(call.method.result_id==T)
    return (^T)(call.result)
}
// An MCP answer carries the PNG at path as an image after the text of the
// result; a JSON-RPC one only the result. path is copied.
call_image :: proc(call:^Call,path:string) {call.image=clone_text(call.allocator,path)}

// message is copied; data is JSON text or "".
call_fail :: proc(call:^Call,code:int,message:string,data:="") {
    call.failed=true
    call.error={code,clone_text(call.allocator,message),clone_text(call.allocator,data)}
}
call_failf :: proc(call:^Call,code:int,format:string,args:..any) {
    call.failed=true
    call.error={code,format_text(call.allocator,format,..args),""}
}
