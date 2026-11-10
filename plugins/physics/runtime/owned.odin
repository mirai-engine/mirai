package physics

import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

// Bodies of the simulation that another library owns: static collision it makes from its own data, as the
// cells of a foliage. The library makes and ends them here and keeps their handles, which live with the world
// as the simulation does: a copy for Play or a rollback takes both. Physics never makes, moves or ends one by
// itself, and knows whose each one is, so a hit on one names its owner without the owner looking for it.

Body_Handle :: sim.Body_Handle
Shape_Handle :: sim.Shape_Handle

// The library that owns a body: a number it declares for itself, never zero.
Body_Owner :: distinct u32

// What a body is to its owner: the entity its hits name and the owner's own index of it.
Owned_Body :: struct {
    owner:Body_Owner,
    entity:core.Entity,
    user:u64,
}

// A shape of an owned body: a Box, Sphere, Capsule or Cylinder collider where position and rotation put it in
// the frame of the body, with the collision of the collider; user is what its owner knows it by.
Owned_Shape :: struct {
    collider:Collider,
    position:[3]f32,
    rotation:mm.Quat,
    user:u64,
}

// By the slot of its body.
@(private)
Owned :: struct {body:Body_Handle,owner:Body_Owner,user:u64}

@(private)
owned_find :: proc(state:^Physics_State,body:Body_Handle) -> ^Owned {
    if state==nil || !state.ready || body=={} {return nil}
    slot:=int(base.handle_index(base.Handle(body)))
    if slot>=len(state.owned) || state.owned[slot].body!=body || !sim.body_valid(&state.world,body) {return nil}
    return &state.owned[slot]
}

Owned_Error :: enum u8 {
    None,
    Invalid,       // no simulation, or no owner
    Capacity,      // Physics_Settings.bodies are in use
    Out_Of_Memory,
}

// Makes a static body of its owner at a world pose; zero with the reason when it is not made.
owned_body_create :: proc(state:^Physics_State,body:Owned_Body,position:[3]f32,rotation:mm.Quat) -> (made:Body_Handle,error:Owned_Error) {
    if state==nil || !state.ready || body.owner==0 {return {},.Invalid}
    made=sim.body_create(&state.world,{type=.Static,position=position,rotation=rotation,user_data=u64(body.entity)})
    if made=={} {return {},.Capacity}
    slot:=int(base.handle_index(base.Handle(made)))
    if slot>=len(state.owned) && resize(&state.owned,min(max(slot+1,2*len(state.owned)),state.world.desc.body_capacity))!=nil {
        sim.body_destroy(&state.world,made)
        return {},.Out_Of_Memory
    }
    state.owned[slot]={made,body.owner,body.user}
    return made,.None
}

// Ends an owned body with its shapes. False for a body that is not owned, or is gone.
owned_body_destroy :: proc(state:^Physics_State,body:Body_Handle) -> bool {
    owned:=owned_find(state,body)
    if owned==nil {return false}
    owned^={}
    sim.body_destroy(&state.world,body)
    return true
}

// Puts an owned body at a world pose, as its owner moves what it made: what touches it wakes and is not pushed.
// False for a body that is not owned, or is gone.
owned_body_place :: proc(state:^Physics_State,body:Body_Handle,position:[3]f32,rotation:mm.Quat) -> bool {
    if owned_find(state,body)==nil {return false}
    sim.body_set_transform(&state.world,body,position,rotation)
    return true
}

// What an owned body is to its owner; false for any other body.
owned_body_of :: proc(state:^Physics_State,body:Body_Handle) -> (found:Owned_Body,ok:bool) {
    owned:=owned_find(state,body)
    if owned==nil {return}
    return {owned.owner,core.Entity(sim.body_user_data(&state.world,body)),owned.user},true
}

// Gives an owned body a shape. Zero when the body is not owned, the collider is not of those kinds, or the
// simulation has no room for it (Physics_Settings.shapes).
owned_shape_create :: proc(state:^Physics_State,collision:^Collision_Settings,body:Body_Handle,shape:Owned_Shape) -> Shape_Handle {
    if owned_find(state,body)==nil {return {}}
    #partial switch shape.collider.kind {
    case .Hull,.Mesh,.Heightfield,.External: return {}
    }
    desc:=collider_desc(shape.collider,{1,1,1},collision_filter(collision,shape.collider),core.NONE)
    position:=shape.position
    if shape.collider.center!={} {position+=mm.quat_rotate(shape.rotation,shape.collider.center)}
    desc.transform={position,shape.rotation}
    desc.user_data=shape.user
    return sim.shape_create(&state.world,body,desc,false)
}

// Ends one shape of an owned body, which keeps the others. False when it is not one, or is gone.
owned_shape_destroy :: proc(state:^Physics_State,shape:Shape_Handle) -> bool {
    if _,ok:=owned_shape_user(state,shape);!ok {return false}
    sim.shape_destroy(&state.world,shape,false)
    return true
}

// What the owner of a shape of an owned body knows it by; false for any other shape.
owned_shape_user :: proc(state:^Physics_State,shape:Shape_Handle) -> (user:u64,ok:bool) {
    if state==nil || !state.ready || !sim.shape_valid(&state.world,shape) || owned_find(state,sim.shape_body(&state.world,shape))==nil {return}
    return sim.shape_user_data(&state.world,shape),true
}

// Whether the simulation was replaced (a copy, a swap, a reset) since seen was last given here: what a cache
// outside the world keeps of its bodies is then of another simulation.
simulation_replaced :: proc(state:^Physics_State,seen:^u32) -> bool {
    if seen^==state.epoch {return false}
    seen^=state.epoch
    return true
}

// The capacities the simulation of a world is made with: those of the settings, and the default of each one
// left at zero.
settings_capacities :: proc(settings:Physics_Settings) -> Physics_Settings {
    desc:=sim.world_desc_default()
    s:=settings
    if s.bodies<=0 {s.bodies=i32(desc.body_capacity)}
    if s.shapes<=0 {s.shapes=i32(desc.shape_capacity)}
    if s.contacts<=0 {s.contacts=i32(desc.contact_capacity)}
    if s.joints<=0 {s.joints=i32(desc.joint_capacity)}
    if s.characters<=0 {s.characters=i32(desc.character_capacity)}
    if s.fluids<=0 {s.fluids=i32(desc.fluid_capacity)}
    if s.breakables<=0 {s.breakables=i32(desc.breakable_capacity)}
    if s.pieces<=0 {s.pieces=i32(desc.piece_capacity)}
    if s.bonds<=0 {s.bonds=i32(desc.bond_capacity)}
    if s.hulls<=0 {s.hulls=i32(desc.hull_capacity)}
    if s.meshes<=0 {s.meshes=i32(desc.mesh_capacity)}
    if s.heightfields<=0 {s.heightfields=i32(desc.heightfield_capacity)}
    if s.events<=0 {s.events=i32(desc.event_capacity)}
    if s.substeps<=0 {s.substeps=i32(desc.substeps)}
    return s
}
