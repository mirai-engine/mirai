package build

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:project"
import "mirai:std/base"

// A test executable stands while the content of what its build read stands,
// the test files of the packages it imports among it: a date that moves or a
// text put back compiles nothing; an edit, another flag or a missing
// executable compiles.
@(test)
a_test_executable_is_current_by_the_content_of_what_its_build_read :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=base.test_folder(t,"test-current")
    if root=="" {return}
    file :: proc(root:string,parts:..string) -> string {
        all:=make([dynamic]string,context.temp_allocator)
        append(&all,root)
        append(&all,..parts)
        return project.path(..all[:],allocator=context.temp_allocator)
    }
    for folder in ([]string{"pkg","lib","bin"}) {
        if !testing.expect(t,os.make_directory_all(file(root,folder))==nil) {return}
    }
    compiler:=file(root,"bin","odin")
    sources:=[]string{file(root,"pkg","a.odin"),file(root,"pkg","a_test.odin"),file(root,"lib","lib.odin")}
    imported_tests:=file(root,"lib","lib_test.odin")
    for path in ([]string{compiler,sources[0],sources[1],sources[2],imported_tests}) {
        if !testing.expect(t,os.write_entire_file(path,"package x")==nil) {return}
        if !testing.expect(t,os.change_times(path,time.unix(100,0),time.unix(100,0))==nil) {return}
    }
    executable:=test_executable(file(root,"tests"),root,file(root,"pkg"))
    testing.expect_value(t,executable,file(root,"tests",strings.concatenate({"pkg",project.EXECUTABLE_SUFFIX})))
    flags:=[]string{"-o:minimal"}
    planned:=test_build_plan(root,compiler,file(root,"pkg"),executable,flags)
    if !testing.expect(t,len(planned.command)>0,"without an executable it compiles") {return}
    // What the compiler would leave.
    if !testing.expect(t,os.make_directory_all(file(root,"tests"))==nil) {return}
    if !testing.expect(t,os.write_entire_file(planned.compile.staged,"executable")==nil) {return}
    export:=struct {source_files,load_files:[]string}{source_files=sources}
    data,_:=json.marshal(export)
    if !testing.expect(t,os.write_entire_file(planned.sources_staged,data)==nil) {return}
    listed,_:=dependencies_read(planned.sources_staged,context.temp_allocator)
    published,stamped:=publish_and_stamp(planned.compile.staged,executable,strings.concatenate({executable,".old"}),listed,{file=test_stamp_file(executable),sources_file=test_sources_file(executable),sources_staged=planned.sources_staged,root=root,compiler=compiler,flags=planned.flags,tests=true,started=time.now()})
    if !testing.expect(t,published && stamped) {return}
    current :: proc(root,compiler,executable:string,flags:[]string) -> bool {
        return len(test_build_plan(root,compiler,project.path(root,"pkg",allocator=context.temp_allocator),executable,flags).command)==0
    }
    testing.expect(t,current(root,compiler,executable,flags),"built from what is there")
    testing.expect(t,os.change_times(sources[0],time.unix(500,0),time.unix(500,0))==nil)
    testing.expect(t,current(root,compiler,executable,flags),"a date is no change")
    testing.expect(t,!current(root,compiler,executable,{"-o:speed"}),"another flag")
    testing.expect(t,os.write_entire_file(imported_tests,"package x\nhelper :: 1")==nil)
    testing.expect(t,!current(root,compiler,executable,flags),"a test file of an imported package is read")
    testing.expect(t,os.write_entire_file(imported_tests,"package x")==nil)
    testing.expect(t,current(root,compiler,executable,flags),"the text put back")
    testing.expect(t,os.remove(executable)==nil)
    testing.expect(t,!current(root,compiler,executable,flags),"the executable is gone")
}

// A test executable builds, runs in the root it was planned with whatever
// package it tests (a relative path in a test is relative to the engine), runs
// the tests asked and says which failed with what they logged.
@(test)
a_test_executable_runs_in_the_root_and_reports_its_tests :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    compiler,found:=compiler_find("")
    if !found {
        log.warn("no Odin compiler: MIRAI_ODIN names it under mirai test")
        return
    }
    root:=base.test_folder(t,"test-run")
    if root=="" {return}
    folder:=project.path(root,"project","game")
    if !testing.expect(t,os.make_directory_all(folder)==nil) {return}
    if !testing.expect(t,os.write_entire_file(project.path(root,"marker.txt"),"here")==nil) {return}
    source:=`package game

import "core:os"
import "core:testing"

@(test)
sees_the_root :: proc(t:^testing.T) {testing.expect(t,os.is_file("marker.txt"),"not run in the root")}

@(test)
fails_on_purpose :: proc(t:^testing.T) {testing.expect(t,false,"on purpose")}

@(test)
not_asked :: proc(t:^testing.T) {testing.expect(t,false,"ran without being asked")}
`
    if !testing.expect(t,os.write_entire_file(project.path(folder,"game_test.odin"),source)==nil) {return}
    b:=test_build_plan(root,compiler,folder,test_executable(project.path(root,"tests"),root,folder),{"-o:minimal"})
    if !testing.expect(t,test_build_start(&b),b.said) {return}
    for !test_build_poll(&b,50*time.Millisecond) {}
    if !testing.expectf(t,b.failure==.None,"%s %v",b.said,b.diagnostics) {return}
    r:Test_Run
    if !testing.expect(t,test_run_start(&r,&b,"project/game",{names={"sees_the_root","fails_on_purpose"},timeout=TEST_TIMEOUT,quiet=true})) {return}
    for !test_run_poll(&r,50*time.Millisecond) {}
    report,ok:=test_run_report(&r)
    testing.expect(t,!ok)
    testing.expect_value(t,report.total,2)
    testing.expect_value(t,report.passed,1)
    if testing.expectf(t,len(report.failed)==1,"%v",report.failed) {
        testing.expect_value(t,report.failed[0].name,"fails_on_purpose")
        testing.expectf(t,len(report.failed[0].messages)==1 && strings.contains(report.failed[0].messages[0],"on purpose"),"%v",report.failed[0].messages)
    }
}

// A test of a game compiles against the declarations of the engine libraries,
// which carry no test file: the test-world builder of core, how a test builds
// a world of its steps, is public API in them.
@(test)
the_declarations_of_core_carry_the_test_world_builder :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"decl-core")
    if folder=="" {return}
    engine:=project.path_absolute(project.path(#directory,"..",".."))
    decl:=project.path(folder,"decl")
    errors,_:=declare({root=engine,packages={"core"},binary="mirai",library=project.path(folder,"core.lib"),stage=project.path(folder,"stage"),decl=decl})
    if !testing.expectf(t,len(errors)==0,"%v",errors) {return}
    text:=strings.builder_make()
    entries,_:=os.read_all_directory_by_path(project.path(decl,"core"),context.temp_allocator)
    for entry in entries {
        data,_:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        strings.write_string(&text,string(data))
    }
    declared:=strings.to_string(text)
    for name in ([]string{"Test_World :: struct","test_world_init ::","test_world_destroy ::","test_info ::"}) {
        testing.expectf(t,strings.contains(declared,name),"the declarations of core lack %s",name)
    }
}

// The code of a project compiles into libraries of its own, game/ and
// editor/ besides its plugins, each from a stage without the tests the
// compiler would otherwise read with their folder, and the library of the
// project reads their declarations; the game that ships, a check and a test
// build read the project itself.
@(test)
the_code_of_a_project_compiles_into_libraries_without_its_tests :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"stage")
    if folder=="" {return}
    root,engine:=project.path(folder,"project"),project.path(folder,"engine")
    files:=[?]string{"game/game.odin","game/game_test.odin","game/testdata/fixture.odin","game/sub/sub.odin","assets/script.odin","editor/tool.odin"}
    for file in files {
        path:=project.path(root,file)
        if !testing.expect(t,os.make_directory_all(path[:strings.last_index_byte(path,'/')])==nil) {return}
        if !testing.expect(t,os.write_entire_file(path,"package x\n")==nil) {return}
    }
    if !testing.expect(t,os.make_directory_all(project.path(engine,"plugins"))==nil) {return}
    p:=project.Project{root=root,engine_root=engine}
    libraries:=plugin_libraries(&p,true)
    if !testing.expect_value(t,len(libraries),2) {return}
    game,editor:=&libraries[0],&libraries[1]
    testing.expect(t,game.project && slice.equal(game.packages,[]string{"game","game/sub"}),"the game library has its packages but testdata")
    testing.expect(t,editor.part==.Editor && slice.equal(editor.project_needs,game.packages),"editor/ compiles against the game")
    plugin_library_name(root,game,0)
    if failed:=plugin_library_prepare(game,nil);!testing.expectf(t,len(failed)==0,"%v",failed) {return}
    testing.expect(t,os.is_file(project.path(game.stage,"game/game.odin")) && !os.is_file(project.path(game.stage,"game/game_test.odin")),"the stage has no tests")

    collection :: proc(flags:[]string) -> string {
        for flag in flags {if strings.has_prefix(flag,"-collection:project=") {return flag[len("-collection:project="):]}}
        return ""
    }
    testing.expect_value(t,collection(target_flags(&p,.Editor,nil,context.temp_allocator,dev=true)),project_decl(root,"minimal"))
    testing.expect_value(t,collection(target_flags(&p,.Game,nil,context.temp_allocator,dev=true)),root)
    job:=Job{root=root,flags=target_flags(&p,.Editor,nil,context.temp_allocator,dev=true)}
    testing.expect_value(t,collection(probe_flags(&job)),root)
}

// The output of the runner: which tests run and which failed with what they
// logged, the state changes the runner asked for hidden, the info hidden when
// quiet, and the hint to recompile with ODIN_TEST_NAMES left out. The fatal
// message of a test can come before its start.
@(test)
the_output_of_the_runner_says_what_runs_and_what_failed :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    run:=Test_Run{output={quiet=true,states_hidden=true,finished=-1},exit_code=1}
    out:=&run.output
    lines:=[]string{
        "[INFO ] --- [2026-10-28 00:12:48] Starting test runner with 4 threads.",
        "[INFO ] --- [2026-10-28 00:12:48] Test #0 main.fast changed state to Running.",
        "[INFO ] --- [2026-10-28 00:12:48] Test #1 main.slow changed state to Running.",
        "[FATAL] --- [2026-10-28 00:12:48] [x_test.odin:20:broken()] runtime assertion: no",
        "[INFO ] --- [2026-10-28 00:12:48] Test #2 main.broken changed state to Running.",
        "[INFO ] --- [2026-10-28 00:12:48] Test #3 main.crashes changed state to Running.",
        "a line a test printed",
        "[ERROR] --- [2026-10-28 00:12:48] [x_test.odin:9:slow()] expected 1, got 2",
        "[INFO ] --- [2026-10-28 00:12:48] Test #1 main.slow changed state to Failed.",
        "[INFO ] --- [2026-10-28 00:12:48] Test #0 main.fast changed state to Successful.",
        "C:/x/x_test.odin(30:5) Index 3 is out of range 0..<2",
        "[FATAL] --- [2026-10-28 00:12:48] Caught signal to stop test #3 main.crashes for: Illegal_Instruction.",
        "",
        "Finished 4 tests in 1.2s. 3 tests failed.",
        " - main.broken\truntime assertion: no",
        " - main.crashes\tSignal caught: Illegal_Instruction",
        " - main.slow   \texpected 1, got 2",
        "",
        "To run only the failed tests, use:",
        "\t-define:ODIN_TEST_NAMES=main.broken,main.crashes,main.slow,",
        "If your terminal supports OSC 52, you may use -define:ODIN_TEST_CLIPBOARD.",
    }
    shown:=make([dynamic]string)
    start:=time.tick_now()
    for line,i in lines {
        if text,show:=test_output_line(out,line,start);show {append(&shown,text)}
        if i==5 {testing.expectf(t,len(out.running)==3 && "main.broken" not_in out.running,"running: %v",out.running)}
    }
    testing.expect_value(t,len(out.running),0)
    expected:=[]string{
        "[FATAL] --- [2026-10-28 00:12:48] [x_test.odin:20:broken()] runtime assertion: no",
        "[ERROR] --- [2026-10-28 00:12:48] [x_test.odin:9:slow()] expected 1, got 2",
        "C:/x/x_test.odin(30:5) Index 3 is out of range 0..<2",
        "[FATAL] --- [2026-10-28 00:12:48] Caught signal to stop test #3 main.crashes for: Illegal_Instruction.",
        "Finished 4 tests in 1.2s. 3 tests failed.",
        " - main.broken\truntime assertion: no",
        " - main.crashes\tSignal caught: Illegal_Instruction",
        " - main.slow   \texpected 1, got 2",
    }
    testing.expectf(t,slice.equal(shown[:],expected),"shown:\n%s",strings.join(shown[:],"\n"))

    report,ok:=test_run_report(&run)
    testing.expect(t,!ok)
    testing.expect_value(t,report.total,4)
    testing.expect_value(t,report.passed,1)
    names:=make([dynamic]string)
    for failure in report.failed {
        append(&names,failure.name)
        testing.expect_value(t,failure.package_name,"main")
        if failure.name=="slow" {testing.expectf(t,len(failure.messages)==1 && strings.contains(failure.messages[0],"expected 1, got 2"),"%v",failure.messages)}
    }
    slice.sort(names[:])
    testing.expectf(t,slice.equal(names[:],[]string{"broken","crashes","slow"}),"failed: %v",names[:])

    // Without quiet, what a test prints and the info stay; the state changes asked by a flag too.
    loud:=Test_Output{finished=-1}
    _,show:=test_output_line(&loud,"[INFO ] --- [2026-10-28 00:12:48] Test #0 main.fast changed state to Running.",start)
    testing.expect(t,show)
    _,show=test_output_line(&loud,"a line a test printed",start)
    testing.expect(t,show)
}

// The executable hangs when no test started or ended for the timeout, also
// before the first one; never without a timeout.
@(test)
an_executable_hangs_when_no_test_starts_or_ends_for_the_timeout :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    out:=Test_Output{states_hidden=true,finished=-1}
    start:=time.tick_now()
    out.changed=start
    later :: proc(tick:time.Tick,seconds:int) -> time.Tick {return {tick._nsec+i64(seconds)*i64(time.Second)}}
    testing.expect(t,!test_hung(out,2*time.Minute,later(start,119)))
    testing.expect(t,test_hung(out,2*time.Minute,later(start,120)))
    test_output_line(&out,"[INFO ] --- [2026-10-28 00:12:48] Test #0 main.waits changed state to Running.",later(start,100))
    testing.expect(t,!test_hung(out,2*time.Minute,later(start,200)))
    testing.expect(t,test_hung(out,2*time.Minute,later(start,220)))
    testing.expect(t,!test_hung(out,0,later(start,10000)))
}

// The runner asks core:testing for the state changes unless a flag does, and
// does not see them when a flag turns them off or logs less.
@(test)
the_state_changes_are_asked_unless_a_flag_decides :: proc(t:^testing.T) {
    cases:=[?]struct{flag:string,added,seen:bool}{
        {"-define:FOO=1",true,true},
        {"-define:ODIN_TEST_LOG_STATE_CHANGES=true",false,true},
        {"-define:ODIN_TEST_LOG_STATE_CHANGES=false",false,false},
        {"-define:ODIN_TEST_LOG_LEVEL=warning",true,false},
    }
    for c in cases {
        added,seen:=test_states_asked({c.flag})
        testing.expectf(t,added==c.added && seen==c.seen,"%s: added %v, seen %v",c.flag,added,seen)
    }
}

// The threads of a test executable reserve 8 MB of stack on every system, unless the flags pass
// linker flags of their own.
@(test)
the_threads_of_a_test_executable_get_the_stack_of_the_system_with_the_most :: proc(t:^testing.T) {
    when ODIN_OS==.Windows {
        testing.expect_value(t,test_link_flag({"-debug"}),"-extra-linker-flags:/STACK:8388608")
    } else {
        testing.expect_value(t,test_link_flag({"-debug"}),"")
    }
    testing.expect_value(t,test_link_flag({"-extra-linker-flags:/DEBUG"}),"")
}
