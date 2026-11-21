package render

import "core:mem"
import "core:testing"
import "mirai:host"

@(test)
debug_draw_batches_one_shots_and_expires_timed_geometry :: proc(t:^testing.T) {
    draw:Debug_Draw
    defer delete(draw.shapes)
    defer delete(draw.vertices)
    extras:=new(host.Frame_Extras)
    defer free(extras)
    debug_draw_submit(&draw,extras,{},nil)
    testing.expect(t,draw.vertices==nil && draw.shapes==nil)

    color:=[4]f32{1,0,0,1}
    testing.expect(t,debug_line(&draw,{},{1,2,3},color))
    testing.expect(t,debug_cross(&draw,{},1,color,duration=0.5))
    debug_draw_submit(&draw,extras,{dt=0.25},nil)
    testing.expect_value(t,len(draw.shapes),1)
    testing.expect_value(t,draw.vertices[1].position,[3]f32{1,2,3})
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    {
        context.allocator=mem.tracking_allocator(&tracker)
        lines:=debug_draw_batch(&draw,0.25)
        testing.expect_value(t,lines.count,6)
        testing.expect_value(t,debug_draw_batch(&draw,0.25).count,0)
        for _ in 0..<DEBUG_DRAW_CAPACITY {_=debug_ray(&draw,{},{0,1,0},1,color)}
        testing.expect(t,!debug_box(&draw,{},{1,1,1},color))
    }
    testing.expect_value(t,tracker.total_allocation_count,i64(0))
}
