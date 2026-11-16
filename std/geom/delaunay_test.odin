package geom

import "core:testing"
import "mirai:std/base"
import mm "mirai:std/math"

// Counter-clockwise triangles whose edges pair up, that cover the hull of the
// points (T = 2n - 2 - h) and keep every point out of every circle.
@(private) expect_delaunay :: proc(t:^testing.T,points:[]Vec2,used:int,triangles,halfedges:[]u32,what:string,loc:=#caller_location) {
    testing.expectf(t,len(halfedges)==len(triangles) && len(triangles)%3==0,"%s: sizes",what,loc=loc)
    hull:=0
    for twin,e in halfedges {
        if twin==NONE {hull+=1;continue}
        if int(twin)>=len(halfedges) || halfedges[twin]!=u32(e) {
            testing.expectf(t,false,"%s: edge %d and %d do not pair up",what,e,twin,loc=loc)
            return
        }
        a,b:=triangles[e],triangles[e/3*3+(e%3+1)%3]
        c,d:=triangles[twin],triangles[twin/3*3+(twin%3+1)%3]
        testing.expectf(t,a==d && b==c,"%s: edge %d is %d-%d and its twin %d-%d",what,e,a,b,c,d,loc=loc)
    }
    testing.expectf(t,len(triangles)/3==2*used-2-hull,"%s: %d triangles for %d points and %d hull edges",what,len(triangles)/3,used,hull,loc=loc)
    scale:f64
    for p in points {scale=max(scale,abs(f64(p.x)),abs(f64(p.y)))}
    for i:=0;i<len(triangles);i+=3 {
        a,b,c:=points[triangles[i]],points[triangles[i+1]],points[triangles[i+2]]
        ax,ay,bx,by,cx,cy:=f64(a.x),f64(a.y),f64(b.x),f64(b.y),f64(c.x),f64(c.y)
        area:=(bx-ax)*(cy-ay)-(by-ay)*(cx-ax)
        testing.expectf(t,area>0,"%s: triangle %d is not counter-clockwise (%v)",what,i/3,area,loc=loc)
        for p,k in points {
            if u32(k)==triangles[i] || u32(k)==triangles[i+1] || u32(k)==triangles[i+2] {continue}
            dx,dy,ex,ey,fx,fy:=ax-f64(p.x),ay-f64(p.y),bx-f64(p.x),by-f64(p.y),cx-f64(p.x),cy-f64(p.y)
            ap,bp,cp:=dx*dx+dy*dy,ex*ex+ey*ey,fx*fx+fy*fy
            inside:=dx*(ey*cp-bp*fy)-dy*(ex*cp-bp*fx)+ap*(ex*fy-ey*fx)
            if inside>1e-9*scale*scale*scale*scale {
                testing.expectf(t,false,"%s: point %d is inside the circle of triangle %d (%v)",what,k,i/3,inside,loc=loc)
                return
            }
        }
    }
}

@(test)
delaunay_triangulates_a_square_with_its_center :: proc(t:^testing.T) {
    triangles,halfedges:[dynamic]u32
    defer delete(triangles)
    defer delete(halfedges)
    points:=[]Vec2{{0,0},{2,0},{2,2},{0,2},{1,1}}
    testing.expect_value(t,delaunay_triangulate(points,&triangles,&halfedges),4)
    expect_delaunay(t,points,5,triangles[:],halfedges[:],"square")
    for i:=0;i<len(triangles);i+=3 {
        testing.expect(t,triangles[i]==4 || triangles[i+1]==4 || triangles[i+2]==4)
    }
    // Without the array of opposite edges, and reusing the output.
    testing.expect_value(t,delaunay_triangulate(points[:4],&triangles),2)
    testing.expect_value(t,len(triangles),6)
}

@(test)
delaunay_gives_nothing_for_points_without_area :: proc(t:^testing.T) {
    triangles,halfedges:[dynamic]u32
    defer delete(triangles)
    defer delete(halfedges)
    append(&triangles,7,7,7)
    testing.expect_value(t,delaunay_triangulate(nil,&triangles,&halfedges),0)
    testing.expect_value(t,len(triangles),0)
    testing.expect_value(t,delaunay_triangulate({{0,0},{1,1}},&triangles,&halfedges),0)
    line:[20]Vec2
    for &p,i in line {p={f32(i)*0.5,f32(i)*0.25+3}}
    testing.expect_value(t,delaunay_triangulate(line[:],&triangles,&halfedges),0)
    same:[9]Vec2
    for &p in same {p={4,-2}}
    testing.expect_value(t,delaunay_triangulate(same[:],&triangles,&halfedges),0)
    // Repeated points are left out of the triangles.
    repeated:=[]Vec2{{0,0},{1,0},{0,0},{0,1},{1,0},{1,1},{0,1},{0.25,0.5},{0.25,0.5}}
    testing.expect_value(t,delaunay_triangulate(repeated,&triangles,&halfedges),4)
    expect_delaunay(t,repeated,5,triangles[:],halfedges[:],"repeated")
}

@(test)
delaunay_handles_lattices_and_circles :: proc(t:^testing.T) {
    triangles,halfedges:[dynamic]u32
    points:[dynamic]Vec2
    defer delete(triangles)
    defer delete(halfedges)
    defer delete(points)
    // Every four neighbours of a lattice are on one circle.
    for y in 0..<9 {for x in 0..<12 {append(&points,Vec2{f32(x)*0.5+100,f32(y)*0.5-7})}}
    testing.expect_value(t,delaunay_triangulate(points[:],&triangles,&halfedges),2*11*8)
    area:f64
    for i:=0;i<len(triangles);i+=3 {
        a,b,c:=points[triangles[i]],points[triangles[i+1]],points[triangles[i+2]]
        twice:=f64(b.x-a.x)*f64(c.y-a.y)-f64(b.y-a.y)*f64(c.x-a.x)
        testing.expect(t,twice>0)
        area+=twice*0.5
    }
    testing.expectf(t,abs(area-5.5*4)<1e-6,"lattice area %v",area)
    // Points on one circle, and its center.
    clear(&points)
    for i in 0..<64 {
        s,c:=turn_sincos(f64(i)/64)
        append(&points,Vec2{f32(c)*3,f32(s)*3})
    }
    testing.expect_value(t,delaunay_triangulate(points[:],&triangles,&halfedges),62)
    append(&points,Vec2{0,0})
    testing.expect_value(t,delaunay_triangulate(points[:],&triangles,&halfedges),64)
    expect_delaunay(t,points[:],65,triangles[:],halfedges[:],"circle")
}

@(test)
delaunay_keeps_every_point_out_of_every_circle :: proc(t:^testing.T) {
    triangles,halfedges,again:[dynamic]u32
    points:[dynamic]Vec2
    defer delete(triangles)
    defer delete(halfedges)
    defer delete(again)
    defer delete(points)
    rng:=base.rng_make(0xde1a)
    for round in 0..<60 {
        count:=3+int(base.rng_u32(&rng)%300)
        scales:=[3]f32{1,1e-3,5e4}
        scale:=scales[round%3]
        offset:=Vec2{mm.random_f32(&rng),mm.random_f32(&rng)}*scale*(round%4==0?50:1)
        resize(&points,count)
        for &p in points {
            switch round%5 {
            case 0,1: p={mm.random_f32(&rng),mm.random_f32(&rng)}
            case 2: b:=mm.random_in_sphere(&rng);p={b.x,b.y}
            case 3: p={mm.random_f32(&rng),mm.random_f32(&rng)*0.01}
            case 4: p={mm.random_f32(&rng)*mm.random_f32(&rng),mm.random_f32(&rng)*mm.random_f32(&rng)*mm.random_f32(&rng)}
            }
            p=p*scale+offset
        }
        found:=delaunay_triangulate(points[:],&triangles,&halfedges)
        testing.expectf(t,found>0,"round %d: no triangles for %d points",round,count)
        expect_delaunay(t,points[:],count,triangles[:],halfedges[:],"random")
        delaunay_triangulate(points[:],&again)
        testing.expectf(t,bytes_equal(triangles[:],again[:]),"round %d: two triangulations differ",round)
    }
}
