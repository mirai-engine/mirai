package volume

import "core:math/linalg"
import mm "mirai:std/math"

// Where things fall, in m/s2, equal for every mass: the gravity of a level,
// a room without it, a planet. Each one rules where the Volume of its entity
// says, by the priority of its zone, replacing what is below or adding to it; without a
// Volume it is the gravity of the whole world. The bodies of the plugin
// physics and the particles of vfx fall with it, and with GRAVITY_WORLD where
// none rules.

Gravity_Pull :: enum u8 {
    Down,   // along -Y of the entity: turn it to turn where things fall
    Center, // toward the entity, as a planet
}

@(component,replicated,description="Where things fall, the same for every mass: down along the entity or toward it, as a planet. It rules where the Volume of the entity says; without one, in the whole world.")
Gravity :: struct {
    pull:Gravity_Pull,
    acceleration:f32 `mirai:"unit=m/s2"`,
    radius:f32 `mirai:"min=0,unit=m"`, // Center: the surface, times the scale; it weakens with the square of the distance beyond it and toward the center inside it; 0: as strong at any distance
    zone:Zone,
}

GRAVITY_DEFAULT :: Gravity{acceleration=9.81,zone=ZONE_DEFAULT}

// What things fall with where no Gravity rules, m/s2.
GRAVITY_WORLD :: [3]f32{0,-9.81,0}

// What the gravity of a field is at a point.
gravity_of :: proc "contextless" (g:Gravity,pose:mm.Transform,point:[3]f32) -> [3]f32 {
    switch g.pull {
    case .Down:
        return mm.quat_rotate(pose.rotation,[3]f32{0,-g.acceleration,0})
    case .Center:
        to:=pose.position-point
        distance:=linalg.length(to)
        if !(distance>1e-4) {return {}}
        scale:=linalg.abs(pose.scale)
        surface:=g.radius*max(scale.x,scale.y,scale.z)
        strength:=g.acceleration
        if surface>0 {
            if distance>surface {strength*=(surface*surface)/(distance*distance)} else {strength*=distance/surface}
        }
        return to/distance*strength
    }
    return {}
}
