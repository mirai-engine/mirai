package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

// A message and a component for some ends reach the World_Info of both
// worlds, and a step that receives the inbox of a message reads its messages
// by its index; what the network cannot send is an error that says what to
// write.
@(test)
messages_and_replicated_components_reach_the_world_info :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"replication")
    if folder=="" {return}
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator)}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    testing.expect(t,os.write_entire_file(project.path(engine,"core","data.odin",allocator=context.temp_allocator),"package core\n@(storage)\nNet_Messages :: struct {count:int}\nInbox :: struct($T:typeid) {items:[]T}\n")==nil)
    file:=project.path(game,"game","game.odin",allocator=context.temp_allocator)
    source:=`package game
import "mirai:core"
@(net_message,from="client",reliable)
Ping :: struct {value:u32}
@(net_message)
Tick :: struct {value:u32}
@(component,replicated="owner")
Secret :: struct {value:f32}
@(component,replicated="object")
Taken :: struct {count:u32}
@(step="fixed")
heard :: proc(ticks:core.Inbox(Tick)) {}
`
    testing.expect(t,os.write_entire_file(file,source)==nil)
    p:=project.Project{root=game,engine_root=engine}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expect_value(t,len(output.errors),0) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expectf(t,strings.contains(text,`{"Ping","game",`) && strings.contains(text,`.Client,true}`),"%s",text)
        testing.expect(t,strings.contains(text,`{"Tick","game",`) && strings.contains(text,`.Server,false}`))
        testing.expect(t,strings.contains(text,`.World,false,.Owner,true,nil,"",nil,false,false,`))
        testing.expect(t,strings.contains(text,`.World,false,.Object,true,`))
    }
    testing.expectf(t,strings.contains(output.game_world,`p_core.inbox(&w.`) && strings.contains(output.game_world,`,1,p_game.Tick))`),"%s",output.game_world)

    wrong:=`package game
@(storage,replicated)
Score :: struct {value:u32}
@(component,net_message)
Both :: struct {value:u32}
@(net_message,from="anyone")
Shout :: struct {value:u32}
@(component,replicated="all")
Loud :: struct {value:u32}
`
    testing.expect(t,os.write_entire_file(file,wrong)==nil)
    output=world_generate(&p,context.temp_allocator)
    expected:=[]string{
        "Score is a storage and says replicated",
        "Both is a @(net_message) and a component or storage",
        `Shout has from="anyone"`,
        `Loud has replicated="all"`,
    }
    for text in expected {
        found:=false
        for message in output.errors {found ||= strings.contains(message,text)}
        testing.expectf(t,found,"no error says %q: %v",text,output.errors)
    }
}
