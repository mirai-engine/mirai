package geom

import "base:runtime"
import "core:math"
import "core:slice"
import "mirai:std/base"

Hull_Error :: enum {
    None,
    Too_Few_Points, // fewer than three points
    Coincident,     // every point is within the tolerance of one point
    Collinear,      // every point is within the tolerance of one line
    Out_Of_Memory,
}

Hull_Desc :: struct {
    // Upper bound of vertices (at least 4); 0 is no limit. The hull grows from
    // the farthest points first, so a bounded hull is inside the full one.
    max_vertices:int,
    // Points closer than this to the hull are not vertices, and neighbouring
    // faces within this distance of one plane merge. 0 uses tolerance_noise.
    tolerance:f32,
}

// vertex_count indices of face_vertices from first_vertex: the corners of the
// face, counter-clockwise seen from outside. first_edge leaves from the first.
Hull_Face :: struct {first_vertex,vertex_count,first_edge:u32}

// Half-edge e runs from its origin to the origin of e~1, its twin, with its
// face on the left; next is the following half-edge around that face.
Hull_Half_Edge :: struct {origin,face,next:u32}

// Convex polyhedron as a SAT narrowphase needs it. No vertex is in front of a
// plane, and without max_vertices no input point is further than the
// tolerance in front of one.
Hull :: struct {
    vertices:     []Vec3,
    sources:      []u32,   // index of each vertex in the points given
    planes:       []Plane, // one per face, pointing outwards
    faces:        []Hull_Face,
    face_vertices:[]u32,
    half_edges:   []Hull_Half_Edge,
    allocator:    runtime.Allocator,
}

hull_destroy :: proc(hull:^Hull) {
    delete(hull.vertices,hull.allocator)
    delete(hull.sources,hull.allocator)
    delete(hull.planes,hull.allocator)
    delete(hull.faces,hull.allocator)
    delete(hull.face_vertices,hull.allocator)
    delete(hull.half_edges,hull.allocator)
    hull^={}
}

hull_edge_count :: proc(hull:Hull) -> int {return len(hull.half_edges)/2}

// Quickhull. Duplicated, collinear and coplanar points are legal input. Points
// within the tolerance of one plane give a flat hull (hull_is_flat): their
// convex polygon as two faces back to back, with no volume. Points that span
// less than a plane return the error that names their dimension.
hull_build :: proc(points:[]Vec3,desc:Hull_Desc={},allocator:=context.allocator) -> (hull:Hull,error:Hull_Error) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=temp_is(allocator))
    q:Qh
    error=qh_run(&q,points,desc)
    if error!=.None {return}
    if q.flat {return qh_flat(&q,points,desc,allocator)}
    ok:bool
    no_memory:runtime.Allocator_Error
    hull,ok,no_memory=qh_emit(&q,points,true,allocator)
    if !ok && no_memory==nil {hull,_,no_memory=qh_emit(&q,points,false,allocator)}
    if no_memory!=nil {return {},.Out_Of_Memory}
    return
}

// The six arrays of a hull, or none of them.
@(private="file")
hull_make :: proc(vertices,faces,corners:int,allocator:runtime.Allocator) -> (hull:Hull,error:runtime.Allocator_Error) {
    hull.allocator=allocator
    failed:[6]runtime.Allocator_Error
    hull.vertices,failed[0]=make([]Vec3,vertices,allocator)
    hull.sources,failed[1]=make([]u32,vertices,allocator)
    hull.planes,failed[2]=make([]Plane,faces,allocator)
    hull.faces,failed[3]=make([]Hull_Face,faces,allocator)
    hull.face_vertices,failed[4]=make([]u32,corners,allocator)
    hull.half_edges,failed[5]=make([]Hull_Half_Edge,corners,allocator)
    for f in failed {
        if f!=nil {hull_destroy(&hull);return {},f}
    }
    return hull,nil
}

// Volume of the convex hull of the points; 0 when they span no volume.
points_hull_volume :: proc(points:[]Vec3,desc:Hull_Desc={}) -> f32 {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    q:Qh
    if qh_run(&q,points,desc)!=.None || q.flat {return 0}
    sums:Mass_Sums
    for f in q.faces {
        if f.alive {mass_add(&sums,q.points[f.v[0]],q.points[f.v[1]],q.points[f.v[2]])}
    }
    return f32(sums.volume/6)
}

// Two faces back to back: the hull of points in one plane.
hull_is_flat :: proc(hull:Hull) -> bool {return len(hull.faces)==2}

hull_mass_properties :: proc(hull:Hull) -> Mass_Properties {
    lo,hi:=mesh_bounds(hull.vertices)
    sums:=Mass_Sums{origin=(dvec(lo)+dvec(hi))*0.5}
    for face in hull.faces {
        loop:=hull.face_vertices[face.first_vertex:][:face.vertex_count]
        a:=dvec(hull.vertices[loop[0]])
        for i in 1..<len(loop)-1 {
            mass_add(&sums,a,dvec(hull.vertices[loop[i]]),dvec(hull.vertices[loop[i+1]]))
        }
    }
    return mass_finish(sums)
}

// Largest distance of `point` in front of a face plane; negative inside.
hull_distance_outside :: proc(hull:Hull,point:Vec3) -> f32 {
    worst:=-max(f32)
    for plane in hull.planes {worst=max(worst,plane_distance(plane,point))}
    return worst
}

// Structural and geometric invariants: twins pair up, every face is a closed
// loop of at least three corners, the surface is a sphere (V-E+F=2; a flat
// hull is two faces), and no vertex is further than `tolerance` in front of a
// plane.
hull_is_valid :: proc(hull:Hull,tolerance:f32) -> bool {
    vertex_count,face_count,edge_count:=len(hull.vertices),len(hull.faces),len(hull.half_edges)
    if face_count!=2 && (vertex_count<4 || face_count<4) || vertex_count<3 || edge_count%2!=0 {return false}
    if len(hull.planes)!=face_count || len(hull.sources)!=vertex_count {return false}
    if vertex_count-edge_count/2+face_count!=2 {return false}
    for e,i in hull.half_edges {
        if int(e.origin)>=vertex_count || int(e.face)>=face_count || int(e.next)>=edge_count {return false}
        twin:=hull.half_edges[i~1]
        if twin.face==e.face || hull.half_edges[e.next].origin!=twin.origin {return false}
        if hull.half_edges[e.next].face!=e.face {return false}
    }
    for face,f in hull.faces {
        if face.vertex_count<3 || int(face.first_vertex+face.vertex_count)>len(hull.face_vertices) {return false}
        e:=face.first_edge
        for i in 0..<face.vertex_count {
            if int(e)>=edge_count {return false}
            edge:=hull.half_edges[e]
            if int(edge.face)!=f || edge.origin!=hull.face_vertices[face.first_vertex+i] {return false}
            e=edge.next
        }
        if e!=face.first_edge {return false}
    }
    for v in hull.vertices {
        if hull_distance_outside(hull,v)>tolerance {return false}
    }
    return true
}

@(private="file") Qh_Face :: struct {
    v:       [3]i32,
    adj:     [3]i32, // face across the edge from v[k] to v[k+1]
    n:       DVec3,
    d:       f64,
    far_dist:f64,
    conflict:i32,    // first point outside this face, linked through Qh.next
    far:     i32,
    stamp:   u32,
    alive:   bool,
    flat:    bool,   // no trustworthy plane: never visible and owns no points
}

@(private="file") Qh_Entry :: struct {face,point:i32}
@(private="file") Qh_Edge :: struct {a,b,outside:i32}

@(private="file") Qh :: struct {
    points:   []DVec3, // relative to center
    center:   DVec3,
    faces:    [dynamic]Qh_Face,
    free:     [dynamic]i32,
    next:     []i32,
    heap:     base.Priority_Queue(f64,Qh_Entry), // keyed by -far_dist; holds stale entries too
    stack:    [dynamic]i32,
    visible:  [dynamic]i32,
    horizon:  [dynamic]Qh_Edge,
    created:  [dynamic]i32,
    labels:   [dynamic]i32,
    deferred: [dynamic]i32,
    alive:    int,
    tolerance:f64,
    sight:    f64, // a face further than this behind a point is visible from it
    flat_area:f64,
    stamp:    u32,
    flat:     bool,  // the points are within the tolerance of the plane through `origin` along `normal`
    normal:   DVec3,
    origin:   i32,
}

@(private="file") qh_plane :: proc(q:^Qh,f:^Qh_Face) {
    a:=q.points[f.v[0]]
    n:=dcross(q.points[f.v[1]]-a,q.points[f.v[2]]-a)
    l:=dlength(n)
    f.flat=!(l>q.flat_area)
    if f.flat {f.n={};f.d=0;return}
    f.n=n/l
    f.d=ddot(f.n,a)
}

@(private="file") qh_face_add :: proc(q:^Qh,a,b,c:i32) -> i32 {
    index:i32
    if len(q.free)>0 {index=pop(&q.free)} else {index=i32(len(q.faces));append(&q.faces,Qh_Face{})}
    f:=&q.faces[index]
    f^={v={a,b,c},adj={-1,-1,-1},conflict=-1,far=-1,alive=true}
    qh_plane(q,f)
    q.alive+=1
    return index
}

@(private="file") qh_edge_from :: #force_inline proc(f:^Qh_Face,vertex:i32) -> int {
    return 0 if f.v[0]==vertex else 1 if f.v[1]==vertex else 2
}

// Squared distance from p to the triangle of a face.
@(private="file") qh_distance2 :: proc(q:^Qh,f:^Qh_Face,p:DVec3) -> f64 #no_bounds_check {
    a,b,c:=q.points[f.v[0]],q.points[f.v[1]],q.points[f.v[2]]
    ab,ac,ap:=b-a,c-a,p-a
    closest:DVec3
    d1,d2:=ddot(ab,ap),ddot(ac,ap)
    bp:=p-b
    d3,d4:=ddot(ab,bp),ddot(ac,bp)
    cp:=p-c
    d5,d6:=ddot(ab,cp),ddot(ac,cp)
    va,vb,vc:=d3*d6-d5*d4,d5*d2-d1*d6,d1*d4-d3*d2
    switch {
    case d1<=0 && d2<=0: closest=a
    case d3>=0 && d4<=d3: closest=b
    case vc<=0 && d1>=0 && d3<=0: closest=a+ab*(d1/(d1-d3))
    case d6>=0 && d5<=d6: closest=c
    case vb<=0 && d2>=0 && d6<=0: closest=a+ac*(d2/(d2-d6))
    case va<=0 && d4-d3>=0 && d5-d6>=0: closest=b+(c-b)*((d4-d3)/((d4-d3)+(d5-d6)))
    case:
        scale:=1/(va+vb+vc)
        closest=a+ab*(vb*scale)+ac*(vc*scale)
    }
    delta:=p-closest
    return ddot(delta,delta)
}

@(private="file") qh_link :: proc(q:^Qh,index,point:i32,dist:f64) {
    f:=&q.faces[index]
    q.next[point]=f.conflict
    f.conflict=point
    if f.far<0 || dist>f.far_dist {f.far=point;f.far_dist=dist}
}

// Gives the point to the candidate it is furthest in front of, when that is
// further than the tolerance. A point in front of a plane by less can still be
// far from the hull, beside a thin face: it is dropped only when it is within
// the tolerance of a triangle. With `all` the candidates are every face and
// the answer is final; otherwise they are the new faces, and a point that is
// not near one of them waits in `deferred` to be tested against every face.
@(private="file") qh_assign :: proc(q:^Qh,point:i32,candidates:[]i32,all:bool) #no_bounds_check {
    best:=i32(-1)
    best_dist:=-max(f64)
    has_flat:=false
    p:=q.points[point]
    for index in candidates {
        f:=&q.faces[index]
        if !f.alive {continue}
        if f.flat {has_flat=true;continue}
        dist:=ddot(f.n,p)-f.d
        if dist>best_dist {best_dist=dist;best=index}
    }
    if best<0 || best_dist<=0 {
        if has_flat && !all {append(&q.deferred,point)}
        return
    }
    if best_dist>q.tolerance {qh_link(q,best,point,best_dist);return}
    limit:=q.tolerance*q.tolerance
    if qh_distance2(q,&q.faces[best],p)<=limit {return}
    if !all {append(&q.deferred,point);return}
    nearest:=max(f64)
    for index in candidates {
        f:=&q.faces[index]
        if !f.alive || f.flat || ddot(f.n,p)-f.d<=0 {continue}
        nearest=min(nearest,qh_distance2(q,f,p))
        if nearest<=limit {return}
    }
    qh_link(q,best,point,math.sqrt(nearest))
}

@(private="file") qh_push :: proc(q:^Qh,index:i32) {
    f:=&q.faces[index]
    if f.far<0 {return}
    if q.heap.count==q.heap.capacity {
        // Full of stale entries: the live ones, this face among them, fit,
        // since a closed hull has fewer faces than twice its points.
        base.priority_queue_clear(&q.heap)
        for &g,i in q.faces {
            if g.alive && g.far>=0 {base.priority_queue_push(&q.heap,-g.far_dist,Qh_Entry{i32(i),g.far})}
        }
        return
    }
    base.priority_queue_push(&q.heap,-f.far_dist,Qh_Entry{index,f.far})
}

@(private="file") qh_run :: proc(q:^Qh,points:[]Vec3,desc:Hull_Desc) -> Hull_Error #no_bounds_check {
    n:=len(points)
    if n<3 {return .Too_Few_Points}
    scratch:=context.temp_allocator
    lo,hi:=mesh_bounds(points)
    q.center=(dvec(lo)+dvec(hi))*0.5
    q.points=make([]DVec3,n,scratch)
    extent:f64
    for p,i in points {
        q.points[i]=dvec(p)-q.center
        extent=max(extent,abs(q.points[i].x),abs(q.points[i].y),abs(q.points[i].z))
    }
    q.tolerance=f64(max(desc.tolerance,tolerance_noise(positions_max_abs(points))))
    q.sight=1e-10*extent
    q.flat_area=1e-9*extent*extent

    i0,i1,i2,i3:i32
    best:f64=-1
    for p,i in q.points {if d:=ddot(p,p);d>best {best=d;i0=i32(i)}}
    best=-1
    for p,i in q.points {
        delta:=p-q.points[i0]
        if d:=ddot(delta,delta);d>best {best=d;i1=i32(i)}
    }
    if !(best>q.tolerance*q.tolerance) {return .Coincident}
    axis:=q.points[i1]-q.points[i0]
    axis_length2:=best
    best=-1
    for p,i in q.points {
        c:=dcross(axis,p-q.points[i0])
        if d:=ddot(c,c);d>best {best=d;i2=i32(i)}
    }
    if !(best>q.tolerance*q.tolerance*axis_length2) {return .Collinear}
    normal:=dnormalize(dcross(axis,q.points[i2]-q.points[i0]))
    best=-1
    height:f64
    for p,i in q.points {
        h:=ddot(normal,p-q.points[i0])
        if abs(h)>best {best=abs(h);height=h;i3=i32(i)}
    }
    if !(best>q.tolerance) {
        q.flat,q.normal,q.origin=true,normal,i0
        return .None
    }
    if height>0 {i1,i2=i2,i1}

    q.faces=make([dynamic]Qh_Face,0,64,scratch)
    q.free=make([dynamic]i32,0,64,scratch)
    q.stack=make([dynamic]i32,0,64,scratch)
    q.visible=make([dynamic]i32,0,64,scratch)
    q.horizon=make([dynamic]Qh_Edge,0,64,scratch)
    q.created=make([dynamic]i32,0,64,scratch)
    q.labels=make([dynamic]i32,0,64,scratch)
    q.deferred=make([dynamic]i32,0,64,scratch)
    q.next=make([]i32,n,scratch)
    base.priority_queue_init(&q.heap,2*n+8,scratch)

    first:=[4]i32{qh_face_add(q,i0,i1,i2),qh_face_add(q,i0,i3,i1),qh_face_add(q,i1,i3,i2),qh_face_add(q,i2,i3,i0)}
    for a in first {
        fa:=&q.faces[a]
        for k in 0..<3 {
            for b in first {
                if a==b {continue}
                fb:=&q.faces[b]
                for j in 0..<3 {
                    if fb.v[j]==fa.v[(k+1)%3] && fb.v[(j+1)%3]==fa.v[k] {fa.adj[k]=b}
                }
            }
        }
    }
    for i in 0..<i32(n) {
        if i==i0 || i==i1 || i==i2 || i==i3 {continue}
        qh_assign(q,i,first[:],true)
    }
    for index in first {qh_push(q,index)}

    limit:=max(desc.max_vertices,4) if desc.max_vertices>0 else max(int)
    everything:=make([dynamic]i32,0,64,scratch)
    pending:=make([dynamic]i32,0,64,scratch)
    for {
        for {
            key,entry,ok:=base.priority_queue_pop(&q.heap)
            if !ok {break}
            f:=&q.faces[entry.face]
            if !f.alive || f.far!=entry.point || f.far_dist!=-key {continue}
            if 2+q.alive/2>=limit {return .None}
            if !qh_add_point(q,entry.face,entry.point) {return .Out_Of_Memory}
        }
        if len(q.deferred)==0 {break}
        clear(&everything)
        for i in 0..<len(q.faces) {append(&everything,i32(i))}
        clear(&pending)
        append(&pending,..q.deferred[:])
        clear(&q.deferred)
        for point in pending {qh_assign(q,point,everything[:],true)}
        for i in 0..<len(q.faces) {
            f:=&q.faces[i]
            if f.alive && f.far>=0 {qh_push(q,i32(i))}
        }
    }
    return .None
}

// Orders the border of the visible faces into q.horizon. False when the
// border is not one closed loop.
@(private="file") qh_horizon :: proc(q:^Qh) -> bool #no_bounds_check {
    clear(&q.horizon)
    total:=0
    start_face,start_edge:=i32(-1),0
    for index in q.visible {
        f:=&q.faces[index]
        for k in 0..<3 {
            if q.faces[f.adj[k]].stamp==q.stamp {continue}
            if total==0 {start_face=index;start_edge=k}
            total+=1
        }
    }
    if total<3 {return false}
    face,edge:=start_face,start_edge
    for _ in 0..<total {
        f:=&q.faces[face]
        a,b:=f.v[edge],f.v[(edge+1)%3]
        append(&q.horizon,Qh_Edge{a,b,f.adj[edge]})
        // Turn around b inside the visible faces until the next border edge.
        edge=(edge+1)%3
        for steps:=0;q.faces[f.adj[edge]].stamp==q.stamp;steps+=1 {
            if steps>len(q.faces) {return false}
            other:=f.v[(edge+1)%3]
            face=f.adj[edge]
            f=&q.faces[face]
            edge=(qh_edge_from(f,other)+1)%3
        }
        if f.v[edge]!=b {return false}
    }
    return face==start_face && edge==start_edge
}

// Faces hidden from the point but enclosed by visible ones would leave a
// second border: only the largest hidden region stays.
@(private="file") qh_absorb_islands :: proc(q:^Qh) -> bool #no_bounds_check {
    if resize(&q.labels,len(q.faces))!=nil {return false}
    for &l in q.labels {l=-1}
    largest,largest_size,regions:=i32(-1),0,i32(0)
    for &f,index in q.faces {
        if !f.alive || f.stamp==q.stamp || q.labels[index]>=0 {continue}
        size:=0
        clear(&q.stack)
        append(&q.stack,i32(index))
        q.labels[index]=regions
        for len(q.stack)>0 {
            g:=&q.faces[pop(&q.stack)]
            size+=1
            for k in 0..<3 {
                h:=g.adj[k]
                if q.faces[h].stamp==q.stamp || q.labels[h]>=0 {continue}
                q.labels[h]=regions
                append(&q.stack,h)
            }
        }
        if size>largest_size {largest_size=size;largest=regions}
        regions+=1
    }
    for &f,index in q.faces {
        if !f.alive || f.stamp==q.stamp || q.labels[index]==largest {continue}
        f.stamp=q.stamp
        append(&q.visible,i32(index))
    }
    return true
}

// False without temporary memory.
@(private="file") qh_add_point :: proc(q:^Qh,seed,point:i32) -> bool #no_bounds_check {
    p:=q.points[point]
    q.stamp+=1
    clear(&q.visible);clear(&q.stack)
    q.faces[seed].stamp=q.stamp
    append(&q.stack,seed);append(&q.visible,seed)
    for len(q.stack)>0 {
        f:=&q.faces[pop(&q.stack)]
        for k in 0..<3 {
            g:=&q.faces[f.adj[k]]
            if g.stamp==q.stamp || g.flat || !(ddot(g.n,p)-g.d>q.sight) {continue}
            g.stamp=q.stamp
            append(&q.stack,f.adj[k]);append(&q.visible,f.adj[k])
        }
    }
    if !qh_horizon(q) {
        if !qh_absorb_islands(q) {return false}
        if !qh_horizon(q) {
            // The point cannot be added without breaking the surface: forget it.
            f:=&q.faces[seed]
            list:=f.conflict
            f.conflict=-1;f.far=-1;f.far_dist=0
            for i:=list;i>=0; {
                following:=q.next[i]
                if i!=point {
                    q.next[i]=f.conflict
                    f.conflict=i
                    dist:=ddot(f.n,q.points[i])-f.d
                    if f.far<0 || dist>f.far_dist {f.far=i;f.far_dist=dist}
                }
                i=following
            }
            qh_push(q,seed)
            return true
        }
    }
    clear(&q.created)
    for edge in q.horizon {append(&q.created,qh_face_add(q,edge.a,edge.b,point))}
    count:=len(q.created)
    for edge,i in q.horizon {
        f:=&q.faces[q.created[i]]
        f.adj={edge.outside,q.created[(i+1)%count],q.created[(i+count-1)%count]}
        outside:=&q.faces[edge.outside]
        outside.adj[qh_edge_from(outside,edge.b)]=q.created[i]
    }
    for index in q.visible {
        for i:=q.faces[index].conflict;i>=0; {
            following:=q.next[i]
            if i!=point {qh_assign(q,i,q.created[:],false)}
            i=following
        }
    }
    for index in q.visible {
        q.faces[index].alive=false
        q.faces[index].conflict=-1
        q.faces[index].far=-1
        append(&q.free,index)
        q.alive-=1
    }
    for index in q.created {qh_push(q,index)}
    return true
}

@(private="file") Qh_Triangle :: struct {
    v:    [3]i32,
    adj:  [3]i32,
    n:    DVec3,
    d:    f64,
    area: f64,
    group:i32,
    flat: bool,
}

// Builds the output from the triangles of the finished hull. With `merge`,
// triangles within the tolerance of one plane become one polygon; false means
// the merged surface failed its checks and the caller emits the triangles.
@(private="file") qh_emit :: proc(q:^Qh,points:[]Vec3,merge:bool,allocator:runtime.Allocator) -> (hull:Hull,ok:bool,error:runtime.Allocator_Error) #no_bounds_check {
    scratch:=context.temp_allocator
    triangle_of:=make([]i32,len(q.faces),scratch)
    triangles:=make([dynamic]Qh_Triangle,0,q.alive,scratch)
    for f,index in q.faces {
        if !f.alive {continue}
        triangle_of[index]=i32(len(triangles))
        a:=q.points[f.v[0]]
        area:=dlength(dcross(q.points[f.v[1]]-a,q.points[f.v[2]]-a))
        append(&triangles,Qh_Triangle{v=f.v,adj=f.adj,n=f.n,d=f.d,area=area,group=-1,flat=f.flat})
    }
    for &t in triangles {
        for k in 0..<3 {t.adj[k]=triangle_of[t.adj[k]]}
    }
    count:=len(triangles)
    stack:=make([dynamic]i32,0,64,scratch)

    // A triangle without area takes the plane of the nearest triangle that
    // has one, starting across its longest edge.
    reached:=make([]i32,count,scratch)
    for &r in reached {r=-1}
    for &t,i in triangles {
        if !t.flat {continue}
        longest,longest_length:=0,f64(-1)
        for k in 0..<3 {
            e:=q.points[t.v[(k+1)%3]]-q.points[t.v[k]]
            if l:=ddot(e,e);l>longest_length {longest_length=l;longest=k}
        }
        t.n={0,1,0}
        t.d=max(q.points[t.v[0]].y,q.points[t.v[1]].y,q.points[t.v[2]].y)
        clear(&stack)
        reached[i]=i32(i)
        for k in 0..<3 {append(&stack,t.adj[(longest+k)%3])}
        for head:=0;head<len(stack);head+=1 {
            index:=stack[head]
            if reached[index]==i32(i) {continue}
            reached[index]=i32(i)
            u:=&triangles[index]
            if !u.flat {t.n=u.n;t.d=u.d;break}
            append(&stack,u.adj[0],u.adj[1],u.adj[2])
        }
    }

    // Seeded growth from the largest triangles: a group never drifts further
    // than the tolerance from the plane of its seed.
    Order :: struct {area:f64,index:i32}
    order:=make([]Order,count,scratch)
    for t,i in triangles {order[i]={t.area,i32(i)}}
    slice.sort_by(order,proc(a,b:Order) -> bool {return a.area>b.area || (a.area==b.area && a.index<b.index)})
    members:=make([dynamic]i32,0,count,scratch)
    Group :: struct {first,count:i32,n:DVec3,d:f64}
    groups:=make([dynamic]Group,0,count,scratch)
    for entry in order {
        seed:=&triangles[entry.index]
        if seed.group>=0 || seed.flat {continue}
        group:=i32(len(groups))
        first:=i32(len(members))
        seed.group=group
        append(&members,entry.index)
        if merge {
            clear(&stack)
            append(&stack,entry.index)
            for len(stack)>0 {
                t:=&triangles[pop(&stack)]
                for k in 0..<3 {
                    u:=&triangles[t.adj[k]]
                    if u.group>=0 || (!u.flat && ddot(u.n,seed.n)<=0) {continue}
                    near:=true
                    for vertex in u.v {
                        if abs(ddot(seed.n,q.points[vertex])-seed.d)>q.tolerance {near=false;break}
                    }
                    if !near {continue}
                    u.group=group
                    append(&members,t.adj[k]);append(&stack,t.adj[k])
                }
            }
        }
        append(&groups,Group{first,i32(len(members))-first,seed.n,seed.d})
    }
    for &t,i in triangles {
        if t.group>=0 {continue}
        t.group=i32(len(groups))
        append(&groups,Group{i32(len(members)),1,t.n,t.d})
        append(&members,i32(i))
    }

    // Border loop of every group.
    loops:=make([dynamic]i32,0,count*3,scratch)
    Face :: struct {first,count:i32,n:DVec3,d:f64,fixed,removed:bool}
    faces:=make([dynamic]Face,0,len(groups),scratch)
    seen:=make([]i32,len(q.points),scratch)
    for &s in seen {s=-1}
    emit_triangle :: proc(faces:^[dynamic]Face,loops:^[dynamic]i32,t:^Qh_Triangle) {
        append(faces,Face{i32(len(loops)),3,t.n,t.d,t.flat,false})
        append(loops,t.v[0],t.v[1],t.v[2])
    }
    for group,g in groups {
        list:=members[group.first:][:group.count]
        if group.count==1 {
            emit_triangle(&faces,&loops,&triangles[list[0]])
            continue
        }
        border:=0
        start_triangle,start_edge:=i32(-1),0
        for index in list {
            t:=&triangles[index]
            for k in 0..<3 {
                if triangles[t.adj[k]].group==i32(g) {continue}
                if border==0 {start_triangle=index;start_edge=k}
                border+=1
            }
        }
        first:=i32(len(loops))
        valid:=border>=3
        triangle,edge:=start_triangle,start_edge
        walk: for _ in 0..<border {
            if !valid {break}
            t:=&triangles[triangle]
            a,b:=t.v[edge],t.v[(edge+1)%3]
            if seen[a]==i32(g) {valid=false;break}
            seen[a]=i32(g)
            append(&loops,a)
            edge=(edge+1)%3
            for steps:=0;triangles[t.adj[edge]].group==i32(g);steps+=1 {
                if steps>count {valid=false;break walk}
                other:=t.v[(edge+1)%3]
                triangle=t.adj[edge]
                t=&triangles[triangle]
                edge=0 if t.v[0]==other else 1 if t.v[1]==other else 2
                edge=(edge+1)%3
            }
            if t.v[edge]!=b {valid=false}
        }
        valid=valid && triangle==start_triangle && edge==start_edge
        if valid {
            // The outline must be convex within the tolerance.
            size:=len(loops)-int(first)
            for i in 0..<size {
                a:=q.points[loops[int(first)+i]]
                b:=q.points[loops[int(first)+(i+1)%size]]
                c:=q.points[loops[int(first)+(i+2)%size]]
                ab,bc:=b-a,c-b
                if ddot(dcross(ab,bc),group.n)<-q.tolerance*(dlength(ab)+dlength(bc)) {valid=false;break}
            }
        }
        if !valid {
            resize(&loops,int(first))
            for index in list {emit_triangle(&faces,&loops,&triangles[index])}
            continue
        }
        append(&faces,Face{first,i32(len(loops))-first,group.n,group.d,false,false})
    }

    // A vertex left between only two faces lies on their common edge: drop
    // it, and drop the faces that lose their area with it.
    uses:=make([]i32,len(q.points),scratch)
    if merge {
        for round in 0..<64 {
            for &u in uses {u=0}
            for face in faces {
                if face.removed {continue}
                for vertex in loops[face.first:][:face.count] {uses[vertex]+=1}
            }
            changed:=false
            for &face in faces {
                if face.removed {continue}
                kept:=i32(0)
                for i in 0..<face.count {
                    vertex:=loops[face.first+i]
                    if uses[vertex]<3 {changed=true;continue}
                    loops[face.first+kept]=vertex
                    kept+=1
                }
                face.count=kept
                if kept<3 {face.removed=true;changed=true}
            }
            if !changed {break}
            if round==63 {return {},false,nil}
        }
    }

    // Vertices in the order of the input, faces in the order they were found.
    vertex_of:=uses
    for &u in vertex_of {u=0}
    face_count,corner_count:=0,0
    for face in faces {
        if face.removed {continue}
        face_count+=1
        corner_count+=int(face.count)
        for vertex in loops[face.first:][:face.count] {vertex_of[vertex]=1}
    }
    vertex_count:=0
    for &v in vertex_of {
        if v==0 {v=-1;continue}
        v=i32(vertex_count)
        vertex_count+=1
    }
    if face_count<4 || vertex_count<4 || corner_count%2!=0 || vertex_count-corner_count/2+face_count!=2 {return {},false,nil}

    // One id per corner, and the one that shows there are more: it fails below.
    edge_ids:Key_Map
    key_map_init(&edge_ids,scratch)
    if no_ids:=key_map_reset(&edge_ids,corner_count+1);no_ids!=nil {return {},false,no_ids}
    claimed:=make([]bool,corner_count,scratch)
    corner_edges:=make([]u32,corner_count,scratch)
    edge_total:=u32(0)
    corner:=0
    for face in faces {
        if face.removed {continue}
        for i in 0..<face.count {
            a:=u32(vertex_of[loops[face.first+i]])
            b:=u32(vertex_of[loops[face.first+(i+1)%face.count]])
            if a==b {return {},false,nil}
            entry,inserted:=key_map_entry(&edge_ids,pair_key(a,b),edge_total)
            id:=entry^
            if inserted {
                if int(edge_total)+2>corner_count {return {},false,nil}
                _,twin_inserted:=key_map_entry(&edge_ids,pair_key(b,a),edge_total+1)
                if !twin_inserted {return {},false,nil}
                edge_total+=2
            }
            if claimed[id] {return {},false,nil}
            claimed[id]=true
            corner_edges[corner]=id
            corner+=1
        }
    }
    if int(edge_total)!=corner_count {return {},false,nil}

    hull=hull_make(vertex_count,face_count,corner_count,allocator) or_return
    for v,i in vertex_of {
        if v<0 {continue}
        hull.vertices[v]=points[i]
        hull.sources[v]=u32(i)
    }
    corner=0
    f:=0
    for face in faces {
        if face.removed {continue}
        first:=corner
        // The plane keeps the normal of the seed and rests on the furthest
        // corner, so the whole hull stays behind it.
        d:=face.d
        for i in 0..<face.count {
            vertex:=loops[face.first+i]
            if !face.fixed {d=max(d,ddot(face.n,q.points[vertex]))}
            hull.face_vertices[corner]=u32(vertex_of[vertex])
            id:=corner_edges[corner]
            following:=corner_edges[first+(int(i)+1)%int(face.count)]
            hull.half_edges[id]={u32(vertex_of[vertex]),u32(f),following}
            corner+=1
        }
        hull.planes[f]={fvec(face.n),f32(d+ddot(face.n,q.center))}
        hull.faces[f]={u32(first),u32(face.count),corner_edges[first]}
        f+=1
    }
    return hull,true,nil
}


// Appends the hull as triangles, each face as a fan from its first corner.
// False, with nothing appended, without memory.
hull_append_mesh :: proc(hull:Hull,out:^Mesh_Buffer) -> bool {
    corners:=0
    for face in hull.faces {corners+=3*max(int(face.vertex_count)-2,0)}
    if reserve_more(&out.positions,len(hull.vertices))!=nil || reserve_more(&out.indices,corners)!=nil {return false}
    base:=u32(len(out.positions))
    append(&out.positions,..hull.vertices)
    for face in hull.faces {
        loop:=hull.face_vertices[face.first_vertex:][:face.vertex_count]
        for i in 1..<len(loop)-1 {append(&out.indices,base+loop[0],base+loop[i],base+loop[i+1])}
    }
    return true
}

// The flat hull: the convex polygon of the points in coordinates of their
// plane (Andrew's monotone chain, dropping corners within the tolerance of
// the edge that skips them), counter-clockwise seen along the normal, as a
// front face and a back face that share every edge. Each plane passes
// through the vertex furthest along it, so no vertex is in front of one.
@(private="file")
qh_flat :: proc(q:^Qh,points:[]Vec3,desc:Hull_Desc,allocator:runtime.Allocator) -> (hull:Hull,error:Hull_Error) {
    Corner :: struct {x,y:f64,index:u32}
    u:DVec3
    for p in q.points {
        if axis:=p-q.points[q.origin];ddot(axis,axis)>ddot(u,u) {u=axis}
    }
    u=dnormalize(u-q.normal*ddot(q.normal,u))
    v:=dcross(q.normal,u)
    sorted:=make([]Corner,len(points),context.temp_allocator)
    for p,i in q.points {sorted[i]={ddot(p,u),ddot(p,v),u32(i)}}
    slice.sort_by(sorted,proc(a,b:Corner) -> bool {return a.x<b.x || a.x==b.x && (a.y<b.y || a.y==b.y && a.index<b.index)})
    // a is no corner when it is not further than the tolerance to the right of o->b.
    inside :: proc(o,a,b:Corner,tolerance:f64) -> bool {
        turn:=(a.x-o.x)*(b.y-o.y)-(a.y-o.y)*(b.x-o.x)
        return turn<=tolerance*math.sqrt((b.x-o.x)*(b.x-o.x)+(b.y-o.y)*(b.y-o.y))
    }
    chain:=make([]Corner,2*len(sorted),context.temp_allocator)
    k:=0
    for p in sorted {
        for k>=2 && inside(chain[k-2],chain[k-1],p,q.tolerance) {k-=1}
        chain[k]=p;k+=1
    }
    lower:=k+1
    #reverse for p in sorted[:len(sorted)-1] {
        for k>=lower && inside(chain[k-2],chain[k-1],p,q.tolerance) {k-=1}
        chain[k]=p;k+=1
    }
    polygon:=chain[:k-1]
    if desc.max_vertices>0 && len(polygon)>desc.max_vertices {
        kept:=make([]Corner,max(desc.max_vertices,3),context.temp_allocator)
        for &corner,i in kept {corner=polygon[i*len(polygon)/len(kept)]}
        polygon=kept
    }
    m:=len(polygon)
    if m<3 {return {},.Collinear}

    no_memory:runtime.Allocator_Error
    if hull,no_memory=hull_make(m,2,2*m,allocator);no_memory!=nil {return {},.Out_Of_Memory}
    front:=Vec3{f32(q.normal.x),f32(q.normal.y),f32(q.normal.z)}
    hull.planes[0]={front,-max(f32)}
    hull.planes[1]={-front,-max(f32)}
    for corner,i in polygon {
        p:=points[corner.index]
        hull.vertices[i]=p
        hull.sources[i]=corner.index
        hull.planes[0].d=max(hull.planes[0].d,plane_distance({front,0},p))
        hull.planes[1].d=max(hull.planes[1].d,plane_distance({-front,0},p))
    }
    // Edge k runs from corner k to k+1: half-edge 2k on the front face, its
    // twin 2k+1, from k+1 back to k, on the back one.
    for i in 0..<m {
        hull.face_vertices[i]=u32(i)
        hull.face_vertices[m+i]=u32(m-1-i)
        hull.half_edges[2*i]={origin=u32(i),face=0,next=u32(2*((i+1)%m))}
        hull.half_edges[2*i+1]={origin=u32((i+1)%m),face=1,next=u32(2*((i-1+m)%m)+1)}
    }
    hull.faces[0]={first_vertex=0,vertex_count=u32(m),first_edge=0}
    hull.faces[1]={first_vertex=u32(m),vertex_count=u32(m),first_edge=u32(2*(m-2)+1)}
    return hull,.None
}
