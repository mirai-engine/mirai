package foliage

import "core:math/linalg"
import "core:slice"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg_lib "mirai:std/pcg"

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

// Room for more elements past the end, grown by doubling. False without memory.
@(private)
room :: proc(array:^[dynamic]$T,more:int) -> bool {
    needed:=len(array)+more
    return needed<=cap(array) || reserve(array,max(needed,2*cap(array)))==nil
}

// The most points the generator makes in a cell, of all its types: past it
// every type keeps the same share of its points (generated_share), and the
// cell is the foliage.cell_instances problem of whoever shows it.
CELL_GENERATED_MAX :: 1 << 18

// The share of the points of each type the generator makes in every cell of a
// source: 1, or less when their densities give more than CELL_GENERATED_MAX.
generated_share :: proc "contextless" (s:^Source) -> f32 {
    total:=f64(0)
    for t in s.types {total+=f64(t.density)*f64(CELL_SIZE)*f64(CELL_SIZE)}
    return total>CELL_GENERATED_MAX?f32(CELL_GENERATED_MAX/total):1
}

// The share of the points of a type a cell keeps: that of its source, times
// thin for a type without collision (what a lower detail draws of it).
type_share :: proc "contextless" (t:Foliage_Type,share,thin:f32) -> f32 {
    return t.collision==.None?share*clamp(thin,0,1):share
}

// The points of a type in a cell, scatter makes at most.
scatter_max :: proc "contextless" (t:Foliage_Type,share:f32) -> int {
    return int(f64(t.density)*f64(CELL_SIZE)*f64(CELL_SIZE)*f64(share))+1
}

// The points of one type in a cell, appended to out. Their places are the
// first points of a (0,2) sequence of base 2, scrambled by the cell and the
// type: however many there are, they cover the cell as a jittered grid does,
// without the clumps and gaps of points at random. Of share, the first of its
// points, which a lower share leaves where they were. False, with none
// appended, without memory for them.
scatter :: proc(seed:u32,coord:[2]i32,t:Foliage_Type,out:^[dynamic]Generated,share:=f32(1)) -> bool {
    key:=pcg_lib.scatter_key(seed,coord,t.id)
    count:=pcg_lib.scatter_count(key,f64(t.density)*f64(CELL_SIZE)*f64(CELL_SIZE)*f64(share))
    if !room(out,int(count)) {return false}
    scramble:=pcg_lib.scatter_scramble(key)
    for point in 0..<count {
        r:=pcg_lib.point_stream(key,point)
        g:=Generated{type=t.id,point=point}
        g.position=pcg_lib.scatter_point_unit(scramble,point)*CELL_SIZE
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
// each with the materials they are of, none when they are not known; and
// where foliage is kept out of it (Foliage_Keep_Out), none when nothing keeps
// it out. Without samples the plane y = 0 is the ground, unless absent: the
// world has a ground and none is known under the cell (not read yet, or none
// there), and no generated instance stands there. With keys it holds only
// the samples keys names (in order), and where one of the four around a
// point is not held the point has no ground.
Ground_Cell :: struct {
    samples:int,
    heights:[]f32,
    weights:[]Layer_Weights,
    layers:[]Ground_Layers, // what weights name
    kept:[]u64, // KEEP_OUT_SIDE squares per side, x first, a bit each: set where foliage is kept out
    keys:[]u16,
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

// The four samples of a grid of samples a side around x and z from the
// corner of its cell, x first, and how far the point is between them.
ground_around :: proc "contextless" (samples:int,x,z:f32) -> (corners:[4]int,fu,fv:f32) {
    step:=CELL_SIZE/f32(samples-1)
    u,v:=clamp(x/step,0,f32(samples-1)),clamp(z/step,0,f32(samples-1))
    c,r:=min(int(u),samples-2),min(int(v),samples-2)
    return {r*samples+c,r*samples+c+1,(r+1)*samples+c,(r+1)*samples+c+1},u-f32(c),v-f32(r)
}

// Where the ground keeps the four samples around x and z, in heights and
// weights; false when it does not keep one.
@(private)
ground_held :: proc "contextless" (g:Ground_Cell,x,z:f32) -> (at:[4]int,fu,fv:f32,ok:bool) {
    at,fu,fv=ground_around(g.samples,x,z)
    if len(g.keys)==0 {return at,fu,fv,true}
    for &k in at {
        low,high:=0,len(g.keys)
        for low<high {mid:=(low+high)/2;if int(g.keys[mid])<k {low=mid+1} else {high=mid}}
        if low==len(g.keys) || int(g.keys[low])!=k {return}
        k=low
    }
    return at,fu,fv,true
}

// The height and normal of the ground at x and z from the corner of its
// cell, between the four samples around it; false where one has no ground.
ground_at :: proc "contextless" (g:Ground_Cell,x,z:f32) -> (height:f32,normal:[3]f32,ok:bool) {
    if g.samples<2 {return}
    step:=CELL_SIZE/f32(g.samples-1)
    at,fu,fv,held:=ground_held(g,x,z)
    if !held {return}
    a,b,d,e:=g.heights[at[0]],g.heights[at[1]],g.heights[at[2]],g.heights[at[3]]
    if a-a!=0 || b-b!=0 || d-d!=0 || e-e!=0 {return}
    height=a+(b-a)*fu+(d-a)*fv+(a-b-d+e)*fu*fv
    dx:=((b-a)+(a-b-d+e)*fv)/step
    dz:=((d-a)+(a-b-d+e)*fu)/step
    normal=linalg.normalize([3]f32{-dx,1,-dz})
    return height,normal,true
}

// The weight of the layers of a mask (layer_mask of the layers of the
// ground) at x and z from the corner of its cell, from 0 to 1, between the
// four samples around it, each by the materials of its own ground; false
// where they are not known or one has no layers.
ground_layer_weight :: proc "contextless" (g:Ground_Cell,mask:^Layer_Mask,x,z:f32) -> (weight:f32,ok:bool) {
    if g.samples<2 || len(g.weights)<(len(g.keys)>0?len(g.keys):g.samples*g.samples) {return}
    at,fu,fv,held:=ground_held(g,x,z)
    if !held {return}
    corners:=[4]Layer_Weights{g.weights[at[0]],g.weights[at[1]],g.weights[at[2]],g.weights[at[3]]}
    share:=[4]f32{(1-fu)*(1-fv),fu*(1-fv),(1-fu)*fv,fu*fv}
    for corner,k in corners {
        w:=corner.weights
        if int(w[0])+int(w[1])+int(w[2])+int(w[3])==0 {return}
        bits:=mask[corner.layers]
        named:=0
        for i in 0..<4 {if bits&(1<<u8(i))!=0 {named+=int(w[i])}}
        weight+=share[k]*f32(named)/255
    }
    return weight,true
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
    color:u32, // with colored, its tint and wetness (render.batch_color), painted or given in play
    colored:bool,
}
MANUAL :: u64(1) << 63

generated_id :: pcg_lib.stable_id

@(private)
placed_of :: proc "contextless" (coord:[2]i32,b:Foliage_Instance,type:u32,id:u64) -> Placed {
    return {type=type,position=cell_corner(coord)+b.position,rotation=mm.quat_unpack(u64(b.rotation),10),scale=b.scale,id=id,color=b.color,colored=b.flags&INSTANCE_COLORED!=0}
}

// Scratch of cell_expand, kept by whoever expands many cells.
Expand_Scratch :: struct {
    points:[dynamic]Generated,
    matched:[dynamic]bool,  // of each override of the cell
    spaced:[dynamic]pcg_lib.Spacing_Point, // the points of one type with a radius, in the cells around
    stood:[dynamic]pcg_lib.Spacing_Point,  // those that stand of the types with a radius placed before
    fresh:[dynamic]pcg_lib.Spacing_Point,  // those that stand of the type being placed
    standing:[dynamic]u32,  // the points of the cell that stand, of each type with a radius in turn
    ranges:[dynamic][2]int, // of standing, by the index of the type in its source
    order:[dynamic]Spaced_Type,
    grid,stood_grid:pcg_lib.Spacing_Grid,
}

expand_scratch_destroy :: proc(e:^Expand_Scratch) {
    delete(e.points);delete(e.matched);delete(e.spaced);delete(e.stood);delete(e.fresh)
    delete(e.standing);delete(e.ranges);delete(e.order)
    pcg_lib.spacing_grid_destroy(&e.grid);pcg_lib.spacing_grid_destroy(&e.stood_grid)
}

@(private)
Spaced_Type :: struct {radius:f32,id:u32,index:int}

// The layers of the ground of a cell that the rule of a type names.
@(private)
type_mask :: proc "contextless" (t:Foliage_Type,ground:Ground_Cell) -> (mask:Layer_Mask) {
    if t.rule.enabled && t.rule.layers!={} {mask=layer_mask(t.rule,ground.layers)}
    return
}

// Whether a point of a type stands on the ground of a cell, at at from its
// corner, and where: not where the ground has none, its rule does not take
// that ground, its chance is not under the density there or foliage is kept
// out. Past the border of the cell, the ground, the density and what keeps
// foliage out at the nearest point of the border stand for those there.
point_stands :: proc "contextless" (cell:^Cell,t:Foliage_Type,mask:^Layer_Mask,chance:f32,ground:Ground_Cell,at:[2]f32) -> (height:f32,normal:[3]f32,ok:bool) {
    normal={0,1,0}
    if ground.samples>0 {
        found:bool
        height,normal,found=ground_at(ground,at.x,at.y)
        if !found {return}
    }
    if chance>=cell_density_at(cell,at.x,at.y) || kept_out(ground,at.x,at.y) {return}
    if t.rule.enabled {
        weight,known:=ground_layer_weight(ground,mask,at.x,at.y)
        if !rule_allows(t,height,normal,weight,known,chance) {return}
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
// is told at the border of this cell nearest to it. Each type gives share of
// its points (generated_share), never fewer for a lower detail: what stands
// is the same for whoever expands the cell. False without memory.
@(private)
spaced_stand :: proc(s:^Source,cell:^Cell,ground:Ground_Cell,e:^Expand_Scratch,share:=f32(1)) -> bool {
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
    if !pcg_lib.spacing_grid_reset(&e.stood_grid,CELL_SIZE,margin) {return false}
    for o in e.order {
        t:=s.types[o.index]
        mask:=type_mask(t,ground)
        clear(&e.spaced);clear(&e.fresh)
        if !pcg_lib.spacing_grid_reset(&e.grid,CELL_SIZE,margin) {return false}
        for k in 0..<9 {
            d:=[2]i32{i32(k%3)-1,i32(k/3)-1}
            clear(&e.points)
            if !scatter(s.info.seed,cell.coord+d,t,&e.points,share) {return false}
            for g in e.points {
                p:=pcg_lib.Spacing_Point{at=g.position+[2]f32{f32(d.x),f32(d.y)}*CELL_SIZE,reach=t.radius*g.scale[0],chance=g.chance,point=g.point,cell=u8(k)}
                if pcg_lib.spacing_grid_blocks(&e.grid,e.spaced[:],p,.Same_Cell) {continue}
                if _,error:=append(&e.spaced,p);error!=nil || !pcg_lib.spacing_grid_add(&e.grid,p.at) {return false}
            }
        }
        first:=len(e.standing)
        for p in e.spaced {
            if p.at.x< -margin || p.at.y< -margin || p.at.x>CELL_SIZE+margin || p.at.y>CELL_SIZE+margin {continue}
            if pcg_lib.spacing_grid_blocks(&e.grid,e.spaced[:],p,.Other_Cells) {continue}
            if _,_,stands:=point_stands(cell,t,&mask,p.chance,ground,p.at);!stands {continue}
            if pcg_lib.spacing_grid_blocks(&e.stood_grid,e.stood[:],p,.Any) {continue}
            if _,error:=append(&e.fresh,p);error!=nil {return false}
            if p.cell==pcg_lib.SPACING_MIDDLE {if _,error:=append(&e.standing,p.point);error!=nil {return false}}
        }
        e.ranges[o.index]={first,len(e.standing)}
        for p in e.fresh {
            if _,error:=append(&e.stood,p);error!=nil || !pcg_lib.spacing_grid_add(&e.stood_grid,p.at) {return false}
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
// nothing out. thin: the share of the generated points of the types without
// collision it keeps (type_share). False, with nothing appended, without
// memory: each part takes the room of all it appends before it writes.
cell_expand :: proc(s:^Source,cell:^Cell,ground:Ground_Cell,out:^[dynamic]Placed,orphans:^[dynamic]int,scratch:^Expand_Scratch,removed:[]u64={},thin:=f32(1)) -> bool {
    first:=len(out)
    share:=generated_share(s)
    clear(&scratch.matched)
    if !room(out,len(cell.manual)) || !room(orphans,len(cell.overrides)) || resize(&scratch.matched,len(cell.overrides))!=nil {return false}
    for b in cell.manual {append(out,placed_grounded(s,cell.coord,b,b.type,MANUAL | u64(b.id),ground))}
    if cell.generate && !ground.absent {
        if !spaced_stand(s,cell,ground,scratch,share) {
            base.truncate(out,first)
            return false
        }
        for t,i in s.types {
            standing:=scratch.standing[scratch.ranges[i][0]:scratch.ranges[i][1]]
            next:=0
            mask:=type_mask(t,ground)
            clear(&scratch.points)
            // A point gives one instance at most.
            if !scatter(s.info.seed,cell.coord,t,&scratch.points,type_share(t,share,thin)) || !room(out,len(scratch.points)) {
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
                height,normal,stands:=point_stands(cell,t,&mask,g.chance,ground,g.position)
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
