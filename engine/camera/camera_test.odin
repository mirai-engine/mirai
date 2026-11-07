package camera

import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"

@(private="file")
Camera_Test :: struct {
    es:core.Entities,
    cameras:core.Table(render.Camera),
    follows:core.Table(Camera_Follow),
    worlds:core.Table(core.World_Transform),
    problems:core.Problems,
}

@(private="file")
test_make :: proc() -> ^Camera_Test {
    f:=new(Camera_Test)
    core.entities_init(&f.es)
    core.table_init(&f.cameras,"Camera")
    core.table_init(&f.follows,"Camera_Follow")
    core.table_init(&f.worlds,"World_Transform")
    return f
}

@(private="file")
test_free :: proc(f:^Camera_Test) {
    core.table_destroy(&f.worlds)
    core.table_destroy(&f.follows)
    core.table_destroy(&f.cameras)
    core.entities_destroy(&f.es)
    free(f)
}

@(private="file")
test_settle :: proc(f:^Camera_Test) {
    core.table_settle(&f.cameras,&f.es)
    core.table_settle(&f.follows,&f.es)
    core.table_settle(&f.worlds,&f.es)
}

@(private="file")
test_place :: proc(f:^Camera_Test,e:core.Entity,position:[3]f32,rotation:=mm.Quat(1)) {
    placed:=core.World_Transform{transform={position=position,rotation=rotation,scale={1,1,1}}}
    placed.previous=placed.transform
    if row:=core.get(&f.worlds,e);row!=nil {row^=placed} else {core.add(&f.worlds,e,placed)}
}

@(private="file")
close :: proc(a,b:f32,epsilon:f32=1e-3) -> bool {return abs(a-b)<=epsilon}

@(private="file")
close_vec :: proc(a,b:[3]f32,epsilon:f32=1e-3) -> bool {return linalg.length(a-b)<=epsilon}

@(private="file")
has_problem :: proc(problems:^core.Problems,code:string) -> bool {
    for &p in problems.entries[:problems.count] {
        if base.text_equal(p.code[:],code) {return true}
    }
    return false
}

@(test)
every_preset_is_a_setup_a_camera_takes :: proc(t:^testing.T) {
    for preset in Camera_Preset {
        testing.expectf(t,setup_invalid(camera_preset(preset))=="","%v: %s",preset,setup_invalid(camera_preset(preset)))
    }
    iso:=camera_preset(.Isometric)
    testing.expect(t,iso.lens.projection==.Orthographic && iso.follow.min_pitch==iso.follow.max_pitch)
    testing.expect(t,close(math.tan(f32(ISOMETRIC_PITCH)),1/math.sqrt(f32(2))),"the isometric pitch sees a cube along its diagonal")
}

@(test)
a_camera_above_the_walls_it_sees_is_not_pulled_in_by_them :: proc(t:^testing.T) {
    for preset in ([]Camera_Preset{.Isometric,.Top_Down}) {
        follow:=camera_preset(preset).follow
        testing.expectf(t,follow.probe_radius==0,"%v looks down from above what it sees: it does not probe the world",preset)
    }
}

@(test)
a_blend_changes_the_layers_when_the_view_arrives_not_when_it_leaves :: proc(t:^testing.T) {
    from:=render.View_Pose{rotation=mm.Quat(1),fov=1,near=0.1,far=100}
    to:=from
    to.layers=~HEAD_LAYER
    testing.expect(t,pose_mix(from,to,{},false,0.5).layers==0,"the head stays while the camera goes to the eyes")
    to.own_hidden=HEAD_LAYER
    testing.expect(t,pose_mix(from,to,{},false,0.5).own_hidden==0 && pose_mix(from,to,{},false,1).own_hidden==HEAD_LAYER,"the own head leaves when the camera is at the eyes")
    testing.expect(t,pose_mix(from,to,{},false,1).layers==~HEAD_LAYER,"the head leaves when the camera is at the eyes")
    from,to=to,from
    testing.expect(t,pose_mix(from,to,{},false,0.5).layers==~HEAD_LAYER,"the head waits while the camera leaves the eyes")
    testing.expect(t,pose_mix(from,to,{},false,1).layers==0,"the head comes back when the camera is out")
}

@(test)
a_mode_is_taken_once_keeps_the_target_and_counts_for_the_views :: proc(t:^testing.T) {
    f:=test_make()
    defer test_free(f)
    camera,body:=core.create(&f.es),core.create(&f.es)
    core.add(&f.cameras,camera,render.CAMERA_DEFAULT)
    core.add(&f.follows,camera,Camera_Follow{target=body,mode=.Follow})
    // The camera looks with a yaw of 1 and a pitch of 0.2, as an Orbit does.
    test_place(f,camera,{},orbit_rotation(orbit_make({},4,1,0.2)))
    test_settle(f)

    third:=camera_preset(.Third_Person)
    mode_take(&f.follows,&f.cameras,core.read(&f.worlds),{camera,third,{0.5,.Linear}},&f.problems)
    follow:=core.get(&f.follows,camera)
    want:=third.follow
    want.target=body
    testing.expect(t,camera_follow_config(follow^)==camera_follow_config(want),"it takes the setup and keeps its target")
    testing.expect(t,follow.state.changes==1 && follow.state.blend.seconds==0.5)
    testing.expect(t,follow.state.handing && close(follow.state.handoff.x,1) && close(follow.state.handoff.y,0.2),"a free Orbit goes on from where the camera looked")
    lens,_:=core.get(core.read(&f.cameras),camera)
    testing.expect(t,lens_of(lens)==third.lens)

    mode_take(&f.follows,&f.cameras,core.read(&f.worlds),{camera,third,{0.5,.Linear}},&f.problems)
    testing.expect(t,follow.state.changes==1,"the mode it has does nothing")

    mode_take(&f.follows,&f.cameras,core.read(&f.worlds),{camera,camera_preset(.Isometric),CAMERA_BLEND},&f.problems)
    testing.expect(t,follow.state.changes==2 && !follow.state.handing,"an Orbit with an angle of its own takes it")
    testing.expect(t,follow.target==body)

    broken:=third
    broken.follow.distance=-1
    mode_take(&f.follows,&f.cameras,core.read(&f.worlds),{camera,broken,CAMERA_BLEND},&f.problems)
    testing.expect(t,has_problem(&f.problems,"camera.mode_invalid") && follow.state.changes==2)
    testing.expect(t,follow.mode==.Orbit && follow.distance==camera_preset(.Isometric).follow.distance)

    lonely:=core.create(&f.es)
    mode_take(&f.follows,&f.cameras,core.read(&f.worlds),{lonely,third,CAMERA_BLEND},&f.problems)
    testing.expect(t,has_problem(&f.problems,"camera.mode_camera"),"a mode needs a render.Camera")
}

@(test)
a_mode_gives_a_camera_without_one_a_camera_follow :: proc(t:^testing.T) {
    f:=test_make()
    defer test_free(f)
    camera:=core.create(&f.es)
    core.add(&f.cameras,camera,render.CAMERA_DEFAULT)
    test_settle(f)
    mode_take(&f.follows,&f.cameras,core.read(&f.worlds),{camera,camera_preset(.Side),CAMERA_BLEND},&f.problems)
    test_settle(f)
    follow,ok:=core.get(core.read(&f.follows),camera)
    testing.expect(t,ok && follow.target==core.NONE && follow.state.changes==1 && follow.state.blend==CAMERA_BLEND)
}

@(test)
the_dead_zone_lets_the_target_move_inside_it_along_the_axes_of_the_camera :: proc(t:^testing.T) {
    zone:=[3]f32{1,1,0}
    testing.expect(t,close_vec(dead_zone_follow({},{0.5,-0.5,0},zone,1),{}),"inside, the center stays")
    testing.expect(t,close_vec(dead_zone_follow({},{3,0,0},zone,1),{2,0,0}),"outside, it moves only what the target left it by")
    testing.expect(t,close_vec(dead_zone_follow({},{0,0,4},zone,1),{0,0,4}),"an axis without a zone follows")
    turned:=mm.quat_axis_angle({0,1,0},math.PI/2)
    testing.expect(t,close_vec(dead_zone_follow({},{0,0,-3},zone,turned),{0,0,-2}),"the box turns with the camera")
    testing.expect(t,close_vec(dead_zone_follow({1,2,3},{4,5,6},{},1),{4,5,6}),"without a zone it is the goal")
}

@(test)
the_pivot_leads_across_the_ground_up_to_its_limit :: proc(t:^testing.T) {
    follow:=Camera_Follow{look_ahead=0.5}
    testing.expect(t,close_vec(follow_lead(follow,{4,0,0}),{2,0,0}))
    follow.look_ahead_max=1
    testing.expect(t,close_vec(follow_lead(follow,{0,0,-4}),{0,0,-1}))
    testing.expect(t,follow_lead(Camera_Follow{},{9,0,9})==[3]f32{})
}

@(test)
a_blend_turns_around_the_pivot_and_narrows_the_field_in_its_tangent :: proc(t:^testing.T) {
    from:=render.View_Pose{position={0,0,5},rotation=1,fov=40*mm.RAD_PER_DEG,near=0.1,far=1000}
    to:=render.View_Pose{position={5,0,0},rotation=mm.quat_axis_angle({0,1,0},math.PI/2),fov=80*mm.RAD_PER_DEG,near=0.1,far=1000}
    half:=pose_mix(from,to,{},true,0.5)
    testing.expect(t,close(linalg.length(half.position),5) && close(half.position.x,half.position.z),"it keeps its distance from the pivot")
    straight:=pose_mix(from,to,{},false,0.5)
    testing.expect(t,close_vec(straight.position,{2.5,0,2.5}))
    testing.expect(t,close(math.tan(half.fov/2),(math.tan(from.fov/2)+math.tan(to.fov/2))/2))
    testing.expect(t,close_vec(pose_mix(from,to,{},true,0).position,from.position) && close_vec(pose_mix(from,to,{},true,1).position,to.position))
    eyes:=from
    eyes.layers=~HEAD_LAYER
    testing.expect(t,pose_mix(eyes,to,{},true,0.9).layers==~HEAD_LAYER,"leaving the eyes it keeps the head out until it is out")
    testing.expect(t,pose_mix(to,eyes,{},true,0.1).layers==0,"coming to the eyes it keeps the head until it arrives")
    testing.expect(t,pose_mix(to,eyes,{},true,1).layers==~HEAD_LAYER)
}

@(test)
a_dolly_zoom_brings_a_perspective_view_to_the_framing_of_an_orthographic_one :: proc(t:^testing.T) {
    persp:=render.View_Pose{position={0,0,10},rotation=1,projection=.Perspective,fov=60*mm.RAD_PER_DEG,near=0.1,far=1000}
    ortho:=render.View_Pose{position={0,0,20},rotation=1,projection=.Orthographic,fov=45*mm.RAD_PER_DEG,near=0.1,far=1000,height=8}
    start:=pose_mix(persp,ortho,{},false,0)
    testing.expect(t,start.projection==.Perspective && close_vec(start.position,persp.position) && close(start.fov,persp.fov) && close(start.near,persp.near))
    end:=pose_mix(persp,ortho,{},false,0.999)
    depth:=linalg.dot(-end.position,[3]f32{0,0,-1})
    testing.expect(t,end.projection==.Perspective && end.fov<4*mm.RAD_PER_DEG)
    testing.expectf(t,close(2*depth*math.tan(end.fov/2),ortho.height,0.05),"it sees the height of the orthographic one at the pivot: %v",2*depth*math.tan(end.fov/2))
    testing.expectf(t,close(end.position.z-end.near,ortho.position.z-ortho.near,0.5),"nothing nearer than the orthographic camera: %v",end.position.z-end.near)
    back:=pose_mix(ortho,persp,{},false,0.001)
    testing.expect(t,close_vec(back.position,end.position,0.5) && close(back.fov,end.fov),"from orthographic it is the same way back")
}

@(test)
a_view_blends_into_a_new_mode_from_what_it_drew_and_travels_with_its_body :: proc(t:^testing.T) {
    f:=test_make()
    defer test_free(f)
    camera,body:=core.create(&f.es),core.create(&f.es)
    core.add(&f.cameras,camera,render.CAMERA_DEFAULT)
    core.add(&f.follows,camera,Camera_Follow{mode=.Follow})
    test_place(f,camera,{})
    test_place(f,body,{})
    test_settle(f)
    frame:=core.Frame_Time{dt=0.125,alpha=1}
    v:Camera_View
    update:=proc(f:^Camera_Test,v:^Camera_View,camera,body:core.Entity,frame:core.Frame_Time) {
        view_update(v,camera,{},body,core.read(&f.cameras),core.read(&f.follows),core.read(&f.worlds),frame)
    }
    update(f,&v,camera,body,frame)
    testing.expect(t,v.camera==camera && !v.blending)

    follow:=core.get(&f.follows,camera)
    follow.state.changes=1
    follow.state.blend={0.5,.Linear}
    test_place(f,camera,{10,0,0})
    update(f,&v,camera,body,frame)
    testing.expectf(t,v.blending && !v.cut && close(v.pose.position.x,2.5),"it starts from what it drew: %v",v.pose.position)
    test_place(f,body,{1,0,0})
    update(f,&v,camera,body,frame)
    testing.expectf(t,close(v.pose.position.x,1+9*0.5),"what it left travels with the body: %v",v.pose.position)
    update(f,&v,camera,body,frame)
    testing.expect(t,v.blending && close(v.pose.position.x,1+9*0.75))
    update(f,&v,camera,body,frame)
    testing.expect(t,!v.blending && close_vec(v.pose.position,{10,0,0}))
}

// A player who looks around during a blend into a mode turns what the view left too: it keeps
// the same place beside the new camera instead of lagging behind the look.
@(test)
what_a_view_left_turns_with_the_camera_it_blends_into :: proc(t:^testing.T) {
    f:=test_make()
    defer test_free(f)
    camera,body:=core.create(&f.es),core.create(&f.es)
    core.add(&f.cameras,camera,render.CAMERA_DEFAULT)
    core.add(&f.follows,camera,Camera_Follow{mode=.Follow})
    test_place(f,camera,{0,0,2})
    test_place(f,body,{})
    test_settle(f)
    frame:=core.Frame_Time{dt=0.125,alpha=1}
    v:Camera_View
    view_update(&v,camera,{},body,core.read(&f.cameras),core.read(&f.follows),core.read(&f.worlds),frame)
    follow:=core.get(&f.follows,camera)
    follow.state.changes=1
    follow.state.blend={0.5,.Linear}
    test_place(f,camera,{0,0,4})
    view_update(&v,camera,{},body,core.read(&f.cameras),core.read(&f.follows),core.read(&f.worlds),frame)
    testing.expectf(t,v.blending && close_vec(v.pose.position,{0,0,2.5}),"a quarter of the way: %v",v.pose.position)
    quarter:=mm.quat_axis_angle({0,1,0},math.PI/2)
    test_place(f,camera,{4,0,0},quarter)
    view_update(&v,camera,{},body,core.read(&f.cameras),core.read(&f.follows),core.read(&f.worlds),frame)
    testing.expectf(t,close_vec(v.pose.position,{3,0,0}),"halfway between both, turned with the look: %v",v.pose.position)
    testing.expectf(t,abs(linalg.dot(v.pose.rotation,quarter))>0.9999,"looking where the camera looks: %v",v.pose.rotation)
}

@(test)
a_view_enters_and_leaves_an_override_with_its_blend_and_cuts_without_one :: proc(t:^testing.T) {
    f:=test_make()
    defer test_free(f)
    a,b,c:=core.create(&f.es),core.create(&f.es),core.create(&f.es)
    for e,i in ([3]core.Entity{a,b,c}) {
        core.add(&f.cameras,e,render.CAMERA_DEFAULT)
        test_place(f,e,{0,f32(i)*10,0})
    }
    test_settle(f)
    frame:=core.Frame_Time{dt=0.1,alpha=1}
    v:Camera_View
    update:=proc(f:^Camera_Test,v:^Camera_View,camera:core.Entity,through:Camera_Blend,frame:core.Frame_Time) {
        view_update(v,camera,through,core.NONE,core.read(&f.cameras),core.read(&f.follows),core.read(&f.worlds),frame)
    }
    update(f,&v,a,{},frame)
    override:=Camera_Blend{0.4,.Linear}
    update(f,&v,b,override,frame)
    testing.expect(t,v.blending && close(v.pose.position.y,2.5),"it comes into the override")
    for _ in 0..<4 {update(f,&v,b,override,frame)}
    testing.expect(t,!v.blending && close(v.pose.position.y,10))
    update(f,&v,a,{},frame)
    testing.expect(t,v.blending && close(v.pose.position.y,7.5),"and leaves it with the same blend")
    for _ in 0..<4 {update(f,&v,a,{},frame)}
    update(f,&v,c,{},frame)
    testing.expect(t,!v.blending && v.cut && close(v.pose.position.y,20),"without a blend it cuts")
}

@(test)
a_camera_with_an_activation_is_seen_while_its_player_holds_the_action :: proc(t:^testing.T) {
    f:=test_make()
    defer test_free(f)
    activations:core.Table(Camera_Activation)
    drivables:core.Table(input.Drivable)
    seats:core.Table(input.Seat)
    core.table_init(&activations,"Camera_Activation")
    core.table_init(&drivables,"Drivable")
    core.table_init(&seats,"Seat")
    defer core.table_destroy(&activations)
    defer core.table_destroy(&drivables)
    defer core.table_destroy(&seats)
    requests:Camera_Requests
    defer core.queue_clear(&requests.queue)
    defer delete(requests.queue.items)
    state:=new(Cameras)
    defer free(state)
    seat_state:input.Seats

    base,aim,body,seat,stray:=core.create(&f.es),core.create(&f.es),core.create(&f.es),core.create(&f.es),core.create(&f.es)
    AIM :: 5
    core.add(&f.cameras,base,render.CAMERA_DEFAULT)
    core.add(&f.cameras,aim,render.CAMERA_DEFAULT)
    core.add(&f.cameras,stray,render.CAMERA_DEFAULT)
    core.add(&f.follows,aim,Camera_Follow{mode=.Orbit,target=body})
    core.add(&activations,aim,Camera_Activation{action=AIM,blend={0.25,.Cubic_Out}})
    core.add(&activations,stray,CAMERA_ACTIVATION_DEFAULT)
    core.add(&drivables,body,input.Drivable{seat=seat,camera=base})
    core.add(&seats,seat,input.Seat{actions={count=input.ACTION_CAPACITY}})
    test_settle(f)
    core.table_settle(&activations,&f.es)
    core.table_settle(&drivables,&f.es)
    core.table_settle(&seats,&f.es)
    select:=proc(f:^Camera_Test,state:^Cameras,requests:^Camera_Requests,activations:^core.Table(Camera_Activation),drivables:^core.Table(input.Drivable),seats:^core.Table(input.Seat),seat_state:^input.Seats) {
        camera_select(core.ref(&f.es),core.read(&f.cameras),state,requests,core.read(activations),core.read(&f.follows),core.read(drivables),core.read(seats),core.ref(seat_state),&f.problems)
    }

    select(f,state,&requests,&activations,&drivables,&seats,&seat_state)
    testing.expect(t,camera_selected(state,core.read(&drivables),core.read(&f.cameras),seat)==base,"without the action, the camera of the body")
    testing.expect(t,has_problem(&f.problems,"camera.activation"),"an activation without an action says so")

    held:=core.get(&seats,seat)
    held.actions.states[AIM].down=true
    select(f,state,&requests,&activations,&drivables,&seats,&seat_state)
    chosen,blend:=seat_camera(state,core.read(&drivables),core.read(&f.cameras),seat)
    testing.expect(t,chosen==aim && blend.seconds==0.25,"while it is held, the camera it brings, with its blend")

    held.actions.states[AIM].down=false
    select(f,state,&requests,&activations,&drivables,&seats,&seat_state)
    testing.expect(t,camera_selected(state,core.read(&drivables),core.read(&f.cameras),seat)==base,"and back once it is let go")
}

// On the side of a planet, where the up of a character is +X, the eyes sit
// above its feet along that up and look level with its ground; between two
// ticks in which its up turned, the camera turns with its place, not at once.
@(test)
the_eyes_sit_along_the_vertical_of_a_character_on_a_planet :: proc(t:^testing.T) {
    f:=test_make()
    defer test_free(f)
    transforms:core.Table(core.Transform);core.table_init(&transforms,"Transform");defer core.table_destroy(&transforms)
    parents:core.Table(core.Parent);core.table_init(&parents,"Parent");defer core.table_destroy(&parents)
    moves:core.Table(input.Move_Input);core.table_init(&moves,"Move_Input");defer core.table_destroy(&moves)
    camera,body:=core.create(&f.es),core.create(&f.es)
    side:=mm.quat_between({0,1,0},{1,0,0})
    test_place(f,body,{20,0,0},side)
    test_place(f,camera,{})
    core.add(&transforms,camera,core.Transform{rotation=1,scale={1,1,1}})
    test_settle(f)
    core.table_settle(&transforms,&f.es)
    follow:=Camera_Follow{target=body,mode=.Eyes,offset={0,1.6,0}}
    follow_one(camera,&follow,body,&transforms,core.read(&f.worlds),core.read(&parents),core.read(&moves),side,{},core.FRAME_TIME_DEFAULT,1.0/60)
    eyes,_:=core.get(core.read(&transforms),camera)
    testing.expectf(t,close_vec(eyes.position,{21.6,0,0}),"the eyes are along the up of the character: %v",eyes.position)
    testing.expect(t,close_vec(mm.quat_rotate(eyes.rotation,{0,1,0}),{1,0,0}),"the eyes look level with its ground")

    // The up turned from +Y to +X in the last tick: halfway through the frame the camera is halfway.
    placed:=core.World_Transform{transform={position={20,0,0},rotation=side,scale={1,1,1}}}
    placed.previous={position={20,0,0},rotation=1,scale={1,1,1}}
    halfway:=vertical_between(side,placed,0.5)
    up:=mm.quat_rotate(halfway,{0,1,0})
    testing.expectf(t,close_vec(up,linalg.normalize([3]f32{1,1,0})),"halfway between the ups of its ticks: %v",up)
    testing.expect(t,vertical_between(side,placed,1)==side && close_vec(mm.quat_rotate(vertical_between(side,placed,0),{0,1,0}),{0,1,0}))
}

// The offset grows with the pitch toward look_up_offset looking up (negative pitch of the orbit)
// and look_down_offset looking down, and a pitch that is not a number adds nothing.
@(test)
look_offset_follows_the_pitch :: proc(t:^testing.T) {
    follow:=Camera_Follow{look_up_offset={0,0.25,-0.1},look_down_offset={0.1,-0.2,0}}
    Case :: struct {pitch:f32,offset:[3]f32}
    cases:=[]Case{
        {0,{}},
        {-0.5*math.PI,{0,0.25,-0.1}},
        {-math.PI,{0,0.25,-0.1}},
        {0.25*math.PI,{0.05,-0.1,0}},
        {math.nan_f32(),{}},
    }
    for c in cases {
        got:=look_offset(follow,c.pitch)
        testing.expectf(t,linalg.length(got-c.offset)<1e-5,"pitch %v gives %v",c.pitch,got)
    }
}

// The keys of a channel join by cubic Hermite with their slopes, and hold their first and last
// values outside them.
@(test)
a_shake_channel_joins_its_keys_by_their_slopes :: proc(t:^testing.T) {
    c:Shake_Channel
    c.keys[0],c.keys[1],c.keys[2]={time=0.5,value=0,slope=0},{time=1.5,value=2,slope=0},{time=2.5,value=0,slope=-4}
    c.count=3
    testing.expect(t,shake_channel_at(c,0)==0 && shake_channel_at(c,3)==0,"before and after its keys, their values")
    testing.expectf(t,abs(shake_channel_at(c,1)-1)<1e-5,"flat at both ends, halfway is half: %v",shake_channel_at(c,1))
    testing.expect(t,abs(shake_channel_at(c,1.5)-2)<1e-6)
    // From 2, flat, to 0 arriving with slope -4: it stays above the flat curve, which would be 1.
    testing.expectf(t,abs(shake_channel_at(c,2)-1.5)<1e-5,"the slope of the last key bends the way in: %v",shake_channel_at(c,2))
    testing.expect(t,shake_channel_at({},1)==0,"a channel without keys adds nothing")
}

// A camera turns its view and widens its perspective lens by the shakes asked of it, at their rate
// and scale, blended in and out, until they end; one asked again while it plays starts over when
// single and adds another when not.
@(test)
a_camera_plays_sequence_shakes_over_its_view_until_they_end :: proc(t:^testing.T) {
    f:=test_make()
    defer test_free(f)
    transforms:core.Table(core.Transform);core.table_init(&transforms,"Transform");defer core.table_destroy(&transforms)
    parents:core.Table(core.Parent);core.table_init(&parents,"Parent");defer core.table_destroy(&parents)
    moves:core.Table(input.Move_Input);core.table_init(&moves,"Move_Input");defer core.table_destroy(&moves)
    camera,body:=core.create(&f.es),core.create(&f.es)
    test_place(f,body,{})
    test_place(f,camera,{})
    core.add(&transforms,camera,core.Transform{rotation=1,scale={1,1,1}})
    core.add(&f.follows,camera,Camera_Follow{target=body,mode=.Eyes,offset={0,1.6,0}})
    test_settle(f)
    core.table_settle(&transforms,&f.es)
    shakes:Camera_Shakes
    defer delete(shakes.queue.items)
    problems:core.Problems
    nod:Shake_Sequence
    nod.pitch.keys[0]={value=0.1}
    nod.pitch.count=1
    nod.length,nod.rate,nod.scale,nod.blend_in,nod.blend_out=1,2,0.5,0.1,0.1
    camera_shake(&shakes,camera,nod)
    shakes_take(&f.follows,&shakes,&problems)
    // 0.05 s in, a quarter of the way through blend_in 0.1 at weight 0.5 x 0.1 rad.
    testing.expectf(t,abs(shake_test_look(f,&transforms,&parents,&moves,camera,body,0.05)-0.025)<1e-4,"blending in")
    testing.expectf(t,abs(shake_test_look(f,&transforms,&parents,&moves,camera,body,0.2)-0.05)<1e-4,"at full weight: scale times its key")
    // The sequence lasts 1 s at rate 2: 0.5 s of play, the last 0.1 blending out.
    testing.expectf(t,abs(shake_test_look(f,&transforms,&parents,&moves,camera,body,0.2)-0.025)<1e-4,"blending out at 0.45 s")
    testing.expect(t,shake_test_look(f,&transforms,&parents,&moves,camera,body,0.1)==0,"ended: the view is its own again")
    following:=core.get(&f.follows,camera)
    testing.expect(t,following.state.shakes[0].sequence.length==0,"and its slot is free")

    swing:=nod
    swing.single,swing.id=true,7
    camera_shake(&shakes,camera,swing)
    camera_shake(&shakes,camera,swing)
    camera_shake(&shakes,camera,nod)
    shakes_take(&f.follows,&shakes,&problems)
    playing:=0
    slots:=following.state.shakes
    for p in slots {
        if p.sequence.length>0 {playing+=1}
    }
    testing.expect_value(t,playing,2)
    // A change of mode (a dash camera) does not cut what plays.
    core.add(&f.cameras,camera,render.Camera{fov=1,near=0.1,active=true})
    test_settle(f)
    setup:=Camera_Setup{follow={mode=.Eyes,offset={0,1.5,0}},lens={fov=1.2,near=0.1}}
    mode_take(&f.follows,&f.cameras,core.read(&f.worlds),{camera=camera,setup=setup},&problems)
    following=core.get(&f.follows,camera)
    kept:=following.state.shakes
    still:=0
    for p in kept {
        if p.sequence.length>0 {still+=1}
    }
    testing.expect(t,following.offset.y==1.5 && still==2,"the mode is taken and its shakes go on")

    camera_shake(&shakes,camera,{})
    camera_shake(&shakes,body,nod)
    shakes_take(&f.follows,&shakes,&problems)
    testing.expect(t,core.problem_find(&problems,camera,"camera.shake")!=nil,"a shake without length is a problem")
    testing.expect(t,core.problem_find(&problems,body,"camera.shake")!=nil,"and one asked of what does not follow")

    zoom:Shake_Sequence
    zoom.fov.keys[0]={value=0.2}
    zoom.fov.count=1
    zoom.length,zoom.scale=1,0.5
    camera_shake(&shakes,camera,zoom)
    shakes_take(&f.follows,&shakes,&problems)
    lens:=core.get(&f.cameras,camera)
    shake_test_look(f,&transforms,&parents,&moves,camera,body,0.1)
    testing.expectf(t,close(lens.fov,1.3,1e-5),"the lens of its mode plus scale times its key: %v",lens.fov)
    shake_test_look(f,&transforms,&parents,&moves,camera,body,0.1)
    testing.expectf(t,close(lens.fov,1.3,1e-5),"and not more each frame: %v",lens.fov)
    lens.projection=.Orthographic
    shake_test_look(f,&transforms,&parents,&moves,camera,body,0.1)
    testing.expect(t,lens.fov==1.2,"an orthographic lens keeps its own")
    lens.projection=.Perspective
    for &p in following.state.shakes {
        if p.sequence.fov.count>0 {p.sequence.scale=100}
    }
    shake_test_look(f,&transforms,&parents,&moves,camera,body,0.1)
    testing.expect(t,lens.fov==SHAKE_FOV_MAX,"and a perspective one stays below pi")
    shake_test_look(f,&transforms,&parents,&moves,camera,body,1)
    testing.expect(t,lens.fov==1.2,"ended: the lens is its own again")
}

// How far up the camera looks after following its body dt seconds.
@(private="file")
shake_test_look :: proc(f:^Camera_Test,transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent),moves:^core.Table(input.Move_Input),camera,body:core.Entity,dt:f32) -> f32 {
    following:=core.get(&f.follows,camera)
    follow_one(camera,following,body,transforms,core.read(&f.worlds),core.read(parents),core.read(moves),1,{},{dt=dt,alpha=1},dt,core.get(&f.cameras,camera))
    placed,_:=core.get(core.read(transforms),camera)
    ahead:=mm.quat_rotate(placed.rotation,{0,0,-1})
    return math.asin(ahead.y) // how far up it looks
}
