package physics_fields

import "core:math/linalg"
import "mirai:core"
import phys "plugins:physics/runtime"
import mm "mirai:std/math"

// Plane: a box whose local +Y face is the plane; the falloff goes from it down to the -Y face.
Field_Shape :: enum u8 {Sphere,Box,Plane}
// Radial: away from the center, or along the normal of a plane.
Field_Direction :: enum u8 {Radial,Directional}

@(component,description="Applies continuous force or strain inside a region to what its filter sees; by default every collision category.")
Physics_Field :: struct {
    shape:Field_Shape,
    direction:Field_Direction,
    radius:f32 `mirai:"min=0,unit=m"`,
    half_extents:mm.Vec3,
    vector:mm.Vec3,
    force:f32 `mirai:"unit=N"`,
    strain:f32, // N s per second
    weakening:bool,
    falloff:phys.Radial_Falloff,
    falloff_range:phys.Weight_Range, // weights of the force at the border and at the center; zero is 0 to 1
    noise:phys.Field_Noise,          // scales the force; zero scale is none
    filter:phys.Query_Filter,
}

PHYSICS_FIELD_DEFAULT :: Physics_Field{radius=3,half_extents={3,3,3},vector={0,1,0},falloff=.Linear,filter={objects=phys.COLLISION_LAYERS_ALL}}

@(step="fixed",stage="simulate",before="physics_prepare")
physics_fields_step :: proc(
    fields:core.Read(Physics_Field),transforms:core.Read(core.Transform),parents:core.Read(core.Parent),
    authority:core.Ref(core.Network),bodies:^phys.Body_Requests,time:core.Time,
) {
    if !time.playing || !(time.dt>0) {return}
    for row in 0..<core.count(fields) {
        field:=core.at(fields,row)
        if field.shape>.Plane || field.direction>.Directional {continue}
        pose,placed:=core.world_of(transforms,parents,core.entity_at(fields,row))
        if !placed {continue}
        scale:=linalg.abs(pose.scale)
        radius,half:=field.radius*max(scale.x,scale.y,scale.z),field.half_extents*scale
        direction:=mm.quat_rotate(pose.rotation,linalg.normalize0(field.vector))*field.force
        range,noise:=field.falloff_range,field.noise
        if field.force!=0 {
            switch field.shape {
            case .Sphere:
                if field.direction==.Radial {phys.apply_radial_force(bodies,pose.position,radius,field.force,field.falloff,field.filter,range,noise)}
                else {phys.apply_sphere_force(bodies,pose.position,radius,direction,field.falloff,field.filter,range,noise)}
            case .Box:
                if field.direction==.Radial {phys.apply_box_radial_force(bodies,pose.position,half,pose.rotation,field.force,field.falloff,field.filter,range,noise)}
                else {phys.apply_box_force(bodies,pose.position,half,pose.rotation,direction,field.falloff,field.filter,range,noise)}
            case .Plane:
                if field.direction==.Radial {direction=mm.quat_rotate(pose.rotation,mm.Vec3{0,1,0})*field.force}
                phys.apply_plane_force(bodies,pose.position,half,pose.rotation,direction,field.falloff,field.filter,range,noise)
            }
        }
        if !(field.strain>0) || authority.role==.Client {continue}
        region:=phys.Break_Region{point=pose.position,radius=radius,rotation=pose.rotation,falloff=field.falloff}
        if field.shape!=.Sphere {region.half_extents=half}
        phys.strain_region(bodies,region,field.strain*time.dt,weakening=field.weakening,filter=field.filter)
    }
}
