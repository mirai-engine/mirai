package core

import "base:intrinsics"
import "base:runtime"

// An entity that passes, with what hangs from it, to the World of the scene
// that replaces the one it is in: the seats of the players and what the
// game hung from them. A scene changing whole (from a menu to a match, from
// a lobby to a map) carries them; a game of levels keeps them in its root.
@(component,shared,description="This entity, with what hangs from it, passes to the world of the next scene that replaces this one.")
Keep :: struct {}

// Adds what src holds to dst: an entity for each one of src, with all its
// rows, on and off, and its Entity fields naming the new entities (one that
// named nothing of src names none). The roots of src go under parent (none:
// they are roots of dst), after the children it has. src stays as it was and
// must be settled; the rows appear in dst at its next settle, where a row of
// a single table comes off: it is on only once enabled. The World a job
// instantiated a scene in joins the live one this way (a section, a
// generated level). entities, when given, receives the entity of dst of each
// index of src; the join allocates nothing when it and dst have room. With
// roots, only those entities of src and what hangs from them join, as roots.
// All or nothing: false, with dst as it was, when the Worlds are not of one
// World_Info or there is no memory for what joins.
world_union :: proc(dst,src:World_Ref,parent:Entity=NONE,entities:^[dynamic]Entity=nil,roots:[]Entity=nil) -> (ok:bool) {
    if dst.info!=src.info || dst.place!=src.place || dst.info.schema==nil {return false}
    des,ses:=world_entities(dst),world_entities(src)
    indices:=len(ses.generation)
    // By index of src, the entity of dst it becomes: NONE when it does not
    // join, and a mark until it has one.
    made:[]Entity
    defer if !ok && entities!=nil {clear(entities)}
    if entities!=nil {
        if resize(entities,indices)!=nil {return false}
        made=entities[:]
    } else {
        error:runtime.Allocator_Error
        if made,error=make([]Entity,indices,context.temp_allocator);error!=nil {return false}
    }
    JOINS :: Entity(max(u64))
    UNKNOWN :: Entity(max(u64)-1)
    for &e in made {e=roots==nil?JOINS:UNKNOWN}
    if indices>0 {made[0]=NONE} // the index of NONE
    for i in ses.free {made[i]=NONE}
    for e in ses.doomed {made[entity_index(e)]=NONE}
    parents:=world_table_of(src,Parent)
    // With roots, nothing joins outside them and what hangs from them.
    if roots!=nil {
        for root in roots {if alive(ses,root) && made[entity_index(root)]==UNKNOWN {made[entity_index(root)]=JOINS}}
        for i in 1..<indices {
            if made[i]!=UNKNOWN {continue}
            chain:[64]int
            n:=0
            at:=entity_make(i,ses.generation[i])
            state:=NONE
            for depth:=0;depth<1024;depth+=1 {
                k:=entity_index(at)
                if made[k]!=UNKNOWN {state=made[k];break}
                if n<len(chain) {chain[n]=k;n+=1}
                if parents==nil {break}
                up,has:=get(read(parents),at)
                if !has || !alive(ses,up.entity) {break}
                at=up.entity
            }
            for k in chain[:n] {made[k]=state}
            if made[i]==UNKNOWN {made[i]=NONE}
        }
    }
    under:=parent!=NONE?world_table_of(dst,Parent):nil
    // Each one that joins is the entity create will give it, in their order.
    joined,rooted:=0,0
    free:=len(des.free)
    for i in 1..<indices {
        if made[i]!=JOINS {continue}
        index:=joined<free?int(des.free[free-1-joined]):len(des.generation)+joined-free
        made[i]=entity_make(index,index<len(des.generation)?des.generation[index]:1)
        joined+=1
        if under!=nil && union_root(made,ses,parents,entity_make(i,ses.generation[i])) {rooted+=1}
    }
    if joined==0 {return true}

    // Room for all of it first: past here nothing fails.
    capacity:=len(des.generation)+max(joined-len(des.free),0)
    if reserve(&des.generation,capacity)!=nil {return false}
    for &info in dst.info.tables {
        if info.place!=dst.place {continue}
        from,to:=world_table_at(src,&info),world_table_at(dst,&info)
        adds,offs:=0,0
        for row in 0..<from.values.len {
            e:=union_remap(made,ses,from.entities[row])
            if e==NONE {continue}
            if info.type==Parent && union_remap(made,ses,(^Parent)(raw_value(from,info.info,row)).entity)==NONE {continue}
            if !rows_room(to,entity_index(e),capacity) {return false}
            adds+=1
            if from.off[row] || info.single {offs+=1}
        }
        if under!=nil && to==raw(under) {
            adds+=rooted
            for e,i in made {
                if e!=NONE && union_root(made,ses,parents,entity_make(i,ses.generation[i])) && !rows_room(to,entity_index(e),capacity) {return false}
            }
        }
        if adds==0 {continue}
        waiting:=0
        for p in to.pending {if p.value>=0 {waiting+=1}}
        size,align:=info.info.size,info.info.align
        if reserve(&to.pending,len(to.pending)+adds+offs)!=nil {return false}
        if size>0 && !runtime.__dynamic_array_reserve(&to.added,size,align,to.added.len+adds) {return false}
        if !raw_reserve(to,size,align,to.values.len+waiting+adds,capacity-1) {return false}
    }

    for &e in made {if e!=NONE {e=create(des)}}
    for &info,index in dst.info.tables {
        if info.place!=dst.place {continue}
        from,to:=world_table_at(src,&info),world_table_at(dst,&info)
        offsets:=dst.info.schema.tables[index].entities
        size:=info.info.size
        for row in 0..<from.values.len {
            e:=union_remap(made,ses,from.entities[row])
            if e==NONE {continue}
            value:=raw_value(from,info.info,row)
            // A root of what joins hangs from parent, not from what stayed out.
            if info.type==Parent && union_remap(made,ses,(^Parent)(value).entity)==NONE {continue}
            raw_add(to,info.info,e,size>0?value:nil)
            if size>0 {
                image:=uintptr(to.added.data)+uintptr((to.added.len-1)*size)
                for offset in offsets {
                    field:=cast(^u64)(image+uintptr(offset))
                    intrinsics.unaligned_store(field,u64(union_remap(made,ses,Entity(intrinsics.unaligned_load(field)))))
                }
            }
            if from.off[row] || info.single {raw_disable(to,e)}
        }
    }
    if under!=nil {
        order:i32=0
        for row in 0..<count(under) {
            if up:=at(read(under),row);up.entity==parent {order=max(order,up.order+1)}
        }
        for e,i in made {
            if e==NONE || !union_root(made,ses,parents,entity_make(i,ses.generation[i])) {continue}
            add(under,e,Parent{parent,order})
            order+=1
        }
    }
    return true
}

// What an entity of src is in dst; NONE when it does not join.
@(private="file")
union_remap :: #force_inline proc "contextless" (made:[]Entity,ses:^Entities,e:Entity) -> Entity {
    if !alive(ses,e) {return NONE}
    return made[entity_index(e)]
}

// A root of what joins: no Parent, or one that names what stays out.
@(private="file")
union_root :: proc(made:[]Entity,ses:^Entities,parents:^Table(Parent),e:Entity) -> bool {
    if parents==nil {return true}
    up,has:=get(read(parents),e)
    return !has || union_remap(made,ses,up.entity)==NONE
}
