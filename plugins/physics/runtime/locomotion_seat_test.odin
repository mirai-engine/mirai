package physics

import "core:math"
import "core:testing"
import "mirai:core"
import cam "mirai:engine/camera"
import input "mirai:engine/input"
import render "mirai:engine/render"
import mm "mirai:std/math"

@(private="file")
Seat_Test :: struct {
    es:core.Entities,
    characters:core.Table(Character),
    moves:core.Table(input.Move_Input),
    states:core.Table(Character_State),
    drivables:core.Table(input.Drivable),
    seats:core.Table(input.Seat),
    worlds:core.Table(core.World_Transform),
    remotes:core.Table(core.Remote),
    follows:core.Table(cam.Camera_Follow),
    cameras:core.Table(render.Camera),
    shown:cam.Cameras,
    bindings:input.Input_Map,
    problems:core.Problems,
}

@(private="file")
seat_test_init :: proc(f:^Seat_Test) {
    core.entities_init(&f.es)
    core.table_init(&f.characters,"Character")
    core.table_init(&f.moves,"Move_Input")
    core.table_init(&f.states,"Character_State")
    core.table_init(&f.drivables,"Drivable")
    core.table_init(&f.seats,"Seat")
    core.table_init(&f.worlds,"World_Transform")
    core.table_init(&f.remotes,"Remote")
    core.table_init(&f.follows,"Camera_Follow")
    core.table_init(&f.cameras,"Camera")
}

@(private="file")
seat_test_destroy :: proc(f:^Seat_Test) {
    core.table_destroy(&f.characters)
    core.table_destroy(&f.moves)
    core.table_destroy(&f.states)
    core.table_destroy(&f.drivables)
    core.table_destroy(&f.seats)
    core.table_destroy(&f.worlds)
    core.table_destroy(&f.remotes)
    core.table_destroy(&f.follows)
    core.table_destroy(&f.cameras)
    core.entities_destroy(&f.es)
}

@(private="file")
seat_test_settle :: proc(f:^Seat_Test) {
    core.table_settle(&f.characters,&f.es)
    core.table_settle(&f.moves,&f.es)
    core.table_settle(&f.states,&f.es)
    core.table_settle(&f.drivables,&f.es)
    core.table_settle(&f.seats,&f.es)
    core.table_settle(&f.worlds,&f.es)
    core.table_settle(&f.remotes,&f.es)
    core.table_settle(&f.follows,&f.es)
    core.table_settle(&f.cameras,&f.es)
}

@(private="file")
seat_test_run :: proc(f:^Seat_Test) {
    walk:=input.Input_Of(Walk_Action){seats=core.read(&f.seats),drivables=core.read(&f.drivables),base=TEST_WALK_BASE}
    look:=input.Input_Of(input.Look_Action){seats=core.read(&f.seats),drivables=core.read(&f.drivables)}
    locomotion_seat(core.read(&f.characters),&f.moves,core.read(&f.states),core.read(&f.drivables),walk,look,core.ref(&f.bindings),core.read(&f.follows),core.ref(&f.shown),core.read(&f.cameras),core.read(&f.worlds),core.read(&f.remotes),{},{},{playing=true,dt=1.0/60},core.CLOCK_DEFAULT,&f.problems)
}

// A character facing -X (yaw π/2, as locomotion_step leaves the look of one that stands so) and its Move_Input.
@(private="file")
seat_test_body :: proc(f:^Seat_Test,relative:=Move_Relative.Look) -> core.Entity {
    e:=core.create(&f.es)
    c:=character_default()
    c.move_relative_to,c.ready,c.turn_speed=relative,true,0
    core.add(&f.characters,e,c)
    core.add(&f.moves,e,input.Move_Input{look_yaw=math.PI/2})
    return e
}

// A seat that holds W and Space and moved the mouse 10 points right.
@(private="file")
seat_test_seat :: proc(f:^Seat_Test) -> core.Entity {
    seat:=core.create(&f.es)
    core.add(&f.seats,seat,input.Seat{})
    core.table_settle(&f.seats,&f.es)
    device:=core.Input{keys_down={.W,.Space},keys_pressed={.W,.Space},mouse_delta={10,0}}
    input.seat_feed(core.get(&f.seats,seat),&device,&f.bindings,false)
    return seat
}

// The input map of a world whose code declares the walk actions, without input.mirai.
@(private="file")
seat_test_map :: proc(m:^input.Input_Map,problems:^core.Problems) {
    names:=[]core.Name_Info{{type=input.Action,value=0,name="look"},{type=input.Action,value=i64(TEST_MOVE),name="move"},{type=input.Action,value=i64(TEST_JUMP),name="jump"},{type=input.Action,value=i64(TEST_SPRINT),name="sprint"},{type=input.Action,value=i64(TEST_CROUCH),name="crouch"}}
    storages:=[]core.Storage_Info{
        {name="Walk_Actions",type=Walk_Actions,info=type_info_of(Walk_Actions),default=proc(dst:rawptr) {(cast(^Walk_Actions)dst)^=walk_actions_default()}},
        {name="Look_Actions",type=input.Look_Actions,info=type_info_of(input.Look_Actions),default=proc(dst:rawptr) {(cast(^input.Look_Actions)dst)^=input.look_actions_default()}},
    }
    actions:=[]core.Actions_Info{{type=input.Look_Action,info=type_info_of(input.Look_Action)},{type=Walk_Action,info=type_info_of(Walk_Action),base=i64(TEST_WALK_BASE)}}
    info:=core.World_Info{names=names,storages=storages,actions=actions}
    input.input_map_make(m,&info,"","",problems)
}

// The walk actions have their defaults in the map without a step that declares them.
@(test)
a_seat_walks_the_character_it_drives_and_leaves_the_others :: proc(t:^testing.T) {
    f:=new(Seat_Test)
    defer free(f)
    seat_test_init(f)
    defer seat_test_destroy(f)
    seat_test_map(&f.bindings,&f.problems)

    driven,idle,remote,by_game:=seat_test_body(f),seat_test_body(f),seat_test_body(f),seat_test_body(f,.Game)
    seat,other,third:=seat_test_seat(f),seat_test_seat(f),seat_test_seat(f)
    core.add(&f.drivables,driven,input.Drivable{seat=seat})
    core.add(&f.drivables,remote,input.Drivable{seat=other})
    core.add(&f.drivables,by_game,input.Drivable{seat=third})
    core.add(&f.remotes,remote,core.Remote{})
    core.add(&f.states,driven,Character_State{ground_turn=0.1})
    seat_test_settle(f)
    seat_test_run(f)

    walked,_:=core.get(core.read(&f.moves),driven)
    wanted:=f32(math.PI/2)+0.1-10*input.LOOK_SPEED
    testing.expect(t,abs(walked.look_yaw-wanted)<1e-4)
    testing.expect_value(t,walked.move,[3]f32{0,0,-1})
    testing.expect_value(t,walked.buttons,input.action_bit(TEST_JUMP))
    for e in ([3]core.Entity{idle,remote,by_game}) {
        left,_:=core.get(core.read(&f.moves),e)
        testing.expect_value(t,left,input.Move_Input{look_yaw=math.PI/2})
    }
    testing.expect_value(t,f.problems.count,0)
}

// Relative to the camera, forward is where the camera looks, and the
// character turns toward it; relative to the world, forward is -Z.
@(test)
a_seat_walks_toward_where_the_camera_or_the_world_says :: proc(t:^testing.T) {
    f:=new(Seat_Test)
    defer free(f)
    seat_test_init(f)
    defer seat_test_destroy(f)
    seat_test_map(&f.bindings,&f.problems)

    followed,mapped:=seat_test_body(f,.Camera),seat_test_body(f,.World)
    camera:=core.create(&f.es)
    core.add(&f.worlds,camera,core.World_Transform{rotation=mm.quat_axis_angle({0,1,0},-math.PI/2),scale=1})
    core.add(&f.drivables,followed,input.Drivable{seat=seat_test_seat(f),camera=camera})
    core.add(&f.drivables,mapped,input.Drivable{seat=seat_test_seat(f)})
    seat_test_settle(f)
    seat_test_run(f)

    turned,_:=core.get(core.read(&f.moves),followed)
    testing.expectf(t,abs(turned.look_yaw+math.PI/2)<1e-4,"it faces where the camera looks: %v",turned.look_yaw)
    testing.expectf(t,abs(turned.move.z+1)<1e-4 && abs(turned.move.x)<1e-4,"and walks forward: %v",turned.move)
    north,_:=core.get(core.read(&f.moves),mapped)
    testing.expectf(t,abs(north.look_yaw)<1e-4 && abs(north.move.z+1)<1e-4,"it walks to -Z of the world: %v",north)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
a_seat_walks_as_the_mode_of_its_camera_wants :: proc(t:^testing.T) {
    f:=new(Seat_Test)
    defer free(f)
    seat_test_init(f)
    defer seat_test_destroy(f)
    seat_test_map(&f.bindings,&f.problems)

    eyes,orbit:=seat_test_body(f,.View),seat_test_body(f,.View)
    for body,i in ([2]core.Entity{eyes,orbit}) {
        camera:=core.create(&f.es)
        core.add(&f.worlds,camera,core.World_Transform{rotation=mm.quat_axis_angle({0,1,0},-math.PI/2),scale=1})
        core.add(&f.follows,camera,cam.Camera_Follow{mode=i==0?.Eyes:.Orbit})
        core.add(&f.drivables,body,input.Drivable{seat=seat_test_seat(f),camera=camera})
    }
    seat_test_settle(f)
    seat_test_run(f)

    looked,_:=core.get(core.read(&f.moves),eyes)
    testing.expectf(t,abs(looked.look_yaw-(math.PI/2-10*input.LOOK_SPEED))<1e-4 && abs(looked.move.z+1)<1e-4,"a camera at its eyes: it turns with the look: %v",looked)
    turned,_:=core.get(core.read(&f.moves),orbit)
    testing.expectf(t,abs(turned.look_yaw+math.PI/2)<1e-4,"a free camera: it faces where the camera looks: %v",turned.look_yaw)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
a_seat_without_the_walk_actions_is_a_problem :: proc(t:^testing.T) {
    f:=new(Seat_Test)
    defer free(f)
    seat_test_init(f)
    defer seat_test_destroy(f)
    input.input_map_action(&f.bindings,TEST_MOVE,.Axis2)
    input.input_map_action(&f.bindings,0,.Button)

    body:=seat_test_body(f)
    seat:=seat_test_seat(f)
    core.add(&f.drivables,body,input.Drivable{seat=seat})
    seat_test_settle(f)
    seat_test_run(f)

    testing.expect_value(t,f.problems.count,1)
    testing.expect(t,core.problem_find(&f.problems,body,"locomotion.seat_action")!=nil)
    walked,_:=core.get(core.read(&f.moves),body)
    testing.expect_value(t,walked,input.Move_Input{look_yaw=math.PI/2})
}
