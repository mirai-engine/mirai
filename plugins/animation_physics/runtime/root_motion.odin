package animation_physics

import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import locomotion "plugins:locomotion/runtime"

// Root motion that moves a Character, as one-tick layered moves of its locomotion, from one source
// at a time: an action whose body_move is not None (body_move.odin); while it mantles, the root
// motion of the clip of the climb, which the warping of its .character takes onto where the climb
// ends (Mantle_State.to, through its warp window MANTLE_WINDOW over the span of that name on the
// clip) and which drives the climb as an Override, so the body climbs as the clip does and lands
// on the ledge (a climb without root motion follows its own way, locomotion.mantle_move); else,
// with a Root_Motion_Body, the root motion of its whole animation, which also turns it.
MANTLE_WINDOW :: "mantle"
MANTLE_ROOT_MOVE :: u32(0x4d4e544c) // the id of the layered moves of a climb
ROOT_MOTION_MOVE :: u32(0x524f4f54) // the id of those of a Root_Motion_Body

// Under this many radians of yaw in a tick, the root does not turn the body: the look does.
ROOT_TURN_MIN :: f32(1e-4)

@(component,replicated,description="The root motion of its whole animation (a clip that strides, steps or turns) moves and turns its Character every tick as a layered move of move: Additive keeps gravity and the ground, Override replaces them. Across its up unless vertical; while the root turns, the body faces as it does instead of its look. An action that moves the body (body_move) takes over while it plays.")
Root_Motion_Body :: struct {
    move:anim.Action_Body_Move, // None: it does not move the body
    vertical:bool,              // the root also moves it along its up
}

ROOT_MOTION_BODY_DEFAULT :: Root_Motion_Body{move=.Additive}

@(step="fixed",stage="apply")
animation_root_motion :: proc(bodies:^core.Table(Root_Motion_Body,.Read),states:^core.Table(locomotion.Locomotion_State,.Read),worlds:^core.Table(core.World_Transform,.Read),verticals:^core.Table(core.Vertical,.Read),paces:^core.Table(core.Own_Pace,.Read),playback:core.Ref(anim.Playback),moves:^locomotion.Locomotion_Requests,time:core.Time,clock:core.Clock) {
    if !(time.dt>0) {return}
    for row in 0..<core.count(states) {
        entity:=core.entity_at(states,row)
        placed,ok:=core.get(worlds,entity)
        if !ok {continue}
        climbing:=core.at(states,row).mode==locomotion.MODE_MANTLING
        body,has:=core.get(bodies,entity)
        if !climbing && (!has || body.move==.None) {continue}
        if _,acting:=anim.animation_body_motion(playback,entity);acting && !climbing {continue}
        delta,rooted:=anim.animation_root_delta(playback,entity)
        if !rooted {continue}
        dt:=time.dt*core.pace_of(clock,paces,entity)
        if climbing {
            locomotion.add_move(moves,entity,{velocity=root_velocity(delta.translation,placed,dt),ticks=1,mix=.Override,id=MANTLE_ROOT_MOVE})
            continue
        }
        locomotion.add_move(moves,entity,root_layered_move(delta,body,placed,core.vertical_of(verticals,entity),dt))
    }
}

// The layered move of one tick of dt seconds of the body's own time that the root motion of its
// animation asks for, placed where the body is and with up the +Y of up_frame (core.Vertical): its
// velocity, and the turn of the root about the up of the body (its +Y).
root_layered_move :: proc "contextless" (delta:anim.Root_Delta,body:Root_Motion_Body,placed:core.World_Transform,up_frame:mm.Quat,dt:f32) -> locomotion.Layered_Move {
    velocity:=root_velocity(delta.translation,placed,dt)
    if !body.vertical {up:=mm.quat_rotate(up_frame,mm.Vec3{0,1,0});velocity-=up*linalg.dot(velocity,up)}
    yaw:=mm.yaw_of_direction(mm.quat_forward(delta.rotation))
    turn:=yaw/dt if abs(yaw)>=ROOT_TURN_MIN && dt>0 else 0
    return {velocity=velocity,turn=turn,ticks=1,mix=.Override if body.move==.Override else .Additive,id=ROOT_MOTION_MOVE}
}

// The target of the warping of a climb: the feet where it ends, facing as the body faces.
mantle_target :: proc "contextless" (climb:locomotion.Mantle_State,facing:mm.Quat) -> anim.Spatial_Target {
    return {kind=.World,position=climb.to,rotation=facing,scale=1}
}
