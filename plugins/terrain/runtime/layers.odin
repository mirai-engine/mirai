package terrain

import "core:math"
import "mirai:asset"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"

LAYERS_MAX :: 32
// The material of plugins/terrain/assets/terrain_layers.mat, whose Surface
// program (Terrain_Layers) blends the layers of a source.
LAYERS_MATERIAL :: base.Asset_Id{0x7465727261696e5f,0x6c61796572730001}
// The same program, its alpha the holes of the cells
// (terrain_layers_holed.mat): what a piece shows whose triangles span cells
// that are holes and cells that are not.
LAYERS_HOLED_MATERIAL :: base.Asset_Id{0x7465727261696e5f,0x6c61796572730002}

// A material painted over a terrain. The weights of the layers of each
// sample add up to WEIGHT_FULL.
Terrain_Layer :: struct {
    material:base.Asset_Id,
    tiling:f32 `mirai:"min=0,unit=m"`,       // metres over which the textures of its material repeat
    height_blend:f32 `mirai:"min=0,max=1"`,  // 0: the weights alone; 1: where layers meet, the higher texels (alpha of the base color map) show
    displacement:f32 `mirai:"min=0,unit=m"`, // how far the lowest texel of that height lies under the highest on a Heightfield near the view (displacement.odin); 0: flat
    detile:f32 `mirai:"min=0,max=1"`,        // how far its repeats shift against each other where a noise of the world says: 0 a plain tiling
    variation:f32 `mirai:"min=0,max=1"`,     // how much a slow noise of the world darkens and brightens it
    far_tiling:f32 `mirai:"min=0,unit=m"`,   // metres of a repeat far away, where one of tiling shrinks to a few pixels; 0: tiling everywhere
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
// The layers a sample holds, its heaviest. A point between samples blends
// those of the four around it, so it can show more.
WEIGHT_SLOTS :: 3

// The weights of a sample, as the surface maps of a piece hold them
// (terrain_surface.slang): the layers of its slots in bits 0-4, 5-9 and 10-14
// and the weights of the first two in bits 16-23 and 24-31, the third taking
// what is left of WEIGHT_FULL. The slots run from the heaviest, the lower
// layer first on a tie, and a slot without weight is of layer 0. Bit 15 is
// free: a map puts the hole of a cell there.
Weights :: distinct u32
WEIGHT_LAYER_BITS :: 5
WEIGHT_VALUES_SHIFT :: 16
WEIGHT_HOLE_BIT :: 15
WEIGHTS_FIRST :: Weights(WEIGHT_FULL<<WEIGHT_VALUES_SHIFT)
WEIGHT_HOLE :: u32(1<<WEIGHT_HOLE_BIT)
#assert(LAYERS_MAX<=1<<WEIGHT_LAYER_BITS && WEIGHT_SLOTS*WEIGHT_LAYER_BITS<=WEIGHT_HOLE_BIT && WEIGHT_HOLE_BIT<WEIGHT_VALUES_SHIFT)

// The share of each layer at a point, from 0 to 1: what blends, rules and
// brushes work with.
Layer_Mix :: [LAYERS_MAX]f32

weights_slot :: #force_inline proc "contextless" (w:Weights,slot:int) -> (layer,value:int) {
    v:=u32(w)
    layer=int(v>>(WEIGHT_LAYER_BITS*uint(slot))&(1<<WEIGHT_LAYER_BITS-1))
    first,second:=int(v>>WEIGHT_VALUES_SHIFT&255),int(v>>(WEIGHT_VALUES_SHIFT+8)&255)
    switch slot {
    case 0: value=first
    case 1: value=second
    case:   value=WEIGHT_FULL-first-second
    }
    return
}

// The weights of slots already in order.
@(private)
weights_pack :: proc "contextless" (layers,values:[WEIGHT_SLOTS]int) -> Weights {
    v:u32
    for slot in 0..<WEIGHT_SLOTS {if values[slot]>0 {v|=u32(layers[slot])<<(WEIGHT_LAYER_BITS*uint(slot))}}
    return Weights(v|u32(values[0])<<WEIGHT_VALUES_SHIFT|u32(values[1])<<(WEIGHT_VALUES_SHIFT+8))
}

layer_valid :: proc "contextless" (layer:Terrain_Layer) -> bool {
    finite :: proc "contextless" (value:f32) -> bool {return value-value==0}
    if !finite(layer.tiling) || !(layer.tiling>0) || layer.tiling>10000 || !(layer.height_blend>=0 && layer.height_blend<=1) {return false}
    if !(layer.displacement>=0 && layer.displacement<=DISPLACEMENT_MAX) {return false}
    if !(layer.detile>=0 && layer.detile<=1) || !(layer.variation>=0 && layer.variation<=1) || !(layer.far_tiling>=0 && layer.far_tiling<=10000) {return false}
    a:=layer.auto
    for value in ([6]f32{a.slope.x,a.slope.y,a.height.x,a.height.y,a.softness.x,a.softness.y}) {if !finite(value) {return false}}
    return a.slope.x>=0 && a.slope.x<=a.slope.y && a.slope.y<=math.PI/2+1e-4 && a.height.x<=a.height.y && abs(a.height.x)<=HEIGHT_LIMIT && abs(a.height.y)<=HEIGHT_LIMIT && a.softness.x>=0 && a.softness.y>=0
}

// Whether w holds weights as they are kept: in order, adding up to
// WEIGHT_FULL, each layer once and nothing in bit 15.
@(private)
weights_full :: proc "contextless" (w:Weights) -> bool {
    if u32(w)&WEIGHT_HOLE!=0 || int(u32(w)>>WEIGHT_VALUES_SHIFT&255)+int(u32(w)>>(WEIGHT_VALUES_SHIFT+8)&255)>WEIGHT_FULL {return false}
    layers,values:[WEIGHT_SLOTS]int
    for slot in 0..<WEIGHT_SLOTS {
        layers[slot],values[slot]=weights_slot(w,slot)
        if values[slot]==0 {
            if layers[slot]!=0 {return false}
            continue
        }
        for before in 0..<slot {if layers[before]==layers[slot] {return false}}
        if slot>0 && (values[slot]>values[slot-1] || values[slot]==values[slot-1] && layers[slot]<layers[slot-1]) {return false}
    }
    return true
}

// The weights that add up to WEIGHT_FULL closest to the shares of f over its
// first count layers, of its WEIGHT_SLOTS largest (keep among them while it
// has a share); the remainder goes to the largest fractions, the lower layer
// on a tie.
weights_quantize :: proc "contextless" (f:Layer_Mix,count:int,keep:=-1) -> Weights {
    count:=clamp(count,1,LAYERS_MAX)
    layers:[WEIGHT_SLOTS]int
    shares:[WEIGHT_SLOTS]f32
    taken:=0
    if keep>=0 && keep<count && f[keep]>0 {layers[0],shares[0],taken=keep,f[keep],1}
    for taken<WEIGHT_SLOTS {
        best:=-1
        for i in 0..<count {
            if !(f[i]>0) {continue}
            used:=false
            for slot in 0..<taken {if layers[slot]==i {used=true}}
            if !used && (best<0 || f[i]>f[best]) {best=i}
        }
        if best<0 {break}
        layers[taken],shares[taken]=best,f[best]
        taken+=1
    }
    if taken==0 {return WEIGHTS_FIRST}
    sum:=f32(0)
    for slot in 0..<taken {sum+=shares[slot]}
    values:[WEIGHT_SLOTS]int
    fraction:[WEIGHT_SLOTS]f32
    used:=0
    for slot in 0..<taken {
        scaled:=shares[slot]/sum*WEIGHT_FULL
        whole:=min(int(scaled),WEIGHT_FULL)
        values[slot]=whole;used+=whole
        fraction[slot]=scaled-f32(whole)
    }
    for _ in used..<WEIGHT_FULL {
        best:=0
        for slot in 1..<taken {if fraction[slot]>fraction[best] || fraction[slot]==fraction[best] && layers[slot]<layers[best] {best=slot}}
        values[best]+=1
        fraction[best]=-1
    }
    // The heaviest first, the lower layer on a tie.
    for slot in 1..<WEIGHT_SLOTS {
        for at:=slot;at>0 && values[at]>0 && (values[at]>values[at-1] || values[at]==values[at-1] && layers[at]<layers[at-1]);at-=1 {
            values[at],values[at-1]=values[at-1],values[at]
            layers[at],layers[at-1]=layers[at-1],layers[at]
        }
    }
    return weights_pack(layers,values)
}

// Adds amount (above zero) of a layer, or takes it away (below zero), the
// share of 1 left to it or of what it has; the other layers keep their
// proportions in what is left. What a single layer had goes to the first
// other layer. The layer painted keeps its slot over the others.
weights_paint :: proc "contextless" (w:Weights,layer:int,amount:f32,count:int) -> Weights {
    if layer<0 || layer>=count {return w}
    f:=weights_float(w)
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
    return weights_quantize(f,count,amount>0?layer:-1)
}

// Takes a layer out of the weights: the others keep their proportions and
// those above it take the index below.
@(private)
weights_remove :: proc "contextless" (w:Weights,layer,count:int) -> Weights {
    f:=weights_float(w)
    copy(f[layer:count],f[layer+1:count])
    f[count-1]=0
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

// The weights a point shows: those painted, then each automatic layer in
// order covering by how much its rule takes the point.
layers_vertex :: proc "contextless" (s:^Source,painted:Layer_Mix,normal:[3]f32,height:f32) -> (w:Layer_Mix) {
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

weights_float :: proc "contextless" (w:Weights) -> (f:Layer_Mix) {
    for slot in 0..<WEIGHT_SLOTS {
        layer,value:=weights_slot(w,slot)
        if value>0 {f[layer]+=f32(value)/WEIGHT_FULL}
    }
    return
}

// The samples of the weights of a source: x, y and z of a Volume, which holds
// what is under its surface too (interior.odin); x and z otherwise.
weights_size :: proc "contextless" (s:^Source) -> [3]int {
    return {int(s.samples.x),int(s.samples.y),int(s.samples.z)}
}

// The weights of a new source: all of its first layer.
@(private)
weights_init :: proc(s:^Source) -> bool {return grid_init(&s.weights,weights_size(s),WEIGHTS_FIRST,s.allocator)}

// The painted weights at a local point: trilinear between the samples of a
// Volume, bilinear over x and z otherwise.
source_weights_at :: proc "contextless" (s:^Source,p:[3]f32) -> (w:Layer_Mix) {
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

// The four heaviest layers of a mix by their materials, as core.Ground_Hit
// gives them: layers of one material add up, and the weights add up to 255.
layers_dominant :: proc "contextless" (s:^Source,f:Layer_Mix) -> (weights:[4]u8,materials:[4]base.Asset_Id) {
    merged:[LAYERS_MAX]f32
    owner:[LAYERS_MAX]int
    count:=int(s.layer_count)
    for i in 0..<count {
        owner[i]=i
        for j in 0..<i {if s.layers[j].material==s.layers[i].material {owner[i]=owner[j];break}}
        merged[owner[i]]+=max(f[i],0)
    }
    picked:[4]int={-1,-1,-1,-1}
    shares:[4]f32
    sum:=f32(0)
    for slot in 0..<4 {
        best:=-1
        for i in 0..<count {
            if owner[i]!=i || !(merged[i]>0) || i==picked[0] || i==picked[1] || i==picked[2] {continue}
            if best<0 || merged[i]>merged[best] {best=i}
        }
        if best<0 {break}
        picked[slot],shares[slot]=best,merged[best]
        sum+=merged[best]
    }
    if !(sum>0) {weights[0],materials[0]=WEIGHT_FULL,s.layers[0].material;return}
    used:=0
    for slot in 0..<4 {
        if picked[slot]<0 {break}
        weights[slot]=u8(shares[slot]/sum*WEIGHT_FULL)
        used+=int(weights[slot])
        materials[slot]=s.layers[picked[slot]].material
    }
    weights[0]+=u8(WEIGHT_FULL-used)
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

// The material a piece shows on slot 0, the one a terrain has: that of the
// layers of its source, or with holes (holed) the one that cuts them. A
// program of its own cuts no holes: its piece keeps them in its triangles.
piece_material :: proc "contextless" (s:^Source,holed:=false) -> base.Asset_Id {
    if s.layers_material!={} {return s.layers_material}
    return holed?LAYERS_HOLED_MATERIAL:LAYERS_MATERIAL
}

// The materials of the slots of a piece without holes.
chunk_materials :: proc "contextless" (s:^Source) -> (materials:[render.MATERIAL_SLOTS]base.Asset_Id) {
    materials[0]=piece_material(s)
    return
}

// The table of the layers of a source the Terrain_Layers program reads
// (terrain_surface.slang): a row of LAYERS_TEXELS texels for each layer,
// each texel four bytes of a value. The textures of a layer are by their
// place in the texture table of the renderer, INVALID without one.
LAYERS_TEXELS :: 8
layers_table :: proc(a:^host.Assets,s:^Source,pixels:[]u8) {
    word :: proc(pixels:[]u8,layer,texel:int,value:u32) {
        at:=4*(texel+LAYERS_TEXELS*layer)
        pixels[at],pixels[at+1],pixels[at+2],pixels[at+3]=u8(value),u8(value>>8),u8(value>>16),u8(value>>24)
    }
    bytes :: proc(pixels:[]u8,layer,texel:int,values:[4]f32) {
        at:=4*(texel+LAYERS_TEXELS*layer)
        for v,i in values {pixels[at+i]=u8(clamp(v,0,1)*255+0.5)}
    }
    index :: proc(a:^host.Assets,id:base.Asset_Id) -> u32 {
        if a==nil {return max(u32)}
        texture:=host.assets_texture_image(a,id)
        if texture==nil || texture.failed || texture.handle==0 {return max(u32)}
        return render.texture_index(texture.handle)
    }
    for i in 0..<int(s.layer_count) {
        if 4*LAYERS_TEXELS*(i+1)>len(pixels) {break}
        layer:=s.layers[i]
        info:=asset.MATERIAL_DEFAULTS
        if a!=nil {if material:=host.assets_material(a,layer.material);material!=nil && !material.failed {info=material.info}}
        maps:=asset.material_maps(&info.maps)
        color,normal:=index(a,maps[.Base_Color].texture),index(a,maps[.Normal].texture)
        word(pixels,i,0,color)
        word(pixels,i,1,normal)
        bytes(pixels,i,2,{info.base_color.r,info.base_color.g,info.base_color.b,info.roughness})
        bytes(pixels,i,3,{info.metallic,layer.height_blend,layer.detile,layer.variation})
        word(pixels,i,4,transmute(u32)layer.tiling)
        word(pixels,i,5,transmute(u32)layer.far_tiling)
        word(pixels,i,6,transmute(u32)(normal!=max(u32)?info.normal_scale:0))
        word(pixels,i,7,transmute(u32)layer.displacement)
    }
}

@(private)
weights_used :: proc "contextless" (w:Weights,count:u32) -> bool {
    if !weights_full(w) {return false}
    for slot in 0..<WEIGHT_SLOTS {
        layer,value:=weights_slot(w,slot)
        if value>0 && layer>=int(count) {return false}
    }
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

// Whether two sets of layers make other weights in the pieces: the count, or a rule.
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
            current:=weights_float(old)[brush.layer]
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
