package terrain

import "base:runtime"
import "core:math"
import "core:math/linalg"

// Regions of a Heightfield: a copy of its heights and weights over a box of
// samples, put back elsewhere (paste, stamp) turned, mirrored and raised, and
// the mirror of one half over the other. Each is a transaction that may
// allocate; what they change is a Change, as a brush's.

Region :: struct {
    allocator:runtime.Allocator,
    size:[2]int,      // samples along x and z
    cell:f32,         // metres between two of them
    layer_count:u32,
    heights:[]f32,    // x first
    weights:[]Weights,
}

region_destroy :: proc(r:^Region) {
    delete(r.heights,r.allocator)
    delete(r.weights,r.allocator)
    r^={}
}

// The samples of a Heightfield from low to high, inclusive and clamped to
// it; false for another kind, a box outside it or without memory.
source_region_copy :: proc(s:^Source,low,high:[2]int,r:^Region,allocator:=context.allocator) -> bool {
    if s.kind!=.Heightfield || !source_valid(s.info) || !source_samples_held(s) {return false}
    from:=[2]int{max(min(low.x,high.x),0),max(min(low.y,high.y),0)}
    to:=[2]int{min(max(low.x,high.x),int(s.samples.x)-1),min(max(low.y,high.y),int(s.samples.z)-1)}
    if to.x<from.x || to.y<from.y {return false}
    size:=to-from+1
    next:=Region{allocator=allocator,size=size,cell=s.cell,layer_count=s.layer_count}
    error:runtime.Allocator_Error
    if next.heights,error=make([]f32,size.x*size.y,allocator);error!=nil {return false}
    if next.weights,error=make([]Weights,size.x*size.y,allocator);error!=nil {region_destroy(&next);return false}
    for z in 0..<size.y {for x in 0..<size.x {
        next.heights[x+size.x*z]=grid_get(&s.field,from.x+x,from.y+z)
        next.weights[x+size.x*z]=grid_get(&s.weights,from.x+x,from.y+z)
    }}
    region_destroy(r)
    r^=next
    return true
}

// How a region goes onto a Heightfield. center: where its middle goes, in
// the space of the source. turn: radians around y, after mirror flips its x.
// offset: metres added to its heights. blend: metres inside its edges over
// which it fades into the ground. way: Up only raises, Down only lowers.
// weights: its layers too, when the source has as many.
Region_Paste :: struct {
    center:[2]f32,
    turn:f32,
    mirror:bool,
    offset:f32,
    blend:f32,
    way:Brush_Way,
    weights:bool,
}

// Puts a region onto a Heightfield, read between its samples at the spacing
// of the source.
source_region_paste :: proc(s:^Source,r:^Region,p:Region_Paste) -> (change:Change) {
    if s.kind!=.Heightfield || !source_valid(s.info) || !source_samples_held(s) {return Change{error=.Unloaded}}
    finite :: proc "contextless" (v:f32) -> bool {return v-v==0}
    if r.size.x<1 || r.size.y<1 || len(r.heights)!=r.size.x*r.size.y || len(r.weights)!=len(r.heights) || !(r.cell>0) {return Change{error=.Invalid}}
    if !finite(p.center.x) || !finite(p.center.y) {return Change{error=.Center}}
    if !finite(p.turn) {return Change{error=.Slope}}
    if !finite(p.offset) || abs(p.offset)>HEIGHT_LIMIT {return Change{error=.Target}}
    if !(p.blend>=0) || p.blend>HEIGHT_LIMIT {return Change{error=.Blend}}
    if p.way>.Down {return Change{error=.Falloff}}
    half:=[2]f32{f32(r.size.x-1),f32(r.size.y-1)}*r.cell*0.5
    c,sn:=math.cos(p.turn),math.sin(p.turn)
    reach:=linalg.length(half)
    origin:=source_origin(s)
    low,high:[2]int
    for axis in 0..<2 {
        o:=axis==0?origin.x:origin.z
        n:=int(axis==0?s.samples.x:s.samples.z)
        lo,hi:=int(math.ceil((p.center[axis]-reach-o)/s.cell)),int(math.floor((p.center[axis]+reach-o)/s.cell))
        if hi<0 || lo>n-1 {return}
        low[axis],high[axis]=max(lo,0),min(hi,n-1)
    }
    if !grid_prepare(&s.field,{low.x,0,low.y},{high.x,0,high.y},s.allocator) {return Change{error=.Out_Of_Memory}}
    layers:=p.weights && r.layer_count==s.layer_count
    if layers && !grid_prepare(&s.weights,{low.x,0,low.y},{high.x,0,high.y},s.allocator) {return Change{error=.Out_Of_Memory}}
    change.low,change.high={high.x,0,high.y},{low.x,0,low.y}
    for z in low.y..=high.y {for x in low.x..=high.x {
        d:=[2]f32{origin.x+f32(x)*s.cell,origin.z+f32(z)*s.cell}-p.center
        // Into the frame of the region: turned back, then mirrored. A turn
        // takes its +x toward -z, as a turn around +y does.
        q:=[2]f32{c*d.x-sn*d.y,sn*d.x+c*d.y}
        if p.mirror {q.x=-q.x}
        if abs(q.x)>half.x+1e-4*r.cell || abs(q.y)>half.y+1e-4*r.cell {continue}
        edge:=min(half.x-abs(q.x),half.y-abs(q.y))
        alpha:=p.blend>0?math.smoothstep(f32(0),f32(1),clamp(edge/p.blend,0,1)):1
        if alpha<=0 {continue}
        u:=[2]f32{max(q.x+half.x,0),max(q.y+half.y,0)}/r.cell
        i0:=[2]int{min(int(u.x),r.size.x-1),min(int(u.y),r.size.y-1)}
        i1:=[2]int{min(i0.x+1,r.size.x-1),min(i0.y+1,r.size.y-1)}
        f:=u-[2]f32{f32(i0.x),f32(i0.y)}
        at :: #force_inline proc "contextless" (r:^Region,x,z:int) -> f32 {return r.heights[x+r.size.x*z]}
        h:=math.lerp(math.lerp(at(r,i0.x,i0.y),at(r,i1.x,i0.y),f.x),math.lerp(at(r,i0.x,i1.y),at(r,i1.x,i1.y),f.x),f.y)
        old:=grid_get(&s.field,x,z)
        value:=clamp(brush_way_keep(p.way,false,old,math.lerp(old,h+p.offset,alpha)),-HEIGHT_LIMIT,HEIGHT_LIMIT)
        touched:=value!=old
        if touched {grid_set(&s.field,x,z,value)}
        if layers {
            nearest:=r.weights[clamp(int(u.x+0.5),0,r.size.x-1)+r.size.x*clamp(int(u.y+0.5),0,r.size.y-1)]
            w:=grid_get(&s.weights,x,z)
            next:=alpha>=1?nearest:weights_quantize(math.lerp(weights_float(w),weights_float(nearest),alpha),int(s.layer_count))
            if next!=w {grid_set(&s.weights,x,z,next);touched=true}
        }
        if !touched {continue}
        change.changed=true
        change.low.x,change.low.z=min(change.low.x,x),min(change.low.z,z)
        change.high.x,change.high.z=max(change.high.x,x),max(change.high.z,z)
    }}
    return
}

// Mirrors a Heightfield over the plane across axis (0: x, 1: z) at sample
// at: the half past it (keep_high: the one before it) takes the heights and
// weights of the half it keeps. rotate turns that half around the center
// instead of mirroring it, as a map for two sides that face each other has
// it. Over blend samples on each side of the plane both halves mix, so the
// ground meets itself at the plane; a sample whose image falls off the
// source stays as it was.
source_mirror :: proc(s:^Source,axis:int,at:int,keep_high:=false,rotate:=false,blend:=0) -> (change:Change) {
    if s.kind!=.Heightfield || !source_valid(s.info) || !source_samples_held(s) {return Change{error=.Unloaded}}
    n:=[2]int{int(s.samples.x),int(s.samples.z)}
    if axis<0 || axis>1 || at<0 || at>=n[axis] || blend<0 {return Change{error=.Invalid}}
    band:=min(blend,n[axis])
    // The samples it writes: the replaced half and the band before the plane.
    low,high:=[2]int{0,0},n-1
    if keep_high {high[axis]=min(at+band,n[axis]-1)} else {low[axis]=max(at-band,0)}
    count:=(high.x-low.x+1)*(high.y-low.y+1)
    heights,error:=make([]f32,count,context.temp_allocator)
    if error!=nil {return Change{error=.Out_Of_Memory}}
    weights,weights_error:=make([]Weights,count,context.temp_allocator)
    if weights_error!=nil {return Change{error=.Out_Of_Memory}}
    other:=1-axis
    // The new values come from the samples as they were, so they are made first.
    for z in low.y..=high.y {for x in low.x..=high.x {
        p:=[2]int{x,z}
        i:=x-low.x+(high.x-low.x+1)*(z-low.y)
        heights[i],weights[i]=grid_get(&s.field,x,z),grid_get(&s.weights,x,z)
        m:=p
        m[axis]=2*at-p[axis]
        if rotate {m[other]=n[other]-1-p[other]}
        if m[axis]<0 || m[axis]>=n[axis] {continue}
        d:=keep_high?at-p[axis]:p[axis]-at // toward the replaced half
        alpha:=f32(1)
        if d<=band {
            fraction:=f32(d+band+1)/f32(2*band+2)
            alpha=0.5-0.5*math.cos(fraction*math.PI)
        }
        mirrored,mirrored_weights:=grid_get(&s.field,m.x,m.y),grid_get(&s.weights,m.x,m.y)
        heights[i]=math.lerp(heights[i],mirrored,alpha)
        weights[i]=alpha>=1?mirrored_weights:weights_quantize(math.lerp(weights_float(weights[i]),weights_float(mirrored_weights),alpha),int(s.layer_count))
    }}
    if !grid_prepare(&s.field,{low.x,0,low.y},{high.x,0,high.y},s.allocator) || !grid_prepare(&s.weights,{low.x,0,low.y},{high.x,0,high.y},s.allocator) {return Change{error=.Out_Of_Memory}}
    change.low,change.high={high.x,0,high.y},{low.x,0,low.y}
    for z in low.y..=high.y {for x in low.x..=high.x {
        i:=x-low.x+(high.x-low.x+1)*(z-low.y)
        if heights[i]==grid_get(&s.field,x,z) && weights[i]==grid_get(&s.weights,x,z) {continue}
        grid_set(&s.field,x,z,heights[i])
        grid_set(&s.weights,x,z,weights[i])
        change.changed=true
        change.low.x,change.low.z=min(change.low.x,x),min(change.low.z,z)
        change.high.x,change.high.z=max(change.high.x,x),max(change.high.z,z)
    }}
    return
}
