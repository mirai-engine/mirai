package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
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
    return editor_rays_wait(e.port,tool,label)
}

EDITOR_RAYS_WAIT_S :: 3600 // the longest the pipelines of rays may take: the driver compiles them for minutes on a cold cache
EDITOR_RAYS_REPORT_S :: 30

// Waits until the editor on port draws its scene: its API opens before the
// driver compiles the pipelines of rays traced by software, and until then
// its frames draw only the UI. An editor that does not say (an older build)
// is taken as ready. tool and label name it in messages.
editor_rays_wait :: proc(port:int,tool,label:string) -> bool {
    Status :: struct {ray_pipelines:struct {pending,total:int,failed:bool,error:string}}
    start:=time.tick_now()
    reported:=start
    first:=true
    for {
        result,err,called:=api.rpc_call(port,"engine.status","{}",1,RENDER_TIMEOUT_MS,context.temp_allocator)
        if !called {fmt.eprintfln("mirai %s: %s: engine.status: %s",tool,label,api.error_text(err,context.temp_allocator));return false}
        status:Status
        _=json.unmarshal_string(result,&status,allocator=context.temp_allocator)
        rays:=status.ray_pipelines
        waited:=time.duration_seconds(time.tick_since(start))
        if rays.pending==0 {
            if !first {fmt.eprintfln("mirai %s: %s: the pipelines of rays are made (%.0f s)",tool,label,waited)}
            return true
        }
        if rays.failed {fmt.eprintfln("mirai %s: %s: a pipeline of rays could not be made: %s",tool,label,rays.error);return false}
        if first || time.duration_seconds(time.tick_since(reported))>=EDITOR_RAYS_REPORT_S {
            fmt.eprintfln("mirai %s: %s: the driver compiles the pipelines of rays traced by software, %d of %d left (%.0f s); a cold cache takes minutes",tool,label,rays.pending,rays.total,waited)
            reported=time.tick_now()
        }
        first=false
        if waited>EDITOR_RAYS_WAIT_S {fmt.eprintfln("mirai %s: %s: the pipelines of rays were not made in %d s",tool,label,EDITOR_RAYS_WAIT_S);return false}
        time.sleep(time.Second)
    }
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
