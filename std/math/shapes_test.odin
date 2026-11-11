package mirai_math

import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:std/base"

@(private="file") DEG :: f32(RAD_PER_DEG)

@(test)
aabb_merges_measures_and_contains :: proc(t:^testing.T) {
    a:=Aabb{{0,0,0},{1,2,3}}
    b:=aabb_from_center({4,0,0},{1,1,1})
    testing.expect_value(t,b,Aabb{{3,-1,-1},{5,1,1}})
    merged:=aabb_merge(a,b)
    testing.expect_value(t,merged,Aabb{{0,-1,-1},{5,2,3}})
    testing.expect_value(t,aabb_merge(AABB_EMPTY,a),a)
    testing.expect_value(t,aabb_center(a),Vec3{0.5,1,1.5})
    testing.expect_value(t,aabb_half(a),Vec3{0.5,1,1.5})
    testing.expect_value(t,aabb_size(a),Vec3{1,2,3})
    testing.expect_value(t,aabb_surface_area(a),f32(22))
    testing.expect_value(t,aabb_volume(a),f32(6))
    testing.expect(t,aabb_is_empty(AABB_EMPTY) && !aabb_is_empty(a))
    testing.expect_value(t,aabb_surface_area(AABB_EMPTY),f32(0))
    testing.expect_value(t,aabb_volume(AABB_EMPTY),f32(0))
    testing.expect_value(t,aabb_add_point(a,{-1,5,1}),Aabb{{-1,0,0},{1,5,3}})
    testing.expect_value(t,aabb_expand(a,0.5),Aabb{{-0.5,-0.5,-0.5},{1.5,2.5,3.5}})
    points:=[3]Vec3{{1,5,-2},{-3,0,4},{2,2,2}}
    testing.expect_value(t,aabb_from_points(points[:]),Aabb{{-3,0,-2},{2,5,4}})
    testing.expect(t,aabb_is_empty(aabb_from_points(nil)))
    testing.expect(t,aabb_contains_point(a,{1,2,3}) && aabb_contains_point(a,{0.5,1,1}) && !aabb_contains_point(a,{0.5,2.1,1}))
    testing.expect(t,aabb_contains(merged,a) && aabb_contains(a,a) && !aabb_contains(a,merged))
    testing.expect_value(t,aabb_from_sphere({{1,1,1},2}),Aabb{{-1,-1,-1},{3,3,3}})
    testing.expect_value(t,aabb_from_capsule({{0,0,0},{0,4,0},1}),Aabb{{-1,-1,-1},{1,5,1}})
}

@(test)
aabb_transform_encloses_every_transformed_corner :: proc(t:^testing.T) {
    box:=Aabb{{-1,-2,-3},{2,1,0.5}}
    rng:=base.rng_make(4)
    for _ in 0..<50 {
        angles:=Vec3{random_range(&rng,-PI,PI),random_range(&rng,-PI,PI),random_range(&rng,-PI,PI)}
        scale:=Vec3{random_range(&rng,0.2,3),random_range(&rng,-3,-0.2),random_range(&rng,0.2,3)}
        m:=transform_matrix(transform_from_euler({random_range(&rng,-5,5),1,2},angles,scale))
        moved:=aabb_transform(box,m)
        exact:=AABB_EMPTY
        for corner in 0..<8 {
            p:=Vec3{box.max.x if corner&1!=0 else box.min.x,box.max.y if corner&2!=0 else box.min.y,box.max.z if corner&4!=0 else box.min.z}
            exact=aabb_add_point(exact,mat4_point(m,p))
        }
        // The result is the tight box of the eight corners.
        if !test_close3(moved.min,exact.min,1e-3) || !test_close3(moved.max,exact.max,1e-3) {testing.expectf(t,false,"%v, expected %v",moved,exact);break}
    }
    testing.expect(t,aabb_is_empty(aabb_transform(AABB_EMPTY,MAT4_IDENTITY)))
    turned:=aabb_from_obb({{1,0,0},quat_axis_angle({0,0,1},45*DEG),{1,1,1}})
    root:=f32(math.SQRT_TWO)
    testing.expect(t,test_close3(turned.min,{1-root,-root,-1}) && test_close3(turned.max,{1+root,root,1}))
}

@(test)
planes_measure_signed_distance :: proc(t:^testing.T) {
    floor:=plane_from_point({0,2,0},{0,5,0})
    testing.expect_value(t,floor.normal,Vec3{0,1,0})
    testing.expect_value(t,plane_distance(floor,{7,5,-3}),f32(3))
    testing.expect_value(t,plane_distance(floor,{0,0,0}),f32(-2))
    testing.expect_value(t,closest_point_plane({7,5,-3},floor),Vec3{7,2,-3})
    wall:=plane_from_points({0,0,0},{1,0,0},{0,1,0})
    testing.expect(t,test_close3(wall.normal,{0,0,1}),"Counter-clockwise points give the front normal")
    testing.expect(t,test_close(plane_distance(wall,{3,3,2}),2))
}

@(test)
ray_hits_planes_from_either_side :: proc(t:^testing.T) {
    floor:=plane_from_point({0,1,0},{0,1,0})
    distance,hit:=ray_plane({{0,5,0},{0,-2,0}},floor)
    testing.expect(t,hit && test_close(distance,2),"t is in units of the direction")
    distance,hit=ray_plane({{0,-5,0},{0,1,0}},floor)
    testing.expect(t,hit && test_close(distance,6))
    _,hit=ray_plane({{0,5,0},{0,1,0}},floor)
    testing.expect(t,!hit,"The plane is behind the ray")
    _,hit=ray_plane({{0,5,0},{1,0,0}},floor)
    testing.expect(t,!hit,"The ray is parallel to the plane")
}

@(test)
ray_hits_boxes_on_the_face_it_enters :: proc(t:^testing.T) {
    box:=Aabb{{-1,-1,-1},{1,1,1}}
    distance,normal,hit:=ray_aabb({{-5,0.5,0},{1,0,0}},box)
    testing.expect(t,hit && test_close(distance,4))
    testing.expect_value(t,normal,Vec3{-1,0,0})
    distance,normal,hit=ray_aabb({{0.2,6,0.3},{0,-2,0}},box)
    testing.expect(t,hit && test_close(distance,2.5))
    testing.expect_value(t,normal,Vec3{0,1,0})
    distance,normal,hit=ray_aabb({{0,0,0},{0,0,1}},box)
    testing.expect(t,hit && test_close(distance,1),"From inside, the hit is where the ray leaves")
    testing.expect_value(t,normal,Vec3{0,0,1})
    _,_,hit=ray_aabb({{-5,0,0},{-1,0,0}},box)
    testing.expect(t,!hit,"The box is behind")
    _,_,hit=ray_aabb({{-5,2,0},{1,0,0}},box)
    testing.expect(t,!hit,"A parallel ray outside the slab")
    _,_,hit=ray_aabb({{-5,0,0},{1,0.5,0}},box)
    testing.expect(t,!hit)
    _,_,hit=ray_aabb({{0,0,0},{}},box)
    testing.expect(t,!hit,"A ray without direction hits nothing")
    // The traversal form agrees.
    direction:=Vec3{1,0.1,-0.2}
    slow,_,_:=ray_aabb({{-5,0.5,0},direction},box)
    fast,fast_hit:=ray_aabb_fast({-5,0.5,0},1/direction,box,100)
    testing.expect(t,fast_hit && test_close(fast,slow))
    _,fast_hit=ray_aabb_fast({-5,0.5,0},1/direction,box,3)
    testing.expect(t,!fast_hit,"Farther than the limit")
    _,fast_hit=ray_aabb_fast({-5,5,0},1/direction,box,100)
    testing.expect(t,!fast_hit)
    inside,inside_hit:=ray_aabb_fast({0,0,0},1/direction,box,100)
    testing.expect(t,inside_hit && inside==0)
    // A turned box, hit on its slanted face.
    obb:=Obb{{0,0,0},quat_axis_angle({0,0,1},45*DEG),{1,1,1}}
    distance,normal,hit=ray_obb({{-5,0,0},{1,0,0}},obb)
    testing.expect(t,hit && test_close(distance,5-f32(math.SQRT_TWO)))
    testing.expect(t,abs(normal.x)>0.7 && normal.x<0 && test_close(linalg.length(normal),1))
    _,_,hit=ray_obb({{-5,1.3,0},{1,0,0}},obb)
    testing.expect(t,hit,"The corner reaches where the unturned box does not")
    _,_,hit=ray_obb({{-5,1.5,0},{1,0,0}},obb)
    testing.expect(t,!hit)
}

@(test)
ray_hits_spheres_and_capsules :: proc(t:^testing.T) {
    sphere:=Sphere{{0,0,-10},2}
    distance,normal,hit:=ray_sphere({{0,0,0},{0,0,-1}},sphere)
    testing.expect(t,hit && test_close(distance,8) && test_close3(normal,{0,0,1}))
    distance,_,hit=ray_sphere({{0,0,0},{0,0,-4}},sphere)
    testing.expect(t,hit && test_close(distance,2),"t is in units of the direction")
    distance,normal,hit=ray_sphere({{0,0,-10},{1,0,0}},sphere)
    testing.expect(t,hit && test_close(distance,2) && test_close3(normal,{1,0,0}),"From inside, the far side")
    _,_,hit=ray_sphere({{0,0,0},{0,0,1}},sphere)
    testing.expect(t,!hit)
    _,_,hit=ray_sphere({{0,2.1,0},{0,0,-1}},sphere)
    testing.expect(t,!hit)
    _,_,hit=ray_sphere({{0,0,0},{}},sphere)
    testing.expect(t,!hit)

    capsule:=Capsule{{0,0,0},{0,4,0},1}
    distance,normal,hit=ray_capsule({{-5,2,0},{1,0,0}},capsule)
    testing.expect(t,hit && test_close(distance,4) && test_close3(normal,{-1,0,0}),"The side")
    distance,normal,hit=ray_capsule({{0,10,0},{0,-1,0}},capsule)
    testing.expect(t,hit && test_close(distance,5) && test_close3(normal,{0,1,0}),"Along the axis, the top end")
    distance,normal,hit=ray_capsule({{0,-10,0},{0,2,0}},capsule)
    testing.expect(t,hit && test_close(distance,4.5) && test_close3(normal,{0,-1,0}),"The bottom end, in units of the direction")
    distance,normal,hit=ray_capsule({{-5,-0.5,0},{1,0,0}},capsule)
    expected:=5-math.sqrt(f32(0.75))
    testing.expect(t,hit && test_close(distance,expected) && normal.y<0 && normal.x<0,"The round part of the bottom end")
    distance,_,hit=ray_capsule({{0,2,0},{1,0,0}},capsule)
    testing.expect(t,hit && test_close(distance,1),"From inside, where the ray leaves")
    distance,_,hit=ray_capsule({{0,2,0},{0,1,0}},capsule)
    testing.expect(t,hit && test_close(distance,3))
    _,_,hit=ray_capsule({{-5,5.1,0},{1,0,0}},capsule)
    testing.expect(t,!hit)
    _,_,hit=ray_capsule({{-5,2,0},{-1,0,0}},capsule)
    testing.expect(t,!hit)
    _,_,hit=ray_capsule({{2,10,0},{0,-1,0}},capsule)
    testing.expect(t,!hit,"Parallel to the axis and outside")
    distance,_,hit=ray_capsule({{-5,0,0},{1,0,0}},{{0,0,0},{0,0,0},1})
    testing.expect(t,hit && test_close(distance,4),"A capsule without length is a sphere")
    // Every hit lies on the surface: at the radius from the segment.
    rng:=base.rng_make(8)
    slanted:=Capsule{{-1,0,2},{3,2,-1},0.75}
    hits:=0
    for _ in 0..<300 {
        origin:=random_in_sphere(&rng)*8
        target:=Vec3{1,1,0.5}+random_in_sphere(&rng)*2
        ray:=Ray{origin,target-origin}
        where_,_,ok:=ray_capsule(ray,slanted)
        if !ok {continue}
        hits+=1
        closest,_:=closest_point_segment(ray_at(ray,where_),{slanted.a,slanted.b})
        if !test_close(linalg.length(ray_at(ray,where_)-closest),slanted.radius,2e-3) {testing.expectf(t,false,"hit at distance %v of the axis",linalg.length(ray_at(ray,where_)-closest));break}
    }
    testing.expect(t,hits>50)
}

@(test)
ray_hits_triangles_on_both_faces :: proc(t:^testing.T) {
    triangle:=Triangle{{0,0,0},{2,0,0},{0,2,0}}
    distance,uv,hit:=ray_triangle({{0.5,0.5,5},{0,0,-1}},triangle)
    testing.expect(t,hit && test_close(distance,5))
    testing.expect(t,linalg.length(uv-Vec2{0.25,0.25})<1e-5)
    distance,_,hit=ray_triangle({{0.5,0.5,-5},{0,0,2}},triangle)
    testing.expect(t,hit && test_close(distance,2.5),"The back face, in units of the direction")
    _,_,hit=ray_triangle({{1.5,1.5,5},{0,0,-1}},triangle)
    testing.expect(t,!hit,"Outside the slanted edge")
    _,_,hit=ray_triangle({{0.5,0.5,5},{0,0,1}},triangle)
    testing.expect(t,!hit,"Behind the ray")
    _,_,hit=ray_triangle({{0.5,0.5,5},{1,0,0}},triangle)
    testing.expect(t,!hit,"Parallel to the triangle")
    testing.expect_value(t,triangle_normal(triangle),Vec3{0,0,1})
    testing.expect_value(t,triangle_normal({{0,0,0},{1,0,0},{2,0,0}}),Vec3{})
}

// Four triangles around a corner they share, on a tilted plane: a ray through
// that corner or through an edge two of them share, at any angle down to
// grazing, meets one of them and never passes between.
@(test)
ray_meets_triangles_through_their_shared_edges_and_corner :: proc(t:^testing.T) {
    center:=Vec3{0.37,1.13,-2.71}
    u,v:=Vec3{0.83,0.21,-0.44},Vec3{-0.17,0.91,0.35}
    corners:=[4]Vec3{center+u+v,center-u+v,center-u-v,center+u-v}
    normal:=linalg.normalize(linalg.cross(u,v))
    rng:=rng_make(2013)
    missed:=0
    for ray in 0..<20000 {
        edge:=ray%4
        target:=center if ray%5==0 else center+(corners[edge]-center)*random_range(&rng,0.01,0.99)
        along:=random_unit_vec3(&rng)
        along=linalg.normalize(along-normal*linalg.dot(along,normal))
        rise:=random_range(&rng,0.3,90)*DEG
        side:=f32(1) if ray%2==0 else -1
        from:=target+(along*math.cos(rise)+normal*side*math.sin(rise))*random_range(&rng,0.5,50)
        direction:=linalg.normalize(target-from)
        met:=false
        for k in 0..<4 {
            _,_,hit:=ray_triangle({from,direction},{center,corners[k],corners[(k+1)%4]})
            met||=hit
        }
        if !met {missed+=1}
    }
    testing.expectf(t,missed==0,"%d of 20000 rays through a shared edge or corner passed between the triangles",missed)
}

@(test)
ray_is_clipped_by_a_frustum :: proc(t:^testing.T) {
    frustum:=frustum_from_matrix(perspective(90*DEG,1,1,100)*look_at({},{0,0,-1},{0,1,0}))
    enter,exit,hit:=ray_frustum({{0,0,0},{0,0,-1}},frustum)
    testing.expect(t,hit && test_close(enter,1,1e-3) && test_close(exit,100,1e-2))
    enter,exit,hit=ray_frustum({{-100,0,-50},{1,0,0}},frustum)
    testing.expect(t,hit && test_close(enter,50,1e-2) && test_close(exit,150,1e-2))
    enter,_,hit=ray_frustum({{0,0,-50},{1,0,0}},frustum)
    testing.expect(t,hit && enter==0,"A ray that starts inside enters at once")
    _,_,hit=ray_frustum({{0,0,5},{0,0,1}},frustum)
    testing.expect(t,!hit)
    _,_,hit=ray_frustum({{-100,0,-200},{1,0,0}},frustum)
    testing.expect(t,!hit,"Parallel to the far plane, beyond it")
}

@(test)
lines_report_their_closest_parameters :: proc(t:^testing.T) {
    s,u,ok:=line_line_closest({0,0,0},{1,0,0},{3,5,2},{0,0,1})
    testing.expect(t,ok && test_close(s,3) && test_close(u,-2))
    s,u,ok=line_line_closest({0,0,0},{2,0,0},{3,5,2},{0,0,-4})
    testing.expect(t,ok && test_close(s,1.5) && test_close(u,0.5),"Parameters are in units of each direction")
    _,_,ok=line_line_closest({0,0,0},{1,0,0},{0,1,0},{-2,0,0})
    testing.expect(t,!ok,"Parallel lines")
    _,_,ok=line_line_closest({0,0,0},{},{0,1,0},{1,0,0})
    testing.expect(t,!ok)
}

@(test)
shapes_report_overlap :: proc(t:^testing.T) {
    box:=Aabb{{0,0,0},{2,2,2}}
    testing.expect(t,aabb_overlaps(box,{{1,1,1},{3,3,3}}))
    testing.expect(t,aabb_overlaps(box,{{2,0,0},{3,1,1}}),"Touching counts")
    testing.expect(t,!aabb_overlaps(box,{{2.1,0,0},{3,1,1}}))
    testing.expect(t,!aabb_overlaps(box,{{0,0,-3},{2,2,-0.1}}))
    testing.expect(t,sphere_overlaps({{0,0,0},1},{{1.5,0,0},0.5}) && !sphere_overlaps({{0,0,0},1},{{1.6,0,0},0.5}))
    testing.expect(t,sphere_overlaps_aabb({{1,1,1},0.1},box),"A sphere inside the box")
    testing.expect(t,sphere_overlaps_aabb({{3,1,1},1},box) && !sphere_overlaps_aabb({{3.1,1,1},1},box))
    // Near a corner the distance is to the corner, not to the faces.
    testing.expect(t,!sphere_overlaps_aabb({{2.8,2.8,1},1},box) && sphere_overlaps_aabb({{2.7,2.7,1},1},box))
    frustum:=frustum_from_matrix(perspective(90*DEG,1,1,100)*look_at({},{0,0,-1},{0,1,0}))
    testing.expect(t,frustum_overlaps_aabb(frustum,{{-1,-1,-11},{1,1,-9}}))
    testing.expect(t,frustum_overlaps_aabb(frustum,{{-12,-1,-11},{-9,1,-9}}),"Across the left plane")
    testing.expect(t,!frustum_overlaps_aabb(frustum,{{-14,-1,-11},{-12,1,-9}}))
    testing.expect(t,!frustum_overlaps_aabb(frustum,{{-1,-1,1},{1,1,3}}),"Behind the camera")
    testing.expect(t,!frustum_overlaps_aabb(frustum,{{-1,-1,-120},{1,1,-101}}))
    testing.expect(t,frustum_overlaps_aabb(frustum,{{-1000,-1000,-1000},{1000,1000,1000}}),"A box around the whole frustum")
    testing.expect(t,frustum_overlaps_sphere(frustum,{{0,0,-10},1}))
    testing.expect(t,frustum_overlaps_sphere(frustum,{{-11,0,-10},1}) && !frustum_overlaps_sphere(frustum,{{-12,0,-10},1}))
    testing.expect(t,!frustum_overlaps_sphere(frustum,{{0,0,2},1}) && frustum_overlaps_sphere(frustum,{{0,0,0},1.1}))
}

@(test)
oriented_boxes_separate_on_faces_and_edges :: proc(t:^testing.T) {
    unit:=Obb{{0,0,0},QUAT_IDENTITY,{1,1,1}}
    testing.expect(t,obb_overlaps(unit,{{1.9,0,0},QUAT_IDENTITY,{1,1,1}}))
    testing.expect(t,!obb_overlaps(unit,{{2.1,0,0},QUAT_IDENTITY,{1,1,1}}))
    turned:=quat_axis_angle({0,0,1},45*DEG)
    // A box turned 45 degrees reaches sqrt(2) with its corner.
    testing.expect(t,obb_overlaps(unit,{{2.3,0,0},turned,{1,1,1}}))
    testing.expect(t,!obb_overlaps(unit,{{2.5,0,0},turned,{1,1,1}}))
    // Two bars crossed in the air: only the cross product of their edges separates them.
    a:=Obb{{0,0,0},QUAT_IDENTITY,{5,0.1,0.1}}
    b:=Obb{{0,0.25,0},quat_axis_angle({0,1,0},60*DEG),{5,0.1,0.1}}
    testing.expect(t,!obb_overlaps(a,b))
    b.center.y=0.15
    testing.expect(t,obb_overlaps(a,b))
    edge_a:=Obb{{0,0,0},quat_axis_angle({0,0,1},45*DEG),{1,1,1}}
    edge_b:=Obb{{2.9,0,0},quat_from_euler(Vec3{45,0,45}*DEG),{1,1,1}}
    testing.expect(t,obb_overlaps(edge_a,{{2.7,0,0},quat_axis_angle({0,0,1},45*DEG),{1,1,1}}))
    testing.expect(t,!obb_overlaps(edge_a,edge_b))
    // Agreement with a brute force test on random pairs: boxes are apart when sampled points of one are all outside the other.
    rng:=base.rng_make(21)
    for _ in 0..<200 {
        first:=Obb{random_in_sphere(&rng)*2,random_quat(&rng),{random_range(&rng,0.2,1.5),random_range(&rng,0.2,1.5),random_range(&rng,0.2,1.5)}}
        second:=Obb{random_in_sphere(&rng)*2,random_quat(&rng),{random_range(&rng,0.2,1.5),random_range(&rng,0.2,1.5),random_range(&rng,0.2,1.5)}}
        touching:=false
        sample: for x in 0..=6 {for y in 0..=6 {for z in 0..=6 {
            local:=(Vec3{f32(x),f32(y),f32(z)}/3-1)*first.half
            point:=first.center+quat_rotate(first.rotation,local)
            if linalg.length(closest_point_obb(point,second)-point)<1e-5 {touching=true;break sample}
        }}}
        if touching && !obb_overlaps(first,second) {testing.expect(t,false,"Boxes that share a point were reported apart");break}
        if obb_overlaps(first,second)!=obb_overlaps(second,first) {testing.expect(t,false,"The test is not symmetric");break}
    }
}

@(test)
closest_points_clamp_to_the_shape :: proc(t:^testing.T) {
    box:=Aabb{{0,0,0},{2,2,2}}
    testing.expect_value(t,closest_point_aabb({3,1,-1},box),Vec3{2,1,0})
    testing.expect_value(t,closest_point_aabb({1,1,1},box),Vec3{1,1,1})
    obb:=Obb{{0,0,0},quat_axis_angle({0,0,1},45*DEG),{1,1,1}}
    testing.expect(t,test_close3(closest_point_obb({5,0,0},obb),{f32(math.SQRT_TWO),0,0}),"The corner of the turned box")
    testing.expect(t,test_close3(closest_point_obb({0.2,0.1,0},obb),{0.2,0.1,0}))
    segment:=Segment{{0,0,0},{4,0,0}}
    point,where_:=closest_point_segment({1,3,0},segment)
    testing.expect(t,test_close3(point,{1,0,0}) && test_close(where_,0.25))
    point,where_=closest_point_segment({-2,1,0},segment)
    testing.expect(t,point=={0,0,0} && where_==0)
    point,where_=closest_point_segment({9,1,0},segment)
    testing.expect(t,point=={4,0,0} && where_==1)
    point,where_=closest_point_segment({9,1,0},{{1,1,1},{1,1,1}})
    testing.expect(t,point=={1,1,1} && where_==0)
}

@(test)
segments_report_their_closest_pair :: proc(t:^testing.T) {
    a:=Segment{{0,0,0},{4,0,0}}
    on_a,on_b,s,u:=closest_segment_segment(a,{{2,-1,3},{2,5,3}})
    testing.expect(t,test_close3(on_a,{2,0,0}) && test_close3(on_b,{2,0,3}) && test_close(s,0.5) && test_close(u,1.0/6))
    on_a,on_b,s,u=closest_segment_segment(a,{{6,1,0},{9,5,0}})
    testing.expect(t,test_close3(on_a,{4,0,0}) && test_close3(on_b,{6,1,0}) && s==1 && u==0,"End to end")
    on_a,on_b,_,_=closest_segment_segment(a,{{1,2,0},{3,2,0}})
    testing.expect(t,test_close(linalg.length(on_a-on_b),2),"Parallel segments: any closest pair")
    on_a,on_b,_,_=closest_segment_segment(a,{{2,1,1},{2,1,1}})
    testing.expect(t,test_close3(on_a,{2,0,0}) && test_close3(on_b,{2,1,1}),"A segment without length is a point")
    on_a,on_b,_,_=closest_segment_segment({{1,1,1},{1,1,1}},a)
    testing.expect(t,test_close3(on_a,{1,1,1}) && test_close3(on_b,{1,0,0}))
    on_a,on_b,s,u=closest_segment_segment({{1,1,1},{1,1,1}},{{2,2,2},{2,2,2}})
    testing.expect(t,on_a=={1,1,1} && on_b=={2,2,2} && s==0 && u==0)
    // No sampled pair is closer than the reported one.
    rng:=base.rng_make(13)
    for _ in 0..<100 {
        first:=Segment{random_in_sphere(&rng)*3,random_in_sphere(&rng)*3}
        second:=Segment{random_in_sphere(&rng)*3,random_in_sphere(&rng)*3}
        p,q,_,_:=closest_segment_segment(first,second)
        best:=linalg.length(p-q)
        for i in 0..=20 {
            sample:=first.a+(first.b-first.a)*(f32(i)/20)
            near,_:=closest_point_segment(sample,second)
            if linalg.length(sample-near)<best-1e-3 {testing.expectf(t,false,"%v is closer than the reported %v",linalg.length(sample-near),best);return}
        }
    }
}

@(test)
closest_point_on_a_triangle_covers_faces_edges_and_corners :: proc(t:^testing.T) {
    triangle:=Triangle{{0,0,0},{4,0,0},{0,4,0}}
    testing.expect(t,test_close3(closest_point_triangle({1,1,5},triangle),{1,1,0}),"Above the face")
    testing.expect(t,test_close3(closest_point_triangle({-1,-1,2},triangle),{0,0,0}),"Corner a")
    testing.expect(t,test_close3(closest_point_triangle({6,-1,0},triangle),{4,0,0}),"Corner b")
    testing.expect(t,test_close3(closest_point_triangle({-1,7,0},triangle),{0,4,0}),"Corner c")
    testing.expect(t,test_close3(closest_point_triangle({2,-3,1},triangle),{2,0,0}),"Edge ab")
    testing.expect(t,test_close3(closest_point_triangle({-2,1,1},triangle),{0,1,0}),"Edge ac")
    testing.expect(t,test_close3(closest_point_triangle({3,3,-1},triangle),{2,2,0}),"Edge bc")
    // No sampled point of the triangle is closer.
    rng:=base.rng_make(17)
    slanted:=Triangle{{1,0,-2},{-2,3,1},{0.5,-1,4}}
    for _ in 0..<200 {
        point:=random_in_sphere(&rng)*6
        closest:=closest_point_triangle(point,slanted)
        best:=linalg.length(point-closest)
        for i in 0..=12 {for j in 0..=12-i {
            u,v:=f32(i)/12,f32(j)/12
            sample:=slanted.a+(slanted.b-slanted.a)*u+(slanted.c-slanted.a)*v
            if linalg.length(point-sample)<best-1e-3 {testing.expectf(t,false,"%v is closer than the reported %v",linalg.length(point-sample),best);return}
        }}
        testing.expect(t,abs(plane_distance(plane_from_points(slanted.a,slanted.b,slanted.c),closest))<1e-3,"The closest point is on the plane of the triangle")
    }
}
