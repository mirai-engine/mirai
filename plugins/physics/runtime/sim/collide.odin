package mirai_physics

import cmath "core:math"

LINEAR_SLOP :: 0.005
MANIFOLD_MAX_POINTS :: 4

// Contact point in the frame of shape A: midway between the two surfaces. Negative separation is penetration.
Local_Point :: struct {point:Vec3,separation:f32,id:u32}
// Normal from A to B.
Local_Manifold :: struct {normal:Vec3,count:i32,points:[MANIFOLD_MAX_POINTS]Local_Point}

@(private) ID_OWNER_B :: 0x8000
@(private) ID_EDGE_PAIR :: 0x4000

// Closest points of two segments, as parameters and positions.
@(private)
segment_closest :: proc "contextless" (p1,q1,p2,q2:Vec3) -> (s,t:f32,c1,c2:Vec3) #no_bounds_check {
    d1:=q1-p1;d2:=q2-p2;r:=p1-p2
    a:=dot(d1,d1);e:=dot(d2,d2);f:=dot(d2,r)
    EPSILON :: 1e-12
    if a<=EPSILON && e<=EPSILON {return 0,0,p1,p2}
    if a<=EPSILON {
        t=clamp(f/e,0,1)
    } else {
        c:=dot(d1,r)
        if e<=EPSILON {
            s=clamp(-c/a,0,1)
        } else {
            b:=dot(d1,d2)
            denominator:=a*e-b*b
            if denominator>1e-7*a*e {s=clamp((b*f-c*e)/denominator,0,1)}
            t=(b*s+f)/e
            if t<0 {
                t=0;s=clamp(-c/a,0,1)
            } else if t>1 {
                t=1;s=clamp((b-c)/a,0,1)
            }
        }
    }
    return s,t,p1+d1*s,p2+d2*t
}

@(private)
segment_closest_point :: #force_inline proc "contextless" (p,q,point:Vec3) -> Vec3 {
    d:=q-p
    l:=dot(d,d)
    if l<=1e-12 {return p}
    return p+d*clamp(dot(point-p,d)/l,0,1)
}

collide_spheres :: proc "contextless" (m:^Local_Manifold,center_a:Vec3,radius_a:f32,center_b:Vec3,radius_b:f32,speculative:f32) #no_bounds_check {
    m.count=0
    d:=center_b-center_a
    distance:=length(d)
    separation:=distance-radius_a-radius_b
    if separation>speculative {return}
    m.normal=distance>1e-6?d/distance:Vec3{0,1,0}
    m.points[0]={center_a+m.normal*(radius_a+0.5*separation),separation,0}
    m.count=1
}

collide_capsule_sphere :: proc "contextless" (m:^Local_Manifold,p,q:Vec3,radius_a:f32,center_b:Vec3,radius_b:f32,speculative:f32) {
    collide_spheres(m,segment_closest_point(p,q,center_b),radius_a,center_b,radius_b,speculative)
}

collide_capsules :: proc "contextless" (m:^Local_Manifold,p1,q1:Vec3,radius_a:f32,p2,q2:Vec3,radius_b:f32,speculative:f32) #no_bounds_check {
    m.count=0
    radius:=radius_a+radius_b
    _,_,c1,c2:=segment_closest(p1,q1,p2,q2)
    offset:=c2-c1
    distance:=length(offset)
    if distance>radius+speculative {return}
    axis_a,length_a:=normalize_length(q1-p1)
    axis_b,length_b:=normalize_length(q2-p2)
    // Nearly parallel capsules rest on two points: B clipped to the extent of A.
    if length_a>LINEAR_SLOP && length_b>LINEAR_SLOP && length2(cross(axis_a,axis_b))<0.05*0.05 {
        t1:=clamp(dot(p2-p1,axis_a),0,length_a)
        t2:=clamp(dot(q2-p1,axis_a),0,length_a)
        if abs(t2-t1)>LINEAR_SLOP {
            a1:=p1+axis_a*t1;a2:=p1+axis_a*t2
            b1:=segment_closest_point(p2,q2,a1);b2:=segment_closest_point(p2,q2,a2)
            n1,d1:=normalize_length(b1-a1)
            n2,d2:=normalize_length(b2-a2)
            if d1>1e-5 && d2>1e-5 && d1<=radius+speculative && d2<=radius+speculative {
                m.normal=normalize(n1+n2)
                if m.normal!={} {
                    m.points[0]={a1+m.normal*(radius_a+0.5*(d1-radius)),d1-radius,1}
                    m.points[1]={a2+m.normal*(radius_a+0.5*(d2-radius)),d2-radius,2}
                    m.count=2
                    return
                }
            }
        }
    }
    if distance<1e-6 {
        m.normal=normalize(cross(axis_a,axis_b))
        if m.normal=={} {m.normal=perp(axis_a=={}?Vec3{0,1,0}:axis_a)}
    } else {
        m.normal=offset/distance
    }
    separation:=distance-radius
    m.points[0]={c1+m.normal*(radius_a+0.5*separation),separation,0}
    m.count=1
}

@(private) Clip_Vertex :: struct {p:Vec3,separation:f32,tag_in,tag_out:u16}
@(private) CLIP_MAX :: 64

// Sutherland-Hodgman against one side plane of the reference face. Inlined: with the callers of the convex
// faces LLVM stopped inlining it into the clipping of boxes, which took 6 % longer.
@(private)
clip_polygon :: #force_inline proc "contextless" (out,polygon:[]Clip_Vertex,count:int,plane,reference:Plane,tag:u16) -> int #no_bounds_check {
    v1:=polygon[count-1]
    d1:=plane_distance(plane,v1.p)
    n:=0
    for i in 0..<count {
        v2:=polygon[i]
        d2:=plane_distance(plane,v2.p)
        if d1<=0 && d2<=0 {
            if n<CLIP_MAX {out[n]=v2;n+=1}
        } else if d1<=0 && d2>0 {
            p:=v1.p+(v2.p-v1.p)*(d1/(d1-d2))
            if n<CLIP_MAX {out[n]={p,plane_distance(reference,p),v2.tag_in,tag};n+=1}
        } else if d2<=0 && d1>0 {
            p:=v1.p+(v2.p-v1.p)*(d1/(d1-d2))
            if n<CLIP_MAX {out[n]={p,plane_distance(reference,p),tag,v1.tag_out};n+=1}
            if n<CLIP_MAX {out[n]=v2;n+=1}
        }
        v1=v2;d1=d2
    }
    return n
}

// Keeps up to four points that preserve the deepest point and the largest contact area. The 0.95 bias gives
// earlier candidates priority so that similar scores do not alternate between steps.
@(private)
manifold_reduce :: proc "contextless" (m:^Local_Manifold,points:[]Local_Point,count:int,speculative:f32) #no_bounds_check {
    count:=count
    m.count=0
    if count<=MANIFOLD_MAX_POINTS {
        for i in 0..<count {m.points[i]=points[i]}
        m.count=i32(count)
        return
    }
    BIAS :: 0.95
    normal:=m.normal
    tolerance:=speculative*speculative
    take :: proc "contextless" (m:^Local_Manifold,points:[]Local_Point,count:^int,index:int) -> Vec3 {
        m.points[m.count]=points[index]
        m.count+=1
        points[index]=points[count^-1]
        count^-=1
        return m.points[m.count-1].point
    }
    direction:=perp(normal)
    best:=-1
    best_score:=min(f32)
    for i in 0..<count {
        score:=-points[i].separation+dot(direction,points[i].point)
        if BIAS*score>best_score || best<0 {best=i;best_score=score}
    }
    a:=take(m,points,&count,best)
    best=-1;best_score=0
    for i in 0..<count {
        d:=points[i].point-a
        v:=d-normal*dot(d,normal)
        depth:=max(0,-points[i].separation)
        score:=length2(v)+4*depth*depth
        if BIAS*score>best_score {best=i;best_score=score}
    }
    if best<0 || best_score<tolerance {return}
    b:=take(m,points,&count,best)
    best=-1;best_score=tolerance
    best_area:f32
    for i in 0..<count {
        area:=dot(normal,cross(b-a,points[i].point-a))
        if BIAS*abs(area)>=best_score {best=i;best_score=abs(area);best_area=area}
    }
    if best<0 {return}
    c:=take(m,points,&count,best)
    sign:f32=best_area<0?-1:1
    best=-1;best_score=tolerance
    for i in 0..<count {
        p:=points[i].point
        u1:=sign*dot(normal,cross(p-a,b-a))
        u2:=sign*dot(normal,cross(p-b,c-b))
        u3:=sign*dot(normal,cross(p-c,a-c))
        score:=max(u1,u2,u3)
        if BIAS*score>best_score {best=i;best_score=score}
    }
    if best>=0 {take(m,points,&count,best)}
}

// Clips the face of `incident` most opposed to a reference face against the sides of that face.
// `xf` is the incident hull in the frame of the reference hull, where the result is expressed.
@(private)
hull_face_contact :: proc "contextless" (m:^Local_Manifold,reference,incident:^Hull,xf:Transform,face:int,speculative:f32) -> (deepest:f32,ok:bool) #no_bounds_check {
    m.count=0
    plane:=reference.planes[face]
    normal_in_incident:=q_inv_rotate(xf.q,plane.n)
    incident_face:=0
    lowest:=max(f32)
    for p,i in incident.planes {
        if d:=dot(p.n,normal_in_incident);d<lowest {lowest=d;incident_face=i}
    }
    buffer_a,buffer_b:[CLIP_MAX]Clip_Vertex=---,---
    input,output:=buffer_a[:],buffer_b[:]
    count:=0
    rotation:=q_matrix(xf.q)
    first:=incident.face_edges[incident_face]
    for edge:=first;count<CLIP_MAX; {
        next:=incident.edges[edge].next
        p:=rotation*incident.vertices[incident.edges[next].origin]+xf.p
        input[count]={p,plane_distance(plane,p),ID_OWNER_B|edge,ID_OWNER_B|next}
        count+=1
        edge=next
        if edge==first {break}
    }
    first=reference.face_edges[face]
    for edge:=first;true; {
        next:=reference.edges[edge].next
        v1:=reference.vertices[reference.edges[edge].origin]
        v2:=reference.vertices[reference.edges[next].origin]
        side:=cross(normalize(v2-v1),plane.n)
        count=clip_polygon(output,input,count,{side,dot(side,v1)},plane,edge)
        input,output=output,input
        if count<3 {return 0,false}
        edge=next
        if edge==first {break}
    }
    points:[CLIP_MAX]Local_Point=---
    kept:=0
    deepest=max(f32)
    for v in input[:count] {
        if v.separation>speculative {continue}
        points[kept]={v.p-plane.n*(0.5*v.separation),v.separation,u32(v.tag_in)<<16|u32(v.tag_out)}
        kept+=1
        deepest=min(deepest,v.separation)
    }
    if kept==0 {return 0,false}
    m.normal=plane.n
    manifold_reduce(m,points[:],kept,speculative)
    return deepest,m.count>0
}

// Expresses a manifold computed with B as the reference in the frame of A. Feature ids swap owners so a
// point keeps its id when the reference face changes side.
@(private)
manifold_flip :: proc "contextless" (m:^Local_Manifold,xf_b:Transform) #no_bounds_check {
    m.normal=-q_rotate(xf_b.q,m.normal)
    for &point in m.points[:m.count] {
        point.point=xf_point(xf_b,point.point)
        tag_in:=(point.id>>16)~ID_OWNER_B
        tag_out:=(point.id&0xffff)~ID_OWNER_B
        point.id=tag_out<<16|tag_in
    }
}

// Edge against edge: one point between the closest points of the two edges, if they cross within both.
@(private)
edge_contact :: proc "contextless" (m:^Local_Manifold,p1,d1,p2,d2,normal:Vec3,index_a,index_b:int) {
    r:=p1-p2
    aa:=dot(d1,d1);ee:=dot(d2,d2);bb:=dot(d1,d2);cc:=dot(d1,r);ff:=dot(d2,r)
    denominator:=aa*ee-bb*bb
    if denominator<=1e-12 {return}
    s:=(bb*ff-cc*ee)/denominator
    t:=(aa*ff-bb*cc)/denominator
    if s<0 || s>1 || t<0 || t>1 {return}
    c1:=p1+d1*s;c2:=p2+d2*t
    m.normal=normal
    m.points[0]={0.5*(c1+c2),dot(normal,c2-c1),u32(ID_EDGE_PAIR|index_a)<<16|u32(ID_OWNER_B|ID_EDGE_PAIR|index_b)}
    m.count=1
}

@(private) Sat_Axis :: struct {normal:Vec3,separation:f32,index_a,index_b:int}

// SAT between two convex polyhedra with face clipping, in the frame of A; `xf` is B in that frame. Returns the
// largest separation along the axes it tried, below the distance of the hulls; the axis of a cache that
// decides returns its separation.
collide_hulls :: proc "contextless" (m:^Local_Manifold,a,b:^Hull,xf:Transform,speculative:f32,cache:^Sat_Cache=nil) -> f32 #no_bounds_check {
    m.count=0
    if cache!=nil && sat_cache_try(m,a,b,xf,speculative,cache) {return cache.separation}
    scratch:Sat_Cache
    cache:=cache if cache!=nil else &scratch
    cache^={}
    vertices_b:[HULL_MAX_VERTICES]Vec3=---
    normals_b:[HULL_MAX_FACES]Vec3=---
    rotation:=q_matrix(xf.q)
    for v,i in b.vertices {vertices_b[i]=rotation*v+xf.p}
    for p,i in b.planes {normals_b[i]=rotation*p.n}

    face_a:=Sat_Axis{separation=min(f32)}
    for plane,i in a.planes {
        separation:=max(f32)
        for v in vertices_b[:len(b.vertices)] {separation=min(separation,dot(plane.n,v))}
        separation-=plane.d
        if separation>face_a.separation {
            face_a={plane.n,separation,i,0}
            if separation>speculative {cache^={separation,u16(i),0,.Face_A};return separation}
        }
    }
    face_b:=Sat_Axis{separation=min(f32)}
    for plane,i in b.planes {
        normal:=normals_b[i]
        separation:=max(f32)
        for v in a.vertices {separation=min(separation,dot(normal,v))}
        separation-=plane.d+dot(normal,xf.p)
        if separation>face_b.separation {
            face_b={normal,separation,0,i}
            if separation>speculative {cache^={separation,0,u16(i),.Face_B};return separation}
        }
    }
    edge:=Sat_Axis{separation=min(f32),index_a=-1}
    for i:=0;i<len(a.edges);i+=2 {
        e1,t1:=a.edges[i],a.edges[i+1]
        p1:=a.vertices[e1.origin]
        d1:=a.vertices[t1.origin]-p1
        u1,v1:=a.planes[e1.face].n,a.planes[t1.face].n
        for j:=0;j<len(b.edges);j+=2 {
            e2,t2:=b.edges[j],b.edges[j+1]
            p2:=vertices_b[e2.origin]
            d2:=vertices_b[t2.origin]-p2
            // The edges form a face of the Minkowski difference only if their arcs cross on the Gauss map.
            cba:=dot(normals_b[e2.face],d1);dba:=dot(normals_b[t2.face],d1)
            adc:=-dot(u1,d2);bdc:=-dot(v1,d2)
            if !(cba*dba<0 && adc*bdc<0 && cba*bdc>0) {continue}
            axis:=cross(d1,d2)
            l2:=length2(axis)
            PARALLEL :: 0.005
            if l2<PARALLEL*PARALLEL*length2(d1)*length2(d2) {continue}
            axis*=1/cmath.sqrt(l2)
            if dot(axis,p1-a.center)<0 {axis=-axis}
            separation:=dot(axis,p2-p1)
            if separation>edge.separation {
                edge={axis,separation,i,j}
                if separation>speculative {cache^={separation,u16(i),u16(j),.Edges};return separation}
            }
        }
    }

    largest:=max(face_a.separation,face_b.separation,edge.separation)
    deepest:f32
    touching:bool
    // A keeps the reference face unless B is clearly better: resting faces tie, and alternating would jitter.
    if face_a.separation+0.1*LINEAR_SLOP>=face_b.separation {
        deepest,touching=hull_face_contact(m,a,b,xf,face_a.index_a,speculative)
        if touching {cache^={deepest,u16(face_a.index_a),0,.Face_A}}
    } else {
        deepest,touching=hull_face_contact(m,b,a,xf_inv(xf),face_b.index_b,speculative)
        if touching {
            manifold_flip(m,xf)
            cache^={deepest,0,u16(face_b.index_b),.Face_B}
        }
    }
    if edge.index_a<0 || (touching && edge.separation<=deepest+LINEAR_SLOP) {return largest}
    cache^={edge.separation,u16(edge.index_a),u16(edge.index_b),.Edges}

    p1:=a.vertices[a.edges[edge.index_a].origin]
    p2:=vertices_b[b.edges[edge.index_b].origin]
    edge_contact(m,p1,a.vertices[a.edges[edge.index_a+1].origin]-p1,p2,vertices_b[b.edges[edge.index_b+1].origin]-p2,edge.normal,edge.index_a,edge.index_b)
    return largest
}

// Hull A against a sphere at `center` in the frame of A.
collide_hull_sphere :: proc(m:^Local_Manifold,hull:^Hull,center:Vec3,radius:f32,speculative:f32) #no_bounds_check {
    m.count=0
    points:=[1]Vec3{center}
    closest:=gjk_distance(hull_proxy(hull),{points[:],0,0},TRANSFORM_IDENTITY)
    if closest.distance>radius+speculative {return}
    if closest.distance>1e-5 {
        separation:=closest.distance-radius
        m.normal=closest.normal
        m.points[0]={closest.point_a+closest.normal*(0.5*separation),separation,0}
    } else {
        // The center is inside: push out through the nearest face.
        face:=0
        depth:=min(f32)
        for plane,i in hull.planes {
            if d:=plane_distance(plane,center);d>depth {depth=d;face=i}
        }
        separation:=depth-radius
        m.normal=hull.planes[face].n
        m.points[0]={center-m.normal*(depth-0.5*separation),separation,0}
    }
    m.count=1
}

// The part of segment pq above a face of the hull, cut by the side planes of the face.
@(private)
hull_clip_segment :: proc "contextless" (hull:^Hull,face:int,p,q:Vec3) -> (a,b:Vec3,ok:bool) #no_bounds_check {
    a,b=p,q
    normal:=hull.planes[face].n
    first:=hull.face_edges[face]
    for edge:=first;true; {
        next:=hull.edges[edge].next
        v1:=hull.vertices[hull.edges[edge].origin]
        side:=cross(normalize(hull.vertices[hull.edges[next].origin]-v1),normal)
        da:=dot(side,a-v1);db:=dot(side,b-v1)
        if da>0 && db>0 {return a,b,false}
        if da>0 {
            a+=(b-a)*(da/(da-db))
        } else if db>0 {
            b+=(a-b)*(db/(db-da))
        }
        edge=next
        if edge==first {break}
    }
    return a,b,length2(b-a)>LINEAR_SLOP*LINEAR_SLOP
}

@(private)
hull_capsule_face_contact :: proc "contextless" (m:^Local_Manifold,hull:^Hull,face:int,p,q:Vec3,radius,speculative:f32) -> bool #no_bounds_check {
    a,b,ok:=hull_clip_segment(hull,face,p,q)
    if !ok {return false}
    plane:=hull.planes[face]
    d1:=plane_distance(plane,a);d2:=plane_distance(plane,b)
    if d1>radius+speculative && d2>radius+speculative {return false}
    m.normal=plane.n
    m.points[0]={a-plane.n*(0.5*(radius+d1)),d1-radius,1}
    m.points[1]={b-plane.n*(0.5*(radius+d2)),d2-radius,2}
    m.count=2
    return true
}

// Hull A against a capsule with segment pq in the frame of A.
collide_hull_capsule :: proc(m:^Local_Manifold,hull:^Hull,p,q:Vec3,radius:f32,speculative:f32) #no_bounds_check {
    m.count=0
    points:=[2]Vec3{p,q}
    closest:=gjk_distance(hull_proxy(hull),{points[:],0,0},TRANSFORM_IDENTITY)
    if closest.distance>radius+speculative {return}
    if closest.distance>1e-5 {
        face:=0
        alignment:=min(f32)
        for plane,i in hull.planes {
            if d:=dot(plane.n,closest.normal);d>alignment {alignment=d;face=i}
        }
        // A capsule lying on a face rests on the two ends of its clipped axis.
        if alignment>0.998 && hull_capsule_face_contact(m,hull,face,p,q,radius,speculative) {return}
        separation:=closest.distance-radius
        m.normal=closest.normal
        m.points[0]={closest.point_a+closest.normal*(0.5*separation),separation,0}
        m.count=1
        return
    }
    // The axis crosses the hull: least penetration over the faces and over the edges against the axis.
    face:=0
    face_separation:=min(f32)
    for plane,i in hull.planes {
        if s:=min(plane_distance(plane,p),plane_distance(plane,q));s>face_separation {face_separation=s;face=i}
    }
    axis:=q-p
    edge:=-1
    edge_separation:=min(f32)
    edge_normal:Vec3
    for i:=0;i<len(hull.edges);i+=2 {
        e,t:=hull.edges[i],hull.edges[i+1]
        if dot(hull.planes[e.face].n,axis)*dot(hull.planes[t.face].n,axis)>=0 {continue}
        p1:=hull.vertices[e.origin]
        d1:=hull.vertices[t.origin]-p1
        normal:=cross(d1,axis)
        l2:=length2(normal)
        if l2<0.005*0.005*length2(d1)*length2(axis) {continue}
        normal*=1/cmath.sqrt(l2)
        if dot(normal,p1-hull.center)<0 {normal=-normal}
        if s:=dot(normal,p-p1);s>edge_separation {edge_separation=s;edge=i;edge_normal=normal}
    }
    touching:=hull_capsule_face_contact(m,hull,face,p,q,radius,speculative)
    if touching {face_separation=min(m.points[0].separation,m.points[1].separation)+radius}
    if edge<0 || (touching && edge_separation<=face_separation+LINEAR_SLOP) {
        if !touching {
            // Neither end is over the face: one point under the deepest end.
            deepest:=plane_distance(hull.planes[face],p)<plane_distance(hull.planes[face],q)?p:q
            m.normal=hull.planes[face].n
            m.points[0]={deepest-m.normal*(0.5*(radius+face_separation)),face_separation-radius,0}
            m.count=1
        }
        return
    }
    p1:=hull.vertices[hull.edges[edge].origin]
    _,_,c1,c2:=segment_closest(p1,hull.vertices[hull.edges[edge+1].origin],p,q)
    separation:=dot(edge_normal,c2-c1)-radius
    m.normal=edge_normal
    m.points[0]={0.5*(c1+c2-edge_normal*radius),separation,u32(ID_EDGE_PAIR|edge)}
    m.count=1
}

@(private)
box_edge_index :: proc "contextless" (v0,v1:int) -> int #no_bounds_check {
    for k:=0;k<24;k+=2 {
        a,b:=int(BOX_EDGES[k].origin),int(BOX_EDGES[k+1].origin)
        if (a==v0 && b==v1) || (a==v1 && b==v0) {return k}
    }
    return 0
}

// Two boxes: the fifteen axes of the separating axis test in closed form, then the clipping of hulls.
// `xf` is B in the frame of A. Returns the largest separation along the axes, below the distance of the boxes.
collide_boxes :: proc "contextless" (m:^Local_Manifold,half_a,half_b:Vec3,xf:Transform,speculative:f32) -> f32 #no_bounds_check {
    m.count=0
    r:=q_matrix(xf.q)
    t:=xf.p
    b:=[3]Vec3{{r[0,0],r[1,0],r[2,0]},{r[0,1],r[1,1],r[2,1]},{r[0,2],r[1,2],r[2,2]}}
    abs_b:=[3]Vec3{vabs(b[0]),vabs(b[1]),vabs(b[2])}
    face_a,face_b:=0,0
    separation_a,separation_b:=min(f32),min(f32)
    for i in 0..<3 {
        s:=abs(t[i])-(half_a[i]+half_b.x*abs_b[0][i]+half_b.y*abs_b[1][i]+half_b.z*abs_b[2][i])
        if s>speculative {return s}
        if s>separation_a {separation_a=s;face_a=2*i+(t[i]>0?1:0)}
    }
    for j in 0..<3 {
        d:=dot(t,b[j])
        s:=abs(d)-(half_b[j]+dot(half_a,abs_b[j]))
        if s>speculative {return s}
        if s>separation_b {separation_b=s;face_b=2*j+(d<0?1:0)}
    }
    edge_i,edge_j:=-1,-1
    separation_e:=min(f32)
    normal:Vec3
    for i in 0..<3 {
        axis:Vec3
        axis[i]=1
        for j in 0..<3 {
            n:=cross(axis,b[j])
            l2:=length2(n)
            if l2<0.005*0.005 {continue}
            n*=1/cmath.sqrt(l2)
            d:=dot(t,n)
            s:=abs(d)-dot(half_a,vabs(n))-(half_b.x*abs(dot(n,b[0]))+half_b.y*abs(dot(n,b[1]))+half_b.z*abs(dot(n,b[2])))
            if s>speculative {return s}
            if s>separation_e {separation_e=s;edge_i=i;edge_j=j;normal=d<0?-n:n}
        }
    }
    largest:=max(separation_a,separation_b,separation_e)
    storage_a,storage_b:Box_Hull=---,---
    hull_a:=box_hull(&storage_a,half_a)
    hull_b:=box_hull(&storage_b,half_b)
    deepest:f32
    touching:bool
    if separation_a+0.1*LINEAR_SLOP>=separation_b {
        deepest,touching=hull_face_contact(m,&hull_a,&hull_b,xf,face_a,speculative)
    } else {
        deepest,touching=hull_face_contact(m,&hull_b,&hull_a,xf_inv(xf),face_b,speculative)
        if touching {manifold_flip(m,xf)}
    }
    if edge_i<0 || (touching && separation_e<=deepest+LINEAR_SLOP) {return largest}
    // The edges that support each box along the axis: A toward the normal, B against it.
    vertex_a,vertex_b:=0,0
    p1,p2,d1:Vec3
    for k in 0..<3 {
        if k!=edge_i {
            if normal[k]>0 {vertex_a|=1<<uint(k);p1[k]=half_a[k]} else {p1[k]=-half_a[k]}
        }
        if k!=edge_j {
            if dot(normal,b[k])<0 {vertex_b|=1<<uint(k);p2[k]=half_b[k]} else {p2[k]=-half_b[k]}
        }
    }
    p1[edge_i]=-half_a[edge_i]
    d1[edge_i]=2*half_a[edge_i]
    p2[edge_j]=-half_b[edge_j]
    edge_contact(m,p1,d1,xf_point(xf,p2),b[edge_j]*(2*half_b[edge_j]),normal,
        box_edge_index(vertex_a,vertex_a|1<<uint(edge_i)),box_edge_index(vertex_b,vertex_b|1<<uint(edge_j)))
    return largest
}

// Point of triangle abc closest to p, by the regions of its vertices, edges and face.
@(private)
triangle_closest_point :: proc "contextless" (a,b,c,p:Vec3) -> Vec3 {
    ab,ac,ap:=b-a,c-a,p-a
    d1,d2:=dot(ab,ap),dot(ac,ap)
    if d1<=0 && d2<=0 {return a}
    bp:=p-b
    d3,d4:=dot(ab,bp),dot(ac,bp)
    if d3>=0 && d4<=d3 {return b}
    vc:=d1*d4-d3*d2
    if vc<=0 && d1>=0 && d3<=0 {return a+ab*(d1/(d1-d3))}
    cp:=p-c
    d5,d6:=dot(ab,cp),dot(ac,cp)
    if d6>=0 && d5<=d6 {return c}
    vb:=d5*d2-d1*d6
    if vb<=0 && d2>=0 && d6<=0 {return a+ac*(d2/(d2-d6))}
    va:=d3*d6-d5*d4
    if va<=0 && d4-d3>=0 && d5-d6>=0 {return b+(c-b)*((d4-d3)/((d4-d3)+(d5-d6)))}
    denominator:=1/(va+vb+vc)
    return a+ab*(vb*denominator)+ac*(vc*denominator)
}

// The axis that the last full search chose, tried first: true when it decides this step too, the hulls
// still apart along it or resting on its face within LINEAR_SLOP of the depth that search found. The
// depth is not updated on a hit, so a slow drift ends in a new search.
@(private)
sat_cache_try :: proc "contextless" (m:^Local_Manifold,a,b:^Hull,xf:Transform,speculative:f32,cache:^Sat_Cache) -> bool #no_bounds_check {
    switch cache.kind {
    case .None:
        return false
    case .Face_A:
        if int(cache.index_a)>=len(a.planes) {return false}
        plane:=a.planes[cache.index_a]
        support:=xf_point(xf,b.vertices[hull_support(b,q_inv_rotate(xf.q,-plane.n))])
        if plane_distance(plane,support)>speculative {return true}
        deepest,touching:=hull_face_contact(m,a,b,xf,int(cache.index_a),speculative)
        if touching && abs(deepest-cache.separation)<LINEAR_SLOP {return true}
    case .Face_B:
        if int(cache.index_b)>=len(b.planes) {return false}
        inverse:=xf_inv(xf)
        plane:=b.planes[cache.index_b]
        support:=xf_point(inverse,a.vertices[hull_support(a,q_rotate(xf.q,-plane.n))])
        if plane_distance(plane,support)>speculative {return true}
        deepest,touching:=hull_face_contact(m,b,a,inverse,int(cache.index_b),speculative)
        if touching && abs(deepest-cache.separation)<LINEAR_SLOP {
            manifold_flip(m,xf)
            return true
        }
    case .Edges:
        if int(cache.index_a)+1>=len(a.edges) || int(cache.index_b)+1>=len(b.edges) {return false}
        p1:=a.vertices[a.edges[cache.index_a].origin]
        d1:=a.vertices[a.edges[cache.index_a+1].origin]-p1
        d2:=q_rotate(xf.q,b.vertices[b.edges[cache.index_b+1].origin]-b.vertices[b.edges[cache.index_b].origin])
        axis:=cross(d1,d2)
        l2:=length2(axis)
        if l2<1e-12 {return false}
        axis*=1/cmath.sqrt(l2)
        if dot(axis,p1-a.center)<0 {axis=-axis}
        // The supports along the axis prove the hulls apart; the distance of the edges alone would not.
        far_a:=dot(axis,a.vertices[hull_support(a,axis)])
        near_b:=dot(axis,xf_point(xf,b.vertices[hull_support(b,q_inv_rotate(xf.q,-axis))]))
        if near_b-far_a>speculative {return true}
    }
    m.count=0
    return false
}

// Moves a manifold found between the cores of two shapes to their surfaces, rounded by ra and rb.
@(private)
manifold_inflate :: proc "contextless" (m:^Local_Manifold,ra,rb:f32) #no_bounds_check {
    for &point in m.points[:m.count] {
        point.separation-=ra+rb
        point.point+=m.normal*(0.5*(ra-rb))
    }
}

// Cylinder A, its core of radius r and half height h rounded by `round`, against a sphere at `center` in the
// frame of A.
collide_cylinder_sphere :: proc "contextless" (m:^Local_Manifold,r,h,round:f32,center:Vec3,radius:f32,speculative:f32) #no_bounds_check {
    m.count=0
    radial:=cmath.sqrt(center.x*center.x+center.z*center.z)
    if radial>r || abs(center.y)>h {
        closest:=Vec3{center.x,clamp(center.y,-h,h),center.z}
        if radial>r {closest.x,closest.z=center.x*(r/radial),center.z*(r/radial)}
        normal,distance:=normalize_length(center-closest)
        separation:=distance-round-radius
        if separation>speculative || normal=={} {return}
        m.normal=normal
        m.points[0]={closest+normal*(round+0.5*separation),separation,0}
    } else {
        // The center is inside the core: out through the nearest of the side and the caps.
        depth:=r-radial
        normal:=radial>1e-6?Vec3{center.x/radial,0,center.z/radial}:Vec3{1,0,0}
        if h-center.y<depth {depth,normal=h-center.y,{0,1,0}}
        if h+center.y<depth {depth,normal=h+center.y,{0,-1,0}}
        separation:=-depth-round-radius
        m.normal=normal
        m.points[0]={center+normal*(depth+round+0.5*separation),separation,0}
    }
    m.count=1
}

// GJK sees a sharp cylinder smaller by this much and inflated by it: contacts shallower than that need no EPA,
// and their normal is the one of the nearest features of the cores.
@(private) CONVEX_MARGIN :: 4*LINEAR_SLOP
// Points of the cap of a cylinder as a face.
@(private) CYLINDER_CAP_POINTS :: 8
// A cap tilted less than this, as the tangent of its angle to the normal, keeps its points where they are: a
// cylinder that stands keeps its feature ids from one step to the next.
@(private) CYLINDER_FLAT :: 0.05
// A capsule whose axis is this close to perpendicular to the normal, as a sine, rests along its segment.
@(private) CAPSULE_FLAT :: 0.05
// A face leaning more than this away from the normal, as the cosine between them, does not hold the others.
@(private) FACE_ALIGNMENT :: 0.1

// A convex shape as collide_convex sees it, in its own frame: its core and radius for GJK and the faces it
// can rest on. `hull` is the core of a box or hull; a capsule and a cylinder take their faces from the proxy,
// and so does a polygon of a mesh (type Mesh), whose plane is the first of `hull`.
@(private)
Convex :: struct {
    proxy:Proxy,
    hull:Hull,
    type:Shape_Type,
    margin:f32, // GJK sees the core smaller by this and inflated by it
}

// The Convex of a shape of type Capsule, Box, Hull or Cylinder; points, box and scaled hold what it points to.
@(private)
convex_of :: proc "contextless" (w:^World,shape:^Shape,points:^[8]Vec3,box:^Box_Hull,scaled:^Scaled_Hull) -> (c:Convex) #no_bounds_check {
    c.proxy=shape_proxy(w,shape,points,scaled)
    c.type=shape.type
    #partial switch shape.type {
    case .Box: c.hull=box_hull(box,shape.size-shape.radius)
    case .Hull: c.hull=shape_hull_of(w,shape,true,scaled)^
    case .Cylinder: c.margin=clamp(CONVEX_MARGIN-shape.radius,0,0.5*min(c.proxy.disc,c.proxy.points[1].y))
    }
    return
}

@(private)
convex_margined :: #force_inline proc "contextless" (c:^Convex,storage:^[2]Vec3) -> Proxy #no_bounds_check {
    if c.margin==0 {return c.proxy}
    storage[0]=c.proxy.points[0]+{0,c.margin,0}
    storage[1]=c.proxy.points[1]-{0,c.margin,0}
    return {storage[:],c.proxy.radius+c.margin,c.proxy.disc-c.margin}
}

// The face of a convex shape farthest along a direction, on its rounded surface, with its outward normal: a
// polygon, a segment or a point. Zero points when a face has more than fit.
@(private)
convex_face :: proc "contextless" (c:^Convex,direction:Vec3,out:^[CLIP_MAX]Vec3) -> (count:int,normal:Vec3) #no_bounds_check {
    radius:=c.proxy.radius
    #partial switch c.type {
    case .Capsule:
        p,q:=c.proxy.points[0],c.proxy.points[1]
        axis:=normalize(q-p)
        along:=dot(direction,axis)
        if abs(along)<CAPSULE_FLAT*length(direction) {
            side:=normalize(direction-axis*along)
            out[0],out[1]=p+side*radius,q+side*radius
            return 2,side
        }
        normal=normalize(direction)
        out[0]=(along>0?q:p)+normal*radius
        return 1,normal
    case .Cylinder:
        h,r:=c.proxy.points[1].y,c.proxy.disc
        lateral:=cmath.sqrt(direction.x*direction.x+direction.z*direction.z)
        if abs(direction.y)>=lateral {
            normal={0,direction.y>0?1:-1,0}
            u:=Vec3{1,0,0}
            // A tilted cap starts at the point it leans on, so that the deepest point is a point of the face.
            if lateral>CYLINDER_FLAT*abs(direction.y) {u={direction.x/lateral,0,direction.z/lateral}}
            v:=cross(normal,u)
            center:=normal*(h+radius)
            for k in 0..<CYLINDER_CAP_POINTS {
                angle:=2*PI*f32(k)/CYLINDER_CAP_POINTS
                out[k]=center+(u*cmath.cos(angle)+v*cmath.sin(angle))*r
            }
            return CYLINDER_CAP_POINTS,normal
        }
        normal={direction.x/lateral,0,direction.z/lateral}
        out[0],out[1]=normal*(r+radius)-{0,h,0},normal*(r+radius)+{0,h,0}
        return 2,normal
    case .Mesh:
        // A polygon of a mesh: its corners, facing the direction.
        normal=c.hull.planes[0].n
        if dot(normal,direction)<0 {normal=-normal}
        for p,i in c.proxy.points {out[i]=p}
        return len(c.proxy.points),normal
    case .Box,.Hull:
        face:=0
        best:=min(f32)
        for plane,i in c.hull.planes {
            if d:=dot(plane.n,direction);d>best {best,face=d,i}
        }
        return hull_face_points(&c.hull,face,radius,out),c.hull.planes[face].n
    }
    return
}

// How far a cylinder reaches from its center along a unit direction: its unit axis, half height, radius and
// convex radius.
@(private)
cylinder_reach :: #force_inline proc "contextless" (axis,direction:Vec3,h,r,round:f32) -> f32 {
    along:=abs(dot(axis,direction))
    return along*h+cmath.sqrt(max(1-along*along,0))*r+round
}

// Whether a cylinder A and a cylinder or capsule B, `xf` B in the frame of A, are apart by more than the
// speculative distance along the line of their centers or the axis of either.
@(private)
cylinder_apart :: proc "contextless" (a,b:^Convex,xf:Transform,speculative:f32) -> bool #no_bounds_check {
    up:=Vec3{0,1,0}
    axis:=q_rotate(xf.q,up)
    ha,ra,rounda:=a.proxy.points[1].y,a.proxy.disc,a.proxy.radius
    hb,rb,roundb:=b.proxy.points[1].y,b.proxy.disc,b.proxy.radius
    if line,distance:=normalize_length(xf.p);distance>0 && distance-cylinder_reach(up,line,ha,ra,rounda)-cylinder_reach(axis,line,hb,rb,roundb)>speculative {return true}
    if abs(xf.p.y)-ha-rounda-cylinder_reach(axis,up,hb,rb,roundb)>speculative {return true}
    return abs(dot(xf.p,axis))-hb-roundb-cylinder_reach(up,axis,ha,ra,rounda)>speculative
}

// Two cylinders by their caps: the cap of either that faces the other is the contact when it holds the
// nearest points of the other, as in a stack. decided=false otherwise, for GJK.
@(private)
cylinder_caps_contact :: proc "contextless" (m:^Local_Manifold,a,b:^Convex,xf:Transform,speculative:f32) -> (decided:bool) #no_bounds_check {
    m.count=0
    up:=Vec3{0,1,0}
    axis:=q_rotate(xf.q,up)
    ha,ra,rounda:=a.proxy.points[1].y,a.proxy.disc,a.proxy.radius
    hb,rb,roundb:=b.proxy.points[1].y,b.proxy.disc,b.proxy.radius
    along_b:=dot(xf.p,axis)
    separation_a:=abs(xf.p.y)-ha-rounda-cylinder_reach(axis,up,hb,rb,roundb)
    separation_b:=abs(along_b)-hb-roundb-cylinder_reach(up,axis,ha,ra,rounda)
    separation:=max(separation_a,separation_b)
    if separation>speculative {return true}
    // Deeper than the margin, or deeper than along the line of the centers, another axis may overlap less.
    line,distance:=normalize_length(xf.p)
    if separation< -CONVEX_MARGIN || distance>0 && separation<distance-cylinder_reach(up,line,ha,ra,rounda)-cylinder_reach(axis,line,hb,rb,roundb)-0.1*LINEAR_SLOP {return false}
    reference,incident:[CLIP_MAX]Vec3=---,---
    reference_count,incident_count:int
    outward,normal:Vec3
    if separation_a+0.1*LINEAR_SLOP>=separation_b {
        normal=xf.p.y>0?up:-up
        reference_count,outward=convex_face(a,normal,&reference)
        incident_count,_=convex_face(b,q_inv_rotate(xf.q,-normal),&incident)
        for &p in incident[:incident_count] {p=xf_point(xf,p)}
    } else {
        normal=along_b>0?axis:-axis
        reference_count,_=convex_face(b,q_inv_rotate(xf.q,-normal),&reference)
        for &p in reference[:reference_count] {p=xf_point(xf,p)}
        outward=-normal
        incident_count,_=convex_face(a,normal,&incident)
    }
    if reference_count<3 {return false}
    points:[CLIP_MAX]Local_Point=---
    kept:=faces_clip(points[:],reference[:reference_count],outward,incident[:incident_count],normal,separation_a+0.1*LINEAR_SLOP<separation_b,speculative)
    if kept==0 {return false}
    deepest:=max(f32)
    for point in points[:kept] {deepest=min(deepest,point.separation)}
    if deepest>separation+0.1*LINEAR_SLOP {return false}
    m.normal=normal
    manifold_reduce(m,points[:],kept,speculative)
    return true
}

// The corners of a face of a hull moved out along its normal by `offset`; zero when they do not fit.
@(private)
hull_face_points :: proc "contextless" (hull:^Hull,face:int,offset:f32,out:^[CLIP_MAX]Vec3) -> (count:int) #no_bounds_check {
    normal:=hull.planes[face].n
    first:=hull.face_edges[face]
    for edge:=first;true; {
        if count==CLIP_MAX {return 0}
        out[count]=hull.vertices[hull.edges[edge].origin]+normal*offset
        count+=1
        edge=hull.edges[edge].next
        if edge==first {break}
    }
    return
}

// A cylinder A against a box or hull B, by the faces of B: the one farthest from the cylinder separates them,
// or holds its lowest points and is the contact. decided=false when the nearest features are elsewhere (an
// edge of B, the rim or a cap of the cylinder), for GJK to find.
@(private)
cylinder_faces_contact :: proc "contextless" (m:^Local_Manifold,a,b:^Convex,xf:Transform,speculative:f32) -> (decided:bool) #no_bounds_check {
    m.count=0
    inverse:=xf_inv(xf)
    axis:=q_rotate(inverse.q,{0,1,0})
    h,r,round:=a.proxy.points[1].y,a.proxy.disc,a.proxy.radius+b.proxy.radius
    face:=-1
    separation:=min(f32)
    for plane,i in b.hull.planes {
        along:=abs(dot(axis,plane.n))
        reach:=along*h+cmath.sqrt(max(1-along*along,0))*r+round
        if s:=dot(plane.n,inverse.p)-plane.d-reach;s>separation {face,separation=i,s}
    }
    if face<0 {return false}
    if separation>speculative {return true}
    // Deeper than the margin another axis may overlap less: GJK and EPA decide.
    if separation< -CONVEX_MARGIN {return false}
    reference:[CLIP_MAX]Vec3=---
    count:=hull_face_points(&b.hull,face,b.proxy.radius,&reference)
    if count<3 {return false}
    for &p in reference[:count] {p=xf_point(xf,p)}
    outward:=q_rotate(xf.q,b.hull.planes[face].n)
    side:[CLIP_MAX]Vec3=---
    side_count,_:=convex_face(a,-outward,&side)
    points:[CLIP_MAX]Local_Point=---
    kept:=faces_clip(points[:],reference[:count],outward,side[:side_count],-outward,true,speculative)
    if kept==0 {return false}
    deepest:=max(f32)
    for point in points[:kept] {deepest=min(deepest,point.separation)}
    if deepest>separation+0.1*LINEAR_SLOP {return false}
    m.normal=-outward
    manifold_reduce(m,points[:],kept,speculative)
    return true
}

// Clips the incident face, a polygon, segment or point, against the sides of the reference polygon seen along
// the normal, and measures each point to the plane of the reference along it. `flipped`: the reference is on
// B and the incident on A. Writes the points within the speculative distance to `out`.
@(private)
faces_clip :: proc "contextless" (out:[]Local_Point,reference:[]Vec3,reference_normal:Vec3,incident:[]Vec3,normal:Vec3,flipped:bool,speculative:f32) -> int #no_bounds_check {
    owner:=u16(flipped?0:ID_OWNER_B)
    centroid:Vec3
    for p in reference {centroid+=p}
    centroid*=1/f32(len(reference))
    buffer_a,buffer_b:[CLIP_MAX]Clip_Vertex=---,---
    input,output:=buffer_a[:],buffer_b[:]
    count:=len(incident)
    for p,i in incident {input[i]={p,0,owner|u16(i),owner|u16((i+1)%count)}}
    unused:=Plane{}
    for v1,i in reference {
        v2:=reference[(i+1)%len(reference)]
        side:=cross(v2-v1,normal)
        if dot(side,centroid-v1)>0 {side=-side}
        plane:=Plane{side,dot(side,v1)}
        switch count {
        case 1:
            if plane_distance(plane,input[0].p)>0 {return 0}
        case 2:
            d1,d2:=plane_distance(plane,input[0].p),plane_distance(plane,input[1].p)
            if d1>0 && d2>0 {return 0}
            if d1>0 {
                input[0]={input[0].p+(input[1].p-input[0].p)*(d1/(d1-d2)),0,u16(i),input[0].tag_out}
            } else if d2>0 {
                input[1]={input[1].p+(input[0].p-input[1].p)*(d2/(d2-d1)),0,input[1].tag_in,u16(i)}
            }
        case:
            count=clip_polygon(output,input,count,plane,unused,u16(i))
            input,output=output,input
            if count==0 {return 0}
        }
    }
    across:=dot(reference_normal,normal)
    offset:=dot(reference_normal,reference[0])
    kept:=0
    for v in input[:count] {
        t:=(dot(reference_normal,v.p)-offset)/across
        separation:=flipped?-t:t
        if separation>speculative || kept==len(out) {continue}
        out[kept]={v.p-normal*(0.5*t),separation,u32(v.tag_in)<<16|u32(v.tag_out)}
        kept+=1
    }
    return kept
}

// Segment A against segment B along the normal: two points where they run side by side, else the closest pair.
@(private)
segments_contact :: proc "contextless" (out:[]Local_Point,a,b:[]Vec3,normal:Vec3,speculative:f32) -> int #no_bounds_check {
    axis_a,length_a:=normalize_length(a[1]-a[0])
    axis_b,length_b:=normalize_length(b[1]-b[0])
    if length_a>LINEAR_SLOP && length_b>LINEAR_SLOP && length2(cross(axis_a,axis_b))<CAPSULE_FLAT*CAPSULE_FLAT {
        t1:=clamp(dot(b[0]-a[0],axis_a),0,length_a)
        t2:=clamp(dot(b[1]-a[0],axis_a),0,length_a)
        if abs(t2-t1)>LINEAR_SLOP {
            kept:=0
            for t,i in ([2]f32{t1,t2}) {
                pa:=a[0]+axis_a*t
                pb:=segment_closest_point(b[0],b[1],pa)
                separation:=dot(pb-pa,normal)
                if separation>speculative {continue}
                out[kept]={0.5*(pa+pb),separation,u32(i+1)}
                kept+=1
            }
            return kept
        }
    }
    _,_,pa,pb:=segment_closest(a[0],a[1],b[0],b[1])
    separation:=dot(pb-pa,normal)
    if separation>speculative {return 0}
    out[0]={0.5*(pa+pb),separation,0}
    return 1
}

// Contact of two convex shapes in the frame of A, `xf` B in that frame. The normal comes from GJK between the
// cores, the points from clipping along it the faces of both shapes; when the faces do not hold each other,
// one point at the closest points. Cores that overlap go to EPA, or, without `epa`, return cores_overlap for
// the caller to decide.
@(private)
collide_convex :: proc(m:^Local_Manifold,a,b:^Convex,xf:Transform,speculative:f32,epa:bool) -> (touching,cores_overlap:bool) #no_bounds_check {
    m.count=0
    storage_a,storage_b:[2]Vec3=---,---
    pa,pb:=convex_margined(a,&storage_a),convex_margined(b,&storage_b)
    g:=gjk_distance(pa,pb,xf)
    normal:Vec3
    if g.normal!={} {
        // The sharp shapes reach past the margined ones by less than the margins.
        if g.distance-pa.radius-pb.radius>speculative+a.margin+b.margin {return}
        normal=g.normal
    } else {
        if !epa {return false,true}
        pen:=epa_penetration(pa,pb,xf)
        if !pen.ok {return}
        normal=pen.normal
    }
    face_a,face_b:[CLIP_MAX]Vec3=---,---
    count_a,normal_a:=convex_face(a,normal,&face_a)
    count_b,normal_b:=convex_face(b,q_inv_rotate(xf.q,-normal),&face_b)
    for &p in face_b[:count_b] {p=xf_point(xf,p)}
    normal_b=q_rotate(xf.q,normal_b)
    points:[CLIP_MAX]Local_Point=---
    kept:=0
    align_a,align_b:=dot(normal_a,normal),-dot(normal_b,normal)
    if count_a>=3 && align_a>FACE_ALIGNMENT && (count_b<3 || align_a+0.1*LINEAR_SLOP>=align_b) {
        kept=faces_clip(points[:],face_a[:count_a],normal_a,face_b[:count_b],normal,false,speculative)
    } else if count_b>=3 && align_b>FACE_ALIGNMENT {
        kept=faces_clip(points[:],face_b[:count_b],normal_b,face_a[:count_a],normal,true,speculative)
    } else if count_a==2 && count_b==2 {
        kept=segments_contact(points[:],face_a[:2],face_b[:2],normal,speculative)
    }
    if kept>0 {
        m.normal=normal
        manifold_reduce(m,points[:],kept,speculative)
        return m.count>0,false
    }
    // One point between the closest points, of the margined shapes while their cores are apart: away from a
    // sharp rim they are the shapes.
    if g.normal!={} {
        separation:=g.distance-pa.radius-pb.radius
        if separation>speculative {return}
        m.normal=g.normal
        m.points[0]={g.point_a+g.normal*(pa.radius+0.5*separation),separation,0}
    } else {
        pen:=epa_penetration(pa,pb,xf)
        if !pen.ok {return}
        m.normal=pen.normal
        m.points[0]={0.5*(pen.point_a+pen.point_b),-pen.depth,0}
    }
    m.count=1
    return true,false
}

// A box or hull A against a sphere, capsule, box or hull B, `xf` B in the frame of A, one of them rounded:
// the routine of the pair between their cores, with the speculative distance grown by the radii, inflated
// back; GJK where the SAT does not decide.
@(private)
collide_rounded :: proc(w:^World,m:^Local_Manifold,a,b:^Shape,xf:Transform,speculative:f32,sat:^Sat_Cache) #no_bounds_check {
    ra,rb:=a.radius,b.radius
    spec:=speculative+ra+rb
    storage_a,storage_b:Box_Hull=---,---
    scaled_a,scaled_b:Scaled_Hull=---,---
    hull_a:=a.type==.Box?box_hull(&storage_a,a.size-ra):shape_hull_of(w,a,true,&scaled_a)^
    #partial switch b.type {
    case .Sphere:
        collide_hull_sphere(m,&hull_a,xf.p,b.size.x,spec)
    case .Capsule:
        axis:=q_rotate(xf.q,{0,b.size.y,0})
        collide_hull_capsule(m,&hull_a,xf.p-axis,xf.p+axis,b.size.x,spec)
    case .Box,.Hull:
        separation:f32
        if a.type==.Box && b.type==.Box {
            separation=collide_boxes(m,a.size-ra,b.size-rb,xf,spec)
        } else {
            hull_b:=b.type==.Box?box_hull(&storage_b,b.size-rb):shape_hull_of(w,b,true,&scaled_b)^
            separation=collide_hulls(m,&hull_a,&hull_b,xf,spec,sat)
        }
        if !sat_decides(m,separation,spec) {
            // The cores are apart and their nearest features are off the axes of the SAT: GJK.
            points_a,points_b:[8]Vec3=---,---
            convex_a,convex_b:=convex_of(w,a,&points_a,&storage_a,&scaled_a),convex_of(w,b,&points_b,&storage_b,&scaled_b)
            cores:=m^
            if _,overlap:=collide_convex(m,&convex_a,&convex_b,xf,speculative,false);!overlap {return}
            m^=cores
        }
    }
    manifold_inflate(m,ra,rb)
}

// A cylinder A against a sphere, capsule, box, hull or cylinder B, `xf` B in the frame of A.
@(private)
collide_cylinder :: proc(w:^World,m:^Local_Manifold,a,b:^Shape,xf:Transform,speculative:f32) #no_bounds_check {
    if b.type==.Sphere {
        collide_cylinder_sphere(m,a.size.x-a.radius,a.size.y-a.radius,a.radius,xf.p,b.size.x,speculative)
        return
    }
    points_a,points_b:[8]Vec3=---,---
    storage_b:Box_Hull=---
    scaled_b:Scaled_Hull=---
    convex_a,convex_b:=convex_of(w,a,&points_a,nil,nil),convex_of(w,b,&points_b,&storage_b,&scaled_b)
    if b.type>=.Box && cylinder_faces_contact(m,&convex_a,&convex_b,xf,speculative) {return}
    if (b.type==.Cylinder || b.type==.Capsule) && cylinder_apart(&convex_a,&convex_b,xf,speculative) {return}
    if b.type==.Cylinder && cylinder_caps_contact(m,&convex_a,&convex_b,xf,speculative) {return}
    collide_convex(m,&convex_a,&convex_b,xf,speculative,true)
}

// Whether the SAT between the cores of two rounded shapes is their contact: the cores overlap, or its points
// are as far as its separation, or it found them farther apart than the speculative distance. Otherwise
// their nearest features are not on its axes (two corners, or two parallel edges) and GJK finds the normal.
@(private)
sat_decides :: proc "contextless" (m:^Local_Manifold,separation,speculative:f32) -> bool #no_bounds_check {
    if m.count==0 {return separation>speculative}
    deepest:=max(f32)
    for point in m.points[:m.count] {deepest=min(deepest,point.separation)}
    return deepest<=0 || deepest<=separation+0.1*LINEAR_SLOP
}
