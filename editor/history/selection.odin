package history

import "mirai:core"

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

@(private)
selection_drop :: proc(s:^Selection,e:core.Entity) {
    for selected,i in s.entities {
        if selected==e {
            ordered_remove(&s.entities,i)
            return
        }
    }
}

selection_restore :: proc(s:^Selection,w:core.World_Ref,entities:[]core.Entity) {
    clear(&s.entities)
    append(&s.entities,..entities)
    s.serial+=1
    selection_prune(s,w)
}
