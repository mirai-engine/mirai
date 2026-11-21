package game

import locomotion "plugins:locomotion/runtime"
import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

@(component,description="Converts horizontal animation root motion into physical character movement and facing. Collision and the character speed limit can prevent reaching a warp target.")
Animation_Motor :: struct {
    enabled:bool,
}

@(component,derived)
Animation_Motor_State :: struct {enabled:Maybe(bool),driving:bool}
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
animation_motor_drive :: proc(motors:^core.Table(Animation_Motor,.Read),states:^core.Table(Animation_Motor_State),drives:^core.Table(locomotion.Locomotion_Drive),worlds:^core.Table(core.World_Transform,.Read),playback:core.Ref(anim.Playback),time:core.Time,problems:^core.Problems) {
    if !time.playing {return}
    for e in states.entities {
        if core.has(motors,e) {continue}
        if state,found:=core.get(states,e);found && state.driving {core.remove(drives,e)}
        core.remove(states,e)
    }
    for row in 0..<core.count(motors) {
        entity:=core.entity_at(motors,row)
        actor,placed:=core.get(worlds,entity)
        motor:=core.at(motors,row)
        state,_:=core.get(states,entity)
        enabled:=state.enabled.? or_else motor.enabled
        if !enabled || !placed {
            if state.driving {
                core.remove(drives,entity)
                core.edit(states,entity).driving=false
            }
            continue
        }
        if !state.driving {
            next:=demo_state(states,entity,Animation_Motor_State{},problems)
            if next==nil {continue}
            next.driving=true
        }
        delta,present:=anim.animation_root_delta(playback,entity)
        if !present {delta=anim.ROOT_DELTA_DEFAULT}
        locomotion.drive(drives,entity,animation_motor_input(delta,mm.Transform(actor),time.dt))
    }
}
