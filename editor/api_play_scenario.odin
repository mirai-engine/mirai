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
//     {"name": "walk", "method": "play.step", "params": {"seconds": 1, "keys": ["W"]}},
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
    scenarios:[1]Api_Scenario_Report `mirai:"list,label=One per file in the order of their names"`,
}
Api_Scenario_Report :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text,label=The file: relative to the project when it is inside"`,
    scene:[API_PATH_BYTES]u8 `mirai:"text,label=The scene it played as the file names it; empty: the one open"`,
    steps:int `mirai:"label=Steps of the file"`,
    ran:[1]Api_Scenario_Step `mirai:"list,label=The steps it ran in order up to the first that failed"`,
    passed:bool,
    failure:[API_SCENARIO_TEXT]u8 `mirai:"text,label=What failed first and why; empty when it passed"`,
    tick:u64 `mirai:"label=The tick of the game when it stopped"`,
}
Api_Scenario_Step :: struct {
    name:[128]u8 `mirai:"optional,text,label=The name the file gives it"`,
    method:[64]u8 `mirai:"text"`,
    result:u8 `mirai:"any,label=What the method answered as it answers a call; null when the call failed"`,
    passed:bool,
    tick:u64 `mirai:"label=The tick of the game after it"`,
    error:[API_SCENARIO_TEXT]u8 `mirai:"text,label=Why the call failed; empty when it answered"`,
}

// A scenario as its file gives it: texts of the file, params as JSON.
@(private)
Scenario :: struct {
    scene:string,
    start:string,
    steps:[]Scenario_Step,
}
@(private)
Scenario_Step :: struct {
    name,method,params:string,
}

@(private)
api_play_scenario_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="play.scenario.run",summary="Plays the scenarios of the project, gameplay tests written as files: each plays its scene from the first tick, runs its steps (calls of play.input, play.step, play.check, play.spawn, capture and the other play methods) and stops; says per step whether it passed, at which tick and what its method answered.",params=Api_Play_Scenario_Params,result=Api_Play_Scenario_Result,writes_result=true,run=api_play_scenario_run})
}

// The keys of a JSON object in values, in the order of keys; problem names a
// key it does not take, or says it is not an object. at prefixes problems.
@(private)
scenario_object :: proc(text,at:string,keys:[]string,values:[]string,allocator:=context.allocator) -> (problem:string) {
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,allocator)
    if !serial.text_accept(&r,'{') {return fmt.aprintf("%sgive an object {...}",at,allocator=allocator)}
    if serial.text_accept(&r,'}') {return ""}
    for {
        key,ok:=serial.text_string(&r)
        if !ok || !serial.text_expect(&r,':') {return fmt.aprintf("%sis not valid JSON",at,allocator=allocator)}
        slot:=-1
        for name,i in keys {if name==key {slot=i;break}}
        if slot<0 {return fmt.aprintf("%s%q is not a key of it; it takes %s",at,key,strings.join(keys,", ",allocator),allocator=allocator)}
        serial.text_peek(&r)
        start:=r.offset
        if !serial.text_skip(&r) {return fmt.aprintf("%s%s: the value is not valid JSON",at,key,allocator=allocator)}
        values[slot]=r.text[start:r.offset]
        if serial.text_accept(&r,'}') {break}
        if !serial.text_expect(&r,',') {return fmt.aprintf("%sis not valid JSON after %s",at,key,allocator=allocator)}
    }
    if !serial.text_end(&r) {return fmt.aprintf("%shas text after the object",at,allocator=allocator)}
    return ""
}

// Reads the text of a scenario file; problem says what is wrong and where.
// The methods of its steps are checked by api_scenario_check.
@(private)
scenario_parse :: proc(text:string,allocator:=context.allocator) -> (sc:Scenario,problem:string) {
    keys:=[?]string{"scene","start","steps"}
    values:[len(keys)]string
    if problem=scenario_object(text,"the file: ",keys[:],values[:],allocator);problem!="" {return}
    if values[0]!="" {
        ok:bool
        if sc.scene,ok=api.string_value(allocator,values[0]);!ok || sc.scene=="" {return {},"scene: give the scene it plays as a path, as \"scenes/main.scene\""}
    }
    sc.start="{}"
    if values[1]!="" {
        if !strings.has_prefix(values[1],"{") {return {},"start: give the params of play.start as an object, as {\"players\": 1}"}
        sc.start=values[1]
    }
    count:=api_list_count(values[2])
    if count==0 {return {},`steps: give the steps in order, as [{"method": "play.step", "params": {"ticks": 60}}, {"method": "play.check", "params": {"conditions": [...]}}]`}
    if count>API_SCENARIO_STEPS {return {},fmt.aprintf("steps: %d steps, and a scenario takes %d at most: split it into several files",count,API_SCENARIO_STEPS,allocator=allocator)}
    items:=make([]string,count,allocator)
    api_list_items(values[2],items)
    sc.steps=make([]Scenario_Step,count,allocator)
    step_keys:=[?]string{"name","method","params"}
    for &step,i in sc.steps {
        at:=fmt.aprintf("steps[%d]: ",i,allocator=allocator)
        fields:[len(step_keys)]string
        if problem=scenario_object(items[i],at,step_keys[:],fields[:],allocator);problem!="" {return {},problem}
        ok:bool
        if fields[0]!="" {
            if step.name,ok=api.string_value(allocator,fields[0]);!ok {return {},fmt.aprintf("%sname is a text",at,allocator=allocator)}
        }
        if step.method,ok=api.string_value(allocator,fields[1]);!ok || step.method=="" {
            return {},fmt.aprintf("%sgive its method, as \"method\": \"play.step\"",at,allocator=allocator)
        }
        step.params="{}"
        if fields[2]!="" {
            if !strings.has_prefix(fields[2],"{") {return {},fmt.aprintf("%sparams: give the params of %s as an object",at,step.method,allocator=allocator)}
            step.params=fields[2]
        }
    }
    return
}

// Whether a scenario may call a method; why not when it may not.
@(private)
scenario_method_refusal :: proc(name:string) -> string {
    switch {
    case name=="play.start" || name=="play.stop": return "the scenario starts the game before its steps and stops it after them: leave it out (start takes the params of play.start)"
    case strings.has_prefix(name,"play.scenario."): return "a scenario does not run scenarios"
    case !strings.has_prefix(name,"play.") && name!="capture": return "a scenario plays the game: its steps are play methods and capture (play.input, play.step, play.check, play.spawn, play.set...)"
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
        mark:=base.arena_mark(&server.scratch)
        _,_,error,read:=api.params_read(server,method,step.params)
        base.arena_rewind(&server.scratch,mark)
        if !read {return fmt.aprintf("steps[%d].params: %s",i,error.message,allocator=allocator)}
        if method.params==serial.TYPE_NONE && !api.json_valid(allocator,step.params) {return fmt.aprintf("steps[%d].params: not valid JSON",i,allocator=allocator)}
    }
    if start:=api.method_find(server,"play.start");start!=nil {
        mark:=base.arena_mark(&server.scratch)
        _,_,error,read:=api.params_read(server,start,sc.start)
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
    file,wrong:=api_output_path(root,given,allocator)
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
    out:=call.out
    failed:=0
    serial.text_write_raw(out,`{"scenarios":[`)
    for file,i in files {
        if i>0 {serial.write_u8(out,',')}
        if !api_scenario_play(s,call,file,out) {failed+=1}
        if out.overflow>0 {break}
    }
    serial.write_u8(out,']')
    api.write_bool(out,"passed",failed==0)
    api.write_int(out,"total",i64(len(files)))
    api.write_int(out,"failed",i64(failed))
    serial.write_u8(out,'}')
}

// Plays one scenario file and writes its report to out; whether it passed.
@(private)
api_scenario_play :: proc(s:^Session,call:^api.Call,file:string,out:^serial.Writer) -> (passed:bool) {
    server:=call.server
    failure_buffer:[API_SCENARIO_TEXT]u8
    failure:string
    tick:u64
    shown:=file
    if root:=s.project_root;root!="" && strings.has_prefix(file,root) && len(file)>len(root) && file[len(root)]=='/' {shown=file[len(root)+1:]}
    serial.write_u8(out,'{')
    api.write_text(out,"path",shown,true)
    sc:Scenario
    text,read_error:=os.read_entire_file(file,call.allocator)
    switch {
    case read_error!=nil:
        failure=fmt.bprintf(failure_buffer[:],"the file could not be read: %s",os.error_string(read_error))
    case len(text)>API_SCENARIO_FILE_BYTES:
        failure=fmt.bprintf(failure_buffer[:],"the file has %d bytes and a scenario takes %d at most: split it",len(text),API_SCENARIO_FILE_BYTES)
    case:
        wrong:string
        if sc,wrong=scenario_parse(string(text),call.allocator);wrong=="" {wrong=api_scenario_check(server,&sc,call.allocator)}
        if wrong!="" {failure=fmt.bprintf(failure_buffer[:],"%s",wrong)}
    }
    api.write_text(out,"scene",sc.scene)
    api.write_int(out,"steps",i64(len(sc.steps)))
    api.write_key(out,"ran");serial.write_u8(out,'[')
    if failure=="" {failure,tick=api_scenario_steps(s,call,&sc,out,failure_buffer[:])}
    serial.write_u8(out,']')
    api.write_bool(out,"passed",failure=="")
    api.write_text(out,"failure",failure)
    api.write_uint(out,"tick",tick)
    serial.write_u8(out,'}')
    return failure==""
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
api_scenario_steps :: proc(s:^Session,call:^api.Call,sc:^Scenario,out:^serial.Writer,buffer:[]u8) -> (failure:string,tick:u64) {
    server:=call.server
    owner:=ai_task_of_call(s,call)
    answer_buffer:[4096]u8
    if run_find(s,owner)!=nil {
        return fmt.bprintf(buffer,"a game is already playing: stop it (play.stop) and run the scenario again"),0
    }
    if sc.scene!="" {
        target:=scene_file(s,sc.scene)
        if target=="" {return fmt.bprintf(buffer,"scene: %q is not a path of a file",sc.scene),0}
        if !os.is_file(target) {return fmt.bprintf(buffer,"scene: %s is not there",target),0}
        when ODIN_OS==.Windows {same:=strings.equal_fold(target,document_file(s.document))} else {same:=target==document_file(s.document)}
        if !same {
            switch {
            case owner!=0:
                return fmt.bprintf(buffer,"scene: the scenario plays %s and the document is %s; a turn does not open another scene: run it with mirai play test, or ask the user to open that scene",sc.scene,document_path(s.document)),0
            case document_dirty(s):
                return fmt.bprintf(buffer,"scene: the scenario plays %s and the document %s has unsaved changes: save them (scene.save) or open %s",sc.scene,document_path(s.document),sc.scene),0
            }
            path:serial.Writer
            serial.writer_init(&path,0,context.temp_allocator)
            serial.text_write_raw(&path,`{"path":`);serial.text_write_string(&path,target);serial.write_u8(&path,'}')
            if _,error,ok:=api_scenario_call(server,"scene.open",string(serial.writer_bytes(&path)),answer_buffer[:]);!ok {
                return fmt.bprintf(buffer,"scene: %s could not be opened: %s",sc.scene,error.message),0
            }
        }
    }
    _,error,ok:=api_scenario_call(server,"play.start",sc.start,answer_buffer[:])
    if !ok {return fmt.bprintf(buffer,"play.start: %s",error.message),0}
    defer api_scenario_call(server,"play.stop","{}",answer_buffer[:])
    for &step,i in sc.steps {
        method:=api.method_find(server,step.method)
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_text(out,"method",step.method,true)
        if step.name!="" {api.write_text(out,"name",step.name)}
        api.write_key(out,"result")
        start:=out.count
        mark:=base.arena_mark(&server.scratch)
        step_error,answered:=api.method_execute(server,method,step.params,out)
        server.image=""
        held:=answered
        if answered {
            why:string
            if held,why=scenario_step_held(step.params,string(out.data[start:min(out.count,len(out.data))]));!held {
                failure=fmt.bprintf(buffer,"steps[%d] %s: %s",i,step.method,why)
            }
        } else {
            out.count,out.overflow=start,0
            serial.text_write_raw(out,"null")
            failure=fmt.bprintf(buffer,"steps[%d] %s: %s",i,step.method,step_error.message)
        }
        if r,_:=api_play_run(s,call);r!=nil {
            if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {tick=t.tick}
        } else if held {
            failure=fmt.bprintf(buffer,"steps[%d] %s: the game stopped",i,step.method)
            held=false
        }
        api.write_bool(out,"passed",held)
        api.write_uint(out,"tick",tick)
        api.write_text(out,"error",answered?"":step_error.message)
        serial.write_u8(out,'}')
        base.arena_rewind(&server.scratch,mark)
        if !held || out.overflow>0 {break}
    }
    return
}
