package core

import "base:intrinsics"

// What the settle, the copy and the swap of a World look for in its
// World_Info: world_info_index finds it once, and a World_Info made by hand
// has it found each time.
Settle_Info :: struct {
    disabled,parent,id:int, // their tables, by index; -1 without one
    hierarchy,world_id:int, // their storages, by index; -1 without one
    editor:bool,            // the editor holds tables
    found:bool,
}

settle_info :: proc "contextless" (info:^World_Info) -> (s:Settle_Info) {
    s={disabled=-1,parent=-1,id=-1,hierarchy=-1,world_id=-1,found=true}
    for &t,i in info.tables {
        switch t.place {
        case .World:
            switch t.type {
            case Disabled: s.disabled=i
            case Parent:   s.parent=i
            case Id:       s.id=i
            }
        case .Editor: s.editor=true
        case .Shared:
        }
    }
    for &storage,i in info.storages {
        if storage.place!=.World || storage.by_world {continue}
        switch storage.type {
        case Hierarchy: s.hierarchy=i
        case World_Id:  s.world_id=i
        }
    }
    return
}

settles :: #force_inline proc "contextless" (info:^World_Info) -> Settle_Info {
    return info.settles.found?info.settles:settle_info(info)
}

// Applies what the functions and the editor added, removed, turned and
// destroyed in a World: Disabled and Parent first, then the Hierarchy and
// what is off, which follow them, then the other tables, which move the rows
// of the entities turned, and last the indices of the entities destroyed are
// free again. It comes only to the tables that say they have changes pending
// (Entities.pending) and to those that hold an entity destroyed or turned;
// in a World made by hand, and in the editor, to every table. Returns how
// many tables it came to.
settle :: proc(info:^World_Info,world,editor:rawptr) -> (settled:int) {
    es:=cast(^Entities)(uintptr(world)+info.entities)
    s:=settles(info)
    marks:=es.pending[:]
    linked:=len(marks)>0 && len(marks)>=len(info.tables)
    if linked {settle_mark(info,world,marks,es.doomed[:],false)}
    for at in ([2]int{s.disabled,s.parent}) {
        if at<0 || linked && !marks[at] {continue}
        settle_table(info,world,at,es,marks)
        settled+=1
    }
    if s.disabled>=0 && s.parent>=0 && s.hierarchy>=0 {
        h:=cast(^Hierarchy)(uintptr(world)+info.storages[s.hierarchy].offset)
        seen,version,rows,cut:=h.seen,h.version,len(h.parent),len(h.cut)
        _=hierarchy_settle(h,cast(^Table(Parent))(uintptr(world)+info.tables[s.parent].offset),es)
        // The settle is the writer of the Hierarchy: a copy of what changed takes it when it moved.
        if info.revisions!=0 && (h.seen!=seen || h.version!=version || len(h.parent)!=rows || len(h.cut)!=cut) {
            ([^]u64)(uintptr(world)+info.revisions)[s.hierarchy]+=1
        }
        _=entities_activity(es,cast(^Table(Disabled))(uintptr(world)+info.tables[s.disabled].offset),ref(h))
    }
    if linked {
        settle_mark(info,world,marks,es.turned[:],true)
        for word in 0..<len(marks)/8 {
            if intrinsics.unaligned_load(cast(^u64)&marks[word*8])==0 {continue}
            for at in word*8..<min(word*8+8,len(info.tables)) {
                if !marks[at] {continue}
                settle_table(info,world,at,es,marks)
                settled+=1
            }
        }
    } else {
        for &t,at in info.tables {
            if t.place!=.World || at==s.disabled || at==s.parent {continue}
            raw_settle(cast(^Raw_Table)(uintptr(world)+t.offset),t.info.size,t.info.align,es)
            settled+=1
        }
    }
    if s.editor && editor!=nil {
        for &t in info.tables {
            if t.place!=.Editor {continue}
            raw_settle(cast(^Raw_Table)(uintptr(editor)+t.offset),t.info.size,t.info.align,es)
            settled+=1
        }
    }
    if s.id>=0 {ids_follow(es,cast(^Table(Id))(uintptr(world)+info.tables[s.id].offset))}
    entities_settle(es)
    return
}

@(private="file")
settle_table :: proc(info:^World_Info,world:rawptr,at:int,es:^Entities,marks:[]bool) {
    t:=&info.tables[at]
    table:=cast(^Raw_Table)(uintptr(world)+t.offset)
    raw_settle(table,t.info.size,t.info.align,es)
    if at<len(marks) {marks[at]=len(table.pending)>0}
}

// Marks the tables of a World that hold a row of one of the entities, which
// were destroyed or turned: each entity is looked for in the tables not yet
// marked. The base of an entity stays on when it is turned.
@(private="file")
settle_mark :: proc "contextless" (info:^World_Info,world:rawptr,marks:[]bool,entities:[]Entity,turned:bool) {
    for e in entities {
        i:=entity_index(e)
        for &t,at in info.tables {
            if marks[at] || t.place!=.World {continue}
            table:=cast(^Raw_Table)(uintptr(world)+t.offset)
            if rows_at(table,i)!=0 && !(turned && table.base) {marks[at]=true}
        }
    }
}
