package game

import inp "mirai:engine/input"
import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

@(component,description="Converts horizontal animation root motion into physical character movement and facing. Collision and the character speed limit can prevent reaching a warp target.")
Animation_Motor :: struct {enabled:bool}
ANIMATION_MOTOR_DEFAULT :: Animation_Motor{enabled=true}

animation_motor_input :: proc "contextless" (delta:anim.Root_Delta,actor:mm.Transform,dt:f32) -> (input:inp.Move_Input) {
    rotation:=actor.rotation*delta.rotation;forward:=mm.quat_forward(rotation);input.look_yaw=mm.yaw_of_direction(forward)
    input.velocity=true
    if !(dt>0) || dt>max(f32) {return}
    velocity:=mm.quat_rotate(actor.rotation,delta.translation*actor.scale)/dt;velocity.y=0
    if linalg.length(velocity)<max(f32) {input.move=velocity}
    return
}

// After the animation is sampled, a character with a motor moves by its root
// motion instead of what its seat or its AI asked.
@(step="fixed",stage="apply")
animation_motor_drive :: proc(motors:^core.Table(Animation_Motor,.Read),inputs:^core.Table(inp.Move_Input),worlds:^core.Table(core.World_Transform,.Read),playback:core.Ref(anim.Playback),time:core.Time) {
    if !time.playing {return}
    for row in 0..<core.count(motors) {
        entity:=core.entity_at(motors,row)
        input:=core.edit(inputs,entity)
        actor,placed:=core.get(worlds,entity)
        if input==nil || !placed {continue}
        // A motor turned off leaves the body to what its seat or its AI asked.
        if !core.at(motors,row).enabled {continue}
        delta,present:=anim.animation_root_delta(playback.ptr,entity)
        if !present {delta=anim.ROOT_DELTA_DEFAULT}
        if value:=animation_motor_input(delta,mm.Transform(actor),time.dt);value!=input^ {input^=value}
    }
}
