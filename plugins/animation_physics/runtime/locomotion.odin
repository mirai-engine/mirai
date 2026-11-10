package animation_physics

import "mirai:core"
import inp "mirai:engine/input"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

// Locomotion animated by the physics. Every tick, each Character with an Animation tells its
// motion matching (the locomotion of the .character in Animation.asset) what its body did in the simulation of this tick:
// the mode its locomotion is in (Locomotion_State, which only locomotion writes), the velocity of the
// body, the velocity its Move_Input asks of that mode at the acceleration of the mode, where it
// turns (the look yaw of its Move_Input: its move, or where it looks), the wall it
// leans on, which its trajectory does not go into, and, while it falls and the clips of that mode
// play toward a landing marker, when it lands on the arc it follows (phys.character_landing).
// While it walks a clip of matching, the warping of its .character stretches the stride to the
// speed of the root of its pose. A game writes no code for locomotion; the clips and their modes
// are in the .character.
@(step="fixed")
animation_locomotion :: proc(characters:core.Read(phys.Character),states:core.Read(locomotion.Locomotion_State),found:core.Read(phys.Character_State),animations:core.Read(anim.Animation),motions:core.Read(core.Motion),inputs:core.Read(inp.Move_Input),walk_actions:inp.Input_Of(locomotion.Walk_Action),walks:core.Read(locomotion.Walk),tacticals:core.Read(locomotion.Tactical_Sprint),flights:core.Read(locomotion.Fly),swims:core.Read(locomotion.Swim),worlds:core.Read(core.World_Transform),playback:core.Ref(anim.Playback),physics:core.Ref(phys.Physics_State),requests:^anim.Animation_Requests,warps:^anim.Motion_Requests,problems:^core.Problems) {
    for row in 0..<core.count(states) {
        entity:=core.entity_at(states,row)
        animation,animated:=core.get(animations,entity)
        if !animated || animation.asset=={} {continue}
        character:=core.at(states,row)
        body,_:=core.get(characters,entity)
        going,_:=core.get(motions,entity)
        asked,_:=core.get(inputs,entity)
        input:=locomotion.move_facing(asked,character.yaw,mm.QUAT_IDENTITY)
        placed,_:=core.get(worlds,entity)
        wish:=locomotion.move_wish(input,mm.QUAT_IDENTITY)
        facing:=mm.quat_forward(mm.quat_axis_angle({0,1,0},asked.look_yaw))
        state,_:=core.get(found,entity)
        goal:=anim.Match_Goal{rig=entity,mode=u16(character.mode),velocity=going.linear,facing=facing,wall=state.wall_normal,turn_rate=body.turn_speed}
        playing,matching:=anim.animation_match(playback.ptr,entity)
        if matching && character.mode==locomotion.MODE_FALLING && playing.landing_modes&(1<<u32(locomotion.MODE_FALLING))!=0 {
            if time,_,lands:=phys.character_landing(physics,entity);lands {goal.time_to_land=time}
        }
        switch character.mode {
        case locomotion.MODE_SWIMMING:
            if swim,ok:=core.get(swims,entity);ok {goal.desired,goal.acceleration,goal.braking=wish*swim.speed,swim.acceleration,swim.acceleration}
        case locomotion.MODE_FLYING:
            if fly,ok:=core.get(flights,entity);ok {goal.desired,goal.acceleration,goal.braking=wish*fly.speed,fly.acceleration,fly.acceleration}
        case locomotion.MODE_SLIDING,locomotion.MODE_MANTLING:
            // The slide keeps its course and the climb its way: what the body does is what it asks.
            if walk,ok:=core.get(walks,entity);ok {goal.desired,goal.acceleration,goal.braking={going.linear.x,0,going.linear.z},walk.acceleration,walk.braking}
            // The clip of the climb warps onto where it ends (mantle.odin).
            if character.mode==locomotion.MODE_MANTLING && matching {anim.motion_target(warps,entity,MANTLE_WINDOW,mantle_target(character,placed.rotation))}
        case:
            if walk,ok:=core.get(walks,entity);ok {
                sprinting:=input.buttons&inp.action_bit(inp.action_of(walk_actions,.Sprint))!=0
                boost:f32=1
                if tactical,has:=core.get(tacticals,entity);has {boost,_=locomotion.tactical_boost(character,tactical)}
                goal.desired,goal.acceleration,goal.braking=walk_goal(walk,character.mode==locomotion.MODE_FALLING,wish,going.linear,locomotion.walk_speed(walk,input,sprinting,character.mode==locomotion.MODE_CROUCHING,boost))
            }
        }
        anim.match_goal(requests,goal)
        if !matching {continue}
        // The warping corrects what the clip travels, in its own direction, toward the body: a clip
        // that strafes or backs off is not turned as if it went forward.
        along:=playing.travel if playing.travel!={} else mm.FORWARD
        anim.motion_locomotion(warps,{rig=entity,velocity={playing.velocity.x,0,playing.velocity.z},source_velocity=mm.quat_rotate(placed.rotation,along*playing.speed),weight=1,enabled=(character.mode==locomotion.MODE_WALKING || character.mode==locomotion.MODE_CROUCHING) && !playing.forced && playing.speed>0})
    }
}

// What a Walk does with the velocity of the body, as the Character does: on the ground it goes to
// the wish at its acceleration and brakes without one; in the air only a wish steers it, at
// air_control of its acceleration, and without one it keeps its course. speed is the top speed
// the Character walks this input at (locomotion.walk_speed: sprint, moving back).
walk_goal :: proc "contextless" (walk:locomotion.Walk,falling:bool,wish,velocity:mm.Vec3,speed:f32) -> (desired:mm.Vec3,acceleration,braking:f32) {
    if !falling {return wish*speed,walk.acceleration,walk.braking}
    air:=walk.air_control*walk.acceleration
    if wish=={} || walk.air_control<=0 {return {velocity.x,0,velocity.z},air,air}
    return wish*speed,air,air
}
