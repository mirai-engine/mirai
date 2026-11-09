package api

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

// Fields of a JSON value and conditions on them: what _select and _wait_until
// of every method read.

@(private) ECHO_BYTES :: 240 // of a list of names an error repeats
@(private) BRIEF_BYTES :: 80 // of a value inside a message
@(private) NOTE_BYTES :: 480 // of what _select says it did not find
@(private) WAIT_VALUE_BYTES :: 240 // of the value a wait that ran out repeats

// <field><op><value> of _wait_until.
Condition :: struct {
    text:string,
    path:Json_Path,
    op:Operator,
    value:string,
}

Operator :: enum u8 {Equal,Not_Equal,Less,Less_Equal,Greater,Greater_Equal}

// The field, the operator (=, ==, !=, <, <=, >, >=) and the value; the
// operators of order need a number.
condition_parse :: proc(text:string) -> (condition:Condition,ok:bool) {
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
condition_met :: proc(condition:Condition,value:string) -> (met:bool,mismatch:string) {
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
// the element i of an array, from its end when i is negative: a.b, c[0].d,
// [-1]. A step of digits on an array is that index: a.0.b is a[0].b.
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
        wanted:=step.index
        numeric:=false
        if step.name!="" && len(value)>0 && value[0]=='[' {wanted,numeric=strconv.parse_int(step.name,10)}
        if step.name=="" || numeric {
            elements,is_array:=json_elements(value)
            if !is_array {return "",fmt.tprintf("%s is not an array: it is %s",place,json_brief(value))}
            index:=wanted<0?len(elements)+wanted:wanted
            if index<0 || index>=len(elements) {return "",fmt.tprintf("%s has %d elements: there is no [%d]",place,len(elements),wanted)}
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
            return "",fmt.tprintf("%s has no '%s'; it has: %s",place,step.name,text_brief(strings.join(names,", ",context.temp_allocator),ECHO_BYTES))
        }
    }
    return value,""
}

@(private)
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

// The members of a JSON object one by one: the one walk over an object.
Object_Walk :: struct {
    r:serial.Text_Reader,
    empty,done:bool,
    failed:bool, // what it read is not an object
}

// False when text does not start an object.
object_walk_init :: proc(walk:^Object_Walk,text:string,allocator:=context.temp_allocator) -> bool {
    serial.text_reader_init(&walk.r,text,allocator)
    if !serial.text_accept(&walk.r,'{') {walk.failed=true;return false}
    walk.empty=serial.text_accept(&walk.r,'}')
    return true
}

// The next member: its name, valid until the next call, and its value as raw JSON text.
object_walk_next :: proc(walk:^Object_Walk) -> (name,value:string,more:bool) {
    r:=&walk.r
    if walk.empty || walk.done || walk.failed {return}
    fail :: proc(walk:^Object_Walk) -> (string,string,bool) {walk.failed=true;return "","",false}
    key,read:=serial.text_string(r)
    if !read || !serial.text_expect(r,':') {return fail(walk)}
    serial.text_peek(r)
    start:=r.offset
    if !serial.text_skip(r) {return fail(walk)}
    value=r.text[start:r.offset]
    if !serial.text_accept(r,',') {
        if !serial.text_expect(r,'}') {return fail(walk)}
        walk.done=true
    }
    return key,value,true
}

// The members of a JSON object in order; not ok when text is not one.
json_members :: proc(text:string,allocator:=context.temp_allocator) -> (members:[dynamic]Json_Member,ok:bool) {
    members=make([dynamic]Json_Member,allocator)
    walk:Object_Walk
    if !object_walk_init(&walk,text) {return}
    for name,value in object_walk_next(&walk) {append(&members,Json_Member{strings.clone(name,allocator),value})}
    return members,!walk.failed && serial.text_end(&walk.r)
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

// How many elements a JSON array has; 0 for anything else.
json_count :: proc(text:string) -> int {
    elements,_:=json_elements(text)
    return len(elements)
}

// The text of a JSON string; not ok when value is not a string.
json_string :: proc(value:string) -> (text:string,ok:bool) {
    trimmed:=strings.trim_space(value)
    if len(trimmed)==0 || trimmed[0]!='"' {return "",false}
    return string_value(context.temp_allocator,trimmed)
}

// A value as --select prints it: a string without its quotes, a number,
// true, false or null as written, and the rest as indented JSON.
json_scalar_text :: proc(value:string) -> string {
    if text,is_text:=json_string(value);is_text {return text}
    if len(value)>0 && (value[0]=='{' || value[0]=='[') {return json_pretty(value,context.temp_allocator)}
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

// A value in a message: on one line, cut past BRIEF_BYTES.
json_brief :: proc(value:string) -> string {return text_brief(json_compact(value),BRIEF_BYTES)}

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


// What a method takes besides its own params: the server does these with its
// answer, so a client of MCP has them as a client of mirai rpc does. _select
// names the fields of the result the answer keeps, separated by commas.
// _wait_until calls the method again until a field of its result meets a
// condition, the editor going on meanwhile, for _wait_seconds at most: only a
// Read_Only method takes these two, as each call of another changes things.
PARAM_SELECT :: "_select"
PARAM_WAIT_UNTIL :: "_wait_until"
PARAM_WAIT_SECONDS :: "_wait_seconds"
WAIT_UNTIL_SECONDS :: 300 // how long _wait_until waits without _wait_seconds, under the timeouts of the clients of MCP
WAIT_UNTIL_PAUSE :: 0.1   // seconds between its calls

@(private) SELECT_SCHEMA :: `"_select":{"type":"string"}`
@(private) WAIT_SCHEMA :: `"_wait_until":{"type":"string"},"_wait_seconds":{"type":"number"}`

param_reserved :: proc(name:string) -> bool {return name==PARAM_SELECT || name==PARAM_WAIT_UNTIL || name==PARAM_WAIT_SECONDS}

// The longest a client gives a call when --timeout does not say: what ends
// it before is an editor that ended or hung (Client_Watch).
WAIT_TIMEOUT_MS :: 2*3600*1000

@(private)
Call_Options :: struct {
    select:[]Json_Path,
    until:Condition,
    waits:bool,
    wait_seconds:f64, // 0: WAIT_UNTIL_SECONDS
}

// The params without the reserved ones and what those ask for. Params that are
// not an object are left for the reader of the method to refuse.
@(private)
call_options_take :: proc(s:^Server,params:string) -> (rest:string,options:Call_Options,err:Error,ok:bool) {
    rest=params
    if !strings.contains(params,`"_`) {return rest,{},{},true}
    allocator:=base.arena_allocator(&s.scratch)
    members,is_object:=json_members(params,allocator)
    if !is_object {return rest,{},{},true}
    kept:=make([dynamic]Json_Member,allocator)
    for member in members {
        switch member.name {
        case PARAM_SELECT:
            text,is_text:=string_value(allocator,member.value)
            if !is_text {return rest,{},{INVALID_PARAMS,"_select must be a string: fields separated by commas (a.b,c[0].d)",""},false}
            parts:=strings.split(text,",",allocator)
            paths:=make([]Json_Path,len(parts),allocator)
            for part,i in parts {
                path,valid:=json_path_parse(strings.trim_space(part),allocator)
                if !valid {return rest,{},{INVALID_PARAMS,format_text(allocator,"_select: '%s' is not a field: names separated by dots and [i] for element i, from the end when negative (a.b,c[0].d,[-1])",part),""},false}
                paths[i]=path
            }
            options.select=paths
        case PARAM_WAIT_UNTIL:
            text,is_text:=string_value(allocator,member.value)
            condition:Condition
            valid:=false
            if is_text {condition,valid=condition_parse(text)}
            if !valid {return rest,{},{INVALID_PARAMS,format_text(allocator,"_wait_until: %s is not <field><op><value>: op is =, !=, <, <=, > or >=, and the last four compare numbers (phase=Built, errors>0)",member.value),""},false}
            options.until,options.waits=condition,true
        case PARAM_WAIT_SECONDS:
            seconds,valid:=strconv.parse_f64(member.value)
            if !valid || !(seconds>0) || seconds>WAIT_TIMEOUT_MS/1000 {return rest,{},{INVALID_PARAMS,format_text(allocator,"_wait_seconds must be seconds above 0 and up to %d, not %s",WAIT_TIMEOUT_MS/1000,member.value),""},false}
            options.wait_seconds=seconds
        case:
            append(&kept,member)
        }
    }
    if len(kept)==len(members) {return rest,{},{},true}
    b:=strings.builder_make(allocator)
    strings.write_byte(&b,'{')
    for member,i in kept {
        if i>0 {strings.write_byte(&b,',')}
        strings.write_string(&b,serial.text_quote(member.name))
        strings.write_byte(&b,':')
        strings.write_string(&b,member.value)
    }
    strings.write_byte(&b,'}')
    return strings.to_string(b),options,{},true
}

// The fields of a result as an object by their paths. Selecting is a read of
// the result of a call that already ran, so a field that is not there is not
// an error: selected keeps those it found and note says which are missing and
// what there is.
@(private)
fields_select :: proc(allocator:runtime.Allocator,result:string,select:[]Json_Path) -> (selected,note:string) {
    b:=strings.builder_make(allocator)
    notes:=strings.builder_make(allocator)
    strings.write_byte(&b,'{')
    comma:=false
    for path in select {
        value,missing:=json_at(result,path)
        if missing!="" {
            if strings.builder_len(notes)>0 {strings.write_string(&notes,"; ")}
            strings.write_string(&notes,format_text(allocator,"_select %s: %s",path.text,missing))
            continue
        }
        if comma {strings.write_byte(&b,',')}
        comma=true
        strings.write_string(&b,serial.text_quote(path.text))
        strings.write_byte(&b,':')
        strings.write_string(&b,value)
    }
    strings.write_byte(&b,'}')
    return strings.to_string(b),text_brief(strings.to_string(notes),NOTE_BYTES)
}

// A call of a client: the method with its params, the server doing what the
// reserved ones ask. The whole result stays in out; selected is what the
// answer keeps of it with _select, "" otherwise, and note what _select named
// that the result does not have.
method_call :: proc(s:^Server,method:^Method,params:string,out:^serial.Writer) -> (err:Error,ok:bool,selected,note:string) {
    allocator:=base.arena_allocator(&s.scratch)
    rest,options,problem,read:=call_options_take(s,params)
    if !read {return problem,false,"",""}
    if (options.waits || options.wait_seconds>0) && .Read_Only not_in method.flags {
        return {INVALID_PARAMS,format_text(allocator,"%s changes things, and %s would call it again until its condition holds: call it once without %s and %s, then wait on a read-only method, such as its status method (build.status after build.start)",method.name,PARAM_WAIT_UNTIL,PARAM_WAIT_UNTIL,PARAM_WAIT_SECONDS),""},false,"",""
    }
    start:=out.count
    started:=time.tick_now()
    limit:=options.wait_seconds>0?options.wait_seconds:WAIT_UNTIL_SECONDS
    for {
        mark:=base.arena_mark(&s.scratch)
        out.count,out.overflow=start,0
        err,ok=method_execute(s,method,rest,out)
        if !ok || !options.waits || out.overflow>0 {break}
        result:=string(out.data[start:out.count])
        value,missing:=json_at(result,options.until.path)
        if missing!="" {return {INVALID_PARAMS,format_text(allocator,"_wait_until %s: %s",options.until.text,missing),""},false,"",""}
        met,mismatch:=condition_met(options.until,value)
        if mismatch!="" {return {INVALID_PARAMS,format_text(allocator,"_wait_until %s: %s",options.until.text,mismatch),""},false,"",""}
        if met {break}
        if time.duration_seconds(time.tick_since(started))>limit {
            message:=format_text(allocator,"%s did not meet %s in %.0f s: %s is %s",method.name,options.until.text,limit,options.until.path.text,json_brief(value))
            return {TIMEOUT,message,format_text(allocator,`{{"field":%s,"value":%s}}`,serial.text_quote(options.until.path.text),wait_value_brief(allocator,value))},false,"",""
        }
        base.arena_rewind(&s.scratch,mark)
        if !server_pause(s) {return {CLOSED,format_text(allocator,"the editor is ending while _wait_until waits for %s",options.until.text),""},false,"",""}
    }
    if ok && len(options.select)>0 && out.overflow==0 {
        selected,note=fields_select(allocator,string(out.data[start:out.count]),options.select)
    }
    return
}

// The value a wait that ran out repeats: whole when it is short, else its
// first bytes and how many more it has.
@(private)
wait_value_brief :: proc(allocator:runtime.Allocator,value:string) -> string {
    prefix,omitted:=text_cut(value,WAIT_VALUE_BYTES)
    if omitted==0 {return value}
    return format_text(allocator,`{{"prefix":%s,"omitted_bytes":%d}}`,serial.text_quote(prefix,allocator),omitted)
}

@(private)
server_pause :: proc(s:^Server) -> bool {
    if s.pause!=nil {return s.pause(s,WAIT_UNTIL_PAUSE)}
    time.sleep(time.Duration(WAIT_UNTIL_PAUSE*f64(time.Second)))
    return true
}
