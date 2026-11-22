package render

import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import "mirai:host"
import gpu "mirai:render"
import mm "mirai:std/math"

@(test)
the_game_draws_only_arrows_in_game_from_their_place_or_onto_it :: proc(t:^testing.T) {
    w:Render_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    drawn:Arrows_Drawn
    defer delete(drawn.vertices)
    extras:=new(host.Frame_Extras)
    defer free(extras)
    // Turned a quarter around Y and stretched twice along its Z: its -Z goes to -X, twice its length long.
    pose:=mm.Transform{position={1,2,3},rotation=mm.quat_axis_angle({0,1,0},math.PI/2),scale={1,1,2}}
    leaving,arriving,hidden,editor_only:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    for e in ([4]core.Entity{leaving,arriving,hidden,editor_only}) {
        core.add(&w.worlds,e,core.World_Transform{pose,pose})
        core.add(&w.arrows,e,Arrow{color={1,0,0},length=1.5,direction={0,0,-1},in_game=e!=editor_only,arrives=e==arriving})
    }
    set_hidden(&w.hidden,hidden,true)
    core.add(&w.arrows,core.create(&w.entities),Arrow{length=1,direction={0h7fc00000,0,0},in_game=true})
    test_world_settle(&w)
    arrows_draw_game(&drawn,core.read(&w.arrows),core.read(&w.worlds),core.read(&w.hidden),core.read(&w.parents),extras,nil)
    testing.expect_value(t,extras.debug_count,1)
    lines:=extras.debug[0]
    testing.expect(t,lines.triangles && lines.depth_test)
    testing.expect_value(t,lines.count,2*gpu.DEBUG_ARROW_VERTICES)
    // The tip is the vertex farthest along -X: one leaves its place, the other ends there.
    tips:=[2][3]f32{{-2,2,3},{1,2,3}}
    for tip,i in tips {
        farthest:=lines.vertices[i*gpu.DEBUG_ARROW_VERTICES].position
        for v in lines.vertices[i*gpu.DEBUG_ARROW_VERTICES:][:gpu.DEBUG_ARROW_VERTICES] {if v.position.x<farthest.x {farthest=v.position}}
        testing.expectf(t,linalg.length(farthest-tip)<1e-4,"arrow %d reaches %v, not %v",i,tip,farthest)
    }
}
