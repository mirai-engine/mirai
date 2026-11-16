package geom

import "base:runtime"
import "core:math"
import "core:slice"
import "mirai:std/base"

Polygon_Op :: enum u8 {Union,Difference,Intersection}
Polygon_Error :: enum u8 {None,Invalid,Out_Of_Memory,Too_Complex}

// Polygons with holes: each polygon is polygon_loops[i] consecutive loops of loop_sizes, its
// outline first and then its holes; the loops index points one after another.
Polygon_Set :: struct {
    points:       [dynamic]Vec2,
    loop_sizes:   [dynamic]int,
    polygon_loops:[dynamic]int,
}

polygon_set_init :: proc(set:^Polygon_Set,allocator:=context.allocator) {
    if set==nil {return}
    set.points=make([dynamic]Vec2,allocator)
    set.loop_sizes=make([dynamic]int,allocator)
    set.polygon_loops=make([dynamic]int,allocator)
}

polygon_set_destroy :: proc(set:^Polygon_Set) {
    if set==nil {return}
    delete(set.points);delete(set.loop_sizes);delete(set.polygon_loops)
    set^={}
}

polygon_set_clear :: proc(set:^Polygon_Set) {
    if set==nil {return}
    clear(&set.points);clear(&set.loop_sizes);clear(&set.polygon_loops)
}

// Coordinates snap to a grid whose step is the power of two that puts the largest absolute
// coordinate of both inputs below 2^23 steps: every grid point is exact in f32, so a result fed
// back in lands on the same grid points, and the predicates are exact in i64.
@(private="file") PB_GRID_BITS :: 23
@(private="file") PB_MIN_GRID_EXPONENT :: -100
@(private="file") PB_MAX_SEGMENTS :: 1<<20 // edges and grid points, crossings included
@(private="file") PB_MAX_ROUNDS :: 16

@(private="file") PB_Point :: [2]i64
// wa and wb: winding of A and B added on the left of a->b.
@(private="file") PB_Segment :: struct {a,b:PB_Point,wa,wb:i32,dirty:bool}
@(private="file") PB_Span :: struct {lo,hi:i64,index:i32}
@(private="file") PB_Hit :: struct {t:i64,p:PB_Point}
// v0 before v1 in sweep order; wa and wb are added above v0->v1, below_a and below_b are the
// windings under it; out is 1 when the result runs v0->v1, -1 when v1->v0.
@(private="file") PB_Edge :: struct {v0,v1,wa,wb,below_a,below_b:i32,out:i8}
@(private="file") PB_Loop :: struct {first,count:i32,area:i128,lo,hi:PB_Point,parent:i32}

@(private="file") PB_Work :: struct {
    segments,next:[dynamic]PB_Segment,
    hot:          [dynamic]PB_Point, // grid points that segments passing through bend to
    crossings:    [dynamic]PB_Point,
    spans:        [dynamic]PB_Span,
    hits:         [dynamic]PB_Hit,
    vertices:     [dynamic]PB_Point,
    edges:        [dynamic]PB_Edge,
    status:       [dynamic]i32,
    ends:         [dynamic]i32, // per vertex: edges that end there
    out_first:    [dynamic]i32, // per vertex and one more: first result edge that leaves it
    out_to:       [dynamic]i32,
    used:         [dynamic]bool,
    position:     [dynamic]i32, // per vertex: place in the walk, -1 outside it
    walk:         [dynamic]i32,
    loop_vertices:[dynamic]i32,
    loops:        [dynamic]PB_Loop,
}

// a op b, where a and b are each one polygon in the convention of polygon_triangulate
// (First_Outline: first loop the outline, the others holes, any direction). Clears out and
// writes the result: every polygon of it separate (a cut that splits gives two), outlines
// counter-clockwise, holes clockwise, no self-intersections, no zero-area loops. A point is
// inside a polygon when its winding is positive once the outline runs counter-clockwise and the
// holes clockwise. Snap rounding on the grid above keeps touching, shared and collinear edges
// exact. An empty loop list, a loop of fewer than 3 points, loops of more points than there
// are or a point that is not finite give .Invalid; more crossings than the cap, .Too_Complex.
polygon_boolean :: proc(a_points:[]Vec2,a_loops:[]int,b_points:[]Vec2,b_loops:[]int,op:Polygon_Op,out:^Polygon_Set) -> (error:Polygon_Error) {
    if out==nil {return .Invalid}
    polygon_set_clear(out)
    defer if error!=.None {polygon_set_clear(out)}
    if op!=.Union && op!=.Difference && op!=.Intersection {return .Invalid}
    a_total:=pb_validate(a_points,a_loops) or_return
    b_total:=pb_validate(b_points,b_loops) or_return
    if a_total+b_total>PB_MAX_SEGMENTS {return .Too_Complex}
    extent:f64
    for p in a_points[:a_total] {extent=max(extent,f64(abs(p.x)),f64(abs(p.y)))}
    for p in b_points[:b_total] {extent=max(extent,f64(abs(p.x)),f64(abs(p.y)))}
    _,exponent:=math.frexp_f64(extent)
    step:=math.ldexp_f64(1,max(exponent-PB_GRID_BITS,PB_MIN_GRID_EXPONENT))
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=temp_is(out.points.allocator))
    w:PB_Work
    pb_init(&w,context.temp_allocator)
    capacity:=2*(a_total+b_total)+64
    if reserve(&w.segments,capacity)!=nil || reserve(&w.next,capacity)!=nil || reserve(&w.hot,capacity)!=nil || reserve(&w.spans,capacity)!=nil {return .Out_Of_Memory}
    pb_add_loops(&w,a_points,a_loops,step,false) or_return
    pb_add_loops(&w,b_points,b_loops,step,true) or_return
    pb_node(&w) or_return
    pb_classify(&w,op) or_return
    pb_trace(&w) or_return
    return pb_emit(&w,step,out)
}

@(private="file") pb_init :: proc(w:^PB_Work,allocator:runtime.Allocator) {
    w.segments=make([dynamic]PB_Segment,allocator)
    w.next=make([dynamic]PB_Segment,allocator)
    w.hot=make([dynamic]PB_Point,allocator)
    w.crossings=make([dynamic]PB_Point,allocator)
    w.spans=make([dynamic]PB_Span,allocator)
    w.hits=make([dynamic]PB_Hit,allocator)
    w.vertices=make([dynamic]PB_Point,allocator)
    w.edges=make([dynamic]PB_Edge,allocator)
    w.status=make([dynamic]i32,allocator)
    w.ends=make([dynamic]i32,allocator)
    w.out_first=make([dynamic]i32,allocator)
    w.out_to=make([dynamic]i32,allocator)
    w.used=make([dynamic]bool,allocator)
    w.position=make([dynamic]i32,allocator)
    w.walk=make([dynamic]i32,allocator)
    w.loop_vertices=make([dynamic]i32,allocator)
    w.loops=make([dynamic]PB_Loop,allocator)
}

@(private="file") pb_push :: #force_inline proc(a:^[dynamic]$T,v:T) -> Polygon_Error {
    _,err:=append(a,v)
    return .Out_Of_Memory if err!=nil else .None
}

@(private="file") pb_resize :: #force_inline proc(a:^[dynamic]$T,n:int) -> Polygon_Error {
    return .Out_Of_Memory if resize(a,n)!=nil else .None
}

@(private="file") pb_orient :: #force_inline proc "contextless" (a,b,c:PB_Point) -> i64 {
    return (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
}

@(private="file") pb_cross :: #force_inline proc "contextless" (a,b:PB_Point) -> i64 {return a.x*b.y-a.y*b.x}

@(private="file") pb_less :: proc(a,b:PB_Point) -> bool {return a.x<b.x || (a.x==b.x && a.y<b.y)}

@(private="file") pb_sort_unique :: proc(points:^[dynamic]PB_Point) {
    slice.sort_by(points[:],pb_less)
    n:=0
    for p,i in points {
        if i>0 && p==points[n-1] {continue}
        points[n]=p
        n+=1
    }
    base.truncate(points,n)
}

@(private="file") pb_find :: proc(points:[]PB_Point,p:PB_Point) -> i32 {
    lo,hi:=0,len(points)
    for lo<hi {
        mid:=(lo+hi)/2
        if pb_less(points[mid],p) {lo=mid+1} else {hi=mid}
    }
    return i32(lo)
}

@(private="file") pb_snap :: #force_inline proc "contextless" (p:Vec2,step:f64) -> PB_Point {
    return {i64(math.floor(f64(p.x)/step+0.5)),i64(math.floor(f64(p.y)/step+0.5))}
}

@(private="file") pb_validate :: proc(points:[]Vec2,loops:[]int) -> (total:int,error:Polygon_Error) {
    if len(loops)==0 {return 0,.Invalid}
    for size in loops {
        if size<3 || size>len(points)-total {return 0,.Invalid}
        total+=size
    }
    for p in points[:total] {
        if !finite2(p) {return 0,.Invalid}
    }
    return total,.None
}

@(private="file") pb_inside :: #force_inline proc "contextless" (op:Polygon_Op,wa,wb:i32) -> bool {
    switch op {
    case .Union:        return wa>0 || wb>0
    case .Difference:   return wa>0 && wb<=0
    case .Intersection: return wa>0 && wb>0
    }
    return false
}

// Segments of every loop on the grid, oriented so that the outline adds 1 inside it and a hole
// takes 1 away.
@(private="file") pb_add_loops :: proc(w:^PB_Work,points:[]Vec2,loops:[]int,step:f64,second:bool) -> Polygon_Error {
    first:=0
    for size,loop in loops {
        ring:=points[first:first+size]
        first+=size
        area:i128
        prev:=pb_snap(ring[size-1],step)
        for p in ring {
            q:=pb_snap(p,step)
            area+=i128(prev.x)*i128(q.y)-i128(q.x)*i128(prev.y)
            prev=q
        }
        sign:i32=1 if (loop==0)==(area>=0) else -1
        for p in ring {
            q:=pb_snap(p,step)
            if q!=prev {
                s:=PB_Segment{a=prev,b=q,dirty=true}
                if second {s.wb=sign} else {s.wa=sign}
                pb_push(&w.segments,s) or_return
                pb_push(&w.hot,q) or_return
            }
            prev=q
        }
    }
    return .None
}

// Snap rounding: every grid point that is an endpoint or the rounded point of a crossing is hot,
// and a segment that passes through the half-open unit square of a hot point bends through it.
// Repeats until no segment bends, so that segments meet only at shared endpoints or coincide.
@(private="file") pb_node :: proc(w:^PB_Work) -> Polygon_Error {
    pb_sort_unique(&w.hot)
    for _ in 0..<PB_MAX_ROUNDS {
        pb_crossings(w) or_return
        all:=len(w.crossings)>0
        if all {
            _,err:=append(&w.hot,..w.crossings[:])
            if err!=nil {return .Out_Of_Memory}
            pb_sort_unique(&w.hot)
            if len(w.hot)>PB_MAX_SEGMENTS {return .Too_Complex}
        }
        changed:=false
        clear(&w.next)
        for s in w.segments {
            if !s.dirty && !all {
                pb_push(&w.next,s) or_return
                continue
            }
            split:=pb_split(w,s) or_return
            changed||=split
        }
        w.segments,w.next=w.next,w.segments
        if len(w.segments)>PB_MAX_SEGMENTS {return .Too_Complex}
        if !changed {return .None}
    }
    return .Too_Complex
}

// Rounded points of the proper crossings between pairs where at least one segment is new.
@(private="file") pb_crossings :: proc(w:^PB_Work) -> Polygon_Error {
    clear(&w.crossings)
    segments:=w.segments[:]
    dirty:=0
    for s in segments {dirty+=int(s.dirty)}
    if dirty==0 {return .None}
    if dirty*8<len(segments) {
        for s,i in segments {
            if !s.dirty {continue}
            for t,j in segments {
                if t.dirty && j<=i {continue}
                pb_crossing(w,s,t) or_return
            }
        }
        return .None
    }
    clear(&w.spans)
    for s,i in segments {pb_push(&w.spans,PB_Span{min(s.a.x,s.b.x),max(s.a.x,s.b.x),i32(i)}) or_return}
    slice.sort_by(w.spans[:],proc(a,b:PB_Span) -> bool {return a.lo<b.lo})
    spans:=w.spans[:]
    for span,i in spans {
        s:=segments[span.index]
        for other in spans[i+1:] {
            if other.lo>span.hi {break}
            t:=segments[other.index]
            if s.dirty || t.dirty {pb_crossing(w,s,t) or_return}
        }
    }
    return .None
}

@(private="file") pb_crossing :: #force_inline proc(w:^PB_Work,s,t:PB_Segment) -> Polygon_Error {
    if max(t.a.x,t.b.x)<min(s.a.x,s.b.x) || min(t.a.x,t.b.x)>max(s.a.x,s.b.x) {return .None}
    if max(t.a.y,t.b.y)<min(s.a.y,s.b.y) || min(t.a.y,t.b.y)>max(s.a.y,s.b.y) {return .None}
    d1,d2:=pb_orient(s.a,s.b,t.a),pb_orient(s.a,s.b,t.b)
    if d1==0 || d2==0 || (d1>0)==(d2>0) {return .None}
    d3,d4:=pb_orient(t.a,t.b,s.a),pb_orient(t.a,t.b,s.b)
    if d3==0 || d4==0 || (d3>0)==(d4>0) {return .None}
    f:=f64(d3)/f64(d3-d4)
    p:=PB_Point{i64(math.floor(f64(s.a.x)+f*f64(s.b.x-s.a.x)+0.5)),i64(math.floor(f64(s.a.y)+f*f64(s.b.y-s.a.y)+0.5))}
    pb_push(&w.crossings,p) or_return
    return .Too_Complex if len(w.crossings)>PB_MAX_SEGMENTS else .None
}

// Appends s to next, bent through the hot points whose square it passes through. Squares are
// half-open: the segment is moved by (e,e*e) for an infinitely small e, so that a segment
// through a corner hits one square.
@(private="file") pb_split :: proc(w:^PB_Work,s:PB_Segment) -> (split:bool,error:Polygon_Error) {
    lo_x,hi_x:=min(s.a.x,s.b.x),max(s.a.x,s.b.x)
    lo_y,hi_y:=min(s.a.y,s.b.y),max(s.a.y,s.b.y)
    d:=s.b-s.a
    reach:=abs(d.x)+abs(d.y)
    tie:=d.y>0 || (d.y==0 && d.x<0)
    hot:=w.hot[:]
    lo,hi:=0,len(hot)
    for lo<hi {
        mid:=(lo+hi)/2
        if hot[mid].x<lo_x {lo=mid+1} else {hi=mid}
    }
    clear(&w.hits)
    for h in hot[lo:] {
        if h.x>hi_x {break}
        if h.y<lo_y || h.y>hi_y || h==s.a || h==s.b {continue}
        o:=pb_orient(s.a,s.b,h)
        twice:=2*abs(o)
        if twice>reach || (twice==reach && (o>0)==tie) {continue}
        pb_push(&w.hits,PB_Hit{d.x*(h.x-s.a.x)+d.y*(h.y-s.a.y),h}) or_return
    }
    if len(w.hits)==0 {
        s:=s
        s.dirty=false
        pb_push(&w.next,s) or_return
        return false,.None
    }
    slice.sort_by(w.hits[:],proc(a,b:PB_Hit) -> bool {return a.t<b.t})
    prev:=s.a
    for hit in w.hits {
        pb_push(&w.next,PB_Segment{prev,hit.p,s.wa,s.wb,true}) or_return
        prev=hit.p
    }
    pb_push(&w.next,PB_Segment{prev,s.b,s.wa,s.wb,true}) or_return
    return true,.None
}

// Merges coincident segments into edges, sweeps them in vertex order to find the windings under
// each one and keeps the edges with the result on one side only, inside on their left.
@(private="file") pb_classify :: proc(w:^PB_Work,op:Polygon_Op) -> Polygon_Error {
    // Every endpoint is a hot point; hot points that no edge uses stay as lone vertices.
    w.vertices,w.hot=w.hot,w.vertices
    vertices:=w.vertices[:]
    for s in w.segments {
        e:=PB_Edge{v0=pb_find(vertices,s.a),v1=pb_find(vertices,s.b),wa=s.wa,wb=s.wb}
        if e.v0>e.v1 {e.v0,e.v1,e.wa,e.wb=e.v1,e.v0,-e.wa,-e.wb}
        pb_push(&w.edges,e) or_return
    }
    slice.sort_by(w.edges[:],proc(a,b:PB_Edge) -> bool {return a.v0<b.v0 || (a.v0==b.v0 && a.v1<b.v1)})
    n:=0
    for e in w.edges {
        if n>0 && w.edges[n-1].v0==e.v0 && w.edges[n-1].v1==e.v1 {
            w.edges[n-1].wa+=e.wa
            w.edges[n-1].wb+=e.wb
            continue
        }
        if n>0 && w.edges[n-1].wa==0 && w.edges[n-1].wb==0 {n-=1}
        w.edges[n]=e
        n+=1
    }
    if n>0 && w.edges[n-1].wa==0 && w.edges[n-1].wb==0 {n-=1}
    base.truncate(&w.edges,n)
    edges:=w.edges[:]
    pb_resize(&w.ends,len(vertices)) or_return
    slice.zero(w.ends[:])
    for e in edges {w.ends[e.v1]+=1}
    next:=0
    for p,v in vertices {
        if w.ends[v]>0 {
            lo,hi:=0,len(w.status)
            for lo<hi {
                mid:=(lo+hi)/2
                t:=edges[w.status[mid]]
                if pb_orient(vertices[t.v0],vertices[t.v1],p)>0 {lo=mid+1} else {hi=mid}
            }
            remove_range(&w.status,lo,lo+min(int(w.ends[v]),len(w.status)-lo))
        }
        run,count:=len(w.status),0
        for ;next<len(edges) && edges[next].v0==i32(v);next+=1 {
            q:=vertices[edges[next].v1]
            lo,hi:=0,len(w.status)
            for lo<hi {
                mid:=(lo+hi)/2
                t:=edges[w.status[mid]]
                below:=pb_orient(p,vertices[t.v1],q)>0 if t.v0==i32(v) else pb_orient(vertices[t.v0],vertices[t.v1],p)>0
                if below {lo=mid+1} else {hi=mid}
            }
            pb_push(&w.status,0) or_return
            copy(w.status[lo+1:],w.status[lo:len(w.status)-1])
            w.status[lo]=i32(next)
            run=min(run,lo)
            count+=1
        }
        // The edges that start at a vertex lie together, above the edge under the vertex.
        under:PB_Edge
        if run>0 {under=edges[w.status[run-1]]}
        a,b:=under.below_a+under.wa,under.below_b+under.wb
        for k in w.status[run:][:count] {
            edges[k].below_a,edges[k].below_b=a,b
            a+=edges[k].wa
            b+=edges[k].wb
        }
    }
    pb_resize(&w.out_first,len(vertices)+1) or_return
    slice.zero(w.out_first[:])
    total:=0
    for &e in edges {
        below:=pb_inside(op,e.below_a,e.below_b)
        above:=pb_inside(op,e.below_a+e.wa,e.below_b+e.wb)
        if above==below {continue}
        e.out=1 if above else -1
        w.out_first[(e.v0 if above else e.v1)+1]+=1
        total+=1
    }
    for v in 0..<len(vertices) {w.out_first[v+1]+=w.out_first[v]}
    pb_resize(&w.out_to,total) or_return
    pb_resize(&w.ends,len(vertices)) or_return
    copy(w.ends[:],w.out_first[:len(vertices)])
    for e in edges {
        if e.out==0 {continue}
        from,to:=e.v0,e.v1
        if e.out<0 {from,to=e.v1,e.v0}
        w.out_to[w.ends[from]]=to
        w.ends[from]+=1
    }
    return .None
}

// Whether a comes before b turning clockwise from r.
@(private="file") pb_clockwise_before :: proc "contextless" (r,a,b:PB_Point) -> bool {
    half :: proc "contextless" (r,d:PB_Point) -> int {
        c:=pb_cross(r,d)
        if c<0 {return 0}
        if c>0 {return 1}
        return 0 if r.x*d.x+r.y*d.y<0 else 2
    }
    ha,hb:=half(r,a),half(r,b)
    if ha!=hb {return ha<hb}
    return pb_cross(a,b)<0
}

// Unused result edge that leaves at, the first one clockwise from the edge that arrived from
// from: the walk goes around one connected piece of the result.
@(private="file") pb_next_edge :: proc(w:^PB_Work,from,at:i32) -> i32 {
    vertices:=w.vertices[:]
    best:=i32(-1)
    r:=vertices[from]-vertices[at]
    for k in w.out_first[at]..<w.out_first[at+1] {
        if w.used[k] {continue}
        if best<0 || pb_clockwise_before(r,vertices[w.out_to[k]]-vertices[at],vertices[w.out_to[best]]-vertices[at]) {best=k}
    }
    return best
}

// Walks the result edges into closed loops, cut wherever a walk comes back to a vertex, so that
// a hole that touches its outline is a loop of its own.
@(private="file") pb_trace :: proc(w:^PB_Work) -> Polygon_Error {
    pb_resize(&w.used,len(w.out_to)) or_return
    slice.zero(w.used[:])
    pb_resize(&w.position,len(w.vertices)) or_return
    slice.fill(w.position[:],-1)
    for v in 0..<i32(len(w.vertices)) {
        for start in w.out_first[v]..<w.out_first[v+1] {
            if w.used[start] {continue}
            clear(&w.walk)
            pb_push(&w.walk,v) or_return
            w.position[v]=0
            from,e:=v,start
            for {
                w.used[e]=true
                at:=w.out_to[e]
                if first:=w.position[at];first>=0 {
                    pb_loop(w,w.walk[first:]) or_return
                    for x in w.walk[first:] {w.position[x]=-1}
                    base.truncate(&w.walk,first)
                }
                w.position[at]=i32(len(w.walk))
                pb_push(&w.walk,at) or_return
                e=pb_next_edge(w,from,at)
                if e<0 {break}
                from=at
            }
            for x in w.walk {w.position[x]=-1}
        }
    }
    return .None
}

@(private="file") pb_loop :: proc(w:^PB_Work,walk:[]i32) -> Polygon_Error {
    if len(walk)<3 {return .None}
    vertices:=w.vertices[:]
    l:=PB_Loop{first=i32(len(w.loop_vertices)),count=i32(len(walk)),lo=vertices[walk[0]],hi=vertices[walk[0]],parent=-1}
    prev:=vertices[walk[len(walk)-1]]
    for v in walk {
        p:=vertices[v]
        l.area+=i128(prev.x)*i128(p.y)-i128(p.x)*i128(prev.y)
        l.lo=PB_Point{min(l.lo.x,p.x),min(l.lo.y,p.y)}
        l.hi=PB_Point{max(l.hi.x,p.x),max(l.hi.y,p.y)}
        prev=p
    }
    if l.area==0 {return .None}
    _,err:=append(&w.loop_vertices,..walk)
    if err!=nil {return .Out_Of_Memory}
    return pb_push(&w.loops,l)
}

// Whether the loop holds p, given twice: p is on none of its edges.
@(private="file") pb_contains :: proc(w:^PB_Work,l:PB_Loop,p:PB_Point) -> bool {
    if p.x<2*l.lo.x || p.x>2*l.hi.x || p.y<2*l.lo.y || p.y>2*l.hi.y {return false}
    ring:=w.loop_vertices[l.first:][:l.count]
    inside:=false
    c:=2*w.vertices[ring[l.count-1]]
    for v in ring {
        d:=2*w.vertices[v]
        if (c.y>p.y)!=(d.y>p.y) && (d.y>c.y)==(pb_orient(c,d,p)>0) {inside=!inside}
        c=d
    }
    return inside
}

// Each hole goes to the smallest outline that holds the middle of its first edge, which no other
// loop touches; points in the middle of a straight run are dropped.
@(private="file") pb_emit :: proc(w:^PB_Work,step:f64,out:^Polygon_Set) -> Polygon_Error {
    loops:=w.loops[:]
    for &hole in loops {
        if hole.area>0 {continue}
        ring:=w.loop_vertices[hole.first:][:hole.count]
        mid:=w.vertices[ring[0]]+w.vertices[ring[1]]
        for outline,i in loops {
            if outline.area>0 && (hole.parent<0 || outline.area<loops[hole.parent].area) && pb_contains(w,outline,mid) {hole.parent=i32(i)}
        }
    }
    for outline,i in loops {
        if outline.area<0 {continue}
        pb_emit_loop(w,outline,step,out) or_return
        count:=1
        for hole in loops {
            if hole.parent!=i32(i) {continue}
            pb_emit_loop(w,hole,step,out) or_return
            count+=1
        }
        pb_push(&out.polygon_loops,count) or_return
    }
    return .None
}

@(private="file") pb_emit_loop :: proc(w:^PB_Work,l:PB_Loop,step:f64,out:^Polygon_Set) -> Polygon_Error {
    ring:=w.loop_vertices[l.first:][:l.count]
    n:=len(ring)
    count:=0
    for v,i in ring {
        p,c,q:=w.vertices[ring[(i+n-1)%n]],w.vertices[v],w.vertices[ring[(i+1)%n]]
        if pb_orient(p,c,q)==0 && (c.x-p.x)*(q.x-c.x)+(c.y-p.y)*(q.y-c.y)>0 {continue}
        pb_push(&out.points,Vec2{f32(f64(c.x)*step),f32(f64(c.y)*step)}) or_return
        count+=1
    }
    return pb_push(&out.loop_sizes,count)
}
