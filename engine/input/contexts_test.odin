package input

import "core:strings"
import "core:testing"
import "mirai:core"

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
    input_map_bind(&m,JUMP,binding_gamepad_button(.South,0))
    input_map_action(&m,CONFIRM,.Button)
    input_map_bind(&m,CONFIRM,binding_key(.Space))
    input_map_bind(&m,CONFIRM,binding_gamepad_button(.South))
    m.contexts[CONFIRM]=MENU
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
    m.contexts[PAUSE]=CONTEXT_ALWAYS
    device:=core.Input{keys_down={.Escape},keys_pressed={.Escape}}
    modal:=Context_Stack{layers={0=MENU},count=1,modal=1}
    actions:Actions
    actions_update(&actions,&m,&device,&modal)
    testing.expect(t,action(&actions,PAUSE).pressed,"a modal context does not silence it")
    actions={}
    actions_update(&actions,&m,&device)
    testing.expect(t,action(&actions,PAUSE).pressed,"without a seat in a context, it reads too")
    input_map_bind(&m,CONFIRM,binding_key(.Escape))
    actions={}
    actions_update(&actions,&m,&device,&modal)
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
    actions_update(&actions,&m,&device)
    testing.expect(t,action(&actions,JUMP).pressed && !action(&actions,CONFIRM).down,"outside the menu, its actions read nothing")

    menu:=Context_Stack{layers={0=MENU},count=1}
    actions={}
    actions_update(&actions,&m,&device,&menu)
    testing.expect(t,action(&actions,CONFIRM).pressed,"the menu confirms on Space")
    testing.expect(t,!action(&actions,JUMP).down,"Space and South of every gamepad are the menu's, also South of the first one")
    testing.expect(t,action(&actions,MOVE).vector==[2]f32{0,1},"what the menu does not read stays with the game")

    menu.modal=1
    actions={}
    actions_update(&actions,&m,&device,&menu)
    testing.expect(t,action(&actions,CONFIRM).pressed && !action(&actions,MOVE).down,"a modal menu leaves the game nothing")
}

// Owners put seats in contexts and take them out; the one entered last is on
// top. What cannot be entered is a problem that says why.
@(test)
seats_enter_and_leave_contexts_by_owner :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    first,second,inventory,map_screen:=core.create(&es),core.create(&es),core.create(&es),core.create(&es)
    seats:core.Table(Seat)
    core.table_init(&seats,"Seat")
    defer core.table_destroy(&seats)
    core.add(&seats,first,Seat{})
    core.add(&seats,second,Seat{slot=1})
    core.table_settle(&seats,&es)
    state:Input_Contexts
    requests:Context_Requests
    defer delete(requests.items)
    problems:core.Problems
    stack :: proc(seats:^core.Table(Seat),e:core.Entity) -> Context_Stack {return seats.values[core.row_of(seats,e)].contexts}

    input_context_enter(&requests,inventory,core.NONE,MENU)
    input_context_enter(&requests,map_screen,second,MAP,modal=true)
    input_contexts(core.ref(&es),&seats,&state,&requests,&problems)
    testing.expect(t,stack(&seats,first)==Context_Stack{layers={0=MENU},count=1},"none puts every local seat in it")
    testing.expect(t,stack(&seats,second)==Context_Stack{layers={0=MENU,1=MAP},count=2,modal=0b10},"the one entered last is on top")
    testing.expect(t,in_context(&state,inventory) && in_context(&state,map_screen))

    // Asked again with the same context, it keeps its place.
    input_context_enter(&requests,inventory,core.NONE,MENU)
    input_contexts(core.ref(&es),&seats,&state,&requests,&problems)
    testing.expect(t,stack(&seats,second).layers[1]==MAP)

    input_context_leave(&requests,inventory)
    input_contexts(core.ref(&es),&seats,&state,&requests,&problems)
    testing.expect(t,stack(&seats,first).count==0 && stack(&seats,second)==Context_Stack{layers={0=MAP},count=1,modal=1})

    // An owner that goes takes its seats out.
    core.destroy(&es,map_screen)
    input_contexts(core.ref(&es),&seats,&state,&requests,&problems)
    testing.expect(t,stack(&seats,second).count==0 && !in_context(&state,map_screen))
    testing.expect_value(t,problems.count,0)

    input_context_enter(&requests,inventory,core.NONE,CONTEXT_BASE)
    input_context_enter(&requests,inventory,core.NONE,Input_Context(CONTEXT_CAPACITY))
    input_context_enter(&requests,inventory,map_screen,MENU)
    input_contexts(core.ref(&es),&seats,&state,&requests,&problems)
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
    seat_feed(&seat,&device,&m,false)
    testing.expect(t,action(&seat.actions,CONFIRM).pressed)
    seat.contexts={}
    device={keys_down={.Space}}
    seat_feed(&seat,&device,&m,false)
    testing.expect(t,seat.rearm&action_bit(JUMP)!=0,"jump waits for Space to be released")
    device={keys_released={.Space}}
    seat_feed(&seat,&device,&m,false)
    device={keys_down={.Space},keys_pressed={.Space}}
    seat_feed(&seat,&device,&m,false)
    testing.expect(t,seat.rearm==0 && action(&seat.actions,JUMP).pressed,"pressed again, it jumps")
}

// input.mirai puts an action in a context and gives a binding a chord; the
// options of the player write the chord and read it back.
@(test)
input_mirai_names_contexts_and_chords :: proc(t:^testing.T) {
    names:=[]core.Name_Info{
        {type=Action,value=2,name="jump",file="game/game.odin",line=1},
        {type=Action,value=17,name="save",file="game/game.odin",line=2},
        {type=Input_Context,value=1,name="menu",file="game/game.odin",line=3},
    }
    info:=core.World_Info{names=names}
    problems:core.Problems
    m:Input_Map
    input_map_make(&m,&info,"input.mirai",`{"actions":[
        {"name":"jump","kind":"Button","bindings":[{"key":"S"}]},
        {"name":"save","kind":"Button","context":"menu","bindings":[{"key":"S","chord":[{"key":"Left_Control"}]}]}]}`,&problems)
    testing.expect_value(t,problems.count,0)
    testing.expect(t,m.contexts[SAVE]==MENU && m.contexts[JUMP]==CONTEXT_BASE)

    menu:=Context_Stack{layers={0=MENU},count=1}
    actions:Actions
    device:=core.Input{keys_down={.Left_Control,.S},keys_pressed={.Left_Control,.S}}
    actions_update(&actions,&m,&device,&menu)
    testing.expect(t,action(&actions,SAVE).pressed && !action(&actions,JUMP).down,"the menu takes S, and Ctrl+S saves")

    below:Input_Map
    input_map_make(&below,&info,"",``,&problems)
    text,ok:=input_map_text(&m,&below,&info)
    testing.expect(t,ok && strings.contains(text,`"chord": [{"key": "Left_Control"}]`),text)
    again:=below
    error,_:=input_map_parse(&again,&info,text)
    testing.expect(t,error==.None && again.bindings[again.binding_count-1]==m.bindings[m.binding_count-1])

    for bad in ([]string{
        `{"actions":[{"name":"save","kind":"Button","context":"pause","bindings":[]}]}`,
        `{"actions":[{"name":"save","kind":"Button","bindings":[{"key":"S","chord":[{"mouse":"X"}]}]}]}`,
        `{"actions":[{"name":"save","kind":"Button","bindings":[{"key":"S","chord":[{"key":"A"},{"key":"B"},{"key":"C"}]}]}]}`,
    }) {
        error,at:=input_map_parse(&again,&info,bad)
        testing.expectf(t,error!=.None && at=="save","%s reads as %v",bad,error)
    }
    testing.expect(t,!input_map_bind(&again,SAVE,binding_chord(binding_key(.S),Input_Code{.Mouse_Axis,0})),"an axis is no chord")
}
