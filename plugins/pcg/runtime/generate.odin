package pcg

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"
import volume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg_lib "mirai:std/pcg"

// What a cell places, from its inputs alone: the same on every machine for a
// seed. The Macro layers go first, the widest first, each kept apart from
// itself and from those before it across the 3 by 3 cells around (std/pcg
// Spacing_Grid); then their cascades grow around the points that stand; then
// the Meso layers keep apart from all of those by their exact radii, and
// their cascades. A point stands where the ground is, its paint and its rule
// take it and no zone excludes it, with the chance of its viability (its
// field, evaluated over tiles of points). Scatter layers of one dither group
// share one set of points, each going to one of them by their viabilities
// there (std/pcg dither_band_select). Grammar layers split each span of the
// Splines of their channel into modules, which belong to the cell of their
// middle. What is suppressed is taken out last: what it leaves is empty, and
// no other point moves into its place. A point is told whether it stands at
// the nearest border of the cell where it is outside it, from the ground of
// this cell, so every cell that sees it decides the same.

// The most points the scatter and cascade layers place in a cell together:
// past it every layer keeps the same share of its points (generated_share).
CELL_GENERATED_MAX :: 1 << 18
GRAMMAR_PLACED_MAX :: 1024 // modules of one span
OCCUPANCY_REACH :: f32(1)  // m around a point, at least, that says whether a point that stands before it is near (occupancy)

// A thing a cell places, in the frame of its graph.
Placed :: struct {
    position:[3]f32,
    rotation:mm.Quat,
    scale:[3]f32,     // across x, along y and across z; a grammar module scales along z, its span
    id:u64,           // stable in its cell: stable_id of its layer and point, or the grammar_span_id of its module
    parent:u64,       // of a cascade child, the id of its parent; 0 for none
    asset:base.Asset_Id,
    layer:u32,        // the id of its layer
    tier:Pcg_Tier,
    collides,filler:bool,
}

// Scatter layers of a tier placed together: one alone, or those of a dither group.
Pcg_Unit :: struct {
    tier:Pcg_Tier,
    key:u32,         // of its points: the id of its layer alone, or DITHER_KEY | its group
    first,count:u16, // of Pcg_Source.members: the indices of its layers
    density:f32,     // per m2, of its layers together
    reach:f32,       // m: the widest radius of its layers at their highest scale
}
DITHER_KEY :: u32(1) << 31

// Where a graph places, in the world: its Volume; unbounded, everywhere.
Pcg_Region :: struct {
    volume:volume.Volume,
    pose:mm.Transform,
    outline:[]mm.Path_Point,
}

// A zone that gives a mask, in the world.
Pcg_Zone_Placed :: struct {
    region:Pcg_Region,
    zone:volume.Zone,
    channel:u32,
    weight:f32,
    box:mm.Aabb,
}

// A straight span of a Spline in the frame of a graph, between two of its points.
Pcg_Span :: struct {
    entity:u64, // the Id of the Spline entity
    span:u32,   // the index of its first point
    channel:u32,
    a,b:[3]f32,
}

// What the generator reads to place a cell.
Pcg_Cell_Input :: struct {
    source:^Pcg_Source,
    seed:u32,         // graph_seed
    coord:[2]i32,
    ground:Pcg_Ground_Cell,
    paint:^Pcg_Cell,  // its painted cell; nil: all of the density, no ecotopes
    frame:mm.Mat4,    // from the frame of the cells to the world
    domain:Pcg_Region,
    zones:[]Pcg_Zone_Placed, // in the order they apply: by priority, then the bigger first
    spans:[]Pcg_Span,
    suppressed:[]u64, // in order
    share:f32,        // generated_share of the source
}

// A point a unit or a cascade scatters.
@(private)
Point :: struct {
    at:[2]f32, // from the corner of the middle cell
    yaw,tilt,turn:f32,
    scale_u,height_u,offset_u:f32,
    chance,viability_u,dither_u:f32,
    parent:u64,
    point:u32,
    cell:u8,
    height:f32,
    normal:[3]f32,
    occupancy:f32,
    reach:f32, // of the layer it ends as
}

// A point that stands, of a layer, in the middle cell or around it.
@(private)
Stood :: struct {
    using p:Point,
    layer:u16, // index in the source
    middle:bool,
}

// The samples of a tile of field inputs.
@(private)
Field_Tile :: struct {
    x,y,z,height,slope,occupancy,out:[pcg_lib.TILE]f32,
    masks:[MASKS_MAX][pcg_lib.TILE]f32,
    ecotopes:[ECOTOPES_MAX][pcg_lib.TILE]f32,
}

// The work memory of one thread placing cells; it keeps its room from cell to cell.
Pcg_Scratch :: struct {
    points:[dynamic]Point,
    spaced:[dynamic]pcg_lib.Spacing_Point,
    spaced_points:[dynamic]u32, // index in points of each of spaced
    candidates:[dynamic]u32,    // index in points of those on the ground
    viability:[dynamic]f32,     // candidates by the layers of their unit
    weights:[dynamic]f32,
    stood:[dynamic]Stood,
    stood_spacing:[dynamic]pcg_lib.Spacing_Point,
    fresh:[dynamic]Stood,
    grid,stood_grid:pcg_lib.Spacing_Grid,
    field:^pcg_lib.Field_Scratch,
    tile:^Field_Tile,
    frames:[pcg_lib.GRAMMAR_MAX_DEPTH]pcg_lib.Grammar_Frame,
    modules:[]pcg_lib.Grammar_Placed,
    occupied:Occupancy, // of the last cell generated, for its Micro layers
    occupied_hash:u64,
    allocator:runtime.Allocator,
}

// Work memory from allocator; false without memory, with nothing kept.
scratch_init :: proc(s:^Pcg_Scratch,allocator:=context.allocator) -> bool {
    s^={allocator=allocator}
    context.allocator=allocator
    e0,e1,e2:runtime.Allocator_Error
    s.field,e0=new(pcg_lib.Field_Scratch)
    s.tile,e1=new(Field_Tile)
    s.modules,e2=make([]pcg_lib.Grammar_Placed,GRAMMAR_PLACED_MAX)
    s.points=make([dynamic]Point);s.spaced=make([dynamic]pcg_lib.Spacing_Point);s.spaced_points=make([dynamic]u32)
    s.candidates=make([dynamic]u32);s.viability=make([dynamic]f32);s.weights=make([dynamic]f32)
    s.stood=make([dynamic]Stood);s.stood_spacing=make([dynamic]pcg_lib.Spacing_Point);s.fresh=make([dynamic]Stood)
    s.grid,s.stood_grid=pcg_lib.spacing_grid_make(),pcg_lib.spacing_grid_make()
    if e0!=nil || e1!=nil || e2!=nil || s.field==nil || s.tile==nil || len(s.modules)!=GRAMMAR_PLACED_MAX {scratch_destroy(s);return false}
    return true
}

scratch_destroy :: proc(s:^Pcg_Scratch) {
    context.allocator=s.allocator
    free(s.field);free(s.tile);delete(s.modules)
    delete(s.points);delete(s.spaced);delete(s.spaced_points);delete(s.candidates);delete(s.viability);delete(s.weights)
    delete(s.stood);delete(s.stood_spacing);delete(s.fresh)
    pcg_lib.spacing_grid_destroy(&s.grid);pcg_lib.spacing_grid_destroy(&s.stood_grid)
    s^={}
}

// The layers of the units of a source by tier, the widest first and the
// lower key first among equal ones, into s.units and s.members.
@(private)
source_units :: proc(s:^Pcg_Source) -> bool {
    clear(&s.units);clear(&s.members)
    for tier in Pcg_Tier.Macro..=Pcg_Tier.Meso {
        first:=len(s.units)
        for l,i in s.layers {
            if l.kind!=.Scatter || l.tier!=tier {continue}
            if l.dither_group!=0 {
                known:=false
                for u in s.units[first:] {known||=u.key==DITHER_KEY|u32(l.dither_group)}
                if known {continue}
                u:=Pcg_Unit{tier=tier,key=DITHER_KEY|u32(l.dither_group),first=u16(len(s.members))}
                for other,k in s.layers {
                    if other.kind!=.Scatter || other.tier!=tier || other.dither_group!=l.dither_group {continue}
                    if _,error:=append(&s.members,u16(k));error!=nil {return false}
                    u.count+=1
                    u.density+=other.density
                    u.reach=max(u.reach,other.radius*other.scale[1])
                }
                if _,error:=append(&s.units,u);error!=nil {return false}
                continue
            }
            if _,error:=append(&s.members,u16(i));error!=nil {return false}
            if _,error:=append(&s.units,Pcg_Unit{tier=tier,key=l.id,first=u16(len(s.members)-1),count=1,density=l.density,reach=l.radius*l.scale[1]});error!=nil {return false}
        }
        slice.sort_by(s.units[first:],proc(a,b:Pcg_Unit) -> bool {return a.reach>b.reach || a.reach==b.reach && a.key<b.key})
    }
    return true
}

// The share of the points of each layer every cell of a source places: 1, or
// less when their densities give more than CELL_GENERATED_MAX.
generated_share :: proc "contextless" (s:^Pcg_Source) -> f32 {
    area:=f64(s.info.cell_size)*f64(s.info.cell_size)
    total:=f64(0)
    for l in s.layers {
        if l.tier==.Micro {continue}
        switch l.kind {
        case .Scatter: total+=f64(l.density)*area
        case .Cascade:
            if parent,_:=source_layer(s,l.parent_layer);parent!=nil {total+=f64(parent.density)*area*f64(l.density)}
        case .Grammar:
        }
    }
    return total>CELL_GENERATED_MAX?f32(CELL_GENERATED_MAX/total):1
}

// How many points of a unit a cell scatters at most, of share.
@(private)
unit_count_max :: proc "contextless" (s:^Pcg_Source,u:Pcg_Unit,share:f32) -> int {
    return int(f64(u.density)*f64(s.info.cell_size)*f64(s.info.cell_size)*f64(share))+1
}

// The points of a unit in a cell, from the corner of the middle cell at
// offset (in cells), appended to out. False without memory, with none appended.
@(private)
unit_scatter :: proc(s:^Pcg_Source,seed:u32,coord:[2]i32,offset:[2]i32,u:Pcg_Unit,share:f32,out:^[dynamic]Point) -> bool {
    key:=pcg_lib.scatter_key(seed,coord+offset,u.key)
    cell:=s.info.cell_size
    count:=pcg_lib.scatter_count(key,f64(u.density)*f64(cell)*f64(cell)*f64(share))
    if !room(out,int(count)) {return false}
    scramble:=pcg_lib.scatter_scramble(key)
    k:=(offset.y+1)*3+offset.x+1
    for point in 0..<count {
        r:=pcg_lib.point_stream(key,point)
        p:=Point{point=point,cell=u8(k)}
        p.at=pcg_lib.scatter_point_unit(scramble,point)*cell+[2]f32{f32(offset.x),f32(offset.y)}*cell
        point_values(&p,&r)
        append(out,p)
    }
    return true
}

// The values of a point, in the order of its stream.
@(private)
point_values :: proc "contextless" (p:^Point,r:^mm.Rng) {
    p.yaw=mm.random_f32(r)
    p.tilt=mm.random_f32(r)
    p.turn=mm.random_f32(r)*6.2831855
    p.scale_u=mm.random_f32(r)
    p.height_u=mm.random_f32(r)
    p.offset_u=mm.random_f32(r)
    p.chance=mm.random_f32(r)
    p.viability_u=mm.random_f32(r)
    p.dither_u=mm.random_f32(r)
}

@(private)
layer_scale :: proc "contextless" (l:^Pcg_Layer,p:Point) -> [2]f32 {
    s:=l.scale[0]+(l.scale[1]-l.scale[0])*p.scale_u
    return {s,s*(l.height[0]+(l.height[1]-l.height[0])*p.height_u)}
}

// Room for more elements past the end, grown by doubling. False without memory.
@(private)
room :: proc(array:^[dynamic]$T,more:int) -> bool {
    needed:=len(array)+more
    return needed<=cap(array) || reserve(array,max(needed,2*cap(array)))==nil
}

// How much of the density a painted cell keeps at x and z from its corner,
// 0 to 1, between its samples; past its border, as at the nearest point of it.
paint_at :: proc "contextless" (paint:^Pcg_Cell,block:int,cell_size:f32,x,z:f32,ecotope:bool) -> f32 {
    n:=PAINT_SAMPLES
    side:=n*n
    values:[]u8
    if paint!=nil {
        if ecotope {
            if (block+1)*side<=len(paint.ecotopes) {values=paint.ecotopes[block*side:][:side]}
        } else if len(paint.density)==side {values=paint.density[:]}
    }
    if len(values)==0 {return 0 if ecotope else 1}
    step:=cell_size/f32(n-1)
    u,v:=clamp(x/step,0,f32(n-1)),clamp(z/step,0,f32(n-1))
    if u!=u {u=0}
    if v!=v {v=0}
    c,r:=min(int(u),n-2),min(int(v),n-2)
    fu,fv:=u-f32(c),v-f32(r)
    a,b:=f32(values[r*n+c]),f32(values[r*n+c+1])
    d,e:=f32(values[(r+1)*n+c]),f32(values[(r+1)*n+c+1])
    return ((a+(b-a)*fu)*(1-fv)+(d+(e-d)*fu)*fv)/255
}

// Whether a region holds a point of the world; an unbounded one, everywhere.
region_holds :: proc "contextless" (r:Pcg_Region,p:[3]f32) -> bool {
    if r.volume.shape==.Unbounded {return true}
    return volume.holds(r.volume,r.pose,p,r.outline)
}

// The mask of a channel at a point of the world: each zone of it that holds
// the point, in their order, replaces or adds its weight by its blend.
zone_mask :: proc "contextless" (zones:[]Pcg_Zone_Placed,channel:u32,p:[3]f32) -> f32 {
    value:=f32(0)
    for &z in zones {
        if z.channel!=channel || !mm.aabb_contains_point(z.box,p) {continue}
        w:=volume.weight(z.region.volume,z.region.pose,p,z.zone.blend,z.region.outline)
        if !(w>0) {continue}
        if z.zone.mode==.Add {value+=z.weight*w} else {value+=(z.weight-value)*w}
    }
    return clamp(value,0,1)
}

@(private)
frame_point :: proc "contextless" (cin:^Pcg_Cell_Input,at:[2]f32,height:f32) -> [3]f32 {
    corner:=cell_corner(cin.source.info.cell_size,cin.coord)
    return mm.mat4_point(cin.frame,corner+{at.x,height,at.y})
}

// Whether a point is on the ground of its cell where its paint keeps it and
// no zone excludes it, and the ground there.
@(private)
point_ground :: proc "contextless" (cin:^Pcg_Cell_Input,p:^Point) -> bool {
    height,normal,ok:=ground_at(cin.ground,p.at.x,p.at.y)
    if !ok || ground_kept_out(cin.ground,p.at.x,p.at.y) {return false}
    if p.chance>=paint_at(cin.paint,0,cin.source.info.cell_size,p.at.x,p.at.y,false) {return false}
    if !region_holds(cin.domain,frame_point(cin,p.at,height)) {return false}
    p.height,p.normal=height,normal
    return true
}

// Whether the rule of a layer takes the ground under a point.
@(private)
rule_takes :: proc "contextless" (cin:^Pcg_Cell_Input,l:^Pcg_Layer,mask:^Layer_Mask,p:Point) -> bool {
    r:=l.ground_rule
    if !r.enabled {return true}
    slope:=math.acos(clamp(p.normal.y,-1,1))
    if !(slope>=r.slope.x && slope<=r.slope.y && p.height>=r.height.x && p.height<=r.height.y) {return false}
    if r.layers=={} {return true}
    weight,known:=ground_layer_weight(cin.ground,mask,p.at.x,p.at.y)
    // Within half a step of the 255 of the weights: a full layer between samples takes weight 1.
    return known && weight+0.5/255>=(r.whole?r.weight:max(r.weight,p.chance))
}

@(private)
rule_mask :: proc "contextless" (cin:^Pcg_Cell_Input,l:^Pcg_Layer) -> (mask:Layer_Mask) {
    if l.ground_rule.enabled && l.ground_rule.layers!={} {mask=layer_mask(l.ground_rule,cin.ground.layers)}
    return
}

// The viability of a layer at the candidates of points, 0 to 1, into out: 1
// without a field. False when its program does not run.
@(private)
field_values :: proc(cin:^Pcg_Cell_Input,scratch:^Pcg_Scratch,layer:int,points:[]Point,candidates:[]u32,out:[]f32) -> bool {
    c:=&cin.source.compiled[layer]
    if !c.has_field {
        for &v in out {v=1}
        return true
    }
    t:=scratch.tile
    cell:=cin.source.info.cell_size
    corner:=cell_corner(cell,cin.coord)
    ecotopes:=int(cin.source.info.ecotopes)
    masks:[MASKS_MAX][]f32
    eco:[ECOTOPES_MAX][]f32
    for start:=0;start<len(candidates);start+=pcg_lib.TILE {
        n:=min(pcg_lib.TILE,len(candidates)-start)
        for k in 0..<n {
            p:=points[candidates[start+k]]
            t.x[k],t.z[k]=corner.x+p.at.x,corner.z+p.at.y
            t.y[k],t.height[k]=p.height,p.height
            t.slope[k]=math.acos(clamp(p.normal.y,-1,1))
            t.occupancy[k]=p.occupancy
            if c.masks!=0 {
                world:=frame_point(cin,p.at,p.height)
                for ch in 0..<MASKS_MAX {if c.masks&(1<<u8(ch))!=0 {t.masks[ch][k]=zone_mask(cin.zones,u32(ch),world)}}
            }
            for e in 0..<ecotopes {t.ecotopes[e][k]=paint_at(cin.paint,e,cell,p.at.x,p.at.y,true)}
        }
        for ch in 0..<MASKS_MAX {masks[ch]=c.masks&(1<<u8(ch))!=0?t.masks[ch][:n]:nil}
        for e in 0..<ECOTOPES_MAX {eco[e]=e<ecotopes?t.ecotopes[e][:n]:nil}
        inputs:=pcg_lib.Field_Inputs{x=t.x[:n],y=t.y[:n],z=t.z[:n],height=t.height[:n],slope=t.slope[:n],occupancy=t.occupancy[:n],masks=masks[:],ecotopes=eco[:]}
        if pcg_lib.field_eval_tile(&c.field,inputs,t.out[:n],scratch.field)!=.None {return false}
        for k in 0..<n {
            v:=t.out[k]
            out[start+k]=v>0?min(v,1):0
        }
    }
    return true
}

// 1 where a point that stood before is within the reach of p (OCCUPANCY_REACH at least), else 0.
@(private)
occupancy_of :: proc "contextless" (scratch:^Pcg_Scratch,p:Point,reach:f32) -> f32 {
    probe:=pcg_lib.Spacing_Point{at=p.at,reach=max(reach,OCCUPANCY_REACH)}
    return 1 if pcg_lib.spacing_grid_blocks(&scratch.stood_grid,scratch.stood_spacing[:],probe,.Any) else 0
}

// Puts what stands of fresh with the points that stand, so the later ones keep apart from them.
@(private)
stood_add :: proc(scratch:^Pcg_Scratch) -> bool {
    if !room(&scratch.stood,len(scratch.fresh)) || !room(&scratch.stood_spacing,len(scratch.fresh)) {return false}
    for f in scratch.fresh {
        append(&scratch.stood,f)
        append(&scratch.stood_spacing,pcg_lib.Spacing_Point{at=f.at,reach=f.reach,point=f.point,cell=f.cell})
        if !pcg_lib.spacing_grid_add(&scratch.stood_grid,f.at) {return false}
    }
    clear(&scratch.fresh)
    return true
}

// Places a unit: its points over the 3 by 3 cells kept apart from each other,
// those on the ground and taken by a layer, each to a layer, and apart from
// what stood before.
@(private)
unit_place :: proc(cin:^Pcg_Cell_Input,scratch:^Pcg_Scratch,u:Pcg_Unit,margin:f32) -> bool {
    s:=cin.source
    cell:=s.info.cell_size
    members:=s.members[u.first:][:u.count]
    clear(&scratch.points);clear(&scratch.spaced);clear(&scratch.spaced_points);clear(&scratch.candidates)
    spaced:=u.reach>0
    if spaced {
        if !pcg_lib.spacing_grid_reset(&scratch.grid,cell,margin) {return false}
        for k in 0..<9 {
            d:=[2]i32{i32(k%3)-1,i32(k/3)-1}
            first:=len(scratch.points)
            if !unit_scatter(s,cin.seed,cin.coord,d,u,cin.share,&scratch.points) {return false}
            for &p,i in scratch.points[first:] {
                reach:=f32(0)
                for m in members {l:=&s.layers[m];reach=max(reach,l.radius*layer_scale(l,p)[0])}
                p.reach=reach
                q:=pcg_lib.Spacing_Point{at=p.at,reach=reach,chance=p.chance,point=p.point,cell=p.cell}
                if pcg_lib.spacing_grid_blocks(&scratch.grid,scratch.spaced[:],q,.Same_Cell) {continue}
                if _,error:=append(&scratch.spaced,q);error!=nil || !pcg_lib.spacing_grid_add(&scratch.grid,q.at) {return false}
                if _,error:=append(&scratch.spaced_points,u32(first+i));error!=nil {return false}
            }
        }
        for q,i in scratch.spaced {
            if q.at.x< -margin || q.at.y< -margin || q.at.x>cell+margin || q.at.y>cell+margin {continue}
            if pcg_lib.spacing_grid_blocks(&scratch.grid,scratch.spaced[:],q,.Other_Cells) {continue}
            p:=&scratch.points[scratch.spaced_points[i]]
            if !point_ground(cin,p) {continue}
            p.occupancy=occupancy_of(scratch,p^,p.reach)
            if _,error:=append(&scratch.candidates,scratch.spaced_points[i]);error!=nil {return false}
        }
    } else {
        if !unit_scatter(s,cin.seed,cin.coord,{0,0},u,cin.share,&scratch.points) {return false}
        if !room(&scratch.candidates,len(scratch.points)) {return false}
        for &p,i in scratch.points {
            if !point_ground(cin,&p) {continue}
            p.occupancy=occupancy_of(scratch,p,0)
            append(&scratch.candidates,u32(i))
        }
    }
    n:=len(scratch.candidates)
    if resize(&scratch.viability,n*len(members))!=nil || resize(&scratch.weights,len(members))!=nil {return false}
    for m,j in members {
        if !field_values(cin,scratch,int(m),scratch.points[:],scratch.candidates[:],scratch.viability[j*n:][:n]) {return false}
    }
    masks:[DITHER_MEMBERS_MAX]Layer_Mask
    if len(members)>DITHER_MEMBERS_MAX {return false}
    for m,j in members {masks[j]=rule_mask(cin,&s.layers[m])}
    clear(&scratch.fresh)
    for c,ci in scratch.candidates {
        p:=scratch.points[c]
        chosen:=-1
        if len(members)==1 {
            l:=&s.layers[members[0]]
            if p.viability_u<scratch.viability[ci] && rule_takes(cin,l,&masks[0],p) {chosen=0}
        } else {
            for m,j in members {
                l:=&s.layers[m]
                share:=l.density/u.density
                scratch.weights[j]=share*scratch.viability[j*n+ci] if rule_takes(cin,l,&masks[j],p) else 0
            }
            if k,ok:=pcg_lib.dither_band_select(p.dither_u,scratch.weights[:]);ok {chosen=k}
        }
        if chosen<0 {continue}
        l:=&s.layers[members[chosen]]
        p.reach=l.radius*layer_scale(l,p)[0]
        q:=pcg_lib.Spacing_Point{at=p.at,reach=p.reach,point=p.point,cell=p.cell}
        if pcg_lib.spacing_grid_blocks(&scratch.stood_grid,scratch.stood_spacing[:],q,.Any) {continue}
        if _,error:=append(&scratch.fresh,Stood{p=p,layer=members[chosen],middle=p.cell==pcg_lib.SPACING_MIDDLE});error!=nil {return false}
    }
    return stood_add(scratch)
}

// The children of a cascade around each point of its parent layer that
// stands in the middle cell: as many as its density says on average, each
// from the stream of its parent's id and its index, at a distance beyond the
// reach of both, and apart from what stood before and from each other.
@(private)
cascade_place :: proc(cin:^Pcg_Cell_Input,scratch:^Pcg_Scratch,layer:int) -> bool {
    s:=cin.source
    l:=&s.layers[layer]
    _,parent:=source_layer(s,l.parent_layer)
    if parent<0 {return false}
    clear(&scratch.points);clear(&scratch.candidates)
    count:=len(scratch.stood)
    for k in 0..<count {
        st:=scratch.stood[k]
        if int(st.layer)!=parent || !st.middle || st.point>max(u32)/CASCADE_CHILDREN_MAX {continue}
        parent_id:=pcg_lib.stable_id(s.layers[parent].id,st.point)
        children:=pcg_lib.scatter_count(base.hash_u64(parent_id)~base.hash_u64(u64(l.id)),f64(l.density)*f64(cin.share))
        children=min(children,CASCADE_CHILDREN_MAX)
        if !room(&scratch.points,int(children)) {return false}
        for child in 0..<children {
            r:=mm.rng_make(base.hash_u64(parent_id~u64(child))~base.hash_u64(u64(l.id)))
            p:=Point{point=st.point*CASCADE_CHILDREN_MAX+child,cell=pcg_lib.SPACING_MIDDLE,parent=parent_id}
            angle:=mm.random_f32(&r)*6.2831855
            spread:=mm.random_f32(&r)
            point_values(&p,&r)
            reach:=l.radius*layer_scale(l,p)[0]
            distance:=st.reach+reach+spread*2*max(st.reach,reach,0.5)
            sn,cs:=mm.sincos_det(angle)
            p.at=st.at+[2]f32{cs,sn}*distance
            p.reach=reach
            append(&scratch.points,p)
        }
    }
    if !room(&scratch.candidates,len(scratch.points)) {return false}
    for &p,i in scratch.points {
        if !point_ground(cin,&p) {continue}
        p.occupancy=occupancy_of(scratch,p,p.reach)
        append(&scratch.candidates,u32(i))
    }
    n:=len(scratch.candidates)
    if resize(&scratch.viability,n)!=nil {return false}
    if !field_values(cin,scratch,layer,scratch.points[:],scratch.candidates[:],scratch.viability[:n]) {return false}
    mask:=rule_mask(cin,l)
    clear(&scratch.fresh)
    for c,ci in scratch.candidates {
        p:=scratch.points[c]
        if !(p.viability_u<scratch.viability[ci]) || !rule_takes(cin,l,&mask,p) {continue}
        q:=pcg_lib.Spacing_Point{at=p.at,reach=p.reach,point=p.point,cell=p.cell}
        if pcg_lib.spacing_grid_blocks(&scratch.stood_grid,scratch.stood_spacing[:],q,.Any) {continue}
        if _,error:=append(&scratch.fresh,Stood{p=p,layer=u16(layer),middle=true});error!=nil {return false}
        // A child keeps apart from its siblings at once.
        if !stood_add(scratch) {return false}
    }
    return true
}

@(private)
quat_turn :: proc "contextless" (axis:[3]f32,angle:f32) -> mm.Quat {
    s,c:=mm.sincos_det(angle*0.5)
    return quaternion(w=c,x=axis.x*s,y=axis.y*s,z=axis.z*s)
}

// The turn from up to a normal of the ground, scaled by align (0 to 1).
ground_slope :: proc "contextless" (align:f32,normal:[3]f32) -> mm.Quat {
    up:=[3]f32{0,1,0}
    n:=normal
    length:=linalg.length(n)
    if align<=0 || length<1e-6 {return 1}
    n/=length
    half:=linalg.normalize(up+n) if linalg.dot(up,n)>-0.999 else [3]f32{1,0,0}
    axis:=linalg.cross(up,half)
    slope:=mm.Quat(quaternion(w=linalg.dot(up,half),x=axis.x,y=axis.y,z=axis.z))
    if align<1 {slope=linalg.normalize(mm.quat_nlerp(1,slope,align))}
    return slope
}

// The thing a point that stands places, in the frame.
@(private)
placed_of :: proc "contextless" (cin:^Pcg_Cell_Input,st:Stood) -> Placed {
    l:=&cin.source.layers[st.layer]
    yaw:=quat_turn({0,1,0},st.yaw*l.yaw)
    s,c:=mm.sincos_det(st.turn)
    lean:=quat_turn({c,0,s},st.tilt*l.tilt)
    rotation:=ground_slope(l.align,st.normal)*lean*yaw
    corner:=cell_corner(cin.source.info.cell_size,cin.coord)
    position:=corner+{st.at.x,st.height,st.at.y}
    offset:=l.offset.x+(l.offset.y-l.offset.x)*st.offset_u
    if offset!=0 {position+=mm.quat_rotate(rotation,{0,offset,0})}
    scale:=layer_scale(l,st)
    return {position=position,rotation=rotation,scale={scale[0],scale[1],scale[0]},id=pcg_lib.stable_id(l.id,st.point),parent=st.parent,asset=l.asset,layer=l.id,tier=l.tier,collides=l.collides,filler=l.filler}
}

// The modules of a Grammar layer along the spans of its channel whose middle
// falls in the cell, appended to out.
@(private)
grammar_place :: proc(cin:^Pcg_Cell_Input,scratch:^Pcg_Scratch,layer:int,out:^[dynamic]Placed) -> bool {
    s:=cin.source
    l:=&s.layers[layer]
    c:=&s.compiled[layer]
    if !c.has_grammar {return true}
    cell:=s.info.cell_size
    corner:=cell_corner(cell,cin.coord)
    frames:=pcg_lib.Grammar_Scratch{frames=scratch.frames[:]}
    for span in cin.spans {
        if span.channel!=l.channel {continue}
        dir:=span.b-span.a
        length:=linalg.length(dir)
        if !(length>1e-4) || length>4*POSITION_MAX {continue}
        // The span only reaches this cell when its middle may fall in it.
        low,high:=linalg.min(span.a.xz,span.b.xz),linalg.max(span.a.xz,span.b.xz)
        if high.x<corner.x || high.y<corner.z || low.x>corner.x+cell || low.y>corner.z+cell {continue}
        key:=base.hash_mix(span.entity,u64(l.id))
        count,error:=pcg_lib.grammar_subdivide(c.grammar,length,pcg_lib.grammar_span_id(key,span.span,0)~u64(cin.seed),&frames,scratch.modules)
        if error!=.None && error!=.Capacity_Exceeded {continue}
        across:=linalg.normalize([3]f32{dir.x,0,dir.z}) if dir.x*dir.x+dir.z*dir.z>1e-12 else [3]f32{0,0,1}
        rotation:=quat_turn({0,1,0},math.atan2(across.x,across.z))
        if !room(out,count) {return false}
        for m in scratch.modules[:count] {
            middle:=span.a+dir*((m.start+m.size*0.5)/length)
            coord,local:=cell_of(cell,middle.xz)
            if coord!=cin.coord {continue}
            position:=span.a+dir*(m.start/length)
            if h,_,ok:=ground_at(cin.ground,local.x,local.y);ok {position.y=h}
            sym:=int(m.sym)
            what:=l.asset
            if sym<len(l.grammar_symbols) && l.grammar_symbols[sym].asset!={} {what=l.grammar_symbols[sym].asset}
            append(out,Placed{position=position,rotation=rotation,scale={1,1,m.scale},id=pcg_lib.grammar_span_id(key,span.span,m.ordinal),asset=what,layer=l.id,tier=l.tier,collides=l.collides,filler=l.filler})
        }
    }
    return true
}

// The authored points of a cell, appended to out regardless of ground, paint,
// field, rule, zones or spacing.
@(private)
points_place :: proc(cin:^Pcg_Cell_Input,out:^[dynamic]Placed) -> bool {
    if cin.paint==nil || len(cin.paint.points)==0 {return true}
    s:=cin.source
    if !room(out,len(cin.paint.points)) {return false}
    for pt in cin.paint.points {
        l,_:=source_layer(s,pt.layer)
        if l==nil || l.kind!=.Scatter || l.tier==.Micro {continue}
        append(out,Placed{position=pt.position,rotation=pt.rotation,scale=pt.scale,id=authored_id(l.id,pt.point),asset=l.asset,layer=l.id,tier=l.tier,collides=l.collides,filler=l.filler})
    }
    return true
}

// What a cell places, appended to out: Macro then Meso units and cascades,
// then grammars (all gated on ground), then authored points of the cell
// regardless of ground, without what is suppressed; with Micro layers, the
// occupancy of what stood before that in scratch.occupied. False without
// memory or when a program does not run, with nothing appended.
cell_generate :: proc(cin:^Pcg_Cell_Input,scratch:^Pcg_Scratch,out:^[dynamic]Placed) -> bool {
    s:=cin.source
    first:=len(out)
    scratch.occupied,scratch.occupied_hash={},0
    if s==nil || len(s.compiled)!=len(s.layers) {return true}
    context.allocator=scratch.allocator
    clear(&scratch.stood);clear(&scratch.stood_spacing);clear(&scratch.fresh)
    has_ground:=!cin.ground.absent && cin.ground.samples>=2
    ok:=true
    if has_ground {
        margin:=f32(0)
        for u in s.units {margin=max(margin,2*u.reach)}
        for l in s.layers {if l.kind==.Cascade {margin=max(margin,2*l.radius*l.scale[1])}}
        if !pcg_lib.spacing_grid_reset(&scratch.stood_grid,s.info.cell_size,max(margin,2*OCCUPANCY_REACH)) {return false}
        for tier in Pcg_Tier.Macro..=Pcg_Tier.Meso {
            for u in s.units {if ok && u.tier==tier {ok=unit_place(cin,scratch,u,margin)}}
            for l,i in s.layers {if ok && l.kind==.Cascade && l.tier==tier {ok=cascade_place(cin,scratch,i)}}
        }
    }
    // Before anything is suppressed: what is taken out keeps its ground.
    if ok && source_micro(s) {scratch.occupied_hash=occupancy_raster(&scratch.occupied,s.info.cell_size,scratch.stood[:],s,cin.coord)}
    if has_ground {
        if ok && room(out,len(scratch.stood)) {
            for st in scratch.stood {if st.middle {append(out,placed_of(cin,st))}}
        } else {ok=false}
        for l,i in s.layers {if ok && l.kind==.Grammar && l.tier!=.Micro {ok=grammar_place(cin,scratch,i,out)}}
    }
    if ok {ok=points_place(cin,out)}
    if !ok {
        base.truncate(out,first)
        return false
    }
    if len(cin.suppressed)==0 {return true}
    kept:=first
    for p in out[first:] {
        if ids_have(cin.suppressed,p.id) {continue}
        out[kept]=p
        kept+=1
    }
    base.truncate(out,kept)
    return true
}

// The thing of an id among those a cell places.
placed_find :: proc "contextless" (placed:[]Placed,id:u64) -> (Placed,bool) {
    for p in placed {if p.id==id {return p,true}}
    return {},false
}
