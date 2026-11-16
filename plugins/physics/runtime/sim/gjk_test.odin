package mirai_physics

import "core:log"
import cmath "core:math"
import "core:testing"
import "core:time"

@(private="file") GJK_BENCH :: #config(GJK_BENCH,false)
@(private="file") GT_MAX_POINTS :: 16

@(private="file") Gt_Rng :: struct {state:u64}
@(private="file") Gt_Shape :: struct {points:[GT_MAX_POINTS]Vec3,count:int,radius:f32}
@(private="file") Gt_D3 :: [3]f64
// Points of a shape in the frame of the query, in double precision for the brute-force references.
@(private="file") Gt_Points :: struct {p:[GT_MAX_POINTS]Gt_D3,count:int}
@(private="file") Gt_Stats :: struct {cases,failures:int,worst:f64}

@(private="file")
gt_next :: proc(r:^Gt_Rng) -> u64 {
    x:=r.state
    x~=x>>12
    x~=x<<25
    x~=x>>27
    r.state=x
    return x*0x2545F4914F6CDD1D
}
@(private="file") gt_range :: proc(r:^Gt_Rng,lo,hi:f32) -> f32 {return lo+(hi-lo)*f32(gt_next(r)>>40)/f32(1<<24)}
@(private="file") gt_vec :: proc(r:^Gt_Rng,h:f32) -> Vec3 {return {gt_range(r,-h,h),gt_range(r,-h,h),gt_range(r,-h,h)}}
@(private="file")
gt_dir :: proc(r:^Gt_Rng) -> Vec3 {
    for {
        v:=gt_vec(r,1)
        if l:=length2(v);l>0.01 && l<=1 {return normalize(v)}
    }
}
@(private="file") gt_rotation :: proc(r:^Gt_Rng) -> Quat {return q_axis_angle(gt_dir(r),gt_range(r,-PI,PI))}
@(private="file") gt_pose :: proc(r:^Gt_Rng,h:f32) -> Transform {return {gt_vec(r,h),gt_rotation(r)}}

@(private="file") gt_proxy :: proc(s:^Gt_Shape) -> Proxy {return {s.points[:s.count],s.radius,0}}
@(private="file")
gt_sphere :: proc(radius:f32,center:Vec3={}) -> (s:Gt_Shape) {
    s.points[0]=center
    s.count,s.radius=1,radius
    return
}
@(private="file")
gt_capsule :: proc(a,b:Vec3,radius:f32) -> (s:Gt_Shape) {
    s.points[0],s.points[1]=a,b
    s.count,s.radius=2,radius
    return
}
@(private="file")
gt_box :: proc(h:Vec3,radius:f32=0) -> (s:Gt_Shape) {
    for i in 0..<8 {s.points[i]={i&1==0 ? -h.x : h.x,i&2==0 ? -h.y : h.y,i&4==0 ? -h.z : h.z}}
    s.count,s.radius=8,radius
    return
}
@(private="file")
gt_tetrahedron :: proc() -> (s:Gt_Shape) {
    s.points[0],s.points[1],s.points[2],s.points[3]={1,1,1},{1,-1,-1},{-1,1,-1},{-1,-1,1}
    s.count=4
    return
}
@(private="file")
gt_triangle :: proc(a,b,c:Vec3) -> (s:Gt_Shape) {
    s.points[0],s.points[1],s.points[2]=a,b,c
    s.count=3
    return
}
@(private="file")
gt_cloud :: proc(r:^Gt_Rng,count:int,h:f32,radius:f32=0) -> (s:Gt_Shape) {
    for i in 0..<count {s.points[i]=gt_vec(r,h)}
    s.count,s.radius=count,radius
    return
}
@(private="file")
gt_random_box :: proc(r:^Gt_Rng) -> Gt_Shape {
    return gt_box({gt_range(r,0.2,1.5),gt_range(r,0.2,1.5),gt_range(r,0.2,1.5)})
}
@(private="file")
gt_random_shape :: proc(r:^Gt_Rng) -> Gt_Shape {
    switch gt_next(r)%6 {
    case 0: return gt_sphere(gt_range(r,0.1,1))
    case 1:
        h:=gt_range(r,0.2,1.5)
        return gt_capsule({-h,0,0},{h,0,0},gt_range(r,0.1,0.6))
    case 2: return gt_random_box(r)
    case 3:
        s:=gt_random_box(r)
        s.radius=gt_range(r,0.02,0.3)
        return s
    case 4: return gt_cloud(r,3,1.5)
    }
    return gt_cloud(r,4+int(gt_next(r)%4),1.2)
}

@(private="file") gt_d3 :: proc(v:Vec3) -> Gt_D3 {return {f64(v.x),f64(v.y),f64(v.z)}}
@(private="file") gt_dot :: proc(a,b:Gt_D3) -> f64 {return a.x*b.x+a.y*b.y+a.z*b.z}
@(private="file") gt_cross :: proc(a,b:Gt_D3) -> Gt_D3 {return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}}
@(private="file")
gt_points :: proc(s:^Gt_Shape,xf:Transform) -> (r:Gt_Points) {
    u:=Gt_D3{f64(xf.q.x),f64(xf.q.y),f64(xf.q.z)}
    for i in 0..<s.count {
        v:=gt_d3(s.points[i])
        c:=2*gt_cross(u,v)
        r.p[i]=v+f64(xf.q.w)*c+gt_cross(u,c)+gt_d3(xf.p)
    }
    r.count=s.count
    return
}

@(private="file")
gt_segments_distance2 :: proc(p1,q1,p2,q2:Gt_D3) -> f64 {
    d1,d2,r:=q1-p1,q2-p2,p1-p2
    a,e,f:=gt_dot(d1,d1),gt_dot(d2,d2),gt_dot(d2,r)
    s,t:f64
    if a<=1e-24 && e<=1e-24 {
    } else if a<=1e-24 {
        t=clamp(f/e,0,1)
    } else {
        c:=gt_dot(d1,r)
        if e<=1e-24 {
            s=clamp(-c/a,0,1)
        } else {
            b:=gt_dot(d1,d2)
            denom:=a*e-b*b
            if denom>1e-24 {s=clamp((b*f-c*e)/denom,0,1)}
            t=(b*s+f)/e
            if t<0 {
                t=0
                s=clamp(-c/a,0,1)
            } else if t>1 {
                t=1
                s=clamp((b-c)/a,0,1)
            }
        }
    }
    c:=(p1+d1*s)-(p2+d2*t)
    return gt_dot(c,c)
}

@(private="file")
gt_triangle_distance2 :: proc(p,a,b,c:Gt_D3) -> f64 {
    ab,ac,ap:=b-a,c-a,p-a
    n:=gt_cross(ab,ac)
    if gt_dot(n,n)<=1e-24 {return max(f64)}
    q:Gt_D3
    d1,d2:=gt_dot(ab,ap),gt_dot(ac,ap)
    bp:=p-b
    d3,d4:=gt_dot(ab,bp),gt_dot(ac,bp)
    cp:=p-c
    d5,d6:=gt_dot(ab,cp),gt_dot(ac,cp)
    vc,vb,va:=d1*d4-d3*d2,d5*d2-d1*d6,d3*d6-d5*d4
    switch {
    case d1<=0 && d2<=0: q=a
    case d3>=0 && d4<=d3: q=b
    case vc<=0 && d1>=0 && d3<=0: q=a+ab*(d1/(d1-d3))
    case d6>=0 && d5<=d6: q=c
    case vb<=0 && d2>=0 && d6<=0: q=a+ac*(d2/(d2-d6))
    case va<=0 && d4-d3>=0 && d5-d6>=0: q=b+(c-b)*((d4-d3)/((d4-d3)+(d5-d6)))
    case:
        denom:=1/(va+vb+vc)
        q=a+ab*(vb*denom)+ac*(vc*denom)
    }
    return gt_dot(p-q,p-q)
}

// Distance between the hulls of two point sets that do not overlap: the smallest over every pair of segments
// and every point against every triangle, which cover the faces and edges of both hulls.
@(private="file")
gt_reference_distance :: proc(a,b:^Gt_Points) -> f64 {
    best:=max(f64)
    for i in 0..<a.count {
        for j in i..<a.count {
            if i==j && a.count>1 {continue}
            for k in 0..<b.count {
                for l in k..<b.count {
                    if k==l && b.count>1 {continue}
                    best=min(best,gt_segments_distance2(a.p[i],a.p[j],b.p[k],b.p[l]))
                }
            }
        }
    }
    sets:=[2]^Gt_Points{a,b}
    for side in 0..<2 {
        points,hull:=sets[side],sets[1-side]
        for i in 0..<hull.count {
            for j in i+1..<hull.count {
                for k in j+1..<hull.count {
                    for p in 0..<points.count {
                        best=min(best,gt_triangle_distance2(points.p[p],hull.p[i],hull.p[j],hull.p[k]))
                    }
                }
            }
        }
    }
    return cmath.sqrt(best)
}

// Overlap of the two point sets along a unit direction: how far B has to move along it to separate.
@(private="file")
gt_overlap_along :: proc(a,b:^Gt_Points,n:Gt_D3) -> f64 {
    high,low:=-max(f64),max(f64)
    for i in 0..<a.count {high=max(high,gt_dot(a.p[i],n))}
    for i in 0..<b.count {low=min(low,gt_dot(b.p[i],n))}
    return high-low
}

// Smallest overlap over every direction that can be a face of the Minkowski difference: the normals of
// the triangles of each set and the cross products of their segments. Positive: the hulls overlap and this
// is the penetration depth. Negative: they are disjoint. found is false when no such direction exists.
@(private="file")
gt_reference_overlap :: proc(a,b:^Gt_Points) -> (depth:f64,found:bool) {
    depth=max(f64)
    axis :: proc(a,b:^Gt_Points,n:Gt_D3,depth:^f64,found:^bool) {
        l2:=gt_dot(n,n)
        if l2<=1e-16 {return}
        u:=n*(1/cmath.sqrt(l2))
        depth^=min(depth^,gt_overlap_along(a,b,u),gt_overlap_along(a,b,-u))
        found^=true
    }
    sets:=[2]^Gt_Points{a,b}
    for s in sets {
        for i in 0..<s.count {
            for j in i+1..<s.count {
                for k in j+1..<s.count {axis(a,b,gt_cross(s.p[j]-s.p[i],s.p[k]-s.p[i]),&depth,&found)}
            }
        }
    }
    for i in 0..<a.count {
        for j in i+1..<a.count {
            for k in 0..<b.count {
                for l in k+1..<b.count {axis(a,b,gt_cross(a.p[j]-a.p[i],b.p[l]-b.p[k]),&depth,&found)}
            }
        }
    }
    return
}

@(private="file")
gt_near :: proc(t:^testing.T,value,expected,tolerance:f32,loc:=#caller_location) {
    testing.expectf(t,abs(value-expected)<=tolerance,"%v is not %v within %v",value,expected,tolerance,loc=loc)
}
@(private="file")
gt_near3 :: proc(t:^testing.T,value,expected:Vec3,tolerance:f32,loc:=#caller_location) {
    testing.expectf(t,length(value-expected)<=tolerance,"%v is not %v within %v",value,expected,tolerance,loc=loc)
}
@(private="file")
gt_finite :: proc(o:Gjk_Output) -> bool {
    return finite(o.point_a) && finite(o.point_b) && finite(o.normal) && o.distance-o.distance==0
}
@(private="file")
gt_report :: proc(t:^testing.T,s:Gt_Stats,loc:=#caller_location) {
    testing.expectf(t,s.failures==0,"%v of %v cases failed, worst error %v",s.failures,s.cases,s.worst,loc=loc)
}
@(private="file")
gt_fail :: proc(s:^Gt_Stats,error:f64,tolerance:f64) {
    s.worst=max(s.worst,error)
    if !(error<=tolerance) {s.failures+=1}
}

// Checks one closest-point query against the references: the distance, the unit normal, the witness points
// lying a distance apart along the normal and each on the supporting plane of its own shape.
@(private="file")
gt_check_distance :: proc(a,b:^Gt_Shape,xf:Transform,s:^Gt_Stats,tolerance:f64) {
    pa,pb:=gt_points(a,TRANSFORM_IDENTITY),gt_points(b,xf)
    depth,found:=gt_reference_overlap(&pa,&pb)
    out:=gjk_distance(gt_proxy(a),gt_proxy(b),xf)
    s.cases+=1
    if !gt_finite(out) {
        s.failures+=1
        return
    }
    if found && abs(depth)<1e-4 {return}
    if found && depth>0 {
        if out.distance!=0 || out.normal!={} || out.point_a!=out.point_b {s.failures+=1}
        return
    }
    reference:=gt_reference_distance(&pa,&pb)
    if reference<1e-4 {return}
    n:=gt_d3(out.normal)
    before:=s.failures
    defer if s.failures!=before {
        log.infof("DBG case %v: a=%v r=%v b=%v r=%v xf=%v out=%v ref=%v depth=%v found=%v high-low=%v",s.cases,a.points[:a.count],a.radius,b.points[:b.count],b.radius,xf,out,reference,depth,found,gt_overlap_along(&pa,&pb,gt_d3(out.normal)))
    }
    gt_fail(s,abs(f64(out.distance)-reference),tolerance)
    gt_fail(s,abs(f64(length(out.normal))-1),1e-5)
    gt_fail(s,f64(length(out.point_b-out.point_a-out.normal*out.distance)),tolerance)
    gt_fail(s,abs(gt_dot(gt_d3(out.point_b)-gt_d3(out.point_a),n)+gt_overlap_along(&pa,&pb,n)),tolerance)
    high,low:=-max(f64),max(f64)
    for i in 0..<pa.count {high=max(high,gt_dot(pa.p[i],n))}
    for i in 0..<pb.count {low=min(low,gt_dot(pb.p[i],n))}
    gt_fail(s,abs(gt_dot(gt_d3(out.point_a),n)-high),tolerance)
    gt_fail(s,abs(gt_dot(gt_d3(out.point_b),n)-low),tolerance)
}

@(test)
gjk_distance_between_spheres_is_the_center_distance_minus_the_radii :: proc(t:^testing.T) {
    a,b:=gt_sphere(1),gt_sphere(0.5)
    xf:=Transform{{3,4,0},QUAT_IDENTITY}
    core:=gjk_distance(gt_proxy(&a),gt_proxy(&b),xf)
    gt_near(t,core.distance,5,1e-5)
    gt_near3(t,core.normal,{0.6,0.8,0},1e-5)
    gt_near3(t,core.point_a,{0,0,0},1e-5)
    gt_near3(t,core.point_b,{3,4,0},1e-5)
    full:=gjk_distance(gt_proxy(&a),gt_proxy(&b),xf,nil,true)
    gt_near(t,full.distance,3.5,1e-5)
    gt_near3(t,full.normal,{0.6,0.8,0},1e-5)
    gt_near3(t,full.point_a,{0.6,0.8,0},1e-5)
    gt_near3(t,full.point_b,{2.7,3.6,0},1e-5)
}

@(test)
gjk_distance_keeps_the_normal_while_only_the_inflated_shapes_overlap :: proc(t:^testing.T) {
    a,b:=gt_sphere(1),gt_sphere(0.5)
    out:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{0.6,0.8,0},QUAT_IDENTITY},nil,true)
    testing.expect_value(t,out.distance,0)
    gt_near3(t,out.normal,{0.6,0.8,0},1e-5)
    gt_near3(t,out.point_a,{0.6,0.8,0},1e-5)
    gt_near3(t,out.point_b,{0.3,0.4,0},1e-5)
}

@(test)
gjk_distance_from_a_sphere_to_a_box_follows_the_face_edge_and_vertex_regions :: proc(t:^testing.T) {
    a,b:=gt_box({1,1,1}),gt_sphere(0.25)
    s:=f32(cmath.SQRT_TWO)*0.5
    face:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{3,0.2,-0.3},QUAT_IDENTITY})
    gt_near(t,face.distance,2,1e-5)
    gt_near3(t,face.normal,{1,0,0},1e-5)
    gt_near3(t,face.point_a,{1,0.2,-0.3},1e-5)
    edge:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{2,2,0.4},QUAT_IDENTITY})
    gt_near(t,edge.distance,cmath.SQRT_TWO,1e-5)
    gt_near3(t,edge.normal,{s,s,0},1e-5)
    gt_near3(t,edge.point_a,{1,1,0.4},1e-5)
    vertex:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{2,3,-3},QUAT_IDENTITY},nil,true)
    gt_near(t,vertex.distance,2.75,1e-5)
    gt_near3(t,vertex.normal,{1.0/3,2.0/3,-2.0/3},1e-5)
    gt_near3(t,vertex.point_a,{1,1,-1},1e-5)
    gt_near3(t,vertex.point_b,Vec3{2,3,-3}-Vec3{1.0/3,2.0/3,-2.0/3}*0.25,1e-5)
}

@(test)
gjk_distance_between_capsules_handles_parallel_and_crossed_axes :: proc(t:^testing.T) {
    a:=gt_capsule({-1,0,0},{1,0,0},0.25)
    b:=a
    parallel:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{0.5,2,0},QUAT_IDENTITY},nil,true)
    gt_near(t,parallel.distance,1.5,1e-5)
    gt_near3(t,parallel.normal,{0,1,0},1e-5)
    gt_near3(t,parallel.point_b-parallel.point_a,{0,1.5,0},1e-5)
    testing.expect(t,parallel.point_a.x>=-0.5-1e-5 && parallel.point_a.x<=1+1e-5)
    gt_near(t,parallel.point_a.y,0.25,1e-5)
    crossed:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{0,1,0},q_axis_angle({0,1,0},0.5*PI)})
    gt_near(t,crossed.distance,1,1e-5)
    gt_near3(t,crossed.point_a,{0,0,0},1e-5)
    gt_near3(t,crossed.point_b,{0,1,0},1e-5)
    ends:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{3,1,0},QUAT_IDENTITY})
    gt_near(t,ends.distance,cmath.SQRT_TWO,1e-5)
    gt_near3(t,ends.point_a,{1,0,0},1e-5)
    gt_near3(t,ends.point_b,{2,1,0},1e-5)
}

@(test)
gjk_distance_between_boxes_covers_separated_touching_and_overlapping :: proc(t:^testing.T) {
    a,b:=gt_box({1,1,1}),gt_box({1,1,1})
    apart:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{3.5,0.3,-0.2},QUAT_IDENTITY})
    gt_near(t,apart.distance,1.5,1e-5)
    gt_near3(t,apart.normal,{1,0,0},1e-5)
    turned:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{3,0,0},q_axis_angle({0,0,1},0.25*PI)})
    gt_near(t,turned.distance,2-cmath.SQRT_TWO,1e-5)
    gt_near3(t,turned.normal,{1,0,0},1e-5)
    gt_near(t,turned.point_a.x,1,1e-5)
    gt_near(t,turned.point_b.x,3-cmath.SQRT_TWO,1e-5)
    touching:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{2,0,0},QUAT_IDENTITY})
    testing.expect(t,gt_finite(touching))
    testing.expect(t,touching.distance<=1e-5)
    xf:=Transform{{1.5,0.2,0},q_axis_angle({0,1,0},0.3)}
    over:=gjk_distance(gt_proxy(&a),gt_proxy(&b),xf,nil,true)
    testing.expect_value(t,over.distance,0)
    testing.expect_value(t,over.normal,Vec3{})
    testing.expect_value(t,over.point_a,over.point_b)
    inside_a,inside_b:=vabs(over.point_a),vabs(xf_inv_point(xf,over.point_a))
    testing.expect(t,max(inside_a.x,inside_a.y,inside_a.z)<=1+1e-5)
    testing.expect(t,max(inside_b.x,inside_b.y,inside_b.z)<=1+1e-5)
}

@(test)
gjk_distance_to_a_tetrahedron_finds_its_face_edge_and_vertex :: proc(t:^testing.T) {
    a,b:=gt_tetrahedron(),gt_sphere(0.5)
    r:=1/f32(cmath.SQRT_THREE)
    face:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{-2,-2,-2},QUAT_IDENTITY})
    gt_near(t,face.distance,5*r,1e-5)
    gt_near3(t,face.normal,{-r,-r,-r},1e-5)
    gt_near3(t,face.point_a,{-1.0/3,-1.0/3,-1.0/3},1e-5)
    edge:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{3,0,0},QUAT_IDENTITY})
    gt_near(t,edge.distance,2,1e-5)
    gt_near3(t,edge.point_a,{1,0,0},1e-5)
    vertex:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{3,3,3},QUAT_IDENTITY},nil,true)
    gt_near(t,vertex.distance,2*cmath.SQRT_THREE-0.5,1e-5)
    gt_near3(t,vertex.point_a,{1,1,1},1e-5)
    inside:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{0.1,0,-0.1},QUAT_IDENTITY})
    testing.expect_value(t,inside.distance,0)
    testing.expect_value(t,inside.normal,Vec3{})
}

@(test)
gjk_distance_from_a_triangle_to_a_sphere_follows_its_regions :: proc(t:^testing.T) {
    a,b:=gt_triangle({0,0,0},{2,0,0},{0,2,0}),gt_sphere(0.5)
    above:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{0.5,0.5,1},QUAT_IDENTITY},nil,true)
    gt_near(t,above.distance,0.5,1e-5)
    gt_near3(t,above.normal,{0,0,1},1e-5)
    gt_near3(t,above.point_a,{0.5,0.5,0},1e-5)
    below:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{0.5,0.5,-2},QUAT_IDENTITY})
    gt_near(t,below.distance,2,1e-5)
    gt_near3(t,below.normal,{0,0,-1},1e-5)
    edge:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{1,-1,0},QUAT_IDENTITY})
    gt_near(t,edge.distance,1,1e-5)
    gt_near3(t,edge.point_a,{1,0,0},1e-5)
    gt_near3(t,edge.normal,{0,-1,0},1e-5)
    slanted:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{2,2,1},QUAT_IDENTITY})
    gt_near(t,slanted.distance,cmath.SQRT_THREE,1e-5)
    gt_near3(t,slanted.point_a,{1,1,0},1e-5)
    corner:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{3,-1,0},QUAT_IDENTITY})
    gt_near(t,corner.distance,cmath.SQRT_TWO,1e-5)
    gt_near3(t,corner.point_a,{2,0,0},1e-5)
    crossing:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{{0.5,0.5,0},QUAT_IDENTITY})
    testing.expect_value(t,crossing.distance,0)
    testing.expect_value(t,crossing.normal,Vec3{})
    gt_near3(t,crossing.point_a,{0.5,0.5,0},1e-5)
}

@(test)
gjk_distance_of_random_boxes_matches_the_exhaustive_feature_distance :: proc(t:^testing.T) {
    rng:=Gt_Rng{0x9e3779b97f4a7c15}
    stats:Gt_Stats
    for _ in 0..<800 {
        a,b:=gt_random_box(&rng),gt_random_box(&rng)
        gt_check_distance(&a,&b,gt_pose(&rng,3.5),&stats,2e-5)
    }
    gt_report(t,stats)
}

@(test)
gjk_distance_of_random_hulls_matches_the_exhaustive_feature_distance :: proc(t:^testing.T) {
    rng:=Gt_Rng{0x2545f4914f6cdd1d}
    stats:Gt_Stats
    for _ in 0..<1500 {
        a,b:=gt_random_shape(&rng),gt_random_shape(&rng)
        gt_check_distance(&a,&b,gt_pose(&rng,3),&stats,2e-5)
    }
    gt_report(t,stats)
}

@(test)
gjk_distance_is_symmetric_when_the_proxies_are_swapped :: proc(t:^testing.T) {
    rng:=Gt_Rng{0xd1b54a32d192ed03}
    stats:Gt_Stats
    for _ in 0..<3000 {
        a,b:=gt_random_shape(&rng),gt_random_shape(&rng)
        xf:=gt_pose(&rng,3)
        ab:=gjk_distance(gt_proxy(&a),gt_proxy(&b),xf)
        ba:=gjk_distance(gt_proxy(&b),gt_proxy(&a),xf_inv(xf))
        stats.cases+=1
        if !gt_finite(ab) || !gt_finite(ba) {
            stats.failures+=1
            continue
        }
        gt_fail(&stats,f64(abs(ab.distance-ba.distance)),2e-5)
        if min(ab.distance,ba.distance)<1e-3 {continue}
        gt_fail(&stats,f64(length(q_rotate(xf.q,ba.normal)+ab.normal)),1e-3)
    }
    gt_report(t,stats)
}

@(test)
gjk_distance_is_invariant_under_a_common_rigid_transform :: proc(t:^testing.T) {
    rng:=Gt_Rng{0x853c49e6748fea9b}
    stats:Gt_Stats
    for _ in 0..<3000 {
        a,b:=gt_random_shape(&rng),gt_random_shape(&rng)
        xf,frame:=gt_pose(&rng,3),gt_pose(&rng,10)
        moved:=a
        for i in 0..<a.count {moved.points[i]=xf_point(frame,a.points[i])}
        base:=gjk_distance(gt_proxy(&a),gt_proxy(&b),xf,nil,true)
        out:=gjk_distance(gt_proxy(&moved),gt_proxy(&b),xf_mul(frame,xf),nil,true)
        stats.cases+=1
        if !gt_finite(out) {
            stats.failures+=1
            continue
        }
        gt_fail(&stats,f64(abs(base.distance-out.distance)),1e-4)
        if base.distance<1e-3 {continue}
        gt_fail(&stats,f64(length(q_rotate(frame.q,base.normal)-out.normal)),1e-3)
        gt_fail(&stats,f64(length(out.point_b-out.point_a-out.normal*out.distance)),1e-4)
    }
    gt_report(t,stats)
}

@(test)
gjk_distance_with_a_warm_cache_agrees_with_a_cold_start_in_fewer_iterations :: proc(t:^testing.T) {
    rng:=Gt_Rng{0xda942042e4dd58b5}
    stats:Gt_Stats
    cold_iterations,warm_iterations:i32
    for _ in 0..<60 {
        a,b:=gt_random_shape(&rng),gt_random_shape(&rng)
        xf:=gt_pose(&rng,3)
        velocity,spin:=gt_vec(&rng,0.02),gt_vec(&rng,0.02)
        cache:Simplex_Cache
        for _ in 0..<50 {
            cold:=gjk_distance(gt_proxy(&a),gt_proxy(&b),xf)
            warm:=gjk_distance(gt_proxy(&a),gt_proxy(&b),xf,&cache)
            cold_iterations+=cold.iterations
            warm_iterations+=warm.iterations
            stats.cases+=1
            gt_fail(&stats,f64(abs(cold.distance-warm.distance)),2e-5)
            if cold.distance>1e-3 {gt_fail(&stats,f64(length(cold.normal-warm.normal)),1e-3)}
            again:=gjk_distance(gt_proxy(&a),gt_proxy(&b),xf,&cache)
            if again.iterations>1 || abs(again.distance-warm.distance)>2e-5 {stats.failures+=1}
            xf.p+=velocity
            xf.q=q_integrate(xf.q,spin)
        }
    }
    gt_report(t,stats)
    testing.expectf(t,warm_iterations<=cold_iterations,"warm %v, cold %v",warm_iterations,cold_iterations)
}

@(test)
gjk_distance_ignores_a_cache_that_does_not_fit_the_proxies :: proc(t:^testing.T) {
    a,b:=gt_box({1,1,1}),gt_tetrahedron()
    xf:=Transform{{3,0.5,1},q_axis_angle(normalize({1,1,0}),0.7)}
    cold:=gjk_distance(gt_proxy(&a),gt_proxy(&b),xf)
    caches:=[4]Simplex_Cache{
        {count=9},
        {count=3,index_a={0,200,1,0},index_b={1,2,3,0}},
        {count=2,index_a={0,1,0,0},index_b={0,7,0,0}},
        {count=4,index_a={3,3,3,3},index_b={2,2,2,2}},
    }
    for &cache in caches {
        out:=gjk_distance(gt_proxy(&a),gt_proxy(&b),xf,&cache)
        gt_near(t,out.distance,cold.distance,1e-5)
        gt_near3(t,out.normal,cold.normal,1e-4)
        testing.expect(t,cache.count>=1 && cache.count<=3)
    }
}

@(test)
gjk_distance_survives_degenerate_proxies :: proc(t:^testing.T) {
    box,ball:=gt_box({1,1,1}),gt_sphere(0.5)
    xf:=Transform{{2.5,1.5,0.3},q_axis_angle(normalize({1,2,3}),0.9)}
    doubled:=box
    for i in 0..<8 {doubled.points[8+i]=box.points[i]}
    doubled.count=16
    plain:=gjk_distance(gt_proxy(&ball),gt_proxy(&box),xf)
    twice:=gjk_distance(gt_proxy(&ball),gt_proxy(&doubled),xf)
    gt_near(t,twice.distance,plain.distance,1e-6)
    gt_near3(t,twice.normal,plain.normal,1e-5)

    heap:Gt_Shape
    for i in 0..<5 {heap.points[i]={0.5,-0.25,2}}
    heap.count=5
    point:=gjk_distance(gt_proxy(&box),gt_proxy(&heap),{{0,0,1},QUAT_IDENTITY})
    gt_near(t,point.distance,2,1e-5)
    gt_near3(t,point.normal,{0,0,1},1e-5)

    line:=gt_triangle({-1,0,0},{0.25,0,0},{1,0,0})
    rod:=gt_capsule({-1,0,0},{1,0,0},0)
    collinear:=gjk_distance(gt_proxy(&line),gt_proxy(&rod),{{0.5,2,0},q_axis_angle({0,1,0},0.4)})
    gt_near(t,collinear.distance,2,1e-5)
    gt_near3(t,collinear.normal,{0,1,0},1e-5)

    dot_capsule:=gt_capsule({0,3,0},{0,3,0},0.25)
    short:=gjk_distance(gt_proxy(&box),gt_proxy(&dot_capsule),TRANSFORM_IDENTITY,nil,true)
    gt_near(t,short.distance,1.75,1e-5)
    gt_near3(t,short.normal,{0,1,0},1e-5)

    plate:Gt_Shape
    plate.points[0],plate.points[1],plate.points[2],plate.points[3]={-1,0,-1},{1,0,-1},{1,0,1},{-1,0,1}
    plate.count=4
    over:=gjk_distance(gt_proxy(&plate),gt_proxy(&ball),{{0.2,1.5,-0.3},QUAT_IDENTITY},nil,true)
    gt_near(t,over.distance,1,1e-5)
    gt_near3(t,over.normal,{0,1,0},1e-5)
    through:=gjk_distance(gt_proxy(&plate),gt_proxy(&ball),{{0.2,0,-0.3},QUAT_IDENTITY})
    testing.expect_value(t,through.distance,0)
    testing.expect_value(t,through.normal,Vec3{})
    gt_near3(t,through.point_a,{0.2,0,-0.3},1e-5)

    same:=gjk_distance(gt_proxy(&ball),gt_proxy(&ball),TRANSFORM_IDENTITY,nil,true)
    testing.expect(t,gt_finite(same))
    testing.expect_value(t,same.distance,0)
    testing.expect_value(t,same.normal,Vec3{})
    rods:=gjk_distance(gt_proxy(&rod),gt_proxy(&rod),TRANSFORM_IDENTITY)
    testing.expect(t,gt_finite(rods))
    testing.expect_value(t,rods.distance,0)
    plates:=gjk_distance(gt_proxy(&plate),gt_proxy(&plate),{{0.5,0,0.5},QUAT_IDENTITY})
    testing.expect(t,gt_finite(plates))
    testing.expect_value(t,plates.distance,0)
    far:=gjk_distance(gt_proxy(&box),gt_proxy(&box),{{4000,3000,0},QUAT_IDENTITY})
    gt_near(t,far.distance,length(Vec3{3998,2998,0}),0.01)
    gt_near3(t,far.normal,normalize(Vec3{3998,2998,0}),1e-4)
}

@(test)
gjk_cast_of_spheres_matches_the_analytic_time_of_contact :: proc(t:^testing.T) {
    a,b:=gt_sphere(1),gt_sphere(0.5)
    direct:=gjk_cast(gt_proxy(&a),gt_proxy(&b),{{-5,0,0},QUAT_IDENTITY},{10,0,0})
    testing.expect(t,direct.hit)
    gt_near(t,direct.fraction,0.35,2e-5)
    gt_near3(t,direct.normal,{-1,0,0},1e-4)
    gt_near3(t,direct.point,{-1,0,0},1e-4)
    reach:=cmath.sqrt(f32(1.25))
    offset:=gjk_cast(gt_proxy(&a),gt_proxy(&b),{{-5,1,0},QUAT_IDENTITY},{10,0,0})
    testing.expect(t,offset.hit)
    gt_near(t,offset.fraction,(5-reach)/10,2e-5)
    gt_near3(t,offset.normal,Vec3{-reach,1,0}/1.5,2e-4)
    gt_near3(t,offset.point,Vec3{-reach,1,0}/1.5,2e-4)
    testing.expect(t,gjk_cast(gt_proxy(&a),gt_proxy(&b),{{-5,1.4,0},QUAT_IDENTITY},{10,0,0}).hit)
    testing.expect(t,!gjk_cast(gt_proxy(&a),gt_proxy(&b),{{-5,1.6,0},QUAT_IDENTITY},{10,0,0}).hit)
}

@(test)
gjk_cast_against_a_box_matches_the_analytic_time_of_contact :: proc(t:^testing.T) {
    a,ball,small:=gt_box({1,1,1}),gt_sphere(0.25),gt_box({0.5,0.5,0.5})
    s:=f32(cmath.SQRT_TWO)*0.5
    face:=gjk_cast(gt_proxy(&a),gt_proxy(&ball),{{0.3,5,-0.2},QUAT_IDENTITY},{0,-10,0})
    testing.expect(t,face.hit)
    gt_near(t,face.fraction,0.375,2e-5)
    gt_near3(t,face.normal,{0,1,0},1e-4)
    gt_near3(t,face.point,{0.3,1,-0.2},1e-4)
    edge:=gjk_cast(gt_proxy(&a),gt_proxy(&ball),{{5,5,0.1},QUAT_IDENTITY},{-10,-10,0})
    testing.expect(t,edge.hit)
    gt_near(t,edge.fraction,(4-0.25*s)/10,2e-5)
    gt_near3(t,edge.normal,{s,s,0},2e-4)
    gt_near3(t,edge.point,{1,1,0.1},2e-4)
    flat:=gjk_cast(gt_proxy(&a),gt_proxy(&small),{{4,0.1,0.2},QUAT_IDENTITY},{-4,0,0})
    testing.expect(t,flat.hit)
    gt_near(t,flat.fraction,0.625,5e-5)
    gt_near3(t,flat.normal,{1,0,0},1e-4)
    gt_near(t,flat.point.x,1,1e-4)
    turned:=gjk_cast(gt_proxy(&a),gt_proxy(&small),{{4,0,0},q_axis_angle({0,0,1},0.25*PI)},{-4,0,0})
    testing.expect(t,turned.hit)
    gt_near(t,turned.fraction,(3-s)/4,5e-5)
    gt_near3(t,turned.normal,{1,0,0},1e-4)
    gt_near3(t,turned.point,{1,0,turned.point.z},1e-4)
}

@(test)
gjk_cast_reports_no_hit_when_the_shapes_never_meet :: proc(t:^testing.T) {
    a,ball,small:=gt_box({1,1,1}),gt_sphere(0.25),gt_box({0.5,0.5,0.5})
    xf:=Transform{{0.3,5,-0.2},QUAT_IDENTITY}
    away:=gjk_cast(gt_proxy(&a),gt_proxy(&ball),xf,{0,10,0})
    testing.expect(t,!away.hit)
    testing.expect_value(t,away.normal,Vec3{})
    testing.expect(t,!gjk_cast(gt_proxy(&a),gt_proxy(&ball),xf,{0,-10,0},0.37).hit)
    testing.expect(t,gjk_cast(gt_proxy(&a),gt_proxy(&ball),xf,{0,-10,0},0.38).hit)
    testing.expect(t,!gjk_cast(gt_proxy(&a),gt_proxy(&ball),xf,{0,0,0}).hit)
    testing.expect(t,!gjk_cast(gt_proxy(&a),gt_proxy(&small),{{-5,1.6,0},QUAT_IDENTITY},{10,0,0}).hit)
    testing.expect(t,!gjk_cast(gt_proxy(&a),gt_proxy(&small),{{-5,1.6,0.3},q_axis_angle({0,1,0},0.5)},{10,0,0}).hit)
    testing.expect(t,gjk_cast(gt_proxy(&a),gt_proxy(&small),{{-5,1.4,0},QUAT_IDENTITY},{10,0,0}).hit)
    testing.expect(t,!gjk_cast(gt_proxy(&a),gt_proxy(&ball),{{-5,1.26,0},QUAT_IDENTITY},{10,0,0}).hit)
}

@(test)
gjk_cast_of_overlapping_shapes_hits_at_zero_without_a_normal :: proc(t:^testing.T) {
    a,ball,small:=gt_box({1,1,1}),gt_sphere(0.5),gt_box({0.5,0.5,0.5})
    deep:=gjk_cast(gt_proxy(&a),gt_proxy(&small),{{0.8,0.2,0},QUAT_IDENTITY},{3,0,0})
    testing.expect(t,deep.hit)
    testing.expect_value(t,deep.fraction,0)
    testing.expect_value(t,deep.normal,Vec3{})
    shallow:=gjk_cast(gt_proxy(&a),gt_proxy(&ball),{{1.3,0,0},QUAT_IDENTITY},{-1,0,0})
    testing.expect(t,shallow.hit)
    testing.expect_value(t,shallow.fraction,0)
    testing.expect_value(t,shallow.normal,Vec3{})
    gt_near3(t,shallow.point,{0.9,0,0},1e-5)
    leaving:=gjk_cast(gt_proxy(&a),gt_proxy(&ball),{{1.3,0,0},QUAT_IDENTITY},{5,0,0})
    testing.expect(t,leaving.hit)
    testing.expect_value(t,leaving.fraction,0)
}

@(test)
gjk_cast_of_touching_shapes_hits_at_zero_only_when_they_approach :: proc(t:^testing.T) {
    a,ball,small:=gt_box({1,1,1}),gt_sphere(0.5),gt_box({0.5,0.5,0.5})
    resting:=Transform{{0.2,1.5,0.1},QUAT_IDENTITY}
    pressing:=gjk_cast(gt_proxy(&a),gt_proxy(&small),resting,{0,-1,0})
    testing.expect(t,pressing.hit)
    testing.expect_value(t,pressing.fraction,0)
    gt_near3(t,pressing.normal,{0,1,0},1e-4)
    gt_near(t,pressing.point.y,1,1e-4)
    testing.expect(t,!gjk_cast(gt_proxy(&a),gt_proxy(&small),resting,{3,0,0}).hit)
    testing.expect(t,!gjk_cast(gt_proxy(&a),gt_proxy(&small),resting,{1,2,0}).hit)
    rolling:=gjk_cast(gt_proxy(&a),gt_proxy(&ball),resting,{0.5,-1,0})
    testing.expect(t,rolling.hit)
    testing.expect_value(t,rolling.fraction,0)
    gt_near3(t,rolling.normal,{0,1,0},1e-4)
    testing.expect(t,!gjk_cast(gt_proxy(&a),gt_proxy(&ball),resting,{3,0,0}).hit)
}

@(test)
gjk_cast_of_random_shapes_stops_where_the_distance_reaches_zero :: proc(t:^testing.T) {
    rng:=Gt_Rng{0x94d049bb133111eb}
    stats:Gt_Stats
    hits,misses:=0,0
    for _ in 0..<1500 {
        a,b:=gt_random_shape(&rng),gt_random_shape(&rng)
        xf:=gt_pose(&rng,4)
        translation:=gt_vec(&rng,1.5)-xf.p*gt_range(&rng,0.5,1.5)
        radius:=a.radius+b.radius
        start:=gjk_distance(gt_proxy(&a),gt_proxy(&b),xf)
        if start.distance-radius<0.01 {continue}
        out:=gjk_cast(gt_proxy(&a),gt_proxy(&b),xf,translation)
        stats.cases+=1
        if out.fraction-out.fraction!=0 || !finite(out.point) || !finite(out.normal) {
            stats.failures+=1
            continue
        }
        end:f32=1
        if out.hit {
            hits+=1
            end=out.fraction
            at:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{xf.p+translation*out.fraction,xf.q})
            gt_fail(&stats,f64(abs(at.distance-radius)),3e-4)
            gt_fail(&stats,f64(abs(length(out.normal)-1)),1e-5)
            if at.distance>1e-3 {
                gt_fail(&stats,f64(length(at.normal-out.normal)),2e-2)
                gt_fail(&stats,f64(length(at.point_a+at.normal*a.radius-out.point)),2e-2)
            }
            if out.fraction<0 || out.fraction>1 || dot(translation,out.normal)>=0 {stats.failures+=1}
        } else {
            misses+=1
            if out.fraction!=0 || out.normal!={} || out.point!={} {stats.failures+=1}
        }
        for i in 0..<24 {
            before:=gjk_distance(gt_proxy(&a),gt_proxy(&b),{xf.p+translation*(end*f32(i)/24),xf.q})
            if before.distance-radius< -3e-4 {
                stats.failures+=1
                break
            }
        }
    }
    gt_report(t,stats)
    testing.expectf(t,hits>300 && misses>100,"%v hits and %v misses",hits,misses)
}

// Checks a penetration: moving B by the normal times the depth leaves the shapes in touch, the witness points
// are that far apart and each one lies on the surface of its shape that faces the other.
@(private="file")
gt_check_penetration :: proc(a,b:^Gt_Shape,xf:Transform,pen:Penetration,s:^Gt_Stats,tolerance:f64) {
    pa,pb:=gt_points(a,TRANSFORM_IDENTITY),gt_points(b,xf)
    n:=gt_d3(pen.normal)
    core:=f64(pen.depth-a.radius-b.radius)
    gt_fail(s,abs(f64(length(pen.normal))-1),1e-5)
    gt_fail(s,abs(gt_overlap_along(&pa,&pb,n)-core),tolerance)
    gt_fail(s,f64(length(pen.point_a-pen.point_b-pen.normal*pen.depth)),tolerance)
    high,low:=-max(f64),max(f64)
    for i in 0..<pa.count {high=max(high,gt_dot(pa.p[i],n))}
    for i in 0..<pb.count {low=min(low,gt_dot(pb.p[i],n))}
    gt_fail(s,abs(gt_dot(gt_d3(pen.point_a),n)-high-f64(a.radius)),tolerance)
    gt_fail(s,abs(gt_dot(gt_d3(pen.point_b),n)-low+f64(b.radius)),tolerance)
    out:=gjk_distance(gt_proxy(a),gt_proxy(b),{xf.p+pen.normal*(pen.depth+1e-3),xf.q},nil,true)
    in_:=gjk_distance(gt_proxy(a),gt_proxy(b),{xf.p+pen.normal*(pen.depth-1e-3),xf.q},nil,true)
    if !(out.distance>0) || in_.distance!=0 {s.failures+=1}
}

@(test)
epa_penetration_of_spheres_is_the_sum_of_radii_minus_the_center_distance :: proc(t:^testing.T) {
    a,b:=gt_sphere(1),gt_sphere(0.5)
    pen:=epa_penetration(gt_proxy(&a),gt_proxy(&b),{{0.6,0,0.8},QUAT_IDENTITY})
    testing.expect(t,pen.ok)
    gt_near(t,pen.depth,0.5,1e-5)
    gt_near3(t,pen.normal,{0.6,0,0.8},1e-5)
    gt_near3(t,pen.point_a,{0.6,0,0.8},1e-5)
    gt_near3(t,pen.point_b,{0.3,0,0.4},1e-5)
    apart:=epa_penetration(gt_proxy(&a),gt_proxy(&b),{{3,0,4},QUAT_IDENTITY})
    testing.expect(t,!apart.ok)
    gt_near(t,apart.depth,-3.5,1e-5)
    gt_near3(t,apart.normal,{0.6,0,0.8},1e-5)
    gt_near3(t,apart.point_a,{0.6,0,0.8},1e-5)
    gt_near3(t,apart.point_b,{2.7,0,3.6},1e-5)
}

@(test)
epa_penetration_of_boxes_matches_the_analytic_depth :: proc(t:^testing.T) {
    a,b:=gt_box({1,1,1}),gt_box({1,1,1})
    stats:Gt_Stats
    xf:=Transform{{1.7,0.2,-0.1},QUAT_IDENTITY}
    aligned:=epa_penetration(gt_proxy(&a),gt_proxy(&b),xf)
    testing.expect(t,aligned.ok)
    gt_near(t,aligned.depth,0.3,1e-5)
    gt_near3(t,aligned.normal,{1,0,0},1e-5)
    gt_near(t,aligned.point_a.x,1,1e-5)
    gt_near(t,aligned.point_b.x,0.7,1e-5)
    gt_check_penetration(&a,&b,xf,aligned,&stats,2e-5)
    xf={{2.2,0,0},q_axis_angle({0,0,1},0.25*PI)}
    turned:=epa_penetration(gt_proxy(&a),gt_proxy(&b),xf)
    testing.expect(t,turned.ok)
    gt_near(t,turned.depth,cmath.SQRT_TWO-1.2,1e-5)
    gt_near3(t,turned.normal,{1,0,0},1e-5)
    gt_check_penetration(&a,&b,xf,turned,&stats,2e-5)
    xf={{0.4,-1.6,0.3},q_axis_angle({0,1,0},0.6)}
    below:=epa_penetration(gt_proxy(&a),gt_proxy(&b),xf)
    testing.expect(t,below.ok)
    gt_near(t,below.depth,0.4,1e-5)
    gt_near3(t,below.normal,{0,-1,0},1e-5)
    gt_check_penetration(&a,&b,xf,below,&stats,2e-5)
    gt_report(t,stats)
}

@(test)
epa_penetration_adds_the_radii_to_the_depth_of_the_cores :: proc(t:^testing.T) {
    rod,block:=gt_capsule({0,-1,0},{0,1,0},0.25),gt_box({1,1,1},0.1)
    stats:Gt_Stats
    xf:=Transform{{0.8,0.1,0.2},QUAT_IDENTITY}
    pen:=epa_penetration(gt_proxy(&rod),gt_proxy(&block),xf)
    testing.expect(t,pen.ok)
    gt_near(t,pen.depth,0.55,1e-5)
    gt_near3(t,pen.normal,{1,0,0},1e-5)
    gt_near(t,pen.point_a.x,0.25,1e-5)
    gt_near(t,pen.point_b.x,-0.3,1e-5)
    gt_check_penetration(&rod,&block,xf,pen,&stats,2e-5)
    swapped:=epa_penetration(gt_proxy(&block),gt_proxy(&rod),xf_inv(xf))
    testing.expect(t,swapped.ok)
    gt_near(t,swapped.depth,0.55,1e-5)
    gt_near3(t,swapped.normal,{-1,0,0},1e-5)
    xf.p={1.2,0.1,0.2}
    grazing:=epa_penetration(gt_proxy(&rod),gt_proxy(&block),xf)
    testing.expect(t,grazing.ok)
    gt_near(t,grazing.depth,0.15,1e-5)
    gt_near3(t,grazing.normal,{1,0,0},1e-5)
    gt_report(t,stats)
}

@(test)
epa_penetration_of_a_contained_box_pushes_through_the_nearest_face :: proc(t:^testing.T) {
    a,b:=gt_box({2,2,2}),gt_box({0.25,0.25,0.25})
    stats:Gt_Stats
    xf:=Transform{{0.5,0.1,-0.2},q_axis_angle({1,0,0},0.5*PI)}
    pen:=epa_penetration(gt_proxy(&a),gt_proxy(&b),xf)
    testing.expect(t,pen.ok)
    gt_near(t,pen.depth,1.75,1e-5)
    gt_near3(t,pen.normal,{1,0,0},1e-5)
    gt_check_penetration(&a,&b,xf,pen,&stats,2e-5)
    centered:=epa_penetration(gt_proxy(&a),gt_proxy(&b),TRANSFORM_IDENTITY)
    testing.expect(t,centered.ok)
    gt_near(t,centered.depth,2.25,1e-5)
    gt_check_penetration(&a,&b,TRANSFORM_IDENTITY,centered,&stats,2e-5)
    gt_report(t,stats)
}

@(test)
epa_penetration_of_random_boxes_matches_the_separating_axis_depth :: proc(t:^testing.T) {
    rng:=Gt_Rng{0xbf58476d1ce4e5b9}
    stats:Gt_Stats
    for stats.cases<600 {
        a,b:=gt_random_box(&rng),gt_random_box(&rng)
        a.radius,b.radius=gt_range(&rng,0,0.2),gt_range(&rng,0,0.2)
        xf:=gt_pose(&rng,1.5)
        pa,pb:=gt_points(&a,TRANSFORM_IDENTITY),gt_points(&b,xf)
        depth,_:=gt_reference_overlap(&pa,&pb)
        if depth<1e-3 {continue}
        pen:=epa_penetration(gt_proxy(&a),gt_proxy(&b),xf)
        stats.cases+=1
        if !pen.ok {
            stats.failures+=1
            continue
        }
        gt_fail(&stats,abs(f64(pen.depth-a.radius-b.radius)-depth),5e-5)
        gt_check_penetration(&a,&b,xf,pen,&stats,5e-5)
    }
    gt_report(t,stats)
}

@(test)
epa_penetration_of_random_hulls_matches_the_smallest_overlap_of_their_axes :: proc(t:^testing.T) {
    rng:=Gt_Rng{0x6a09e667f3bcc909}
    stats:Gt_Stats
    disjoint:=0
    for stats.cases<1000 {
        a,b:=gt_random_shape(&rng),gt_random_shape(&rng)
        xf:=gt_pose(&rng,1.2)
        pa,pb:=gt_points(&a,TRANSFORM_IDENTITY),gt_points(&b,xf)
        depth,found:=gt_reference_overlap(&pa,&pb)
        if !found || abs(depth)<1e-3 {continue}
        pen:=epa_penetration(gt_proxy(&a),gt_proxy(&b),xf)
        stats.cases+=1
        if !finite(pen.normal) || !finite(pen.point_a) || !finite(pen.point_b) {
            stats.failures+=1
            continue
        }
        if depth<0 {
            disjoint+=1
            reference:=gt_reference_distance(&pa,&pb)
            gt_fail(&stats,abs(f64(a.radius+b.radius-pen.depth)-reference),5e-5)
            if pen.ok!=(pen.depth>0) {stats.failures+=1}
            continue
        }
        if !pen.ok {
            stats.failures+=1
            continue
        }
        gt_fail(&stats,abs(f64(pen.depth-a.radius-b.radius)-depth),5e-5)
        gt_check_penetration(&a,&b,xf,pen,&stats,5e-5)
    }
    gt_report(t,stats)
    testing.expect(t,disjoint>100 && disjoint<900)
}

@(test)
epa_penetration_of_flat_and_coincident_cores_is_the_sum_of_radii :: proc(t:^testing.T) {
    ball,rod:=gt_sphere(0.5),gt_capsule({-1,0,0},{1,0,0},0.25)
    floor:=gt_triangle({-2,0,-2},{2,0,-2},{0,0,3})
    same:=epa_penetration(gt_proxy(&ball),gt_proxy(&ball),TRANSFORM_IDENTITY)
    testing.expect(t,same.ok)
    gt_near(t,same.depth,1,1e-6)
    gt_near3(t,same.normal,{0,1,0},1e-6)
    gt_near3(t,same.point_a-same.point_b,{0,1,0},1e-6)
    along:=epa_penetration(gt_proxy(&rod),gt_proxy(&rod),{{0.5,0,0},QUAT_IDENTITY})
    testing.expect(t,along.ok)
    gt_near(t,along.depth,0.5,1e-5)
    gt_near(t,length(along.normal),1,1e-5)
    gt_near(t,along.normal.x,0,1e-5)
    crossed:=epa_penetration(gt_proxy(&rod),gt_proxy(&rod),{{0.2,0,0.1},q_axis_angle({0,1,0},1.1)})
    testing.expect(t,crossed.ok)
    gt_near(t,crossed.depth,0.5,1e-5)
    gt_near(t,abs(crossed.normal.y),1,1e-5)
    gt_near3(t,crossed.point_a-crossed.point_b,crossed.normal*0.5,1e-5)
    resting:=epa_penetration(gt_proxy(&floor),gt_proxy(&ball),{{0.3,0,0.4},QUAT_IDENTITY})
    testing.expect(t,resting.ok)
    gt_near(t,resting.depth,0.5,1e-5)
    gt_near(t,abs(resting.normal.y),1,1e-5)
    gt_near3(t,resting.point_a,{0.3,0,0.4},1e-5)
    sunk:=epa_penetration(gt_proxy(&floor),gt_proxy(&ball),{{0.3,-0.2,0.4},QUAT_IDENTITY})
    testing.expect(t,sunk.ok)
    gt_near(t,sunk.depth,0.3,1e-5)
    gt_near3(t,sunk.normal,{0,-1,0},1e-5)
    pierced:=epa_penetration(gt_proxy(&floor),gt_proxy(&rod),{{0.2,0.5,0.3},q_axis_angle({0,0,1},0.5*PI)})
    testing.expect(t,pierced.ok)
    gt_near(t,pierced.depth,0.75,1e-5)
    gt_near3(t,pierced.normal,{0,1,0},1e-5)
}

@(test)
epa_penetration_of_touching_boxes_has_no_depth :: proc(t:^testing.T) {
    a,b:=gt_box({1,1,1}),gt_box({0.5,0.5,0.5})
    poses:=[3]Transform{
        {{1.5,0.2,0.1},QUAT_IDENTITY},
        {{0.3,1.5,-0.4},q_axis_angle({0,1,0},0.7)},
        {{1+f32(cmath.SQRT_TWO)*0.5,0,0},q_axis_angle({0,0,1},0.25*PI)},
    }
    for xf in poses {
        pen:=epa_penetration(gt_proxy(&a),gt_proxy(&b),xf)
        testing.expect(t,finite(pen.normal) && finite(pen.point_a) && finite(pen.point_b))
        gt_near(t,pen.depth,0,1e-5)
        if pen.ok {gt_near3(t,pen.normal,normalize(Vec3{xf.p.x>1 ? 1 : 0,xf.p.y>1 ? 1 : 0,0}),1e-4)}
    }
}

@(private="file")
gt_sweep :: proc(from,to:Transform) -> Sweep {return {{},from.p,to.p,from.q,to.q}}
@(private="file")
gt_still :: proc(xf:Transform) -> Sweep {return gt_sweep(xf,xf)}
// First of `steps` sampled times at which the distance between the swept shapes, radii included, is at or
// below the limit, and the smallest distance sampled.
@(private="file")
gt_first_time_within :: proc(a,b:^Gt_Shape,sa,sb:Sweep,limit,until:f32,steps:int) -> (fraction,lowest:f32) {
    fraction,lowest=-1,max(f32)
    for i in 0..=steps {
        time:=until*f32(i)/f32(steps)
        xf:=xf_inv_mul(sweep_transform(sa,time),sweep_transform(sb,time))
        d:=gjk_distance(gt_proxy(a),gt_proxy(b),xf).distance-a.radius-b.radius
        lowest=min(lowest,d)
        if d<=limit && fraction<0 {fraction=time}
    }
    return
}

@(test)
time_of_impact_of_a_sphere_thrown_at_a_box_stops_a_slop_before_contact :: proc(t:^testing.T) {
    a,b:=gt_box({1,1,1}),gt_sphere(0.5)
    home:=Transform{{10,-3,2},q_axis_angle({0,1,0},0.5*PI)}
    out:=time_of_impact(gt_proxy(&a),gt_proxy(&b),gt_still(home),
        gt_sweep({home.p+Vec3{0,0.2,5},QUAT_IDENTITY},{home.p+Vec3{0,0.2,-5},QUAT_IDENTITY}))
    testing.expect_value(t,out.state,Toi_State.Hit)
    gt_near(t,out.fraction,(5-1.5-GJK_LINEAR_SLOP)/10,0.25*GJK_LINEAR_SLOP/10+1e-5)
    short:=time_of_impact(gt_proxy(&a),gt_proxy(&b),gt_still(home),
        gt_sweep({home.p+Vec3{0,0.2,5},QUAT_IDENTITY},{home.p+Vec3{0,0.2,-5},QUAT_IDENTITY}),0.3)
    testing.expect_value(t,short.state,Toi_State.Separated)
    testing.expect_value(t,short.fraction,0.3)
}

@(test)
time_of_impact_of_a_box_falling_flat_on_a_slab_stops_a_slop_above_it :: proc(t:^testing.T) {
    slab,crate:=gt_box({10,1,10}),gt_box({0.5,0.5,0.5})
    turn:=q_axis_angle({0,1,0},0.4)
    out:=time_of_impact(gt_proxy(&slab),gt_proxy(&crate),gt_still(TRANSFORM_IDENTITY),
        gt_sweep({{2,5,-3},turn},{{2,-5,-3},turn}))
    testing.expect_value(t,out.state,Toi_State.Hit)
    gt_near(t,out.fraction,(5-1.5-GJK_LINEAR_SLOP)/10,0.25*GJK_LINEAR_SLOP/10+1e-5)
    both:=time_of_impact(gt_proxy(&slab),gt_proxy(&crate),gt_sweep(TRANSFORM_IDENTITY,{{0,2,0},QUAT_IDENTITY}),
        gt_sweep({{2,5,-3},turn},{{2,-5,-3},turn}))
    testing.expect_value(t,both.state,Toi_State.Hit)
    gt_near(t,both.fraction,(5-1.5-GJK_LINEAR_SLOP)/12,0.25*GJK_LINEAR_SLOP/12+1e-5)
}

@(test)
time_of_impact_of_a_spinning_rod_matches_a_finely_sampled_sweep :: proc(t:^testing.T) {
    wall,rod:=gt_box({0.5,5,5}),gt_box({1,0.05,0.05})
    still:=gt_still({{1.2,0,0},QUAT_IDENTITY})
    spin:=gt_sweep({{0,0,0},q_axis_angle({0,0,1},0.5*PI)},{{0,0,0},QUAT_IDENTITY})
    out:=time_of_impact(gt_proxy(&wall),gt_proxy(&rod),still,spin)
    testing.expect_value(t,out.state,Toi_State.Hit)
    reference,_:=gt_first_time_within(&wall,&rod,still,spin,GJK_LINEAR_SLOP,1,4000)
    gt_near(t,out.fraction,reference,2.5e-3)
    at:=xf_inv_mul(sweep_transform(still,out.fraction),sweep_transform(spin,out.fraction))
    gt_near(t,gjk_distance(gt_proxy(&wall),gt_proxy(&rod),at).distance,GJK_LINEAR_SLOP,0.25*GJK_LINEAR_SLOP+1e-5)

    tumble:=Sweep{{0.5,0,0},{-3,0.5,0},{0.4,0.2,0.3},q_axis_angle(normalize({1,1,1}),-1),q_axis_angle({0,1,0},0.4)}
    out=time_of_impact(gt_proxy(&wall),gt_proxy(&rod),still,tumble)
    testing.expect_value(t,out.state,Toi_State.Hit)
    reference,_=gt_first_time_within(&wall,&rod,still,tumble,GJK_LINEAR_SLOP,1,4000)
    gt_near(t,out.fraction,reference,2.5e-3)
    at=xf_inv_mul(sweep_transform(still,out.fraction),sweep_transform(tumble,out.fraction))
    gt_near(t,gjk_distance(gt_proxy(&wall),gt_proxy(&rod),at).distance,GJK_LINEAR_SLOP,0.25*GJK_LINEAR_SLOP+1e-5)
}

@(test)
time_of_impact_tells_overlapped_touching_and_separated_sweeps_apart :: proc(t:^testing.T) {
    a,b,ball:=gt_box({1,1,1}),gt_box({0.5,0.5,0.5}),gt_sphere(0.5)
    still:=gt_still(TRANSFORM_IDENTITY)
    inside:=time_of_impact(gt_proxy(&a),gt_proxy(&b),still,gt_sweep({{1.2,0,0},QUAT_IDENTITY},{{5,0,0},QUAT_IDENTITY}))
    testing.expect_value(t,inside.state,Toi_State.Overlapped)
    testing.expect_value(t,inside.fraction,0)
    pressed:=time_of_impact(gt_proxy(&a),gt_proxy(&ball),still,gt_sweep({{1.4,0,0},QUAT_IDENTITY},{{0,0,0},QUAT_IDENTITY}))
    testing.expect_value(t,pressed.state,Toi_State.Overlapped)
    close:=time_of_impact(gt_proxy(&a),gt_proxy(&ball),still,gt_sweep({{1.503,0,0},QUAT_IDENTITY},{{0,0,0},QUAT_IDENTITY}))
    testing.expect_value(t,close.state,Toi_State.Hit)
    testing.expect_value(t,close.fraction,0)
    away:=time_of_impact(gt_proxy(&a),gt_proxy(&b),still,gt_sweep({{2,0,0},QUAT_IDENTITY},{{6,1,0},QUAT_IDENTITY}))
    testing.expect_value(t,away.state,Toi_State.Separated)
    testing.expect_value(t,away.fraction,1)
    past:=time_of_impact(gt_proxy(&a),gt_proxy(&b),still,
        gt_sweep({{-5,1.6,0},q_axis_angle({0,1,0},0.3)},{{5,1.6,0},q_axis_angle({0,1,0},-0.9)}),0.75)
    testing.expect_value(t,past.state,Toi_State.Separated)
    testing.expect_value(t,past.fraction,0.75)
    idle:=time_of_impact(gt_proxy(&a),gt_proxy(&b),still,gt_still({{3,0,0},QUAT_IDENTITY}))
    testing.expect_value(t,idle.state,Toi_State.Separated)
}

@(test)
time_of_impact_of_random_sweeps_never_passes_the_first_contact :: proc(t:^testing.T) {
    rng:=Gt_Rng{0x3c6ef372fe94f82b}
    stats:Gt_Stats
    counts:[Toi_State]int
    for _ in 0..<600 {
        a,b:=gt_random_shape(&rng),gt_random_shape(&rng)
        xa,xb:=gt_pose(&rng,2),gt_pose(&rng,2)
        xb.p+=gt_dir(&rng)*5
        sa:=Sweep{gt_vec(&rng,0.3),xa.p,xa.p+gt_vec(&rng,1),xa.q,q_integrate(xa.q,gt_vec(&rng,0.3))}
        sb:=Sweep{gt_vec(&rng,0.3),xb.p,xa.p+gt_vec(&rng,2),xb.q,q_integrate(xb.q,gt_vec(&rng,0.45))}
        out:=time_of_impact(gt_proxy(&a),gt_proxy(&b),sa,sb)
        stats.cases+=1
        counts[out.state]+=1
        if out.state==.Unknown || !(out.fraction>=0 && out.fraction<=1) {
            stats.failures+=1
            continue
        }
        _,lowest:=gt_first_time_within(&a,&b,sa,sb,0,out.fraction,48)
        #partial switch out.state {
        case .Hit:
            xf:=xf_inv_mul(sweep_transform(sa,out.fraction),sweep_transform(sb,out.fraction))
            d:=gjk_distance(gt_proxy(&a),gt_proxy(&b),xf).distance-a.radius-b.radius
            if out.fraction>0 {gt_fail(&stats,f64(abs(d-GJK_LINEAR_SLOP)),0.25*GJK_LINEAR_SLOP+1e-4)}
            if lowest<0.5*GJK_LINEAR_SLOP {stats.failures+=1}
        case .Separated:
            if out.fraction!=1 || lowest<0.5*GJK_LINEAR_SLOP {stats.failures+=1}
        case .Overlapped:
            if out.fraction!=0 || lowest>1e-4 {stats.failures+=1}
        case .Failed:
            if lowest<0 {stats.failures+=1}
        }
    }
    gt_report(t,stats)
    testing.expectf(t,counts[.Hit]>200 && counts[.Separated]>20 && counts[.Failed]<=6,"%v",counts)
}

@(test)
convex_queries_stay_finite_for_degenerate_shapes_and_motions :: proc(t:^testing.T) {
    heap:Gt_Shape
    for i in 0..<6 {heap.points[i]={1,2,3}}
    heap.count,heap.radius=6,0.1
    line:=gt_triangle({-1,0,0},{0,0,0},{2,0,0})
    plate:Gt_Shape
    plate.points[0],plate.points[1],plate.points[2],plate.points[3]={-1,0,-1},{1,0,-1},{1,0,1},{-1,0,1}
    plate.count=4
    shapes:=[6]Gt_Shape{gt_sphere(0),gt_capsule({0,1,0},{0,1,0},0),heap,line,plate,gt_box({1,1,1})}
    poses:=[4]Transform{
        TRANSFORM_IDENTITY,
        {{1,2,3},QUAT_IDENTITY},
        {{0,1,0},q_axis_angle({1,0,0},0.5*PI)},
        {{1e-7,-1e-7,0},q_axis_angle({0,0,1},PI)},
    }
    translations:=[3]Vec3{{},{0,-1,0},{-1,-2,-3}}
    failures:=0
    for &a in shapes {
        for &b in shapes {
            for xf in poses {
                ends:=[2]Transform{xf,{{0,-1,0.5},q_axis_angle({0,1,0},2)}}
                d:=gjk_distance(gt_proxy(&a),gt_proxy(&b),xf,nil,true)
                if !gt_finite(d) || d.distance<0 || (d.normal!={} && abs(length(d.normal)-1)>1e-5) {failures+=1}
                p:=epa_penetration(gt_proxy(&a),gt_proxy(&b),xf)
                if !finite(p.normal) || !finite(p.point_a) || !finite(p.point_b) || p.depth-p.depth!=0 {failures+=1}
                if p.ok && (abs(length(p.normal)-1)>1e-5 || p.depth<0) {failures+=1}
                if d.normal=={} && !(p.ok && p.depth>=a.radius+b.radius) {failures+=1}
                for translation in translations {
                    c:=gjk_cast(gt_proxy(&a),gt_proxy(&b),xf,translation)
                    if !finite(c.normal) || !finite(c.point) || !(c.fraction>=0 && c.fraction<=1) {failures+=1}
                }
                for end in ends {
                    o:=time_of_impact(gt_proxy(&a),gt_proxy(&b),gt_still(TRANSFORM_IDENTITY),gt_sweep(xf,end))
                    if o.state==.Unknown || !(o.fraction>=0 && o.fraction<=1) {failures+=1}
                }
            }
        }
    }
    testing.expect_value(t,failures,0)
}

when GJK_BENCH {
// Nanoseconds per call of gjk_distance and epa_penetration over random box pairs: the best of several passes.
@(test)
gjk_distance_of_boxes_reports_its_time :: proc(t:^testing.T) {
    COUNT::256
    PASSES::9
    ROUNDS::40
    rng:=Gt_Rng{0x1234567887654321}
    boxes:=new([COUNT][2]Gt_Shape)
    poses:=new([COUNT]Transform)
    caches:=new([COUNT]Simplex_Cache)
    defer free(boxes)
    defer free(poses)
    defer free(caches)
    for i in 0..<COUNT {
        boxes[i]={gt_random_box(&rng),gt_random_box(&rng)}
        poses[i]={gt_dir(&rng)*gt_range(&rng,3,6),gt_rotation(&rng)}
    }
    best:=[3]f64{max(f64),max(f64),max(f64)}
    sum:f32
    iterations,overlapping:=0,0
    for pass in 0..<PASSES {
        start:=time.tick_now()
        for _ in 0..<ROUNDS {
            for i in 0..<COUNT {
                out:=gjk_distance(gt_proxy(&boxes[i][0]),gt_proxy(&boxes[i][1]),poses[i])
                sum+=out.distance
                if pass==0 {iterations+=int(out.iterations)}
            }
        }
        best[0]=min(best[0],f64(time.duration_nanoseconds(time.tick_since(start)))/(ROUNDS*COUNT))
        start=time.tick_now()
        for _ in 0..<ROUNDS {
            for i in 0..<COUNT {sum+=gjk_distance(gt_proxy(&boxes[i][0]),gt_proxy(&boxes[i][1]),poses[i],&caches[i]).distance}
        }
        best[1]=min(best[1],f64(time.duration_nanoseconds(time.tick_since(start)))/(ROUNDS*COUNT))
        start=time.tick_now()
        for _ in 0..<ROUNDS/4 {
            for i in 0..<COUNT {
                pen:=epa_penetration(gt_proxy(&boxes[i][0]),gt_proxy(&boxes[i][1]),{poses[i].p*0.15,poses[i].q})
                sum+=pen.depth
                if pass==0 && pen.ok {overlapping+=1}
            }
        }
        best[2]=min(best[2],f64(time.duration_nanoseconds(time.tick_since(start)))/(ROUNDS/4*COUNT))
    }
    log.infof("box-box: gjk_distance cold %.0f ns (%.2f iterations), warm %.0f ns; epa_penetration %.0f ns (%v%% overlapping); checksum %v",
        best[0],f64(iterations)/(ROUNDS*COUNT),best[1],best[2],overlapping*100/(ROUNDS/4*COUNT),sum)
}
}
