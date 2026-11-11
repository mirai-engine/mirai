package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:cook/workspace"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

RPC_USAGE :: "rpc <method> [key=value...|json|-|--file F] [--select FIELDS] [--wait-until CONDITION] | rpc describe [plugin|method|prefix|method...] [--project P|--port N] [--timeout S] [--client NAME]"

RPC_ENDING_WAIT :: 3*time.Second // how long an editor that stopped listening may go on counting as alive
RPC_RESTART_PAUSE :: 250*time.Millisecond // between the calls of a --wait-until whose editor restarts
RPC_WAIT_MARGIN_MS :: 5000 // a --wait-until reads the answer past its limit: the server says what it last saw

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
    fmt.eprintfln("mirai: %s has no open editor; starting its headless session (mirai session start %s)",connection.project,connection.project)
    self,error:=os.get_executable_path(context.temp_allocator)
    if error!=nil {return {api.UNREACHABLE,fmt.tprintf("could not start the session of %s: %v",connection.project,error),""}}
    if run_with(connection.root,{self,"session","start",connection.project},os.stderr)!=0 {
        return {api.UNREACHABLE,fmt.tprintf("mirai session start %s failed; what it said is above",connection.project),""}
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
        result,err,called=api.rpc_call(editor.port,method,params,id,connection.timeout_ms,context.allocator,connection_task(connection,editor.port),connection.client,watch,workspace.measurement(context.temp_allocator))
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
    if !called {return rpc_fail(rpc_hint(err))}
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
    values:=make([dynamic]string,context.temp_allocator)
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
            case !positional(arg) && arg!="-": return request,fmt.tprintf("'%s' is not an option of rpc; a value that starts with '-' goes in key=value or JSON params",arg),false
            case rpc_field_arg(arg):           append(&fields,arg)
            case:                              append(&values,arg)
            }
        }
    }
    if len(values)==0 || len(values)>2 || (len(values)==2 && file!="") {return request,"",false}
    request.method=values[0]
    if len(fields)>0 {
        if len(values)==2 || file!="" {return request,"key=value arguments and a JSON object do not go together",false}
        request.params,problem=rpc_fields_params(fields[:])
        return request,problem,problem==""
    }
    switch {
    case len(values)==2 && values[1]=="-": request.params=read_stdin()
    case len(values)==2: request.params=values[1]
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

// The error of a call with what to do next.
@(private="file")
rpc_hint :: proc(err:api.Error) -> api.Error {
    err:=err
    switch err.code {
    case api.TIMEOUT:
        err.message=fmt.tprintf("%s; --timeout S waits longer",err.message)
    case api.METHOD_NOT_FOUND:
        err.message=fmt.tprintf("%s; mirai rpc describe lists the methods and gives their params",err.message)
    }
    return err
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
        if similar:=api.names_similar(rpc_listed_names(listing),name,context.temp_allocator);similar!="" {message=fmt.tprintf("%s; similar: %s",message,similar)}
        return rpc_fail({api.INVALID_PARAMS,fmt.tprintf("%s; mirai rpc describe without an argument lists them all",message),""})
    }
    fmt.print(rpc_describe_text(result,name))
    return 0
}

// An answer of engine.describe; what does not read as one has nothing.
rpc_describe_read :: proc(text:string) -> (describe:api.Describe_Result) {
    serial.text_decode(text,&describe,context.temp_allocator,skip_unknown=true)
    return
}

// The texts of a list of text fields.
@(private="file")
rpc_texts :: proc(list:[][$N]u8) -> []string {
    texts:=make([]string,len(list),context.temp_allocator)
    for &text,i in list {texts[i]=base.text_get(text[:])}
    return texts
}

// The names of the methods of an answer of engine.describe: the entries of
// methods, or those of the index without params.
rpc_listed_names :: proc(describe:string) -> []string {
    d:=rpc_describe_read(describe)
    names:=make([dynamic]string,context.temp_allocator)
    for &method in d.methods {append(&names,base.text_get(method.name[:]))}
    for &method in d.core {append(&names,base.text_get(method.name[:]))}
    for &group in d.others {append(&names,..strings.fields(base.text_get(group.methods[:]),context.temp_allocator))}
    return names[:]
}

// Whether name is editor or a plugin engine.describe lists without params.
rpc_describe_is_plugin :: proc(listing,name:string) -> bool {
    d:=rpc_describe_read(listing)
    return name=="editor" || slice.contains(rpc_texts(d.active_plugins),name) || slice.contains(rpc_texts(d.other_plugins),name)
}

// What mirai rpc describe prints without arguments: the core methods with
// what each is for, the names of the others by plugin and the plugins the
// project does not use.
rpc_describe_list_text :: proc(listing:string) -> string {
    d:=rpc_describe_read(listing)
    width:=0
    for &method in d.core {width=max(width,len(base.text_get(method.name[:])))}
    b:=strings.builder_make(context.temp_allocator)
    if len(d.core)>0 {strings.write_string(&b,"core\n")}
    for &method in d.core {
        name:=base.text_get(method.name[:])
        fmt.sbprintf(&b,"  %s%s  %s\n",name,strings.repeat(" ",width-len(name),context.temp_allocator),base.text_get(method.summary[:]))
    }
    for &group in d.others {
        if strings.builder_len(b)>0 {strings.write_byte(&b,'\n')}
        fmt.sbprintf(&b,"%s\n  %s\n",base.text_get(group.plugin[:]),base.text_get(group.methods[:]))
    }
    if inactive:=rpc_texts(d.other_plugins);len(inactive)>0 {
        fmt.sbprintf(&b,"\ninactive plugins: %s\n",strings.join(inactive,", ",context.temp_allocator))
    }
    strings.write_string(&b,"\nmirai rpc describe <method> gives its params and result; <plugin> or <prefix> the summaries of an area.\n")
    return strings.to_string(b)
}

// What mirai rpc describe prints of the result of engine.describe: each
// method, or only the one named name when it is listed, with its params, an
// example of valid params and the fields of its result.
rpc_describe_text :: proc(result,name:string) -> string {
    methods:=rpc_describe_read(result).methods
    exact:=false
    for &method in methods {exact||=base.text_get(method.name[:])==name}
    b:=strings.builder_make(context.temp_allocator)
    for &method in methods {
        method_name:=base.text_get(method.name[:])
        if exact && method_name!=name {continue}
        if strings.builder_len(b)>0 {strings.write_byte(&b,'\n')}
        strings.write_string(&b,method_name)
        if len(method.flags)>0 {fmt.sbprintf(&b," (%s)",strings.join(rpc_texts(method.flags),", ",context.temp_allocator))}
        strings.write_byte(&b,'\n')
        if summary:=base.text_get(method.summary[:]);summary!="" {fmt.sbprintf(&b,"  %s\n",summary)}
        params,result_schema:=string(method.params),string(method.result)
        if params=="" {continue}
        api.describe_params(&b,params)
        api.describe_example(&b,method_name,params)
        switch properties:=api.json_compact(api.json_member(result_schema,"properties"));{
        case properties!="" && properties!="{}":
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
    fmt.eprintln(api.error_text(err,context.allocator))
    return 1
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
