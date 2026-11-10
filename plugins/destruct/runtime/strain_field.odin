package destruct

import "core:math/linalg"
import "mirai:core"
import volume "mirai:engine/volume"
import phys "plugins:physics/runtime"

// Strain that lasts on the destructibles in the Volume of its entity, a box
// or a sphere: heat that weakens a wall, a press. Each tick it asks
// field_strain of every destructible its filter sees, with the region of the
// volume; the strain is whole inside a volume without blend and rises from
// its border to its center in one with it.
@(component,description="Strains the destructibles in the Volume of its entity, a box or a sphere, every tick: damage that breaks them, or with weakening, strain they keep without letting pieces go.")
Strain_Field :: struct {
    strain:f32 `mirai:"min=0"`, // N s per second
    weakening:bool,
    filter:phys.Query_Filter,
}

STRAIN_FIELD_DEFAULT :: Strain_Field{filter={objects=phys.COLLISION_LAYERS_ALL}}

// The server decides what breaks: a client asks for no strain.
@(step="fixed",stage="simulate",before="physics_prepare")
strain_fields_step :: proc(
    fields:core.Read(Strain_Field),volumes:core.Read(volume.Volume),worlds:core.Read(core.World_Transform),
    destructibles:core.Read(Destructible),colliders:core.Read(phys.Collider),authority:core.Ref(core.Network),
    damage:^Destruct_Requests,time:core.Time,collision:core.Ref(phys.Collision_Settings),problems:^core.Problems,
) {
    if !time.playing || !(time.dt>0) || authority.role==.Client {return}
    for row in 0..<core.count(fields) {
        field:=core.at(fields,row)
        if !(field.strain>0) {continue}
        e:=core.entity_at(fields,row)
        area,pose,rules:=volume.placed(volumes,worlds,e)
        if !rules {continue}
        scale:=linalg.abs(pose.scale)
        region:=Destruct_Region{point=pose.position,rotation=pose.rotation,falloff=area.blend>0?.Linear:.Constant}
        #partial switch area.shape {
        case .Sphere: region.radius=area.extents.x*max(scale.x,scale.y,scale.z)
        case .Box:    region.half_extents=area.extents*scale
        case:
            core.report(problems,e,"destruct.strain_field","its Strain_Field strains nothing: it needs a Volume of shape Box or Sphere on its entity (volume.box, volume.sphere)")
            continue
        }
        for target in 0..<core.count(destructibles) {
            d:=core.entity_at(destructibles,target)
            collider,_:=core.get(colliders,d)
            if phys.query_meets(field.filter,phys.collision_filter(collision.ptr,collider))==.Ignore {continue}
            field_strain(damage,d,region,field.strain*time.dt,weakening=field.weakening,ignore_body=field.filter.ignore_body)
        }
    }
}
