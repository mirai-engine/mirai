package mirai_physics

import cmath "core:math"
import "mirai:std/base"
import math "mirai:std/math"

Fluid_Handle :: distinct base.Handle

Fluid_Shape :: enum u32 {
    Plane, // everything under the height of its position: an ocean
    Box,   // its top face is the surface: a lake in its basin, a pool
    River, // a path of points with their width, depth and speed (fluid_river.odin)
}

// A volume of fluid, or of air with density zero: a dry box takes the fluid of lower priority out of where
// it is, as a base under the sea or the air of a room that floods. Fluids do not overlap each other and dry
// boxes do not overlap each other; where two would, the one of higher priority decides.
Fluid_Desc :: struct {
    shape:Fluid_Shape,
    position:Vec3,     // a point of the surface of a plane; the center of a box
    yaw:f32,           // radians about +Y: the frame of a box and of its current
    half_extents:Vec3, // m, of a box
    density:f32,       // kg/m3: 1000 fresh water, 1025 the sea; zero is dry, only for a box
    current:Vec3,      // m/s in the frame of the volume
    priority:i32,
    user_data:u64,
    waves:Fluid_Waves, // of a plane, in the world; a box and a river hold still
    river:[FLUID_RIVER_POINTS]River_Point, // of a river, in the world
    river_count:u32,
}

// Slot of a fluid. Plain data, copied by snapshots.
@(private)
Fluid :: struct {
    user_data:u64,
    position:Vec3,
    half_extents:Vec3,
    current:Vec3, // in the frame of the volume
    yaw:f32,
    density:f32,
    priority:i32,
    shape:Fluid_Shape,
    generation:u32, // odd while the slot is in use
    next_free:i32,
    reach:f32,      // m the waves reach over and under the still surface
    river_count:u32, // points of a river
    river_at:[FLUID_RIVER_POINTS]u8, // the sample of each of its points
    waves:Fluid_Waves,
    river:[FLUID_RIVER_SAMPLES]River_Point, // of a river, its points with the curve between them (river_samples)
}

// The fluid at a point. `height` is the surface over a point in the fluid, under a point above it, or the
// underside of the fluid over a point below all of it, whose normal then faces down.
Fluid_Sample :: struct {
    height:f32,
    normal:Vec3,
    current:Vec3,  // m/s, world
    density:f32,   // kg/m3 at the point: zero above the surface and in a dry box
    fluid:Fluid_Handle,
}

// Most dry boxes taken out of the column of one point; more in the same column are ignored.
FLUID_COLUMN_DRY :: 8

@(private)
fluid_read :: #force_inline proc "contextless" (w:^World,h:Fluid_Handle) -> (^Fluid,i32) {
    index:=base.handle_index(base.Handle(h))
    generation:=base.handle_generation(base.Handle(h))
    if index>=u32(w.fluid_high) || generation&1==0 || w.fluids[index].generation!=generation {return nil,-1}
    return &w.fluids[index],i32(index)
}
@(private)
fluid_get :: #force_inline proc "contextless" (w:^World,h:Fluid_Handle) -> (^Fluid,i32) {
    f,index:=fluid_read(w,h)
    if f!=nil {stamp(w,.Fluids,index)}
    return f,index
}

@(private) fluid_handle :: #force_inline proc "contextless" (w:^World,index:i32) -> Fluid_Handle {
    return Fluid_Handle(base.handle_make(u32(index),w.fluids[index].generation))
}

@(private)
fluid_desc_valid :: proc "contextless" (d:Fluid_Desc) -> bool {
    if !is_finite3(d.position) || !is_finite3(d.current) || !(abs(d.yaw)<=max(f32)) {return false}
    if !(d.density>=0 && d.density<=max(f32)) {return false}
    if !waves_valid(d.waves) {return false}
    switch d.shape {
    case .Plane: return d.density>0
    case .Box:   return d.waves.count==0 && d.half_extents.x>0 && d.half_extents.y>0 && d.half_extents.z>0 && is_finite3(d.half_extents)
    case .River: return d.waves.count==0 && d.density>0 && river_valid(d)
    }
    return false
}

// The curve of a river (river_samples), which its surface follows; zero for another fluid or a handle that
// is gone.
fluid_river :: proc(w:^World,h:Fluid_Handle,out:^[FLUID_RIVER_SAMPLES]River_Point) -> int {
    f,_:=fluid_read(w,h)
    if f==nil || f.shape!=.River {return 0}
    count:=int(f.river_at[f.river_count-1])+1
    copy(out[:count],f.river[:count])
    return count
}

fluid_valid :: proc(w:^World,h:Fluid_Handle) -> bool {
    f,_:=fluid_read(w,h)
    return f!=nil
}

// Null when the description is not usable (a dry plane, a box without size or with waves, a dry river, one
// with waves or with fewer than two points, a point without width or depth or on the one before it, values
// that are not finite, waves of no length or of no direction) or
// World_Desc.fluid_capacity is exhausted.
fluid_create :: proc(w:^World,desc:Fluid_Desc) -> Fluid_Handle {
    if !fluid_desc_valid(desc) || !fluid_scratch_make(w) {return {}}
    index:=w.fluid_free
    if index<0 && int(w.fluid_high)>=len(w.fluids) {
        w.stats.fluid_capacity_exhausted+=1
        return {}
    }
    if index>=0 {
        w.fluid_free=w.fluids[index].next_free
    } else {
        index=w.fluid_high
        w.fluid_high+=1
    }
    w.fluid_count+=1
    f:=&w.fluids[index]
    stamp(w,.Fluids,index)
    generation:=f.generation+1
    f^=fluid_of(desc)
    f.generation,f.next_free=generation,-1
    fluid_changed(w,fluid_aabb(f))
    return fluid_handle(w,index)
}

fluid_destroy :: proc(w:^World,h:Fluid_Handle) {
    f,index:=fluid_get(w,h)
    if f==nil {return}
    fluid_changed(w,fluid_aabb(f))
    f^={generation=f.generation+1,next_free=w.fluid_free}
    w.fluid_free=index
    w.fluid_count-=1
}

// Changes a fluid in place, as a room that floods; wakes what it covered and what it covers now. False,
// changing nothing, for a description that is not usable.
fluid_set :: proc(w:^World,h:Fluid_Handle,desc:Fluid_Desc) -> bool {
    f,_:=fluid_get(w,h)
    if f==nil || !fluid_desc_valid(desc) {return false}
    before:=fluid_aabb(f)
    generation:=f.generation
    f^=fluid_of(desc)
    f.generation,f.next_free=generation,-1
    fluid_changed(w,before)
    fluid_changed(w,fluid_aabb(f))
    return true
}

fluid_desc :: proc(w:^World,h:Fluid_Handle) -> (desc:Fluid_Desc,ok:bool) {
    f,_:=fluid_read(w,h)
    if f==nil {return}
    desc={shape=f.shape,position=f.position,yaw=f.yaw,half_extents=f.half_extents,density=f.density,current=f.current,priority=f.priority,user_data=f.user_data,waves=f.waves,river_count=f.river_count}
    for i in 0..<int(f.river_count) {desc.river[i]=f.river[f.river_at[i]]}
    return desc,true
}

// The box a fluid fills; a plane reaches without end sideways and down.
fluid_bounds :: proc(w:^World,h:Fluid_Handle) -> Aabb {
    f,_:=fluid_read(w,h)
    return f!=nil?fluid_aabb(f):{}
}

// The live fluids and dry boxes whose bounds meet `box`, in slot order; writes up to len(out) of them after
// the first `skip` and returns how many there are in all.
fluids_overlap :: proc(w:^World,box:Aabb,out:[]Fluid_Handle,skip:=0) -> int {
    count:=0
    for &f,i in w.fluids[:w.fluid_high] {
        if f.generation&1==0 || !math.aabb_overlaps(fluid_aabb(&f),box) {continue}
        if at:=count-skip;at>=0 && at<len(out) {out[at]=fluid_handle(w,i32(i))}
        count+=1
    }
    return count
}

@(private)
fluid_of :: proc "contextless" (d:Fluid_Desc) -> Fluid {
    f:=Fluid{user_data=d.user_data,position=d.position,current=d.current,yaw=d.yaw,density=d.density,priority=d.priority,shape=d.shape,waves=waves_of(d.waves)}
    if d.shape==.Box {f.half_extents=d.half_extents}
    if d.shape==.River {
        points:=d.river
        f.river_count=d.river_count
        river_samples(points[:d.river_count],&f.river,&f.river_at)
    }
    f.reach=waves_reach(&f.waves)
    return f
}

@(private) FLUID_FAR :: 1e30 // m: how far a plane reaches sideways and down

@(private)
fluid_aabb :: proc "contextless" (f:^Fluid) -> Aabb {
    if f.shape==.Plane {return {{-FLUID_FAR,-FLUID_FAR,-FLUID_FAR},{FLUID_FAR,f.position.y+f.reach,FLUID_FAR}}}
    if f.shape==.River {return river_aabb(f)}
    s,c:=cmath.sincos(f.yaw)
    h:=f.half_extents
    reach:=Vec3{abs(c)*h.x+abs(s)*h.z,h.y,abs(s)*h.x+abs(c)*h.z}
    return {f.position-reach,f.position+reach}
}

// The point in the frame of a box, turned by its yaw.
@(private)
fluid_local :: #force_inline proc "contextless" (f:^Fluid,p:Vec3) -> Vec3 {
    s,c:=cmath.sincos(f.yaw)
    d:=p-f.position
    return {c*d.x-s*d.z,d.y,s*d.x+c*d.z}
}

@(private)
fluid_in_column :: #force_inline proc "contextless" (f:^Fluid,p:Vec3) -> bool {
    if f.shape==.Plane {return true}
    if f.shape==.River {return river_spot(f,p.x,p.z).inside}
    l:=fluid_local(f,p)
    return abs(l.x)<=f.half_extents.x && abs(l.z)<=f.half_extents.z
}

// Height and normal of the free surface of a fluid over (x, z) at the time of the world: its waves over its
// still surface. The one place that knows its shape, which every reader follows.
@(private)
fluid_surface_at :: proc "contextless" (w:^World,f:^Fluid,x,z:f32) -> (height:f32,normal:Vec3) {
    if f.shape==.River {
        spot:=river_spot(f,x,z)
        return spot.center.y,river_normal(spot.along)
    }
    still:=f.position.y+(f.shape==.Box?f.half_extents.y:0)
    if f.waves.count==0 {return still,UP}
    origin:=wave_origin(x,z)
    terms,count:=wave_terms(&f.waves,w.time,origin)
    height,normal=wave_surface(terms[:count],f32(f64(x)-origin.x),f32(f64(z)-origin.y))
    return still+height,normal
}

@(private)
fluid_bottom :: #force_inline proc "contextless" (f:^Fluid,p:Vec3) -> f32 {
    if f.shape==.River {
        spot:=river_spot(f,p.x,p.z)
        return spot.center.y-spot.depth
    }
    return f.shape==.Box?f.position.y-f.half_extents.y:-FLUID_FAR
}

// The surface of a fluid or the top of a dry box over (x, z) (fluid_surface_at); false for a handle that is gone.
fluid_surface :: proc(w:^World,h:Fluid_Handle,x,z:f32) -> (height:f32,normal:Vec3,ok:bool) {
    f,_:=fluid_read(w,h)
    if f==nil {return}
    height,normal=fluid_surface_at(w,f,x,z)
    return height,normal,true
}

// Whether a point is in the volume of a fluid or a dry box: in its column, between its bottom and its surface.
// Dry boxes do not take a fluid out here: fluid_sample does.
fluid_holds :: proc(w:^World,h:Fluid_Handle,p:Vec3) -> bool {
    f,_:=fluid_read(w,h)
    if f==nil || !fluid_in_column(f,p) {return false}
    top,_:=fluid_surface_at(w,f,p.x,p.z)
    return p.y>=fluid_bottom(f,p) && p.y<=top
}

@(private)
fluid_current :: #force_inline proc "contextless" (f:^Fluid,p:Vec3) -> Vec3 {
    if f.shape==.River {
        spot:=river_spot(f,p.x,p.z)
        return spot.along*spot.speed
    }
    s,c:=cmath.sincos(f.yaw)
    return {c*f.current.x+s*f.current.z,f.current.y,c*f.current.z-s*f.current.x}
}

// The outward planes of a box turned by its yaw: -X, +X, -Y, +Y, -Z, +Z of its frame.
@(private)
fluid_box_planes :: proc "contextless" (f:^Fluid) -> [6]Plane {
    s,c:=cmath.sincos(f.yaw)
    x:=Vec3{c,0,-s}
    z:=Vec3{s,0,c}
    h:=f.half_extents
    p:=f.position
    return {{-x,-dot(x,p)+h.x},{x,dot(x,p)+h.x},{-UP,-p.y+h.y},{UP,p.y+h.y},{-z,-dot(z,p)+h.z},{z,dot(z,p)+h.z}}
}

// Of the fluids whose column holds the point (a pool can stand over the sea), the one that holds it, else
// the nearest under it, else the nearest over it; then the one of higher priority, then the lower slot. -1
// without one.
@(private)
fluid_find :: proc "contextless" (w:^World,p:Vec3) -> i32 {
    found:=i32(-1)
    found_rank:=3
    found_distance:f32
    for &f,i in w.fluids[:w.fluid_high] {
        if f.generation&1==0 || f.density<=0 || !fluid_in_column(&f,p) {continue}
        top,_:=fluid_surface_at(w,&f,p.x,p.z)
        bottom:=fluid_bottom(&f,p)
        rank,distance:=0,f32(0)
        if p.y>top {
            rank,distance=1,p.y-top
        } else if p.y<bottom {rank,distance=2,bottom-p.y}
        if rank>found_rank || rank==found_rank && (distance>found_distance || distance==found_distance && f.priority<=w.fluids[found].priority) {continue}
        found,found_rank,found_distance=i32(i),rank,distance
    }
    return found
}

@(private) Fluid_Interval :: struct {bottom,top:f32}

// The stretches of the column of a point that hold the fluid, bottom up: the fluid less the dry boxes
// over it in priority. Returns how many.
@(private)
fluid_column :: proc "contextless" (w:^World,fluid:i32,p:Vec3,out:^[FLUID_COLUMN_DRY+1]Fluid_Interval) -> int #no_bounds_check {
    f:=&w.fluids[fluid]
    top,_:=fluid_surface_at(w,f,p.x,p.z)
    bottom:=fluid_bottom(f,p)
    if !(top>bottom) {return 0}
    holes:[FLUID_COLUMN_DRY]Fluid_Interval
    hole_count:=0
    for &d in w.fluids[:w.fluid_high] {
        if d.generation&1==0 || d.density>0 || d.priority<=f.priority || !fluid_in_column(&d,p) {continue}
        hole:=Fluid_Interval{d.position.y-d.half_extents.y,d.position.y+d.half_extents.y}
        if hole.top<=bottom || hole.bottom>=top || hole_count==FLUID_COLUMN_DRY {continue}
        at:=hole_count
        for at>0 && holes[at-1].bottom>hole.bottom {
            holes[at]=holes[at-1]
            at-=1
        }
        holes[at]=hole
        hole_count+=1
    }
    count:=0
    from:=bottom
    for hole in holes[:hole_count] {
        if hole.bottom>from {
            out[count]={from,hole.bottom}
            count+=1
        }
        from=max(from,hole.top)
    }
    if top>from {
        out[count]={from,top}
        count+=1
    }
    return count
}

// The fluid at a point, through the one contract its readers share (fluid_surface_at): the physics, and
// what draws, splashes or navigates it. False where no fluid's column holds the point, or where dry boxes
// take all of it.
fluid_sample :: proc(w:^World,p:Vec3) -> (sample:Fluid_Sample,ok:bool) #no_bounds_check {
    fluid:=fluid_find(w,p)
    if fluid<0 {return}
    column:[FLUID_COLUMN_DRY+1]Fluid_Interval
    count:=fluid_column(w,fluid,p,&column)
    if count==0 {return}
    f:=&w.fluids[fluid]
    _,normal:=fluid_surface_at(w,f,p.x,p.z)
    sample={normal=normal,current=fluid_current(f,p),fluid=fluid_handle(w,fluid)}
    if p.y<column[0].bottom {
        sample.height,sample.normal=column[0].bottom,-UP
        return sample,true
    }
    sample.height=column[0].top
    for stretch in column[:count] {
        if p.y<stretch.bottom {break}
        sample.height=stretch.top
        if p.y<=stretch.top {sample.density=f.density}
    }
    return sample,true
}

// A fluid change reaches a box: it wakes the bodies there, and it is a change of the static world for
// whoever navigates through water (static_changes).
@(private)
fluid_changed :: proc(w:^World,box:Aabb) {
    static_log_push(w,box)
    for &body,i in w.bodies[:w.body_high] {
        if body.generation&1==0 || body.type!=.Dynamic || .Awake in body.flags {continue}
        for s:=body.shape_list;s>=0;s=w.shapes[s].next {
            if math.aabb_overlaps(w.shapes[s].aabb,box) {
                body_wake(w,i32(i))
                break
            }
        }
    }
}
