package geom

import "core:math"
import "core:slice"
import "core:testing"

@(private="file") Partition_Case :: struct {
    name:      string,
    points:    []Vec2,
    loops:     []int,
    area:      f64, // of the outline minus the holes
    max_pieces:int, // Hertel-Mehlhorn: twice the reflex corners, minus the holes, plus one
}

@(private="file") inside_loops :: proc(points:[]Vec2,loops:[]int,p:[2]f64) -> bool {
    inside:=false
    first:=0
    for size in loops {
        for i in 0..<size {
            a,b:=points[first+i],points[first+(i+1)%size]
            ay,by:=f64(a.y),f64(b.y)
            if (ay>p.y)!=(by>p.y) && p.x<f64(a.x)+(p.y-ay)*f64(b.x-a.x)/(by-ay) {inside=!inside}
        }
        first+=size
    }
    return inside
}

// Two convex counter-clockwise pieces overlap with area unless an edge of one
// separates them.
@(private="file") pieces_overlap :: proc(points:[]Vec2,a,b:[]u32,tolerance:f64) -> bool {
    for piece in ([2][]u32{a,b}) {
        for i in 0..<len(piece) {
            p,q:=points[piece[i]],points[piece[(i+1)%len(piece)]]
            n:=[2]f64{f64(q.y)-f64(p.y),f64(p.x)-f64(q.x)}
            lo,hi:=[2]f64{max(f64),max(f64)},[2]f64{-max(f64),-max(f64)}
            for other,k in ([2][]u32{a,b}) {
                for index in other {
                    s:=n.x*f64(points[index].x)+n.y*f64(points[index].y)
                    lo[k],hi[k]=min(lo[k],s),max(hi[k],s)
                }
            }
            if hi[0]<=lo[1]+tolerance || hi[1]<=lo[0]+tolerance {return false}
        }
    }
    return true
}

@(test)
convex_partition_covers_the_polygon_with_convex_pieces_that_do_not_overlap :: proc(t:^testing.T) {
    circle:[64]Vec2
    for &p,i in circle {
        angle:=f32(i)*math.TAU/64
        p={math.cos(angle),math.sin(angle)}
    }
    circle_area:=loop_area(circle[:])
    star:[10]Vec2
    for &p,i in star {
        angle:=f32(i)*math.TAU/10+math.PI/2
        radius:f32=2 if i%2==0 else 0.8
        p={radius*math.cos(angle),radius*math.sin(angle)}
    }
    comb:=[]Vec2{{0,0},{7,0},{7,3},{6,3},{6,1},{5,1},{5,3},{4,3},{4,1},{3,1},{3,3},{2,3},{2,1},{1,1},{1,3},{0,3}}
    cases:=[]Partition_Case{
        {"square",{{0,0},{2,0},{2,2},{0,2}},{4},4,1},
        {"clockwise square",{{0,0},{0,2},{2,2},{2,0}},{4},4,1},
        {"circle of 64 points",circle[:],{64},circle_area,1},
        {"collinear and repeated points",{{0,0},{1,0},{2,0},{2,1},{2,2},{2,2},{1,2},{0,2},{0,1},{0,0}},{10},4,1},
        {"L",{{0,0},{2,0},{2,1},{1,1},{1,2},{0,2}},{6},3,3},
        {"star",star[:],{10},loop_area(star[:]),11},
        {"comb",comb,{16},loop_area(comb),13},
        {"one hole",{{0,0},{10,0},{10,10},{0,10},{2,2},{2,4},{4,4},{4,2}},{4,4},96,8},
        {"two holes",{{0,0},{10,0},{10,10},{0,10},{2,2},{2,4},{4,4},{4,2},{6,5},{8,5},{8,8},{6,8}},{4,4,4},90,15},
        {"hole touching the outline",{{0,0},{4,0},{4,4},{0,4},{0,0},{1,2},{2,3},{3,2},{2,1}},{4,5},12.5,10},
    }
    indices,sizes,again,again_sizes:[dynamic]u32
    defer {delete(indices);delete(sizes);delete(again);delete(again_sizes)}
    for c in cases {
        clear(&indices);clear(&sizes)
        append(&indices,7);append(&sizes,7)
        count:=polygon_convex_partition(c.points,c.loops,&indices,&sizes)
        testing.expectf(t,count>=1 && count<=c.max_pieces,"%s: %d pieces, at most %d",c.name,count,c.max_pieces)
        testing.expectf(t,indices[0]==7 && sizes[0]==7 && len(sizes)==count+1,"%s: does not append",c.name)
        clear(&again);clear(&again_sizes)
        append(&again,7);append(&again_sizes,7)
        testing.expect_value(t,polygon_convex_partition(c.points,c.loops,&again,&again_sizes),count)
        testing.expectf(t,slice.equal(indices[:],again[:]) && slice.equal(sizes[:],again_sizes[:]),"%s: not deterministic",c.name)
        pieces:=make([dynamic][]u32,context.temp_allocator)
        area:f64
        first:=1
        for size in sizes[1:] {
            if !testing.expectf(t,size>=3 && first+int(size)<=len(indices),"%s: piece of %d points",c.name,size) {break}
            piece:=indices[first:first+int(size)]
            first+=int(size)
            append(&pieces,piece)
            centroid:[2]f64
            piece_area:f64
            for index,i in piece {
                testing.expectf(t,int(index)<len(c.points),"%s: index %d out of range",c.name,index)
                a,b,n:=c.points[index],c.points[piece[(i+1)%len(piece)]],c.points[piece[(i+2)%len(piece)]]
                twice:=f64(b.x-a.x)*f64(n.y-a.y)-f64(b.y-a.y)*f64(n.x-a.x)
                testing.expectf(t,twice>0,"%s: corner %d of a piece is not strictly convex: %v",c.name,i,twice)
                piece_area+=(f64(a.x)*f64(b.y)-f64(b.x)*f64(a.y))*0.5
                centroid+={f64(a.x),f64(a.y)}
            }
            area+=piece_area
            centroid/=f64(len(piece))
            testing.expectf(t,inside_loops(c.points,c.loops,centroid),"%s: piece around %v is outside",c.name,centroid)
        }
        testing.expectf(t,first==len(indices),"%s: sizes add up to %d of %d indices",c.name,first,len(indices))
        testing.expectf(t,abs(area-c.area)<=1e-5*max(1,c.area),"%s: area %v, expected %v",c.name,area,c.area)
        for i in 0..<len(pieces) {
            for j in i+1..<len(pieces) {
                testing.expectf(t,!pieces_overlap(c.points,pieces[i],pieces[j],1e-9),"%s: pieces %d and %d overlap",c.name,i,j)
            }
        }
        free_all(context.temp_allocator)
    }
}
