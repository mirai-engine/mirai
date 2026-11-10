package editor

import "mirai:core"
import "mirai:asset"

// The selected entities of the World shown. Handles stay valid across Play
// and Stop: the World of a Play is a copy that keeps them.
@(storage)
Selection :: struct {
    entities:[dynamic]core.Entity, // in the order they were selected: the active one is the last
    serial:u64,                    // advances with every change
}

selection_active :: proc "contextless" (s:^Selection) -> core.Entity {
    if len(s.entities)==0 {return core.NONE}
    return s.entities[len(s.entities)-1]
}

selection_has :: proc "contextless" (s:^Selection,e:core.Entity) -> bool {
    for selected in s.entities {
        if selected==e {return true}
    }
    return false
}

// Selects entities; with add they join what is selected. The last becomes the active one.
selection_set :: proc(s:^Selection,entities:[]core.Entity,add:=false) {
    if !add {clear(&s.entities)}
    for e in entities {
        if e==core.NONE {continue}
        selection_drop(s,e)
        append(&s.entities,e)
    }
    s.serial+=1
}

selection_add :: proc(s:^Selection,e:core.Entity) {selection_set(s,{e},true)}

selection_toggle :: proc(s:^Selection,e:core.Entity) {
    if selection_has(s,e) {
        selection_drop(s,e)
        s.serial+=1
        return
    }
    selection_add(s,e)
}

selection_clear :: proc(s:^Selection) {
    if len(s.entities)==0 {return}
    clear(&s.entities)
    s.serial+=1
}

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

// Forgets what is no longer alive in a World.
selection_prune :: proc(s:^Selection,w:core.World_Ref) {
    es:=core.world_entities(w)
    kept:=0
    for e in s.entities {
        if core.alive(es,e) {s.entities[kept]=e;kept+=1}
    }
    if kept!=len(s.entities) {
        resize(&s.entities,kept)
        s.serial+=1
    }
}

// The selected entities none of whose ancestors is selected: what moves,
// is duplicated or deleted as a whole.
selection_roots :: proc(s:^Selection,w:core.World_Ref,allocator:=context.temp_allocator) -> []core.Entity {
    roots:=make([dynamic]core.Entity,allocator)
    parents:=core.world_table_of(w,core.Parent)
    es:=core.world_entities(w)
    for e in s.entities {
        if !core.alive(es,e) {continue}
        covered:=false
        if parents!=nil {
            at:=e
            for _ in 0..<256 {
                parent,ok:=core.get(core.read(parents),at)
                if !ok || parent.entity==core.NONE {break}
                at=parent.entity
                if selection_has(s,at) {covered=true;break}
            }
        }
        if !covered {append(&roots,e)}
    }
    return roots[:]
}

// Copy keeps the ids of the selected roots, not the entities: Paste finds
// them in the scene as it is then, after undo, redo or a reload.
selection_copy :: proc(s:^Session,w:core.World_Ref) {
    clear(&s.copied)
    for e in selection_roots(s.selection,w) {
        if id:=api_entity_id(w,e);id!=0 {append(&s.copied,id)}
    }
}

// The copied roots that the World has.
copied_entities :: proc(s:^Session,w:core.World_Ref,allocator:=context.temp_allocator) -> []core.Entity {
    found:=make([dynamic]core.Entity,allocator)
    for id in s.copied {
        if e:=core.entity_of(core.world_entities(w),id);e!=core.NONE {append(&found,e)}
    }
    return found[:]
}

@(private)
selection_drop :: proc(s:^Selection,e:core.Entity) {
    for selected,i in s.entities {
        if selected==e {
            ordered_remove(&s.entities,i)
            return
        }
    }
}

@(private)
selection_restore :: proc(s:^Selection,w:core.World_Ref,entities:[]core.Entity) {
    clear(&s.entities)
    append(&s.entities,..entities)
    s.serial+=1
    selection_prune(s,w)
}
