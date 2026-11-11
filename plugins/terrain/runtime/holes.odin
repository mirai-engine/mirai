package terrain

import "core:math"
import "mirai:asset"

// Holes of a Heightfield: cells without surface, drawn or collided. The grid
// of a source is (samples.x-1) by (samples.z-1) cells and holds pages only
// once a cell is a hole.

source_hole :: #force_inline proc "contextless" (s:^Source,x,z:int) -> bool {
    return !grid_none(&s.holes) && grid_get(&s.holes,x,z)!=0
}

@(private)
hole_valid :: proc "contextless" (value:u8) -> bool {return value<=1}

// The cells of the grid of holes of a source; none for a Volume.
@(private)
holes_size :: proc "contextless" (s:^Source) -> [3]int {
    return s.kind==.Heightfield?{int(s.samples.x)-1,1,int(s.samples.z)-1}:{}
}

// Whether chunk index has a hole: it stays at level 0, the holes exact.
chunk_holed :: proc "contextless" (s:^Source,index:int) -> bool {
    if grid_none(&s.holes) {return false}
    low,high,valid:=chunk_region(s,chunk_coord(s,index))
    if !valid {return false}
    for pz in low.z/PAGE..=(high.z-1)/PAGE {for px in low.x/PAGE..=(high.x-1)/PAGE {
        // A page in its block has cells of both values: taken as holed until it is read.
        if grid_absent(&s.holes,px+s.holes.counts.x*pz) {return true}
        page:=&s.holes.pages[px+s.holes.counts.x*pz]
        if page.values==nil {
            if page.fill!=0 {return true}
            continue
        }
        for z in max(low.z,pz*PAGE)..<min(high.z,pz*PAGE+PAGE) {for x in max(low.x,px*PAGE)..<min(high.x,px*PAGE+PAGE) {
            if page.values[x-px*PAGE+min(PAGE,s.holes.size.x-px*PAGE)*(z-pz*PAGE)]!=0 {return true}
        }}
    }}
    return false
}

// Cuts holes (Hole) or fills them (Fill) in the cells whose centers are
// within brush.radius of brush.center, over X/Z.
@(private)
source_holes_edit :: proc(s:^Source,brush:Brush) -> (change:Change) {
    cells:=holes_size(s)
    if cells=={} {change.error=.Kind;return}
    size:=cells.xz
    if grid_none(&s.holes) {
        if brush.kind==.Fill {return}
        if !grid_init(&s.holes,cells,0,s.allocator) {change.error=.Out_Of_Memory;return}
    }
    origin:=source_origin(s)
    center:=[2]f32{(brush.center.x-origin.x)/s.cell-0.5,(brush.center.z-origin.z)/s.cell-0.5}
    reach:=brush.radius/s.cell
    from,to:[2]int
    for axis in 0..<2 {
        lo,hi:=math.ceil(center[axis]-reach),math.floor(center[axis]+reach)
        if hi<0 || lo>f32(size[axis]-1) {return}
        from[axis],to[axis]=int(max(lo,0)),int(min(hi,f32(size[axis]-1)))
    }
    if !grid_prepare(&s.holes,{from.x,0,from.y},{to.x,0,to.y},s.allocator) {change.error=.Out_Of_Memory;return}
    value:=u8(brush.kind==.Hole?1:0)
    low,high:=to,from
    for z in from.y..=to.y {for x in from.x..=to.x {
        offset:=[2]f32{f32(x),f32(z)}-center
        if offset.x*offset.x+offset.y*offset.y>reach*reach || grid_get(&s.holes,x,z)==value {continue}
        // An alpha cuts where it is at least half; the slope is the one of the cell's corner.
        if brush.alpha!=nil && alpha_sample(brush.alpha^,offset*s.cell,brush.radius,brush.turn)<0.5 || !brush_slope_allows(s,brush,x,z) {continue}
        grid_set(&s.holes,x,z,value)
        low,high={min(low.x,x),min(low.y,z)},{max(high.x,x),max(high.y,z)}
        change.changed=true
    }}
    if !change.changed {return}
    // The samples of the cells: their vertices, and the edges of the collider around them.
    change.low,change.high={low.x,0,low.y},{high.x+1,0,high.y+1}
    return
}

@(private)
source_holes_read :: proc(s:^Source,file:^asset.Asset,types:^asset.Types,allocator:=context.allocator,paged:=false) -> bool {
    if _,found:=asset.asset_table(file,"hole_pages");!found {return true}
    return holes_size(s)!={} && grid_read_document(&s.holes,file,types,holes_size(s),"hole_pages","hole_blocks",hole_valid,allocator,paged)
}

@(private)
source_holes_put :: proc(document:^asset.Document,types:^asset.Types,s:^Source,keep:=false) -> asset.Error {
    if grid_none(&s.holes) {return .None}
    if s.holes.size!=holes_size(s) {return .Invalid}
    return grid_put_document(document,types,&s.holes,"hole_pages","hole_blocks",hole_valid,s.file,s.allocator,keep)
}
