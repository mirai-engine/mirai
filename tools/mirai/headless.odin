package main

import "core:fmt"
import "core:os"
import "core:time"
import "mirai:editor/api"
import "mirai:std/serial"
import "mirai:std/subprocess"

// An editor that mirai bench or mirai render opens headless to measure, and
// closes. tool and label name it in messages.
Headless_Editor :: struct {
    port:int,
    process:subprocess.Process,
    project:string,
    tool,label:string,
}

// Opens the editor of a project at size with its API on the first free port
// from port, which moves past it, and waits for the API. On failure the
// editor may still run: headless_close ends it.
headless_open :: proc(e:^Headless_Editor,tool,label,editor,project,checkout,log:string,size:[2]int,port:^int) -> bool {
    for session_answers(port^) {port^+=1}
    command:=[]string{editor,"--project",project,"--headless","--api-port",fmt.tprintf("%d",port^),"--width",fmt.tprintf("%d",size.x),"--height",fmt.tprintf("%d",size.y)}
    process,error:=detached_logged(command,log,checkout)
    if error!=nil {fmt.eprintfln("mirai %s: could not open %s: %v",tool,editor,error);return false}
    e^={port=port^,process=process,project=project,tool=tool,label=label}
    port^+=1
    fmt.eprintfln("mirai %s: %s at %dx%d (pid %d)",tool,label,size.x,size.y,process.pid)
    start:=time.tick_now()
    for !session_answers(e.port) {
        if state,_:=subprocess.wait(&process,0);state.exited {fmt.eprintfln("mirai %s: the editor of %s exited before opening the API (exit code %d); see %s",tool,label,state.exit_code,log);return false}
        if time.duration_seconds(time.tick_since(start))>300 {fmt.eprintfln("mirai %s: the API of %s did not answer in 300 s; see %s",tool,label,log);return false}
        time.sleep(250*time.Millisecond)
    }
    return true
}

headless_close :: proc(e:^Headless_Editor) {
    if e.port==0 {return}
    session_close(e.project,{port=e.port,pid=e.process.pid},true)
    e.port=0
}

// The params of camera.set and profile.capture that bench and render give.
Camera_Set :: struct {
    position,target:[]f64,
    fov:f64 `mirai:"optional"`, // degrees, vertical; 0 keeps the camera of the editor
    exposure:string,
    ev100:f64 `mirai:"optional"`,
}
Profile_Capture :: struct {frames:int,advance:bool,label:string,top:int}

headless_call :: proc(e:^Headless_Editor,method:string,params:any) -> (result:string,err:api.Error,called:bool) {
    text,_:=serial.text_encode(params,.Line,context.temp_allocator,sparse=true)
    return api.rpc_call(e.port,method,string(text),1,RENDER_TIMEOUT_MS,context.allocator)
}

// Advances frames, each with the fixed dt of engine.step.
headless_step :: proc(e:^Headless_Editor,frames:int) -> bool {
    for left:=frames;left>0;left-=3600 {
        if _,err,called:=headless_call(e,"engine.step",struct{frames:int}{min(left,3600)});!called {
            fmt.eprintfln("mirai %s: %s: engine.step: %s",e.tool,e.label,api.error_text(err,context.temp_allocator))
            return false
        }
    }
    return true
}
