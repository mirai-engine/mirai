package physics

import "mirai:core"
import volume "mirai:engine/volume"
import sim "plugins:physics/runtime/sim"

// The bodies fall with the Gravity fields of engine/volume.
//
// The gravity of the world is that of the unbounded fields that pull down,
// combined again only when a field changes: what falls where no bounded field
// is. A field toward a center has no value away from a place and is left out
// of it: whoever needs the gravity of a place asks for that of its entity
// (gravity_of_entity). Each awake body falls with the gravity of the place of
// its center, which asks the index of the fields only for the bounded ones
// there; without bounded fields nor fields toward a center, every body falls
// with that of the world, at no cost per body.

// What the bodies of a world fall with: the fields of its Gravity entities.
Gravity_Fields :: struct {
    index:volume.Index,
    world:[3]f32, // of the unbounded fields that pull down
    center:bool,  // an unbounded field pulls toward a center: it changes from place to place
}

@(private)
Gravity_Place :: struct {
    fields:^Gravity_Fields,
    gravities:^core.Table(volume.Gravity,.Read),
    point:[3]f32,
}

@(private)
gravity_value :: proc(p:Gravity_Place,row:i32) -> [3]f32 {
    return volume.gravity_of(core.at(p.gravities,int(row)),p.fields.index.places[row].world,p.point)
}

// Makes what the fields keep again when a Gravity, its Volume or their
// places changed. False without memory.
@(private)
gravity_fields_update :: proc(fields:^Gravity_Fields,gravities:^core.Table(volume.Gravity,$A),volumes:^core.Table(volume.Volume,$B),worlds:^core.Table(core.World_Transform,$C)) -> (changed,ok:bool) {
    changed,ok=volume.index_update(&fields.index,volumes,worlds,gravities)
    if !changed {return}
    down:volume.Hits
    fields.center=false
    unbounded:=fields.index.unbounded
    for hit in unbounded.hits[:unbounded.count] {
        if core.at(gravities,int(hit.row)).pull==.Down {
            down.hits[down.count]=hit
            down.count+=1
        } else {fields.center=true}
    }
    fields.world=volume.combine(down,volume.GRAVITY_WORLD,Gravity_Place{fields,gravities,{}},gravity_value,volume.mix_linear)
    return
}

// The gravity at a point of the fields as gravity_fields_update left them.
@(private)
gravity_place :: proc(fields:^Gravity_Fields,gravities:^core.Table(volume.Gravity,$A),point:[3]f32) -> [3]f32 {
    hits,bounded:=volume.index_hits(&fields.index,point)
    if !bounded && !fields.center {return fields.world}
    return volume.combine(hits,volume.GRAVITY_WORLD,Gravity_Place{fields,gravities,point},gravity_value,volume.mix_linear)
}

// Whether the bodies fall each with the gravity of its place: some field has
// a border or pulls toward a center.
@(private)
gravity_local :: proc "contextless" (fields:^Gravity_Fields) -> bool {
    return fields.center || volume.index_bounded(&fields.index)
}

// The simulation falls with the gravity of the place of each body; where it
// is the same everywhere, with that of its world alone. physics_step gives it
// after it made the bodies of the tick, which fall from their first one.
@(private)
gravity_apply :: proc(state:^Physics_State,gravities:^core.Table(volume.Gravity,$A),volumes:^core.Table(volume.Volume,$B),worlds:^core.Table(core.World_Transform,$C),problems:^core.Problems) {
    w:=&state.world
    fields:=&state.gravity
    changed,ok:=gravity_fields_update(fields,gravities,volumes,worlds)
    if !ok {memory_problem(problems,core.NONE,"the places of the Gravity fields, so the bodies fall with that of the world")}
    if !gravity_local(fields) {
        // Every body falls with the world: only a change of it reaches them.
        if changed || state.own_gravity || sim.world_gravity(w)!=fields.world {sim.world_set_body_gravity(w,fields.world,nil,nil,true)}
        state.own_gravity=false
        return
    }
    at :: proc(user:rawptr,point:[3]f32) -> [3]f32 {
        p:=(^Gravity_Place)(user)
        return gravity_place(p.fields,p.gravities,point)
    }
    place:=Gravity_Place{fields=fields,gravities=gravities}
    sim.world_set_body_gravity(w,fields.world,at,&place,changed || !state.own_gravity)
    state.own_gravity=true
}

// The gravity the body of an entity falls with; that of the world without one.
gravity_of_entity :: proc(physics:core.Ref(Physics_State),e:core.Entity) -> [3]f32 {
    if physics.ptr==nil || !physics.ready {return volume.GRAVITY_WORLD}
    if body:=body_of(physics,e);body!={} {return sim.body_gravity(&physics.world,body)}
    return physics.world.gravity
}
