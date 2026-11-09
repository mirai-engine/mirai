package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:editor/api"
import "mirai:std/subprocess"

// An editor that mirai bench or mirai render opens headless to measure, and
// closes discarding what it did. tool and label name it in messages.
Headless_Editor :: struct {
    port:int,
    process:os.Process,
    project:string,
    tool,label:string,
}

// Opens the editor of a project at size with its API on the first free port
// from port, which moves past it, and waits for the API. On failure the
// editor may still run: headless_close ends it.
headless_open :: proc(e:^Headless_Editor,tool,label,editor,project,checkout,log:string,size:[2]int,port:^int) -> bool {
    for session_answers(port^) {port^+=1}
    command:=[]string{editor,"--project",project,"--headless","--api-port",fmt.tprintf("%d",port^),"--width",fmt.tprintf("%d",size.x),"--height",fmt.tprintf("%d",size.y)}
    process,error:=subprocess.detached(command,log,checkout)
    if error!=nil {fmt.eprintfln("mirai %s: could not open %s: %v",tool,editor,error);return false}
    e^={port=port^,process=process,project=project,tool=tool,label=label}
    port^+=1
    fmt.eprintfln("mirai %s: %s at %dx%d (pid %d)",tool,label,size.x,size.y,process.pid)
    start:=time.tick_now()
    for !session_answers(e.port) {
        if state,_:=os.process_wait(process,0);state.exited {fmt.eprintfln("mirai %s: the editor of %s exited before opening the API (exit code %d); see %s",tool,label,state.exit_code,log);return false}
        if time.duration_seconds(time.tick_since(start))>300 {fmt.eprintfln("mirai %s: the API of %s did not answer in 300 s; see %s",tool,label,log);return false}
        time.sleep(250*time.Millisecond)
    }
    return true
}

headless_close :: proc(e:^Headless_Editor) {
    if e.port==0 {return}
    _,_=session_close(e.project,{port=e.port,pid=e.process.pid},true)
    e.port=0
}

headless_call :: proc(e:^Headless_Editor,method:string,params:json.Object) -> (result:string,err:api.Error,called:bool) {
    text:="{}"
    if params!=nil {
        bytes,_:=json.marshal(params,allocator=context.temp_allocator)
        text=string(bytes)
    }
    return api.rpc_call(e.port,method,text,1,RENDER_TIMEOUT_MS,context.allocator)
}

// Advances frames, each with the fixed dt of engine.step.
headless_step :: proc(e:^Headless_Editor,frames:int) -> bool {
    for left:=frames;left>0;left-=3600 {
        step:=make(json.Object,context.temp_allocator)
        step["frames"]=json.Integer(min(left,3600))
        if _,err,called:=headless_call(e,"engine.step",step);!called {
            fmt.eprintfln("mirai %s: %s: engine.step: %s",e.tool,e.label,api.error_text(err,context.temp_allocator))
            return false
        }
    }
    return true
}

// Calls method on e; a field of params that the build of e does not take (an
// older base) is dropped and the call made again without it. dropped names
// those fields, for the report to say that the build was measured without them.
headless_call_known :: proc(e:^Headless_Editor,method:string,params:json.Object,dropped:^[dynamic]string) -> (result:string,err:api.Error,called:bool) {
    params:=params
    for {
        result,err,called=headless_call(e,method,params)
        if called || err.code!=api.INVALID_PARAMS {return}
        field,unknown:=unknown_field(err.message)
        if !unknown || field not_in params {return}
        delete_key(&params,field)
        append(dropped,field)
    }
}

// The field an error of invalid params names as not one of the method:
// `"name" is not a field: the fields are ...`.
unknown_field :: proc(message:string) -> (field:string,found:bool) {
    MARK :: `" is not a field`
    end:=strings.index(message,MARK)
    if end<0 {return}
    start:=strings.last_index_byte(message[:end],'"')
    if start<0 {return}
    return message[start+1:end],true
}
