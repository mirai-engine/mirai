package terrain_editor

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import mm "mirai:std/math"
import terrain "plugins:terrain/runtime"

@(test)
terrain_grow_turns_from_the_stroke_path_and_bounds_corrections_by_mouse_travel :: proc(t:^testing.T) {
    for direction in ([4][3]f32{{1,0,0},{0,1,0},{-1,0,0},{0,0,1}}) {
        drag:=Terrain_Drag{brush={radius=2,normal={0,1,0}}}
        turn,follow:=terrain_drag_turn(&drag,direction*0.0001)
        testing.expect_value(t,turn,mm.Quat(1))
        testing.expect_value(t,follow,[3]f32{})
    }
    drag:=Terrain_Drag{brush={radius=2},last={0,2,0},follow={0,1,0}}
    for step in 0..<180 {
        delta:=[3]f32{0.08,0,0}
        if step>=30 && step<60 {delta={0,0.08,0}}
        if step>=60 {delta={0.0001,0,0};if step%2==0 {delta.x= -delta.x}}
        point:=drag.last+delta
        turn,follow:=terrain_drag_turn(&drag,point)
        testing.expect(t,mm.quat_angle(1,turn)<=2*linalg.length(delta)/drag.brush.radius+1e-6)
        testing.expect(t,linalg.length(point-follow)<=drag.brush.radius*0.5+1e-5)
        drag.last,drag.follow=point,follow
        held,unchanged:=terrain_drag_turn(&drag,point)
        testing.expect(t,mm.quat_angle(1,held)<1e-6)
        testing.expect(t,linalg.length(unchanged-follow)<1e-5)
    }
}

@(test)
terrain_drag_keeps_depth_when_the_surface_moves_or_the_cursor_leaves_it :: proc(t:^testing.T) {
    tool:Terrain_Tool
    defer terrain_tool_free(&tool)
    brush_of(&tool).radius,tool.edge_length,tool.brush=2,0.5,.Grab
    tool.stroke.to_world=mm.transform_matrix(mm.TRANSFORM_IDENTITY)
    tool.stroke.to_local=tool.stroke.to_world;tool.stroke.scale=1
    view:=core.VIEW_DEFAULT;view.position={0,0,10};view.size={1000,1000}
    stroke_drag_begin(&tool,{0,0,0},view)
    tool.stroke.active=true
    // The scene under a bar of 40 points, as the editor lays it out.
    viewport:=editor.Viewport{origin={0,40},size={1000,1000},view_matrix=mm.look_at({0,0,10},{0,0,0},{0,1,0}),projection=mm.perspective_infinite(60*mm.RAD_PER_DEG,1,0.1)}
    pointer:=[2]f32{700,440}
    point,normal,ok:=stroke_point(&tool.stroke,&viewport,pointer)
    testing.expect(t,ok && abs(point.z)<1e-5 && point.x>0 && point.y>0)
    testing.expect_value(t,normal,[3]f32{0,0,-1})
    // No source geometry participates in a captured drag.
    testing.expect(t,terrain.source_make(&tool.stroke.source,.Heightfield,{3,1,3},1,4))
    for z in 0..<3 {for x in 0..<3 {terrain.source_set(&tool.stroke.source,{x,0,z},100)}}
    after,_,hit:=stroke_point(&tool.stroke,&viewport,pointer)
    testing.expect(t,hit && after==point)
    tool.stroke.drag.released=true;tool.stroke.drag.destination=point
    after,_,hit=stroke_point(&tool.stroke,&viewport,{100,940})
    testing.expect(t,hit && after==point)
}

@(test)
terrain_drag_axes_preserve_the_other_coordinates_and_reject_parallel_rays :: proc(t:^testing.T) {
    drag:=Terrain_Drag{anchor={1,2,3},plane={0,0,-1}}
    for axis in Drag_Axis.X..=Drag_Axis.Z {
        drag.axis=axis
        desired:=drag.anchor;desired[int(axis)-1]+=4
        origin:=drag.anchor+[3]f32{10,8,12}
        point,ok:=terrain_drag_point(&drag,origin,linalg.normalize(desired-origin))
        testing.expect(t,ok && linalg.length(point-desired)<1e-4)
        parallel:=[3]f32{};parallel[int(axis)-1]=1
        _,ok=terrain_drag_point(&drag,origin,parallel)
        testing.expect(t,!ok)
    }
    drag.axis=.Free
    _,ok:=terrain_drag_point(&drag,{0,0,10},{1,0,0})
    testing.expect(t,!ok)
}

@(test)
terrain_initial_asset_revision_is_the_baseline_of_the_first_undo :: proc(t:^testing.T) {
    world:Create_Test_World
    create_test_world_init(&world);defer create_test_world_destroy(&world)
    tables:=create_test_tables()
    info:=core.World_Info{entities=offset_of(Create_Test_World,entities),tables=tables[:]}
    ref:=core.world_ref(&world,&info)
    edits:editor.Edits;defer editor.edits_free(&edits)
    selection:editor.Selection;defer delete(selection.entities)
    assets:host.Assets
    app:=host.App{allocator=context.allocator,assets=&assets}
    session:=editor.Session{app=&app,info=&info,edit_world=&world,selection=&selection,edits=&edits,id_state=42}
    owner:=editor.entity_create(&session,{name="Terrain"})
    core.add(&world.terrains,owner,{source={1,2},revision=1})
    create_test_settle(&world,nil,nil)
    editor.edits_reset(&edits,ref)
    initial:=editor.edits_state(&edits)
    core.get(&world.terrains,owner).revision=7
    tool:Terrain_Tool;defer terrain_tool_free(&tool)
    terrain_sync(&session,&tool,core.read(&world.terrains),&app)
    testing.expect_value(t,editor.edits_state(&edits),initial)
    testing.expect_value(t,len(edits.steps),0)
    editor.edits_begin(&edits,&selection,"Sculpt")
    core.get(&world.terrains,owner).revision=8
    testing.expect(t,!editor.edits_sync_initial(&edits,ref))
    editor.edits_end(&edits)
    testing.expect(t,editor.edits_commit(&edits,ref,&selection))
    testing.expect(t,editor.undo(&edits,ref,&selection))
    testing.expect_value(t,core.get(&world.terrains,owner).revision,u32(7))
    testing.expect(t,!editor.edits_sync_initial(&edits,ref))
    testing.expect(t,editor.redo(&edits,ref,&selection))
    testing.expect_value(t,core.get(&world.terrains,owner).revision,u32(8))
    testing.expect(t,!editor.edits_sync_initial(nil,{}))
}
