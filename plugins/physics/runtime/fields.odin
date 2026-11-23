package physics

import "core:math/linalg"
import "mirai:core"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import mm "mirai:std/math"

// A force that lasts on the bodies in the Volume of its entity: a draught in
// a shaft, a lift, a magnet, a whirl. Each tick it asks apply_area for its
// volume where the entity is, once for its force and once for its
// acceleration; core.disable turns it off without losing its values. Without
// a Volume it pushes in the whole world.
@(component,description="Pushes the bodies in the Volume of its entity every tick: away from its center, along the up of a Plane, or along a direction of the entity. A force moves a light body more than a heavy one; an acceleration moves any the same. Both rise over its blend inside the border by its falloff.")
Force_Field :: struct {
    force:f32 `mirai:"unit=N"`,   // negative pulls in
    acceleration:f32 `mirai:"unit=m/s^2"`, // the same on any mass, with the force; negative pulls in
    along:[3]f32,                 // in the frame of the entity; zero: away from its center, or along the up of a Plane
    blend:f32 `mirai:"min=0,unit=m"`, // inside the border of the Volume, where the push rises from 0
    falloff:Radial_Falloff,       // how the push rises over the blend
    falloff_range:Weight_Range,   // weights of the push at the border and inside the blend; zero is 0 to 1
    noise:Field_Noise,            // scales the push; zero scale is none
    filter:Query_Filter,
}

FORCE_FIELD_DEFAULT :: Force_Field{falloff=.Linear,filter=QUERY_FILTER_DEFAULT}

@(step="fixed",stage="simulate",before="physics_prepare")
force_fields_step :: proc(fields:^core.Table(Force_Field,.Read),volumes:^core.Table(volume.Volume,.Read),worlds:^core.Table(core.World_Transform,.Read),parents:^core.Table(core.Parent,.Read),sections:^core.Table(scene.Scene_Reference,.Read),bodies:^Body_Requests,time:core.Time) {
    if !time.playing || !(time.dt>0) {return}
    for row in 0..<core.count(fields) {
        field:=core.at(fields,row)
        if field.force==0 && field.acceleration==0 {continue}
        e:=core.entity_at(fields,row)
        area,pose,_,rules:=volume.placed({volumes,worlds,parents,sections,nil},e)
        if !rules {continue}
        along:=linalg.normalize0(field.along)
        if world,placed:=core.get(worlds,e);placed {along=mm.quat_rotate(world.rotation,along)}
        for strength,per_mass in ([2]f32{field.force,field.acceleration}) {
            if strength==0 {continue}
            apply_area(bodies,area,pose,strength,along,per_mass=per_mass==1,blend=field.blend,falloff=field.falloff,filter=field.filter,range=field.falloff_range,noise=field.noise,outline_of=e)
        }
    }
}
