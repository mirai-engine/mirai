package input

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

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
    return
}

// The ray is that of the camera the body names, not of the body.
@(test)
aim_is_the_ray_of_the_camera_of_the_body :: proc(t:^testing.T) {
    w:Test_Seats
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    body,camera,bare:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    turn:=mm.quat_axis_angle({0,1,0},mm.PI/2)
    core.add(&w.drivables,body,Drivable{camera=camera})
    core.add(&w.drivables,bare,Drivable{})
    core.add(&w.worlds,camera,core.World_Transform{transform={position={1,2,3},rotation=turn,scale={1,1,1}}})
    core.test_world_settle(&w)
    origin,direction,ok:=aim(core.read(&w.drivables),core.read(&w.worlds),body)
    testing.expect(t,ok && origin==[3]f32{1,2,3})
    testing.expectf(t,abs(direction.x+1)<1e-5 && abs(direction.z)<1e-5,"a quarter turn to the left looks along -X: %v",direction)
    _,_,ok=aim(core.read(&w.drivables),core.read(&w.worlds),bare)
    testing.expect(t,!ok,"a body without a camera has no aim")
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
    first,second:Seat
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
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    first,second,body:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    bindings:=test_bindings()
    core.add(&w.seats,first,Seat{})
    core.add(&w.seats,second,Seat{slot=1})
    core.add(&w.drivables,body,Drivable{})
    core.test_world_settle(&w)
    state:Seats
    problems:core.Problems
    a:=Apply{es=&w.entities,state=&state,drivables=&w.drivables,seats=&w.seats,problems=&problems}
    read:=Input_Of(Seat_Test_Action){seats=core.read(&w.seats),drivables=core.read(&w.drivables)}

    // Space and W held while the keyboard is with the first player.
    device:=core.Input{keys_down={.Space,.W},keys_pressed={.Space,.W}}
    tick :: proc(seats:^core.Table(Seat),first,second:core.Entity,device:core.Input,focus:int,bindings:^Input_Map,moved:=false) {
        for e,slot in ([2]core.Entity{first,second}) {
            own:=slot_input(device,slot,2,focus)
            seat_feed(core.edit(seats,e),&own,bindings,moved && slot==focus,1.0/60)
        }
    }
    tick(&w.seats,first,second,device,0,&bindings)
    testing.expect(t,seat_pressed(read,first,.Jump))
    testing.expect(t,!seat_down(read,second,.Jump))

    // The keyboard moves to the second player: the first sees the release,
    // the second waits for it; the axis moves on at once.
    device.keys_pressed={}
    tick(&w.seats,first,second,device,1,&bindings,true)
    testing.expect(t,seat_released(read,first,.Jump))
    testing.expect(t,!seat_down(read,second,.Jump))
    testing.expect(t,seat_vector(read,second,.Move)==[2]f32{0,1})

    device={keys_released={.Space,.W}}
    tick(&w.seats,first,second,device,1,&bindings)
    device={keys_down={.Space},keys_pressed={.Space}}
    tick(&w.seats,first,second,device,1,&bindings)
    testing.expect(t,seat_pressed(read,second,.Jump))

    // Driving a body while jump is held: it waits for its release.
    device.keys_pressed={}
    tick(&w.seats,first,second,device,1,&bindings)
    request_apply(&a,{kind=.Drive,seat=second,entity=body})
    testing.expect(t,seat_of(core.read(&w.drivables),body)==second)
    testing.expect(t,!seat_down(read,second,.Jump))
    device={keys_released={.Space}}
    tick(&w.seats,first,second,device,1,&bindings)
    device={keys_down={.Space},keys_pressed={.Space}}
    tick(&w.seats,first,second,device,1,&bindings)
    testing.expect(t,seat_pressed(read,second,.Jump))

    // A block takes the action; once given back, the held button waits for its release.
    request_apply(&a,{kind=.Block_Add,owner=body,seat=second,mask=ALL_ACTIONS})
    blocks_apply(&w.seats,&state)
    testing.expect(t,!seat_down(read,second,.Jump))
    testing.expect(t,!pressed(read,body,.Jump))
    request_apply(&a,{kind=.Block_Remove,owner=body})
    blocks_apply(&w.seats,&state)
    testing.expect(t,!seat_down(read,second,.Jump))
    device={keys_released={.Space}}
    tick(&w.seats,first,second,device,1,&bindings)
    device={keys_down={.Space},keys_pressed={.Space}}
    tick(&w.seats,first,second,device,1,&bindings)
    testing.expect(t,pressed(read,body,.Jump))
    testing.expect_value(t,problems.count,0)
}

@(test)
a_block_of_no_seat_takes_every_local_seat :: proc(t:^testing.T) {
    w:Test_Seats
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    first,second,remote,menu:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    bindings:=test_bindings()
    core.add(&w.seats,first,Seat{})
    core.add(&w.seats,second,Seat{slot=1})
    core.add(&w.seats,remote,Seat{peer=7})
    core.test_world_settle(&w)
    state:Seats
    problems:core.Problems
    a:=Apply{es=&w.entities,state=&state,drivables=&w.drivables,seats=&w.seats,problems=&problems}
    read:=Input_Of(Seat_Test_Action){seats=core.read(&w.seats),drivables=core.read(&w.drivables)}
    blocked :: proc(seats:^core.Table(Seat),e:core.Entity) -> Action_Mask {return seats.values[core.row_of(seats,e)].blocked}
    device:=core.Input{keys_down={.Space},keys_pressed={.Space}}
    seat_feed(core.edit(&w.seats,first),&device,&bindings,false,1.0/60)
    request_apply(&a,{kind=.Block_Add,owner=menu,mask=ALL_ACTIONS})
    blocks_apply(&w.seats,&state)
    testing.expect(t,blocking(&state,menu))
    testing.expect(t,blocked(&w.seats,first)==ALL_ACTIONS && blocked(&w.seats,second)==ALL_ACTIONS)
    testing.expect_value(t,blocked(&w.seats,remote),Action_Mask(0))
    testing.expect(t,!seat_down(read,first,.Jump))
    // Its owner still gets what it takes, until another owner takes it too.
    testing.expect(t,seat_action_for(&state,core.read(&w.seats),first,TEST_JUMP,menu).pressed)
    cinematic:=core.create(&w.entities)
    request_apply(&a,{kind=.Block_Add,owner=cinematic,seat=first,mask=action_bit(TEST_JUMP)})
    blocks_apply(&w.seats,&state)
    testing.expect(t,!seat_action_for(&state,core.read(&w.seats),first,TEST_JUMP,menu).down)
    request_apply(&a,{kind=.Block_Remove,owner=cinematic})
    blocks_apply(&w.seats,&state)
    // Given back, the button held through the block waits for its release.
    request_apply(&a,{kind=.Block_Remove,owner=menu})
    blocks_apply(&w.seats,&state)
    testing.expect(t,blocked(&w.seats,first)==0 && !seat_down(read,first,.Jump))
    // The owner goes: so does its block.
    request_apply(&a,{kind=.Block_Add,owner=menu,mask=ALL_ACTIONS})
    core.destroy(&w.entities,menu)
    upkeep(&a)
    blocks_apply(&w.seats,&state)
    testing.expect(t,!blocking(&state,menu) && blocked(&w.seats,second)==0)
    testing.expect_value(t,problems.count,0)
}

@(test)
refused_drives_report_the_seat_and_how_to_fix_them :: proc(t:^testing.T) {
    w:Test_Seats
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    first,second,body,prop:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,first,Seat{})
    core.add(&w.seats,second,Seat{slot=1})
    core.add(&w.drivables,body,Drivable{})
    core.test_world_settle(&w)
    state:Seats
    problems:core.Problems
    a:=Apply{es=&w.entities,state=&state,drivables=&w.drivables,seats=&w.seats,problems=&problems}

    request_apply(&a,{kind=.Drive,seat=first,entity=body})
    request_apply(&a,{kind=.Drive,seat=second,entity=body})
    request_apply(&a,{kind=.Drive,seat=second,entity=body})
    request_apply(&a,{kind=.Drive,seat=second,entity=prop})
    testing.expect_value(t,seat_of(core.read(&w.drivables),body),first)
    testing.expect_value(t,problems.count,2)
    taken:=core.problem_find(&problems,second,"input.body_taken")
    if testing.expect(t,taken!=nil) {
        testing.expect_value(t,taken.count,u64(2))
        testing.expect(t,strings.contains(core.problem_text(taken),fmt.tprintf("0x%016x",u64(body))))
        testing.expect(t,strings.contains(core.problem_text(taken),"release it first"))
    }
    missing:=core.problem_find(&problems,second,"input.not_drivable")
    testing.expect(t,missing!=nil && strings.contains(core.problem_text(missing),"add one to the body"))
}


// A client takes only the bodies it owns, and lets go of one the server gave
// someone else (it became core.Remote) to drive the one it got instead.
@(test)
a_client_lets_go_of_what_the_server_took_and_takes_only_what_it_owns :: proc(t:^testing.T) {
    w:Test_Seats
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    seat,person,dog:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,seat,Seat{})
    core.add(&w.drivables,person,Drivable{seat=seat})
    core.add(&w.drivables,dog,Drivable{})
    core.add(&w.remotes,dog,core.Remote{})
    core.test_world_settle(&w)
    state:Seats
    problems:core.Problems
    a:=Apply{es=&w.entities,state=&state,drivables=&w.drivables,seats=&w.seats,role=.Client,elsewhere=core.read(&w.remotes),problems=&problems}

    request_apply(&a,{kind=.Drive,seat=seat,entity=dog})
    testing.expect_value(t,body_of(core.read(&w.drivables),seat),person)
    testing.expect(t,core.problem_find(&problems,seat,"input.server_decides")!=nil)

    // The server gives the dog to this client and the person to someone else.
    core.remove(&w.remotes,dog)
    core.add(&w.remotes,person,core.Remote{})
    core.test_world_settle(&w)
    a.elsewhere=core.read(&w.remotes)
    count:=problems.count
    request_apply(&a,{kind=.Release,seat=seat})
    request_apply(&a,{kind=.Drive,seat=seat,entity=dog})
    testing.expect_value(t,body_of(core.read(&w.drivables),seat),dog)
    testing.expect_value(t,seat_of(core.read(&w.drivables),person),core.NONE)
    testing.expect_value(t,problems.count,count)
}
