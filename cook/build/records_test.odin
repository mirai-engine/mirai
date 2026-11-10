package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(private="file")
records_fixture :: proc(t:^testing.T,game_source:string,editor_source:="") -> (output:Generated,ok:bool) {
    folder:=base.test_folder(t,"records")
    if folder=="" {return}
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    folders:=[]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator),project.path(game,"editor",allocator=context.temp_allocator)}
    for path in folders {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    core_source:=`package core
Record :: struct($T:typeid) {table:[2]u64,row:u64}
Records :: struct($T:typeid) {set:rawptr}
@(component)
Spin :: struct {speed:f32}
`
    testing.expect(t,os.write_entire_file(project.path(folders[0],"core.odin",allocator=context.temp_allocator),core_source)==nil)
    testing.expect(t,os.write_entire_file(project.path(folders[1],"game.odin",allocator=context.temp_allocator),game_source)==nil)
    if editor_source!="" {testing.expect(t,os.write_entire_file(project.path(folders[2],"editor.odin",allocator=context.temp_allocator),editor_source)==nil)}
    p:=project.Project{root=game,engine_root=engine}
    return world_generate(&p,context.temp_allocator),true
}

// A struct marked @(record) is in World_Info.records of both worlds, with its
// default, the descriptions of its fields and the typeid of its Record(T); a
// step that receives core.Records(T) gets the set of the application.
@(test)
a_record_type_reaches_the_world_info_and_the_steps_that_read_it :: proc(t:^testing.T) {
    source:=`package game
import "mirai:core"
@(record,description="A weapon a player can hold")
Weapon :: struct {
    damage:f32, // per hit
    ammo:core.Record(Ammo),
}
WEAPON_DEFAULT :: Weapon{damage=10}
@(record)
Ammo :: struct {count:u16}
@(component)
Holder :: struct {weapon:core.Record(Weapon)}
@(step="fixed")
fire :: proc(weapons:core.Records(Weapon),holders:core.Read(Holder)) {}
`
    output,ok:=records_fixture(t,source)
    if !ok {return}
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expectf(t,strings.contains(text,`records[0]={"Weapon","game",typeid_of(p_game.Weapon),type_info_of(p_game.Weapon),typeid_of(p_core.Record(p_game.Weapon)),record_default_game_weapon,"A weapon a player can hold",record_fields_game_weapon[:],true}`),"%s",text)
        testing.expect(t,strings.contains(text,`records[1]={"Ammo","game",typeid_of(p_game.Ammo),type_info_of(p_game.Ammo),typeid_of(p_core.Record(p_game.Ammo)),nil,"",nil,true}`))
        testing.expect(t,strings.contains(text,`record_default_game_weapon :: proc(dst:rawptr) {(cast(^p_game.Weapon)dst)^=p_game.WEAPON_DEFAULT}`))
        testing.expect(t,strings.contains(text,`record_fields_game_weapon:=[1]p_core.Field_Description{{"damage","per hit"}}`))
        testing.expect(t,strings.contains(text,`p_core.Records(p_game.Weapon){p_host.app_record_set(app,0)}`))
        testing.expect(t,strings.contains(text,"info.records=records"))
        // A record is no data of the World: it has no field there.
        testing.expect(t,!strings.contains(text,"weapon:p_game.Weapon"))
    }
}

// What a table of game data cannot hold, where a record cannot be declared
// and what it cannot also be are errors that say what to do instead.
@(test)
records_that_are_not_plain_game_data_are_errors :: proc(t:^testing.T) {
    cases:=[]struct {source,editor,wanted:string}{
        {"package game\n@(record)\nLine :: struct {text:string}\n","","Line says record and Line.text is a string"},
        {"package game\nimport \"mirai:core\"\n@(record)\nTarget :: struct {who:core.Entity}\n","","Target.who is an Entity"},
        {"package game\n@(record,component)\nBoth :: struct {value:f32}\n","","is a @(record), the row of tables of game data, and also a component"},
        {"package game\n","package editor\n@(record)\nTool :: struct {value:f32}\n","is a @(record) in a package of the editor"},
        {"package game\n@(record)\nCount :: distinct u32\n","","is a @(record) and not a struct"},
        {"package game\nimport \"mirai:core\"\n@(component)\nHeld :: struct {value:f32}\n@(step=\"fixed\")\nread :: proc(rows:core.Records(Held)) {}\n","","the parameter rows of read is core.Records(Held)"},
    }
    for c in cases {
        output,ok:=records_fixture(t,c.source,c.editor)
        if !ok {return}
        found:=false
        for message in output.errors {found||=strings.contains(message,c.wanted)}
        testing.expectf(t,found,"%q not in %v",c.wanted,output.errors)
    }
}

// A procedure @(draw="name") of the game is in World_Info.draws of both
// worlds, by the name the Draw nodes of the interfaces say.
@(test)
a_draw_procedure_reaches_the_world_info_by_its_name :: proc(t:^testing.T) {
    source:=`package game
import "mirai:ui"
@(draw="minimap")
minimap_draw :: proc(ctx:^ui.Context,node:ui.Draw_Node) {}
@(draw="graph")
graph_draw :: proc(ctx:^ui.Context,node:ui.Draw_Node) {}
`
    output,ok:=records_fixture(t,source)
    if !ok {return}
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expectf(t,strings.contains(text,`draws[0]={"minimap",rawptr(p_game.minimap_draw)}`) && strings.contains(text,`draws[1]={"graph",rawptr(p_game.graph_draw)}`),"%s",text)
        testing.expect(t,strings.contains(text,"draws:=make([]p_core.Draw_Info,2)") && strings.contains(text,"info.draws=draws"))
    }
}
