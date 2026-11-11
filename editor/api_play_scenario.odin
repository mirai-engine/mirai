package editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// A play scenario is a gameplay test written once as a file of the project
// and played again whenever: it plays a scene from its first tick, runs its
// steps in order as calls of the play methods with their params, and stops
// the game. Nothing but its steps advances the game, so the same file plays
// the same ticks every time.
//
//   {"scene": "scenes/main.scene", "start": {"players": 1}, "steps": [
//     {"name": "walk", "method": "play.step", "params": {"for": "1s", "keys": ["W"]}},
//     {"method": "play.check", "params": {"conditions": [...]}}]}
//
// A step fails when its call fails, when its result says passed false (the
// conditions of play.check) or when play.step with until runs out of ticks
// before they hold; the scenario ends at its first failed step. The params
// of each step are those of its method, checked against its schema before
// the game starts.

SCENARIO_FOLDER :: "tests/scenarios"
SCENARIO_EXTENSION :: ".mirai"
API_SCENARIO_STEPS :: 2048
API_SCENARIO_FILES :: 256
API_SCENARIO_FILE_BYTES :: 1<<20
API_SCENARIO_TEXT :: 512

Api_Play_Scenario_Params :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"optional,text,label=A scenario file or a folder of them (its .mirai files) absolute or under the project; empty: tests/scenarios"`,
}

// What play.scenario.run writes.
Api_Play_Scenario_Result :: struct {
    passed:bool `mirai:"label=Every scenario passed"`,
    total:int `mirai:"label=Scenarios it ran"`,
    failed:int `mirai:"label=Scenarios that failed"`,
    scenarios:[]Api_Scenario_Report `mirai:"label=One per file in the order of their names"`,
}
Api_Scenario_Report :: struct {
    path:string `mirai:"label=The file: relative to the project when it is inside"`,
    scene:string `mirai:"label=The scene it played as the file names it; empty: the one open"`,
    steps:int `mirai:"label=Steps of the file"`,
    ran:[]Api_Scenario_Step `mirai:"label=The steps it ran in order up to the first that failed"`,
    passed:bool,
    failure:string `mirai:"label=What failed first and why; empty when it passed"`,
    tick:u64 `mirai:"label=The tick of the game when it stopped"`,
}
Api_Scenario_Step :: struct {
    name:string `mirai:"optional,label=The name the file gives it"`,
    method:string,
    result:serial.Json `mirai:"label=What the method answered as it answers a call; null when the call failed"`,
    passed:bool,
    tick:u64 `mirai:"label=The tick of the game after it"`,
    error:string `mirai:"label=Why the call failed; empty when it answered"`,
}

// A scenario file; the params of a step are those of its method.
Scenario :: struct {
    scene:string `mirai:"optional"`,
    start:serial.Json `mirai:"optional"`,
    steps:[]Scenario_Step,
}
Scenario_Step :: struct {
    name:string `mirai:"optional"`,
    method:string,
    params:serial.Json `mirai:"optional"`,
}

@(private)
api_play_scenario_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="play.scenario.run",summary="Plays the scenarios of the project, gameplay tests written as files: each plays its scene from the first tick, runs its steps (calls of play.input, play.step, play.check, capture, the other play methods, and scene.write and scene.inspect with world Game) and stops; says per step whether it passed, at which tick and what its method answered.",params=type_info_of(Api_Play_Scenario_Params),result=type_info_of(Api_Play_Scenario_Result),run=api_play_scenario_run})
}


// Reads the text of a scenario file; problem says what is wrong and where.
// The methods of its steps are checked by api_scenario_check.
@(private)
scenario_parse :: proc(text:string,allocator:=context.allocator) -> (sc:Scenario,problem:string) {
    if problem=serial.text_decode(text,&sc,allocator);problem!="" {return {},fmt.aprintf("the file: %s",problem,allocator=allocator)}
    if len(sc.steps)==0 {return {},`steps: give the steps in order, as [{"method": "play.step", "params": {"for": 60}}, {"method": "play.check", "params": {"conditions": [...]}}]`}
    if len(sc.steps)>API_SCENARIO_STEPS {return {},fmt.aprintf("steps: %d steps, and a scenario takes %d at most: split it into several files",len(sc.steps),API_SCENARIO_STEPS,allocator=allocator)}
    if sc.start=="" {sc.start="{}"}
    if !strings.has_prefix(string(sc.start),"{") {return {},"start: give the params of play.start as an object, as {\"players\": 1}"}
    for &step,i in sc.steps {
        if step.method=="" {return {},fmt.aprintf("steps[%d]: give its method, as \"method\": \"play.step\"",i,allocator=allocator)}
        if step.params=="" {step.params="{}"}
        if !strings.has_prefix(string(step.params),"{") {return {},fmt.aprintf("steps[%d]: params: give the params of %s as an object",i,step.method,allocator=allocator)}
    }
    return
}

// Whether a scenario may call a method; why not when it may not.
@(private)
scenario_method_refusal :: proc(name:string) -> string {
    switch {
    case name=="play.start" || name=="play.stop": return "the scenario starts the game before its steps and stops it after them: leave it out (start takes the params of play.start)"
    case strings.has_prefix(name,"play.scenario."): return "a scenario does not run scenarios"
    case !strings.has_prefix(name,"play.") && name!="capture" && name!="scene.write" && name!="scene.inspect": return "a scenario plays the game: its steps are play methods (play.input, play.step, play.check...), capture, and scene.write and scene.inspect with world Game"
    }
    return ""
}

// Checks every step names a method a scenario may call with params its
// schema takes, before the game starts; problem names the first that does not.
@(private)
api_scenario_check :: proc(server:^api.Server,sc:^Scenario,allocator:=context.allocator) -> (problem:string) {
    for &step,i in sc.steps {
        method:=api.method_find(server,step.method)
        if method==nil {return fmt.aprintf("steps[%d].method: %q is not a method of this editor; engine.describe lists them",i,step.method,allocator=allocator)}
        if refusal:=scenario_method_refusal(step.method);refusal!="" {return fmt.aprintf("steps[%d].method: %s: %s",i,step.method,refusal,allocator=allocator)}
        if world:[1]string;strings.has_prefix(step.method,"scene.") && (!api.object_values(allocator,string(step.params),{"world"},world[:]) || world[0]!=`"Game"`) {
            return fmt.aprintf(`steps[%d].params: a scenario plays the game: give %s "world": "Game"`,i,step.method,allocator=allocator)
        }
        mark:=base.arena_mark(&server.scratch)
        _,_,error,read:=api.params_read(server,method,string(step.params))
        base.arena_rewind(&server.scratch,mark)
        if !read {return fmt.aprintf("steps[%d].params: %s",i,error.message,allocator=allocator)}
        if method.params==serial.TYPE_NONE && !api.json_valid(allocator,string(step.params)) {return fmt.aprintf("steps[%d].params: not valid JSON",i,allocator=allocator)}
    }
    if start:=api.method_find(server,"play.start");start!=nil {
        mark:=base.arena_mark(&server.scratch)
        _,_,error,read:=api.params_read(server,start,string(sc.start))
        base.arena_rewind(&server.scratch,mark)
        if !read {return fmt.aprintf("start: %s",error.message,allocator=allocator)}
    }
    return ""
}

// The scenario files path names: the file, or the files of a folder in the
// order of their names; problem says why there are none.
@(private)
scenario_files :: proc(root,path:string,allocator:=context.allocator) -> (files:[]string,problem:string) {
    given:=path
    if given=="" {
        if root=="" {return nil,"path: give the scenario file or folder; the editor has no project to look in"}
        given=SCENARIO_FOLDER
    }
    file,wrong:=api_file_path(root,given,allocator)
    if wrong!="" {return nil,wrong}
    if !os.is_dir(file) {
        if !os.is_file(file) {return nil,fmt.aprintf("%s is not there: write the scenario there, or give the path of one",file,allocator=allocator)}
        found:=make([]string,1,allocator)
        found[0]=file
        return found,""
    }
    entries,error:=os.read_all_directory_by_path(file,allocator)
    if error!=nil {return nil,fmt.aprintf("%s could not be read: %s",file,os.error_string(error),allocator=allocator)}
    list:=make([dynamic]string,allocator)
    for entry in entries {
        if entry.type!=.Directory && strings.has_suffix(entry.name,SCENARIO_EXTENSION) {append(&list,project.path(file,entry.name,allocator=allocator))}
    }
    if len(list)==0 {return nil,fmt.aprintf("%s has no scenarios: write them as %s files there",file,SCENARIO_EXTENSION,allocator=allocator)}
    if len(list)>API_SCENARIO_FILES {return nil,fmt.aprintf("%s has %d scenarios and a call runs %d at most: run its files by parts",file,len(list),API_SCENARIO_FILES,allocator=allocator)}
    slice.sort(list[:])
    return list[:],""
}

@(private)
api_play_scenario_run :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Play_Scenario_Params)
    files,problem:=scenario_files(s.project_root,base.text_get(params.path[:]),call.allocator)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    result:=api.call_result(call,Api_Play_Scenario_Result)
    result.scenarios=make([]Api_Scenario_Report,len(files),call.allocator)
    for file,i in files {
        result.scenarios[i]=api_scenario_play(s,call,file)
        if !result.scenarios[i].passed {result.failed+=1}
    }
    result.passed,result.total=result.failed==0,len(files)
}

// Plays one scenario file; its report.
@(private)
api_scenario_play :: proc(s:^Session,call:^api.Call,file:string) -> (report:Api_Scenario_Report) {
    server:=call.server
    report.path=file
    if root:=s.project_root;root!="" && strings.has_prefix(file,root) && len(file)>len(root) && file[len(root)]=='/' {report.path=file[len(root)+1:]}
    sc:Scenario
    text,read_error:=os.read_entire_file(file,call.allocator)
    switch {
    case read_error!=nil:
        report.failure=fmt.aprintf("the file could not be read: %s",os.error_string(read_error),allocator=call.allocator)
    case len(text)>API_SCENARIO_FILE_BYTES:
        report.failure=fmt.aprintf("the file has %d bytes and a scenario takes %d at most: split it",len(text),API_SCENARIO_FILE_BYTES,allocator=call.allocator)
    case:
        if sc,report.failure=scenario_parse(string(text),call.allocator);report.failure=="" {report.failure=api_scenario_check(server,&sc,call.allocator)}
    }
    report.scene,report.steps=sc.scene,len(sc.steps)
    if report.failure=="" {report.ran,report.failure,report.tick=api_scenario_steps(s,call,&sc)}
    report.passed=report.failure==""
    return
}

// Runs a method of the API inside this call with params as JSON, answering
// into a writer of its own; what it answered, kept in buffer.
api_scenario_call :: proc(server:^api.Server,name,params:string,buffer:[]u8) -> (answer:string,error:api.Error,ok:bool) {
    method:=api.method_find(server,name)
    if method==nil {return "",{api.METHOD_NOT_FOUND,fmt.tprintf("%s is not a method of this editor",name),""},false}
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer)
    mark:=base.arena_mark(&server.scratch)
    error,ok=api.method_execute(server,method,params,&w)
    error.message=strings.clone(error.message,context.temp_allocator)
    base.arena_rewind(&server.scratch,mark)
    server.image=""
    return string(serial.writer_bytes(&w)),error,ok
}

// Whether a step whose method answered held: not when its answer says passed
// false (the conditions of play.check), nor when play.step with until ran out
// of its ticks before they hold, nor when a drive ended without arriving; why not.
@(private)
scenario_step_held :: proc(params,answer:string) -> (held:bool,why:string) {
    values:[3]string
    api.object_values(context.temp_allocator,answer,{"passed","met","drive"},values[:])
    asked:[2]string
    api.object_values(context.temp_allocator,params,{"until","drive"},asked[:])
    switch {
    case values[0]=="false":                 return false,"did not hold"
    case asked[1]!="":
        if !api_drive_held(values[2]) {return false,fmt.tprintf("the drive did not arrive: %s",values[2])}
    case asked[0]!="" && values[1]=="false": return false,"until did not hold within its ticks"
    }
    return true,""
}

// Plays the scene of a scenario and its steps, writing a report per step to
// out, and stops the game; the first failure, in buffer, and the last tick.
@(private)
api_scenario_steps :: proc(s:^Session,call:^api.Call,sc:^Scenario) -> (ran:[]Api_Scenario_Step,failure:string,tick:u64) {
    server:=call.server
    owner:=ai_task_of_call(s,call)
    answer_buffer:[4096]u8
    fail :: proc(call:^api.Call,format:string,args:..any) -> string {return fmt.aprintf(format,..args,allocator=call.allocator)}
    if run_find(s,owner)!=nil {return nil,fail(call,"a game is already playing: stop it (play.stop) and run the scenario again"),0}
    if sc.scene!="" {
        target:=scene_file(s,sc.scene)
        if target=="" {return nil,fail(call,"scene: %q is not a path of a file",sc.scene),0}
        if !os.is_file(target) {return nil,fail(call,"scene: %s is not there",target),0}
        if !project.path_same(target,document_file(s.document)) {
            switch {
            case owner!=0:
                return nil,fail(call,"scene: the scenario plays %s and the document is %s; a turn does not open another scene: run it with mirai play test, or ask the user to open that scene",sc.scene,document_path(s.document)),0
            case document_dirty(s):
                return nil,fail(call,"scene: the scenario plays %s and the document %s has unsaved changes: save them (scene.save) or open %s",sc.scene,document_path(s.document),sc.scene),0
            }
            path,_:=serial.text_encode(struct{path:string}{target},.Line,context.temp_allocator)
            if _,error,ok:=api_scenario_call(server,"scene.open",string(path),answer_buffer[:]);!ok {
                return nil,fail(call,"scene: %s could not be opened: %s",sc.scene,error.message),0
            }
        }
    }
    _,error,ok:=api_scenario_call(server,"play.start",string(sc.start),answer_buffer[:])
    if !ok {return nil,fail(call,"play.start: %s",error.message),0}
    defer api_scenario_call(server,"play.stop","{}",answer_buffer[:])
    // Each step rewinds the scratch it used, and the frames it runs free the
    // temporary memory: what it leaves is kept after the rewind.
    steps:=make([dynamic]Api_Scenario_Step,call.allocator)
    answer:serial.Writer
    serial.writer_init(&answer,0,s.app.allocator)
    defer serial.writer_destroy(&answer)
    for &step,i in sc.steps {
        if api_stop_asked(s) {return steps[:],"cancelled",tick}
        api.server_progress(server,fmt.tprintf("step %d of %d: %s",i+1,len(sc.steps),step.name!=""?step.name:step.method),i,len(sc.steps))
        method:=api.method_find(server,step.method)
        serial.writer_reset(&answer)
        mark:=base.arena_mark(&server.scratch)
        step_error,answered:=api.method_execute(server,method,string(step.params),&answer)
        server.image=""
        why:=step_error.message
        held:=answered
        if answered {held,why=scenario_step_held(string(step.params),string(serial.writer_bytes(&answer)))}
        if r,_:=api_play_run(s,call);r!=nil {
            if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {tick=t.tick}
        } else if held {
            held,why=false,"the game stopped"
        }
        why=fmt.tprintf("steps[%d] %s: %s",i,step.method,why)
        base.arena_rewind(&server.scratch,mark)
        report:=Api_Scenario_Step{name=step.name,method=step.method,result="null",passed=held,tick=tick}
        if answered {report.result=serial.Json(strings.clone(string(serial.writer_bytes(&answer)),call.allocator))} else {report.error=strings.clone(step_error.message,call.allocator)}
        append(&steps,report)
        if !held {failure=strings.clone(why,call.allocator);break}
    }
    return steps[:],failure,tick
}
