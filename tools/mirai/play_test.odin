package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:editor/api"
import "mirai:project"

PLAY_TEST_USAGE :: "play test [project] [scenario...] [--dev|--release]"

// The folder and extension of the scenarios of a project, as the editor reads
// them (editor/api_play_scenario.odin).
PLAY_SCENARIO_FOLDER :: "tests/scenarios"
PLAY_SCENARIO_EXTENSION :: ".mirai"

// mirai play test: plays the scenarios of a project, gameplay tests written as
// files, in a headless editor: the session of the project (mirai session), or
// one it opens for them and closes. A scenario is named by its name in
// tests/scenarios or by its path; none: all of tests/scenarios. Prints a line
// per scenario and, for one that fails, the step and what its method
// answered. Exit 0 when all pass, 1 when one fails, 2 when they cannot run.
cmd_play_test :: proc(root:string,args:[]string) -> int {
    mode,rest,ok:=build_mode_take(args)
    usage :: proc() -> int {fmt.eprintfln("Usage: mirai %s",PLAY_TEST_USAGE);return 2}
    if !ok {return usage()}
    folder:="."
    names:=make([dynamic]string,context.temp_allocator)
    for arg,i in rest {
        if strings.has_prefix(arg,"-") {return usage()}
        if i==0 && os.is_file(project.path(arg,project.PROJECT_FILE,allocator=context.temp_allocator)) {folder=arg;continue}
        append(&names,arg)
    }
    if !os.is_file(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator)) {
        fmt.eprintfln("mirai play test: %s is not a project (%s is missing); give the project first",folder,project.PROJECT_FILE)
        return 2
    }
    folder=project.path_absolute(folder)
    files,problem:=play_scenario_files(folder,names[:])
    if problem!="" {fmt.eprintfln("mirai play test: %s",problem);return 2}

    file,reused,code:=session_borrow(root,folder,mode,"play test")
    if code!=0 {return code}
    defer if !reused {session_close(folder,file,true)}

    Step :: struct {method,name:string,passed:bool,tick:u64,result:json.Value,error:string}
    Report :: struct {path:string,passed:bool,failure:string,tick:u64,steps:int,ran:[]Step}
    Result :: struct {scenarios:[]Report}
    failed:=0
    for path in files {
        params,_:=json.marshal(struct{path:string}{path},allocator=context.temp_allocator)
        response,err,called:=api.rpc_call(file.port,"play.scenario.run",string(params),1,3600000,context.allocator)
        if !called {
            fmt.eprintfln("mirai play test: %s: %s",path,api.error_text(err,context.temp_allocator))
            return 2
        }
        result:Result
        if json.unmarshal_string(response,&result,allocator=context.temp_allocator)!=nil || len(result.scenarios)!=1 {
            fmt.eprintfln("mirai play test: %s: the editor answered %s",path,response)
            return 2
        }
        report:=result.scenarios[0]
        if report.passed {
            fmt.printfln("PASS %s (%d steps, tick %d)",report.path,report.steps,report.tick)
            continue
        }
        failed+=1
        fmt.printfln("FAIL %s: %s",report.path,report.failure)
        if len(report.ran)>0 {
            last:=report.ran[len(report.ran)-1]
            if answer,_:=json.marshal(last.result,allocator=context.temp_allocator);last.error=="" {
                fmt.printfln("  at tick %d %s answered %s",last.tick,last.method,string(answer))
            }
        }
    }
    fmt.printfln("%d of %d scenarios passed.",len(files)-failed,len(files))
    return failed>0?1:0
}

// The scenario files of names: a name of tests/scenarios (with or without
// its extension) or a path; none: every file of tests/scenarios, by name.
play_scenario_files :: proc(folder:string,names:[]string) -> (files:[]string,problem:string) {
    scenarios:=project.path(folder,PLAY_SCENARIO_FOLDER,allocator=context.temp_allocator)
    list:=make([dynamic]string,context.temp_allocator)
    if len(names)==0 {
        entries,error:=os.read_all_directory_by_path(scenarios,context.temp_allocator)
        if error!=nil {return nil,fmt.tprintf("%s has no scenarios: write them as %s files there",scenarios,PLAY_SCENARIO_EXTENSION)}
        for entry in entries {
            if entry.type!=.Directory && strings.has_suffix(entry.name,PLAY_SCENARIO_EXTENSION) {append(&list,project.path(scenarios,entry.name,allocator=context.temp_allocator))}
        }
        if len(list)==0 {return nil,fmt.tprintf("%s has no scenarios: write them as %s files there",scenarios,PLAY_SCENARIO_EXTENSION)}
        slice.sort(list[:])
        return list[:],""
    }
    for name in names {
        path:=name
        if !strings.contains_any(name,"/\\") {
            path=project.path(scenarios,strings.has_suffix(name,PLAY_SCENARIO_EXTENSION)?name:strings.concatenate({name,PLAY_SCENARIO_EXTENSION},context.temp_allocator),allocator=context.temp_allocator)
        }
        path=project.path_absolute(path,context.temp_allocator)
        if !os.is_file(path) {return nil,fmt.tprintf("%s: %s is not there",name,path)}
        append(&list,path)
    }
    return list[:],""
}
