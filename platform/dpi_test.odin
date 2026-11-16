package platform

import "core:testing"
import sdl "vendor:sdl3"

@(test)
display_content_scale_changes_points_without_changing_the_drawable :: proc(t:^testing.T) {
    samples:=[?]struct {content,pixel:f32,native,pixels,points:[2]i32}{
        {1,1,{1600,900},{1600,900},{1600,900}},
        {2,1,{1600,900},{1600,900},{800,450}},
        {1.75,1,{1638,900},{1638,900},{936,514}},
        {2,2,{800,450},{1600,900},{800,450}},
    }
    for sample in samples {
        p:Platform
        window_metrics_apply(&p,&p.input.frame.window,sample.native,sample.pixels,display_scale(sample.content,sample.pixel))
        testing.expect_value(t,p.input.frame.window.size,sample.points)
        testing.expect_value(t,p.input.frame.window.pixel_size,sample.pixels)
        testing.expect_value(t,p.input.frame.window.density,sample.content)
        testing.expect_value(t,p.input.frame.window.pixel_density,sample.pixel)
        testing.expect_value(t,window_point(&p,{100,50}*p.window.coordinate_scale),[2]f32{100,50})
    }
}

@(test)
scaled_sdl_pointer_events_keep_captured_motion_in_device_units :: proc(t:^testing.T) {
    p:=test_headless(t)
    if p==nil {return}
    defer destroy(p)
    window_metrics_apply(p,&p.input.frame.window,{1600,900},{1600,900},display_scale(2,1))
    event:sdl.Event
    event.motion={type=.MOUSE_MOTION,x=100,y=80,xrel=10,yrel=6}
    window_translate(p,&event)
    tick:=input_tick_take(p)
    testing.expect_value(t,tick.mouse_position,[2]f32{50,40})
    testing.expect_value(t,tick.mouse_delta,[2]f32{5,3})
    p.window.relative_mouse=true
    event.motion={type=.MOUSE_MOTION,x=120,y=100,xrel=10,yrel=6}
    window_translate(p,&event)
    event.button={type=.MOUSE_BUTTON_DOWN,button=sdl.BUTTON_LEFT,down=true,x=160,y=140,clicks=1}
    window_translate(p,&event)
    tick=input_tick_take(p)
    testing.expect_value(t,tick.mouse_position,[2]f32{80,70})
    testing.expect_value(t,tick.mouse_delta,[2]f32{10,6})
    testing.expect(t,.Left in tick.mouse_pressed)
}

@(test)
display_scale_changes_rebase_the_pointer_and_preserve_relative_motion :: proc(t:^testing.T) {
    p:Platform
    p.window.coordinate_scale=1
    p.input.frame.mouse_position={200,100}
    p.input.tick.mouse_delta={20,10}
    window_metrics_apply(&p,&p.input.frame.window,{1600,900},{1600,900},display_scale(2,1))
    testing.expect_value(t,p.input.frame.mouse_position,[2]f32{100,50})
    testing.expect_value(t,p.input.tick.mouse_delta,[2]f32{10,5})
    p.window.relative_mouse=true
    window_metrics_apply(&p,&p.input.frame.window,{1600,900},{1600,900},display_scale(1,1))
    testing.expect_value(t,p.input.frame.mouse_position,[2]f32{200,100})
    testing.expect_value(t,p.input.tick.mouse_delta,[2]f32{10,5})
    p.input.frame.mouse_position=MOUSE_OUTSIDE
    p.input.live.mouse_position=MOUSE_OUTSIDE
    p.input.tick.mouse_position=MOUSE_OUTSIDE
    window_metrics_apply(&p,&p.input.frame.window,{1600,900},{1600,900},display_scale(2,1))
    testing.expect_value(t,p.input.frame.mouse_position,MOUSE_OUTSIDE)
    testing.expect_value(t,p.input.live.mouse_position,MOUSE_OUTSIDE)
    testing.expect_value(t,p.input.tick.mouse_position,MOUSE_OUTSIDE)
}
