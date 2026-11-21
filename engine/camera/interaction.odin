package camera

import "core:math"
import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"

Interaction_Mode :: enum u8 {Proximity,Look}

@(component,description="A target that a nearby body can focus and use.")
Interactable :: struct {
    reach:f32 `mirai:"unit=m,min=0"`,
    mode:Interaction_Mode,
    look_angle:f32 `mirai:"unit=deg,min=0,max=180"`,
    hold_seconds:f32 `mirai:"unit=s,min=0"`,
    prompt:[32]u8 `mirai:"text"`,
    priority:i16,
    enabled:bool,
}

INTERACTABLE_DEFAULT :: Interactable{reach=2,look_angle=30,enabled=true}

@(component,description="A body that can focus and use nearby Interactables.")
Interactor :: struct {}

@(component,derived,description="The target and hold progress derived for an Interactor.")
Interaction_State :: struct {
    target:core.Entity,
    progress:f32,
    available:bool,
    holding:bool,
    started:u64,
    deadline:u64,
}

Interaction_Kind :: enum u8 {Started,Completed,Cancelled,Focused,Unfocused}

Interaction_Event :: struct {
    actor,target:core.Entity,
    kind:Interaction_Kind,
}

@(storage)
Interaction_Events :: struct {using queue:core.Events(Interaction_Event)}

Interaction_Use :: struct {
    actor:core.Entity,
    pressed:bool,
}

@(storage,queue)
Interaction_Requests :: struct {using queue:core.Queue(Interaction_Use)}

interaction_use :: proc(requests:^Interaction_Requests,actor:core.Entity,pressed:bool) {
    if requests!=nil && actor!=core.NONE {core.offer(&requests.queue,{actor,pressed})}
}

INTERACTION_EVENT_CAPACITY :: 4096

@(step="fixed",stage="apply",loops="game")
interaction_step :: proc(
    interactables:^core.Table(Interactable,.Read),actors:^core.Table(Interactor,.Read),
    states:^core.Table(Interaction_State),events:^Interaction_Events,
    sight:Sight,requests:^Interaction_Requests,
    time:core.Time,problems:^core.Problems,
) {
    active:=core.count(interactables)>0 && core.count(actors)>0
    if len(requests.items)>0 || requests.dropped>0 {
        core.queue_serve(&requests.queue,core.QUEUE_FIRST_ROOM,problems,
            "interaction.requests","interaction requests","the interaction request capacity")
    }
    uses:=core.take(&requests.queue)
    if !active && core.count(states)==0 {return}
    for actor,row in states.entities[:core.count(states)] {
        if active && core.has(actors,actor) {continue}
        state:=core.at(states,row)
        _=interaction_update(state,actor,core.NONE,0,false,false,time,events,problems)
        core.remove(states,actor)
    }
    if !active {return}
    for row in 0..<core.count(actors) {
        actor:=core.entity_at(actors,row)
        target,hold:=interaction_target(interactables,sight,actor)
        was,exists:=core.get(states,actor)
        pressed,down:=false,false
        for use in uses {
            if use.actor!=actor {continue}
            pressed||=use.pressed
            down=true
        }
        if !exists && target==core.NONE {continue}
        next:=interaction_update(was,actor,target,hold,pressed,down,time,events,problems)
        if exists {
            if next!=was {core.edit(states,actor)^=next}
        } else if !core.add(states,actor,next) {
            core.report(problems,actor,"interaction.state","out of memory for interaction state")
        }
    }
}

@(private)
interaction_target :: proc(
    interactables:^core.Table(Interactable,.Read),sight:Sight,actor:core.Entity,
) -> (target:core.Entity,hold:f32) {
    body,placed:=core.get(sight.worlds,actor)
    if !placed {return}
    eye,forward:=body.position,mm.quat_forward(body.rotation)
    viewed:=false
    best_priority:i16
    best_distance:f32
    for row in 0..<core.count(interactables) {
        entity:=core.entity_at(interactables,row)
        item:=core.at(interactables,row)
        if !item.enabled || entity==actor || !(item.reach>0) {continue}
        pose,exists:=core.get(sight.worlds,entity)
        if !exists {continue}
        offset:=pose.position-body.position
        distance:=linalg.dot(offset,offset)
        if !(distance<=item.reach*item.reach) {continue}
        if item.mode==.Look {
            if !viewed {
                if origin,direction,found:=aim(sight,actor);found {eye,forward=origin,direction}
                viewed=true
            }
            ray:=pose.position-eye
            if linalg.dot(ray,ray)>0 &&
                !(linalg.dot(linalg.normalize0(ray),forward)>=math.cos(item.look_angle*mm.RAD_PER_DEG)) {continue}
        }
        if target!=core.NONE && (item.priority<best_priority ||
            item.priority==best_priority && (distance>best_distance ||
            distance==best_distance && entity>target)) {continue}
        target,hold,best_priority,best_distance=entity,item.hold_seconds,item.priority,distance
    }
    return
}

@(private)
interaction_update :: proc(
    previous:Interaction_State,actor,target:core.Entity,hold:f32,pressed,down:bool,time:core.Time,
    events:^Interaction_Events,problems:^core.Problems,
) -> Interaction_State {
    next:=previous
    if next.target!=target {
        if next.holding {interaction_emit(events,actor,next.target,.Cancelled,problems)}
        if next.target!=core.NONE {interaction_emit(events,actor,next.target,.Unfocused,problems)}
        next={target=target,available=target!=core.NONE}
        if next.available {interaction_emit(events,actor,target,.Focused,problems)}
    }
    if !next.available {return next}
    if pressed && !next.holding {
        next.holding,next.started,next.deadline=true,time.tick,core.deadline(time,hold)
        interaction_emit(events,actor,target,.Started,problems)
    }
    if next.holding {
        if !down && !pressed {
            interaction_emit(events,actor,target,.Cancelled,problems)
            next.holding,next.progress=false,0
        } else if core.due(time,next.deadline) {
            interaction_emit(events,actor,target,.Completed,problems)
            next.holding,next.progress=false,1
        } else {
            next.progress=f32(f64(time.tick-next.started)/f64(next.deadline-next.started))
        }
    } else if !down {next.progress=0}
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
