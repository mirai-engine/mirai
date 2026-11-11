package shapes

import "core:math"
import "core:testing"
import "mirai:std/geom"

@(private="file")
square :: proc(half:f32) -> Shape {
    s:=SHAPE_DEFAULT
    s.points[0],s.points[1],s.points[2],s.points[3]={-half,-half},{half,-half},{half,half},{-half,half}
    return s
}

// Outline counter-clockwise, holes clockwise, nothing crossing.
@(private="file")
outline_ok :: proc(s:^Shape) -> bool {
    if shape_valid_counts(s)!=.None || !shape_outline_clear(s) {return false}
    first:=0
    for l in 0..<int(s.loop_count) {
        n:=int(s.loops[l])
        if (loop_area(s.points[first:first+n])>0)!=(l==0) {return false}
        first+=n
    }
    return true
}

@(test)
stamps_are_counter_clockwise_loops :: proc(t:^testing.T) {
    out:=make([dynamic]geom.Vec2,context.temp_allocator)
    defer free_all(context.temp_allocator)
    for kind in Stamp_Kind {
        stamp_points(kind,{1,2},0.5,0.3,&out)
        testing.expectf(t,len(out)>=3 && loop_area(out[:])>0,"%v",kind)
    }
}

@(test)
stamping_adds_cuts_splits_and_removes :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    set:geom.Polygon_Set
    geom.polygon_set_init(&set)
    defer geom.polygon_set_destroy(&set)
    circle:=make([dynamic]geom.Vec2,context.temp_allocator)
    stamp_points(.Circle,{0,0},0.3,0,&circle)
    bump:=make([dynamic]geom.Vec2,context.temp_allocator)
    stamp_points(.Square,{1,0},0.5,0,&bump)
    bar:=[4]geom.Vec2{{-0.4,-2},{0,-2},{0,2},{-0.4,2}}
    big:=make([dynamic]geom.Vec2,context.temp_allocator)
    stamp_points(.Square,{0,0},3,0,&big)
    Case :: struct {name:string,stamp:[]geom.Vec2,op:geom.Polygon_Op,polygons,loops:int,inside,outside:geom.Vec2}
    cases:=[]Case{
        {"merge",bump[:],.Union,1,1,{1.3,0},{0,1.5}},
        {"hole",circle[:],.Difference,1,2,{0.8,0.8},{0,0}},
        {"split",bar[:],.Difference,2,1,{0.6,0},{-0.2,0}},
        {"vanish",big[:],.Difference,0,1,{0,0},{2,2}},
    }
    for c in cases {
        s:=square(1)
        testing.expectf(t,shape_stamp(&s,c.stamp,c.op,&set)==.None,"%s",c.name)
        testing.expectf(t,len(set.polygon_loops)==c.polygons,"%s: %d polygons",c.name,len(set.polygon_loops))
        testing.expectf(t,int(s.loop_count)==c.loops && outline_ok(&s),"%s: %d loops",c.name,s.loop_count)
        testing.expectf(t,shape_contains(&s,c.inside) && !shape_contains(&s,c.outside),"%s: containment",c.name)
        for polygon in 1..<len(set.polygon_loops) {
            other:=SHAPE_DEFAULT
            testing.expectf(t,shape_outline_set(&other,&set,polygon)==.None && outline_ok(&other),"%s: polygon %d",c.name,polygon)
            testing.expectf(t,shape_contains(&other,-c.inside),"%s: the other half",c.name)
        }
    }
}

@(test)
a_long_drag_of_a_circle_stays_within_capacity :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    set:geom.Polygon_Set
    geom.polygon_set_init(&set)
    defer geom.polygon_set_destroy(&set)
    base:=square(0.5)
    s:=base
    circle:=make([dynamic]geom.Vec2,context.temp_allocator)
    stamp_points(.Circle,{},0.5,0,&circle)
    st:Shape_Stroke
    testing.expect_value(t,shape_stroke_begin(&st,circle[:],0.01),Shape_Error.None)
    defer shape_stroke_destroy(&st)
    for i in 0..<200 {
        if !shape_stroke_to(&st,{0.05*f32(i),0.6*math.sin(0.3*f32(i))}) {continue}
        points,loops:=shape_stroke_area(&st)
        s=base
        if !testing.expectf(t,shape_combine(&s,points,loops,.Union,&set)==.None,"point %d",i) {return}
        if !testing.expectf(t,int(s.point_count)<=SHAPE_POINTS && outline_ok(&s),"point %d: %d points",i,s.point_count) {return}
    }
    testing.expect(t,shape_contains(&s,{5,0}) && shape_contains(&s,{9.9,0}) && !shape_contains(&s,{5,1.2}))
}

@(test)
a_polygon_with_more_points_than_a_shape_holds_is_refused :: proc(t:^testing.T) {
    set:geom.Polygon_Set
    geom.polygon_set_init(&set)
    defer geom.polygon_set_destroy(&set)
    // A jagged ring of 2000 points around a hole of 600, every point a real turn.
    for i in 0..<2000 {
        a:=2*math.PI*f64(i)/2000
        r:=4+0.05*f64(i%2)
        append(&set.points,geom.Vec2{f32(r*math.cos(a)),f32(r*math.sin(a))})
    }
    for i in 0..<600 {
        a:=-2*math.PI*f64(i)/600
        r:=1+0.02*f64(i%2)
        append(&set.points,geom.Vec2{f32(r*math.cos(a)),f32(r*math.sin(a))})
    }
    append(&set.loop_sizes,2000,600)
    append(&set.polygon_loops,2)
    s:=square(1)
    testing.expect_value(t,shape_outline_set(&s,&set,0),Shape_Error.Too_Many_Points)
    testing.expect(t,s==square(1))
    testing.expect_value(t,shape_outline_set(&s,&set,1),Shape_Error.Invalid)
    // Points on the line of their neighbors go before the count is taken.
    clear(&set.points);clear(&set.loop_sizes);clear(&set.polygon_loops)
    for i in 0..<SHAPE_POINTS+100 {append(&set.points,geom.Vec2{f32(i),0})}
    append(&set.points,geom.Vec2{f32(SHAPE_POINTS+99),1},geom.Vec2{0,1})
    append(&set.loop_sizes,SHAPE_POINTS+102)
    append(&set.polygon_loops,1)
    testing.expect_value(t,shape_outline_set(&s,&set,0),Shape_Error.None)
    testing.expect_value(t,s.point_count,u16(4))
}

@(test)
vertex_edits_keep_the_outline_simple :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    // A pentagon with a small hole under its peak.
    pentagon:=SHAPE_DEFAULT
    pentagon.point_count,pentagon.loop_count,pentagon.loops=8,2,{0=5,1=3}
    pentagon.points[0],pentagon.points[1],pentagon.points[2],pentagon.points[3],pentagon.points[4]={-2,-2},{2,-2},{2,2},{0,3},{-2,2}
    pentagon.points[5],pentagon.points[6],pentagon.points[7]={-0.2,2.1},{0.2,2.1},{0,2.4}
    Edit :: enum {Move,Insert,Remove}
    Case :: struct {name:string,shape:Shape,edit:Edit,vertex:int,at:geom.Vec2,error:Shape_Error,points:int}
    cases:=[]Case{
        {"move",square(1),.Move,0,{-0.8,-0.5},.None,4},
        {"move across an edge",square(1),.Move,0,{2,0},.Self_Intersecting,4},
        {"move onto a neighbor",square(1),.Move,0,{1,-1},.Self_Intersecting,4},
        {"move a hole out",pentagon,.Move,7,{0,3.5},.Self_Intersecting,8},
        {"insert",square(1),.Insert,0,{0,-1.2},.None,5},
        {"insert across",square(1),.Insert,0,{0,2},.Self_Intersecting,4},
        {"insert into nothing",{},.Insert,0,{},.Empty,0},
        {"remove",square(1),.Remove,2,{},.None,3},
        {"remove from a triangle",pentagon,.Remove,6,{},.Invalid,8},
        {"remove leaves the hole out",pentagon,.Remove,3,{},.Self_Intersecting,8},
        {"out of range",square(1),.Remove,4,{},.Invalid,4},
    }
    for c in cases {
        s:=c.shape
        before:=s
        error:Shape_Error
        switch c.edit {
        case .Move:   error=shape_vertex_move(&s,c.vertex,c.at)
        case .Insert: error=shape_vertex_insert(&s,c.vertex,c.at)
        case .Remove: error=shape_vertex_remove(&s,c.vertex)
        }
        testing.expectf(t,error==c.error,"%s: %v",c.name,error)
        testing.expectf(t,int(s.point_count)==c.points,"%s: %d points",c.name,s.point_count)
        if error!=.None {
            testing.expectf(t,s==before,"%s: a refused edit keeps the shape",c.name)
        } else {
            testing.expectf(t,outline_ok(&s),"%s: valid",c.name)
        }
    }
    s:=square(1)
    testing.expect(t,shape_vertex_insert(&s,3,{-1.2,0})==.None && s.points[4]==geom.Vec2{-1.2,0})
    full:=square(1)
    full.point_count,full.loops[0]=SHAPE_POINTS,SHAPE_POINTS
    testing.expect_value(t,shape_vertex_insert(&full,0,{0,-1}),Shape_Error.Too_Many_Points)
}
