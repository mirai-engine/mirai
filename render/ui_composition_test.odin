package mirai_render

import "core:fmt"
import "core:mem"
import "core:testing"
import "mirai:rhi"

@(private="file")
shape_quad :: proc(x,y,w,h:f32,index:u32) -> [6]Ui_Vertex {
    result:=quad(x,y,w,h,{1,1,1,1},UI_MATERIAL_SHAPE_BIT|index)
    for &vertex in result {vertex.uv=vertex.position.xy}
    return result
}

@(test)
ui_analytic_shapes_have_rounded_coverage_strokes_gradients_and_gaussian_shadows :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,96,64) {return}
    defer overlay_fixture_destroy(t,&f)
    white:=quad(0,0,96,64,{1,1,1,1})
    shapes:=[]Ui_Shape{
        {bounds={8,8,32,24},radii={10,10,10,10},fill={1,0,0,1},fill2={0,1,0,1},stroke={0,0,1,1},params={2,0,0,1}},
        {bounds={52,8,28,24},fill={1,0,1,1},params={0,1,0,0}},
        {bounds={16,44,28,8},radii={4,4,4,4},fill={0,0,0,0.8},params={0,2,3,0}},
    }
    rounded,ellipse,shadow:=shape_quad(7,7,34,26,0),shape_quad(51,7,30,26,1),shape_quad(7,35,46,26,2)
    vertices:[18]Ui_Vertex
    copy(vertices[:6],rounded[:]);copy(vertices[6:12],ellipse[:]);copy(vertices[12:],shadow[:])
    pixels:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=white[:]},{vertices=vertices[:],shapes=shapes}}})
    defer delete(pixels)
    testing.expect_value(t,at(pixels,96,8,8),[4]u8{255,255,255,255})
    testing.expect(t,near_color(at(pixels,96,24,8),{0,0,255,255},3),fmt.tprintf("stroke: %v",at(pixels,96,24,8)))
    top,bottom:=at(pixels,96,24,12),at(pixels,96,24,27)
    testing.expect(t,top[0]>top[1] && bottom[1]>bottom[0],"the gradient remains inside the rounded shape")
    testing.expect_value(t,at(pixels,96,66,20),[4]u8{255,0,255,255})
    testing.expect_value(t,at(pixels,96,52,8),[4]u8{255,255,255,255})
    inside,outside:=at(pixels,96,30,47),at(pixels,96,30,39)
    testing.expect(t,inside[0]<outside[0] && outside[0]<255,fmt.tprintf("Gaussian shadow has a smooth tail: inside=%v outside=%v",inside,outside))
    // Shape indices outside the uploaded budget are transparent rather than out-of-bounds reads.
    for &vertex in vertices[:6] {vertex.material=UI_MATERIAL_SHAPE_BIT|u32(len(shapes))}
    invalid:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=white[:]},{vertices=vertices[:6],shapes=shapes}}})
    defer delete(invalid)
    testing.expect_value(t,at(invalid,96,24,20),[4]u8{255,255,255,255})
}

@(test)
ui_isolated_layers_apply_opacity_once_and_clip_all_children_to_rounded_bounds :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,64,48) {return}
    defer overlay_fixture_destroy(t,&f)
    white,red,blue:=quad(0,0,64,48,{1,1,1,1}),quad(0,0,48,48,{1,0,0,1}),quad(24,0,40,48,{0,0,1,1})
    vertices:[12]Ui_Vertex
    copy(vertices[:6],red[:]);copy(vertices[6:],blue[:])
    commands:=[]Ui_Draw{{kind=.Begin_Layer},{first=0,count=12},{kind=.End_Layer}}
    effects:=[]Ui_Effect{{bounds={8,8,48,32},radius=10,opacity=0.5}}
    pixels:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=white[:]},{vertices=vertices[:],draws=commands,effects=effects}}})
    defer delete(pixels)
    testing.expect(t,near_color(at(pixels,64,16,24),{255,128,128,255},2))
    testing.expect(t,near_color(at(pixels,64,32,24),{128,128,255,255},2),fmt.tprintf("overlap is the final child color at group opacity: %v",at(pixels,64,32,24)))
    testing.expect_value(t,at(pixels,64,8,8),[4]u8{255,255,255,255})
    testing.expect_value(t,at(pixels,64,4,24),[4]u8{255,255,255,255})
    testing.expect_value(t,at(pixels,64,60,24),[4]u8{255,255,255,255})
    // Nested isolation composes each group once, preserving the outer clip.
    nested:=[]Ui_Draw{{kind=.Begin_Layer},{first=0,count=6},{kind=.Begin_Layer,layer=1},{first=6,count=6},{kind=.End_Layer,layer=1},{kind=.End_Layer}}
    nested_effects:=[]Ui_Effect{effects[0],{bounds={24,16,24,16},opacity=0.5}}
    result:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=white[:]},{vertices=vertices[:],draws=nested,effects=nested_effects}}})
    defer delete(result)
    testing.expect(t,near_color(at(result,64,32,24),{191,128,191,255},3),fmt.tprintf("nested opacity: %v",at(result,64,32,24)))
    testing.expect(t,near_color(at(result,64,32,12),{255,128,128,255},2))
    // A UI texture composes them as the screen does, with targets of its own size.
    texture,made:=ui_texture_add(f.renderer,32,24,"ui on mesh")
    if !testing.expect(t,made,f.renderer.error) {return}
    defer ui_texture_remove(f.renderer,texture)
    into:=[]Ui_Texture_Draw{{texture=texture,layer={vertices=white[:]},size={64,48}},{texture=texture,layer={vertices=vertices[:],draws=commands,effects=effects},size={64,48}}}
    testing.expect(t,renderer_frame(f.renderer,{offscreen=true,ui_only=true,ui_textures=into}),f.renderer.error)
    small,_,_,read:=ui_texture_capture(f.renderer,texture)
    if !testing.expect(t,read,f.renderer.error) {return}
    defer delete(small)
    testing.expect(t,near_color(at(small,32,8,12),{255,128,128,255},2))
    testing.expect(t,near_color(at(small,32,16,12),{128,128,255,255},2),fmt.tprintf("overlap in a texture: %v",at(small,32,16,12)))
    testing.expect_value(t,at(small,32,2,12),[4]u8{255,255,255,255})
}

@(test)
ui_backdrop_blur_reads_the_parent_and_keeps_content_drawn_after_it_sharp :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,64,48) {return}
    defer overlay_fixture_destroy(t,&f)
    black,white:=quad(0,0,32,48,{0,0,0,1}),quad(32,0,32,48,{1,1,1,1})
    background:[12]Ui_Vertex
    copy(background[:6],black[:]);copy(background[6:],white[:])
    mark:=quad(28,20,8,8,{1,0,0,1})
    commands:=[]Ui_Draw{{kind=.Begin_Layer},{count=6},{kind=.End_Layer}}
    effects:=[]Ui_Effect{{bounds={8,8,48,32},radius=8,opacity=1,backdrop_blur=4}}
    pixels:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=background[:]},{vertices=mark[:],draws=commands,effects=effects}}})
    defer delete(pixels)
    left,right:=at(pixels,64,30,16),at(pixels,64,33,16)
    testing.expect(t,left[0]>40 && left[0]<160 && right[0]>100 && right[0]<220,fmt.tprintf("both sides of the edge are blurred: %v %v",left,right))
    testing.expect_value(t,at(pixels,64,31,24),[4]u8{255,0,0,255})
    testing.expect_value(t,at(pixels,64,30,4),[4]u8{0,0,0,255})
    testing.expect_value(t,at(pixels,64,33,4),[4]u8{255,255,255,255})
}

@(test)
ui_composition_frames_reuse_shape_buffers_and_effect_targets_without_allocating :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,64,48) {return}
    defer overlay_fixture_destroy(t,&f)
    shapes:=[]Ui_Shape{{bounds={12,12,32,24},radii={8,8,8,8},fill={0.3,0.2,0.8,0.8}}}
    vertices:=shape_quad(11,11,34,26,0)
    commands:=[]Ui_Draw{{kind=.Begin_Layer},{count=6},{kind=.End_Layer}}
    effects:=[]Ui_Effect{{bounds={4,4,56,40},radius=12,opacity=0.8,backdrop_blur=3}}
    frame:=Frame_Desc{camera=EMPTY_CAMERA,ui={{vertices=vertices[:],draws=commands,shapes=shapes,effects=effects}}}
    for _ in 0..<4 {testing.expect(t,renderer_frame(f.renderer,frame),f.renderer.error)}
    allocations:=f.tracking.total_allocation_count
    resources:=rhi.device_stats(f.device)
    caller:mem.Tracking_Allocator
    mem.tracking_allocator_init(&caller,context.allocator)
    defer mem.tracking_allocator_destroy(&caller)
    {
        context.allocator=mem.tracking_allocator(&caller)
        for _ in 0..<8 {testing.expect(t,renderer_frame(f.renderer,frame),f.renderer.error)}
    }
    testing.expect_value(t,f.tracking.total_allocation_count,allocations)
    testing.expect_value(t,caller.total_allocation_count,0)
    after:=rhi.device_stats(f.device)
    testing.expect_value(t,after.buffers,resources.buffers)
    testing.expect_value(t,after.textures,resources.textures)
    testing.expect_value(t,after.pipelines,resources.pipelines)
    testing.expect_value(t,after.exhausted,0)
}

@(test)
world_panels_use_analytic_shapes_and_share_their_upload_with_screen_ui :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,128,96) {return}
    defer overlay_fixture_destroy(t,&f)
    scene_given(f.renderer,nil,nil,{},{background={0,0,0},use_background=true})
    shapes:=[]Ui_Shape{{bounds={0,0,100,100},fill={1,0,1,1},params={0,1,0,0}}}
    vertices:=shape_quad(-1,-1,102,102,0)
    panels:=[]World_Panel{panel(vertices[:],{0,0,0}),panel(vertices[:],{1.5,0,0})}
    for &p in panels {p.shapes=shapes}
    screen:=shape_quad(0,0,8,8,0)
    pixels:=captured(t,&f,{camera=PANEL_CAMERA,panels=panels,ui={{vertices=screen[:],shapes=shapes}}})
    defer delete(pixels)
    testing.expect_value(t,at(pixels,128,64,48),[4]u8{255,0,255,255})
    testing.expect_value(t,at(pixels,128,57,41),[4]u8{0,0,0,255})
    testing.expect_value(t,f.renderer.ui_shape_written,1)
    testing.expect_value(t,renderer_stats(f.renderer).ui_shapes_dropped,u32(0))
}

@(test)
ui_shape_and_layer_budgets_drop_whole_effects_without_corrupting_parent_draws :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,64,48,ui_shape_capacity=1,ui_layer_depth=1) {return}
    defer overlay_fixture_destroy(t,&f)
    shapes:=[]Ui_Shape{
        {bounds={8,8,16,24},fill={1,0,0,1}},
        {bounds={32,8,16,24},fill={0,1,0,1}},
    }
    first,second:=shape_quad(7,7,18,26,0),shape_quad(31,7,18,26,1)
    vertices:[12]Ui_Vertex
    copy(vertices[:6],first[:]);copy(vertices[6:],second[:])
    white:=quad(0,0,64,48,{1,1,1,1})
    commands:=[]Ui_Draw{{kind=.Begin_Layer},{first=0,count=6},{kind=.Begin_Layer,layer=1},{first=6,count=6},{kind=.End_Layer,layer=1},{kind=.End_Layer}}
    effects:=[]Ui_Effect{{bounds={4,4,56,36},opacity=1},{bounds={4,4,56,36},opacity=1}}
    pixels:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=white[:]},{vertices=vertices[:],shapes=shapes,draws=commands,effects=effects}}})
    defer delete(pixels)
    testing.expect_value(t,at(pixels,64,16,16),[4]u8{255,0,0,255})
    testing.expect_value(t,at(pixels,64,40,16),[4]u8{255,255,255,255})
    stats:=renderer_stats(f.renderer)
    testing.expect_value(t,stats.ui_shapes_dropped,u32(1))
    testing.expect_value(t,stats.ui_layers_dropped,u32(1))
    // An empty marker scissor prevents the composition from escaping its parent's clip.
    empty:=[]Ui_Draw{{kind=.Begin_Layer,scissor={0,0,-1,-1}},{first=0,count=6},{kind=.End_Layer}}
    clipped:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=white[:]},{vertices=vertices[:6],shapes=shapes[:1],draws=empty,effects=effects[:1]}}})
    defer delete(clipped)
    testing.expect_value(t,at(clipped,64,16,16),[4]u8{255,255,255,255})
}

@(test)
a_ui_program_colors_its_node_inside_the_rounded_bounds :: proc(t:^testing.T) {
    f:Overlay_Fixture
    if !overlay_fixture(t,&f,64,64) {return}
    defer overlay_fixture_destroy(t,&f)
    wipe:=program_find(f.renderer,"Ui_Radial_Wipe",.Ui)
    if !testing.expect(t,wipe!=nil,"the engine has Ui_Radial_Wipe") {return}
    white:=quad(0,0,64,64,{1,1,1,1})
    // Half a turn clockwise from the top: the right half of a disc.
    shapes:=[]Ui_Shape{{bounds={8,8,48,48},radii={24,24,24,24},fill={1,0,0,1},stroke={transmute(f32)wipe.id,0,0,0},params={0.5,0,0,0}}}
    vertices:=quad(7,7,50,50,{1,1,1,1},UI_MATERIAL_PROGRAM_BIT)
    for &vertex in vertices {vertex.uv=vertex.position.xy}
    pixels:=captured(t,&f,{camera=EMPTY_CAMERA,ui={{vertices=white[:]},{vertices=vertices[:],shapes=shapes}}})
    defer delete(pixels)
    testing.expect(t,near_color(at(pixels,64,44,32),{255,0,0,255},3),fmt.tprintf("the sector is filled: %v",at(pixels,64,44,32)))
    testing.expect_value(t,at(pixels,64,20,32),[4]u8{255,255,255,255})
    testing.expect_value(t,at(pixels,64,53,11),[4]u8{255,255,255,255})
}
