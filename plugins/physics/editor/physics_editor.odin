package physics_editor

import "base:runtime"
import "mirai:core"
import "mirai:editor"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// What physics gives the editor: the rows of its collision types and of
// Collision_Settings, the collision API, the Collider of a Character, the
// bodies Simulate drives with the gizmo, the Simulate limited to some
// entities that drops them to rest (physics.settle and the Drop tool),
// whether a character stands for the bots that play a game, the colliders of
// the selection and the Collision modes of the viewport.

@(storage)
Physics_Inspector :: struct {provider:editor.Inspector_Provider}

PHYSICS_INSPECTOR_DEFAULT :: Physics_Inspector{provider={field=collision_collider_field,array=collision_settings_field,valid=collision_settings_problem}}

@(storage)
Physics_Api :: struct {provider:editor.Api_Provider}

PHYSICS_API_DEFAULT :: Physics_Api{provider={register=api_register}}

@(private)
api_register :: proc(s:^editor.Session) {
    api_collision_register(s)
    api_settle_register(s)
    api_drop_register(s)
}

@(storage)
Physics_Components :: struct {provider:editor.Component_Provider}

PHYSICS_COMPONENTS_DEFAULT :: Physics_Components{provider={added=collider_companion}}

@(storage)
Physics_Simulation :: struct {provider:editor.Simulation_Provider}

PHYSICS_SIMULATION_DEFAULT :: Physics_Simulation{provider={owner=body_owner,move=body_move,release=body_release,step=phys.step_world,limit=simulation_limit}}

@(storage)
Physics_Bodies :: struct {provider:editor.Body_Provider}

PHYSICS_BODIES_DEFAULT :: Physics_Bodies{provider={standing=character_standing}}

@(private)
collision_settings_problem :: proc(info:^runtime.Type_Info,value:rawptr) -> string {
    if info.id!=phys.Collision_Settings || phys.collision_settings_valid(cast(^phys.Collision_Settings)value) {return ""}
    return COLLISION_SETTINGS_RULE
}

@(private)
body_owner :: proc(w:core.World_Ref,e:core.Entity) -> core.Entity {
    state:=core.world_storage_of(w,phys.Physics_State)
    return state!=nil?phys.manipulation_owner(core.ref(state),e):core.NONE
}

@(private)
body_move :: proc(w:core.World_Ref,e:core.Entity,position:[3]f32,rotation:mm.Quat) -> bool {
    requests:=core.world_storage_of(w,phys.Body_Requests)
    if requests==nil {return false}
    phys.manipulation_target(requests,e,position,rotation)
    return true
}

@(private)
body_release :: proc(w:core.World_Ref,e:core.Entity) -> bool {
    requests:=core.world_storage_of(w,phys.Body_Requests)
    if requests==nil {return false}
    phys.manipulation_end(requests,e)
    return true
}

@(private)
character_standing :: proc(w:core.World_Ref,body:core.Entity) -> (standing,known:bool) {
    states:=core.world_table_of(w,phys.Character_State)
    if states==nil {return}
    state:=core.get(states,body) or_return
    return state.standing,true
}
