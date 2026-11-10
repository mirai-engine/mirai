package physics_multiplayer

import "mirai:core"
import multiplayer "plugins:multiplayer/runtime"
import phys "plugins:physics/runtime"

// Lag compensation against the colliders of physics: the server judges a shot
// where the player who fired saw the others, and nothing moves.

// The nearest entity with multiplayer.Rewind that a ray hits where each was at
// tick: the one multiplayer.rewind_tick gives for the connection that fired.
// ignore is who fired.
rewind_raycast :: proc(
    history:^multiplayer.Rewind_History,physics:core.Ref(phys.Physics_State),marked:core.Read(multiplayer.Rewind),
    tick:f64,origin,direction:[3]f32,max_distance:f32=1000,ignore:=core.NONE,
) -> (hit:phys.Hit,ok:bool) {
    for row in 0..<core.count(marked) {
        e:=core.entity_at(marked,row)
        if e==ignore {continue}
        position,rotation:=multiplayer.rewind_pose(history,e,tick) or_continue
        found:=phys.raycast_at(physics,e,position,rotation,origin,direction,ok?hit.distance:max_distance) or_continue
        hit,ok=found,true
    }
    return
}
