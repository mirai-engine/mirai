package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "mirai:project"
import "mirai:std/serial"

RECORD_USAGE :: "record [project] [--out <folder>] [--scene S] [--format png16|exr] [--fps N] [--seconds S] [--size WxH] [--sheet N] [--no-audio] [--release]"

// mirai record: a sequence of the game of a project frame after frame at a
// fixed rate, as play.record writes it, with its sound. It uses the session of
// the project (mirai session), or opens one for the recording and closes it;
// it plays the scene when no Play is running and stops what it started.
// Prints the result of play.record and the validation errors of the editor;
// exit 1 with validation errors.
cmd_record :: proc(root:string,args:[]string) -> int {
    mode,args:=build_mode_take(args)
    folder,out,scene:=".","",""
    Params :: struct {path:string,format:string,fps:int,duration:string `mirai:"name=for"`,width,height:int,audio:bool,sheet:int}
    params:=Params{format="Png16",fps=30,duration="2s",width=1280,height=720,audio=true,sheet=16}
    usage :: proc() -> int {fmt.eprintfln("Usage: mirai %s",RECORD_USAGE);return 2}
    for i:=0;i<len(args);i+=1 {
        ok:=true
        text:string
        switch args[i] {
        case "--out":   out,ok=option_next(args,&i)
        case "--scene": scene,ok=option_next(args,&i)
        case "--format":
            text,ok=option_next(args,&i)
            switch text {
            case "png16": params.format="Png16"
            case "exr":   params.format="Exr"
            case:         ok=false
            }
        case "--fps":
            text,ok=option_next(args,&i)
            number,valid:=strconv.parse_int(text,10)
            params.fps,ok=number,ok && valid
        case "--seconds":
            text,ok=option_next(args,&i)
            number,valid:=strconv.parse_f64(text)
            _=number
            params.duration,ok=fmt.aprintf("%ss",text),ok && valid
        case "--size":
            text,ok=option_next(args,&i)
            size,valid:=render_size_parse(text)
            params.width,params.height,ok=size.x,size.y,ok && valid
        case "--sheet":
            text,ok=option_next(args,&i)
            number,valid:=strconv.parse_int(text,10)
            params.sheet,ok=number,ok && valid
        case "--no-audio": params.audio=false
        case:
            if !positional(args[i]) || folder!="." {return argument_unknown("record",args[i])}
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

    file,reused,code:=session_borrow(root,folder,mode,"record")
    if code!=0 {return code}
    defer if !reused {session_close(folder,file,true)}

    call :: proc(port:int,method:string,params:any) -> (result:string,ok:bool) {return session_call("record",port,method,params,3600000)}
    if scene!="" {
        if _,ok:=call(file.port,"scene.open",struct{path:string}{scene});!ok {return 1}
    }
    Status :: struct {playing:bool}
    status:Status
    if text,ok:=call(file.port,"play.status",struct{}{});ok {serial.text_decode(text,&status,context.temp_allocator,skip_unknown=true)}
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
        serial.text_decode(text,&diagnostics,context.temp_allocator,skip_unknown=true)
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
    serial.text_decode(recorded,&report.recording,context.temp_allocator,skip_unknown=true)
    text,_:=serial.text_encode(report,.Pretty,context.temp_allocator)
    fmt.println(string(text))
    return report.validation_errors>0?1:0
}
