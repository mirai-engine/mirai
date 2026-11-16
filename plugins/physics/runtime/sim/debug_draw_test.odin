package mirai_physics

import "core:testing"

@(test)
debug_draw_writes_shapes_contacts_and_joints_to_the_buffers_given :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    box:=test_body(&w,Box{{0.5,0.5,0.5}},{0,0.5,0})
    ball:=test_body(&w,Sphere{0.5},{3,2,0})
    test_body(&w,Capsule{0.25,0.5},{-3,2,0})
    far:=test_body(&w,Sphere{0.5},{40,2,40},.Static)
    joint_create(&w,test_joint(&w,.Spherical,box,ball,{1.5,1,0},{0,0,1}))
    for _ in 0..<10 {world_step(&w,1.0/60)}
    lines:=make([]Debug_Line,1024)
    points:=make([]Debug_Point,64)
    defer delete(lines)
    defer delete(points)
    out:=Debug_Draw{lines=lines,points=points}
    world_debug_draw(&w,&out,{.Shapes})
    // Ground and box: 12 edges each. Two spheres: three circles of 16. Capsule: two circles, four sides, four half circles.
    testing.expect_value(t,out.line_count,2*12+2*3*16+2*16+4+4*8)
    testing.expect(t,out.point_count==0 && out.lines_dropped==0)
    kinds:[Debug_Kind]int
    for line in lines[:out.line_count] {kinds[line.kind]+=1}
    testing.expect(t,kinds[.Static]==12+48 && kinds[.Dynamic]==12+48+68)
    world_debug_draw(&w,&out,{.Bounds,.Contacts,.Joints,.Centers})
    testing.expect_value(t,out.line_count,5*12+3+3*3)
    testing.expect(t,out.point_count>=4,"the box rests on four points")
    for point in points[:out.point_count] {testing.expect(t,abs(point.normal.y)>0.99 && point.impulse>0)}
    // Only what meets the region (the far sphere and the ground under it), and what does not fit is counted.
    world_debug_draw(&w,&out,{.Shapes},{{30,0,30},{50,5,50}})
    testing.expect_value(t,out.line_count,12+48)
    small:=Debug_Draw{lines=lines[:10]}
    world_debug_draw(&w,&small,{.Shapes,.Contacts})
    testing.expect(t,small.line_count==10 && small.lines_dropped==2*12+2*48+68-10 && small.points_dropped>=4)
    _=far
}

@(test)
debug_draw_of_one_shape_excludes_other_shapes_and_rejects_stale_handles :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    body:=body_create(&w,{type=.Static,position={3,4,5},rotation=1})
    box:=shape_create(&w,body,{geometry=Box{{0.5,1,1.5}},transform={{1,0,0},1}})
    shape_create(&w,body,{geometry=Sphere{2}})
    storage:[48]Debug_Line
    out:=Debug_Draw{lines=storage[:]}
    testing.expect(t,shape_debug_draw(&w,box,&out))
    testing.expect_value(t,out.line_count,12)
    for line in out.lines[:out.line_count] {
        for point in ([2]Vec3{line.a,line.b}) {
            testing.expect(t,abs(point.x-4)==0.5 && abs(point.y-4)==1 && abs(point.z-5)==1.5)
        }
    }
    out.lines=storage[:4]
    testing.expect(t,shape_debug_draw(&w,box,&out))
    testing.expect(t,out.line_count==4 && out.lines_dropped==8)
    shape_destroy(&w,box)
    testing.expect(t,!shape_debug_draw(&w,box,&out))
    testing.expect(t,out.line_count==0 && out.lines_dropped==0)
    testing.expect(t,!shape_debug_draw(&w,{},&out))
}

@(test)
debug_draw_of_a_mesh_truncates_to_the_buffer_and_counts_remaining_edges :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    vertices:=[4]Vec3{{0,0,0},{1,0,0},{0,0,1},{1,0,1}}
    indices:=[6]u32{0,2,1,1,2,3}
    mesh,ok:=mesh_create(&w,{vertices=vertices[:],indices=indices[:]})
    testing.expect(t,ok)
    body:=body_create(&w,{type=.Static,position={2,3,4},rotation=1})
    shape:=shape_create(&w,body,{geometry=mesh})
    storage:[4]Debug_Line
    out:=Debug_Draw{lines=storage[:]}
    testing.expect(t,shape_debug_draw(&w,shape,&out))
    testing.expect(t,out.line_count==4 && out.lines_dropped==2)
    for line in out.lines[:out.line_count] {
        for point in ([2]Vec3{line.a,line.b}) {
            testing.expect(t,point.x>=2 && point.x<=3 && point.y==3 && point.z>=4 && point.z<=5)
        }
    }
    out.lines=storage[:0]
    testing.expect(t,shape_debug_draw(&w,shape,&out))
    testing.expect(t,out.line_count==0 && out.lines_dropped==6)
}

@(test)
debug_draw_of_layers_draws_only_the_shapes_of_their_categories :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    body:=body_create(&w,{type=.Static,rotation=1})
    shape_create(&w,body,{geometry=Box{{0.5,0.5,0.5}},filter={layers=2,block=0xffffffff}})
    shape_create(&w,body,{geometry=Sphere{1},transform={{3,0,0},1},filter={layers=4,block=0xffffffff}})
    storage:[256]Debug_Line
    out:=Debug_Draw{lines=storage[:]}
    world_debug_draw(&w,&out,{.Shapes},layers=2)
    testing.expect_value(t,out.line_count,12)
    world_debug_draw(&w,&out,{.Shapes,.Bounds},layers=4)
    testing.expect_value(t,out.line_count,3*16+12)
    world_debug_draw(&w,&out,{.Shapes},layers=8)
    testing.expect_value(t,out.line_count,0)
    world_debug_draw(&w,&out,{.Shapes})
    testing.expect_value(t,out.line_count,12+3*16)
}
