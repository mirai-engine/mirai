package physics

import "mirai:core"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

Joint_Request_Kind :: enum u8 {Pose,Axes,Motor,Repair,Drive_Enabled,World_Rotation,Configure}
Joint_Request :: struct {
    entity:core.Entity,
    kind:Joint_Request_Kind,
    position:[3]f32,
    rotation,parent_rotation:mm.Quat,
    hertz,damping_ratio,max_force,max_torque:f32,
    speed:f32,
    enabled:bool,
    configuration:Joint,
}
@(storage,queue)
Joint_Requests :: struct {queue:core.Queue(Joint_Request)}

set_joint_drive :: proc(requests:^Joint_Requests,e:core.Entity,translation:[3]f32,rotation:mm.Quat,hertz:f32=5,damping_ratio:f32=1,max_force:f32=1000,max_torque:f32=1000) {
    core.push(&requests.queue,Joint_Request{entity=e,kind=.Pose,position=translation,rotation=rotation,hertz=hertz,damping_ratio=damping_ratio,max_force=max_force,max_torque=max_torque})
}
set_joint_world_rotation :: proc(requests:^Joint_Requests,e:core.Entity,rotation,parent_rotation:mm.Quat,hertz:f32=5,damping_ratio:f32=1,max_torque:f32=1000) {
    core.push(&requests.queue,Joint_Request{entity=e,kind=.World_Rotation,rotation=rotation,parent_rotation=parent_rotation,hertz=hertz,damping_ratio=damping_ratio,max_torque=max_torque})
}
set_joint_configuration :: proc(requests:^Joint_Requests,e:core.Entity,joint:Joint) {
    core.push(&requests.queue,Joint_Request{entity=e,kind=.Configure,configuration=joint})
}
set_joint_axes :: proc(requests:^Joint_Requests,e:core.Entity,linear,angular:[3]Joint_Axis) {
    core.push(&requests.queue,Joint_Request{entity=e,kind=.Axes,configuration={linear=linear,angular=angular}})
}
set_joint_motor :: proc(requests:^Joint_Requests,e:core.Entity,enabled:bool,speed,max_force:f32) {
    core.push(&requests.queue,Joint_Request{entity=e,kind=.Motor,enabled=enabled,speed=speed,max_force=max_force})
}
set_joint_drive_enabled :: proc(requests:^Joint_Requests,e:core.Entity,enabled:bool) {
    core.push(&requests.queue,Joint_Request{entity=e,kind=.Drive_Enabled,enabled=enabled})
}
repair_joint :: proc(requests:^Joint_Requests,e:core.Entity) {
    core.push(&requests.queue,Joint_Request{entity=e,kind=.Repair})
}

@(private)
joint_requests_apply :: proc(s:^Sync,joints:^core.Table(Joint),states:^core.Table(Joint_State),requests:^Joint_Requests) {
    if requests==nil {return}
    for request in core.take(&requests.queue) {
        row:=core.row_of(joints,request.entity)
        if row<0 {
            core.report(s.problems,request.entity,"physics.joint_request","a %v request of Joint_Requests did nothing: this entity has no Joint; add one, or send it to an entity that has one",request.kind)
            continue
        }
        if request.kind==.Repair {
            if state,found:=joint_state_read(states,request.entity);found && state.broken {
                state.broken,state.taken=false,false
                core.add(states,request.entity,state)
                if s.playing {joint_reconcile(s,states,request.entity,joints.values[row])}
            }
            continue
        }
        next:=joints.values[row]
        error:Joint_Error
        switch request.kind {
        case .Pose: error=joint_drive_pose(&next,request.position,request.rotation,request.hertz,request.damping_ratio,request.max_force,request.max_torque)
        case .Configure: next=request.configuration
        case .World_Rotation:
            child,parent:=request.rotation,request.parent_rotation
            for q in ([2]mm.Quat{child,parent}) {
                for value in ([4]f32{q.x,q.y,q.z,q.w}) {if !(abs(value)<=max(f32)) {error=.Invalid_Value}}
            }
            if error==.None {error=joint_drive_pose(&next,{},1,request.hertz,request.damping_ratio,0,request.max_torque)}
            if error==.None && !s.playing {error=.Invalid_Bodies}
            if error==.None {
                if link:=core.entity_map_get(&s.state.joints,request.entity);link==nil {error=.Invalid_Bodies} else {
                    frame_a,frame_b,valid:=sim.joint_local_frames(&s.state.world,link.joint)
                    if !valid {error=.Invalid_Bodies} else {
                        target:=mm.quat_inverse(joint_quat(parent)*frame_a.q)*joint_quat(child)*frame_b.q
                        error=joint_drive_pose(&next,{},target,request.hertz,request.damping_ratio,0,request.max_torque)
                    }
                }
            }
        case .Axes: next.linear,next.angular=request.configuration.linear,request.configuration.angular
        case .Motor: next.motor,next.motor_speed,next.max_motor=request.enabled,request.speed,request.max_force
        case .Drive_Enabled:
            for &axis in next.linear {
                if axis.drive=={} {continue}
                if request.enabled {axis.drive-={.Disabled}} else {axis.drive+={.Disabled}}
            }
            for &axis in next.angular {
                if axis.drive=={} {continue}
                if request.enabled {axis.drive-={.Disabled}} else {axis.drive+={.Disabled}}
            }
        case .Repair:
        }
        if error==.None {error=joint_configuration_error(next)}
        if error==.None && request.kind==.Configure {
            body:=joint_body(s,request.entity)
            target:=next.target==core.NONE?sim.Body_Handle{}:joint_body(s,next.target)
            if body=={} || next.target!=core.NONE && (target=={} || body==target) {error=.Invalid_Bodies}
        }
        if error!=.None {
            joint_request_problem(s.problems,request,error)
            continue
        }
        if next!=joints.values[row] {
            core.edit_at(joints,row)^=next
            if s.playing {joint_reconcile(s,states,request.entity,next)}
        }
    }
}

@(private)
joint_request_problem :: proc(problems:^core.Problems,request:Joint_Request,error:Joint_Error) {
    why,fix:string
    switch error {
    case .None:
    case .Invalid_Value:      why,fix="a value is not finite or out of range","send finite values, and positive hertz, damping, forces and torques"
    case .Unsupported_Option: why,fix="the kind of the Joint does not take that option","use a Six_Dof Joint for axes and drives, or leave the option off"
    case .Invalid_Axis:       why,fix="an axis is not valid: a drive on a locked axis, or a lower limit above the upper one","fix the axes"
    case .Invalid_Bodies:     why,fix="the Joint has no two different bodies to join, or is not made yet","give the entity and Joint.target bodies of their own, and ask for World_Rotation while the world plays"
    case .Capacity:           why,fix="the simulation has no room for the Joint","raise Physics_Settings.joints"
    }
    core.report(problems,request.entity,"physics.joint_request","a %v request of Joint_Requests was refused and the Joint was left as it was: %s; %s",request.kind,why,fix)
}
