package api

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// batch: calls of any methods in one request, in their order, the one list
// of calls of the API (mirai rpc --batch sends it). It stops at the first
// call that fails, with which one and what the ones before it answered. A
// value of the params of a call that is exactly "$N" or "$N.path" (the paths
// of --select) stands for the result of call N or for that field of it; "$$"
// begins a text that really starts with $. With transaction what the calls
// edit of the scene is one step of undo, taken back whole when a call fails;
// what they write to files stays. Whoever owns the server registers it, with
// the handler its methods go through, and gives Server.transaction.

BATCH_CALLS :: 256
BATCH_SUMMARY :: "Runs calls of any methods in order in one request and answers what each answered; a param \"$N\" or \"$N.path\" takes the result of call N or a field of it. It stops at the first call that fails. With transaction their edits of the scene are one step of undo, taken back whole when one fails."

Batch_Result :: struct {
    results:[1]Batch_Answer `mirai:"list,label=One per call in their order"`,
}
Batch_Answer :: struct {
    method:[64]u8 `mirai:"text"`,
    result:u8 `mirai:"any,label=What the method answered as it answers a call"`,
}

// The value with what "$N" and "$N.path" stand for in their place: answers
// holds where in text each call so far answered.
@(private="file")
batch_value :: proc(value:json.Value,text:[]u8,answers:[][2]int) -> (out:json.Value,problem:string) {
    #partial switch v in value {
    case json.String:
        given:=string(v)
        if strings.has_prefix(given,"$$") {return json.String(given[1:]),""}
        if len(given)<2 || given[0]!='$' || given[1]<'0' || given[1]>'9' {return value,""}
        rest:=given[1:]
        end:=strings.index_any(rest,".[")
        n,valid:=strconv.parse_int(end<0?rest:rest[:end],10)
        if !valid {return value,""}
        if n<0 || n>=len(answers) {return nil,fmt.tprintf("%s: the batch has %d results so far; a call takes those of the calls before it",given,len(answers))}
        raw:=string(text[answers[n][0]:answers[n][1]])
        if end>=0 {
            path,ok:=json_path_parse(strings.trim_prefix(rest[end:],"."))
            if !ok {return nil,fmt.tprintf("%s: %q is not a field path as --select takes it",given,rest[end:])}
            found,missing:=json_at(raw,path)
            if missing!="" {return nil,fmt.tprintf("%s: %s",given,missing)}
            raw=found
        }
        parsed,parse_error:=json.parse_string(raw,parse_integers=true,allocator=context.temp_allocator)
        if parse_error!=nil {return nil,fmt.tprintf("%s: the result is not JSON",given)}
        return parsed,""
    case json.Object:
        resolved:=make(json.Object,len(v),context.temp_allocator)
        for key,element in v {
            resolved[key],problem=batch_value(element,text,answers)
            if problem!="" {return nil,problem}
        }
        return resolved,""
    case json.Array:
        for &element in v {
            element,problem=batch_value(element,text,answers)
            if problem!="" {return nil,problem}
        }
        return v,""
    }
    return value,""
}

batch :: proc(call:^Call) {
    server:=call.server
    given:[2]string
    calls,listed:=make([dynamic]string,call.allocator),false
    if object_values(call.allocator,call.raw,{"calls","transaction"},given[:]) {calls,listed=json_elements(given[0],call.allocator)}
    if !listed || len(calls)==0 || len(calls)>BATCH_CALLS {
        call_failf(call,INVALID_PARAMS,`calls must be 1 to %d calls: [{{"method":"...","params":{{...}}}}]`,BATCH_CALLS)
        return
    }
    transaction:=given[1]=="true"
    if transaction {
        if server.transaction==nil {call_fail(call,INVALID_PARAMS,"transaction is of a server that edits a scene; leave it out");return}
        if !server.transaction(server,call,true) {return}
    }
    out:=call.out
    serial.text_write_raw(out,`{"results":[`)
    first:=out.count
    answers:=make([dynamic][2]int,0,len(calls),call.allocator)
    failure:Error
    for text,at in calls {
        fields:[2]string
        name:string
        method:^Method
        if object_values(call.allocator,text,{"method","params"},fields[:]) {
            name,_=json_string(fields[0])
            method=method_find(server,name)
        }
        params:=fields[1]!=""?fields[1]:"{}"
        if method==nil {
            failure={INVALID_PARAMS,fmt.tprintf(`%q is not a method of this editor; a call is {{"method":"...","params":{{...}}}}`,name),""}
        } else if strings.contains(params,`"$`) {
            problem:="params is not JSON"
            if value,malformed:=json.parse_string(params,parse_integers=true,allocator=context.temp_allocator);malformed==nil {
                if value,problem=batch_value(value,out.data,answers[:]);problem=="" {
                    encoded,_:=json.marshal(value,allocator=context.temp_allocator)
                    params=strings.clone(string(encoded),call.allocator)
                }
            }
            if problem!="" {failure={INVALID_PARAMS,problem,""}}
        }
        entry:=out.count
        if failure.code==0 {
            serial.text_write_raw(out,at>0?`,{"method":`:`{"method":`);serial.text_write_string(out,name)
            write_key(out,"result")
            start:=out.count
            mark:=base.arena_mark(&server.scratch)
            if failed,_:=method_execute(server,method,params,out);failed.code!=0 {failure={failed.code,strings.clone(failed.message,context.temp_allocator),""}}
            base.arena_rewind(&server.scratch,mark)
            if failure.code==0 {
                append(&answers,[2]int{start,out.count})
                serial.write_u8(out,'}')
                continue
            }
        }
        done:=string(out.data[first:entry])
        call_fail(call,failure.code,fmt.tprintf("calls[%d] %s: %s; the %d calls before it ran%s",at,name,failure.message,at,transaction?", and what they edited of the scene was taken back":""),fmt.tprintf(`{{"failed":%d,"results":[%s]}}`,at,done))
        break
    }
    if transaction && !server.transaction(server,call,false) {return}
    if !call.failed {serial.text_write_raw(out,"]}")}
}

BATCH_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["calls"],"properties":{"calls":{"type":"array","minItems":1,"maxItems":256,"items":{"type":"object","required":["method"],"additionalProperties":false,"properties":{"method":{"type":"string","description":"any method of the API but batch"},"params":{"type":"object","description":"the params of that method; a string that is exactly \"$N\" or \"$N.path\" stands for the result of call N of this batch or for that field of it, as {\"root\":\"$0.id\"}; \"$$\" begins a text that really starts with $"}}}},"transaction":{"type":"boolean","description":"true: what the calls edit of the scene is one step of undo, taken back whole when one fails; what they write to files stays"}}}`
