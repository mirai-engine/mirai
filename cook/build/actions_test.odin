package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
actions_project :: proc(t:^testing.T,folder,core_source,game_source:string) -> (p:project.Project,ok:bool) {
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
ACTIONS_CORE :: `package core
@(names,actions) Action :: distinct u8
@(name_bits="Action") Action_Mask :: distinct u64
@(storage) Actions :: struct {states:[64]f32}
@(params) Input_Of :: struct($E:typeid) {actions:Ref(Actions),base:Action}
@(actions) Look_Action :: enum u8 {Look}
@(actions) Walk_Action :: enum u8 {Move,Jump}
Action_Bindings :: struct {kind:u8}
`

// The members of the @(actions) enums are the actions of the world, one
// library after the other, named in lower case; a step that receives
// Input_Of(E) gets the base of E; and the defaults of an enum are
// <enum>_defaults() beside it, which the world hands the input map.
@(test)
the_members_of_the_actions_enums_take_the_actions_in_order :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"actions")
    if folder=="" {return}
    p,ok:=actions_project(t,folder,ACTIONS_CORE,`package game
import "mirai:core"
@(actions)
Action :: enum u8 {
    Layer_Back,
    Stamp,
}
action_defaults :: proc() -> [Action]core.Action_Bindings {return {.Layer_Back={kind=1},.Stamp={kind=1}}}
@(step="fixed") game_stamp :: proc(input:core.Input_Of(Action),walk:core.Input_Of(core.Walk_Action)) {}
`)
    if !ok {return}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        for line in ([]string{
            `{typeid_of(p_core.Action),i64(0),"look","core","core/data.odin",6,false,false,nil}`,
            `{typeid_of(p_core.Action),i64(1),"move","core","core/data.odin",7,false,false,nil}`,
            `{typeid_of(p_core.Action),i64(2),"jump","core","core/data.odin",7,false,false,nil}`,
            `{typeid_of(p_core.Action),i64(3),"layer_back","game","game/game.odin",5,false,true,nil}`,
            `{typeid_of(p_core.Action),i64(4),"stamp","game","game/game.odin",6,false,true,nil}`,
            `actions[0]={typeid_of(p_core.Look_Action),type_info_of(p_core.Look_Action),0,"core",nil}`,
            `actions[2]={typeid_of(p_game.Action),type_info_of(p_game.Action),3,"game",action_defaults_2}`,
            `action_defaults_2 :: proc(dst:rawptr) {(cast(^[p_game.Action]p_core.Action_Bindings)dst)^=p_game.action_defaults()}`,
            `i64(8*size_of(p_core.Action_Mask))),true}`,
            `p_game.game_stamp(p_core.Input_Of(p_game.Action){actions=p_core.ref(&w.actions),base=p_core.Action(3)},p_core.Input_Of(p_core.Walk_Action){actions=p_core.ref(&w.actions),base=p_core.Action(1)})`,
            "info.named_types,info.names,info.name_bits,info.actions=named_types,names,name_bits,actions",
        }) {testing.expectf(t,strings.contains(text,line),"%s is not in\n%s",line,text)}
        testing.expect(t,!strings.contains(text,"#assert"),"the generator gives each its value")
    }
    actions,errors:=world_actions(&p,context.temp_allocator)
    testing.expect(t,len(errors)==0 && len(actions)==5 && actions[3]==serial.Choice{"layer_back",3},fmt.tprint(actions,errors))
}

// More actions than the mask holds, one name in two enums, an enum that is
// not of u8 or gives its members values, a constant of the type of the
// actions, Input_Of of what is not an enum @(actions) and a storage that
// carries defaults of actions are errors that say how to fix them.
@(test)
the_actions_enums_are_checked :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"actions")
    if folder=="" {return}
    many:=strings.builder_make(context.temp_allocator)
    for i in 0..<62 {fmt.sbprintf(&many,"A%d,",i)}
    cases:=[]struct{game,says:string}{
        {fmt.tprintf("package game\n@(actions) Action :: enum u8 {{%s}}\n",strings.to_string(many)),"declare 65 actions (core.Look_Action 1, core.Walk_Action 2, game.Action 62), and Action holds 64: remove the actions no longer used"},
        {"package game\n@(actions) Action :: enum u8 {Jump}\n",`Action.Jump and Walk_Action.Jump`},
        {"package game\n@(actions) Action :: enum u16 {Fire}\n","its members are not u8: write Action :: enum u8"},
        {"package game\n@(actions) Action :: enum u8 {Fire=4}\n","the generator gives the values of actions"},
        {"package game\nimport \"mirai:core\"\nFIRE :: core.Action(9)\n","make it a member of the @(actions) enum of its library"},
        {"package game\nimport \"mirai:core\"\nKind :: enum u8 {A}\n@(step=\"fixed\") game_kind :: proc(input:core.Input_Of(Kind)) {}\n","Input_Of is received for the @(actions) enum whose actions it reads"},
        {"package game\nimport \"mirai:core\"\n@(actions) Action :: enum u8 {Fire}\n@(storage) Game_Actions :: struct {defaults:[Action]core.Action_Bindings}\n","game.odin(4): Game_Actions carries the defaults of the actions of Action, and a struct carries no defaults of actions: declare them beside the enum as action_defaults"},
    }
    for c in cases {
        p,ok:=actions_project(t,folder,ACTIONS_CORE,c.game)
        if !ok {return}
        errors:=world_generate(&p,context.temp_allocator).errors
        found:=false
        for message in errors {found||=strings.contains(message,c.says)}
        testing.expectf(t,found,"no error says %q: %v",c.says,errors)
    }
    // Bindings held as data, by a number and not by an enum @(actions), are no defaults.
    p,ok:=actions_project(t,folder,ACTIONS_CORE,"package game\nimport \"mirai:core\"\n@(storage) Game_Bindings :: struct {held:[8]core.Action_Bindings}\n")
    if !ok {return}
    for message in world_generate(&p,context.temp_allocator).errors {testing.expectf(t,!strings.contains(message,"carries the defaults"),"%s",message)}
}
