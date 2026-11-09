package physics

import "core:math/linalg"
import "mirai:core"
import cam "mirai:engine/camera"
import input "mirai:engine/input"
import render "mirai:engine/render"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

// The actions the seat that drives a Character moves it with, with
// input.Look_Action: move is an Axis2 (x right, y forward), jump, sprint and crouch Buttons.
@(actions)
Walk_Action :: enum u8 {Move,Jump,Sprint,Crouch}

// Their bindings when input.mirai of the project does not name them.
@(storage,host)
Walk_Actions :: struct {defaults:[Walk_Action]input.Action_Default}

walk_actions_default :: proc "contextless" () -> Walk_Actions {
    return {defaults={
        .Move=input.action_default(.Axis2,input.binding_keys(.A,.D,.S,.W),input.binding_gamepad_stick(.Left)),
        .Jump=input.action_default(.Button,input.binding_key(.Space),input.binding_gamepad_button(.South)),
        .Sprint=input.action_default(.Button,input.binding_key(.Left_Shift),input.binding_gamepad_button(.Left_Stick)),
        .Crouch=input.action_default(.Button,input.binding_key(.Left_Control),input.binding_gamepad_button(.Right_Stick)),
    }}
}

// The Move_Input of every Character a seat drives comes from the move and
// look actions of that seat, toward the forward its move_relative_to says,
// with the buttons the seat holds; it turns with the ground it stands on.
// Forward is in the frame of its vertical: the camera and the world give the
// way they look across its up.
// While no seat drives it, while it moves relative to the Game, or where
// another end decides it, the Move_Input stays as whoever else writes it left
// it (the game, an AI, the network).
@(step="fixed",stage="input",after="input_drive")
locomotion_seat :: proc(
    characters:core.Read(Character),moves:^core.Table(input.Move_Input),found:core.Read(Character_State),
    drivables:core.Read(input.Drivable),walk_actions:input.Input_Of(Walk_Action),look_actions:input.Input_Of(input.Look_Action),bindings:core.Ref(input.Input_Map),
    follows:core.Read(cam.Camera_Follow),shown:core.Ref(cam.Cameras),cameras:core.Read(render.Camera),
    worlds:core.Read(core.World_Transform),remotes:core.Read(core.Remote),physics:core.Ref(Physics_State),paces:core.Read(core.Own_Pace),
    time:core.Time,clock:core.Clock,problems:^core.Problems,
) {
    walks:=input.input_map_has(bindings.ptr,input.action_of(walk_actions,.Move),.Axis2) && input.input_map_has(bindings.ptr,input.action_of(look_actions,.Look),.Axis2)
    for row in 0..<core.count(characters) {
        e:=core.entity_at(characters,row)
        c:=&characters.table.values[row]
        seat:=input.seat_of(drivables,e)
        if c.move_relative_to==.Game || !c.ready || seat==core.NONE || !core.owned(remotes,e) {continue}
        move:=core.get(moves,e)
        if move==nil {continue}
        if !walks {
            core.report(problems,e,"locomotion.seat_action","a seat drives its Character, whose actions move and look have another kind than Axis2 in the input map; give them that kind in input.mirai, or give it move_relative_to Game and write its Move_Input in the game")
            continue
        }
        if state,on:=core.get(found,e);on {move.look_yaw+=state.ground_turn}
        look:=input.seat_vector(look_actions,seat,.Look)
        wish:=input.seat_vector(walk_actions,seat,.Move)
        move.buttons=input.seat_buttons(walk_actions.seats,seat,bindings.ptr)
        relative:=c.move_relative_to
        owner,_:=core.get(drivables,e)
        view:=owner.camera
        facing:=false
        // View: as the camera the seat sees through wants.
        if relative==.View {
            relative=.Camera
            if seen:=cam.camera_selected(shown.ptr,drivables,cameras,seat);seen!=core.NONE {view=seen}
            if follow,ok:=core.get(follows,view);ok {
                switch {
                case follow.mode==.Eyes || follow.mode==.Orbit && follow.aim: relative=.Look
                case follow.mode==.Orbit && follow.facing: facing=true
                }
            }
        }
        switch relative {
        case .Look:
            move.look_yaw-=look.x*input.LOOK_SPEED
            move.look_pitch=clamp(move.look_pitch+look.y*input.LOOK_SPEED,-c.pitch_limit,c.pitch_limit)
            move.move={wish.x,0,-wish.y}
        case .Camera,.World:
            looking:=mm.QUAT_IDENTITY
            if relative==.Camera {
                if placed,ok:=core.get(worlds,view);ok {looking=placed.rotation}
            }
            yaw:=sim.up_frame_yaw(up_frame_of(physics,e),looking)
            toward:=mm.quat_rotate(mm.quat_axis_angle({0,1,0},yaw),[3]f32{wish.x,0,-wish.y})
            move.look_pitch=0
            move.move={}
            // It turns toward its move or, facing, toward where the camera looks.
            amount:=linalg.length(toward)
            if facing || amount>0.001 {
                desired:=facing?yaw:mm.yaw_of_direction(toward)
                turn:=c.turn_speed>0?c.turn_speed*time.dt*core.pace_of(clock,paces,e):mm.PI
                move.look_yaw=mm.angle_wrap(mm.angle_approach(move.look_yaw,desired,turn))
            }
            if amount>0.001 {move.move=mm.quat_rotate(mm.quat_axis_angle({0,1,0},-move.look_yaw),toward/max(amount,1))}
        case .Game,.View:
        }
    }
}
