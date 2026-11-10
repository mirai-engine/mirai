package scene

import "base:intrinsics"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"

// An Entity field of a document that names an entity that is not in the
// world: another section, not loaded, names it by its Id in the world (id_in
// of its reference). The field holds none meanwhile; the reference waits
// here, a capture saves the Id instead of none, and once an entity with that
// Id is loaded the field takes it. A section that is dropped gives its fields
// back here: what named what it held waits for it again. Only loads, drops,
// captures and the step below touch it.

Unresolved_Reference :: struct {
    entity:core.Entity,
    table:u64,  // base.name_hash of the component
    offset:u32, // of the Entity field in its value
    target:base.Entity_Id,
}

@(storage)
Unresolved_References :: struct {
    items:[dynamic]Unresolved_Reference,
    ids:core.Seen, // the table of Id the last resolve saw
    resolved:[dynamic]Unresolved_Reference, // the fields that the loads and drops of sections of this frame gave their entity or none, not whoever edits the world; scene_sections empties it
    written:u64, // advances each time resolved takes fields
}

// The pending target of a field, 0 when it is not pending.
unresolved_target :: proc "contextless" (u:^Unresolved_References,e:core.Entity,table:u64,offset:u32) -> base.Entity_Id {
    if u==nil {return 0}
    for item in u.items {
        if item.entity==e && item.table==table && item.offset==offset {return item.target}
    }
    return 0
}

// A field that names something else now no longer waits.
unresolved_forget :: proc(u:^Unresolved_References,e:core.Entity,table:u64,offset:u32) {
    if u==nil {return}
    for i:=len(u.items)-1;i>=0;i-=1 {
        item:=u.items[i]
        if item.entity==e && item.table==table && item.offset==offset {unordered_remove(&u.items,i)}
    }
}

@(private)
Unresolved_Key :: struct {entity:core.Entity,table:u64,offset:u32}

// The pending targets by field, for whoever asks for many.
@(private)
unresolved_map :: proc(u:^Unresolved_References) -> map[Unresolved_Key]base.Entity_Id {
    pending:=make(map[Unresolved_Key]base.Entity_Id,context.temp_allocator)
    if u==nil {return pending}
    reserve(&pending,len(u.items))
    for item in u.items {pending[{item.entity,item.table,item.offset}]=item.target}
    return pending
}

// Whether a field of a value is saved: an Entity field that is transient is not.
@(private)
field_saved :: proc "contextless" (layout:^serial.Layout,offset:u32) -> bool {
    if layout.dense {return true}
    for run in layout.runs {
        if offset>=run.offset && offset<run.offset+run.size {return true}
    }
    return false
}

// Gives each pending field whose target is loaded now its entity, and forgets
// those of entities that are gone. A field that changed meanwhile keeps what
// it has; a target that is dormant is not loaded, and waits.
references_resolve :: proc(w:core.World_Ref) {
    u:=core.world_storage_of(w,Unresolved_References)
    ids:=core.world_table_of(w,core.Id)
    if u==nil || ids==nil || len(u.items)==0 {return}
    _=core.touched(ids,&u.ids)
    taken:=len(u.resolved)
    es:=core.world_entities(w)
    dormants:=core.world_table_of(w,Dormant)
    kept:=0
    for item in u.items {
        if !core.alive(es,item.entity) {continue}
        at,known:=core.world_table_index_of_hash(w,item.table)
        if !known {continue}
        info:=&w.info.tables[at]
        table:=core.world_table_at(w,info)
        value:=core.raw_find(table,info.info,item.entity)
        if value==nil {continue}
        field:=cast(^u64)(uintptr(value)+uintptr(item.offset))
        if core.Entity(intrinsics.unaligned_load(field))!=core.NONE {continue}
        target:=core.entity_of(es,item.target)
        if target==core.NONE || dormants!=nil && core.raw_row(core.raw(dormants),target)>=0 {
            u.items[kept]=item
            kept+=1
            continue
        }
        intrinsics.unaligned_store(field,u64(target))
        core.raw_touch(table,item.entity)
        append(&u.resolved,item)
    }
    base.truncate(&u.items,kept)
    if len(u.resolved)>taken {u.written+=1}
}

// The saved Entity fields of the world that name an entity inside (by index,
// alive) wait for its Id instead, and name none meanwhile: what a section that
// is dropped held. Those of the entities that go with it (gone, by index) stay
// as they are; one whose target has no Id names none.
references_release :: proc(w:core.World_Ref,inside,gone:[]bool) {
    es:=core.world_entities(w)
    ids:=core.read(core.world_table_of(w,core.Id))
    u:=core.world_storage_of(w,Unresolved_References)
    types:=schema_of(w)
    if types==nil {return}
    for &info,at in w.info.tables {
        value_type:=&types.tables[at]
        if info.place!=w.place || info.type==core.Parent || len(value_type.entities)==0 {continue}
        table:=core.world_table_at(w,&info)
        hash:=base.name_hash(info.name)
        for row in 0..<core.raw_count(table) {
            holder:=table.entities[row]
            if index:=core.entity_index(holder);index<len(gone) && gone[index] {continue}
            value:=core.raw_value(table,info.info,row)
            written:=false
            for offset in value_type.entities {
                if !field_saved(&value_type.layout,offset) {continue}
                field:=cast(^u64)(uintptr(value)+uintptr(offset))
                target:=core.Entity(intrinsics.unaligned_load(field))
                index:=core.entity_index(target)
                if target==core.NONE || index>=len(inside) || !inside[index] || !core.alive(es,target) {continue}
                id:=core.id_of(ids,target)
                if u!=nil {
                    if id!=0 {append(&u.items,Unresolved_Reference{holder,hash,offset,id})}
                    append(&u.resolved,Unresolved_Reference{holder,hash,offset,id})
                }
                intrinsics.unaligned_store(field,u64(core.NONE))
                written=true
            }
            if written {
                core.raw_touch(table,holder)
                if u!=nil {u.written+=1}
            }
        }
    }
}

// The fields that wait for a section resolve once the entities of the world
// change: a section that loads brings their targets.
@(step="frame",loops="game editor")
scene_references :: proc(world:core.World_Ref,unresolved:^Unresolved_References,ids:core.Read(core.Id)) {
    seen:=unresolved.ids
    if len(unresolved.items)==0 || !core.touched(ids,&seen) {return}
    references_resolve(world)
}
