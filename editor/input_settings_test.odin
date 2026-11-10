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

@(private="file") Input_Defaults :: struct {defaults:[Input_Test_Action]input.Action_Default}
@(private="file") Input_World :: struct {using world:core.Test_World,bindings:input.Input_Map,defaults:Input_Defaults}
@(private="file") Input_Editor :: struct {api:Api}

@(private="file")
input_test_types :: proc(types:^[dynamic]core.Test_Type) {
    test_types(types)
    append(types,core.test_type(Input_Defaults,default=proc(dst:^Input_Defaults) {
        dst^={defaults={
            .Move=input.action_default(.Axis2,input.binding_keys(.A,.D,.S,.W),input.binding_gamepad_stick(.Left)),
            .Jump=input.action_default(.Button,input.binding_key(.Space)),
        }}
    }))
}

@(private="file")
input_test_actions :: proc() -> []core.Actions_Info {
    @(static) actions:[1]core.Actions_Info
    actions[0]={type=Input_Test_Action,info=type_info_of(Input_Test_Action)}
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
// and an editor with input.get and input.set.
@(private="file")
input_fixture :: proc(t:^testing.T,f:^Input_Fixture) -> bool {
    f.folder=base.test_folder(t,"input-settings")
    if f.folder=="" {return false}
    f.info=core.test_info(t,Input_World,core.Test_None,Input_Editor,input_test_types) or_return
    f.names={
        {type=input.Action,value=0,name="move",file="engine/input/input.odin",line=1},
        {type=input.Action,value=1,name="jump",file="engine/input/input.odin",line=2},
        {type=input.Action,value=40,name="hit",library="game",file="game/game.odin",line=3,project=true},
    }
    f.info.names,f.info.actions=f.names[:],input_test_actions()
    core.test_info_index(&f.info)
    if !testing.expect(t,f.info.init[.World](&f.world,context.allocator)) {return false}
    f.session=Session{info=&f.info,edit_world=&f.world,editor_world=&f.editor,app=&f.app,selection=&f.selection,viewport=&f.viewport,gui=&f.gui,edits=&f.edits,inspector=&f.inspector,project_root=f.folder,has_project=true}
    history.edits_reset(&f.edits,edited_world(&f.session))
    if !testing.expect(t,api_open(&f.session,0,true)==.None) {return false}
    state:=api_state(&f.session)
    state.poll_temp=context.temp_allocator
    if api.method_find(&state.server,"input.get")==nil {input_api_register(&f.session,state)}
    serial.writer_init(&f.out)
    return true
}

@(private="file")
input_fixture_destroy :: proc(f:^Input_Fixture) {
    serial.writer_destroy(&f.out)
    api_close(&f.session)
    history.edits_free(&f.edits)
    delete(f.selection.entities)
    if f.info.destroy[.World]!=nil {f.info.destroy[.World](&f.world)}
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
input_file :: proc(f:^Input_Fixture) -> (text:string,found:bool) {
    data,error:=os.read_entire_file(project.path(f.folder,project.INPUT_FILE,allocator=context.temp_allocator),context.temp_allocator)
    return string(data),error==nil
}

// input.set replaces the kind and the bindings of an action and the ticks;
// input.mirai keeps only what differs from the code, input.get gives back
// what was set and where it comes from, and reset takes the action out of
// the file, which goes away once nothing differs.
@(test)
input_set_writes_only_what_differs_and_reset_brings_back_the_code :: proc(t:^testing.T) {
    f:=new(Input_Fixture,context.temp_allocator)
    if !input_fixture(t,f) {return}
    defer input_fixture_destroy(f)

    text,error:=input_call(f,"input.get","{}")
    testing.expect_value(t,error.code,0)
    for want in ([]string{`"tap_ticks":12`,`"hold_ticks":30`,`"problem":""`,`{"name":"move","kind":"Axis2","source":"code","bindings":[{"keys": ["A", "D", "S", "W"]}, {"gamepad_stick": "Left"}]}`,`{"name":"hit","kind":"Button","source":"code","bindings":[]}`}) {
        testing.expectf(t,strings.contains(text,want),"%q is not in %s",want,text)
    }
    _,exists:=input_file(f)
    testing.expect(t,!exists)

    f.world.bindings.built=true
    text,error=input_call(f,"input.set",`{"action":"jump","bindings":[{"key":"J"},{"gamepad_button":"South","gamepad":1}]}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`{"name":"jump","kind":"Button","source":"file","bindings":[{"key": "J"}, {"gamepad_button": "South", "gamepad": 1}]}`),text)
    testing.expect(t,!f.world.bindings.built,"the edited World builds its map again from the file")
    file,_:=input_file(f)
    testing.expect(t,strings.contains(file,`"jump"`) && !strings.contains(file,`"move"`) && !strings.contains(file,`"hit"`),file)

    _,error=input_call(f,"input.set",`{"action":"hit","kind":"Axis","bindings":[{"keys":["Q","E"],"scale":2}]}`)
    testing.expect_value(t,error.code,0)
    _,error=input_call(f,"input.set",`{"tap_ticks":20,"hold_ticks":30}`)
    testing.expect_value(t,error.code,0)
    file,_=input_file(f)
    testing.expect(t,strings.contains(file,`"tap_ticks": 20`) && !strings.contains(file,`"hold_ticks"`) && strings.contains(file,`"hit"`) && strings.contains(file,`"jump"`),file)

    // What the file says is what the game builds.
    built:input.Input_Map
    problems:core.Problems
    input.input_map_make(&built,&f.info,"input.mirai",file,&problems)
    testing.expect_value(t,problems.count,0)
    testing.expect(t,input.input_map_has(&built,HIT,.Axis) && built.tap_ticks==20)
    actions:input.Actions
    device:=core.Input{keys_down={.E,.J},keys_pressed={.E,.J}}
    input.actions_update(&actions,&built,&device)
    testing.expect_value(t,input.action(&actions,HIT).value,f32(2))
    testing.expect(t,input.action(&actions,JUMP).pressed)

    text,error=input_call(f,"input.set",`{"action":"jump","reset":true}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`{"name":"jump","kind":"Button","source":"code","bindings":[{"key": "Space"}]}`),text)
    file,_=input_file(f)
    testing.expect(t,!strings.contains(file,`"jump"`) && strings.contains(file,`"hit"`),file)

    _,error=input_call(f,"input.set",`{"action":"hit","reset":true,"tap_ticks":12}`)
    testing.expect_value(t,error.code,0)
    _,exists=input_file(f)
    testing.expect(t,!exists,"nothing differs from the code: no file")

    // A binding the same as the code's, with its scale written out, is the code.
    _,error=input_call(f,"input.set",`{"action":"jump","bindings":[{"key":"Space","scale":1}]}`)
    testing.expect_value(t,error.code,0)
    _,exists=input_file(f)
    testing.expect(t,!exists)
}

// A call that fails says what failed and the names it takes, and leaves the file as it was.
@(test)
input_set_errors_name_what_is_valid :: proc(t:^testing.T) {
    f:=new(Input_Fixture,context.temp_allocator)
    if !input_fixture(t,f) {return}
    defer input_fixture_destroy(f)
    _,error:=input_call(f,"input.set",`{"action":"jump","kind":"button","bindings":[{"key":"left shift"}]}`)
    testing.expect_value(t,error.code,0)
    _,error=input_call(f,"input.set",`{"action":"jump","bindings":[{"key":"K"}]}`)
    testing.expect_value(t,error.code,0)
    before,_:=input_file(f)

    cases:=[]struct{params:string,wants:[]string}{
        {`{"action":"fire","bindings":[]}`,{`"fire" is not an input action`,"move, jump, hit",`names.create {"type": "Action", "name": "fire"} declares`}},
        {`{"action":"jump","bindings":[{"key":"Spce"}]}`,{`bindings[0].key: "Spce" is not a key; the nearest are Space`,"Space"}},
        {`{"action":"move","bindings":[{"keys":["A","D","S","Wx"]}]}`,{`"Wx" is not a key`}},
        {`{"action":"move","bindings":[{"keys":["A","D","S"]}]}`,{"has 3 keys","four (left, right, down, up)"}},
        {`{"action":"jump","bindings":[{"keys":["A","D"]}]}`,{`bindings[0] does not suit the Button action "jump"`,"a Button takes"}},
        {`{"action":"move","bindings":[{"gamepad_button":"South"}]}`,{"Axis2 action","gamepad_stick"}},
        {`{"action":"jump","bindings":[{"gamepad_stick":"Middle"}]}`,{`"Middle" is not a gamepad stick`}},
        {`{"action":"jump","kind":"Trigger","bindings":[]}`,{`kind "Trigger" is not one of its names`}},
        {`{"action":"jump","bindings":[{"scale":2}]}`,{"names no input","gamepad_button"}},
        {`{"action":"jump","bindings":[{"key":"J","gamepad":7}]}`,{"a gamepad is 0 to 3"}},
        {`{"action":"jump","kind":"Axis"}`,{"give the bindings"}},
        {`{"action":"jump","reset":true,"bindings":[]}`,{"leave out kind and bindings"}},
        {`{"tap_ticks":0}`,{"tap_ticks is a whole number of ticks from 1"}},
        {`{"bind":"jump"}`,{`"bind" is not a field`}},
        {`{}`,{"action is missing"}},
    }
    for c in cases {
        _,error=input_call(f,"input.set",c.params)
        testing.expectf(t,error.code==api.INVALID_PARAMS,"%s: %v",c.params,error)
        for want in c.wants {testing.expectf(t,strings.contains(error.message,want),"%s: %q is not in %q",c.params,want,error.message)}
        after,_:=input_file(f)
        testing.expect_value(t,after,before)
    }

    // A file the code does not agree with is not written over: get says why.
    broken:=`{"actions":[{"name":"fire","kind":"Button","bindings":[]}]}`
    testing.expect(t,os.write_entire_file(project.path(f.folder,project.INPUT_FILE,allocator=context.temp_allocator),broken)==nil)
    _,error=input_call(f,"input.set",`{"action":"jump","bindings":[]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expect(t,strings.contains(error.message,`names the action "fire"`) && strings.contains(error.message,"move, jump, hit"),error.message)
    text,get_error:=input_call(f,"input.get","{}")
    testing.expect_value(t,get_error.code,0)
    testing.expect(t,strings.contains(text,`names the action \"fire\"`),text)
    after,_:=input_file(f)
    testing.expect_value(t,after,broken)
}

// The menus of a binding offer only what the kind of the action takes, every
// key and button for a Button; a choice adds its binding to input.mirai in
// one step, or takes the place of a binding with its options.
@(test)
a_binding_chosen_from_the_menus_is_written :: proc(t:^testing.T) {
    for kind in input.Action_Kind {
        keys:core.Keys
        pads:bit_set[core.Gamepad_Button;u32]
        for choice in input_choices(kind) {
            testing.expectf(t,input.binding_suits(kind,choice.binding),"%v offers %q, which it does not take",kind,choice.name)
            testing.expectf(t,input_code_menu(choice.binding.codes[0])==choice.menu,"%q is in the %v menu",choice.name,choice.menu)
            code:=choice.binding.codes[0]
            if code.device==.Key {keys+={core.Key(code.code)}}
            if code.device==.Gamepad_Button {pads+={core.Gamepad_Button(code.code)}}
        }
        if kind!=.Button {continue}
        for k in core.Key {testing.expectf(t,k in keys,"a Button lists the key %v",k)}
        for b in core.Gamepad_Button {testing.expectf(t,b in pads,"a Button lists the gamepad button %v",b)}
    }

    f:=new(Input_Fixture,context.temp_allocator)
    if !input_fixture(t,f) {return}
    defer input_fixture_destroy(f)
    input_settings_load(&f.session)
    st:=&f.session.settings_dialog.input
    input.input_map_action(&st.current,HIT,.Axis)
    st.current.bindings[input_binding_index(&st.current,MOVE,1)].dead_zone=0.4
    cases:=[]struct{action:input.Action,nth:int,menu:Input_Menu,name,want,gone:string}{
        {JUMP,-1,.Gamepad,"South",`{"gamepad_button": "South"}`,""},
        {JUMP,-1,.Keyboard,"Escape",`{"key": "Escape"}`,""},
        {HIT,-1,.Gamepad,"Right trigger",`{"gamepad_axis": "Right_Trigger"}`,""},
        {HIT,-1,.Keyboard,"Q / E",`{"keys": ["Q", "E"]}`,""},
        {MOVE,-1,.Mouse,"Move",`{"mouse": "Delta"}`,""},
        {MOVE,0,.Keyboard,"Arrow keys",`{"keys": ["Left", "Right", "Down", "Up"]}`,`"A"`},
        {MOVE,1,.Gamepad,"Right stick",`{"gamepad_stick": "Right", "dead_zone": 0.4`,`"gamepad_stick": "Left"`},
    }
    for c in cases {
        found:=false
        for choice in input_choices(st.current.kinds[c.action]) {
            if choice.menu!=c.menu || choice.name!=c.name {continue}
            found=true
            input_binding_choose(&f.session,c.action,c.nth,choice.binding)
        }
        testing.expectf(t,found,"the %v menu offers %q",c.menu,c.name)
        file,_:=input_file(f)
        testing.expectf(t,strings.contains(file,c.want),"%q is not in %s",c.want,file)
        if c.gone!="" {testing.expectf(t,!strings.contains(file,c.gone),"%q is still in %s",c.gone,file)}
    }
}

// A binding that listens takes the keys one after the other for an axis, a
// stick for an Axis2 and a button for a Button; a code of a binding of keys
// takes another key alone.
@(test)
a_listening_binding_takes_what_is_pressed :: proc(t:^testing.T) {
    names:=[]core.Name_Info{{type=input.Action,value=0,name="move"},{type=input.Action,value=1,name="jump"}}
    info,made:=core.test_info(t,struct {using world:core.Test_World,defaults:Input_Defaults},input_test_types)
    if !made {return}
    defer core.test_info_destroy(&info)
    info.names,info.actions=names,input_test_actions()
    core.test_info_index(&info)
    st:=new(Input_Settings,context.temp_allocator)
    input.input_map_make(&st.code,&info,"","",nil)
    st.current=st.code
    key :: proc(k:core.Key) -> input.Input_Code {return {.Key,u8(k)}}

    st.listen={active=true,whole=true,action=MOVE,binding=-1}
    for k in ([]core.Key{.J,.L,.K}) {
        _,found:=input_listen_take(st,key(k),{},false,false,false,false)
        testing.expect(t,!found,"an Axis2 waits for four keys")
    }
    binding,found:=input_listen_take(st,key(.I),{},false,false,false,false)
    testing.expect(t,found && binding.count==4 && binding.codes[3]==key(.I) && binding.codes[0]==key(.J))
    testing.expect(t,input.binding_suits(.Axis2,binding))

    st.listen={active=true,whole=true,action=MOVE,binding=-1}
    binding,found=input_listen_take(st,{},{.Gamepad_Axis,u8(core.Gamepad_Axis.Right_Y)},false,false,false,false)
    testing.expect(t,found && binding.count==2 && binding.codes==input.binding_gamepad_stick(.Right).codes && binding.gamepad==input.GAMEPAD_ANY)
    st.listen={active=true,whole=true,action=MOVE,binding=-1}
    binding,found=input_listen_take(st,{},{},true,true,false,false)
    testing.expect(t,found && binding.count==2 && binding.codes==input.binding_mouse_delta().codes)

    st.listen={active=true,whole=false,action=MOVE,binding=0,slot=3}
    binding,found=input_listen_take(st,key(.Up),{},false,false,false,false)
    want:=input.binding_keys(.A,.D,.S,.Up)
    want.action=MOVE
    testing.expect(t,found && binding==want,"the fourth key alone changes")

    st.listen={active=true,whole=true,action=JUMP,binding=0}
    binding,found=input_listen_take(st,{.Gamepad_Button,u8(core.Gamepad_Button.South)},{},false,false,false,false)
    testing.expect(t,found && binding.count==1 && binding.codes[0]=={.Gamepad_Button,u8(core.Gamepad_Button.South)} && binding.gamepad==input.GAMEPAD_ANY)
    _,found=input_listen_take(st,{},{},true,true,false,false)
    testing.expect(t,!found,"moving the mouse does not press a Button")
}
