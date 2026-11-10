package physics

import "mirai:core"
import sim "plugins:physics/runtime/sim"

// Breakable bodies of the simulation, for a library that makes them from its own data and mirrors what
// becomes of them, as destruct does for a Destructible. A breakable is made of convex pieces held by
// bonds; the hits of a step damage it in that step, and what comes off becomes bodies of the simulation.
// Its state is state of the simulation: a copy for Play, a rollback or a save takes it with the bodies.
// Its bodies name the entity it was made with until their owner names them otherwise.

Breakable_Handle :: sim.Breakable_Handle
Breakable_Desc :: sim.Breakable_Desc
Breakable_Error :: sim.Breakable_Error
Break_Event :: sim.Break_Event
Break_Kind :: sim.Break_Kind
Break_Region :: sim.Break_Region
Break_Capacity :: sim.Break_Capacity
Break_Capacities :: sim.Break_Capacities
Piece_Info :: sim.Piece_Info
Piece_Flag :: sim.Piece_Flag
Piece_Flags :: sim.Piece_Flags
Bond_Info :: sim.Bond_Info
Cluster_Desc :: sim.Cluster_Desc
Cluster_Info :: sim.Cluster_Info

BREAKABLE_DESC_DEFAULT :: sim.BREAKABLE_DESC_DEFAULT

// Where a body is; false for a body that is gone, or while the simulation is not ready.
Body_Pose :: sim.Transform
body_pose :: proc(physics:core.Ref(Physics_State),body:Body_Handle) -> (pose:Body_Pose,ok:bool) {
    if physics.ptr==nil || !physics.ready || !sim.body_valid(&physics.world,body) {return}
    return sim.body_transform(&physics.world,body),true
}

// The capacities the breakables of a simulation were given by Physics_Settings; zero while it is not ready.
Breakable_Room :: struct {breakables,pieces,bonds,bodies,events:int}
breakable_room :: proc(physics:core.Ref(Physics_State)) -> Breakable_Room {
    if physics.ptr==nil || !physics.ready {return {}}
    d:=physics.world.desc
    return {d.breakable_capacity,d.piece_capacity,d.bond_capacity,d.body_capacity,d.event_capacity}
}

// Makes a breakable: a transaction that allocates, not for the middle of a step of the simulation.
breakable_create :: proc(state:^Physics_State,desc:Breakable_Desc) -> (handle:Breakable_Handle,error:Breakable_Error) {
    if state==nil || !state.ready {return {},.Invalid_Desc}
    return sim.breakable_create(&state.world,desc)
}

// Ends a breakable with every body it has become.
breakable_destroy :: proc(state:^Physics_State,h:Breakable_Handle) {
    if state!=nil && state.ready {sim.breakable_destroy(&state.world,h)}
}

breakable_valid :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> bool {
    return physics.ptr!=nil && physics.ready && sim.breakable_valid(&physics.world,h)
}

// The breakable made for an entity (Breakable_Desc.user_data); zero without one.
breakable_of :: proc(physics:core.Ref(Physics_State),e:core.Entity) -> Breakable_Handle {
    if physics.ptr==nil || !physics.ready {return {}}
    return sim.breakable_find(&physics.world,u64(e))
}

// The body it was created as: where its anchored pieces are, or its largest part.
breakable_body :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> Body_Handle {
    if physics.ptr==nil || !physics.ready {return {}}
    return sim.breakable_body(&physics.world,h)
}

// Makes a body of a breakable name an entity: what its contacts and the queries that hit it report. False
// for a body that is of no breakable.
breakable_body_name :: proc(state:^Physics_State,body:Body_Handle,e:core.Entity) -> bool {
    if state==nil || !state.ready {return false}
    if owner,_:=sim.breakable_of(&state.world,body);owner=={} {return false}
    sim.body_set_user_data(&state.world,body,u64(e))
    return true
}

// Changes what every piece meets, those that came off included.
breakable_set_filter :: proc(state:^Physics_State,h:Breakable_Handle,filter:Collision_Filter) {
    if state!=nil && state.ready {sim.breakable_set_filter(&state.world,h,filter)}
}

// Its pieces, gone ones included, into out; returns how many there are.
breakable_pieces :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle,out:[]Piece_Info) -> int {
    if physics.ptr==nil || !physics.ready {return 0}
    return sim.breakable_pieces(&physics.world,h,out)
}

// Its bonds, broken ones included, into out; a and b are piece ids. Returns how many there are.
breakable_bonds :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle,out:[]Bond_Info) -> int {
    if physics.ptr==nil || !physics.ready {return 0}
    return sim.breakable_bonds(&physics.world,h,out)
}

// Mass of its pieces that are still in the world.
breakable_mass :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> f32 {
    if physics.ptr==nil || !physics.ready {return 0}
    return sim.breakable_mass(&physics.world,h)
}

breakable_clusters :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle,out:[]Cluster_Info) -> int {
    if physics.ptr==nil || !physics.ready {return 0}
    return sim.breakable_clusters(&physics.world,h,out)
}

// Counts every group that left, every cut and every piece removed; zero while it is as created.
breakable_revision :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> u32 {
    if physics.ptr==nil || !physics.ready {return 0}
    return sim.breakable_revision(&physics.world,h)
}

// Hash of what it has become, the same wherever the same events were applied to an equal breakable.
breakable_check :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> u32 {
    if physics.ptr==nil || !physics.ready {return 0}
    return sim.breakable_check(&physics.world,h)
}

// What it has become since it was made, as bytes without geometry for an equal breakable elsewhere:
// the bytes breakable_state_write needs, what it wrote (zero when out is too small), and whether a
// breakable that is still as created took them. One that refused them is only good to destroy.
breakable_state_size :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> int {
    if physics.ptr==nil || !physics.ready {return 0}
    return sim.breakable_state_size(&physics.world,h)
}
breakable_state_write :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle,out:[]u8) -> int {
    if physics.ptr==nil || !physics.ready {return 0}
    return sim.breakable_state_write(&physics.world,h,out)
}
breakable_state_apply :: proc(state:^Physics_State,h:Breakable_Handle,data:[]u8) -> bool {
    return state!=nil && state.ready && sim.breakable_state_apply(&state.world,h,data)
}

// Strains every body of a breakable around a world point: each bond within the radius takes amount N s,
// fading to nothing at the radius, and what comes off shares the impulse. With weaken nothing breaks yet.
breakable_strain :: proc(state:^Physics_State,h:Breakable_Handle,point:[3]f32,radius,amount:f32,impulse:[3]f32={}) -> (event:Break_Event,broke:bool) {
    if state==nil || !state.ready {return}
    return sim.breakable_strain(&state.world,h,point,radius,amount,impulse)
}
breakable_weaken :: proc(state:^Physics_State,h:Breakable_Handle,point:[3]f32,radius,amount:f32) -> (event:Break_Event,strained:bool) {
    if state==nil || !state.ready {return}
    return sim.breakable_weaken(&state.world,h,point,radius,amount)
}

// Cuts every body of a breakable by the plane through a world point. It allocates: between steps.
breakable_slice :: proc(state:^Physics_State,h:Breakable_Handle,point,normal:[3]f32) -> (event:Break_Event,cut:bool) {
    if state==nil || !state.ready {return}
    return sim.breakable_slice(&state.world,h,point,normal)
}

// The same on the body that holds one piece alone, so that the event can travel in the frame of that body:
// what it does no longer depends on where the other bodies of the breakable are.
breakable_strain_region :: proc(state:^Physics_State,h:Breakable_Handle,piece:i32,region:Break_Region,amount:f32,impulse:[3]f32={},weaken:=false) -> (event:Break_Event,broke,strained:bool) {
    if state==nil || !state.ready {return}
    return sim.breakable_strain_region(&state.world,h,piece,region,amount,impulse,weaken)
}
breakable_slice_body :: proc(state:^Physics_State,h:Breakable_Handle,piece:i32,point,normal:[3]f32) -> (event:Break_Event,cut:bool) {
    if state==nil || !state.ready {return}
    return sim.breakable_slice_body(&state.world,h,piece,point,normal)
}

// Takes out of the world the body that holds a piece, when it is one that came off.
breakable_remove_body :: proc(state:^Physics_State,h:Breakable_Handle,piece:i32) -> (event:Break_Event,removed:bool) {
    if state==nil || !state.ready {return}
    return sim.breakable_remove_body(&state.world,h,piece)
}

// Applies an event another simulation in the same state recorded.
breakable_event_apply :: proc(state:^Physics_State,event:Break_Event) -> bool {
    return state!=nil && state.ready && sim.break_event_apply(&state.world,event)
}

// What broke the breakables in the last step: its hits, what expired and the regions of strain_region.
// The slice lasts until the next step.
breakable_events :: proc(physics:core.Ref(Physics_State)) -> []Break_Event {
    if physics.ptr==nil || !physics.ready {return nil}
    return sim.world_events(&physics.world).breaks
}

// What a breakable could not get in the last step: the events that did not fit in Physics_Settings.events
// and the capacities that refused it a break or a cut.
breakable_shortfall :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> (events:int,refused:Break_Capacities) {
    if physics.ptr==nil || !physics.ready {return}
    return sim.breakable_shortfall(&physics.world,h)
}

// Steps until the pieces of a breakable on a body expire, and whether they do.
breakable_body_remaining_ticks :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle,body:Body_Handle) -> (ticks:u32,expires:bool) {
    if physics.ptr==nil || !physics.ready {return}
    return sim.breakable_body_remaining_ticks(&physics.world,h,body)
}

// Strains the breakables the filter meets in a region of the world, each of their bodies by itself: amount
// N s on every bond within reach, by the falloff of the region; with weakening nothing breaks yet. Applied
// after the step of the tick, with its hits: the events are in breakable_events.
strain_region :: proc(requests:^Body_Requests,region:Break_Region,amount:f32,impulse:[3]f32={},weakening:=false,filter:=QUERY_FILTER_DEFAULT) {
    core.push(&requests.queue,Body_Request{
        kind=.Strain,position=region.point,radius=region.radius,half_extents=region.half_extents,rotation=region.rotation,falloff=region.falloff,
        strength=amount,linear=impulse,override=weakening,filter=filter,
    })
}

// The regions of strain the tick asked for, once its step ran.
@(private)
strains_apply :: proc(w:^sim.World,requests:[]Body_Request) {
    for request in requests {
        if request.kind!=.Strain {continue}
        region:=Break_Region{point=request.position,radius=request.radius,half_extents=request.half_extents,rotation=request.rotation,falloff=request.falloff}
        sim.breakables_strain(w,region,request.strength,request.linear,request.override,request.filter)
    }
}
