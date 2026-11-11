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
// The params and the result of a method are structs, and they are its only
// description: a method without a params type takes none, and one without a
// result type answers null. A field is required unless its struct tag has
// `optional` (`mirai:"optional,min=0,max=10"`). An absent optional field keeps
// the value of Method_Desc.defaults, or zero without it. Text is a [N]u8 field
// tagged `text`, N bytes the longest value, or a string of any length. Ranges
// come from the tags min and max, which also bound each element of an array
// field. A list of any length is a slice, in the scratch of the call; any
// JSON value, one whose shape only the world knows (the values of a
// component), is a serial.Json field, which holds its text; and a key that
// cannot be the name of a field (an Odin keyword such as where) is given with
// `name=where`. An integer param that only bounds how much a method answers is
// tagged `clamp`: past its max it takes the max and the answer says so in
// _clamped.

DEFAULT_PORT :: 7940

// The editor starts each AI agent with the port of its API and the context
// of its turns, and the commands the agent runs inherit them: mirai rpc sends
// that context as X-Mirai-Ai-Task to that port.
// A command that runs inside a measurement (mirai measure) sends which one as
// X-Mirai-Measure: the editor is no child of it and would wait for its turn.
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
    stamp:string,  // the stamp of the binaries it runs, as they were built (build.engine_stamp_of)
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
    args:[]string,
}

PARSE_ERROR       :: -32700
INVALID_REQUEST   :: -32600
METHOD_NOT_FOUND  :: -32601
INVALID_PARAMS    :: -32602
INTERNAL_ERROR    :: -32603
SERVER_ERROR      :: -32000 // a handler failed without a code of its own
NOT_NOW           :: -32001 // the state of the editor does not allow the method now: data.fix names the method that changes it
CANCELLED         :: -32094 // the client cancelled the call; it stopped at a safe point
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
    Draws,     // it draws the scene or starts what draws it: whoever serves it has the shaders of the disk published first
    As_User,   // it runs frames, input or captures as the user would: what it changes is the user's, of no caller
    View,      // it changes what the editor shows, or ends a turn, and not the document
}
Method_Flags :: bit_set[Method_Flag;u8]

// A handler reads call.params and fills call.result, or calls call_fail.
Handler :: #type proc(call:^Call)

Method_Desc :: struct {
    name,summary:string,
    plugin:string,        // the plugin that registers it; empty for the editor
    params,result:^runtime.Type_Info, // structs, from the library that declares them; nil: no params, a null result
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
    params,result:serial.Type_Index, // TYPE_NONE: no params, a null result
    params_id,result_id:typeid,
    defaults:[]u8,
    handler:Handler,
    user:rawptr,
    flags:Method_Flags,
    writes_result:bool,
    clamps:bool, // a field of its params is tagged clamp
}

Call :: struct {
    server:^Server,
    method:^Method,
    user:rawptr,
    raw:string,                   // the params as read: a JSON object, with its names as the types of the params have them
    client_tag:string,
    client_name:string,           // X-Mirai-Client: the agent outside the editor that calls, or ""
    measure:string,               // X-Mirai-Measure: the measurement the caller is part of, or ""
    params:rawptr,                // validated; nil when the method takes none
    result:rawptr,                // zeroed; nil when the handler writes the result or there is none
    out:^serial.Writer,           // the result a handler that writes it writes; nil when the server writes it from result
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
    local:bool,                  // it listens on no port: only whoever owns it runs its methods (method_execute)
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
    stream:bool, // Accept: text/event-stream: its tools/call may answer as a stream
    client_tag:[64]u8,
    client_name:[CLIENT_NAME_BYTES]u8,
    measure:[24]u8, // X-Mirai-Measure
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
    client_measure:string,
    client_plugins:string, // of the request that runs
    image:string,          // Call.image of the call that ran last; in its scratch
    running:Running,       // the tools/call that holds the server
    instance:Instance,     // which editor this is
    clamped:string,        // what the params read last asked past a maximum, as members of _clamped; in its scratch
    plugins:[]Plugin,
    guides:[]Guide,
    assets:serial.Text_Assets, // how params take a path where an Asset_Id goes
    pause:proc(s:^Server,seconds:f64)->bool, // keeps what owns the server going between two calls of _wait_until; false: it is ending
    transaction:proc(s:^Server,call:^Call,open:bool)->bool, // opens the one step of undo the calls of a batch edit in, or closes it: a step when the call did not fail, nothing otherwise; false after failing the call
    user:rawptr,                             // of pause and transaction
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
    r.nulls=true
    if call.server!=nil {r.assets=call.server.assets}
}

call_params :: #force_inline proc(call:^Call,$T:typeid) -> ^T {
    assert(call.method.params_id==T)
    return (^T)(call.params)
}
call_result :: #force_inline proc(call:^Call,$T:typeid) -> ^T {
    assert(call.method.result_id==T && call.result!=nil,"a handler answers with the result its method registers; a call made by hand gives it one")
    return (^T)(call.result)
}
// Whether the caller gave a param, and not null: an optional one left out
// holds what it starts with, which may be what the caller would have given.
call_given :: proc(call:^Call,name:string) -> bool {
    value:=json_member(call.raw,name)
    return value!="" && value!="null"
}
// An MCP answer carries the PNG at path as an image after the text of the
// result; a JSON-RPC one only the result. path is copied.
call_image :: proc(call:^Call,path:string) {call.image=clone_text(call.allocator,path)}

// message is copied; data is JSON text or "".
call_fail :: proc(call:^Call,code:int,message:string,data:="") {
    call.failed=true
    call.error={code,clone_text(call.allocator,message),clone_text(call.allocator,data)}
}
// The state of the editor does not allow the method now: no game plays, or one
// does. fix names the method that changes that, which the error carries in
// data.fix for whoever calls to branch on.
call_not_now :: proc(call:^Call,message,fix:string) {
    call.failed=true
    call.error={NOT_NOW,clone_text(call.allocator,message),format_text(call.allocator,`{{"fix":%s}}`,serial.text_quote(fix,call.allocator))}
}
call_failf :: proc(call:^Call,code:int,format:string,args:..any) {
    call.failed=true
    call.error={code,format_text(call.allocator,format,..args),""}
}
