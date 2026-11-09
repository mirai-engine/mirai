package host

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:project"

@(private="file") Layered :: struct {code,engine,both:i32}
@(private="file") Rule :: struct {value:i32}
@(private="file") Layered_World :: struct {layered:Layered,rule:Rule}

// A world takes the values of the code, the settings of the machine in the
// file of the engine the application runs with over them, and those of the
// project over both. The file of the engine does not set the others.
@(test)
a_world_reads_the_settings_of_the_engine_under_those_of_the_project :: proc(t:^testing.T) {
    folder,_:=os.make_directory_temp("","mirai-host-settings",context.temp_allocator)
    defer os.remove_all(folder)
    root,engine:=project.path(folder,"project",allocator=context.temp_allocator),project.path(folder,"engine",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(root)==nil && os.make_directory_all(project.path(engine,".mirai",allocator=context.temp_allocator))==nil)
    testing.expect(t,os.write_entire_file(project.settings_file(.Engine,root,engine,context.temp_allocator),`{"version": 3, "Layered": {"engine": 2, "both": 2}, "Rule": {"value": 5}}`)==nil)
    testing.expect(t,os.write_entire_file(project.settings_file(.Project,root,engine,context.temp_allocator),`{"Layered": {"both": 3}}`)==nil)
    storages:=[2]core.Storage_Info{
        {
            name="Layered",type=Layered,info=type_info_of(Layered),offset=offset_of(Layered_World,layered),place=.World,setting=.Machine,
            default=proc(dst:rawptr) {(^Layered)(dst)^={code=1,engine=1,both=1}},
        },
        {name="Rule",type=Rule,info=type_info_of(Rule),offset=offset_of(Layered_World,rule),place=.World,setting=.Project},
    }
    info:=core.World_Info{storages=storages[:]}
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
    folder,_:=os.make_directory_temp("","mirai-host-options",context.temp_allocator)
    defer os.remove_all(folder)
    root,engine,player:=project.path(folder,"project",allocator=context.temp_allocator),project.path(folder,"engine",allocator=context.temp_allocator),project.path(folder,"player",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(root)==nil && os.make_directory_all(project.path(engine,".mirai",allocator=context.temp_allocator))==nil && os.make_directory_all(player)==nil)
    testing.expect(t,os.write_entire_file(project.settings_file(.Engine,root,engine,context.temp_allocator),`{"version": 3, "Layered": {"engine": 2}}`)==nil)
    testing.expect(t,os.write_entire_file(project.settings_file(.Project,root,engine,context.temp_allocator),`{"Layered": {"both": 3}, "Rule": {"value": 5}}`)==nil)
    options:=project.settings_file(.Player,root,engine,context.temp_allocator,player)
    testing.expect(t,os.write_entire_file(options,`{"version": 3, "Layered": {"code": 7}, "Rule": {"value": 9}}`)==nil)
    storages:=[2]core.Storage_Info{
        {
            name="Layered",type=Layered,info=type_info_of(Layered),offset=offset_of(Layered_World,layered),place=.World,setting=.Machine,
            default=proc(dst:rawptr) {(^Layered)(dst)^={code=1,engine=1,both=1}},
        },
        {name="Rule",type=Rule,info=type_info_of(Rule),offset=offset_of(Layered_World,rule),place=.World,setting=.Project},
    }
    info:=core.World_Info{storages=storages[:]}
    world:Layered_World
    app:=App{info=&info,root=root,engine_root=engine,options=player}
    app_settings_load(&app,&world,.World)
    testing.expect_value(t,world.layered,Layered{code=7,engine=2,both=3})
    testing.expect_value(t,world.rule,Rule{5})

    world.layered.code,world.layered.engine=1,4
    testing.expect(t,app_options_save(&app,&world))
    world={}
    app_settings_load(&app,&world,.World)
    testing.expect_value(t,world.layered,Layered{code=1,engine=4,both=3})
    data,_:=os.read_entire_file(options,context.temp_allocator)
    text:=string(data)
    testing.expectf(t,strings.contains(text,`"engine": 4`) && !strings.contains(text,`"code"`) && !strings.contains(text,`"both"`) && strings.contains(text,`"Rule"`),"%s",text)
    app.options=""
    testing.expect(t,!app_options_save(&app,&world))
}

@(private="file") Simulation_Shared :: struct {simulation:core.Simulation_Settings}

// A World is made with the tick rate the settings of the application have
// then; a rate of zero leaves the step as it was.
@(test)
a_world_is_made_with_the_tick_rate_of_the_settings :: proc(t:^testing.T) {
    storages:=[1]core.Storage_Info{{name="Simulation_Settings",type=core.Simulation_Settings,info=type_info_of(core.Simulation_Settings),offset=offset_of(Simulation_Shared,simulation),place=.Shared,setting=.Project}}
    info:=core.World_Info{storages=storages[:]}
    shared:=Simulation_Shared{core.SIMULATION_SETTINGS_DEFAULT}
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
