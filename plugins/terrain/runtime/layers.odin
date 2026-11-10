package terrain

import "core:math"
import "mirai:asset"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

LAYERS_MAX :: 4
// The material of plugins/terrain/assets/terrain_layers.mat, whose Surface
// program (Terrain_Layers) blends the layers of a source.
LAYERS_MATERIAL :: base.Asset_Id{0x7465727261696e5f,0x6c61796572730001}

// A material painted over a terrain. The weights of the layers of each
// sample add up to WEIGHT_FULL.
Terrain_Layer :: struct {
    material:base.Asset_Id,
    tiling:f32 `mirai:"min=0,unit=m"`,       // metres over which the textures of its material repeat
    height_blend:f32 `mirai:"min=0,max=1"`,  // 0: the weights alone; 1: where layers meet, the higher texels (alpha of the base color map) show
    displacement:f32 `mirai:"min=0,unit=m"`, // how far the lowest texel of that height lies under the highest on a Heightfield near the view (displacement.odin); 0: flat
    auto:Layer_Auto,
}
// Covers, over what is painted, where the slope and the height of the surface
// are within their ranges.
Layer_Auto :: struct {
    enabled:bool,
    slope:[2]f32 `mirai:"angle"`,       // from horizontal
    height:[2]f32 `mirai:"unit=m"`,     // local
    softness:[2]f32,                    // how far past each range it fades out: radians of slope, metres of height
}
LAYER_DEFAULT :: Terrain_Layer{tiling=4,auto={slope={0,math.PI/2},height={-HEIGHT_LIMIT,HEIGHT_LIMIT},softness={0.35,2}}}
// The rule of an automatic layer reads the slope of a Heightfield over this
// many samples on each side, the same at every level: its cover does not jump
// from one sample to the next.
LAYER_RULE_SAMPLES :: 2
WEIGHT_FULL :: 255

Weights :: [4]u8

layer_valid :: proc "contextless" (layer:Terrain_Layer) -> bool {
    finite :: proc "contextless" (value:f32) -> bool {return value-value==0}
    if !finite(layer.tiling) || !(layer.tiling>0) || layer.tiling>10000 || !(layer.height_blend>=0 && layer.height_blend<=1) {return false}
    if !(layer.displacement>=0 && layer.displacement<=DISPLACEMENT_MAX) {return false}
    a:=layer.auto
    for value in ([6]f32{a.slope.x,a.slope.y,a.height.x,a.height.y,a.softness.x,a.softness.y}) {if !finite(value) {return false}}
    return a.slope.x>=0 && a.slope.x<=a.slope.y && a.slope.y<=math.PI/2+1e-4 && a.height.x<=a.height.y && abs(a.height.x)<=HEIGHT_LIMIT && abs(a.height.y)<=HEIGHT_LIMIT && a.softness.x>=0 && a.softness.y>=0
}

@(private)
weights_full :: proc "contextless" (w:Weights) -> bool {return int(w[0])+int(w[1])+int(w[2])+int(w[3])==WEIGHT_FULL}

// The weights that add up to WEIGHT_FULL closest to the shares of f over its
// first count layers; the remainder goes to the largest fractions, the
// lower layer on a tie.
weights_quantize :: proc "contextless" (f:[4]f32,count:int) -> (w:Weights) {
    count:=clamp(count,1,LAYERS_MAX)
    sum:=f32(0)
    for i in 0..<count {sum+=max(f[i],0)}
    if !(sum>0) {w[0]=WEIGHT_FULL;return}
    fraction:[4]f32
    used:=0
    for i in 0..<count {
        scaled:=max(f[i],0)/sum*WEIGHT_FULL
        whole:=min(int(scaled),WEIGHT_FULL)
        w[i]=u8(whole);used+=whole
        fraction[i]=scaled-f32(whole)
    }
    for _ in used..<WEIGHT_FULL {
        best:=0
        for i in 1..<count {if fraction[i]>fraction[best] {best=i}}
        w[best]+=1
        fraction[best]=-1
    }
    return
}

// Adds amount (above zero) of a layer, or takes it away (below zero), the
// share of 1 left to it or of what it has; the other layers keep their
// proportions in what is left. What a single layer had goes to the first
// other layer.
weights_paint :: proc "contextless" (w:Weights,layer:int,amount:f32,count:int) -> Weights {
    if layer<0 || layer>=count {return w}
    f:[4]f32
    for i in 0..<count {f[i]=f32(w[i])/WEIGHT_FULL}
    current:=f[layer]
    target:=amount>0?current+min(amount,1)*(1-current):current*(1-min(-amount,1))
    others,rest:=1-current,1-target
    if others>1e-6 {
        for i in 0..<count {if i!=layer {f[i]*=rest/others}}
    } else if rest>0 {
        fallback:=layer==0?1:0
        if fallback>=count {return w}
        f[fallback]=rest
    }
    f[layer]=target
    return weights_quantize(f,count)
}

// Takes a layer out of the weights: the others keep their proportions.
@(private)
weights_remove :: proc "contextless" (w:Weights,layer,count:int) -> Weights {
    f:[4]f32
    at:=0
    for i in 0..<count {
        if i==layer {continue}
        f[at]=f32(w[i]);at+=1
    }
    return weights_quantize(f,count-1)
}

// How much an automatic layer covers a point: 1 inside both ranges, fading
// out over its softness.
layer_auto_cover :: proc "contextless" (auto:Layer_Auto,normal_y,height:f32) -> f32 {
    band :: proc "contextless" (value,low,high,soft:f32) -> f32 {
        if soft<=0 {return value>=low && value<=high?1:0}
        // Linear over the softness: between two samples it changes by no more than their slopes differ over it.
        return clamp((value-low+soft)/soft,0,1)*clamp((high+soft-value)/soft,0,1)
    }
    slope:=math.acos(clamp(normal_y,-1,1))
    return band(slope,auto.slope.x,auto.slope.y,auto.softness.x)*band(height,auto.height.x,auto.height.y,auto.softness.y)
}

// The weights a vertex shows: those painted, then each automatic layer in
// order covering by how much its rule takes the point.
layers_vertex :: proc "contextless" (s:^Source,painted:[4]f32,normal:[3]f32,height:f32) -> (w:[4]f32) {
    w=painted
    for i in 0..<int(s.layer_count) {
        auto:=s.layers[i].auto
        if !auto.enabled {continue}
        cover:=layer_auto_cover(auto,normal.y,height)
        w*=1-cover
        w[i]+=cover
    }
    return
}

@(private)
weights_float :: #force_inline proc "contextless" (w:Weights) -> [4]f32 {
    return {f32(w[0]),f32(w[1]),f32(w[2]),f32(w[3])}/WEIGHT_FULL
}

// The samples of the weights of a source: x, y and z of a Volume, which holds
// what is under its surface too (interior.odin); x and z otherwise.
weights_size :: proc "contextless" (s:^Source) -> [3]int {
    return {int(s.samples.x),s.kind==.Volume?int(s.samples.y):1,int(s.samples.z)}
}

// The weights of a new source: all of its first layer.
@(private)
weights_init :: proc(s:^Source) -> bool {return grid_init(&s.weights,weights_size(s),Weights{WEIGHT_FULL,0,0,0},s.allocator)}

// The painted weights at a local point: trilinear between the samples of a
// Volume, bilinear over x and z otherwise.
source_weights_at :: proc "contextless" (s:^Source,p:[3]f32) -> (w:[4]f32) {
    g:=&s.weights
    at:=(p-source_origin(s))/s.cell
    first:[3]int
    t:[3]f32
    for axis in 0..<3 {
        last:=g.size[axis]-1
        if last==0 {continue}
        v:=clamp(at[axis],0,f32(last))
        first[axis]=min(int(v),last-1)
        t[axis]=v-f32(first[axis])
    }
    for corner in 0..<8 {
        offset:=[3]int{corner&1,corner>>1&1,corner>>2&1}
        share:=f32(1)
        for axis in 0..<3 {
            if g.size[axis]==1 && offset[axis]==1 {share=0;break}
            share*=offset[axis]==1?t[axis]:1-t[axis]
        }
        if share>0 {w+=weights_float(grid_value(g,first+offset))*share}
    }
    return
}

// Sets layer index of a source, or adds one with index layer_count.
source_layer_set :: proc(s:^Source,index:int,layer:Terrain_Layer) -> bool {
    if !layer_valid(layer) || index<0 || index>int(s.layer_count) || index>=LAYERS_MAX || !source_valid(s.info) {return false}
    s.layers[index]=layer
    if index==int(s.layer_count) {s.layer_count+=1}
    return true
}

// Takes a layer away; what it covered goes to the others in their
// proportions. The last one stays.
source_layer_remove :: proc(s:^Source,index:int) -> bool {
    count:=int(s.layer_count)
    if index<0 || index>=count || count==1 {return false}
    // Each page takes values no other grid holds before they change.
    for &page in s.weights.pages {
        if page.values==nil || shared_alone(page.values) {continue}
        values,made:=shared_make(Weights,len(page.values),s.allocator)
        if !made {return false}
        copy(values,page.values)
        shared_free(page.values)
        page.values=values
    }
    for &page in s.weights.pages {
        page.altered=true
        page.fill=weights_remove(page.fill,index,count)
        for &value in page.values {value=weights_remove(value,index,count)}
    }
    Removed :: struct {index,count:int}
    removed:=Removed{index,count}
    grid_tiles_map(&s.weights,&removed,proc(user:rawptr,fill:Weights) -> Weights {
        r:=(^Removed)(user)
        return weights_remove(fill,r.index,r.count)
    })
    s.weights.filled=true
    copy(s.layers[index:count],s.layers[index+1:count])
    s.layers[count-1]={}
    s.layer_count-=1
    interior_layer_removed(&s.interior,index)
    return true
}

// The materials of the slots the chunks of a source show: that of its layers
// on slot 0, the one a terrain has.
chunk_materials :: proc "contextless" (s:^Source) -> (materials:[render.MATERIAL_SLOTS]base.Asset_Id) {
    materials[0]=s.layers_material!={}?s.layers_material:LAYERS_MATERIAL
    return
}

// The textures and values the layers of a source give the Terrain_Layers
// program, as each chunk shows them: the base color and normal maps of each
// layer material, its color, roughness and metallic, and the tiling and height
// blend of the layer. A layer without a normal map gets no strength for it.
layers_override :: proc(a:^host.Assets,s:^Source) -> (o:render.Material_Values) {
    o=render.MATERIAL_VALUES_DEFAULT
    COLORS :: [LAYERS_MAX]string{"color0","color1","color2","color3"}
    NORMALS :: [LAYERS_MAX]string{"normal0","normal1","normal2","normal3"}
    VALUES :: [LAYERS_MAX]string{"layer0","layer1","layer2","layer3"}
    DETAILS :: [LAYERS_MAX]string{"detail0","detail1","detail2","detail3"}
    colors,normals,values,details:=COLORS,NORMALS,VALUES,DETAILS
    for i in 0..<int(min(s.layer_count,LAYERS_MAX)) {
        layer:=s.layers[i]
        info:=asset.MATERIAL_DEFAULTS
        if a!=nil {if material:=host.assets_material(a,layer.material);material!=nil && !material.failed {info=material.info}}
        maps:=asset.material_maps(&info.maps)
        o.texture_names[o.texture_count],o.textures[o.texture_count]=base.name_hash(colors[i]),maps[.Base_Color].texture;o.texture_count+=1
        o.texture_names[o.texture_count],o.textures[o.texture_count]=base.name_hash(normals[i]),maps[.Normal].texture;o.texture_count+=1
        o.names[o.count],o.values[o.count]=base.name_hash(values[i]),{info.base_color.r,info.base_color.g,info.base_color.b,info.roughness};o.count+=1
        normal:=maps[.Normal].texture!={}?info.normal_scale:0
        o.names[o.count],o.values[o.count]=base.name_hash(details[i]),{layer.tiling,layer.height_blend,info.metallic,normal};o.count+=1
    }
    return
}

@(private)
weights_used :: proc "contextless" (w:Weights,count:u32) -> bool {
    if !weights_full(w) {return false}
    for i in int(count)..<LAYERS_MAX {if w[i]!=0 {return false}}
    return true
}

// Whether every weight a source holds is of its layers alone.
@(private)
weights_all_used :: proc(s:^Source) -> bool {
    for page in s.weights.pages {
        if !weights_used(page.fill,s.layer_count) {return false}
        for value in page.values {if !weights_used(value,s.layer_count) {return false}}
    }
    count:=s.layer_count
    return grid_tiles_all(&s.weights,&count,proc(user:rawptr,fill:Weights) -> bool {return weights_used(fill,(^u32)(user)^)})
}

// The weights a .terrain holds for the layers of info, into s.
@(private)
source_weights_read :: proc(s:^Source,file:^asset.Asset,types:^asset.Types,allocator:=context.allocator,paged:=false) -> bool {
    if !grid_read_document(&s.weights,file,types,weights_size(s),"weight_pages","weight_blocks",weights_full,allocator,paged) {return false}
    return weights_all_used(s)
}

@(private)
source_weights_put :: proc(document:^asset.Document,types:^asset.Types,s:^Source,keep:=false) -> asset.Error {
    if s.weights.size!=weights_size(s) || !weights_all_used(s) {return .Invalid}
    return grid_put_document(document,types,&s.weights,"weight_pages","weight_blocks",weights_full,s.file,s.allocator,keep)
}

// Whether two sets of layers make other vertex weights: the count, or a rule.
@(private)
layers_reshape :: proc "contextless" (a,b:Source_Info) -> bool {
    if a.layer_count!=b.layer_count {return true}
    for i in 0..<int(a.layer_count) {if a.layers[i].auto!=b.layers[i].auto {return true}}
    return false
}

// Paints a layer into the weights, over X/Z, or in the ball of the brush in a
// Volume: Paint adds brush.amount (a fraction, up to 1) of brush.layer at the
// center, Erase takes it away, both fading out at brush.radius.
source_paint :: proc(s:^Source,brush:Brush) -> (change:Change) {
    if brush.layer>=s.layer_count {change.error=.Layer;return}
    size:=s.weights.size
    volume:=size.y>1
    center:=(brush.center-source_origin(s))/s.cell
    reach:=brush.radius/s.cell
    if !volume {center.y=0}
    from,to:[3]int
    for axis in 0..<3 {
        if size[axis]==1 {continue}
        lo,hi:=math.ceil(center[axis]-reach),math.floor(center[axis]+reach)
        if hi<0 || lo>f32(size[axis]-1) {return}
        from[axis],to[axis]=int(max(lo,0)),int(min(hi,f32(size[axis]-1)))
    }
    if !grid_prepare(&s.weights,from,to,s.allocator) {change.error=.Out_Of_Memory;return}
    low,high:=to,from
    amount:=min(brush.amount,1)
    count:=int(s.layer_count)
    grid:=s.kind==.Heightfield
    for z in from.z..=to.z {for y in from.y..=to.y {for x in from.x..=to.x {
        offset:=[3]f32{f32(x),f32(y),f32(z)}-center
        t:=math.sqrt(offset.x*offset.x+offset.y*offset.y+offset.z*offset.z)/reach
        if t>=1 || grid && !brush_slope_allows(s,brush,x,z) {continue}
        share:=amount*brush_weight(brush,offset.xz*s.cell,t*brush.radius)
        if share<=0 {continue}
        p:=[3]int{x,y,z}
        old:=grid_value(&s.weights,p)
        if brush.kind==.Paint && brush.toward {
            // A part share of the way to target: added from what the others
            // have, or taken from what it has.
            current:=f32(old[brush.layer])/WEIGHT_FULL
            switch {
            case brush.target>current: share*=(brush.target-current)/max(1-current,1e-6)
            case brush.target<current: share*=-(current-brush.target)/max(current,1e-6)
            case: continue
            }
        }
        next:=weights_paint(old,int(brush.layer),brush.kind==.Erase?-share:share,count)
        if next==old {continue}
        grid_write(&s.weights,p,next)
        for axis in 0..<3 {low[axis],high[axis]=min(low[axis],p[axis]),max(high[axis],p[axis])}
        change.changed=true
    }}}
    if volume {grid_settle(&s.weights,from,to,s.allocator)}
    if !change.changed {return}
    change.low,change.high=low,high
    if !volume {change.high.y=int(s.samples.y)-1}
    return
}

