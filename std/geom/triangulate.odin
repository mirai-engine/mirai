package geom

import "base:runtime"
import "core:slice"

Polygon_Rule :: enum {
    // The first loop is the outline and the others are holes in it; a loop may
    // run in either direction.
    First_Outline,
    // Counter-clockwise loops are outlines and clockwise loops are holes of
    // the smallest outline around them; a hole outside every outline is filled
    // with clockwise triangles.
    Orientation,
}

// Ear clipping of polygons with holes. `points` holds the loops one after
// another and loop_sizes the number of points of each. Appends triangles as
// indices into points, counter-clockwise, and returns how many. Every loop
// edge ends up in exactly one triangle, so collinear and repeated points are
// kept, with triangles without area where nothing else can use them. A
// negative loop size, loops of more points than there are, a point that is
// not finite or no memory for the triangles give none.
polygon_triangulate :: proc(points:[]Vec2,loop_sizes:[]int,out:^[dynamic]u32,rule:=Polygon_Rule.First_Outline) -> int {
    total:=0
    for size in loop_sizes {
        if size<0 || size>len(points)-total {return 0}
        total+=size
    }
    for p in points[:total] {
        if !finite2(p) {return 0}
    }
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=temp_is(out.allocator))
    scratch:=context.temp_allocator
    tr:Triangulator
    triangulator_init(&tr,scratch)
    doubles,no_doubles:=make([]DVec2,len(points),scratch)
    sizes,no_sizes:=make([]i32,len(loop_sizes),scratch)
    if no_doubles!=nil || no_sizes!=nil {return 0}
    for p,i in points {doubles[i]={f64(p.x),f64(p.y)}}
    for size,i in loop_sizes {sizes[i]=i32(size)}
    before:=len(out)
    if triangulate_loops(&tr,doubles,sizes,out,rule)!=nil {return 0}
    return (len(out)-before)/3
}

@(private) Tri_Loop :: struct {
    first,count:i32, // range of points
    area:       f64, // twice the signed area
    parent:     i32, // outline of a hole, -1 for an outline
    leftmost:   i32, // node of the leftmost point
    reversed:   bool,
}

@(private) Triangulator :: struct {
    point:    [dynamic]u32, // per node
    prev,next:[dynamic]i32,
    loops:    [dynamic]Tri_Loop,
    order:    [dynamic]Tri_Hole,
    reflex:   [dynamic]i32, // nodes that were not convex when last looked at
    removed:  [dynamic]bool,
    listed:   [dynamic]bool,
}
@(private) Tri_Hole :: struct {x,y:f64,loop:i32}

@(private) triangulator_init :: proc(tr:^Triangulator,allocator:runtime.Allocator) {
    tr.point=make([dynamic]u32,allocator)
    tr.prev=make([dynamic]i32,allocator)
    tr.next=make([dynamic]i32,allocator)
    tr.loops=make([dynamic]Tri_Loop,allocator)
    tr.order=make([dynamic]Tri_Hole,allocator)
    tr.reflex=make([dynamic]i32,allocator)
    tr.removed=make([dynamic]bool,allocator)
    tr.listed=make([dynamic]bool,allocator)
}
@(private) triangulator_destroy :: proc(tr:^Triangulator) {
    delete(tr.point);delete(tr.prev);delete(tr.next);delete(tr.loops);delete(tr.order)
    delete(tr.reflex);delete(tr.removed);delete(tr.listed)
    tr^={}
}

@(private="file") orient :: #force_inline proc "contextless" (a,b,c:DVec2) -> f64 {
    return (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
}

// Inside or on the border of the counter-clockwise triangle a b c.
@(private="file") in_triangle :: #force_inline proc "contextless" (a,b,c,p:DVec2) -> bool {
    return orient(a,b,p)>=0 && orient(b,c,p)>=0 && orient(c,a,p)>=0
}
@(private="file") strictly_in_triangle :: #force_inline proc "contextless" (a,b,c,p:DVec2) -> bool {
    return orient(a,b,p)>0 && orient(b,c,p)>0 && orient(c,a,p)>0
}

@(private="file") loop_contains :: proc(points:[]DVec2,loop:Tri_Loop,p:DVec2) -> bool #no_bounds_check {
    inside:=false
    a:=points[loop.first+loop.count-1]
    for i in 0..<loop.count {
        b:=points[loop.first+i]
        if (a.y>p.y)!=(b.y>p.y) && p.x<a.x+(p.y-a.y)*(b.x-a.x)/(b.y-a.y) {inside=!inside}
        a=b
    }
    return inside
}

// Links the points of a loop as nodes, forwards or backwards.
@(private="file") loop_link :: proc(tr:^Triangulator,points:[]DVec2,loop:^Tri_Loop,reversed:bool) -> i32 #no_bounds_check {
    first:=i32(len(tr.point))
    count:=loop.count
    for i in 0..<count {
        index:=loop.first+(count-1-i if reversed else i)
        append(&tr.point,u32(index))
        append(&tr.prev,first+(i+count-1)%count)
        append(&tr.next,first+(i+1)%count)
    }
    leftmost:=first
    for node in first+1..<first+count {
        a,b:=points[tr.point[node]],points[tr.point[leftmost]]
        if a.x<b.x || (a.x==b.x && a.y<b.y) {leftmost=node}
    }
    loop.leftmost=leftmost
    return first
}

@(private="file") locally_inside :: proc(tr:^Triangulator,points:[]DVec2,a:i32,b:DVec2) -> bool #no_bounds_check {
    pa,pp,pn:=points[tr.point[a]],points[tr.point[tr.prev[a]]],points[tr.point[tr.next[a]]]
    if orient(pp,pa,pn)>0 {return orient(pa,pn,b)>=0 && orient(pp,pa,b)>=0}
    return orient(pp,pa,b)>0 || orient(pa,pn,b)>0
}

// Node of the outline that sees the leftmost point of a hole: the classic
// search along the ray towards -x, then among the reflex points that could
// hide the candidate.
@(private="file") bridge_find :: proc(tr:^Triangulator,points:[]DVec2,hole,outline:i32) -> i32 #no_bounds_check {
    h:=points[tr.point[hole]]
    qx:=-max(f64)
    m:=i32(-1)
    p:=outline
    for {
        a,b:=points[tr.point[p]],points[tr.point[tr.next[p]]]
        if h.y<=a.y && h.y>=b.y && b.y!=a.y {
            x:=a.x+(h.y-a.y)*(b.x-a.x)/(b.y-a.y)
            if x<=h.x && x>qx {
                qx=x
                m=p if a.x<b.x else tr.next[p]
                if x==h.x {return m}
            }
        }
        p=tr.next[p]
        if p==outline {break}
    }
    if m<0 {return -1}
    stop:=m
    pm:=points[tr.point[m]]
    best:=max(f64)
    p=m
    for {
        c:=points[tr.point[p]]
        if h.x>=c.x && c.x>=pm.x && h.x!=c.x {
            a:=DVec2{h.x if h.y<pm.y else qx,h.y}
            b:=DVec2{qx if h.y<pm.y else h.x,h.y}
            if orient(a,pm,b)*orient(a,pm,c)>=0 && orient(pm,b,a)*orient(pm,b,c)>=0 && orient(b,a,pm)*orient(b,a,c)>=0 {
                slope:=abs(h.y-c.y)/(h.x-c.x)
                current:=points[tr.point[m]]
                better:=slope<best
                if slope==best {
                    better=c.x>current.x
                    if c.x==current.x {
                        better=orient(points[tr.point[tr.prev[m]]],current,points[tr.point[tr.prev[p]]])>0 &&
                            orient(points[tr.point[tr.next[p]]],current,points[tr.point[tr.next[m]]])>0
                    }
                }
                if better && locally_inside(tr,points,p,h) {m=p;best=slope}
            }
        }
        p=tr.next[p]
        if p==stop {break}
    }
    return m
}

// Joins the loop of b into the loop of a with a two-way bridge.
@(private="file") bridge_make :: proc(tr:^Triangulator,a,b:i32) #no_bounds_check {
    a2,b2:=i32(len(tr.point)),i32(len(tr.point))+1
    an,bp:=tr.next[a],tr.prev[b]
    append(&tr.point,tr.point[a],tr.point[b])
    append(&tr.prev,b2,bp)
    append(&tr.next,an,a2)
    tr.next[a]=b;tr.prev[b]=a
    tr.prev[an]=a2
    tr.next[bp]=b2
}

@(private="file") Ear_Level :: enum {Strict,Loose,Forced}

@(private="file") node_is_reflex :: #force_inline proc(tr:^Triangulator,points:[]DVec2,node:i32) -> bool #no_bounds_check {
    return orient(points[tr.point[tr.prev[node]]],points[tr.point[node]],points[tr.point[tr.next[node]]])<=0
}

// Only a corner that is not convex can lie inside an ear, so the test looks
// at the list of those instead of at the whole polygon.
@(private="file") ear_test :: proc(tr:^Triangulator,points:[]DVec2,ear:i32,level:Ear_Level) -> (area:f64,ok:bool) #no_bounds_check {
    prev,next:=tr.prev[ear],tr.next[ear]
    a,b,c:=points[tr.point[prev]],points[tr.point[ear]],points[tr.point[next]]
    area=orient(a,b,c)
    if level==.Forced {return area,true}
    if area<0 || (area==0 && level==.Strict) {return area,false}
    lo:=DVec2{min(a.x,b.x,c.x),min(a.y,b.y,c.y)}
    hi:=DVec2{max(a.x,b.x,c.x),max(a.y,b.y,c.y)}
    for p in tr.reflex {
        if tr.removed[p] || p==prev || p==ear || p==next {continue}
        q:=points[tr.point[p]]
        if q.x<lo.x || q.x>hi.x || q.y<lo.y || q.y>hi.y || q==a || q==b || q==c {continue}
        inside:=in_triangle(a,b,c,q) if level==.Strict else strictly_in_triangle(a,b,c,q)
        if inside && node_is_reflex(tr,points,p) {return area,false}
    }
    return area,true
}

// Clips the polygon that starts at `start`. An ear is a convex corner whose
// triangle holds no other point. When a whole turn finds none, the corner
// with the largest area that holds no point strictly inside goes, and failing
// that the corner with the largest area: the loop always ends with every edge
// used once.
@(private="file") ears_clip :: proc(tr:^Triangulator,points:[]DVec2,start:i32,flip:bool,out:^[dynamic]u32) #no_bounds_check {
    emit :: proc(tr:^Triangulator,points:[]DVec2,ear:i32,flip:bool,out:^[dynamic]u32) -> i32 #no_bounds_check {
        prev,next:=tr.prev[ear],tr.next[ear]
        if flip {append(out,tr.point[next],tr.point[ear],tr.point[prev])} else {append(out,tr.point[prev],tr.point[ear],tr.point[next])}
        tr.next[prev]=next;tr.prev[next]=prev
        tr.removed[ear]=true
        // A clip can leave its neighbours reflex only when it was not an ear,
        // but the check is cheap.
        for node in ([2]i32{prev,next}) {
            if !tr.listed[node] && node_is_reflex(tr,points,node) {tr.listed[node]=true;append(&tr.reflex,node)}
        }
        return next
    }
    clear(&tr.reflex)
    for node:=start;true; {
        tr.removed[node]=false
        tr.listed[node]=node_is_reflex(tr,points,node)
        if tr.listed[node] {append(&tr.reflex,node)}
        node=tr.next[node]
        if node==start {break}
    }
    ear:=start
    stop:=start
    for tr.prev[ear]!=tr.next[ear] {
        // A repeated point or a spike without width goes first, as a triangle
        // without area: it would pass for a corner of the polygon otherwise.
        a,b,c:=points[tr.point[tr.prev[ear]]],points[tr.point[ear]],points[tr.point[tr.next[ear]]]
        if a==b || b==c || a==c {
            ear=emit(tr,points,ear,flip,out)
            stop=ear
            continue
        }
        if _,ok:=ear_test(tr,points,ear,.Strict);ok {
            next:=emit(tr,points,ear,flip,out)
            ear=tr.next[next]
            stop=ear
            continue
        }
        ear=tr.next[ear]
        if ear!=stop {continue}
        chosen:=i32(-1)
        chosen_area:=-max(f64)
        for level in ([2]Ear_Level{.Loose,.Forced}) {
            p:=ear
            for {
                if area,ok:=ear_test(tr,points,p,level);ok && area>chosen_area {chosen=p;chosen_area=area}
                p=tr.next[p]
                if p==ear {break}
            }
            if chosen>=0 {break}
        }
        next:=emit(tr,points,chosen,flip,out)
        ear=next
        stop=next
    }
}

// Takes its memory before it links a node: every point of a loop is a node,
// a bridge adds two, and each clip of a node is one triangle. Without memory
// nothing is appended.
@(private) triangulate_loops :: proc(tr:^Triangulator,points:[]DVec2,loop_sizes:[]i32,out:^[dynamic]u32,rule:Polygon_Rule) -> runtime.Allocator_Error #no_bounds_check {
    clear(&tr.point);clear(&tr.prev);clear(&tr.next);clear(&tr.loops);clear(&tr.order)
    nodes,loops:=0,0
    for size in loop_sizes {
        if size>=3 {nodes+=int(size)+2;loops+=1}
    }
    reserve(&tr.loops,loops) or_return
    reserve(&tr.order,loops) or_return
    reserve(&tr.point,nodes) or_return
    reserve(&tr.prev,nodes) or_return
    reserve(&tr.next,nodes) or_return
    reserve(&tr.reflex,nodes) or_return
    resize(&tr.removed,nodes) or_return
    resize(&tr.listed,nodes) or_return
    reserve_more(out,3*nodes) or_return
    first:=i32(0)
    for size in loop_sizes {
        loop:=Tri_Loop{first=first,count=size,parent=-1}
        first+=size
        if size<3 {continue}
        a:=points[loop.first+size-1]
        for i in 0..<size {
            b:=points[loop.first+i]
            loop.area+=a.x*b.y-b.x*a.y
            a=b
        }
        append(&tr.loops,loop)
    }
    for &loop,i in tr.loops {
        hole:=loop.area<0
        if rule==.First_Outline {
            hole=i>0
            loop.reversed=(loop.area<0)!=hole
            if hole {loop.parent=0}
            continue
        }
        if !hole {continue}
        // The smallest outline around the first point of the hole.
        p:=points[loop.first]
        for &outline,j in tr.loops {
            if outline.area<=0 || outline.area<-loop.area || !loop_contains(points,outline,p) {continue}
            if loop.parent<0 || outline.area<tr.loops[loop.parent].area {loop.parent=i32(j)}
        }
    }
    for &loop,i in tr.loops {
        if loop.parent>=0 {continue}
        // An orphan hole is clipped backwards and its triangles flipped, so
        // that its edges keep their direction.
        orphan:=rule==.Orientation && loop.area<0
        start:=loop_link(tr,points,&loop,orphan || loop.reversed)
        clear(&tr.order)
        for &hole,j in tr.loops {
            if hole.parent!=i32(i) {continue}
            loop_link(tr,points,&hole,hole.reversed)
            p:=points[tr.point[hole.leftmost]]
            append(&tr.order,Tri_Hole{p.x,p.y,i32(j)})
        }
        slice.sort_by(tr.order[:],proc(a,b:Tri_Hole) -> bool {
            if a.x!=b.x {return a.x<b.x}
            if a.y!=b.y {return a.y<b.y}
            return a.loop<b.loop
        })
        for entry in tr.order {
            hole:=&tr.loops[entry.loop]
            bridge:=bridge_find(tr,points,hole.leftmost,start)
            if bridge>=0 {bridge_make(tr,bridge,hole.leftmost);continue}
            // No way into the outline: the hole is clipped on its own, backwards.
            for node:=hole.leftmost;true; {
                tr.prev[node],tr.next[node]=tr.next[node],tr.prev[node]
                node=tr.next[node]
                if node==hole.leftmost {break}
            }
            ears_clip(tr,points,hole.leftmost,true,out)
        }
        ears_clip(tr,points,start,orphan,out)
    }
    return nil
}
