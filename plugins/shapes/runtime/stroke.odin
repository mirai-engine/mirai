package shapes

import "core:math"
import "core:slice"
import "mirai:std/geom"

// A drag of a brush as one area: the brush swept along the path of
// the pointer once it is simplified. Shape_Edit keeps each shape the stroke
// may change as it was given and combines that copy with the whole area each
// time it changes (shape_combine), so a shape never
// gathers the junctions of the pieces of a drag, keeps every vertex outside
// the area, and comes out the same at any frame rate.
//
// The path is simplified as it comes, in the units of the plane: a point
// closer than the tolerance to the last one kept is left out, and a kept
// point becomes a corner of the path only when the path leaves by more than
// the tolerance every line from the last corner that passes near all the
// points kept since it (a sleeve fit). Callers turn a few pixels of the
// screen into the tolerance at the current zoom, so the shake of a hand goes
// where it happens.
//
// The area is the union of the convex hulls of each convex piece of the brush
// at both ends of each segment, which is exact for a brush moved without
// turning, or the brush alone for one point. The segments up to the last
// corner are kept united; each point that is kept recomputes only the last
// segment, with a boolean per piece of the brush.

Shape_Stroke :: struct {
    brush:[dynamic]geom.Vec2, // a simple loop, counter-clockwise, around 0
    pieces:[dynamic]geom.Vec2,// the convex pieces of the brush one after another
    piece_sizes:[dynamic]int,
    tolerance:f64,
    started:bool,
    corner:geom.Vec2,         // the last corner of the path: the start of the last segment
    end:geom.Vec2,            // the last point kept: the end of the last segment
    toward:f64,               // radians: the direction from the corner to the first point kept after it
    lo,hi:f64,                // radians from toward: the lines from the corner that pass near every point kept since it
    reach:f64,                // the farthest of those points from the corner
    closed:geom.Polygon_Set,  // the segments up to the corner, one polygon
    area:geom.Polygon_Set,    // closed and the last segment, one polygon
    scratch,next,swept:geom.Polygon_Set, // swept: between the booleans of the pieces
    hull,ends:[dynamic]geom.Vec2,
}

// Starts a stroke of a brush: a simple loop around 0 in the units of the
// plane, turned counter-clockwise when it is not; a concave one is swept as
// its convex pieces. tolerance: in the same units, at least 0. Invalid for a
// brush that crosses itself, has no area or a point that is not finite, and
// for a tolerance that is not finite.
shape_stroke_begin :: proc(st:^Shape_Stroke,brush:[]geom.Vec2,tolerance:f32,allocator:=context.allocator) -> Shape_Error {
    shape_stroke_destroy(st)
    if len(brush)<3 || !(tolerance>=0) || !(f64(tolerance)<math.F32_MAX) {return .Invalid}
    for p in brush {if !finite2(p) {return .Invalid}}
    st.brush=make([dynamic]geom.Vec2,allocator)
    st.pieces=make([dynamic]geom.Vec2,allocator)
    st.piece_sizes=make([dynamic]int,allocator)
    st.hull=make([dynamic]geom.Vec2,allocator)
    st.ends=make([dynamic]geom.Vec2,allocator)
    geom.polygon_set_init(&st.closed,allocator)
    geom.polygon_set_init(&st.area,allocator)
    geom.polygon_set_init(&st.scratch,allocator)
    geom.polygon_set_init(&st.swept,allocator)
    geom.polygon_set_init(&st.next,allocator)
    append(&st.brush,..brush)
    area:=loop_area(st.brush[:])
    if area<0 {slice.reverse(st.brush[:])}
    if !(abs(area)>0) || !loop_simple(st.brush[:]) {
        shape_stroke_destroy(st)
        return .Invalid
    }
    indices:=make([dynamic]u32,context.temp_allocator)
    sizes:=make([dynamic]u32,context.temp_allocator)
    loops:=[1]int{len(st.brush)}
    if geom.polygon_convex_partition(st.brush[:],loops[:],&indices,&sizes)<=0 {
        shape_stroke_destroy(st)
        return .Invalid
    }
    for i in indices {append(&st.pieces,st.brush[i])}
    for size in sizes {append(&st.piece_sizes,int(size))}
    st.tolerance=f64(tolerance)
    return .None
}

shape_stroke_destroy :: proc(st:^Shape_Stroke) {
    delete(st.brush);delete(st.pieces);delete(st.piece_sizes);delete(st.hull);delete(st.ends)
    geom.polygon_set_destroy(&st.closed)
    geom.polygon_set_destroy(&st.area)
    geom.polygon_set_destroy(&st.scratch)
    geom.polygon_set_destroy(&st.swept)
    geom.polygon_set_destroy(&st.next)
    st^={}
}

// Takes the next point of the path, in the units of the plane. changed: the
// area changed. A point that is not finite or too near the last one kept is
// left out, and so is one whose boolean fails: the area stays as it was.
shape_stroke_to :: proc(st:^Shape_Stroke,p:geom.Vec2) -> (changed:bool) {
    if len(st.brush)<3 || !finite2(p) {return false}
    if !st.started {
        geom.polygon_set_clear(&st.closed)
        append(&st.closed.points,..st.brush[:])
        for &q in st.closed.points {q+=p}
        append(&st.closed.loop_sizes,len(st.brush))
        append(&st.closed.polygon_loops,1)
        if !set_copy(&st.area,&st.closed) {
            geom.polygon_set_clear(&st.area)
            return false
        }
        st.started,st.corner,st.end=true,p,p
        return true
    }
    step:=dvec(p)-dvec(st.end)
    if step.x==0 && step.y==0 || step.x*step.x+step.y*step.y<st.tolerance*st.tolerance {return false}
    from:=dvec(p)-dvec(st.corner)
    distance:=math.sqrt(from.x*from.x+from.y*from.y)
    if st.end==st.corner {
        // The first point after a corner sets the direction of the segment.
        if !stroke_area(st,&st.closed,st.corner,p) {return false}
        st.end,st.toward,st.reach=p,math.atan2(from.y,from.x),distance
        st.lo,st.hi=-sleeve(st.tolerance,distance),sleeve(st.tolerance,distance)
        return true
    }
    turn:=angle_wrap(math.atan2(from.y,from.x)-st.toward)
    if distance>=st.reach-st.tolerance && st.lo<=turn && turn<=st.hi {
        // Every point kept since the corner is near the line to p: the segment reaches p.
        if !stroke_area(st,&st.closed,st.corner,p) {return false}
        st.end,st.reach=p,max(st.reach,distance)
        if distance>st.tolerance {
            width:=sleeve(st.tolerance,distance)
            st.lo,st.hi=max(st.lo,turn-width),min(st.hi,turn+width)
        }
        return true
    }
    // The path left the sleeve: the last point kept becomes a corner.
    if !sweep_union(st,&st.closed,st.corner,st.end,&st.scratch) {return false}
    if !stroke_area(st,&st.scratch,st.end,p) {return false}
    st.closed,st.scratch=st.scratch,st.closed
    corner:=st.end
    from=dvec(p)-dvec(corner)
    distance=math.sqrt(from.x*from.x+from.y*from.y)
    st.corner,st.end,st.toward,st.reach=corner,p,math.atan2(from.y,from.x),distance
    st.lo,st.hi=-sleeve(st.tolerance,distance),sleeve(st.tolerance,distance)
    return true
}

// The area the stroke covers: one polygon, its outline first and then its
// holes, in the units of the plane; empty before the first point. Views of
// the stroke, valid until its next point.
shape_stroke_area :: proc(st:^Shape_Stroke) -> (points:[]geom.Vec2,loops:[]int) {
    return st.area.points[:],st.area.loop_sizes[:]
}

// ------------------------------------------------------------------ helpers

// Half the width, in radians, of the directions from a corner whose lines
// pass within tolerance of a point at distance.
@(private)
sleeve :: proc "contextless" (tolerance,distance:f64) -> f64 {
    if !(distance>tolerance) {return math.PI}
    return math.asin(tolerance/distance)
}

@(private)
angle_wrap :: proc "contextless" (a:f64) -> f64 {
    a:=a
    for a>math.PI {a-=2*math.PI}
    for a<=-math.PI {a+=2*math.PI}
    return a
}

// st.area becomes base and the brush swept from a to b; on a failure it
// keeps its value.
@(private)
stroke_area :: proc(st:^Shape_Stroke,base:^geom.Polygon_Set,a,b:geom.Vec2) -> bool {
    if !sweep_union(st,base,a,b,&st.next) {return false}
    st.area,st.next=st.next,st.area
    return true
}

// out, another set than base, becomes base, one polygon, and the hull of each
// convex piece of the brush at a and at b.
@(private)
sweep_union :: proc(st:^Shape_Stroke,base:^geom.Polygon_Set,a,b:geom.Vec2,out:^geom.Polygon_Set) -> bool {
    from:=base
    at:=0
    for size,i in st.piece_sizes {
        clear(&st.ends)
        for p in st.pieces[at:at+size] {
            if _,err:=append(&st.ends,p+a,p+b);err!=nil {return false}
        }
        at+=size
        if !hull_of(st.ends[:],&st.hull) || len(st.hull)<3 {return false}
        hull_loops:=[1]int{len(st.hull)}
        // The pieces go back and forth between out and swept and end in out.
        into:=out if (len(st.piece_sizes)-1-i)%2==0 else &st.swept
        if into==from {return false}
        if geom.polygon_boolean(from.points[:],from.loop_sizes[:],st.hull[:],hull_loops[:],.Union,into)!=.None {return false}
        from=into
    }
    return from==out && len(out.polygon_loops)==1
}

@(private)
set_copy :: proc(to,from:^geom.Polygon_Set) -> bool {
    geom.polygon_set_clear(to)
    _,a:=append(&to.points,..from.points[:])
    _,b:=append(&to.loop_sizes,..from.loop_sizes[:])
    _,c:=append(&to.polygon_loops,..from.polygon_loops[:])
    return a==nil && b==nil && c==nil
}

// The convex hull of points into out, counter-clockwise, without points on
// its edges; sorts points. False without memory for it.
@(private)
hull_of :: proc(points:[]geom.Vec2,out:^[dynamic]geom.Vec2) -> bool {
    clear(out)
    slice.sort_by(points,proc(a,b:geom.Vec2) -> bool {return a.x<b.x || a.x==b.x && a.y<b.y})
    for p in points {
        for len(out)>=2 && orient(dvec(out[len(out)-2]),dvec(out[len(out)-1]),dvec(p))<=0 {pop(out)}
        if _,err:=append(out,p);err!=nil {return false}
    }
    lower:=len(out)+1
    #reverse for p in points[:max(len(points)-1,0)] {
        for len(out)>=lower && orient(dvec(out[len(out)-2]),dvec(out[len(out)-1]),dvec(p))<=0 {pop(out)}
        if _,err:=append(out,p);err!=nil {return false}
    }
    if len(out)>1 {pop(out)}
    return true
}

// Whether no two edges of a loop that are not neighbors meet.
@(private)
loop_simple :: proc "contextless" (points:[]geom.Vec2) -> bool {
    n:=len(points)
    if n<3 {return false}
    for i in 0..<n {
        a,b:=dvec(points[i]),dvec(points[(i+1)%n])
        for j in i+2..<n {
            if i==0 && j==n-1 {continue}
            if segments_meet(a,b,dvec(points[j]),dvec(points[(j+1)%n])) {return false}
        }
    }
    return true
}
