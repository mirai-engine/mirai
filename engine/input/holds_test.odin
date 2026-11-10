package input

import "core:testing"
import "mirai:core"

@(private="file") HOLD_MOVE :: Action(0)
@(private="file") HOLD_JUMP :: Action(2)
@(private="file") HOLD_CONFIRM :: Action(3)
@(private="file") HOLD_MENU :: Input_Context(1)

// The values 0 to 3, as a world whose first enum @(actions) it is.
@(private="file") Hold_Test_Action :: enum u8 {Move,Look,Jump,Confirm}

@(private="file")
Hold_Test :: struct {
    using w:Test_Seats,
    problems:core.Problems,
    time:core.Time,
    bindings:Input_Map,
    local,remote:core.Entity,
}

@(private="file")
hold_test_init :: proc(t:^testing.T,f:^Hold_Test,jump:..Input_Binding) -> bool {
    core.test_world_init(t,&f.w,test_types) or_return
    f.local,f.remote=core.create(&f.entities),core.create(&f.entities)
    core.add(&f.seats,f.local,Seat{})
    core.add(&f.seats,f.remote,Seat{peer=7})
    core.test_world_settle(&f.w)
    input_map_action(&f.bindings,HOLD_MOVE,.Axis2)
    input_map_bind(&f.bindings,HOLD_MOVE,binding_keys(.A,.D,.S,.W))
    input_map_action(&f.bindings,HOLD_JUMP,.Button)
    for binding in jump {input_map_bind(&f.bindings,HOLD_JUMP,binding)}
    input_map_action(&f.bindings,HOLD_CONFIRM,.Button)
    f.bindings.contexts[HOLD_CONFIRM]=HOLD_MENU
    f.time.tick=10
    return true
}

// One fixed tick of the seats without devices: the holds first, as the loop
// runs them, then the local seat reads its actions, and the seat of a
// connection takes them as its client sends them to the server.
@(private="file")
hold_test_tick :: proc(f:^Hold_Test) {
    input_holds(&f.seats,&f.hold_requests,f.time,&f.problems)
    device:core.Input
    seat_feed(core.get(&f.seats,f.local),&device,&f.bindings,false,1.0/60)
    sent,_:=seat_remote(core.read(&f.seats),f.local,&f.bindings)
    seat_receive(core.get(&f.seats,f.remote),&f.bindings,sent,1.0/60)
    core.time_advance(&f.time)
}

@(test)
a_held_action_reaches_its_seat_from_the_next_tick_whatever_its_bindings :: proc(t:^testing.T) {
    rebound:=[3][]Input_Binding{{binding_key(.Space)},{binding_key(.K),binding_gamepad_button(.East)},{}}
    for jump in rebound {
        f:Hold_Test
        if !hold_test_init(t,&f,..jump) {return}
        defer core.test_world_destroy(&f.w)
        read:=core.read(&f.seats)
        typed:=Input_Of(Hold_Test_Action){seats=read}
        hold(&f.hold_requests,f.local,HOLD_JUMP,{1,0},3)
        hold(&f.hold_requests,f.local,HOLD_MOVE,{0,1})
        testing.expect(t,!seat_down(typed,f.local,.Jump),"nothing acts before the tick")
        _,ahead:=holds_at(f.seats.values[core.row_of(read,f.local)],f.local,&f.hold_requests,f.time.tick)
        testing.expect_value(t,ahead,2)
        hold_test_tick(&f)
        testing.expect(t,seat_pressed(typed,f.local,.Jump),"pressed on the next tick")
        testing.expect(t,seat_pressed(typed,f.remote,.Jump),"and on the server, from what the client sent")
        testing.expect_value(t,seat_vector(typed,f.local,.Move),[2]f32{0,1})
        testing.expect_value(t,seat_vector(typed,f.remote,.Move),[2]f32{0,1})
        hold_test_tick(&f)
        hold_test_tick(&f)
        testing.expect(t,seat_down(typed,f.remote,.Jump) && !seat_pressed(typed,f.remote,.Jump))
        testing.expect(t,abs(seat_action(read,f.remote,HOLD_JUMP).held-3.0/60)<1e-6)
        // Its seat still has the jump, which the next tick no longer holds.
        _,ahead=holds_at(f.seats.values[core.row_of(read,f.local)],f.local,&f.hold_requests,f.time.tick)
        testing.expect(t,ahead==1 && f.seats.values[core.row_of(read,f.local)].hold_count==2)
        hold_test_tick(&f)
        state:=seat_action(read,f.remote,HOLD_JUMP)
        testing.expect(t,state.released && state.tapped && abs(state.released_held-3.0/60)<1e-6,"released after its ticks")
        testing.expect_value(t,f.seats.values[core.row_of(read,f.local)].hold_count,1)
        testing.expect_value(t,seat_vector(typed,f.local,.Move),[2]f32{0,1})
        // Until it is let go: released on the tick after.
        let_go(&f.hold_requests,f.local,HOLD_MOVE)
        hold_test_tick(&f)
        testing.expect(t,seat_released(typed,f.local,.Move) && seat_released(typed,f.remote,.Move))
        testing.expect_value(t,f.problems.count,0)
    }
}

@(test)
a_held_action_keeps_the_contexts_blocks_and_capacity_of_its_seat :: proc(t:^testing.T) {
    f:Hold_Test
    if !hold_test_init(t,&f,binding_key(.Space)) {return}
    defer core.test_world_destroy(&f.w)
    read:=core.read(&f.seats)
    typed:=Input_Of(Hold_Test_Action){seats=read}
    hold(&f.hold_requests,f.local,HOLD_CONFIRM,{1,0})
    hold_test_tick(&f)
    testing.expect(t,!seat_down(typed,f.local,.Confirm),"an action of a context the seat is not in")
    let_go(&f.hold_requests,f.local,HOLD_CONFIRM)
    seat:=core.get(&f.seats,f.local)
    seat.contexts.layers[0],seat.contexts.count=HOLD_MENU,1
    hold_test_tick(&f)
    hold(&f.hold_requests,f.local,HOLD_CONFIRM,{1,0})
    hold_test_tick(&f)
    testing.expect(t,seat_pressed(typed,f.local,.Confirm),"in the context, it acts")
    seat.blocked=action_bit(HOLD_CONFIRM)
    testing.expect(t,!seat_down(typed,f.local,.Confirm),"a block takes it")
    for action in 4..<4+HOLD_CAPACITY {hold(&f.hold_requests,f.local,Action(action),{1,0})}
    hold(&f.hold_requests,core.Entity(0xdead),HOLD_JUMP,{1,0})
    hold(&f.hold_requests,f.remote,HOLD_JUMP,{1,0})
    hold_test_tick(&f)
    testing.expect_value(t,f.problems.count,3)
    testing.expect_value(t,f.seats.values[core.row_of(read,f.remote)].hold_count,0)
    testing.expect_value(t,f.seats.values[core.row_of(read,f.local)].hold_count,u8(HOLD_CAPACITY))
}

@(test)
the_same_holds_on_the_same_seats_give_the_same_ticks :: proc(t:^testing.T) {
    run :: proc(t:^testing.T) -> (states:[12][2]Action_State) {
        f:Hold_Test
        if !hold_test_init(t,&f,binding_key(.Space)) {return}
        defer core.test_world_destroy(&f.w)
        read:=core.read(&f.seats)
        typed:=Input_Of(Hold_Test_Action){seats=read}
        for tick in 0..<len(states) {
            switch tick {
            case 0: hold(&f.hold_requests,f.local,HOLD_JUMP,{1,0},2)
            case 1: hold(&f.hold_requests,f.local,HOLD_MOVE,{0.5,-0.5},4)
            case 4: hold(&f.hold_requests,f.local,HOLD_JUMP,{1,0},5)
            case 6: let_go(&f.hold_requests,f.local,HOLD_JUMP)
            }
            hold_test_tick(&f)
            states[tick]={seat_action(read,f.local,HOLD_JUMP),seat_action(read,f.local,HOLD_MOVE)}
        }
        return
    }
    first,second:=run(t),run(t)
    testing.expect(t,first==second)
    testing.expect(t,first[0][0].pressed && first[2][0].released && first[4][0].pressed && first[5][0].down && first[6][0].released)
    testing.expect(t,first[1][1].pressed && first[4][1].down && first[5][1].released)
}
