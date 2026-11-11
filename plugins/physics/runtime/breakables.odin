package physics

import "core:math/linalg"
import "mirai:core"
import volume "mirai:engine/volume"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

// Breakable bodies of the simulation, for a library that makes them from its own data and mirrors what
// becomes of them, as destruct does for a Destructible: the procedures of the solver (sim/breakable.odin)
// on a Physics_State, which do nothing while it is not ready. A breakable is state of the simulation: a
// copy for Play, a rollback or a save takes it with the bodies. Its bodies name the entity it was made
// with until breakable_body_name gives them another.

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
Cluster_Desc :: sim.Cluster_Desc
Cluster_Info :: sim.Cluster_Info
Body_Pose :: sim.Transform

BREAKABLE_DESC_DEFAULT :: sim.BREAKABLE_DESC_DEFAULT

@(private) made :: #force_inline proc "contextless" (state:^Physics_State) -> bool {return state!=nil && state.ready}

// Where a body is; false for a body that is gone.
body_pose :: proc(physics:core.Ref(Physics_State),body:Body_Handle) -> (pose:Body_Pose,ok:bool) {
    if !made(physics.ptr) || !sim.body_valid(&physics.world,body) {return}
    return sim.body_transform(&physics.world,body),true
}

// The capacities Physics_Settings gave the breakables of the simulation.
Breakable_Room :: struct {breakables,pieces,bonds,bodies,events:int}
breakable_room :: proc(physics:core.Ref(Physics_State)) -> Breakable_Room {
    if !made(physics.ptr) {return {}}
    d:=physics.world.desc
    return {d.breakable_capacity,d.piece_capacity,d.bond_capacity,d.body_capacity,d.event_capacity}
}

breakable_create :: proc(state:^Physics_State,desc:Breakable_Desc) -> (handle:Breakable_Handle,error:Breakable_Error) {
    if !made(state) {return {},.Invalid_Desc}
    return sim.breakable_create(&state.world,desc)
}
breakable_destroy :: proc(state:^Physics_State,h:Breakable_Handle) {
    if made(state) {sim.breakable_destroy(&state.world,h)}
}
breakable_valid :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> bool {
    return made(physics.ptr) && sim.breakable_valid(&physics.world,h)
}
// The breakable made for an entity (Breakable_Desc.user_data).
breakable_of :: proc(physics:core.Ref(Physics_State),e:core.Entity) -> Breakable_Handle {
    return made(physics.ptr)?sim.breakable_find(&physics.world,u64(e)):{}
}
breakable_body :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> Body_Handle {
    return made(physics.ptr)?sim.breakable_body(&physics.world,h):{}
}
// Makes a body of a breakable name an entity in contacts and queries; false for any other body.
breakable_body_name :: proc(state:^Physics_State,body:Body_Handle,e:core.Entity) -> bool {
    if !made(state) {return false}
    if owner,_:=sim.breakable_of(&state.world,body);owner=={} {return false}
    sim.body_set_user_data(&state.world,body,u64(e))
    return true
}
breakable_surface :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> (density,friction,restitution:f32,filter:Collision_Filter,ok:bool) {
    if !made(physics.ptr) {return}
    return sim.breakable_surface(&physics.world,h)
}
breakable_set_filter :: proc(state:^Physics_State,h:Breakable_Handle,filter:Collision_Filter) {
    if made(state) {sim.breakable_set_filter(&state.world,h,filter)}
}
breakable_pieces :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle,out:[]Piece_Info) -> int {
    return made(physics.ptr)?sim.breakable_pieces(&physics.world,h,out):0
}
breakable_clusters :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle,out:[]Cluster_Info) -> int {
    return made(physics.ptr)?sim.breakable_clusters(&physics.world,h,out):0
}
breakable_revision :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> u32 {
    return made(physics.ptr)?sim.breakable_revision(&physics.world,h):0
}
breakable_check :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> u32 {
    return made(physics.ptr)?sim.breakable_check(&physics.world,h):0
}
breakable_state_size :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> int {
    return made(physics.ptr)?sim.breakable_state_size(&physics.world,h):0
}
breakable_state_write :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle,out:[]u8) -> int {
    return made(physics.ptr)?sim.breakable_state_write(&physics.world,h,out):0
}
breakable_state_apply :: proc(state:^Physics_State,h:Breakable_Handle,data:[]u8) -> bool {
    return made(state) && sim.breakable_state_apply(&state.world,h,data)
}
breakable_shortfall :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle) -> (events:int,refused:Break_Capacities) {
    if !made(physics.ptr) {return}
    return sim.breakable_shortfall(&physics.world,h)
}
breakable_body_remaining_ticks :: proc(physics:core.Ref(Physics_State),h:Breakable_Handle,body:Body_Handle) -> (ticks:u32,expires:bool) {
    if !made(physics.ptr) {return}
    return sim.breakable_body_remaining_ticks(&physics.world,h,body)
}

// Strains, cuts or takes a body out of a breakable, or repeats what another simulation recorded: sim.break_apply.
break_apply :: proc(state:^Physics_State,event:Break_Event) -> (applied:Break_Event,changed,strained:bool) {
    if !made(state) {return event,false,false}
    return sim.break_apply(&state.world,event)
}

// What broke the breakables in the last step: its hits, what expired and what strain_area asked. The slice
// lasts until the next step.
breakable_events :: proc(physics:core.Ref(Physics_State)) -> []Break_Event {
    return made(physics.ptr)?sim.world_events(&physics.world).breaks:nil
}

// Strains the breakables the filter meets in a volume placed at pose, a box or a sphere, each of their
// bodies by itself: amount N s on every bond, by the weight of the volume there, rising over blend metres
// from its border; with weakening nothing breaks yet. Applied once the step of the tick ran, with its hits:
// what it did is in breakable_events.
strain_area :: proc(requests:^Body_Requests,area:volume.Volume,pose:mm.Transform,amount:f32,weakening:=false,filter:=QUERY_FILTER_DEFAULT,blend:f32=0) {
    core.push(&requests.queue,Body_Request{kind=.Area_Strain,area=area,position=pose.position,rotation=pose.rotation,scale=pose.scale,blend=blend,strength=amount,override=weakening,filter=filter})
}

@(private)
strains_apply :: proc(w:^sim.World,requests:[]Body_Request) {
    for request in requests {
        if request.kind!=.Area_Strain {continue}
        scale:=request.scale=={}?[3]f32{1,1,1}:linalg.abs(request.scale)
        region:=Break_Region{point=request.position,rotation=request.rotation,blend=request.blend}
        #partial switch request.area.shape {
        case .Sphere: region.radius=request.area.extents.x*max(scale.x,scale.y,scale.z)
        case .Box:    region.half_extents=request.area.extents*scale
        }
        sim.breakables_strain(w,region,request.strength,{},request.override,request.filter)
    }
}
