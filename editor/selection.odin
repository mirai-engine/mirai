package editor

import "mirai:core"
import "mirai:editor/history"

selection_click_target :: proc(s:^Session,w:core.World_Ref,e:core.Entity,individual:bool) -> core.Entity {
    if e==core.NONE || individual || s.document==nil {return e}
    link,linked:=prefab_link_of(w,e)
    if !linked || link.root {return e}
    for selected in s.selection.entities {
        selected_link,selected_linked:=prefab_link_of(w,selected)
        if selected_linked && selected_link.instance==link.instance {return e}
    }
    return link.instance
}

// The copied roots that the World has: Copy keeps their ids, not the
// entities (Copy), so Paste finds them in the scene as it is then,
// after undo, redo or a reload.
copied_entities :: proc(s:^Session,w:core.World_Ref,allocator:=context.temp_allocator) -> []core.Entity {
    found:=make([dynamic]core.Entity,allocator)
    for id in s.copied {
        if e:=core.entity_of(core.world_entities(w),id);e!=core.NONE {append(&found,e)}
    }
    return found[:]
}
