package ui

import "core:testing"

@(test)
analytic_shapes_keep_their_curves_gradients_and_borders_in_six_vertices :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,{no_font=true}))
    defer context_destroy(&ctx)
    frame_begin(&ctx,test_input())
    draw_shape(&ctx,{8,8,48,48},{fill={255,0,0,255},fill2={0,0,255,255},gradient=.Vertical,radii={16,16,16,16},stroke={0,255,0,255},stroke_width=2})
    frame:=frame_end(&ctx)
    testing.expect_value(t,len(frame.shapes),1)
    testing.expect_value(t,len(frame.vertices),6)
    image:=test_raster(&ctx,frame,64,64,1,{0,0,0,255})
    defer test_image_destroy(&image)
    testing.expect(t,test_color_near(test_pixel(&image,8,8),{0,0,0,255}))
    testing.expect(t,test_color_near(test_pixel(&image,32,8),{0,255,0,255}))
    top,bottom:=test_pixel(&image,32,12),test_pixel(&image,32,51)
    testing.expect(t,top.r>top.b && bottom.b>bottom.r)
    corner:=test_pixel(&image,12,12)
    testing.expect(t,corner.g>0 && corner.g<255,"rounded edges retain fractional coverage")
    test_image_dump(&image,"analytic-gradient-border")
}

@(test)
analytic_shadows_fade_outside_the_box_without_nested_rectangles :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,{no_font=true}))
    defer context_destroy(&ctx)
    frame_begin(&ctx,test_input())
    draw_blurred_shadow(&ctx,{24,16,32,32},6,4,{0,0},{255,255,255,255})
    frame:=frame_end(&ctx)
    testing.expect_value(t,len(frame.shapes),1)
    testing.expect_value(t,len(frame.vertices),6)
    image:=test_raster(&ctx,frame,80,64,1,{0,0,0,255})
    defer test_image_destroy(&image)
    inside,near,far:=test_pixel(&image,28,32),test_pixel(&image,22,32),test_pixel(&image,15,32)
    testing.expect(t,inside.r>near.r && near.r>far.r && far.r>0)
    testing.expect_value(t,test_pixel(&image,8,32).r,u8(0))
    test_image_dump(&image,"analytic-shadow")
}

@(test)
composition_applies_opacity_once_to_overlapping_children :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,{no_font=true}))
    defer context_destroy(&ctx)
    frame_begin(&ctx,test_input())
    composition_begin(&ctx,{0,0,64,64},{enabled=true,opacity=0.5})
    draw_rect(&ctx,{8,8,32,48},{255,0,0,255})
    draw_rect(&ctx,{24,8,32,48},{255,0,0,255})
    composition_end(&ctx)
    frame:=frame_end(&ctx)
    testing.expect_value(t,len(frame.layers),1)
    image:=test_raster(&ctx,frame,64,64,1,{0,0,255,255})
    defer test_image_destroy(&image)
    single,overlap:=test_pixel(&image,12,32),test_pixel(&image,32,32)
    testing.expect_value(t,single,overlap)
    testing.expect(t,test_color_near(overlap,{128,0,128,255}))
    testing.expect(t,test_color_near(test_pixel(&image,2,32),{0,0,255,255}))
    test_image_dump(&image,"composition-opacity")
}

@(test)
nested_composition_masks_all_children_to_the_rounded_group :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,{no_font=true}))
    defer context_destroy(&ctx)
    frame_begin(&ctx,test_input())
    composition_begin(&ctx,{4,4,56,56},{enabled=true,opacity=1,radius=16})
    draw_rect(&ctx,{0,0,64,64},{0,255,0,255})
    composition_begin(&ctx,{16,16,32,32},{enabled=true,opacity=0.5,radius=8})
    draw_rect(&ctx,{0,0,64,64},{255,0,0,255})
    composition_end(&ctx)
    composition_end(&ctx)
    frame:=frame_end(&ctx)
    image:=test_raster(&ctx,frame,64,64,1,{0,0,0,255})
    defer test_image_destroy(&image)
    testing.expect(t,test_color_near(test_pixel(&image,4,4),{0,0,0,255}))
    testing.expect(t,test_color_near(test_pixel(&image,32,8),{0,255,0,255}))
    testing.expect(t,test_color_near(test_pixel(&image,16,16),{0,255,0,255}))
    testing.expect(t,test_color_near(test_pixel(&image,32,32),{128,128,0,255}))
    test_image_dump(&image,"composition-nested-mask")
}

@(test)
composition_backdrop_blurs_the_parent_and_preserves_pixels_outside_its_mask :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,{no_font=true}))
    defer context_destroy(&ctx)
    frame_begin(&ctx,test_input())
    for x in 0..<16 {draw_rect(&ctx,{f32(x*4),0,4,64},x%2==0 ? Color{255,0,0,255} : Color{0,0,255,255})}
    composition_begin(&ctx,{16,16,32,32},{enabled=true,opacity=1,radius=8,backdrop_blur=2})
    composition_end(&ctx)
    frame:=frame_end(&ctx)
    image:=test_raster(&ctx,frame,64,64,1,{0,0,0,255})
    defer test_image_destroy(&image)
    center:=test_pixel(&image,32,32)
    testing.expect(t,center.r>40 && center.b>40,"backdrop contains contributions from neighbouring stripes")
    testing.expect(t,test_color_near(test_pixel(&image,8,32),{255,0,0,255}))
    testing.expect(t,test_color_near(test_pixel(&image,16,16),{255,0,0,255}))
    test_image_dump(&image,"composition-backdrop")
}

@(test)
an_arc_is_one_analytic_shape_cut_from_the_top_clockwise :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,{no_font=true}))
    defer context_destroy(&ctx)
    frame_begin(&ctx,test_input())
    draw_arc(&ctx,{32,32},20,8,0.25,{255,200,0,255})
    frame:=frame_end(&ctx)
    testing.expect_value(t,len(frame.shapes),1)
    testing.expect_value(t,len(frame.vertices),6)
    image:=test_raster(&ctx,frame,64,64,1,{0,0,0,255})
    defer test_image_destroy(&image)
    // A quarter: the ring from the top to the right, nothing past it.
    testing.expect(t,test_pixel(&image,46,18).r>200,"inside the quarter")
    testing.expect_value(t,test_pixel(&image,46,46).r,u8(0))
    testing.expect_value(t,test_pixel(&image,18,18).r,u8(0))
    testing.expect_value(t,test_pixel(&image,32,32).r,u8(0))
    edge:=test_pixel(&image,52,32)
    testing.expect(t,edge.r>0 && edge.r<255,"the cut at the quarter keeps fractional coverage")
    test_image_dump(&image,"analytic-arc")
}
