package editor

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"

@(private="file") Names_World :: struct {using world:core.Test_World,settings:input.Input_Settings}

// An input action is renamed in code; once built, renaming it follows:
// Input_Settings of the project takes the new name and the code stays as it
// is. Following before the code declares the new name, or while it keeps the
// old one, says to rename it in code first. A new action is declared in code.
@(test)
renaming_an_action_follows_the_code_in_input_settings :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"names")
    if folder=="" {return}
    game:=project.path(folder,"game",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(game)==nil)
    code:=project.path(game,"game.odin",allocator=context.temp_allocator)
    SOURCE :: "package game\n@(actions)\nAction :: enum u8 {Strike,Hitter}\n"
    testing.expect(t,os.write_entire_file(code,SOURCE)==nil)

    info,made:=core.test_info(t,Names_World)
    if !made {return}
    defer core.test_info_destroy(&info)
    info.names=[]core.Name_Info{
        {type=input.Action,value=16,name="strike",library="game",file="game/game.odin",line=3,project=true},
        {type=input.Action,value=17,name="hitter",library="game",file="game/game.odin",line=3,project=true},
    }
    info.named_types=[]core.Named_Type_Info{{type=input.Action,name="Action",path="mirai:engine/input",actions=true}}
    core.test_info_index(&info)
    world:Names_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&world)
    input.input_settings_put(&world.settings,"hit",input.action_default(.Button,input.binding_mouse_button(.Left)))
    input.input_settings_put(&world.settings,"hitter",input.action_default(.Button))
    app:host.App
    app.info=&info
    build:Build_State
    s:=Session{build=&build,has_project=true,project_root=folder,info=&info,app=&app,edit_world=&world}

    testing.expect_value(t,names_rename(&s,&info,input.Action,"hit","punch"),Names_Error.Action_Not_Declared)
    testing.expect_value(t,names_rename(&s,&info,input.Action,"hitter","strike"),Names_Error.Action_Still_Declared)
    testing.expect_value(t,names_rename(&s,&info,input.Action,"hit","strike"),Names_Error.None)
    written,_:=os.read_entire_file(code,context.temp_allocator)
    testing.expect_value(t,string(written),SOURCE)
    testing.expect(t,input.input_settings_find(&world.settings,"hit")==nil && input.input_settings_find(&world.settings,"strike")!=nil)
    file,_:=os.read_entire_file(project.path(folder,project.SETTINGS_FILE,allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(file),`"strike"`) && !strings.contains(string(file),`"hit"`),string(file))
    _,created:=names_create(&s,&info,input.Action,"dash")
    testing.expect_value(t,created,Names_Error.Action_In_Code)
    testing.expect(t,strings.contains(names_error_text(created,"Action","dash"),"add Dash to it"))
}

// A new value follows the highest, skips those taken and leaves out the last
// value of the type, which a sentinel with a name may hold.
@(test)
a_new_name_takes_the_value_after_the_highest_below_the_last :: proc(t:^testing.T) {
    profiles:=[]core.Name_Info{{value=0},{value=1},{value=255}}
    testing.expect_value(t,names_free(profiles,256),i64(2))
    testing.expect_value(t,names_free(nil,32),i64(0))
    full:=[]core.Name_Info{{value=0},{value=1},{value=2},{value=3}}
    testing.expect_value(t,names_free(full,4),i64(4))
    ends:=[]core.Name_Info{{value=0},{value=3}}
    testing.expect_value(t,names_free(ends,4),i64(1))
}
