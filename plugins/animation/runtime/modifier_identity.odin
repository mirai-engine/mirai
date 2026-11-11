package anim

import "mirai:core"
import "mirai:std/base"

// Why the last goal or control of a rig was refused: its operation or
// effector no longer has that name, or its target cannot be found.
Modifier_Request_Error :: enum u8 {None,Missing_Operation,Missing_Effector,Missing_Target}

@(private)
modifier_name_at :: proc(runtime:^Modifier_Runtime,rig:core.Entity,kind:Modifier_Kind,slot:u16) -> (string,bool) {
    if runtime==nil {return "",false}
    name :: proc(table:^core.Table($T),rig:core.Entity,slot:u16) -> (string,bool) {
        row:=rig_slot_row(table,rig,slot)
        if row<0 {return "",false}
        return modifier_operation_name(&table.values[row]),true
    }
    switch kind {
    case .IK: return name(&runtime.ik,rig,slot)
    case .Look: return name(&runtime.look,rig,slot)
    case .Grounding: return name(&runtime.grounding,rig,slot)
    case .Limit: return name(&runtime.limits,rig,slot)
    case .Chain_IK: return name(&runtime.chain_ik,rig,slot)
    case .Twist: return name(&runtime.twist,rig,slot)
    case .Spring: return name(&runtime.springs,rig,slot)
    case .Multi_IK: return name(&runtime.multi_ik,rig,slot)
    case .Chain_Retarget: return name(&runtime.retarget_chains,rig,slot)
    case .Spline_IK: return name(&runtime.spline_ik,rig,slot)
    case .Corrective: return name(&runtime.correctives,rig,slot)
    case .Follow: return name(&runtime.follow,rig,slot)
    }
    return "",false
}

// Whether a slot names the same operation after its .character was read again:
// what a goal or a fade kept for it still applies.
@(private)
modifier_same_operation :: proc(previous,next:^Modifier_Runtime,rig:core.Entity,kind:Modifier_Kind,slot:u16) -> bool {
    old,had:=modifier_name_at(previous,rig,kind,slot)
    current,has:=modifier_name_at(next,rig,kind,slot)
    return had && has && old==current
}

@(private)
modifier_same_goal :: proc(previous,next:^Modifier_Runtime,goal:Modifier_Goal) -> bool {
    if !modifier_same_operation(previous,next,goal.rig,goal.kind,goal.slot) {return false}
    if goal.kind!=.Multi_IK {return true}
    old_row,new_row:=rig_slot_row(&previous.multi_ik,goal.rig,goal.slot),rig_slot_row(&next.multi_ik,goal.rig,goal.slot)
    if old_row<0 || new_row<0 {return false}
    old,current:=&previous.multi_ik.values[old_row],&next.multi_ik.values[new_row]
    return goal.effector<old.effector_count && goal.effector<current.effector_count && int(goal.effector)<RIG_EFFECTORS && old.effectors[goal.effector].name==current.effectors[goal.effector].name
}

// A goal by name takes the slot and effector of that name in the .character the rig plays now.
@(private)
modifier_goal_resolve :: proc(runtime:^Modifier_Runtime,goal:^Modifier_Goal) -> Modifier_Request_Error {
    if goal.name[0]==0 {return .None}
    slot,found:=modifier_named_slot(runtime,goal.rig,goal.kind,base.text_get(goal.name[:]))
    if !found {return .Missing_Operation}
    goal.slot=slot
    if goal.kind==.Multi_IK && goal.effector_name[0]!=0 {
        effector,present:=modifier_effector_named(runtime,goal.rig,slot,base.text_get(goal.effector_name[:]))
        if !present {return .Missing_Effector}
        goal.effector=effector
    }
    return .None
}

// Keeps why the last goal or control of a rig was refused, for its
// diagnostic; the caller reports the problem.
@(private)
modifier_request_rejected :: proc(runtime:^Modifier_Runtime,rig:core.Entity,error:Modifier_Request_Error) {
    runtime.request_error,runtime.request_error_rig=error,rig
}

// Reports a goal or control by name that names no operation, or no effector,
// of the .character the rig plays now.
@(private)
modifier_name_problem :: proc(problems:^core.Problems,rig:core.Entity,kind:Modifier_Kind,name,effector:[]u8,error:Modifier_Request_Error) {
    #partial switch error {
    case .Missing_Operation:
        core.report(problems,rig,"animation.modifier_name","a goal or control for %v '%s' was refused: the .character of this rig has no %v with that name; name one it has (animation.inspect lists them)",kind,base.text_get(name),kind)
    case .Missing_Effector:
        core.report(problems,rig,"animation.modifier_effector","a goal for effector '%s' of %v '%s' was refused: it has no effector with that name; name one it has",base.text_get(effector),kind,base.text_get(name))
    }
}

modifier_request_error :: proc(runtime:^Modifier_Runtime,rig:core.Entity) -> Modifier_Request_Error {
    if runtime!=nil && runtime.request_error_rig==rig {return runtime.request_error}
    return .None
}
