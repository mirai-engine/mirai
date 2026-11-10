package core

import "mirai:std/base"
import mm "mirai:std/math"

// The ground of a world, for what stands on it or builds over it without
// knowing who makes it: foliage, navigation. The library that makes it sets
// Ground_Queries.open once (terrain); without one the world has no ground.

Ground_Found :: enum u8 {
    None,     // no ground covers the line
    Ground,   // the hit
    Empty,    // ground covers the line but shows no surface along it: a hole, or a stroke the editor holds
    Unloaded, // ground covers the line but is not in memory there, far from every viewer: a change announces it once it loads
}

Ground_Hit :: struct {
    point,normal:[3]f32,     // in the world
    weights:[4]u8,           // of the layers there, adding up to 255
    layers:[4]base.Asset_Id, // the material of each weight
}

// Where the ground changed, in the world, with the revision it took.
Ground_Change :: struct {
    box:mm.Aabb,
    revision:u64,
}

Ground_Query :: struct {
    user:rawptr,
    // The highest ground along the line through origin along down. coarse:
    // an answer from what stays in memory wherever the ground is, cheaper.
    probe:proc(user:rawptr,origin,down:[3]f32,coarse:bool) -> (Ground_Hit,Ground_Found),
    spacing:f32,             // m between the finest samples of the ground: what samples it without missing any
    revision:u64,            // of its last change
    changes:[]Ground_Change, // the last ones, oldest first; one who saw a revision before changes[0].revision-1 takes everything as changed
    unloaded:[]mm.Aabb,      // where ground is but its collision is not loaded
    unloaded_revision:u64,   // changes whenever unloaded does
}

// Not shared: its one writer runs before its readers in each stage.
@(storage)
Ground_Queries :: struct {
    open:proc(w:World_Ref) -> (Ground_Query,bool),
}

// The ground of the world w; one without a probe when no library makes it.
ground_query :: proc(w:World_Ref,queries:Ref(Ground_Queries)) -> Ground_Query {
    if queries.ptr==nil || queries.open==nil || w.data==nil {return {}}
    query,_:=queries.open(w)
    return query
}
