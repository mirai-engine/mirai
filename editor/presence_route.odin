package editor

import "core:math"
import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"

// The figure of an agent goes through no body of its world: what the library
// that simulates the world says collides (core.World_Query, which physics
// gives). Without one it goes straight and stands where it is told.

// A figure rests on what is under it: its sphere starts this far over its bottom.
PRESENCE_REST :: f32(0.02)
// The turns of a way around what stands between two places: up and across.
PRESENCE_ROUTE :: 2
// How high a way goes over what stands between two places, in steps of PRESENCE_LIFT m.
PRESENCE_LIFTS :: 8
PRESENCE_LIFT :: f32(0.5)
PRESENCE_ALL :: max(u32) // the collision categories that stop a figure: all

// The query of a world and the sphere a figure asks it with: about its
// middle, as wide as its widest half, its bottom PRESENCE_REST over its feet.
Presence_Space :: struct {
    query:core.World_Query,
    center:[3]f32, // from the eyes
    radius:f32,
    height:f32,    // of the top of the figure over its eyes
}

@(private)
presence_space :: proc(w:core.World_Ref,low,high:[3]f32) -> Presence_Space {
    query:core.World_Query
    if w.data!=nil {query=core.world_query(w,{core.world_storage_of(w,core.World_Queries)})}
    half:=(high-low)*0.5
    radius:=max(half.x,half.y,half.z)
    return {query,{(low.x+high.x)*0.5,low.y+PRESENCE_REST+radius,(low.z+high.z)*0.5},radius,high.y}
}

@(private="file")
presence_probe :: proc(space:Presence_Space,origin,span:[3]f32,radius:f32) -> (hit:core.World_Hit,met:bool) {
    length:=linalg.length(span)
    if space.query.probe==nil || length<1e-5 {return}
    return space.query.probe(space.query.user,origin,span/length,length,radius,core.NONE,PRESENCE_ALL)
}

// Whether a figure with its eyes there stands in a body.
@(private)
presence_blocked :: proc(space:Presence_Space,eyes:[3]f32) -> bool {
    _,met:=presence_probe(space,eyes+space.center,{0,1e-3,0},space.radius)
    return met
}

// Whether a figure goes from one place of its eyes to another through no body.
@(private)
presence_way_clear :: proc(space:Presence_Space,from,to:[3]f32) -> bool {
    if linalg.length(to-from)<1e-5 {return !presence_blocked(space,to)}
    _,met:=presence_probe(space,from+space.center,to-from,space.radius)
    return !met
}

// Whether the camera at `eye` sees the top and the middle of a figure with
// its eyes there: a head over a wall, or a body through a gap, is not enough.
@(private)
presence_seen :: proc(space:Presence_Space,eyes,eye:[3]f32) -> bool {
    for point in ([2][3]f32{eyes+{0,space.height,0},eyes+space.center}) {
        if _,met:=presence_probe(space,eye,point-eye,0);met {return false}
    }
    return true
}

// The turns of a way from one place of the eyes to another that crosses no
// body: none when the straight one is clear, else up, across over what stands
// between them and down. False when there is none.
@(private)
presence_route :: proc(space:Presence_Space,from,to:[3]f32) -> (route:[PRESENCE_ROUTE][3]f32,count:int,ok:bool) {
    if presence_way_clear(space,from,to) {return route,0,true}
    if presence_blocked(space,to) {return}
    for lift in 1..=PRESENCE_LIFTS {
        height:=max(from.y,to.y)+f32(lift)*PRESENCE_LIFT
        up,across:=[3]f32{from.x,height,from.z},[3]f32{to.x,height,to.z}
        if presence_way_clear(space,from,up) && presence_way_clear(space,up,across) && presence_way_clear(space,across,to) {
            return {up,across},2,true
        }
    }
    return
}

// The place nearest to `base` where a figure standing on it, around `look`,
// is in no body and the camera at `eye` sees it: the same height on the other
// side, to the sides and further out first; then one the camera does not see;
// then on what stands there. `base` itself when none is free.
@(private)
presence_free_place :: proc(space:Presence_Space,low,base,look,eye:[3]f32) -> [3]f32 {
    if space.query.probe==nil {return base}
    lift:=[3]f32{0,-low.y,0}
    out:=base-look
    out.y=0
    radius:=linalg.length(out)
    if radius<1e-3 {out,radius={0,0,1},0} else {out/=radius}
    TURNS :: [8]f32{0,1,0.5,-0.5,0.25,-0.25,0.75,-0.75}
    for seen in ([2]bool{true,false}) {
        for ring in 0..<(seen?3:6) {
            for turn in TURNS {
                place:=base
                if ring>0 || turn!=0 {
                    direction:=mm.quat_rotate(mm.quat_axis_angle({0,1,0},turn*math.PI),out)
                    place=look+direction*(radius+f32(ring)*0.6)
                    place.y=base.y
                }
                if presence_blocked(space,place+lift) {continue}
                if !seen || presence_seen(space,place+lift,eye) {return place}
            }
        }
    }
    // On the top of what stands there.
    above:=base+{0,f32(PRESENCE_LIFTS)*PRESENCE_LIFT,0}
    if hit,met:=presence_probe(space,above,base-above,0);met {
        place:=[3]f32{base.x,hit.point.y,base.z}
        if !presence_blocked(space,place+lift) {return place}
    }
    return base
}
