package game

import locomotion "plugins:locomotion/runtime"
import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

@(component,description="Converts horizontal animation root motion into physical character movement and facing. Collision and the character speed limit can prevent reaching a warp target.")
Animation_Motor :: struct {
    enabled:bool,
    driving:bool `mirai:"transient,hidden"`,
}
ANIMATION_MOTOR_DEFAULT :: Animation_Motor{enabled=true}

animation_motor_input :: proc "contextless" (delta:anim.Root_Delta,actor:mm.Transform,dt:f32) -> (input:locomotion.Locomotion_Drive) {
    rotation:=actor.rotation*delta.rotation;forward:=mm.quat_forward(rotation);input.look_yaw=mm.yaw_of_direction(forward)
    if !(dt>0) || dt>max(f32) {return}
    velocity:=mm.quat_rotate(actor.rotation,delta.translation*actor.scale)/dt;velocity.y=0
    if linalg.length(velocity)<max(f32) {input.velocity=velocity}
    return
}

// After the animation is sampled, a character with a motor moves by its root
// motion instead of what its seat or its AI asked.
@(step="fixed",stage="apply")
animation_motor_drive :: proc(motors:^core.Table(Animation_Motor),drives:^core.Table(locomotion.Locomotion_Drive),worlds:^core.Table(core.World_Transform,.Read),playback:core.Ref(anim.Playback),time:core.Time) {
    if !time.playing {return}
    for row in 0..<core.count(motors) {
        entity:=core.entity_at(motors,row)
        actor,placed:=core.get(worlds,entity)
        motor:=core.edit_at(motors,row)
        if !motor.enabled || !placed {
            if motor.driving {core.remove(drives,entity);motor.driving=false}
            continue
        }
        delta,present:=anim.animation_root_delta(playback.ptr,entity)
        if !present {delta=anim.ROOT_DELTA_DEFAULT}
        locomotion.drive(drives,entity,animation_motor_input(delta,mm.Transform(actor),time.dt))
        motor.driving=true
    }
}
