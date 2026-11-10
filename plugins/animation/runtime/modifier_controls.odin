package anim

import "mirai:core"
import "mirai:std/base"

Modifier_Control :: struct {
    rig:core.Entity,
    kind:Modifier_Kind,
    slot:u16,
    name:[256]u8, // the operation by name instead of slot: found again when the .character is read again
    weight:f32,
    enabled:bool,
    fade:f32,
}

Modifier_Control_State :: struct {
    rig:core.Entity,
    kind:Modifier_Kind,
    slot:u16,
    row:int,
    fade_row:u32,
    base_weight,weight,start,target,elapsed,duration:f32,
    base_enabled,enabled:bool,
}

modifier_control :: proc(requests:^Animation_Requests,control:Modifier_Control) {
    if requests==nil {return}
    control:=control
    if !blend_text_valid(control.name[:],true) || control.rig==core.NONE || control.kind>max(Modifier_Kind) || control.slot>=POSE_CONSTRAINTS || control.kind==.Grounding && control.slot!=0 || !profile_weight(control.weight) || !finite(control.fade) || control.fade<0 {
        core.refuse(&requests.controls)
        return
    }
    core.offer(&requests.controls,control)
}

modifier_control_state :: proc(runtime:^Modifier_Runtime,rig:core.Entity,kind:Modifier_Kind,slot:u16) -> ^Modifier_Control_State {
    if runtime==nil {return nil}
    row:=-1
    #partial switch kind {
    case .IK: row=rig_slot_row(&runtime.ik,rig,slot)
    case .Look: row=rig_slot_row(&runtime.look,rig,slot)
    case .Grounding: row=rig_slot_row(&runtime.grounding,rig,slot)
    case .Limit: row=rig_slot_row(&runtime.limits,rig,slot)
    case .Chain_IK: row=rig_slot_row(&runtime.chain_ik,rig,slot)
    case .Twist: row=rig_slot_row(&runtime.twist,rig,slot)
    case .Spring: row=rig_slot_row(&runtime.springs,rig,slot)
    case .Multi_IK: row=rig_slot_row(&runtime.multi_ik,rig,slot)
    case .Chain_Retarget: row=rig_slot_row(&runtime.retarget_chains,rig,slot)
    case .Spline_IK: row=rig_slot_row(&runtime.spline_ik,rig,slot)
    case .Corrective: row=rig_slot_row(&runtime.correctives,rig,slot)
    case .Follow: row=rig_slot_row(&runtime.follow,rig,slot)
    }
    if row<0 {return nil}
    counts:=[Modifier_Kind]int{.IK=len(runtime.ik.values),.Look=len(runtime.look.values),.Grounding=len(runtime.grounding.values),.Limit=len(runtime.limits.values),.Chain_IK=len(runtime.chain_ik.values),.Twist=len(runtime.twist.values),.Spring=len(runtime.springs.values),.Multi_IK=len(runtime.multi_ik.values),.Chain_Retarget=len(runtime.retarget_chains.values),.Spline_IK=len(runtime.spline_ik.values),.Corrective=len(runtime.correctives.values),.Follow=len(runtime.follow.values)}
    for previous in Modifier_Kind {if previous>=kind {break};row+=counts[previous]}
    if row>=len(runtime.controls) {return nil}
    state:=&runtime.controls[row]
    return state if state.rig==rig && state.kind==kind && state.slot==slot else nil
}

@(private)
modifier_controls_prepare :: proc(next,previous:^Modifier_Runtime) -> bool {
    prepare :: proc(next,previous:^Modifier_Runtime,table:^core.Table($T),kind:Modifier_Kind) -> bool {
        slot:u16
        rig:=core.NONE
        for &value,row in table.values {
            if rig!=table.entities[row] {rig=table.entities[row];slot=0}
            state:=Modifier_Control_State{rig=rig,kind=kind,slot=slot,row=row,base_weight=value.weight,base_enabled=value.enabled,weight=1,start=1,target=1,enabled=true}
            if found:=modifier_control_state(previous,rig,kind,slot);found!=nil && modifier_same_operation(previous,next,rig,kind,slot) {
                state.weight,state.start,state.target,state.elapsed,state.duration,state.enabled=found.weight,found.start,found.target,found.elapsed,found.duration,found.enabled
            }
            if append(&next.controls,state)!=1 {return false}
            modifier_control_apply(next,&state)
            slot+=1
        }
        return true
    }
    if !prepare(next,previous,&next.ik,.IK) || !prepare(next,previous,&next.look,.Look) || !prepare(next,previous,&next.grounding,.Grounding) || !prepare(next,previous,&next.limits,.Limit) || !prepare(next,previous,&next.chain_ik,.Chain_IK) || !prepare(next,previous,&next.twist,.Twist) || !prepare(next,previous,&next.springs,.Spring) || !prepare(next,previous,&next.multi_ik,.Multi_IK) || !prepare(next,previous,&next.retarget_chains,.Chain_Retarget) || !prepare(next,previous,&next.spline_ik,.Spline_IK) || !prepare(next,previous,&next.correctives,.Corrective) || !prepare(next,previous,&next.follow,.Follow) || reserve(&next.fades,len(next.controls))!=nil {return false}
    for &state,row in next.controls {
        if state.elapsed<state.duration {append(&next.fades,u32(row));state.fade_row=u32(len(next.fades))}
    }
    return true
}

@(private)
modifier_control_apply :: proc(runtime:^Modifier_Runtime,state:^Modifier_Control_State) {
    weight:=state.base_weight*state.weight
    enabled:=state.base_enabled && (state.enabled || state.weight>0)
    apply :: proc(table:^core.Table($T),row:int,weight:f32,enabled:bool) {
        if row<0 || row>=len(table.values) {return}
        value:=&table.values[row]
        if value.weight==weight && value.enabled==enabled {return}
        out:=core.edit_at(table,row)
        out.weight,out.enabled=weight,enabled
    }
    switch state.kind {
    case .IK: apply(&runtime.ik,state.row,weight,enabled)
    case .Look: apply(&runtime.look,state.row,weight,enabled)
    case .Grounding: apply(&runtime.grounding,state.row,weight,enabled)
    case .Limit: apply(&runtime.limits,state.row,weight,enabled)
    case .Chain_IK: apply(&runtime.chain_ik,state.row,weight,enabled)
    case .Twist: apply(&runtime.twist,state.row,weight,enabled)
    case .Spring: apply(&runtime.springs,state.row,weight,enabled)
    case .Multi_IK: apply(&runtime.multi_ik,state.row,weight,enabled)
    case .Chain_Retarget: apply(&runtime.retarget_chains,state.row,weight,enabled)
    case .Spline_IK: apply(&runtime.spline_ik,state.row,weight,enabled)
    case .Corrective: apply(&runtime.correctives,state.row,weight,enabled)
    case .Follow: apply(&runtime.follow,state.row,weight,enabled)
    }
}

@(private)
modifier_fade_remove :: proc(runtime:^Modifier_Runtime,state:^Modifier_Control_State) {
    if state.fade_row==0 {return}
    row:=int(state.fade_row)-1
    moved:=runtime.fades[len(runtime.fades)-1]
    unordered_remove(&runtime.fades,row)
    if row<len(runtime.fades) {runtime.controls[moved].fade_row=u32(row+1)}
    state.fade_row=0
}

@(private)
modifier_controls_take :: proc(runtime:^Modifier_Runtime,requests:^Animation_Requests,problems:^core.Problems,dt:f32) {
    if requests==nil {return}
    for control in core.take(&requests.controls) {
        control:=control
        if control.name[0]!=0 {
            slot,found:=modifier_named_slot(runtime,control.rig,control.kind,base.text_get(control.name[:]))
            if !found {
                modifier_request_rejected(runtime,control.rig,.Missing_Operation)
                modifier_name_problem(problems,control.rig,control.kind,control.name[:],nil,.Missing_Operation)
                continue
            }
            control.slot=slot
        }
        state:=modifier_control_state(runtime,control.rig,control.kind,control.slot)
        if state==nil {
            core.report(problems,control.rig,"animation.modifier_slot","a control of %v %d was refused: the .character of this rig has no such operation; name one it has (animation.inspect lists them)",control.kind,control.slot)
            continue
        }
        target:=control.weight if control.enabled else f32(0)
        if state.target==target && state.enabled==control.enabled {continue}
        if control.fade>0 && state.weight!=target && state.fade_row==0 {
            row:=int((uintptr(state)-uintptr(raw_data(runtime.controls)))/size_of(Modifier_Control_State))
            if append(&runtime.fades,u32(row))!=1 {memory_problem(problems,control.rig,"the fade of a control of its .character");continue}
            state.fade_row=u32(len(runtime.fades))
        }
        state.start,state.target,state.enabled,state.duration,state.elapsed=state.weight,target,control.enabled,control.fade,0
        if control.fade==0 || state.start==target {state.weight=target;state.elapsed=state.duration;modifier_fade_remove(runtime,state)}
        modifier_control_apply(runtime,state)
    }
    if !finite(dt) || dt<=0 {return}
    #reverse for row in runtime.fades {
        state:=&runtime.controls[row]
        state.elapsed=min(state.duration,state.elapsed+dt)
        alpha:=state.elapsed/state.duration
        alpha=alpha*alpha*(3-2*alpha)
        state.weight=state.target if state.elapsed>=state.duration else state.start+(state.target-state.start)*alpha
        modifier_control_apply(runtime,state)
        if state.elapsed>=state.duration {modifier_fade_remove(runtime,state)}
    }
}
