package editor

import "core:testing"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import mm "mirai:std/math"

// A recording reads the image of its view wide: after the tonemap, the
// window's image without its 8-bit steps; before it, the exposed linear light
// beyond 1. GPU and validation.
@(test)
a_recording_reads_its_frames_wide_before_and_after_the_tonemap :: proc(t:^testing.T) {
    Recorded_World :: struct {using world:core.Test_World}
    world:Recorded_World
    if !core.test_world_init(t,&world) {return}
    defer core.test_world_destroy(&world)
    settings:=gpu.DEFAULT_SETTINGS
    settings.gi_enabled,settings.taa=false,false
    app,error:=host.app_create({gpu=true,gpu_validation=true,assets_root="assets",window_desc={size={96,64}},threads=1,render_settings=settings})
    if !testing.expect_value(t,error,host.App_Error.None) || app==nil {return}
    defer host.app_destroy(app)
    app.info=core.test_world_info(&world)
    cube,made:=erender.mesh_instance(app.assets,{shape=.Cube},mm.transform_matrix({position={0,0.5,0},rotation=1,scale={1,1,1}}),{color={0.2,0.9,0.5,1},emission={2,6,3}})
    if !testing.expect(t,made) {return}
    host.assets_commit(app.assets)
    gpu.scene_set(app.renderer,{cube},nil,{},{background={0.3,0.05,0.02},use_background=true})
    host.app_camera_set(app,{position={0,1.2,4},forward={0,-0.7,-4},up={0,1,0},fov_y=40,near=0.05,far=100,exposure=gpu.UNIT_EXPOSURE},true)
    size:=[2]i32{64,48}
    images:[2][]f32
    eight:[]u8
    for wide,i in ([2]gpu.View_Wide{.Display,.Scene}) {
        rec:host.World_Recording
        if !testing.expect(t,host.app_recording_begin(app,&rec,size,wide,false)) {return}
        images[i]=make([]f32,int(size.x*size.y*4))
        for _ in 0..<3 {
            if !testing.expect(t,host.app_recording_frame(app,&rec,&world,images[i]),app.renderer.error) {host.app_recording_end(app,&rec);return}
        }
        if wide==.Display {
            width,height:int
            ok:bool
            eight,width,height,ok=gpu.view_texture_capture(app.renderer,rec.texture,context.allocator)
            testing.expect(t,ok && width==int(size.x) && height==int(size.y))
        }
        host.app_recording_end(app,&rec)
    }
    defer {delete(images[0]);delete(images[1]);delete(eight)}
    // The display image is the 8-bit one less its steps and its dither.
    far,beyond:=0,0
    for value,i in images[0] {
        if i%4==3 {continue}
        testing.expect(t,value>=0 && value<=1)
        if abs(value*255-f32(eight[i]))>2 {far+=1}
    }
    for value,i in images[1] {
        if i%4!=3 && value>1 {beyond+=1}
    }
    testing.expectf(t,far==0,"%d channels of the display image differ from the 8-bit one by more than two steps",far)
    testing.expectf(t,beyond>0,"the linear image keeps the light beyond 1 of the emissive cube")
    testing.expect_value(t,rhi.device_validation_errors(app.device),0)
}
