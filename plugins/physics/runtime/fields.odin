package physics

import "core:math/linalg"
import "mirai:core"
import volume "mirai:engine/volume"
import mm "mirai:std/math"

// A force that lasts on the bodies in the Volume of its entity: a draught in
// a shaft, a lift, a magnet, a whirl. Each tick it asks apply_area for its
// volume where the entity is; core.disable turns it off without losing its
// values. Without a Volume it pushes in the whole world.
@(component,description="Pushes the bodies in the Volume of its entity every tick: away from its center, along the up of a Plane, or along a direction of the entity. The force rises over the blend of the Volume by its falloff.")
Force_Field :: struct {
    force:f32 `mirai:"unit=N"`,   // negative pulls in
    along:[3]f32,                 // in the frame of the entity; zero: away from its center, or along the up of a Plane
    falloff:Radial_Falloff,       // how the force rises over the blend of the Volume
    falloff_range:Weight_Range,   // weights of the force at the border and inside the blend; zero is 0 to 1
    noise:Field_Noise,            // scales the force; zero scale is none
    filter:Query_Filter,
}

FORCE_FIELD_DEFAULT :: Force_Field{falloff=.Linear,filter={objects=COLLISION_LAYERS_ALL}}

@(step="fixed",stage="simulate",before="physics_prepare")
force_fields_step :: proc(fields:core.Read(Force_Field),volumes:core.Read(volume.Volume),worlds:core.Read(core.World_Transform),bodies:^Body_Requests,time:core.Time) {
    if !time.playing || !(time.dt>0) {return}
    for row in 0..<core.count(fields) {
        field:=core.at(fields,row)
        if field.force==0 {continue}
        e:=core.entity_at(fields,row)
        area,pose,rules:=volume.placed(volumes,worlds,e)
        if !rules {continue}
        along:=linalg.normalize0(field.along)
        if world,placed:=core.get(worlds,e);placed {along=mm.quat_rotate(world.rotation,along)}
        apply_area(bodies,area,pose,field.force,along,falloff=field.falloff,filter=field.filter,range=field.falloff_range,noise=field.noise)
    }
}
