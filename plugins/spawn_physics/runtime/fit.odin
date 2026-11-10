package spawn_physics

import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"
import spawn "plugins:spawn/runtime"

// A body the Play of the editor puts where it was asked (its camera, a point
// of the scene) stands, by the collider of its root, on what is under that
// place: a click on the floor does not bury it and a camera in a room puts it
// on the floor. The shape comes down from as high as it is over the place;
// from inside something it comes down from where it was put. Without
// anything under it within reach, or inside something, it stays there.

SPAWN_FIT_REACH :: f32(2) // m the bottom of the shape goes down from the place for something to stand on

@(step="fixed",stage="input")
spawn_fit :: proc(at_origin:core.Ref(spawn.Spawned_At_Origin),colliders:core.Read(phys.Collider),physics:core.Ref(phys.Physics_State),placer:core.Placer) {
    for body in at_origin.items {
        collider,ok:=core.get(colliders,body)
        if !ok || collider.sensor {continue}
        shape,below:=fit_shape(collider)
        if shape==nil {continue}
        placed:=core.world_of(core.read(placer.transforms),placer.parents,body) or_continue
        down:=linalg.normalize0(phys.gravity(physics))
        if down=={} {down={0,-1,0}}
        center:=placed.position+mm.quat_rotate(placed.rotation,collider.center)
        for lift in ([2]f32{2*below,0}) {
            hit,met:=phys.sweep(physics,shape,center-down*lift,placed.rotation,down,lift+SPAWN_FIT_REACH,body)
            if !met {break}
            if hit.normal=={} {continue} // it starts inside a shape
            core.place(placer,body,placed.position+down*(hit.distance-lift),placed.rotation)
            break
        }
    }
}

// The shape of a collider for a sweep and how far its bottom is under its center.
@(private)
fit_shape :: proc(c:phys.Collider) -> (shape:phys.Sweep_Shape,below:f32) {
    #partial switch c.kind {
    case .Sphere:   return phys.Sphere{c.size.x},c.size.x
    case .Capsule:  return phys.Capsule{c.size.x,c.size.y},c.size.x+c.size.y
    case .Box:      return phys.Box{c.size},c.size.y
    case .Cylinder: return phys.Cylinder{c.size.x,c.size.y},c.size.y
    }
    return
}
