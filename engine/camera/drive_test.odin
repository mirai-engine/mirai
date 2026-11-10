package camera

import "core:math"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import mm "mirai:std/math"

// What the seats read to drive their bodies and turn their cameras.
@(private="file")
Drive_World :: struct {
    using world:core.Test_World,
    seats:core.Table(input.Seat),
    moves:core.Table(input.Move_Input),
    follows:core.Table(Camera_Follow),
    cameras:core.Table(render.Camera),
    transforms:core.Table(core.Transform),
    worlds:core.Table(core.World_Transform),
    parents:core.Table(core.Parent),
    verticals:core.Table(core.Vertical),
    remotes:core.Table(core.Remote),
    hierarchy:core.Hierarchy,
    seat_state:input.Seats,
    shown:Cameras,
    views:Camera_Views,
    frame:input.Frame_Actions,
    look_input:Camera_Input,
    changes:Camera_Changes,
    shakes:Camera_Shakes,
    queries:core.World_Queries,
    bindings:input.Input_Map,
    free:Free_Camera,
    origin:scene.Play_Origin,
    seat_requests:input.Seat_Requests,
    network:core.Network,
}

@(private="file") DRIVE_LOOK :: input.Action(0)
@(private="file") DRIVE_MOVE :: input.Action(1)

@(private="file")
drive_init :: proc(t:^testing.T,w:^Drive_World) -> bool {
    core.test_world_init(t,w,test_types) or_return
    input.input_map_action(&w.bindings,DRIVE_LOOK,.Axis2)
    input.input_map_action(&w.bindings,DRIVE_MOVE,.Axis2)
    return true
}

// A body at the origin facing -Z, driven by a seat that pushes forward and
// moved the look 10 points right; with a camera of mode under it, or none.
@(private="file")
drive_body :: proc(w:^Drive_World,camera_rotation:mm.Quat,follow:Maybe(Camera_Follow),camera:=true) -> (seat,body,eye:core.Entity) {
    seat,body=core.create(&w.entities),core.create(&w.entities)
    actions:input.Actions
    actions.count=2
    actions.states[DRIVE_LOOK].vector={10,0}
    actions.states[DRIVE_MOVE].vector={0,1}
    core.add(&w.seats,seat,input.Seat{slot=1,peer=7,actions=actions,body=body})
    core.add(&w.worlds,body,core.World_Transform{transform={rotation=1,scale=1}})
    core.add(&w.moves,body,input.Move_Input{look_yaw=0.5})
    if !camera {return}
    eye=core.create(&w.entities)
    core.add(&w.parents,eye,core.Parent{entity=body})
    core.add(&w.cameras,eye,render.CAMERA_DEFAULT)
    core.add(&w.worlds,eye,core.World_Transform{transform={rotation=camera_rotation,scale=1}})
    if f,has:=follow.?;has {core.add(&w.follows,eye,f)}
    return
}

@(private="file")
drive_settle :: proc(w:^Drive_World) {
    core.test_world_settle(w)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
}

@(private="file")
drive_run :: proc(w:^Drive_World,problems:^core.Problems) {
    drive_settle(w)
    camera_drive(
        core.read(&w.seats),&w.moves,{state=core.ref(&w.seat_state),seats=core.read(&w.seats),base=DRIVE_MOVE},{state=core.ref(&w.seat_state),seats=core.read(&w.seats),base=DRIVE_LOOK},
        core.ref(&w.bindings),core.read(&w.follows),core.ref(&w.shown),core.read(&w.cameras),core.ref(&w.views),core.ref(&w.hierarchy),core.read(&w.parents),
        core.read(&w.transforms),core.read(&w.worlds),core.read(&w.verticals),core.read(&w.remotes),problems,
    )
}

// Forward comes from what the seat sees: where the body looks for a camera
// that looks with it, which the look turns within its pitch limits; where the
// camera looks for another, and the body faces its move; -Z without a camera.
// What another end decides is left as it was.
@(test)
a_seat_drives_toward_the_forward_of_the_camera_it_sees :: proc(t:^testing.T) {
    w:=new(Drive_World)
    defer free(w)
    if !drive_init(t,w) {return}
    defer core.test_world_destroy(w)
    turned:=f32(0.5)-10*input.LOOK_SPEED
    quarter:=mm.quat_axis_angle({0,1,0},-math.PI/2) // looks along +X
    Case :: struct {name:string,follow:Maybe(Camera_Follow),camera:bool,yaw:f32,remote:bool,turn:f32}
    cases:=[]Case{
        {name="eyes",follow=Camera_Follow{mode=.Eyes},camera=true,yaw=turned},
        {name="an orbit that aims",follow=Camera_Follow{mode=.Orbit,aim=true},camera=true,yaw=turned},
        {name="a camera on the body",camera=true,yaw=turned},
        {name="an orbit",follow=Camera_Follow{mode=.Orbit,turn=true},camera=true,yaw=-math.PI/2},
        {name="no camera",yaw=0},
        {name="ground that turns",follow=Camera_Follow{mode=.Eyes},camera=true,yaw=turned+0.1,turn=0.1},
        {name="another end decides it",follow=Camera_Follow{mode=.Eyes},camera=true,yaw=0.5,remote=true},
    }
    bodies:=make([]core.Entity,len(cases),context.temp_allocator)
    for c,i in cases {
        _,bodies[i],_=drive_body(w,quarter,c.follow,c.camera)
        if c.remote {core.add(&w.remotes,bodies[i],core.Remote{})}
        if c.turn!=0 {core.add(&w.verticals,bodies[i],core.Vertical{frame=1,turn=c.turn})}
    }
    problems:core.Problems
    drive_run(w,&problems)
    for c,i in cases {
        move,_:=core.get(&w.moves,bodies[i])
        testing.expectf(t,abs(mm.angle_wrap(move.look_yaw-c.yaw))<1e-4,"%s: it looks at yaw %v, not %v",c.name,move.look_yaw,c.yaw)
        ahead:=c.remote?[3]f32{}:mm.quat_rotate(mm.quat_axis_angle({0,1,0},c.yaw),[3]f32{0,0,-1})
        testing.expectf(t,linalg_close(move.move,ahead),"%s: it goes %v, not %v",c.name,move.move,ahead)
    }
    testing.expect_value(t,problems.count,0)

    // A look that is no Axis2 in the input map is a problem of the body, which is left as it was.
    input.input_map_action(&w.bindings,DRIVE_LOOK,.Button)
    before,_:=core.get(&w.moves,bodies[0])
    drive_run(w,&problems)
    after,_:=core.get(&w.moves,bodies[0])
    testing.expect(t,after==before && core.problem_find(&problems,bodies[0],"camera.seat_actions")!=nil)
}

@(private="file")
linalg_close :: proc(a,b:[3]f32) -> bool {return abs(a.x-b.x)<1e-4 && abs(a.y-b.y)<1e-4 && abs(a.z-b.z)<1e-4}

// With several players at the machine, the orbit of each turns with the look
// of its own seat alone, from the devices of its slot.
@(test)
each_orbit_turns_with_the_look_of_its_own_seat :: proc(t:^testing.T) {
    w:=new(Drive_World)
    defer free(w)
    if !drive_init(t,w) {return}
    defer core.test_world_destroy(w)
    w.seat_state.local_count=2
    eyes:[2]core.Entity
    for slot in 0..<2 {
        seat,body:=core.create(&w.entities),core.create(&w.entities)
        core.add(&w.seats,seat,input.Seat{slot=u8(slot),body=body})
        core.add(&w.worlds,body,core.World_Transform{transform={position={f32(slot)*10,0,0},rotation=1,scale=1}})
        eyes[slot]=core.create(&w.entities)
        core.add(&w.parents,eyes[slot],core.Parent{entity=body})
        core.add(&w.cameras,eyes[slot],render.CAMERA_DEFAULT)
        core.add(&w.transforms,eyes[slot],core.Transform{rotation=1,scale=1})
        follow:=Camera_Follow{mode=.Orbit,turn=true,distance=4}
        follow.state.ready=true
        core.add(&w.follows,eyes[slot],follow)
    }
    // The pad of the second player looks right; the first one does nothing.
    w.frame.slots[1].count=1
    w.frame.slots[1].states[DRIVE_LOOK].vector={10,0}
    drive_settle(w)
    problems:core.Problems
    camera_follow(
        core.test_world_ref(w),&w.follows,&w.cameras,&w.transforms,core.read(&w.worlds),core.read(&w.parents),core.read(&w.seats),core.read(&w.moves),core.ref(&w.shown),
        core.ref(&w.seat_state),{actions=core.ref(&w.frame),state=core.ref(&w.seat_state),seats=core.read(&w.seats),base=DRIVE_LOOK},core.ref(&w.queries),&w.look_input,&w.changes,
        core.ref(&w.views),core.read(&w.verticals),{dt=1.0/60,alpha=1},{dt=1.0/60},&problems,&w.shakes,
    )
    first,_:=core.get(&w.follows,eyes[0])
    second,_:=core.get(&w.follows,eyes[1])
    testing.expectf(t,first.looking.x==0,"the first orbit stays: %v",first.looking)
    testing.expectf(t,abs(second.looking.x+10*input.LOOK_SPEED)<1e-5,"the second turns with its own pad: %v",second.looking)
}

// The aim of a player is the ray of the camera it sees through: that of its
// body, or of an override (an aim camera) while it stands.
@(test)
aim_is_the_ray_of_the_camera_the_player_sees :: proc(t:^testing.T) {
    w:=new(Drive_World)
    defer free(w)
    if !drive_init(t,w) {return}
    defer core.test_world_destroy(w)
    turn:=mm.quat_axis_angle({0,1,0},mm.PI/2)
    seat,body,eye:=drive_body(w,turn,nil)
    drive_settle(w)
    core.edit(&w.worlds,eye).position={1,2,3}
    scope:=core.create(&w.entities)
    core.add(&w.cameras,scope,render.CAMERA_DEFAULT)
    core.add(&w.worlds,scope,core.World_Transform{transform={position={4,5,6},rotation=1,scale=1}})
    drive_settle(w)
    sight:=Sight{core.ref(&w.shown),core.read(&w.seats),core.read(&w.cameras),core.ref(&w.hierarchy),core.read(&w.worlds)}
    origin,direction,ok:=aim(sight,body)
    testing.expect(t,ok && origin==[3]f32{1,2,3})
    testing.expectf(t,abs(direction.x+1)<1e-5 && abs(direction.z)<1e-5,"a quarter turn to the left looks along -X: %v",direction)
    testing.expect(t,override_set(&w.shown,{owner=scope,seat=seat,camera=scope}))
    origin,direction,ok=aim(sight,body)
    testing.expect(t,ok && origin==[3]f32{4,5,6} && abs(direction.z+1)<1e-5,"through the override it aims")
    _,_,ok=aim(sight,core.create(&w.entities))
    testing.expect(t,!ok,"a body nobody drives has no aim")
}

// In the Play of the editor, player 1 without a body flies a camera from where
// the editor looked, until it drives a body of the game; never in a game, nor
// with an active camera in the scene.
@(test)
player_1_without_a_body_flies_a_free_camera_in_play :: proc(t:^testing.T) {
    w:=new(Drive_World)
    defer free(w)
    if !drive_init(t,w) {return}
    defer core.test_world_destroy(w)
    w.seat_state.local_count=1
    seat:=core.create(&w.entities)
    core.add(&w.seats,seat,input.Seat{})
    core.test_world_settle(w)
    commands:=core.commands(w,core.test_world_info(w))
    run :: proc(w:^Drive_World,commands:core.Commands) {
        camera_free(commands,&w.free,core.read(&w.seats),core.ref(&w.seat_state),&w.seat_requests,&w.cameras,&w.transforms,core.read(&w.moves),core.ref(&w.origin),core.ref(&w.network),core.ref(&w.hierarchy),{dt=0.5})
        core.test_world_settle(w)
    }
    run(w,commands)
    testing.expect(t,w.free.entity==core.NONE,"a game without the Play of the editor has none")
    w.origin={position={1,2,3},rotation=1,set=true}
    run(w,commands)
    flown:=w.free.entity
    placed,_:=core.get(&w.transforms,flown)
    testing.expect(t,flown!=core.NONE && core.has(&w.cameras,flown) && placed.position==[3]f32{1,2,3},"it starts where the editor looked")
    asked:=core.take(&w.seat_requests.queue)
    testing.expect(t,len(asked)==1 && asked[0]==input.Seat_Request{kind=.Drive,seat=seat,entity=flown})
    core.edit(&w.seats,seat).body=flown
    core.add(&w.moves,flown,input.Move_Input{move={0,0,-1}})
    core.test_world_settle(w)
    run(w,commands)
    placed,_=core.get(&w.transforms,flown)
    testing.expectf(t,abs(placed.position.z-(3-FREE_CAMERA_SPEED*0.5))<1e-4,"its move flies it: %v",placed.position)
    body:=core.create(&w.entities)
    core.edit(&w.seats,seat).body=body
    core.test_world_settle(w)
    run(w,commands)
    testing.expect(t,!core.alive(&w.entities,flown) && w.free.entity==core.NONE,"driving a body of the game, it goes")
    core.edit(&w.seats,seat).body=core.NONE
    core.test_world_settle(w)
    run(w,commands)
    testing.expect(t,w.free.entity==core.NONE,"once it had a body, it gets no other free camera")
}
