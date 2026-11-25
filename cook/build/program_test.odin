package build

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
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

// What a test runs and what it said, stdout and stderr together.
@(private="file")
program_output :: proc(t:^testing.T,folder:string,command:[]string,environment:[]string) -> (said:string,code:int) {
    process,started:=subprocess.start({working_dir=folder,command=command,env=environment},{},.Merged)
    if !testing.expect_value(t,started,nil) {return "",-1}
    defer subprocess.release(&process)
    output:=make([dynamic]u8)
    buffer:[4096]u8
    exited:=false
    for {
        count,_:=subprocess.read(&process,.Stdout,buffer[:])
        if count>0 {append(&output,..buffer[:count]);continue}
        if exited {break}
        state,_:=subprocess.wait(&process,10*time.Millisecond)
        if state.exited {exited,code=true,state.exit_code}
    }
    return string(output[:]),code
}

@(private="file") Fixture_Ammo :: struct {count:i32}
@(private="file") Fixture_Binding :: struct {action:u8,hold:f32}
@(private="file") Fixture_Weapon :: struct {damage:f32,ammo:[2]u64,ammo_row:u64,binding:Fixture_Binding}

// The line of the call of the tool below that writes a scene the game refuses.
@(private="file")
FIXTURE_REFUSED_LINE :: 26

// A content tool writes rows of the record types of its game, with a
// reference to a row of another table, an input action by the name of the
// member of its enum and ids that stand from one run to the next, and a scene
// that mirai scene check passes; a scene the game refuses is said with the
// line of the tool that wrote it; a second run writes nothing.
@(test)
a_content_tool_writes_typed_rows_and_scenes_of_its_game :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=project.path_absolute(".")
    if !engine_current(root,.Dev) {
        log.warn("the dev binaries of the engine are not current (mirai build engine): the tool was not built")
        return
    }
    folder:=base.test_folder(t,"content-tool")
    if folder=="" {return}
    files:=[?][2]string{
        {"project.mirai",`{"name":"Fixture","plugins":[]}`},
        {"game/game.odin",`package game

import "mirai:core"
import "mirai:engine/input"

@(actions)
Fixture_Action :: enum u8 {Fire,Dash}

Binding :: struct {action:input.Action,hold:f32}

@(component)
Crate :: struct {weight:f32}

@(step="fixed")
crates_fall :: proc(crates:^core.Table(Crate),weapons:core.Records(Weapon)) {}
`},
        {"tools/content/main.odin",`package main

import "core:fmt"
import "core:os"
import "mirai:cook/content"
import "mirai:cook/records"
import game "project:game"
import world "generated:editor_world"

main :: proc() {
    w:content.Writer
    if !content.open(&w,world.info()) {os.exit(1)}
    if len(os.args)>1 && os.args[1]=="--read" {
        for path in ([]string{"data/ammo.records","data/weapons.records"}) {
            file,_:=records.tables_scan(&w.registry,&w.types),0
            for f in file {
                if f.path!=path {continue}
                e:records.Edit
                if records.load(&w.registry,&w.types,&w.world,f.id,&e)!="" {os.exit(1)}
                for row in 0..<records.row_count(&e) {fmt.printfln("%s %s %d %s",path,records.row_name(&e,row),e.ids[row],records.row_text(&e,row))}
            }
        }
        os.exit(content.close(&w))
    }
    if len(os.args)>1 && os.args[1]=="--refused" {
        content.scene_write(&w,"arena/refused.scene",` + "`" + `{"entities":[{"name":"X","components":{"Nope":{}}}]}` + "`" + `)
        os.exit(content.close(&w))
    }
    content.records_write(&w,"data/ammo.records",[]content.Row(game.Ammo){{"shell",{count=6}},{"slug",{count=2}}})
    shell:=content.record(&w,game.Ammo,"data/ammo.records","shell")
    dash:=content.action(&w,game.Fixture_Action.Dash)
    content.records_write(&w,"data/weapons.records",[]content.Row(game.Weapon){{"shotgun",{damage=12,ammo=shell,binding={action=dash,hold=0.5}}}})
    content.scene_write(&w,"arena/crates.scene",` + "`" + `{"entities":[{"name":"Crate","components":{"Crate":{"weight":3}}}]}` + "`" + `)
    os.exit(content.close(&w))
}
`},
    }
    for file in files {
        path:=project.path(folder,file[0])
        if !testing.expect(t,base.make_directory_all(path[:strings.last_index_byte(path,'/')])==nil) {return}
        if !testing.expect(t,os.write_entire_file(path,file[1])==nil) {return}
    }
    testing.expect_value(t,strings.count(files[2][1][:strings.index(files[2][1],"arena/refused.scene")],"\n")+1,FIXTURE_REFUSED_LINE)
    // The tables that declare Ammo and Weapon, with no rows.
    data:=project.path(folder,"assets/data")
    if !testing.expect(t,base.make_directory_all(data)==nil) {return}
    column :: proc(name:string,kind:asset.Records_Kind,type:="") -> (c:asset.Records_Column) {
        base.text_set(c.name[:],name)
        c.kind=kind
        base.text_set(c.type[:],type)
        return
    }
    declare :: proc(t:^testing.T,file,type:string,id:base.Asset_Id,columns:[]asset.Records_Column,default:^$T) {
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        schema:serial.Schema
        serial.schema_init(&schema,context.temp_allocator)
        defer serial.schema_destroy(&schema)
        value_type,_:=serial.schema_add_type_info(&schema,type_info_of(T))
        info:asset.Records_Info
        base.text_set(info.type[:],type)
        info.declares=true
        bytes,error:=asset.records_bytes(&types,{id=id,info=info,columns=columns,schema=&schema,value_type=value_type,defaults=mem.ptr_to_bytes(default)},context.temp_allocator)
        testing.expect_value(t,error,asset.Error.None)
        testing.expect(t,os.write_entire_file(file,bytes)==nil)
    }
    ammo:Fixture_Ammo
    declare(t,project.path(data,"ammo.records"),"Ammo",{1,1},{column("count",.Int)},&ammo)
    weapon:Fixture_Weapon
    declare(t,project.path(data,"weapons.records"),"Weapon",{2,2},{column("damage",.Float),column("ammo",.Record,"Ammo"),column("binding",.Type,"Binding")},&weapon)

    p,error:=project.open(folder,root)
    if !testing.expect_value(t,error.code,project.Error_Code.None) {return}
    defer project.close(&p)
    built:=job_run({project=&p,target=.Editor,dev=true,engine=.Dev})
    testing.expectf(t,built.result.status!=.Failed,"the editor library: %v %s %v",built.result.failure,built.result.text,built.result.diagnostics)
    job_destroy(built)
    job:=job_run({project=&p,target=.Editor,action=.Program,package_folder=project.path(folder,"tools/content"),dev=true,engine=.Dev})
    for d in job.result.diagnostics {log.errorf("%s(%d:%d): %s",d.file,d.line,d.column,d.message)}
    if !testing.expectf(t,job.result.status==.Built,"%v: %s",job.result.failure,job.result.text) {job_destroy(job);return}
    tool:=strings.clone(job.result.output)
    environment:=program_environment(job)
    job_destroy(job)

    said,code:=program_output(t,folder,{tool},environment)
    testing.expectf(t,code==0 && strings.contains(said,"content: 3 written, 0 unchanged"),"%s",said)
    first,_:=program_output(t,folder,{tool,"--read"},environment)
    for wanted in ([]string{"data/ammo.records shell ","data/ammo.records slug ","data/weapons.records shotgun ",`"action": "dash"`,`"hold": 0.5`,`"damage": 12`}) {
        testing.expectf(t,strings.contains(first,wanted),"%q not in\n%s",wanted,first)
    }
    // The reference names the row shell of the table of ammo.
    shell:=first[strings.index(first,"data/ammo.records shell ")+len("data/ammo.records shell "):]
    shell=shell[:strings.index_byte(shell,' ')]
    testing.expectf(t,strings.contains(first,fmt.tprintf(`"row": %s}`,shell)),"the shotgun names shell (%s):\n%s",shell,first)

    said,code=program_output(t,folder,{tool},environment)
    testing.expectf(t,code==0 && strings.contains(said,"content: 0 written, 3 unchanged"),"a second run writes nothing:\n%s",said)
    again,_:=program_output(t,folder,{tool,"--read"},environment)
    testing.expect_value(t,again,first)

    checked,checked_code:=program_output(t,folder,{engine_paths(root,.Dev).author_program,"--project",folder,"--engine",root,"scene","check","arena/crates.scene"},child_environment(root,context.temp_allocator))
    testing.expectf(t,checked_code==0,"mirai scene check of what the tool wrote:\n%s",checked)

    refused,refused_code:=program_output(t,folder,{tool,"--refused"},environment)
    testing.expectf(t,refused_code==1 && strings.contains(refused,fmt.tprintf("main.odin(%d:",FIXTURE_REFUSED_LINE)),"a refused scene names the line of the tool:\n%s",refused)
    testing.expect(t,!os.exists(project.path(folder,"assets/arena/refused.scene")))
}
