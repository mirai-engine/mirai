package mirai_physics

import "core:testing"
import cmath "core:math"
import "core:math/rand"

@(test)
rays_hit_every_kind_of_shape_where_geometry_says :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    sphere:=test_body(&w,Sphere{1},{0,0,0})
    box:=test_body(&w,Box{{1,2,3}},{10,0,0})
    capsule:=test_body(&w,Capsule{0.5,1},{20,0,0})
    prism,_:=test_prism(&w,4,cmath.sqrt(f32(2)),1)
    hull:=test_body(&w,prism,{30,0,0})
    body_set_transform(&w,hull,{30,0,0},q_axis_angle({0,1,0},cmath.PI/4))

    hit,ok:=ray_cast_closest(&w,{0,5,0},{0,-10,0})
    testing.expect(t,ok && hit.body==sphere)
    expect_near(t,hit.fraction,0.4)
    expect_near3(t,hit.point,{0,1,0})
    expect_near3(t,hit.normal,{0,1,0})
    hit,ok=ray_cast_closest(&w,{-5,0.6,0},{10,0,0})
    expect_near3(t,hit.point,{-0.8,0.6,0})
    expect_near3(t,hit.normal,{-0.8,0.6,0})

    hit,ok=ray_cast_closest(&w,{10,0,-10},{0,0,20})
    testing.expect(t,ok && hit.body==box)
    expect_near3(t,hit.point,{10,0,-3})
    expect_near3(t,hit.normal,{0,0,-1})
    hit,ok=ray_cast_closest(&w,{10.5,10,1},{0,-20,0})
    expect_near3(t,hit.point,{10.5,2,1})
    expect_near3(t,hit.normal,{0,1,0})

    hit,ok=ray_cast_closest(&w,{15,0.5,0},{10,0,0})
    testing.expect(t,ok && hit.body==capsule)
    expect_near3(t,hit.point,{19.5,0.5,0})
    expect_near3(t,hit.normal,{-1,0,0})
    hit,ok=ray_cast_closest(&w,{20,5,0},{0,-10,0})
    expect_near3(t,hit.point,{20,1.5,0})
    expect_near3(t,hit.normal,{0,1,0})
    hit,ok=ray_cast_closest(&w,{15,1.3,0},{10,0,0})
    expect_near3(t,hit.point,{20-0.4,1.3,0})
    expect_near3(t,hit.normal,{-0.8,0.6,0})

    // The square prism turned an eighth of a turn is an axis-aligned box of half side 1.
    hit,ok=ray_cast_closest(&w,{25,0.3,0.2},{10,0,0})
    testing.expect(t,ok && hit.body==hull)
    expect_near3(t,hit.point,{29,0.3,0.2})
    expect_near3(t,hit.normal,{-1,0,0})

    // A ray that starts inside reports the start with no normal.
    hit,ok=ray_cast_closest(&w,{10,0,0},{0,0,20})
    testing.expect(t,ok)
    testing.expect_value(t,hit.fraction,0)
    testing.expect_value(t,hit.normal,Vec3{})
    // Misses: short of the shape, beside it and pointing away.
    testing.expect(t,!ray_cast_any(&w,{0,5,0},{0,-3.9,0}))
    testing.expect(t,!ray_cast_any(&w,{1.1,5,0},{0,-10,0}))
    testing.expect(t,!ray_cast_any(&w,{0,5,0},{0,10,0}))
    testing.expect(t,ray_cast_any(&w,{0,5,0},{0,-4.1,0}))
    _,ok=shape_ray_cast(&w,Shape_Handle(1<<32|1),{0,5,0},{0,-10,0})
    testing.expect(t,!ok)
    hit,ok=shape_ray_cast(&w,Shape_Handle(1<<32|1),{10,5,0},{0,-10,0})
    testing.expect(t,ok && hit.body==box)
    expect_near(t,hit.fraction,0.3)
    // A body as if it were at another pose, where it was at another time: the ray misses where it is and hits where it was.
    _,ok=body_ray_cast(&w,sphere,{{0,0,50},QUAT_IDENTITY},{0,5,0},{0,-10,0})
    testing.expect(t,!ok)
    hit,ok=body_ray_cast(&w,sphere,{{0,0,50},QUAT_IDENTITY},{0,5,50},{0,-10,0})
    testing.expect(t,ok && hit.body==sphere)
    expect_near(t,hit.fraction,0.4)
    expect_near3(t,hit.point,{0,1,50})
    _,ok=body_ray_cast(&w,Body_Handle(12345),TRANSFORM_IDENTITY,{0,5,0},{0,-10,0})
    testing.expect(t,!ok)
}

@(test)
ray_cast_all_returns_the_nearest_hits_in_order_up_to_the_first_that_blocks :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    bodies:[6]Body_Handle
    for i in 0..<6 {bodies[i]=test_body(&w,Sphere{0.5},{f32(5-i)*3,0,0},i%2==0?.Static:.Dynamic)}
    hits:[8]Ray_Hit
    testing.expect_value(t,ray_cast_all(&w,{-5,0,0},{30,0,0},hits[:]),1)
    testing.expect_value(t,hits[0].body,bodies[5])
    every:=Query_Filter{objects=0xffffffff}
    count:=ray_cast_all(&w,{-5,0,0},{30,0,0},hits[:],every)
    testing.expect_value(t,count,6)
    for i in 0..<6 {
        testing.expect_value(t,hits[i].body,bodies[5-i])
        expect_near(t,hits[i].point.x,f32(i)*3-0.5)
    }
    // A short buffer keeps the nearest.
    count=ray_cast_all(&w,{-5,0,0},{30,0,0},hits[:3],every)
    testing.expect_value(t,count,3)
    testing.expect_value(t,hits[2].body,bodies[3])
    testing.expect_value(t,ray_cast_all(&w,{-5,0,0},{30,0,0},nil),0)
    closest,ok:=ray_cast_closest(&w,{-5,0,0},{30,0,0})
    testing.expect(t,ok && closest.body==bodies[5])
}

@(test)
query_filters_select_channels_object_types_bodies_and_overlaps :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    near:=body_create(&w,{type=.Static,position={2,0,0}})
    desc:=SHAPE_DESC_DEFAULT
    desc.geometry=Sphere{0.5}
    desc.filter={layers=2,block=0xffffffff}
    shape_create(&w,near,desc)
    trigger:=body_create(&w,{type=.Static,position={4,0,0}})
    desc.filter={layers=1,overlap=0xffffffff}
    shape_create(&w,trigger,desc)
    far:=test_body(&w,Sphere{0.5},{6,0,0},.Static)
    hit,_:=ray_cast_closest(&w,{0,0,0},{10,0,0})
    testing.expect_value(t,hit.body,near)
    only_first:=Query_Filter{filter={layers=1,block=1}}
    hit,_=ray_cast_closest(&w,{0,0,0},{10,0,0},only_first)
    testing.expect_value(t,hit.body,far)
    only_first.overlaps=true
    hit,_=ray_cast_closest(&w,{0,0,0},{10,0,0},only_first)
    testing.expect_value(t,hit.body,far)
    hits:[4]Ray_Hit
    testing.expect_value(t,ray_cast_all(&w,{0,0,0},{10,0,0},hits[:],only_first),2)
    testing.expect(t,hits[0].body==trigger && hits[0].overlap && hits[1].body==far && !hits[1].overlap)
    testing.expect_value(t,ray_cast_all(&w,{0,0,0},{10,0,0},hits[:],{filter=FILTER_DEFAULT,overlaps=true}),1)
    hit,_=ray_cast_closest(&w,{0,0,0},{10,0,0},{filter=FILTER_DEFAULT,ignore_body=near})
    testing.expect_value(t,hit.body,far)
    testing.expect(t,!ray_cast_any(&w,{0,0,0},{10,0,0},{filter={layers=1,block=4}}))
    hit,_=ray_cast_closest(&w,{0,0,0},{10,0,0},{objects=1})
    testing.expect_value(t,hit.body,trigger)
    testing.expect_value(t,ray_cast_all(&w,{0,0,0},{10,0,0},hits[:],{objects=3}),3)
    out:[4]Shape_Handle
    testing.expect_value(t,overlap_aabb(&w,{{-1,-1,-1},{7,1,1}},out[:]),2)
    testing.expect_value(t,overlap_aabb(&w,{{-1,-1,-1},{7,1,1}},out[:],{filter=FILTER_DEFAULT,overlaps=true}),3)
    testing.expect_value(t,overlap_aabb(&w,{{-1,-1,-1},{7,1,1}},out[:],{objects=2}),1)
    testing.expect_value(t,overlap_aabb(&w,{{-1,-1,-1},{7,1,1}},out[:1]),2)
}

@(test)
rays_against_many_shapes_match_testing_each_shape :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w,bodies=512))
    defer world_destroy(&w)
    state:=rand.create(7)
    context.random_generator=rand.default_random_generator(&state)
    prism,_:=test_prism(&w,7,0.6,0.5)
    shapes:[300]Shape_Handle
    for i in 0..<300 {
        position:=Vec3{rand.float32_range(-20,20),rand.float32_range(-20,20),rand.float32_range(-20,20)}
        geometry:Geometry
        switch i%4 {
        case 0: geometry=Sphere{rand.float32_range(0.2,1)}
        case 1: geometry=Box{{rand.float32_range(0.2,1),rand.float32_range(0.2,1),rand.float32_range(0.2,1)}}
        case 2: geometry=Capsule{rand.float32_range(0.2,0.6),rand.float32_range(0.2,1)}
        case 3: geometry=prism
        }
        body:=test_body(&w,geometry,position,i%3==0?.Static:.Dynamic)
        axis:=normalize(Vec3{rand.float32_range(-1,1),rand.float32_range(-1,1),rand.float32_range(-1,1)+1.5})
        body_set_transform(&w,body,position,q_axis_angle(axis,rand.float32_range(0,6)))
        body_shapes(&w,body,shapes[i:i+1])
    }
    hits:=0
    for _ in 0..<400 {
        origin:=Vec3{rand.float32_range(-25,25),rand.float32_range(-25,25),rand.float32_range(-25,25)}
        target:=shape_world_transform(&w,shapes[rand.int_max(300)]).p+{rand.float32_range(-1,1),rand.float32_range(-1,1),rand.float32_range(-1,1)}
        translation:=1.5*(target-origin)
        best:Ray_Hit
        found:=false
        for shape in shapes {
            if hit,ok:=shape_ray_cast(&w,shape,origin,translation);ok && (!found || hit.fraction<best.fraction) {best,found=hit,true}
        }
        hit,ok:=ray_cast_closest(&w,origin,translation)
        testing.expect_value(t,ok,found)
        testing.expect_value(t,ray_cast_any(&w,origin,translation),found)
        if found && ok {
            hits+=1
            testing.expect_value(t,hit.shape,best.shape)
            testing.expect_value(t,hit.fraction,best.fraction)
        }
    }
    testing.expect(t,hits>50)
}

@(test)
rays_hit_meshes_and_heightfields_from_the_front :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    mesh,_:=test_grid_mesh(&w,16,16,proc(x,z:f32)->f32 {return 0.25*x})
    test_static_shape(&w,mesh,{0,0,0})
    field,_:=test_heights(&w,17,17,{1,1,1},proc(column,row:int)->f32 {return 0.25*f32(column)})
    test_static_shape(&w,field,{100,0,0})
    for origin in ([4]Vec3{{0.3,10,0.4},{-5.2,10,7.9},{3.7,10,-6.1},{7.99,10,0.01}}) {
        hit,ok:=ray_cast_closest(&w,origin,{0,-20,0})
        testing.expect(t,ok)
        expect_near(t,hit.point.y,0.25*origin.x,1e-3)
        expect_near3(t,hit.normal,normalize(Vec3{-0.25,1,0}),1e-3)
        // The same slope seen through the heightfield, whose corner is at its origin.
        hit,ok=ray_cast_closest(&w,origin+{108,0,8},{0,-20,0})
        testing.expect(t,ok)
        expect_near(t,hit.point.y,0.25*(origin.x+8),1e-3)
        expect_near3(t,hit.normal,normalize(Vec3{-0.25,1,0}),1e-3)
    }
    // From below the triangles are not seen; a slanted ray is found by walking the cells.
    testing.expect(t,!ray_cast_any(&w,{0.3,-10,0.4},{0,20,0}))
    testing.expect(t,!ray_cast_any(&w,{108.3,-10,8.4},{0,20,0}))
    hit,ok:=ray_cast_closest(&w,{101,6,1},{14,-4,14})
    testing.expect(t,ok)
    expect_near(t,hit.point.y,0.25*(hit.point.x-100),1e-3)
    expect_near(t,hit.point.z-1,hit.point.x-101,1e-3)
    testing.expect(t,!ray_cast_any(&w,{101,6,1},{14,1,14}))
    testing.expect(t,!ray_cast_any(&w,{90,1,1},{5,0,0}))
}

@(test)
shape_casts_stop_at_first_contact :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    wall:=test_body(&w,Box{{0.5,2,5}},{10,2,0},.Static)
    ball:=test_body(&w,Sphere{1},{5,3,0},.Static)
    hit,ok:=shape_cast_closest(&w,Sphere{0.5},{{0,1,3},QUAT_IDENTITY},{20,0,0})
    testing.expect(t,ok && hit.body==wall)
    expect_near(t,hit.fraction,(9.5-0.5)/20,2e-3)
    expect_near3(t,hit.point,{9.5,1,3},0.01)
    expect_near3(t,hit.normal,{-1,0,0},0.01)
    hit,ok=shape_cast_closest(&w,Box{{0.5,0.5,0.5}},{{0,3,0},QUAT_IDENTITY},{20,0,0})
    testing.expect(t,ok && hit.body==ball)
    expect_near(t,hit.fraction,(4-0.5)/20,2e-3)
    hits:[4]Ray_Hit
    testing.expect_value(t,shape_cast_all(&w,Capsule{0.25,0.5},{{0,3,0},QUAT_IDENTITY},{20,0,0},hits[:]),1)
    count:=shape_cast_all(&w,Capsule{0.25,0.5},{{0,3,0},QUAT_IDENTITY},{20,0,0},hits[:],{objects=0xffffffff})
    testing.expect_value(t,count,2)
    testing.expect(t,hits[0].body==ball && hits[1].body==wall)
    expect_near(t,hits[1].fraction,(9.5-0.25)/20,2e-3)
    // Downward onto the ground; a cast that starts in contact reports fraction zero.
    hit,ok=shape_cast_closest(&w,Box{{0.5,0.5,0.5}},{{-5,3,0},q_axis_angle({0,1,0},0.4)},{0,-10,0})
    testing.expect(t,ok)
    expect_near(t,hit.fraction,0.25,2e-3)
    expect_near3(t,hit.normal,{0,1,0},0.01)
    hit,ok=shape_cast_closest(&w,Sphere{0.5},{{-5,0.2,0},QUAT_IDENTITY},{0,-10,0})
    testing.expect(t,ok)
    testing.expect_value(t,hit.fraction,0)
    _,ok=shape_cast_closest(&w,Sphere{0.5},{{-5,3,0},QUAT_IDENTITY},{0,-2,0})
    testing.expect(t,!ok)
    _,ok=shape_cast_closest(&w,Mesh_Handle(1),{{-5,3,0},QUAT_IDENTITY},{0,-10,0})
    testing.expect(t,!ok)
    mesh,_:=test_grid_mesh(&w,8,8)
    test_static_shape(&w,mesh,{0,20,0})
    hit,ok=shape_cast_closest(&w,Sphere{0.5},{{0.3,25,0.2},QUAT_IDENTITY},{0,-10,0})
    testing.expect(t,ok)
    expect_near(t,hit.fraction,0.45,2e-3)
    expect_near3(t,hit.normal,{0,1,0},0.01)
    _,ok=shape_cast_closest(&w,Sphere{0.5},{{0.3,15,0.2},QUAT_IDENTITY},{0,8,0},{filter=FILTER_DEFAULT})
    testing.expect(t,!ok)
}

@(test)
overlaps_and_closest_points_agree_with_geometry :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    box:=test_body(&w,Box{{1,1,1}},{0,0,0},.Static)
    ball:=test_body(&w,Sphere{1},{5,0,0})
    mesh,_:=test_grid_mesh(&w,4,8)
    floor:=test_static_shape(&w,mesh,{0,-5,0})
    out:[4]Shape_Handle
    testing.expect_value(t,overlap_shape(&w,Sphere{0.5},{{1.4,0,0},QUAT_IDENTITY},out[:]),1)
    testing.expect_value(t,shape_body(&w,out[0]),box)
    testing.expect_value(t,overlap_shape(&w,Sphere{0.5},{{1.6,0,0},QUAT_IDENTITY},out[:]),0)
    // The boxes of the query and of the turned box overlap, the shapes do not.
    testing.expect_value(t,overlap_shape(&w,Box{{0.5,0.5,0.5}},{{1.5,1.5,0},q_axis_angle({0,0,1},cmath.PI/4)},out[:]),0)
    testing.expect_value(t,overlap_shape(&w,Box{{0.5,0.5,0.5}},{{1.3,1.3,0},q_axis_angle({0,0,1},cmath.PI/4)},out[:]),1)
    testing.expect_value(t,overlap_shape(&w,Capsule{0.5,3},{{2.5,0,0},q_axis_angle({0,0,1},cmath.PI/2)},out[:]),2)
    testing.expect_value(t,overlap_shape(&w,Sphere{0.5},{{1,-4.6,1},QUAT_IDENTITY},out[:]),1)
    testing.expect_value(t,shape_body(&w,out[0]),floor)
    testing.expect_value(t,overlap_shape(&w,Sphere{0.5},{{1,-4.4,1},QUAT_IDENTITY},out[:]),0)

    hit,ok:=closest_point(&w,{3,0.5,0},10)
    testing.expect(t,ok && hit.body==ball)
    expect_near(t,hit.distance,cmath.sqrt(f32(4.25))-1,1e-3)
    hit,ok=closest_point(&w,{2.4,0.5,0},10)
    testing.expect(t,ok && hit.body==box)
    expect_near(t,hit.distance,1.4,1e-3)
    expect_near3(t,hit.point,{1,0.5,0},1e-3)
    expect_near3(t,hit.normal,{1,0,0},1e-3)
    hit,ok=closest_point(&w,{0.2,0.1,0},10)
    testing.expect(t,ok && hit.body==box)
    testing.expect_value(t,hit.distance,0)
    hit,ok=closest_point(&w,{1,-3,1},10)
    testing.expect(t,ok && hit.body==box || hit.body==floor)
    expect_near(t,hit.distance,2,1e-3)
    _,ok=closest_point(&w,{0,10,0},5)
    testing.expect(t,!ok)
    hit,ok=closest_shape(&w,Box{{0.5,0.5,0.5}},{{0,3,0},QUAT_IDENTITY},5)
    testing.expect(t,ok && hit.body==box)
    expect_near(t,hit.distance,1.5,1e-3)
    expect_near(t,hit.point.y,1,1e-3)
    expect_near(t,hit.query_point.y,2.5,1e-3)
}
