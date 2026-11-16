package locomotion_editor

import "mirai:core"
import "mirai:editor"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

// What locomotion tells the bots that play a game of a body it walks: its Walk, the step of its
// Character and its height once a step made its capsule.
@(storage)
Locomotion_Bodies :: struct {provider:editor.Body_Provider}

LOCOMOTION_BODIES_DEFAULT :: Locomotion_Bodies{provider={measure=walk_measure}}

@(private)
walk_measure :: proc(w:core.World_Ref,body:core.Entity) -> (measure:editor.Body_Measure,known:bool) {
    walks,characters,states:=core.world_table_of(w,locomotion.Walk),core.world_table_of(w,phys.Character),core.world_table_of(w,phys.Character_State)
    if walks==nil || characters==nil {return}
    walk:=core.get(walks,body) or_return
    character:=core.get(characters,body) or_return
    measure={step_height=character.step_height,speed=walk.max_speed,jump_height=walk.jump_height}
    if states!=nil {
        if state,stepped:=core.get(states,body);stepped {measure.height=state.height}
    }
    return measure,true
}
