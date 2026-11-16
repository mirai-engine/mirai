package mirai_physics

import "core:testing"
import cmath "core:math"

@(private="file")
cube_hull :: proc(w:^World,half:f32,convex_radius:f32) -> (Hull_Handle,bool) {
    vertices:[8]Vec3
    for &v,i in vertices {v={i&1!=0?half:-half,i&2!=0?half:-half,i&4!=0?half:-half}}
    counts:=BOX_FACE_COUNTS
    indices:=BOX_FACE_INDICES
    return hull_create(w,{vertices[:],counts[:],indices[:]},convex_radius)
}

@(test)
hull_cores_move_every_face_in_by_the_convex_radius :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    cube,ok:=cube_hull(&w,0.5,0.1)
    testing.expect(t,ok)
    slot,_:=hull_slot(&w,cube)
    hull:=&slot.hull
    testing.expect(t,hull.core!=nil)
    expect_near(t,hull.convex_radius,0.1)
    testing.expect_value(t,len(hull.core.vertices),8)
    testing.expect_value(t,len(hull.core.planes),6)
    for plane in hull.core.planes {expect_near(t,plane.d,0.4,1e-4)}
    for v in hull.core.vertices {expect_near3(t,vabs(v),{0.4,0.4,0.4},1e-4)}
    // The outside is the hull as given: its bounds and its mass do not change.
    expect_near3(t,hull.aabb.max,{0.5,0.5,0.5})
    expect_near(t,hull.volume,1,1e-4)
    // Vertices where four faces meet split into new edges of the core.
    octahedron:=[6]Vec3{{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}
    counts:=[8]u8{3,3,3,3,3,3,3,3}
    indices:=[24]u8{0,2,4, 2,1,4, 1,3,4, 3,0,4, 2,0,5, 1,2,5, 3,1,5, 0,3,5}
    rounded,rounded_ok:=hull_create(&w,{octahedron[:],counts[:],indices[:]},0.1)
    testing.expect(t,rounded_ok)
    slot,_=hull_slot(&w,rounded)
    distance:=1/cmath.sqrt(f32(3))
    testing.expect_value(t,len(slot.hull.core.planes),8)
    for plane in slot.hull.core.planes {expect_near(t,plane.d,distance-0.1,1e-4)}
    for v in slot.hull.core.vertices {
        for plane in slot.hull.planes {testing.expect(t,plane_distance(plane,v)<=-0.1+1e-4)}
    }
    // The radius must leave a core: less than the distance from the center to the nearest face.
    _,too_round:=cube_hull(&w,0.5,0.5)
    testing.expect(t,!too_round)
    _,negative:=cube_hull(&w,0.5,-0.1)
    testing.expect(t,!negative)
    sharp,sharp_ok:=cube_hull(&w,0.5,0)
    testing.expect(t,sharp_ok)
    slot,_=hull_slot(&w,sharp)
    testing.expect(t,slot.hull.core==nil)
}

@(test)
a_convex_radius_rounds_the_edges_and_keeps_the_size :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    cube,_:=cube_hull(&w,0.5,0.1)
    shapes:=[3]Body_Handle{
        test_shape_body(&w,Box{{0.5,0.5,0.5}},{0,0,0},convex_radius=0.1,type=.Static),
        test_shape_body(&w,cube,{0,0,4},type=.Static),
        test_shape_body(&w,Box{{0.5,0.5,0.5}},{0,0,8},type=.Static),
    }
    corner:=0.4+0.1/cmath.sqrt(f32(3))
    for body,i in shapes {
        offset:=Vec3{0,0,4*f32(i)}
        face,face_ok:=ray_cast_closest(&w,offset+{0.2,2,0.1},{0,-4,0})
        testing.expect(t,face_ok && face.body==body)
        expect_near(t,face.point.y,0.5,1e-3)
        expect_near3(t,face.normal,{0,1,0},1e-3)
        diagonal,diagonal_ok:=ray_cast_closest(&w,offset+{2,2,2},{-4,-4,-4})
        testing.expect(t,diagonal_ok && diagonal.body==body)
        if i<2 {
            expect_near3(t,diagonal.point-offset,{corner,corner,corner},1e-3)
            expect_near3(t,diagonal.normal,normalize(Vec3{1,1,1}),1e-3)
        } else {
            expect_near3(t,diagonal.point-offset,{0.5,0.5,0.5},1e-3)
        }
    }
    rim,rim_ok:=shape_ray_cast(&w,shape_handle(&w,test_first_shape(&w,test_shape_body(&w,Cylinder{0.4,0.5},{0,0,12},convex_radius=0.1,type=.Static))),{2.3,2.4,12},{-4,-4,0})
    testing.expect(t,rim_ok)
    expect_near3(t,rim.point,Vec3{0.3,0.4,12}+normalize(Vec3{1,1,0})*0.1,1e-3)
}

@(test)
rounded_shapes_rest_at_the_height_of_their_size :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    cube,_:=cube_hull(&w,0.5,0.05)
    box:=test_shape_body(&w,Box{{0.5,0.5,0.5}},{0,0.52,0},convex_radius=0.05)
    hull:=test_shape_body(&w,cube,{3,0.52,0})
    cylinder:=test_shape_body(&w,Cylinder{0.4,0.5},{-3,0.52,0},convex_radius=0.05)
    lying:=test_shape_body(&w,Cylinder{0.4,0.5},{-3,0.42,3},q_axis_angle({0,0,1},0.5*PI),convex_radius=0.05)
    test_steps(&w,240)
    expect_near3(t,body_position(&w,box),{0,0.5,0},0.01)
    expect_near3(t,body_position(&w,hull),{3,0.5,0},0.01)
    expect_near3(t,body_position(&w,cylinder),{-3,0.5,0},0.01)
    expect_near3(t,body_position(&w,lying),{-3,0.4,3},0.02)
    for body in ([4]Body_Handle{box,hull,cylinder,lying}) {
        testing.expectf(t,!body_is_awake(&w,body),"%v is still awake",body_position(&w,body))
        testing.expectf(t,abs(body_rotation(&w,body).w)>0.999 || body==lying,"%v tilted",body_rotation(&w,body))
    }
}

@(test)
a_pyramid_and_a_stack_of_rounded_boxes_rest_and_sleep :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    bodies:[65]Body_Handle
    positions:[65]Vec3
    count:=0
    for row in 0..<10 {
        for column in 0..<10-row {
            positions[count]={f32(column)*1.05+f32(row)*0.525-4.7,0.5+f32(row),0}
            bodies[count]=test_shape_body(&w,Box{{0.5,0.5,0.5}},positions[count],convex_radius=0.05)
            count+=1
        }
    }
    for i in 0..<10 {
        positions[count]={0,0.5+f32(i),6}
        bodies[count]=test_shape_body(&w,Box{{0.5,0.5,0.5}},positions[count],convex_radius=0.05)
        count+=1
    }
    test_stack_rests(t,&w,bodies[:],positions[:],6)
}

@(test)
rounded_boxes_meet_face_to_face_on_their_flat_faces_and_edge_to_edge_on_their_rounding :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    a:=test_shape_body(&w,Box{{0.5,0.5,0.5}},{},convex_radius=0.1,type=.Static)
    on_top:=test_shape_body(&w,Box{{0.5,0.5,0.5}},{0.05,0.99,0},convex_radius=0.1)
    out,count:=test_pair(&w,a,on_top)
    testing.expect_value(t,count,1)
    m:=out[0]
    testing.expect_value(t,m.count,4)
    expect_near3(t,m.normal,{0,1,0},1e-4)
    for point in m.points[:m.count] {
        expect_near(t,point.separation,-0.01,1e-4)
        expect_near(t,point.point.y,0.495,1e-4)
        testing.expectf(t,abs(point.point.z)<=0.4+1e-4 && point.point.x<=0.4+1e-4 && point.point.x>=-0.35-1e-4,"%v is outside the flat faces",point.point)
    }
    body_destroy(&w,on_top)
    // Two edges along Z: the rounding faces them along the diagonal, apart by the distance of the edges of the cores less both radii.
    beside:=test_shape_body(&w,Box{{0.5,0.5,0.5}},{0.95,0.95,0},convex_radius=0.1)
    out,count=test_pair(&w,a,beside)
    testing.expect_value(t,count,1)
    m=out[0]
    testing.expect(t,m.count>=1)
    expect_near3(t,m.normal,normalize(Vec3{1,1,0}),1e-3)
    for point in m.points[:m.count] {expect_near(t,point.separation,0.15*cmath.sqrt(f32(2))-0.2,1e-3)}
}

@(test)
rounded_boxes_rest_on_a_triangle_mesh :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    mesh,ok:=test_grid_mesh(&w,8,16)
    testing.expect(t,ok)
    test_static_shape(&w,mesh)
    box:=test_shape_body(&w,Box{{0.5,0.5,0.5}},{0.3,0.52,0.2},convex_radius=0.05)
    top:=test_shape_body(&w,Box{{0.4,0.4,0.4}},{0.3,1.42,0.2},convex_radius=0.05)
    test_steps(&w,300)
    expect_near3(t,body_position(&w,box),{0.3,0.5,0.2},0.02)
    expect_near3(t,body_position(&w,top),{0.3,1.4,0.2},0.03)
    testing.expect(t,!body_is_awake(&w,box) && !body_is_awake(&w,top))
}
