package geom

import "core:testing"
import "mirai:std/base"
import mm "mirai:std/math"

@(private) loop_area :: proc(points:[]Vec2) -> f64 {
    area:f64
    for p,i in points {
        q:=points[(i+1)%len(points)]
        area+=f64(p.x)*f64(q.y)-f64(q.x)*f64(p.y)
    }
    return area*0.5
}

// Triangles cover `expected_area` without overlap (none is clockwise), and
// every edge of every loop is the edge of exactly one triangle while every
// other edge is shared by two.
@(private) expect_triangulation :: proc(t:^testing.T,points:[]Vec2,loop_sizes:[]int,triangles:[]u32,expected_area:f64,loc:=#caller_location) {
    area:f64
    edges:=make(map[[2]u32]int)
    defer delete(edges)
    for i:=0;i+2<len(triangles);i+=3 {
        a,b,c:=points[triangles[i]],points[triangles[i+1]],points[triangles[i+2]]
        twice:=f64(b.x-a.x)*f64(c.y-a.y)-f64(b.y-a.y)*f64(c.x-a.x)
        testing.expectf(t,twice>=-1e-9,"triangle %d is clockwise: %v",i/3,twice,loc=loc)
        area+=twice*0.5
        for k in 0..<3 {edges[{triangles[i+k],triangles[i+(k+1)%3]}]+=1}
    }
    testing.expectf(t,abs(area-expected_area)<=1e-5*max(1,abs(expected_area)),"area %v, expected %v",area,expected_area,loc=loc)
    first:=0
    border:=0
    for size in loop_sizes {
        for i in 0..<size {
            a,b:=u32(first+i),u32(first+(i+1)%size)
            forwards,backwards:=edges[{a,b}],edges[{b,a}]
            testing.expectf(t,forwards+backwards==1,"loop edge %d-%d is used %d times",a,b,forwards+backwards,loc=loc)
            border+=1
        }
        first+=size
    }
    inner:=0
    for edge,count in edges {
        testing.expectf(t,count==1,"edge %v is used %d times in one direction",edge,count,loc=loc)
        if edges[{edge[1],edge[0]}]==1 {inner+=1}
    }
    testing.expect_value(t,inner+border,len(edges),loc=loc)
}

@(test)
ear_clipping_covers_convex_and_concave_polygons :: proc(t:^testing.T) {
    out:[dynamic]u32
    defer delete(out)
    square:=[]Vec2{{0,0},{2,0},{2,2},{0,2}}
    testing.expect_value(t,polygon_triangulate(square,{4},&out),2)
    expect_triangulation(t,square,{4},out[:],4)
    // A comb, counter-clockwise and clockwise.
    comb:=[]Vec2{{0,0},{7,0},{7,3},{6,3},{6,1},{5,1},{5,3},{4,3},{4,1},{3,1},{3,3},{2,3},{2,1},{1,1},{1,3},{0,3}}
    clear(&out)
    testing.expect_value(t,polygon_triangulate(comb,{len(comb)},&out),len(comb)-2)
    expect_triangulation(t,comb,{len(comb)},out[:],loop_area(comb))
    reversed:[16]Vec2
    for p,i in comb {reversed[len(comb)-1-i]=p}
    clear(&out)
    testing.expect_value(t,polygon_triangulate(reversed[:],{16},&out),14)
    expect_triangulation(t,reversed[:],{16},out[:],loop_area(comb))
    // Appending keeps what was there, and fewer than three points give nothing.
    testing.expect_value(t,polygon_triangulate(square[:2],{2},&out),0)
    testing.expect_value(t,len(out),14*3)
    testing.expect_value(t,polygon_triangulate(nil,nil,&out),0)
}

@(test)
ear_clipping_bridges_holes :: proc(t:^testing.T) {
    out:[dynamic]u32
    defer delete(out)
    // A square with two square holes, the second one counter-clockwise.
    points:=[]Vec2{
        {0,0},{10,0},{10,10},{0,10},
        {2,2},{2,4},{4,4},{4,2},
        {6,5},{8,5},{8,8},{6,8},
    }
    sizes:=[]int{4,4,4}
    testing.expect_value(t,polygon_triangulate(points,sizes,&out),12+2*2-2)
    expect_triangulation(t,points,sizes,out[:],100-4-6)
    // A hole inside a hole's shadow and a hole that touches the outline.
    nested:=[]Vec2{
        {0,0},{10,0},{10,10},{0,10},
        {7,4},{7,6},{9,6},{9,4},
        {1,4},{1,6},{6,6},{6,4},
        {0,8},{1,9},{1,7},
    }
    sizes=[]int{4,4,4,3}
    clear(&out)
    testing.expect_value(t,polygon_triangulate(nested,sizes,&out),15+2*3-2)
    expect_triangulation(t,nested,sizes,out[:],100-4-10-1)
}

@(test)
ear_clipping_by_orientation_fills_several_outlines :: proc(t:^testing.T) {
    out:[dynamic]u32
    defer delete(out)
    // Two outlines, a hole in the first and an island inside that hole.
    points:=[]Vec2{
        {0,0},{10,0},{10,10},{0,10},
        {20,0},{23,0},{20,3},
        {2,2},{2,8},{8,8},{8,2},
        {4,4},{6,4},{6,6},{4,6},
    }
    sizes:=[]int{4,3,4,4}
    count:=polygon_triangulate(points,sizes,&out,.Orientation)
    testing.expect_value(t,count,(4+4+2-2)+1+2)
    expect_triangulation(t,points,sizes,out[:],100-36+4+4.5)
    // A clockwise loop outside every outline is filled clockwise.
    orphan:=[]Vec2{{0,0},{0,1},{1,1},{1,0}}
    clear(&out)
    testing.expect_value(t,polygon_triangulate(orphan,{4},&out,.Orientation),2)
    for i:=0;i<len(out);i+=3 {
        a,b,c:=orphan[out[i]],orphan[out[i+1]],orphan[out[i+2]]
        testing.expect(t,(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)<0)
    }
}

@(test)
ear_clipping_keeps_collinear_and_repeated_points :: proc(t:^testing.T) {
    out:[dynamic]u32
    defer delete(out)
    // Extra points on every side of a triangle and of a square.
    triangle:=[]Vec2{{0,0},{1,0},{2,0},{3,0},{4,0},{3,1},{2,2},{1,1}}
    testing.expect_value(t,polygon_triangulate(triangle,{8},&out),6)
    expect_triangulation(t,triangle,{8},out[:],4)
    // A repeated corner and a spike without area.
    spiked:=[]Vec2{{0,0},{4,0},{4,0},{4,4},{2,4},{2,6},{2,4},{0,4}}
    clear(&out)
    testing.expect_value(t,polygon_triangulate(spiked,{8},&out),6)
    expect_triangulation(t,spiked,{8},out[:],16)
    // Nothing but a line: triangles without area that still use every edge.
    line:=[]Vec2{{0,0},{1,0},{2,0},{3,0},{2,0},{1,0}}
    clear(&out)
    testing.expect_value(t,polygon_triangulate(line,{6},&out),4)
    expect_triangulation(t,line,{6},out[:],0)
    // Two squares that share a corner, as one loop.
    touching:=[]Vec2{{0,0},{1,0},{1,1},{2,1},{2,2},{1,2},{1,1},{0,1}}
    clear(&out)
    testing.expect_value(t,polygon_triangulate(touching,{8},&out),6)
    expect_triangulation(t,touching,{8},out[:],2)
}

@(test)
ear_clipping_survives_random_polygons :: proc(t:^testing.T) {
    out:[dynamic]u32
    points:[dynamic]Vec2
    defer delete(out)
    defer delete(points)
    rng:=base.rng_make(0xea5)
    for round in 0..<200 {
        // Star-shaped outline with a star-shaped hole, on a coarse grid in
        // half of the rounds so that points repeat and line up.
        count:=3+int(base.rng_u32(&rng)%40)
        hole:=3+int(base.rng_u32(&rng)%12) if round%3==0 else 0
        clear(&points)
        for i in 0..<count {
            s,c:=turn_sincos(f64(i)/f64(count))
            radius:=3+mm.random_f32(&rng)*7
            p:=Vec2{f32(c)*radius,f32(s)*radius}
            if round%2==0 {p={f32(int(p.x*2))/2,f32(int(p.y*2))/2}}
            append(&points,p)
        }
        for i in 0..<hole {
            s,c:=turn_sincos(f64(i)/f64(hole))
            radius:=0.5+mm.random_f32(&rng)*2
            append(&points,Vec2{f32(c)*radius,-f32(s)*radius})
        }
        sizes:=[]int{count,hole} if hole>0 else []int{count}
        clear(&out)
        triangles:=polygon_triangulate(points[:],sizes,&out)
        testing.expect_value(t,triangles,count-2 if hole==0 else count+hole)
        if round%2==0 {continue}
        area:=loop_area(points[:count])
        if hole>0 {area-=abs(loop_area(points[count:]))}
        expect_triangulation(t,points[:],sizes,out[:],area)
        again:[dynamic]u32
        defer delete(again)
        polygon_triangulate(points[:],sizes,&again)
        testing.expect(t,bytes_equal(out[:],again[:]))
    }
}
