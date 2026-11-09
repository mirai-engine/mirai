package game

import "core:math"
import "mirai:core"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

Rig_Playground_Kind :: enum u8 {Spline,Stretch,Corrective}
@(component)
Rig_Playground :: struct {kind:Rig_Playground_Kind,origin:mm.Vec3,age:f32 `mirai:"transient"`}

@(step="fixed")
rig_playground_animate :: proc(items:^core.Table(Rig_Playground),goals:^anim.Modifier_Requests,poses:^anim.Animation_Requests,time:core.Time) {
    for &item,row in items.values[:core.count(items)] {
        rig:=core.entity_at(items,row);item.age+=time.dt
        phase:=item.age
        switch item.kind {
        case .Spline:
            controls:=[4]mm.Vec3{item.origin,item.origin+{math.sin(phase*.8)*.8,.7,.3},item.origin+{math.sin(phase*.8+.8)*.9,1.5,-.2},item.origin+{math.sin(phase*.8+1.4)*.8,2.3,0}}
            for point,i in controls {anim.modifier_goal(goals,{rig=rig,kind=.Spline_IK,effector=u8(i),target=anim.spatial_point(point),weight=1,enabled=true})}
        case .Stretch:
            target:=item.origin+mm.Vec3{.4*math.sin(phase*.7),2.25+.65*math.sin(phase*.7),0}
            anim.modifier_goal(goals,{rig=rig,kind=.Chain_IK,target=anim.spatial_point(target),weight=1,enabled=true})
        case .Corrective:
            pose:=mm.TRANSFORM_IDENTITY;pose.position={0,.28,0};pose.rotation=mm.quat_axis_angle({0,0,1},(.5+.5*math.sin(phase))*1.4)
            anim.animation_pose(poses,rig,anim.bone_ref("joint3"),pose)
        }
    }
}
