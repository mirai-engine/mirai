package terrain

import mm "mirai:std/math"

INTERIOR_STRATA :: 4
INTERIOR_VEINS :: 4

// What a Volume holds under its surface, as its layers: strata down from the
// top of each column, and veins or pockets over them. source_interior_apply
// writes it into the weights of every sample, which brushes change after.
Interior :: struct {
    strata_count:u32,
    strata:[INTERIOR_STRATA]Stratum,
    vein_count:u32,
    veins:[INTERIOR_VEINS]Vein,
    wave:f32 `mirai:"min=0,unit=m"`,       // how far the boundaries between strata rise and fall
    wave_scale:f32 `mirai:"min=0,unit=m"`, // metres across those waves
    seed:u32,
}

// A layer from where the stratum above ends down to depth under the top of
// its column; the last one reaches the bottom.
Stratum :: struct {
    layer:u32,
    depth:f32 `mirai:"min=0,unit=m"`,
}

Vein_Shape :: enum u8 {Pocket,Vein}

// A layer in blobs (Pocket) or thin sheets (Vein) of noise between two depths
// under the top of its column, over the strata and the veins before it.
Vein :: struct {
    layer:u32,
    shape:Vein_Shape,
    scale:f32 `mirai:"min=0,unit=m"`,    // metres across its features
    amount:f32 `mirai:"min=0,max=1"`,    // 0 takes nothing; more takes more of what is between its depths
    depth:[2]f32 `mirai:"min=0,unit=m"`, // under the top of its column
    seed:u32,
}

interior_valid :: proc "contextless" (interior:Interior,layer_count:u32) -> bool {
    finite :: proc "contextless" (value:f32) -> bool {return value-value==0}
    if interior.strata_count>INTERIOR_STRATA || interior.vein_count>INTERIOR_VEINS {return false}
    if !finite(interior.wave) || !(interior.wave>=0) || interior.wave>HEIGHT_LIMIT || !finite(interior.wave_scale) || !(interior.wave_scale>=0) || interior.wave_scale>HEIGHT_LIMIT {return false}
    if interior.wave>0 && !(interior.wave_scale>0) {return false}
    above:=f32(0)
    for stratum,i in interior.strata {
        if i>=int(interior.strata_count) {if stratum!={} {return false};continue}
        if stratum.layer>=layer_count || !finite(stratum.depth) || stratum.depth<above || stratum.depth>HEIGHT_LIMIT {return false}
        above=stratum.depth
    }
    for vein,i in interior.veins {
        if i>=int(interior.vein_count) {if vein!={} {return false};continue}
        if vein.layer>=layer_count || vein.shape>.Vein || !finite(vein.scale) || !(vein.scale>0) || vein.scale>HEIGHT_LIMIT {return false}
        if !(vein.amount>=0 && vein.amount<=1) || !finite(vein.depth.x) || !finite(vein.depth.y) || vein.depth.x<0 || vein.depth.x>vein.depth.y || vein.depth.y>HEIGHT_LIMIT {return false}
    }
    return true
}

// What an interior names of layer index goes once the layer goes: strata and
// veins of it, and those of later layers name theirs one lower.
@(private)
interior_layer_removed :: proc "contextless" (interior:^Interior,index:int) {
    strata:=interior.strata
    veins:=interior.veins
    interior.strata,interior.veins={},{}
    count:=0
    for stratum in strata[:interior.strata_count] {
        if int(stratum.layer)==index {continue}
        interior.strata[count]=stratum
        if int(stratum.layer)>index {interior.strata[count].layer-=1}
        count+=1
    }
    interior.strata_count=u32(count)
    count=0
    for vein in veins[:interior.vein_count] {
        if int(vein.layer)==index {continue}
        interior.veins[count]=vein
        if int(vein.layer)>index {interior.veins[count].layer-=1}
        count+=1
    }
    interior.vein_count=u32(count)
}

// The local height of the top of the surface over column x, z of a Volume,
// between its samples; the bottom of its box where the column is all air.
@(private)
volume_column_top :: proc "contextless" (s:^Source,x,z:int) -> f32 {
    origin:=source_origin(s)
    for y:=int(s.samples.y)-2;y>=0;y-=1 {
        below,above:=block_get(&s.field,{x,y,z}),block_get(&s.field,{x,y+1,z})
        if below>0 || above<=0 {continue}
        return origin.y+(f32(y)+below/(below-above))*s.cell
    }
    if block_get(&s.field,{x,int(s.samples.y)-1,z})<=0 {return origin.y+f32(s.samples.y-1)*s.cell}
    return origin.y
}

// The layer the interior puts at a local point depth metres under the top of
// its column.
interior_layer :: proc(interior:^Interior,p:[3]f32,depth:f32) -> u32 {
    layer:=u32(0)
    if interior.strata_count>0 {
        d:=depth
        if interior.wave>0 {d+=interior.wave*mm.noise_perlin2(p.xz/interior.wave_scale,interior.seed)}
        layer=interior.strata[interior.strata_count-1].layer
        for stratum in interior.strata[:interior.strata_count] {if d<=stratum.depth {layer=stratum.layer;break}}
    }
    for vein in interior.veins[:interior.vein_count] {
        if depth<vein.depth.x || depth>vein.depth.y || vein.amount<=0 {continue}
        n:=mm.noise_perlin3(p/vein.scale,vein.seed)
        // Perlin noise of three axes keeps within about 0.7 of zero.
        inside:=vein.shape==.Pocket?n>0.7*(1-2*vein.amount):abs(n)<0.35*vein.amount
        if inside {layer=vein.layer}
    }
    return layer
}

// Writes the interior of a Volume into the weights of its samples: each takes
// the layer interior_layer gives it under the top of its column. False for an
// interior that is not valid or without memory; the weights are then as they
// were.
source_interior_apply :: proc(s:^Source) -> bool {
    if s.kind!=.Volume || !source_samples_held(s) || !interior_valid(s.interior,s.layer_count) {return false}
    size:=weights_size(s)
    tops,tops_error:=make([]f32,size.x*size.z,context.temp_allocator)
    if tops_error!=nil {return false}
    for z in 0..<size.z {for x in 0..<size.x {tops[x+size.x*z]=volume_column_top(s,x,z)}}
    next:Grid(Weights)
    if !grid_init(&next,size,WEIGHTS_FIRST,s.allocator) {return false}
    Columns :: struct {s:^Source,tops:[]f32,width:int}
    page :: proc(user:rawptr,first,extent:[3]int,values:[]Weights) -> (fill:Weights,uniform:bool) {
        c:=(^Columns)(user)
        for z in 0..<extent.z {for y in 0..<extent.y {for x in 0..<extent.x {
            q:=first+{x,y,z}
            p:=source_point(c.s,q)
            w:=weights_pack({int(interior_layer(&c.s.interior,p,c.tops[q.x+c.width*q.z]-p.y)),0,0},{WEIGHT_FULL,0,0})
            values[x+extent.x*(y+extent.y*z)]=w
        }}}
        return
    }
    columns:=Columns{s,tops,size.x}
    if !grid_generate(&next,&columns,page,s.allocator) {grid_destroy(&next,s.allocator);return false}
    for &held in next.pages {held.altered=true}
    next.filled=true
    grid_destroy(&s.weights,s.allocator)
    s.weights=next
    return true
}

// The part of the cell of a sample of a Volume its distance makes solid.
@(private)
volume_solid :: #force_inline proc "contextless" (distance,cell:f32) -> f32 {return clamp(0.5-distance/cell,0,1)}

// The weights of a sample of a Volume that grows from solid old to solid new
// with layer: what was there keeps its part, what grows is of layer.
@(private)
weights_grow :: proc "contextless" (w:Weights,layer,count:int,old,new:f32) -> Weights {
    if !(new>old) {return w}
    f:=weights_float(w)*old
    f[layer]+=new-old
    return weights_quantize(f,count,layer)
}

// What the last edit of a source took out (source_edit): its cubic metres,
// those of each layer (all of the first without layers) and where, local.
Dug :: struct {
    volume:f32,
    layers:[LAYERS_MAX]f32,
    sum:[3]f32, // the local points of what it took, each by its volume
    low,high:[3]f32,
}

// Counts into s.dug what a brush took at sample p moving it from old to value:
// the height a Heightfield loses over its cell, or the part of the cell of a
// Volume that stops being solid.
@(private)
dug_count :: proc "contextless" (s:^Source,p:[3]int,old,value:f32) {
    taken:f32
    point:=source_point(s,p)
    if s.kind==.Heightfield {
        taken=(old-value)*s.cell*s.cell
        point.y=(old+value)*0.5
    } else {
        taken=(volume_solid(old,s.cell)-volume_solid(value,s.cell))*s.cell*s.cell*s.cell
    }
    if !(taken>0) {return}
    d:=&s.dug
    if d.volume==0 {d.low,d.high=point,point}
    d.volume+=taken
    d.sum+=point*taken
    for axis in 0..<3 {d.low[axis],d.high[axis]=min(d.low[axis],point[axis]),max(d.high[axis],point[axis])}
    d.layers+=weights_float(grid_value(&s.weights,p))*taken
}
