package editor

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// An enum @(actions) at the base 0, and an action of the game at 40.
@(private="file") Input_Test_Action :: enum u8 {Move,Jump}
@(private="file") MOVE :: input.Action(0)
@(private="file") JUMP :: input.Action(1)
@(private="file") HIT :: input.Action(40)

@(private="file") Input_World :: struct {using world:core.Test_World,settings:input.Input_Settings,bindings:input.Input_Map}
@(private="file") Input_Editor :: struct {api:Api}

// The defaults of Input_Test_Action, as the generator finds them beside the enum.
@(private="file")
input_test_actions :: proc() -> []core.Actions_Info {
    defaults :: proc(dst:rawptr) {
        (cast(^[Input_Test_Action]input.Action_Bindings)dst)^={
            .Move=input.action_default(.Axis2,input.binding_keys(.A,.D,.S,.W),input.binding_gamepad_stick(.Left)),
            .Jump=input.action_default(.Button,input.binding_key(.Space)),
        }
    }
    @(static) actions:[1]core.Actions_Info
    actions[0]={type=Input_Test_Action,info=type_info_of(Input_Test_Action),defaults=defaults}
    return actions[:]
}

@(private="file")
Input_Fixture :: struct {
    folder:string,
    world:Input_World,
    names:[3]core.Name_Info,
    info:core.World_Info,
    selection:history.Selection,
    viewport:Viewport,
    gui:Editor_Ui,
    edits:history.Edits,
    inspector:Inspector,
    editor:Input_Editor,
    app:host.App,
    session:Session,
    out:serial.Writer,
}

// A project whose code declares move and jump with defaults and hit without,
// and an editor with input.get and settings.set.
@(private="file")
input_fixture :: proc(t:^testing.T,f:^Input_Fixture) -> bool {
    f.folder=base.test_folder(t,"input-settings")
    if f.folder=="" {return false}
    f.info=core.test_info(t,Input_World,core.Test_None,Input_Editor,test_types) or_return
    f.names={
        {type=input.Action,value=0,name="move",file="engine/input/input.odin",line=1},
        {type=input.Action,value=1,name="jump",file="engine/input/input.odin",line=2},
        {type=input.Action,value=40,name="hit",library="game",file="game/game.odin",line=3,project=true},
    }
    f.info.names,f.info.actions=f.names[:],input_test_actions()
    core.test_info_index(&f.info)
    if !testing.expect(t,core.world_init(&f.info,.World,&f.world,context.allocator)) {return false}
    f.app.info=&f.info
    f.session=Session{info=&f.info,edit_world=&f.world,editor_world=&f.editor,app=&f.app,selection=&f.selection,viewport=&f.viewport,gui=&f.gui,edits=&f.edits,inspector=&f.inspector,project_root=f.folder,has_project=true}
    history.edits_reset(&f.edits,edited_world(&f.session))
    api_opened,api_problem:=api_open(&f.session,0,true)
    if !testing.expectf(t,api_opened==.None,"%v: %s",api_opened,api_problem) {return false}
    state:=api_state(&f.session)
    state.poll_temp=context.temp_allocator
    if api.method_find(&state.server,"input.get")==nil {input_api_register(&f.session,state)}
    if api.method_find(&state.server,"settings.set")==nil {settings_api_register(&f.session,state)}
    input_settings_load(&f.session)
    serial.writer_init(&f.out)
    return true
}

@(private="file")
input_fixture_destroy :: proc(f:^Input_Fixture) {
    serial.writer_destroy(&f.out)
    api_close(&f.session)
    history.edits_free(&f.edits)
    delete(f.selection.entities)
    if f.info.sizes[.World]>0 {core.world_destroy(&f.info,.World,&f.world)}
    core.test_info_destroy(&f.info)
}

@(private="file")
input_call :: proc(f:^Input_Fixture,name,params:string) -> (text:string,error:api.Error) {
    state:=api_state(&f.session)
    base.arena_reset(&state.server.scratch)
    serial.writer_reset(&f.out)
    error,_=api.method_execute(&state.server,api.method_find(&state.server,name),params,&f.out)
    return strings.clone(string(serial.writer_bytes(&f.out)),context.temp_allocator),error
}

@(private="file")
input_file :: proc(f:^Input_Fixture) -> string {
    data,_:=os.read_entire_file(project.path(f.folder,project.SETTINGS_FILE,allocator=context.temp_allocator),context.temp_allocator)
    return string(data)
}

// settings.set gives an action its bindings in Input_Settings, whose file
// keeps only the actions that differ from the code; input.get gives back
// every action as an entry of the setting writes it and which ones the project
// changes. A binding the kind of its action does not take, an input or an
// action that does not exist, are refused with what to give, and the file
// stays as it was.
@(test)
the_bindings_are_set_as_settings_and_refused_with_the_fix :: proc(t:^testing.T) {
    f:=new(Input_Fixture,context.temp_allocator)
    if !input_fixture(t,f) {return}
    defer input_fixture_destroy(f)

    text,error:=input_call(f,"input.get","{}")
    testing.expect_value(t,error.code,0)
    for want in ([]string{`"tap_seconds": 0.2`,`"hold_seconds": 0.5`,`"action": "move"`,`["A", "D", "S", "W"]`,`["Left_X", "Left_Y"]`,`"changed": []`}) {
        testing.expectf(t,strings.contains(text,want),"%q is not in %s",want,text)
    }

    _,error=input_call(f,"settings.set",`{"settings":{"Input_Settings":{"actions":[{"action":"jump","kind":"Button","bindings":[{"inputs":["J"]},{"inputs":["South"],"gamepad":2}]}]}}}`)
    testing.expect_value(t,error.code,0)
    file:=input_file(f)
    testing.expect(t,strings.contains(file,`"jump"`) && strings.contains(file,`["South"]`) && !strings.contains(file,`"move"`),file)
    text,_=input_call(f,"input.get",`{"actions":["jump"]}`)
    testing.expect(t,strings.contains(text,`["J"]`) && strings.contains(text,`"changed": ["jump"]`) && !strings.contains(text,`"move"`),text)

    cases:=[]struct{params:string,wants:[]string}{
        {`{"action":"jump","kind":"Button","bindings":[{"inputs":["A","D"]}]}`,{`"jump"`,"a Button reads one input"}},
        {`{"action":"move","kind":"Axis2","bindings":[{"inputs":["South"]}]}`,{`"move"`,"an Axis2 reads four keys"}},
        {`{"action":"jump","kind":"Button","bindings":[{"inputs":["S"],"chord":["Mouse_X"]}]}`,{"a chord holds one or two keys"}},
        {`{"action":"jump","kind":"Button","bindings":[{"inputs":["Spce"]}]}`,{`"Spce"`,"Space"}},
        {`{"action":"fire","kind":"Button","bindings":[{"inputs":["F"]}]}`,{`"fire"`,"move, jump, hit","a member Fire"}},
    }
    for c in cases {
        _,error=input_call(f,"settings.set",strings.concatenate({`{"settings":{"Input_Settings":{"actions":[`,c.params,`]}}}`},context.temp_allocator))
        testing.expectf(t,error.code==api.INVALID_PARAMS,"%s: %v",c.params,error)
        for want in c.wants {testing.expectf(t,strings.contains(error.message,want),"%s: %q is not in %q",c.params,want,error.message)}
        testing.expect_value(t,input_file(f),file)
    }
}

// The menus of a binding offer only what the kind of the action takes, every
// key and button for a Button; a choice adds its binding to Input_Settings in
// one step, or takes the place of a binding with its options.
@(test)
a_binding_chosen_from_the_menus_is_written :: proc(t:^testing.T) {
    for kind in input.Action_Kind {
        keys:core.Keys
        pads:bit_set[core.Gamepad_Button;u32]
        for choice in input_choices(kind) {
            testing.expectf(t,input.binding_suits(kind,choice.binding),"%v offers %q, which it does not take",kind,choice.name)
            testing.expectf(t,input_code_menu(choice.binding.inputs[0])==choice.menu,"%q is in the %v menu",choice.name,choice.menu)
            #partial switch device,index:=input.code_device(choice.binding.inputs[0]);device {
            case .Key:            keys+={core.Key(index)}
            case .Gamepad_Button: pads+={core.Gamepad_Button(index)}
            }
        }
        if kind!=.Button {continue}
        for k in core.Key {testing.expectf(t,k in keys,"a Button lists the key %v",k)}
        for b in core.Gamepad_Button {testing.expectf(t,b in pads,"a Button lists the gamepad button %v",b)}
    }

    f:=new(Input_Fixture,context.temp_allocator)
    if !input_fixture(t,f) {return}
    defer input_fixture_destroy(f)
    s:=&f.session
    hit:=input_driven(s,HIT)
    hit.kind=.Axis
    input_drive(s,HIT,hit)
    move:=input_driven(s,MOVE)
    move.bindings[1].dead_zone=0.4
    input_drive(s,MOVE,move)
    cases:=[]struct{action:input.Action,nth:int,menu:Input_Menu,name,want,gone:string}{
        {JUMP,-1,.Gamepad,"South",`["South"]`,""},
        {JUMP,-1,.Keyboard,"Escape",`["Escape"]`,""},
        {HIT,-1,.Gamepad,"Right trigger",`["Right_Trigger"]`,""},
        {HIT,-1,.Keyboard,"Q / E",`["Q", "E"]`,""},
        {MOVE,-1,.Mouse,"Move",`["Mouse_X", "Mouse_Y"]`,""},
        {MOVE,0,.Keyboard,"Arrow keys",`["Left", "Right", "Down", "Up"]`,`["A", "D", "S", "W"]`},
        {MOVE,1,.Gamepad,"Right stick",`"dead_zone": 0.4`,`["Left_X", "Left_Y"]`},
    }
    for c in cases {
        found:=false
        for choice in input_choices(input_driven(s,c.action).kind) {
            if choice.menu!=c.menu || choice.name!=c.name {continue}
            found=true
            input_binding_choose(s,c.action,c.nth,choice.binding)
        }
        testing.expectf(t,found,"the %v menu offers %q",c.menu,c.name)
        file:=input_file(f)
        testing.expectf(t,strings.contains(file,c.want),"%q is not in %s",c.want,file)
        if c.gone!="" {testing.expectf(t,!strings.contains(file,c.gone),"%q is still in %s",c.gone,file)}
    }
    testing.expect(t,strings.contains(input_file(f),`["Right_X", "Right_Y"]`))
    input_drive(s,MOVE,f.session.settings_dialog.input.code.actions[MOVE])
    testing.expect(t,input.input_settings_find(&f.world.settings,"move")==nil,"back to the code, the entry goes")
}

// A binding that listens takes the keys one after the other for an axis, a
// stick for an Axis2 and a button for a Button; a key of a binding of keys
// takes another key alone.
@(test)
a_listening_binding_takes_what_is_pressed :: proc(t:^testing.T) {
    l:Input_Listen
    l={active=true,whole=true,action=MOVE,binding=-1}
    for k in ([]input.Input_Code{.J,.L,.K}) {
        _,found:=input_listen_take(&l,.Axis2,{},k,.None,false,false,false,false)
        testing.expect(t,!found,"an Axis2 waits for four keys")
    }
    binding,found:=input_listen_take(&l,.Axis2,{},.I,.None,false,false,false,false)
    testing.expect(t,found && binding.inputs==[4]input.Input_Code{.J,.L,.K,.I})
    testing.expect(t,input.binding_suits(.Axis2,binding))

    l={active=true,whole=true,action=MOVE,binding=-1}
    binding,found=input_listen_take(&l,.Axis2,{},.None,.Right_Y,false,false,false,false)
    testing.expect(t,found && binding.inputs==input.binding_gamepad_stick(.Right).inputs && binding.gamepad==0)
    l={active=true,whole=true,action=MOVE,binding=-1}
    binding,found=input_listen_take(&l,.Axis2,{},.None,.None,true,true,false,false)
    testing.expect(t,found && binding.inputs==input.binding_mouse_delta().inputs)

    l={active=true,whole=false,action=MOVE,binding=0,slot=3}
    binding,found=input_listen_take(&l,.Axis2,input.binding_keys(.A,.D,.S,.W),.Up,.None,false,false,false,false)
    testing.expect(t,found && binding==input.binding_keys(.A,.D,.S,.Up),"the fourth key alone changes")

    l={active=true,whole=true,action=JUMP,binding=0}
    binding,found=input_listen_take(&l,.Button,input.binding_key(.Space),.South,.None,false,false,false,false)
    testing.expect(t,found && binding==input.binding_gamepad_button(.South))
    _,found=input_listen_take(&l,.Button,input.binding_key(.Space),.None,.None,true,true,false,false)
    testing.expect(t,!found,"moving the mouse does not press a Button")
}
