package main

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/serial"

RPC_USAGE :: "rpc <method> [key=value...|json|-|--file F] [--select FIELDS] [--wait-until CONDITION] | rpc describe [plugin|method|prefix|method...] | rpc --batch <calls.jsonl> | rpc --stdin [--project P|--port N] [--timeout S] [--client NAME]"

RPC_ENDING_WAIT :: 3*time.Second // how long an editor that stopped listening may go on counting as alive
RPC_RESTART_PAUSE :: 250*time.Millisecond // between the calls of a --wait-until whose editor restarts
RPC_WAIT_MARGIN_MS :: 5000 // a --wait-until reads the answer past its limit: the server says what it last saw
RPC_ECHO_BYTES :: 240 // of a result an error repeats

// The methods, by their tool names, that only make sense with an editor
// already open: calling one never starts a session.
RPC_NEEDS_OPEN_EDITOR :: [?]string{"engine_shutdown","ai_turn_end"}

Connection :: struct {
    port,timeout_ms:int,
    timed:bool,  // --timeout gave timeout_ms
    root:string, // of the engine, where a session is started from
    agent:Agent_Environment, // the task context the calls to the editor of that port belong to
    project:string, // with --project and no --port: whose api.json names the port, read again on every attempt
    named:bool,     // --project named project, which a call may open a session of
    near:string,    // with a port: the project at or above the working folder, to know the process of an editor of that port
    client:string,  // the agent outside the editor that calls: --client, MIRAI_CLIENT, or claude-code from its shell
    link:^api.Client_Connection, // --stdin: one connection for all its calls
    rest:[dynamic]string,
}

// What the editor gives the commands of an AI agent it starts: the task
// context of the agent and the port of the editor, both or neither.
Agent_Environment :: struct {
    task:string,
    port:int,
}

agent_environment :: proc() -> Agent_Environment {
    task,_:=os.lookup_env(api.AI_TASK_VARIABLE,context.allocator)
    text,_:=os.lookup_env(api.PORT_VARIABLE,context.temp_allocator)
    port,valid:=strconv.parse_int(text,10)
    if task=="" || !valid || port<=0 || port>65535 {return {}}
    return {task,port}
}

// --port N, --project P, --timeout SECONDS and --client NAME;
// everything else is returned in order. Without --port, the port is the one
// of the editor of --project (api.PORT_FILE), or that of agent, or of the
// project at or above the working directory; api.DEFAULT_PORT only outside
// any project, never for one.
connection_args :: proc(args:[]string,agent:Agent_Environment) -> (connection:Connection,ok:bool) {
    connection={port=0,timeout_ms=api.WAIT_TIMEOUT_MS,agent=agent}
    folder:=""
    for i:=0;i<len(args);i+=1 {
        switch args[i] {
        case "--port","--timeout":
            if i+1>=len(args) {return}
            value,valid:=strconv.parse_int(args[i+1],10)
            if !valid || value<=0 || (args[i]=="--port" && value>65535) {return}
            if args[i]=="--port" {connection.port=value} else {connection.timeout_ms,connection.timed=value*1000,true}
            i+=1
        case "--project":
            if i+1>=len(args) || args[i+1]=="" {return}
            folder=args[i+1]
            i+=1
        case "--client":
            if i+1>=len(args) || !api.client_name_valid(args[i+1]) {return}
            connection.client=args[i+1]
            i+=1
        case: append(&connection.rest,args[i])
        }
    }
    if connection.port==0 {
        if folder!="" {
            connection.project,connection.named=project.path_absolute(folder),true
            return connection,true
        }
        connection.port=agent.port
        if connection.port==0 {
            if owner:=project_of(".");owner!="" {
                connection.project=owner
                return connection,true
            }
            connection.port=api.DEFAULT_PORT
        }
    }
    connection.near=project_of(".")
    return connection,true
}

// An editor calls go to, as the port file of its project names it; zero when
// a project has none, and only the port when the process is unknown.
Connection_Editor :: struct {port,pid:int}

// The editor calls go to now: with a project, the one its port file names, or
// none while it has no editor; with a port, that port and, when the port file
// of the project near it names it, its process.
connection_editor :: proc(connection:Connection) -> Connection_Editor {
    folder:=connection.project!=""?connection.project:connection.near
    if folder=="" {return {port=connection.port}}
    file,alive:=session_find(folder)
    if connection.project!="" {return alive?Connection_Editor{file.port,file.pid}:Connection_Editor{}}
    return alive && file.port==connection.port?Connection_Editor{file.port,file.pid}:Connection_Editor{port=connection.port}
}

// What a client watches of the editor a call goes to, with the log of a
// session and label naming the call in its notices.
connection_watch :: proc(connection:Connection,editor:Connection_Editor,label:string) -> api.Client_Watch {
    log:=""
    folder:=connection.project!=""?connection.project:connection.near
    if file,alive:=session_find(folder);alive && file.pid==editor.pid && file.manual {log=session_log_path(folder)}
    return {editor.pid,log,label}
}

// The agent outside the editor whose shell runs the command: MIRAI_CLIENT,
// or Claude Code, which marks the commands it runs with CLAUDECODE=1.
client_environment :: proc() -> string {
    if name,found:=os.lookup_env(api.CLIENT_VARIABLE,context.allocator);found && api.client_name_valid(name) {return name}
    if value,_:=os.lookup_env("CLAUDECODE",context.temp_allocator);value=="1" {return "claude-code"}
    return ""
}

// The task context of a call to port: that of the agent when the call goes
// to the editor that started it.
connection_task :: proc(connection:Connection,port:int) -> string {
    return connection.agent.task if port==connection.agent.port else ""
}

// What a call to a project without an open editor says.
no_editor_text :: proc(project:string) -> string {
    return fmt.tprintf("%s has no open editor: mirai session start %s",project,project)
}

// Whether a call of method may start the session of the project --project
// names. method is a method or its tool; "" is not a call of one.
connection_opens :: proc(connection:Connection,method:string) -> bool {
    if !connection.named || method=="" {return false}
    tool,_:=strings.replace_all(method,".","_",context.temp_allocator)
    bound:=RPC_NEEDS_OPEN_EDITOR
    for name in bound {
        if name==tool {return false}
    }
    return true
}

// The editor a call of method goes to, opening the session of its project
// when it has none and the method may; err says why there is none to call.
connection_ready :: proc(connection:Connection,method:string) -> (editor:Connection_Editor,err:api.Error) {
    editor=connection_editor(connection)
    if editor.port==0 && connection_opens(connection,method) {
        if err=connection_session_start(connection);err.code!=0 {return}
        editor=connection_editor(connection)
    }
    if editor.port==0 {err={api.UNREACHABLE,no_editor_text(connection.project),""}}
    return
}

// Whether a call of method found nobody listening because its editor is
// ending: a killed process still counts as alive for a moment after it closed
// its port. Then connection_ready opens another session and the call is made again.
connection_ended :: proc(connection:Connection,method:string,err:api.Error) -> bool {
    if err.code!=api.UNREACHABLE || !connection_opens(connection,method) {return false}
    start:=time.tick_now()
    for connection_editor(connection).port!=0 {
        if time.tick_since(start)>=RPC_ENDING_WAIT {return false}
        time.sleep(100*time.Millisecond)
    }
    return true
}

// Starts the headless session of the project of connection, saying so on
// stderr, where all that mirai session start prints goes too: stdout is the
// answer of the call.
connection_session_start :: proc(connection:Connection) -> api.Error {
    fmt.eprintfln("mirai: %s has no open editor; starting its headless session (mirai session start %s --dev)",connection.project,connection.project)
    self,error:=os.get_executable_path(context.temp_allocator)
    if error!=nil {return {api.UNREACHABLE,fmt.tprintf("could not start the session of %s: %v",connection.project,error),""}}
    if run_with(connection.root,{self,"session","start",connection.project,"--dev"},os.stderr)!=0 {
        return {api.UNREACHABLE,fmt.tprintf("mirai session start %s --dev failed; what it said is above",connection.project),""}
    }
    return {}
}

// One call, in the editor connection_ready gives it.
rpc_call_waiting :: proc(connection:Connection,method,params:string,id:int) -> (result:string,err:api.Error,called:bool) {
    for retried:=false;;retried=true {
        editor:Connection_Editor
        editor,err=connection_ready(connection,method)
        if err.code!=0 {return}
        watch:=connection_watch(connection,editor,fmt.tprintf("mirai rpc %s",method))
        result,err,called=api.rpc_call(editor.port,method,params,id,connection.timeout_ms,context.allocator,connection_task(connection,editor.port),connection.client,watch,connection.link)
        if called || retried || !connection_ended(connection,method,err) {return}
    }
}

// A call of mirai rpc and what it asks of the result: FIELDS and CONDITION as
// they were written, which the server reads.
Rpc_Request :: struct {
    method,params:string,
    select,until:string,
}

cmd_rpc :: proc(root:string,args:[]string) -> int {
    connection,ok:=connection_args(args,agent_environment())
    connection.root=root
    if connection.client=="" {connection.client=client_environment()}
    if !ok || len(connection.rest)==0 {
        fmt.eprintfln("Usage: mirai %s",RPC_USAGE)
        return 2
    }
    switch connection.rest[0] {
    case "--batch":
        if len(connection.rest)!=2 {fmt.eprintfln("Usage: mirai %s",RPC_USAGE);return 2}
        return rpc_batch(connection,connection.rest[1])
    case "--stdin":
        if len(connection.rest)!=1 {fmt.eprintfln("Usage: mirai %s",RPC_USAGE);return 2}
        return rpc_stdin(connection)
    case "describe":
        return rpc_describe(connection,connection.rest[1:])
    }
    request,problem,parsed:=rpc_request(connection.rest[:])
    if !parsed {
        if problem!="" {fmt.eprintfln("mirai rpc: %s",problem)}
        fmt.eprintfln("Usage: mirai %s",RPC_USAGE)
        return 2
    }
    params:=strings.trim_space(request.params)
    if !api.json_valid(context.allocator,params) || !params_is_object(params) {
        return rpc_fail({api.INVALID_PARAMS,"params must be a JSON object: key=value arguments, '{...}' as one argument, - to read it from stdin, or --file F",""})
    }
    result,err,called:=rpc_request_call(connection,request,params)
    if !called {return rpc_fail(rpc_hint(connection,request.method,err))}
    return rpc_print(result,request.select!="")
}

// The call of a request, whose --select and --wait-until the server does. All
// that is left here is an editor that restarts during the wait, as a build
// can: the call is made again for what remains, and that restart opens no session.
rpc_request_call :: proc(connection:Connection,request:Rpc_Request,params:string) -> (result:string,err:api.Error,called:bool) {
    if request.until=="" {return rpc_call_waiting(connection,request.method,rpc_params_reserved(request,params,0),1)}
    limit:=connection.timed?connection.timeout_ms:api.WAIT_UNTIL_SECONDS*1000
    start:=time.tick_now()
    attempt:=connection
    restarting:=false
    for id:=1;;id+=1 {
        remaining:=limit-int(time.duration_milliseconds(time.tick_since(start)))
        if remaining<=0 {return}
        attempt.timeout_ms=remaining+RPC_WAIT_MARGIN_MS
        result,err,called=rpc_call_waiting(attempt,request.method,rpc_params_reserved(request,params,remaining),id)
        if called || !(err.code==api.CLOSED || restarting && err.code==api.UNREACHABLE) {return}
        restarting,attempt.named=true,false
        time.sleep(RPC_RESTART_PAUSE)
    }
}

// params, a JSON object, with the reserved params of the request; wait_ms is
// how long its --wait-until may take.
rpc_params_reserved :: proc(request:Rpc_Request,params:string,wait_ms:int) -> string {
    parts:=make([dynamic]string,context.temp_allocator)
    if members:=strings.trim_space(params[1:len(params)-1]);members!="" {append(&parts,members)}
    if request.select!="" {append(&parts,fmt.tprintf(`"%s":%s`,api.PARAM_SELECT,serial.text_quote(request.select)))}
    if request.until!="" {
        append(&parts,fmt.tprintf(`"%s":%s`,api.PARAM_WAIT_UNTIL,serial.text_quote(request.until)))
        append(&parts,fmt.tprintf(`"%s":%.3f`,api.PARAM_WAIT_SECONDS,f64(wait_ms)/1000))
    }
    return strings.concatenate({"{",strings.join(parts[:],",",context.temp_allocator),"}"},context.temp_allocator)
}

// The method, its params and what to do with the result, from what
// connection_args left. problem says what is wrong, unless it is plain misuse.
rpc_request :: proc(args:[]string) -> (request:Rpc_Request,problem:string,ok:bool) {
    request.params="{}"
    positional:=make([dynamic]string,context.temp_allocator)
    fields:=make([dynamic]string,context.temp_allocator)
    file:=""
    for i:=0;i<len(args);i+=1 {
        arg:=args[i]
        switch arg {
        case "--select","--wait-until","--file":
            if i+1>=len(args) {return request,fmt.tprintf("%s needs a value",arg),false}
            i+=1
            switch arg {
            case "--select":     request.select=args[i]
            case "--wait-until": request.until=args[i]
            case "--file":       file=args[i]
            }
        case:
            switch {
            case strings.has_prefix(arg,"--"): return request,fmt.tprintf("unknown option '%s'",arg),false
            case rpc_field_arg(arg):           append(&fields,arg)
            case:                              append(&positional,arg)
            }
        }
    }
    if len(positional)==0 || len(positional)>2 || (len(positional)==2 && file!="") {return request,"",false}
    request.method=positional[0]
    if len(fields)>0 {
        if len(positional)==2 || file!="" {return request,"key=value arguments and a JSON object do not go together",false}
        request.params,problem=rpc_fields_params(fields[:])
        return request,problem,problem==""
    }
    switch {
    case len(positional)==2 && positional[1]=="-": request.params=read_stdin()
    case len(positional)==2: request.params=positional[1]
    case file!="":
        data,error:=os.read_entire_file(file,context.allocator)
        if error!=nil {return request,fmt.tprintf("could not read %s",file),false}
        request.params=string(data)
    }
    return request,"",true
}

// A key=value argument of mirai rpc: its key is a name or names joined by dots.
rpc_field_arg :: proc(arg:string) -> bool {
    at:=strings.index_byte(arg,'=')
    if at<=0 || !(arg[0]=='_' || arg[0]>='a' && arg[0]<='z' || arg[0]>='A' && arg[0]<='Z') {return false}
    for c in transmute([]u8)arg[:at] {
        if !(c=='_' || c=='.' || c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9') {return false}
    }
    return true
}

// A member of the object key=value arguments build: its value as JSON, or
// the members inside it.
Rpc_Field :: struct {
    name,value:string,
    fields:[dynamic]Rpc_Field,
}

// The JSON object of key=value arguments: a value that parses as JSON is that
// JSON and any other is text, dots in a key make objects inside, and @file is
// the contents of a file that exists.
rpc_fields_params :: proc(args:[]string) -> (params,problem:string) {
    set :: proc(fields:^[dynamic]Rpc_Field,path:[]string,value:string) -> bool {
        for &field in fields {
            if field.name!=path[0] {continue}
            return len(path)>1 && field.value=="" && set(&field.fields,path[1:],value)
        }
        field:=Rpc_Field{name=path[0],fields=make([dynamic]Rpc_Field,context.temp_allocator)}
        if len(path)==1 {field.value=value}
        else if !set(&field.fields,path[1:],value) {return false}
        append(fields,field)
        return true
    }
    write :: proc(b:^strings.Builder,fields:[]Rpc_Field) {
        strings.write_byte(b,'{')
        for field,i in fields {
            if i>0 {strings.write_byte(b,',')}
            fmt.sbprintf(b,"%s:",serial.text_quote(field.name))
            if field.value!="" {strings.write_string(b,field.value)} else {write(b,field.fields[:])}
        }
        strings.write_byte(b,'}')
    }
    fields:=make([dynamic]Rpc_Field,context.temp_allocator)
    for arg in args {
        key,_,value:=strings.partition(arg,"=")
        path:=strings.split(key,".",context.temp_allocator)
        for name in path {
            if name=="" {return "",fmt.tprintf("'%s': a key is names joined by dots",key)}
        }
        file_value:=value
        if strings.has_prefix(file_value,"@") && len(file_value)>1 && os.is_file(file_value[1:]) {
            bytes,error:=os.read_entire_file_from_path(file_value[1:],context.temp_allocator)
            if error!=nil {return "",fmt.tprintf("'%s': the file could not be read",file_value[1:])}
            file_value=strings.trim_space(string(bytes))
        }
        json_value:=api.json_valid(context.temp_allocator,file_value)?file_value:serial.text_quote(file_value)
        if !set(&fields,path,json_value) {return "",fmt.tprintf("'%s' is given twice, or inside a field that has a value",key)}
    }
    b:=strings.builder_make(context.temp_allocator)
    write(&b,fields[:])
    return strings.to_string(b),""
}

// The result, or with selected the fields the server kept of it, each a line:
// a string without quotes, a number, true, false or null, and the rest as
// indented JSON.
rpc_print :: proc(result:string,selected:bool) -> int {
    if !selected {
        fmt.println(api.json_pretty(result,context.allocator))
        return 0
    }
    members,_:=api.json_members(result)
    for member in members {fmt.println(api.json_scalar_text(member.value))}
    return 0
}

// The error of a call with what to do next: a longer --timeout, or the
// methods whose names look like the one that does not exist.
@(private="file")
rpc_hint :: proc(connection:Connection,method:string,err:api.Error) -> api.Error {
    err:=err
    switch err.code {
    case api.TIMEOUT:
        err.message=fmt.tprintf("%s; --timeout S waits longer",err.message)
    case api.METHOD_NOT_FOUND:
        if similar:=rpc_similar(connection,method);similar!="" {
            err.message=fmt.tprintf("%s; similar: %s; mirai rpc describe <method> gives their params",err.message,similar)
        } else {
            err.message=fmt.tprintf("%s; mirai rpc describe lists the methods",err.message)
        }
    }
    return err
}

// The methods whose names look like name, of the editor that is called.
@(private="file")
rpc_similar :: proc(connection:Connection,name:string) -> string {
    result,_,called:=rpc_call_waiting(connection,"engine.describe","{}",2)
    if !called {return ""}
    return rpc_similar_names(result,name)
}

// Up to a dozen names of the methods engine.describe lists: those that
// contain the last word of name first, then the others of its namespace
// (scene. of scene.spawn).
rpc_similar_names :: proc(describe,name:string) -> string {
    dot:=strings.last_index_byte(name,'.')
    namespace:=name[:dot+1]
    word:=strings.to_lower(name[dot+1:],context.temp_allocator)
    first:=make([dynamic]string,context.temp_allocator)
    second:=make([dynamic]string,context.temp_allocator)
    for method_name in rpc_listed_names(describe) {
        switch {
        case word!="" && strings.contains(strings.to_lower(method_name,context.temp_allocator),word): append(&first,method_name)
        case namespace!="" && strings.has_prefix(method_name,namespace): append(&second,method_name)
        }
    }
    append(&first,..second[:])
    if len(first)>12 {return fmt.tprintf("%s and %d more",strings.join(first[:12],", ",context.temp_allocator),len(first)-12)}
    return strings.join(first[:],", ",context.temp_allocator)
}

// mirai rpc describe [plugin|method|prefix|method...]: without one, the
// methods by plugin and the plugins the project does not use; with the name
// of a plugin (editor for the editor), a method or the prefix of some, or
// several methods, those methods with their params, an example of valid
// params and their result.
@(private="file")
rpc_describe :: proc(connection:Connection,args:[]string) -> int {
    listing,err,called:=rpc_call_waiting(connection,"engine.describe","{}",1)
    if !called {return rpc_fail(err)}
    if len(args)==0 {
        fmt.print(rpc_describe_list_text(listing))
        return 0
    }
    result:string
    if len(args)>1 {
        names:=make([]string,len(args),context.temp_allocator)
        for arg,i in args {names[i]=serial.text_quote(arg)}
        result,err,called=rpc_call_waiting(connection,"engine.describe",fmt.tprintf(`{{"methods":[%s]}}`,strings.join(names,",",context.temp_allocator)),1)
        if !called {return rpc_fail(err)}
        fmt.print(rpc_describe_text(result,""))
        return 0
    }
    name:=args[0]
    key:=rpc_describe_is_plugin(listing,name)?"plugin":"prefix"
    params:=fmt.tprintf(`{{"%s":%s}}`,key,serial.text_quote(name))
    if slice.contains(rpc_listed_names(listing),name) {params=fmt.tprintf(`{{"methods":[%s]}}`,serial.text_quote(name))}
    result,err,called=rpc_call_waiting(connection,"engine.describe",params,1)
    if !called {
        if err.code!=api.INVALID_PARAMS || key=="plugin" {return rpc_fail(err)}
        message:=fmt.tprintf("no method starts with '%s'",name)
        if similar:=rpc_similar_names(listing,name);similar!="" {message=fmt.tprintf("%s; similar: %s",message,similar)}
        return rpc_fail({api.INVALID_PARAMS,fmt.tprintf("%s; mirai rpc describe without an argument lists them all",message),""})
    }
    fmt.print(rpc_describe_text(result,name))
    return 0
}

// The names of the methods of an answer of engine.describe: the entries of
// methods, or those of the index without params.
rpc_listed_names :: proc(describe:string) -> []string {
    names:=make([dynamic]string,context.temp_allocator)
    for key in ([]string{"methods","core"}) {
        entries,_:=api.json_elements(api.json_member(describe,key))
        for entry in entries {
            if name,ok:=api.json_string(api.json_member(entry,"name"));ok {append(&names,name)}
        }
    }
    groups,_:=api.json_elements(api.json_member(describe,"others"))
    for group in groups {
        text,_:=api.json_string(api.json_member(group,"methods"))
        for name in strings.fields(text,context.temp_allocator) {append(&names,name)}
    }
    return names[:]
}

// The names of a list of strings of the index of engine.describe.
@(private="file")
rpc_listed_strings :: proc(listing,key:string) -> []string {
    entries,_:=api.json_elements(api.json_member(listing,key))
    names:=make([dynamic]string,context.temp_allocator)
    for entry in entries {
        if name,ok:=api.json_string(entry);ok {append(&names,name)}
    }
    return names[:]
}

// Whether name is editor or a plugin engine.describe lists without params.
rpc_describe_is_plugin :: proc(listing,name:string) -> bool {
    return name=="editor" || slice.contains(rpc_listed_strings(listing,"active_plugins"),name) || slice.contains(rpc_listed_strings(listing,"other_plugins"),name)
}

// What mirai rpc describe prints without arguments: the core methods with
// what each is for, the names of the others by plugin and the plugins the
// project does not use.
rpc_describe_list_text :: proc(listing:string) -> string {
    core_methods,_:=api.json_elements(api.json_member(listing,"core"))
    width:=0
    for method in core_methods {
        name,_:=api.json_string(api.json_member(method,"name"))
        width=max(width,len(name))
    }
    b:=strings.builder_make(context.temp_allocator)
    if len(core_methods)>0 {strings.write_string(&b,"core\n")}
    for method in core_methods {
        name,_:=api.json_string(api.json_member(method,"name"))
        summary,_:=api.json_string(api.json_member(method,"summary"))
        fmt.sbprintf(&b,"  %s%s  %s\n",name,strings.repeat(" ",width-len(name),context.temp_allocator),summary)
    }
    groups,_:=api.json_elements(api.json_member(listing,"others"))
    for group in groups {
        plugin,_:=api.json_string(api.json_member(group,"plugin"))
        methods,_:=api.json_string(api.json_member(group,"methods"))
        if strings.builder_len(b)>0 {strings.write_byte(&b,'\n')}
        fmt.sbprintf(&b,"%s\n  %s\n",plugin,methods)
    }
    if inactive:=rpc_listed_strings(listing,"other_plugins");len(inactive)>0 {
        fmt.sbprintf(&b,"\ninactive plugins: %s\n",strings.join(inactive,", ",context.temp_allocator))
    }
    strings.write_string(&b,"\nmirai rpc describe <method> gives its params and result; <plugin> or <prefix> the summaries of an area.\n")
    return strings.to_string(b)
}

// What mirai rpc describe prints of the result of engine.describe: each
// method, or only the one named name when it is listed, with its params, an
// example of valid params and the fields of its result.
rpc_describe_text :: proc(result,name:string) -> string {
    methods,_:=api.json_elements(api.json_member(result,"methods"))
    exact:=false
    for method in methods {
        if method_name,_:=api.json_string(api.json_member(method,"name"));method_name==name {exact=true}
    }
    b:=strings.builder_make(context.temp_allocator)
    for method in methods {
        method_name,_:=api.json_string(api.json_member(method,"name"))
        if exact && method_name!=name {continue}
        if strings.builder_len(b)>0 {strings.write_byte(&b,'\n')}
        strings.write_string(&b,method_name)
        if flags,_:=api.json_elements(api.json_member(method,"flags"));len(flags)>0 {
            names:=make([]string,len(flags),context.temp_allocator)
            for flag,i in flags {names[i],_=api.json_string(flag)}
            fmt.sbprintf(&b," (%s)",strings.join(names,", ",context.temp_allocator))
        }
        strings.write_byte(&b,'\n')
        if summary,_:=api.json_string(api.json_member(method,"summary"));summary!="" {fmt.sbprintf(&b,"  %s\n",summary)}
        params:=api.json_member(method,"params")
        if params=="" {continue}
        api.describe_params(&b,params)
        api.describe_example(&b,method_name,params)
        result_schema:=api.json_member(method,"result")
        switch {
        case api.json_compact(api.json_member(result_schema,"properties"))!="" && api.json_compact(api.json_member(result_schema,"properties"))!="{}":
            strings.write_string(&b,"  result:\n")
            api.describe_fields(&b,result_schema,"",true,0)
        case api.json_compact(result_schema)=="{}" || result_schema=="":
            strings.write_string(&b,"  result: no schema; the catalog of the mirai-agent-api skill gives its shape\n")
        case:
            fmt.sbprintf(&b,"  result: %s\n",api.describe_type(result_schema))
        }
    }
    return strings.to_string(b)
}

// mirai rpc --stdin: one connection and one call per line of stdin,
// "method key=value..." or "method {json}", with the options of a call after
// it, so a script makes many calls in one process. One line of JSON on stdout
// per call: its result, or {"error":{...}} when it failed. Ends at the end of
// the input.
@(private="file")
rpc_stdin :: proc(connection:Connection) -> int {
    connection:=connection
    link:api.Client_Connection
    defer api.client_connection_close(&link)
    connection.link=&link
    pending:=make([dynamic]u8)
    chunk:[4096]u8
    arena:virtual.Arena
    if virtual.arena_init_growing(&arena)!=nil {fmt.eprintln("mirai rpc: no memory");return 1}
    line_memory:=virtual.arena_allocator(&arena)
    for {
        n,read_error:=os.read(os.stdin,chunk[:])
        if n>0 {append(&pending,..chunk[:n])}
        finished:=read_error!=nil || n==0
        for {
            end:=strings.index_byte(string(pending[:]),'\n')
            if end<0 && !(finished && len(pending)>0) {break}
            count:=end>=0?end:len(pending)
            rpc_stdin_line(connection,strings.trim_space(string(pending[:count])),line_memory)
            virtual.arena_free_all(&arena)
            free_all(context.temp_allocator)
            consumed:=end>=0?end+1:len(pending)
            remove_range(&pending,0,consumed)
        }
        if finished {break}
    }
    return 0
}

// Runs a line of --stdin and prints its answer as one line of JSON.
@(private="file")
rpc_stdin_line :: proc(connection:Connection,line:string,allocator:=context.allocator) {
    if line=="" {return}
    context.allocator=allocator
    answer :: proc(text:string) {fmt.println(api.json_single_line(text,context.allocator))}
    fail :: proc(err:api.Error) {answer(api.error_text(rpc_error_short(err),context.allocator))}
    request,problem,parsed:=rpc_stdin_request(line)
    if !parsed {
        if problem=="" {problem=fmt.tprintf("not a call: write method key=value... or method {{json}}, as: %s",line)}
        fail({api.INVALID_PARAMS,problem,""})
        return
    }
    params:=strings.trim_space(request.params)
    if !api.json_valid(context.allocator,params) || !params_is_object(params) {
        fail({api.INVALID_PARAMS,"params must be a JSON object: key=value arguments or one {...} after the method",""})
        return
    }
    result,err,called:=rpc_request_call(connection,request,params)
    if !called {
        fail(rpc_hint(connection,request.method,err))
        return
    }
    answer(result)
}

// A line of --stdin as what its arguments give: the JSON object is one
// argument whatever spaces it has, a "quoted value" keeps its spaces.
rpc_stdin_request :: proc(line:string) -> (request:Rpc_Request,problem:string,ok:bool) {
    args:=make([dynamic]string,context.temp_allocator)
    rest:=line
    if first:=strings.index_any(rest," \t");first>=0 {
        append(&args,rest[:first])
        rest=strings.trim_left_space(rest[first:])
    } else {
        append(&args,rest)
        rest=""
    }
    if strings.has_prefix(rest,"{") {
        r:serial.Text_Reader
        serial.text_reader_init(&r,rest,context.temp_allocator)
        serial.text_peek(&r)
        if serial.text_skip(&r) {
            append(&args,rest[:r.offset])
            rest=strings.trim_left_space(rest[r.offset:])
        } else {
            append(&args,rest)
            rest=""
        }
    }
    for len(rest)>0 {
        end:=0
        quoted:=false
        for end<len(rest) && (quoted || (rest[end]!=' ' && rest[end]!='\t')) {
            if rest[end]=='"' {quoted=!quoted}
            end+=1
        }
        arg:=rest[:end]
        // Whole quoted, as a --select with spaces; key="a b" keeps them for its JSON.
        if len(arg)>=2 && arg[0]=='"' && arg[len(arg)-1]=='"' {arg=arg[1:len(arg)-1]}
        append(&args,arg)
        rest=strings.trim_left_space(rest[end:])
    }
    for arg in args[1:] {
        if arg=="-" {return request,"params come on the line: key=value arguments or one {...} after the method",false}
    }
    return rpc_request(args[:])
}

// What the batch answered so far: each result, for the references of the calls after it.
// A string that is exactly $N or $N.path stands for that result or its field
// (the fields go as in --select); $$ begins a text that really starts with $.
@(private="file")
rpc_batch_value :: proc(value:json.Value,results:[]string) -> (out:json.Value,problem:string) {
    #partial switch v in value {
    case json.String:
        text:=string(v)
        if strings.has_prefix(text,"$$") {return json.String(text[1:]),""}
        if len(text)<2 || text[0]!='$' || text[1]<'0' || text[1]>'9' {return value,""}
        rest:=text[1:]
        end:=strings.index_any(rest,".[")
        digits:=end<0?rest:rest[:end]
        n,valid:=strconv.parse_int(digits,10)
        if !valid {return value,""}
        if n<0 || n>=len(results) {return nil,fmt.tprintf("%s: the batch has %d results so far, $0 to $%d",text,len(results),len(results)-1)}
        raw:=results[n]
        if end>=0 {
            field:=rest[end:]
            if field[0]=='.' {field=field[1:]}
            path,ok:=api.json_path_parse(field)
            if !ok {return nil,fmt.tprintf("%s: %q is not a field path as --select takes it",text,field)}
            found,missing:=api.json_at(raw,path)
            if missing!="" {return nil,fmt.tprintf("%s: %s",text,missing)}
            raw=found
        }
        parsed,parse_error:=json.parse(transmute([]u8)raw,parse_integers=true,allocator=context.temp_allocator)
        if parse_error!=nil {return nil,fmt.tprintf("%s: the result is not JSON",text)}
        return parsed,""
    case json.Object:
        resolved:=make(json.Object,len(v),context.temp_allocator)
        for key,element in v {
            resolved[key],problem=rpc_batch_value(element,results)
            if problem!="" {return nil,problem}
        }
        return resolved,""
    case json.Array:
        for &element in v {
            element,problem=rpc_batch_value(element,results)
            if problem!="" {return nil,problem}
        }
        return v,""
    }
    return value,""
}

// mirai rpc --batch <file>: one call per line, {"method": "...", "params": {...}},
// in order and over the same editor; prints a JSON array with the result or
// the error of each and stops at the first error. A value of the params that
// is exactly $N or $N.path (the same paths as --select) stands for the result
// of the call N of the batch or for that field of it; $$ writes a literal $.
@(private="file")
rpc_batch :: proc(connection:Connection,file:string) -> int {
    data,error:=os.read_entire_file(file,context.allocator)
    if error!=nil {fmt.eprintfln("mirai rpc: could not read %s",file);return 2}
    Line :: struct {method:string,params:json.Value}
    out:=strings.builder_make()
    strings.write_string(&out,"[")
    results:=make([dynamic]string)
    id:=0
    failed:=false
    text:=string(data)
    for line in strings.split_lines_iterator(&text) {
        trimmed:=strings.trim_space(line)
        if trimmed=="" {continue}
        call:Line
        if json.unmarshal_string(trimmed,&call,allocator=context.temp_allocator)!=nil || call.method=="" {
            fmt.eprintfln("mirai rpc: line %d is not {\"method\": ..., \"params\": {...}}",id+1)
            return 2
        }
        params:="{}"
        id+=1
        if id>1 {strings.write_string(&out,",")}
        if call.params!=nil {
            resolved,problem:=rpc_batch_value(call.params,results[:])
            if problem!="" {
                fmt.sbprintf(&out,"\n{{\"method\": %q, \"error\": %q}}",call.method,api.error_text({api.INVALID_PARAMS,problem,""},context.temp_allocator))
                failed=true
                break
            }
            encoded,marshal_error:=json.marshal(resolved,allocator=context.temp_allocator)
            if marshal_error!=nil {return 2}
            params=string(encoded)
        }
        result,err,called:=rpc_call_waiting(connection,call.method,params,id)
        if called {
            append(&results,result)
            fmt.sbprintf(&out,"\n{{\"method\": %q, \"result\": %s}}",call.method,result)
        } else {
            fmt.sbprintf(&out,"\n{{\"method\": %q, \"error\": %q}}",call.method,api.error_text(rpc_error_short(err),context.temp_allocator))
            failed=true
            break
        }
    }
    strings.write_string(&out,"\n]")
    fmt.println(strings.to_string(out))
    return failed?1:0
}

params_is_object :: proc(text:string) -> bool {
    for c in transmute([]u8)text {
        switch c {
        case ' ','\t','\n','\r': continue
        case '{': return true
        case: return false
        }
    }
    return false
}

rpc_fail :: proc(err:api.Error) -> int {
    fmt.eprintln(api.error_text(rpc_error_short(err),context.allocator))
    return 1
}

// An error as it is shown: data that echoes a large result becomes its first
// bytes and the size of the rest. What a method takes is shown whole.
rpc_error_short :: proc(err:api.Error) -> api.Error {
    prefix,omitted:=api.text_cut(err.data,RPC_ECHO_BYTES)
    if omitted==0 || api.json_member(err.data,"usage")!="" {return err}
    short:=err
    short.data=fmt.tprintf(`{{"prefix":%s,"omitted_bytes":%d}}`,serial.text_quote(prefix),omitted)
    return short
}

read_stdin :: proc() -> string {
    data:[dynamic]u8
    chunk:[4096]u8
    for {
        n,err:=os.read(os.stdin,chunk[:])
        if n>0 {append(&data,..chunk[:n])}
        if err!=nil || n==0 {break}
    }
    return string(data[:])
}
