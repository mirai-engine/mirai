package input

import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:project"
import "mirai:std/serial"

@(private="file") MOVE :: Action(0)
@(private="file") JUMP :: Action(2)
@(private="file") CONFIRM :: Action(16)
@(private="file") SAVE :: Action(17)
@(private="file") MENU :: Input_Context(1)
@(private="file") MAP :: Input_Context(2)

// Jump on Space and on South of the first gamepad, move on WASD; the menu
// confirms on Space and on South of every gamepad.
@(private="file")
menu_bindings :: proc() -> (m:Input_Map) {
    input_map_action(&m,MOVE,.Axis2)
    input_map_bind(&m,MOVE,binding_keys(.A,.D,.S,.W))
    input_map_action(&m,JUMP,.Button)
    input_map_bind(&m,JUMP,binding_key(.Space))
    input_map_bind(&m,JUMP,binding_gamepad_button(.South,1))
    input_map_action(&m,CONFIRM,.Button)
    input_map_bind(&m,CONFIRM,binding_key(.Space))
    input_map_bind(&m,CONFIRM,binding_gamepad_button(.South))
    m.actions[CONFIRM].input_context=MENU
    return
}

// An action of the always context reads under a modal context, and a context
// that reads its input still takes it.
@(test)
the_always_context_reads_under_a_modal_one :: proc(t:^testing.T) {
    PAUSE :: Action(18)
    m:=menu_bindings()
    input_map_action(&m,PAUSE,.Button)
    input_map_bind(&m,PAUSE,binding_key(.Escape))
    m.actions[PAUSE].input_context=CONTEXT_ALWAYS
    device:=core.Input{keys_down={.Escape},keys_pressed={.Escape}}
    modal:=Context_Stack{layers={0=MENU},count=1,modal=1}
    actions:Actions
    actions_update(&actions,&m,&device,1.0/60,&modal)
    testing.expect(t,action(&actions,PAUSE).pressed,"a modal context does not silence it")
    actions={}
    actions_update(&actions,&m,&device,1.0/60)
    testing.expect(t,action(&actions,PAUSE).pressed,"without a seat in a context, it reads too")
    input_map_bind(&m,CONFIRM,binding_key(.Escape))
    actions={}
    actions_update(&actions,&m,&device,1.0/60,&modal)
    testing.expect(t,action(&actions,CONFIRM).pressed && !action(&actions,PAUSE).down,"the context that reads Escape keeps it")
}

// A context takes from those under it the inputs its actions read, and a
// modal one takes everything; outside it, its actions read nothing.
@(test)
a_context_on_top_takes_the_inputs_its_actions_read :: proc(t:^testing.T) {
    m:=menu_bindings()
    device:=core.Input{keys_down={.Space,.W},keys_pressed={.Space,.W}}
    device.gamepads[0]={connected=true,down={.South},pressed={.South}}

    actions:Actions
    actions_update(&actions,&m,&device,1.0/60)
    testing.expect(t,action(&actions,JUMP).pressed && !action(&actions,CONFIRM).down,"outside the menu, its actions read nothing")

    menu:=Context_Stack{layers={0=MENU},count=1}
    actions={}
    actions_update(&actions,&m,&device,1.0/60,&menu)
    testing.expect(t,action(&actions,CONFIRM).pressed,"the menu confirms on Space")
    testing.expect(t,!action(&actions,JUMP).down,"Space and South of every gamepad are the menu's, also South of the first one")
    testing.expect(t,action(&actions,MOVE).vector==[2]f32{0,1},"what the menu does not read stays with the game")

    menu.modal=1
    actions={}
    actions_update(&actions,&m,&device,1.0/60,&menu)
    testing.expect(t,action(&actions,CONFIRM).pressed && !action(&actions,MOVE).down,"a modal menu leaves the game nothing")
}

// Owners put seats in contexts and take them out; the one entered last is on
// top. What cannot be entered is a problem that says why.
@(test)
seats_enter_and_leave_contexts_by_owner :: proc(t:^testing.T) {
    w:Test_Seats
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    first,second,inventory,map_screen:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,first,Seat{})
    core.add(&w.seats,second,Seat{slot=1})
    core.test_world_settle(&w)
    state:Input_Contexts
    problems:core.Problems
    stack :: proc(seats:^core.Table(Seat),e:core.Entity) -> Context_Stack {return seats.values[core.row_of(seats,e)].contexts}

    input_context_enter(&w.context_requests,inventory,core.NONE,MENU)
    input_context_enter(&w.context_requests,map_screen,second,MAP,modal=true)
    input_contexts(core.ref(&w.entities),&w.seats,&state,&w.context_requests,&problems)
    testing.expect(t,stack(&w.seats,first)==Context_Stack{layers={0=MENU},count=1},"none puts every local seat in it")
    testing.expect(t,stack(&w.seats,second)==Context_Stack{layers={0=MENU,1=MAP},count=2,modal=0b10},"the one entered last is on top")
    testing.expect(t,in_context(&state,inventory) && in_context(&state,map_screen))

    // Asked again with the same context, it keeps its place.
    input_context_enter(&w.context_requests,inventory,core.NONE,MENU)
    input_contexts(core.ref(&w.entities),&w.seats,&state,&w.context_requests,&problems)
    testing.expect(t,stack(&w.seats,second).layers[1]==MAP)

    input_context_leave(&w.context_requests,inventory)
    input_contexts(core.ref(&w.entities),&w.seats,&state,&w.context_requests,&problems)
    testing.expect(t,stack(&w.seats,first).count==0 && stack(&w.seats,second)==Context_Stack{layers={0=MAP},count=1,modal=1})

    // An owner that goes takes its seats out.
    core.destroy(&w.entities,map_screen)
    input_contexts(core.ref(&w.entities),&w.seats,&state,&w.context_requests,&problems)
    testing.expect(t,stack(&w.seats,second).count==0 && !in_context(&state,map_screen))
    testing.expect_value(t,problems.count,0)

    input_context_enter(&w.context_requests,inventory,core.NONE,CONTEXT_BASE)
    input_context_enter(&w.context_requests,inventory,core.NONE,Input_Context(CONTEXT_CAPACITY))
    input_context_enter(&w.context_requests,inventory,map_screen,MENU)
    input_contexts(core.ref(&w.entities),&w.seats,&state,&w.context_requests,&problems)
    for code in ([]string{"input.context_base","input.context_value","input.context_seat"}) {
        testing.expectf(t,core.problem_find(&problems,inventory,code)!=nil,"%s is a problem",code)
    }
    testing.expect(t,!in_context(&state,inventory))
}

// A button held as a seat leaves a context waits for its release: the press
// that closed the menu does not also jump.
@(test)
a_button_held_across_a_change_of_context_waits_for_its_release :: proc(t:^testing.T) {
    m:=menu_bindings()
    seat:Seat
    seat.contexts=Context_Stack{layers={0=MENU},count=1}
    device:=core.Input{keys_down={.Space},keys_pressed={.Space}}
    seat_feed(&seat,&device,&m,false,1.0/60)
    testing.expect(t,action(&seat.actions,CONFIRM).pressed)
    seat.contexts={}
    device={keys_down={.Space}}
    seat_feed(&seat,&device,&m,false,1.0/60)
    testing.expect(t,seat.rearm&action_bit(JUMP)!=0,"jump waits for Space to be released")
    device={keys_released={.Space}}
    seat_feed(&seat,&device,&m,false,1.0/60)
    device={keys_down={.Space},keys_pressed={.Space}}
    seat_feed(&seat,&device,&m,false,1.0/60)
    testing.expect(t,seat.rearm==0 && action(&seat.actions,JUMP).pressed,"pressed again, it jumps")
}

// Input_Settings puts an action in a context and gives a binding a chord,
// and its text names them.
@(test)
input_settings_name_contexts_and_chords :: proc(t:^testing.T) {
    names:=[]core.Name_Info{
        {type=Action,value=2,name="jump",file="game/game.odin",line=1},
        {type=Action,value=17,name="save",file="game/game.odin",line=2},
        {type=Input_Context,value=1,name="menu",file="game/game.odin",line=3},
    }
    info,made:=core.test_info(t,Test_Seats,test_types)
    if !made {return}
    defer core.test_info_destroy(&info)
    info.names=names
    settings:Input_Settings
    input_settings_put(&settings,"jump",action_default(.Button,binding_key(.S)))
    input_settings_put(&settings,"save",action_default_in(MENU,.Button,binding_chord(binding_key(.S),code_key(.Left_Control))))
    problems:core.Problems
    m:Input_Map
    input_map_make(&m,&info,&settings,&problems)
    testing.expect_value(t,problems.count,0)
    testing.expect(t,m.actions[SAVE].input_context==MENU && m.actions[JUMP].input_context==CONTEXT_BASE)

    menu:=Context_Stack{layers={0=MENU},count=1}
    actions:Actions
    device:=core.Input{keys_down={.Left_Control,.S},keys_pressed={.Left_Control,.S}}
    actions_update(&actions,&m,&device,1.0/60,&menu)
    testing.expect(t,action(&actions,SAVE).pressed && !action(&actions,JUMP).down,"the menu takes S, and Ctrl+S saves")

    named:=make(map[typeid]serial.Named,context.temp_allocator)
    named[Input_Context]={choices={{"base",0},{"menu",1}}}
    list:=[]project.Setting{{name="Input_Settings",info=type_info_of(Input_Settings),value=&settings,named=named}}
    text:=project.settings_text(list,allocator=context.temp_allocator)
    for want in ([]string{`"context": "menu"`,`"inputs": ["S"]`,`"chord": ["Left_Control"]`}) {testing.expectf(t,strings.contains(text,want),"%q is not in %s",want,text)}
    back:Input_Settings
    list[0].value=&back
    testing.expect_value(t,project.settings_parse(text,list).code,project.Error_Code.None)
    testing.expect(t,back==settings)
}
