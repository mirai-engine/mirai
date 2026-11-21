package camera

import "core:mem"
import "core:testing"
import "mirai:core"

@(private)
@(test_world)
Interaction_World :: struct {
    using world:Test_World,
    targets:core.Table(Interactable),
    actors:core.Table(Interactor),
    states:core.Table(Interaction_State),
    worlds:core.Table(core.World_Transform),
    events:Interaction_Events,
    requests:Interaction_Requests,
}

@(test)
interaction_prioritizes_focus_and_cancels_or_completes_one_hold :: proc(t:^testing.T) {
    w:Interaction_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    actor:=core.create(&w.entities)
    near:=core.create(&w.entities)
    front:=core.create(&w.entities)
    core.add(&w.actors,actor,Interactor{})
    core.add(&w.worlds,actor,core.World_Transform{transform={rotation=1,scale=1}})
    core.add(&w.worlds,near,core.World_Transform{transform={position={0.5,0,0}}})
    core.add(&w.worlds,front,core.World_Transform{transform={position={0,0,-1}}})
    core.add(&w.targets,near,INTERACTABLE_DEFAULT)
    target:=INTERACTABLE_DEFAULT
    target.mode,target.priority,target.hold_seconds=.Look,1,0.5
    core.add(&w.targets,front,target)
    test_world_settle(&w)

    step :: proc(w:^Interaction_World,tick:u64) {
        interaction_step(core.read(&w.targets),core.read(&w.actors),&w.states,&w.events,
            Sight{worlds=core.read(&w.worlds)},&w.requests,{tick=tick,dt=0.25,playing=true},nil)
        core.table_settle(&w.states,&w.entities)
    }
    interaction_use(&w.requests,actor,true)
    step(&w,0)
    testing.expect(t,len(w.events.items)==2 && w.events.items[0].kind==.Focused &&
        w.events.items[0].target==front && w.events.items[1].kind==.Started)
    step(&w,1)
    testing.expect(t,w.events.items[len(w.events.items)-1].kind==.Cancelled)

    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    {
        context.allocator=mem.tracking_allocator(&tracker)
        for tick in u64(2)..=u64(6) {
            interaction_use(&w.requests,actor,tick==2)
            step(&w,tick)
            if tick==3 {
                state,found:=core.get(&w.states,actor)
                testing.expect(t,found && state.holding && state.progress==0.5)
            }
        }
    }
    testing.expect_value(t,tracker.total_allocation_count,i64(0))
    testing.expect(t,len(w.events.items)==5 && w.events.items[4].kind==.Completed)

    core.edit(&w.worlds,front).position={0,0,1}
    step(&w,7)
    state,found:=core.get(&w.states,actor)
    testing.expect(t,found && state.available && state.target==near)
    testing.expect(t,len(w.events.items)==7 && w.events.items[5].kind==.Unfocused &&
        w.events.items[6].kind==.Focused)
    core.remove(&w.targets,front)
    core.remove(&w.targets,near)
    core.table_settle(&w.targets,&w.entities)
    step(&w,8)
    testing.expect(t,!core.has(&w.states,actor) && w.events.items[7].kind==.Unfocused)
}

@(test)
empty_interaction_has_no_events_or_allocations :: proc(t:^testing.T) {
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    events:Interaction_Events
    requests:Interaction_Requests
    targets:core.Table(Interactable)
    actors:core.Table(Interactor)
    states:core.Table(Interaction_State)
    {
        context.allocator=mem.tracking_allocator(&tracker)
        interaction_step(core.read(&targets),core.read(&actors),&states,&events,{},&requests,{},nil)
    }
    testing.expect_value(t,tracker.total_allocation_count,i64(0))
    testing.expect(t,len(events.items)==0)
}
