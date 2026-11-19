package importer

import "base:runtime"
import "core:math"
import "core:mem"
import "mirai:std/geom"

// Outlines of what a mask keeps of a card: the polygons a masked card is cut
// to so it is drawn opaque, without the alpha test, from the finest the
// texture shows to a convex quadrilateral.
//
// An outline at a tolerance of t texels: the mask closed by a disk of radius
// t (gaps and holes narrower than about 2t filled, nothing farther than t
// from what it keeps), its texel edges traced into loops (4-connected
// pieces, their holes apart), each loop simplified by Douglas-Peucker at t
// and every kept edge moved out until the edges it replaced are behind it,
// a sharp tip cut square. It is conservative: every texel the mask keeps is
// drawn. Its error is measured, not assumed: the farthest texel it draws
// from one the mask keeps. The tolerances go from OUTLINE_FINEST texels by
// factors of √2 to OUTLINE_COARSEST of the side; with them, the convex
// outlines of eight corners down to four (the convex hull, then the edge
// whose neighbours meet adding the least area removed down to
// OUTLINE_HULL_EDGES, then the k of those edges whose lines close the least
// area, tried all). The ladder keeps
// those of at most OUTLINE_TRIANGLES that draw fewer triangles, or as many
// and less area, than every one of less error: what a level whose error
// allows it takes. A finer outline would draw more triangles than its leaf
// shows wherever it is near: level 0 takes the first, with its error.
//
// A mask wider than OUTLINE_MASK_SIDE is cut on cells of several texels: a
// cell is kept where any of its texels is, so nothing kept is lost, and the
// error of an outline is that of its cells, which it touches whole, grown by
// the cell it starts from and the one it ends in. Its work takes at most
// OUTLINE_WORK_BYTES for each of its cells, taken once and given back as it
// ends: a mask of any size cuts in bounded memory, and one that cannot have
// it keeps its alpha test.
//
// Whether a card is drawn as its outlines is decided by what its mask costs
// to cut out: the fewest triangles an outline needs to draw at most
// 1/OUTLINE_COVERAGE of what the mask keeps. A single leaf needs a few; a
// card that holds a cluster of leaves needs many and keeps its mask, drawn
// on the tightest convex outline of up to eight corners that does not add
// OUTLINE_HULL_SLACK of the area to the one of eight.

OUTLINE_FINEST :: f32(1)         // texels: the finest tolerance; finer, an outline follows steps of the texels that filtering does not show
OUTLINE_COARSEST :: f32(0.25)    // of the side of a card: the coarsest tolerance
OUTLINE_STEPS :: 22              // tolerances at most, each √2 coarser than the one before
OUTLINE_RUNGS :: OUTLINE_STEPS+5 // with the convex outlines of eight corners down to four
OUTLINE_COVERAGE :: f64(0.75)    // of what an outline draws, the share the mask keeps that the rule of a leaf asks for
OUTLINE_TRIANGLES :: 16          // the most triangles a leaf needs to reach OUTLINE_COVERAGE, and an outline of the ladder draws
OUTLINE_HULL_SLACK :: f64(0.05)
OUTLINE_HULL_EDGES :: 24         // of the convex hull, kept to choose the convex outlines from
// Cells a side of the mask an outline is cut on: one of the ladder has at most
// OUTLINE_TRIANGLES+2 corners, and a cell under a fourteenth of their spacing
// along a side is finer than its edges follow.
OUTLINE_MASK_SIDE :: 256
// Of each cell of a mask, the memory the cut of its outlines may hold at once
// (the mask closed, its distances, the edges of its trace and the polygons
// they make, about a quarter of it for a leaf), and what it may hold whatever
// the size. A mask its cut does not fit in keeps its alpha test.
OUTLINE_WORK_BYTES :: 256
OUTLINE_WORK_FIXED :: 1<<20

// The texels of a rectangle of an image whose alpha reaches a cutoff, rows
// from the top; or cells of scale texels a side, each kept where one of its
// texels is (outline_mask_reduce).
Outline_Mask :: struct {
    covered:[]bool,
    width,height:int,
    scale:int, // texels a cell spans along each side; 0 or 1: a cell a texel
}

// Polygons with holes in texels of the rectangle of a mask, x to the right
// and y down: each polygon its outline and then its holes.
Outline :: struct {
    set:geom.Polygon_Set,
    error:f32,     // texels: how far the farthest texel it draws is from one the mask keeps
    tolerance:f32, // texels it was cut at; 0 for a convex outline
    triangles:int, // of its triangulation
    area:f64,      // texels²
}

// The outlines of a mask, finest first: each with more error and fewer
// triangles (or as many and less area) than the one before, the last
// repeated to fill them.
Outline_Ladder :: struct {
    rungs:[OUTLINE_RUNGS]Outline,
    hull:Outline, // the convex outline a mask that keeps a cluster is drawn on
    opaque:int,   // texels the mask keeps; of cells, those of the cells it keeps
    leaf:bool,    // drawn as its outlines; else masked on hull
}

// The mask of a rectangle of width by height texels, those `kept` keeps, on
// cells of as many texels as bring its longer side to OUTLINE_MASK_SIDE at
// most: a cell is kept where any of its texels is. In allocator; false
// without memory.
outline_mask_reduce :: proc(width,height:int,data:$T,kept:proc(data:T,x,y:int) -> bool,allocator:=context.allocator) -> (mask:Outline_Mask,ok:bool) {
    if width<=0 || height<=0 {return}
    scale:=max((max(width,height)+OUTLINE_MASK_SIDE-1)/OUTLINE_MASK_SIDE,1)
    mask.width,mask.height,mask.scale=(width+scale-1)/scale,(height+scale-1)/scale,scale
    error:mem.Allocator_Error
    if mask.covered,error=make([]bool,mask.width*mask.height,allocator);error!=nil {return}
    for y in 0..<height {
        row:=mask.covered[y/scale*mask.width:][:mask.width]
        for x in 0..<width {
            if !row[x/scale] && kept(data,x,y) {row[x/scale]=true}
        }
    }
    return mask,true
}

// The ladder of a mask that keeps some texel, in allocator. False without
// one, or without the memory its cut takes. A mask wider than
// OUTLINE_MASK_SIDE is reduced first.
outline_ladder :: proc(mask:Outline_Mask,allocator:=context.allocator) -> (ladder:Outline_Ladder,ok:bool) {
    cells:=mask.width*mask.height
    if mask.width<=0 || mask.height<=0 || len(mask.covered)!=cells || mask.scale>1 && (mask.width>OUTLINE_MASK_SIDE || mask.height>OUTLINE_MASK_SIDE) {return}
    mask:=mask
    if mask.width>OUTLINE_MASK_SIDE || mask.height>OUTLINE_MASK_SIDE {
        kept :: proc(full:Outline_Mask,x,y:int) -> bool {return full.covered[y*full.width+x]}
        reduced,reduced_ok:=outline_mask_reduce(mask.width,mask.height,mask,kept,context.allocator)
        if !reduced_ok {return}
        defer delete(reduced.covered,context.allocator)
        return outline_ladder(reduced,allocator)
    }
    scale:=max(mask.scale,1)
    // Its work, taken once from the allocator of the context and given back as it ends.
    work_bytes:=OUTLINE_WORK_FIXED+OUTLINE_WORK_BYTES*(mask.width+2)*(mask.height+2)
    buffer,taken:=mem.alloc_bytes_non_zeroed(work_bytes,allocator=context.allocator)
    if taken!=nil {return}
    defer mem.free_bytes(buffer,context.allocator)
    arena:mem.Arena
    mem.arena_init(&arena,buffer)
    context.temp_allocator=mem.arena_allocator(&arena)
    for cover in mask.covered {if cover {ladder.opaque+=scale*scale}}
    if ladder.opaque==0 {return}
    distance2,no_distance:=make([]u32,cells,context.temp_allocator)
    nearest,no_nearest:=make([]u32,cells,context.temp_allocator)
    if no_distance!=nil || no_nearest!=nil || !geom.grid_nearest(mask.covered,mask.width,mask.height,0,nearest,distance2) {return}
    // The candidates with their metrics, and the outlines of those the ladder may keep, in allocator.
    candidates:[OUTLINE_RUNGS]Outline
    count:=0
    defer if !ok {
        for &c in candidates[:count] {geom.polygon_set_destroy(&c.set)}
        outline_ladder_destroy(&ladder)
    }
    keep :: proc(candidates:^[OUTLINE_RUNGS]Outline,count:^int,c:Outline,scale:int,allocator:runtime.Allocator) -> bool {
        candidates[count^]=outline_scaled(c,scale)
        if c.triangles<=OUTLINE_TRIANGLES {
            copied,copied_ok:=outline_copy(c,scale,allocator)
            if !copied_ok {return false}
            candidates[count^]=copied
        }
        count^+=1
        return true
    }
    coarsest:=f32(max(mask.width,mask.height))*OUTLINE_COARSEST
    for k in 0..<OUTLINE_STEPS {
        tolerance:=OUTLINE_FINEST*f32(math.pow(f64(2),f64(k)*0.5))
        if k>0 && tolerance>coarsest {break}
        // A tolerance that would lose a texel the mask keeps is halved until none is lost.
        candidate:Outline
        for {
            step:=mem.begin_arena_temp_memory(&arena)
            candidate.tolerance=tolerance
            geom.polygon_set_init(&candidate.set,context.temp_allocator)
            cut,cut_ok:=outline_cut(mask,tolerance,&candidate.set)
            if !cut_ok {mem.end_arena_temp_memory(step);return}
            lost:int
            measured:bool
            candidate.error,candidate.triangles,candidate.area,lost,measured=outline_measure(candidate.set,mask,distance2)
            if !measured {mem.end_arena_temp_memory(step);return}
            if cut && lost==0 || tolerance<OUTLINE_FINEST {
                if !keep(&candidates,&count,candidate,scale,allocator) {mem.end_arena_temp_memory(step);return}
                mem.end_arena_temp_memory(step)
                break
            }
            mem.end_arena_temp_memory(step)
            tolerance=tolerance*0.5 if tolerance>OUTLINE_FINEST else 0
        }
    }
    kgon,greedy:[dynamic]geom.Vec2
    kgon.allocator=context.temp_allocator
    greedy.allocator=context.temp_allocator
    hull_corners,hull_ok:=outline_corners(mask)
    if !hull_ok {return}
    if _,error:=append(&kgon,..hull_corners);error!=nil {return}
    convex_reduce(&kgon,OUTLINE_HULL_EDGES)
    if _,error:=append(&greedy,..kgon[:]);error!=nil {return}
    eight:=count
    hull:=eight
    for k:=8;k>=4;k-=1 {
        convex_reduce(&greedy,k)
        tried,tried_ok:=convex_fewest(kgon[:],k)
        if !tried_ok {return}
        if loop_area(greedy[:])<loop_area(tried) {tried=greedy[:]}
        step:=mem.begin_arena_temp_memory(&arena)
        convex,convex_ok:=convex_outline(tried,mask,distance2)
        if !convex_ok || !keep(&candidates,&count,convex,scale,allocator) {mem.end_arena_temp_memory(step);return}
        mem.end_arena_temp_memory(step)
        if candidates[count-1].area<=candidates[eight].area*(1+OUTLINE_HULL_SLACK) {hull=count-1}
    }
    hull_copy,hull_copied:=outline_copy(candidates[hull],1,allocator)
    if !hull_copied {return}
    ladder.hull=hull_copy
    // By error, then triangles, then area; ties by the order they were made in.
    order:[OUTLINE_RUNGS]int
    for &o,i in order[:count] {o=i}
    for i in 1..<count {
        for j:=i;j>0;j-=1 {
            a,b:=candidates[order[j]],candidates[order[j-1]]
            if !(a.error<b.error || a.error==b.error && (a.triangles<b.triangles || a.triangles==b.triangles && a.area<b.area)) {break}
            order[j],order[j-1]=order[j-1],order[j]
        }
    }
    rungs:=0
    for o in order[:count] {
        c:=candidates[o]
        if c.triangles>OUTLINE_TRIANGLES {continue}
        if rungs>0 {
            last:=ladder.rungs[rungs-1]
            if !(c.triangles<last.triangles || c.triangles==last.triangles && c.area<last.area) {continue}
        }
        copied,copied_ok:=outline_copy(c,1,allocator)
        if !copied_ok {return}
        ladder.rungs[rungs]=copied
        rungs+=1
    }
    for k in rungs..<OUTLINE_RUNGS {
        copied,copied_ok:=outline_copy(ladder.rungs[rungs-1],1,allocator)
        if !copied_ok {return}
        ladder.rungs[k]=copied
    }
    needed:=max(int)
    for c in candidates[:count] {
        if f64(ladder.opaque)>=OUTLINE_COVERAGE*c.area {needed=min(needed,c.triangles)}
    }
    ladder.leaf=needed<=OUTLINE_TRIANGLES
    for &c in candidates[:count] {geom.polygon_set_destroy(&c.set)}
    count=0
    return ladder,true
}

outline_ladder_destroy :: proc(ladder:^Outline_Ladder) {
    for &rung in ladder.rungs {geom.polygon_set_destroy(&rung.set)}
    geom.polygon_set_destroy(&ladder.hull.set)
    ladder^={}
}

// The metrics of an outline cut on cells of `scale` texels, in texels,
// without its polygons: an outline that touches a cell may draw any texel of
// it, and the nearest texel a kept cell keeps may be anywhere in that cell.
@(private="file")
outline_scaled :: proc(from:Outline,scale:int) -> (to:Outline) {
    to=from
    to.set={}
    if scale>1 {
        s:=f32(scale)
        to.error=(from.error+math.SQRT_TWO)*s
        to.tolerance=from.tolerance*s
        to.area=from.area*f64(scale*scale)
    }
    return
}

// An outline in allocator, cut on cells of `scale` texels and given in texels
// (outline_scaled).
@(private="file")
outline_copy :: proc(from:Outline,scale:int,allocator:=context.allocator) -> (to:Outline,ok:bool) {
    to=outline_scaled(from,scale)
    geom.polygon_set_init(&to.set,allocator)
    _,no_points:=append(&to.set.points,..from.set.points[:])
    _,no_sizes:=append(&to.set.loop_sizes,..from.set.loop_sizes[:])
    _,no_loops:=append(&to.set.polygon_loops,..from.set.polygon_loops[:])
    if no_points!=nil || no_sizes!=nil || no_loops!=nil {
        geom.polygon_set_destroy(&to.set)
        return {},false
    }
    if scale>1 {
        for &p in to.set.points {p*=f32(scale)}
    }
    return to,true
}

// The convex polygon of corners, measured.
@(private="file")
convex_outline :: proc(corners:[]geom.Vec2,mask:Outline_Mask,distance2:[]u32) -> (outline:Outline,ok:bool) {
    geom.polygon_set_init(&outline.set,context.temp_allocator)
    _,no_points:=append(&outline.set.points,..corners)
    _,no_sizes:=append(&outline.set.loop_sizes,len(corners))
    _,no_loops:=append(&outline.set.polygon_loops,1)
    if no_points!=nil || no_sizes!=nil || no_loops!=nil {return}
    outline.error,outline.triangles,outline.area,_,ok=outline_measure(outline.set,mask,distance2)
    return
}

// The conservative outline of a mask at a tolerance in texels (see above),
// into set; below OUTLINE_FINEST, its texel edges as they are. whole false
// where a polygon of it does not triangulate whole; ok false without memory.
@(private="file")
outline_cut :: proc(mask:Outline_Mask,tolerance:f32,set:^geom.Polygon_Set) -> (whole,ok:bool) {
    whole=true
    cells:=mask.width*mask.height
    closed:=mask.covered
    if tolerance>=1 {
        error:mem.Allocator_Error
        if closed,error=make([]bool,cells,context.temp_allocator);error!=nil {return}
        mask_close(mask,tolerance,closed) or_return
    }
    traced:geom.Polygon_Set
    geom.polygon_set_init(&traced,context.temp_allocator)
    mask_trace({closed,mask.width,mask.height,1},&traced) or_return
    moved:[dynamic]geom.Vec2
    moved.allocator=context.temp_allocator
    sizes:[dynamic]int
    sizes.allocator=context.temp_allocator
    clean:geom.Polygon_Set
    geom.polygon_set_init(&clean,context.temp_allocator)
    first:=0
    loop:=0
    for loops in traced.polygon_loops {
        clear(&moved);clear(&sizes)
        for k in 0..<loops {
            size:=traced.loop_sizes[loop+k]
            ring:=traced.points[first:][:size]
            first+=size
            before:=len(moved)
            if tolerance>=OUTLINE_FINEST {
                loop_conservative(ring,tolerance,&moved) or_return
            } else if _,error:=append(&moved,..ring);error!=nil {return}
            // A hole the outline of its tolerance closes is filled.
            if k>0 && !(loop_area(moved[before:])<-f64(tolerance)*f64(tolerance)) {
                resize(&moved,before)
                continue
            }
            if k==0 && !(loop_area(moved[before:])>0) {
                resize(&moved,before)
                if _,error:=append(&moved,..ring);error!=nil {return}
            }
            if _,error:=append(&sizes,len(moved)-before);error!=nil {return}
        }
        loop+=loops
        if polygon_whole(moved[:],sizes[:]) {
            _,no_points:=append(&set.points,..moved[:])
            _,no_sizes:=append(&set.loop_sizes,..sizes[:])
            _,no_loops:=append(&set.polygon_loops,len(sizes))
            if no_points!=nil || no_sizes!=nil || no_loops!=nil {return}
            continue
        }
        // Edges moved past each other leave loops that cross: the union of the polygon with itself is simple.
        if geom.polygon_boolean(moved[:],sizes[:],moved[:],sizes[:],.Union,&clean)!=.None {return false,true}
        at,at_loop:=0,0
        for count in clean.polygon_loops {
            points:=0
            for size in clean.loop_sizes[at_loop:][:count] {points+=size}
            if !polygon_whole(clean.points[at:][:points],clean.loop_sizes[at_loop:][:count]) {whole=false}
            at+=points
            at_loop+=count
        }
        _,no_points:=append(&set.points,..clean.points[:])
        _,no_sizes:=append(&set.loop_sizes,..clean.loop_sizes[:])
        _,no_loops:=append(&set.polygon_loops,..clean.polygon_loops[:])
        if no_points!=nil || no_sizes!=nil || no_loops!=nil {return}
    }
    return whole,true
}

// Whether a polygon (its outline, then its holes) triangulates into
// triangles that turn its way and cover it once.
@(private)
polygon_whole :: proc(points:[]geom.Vec2,loop_sizes:[]int) -> bool {
    indices:[dynamic]u32
    indices.allocator=context.temp_allocator
    geom.polygon_triangulate(points,loop_sizes,&indices)
    signed:f64
    at:=0
    for size,k in loop_sizes {
        area:=loop_area(points[at:][:size])
        signed+=abs(area) if k==0 else -abs(area)
        at+=size
    }
    folded:f64
    for t:=0;t+2<len(indices);t+=3 {
        twice:=orient(points[indices[t]],points[indices[t+1]],points[indices[t+2]])
        if twice<0 {folded-=twice}
    }
    return signed>0 && folded<=1e-6*signed
}

// The signed area of a loop: positive for the outlines of mask_trace,
// negative for its holes.
@(private)
loop_area :: proc "contextless" (ring:[]geom.Vec2) -> f64 {
    sum:f64
    for a,i in ring {
        b:=ring[(i+1)%len(ring)]
        sum+=f64(a.x)*f64(b.y)-f64(b.x)*f64(a.y)
    }
    return sum*0.5
}

// The mask closed by a disk of `radius` texels: what keeps every disk around
// it that it touches; within the rectangle, so nothing it keeps at its border
// is lost. False without memory.
@(private="file")
mask_close :: proc(mask:Outline_Mask,radius:f32,closed:[]bool) -> bool {
    cells:=len(mask.covered)
    distance2,no_distance:=make([]u32,cells,context.temp_allocator)
    nearest,no_nearest:=make([]u32,cells,context.temp_allocator)
    if no_distance!=nil || no_nearest!=nil {return false}
    reach:=u32(radius*radius)
    if !geom.grid_nearest(mask.covered,mask.width,mask.height,0,nearest,distance2) {return false}
    for &out,at in closed {out=distance2[at]>reach}
    if !geom.grid_nearest(closed,mask.width,mask.height,0,nearest,distance2) {return false}
    for &out,at in closed {out=distance2[at]>reach}
    return true
}

// The loops along the texel edges of a mask, one polygon a 4-connected piece:
// its outline (positive area) and then its holes. Each loop runs with what it
// keeps on its right as the image is seen, and turns right where two pieces
// touch at a corner, so they stay apart. False without memory.
@(private="file")
mask_trace :: proc(mask:Outline_Mask,set:^geom.Polygon_Set) -> bool {
    w,h:=mask.width,mask.height
    corners:=(w+1)*(h+1)
    // Up to two edges leave a corner: where to, -1 for none.
    out,no_out:=make([][2]i32,corners,context.temp_allocator)
    used,no_used:=make([][2]bool,corners,context.temp_allocator)
    if no_out!=nil || no_used!=nil {return false}
    for &o in out {o={-1,-1}}
    add :: proc(out:[][2]i32,w:int,ax,ay,bx,by:int) {
        a:=ay*(w+1)+ax
        if out[a][0]<0 {out[a][0]=i32(by*(w+1)+bx)} else {out[a][1]=i32(by*(w+1)+bx)}
    }
    kept :: proc(mask:Outline_Mask,x,y:int) -> bool {return x>=0 && y>=0 && x<mask.width && y<mask.height && mask.covered[y*mask.width+x]}
    for y in 0..<h {
        for x in 0..<w {
            if !mask.covered[y*w+x] {continue}
            if !kept(mask,x,y-1) {add(out,w,x,y,x+1,y)}
            if !kept(mask,x+1,y) {add(out,w,x+1,y,x+1,y+1)}
            if !kept(mask,x,y+1) {add(out,w,x+1,y+1,x,y+1)}
            if !kept(mask,x-1,y) {add(out,w,x,y+1,x,y)}
        }
    }
    Loop :: struct {first,count:int,area:f64}
    loops:[dynamic]Loop
    loops.allocator=context.temp_allocator
    points:[dynamic]geom.Vec2
    points.allocator=context.temp_allocator
    corner :: proc(w,v:int) -> [2]int {return {v%(w+1),v/(w+1)}}
    for start in 0..<corners {
        for e in 0..<2 {
            if out[start][e]<0 || used[start][e] {continue}
            first:=len(points)
            at,edge:=start,e
            previous:=[2]int{}
            for steps:=0;steps<4*corners;steps+=1 {
                used[at][edge]=true
                here:=corner(w,at)
                to:=int(out[at][edge])
                direction:=corner(w,to)-here
                if direction!=previous {
                    if _,error:=append(&points,geom.Vec2{f32(here.x),f32(here.y)});error!=nil {return false}
                }
                previous=direction
                at=to
                // The edge that turns right of the one that came, where two leave.
                edge=0
                if out[at][1]>=0 {
                    right:=[2]int{-direction.y,direction.x}
                    if corner(w,int(out[at][1]))-corner(w,at)==right {edge=1}
                }
                if at==start && edge==e {break}
            }
            // The first point is a corner unless the loop came back to it straight.
            if len(points)-first>=3 && previous==corner(w,int(out[start][e]))-corner(w,start) {
                ordered_remove(&points,first)
            }
            if _,error:=append(&loops,Loop{first,len(points)-first,loop_area(points[first:])});error!=nil {return false}
        }
    }
    // Each hole goes with the smallest outline around the empty texel left of its first edge.
    owner,no_owner:=make([]int,len(loops),context.temp_allocator)
    if no_owner!=nil {return false}
    for l,i in loops {
        owner[i]=i
        if l.area>=0 {continue}
        a,b:=points[l.first],points[l.first+1]
        d:=geom.Vec2{math.sign(b.x-a.x),math.sign(b.y-a.y)}
        probe:=a+d*0.5+geom.Vec2{d.y,-d.x}*0.5
        best:=-1
        for o,j in loops {
            if o.area<=0 || best>=0 && o.area>=loops[best].area || !ring_holds(points[o.first:][:o.count],probe) {continue}
            best=j
        }
        owner[i]=best
    }
    for l,i in loops {
        if l.area<=0 {continue}
        _,no_points:=append(&set.points,..points[l.first:][:l.count])
        _,no_sizes:=append(&set.loop_sizes,l.count)
        if no_points!=nil || no_sizes!=nil {return false}
        count:=1
        for h,j in loops {
            if h.area>=0 || owner[j]!=i {continue}
            _,no_hole:=append(&set.points,..points[h.first:][:h.count])
            _,no_size:=append(&set.loop_sizes,h.count)
            if no_hole!=nil || no_size!=nil {return false}
            count+=1
        }
        if _,error:=append(&set.polygon_loops,count);error!=nil {return false}
    }
    return true
}

// Whether a point is inside a loop, by the crossings of a ray to the right.
@(private="file")
ring_holds :: proc "contextless" (ring:[]geom.Vec2,p:geom.Vec2) -> bool {
    inside:=false
    for a,i in ring {
        b:=ring[(i+1)%len(ring)]
        if (a.y>p.y)!=(b.y>p.y) && f64(p.x)<f64(a.x)+(f64(p.y)-f64(a.y))*(f64(b.x)-f64(a.x))/(f64(b.y)-f64(a.y)) {inside=!inside}
    }
    return inside
}

// A traced loop simplified by Douglas-Peucker at tolerance, each kept edge
// moved out (to the left as the image is seen, away from what the mask keeps)
// until the points it replaced are behind it, the corners where the moved
// edges meet appended to out. False without memory.
@(private="file")
loop_conservative :: proc(ring:[]geom.Vec2,tolerance:f32,out:^[dynamic]geom.Vec2) -> bool {
    n:=len(ring)
    keep,no_keep:=make([]bool,n,context.temp_allocator)
    if no_keep!=nil {return false}
    far:=0
    for p,i in ring {
        if length2(p-ring[0])>length2(ring[far]-ring[0]) {far=i}
    }
    keep[0],keep[far]=true,true
    Span :: struct {from,to:int} // to past the end wraps
    stack:[dynamic]Span
    stack.allocator=context.temp_allocator
    if _,error:=append(&stack,Span{0,far},Span{far,n});error!=nil {return false}
    for len(stack)>0 {
        s:=pop(&stack)
        if s.to-s.from<2 {continue}
        a,b:=ring[s.from],ring[s.to%n]
        worst,at:=f64(-1),-1
        for i in s.from+1..<s.to {
            d:=line_distance(a,b,ring[i])
            if d>worst {worst,at=d,i}
        }
        if worst<=f64(tolerance) {continue}
        keep[at]=true
        if _,error:=append(&stack,Span{s.from,at},Span{at,s.to});error!=nil {return false}
    }
    kept:[dynamic]int
    kept.allocator=context.temp_allocator
    for k,i in keep {
        if k {if _,error:=append(&kept,i);error!=nil {return false}}
    }
    m:=len(kept)
    if m<3 {
        _,error:=append(out,..ring)
        return error==nil
    }
    dot :: #force_inline proc "contextless" (a,b:[2]f64) -> f64 {return a.x*b.x+a.y*b.y}
    Line :: struct {at,direction,normal:[2]f64}
    lines,no_lines:=make([]Line,m,context.temp_allocator)
    if no_lines!=nil {return false}
    for k in 0..<m {
        i0,i1:=kept[k],kept[(k+1)%m]
        a,b:=ring[i0],ring[i1]
        d:=[2]f64{f64(b.x)-f64(a.x),f64(b.y)-f64(a.y)}
        normal:=[2]f64{d.y,-d.x}/max(math.sqrt(dot(d,d)),1e-12)
        offset:f64
        for i:=i0;;i=(i+1)%n {
            p:=ring[i]
            offset=max(offset,(f64(p.x)-f64(a.x))*normal.x+(f64(p.y)-f64(a.y))*normal.y)
            if i==i1 {break}
        }
        lines[k]={{f64(a.x),f64(a.y)}+normal*offset,d,normal}
    }
    // Where two moved edges meet farther than this from their corner, the corner is cut.
    reach:=2*f64(tolerance)+1
    for k in 0..<m {
        l0,l1:=lines[(k+m-1)%m],lines[k]
        corner:=[2]f64{f64(ring[kept[k]].x),f64(ring[kept[k]].y)}
        den:=l0.direction.x*l1.direction.y-l0.direction.y*l1.direction.x
        q:=corner
        if abs(den)>1e-9*math.sqrt(dot(l0.direction,l0.direction)*dot(l1.direction,l1.direction)) {
            e:=l1.at-l0.at
            q=l0.at+l0.direction*((e.x*l1.direction.y-e.y*l1.direction.x)/den)
        }
        if v:=q-corner;dot(v,v)<=reach*reach {
            if _,error:=append(out,geom.Vec2{f32(q.x),f32(q.y)});error!=nil {return false}
            continue
        }
        // A sharp tip is cut square to its bisector, moved out until the points of both edges are behind it.
        bisector:=l0.normal+l1.normal
        if dot(bisector,bisector)<1e-2 {bisector=l0.direction/math.sqrt(dot(l0.direction,l0.direction))-l1.direction/math.sqrt(dot(l1.direction,l1.direction))}
        bisector/=math.sqrt(dot(bisector,bisector))
        ends:[2]f64
        if dot(q-corner,bisector)>0 && abs(dot(l0.direction,bisector))>1e-9 && abs(dot(l1.direction,bisector))>1e-9 {
            offset:f64
            for i:=kept[(k+m-1)%m];;i=(i+1)%n {
                p:=ring[i]
                offset=max(offset,dot({f64(p.x),f64(p.y)}-corner,bisector))
                if i==kept[(k+1)%m] {break}
            }
            cut:=corner+bisector*offset
            ends={dot(cut-l0.at,bisector)/dot(l0.direction,bisector),dot(cut-l1.at,bisector)/dot(l1.direction,bisector)}
        } else {
            // A notch: the moved edges end square at its corner.
            ends={dot(corner-l0.at,l0.direction)/dot(l0.direction,l0.direction),dot(corner-l1.at,l1.direction)/dot(l1.direction,l1.direction)}
        }
        a,b:=l0.at+l0.direction*ends[0],l1.at+l1.direction*ends[1]
        if _,error:=append(out,geom.Vec2{f32(a.x),f32(a.y)},geom.Vec2{f32(b.x),f32(b.y)});error!=nil {return false}
    }
    return true
}

@(private="file")
length2 :: #force_inline proc "contextless" (v:geom.Vec2) -> f64 {return f64(v.x)*f64(v.x)+f64(v.y)*f64(v.y)}

// Of p, how far from the line through a and b; from a when they are one point.
@(private="file")
line_distance :: proc "contextless" (a,b,p:geom.Vec2) -> f64 {
    dx,dy:=f64(b.x)-f64(a.x),f64(b.y)-f64(a.y)
    px,py:=f64(p.x)-f64(a.x),f64(p.y)-f64(a.y)
    l:=math.sqrt(dx*dx+dy*dy)
    if l<1e-12 {return math.sqrt(px*px+py*py)}
    return abs(dx*py-dy*px)/l
}

// Of an outline: the farthest texel it draws from one the mask keeps (by
// distance2, of each texel to the nearest it keeps), its triangles and area,
// and how many texels the mask keeps that it does not draw. Texels are drawn
// by their centres; of a mask of cells (scale above 1), the error counts every
// cell it touches. ok false without memory.
@(private="file")
outline_measure :: proc(set:geom.Polygon_Set,mask:Outline_Mask,distance2:[]u32) -> (error:f32,triangles:int,area:f64,lost:int,ok:bool) {
    drawn,no_drawn:=make([]bool,len(mask.covered),context.temp_allocator)
    touched:=drawn
    if mask.scale>1 {
        no_touched:mem.Allocator_Error
        touched,no_touched=make([]bool,len(mask.covered),context.temp_allocator)
        if no_touched!=nil {return}
    }
    if no_drawn!=nil {return}
    indices:[dynamic]u32
    indices.allocator=context.temp_allocator
    first:=0
    loop:=0
    for loops in set.polygon_loops {
        count:=0
        for size in set.loop_sizes[loop:][:loops] {count+=size}
        clear(&indices)
        points:=set.points[first:][:count]
        geom.polygon_triangulate(points,set.loop_sizes[loop:][:loops],&indices)
        for t:=0;t+2<len(indices);t+=3 {
            corners:=[3]geom.Vec2{points[indices[t]],points[indices[t+1]],points[indices[t+2]]}
            area+=0.5*abs(orient(corners[0],corners[1],corners[2]))
            triangle_raster(corners,mask.width,mask.height,drawn)
            if mask.scale>1 {triangle_raster(corners,mask.width,mask.height,touched,math.SQRT_TWO*0.5)}
        }
        triangles+=len(indices)/3
        first+=count
        loop+=loops
    }
    worst:u32
    for d,at in touched {
        if d {worst=max(worst,distance2[at])}
    }
    for d,at in drawn {
        if !d && mask.covered[at] {lost+=1}
    }
    return f32(math.sqrt(f64(worst))),triangles,area,lost,true
}

// Marks the texels of a grid whose centres a triangle holds, its edges
// included; with reach, those whose centres are within it of the triangle.
@(private)
triangle_raster :: proc(corners:[3]geom.Vec2,width,height:int,drawn:[]bool,reach:f32=0) {
    a,b,c:=corners[0],corners[1],corners[2]
    side:=orient(a,b,c)
    if side==0 {return}
    x0:=max(int(math.floor(min(a.x,b.x,c.x)-0.5-reach)),0)
    y0:=max(int(math.floor(min(a.y,b.y,c.y)-0.5-reach)),0)
    x1:=min(int(math.ceil(max(a.x,b.x,c.x)-0.5+reach)),width-1)
    y1:=min(int(math.ceil(max(a.y,b.y,c.y)-0.5+reach)),height-1)
    for y in y0..=y1 {
        for x in x0..=x1 {
            p:=geom.Vec2{f32(x)+0.5,f32(y)+0.5}
            e0,e1,e2:=orient(a,b,p),orient(b,c,p),orient(c,a,p)
            inside:=side>0 ? (e0>=0 && e1>=0 && e2>=0) : (e0<=0 && e1<=0 && e2<=0)
            if !inside && reach>0 {
                inside=segment_distance(a,b,p)<=f64(reach) || segment_distance(b,c,p)<=f64(reach) || segment_distance(c,a,p)<=f64(reach)
            }
            if inside {drawn[y*width+x]=true}
        }
    }
}

// Of p, how far from the segment from a to b.
@(private="file")
segment_distance :: proc "contextless" (a,b,p:geom.Vec2) -> f64 {
    dx,dy:=f64(b.x)-f64(a.x),f64(b.y)-f64(a.y)
    px,py:=f64(p.x)-f64(a.x),f64(p.y)-f64(a.y)
    l2:=dx*dx+dy*dy
    t:=clamp((px*dx+py*dy)/l2,0,1) if l2>0 else 0
    ex,ey:=px-t*dx,py-t*dy
    return math.sqrt(ex*ex+ey*ey)
}

// Twice the signed area of the triangle a, b, c.
@(private)
orient :: #force_inline proc "contextless" (a,b,c:geom.Vec2) -> f64 {
    return (f64(b.x)-f64(a.x))*(f64(c.y)-f64(a.y))-(f64(b.y)-f64(a.y))*(f64(c.x)-f64(a.x))
}

// The convex hull of the corners of the texels a mask keeps, its loop of
// positive area. False without memory.
@(private="file")
outline_corners :: proc(mask:Outline_Mask) -> (out:[]geom.Vec2,ok:bool) {
    points:[dynamic][2]i64
    points.allocator=context.temp_allocator
    for y in 0..<mask.height {
        row:=mask.covered[y*mask.width:][:mask.width]
        left,right:=-1,-1
        for cover,x in row {
            if !cover {continue}
            if left<0 {left=x}
            right=x
        }
        if left<0 {continue}
        if _,error:=append(&points,[2]i64{i64(left),i64(y)},[2]i64{i64(left),i64(y+1)},[2]i64{i64(right+1),i64(y)},[2]i64{i64(right+1),i64(y+1)});error!=nil {return}
    }
    // Andrew's monotone chain over the points by x, then y.
    for i in 1..<len(points) {
        for j:=i;j>0 && (points[j].x<points[j-1].x || points[j].x==points[j-1].x && points[j].y<points[j-1].y);j-=1 {
            points[j],points[j-1]=points[j-1],points[j]
        }
    }
    cross :: proc "contextless" (o,a,b:[2]i64) -> i64 {return (a.x-o.x)*(b.y-o.y)-(a.y-o.y)*(b.x-o.x)}
    hull,no_hull:=make([dynamic][2]i64,0,2*len(points)+1,context.temp_allocator)
    if no_hull!=nil {return}
    for p in points {
        for len(hull)>=2 && cross(hull[len(hull)-2],hull[len(hull)-1],p)<=0 {pop(&hull)}
        append(&hull,p)
    }
    lower:=len(hull)+1
    #reverse for p in points[:len(points)-1] {
        for len(hull)>=lower && cross(hull[len(hull)-2],hull[len(hull)-1],p)<=0 {pop(&hull)}
        append(&hull,p)
    }
    pop(&hull)
    error:mem.Allocator_Error
    if out,error=make([]geom.Vec2,len(hull),context.temp_allocator);error!=nil {return}
    for p,i in hull {out[i]={f32(p.x),f32(p.y)}}
    return out,true
}

// Of the lines of the edges of a convex loop of positive area, the k that
// close the least area around it, and the corners where they meet; the loop
// itself when it has no more. Every choice is tried: one whose consecutive
// lines turn by half a turn or more is open. False without memory.
@(private="file")
convex_fewest :: proc(loop:[]geom.Vec2,k:int) -> (corners_out:[]geom.Vec2,ok:bool) {
    n:=len(loop)
    if n<=k {return loop,true}
    best,no_best:=make([]geom.Vec2,k,context.temp_allocator)
    corners,no_corners:=make([][2]f64,k,context.temp_allocator)
    pick,no_pick:=make([]int,k,context.temp_allocator)
    if no_best!=nil || no_corners!=nil || no_pick!=nil {return}
    least:=max(f64)
    for &p,i in pick {p=i}
    for {
        closed:=true
        area:f64
        for j in 0..<k {
            i0,i1:=pick[j],pick[(j+1)%k]
            a,b:=loop[i0],loop[(i0+1)%n]
            c,d:=loop[i1],loop[(i1+1)%n]
            r:=[2]f64{f64(b.x)-f64(a.x),f64(b.y)-f64(a.y)}
            s:=[2]f64{f64(d.x)-f64(c.x),f64(d.y)-f64(c.y)}
            den:=r.x*s.y-r.y*s.x
            if !(den>1e-12*(abs(r.x)+abs(r.y))*(abs(s.x)+abs(s.y))) {closed=false;break}
            e:=[2]f64{f64(c.x)-f64(a.x),f64(c.y)-f64(a.y)}
            corners[j]=[2]f64{f64(a.x),f64(a.y)}+r*((e.x*s.y-e.y*s.x)/den)
        }
        if closed {
            for j in 0..<k {
                a,b:=corners[j],corners[(j+1)%k]
                area+=a.x*b.y-b.x*a.y
            }
            if area<least {
                least=area
                for c,j in corners {best[j]={f32(c.x),f32(c.y)}}
            }
        }
        // The next choice of k of n in order.
        at:=k-1
        for at>=0 && pick[at]==n-k+at {at-=1}
        if at<0 {break}
        pick[at]+=1
        for j in at+1..<k {pick[j]=pick[j-1]+1}
    }
    return best if least<max(f64) else loop,true
}

// A convex loop of positive area reduced to k corners: each step removes the
// edge whose neighbours, extended to meet, add the least area. It stays
// convex and around the loop it was.
@(private="file")
convex_reduce :: proc(loop:^[dynamic]geom.Vec2,k:int) {
    for len(loop)>k {
        n:=len(loop)
        best,choice:=max(f64),-1
        meet:[2]f64
        for i in 0..<n {
            a,b,c,d:=loop[(i+n-1)%n],loop[i],loop[(i+1)%n],loop[(i+2)%n]
            r:=[2]f64{f64(b.x)-f64(a.x),f64(b.y)-f64(a.y)}
            s:=[2]f64{f64(c.x)-f64(d.x),f64(c.y)-f64(d.y)}
            den:=r.x*s.y-r.y*s.x
            if abs(den)<1e-12 {continue}
            e:=[2]f64{f64(d.x)-f64(a.x),f64(d.y)-f64(a.y)}
            t:=(e.x*s.y-e.y*s.x)/den
            u:=(e.x*r.y-e.y*r.x)/den
            if t<1 || u<1 {continue}
            q:=[2]f64{f64(a.x),f64(a.y)}+r*t
            bq:=[2]f64{f64(b.x),f64(b.y)}-q
            cq:=[2]f64{f64(c.x),f64(c.y)}-q
            added:=0.5*abs(bq.x*cq.y-bq.y*cq.x)
            if added<best {best,choice,meet=added,i,q}
        }
        if choice<0 {return}
        loop[choice]=geom.Vec2{f32(meet.x),f32(meet.y)}
        ordered_remove(loop,(choice+1)%n)
    }
}
