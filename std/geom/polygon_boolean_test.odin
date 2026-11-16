package geom

import "core:fmt"
import "core:math"
import "core:mem"
import "core:testing"
import "core:time"

@(private="file") rect :: proc(x0,y0,x1,y1:f32) -> [4]Vec2 {return {{x0,y0},{x1,y0},{x1,y1},{x0,y1}}}

@(private="file") circle :: proc(center:Vec2,radius:f32,$N:int) -> (points:[N]Vec2) {
    for &p,i in points {
        angle:=2*math.PI*f64(i)/f64(N)
        p=center+radius*Vec2{f32(math.cos(angle)),f32(math.sin(angle))}
    }
    return
}

@(private="file") set_area :: proc(set:Polygon_Set) -> f64 {
    area:f64
    first:=0
    for size in set.loop_sizes {
        area+=loop_area(set.points[first:first+size])
        first+=size
    }
    return area
}

@(private="file") orient64 :: proc(a,b,c:Vec2) -> f64 {
    return (f64(b.x)-f64(a.x))*(f64(c.y)-f64(a.y))-(f64(b.y)-f64(a.y))*(f64(c.x)-f64(a.x))
}

@(private="file") on_segment :: proc(a,b,p:Vec2) -> bool {
    return orient64(a,b,p)==0 && min(a.x,b.x)<=p.x && p.x<=max(a.x,b.x) && min(a.y,b.y)<=p.y && p.y<=max(a.y,b.y)
}

@(private="file") segments_touch :: proc(a,b,c,d:Vec2) -> bool {
    d1,d2,d3,d4:=orient64(a,b,c),orient64(a,b,d),orient64(c,d,a),orient64(c,d,b)
    if d1*d2<0 && d3*d4<0 {return true}
    return on_segment(a,b,c) || on_segment(a,b,d) || on_segment(c,d,a) || on_segment(c,d,b)
}

@(private="file") segments_cross :: proc(a,b,c,d:Vec2) -> bool {
    return orient64(a,b,c)*orient64(a,b,d)<0 && orient64(c,d,a)*orient64(c,d,b)<0
}

@(private="file") loop_holds :: proc(ring:[]Vec2,p:[2]f64) -> bool {
    inside:=false
    for a,i in ring {
        b:=ring[(i+1)%len(ring)]
        ay,by:=f64(a.y),f64(b.y)
        if (ay>p.y)!=(by>p.y) && p.x<f64(a.x)+(p.y-ay)*(f64(b.x)-f64(a.x))/(by-ay) {inside=!inside}
    }
    return inside
}

// Counts add up, outlines are counter-clockwise and holes clockwise, every loop is simple, no
// two edges of the set cross and every hole lies in its outline.
@(private="file") expect_polygon_set :: proc(t:^testing.T,set:Polygon_Set,loc:=#caller_location) -> bool {
    loops,points:=0,0
    for count in set.polygon_loops {
        if !testing.expectf(t,count>=1,"a polygon of %d loops",count,loc=loc) {return false}
        loops+=count
    }
    for size in set.loop_sizes {points+=size}
    if !testing.expectf(t,loops==len(set.loop_sizes) && points==len(set.points),"%d loops and %d points for %d and %d",loops,points,len(set.loop_sizes),len(set.points),loc=loc) {return false}
    rings:=make([][]Vec2,len(set.loop_sizes),context.temp_allocator)
    first:=0
    for size,i in set.loop_sizes {
        rings[i]=set.points[first:first+size]
        first+=size
    }
    loop:=0
    for count in set.polygon_loops {
        for k in 0..<count {
            ring:=rings[loop+k]
            n:=len(ring)
            if !testing.expectf(t,n>=3,"loop %d has %d points",loop+k,n,loc=loc) {return false}
            area:=loop_area(ring)
            if !testing.expectf(t,(area>0)==(k==0) && area!=0,"loop %d of area %v as %s",loop+k,area,k==0?"outline":"hole",loc=loc) {return false}
            for i in 0..<n {
                for j in i+1..<n {
                    a,b,c,d:=ring[i],ring[(i+1)%n],ring[j],ring[(j+1)%n]
                    if j==i+1 || (i==0 && j==n-1) {
                        shared:=b if j==i+1 else a
                        other_a,other_b:=a if j==i+1 else b,d if j==i+1 else c
                        bad:=other_a==shared || other_b==shared || (orient64(other_a,shared,other_b)==0 && (f64(shared.x)-f64(other_a.x))*(f64(other_b.x)-f64(shared.x))+(f64(shared.y)-f64(other_a.y))*(f64(other_b.y)-f64(shared.y))<0)
                        if !testing.expectf(t,!bad,"loop %d folds back at %v",loop+k,shared,loc=loc) {return false}
                        continue
                    }
                    if !testing.expectf(t,!segments_touch(a,b,c,d),"loop %d touches itself: %v-%v and %v-%v",loop+k,a,b,c,d,loc=loc) {return false}
                }
            }
            if k>0 {
                mid:=[2]f64{(f64(ring[0].x)+f64(ring[1].x))/2,(f64(ring[0].y)+f64(ring[1].y))/2}
                if !testing.expectf(t,loop_holds(rings[loop],mid),"hole %d is not in its outline",loop+k,loc=loc) {return false}
            }
        }
        loop+=count
    }
    for ra,i in rings {
        for rb in rings[i+1:] {
            for a,p in ra {
                b:=ra[(p+1)%len(ra)]
                for c,q in rb {
                    d:=rb[(q+1)%len(rb)]
                    if !testing.expectf(t,!segments_cross(a,b,c,d),"loops cross: %v-%v and %v-%v",a,b,c,d,loc=loc) {return false}
                }
            }
        }
    }
    return true
}

@(private="file") Boolean_Case :: struct {
    name:string,
    a:[]Vec2,a_loops:[]int,
    b:[]Vec2,b_loops:[]int,
    area_a,area_b:f64,
}

@(test)
polygon_boolean_areas_add_up_and_results_are_valid :: proc(t:^testing.T) {
    square:=rect(0,0,2,2)
    shifted:=rect(1,1,3,3)
    beside:=rect(2,0,4,2)
    corner:=rect(2,2,4,4)
    on_top:=rect(0.5,2,1.5,3)
    notch:=rect(0.5,1,1.5,2)
    long:=rect(1,0,3,1)
    disc:=circle({1,2},0.75,32)
    inner_disc:=circle({1,1},0.5,32)
    triangle:=[3]Vec2{{-1,0.5},{3,1},{-1,1.5}}
    touching_triangle:=[3]Vec2{{1,0},{1.5,1},{0.5,1}}
    holed:=[8]Vec2{{0,0},{4,0},{4,4},{0,4},{1,1},{3,1},{3,3},{1,3}}
    cover:=rect(0.5,0.5,3.5,3.5)
    rotated:=[4]Vec2{{1,-0.5},{2.5,1},{1,2.5},{-0.5,1}}
    cases:=[]Boolean_Case{
        {"overlapping squares",square[:],{4},shifted[:],{4},4,4},
        {"identical squares",square[:],{4},square[:],{4},4,4},
        {"squares sharing an edge",square[:],{4},beside[:],{4},4,4},
        {"squares sharing a corner",square[:],{4},corner[:],{4},4,4},
        {"stamp on the outside of an edge",square[:],{4},on_top[:],{4},4,1},
        {"stamp on the inside of an edge",square[:],{4},notch[:],{4},4,1},
        {"collinear overlapping edges",square[:],{4},long[:],{4},4,2},
        {"circle centred on an edge",square[:],{4},disc[:],{32},4,loop_area(disc[:])},
        {"circle inside",square[:],{4},inner_disc[:],{32},4,loop_area(inner_disc[:])},
        {"triangle across",square[:],{4},triangle[:],{3},4,loop_area(triangle[:])},
        {"triangle touching an edge at a vertex",square[:],{4},touching_triangle[:],{3},4,loop_area(touching_triangle[:])},
        {"polygon with a hole",holed[:],{4,4},cover[:],{4},12,9},
        {"diamond through the corners",square[:],{4},rotated[:],{4},4,loop_area(rotated[:])},
    }
    set:Polygon_Set
    polygon_set_init(&set)
    defer polygon_set_destroy(&set)
    for c in cases {
        areas:[Polygon_Op]f64
        for op in Polygon_Op {
            testing.expect_value(t,polygon_boolean(c.a,c.a_loops,c.b,c.b_loops,op,&set),Polygon_Error.None)
            if !expect_polygon_set(t,set) {testing.expectf(t,false,"%s, %v",c.name,op)}
            areas[op]=set_area(set)
        }
        tolerance:=1e-4*(c.area_a+c.area_b)
        testing.expectf(t,abs(areas[.Union]-(c.area_a+c.area_b-areas[.Intersection]))<=tolerance,"%s: union %v, intersection %v",c.name,areas[.Union],areas[.Intersection])
        testing.expectf(t,abs(areas[.Difference]-(c.area_a-areas[.Intersection]))<=tolerance,"%s: difference %v, intersection %v",c.name,areas[.Difference],areas[.Intersection])
    }
}

@(test)
polygon_boolean_splits_cuts_holes_and_fills :: proc(t:^testing.T) {
    Shape_Case :: struct {
        name:string,
        a:[]Vec2,a_loops:[]int,
        b:[]Vec2,b_loops:[]int,
        op:Polygon_Op,
        polygons,loops,points:int, // points 0: not checked
        area:f64,
    }
    bar:=rect(0,0,4,1)
    blade:=rect(1.5,-1,2.5,2)
    square:=rect(0,0,4,4)
    disc:=circle({2,2},1,32)
    left:=rect(0,0,1,1)
    right:=rect(2,0,3,1)
    beside:=rect(1,0,2,1)
    corner:=rect(1,1,2,2)
    holed:=[8]Vec2{{0,0},{4,0},{4,4},{0,4},{1,1},{1,3},{3,3},{3,1}}
    cover:=rect(0.5,0.5,3.5,3.5)
    top_notch:=rect(1,3,2,4)
    spike:=[3]Vec2{{2,0},{3,1},{1,1}}
    cases:=[]Shape_Case{
        {"a cut through the middle splits",bar[:],{4},blade[:],{4},.Difference,2,2,8,3},
        {"a circle inside opens a hole",square[:],{4},disc[:],{32},.Difference,1,2,36,16-loop_area(disc[:])},
        {"disjoint squares stay apart",left[:],{4},right[:],{4},.Union,2,2,8,2},
        {"squares on a shared edge merge without the seam",left[:],{4},beside[:],{4},.Union,1,1,4,2},
        {"squares on a shared corner stay apart",left[:],{4},corner[:],{4},.Union,2,2,8,2},
        {"a union that covers the hole removes it",holed[:],{4,4},cover[:],{4},.Union,1,1,4,16},
        {"a stamp flush with an edge leaves a notch",square[:],{4},top_notch[:],{4},.Difference,1,1,8,15},
        {"a cut that touches the outline at a vertex is a hole",square[:],{4},spike[:],{3},.Difference,1,2,0,15},
        {"disjoint intersection is empty",left[:],{4},right[:],{4},.Intersection,0,0,0,0},
    }
    set:Polygon_Set
    polygon_set_init(&set)
    defer polygon_set_destroy(&set)
    for c in cases {
        testing.expect_value(t,polygon_boolean(c.a,c.a_loops,c.b,c.b_loops,c.op,&set),Polygon_Error.None)
        expect_polygon_set(t,set)
        testing.expectf(t,len(set.polygon_loops)==c.polygons && len(set.loop_sizes)==c.loops,"%s: %d polygons and %d loops",c.name,len(set.polygon_loops),len(set.loop_sizes))
        testing.expectf(t,c.points==0 || len(set.points)==c.points,"%s: %d points",c.name,len(set.points))
        testing.expectf(t,abs(set_area(set)-c.area)<=1e-4,"%s: area %v, expected %v",c.name,set_area(set),c.area)
    }
}

// Carves a channel with 200 circles along a line and grows a stroke with 200 more, each result
// the input of the next; stamping the last circle again changes nothing.
@(test)
polygon_boolean_repeated_stamps_stay_valid_and_bounded :: proc(t:^testing.T) {
    STAMPS :: 200
    SPACING :: 0.09
    for op in ([]Polygon_Op{.Difference,.Union}) {
        set,next:Polygon_Set
        polygon_set_init(&set);polygon_set_init(&next)
        defer {polygon_set_destroy(&set);polygon_set_destroy(&next)}
        start:=rect(0,0,20,4)
        if op==.Union {start=rect(0.7,1.9,1.3,2.1)}
        append(&set.points,..start[:])
        append(&set.loop_sizes,4)
        append(&set.polygon_loops,1)
        stamp:[32]Vec2
        for i in 0..<STAMPS {
            // A jitter far below the spacing puts crossings next to earlier points.
            jitter:=f32(i%7)*2e-6
            stamp=circle({1+f32(i)*SPACING,2+jitter},0.5,32)
            error:=polygon_boolean(set.points[:],set.loop_sizes[:],stamp[:],{32},op,&next)
            if !testing.expectf(t,error==.None,"%v stamp %d: %v",op,i,error) {return}
            set,next=next,set
            if !testing.expectf(t,len(set.polygon_loops)==1 && len(set.loop_sizes)==(op==.Difference?2:1),"%v stamp %d: %d polygons, %d loops",op,i,len(set.polygon_loops),len(set.loop_sizes)) {return}
            if i%25==24 && !expect_polygon_set(t,set) {return}
        }
        expect_polygon_set(t,set)
        // Each side of the stroke keeps about a corner and a crossing of every circle, with no
        // edge much shorter than the spacing.
        testing.expectf(t,len(set.points)<=4+32+5*STAMPS,"%v: %d points after %d stamps",op,len(set.points),STAMPS)
        first:=0
        for size in set.loop_sizes {
            for k in 0..<size {
                a,b:=set.points[first+k],set.points[first+(k+1)%size]
                testing.expectf(t,abs(a.x-b.x)+abs(a.y-b.y)>=SPACING/4,"%v: edge %v-%v",op,a,b)
            }
            first+=size
        }
        stroke:=f64(STAMPS-1)*SPACING
        expected:=stroke*1+math.PI*0.25
        area:=abs(set_area(set)-(op==.Difference?80:0))
        testing.expectf(t,area>expected*0.97 && area<expected*1.001,"%v: stroke of area %v, about %v",op,area,expected)
        count,area_before:=len(set.points),set_area(set)
        testing.expect_value(t,polygon_boolean(set.points[:],set.loop_sizes[:],stamp[:],{32},op,&next),Polygon_Error.None)
        testing.expectf(t,len(next.points)==count && abs(set_area(next)-area_before)<1e-9,"%v: the same stamp again gives %d points (%d) and area %v (%v)",op,len(next.points),count,set_area(next),area_before)
    }
}

// Polygons on a coarse lattice: shared vertices, collinear runs, self-crossings and repeated
// points. The four results add up and are valid.
@(test)
polygon_boolean_degenerate_polygons_give_valid_results :: proc(t:^testing.T) {
    state:=u64(7)
    random :: proc(state:^u64,below:int) -> int {
        state^=state^*6364136223846793005+1442695040888963407
        return int((state^>>33)%u64(below))
    }
    a,b:[dynamic]Vec2
    set:Polygon_Set
    defer {delete(a);delete(b);polygon_set_destroy(&set)}
    for round in 0..<300 {
        clear(&a);clear(&b)
        for _ in 0..<3+random(&state,8) {append(&a,Vec2{f32(random(&state,5)),f32(random(&state,5))}*0.5)}
        for _ in 0..<3+random(&state,8) {append(&b,Vec2{f32(random(&state,5)),f32(random(&state,5))}*0.5+0.25*f32(round%2))}
        areas:[4]f64
        for op,k in ([]Polygon_Op{.Union,.Intersection,.Difference}) {
            testing.expect_value(t,polygon_boolean(a[:],{len(a)},b[:],{len(b)},op,&set),Polygon_Error.None)
            if !expect_polygon_set(t,set) {testing.expectf(t,false,"round %d, %v: %v and %v",round,op,a[:],b[:]);return}
            areas[k]=set_area(set)
        }
        testing.expect_value(t,polygon_boolean(b[:],{len(b)},a[:],{len(a)},.Difference,&set),Polygon_Error.None)
        expect_polygon_set(t,set)
        areas[3]=set_area(set)
        testing.expectf(t,abs(areas[0]-(areas[1]+areas[2]+areas[3]))<=1e-4,"round %d: union %v is not %v+%v+%v",round,areas[0],areas[1],areas[2],areas[3])
        testing.expect_value(t,polygon_boolean(a[:],{len(a)},a[:],{len(a)},.Difference,&set),Polygon_Error.None)
        testing.expect_value(t,len(set.points),0)
    }
}

// Circles, squares and triangles added and cut at random, half of them dragged a little from the
// last one, some on a coarse lattice; the first polygon of each result is the next input.
@(test)
polygon_boolean_random_drags_stay_valid :: proc(t:^testing.T) {
    state:=u64(12345)
    random :: proc(state:^u64) -> f32 {
        state^=state^*6364136223846793005+1442695040888963407
        return f32(state^>>40)/f32(1<<24)
    }
    set,next:Polygon_Set
    defer {polygon_set_destroy(&set);polygon_set_destroy(&next)}
    sizes:=[3]int{32,4,3}
    start:=rect(0,0,10,6)
    center:Vec2
    radius:f32
    for step in 0..<1500 {
        if len(set.polygon_loops)==0 {
            polygon_set_clear(&set)
            append(&set.points,..start[:])
            append(&set.loop_sizes,4)
            append(&set.polygon_loops,1)
        }
        n:=sizes[int(random(&state)*3)]
        angle:=f64(random(&state))*2*math.PI
        if random(&state)<0.5 {
            center+=Vec2{random(&state)-0.5,random(&state)-0.5}*0.01
        } else {
            center,radius=Vec2{random(&state)*10,random(&state)*6},0.2+random(&state)*1.5
            if random(&state)<0.3 {center,radius,angle=Vec2{f32(int(center.x*4)),f32(int(center.y*4))}/4,f32(int(radius*4)+1)/4,0}
        }
        stamp:[32]Vec2
        for k in 0..<n {
            a:=angle+2*math.PI*f64(k)/f64(n)
            stamp[k]=center+radius*Vec2{f32(math.cos(a)),f32(math.sin(a))}
        }
        op:=Polygon_Op.Union if random(&state)<0.5 else .Difference
        loops,points:=set.polygon_loops[0],0
        for size in set.loop_sizes[:loops] {points+=size}
        error:=polygon_boolean(set.points[:points],set.loop_sizes[:loops],stamp[:n],{n},op,&next)
        if !testing.expectf(t,error==.None,"step %d: %v",step,error) {return}
        if step%10==0 && !expect_polygon_set(t,next) {testing.expectf(t,false,"step %d, %v",step,op);return}
        set,next=next,set
    }
}

@(test)
polygon_boolean_rejects_hostile_input :: proc(t:^testing.T) {
    square:=rect(0,0,1,1)
    nan:=[4]Vec2{{0,0},{1,0},{f32(0h7fc00000),1},{0,1}}
    inf:=[4]Vec2{{0,0},{f32(0h7f800000),0},{1,1},{0,1}}
    set:Polygon_Set
    defer polygon_set_destroy(&set)
    append(&set.points,Vec2{9,9})
    for loops in ([][]int{{max(int),max(int)},{5},{-1,4},{2},{},{4,0},{3,max(int)}}) {
        testing.expect_value(t,polygon_boolean(square[:],loops,square[:],{4},.Union,&set),Polygon_Error.Invalid)
        testing.expect_value(t,polygon_boolean(square[:],{4},square[:],loops,.Union,&set),Polygon_Error.Invalid)
        testing.expect_value(t,len(set.points),0)
    }
    testing.expect_value(t,polygon_boolean(nan[:],{4},square[:],{4},.Union,&set),Polygon_Error.Invalid)
    testing.expect_value(t,polygon_boolean(square[:],{4},inf[:],{4},.Difference,&set),Polygon_Error.Invalid)
    testing.expect_value(t,polygon_boolean(square[:],{4},square[:],{4},Polygon_Op(7),&set),Polygon_Error.Invalid)
    testing.expect_value(t,polygon_boolean(square[:],{4},square[:],{4},.Union,nil),Polygon_Error.Invalid)
    huge:=[4]Vec2{{-1e30,-1e30},{1e30,-1e30},{1e30,1e30},{-1e30,1e30}}
    tiny:=[4]Vec2{{0,0},{1e-30,0},{1e-30,1e-30},{0,1e-30}}
    testing.expect_value(t,polygon_boolean(huge[:],{4},square[:],{4},.Difference,&set),Polygon_Error.None)
    expect_polygon_set(t,set)
    testing.expect_value(t,polygon_boolean(tiny[:],{4},tiny[:],{4},.Union,&set),Polygon_Error.None)
    expect_polygon_set(t,set)
    // Two combs whose teeth cross more times than the cap.
    TEETH :: 600
    combs:[2][dynamic]Vec2
    defer {delete(combs[0]);delete(combs[1])}
    for tooth in 0..<TEETH {
        x:=f32(tooth)*2
        append(&combs[0],Vec2{x,0},Vec2{x+1,0},Vec2{x+1,f32(TEETH*2)})
        append(&combs[0],Vec2{x+1.5,f32(TEETH*2)},Vec2{x+1.5,-1},Vec2{x,-1})
    }
    for p in combs[0] {append(&combs[1],Vec2{p.y,p.x})}
    testing.expect_value(t,polygon_boolean(combs[0][:],{len(combs[0])},combs[1][:],{len(combs[1])},.Union,&set),Polygon_Error.Too_Complex)
    // An output allocator without room.
    buffer:[64]byte
    arena:mem.Arena
    mem.arena_init(&arena,buffer[:])
    small:Polygon_Set
    polygon_set_init(&small,mem.arena_allocator(&arena))
    disc:=circle({0.5,0.5},0.4,32)
    testing.expect_value(t,polygon_boolean(square[:],{4},disc[:],{32},.Difference,&small),Polygon_Error.Out_Of_Memory)
    testing.expect_value(t,len(small.points)+len(small.loop_sizes)+len(small.polygon_loops),0)
    polygon_set_destroy(nil)
    polygon_set_clear(nil)
    polygon_set_init(nil)
}

@(test)
bench_polygon_boolean :: proc(t:^testing.T) {
    when !GEOM_BENCH {return} else {
        shape:[300]Vec2
        for &p,i in shape {
            angle:=2*math.PI*f64(i)/300
            radius:=4+0.5*math.sin(7*angle)
            p={f32(radius*math.cos(angle)),f32(radius*math.sin(angle))}
        }
        stamp:=circle({4,0},1,32)
        set:Polygon_Set
        polygon_set_init(&set)
        defer polygon_set_destroy(&set)
        for op in Polygon_Op {
            runs:=2000
            start:=time.tick_now()
            for _ in 0..<runs {_=polygon_boolean(shape[:],{300},stamp[:],{32},op,&set)}
            bench_report(fmt.tprintf("polygon_boolean 300 points %v 32-point circle",op),runs,time.tick_since(start),fmt.tprintf("%d points",len(set.points)))
        }
    }
}
