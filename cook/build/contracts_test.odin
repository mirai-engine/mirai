package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"

@(private="file")
contracts_project :: proc(t:^testing.T,folder,core_source,game_source:string) -> (p:project.Project,ok:bool) {
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator)}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    if !testing.expect(t,os.write_entire_file(project.path(engine,"core","data.odin",allocator=context.temp_allocator),core_source)==nil) {return}
    if !testing.expect(t,os.write_entire_file(project.path(game,"game","game.odin",allocator=context.temp_allocator),game_source)==nil) {return}
    return project.Project{root=game,engine_root=engine},true
}

// A storage is the state of one library: another pushes to it when it is a
// queue, or writes it in the order of the loop when it says it is shared.
// core.Commands makes entities with rows of any component and settles every
// table after the function; core.Ref(core.Entities) reads which are alive.
@(test)
storages_have_one_writing_library_and_commands_make_entities :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-contracts-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    core_source:=`package core
@(storage) State :: struct {value:i32}
@(storage,queue) Requests :: struct {count:i32}
@(storage,shared) Board :: struct {value:i32}
@(storage,events) Reports :: struct {count:i32}
@(component) Thing :: struct {value:f32}
@(step="fixed") state_step :: proc(state:^State,requests:^Requests,board:^Board,reports:^Reports) {}
@(step="fixed") things_make :: proc(commands:Commands,entities:Ref(Entities),things:Read(Thing)) {}
`
    game_source:=`package game
import "mirai:core"
@(step="fixed") game_push :: proc(requests:^core.Requests,board:^core.Board,reports:core.Ref(core.Reports)) {}
`
    p,ok:=contracts_project(t,folder,core_source,game_source)
    if !ok {return}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expect(t,strings.contains(text,"p_core.things_make(p_core.commands(w,app.info),p_core.ref(&w.entities),p_core.read(&w.thing))"),text)
        at:=strings.index(text,"p_core.things_make(")
        testing.expect(t,at>=0 && strings.contains(text[at:][:400],"settle(w,s,e)"))
    }
    // The state of a library written by another one is an error that says what to do.
    wrong:=`package game
import "mirai:core"
@(step="fixed") game_push :: proc(state:^core.State,reports:^core.Reports) {}
`
    testing.expect(t,os.write_entire_file(project.path(p.root,"game","game.odin",allocator=context.temp_allocator),wrong)==nil)
    output=world_generate(&p,context.temp_allocator)
    state,reports:=false,false
    for message in output.errors {
        state||=strings.contains(message,"write State") && strings.contains(message,"@(storage,queue)")
        reports||=strings.contains(message,"write Reports")
    }
    testing.expectf(t,state && reports,"%v",output.errors)
    // queue and events are of storages, and a storage is not both.
    both:=`package core
@(storage,queue,events) Mixed :: struct {}
@(component,queue) Row :: struct {}
`
    testing.expect(t,os.write_entire_file(project.path(p.engine_root,"core","data.odin",allocator=context.temp_allocator),both)==nil)
    output=world_generate(&p,context.temp_allocator)
    mixed,row:=false,false
    for message in output.errors {
        mixed||=strings.contains(message,"Mixed says queue or events")
        row||=strings.contains(message,"Row says queue or events")
    }
    testing.expectf(t,mixed && row,"%v",output.errors)
}

// Clearing a World resets the storages derived from its entities: with the
// reset of their package, or freed and back to their default. Settings, what
// is not copied and what says keep or persist stay.
@(test)
clearing_a_world_resets_its_derived_storages :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-contracts-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    core_source:=`package core
@(storage) Cache :: struct {values:[dynamic]i32}
@(storage,free="tally_free") Tally :: struct {count:i32}
tally_free :: proc(t:^Tally) {}
TALLY_DEFAULT :: Tally{count=1}
@(component) Paced :: struct {speed:f32}
PACED_DEFAULT :: Paced{speed=3}
@(storage,reset="simulation_reset") Simulation :: struct {epoch:u32}
simulation_reset :: proc(s:^Simulation) {}
@(storage,queue) Requests :: struct {count:i32}
@(storage,keep) Clock :: struct {tick:u64}
@(storage,persist) Progress :: struct {level:i32}
@(storage,setting) Settings :: struct {value:i32}
@(storage,copy=false) World_Id :: struct {index,generation:u32}
`
    p,ok:=contracts_project(t,folder,core_source,"package game\n")
    if !ok {return}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    text:=output.game_world
    at:=strings.index(text,"clear_world :: proc")
    if !testing.expect(t,at>=0) {return}
    clear:=text[at:]
    clear=clear[:strings.index(clear,"\n}\n")]
    testing.expect(t,strings.contains(clear,"p_core.value_free(&w.cache,type_info_of(p_core.Cache))\n    w.cache={}"),clear)
    testing.expect(t,strings.contains(clear,"p_core.tally_free(&w.tally)\n    w.tally=p_core.TALLY_DEFAULT"),clear)
    testing.expect(t,strings.contains(text,"w.paced.default=default_paced"),"a table starts its rows at the default of its component")
    testing.expect(t,strings.contains(clear,"p_core.simulation_reset(&w.simulation)"),clear)
    testing.expect(t,strings.contains(clear,"w.requests={}"),clear)
    testing.expect(t,strings.contains(text,"type_info_of(p_core.Progress),offset_of(World,progress),.World,.None,nil,false,nil,true,true,\"\",false}"),text)
    for kept in ([]string{"w.clock","w.progress","w.settings","w.world_id"}) {testing.expectf(t,!strings.contains(clear,kept),"%s in %s",kept,clear)}
    // keep and reset are of storages of the World that do not survive already.
    wrong:=`package core
@(storage,host,keep) Shared_State :: struct {}
@(component,keep) Row :: struct {}
@(storage,setting,keep) Kept_Setting :: struct {}
@(storage,keep,reset="r") Both :: struct {}
r :: proc(b:^Both) {}
@(storage,persist,queue) Asked :: struct {}
@(component,persist) Saved_Row :: struct {}
`
    testing.expect(t,os.write_entire_file(project.path(p.engine_root,"core","data.odin",allocator=context.temp_allocator),wrong)==nil)
    output=world_generate(&p,context.temp_allocator)
    found:[6]bool
    for message in output.errors {
        for name,i in ([6]string{"Shared_State says keep","Row says keep","Kept_Setting says keep","Both says keep","Asked says persist","Saved_Row says persist"}) {found[i]||=strings.contains(message,name)}
    }
    testing.expectf(t,found==[6]bool{true,true,true,true,true,true},"%v",output.errors)
}

// The profile of the player keeps plain data: a persist storage that holds a
// dynamic array, a string or an Entity, also in a struct of its own or of
// another package of the world, is an error that names the field and says
// what to hold instead.
@(test)
the_progress_of_the_player_holds_plain_data :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-contracts-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    core_source:=`package core
import "mirai:std/base"
Entity :: base.Entity
Unlock :: struct {name:string}
@(storage,persist) Plain :: struct {level:i32,best:[4]f32,name:[32]u8,id:base.Entity_Id}
`
    game_source:=`package game
import "mirai:core"
Slot :: struct {at:core.Entity}
@(storage,persist) Progress :: struct {levels:[dynamic]i32}
@(storage,persist) Records :: struct {slots:[4]Slot}
@(storage,persist) Unlocks :: struct {first:core.Unlock}
`
    p,ok:=contracts_project(t,folder,core_source,game_source)
    if !ok {return}
    output:=world_generate(&p,context.temp_allocator)
    found:[3]bool
    for message in output.errors {
        testing.expectf(t,!strings.contains(message,"Plain"),"%s",message)
        found[0]||=strings.contains(message,"Progress.levels is a dynamic array") && strings.contains(message,"[N]T")
        found[1]||=strings.contains(message,"Records.slots.at is an Entity") && strings.contains(message,"Entity_Id")
        found[2]||=strings.contains(message,"Unlocks.first.name is a string") && strings.contains(message,"base.text_set")
    }
    testing.expectf(t,found==[3]bool{true,true,true},"%v",output.errors)
}

// Each function is written once with its binding and its settle; the loops
// call it in their order, which info.order gives core.world_run. A parameter
// with a default is an error: the generator binds every parameter.
@(test)
functions_are_called_from_the_loops_and_from_their_order :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-contracts-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    core_source:=`package core
@(storage) Clock :: struct {tick:u64}
@(component) Thing :: struct {value:f32}
@(step="fixed late",loops="game editor",stage="end") things_move :: proc(things:^Table(Thing),clock:Clock) {}
@(step="fixed",loops="game editor") clock_read :: proc(clock:Ref(Clock)) {}
`
    p,ok:=contracts_project(t,folder,core_source,"package game\n")
    if !ok {return}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expect_value(t,strings.count(text,"call_things_move :: proc(world,shared,editor:rawptr,app_data:rawptr,worker:int) {"),1)
        testing.expect_value(t,strings.count(text,"p_core.things_move(&w.thing,w.clock)"),2) // with and without CHECK_WRITES
        testing.expect(t,strings.contains(text,"game_fixed :: proc(world,shared,editor:rawptr,app_data:rawptr) {\n    call_clock_read(world,shared,editor,app_data,p_host.PROFILE_MAIN)\n    call_things_move(world,shared,editor,app_data,p_host.PROFILE_MAIN)\n}"),text)
        testing.expect(t,strings.contains(text,"@(rodata) order_game_fixed:=[2]i32{1,0}"),text)
        testing.expect(t,strings.contains(text,"info.loops[.Game][.Late],info.order[.Game][.Late]=game_late,order_game_late[:]"),text)
        testing.expect(t,strings.contains(text,"steps[0]={\"things_move\",\"core\",{.Fixed,.Late,},{.Game,.Editor,},call_things_move,false}"),text)
    }
    defaulted:=`package core
@(storage) Clock :: struct {tick:u64}
@(step="fixed") clock_read :: proc(clock:^Clock=nil,other:^Clock=nil) {}
`
    testing.expect(t,os.write_entire_file(project.path(p.engine_root,"core","data.odin",allocator=context.temp_allocator),defaulted)==nil)
    output=world_generate(&p,context.temp_allocator)
    found:=false
    for message in output.errors {found||=strings.contains(message,"clock_read gives a default to clock, other")}
    testing.expectf(t,found,"%v",output.errors)
}
