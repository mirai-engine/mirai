package host

import "core:testing"
import "core:time"
import "mirai:core"
import "mirai:platform"

@(private)
@(test_world)
Clock_Test_World :: struct {
    using world:Test_World,
    time:core.Time,
    frame_time:core.Frame_Time,
}

@(private="file")
clock_test_render :: proc(data,shared,editor,app:rawptr) {}

@(private="file")
clock_test_frame :: proc(app:^App,w:^Clock_Test_World,wait:time.Duration) -> f32 {
    time.sleep(wait)
    before:=app.time
    app_frame_begin(app)
    app_editor_frame(app,w,nil)
    return app.time-before
}

@(test)
outside_play_the_render_clock_advances_the_dt_of_each_frame_and_not_the_time_between_them :: proc(t:^testing.T) {
    w:Clock_Test_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    info:=test_world_info(&w)
    info.loops[.Editor][.Render]=clock_test_render

    manual,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    testing.expect_value(t,error,platform.Error.None)
    if manual==nil {return}
    defer platform.destroy(manual)
    app:=App{info=info,platform=manual,tick_dt=1.0/60,max_ticks=8}
    defer delete(app.worlds)
    for _ in 0..<3 {
        dt:=clock_test_frame(&app,&w,40*time.Millisecond)
        testing.expectf(t,abs(dt-1.0/60)<1e-5,"a frame of a manual run lasts its fixed dt: %v s",dt)
    }
    manual.fixed_dt=0.25
    stepped:=clock_test_frame(&app,&w,0)
    testing.expectf(t,abs(stepped-0.25)<1e-5,"engine.step gives its dt to the frame: %v s",stepped)
    testing.expect(t,!w.time.playing)

    live,live_error:=platform.create({headless=true,pacing=platform.Frame_Pacing{}})
    testing.expect_value(t,live_error,platform.Error.None)
    if live==nil {return}
    defer platform.destroy(live)
    app.platform=live
    clock_test_frame(&app,&w,0)
    waited:=clock_test_frame(&app,&w,40*time.Millisecond)
    testing.expectf(t,waited>=0.035,"without a fixed dt the clock is the real one: %v s",waited)
}
