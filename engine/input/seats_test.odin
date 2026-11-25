package input

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:core"

@(private="file") TEST_MOVE :: Action(0)
@(private="file") TEST_JUMP :: Action(2)

// The values 0 to 2, as a world whose first enum @(actions) it is.
@(private="file") Seat_Test_Action :: enum u8 {Move,Look,Jump}

@(private="file")
test_bindings :: proc() -> (bindings:Input_Map) {
    input_map_action(&bindings,TEST_JUMP,.Button)
    input_map_bind(&bindings,TEST_JUMP,binding_key(.Space))
    input_map_bind(&bindings,TEST_JUMP,binding_gamepad_button(.South))
    input_map_action(&bindings,TEST_MOVE,.Axis2)
    input_map_bind(&bindings,TEST_MOVE,binding_keys(.A,.D,.S,.W))
    input_map_compile(&bindings)
    return
}

@(test)
devices_reach_each_local_player :: proc(t:^testing.T) {
    device:=core.Input{keys_down={.Space},keys_pressed={.Space}}
    device.gamepads[1]={connected=true,down={.South},pressed={.South}}
    testing.expect(t,slot_input(device,0,2,0).keys_down=={.Space})
    testing.expect(t,slot_input(device,1,2,0).keys_down=={})
    testing.expect(t,!slot_input(device,0,2,0).gamepads[1].connected)
    testing.expect(t,slot_input(device,1,2,0).gamepads[1].connected)
    testing.expect(t,slot_input(device,0,1,0).gamepads[1].connected)

    bindings:=test_bindings()
    first,second:Seat_State
    own:=slot_input(device,0,2,0)
    seat_feed(&first,&own,&bindings,false,1.0/60)
    own=slot_input(device,1,2,0)
    seat_feed(&second,&own,&bindings,false,1.0/60)
    testing.expect(t,action(&first.actions,TEST_JUMP).pressed)
    testing.expect(t,action(&second.actions,TEST_JUMP).pressed)
}

@(test)
focus_and_driving_wait_for_held_buttons :: proc(t:^testing.T) {
    w:Test_Seats
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    first,second,body,other:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    bindings:=test_bindings()
    core.add(&w.seats,first,Seat{})
    core.add(&w.seats,second,Seat{slot=1})
    core.add(&w.moves,body,Move_Input{})
    test_world_settle(&w)
    state:=&w.seat_state
    problems:core.Problems
    a:=Apply{es=&w.entities,state=state,states=&w.runtime,moves=&w.moves,seats=&w.seats,problems=&problems}
    read:=Input_Of(Seat_Test_Action){state=core.ref(state),runtime=core.ref(&w.runtime),seats=core.read(&w.seats)}

    // Space and W held while the keyboard is with the first player.
    device:=core.Input{keys_down={.Space,.W},keys_pressed={.Space,.W}}
    tick :: proc(states:^Seat_States,first,second:core.Entity,device:core.Input,focus:int,bindings:^Input_Map,moved:=false) {
        for e,slot in ([2]core.Entity{first,second}) {
            own:=slot_input(device,slot,2,focus)
            seat_feed(seat_runtime_edit(states,e),&own,bindings,moved && slot==focus,1.0/60)
        }
    }
    tick(&w.runtime,first,second,device,0,&bindings)
    testing.expect(t,seat_pressed(read,first,.Jump))
    testing.expect(t,!seat_down(read,second,.Jump))

    // The keyboard moves to the second player: the first sees the release,
    // the second waits for it; the axis moves on at once.
    device.keys_pressed={}
    tick(&w.runtime,first,second,device,1,&bindings,true)
    testing.expect(t,seat_released(read,first,.Jump))
    testing.expect(t,!seat_down(read,second,.Jump))
    testing.expect(t,seat_vector(read,second,.Move)==[2]f32{0,1})

    device={keys_released={.Space,.W}}
    tick(&w.runtime,first,second,device,1,&bindings)
    device={keys_down={.Space},keys_pressed={.Space}}
    tick(&w.runtime,first,second,device,1,&bindings)
    testing.expect(t,seat_pressed(read,second,.Jump))

    // Driving a body while jump is held: it waits for its release.
    device.keys_pressed={}
    tick(&w.runtime,first,second,device,1,&bindings)
    request_apply(&a,{kind=.Drive,seat=second,entity=body})
    testing.expect(t,seat_of(core.ref(state),body)==second)
    testing.expect(t,!seat_down(read,second,.Jump))
    device={keys_released={.Space}}
    tick(&w.runtime,first,second,device,1,&bindings)
    device={keys_down={.Space},keys_pressed={.Space}}
    tick(&w.runtime,first,second,device,1,&bindings)
    testing.expect(t,seat_pressed(read,second,.Jump))

    // A block takes the action; once given back, the held button waits for its release.
    request_apply(&a,{kind=.Block_Add,owner=body,seat=second,mask=ALL_ACTIONS})
    blocks_apply(&w.seats,state,&w.runtime)
    testing.expect(t,!seat_down(read,second,.Jump))
    testing.expect(t,!pressed(read,body,.Jump))
    request_apply(&a,{kind=.Block_Remove,owner=body})
    blocks_apply(&w.seats,state,&w.runtime)
    testing.expect(t,!seat_down(read,second,.Jump))
    device={keys_released={.Space}}
    tick(&w.runtime,first,second,device,1,&bindings)
    device={keys_down={.Space},keys_pressed={.Space}}
    tick(&w.runtime,first,second,device,1,&bindings)
    testing.expect(t,pressed(read,body,.Jump))

    // The body it lets go of stops, looking where it looked.
    core.edit(&w.moves,body)^=Move_Input{move={0,0,-1},look_yaw=1,buttons=action_bit(TEST_JUMP)}
    request_apply(&a,{kind=.Drive,seat=second,entity=other})
    left,_:=core.get(core.read(&w.moves),body)
    testing.expect_value(t,left,Move_Input{look_yaw=1})
    testing.expect_value(t,body_of(core.read(&w.seats),second),other)
    testing.expect_value(t,problems.count,0)
}

@(test)
a_block_of_no_seat_takes_every_local_seat :: proc(t:^testing.T) {
    w:Test_Seats
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    first,second,remote,menu:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    bindings:=test_bindings()
    core.add(&w.seats,first,Seat{})
    core.add(&w.seats,second,Seat{slot=1})
    core.add(&w.seats,remote,Seat{remote=true})
    test_world_settle(&w)
    state:=&w.seat_state
    problems:core.Problems
    a:=Apply{es=&w.entities,state=state,states=&w.runtime,moves=&w.moves,seats=&w.seats,problems=&problems}
    read:=Input_Of(Seat_Test_Action){state=core.ref(state),runtime=core.ref(&w.runtime),seats=core.read(&w.seats)}
    for e in ([3]core.Entity{first,second,remote}) {seat_runtime_edit(&w.runtime,e)}
    blocked :: proc(states:^Seat_States,e:core.Entity) -> Action_Mask {return seat_runtime_edit(states,e).blocked}
    device:=core.Input{keys_down={.Space},keys_pressed={.Space}}
    seat_feed(seat_runtime_edit(&w.runtime,first),&device,&bindings,false,1.0/60)
    request_apply(&a,{kind=.Block_Add,owner=menu,mask=ALL_ACTIONS})
    blocks_apply(&w.seats,state,&w.runtime)
    testing.expect(t,blocking(core.ref(state),menu))
    testing.expect(t,blocked(&w.runtime,first)==ALL_ACTIONS && blocked(&w.runtime,second)==ALL_ACTIONS)
    testing.expect_value(t,blocked(&w.runtime,remote),Action_Mask(0))
    testing.expect(t,!seat_down(read,first,.Jump))
    // Its owner still gets what it takes, until another owner takes it too.
    testing.expect(t,seat_action_for(core.ref(state),core.ref(&w.runtime),core.read(&w.seats),first,TEST_JUMP,menu).pressed)
    cinematic:=core.create(&w.entities)
    request_apply(&a,{kind=.Block_Add,owner=cinematic,seat=first,mask=action_bit(TEST_JUMP)})
    blocks_apply(&w.seats,state,&w.runtime)
    testing.expect(t,!seat_action_for(core.ref(state),core.ref(&w.runtime),core.read(&w.seats),first,TEST_JUMP,menu).down)
    request_apply(&a,{kind=.Block_Remove,owner=cinematic})
    blocks_apply(&w.seats,state,&w.runtime)
    // Given back, the button held through the block waits for its release.
    request_apply(&a,{kind=.Block_Remove,owner=menu})
    blocks_apply(&w.seats,state,&w.runtime)
    testing.expect(t,blocked(&w.runtime,first)==0 && !seat_down(read,first,.Jump))
    // The owner goes: so does its block.
    request_apply(&a,{kind=.Block_Add,owner=menu,mask=ALL_ACTIONS})
    core.destroy(&w.entities,menu)
    upkeep(&a)
    blocks_apply(&w.seats,state,&w.runtime)
    testing.expect(t,!blocking(core.ref(state),menu) && blocked(&w.runtime,second)==0)
    testing.expect_value(t,problems.count,0)
}

@(test)
refused_drives_report_the_seat_and_how_to_fix_them :: proc(t:^testing.T) {
    w:Test_Seats
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    first,second,body,prop:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,first,Seat{})
    core.add(&w.seats,second,Seat{slot=1})
    core.destroy(&w.entities,prop)
    test_world_settle(&w)
    state:=&w.seat_state
    problems:core.Problems
    a:=Apply{es=&w.entities,state=state,states=&w.runtime,moves=&w.moves,seats=&w.seats,problems=&problems}

    request_apply(&a,{kind=.Drive,seat=first,entity=body})
    request_apply(&a,{kind=.Drive,seat=second,entity=body})
    request_apply(&a,{kind=.Drive,seat=second,entity=body})
    request_apply(&a,{kind=.Drive,seat=second,entity=prop})
    testing.expect_value(t,seat_of(core.ref(state),body),first)
    testing.expect_value(t,problems.count,2)
    taken:=core.problem_find(&problems,second,"input.body_taken")
    if testing.expect(t,taken!=nil) {
        testing.expect_value(t,taken.count,u64(2))
        testing.expect(t,strings.contains(core.problem_text(taken),fmt.tprintf("0x%016x",u64(body))))
        testing.expect(t,strings.contains(core.problem_text(taken),"release it first"))
    }
    gone:=core.problem_find(&problems,second,"input.body_gone")
    testing.expect(t,gone!=nil && strings.contains(core.problem_text(gone),"drive a live body"))
}


// A client takes only the bodies it owns, and lets go of one the server gave
// someone else (it became core.Remote) to drive the one it got instead.
@(test)
a_client_lets_go_of_what_the_server_took_and_takes_only_what_it_owns :: proc(t:^testing.T) {
    w:Test_Seats
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    seat,person,dog:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,seat,Seat{body=person})
    core.add(&w.remotes,dog,core.Remote{})
    test_world_settle(&w)
    state:=&w.seat_state
    problems:core.Problems
    a:=Apply{es=&w.entities,state=state,states=&w.runtime,moves=&w.moves,seats=&w.seats,role=.Client,elsewhere=core.read(&w.remotes),problems=&problems}

    request_apply(&a,{kind=.Drive,seat=seat,entity=dog})
    testing.expect_value(t,body_of(core.read(&w.seats),seat),person)
    testing.expect(t,core.problem_find(&problems,seat,"input.server_decides")!=nil)

    // The server gives the dog to this client and the person to someone else.
    core.remove(&w.remotes,dog)
    core.add(&w.remotes,person,core.Remote{})
    test_world_settle(&w)
    a.elsewhere=core.read(&w.remotes)
    count:=problems.count
    request_apply(&a,{kind=.Release,seat=seat})
    request_apply(&a,{kind=.Drive,seat=seat,entity=dog})
    testing.expect_value(t,body_of(core.read(&w.seats),seat),dog)
    testing.expect_value(t,seat_of(core.ref(state),person),core.NONE)
    testing.expect_value(t,problems.count,count)
}

@(test)
steady_input_keeps_the_authored_seats_clean_without_allocating :: proc(t:^testing.T) {
    testing.expect(t,size_of(Seat)<=4*size_of(u64))
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    context.allocator=mem.tracking_allocator(&tracker)
    context.temp_allocator=context.allocator
    w:Test_Seats
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)

    first,second,body,remote:=core.create(&w.entities),core.create(&w.entities),
        core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,first,Seat{body=body})
    core.add(&w.seats,second,Seat{slot=1})
    core.add(&w.seats,remote,Seat{slot=1,remote=true})
    test_world_settle(&w)

    bindings:=test_bindings()
    network:core.Network
    run:=Run_Players{count=2}
    contexts:Input_Contexts
    frame:Frame_Actions
    problems:core.Problems
    // Where each local slot looked as the last frame was drawn.
    views:=Slot_Views{views={0={yaw=0.5,pitch=0.1,kind=.Apart},1={yaw=-0.25,kind=.Body}}}
    tick :: proc(w:^Test_Seats,contexts:^Input_Contexts,run:^Run_Players,bindings:^Input_Map,
        network:^core.Network,frame:^Frame_Actions,problems:^core.Problems,device:core.Input,views:^Slot_Views) {
        es:=core.ref(&w.entities)
        seats:=core.read(&w.seats)
        time:=core.Time{dt=1.0/60}
        input_contexts(es,seats,&w.runtime,contexts,&w.context_requests,problems)
        input_holds(seats,&w.runtime,&w.hold_requests,time,problems)
        input_seats({entities=&w.entities},nil,&w.seats,&w.seat_state,run,&w.runtime,device,core.ref(views),
            core.ref(bindings),core.ref(network),nil,time)
        input_drive(es,&w.moves,&w.seats,&w.seat_state,&w.runtime,&w.seat_requests,
            core.ref(network),core.read(&w.remotes),nil,nil,{},problems)
        input_frame_actions_update(core.ref(bindings),frame,{input=device},core.ref(&w.seat_state),
            seats,core.ref(&w.runtime),{dt=time.dt})
    }
    tick(&w,&contexts,&run,&bindings,&network,&frame,&problems,{},&views)
    version:=core.version(&w.seats)
    allocated:=tracker.total_memory_allocated
    drive(&w.seat_requests,first,body)
    hold(&w.hold_requests,first,TEST_JUMP,{1,0})
    input_context_enter(&w.context_requests,body,first,Input_Context(1))
    input_context_leave(&w.context_requests,body)
    for _ in 0..<8 {
        tick(&w,&contexts,&run,&bindings,&network,&frame,&problems,{keys_down={.W}},&views)
    }

    testing.expect_value(t,tracker.total_memory_allocated,allocated)
    testing.expect_value(t,core.version(&w.seats),version)
    testing.expect_value(t,problems.count,0)
    state,runtime:=core.ref(&w.seat_state),core.ref(&w.runtime)
    testing.expect_value(t,seat_of(state,body),first)
    testing.expect(t,body_action(state,runtime,body,TEST_JUMP).down)
    testing.expect(t,!seat_action(runtime,remote,TEST_JUMP).down)
    testing.expect_value(t,action(&frame.slots[0],TEST_MOVE).vector,[2]f32{0,1})
    testing.expect(t,seat_view(runtime,first)==views.views[0] && seat_view(runtime,second)==views.views[1],"each local seat looks where its slot was drawn from")
    testing.expect_value(t,seat_view(runtime,remote),Seat_View{})

    core.destroy(&w.entities,body)
    test_world_settle(&w)
    tick(&w,&contexts,&run,&bindings,&network,&frame,&problems,{},&views)
    testing.expect_value(t,seat_of(state,body),core.NONE)
    testing.expect_value(t,body_of(core.read(&w.seats),first),core.NONE)
}
