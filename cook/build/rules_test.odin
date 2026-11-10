package build

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"

// Every rule of the generator that the other tests do not reach refuses its
// declaration with an error that names it and says what to write instead.
@(test)
each_rule_of_the_generator_names_the_declaration_that_breaks_it :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-rules-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    files:=[][2]string{
        {project.path(engine,"core","data.odin",allocator=context.temp_allocator),`package core
@(component,shared) Owned :: struct {value:f32}
@(component) Plain_Row :: struct {value:f32}
@(component,locks="Plain_Row") Locker :: struct {}
@(component,locks="Nowhere") Lost_Lock :: struct {}
@(storage,host,locks="Owned") Far_Lock :: struct {}
@(storage,single) Alone :: struct {}
@(storage,far) Distant :: struct {}
@(storage,setting="cloud") Cloudy :: struct {}
@(component,setting) Row_Setting :: struct {}
@(component,copy_kept="row_copy") Kept_Row :: struct {}
@(storage,host,by_world) Session :: struct {}
@(component) Twice :: struct {}
@(component) Twice :: struct {}
@(name_bits) Bare :: distinct u8
@(names="MOVE_") Move :: distinct u8
MOVE_ :: Move(1)
@(step="fixed") steady :: proc() {}
@(storage) Network :: struct {}
`},
        {project.path(game,"game","shown.odin",allocator=context.temp_allocator),`package game
import "mirai:core"
@(component,replicated) Score_Row :: struct {value:f32}
@(component) Glow :: struct {value:f32}
@(storage) Hud_State :: struct {value:f32}
@(storage,events) Clicked :: struct {count:int}
@(storage,events) Hits :: struct {count:int}
@(storage,queue) Wishes :: struct {count:int}
@(step="ui") hud_scores :: proc(rows:^core.Table(Score_Row)) {}
@(step="render") hud_spawns :: proc(entities:^core.Entities) {}
@(step="ui release") hud_commands :: proc(commands:core.Commands) {}
@(step="ui",server) hud_rules :: proc() {}
@(step="ui") hud_glow :: proc(glows:^core.Table(Glow),state:^Hud_State,clicked:^Clicked,wishes:^Wishes) {}
@(step="fixed") glow_reader :: proc(glows:core.Read(Glow),state:core.Ref(Hud_State),clicked:core.Ref(Clicked),wishes:^Wishes) {}
@(step="frame render") glow_both :: proc(state:^Hud_State) {}
@(step="frame") hits_shown :: proc(hits:^Hits) {}
@(step="fixed") hits_ticked :: proc(hits:^Hits) {}
@(step="fixed") hits_reader :: proc(hits:core.Ref(Hits)) {}
`},
        {project.path(game,"game","game.odin",allocator=context.temp_allocator),"package game\nimport editor \"project:editor\"\n"+`@(step="fixed") steady :: proc() {}
@(step="fixed") counted :: proc() -> int {return 0}
@(step="fixed") five :: 5
@(step="later") misplaced :: proc() {}
@(step="fixed",loops="arcade") lost_loop :: proc() {}
@(params) Odd :: distinct int
@(step="frame") tools_in_game :: proc(tools:editor.Tools) {}
`},
        {project.path(game,"editor","editor.odin",allocator=context.temp_allocator),`package editor
@(storage) Panel :: struct {}
@(net_message) Hello :: struct {}
@(params) Tools :: struct {panel:^Panel}
@(step="frame",loops="game") panel_in_game :: proc(panel:^Panel) {}
@(step="fixed") panel_fixed :: proc(panel:^Panel) {}
`},
    }
    for file in files {
        dir:=file[0][:strings.last_index_any(file[0],`/\`)]
        if !testing.expect(t,os.make_directory_all(dir)==nil || os.is_dir(dir)) {return}
        if !testing.expect(t,os.write_entire_file(file[0],file[1])==nil) {return}
    }
    p:=project.Project{root=game,engine_root=engine}
    output:=world_generate(&p,context.temp_allocator)
    wanted:=[]string{
        "Alone says single",
        "Distant says far",
        `Cloudy has setting="cloud", which is not a kind of setting`,
        "Row_Setting is a setting: mark it",
        "Kept_Row says copy_kept",
        "Session is by_world, and the world has no core.World_Id",
        "Twice is declared twice",
        "Locker locks Plain_Row, which is not @(component,shared)",
        "Lost_Lock locks mirai:core.Nowhere, which is not a component",
        "Far_Lock locks Owned, which is in another place of the world",
        "Bare says name_bits without a type",
        "MOVE_ has an empty name",
        "a step steady already exists in",
        "counted returns something",
        "@(step) on five, which is not a procedure",
        `misplaced has the phase "later"`,
        `lost_loop has the loop "arcade"`,
        "@(params) on Odd, which is not a struct without parameters",
        "tools_in_game receives Tools, a @(params) of an editor package",
        "Hello is a @(net_message) of the editor",
        "panel_in_game is in an editor package and asks for the game loop",
        "panel_in_game runs in the game and receives Panel, which is of the editor",
        "panel_fixed runs in fixed, which a rollback runs again, and receives Panel of the editor",
        "hud_scores runs only in ui or render and writes Score_Row, which is replicated",
        "hud_spawns runs only in ui or render and receives ^core.Entities, which creates and destroys entities, as a dedicated server would not: create them in input, fixed, frame or late; to ask only whether an entity is alive or off, receive core.Ref(core.Entities)",
        "hud_commands runs only in ui or render and creates or destroys entities",
        "hud_rules is server and runs only in ui or render",
        "glow_reader reads Glow, which only hud_glow writes, in ui or render",
        "glow_reader runs in fixed and reads Clicked, which only hud_glow fills",
    }
    for want in wanted {
        found:=false
        for message in output.errors {found||=strings.contains(message,want)}
        testing.expectf(t,found,"no error says %q: %v",want,output.errors)
    }
    testing.expect_value(t,len(output.errors),len(wanted))
}

// The game loop leaves core.Input and the actions made of it at the last tick
// outside fixed: a step that reads them there is refused, and what the editor
// loop refills or fixed reads is not.
@(test)
a_step_of_the_game_that_reads_the_input_of_the_tick_outside_fixed_is_refused :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-rules-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    files:=[][2]string{
        {project.path(engine,"core","data.odin",allocator=context.temp_allocator),`package core
@(storage,keep) Input :: struct {keys:u32}
@(storage,copy=false) Frame_Input :: struct {using input:Input}
Ref :: struct($T:typeid) {value:^T}
`},
        {project.path(engine,"engine","input","input.odin",allocator=context.temp_allocator),`package input
import "mirai:core"
@(storage,keep) Actions :: struct {count:u32}
@(storage,keep) Frame_Actions :: struct {count:u32}
@(params) Input_Of :: struct {actions:core.Ref(Actions)}
@(params) Frame_Input_Of :: struct {actions:core.Ref(Frame_Actions)}
`},
        {project.path(game,"game","game.odin",allocator=context.temp_allocator),`package game
import "mirai:core"
import inp "mirai:engine/input"
@(params) Pad :: struct {device:core.Input}
@(step="frame") stale_value :: proc(input:core.Input) {}
@(step="frame") stale_ref :: proc(input:core.Ref(core.Input)) {}
@(step="frame") stale_bundle :: proc(pad:Pad) {}
@(step="fixed frame",loops="game editor") stale_both :: proc(input:core.Input) {}
@(step="frame") fresh :: proc(input:core.Frame_Input) {}
@(step="fixed") ticked :: proc(input:core.Input) {}
@(step="frame",loops="editor") refilled :: proc(input:core.Input) {}
@(step="late") stale_actions :: proc(input:inp.Input_Of) {}
@(step="input") stale_input :: proc(input:core.Input) {}
@(step="ui") fresh_actions :: proc(input:inp.Frame_Input_Of) {}
@(step="fixed") ticked_actions :: proc(input:inp.Input_Of) {}
`},
    }
    for file in files {
        dir:=file[0][:strings.last_index_any(file[0],`/\`)]
        if !testing.expect(t,os.make_directory_all(dir)==nil || os.is_dir(dir)) {return}
        if !testing.expect(t,os.write_entire_file(file[0],file[1])==nil) {return}
    }
    p:=project.Project{root=game,engine_root=engine}
    output:=world_generate(&p,context.temp_allocator)
    refused:=[][2]string{
        {"stale_value","core.Frame_Input"},{"stale_ref","core.Frame_Input"},{"stale_bundle","core.Frame_Input"},{"stale_both","core.Frame_Input"},
        {"stale_input","core.Frame_Input"},{"stale_actions","input.Frame_Input_Of"},
    }
    for step in refused {
        found:=false
        for message in output.errors {
            found||=strings.contains(message,step[0]) && strings.contains(message,"runs outside fixed") && strings.contains(message,step[1])
        }
        testing.expectf(t,found,"no error names %s: %v",step[0],output.errors)
    }
    testing.expect_value(t,len(output.errors),len(refused))
}
