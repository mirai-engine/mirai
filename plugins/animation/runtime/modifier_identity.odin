package anim

import "mirai:core"

// Why the last goal or control of a rig was refused: its operation or
// effector no longer has that name, or its target cannot be found.
Modifier_Request_Error :: enum u8 {None,Missing_Operation,Missing_Effector,Missing_Target}

// Keeps why the last goal or control of a rig was refused, for its
// diagnostic; the caller reports the problem.
@(private)
modifier_request_rejected :: proc(runtime:^Modifier_Runtime,rig:core.Entity,error:Modifier_Request_Error) {
    runtime.request_error,runtime.request_error_rig=error,rig
}

// Reports a goal or control by name that names no operation, or no effector,
// of the .character the rig plays now.
@(private)
modifier_name_problem :: proc(problems:^core.Problems,rig:core.Entity,kind:Modifier_Kind,name,effector:u64,error:Modifier_Request_Error) {
    #partial switch error {
    case .Missing_Operation:
        core.report(problems,rig,"animation.modifier_name","a goal or control for %v 0x%016x was refused: the .character of this rig has no %v with that name; name one it has (animation.inspect lists them)",kind,name,kind)
    case .Missing_Effector:
        core.report(problems,rig,"animation.modifier_effector","a goal for effector 0x%016x of %v 0x%016x was refused: it has no effector with that name; name one it has",effector,kind,name)
    }
}

modifier_request_error :: proc(runtime:^Modifier_Runtime,rig:core.Entity) -> Modifier_Request_Error {
    if runtime!=nil && runtime.request_error_rig==rig {return runtime.request_error}
    return .None
}
