package game

import "mirai:core"
import inp "mirai:engine/input"
import mm "mirai:std/math"

// Turns its entity around the vertical axis, the other way while the action
// reverse is held.
@(component)
Spinner :: struct {speed:f32 `mirai:"unit=rad/s"`}

// The actions of the game.
@(actions)
Action :: enum u8 {Reverse}

// Their bindings. The editor (Project Settings > Input), settings.set and the
// player keep in Input_Settings of settings.mirai only what they change of these.
action_defaults :: proc "contextless" () -> [Action]inp.Action_Bindings {
    return {.Reverse=inp.action_default(.Button,inp.binding_key(.R),inp.binding_gamepad_button(.East))}
}

@(step="fixed")
game_spin :: proc(spinners:core.Read(Spinner),transforms:^core.Table(core.Transform),actions:inp.Input_Of(Action),time:core.Time) {
    turn:=f32(inp.down(actions,.Reverse)?-1:1)*time.dt
    for row in 0..<core.count(spinners) {
        local:=core.free(transforms,core.entity_at(spinners,row))
        if local==nil {continue}
        local.rotation=mm.quat_axis_angle({0,1,0},core.at(spinners,row).speed*turn)*local.rotation
    }
}
