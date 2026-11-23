package camera

import "core:math"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import mm "mirai:std/math"

// What the seats read to drive their bodies and turn their cameras.
@(private)
@(test_world)
Drive_World :: struct {
    using world:Test_World,
    seats:core.Table(input.Seat),
    moves:core.Table(input.Move_Input),
    follows:core.Table(Camera_Follow),
    states:core.Table(Camera_Follow_State),
    cameras:core.Table(render.Camera),
    transforms:core.Table(core.Transform),
    worlds:core.Table(core.World_Transform),
    parents:core.Table(core.Parent),
    verticals:core.Table(core.Vertical),
    remotes:core.Table(core.Remote),
    hierarchy:core.Hierarchy,
    seat_state:input.Seats,
    seat_runtime:input.Seat_States,
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
    chosen:render.View_Camera,
    view_bodies:render.View_Bodies,
    slot_views:input.Slot_Views,
}

@(private="file") DRIVE_LOOK :: input.Action(0)
@(private="file") DRIVE_MOVE :: input.Action(1)

@(private="file")
drive_init :: proc(t:^testing.T,w:^Drive_World) -> bool {
    test_world_init(t,w) or_return
    input.input_map_action(&w.bindings,DRIVE_LOOK,.Axis2)
    input.input_map_action(&w.bindings,DRIVE_MOVE,.Axis2)
    return true
}

// A body at the origin facing -Z, driven by a seat that pushes forward,
// moved the look 10 points right and saw the game through view; with a camera
// of mode under it, or none.
@(private="file")
drive_body :: proc(w:^Drive_World,camera_rotation:mm.Quat,follow:Maybe(Camera_Follow),camera:=true,view:=input.Seat_View{}) -> (seat,body,eye:core.Entity) {
    seat,body=core.create(&w.entities),core.create(&w.entities)
    actions:input.Actions
    actions.count=2
    actions.states[DRIVE_LOOK].vector={10,0}
    actions.states[DRIVE_MOVE].vector={0,1}
    core.add(&w.seats,seat,input.Seat{slot=1,remote=true,body=body})
    input.seat_runtime_edit(&w.seat_runtime,seat).actions=actions
    input.seat_runtime_edit(&w.seat_runtime,seat).view=view
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
    test_world_settle(w)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
}

@(private="file")
drive_run :: proc(w:^Drive_World,problems:^core.Problems) {
    drive_settle(w)
    camera_drive(
        &w.moves,
        {state=core.ref(&w.seat_state),runtime=core.ref(&w.seat_runtime),seats=core.read(&w.seats),base=DRIVE_MOVE},
        {state=core.ref(&w.seat_state),runtime=core.ref(&w.seat_runtime),seats=core.read(&w.seats),base=DRIVE_LOOK},
        core.ref(&w.bindings),
        {sight={shown=core.ref(&w.shown),seats=core.read(&w.seats),cameras=core.read(&w.cameras),
                hierarchy=core.ref(&w.hierarchy),worlds=core.read(&w.worlds)},
         follows=core.read(&w.follows),parents=core.read(&w.parents),
         locals=core.read(&w.transforms),verticals=core.read(&w.verticals)},
        core.read(&w.remotes),problems,
    )
}

// Forward comes from what the seat sees: where the body looks for a camera
// that looks with it, which the look turns within its pitch limits, from where
// the camera it saw before looked when that one turned apart; where its view
// looks for another, and the body faces its move, whatever the cameras of this
// end did; -Z without a camera. What another end decides is left as it was.
@(test)
a_seat_drives_toward_the_forward_of_the_camera_it_sees :: proc(t:^testing.T) {
    w:=new(Drive_World)
    defer free(w)
    if !drive_init(t,w) {return}
    defer test_world_destroy(w)
    turned:=f32(0.5)-10*input.LOOK_SPEED
    with_body:=input.Seat_View{kind=.Body}
    // The camera of this end looks along -Z; the seat saw along +X.
    apart:=input.Seat_View{yaw=-math.PI/2,kind=.Apart}
    Case :: struct {name:string,follow:Maybe(Camera_Follow),camera:bool,view:input.Seat_View,yaw:f32,remote:bool,turn:f32}
    cases:=[]Case{
        {name="eyes",follow=Camera_Follow{mode=.Eyes},camera=true,view=with_body,yaw=turned},
        {name="an orbit that aims",follow=Camera_Follow{mode=.Orbit,aim=true},camera=true,view=with_body,yaw=turned},
        {name="an orbit that aims after one apart",follow=Camera_Follow{mode=.Orbit,aim=true},camera=true,view=apart,yaw=-math.PI/2-10*input.LOOK_SPEED},
        {name="a camera on the body",camera=true,view=with_body,yaw=turned},
        {name="an orbit",follow=Camera_Follow{mode=.Orbit,turn=true},camera=true,view=apart,yaw=-math.PI/2},
        {name="no camera",yaw=0},
        {name="ground that turns",follow=Camera_Follow{mode=.Eyes},camera=true,view=with_body,yaw=turned+0.1,turn=0.1},
        {name="another end decides it",follow=Camera_Follow{mode=.Eyes},camera=true,view=with_body,yaw=0.5,remote=true},
    }
    bodies:=make([]core.Entity,len(cases),context.temp_allocator)
    for c,i in cases {
        _,bodies[i],_=drive_body(w,1,c.follow,c.camera,c.view)
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

// Where the camera each local slot is drawn from looks, in the frame of the
// vertical of the body of its seat, is the view that seat takes for the next
// tick: apart from the body for a free orbit, with it for eyes; nothing past
// the local players.
@(test)
the_view_each_slot_draws_is_the_view_its_seat_takes :: proc(t:^testing.T) {
    w:=new(Drive_World)
    defer free(w)
    if !drive_init(t,w) {return}
    defer test_world_destroy(w)
    w.seat_state.local_count=2
    w.slot_views.views[2]={yaw=1,kind=.Apart}
    // The camera of the first looks along +X, a quarter turn right. The second's tilts 0.3 rad up
    // from -Z, on a body whose up is +X (it walks on a wall): about that up it looks 0.3 rad left,
    // level.
    rotations:=[2]mm.Quat{mm.quat_axis_angle({0,1,0},-math.PI/2),mm.quat_axis_angle({1,0,0},0.3)}
    follows:=[2]Camera_Follow{{mode=.Orbit,turn=true},{mode=.Eyes}}
    for slot in 0..<2 {
        seat,body,eye:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
        core.add(&w.seats,seat,input.Seat{slot=u8(slot),body=body})
        core.add(&w.worlds,body,core.World_Transform{transform={rotation=1,scale=1}})
        if slot==1 {core.add(&w.verticals,body,core.Vertical{frame=mm.quat_axis_angle({0,0,1},-math.PI/2)})}
        core.add(&w.parents,eye,core.Parent{entity=body})
        core.add(&w.cameras,eye,render.CAMERA_DEFAULT)
        core.add(&w.follows,eye,follows[slot])
        core.add(&w.worlds,eye,core.World_Transform{transform={rotation=rotations[slot],scale=1}})
    }
    drive_settle(w)
    input.input_seat_index(core.ref(&w.entities),core.read(&w.seats),&w.seat_state,nil)
    camera_blend(&w.views,core.ref(&w.shown),core.ref(&w.seat_state),core.read(&w.seats),core.read(&w.parents),core.ref(&w.hierarchy),
        core.read(&w.cameras),core.read(&w.follows),core.read(&w.states),core.read(&w.worlds),&w.chosen,&w.view_bodies,&w.slot_views,core.read(&w.verticals),{dt=1.0/60,alpha=1})
    first,second:=w.slot_views.views[0],w.slot_views.views[1]
    testing.expectf(t,first.kind==.Apart && abs(mm.angle_wrap(first.yaw+math.PI/2))<1e-4 && abs(first.pitch)<1e-4,"the free orbit: %v",first)
    testing.expectf(t,second.kind==.Body && abs(second.yaw-0.3)<1e-4 && abs(second.pitch)<1e-4,"the eyes: %v",second)
    testing.expect_value(t,w.slot_views.views[2],input.Seat_View{})
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
    defer test_world_destroy(w)
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
        core.add(&w.states,eyes[slot],Camera_Follow_State{ready=true})
        core.add(&w.follows,eyes[slot],follow)
    }
    // The pad of the second player looks right; the first one does nothing.
    w.frame.slots[1].count=1
    w.frame.slots[1].states[DRIVE_LOOK].vector={10,0}
    drive_settle(w)
    problems:core.Problems
    input.input_seat_index(core.ref(&w.entities),core.read(&w.seats),&w.seat_state,&problems)
    authored:=w.follows.version
    camera_follow(
        &w.follows,&w.states,&w.cameras,&w.transforms,
        {world=core.world_read(test_world_ref(w)),worlds=core.read(&w.worlds),parents=core.read(&w.parents),
         moves=core.read(&w.moves),shown=core.ref(&w.shown),
         look_actions={actions=core.ref(&w.frame),state=core.ref(&w.seat_state),runtime=core.ref(&w.seat_runtime),
                       seats=core.read(&w.seats),base=DRIVE_LOOK},
         queries=core.ref(&w.queries),verticals=core.read(&w.verticals)},
        &w.look_input,&w.changes,{dt=1.0/60,alpha=1},{dt=1.0/60},&problems,&w.shakes,
    )
    testing.expect(t,w.follows.version==authored && !core.table_has_edits(&w.follows),"following and turning leave the authored table untouched")
    first,_:=core.get(&w.states,eyes[0])
    second,_:=core.get(&w.states,eyes[1])
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
    defer test_world_destroy(w)
    turn:=mm.quat_axis_angle({0,1,0},mm.PI/2)
    seat,body,eye:=drive_body(w,turn,nil)
    drive_settle(w)
    core.edit(&w.worlds,eye).position={1,2,3}
    scope:=core.create(&w.entities)
    core.add(&w.cameras,scope,render.CAMERA_DEFAULT)
    core.add(&w.worlds,scope,core.World_Transform{transform={position={4,5,6},rotation=1,scale=1}})
    drive_settle(w)
    input.input_seat_index(core.ref(&w.entities),core.read(&w.seats),&w.seat_state,nil)
    sight:=Sight{core.ref(&w.shown),core.read(&w.seats),core.ref(&w.seat_state),core.read(&w.cameras),core.ref(&w.hierarchy),core.read(&w.worlds)}
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
    defer test_world_destroy(w)
    w.seat_state.local_count=1
    seat:=core.create(&w.entities)
    core.add(&w.seats,seat,input.Seat{})
    test_world_settle(w)
    commands:=core.commands(w,test_world_info(w))
    run :: proc(w:^Drive_World,commands:core.Commands) {
        camera_free(commands,&w.free,core.read(&w.seats),core.ref(&w.seat_state),&w.seat_requests,&w.cameras,&w.transforms,core.read(&w.moves),core.ref(&w.origin),core.ref(&w.network),{dt=0.5})
        test_world_settle(w)
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
    test_world_settle(w)
    run(w,commands)
    placed,_=core.get(&w.transforms,flown)
    testing.expectf(t,abs(placed.position.z-(3-FREE_CAMERA_SPEED*0.5))<1e-4,"its move flies it: %v",placed.position)
    body:=core.create(&w.entities)
    core.edit(&w.seats,seat).body=body
    test_world_settle(w)
    run(w,commands)
    testing.expect(t,!core.alive(&w.entities,flown) && w.free.entity==core.NONE,"driving a body of the game, it goes")
    core.edit(&w.seats,seat).body=core.NONE
    test_world_settle(w)
    run(w,commands)
    testing.expect(t,w.free.entity==core.NONE,"once it had a body, it gets no other free camera")
}
