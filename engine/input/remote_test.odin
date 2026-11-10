package input

import "core:math"
import "core:testing"
import "mirai:core"

@(private="file") TEST_MOVE :: Action(0)
@(private="file") TEST_LOOK :: Action(1)
@(private="file") TEST_JUMP :: Action(2)
@(private="file") TEST_CONFIRM :: Action(3)
@(private="file") TEST_MENU :: Input_Context(1)

@(private="file")
remote_bindings :: proc() -> (m:Input_Map) {
    input_map_action(&m,TEST_MOVE,.Axis2)
    input_map_bind(&m,TEST_MOVE,binding_keys(.A,.D,.S,.W))
    input_map_action(&m,TEST_LOOK,.Axis2)
    input_map_bind(&m,TEST_LOOK,binding_mouse_delta())
    input_map_action(&m,TEST_JUMP,.Button)
    input_map_bind(&m,TEST_JUMP,binding_key(.Space))
    input_map_action(&m,TEST_CONFIRM,.Button)
    input_map_bind(&m,TEST_CONFIRM,binding_key(.Space))
    m.contexts[TEST_CONFIRM]=TEST_MENU
    return
}

@(private="file")
same_state :: proc(a,b:Action_State) -> bool {
    return a.down==b.down && a.pressed==b.pressed && a.released==b.released && a.tapped==b.tapped &&
        a.held_ticks==b.held_ticks && a.holding==b.holding && abs(a.value-b.value)<0.002 && abs(a.vector.x-b.vector.x)<0.001 && abs(a.vector.y-b.vector.y)<0.001
}

// The seat of another end that takes what a seat sent has its actions as
// they were where its devices are, in the contexts of that end, edges and
// taps included.
@(test)
a_seat_takes_the_actions_another_end_sent_as_they_were_there :: proc(t:^testing.T) {
    w:Test_Seats
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    m:=remote_bindings()
    local:=core.create(&w.entities)
    core.add(&w.seats,local,Seat{})
    core.test_world_settle(&w)
    there:Seat
    menu:=Context_Stack{layers={0=TEST_MENU},count=1,modal=1}
    Tick :: struct {device:core.Input,menu:bool}
    ticks:=[]Tick{
        {device={keys_down={.Space,.W},keys_pressed={.Space,.W}}},
        {device={keys_down={.Space,.D},keys_pressed={.D},keys_released={.W},mouse_delta={3,-2}}},
        {device={keys_released={.Space,.D},mouse_delta={-0.5,0}}},
        {device={keys_pressed={.Space},keys_released={.Space}}},
        {menu=true},
        {device={keys_down={.Space},keys_pressed={.Space}},menu=true},
        {device={keys_released={.Space}},menu=true},
        {},
    }
    for tick,index in ticks {
        seat:=core.edit(&w.seats,local)
        seat.contexts=tick.menu?menu:{}
        device:=tick.device
        seat_feed(seat,&device,&m,false)
        sent,ok:=seat_remote(core.read(&w.seats),local,&m)
        testing.expect(t,ok)
        seat_receive(&there,&m,sent)
        for a in ([]Action{TEST_MOVE,TEST_LOOK,TEST_JUMP,TEST_CONFIRM}) {
            here:=seat_action(core.read(&w.seats),local,a)
            testing.expectf(t,same_state(here,action(&there.actions,a)),"tick %d, action %d: %v here, %v there",index,a,here,action(&there.actions,a))
        }
    }
    testing.expect(t,there.contexts.count==0,"the contexts of the end that sent are not those of the seat that takes")
}

// A tick that did not arrive keeps what was held without pressing it again,
// and repeats neither a tap nor the movement of the mouse.
@(test)
a_repeated_tick_holds_what_was_held_and_not_the_mouse :: proc(t:^testing.T) {
    m:=remote_bindings()
    sent:Remote_Actions
    sent.down=action_bit(TEST_JUMP)|action_bit(TEST_MOVE)|action_bit(TEST_LOOK)
    sent.quick=action_bit(TEST_CONFIRM)
    sent.motion=action_bit(TEST_LOOK)
    sent.axis_count=2
    sent.axes[0]={TEST_MOVE,{0,1}}
    sent.axes[1]={TEST_LOOK,{4,1}}
    there:Seat
    seat_receive(&there,&m,sent)
    testing.expect(t,action(&there.actions,TEST_JUMP).pressed && action(&there.actions,TEST_CONFIRM).pressed && action(&there.actions,TEST_CONFIRM).released)
    seat_receive(&there,&m,remote_repeated(sent))
    jump,move,look:=action(&there.actions,TEST_JUMP),action(&there.actions,TEST_MOVE),action(&there.actions,TEST_LOOK)
    testing.expect(t,jump.down && !jump.pressed && jump.held_ticks==2)
    testing.expect(t,move.down && move.vector==[2]f32{0,1})
    testing.expect(t,!look.down && look.vector==[2]f32{})
    testing.expect(t,!action(&there.actions,TEST_CONFIRM).pressed)
}

// What another end sends is hostile: counts, actions and values out of range
// leave the actions of the map, and nothing else.
@(test)
hostile_remote_actions_stay_in_the_map :: proc(t:^testing.T) {
    m:=remote_bindings()
    cases:=[]Remote_Actions{
        {down=ALL_ACTIONS,quick=ALL_ACTIONS,motion=ALL_ACTIONS,axis_count=255},
        {down=ALL_ACTIONS,axis_count=REMOTE_AXES,axes={0={Action(200),{1,1}},1={Action(63),{math.F32_MAX,-math.F32_MAX}},2={TEST_MOVE,{math.nan_f32(),0}}}},
    }
    for sent in cases {
        there:Seat
        seat_receive(&there,&m,sent)
        seat_receive(&there,&m,remote_repeated(sent))
        testing.expect_value(t,int(there.actions.count),action_end(&m))
    }
    without:Seat
    seat_receive(&without,nil,cases[0])
    testing.expect_value(t,without.actions.count,0)
}
