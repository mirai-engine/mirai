package mirai_render

import "core:math/linalg"
import "core:testing"

@(test)
debug_shapes_are_lines_and_a_full_batch_counts_what_it_drops :: proc(t:^testing.T) {
    storage:[512]Debug_Vertex
    lines:=debug_lines_make(storage[:])
    testing.expect(t,lines.depth_test)
    debug_line(&lines,{0,0,0},{1,2,3},{1,0,0,1})
    testing.expect_value(t,lines.count,2)
    testing.expect_value(t,lines.vertices[1].position,Vec3{1,2,3})
    testing.expect_value(t,lines.vertices[0].color,u32(0xff0000ff))
    debug_lines_clear(&lines)
    debug_box(&lines,{-1,-2,-3},{1,2,3},{1,1,1,1})
    testing.expect_value(t,lines.count,24)
    for vertex in lines.vertices[:lines.count] {
        testing.expect(t,abs(vertex.position.x)==1 && abs(vertex.position.y)==2 && abs(vertex.position.z)==3,"box lines join its corners")
    }
    debug_lines_clear(&lines)
    debug_box_transformed(&lines,place({10,0,0},{2,2,2}),{0,0,0},{1,1,1},{1,1,1,1})
    testing.expect_value(t,lines.count,24)
    for vertex in lines.vertices[:lines.count] {testing.expect(t,vertex.position.x>=10 && vertex.position.x<=12,"the box is where its transform puts it")}
    debug_lines_clear(&lines)
    debug_circle(&lines,{0,5,0},{0,1,0},2,{1,1,1,1},16)
    testing.expect_value(t,lines.count,32)
    for vertex in lines.vertices[:lines.count] {
        radius:=vertex.position.x*vertex.position.x+vertex.position.z*vertex.position.z
        testing.expect(t,abs(radius-4)<1e-3 && abs(vertex.position.y-5)<1e-5,"a circle lies around its normal")
    }
    closing:=lines.vertices[0].position-lines.vertices[31].position
    testing.expect(t,abs(closing.x)+abs(closing.y)+abs(closing.z)<1e-4,"a circle ends where it starts")
    debug_lines_clear(&lines)
    debug_sphere(&lines,{0,0,0},1,{1,1,1,1},8)
    testing.expect_value(t,lines.count,48)
    debug_lines_clear(&lines)
    debug_axes(&lines,place({1,1,1},{2,2,2}),0.5)
    testing.expect_value(t,lines.count,6)
    testing.expect_value(t,lines.vertices[1].position,Vec3{2,1,1})
    // A batch without room drops whole lines and counts them.
    small:[5]Debug_Vertex
    full:=debug_lines_make(small[:],depth_test=false)
    debug_box(&full,{0,0,0},{1,1,1},{1,1,1,1})
    testing.expect_value(t,full.count,4)
    testing.expect_value(t,full.dropped,10)
    debug_lines_clear(&full)
    testing.expect(t,full.count==0 && full.dropped==0)
}

@(test)
debug_solid_arrow_is_triangles_wound_outward_and_kinds_do_not_mix :: proc(t:^testing.T) {
    storage:[DEBUG_ARROW_VERTICES+1]Debug_Vertex
    solid:=debug_lines_make(storage[:],triangles=true)
    debug_line(&solid,{},{1,0,0},{1,1,1,1})
    testing.expect(t,solid.count==0 && solid.dropped==1,"a batch of triangles takes no lines")
    from,to:=Vec3{1,2,3},Vec3{1,2,1}
    radius:=f32(0.05)
    debug_arrow_solid(&solid,from,to,{1,0,0,1},radius)
    testing.expect_value(t,solid.count,DEBUG_ARROW_VERTICES)
    axis:=linalg.normalize(to-from)
    length:=linalg.length(to-from)
    neck:=length*(1-DEBUG_ARROW_HEAD)
    for i:=0;i<solid.count;i+=3 {
        a,b,c:=solid.vertices[i].position,solid.vertices[i+1].position,solid.vertices[i+2].position
        center:=(a+b+c)/3
        along:=linalg.dot(center-from,axis)
        // Each triangle faces away from the middle of its part: the shaft or the cone.
        middle:=from+axis*(along>=neck-1e-4?neck+length*DEBUG_ARROW_HEAD*0.25:neck*0.5)
        testing.expectf(t,linalg.dot(linalg.cross(b-a,c-a),center-middle)>0,"triangle %d faces out",i/3)
        for p in ([3]Vec3{a,b,c}) {
            on:=linalg.dot(p-from,axis)
            off:=linalg.length(p-from-axis*on)
            testing.expect(t,on>=-1e-5 && on<=length+1e-5 && off<=radius*DEBUG_ARROW_HEAD_WIDTH+1e-5,"the arrow stays between its ends and within its head")
        }
    }
    count:=solid.count
    for bad in ([3]f32{0,-1,f32(0h7fc00000)}) {debug_arrow_solid(&solid,from,to,{1,1,1,1},bad)}
    debug_arrow_solid(&solid,from,from,{1,1,1,1},radius)
    testing.expect_value(t,solid.count,count)
    lines:=debug_lines_make(storage[:])
    debug_triangle(&lines,{},{1,0,0},{0,1,0},{1,1,1,1})
    testing.expect(t,lines.count==0 && lines.dropped==1,"a batch of lines takes no triangles")
}
