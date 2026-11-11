package core

import "core:slice"
import "mirai:std/base"

// Index in the low 32 bits, generation in the high 32. NONE is zero and no
// entity ever has index 0. The same type std/serial knows as an entity, so
// saving, loading and replicating remap the fields that hold one.
Entity :: base.Entity
NONE :: base.ENTITY_NONE

entity_index :: #force_inline proc "contextless" (e:Entity) -> int {return int(u64(e)&0xffff_ffff)}
entity_generation :: #force_inline proc "contextless" (e:Entity) -> u32 {return u32(u64(e)>>32)}
entity_make :: #force_inline proc "contextless" (index:int,generation:u32) -> Entity {return Entity(u64(generation)<<32|u64(u32(index)))}

Entities :: struct {
    generation:[dynamic]u32, // by index: that of the live entity, or of the next one
    free:[dynamic]u32,
    doomed:[dynamic]Entity,  // destroyed; world_settle removes their rows and frees their index
    off:[dynamic]bool,       // by index: it or something above it has Disabled
    turned:[dynamic]Entity,  // their off changed in this settle: the tables move their rows
    walk:[dynamic]bool,      // by index, while entities_activity runs: under a Disabled
    activity:Seen,           // the Disabled that off follows
    activity_tree:u64,       // and the version of the Hierarchy
    alive:int,
    disabled:int,            // the entities off
    ids:Id_Index,            // the entities by their Id
    pending:[dynamic]bool,   // by table of the World, as its World_Info lists them: it has adds, removes or turns that wait for the settle (Table.waits); a multiple of 8 long, and empty in a World made by hand
}

// Turns its entity off with everything under it. Their components keep their
// values, and no function sees them until Disabled goes, but for the base of
// every entity: Transform, World_Transform, Parent, Name, Id and Disabled
// stay on. A component turned off by itself stays off when its entity is on
// again.
@(component,shared,description="Turns this entity and everything under it off: their components keep their values and no system sees them until it is removed.")
Disabled :: struct {}

entities_init :: proc(es:^Entities,allocator:=context.allocator) -> bool {
    generation,error:=make([dynamic]u32,1,allocator)
    if error!=nil || raw_data(generation)==nil {return false}
    es.generation=generation
    es.free=make([dynamic]u32,allocator)
    es.doomed=make([dynamic]Entity,allocator)
    es.off=make([dynamic]bool,allocator)
    es.turned=make([dynamic]Entity,allocator)
    es.walk=make([dynamic]bool,allocator)
    es.ids.slots=make([dynamic]Id_Slot,allocator)
    es.ids.of=make([dynamic]base.Entity_Id,allocator)
    es.pending=make([dynamic]bool,allocator)
    es.alive=0
    return true
}

// Room for the tables of the World to say what they have pending
// (table_follow). False without memory.
entities_tables :: proc(es:^Entities,tables:int) -> bool {
    return resize(&es.pending,(tables+7)&~int(7))==nil
}

entities_destroy :: proc(es:^Entities) {
    delete(es.generation);delete(es.free);delete(es.doomed);delete(es.off);delete(es.turned);delete(es.walk)
    delete(es.ids.slots);delete(es.ids.of);delete(es.pending)
    es^={}
}

// False without memory for the list of its free indices: nothing changed.
entities_clear :: proc(es:^Entities) -> bool {
    if len(es.generation)==0 && resize(&es.generation,1)!=nil {return false}
    count:=len(es.generation)-1
    if resize(&es.free,count)!=nil {return false}
    for index in 1..<len(es.generation) {
        es.generation[index]+=1
        if es.generation[index]==0 {es.generation[index]=1}
        es.free[count-index]=u32(index)
    }
    clear(&es.doomed)
    clear(&es.off)
    clear(&es.turned)
    es.activity,es.activity_tree={},0
    es.alive=0
    es.disabled=0
    ids_clear(&es.ids)
    es.ids.whole=true
    return true
}

entity_create :: proc(es:^Entities) -> Entity {
    index:int
    if len(es.free)>0 {
        index=int(pop(&es.free))
    } else {
        append(&es.generation,1)
        index=len(es.generation)-1
    }
    es.alive+=1
    return entity_make(index,es.generation[index])
}

// The handle stops being alive at once; its rows go with the next settle.
entity_destroy :: proc(es:^Entities,e:Entity) -> bool {
    if !alive(es,e) {return false}
    i:=entity_index(e)
    es.generation[i]+=1
    if es.generation[i]==0 {es.generation[i]=1}
    append(&es.doomed,e)
    es.alive-=1
    return true
}

alive :: #force_inline proc "contextless" (es:^Entities,e:Entity) -> bool {
    i:=entity_index(e)
    return e!=NONE && i<len(es.generation) && es.generation[i]==entity_generation(e)
}

// Whether an entity is off: it or something above it has Disabled.
entity_off :: #force_inline proc "contextless" (es:^Entities,e:Entity) -> bool {
    i:=entity_index(e)
    return i<len(es.off) && es.off[i]
}

// Makes off follow Disabled and the hierarchy when either changed, and lists
// in turned the entities whose rows the other tables then move. The generated
// settle calls it between functions, after settling Disabled and Parent and
// the Hierarchy. False without memory: what it could not do waits for the
// next settle.
entities_activity :: proc(es:^Entities,disabled:^Table(Disabled,$A),hierarchy:Ref(Hierarchy)) -> bool {
    seen:=es.activity
    if !touched(disabled,&seen) && hierarchy.version==es.activity_tree {return true}
    if count(disabled)==0 && es.disabled==0 {
        es.activity,es.activity_tree=seen,hierarchy.version
        return true
    }
    n:=len(es.generation)
    if resize(&es.off,n)!=nil || resize(&es.walk,n)!=nil {return false}
    slice.zero(es.walk[:])
    // Below an entity marked everything is marked: its walk stops there.
    for row in 0..<count(disabled) {
        root:=entity_at(disabled,row)
        for at:=root;at!=NONE; {
            i:=entity_index(at)
            if es.walk[i] {
                at=subtree_next(hierarchy,root,at,false)
                continue
            }
            es.walk[i]=true
            at=subtree_next(hierarchy,root,at)
        }
    }
    for i in 1..<n {
        off:=es.walk[i]
        if off==es.off[i] {continue}
        if _,error:=append(&es.turned,entity_make(i,es.generation[i]));error!=nil {return false}
        es.off[i]=off
        es.disabled+=off?1:-1
    }
    es.activity,es.activity_tree=seen,hierarchy.version
    return true
}

// After every table dropped the rows of the doomed entities and moved those
// of the turned ones.
entities_settle :: proc(es:^Entities) {
    for e in es.doomed {append(&es.free,u32(entity_index(e)))}
    clear(&es.doomed)
    clear(&es.turned)
}

entities_copy :: proc(dst,src:^Entities) -> bool {
    return value_copy(dst,src,type_info_of(Entities))
}

// Every index an entity has had: the size a table of rows by entity needs.
entities_capacity :: #force_inline proc "contextless" (es:^Entities) -> int {return len(es.generation)}
