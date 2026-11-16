package animation_editor

import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"

@(private)
preview_world_clone :: proc(s:^editor.Session,call:^api.Call,source:core.World_Ref) -> rawptr {
    context.allocator=s.app.allocator
    clone:=host.app_world_create(s.app)
    if clone==nil {authoring_failure(call,"preview","Out_Of_Memory","memory for an isolated animation world","allocation failed","The animation world could not be allocated",api.SERVER_ERROR);return nil}
    if !core.world_copy(s.info,clone,source.data) {host.app_world_free(s.app,clone);authoring_failure(call,"preview","Out_Of_Memory","memory for a complete animation world copy","copy failed","The isolated animation world could not be copied",api.SERVER_ERROR);return nil}
    return clone
}
