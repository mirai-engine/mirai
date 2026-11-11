package core

import "core:log"
import "core:slice"
import mm "mirai:std/math"

// The tree the Parent rows make, as they were at the last settle: by entity
// index, the entity each one hangs from, its first and last child and the
// siblings next to it, in their order. Only the generated settle writes it,
// after settling Parent; functions read it with Ref(Hierarchy) to go down the
// hierarchy, and go up it through Parent. A Parent that would put its entity
// under itself is left out of the tree, and its entity is a root of it until
// that Parent or the links above change; one that names an entity not alive
// leaves it a root. What hangs from an entity destroyed goes with it at the
// settle (hierarchy_doom): a child to keep is taken out first.
@(storage,reset="hierarchy_clear")
Hierarchy :: struct {
    parent:[dynamic]Entity,
    first_child,last_child:[dynamic]Entity,
    next_sibling,previous_sibling:[dynamic]Entity,
    cut:[dynamic]Entity, // with a Parent left out for a cycle: tried again when a link changes
    seen:Seen,           // of Parent
    version:u64,         // grows when a link changes
    // The entities whose link changed: each hangs from another entity, or
    // from none, or among its siblings in another order. A reader that reads
    // it whole (log_since) goes through all of the tree. Valid until the next
    // settle.
    moved:Log(Entity),
}

HIERARCHY_MOVED :: 1024 // the links moved holds

hierarchy_clear :: proc(h:^Hierarchy) {
    clear(&h.parent);clear(&h.first_child);clear(&h.last_child);clear(&h.next_sibling);clear(&h.previous_sibling);clear(&h.cut)
    h.seen={}
    h.version+=1
    log_reset(&h.moved)
}

// Destroys, with each entity destroyed since the last settle, what hangs from
// it: its children in the tree whose Parent still names it, those a Parent
// written since the tree last looked puts under it, and so on down. The
// settle of a World calls it after settling Parent and before the other
// tables. True when it destroyed any.
hierarchy_doom :: proc(h:^Hierarchy,parents:^Table(Parent,$A),es:^Entities) -> bool {
    if len(es.doomed)==0 || resize(&es.walk,len(es.generation))!=nil {return false}
    for e in es.doomed {es.walk[entity_index(e)]=true}
    first,k:=len(es.doomed),0
    for more:=true;more; {
        for ;k<len(es.doomed);k+=1 {
            gone:=es.doomed[k]
            if entity_index(gone)>=len(h.first_child) {continue}
            for child:=h.first_child[entity_index(gone)];child!=NONE;child=h.next_sibling[entity_index(child)] {
                if value,ok:=get(parents,child);ok && value.entity==gone {doom(es,child)}
            }
        }
        more=false
        seen:=h.seen
        c:=changes(parents,&seen)
        for row in each_changed(parents,&c) {
            p:=at(parents,row).entity
            if p!=NONE && !alive(es,p) && entity_index(p)<len(es.walk) && es.walk[entity_index(p)] {more=doom(es,entity_at(parents,row)) || more}
        }
    }
    for e in es.doomed {es.walk[entity_index(e)]=false}
    return len(es.doomed)>first
}

@(private="file")
doom :: proc(es:^Entities,e:Entity) -> bool {
    if !entity_destroy(es,e) {return false}
    es.walk[entity_index(e)]=true
    return true
}

// Makes the tree follow what Parent settled since it last looked: the
// generated settle calls it after table_settle of Parent, while the entities
// destroyed are still doomed. It goes through every row only when the table
// was copied, swapped or cleared. False without memory: the tree is built
// whole on the next settle.
hierarchy_settle :: proc(h:^Hierarchy,parents:^Table(Parent,$A),es:^Entities) -> bool {
    n:=entities_capacity(es)
    if len(h.parent)<n {
        if resize(&h.parent,n)!=nil || resize(&h.first_child,n)!=nil || resize(&h.last_child,n)!=nil ||
           resize(&h.next_sibling,n)!=nil || resize(&h.previous_sibling,n)!=nil {
            h.seen={}
            return false
        }
    }
    c:=changes(parents,&h.seen)
    moved:=false
    if c.all {
        slice.zero(h.parent[:]);slice.zero(h.first_child[:]);slice.zero(h.last_child[:])
        slice.zero(h.next_sibling[:]);slice.zero(h.previous_sibling[:])
        clear(&h.cut)
        for row in 0..<count(parents) {hierarchy_place(h,parents,es,entity_at(parents,row))}
        log_reset(&h.moved)
        moved=true
    } else {
        for e in es.doomed {moved=hierarchy_orphan(h,e) || moved}
        for e in c.gone {
            cut_drop(h,e)
            // Gone in a World rolled back from: an index the tree has not, or another's.
            i:=entity_index(e)
            if row:=rows_at(raw(parents),i);i>=len(h.parent) || row!=0 && parents.entities[row-1]!=e {continue}
            if hierarchy_unlink(h,e) {
                log_push(&h.moved,e,HIERARCHY_MOVED)
                moved=true
            }
        }
        for row in each_changed(parents,&c) {
            e:=entity_at(parents,row)
            if hierarchy_placed(h,parents,e) {continue}
            cut_drop(h,e)
            hierarchy_unlink(h,e)
            hierarchy_place(h,parents,es,e)
            log_push(&h.moved,e,HIERARCHY_MOVED)
            moved=true
        }
    }
    // A link that went may let one left out for a cycle in.
    for moved && len(h.cut)>0 {
        tried:=len(h.cut)
        for _ in 0..<tried {
            e:=h.cut[0]
            ordered_remove(&h.cut,0)
            if !alive(es,e) || !has(parents,e) {continue}
            if hierarchy_link(h,parents,es,e) {log_push(&h.moved,e,HIERARCHY_MOVED)} else if _,error:=append(&h.cut,e);error!=nil {h.seen={}}
        }
        if len(h.cut)==tried {break}
    }
    if moved {h.version+=1}
    return true
}

// Links e under the entity its Parent names, or leaves it out for a cycle and says so.
@(private)
hierarchy_place :: proc(h:^Hierarchy,parents:^Table(Parent,$A),es:^Entities,e:Entity) {
    if hierarchy_link(h,parents,es,e) {return}
    if _,error:=append(&h.cut,e);error!=nil {h.seen={}}
    log.warnf("core: the Parent of entity %d puts it under itself; it stays a root of the hierarchy until that changes",entity_index(e))
}

// Whether e hangs where its Parent says, among its siblings in their order.
@(private)
hierarchy_placed :: proc(h:^Hierarchy,parents:^Table(Parent,$A),e:Entity) -> bool {
    value,_:=get(parents,e)
    i:=entity_index(e)
    if h.parent[i]!=value.entity {return false}
    if value.entity==NONE {return true}
    if before:=h.previous_sibling[i];before!=NONE && order_of(parents,before)>value.order {return false}
    if after:=h.next_sibling[i];after!=NONE && order_of(parents,after)<value.order {return false}
    return true
}

// Puts e under the entity its Parent names, after the siblings whose order
// is not above its own; a root when that one is not alive. False when e is
// above it: the link would close a cycle.
@(private)
hierarchy_link :: proc(h:^Hierarchy,parents:^Table(Parent,$A),es:^Entities,e:Entity) -> bool {
    value,_:=get(parents,e)
    p:=value.entity
    if p==NONE || !alive(es,p) {return true}
    for at:=p;at!=NONE;at=h.parent[entity_index(at)] {
        if at==e {return false}
    }
    i,pi:=entity_index(e),entity_index(p)
    before:=h.last_child[pi]
    for before!=NONE && order_of(parents,before)>value.order {before=h.previous_sibling[entity_index(before)]}
    after:=before==NONE?h.first_child[pi]:h.next_sibling[entity_index(before)]
    h.parent[i],h.previous_sibling[i],h.next_sibling[i]=p,before,after
    if before==NONE {h.first_child[pi]=e} else {h.next_sibling[entity_index(before)]=e}
    if after==NONE {h.last_child[pi]=e} else {h.previous_sibling[entity_index(after)]=e}
    return true
}

@(private)
hierarchy_unlink :: proc(h:^Hierarchy,e:Entity) -> bool {
    i:=entity_index(e)
    p:=h.parent[i]
    if p==NONE {return false}
    pi:=entity_index(p)
    before,after:=h.previous_sibling[i],h.next_sibling[i]
    if before==NONE {h.first_child[pi]=after} else {h.next_sibling[entity_index(before)]=after}
    if after==NONE {h.last_child[pi]=before} else {h.previous_sibling[entity_index(after)]=before}
    h.parent[i],h.previous_sibling[i],h.next_sibling[i]=NONE,NONE,NONE
    return true
}

// The children an entity destroyed still has in the tree (hierarchy_doom had no memory) become roots.
@(private)
hierarchy_orphan :: proc(h:^Hierarchy,e:Entity) -> bool {
    i:=entity_index(e)
    child:=h.first_child[i]
    if child==NONE {return false}
    for child!=NONE {
        ci:=entity_index(child)
        log_push(&h.moved,child,HIERARCHY_MOVED)
        child,h.parent[ci],h.previous_sibling[ci],h.next_sibling[ci]=h.next_sibling[ci],NONE,NONE,NONE
    }
    h.first_child[i],h.last_child[i]=NONE,NONE
    return true
}

@(private)
cut_drop :: proc(h:^Hierarchy,e:Entity) {
    for at,k in h.cut {
        if at==e {unordered_remove(&h.cut,k);return}
    }
}

@(private)
order_of :: #force_inline proc(parents:^Table(Parent,$A),e:Entity) -> i32 {
    value,_:=get(parents,e)
    return value.order
}

// The entity e hangs from in the tree, NONE for a root.
parent_of :: #force_inline proc "contextless" (h:Ref(Hierarchy),e:Entity) -> Entity {
    i:=entity_index(e)
    return h.ptr!=nil && i<len(h.parent)?h.parent[i]:NONE
}

// The children of e in their order: from first_child, each one's next_sibling.
first_child :: #force_inline proc "contextless" (h:Ref(Hierarchy),e:Entity) -> Entity {
    i:=entity_index(e)
    return h.ptr!=nil && i<len(h.first_child)?h.first_child[i]:NONE
}
last_child :: #force_inline proc "contextless" (h:Ref(Hierarchy),e:Entity) -> Entity {
    i:=entity_index(e)
    return h.ptr!=nil && i<len(h.last_child)?h.last_child[i]:NONE
}
next_sibling :: #force_inline proc "contextless" (h:Ref(Hierarchy),e:Entity) -> Entity {
    i:=entity_index(e)
    return h.ptr!=nil && i<len(h.next_sibling)?h.next_sibling[i]:NONE
}

children :: proc(h:Ref(Hierarchy),e:Entity,allocator:=context.temp_allocator) -> []Entity {
    found:=make([dynamic]Entity,allocator)
    for child:=first_child(h,e);child!=NONE;child=next_sibling(h,child) {append(&found,child)}
    return found[:]
}

// The entity after at in the walk of root and everything under it, parents
// before children and siblings in their order; NONE past the last. With
// descend false the walk leaves out what hangs from at.
//
//     for at:=root;at!=core.NONE;at=core.subtree_next(h,root,at) {...}
subtree_next :: proc "contextless" (h:Ref(Hierarchy),root,at:Entity,descend:=true) -> Entity {
    if descend {
        if child:=first_child(h,at);child!=NONE {return child}
    }
    for e:=at;e!=root && e!=NONE;e=parent_of(h,e) {
        if next:=next_sibling(h,e);next!=NONE {return next}
    }
    return NONE
}

// e, or the nearest entity above it, with the component on; NONE without one.
ancestor_with :: proc(parents:^Table(Parent,$A),table:^Table($T,$B),e:Entity) -> Entity {
    at:=e
    for _ in 0..=HIERARCHY_DEPTH {
        if at==NONE || has(table,at) {return at}
        parent,ok:=get(parents,at)
        if !ok {return NONE}
        at=parent.entity
    }
    return NONE
}

// Whether ancestor is e or something e hangs under.
is_under :: proc(parents:^Table(Parent,$A),e,ancestor:Entity) -> bool {
    if ancestor==NONE {return false}
    at:=e
    for _ in 0..=HIERARCHY_DEPTH {
        if at==ancestor {return true}
        parent,ok:=get(parents,at)
        if !ok || parent.entity==NONE {return false}
        at=parent.entity
    }
    return false
}

// How many entities e hangs under, HIERARCHY_DEPTH at most.
depth_of :: proc(parents:^Table(Parent,$A),e:Entity) -> int {
    at:=e
    for depth in 0..<HIERARCHY_DEPTH {
        parent,ok:=get(parents,at)
        if !ok || parent.entity==NONE {return depth}
        at=parent.entity
    }
    return HIERARCHY_DEPTH
}

// The local transform that is world under parent, NONE for the root: what an
// entity that hangs from parent has to be to be there. A parent without
// Transform holds it as the root does. False when a parent without size on
// an axis cannot hold it there.
local_under :: proc(locals:^Table(Transform,$A),parents:^Table(Parent,$B),parent:Entity,world:mm.Transform) -> (local:mm.Transform,ok:bool) {
    if parent==NONE {return world,true}
    above,placed:=world_of(locals,parents,parent)
    if !placed {return world,true}
    return mm.transform_relative(world,above)
}

// Writes the Transform row of e so that it is at a position and rotation of
// the world under its parent; its scale stays. What a library that moves an
// entity writes.
world_set :: proc(row:^Transform,locals:^Table(Transform,$A),parents:^Table(Parent,$B),e:Entity,position:[3]f32,rotation:mm.Quat) -> bool {
    parent,_:=get(parents,e)
    local:=local_under(locals,parents,parent.entity,{position,rotation,{1,1,1}}) or_return
    row.position,row.rotation=local.position,local.rotation
    return true
}
