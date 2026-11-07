package animation_physics

import "mirai:core"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// A climb animated with root motion. While a Character mantles, the motion warping of its Animation
// takes the root of the clip that plays onto where the climb ends (Character.mantle_to), through a
// window named MANTLE_WINDOW in its Animation.motion on the clip of the climb (animation_locomotion
// gives the target), and the root motion of every tick drives the climb (an Override layered move),
// so the body climbs as the clip does and lands on the ledge. A climb without root motion follows
// its own way (phys.mantle_move).
MANTLE_WINDOW :: "mantle"
MANTLE_ROOT_MOVE :: u32(0x4d4e544c) // the id of its layered moves

@(step="fixed",stage="apply",after="animation_sample")
animation_mantle :: proc(characters:core.Read(phys.Character),worlds:core.Read(core.World_Transform),playback:core.Ref(anim.Playback),moves:^phys.Locomotion_Requests,time:core.Time) {
    if !(time.dt>0) {return}
    for row in 0..<core.count(characters) {
        if core.at(characters,row).mode!=phys.MODE_MANTLING {continue}
        entity:=core.entity_at(characters,row)
        delta,rooted:=anim.animation_root_delta(playback.ptr,entity)
        placed,ok:=core.get(worlds,entity)
        if !rooted || !ok {continue}
        velocity:=mm.quat_rotate(placed.rotation,delta.translation*placed.scale)/time.dt
        phys.add_move(moves,entity,{velocity=velocity,ticks=1,mix=.Override,id=MANTLE_ROOT_MOVE})
    }
}

// The target of the warping of a climb: the feet where it ends, facing as the body faces.
mantle_target :: proc "contextless" (character:phys.Character,facing:mm.Quat) -> anim.Spatial_Target {
    return {kind=.World,position=character.mantle_to,rotation=facing,scale=1}
}
