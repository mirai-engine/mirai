package animation_physics

import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// Actions that move their body. While an action whose body_move is not None plays on a Character,
// in a layer or over the whole body of its .match (a lunge, a slash that steps in, a vault, a death
// that falls forward), the root motion its actions give the body in this tick
// (anim.animation_body_motion: by their share of the root, mirrored and warped with it) becomes a
// one-tick layered move of its mix, across the up of the Character unless the action keeps the
// vertical. A game writes no code for it, and names no locomotion mode: the Character keeps the
// one it has. A climb is driven by its own (mantle.odin).
BODY_ROOT_MOVE :: u32(0x41435452) // the id of its layered moves

@(step="fixed",stage="apply")
animation_body_move :: proc(characters:core.Read(phys.Character),worlds:core.Read(core.World_Transform),verticals:core.Read(core.Vertical),paces:core.Read(core.Own_Pace),playback:core.Ref(anim.Playback),moves:^phys.Locomotion_Requests,time:core.Time,clock:core.Clock) {
    if !(time.dt>0) {return}
    for row in 0..<core.count(characters) {
        character:=core.at(characters,row)
        if character.mode==phys.MODE_MANTLING {continue}
        entity:=core.entity_at(characters,row)
        body,moving:=anim.animation_body_motion(playback.ptr,entity)
        placed,ok:=core.get(worlds,entity)
        if !moving || !ok {continue}
        phys.add_move(moves,entity,body_layered_move(body,placed,core.vertical_of(verticals,entity),time.dt*core.pace_of(clock,paces,entity),character.mass))
    }
}

// The layered move of one tick of dt seconds of the body's own time that the root motion of its
// actions asks for, placed where the body is and with up the +Y of up_frame (core.Vertical). Its
// force reaches the velocity in that tick for a body of mass kg: a root that lunges faster than
// traction drives the body is followed, and an Additive one is not counted as the walk's own.
body_layered_move :: proc "contextless" (body:anim.Body_Motion,placed:core.World_Transform,up_frame:mm.Quat,dt:f32,mass:f32) -> phys.Layered_Move {
    velocity:=root_velocity(body.translation,placed,dt)
    if !body.vertical {up:=mm.quat_rotate(up_frame,mm.Vec3{0,1,0});velocity-=up*linalg.dot(velocity,up)}
    force:=max(mass,0)*linalg.length(velocity)/dt
    if !(force>=0) || !(force<max(f32)) {force=0}
    return {velocity=velocity,force=force,ticks=1,mix=.Override if body.move==.Override else .Additive,id=BODY_ROOT_MOVE}
}

// The velocity in the world of a root that moves translation, in the space of the entity placed so,
// in dt seconds of the entity's own time: the time of the layered moves of its Character.
root_velocity :: proc "contextless" (translation:mm.Vec3,placed:core.World_Transform,dt:f32) -> mm.Vec3 {
    return mm.quat_rotate(placed.rotation,translation*placed.scale)/dt
}
