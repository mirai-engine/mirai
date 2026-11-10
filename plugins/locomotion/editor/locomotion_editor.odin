package locomotion_editor

import "mirai:core"
import "mirai:editor"
import locomotion "plugins:locomotion/runtime"

// What locomotion tells the bots that play a game of a body it moves: how fast it walks and how high it
// jumps, by its Walk. Physics says its size.
@(storage)
Locomotion_Bodies :: struct {provider:editor.Body_Provider}

LOCOMOTION_BODIES_DEFAULT :: Locomotion_Bodies{provider={measure=walk_measure}}

@(private)
walk_measure :: proc(w:core.World_Ref,body:core.Entity) -> (measure:editor.Body_Measure,known:bool) {
    walks:=core.world_table_of(w,locomotion.Walk)
    if walks==nil {return}
    walk:=core.get(walks,body) or_return
    return {speed=walk.max_speed,jump_height=walk.jump_height},true
}
