package anim

import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

Modifier_Request :: struct {
    rig:core.Entity,
    name,effector:u64,
    target:Spatial_Target,
    position:mm.Vec3,
    weight,fade:f32,
    kind:Modifier_Kind,
    enabled:bool,
    goal:bool, // changes the target, spring force or ground contact along with influence
}

modifier :: proc(requests:^Animation_Requests,request:Modifier_Request,name:string="",effector:string="") {
    if requests==nil {return}
    request:=request
    if name!="" {request.name=base.name_hash(name)}
    if effector!="" {request.effector=base.name_hash(effector)}
    if request.rig==core.NONE || request.name==0 || request.kind>max(Modifier_Kind) ||
        !profile_weight(request.weight) || !finite(request.fade) || request.fade<0 ||
        request.goal && (!profile_vector(request.position) ||
        request.kind in MODIFIER_TARGETED && !spatial_target_valid(request.target)) {
        core.refuse(&requests.modifiers)
        return
    }
    core.offer(&requests.modifiers,request)
}

Modifier_Control_State :: struct {
    name:u64,
    began:f64,
    base_weight,start,target,duration:f32,
    first_override:u16,
    base_enabled,enabled,turning:bool,
}

modifier_count :: proc(pose:Pose_Profile,kind:Modifier_Kind) -> int {
    switch kind {
    case .IK: return len(pose.ik)
    case .Look: return len(pose.look)
    case .Grounding: return 1 if len(pose.grounding.legs)>0 else 0
    case .Limit: return len(pose.limits)
    case .Chain_IK: return len(pose.chain_ik)
    case .Twist: return len(pose.twist)
    case .Spring: return len(pose.springs)
    case .Multi_IK: return len(pose.multi_ik)
    case .Chain_Retarget: return len(pose.retarget_chains)
    case .Spline_IK: return len(pose.spline_ik)
    case .Corrective: return len(pose.correctives)
    case .Follow: return len(pose.follow)
    }
    return 0
}

modifier_definition :: proc(pose:^Pose_Profile,kind:Modifier_Kind,slot:int) -> (name:string,weight:f32,enabled:bool) {
    if slot<0 || slot>=modifier_count(pose^,kind) {return}
    info :: proc(value:^$T) -> (string,f32,bool) {
        return modifier_operation_name(value),value.weight,value.enabled
    }
    switch kind {
    case .IK: return info(&pose.ik[slot])
    case .Look: return info(&pose.look[slot])
    case .Grounding: return info(&pose.grounding)
    case .Limit: return info(&pose.limits[slot])
    case .Chain_IK: return info(&pose.chain_ik[slot])
    case .Twist: return info(&pose.twist[slot])
    case .Spring: return info(&pose.springs[slot])
    case .Multi_IK: return info(&pose.multi_ik[slot])
    case .Chain_Retarget: return info(&pose.retarget_chains[slot])
    case .Spline_IK: return info(&pose.spline_ik[slot])
    case .Corrective: return info(&pose.correctives[slot])
    case .Follow: return info(&pose.follow[slot])
    }
    return
}

@(private)
modifier_states :: proc(rig:^Modifier_Rig,kind:Modifier_Kind) -> []Modifier_Control_State {
    return rig.controls[rig.first[int(kind)]:rig.first[int(kind)+1]]
}

@(private)
modifier_control_slot :: proc(rig:^Modifier_Rig,kind:Modifier_Kind,name:u64) -> int {
    if rig==nil || kind>max(Modifier_Kind) {return -1}
    found:=-1
    for &state,slot in modifier_states(rig,kind) {
        if state.name!=name {continue}
        if found>=0 {return -1}
        found=slot
    }
    return found
}

modifier_influence :: proc(runtime:^Modifier_Runtime,entity:core.Entity,kind:Modifier_Kind,name:u64) -> (weight:f32,enabled:bool,alpha,target,remaining:f32,requested:bool,found:bool) {
    rig:=modifier_rig(runtime,entity)
    slot:=modifier_control_slot(rig,kind,name)
    if slot<0 {return}
    control:=&modifier_states(rig,kind)[slot]
    weight,enabled=modifier_weight(control,runtime.time)
    return weight,enabled,modifier_alpha(control,runtime.time),control.target,
        max(0,control.duration-f32(runtime.time-control.began)),control.enabled,true
}

@(private)
modifier_effector_slot :: proc(pose:Pose_Profile,kind:Modifier_Kind,slot:int,name:u64) -> int {
    #partial switch kind {
    case .Multi_IK:
        for &effector,i in pose.multi_ik[slot].effectors {
            if base.name_hash(base.text_get(effector.name[:]))==name {return i}
        }
    case .Spline_IK:
        for label,i in SPLINE_CONTROLS {if base.name_hash(label)==name {return i}}
    case: return 0
    }
    return -1
}

@(private)
modifier_controls_prepare :: proc(next,old:^Modifier_Rig,pose:Pose_Profile) -> bool {
    pose:=pose
    count:=0
    for kind in Modifier_Kind {
        next.first[int(kind)]=u16(count)
        count+=modifier_count(pose,kind)
    }
    next.first[len(Modifier_Kind)]=u16(count)
    if resize(&next.controls,count)!=nil {return false}
    capacity:=0
    for kind in Modifier_Kind {
        for &control,slot in modifier_states(next,kind) {
            name,weight,enabled:=modifier_definition(&pose,kind,slot)
            control={name=base.name_hash(name),base_weight=weight,base_enabled=enabled,
                first_override=u16(capacity),start=1,target=1,enabled=true}
            #partial switch kind {
            case .Multi_IK: capacity+=len(pose.multi_ik[slot].effectors)
            case .Spline_IK: capacity+=len(SPLINE_CONTROLS)
            case: capacity+=1
            }
            if previous:=modifier_control_slot(old,kind,control.name);previous>=0 {
                prior:=modifier_states(old,kind)[previous]
                control.start,control.target,control.enabled=prior.start,prior.target,prior.enabled
                control.began,control.duration,control.turning=prior.began,prior.duration,prior.turning
                if kind==.Look {next.look_states[slot].from=old.look_states[previous].from}
            }
        }
    }
    if resize(&next.overrides,capacity)!=nil {return false}
    for &request in old.overrides {
        if request.name==0 {continue}
        slot:=modifier_control_slot(next,request.kind,request.name)
        if slot<0 {continue}
        effector:=modifier_effector_slot(pose,request.kind,slot,request.effector)
        if effector<0 {continue}
        control:=&modifier_states(next,request.kind)[slot]
        next.overrides[int(control.first_override)+effector]=request
        prior:=modifier_states(old,request.kind)[modifier_control_slot(old,request.kind,request.name)]
        control.base_weight,control.base_enabled=prior.base_weight,prior.base_enabled
    }
    return true
}

@(private)
modifier_override :: proc(rig:^Modifier_Rig,kind:Modifier_Kind,slot:int,effector:int=0) -> ^Modifier_Request {
    control:=&modifier_states(rig,kind)[slot]
    request:=&rig.overrides[int(control.first_override)+effector]
    return request if request.name!=0 else nil
}

@(private)
modifier_target :: proc(rig:^Modifier_Rig,kind:Modifier_Kind,slot:int,definition:^Spatial_Definition,effector:int=0) -> Spatial_Target {
    if entry:=modifier_override(rig,kind,slot,effector);entry!=nil {return entry.target}
    return spatial_compile(definition)
}

@(private)
modifier_fade :: proc(control:^Modifier_Control_State,now:f64) -> f32 {
    if control.duration<=0 {return 1}
    alpha:=min(f32(now-control.began)/control.duration,1)
    return alpha*alpha*(3-2*alpha)
}

@(private)
modifier_alpha :: proc(control:^Modifier_Control_State,now:f64) -> f32 {
    return mm.lerp(control.start,control.target,modifier_fade(control,now))
}

@(private)
modifier_weight :: proc(control:^Modifier_Control_State,now:f64) -> (weight:f32,enabled:bool) {
    alpha:=modifier_alpha(control,now)
    return control.base_weight*alpha,control.base_enabled && (control.enabled || alpha>0)
}

modifier_take :: proc(runtime:^Modifier_Runtime,characters:^Character_Assets,requests:^Animation_Requests,problems:^core.Problems,dt:f32) {
    if runtime==nil || requests==nil {return}
    defer if finite(dt) && dt>0 {runtime.time+=f64(dt)}
    for request in core.take(&requests.modifiers) {
        request:=request
        rig:=modifier_rig(runtime,request.rig)
        slot:=modifier_control_slot(rig,request.kind,request.name)
        error:=Modifier_Request_Error.None
        effector:=0
        if slot<0 {error=.Missing_Operation}
        else if request.goal {
            effector=modifier_effector_slot(modifier_pose(rig,characters),request.kind,slot,request.effector)
            if effector<0 {error=.Missing_Effector}
        }
        if error!=.None {
            modifier_request_rejected(runtime,request.rig,error)
            modifier_name_problem(problems,request.rig,request.kind,request.name,request.effector,error)
            continue
        }
        control:=&modifier_states(rig,request.kind)[slot]
        start:=modifier_alpha(control,runtime.time)
        target:=request.weight if request.enabled else 0
        turning:=false
        if request.goal {
            entry:=modifier_override(rig,request.kind,slot,effector)
            if entry!=nil {
                if !request.enabled && request.fade>0 {request.target=entry.target}
                if entry^==request {continue}
            }
            if request.kind==.Look && request.fade>0 && request.enabled && start>0 && control.base_enabled {
                pose:=modifier_pose(rig,characters)
                previous:=modifier_target(rig,.Look,slot,&pose.look[slot].target)
                if previous!=request.target {rig.look_states[slot].from=previous;turning=true}
            }
            rig.overrides[int(control.first_override)+effector]=request
            if request.fade==0 || request.kind==.Grounding {
                control.base_enabled=request.enabled
                if request.kind!=.Grounding {control.base_weight=request.weight}
                continue
            }
            start*=control.base_weight if control.base_enabled else 0
            control.base_weight,control.base_enabled=1,true
        } else if control.target==target && control.enabled==request.enabled {continue}
        control.start,control.target,control.enabled=start,target,request.enabled
        control.began,control.duration,control.turning=runtime.time,request.fade,turning
    }
}

animation_rig_diagnostic :: proc(runtime:^Modifier_Runtime,entity:core.Entity,kind:Modifier_Kind,name:u64) -> (Rig_Diagnostic,bool) {
    rig:=modifier_rig(runtime,entity)
    index:=modifier_control_slot(rig,kind,name)
    if index<0 {return {},false}
    read :: proc(binding:^$T) -> (Rig_Diagnostic,bool) {
        return binding.diagnostic,binding.diagnostic.rig!=core.NONE
    }
    #partial switch kind {
    case .IK: return read(&rig.ik_states[index])
    case .Look: return read(&rig.look_states[index])
    case .Chain_IK: return read(&rig.chain_states[index])
    case .Twist: return read(&rig.twist_states[index])
    case .Spring: return read(&rig.spring_states[index])
    case .Multi_IK: return read(&rig.multi_states[index])
    case .Chain_Retarget: return read(&rig.retarget_chain_states[index])
    case .Spline_IK: return read(&rig.spline_states[index])
    case .Corrective: return read(&rig.corrective_states[index])
    case .Follow: return read(&rig.follow_states[index])
    }
    return {},false
}
