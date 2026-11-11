package shapes_editor

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import volume "mirai:engine/volume"
import shapes "plugins:shapes/runtime"
import mm "mirai:std/math"

@(private)
@(test_world)
Shapes_Test_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    brushes:core.Table(shapes.Shape_Brush),
    shapes:core.Table(shapes.Shape),
    splines:core.Table(volume.Spline),
    volumes:core.Table(volume.Volume),
}

// A scene with the tables a shape entity uses, edited by a session of its own.
@(private)
Shapes_Test :: struct {
    world:Shapes_Test_World,
    ref:core.World_Ref,
    app:host.App,
    selection:history.Selection,
    edits:history.Edits,
    viewport:editor.Viewport,
    gui:editor.Editor_Ui,
    previous:asset.Scene,
    document:editor.Document,
    session:editor.Session,
}

@(private)
shapes_test_open :: proc(t:^testing.T,f:^Shapes_Test) -> bool {
    if !test_world_init(t,&f.world) {return false}
    f.ref=test_world_ref(&f.world)
    f.app={allocator=context.allocator}
    f.document={previous=&f.previous}
    history.edits_reset(&f.edits,f.ref)
    f.session={app=&f.app,info=f.ref.info,edit_world=&f.world,headless=true,selection=&f.selection,edits=&f.edits,viewport=&f.viewport,gui=&f.gui,document=&f.document,id_state=101}
    return true
}

@(private)
shapes_test_close :: proc(f:^Shapes_Test) {
    history.edits_free(&f.edits)
    delete(f.selection.entities)
    test_world_destroy(&f.world)
}

// A shape entity with Id 7 at the origin, which the history starts with.
@(private)
shapes_test_shape :: proc(f:^Shapes_Test,shape:shapes.Shape) -> core.Entity {
    w:=&f.world
    e:=core.create(&w.entities)
    core.add(&w.ids,e,core.Id{value=7})
    core.add(&w.names,e,core.name_make("Shape"))
    core.add(&w.transforms,e,core.TRANSFORM_IDENTITY)
    core.add(&w.shapes,e,shape)
    test_world_settle(w)
    history.edits_reset(&f.edits,f.ref)
    return e
}

// The box of the points of a shape.
@(private)
shapes_test_bounds :: proc(shape:shapes.Shape) -> (lo,hi:[2]f32) {
    shape:=shape
    lo,hi=shape.points[0],shape.points[0]
    for p in shape.points[:shape.point_count] {lo,hi={min(lo.x,p.x),min(lo.y,p.y)},{max(hi.x,p.x),max(hi.y,p.y)}}
    return
}

@(test)
a_stamp_stroke_is_one_step_that_undo_and_redo_take_back_and_forth :: proc(t:^testing.T) {
    f:=new(Shapes_Test)
    defer free(f)
    if !shapes_test_open(t,f) {return}
    defer shapes_test_close(f)
    s,w:=&f.session,&f.world
    tool:Shapes_Tool;tool_ready(&tool);defer shapes_tool_free(&tool)
    stroke:=&tool.stroke

    // A press outside every shape makes one, and the drag of two frames joins it.
    if !testing.expect(t,stroke_begin(stroke,f.ref,mm.TRANSFORM_IDENTITY,core.NONE,false,.Square,0.5,0,0.01,{},context.allocator)) {return}
    testing.expect_value(t,stroke_to(stroke,{0,0}),shapes.Shape_Error.None)
    testing.expect(t,stroke_write(s,&tool))
    test_world_settle(&f.world)
    testing.expect_value(t,stroke_to(stroke,{1.5,0}),shapes.Shape_Error.None)
    testing.expect(t,stroke_write(s,&tool))
    test_world_settle(&f.world)
    testing.expect_value(t,stroke_to(stroke,{3,0}),shapes.Shape_Error.None)
    testing.expect(t,stroke_write(s,&tool))
    stroke_end(s,&tool)
    if !testing.expect(t,history.edits_commit(&f.edits,f.ref,&f.selection)) {return}
    testing.expect_value(t,f.edits.cursor,1)
    testing.expect_value(t,w.entities.alive,1)
    if !testing.expect_value(t,len(w.shapes.values),1) {return}
    made:=w.shapes.values[0]
    lo,hi:=shapes_test_bounds(made)
    testing.expect_value(t,lo,[2]f32{-0.5,-0.5})
    testing.expect_value(t,hi,[2]f32{3.5,0.5})
    testing.expect_value(t,made.point_count,u16(4))

    testing.expect(t,history.undo(&f.edits,f.ref,&f.selection))
    testing.expect_value(t,w.entities.alive,0)
    testing.expect_value(t,len(w.shapes.values),0)
    testing.expect(t,history.redo(&f.edits,f.ref,&f.selection))
    testing.expect_value(t,w.entities.alive,1)
    if testing.expect_value(t,len(w.shapes.values),1) {testing.expect(t,w.shapes.values[0]==made)}
}

@(test)
a_cut_that_splits_makes_a_second_shape_and_undo_restores_one :: proc(t:^testing.T) {
    f:=new(Shapes_Test)
    defer free(f)
    if !shapes_test_open(t,f) {return}
    defer shapes_test_close(f)
    s,w:=&f.session,&f.world
    bar:=shapes.SHAPE_DEFAULT
    bar.points[0],bar.points[1],bar.points[2],bar.points[3]={-2,-0.5},{2,-0.5},{2,0.5},{-2,0.5}
    e:=shapes_test_shape(f,bar)
    tool:Shapes_Tool;tool_ready(&tool);defer shapes_tool_free(&tool)
    stroke:=&tool.stroke

    if !testing.expect(t,stroke_begin(stroke,f.ref,mm.TRANSFORM_IDENTITY,core.NONE,true,.Square,0.75,0,0.01,{},context.allocator)) {return}
    testing.expect_value(t,stroke_to(stroke,{0,0}),shapes.Shape_Error.None)
    testing.expect(t,stroke_write(s,&tool))
    stroke_end(s,&tool)
    if !testing.expect(t,history.edits_commit(&f.edits,f.ref,&f.selection)) {return}
    testing.expect_value(t,f.edits.cursor,1)
    testing.expect_value(t,w.entities.alive,2)
    if !testing.expect_value(t,len(w.shapes.values),2) {return}
    // The larger piece stays the shape; each is one side of the cut.
    for shape,row in w.shapes.values {
        lo,hi:=shapes_test_bounds(shape)
        testing.expect(t,hi.x==-0.75 || lo.x==0.75)
        testing.expect_value(t,hi.x-lo.x,f32(1.25))
        testing.expect(t,core.has(&w.ids,w.shapes.entities[row]))
    }

    testing.expect(t,history.undo(&f.edits,f.ref,&f.selection))
    testing.expect_value(t,w.entities.alive,1)
    if testing.expect_value(t,len(w.shapes.values),1) {testing.expect(t,core.at(&w.shapes,core.row_of(&w.shapes,e))==bar)}
    testing.expect(t,history.redo(&f.edits,f.ref,&f.selection))
    testing.expect_value(t,len(w.shapes.values),2)
}

@(test)
escape_puts_back_every_shape_a_cut_stroke_changed :: proc(t:^testing.T) {
    f:=new(Shapes_Test)
    defer free(f)
    if !shapes_test_open(t,f) {return}
    defer shapes_test_close(f)
    s,w:=&f.session,&f.world
    bar:=shapes.SHAPE_DEFAULT
    bar.points[0],bar.points[1],bar.points[2],bar.points[3]={-2,-0.5},{2,-0.5},{2,0.5},{-2,0.5}
    e:=shapes_test_shape(f,bar)
    tool:Shapes_Tool;tool_ready(&tool);defer shapes_tool_free(&tool)
    stroke:=&tool.stroke

    // A cut down through the bar over several frames splits it, then Escape.
    if !testing.expect(t,stroke_begin(stroke,f.ref,mm.TRANSFORM_IDENTITY,core.NONE,true,.Circle,0.25,0,0.01,{},context.allocator)) {return}
    for i in 0..=20 {
        testing.expect_value(t,stroke_to(stroke,{0.05*f32(i%3),-1.5+0.15*f32(i)}),shapes.Shape_Error.None)
        testing.expect(t,stroke_write(s,&tool))
        test_world_settle(&f.world)
    }
    testing.expect_value(t,len(w.shapes.values),2)
    stroke_cancel(s,&tool)
    test_world_settle(&f.world)
    testing.expect(t,!stroke.active)
    testing.expect_value(t,w.entities.alive,1)
    if testing.expect_value(t,len(w.shapes.values),1) {testing.expect(t,core.at(&w.shapes,core.row_of(&w.shapes,e))==bar)}
    testing.expect_value(t,f.edits.cursor,0)
}

@(test)
a_corner_drag_is_one_step_and_a_move_that_crosses_does_not_apply :: proc(t:^testing.T) {
    f:=new(Shapes_Test)
    defer free(f)
    if !shapes_test_open(t,f) {return}
    defer shapes_test_close(f)
    s,w:=&f.session,&f.world
    e:=shapes_test_shape(f,shapes.SHAPE_DEFAULT)
    drag:Corner_Drag
    corner_drag_begin(&drag,e,2,{shape=shapes.SHAPE_DEFAULT})
    testing.expect_value(t,corner_drag_move(s,&drag,{1,1}),shapes.Shape_Error.None)
    testing.expect_value(t,corner_drag_move(s,&drag,{-1,-0.2}),shapes.Shape_Error.Self_Intersecting)
    testing.expect_value(t,core.at(&w.shapes,core.row_of(&w.shapes,e)).points[2],[2]f32{1,1})
    testing.expect_value(t,corner_drag_move(s,&drag,{1.5,1}),shapes.Shape_Error.None)
    corner_drag_end(s,&drag)
    if !testing.expect(t,history.edits_commit(&f.edits,f.ref,&f.selection)) {return}
    testing.expect_value(t,f.edits.cursor,1)
    testing.expect_value(t,core.at(&w.shapes,core.row_of(&w.shapes,e)).points[2],[2]f32{1.5,1})

    // A removal is a step of its own.
    testing.expect_value(t,corner_edit(s,e,.Remove,0,{},"Remove corner"),shapes.Shape_Error.None)
    if !testing.expect(t,history.edits_commit(&f.edits,f.ref,&f.selection)) {return}
    testing.expect_value(t,f.edits.cursor,2)
    testing.expect_value(t,core.at(&w.shapes,core.row_of(&w.shapes,e)).point_count,u16(3))
    testing.expect_value(t,corner_edit(s,e,.Remove,0,{},"Remove corner"),shapes.Shape_Error.Invalid)
    testing.expect_value(t,f.edits.cursor,2)

    testing.expect(t,history.undo(&f.edits,f.ref,&f.selection))
    testing.expect(t,history.undo(&f.edits,f.ref,&f.selection))
    testing.expect(t,core.at(&w.shapes,core.row_of(&w.shapes,e))==shapes.SHAPE_DEFAULT)
}

@(test)
shapes_api_stamps_and_moves_corners_as_steps_of_undo :: proc(t:^testing.T) {
    f:=new(Shapes_Test)
    defer free(f)
    if !shapes_test_open(t,f) {return}
    defer shapes_test_close(f)
    s,w:=&f.session,&f.world
    stamp_method:=api.Method{params_id=Stamp_Params,result_id=Stamp_Result}
    corner_method:=api.Method{params_id=Corner_Params,result_id=Corner_Result}

    params:=Stamp_Params{size=0.5}
    params.points[0],params.points[1]={0,0,0},{1,0,0}
    result:Stamp_Result
    call:=api.Call{method=&stamp_method,params=&params,result=&result,raw=`{"points":[[0,0,0],[1,0,0]]}`,allocator=context.temp_allocator}
    api_stamp(s,&call)
    if !testing.expectf(t,!call.failed,"%s",call.error.message) {return}
    testing.expect_value(t,result.count,u32(1))
    testing.expect_value(t,f.edits.cursor,1)
    id:=result.ids[0]
    e:=core.entity_of(core.world_entities(f.ref),id)
    if !testing.expect(t,e!=core.NONE && core.has(&w.shapes,e)) {return}

    // A cut that touches no shape is refused and makes no step.
    away:=Stamp_Params{size=0.5,cut=true}
    away.points[0]={10,10,0}
    nothing:Stamp_Result
    refused:=api.Call{method=&stamp_method,params=&away,result=&nothing,raw=`{"points":[[10,10,0]],"cut":true}`,allocator=context.temp_allocator}
    api_stamp(s,&refused)
    testing.expect(t,refused.failed && refused.error.code==api.INVALID_PARAMS)
    testing.expect_value(t,f.edits.cursor,1)

    corner:=Corner_Params{op=.Move,at={1.5,0.5,0},to={2,1,0}};copy(corner.entity[:],fmt.tprintf("%016x",u64(id)))
    moved:Corner_Result
    move:=api.Call{method=&corner_method,params=&corner,result=&moved,raw=`{"op":"Move","at":[1.5,0.5,0],"to":[2,1,0]}`,allocator=context.temp_allocator}
    api_corner(s,&move)
    if !testing.expectf(t,!move.failed,"%s",move.error.message) {return}
    testing.expect_value(t,moved.corners,u32(4))
    testing.expect_value(t,core.at(&w.shapes,core.row_of(&w.shapes,e)).points[moved.corner],[2]f32{2,1})
    testing.expect_value(t,f.edits.cursor,2)

    // Over the opposite edge the move is refused.
    corner.at,corner.to={2,1,0},{-1,-2,0}
    crossing:=api.Call{method=&corner_method,params=&corner,result=&moved,raw=`{"op":"Move","at":[2,1,0],"to":[-1,-2,0]}`,allocator=context.temp_allocator}
    api_corner(s,&crossing)
    testing.expect(t,crossing.failed && crossing.error.code==api.INVALID_PARAMS)
    testing.expect_value(t,f.edits.cursor,2)

    testing.expect(t,history.undo(&f.edits,f.ref,&f.selection))
    lo,hi:=shapes_test_bounds(core.at(&w.shapes,core.row_of(&w.shapes,e)))
    testing.expect_value(t,lo,[2]f32{-0.5,-0.5})
    testing.expect_value(t,hi,[2]f32{1.5,0.5})
    testing.expect(t,history.undo(&f.edits,f.ref,&f.selection))
    testing.expect_value(t,w.entities.alive,0)
}

@(test)
a_brush_placed_on_a_surface_is_one_step_and_a_child_with_an_id :: proc(t:^testing.T) {
    f:=new(Shapes_Test)
    defer free(f)
    if !shapes_test_open(t,f) {return}
    defer shapes_test_close(f)
    s,w:=&f.session,&f.world
    solid:=shapes_test_shape(f,shapes.Shape{uv_scale=1})

    // On the top of the solid, its Y up the normal: an added box rests on the surface.
    place:=brush_place_at(.Union,{0,0,0.5},{0,0,1},0.25,0)
    brush,error:=brush_place(s,place,{0,0,0.5},.Box,.Union,{},solid)
    testing.expect_value(t,error,shapes.Shape_Error.None)
    if !testing.expect(t,history.edits_commit(&f.edits,f.ref,&f.selection)) {return}
    testing.expect_value(t,f.edits.cursor,1)
    testing.expect(t,core.has(&w.ids,brush))
    parent,has_parent:=core.get(&w.parents,brush)
    testing.expect(t,has_parent && parent.entity==solid)
    value,has_brush:=core.get(&w.brushes,brush)
    testing.expect(t,has_brush && value==shapes.Shape_Brush{kind=.Box})
    local,_:=core.get(&w.transforms,brush)
    testing.expectf(t,abs(local.position.z-0.75)<1e-5 && abs(local.scale.x-0.5)<1e-5,"%v",local)
    testing.expectf(t,abs(mm.quat_rotate(local.rotation,{0,1,0}).z-1)<1e-5,"%v",local.rotation)

    // Away from every solid, a cut has nothing to cut and an add makes a Solid with the brush, in one step.
    away:=brush_place_at(.Subtract,{5,0,0},{0,0,1},0.25,0)
    _,refused:=brush_place(s,away,{5,0,0},.Sphere,.Subtract,{},core.NONE)
    testing.expect_value(t,refused,shapes.Shape_Error.Empty)
    away=brush_place_at(.Union,{5,0,0},{0,0,1},0.25,0)
    made,made_error:=brush_place(s,away,{5,0,0},.Cylinder,.Union,{},core.NONE)
    testing.expect_value(t,made_error,shapes.Shape_Error.None)
    if !testing.expect(t,history.edits_commit(&f.edits,f.ref,&f.selection)) {return}
    testing.expect_value(t,f.edits.cursor,2)
    testing.expect_value(t,w.entities.alive,4)
    made_parent,_:=core.get(&w.parents,made)
    testing.expect(t,core.has(&w.shapes,made_parent.entity))

    testing.expect(t,history.undo(&f.edits,f.ref,&f.selection))
    testing.expect_value(t,w.entities.alive,2)
    testing.expect(t,history.undo(&f.edits,f.ref,&f.selection))
    testing.expect_value(t,w.entities.alive,1)
    testing.expect_value(t,len(w.brushes.values),0)
}

@(test)
a_ray_meets_a_brush_primitive_where_it_enters_and_leaves :: proc(t:^testing.T) {
    Case :: struct {kind:shapes.Brush_Kind,origin,direction:[3]f32,enter,leave:f32,hit:bool}
    cases:=[]Case{
        {.Box,{-2,0,0},{1,0,0},1.5,2.5,true},
        {.Box,{-2,0.6,0},{1,0,0},0,0,false},
        {.Sphere,{0,0,-2},{0,0,1},1.5,2.5,true},
        {.Sphere,{0,0.45,-2},{0,0,1},0,0,true},
        {.Cylinder,{0,-2,0},{0,1,0},1.5,2.5,true},
        {.Cylinder,{-2,0,0},{1,0,0},1.5,2.5,true},
        {.Cylinder,{-2,0.6,0},{1,0,0},0,0,false},
        {.Box,{0,0,0},{1,0,0},-0.5,0.5,true},
    }
    for c in cases {
        enter,leave,hit:=unit_hit(c.kind,c.origin,c.direction)
        testing.expectf(t,hit==c.hit,"%v from %v: hit %v",c.kind,c.origin,hit)
        if c.hit && c.enter!=0 {testing.expectf(t,abs(enter-c.enter)<1e-5 && abs(leave-c.leave)<1e-5,"%v from %v: %v %v",c.kind,c.origin,enter,leave)}
    }
}

// The points of a Spline lie in its local XZ, edited by the one corner tool:
// the API takes them by world points from above, inserts with the width and
// height in proportion, lets the path cross itself and keeps two. With a
// Volume Outline they are a loop: its closing edge takes a corner, its edges
// may not cross and it keeps three.
@(test)
shapes_api_edits_the_points_of_a_spline_from_above :: proc(t:^testing.T) {
    f:=new(Shapes_Test)
    defer free(f)
    if !shapes_test_open(t,f) {return}
    defer shapes_test_close(f)
    s,w:=&f.session,&f.world
    e:=shapes_test_shape(f,{})
    core.remove(&w.shapes,e)
    path:=volume.SPLINE_DEFAULT
    path.points[1].width,path.points[1].height=5,1
    core.add(&w.splines,e,path)
    test_world_settle(w)
    history.edits_reset(&f.edits,f.ref)
    run :: proc(s:^editor.Session,params:Corner_Params) -> (corner:u32,failed:bool) {
        method:=api.Method{params_id=Corner_Params,result_id=Corner_Result}
        params:=params
        copy(params.entity[:],"0000000000000007")
        result:Corner_Result
        call:=api.Call{method=&method,params=&params,result=&result,raw=`{"to":[0,0,0]}`,allocator=context.temp_allocator}
        api_corner(s,&call)
        return result.corner,call.failed
    }
    // Inserted from 9 m above the middle of the path.
    corner,failed:=run(s,{op=.Insert,at={0.5,9,-6}})
    spline:=core.at(&w.splines,core.row_of(&w.splines,e))
    p:=spline.points[1]
    testing.expectf(t,!failed && corner==1 && spline.count==3 && abs(p.position.x)<1e-4 && abs(p.position.z+6)<1e-4 && abs(p.width-4)<1e-4 && abs(p.height-0.525)<1e-4,"%v %v",spline.count,p)
    // Across the path: a spline may cross itself.
    _,failed=run(s,{op=.Move,at={0,0,-6},to={2,5,-14}})
    spline=core.at(&w.splines,core.row_of(&w.splines,e))
    testing.expectf(t,!failed && abs(spline.points[1].position.x-2)<1e-4 && abs(spline.points[1].position.z+14)<1e-4,"%v",spline.points[1])
    run(s,{op=.Remove,at={2,0,-14}})
    _,failed=run(s,{op=.Remove,at={0,0,0}})
    testing.expect(t,failed && core.at(&w.splines,core.row_of(&w.splines,e)).count==2,"a spline keeps two points")
    core.add(&w.volumes,e,volume.outline(2))
    core.edit(&w.splines,e)^=volume.Spline{count=4,points={0={position={-4,0,-4}},1={position={4,0,-4}},2={position={4,0,4}},3={position={-4,0,4}}}}
    test_world_settle(w)
    corner,failed=run(s,{op=.Insert,at={-4,9,0}})
    spline=core.at(&w.splines,core.row_of(&w.splines,e))
    testing.expectf(t,!failed && corner==4 && spline.count==5 && abs(spline.points[4].position.x+4)<1e-4 && abs(spline.points[4].position.z)<1e-4,"the edge from the last point to the first takes one: %v",spline)
    _,failed=run(s,{op=.Move,at={-4,0,0},to={6,0,0}})
    testing.expect(t,failed && core.at(&w.splines,core.row_of(&w.splines,e)).points[4].position.x==-4,"a loop does not cross itself")
    run(s,{op=.Remove,at={-4,0,0}})
    run(s,{op=.Remove,at={4,0,4}})
    _,failed=run(s,{op=.Remove,at={4,0,-4}})
    testing.expect(t,failed && core.at(&w.splines,core.row_of(&w.splines,e)).count==3,"a loop keeps three points")
}

