package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(private="file")
params_project :: proc(t:^testing.T,folder,core_source,game_source:string) -> (p:project.Project,ok:bool) {
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator)}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    if !testing.expect(t,os.write_entire_file(project.path(engine,"core","data.odin",allocator=context.temp_allocator),core_source)==nil) {return}
    if !testing.expect(t,os.write_entire_file(project.path(game,"game","game.odin",allocator=context.temp_allocator),game_source)==nil) {return}
    return project.Project{root=game,engine_root=engine},true
}

@(private="file")
params_errors :: proc(t:^testing.T,p:^project.Project,game_source:string) -> []string {
    testing.expect(t,os.write_entire_file(project.path(p.root,"game","game.odin",allocator=context.temp_allocator),game_source)==nil)
    return world_generate(p,context.temp_allocator).errors
}

@(private="file")
PARAMS_CORE :: `package core
@(storage) Clock :: struct {tick:u64}
@(storage,queue) Asks :: struct {count:i32}
@(storage) Tally :: struct {count:i32}
@(component) Spot :: struct {value:f32}
@(component) Mark :: struct {value:f32}
@(params) Looker :: struct {spots:Read(Spot),asks:Ref(Asks),clock:Clock}
@(params) Mover :: struct {spots:^Table(Spot),asks:^Asks,tally:^Tally}
`

// A @(params) struct reaches a step as its fields would one by one: the call
// builds it with each field bound as that parameter alone, and what it
// writes is written by the step, with its settle, its check of writes and
// its one writer.
@(test)
a_params_struct_binds_each_field_as_its_parameter :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"params")
    if folder=="" {return}
    game_source:=`package game
import "mirai:core"
@(step="fixed") game_look :: proc(marks:^core.Table(core.Mark),look:core.Looker,spots:core.Read(core.Spot)) {}
@(step="fixed") game_move :: proc(move:core.Mover,asks:^core.Asks,clock:core.Clock) {}
`
    p,ok:=params_project(t,folder,PARAMS_CORE,game_source)
    if !ok {return}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expect_value(t,strings.count(text,"p_game.game_look(&w.mark,p_core.Looker{spots=p_core.read(&w.spot),asks=p_core.ref(&w.asks),clock=w.clock},p_core.read(&w.spot))"),2)
        testing.expect_value(t,strings.count(text,"p_game.game_move(p_core.Mover{spots=&w.spot,asks=&w.asks,tally=&w.tally},&w.asks,w.clock)"),2)
        at:=strings.index(text,"call_game_move :: proc")
        if !testing.expect(t,at>=0) {continue}
        call:=text[at:]
        call=call[:strings.index(call,"\n}\n")]
        testing.expect(t,strings.contains(call,"p_core.write_check_begin(p_core.raw(&w.spot),size_of(p_core.Spot))"),call)
        testing.expect(t,strings.contains(call,"p_core.table_settle(&w.spot,&w.entities)"),call)
    }
    // The table a @(params) writes has one writer, as if the step received it alone.
    errors:=params_errors(t,&p,`package game
import "mirai:core"
@(step="fixed") game_move :: proc(move:core.Mover) {}
@(step="fixed") game_push :: proc(spots:^core.Table(core.Spot)) {}
`)
    found:=false
    for message in errors {found||=strings.contains(message,"game_move and game_push write Spot")}
    testing.expectf(t,found,"%v",errors)
}

// What a step writes reaches it once: by itself and in a @(params), or in two
// of them, is an error that says which to take out. What it only reads, or a
// queue it pushes to, may come twice.
@(test)
a_written_datum_reaches_a_step_once :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"params")
    if folder=="" {return}
    p,ok:=params_project(t,folder,PARAMS_CORE,"package game\n")
    if !ok {return}
    errors:=params_errors(t,&p,`package game
import "mirai:core"
@(step="fixed") game_loose :: proc(move:core.Mover,spots:core.Read(core.Spot)) {}
@(step="fixed") game_twice :: proc(a:core.Mover,b:core.Mover) {}
@(step="fixed") game_pushes :: proc(look:core.Looker,asks:^core.Asks,spots:core.Read(core.Spot)) {}
@(params) Itself :: struct {marks:^core.Table(core.Mark),seen:core.Read(core.Mark)}
@(step="fixed") game_itself :: proc(it:Itself) {}
`)
    loose,twice,pushes,itself:=false,false,false,false
    for message in errors {
        loose||=strings.contains(message,"game_loose receives Spot as the field spots of the @(params) Mover and as its parameter spots, and writes it") && strings.contains(message,"take its parameter spots out and use Mover.spots")
        twice||=strings.contains(message,"game_twice receives") && strings.contains(message,"receive Mover once")
        pushes||=strings.contains(message,"game_pushes")
        itself||=strings.contains(message,"game_itself receives Mark") && strings.contains(message,"take marks or seen out of Itself")
    }
    testing.expectf(t,loose && twice && !pushes && itself,"%v",errors)
}

// A @(params) holds parameters of steps and is received by value: one
// inside another, one received by pointer, a field that is no parameter and
// one with no fields are errors that say what to write.
@(test)
a_params_struct_has_only_parameters_and_does_not_nest :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"params")
    if folder=="" {return}
    p,ok:=params_project(t,folder,PARAMS_CORE,"package game\n")
    if !ok {return}
    errors:=params_errors(t,&p,`package game
import "mirai:core"
@(params) Outer :: struct {look:core.Looker,marks:core.Read(core.Mark)}
@(params) Odd :: struct {count:int}
@(params) Empty :: struct {}
@(params,component) Both :: struct {value:f32}
@(step="fixed") game_pointer :: proc(move:^core.Mover) {}
@(step="fixed") game_untyped :: proc(marks:core.Read(core.Mark),count:=3) {}
`)
    found:[6]bool
    for message in errors {
        found[0]||=strings.contains(message,"Outer has a field of Looker, another @(params): they do not nest")
        found[1]||=strings.contains(message,"the field count of Odd is int")
        found[2]||=strings.contains(message,"Empty is @(params) and has no fields")
        found[3]||=strings.contains(message,"Both is @(params) and a component")
        found[4]||=strings.contains(message,"game_pointer receives ^core.Mover, a @(params) struct, by pointer: receive it by value, core.Mover")
        found[5]||=strings.contains(message,"game_untyped gives a default to count")
    }
    testing.expectf(t,found==[6]bool{true,true,true,true,true,true},"%v",errors)
}

// What the application owns reaches a step by the type that names it, alone
// or in a @(params): the call hands out what host.App holds. Asked for in
// another form, the error says which form to receive.
@(test)
a_part_of_the_application_reaches_a_step_by_its_type :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"params")
    if folder=="" {return}
    game_source:=`package game
import "base:runtime"
import "mirai:core"
import "mirai:host"
import mixer "mirai:audio"
import erender "mirai:engine/render"
import "mirai:std/jobs"
@(params) Loader :: struct {assets:^host.Assets,allocator:runtime.Allocator,spots:core.Read(core.Spot)}
@(step="frame") game_load :: proc(loader:Loader,job_system:^jobs.Job_System) {}
@(step="render") game_draw :: proc(renderer:^erender.Renderer,extras:^host.Frame_Extras,m:^mixer.Mixer,app:^host.App) {}
`
    p,ok:=params_project(t,folder,PARAMS_CORE,game_source)
    if !ok {return}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expect(t,strings.contains(text,"p_game.game_load(p_game.Loader{assets=app.assets,allocator=app.allocator,spots=p_core.read(&w.spot)},&app.jobs)"))
        testing.expect(t,strings.contains(text,"p_game.game_draw(app.renderer,&app.extras,app.mixer,app)"))
    }
    errors:=params_errors(t,&p,`package game
import "base:runtime"
import "mirai:host"
@(step="frame") game_load :: proc(assets:host.Assets,allocator:^runtime.Allocator,content:^host.Content) {}
`)
    found:[3]bool
    for message in errors {
        found[0]||=strings.contains(message,"the parameter assets of game_load is host.Assets, and the application hands that part out as ^host.Assets: receive ^host.Assets")
        found[1]||=strings.contains(message,"the parameter allocator of game_load is ^runtime.Allocator, and the application hands that part out as runtime.Allocator")
        found[2]||=strings.contains(message,"the parameter content of game_load is ^host.Content") && strings.contains(message,"a part of the application (^host.Assets")
    }
    testing.expectf(t,found==[3]bool{true,true,true},"%v",errors)
}
