package foliage

import "core:math/linalg"
import "mirai:std/base"
import mm "mirai:std/math"

// The instances of a cell: its manual ones, and those the generator makes
// with the overrides applied. The generator is the first producer: a scatter
// of each type at its density, the same on every machine for a seed (only
// arithmetic, a square root and the deterministic sine of std/math).

// A point the generator makes: with its cell, its type and its index among
// those of its type there, the id an override names it by. The index of a
// point does not depend on how many there are: a lower density takes the
// last ones away and keeps the others where they were.
Generated :: struct {
    type:u32,
    point:u32,
    position:[2]f32, // x and z from the corner of its cell
    yaw:f32,         // radians around y
    tilt:f32,        // radians of lean
    tilt_turn:f32,   // radians around y of the side it leans to
    scale:[2]f32,    // across and along y
    offset:f32,      // metres along its y, over the ground
}

// How many points of a type a cell gets, and the stream of each one.
@(private)
scatter_key :: proc "contextless" (seed:u32,coord:[2]i32,type:u32) -> u64 {
    return base.hash_u64(u64(seed)<<32 ~ u64(type)) ~ base.hash_u64(u64(u32(coord.x)) | u64(u32(coord.y))<<32)
}

// Room for more elements past the end, grown by doubling. False without memory.
@(private)
room :: proc(array:^[dynamic]$T,more:int) -> bool {
    needed:=len(array)+more
    return needed<=cap(array) || reserve(array,max(needed,2*cap(array)))==nil
}

// The points of one type in a cell, appended to out. False, with none
// appended, without memory for them.
scatter :: proc(seed:u32,coord:[2]i32,t:Foliage_Type,out:^[dynamic]Generated) -> bool {
    key:=scatter_key(seed,coord,t.id)
    counter:=mm.rng_make(key)
    expected:=f64(t.density)*f64(CELL_SIZE)*f64(CELL_SIZE)
    count:=u32(expected)
    if f64(mm.random_f32(&counter))<expected-f64(count) {count+=1}
    if !room(out,int(count)) {return false}
    for point in 0..<count {
        r:=mm.rng_make(key,u64(point)+1)
        g:=Generated{type=t.id,point=point}
        g.position={mm.random_f32(&r)*CELL_SIZE,mm.random_f32(&r)*CELL_SIZE}
        g.yaw=mm.random_f32(&r)*t.yaw
        g.tilt=mm.random_f32(&r)*t.tilt
        g.tilt_turn=mm.random_f32(&r)*6.2831855
        across:=t.scale[0]+(t.scale[1]-t.scale[0])*mm.random_f32(&r)
        g.scale={across,across*(t.height[0]+(t.height[1]-t.height[0])*mm.random_f32(&r))}
        // After the values it had before: those of the points stay.
        g.offset=t.offset.x+(t.offset.y-t.offset.x)*mm.random_f32(&r)
        append(out,g)
    }
    return true
}

// The ground under a cell, in the space of its entity (Foliage_Ground):
// heights on a grid of samples by samples points over the cell, x first,
// NaN where there is none, and the weights of the layers of the terrain at
// each, none when they are not known. Without samples there is no ground
// known, and the plane y = 0 is taken.
Ground_Cell :: struct {
    samples:int,
    heights:[]f32,
    weights:[][4]u8,
}

// The height and normal of the ground at x and z from the corner of its
// cell, between the four samples around it; false where one has no ground.
ground_at :: proc "contextless" (g:Ground_Cell,x,z:f32) -> (height:f32,normal:[3]f32,ok:bool) {
    if g.samples<2 {return}
    step:=CELL_SIZE/f32(g.samples-1)
    u,v:=clamp(x/step,0,f32(g.samples-1)),clamp(z/step,0,f32(g.samples-1))
    c,r:=min(int(u),g.samples-2),min(int(v),g.samples-2)
    fu,fv:=u-f32(c),v-f32(r)
    a,b:=g.heights[r*g.samples+c],g.heights[r*g.samples+c+1]
    d,e:=g.heights[(r+1)*g.samples+c],g.heights[(r+1)*g.samples+c+1]
    if a-a!=0 || b-b!=0 || d-d!=0 || e-e!=0 {return}
    height=a+(b-a)*fu+(d-a)*fv+(a-b-d+e)*fu*fv
    dx:=((b-a)+(a-b-d+e)*fv)/step
    dz:=((d-a)+(a-b-d+e)*fu)/step
    normal=linalg.normalize([3]f32{-dx,1,-dz})
    return height,normal,true
}

// The weights of the layers of the terrain at x and z from the corner of its
// cell, from 0 to 1, between the four samples around it; false where they are
// not known or one has no layers.
ground_weights_at :: proc "contextless" (g:Ground_Cell,x,z:f32) -> (w:[4]f32,ok:bool) {
    if g.samples<2 || len(g.weights)<g.samples*g.samples {return}
    step:=CELL_SIZE/f32(g.samples-1)
    u,v:=clamp(x/step,0,f32(g.samples-1)),clamp(z/step,0,f32(g.samples-1))
    c,r:=min(int(u),g.samples-2),min(int(v),g.samples-2)
    fu,fv:=u-f32(c),v-f32(r)
    corners:=[4][4]u8{g.weights[r*g.samples+c],g.weights[r*g.samples+c+1],g.weights[(r+1)*g.samples+c],g.weights[(r+1)*g.samples+c+1]}
    share:=[4]f32{(1-fu)*(1-fv),fu*(1-fv),(1-fu)*fv,fu*fv}
    for corner,k in corners {
        if int(corner[0])+int(corner[1])+int(corner[2])+int(corner[3])==0 {return}
        w+=share[k]*[4]f32{f32(corner[0]),f32(corner[1]),f32(corner[2]),f32(corner[3])}/255
    }
    return w,true
}

@(private)
quat_turn :: proc "contextless" (axis:[3]f32,angle:f32) -> mm.Quat {
    s,c:=mm.sincos_det(angle*0.5)
    return quaternion(w=c,x=axis.x*s,y=axis.y*s,z=axis.z*s)
}

// The rotation of a generated instance: its yaw, then its lean, then as much
// of the slope of the ground as its type aligns it with.
generated_rotation :: proc "contextless" (g:Generated,align:f32,normal:[3]f32) -> mm.Quat {
    yaw:=quat_turn({0,1,0},g.yaw)
    s,c:=mm.sincos_det(g.tilt_turn)
    lean:=quat_turn({c,0,s},g.tilt)
    return ground_slope(align,normal)*lean*yaw
}

// The turn from up to a normal of the ground, scaled by align (0 to 1).
ground_slope :: proc "contextless" (align:f32,normal:[3]f32) -> mm.Quat {
    up:=[3]f32{0,1,0}
    n:=normal
    length:=linalg.length(n)
    if align<=0 || length<1e-6 {return 1}
    n/=length
    // Between up and the normal, scaled by align: half the angle as a quaternion.
    half:=linalg.normalize(up+n) if linalg.dot(up,n)>-0.999 else [3]f32{1,0,0}
    axis:=linalg.cross(up,half)
    slope:=mm.Quat(quaternion(w=linalg.dot(up,half),x=axis.x,y=axis.y,z=axis.z))
    if align<1 {slope=linalg.normalize(mm.quat_nlerp(1,slope,align))}
    return slope
}

// An instance as a cell shows it: its type, where it is in the space of the
// entity, its rotation and its scales. id, what names it in its cell while the
// source keeps it: a manual one has MANUAL and its own id
// (Foliage_Instance.id), which an edit of its cell does not change; a
// generated one its type in the high half and its point, which stay while the
// seed and the type do.
Placed :: struct {
    type:u32,
    position:[3]f32,
    rotation:mm.Quat,
    scale:[2]f32,
    id:u64,
}
MANUAL :: u64(1) << 63

generated_id :: proc "contextless" (type,point:u32) -> u64 {return u64(type)<<32 | u64(point)}

@(private)
placed_of :: proc "contextless" (coord:[2]i32,b:Foliage_Instance,type:u32,id:u64) -> Placed {
    return {type=type,position=cell_corner(coord)+b.position,rotation=mm.quat_unpack(u64(b.rotation),10),scale=b.scale,id=id}
}

// Scratch of cell_expand, kept by whoever expands many cells.
Expand_Scratch :: struct {
    points:[dynamic]Generated,
    matched:[dynamic]bool, // of each override of the cell
}

expand_scratch_destroy :: proc(e:^Expand_Scratch) {delete(e.points);delete(e.matched)}

// Where an instance of a cell stands: with INSTANCE_GROUNDED, `ground` over
// the ground under it where there is one; with INSTANCE_ALIGNED also leaned
// with it as much as its type aligns, so that it follows a ground that changes.
@(private)
placed_grounded :: proc "contextless" (s:^Source,coord:[2]i32,b:Foliage_Instance,type:u32,id:u64,ground:Ground_Cell) -> Placed {
    p:=placed_of(coord,b,type,id)
    if b.flags&INSTANCE_GROUNDED!=0 {
        h,normal,ok:=ground_at(ground,b.position.x,b.position.z)
        if ok {p.position.y=h+b.ground}
        if b.flags&INSTANCE_ALIGNED!=0 {
            if !ok {normal={0,1,0}}
            if t,_:=source_type(s,type);t!=nil {p.rotation=ground_slope(t.align,normal)*p.rotation}
        }
    }
    return p
}

// The instances a cell shows, appended to out, and the indices of its
// overrides whose generated instance the generator does not make (orphans).
// A generated instance stands on the ground and leans with it; where the
// ground is known and there is none (a hole, off the terrain) it is not
// there, nor where the rule of its type does not take that ground; it
// stands its offset along its y over it. Overrides are in the order of type
// and point, as the points of a type are: each type walks its own range of
// them once. The ids in removed (in order: those taken out in play,
// Foliage_Removed) are not there; one that names nothing of the cell takes
// nothing out. False, with nothing appended, without memory: each part
// takes the room of all it appends before it writes.
cell_expand :: proc(s:^Source,cell:^Cell,ground:Ground_Cell,out:^[dynamic]Placed,orphans:^[dynamic]int,scratch:^Expand_Scratch,removed:[]u64={}) -> bool {
    first:=len(out)
    clear(&scratch.matched)
    if !room(out,len(cell.manual)) || !room(orphans,len(cell.overrides)) || resize(&scratch.matched,len(cell.overrides))!=nil {return false}
    for b in cell.manual {append(out,placed_grounded(s,cell.coord,b,b.type,MANUAL | u64(b.id),ground))}
    if cell.generate {
        for t in s.types {
            clear(&scratch.points)
            // A point gives one instance at most.
            if !scatter(s.info.seed,cell.coord,t,&scratch.points) || !room(out,len(scratch.points)) {
                base.truncate(out,first)
                return false
            }
            at:=override_lower(cell,t.id,0)
            for g in scratch.points {
                for at<len(cell.overrides) && cell.overrides[at].type==t.id && cell.overrides[at].point<g.point {at+=1}
                if at<len(cell.overrides) && cell.overrides[at].type==t.id && cell.overrides[at].point==g.point {
                    scratch.matched[at]=true
                    o:=cell.overrides[at]
                    switch o.kind {
                    case .Deleted:
                    case .Moved:    append(out,placed_grounded(s,cell.coord,o.instance,g.type,generated_id(g.type,g.point),ground))
                    case .Replaced: append(out,placed_grounded(s,cell.coord,o.instance,o.instance.type,generated_id(g.type,g.point),ground))
                    }
                    continue
                }
                height:f32=0
                normal:=[3]f32{0,1,0}
                if ground.samples>0 {
                    h,n,ok:=ground_at(ground,g.position.x,g.position.y)
                    if !ok {continue}
                    height,normal=h,n
                }
                if t.rule.enabled {
                    weights,known:=ground_weights_at(ground,g.position.x,g.position.y)
                    if !rule_allows(t,height,normal,weights,known) {continue}
                }
                x,z:=g.position.x+f32(cell.coord.x)*CELL_SIZE,g.position.y+f32(cell.coord.y)*CELL_SIZE
                rotation:=generated_rotation(g,t.align,normal)
                position:=[3]f32{x,height,z}
                if g.offset!=0 {position+=mm.quat_rotate(rotation,{0,g.offset,0})}
                append(out,Placed{type=g.type,position=position,rotation=rotation,scale=g.scale,id=generated_id(g.type,g.point)})
            }
        }
    }
    for matched,i in scratch.matched {if !matched {append(orphans,i)}}
    if len(removed)==0 {return true}
    kept:=first
    for p in out[first:] {
        if ids_have(removed,p.id) {continue}
        out[kept]=p
        kept+=1
    }
    base.truncate(out,kept)
    return true
}
