package host

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import "mirai:platform"
import render "mirai:render"
import "mirai:ui"

@(test)
world_panel_pointer_uses_the_focused_split_view :: proc(t:^testing.T) {
    input:=ui.Input{size={1280,720},pointer={960,360}}
    camera:=render.Camera{position={3,0,4},forward={0,0,-4},up={0,1,0},fov_y=60,near=0.1,far=100}
    ui_input_camera(&input,camera,{640,0,640,720})
    testing.expect(t,input.ray.valid)
    testing.expect(t,linalg.length(input.ray.direction-[3]f32{0,0,-1})<1e-5)
    testing.expect_value(t,input.pointer,[2]f32{960,360})
    testing.expect_value(t,input.size,[2]f32{1280,720})
    input.pointer={320,360}
    ui_input_camera(&input,camera,{640,0,640,720})
    testing.expect(t,!input.ray.valid)
    input.pointer={960,540}
    ui_input_camera(&input,camera,{640,360,640,360})
    testing.expect(t,input.ray.valid)
    testing.expect(t,linalg.length(input.ray.direction-[3]f32{0,0,-1})<1e-5)
    testing.expect_value(t,input.view.viewport_height,f32(360))
}

@(test)
an_aimed_ray_goes_through_the_center_of_the_view_wherever_the_pointer_is :: proc(t:^testing.T) {
    camera:=render.Camera{position={3,0,4},forward={0,0,-4},up={0,1,0},fov_y=60,near=0.1,far=100}
    input:=ui.Input{size={1280,720},pointer={10,10},pointer_absent=true}
    ui_input_camera(&input,camera,{640,0,640,720})
    testing.expect(t,!input.ray.valid)
    ui_input_camera(&input,camera,{640,0,640,720},aim=true)
    testing.expect(t,input.ray.valid)
    testing.expect(t,linalg.length(input.ray.direction-[3]f32{0,0,-1})<1e-5)
}

@(test)
the_commands_of_a_panel_that_follow_each_other_are_one_panel :: proc(t:^testing.T) {
    vertices:[12]ui.Vertex
    commands:=[?]ui.Draw_Command{
        {first=0,count=3,surface=1},{first=3,count=3,surface=1}, // one panel, cut in two by a clip
        {kind=.Begin_Layer,surface=2},{first=6,count=3,surface=2},{kind=.End_Layer,surface=2}, // a panel drawn into a texture keeps its layers
        {first=9,count=3,surface=1},                            // the first again, after another: its own run
    }
    placements:=[?]ui.World_Placement{
        {id=7,visible=true,position={1,2,3},pivot={50,25},billboard=true,depth_test=true,transform=1},
        {id=8,size={20,10},offscreen=true},
    }
    frame:=ui.Frame{vertices=vertices[:],commands=commands[:],placements=placements[:]}
    draws:[4]render.Ui_Draw
    panels:[4]render.World_Panel
    offscreen:[2]Ui_Offscreen
    offscreen_draws:[4]render.Ui_Draw
    out:=ui_frame_split(frame,draws[:],panels[:],offscreen[:],offscreen_draws[:],2)
    testing.expect_value(t,out.panel_count,2)
    testing.expect_value(t,out.offscreen_count,1)
    testing.expect_value(t,out.dropped,0)
    testing.expect_value(t,len(panels[0].vertices),6)
    testing.expect_value(t,len(panels[1].vertices),3)
    testing.expect(t,panels[0].billboard && panels[0].view==2 && panels[0].pivot==[2]f32{50,25} && panels[0].origin==[3]f32{1,2,3})
    testing.expect(t,offscreen[0].id==8 && offscreen[0].size==[2]f32{20,10} && len(offscreen[0].layer.draws)==3 && offscreen[0].layer.draws[0].kind==.Begin_Layer && offscreen[0].layer.draws[1].first==6)
}

@(test)
split_view_pointer_uses_content_scale_independently_of_native_density :: proc(t:^testing.T) {
    cases:=[?]struct {density,pixel_density:f32,drawable:[2]i32}{
        {1,1,{1280,720}},
        {2,1,{2560,1440}},
        {2,2,{2560,1440}},
        {1.5,1,{1920,1080}},
    }
    for sample in cases {
        p:platform.Platform
        p.input.frame={
            window={size={1280,720},pixel_size=sample.drawable,density=sample.density,pixel_density=sample.pixel_density},
            mouse_position={960,540},mouse_inside=true,
        }
        views:[4]core.View
        rects:[4][4]i32
        for &view,index in views {
            view=core.VIEW_DEFAULT
            view.camera=core.Entity(index+1)
            half:=sample.drawable/2
            rects[index]={i32(index%2)*half.x,i32(index/2)*half.y,half.x,half.y}
        }
        app:=App{
            platform=&p,drawable=sample.drawable,density=sample.density,pixel_density=sample.pixel_density,
            camera=camera_from_view(views[3]),ui_input=ui_input_from_platform(&p.input.frame),
        }
        app_views_set(&app,views[:],rects[:],3)
        testing.expect(t,app.local_camera_count==4 && app.local_cameras[3]==app.views[3].camera)
        testing.expect(t,app.ui_input.ray.valid)
        testing.expect(t,linalg.length(app.ui_input.ray.direction-[3]f32{0,0,-1})<1e-5)
        testing.expect_value(t,app.ui_input.view.viewport_height,f32(360))
        testing.expect_value(t,app.ui_input.size,[2]f32{1280,720})
        testing.expect_value(t,app.ui_input.pointer,[2]f32{960,540})
        app.ui_input.pointer={320,540}
        app_views_set(&app,views[:],rects[:],3)
        testing.expect(t,!app.ui_input.ray.valid)
    }
}

@(test)
each_quad_of_ui_gets_the_material_of_the_renderer :: proc(t:^testing.T) {
    testing.expect_value(t,ui_material(ui.quad_pack(.Solid)),u32(0))
    testing.expect_value(t,ui_material(ui.quad_pack(.Shape,12)),render.UI_MATERIAL_SHAPE_BIT|12)
    testing.expect_value(t,ui_material(ui.quad_pack(.Program,12)),render.UI_MATERIAL_PROGRAM_BIT|12)
    testing.expect_value(t,ui_material(ui.quad_pack(.Program,ui.QUAD_DATA_MASK))&~u32(ui.QUAD_DATA_MASK),render.UI_MATERIAL_PROGRAM_BIT)
}
