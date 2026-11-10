package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(test)
by_world_storages_give_each_function_the_value_of_its_world :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"by-world")
    if folder=="" {return}
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator)}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    core_file:=project.path(engine,"core","session.odin",allocator=context.temp_allocator)
    source:=`package core
@(storage,copy=false) World_Id :: struct {index,generation:u32}
@(storage,host,by_world,free="session_free") Session :: struct {open:bool}
session_free :: proc(s:^Session) {}
@(step="input") session_open :: proc(s:^Session) {}
@(step="frame") session_look :: proc(s:Ref(Session)) {}
`
    testing.expect_value(t,os.write_entire_file(core_file,source),nil)
    p:=project.Project{root=game,engine_root=engine}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expect_value(t,len(output.errors),0) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expect(t,strings.contains(text,"session:p_core.By_World(p_core.Session),"))
        testing.expect(t,strings.contains(text,"p_core.session_open(p_core.by_world_get(&s.session,w.world_id))"))
        testing.expect(t,strings.contains(text,"p_core.session_look(p_core.ref(p_core.by_world_get(&s.session,w.world_id)))"))
        // core.world_attach gives each World its value, and core.world_detach frees it with its free.
        testing.expect(t,strings.contains(text,"free_session :: proc(value:rawptr) {p_core.session_free(cast(^p_core.Session)value)}"),text)
        testing.expect(t,strings.contains(text,`,false,nil,false,false,"",false,true,{}}`+"\n") && strings.contains(text,`p_core.Session),offset_of(Shared,session),.Shared,.None,nil,true,nil,false,false,"",false,false,{free=free_session}}`),text)
    }
    // A value for each World is of the application, and a function takes it by pointer.
    wrong:=`package core
@(storage,copy=false) World_Id :: struct {index,generation:u32}
@(storage,by_world) Local :: struct {}
@(storage,host,by_world) Session :: struct {open:bool}
@(step="frame") session_copy :: proc(s:Session) {}
`
    testing.expect_value(t,os.write_entire_file(core_file,wrong),nil)
    output=world_generate(&p,context.temp_allocator)
    local,by_value:=false,false
    for message in output.errors {
        local||=strings.contains(message,"Local is by_world")
        by_value||=strings.contains(message,"session_copy receives Session")
    }
    testing.expect(t,local && by_value)
    // What comes back from the GPU is presentation: no function of fixed reads it.
    presentation:=`package core
@(storage,copy=false) World_Id :: struct {index,generation:u32}
@(storage,host,by_world,presentation) Hits :: struct {count:int}
@(step="frame") hits_show :: proc(h:Ref(Hits)) {}
@(step="fixed") hits_decide :: proc(h:Ref(Hits)) {}
`
    testing.expect_value(t,os.write_entire_file(core_file,presentation),nil)
    output=world_generate(&p,context.temp_allocator)
    refused:=0
    for message in output.errors {
        if strings.contains(message,"hits_decide runs in fixed and receives Hits") {refused+=1}
        testing.expect(t,!strings.contains(message,"hits_show"),message)
    }
    testing.expect_value(t,refused,1)
}
