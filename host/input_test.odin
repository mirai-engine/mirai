package host

import "core:testing"
import "mirai:core"
import "mirai:platform"

Input_Test_World :: struct {
    using world:core.Test_World,
    time:core.Time,
    input:core.Input,
    frame:core.Frame_Input,
    frame_time:core.Frame_Time,
    tick_delta:[2]f32,
    presses:int,
}

input_test_tick :: proc(data,shared,editor,app:rawptr) {
    w:=cast(^Input_Test_World)data
    w.tick_delta+=w.input.mouse_delta
    if .Space in w.input.keys_pressed {w.presses+=1}
}

@(test)
frame_input_is_immediate_without_consuming_or_repeating_tick_input :: proc(t:^testing.T) {
    p,error:=platform.create({headless=true,fixed_dt=1.0/240,pacing=platform.Frame_Pacing{}})
    testing.expect_value(t,error,platform.Error.None)
    if p==nil {return}
    defer platform.destroy(p)
    w:Input_Test_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    info:=core.test_world_info(&w)
    info.loops[.Game][.Fixed]=input_test_tick
    app:=App{info=info,platform=p,tick_dt=1.0/60,max_ticks=8}
    defer delete(app.worlds)
    for i in 0..<8 {
        platform.input_inject(p,platform.Mouse_Motion_Event{delta={2,-1}})
        if i==0 {platform.input_inject(p,platform.Key_Event{key=.Space,down=true})}
        platform.frame_begin(p)
        app_game_frame(&app,&w)
        testing.expect_value(t,w.frame.mouse_delta,([2]f32{2,-1}))
        testing.expect_value(t,.Space in w.frame.keys_pressed,i==0)
        testing.expect_value(t,w.time.tick,u64((i+1)/4))
    }
    testing.expect_value(t,w.tick_delta,([2]f32{16,-8}))
    testing.expect_value(t,w.presses,1)
    platform.frame_begin(p)
    app_input_add(&app,{mouse_delta={3,5}})
    app_game_frame(&app,&w)
    testing.expect_value(t,w.frame.mouse_delta,([2]f32{3,5}))
    for _ in 0..<3 {
        platform.frame_begin(p)
        app_game_frame(&app,&w)
        testing.expect_value(t,w.frame.mouse_delta,([2]f32{}))
    }
    testing.expect_value(t,w.tick_delta,([2]f32{19,-3}))
    p.fixed_dt=1.0/20
    platform.input_inject(p,platform.Mouse_Motion_Event{delta={4,2}})
    platform.frame_begin(p)
    app_game_frame(&app,&w)
    testing.expect_value(t,w.frame.mouse_delta,([2]f32{4,2}))
    testing.expect_value(t,w.tick_delta,([2]f32{23,-1}))
    app.game_input_blocked=true
    platform.input_inject(p,platform.Mouse_Motion_Event{delta={20,30}})
    platform.frame_begin(p)
    app_game_frame(&app,&w)
    testing.expect_value(t,w.frame.mouse_delta,([2]f32{}))
    testing.expect_value(t,w.tick_delta,([2]f32{23,-1}))
    app.game_input_blocked=false
    app.game_input_excluded={.Space}
    platform.frame_begin(p)
    app_game_frame(&app,&w)
    testing.expect(t,.Space not_in w.input.keys_down && .Space not_in w.frame.keys_down)
}
