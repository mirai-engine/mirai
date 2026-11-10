package editor

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:cook/build"
import "mirai:project"
import "mirai:std/base"

// A run of the tests that build.test asks for holds neither the call nor a
// frame: it returns while its job opens the project, plans and compiles, in a
// thread of its own, one at a time, against the libraries this editor builds
// and loads whatever the manifest optimizes for.
@(test)
a_run_of_the_tests_starts_without_waiting_against_the_libraries_of_the_editor :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"probe")
    if folder=="" {return}
    root,engine:=project.path(folder,"project"),project.path(folder,"engine")
    for path in ([]string{project.path(root,"game"),project.path(engine,"plugins")}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    files:=[?][2]string{
        {project.path(root,project.PROJECT_FILE),`{"name": "Probe", "build": {"optimization": "Speed"}}`},
        {project.path(root,"game","game.odin"),"package game\n"},
        {project.path(root,"game","game_test.odin"),"package game\n\nimport \"core:testing\"\n\n@(test)\nruns :: proc(t:^testing.T) {}\n"},
    }
    for file in files {
        if !testing.expect(t,os.write_entire_file(file[0],file[1])==nil) {return}
    }
    b:Build_State
    s:=Session{build=&b,has_project=true,project_root=project.path_absolute(root),engine_root=project.path_absolute(engine)}
    defer probe_free(&b)
    game:=project.path_absolute(project.path(root,"game"))
    testing.expect_value(t,code_probe_start(&s,.Test,game,nil,60),"")
    testing.expect(t,probe_running(&b),"it returns while the job runs")
    testing.expect(t,code_probe_start(&s,.Test,game,nil,60)!="","one at a time")
    started:=time.tick_now()
    for probe_running(&b) && time.tick_since(started)<2*time.Minute {time.sleep(10*time.Millisecond)}
    probe_poll(&s)
    job:=probe_job(&b)
    if !testing.expect(t,job!=nil,"the job ended and its thread joined") {return}
    mode:="minimal" if build.ENGINE_MODE_HERE==.Dev else "speed"
    plugins:=""
    for flag in job.flags {
        if strings.has_prefix(flag,"-collection:plugins=") {plugins=flag}
    }
    testing.expectf(t,strings.has_suffix(plugins,strings.concatenate({"/",mode,"/decl"})),"the plugin libraries of the editor's mode: %q",plugins)
}
