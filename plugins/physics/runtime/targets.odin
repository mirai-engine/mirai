package physics

import "core:math/linalg"
import "mirai:core"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

// What another owner asks of the bodies (core.Pose_Target), at the start of
// the tick. A place puts the body there at once, with those velocities; a
// character takes the rotation, its up and its yaw, and no angular velocity. A
// following target makes its body head for the pose in the step as a
// kinematic body, pushing what it touches, until it no longer follows; a
// manipulation underneath holds it again then. A following character is put at
// its pose after every step (step_followed), so neither its own move nor what
// it touches takes it away from what the other owner shows. A body that was not made yet
// is made at the pose, with the velocities of its target (target_made). An
// entity with a parent is left to its parent.
@(step="fixed",loops="game",stage="begin")
physics_pose_targets :: proc(
    state:^Physics_State,targets:core.Read(core.Pose_Target),transforms:^core.Table(core.Transform),parents:core.Read(core.Parent),
    rigids:core.Read(Rigid_Body),characters:core.Read(Character),
) {
    c:=core.changes(targets,&state.targets_seen)
    if c.all {
        // What left the table was not kept: every follow of what no longer has a target ends.
        for &l,at in state.links.values {
            if !core.has(targets,state.links.entities[at]) {
                if .Target in l.hold.by {
                    hold_end(&state.world,&l,.Target,true)
                    link_touch(state,&l)
                }
                l.followed=false
            }
        }
    }
    for e in c.gone {
        if core.has(targets,e) {continue}
        if l:=link_find(state,e);l!=nil {
            hold_end(&state.world,l,.Target,true)
            l.followed=false
            link_touch(state,l)
        }
    }
    for row in core.each_changed(targets,&c) {
        e:=core.entity_at(targets,row)
        if core.has(parents,e) || !core.has(rigids,e) && !core.has(characters,e) && !proxied(state,e) {continue}
        target:=core.at(targets,row)
        local:=core.edit(transforms,e)
        if local==nil {continue}
        rotation:=target.rotation==0?mm.QUAT_IDENTITY:linalg.normalize(target.rotation)
        local.scale=target.scale
        l:=link_find(state,e)
        if l==nil || !state.ready || !link_made(state,l) {
            local.position,local.rotation=target.position,rotation
            continue
        }
        link_touch(state,l)
        if l.target_placed!=target.placed {
            l.target_placed=target.placed
            target_place(state,l,local,target.position,rotation,target.linear,target.angular,target.rest)
        }
        l.followed=target.follow && l.kind==.Character
        if l.followed {
            l.follow,l.follow_linear={target.position,rotation},target.linear
        } else if target.follow {
            hold_begin(&state.world,l,.Target,{target.position,rotation})
        } else {
            hold_end(&state.world,l,.Target,true)
        }
    }
}

// A body made for an entity with a target starts as its target asks: placed
// where it was made, and heading for the pose when it follows.
@(private)
target_made :: proc(state:^Physics_State,l:^Link,targets:core.Read(core.Pose_Target),e:core.Entity) {
    target,on:=core.get(targets,e)
    if !on {return}
    l.target_placed=target.placed
    l.followed=target.follow && l.kind==.Character
    if l.followed {l.follow,l.follow_linear={target.position,target.rotation==0?mm.QUAT_IDENTITY:linalg.normalize(target.rotation)},target.linear}
    if target.follow && l.kind!=.Character {
        hold_begin(&state.world,l,.Target,{target.position,target.rotation==0?mm.QUAT_IDENTITY:linalg.normalize(target.rotation)})
    }
}

@(private)
proxied :: proc(state:^Physics_State,e:core.Entity) -> bool {
    l:=link_find(state,e)
    return l!=nil && l.kind==.Proxy
}

// Whether the simulation made what the link stands for.
@(private)
link_made :: proc(state:^Physics_State,l:^Link) -> bool {
    #partial switch l.kind {
    case .Body,.Proxy: return sim.body_valid(&state.world,l.body)
    case .Character:   return sim.character_valid(&state.world,l.character)
    }
    return false
}

@(private)
target_place :: proc(state:^Physics_State,l:^Link,local:^core.Transform,position:[3]f32,rotation:mm.Quat,linear,angular:[3]f32,rest:bool) {
    world:=&state.world
    state.stats.teleports+=1
    if l.kind==.Character {
        body:=sim.character_body(world,l.character)
        sim.character_set_position(world,l.character,position)
        sim.character_set_rotation(world,l.character,rotation)
        sim.body_set_linear_velocity(world,body,linear)
        local.position,local.rotation=position,sim.body_rotation(world,body)
    } else {
        at:=sim.Transform{position,rotation}

        same:=!pose_differs(sim.body_transform(world,l.body),at)
        if rest && sim.body_type(world,l.body)==.Dynamic {
            if !same || sim.body_is_awake(world,l.body) {sim.body_rest(world,l.body,position,rotation)}
        } else if !same || sim.body_linear_velocity(world,l.body)!=linear || sim.body_angular_velocity(world,l.body)!=angular {
            sim.body_set_transform(world,l.body,position,rotation)
            sim.body_set_velocity(world,l.body,linear,angular)
        }
        local.position,local.rotation=position,rotation
    }
    l.placed={local.position,local.rotation}
    l.written_position,l.written_rotation=local.position,local.rotation
}

// Puts every character a following target leads at its pose, with its
// velocity: after the step, so what the step did to it is undone. It looks
// at the characters, not at every body.
@(private)
step_followed :: proc(state:^Physics_State,characters:core.Read(Character)) {
    world:=&state.world
    for row in 0..<core.count(characters) {
        l:=link_find(state,core.entity_at(characters,row))
        if l==nil || l.kind!=.Character || !l.followed || !sim.character_valid(world,l.character) {continue}
        sim.character_set_position(world,l.character,l.follow.p)
        sim.character_set_rotation(world,l.character,l.follow.q)
        sim.body_set_linear_velocity(world,sim.character_body(world,l.character),l.follow_linear)
    }
}
