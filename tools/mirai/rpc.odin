package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/serial"

RPC_USAGE :: "rpc <method> [json|-|--file F] [--select FIELDS] [--wait-until CONDITION [--every S]] | rpc describe [plugin|method|prefix|method...] | rpc --batch <calls.jsonl> [--project P|--port N] [--timeout S] [--wait S] [--client NAME]"

// How often --wait-until calls again without --every, in milliseconds.
RPC_EVERY_MS :: 1000
RPC_ECHO_BYTES :: 240 // of a result or a list of names an error repeats
RPC_BRIEF_BYTES :: 80 // of a value inside a message

Connection :: struct {
    port,timeout_ms:int,
    wait_ms:int, // how long to retry while nobody listens
    agent:Agent_Environment, // the task context the calls to the editor of that port belong to
    project:string, // with --project and no --port: whose api.json names the port, read again on every attempt
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

// --port N, --project P, --timeout SECONDS, --wait SECONDS and --client NAME;
// everything else is returned in order. Without --port, the port is the one
// of the editor of --project (api.PORT_FILE), or that of agent, or of the
// project in the working directory, or api.DEFAULT_PORT; never the default
// one for --project.
connection_args :: proc(args:[]string,agent:Agent_Environment) -> (connection:Connection,ok:bool) {
    connection={port=0,timeout_ms=30000,agent=agent}
    folder:=""
    for i:=0;i<len(args);i+=1 {
        switch args[i] {
        case "--port","--timeout","--wait":
            if i+1>=len(args) {return}
            value,valid:=strconv.parse_int(args[i+1],10)
            if !valid || value<=0 || (args[i]=="--port" && value>65535) {return}
            switch args[i] {
            case "--port":    connection.port=value
            case "--timeout": connection.timeout_ms=value*1000
            case "--wait":    connection.wait_ms=value*1000
            }
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
            connection.project=project.path_absolute(folder)
            return connection,true
        }
        connection.port=agent.port
        if connection.port==0 && os.is_file(project.PROJECT_FILE) {
            if file,alive:=session_find(project.path_absolute(".",context.temp_allocator));alive {connection.port=file.port}
        }
        if connection.port==0 {connection.port=api.DEFAULT_PORT}
    }
    return connection,true
}

// The port to call now: with --project, the one its api.json names, or 0
// while it has no editor.
connection_port :: proc(connection:Connection) -> int {
    if connection.project=="" {return connection.port}
    if file,alive:=session_find(connection.project);alive {return file.port}
    return 0
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
no_editor_text :: proc(project:string,allocator:=context.temp_allocator) -> string {
    return fmt.aprintf("%s has no open editor: mirai session start %s",project,project,allocator=allocator)
}

// One call, retried while nobody listens and the wait allows.
rpc_call_waiting :: proc(connection:Connection,method,params:string,id:int) -> (result:string,err:api.Error,called:bool) {
    start:=time.tick_now()
    for {
        if port:=connection_port(connection);port!=0 {
            result,err,called=api.rpc_call(port,method,params,id,connection.timeout_ms,context.allocator,connection_task(connection,port),connection.client)
        } else {
            err={api.UNREACHABLE,no_editor_text(connection.project,context.allocator),""}
        }
        if called || err.code!=api.UNREACHABLE || time.duration_milliseconds(time.tick_since(start))>=f64(connection.wait_ms) {return}
        time.sleep(250*time.Millisecond)
    }
}

// A call of mirai rpc and what it does with the result: the fields it
// prints and the condition it calls again until.
Rpc_Request :: struct {
    method,params:string,
    select:[dynamic]Json_Path,
    until:Rpc_Condition,
    waits:bool,
    every_ms:int,
}

cmd_rpc :: proc(root:string,args:[]string) -> int {
    connection,ok:=connection_args(args,agent_environment())
    if connection.client=="" {connection.client=client_environment()}
    if !ok || len(connection.rest)==0 {
        fmt.eprintfln("Usage: mirai %s",RPC_USAGE)
        return 2
    }
    switch connection.rest[0] {
    case "--batch":
        if len(connection.rest)!=2 {fmt.eprintfln("Usage: mirai %s",RPC_USAGE);return 2}
        return rpc_batch(connection,connection.rest[1])
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
        return rpc_fail({api.INVALID_PARAMS,"params must be a JSON object: '{...}' as one argument, - to read it from stdin, or --file F",""})
    }
    if request.waits {return rpc_wait(connection,request,params)}
    result,err,called:=rpc_call_waiting(connection,request.method,params,1)
    if !called {return rpc_fail(rpc_hint(connection,request.method,err))}
    return rpc_print(result,request.select[:])
}

// The method, its params and what to do with the result, from what
// connection_args left. problem says what is wrong, unless it is plain misuse.
rpc_request :: proc(args:[]string) -> (request:Rpc_Request,problem:string,ok:bool) {
    request.params="{}"
    request.every_ms=RPC_EVERY_MS
    request.select=make([dynamic]Json_Path,context.temp_allocator)
    positional:=make([dynamic]string,context.temp_allocator)
    file:=""
    every:=false
    for i:=0;i<len(args);i+=1 {
        arg:=args[i]
        switch arg {
        case "--select","--wait-until","--every","--file":
            if i+1>=len(args) {return request,fmt.tprintf("%s needs a value",arg),false}
            i+=1
            value:=args[i]
            switch arg {
            case "--select":
                for part in strings.split(value,",",context.temp_allocator) {
                    path,valid:=json_path_parse(strings.trim_space(part))
                    if !valid {return request,fmt.tprintf("--select: '%s' is not a field: names separated by dots and [i] for element i, from the end when negative (a.b,c[0].d,[-1])",part),false}
                    append(&request.select,path)
                }
            case "--wait-until":
                condition,valid:=rpc_condition_parse(value)
                if !valid {return request,fmt.tprintf("--wait-until: '%s' is not <field><op><value>: op is =, !=, <, <=, > or >=, and the last four compare numbers (phase=Done, errors>0)",value),false}
                request.until,request.waits=condition,true
            case "--every":
                seconds,valid:=strconv.parse_f64(value)
                if !valid || !(seconds>0) || seconds>3600 {return request,fmt.tprintf("--every needs seconds greater than 0 and up to 3600, not '%s'",value),false}
                request.every_ms=max(int(seconds*1000),1)
                every=true
            case "--file":
                file=value
            }
        case:
            if strings.has_prefix(arg,"--") {return request,fmt.tprintf("unknown option '%s'",arg),false}
            append(&positional,arg)
        }
    }
    if every && !request.waits {return request,"--every is the interval of --wait-until",false}
    if len(positional)==0 || len(positional)>2 || (len(positional)==2 && file!="") {return request,"",false}
    request.method=positional[0]
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

// The result, or the fields of it select names, each a line: a string
// without quotes, a number, true, false or null, and the rest as indented JSON.
rpc_print :: proc(result:string,select:[]Json_Path) -> int {
    if len(select)==0 {
        fmt.println(api.json_pretty(result,context.allocator))
        return 0
    }
    values:=make([]string,len(select),context.temp_allocator)
    for path,i in select {
        value,problem:=json_at(result,path)
        if problem!="" {return rpc_fail({api.INVALID_PARAMS,fmt.tprintf("--select %s: %s",path.text,problem),strings.concatenate({`{"result":`,result,"}"},context.temp_allocator)})}
        values[i]=value
    }
    for value in values {fmt.println(json_scalar_text(value))}
    return 0
}

// Calls every request.every_ms until the field of the condition meets it,
// for at most --timeout in all, and prints the result that met it. An editor
// that does not answer, or that ends while it answers, is waited for: Build
// restarts it, and the call is made again anyway.
@(private="file")
rpc_wait :: proc(connection:Connection,request:Rpc_Request,params:string) -> int {
    start:=time.tick_now()
    elapsed :: proc(start:time.Tick) -> int {return int(time.duration_milliseconds(time.tick_since(start)))}
    last:=""
    last_error:api.Error
    for id:=1;;id+=1 {
        remaining:=connection.timeout_ms-elapsed(start)
        if remaining<=0 {break}
        attempt:=connection
        attempt.timeout_ms=remaining
        attempt.wait_ms=min(connection.wait_ms,remaining)
        result,err,called:=rpc_call_waiting(attempt,request.method,params,id)
        switch {
        case called:
            value,problem:=json_at(result,request.until.path)
            if problem!="" {return rpc_fail({api.INVALID_PARAMS,fmt.tprintf("--wait-until %s: %s",request.until.text,problem),strings.concatenate({`{"result":`,result,"}"},context.temp_allocator)})}
            met,mismatch:=rpc_condition_met(request.until,value)
            if mismatch!="" {return rpc_fail({api.INVALID_PARAMS,fmt.tprintf("--wait-until %s: %s",request.until.text,mismatch),""})}
            if met {return rpc_print(result,request.select[:])}
            last,last_error=value,{}
        case err.code==api.UNREACHABLE || err.code==api.TIMEOUT || err.code==api.CLOSED:
            last_error=err
        case:
            return rpc_fail(rpc_hint(connection,request.method,err))
        }
        if pause:=min(request.every_ms,connection.timeout_ms-elapsed(start));pause>0 {time.sleep(time.Duration(pause)*time.Millisecond)}
    }
    message:=fmt.tprintf("%s did not meet %s in %d s",request.method,request.until.text,connection.timeout_ms/1000)
    data:=""
    if last!="" {
        message=fmt.tprintf("%s: %s is %s",message,request.until.path.text,json_brief(last))
        data=strings.concatenate({`{"field":`,serial.text_quote(request.until.path.text),`,"value":`,last,"}"},context.temp_allocator)
    }
    if last_error.code!=0 {message=fmt.tprintf("%s; the last call: %s",message,last_error.message)}
    return rpc_fail({api.TIMEOUT,fmt.tprintf("%s; --timeout S waits longer",message),data})
}

// The error of a call with what to do next: a longer --timeout, or the
// methods whose names look like the one that does not exist.
@(private="file")
rpc_hint :: proc(connection:Connection,method:string,err:api.Error) -> api.Error {
    err:=err
    switch err.code {
    case api.TIMEOUT:
        err.message=fmt.tprintf("%s; --timeout S waits longer (now %d s)",err.message,connection.timeout_ms/1000)
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
    methods,_:=json_elements(json_member(describe,"methods"))
    first:=make([dynamic]string,context.temp_allocator)
    second:=make([dynamic]string,context.temp_allocator)
    for method in methods {
        method_name,_:=json_string(json_member(method,"name"))
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
    result,err,called=rpc_call_waiting(connection,"engine.describe",fmt.tprintf(`{{"%s":%s}}`,key,serial.text_quote(name)),1)
    if !called {
        if err.code!=api.INVALID_PARAMS || key=="plugin" {return rpc_fail(err)}
        message:=fmt.tprintf("no method starts with '%s'",name)
        if similar:=rpc_similar_names(listing,name);similar!="" {message=fmt.tprintf("%s; similar: %s",message,similar)}
        return rpc_fail({api.INVALID_PARAMS,fmt.tprintf("%s; mirai rpc describe without an argument lists them all",message),""})
    }
    fmt.print(rpc_describe_text(result,name))
    return 0
}

// Whether name is editor or a plugin engine.describe lists without params.
rpc_describe_is_plugin :: proc(listing,name:string) -> bool {
    if name=="editor" {return true}
    plugins,_:=json_elements(json_member(listing,"plugins"))
    for plugin in plugins {
        if plugin_name,_:=json_string(json_member(plugin,"name"));plugin_name==name {return true}
    }
    return false
}

// What mirai rpc describe prints without arguments: the methods of each
// plugin under its name, editor first, and the plugins the project does not use.
rpc_describe_list_text :: proc(listing:string) -> string {
    methods,_:=json_elements(json_member(listing,"methods"))
    groups:=make([dynamic]string,context.temp_allocator)
    append(&groups,"editor")
    width:=0
    for method in methods {
        name,_:=json_string(json_member(method,"name"))
        plugin,_:=json_string(json_member(method,"plugin"))
        width=max(width,len(name))
        known:=false
        for group in groups {if group==plugin {known=true;break}}
        if !known && plugin!="" {append(&groups,plugin)}
    }
    b:=strings.builder_make(context.temp_allocator)
    for group in groups {
        listed:=false
        for method in methods {
            name,_:=json_string(json_member(method,"name"))
            plugin,_:=json_string(json_member(method,"plugin"))
            if plugin!=group && !(group=="editor" && plugin=="") {continue}
            if !listed {
                if strings.builder_len(b)>0 {strings.write_byte(&b,'\n')}
                fmt.sbprintf(&b,"%s\n",group)
                listed=true
            }
            summary,_:=json_string(json_member(method,"summary"))
            fmt.sbprintf(&b,"  %s%s  %s\n",name,strings.repeat(" ",width-len(name),context.temp_allocator),summary)
        }
    }
    inactive:=make([dynamic]string,context.temp_allocator)
    plugins,_:=json_elements(json_member(listing,"plugins"))
    for plugin in plugins {
        if json_compact(json_member(plugin,"active"))=="true" {continue}
        name,_:=json_string(json_member(plugin,"name"))
        append(&inactive,name)
    }
    if len(inactive)>0 {fmt.sbprintf(&b,"\ninactive plugins: %s\n",strings.join(inactive[:],", ",context.temp_allocator))}
    return strings.to_string(b)
}

// What mirai rpc describe prints of the result of engine.describe: each
// method, or only the one named name when it is listed, with its params, an
// example of valid params and the fields of its result.
rpc_describe_text :: proc(result,name:string) -> string {
    methods,_:=json_elements(json_member(result,"methods"))
    exact:=false
    for method in methods {
        if method_name,_:=json_string(json_member(method,"name"));method_name==name {exact=true}
    }
    b:=strings.builder_make(context.temp_allocator)
    for method in methods {
        method_name,_:=json_string(json_member(method,"name"))
        if exact && method_name!=name {continue}
        if strings.builder_len(b)>0 {strings.write_byte(&b,'\n')}
        strings.write_string(&b,method_name)
        if flags,_:=json_elements(json_member(method,"flags"));len(flags)>0 {
            names:=make([]string,len(flags),context.temp_allocator)
            for flag,i in flags {names[i],_=json_string(flag)}
            fmt.sbprintf(&b," (%s)",strings.join(names,", ",context.temp_allocator))
        }
        strings.write_byte(&b,'\n')
        if summary,_:=json_string(json_member(method,"summary"));summary!="" {fmt.sbprintf(&b,"  %s\n",summary)}
        params:=json_member(method,"params")
        properties:=json_member(params,"properties")
        switch {
        case properties=="": strings.write_string(&b,"  params: no schema; the summary says which it reads, if any\n")
        case json_compact(properties)=="{}": strings.write_string(&b,"  params: none\n")
        case:
            strings.write_string(&b,"  params:\n")
            rpc_describe_fields(&b,params,"",false,0)
        }
        example:=strings.builder_make(context.temp_allocator)
        rpc_schema_example(&example,params,0)
        fmt.sbprintf(&b,"  example: mirai rpc %s '%s'\n",method_name,strings.to_string(example))
        result_schema:=json_member(method,"result")
        switch {
        case json_compact(json_member(result_schema,"properties"))!="" && json_compact(json_member(result_schema,"properties"))!="{}":
            strings.write_string(&b,"  result:\n")
            rpc_describe_fields(&b,result_schema,"",true,0)
        case json_compact(result_schema)=="{}" || result_schema=="":
            strings.write_string(&b,"  result: no schema; the catalog of the mirai-agent-api skill gives its shape\n")
        case:
            fmt.sbprintf(&b,"  result: %s\n",rpc_schema_type(result_schema))
        }
    }
    return strings.to_string(b)
}

// A line per field of an object schema, after it those of an object inside,
// with their path (a.b, or a[].b for the objects of an array).
@(private="file")
rpc_describe_fields :: proc(b:^strings.Builder,schema,prefix:string,result:bool,depth:int) {
    properties,_:=json_members(json_member(schema,"properties"))
    required,_:=json_elements(json_member(schema,"required"))
    for property in properties {
        path:=prefix==""?property.name:fmt.tprintf("%s.%s",prefix,property.name)
        fmt.sbprintf(b,"    %s: %s",path,rpc_schema_type(property.value))
        if !result {
            needed:=false
            for field in required {
                if text,_:=json_string(field);text==property.name {needed=true}
            }
            if needed {
                strings.write_string(b,", required")
            } else if default:=json_member(property.value,"default");default!="" {
                fmt.sbprintf(b,", default %s",json_compact(default))
            } else if each:=json_member(json_member(property.value,"items"),"default");each!="" {
                fmt.sbprintf(b,", default %s each",json_compact(each))
            }
        }
        if description,_:=json_string(json_member(property.value,"description"));description!="" {fmt.sbprintf(b,". %s",description)}
        strings.write_byte(b,'\n')
        if depth>=4 {continue}
        if json_member(property.value,"properties")!="" {
            rpc_describe_fields(b,property.value,path,result,depth+1)
        } else if items:=json_member(property.value,"items");json_member(items,"properties")!="" {
            rpc_describe_fields(b,items,fmt.tprintf("%s[]",path),result,depth+1)
        }
    }
}

// The type of a JSON Schema in a few words, with its unit: integer 0..3600,
// number[3] m, string up to 64, list of A|B, entity id.
rpc_schema_type :: proc(schema:string) -> string {
    text:=rpc_schema_words(schema)
    unit,_:=json_string(json_member(schema,"x-unit"))
    return unit==""?text:fmt.tprintf("%s %s",text,unit)
}

@(private="file")
rpc_schema_words :: proc(schema:string) -> string {
    if names,_:=json_elements(json_member(schema,"enum"));len(names)>0 {return rpc_names(names[:])}
    if constant:=json_member(schema,"const");constant!="" {return json_compact(constant)}
    type:=json_member(schema,"type")
    kind,_:=json_string(type)
    switch kind {
    case "integer","number":
        lo,hi:=json_member(schema,"minimum"),json_member(schema,"maximum")
        switch {
        case kind=="integer" && rpc_integer_natural(lo,hi): return kind
        case lo!="" && hi!="": return fmt.tprintf("%s %s..%s",kind,lo,hi)
        case lo!="": return fmt.tprintf("%s >= %s",kind,lo)
        case hi!="": return fmt.tprintf("%s <= %s",kind,hi)
        }
        return kind
    case "string":
        pattern,_:=json_string(json_member(schema,"pattern"))
        switch pattern {
        case "^(0x)?[0-9a-fA-F]{1,16}$": return "entity id (up to 16 hex)"
        case "^[0-9a-fA-F]{32}$":        return "asset id (32 hex)"
        case "^0x[0-9a-fA-F]{32}$":      return "128-bit integer (0x and 32 hex)"
        }
        if size:=json_member(schema,"maxLength");size!="" {return fmt.tprintf("string up to %s",size)}
        return "string"
    case "boolean","null":
        return kind
    case "object":
        return "object"
    case "array":
        items:=json_member(schema,"items")
        item:=items!=""?rpc_schema_type(items):"JSON"
        lo,hi:=json_member(schema,"minItems"),json_member(schema,"maxItems")
        switch {
        case lo!="" && lo==hi: return strings.contains(item," ")?fmt.tprintf("(%s)[%s]",item,lo):fmt.tprintf("%s[%s]",item,lo)
        case hi!="": return fmt.tprintf("list of %s, up to %s",item,hi)
        }
        return fmt.tprintf("list of %s",item)
    }
    if kinds,is_list:=json_elements(type);is_list && len(kinds)>0 {return rpc_names(kinds[:])}
    return "JSON"
}

// Names of an enum or of the types of a schema as A|B|C; past 16, how many there are.
@(private="file")
rpc_names :: proc(values:[]string) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for value in values[:min(len(values),16)] {
        text,is_text:=json_string(value)
        append(&names,is_text?text:json_compact(value))
    }
    joined:=strings.join(names[:],"|",context.temp_allocator)
    return len(values)>16?fmt.tprintf("%s|... (%d in all)",joined,len(values)):joined
}

// Whether lo..hi is the whole range of an integer type, which says nothing.
@(private="file")
rpc_integer_natural :: proc(lo,hi:string) -> bool {
    ranges:=[?][2]string{
        {"-128","127"},{"0","255"},{"-32768","32767"},{"0","65535"},
        {"-2147483648","2147483647"},{"0","4294967295"},
        {"-9223372036854775808","9223372036854775807"},{"0","18446744073709551615"},
    }
    for range in ranges {
        if range[0]==lo && range[1]==hi {return true}
    }
    return false
}

// Valid JSON for a schema: its default, its first name, or the least value
// of its type its bounds allow; for an object, its required fields.
rpc_schema_example :: proc(b:^strings.Builder,schema:string,depth:int) {
    if default:=json_member(schema,"default");default!="" {strings.write_string(b,json_compact(default));return}
    if names,_:=json_elements(json_member(schema,"enum"));len(names)>0 {strings.write_string(b,json_compact(names[0]));return}
    if constant:=json_member(schema,"const");constant!="" {strings.write_string(b,json_compact(constant));return}
    kind,_:=json_string(json_member(schema,"type"))
    switch kind {
    case "boolean": strings.write_string(b,"false")
    case "null":    strings.write_string(b,"null")
    case "integer","number":
        lo,hi:=json_member(schema,"minimum"),json_member(schema,"maximum")
        value:="0"
        if low,valid:=strconv.parse_f64(lo);valid && low>0 {
            value=lo
        } else if high,high_valid:=strconv.parse_f64(hi);high_valid && high<0 {
            value=hi
        }
        strings.write_string(b,value)
    case "string":
        pattern,_:=json_string(json_member(schema,"pattern"))
        switch pattern {
        case "^(0x)?[0-9a-fA-F]{1,16}$": strings.write_string(b,`"0000000000000001"`)
        case "^[0-9a-fA-F]{32}$":        strings.write_string(b,`"00000000000000000000000000000001"`)
        case "^0x[0-9a-fA-F]{32}$":      strings.write_string(b,`"0x00000000000000000000000000000000"`)
        case:                            strings.write_string(b,`"x"`)
        }
    case "array":
        count,_:=strconv.parse_int(json_member(schema,"minItems"),10)
        strings.write_byte(b,'[')
        for i in 0..<count {
            if i>0 {strings.write_byte(b,',')}
            rpc_schema_example(b,json_member(schema,"items"),depth+1)
        }
        strings.write_byte(b,']')
    case:
        strings.write_byte(b,'{')
        properties,_:=json_members(json_member(schema,"properties"))
        required,_:=json_elements(json_member(schema,"required"))
        first:=true
        for field in required {
            if depth>=8 {break}
            name,_:=json_string(field)
            for property in properties {
                if property.name!=name {continue}
                if !first {strings.write_byte(b,',')}
                first=false
                fmt.sbprintf(b,"%s:",serial.text_quote(name))
                rpc_schema_example(b,property.value,depth+1)
            }
        }
        strings.write_byte(b,'}')
    }
}

// <field><op><value> of --wait-until.
Rpc_Condition :: struct {
    text:string,
    path:Json_Path,
    op:Rpc_Operator,
    value:string,
}

Rpc_Operator :: enum u8 {Equal,Not_Equal,Less,Less_Equal,Greater,Greater_Equal}

// The field, the operator (=, ==, !=, <, <=, >, >=) and the value; the
// operators of order need a number.
rpc_condition_parse :: proc(text:string) -> (condition:Rpc_Condition,ok:bool) {
    at:=strings.index_any(text,"=!<>")
    if at<=0 {return}
    rest:=text[at:]
    size:=2
    switch {
    case strings.has_prefix(rest,"!="): condition.op=.Not_Equal
    case strings.has_prefix(rest,"=="): condition.op=.Equal
    case strings.has_prefix(rest,"<="): condition.op=.Less_Equal
    case strings.has_prefix(rest,">="): condition.op=.Greater_Equal
    case rest[0]=='=': condition.op,size=.Equal,1
    case rest[0]=='<': condition.op,size=.Less,1
    case rest[0]=='>': condition.op,size=.Greater,1
    case: return
    }
    condition.text=text
    condition.path=json_path_parse(strings.trim_space(text[:at])) or_return
    condition.value=strings.trim_space(rest[size:])
    if condition.op!=.Equal && condition.op!=.Not_Equal {
        if _,number:=strconv.parse_f64(condition.value);!number {return condition,false}
    }
    return condition,true
}

// Whether value, raw JSON, meets the condition. Numbers compare as numbers,
// integers exactly; a string compares its text, with the value of the
// condition with or without quotes; the rest compares as written, without
// spaces. mismatch says why a value cannot be ordered.
rpc_condition_met :: proc(condition:Rpc_Condition,value:string) -> (met:bool,mismatch:string) {
    expected:=condition.value
    if len(expected)>=2 && expected[0]=='"' && expected[len(expected)-1]=='"' {expected=expected[1:len(expected)-1]}
    actual:=json_compact(value)
    number:=len(actual)>0 && (actual[0]=='-' || (actual[0]>='0' && actual[0]<='9'))
    if text,is_text:=json_string(value);is_text {actual=text} else {expected=json_compact(expected)}
    order:=0
    ordered:=false
    if number {
        a,a_valid:=strconv.parse_i128_of_base(actual,10)
        b,b_valid:=strconv.parse_i128_of_base(expected,10)
        if a_valid && b_valid {
            order,ordered=a<b?-1:(a>b?1:0),true
        } else {
            x,x_valid:=strconv.parse_f64(actual)
            y,y_valid:=strconv.parse_f64(expected)
            if x_valid && y_valid {order,ordered=x<y?-1:(x>y?1:0),true}
        }
    }
    switch condition.op {
    case .Equal:     return ordered?order==0:actual==expected,""
    case .Not_Equal: return ordered?order!=0:actual!=expected,""
    case .Less,.Less_Equal,.Greater,.Greater_Equal:
    }
    if !ordered {return false,fmt.tprintf("%s is %s, which is not a number: <, <=, > and >= compare numbers",condition.path.text,json_brief(value))}
    #partial switch condition.op {
    case .Less:       return order<0,""
    case .Less_Equal: return order<=0,""
    case .Greater:    return order>0,""
    }
    return order>=0,""
}

// A field of a JSON value: names of members separated by dots and [i] for
// the element i of an array, from its end when i is negative: a.b, c[0].d, [-1].
Json_Path :: struct {
    text:string,
    steps:[]Json_Step,
}

Json_Step :: struct {
    name:string, // of a member; empty for an element
    index:int,
}

json_path_parse :: proc(text:string,allocator:=context.temp_allocator) -> (path:Json_Path,ok:bool) {
    steps:=make([dynamic]Json_Step,allocator)
    i:=0
    for i<len(text) {
        if text[i]=='[' {
            close:=strings.index_byte(text[i:],']')
            if close<0 {return}
            index,valid:=strconv.parse_int(text[i+1:i+close],10)
            if !valid {return}
            append(&steps,Json_Step{index=index})
            i+=close+1
        } else {
            end:=i
            for end<len(text) && text[end]!='.' && text[end]!='[' {end+=1}
            if end==i {return}
            append(&steps,Json_Step{name=text[i:end]})
            i=end
        }
        if i<len(text) && text[i]=='.' {
            i+=1
            if i==len(text) || text[i]=='.' || text[i]=='[' {return}
        } else if i<len(text) && text[i]!='[' {
            return
        }
    }
    return {text,steps[:]},len(steps)>0
}

// The raw JSON text of the field path names in text; problem says where the
// path stops and what is there when the field is not found.
json_at :: proc(text:string,path:Json_Path) -> (value,problem:string) {
    value=strings.trim_space(text)
    for step,i in path.steps {
        place:=i==0?"the result":json_path_text(path.steps[:i])
        if step.name=="" {
            elements,is_array:=json_elements(value)
            if !is_array {return "",fmt.tprintf("%s is not an array: it is %s",place,json_brief(value))}
            index:=step.index<0?len(elements)+step.index:step.index
            if index<0 || index>=len(elements) {return "",fmt.tprintf("%s has %d elements: there is no [%d]",place,len(elements),step.index)}
            value=elements[index]
            continue
        }
        members,is_object:=json_members(value)
        if !is_object {return "",fmt.tprintf("%s is not an object: it is %s",place,json_brief(value))}
        found:=false
        for member in members {
            if member.name==step.name {value,found=member.value,true;break}
        }
        if !found {
            names:=make([]string,len(members),context.temp_allocator)
            for member,j in members {names[j]=member.name}
            return "",fmt.tprintf("%s has no '%s'; it has: %s",place,step.name,text_brief(strings.join(names,", ",context.temp_allocator),RPC_ECHO_BYTES))
        }
    }
    return value,""
}

@(private="file")
json_path_text :: proc(steps:[]Json_Step) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for step,i in steps {
        if step.name=="" {fmt.sbprintf(&b,"[%d]",step.index);continue}
        if i>0 {strings.write_byte(&b,'.')}
        strings.write_string(&b,step.name)
    }
    return strings.to_string(b)
}

// A member of a JSON object: its name and its value as raw JSON text.
Json_Member :: struct {name,value:string}

// The members of a JSON object in order; not ok when text is not one.
json_members :: proc(text:string,allocator:=context.temp_allocator) -> (members:[dynamic]Json_Member,ok:bool) {
    members=make([dynamic]Json_Member,allocator)
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    if !serial.text_accept(&r,'{') {return}
    if serial.text_accept(&r,'}') {return members,serial.text_end(&r)}
    for {
        name:=serial.text_string(&r) or_return
        member:=Json_Member{name=strings.clone(name,allocator)}
        serial.text_expect(&r,':') or_return
        serial.text_peek(&r)
        start:=r.offset
        serial.text_skip(&r) or_return
        member.value=r.text[start:r.offset]
        append(&members,member)
        if serial.text_accept(&r,',') {continue}
        serial.text_expect(&r,'}') or_return
        return members,serial.text_end(&r)
    }
}

// The elements of a JSON array as raw JSON text; not ok when text is not one.
json_elements :: proc(text:string,allocator:=context.temp_allocator) -> (elements:[dynamic]string,ok:bool) {
    elements=make([dynamic]string,allocator)
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    if !serial.text_accept(&r,'[') {return}
    if serial.text_accept(&r,']') {return elements,serial.text_end(&r)}
    for {
        serial.text_peek(&r)
        start:=r.offset
        serial.text_skip(&r) or_return
        append(&elements,r.text[start:r.offset])
        if serial.text_accept(&r,',') {continue}
        serial.text_expect(&r,']') or_return
        return elements,serial.text_end(&r)
    }
}

// The raw JSON of a member of an object; "" when it has none.
json_member :: proc(text,name:string) -> string {
    members,_:=json_members(text)
    for member in members {
        if member.name==name {return member.value}
    }
    return ""
}

// The text of a JSON string; not ok when value is not a string.
json_string :: proc(value:string) -> (text:string,ok:bool) {
    trimmed:=strings.trim_space(value)
    if len(trimmed)==0 || trimmed[0]!='"' {return "",false}
    return api.string_value(context.temp_allocator,trimmed)
}

// A value as --select prints it: a string without its quotes, a number,
// true, false or null as written, and the rest as indented JSON.
json_scalar_text :: proc(value:string) -> string {
    if text,is_text:=json_string(value);is_text {return text}
    if len(value)>0 && (value[0]=='{' || value[0]=='[') {return api.json_pretty(value,context.temp_allocator)}
    return value
}

// JSON without the space between its tokens.
json_compact :: proc(text:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    inside:=false
    for i:=0;i<len(text);i+=1 {
        c:=text[i]
        if inside {
            strings.write_byte(&b,c)
            if c=='\\' && i+1<len(text) {
                i+=1
                strings.write_byte(&b,text[i])
            } else if c=='"' {
                inside=false
            }
            continue
        }
        switch c {
        case ' ','\t','\n','\r': continue
        case '"': inside=true
        }
        strings.write_byte(&b,c)
    }
    return strings.to_string(b)
}

// A value in a message: on one line, cut past RPC_BRIEF_BYTES.
json_brief :: proc(value:string) -> string {return text_brief(json_compact(value),RPC_BRIEF_BYTES)}

// At most limit bytes of text, without splitting a character, and how many it left out.
text_cut :: proc(text:string,limit:int) -> (prefix:string,omitted:int) {
    if len(text)<=limit {return text,0}
    end:=limit
    for end>0 && text[end]&0xC0==0x80 {end-=1}
    return text[:end],len(text)-end
}

// text as a message shows it: what text_cut keeps and the size of the rest.
text_brief :: proc(text:string,limit:int) -> string {
    prefix,omitted:=text_cut(text,limit)
    return omitted>0?fmt.tprintf("%s... (%d more bytes)",prefix,omitted):prefix
}

// mirai rpc --batch <file>: one call per line, {"method": "...", "params": {...}},
// in order and over the same editor; prints a JSON array with the result or
// the error of each and stops at the first error.
@(private="file")
rpc_batch :: proc(connection:Connection,file:string) -> int {
    data,error:=os.read_entire_file(file,context.allocator)
    if error!=nil {fmt.eprintfln("mirai rpc: could not read %s",file);return 2}
    Line :: struct {method:string,params:json.Value}
    out:=strings.builder_make()
    strings.write_string(&out,"[")
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
        if call.params!=nil {
            encoded,marshal_error:=json.marshal(call.params,allocator=context.temp_allocator)
            if marshal_error!=nil {return 2}
            params=string(encoded)
        }
        id+=1
        if id>1 {strings.write_string(&out,",")}
        result,err,called:=rpc_call_waiting(connection,call.method,params,id)
        if called {
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
// bytes and the size of the rest.
rpc_error_short :: proc(err:api.Error) -> api.Error {
    prefix,omitted:=text_cut(err.data,RPC_ECHO_BYTES)
    if omitted==0 {return err}
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
