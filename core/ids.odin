package core

import "mirai:std/base"

// The entities of a World by their Id, kept in its Entities: what finds the
// entity a scene, a save, the network or the API names. Settling the Id
// table brings it up to date with what changed since (ids_follow), and it
// travels with the entities when the World is copied or swapped. When two
// entities have one Id the one indexed first holds it, and another one with
// that Id takes it when it goes.
Id_Index :: struct {
    slots:[dynamic]Id_Slot,     // open addressing, a power of two at most half full; id 0 is empty
    of:[dynamic]base.Entity_Id, // by entity index: the Id it is indexed with, 0 without one
    count:int,                  // slots in use
    shared:int,                 // entities indexed with an Id another one holds
    seen:Seen,                  // of the Id table
    whole:bool,                 // the next follow reads the table whole: memory ran out, or the table came from elsewhere
    next:u64,                   // the state of id_next
}

Id_Slot :: struct {
    id:base.Entity_Id,
    entity:Entity,
}

@(private) IDS_MIN_SLOTS :: 64

// The live entity with an Id as of the last settle of the Id table; NONE
// without one. An Id added and not yet settled is not there.
entity_of :: proc "contextless" (es:^Entities,id:base.Entity_Id) -> Entity {
    if slot:=ids_slot(&es.ids,id);slot>=0 {
        e:=es.ids.slots[slot].entity
        if alive(es,e) {return e}
    }
    return NONE
}

// The Id of an entity, 0 without one or without a table of Id: its row,
// read without sealing it.
id_of :: proc "contextless" (ids:^Table(Id,$A),e:Entity) -> base.Entity_Id {
    if ids==nil {return 0}
    value,_:=get(ids,e)
    return value.value
}

// A new Id for an entity of the World: the next of the sequence of state
// (base.entity_id_next) that no live entity has. The caller keeps state; a
// state every end of a session derives alike gives each the same Id. Ids
// added and not yet settled do not count, so a second call before the
// settle gives another one only because state moved on.
id_new :: proc "contextless" (es:^Entities,state:^u64) -> base.Entity_Id {
    for {
        id:=base.entity_id_next(state)
        if entity_of(es,id)==NONE {return id}
    }
}

// A new Id from the sequence the World keeps, which travels with it when it is
// copied: what gives every copy of a document instantiated to stay its own Ids.
id_next :: proc "contextless" (es:^Entities) -> base.Entity_Id {
    return id_new(es,&es.ids.next)
}

// Brings the index up to date with the Id table of its World: the entities
// whose row went and the rows written or added since it looked, or the
// whole table when it was copied, swapped or cleared. table_settle calls it
// after settling a table of Id. Without memory the index reads the table
// whole at the next settle.
ids_follow :: proc(es:^Entities,table:^Table(Id,$A)) {
    x:=&es.ids
    c:=changes(table,&x.seen)
    if c.all || x.whole {
        if !ids_rebuild(es,table) {x.whole=true}
        return
    }
    for e in c.gone {ids_drop(es,table,e)}
    for row in each_changed(table,&c) {
        if !ids_put(es,table,entity_at(table,row),at(table,row).value) {
            x.whole=true
            return
        }
    }
}

// Whether the index followed every change of the Id table.
ids_synced :: proc "contextless" (es:^Entities,t:^Table(Id,$A)) -> bool {
    return !es.ids.whole && es.ids.seen==Seen{t.version,t.gone_first+u64(len(t.gone))}
}

// The entities and the Id table of a World came together from another one,
// copied or swapped: synced says whether the index had followed the table
// there (ids_synced). Then it follows this one from here, and otherwise it
// reads it whole at the next settle.
ids_moved :: proc "contextless" (es:^Entities,t:^Table(Id,$A),synced:bool) {
    if !synced {
        es.ids.whole=true
        return
    }
    es.ids.seen={t.version,t.gone_first+u64(len(t.gone))}
}

@(private)
ids_clear :: proc "contextless" (x:^Id_Index) {
    for &slot in x.slots {slot={}}
    for &id in x.of {id=0}
    x.count,x.shared=0,0
}

@(private)
ids_rebuild :: proc(es:^Entities,table:^Table(Id,$A)) -> bool {
    x:=&es.ids
    ids_clear(x)
    x.whole=false
    if !ids_reserve(x,count(table)) {return false}
    for row in 0..<count(table) {
        if !ids_put(es,table,entity_at(table,row),at(table,row).value) {return false}
    }
    return true
}

// The slot of an Id; -1 without it.
@(private)
ids_slot :: proc "contextless" (x:^Id_Index,id:base.Entity_Id) -> int {
    if id==0 || len(x.slots)==0 {return -1}
    mask:=len(x.slots)-1
    for i:=ids_home(id,mask);;i=(i+1)&mask {
        if x.slots[i].id==id {return i}
        if x.slots[i].id==0 {return -1}
    }
}

@(private)
ids_home :: #force_inline proc "contextless" (id:base.Entity_Id,mask:int) -> int {
    return int((u64(id)*0x9e3779b97f4a7c15)>>32)&mask
}

// Room for n Ids; false without memory.
@(private)
ids_reserve :: proc(x:^Id_Index,n:int) -> bool {
    if (n+1)*2<=len(x.slots) {return true}
    size:=max(IDS_MIN_SLOTS,len(x.slots))
    for (n+1)*2>size {size*=2}
    allocator:=x.slots.allocator
    if allocator.procedure==nil {allocator=context.allocator}
    slots,error:=make([dynamic]Id_Slot,size,allocator)
    if error!=nil {return false}
    mask:=size-1
    for slot in x.slots {
        if slot.id==0 {continue}
        i:=ids_home(slot.id,mask)
        for slots[i].id!=0 {i=(i+1)&mask}
        slots[i]=slot
    }
    delete(x.slots)
    x.slots=slots
    return true
}

// Indexes an entity with an Id, in place of the one it had.
@(private)
ids_put :: proc(es:^Entities,table:^Table(Id,$A),e:Entity,id:base.Entity_Id) -> bool {
    x:=&es.ids
    i:=entity_index(e)
    if i>=len(x.of) && resize(&x.of,max(i+1,entities_capacity(es)))!=nil {return false}
    if x.of[i]==id {return true}
    if x.of[i]!=0 {ids_unhold(es,table,e,x.of[i])}
    x.of[i]=id
    if id==0 {return true}
    if slot:=ids_slot(x,id);slot>=0 {
        if x.slots[slot].entity!=e {x.shared+=1}
        return true
    }
    if !ids_reserve(x,x.count+1) {
        x.of[i]=0
        return false
    }
    mask:=len(x.slots)-1
    at:=ids_home(id,mask)
    for x.slots[at].id!=0 {at=(at+1)&mask}
    x.slots[at]={id,e}
    x.count+=1
    return true
}

// An entity whose row of Id went.
@(private)
ids_drop :: proc(es:^Entities,table:^Table(Id,$A),e:Entity) {
    x:=&es.ids
    i:=entity_index(e)
    if i>=len(x.of) || x.of[i]==0 {return}
    id:=x.of[i]
    x.of[i]=0
    ids_unhold(es,table,e,id)
}

// An entity is no longer indexed with an Id: if it held it, another one
// indexed with it takes it, or the Id leaves the index.
@(private)
ids_unhold :: proc(es:^Entities,table:^Table(Id,$A),e:Entity,id:base.Entity_Id) {
    x:=&es.ids
    slot:=ids_slot(x,id)
    if slot<0 {return}
    if x.slots[slot].entity!=e {
        if x.shared>0 {x.shared-=1}
        return
    }
    if x.shared>0 {
        for row in 0..<count(table) {
            other:=entity_at(table,row)
            index:=entity_index(other)
            if other!=e && index<len(x.of) && x.of[index]==id {
                x.slots[slot].entity=other
                x.shared-=1
                return
            }
        }
    }
    // Backward shift: what probed past the slot moves into it.
    mask:=len(x.slots)-1
    hole,next:=slot,slot
    for {
        next=(next+1)&mask
        if x.slots[next].id==0 {break}
        home:=ids_home(x.slots[next].id,mask)
        stays:=hole<=next?hole<home && home<=next:hole<home || home<=next
        if stays {continue}
        x.slots[hole]=x.slots[next]
        hole=next
    }
    x.slots[hole]={}
    x.count-=1
}
