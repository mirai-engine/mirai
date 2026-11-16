package mirai_render

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
