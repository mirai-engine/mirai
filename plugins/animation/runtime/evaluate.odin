package anim

import "mirai:core"
import "mirai:host"

// Evaluates only animation and its transforms: the functions of this library
// and of core in the fixed phase of the editor loop, with the binding and the
// settle the generator gives them. The caller chooses the world, including a
// disposable clone for a preview or an offline tool.
animation_evaluate :: proc(world:core.World_Ref,app:^host.App,dt:f32) -> bool {
    if app==nil || app.shared==nil || world.data==nil || world.info==nil || world.place!=.World || !finite(dt) || dt<0 {return false}
    defer core.world_events_age(world)
    return core.world_run(world,app.shared,nil,app,.Editor,.Fixed,{"anim","core"},{dt=dt,playing=true})
}
