package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "mirai:cook/workspace"
import "mirai:editor/api"
import "mirai:project"

PLAY_AUDIT_USAGE :: "play audit [project] [--copy] [--ticks n] [--explore] [--release] [--store folder]"
PLAY_AUDIT_TICKS :: 300 // the most play.audit runs before its checks

Play_Audit_Options :: struct {
    folder:string,
    copy,explore:bool,
    ticks:int,
}

// What play audit takes besides the build mode and the store; problem says
// what is wrong, "" when nothing is.
play_audit_options :: proc(args:[]string) -> (options:Play_Audit_Options,problem:string) {
    options.folder="."
    given:=false
    for i:=0;i<len(args);i+=1 {
        if value,matched,ok:=option_value(args,&i,"--ticks");matched {
            ticks,number:=strconv.parse_int(value,10)
            if !ok || !number || ticks<0 || ticks>PLAY_AUDIT_TICKS {return {},fmt.tprintf("--ticks is a number of ticks from 0 to %d",PLAY_AUDIT_TICKS)}
            options.ticks=ticks
            continue
        }
        switch args[i] {
        case "--copy":    options.copy=true
        case "--explore": options.explore=true
        case:
            if !positional(args[i]) {return {},fmt.tprintf("'%s' is not an option of play audit",args[i])}
            if given {return {},fmt.tprintf("'%s' is one argument too many: play audit takes one project",args[i])}
            options.folder,given=args[i],true
        }
    }
    return options,""
}

// mirai play audit: the preflight of a game in a headless editor. It plays
// the project in its session (or in one it opens on the project, or on a copy
// with --copy, and closes), lets the bot of play.explore play it with
// --explore, runs play.audit with --ticks and reads engine.diagnostics; then
// prints a line per flag with its fix, and PASS or FAIL. Exit 0 without
// errors, 1 with one (an Error flag, a violation of severity Error of the bot
// or a validation error of the GPU), 2 when it cannot run.
cmd_play_audit :: proc(root:string,args:[]string) -> int {
    mode,rest:=build_mode_take(args)
    store_root,taken:=store_root_take(&rest,"play audit")
    if !taken {return 2}
    options,problem:=play_audit_options(rest)
    if problem!="" {fmt.eprintfln("mirai play audit: %s. Usage: mirai %s",problem,PLAY_AUDIT_USAGE);return 2}
    if !os.is_file(project.path(options.folder,project.PROJECT_FILE,allocator=context.temp_allocator)) {
        fmt.eprintfln("mirai play audit: %s is not a project (%s is missing); give the project first",options.folder,project.PROJECT_FILE)
        return 2
    }
    folder:=project.path_absolute(options.folder)
    opened:=folder
    file:api.Port_File
    owned:=false
    copy_lock:workspace.Lock
    defer workspace.lock_release(&copy_lock)
    defer if owned {
        session_close(opened,file,true,"play audit")
        if options.copy {session_copy_remove(opened,"play audit")}
    }
    if options.copy {
        session_copies_sweep(folder)
        copy,lock,copy_problem:=session_copy(folder)
        if copy_problem!="" {fmt.eprintfln("mirai play audit: %s",copy_problem);return 2}
        opened,copy_lock=copy,lock
        given:=[2]string{"--store",store_root}
        code:int
        if file,code=session_open(root,opened,mode,false,180,given[:] if store_root!="" else nil);code!=0 {
            session_copy_remove(opened,"play audit")
            return 2
        }
        owned=true
    } else {
        reused:bool
        code:int
        if file,reused,code=session_borrow(root,folder,mode,"play audit",store_root);code!=0 {return 2}
        owned=!reused
    }
    return play_audit_run(file.port,options,folder)
}

// The audit of the game in the editor at port: Play is started and stopped
// again when the editor was in Edit.
play_audit_run :: proc(port:int,options:Play_Audit_Options,folder:string) -> int {
    Empty :: struct {}
    status_text,known:=session_call("play audit",port,"engine.status",Empty{})
    if !known {return 2}
    status:struct {mode:string}
    _=json.unmarshal_string(status_text,&status,allocator=context.temp_allocator)
    started:=false
    defer if started {session_call("play audit",port,"play.stop",Empty{})}
    if status.mode=="Edit" {
        if _,ok:=session_call("play audit",port,"play.start",Empty{},3600000);!ok {return 2}
        started=true
    }
    errors,warnings:=0,0
    if options.explore {
        text,ok:=session_call("play audit",port,"play.explore",Empty{},3600000)
        if !ok {return 2}
        Violation :: struct {kind,severity,code,text:string,tick:u64}
        explored:struct {ran:int,stopped:string,violations:[]Violation,repros:[]string}
        if json.unmarshal_string(text,&explored,allocator=context.temp_allocator)!=nil {fmt.eprintfln("mirai play audit: play.explore answered %s",text);return 2}
        fmt.printfln("explore: %d ticks, stopped by %s",explored.ran,explored.stopped)
        for v in explored.violations {
            if v.severity=="Error" {errors+=1} else {warnings+=1}
            fmt.printfln("%s explore %s at tick %d%s%s",v.severity=="Error"?"ERROR":"WARN",v.kind,v.tick,v.code!=""?" ":"",v.code!=""?v.text:"")
        }
        for repro in explored.repros {fmt.printfln("  repro: %s",repro)}
    }
    text,ok:=session_call("play audit",port,"play.audit",struct {ticks:int}{options.ticks},600000)
    if !ok {return 2}
    Flag :: struct {severity,area,code,entity,message,fix:string}
    Summary :: struct {entities,mesh_entities,blend_entities,textures_pending,problems,ui_buttons_visible,rigs:int,mouse_captured,keyboard_consumed:bool,frame_luma:f32}
    audit:struct {passed:bool,flags:[]Flag,flags_more:int,summary:Summary}
    if json.unmarshal_string(text,&audit,allocator=context.temp_allocator)!=nil {fmt.eprintfln("mirai play audit: play.audit answered %s",text);return 2}
    for f in audit.flags {
        if f.severity=="Error" {errors+=1} else {warnings+=1}
        fmt.printfln("%s %s %s%s%s: %s",f.severity=="Error"?"ERROR":"WARN",f.area,f.code,f.entity!=""?" ":"",f.entity,f.message)
        if f.fix!="" {fmt.printfln("  fix: %s",f.fix)}
    }
    if audit.flags_more>0 {fmt.printfln("... %d flags more",audit.flags_more)}
    if diagnosed,read:=session_call("play audit",port,"engine.diagnostics",struct {limit:int}{1});read {
        diagnostics:struct {validation:struct {errors:int,messages:[]string}}
        if json.unmarshal_string(diagnosed,&diagnostics,allocator=context.temp_allocator)==nil && diagnostics.validation.errors>0 {
            errors+=1
            fmt.printfln("ERROR Render render.validation: %d validation errors of the GPU",diagnostics.validation.errors)
            for message in diagnostics.validation.messages[:min(len(diagnostics.validation.messages),3)] {fmt.printfln("  %s",message)}
        }
    }
    s:=audit.summary
    fmt.printfln("%s %s: %d errors, %d warnings; %d entities, %d meshes (%d blended), %d rigs watched, %d problems, %d textures pending, %d buttons on screen, mouse %s, frame luminance %.3f",
        errors>0?"FAIL":"PASS",folder,errors,warnings,s.entities,s.mesh_entities,s.blend_entities,s.rigs,s.problems,s.textures_pending,s.ui_buttons_visible,s.mouse_captured?"held":"free",s.frame_luma)
    return errors>0?1:0
}
