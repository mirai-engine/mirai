package camera

import "core:math"
import "core:math/linalg"
import "mirai:core"
import input "mirai:engine/input"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import mm "mirai:std/math"

// What a seat asks of the body it drives: its move and look actions toward
// the forward of the camera it sees through. A camera that looks with the
// body (Eyes, an Orbit that aims, or one on the body without a Camera_Follow)
// gives where the body looks, which the look action turns and tilts within the
// pitch limits of that camera; another gives where it looks, and the body
// faces where it goes; without a camera, -Z of the world. Forward is in the
// frame of the vertical of the body. One that changes to a camera that looks
// with the body starts looking where the camera it left looked. Where another
// end decides the body, its Move_Input is that end's.
//
// With no body for player 1 when the Play of the editor starts and no active
// camera, the player flies a camera of its own from where the editor looked:
// its seat drives it until it drives another body, and then it goes.

FREE_CAMERA_SPEED :: 8 // m/s

// The camera player 1 flies without a body of its own.
@(storage)
Free_Camera :: struct {
    entity:core.Entity,
    bodied:bool, // player 1 drove a body of the game: no free camera after
}

@(step="fixed",stage="input",after="camera_select input_drive")
camera_drive :: proc(
    seats:core.Read(input.Seat),moves:^core.Table(input.Move_Input),move_actions:input.Input_Of(input.Move_Action),look_actions:input.Input_Of(input.Look_Action),
    bindings:core.Ref(input.Input_Map),follows:core.Read(Camera_Follow),shown:core.Ref(Cameras),cameras:core.Read(render.Camera),views:core.Ref(Camera_Views),
    hierarchy:core.Ref(core.Hierarchy),parents:core.Read(core.Parent),locals:core.Read(core.Transform),worlds:core.Read(core.World_Transform),
    verticals:core.Read(core.Vertical),remotes:core.Read(core.Remote),problems:^core.Problems,
) {
    axes:=input.input_map_has(bindings.ptr,input.action_of(move_actions,.Move),.Axis2) && input.input_map_has(bindings.ptr,input.action_of(look_actions,.Look),.Axis2)
    for row in 0..<core.count(seats) {
        seat:=core.entity_at(seats,row)
        source:=core.at(seats,row)
        body:=source.body
        if body==core.NONE || !core.owned(remotes,body) {continue}
        if !axes {
            core.report(problems,body,"camera.seat_actions","a seat drives this body, and its actions move and look have another kind than Axis2 in the input map; give them that kind in input.mirai")
            continue
        }
        vertical:=core.vertical_of(verticals,body)
        move:=core.edit(moves,body)
        if move==nil {
            // It starts looking where it faces: by its Transform, since a body spawned in this tick has no World_Transform yet.
            first:input.Move_Input
            if placed,ok:=core.world_of(locals,parents,body);ok {first.look_yaw=yaw_in(vertical,placed.rotation)}
            core.add(moves,body,first)
            move=core.added(moves,body)
            if move==nil {continue}
        }
        if turned,ok:=core.get(verticals,body);ok {move.look_yaw=mm.angle_wrap(move.look_yaw+turned.turn)}
        move.buttons=input.seat_buttons(seats,seat,bindings.ptr)
        wish:=input.seat_vector(move_actions,seat,.Move)
        camera,_:=seat_camera(shown.ptr,seats,cameras,hierarchy,seat)
        follow,follows_it:=core.get(follows,camera)
        yaw:f32
        if camera==core.NONE {
            move.look_pitch=0
        } else if follows_it && (follow.mode==.Eyes || follow.mode==.Orbit && follow.aim) || !follows_it && core.is_under(parents,camera,body) {
            // Changing to it, the body starts looking where the camera it left looked.
            if input.seat_local(source) && int(source.slot)<len(views.slots) {
                if left:=views.slots[source.slot].camera;left!=core.NONE && left!=camera {
                    if placed,ok:=core.get(worlds,left);ok {
                        forward:=mm.quat_rotate(conj(vertical),mm.quat_forward(placed.rotation))
                        move.look_yaw=mm.yaw_of_direction(forward)
                        move.look_pitch=math.asin(clamp(forward.y,-1,1))+(follows_it && follow.mode==.Orbit?follow.pitch:0)
                    }
                }
            }
            look:=input.seat_vector(look_actions,seat,.Look)*input.LOOK_SPEED
            low,high:f32=-PITCH_LIMIT,PITCH_LIMIT
            if follows_it {
                low,high=pitch_limits(follow)
                // An Orbit pitches the other way, from its own pitch.
                if follow.mode==.Orbit {low,high=follow.pitch-high,follow.pitch-low}
            }
            move.look_yaw=mm.angle_wrap(move.look_yaw-look.x)
            move.look_pitch=clamp(move.look_pitch+look.y,low,high)
            move.move=mm.quat_rotate(vertical*mm.quat_axis_angle({0,1,0},move.look_yaw),[3]f32{wish.x,0,-wish.y})
            continue
        } else {
            move.look_pitch=0
            if placed,ok:=core.get(worlds,camera);ok {yaw=yaw_in(vertical,placed.rotation)}
        }
        toward:=mm.quat_rotate(mm.quat_axis_angle({0,1,0},yaw),[3]f32{wish.x,0,-wish.y})
        move.move={}
        // It faces where it goes.
        if amount:=linalg.length(toward);amount>0.001 {
            move.look_yaw=mm.yaw_of_direction(toward)
            move.move=mm.quat_rotate(vertical,toward/max(amount,1))
        }
    }
}

// The yaw of a rotation about the up of a vertical frame: of where it looks,
// or, looking straight down or up, of its up.
@(private)
yaw_in :: proc "contextless" (vertical,rotation:mm.Quat) -> f32 {
    forward:=mm.quat_rotate(conj(vertical),mm.quat_forward(rotation))
    if linalg.length(forward.xz)<1e-3 {forward=mm.quat_rotate(conj(vertical),mm.quat_rotate(rotation,{0,1,0}))*(forward.y>0?-1:1)}
    return mm.yaw_of_direction(forward)
}

// The free camera of player 1: made where the Play of the editor put the
// player while its seat drives nothing, flown by its Move_Input, and gone
// once the seat drives something else.
@(step="fixed",stage="input",after="camera_drive")
camera_free :: proc(
    es:core.Commands,free:^Free_Camera,seats:core.Read(input.Seat),seat_state:core.Ref(input.Seats),requests:^input.Seat_Requests,
    cameras:^core.Table(render.Camera),transforms:^core.Table(core.Transform),moves:core.Read(input.Move_Input),
    origin:core.Ref(scene.Play_Origin),network:core.Ref(core.Network),hierarchy:core.Ref(core.Hierarchy),time:core.Time,
) {
    seat:=seat_state.local_count>0?input.local_seat(seats,0):core.NONE
    body:=input.body_of(seats,seat)
    if body!=core.NONE && body!=free.entity {free.bodied=true}
    if free.entity!=core.NONE {
        if !core.alive(es.entities,free.entity) {
            free.entity=core.NONE
        } else if body!=free.entity && body!=core.NONE || seat==core.NONE {
            core.destroy_tree(es.entities,hierarchy,free.entity)
            free.entity=core.NONE
        } else if row:=core.edit(transforms,free.entity);row!=nil && body==free.entity {
            move,_:=core.get(moves,free.entity)
            look:=mm.quat_from_euler({move.look_pitch,move.look_yaw,0})
            across:=mm.quat_rotate(mm.quat_axis_angle({0,1,0},-move.look_yaw),move.move)
            row.position+=mm.quat_rotate(look,across)*FREE_CAMERA_SPEED*time.dt
            row.rotation=look
        }
        return
    }
    if !origin.set || free.bodied || network.role==.Client || seat==core.NONE || body!=core.NONE {return}
    for camera in cameras.values[:core.count(cameras)] {
        if camera.active {return}
    }
    e:=core.create(es)
    core.add(transforms,e,core.Transform{origin.position,origin.rotation,{1,1,1}})
    core.add(cameras,e,render.CAMERA_DEFAULT)
    input.drive(requests,seat,e)
    free.entity=e
}
