package build

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"

// The content tool of a project builds as its tests do, with no flag of its
// own: it imports the game of the project, a plugin the project enables and
// the world generated from them, reads the attributes and the defines of the
// project, runs where the libraries are found and compiles nothing again
// while what its build read stands.
@(test)
a_program_of_a_project_imports_its_game_its_plugins_and_its_world :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=project.path_absolute(".")
    if !engine_current(root,.Dev) {
        log.warn("the dev binaries of the engine are not current (mirai build engine): the program was not built")
        return
    }
    folder:=base.test_folder(t,"program")
    if folder=="" {return}
    files:=[?][2]string{
        {"project.mirai",`{"name":"Fixture","plugins":["spawn"],"build":{"defines":["FIXTURE_SIDES=6"]}}`},
        {"game/game.odin","package game\n\nimport \"mirai:core\"\n\nSIDES :: #config(FIXTURE_SIDES,0)\n\n@(component)\nDie :: struct {sides:i32}\n\n@(step=\"fixed\")\ndice_roll :: proc(dice:^core.Table(Die)) {}\n"},
        {"tools/content/main.odin",`package main

import "core:fmt"
import "core:os"
import "mirai:core"
import spawn "plugins:spawn/runtime"
import game "project:game"
import world "generated:editor_world"

main :: proc() {
    info:=world.info()
    tables:=0
    for &t in info.tables {
        if t.name=="Die" || t.name=="Spawn_Point" {tables+=1}
    }
    point:spawn.Spawn_Point
    fmt.printf("sides %d tables %d point %d",game.SIDES,tables,size_of(point))
    os.exit(0 if tables==2 else 1)
}
`},
    }
    for file in files {
        path:=project.path(folder,file[0])
        if !testing.expect(t,base.make_directory_all(path[:strings.last_index_byte(path,'/')])==nil) {return}
        if !testing.expect(t,os.write_entire_file(path,file[1])==nil) {return}
    }
    p,error:=project.open(folder,root)
    if !testing.expect_value(t,error.code,project.Error_Code.None) {return}
    defer project.close(&p)
    tool:=project.path(folder,"tools/content")
    build_tool :: proc(t:^testing.T,p:^project.Project,tool:string) -> (executable:string,environment:[]string,status:Status) {
        job:=job_run({project=p,target=.Editor,action=.Program,package_folder=tool,dev=true,engine=.Dev})
        defer job_destroy(job)
        for d in job.result.diagnostics {log.errorf("%s(%d:%d): %s",d.file,d.line,d.column,d.message)}
        if !testing.expectf(t,job.result.status!=.Failed,"%v: %s",job.result.failure,job.result.text) {return}
        return strings.clone(job.result.output),program_environment(job),job.result.status
    }
    executable,environment,status:=build_tool(t,&p,tool)
    if !testing.expect_value(t,status,Status.Built) {return}
    process,started:=subprocess.start({working_dir=folder,command={executable},env=environment},{},.Merged)
    if !testing.expect_value(t,started,nil) {return}
    output:=make([dynamic]u8)
    buffer:[256]u8
    exited:=false
    for {
        count,_:=subprocess.read(&process,.Stdout,buffer[:])
        if count>0 {append(&output,..buffer[:count]);continue}
        if exited {break}
        state,_:=subprocess.wait(&process,10*time.Millisecond)
        if state.exited {
            testing.expect_value(t,state.exit_code,0)
            exited=true
        }
    }
    subprocess.release(&process)
    testing.expect(t,strings.has_prefix(string(output[:]),"sides 6 tables 2"),string(output[:]))
    _,_,status=build_tool(t,&p,tool)
    testing.expect_value(t,status,Status.Up_To_Date)
}
