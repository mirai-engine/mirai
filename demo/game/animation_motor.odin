package game

import inp "mirai:engine/input"
import "core:math"
import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import locomotion "plugins:locomotion/runtime"

@(component,description="Converts horizontal animation root motion into physical character movement and facing. Collision and the character speed limit can prevent reaching a warp target.")
Animation_Motor :: struct {enabled:bool}
ANIMATION_MOTOR_DEFAULT :: Animation_Motor{enabled=true}

animation_motor_input :: proc "contextless" (delta:anim.Root_Delta,actor:mm.Transform,max_speed,dt:f32) -> (input:inp.Move_Input) {
    rotation:=actor.rotation*delta.rotation;forward:=mm.quat_forward(rotation);input.look_yaw=mm.yaw_of_direction(forward)
    if dt<=0 || max_speed<=0 || abs(dt)>max(f32) || abs(max_speed)>max(f32) {return}
    velocity:=mm.quat_rotate(actor.rotation,delta.translation*actor.scale)/(dt*max_speed);velocity.y=0
    if length:=linalg.length(velocity);length>1 {velocity/=length}
    input.move=velocity
    return
}

// After the animation is sampled, a character with a motor moves by its root
// motion instead of what its seat or its AI asked.
@(step="fixed",stage="apply")
animation_motor_drive :: proc(motors:core.Read(Animation_Motor),inputs:^core.Table(inp.Move_Input),walks:core.Read(locomotion.Walk),worlds:core.Read(core.World_Transform),playback:core.Ref(anim.Playback),time:core.Time) {
    if !time.playing {return}
    for row in 0..<core.count(motors) {
        entity:=core.entity_at(motors,row)
        input:=core.edit(inputs,entity)
        config,configured:=core.get(walks,entity)
        actor,placed:=core.get(worlds,entity)
        if input==nil || !configured || !placed {continue}
        // A motor turned off leaves the body to what its seat or its AI asked.
        if !core.at(motors,row).enabled {continue}
        delta,present:=anim.animation_root_delta(playback.ptr,entity)
        if !present {delta=anim.ROOT_DELTA_DEFAULT}
        if value:=animation_motor_input(delta,mm.Transform(actor),config.max_speed,time.dt);value!=input^ {input^=value}
    }
}
