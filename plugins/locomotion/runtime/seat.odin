package locomotion

import "core:math/linalg"
import "mirai:core"
import cam "mirai:engine/camera"
import input "mirai:engine/input"
import render "mirai:engine/render"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// The actions the seat that drives a Character moves it with, with
// input.Look_Action: move is an Axis2 (x right, y forward), jump, sprint and crouch Buttons.
@(actions)
Walk_Action :: enum u8 {Move,Jump,Sprint,Crouch}

// Their bindings when input.mirai of the project does not name them.
walk_action_defaults :: proc "contextless" () -> [Walk_Action]input.Action_Default {
    return {
        .Move=input.action_default(.Axis2,input.binding_keys(.A,.D,.S,.W),input.binding_gamepad_stick(.Left)),
        .Jump=input.action_default(.Button,input.binding_key(.Space),input.binding_gamepad_button(.South)),
        .Sprint=input.action_default(.Button,input.binding_key(.Left_Shift),input.binding_gamepad_button(.Left_Stick)),
        .Crouch=input.action_default(.Button,input.binding_key(.Left_Control),input.binding_gamepad_button(.Right_Stick)),
    }
}

// The Move_Input of every Character a seat drives comes from the move and
// look actions of that seat, toward the forward the move_relative_to of its
// Drivable says, with the buttons the seat holds; it turns with the ground it
// stands on. Forward is in the frame of its vertical: the camera and the world
// give the way they look across its up. Moving relative to the camera or the
// world it turns toward its move at the turn_speed of its Character.
// While no seat drives it, while it moves relative to the Game, or where
// another end decides it, the Move_Input stays as whoever else writes it left
// it (the game, an AI, the network).
@(step="fixed",stage="input")
locomotion_seat :: proc(
    states:^core.Table(Locomotion_State,.Read),characters:^core.Table(phys.Character,.Read),moves:^core.Table(input.Move_Input),found:^core.Table(phys.Character_State,.Read),
    drivables:^core.Table(input.Drivable,.Read),walk_actions:input.Input_Of(Walk_Action),look_actions:input.Input_Of(input.Look_Action),bindings:core.Ref(input.Input_Map),
    follows:^core.Table(cam.Camera_Follow,.Read),shown:core.Ref(cam.Cameras),cameras:^core.Table(render.Camera,.Read),
    worlds:^core.Table(core.World_Transform,.Read),remotes:^core.Table(core.Remote,.Read),physics:core.Ref(phys.Physics_State),paces:^core.Table(core.Own_Pace,.Read),
    time:core.Time,clock:core.Clock,problems:^core.Problems,
) {
    walks:=input.input_map_has(bindings.ptr,input.action_of(walk_actions,.Move),.Axis2) && input.input_map_has(bindings.ptr,input.action_of(look_actions,.Look),.Axis2)
    driven:=core.join(states,drivables)
    for e,state,owner in core.each_joined(&driven) {
        if owner.seat==core.NONE || owner.move_relative_to==.Game || !state.ready || !core.owned(remotes,e) {continue}
        move:=core.edit(moves,e)
        if move==nil {continue}
        if !walks {
            core.report(problems,e,"locomotion.seat_action","a seat drives its Character, whose actions move and look have another kind than Axis2 in the input map; give them that kind in input.mirai, or give its Drivable move_relative_to Game and write its Move_Input in the game")
            continue
        }
        seat:=owner.seat
        if ground,on:=core.get(found,e);on {move.look_yaw+=ground.ground_turn}
        look:=input.seat_vector(look_actions,seat,.Look)
        wish:=input.seat_vector(walk_actions,seat,.Move)
        move.buttons=input.seat_buttons(walk_actions.seats,seat,bindings.ptr)
        relative:=owner.move_relative_to
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
            move.look_pitch=clamp(move.look_pitch+look.y*input.LOOK_SPEED,-owner.pitch_limit,owner.pitch_limit)
            move.move={wish.x,0,-wish.y}
        case .Camera,.World:
            looking:=mm.QUAT_IDENTITY
            if relative==.Camera {
                if placed,ok:=core.get(worlds,view);ok {looking=placed.rotation}
            }
            frame:=mm.QUAT_IDENTITY
            if capsule,made:=phys.character_capsule(physics,e);made {frame=capsule.up_frame}
            yaw:=phys.look_yaw_of(frame,looking)
            toward:=mm.quat_rotate(mm.quat_axis_angle({0,1,0},yaw),[3]f32{wish.x,0,-wish.y})
            move.look_pitch=0
            move.move={}
            // It turns toward its move or, facing, toward where the camera looks.
            amount:=linalg.length(toward)
            if facing || amount>0.001 {
                desired:=facing?yaw:mm.yaw_of_direction(toward)
                body,_:=core.get(characters,e)
                turn:=body.turn_speed>0?body.turn_speed*time.dt*core.pace_of(clock,paces,e):mm.PI
                move.look_yaw=mm.angle_wrap(mm.angle_approach(move.look_yaw,desired,turn))
            }
            if amount>0.001 {move.move=mm.quat_rotate(mm.quat_axis_angle({0,1,0},-move.look_yaw),toward/max(amount,1))}
        case .Game,.View:
        }
    }
}
