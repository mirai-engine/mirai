package ai

import "base:runtime"
import "core:math"
import mm "mirai:std/math"

// Influence maps: a grid over the ground (x and z) whose layers hold how much
// of something is near each cell: the presence of a side, which a reader adds
// up as threat or as allies. A pass stamps the sources into their cells and
// spreads every layer to the neighbors of each cell, `falloff` less per metre,
// blended with what the cell held; it runs over `cells` cells a tick, so a
// tick costs at most that, and the map a reader sees is the last finished
// pass. Each cell keeps too the eight directions in which something blocks a
// body near it (cover), which the caller measures and writes. Plain slices
// made once: nothing allocates after influence_init.

Cell :: [2]i32

NEIGHBORS_8 :: [8]Cell{{1,0},{-1,0},{0,1},{0,-1},{1,1},{-1,1},{1,-1},{-1,-1}}

INFLUENCE_DIRECTIONS :: 8 // of the cover of a cell: bit d faces the angle d*45° from +x toward +z

Influence_Grid :: struct {
    origin:[2]f32, // m: x and z of the corner of the first cell
    cell:f32,      // m across a cell
    width,height,layers:int,
    values:[]f32,  // of the last finished pass, layer after layer of rows
    next:[]f32,    // of the pass that runs
    sources:[]f32, // stamped for the pass that runs
    cover:[]u8,    // directions blocked, one byte a cell
    known:[]u8,    // 1 for a cell whose cover was measured
    cursor:int,    // the next cell of the pass, over all the layers
    passes:u64,    // finished
    allocator:runtime.Allocator,
}

// False for a size that is not positive or too large, or without memory.
influence_init :: proc(g:^Influence_Grid,origin:[2]f32,cell:f32,width,height,layers:int,allocator:=context.allocator) -> bool {
    influence_destroy(g)
    g^={allocator=allocator}
    if !(cell>0) || cell>max(f32) || width<=0 || height<=0 || layers<=0 || width>(1<<16) || height>(1<<16) || layers>64 {return false}
    count:=width*height
    values,e0:=make([]f32,count*layers,allocator)
    next,e1:=make([]f32,count*layers,allocator)
    sources,e2:=make([]f32,count*layers,allocator)
    cover,e3:=make([]u8,count,allocator)
    known,e4:=make([]u8,count,allocator)
    g^={origin=origin,cell=cell,width=width,height=height,layers=layers,values=values,next=next,sources=sources,cover=cover,known=known,allocator=allocator}
    if e0!=nil || e1!=nil || e2!=nil || e3!=nil || e4!=nil {influence_destroy(g);return false}
    return true
}

influence_destroy :: proc(g:^Influence_Grid) {
    if g.allocator.procedure!=nil {
        delete(g.values,g.allocator);delete(g.next,g.allocator);delete(g.sources,g.allocator)
        delete(g.cover,g.allocator);delete(g.known,g.allocator)
    }
    g^={}
}

influence_ready :: #force_inline proc "contextless" (g:^Influence_Grid) -> bool {
    return g!=nil && g.width>0 && g.height>0 && g.layers>0 && len(g.values)==g.width*g.height*g.layers && len(g.cover)==g.width*g.height
}

// The cell of a point, and whether it is in the grid.
influence_cell :: proc "contextless" (g:^Influence_Grid,position:mm.Vec3) -> (cell:Cell,inside:bool) {
    if !influence_ready(g) {return}
    x:=(position.x-g.origin.x)/g.cell
    z:=(position.z-g.origin.y)/g.cell
    if !(x>=0 && z>=0 && x<f32(g.width) && z<f32(g.height)) {return}
    return {i32(x),i32(z)},true
}

// The middle of a cell, at height y.
influence_center :: proc "contextless" (g:^Influence_Grid,cell:Cell,y:f32) -> mm.Vec3 {
    return {g.origin.x+(f32(cell.x)+0.5)*g.cell,y,g.origin.y+(f32(cell.y)+0.5)*g.cell}
}

// Whether a pass is between its sources and its last cell: a new one stamps
// first. Stamping when no pass runs starts one.
influence_running :: #force_inline proc "contextless" (g:^Influence_Grid) -> bool {return g.cursor>0}

// Adds a source to the pass that runs: `strength` in the cell of the
// position, of the layer. A source outside the grid or of another layer
// stamps nothing.
influence_stamp :: proc "contextless" (g:^Influence_Grid,layer:int,position:mm.Vec3,strength:f32) {
    cell,inside:=influence_cell(g,position)
    if !inside || layer<0 || layer>=g.layers || !(strength>0) || strength>max(f32) {return}
    at:=layer*g.width*g.height+int(cell.y)*g.width+int(cell.x)
    g.sources[at]+=strength
}

// Spreads the pass that runs over at most `cells` cells: each takes the
// largest of its sources and of its neighbors in the last pass, `falloff` less
// per metre (a fraction from 0 to 1), and moves `blend` of the way there from
// what it held (1: at once). Returns true when the pass finished: its values
// are the map now, and the next pass begins with no sources.
influence_spread :: proc "contextless" (g:^Influence_Grid,cells:int,falloff,blend:f32) -> bool {
    if !influence_ready(g) || cells<=0 {return false}
    keep:=clamp(falloff,0,1) if falloff==falloff else 0
    step:=math.pow(1-keep,g.cell)
    diagonal:=math.pow(1-keep,g.cell*math.SQRT_TWO)
    mix:=clamp(blend,0,1) if blend==blend else 1
    plane:=g.width*g.height
    total:=plane*g.layers
    for _ in 0..<cells {
        if g.cursor>=total {break}
        i:=g.cursor
        g.cursor+=1
        layer:=i/plane
        rest:=i%plane
        x,z:=rest%g.width,rest/g.width
        base:=layer*plane
        best:=g.sources[i]
        for o in NEIGHBORS_8 {
            nx,nz:=x+int(o.x),z+int(o.y)
            if nx<0 || nz<0 || nx>=g.width || nz>=g.height {continue}
            v:=g.values[base+nz*g.width+nx]*(step if o.x==0 || o.y==0 else diagonal)
            if v>best {best=v}
        }
        held:=g.values[i]
        g.next[i]=held+(best-held)*mix
    }
    if g.cursor<total {return false}
    g.values,g.next=g.next,g.values
    for &s in g.sources {s=0}
    g.cursor=0
    g.passes+=1
    return true
}

// The value of a layer at a point, between the four nearest cells; 0 outside.
influence_sample :: proc "contextless" (g:^Influence_Grid,layer:int,position:mm.Vec3) -> f32 {
    if !influence_ready(g) || layer<0 || layer>=g.layers {return 0}
    x:=(position.x-g.origin.x)/g.cell-0.5
    z:=(position.z-g.origin.y)/g.cell-0.5
    if !(x>-1 && z>-1 && x<f32(g.width) && z<f32(g.height)) {return 0}
    x0,z0:=int(math.floor(x)),int(math.floor(z))
    fx,fz:=x-f32(x0),z-f32(z0)
    base:=layer*g.width*g.height
    at :: proc "contextless" (g:^Influence_Grid,base,x,z:int) -> f32 {
        if x<0 || z<0 || x>=g.width || z>=g.height {return 0}
        return g.values[base+z*g.width+x]
    }
    a:=at(g,base,x0,z0)+(at(g,base,x0+1,z0)-at(g,base,x0,z0))*fx
    b:=at(g,base,x0,z0+1)+(at(g,base,x0+1,z0+1)-at(g,base,x0,z0+1))*fx
    return a+(b-a)*fz
}

// The direction of the cover of a cell that faces from a point toward another.
influence_direction :: proc "contextless" (from,toward:mm.Vec3) -> (direction:int,ok:bool) {
    dx,dz:=toward.x-from.x,toward.z-from.z
    if !(dx*dx+dz*dz>1e-8) {return}
    angle:=math.atan2(dz,dx)
    return int(math.round(angle/(math.PI/4))+INFLUENCE_DIRECTIONS)%INFLUENCE_DIRECTIONS,true
}

// Writes the cover of a cell: the directions in which something blocks a body.
influence_cover_set :: proc "contextless" (g:^Influence_Grid,cell:Cell,blocked:u8) {
    if !influence_ready(g) || cell.x<0 || cell.y<0 || int(cell.x)>=g.width || int(cell.y)>=g.height {return}
    at:=int(cell.y)*g.width+int(cell.x)
    g.cover[at]=blocked
    g.known[at]=1
}

// How well a point is covered from another: 1 when something blocks the way
// toward it beside the point, 0.5 when only a direction next to it is
// blocked, 0 when nothing is or the cell was not measured.
influence_cover :: proc "contextless" (g:^Influence_Grid,position,from:mm.Vec3) -> f32 {
    cell,inside:=influence_cell(g,position)
    if !inside {return 0}
    at:=int(cell.y)*g.width+int(cell.x)
    if g.known[at]==0 {return 0}
    d,ok:=influence_direction(position,from)
    if !ok {return 0}
    bits:=g.cover[at]
    if bits&(1<<uint(d))!=0 {return 1}
    if bits&(1<<uint((d+1)%INFLUENCE_DIRECTIONS))!=0 || bits&(1<<uint((d+INFLUENCE_DIRECTIONS-1)%INFLUENCE_DIRECTIONS))!=0 {return 0.5}
    return 0
}
