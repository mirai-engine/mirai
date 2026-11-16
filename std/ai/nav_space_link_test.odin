package ai

import "core:testing"
import math "mirai:std/math"

// Two banks of a mesh that do not touch, with the volume of the water
// between them under a wall: the one search walks to the shore, crosses into
// the volume, goes under the wall and comes out on the other bank; a link
// that goes one way only is not taken back.
@(test)
a_path_crosses_from_a_mesh_into_a_volume_and_out_again :: proc(t:^testing.T) {
    volume:Nav_Volume
    volume_wall(t,&volume)
    defer nav_volume_destroy(&volume)
    mesh:Nav_Mesh
    testing.expect(t,nav_mesh_init(&mesh,{tile_width=16,climb=0.3,max_tiles=1}))
    defer nav_mesh_destroy(&mesh)
    vertices:=[]math.Vec3{{0,0,0},{4,0,0},{4,0,16},{0,0,16},{12,0,0},{16,0,0},{16,0,16},{12,0,16}}
    indices:=[]u32{0,2,1,0,3,2,4,6,5,4,7,6}
    data,made:=nav_tile_from_triangles({0,0},{{0,-1e6,0},{16,1e6,16}},vertices,indices)
    testing.expect(t,made && nav_mesh_add_tile(&mesh,data))
    filter:=Nav_Filter{can=NAV_CAN_ALL}
    q:Nav_Medium_Query
    testing.expect(t,nav_medium_query_init(&q,8192))
    defer nav_medium_query_destroy(&q)
    start,end:=math.Vec3{1,0,8},math.Vec3{15,0,8}
    extents:=math.Vec3{1,2,1}
    from,_,on:=nav_find_nearest(&mesh,start,extents,&filter)
    to,_,there:=nav_find_nearest(&mesh,end,extents,&filter)
    testing.expect(t,on && there)
    out:[1024]Nav_Ref
    _,status,partial:=nav_medium_find_path(&q,&mesh,&volume,&filter,nil,extents,from,to,start,end,out[:])
    testing.expect(t,status!=.Found || partial,"without links the banks do not join")
    links:=[]Nav_Space_Link{
        {surface={3,0,8},space={5,1,8},two_way=true,kind=7},
        {surface={13,0,8},space={11,1,8},two_way=true,kind=7},
    }
    count:int
    count,status,partial=nav_medium_find_path(&q,&mesh,&volume,&filter,links,extents,from,to,start,end,out[:])
    testing.expect_value(t,status,Search_Status.Found)
    testing.expect(t,!partial && count>2 && out[0]==from && out[count-1]==to)
    cells:=0
    for ref in out[:count] {if nav_ref_is_volume(ref) {cells+=1}}
    testing.expect(t,cells>0 && cells<count-1,"over the mesh, through the volume, onto the mesh")
    part,enter,into,kind,crosses:=nav_medium_first_part(&q,out[:count])
    testing.expect(t,crosses && part>=1 && !nav_ref_is_volume(out[part-1]) && nav_ref_is_volume(out[part]))
    testing.expect(t,enter=={3,0,8} && into=={5,1,8} && kind==7)
    for ref in out[:count] {
        if !nav_ref_is_volume(ref) {continue}
        box,_:=nav_volume_ref_box(&volume,ref)
        testing.expect(t,box.max.y<=3 || box.max.x<=7.5 || box.min.x>=8.5,"under the wall, never through it")
    }
    // Back the other way the second link leads in; one way only, it does not.
    count,status,partial=nav_medium_find_path(&q,&mesh,&volume,&filter,links,extents,to,from,end,start,out[:])
    testing.expect(t,status==.Found && !partial)
    links[1].two_way=false
    _,status,partial=nav_medium_find_path(&q,&mesh,&volume,&filter,links,extents,from,to,start,end,out[:])
    testing.expect(t,status!=.Found || partial,"a one-way link is not taken out of the water")
    // A start in the volume reaches a bank.
    cell,_,_:=nav_volume_find_nearest(&volume,{6,1,8},extents)
    count,status,partial=nav_medium_find_path(&q,&mesh,&volume,&filter,links,extents,cell,from,{6,1,8},start,out[:])
    testing.expect(t,status==.Found && !partial && nav_ref_is_volume(out[0]) && !nav_ref_is_volume(out[count-1]))
}
