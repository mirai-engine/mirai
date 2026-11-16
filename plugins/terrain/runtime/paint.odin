package terrain

import "core:math"
import "mirai:asset"

// The color and roughness painted over the layers of a Heightfield, one per
// sample: a tint the layers show multiplied by (sRGB), and how much rougher
// (above PAINT_NEUTRAL.a) or smoother (below) they are. A source holds no
// pages of it until something is painted.
Paint :: [4]u8
PAINT_ROUGHNESS_NEUTRAL :: 128
PAINT_NEUTRAL :: Paint{255,255,255,PAINT_ROUGHNESS_NEUTRAL}

@(private)
paint_valid :: proc "contextless" (value:Paint) -> bool {return true}

// The samples of the paint of a source; none for a Volume.
@(private)
paint_size :: proc "contextless" (s:^Source) -> [3]int {
    return s.kind==.Heightfield?{int(s.samples.x),1,int(s.samples.z)}:{}
}

// Takes the paint of the samples within brush.radius of brush.center, over
// X/Z, a share of the way toward brush.color (Tint: white shows the layers as
// they are) or brush.target of roughness (Roughness: 0 smooth, 0.5 the layers
// as they are, 1 rough). The share is brush.amount at the center, fading out
// at brush.radius.
@(private)
source_paint_edit :: proc(s:^Source,brush:Brush) -> (change:Change) {
    size:=paint_size(s)
    if size=={} {change.error=.Kind;return}
    if grid_none(&s.paint) {
        if !grid_init(&s.paint,size,PAINT_NEUTRAL,s.allocator) {change.error=.Out_Of_Memory;return}
    }
    origin:=source_origin(s)
    center:=[2]f32{(brush.center.x-origin.x)/s.cell,(brush.center.z-origin.z)/s.cell}
    reach:=brush.radius/s.cell
    from,to:[2]int
    for axis in 0..<2 {
        lo,hi:=math.ceil(center[axis]-reach),math.floor(center[axis]+reach)
        if hi<0 || lo>f32(size[axis*2]-1) {return}
        from[axis],to[axis]=int(max(lo,0)),int(min(hi,f32(size[axis*2]-1)))
    }
    if !grid_prepare(&s.paint,{from.x,0,from.y},{to.x,0,to.y},s.allocator) {change.error=.Out_Of_Memory;return}
    goal:=brush.kind==.Tint?[4]f32{brush.color.r,brush.color.g,brush.color.b,-1}:[4]f32{-1,-1,-1,brush.target}
    amount:=min(brush.amount,1)
    low,high:=to,from
    for z in from.y..=to.y {for x in from.x..=to.x {
        offset:=[2]f32{f32(x),f32(z)}-center
        t:=math.sqrt(offset.x*offset.x+offset.y*offset.y)/reach
        if t>=1 || !brush_slope_allows(s,brush,x,z) {continue}
        share:=amount*brush_weight(brush,offset*s.cell,t*brush.radius)
        if share<=0 {continue}
        old:=grid_get(&s.paint,x,z)
        next:=old
        for channel in 0..<4 {
            if goal[channel]<0 {continue}
            // The color goes in sRGB, as the texture is read; roughness from PAINT_NEUTRAL.a at 0.5.
            target:=channel<3?goal[channel]*255:goal[channel]<=0.5?goal[channel]*2*f32(PAINT_NEUTRAL.a):f32(PAINT_NEUTRAL.a)+(goal[channel]-0.5)*2*(255-f32(PAINT_NEUTRAL.a))
            value:=f32(old[channel])
            moved:=value+(target-value)*share
            // A part of a step still moves it, so a weak brush reaches its goal.
            if moved!=target && abs(moved-value)<1 {moved=value+math.sign(target-value)}
            next[channel]=u8(clamp(math.round(moved),0,255))
        }
        if next==old {continue}
        grid_set(&s.paint,x,z,next)
        low,high={min(low.x,x),min(low.y,z)},{max(high.x,x),max(high.y,z)}
        change.changed=true
    }}
    if !change.changed {return}
    change.low,change.high={low.x,0,low.y},{high.x,0,high.y}
    return
}

@(private)
source_paint_read :: proc(s:^Source,file:^asset.Asset,types:^asset.Types,allocator:=context.allocator,paged:=false) -> bool {
    if _,found:=asset.asset_table(file,"paint_pages");!found {return true}
    return paint_size(s)!={} && grid_read_document(&s.paint,file,types,paint_size(s),"paint_pages","paint_blocks",paint_valid,allocator,paged)
}

@(private)
source_paint_put :: proc(document:^asset.Document,types:^asset.Types,s:^Source,keep:=false) -> asset.Error {
    if grid_none(&s.paint) {return .None}
    if s.paint.size!=paint_size(s) {return .Invalid}
    return grid_put_document(document,types,&s.paint,"paint_pages","paint_blocks",paint_valid,s.file,s.allocator,keep)
}
