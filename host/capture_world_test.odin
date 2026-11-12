package host

import "core:testing"
import "mirai:core"
import "mirai:rhi"
import "mirai:rhi/shared_device"

@(private="file")
Capture_Seen :: struct {scene:[4]f32,player:[4]i32,ran:bool}

@(private="file")
capture_seen_ui :: proc(world,shared,editor,app:rawptr) {
    seen:=cast(^Capture_Seen)world
    a:=cast(^App)app
    seen^={app_scene_points(a),app_player_rect(a,0,1),true}
}

// A world drawn off the window has the whole image for its UI and its
// players, not the part of the window that the view of the editor takes; the
// window keeps its part.
@(test)
a_world_drawn_off_the_window_fills_the_image :: proc(t:^testing.T) {
    shared_device.hold(t)
    app,error:=app_create({gpu=true,window=true,window_desc={size={64,48},hidden=true},fixed_dt=1.0/60,threads=1})
    if app==nil {
        testing.expectf(t,rhi.gpu_skip_allowed(),"no application with a GPU: %v (set MIRAI_ALLOW_GPU_SKIP=1 to skip)",error)
        return
    }
    defer app_destroy(app)
    info:core.World_Info
    info.loops[.Game][.Ui]=capture_seen_ui
    app.info=&info
    defer app.info=nil
    rail:=[4]i32{8,0,app.drawable.x-8,app.drawable.y}
    app.scene,app.scene_shift=rail,{0.1,0}
    seen:Capture_Seen
    pixels,width,height,ok:=app_capture_world(app,&seen,1)
    defer delete(pixels,app.allocator)
    if !testing.expect(t,ok && seen.ran,app_draw_problem(app)) {return}
    testing.expect_value(t,[2]i32{i32(width),i32(height)},app.drawable)
    testing.expect_value(t,seen.scene,[4]f32{})
    testing.expect_value(t,seen.player,[4]i32{0,0,app.drawable.x,app.drawable.y})
    testing.expect(t,app.scene==rail && app.scene_shift==[2]f32{0.1,0},"the window keeps the part of its view")
}
