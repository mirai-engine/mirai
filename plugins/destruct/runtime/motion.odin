package destruct

import "mirai:core"
import phys "plugins:physics/runtime"
import mm "mirai:std/math"

@(step="fixed",stage="simulate",before="physics_prepare")
destruct_parent_motion :: proc(
    physics:core.Ref(phys.Physics_State),destructibles:core.Read(Destructible),states:core.Read(Destructible_State),
    transforms:core.Read(core.Transform),parents:core.Read(core.Parent),requests:^phys.Body_Requests,time:core.Time,
) {
    if !time.playing || !physics.ready {return}
    for row in 0..<core.count(destructibles) {
        config:=core.at(destructibles,row)
        if !config.follow_parent {continue}
        e:=core.entity_at(destructibles,row)
        state,has:=core.get(states,e)
        held,valid:=phys.body_pose(physics,state.body)
        if !has || !valid {continue}
        desired:=mm.Transform{state.initial.position,state.initial.rotation,state.initial.scale}
        if parent,attached:=core.get(parents,e);attached {
            above,ok:=core.world_of(transforms,parents,parent.entity)
            if !ok {continue}
            desired=mm.transform_compose(above,desired)
        }
        if held.p!=desired.position || held.q!=desired.rotation {phys.move_kinematic(requests,e,desired.position,desired.rotation)}
    }
}
