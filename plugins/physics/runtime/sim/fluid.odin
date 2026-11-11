package mirai_physics

import cmath "core:math"
import "mirai:std/base"
import math "mirai:std/math"

Fluid_Handle :: distinct base.Handle

Fluid_Shape :: enum u32 {
    Plane, // everything under the height of its position: an ocean
    Box,   // its top face is the surface: a lake in its basin, a pool
    Path,  // water along the curve of its points, with their width, depth and speed (fluid_path.odin)
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
    current:Vec3,      // m/s in the frame of the volume; of a path, across (x) and up (y), z zero
    priority:i32,
    user_data:u64,
    waves:Fluid_Waves, // of a plane, in the world; a box and a path hold still
}

// Slot of a fluid; the points of a path are in World.fluid_paths. Plain data, copied by snapshots.
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
    path_count:u32,
    bounds:Aabb,    // the box it fills; a plane reaches without end sideways and down
    waves:Fluid_Waves,
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
fluid_desc_valid :: proc "contextless" (d:Fluid_Desc,path:[]Path_Point) -> bool {
    if !finite(d.position) || !finite(d.current) || !(abs(d.yaw)<=max(f32)) {return false}
    if !(d.density>=0 && d.density<=max(f32)) {return false}
    if !waves_valid(d.waves) {return false}
    switch d.shape {
    case .Plane: return d.density>0
    case .Box:   return d.waves.count==0 && d.half_extents.x>0 && d.half_extents.y>0 && d.half_extents.z>0 && finite(d.half_extents)
    case .Path:  return d.waves.count==0 && d.density>0 && d.current.z==0 && path_valid(path)
    }
    return false
}

// The points of a path, whose curve its surface follows (math.path_at), each no higher than the one
// before; zero for another fluid or a handle that is gone.
fluid_path :: proc(w:^World,h:Fluid_Handle,out:^[FLUID_PATH_POINTS]Path_Point) -> int {
    f,index:=fluid_read(w,h)
    if f==nil {return 0}
    return copy(out[:],fluid_points(w,index))
}

@(private)
fluid_points :: #force_inline proc "contextless" (w:^World,index:i32) -> []Path_Point {
    return w.fluid_paths[index][:w.fluids[index].path_count]
}

fluid_valid :: proc(w:^World,h:Fluid_Handle) -> bool {
    f,_:=fluid_read(w,h)
    return f!=nil
}

// Null when the description is not usable (a dry plane, a box without size or with waves, a dry path, one
// with waves or a current along it, with fewer than two points or more than FLUID_PATH_POINTS, a point
// without width or depth or over the one before it, values that are not finite, waves of no length or of no
// direction) or World_Desc.fluid_capacity is exhausted. path: the points of a Path, in the world; one higher
// than the one before is lowered to it.
fluid_create :: proc(w:^World,desc:Fluid_Desc,path:[]Path_Point={}) -> Fluid_Handle {
    if !fluid_desc_valid(desc,path) || !fluid_scratch_make(w) {return {}}
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
    stamp(w,.Fluids,index)
    fluid_put(w,index,desc,path,w.fluids[index].generation+1)
    fluid_changed(w,w.fluids[index].bounds)
    return fluid_handle(w,index)
}

fluid_destroy :: proc(w:^World,h:Fluid_Handle) {
    f,index:=fluid_get(w,h)
    if f==nil {return}
    fluid_changed(w,f.bounds)
    f^={generation=f.generation+1,next_free=w.fluid_free}
    w.fluid_free=index
    w.fluid_count-=1
}

// Changes a fluid in place, as a room that floods; wakes what it covered and what it covers now. False,
// changing nothing, for a description that is not usable.
fluid_set :: proc(w:^World,h:Fluid_Handle,desc:Fluid_Desc,path:[]Path_Point={}) -> bool {
    f,index:=fluid_get(w,h)
    if f==nil || !fluid_desc_valid(desc,path) {return false}
    before:=f.bounds
    fluid_put(w,index,desc,path,f.generation)
    fluid_changed(w,before)
    fluid_changed(w,f.bounds)
    return true
}

fluid_desc :: proc(w:^World,h:Fluid_Handle) -> (desc:Fluid_Desc,ok:bool) {
    f,_:=fluid_read(w,h)
    if f==nil {return}
    return {shape=f.shape,position=f.position,yaw=f.yaw,half_extents=f.half_extents,density=f.density,current=f.current,priority=f.priority,user_data=f.user_data,waves=f.waves},true
}

// The box a fluid fills; a plane reaches without end sideways and down.
fluid_bounds :: proc(w:^World,h:Fluid_Handle) -> Aabb {
    f,_:=fluid_read(w,h)
    return f!=nil?f.bounds:{}
}

// The live fluids and dry boxes whose bounds meet `box`, in slot order; writes up to len(out) of them after
// the first `skip` and returns how many there are in all.
fluids_overlap :: proc(w:^World,box:Aabb,out:[]Fluid_Handle,skip:=0) -> int {
    count:=0
    for &f,i in w.fluids[:w.fluid_high] {
        if f.generation&1==0 || !math.aabb_overlaps(f.bounds,box) {continue}
        if at:=count-skip;at>=0 && at<len(out) {out[at]=fluid_handle(w,i32(i))}
        count+=1
    }
    return count
}

// Whether two fluids or dry boxes meet: a point that both columns hold between bottom and surface, by the
// rule every reader follows (fluid_spot). It looks at points of each about FLUID_MEET_STEP apart over its
// surface, its middle and its floor, just inside them; a plane holds every point under it. False for a
// handle that is gone.
fluids_meet :: proc(w:^World,a,b:Fluid_Handle) -> bool {
    fa,ia:=fluid_read(w,a)
    fb,ib:=fluid_read(w,b)
    if fa==nil || fb==nil || !math.aabb_overlaps(fa.bounds,fb.bounds) {return false}
    if fa.shape==.Plane && fb.shape==.Plane {return true}
    return fluid_reaches(w,ia,ib) || fluid_reaches(w,ib,ia)
}

@(private) FLUID_MEET_STEP :: 1     // m between the points fluids_meet looks at
@(private) FLUID_MEET_POINTS :: 256 // most of them along a side of a box or a segment of a path
@(private) FLUID_MEET_INSET :: 0.999

// Whether a point of fluid `from`, of those fluids_meet looks at, is held by fluid `into`.
@(private)
fluid_reaches :: proc "contextless" (w:^World,from,into:i32) -> bool {
    held :: proc "contextless" (w:^World,into:i32,p:Vec3) -> bool {
        spot:=fluid_spot(w,into,p)
        return spot.inside && p.y>=spot.bottom && p.y<=spot.top
    }
    pieces :: proc "contextless" (long:f32) -> int {return clamp(int(cmath.ceil(long/FLUID_MEET_STEP)),1,FLUID_MEET_POINTS)}
    f:=&w.fluids[from]
    switch f.shape {
    case .Plane:
    case .Box:
        h:=f.half_extents*FLUID_MEET_INSET
        s,c:=cmath.sincos(f.yaw)
        nx,nz:=pieces(2*h.x),pieces(2*h.z)
        for i in 0..=nx {
            for k in 0..=nz {
                l:=Vec3{h.x*(2*f32(i)/f32(nx)-1),0,h.z*(2*f32(k)/f32(nz)-1)}
                for y in ([3]f32{-h.y,0,h.y}) {
                    if held(w,into,f.position+{c*l.x+s*l.z,y,c*l.z-s*l.x}) {return true}
                }
            }
        }
    case .Path:
        points:=fluid_points(w,from)
        for j in 0..<len(points)-1 {
            n:=pieces(length(points[j+1].position-points[j].position))
            for k in 0..=n {
                p,tangent:=math.path_at(points,j,f32(k)/f32(n))
                across:=0.5*p.width*FLUID_MEET_INSET*normalize(Vec3{-tangent.z,0,tangent.x})
                for side in ([3]f32{-1,0,1}) {
                    for depth in ([3]f32{1-FLUID_MEET_INSET,0.5,FLUID_MEET_INSET}) {
                        if held(w,into,p.position+side*across-{0,depth*p.height,0}) {return true}
                    }
                }
            }
        }
    }
    return false
}

// Makes slot index the fluid of a valid description, of that generation.
@(private)
fluid_put :: proc "contextless" (w:^World,index:i32,d:Fluid_Desc,path:[]Path_Point,generation:u32) {
    f:=&w.fluids[index]
    f^={user_data=d.user_data,position=d.position,current=d.current,yaw=d.yaw,density=d.density,priority=d.priority,shape=d.shape,waves=waves_of(d.waves),generation=generation,next_free=-1}
    f.reach=waves_reach(&f.waves)
    switch d.shape {
    case .Plane:
        f.bounds={{-FLUID_FAR,-FLUID_FAR,-FLUID_FAR},{FLUID_FAR,f.position.y+f.reach,FLUID_FAR}}
    case .Box:
        f.half_extents=d.half_extents
        s,c:=cmath.sincos(f.yaw)
        h:=f.half_extents
        reach:=Vec3{abs(c)*h.x+abs(s)*h.z,h.y,abs(s)*h.x+abs(c)*h.z}
        f.bounds={f.position-reach,f.position+reach}
    case .Path:
        points:=&w.fluid_paths[index]
        f.path_count=u32(copy(points[:],path))
        for k in 1..<f.path_count {points[k].position.y=min(points[k].position.y,points[k-1].position.y)}
        f.bounds=path_aabb(points[:f.path_count])
    }
}

@(private) FLUID_FAR :: 1e30 // m: how far a plane reaches sideways and down

// The point in the frame of a box, turned by its yaw.
@(private)
fluid_local :: #force_inline proc "contextless" (f:^Fluid,p:Vec3) -> Vec3 {
    s,c:=cmath.sincos(f.yaw)
    d:=p-f.position
    return {c*d.x-s*d.z,d.y,s*d.x+c*d.z}
}

@(private)
fluid_box_column :: #force_inline proc "contextless" (f:^Fluid,p:Vec3) -> bool {
    l:=fluid_local(f,p)
    return abs(l.x)<=f.half_extents.x && abs(l.z)<=f.half_extents.z
}

// What a fluid is over (x, z) of a point at the time of the world: whether its column holds the point, its
// free surface there (its waves over its still surface) with its normal, its bottom and its current; of a
// path, the segment it is nearest on, looked for from the segment `hint` (path_spot). The one place that
// knows its shape, which every reader follows.
@(private)
Fluid_Spot :: struct {
    top,bottom:f32,
    normal,current:Vec3,
    segment:i32,
    inside:bool,
}

@(private)
fluid_spot :: proc "contextless" (w:^World,index:i32,p:Vec3,hint:i32=-1) -> (spot:Fluid_Spot) #no_bounds_check {
    f:=&w.fluids[index]
    switch f.shape {
    case .Path:
        at:=path_spot(fluid_points(w,index),p.x,p.z,hint)
        y:=at.point.position.y
        return {top=y,bottom=y-at.point.height,normal=path_normal(at.along),current=path_current(at,f.current),segment=at.segment,inside=at.inside}
    case .Box:
        spot.inside,spot.top,spot.bottom,spot.normal=fluid_box_column(f,p),f.position.y+f.half_extents.y,f.position.y-f.half_extents.y,UP
    case .Plane:
        spot.inside,spot.top,spot.bottom,spot.normal=true,f.position.y,-FLUID_FAR,UP
        if f.waves.count>0 {
            origin:=wave_origin(p.x,p.z)
            terms,count:=wave_terms(&f.waves,w.time,origin)
            height,normal:=wave_surface(terms[:count],f32(f64(p.x)-origin.x),f32(f64(p.z)-origin.y))
            spot.top+=height
            spot.normal=normal
        }
    }
    s,c:=cmath.sincos(f.yaw)
    spot.current={c*f.current.x+s*f.current.z,f.current.y,c*f.current.z-s*f.current.x}
    return
}

// The surface of a fluid or the top of a dry box over (x, z) (fluid_spot); false for a handle that is gone.
fluid_surface :: proc(w:^World,h:Fluid_Handle,x,z:f32) -> (height:f32,normal:Vec3,ok:bool) {
    f,index:=fluid_read(w,h)
    if f==nil {return}
    spot:=fluid_spot(w,index,{x,0,z})
    return spot.top,spot.normal,true
}

// Whether a point is in the volume of a fluid or a dry box: in its column, between its bottom and its surface.
// Dry boxes do not take a fluid out here: fluid_sample does.
fluid_holds :: proc(w:^World,h:Fluid_Handle,p:Vec3) -> bool {
    f,index:=fluid_read(w,h)
    if f==nil {return false}
    spot:=fluid_spot(w,index,p)
    return spot.inside && p.y>=spot.bottom && p.y<=spot.top
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

// Of the fluids whose column holds the point (a pool can stand over the sea), of the slots of `among` or of
// all, the one that holds it, else the nearest under it, else the nearest over it; then the one of higher
// priority, then the first. -1 without one.
@(private)
fluid_find :: proc "contextless" (w:^World,p:Vec3,among:[]i32=nil) -> (found:i32,found_spot:Fluid_Spot) #no_bounds_check {
    found=-1
    found_rank:=3
    found_distance:f32
    for k in 0..<(among==nil?int(w.fluid_high):len(among)) {
        i:=among==nil?i32(k):among[k]
        f:=&w.fluids[i]
        if f.generation&1==0 || f.density<=0 {continue}
        spot:=fluid_spot(w,i,p)
        if !spot.inside {continue}
        rank,distance:=0,f32(0)
        if p.y>spot.top {
            rank,distance=1,p.y-spot.top
        } else if p.y<spot.bottom {rank,distance=2,spot.bottom-p.y}
        if rank>found_rank || rank==found_rank && (distance>found_distance || distance==found_distance && f.priority<=w.fluids[found].priority) {continue}
        found,found_rank,found_distance,found_spot=i,rank,distance,spot
    }
    return
}

@(private) Fluid_Interval :: struct {bottom,top:f32}

// The stretches of the column of a point that hold the fluid, at its spot there, bottom up: the fluid less
// the dry boxes over it in priority. Returns how many.
@(private)
fluid_column :: proc "contextless" (w:^World,fluid:i32,spot:Fluid_Spot,p:Vec3,out:^[FLUID_COLUMN_DRY+1]Fluid_Interval) -> int #no_bounds_check {
    f:=&w.fluids[fluid]
    top,bottom:=spot.top,spot.bottom
    if !(top>bottom) {return 0}
    holes:[FLUID_COLUMN_DRY]Fluid_Interval
    hole_count:=0
    for &d in w.fluids[:w.fluid_high] {
        if d.generation&1==0 || d.density>0 || d.priority<=f.priority || !fluid_box_column(&d,p) {continue}
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

// The fluid at a point, through the one contract its readers share (fluid_spot): the physics, and what
// draws, splashes or navigates it. False where no fluid's column holds the point, or where dry boxes take
// all of it.
fluid_sample :: proc(w:^World,p:Vec3) -> (sample:Fluid_Sample,ok:bool) #no_bounds_check {
    fluid,spot:=fluid_find(w,p)
    if fluid<0 {return}
    column:[FLUID_COLUMN_DRY+1]Fluid_Interval
    count:=fluid_column(w,fluid,spot,p,&column)
    if count==0 {return}
    f:=&w.fluids[fluid]
    sample={normal=spot.normal,current=spot.current,fluid=fluid_handle(w,fluid)}
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
