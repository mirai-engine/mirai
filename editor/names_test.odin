package editor

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:project"
import "mirai:std/base"

// An input action is renamed in code; once built, renaming it follows: the
// input.mirai of the project takes the new name and the code stays as it is.
// Following before the code declares the new name, or while it keeps the old
// one, says to rename it in code first. A new action is declared in code.
@(test)
renaming_an_action_follows_the_code_in_input_mirai :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"names")
    if folder=="" {return}
    game:=project.path(folder,"game",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(game)==nil)
    code:=project.path(game,"game.odin",allocator=context.temp_allocator)
    bindings:=project.path(folder,project.INPUT_FILE,allocator=context.temp_allocator)
    SOURCE :: "package game\n@(actions)\nAction :: enum u8 {Strike,Hitter}\n"
    testing.expect(t,os.write_entire_file(code,SOURCE)==nil)
    testing.expect(t,os.write_entire_file(bindings,`{"actions": [
    {"name": "hit", "kind": "Button", "bindings": [{"mouse_button": "Left"}]},
    {"name":"hitter", "kind": "Button", "bindings": []}
]}`)==nil)

    names:=[]core.Name_Info{
        {type=input.Action,value=16,name="strike",library="game",file="game/game.odin",line=3,project=true},
        {type=input.Action,value=17,name="hitter",library="game",file="game/game.odin",line=3,project=true},
    }
    types:=[]core.Named_Type_Info{{type=input.Action,name="Action",path="mirai:engine/input",actions=true}}
    info:=core.World_Info{names=names,named_types=types}
    build:Build_State
    s:=Session{build=&build,has_project=true,project_root=folder}

    testing.expect_value(t,names_rename(&s,&info,input.Action,"hit","punch"),Names_Error.Action_Not_Declared)
    testing.expect_value(t,names_rename(&s,&info,input.Action,"hitter","strike"),Names_Error.Action_Still_Declared)
    testing.expect_value(t,names_rename(&s,&info,input.Action,"hit","strike"),Names_Error.None)
    written,_:=os.read_entire_file(code,context.temp_allocator)
    testing.expect_value(t,string(written),SOURCE)
    renamed,_:=os.read_entire_file(bindings,context.temp_allocator)
    testing.expect_value(t,string(renamed),`{"actions": [
    {"name": "strike", "kind": "Button", "bindings": [{"mouse_button": "Left"}]},
    {"name":"hitter", "kind": "Button", "bindings": []}
]}`)
    testing.expect_value(t,input_file_rename(string(renamed),"hit","x"),"")
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
