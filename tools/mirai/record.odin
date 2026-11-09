package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "mirai:editor/api"
import "mirai:project"

RECORD_USAGE :: "record [project] [--out <folder>] [--scene S] [--format png16|exr] [--fps N] [--seconds S] [--size WxH] [--sheet N] [--no-audio] [--dev|--release]"

// mirai record: a sequence of the game of a project frame after frame at a
// fixed rate, as play.record writes it, with its sound. It uses the session of
// the project (mirai session), or opens one for the recording and closes it;
// it plays the scene when no Play is running and stops what it started.
// Prints the result of play.record and the validation errors of the editor;
// exit 1 with validation errors.
cmd_record :: proc(root:string,args:[]string) -> int {
    folder,out,scene:=".","",""
    Params :: struct {path:string,format:string,fps:int,seconds:f64,width,height:int,audio:bool,sheet:int}
    params:=Params{format="Png16",fps=30,seconds=2,width=1280,height=720,audio=true,sheet=16}
    mode:Build_Mode=.Keep
    usage :: proc() -> int {fmt.eprintfln("Usage: mirai %s",RECORD_USAGE);return 2}
    value :: proc(args:[]string,i:^int) -> (string,bool) {
        if i^+1>=len(args) {return "",false}
        i^+=1
        return args[i^],true
    }
    for i:=0;i<len(args);i+=1 {
        ok:=true
        text:string
        switch args[i] {
        case "--out":   out,ok=value(args,&i)
        case "--scene": scene,ok=value(args,&i)
        case "--format":
            text,ok=value(args,&i)
            switch text {
            case "png16": params.format="Png16"
            case "exr":   params.format="Exr"
            case:         ok=false
            }
        case "--fps":
            text,ok=value(args,&i)
            number,valid:=strconv.parse_int(text,10)
            params.fps,ok=number,ok && valid
        case "--seconds":
            text,ok=value(args,&i)
            number,valid:=strconv.parse_f64(text)
            params.seconds,ok=number,ok && valid
        case "--size":
            text,ok=value(args,&i)
            cut:=strings.index_byte(text,'x')
            if ok && cut>0 {
                w,w_ok:=strconv.parse_int(text[:cut],10)
                h,h_ok:=strconv.parse_int(text[cut+1:],10)
                params.width,params.height,ok=w,h,w_ok && h_ok
            } else {ok=false}
        case "--sheet":
            text,ok=value(args,&i)
            number,valid:=strconv.parse_int(text,10)
            params.sheet,ok=number,ok && valid
        case "--no-audio": params.audio=false
        case "--dev":  mode=.Dev
        case "--release": mode=.Release
        case:
            if strings.has_prefix(args[i],"-") || folder!="." {return usage()}
            folder=args[i]
        }
        if !ok {return usage()}
    }
    if !os.is_file(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator)) {
        fmt.eprintfln("mirai record: %s is not a project (%s is missing)",folder,project.PROJECT_FILE)
        return 2
    }
    folder=project.path_absolute(folder)
    if out!="" {params.path=project.path_absolute(out)}

    file,alive:=session_find(folder)
    reused:=alive && session_answers(file.port)
    if reused && !session_reusable(root,folder,mode,file,"record") {return 1}
    if !reused {
        code:int
        if file,code=session_open(root,folder,mode,false,180,{});code!=0 {return code}
    }
    defer if !reused {session_close(folder,file,true)}

    call :: proc(port:int,method:string,params:any) -> (result:string,ok:bool) {
        text,_:=json.marshal(params,allocator=context.temp_allocator)
        response,err,called:=api.rpc_call(port,method,string(text),1,3600000,context.allocator)
        if !called {fmt.eprintfln("mirai record: %s: %s",method,api.error_text(err,context.temp_allocator))}
        return response,called
    }
    if scene!="" {
        if _,ok:=call(file.port,"scene.open",struct{path:string}{scene});!ok {return 1}
    }
    Status :: struct {playing:bool}
    status:Status
    if text,ok:=call(file.port,"play.status",struct{}{});ok {_=json.unmarshal_string(text,&status,allocator=context.temp_allocator)}
    started:=false
    if !status.playing {
        if _,ok:=call(file.port,"play.start",struct{}{});!ok {return 1}
        started=true
    }
    recorded,recorded_ok:=call(file.port,"play.record",params)
    if started {_,_=call(file.port,"play.stop",struct{}{})}
    if !recorded_ok {return 1}

    Validation :: struct {errors,loader_errors:int,messages:[]string}
    Diagnostics :: struct {validation:Validation}
    diagnostics:Diagnostics
    if text,ok:=call(file.port,"engine.diagnostics",struct{min_level:string,limit:int}{"Warning",20});ok {
        _=json.unmarshal_string(text,&diagnostics,allocator=context.temp_allocator)
    }
    Recording :: struct {
        path,first,audio:string,
        frames,fps,width,height:int,
        format:string,
        tick_from,tick_to:u64,
        seconds:f64,
        sample_rate,channels:int,
        audio_frames:u64,
    }
    Report :: struct {
        recording:Recording,
        validation_errors,loader_errors:int,
        validation_messages:[]string,
    }
    report:=Report{validation_errors=diagnostics.validation.errors,loader_errors=diagnostics.validation.loader_errors,validation_messages=diagnostics.validation.messages}
    _=json.unmarshal_string(recorded,&report.recording,allocator=context.temp_allocator)
    text,_:=json.marshal(report,{pretty=true},context.temp_allocator)
    fmt.println(string(text))
    return report.validation_errors>0?1:0
}
