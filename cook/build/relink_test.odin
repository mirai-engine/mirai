package build

import "core:mem/virtual"
import "core:os"
import "mirai:std/subprocess"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

// A change inside a procedure of a plugin library renames it, and what links
// against it links its objects again against the new name instead of
// compiling; a change of what it declares compiles them.
@(test)
a_change_inside_a_procedure_links_what_links_against_it_again :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    repository:=slashes(project.path_absolute(#directory+"../..",context.temp_allocator),context.temp_allocator)
    compiler,found:=compiler_find(repository,context.temp_allocator)
    if !testing.expect(t,found,"no Odin compiler") {return}
    folder:=base.test_folder(t,"relink")
    if folder=="" {return}
    base_source:="engine/plugins/base_thing/runtime/base.odin"
    files:=[][2]string{
        {"engine/core/data.odin","package core\n"},
        {"engine/plugins/base_thing/plugin.mirai",`{"name": "base_thing", "version": "1.0.0", "parts": ["Runtime"]}`},
        {base_source,"package base_thing\n\nanswer :: proc() -> i32 {return 21}\n"},
        {"engine/plugins/middle/plugin.mirai",`{"name": "middle", "version": "1.0.0", "dependencies": ["base_thing"], "parts": ["Runtime"]}`},
        {"engine/plugins/middle/runtime/middle.odin","package middle\n\nimport base_thing \"plugins:base_thing/runtime\"\n\ntwice :: proc() -> i32 {return 2*base_thing.answer()}\n"},
        {"game/project.mirai",`{"name": "Relink", "plugins": ["middle"]}`},
    }
    for file in files {
        path:=project.path(folder,file[0])
        testing.expect(t,os.make_directory_all(path[:strings.last_index_byte(path,'/')])==nil)
        testing.expect(t,os.write_entire_file(path,file[1])==nil,path)
    }
    engine,game:=project.path(folder,"engine"),project.path(folder,"game")
    p,error:=project.open(game,engine)
    if !testing.expectf(t,error.code==.None,"the project opens: %v",error) {return}
    testing.expect(t,os.make_directory_all(engine_paths(engine,.Dev).decl)==nil)

    Built :: struct {compiled,relinked:int,middle:string,base:string}
    build :: proc(t:^testing.T,p:^project.Project,compiler,prefix:string) -> (built:Built,ok:bool) {
        job:=plugin_job(p,compiler)
        defer virtual.arena_destroy(&job.arena)
        job.prefix=prefix
        if !testing.expect_value(t,job_plugins_plan(job,p,{project=p,target=.Editor,dev=true,engine=.Dev}),Failure.None) {return}
        job.plugin_cache=false
        job_plugins_start(job)
        for len(job.compiles)>0 {
            compile:=job.compiles[0]
            ordered_remove(&job.compiles,0)
            state,_:=subprocess.wait(&compile.process)
            if !compile.relink {built.compiled+=1}
            job_plugin_finish(job,compile,state.exit_code)
            if !testing.expectf(t,job.result.status==.Running,"%s builds: %v %s",job.plugins[compile.library].path,job.result.diagnostics,job.result.text) {return}
            job_plugins_start(job)
        }
        built.relinked=job.result.plugins_relinked
        for &lib in job.plugins {
            if lib.path=="middle/runtime" {built.middle=strings.clone(lib.library)}
            if lib.path=="base_thing/runtime" {built.base=strings.clone(lib.file)}
        }
        return built,true
    }
    first,first_ok:=build(t,&p,compiler,"play-a")
    if !first_ok {return}
    testing.expect_value(t,first.compiled,2)

    testing.expect(t,os.write_entire_file(project.path(folder,base_source),"package base_thing\n\nanswer :: proc() -> i32 {return 22}\n")==nil)
    inside,inside_ok:=build(t,&p,compiler,"play-b")
    if !inside_ok {return}
    testing.expect_value(t,inside.compiled,1)
    testing.expect_value(t,inside.relinked,1)
    testing.expect(t,inside.base!=first.base && inside.middle!=first.middle,"both are renamed, so a program that loaded them loads both again")
    data,read_error:=os.read_entire_file(inside.middle,context.temp_allocator)
    if testing.expect(t,read_error==nil,inside.middle) {
        testing.expect(t,strings.contains(string(data),inside.base),"the library linked again imports the new name of the one it links against")
        testing.expect(t,!strings.contains(string(data),first.base),"and not the old one")
    }

    testing.expect(t,os.write_entire_file(project.path(folder,base_source),"package base_thing\n\nanswer :: proc() -> i64 {return 22}\n")==nil)
    testing.expect(t,os.write_entire_file(project.path(folder,"engine/plugins/middle/runtime/middle.odin"),"package middle\n\nimport base_thing \"plugins:base_thing/runtime\"\n\ntwice :: proc() -> i64 {return 2*base_thing.answer()}\n")==nil)
    declared,declared_ok:=build(t,&p,compiler,"play-c")
    if !declared_ok {return}
    testing.expect_value(t,declared.compiled,2)
    testing.expect_value(t,declared.relinked,0)
}

// The hash of the name of a plugin library is masked in the foreign imports
// of a declaration and nowhere else, and the names of the command of a
// linker become those of now whatever their case.
@(test)
the_names_of_plugin_libraries_are_masked_in_declarations_and_renamed_in_commands :: proc(t:^testing.T) {
    Mask_Case :: struct {text,masked:string}
    masks:=[]Mask_Case{
        {"foreign import __mirai \"../../lib/plugin-a-runtime-minimal-8ed57662.lib\"\n","foreign import __mirai \"../../lib/plugin-a-runtime-minimal-00000000.lib\"\n"},
        {"\tforeign import __mirai \"lib/libplugin-a-runtime-minimal-0a1b2c3d.so\"","\tforeign import __mirai \"lib/libplugin-a-runtime-minimal-00000000.so\""},
        {"name :: \"plugin-a-runtime-minimal-8ed57662.lib\"\n","name :: \"plugin-a-runtime-minimal-8ed57662.lib\"\n"},
        {"foreign import lib \"third-party-ABCDEF12.lib\"\n","foreign import lib \"third-party-ABCDEF12.lib\"\n"},
        {"foreign import lib \"short-8ed5766.lib\"\n","foreign import lib \"short-8ed5766.lib\"\n"},
    }
    for c in masks {
        data:=transmute([]u8)strings.clone(c.text,context.temp_allocator)
        link_names_mask(data)
        testing.expect_value(t,string(data),c.masked)
    }
    names:=make(map[string]string,context.temp_allocator)
    names["plugin-base-runtime-minimal"]="plugin-base-runtime-minimal-11111111"
    names["plugin-mid-runtime-minimal"]="plugin-mid-runtime-minimal-22222222"
    command:=`radlink "c:/p/lib/plugin-base-runtime-minimal-8ed57662.lib" /DEF:plugin-mid-runtime-minimal-0a1b2c3d.def "C:/P/LIB/PLUGIN-BASE-RUNTIME-MINIMAL-abcdef01.LIB" "plugin-other-runtime-minimal-8ed57662.lib" -OUT:"o/l.dll"`
    testing.expect_value(t,link_command_rename(command,names,context.temp_allocator),`radlink "c:/p/lib/plugin-base-runtime-minimal-11111111.lib" /DEF:plugin-mid-runtime-minimal-22222222.def "C:/P/LIB/plugin-base-runtime-minimal-11111111.LIB" "plugin-other-runtime-minimal-8ed57662.lib" -OUT:"o/l.dll"`)
    OUTPUT :: "[SYSTEM CALL] msvc-rad-link\n\"radlink\" \"a.obj\"\n\n[SYSTEM CALL] dsymutil\ndsymutil l\n"
    found,ok:=link_command_find(OUTPUT)
    testing.expect(t,ok)
    testing.expect_value(t,found,`"radlink" "a.obj"`)
    testing.expect_value(t,link_calls_strip("Error: x\n"+OUTPUT,context.temp_allocator),"Error: x")
}
