package vehicles

import "core:math"
import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"

// An Aim turns its entity about one of its axes toward where the body it
// hangs from looks (the Move_Input of the nearest entity above it that has
// one): a yaw Aim on a ring and a pitch Aim on the barrel under it make a
// turret. Where it is turned (angle) is simulation, of the tick, from the
// angles of the Aims above it, so every end and a tick run again aim alike;
// its Transform only shows it (vehicles_show), which owns its rotation:
// orient the rest of the turret with its parent.

AIM_CHAIN :: 16 // entities above an Aim its turn is composed through

Aim_Axis :: enum u8 {
    Yaw,   // about its up (+Y), toward the yaw of the look
    Pitch, // about its right (+X), toward the pitch of the look
}

@(component,replicated,description="Turns this entity about one of its axes toward where the body it hangs from looks: a turret ring, a gun barrel.")
Aim :: struct {
    axis:Aim_Axis,
    speed:f32 `mirai:"min=0,unit=rad/s"`, // the most it turns; 0: at once
    min,max:f32 `mirai:"angle"`,          // the angles it stays within; both 0: none, a yaw turns all around
    angle:f32 `mirai:"transient,readonly,angle"`, // where it is turned now
}

AIM_DEFAULT :: Aim{axis=.Yaw,speed=1.5}

// The rotation of an Aim at its angle, under its parent.
aim_rotation :: proc "contextless" (aim:Aim) -> mm.Quat {
    return mm.quat_axis_angle(aim.axis==.Yaw?[3]f32{0,1,0}:[3]f32{1,0,0},aim.angle)
}

// The rotation in the world of what e hangs from, with each Aim above it at its angle.
@(private)
parent_rotation :: proc(aims:^core.Table(Aim),locals:^core.Table(core.Transform,$A),parents:^core.Table(core.Parent,$B),e:core.Entity) -> mm.Quat {
    chain:[AIM_CHAIN]mm.Quat
    count:=0
    at:=(core.get(parents,e) or_else core.Parent{}).entity
    for at!=core.NONE && count<AIM_CHAIN {
        if aim,ok:=core.get(aims,at);ok {chain[count]=aim_rotation(aim)} else {
            local,_:=core.get(locals,at)
            chain[count]=local.rotation==0?mm.QUAT_IDENTITY:local.rotation
        }
        count+=1
        at=(core.get(parents,at) or_else core.Parent{}).entity
    }
    rotation:=mm.QUAT_IDENTITY
    for i:=count-1;i>=0;i-=1 {rotation=rotation*chain[i]}
    return rotation
}

// Each Aim turns toward the look of the body it hangs from, within its speed and its limits.
@(private)
aims_turn :: proc(aims:^core.Table(Aim),view:Vehicle_View,dt:f32) {
    for row in 0..<core.count(aims) {
        e:=core.entity_at(aims,row)
        body:=core.ancestor_with(view.parents,view.moves,e)
        if body==core.NONE || !core.owned(view.remotes,body) {continue}
        move,_:=core.get(view.moves,body)
        aim:=core.at(aims,row)
        look:=core.vertical_of(view.verticals,body)*mm.quat_axis_angle({0,1,0},move.look_yaw)*mm.quat_axis_angle({1,0,0},move.look_pitch)
        toward:=mm.quat_rotate(conj(parent_rotation(aims,view.locals,view.parents,e)),mm.quat_forward(look))
        wanted:f32
        switch aim.axis {
        case .Yaw:   wanted=mm.yaw_of_direction(toward)
        case .Pitch: wanted=math.atan2(toward.y,linalg.length(toward.xz))
        }
        limited:=aim.min!=0 || aim.max!=0
        step:=mm.angle_delta(aim.angle,wanted)
        if limited {
            wanted=clamp(wanted,min(aim.min,aim.max),max(aim.min,aim.max))
            step=wanted-aim.angle
        }
        if aim.speed>0 {step=clamp(step,-aim.speed*dt,aim.speed*dt)}
        angle:=aim.angle+step
        angle=limited?clamp(angle,min(aim.min,aim.max),max(aim.min,aim.max)):mm.angle_wrap(angle)
        if angle!=aim.angle {core.edit_at(aims,row).angle=angle}
    }
}

// Each Aim shows where it is turned: the rotation of its Transform.
@(step="late")
vehicles_show :: proc(aims:^core.Table(Aim,.Read),transforms:^core.Table(core.Transform)) {
    for row in 0..<core.count(aims) {
        e:=core.entity_at(aims,row)
        rotation:=aim_rotation(core.at(aims,row))
        if local,ok:=core.get(transforms,e);ok && local.rotation!=rotation {
            if written:=core.free(transforms,e);written!=nil {written.rotation=rotation}
        }
    }
}
