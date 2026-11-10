package core

import "base:runtime"
import "core:mem"
import "core:slice"

// Makes, frees, copies, swaps and clears the structs a World_Info describes:
// a World, the Shared of its application and the Editor, each a struct of
// tables and storages at the offsets its lists give.

@(private="file")
table_of :: #force_inline proc "contextless" (data:rawptr,t:^Table_Info) -> ^Raw_Table {return cast(^Raw_Table)(uintptr(data)+t.offset)}

@(private="file")
storage_of :: #force_inline proc "contextless" (data:rawptr,s:^Storage_Info) -> rawptr {return rawptr(uintptr(data)+s.offset)}

@(private="file")
entities_of :: #force_inline proc "contextless" (info:^World_Info,world:rawptr) -> ^Entities {return cast(^Entities)(uintptr(world)+info.entities)}

@(private="file")
ids_of :: #force_inline proc "contextless" (info:^World_Info,world:rawptr,id:int) -> Read(Id) {
    return {cast(^Table(Id))table_of(world,&info.tables[id])}
}

@(private="file")
revisions_of :: #force_inline proc "contextless" (info:^World_Info,world:rawptr) -> []u64 {
    return world_revisions({world,info,.World})
}

@(private="file")
storage_free :: proc(s:^Storage_Info,value:rawptr) {
    if s.procs.free!=nil {s.procs.free(value)} else {value_free(value,s.info)}
}

// kept: into the copy a history keeps.
@(private="file")
storage_copy :: proc(s:^Storage_Info,dst,src:rawptr,kept:bool) -> bool {
    copy:=kept && s.procs.copy_kept!=nil?s.procs.copy_kept:s.procs.copy
    switch {
    case copy!=nil: return copy(dst,src)
    case s.flat:    mem.copy(dst,src,s.info.size)
    case:           return value_copy(dst,src,s.info)
    }
    return true
}

// Starts the struct of a place: its tables empty and its storages at their
// defaults. False without memory, with a struct that world_destroy frees.
world_init :: proc(info:^World_Info,place:Place,data:rawptr,allocator:runtime.Allocator) -> bool {
    context.allocator=allocator
    es:^Entities
    if place==.World {
        es=entities_of(info,data)
        if !entities_init(es,allocator) || !entities_tables(es,len(info.tables)) {return false}
    }
    for &t,at in info.tables {
        if t.place!=place {continue}
        table:=table_of(data,&t)
        raw_init(table,t.name,allocator)
        // Its place in info.tables is where settle finds what it has pending.
        if es!=nil {raw_follow(table,es,at)}
        table.base,table.single,table.locks=t.base,t.single,t.locks
    }
    for &s in info.storages {
        if s.place==place && !s.by_world && s.default!=nil {s.default(storage_of(data,&s))}
    }
    // What a storage starts as is its first value: who reads it by change takes it.
    if place==.World {revisions_moved(revisions_of(info,data))}
    return true
}

world_destroy :: proc(info:^World_Info,place:Place,data:rawptr) {
    for &t in info.tables {
        if t.place==place {raw_destroy(table_of(data,&t),t.info.size)}
    }
    for &s in info.storages {
        if s.place!=place {continue}
        if !s.by_world {
            storage_free(&s,storage_of(data,&s))
            continue
        }
        held:=cast(^By_World(u8))storage_of(data,&s)
        for entry in held.entries {
            if entry.value==nil {continue}
            storage_free(&s,entry.value)
            by_world_release(held,entry.value)
        }
        delete(held.entries)
    }
    if place==.World {entities_destroy(entities_of(info,data))}
}

// Makes the World dst a copy of src; what says copy=false stays. False
// without memory: dst is left partial, to destroy or to copy over.
world_copy :: proc(info:^World_Info,dst,src:rawptr) -> bool {return copy_marked(info,dst,src,nil)}

// The copy a history keeps: for a dst that is a copy of src, it copies again
// only the tables that changed (raw_copy_changed) and the storages whose
// revision moved since the marks, which it updates: copy_marks_count of them,
// one per table by its index in tables, then one per storage; with fewer it
// copies whole. dst is only copied back with world_copy: the storages that
// say copy_kept hold there only what that needs.
world_copy_changed :: proc(info:^World_Info,dst,src:rawptr,marks:[]Copy_Mark) -> bool {
    return copy_marked(info,dst,src,len(marks)<copy_marks_count(info)?nil:marks)
}

// The index of the entities by Id comes with them and goes on following the
// table of Id that comes with it.
@(private="file")
copy_marked :: proc(info:^World_Info,dst,src:rawptr,marks:[]Copy_Mark) -> bool {
    if dst==src {return true}
    changed:=marks!=nil
    to,from:=entities_of(info,dst),entities_of(info,src)
    context.allocator=to.generation.allocator
    found:=settles(info)
    synced:=found.id>=0 && ids_synced(from,ids_of(info,src,found.id))
    if !entities_copy(to,from) {return false}
    for &t,at in info.tables {
        if t.place!=.World {continue}
        if changed {
            if !raw_copy_changed(table_of(dst,&t),table_of(src,&t),t.info,t.flat,&marks[at]) {return false}
        } else if !raw_copy(table_of(dst,&t),table_of(src,&t),t.info,t.flat) {return false}
    }
    to_revisions,from_revisions:=revisions_of(info,dst),revisions_of(info,src)
    first:=len(info.tables)
    for &s,k in info.storages {
        if s.place!=.World || s.local {continue}
        a,b:=storage_of(dst,&s),storage_of(src,&s)
        marked:=changed && from_revisions!=nil
        if marked && !storage_changed(&marks[first+k],from_revisions[k]) {
            when CHECK_WRITES {if s.procs.copy==nil && s.procs.copy_kept==nil {storage_check(a,b,s.info,s.name)}}
            continue
        }
        if !storage_copy(&s,a,b,changed) {return false}
        if marked {storage_copied(&marks[first+k],&to_revisions[k],from_revisions[k])}
    }
    if !changed {revisions_copied(to_revisions,from_revisions)}
    if found.id>=0 {ids_moved(to,ids_of(info,dst,found.id),synced)}
    return true
}

// Whether a World still has a table, or a storage, as the copy a mark is of
// took it: nothing of it is to bring back from that copy.
@(private="file")
table_kept :: #force_inline proc "contextless" (t:^Raw_Table,mark:Copy_Mark) -> bool {
    return mark.valid && mark.version==t.version && mark.layout==t.layout && len(t.pending)==0
}

@(private="file")
storage_kept :: #force_inline proc "contextless" (revisions:[]u64,k:int,mark:Copy_Mark) -> bool {
    return revisions!=nil && mark.valid && mark.version==revisions[k]
}

// Makes the World dst what src holds, for a src that world_copy_changed
// keeps as a copy of dst with marks: the tables dst still has as that copy
// took them, with nothing pending, and the storages whose revision did not
// move since, stay as they are, and their readers see no change. The others
// are copied into stage, a third World, and then traded with dst without
// allocating. All or nothing: false without memory, with dst as it was. With
// fewer marks than copy_marks_count all of it is copied and traded. mixed:
// stage is left with parts of several Worlds, to stage another copy in or
// to clear, never to run; false after all of it was traded.
world_restore :: proc(info:^World_Info,dst,src,stage:rawptr,marks:[]Copy_Mark) -> (ok,mixed:bool) {
    if dst==src {return true,false}
    if len(marks)<copy_marks_count(info) {
        if !world_copy(info,stage,src) {return false,true}
        world_swap(info,dst,stage)
        return true,false
    }
    to,from,held:=entities_of(info,dst),entities_of(info,src),entities_of(info,stage)
    context.allocator=held.generation.allocator
    found:=settles(info)
    synced:=found.id>=0 && ids_synced(from,ids_of(info,src,found.id))
    if !entities_copy(held,from) {return false,true}
    revisions,staged:=revisions_of(info,dst),revisions_of(info,stage)
    first:=len(info.tables)
    for &t,at in info.tables {
        if t.place!=.World || table_kept(table_of(dst,&t),marks[at]) {continue}
        if !raw_copy(table_of(stage,&t),table_of(src,&t),t.info,t.flat) {return false,true}
    }
    for &s,k in info.storages {
        if s.place!=.World || s.local || storage_kept(revisions,k,marks[first+k]) {continue}
        if !storage_copy(&s,storage_of(stage,&s),storage_of(src,&s),false) {return false,true}
    }
    slice.ptr_swap_non_overlapping(to,held,size_of(Entities))
    for &t,at in info.tables {
        if t.place!=.World {continue}
        live:=table_of(dst,&t)
        if table_kept(live,marks[at]) {table_waits(live,false)} else {raw_swap(live,table_of(stage,&t))}
    }
    for &s,k in info.storages {
        if s.place!=.World || s.local || storage_kept(revisions,k,marks[first+k]) {continue}
        x,y:=storage_of(dst,&s),storage_of(stage,&s)
        if s.procs.swap!=nil {s.procs.swap(x,y)} else {slice.ptr_swap_non_overlapping(x,y,s.info.size)}
        if revisions!=nil {
            revision:=max(revisions[k],staged[k])+1
            revisions[k],staged[k]=revision,revision
        }
    }
    if found.id>=0 {
        ids_moved(to,ids_of(info,dst,found.id),synced)
        ids_moved(held,ids_of(info,stage,found.id),false)
    }
    return true,true
}

// Trades what two Worlds hold without allocating: what publishes a World
// prepared apart. What says copy=false stays in each.
world_swap :: proc(info:^World_Info,a,b:rawptr) {
    if a==b {return}
    ea,eb:=entities_of(info,a),entities_of(info,b)
    found:=settles(info)
    a_synced:=found.id>=0 && ids_synced(ea,ids_of(info,a,found.id))
    b_synced:=found.id>=0 && ids_synced(eb,ids_of(info,b,found.id))
    slice.ptr_swap_non_overlapping(ea,eb,size_of(Entities))
    for &t in info.tables {
        if t.place==.World {raw_swap(table_of(a,&t),table_of(b,&t))}
    }
    for &s in info.storages {
        if s.place!=.World || s.local {continue}
        x,y:=storage_of(a,&s),storage_of(b,&s)
        if s.procs.swap!=nil {s.procs.swap(x,y)} else {slice.ptr_swap_non_overlapping(x,y,s.info.size)}
    }
    revisions_swapped(revisions_of(info,a),revisions_of(info,b))
    if found.id>=0 {
        ids_moved(ea,ids_of(info,a,found.id),b_synced)
        ids_moved(eb,ids_of(info,b,found.id),a_synced)
    }
}

// Takes every entity and row of a World, and its storages derived from them
// go back to their start: the settings, the storages that say keep and those
// that are not copied stay. False without memory: the World as it was.
world_clear :: proc(info:^World_Info,world:rawptr) -> bool {
    if !entities_clear(entities_of(info,world)) {return false}
    for &t in info.tables {
        if t.place==.World {raw_clear(table_of(world,&t))}
    }
    for &s in info.storages {
        if s.place!=.World || s.keep || s.setting!=.None || s.local {continue}
        value:=storage_of(world,&s)
        if s.procs.reset!=nil {
            s.procs.reset(value)
            continue
        }
        storage_free(&s,value)
        mem.zero(value,s.info.size)
        if s.default!=nil {s.default(value)}
    }
    revisions_moved(revisions_of(info,world))
    return true
}

// Gives a World with an id its value of every by_world storage of the
// Shared, at its default. False without memory.
world_attach :: proc(info:^World_Info,world,shared:rawptr,allocator:runtime.Allocator) -> bool {
    found:=settles(info)
    if found.world_id<0 {return true}
    id:=(cast(^World_Id)storage_of(world,&info.storages[found.world_id]))^
    if id.generation==0 {return true}
    context.allocator=allocator
    for &s in info.storages {
        if !s.by_world {continue}
        value:=by_world_room(cast(^By_World(u8))storage_of(shared,&s),id,s.info.size,s.info.align,allocator)
        if value==nil {return false}
        mem.zero(value,s.info.size)
        if s.default!=nil {s.default(value)}
    }
    return true
}

// Frees the values of the by_world storages of a World, after its release phase.
world_detach :: proc(info:^World_Info,world,shared:rawptr) {
    found:=settles(info)
    if found.world_id<0 {return}
    id:=(cast(^World_Id)storage_of(world,&info.storages[found.world_id]))^
    for &s in info.storages {
        if !s.by_world {continue}
        held:=cast(^By_World(u8))storage_of(shared,&s)
        if value:=by_world_detach(held,id);value!=nil {
            storage_free(&s,value)
            by_world_release(held,value)
        }
    }
}
