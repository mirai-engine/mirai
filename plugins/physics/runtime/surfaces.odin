package physics

import "mirai:core"
import sim "plugins:physics/runtime/sim"
import "mirai:std/base"

COLLISION_SURFACE_CAPACITY :: sim.SURFACE_RULE_CAPACITY

// How a material collides where a collider shows one material per place:
// each cell of a terrain shows the material that covers most of it, and
// meets what touches it with this friction and restitution, mixed with
// those of the other collider as two colliders mix. A material without an
// entry collides as the Collider that shows it. A hit or a contact names
// what it touched by its material either way (Hit.material).
Collision_Surface :: struct {
    material:base.Asset_Id `mirai:"kind=.mat"`,
    friction:f32 `mirai:"min=0"`,
    restitution:f32 `mirai:"min=0,max=1"`,
}

// Gives the simulation the surface rules of the settings. An entry that cannot be one (a friction below
// zero or not finite, a restitution outside 0..1, a material an earlier entry has) is a problem and is
// left out.
@(private)
collision_surfaces_apply :: proc(w:^sim.World,settings:^Collision_Settings,problems:^core.Problems) {
    rules:[COLLISION_SURFACE_CAPACITY]sim.Surface_Rule
    count:=0
    each: for entry,i in settings.surfaces {
        if entry.material=={} {continue}
        if !(entry.friction>=0 && entry.friction<=max(f32)) || !(entry.restitution>=0 && entry.restitution<=1) {
            core.report(problems,core.NONE,"physics.collision_surface","Collision_Settings.surfaces[%d] has friction %v and restitution %v, so its material collides as its colliders do; give it a friction of 0 or more and a restitution from 0 to 1",i,entry.friction,entry.restitution)
            continue
        }
        for rule in rules[:count] {
            if rule.surface!=sim.Surface(entry.material) {continue}
            core.report(problems,core.NONE,"physics.collision_surface","Collision_Settings.surfaces[%d] names a material an earlier entry has, and is left out; keep one entry per material",i)
            continue each
        }
        rules[count]={sim.Surface(entry.material),entry.friction,entry.restitution}
        count+=1
    }
    sim.world_set_surface_rules(w,rules[:count])
}
