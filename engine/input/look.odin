package input

import "core:math"
import "mirai:core"
import mm "mirai:std/math"

// A turn of where a body looks that gameplay asks in a fixed tick: the kick of a recoil. It turns
// the look of the Move_Input of the body, which a camera that looks with the body follows, and so
// the view of its seat and its aim (aim) from then on, on every end alike, also in a tick run
// again. What brings the look back is more kicks the game asks; a camera that turns apart from
// the body is not turned.
Look_Kick :: struct {
    body:core.Entity,
    yaw,pitch:f32, // radians: yaw turns left about the up of the body, pitch looks up
}

// Many push; input_look_kicks takes them in the next tick.
@(storage,queue)
Look_Kicks :: struct {queue:core.Queue(Look_Kick)}

LOOK_KICKS :: 256 // a tick can ask this many

// Turns where body looks by yaw and pitch radians, each within half a turn, from the next tick.
look_kick :: proc(kicks:^Look_Kicks,body:core.Entity,yaw,pitch:f32) {
    if kicks==nil {return}
    if body==core.NONE || !(abs(yaw)<=math.PI) || !(abs(pitch)<=math.PI) {core.refuse(&kicks.queue);return}
    core.offer(&kicks.queue,Look_Kick{body,yaw,pitch})
}

// The kicks asked since the last tick turn the Move_Input of their bodies: a body without one has
// nothing to turn.
@(step="fixed",stage="input",after="input_drive")
input_look_kicks :: proc(kicks:^Look_Kicks,moves:^core.Table(Move_Input),problems:^core.Problems) {
    core.queue_serve(&kicks.queue,LOOK_KICKS,problems,"input.look_kicks","look kicks","the look kick capacity (LOOK_KICKS)","name a body, and turns within half a turn")
    for kick in core.take(&kicks.queue) {
        move:=core.edit(moves,kick.body)
        if move==nil {continue}
        move.look_yaw=mm.angle_wrap(move.look_yaw+kick.yaw)
        move.look_pitch+=kick.pitch
    }
}
