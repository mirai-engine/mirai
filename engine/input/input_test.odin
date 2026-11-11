package input

import "core:mem"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"

// An enum @(actions) whose base the generator made 3, and an action of the game at 40.
@(private="file") Test_Action :: enum u8 {Move,Jump}
@(private="file") MOVE :: Action(3)
@(private="file") JUMP :: Action(4)
@(private="file") HIT :: Action(40)

// The defaults of Test_Action, as the generator finds them beside the enum.
@(private="file")
test_action_defaults :: proc(dst:rawptr) {
    (cast(^[Test_Action]Action_Bindings)dst)^={
        .Move=action_default(.Axis2,binding_keys(.A,.D,.S,.W),binding_gamepad_stick(.Left)),
        .Jump=action_default(.Button,binding_key(.Space)),
    }
}

@(private)
@(test_world)
Defaults_World :: struct {
    using world:Test_World,
}

@(private="file")
TEST_NAMES :: [3]core.Name_Info{
    {type=Action,value=3,name="move",file="plugins/test/move.odin",line=3},
    {type=Action,value=4,name="jump",file="plugins/test/move.odin",line=4},
    {type=Action,value=40,name="hit",file="game/game.odin",line=7,project=true},
}

@(private="file")
named_info :: proc(t:^testing.T,$W:typeid,names:[]core.Name_Info,defaults:proc(dst:rawptr)=test_action_defaults) -> (info:core.World_Info,ok:bool) {
    @(static) actions:=[1]core.Actions_Info{{type=Test_Action,base=3,library="test"}}
    actions[0].info,actions[0].defaults=type_info_of(Test_Action),defaults
    info=test_info(t,W) or_return
    info.names,info.actions=names,actions[:]
    return info,true
}

// The defaults the code gives its actions are in the map without a step that
// declares them; Input_Settings replaces those of the actions it names, and
// the step builds the map again when the setting changes, and not otherwise.
@(test)
input_settings_replace_the_defaults_of_the_actions_they_name :: proc(t:^testing.T) {
    names:=TEST_NAMES
    info,made:=named_info(t,Defaults_World,names[:])
    if !made {return}
    defer test_info_destroy(&info)
    problems:core.Problems
    settings:Input_Settings
    testing.expect(t,input_settings_put(&settings,"hit",action_default(.Button,binding_mouse_button(.Left))))
    testing.expect(t,input_settings_put(&settings,"jump",action_default(.Button,binding_key(.J))))
    m:Input_Map
    input_map_make(&m,&info,&settings,&problems)
    testing.expect(t,m.built && input_map_has(&m,MOVE,.Axis2) && input_map_has(&m,JUMP,.Button) && input_map_has(&m,HIT,.Button))
    testing.expect_value(t,len(action_bindings(&m.actions[MOVE])),2)
    testing.expect_value(t,problems.count,0)

    device:=core.Input{keys_down={.W,.J,.Space},keys_pressed={.W,.J,.Space},mouse_down={.Left},mouse_pressed={.Left}}
    actions:Actions
    actions_update(&actions,&m,&device,1.0/60)
    testing.expect(t,action(&actions,MOVE).vector==[2]f32{0,1})
    testing.expect(t,action(&actions,JUMP).pressed,"the setting binds jump to J")
    testing.expect(t,action(&actions,HIT).pressed)
    testing.expect_value(t,actions.count,u32(41))

    device={keys_down={.Space},keys_pressed={.Space}}
    actions_update(&actions,&m,&device,1.0/60)
    testing.expect(t,!action(&actions,JUMP).down,"Space is no longer a binding of jump")
    testing.expect(t,action(&actions,HIT).released)
    testing.expect(t,action(&actions,Action(50))=={},"a value the map does not have is released")

    // A frame that wrote nothing builds nothing; a write of the setting moves its revision.
    app:host.App
    app.info=&info
    built:Input_Map
    revision:=u64(1)
    written:=core.Stamp(Input_Settings){&revision}
    input_map_build(&built,core.ref(&settings),written,&app,nil)
    testing.expect(t,built.built && input_map_has(&built,HIT,.Button))
    built.actions[JUMP]={}
    input_settings_remove(&settings,"jump")
    for _ in 0..<3 {input_map_build(&built,core.ref(&settings),written,&app,nil)}
    testing.expect_value(t,built.actions[JUMP],Action_Bindings{})
    revision+=1
    input_map_build(&built,core.ref(&settings),written,&app,nil)
    testing.expect_value(t,built.actions[JUMP].bindings[0].inputs[0],Input_Code.Space)
}

// The names of the inputs are the names of the members of their enums.
@(test)
input_codes_are_named_as_their_enums :: proc(t:^testing.T) {
    for key in core.Key {testing.expect_value(t,reflect.enum_string(code_key(key)),reflect.enum_string(key))}
    for button in core.Mouse_Button {testing.expect_value(t,reflect.enum_string(code_mouse_button(button)),strings.concatenate({"Mouse_",reflect.enum_string(button)},context.temp_allocator))}
    for button in core.Gamepad_Button {testing.expect_value(t,reflect.enum_string(code_gamepad_button(button)),reflect.enum_string(button))}
    for axis in core.Gamepad_Axis {testing.expect_value(t,reflect.enum_string(code_gamepad_axis(axis)),reflect.enum_string(axis))}
    for axis in Mouse_Axis {
        device,index:=code_device(code_mouse_axis(axis))
        testing.expect(t,device==.Mouse_Axis && index==u8(axis))
    }
    device,_:=code_device(Input_Code(250))
    testing.expect_value(t,device,Input_Device.None)
}

// Defaults are given by member of an enum @(actions), which take the actions
// from its base on; the members of an enum without defaults are unbound.
@(test)
defaults_are_given_by_member_of_an_enum_of_actions :: proc(t:^testing.T) {
    names:=TEST_NAMES
    cases:=[]struct{defaults:proc(dst:rawptr),bound:bool}{{test_action_defaults,true},{nil,false}}
    for c in cases {
        info,made:=named_info(t,Defaults_World,names[:],c.defaults)
        if !made {return}
        defer test_info_destroy(&info)
        problems:core.Problems
        m:Input_Map
        input_map_make(&m,&info,nil,&problems)
        testing.expect_value(t,input_map_has(&m,MOVE,.Axis2) && input_map_has(&m,JUMP,.Button),c.bound)
        testing.expect(t,m.declared&(action_bit(0)|action_bit(1)|action_bit(2))==0,"below the base nothing is declared")
        unbound:=core.problem_find(&problems,core.NONE,"input.action_unbound")
        testing.expect_value(t,unbound!=nil && strings.contains(core.problem_text(unbound),`"move"`),!c.bound)
    }
}

// A step reads the actions of its enum by member, and the base of the enum
// makes them the actions of the world: of the focused seat for the tick, of
// its slot for the frame. A block of that seat takes them from both.
@(test)
typed_reads_take_the_actions_of_their_enum :: proc(t:^testing.T) {
    names:=TEST_NAMES
    info,made:=named_info(t,Defaults_World,names[:])
    if !made {return}
    defer test_info_destroy(&info)
    w:Test_Seats
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    seat:=core.create(&w.entities)
    core.add(&w.seats,seat,Seat{})
    test_world_settle(&w)
    m:Input_Map
    input_map_make(&m,&info,nil,nil)
    device:=core.Input{keys_down={.D,.Space},keys_pressed={.D,.Space}}
    actions_update(&core.edit(&w.seats,seat).actions,&m,&device,1.0/60)
    state:=Seats{local_count=1}
    frame:Frame_Actions
    device={keys_down={.D}}
    actions_update(&frame.slots[0],&m,&device,1.0/60)

    input:=Input_Of(Test_Action){state=core.ref(&state),seats=core.read(&w.seats),base=3}
    testing.expect_value(t,action_of(input,.Jump),JUMP)
    testing.expect(t,pressed(input,.Jump) && down(input,.Jump) && !released(input,.Jump))
    testing.expect_value(t,vector(input,.Move),[2]f32{1,0})
    shown:=Frame_Input_Of(Test_Action){actions=core.ref(&frame),state=core.ref(&state),seats=core.read(&w.seats),base=3}
    testing.expect(t,!down(shown,.Jump) && vector(shown,.Move)=={1,0},"the frame has its own")
    testing.expect_value(t,action_of(shown,.Move),MOVE)

    core.edit(&w.seats,seat).blocked=ALL_ACTIONS
    testing.expect(t,!pressed(input,.Jump) && vector(shown,.Move)=={},"a menu that blocks the seat blocks what the machine reads")
}

// A frame without a tick (a paused clock) runs the input phase and not fixed:
// Input_Of keeps what the last tick left, its edge repeated and a new press
// unseen, and only Frame_Input_Of follows the frame. The generator refuses
// Input_Of and core.Input outside fixed in the game loop because of this.
@(test)
a_frame_without_a_tick_leaves_input_of_at_the_last_tick :: proc(t:^testing.T) {
    names:=TEST_NAMES
    info,made:=named_info(t,Defaults_World,names[:])
    if !made {return}
    defer test_info_destroy(&info)
    w:Test_Seats
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    seat:=core.create(&w.entities)
    core.add(&w.seats,seat,Seat{})
    test_world_settle(&w)
    m:Input_Map
    input_map_make(&m,&info,nil,nil)
    state:=Seats{local_count=1}
    frame:Frame_Actions
    ticked:=Input_Of(Test_Action){state=core.ref(&state),seats=core.read(&w.seats),base=3}
    shown:=Frame_Input_Of(Test_Action){actions=core.ref(&frame),state=core.ref(&state),seats=core.read(&w.seats),base=3}

    pressed_space:=core.Input{keys_down={.Space},keys_pressed={.Space}}
    seat_feed(core.edit(&w.seats,seat),&pressed_space,&m,false,1.0/60)
    input_frame_actions_update(core.ref(&m),&frame,core.Frame_Input{input=pressed_space},core.ref(&state),core.read(&w.seats),{dt=1.0/60})
    testing.expect(t,pressed(ticked,.Jump) && pressed(shown,.Jump))

    input_frame_actions_update(core.ref(&m),&frame,core.Frame_Input{},core.ref(&state),core.read(&w.seats),{dt=1.0/60})
    testing.expect(t,pressed(ticked,.Jump) && down(ticked,.Jump),"the edge of the last tick is still there")
    testing.expect(t,released(shown,.Jump) && !down(shown,.Jump),"the frame saw the key go up")

    held_d:=core.Input{keys_down={.D},keys_pressed={.D}}
    input_frame_actions_update(core.ref(&m),&frame,core.Frame_Input{input=held_d},core.ref(&state),core.read(&w.seats),{dt=1.0/60})
    testing.expect_value(t,vector(ticked,.Move),[2]f32{0,0})
    testing.expect_value(t,vector(shown,.Move),[2]f32{1,0})
}

// An entry of Input_Settings the code does not take is a problem that names
// the action and how to fix it, and the action keeps its default; the others
// hold. Bytes of any value in the setting build a map, with no crash.
@(test)
what_the_code_does_not_take_is_a_problem :: proc(t:^testing.T) {
    names:=TEST_NAMES
    info,made:=named_info(t,Defaults_World,names[:])
    if !made {return}
    defer test_info_destroy(&info)
    problems:core.Problems
    settings:Input_Settings
    input_settings_put(&settings,"jump",action_default(.Button,binding_key(.J)))
    input_settings_put(&settings,"fire",action_default(.Button,binding_key(.F)))
    m:Input_Map
    input_map_make(&m,&info,&settings,&problems)
    unknown:=core.problem_find(&problems,core.NONE,"input.settings")
    if testing.expect(t,unknown!=nil) {
        text:=core.problem_text(unknown)
        for want in ([]string{`binds the action "fire"`,"move, jump, hit","a member Fire of an enum @(actions)"}) {
            testing.expectf(t,strings.contains(text,want),"%q is not in %q",want,text)
        }
    }
    testing.expect(t,m.actions[JUMP].bindings[0].inputs[0]==.J,"the rest of the setting holds")
    unbound:=core.problem_find(&problems,core.NONE,"input.action_unbound")
    testing.expect(t,unbound!=nil && strings.contains(core.problem_text(unbound),`"hit" (game/game.odin:7)`))
    testing.expect(t,input_map_has(&m,HIT,.Button),"an action without bindings is still read, released")

    hole:=action_default(.Button,binding_key(.J))
    hole.bindings[2]=binding_key(.K)
    nan:=binding_key(.J)
    nan.scale=transmute(f32)u32(0x7fc00000)
    cases:=[]struct{driven:Action_Bindings,wants:[]string}{
        {{kind=Action_Kind(7),bindings={0=binding_key(.J)}},{"the kind 7","Button, Axis or Axis2"}},
        {{kind=.Button,input_context=Input_Context(40),bindings={0=binding_key(.J)}},{"input context 40","leave it out"}},
        {action_default(.Button,binding_keys(.A,.D,.S,.W)),{"binding 0","a Button reads one input"}},
        {action_default(.Axis2,binding_gamepad_button(.South)),{"an Axis2 reads four keys"}},
        {action_default(.Button,binding_chord(binding_key(.S),.Mouse_X)),{"a chord holds one or two keys"}},
        {action_default(.Button,binding_gamepad_button(.South,9)),{"gamepad is 0 for every gamepad"}},
        {action_default(.Button,nan),{"scale is finite"}},
        {action_default(.Button,{inputs={0=Input_Code(250)}}),{"binding 0"}},
        {hole,{"binding 2","comes after one that reads no input"}},
    }
    for c in cases {
        settings={}
        input_settings_put(&settings,"jump",c.driven)
        problem:=input_settings_problem(&info,&settings)
        for want in c.wants {testing.expectf(t,strings.contains(problem,want) && strings.contains(problem,`"jump"`),"%q is not in %q",want,problem)}
        problems={}
        input_map_make(&m,&info,&settings,&problems)
        testing.expect(t,core.problem_find(&problems,core.NONE,"input.settings")!=nil && m.actions[JUMP].bindings[0].inputs[0]==.Space,"the action keeps its default")
    }
    settings={tap_seconds=-1}
    testing.expect(t,strings.contains(input_settings_problem(&info,&settings),"tap_seconds"))
    testing.expect(t,!input_map_bind(&m,JUMP,binding_chord(binding_key(.S),.Mouse_X)),"an axis is no chord")

    bytes:=mem.ptr_to_bytes(&settings)
    seed:=u64(0x9e3779b97f4a7c15)
    for _ in 0..<64 {
        for &b in bytes {
            seed=seed*6364136223846793005+1442695040888963407
            b=u8(seed>>56)
        }
        base.text_set(settings.actions[0].action[:],"jump")
        testing.expect(t,input_settings_problem(&info,&settings)!="")
        input_map_make(&m,&info,&settings,nil)
        actions:Actions
        device:=core.Input{keys_down={.J}}
        actions_update(&actions,&m,&device,1.0/60)
    }
}

// The bindings a player changed are its own layer of Input_Settings: read over
// the project's they win, they are written with the other options and read
// back the next time the game starts; an action the game no longer declares is
// a problem, and the rest holds.
@(test)
the_bindings_the_player_changed_come_back_over_those_of_the_project :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"input-player")
    if folder=="" {return}
    defer base.remove_all(folder)
    root,player:=project.path(folder,"game",allocator=context.temp_allocator),project.path(folder,"player",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(root)==nil && os.make_directory_all(player)==nil)
    names:=TEST_NAMES
    info,made:=named_info(t,Defaults_World,names[:])
    if !made {return}
    defer test_info_destroy(&info)
    settings:Input_Settings
    list:=[]project.Setting{{name="Input_Settings",info=type_info_of(Input_Settings),value=&settings,machine=true}}

    input_settings_put(&settings,"hit",action_default(.Button,binding_mouse_button(.Left)))
    input_settings_put(&settings,"jump",action_default(.Button,binding_key(.K)))
    error,_:=project.settings_save(list,.Project,root,"")
    testing.expect_value(t,error.code,project.Error_Code.None)

    // The player binds jump again in the options of the game.
    input_settings_put(&settings,"jump",action_default(.Button,binding_key(.J),binding_gamepad_button(.South,2)))
    settings.hold_seconds=0.75
    error,_=project.settings_save(list,.Player,root,"",player)
    testing.expect_value(t,error.code,project.Error_Code.None)
    file:=project.settings_file(.Player,root,"",context.temp_allocator,player)
    data,_:=os.read_entire_file(file,context.temp_allocator)
    text:=string(data)
    testing.expectf(t,strings.contains(text,`"jump"`) && !strings.contains(text,`"hit"`),"the player keeps only what it changed: %s",text)

    // The game starts again.
    settings={}
    error,_=project.settings_load(list,root,"",{.Player,.Project},player)
    testing.expect_value(t,error.code,project.Error_Code.None)
    problems:core.Problems
    m:Input_Map
    input_map_make(&m,&info,&settings,&problems)
    testing.expect_value(t,problems.count,0)
    testing.expect_value(t,m.hold_seconds,f32(0.75))
    actions:Actions
    device:=core.Input{keys_down={.J},keys_pressed={.J},mouse_down={.Left},mouse_pressed={.Left}}
    actions_update(&actions,&m,&device,1.0/60)
    testing.expect(t,action(&actions,JUMP).pressed && action(&actions,HIT).pressed,"the player's jump over the project's hit")
    device={keys_down={.K},keys_pressed={.K}}
    actions_update(&actions,&m,&device,1.0/60)
    testing.expect(t,!action(&actions,JUMP).down,"K is the binding of the project, which the player replaced")

    // An update of the game renamed an action the player had bound.
    stale,_:=strings.replace(text,`"actions": [`,`"actions": [{"action": "gone", "kind": "Button", "bindings": [{"inputs": ["G"]}]},`,1,context.temp_allocator)
    testing.expect(t,os.write_entire_file(file,stale)==nil)
    settings={}
    error,_=project.settings_load(list,root,"",{.Player,.Project},player)
    testing.expect_value(t,error.code,project.Error_Code.None)
    input_map_make(&m,&info,&settings,&problems)
    gone:=core.problem_find(&problems,core.NONE,"input.settings")
    testing.expect(t,gone!=nil && strings.contains(core.problem_text(gone),`"gone"`))
    testing.expect(t,m.actions[JUMP].bindings[0].inputs[0]==.J,"the rest of what the player chose holds")
}

// A project with the file of bindings of before is told where they go.
@(test)
an_old_input_mirai_is_refused_with_where_its_bindings_go :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"input-old")
    if folder=="" {return}
    defer base.remove_all(folder)
    names:=TEST_NAMES
    info,made:=named_info(t,Defaults_World,names[:])
    if !made {return}
    defer test_info_destroy(&info)
    testing.expect(t,os.write_entire_file(project.path(folder,"input.mirai",allocator=context.temp_allocator),`{"actions":[]}`)==nil)
    app:host.App
    app.info,app.root=&info,folder
    settings:Input_Settings
    m:Input_Map
    problems:core.Problems
    input_map_build(&m,core.ref(&settings),{},&app,&problems)
    old:=core.problem_find(&problems,core.NONE,"input.old_file")
    testing.expect(t,old!=nil && strings.contains(core.problem_text(old),"Input_Settings of") && strings.contains(core.problem_text(old),project.SETTINGS_FILE))
}
