package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(private="file")
MINDS_CORE :: `package core
@(storage,keep) Network :: struct {role:u8}
@(storage) Time :: struct {tick:u64}
@(storage,host,shared) Minds :: struct {count:int}
@(component,shared) Mind_Agent :: struct {state:u8}
@(component) Spot :: struct {value:f32}
@(storage,queue) Asks :: struct {count:i32}
@(params) Mind_World :: struct {minds:^Minds,agents:^Table(Mind_Agent),time:Time}
`

// The generated world of a project whose engine has core_source and whose game has game_source.
@(private="file")
minds_generate :: proc(t:^testing.T,core_source,game_source:string) -> (out:Generated,ok:bool) {
    folder:=base.test_folder(t,"minds")
    if folder=="" {return}
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    sources:=[2][2]string{{project.path(engine,"core",allocator=context.temp_allocator),core_source},{project.path(game,"game",allocator=context.temp_allocator),game_source}}
    for source,i in sources {
        if !testing.expect(t,os.make_directory_all(source[0])==nil) {return}
        name:=i==0?"data.odin":"game.odin"
        if !testing.expect(t,os.write_entire_file(project.path(source[0],name,allocator=context.temp_allocator),source[1])==nil) {return}
    }
    p:=project.Project{root=game,engine_root=engine}
    return world_generate(&p,context.temp_allocator),true
}

// A mind is its @(mind) think procedure and the @(act) procedures of its
// enum: the generator makes it a fixed, server step that binds what they
// receive after their first parameter, once each in the context of the mind
// after Mind_World, and ticks its agents with minds_tick.
@(test)
a_mind_becomes_a_step_that_binds_what_its_procedures_receive :: proc(t:^testing.T) {
    output,ok:=minds_generate(t,MINDS_CORE,`package game
import "mirai:core"
import "mirai:std/ai"
@(component) Hunger :: struct {value:f32}
@(params) Senses :: struct {spots:^core.Table(core.Spot,.Read),time:core.Time}
Zombie_Act :: enum u8 {Wander,Chase,Circle}
@(mind="zombie") zombie_think :: proc(t:^ai.Think(Zombie_Act),senses:Senses) {}
@(act="Wander") zombie_wander :: proc(a:^ai.Act(Zombie_Act)) -> ai.Status {return .Success}
@(act="Chase Circle") zombie_chase :: proc(a:^ai.Act(Zombie_Act),senses:Senses,hungers:^core.Table(Hunger),asks:^core.Asks) -> ai.Status {return .Success}
`)
    if !ok || !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        expected:=[?]string{
            `import gen_ai "mirai:std/ai"`,
            "Mind_zombie_think :: struct {world:p_core.Mind_World,a1:p_game.Senses,a2:^p_core.Table(p_game.Hunger),a3:^p_core.Asks}",
            "ctx:=Mind_zombie_think{world=p_core.Mind_World{minds=&s.minds,agents=&w.mind_agent,time=w.time},a1=p_game.Senses{spots=p_core.read(&w.spot),time=w.time},a2=&w.hunger,a3=&w.asks}",
            "think:=proc(t:^gen_ai.Think(p_game.Zombie_Act)) {c:=cast(^Mind_zombie_think)t.user;p_game.zombie_think(t,c.a1)}",
            ".Wander=proc(a:^gen_ai.Act(p_game.Zombie_Act)) -> gen_ai.Status {return p_game.zombie_wander(a)}",
            ".Circle=proc(a:^gen_ai.Act(p_game.Zombie_Act)) -> gen_ai.Status {c:=cast(^Mind_zombie_think)a.user;return p_game.zombie_chase(a,c.a1,c.a2,c.a3)}",
            `p_core.minds_tick(&ctx.world,"zombie",&acts,think)`,
            `#assert(len("zombie")<p_core.MIND_NAME`,
            "#assert(1<=p_core.MINDS_CAPACITY",
        }
        for e in expected {testing.expectf(t,strings.contains(text,e),"missing %s",e)}
        at:=strings.index(text,"call_zombie_think :: proc")
        if !testing.expect(t,at>=0) {continue}
        call:=text[at:]
        call=call[:strings.index(call,"\n}\n")]
        testing.expect(t,strings.contains(call,"if w.network.role==.Client {return}"),call)
        testing.expect(t,strings.contains(call,"p_core.table_settle(&w.hunger,&w.entities)"),call)
        testing.expect(t,strings.contains(text,`steps[0]={"zombie_think","game",{.Fixed,},{.Game,},call_zombie_think}`),"its step is named after its think")
    }
}

// What is wrong in a mind is a generator error that says what to write.
@(test)
a_wrong_mind_is_an_error_that_says_how_to_fix_it :: proc(t:^testing.T) {
    output,ok:=minds_generate(t,MINDS_CORE,`package game
import "mirai:host"
import "mirai:std/ai"
A_Act :: enum u8 {One,Two}
@(mind) a_think :: proc(t:^ai.Think(A_Act)) {}
@(act="One Two") a_run :: proc(a:^ai.Act(A_Act)) -> ai.Status {return .Success}
B_Act :: enum u8 {One,Two}
@(mind="b") b_think :: proc(t:^ai.Think(B_Act)) {}
@(act="One") b_one :: proc(a:^ai.Act(B_Act)) -> ai.Status {return .Success}
@(act="One Three") b_again :: proc(a:^ai.Act(B_Act)) -> ai.Status {return .Success}
C_Act :: enum u8 {One}
@(act="One") c_one :: proc(a:^ai.Act(C_Act)) -> ai.Status {return .Success}
@(mind="d") d_think :: proc(x:int) {}
@(mind="e") e_think :: proc(t:^ai.Think(B_Act),count:int,assets:^host.Assets) {}
@(act="Two") e_two :: proc(a:^ai.Act(B_Act)) {}
@(mind="b") f_think :: proc(t:^ai.Think(B_Act)) {}
Not_Enum :: struct {}
@(mind="g") g_think :: proc(t:^ai.Think(Not_Enum)) {}
@(private,mind="h") h_think :: proc(t:^ai.Think(A_Act)) {}
@(step="fixed",mind="i") i_think :: proc(t:^ai.Think(A_Act)) {}
`)
    if !ok {return}
    expected:=[?]string{
        "a_think has @(mind) without a name",
        "B_Act.Two has no action",
        "b_again runs B_Act.One, which another action already runs",
        `b_again runs "Three", which is no value of B_Act`,
        "c_one is an action of C_Act, and no think procedure of this package proposes them",
        "d_think is a @(mind) and is not a proc(t:^ai.Think(Actions), ...)",
        "e_two is a @(act) and is not a proc(a:^ai.Act(Actions), ...) -> ai.Status",
        "the parameter count of e_think is int",
        "e_think receives assets, a part of the application: a mind decides from the world",
        `the mind "b" of f_think is also the one of b_think`,
        "g_think runs for Not_Enum, which is not an enum of this package",
        "h_think is @(private), and the generated world calls it",
        "i_think is a @(step) and a @(mind)",
    }
    for e in expected {
        found:=false
        for message in output.errors {found||=strings.contains(message,e)}
        testing.expectf(t,found,"no error says %q: %v",e,output.errors)
    }
    // Without the behavior plugin there is no Mind_World for a mind to read.
    alone,alone_ok:=minds_generate(t,"package core\n@(storage,keep) Network :: struct {role:u8}\n",`package game
import "mirai:std/ai"
A_Act :: enum u8 {One}
@(mind="a") a_think :: proc(t:^ai.Think(A_Act)) {}
@(act="One") a_one :: proc(a:^ai.Act(A_Act)) -> ai.Status {return .Success}
`)
    if !alone_ok {return}
    found:=false
    for message in alone.errors {found||=strings.contains(message,"a_think is the think procedure of a mind, and the world has no behavior plugin")}
    testing.expectf(t,found,"%v",alone.errors)
}
