package foliage

import "base:intrinsics"
import "core:math/linalg"
import "core:slice"
import "mirai:std/base"
import mm "mirai:std/math"

// The instances of a cell: its manual ones, and those the generator makes
// with the overrides applied. The generator is the first producer: the points
// of each type at its density, spread evenly over the cell, kept apart by the
// radius of their types and thinned by the density of the cell, the layers of
// the ground and what keeps foliage out. It is the same on every machine for a
// seed: only integer arithmetic, a square root and the deterministic sine of
// std/math.

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
    chance:f32,      // 0 to 1: it stands where the density there is above it
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

// The second dimension of the Sobol sequence at index i, as a fraction of 2^32.
@(private)
sobol_second :: proc "contextless" (i:u32) -> u32 {
    r,v,i:=u32(0),u32(1)<<31,i
    for i!=0 {
        if i&1!=0 {r~=v}
        i>>=1
        v~=v>>1
    }
    return r
}

// A nested uniform (Owen) scramble of a fraction of 2^32: each bit flips by a
// hash of the bits above it, so a set stratified in base 2 stays so.
@(private)
owen_scramble :: proc "contextless" (x,seed:u32) -> u32 {
    v:=intrinsics.reverse_bits(x)+seed
    v~=v*0x6c50b47c
    v~=v*0xb82f1e52
    v~=v*0xc7afe638
    v~=v*0x8d22f6e6
    return intrinsics.reverse_bits(v)
}

// The points of one type in a cell, appended to out. Their places are the
// first points of a (0,2) sequence of base 2, scrambled by the cell and the
// type: however many there are, they cover the cell as a jittered grid does,
// without the clumps and gaps of points at random. False, with none appended,
// without memory for them.
scatter :: proc(seed:u32,coord:[2]i32,t:Foliage_Type,out:^[dynamic]Generated) -> bool {
    key:=scatter_key(seed,coord,t.id)
    counter:=mm.rng_make(key)
    expected:=f64(t.density)*f64(CELL_SIZE)*f64(CELL_SIZE)
    count:=u32(expected)
    if f64(mm.random_f32(&counter))<expected-f64(count) {count+=1}
    if !room(out,int(count)) {return false}
    scramble:=base.hash_u64(key)
    for point in 0..<count {
        r:=mm.rng_make(key,u64(point)+1)
        g:=Generated{type=t.id,point=point}
        across:=owen_scramble(intrinsics.reverse_bits(point),u32(scramble))
        along:=owen_scramble(sobol_second(point),u32(scramble>>32))
        g.position=[2]f32{f32(across>>8),f32(along>>8)}*(CELL_SIZE/16777216.0)
        g.yaw=mm.random_f32(&r)*t.yaw
        g.tilt=mm.random_f32(&r)*t.tilt
        g.tilt_turn=mm.random_f32(&r)*6.2831855
        scale:=t.scale[0]+(t.scale[1]-t.scale[0])*mm.random_f32(&r)
        g.scale={scale,scale*(t.height[0]+(t.height[1]-t.height[0])*mm.random_f32(&r))}
        g.offset=t.offset.x+(t.offset.y-t.offset.x)*mm.random_f32(&r)
        g.chance=mm.random_f32(&r)
        append(out,g)
    }
    return true
}

// The ground under a cell, in the space of its entity (Foliage_Ground):
// heights on a grid of samples by samples points over the cell, x first,
// NaN where there is none, and the weights of the layers of the terrain at
// each, none when they are not known; and where foliage is kept out of it
// (Foliage_Keep_Out), none when nothing keeps it out. Without samples the
// plane y = 0 is the ground, unless absent: the world has a ground and none
// is known under the cell (not read yet, or none there), and no generated
// instance stands there.
Ground_Cell :: struct {
    samples:int,
    heights:[]f32,
    weights:[][4]u8,
    kept:[]u64, // KEEP_OUT_SIDE squares per side, x first, a bit each: set where foliage is kept out
    absent:bool,
}

KEEP_OUT_SIDE :: 64 // squares per side of a cell where foliage is kept out or not, as its centre is
KEEP_OUT_WORDS :: KEEP_OUT_SIDE*KEEP_OUT_SIDE/64

// Whether foliage is kept out at x and z from the corner of its cell; past
// its border, as the nearest square inside it is.
kept_out :: proc "contextless" (g:Ground_Cell,x,z:f32) -> bool {
    if len(g.kept)<KEEP_OUT_WORDS {return false}
    step:=CELL_SIZE/KEEP_OUT_SIDE
    k:=clamp(int(z/step),0,KEEP_OUT_SIDE-1)*KEEP_OUT_SIDE+clamp(int(x/step),0,KEEP_OUT_SIDE-1)
    return g.kept[k>>6]>>(uint(k)&63)&1!=0
}

// How much of the density of its types a cell generates at x and z from its
// corner, from 0 to 1, between the samples of its density around it; past
// its border, as at the nearest point of it.
cell_density_at :: proc "contextless" (cell:^Cell,x,z:f32) -> f32 {
    n:=DENSITY_SAMPLES
    if len(cell.density)!=n*n {return 1}
    step:=CELL_SIZE/f32(n-1)
    u,v:=clamp(x/step,0,f32(n-1)),clamp(z/step,0,f32(n-1))
    c,r:=min(int(u),n-2),min(int(v),n-2)
    fu,fv:=u-f32(c),v-f32(r)
    d:=cell.density
    a,b:=f32(d[r*n+c]),f32(d[r*n+c+1])
    e,f:=f32(d[(r+1)*n+c]),f32(d[(r+1)*n+c+1])
    return ((a+(b-a)*fu)*(1-fv)+(e+(f-e)*fu)*fv)/255
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
    matched:[dynamic]bool,  // of each override of the cell
    spaced:[dynamic]Spaced, // the points of one type with a radius, in the cells around
    stood:[dynamic]Spaced,  // those that stand of the types with a radius placed before
    fresh:[dynamic]Spaced,  // those that stand of the type being placed
    standing:[dynamic]u32,  // the points of the cell that stand, of each type with a radius in turn
    ranges:[dynamic][2]int, // of standing, by the index of the type in its source
    order:[dynamic]Spaced_Type,
    grid,stood_grid:Grid,
}

expand_scratch_destroy :: proc(e:^Expand_Scratch) {
    delete(e.points);delete(e.matched);delete(e.spaced);delete(e.stood);delete(e.fresh)
    delete(e.standing);delete(e.ranges);delete(e.order)
    delete(e.grid.heads);delete(e.grid.next);delete(e.stood_grid.heads);delete(e.stood_grid.next)
}

// A point of a type with a radius, from the corner of the cell expanded,
// which is in the middle of the 3 by 3 cells its points come from.
@(private)
Spaced :: struct {
    at:[2]f32,
    reach:f32, // its radius times its scale across
    chance:f32,
    point:u32,
    cell:u8,   // of the 3 by 3, x first: 4 is the cell expanded
}

@(private)
Spaced_Type :: struct {radius:f32,id:u32,index:int}

// Which of two points of a type keeps its place when they are too near: the
// one of the lower index, or of the cell first in z and then x.
@(private)
spaced_before :: proc "contextless" (a,b:Spaced) -> bool {return a.point<b.point || a.point==b.point && a.cell<b.cell}

// Buckets over the 3 by 3 cells around the one expanded, at least as wide as
// the reaches of two points together: a point meets only those of the 9
// buckets around its own.
@(private)
Grid :: struct {
    heads:[dynamic]i32,
    next:[dynamic]i32, // of each point added, the one added before it to its bucket
    side:int,
    size:f32,
}
@(private) GRID_SIDE_MAX :: 192

@(private)
grid_reset :: proc(g:^Grid,reach:f32) -> bool {
    g.side=clamp(int(3*CELL_SIZE/max(reach,1e-3)),1,GRID_SIDE_MAX)
    g.size=3*CELL_SIZE/f32(g.side)
    clear(&g.next)
    if resize(&g.heads,g.side*g.side)!=nil {return false}
    for &h in g.heads {h=-1}
    return true
}

@(private)
grid_bucket :: proc "contextless" (g:^Grid,at:[2]f32) -> [2]int {
    b:=(at+CELL_SIZE)/g.size
    return {clamp(int(b.x),0,g.side-1),clamp(int(b.y),0,g.side-1)}
}

// Adds the next point to the grid, the one of index len(g.next).
@(private)
grid_add :: proc(g:^Grid,at:[2]f32) -> bool {
    b:=grid_bucket(g,at)
    k:=b.y*g.side+b.x
    if _,error:=append(&g.next,g.heads[k]);error!=nil {return false}
    g.heads[k]=i32(len(g.next)-1)
    return true
}

@(private)
Block :: enum u8 {
    Same_Cell,   // by those of the cell of the point
    Other_Cells, // by those of the other cells that keep their place before it
    Any,
}

// Whether one of points, those the grid holds, is nearer to p than their
// two reaches.
@(private)
grid_blocks :: proc "contextless" (g:^Grid,points:[]Spaced,p:Spaced,by:Block) -> bool {
    b:=grid_bucket(g,p.at)
    for z in max(b.y-1,0)..=min(b.y+1,g.side-1) {
        for x in max(b.x-1,0)..=min(b.x+1,g.side-1) {
            for i:=g.heads[z*g.side+x];i>=0;i=g.next[i] {
                q:=points[i]
                switch by {
                case .Same_Cell: if q.cell!=p.cell {continue}
                case .Other_Cells: if q.cell==p.cell || !spaced_before(q,p) {continue}
                case .Any:
                }
                d:=q.at-p.at
                r:=q.reach+p.reach
                if d.x*d.x+d.y*d.y<r*r {return true}
            }
        }
    }
    return false
}

// Whether a point of a type stands on the ground of a cell, at at from its
// corner, and where: not where the ground has none, its rule does not take
// that ground, its chance is not under the density there or foliage is kept
// out. Past the border of the cell, the ground, the density and what keeps
// foliage out at the nearest point of the border stand for those there.
point_stands :: proc "contextless" (cell:^Cell,t:Foliage_Type,chance:f32,ground:Ground_Cell,at:[2]f32) -> (height:f32,normal:[3]f32,ok:bool) {
    normal={0,1,0}
    if ground.samples>0 {
        found:bool
        height,normal,found=ground_at(ground,at.x,at.y)
        if !found {return}
    }
    if chance>=cell_density_at(cell,at.x,at.y) || kept_out(ground,at.x,at.y) {return}
    if t.rule.enabled {
        weights,known:=ground_weights_at(ground,at.x,at.y)
        if !rule_allows(t,height,normal,weights,known,chance) {return}
    }
    return height,normal,true
}

// The points of a cell that stand, of each type with a radius, into
// e.standing by e.ranges. The types go from the widest radius (the lower id
// first among equal ones). A point keeps apart from those of its type, in
// its cell in the order of their index and across the border from those
// that keep their place before it; then, if it stands, from those that stand
// of the types before. Only the place, the scale and the stream of the points
// of the cells around are known here, not their ground: whether one stands
// is told at the border of this cell nearest to it. False without memory.
@(private)
spaced_stand :: proc(s:^Source,cell:^Cell,ground:Ground_Cell,e:^Expand_Scratch) -> bool {
    clear(&e.order);clear(&e.standing);clear(&e.stood)
    if resize(&e.ranges,len(s.types))!=nil {return false}
    for &r in e.ranges {r={}}
    widest:f32
    for t,i in s.types {
        if t.radius<=0 {continue}
        if _,error:=append(&e.order,Spaced_Type{t.radius,t.id,i});error!=nil {return false}
        widest=max(widest,t.radius*t.scale[1])
    }
    if len(e.order)==0 {return true}
    slice.sort_by(e.order[:],proc(a,b:Spaced_Type) -> bool {return a.radius>b.radius || a.radius==b.radius && a.id<b.id})
    // How far from the cell a point can keep one of it away.
    margin:=2*widest
    if !grid_reset(&e.stood_grid,margin) {return false}
    for o in e.order {
        t:=s.types[o.index]
        clear(&e.spaced);clear(&e.fresh)
        if !grid_reset(&e.grid,margin) {return false}
        for k in 0..<9 {
            d:=[2]i32{i32(k%3)-1,i32(k/3)-1}
            clear(&e.points)
            if !scatter(s.info.seed,cell.coord+d,t,&e.points) {return false}
            for g in e.points {
                p:=Spaced{at=g.position+[2]f32{f32(d.x),f32(d.y)}*CELL_SIZE,reach=t.radius*g.scale[0],chance=g.chance,point=g.point,cell=u8(k)}
                if grid_blocks(&e.grid,e.spaced[:],p,.Same_Cell) {continue}
                if _,error:=append(&e.spaced,p);error!=nil || !grid_add(&e.grid,p.at) {return false}
            }
        }
        first:=len(e.standing)
        for p in e.spaced {
            if p.at.x< -margin || p.at.y< -margin || p.at.x>CELL_SIZE+margin || p.at.y>CELL_SIZE+margin {continue}
            if grid_blocks(&e.grid,e.spaced[:],p,.Other_Cells) {continue}
            if _,_,stands:=point_stands(cell,t,p.chance,ground,p.at);!stands {continue}
            if grid_blocks(&e.stood_grid,e.stood[:],p,.Any) {continue}
            if _,error:=append(&e.fresh,p);error!=nil {return false}
            if p.cell==4 {if _,error:=append(&e.standing,p.point);error!=nil {return false}}
        }
        e.ranges[o.index]={first,len(e.standing)}
        for p in e.fresh {
            if _,error:=append(&e.stood,p);error!=nil || !grid_add(&e.stood_grid,p.at) {return false}
        }
    }
    return true
}

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
    if cell.generate && !ground.absent {
        if !spaced_stand(s,cell,ground,scratch) {
            base.truncate(out,first)
            return false
        }
        for t,i in s.types {
            standing:=scratch.standing[scratch.ranges[i][0]:scratch.ranges[i][1]]
            next:=0
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
                if t.radius>0 {
                    for next<len(standing) && standing[next]<g.point {next+=1}
                    if next==len(standing) || standing[next]!=g.point {continue}
                }
                height,normal,stands:=point_stands(cell,t,g.chance,ground,g.position)
                if !stands {continue}
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
