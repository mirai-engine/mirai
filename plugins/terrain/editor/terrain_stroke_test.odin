package terrain_editor

import "core:testing"
import "mirai:core"
import "mirai:editor"
import mm "mirai:std/math"
import terrain "plugins:terrain/runtime"
import "mirai:ui"

// A Raise held still keeps lifting, and where the pointer is: the scene of
// the editor begins under its bars.
@(test)
terrain_held_brush_keeps_raising_under_the_pointer :: proc(t:^testing.T) {
    world:Create_Test_World
    create_test_world_init(&world);defer create_test_world_destroy(&world)
    tables:=create_test_tables()
    info:=core.World_Info{entities=offset_of(Create_Test_World,entities),tables=tables[:]}
    ref:=core.world_ref(&world,&info)
    ctx:ui.Context
    if !testing.expect(t,ui.context_init(&ctx,{})) {return}
    defer ui.context_destroy(&ctx)
    viewport:=editor.Viewport{origin={0,84},size={800,600},view_matrix=mm.look_at({0,12,8},{0,0,0},{0,1,0}),projection=mm.perspective_infinite(60*mm.RAD_PER_DEG,800.0/600,0.1)}
    viewport.view_projection=viewport.projection*viewport.view_matrix
    gui:=editor.Editor_Ui{ctx=&ctx,begun=true}
    s:=editor.Session{headless=true,viewport=&viewport,gui=&gui}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.brush,brush_of(&tool).radius,brush_of(&tool).strength=.Raise,3,0.5
    stroke:=&tool.stroke
    if !testing.expect(t,terrain.source_make(&stroke.source,.Heightfield,{17,1,17},1,4)) {return}
    stroke.to_world=mm.transform_matrix(mm.TRANSFORM_IDENTITY);stroke.to_local=stroke.to_world;stroke.scale=1
    stroke.active=true
    target:=[3]f32{2,0,-1}
    under:=[3]int{10,0,7}
    pointer,seen:=editor.viewport_screen(&viewport,target)
    if !testing.expect(t,seen) {return}
    input:=core.Input{mouse_position=pointer}
    heights:[dynamic]f32;defer delete(heights)
    for _ in 0..<20 {
        stroke_apply(&s,&tool,ref,input,core.VIEW_DEFAULT,{dt=0.05})
        append(&heights,terrain.source_value(&stroke.source,under))
    }
    for i in 1..<len(heights) {testing.expectf(t,heights[i]>heights[i-1],"the touch %d of a held brush lifted nothing",i)}
    // A second at half strength lifts the middle by about half the radius.
    testing.expectf(t,heights[len(heights)-1]>1 && heights[len(heights)-1]<2,"a second lifted %v",heights[len(heights)-1])
    for z in 0..<17 {for x in 0..<17 {
        testing.expect(t,terrain.source_value(&stroke.source,{x,0,z})<=heights[len(heights)-1])
    }}
}
