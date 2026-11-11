package api

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import "mirai:std/base"
import "mirai:std/serial"

MAX_ID :: 256

Request :: struct {
    id:string,   // JSON text
    has_id:bool,
    method:string,
    params:string, // JSON text
    has_params:bool,
    reply:bool,  // a response to something the server never asked: ignored
    error:Error, // the request is not valid when the code is not zero
}

@(private)
rewind :: #force_inline proc(w:^serial.Writer,mark:int) {
    w.count=mark
    w.overflow=0
}

write_error_object :: proc(allocator:runtime.Allocator,w:^serial.Writer,err:Error) {
    raw(w,`{"code":`);serial.text_write_int(w,i64(err.code))
    raw(w,`,"message":`);serial.text_write_string(w,err.message)
    if err.data!="" && json_valid(allocator,err.data) {raw(w,`,"data":`);raw(w,err.data)}
    raw(w,"}")
}

write_error_envelope :: proc(allocator:runtime.Allocator,w:^serial.Writer,id:string,err:Error) {
    raw(w,`{"jsonrpc":"2.0","id":`);raw(w,id==""?"null":id)
    raw(w,`,"error":`);write_error_object(allocator,w,err)
    raw(w,"}")
}

json_valid :: proc(allocator:runtime.Allocator,text:string) -> bool {
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,allocator)
    return serial.text_skip(&r) && serial.text_end(&r)
}

// How many elements the caller gave to an array of the params: the elements
// it did not give keep their defaults, which may look like given ones.
params_array_count :: proc(call:^Call,field:string) -> (count:int,found:bool) {
    elements,is_array:=json_elements(json_member(call.raw,field))
    return len(elements),is_array
}

@(private)
shorten :: #force_inline proc(text:string) -> string {return text[:min(len(text),MAX_NAME)]}

@(private)
text_error :: proc(s:^Server,prefix:string,text:string,r:^serial.Text_Reader) -> Error {
    allocator:=base.arena_allocator(&s.scratch)
    line,column:=serial.text_position(text,r.error.offset)
    return {INVALID_PARAMS,format_text(allocator,"%s: %s at line %d column %d",prefix,serial.text_error_message(r,allocator=allocator),line,column),""}
}

@(private)
request_read :: proc(s:^Server,r:^serial.Text_Reader) -> (req:Request) {
    invalid :: proc(req:^Request,message:string) {req.error={INVALID_REQUEST,message,""}}
    if serial.text_peek(r)!='{' {
        serial.text_skip(r)
        invalid(&req,"a request must be an object")
        return
    }
    r.offset+=1
    version_ok,has_method,has_result:=false,false,false
    if !serial.text_accept(r,'}') {
        for {
            key,_:=serial.text_string(r)
            serial.text_expect(r,':')
            switch key {
            case "jsonrpc":
                if serial.text_peek(r)=='"' {
                    value,_:=serial.text_string(r)
                    version_ok=value=="2.0"
                } else {serial.text_skip(r)}
            case "method":
                has_method=true
                if serial.text_peek(r)=='"' {
                    value,_:=serial.text_string(r)
                    req.method=clone_text(base.arena_allocator(&s.scratch),value)
                } else {serial.text_skip(r);invalid(&req,"method must be a string")}
            case "id":
                kind:=serial.text_peek(r)
                start:=r.offset
                serial.text_skip(r)
                req.id,req.has_id=r.text[start:r.offset],true
                switch {
                case kind=='{' || kind=='[' || kind=='t' || kind=='f': invalid(&req,"id must be a string, a number or null");req.id=""
                case len(req.id)>MAX_ID || (kind=='"' && !utf8.valid_string(req.id)): invalid(&req,"id is too long or not UTF-8");req.id=""
                }
            case "params":
                serial.text_peek(r)
                start:=r.offset
                serial.text_skip(r)
                req.params,req.has_params=r.text[start:r.offset],true
            case "result","error":
                has_result=true
                serial.text_skip(r)
            case:
                serial.text_skip(r)
            }
            if serial.text_accept(r,',') {continue}
            serial.text_expect(r,'}')
            break
        }
    }
    switch {
    case req.error.code!=0:
    case has_result && !has_method: req.reply=true
    case !version_ok: invalid(&req,"jsonrpc must be \"2.0\"")
    case !has_method: invalid(&req,"method is required")
    case req.has_params && (len(req.params)==0 || req.params[0]!='{'): req.error={INVALID_PARAMS,"params must be a JSON object",""}
    }
    return
}

// Answers the message in body into s.out. False when nothing is to be sent:
// the body held only notifications.
// plugins: those whose tools tools/list adds to the ones of the editor, as X-Mirai-Plugins names them.
process :: proc(s:^Server,body:string,route:Route,client_tag:string="",plugins:string="",client_name:string="",measure:string="") -> bool {
    s.client_tag,s.client_plugins,s.client_name,s.client_measure=client_tag,plugins,client_name,measure
    defer {s.client_tag,s.client_plugins,s.client_name,s.client_measure="","","",""}
    context.temp_allocator=base.arena_allocator(&s.scratch)
    base.arena_reset(&s.scratch)
    base.arena_reset(&s.text)
    w:=&s.out
    r:serial.Text_Reader
    serial.text_reader_init(&r,body,base.arena_allocator(&s.text))
    failed:=s.text.failed
    s.stats.requests+=1
    if !(serial.text_skip(&r) && serial.text_end(&r)) {
        s.stats.errors+=1
        error:=text_error(s,"parse error",body,&r)
        error.code=PARSE_ERROR
        write_error_envelope(base.arena_allocator(&s.scratch),w,"",error)
        return true
    }
    r.offset=0
    answered:=false
    if s.text.failed!=failed {
        s.stats.errors+=1;s.stats.scratch_failures+=1
        write_error_envelope(base.arena_allocator(&s.scratch),w,"",{INVALID_REQUEST,"a string of the request is too long to read",""})
        return true
    }
    if serial.text_peek(&r)=='[' {
        r.offset+=1
        if serial.text_accept(&r,']') {
            s.stats.errors+=1
            write_error_envelope(base.arena_allocator(&s.scratch),w,"",{INVALID_REQUEST,"a batch has at least one request",""})
            return true
        }
        serial.write_u8(w,'[')
        for {
            if process_one(s,&r,route,answered) {answered=true}
            if serial.text_accept(&r,',') {continue}
            break
        }
        serial.write_u8(w,']')
    } else {
        answered=process_one(s,&r,route,false)
    }
    if w.overflow>0 {
        rewind(w,0)
        s.stats.errors+=1;s.stats.oversized+=1
        write_error_envelope(base.arena_allocator(&s.scratch),w,"",{SERVER_ERROR,"the response does not fit in the response buffer",""})
        return true
    }
    if !answered {rewind(w,0)}
    return answered
}

@(private)
process_one :: proc(s:^Server,r:^serial.Text_Reader,route:Route,comma:bool) -> bool {
    w:=&s.out
    base.arena_reset(&s.scratch)
    mark:=w.count
    request:=request_read(s,r)
    if request.reply {return false}
    if comma {serial.write_u8(w,',')}
    if request.error.code!=0 {
        s.stats.errors+=1
        write_error_envelope(base.arena_allocator(&s.scratch),w,request.id,request.error)
        return true
    }
    raw(w,`{"jsonrpc":"2.0","id":`);raw(w,request.has_id?request.id:"null");raw(w,`,"result":`)
    err:Error
    ok:bool
    switch route {
    case .Rpc: err,ok=rpc_dispatch(s,&request,w)
    case .Mcp: err,ok=mcp_dispatch(s,&request,w)
    }
    if ok && w.overflow==0 {
        raw(w,"}")
    } else {
        rewind(w,mark)
        if comma {serial.write_u8(w,',')}
        if ok {
            s.stats.oversized+=1
            err={SERVER_ERROR,"the result does not fit in the response buffer",""}
        }
        s.stats.errors+=1
        write_error_envelope(base.arena_allocator(&s.scratch),w,request.has_id?request.id:"",err)
    }
    if !request.has_id {rewind(w,mark);return false}
    return true
}

// What an error adds about the methods whose names look like name; "" without one.
@(private)
methods_similar :: proc(s:^Server,name:string) -> string {
    allocator:=base.arena_allocator(&s.scratch)
    names:=make([]string,s.method_count,allocator)
    for &method,i in s.methods[:s.method_count] {names[i]=method.name}
    similar:=names_similar(names,name,allocator)
    return similar!=""?format_text(allocator,"; similar: %s",similar):""
}

// Up to a dozen of names that look like name: those that contain its last word
// first, then the others of its namespace (scene. of scene.spawn).
names_similar :: proc(names:[]string,name:string,allocator:runtime.Allocator) -> string {
    dot:=strings.last_index_byte(name,'.')
    namespace:=name[:dot+1]
    word:=strings.to_lower(name[dot+1:],allocator)
    first:=make([dynamic]string,allocator)
    second:=make([dynamic]string,allocator)
    for each in names {
        switch {
        case word!="" && strings.contains(strings.to_lower(each,allocator),word): append(&first,each)
        case namespace!="" && strings.has_prefix(each,namespace): append(&second,each)
        }
    }
    append(&first,..second[:])
    if len(first)>SIMILAR_NAMES {return format_text(allocator,"%s and %d more",strings.join(first[:SIMILAR_NAMES],", ",allocator),len(first)-SIMILAR_NAMES)}
    return strings.join(first[:],", ",allocator)
}

@(private)
SIMILAR_NAMES :: 12

@(private)
rpc_dispatch :: proc(s:^Server,req:^Request,w:^serial.Writer) -> (Error,bool) {
    method:=method_find(s,req.method)
    if method==nil {
        return {METHOD_NOT_FOUND,format_text(base.arena_allocator(&s.scratch),"unknown method %q%s",shorten(req.method),methods_similar(s,req.method)),""},false
    }
    start:=w.count
    err,ok,selected,note:=method_call(s,method,req.has_params?req.params:"{}",w)
    if ok && selected!="" {
        w.count,w.overflow=start,0
        raw(w,selected)
    }
    if ok && note!="" {raw(w,`,"note":`);serial.text_write_string(w,note)}
    return err,ok
}

// Reads the text of params into bytes as the params of method, over its defaults.
@(private="file")
params_parse :: proc(s:^Server,method:^Method,params:string,bytes:[]u8,r:^serial.Text_Reader) -> bool {
    mem.zero_slice(bytes)
    if method.defaults!=nil {copy(bytes,method.defaults)}
    serial.text_reader_init(r,params,base.arena_allocator(&s.scratch))
    r.assets=s.assets
    r.loose_names=true
    r.nulls=true
    return serial.text_read(r,&s.schema,method.params,bytes) && serial.text_end(r)
}

// A failure of the reader of params: says what the method takes for a failure
// of shape or type, not for a name that names nothing.
@(private="file")
params_parse_error :: proc(s:^Server,method:^Method,text:string,r:^serial.Text_Reader) -> Error {
    if r.error.code==.Unknown_Entity {return {INVALID_PARAMS,serial.text_error_message(r,allocator=base.arena_allocator(&s.scratch)),""}}
    err:=text_error(s,"invalid params",text,r)
    if r.error.code!=.Unknown_Asset {err.data=params_usage(s,method)}
    return err
}

// Reads params as the params of method into the scratch of the server, with
// its defaults, and checks them against its schema: nil for a method that
// takes none. shaped is the text it read (params_shape), which the handler
// gets. What method_execute does before the handler runs.
params_read :: proc(s:^Server,method:^Method,params:string) -> (bytes:[]u8,shaped:string,err:Error,ok:bool) {
    shaped=params
    s.clamped=""
    allocator:=base.arena_allocator(&s.scratch)
    failed:=s.scratch.failed
    if method.params==serial.TYPE_NONE {
        members,_:=json_members(params,allocator)
        if s.scratch.failed!=failed {return nil,params,scratch_error(s),false}
        if len(members)>0 {return nil,params,{INVALID_PARAMS,format_text(allocator,"%s takes no params; it was given %s",method.name,shorten(members[0].name)),""},false}
        return nil,params,{},true
    }
    sc:=&s.schema
    type:=sc.types[method.params]
    bytes=base.arena_alloc(&s.scratch,max(int(type.size),1),max(int(type.align),16))
    if bytes==nil {return nil,params,scratch_error(s),false}
    r:serial.Text_Reader
    if !params_parse(s,method,params,bytes,&r) {
        if s.scratch.failed!=failed {return nil,params,scratch_error(s),false}
        first:=params_parse_error(s,method,params,&r)
        problem:string
        shaped,problem=params_shape(s,params_schema_text(s,method),params)
        if s.scratch.failed!=failed {return nil,params,scratch_error(s),false}
        if problem!="" {return nil,params,{INVALID_PARAMS,problem,params_usage(s,method)},false}
        if shaped==params {return nil,params,first,false}
        if !params_parse(s,method,shaped,bytes,&r) {
            if s.scratch.failed!=failed {return nil,params,scratch_error(s),false}
            return nil,params,params_parse_error(s,method,shaped,&r),false
        }
    }
    // A member it took by another spelling goes to the handler as its type has it.
    if r.loosened {shaped,_=params_shape(s,params_schema_text(s,method),shaped,names=true)}
    if s.scratch.failed!=failed {return nil,params,scratch_error(s),false}
    checker:=Checker{server=s,schema=sc,allocator=allocator}
    again:serial.Text_Reader
    serial.text_reader_init(&again,shaped,allocator)
    if !check_given(&checker,&again,method.params,bytes[:type.size]) {
        if s.scratch.failed!=failed {return nil,params,scratch_error(s),false}
        return nil,params,{INVALID_PARAMS,checker.message!=""?checker.message:"invalid params",checker.ranged?"":params_usage(s,method)},false
    }
    s.clamped=checker.clamped
    return bytes,shaped,{},true
}

@(private="file")
scratch_error :: proc(s:^Server) -> Error {
    s.stats.scratch_failures+=1
    return {INTERNAL_ERROR,"the request needs more scratch memory than the server has",""}
}

// Reads the params of the method, runs its handler and writes its result to out.
method_execute :: proc(s:^Server,method:^Method,params:string,out:^serial.Writer) -> (err:Error,ok:bool) {
    s.stats.calls+=1
    allocator:=base.arena_allocator(&s.scratch)
    failed:=s.scratch.failed
    sc:=&s.schema
    params_bytes,shaped,read_error,read:=params_read(s,method,params)
    if !read {return read_error,false}
    clamped:=s.clamped
    call:=Call{server=s,method=method,user=method.user,raw=shaped,client_tag=s.client_tag,client_name=s.client_name,measure=s.client_measure,allocator=allocator}
    if params_bytes!=nil {call.params=raw_data(params_bytes)}
    typed:=method.result!=serial.TYPE_NONE && !method.writes_result
    if typed {
        result_bytes:=base.arena_alloc(&s.scratch,max(int(sc.types[method.result].size),1),max(int(sc.types[method.result].align),16))
        if result_bytes==nil {return scratch_error(s),false}
        call.result=raw_data(result_bytes)
    } else {
        call.out=out
    }
    mark:=out.count
    s.image=""
    method.handler(&call)
    if call.failed {return call.error,false}
    s.image=call.image
    if s.scratch.failed!=failed {return scratch_error(s),false}
    if typed {
        size:=int(sc.types[method.result].size)
        serial.text_write(out,sc,method.result,mem.byte_slice(call.result,size),.Line)
    } else if !method.writes_result && out.count!=mark {
        rewind(out,mark)
        return {INTERNAL_ERROR,format_text(allocator,"%s wrote a result and declares none: its registration needs the type of its result",method.name),""},false
    } else if out.count==mark {
        raw(out,"null")
    }
    clamped_write(out,mark,clamped)
    s.stats.peak_scratch=max(s.stats.peak_scratch,base.arena_stats(&s.scratch).peak)
    return {},true
}

// Says in a result that is an object, written from mark, which params took their maximum.
@(private="file")
clamped_write :: proc(out:^serial.Writer,mark:int,clamped:string) {
    if clamped=="" || out.overflow>0 || out.count<=mark || out.data[out.count-1]!='}' || out.data[mark]!='{' {return}
    out.count-=1
    if out.count-1>mark {raw(out,",")}
    raw(out,`"_clamped":{`);raw(out,clamped);raw(out,"}}")
}

// The raw JSON text of the given keys of an object; "" for keys it does not have.
object_values :: proc(allocator:runtime.Allocator,text:string,keys:[]string,values:[]string) -> bool {
    walk:Object_Walk
    if !object_walk_init(&walk,text,allocator) {return false}
    for name,value in object_walk_next(&walk) {
        for key,i in keys {
            if key==name {values[i]=value;break}
        }
    }
    return !walk.failed
}

// The text of a JSON string.
string_value :: proc(allocator:runtime.Allocator,text:string) -> (value:string,ok:bool) {
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,allocator)
    return serial.text_string(&r)
}
@(private)
describe_register :: proc(s:^Server) -> bool {
    return method_register(s,{
        name="engine.describe",
        summary="A short index of the methods and the plugins of the project; methods gives the JSON Schema of the params and the result of those it names, plugin or prefix the summaries of an area.",
        params=type_info_of(Describe_Params),result=type_info_of(Describe_Result),writes_result=true,handler=describe_handler,flags={.Read_Only,.Idempotent,.Core},
    })==.None
}

// What engine.describe names the plugin of the methods of the editor.
DESCRIBE_EDITOR :: "editor"

// Methods engine.describe gives by name in one call at most.
DESCRIBE_METHODS :: 32

Describe_Params :: struct {
    methods:[DESCRIBE_METHODS][MAX_NAME]u8 `mirai:"text,optional,label=Only these methods by name; without prefix or plugin"`,
    prefix:[MAX_NAME]u8 `mirai:"text,optional,label=Only the methods whose name starts with it (such as scene.)"`,
    plugin:[MAX_NAME]u8 `mirai:"text,optional,label=Only the methods of this plugin; editor names those of the editor"`,
}

Describe_Result :: struct {
    server:struct {name,version:[MAX_NAME]u8 `mirai:"text"`},
    methods:[]Describe_Method `mirai:"optional,label=With methods; prefix or plugin"`,
    guides:[][8192]u8 `mirai:"text,optional,label=How to use the methods given: read before using them"`,
    core:[]Describe_Brief `mirai:"optional,label=Without params: the methods used most and what each is for"`,
    others:[]Describe_Group `mirai:"optional,label=Without params: the names of the other methods by plugin"`,
    active_plugins:[][MAX_NAME]u8 `mirai:"text,optional,label=Without params: the plugins the project uses"`,
    other_plugins:[][MAX_NAME]u8 `mirai:"text,optional,label=Without params: the plugins it finds and does not use"`,
    more:[256]u8 `mirai:"text,optional,label=Without params: how to ask for the rest"`,
}
Describe_Brief :: struct {
    name:[MAX_NAME]u8 `mirai:"text"`,
    summary:[128]u8 `mirai:"text"`,
}
Describe_Group :: struct {
    plugin:[MAX_NAME]u8 `mirai:"text"`,
    methods:[16384]u8 `mirai:"text,label=Their names separated by spaces"`,
}
Describe_Method :: struct {
    name:[MAX_NAME]u8 `mirai:"text"`,
    plugin:[MAX_NAME]u8 `mirai:"text,label=The plugin that registers it; editor for those of the editor"`,
    tool:[MAX_NAME]u8 `mirai:"text,optional,label=Its name as an MCP tool"`,
    summary:[1024]u8 `mirai:"text"`,
    flags:[][16]u8 `mirai:"text,optional,label=read_only; destructive; idempotent"`,
    params:serial.Json `mirai:"optional,label=The JSON Schema of its params"`,
    result:serial.Json `mirai:"optional,label=The JSON Schema of its result"`,
}
@(private)
tool_name :: proc(name:string,buffer:[]u8) -> string {
    n:=min(len(name),len(buffer))
    for i in 0..<n {buffer[i]=name[i]=='.'?'_':name[i]}
    return string(buffer[:n])
}

@(private)
write_flags :: proc(w:^serial.Writer,flags:Method_Flags) {
    raw(w,"[")
    first:=true
    for flag in Method_Flag {
        if flag not_in flags {continue}
        if !first {raw(w,",")}
        first=false
        switch flag {
        case .Read_Only: raw(w,`"read_only"`)
        case .Destructive: raw(w,`"destructive"`)
        case .Idempotent: raw(w,`"idempotent"`)
        case .Core: raw(w,`"core"`)
        case .Turn: raw(w,`"turn"`)
        case .Draws: raw(w,`"draws"`)
        case .As_User: raw(w,`"as_user"`)
        case .View: raw(w,`"view"`)
        }
    }
    raw(w,"]")
}

@(private)
describe_handler :: proc(call:^Call) {
    s:=call.server
    w:=call.out
    p:=call_params(call,Describe_Params)
    names_buffer:[DESCRIBE_METHODS]string
    count:=0
    unknown:=strings.builder_make(call.allocator)
    for &entry in p.methods {
        name:=base.text_get(entry[:])
        if name=="" {continue}
        names_buffer[count]=name
        count+=1
        if method_find(s,name)==nil {
            if strings.builder_len(unknown)>0 {strings.write_string(&unknown,", ")}
            strings.write_quoted_string(&unknown,name)
        }
    }
    names:=names_buffer[:count]
    prefix:=base.text_get(p.prefix[:])
    plugin:=base.text_get(p.plugin[:])
    if count>0 && (prefix!="" || plugin!="") {call_fail(call,INVALID_PARAMS,"methods names the methods: pass them without prefix and plugin");return}
    if strings.builder_len(unknown)>0 {call_failf(call,INVALID_PARAMS,"unknown methods %s; engine.describe without params lists them all",strings.to_string(unknown));return}
    if plugin!="" && !describe_plugin_known(s,plugin) {describe_plugin_fail(call,plugin);return}
    matched:=0
    for &method in s.methods[:s.method_count] {
        if describe_listed(&method,names,prefix,plugin) {matched+=1}
    }
    if matched==0 && plugin!="" {call_failf(call,INVALID_PARAMS,"no method of plugin %q starts with %q",plugin,prefix);return}
    if matched==0 {call_failf(call,INVALID_PARAMS,"no method starts with %q; engine.describe without params lists them all",prefix);return}
    if count==0 && prefix=="" && plugin=="" {describe_index_write(call);return}
    schemas:=count>0 || matched==1
    raw(w,`{"server":{"name":`);serial.text_write_string(w,s.name)
    raw(w,`,"version":`);serial.text_write_string(w,s.version)
    raw(w,`},"methods":[`)
    first:=true
    buffer:[MAX_NAME]u8
    for &method in s.methods[:s.method_count] {
        if !describe_listed(&method,names,prefix,plugin) {continue}
        if !first {raw(w,",")}
        first=false
        raw(w,`{"name":`);serial.text_write_string(w,method.name)
        raw(w,`,"plugin":`);serial.text_write_string(w,method_plugin(&method))
        if schemas {raw(w,`,"tool":`);serial.text_write_string(w,tool_name(method.name,buffer[:]))}
        raw(w,`,"summary":`);serial.text_write_string(w,method.summary)
        raw(w,`,"flags":`);write_flags(w,method.flags)
        if schemas {
            raw(w,`,"params":`);method_schema_write(w,s,&method,false)
            raw(w,`,"result":`);method_schema_write(w,s,&method,true)
        }
        raw(w,"}")
    }
    raw(w,"]")
    listed:=false
    for &guide in s.guides {
        about:=guide.topic==plugin
        for &method in s.methods[:s.method_count] {
            if about {break}
            if !describe_listed(&method,names,prefix,plugin) {continue}
            about=method.plugin==guide.topic || method.name==guide.topic || strings.has_prefix(method.name,guide.topic) && len(method.name)>len(guide.topic) && method.name[len(guide.topic)]=='.'
        }
        if !about {continue}
        raw(w,listed?",":`,"guides":[`)
        listed=true
        serial.text_write_string(w,guide.text)
    }
    if listed {raw(w,"]")}
    raw(w,"}")
}

// How many bytes of a summary an index shows at most.
DESCRIBE_BRIEF :: 72

// A text up to its first sentence or clause, cut at a word when it is longer
// than at most: what an index shows of a summary or a description.
summary_brief :: proc(text:string,at_most:=DESCRIBE_BRIEF) -> string {
    end:=len(text)
    for i in 0..<len(text) {
        if text[i]==';' || text[i]=='.' && (i+1==len(text) || text[i+1]==' ') {end=i;break}
    }
    if end<=at_most {return text[:end]}
    space:=strings.last_index_byte(text[:at_most],' ')
    return space>0?text[:space]:text[:at_most]
}

// engine.describe without params: the core methods with what each is for,
// the names of the others by plugin, the plugins and how to ask for the rest.
@(private)
describe_index_write :: proc(call:^Call) {
    s:=call.server
    w:=call.out
    raw(w,`{"server":{"name":`);serial.text_write_string(w,s.name)
    raw(w,`,"version":`);serial.text_write_string(w,s.version)
    raw(w,`},"core":[`)
    first:=true
    for &method in s.methods[:s.method_count] {
        if .Core not_in method.flags {continue}
        if !first {raw(w,",")}
        first=false
        raw(w,`{"name":`);serial.text_write_string(w,method.name)
        raw(w,`,"summary":`);serial.text_write_string(w,summary_brief(method.summary))
        raw(w,"}")
    }
    raw(w,`],"others":[`)
    first=true
    for &method,i in s.methods[:s.method_count] {
        if .Core in method.flags {continue}
        plugin:=method_plugin(&method)
        seen:=false
        for &earlier in s.methods[:i] {
            if .Core not_in earlier.flags && method_plugin(&earlier)==plugin {seen=true;break}
        }
        if seen {continue}
        names:=strings.builder_make(call.allocator)
        for &other in s.methods[i:s.method_count] {
            if .Core in other.flags || method_plugin(&other)!=plugin {continue}
            if strings.builder_len(names)>0 {strings.write_byte(&names,' ')}
            strings.write_string(&names,other.name)
        }
        if !first {raw(w,",")}
        first=false
        raw(w,`{"plugin":`);serial.text_write_string(w,plugin)
        raw(w,`,"methods":`);serial.text_write_string(w,strings.to_string(names))
        raw(w,"}")
    }
    raw(w,"]")
    for active in ([]bool{true,false}) {
        raw(w,active?`,"active_plugins":[`:`,"other_plugins":[`)
        first=true
        for found in s.plugins {
            if found.active!=active {continue}
            if !first {raw(w,",")}
            first=false
            serial.text_write_string(w,found.name)
        }
        raw(w,"]")
    }
    raw(w,`,"more":"methods (a list of names) gives their params and results; prefix or plugin the summaries and guides of an area"}`)
}

// The plugin engine.describe names for a method.
method_plugin :: #force_inline proc(method:^Method) -> string {
    return method.plugin!=""?method.plugin:DESCRIBE_EDITOR
}

@(private)
describe_listed :: proc(method:^Method,names:[]string,prefix,plugin:string) -> bool {
    named:=len(names)==0
    for name in names {named||=method.name==name}
    return named && (plugin=="" || method_plugin(method)==plugin) && strings.has_prefix(method.name,prefix)
}

@(private)
describe_plugin_known :: proc(s:^Server,plugin:string) -> bool {
    if plugin==DESCRIBE_EDITOR {return true}
    for &method in s.methods[:s.method_count] {if method.plugin==plugin {return true}}
    return false
}

// A plugin without methods fails with why, and with the plugins that have them.
@(private)
describe_plugin_fail :: proc(call:^Call,plugin:string) {
    s:=call.server
    reason:="no plugin is named %q"
    for found in s.plugins {
        if found.name==plugin {reason=found.active?"plugin %q registers no methods":"plugin %q is not active in the project"}
    }
    b:=strings.builder_make(call.allocator)
    strings.write_string(&b,format_text(call.allocator,reason,plugin))
    strings.write_string(&b,"; the plugins with methods are: ")
    strings.write_string(&b,DESCRIBE_EDITOR)
    for &method,i in s.methods[:s.method_count] {
        if method.plugin=="" {continue}
        seen:=false
        for &earlier in s.methods[:i] {if earlier.plugin==method.plugin {seen=true;break}}
        if seen {continue}
        strings.write_string(&b,", ")
        strings.write_string(&b,method.plugin)
    }
    call_fail(call,INVALID_PARAMS,strings.to_string(b))
}
