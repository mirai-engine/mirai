package geom

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "mirai:std/base"
import mm "mirai:std/math"

@(private) bytes_equal :: proc(a,b:[]$T) -> bool {
    return slice.equal(slice.to_bytes(a),slice.to_bytes(b))
}

@(private) hulls_equal :: proc(a,b:Hull) -> bool {
    return bytes_equal(a.vertices,b.vertices) && bytes_equal(a.sources,b.sources) && bytes_equal(a.planes,b.planes) &&
        bytes_equal(a.faces,b.faces) && bytes_equal(a.face_vertices,b.face_vertices) && bytes_equal(a.half_edges,b.half_edges)
}

@(private) Cloud :: enum {Box,Sphere_Surface,Ball,Grid,Slab,Clusters}

@(private) cloud_fill :: proc(points:[]Vec3,kind:Cloud,rng:^base.Rng,scale:f32=1,offset:Vec3={}) {
    for &p,i in points {
        switch kind {
        case .Box: p={mm.random_f32(rng)-0.5,mm.random_f32(rng)-0.5,mm.random_f32(rng)-0.5}
        case .Sphere_Surface:
            b:=mm.random_in_sphere(rng)
            l:=math.sqrt(b.x*b.x+b.y*b.y+b.z*b.z)
            p=b/l if l>1e-6 else Vec3{1,0,0}
        case .Ball: p=mm.random_in_sphere(rng)
        case .Grid: p={f32(base.rng_u32(rng)%5),f32(base.rng_u32(rng)%5),f32(base.rng_u32(rng)%5)}
        case .Slab: p={mm.random_f32(rng)-0.5,(mm.random_f32(rng)-0.5)*1e-3,mm.random_f32(rng)-0.5}
        case .Clusters:
            center:=Vec3{f32(i%3),f32(i%2),f32(i%5)}
            p=center+mm.random_in_sphere(rng)*0.01
        }
        p=p*scale+offset
    }
}

@(test)
hull_of_a_cube_has_six_quads :: proc(t:^testing.T) {
    points:[dynamic]Vec3
    defer delete(points)
    corners:=box_corners({-1,-1,-1},{1,1,1})
    // Interior points, points on faces and on edges, and every corner twice.
    rng:=base.rng_make(1)
    for _ in 0..<200 {append(&points,Vec3{mm.random_f32(&rng)*2-1,mm.random_f32(&rng)*2-1,mm.random_f32(&rng)*2-1}*0.99)}
    for i in 0..<100 {
        u,v:=f32(i%10)/5-0.9,f32(i/10)/5-0.9
        append(&points,Vec3{u,v,1},Vec3{u,-1,v},Vec3{1,u,v},Vec3{-1,u,v},Vec3{u,1,v},Vec3{u,v,-1})
        append(&points,Vec3{u,1,1},Vec3{-1,u,-1})
    }
    append(&points,..corners[:]);append(&points,..corners[:])
    hull,error:=hull_build(points[:])
    defer hull_destroy(&hull)
    testing.expect_value(t,error,Hull_Error.None)
    testing.expect_value(t,len(hull.vertices),8)
    testing.expect_value(t,len(hull.faces),6)
    testing.expect_value(t,hull_edge_count(hull),12)
    for face in hull.faces {testing.expect_value(t,face.vertex_count,u32(4))}
    testing.expect(t,hull_is_valid(hull,1e-5))
    mass:=hull_mass_properties(hull)
    testing.expectf(t,abs(mass.volume-8)<1e-4,"volume %v",mass.volume)
    for plane in hull.planes {
        testing.expectf(t,abs(plane.d-1)<1e-5 && abs(abs(plane.normal.x)+abs(plane.normal.y)+abs(plane.normal.z)-1)<1e-5,"plane %v",plane)
    }
}

@(test)
hull_reports_the_dimension_of_degenerate_input :: proc(t:^testing.T) {
    expect_error :: proc(t:^testing.T,points:[]Vec3,expected:Hull_Error,loc:=#caller_location) {
        hull,error:=hull_build(points)
        defer hull_destroy(&hull)
        testing.expect_value(t,error,expected,loc)
        testing.expect_value(t,len(hull.vertices),0,loc)
    }
    expect_error(t,{},.Too_Few_Points)
    expect_error(t,{{0,0,0},{1,0,0}},.Too_Few_Points)
    same:[16]Vec3
    for &p in same {p={3,4,5}}
    expect_error(t,same[:],.Coincident)
    line:[32]Vec3
    for &p,i in line {p=Vec3{1,2,-3}*f32(i)*0.37+{5,5,5}}
    expect_error(t,line[:],.Collinear)
}

@(test)
points_in_one_plane_give_a_flat_hull_of_two_faces :: proc(t:^testing.T) {
    expect_flat :: proc(t:^testing.T,points:[]Vec3,corners:int,normal:Vec3,desc:Hull_Desc={},loc:=#caller_location) {
        hull,error:=hull_build(points,desc)
        defer hull_destroy(&hull)
        testing.expect_value(t,error,Hull_Error.None,loc)
        testing.expect(t,hull_is_flat(hull) && len(hull.vertices)==corners && hull_edge_count(hull)==corners,"the polygon and its back",loc=loc)
        testing.expect(t,hull_is_valid(hull,tolerance_noise(positions_max_abs(points))),"valid",loc=loc)
        testing.expect(t,abs(abs(linalg.dot(hull.planes[0].normal,normal))-1)<1e-5 && hull.planes[1].normal==-hull.planes[0].normal,"faces along the normal",loc=loc)
        for v,i in hull.vertices {testing.expect(t,points[hull.sources[i]]==v,"vertices are input points",loc=loc)}
        extent:=positions_max_abs(points)
        // Only the noise of points off the plane: the two faces fan out from different corners.
        testing.expect(t,abs(hull_mass_properties(hull).volume)<=extent*extent*(4*desc.tolerance+1e-6*extent),"no volume",loc=loc)
    }
    expect_flat(t,{{0,0,0},{1,0,0},{0,1,0}},3,{0,0,1})
    // The corners of a grid; the points along its edges are no corners.
    plane:[64]Vec3
    for &p,i in plane {
        u,v:=f32(i%8),f32(i/8)
        p=Vec3{1,2,2}/3*u+Vec3{2,-2,1}/3*v+{10,0,0}
    }
    expect_flat(t,plane[:],4,linalg.cross(Vec3{1,2,2},Vec3{2,-2,1})/9)
    huge:[64]Vec3
    for &p,i in huge {p={f32(i%8)*1e6,f32(i/8)*1e6,0}}
    expect_flat(t,huge[:],4,{0,0,1})
    circle:[32]Vec3
    for &p,i in circle {
        angle:=f32(i)*math.TAU/32
        p={math.cos(angle),0.001*math.sin(f32(i)),math.sin(angle)}*5
    }
    expect_flat(t,circle[:],32,{0,1,0},{tolerance=0.01})
    expect_flat(t,circle[:],8,{0,1,0},{max_vertices=8,tolerance=0.01})
}

@(test)
hull_keeps_its_shape_at_tiny_and_huge_coordinates :: proc(t:^testing.T) {
    cases:=[?]struct {scale:f32,offset:Vec3}{{1e-4,{}},{1e5,{}},{16,{1e6,-1e6,1e6}},{1e-3,{1,2,3}}}
    for c in cases {
        corners:=box_corners(c.offset-c.scale,c.offset+c.scale)
        points:[dynamic]Vec3
        defer delete(points)
        append(&points,..corners[:])
        for i in 0..<64 {append(&points,c.offset+Vec3{f32(i%4)-1.5,f32(i/4%4)-1.5,f32(i/16)-1.5}*c.scale*0.6)}
        hull,error:=hull_build(points[:])
        defer hull_destroy(&hull)
        testing.expect_value(t,error,Hull_Error.None)
        testing.expectf(t,len(hull.vertices)==8 && len(hull.faces)==6,"scale %v: %d vertices, %d faces",c.scale,len(hull.vertices),len(hull.faces))
        testing.expect(t,hull_is_valid(hull,tolerance_noise(positions_max_abs(points[:]))))
        volume:=hull_mass_properties(hull).volume
        expected:=8*c.scale*c.scale*c.scale
        testing.expectf(t,abs(volume-expected)<=1e-3*expected,"scale %v: volume %v, expected %v",c.scale,volume,expected)
    }
}

@(test)
hull_bounded_by_max_vertices_stays_inside_the_full_hull :: proc(t:^testing.T) {
    points:[2000]Vec3
    rng:=base.rng_make(7)
    cloud_fill(points[:],.Sphere_Surface,&rng)
    full,_:=hull_build(points[:])
    defer hull_destroy(&full)
    testing.expect_value(t,len(full.vertices),len(points))
    full_volume:=hull_mass_properties(full).volume
    previous:f32
    for limit in ([?]int{4,8,16,32,64,255}) {
        hull,error:=hull_build(points[:],{max_vertices=limit})
        defer hull_destroy(&hull)
        testing.expect_value(t,error,Hull_Error.None)
        testing.expectf(t,len(hull.vertices)<=limit && len(hull.vertices)>=4,"limit %d gave %d vertices",limit,len(hull.vertices))
        testing.expect(t,hull_is_valid(hull,1e-5))
        for v in hull.vertices {testing.expect(t,hull_distance_outside(full,v)<=1e-5)}
        volume:=hull_mass_properties(hull).volume
        testing.expectf(t,volume>previous && volume<=full_volume,"limit %d: volume %v after %v of %v",limit,volume,previous,full_volume)
        previous=volume
    }
    testing.expectf(t,previous>0.9*full_volume,"255 vertices keep %v of %v",previous,full_volume)
}

@(test)
hull_contains_every_point_of_random_clouds :: proc(t:^testing.T) {
    rng:=base.rng_make(0x51ce)
    points:[dynamic]Vec3
    defer delete(points)
    for round in 0..<240 {
        kind:=Cloud(round%len(Cloud))
        count:=4+int(base.rng_u32(&rng)%400)
        scales:=[4]f32{1,1e-3,250,1e4}
        scale:=scales[round/len(Cloud)%4]
        offset:=Vec3{mm.random_f32(&rng),mm.random_f32(&rng),mm.random_f32(&rng)}*scale*(round%5==0?100:1)
        resize(&points,count)
        cloud_fill(points[:],kind,&rng,scale,offset)
        // Repeat a few points so that duplicates are always present.
        for i in 0..<count/8 {points[i*8]=points[i*8+1]}
        hull,error:=hull_build(points[:])
        defer hull_destroy(&hull)
        if error!=.None {
            testing.expectf(t,count<8 || kind==.Grid,"round %d (%v, %d points): %v",round,kind,count,error)
            continue
        }
        tolerance:=tolerance_noise(positions_max_abs(points[:]))
        testing.expectf(t,hull_is_valid(hull,tolerance*2),"round %d (%v, %d points): invalid hull",round,kind,count)
        worst:f32
        for p in points {worst=max(worst,hull_distance_outside(hull,p))}
        testing.expectf(t,worst<=tolerance*1.5,"round %d (%v, %d points): a point is %v outside, tolerance %v",round,kind,count,worst,tolerance)
        testing.expect(t,hull_mass_properties(hull).volume>0)
        again,_:=hull_build(points[:])
        defer hull_destroy(&again)
        testing.expectf(t,hulls_equal(hull,again),"round %d: two builds differ",round)
    }
}

@(test)
hull_merges_coplanar_triangles_into_polygons :: proc(t:^testing.T) {
    // A prism over a regular 12-gon: 2 caps of 12 corners and 12 quads.
    points:[24]Vec3
    for i in 0..<12 {
        s,c:=turn_sincos(f64(i)/12)
        points[i]={f32(c),-0.5,f32(s)}
        points[12+i]={f32(c),0.5,f32(s)}
    }
    hull,error:=hull_build(points[:])
    defer hull_destroy(&hull)
    testing.expect_value(t,error,Hull_Error.None)
    testing.expect_value(t,len(hull.vertices),24)
    testing.expect_value(t,len(hull.faces),14)
    testing.expect_value(t,hull_edge_count(hull),36)
    caps,quads:=0,0
    for face in hull.faces {
        if face.vertex_count==12 {caps+=1}
        if face.vertex_count==4 {quads+=1}
    }
    testing.expect_value(t,caps,2)
    testing.expect_value(t,quads,12)
    testing.expect(t,hull_is_valid(hull,1e-5))
    // Every half-edge and its twin separate two different faces that share both ends.
    for e,i in hull.half_edges {
        twin:=hull.half_edges[i~1]
        testing.expect(t,e.face!=twin.face && hull.half_edges[twin.next].origin==e.origin)
    }
}

@(test)
hull_mass_properties_match_a_box :: proc(t:^testing.T) {
    size:=Vec3{1,2,3}
    center:=Vec3{10,-4,7}
    corners:=box_corners(center-size*0.5,center+size*0.5)
    hull,_:=hull_build(corners[:])
    defer hull_destroy(&hull)
    mass:=hull_mass_properties(hull)
    testing.expectf(t,abs(mass.volume-6)<1e-4,"volume %v",mass.volume)
    for k in 0..<3 {testing.expectf(t,abs(mass.center[k]-center[k])<1e-4,"center %v",mass.center)}
    expected:=[3]f32{6.0/12*(4+9),6.0/12*(1+9),6.0/12*(1+4)}
    for i in 0..<3 {
        for j in 0..<3 {
            want:=expected[i] if i==j else 0
            testing.expectf(t,abs(mass.inertia[i,j]-want)<1e-3,"inertia[%d,%d]=%v, expected %v",i,j,mass.inertia[i,j],want)
        }
    }
}

@(test)
mesh_mass_properties_match_a_tetrahedron_and_flip_with_the_winding :: proc(t:^testing.T) {
    positions:=[]Vec3{{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
    indices:=[]u32{0,2,1, 0,1,3, 0,3,2, 1,2,3}
    mass:=mesh_mass_properties(positions,indices)
    testing.expectf(t,abs(mass.volume-1.0/6)<1e-6,"volume %v",mass.volume)
    for k in 0..<3 {testing.expectf(t,abs(mass.center[k]-0.25)<1e-6,"center %v",mass.center)}
    // Unit right tetrahedron about its center of mass: 3/40 of the mass on the
    // diagonal and 1/80 off it.
    for i in 0..<3 {
        for j in 0..<3 {
            want:=f32(1.0/6)*(3.0/40 if i==j else 1.0/80)
            testing.expectf(t,abs(mass.inertia[i,j]-want)<1e-6,"inertia[%d,%d]=%v, expected %v",i,j,mass.inertia[i,j],want)
        }
    }
    flipped:=[]u32{0,1,2, 0,3,1, 0,2,3, 1,3,2}
    inside_out:=mesh_mass_properties(positions,flipped)
    testing.expectf(t,abs(inside_out.volume+1.0/6)<1e-6,"volume %v",inside_out.volume)
    testing.expect(t,inside_out.inertia[0,0]>0)
    empty:=mesh_mass_properties(nil,nil)
    testing.expect_value(t,empty.volume,0)
}

@(test)
hull_of_a_lattice_is_its_bounding_box :: proc(t:^testing.T) {
    points:[dynamic]Vec3
    defer delete(points)
    for x in 0..<6 {for y in 0..<5 {for z in 0..<4 {append(&points,Vec3{f32(x),f32(y),f32(z)}*0.37+{100,-50,3})}}}
    hull,error:=hull_build(points[:])
    defer hull_destroy(&hull)
    testing.expect_value(t,error,Hull_Error.None)
    testing.expect_value(t,len(hull.vertices),8)
    testing.expect_value(t,len(hull.faces),6)
    testing.expect(t,hull_is_valid(hull,tolerance_noise(110)))
    volume:=hull_mass_properties(hull).volume
    testing.expectf(t,abs(volume-5*4*3*0.37*0.37*0.37)<1e-3,"volume %v",volume)
    testing.expectf(t,abs(points_hull_volume(points[:])-volume)<1e-4,"volume of the points %v",points_hull_volume(points[:]))
    testing.expect_value(t,points_hull_volume(points[:3]),0)
}

@(test)
hull_keeps_points_beside_thin_faces :: proc(t:^testing.T) {
    // A plate 1000 times wider than thick: almost every point is within the
    // tolerance of the planes of the first tetrahedron but far beside it.
    rng:=base.rng_make(99)
    points:[600]Vec3
    for &p in points {p={mm.random_f32(&rng)*200,mm.random_f32(&rng)*0.2+3000,mm.random_f32(&rng)*200}}
    tolerance:=tolerance_noise(positions_max_abs(points[:]))
    hull,error:=hull_build(points[:])
    defer hull_destroy(&hull)
    testing.expect_value(t,error,Hull_Error.None)
    testing.expect(t,hull_is_valid(hull,tolerance))
    for p in points {testing.expect(t,hull_distance_outside(hull,p)<=tolerance*1.5)}
    volume:=hull_mass_properties(hull).volume
    testing.expectf(t,volume>0.8*200*200*0.2 && volume<=200*200*0.2,"volume %v",volume)
}
