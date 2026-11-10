package animation_physics

import "mirai:core"
import inp "mirai:engine/input"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// Locomotion animated by the physics. Every tick, each Character with an Animation tells its
// motion matching (a .match in Animation.asset) what its body did in the simulation of this tick:
// the mode its locomotion is in, of which the Character is the only writer, the velocity of the
// body, the velocity its Move_Input asks of that mode at the acceleration of the mode, where it
// turns (toward its move, or where it looks when it moves relative to its look), the wall it
// leans on, which its trajectory does not go into, and, while it falls and the clips of that mode
// play toward a landing marker, when it lands on the arc it follows (phys.character_landing).
// While it walks a clip of matching, the warping of its Animation.motion stretches the stride to
// the speed of the root of its pose. A game writes no code for locomotion; the clips and their
// modes are in the .match.
@(step="fixed")
animation_locomotion :: proc(characters:core.Read(phys.Character),found:core.Read(phys.Character_State),animations:core.Read(anim.Animation),motions:core.Read(core.Motion),inputs:core.Read(inp.Move_Input),walk_actions:inp.Input_Of(phys.Walk_Action),walks:core.Read(phys.Walk),tacticals:core.Read(phys.Tactical_Sprint),flights:core.Read(phys.Fly),swims:core.Read(phys.Swim),worlds:core.Read(core.World_Transform),playback:core.Ref(anim.Playback),physics:core.Ref(phys.Physics_State),requests:^anim.Animation_Requests,warps:^anim.Motion_Requests,problems:^core.Problems) {
    for row in 0..<core.count(characters) {
        entity:=core.entity_at(characters,row)
        animation,animated:=core.get(animations,entity)
        if !animated || animation.asset=={} {continue}
        character:=core.at(characters,row)
        going,_:=core.get(motions,entity)
        input,_:=core.get(inputs,entity)
        placed,_:=core.get(worlds,entity)
        wish:=phys.move_wish(input,mm.QUAT_IDENTITY)
        facing:=mm.quat_forward(placed.rotation) if character.move_relative_to==.Look else wish
        state,_:=core.get(found,entity)
        goal:=anim.Match_Goal{rig=entity,mode=u16(character.mode),velocity=going.linear,facing=facing,wall=state.wall_normal,turn_rate=character.turn_speed}
        playing,matching:=anim.animation_match(playback.ptr,entity)
        if matching && character.mode==phys.MODE_FALLING && playing.landing_modes&(1<<u32(phys.MODE_FALLING))!=0 {
            if time,_,lands:=phys.character_landing(physics,entity);lands {goal.time_to_land=time}
        }
        switch character.mode {
        case phys.MODE_SWIMMING:
            if swim,ok:=core.get(swims,entity);ok {goal.desired,goal.acceleration,goal.braking=wish*swim.speed,swim.acceleration,swim.acceleration}
        case phys.MODE_FLYING:
            if fly,ok:=core.get(flights,entity);ok {goal.desired,goal.acceleration,goal.braking=wish*fly.speed,fly.acceleration,fly.acceleration}
        case phys.MODE_SLIDING,phys.MODE_MANTLING:
            // The slide keeps its course and the climb its way: what the body does is what it asks.
            if walk,ok:=core.get(walks,entity);ok {goal.desired,goal.acceleration,goal.braking={going.linear.x,0,going.linear.z},walk.acceleration,walk.braking}
            // The clip of the climb warps onto where it ends (mantle.odin).
            if character.mode==phys.MODE_MANTLING && animation.motion!={} {anim.motion_target(warps,entity,MANTLE_WINDOW,mantle_target(character,placed.rotation))}
        case:
            if walk,ok:=core.get(walks,entity);ok {
                sprinting:=input.buttons&inp.action_bit(inp.action_of(walk_actions,.Sprint))!=0
                boost:f32=1
                if tactical,has:=core.get(tacticals,entity);has {boost,_=phys.tactical_boost(character,tactical)}
                goal.desired,goal.acceleration,goal.braking=walk_goal(walk,character.mode==phys.MODE_FALLING,wish,going.linear,phys.walk_speed(walk,input,sprinting,character.mode==phys.MODE_CROUCHING,boost))
            }
        }
        anim.match_goal(requests,goal)
        if animation.motion=={} || !matching {continue}
        // The warping corrects what the clip travels, in its own direction, toward the body: a clip
        // that strafes or backs off is not turned as if it went forward.
        along:=playing.travel if playing.travel!={} else mm.FORWARD
        anim.motion_locomotion(warps,{rig=entity,velocity={playing.velocity.x,0,playing.velocity.z},source_velocity=mm.quat_rotate(placed.rotation,along*playing.speed),weight=1,enabled=(character.mode==phys.MODE_WALKING || character.mode==phys.MODE_CROUCHING) && !playing.forced && playing.speed>0})
    }
}

// What a Walk does with the velocity of the body, as the Character does: on the ground it goes to
// the wish at its acceleration and brakes without one; in the air only a wish steers it, at
// air_control of its acceleration, and without one it keeps its course. speed is the top speed
// the Character walks this input at (phys.walk_speed: sprint, moving back).
walk_goal :: proc "contextless" (walk:phys.Walk,falling:bool,wish,velocity:mm.Vec3,speed:f32) -> (desired:mm.Vec3,acceleration,braking:f32) {
    if !falling {return wish*speed,walk.acceleration,walk.braking}
    air:=walk.air_control*walk.acceleration
    if wish=={} || walk.air_control<=0 {return {velocity.x,0,velocity.z},air,air}
    return wish*speed,air,air
}
