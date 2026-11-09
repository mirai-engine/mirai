package core

import "core:slice"
import "mirai:std/base"
import mm "mirai:std/math"

// Where an entity is relative to its parent. Several libraries move
// entities: a component that owns the Transform of its entity (a body, a
// replica) declares locks="core.Transform", and the others write with free.
@(component,shared,description="Position, rotation and scale relative to the parent entity.")
Transform :: struct {
    position:[3]f32,
    rotation:mm.Quat,
    scale:[3]f32,
}

TRANSFORM_IDENTITY :: Transform{{0,0,0},1,{1,1,1}}
TRANSFORM_DEFAULT :: TRANSFORM_IDENTITY

// Where an entity is in the world, and where it was at the tick before: the
// render draws it between the two. Only transforms_propagate writes it.
@(component,description="World position, rotation and scale computed from the entity hierarchy.")
World_Transform :: struct {
    using transform:mm.Transform `mirai:"transient"`,
    previous:mm.Transform `mirai:"transient"`,
}

@(component,description="The parent entity whose transform this entity follows.")
Parent :: struct {
    entity:Entity,
    order:i32, // among its siblings
}

@(component,description="The entity name shown in the scene hierarchy.")
Name :: struct {
    text:[64]u8 `mirai:"text"`,
}

// The identity of an entity in its scene or prefab and on every end of a
// network session.
@(component,description="Persistent identity used to save and reference this entity.")
Id :: struct {
    value:base.Entity_Id,
}

// An entity that this tick puts somewhere else without passing through what
// is between (a teleport): it and what hangs from it are drawn as coming from
// where `by` takes where they were, not from where they were.
Jump :: struct {entity:Entity,by:mm.Transform}

@(storage,queue)
Jumps :: struct {
    queue:Queue(Jump),
}

jump :: proc(jumps:^Jumps,e:Entity,by:mm.Transform) {push(&jumps.queue,Jump{e,by})}

// A place of the world an entity is asked to be at, without passing through
// what is between. The library whose component owns its Transform takes it
// in the fixed phase before places_drop, in the stage simulate (physics
// teleports its bodies); what nobody took is reported then and dropped, and
// what is asked later waits for the next tick.
Place_Request :: struct {entity:Entity,position:[3]f32,rotation:mm.Quat,at_rest:bool}

@(storage,queue)
Places :: struct {
    queue:Queue(Place_Request),
}

// What placing an entity needs, for a step to receive in one parameter.
@(params)
Placer :: struct {
    transforms:^Table(Transform),
    parents:Read(Parent),
    places:^Places,
    jumps:^Jumps,
}

// Puts an entity at a place of the world without knowing who owns its
// Transform: a free one is written now, under its parents; one that another
// component owns is asked of its owner. A teleport is a jump: who draws it
// takes it as coming from where it is put, not from where it was; a place
// that is not one moves it as it would have moved there (a cinematic).
// at_rest stops what its owner moves (a body): a respawn or a reset. Without it
// a body keeps its velocity, as what goes through a portal does.
// False when the entity has no Transform, or its parents cannot hold that place.
place :: proc(p:Placer,e:Entity,position:[3]f32,rotation:mm.Quat=1,teleport:=true,at_rest:=false) -> bool {
    row:=free(p.transforms,e)
    if row==nil {
        if !has(p.transforms,e) {return false}
        push(&p.places.queue,Place_Request{e,position,rotation,at_rest})
        return true
    }
    was,_:=world_of(read(p.transforms),p.parents,e)
    world_set(row,read(p.transforms),p.parents,e,position,rotation) or_return
    if teleport {
        turn:=rotation*conj(was.rotation)
        jump(p.jumps,e,{position-mm.quat_rotate(turn,was.position),turn,{1,1,1}})
    }
    return true
}

@(step="fixed",loops="game editor",stage="simulate")
places_drop :: proc(places:^Places,problems:^Problems) {
    for asked in take(&places.queue) {
        report(problems,asked.entity,"core.place","a place asked for this entity was not taken: another component owns its Transform (a pose target, a camera, a viewer) and does not place it; ask that library, or place an entity whose Transform is free or has a body")
    }
}

// What transforms_propagate keeps between passes.
@(storage)
Propagation :: struct {
    order:[dynamic]Entity,        // the entities with Transform, parents before children
    worlds:[dynamic]mm.Transform, // by entity index: the world of its last pass
    position:[dynamic]i32,        // by entity index: where it is in order
    computed:[dynamic]u32,        // by entity index: the pass that computed it last
    listed:[dynamic]u32,          // by entity index: the tick its row was put in moving
    moving,spare:[dynamic]Entity, // rows computed since the tick whose previous is not their transform
    dirty:[dynamic]Ordered,
    pass,ticks:u32,
    built_tree,built_locals,seen_locals:u64,
}

Ordered :: struct {position:i32,entity:Entity}

// The most parents a walk up through Parent goes through (world_of,
// ancestor_with, is_under, depth_of): a chain of parents that goes round ends
// there. The Hierarchy has no cycles and no limit: what hangs deeper is still
// propagated from its parent.
HIERARCHY_DEPTH :: 256

to_math :: #force_inline proc "contextless" (t:Transform) -> mm.Transform {return transmute(mm.Transform)t}
from_math :: #force_inline proc "contextless" (t:mm.Transform) -> Transform {return transmute(Transform)t}

// After every tick and every frame. In a tick what the entities were becomes
// their previous world transform; after a frame what the frame moved keeps
// the previous of the tick. Only the transforms written since the last pass
// and what hangs from them are computed again; all of them when entities
// gained or lost a Transform or the hierarchy changed. An entity hangs from
// its parent in the Hierarchy when that one has a Transform too.
@(step="fixed late",loops="game editor",stage="end")
transforms_propagate :: proc(locals:Read(Transform),hierarchy:Ref(Hierarchy),worlds:^Table(World_Transform),propagation:^Propagation,jumps:^Jumps,frame:Frame_Time) {
    transforms_compute(locals,hierarchy,worlds,propagation,frame.phase==.Fixed)
    if frame.phase!=.Fixed {return}
    for jumped in take(&jumps.queue) {
        for e:=jumped.entity;e!=NONE; {
            if !has(locals,e) {
                e=subtree_next(hierarchy,jumped.entity,e,false)
                continue
            }
            if row:=row_of(worlds,e);row>=0 {
                world:=at(worlds,row)
                world.previous=mm.transform_compose(jumped.by,world.previous)
            }
            e=subtree_next(hierarchy,jumped.entity,e)
        }
    }
}

@(private)
transforms_compute :: proc(locals:Read(Transform),h:Ref(Hierarchy),worlds:^Table(World_Transform),p:^Propagation,tick:bool) {
    p.pass+=1
    previous_moving:[]Entity
    if tick {
        p.ticks+=1
        p.moving,p.spare=p.spare,p.moving
        clear(&p.moving)
        previous_moving=p.spare[:]
    }
    if p.built_tree!=h.version || p.built_locals!=layout(locals) || len(p.position)!=len(locals.table.rows) {
        if !propagation_order(locals,h,p) {return}
        for e in p.order {transform_compute(locals,h,worlds,p,e,tick)}
        for i:=len(worlds.entities)-1;i>=0;i-=1 {
            if !has(locals,worlds.entities[i]) {remove(worlds,worlds.entities[i])}
        }
    } else if version(locals)!=p.seen_locals {
        clear(&p.dirty)
        for row in 0..<count(locals) {
            if stamp(locals,row)<=p.seen_locals {continue}
            e:=entity_at(locals,row)
            append(&p.dirty,Ordered{p.position[entity_index(e)],e})
        }
        slice.sort_by(p.dirty[:],proc(a,b:Ordered) -> bool {return a.position<b.position})
        for item in p.dirty {
            if p.computed[entity_index(item.entity)]==p.pass {continue}
            for at:=item.entity;at!=NONE; {
                if !has(locals,at) {
                    at=subtree_next(h,item.entity,at,false)
                    continue
                }
                transform_compute(locals,h,worlds,p,at,tick)
                at=subtree_next(h,item.entity,at)
            }
        }
    }
    p.seen_locals=version(locals)
    // What moved the tick before and not in this one stops between two places.
    for e in previous_moving {
        if i:=entity_index(e);i<len(p.computed) && p.computed[i]==p.pass {continue}
        row:=row_of(worlds,e)
        if row>=0 && worlds.values[row].previous!=worlds.values[row].transform {
            world:=at(worlds,row)
            world.previous=world.transform
        }
    }
}

@(private)
transform_compute :: proc(locals:Read(Transform),h:Ref(Hierarchy),worlds:^Table(World_Transform),p:^Propagation,e:Entity,tick:bool) {
    i:=entity_index(e)
    local,_:=get(locals,e)
    world:=to_math(local)
    if parent:=parent_of(h,e);parent!=NONE && has(locals,parent) {
        world=mm.transform_compose(p.worlds[entity_index(parent)],world)
    }
    p.worlds[i]=world
    p.computed[i]=p.pass
    if row:=row_of(worlds,e);row>=0 {
        current:=worlds.values[row]
        next:=World_Transform{world,tick?current.transform:current.previous}
        // A row is written only when it changes: its readers see what moved.
        if next!=current {at(worlds,row)^=next}
        if next.previous!=next.transform && p.listed[i]!=p.ticks+1 {
            p.listed[i]=p.ticks+1
            append(&p.moving,e)
        }
    } else {
        add(worlds,e,World_Transform{world,world})
    }
}

// The entities with Transform, each one after the one it hangs from: from
// each that hangs from none with a Transform, its subtree down to those
// without one. False without memory: it is built again on the next pass.
@(private)
propagation_order :: proc(locals:Read(Transform),h:Ref(Hierarchy),p:^Propagation) -> bool {
    size:=len(locals.table.rows)
    if resize(&p.order,count(locals))!=nil || resize(&p.worlds,size)!=nil || resize(&p.position,size)!=nil || resize(&p.computed,size)!=nil || resize(&p.listed,size)!=nil {
        p.built_locals=layout(locals)-1
        return false
    }
    n:=0
    for row in 0..<count(locals) {
        root:=entity_at(locals,row)
        if parent:=parent_of(h,root);parent!=NONE && has(locals,parent) {continue}
        for at:=root;at!=NONE; {
            if !has(locals,at) {
                at=subtree_next(h,root,at,false)
                continue
            }
            p.position[entity_index(at)]=i32(n)
            p.order[n]=at
            n+=1
            at=subtree_next(h,root,at)
        }
    }
    base.truncate(&p.order,n)
    p.built_tree=h.version
    p.built_locals=layout(locals)
    return true
}

// The world transform of an entity from its locals, without waiting for the
// next propagation: for a function that moved something and needs it now.
world_of :: proc(locals:Read(Transform),parents:Read(Parent),e:Entity) -> (world:mm.Transform,ok:bool) {
    chain:[HIERARCHY_DEPTH+1]Entity
    n:=0
    at:=e
    for at!=NONE && n<len(chain) {
        if !has(locals,at) {break}
        chain[n]=at
        n+=1
        parent,has_parent:=get(parents,at)
        at=has_parent?parent.entity:NONE
    }
    if n==0 {return mm.TRANSFORM_IDENTITY,false}
    world=mm.TRANSFORM_IDENTITY
    for i:=n-1;i>=0;i-=1 {
        local,_:=get(locals,chain[i])
        world=mm.transform_compose(world,to_math(local))
    }
    return world,true
}

name_get :: proc(names:Read(Name),e:Entity) -> string {
    if row:=row_of(names,e);row>=0 {return base.text_get(names.table.values[row].text[:])}
    return ""
}

// The first entity with that name; NONE without one. It walks the names.
entity_named :: proc(names:Read(Name),text:string) -> Entity {
    for row in 0..<count(names) {
        if base.text_equal(names.table.values[row].text[:],text) {return entity_at(names,row)}
    }
    return NONE
}

name_make :: proc(text:string) -> (name:Name) {
    base.text_set(name.text[:],text)
    return
}
