package animation_physics

import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import "mirai:std/base"
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
    bodies:core.Table(Root_Motion_Body),
    verticals:core.Table(core.Vertical),
    found:core.Table(phys.Character_State),
    animations:core.Table(anim.Animation),
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

// With a Root_Motion_Body, the root motion of the whole animation of a Character (a clip that
// strides and turns) is one tick of a layered move of its mix that moves it across its up and
// turns it as the root turns; one an action moves takes the action's instead, one without the
// component none, and one that climbs gets the climb's, an Override with its vertical.
@(test)
the_root_motion_of_an_animation_walks_and_turns_a_character_with_a_root_motion_body :: proc(t:^testing.T) {
    w:Body_Move_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    walker,acting,plain,climber:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    yaw:=mm.quat_axis_angle({0,1,0},math.PI/2) // its -Z, its front, is -X of the world
    resize(&w.playback.rows,core.entity_index(climber)+1)
    for e,i in ([4]core.Entity{walker,acting,plain,climber}) {
        core.add(&w.states,e,locomotion.Locomotion_State{mode=locomotion.MODE_MANTLING if e==climber else locomotion.MODE_WALKING})
        core.add(&w.worlds,e,core.World_Transform{transform={rotation=yaw,scale={1,1,1}}})
        if e!=plain && e!=climber {core.add(&w.bodies,e,ROOT_MOTION_BODY_DEFAULT)}
        // .1 forward and .05 up in .1 s, turning .05 rad left.
        state:=anim.Playing{entity=e,root_enabled=true,motion={translation={0,.05,-.1},rotation=mm.quat_axis_angle({0,1,0},.05)}}
        if e==acting {state.body_motion={translation={0,0,-.1},move=.Additive}}
        append(&w.playback.states,state);w.playback.rows[core.entity_index(e)]=i32(i+1)
    }
    test_world_settle(&w)
    animation_root_motion(core.read(&w.bodies),core.read(&w.states),core.read(&w.worlds),core.read(&w.verticals),core.read(&w.paces),core.ref(&w.playback),&w.moves,{playing=true,dt=.1},core.CLOCK_DEFAULT)
    if !testing.expect_value(t,len(w.moves.queue.items),2) {return}
    walked,climbed:=w.moves.queue.items[0],w.moves.queue.items[1]
    testing.expectf(t,walked.entity==walker && walked.move.mix==.Additive && walked.move.ticks==1 && walked.move.id==ROOT_MOTION_MOVE && linalg.length(walked.move.velocity-mm.Vec3{-1,0,0})<1e-4 && abs(walked.move.turn-.5)<1e-4,"%v",walked)
    testing.expectf(t,climbed.entity==climber && climbed.move.mix==.Override && climbed.move.id==MANTLE_ROOT_MOVE && linalg.length(climbed.move.velocity-mm.Vec3{-1,.5,0})<1e-4,"%v",climbed)
    // Override and vertical keep the rise; a root that does not turn leaves the look to turn the body.
    move:=root_layered_move({translation={0,.05,-.1},rotation=1},{move=.Override,vertical=true},{transform={rotation=1,scale={1,1,1}}},mm.QUAT_IDENTITY,.1)
    testing.expectf(t,move.mix==.Override && move.turn==0 && linalg.length(move.velocity-mm.Vec3{0,.5,-1})<1e-4,"%v",move)
}

// The grounding of the rig of a Character weighs 1 while it stands and 0 in the air, every tick and
// without a game asking; a Character whose rig grounds nothing, or with no animation, gets nothing.
@(test)
the_grounding_of_a_character_follows_whether_it_stands :: proc(t:^testing.T) {
    w:Body_Move_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    standing,flying,ungrounded,still:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    set:=base.Asset_Id{7,7}
    characters:anim.Character_Assets
    defer anim.character_assets_free(&characters)
    resize(&characters.contents,2)
    legs:=[1]anim.Grounded_Leg{}
    characters.contents[0].id,characters.contents[0].valid=set,true
    characters.contents[0].set.pose.grounding.legs=legs[:]
    base.text_set(characters.contents[0].set.pose.grounding.name[:],"feet")
    defer characters.contents[0].set.pose.grounding.legs=nil
    characters.contents[1].id,characters.contents[1].valid=set,true
    modifiers:anim.Modifier_Runtime
    defer delete(modifiers.rigs)
    defer delete(modifiers.rows)
    resize(&modifiers.rows,core.entity_index(still)+1)
    for e,i in ([4]core.Entity{standing,flying,ungrounded,still}) {
        core.add(&w.found,e,phys.Character_State{standing=e!=flying})
        if e!=still {core.add(&w.animations,e,anim.Animation{asset=set})}
        append(&modifiers.rigs,anim.Modifier_Rig{entity=e,asset=set,character=2 if e==ungrounded else 1})
        modifiers.rows[core.entity_index(e)]=i32(i+1)
    }
    test_world_settle(&w)
    requests:anim.Animation_Requests
    defer delete(requests.modifiers.items)
    animation_grounding(core.read(&w.found),core.read(&w.animations),core.ref(&modifiers),core.ref(&characters),&requests)
    if !testing.expect_value(t,len(requests.modifiers.items),2) {return}
    rigs,weights:=[2]core.Entity{standing,flying},[2]f32{1,0}
    for asked,i in requests.modifiers.items {
        testing.expectf(t,asked.rig==rigs[i] && asked.kind==.Grounding && asked.name==base.name_hash("feet") && asked.enabled && asked.goal && asked.weight==weights[i],"%v",asked)
    }
}
