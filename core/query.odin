package core

import mm "mirai:std/math"

// What collides in a world, for what looks into it without knowing who
// simulates it: the arm of a camera, the feet of a rig. The library that
// simulates the world gives it (physics); without one nothing is hit.
World_Hit :: struct {
    point,normal:[3]f32,
    distance:f32,
    entity:Entity,                  // the body hit
    support:u64,                    // what was hit, whose motion what stands on it follows
    support_transform:mm.Transform, // where the support is
}

World_Query :: struct {
    user:rawptr,
    // The first shape a sphere of radius (a ray at 0) meets going from origin
    // along direction for length, skipping the body of ignore. mask: the
    // collision categories that stop it.
    probe:proc(user:rawptr,origin,direction:[3]f32,length,radius:f32,ignore:Entity,mask:u32) -> (World_Hit,bool),
    support:proc(user:rawptr,id:u64) -> (mm.Transform,bool), // where a support is now; false once it is gone
    solid:proc(user:rawptr,e:Entity) -> bool,                // e has a body
}

@(storage,shared)
World_Queries :: struct {
    open:proc(w:World_Ref) -> (World_Query,bool),
}

// The query of the world w; one that hits nothing without a library that gives it.
world_query :: proc(w:World_Ref,queries:Ref(World_Queries)) -> World_Query {
    if queries.ptr==nil || queries.open==nil || w.data==nil {return {}}
    query,_:=queries.open(w)
    return query
}
