package scene

import mm "mirai:std/math"

// Where the Play of the editor puts the player, facing level. Unset in a
// game, where a body without a Spawn_Point is a problem of the scene.
// Without asked it is the camera of the editor when the Play began: a body
// for a player that has no Spawn_Point to appear at appears there. With
// asked (Play from here, Play from camera) the first body of player 1
// appears there before any Spawn_Point.
@(storage)
Play_Origin :: struct {
    position:[3]f32,
    rotation:mm.Quat,
    set:bool,
    asked:bool,
}
