package shapes

import "core:fmt"
import "core:math"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// Editing of the source of a shape in its local XY. Each procedure changes
// only the Shape it is given, and only when it succeeds: on an error the
// Shape keeps its value. Vertices are indices into the points of all the
// loops, the outline first; an edge is named by its first vertex and runs to
// the next vertex of its loop. An edit that would make edges cross or touch,
// move a hole out of the outline or into another hole, or turn a loop inside
// out is refused with Self_Intersecting.

STAMP_CIRCLE_POINTS :: 32

// A stamp as a simple counter-clockwise loop into out, which it clears first.
// size: half the width of the square and the radius of the circle; every other
// stamp reaches about as far from center. angle: radians around center. The
// star, the hexagram, the cross, the arrow and the heart are concave.
stamp_points :: proc(kind:Stamp_Kind,center:[2]f32,size,angle:f32,out:^[dynamic]geom.Vec2) {
    clear(out)
    // A regular polygon of count corners, the first at turn first of a circle, or a star whose
    // corners between those are at inner of the radius.
    ring :: proc(out:^[dynamic]geom.Vec2,count:int,first:f64,radius:f64=1,inner:f64=0) {
        steps:=count if inner==0 else 2*count
        for i in 0..<steps {
            a:=2*math.PI*(first+f64(i)/f64(steps))
            r:=radius if inner==0 || i%2==0 else inner
            append(out,geom.Vec2{f32(r*math.cos(a)),f32(r*math.sin(a))})
        }
    }
    corners :: proc(out:^[dynamic]geom.Vec2,points:[]geom.Vec2) {append(out,..points)}
    switch kind {
    case .Square:         ring(out,4,0.125,math.SQRT_TWO)
    case .Circle:         ring(out,STAMP_CIRCLE_POINTS,0)
    case .Triangle:       ring(out,3,0.25)
    case .Pentagon:       ring(out,5,0.25)
    case .Hexagon:        ring(out,6,0)
    case .Octagon:        ring(out,8,1.0/16)
    case .Star:           ring(out,5,0.25,1,0.42)
    case .Hexagram:       ring(out,6,0.25,1,1/math.SQRT_THREE)
    case .Right_Triangle: corners(out,{{-1,-1},{1,-1},{-1,1}})
    case .Cross:
        w:=f32(0.32)
        plus:=[12]geom.Vec2{{w,-1},{w,-w},{1,-w},{1,w},{w,w},{w,1},{-w,1},{-w,w},{-1,w},{-1,-w},{-w,-w},{-w,-1}}
        turn:=math.PI/4
        for p in plus {
            c,s:=f32(math.cos(turn)),f32(math.sin(turn))
            append(out,geom.Vec2{p.x*c-p.y*s,p.x*s+p.y*c})
        }
    case .Arrow:
        corners(out,{{0,1},{-0.75,0.1},{-0.3,0.1},{-0.3,-1},{0.3,-1},{0.3,0.1},{0.75,0.1}})
    case .Half_Disc:
        for i in 0..=STAMP_CIRCLE_POINTS/2 {
            a:=math.PI*f64(i)/f64(STAMP_CIRCLE_POINTS/2)
            append(out,geom.Vec2{f32(math.cos(a)),f32(math.sin(a))-0.5})
        }
    case .Ellipse:
        for i in 0..<STAMP_CIRCLE_POINTS {
            a:=2*math.PI*f64(i)/f64(STAMP_CIRCLE_POINTS)
            append(out,geom.Vec2{f32(math.cos(a)),f32(0.6*math.sin(a))})
        }
    case .Lens:
        // Two arcs of a circle of radius 1.25 that meet at x = -1 and 1.
        half:=STAMP_CIRCLE_POINTS/2
        for side in ([2]f64{-1,1}) {
            for i in 0..<half {
                x:=side*(1-2*f64(i)/f64(half))
                append(out,geom.Vec2{f32(x),f32(side*(math.sqrt(1.5625-x*x)-0.75))})
            }
        }
    case .Drop:
        // A circle under a point at the top, the two joined by the tangents from the point.
        c,r,tip:=-0.35,0.62,1.0
        turn:=math.acos(r/(tip-c))
        append(out,geom.Vec2{0,f32(tip)})
        steps:=STAMP_CIRCLE_POINTS
        for i in 0..=steps {
            a:=math.PI/2+turn+(2*math.PI-2*turn)*f64(i)/f64(steps)
            append(out,geom.Vec2{f32(r*math.cos(a)),f32(c+r*math.sin(a))})
        }
    case .Heart:
        // The heart curve of 16 sin^3 t and 13 cos t - 5 cos 2t - 2 cos 3t - cos 4t, over 17.
        steps:=2*STAMP_CIRCLE_POINTS
        for i in 0..<steps {
            t:=-2*math.PI*f64(i)/f64(steps)
            s:=math.sin(t)
            x:=16*s*s*s
            y:=13*math.cos(t)-5*math.cos(2*t)-2*math.cos(3*t)-math.cos(4*t)
            append(out,geom.Vec2{f32(x/17),f32((y+2.5)/17)})
        }
    }
    c,s:=f32(math.cos(f64(angle))),f32(math.sin(f64(angle)))
    for &p in out {p={center.x+size*(p.x*c-p.y*s),center.y+size*(p.x*s+p.y*c)}}
}

// The points of the loops one after another and the size of each, the
// outline first: the points are a view of s, the sizes are temporary.
shape_outline :: proc(s:^Shape) -> (points:[]geom.Vec2,loops:[]int) {
    count,loop_count:=shape_counts(s)
    sizes:=make([]int,loop_count,context.temp_allocator)
    for &size,i in sizes {size=int(s.loops[i])}
    return s.points[:count],sizes
}

// Makes s the Outline of one polygon of a set: its first loop the outline,
// counter-clockwise, and the others its holes, clockwise. Repeated points and
// points on the line of their neighbors go, and so does a hole left without
// area. A polygon that still has more points or loops than a Shape holds is
// refused with Too_Many_Points or Too_Many_Loops, and s keeps its value.
shape_outline_set :: proc(s:^Shape,set:^geom.Polygon_Set,polygon:int) -> Shape_Error {
    if set==nil || polygon<0 || polygon>=len(set.polygon_loops) {return .Invalid}
    first_loop,first_point:=0,0
    for count in set.polygon_loops[:polygon] {first_loop+=count}
    if first_loop>len(set.loop_sizes) {return .Invalid}
    for size in set.loop_sizes[:first_loop] {first_point+=size}
    loop_count:=set.polygon_loops[polygon]
    if loop_count<=0 || first_loop+loop_count>len(set.loop_sizes) {return .Invalid}
    total:=0
    for size in set.loop_sizes[first_loop:][:loop_count] {
        if size<0 {return .Invalid}
        total+=size
    }
    if first_point+total>len(set.points) {return .Invalid}
    source:=set.points[first_point:][:total]
    for p in source {if !finite2(p) {return .Invalid}}
    loops:=make([][dynamic]geom.Vec2,loop_count,context.temp_allocator)
    kept_loops,kept_points:=0,0
    at:=0
    for size,l in set.loop_sizes[first_loop:][:loop_count] {
        loop:=&loops[l]
        loop^=make([dynamic]geom.Vec2,context.temp_allocator)
        append(loop,..source[at:at+size])
        at+=size
        loop_simplify(loop)
        area:=loop_area(loop[:])
        if len(loop)<3 || area==0 {
            if l==0 {return .Empty}
            clear(loop)
            continue
        }
        // The outline runs counter-clockwise and the holes clockwise.
        if (area>0)!=(l==0) {loop_reverse(loop[:])}
        kept_loops+=1
        kept_points+=len(loop)
    }
    if kept_loops>SHAPE_LOOPS {return .Too_Many_Loops}
    if kept_points>SHAPE_POINTS {return .Too_Many_Points}
    t:=s^
    t.kind=.Outline
    t.points={}
    t.loops={}
    t.point_count,t.loop_count=u16(kept_points),0
    at=0
    for loop in loops {
        if len(loop)==0 {continue}
        copy(t.points[at:],loop[:])
        at+=len(loop)
        t.loops[t.loop_count]=u16(len(loop))
        t.loop_count+=1
    }
    if !shape_outline_clear(&t) {return .Self_Intersecting}
    s^=t
    return .None
}

// Combines an Outline with a polygon with holes, its outline first, in the
// local XY of the shape: union adds its area, difference cuts it,
// intersection keeps only what both cover. out gets every polygon of the
// result, the one of largest area first, and s becomes that one. With no
// polygon the shape is gone and s keeps its value; with more than one the
// caller makes a shape of each of the others with shape_outline_set. It fails
// before changing s when some polygon of the result does not fit a Shape.
shape_combine :: proc(s:^Shape,points:[]geom.Vec2,loops:[]int,op:geom.Polygon_Op,out:^geom.Polygon_Set) -> Shape_Error {
    if s.kind!=.Outline || out==nil || len(loops)==0 {return .Invalid}
    if error:=shape_valid_counts(s);error!=.None {return error}
    shape_points,shape_loops:=shape_outline(s)
    switch geom.polygon_boolean(shape_points,shape_loops,points,loops,op,out) {
    case .None:
    case .Invalid: return .Invalid
    case .Out_Of_Memory,.Too_Complex: return .Geometry
    }
    if len(out.polygon_loops)==0 {return .None}
    if !set_largest_first(out) {return .Geometry}
    for polygon in 1..<len(out.polygon_loops) {
        t:=s^
        if error:=shape_outline_set(&t,out,polygon);error!=.None {return error}
    }
    return shape_outline_set(s,out,0)
}

// Stamps a loop on an Outline: shape_combine with a polygon of one loop.
shape_stamp :: proc(s:^Shape,stamp:[]geom.Vec2,op:geom.Polygon_Op,out:^geom.Polygon_Set) -> Shape_Error {
    if len(stamp)<3 {return .Invalid}
    stamp_loops:=[1]int{len(stamp)}
    return shape_combine(s,stamp,stamp_loops[:],op,out)
}

// Whether p is inside the outline and outside its holes.
shape_contains :: proc(s:^Shape,p:geom.Vec2) -> bool {
    if shape_valid_counts(s)!=.None {return false}
    inside:=false
    first:=0
    for l in 0..<int(s.loop_count) {
        n:=int(s.loops[l])
        if loop_contains(s.points[first:first+n],p) {inside=!inside}
        first+=n
    }
    return inside
}

// The nearest vertex within radius of p.
shape_vertex_near :: proc(s:^Shape,p:geom.Vec2,radius:f32) -> (vertex:int,found:bool) {
    if shape_valid_counts(s)!=.None {return}
    best:=radius*radius
    for q,i in s.points[:s.point_count] {
        d:=q-p
        if distance:=d.x*d.x+d.y*d.y;distance<=best {vertex,found,best=i,true,distance}
    }
    return
}

// The nearest edge within radius of p, by its first vertex, and the point of
// it nearest to p.
shape_edge_near :: proc(s:^Shape,p:geom.Vec2,radius:f32) -> (edge:int,at:geom.Vec2,found:bool) {
    if shape_valid_counts(s)!=.None {return}
    best:=radius*radius
    first:=0
    for l in 0..<int(s.loop_count) {
        n:=int(s.loops[l])
        for i in 0..<n {
            a,b:=s.points[first+i],s.points[first+(i+1)%n]
            q:=segment_nearest(a,b,p)
            d:=q-p
            if distance:=d.x*d.x+d.y*d.y;distance<=best {edge,at,found,best=first+i,q,true,distance}
        }
        first+=n
    }
    return
}

// Moves a vertex to a new place in the local XY.
shape_vertex_move :: proc(s:^Shape,vertex:int,to:geom.Vec2) -> Shape_Error {
    if error:=shape_valid_counts(s);error!=.None {return error}
    if vertex<0 || vertex>=int(s.point_count) || !finite2(to) {return .Invalid}
    loop,first,n:=loop_of(s,vertex)
    before:=loop_area(s.points[first:first+n])
    previous:=s.points[vertex]
    s.points[vertex]=to
    prev:=first+(vertex-first+n-1)%n
    if !edge_clear(s,prev) || !edge_clear(s,vertex) || !loops_hold(s,loop,before) {
        s.points[vertex]=previous
        return .Self_Intersecting
    }
    return .None
}

// Inserts a vertex at `at` on an edge, after its first vertex.
shape_vertex_insert :: proc(s:^Shape,edge:int,at:geom.Vec2) -> Shape_Error {
    if error:=shape_valid_counts(s);error!=.None {return error}
    if edge<0 || edge>=int(s.point_count) || !finite2(at) {return .Invalid}
    if int(s.point_count)>=SHAPE_POINTS {return .Too_Many_Points}
    loop,first,n:=loop_of(s,edge)
    before:=loop_area(s.points[first:first+n])
    next:=s.point_count
    copy(s.points[edge+2:next+1],s.points[edge+1:next])
    s.points[edge+1]=at
    s.point_count+=1
    s.loops[loop]+=1
    if !edge_clear(s,edge) || !edge_clear(s,edge+1) || !loops_hold(s,loop,before) {
        copy(s.points[edge+1:next],s.points[edge+2:next+1])
        s.points[next]={}
        s.point_count-=1
        s.loops[loop]-=1
        return .Self_Intersecting
    }
    return .None
}

// Removes a vertex; a loop keeps at least three.
shape_vertex_remove :: proc(s:^Shape,vertex:int) -> Shape_Error {
    if error:=shape_valid_counts(s);error!=.None {return error}
    if vertex<0 || vertex>=int(s.point_count) {return .Invalid}
    loop,first,n:=loop_of(s,vertex)
    if n<=3 {return .Invalid}
    before:=loop_area(s.points[first:first+n])
    count:=int(s.point_count)
    removed:=s.points[vertex]
    copy(s.points[vertex:count-1],s.points[vertex+1:count])
    s.points[count-1]={}
    s.point_count-=1
    s.loops[loop]-=1
    // The edge that now joins the neighbors of the vertex starts at the one before it.
    prev:=first+(vertex-first+n-2)%(n-1)
    if !edge_clear(s,prev) || !loops_hold(s,loop,before) {
        copy(s.points[vertex+1:count],s.points[vertex:count-1])
        s.points[vertex]=removed
        s.point_count+=1
        s.loops[loop]+=1
        return .Self_Intersecting
    }
    return .None
}

// What a refused edit of a shape means, for a person.
shape_error_text :: proc(error:Shape_Error) -> string {
    switch error {
    case .None:              return ""
    case .Invalid:           return "The shape is not valid: a count, a point or an index is out of range"
    case .Empty:             return "Nothing of the shape would be left"
    case .Too_Many_Points:   return fmt.tprintf("The shape would need more than %d corners, cut it in parts",SHAPE_POINTS)
    case .Too_Many_Loops:    return fmt.tprintf("The shape would have more than %d holes; cut it in parts",SHAPE_LOOPS-1)
    case .Self_Intersecting: return "That would make edges of the shape cross or touch"
    case .Geometry:          return "The boolean of the shape and the stamp failed"
    case .Out_Of_Memory:     return "No memory to build the shape"
    }
    return ""
}

// ------------------------------------------------------------------ helpers

@(private)
finite2 :: proc "contextless" (p:geom.Vec2) -> bool {return p.x-p.x==0 && p.y-p.y==0}

@(private)
finite3 :: proc "contextless" (p:[3]f32) -> bool {return p.x-p.x==0 && p.y-p.y==0 && p.z-p.z==0}

// The counts of a shape that are in range; a game may write any value.
@(private)
shape_counts :: proc "contextless" (s:^Shape) -> (points,loops:int) {
    return min(int(s.point_count),SHAPE_POINTS),min(int(s.loop_count),SHAPE_LOOPS)
}

// Whether the loops of a shape hold its points, each at least three.
@(private)
shape_valid_counts :: proc "contextless" (s:^Shape) -> Shape_Error {
    if int(s.point_count)>SHAPE_POINTS {return .Too_Many_Points}
    if int(s.loop_count)>SHAPE_LOOPS {return .Too_Many_Loops}
    if s.loop_count==0 {return .Empty}
    total:=0
    for size in s.loops[:s.loop_count] {
        if size<3 {return .Invalid}
        total+=int(size)
    }
    if total!=int(s.point_count) {return .Invalid}
    return .None
}

@(private)
brush_valid :: proc "contextless" (b:Brush) -> bool {
    if b.kind>max(Brush_Kind) || !finite3(b.place.position) || !finite3(b.place.scale) {return false}
    q:=b.place.rotation
    if !(abs(q.x)<=2 && abs(q.y)<=2 && abs(q.z)<=2 && abs(q.w)<=2) {return false}
    scale:=b.place.scale
    return scale.x>0 && scale.y>0 && scale.z>0
}

@(private)
brush_rotation :: proc "contextless" (b:Brush) -> mm.Quat {
    q:=b.place.rotation
    length:=q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w
    if !(length>1e-12) {return mm.QUAT_IDENTITY}
    s:=1/math.sqrt(length)
    return quaternion(w=q.w*s,x=q.x*s,y=q.y*s,z=q.z*s)
}

// The loop of a vertex, its first vertex and its size.
@(private)
loop_of :: proc "contextless" (s:^Shape,vertex:int) -> (loop,first,count:int) {
    for l in 0..<int(s.loop_count) {
        n:=int(s.loops[l])
        if vertex<first+n {return l,first,n}
        first+=n
    }
    return -1,first,0
}

// The edge from a vertex: its two ends.
@(private)
edge_ends :: proc "contextless" (s:^Shape,edge:int) -> (a,b:int) {
    _,first,n:=loop_of(s,edge)
    return edge,first+(edge-first+1)%n
}

@(private)
DVec2 :: [2]f64

@(private)
dvec :: #force_inline proc "contextless" (p:geom.Vec2) -> DVec2 {return {f64(p.x),f64(p.y)}}

@(private)
orient :: #force_inline proc "contextless" (a,b,c:DVec2) -> f64 {
    return (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
}

// Whether c, on the line of ab, lies within the box of ab.
@(private)
between :: #force_inline proc "contextless" (a,b,c:DVec2) -> bool {
    return min(a.x,b.x)<=c.x && c.x<=max(a.x,b.x) && min(a.y,b.y)<=c.y && c.y<=max(a.y,b.y)
}

// Whether two closed segments meet, touching included.
@(private)
segments_meet :: proc "contextless" (a,b,c,d:DVec2) -> bool {
    d1,d2,d3,d4:=orient(c,d,a),orient(c,d,b),orient(a,b,c),orient(a,b,d)
    if (d1>0 && d2<0 || d1<0 && d2>0) && (d3>0 && d4<0 || d3<0 && d4>0) {return true}
    return d1==0 && between(c,d,a) || d2==0 && between(c,d,b) || d3==0 && between(a,b,c) || d4==0 && between(a,b,d)
}

// Whether two edges that share the end s overlap along a line: the other ends
// p and q lie on the same ray from s.
@(private)
edges_fold :: proc "contextless" (s,p,q:DVec2) -> bool {
    return orient(s,p,q)==0 && (p.x-s.x)*(q.x-s.x)+(p.y-s.y)*(q.y-s.y)>0
}

// Whether the edge from a vertex has length and meets no other edge of the
// shape but its neighbors at their shared ends.
@(private)
edge_clear :: proc(s:^Shape,edge:int) -> bool {
    ia,ib:=edge_ends(s,edge)
    a,b:=dvec(s.points[ia]),dvec(s.points[ib])
    if a==b {return false}
    first:=0
    for l in 0..<int(s.loop_count) {
        n:=int(s.loops[l])
        for i in 0..<n {
            ic,id:=first+i,first+(i+1)%n
            if ic==ia {continue}
            c,d:=dvec(s.points[ic]),dvec(s.points[id])
            switch {
            case ic==ib: if edges_fold(b,a,d) {return false}
            case id==ia: if edges_fold(a,b,c) {return false}
            case:        if segments_meet(a,b,c,d) {return false}
            }
        }
        first+=n
    }
    return true
}

// Twice the signed area of a loop: positive counter-clockwise.
@(private)
loop_area :: proc "contextless" (points:[][2]f32) -> f64 {
    area:f64
    n:=len(points)
    for i in 0..<n {
        a,b:=dvec(points[i]),dvec(points[(i+1)%n])
        area+=a.x*b.y-b.x*a.y
    }
    return area
}

// Crossing number of p against one loop.
@(private)
loop_contains :: proc "contextless" (points:[][2]f32,p:geom.Vec2) -> bool {
    inside:=false
    n:=len(points)
    q:=dvec(p)
    for i in 0..<n {
        a,b:=dvec(points[i]),dvec(points[(i+1)%n])
        if (a.y>q.y)!=(b.y>q.y) && q.x<a.x+(q.y-a.y)*(b.x-a.x)/(b.y-a.y) {inside=!inside}
    }
    return inside
}

// After an edit of one loop whose edges meet no other: whether that loop
// keeps its turn (twice its signed area was before), every hole is still in
// the outline and no hole is in another.
@(private)
loops_hold :: proc(s:^Shape,loop:int,before:f64) -> bool {
    first:=loop_first(s,loop)
    after:=loop_area(s.points[first:first+int(s.loops[loop])])
    if after==0 || (after>0)!=(before>0) {return false}
    return loops_nested(s)
}

@(private)
loop_first :: proc "contextless" (s:^Shape,loop:int) -> int {
    first:=0
    for l in 0..<loop {first+=int(s.loops[l])}
    return first
}

// Whether every hole lies in the outline and outside the other holes; the
// edges of the loops are known not to meet.
@(private)
loops_nested :: proc(s:^Shape) -> bool {
    outline:=s.points[:s.loops[0]]
    first:=int(s.loops[0])
    for h in 1..<int(s.loop_count) {
        n:=int(s.loops[h])
        p:=s.points[first]
        if !loop_contains(outline,p) {return false}
        other:=int(s.loops[0])
        for o in 1..<int(s.loop_count) {
            m:=int(s.loops[o])
            if o!=h && loop_contains(s.points[other:other+m],p) {return false}
            other+=m
        }
        first+=n
    }
    return true
}

// Whether no two edges of the loops meet, and the holes nest in the outline.
@(private)
shape_outline_clear :: proc(s:^Shape) -> bool {
    for edge in 0..<int(s.point_count) {
        if !edge_clear(s,edge) {return false}
    }
    first:=0
    for l in 0..<int(s.loop_count) {
        n:=int(s.loops[l])
        if loop_area(s.points[first:first+n])==0 {return false}
        first+=n
    }
    return loops_nested(s)
}

// Drops repeated points and those on the line between the points kept
// around them.
@(private)
loop_simplify :: proc(loop:^[dynamic]geom.Vec2) {
    for {
        n:=len(loop)
        if n<3 {return}
        removed:=false
        kept:=0
        for i in 0..<n {
            a:=dvec(loop[kept-1 if kept>0 else n-1])
            b:=dvec(loop[i])
            c:=dvec(loop[(i+1)%n])
            ac:=c-a
            length:=ac.x*ac.x+ac.y*ac.y
            drop:=b==a
            if !drop && length>0 {
                along:=(b.x-a.x)*ac.x+(b.y-a.y)*ac.y
                drop=along>=0 && along<=length && orient(a,c,b)==0
            }
            // The last point is compared with the first one kept, which may have moved.
            if drop && kept+(n-1-i)>=3 {
                removed=true
                continue
            }
            loop[kept]=loop[i]
            kept+=1
        }
        base.truncate(loop,kept)
        if !removed {return}
    }
}

@(private)
loop_reverse :: proc "contextless" (loop:[]geom.Vec2) {
    for i in 0..<len(loop)/2 {loop[i],loop[len(loop)-1-i]=loop[len(loop)-1-i],loop[i]}
}

// Moves the polygon whose outline has the largest area to the front of a set.
@(private)
set_largest_first :: proc(set:^geom.Polygon_Set) -> bool {
    best,best_area:=0,f64(0)
    loop,point:=0,0
    best_loop,best_point:=0,0
    for count,p in set.polygon_loops {
        if loop>=len(set.loop_sizes) || point+set.loop_sizes[loop]>len(set.points) {return false}
        area:=abs(loop_area(set.points[point:point+set.loop_sizes[loop]]))
        if area>best_area {best,best_area,best_loop,best_point=p,area,loop,point}
        for size in set.loop_sizes[loop:min(loop+count,len(set.loop_sizes))] {point+=size}
        loop+=count
    }
    if best==0 {return true}
    loops:=set.polygon_loops[best]
    points:=0
    for size in set.loop_sizes[best_loop:][:loops] {points+=size}
    moved_points:=make([]geom.Vec2,points,context.temp_allocator)
    moved_sizes:=make([]int,loops,context.temp_allocator)
    copy(moved_points,set.points[best_point:][:points])
    copy(moved_sizes,set.loop_sizes[best_loop:][:loops])
    copy(set.points[points:best_point+points],set.points[:best_point])
    copy(set.points[:points],moved_points)
    copy(set.loop_sizes[loops:best_loop+loops],set.loop_sizes[:best_loop])
    copy(set.loop_sizes[:loops],moved_sizes)
    copy(set.polygon_loops[1:best+1],set.polygon_loops[:best])
    set.polygon_loops[0]=loops
    return true
}

@(private)
segment_nearest :: proc "contextless" (a,b,p:geom.Vec2) -> geom.Vec2 {
    ab:=b-a
    length:=ab.x*ab.x+ab.y*ab.y
    if !(length>0) {return a}
    t:=clamp(((p.x-a.x)*ab.x+(p.y-a.y)*ab.y)/length,0,1)
    return a+ab*t
}
