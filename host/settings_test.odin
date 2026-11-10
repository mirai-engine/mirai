package host

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:project"
import "mirai:std/base"

@(private="file") @(storage,setting="machine")
Layered :: struct {code,engine,both:i32}
@(private="file") @(storage,setting)
Rule :: struct {value:i32}
@(private="file") Layered_World :: struct {using world:core.Test_World,layered:Layered,rule:Rule}

@(private="file")
layered_types :: proc(types:^[dynamic]core.Test_Type) {
    append(types,core.test_type(Layered,default=proc(dst:^Layered) {dst^={code=1,engine=1,both=1}}))
}

// A world takes the values of the code, the settings of the machine in the
// file of the engine the application runs with over them, and those of the
// project over both. The file of the engine does not set the others.
@(test)
a_world_reads_the_settings_of_the_engine_under_those_of_the_project :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"host-settings")
    if folder=="" {return}
    root,engine:=project.path(folder,"project",allocator=context.temp_allocator),project.path(folder,"engine",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(root)==nil && os.make_directory_all(project.path(engine,".mirai",allocator=context.temp_allocator))==nil)
    testing.expect(t,os.write_entire_file(project.settings_file(.Engine,root,engine,context.temp_allocator),`{"version": 3, "Layered": {"engine": 2, "both": 2}, "Rule": {"value": 5}}`)==nil)
    testing.expect(t,os.write_entire_file(project.settings_file(.Project,root,engine,context.temp_allocator),`{"Layered": {"both": 3}}`)==nil)
    info,described:=core.test_info(t,Layered_World,layered_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Layered_World
    app:=App{info=&info,root=root,engine_root=engine}
    app_settings_load(&app,&world,.World)
    testing.expect_value(t,world.layered,Layered{code=1,engine=2,both=3})
    testing.expect_value(t,world.rule,Rule{})
    // A shipped game knows no engine: only its own file.
    app.engine_root=""
    app_settings_load(&app,&world,.World)
    testing.expect_value(t,world.layered,Layered{code=1,engine=1,both=3})
}

// The options of the player are the layer on top: they give the settings of
// the machine, never those of the project, and saving them writes what
// differs from the layers under them.
@(test)
the_options_of_the_player_are_the_layer_on_top :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"host-options")
    if folder=="" {return}
    root,engine,player:=project.path(folder,"project",allocator=context.temp_allocator),project.path(folder,"engine",allocator=context.temp_allocator),project.path(folder,"player",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(root)==nil && os.make_directory_all(project.path(engine,".mirai",allocator=context.temp_allocator))==nil && os.make_directory_all(player)==nil)
    testing.expect(t,os.write_entire_file(project.settings_file(.Engine,root,engine,context.temp_allocator),`{"version": 3, "Layered": {"engine": 2}}`)==nil)
    testing.expect(t,os.write_entire_file(project.settings_file(.Project,root,engine,context.temp_allocator),`{"Layered": {"both": 3}, "Rule": {"value": 5}}`)==nil)
    options:=project.settings_file(.Player,root,engine,context.temp_allocator,player)
    testing.expect(t,os.write_entire_file(options,`{"version": 3, "Layered": {"code": 7}, "Rule": {"value": 9}}`)==nil)
    info,described:=core.test_info(t,Layered_World,layered_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Layered_World
    app:=App{info=&info,root=root,engine_root=engine,options=player}
    app_settings_load(&app,&world,.World)
    testing.expect_value(t,world.layered,Layered{code=7,engine=2,both=3})
    testing.expect_value(t,world.rule,Rule{5})

    world.layered.code,world.layered.engine=1,4
    testing.expect(t,app_options_save(&app,&world))
    world.layered,world.rule={},{}
    app_settings_load(&app,&world,.World)
    testing.expect_value(t,world.layered,Layered{code=1,engine=4,both=3})
    data,_:=os.read_entire_file(options,context.temp_allocator)
    text:=string(data)
    testing.expectf(t,strings.contains(text,`"engine": 4`) && !strings.contains(text,`"code"`) && !strings.contains(text,`"both"`) && strings.contains(text,`"Rule"`),"%s",text)
    app.options=""
    testing.expect(t,!app_options_save(&app,&world))
}

@(private="file") Simulation_World :: struct {using world:core.Test_World}
@(private="file") Simulation_Shared :: struct {simulation:core.Simulation_Settings}

// A World is made with the tick rate the settings of the application have
// then; a rate of zero leaves the step as it was.
@(test)
a_world_is_made_with_the_tick_rate_of_the_settings :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Simulation_World,Simulation_Shared,core.Test_None)
    if !described {return}
    defer core.test_info_destroy(&info)
    shared:Simulation_Shared
    if !testing.expect(t,info.init[.Shared](&shared,context.allocator)) {return}
    defer info.destroy[.Shared](&shared)
    app:=App{info=&info,shared=&shared,tick_dt=1}
    tick_rate_follow(&app)
    testing.expect_value(t,app.tick_dt,f32(1)/60)
    shared.simulation.tick_rate=30
    tick_rate_follow(&app)
    testing.expect_value(t,app.tick_dt,f32(1)/30)
    shared.simulation.tick_rate=0
    tick_rate_follow(&app)
    testing.expect_value(t,app.tick_dt,f32(1)/30)
}
