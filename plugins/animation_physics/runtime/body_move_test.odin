package animation_physics

import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

@(private) @(test_world) Body_Move_World :: struct {
    using world:Test_World,
    characters:core.Table(phys.Character),
    states:core.Table(locomotion.Locomotion_State),
    worlds:core.Table(core.World_Transform),
    paces:core.Table(core.Own_Pace),
    playback:anim.Playback,
    moves:locomotion.Locomotion_Requests,
}

// The root motion the actions of a Character give its body is one tick of a layered move of their
// mix: in the world from where the body stands, in the body's own time and across its up unless the
// action keeps the vertical. A climbing Character, or one no such action moves, gets none.
@(test)
the_root_motion_of_an_action_that_moves_its_body_moves_its_character_for_one_tick :: proc(t:^testing.T) {
    w:Body_Move_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    walker,climber,still:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    yaw:=mm.quat_axis_angle({0,1,0},math.PI/2) // its -Z, its front, is -X of the world
    resize(&w.playback.rows,core.entity_index(still)+1)
    for e,i in ([3]core.Entity{walker,climber,still}) {
        core.add(&w.characters,e,phys.Character{})
        core.add(&w.states,e,locomotion.Locomotion_State{mode=locomotion.MODE_MANTLING if e==climber else locomotion.MODE_WALKING})
        core.add(&w.worlds,e,core.World_Transform{transform={rotation=yaw,scale={2,2,2}}})
        state:=anim.Playing{entity=e}
        if e!=still {state.body_motion={translation={0,.1,-.05},move=.Additive}}
        append(&w.playback.states,state);w.playback.rows[core.entity_index(e)]=i32(i+1)
    }
    core.add(&w.paces,walker,core.Own_Pace{rate=.5})
    test_world_settle(&w)
    animation_body_move(core.read(&w.characters),core.read(&w.states),core.read(&w.worlds),{},core.read(&w.paces),core.ref(&w.playback),&w.moves,{playing=true,dt=.1},core.CLOCK_DEFAULT)
    if !testing.expect_value(t,len(w.moves.queue.items),1) {return}
    // .05 forward (-Z) at twice its size in .05 s of its own time; its .1 up is dropped.
    asked:=w.moves.queue.items[0]
    testing.expectf(t,asked.entity==walker && asked.kind==.Add_Move && asked.move.mix==.Additive && asked.move.ticks==1 && asked.move.id==BODY_ROOT_MOVE && linalg.length(asked.move.velocity-mm.Vec3{-2,0,0})<1e-4,"%v",asked)
    placed:=core.World_Transform{transform={rotation=yaw,scale={1,1,1}}}
    cases:=[?]struct {body:anim.Body_Motion,up:mm.Quat,velocity:mm.Vec3,mix:locomotion.Move_Mix}{
        {{translation={0,.1,-.1},move=.Override,vertical=true},mm.QUAT_IDENTITY,{-1,1,0},.Override},
        // A body whose up is -X of the world (core.Vertical) keeps the motion across that up.
        {{translation={0,.1,-.1},move=.Additive},mm.quat_axis_angle({0,0,1},math.PI/2),{0,1,0},.Additive},
    }
    for c in cases {
        move:=body_layered_move(c.body,placed,c.up,.1)
        testing.expectf(t,move.mix==c.mix && linalg.length(move.velocity-c.velocity)<1e-4,"%v: %v",c.body,move)
    }
}
