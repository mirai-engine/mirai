package animation_physics

import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// The root motion the actions of a Character give its body is one tick of a layered move of their
// mix: in the world from where the body stands, in the body's own time and across its up unless the
// action keeps the vertical. A climbing Character, or one no such action moves, gets none.
@(test)
the_root_motion_of_an_action_that_moves_its_body_moves_its_character_for_one_tick :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    walker,climber,still:=core.create(&entities),core.create(&entities),core.create(&entities)
    characters:core.Table(phys.Character);defer core.table_destroy(&characters)
    worlds:core.Table(core.World_Transform);defer core.table_destroy(&worlds)
    paces:core.Table(core.Own_Pace);defer core.table_destroy(&paces)
    playback:anim.Playback;defer anim.playback_free(&playback)
    yaw:=mm.quat_axis_angle({0,1,0},math.PI/2) // its +Z is +X of the world
    resize(&playback.rows,core.entity_index(still)+1)
    for e,i in ([3]core.Entity{walker,climber,still}) {
        core.add(&characters,e,phys.Character{mode=phys.MODE_MANTLING if e==climber else phys.MODE_WALKING,mass=80})
        core.add(&worlds,e,core.World_Transform{transform={rotation=yaw,scale={2,2,2}}})
        state:=anim.Playing{entity=e}
        if e!=still {state.body_motion={translation={0,.1,.05},move=.Additive}}
        append(&playback.states,state);playback.rows[core.entity_index(e)]=i32(i+1)
    }
    core.add(&paces,walker,core.Own_Pace{rate=.5})
    core.table_settle(&characters,&entities);core.table_settle(&worlds,&entities);core.table_settle(&paces,&entities)
    moves:phys.Locomotion_Requests;defer delete(moves.queue.items)
    animation_body_move(core.read(&characters),core.read(&worlds),{},core.read(&paces),core.ref(&playback),&moves,{playing=true,dt=.1},core.CLOCK_DEFAULT)
    if !testing.expect_value(t,len(moves.queue.items),1) {return}
    // .05 forward at twice its size in .05 s of its own time; its .1 up is dropped. Its force takes
    // the 80 kg body from rest to those 2 m/s in that time.
    asked:=moves.queue.items[0]
    testing.expectf(t,asked.entity==walker && asked.kind==.Add_Move && asked.move.mix==.Additive && asked.move.ticks==1 && asked.move.id==BODY_ROOT_MOVE && linalg.length(asked.move.velocity-mm.Vec3{2,0,0})<1e-4 && abs(asked.move.force-80*2/.05)<1e-2,"%v",asked)
    placed:=core.World_Transform{transform={rotation=yaw,scale={1,1,1}}}
    cases:=[?]struct {body:anim.Body_Motion,up:mm.Quat,velocity:mm.Vec3,mix:phys.Move_Mix}{
        {{translation={0,.1,.1},move=.Override,vertical=true},mm.QUAT_IDENTITY,{1,1,0},.Override},
        // A body whose up is -X of the world (core.Vertical) keeps the motion across that up.
        {{translation={0,.1,.1},move=.Additive},mm.quat_axis_angle({0,0,1},math.PI/2),{0,1,0},.Additive},
    }
    for c in cases {
        move:=body_layered_move(c.body,placed,c.up,.1,80)
        testing.expectf(t,move.mix==c.mix && linalg.length(move.velocity-c.velocity)<1e-4 && abs(move.force-80*linalg.length(c.velocity)/.1)<1e-2,"%v: %v",c.body,move)
    }
}
