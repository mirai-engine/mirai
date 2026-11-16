package mirai_physics

import "core:testing"
import cmath "core:math"

// A body of one shape, with the rotation and convex radius given.
@(private)
test_shape_body :: proc(w:^World,geometry:Geometry,position:Vec3,rotation:Quat=QUAT_IDENTITY,convex_radius:f32=0,type:=Body_Type.Dynamic,velocity:Vec3={},bullet:=false) -> Body_Handle {
    desc:=BODY_DESC_DEFAULT
    desc.type,desc.position,desc.rotation,desc.linear_velocity,desc.bullet=type,position,rotation,velocity,bullet
    body:=body_create(w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=geometry
    shape.convex_radius=convex_radius
    if shape_create(w,body,shape)=={} {
        body_destroy(w,body)
        return {}
    }
    return body
}

// The manifold of the contact between the first shapes of two bodies, in the frame of the shape of higher type.
@(private)
test_pair :: proc(w:^World,first,second:Body_Handle) -> (out:[1+EXTRA_MANIFOLDS]Local_Manifold,count:int) {
    a:=&w.shapes[test_first_shape(w,first)]
    b:=&w.shapes[test_first_shape(w,second)]
    if a.type<b.type {a,b=b,a}
    sat:Sat_Cache
    count=shapes_collide(w,a,b,xf_inv_mul(shape_transform_of(w,a),shape_transform_of(w,b)),SPECULATIVE_DISTANCE,&out,&sat)
    return
}

@(private)
test_first_shape :: proc(w:^World,h:Body_Handle) -> i32 {
    body,_:=body_get(w,h)
    return body==nil?-1:body.shape_list
}

@(test)
cylinder_mass_and_bounds_follow_its_size :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    standing:=test_shape_body(&w,Cylinder{0.4,0.5},{})
    mass,center,inertia:=body_mass_properties(&w,standing)
    expected:=f32(1000*PI*0.16*1.0)
    expect_near(t,mass,expected,0.05)
    expect_near3(t,center,{})
    expect_near(t,inertia[1,1],expected*0.16/2,0.005)
    expect_near(t,inertia[0,0],expected*(0.16/4+0.25/3),0.005)
    expect_near(t,inertia[2,2],inertia[0,0],0.01)
    box:=shape_bounds(&w,shape_handle(&w,test_first_shape(&w,standing)))
    expect_near3(t,box.min,{-0.4,-0.5,-0.4})
    expect_near3(t,box.max,{0.4,0.5,0.4})
    leaning:=test_shape_body(&w,Cylinder{0.4,0.5},{2,0,0},q_axis_angle({0,0,1},0.25*PI))
    box=shape_bounds(&w,shape_handle(&w,test_first_shape(&w,leaning)))
    half:=0.9*cmath.sqrt(f32(0.5))
    expect_near3(t,box.max-{2,0,0},{half,half,0.4},1e-3)
}

@(test)
cylinder_shapes_validate_their_size_and_convex_radius :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    for geometry in ([?]Geometry{Cylinder{0,1},Cylinder{1,0},Cylinder{-1,1},Cylinder{cmath.nan_f32(),1}}) {
        testing.expectf(t,test_shape_body(&w,geometry,{})=={},"%v was accepted",geometry)
    }
    testing.expect(t,test_shape_body(&w,Cylinder{0.4,0.5},{},convex_radius=0.1)!={})
    testing.expect(t,test_shape_body(&w,Cylinder{0.4,0.5},{},convex_radius=0.4)=={})
    testing.expect(t,test_shape_body(&w,Box{{0.5,0.2,0.5}},{},convex_radius=0.1)!={})
    testing.expect(t,test_shape_body(&w,Box{{0.5,0.2,0.5}},{},convex_radius=0.2)=={})
    testing.expect(t,test_shape_body(&w,Box{{0.5,0.5,0.5}},{},convex_radius=-0.1)=={})
    testing.expect(t,test_shape_body(&w,Box{{0.5,0.5,0.5}},{},convex_radius=cmath.inf_f32(1))=={})
    // Spheres and capsules are round already: the radius does not apply to them.
    testing.expect(t,test_shape_body(&w,Sphere{0.5},{},convex_radius=1)!={})
}

@(test)
a_standing_cylinder_and_a_lying_one_rest_on_the_ground_and_sleep :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    standing:=test_shape_body(&w,Cylinder{0.4,0.5},{0,0.52,0})
    lying:=test_shape_body(&w,Cylinder{0.4,0.5},{3,0.42,1},q_axis_angle({0,0,1},0.5*PI))
    thin:=test_shape_body(&w,Cylinder{0.3,0.02},{-3,0.04,0})
    test_steps(&w,240)
    expect_near3(t,body_position(&w,standing),{0,0.5,0},0.01)
    expect_near3(t,body_position(&w,lying),{3,0.4,1},0.02)
    expect_near3(t,body_position(&w,thin),{-3,0.02,0},0.01)
    testing.expectf(t,abs(body_rotation(&w,standing).w)>0.9999,"the standing cylinder tilted: %v",body_rotation(&w,standing))
    for body in ([3]Body_Handle{standing,lying,thin}) {testing.expectf(t,!body_is_awake(&w,body),"%v is still awake",body_position(&w,body))}
}

@(test)
cylinders_rest_on_a_triangle_mesh_and_a_heightfield :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    mesh,ok:=test_grid_mesh(&w,8,16)
    testing.expect(t,ok)
    test_static_shape(&w,mesh)
    field,field_ok:=test_heights(&w,9,9,{1,1,1},proc(column,row:int)->f32 {return 0})
    testing.expect(t,field_ok)
    test_static_shape(&w,field,{20,0,-4})
    standing:=test_shape_body(&w,Cylinder{0.4,0.5},{0.3,0.52,0.2})
    lying:=test_shape_body(&w,Cylinder{0.4,0.5},{-3,0.42,1.3},q_axis_angle({0,0,1},0.5*PI))
    on_field:=test_shape_body(&w,Cylinder{0.4,0.5},{23.5,0.52,-0.5})
    lying_on_field:=test_shape_body(&w,Cylinder{0.4,0.5},{22.3,0.42,1.5},q_axis_angle({1,0,0},0.5*PI))
    test_steps(&w,300)
    expect_near3(t,body_position(&w,standing),{0.3,0.5,0.2},0.02)
    expect_near3(t,body_position(&w,lying),{-3,0.4,1.3},0.03)
    expect_near3(t,body_position(&w,on_field),{23.5,0.5,-0.5},0.02)
    expect_near3(t,body_position(&w,lying_on_field),{22.3,0.4,1.5},0.03)
    for body in ([4]Body_Handle{standing,lying,on_field,lying_on_field}) {testing.expectf(t,!body_is_awake(&w,body),"%v is still awake",body_position(&w,body))}
}

@(test)
a_cylinder_rolls_down_a_slope_as_a_solid_cylinder_does :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    angle:=f32(10*PI/180)
    slope:=q_axis_angle({0,0,1},-angle)
    ground:=body_create(&w,{type=.Static,rotation=slope})
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{{30,0.5,5}}
    shape_create(&w,ground,shape)
    up:=q_rotate(slope,{0,1,0})
    down:=q_rotate(slope,{1,0,0})
    start:=up*0.901
    // Axis along Z: it rolls down the slope.
    wheel:=test_shape_body(&w,Cylinder{0.4,0.3},start,q_axis_angle({1,0,0},0.5*PI))
    test_steps(&w,30)
    first:=body_position(&w,wheel)
    test_steps(&w,60)
    // A solid cylinder that rolls without slipping accelerates at 2/3 g sin(angle).
    travelled:=dot(body_position(&w,wheel)-first,down)
    v0:=dot(body_linear_velocity(&w,wheel),down)
    acceleration:=f32(2.0/3*9.81)*cmath.sin(angle)
    expected:=0.5*acceleration*(1.5*1.5-0.5*0.5)
    testing.expectf(t,abs(travelled-expected)<0.05*expected,"it went %v m, a rolling cylinder goes %v m",travelled,expected)
    expect_near(t,v0,acceleration*1.5,0.05*acceleration*1.5)
    spin:=body_angular_velocity(&w,wheel)
    expect_near(t,-spin.z*0.4,v0,0.03*v0)
    testing.expectf(t,abs(body_position(&w,wheel).z)<0.005,"it drifted sideways to z=%v",body_position(&w,wheel).z)
    // It keeps touching the slope: no hops along the way.
    height:=dot(body_position(&w,wheel),up)
    expect_near(t,height,0.9,0.01)
}

@(test)
a_cylinder_meets_every_convex_shape :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    cylinder:=test_shape_body(&w,Cylinder{0.4,0.5},{},type=.Static)
    expect_contact :: proc(t:^testing.T,w:^World,a,b:Body_Handle,count:int,normal:Vec3,separation:f32,loc:=#caller_location) -> Local_Manifold {
        out,manifolds:=test_pair(w,a,b)
        testing.expectf(t,manifolds==1,"%v manifolds",manifolds,loc=loc)
        m:=out[0]
        testing.expectf(t,int(m.count)==count,"%v points, expected %v",m.count,count,loc=loc)
        expect_near3(t,m.normal,normal,1e-3,loc=loc)
        for point in m.points[:m.count] {expect_near(t,point.separation,separation,1e-3,loc=loc)}
        body_destroy(w,b)
        return m
    }
    expect_contact(t,&w,cylinder,test_shape_body(&w,Sphere{0.2},{0.59,0.1,0}),1,{1,0,0},-0.01)
    expect_contact(t,&w,cylinder,test_shape_body(&w,Sphere{0.2},{0.1,0.69,-0.1}),1,{0,1,0},-0.01)
    rim:=expect_contact(t,&w,cylinder,test_shape_body(&w,Sphere{0.2},{0.5,0.6,0}),1,normalize(Vec3{1,1,0}),cmath.sqrt(f32(0.02))-0.2)
    expect_near3(t,rim.points[0].point,Vec3{0.4,0.5,0}+normalize(Vec3{1,1,0})*0.5*(cmath.sqrt(f32(0.02))-0.2))
    expect_contact(t,&w,cylinder,test_shape_body(&w,Sphere{0.2},{0.3,0,0}),1,{1,0,0},-0.3)
    expect_contact(t,&w,cylinder,test_shape_body(&w,Capsule{0.2,0.3},{0,0,0.59}),2,{0,0,1},-0.01)
    expect_contact(t,&w,cylinder,test_shape_body(&w,Box{{1,0.25,1}},{0,-0.74,0}),4,{0,-1,0},-0.01)
    side:=expect_contact(t,&w,cylinder,test_shape_body(&w,Box{{0.25,1,1}},{-0.64,0,0}),2,{-1,0,0},-0.01)
    expect_near(t,abs(side.points[0].point.y-side.points[1].point.y),1)
    // Deeper than the margin of GJK, EPA finds the side.
    expect_contact(t,&w,cylinder,test_shape_body(&w,Box{{0.25,1,1}},{-0.55,0.1,0}),2,{-1,0,0},-0.1)
    prism,_:=test_prism(&w,6,1,0.25)
    expect_contact(t,&w,cylinder,test_shape_body(&w,prism,{0,0.74,0}),4,{0,1,0},-0.01)
    expect_contact(t,&w,cylinder,test_shape_body(&w,Cylinder{0.4,0.5},{0.2,0.99,0.1}),4,{0,1,0},-0.01)
    expect_contact(t,&w,cylinder,test_shape_body(&w,Cylinder{0.4,0.5},{0,0,0.79}),2,{0,0,1},-0.01)
    crossed:=expect_contact(t,&w,cylinder,test_shape_body(&w,Cylinder{0.4,0.5},{0.79,0.1,0},q_axis_angle({1,0,0},0.5*PI)),1,{1,0,0},-0.01)
    expect_near3(t,crossed.points[0].point,{0.395,0.1,0},1e-3)
    // Apart by more than the speculative distance: nothing.
    out,count:=test_pair(&w,cylinder,test_shape_body(&w,Box{{1,0.25,1}},{0,-0.8,0}))
    testing.expect_value(t,count,0)
    _=out
}

@(test)
cylinders_stack_on_each_other_and_on_boxes :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    bodies:[8]Body_Handle
    positions:[8]Vec3
    for i in 0..<8 {
        positions[i]={0,0.4+0.8*f32(i),0}
        if i%2==0 {
            bodies[i]=test_shape_body(&w,Cylinder{0.5,0.4},positions[i])
        } else {
            bodies[i]=test_shape_body(&w,Box{{0.4,0.4,0.4}},positions[i])
        }
    }
    test_stack_rests(t,&w,bodies[:],positions[:],6)
}

@(test)
queries_see_cylinders :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    post:=test_shape_body(&w,Cylinder{0.4,0.5},{0,1,0},type=.Static)
    side,side_ok:=ray_cast_closest(&w,{2,1.2,0},{-4,0,0})
    testing.expect(t,side_ok && side.body==post)
    expect_near(t,side.fraction,0.4)
    expect_near3(t,side.normal,{1,0,0})
    top,top_ok:=ray_cast_closest(&w,{0.1,4,-0.1},{0,-4,0})
    testing.expect(t,top_ok && top.body==post)
    expect_near(t,top.fraction,2.5/4)
    expect_near3(t,top.normal,{0,1,0})
    beside,beside_ok:=ray_cast_closest(&w,{0.35,4,0.35},{0,-4,0})
    testing.expect(t,beside_ok && beside.body!=post)
    inside,inside_ok:=shape_ray_cast(&w,shape_handle(&w,test_first_shape(&w,post)),{0.1,1,0},{1,0,0})
    testing.expect(t,inside_ok)
    expect_near(t,inside.fraction,0)
    // A falling cylinder stops on the top of the ground, at y=0.
    fall,fall_ok:=shape_cast_closest(&w,Cylinder{0.2,0.3},{{3,3,0},QUAT_IDENTITY},{0,-5,0})
    testing.expect(t,fall_ok)
    expect_near(t,fall.fraction,(3-0.3)/5,1e-3)
    expect_near3(t,fall.normal,{0,1,0},1e-3)
    // Lying, it meets the side of the post first.
    rolled,rolled_ok:=shape_cast_closest(&w,Cylinder{0.2,0.3},{{3,1,0},q_axis_angle({1,0,0},0.5*PI)},{-5,0,0})
    testing.expect(t,rolled_ok && rolled.body==post)
    expect_near(t,rolled.fraction,(3-0.6)/5,1e-3)
    found:[4]Shape_Handle
    testing.expect_value(t,overlap_shape(&w,Cylinder{0.5,0.5},{{3,0.4,0},QUAT_IDENTITY},found[:]),1)
    testing.expect_value(t,overlap_shape(&w,Cylinder{0.5,0.5},{{3,0.6,0},QUAT_IDENTITY},found[:]),0)
    testing.expect_value(t,overlap_shape(&w,Cylinder{0.5,0.5},{{0.85,1,0},QUAT_IDENTITY},found[:]),1)
    near,near_ok:=closest_point(&w,{1,1.2,0},2)
    testing.expect(t,near_ok && near.body==post)
    expect_near(t,near.distance,0.6,1e-3)
    expect_near3(t,near.normal,{1,0,0},1e-3)
}

@(test)
a_fast_cylinder_does_not_go_through_a_thin_wall :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    w.desc.gravity={}
    // Tall and wide: the tilted cylinder pivots on its rim and slides up the face at about 150 m/s, which
    // would carry it over a short wall within the three steps.
    test_shape_body(&w,Box{{0.05,20,20}},{5,0,0},type=.Static)
    bullet:=test_shape_body(&w,Cylinder{0.2,0.3},{0,0,0},q_axis_angle({0,0,1},0.3),velocity={300,0,0},bullet=true)
    lying:=test_shape_body(&w,Cylinder{0.2,0.3},{0,0,1},q_axis_angle({1,0,0},0.5*PI),velocity={300,0,0},bullet=true)
    test_steps(&w,3)
    testing.expectf(t,body_position(&w,bullet).x<5,"the cylinder went through to %v",body_position(&w,bullet))
    testing.expectf(t,body_position(&w,lying).x<5,"the lying cylinder went through to %v",body_position(&w,lying))
}

@(test)
a_snapshot_of_rolling_cylinders_replays_the_same_steps :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    for i in 0..<6 {
        test_shape_body(&w,Cylinder{0.3,0.4},{f32(i)*0.7-2,0.5+f32(i)*0.9,0},q_axis_angle({1,0.3,0.2},f32(i)),convex_radius=f32(i%2)*0.05,velocity={1,0,0.5})
    }
    test_shape_body(&w,Box{{0.3,0.3,0.3}},{0,3,0},convex_radius=0.05)
    test_steps(&w,30)
    buffer:World
    defer world_destroy(&buffer)
    saved:=test_keep(&buffer,&w)
    testing.expect(t,saved)
    test_steps(&w,60)
    after:=world_hash(&w)
    testing.expect(t,test_restore(&w,&buffer))
    test_steps(&w,60)
    testing.expect_value(t,world_hash(&w),after)
}

@(test)
debug_draw_outlines_a_cylinder :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    body:=test_shape_body(&w,Cylinder{0.4,0.5},{1,2,3})
    lines:[64]Debug_Line
    out:=Debug_Draw{lines=lines[:]}
    testing.expect(t,shape_debug_draw(&w,shape_handle(&w,test_first_shape(&w,body)),&out))
    testing.expect_value(t,out.line_count,2*DEBUG_SEGMENTS+4)
    for line in lines[:out.line_count] {
        for p in ([2]Vec3{line.a,line.b}) {
            local:=p-{1,2,3}
            expect_near(t,abs(local.y),0.5,1e-4)
            testing.expect(t,cmath.sqrt(local.x*local.x+local.z*local.z)<=0.4+1e-4)
        }
    }
}

@(test)
gjk_sees_a_cylinder_as_a_segment_swept_by_a_disc :: proc(t:^testing.T) {
    ends:=[2]Vec3{{0,-0.5,0},{0,0.5,0}}
    cylinder:=Proxy{points=ends[:],disc=0.4}
    origin:=[1]Vec3{{}}
    point:=Proxy{points=origin[:]}
    side:=gjk_distance(cylinder,point,{{1,0.2,0.5},QUAT_IDENTITY})
    expect_near(t,side.distance,cmath.sqrt(f32(1.25))-0.4,1e-4)
    expect_near3(t,side.normal,normalize(Vec3{1,0,0.5}),1e-4)
    rim:=gjk_distance(cylinder,point,{{1,1,0},QUAT_IDENTITY})
    expect_near(t,rim.distance,cmath.sqrt(f32(0.61)),1e-4)
    expect_near3(t,rim.point_a,{0.4,0.5,0},1e-4)
    corners:[8]Vec3
    for &c,i in corners {c={i&1!=0?0.5:-0.5,i&2!=0?0.1:-0.1,i&4!=0?0.5:-0.5}}
    slab:=Proxy{points=corners[:]}
    on_top:=epa_penetration(cylinder,slab,{{0.1,0.55,0},QUAT_IDENTITY})
    testing.expect(t,on_top.ok)
    expect_near(t,on_top.depth,0.05,1e-4)
    expect_near3(t,on_top.normal,{0,1,0},1e-4)
    against_side:=epa_penetration(cylinder,slab,{{0.85,0,0},QUAT_IDENTITY})
    testing.expect(t,against_side.ok)
    expect_near(t,against_side.depth,0.05,1e-3)
    expect_near3(t,against_side.normal,{1,0,0},1e-2)
    // Swept toward the slab without turning, it touches when its side reaches the face.
    swept:=gjk_cast(slab,cylinder,{{-3,0,0},QUAT_IDENTITY},{4,0,0})
    testing.expect(t,swept.hit)
    expect_near(t,swept.fraction,(3-0.9)/4,1e-3)
    expect_near3(t,swept.normal,{-1,0,0},1e-3)
    toi:=time_of_impact(cylinder,slab,{c1={-3,0,0},c2={1,0,0},q1=QUAT_IDENTITY,q2=q_axis_angle({0,0,1},1)},{q1=QUAT_IDENTITY,q2=QUAT_IDENTITY})
    testing.expect_value(t,toi.state,Toi_State.Hit)
    testing.expect(t,toi.fraction>0.4 && toi.fraction<0.6)
}
