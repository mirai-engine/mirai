package scene

import "base:intrinsics"
import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// What changed in a section is there when it loads again: an open chest, a
// dead boss, a bridge lowered. While a section is loaded its record tells,
// by the stamps of its rows (core.changes), which of its entities changed
// since it loaded. When it is dropped those, and the entities added while it
// was loaded, stay, off, where they hung (Dormant), and each entity of its
// scene that was destroyed, or left it, leaves a Tombstone with its Id. When it
// loads again, before what loaded joins the world, each dormant entity gives
// its values to the one that comes with its Id, and each tombstone takes its
// own. The memory follows what changed, and being entities, a saved game
// keeps them and Play and rollback copy them.

@(component,description="An entity of a section that is not loaded and that changed since its scene: it waits, off, for the section to load again.")
Dormant :: struct {}

// Whoever moves an entity by itself (an agent with somewhere to go) marks it
// each tick it does. Dropping its section does not leave it dormant: it hangs
// from the root and goes on in the far simulation of whoever marked it, and a
// section that loads where it is takes it again.
@(component,description="Moves by itself: dropping its section hangs it from the root, where it goes on moving far from the players, instead of leaving it dormant.")
Roaming :: struct {}

@(component,description="An entity of the scene of a section that was destroyed or left it: when the section loads again, the entity with this Id goes.")
Tombstone :: struct {
    id:base.Entity_Id `mirai:"readonly"`, // in the world: one that left the section keeps it
}

// What draws a far form of its own (an entity with a @(component,far): the
// roots of a terrain, the impostors of foliage) stays on when its section
// unloads, with what hangs from it, from the reference: the library that
// draws it keeps of it what its far form needs, as far as the sources are.
// The section that loads again takes it back in place of the entity of its
// scene with its Id, where that one hangs.
@(component,description="Draws the far form of a section that is not loaded: it stays on, and the section takes it back when it loads.")
Far_Kept :: struct {}

// The tables of the components that draw a far form of their own.
@(private)
far_tables :: proc(w:core.World_Ref) -> []^core.Raw_Table {
    tables:=make([dynamic]^core.Raw_Table,context.temp_allocator)
    for &info in w.info.tables {
        if !info.far || info.place!=w.place {continue}
        if t:=core.world_table_at(w,&info);t!=nil {append(&tables,t)}
    }
    return tables[:]
}

// Whether e draws a far form of its own.
@(private)
far_has :: proc(tables:[]^core.Raw_Table,e:core.Entity) -> bool {
    for t in tables {if core.raw_row(t,e)>=0 {return true}}
    return false
}


// What a loaded section knows of itself: the Ids of its scene, which
// components each of its entities had when it loaded, and what changed since.
// Made when it loads, looked at once its rows are in the world (records_look),
// and dropped with it. A copy of the world (Play, rollback) copies it with the
// stamps of the rows, so it goes on telling what changed.
Section_Record :: struct {
    reference:core.Entity,
    locals:[]base.Entity_Id,       // the Ids in its scene of what its scene brought, in order
    seen:[]u64,                    // by table of the World_Info: the version the last look saw; nil before the first
    fresh:[]bool,                  // by table: its rows that the next settle stamps without a change (it joins, or turns on)
    shapes:[dynamic]Section_Shape, // by entity, in order
    shaped:bool,                   // shapes holds what it had when it loaded
    changed:[dynamic]core.Entity,  // what changed before the last look
    look:bool,                     // the end of scene_sections looks at it
}

// Which components an entity has and which of them are off by themselves, as
// a hash: one that went or turned off changes it, which no stamp tells.
Section_Shape :: struct {
    entity:core.Entity,
    shape:u64,
}

@(storage)
Section_Records :: struct {
    items:[dynamic]Section_Record,
    looks:int, // records with look
}

@(private)
records_find :: proc(r:^Section_Records,e:core.Entity) -> ^Section_Record {
    if r==nil {return nil}
    for &record in r.items {if record.reference==e {return &record}}
    return nil
}

@(private)
records_drop :: proc(r:^Section_Records,e:core.Entity) {
    if r==nil {return}
    for &record,i in r.items {
        if record.reference!=e {continue}
        if record.look {r.looks-=1}
        core.value_free(&record,type_info_of(Section_Record))
        unordered_remove(&r.items,i)
        return
    }
}

// A record of the section of e, which its scene brought locals to, for the
// next look; the one it had goes. Not ok, with no record, without memory for it.
@(private)
records_add :: proc(w:core.World_Ref,e:core.Entity,locals:[]base.Entity_Id) -> (record:^Section_Record,ok:bool) {
    r:=core.world_storage_of(w,Section_Records)
    if r==nil || e==core.NONE {return nil,true}
    records_drop(r,e)
    // Those of sections that went go now: a section dropped takes its own.
    es:=core.world_entities(w)
    for i:=len(r.items)-1;i>=0;i-=1 {
        if !core.alive(es,r.items[i].reference) {records_drop(r,r.items[i].reference)}
    }
    sorted,no_sorted:=slice.clone(locals)
    if no_sorted!=nil {return nil,false}
    slice.sort(sorted)
    if _,no_room:=append(&r.items,Section_Record{reference=e,locals=sorted,look=true});no_room!=nil {
        delete(sorted)
        return nil,false
    }
    r.looks+=1
    return &r.items[len(r.items)-1],true
}

// Every record waiting for a look sees each table as it is, past the rows the
// next settle stamps for it (fresh): what is written after is a change. One
// that has no shapes yet takes those of its entities now. Out_Of_Memory when
// a record had no memory to look: it waits for the next call.
records_look :: proc(w:core.World_Ref) -> Error {
    r:=core.world_storage_of(w,Section_Records)
    if r==nil || r.looks==0 {return .None}
    waiting:=0
    for &record in r.items {
        if !record.look {continue}
        if len(record.seen)!=len(w.info.tables) {
            delete(record.seen)
            no_seen:mem.Allocator_Error
            if record.seen,no_seen=make([]u64,len(w.info.tables));no_seen!=nil {
                waiting+=1
                continue
            }
        }
        for &info,at in w.info.tables {
            if info.place!=w.place {continue}
            t:=core.world_table_at(w,&info)
            record.seen[at]=core.raw_settle_stamp(t) if at<len(record.fresh) && record.fresh[at] else t.version
        }
        delete(record.fresh)
        record.fresh,record.look=nil,false
        if !record.shaped {
            content:=make([dynamic]core.Entity,context.temp_allocator)
            section_content(w,record.reference,&content)
            shapes_take(w,&record.shapes,content[:],content[:])
            record.shaped=true
        }
    }
    r.looks=waiting
    return .Out_Of_Memory if waiting>0 else .None
}

// The tables whose rows say nothing of whether an entity of a section changed:
// what is derived, what a scene does not save, and what sections keep.
@(private)
fold_skips :: proc(info:^core.Table_Info,value_type:^core.Value_Schema) -> bool {
    if info.type==core.World_Transform || info.type==core.Id || info.type==Section_Held || info.type==Dormant || info.type==Tombstone || info.type==Section_Member || info.type==Section_Proxy {return true}
    return value_type.type==serial.TYPE_NONE || info.info.size>0 && len(value_type.layout.runs)==0
}

// The shape of e in w: Disabled counts only when its section did not give it,
// and where it hangs is told by the stamps of Parent.
@(private)
shape_of :: proc(w:core.World_Ref,types:^core.World_Schema,held:^core.Table(Section_Held),e:core.Entity) -> u64 {
    shape:=base.HASH_SEED
    for &info,at in w.info.tables {
        if info.place!=w.place || info.type==core.Parent || fold_skips(&info,&types.tables[at]) {continue}
        t:=core.world_table_at(w,&info)
        row:=core.raw_row(t,e)
        if row<0 || info.type==core.Disabled && row_has(held,e) {continue}
        shape=base.hash_mix(shape,u64(at)<<1|u64(t.off[row]))
    }
    return shape
}

// The shapes of entities of w, kept as those of into (by position), in order.
@(private)
shapes_take :: proc(w:core.World_Ref,shapes:^[dynamic]Section_Shape,entities,into:[]core.Entity) {
    types:=schema_of(w)
    if types==nil {return}
    held:=core.world_table_of(w,Section_Held)
    for e,i in entities {append(shapes,Section_Shape{into[i],shape_of(w,types,held,e)})}
    slice.sort_by(shapes[:],proc(a,b:Section_Shape) -> bool {return a.entity<b.entity})
}

// Adds to the record what of content changed since its last look: a row
// written, added or turned on since (core.changes), or a component that went
// or turned off by itself (its shape). What turning the section off or on did
// is no change: the Disabled of what it held, and the rows that went off with
// their entity. Without a look yet every entity of content counts.
@(private)
records_fold :: proc(w:core.World_Ref,record:^Section_Record,content:[]core.Entity) {
    types:=schema_of(w)
    if types==nil {return}
    held:=core.world_table_of(w,Section_Held)
    known:=make(map[core.Entity]bool,context.temp_allocator)
    for e in record.changed {known[e]=true}
    mark :: proc(record:^Section_Record,known:^map[core.Entity]bool,e:core.Entity) {
        if e in known {return}
        known[e]=true
        append(&record.changed,e)
    }
    if record.seen==nil || !record.shaped {
        for e in content {mark(record,&known,e)}
        return
    }
    for e in content {
        at,found:=slice.binary_search_by(record.shapes[:],e,proc(s:Section_Shape,e:core.Entity) -> slice.Ordering {return slice.cmp(s.entity,e)})
        if !found || record.shapes[at].shape!=shape_of(w,types,held,e) {mark(record,&known,e)}
    }
    for &info,at in w.info.tables {
        if info.place!=w.place || fold_skips(&info,&types.tables[at]) {continue}
        t:=core.world_table_at(w,&info)
        seen:=core.Seen{record.seen[at],t.gone_first+u64(len(t.gone))}
        c:=core.raw_changes(t,&seen)
        record.seen[at]=seen.version
        if t.version<=c.since {continue}
        disabled:=info.type==core.Disabled
        for e in content {
            row:=core.raw_row(t,e)
            if row<0 || t.stamps[row]<=c.since || disabled && row_has(held,e) {continue}
            mark(record,&known,e)
        }
    }
}

// Whether e is dormant, a tombstone or a far form kept: what a dropped section left.
@(private)
sleeper :: proc(dormants:^core.Table(Dormant),tombstones:^core.Table(Tombstone),kept:^core.Table(Far_Kept),e:core.Entity) -> bool {
    return row_has(dormants,e) || row_has(tombstones,e) || row_has(kept,e) || dormants!=nil && core.raw_added(core.raw(dormants),type_info_of(Dormant),e)!=nil
}

// A section that a drop goes through: the one dropped and each inside it.
@(private)
Dropped :: struct {
    reference:core.Entity,
    loaded:bool,
    content:[dynamic]core.Entity, // parents before children
    far:[dynamic]core.Entity,     // what draws a far form of its own: it stays on, with what hangs from it
    asleep:bool,  // what an earlier drop left hangs under it
    left:bool,    // dropped, it leaves something: its reference stays
    gone:[dynamic]base.Entity_Id, // Ids of its scene that are not there: tombstones
}

// Drops the section of reference e: its entities that changed since it loaded,
// or were added while it was loaded, stay off where they hung (a kept entity
// whose parent goes hangs from the reference, where it is), each entity of its
// scene that is not there leaves a Tombstone, what moves by itself (Roaming)
// hangs from the root, what draws a far form of its own stays on with what
// hangs from it (Far_Kept, from the reference, where it is), and the rest is
// destroyed. A section inside it is
// dropped first, and its reference stays while it holds something of it. The
// fields of the world that named what goes, or sleeps, wait for its Id. A
// section without a record (a saved game) keeps every entity with an Id, and
// takes the Ids of its scene from documents. False when the world has no
// sections; left: something stays under e.
section_unload :: proc(w:core.World_Ref,documents:Documents,e:core.Entity) -> (ok,left:bool) {
    references:=core.world_table_of(w,Scene_Reference)
    ids:=core.world_table_of(w,core.Id)
    members:=core.world_table_of(w,Section_Member)
    parents:=core.world_table_of(w,core.Parent)
    transforms:=core.world_table_of(w,core.Transform)
    hierarchy:=core.world_storage_of(w,core.Hierarchy)
    if references==nil || ids==nil || members==nil || parents==nil || hierarchy==nil || core.raw_row(core.raw(references),e)<0 {return}
    dormants:=core.world_table_of(w,Dormant)
    tombstones:=core.world_table_of(w,Tombstone)
    disabled:=core.world_table_of(w,core.Disabled)
    held:=core.world_table_of(w,Section_Held)
    roaming:=core.world_table_of(w,Roaming)
    far_kept:=core.world_table_of(w,Far_Kept)
    fars:=far_tables(w) if far_kept!=nil else nil
    records:=core.world_storage_of(w,Section_Records)
    es:=core.world_entities(w)
    h:=core.ref(hierarchy)
    reference_of :: proc(references:^core.Table(Scene_Reference),e:core.Entity) -> ^Scene_Reference {
        return (^Scene_Reference)(core.raw_find(core.raw(references),type_info_of(Scene_Reference),e))
    }

    // What there is, before anything changes: each section with what it holds.
    sections:=make([dynamic]Dropped,context.temp_allocator)
    roamers:=make([dynamic]core.Entity,context.temp_allocator)
    dropped :: proc(reference:core.Entity,loaded:bool) -> Dropped {return {reference=reference,loaded=loaded,content=make([dynamic]core.Entity,context.temp_allocator),far=make([dynamic]core.Entity,context.temp_allocator),gone=make([dynamic]base.Entity_Id,context.temp_allocator)}}
    append(&sections,dropped(e,true))
    Visit :: struct {entity:core.Entity,section:int}
    stack:=make([dynamic]Visit,context.temp_allocator)
    for child:=core.first_child(h,e);child!=core.NONE;child=core.next_sibling(h,child) {append(&stack,Visit{child,0})}
    for len(stack)>0 {
        visit:=pop(&stack)
        x:=visit.entity
        if !core.alive(es,x) {continue}
        if sleeper(dormants,tombstones,far_kept,x) {
            sections[visit.section].asleep=true
            continue
        }
        if row_has(roaming,x) {
            append(&roamers,x)
            continue
        }
        if sections[visit.section].loaded && far_has(fars,x) {
            append(&sections[visit.section].far,x)
            continue
        }
        append(&sections[visit.section].content,x)
        inner:=visit.section
        if reference:=reference_of(references,x);reference!=nil {
            append(&sections,dropped(x,reference.loaded!={}))
            inner=len(sections)-1
        }
        for child:=core.first_child(h,x);child!=core.NONE;child=core.next_sibling(h,child) {append(&stack,Visit{child,inner})}
    }

    // What stays of each, the innermost first: a reference whose section left something stays.
    count:=len(es.generation)
    inside:=make([]bool,count,context.temp_allocator)
    goes:=make([]bool,count,context.temp_allocator)
    kept:=make([]bool,count,context.temp_allocator)
    stays:=make(map[core.Entity]bool,context.temp_allocator)
    for i:=len(sections)-1;i>=0;i-=1 {
        s:=&sections[i]
        if !s.loaded {
            if s.asleep {stays[s.reference]=true}
            continue
        }
        for x in s.content {inside[core.entity_index(x)]=true}
        record:=records_find(records,s.reference)
        changed:=make(map[core.Entity]bool,context.temp_allocator)
        locals:[]base.Entity_Id
        if record!=nil {
            records_fold(w,record,s.content[:])
            for x in record.changed {changed[x]=true}
            locals=record.locals
        } else {
            for x in s.content {changed[x]=true}
            locals=scene_locals(documents,reference_of(references,s.reference).scene)
        }
        present:=make(map[base.Entity_Id]bool,context.temp_allocator)
        // A far form kept and what hangs from it are there: no tombstone takes them.
        far_stack:=make([dynamic]core.Entity,context.temp_allocator)
        append(&far_stack,..s.far[:])
        for len(far_stack)>0 {
            x:=pop(&far_stack)
            if member,in_scene:=row_of(members,x);in_scene {present[member.local]=true}
            for child:=core.first_child(h,x);child!=core.NONE;child=core.next_sibling(h,child) {append(&far_stack,child)}
        }
        for x in s.content {
            member,in_scene:=row_of(members,x)
            if in_scene {present[member.local]=true}
            if core.id_of(core.read(ids),x)==0 {continue}
            if !in_scene || changed[x] || stays[x] {
                kept[core.entity_index(x)]=true
                s.left=true
            }
        }
        for local in locals {
            if !present[local] {append(&s.gone,local)}
        }
        s.left||=len(s.gone)>0 || s.asleep || len(s.far)>0
        if s.left && i>0 {stays[s.reference]=true}
        for x in s.content {
            index:=core.entity_index(x)
            if !kept[index] {goes[index]=true}
        }
    }

    // Where what stays and what roams is, before anything moves: one whose parent goes hangs from its reference.
    Move :: struct {entity,parent:core.Entity,local:mm.Transform}
    moves:=make([dynamic]Move,context.temp_allocator)
    locals:=core.read(transforms)
    for s in sections {
        if !s.loaded {continue}
        above,_:=core.world_of(locals,core.read(parents),s.reference)
        for x in s.content {
            if !kept[core.entity_index(x)] {continue}
            parent,_:=core.get(parents,x)
            if parent.entity==s.reference || kept[core.entity_index(parent.entity)] {continue}
            at,placed:=core.world_of(locals,core.read(parents),x)
            local,fits:=mm.transform_relative(at,above)
            if !placed || !fits {local=at}
            append(&moves,Move{x,s.reference,local})
        }
        // A far form under what goes, or sleeps off, would go or turn off with it.
        for x in s.far {
            parent,_:=core.get(parents,x)
            if parent.entity==s.reference {continue}
            at,placed:=core.world_of(locals,core.read(parents),x)
            local,fits:=mm.transform_relative(at,above)
            if !placed || !fits {local=at}
            append(&moves,Move{x,s.reference,local})
        }
    }
    for x in roamers {
        at,_:=core.world_of(locals,core.read(parents),x)
        append(&moves,Move{x,core.NONE,at})
    }

    // What named what goes or sleeps waits for it.
    references_release(w,inside,goes)

    marks :: proc(disabled:^core.Table(core.Disabled),held:^core.Table(Section_Held),e:core.Entity,on:bool) {
        if disabled==nil || held==nil {return}
        switch {
        case !on && !row_has(disabled,e):
            core.add(disabled,e,core.Disabled{})
            core.add(held,e,Section_Held{})
        case on && row_has(held,e):
            core.remove(disabled,e)
            core.remove(held,e)
        }
    }
    // After what hangs from each reference: its children, and those that come now.
    next:=make(map[core.Entity]i32,context.temp_allocator)
    order_after :: proc(next:^map[core.Entity]i32,h:core.Ref(core.Hierarchy),e:core.Entity) -> i32 {
        if e not_in next {next[e]=i32(len(core.children(h,e)))}
        order:=next[e]
        next[e]=order+1
        return order
    }
    for move in moves {
        if transform:=(^core.Transform)(core.raw_edit(core.raw(transforms),type_info_of(core.Transform),move.entity));transform!=nil {transform^=core.from_math(move.local)}
        if move.parent==core.NONE {
            core.remove(parents,move.entity)
            core.remove(members,move.entity)
            marks(disabled,held,move.entity,true)
        } else {
            core.add(parents,move.entity,core.Parent{move.parent,order_after(&next,h,move.parent)})
        }
    }
    for &s in sections {
        if !s.loaded {continue}
        salt:=core.id_of(core.read(ids),s.reference)
        for x in s.content {
            if goes[core.entity_index(x)] {
                core.destroy(es,x)
                continue
            }
            if dormants!=nil {core.add(dormants,x,Dormant{})}
            marks(disabled,held,x,false)
        }
        // What stands for it stays on, whatever held it while it was loaded and off.
        for x in s.far {
            core.add(far_kept,x,Far_Kept{})
            marks(disabled,held,x,true)
        }
        for local in s.gone {
            t:=core.create(es)
            core.add(ids,t,core.Id{core.id_next(es)})
            core.add(parents,t,core.Parent{s.reference,order_after(&next,h,s.reference)})
            if tombstones!=nil {core.add(tombstones,t,Tombstone{id_in(salt,local)})}
            marks(disabled,held,t,false)
        }
        if reference:=(^Scene_Reference)(core.raw_edit(core.raw(references),type_info_of(Scene_Reference),s.reference));reference!=nil {
            reference.loaded,reference.held,reference.far={},false,reference.scene
        }
        records_drop(records,s.reference)
    }
    return true,sections[0].left
}

// The Ids in the world of the entities of the scene of the section of
// reference e that are not in it any more, destroyed or gone elsewhere, into
// out: of a section loaded, those its record knows of that it does not hold,
// or, loaded without a record (from a saved game), those of its scene in
// documents; of one dropped, its tombstones. False when it cannot tell: no
// section, or a scene documents cannot read. What a server says to the
// clients that load the section, so that its state of it wins over theirs.
section_gone :: proc(w:core.World_Ref,documents:Documents,e:core.Entity,out:^[dynamic]base.Entity_Id) -> bool {
    references:=core.world_table_of(w,Scene_Reference)
    hierarchy:=core.world_storage_of(w,core.Hierarchy)
    ids:=core.world_table_of(w,core.Id)
    reference,found:=row_of(references,e)
    if !found || hierarchy==nil || ids==nil {return false}
    h:=core.ref(hierarchy)
    tombstones:=core.world_table_of(w,Tombstone)
    if reference.loaded=={} {
        for child:=core.first_child(h,e);child!=core.NONE;child=core.next_sibling(h,child) {
            if tomb,buried:=row_of(tombstones,child);buried {append(out,tomb.id)}
        }
        return true
    }
    locals:[]base.Entity_Id
    if record:=records_find(core.world_storage_of(w,Section_Records),e);record!=nil {locals=record.locals} else {locals=scene_locals(documents,reference.loaded)}
    if locals==nil {return false}
    // What it holds of its scene, roaming or not, but not what is of a section inside it.
    members:=core.world_table_of(w,Section_Member)
    present:=make(map[base.Entity_Id]bool,context.temp_allocator)
    stack:=make([dynamic]core.Entity,context.temp_allocator)
    for child:=core.first_child(h,e);child!=core.NONE;child=core.next_sibling(h,child) {append(&stack,child)}
    for len(stack)>0 {
        x:=pop(&stack)
        if row_has(tombstones,x) {continue}
        if member,in_scene:=row_of(members,x);in_scene {present[member.local]=true}
        if row_has(references,x) {continue}
        for child:=core.first_child(h,x);child!=core.NONE;child=core.next_sibling(h,child) {append(&stack,child)}
    }
    salt:=core.id_of(core.read(ids),e)
    for local in locals {
        if !present[local] {append(out,id_in(salt,local))}
    }
    return true
}

// The Ids of the entities of a scene, from documents; nil when it cannot be read.
@(private)
scene_locals :: proc(documents:Documents,scene:base.Asset_Id) -> []base.Entity_Id {
    if documents.open==nil {return nil}
    file:=documents.open(documents.user,scene)
    if file==nil {return nil}
    view,error:=asset.scene_view(file,documents.types)
    if error!=.None {return nil}
    return view.ids
}

// What the dormant entities and tombstones under a section that loads do with
// the World it loaded in, before that World joins the world (sleepers_apply),
// and what is left to do in the world once it joined (sleepers_join).
@(private)
Sleepers :: struct {
    applied:map[core.Entity]core.Entity, // a dormant entity whose values went to an entity of the load, which takes its place
    woken:[dynamic]core.Entity,          // dormant entities added while it was loaded: they turn on
    buried:[dynamic]core.Entity,         // tombstones that took their entity
    hang:[dynamic]Hang,                  // entities of the load that hang from an entity of the world
    took:[dynamic]core.Entity,           // entities of the load that took the values of a dormant one
    kept:[dynamic]Kept,                  // far forms kept, which take the place of the entities of the load with their Ids
}

@(private)
Hang :: struct {entity,parent:core.Entity,order:i32}

// A far form kept and where the entity of the load it replaces hung: from
// an entity of the load, or none, from the reference.
@(private)
Kept :: struct {
    entity,parent:core.Entity,
    order:i32,
    local:core.Transform,
}

// Gives each dormant entity under e whose section loaded in apart its values
// to the entity of apart with its Id, and takes from apart the entity of each
// tombstone: one of a section inside it goes with it once that section loads.
// Entity fields name the entities of apart with the Ids they named, or wait
// for them. A far form kept stays, with what hangs from it, and the entity
// of apart with its Id goes, with what hangs from it.
@(private)
sleepers_apply :: proc(w,apart:core.World_Ref,e:core.Entity) -> (s:Sleepers) {
    s.applied=make(map[core.Entity]core.Entity,context.temp_allocator)
    s.woken=make([dynamic]core.Entity,context.temp_allocator)
    s.buried=make([dynamic]core.Entity,context.temp_allocator)
    s.hang=make([dynamic]Hang,context.temp_allocator)
    s.took=make([dynamic]core.Entity,context.temp_allocator)
    s.kept=make([dynamic]Kept,context.temp_allocator)
    far_kept:=core.world_table_of(w,Far_Kept)
    hierarchy:=core.world_storage_of(w,core.Hierarchy)
    dormants:=core.world_table_of(w,Dormant)
    tombstones:=core.world_table_of(w,Tombstone)
    parents:=core.world_table_of(w,core.Parent)
    if hierarchy==nil || dormants==nil || tombstones==nil || parents==nil {return}
    h:=core.ref(hierarchy)
    ids:=core.read(core.world_table_of(w,core.Id))
    apart_es:=core.world_entities(apart)
    apart_references:=core.world_table_of(apart,Scene_Reference)
    apart_parents:=core.world_table_of(apart,core.Parent)
    // Under e, parents before children: what is dormant may hold more.
    asleep:=make([dynamic]core.Entity,context.temp_allocator)
    stack:=make([dynamic]core.Entity,context.temp_allocator)
    for child:=core.first_child(h,e);child!=core.NONE;child=core.next_sibling(h,child) {append(&stack,child)}
    for len(stack)>0 {
        x:=pop(&stack)
        if row_has(tombstones,x) || row_has(far_kept,x) {append(&asleep,x);continue}
        if !row_has(dormants,x) {continue}
        append(&asleep,x)
        for child:=core.first_child(h,x);child!=core.NONE;child=core.next_sibling(h,child) {append(&stack,child)}
    }
    // Whether the section x sleeps in loaded in apart: that of e, or one inside it that loaded with it.
    loaded_with :: proc(s:^Sleepers,w:core.World_Ref,apart_references:^core.Table(Scene_Reference),parents:^core.Table(core.Parent),e,x:core.Entity) -> bool {
        references:=core.world_table_of(w,Scene_Reference)
        at:=x
        for _ in 0..<core.HIERARCHY_DEPTH {
            parent,placed:=core.get(parents,at)
            if !placed || parent.entity==e {return true}
            at=parent.entity
            if references==nil || core.raw_row(core.raw(references),at)<0 {continue}
            took,applied:=s.applied[at]
            if !applied || apart_references==nil {return false}
            inner:=(^Scene_Reference)(core.raw_find(core.raw(apart_references),type_info_of(Scene_Reference),took))
            return inner!=nil && inner.loaded!={}
        }
        return false
    }
    for x in asleep {
        if !loaded_with(&s,w,apart_references,parents,e,x) {continue}
        if row_has(far_kept,x) {
            k:=Kept{entity=x,parent=core.NONE}
            if took:=core.entity_of(apart_es,core.id_of(ids,x));core.alive(apart_es,took) {
                if apart_parents!=nil {
                    if parent:=(^core.Parent)(core.raw_find(core.raw(apart_parents),type_info_of(core.Parent),took));parent!=nil {k.parent,k.order=parent.entity,parent.order}
                }
                if transforms:=core.world_table_of(apart,core.Transform);transforms!=nil {
                    if local:=(^core.Transform)(core.raw_find(core.raw(transforms),type_info_of(core.Transform),took));local!=nil {k.local=local^}
                }
                // What hangs from it in the load hangs from x, but for what x already holds.
                if apart_parents!=nil {
                    children:=make([dynamic]core.Entity,context.temp_allocator)
                    t:=core.raw(apart_parents)
                    for row in 0..<core.raw_count(t) {
                        if (^core.Parent)(core.raw_value(t,type_info_of(core.Parent),row)).entity==took {append(&children,t.entities[row])}
                    }
                    apart_ids:=core.read(core.world_table_of(apart,core.Id))
                    for child in children {
                        if there:=core.entity_of(core.world_entities(w),core.id_of(apart_ids,child));core.alive(core.world_entities(w),there) {
                            core.world_destroy_tree(apart,child)
                            continue
                        }
                        parent:=(^core.Parent)(core.raw_find(t,type_info_of(core.Parent),child))
                        append(&s.hang,Hang{child,x,parent.order})
                        core.remove(apart_parents,child)
                    }
                }
                core.destroy(apart_es,took)
            }
            append(&s.kept,k)
            continue
        }
        if tomb,buried:=row_of(tombstones,x);buried {
            if gone:=core.entity_of(apart_es,tomb.id);core.alive(apart_es,gone) {core.world_destroy_tree(apart,gone)}
            append(&s.buried,x)
            continue
        }
        took:=core.entity_of(apart_es,core.id_of(ids,x))
        if !core.alive(apart_es,took) {
            append(&s.woken,x)
            continue
        }
        s.applied[x]=took
        append(&s.took,took)
        values_apply(w,apart,x,took)
        parent,_:=core.get(parents,x)
        switch {
        case parent.entity==e:
            if apart_parents!=nil {core.remove(apart_parents,took)}
        case parent.entity in s.applied:
            if apart_parents!=nil {core.add(apart_parents,took,core.Parent{s.applied[parent.entity],parent.order})}
        case:
            append(&s.hang,Hang{took,parent.entity,parent.order})
        }
    }
    return
}

// The values of the dormant entity x go to the entity took of apart: every
// component it has, with what it saves and took keeps of the rest, and
// whether one is off; what x lacks goes from took. Where it hangs and its
// identity are those of took.
@(private)
values_apply :: proc(w,apart:core.World_Ref,x,took:core.Entity) {
    types:=schema_of(w)
    if types==nil {return}
    ids:=core.read(core.world_table_of(w,core.Id))
    apart_es:=core.world_entities(apart)
    pending:=core.world_storage_of(w,Unresolved_References)
    waiting:=core.world_storage_of(apart,Unresolved_References)
    // What took waited for is what x waits for now.
    if waiting!=nil {
        for i:=len(waiting.items)-1;i>=0;i-=1 {if waiting.items[i].entity==took {unordered_remove(&waiting.items,i)}}
        if pending!=nil {
            for item in pending.items {
                if item.entity!=x {continue}
                moved:=item
                moved.entity=took
                append(&waiting.items,moved)
            }
        }
    }
    buffer:=make([dynamic]u8,context.temp_allocator)
    for &info,at in w.info.tables {
        if info.place!=w.place || info.type==core.Parent || info.type==core.Id || info.type==core.Disabled || info.type==Dormant || info.type==Section_Held || info.type==Section_Member || info.type==core.World_Transform || info.type==Tombstone {continue}
        from,to:=core.world_table_at(w,&info),core.world_table_at(apart,&info)
        if from==nil || to==nil {continue}
        value:=core.raw_find(from,info.info,x)
        target:=core.raw_find(to,info.info,took)
        if value==nil {
            if target!=nil {core.raw_remove(to,took)}
            continue
        }
        size:=info.info.size
        value_type:=&types.tables[at]
        resize(&buffer,size)
        if size>0 {
            if target!=nil {mem.copy(raw_data(buffer),target,size)} else {mem.zero(raw_data(buffer),size)}
            if value_type.type==serial.TYPE_NONE || value_type.layout.dense {
                mem.copy(raw_data(buffer),value,size)
            } else {
                for run in value_type.layout.runs {mem.copy(&buffer[run.offset],rawptr(uintptr(value)+uintptr(run.offset)),int(run.size))}
            }
            for offset in value_type.entities {
                if !field_saved(&value_type.layout,offset) {continue}
                field:=cast(^u64)&buffer[offset]
                named:=core.Entity(intrinsics.unaligned_load(field))
                id:=named!=core.NONE?core.id_of(ids,named):0
                there:=id!=0?core.entity_of(apart_es,id):core.NONE
                if id!=0 && !core.alive(apart_es,there) {
                    if waiting!=nil {append(&waiting.items,Unresolved_Reference{took,base.name_hash(info.name),offset,id})}
                    there=core.NONE
                }
                intrinsics.unaligned_store(field,u64(there))
            }
        }
        data:rawptr=size>0?raw_data(buffer):nil
        if target!=nil {
            if size>0 {mem.copy(target,data,size)}
        } else {
            core.raw_add(to,info.info,took,data)
        }
        if to.base {continue}
        _,off,_:=core.raw_state(from,x)
        _,was,found:=core.raw_state(to,took)
        switch {
        case off && (!found || !was): core.raw_disable(to,took)
        case !off && found && was:    core.raw_enable(to,took)
        }
    }
    // What its author turned off stays off; what its section turned off is not.
    disabled,held:=core.world_table_of(w,core.Disabled),core.world_table_of(w,Section_Held)
    if row_has(disabled,x) && !row_has(held,x) {
        if off:=core.world_table_of(apart,core.Disabled);off!=nil {core.add(off,took,core.Disabled{})}
    }
}

// Once what loaded joined the world (made: the entity of the world of each
// index of apart): what hung from a dormant entity that gave its values hangs
// from the one that took them, and it goes; tombstones that took theirs go;
// what was added while the section was loaded turns on, but under a section
// that joins off (held); and what waits for a field of a dormant entity that
// went waits for the one that took it.
@(private)
sleepers_join :: proc(w:core.World_Ref,e:core.Entity,s:^Sleepers,made:[]core.Entity,held:bool) {
    hierarchy:=core.world_storage_of(w,core.Hierarchy)
    parents:=core.world_table_of(w,core.Parent)
    if hierarchy==nil || parents==nil {return}
    h:=core.ref(hierarchy)
    es:=core.world_entities(w)
    took :: proc(made:[]core.Entity,e:core.Entity) -> core.Entity {
        index:=core.entity_index(e)
        return index<len(made)?made[index]:core.NONE
    }
    buried:=make(map[core.Entity]bool,context.temp_allocator)
    for x in s.buried {buried[x]=true}
    for x,into in s.applied {
        for child:=core.first_child(h,x);child!=core.NONE;child=core.next_sibling(h,child) {
            if child in s.applied || buried[child] {continue}
            parent,_:=core.get(parents,child)
            core.add(parents,child,core.Parent{took(made,into),parent.order})
        }
        core.destroy(es,x)
    }
    for x in s.buried {core.destroy(es,x)}
    // A far form kept hangs where the entity it took the place of hung.
    if far_kept:=core.world_table_of(w,Far_Kept);far_kept!=nil {
        transforms:=core.world_table_of(w,core.Transform)
        disabled:=core.world_table_of(w,core.Disabled)
        held_marks:=core.world_table_of(w,Section_Held)
        for k in s.kept {
            core.remove(far_kept,k.entity)
            if row_has(held_marks,k.entity) {
                if disabled!=nil {core.remove(disabled,k.entity)}
                core.remove(held_marks,k.entity)
            }
            into:=took(made,k.parent) if k.parent!=core.NONE else core.NONE
            if into==core.NONE {continue}
            core.add(parents,k.entity,core.Parent{into,k.order})
            if transform:=(^core.Transform)(core.raw_edit(core.raw(transforms),type_info_of(core.Transform),k.entity));transform!=nil {transform^=k.local}
        }
    }
    dormants:=core.world_table_of(w,Dormant)
    disabled:=core.world_table_of(w,core.Disabled)
    marks:=core.world_table_of(w,Section_Held)
    for x in s.woken {
        if dormants!=nil {core.remove(dormants,x)}
        parent,_:=core.get(parents,x)
        if held && parent.entity==e {continue}
        if row_has(marks,x) {
            if disabled!=nil {core.remove(disabled,x)}
            core.remove(marks,x)
        }
    }
    for hang in s.hang {core.add(parents,took(made,hang.entity),core.Parent{hang.parent,hang.order})}
    if u:=core.world_storage_of(w,Unresolved_References);u!=nil {
        for i:=len(u.items)-1;i>=0;i-=1 {if u.items[i].entity in s.applied {unordered_remove(&u.items,i)}}
    }
}

// Whether e has a row of t, off or on: what is dormant is off.
@(private)
row_has :: proc(t:^core.Table($T),e:core.Entity) -> bool {return t!=nil && core.raw_row(core.raw(t),e)>=0}

// The row of e in t, off or on.
@(private)
row_of :: proc(t:^core.Table($T),e:core.Entity) -> (value:T,found:bool) {
    if t==nil {return}
    row:=core.raw_row(core.raw(t),e)
    if row<0 {return}
    return (^T)(core.raw_value(core.raw(t),type_info_of(T),row))^,true
}

// Starts reading what of the scene of the section of reference e draws a
// far form of its own (the entities with a @(component,far)), to show while
// the section is not loaded: a load of its own (far_keep), whose assets warm
// in jobs as those of any load. far_load_end shows it. nil without far
// forms in the world.
far_load_begin :: proc(app:^host.App,w:core.World_Ref,e:core.Entity) -> (job:^Load_Job,error:Error) {
    references:=core.world_table_of(w,Scene_Reference)
    ids:=core.world_table_of(w,core.Id)
    if references==nil || ids==nil {return nil,.Invalid}
    reference:=(^Scene_Reference)(core.raw_find(core.raw(references),type_info_of(Scene_Reference),e))
    if reference==nil {return nil,.Invalid}
    reference.far=reference.scene
    if len(far_tables(w))==0 || reference.scene=={} {return nil,.None}
    return load_begin(app,reference.scene,{},core.id_of(core.read(ids),e),far=true)
}

// Of a scene instantiated apart, only the entities that draw a far form of
// their own stay: kept (Far_Kept), where they are in the scene, without
// what hangs from them, as a section that unloads leaves them.
@(private)
far_keep :: proc(apart:core.World_Ref) {
    fars:=far_tables(apart)
    es:=core.world_entities(apart)
    transforms:=core.world_table_of(apart,core.Transform)
    parents:=core.world_table_of(apart,core.Parent)
    kept:=core.world_table_of(apart,Far_Kept)
    if transforms==nil || parents==nil || kept==nil {return}
    Placed :: struct {entity:core.Entity,pose:mm.Transform}
    placed:=make([dynamic]Placed,context.temp_allocator)
    for generation,index in es.generation {
        x:=core.entity_make(index,generation)
        if index==0 || !core.alive(es,x) || !far_has(fars,x) {continue}
        pose,_:=core.world_of(core.read(transforms),core.read(parents),x)
        append(&placed,Placed{x,pose})
    }
    for generation,index in es.generation {
        x:=core.entity_make(index,generation)
        if index==0 || !core.alive(es,x) {continue}
        far:=false
        for p in placed {far||=p.entity==x}
        if !far {core.destroy(es,x)}
    }
    for p in placed {
        core.remove(parents,p.entity)
        if local:=(^core.Transform)(core.raw_edit(core.raw(transforms),type_info_of(core.Transform),p.entity));local!=nil {local^=core.from_math(p.pose)}
        core.add(kept,p.entity,Far_Kept{})
    }
    core.world_settle(apart)
}

// Shows what a far load read, from the reference e, where what the section
// showed before goes; nothing when the section loaded, or asks for another
// scene, meanwhile. A section that loads takes it back. Frees the load.
far_load_end :: proc(job:^Load_Job,w:core.World_Ref,e:core.Entity) -> bool {
    defer load_free(job)
    references:=core.world_table_of(w,Scene_Reference)
    kept:=core.world_table_of(w,Far_Kept)
    hierarchy:=core.world_storage_of(w,core.Hierarchy)
    if job.error!=.None || references==nil || kept==nil || hierarchy==nil {return false}
    reference:=(^Scene_Reference)(core.raw_find(core.raw(references),type_info_of(Scene_Reference),e))
    if reference==nil || reference.loaded!={} || reference.far!=job.root {return false}
    h:=core.ref(hierarchy)
    for child:=core.first_child(h,e);child!=core.NONE;child=core.next_sibling(h,child) {
        if row_has(kept,child) {core.world_destroy_tree(w,child)}
    }
    return core.world_union(w,host.app_world_ref(job.app,job.world),e)
}
