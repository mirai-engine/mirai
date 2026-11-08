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
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    drivables:core.Table(Drivable)
    core.table_init(&drivables,"Drivable")
    defer core.table_destroy(&drivables)
    worlds:core.Table(core.World_Transform)
    core.table_init(&worlds,"World_Transform")
    defer core.table_destroy(&worlds)
    body,camera,bare:=core.create(&es),core.create(&es),core.create(&es)
    turn:=mm.quat_axis_angle({0,1,0},mm.PI/2)
    core.add(&drivables,body,Drivable{camera=camera})
    core.add(&drivables,bare,Drivable{})
    core.add(&worlds,camera,core.World_Transform{transform={position={1,2,3},rotation=turn,scale={1,1,1}}})
    core.table_settle(&drivables,&es)
    core.table_settle(&worlds,&es)
    origin,direction,ok:=aim(core.read(&drivables),core.read(&worlds),body)
    testing.expect(t,ok && origin==[3]f32{1,2,3})
    testing.expectf(t,abs(direction.x+1)<1e-5 && abs(direction.z)<1e-5,"a quarter turn to the left looks along -X: %v",direction)
    _,_,ok=aim(core.read(&drivables),core.read(&worlds),bare)
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
    seat_feed(&first,&own,&bindings,false)
    own=slot_input(device,1,2,0)
    seat_feed(&second,&own,&bindings,false)
    testing.expect(t,action(&first.actions,TEST_JUMP).pressed)
    testing.expect(t,action(&second.actions,TEST_JUMP).pressed)
}

@(test)
focus_and_driving_wait_for_held_buttons :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    first,second,body:=core.create(&es),core.create(&es),core.create(&es)
    bindings:=test_bindings()
    drivables:core.Table(Drivable)
    core.table_init(&drivables,"Drivable")
    seats:core.Table(Seat)
    core.table_init(&seats,"Seat")
    defer core.table_destroy(&seats)
    core.add(&seats,first,Seat{})
    core.add(&seats,second,Seat{slot=1})
    core.table_settle(&seats,&es)
    defer core.table_destroy(&drivables)
    core.add(&drivables,body,Drivable{})
    core.table_settle(&drivables,&es)
    state:Seats
    problems:core.Problems
    a:=Apply{es=&es,state=&state,drivables=&drivables,seats=&seats,problems=&problems}
    read:=Input_Of(Seat_Test_Action){seats=core.read(&seats),drivables=core.read(&drivables)}

    // Space and W held while the keyboard is with the first player.
    device:=core.Input{keys_down={.Space,.W},keys_pressed={.Space,.W}}
    tick :: proc(seats:^core.Table(Seat),first,second:core.Entity,device:core.Input,focus:int,bindings:^Input_Map,moved:=false) {
        for e,slot in ([2]core.Entity{first,second}) {
            own:=slot_input(device,slot,2,focus)
            seat_feed(core.get(seats,e),&own,bindings,moved && slot==focus)
        }
    }
    tick(&seats,first,second,device,0,&bindings)
    testing.expect(t,seat_pressed(read,first,.Jump))
    testing.expect(t,!seat_down(read,second,.Jump))

    // The keyboard moves to the second player: the first sees the release,
    // the second waits for it; the axis moves on at once.
    device.keys_pressed={}
    tick(&seats,first,second,device,1,&bindings,true)
    testing.expect(t,seat_released(read,first,.Jump))
    testing.expect(t,!seat_down(read,second,.Jump))
    testing.expect(t,seat_vector(read,second,.Move)==[2]f32{0,1})

    device={keys_released={.Space,.W}}
    tick(&seats,first,second,device,1,&bindings)
    device={keys_down={.Space},keys_pressed={.Space}}
    tick(&seats,first,second,device,1,&bindings)
    testing.expect(t,seat_pressed(read,second,.Jump))

    // Driving a body while jump is held: it waits for its release.
    device.keys_pressed={}
    tick(&seats,first,second,device,1,&bindings)
    request_apply(&a,{kind=.Drive,seat=second,entity=body})
    testing.expect(t,seat_of(core.read(&drivables),body)==second)
    testing.expect(t,!seat_down(read,second,.Jump))
    device={keys_released={.Space}}
    tick(&seats,first,second,device,1,&bindings)
    device={keys_down={.Space},keys_pressed={.Space}}
    tick(&seats,first,second,device,1,&bindings)
    testing.expect(t,seat_pressed(read,second,.Jump))

    // A block takes the action; once given back, the held button waits for its release.
    request_apply(&a,{kind=.Block_Add,owner=body,seat=second,mask=ALL_ACTIONS})
    blocks_apply(&seats,&state)
    testing.expect(t,!seat_down(read,second,.Jump))
    testing.expect(t,!pressed(read,body,.Jump))
    request_apply(&a,{kind=.Block_Remove,owner=body})
    blocks_apply(&seats,&state)
    testing.expect(t,!seat_down(read,second,.Jump))
    device={keys_released={.Space}}
    tick(&seats,first,second,device,1,&bindings)
    device={keys_down={.Space},keys_pressed={.Space}}
    tick(&seats,first,second,device,1,&bindings)
    testing.expect(t,pressed(read,body,.Jump))
    testing.expect_value(t,problems.count,0)
}

@(test)
a_block_of_no_seat_takes_every_local_seat :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    first,second,remote,menu:=core.create(&es),core.create(&es),core.create(&es),core.create(&es)
    bindings:=test_bindings()
    drivables:core.Table(Drivable)
    core.table_init(&drivables,"Drivable")
    defer core.table_destroy(&drivables)
    seats:core.Table(Seat)
    core.table_init(&seats,"Seat")
    defer core.table_destroy(&seats)
    core.add(&seats,first,Seat{})
    core.add(&seats,second,Seat{slot=1})
    core.add(&seats,remote,Seat{peer=7})
    core.table_settle(&seats,&es)
    state:Seats
    problems:core.Problems
    a:=Apply{es=&es,state=&state,drivables=&drivables,seats=&seats,problems=&problems}
    read:=Input_Of(Seat_Test_Action){seats=core.read(&seats),drivables=core.read(&drivables)}
    blocked :: proc(seats:^core.Table(Seat),e:core.Entity) -> Action_Mask {return seats.values[core.row_of(seats,e)].blocked}
    device:=core.Input{keys_down={.Space},keys_pressed={.Space}}
    seat_feed(core.get(&seats,first),&device,&bindings,false)
    request_apply(&a,{kind=.Block_Add,owner=menu,mask=ALL_ACTIONS})
    blocks_apply(&seats,&state)
    testing.expect(t,blocking(&state,menu))
    testing.expect(t,blocked(&seats,first)==ALL_ACTIONS && blocked(&seats,second)==ALL_ACTIONS)
    testing.expect_value(t,blocked(&seats,remote),Action_Mask(0))
    testing.expect(t,!seat_down(read,first,.Jump))
    // Its owner still gets what it takes, until another owner takes it too.
    testing.expect(t,seat_action_for(&state,core.read(&seats),first,TEST_JUMP,menu).pressed)
    cinematic:=core.create(&es)
    request_apply(&a,{kind=.Block_Add,owner=cinematic,seat=first,mask=action_bit(TEST_JUMP)})
    blocks_apply(&seats,&state)
    testing.expect(t,!seat_action_for(&state,core.read(&seats),first,TEST_JUMP,menu).down)
    request_apply(&a,{kind=.Block_Remove,owner=cinematic})
    blocks_apply(&seats,&state)
    // Given back, the button held through the block waits for its release.
    request_apply(&a,{kind=.Block_Remove,owner=menu})
    blocks_apply(&seats,&state)
    testing.expect(t,blocked(&seats,first)==0 && !seat_down(read,first,.Jump))
    // The owner goes: so does its block.
    request_apply(&a,{kind=.Block_Add,owner=menu,mask=ALL_ACTIONS})
    core.destroy(&es,menu)
    upkeep(&a)
    blocks_apply(&seats,&state)
    testing.expect(t,!blocking(&state,menu) && blocked(&seats,second)==0)
    testing.expect_value(t,problems.count,0)
}

@(test)
refused_drives_report_the_seat_and_how_to_fix_them :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    first,second,body,prop:=core.create(&es),core.create(&es),core.create(&es),core.create(&es)
    drivables:core.Table(Drivable)
    core.table_init(&drivables,"Drivable")
    seats:core.Table(Seat)
    core.table_init(&seats,"Seat")
    defer core.table_destroy(&seats)
    core.add(&seats,first,Seat{})
    core.add(&seats,second,Seat{slot=1})
    core.table_settle(&seats,&es)
    defer core.table_destroy(&drivables)
    core.add(&drivables,body,Drivable{})
    core.table_settle(&drivables,&es)
    state:Seats
    problems:core.Problems
    a:=Apply{es=&es,state=&state,drivables=&drivables,seats=&seats,problems=&problems}

    request_apply(&a,{kind=.Drive,seat=first,entity=body})
    request_apply(&a,{kind=.Drive,seat=second,entity=body})
    request_apply(&a,{kind=.Drive,seat=second,entity=body})
    request_apply(&a,{kind=.Drive,seat=second,entity=prop})
    testing.expect_value(t,seat_of(core.read(&drivables),body),first)
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
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    seat,person,dog:=core.create(&es),core.create(&es),core.create(&es)
    drivables:core.Table(Drivable)
    seats:core.Table(Seat)
    remotes:core.Table(core.Remote)
    core.table_init(&drivables,"Drivable")
    core.table_init(&seats,"Seat")
    core.table_init(&remotes,"Remote")
    defer core.table_destroy(&drivables)
    defer core.table_destroy(&seats)
    defer core.table_destroy(&remotes)
    core.add(&seats,seat,Seat{})
    core.add(&drivables,person,Drivable{seat=seat})
    core.add(&drivables,dog,Drivable{})
    core.add(&remotes,dog,core.Remote{})
    core.table_settle(&seats,&es)
    core.table_settle(&drivables,&es)
    core.table_settle(&remotes,&es)
    state:Seats
    problems:core.Problems
    a:=Apply{es=&es,state=&state,drivables=&drivables,seats=&seats,role=.Client,elsewhere=core.read(&remotes),problems=&problems}

    request_apply(&a,{kind=.Drive,seat=seat,entity=dog})
    testing.expect_value(t,body_of(core.read(&drivables),seat),person)
    testing.expect(t,core.problem_find(&problems,seat,"input.server_decides")!=nil)

    // The server gives the dog to this client and the person to someone else.
    core.remove(&remotes,dog)
    core.add(&remotes,person,core.Remote{})
    core.table_settle(&remotes,&es)
    a.elsewhere=core.read(&remotes)
    count:=problems.count
    request_apply(&a,{kind=.Release,seat=seat})
    request_apply(&a,{kind=.Drive,seat=seat,entity=dog})
    testing.expect_value(t,body_of(core.read(&drivables),seat),dog)
    testing.expect_value(t,seat_of(core.read(&drivables),person),core.NONE)
    testing.expect_value(t,problems.count,count)
}
