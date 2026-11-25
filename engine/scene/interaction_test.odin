package scene

import "core:mem"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"

@(private)
@(test_world)
Interaction_World :: struct {
    using world:Test_World,
    targets:core.Table(Interactable),
    actors:core.Table(Interactor),
    states:core.Table(Interaction_State),
    worlds:core.Table(core.World_Transform),
    parents:core.Table(core.Parent),
    seats:core.Table(input.Seat),
    seat_state:input.Seats,
    runtime:input.Seat_States,
    events:Interaction_Events,
}

@(private="file") USE :: input.Action(3)
@(private="file") DT :: f32(0.25)

@(private="file")
Interaction_Test :: struct {
    w:Interaction_World,
    actor,seat:core.Entity,
    walls:[]core.Entity, // what the fake probe hits, in order along any ray
}

@(private="file")
interaction_test_init :: proc(t:^testing.T,f:^Interaction_Test) -> bool {
    if !test_world_init(t,&f.w) {return false}
    f.actor=core.create(&f.w.entities)
    f.seat=core.create(&f.w.entities)
    core.add(&f.w.actors,f.actor,Interactor{action=USE})
    core.add(&f.w.seats,f.seat,input.Seat{body=f.actor})
    core.add(&f.w.worlds,f.actor,core.World_Transform{transform={rotation=1,scale=1}})
    test_world_settle(&f.w)
    input.input_seat_index(core.ref(&f.w.entities),core.read(&f.w.seats),&f.w.seat_state,nil)
    return true
}

@(private="file")
interaction_target_add :: proc(f:^Interaction_Test,at:[3]f32,item:Interactable) -> core.Entity {
    e:=core.create(&f.w.entities)
    core.add(&f.w.worlds,e,core.World_Transform{transform={position=at,rotation=1,scale=1}})
    core.add(&f.w.targets,e,item)
    return e
}

// One tick with the use action of the seat as given.
@(private="file")
interaction_tick :: proc(f:^Interaction_Test,tick:u64,use:input.Action_State={}) {
    state:=input.seat_runtime_edit(&f.w.runtime,f.seat)
    state.actions.count=u32(USE)+1
    state.actions.states[USE]=use
    test_world_settle(&f.w)
    queries:=core.World_Queries{open=proc(w:core.World_Read) -> (core.World_Query,bool) {
        return {user=w.data,probe=proc(user:rawptr,origin,direction:[3]f32,length,radius:f32,ignore:core.Entity,mask:u32) -> (core.World_Hit,bool) {
            walls:=(cast(^Interaction_Test)user).walls
            return len(walls)>0?core.World_Hit{entity=walls[0],distance=length/2}:{},len(walls)>0
        }},true
    }}
    view:=Interaction_View{
        aims={core.ref(&f.w.seat_state),core.ref(&f.w.runtime),core.read(&f.w.worlds),nil},
        parents=core.read(&f.w.parents),
        world={data=f,info=test_world_info(&f.w),place=.World},
        queries=core.ref(&queries),
    }
    interaction_step(core.read(&f.w.targets),core.read(&f.w.actors),&f.w.states,&f.w.events,view,{tick=tick,dt=DT,playing=true},nil)
    core.table_settle(&f.w.states,&f.w.entities)
}

@(private="file")
interaction_kinds :: proc(f:^Interaction_Test,from:int) -> (kinds:[dynamic]Interaction_Kind) {
    kinds=make([dynamic]Interaction_Kind,context.temp_allocator)
    for event in f.w.events.items[from:] {append(&kinds,event.kind)}
    return
}

// The focus goes to the highest priority, then the nearest, then the lowest
// entity, among the targets in reach; a Look target only inside the cone of
// where the body looks, and one that needs sight only with a clear line.
@(test)
interaction_focuses_by_priority_distance_cone_and_sight :: proc(t:^testing.T) {
    Target :: struct {at:[3]f32,mode:Interaction_Mode,priority:i16,sight:bool}
    Case :: struct {name:string,targets:[]Target,walled:bool,focused:int}
    for c in ([]Case{
        {"the nearest",{{at={1.5,0,0}},{at={0.5,0,0}}},false,1},
        {"the highest priority before the nearest",{{at={1.5,0,0},priority=2},{at={0.5,0,0}}},false,0},
        {"the lowest entity at one distance",{{at={1,0,0}},{at={-1,0,0}}},false,0},
        {"out of reach is never focused",{{at={3,0,0}}},false,-1},
        {"a Look target behind the body is not",{{at={0,0,1},mode=.Look,priority=5},{at={1,0,0}}},false,1},
        {"a Look target ahead is",{{at={0,0,-1},mode=.Look,priority=5},{at={1,0,0}}},false,0},
        {"a wall hides one that needs sight",{{at={0.5,0,0},sight=true},{at={1,0,0}}},true,1},
        {"none needs sight: the wall changes nothing",{{at={0.5,0,0}}},true,0},
    }) {
        f:=new(Interaction_Test)
        defer free(f)
        if !interaction_test_init(t,f) {continue}
        defer test_world_destroy(&f.w)
        made:=make([]core.Entity,len(c.targets),context.temp_allocator)
        for target,i in c.targets {
            item:=INTERACTABLE_DEFAULT
            item.mode,item.priority,item.sight=target.mode,target.priority,target.sight
            made[i]=interaction_target_add(f,target.at,item)
        }
        wall:=core.create(&f.w.entities)
        if c.walled {f.walls=[]core.Entity{wall}}
        interaction_tick(f,1)
        state,found:=core.get(&f.w.states,f.actor)
        want:=c.focused>=0?made[c.focused]:core.NONE
        testing.expectf(t,state.target==want && found==(want!=core.NONE),"%s: focused %v, not %v",c.name,state.target,want)
    }
}

// A press of the action the Interactor names starts a hold, its end completes
// it and letting go cancels it, with no call of the game: the step reads the
// seat. The state is written as the hold starts and ends, never while it runs,
// and its progress comes from the ticks.
@(test)
interaction_holds_complete_or_cancel_from_the_seat_with_no_write_while_held :: proc(t:^testing.T) {
    Case :: struct {name:string,hold:f32,release_at:u64,want:[]Interaction_Kind}
    down:=input.Action_State{down=true}
    for c in ([]Case{
        {"held to its end completes",1,0,{.Focused,.Started,.Completed}},
        {"let go before its end cancels",1,2,{.Focused,.Started,.Cancelled}},
        {"no hold completes on the press",0,0,{.Focused,.Started,.Completed}},
    }) {
        f:=new(Interaction_Test)
        defer free(f)
        if !interaction_test_init(t,f) {continue}
        defer test_world_destroy(&f.w)
        item:=INTERACTABLE_DEFAULT
        item.hold_seconds=c.hold
        target:=interaction_target_add(f,{1,0,0},item)
        interaction_tick(f,0)
        tracker:mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracker,context.allocator)
        defer mem.tracking_allocator_destroy(&tracker)
        writes:=0
        {
            context.allocator=mem.tracking_allocator(&tracker)
            interaction_tick(f,1,{down=true,pressed=true})
            for tick in u64(2)..=u64(8) {
                version:=f.w.states.version
                use:=c.release_at!=0 && tick>=c.release_at?input.Action_State{}:down
                interaction_tick(f,tick,use)
                if f.w.states.version!=version {writes+=1}
                if tick==3 && c.release_at==0 && c.hold>0 {
                    state,_:=core.get(&f.w.states,f.actor)
                    testing.expectf(t,abs(interaction_progress(state,{tick=tick,dt=DT})-0.5)<1e-5,"%s: half held at tick 3",c.name)
                }
            }
        }
        testing.expect_value(t,tracker.total_allocation_count,i64(0))
        kinds:=interaction_kinds(f,0)
        testing.expectf(t,len(kinds)==len(c.want),"%s: events %v",c.name,kinds)
        for kind,i in c.want {
            if i<len(kinds) {testing.expectf(t,kinds[i]==kind,"%s: event %d is %v, not %v",c.name,i,kinds[i],kind)}
        }
        // The end or the release is the one write after the press.
        testing.expectf(t,writes==(c.hold>0?1:0),"%s: %d writes while held",c.name,writes)
        state,_:=core.get(&f.w.states,f.actor)
        testing.expect(t,state.target==target && !state.hold.active)
        // Holding on after it completed does not start it again; a new press does.
        interaction_tick(f,9,down)
        testing.expect_value(t,len(interaction_kinds(f,0)),len(c.want))
        interaction_tick(f,10,{down=true,pressed=true})
        last:=interaction_kinds(f,len(c.want))
        testing.expectf(t,len(last)>=1 && last[0]==.Started,"%s: a new press starts it: %v",c.name,last)
    }
}

// Losing the focus cancels the hold, and an Interactor that goes stops.
@(test)
interaction_focus_loss_cancels_and_a_gone_interactor_unfocuses :: proc(t:^testing.T) {
    f:=new(Interaction_Test)
    defer free(f)
    if !interaction_test_init(t,f) {return}
    defer test_world_destroy(&f.w)
    item:=INTERACTABLE_DEFAULT
    item.hold_seconds=1
    target:=interaction_target_add(f,{1,0,0},item)
    interaction_tick(f,1,{down=true,pressed=true})
    core.edit(&f.w.worlds,target).position={5,0,0}
    interaction_tick(f,2,{down=true})
    kinds:=interaction_kinds(f,0)
    testing.expectf(t,len(kinds)==4 && kinds[2]==.Cancelled && kinds[3]==.Unfocused,"%v",kinds)
    core.edit(&f.w.worlds,target).position={1,0,0}
    interaction_tick(f,3)
    core.remove(&f.w.actors,f.actor)
    interaction_tick(f,4)
    kinds=interaction_kinds(f,0)
    testing.expectf(t,len(kinds)==6 && kinds[5]==.Unfocused && !core.has(&f.w.states,f.actor),"%v",kinds)
}

@(test)
empty_interaction_has_no_events_or_allocations :: proc(t:^testing.T) {
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    events:Interaction_Events
    targets:core.Table(Interactable)
    actors:core.Table(Interactor)
    states:core.Table(Interaction_State)
    {
        context.allocator=mem.tracking_allocator(&tracker)
        interaction_step(core.read(&targets),core.read(&actors),&states,&events,{},{},nil)
    }
    testing.expect_value(t,tracker.total_allocation_count,i64(0))
    testing.expect(t,len(events.items)==0)
}
