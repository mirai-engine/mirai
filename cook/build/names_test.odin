package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(private="file")
names_project :: proc(t:^testing.T,folder,core_source,game_source:string) -> (p:project.Project,ok:bool) {
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
NAMES_CORE :: `package core
@(names="MODE_") Mode :: distinct u16
@(name_bits="Mode") Mode_Mask :: distinct u32
Mode_Bits :: distinct u64
MODE_FALLING :: Mode(0)
MODE_WALKING :: Mode(1)
LIMIT :: 4
`

// The constants of a type @(names) in any package are its values with names:
// the identifier without the prefix of the type in lower case, or its
// @(name); a mask @(name_bits) names its bits by them.
@(test)
the_constants_of_a_named_type_are_its_values :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"names")
    if folder=="" {return}
    p,ok:=names_project(t,folder,NAMES_CORE,`package game
import "mirai:core"
MODE_SWIM :: core.Mode(16)
@(name="ladder",name_requires="Ladder") CLIMB : core.Mode : 17
@(component) Ladder :: struct {height:f32}
@(name_bits="core.Mode") Moves :: core.Mode_Bits
`)
    if !ok {return}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        for line in ([]string{
            `{typeid_of(p_core.Mode),i64(p_core.MODE_FALLING),"falling","core","core/data.odin",5,false,false,nil}`,
            `{typeid_of(p_core.Mode),i64(p_core.MODE_WALKING),"walking","core","core/data.odin",6,false,false,nil}`,
            `{typeid_of(p_core.Mode),i64(p_game.MODE_SWIM),"swim","game","game/game.odin",3,false,true,nil}`,
            `{typeid_of(p_core.Mode),i64(p_game.CLIMB),"ladder","game","game/game.odin",4,true,true,typeid_of(p_game.Ladder)}`,
            `named_types[0]={typeid_of(p_core.Mode),"Mode","mirai:core","MODE_",min(min(i64(1)<<uint(min(8*size_of(p_core.Mode),63)),i64(8*size_of(p_core.Mode_Mask))),i64(8*size_of(p_game.Moves))),false}`,
            `name_bits[0]={typeid_of(p_core.Mode_Mask),typeid_of(p_core.Mode)}`,
            `name_bits[1]={typeid_of(p_game.Moves),typeid_of(p_core.Mode)}`,
        }) {testing.expectf(t,strings.contains(text,line),"%s is not in\n%s",line,text)}
        testing.expect(t,!strings.contains(text,"LIMIT"),"a constant of another type has no name")
        testing.expect(t,strings.contains(text,"info.named_types,info.names,info.name_bits,info.actions=named_types,names,name_bits,actions"))
    }
}

// Two constants with one name in a type, a type @(names) that is not a
// distinct integer, and a mask of what has no names are errors that say how
// to fix them.
@(test)
named_types_and_their_names_are_checked :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"names")
    if folder=="" {return}
    p,ok:=names_project(t,folder,NAMES_CORE,`package game
import "mirai:core"
WALKING :: core.Mode(5)
@(names) Shape :: struct {a:int}
@(name_bits="Nothing") Mask :: distinct u8
`)
    if !ok {return}
    errors:=world_generate(&p,context.temp_allocator).errors
    wanted:=[]string{`are both named "walking" in Mode`,"@(names) marks a distinct integer",`says name_bits="project:game.Nothing", which is not a type @(names)`}
    for want in wanted {
        found:=false
        for message in errors {found||=strings.contains(message,want)}
        testing.expectf(t,found,"no error says %q: %v",want,errors)
    }
}
