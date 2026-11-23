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
// are in the .character. An animated entity that no body of the physics moves but that has a
// core.Motion (an agent of navigation without a Character, a walker of a crowd) walks in the
// matching by its Motion (motion_goal).
@(step="fixed",stage="simulate",after="physics_step",before="animation_sample")
animation_locomotion :: proc(states:^core.Table(locomotion.Locomotion_State,.Read),found:^core.Table(phys.Character_State,.Read),animations:^core.Table(anim.Animation,.Read),motions:^core.Table(core.Motion,.Read),mantles:^core.Table(locomotion.Mantle_State,.Read),worlds:^core.Table(core.World_Transform,.Read),verticals:^core.Table(core.Vertical,.Read),characters:^core.Table(phys.Character,.Read),rigids:^core.Table(phys.Rigid_Body,.Read),walks:^core.Table(locomotion.Walk,.Read),playback:core.Ref(anim.Playback),physics:core.Ref(phys.Physics_State),requests:^anim.Animation_Requests,sets:core.Ref(anim.Character_Assets),app:^host.App) {
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
        walking:=character.mode==locomotion.MODE_WALKING || character.mode==locomotion.MODE_CROUCHING
        locomotion_warp(requests,entity,playing,going.linear,placed.rotation,core.vertical_of(verticals,entity),walking)
    }
    for row in 0..<core.count(animations) {
        entity:=core.entity_at(animations,row)
        going,moves:=core.get(motions,entity)
        if !moves || core.has(states,entity) || core.has(characters,entity) || core.has(rigids,entity) {continue}
        set:=anim.character_cached(sets,anim.animation_character(app.assets,core.at(animations,row)))
        if set==nil || len(set.set.match.clips)==0 {continue}
        placed,_:=core.get(worlds,entity)
        walk,_:=core.get(walks,entity)
        anim.match_goal(requests,motion_goal(entity,going,placed.rotation,walk))
        if playing,matching:=anim.animation_match(playback,entity);matching {
            locomotion_warp(requests,entity,playing,going.linear,placed.rotation,core.vertical_of(verticals,entity),true)
        }
    }
}

// The warping of a walk: it corrects what the clip travels, in its own direction, toward the body
// at velocity: a clip that strafes or backs off is not turned as if it went forward.
@(private)
locomotion_warp :: proc(requests:^anim.Animation_Requests,rig:core.Entity,playing:anim.Animation_Match,velocity:mm.Vec3,rotation,up_frame:mm.Quat,walking:bool) {
    along:=playing.travel if playing.travel!={} else mm.FORWARD
    anim.motion_locomotion(requests,{rig=rig,velocity=across_up(velocity,up_frame),source_velocity=mm.quat_rotate(rotation,along*playing.speed),weight=1,enabled=walking && !playing.forced && playing.speed>0})
}

// The goal of the matching of a body that goes at velocity, from what its locomotion published.
locomotion_goal :: proc "contextless" (rig:core.Entity,character:locomotion.Locomotion_State,velocity,wall:mm.Vec3) -> anim.Match_Goal {
    return {rig=rig,mode=u16(character.mode),velocity=velocity,desired=character.desired,facing=character.facing,wall=wall,
        acceleration=character.acceleration,braking=character.braking,turn_rate=character.turn_speed}
}

// The goal of the matching of what walks at the velocity of its core.Motion with no locomotion to
// say where it heads: on as it goes, facing where it goes (where it faces while it stands), at the
// acceleration, braking and turn_speed of its Walk (none: it keeps its velocity and turns at once).
motion_goal :: proc "contextless" (rig:core.Entity,motion:core.Motion,rotation:mm.Quat,walk:locomotion.Walk) -> anim.Match_Goal {
    going:=mm.Vec3{motion.linear.x,0,motion.linear.z}
    facing:=mm.quat_forward(rotation)
    facing.y=0
    if speed:=linalg.length(going);speed>0.05 {
        facing=going/speed
    } else if length:=linalg.length(facing);length>1e-4 {
        facing/=length
    } else {
        facing=mm.FORWARD
    }
    return {rig=rig,mode=u16(locomotion.MODE_WALKING),velocity=motion.linear,desired=going,facing=facing,
        acceleration=walk.acceleration,braking=walk.braking,turn_rate=walk.turn_speed}
}

// A velocity across the up of up_frame (core.Vertical): what goes along the ground.
across_up :: proc "contextless" (velocity:mm.Vec3,up_frame:mm.Quat) -> mm.Vec3 {
    up:=mm.quat_rotate(up_frame,mm.Vec3{0,1,0})
    return velocity-up*linalg.dot(velocity,up)
}
