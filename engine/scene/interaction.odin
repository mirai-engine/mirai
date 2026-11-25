package scene

import "core:math"
import "core:math/linalg"
import "mirai:core"
import input "mirai:engine/input"
import mm "mirai:std/math"

// Targets a body can use (a door, a lever, a shop): each Interactor focuses
// the Interactable it reaches with the highest priority, then the nearest,
// then the lowest entity; Look mode needs it inside a cone of the aim of the
// player who drives the body (input.aim), or of where the body faces without
// one, and sight a clear line from that eye (core.World_Queries; nothing
// blocks it without a library that simulates the world). The player uses it
// with the action the Interactor names, read from its seat on every end: a
// press starts a hold of hold_seconds, letting go or losing the focus cancels
// it, and its end completes it; one more press starts it again. Every change
// is an Interaction_Event; the state is written when it changes, never while
// a hold runs. What the target does and what a HUD shows is the game's.

Interaction_Mode :: enum u8 {Proximity,Look}

@(component,description="A target that a nearby body can focus and use.")
Interactable :: struct {
    reach:f32 `mirai:"unit=m,min=0"`,                   // from the body that uses it
    mode:Interaction_Mode,
    look_angle:f32 `mirai:"unit=deg,min=0,max=180,mode=Look"`, // half the cone the aim keeps it in
    hold_seconds:f32 `mirai:"unit=s,min=0"`,            // 0: a press uses it
    priority:i16,                                        // the highest is focused first
    sight:bool,                                          // it needs a clear line from the eye
    enabled:bool,
}

INTERACTABLE_DEFAULT :: Interactable{reach=2,look_angle=30,sight=true,enabled=true}

@(component,description="A body that focuses Interactables and uses them with an action of the player who drives it.")
Interactor :: struct {
    action:input.Action, // pressed starts using the focused target, released cancels a hold; none: it only focuses
}

INTERACTOR_DEFAULT :: Interactor{action=max(input.Action)}

@(component,derived,description="The target an Interactor focuses and its hold on it.")
Interaction_State :: struct {
    target:core.Entity,
    hold:core.Countdown, // from the press to the end of the hold; stopped when it completes or is cancelled
}

// How far the hold on the focused target has come, 0 to 1; 0 without one.
interaction_progress :: proc "contextless" (state:Interaction_State,time:core.Time) -> f32 {
    return core.countdown_progress(state.hold,time)
}

Interaction_Kind :: enum u8 {Started,Completed,Cancelled,Focused,Unfocused}

Interaction_Event :: struct {
    actor,target:core.Entity,
    kind:Interaction_Kind,
}

@(storage)
Interaction_Events :: struct {using queue:core.Events(Interaction_Event)}

INTERACTION_EVENT_CAPACITY :: 4096

// What the interaction step sees of the world.
@(params)
Interaction_View :: struct {
    aims:input.Aims,
    parents:^core.Table(core.Parent,.Read),
    world:core.World_Read,
    queries:core.Ref(core.World_Queries),
}

@(step="fixed",stage="apply",loops="game")
interaction_step :: proc(
    interactables:^core.Table(Interactable,.Read),actors:^core.Table(Interactor,.Read),
    states:^core.Table(Interaction_State),events:^Interaction_Events,view:Interaction_View,
    time:core.Time,problems:^core.Problems,
) {
    active:=core.count(interactables)>0 && core.count(actors)>0
    if !active && core.count(states)==0 {return}
    for actor,row in states.entities[:core.count(states)] {
        if active && core.has(actors,actor) {continue}
        _=interaction_update(core.at(states,row),actor,core.NONE,0,{},time,events,problems)
        core.remove(states,actor)
    }
    if !active {return}
    query:=core.world_query_read(view.world,view.queries)
    for row in 0..<core.count(actors) {
        actor:=core.entity_at(actors,row)
        interactor:=core.at(actors,row)
        target,hold:=interaction_target(interactables,view,query,actor)
        was,exists:=core.get(states,actor)
        if !exists && target==core.NONE {continue}
        use:input.Action_State
        if interactor.action!=max(input.Action) {
            if int(interactor.action)>=input.ACTION_CAPACITY {
                core.report(problems,actor,"interaction.action","the Interactor of entity 0x%016x names action %d, which no input map holds; choose one of the actions of the game",u64(actor),int(interactor.action))
            } else {
                use=input.seat_action(view.aims.runtime,input.seat_of(view.aims.seat_state,actor),interactor.action)
            }
        }
        next:=interaction_update(was,actor,target,hold,use,time,events,problems)
        if exists {
            if next!=was {core.edit(states,actor)^=next}
        } else if !core.add(states,actor,next) {
            core.report(problems,actor,"interaction.state","out of memory for interaction state")
        }
    }
}

@(private)
interaction_target :: proc(
    interactables:^core.Table(Interactable,.Read),view:Interaction_View,query:core.World_Query,actor:core.Entity,
) -> (target:core.Entity,hold:f32) {
    body,placed:=core.get(view.aims.worlds,actor)
    if !placed {return}
    eye,forward:=body.position,mm.quat_forward(body.rotation)
    if origin,direction,_,aimed:=input.aim(view.aims,actor);aimed {eye,forward=origin,direction}
    best_priority:i16
    best_distance:f32
    for row in 0..<core.count(interactables) {
        entity:=core.entity_at(interactables,row)
        item:=core.at(interactables,row)
        if !item.enabled || entity==actor || !(item.reach>0) {continue}
        pose,exists:=core.get(view.aims.worlds,entity)
        if !exists {continue}
        offset:=pose.position-body.position
        distance:=linalg.dot(offset,offset)
        if !(distance<=item.reach*item.reach) {continue}
        if target!=core.NONE && (item.priority<best_priority ||
            item.priority==best_priority && (distance>best_distance ||
            distance==best_distance && entity>target)) {continue}
        ray:=pose.position-eye
        along:=linalg.length(ray)
        if item.mode==.Look && along>0 &&
            !(linalg.dot(ray/along,forward)>=math.cos(item.look_angle*mm.RAD_PER_DEG)) {continue}
        if item.sight && query.probe!=nil && along>0 {
            if hit,blocked:=query.probe(query.user,eye,ray/along,along,0,actor,~u32(0));blocked &&
                !core.is_under(view.parents,hit.entity,entity) {continue}
        }
        target,hold,best_priority,best_distance=entity,item.hold_seconds,item.priority,distance
    }
    return
}

@(private)
interaction_update :: proc(
    previous:Interaction_State,actor,target:core.Entity,hold:f32,use:input.Action_State,time:core.Time,
    events:^Interaction_Events,problems:^core.Problems,
) -> Interaction_State {
    next:=previous
    if next.target!=target {
        if next.hold.active {interaction_emit(events,actor,next.target,.Cancelled,problems)}
        if next.target!=core.NONE {interaction_emit(events,actor,next.target,.Unfocused,problems)}
        next={target=target}
        if target!=core.NONE {interaction_emit(events,actor,target,.Focused,problems)}
    }
    if target==core.NONE {return next}
    if use.pressed && !next.hold.active {
        core.countdown_start(&next.hold,time,hold)
        interaction_emit(events,actor,target,.Started,problems)
    }
    if !next.hold.active {return next}
    switch {
    case core.countdown_ended(next.hold,time):
        interaction_emit(events,actor,target,.Completed,problems)
        core.countdown_stop(&next.hold)
    case !use.down && !use.pressed:
        interaction_emit(events,actor,target,.Cancelled,problems)
        core.countdown_stop(&next.hold)
    }
    return next
}

@(private)
interaction_emit :: proc(
    events:^Interaction_Events,actor,target:core.Entity,kind:Interaction_Kind,problems:^core.Problems,
) {
    if cap(events.items)==0 && reserve(&events.items,INTERACTION_EVENT_CAPACITY)!=nil ||
       len(events.items)>=INTERACTION_EVENT_CAPACITY {
        core.report(problems,actor,"interaction.events","interaction event capacity exhausted")
        return
    }
    core.push(&events.queue,Interaction_Event{actor,target,kind})
}
