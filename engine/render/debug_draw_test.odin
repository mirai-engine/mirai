package render

import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:host"

@(test)
debug_draw_batches_one_shots_and_expires_timed_geometry :: proc(t:^testing.T) {
    draw:Debug_Draw
    shapes:Debug_Shapes
    defer {delete(draw.queue.items);delete(draw.queue.waiting)}
    defer delete(shapes.shapes)
    defer delete(shapes.vertices)
    extras:=new(host.Frame_Extras)
    defer free(extras)
    problems:core.Problems
    debug_draw_submit(&draw,&shapes,extras,{},&problems)
    testing.expect(t,shapes.vertices==nil && shapes.shapes==nil)

    color:=[4]f32{1,0,0,1}
    testing.expect(t,debug_line(&draw,{},{1,2,3},color))
    testing.expect(t,debug_cross(&draw,{},1,color,duration=0.5))
    testing.expect(t,!debug_line(&draw,{},{1,2,3},color,duration=-1))
    debug_draw_submit(&draw,&shapes,extras,{dt=0.25},&problems)
    testing.expect_value(t,len(shapes.shapes),1)
    testing.expect_value(t,shapes.vertices[1].position,[3]f32{1,2,3})
    testing.expect(t,core.problem_find(&problems,core.NONE,"render.debug_capacity")!=nil,"a refused duration is reported")
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    {
        context.allocator=mem.tracking_allocator(&tracker)
        lines:=debug_draw_batch(&shapes,0.25)
        testing.expect_value(t,lines.count,6)
        testing.expect_value(t,debug_draw_batch(&shapes,0.25).count,0)
        for _ in 0..<DEBUG_DRAW_CAPACITY {_=debug_ray(&draw,{},{0,1,0},1,color)}
        testing.expect(t,!debug_box(&draw,{},{1,1,1},color))
        debug_draw_submit(&draw,&shapes,extras,{dt=0.25},&problems)
    }
    testing.expect_value(t,tracker.total_allocation_count,i64(0))
}

// A tick that runs again asks again for the shapes it asked for the first
// time: one that lasts is drawn once, not once per run of its tick.
@(test)
a_resimulated_tick_does_not_repeat_a_timed_shape :: proc(t:^testing.T) {
    draw:Debug_Draw
    shapes:Debug_Shapes
    defer {delete(draw.queue.items);delete(draw.queue.waiting)}
    defer delete(shapes.shapes)
    color:=[4]f32{0,1,0,1}
    time:=core.Time{tick=10,dt=1.0/60,playing=true}
    testing.expect(t,debug_box(&draw,{},{1,1,1},color,duration=2))
    debug_draw_tick(&draw,&shapes,time,nil)
    time.resimulating=true
    for _ in 0..<3 {
        testing.expect(t,debug_box(&draw,{},{1,1,1},color,duration=2))
        debug_draw_tick(&draw,&shapes,time,nil)
    }
    testing.expect_value(t,len(shapes.shapes),1)
    testing.expect_value(t,len(draw.queue.items),0)
}
