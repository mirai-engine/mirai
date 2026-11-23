package animation_physics

import "core:math/linalg"
import "mirai:core"
import "mirai:host"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

// Locomotion animated by the physics. Every tick, each Character with an Animation tells its
// motion matching (the locomotion of the .character in Animation.asset) what its body did in the
// simulation of this tick and what its locomotion heads to: the mode it is in, the velocity of the
// body, the velocity its mode drives toward at its acceleration and braking, where it turns and how
// fast (all published by locomotion on Locomotion_State, which only locomotion writes), the wall it
// leans on, which its trajectory does not go into, and, while it falls and the clips of that mode
// play toward a landing marker, when it lands on the arc it follows (phys.character_landing).
// Velocities that run along the ground are across the up of its core.Vertical, a planet's too.
// While it walks a clip of matching, the warping of its .character stretches the stride to the
// speed of the root of its pose. A game writes no code for locomotion; the clips and their modes
// are in the .character.
@(step="fixed",stage="simulate",after="physics_step",before="animation_sample")
animation_locomotion :: proc(states:^core.Table(locomotion.Locomotion_State,.Read),found:^core.Table(phys.Character_State,.Read),animations:^core.Table(anim.Animation,.Read),motions:^core.Table(core.Motion,.Read),mantles:^core.Table(locomotion.Mantle_State,.Read),worlds:^core.Table(core.World_Transform,.Read),verticals:^core.Table(core.Vertical,.Read),playback:core.Ref(anim.Playback),physics:core.Ref(phys.Physics_State),requests:^anim.Animation_Requests,sets:core.Ref(anim.Character_Assets),app:^host.App) {
    if app==nil || app.assets==nil {return}
    for row in 0..<core.count(states) {
        entity:=core.entity_at(states,row)
        animation,animated:=core.get(animations,entity)
        if !animated {continue}
        id:=anim.animation_character(app.assets,animation)
        set:=anim.character_cached(sets,id)
        if set==nil || len(set.set.match.clips)==0 {continue}
        character:=core.at(states,row)
        going,_:=core.get(motions,entity)
        placed,_:=core.get(worlds,entity)
        state,_:=core.get(found,entity)
        goal:=locomotion_goal(entity,character,going.linear,state.wall_normal)
        playing,matching:=anim.animation_match(playback,entity)
        if matching && character.mode==locomotion.MODE_FALLING && playing.landing_modes&(1<<u32(locomotion.MODE_FALLING))!=0 {
            if time,_,lands:=phys.character_landing(physics,entity);lands {goal.time_to_land=time}
        }
        // The clip of the climb warps onto where it ends (root_motion.odin).
        if character.mode==locomotion.MODE_MANTLING && matching {
            if climb,climbing:=core.get(mantles,entity);climbing {anim.motion_target(requests,entity,MANTLE_WINDOW,mantle_target(climb,placed.rotation))}
        }
        anim.match_goal(requests,goal)
        if !matching {continue}
        // The warping corrects what the clip travels, in its own direction, toward the body: a clip
        // that strafes or backs off is not turned as if it went forward.
        along:=playing.travel if playing.travel!={} else mm.FORWARD
        walking:=character.mode==locomotion.MODE_WALKING || character.mode==locomotion.MODE_CROUCHING
        anim.motion_locomotion(requests,{rig=entity,velocity=across_up(going.linear,core.vertical_of(verticals,entity)),source_velocity=mm.quat_rotate(placed.rotation,along*playing.speed),weight=1,enabled=walking && !playing.forced && playing.speed>0})
    }
}

// The goal of the matching of a body that goes at velocity, from what its locomotion published.
locomotion_goal :: proc "contextless" (rig:core.Entity,character:locomotion.Locomotion_State,velocity,wall:mm.Vec3) -> anim.Match_Goal {
    return {rig=rig,mode=u16(character.mode),velocity=velocity,desired=character.desired,facing=character.facing,wall=wall,
        acceleration=character.acceleration,braking=character.braking,turn_rate=character.turn_speed}
}

// A velocity across the up of up_frame (core.Vertical): what goes along the ground.
across_up :: proc "contextless" (velocity:mm.Vec3,up_frame:mm.Quat) -> mm.Vec3 {
    up:=mm.quat_rotate(up_frame,mm.Vec3{0,1,0})
    return velocity-up*linalg.dot(velocity,up)
}
