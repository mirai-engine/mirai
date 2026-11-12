package camera

import "core:math"
import "core:math/linalg"
import "mirai:core"
import input "mirai:engine/input"
import render "mirai:engine/render"
import mm "mirai:std/math"

// The camera each player sees through, and cameras that follow. The camera a
// seat sees through is its latest override, and otherwise the camera of its
// body: the render.Camera on it or under it, first in the walk of its
// hierarchy; the focused local player's is the view of the game
// (render.View_Camera, view.odin). The lens of an override goes to its camera
// while it stands. What the seat asks of its body comes from what it sees
// (drive.odin).
//
// A Camera_Follow on a camera entity moves it with a target. Follow keeps an
// offset from the target with a smoothed pivot; Orbit turns around the pivot
// at a distance, from over a shoulder when it has one, pulled in when a probe
// of the world (core.World_Queries) finds something in the way; Eyes sits at
// the offset and looks where the Move_Input of the target looks: a first
// person. An Orbit that aims turns with that look too. The pivot of Follow and
// Orbit leads a target that moves (look_ahead) and lets it move inside a box
// before it follows (dead_zone). Offset, orbit and look are in the frame of
// the vertical of the target (core.Vertical): around a planet the camera turns
// with the up of the character it follows. The component owns the Transform
// of its entity; what it is set to can change at run time (modes.odin).

OVERRIDE_CAPACITY :: 64
PITCH_LIMIT :: 1.5533 // radians
RECENTER_SPEED :: 0.5 // m/s a target moves at least for an Orbit to come back behind it
RECENTER_RATE :: 2    // 1/seconds of the exponential turn back

Camera_Mode :: enum u8 {Follow,Orbit,Eyes}

@(component,locks="core.Transform")
Camera_Follow :: struct {
    target:core.Entity `mirai:"section=Follow"`, // none: the body it hangs from (follow_target), or else the one of the focused local player
    mode:Camera_Mode,
    offset:[3]f32 `mirai:"unit=m"`, // from the target to the pivot, in the axes of the vertical of the target: world axes without one
    distance:f32 `mirai:"min=0,unit=m,mode=Orbit"`, // from the pivot to the camera
    half_life:f32 `mirai:"min=0,unit=s,mode=Follow|Orbit"`, // time the pivot takes to close half of its distance to the target; 0: rigid
    up_half_life:f32 `mirai:"min=0,unit=s,mode=Follow|Orbit"`, // the same along the up of the target; 0: half_life
    probe_radius:f32 `mirai:"min=0,unit=m,mode=Orbit"`, // of the sphere kept clear from the pivot to the camera; 0: nothing pulls it in
    shoulder:[2]f32 `mirai:"unit=m,mode=Orbit"`, // right and up of the camera, from the pivot to where its arm starts
    look_up_offset:[3]f32 `mirai:"unit=m,mode=Orbit"`,   // right, up and back of the camera added to where its arm starts when it looks straight up, in proportion to the pitch
    look_down_offset:[3]f32 `mirai:"unit=m,mode=Orbit"`, // the same looking straight down
    dead_zone:[3]f32 `mirai:"min=0,unit=m,section=Framing,mode=Follow|Orbit"`, // half the box, along the right, up and back of the camera, the target moves in before the pivot follows
    look_ahead:f32 `mirai:"min=0,unit=s,mode=Follow|Orbit"`, // the pivot leads the target by how far it goes across the ground in this time
    look_ahead_max:f32 `mirai:"min=0,unit=m,mode=Follow|Orbit"`, // 0: no limit
    yaw:f32 `mirai:"angle,section=Look,mode=Orbit"`, // where it starts; aiming, what it adds to the look
    pitch:f32 `mirai:"angle,mode=Orbit|Eyes"`, // Orbit: where it starts, positive above the pivot looking down, negative below it looking up; aiming, what it adds to the look. Eyes: where it starts, positive looks up
    min_pitch,max_pitch:f32 `mirai:"angle,mode=Orbit|Eyes"`, // both 0: almost straight up and down
    turn:bool `mirai:"mode=Orbit"`, // without aim: the look action of the local player who drives its target turns it
    recenter:f32 `mirai:"min=0,unit=s,mode=Orbit"`, // without aim: this long after it was last turned, it comes back behind a target that moves away from it; 0: never
    look_at:bool `mirai:"mode=Follow"`, // the camera faces the target
    aim:bool `mirai:"mode=Orbit"`,  // it looks where the Move_Input of the target looks
    pull_grace:f32 `mirai:"min=0,unit=s,section=Advanced,mode=Orbit"`, // what only crosses between the pivot and the camera is let be this long before the camera comes in
    pull_time:f32 `mirai:"min=0,unit=s,mode=Orbit"`,    // half-life of coming in toward it; 0: at once
    return_delay:f32 `mirai:"min=0,unit=s,mode=Orbit"`, // it stays in this long after the way clears
    return_time:f32 `mirai:"min=0,unit=s,mode=Orbit"`,  // half-life of going back out; 0: at once
    arm_margin:f32 `mirai:"min=0,unit=m,mode=Orbit"`,   // kept between the camera and what it hit
    hide_within:f32 `mirai:"min=0,unit=m"`,  // the body it follows is not drawn in its view while the camera is nearer than this to its pivot, and fades out from twice as far; 0: always drawn
    looking:[2]f32 `mirai:"transient,readonly"`, // yaw and pitch it looks with now, radians
    state:Camera_Follow_State `mirai:"transient,hidden"`,
}

// What a Camera_Follow derives as it runs.
Camera_Follow_State :: struct {
    pivot:Follow,
    zone:[3]f32,          // the center of the dead zone
    arm:Spring_Arm,
    side:Spring_Arm, // from the pivot to the shoulder
    idle:f32,             // s since it was last turned
    changes:u32,          // the setups it took: a view through it blends when this changes
    blend:Camera_Blend,   // of the last setup
    handoff:[2]f32,       // yaw and pitch it starts with after a setup: where the camera looked
    handing:bool,
    ready:bool,
    written:core.Transform, // what the last frame left in the transform
    wrote:bool,
    shakes:[CAMERA_SHAKES]Shake_Playing, // the sequence shakes it plays over its view (camera_shake)
    fov_base:f32,         // the fov of its render.Camera without the shakes, while fov_shaken
    fov_shaken:bool,
}

CAMERA_FOLLOW_DEFAULT :: Camera_Follow{
    mode=.Orbit,offset={0,1.6,0},distance=4,half_life=0.08,probe_radius=0.2,
    pull_grace=SPRING_ARM_GRACE,pull_time=SPRING_ARM_PULL_TIME,return_delay=SPRING_ARM_HOLD,return_time=SPRING_ARM_RETURN_TIME,arm_margin=SPRING_ARM_MARGIN,
    hide_within=0.5,
}

Camera_Look :: struct {
    camera:core.Entity,
    yaw,pitch:f32, // radians to turn an Orbit camera by
}

@(storage,queue)
Camera_Input :: struct {
    looks:core.Queue(Camera_Look),
}

camera_look :: proc(input:^Camera_Input,camera:core.Entity,yaw,pitch:f32) {
    core.push(&input.looks,Camera_Look{camera,yaw,pitch})
}

// Asks an Orbit camera to turn so that it looks from its pivot at a point of
// the world, whatever turned it so far; up is the frame of the vertical of its
// target. false for one that does not orbit by itself or has not started.
camera_look_toward :: proc(input:^Camera_Input,camera:core.Entity,follow:Camera_Follow,point:[3]f32,up:=mm.QUAT_IDENTITY) -> bool {
    if follow.mode!=.Orbit || follow.aim || !follow.state.ready {return false}
    toward:=point-follow.state.pivot.position
    if linalg.length(toward)<1e-4 {return true}
    want:=look_toward(mm.quat_rotate(conj(up),linalg.normalize(toward)))
    camera_look(input,camera,mm.angle_wrap(want.x-follow.looking.x),want.y-follow.looking.y)
    return true
}

// A camera the seat sees through for as long as the owner asks; the latest
// asked wins. A lens (fov above zero) is given to the camera while the
// override stands. With a blend, the view comes into it and back out over it.
Camera_Override :: struct {
    owner,seat,camera:core.Entity,
    fov,near:f32,
    blend:Camera_Blend,
    order:u64,
    active:bool,
}

// Players see through this camera while they hold action, as when aiming: the
// player who drives the target of its Camera_Follow, or without one the
// focused local player. The view comes into it and goes back out with blend.
@(component,description="Players see through this camera while they hold an action, as when aiming, coming into it and going back with a blend.")
Camera_Activation :: struct {
    action:input.Action,
    blend:Camera_Blend,
}

CAMERA_ACTIVATION_DEFAULT :: Camera_Activation{action=max(input.Action),blend={seconds=0.25,ease=.Cubic_Out}}

// What this library derives and is asked while the world runs. Loading a
// scene or a save starts it again: the libraries that asked for overrides ask again.
@(storage)
Cameras :: struct {
    overrides:[OVERRIDE_CAPACITY]Camera_Override,
    order:u64,
}

Camera_Request :: struct {
    add:bool,
    override:Camera_Override,
}

@(storage,queue)
Camera_Requests :: struct {
    using queue:core.Queue(Camera_Request),
}

// The seat sees through camera while owner asks, with its own lens or,
// with fov above zero, that one; the view blends into it and out of it as
// blend says.
camera_override :: proc(r:^Camera_Requests,owner,seat,camera:core.Entity,fov:f32=0,near:f32=0,blend:=Camera_Blend{}) {
    core.push(&r.queue,Camera_Request{add=true,override={owner=owner,seat=seat,camera=camera,fov=fov,near=near,blend=blend}})
}
camera_override_remove :: proc(r:^Camera_Requests,owner:core.Entity) {
    core.push(&r.queue,Camera_Request{override={owner=owner}})
}

// What the players see through, for a step to receive in one parameter.
@(params)
Sight :: struct {
    shown:core.Ref(Cameras),
    seats:^core.Table(input.Seat,.Read),
    cameras:^core.Table(render.Camera,.Read),
    hierarchy:core.Ref(core.Hierarchy),
    worlds:^core.Table(core.World_Transform,.Read),
}

// The ray of the view of the player who drives a body: from the camera it
// sees through, where it looks, whatever the mode of that camera. False
// without a camera.
aim :: proc(sight:Sight,body:core.Entity) -> (origin,direction:[3]f32,ok:bool) {
    camera,_:=camera_selected(sight.shown.ptr,sight.seats,sight.cameras,sight.hierarchy,input.seat_of(sight.seats,body))
    placed:=core.get(sight.worlds,camera) or_return
    return placed.position,mm.quat_forward(placed.rotation),true
}

// The camera a seat sees through: its latest override, and otherwise the
// camera of its body; none without a valid one. With the blend an override asked for.
camera_selected :: proc(cameras_state:^Cameras,seats:^core.Table(input.Seat,.Read),cameras:^core.Table(render.Camera,.Read),hierarchy:core.Ref(core.Hierarchy),seat:core.Entity) -> (core.Entity,Camera_Blend) {
    if chosen:=override_chosen(cameras_state,cameras,seat);chosen!=nil {return chosen.camera,chosen.blend}
    return body_camera(hierarchy,cameras,input.body_of(seats,seat)),{}
}

// The camera of a body: a render.Camera on it or under it, the first in the
// walk of its hierarchy; none without one.
body_camera :: proc(hierarchy:core.Ref(core.Hierarchy),cameras:^core.Table(render.Camera,$A),body:core.Entity) -> core.Entity {
    if body==core.NONE {return core.NONE}
    for at:=body;at!=core.NONE;at=core.subtree_next(hierarchy,body,at) {
        if camera_valid(cameras,at) {return at}
    }
    return core.NONE
}

// Whether an owner asks for a camera now.
camera_overriding :: proc "contextless" (cameras_state:^Cameras,owner:core.Entity) -> bool {
    for item in cameras_state.overrides {
        if item.active && item.owner==owner {return true}
    }
    return false
}

@(private)
override_chosen :: proc(cameras_state:^Cameras,cameras:^core.Table(render.Camera,$A),seat:core.Entity) -> (chosen:^Camera_Override) {
    if seat==core.NONE {return}
    for &item in cameras_state.overrides {
        if !item.active || item.seat!=seat || !camera_valid(cameras,item.camera) {continue}
        if chosen==nil || item.order>chosen.order {chosen=&item}
    }
    return
}

@(private)
camera_valid :: proc(cameras:^core.Table(render.Camera,$A),e:core.Entity) -> bool {
    camera,ok:=core.get(cameras,e)
    return ok && camera.fov>=0 && camera.fov<3.14159 && camera.near>=0
}

// The overrides as they were asked, and those of the activations whose action is held: with who
// drives what, so a camera and a seat request land together, before the Move_Input of the seats.
@(step="fixed",stage="input")
camera_select :: proc(
    es:core.Ref(core.Entities),cameras:^core.Table(render.Camera,.Read),cameras_state:^Cameras,requests:^Camera_Requests,
    activations:^core.Table(Camera_Activation,.Read),follows:^core.Table(Camera_Follow,.Read),parents:^core.Table(core.Parent,.Read),
    seats:^core.Table(input.Seat,.Read),seat_state:core.Ref(input.Seats),problems:^core.Problems,
) {
    for request in core.take(&requests.queue) {
        r:=request.override
        if !request.add {
            for &item in cameras_state.overrides {
                if item.active && item.owner==r.owner {item.active=false}
            }
            continue
        }
        switch {
        case !core.alive(es.ptr,r.seat):
            core.report(problems,r.owner,"camera.override_seat","a camera override for seat 0x%016x was refused: that seat is not alive; ask for one of a live seat",u64(r.seat))
        case !camera_valid(cameras,r.camera):
            core.report(problems,r.owner,"camera.override_invalid","a camera override through entity 0x%016x was refused: it has no render.Camera with a fov from 0 to pi and a near of 0 or more; give it one or pass another camera",u64(r.camera))
        case r.blend.seconds<0:
            core.report(problems,r.owner,"camera.override_blend","a camera override through entity 0x%016x was refused: its blend lasts %v seconds; give it 0 or more",u64(r.camera),r.blend.seconds)
        case !override_set(cameras_state,r):
            core.report(problems,r.owner,"camera.overrides_full","a camera override was refused: %d camera overrides are active, as many as fit; remove the ones no longer needed with camera_override_remove",OVERRIDE_CAPACITY)
        }
    }
    for &item in cameras_state.overrides {
        if !item.active {continue}
        if !core.alive(es.ptr,item.seat) || !camera_valid(cameras,item.camera) || item.owner!=core.NONE && !core.alive(es.ptr,item.owner) {item.active=false}
    }
    player:=input.focused(seat_state.ptr,seats)
    for row in 0..<core.count(activations) {
        camera:=core.entity_at(activations,row)
        activation:=core.at(activations,row)
        if int(activation.action)>=input.ACTION_CAPACITY || activation.blend.seconds<0 {
            core.report(problems,camera,"camera.activation","the Camera_Activation of entity 0x%016x has no action or a blend below 0 seconds; give it the action that brings this camera, as aim",u64(camera))
            continue
        }
        follow,_:=core.get(follows,camera)
        seat:=input.seat_of(seats,follow_target(camera,follow.target,parents,seats,player))
        if seat!=core.NONE && camera_valid(cameras,camera) && input.seat_action(seats,seat,activation.action).down {
            if !override_set(cameras_state,{owner=camera,seat=seat,camera=camera,blend=activation.blend}) {
                core.report(problems,camera,"camera.overrides_full","the Camera_Activation of entity 0x%016x was not seen: %d camera overrides are active, as many as fit",u64(camera),OVERRIDE_CAPACITY)
            }
            continue
        }
        for &item in cameras_state.overrides {
            if item.active && item.owner==camera {item.active=false}
        }
    }
}

@(private)
override_set :: proc(cameras_state:^Cameras,r:Camera_Override) -> bool {
    free:^Camera_Override
    for &item in cameras_state.overrides {
        if item.active && item.owner==r.owner {
            free=&item
            break
        }
        if !item.active && free==nil {free=&item}
    }
    if free==nil {return false}
    // The same override asked again keeps its order: it is the same choice.
    order:=free.order
    if !free.active || free.seat!=r.seat || free.camera!=r.camera {
        cameras_state.order+=1
        order=cameras_state.order
    }
    free^=r
    free.order,free.active=order,true
    return true
}

// The modes asked for, the lens of the overrides, the turns asked for and
// every camera that follows: the only writer of Camera_Follow and of the lens.
@(step="late")
camera_follow :: proc(
    world:core.World_Ref,follows:^core.Table(Camera_Follow),cameras:^core.Table(render.Camera),transforms:^core.Table(core.Transform),
    worlds:^core.Table(core.World_Transform,.Read),parents:^core.Table(core.Parent,.Read),
    seats:^core.Table(input.Seat,.Read),moves:^core.Table(input.Move_Input,.Read),shown:core.Ref(Cameras),
    seat_state:core.Ref(input.Seats),look_actions:input.Frame_Input_Of(input.Look_Action),queries:core.Ref(core.World_Queries),look_input:^Camera_Input,changes:^Camera_Changes,
    verticals:^core.Table(core.Vertical,.Read),frame:core.Frame_Time,time:core.Time,problems:^core.Problems,
    shakes:^Camera_Shakes,
) {
    // The lens is the one of the mode or the override; the shakes go over it again below.
    for row in 0..<core.count(follows) {
        if s:=&core.edit_at(follows,row).state;s.fov_shaken {
            if camera:=core.edit(cameras,core.entity_at(follows,row));camera!=nil {shakes_fov_restore(camera,s)}
            s.fov_shaken=false
        }
    }
    for change in core.take(&changes.queue) {mode_take(follows,cameras,worlds,change,problems)}
    shakes_take(follows,shakes,problems)
    for item in shown.overrides {
        if !item.active || item.fov<=0 {continue}
        if camera:=core.edit(cameras,item.camera);camera!=nil && (camera.fov!=item.fov || camera.near!=item.near) {camera.fov,camera.near=item.fov,item.near}
    }
    for look in core.take(&look_input.looks) {
        follow:=core.edit(follows,look.camera)
        if follow==nil || !follow.state.ready {continue}
        low,high:=pitch_limits(follow^)
        follow.looking={mm.angle_wrap(follow.looking.x+look.yaw),clamp(follow.looking.y+look.pitch,low,high)}
        follow.state.idle=0
    }
    player:=input.focused(seat_state.ptr,seats)
    for row in 0..<core.count(follows) {
        e:=core.entity_at(follows,row)
        follow:=core.edit_at(follows,row)
        target:=follow_target(e,follow.target,parents,seats,player)
        // The look of the local seat that drives its target turns it, from the devices of its slot.
        if seat,local:=core.get(seats,input.seat_of(seats,target));local && input.seat_local(seat) && follow.turn && follow.state.ready && follow.mode==.Orbit && !follow.aim {
            if turn:=input.slot_frame_state(look_actions,int(seat.slot),.Look).vector*input.LOOK_SPEED;turn!={} {
                low,high:=pitch_limits(follow^)
                follow.looking={mm.angle_wrap(follow.looking.x-turn.x),clamp(follow.looking.y-turn.y,low,high)}
                follow.state.idle=0
            }
        }
        vertical:=core.vertical_of(verticals,target)
        if placed,ok:=core.get(worlds,target);ok && core.has(verticals,target) {vertical=vertical_between(vertical,placed,frame.alpha)}
        follow_one(e,follow,target,transforms,worlds,parents,moves,vertical,core.world_query(world,queries),frame,time.dt,core.edit(cameras,e))
    }
}

// The frame of the vertical of a body whose rotation has its up (a
// Character) in this frame, between its last two ticks as its place is: it
// turns from the up of its previous rotation to the one it has.
vertical_between :: proc "contextless" (vertical:mm.Quat,placed:core.World_Transform,alpha:f32) -> mm.Quat {
    if !(alpha<1) {return vertical}
    back:=mm.quat_between(mm.quat_rotate(placed.rotation,{0,1,0}),mm.quat_rotate(placed.previous.rotation,{0,1,0}))
    return mm.quat_slerp(back,mm.QUAT_IDENTITY,max(alpha,0))*vertical
}

// A setup keeps the target and what its camera derived; a free Orbit goes on
// looking where the camera looked, and one with an angle of its own takes it.
@(private)
mode_take :: proc(follows:^core.Table(Camera_Follow),cameras:^core.Table(render.Camera),worlds:^core.Table(core.World_Transform,$A),change:Camera_Change,problems:^core.Problems) {
    camera:=core.edit(cameras,change.camera)
    if camera==nil {
        core.report(problems,change.camera,"camera.mode_camera","a camera mode for entity 0x%016x was refused: it has no render.Camera; give it one, or ask for the mode of a camera",u64(change.camera))
        return
    }
    if why:=setup_invalid(change.setup);why!="" {
        core.report(problems,change.camera,"camera.mode_invalid","a camera mode for entity 0x%016x was refused: %s; correct its Camera_Setup",u64(change.camera),why)
        return
    }
    if change.blend.seconds<0 {
        core.report(problems,change.camera,"camera.mode_blend","a camera mode for entity 0x%016x was refused: its blend lasts %v seconds; give it 0 or more",u64(change.camera),change.blend.seconds)
        return
    }
    want:=camera_follow_config(change.setup.follow)
    follow:=core.edit(follows,change.camera)
    if follow==nil {
        want.target=core.NONE
        want.state.changes=1
        want.state.blend=change.blend
        core.add(follows,change.camera,want)
        camera^=lens_on(camera^,change.setup.lens)
        return
    }
    want.target=follow.target
    if camera_follow_config(follow^)==want && lens_on(camera^,change.setup.lens)==camera^ {return}
    state:=follow.state
    looked:=follow.looking
    if own,ok:=core.get(worlds,change.camera);ok {looked=look_of(own.rotation)}
    follow^=want
    follow.state.changes=state.changes+1
    follow.state.blend=change.blend
    follow.state.written=state.written
    follow.state.wrote=state.wrote
    follow.state.shakes=state.shakes // a shake goes on through a change of mode
    if follow.mode==.Orbit && !follow.aim && (follow.min_pitch!=follow.max_pitch || follow.min_pitch==0) {
        follow.state.handoff=looked
        follow.state.handing=true
    }
    camera^=lens_on(camera^,change.setup.lens)
}

// The yaw and pitch of an Orbit that looks as rotation does.
@(private)
look_of :: proc "contextless" (rotation:mm.Quat) -> [2]f32 {
    return look_toward(mm.quat_forward(rotation))
}

// The yaw and pitch of an Orbit that looks along forward, a unit vector.
@(private)
look_toward :: proc "contextless" (forward:[3]f32) -> [2]f32 {
    return {mm.yaw_of_direction(forward),math.asin(clamp(-forward.y,-1,1))}
}

@(private)
pitch_limits :: proc(follow:Camera_Follow) -> (low,high:f32) {
    low,high=follow.min_pitch,follow.max_pitch
    if low==0 && high==0 {low,high=-PITCH_LIMIT,PITCH_LIMIT}
    return
}

@(private)
Arm_Probe :: struct {
    query:core.World_Query,
    ignore:core.Entity,
}

@(private)
arm_query :: proc(user:rawptr,from,to:mm.Vec3,radius:f32) -> (fraction:f32,hit:bool) {
    arm:=cast(^Arm_Probe)user
    length:=linalg.length(to-from)
    if arm.query.probe==nil || length<1e-6 {return}
    found:=arm.query.probe(arm.query.user,from,to-from,length,radius,arm.ignore,~u32(0)) or_return
    return found.distance/length,true
}

// Its target, or without one the body it hangs from: the nearest entity above
// it that a seat drives, or else the root of its hierarchy. A camera that
// hangs from nothing follows the body of the focused local player.
follow_target :: proc(e,target:core.Entity,parents:^core.Table(core.Parent,$A),seats:^core.Table(input.Seat,$B),player:core.Entity) -> core.Entity {
    if target!=core.NONE {return target}
    root:=core.NONE
    at:=e
    for _ in 0..<core.HIERARCHY_DEPTH {
        parent,ok:=core.get(parents,at)
        if !ok || parent.entity==core.NONE {break}
        at=parent.entity
        if input.seat_of(seats,at)!=core.NONE {return at}
        root=at
    }
    return root!=core.NONE?root:input.body_of(seats,player)
}

// How far ahead of the target the pivot goes for a velocity across the ground.
@(private)
follow_lead :: proc "contextless" (follow:Camera_Follow,ground:[3]f32) -> [3]f32 {
    lead:=ground*follow.look_ahead
    if length:=linalg.length(lead);follow.look_ahead_max>0 && length>follow.look_ahead_max {lead*=follow.look_ahead_max/length}
    return lead
}

// The center of a dead zone: it moves only as far as the goal leaves the box
// around it, along the axes of rotation.
@(private)
dead_zone_follow :: proc "contextless" (center,goal,zone:[3]f32,rotation:mm.Quat) -> [3]f32 {
    if zone=={} {return goal}
    moved:=center
    axes:=[3][3]f32{{1,0,0},{0,1,0},{0,0,1}}
    for axis,i in axes {
        along:=mm.quat_rotate(rotation,axis)
        d:=linalg.dot(goal-center,along)
        if d>zone[i] {moved+=along*(d-zone[i])} else if d< -zone[i] {moved+=along*(d+zone[i])}
    }
    return moved
}

// What the pitch adds to where the arm of an Orbit starts, in the axes of the
// camera: look_up_offset looking straight up (the camera below the pivot,
// negative pitch), look_down_offset straight down, nothing level.
look_offset :: proc "contextless" (follow:Camera_Follow,pitch:f32) -> [3]f32 {
    share:f32=pitch/(0.5*math.PI)
    if !(abs(share)<=1) {share=share>0?1:(share<0?-1:0)}
    return share<0?follow.look_up_offset*(-share):follow.look_down_offset*share
}

@(private)
arm_tune :: proc "contextless" (arm:^Spring_Arm,follow:Camera_Follow) {
    arm.probe_radius,arm.margin=follow.probe_radius,follow.arm_margin
    arm.grace,arm.pull_time,arm.hold,arm.return_time=follow.pull_grace,follow.pull_time,follow.return_delay,follow.return_time
}

// vertical: the frame of the vertical of the target. tick: seconds of a fixed
// tick, which the velocity of the target is measured over. camera: its lens,
// which its shakes widen; nil without one.
@(private)
follow_one :: proc(
    e:core.Entity,follow:^Camera_Follow,target:core.Entity,transforms:^core.Table(core.Transform),
    worlds:^core.Table(core.World_Transform,$A),parents:^core.Table(core.Parent,$B),
    moves:^core.Table(input.Move_Input,$C),vertical:mm.Quat,query:core.World_Query,frame:core.Frame_Time,tick:f32,
    camera:^render.Camera=nil,
) {
    placed,has_target:=core.get(worlds,target)
    row:=core.edit(transforms,e)
    if !has_target || row==nil {return}
    s:=&follow.state
    position:=placed.position
    if frame.alpha<1 {position=mm.lerp(placed.previous.position,placed.position,frame.alpha)}
    up:=mm.quat_rotate(vertical,{0,1,0})
    ground:[3]f32
    if tick>0 {
        ground=(placed.position-placed.previous.position)/tick
        ground-=up*linalg.dot(ground,up)
    }
    goal:=position+mm.quat_rotate(vertical,follow.offset)+follow_lead(follow^,ground)
    if !s.ready {
        s.pivot=Follow{position=goal}
        s.zone=goal
        s.arm=spring_arm_make(max(follow.distance,0.01),follow.probe_radius)
        s.side=spring_arm_make(linalg.length(follow.shoulder),follow.probe_radius)
        s.side.min_length=0
        follow.looking={follow.yaw,follow.pitch}
        if s.handing {
            low,high:=pitch_limits(follow^)
            follow.looking={s.handoff.x,clamp(s.handoff.y,low,high)}
        }
        s.handing,s.idle,s.ready=false,0,true
    }
    if s.wrote && row^!=s.written {
        core.fail("Camera_Follow owns the Transform of entity %v and another library wrote it: move the camera through its Camera_Follow, or remove the component",e)
    }
    dt:=frame.dt
    facing:=row.rotation
    if own,found:=core.get(worlds,e);found {facing=own.rotation}
    s.zone=dead_zone_follow(s.zone,goal,follow.dead_zone,facing)
    pivot:=follow_update_split(&s.pivot,s.zone,follow.half_life,follow.up_half_life,up,dt)
    world_position:[3]f32
    world_rotation:mm.Quat
    look,aiming:=core.get(moves,target)
    low,high:=pitch_limits(follow^)
    switch follow.mode {
    case .Follow:
        world_position=pivot
        world_rotation=facing
        if follow.look_at && position!=pivot {world_rotation=mm.quat_look(position-pivot,up)}
    case .Orbit:
        if aiming && follow.aim {
            follow.looking={mm.angle_wrap(look.look_yaw+follow.yaw),clamp(follow.pitch-look.look_pitch,low,high)}
        } else if follow.recenter>0 {
            s.idle+=dt
            if s.idle>=follow.recenter && linalg.length(ground)>RECENTER_SPEED {
                // Only going away from the camera brings it behind, the more the straighter:
                // walking toward it or across it keeps its yaw, since a walk relative to the
                // camera turns with it and chasing it would spin the camera without end.
                along:=mm.yaw_of_direction(mm.quat_rotate(conj(vertical),ground))
                if away:=math.cos(mm.angle_delta(follow.looking.x,along));away>0 {
                    turned:=mm.damp_angle(follow.looking.x,along,RECENTER_RATE*away,dt)
                    follow.looking.x=mm.angle_wrap(turned)
                }
            }
        }
        orbit:=orbit_make(pivot,follow.distance,follow.looking.x,follow.looking.y)
        world_rotation=vertical*orbit_rotation(orbit)
        probe:=Arm_Probe{query,target}
        collide:=follow.probe_radius>0?arm_query:nil
        origin:=pivot+mm.quat_rotate(world_rotation,look_offset(follow^,follow.looking.y))
        if side:=mm.quat_rotate(world_rotation,[3]f32{follow.shoulder.x,follow.shoulder.y,0});follow.shoulder!={} {
            // What stands beside the target brings the shoulder in, as the arm.
            arm_tune(&s.side,follow^)
            s.side.length=linalg.length(side)
            origin=spring_arm_update(&s.side,pivot,side/s.side.length,collide,&probe,dt)
        }
        arm_tune(&s.arm,follow^)
        s.arm.length=follow.distance
        world_position=spring_arm_update(&s.arm,origin,mm.quat_rotate(vertical,orbit_direction(orbit)),collide,&probe,dt)
    case .Eyes:
        if aiming {follow.looking={look.look_yaw,clamp(look.look_pitch,low,high)}}
        world_position=position+mm.quat_rotate(vertical,follow.offset)
        world_rotation=vertical*mm.quat_from_euler({follow.looking.y,follow.looking.x,0})

    }
    turn,widen:=shakes_advance(s,dt)
    world_rotation*=turn
    if camera!=nil {shakes_fov(camera,s,widen)}
    if core.world_set(row,transforms,parents,e,world_position,world_rotation) {
        s.written,s.wrote=row^,true
    }
}
