package mirai_physics

import cmath "core:math"

// Convex queries between two proxies: closest points (GJK), linear cast, penetration (EPA) and time of impact.
// Except time_of_impact, every routine works in the local frame of proxy A, with xf_b the pose of B in that frame.
// Normals are unit vectors from A to B. The simplex solver, the cast and the time of impact follow Box3D
// (distance.c, MIT, Erin Catto); the polytope expansion keeps the horizon by flood fill as Jolt does.

@(private) GJK_LINEAR_SLOP :: 0.005

@(private="file") GJK_MAX_ITERATIONS :: 32
// Both relative to the largest coordinate of the support points: the gain below which a support point adds
// nothing, and the distance below which the cores overlap, where the direction between them is noise.
@(private="file") GJK_EPSILON :: 1e-6
@(private="file") GJK_OVERLAP :: 1e-5
@(private="file") GJK_STALL :: 1e-6
@(private="file") CAST_MAX_ITERATIONS :: 32
@(private="file") CAST_TOLERANCE :: 1e-4
@(private="file") EPA_MAX_VERTICES :: 128
@(private="file") EPA_MAX_FACES :: 2*EPA_MAX_VERTICES-4
// Relative to the largest coordinate of the support points: convergence, visibility and flatness.
@(private="file") EPA_TOLERANCE :: 1e-5
@(private="file") EPA_NONE :: 0xff
@(private="file") TOI_MAX_ITERATIONS :: 25
@(private="file") TOI_MAX_ROOT_ITERATIONS :: 50
// Pairs of support points the time of impact tries beyond those of the point sets when a proxy has a disc,
// whose support point moves with the axis.
@(private="file") TOI_DISC_PAIRS :: 16

// Vertex pairs of the last simplex of a query, to warm start the next one. The zero value is a cold start.
Simplex_Cache :: struct {count:u8,index_a,index_b:[4]u8}

Gjk_Output :: struct {point_a,point_b,normal:Vec3,distance:f32,iterations:i32}
Cast_Output :: struct {point,normal:Vec3,fraction:f32,iterations:i32,hit:bool}
Penetration :: struct {point_a,point_b,normal:Vec3,depth:f32,ok:bool}
Toi_State :: enum u8 {Unknown,Failed,Overlapped,Hit,Separated}
Toi_Output :: struct {state:Toi_State,fraction:f32}

// w is a point of the Minkowski difference B-A, u its weight in the closest point.
@(private="file") Gjk_Vertex :: struct {w,wa,wb:Vec3,u:f32,ia,ib:u8}
@(private="file") Gjk_Simplex :: struct {v:[4]Gjk_Vertex,count:int}
@(private="file") Gjk_Closest :: struct {u:[4]f32,d2:f32}
@(private="file") Gjk_Run :: struct {simplex:Gjk_Simplex,normal:Vec3,extent:f32,iterations:i32,overlap:bool}

// pa and pb are support points of A and B in their own frames.
@(private="file")
gjk_vertex :: #force_inline proc "contextless" (r:Mat3,p:Vec3,ia,ib:int,pa,pb:Vec3) -> (v:Gjk_Vertex) #no_bounds_check {
    v.wa=pa
    v.wb=r*pb+p
    v.w=v.wb-v.wa
    v.ia,v.ib=u8(ia),u8(ib)
    return
}

@(private="file")
gjk_extent :: #force_inline proc "contextless" (wa,wb:Vec3) -> f32 {
    m:=vmax(vabs(wa),vabs(wb))
    return max(m.x,m.y,m.z)
}

// The three solvers give the point of a sub-simplex closest to the origin as weights of its vertices;
// a vertex left at zero is not part of the closest feature.
@(private="file")
gjk_segment :: proc "contextless" (p:^[4]Vec3,i,j:int) -> (r:Gjk_Closest) #no_bounds_check {
    a,b:=p[i],p[j]
    ab:=b-a
    u,v:=dot(b,ab),-dot(a,ab)
    if v<=0 {r.u[i]=1;r.d2=length2(a);return}
    if u<=0 {r.u[j]=1;r.d2=length2(b);return}
    s:=1/(u+v)
    r.u[i],r.u[j]=u*s,v*s
    r.d2=length2(a*r.u[i]+b*r.u[j])
    return
}

@(private="file")
gjk_triangle :: proc "contextless" (p:^[4]Vec3,i,j,k:int) -> (r:Gjk_Closest) #no_bounds_check {
    a,b,c:=p[i],p[j],p[k]
    ab,bc,ca:=b-a,c-b,a-c
    n:=cross(ab,bc)
    nn:=dot(n,n)
    wa,wb,wc:=dot(cross(b,bc),n),dot(cross(c,ca),n),dot(cross(a,ab),n)
    flat:=!(nn>1e-10*dot(ab,ab)*dot(ca,ca))
    if !flat && wa>0 && wb>0 && wc>0 {
        s:=1/(wa+wb+wc)
        r.u[i],r.u[j],r.u[k]=wa*s,wb*s,wc*s
        d:=dot(a,n)
        r.d2=d*d/nn
        return
    }
    r.d2=max(f32)
    if flat || wc<=0 {r=gjk_segment(p,i,j)}
    if flat || wa<=0 {if t:=gjk_segment(p,j,k);t.d2<r.d2 {r=t}}
    if flat || wb<=0 {if t:=gjk_segment(p,k,i);t.d2<r.d2 {r=t}}
    return
}

@(private="file")
gjk_tetrahedron :: proc "contextless" (p:^[4]Vec3) -> (r:Gjk_Closest,inside:bool) #no_bounds_check {
    a,b,c,d:=p[0],p[1],p[2],p[3]
    ab,ac,ad:=b-a,c-a,d-a
    volume:=dot(ab,cross(ac,ad))
    w:=[4]f32{dot(b,cross(c-b,d-b)),dot(a,cross(ad,ac)),dot(a,cross(ab,ad)),dot(a,cross(ac,ab))}
    if volume<0 {volume=-volume;w=-w}
    flat:=!(volume*volume>1e-10*dot(ab,ab)*dot(ac,ac)*dot(ad,ad))
    if !flat && w[0]>0 && w[1]>0 && w[2]>0 && w[3]>0 {
        r.u=w*(1/(w[0]+w[1]+w[2]+w[3]))
        return r,true
    }
    opposite:=[4][3]int{{1,2,3},{0,2,3},{0,1,3},{0,1,2}}
    r.d2=max(f32)
    for f,x in opposite {
        if flat || w[x]<=0 {if t:=gjk_triangle(p,f[0],f[1],f[2]);t.d2<r.d2 {r=t}}
    }
    return
}

// Reduces the simplex to the feature closest to the origin. inside: the tetrahedron contains the origin.
@(private="file")
gjk_solve :: proc "contextless" (s:^Gjk_Simplex) -> (d2:f32,inside:bool) #no_bounds_check {
    p:[4]Vec3
    for i in 0..<s.count {p[i]=s.v[i].w}
    c:Gjk_Closest
    switch s.count {
    case 1: c.u[0]=1;c.d2=length2(p[0])
    case 2: c=gjk_segment(&p,0,1)
    case 3: c=gjk_triangle(&p,0,1,2)
    case 4: c,inside=gjk_tetrahedron(&p)
    }
    count:=0
    for i in 0..<s.count {
        if c.u[i]>0 {
            s.v[count]=s.v[i]
            s.v[count].u=c.u[i]
            count+=1
        }
    }
    if count==0 {s.v[0].u=1;count=1}
    s.count=count
    return c.d2,inside
}

// Unnormalized direction from the simplex to the origin, perpendicular to the simplex.
@(private="file")
gjk_direction :: proc "contextless" (s:^Gjk_Simplex) -> Vec3 #no_bounds_check {
    a:=s.v[0].w
    if s.count==1 {return -a}
    ab:=s.v[1].w-a
    if s.count==2 {return cross(cross(ab,-a),ab)}
    n:=cross(ab,s.v[2].w-a)
    return dot(n,a)<0 ? n : -n
}

@(private="file")
gjk_witness :: proc "contextless" (s:^Gjk_Simplex) -> (pa,pb:Vec3) #no_bounds_check {
    for i in 0..<s.count {
        pa+=s.v[i].wa*s.v[i].u
        pb+=s.v[i].wb*s.v[i].u
    }
    return
}

@(private="file")
gjk_run :: proc "contextless" (a,b:Proxy,xf:Transform,cache:^Simplex_Cache) -> (g:Gjk_Run) #no_bounds_check {
    r:=q_matrix(xf.q)
    s:=&g.simplex
    // The support points of a disc are not points of the set: a disc starts cold.
    discs:=a.disc!=0 || b.disc!=0
    if cache!=nil && cache.count<=4 && !discs {
        for i in 0..<int(cache.count) {
            ia,ib:=int(cache.index_a[i]),int(cache.index_b[i])
            if ia>=len(a.points) || ib>=len(b.points) {s.count=0;break}
            s.v[i]=gjk_vertex(r,xf.p,ia,ib,a.points[ia],b.points[ib])
            s.count+=1
        }
    }
    if s.count==0 {
        s.v[0]=gjk_vertex(r,xf.p,0,0,a.points[0],b.points[0])
        s.count=1
    }
    for i in 0..<s.count {g.extent=max(g.extent,gjk_extent(s.v[i].wa,s.v[i].wb))}
    d2,inside:=gjk_solve(s)
    backup:Gjk_Simplex=---
    stalled:=false
    for {
        margin:=GJK_OVERLAP*g.extent
        if inside || d2<=margin*margin {g.overlap=true;break}
        direction:=gjk_direction(s)
        l2:=length2(direction)
        if !(l2>1e-36) {g.overlap=true;break}
        direction*=1/cmath.sqrt(l2)
        g.normal=-direction
        if stalled || g.iterations==GJK_MAX_ITERATIONS {break}
        g.iterations+=1
        ia,pa:=proxy_support_point(a,-direction)
        ib,pb:=proxy_support_point(b,direction*r)
        v:=gjk_vertex(r,xf.p,ia,ib,pa,pb)
        duplicate:=false
        for i in 0..<s.count {
            if discs ? s.v[i].wa==v.wa && s.v[i].wb==v.wb : int(s.v[i].ia)==ia && int(s.v[i].ib)==ib {duplicate=true}
        }
        if duplicate {break}
        g.extent=max(g.extent,gjk_extent(v.wa,v.wb))
        if dot(v.w-s.v[0].w,direction)<=GJK_EPSILON*g.extent {break}
        backup=s^
        s.v[s.count]=v
        s.count+=1
        next_d2,next_inside:=gjk_solve(s)
        if !next_inside && next_d2>=d2 {
            // The distance is at the limit of precision. A simplex that keeps it has the better witness points.
            if next_d2>d2*(1+GJK_STALL) {s^=backup;break}
            stalled=true
        }
        d2,inside=next_d2,next_inside
    }
    if g.overlap {g.normal={}}
    if cache!=nil {
        cache^={}
        cache.count=u8(s.count)
        for i in 0..<s.count {cache.index_a[i],cache.index_b[i]=s.v[i].ia,s.v[i].ib}
    }
    return
}

// Closest points between the proxies. With use_radii=false the radii are ignored: distance==0 and a zero normal
// mean the cores overlap, and point_a==point_b is a point of the overlap. With use_radii=true the points are on
// the inflated surfaces and distance is max(0,core distance-ra-rb); the normal stays valid while only the
// inflated shapes overlap. cache is read to warm start and written with the final simplex.
gjk_distance :: proc(a,b:Proxy,xf_b:Transform,cache:^Simplex_Cache=nil,use_radii:=false) -> (out:Gjk_Output) {
    g:=gjk_run(a,b,xf_b,cache)
    pa,pb:=gjk_witness(&g.simplex)
    out.iterations=g.iterations
    if g.overlap {
        out.point_a=(pa+pb)*0.5
        out.point_b=out.point_a
        return
    }
    out.point_a,out.point_b,out.normal=pa,pb,g.normal
    out.distance=length(pb-pa)
    if use_radii {
        out.distance=max(0,out.distance-a.radius-b.radius)
        out.point_a+=g.normal*a.radius
        out.point_b-=g.normal*b.radius
    }
    return
}

// B, radii included on both, translates by `translation` in A's frame without rotating. fraction in
// [0,max_fraction] is the first time of contact, point the contact on A. Shapes that overlap at the start hit
// at fraction 0 with a zero normal; shapes that start in touch hit at 0 only when they approach.
gjk_cast :: proc(a,b:Proxy,xf_b:Transform,translation:Vec3,max_fraction:f32=1) -> (out:Cast_Output) {
    radius:=a.radius+b.radius
    cache:Simplex_Cache
    xf:=xf_b
    fraction,gap:f32
    point,normal:Vec3
    for out.iterations<CAST_MAX_ITERATIONS {
        out.iterations+=1
        d:=gjk_distance(a,b,xf,&cache)
        gap=d.distance-radius
        if d.normal=={} || gap< -CAST_TOLERANCE {
            // Past the first step the advance is conservative: this is the contact, lost in rounding.
            if out.iterations>1 {return {point,normal,fraction,out.iterations,true}}
            if d.normal!={} {return {(d.point_a+d.point_b+d.normal*(a.radius-b.radius))*0.5,{},0,1,true}}
            touch:=epa_penetration(a,b,xf_b)
            if !touch.ok || touch.depth>CAST_TOLERANCE {return {d.point_a,{},0,1,true}}
            if dot(translation,touch.normal)>=0 {return}
            return {touch.point_a,touch.normal,0,1,true}
        }
        closing:=-dot(translation,d.normal)
        if closing<=0 {return}
        point,normal=d.point_a+d.normal*a.radius,d.normal
        if gap<=CAST_TOLERANCE {return {point,normal,fraction,out.iterations,true}}
        fraction+=gap/closing
        if fraction>max_fraction {return}
        xf.p=xf_b.p+translation*fraction
    }
    if gap<=GJK_LINEAR_SLOP {return {point,normal,fraction,out.iterations,true}}
    return
}

@(private="file") Epa_Vertex :: struct {w,wa,wb:Vec3,ia,ib:u8}
// Triangle of the polytope, counterclockwise seen from outside. adj[i] is the face across the edge v[i],v[i+1].
// key orders the faces: the squared distance from the origin, negative while the origin is in front of the plane.
@(private="file") Epa_Face :: struct {n:Vec3,offset,key:f32,v,adj:[3]u8,alive:bool}
@(private="file") Epa_Edge :: struct {a,b,outer:u8}
// bound is the smallest support distance found along a tested direction: moving B by -bound_normal*bound
// separates the cores, whatever the state of the polytope.
@(private="file") Epa :: struct {
    a,b:Proxy,
    r:Mat3,
    p:Vec3,
    verts:[EPA_MAX_VERTICES]Epa_Vertex,
    faces:[EPA_MAX_FACES]Epa_Face,
    free:[EPA_MAX_FACES]u8,
    vert_count,face_count,free_count:int,
    extent,tolerance:f32,
    bound_normal:Vec3,
    bound:f32,
    bound_tri:[3]u8,
    bound_face,bound_set,discs:bool,
}

@(private="file")
epa_support :: proc "contextless" (e:^Epa,direction:Vec3) -> Epa_Vertex {
    ia,pa:=proxy_support_point(e.a,-direction)
    ib,pb:=proxy_support_point(e.b,direction*e.r)
    wa,wb:=pa,e.r*pb+e.p
    e.extent=max(e.extent,gjk_extent(wa,wb))
    e.tolerance=EPA_TOLERANCE*e.extent
    return {wb-wa,wa,wb,u8(ia),u8(ib)}
}

@(private="file")
epa_bound :: proc "contextless" (e:^Epa,normal:Vec3,d:f32,tri:[3]u8,face:bool) {
    if e.bound_set && (d>e.bound || (!face && d==e.bound)) {return}
    e.bound_normal,e.bound,e.bound_tri,e.bound_face,e.bound_set=normal,d,tri,face,true
}

// Squared distance from a point to the affine hull of the vertices gathered so far (fewer than four).
@(private="file")
epa_spread :: proc "contextless" (e:^Epa,w:Vec3) -> f32 {
    r:=w-e.verts[0].w
    if e.vert_count==1 {return length2(r)}
    axis:=e.verts[1].w-e.verts[0].w
    if e.vert_count==2 {return length2(cross(r,axis))/length2(axis)}
    n:=cross(axis,e.verts[2].w-e.verts[0].w)
    d:=dot(r,n)
    return d*d/length2(n)
}

@(private="file")
epa_face_set :: proc "contextless" (e:^Epa,f:int,i,j,k:u8) -> bool {
    p:=[4]Vec3{e.verts[i].w,e.verts[j].w,e.verts[k].w,{}}
    ab,ac:=p[1]-p[0],p[2]-p[0]
    n:=cross(ab,ac)
    l2:=length2(n)
    if !(l2>1e-14*length2(ab)*length2(ac)) {return false}
    n*=1/cmath.sqrt(l2)
    offset:=dot(n,p[0])
    key:=-offset*offset
    if offset>=0 {key=gjk_triangle(&p,0,1,2).d2}
    e.faces[f]={n,offset,key,{i,j,k},{EPA_NONE,EPA_NONE,EPA_NONE},true}
    return true
}

// Replaces the faces that see vertex vi, starting from one that does, by a fan from their horizon to vi.
// false leaves the polytope unusable.
@(private="file")
epa_expand :: proc "contextless" (e:^Epa,start,vi:int) -> bool {
    w:=e.verts[vi].w
    horizon:[EPA_MAX_FACES]Epa_Edge=---
    stack:[EPA_MAX_FACES]u8=---
    fan:[EPA_MAX_VERTICES]u8=---
    horizon_count,stack_count:=0,1
    stack[0]=u8(start)
    e.faces[start].alive=false
    for stack_count>0 {
        stack_count-=1
        index:=stack[stack_count]
        f:=e.faces[index]
        e.free[e.free_count]=index
        e.free_count+=1
        for i in 0..<3 {
            g:=&e.faces[f.adj[i]]
            if !g.alive {continue}
            if dot(g.n,w)-g.offset>e.tolerance {
                g.alive=false
                stack[stack_count]=f.adj[i]
                stack_count+=1
            } else {
                if horizon_count==len(horizon) {return false}
                horizon[horizon_count]={f.v[i],f.v[(i+1)%3],f.adj[i]}
                horizon_count+=1
            }
        }
    }
    if horizon_count<3 {return false}
    for h in horizon[:horizon_count] {fan[h.a],fan[h.b]=EPA_NONE,EPA_NONE}
    for h in horizon[:horizon_count] {
        if fan[h.a]!=EPA_NONE {return false}
        f:=e.face_count
        if e.free_count>0 {
            e.free_count-=1
            f=int(e.free[e.free_count])
        } else if e.face_count<EPA_MAX_FACES {
            e.face_count+=1
        } else {
            return false
        }
        if !epa_face_set(e,f,h.a,h.b,u8(vi)) {return false}
        e.faces[f].adj[0]=h.outer
        outer:=&e.faces[h.outer]
        for k in 0..<3 {
            if outer.v[k]==h.b && outer.v[(k+1)%3]==h.a {outer.adj[k]=u8(f)}
        }
        fan[h.a]=u8(f)
    }
    for h in horizon[:horizon_count] {
        f,next:=fan[h.a],fan[h.b]
        if next==EPA_NONE {return false}
        e.faces[f].adj[1]=next
        e.faces[next].adj[2]=f
    }
    first:=fan[horizon[0].a]
    f,count:=e.faces[first].adj[1],1
    for f!=first && count<=horizon_count {
        f=e.faces[f].adj[1]
        count+=1
    }
    return count==horizon_count
}

@(private="file")
epa_solve :: proc "contextless" (e:^Epa,s:^Gjk_Simplex) {
    e.verts[0]={s.v[0].w,s.v[0].wa,s.v[0].wb,s.v[0].ia,s.v[0].ib}
    e.vert_count=1
    for i in 1..<s.count {
        if epa_spread(e,s.v[i].w)>e.tolerance*e.tolerance {
            e.verts[e.vert_count]={s.v[i].w,s.v[i].wa,s.v[i].wb,s.v[i].ia,s.v[i].ib}
            e.vert_count+=1
        }
    }
    // A tetrahedron needs four independent points: the missing ones are support points across the ones
    // at hand. When none stands out the difference is flat there and the tested directions already bound it.
    for e.vert_count<4 {
        directions:[6]Vec3
        count:=6
        w0:=e.verts[0].w
        switch e.vert_count {
        case 1: directions={{0,-1,0},{0,1,0},{-1,0,0},{1,0,0},{0,0,-1},{0,0,1}}
        case 2:
            axis:=normalize(e.verts[1].w-w0)
            u:=perp(axis)
            v:=cross(axis,u)
            directions,count={u,-u,v,-v,{},{}},4
        case 3:
            n:=normalize(cross(e.verts[1].w-w0,e.verts[2].w-w0))
            directions,count={n,-n,{},{},{},{}},2
        }
        grown:=false
        for direction in directions[:count] {
            if length2(direction)<0.5 {continue}
            v:=epa_support(e,direction)
            epa_bound(e,direction,dot(v.w,direction),{},false)
            if epa_spread(e,v.w)>e.tolerance*e.tolerance {
                e.verts[e.vert_count]=v
                e.vert_count+=1
                grown=true
                break
            }
        }
        if !grown {return}
    }
    v:=&e.verts
    if dot(v[1].w-v[0].w,cross(v[2].w-v[0].w,v[3].w-v[0].w))>0 {v[0],v[1]=v[1],v[0]}
    tetrahedron:=[4][3]u8{{0,1,2},{0,3,1},{1,3,2},{0,2,3}}
    links:=[4][3]u8{{1,2,3},{3,2,0},{1,3,0},{0,2,1}}
    for t,f in tetrahedron {
        if !epa_face_set(e,f,t[0],t[1],t[2]) {return}
        e.faces[f].adj=links[f]
    }
    e.face_count=4
    for {
        closest:=-1
        key:=max(f32)
        for i in 0..<e.face_count {
            if e.faces[i].alive && e.faces[i].key<key {closest,key=i,e.faces[i].key}
        }
        if closest<0 {return}
        face:=e.faces[closest]
        vertex:=epa_support(e,face.n)
        d:=dot(vertex.w,face.n)
        epa_bound(e,face.n,d,face.v,true)
        if d-face.offset<=e.tolerance || e.vert_count==EPA_MAX_VERTICES {return}
        for i in 0..<e.vert_count {
            if e.discs ? v[i].w==vertex.w : v[i].ia==vertex.ia && v[i].ib==vertex.ib {return}
        }
        v[e.vert_count]=vertex
        e.vert_count+=1
        if !epa_expand(e,closest,e.vert_count-1) {return}
    }
}

// Smallest translation that separates two overlapping shapes, radii included: moving B by normal*depth.
// point_a and point_b are the witness points on each inflated surface. Disjoint cores answer from their
// closest points, with depth=ra+rb-distance and ok=depth>0. Overlapping cores expand a polytope; when it
// runs out of capacity or precision the answer is the tightest direction tested, a valid translation that
// may not be the smallest. ok=false with overlapping cores means that no direction could be tested.
epa_penetration :: proc(a,b:Proxy,xf_b:Transform) -> (out:Penetration) {
    g:=gjk_run(a,b,xf_b,nil)
    pa,pb:=gjk_witness(&g.simplex)
    radius:=a.radius+b.radius
    if !g.overlap {
        out.normal=g.normal
        out.depth=radius-length(pb-pa)
        out.point_a=pa+g.normal*a.radius
        out.point_b=pb-g.normal*b.radius
        out.ok=out.depth>0
        return
    }
    e:Epa=---
    e.a,e.b,e.r,e.p=a,b,q_matrix(xf_b.q),xf_b.p
    e.vert_count,e.face_count,e.free_count=0,0,0
    e.extent,e.tolerance=g.extent,EPA_TOLERANCE*g.extent
    e.bound_set=false
    e.discs=a.disc!=0 || b.disc!=0
    epa_solve(&e,&g.simplex)
    pa=(pa+pb)*0.5
    pb=pa
    if !e.bound_set {
        out.point_a,out.point_b=pa,pb
        return
    }
    if e.bound_face {
        t:=e.bound_tri
        p:=[4]Vec3{e.verts[t[0]].w,e.verts[t[1]].w,e.verts[t[2]].w,{}}
        c:=gjk_triangle(&p,0,1,2)
        pa,pb={},{}
        for k in 0..<3 {
            pa+=e.verts[t[k]].wa*c.u[k]
            pb+=e.verts[t[k]].wb*c.u[k]
        }
    }
    out.normal=-e.bound_normal
    out.depth=max(e.bound,0)+radius
    out.point_a=pa+out.normal*a.radius
    out.point_b=pb-out.normal*b.radius
    out.ok=true
    return
}

@(private="file") Toi_Axis :: enum u8 {Fixed,Edges,Face_A,Face_B}
// Separation along an axis that follows the features found by GJK. w1,w2: the world axis (Fixed), the local
// edge directions of A and B (Edges), or the local normal and a local point of the face (Face_A, Face_B).
@(private="file") Toi_Function :: struct {a,b:Proxy,sweep_a,sweep_b:Sweep,w1,w2:Vec3,type:Toi_Axis}

@(private="file")
toi_edges :: proc "contextless" (f:^Toi_Function,xa,xb:Transform,a0,a1,b0,b1:Vec3,parallel:f32) {
    ea,eb:=normalize(a1-a0),normalize(b1-b0)
    axis:=cross(q_rotate(xa.q,ea),q_rotate(xb.q,eb))
    if length2(axis)<parallel*parallel {return}
    if dot(q_rotate(xb.q,b0)-q_rotate(xa.q,a0)+(xb.p-xa.p),axis)<0 {axis,eb=-axis,-eb}
    // Edges that end the sweep crossed the other way would flip the axis on the way.
    if dot(cross(q_rotate(f.sweep_a.q2,ea),q_rotate(f.sweep_b.q2,eb)),axis)<0 {
        f.w1=normalize(axis)
        return
    }
    f.type,f.w1,f.w2=.Edges,ea,eb
}

@(private="file")
toi_function_init :: proc "contextless" (f:^Toi_Function,cache:Simplex_Cache,normal:Vec3,t:f32) {
    f.type,f.w1,f.w2=.Fixed,normal,{}
    // The simplex of a disc names no features: its axis stays the normal.
    if f.a.disc!=0 || f.b.disc!=0 {return}
    xa,xb:=sweep_transform(f.sweep_a,t),sweep_transform(f.sweep_b,t)
    ia,ib:=cache.index_a,cache.index_b
    pa,pb:=f.a.points,f.b.points
    if cache.count==2 {
        if ia[0]!=ia[1] && ib[0]!=ib[1] {toi_edges(f,xa,xb,pa[ia[0]],pa[ia[1]],pb[ib[0]],pb[ib[1]],0.05)}
        return
    }
    if cache.count!=3 {return}
    if ia[0]!=ia[1] && ia[0]!=ia[2] && ia[1]!=ia[2] {
        n:=normalize(cross(pa[ia[1]]-pa[ia[0]],pa[ia[2]]-pa[ia[0]]))
        if n=={} {return}
        c:=(pa[ia[0]]+pa[ia[1]]+pa[ia[2]])*(1.0/3)
        if dot(q_rotate(xb.q,pb[ib[0]])-q_rotate(xa.q,c)+(xb.p-xa.p),q_rotate(xa.q,n))<0 {n=-n}
        f.type,f.w1,f.w2=.Face_A,n,c
        return
    }
    if ib[0]!=ib[1] && ib[0]!=ib[2] && ib[1]!=ib[2] {
        n:=normalize(cross(pb[ib[1]]-pb[ib[0]],pb[ib[2]]-pb[ib[0]]))
        if n=={} {return}
        c:=(pb[ib[0]]+pb[ib[1]]+pb[ib[2]])*(1.0/3)
        if dot(q_rotate(xa.q,pa[ia[0]])-q_rotate(xb.q,c)-(xb.p-xa.p),q_rotate(xb.q,n))<0 {n=-n}
        f.type,f.w1,f.w2=.Face_B,n,c
        return
    }
    a1:=ia[0]!=ia[1] ? ia[1] : ia[2]
    b1:=ib[0]!=ib[1] ? ib[1] : ib[2]
    if a1!=ia[0] && b1!=ib[0] {toi_edges(f,xa,xb,pa[ia[0]],pa[a1],pb[ib[0]],pb[b1],0.005)}
}

// Separation at time t between the support points pa and pb, local to A and B, along the axis; search first
// picks the deepest pair.
@(private="file")
toi_separation :: proc "contextless" (f:^Toi_Function,t:f32,pa,pb:^Vec3,search:bool) -> f32 {
    xa,xb:=sweep_transform(f.sweep_a,t),sweep_transform(f.sweep_b,t)
    dp:=xb.p-xa.p
    axis:=f.w1
    switch f.type {
    case .Fixed:
    case .Edges:
        axis=normalize(cross(q_rotate(xa.q,f.w1),q_rotate(xb.q,f.w2)))
    case .Face_A:
        axis=q_rotate(xa.q,f.w1)
        if search {_,pb^=proxy_support_point(f.b,q_inv_rotate(xb.q,-axis))}
        return dot(q_rotate(xb.q,pb^)-q_rotate(xa.q,f.w2)+dp,axis)
    case .Face_B:
        axis=q_rotate(xb.q,f.w1)
        if search {_,pa^=proxy_support_point(f.a,q_inv_rotate(xa.q,-axis))}
        return dot(q_rotate(xa.q,pa^)-q_rotate(xb.q,f.w2)-dp,axis)
    }
    if search {
        _,pa^=proxy_support_point(f.a,q_inv_rotate(xa.q,axis))
        _,pb^=proxy_support_point(f.b,q_inv_rotate(xb.q,-axis))
    }
    return dot(q_rotate(xb.q,pb^)-q_rotate(xa.q,pa^)+dp,axis)
}

// Conservative advancement with separation functions. The sweeps are in world space: the pose of a body at
// time t is sweep_transform(sweep,t). Hit: fraction is the first time in [0,max_fraction] at which the distance
// between the shapes, radii included, comes down to GJK_LINEAR_SLOP within a quarter of it. Separated: it stays
// above until max_fraction, which is the fraction. Overlapped: the shapes touch or overlap at the start,
// fraction 0. Failed: no convergence, fraction is the last time known to be clear.
time_of_impact :: proc(a,b:Proxy,sweep_a,sweep_b:Sweep,max_fraction:f32=1) -> Toi_Output {
    return toi_solve(a,b,sweep_a,sweep_b,max_fraction,GJK_LINEAR_SLOP)
}

@(private)
toi_solve :: proc(a,b:Proxy,sweep_a,sweep_b:Sweep,max_fraction,clearance:f32) -> Toi_Output {
    f:=Toi_Function{a=a,b=b,sweep_a=sweep_a,sweep_b=sweep_b}
    origin:=sweep_a.c1
    f.sweep_a.c1-=origin
    f.sweep_a.c2-=origin
    f.sweep_b.c1-=origin
    f.sweep_b.c2-=origin
    radius:=a.radius+b.radius
    target:=radius+clearance
    tolerance:f32=max(0.25*clearance,1e-6)
    cache:Simplex_Cache
    t1:f32
    for _ in 0..<TOI_MAX_ITERATIONS {
        xa,xb:=sweep_transform(f.sweep_a,t1),sweep_transform(f.sweep_b,t1)
        d:=gjk_distance(a,b,xf_inv_mul(xa,xb),&cache)
        if d.distance<=radius || clearance==0 && d.distance<=target+tolerance {
            return {t1==0?.Overlapped:.Hit,t1}
        }
        if d.distance<=target+tolerance {return {.Hit,t1}}
        toi_function_init(&f,cache,q_rotate(xa.q,d.normal),t1)
        // Pushes t2 back from the end of the sweep until no pair of vertices is deeper than the target there.
        t2:=max_fraction
        advanced:=false
        pairs:=len(a.points)+len(b.points)
        if a.disc!=0 || b.disc!=0 {pairs+=TOI_DISC_PAIRS}
        for _ in 0..<pairs {
            pa,pb:Vec3
            s2:=toi_separation(&f,t2,&pa,&pb,true)
            if s2>target+tolerance {return {.Separated,max_fraction}}
            if s2>=target-tolerance {
                t1=t2
                advanced=true
                break
            }
            s1:=toi_separation(&f,t1,&pa,&pb,false)
            if s1<target-tolerance {return {.Failed,t1}}
            if s1<=target+tolerance {return {.Hit,t1}}
            a1,a2:=t1,t2
            found:=false
            for root in 0..<TOI_MAX_ROOT_ITERATIONS {
                t:=0.5*(a1+a2)
                if root&1==1 {t=a1+(target-s1)*(a2-a1)/(s2-s1)}
                s:=toi_separation(&f,t,&pa,&pb,false)
                if abs(s-target)<=tolerance {
                    t2=t
                    found=true
                    break
                }
                if s>target {a1,s1=t,s} else {a2,s2=t,s}
            }
            if found {continue}
            if f.type!=.Edges {return {.Failed,t1}}
            // The cross product of the edges did not behave: freeze it as it is at t1.
            xa,xb=sweep_transform(f.sweep_a,t1),sweep_transform(f.sweep_b,t1)
            f.w1=normalize(cross(q_rotate(xa.q,f.w1),q_rotate(xb.q,f.w2)))
            f.type=.Fixed
            t2=max_fraction
        }
        if !advanced {return {.Failed,t1}}
    }
    return {.Failed,t1}
}
