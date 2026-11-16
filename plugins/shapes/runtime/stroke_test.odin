package shapes

import "core:fmt"
import "core:math"
import "core:testing"
import "core:time"
import "mirai:core"
import "mirai:std/geom"
import mm "mirai:std/math"

// Benchmark: mirai test plugins/shapes/runtime bench_stroke_combine --release -define:SHAPES_BENCH=true
SHAPES_BENCH :: #config(SHAPES_BENCH,false)

@(private="file")
brush_of :: proc(kind:Stamp_Kind,size:f32) -> []geom.Vec2 {
    out:=make([dynamic]geom.Vec2,context.temp_allocator)
    stamp_points(kind,{},size,0,&out)
    return out[:]
}

// The area of a polygon of loops: outlines count, holes take away.
@(private="file")
loops_area :: proc(points:[]geom.Vec2,loops:[]int) -> f64 {
    area:f64
    at:=0
    for size in loops {
        area+=loop_area(points[at:at+size])
        at+=size
    }
    return abs(area)/2
}

// A circle of count points of radius r on a grid of 1/1024: exact in every boolean.
@(private="file")
round_shape :: proc(count:int,r:f64) -> Shape {
    set:geom.Polygon_Set
    geom.polygon_set_init(&set,context.temp_allocator)
    for i in 0..<count {
        a:=2*math.PI*f64(i)/f64(count)
        append(&set.points,geom.Vec2{f32(math.round(r*math.cos(a)*1024)/1024),f32(math.round(r*math.sin(a)*1024)/1024)})
    }
    append(&set.loop_sizes,count)
    append(&set.polygon_loops,1)
    s:=SHAPE_DEFAULT
    shape_outline_set(&s,&set,0)
    return s
}

@(private="file")
noise :: proc(i:int) -> f32 {
    x:=u32(i)*2654435761+12345
    x~=x>>15;x*=2246822519;x~=x>>13
    return f32(x%2001)/1000-1
}

@(test)
a_straight_drag_with_jitter_is_one_segment :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    Case :: struct {name:string,kind:Stamp_Kind,direction:geom.Vec2}
    cases:=[]Case{
        {"diagonal square",.Square,{1,1}},
        {"square along x",.Square,{1,0}},
        {"triangle",.Triangle,{1,0.3}},
    }
    tolerance:=f32(0.05)
    for c in cases {
        st:Shape_Stroke
        brush:=brush_of(c.kind,0.5)
        if !testing.expect_value(t,shape_stroke_begin(&st,brush,tolerance),Shape_Error.None) {continue}
        across:=geom.Vec2{-c.direction.y,c.direction.x}/math.sqrt(c.direction.x*c.direction.x+c.direction.y*c.direction.y)
        // The hand shakes within the tolerance around the line.
        for i in 0..=400 {
            shape_stroke_to(&st,c.direction*f32(i)*0.025+across*noise(i)*tolerance/2)
        }
        // One segment: the corners of the brush and the two where the sweep leaves and joins it.
        points,loops:=shape_stroke_area(&st)
        testing.expectf(t,len(loops)==1 && len(points)<=len(brush)+2,"%s: %d points in %d loops",c.name,len(points),len(loops))
        shape_stroke_destroy(&st)
    }
}

@(test)
the_area_does_not_depend_on_how_often_the_pointer_is_read :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    tolerance:=f32(0.02)
    path:=make([]geom.Vec2,501,context.temp_allocator)
    for &p,i in path {
        a:=math.PI*f64(i)/500
        p={f32(5*math.cos(a)),f32(5*math.sin(a))+0.3*f32(math.sin(4*a))}
    }
    length:f64
    for i in 1..<len(path) {length+=f64(math.sqrt((path[i].x-path[i-1].x)*(path[i].x-path[i-1].x)+(path[i].y-path[i-1].y)*(path[i].y-path[i-1].y)))}
    every,fifth:Shape_Stroke
    brush:=brush_of(.Circle,0.5)
    testing.expect_value(t,shape_stroke_begin(&every,brush,tolerance),Shape_Error.None)
    testing.expect_value(t,shape_stroke_begin(&fifth,brush,tolerance),Shape_Error.None)
    defer {shape_stroke_destroy(&every);shape_stroke_destroy(&fifth)}
    for p,i in path {
        shape_stroke_to(&every,p)
        if i%5==0 {shape_stroke_to(&fifth,p)}
    }
    a_points,a_loops:=shape_stroke_area(&every)
    b_points,b_loops:=shape_stroke_area(&fifth)
    set:geom.Polygon_Set
    geom.polygon_set_init(&set,context.temp_allocator)
    apart:f64
    for op in ([2]bool{false,true}) {
        if op {testing.expect_value(t,geom.polygon_boolean(b_points,b_loops,a_points,a_loops,.Difference,&set),geom.Polygon_Error.None)}
        else  {testing.expect_value(t,geom.polygon_boolean(a_points,a_loops,b_points,b_loops,.Difference,&set),geom.Polygon_Error.None)}
        at,loop:=0,0
        for count in set.polygon_loops {
            size:=0
            for s in set.loop_sizes[loop:loop+count] {size+=s}
            apart+=loops_area(set.points[at:at+size],set.loop_sizes[loop:loop+count])
            at+=size
            loop+=count
        }
    }
    area:=loops_area(a_points,a_loops)
    testing.expectf(t,area>2*length*0.5*0.9,"area %v",area)
    testing.expectf(t,apart<=2*f64(tolerance)*length,"the areas differ by %v of %v",apart,area)
}

// Writes what changed as a caller does: a new piece gets the next entity
// and a piece that is gone loses its own.
@(private="file")
edit_write :: proc(e:^Shape_Edit,last:^core.Entity) -> (made,taken:int) {
    index:=0
    for piece in shape_edit_next(e,&index) {
        switch {
        case piece.gone:
            if piece.entity!=core.NONE {taken+=1}
            piece.entity=core.NONE
        case piece.entity==core.NONE:
            last^+=1
            piece.entity=last^
            made+=1
        }
    }
    return
}

@(private="file")
moved :: proc(x,y:f32) -> mm.Transform {return {{x,y,0},mm.QUAT_IDENTITY,{1,1,1}}}

@(test)
an_add_stroke_outside_every_shape_makes_one_new_piece :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    e:Shape_Edit
    made:=SHAPE_DEFAULT
    made.depth,made.material=0.5,{1,2}
    if !testing.expect_value(t,shape_edit_begin(&e,mm.TRANSFORM_IDENTITY,false,.Square,0.5,0,0.01,made),Shape_Error.None) {return}
    defer shape_edit_free(&e)
    testing.expect(t,shape_edit_piece(&e,core.Entity(1),moved(10,0),SHAPE_DEFAULT))
    last:=core.Entity(1)
    // A diagonal drag: one segment, the corners of the square and the two where the sweep leaves it.
    for i in 0..=20 {
        testing.expect_value(t,shape_edit_to(&e,{f32(i)*0.1,f32(i)*0.1}),Shape_Error.None)
        edit_write(&e,&last)
    }
    testing.expect_value(t,last,core.Entity(2))
    if !testing.expect_value(t,len(e.pieces),2) {return}
    testing.expect(t,!e.pieces[0].changed && !e.pieces[0].reached)
    piece:=e.pieces[1]
    testing.expect(t,!piece.given && piece.from==core.NONE && piece.entity==core.Entity(2))
    testing.expect(t,piece.shape.depth==0.5 && piece.shape.material==made.material)
    testing.expectf(t,piece.shape.point_count<=6,"%d points",piece.shape.point_count)
    shape:=piece.shape
    testing.expect(t,shape_contains(&shape,{0,0}) && shape_contains(&shape,{2,2}))
}

@(test)
a_cut_stroke_splits_a_shape_into_pieces_that_keep_their_entities :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    bar:=SHAPE_DEFAULT
    bar.points[0],bar.points[1],bar.points[2],bar.points[3]={-2,-0.5},{2,-0.5},{2,0.5},{-2,0.5}
    e:Shape_Edit
    if !testing.expect_value(t,shape_edit_begin(&e,mm.TRANSFORM_IDENTITY,true,.Circle,0.2,0,0.01,SHAPE_DEFAULT),Shape_Error.None) {return}
    defer shape_edit_free(&e)
    testing.expect(t,shape_edit_piece(&e,core.Entity(1),mm.TRANSFORM_IDENTITY,bar))
    last:=core.Entity(1)
    sides :: proc(t:^testing.T,e:^Shape_Edit) {
        if !testing.expect_value(t,len(e.pieces),2) {return}
        for &piece in e.pieces {
            testing.expect(t,!piece.gone)
            testing.expect(t,shape_contains(&piece.shape,{1.9,0})!=shape_contains(&piece.shape,{-1.9,0}))
            testing.expect(t,!shape_contains(&piece.shape,{0,0}))
        }
    }
    // Down through the bar, then back down beside the cut, widening it.
    for i in 0..=40 {
        testing.expect_value(t,shape_edit_to(&e,{0.1*math.sin(f32(i)*0.2),-1+f32(i)*0.05}),Shape_Error.None)
        edit_write(&e,&last)
    }
    sides(t,&e)
    split:=e.pieces[1].shape
    for i in 0..=20 {
        testing.expect_value(t,shape_edit_to(&e,{0.2,1-f32(i)*0.1}),Shape_Error.None)
        edit_write(&e,&last)
    }
    sides(t,&e)
    testing.expect_value(t,last,core.Entity(2))
    if len(e.pieces)==2 {
        testing.expect(t,e.pieces[0].entity==core.Entity(1) && e.pieces[1].entity==core.Entity(2))
        testing.expect(t,e.pieces[1].from==core.Entity(1) && e.pieces[1].split_of==0)
        testing.expect(t,e.pieces[1].shape!=split)
    }
}

@(test)
a_cut_that_covers_a_shape_marks_it_gone :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    e:Shape_Edit
    if !testing.expect_value(t,shape_edit_begin(&e,mm.TRANSFORM_IDENTITY,true,.Square,1,0,0.01,SHAPE_DEFAULT),Shape_Error.None) {return}
    defer shape_edit_free(&e)
    testing.expect(t,shape_edit_piece(&e,core.Entity(1),mm.TRANSFORM_IDENTITY,SHAPE_DEFAULT))
    testing.expect(t,shape_edit_piece(&e,core.Entity(2),moved(10,0),SHAPE_DEFAULT))
    last:=core.Entity(2)
    testing.expect_value(t,shape_edit_to(&e,{0,0}),Shape_Error.None)
    made,taken:=edit_write(&e,&last)
    testing.expect(t,made==0 && taken==1)
    testing.expect(t,e.pieces[0].gone && e.pieces[0].changed && e.pieces[0].entity==core.NONE)
    testing.expect(t,!e.pieces[1].changed && !e.pieces[1].reached)
    testing.expect_value(t,shape_edit_to(&e,{0.1,0}),Shape_Error.None)
    testing.expect(t,!shape_edit_dirty(&e))
}

@(test)
a_piece_given_late_is_cut_from_its_shape_then_by_the_whole_area :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    e:Shape_Edit
    if !testing.expect_value(t,shape_edit_begin(&e,mm.TRANSFORM_IDENTITY,true,.Circle,0.2,0,0.01,SHAPE_DEFAULT),Shape_Error.None) {return}
    defer shape_edit_free(&e)
    // Along the top edge of a square at x 2, which the edit gets only halfway across it.
    square:=SHAPE_DEFAULT
    for i in 0..=40 {
        if i==20 {testing.expect(t,shape_edit_piece(&e,core.Entity(1),moved(2,0),square))}
        testing.expect_value(t,shape_edit_to(&e,{f32(i)*0.1,0.5}),Shape_Error.None)
    }
    if !testing.expect_value(t,len(e.pieces),1) {return}
    points,loops:=shape_stroke_area(&e.stroke)
    local:=make([]geom.Vec2,len(points),context.temp_allocator)
    for p,i in points {local[i]=p-{2,0}}
    set:geom.Polygon_Set
    geom.polygon_set_init(&set,context.temp_allocator)
    expected:=square
    testing.expect_value(t,shape_combine(&expected,local,loops,.Difference,&set),Shape_Error.None)
    testing.expect(t,e.pieces[0].shape==expected)
    testing.expect(t,!shape_contains(&e.pieces[0].shape,{-0.4,0.45}) && shape_contains(&e.pieces[0].shape,{-0.4,0}))
}

@(test)
an_add_stroke_keeps_every_vertex_outside_its_area :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    base:=round_shape(300,4)
    if !testing.expect_value(t,int(base.point_count),300) {return}
    e:Shape_Edit
    if !testing.expect_value(t,shape_edit_begin(&e,mm.TRANSFORM_IDENTITY,false,.Square,0.25,0,0.01,SHAPE_DEFAULT),Shape_Error.None) {return}
    defer shape_edit_free(&e)
    testing.expect(t,shape_edit_piece(&e,core.Entity(1),mm.TRANSFORM_IDENTITY,base))
    for i in 0..=95 {
        x:=-3.5+f32(i)*0.1
        if !testing.expect_value(t,shape_edit_to(&e,{x,0.5*math.sin(x)}),Shape_Error.None) {return}
    }
    if !testing.expect_value(t,len(e.pieces),1) {return}
    shape:=e.pieces[0].shape
    points,loops:=shape_stroke_area(&e.stroke)
    kept,outside:=0,0
    for p in base.points[:base.point_count] {
        near:=false
        at:=0
        for size in loops {
            for i in 0..<size {
                q:=segment_nearest(points[at+i],points[at+(i+1)%size],p)
                if (q.x-p.x)*(q.x-p.x)+(q.y-p.y)*(q.y-p.y)<1e-4 {near=true}
            }
            at+=size
        }
        if near || loop_contains(points[:loops[0]],p) {continue}
        outside+=1
        for q in shape.points[:shape.point_count] {
            if q==p {
                kept+=1
                break
            }
        }
    }
    testing.expectf(t,outside>250 && kept==outside,"%d of %d vertices outside the area kept",kept,outside)
    testing.expect(t,shape_contains(&shape,{5.9,0.5*math.sin(f32(5.9))}))
}

@(test)
a_stroke_past_capacity_is_refused_and_the_piece_keeps_its_last_result :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    e:Shape_Edit
    if !testing.expect_value(t,shape_edit_begin(&e,mm.TRANSFORM_IDENTITY,false,.Square,0.1,0,0.01,SHAPE_DEFAULT),Shape_Error.None) {return}
    defer shape_edit_free(&e)
    testing.expect(t,shape_edit_piece(&e,core.Entity(1),mm.TRANSFORM_IDENTITY,SHAPE_DEFAULT))
    refused:Shape_Error
    // A zigzag whose every turn adds corners to the area.
    for i in 0..<400 {
        before:=e.pieces[0].shape
        if error:=shape_edit_to(&e,{f32(i)*0.3,f32(i%2)});error!=.None {
            refused=error
            testing.expect(t,e.pieces[0].shape==before)
            break
        }
    }
    testing.expect_value(t,refused,Shape_Error.Too_Many_Points)
    testing.expect_value(t,len(e.pieces),1)
    shape:=e.pieces[0].shape
    testing.expect(t,int(shape.point_count)<=SHAPE_POINTS && shape_contains(&shape,{0,0}) && shape_contains(&shape,{3,0}))
}

@(test)
hostile_strokes_do_not_crash :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    nan:=math.nan_f32()
    inf:=math.inf_f32(1)
    square:=brush_of(.Square,0.5)
    arrow:=[]geom.Vec2{{0,0},{1,-1},{0.2,0},{1,1}}
    pentagram:=make([dynamic]geom.Vec2,context.temp_allocator)
    for i in 0..<5 {
        a:=2*math.PI*f64(i*2)/5
        append(&pentagram,geom.Vec2{f32(math.cos(a)),f32(math.sin(a))})
    }
    twice:=make([dynamic]geom.Vec2,context.temp_allocator)
    append(&twice,..square);append(&twice,..square)
    clockwise:=[]geom.Vec2{square[3],square[2],square[1],square[0]}
    Case :: struct {name:string,brush:[]geom.Vec2,tolerance:f32,error:Shape_Error}
    cases:=[]Case{
        {"empty",{},0.1,.Invalid},
        {"a segment",square[:2],0.1,.Invalid},
        {"concave",arrow,0.1,.None},
        {"winds twice",twice[:],0.1,.Invalid},
        {"a star",pentagram[:],0.1,.Invalid},
        {"not finite",{{0,0},{nan,0},{0,1}},0.1,.Invalid},
        {"no area",{{0,0},{1,0},{2,0}},0.1,.Invalid},
        {"tolerance not finite",square,nan,.Invalid},
        {"tolerance below 0",square,-1,.Invalid},
        {"clockwise",clockwise,0.1,.None},
    }
    for c in cases {
        st:Shape_Stroke
        testing.expectf(t,shape_stroke_begin(&st,c.brush,c.tolerance)==c.error,"%s",c.name)
        for p in ([]geom.Vec2{{nan,0},{0,0},{inf,1},{1,nan},{3,1},{1e30,-1e30},{-1e30,1e30},{4,1}}) {shape_stroke_to(&st,p)}
        points,loops:=shape_stroke_area(&st)
        if c.error==.None {
            testing.expectf(t,len(loops)==1 && loops_area(points,loops)>0,"%s: an area",c.name)
            s:=SHAPE_DEFAULT
            set:geom.Polygon_Set
            geom.polygon_set_init(&set,context.temp_allocator)
            testing.expectf(t,shape_combine(&s,points,loops,.Union,&set)==.None,"%s: combines",c.name)
            bad_loops:=[]int{len(points)+5}
            testing.expectf(t,shape_combine(&s,points,bad_loops,.Union,&set)==.Invalid,"%s: loops past the points",c.name)
            testing.expectf(t,shape_combine(&s,points,{},.Union,&set)==.Invalid,"%s: no loops",c.name)
        } else {
            testing.expectf(t,len(points)==0,"%s: no area",c.name)
        }
        shape_stroke_destroy(&st)
    }
    st:Shape_Stroke
    testing.expect(t,!shape_stroke_to(&st,{0,0}))

    e:Shape_Edit
    defer shape_edit_free(&e)
    flat:=mm.TRANSFORM_IDENTITY
    flat.scale.y=0
    lost:=mm.TRANSFORM_IDENTITY
    lost.position.x=nan
    testing.expect(t,!shape_edit_piece(&e,core.Entity(1),mm.TRANSFORM_IDENTITY,SHAPE_DEFAULT))
    testing.expect_value(t,shape_edit_to(&e,{0,0}),Shape_Error.None)
    for plane in ([]mm.Transform{flat,lost}) {
        testing.expect_value(t,shape_edit_begin(&e,plane,true,.Square,1,0,0.01,SHAPE_DEFAULT),Shape_Error.Invalid)
    }
    for size in ([]f32{0,-1,nan,inf}) {
        testing.expect_value(t,shape_edit_begin(&e,mm.TRANSFORM_IDENTITY,true,.Square,size,0,0.01,SHAPE_DEFAULT),Shape_Error.Invalid)
    }
    if !testing.expect_value(t,shape_edit_begin(&e,mm.TRANSFORM_IDENTITY,true,.Square,1,0,0.01,SHAPE_DEFAULT),Shape_Error.None) {return}
    tilted:=mm.TRANSFORM_IDENTITY
    tilted.rotation=mm.quat_axis_angle({1,0,0},0.5)
    bad:=SHAPE_DEFAULT
    bad.point_count=SHAPE_POINTS+1
    // A solid of brushes alone has no polygon to stamp.
    solid:=Shape{}
    testing.expect(t,!shape_edit_piece(&e,core.Entity(1),tilted,SHAPE_DEFAULT))
    testing.expect(t,!shape_edit_piece(&e,core.Entity(1),lost,SHAPE_DEFAULT))
    testing.expect(t,!shape_edit_piece(&e,core.Entity(1),mm.TRANSFORM_IDENTITY,bad))
    testing.expect(t,!shape_edit_piece(&e,core.Entity(1),mm.TRANSFORM_IDENTITY,solid))
    for p in ([]geom.Vec2{{nan,0},{1e30,-1e30},{0,0}}) {shape_edit_to(&e,p)}
    testing.expect_value(t,len(e.pieces),0)
}

@(test)
bench_stroke_combine :: proc(t:^testing.T) {
    when !SHAPES_BENCH {return} else {
        defer free_all(context.temp_allocator)
        base:=round_shape(300,4)
        st:Shape_Stroke
        shape_stroke_begin(&st,brush_of(.Circle,0.5),0.01)
        defer shape_stroke_destroy(&st)
        set:geom.Polygon_Set
        geom.polygon_set_init(&set)
        defer geom.polygon_set_destroy(&set)
        // A wavy drag across the shape; each step a point the path turns at.
        runs:=0
        total:time.Duration
        for i in 0..<400 {
            x:=-5+f32(i)*0.025
            start:=time.tick_now()
            if shape_stroke_to(&st,{x,0.6*math.sin(3*x)}) {
                points,loops:=shape_stroke_area(&st)
                next:=base
                shape_combine(&next,points,loops,.Union,&set)
                total+=time.tick_since(start)
                runs+=1
            }
        }
        points,_:=shape_stroke_area(&st)
        fmt.printfln("BENCH %-44s %.3f ms  %d runs, area of %d points",
            "stroke_to and combine, 300-point shape",time.duration_milliseconds(total)/f64(max(runs,1)),runs,len(points))
    }
}

// A concave brush sweeps as its convex pieces: dragging a star to the right
// leaves the dent on its left open, which the hull of the whole star fills.
@(test)
a_concave_brush_keeps_its_dents_while_it_is_dragged :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    st:Shape_Stroke
    testing.expect_value(t,shape_stroke_begin(&st,brush_of(.Star,1),0.01),Shape_Error.None)
    defer shape_stroke_destroy(&st)
    for i in 0..=20 {shape_stroke_to(&st,{f32(i)*0.1,0})}
    points,loops:=shape_stroke_area(&st)
    testing.expect_value(t,len(loops),1)
    a:=2*math.PI*198/360
    dent:=geom.Vec2{f32(0.7*math.cos(a)),f32(0.7*math.sin(a))}
    testing.expect(t,!loop_contains(points[:loops[0]],dent),"the dent left of the start stays open")
    testing.expect(t,loop_contains(points[:loops[0]],{1,0}),"the path is covered")
    testing.expect(t,loop_contains(points[:loops[0]],{2,0.9}),"the top arm reaches up at the end")
    // A brush that crosses itself has no inside: refused.
    bow:=[]geom.Vec2{{-1,-1},{1,1},{1,-1},{-1,1}}
    crossed:Shape_Stroke
    testing.expect_value(t,shape_stroke_begin(&crossed,bow,0.01),Shape_Error.Invalid)
}

@(private="file")
segment_nearest :: proc "contextless" (a,b,p:geom.Vec2) -> geom.Vec2 {
    ab:=b-a
    length:=ab.x*ab.x+ab.y*ab.y
    if !(length>0) {return a}
    t:=clamp(((p.x-a.x)*ab.x+(p.y-a.y)*ab.y)/length,0,1)
    return a+ab*t
}
