package input

import "core:strings"
import "core:testing"
import "mirai:core"

// An enum @(actions) whose base the generator made 3, and an action of the game at 40.
@(private="file") Test_Action :: enum u8 {Move,Jump}
@(private="file") MOVE :: Action(3)
@(private="file") JUMP :: Action(4)
@(private="file") HIT :: Action(40)

@(private="file")
Test_Defaults :: struct {
    count:int,
    defaults:[Test_Action]Action_Default,
}

@(private="file")
defaults_types :: proc(types:^[dynamic]core.Test_Type) {
    append(types,
        core.test_type(Test_Defaults,default=proc(dst:^Test_Defaults) {
            dst^={defaults={
                .Move=action_default(.Axis2,binding_keys(.A,.D,.S,.W),binding_gamepad_stick(.Left)),
                .Jump=action_default(.Button,binding_key(.Space)),
            }}
        }),
        core.test_type(Loose_Defaults,default=proc(dst:^Loose_Defaults) {dst^={defaults={.Fire=action_default(.Button,binding_key(.F))}}}),
    )
}

@(private="file")
Defaults_World :: struct {
    using world:core.Test_World,
    defaults:Test_Defaults,
}

@(private="file")
TEST_NAMES :: [3]core.Name_Info{
    {type=Action,value=3,name="move",file="plugins/test/move.odin",line=3},
    {type=Action,value=4,name="jump",file="plugins/test/move.odin",line=4},
    {type=Action,value=40,name="hit",file="game/game.odin",line=7,project=true},
}

@(private="file")
test_info :: proc(t:^testing.T,$W:typeid,names:[]core.Name_Info) -> (info:core.World_Info,ok:bool) {
    @(static) actions:=[1]core.Actions_Info{{type=Test_Action,base=3,library="test"}}
    actions[0].info=type_info_of(Test_Action)
    info=core.test_info(t,W,defaults_types) or_return
    info.names,info.actions=names,actions[:]
    return info,true
}

// The defaults the code gives its actions are in the map without a step that
// declares them; input.mirai replaces those of the actions it names.
@(test)
the_defaults_of_the_code_need_no_step :: proc(t:^testing.T) {
    names:=TEST_NAMES
    info,made:=test_info(t,Defaults_World,names[:])
    if !made {return}
    defer core.test_info_destroy(&info)
    problems:core.Problems
    m:Input_Map
    input_map_make(&m,&info,"input.mirai",`{"actions":[{"name":"hit","kind":"Button","bindings":[{"mouse_button":"Left"}]},{"name":"jump","kind":"Button","bindings":[{"key":"J"}]}]}`,&problems)
    testing.expect(t,m.built && input_map_has(&m,MOVE,.Axis2) && input_map_has(&m,JUMP,.Button) && input_map_has(&m,HIT,.Button))
    testing.expect_value(t,m.binding_count,u32(4))
    testing.expect_value(t,problems.count,0)

    device:=core.Input{keys_down={.W,.J,.Space},keys_pressed={.W,.J,.Space},mouse_down={.Left},mouse_pressed={.Left}}
    actions:Actions
    actions_update(&actions,&m,&device)
    testing.expect(t,action(&actions,MOVE).vector==[2]f32{0,1})
    testing.expect(t,action(&actions,JUMP).pressed,"input.mirai binds jump to J")
    testing.expect(t,action(&actions,HIT).pressed)
    testing.expect_value(t,actions.count,u32(41))

    device={keys_down={.Space},keys_pressed={.Space}}
    actions_update(&actions,&m,&device)
    testing.expect(t,!action(&actions,JUMP).down,"Space is no longer a binding of jump")
    testing.expect(t,action(&actions,HIT).released)
    testing.expect(t,action(&actions,Action(50))=={},"a value the map does not have is released")
}

@(private="file") Loose :: enum u8 {Fire}

@(private="file")
Loose_Defaults :: struct {defaults:[Loose]Action_Default}

@(private="file")
Loose_World :: struct {
    using world:core.Test_World,
    defaults:Test_Defaults,
    loose:Loose_Defaults,
}

// Defaults are given by member of an enum @(actions), which take the actions
// from its base on; those of an enum that is not one are a problem.
@(test)
defaults_are_given_by_member_of_an_enum_of_actions :: proc(t:^testing.T) {
    names:=TEST_NAMES
    info,made:=test_info(t,Loose_World,names[:])
    if !made {return}
    defer core.test_info_destroy(&info)
    problems:core.Problems
    m:Input_Map
    input_map_make(&m,&info,"","",&problems)
    testing.expect(t,input_map_has(&m,MOVE,.Axis2) && input_map_has(&m,JUMP,.Button),"the members take 3 and 4")
    testing.expect(t,m.declared&(action_bit(0)|action_bit(1)|action_bit(2))==0,"below the base nothing is declared")
    loose:=core.problem_find(&problems,core.NONE,"input.default_unknown")
    testing.expect(t,loose!=nil && strings.contains(core.problem_text(loose),"Loose_Defaults gives defaults to the members of Loose, which is not an enum @(actions)"))
}

// A step reads the actions of its enum by member, and the base of the enum
// makes them the actions of the world: of the tick and of the frame.
@(test)
typed_reads_take_the_actions_of_their_enum :: proc(t:^testing.T) {
    names:=TEST_NAMES
    info,made:=test_info(t,Defaults_World,names[:])
    if !made {return}
    defer core.test_info_destroy(&info)
    m:Input_Map
    input_map_make(&m,&info,"","",nil)
    device:=core.Input{keys_down={.D,.Space},keys_pressed={.D,.Space}}
    tick:Actions
    actions_update(&tick,&m,&device)
    frame:Frame_Actions
    device={keys_down={.D}}
    actions_update(&frame.actions,&m,&device)

    input:=Input_Of(Test_Action){actions=core.ref(&tick),base=3}
    testing.expect_value(t,action_of(input,.Jump),JUMP)
    testing.expect(t,pressed(input,.Jump) && down(input,.Jump) && !released(input,.Jump))
    testing.expect_value(t,vector(input,.Move),[2]f32{1,0})
    shown:=Frame_Input_Of(Test_Action){actions=core.ref(&frame),base=3}
    testing.expect(t,!down(shown,.Jump) && vector(shown,.Move)=={1,0},"the frame has its own")
    testing.expect_value(t,action_of(shown,.Move),MOVE)
}

// A frame without a tick (a paused clock) runs the input phase and not fixed:
// Input_Of keeps what the last tick left, its edge repeated and a new press
// unseen, and only Frame_Input_Of follows the frame. The generator refuses
// Input_Of and core.Input outside fixed in the game loop because of this.
@(test)
a_frame_without_a_tick_leaves_input_of_at_the_last_tick :: proc(t:^testing.T) {
    names:=TEST_NAMES
    info,made:=test_info(t,Defaults_World,names[:])
    if !made {return}
    defer core.test_info_destroy(&info)
    m:Input_Map
    input_map_make(&m,&info,"","",nil)
    state:Seats
    seats:core.Table(Seat)
    tick:Actions
    frame:Frame_Actions
    ticked:=Input_Of(Test_Action){actions=core.ref(&tick),base=3}
    shown:=Frame_Input_Of(Test_Action){actions=core.ref(&frame),base=3}

    pressed_space:=core.Input{keys_down={.Space},keys_pressed={.Space}}
    input_actions_update(&m,&tick,pressed_space,core.ref(&state),core.read(&seats))
    input_frame_actions_update(core.ref(&m),&frame,core.Frame_Input{input=pressed_space},core.ref(&state),core.read(&seats))
    testing.expect(t,pressed(ticked,.Jump) && pressed(shown,.Jump))

    input_frame_actions_update(core.ref(&m),&frame,core.Frame_Input{},core.ref(&state),core.read(&seats))
    testing.expect(t,pressed(ticked,.Jump) && down(ticked,.Jump),"the edge of the last tick is still there")
    testing.expect(t,released(shown,.Jump) && !down(shown,.Jump),"the frame saw the key go up")

    held_d:=core.Input{keys_down={.D},keys_pressed={.D}}
    input_frame_actions_update(core.ref(&m),&frame,core.Frame_Input{input=held_d},core.ref(&state),core.read(&seats))
    testing.expect_value(t,vector(ticked,.Move),[2]f32{0,0})
    testing.expect_value(t,vector(shown,.Move),[2]f32{1,0})
}

// A name in input.mirai that the code does not declare is a problem that
// says which, in which file and how to fix it; the file is not read and the
// defaults stay. An action with neither a default nor an entry is one too.
@(test)
what_the_code_does_not_declare_is_a_problem :: proc(t:^testing.T) {
    names:=TEST_NAMES
    info,made:=test_info(t,Defaults_World,names[:])
    if !made {return}
    defer core.test_info_destroy(&info)
    problems:core.Problems
    m:Input_Map
    input_map_make(&m,&info,"demo/input.mirai",`{"actions":[{"name":"jump","kind":"Button","bindings":[{"key":"J"}]},{"name":"fire","kind":"Button","bindings":[{"key":"F"}]}]}`,&problems)
    unknown:=core.problem_find(&problems,core.NONE,"input.unknown_action")
    if testing.expect(t,unknown!=nil) {
        text:=core.problem_text(unknown)
        for want in ([]string{`demo/input.mirai names the action "fire"`,"move, jump, hit","a member Fire of the enum @(actions)"}) {
            testing.expectf(t,strings.contains(text,want),"%q is not in %q",want,text)
        }
    }
    testing.expect(t,input_map_has(&m,JUMP,.Button) && m.bindings[m.binding_count-1].codes[0]=={.Key,u8(core.Key.Space)},"the file was not read")
    unbound:=core.problem_find(&problems,core.NONE,"input.action_unbound")
    testing.expect(t,unbound!=nil && strings.contains(core.problem_text(unbound),`"hit" (game/game.odin:7)`))
    testing.expect(t,input_map_has(&m,HIT,.Button),"an action without bindings is still read, released")

    problems={}
    error,at:=input_map_parse(&m,&info,`{"actions":[{"name":"jump","kind":"Trigger"}]}`)
    testing.expect(t,error==.Unknown_Kind && at=="jump")
}

// What the player rebinds goes to its options as the actions that differ from
// the code and the project, and read over them gives the same map; an action
// the game no longer declares is left out of them, and the rest holds.
@(test)
the_bindings_the_player_changed_come_back_over_those_of_the_project :: proc(t:^testing.T) {
    names:=TEST_NAMES
    info,made:=test_info(t,Defaults_World,names[:])
    if !made {return}
    defer core.test_info_destroy(&info)
    problems:core.Problems
    PROJECT :: `{"actions":[{"name":"hit","kind":"Button","bindings":[{"mouse_button":"Left"}]}]}`
    below,m:Input_Map
    input_map_make(&below,&info,"input.mirai",PROJECT,&problems)
    m=below
    text,ok:=input_map_text(&m,&below,&info)
    testing.expect(t,ok && text=="","an untouched map writes nothing")

    input_map_unbind(&m,JUMP)
    testing.expect(t,input_map_bind(&m,JUMP,binding_key(.J)) && input_map_bind(&m,JUMP,binding_gamepad_button(.South,1)))
    m.hold_ticks=40
    text,ok=input_map_text(&m,&below,&info)
    testing.expect(t,ok && strings.contains(text,`"jump"`) && !strings.contains(text,`"move"`) && !strings.contains(text,`"hit"`),text)

    again:Input_Map
    input_map_make(&again,&info,"input.mirai",PROJECT,&problems,"options/input.mirai",text)
    testing.expect_value(t,problems.count,0)
    testing.expect_value(t,again.hold_ticks,u32(40))
    actions:Actions
    device:=core.Input{keys_down={.J},keys_pressed={.J}}
    actions_update(&actions,&again,&device)
    testing.expect(t,action(&actions,JUMP).pressed,"the options bind jump to J")
    device={keys_down={.Space},keys_pressed={.Space}}
    actions_update(&actions,&again,&device)
    testing.expect(t,!action(&actions,JUMP).down,"Space is the binding of the project, which the options replaced")
    same:=again
    unchanged,_:=input_map_text(&same,&again,&info)
    testing.expect_value(t,unchanged,"")

    // An update of the game renamed or removed an action the player had bound.
    stale,_:=strings.replace(text,`"actions": [`,`"actions": [{"name": "gone", "kind": "Button", "bindings": [{"key": "G"}]},`,1,context.temp_allocator)
    kept:Input_Map
    problems={}
    input_map_make(&kept,&info,"input.mirai",PROJECT,&problems,"options/input.mirai",stale)
    testing.expect(t,problems.count==1 && strings.has_prefix(string(problems.entries[0].code[:]),"input.options_gone"),string(problems.entries[0].text[:]))
    testing.expect_value(t,kept.hold_ticks,u32(40))
    actions_update(&actions,&kept,&core.Input{keys_down={.J},keys_pressed={.J}})
    testing.expect(t,action(&actions,JUMP).pressed,"the rest of the options holds")
    rewritten,_:=input_map_text(&kept,&below,&info)
    testing.expect(t,!strings.contains(rewritten,`"gone"`),"writing the options again drops it")
}
