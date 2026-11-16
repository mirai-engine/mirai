package api

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// batch: calls of any methods in one request, in their order, the one list
// of calls of the API (mirai rpc batch --file sends one). It stops at the first
// call that fails, with which one and what the ones before it answered. A
// value of the params of a call that is exactly "$N" or "$N.path" (the paths
// of --select) stands for the result of call N or for that field of it; "$$"
// begins a text that really starts with $. With transaction what the calls
// edit of the scene is one step of undo, taken back whole when a call fails;
// what they write to files stays. Whoever owns the server registers it, with
// the handler its methods go through, and gives Server.transaction.

BATCH_CALLS :: 256
BATCH_SUMMARY :: "Runs calls of any methods in order in one request and answers what each answered; a param \"$N\" or \"$N.path\" takes the result of call N or a field of it. It stops at the first call that fails. With transaction their edits of the scene are one step of undo, taken back whole when one fails."

Batch_Params :: struct {
    calls:[]Batch_Call `mirai:"label=1 to 256 calls, run in their order"`,
    transaction:bool `mirai:"optional,label=true: what the calls edit of the scene is one step of undo, taken back whole when one fails; what they write to files stays"`,
}
Batch_Call :: struct {
    method:string `mirai:"label=Any method of the API but batch"`,
    params:serial.Json `mirai:"optional,label=The params of that method; a string that is exactly '$N' or '$N.path' stands for the result of call N of this batch or for that field of it, as {'root':'$0.id'}; '$$' begins a text that really starts with $"`,
}
Batch_Result :: struct {
    results:[]Batch_Answer `mirai:"label=One per call in their order"`,
}
Batch_Answer :: struct {
    method:string,
    result:serial.Json `mirai:"label=What the method answered as it answers a call"`,
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
    p:=call_params(call,Batch_Params)
    if len(p.calls)==0 || len(p.calls)>BATCH_CALLS {
        call_failf(call,INVALID_PARAMS,`calls must be 1 to %d calls: [{{"method":"...","params":{{...}}}}]`,BATCH_CALLS)
        return
    }
    if p.transaction {
        if server.transaction==nil {call_fail(call,INVALID_PARAMS,"transaction is of a server that edits a scene; leave it out");return}
        if !server.transaction(server,call,true) {return}
    }
    // The answers go straight into the response: the scratch each call takes
    // back after it runs never holds them.
    out:=call.out
    start:=out.count
    raw(out,`{"results":[`)
    list:=out.count
    answers:=make([dynamic][2]int,0,len(p.calls),call.allocator)
    for &given,at in p.calls {
        failure:Error
        method:=method_find(server,given.method)
        params:=given.params!=""?string(given.params):"{}"
        if method==nil {
            failure={INVALID_PARAMS,fmt.tprintf(`%q is not a method of this editor%s; a call is {{"method":"...","params":{{...}}}}`,given.method,methods_similar(server,given.method)),""}
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
        ran:=false
        if failure.code==0 {
            if at>0 {raw(out,",")}
            raw(out,`{"method":`);serial.text_write_string(out,given.method);raw(out,`,"result":`)
            begin:=out.count
            mark:=base.arena_mark(&server.scratch)
            failed,_:=method_execute(server,method,params,out)
            if failed.code==0 {
                base.arena_rewind(&server.scratch,mark)
                end:=out.count
                raw(out,"}")
                if out.overflow==0 {
                    append(&answers,[2]int{begin,end})
                    continue
                }
                ran=true
                failure={SERVER_ERROR,fmt.tprintf("its result does not fit in the %d bytes of a response with those of the calls before it; split the calls into smaller batches",server.max_response),""}
            } else {
                failure={failed.code,failed.message,""}
            }
        }
        // In the scratch of the call, the message first: the results so far
        // may not fit there, and then the error goes without them.
        message:=fmt.tprintf("calls[%d] %s: %s; %s %d calls before it ran%s",at,given.method,failure.message,ran?"it and the":"the",at,p.transaction?", and what they edited of the scene was taken back":"")
        data:=ran?fmt.tprintf(`{{"failed":%d}}`,at):fmt.tprintf(`{{"failed":%d,"results":[%s]}}`,at,string(out.data[list:entry]))
        rewind(out,start)
        call.failed,call.error=true,{failure.code,message,data}
        break
    }
    if !call.failed {
        raw(out,"]}")
        if out.overflow>0 {
            rewind(out,start)
            call_failf(call,SERVER_ERROR,"the results of the %d calls do not fit in the %d bytes of a response; split the calls into smaller batches",len(p.calls),server.max_response)
        }
    }
    if p.transaction {server.transaction(server,call,false)}
}
