package ui

import "core:math"
import "core:testing"

@(test)
vertices_keep_the_layout_the_renderer_reads :: proc(t:^testing.T) {
    testing.expect_value(t,size_of(Vertex),40)
    testing.expect_value(t,offset_of(Vertex,position),uintptr(0))
    testing.expect_value(t,offset_of(Vertex,color),uintptr(12))
    testing.expect_value(t,offset_of(Vertex,quad),uintptr(28))
    testing.expect_value(t,offset_of(Vertex,uv),uintptr(32))
    packed:=quad_pack(.Image,77)
    testing.expect_value(t,quad_kind(packed),Quad_Kind.Image)
    testing.expect_value(t,quad_data(packed),u32(77))
    testing.expect_value(t,quad_pack(.Solid),u32(0))
    testing.expect_value(t,quad_kind(quad_pack(quad_user(3),0xffffff)),Quad_Kind(19))
    testing.expect_value(t,quad_data(quad_pack(quad_user(3),0x1ffffff)),u32(0xffffff))
}

@(test)
rectangles_are_two_triangles_in_window_points :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input(800,600)
    input.scale=2
    frame_begin(&ctx,input)
    draw_rect(&ctx,{10,20,30,40},{255,0,51,255})
    draw_rect(&ctx,{10,20,0,40},{255,255,255,255})
    draw_rect(&ctx,{10,20,30,40},{255,255,255,0})
    frame:=frame_end(&ctx)
    testing.expect_value(t,len(frame.vertices),6)
    testing.expect_value(t,len(frame.commands),1)
    testing.expect_value(t,frame.commands[0],Draw_Command{first=0,count=6,scissor={0,0,800,600},surface=0})
    lo,hi:=[2]f32{max(f32),max(f32)},[2]f32{min(f32),min(f32)}
    for v in frame.vertices {
        lo={min(lo.x,v.position.x),min(lo.y,v.position.y)};hi={max(hi.x,v.position.x),max(hi.y,v.position.y)}
        testing.expect_value(t,v.color,[4]f32{1,0,0.2,1})
        testing.expect_value(t,v.quad,u32(0))
        testing.expect_value(t,v.position.z,f32(0))
    }
    testing.expect_value(t,lo,[2]f32{20,40})
    testing.expect_value(t,hi,[2]f32{80,120})
}

@(test)
the_clip_cuts_geometry_colors_and_texture_coordinates :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input()
    frame_begin(&ctx,input)
    clip_push(&ctx,{15,12,5,4})
    draw_quad(&ctx,{10,10,20,10},{0.2,0.3,0.4,0.2},{255,255,255,255},quad_pack(.Glyph,3))
    testing.expect_value(t,ctx.draw.count,6)
    for v in ctx.draw.vertices[:6] {
        testing.expect(t,v.position.x>=15 && v.position.x<=20 && v.position.y>=12 && v.position.y<=16,"Quads clip to the box")
        testing.expect(t,test_near(v.uv.x,0.2+(v.position.x-10)/20*0.4,0.00001) && test_near(v.uv.y,0.3+(v.position.y-10)/10*0.2,0.00001),"Clipping keeps the texel under each point")
        testing.expect_value(t,v.quad,quad_pack(.Glyph,3))
    }
    draw_quad(&ctx,{30,30,5,5},{0,0,1,1},{255,255,255,255},quad_pack(.Image,1))
    draw_rect(&ctx,{0,0,10,10},{255,255,255,255})
    testing.expect_value(t,ctx.draw.count,6)
    // A clip inside another is their intersection.
    clip_push(&ctx,{0,0,17,100})
    draw_rect(&ctx,{0,0,100,100},{255,255,255,255})
    testing.expect_value(t,ctx.draw.count,12)
    for v in ctx.draw.vertices[6:12] {testing.expect(t,v.position.x>=15 && v.position.x<=17 && v.position.y>=12 && v.position.y<=16)}
    clip_pop(&ctx)
    clip_pop(&ctx)
    // A triangle is cut into a fan whose colors follow the cut.
    clip_push(&ctx,{0,0,5,100})
    draw_triangle_colors(&ctx,{0,0},{10,0},{0,10},{0,0,0,255},{255,0,0,255},{0,0,0,255})
    testing.expect_value(t,ctx.draw.count,12+6)
    for v in ctx.draw.vertices[12:18] {
        testing.expect(t,v.position.x<=5.0001)
        testing.expect(t,test_near(v.color.r,v.position.x/10,0.0001),"Colors are interpolated at the cut")
    }
    clip_pop(&ctx)
    draw_rect(&ctx,{0,0,10,10},{255,255,255,255})
    testing.expect_value(t,ctx.draw.count,24)
    frame_end(&ctx)
}

@(test)
scissors_split_the_commands_and_skip_what_they_hide :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input(800,600)
    frame_begin(&ctx,input)
    white:=Color{255,255,255,255}
    draw_rect(&ctx,{0,0,10,10},white)
    scissor_push(&ctx,{100,100,200,100})
    draw_rect(&ctx,{150,150,10,10},white)
    draw_rect(&ctx,{0,0,10,10},white)        // outside: skipped whole
    draw_rect(&ctx,{90,90,20,20},white)      // across the edge: kept whole, the scissor cuts it
    scissor_push(&ctx,{250,0,500,500})
    draw_rect(&ctx,{260,150,10,10},white)
    draw_rect(&ctx,{150,150,10,10},white)    // inside the outer one only
    scissor_pop(&ctx)
    draw_rect(&ctx,{160,160,10,10},white)
    scissor_pop(&ctx)
    scissor_push(&ctx,{0,0,5,5})
    scissor_pop(&ctx)                        // nothing drawn: no command
    draw_rect(&ctx,{0,0,10,10},white)
    frame:=frame_end(&ctx)
    testing.expect_value(t,len(frame.commands),5)
    if len(frame.commands)!=5 {return}
    whole:=Rect{0,0,800,600}
    testing.expect_value(t,frame.commands[0],Draw_Command{first=0,count=6,scissor=whole})
    testing.expect_value(t,frame.commands[1],Draw_Command{first=6,count=12,scissor={100,100,200,100}})
    testing.expect_value(t,frame.commands[2],Draw_Command{first=18,count=6,scissor={250,100,50,100}})
    testing.expect_value(t,frame.commands[3],Draw_Command{first=24,count=6,scissor={100,100,200,100}})
    testing.expect_value(t,frame.commands[4],Draw_Command{first=30,count=6,scissor=whole})
    testing.expect_value(t,len(frame.vertices),36)
    total:u32
    for command in frame.commands {total+=command.count}
    testing.expect_value(t,total,u32(36))
}

@(test)
scissors_are_in_window_points_whatever_the_scale :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input(800,600)
    input.scale=2
    frame_begin(&ctx,input)
    scissor_push(&ctx,{10,10,100,50})
    draw_rect(&ctx,{20,20,10,10},{255,255,255,255})
    scissor_pop(&ctx)
    frame:=frame_end(&ctx)
    testing.expect_value(t,frame.commands[0].scissor,Rect{20,20,200,100})
}

@(test)
vertices_that_do_not_fit_are_dropped_whole_and_counted :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.max_vertices=14
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    input:=test_input()
    frame_begin(&ctx,input)
    storage:=raw_data(ctx.draw.vertices)
    white:=Color{255,255,255,255}
    draw_rect(&ctx,{0,0,10,10},white)
    draw_rect(&ctx,{0,0,10,10},white)
    draw_rect(&ctx,{0,0,10,10},white)
    draw_quad(&ctx,{0,0,10,10},{0,0,1,1},white,quad_pack(.Glyph))
    draw_triangle(&ctx,{0,0},{10,0},{0,10},white) // no room for three either
    frame:=frame_end(&ctx)
    testing.expect_value(t,len(frame.vertices),12)
    testing.expect(t,raw_data(frame.vertices)==storage,"The draw list is the preallocated array")
    testing.expect(t,frame.overflow)
    testing.expect_value(t,ctx.stats.dropped_vertices,u32(15))
    testing.expect_value(t,frame.commands[0].count,u32(12))
    frame_begin(&ctx,input)
    draw_rect(&ctx,{0,0,10,10},white)
    testing.expect(t,!frame_end(&ctx).overflow)
}

@(test)
commands_that_do_not_fit_drop_their_vertices :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.max_commands=2
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    input:=test_input()
    frame_begin(&ctx,input)
    white:=Color{255,255,255,255}
    for i in 0..<3 {
        scissor_push(&ctx,{f32(i)*10,0,10,10})
        draw_rect(&ctx,{f32(i)*10,0,10,10},white)
        scissor_pop(&ctx)
    }
    frame:=frame_end(&ctx)
    testing.expect_value(t,len(frame.commands),2)
    testing.expect_value(t,len(frame.vertices),12)
    testing.expect_value(t,ctx.stats.dropped_commands,u32(1))
    testing.expect(t,frame.overflow)
}

@(test)
glyphs_snap_to_device_pixels_at_any_density :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_FONT
    desc.density=2
    desc.font_texture=5
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    input:=test_input(100,100)
    frame_begin(&ctx,input)
    draw_text(&ctx,"Mirai",10.3,7.7,13,{255,255,255,255})
    frame:=frame_end(&ctx)
    testing.expect_value(t,len(frame.vertices),30)
    for v in frame.vertices {
        for axis in 0..<2 {testing.expectf(t,abs(v.position[axis]*2-math.round(v.position[axis]*2))<1e-3,"Vertex %v lies on the device pixel grid",v.position)}
        testing.expect_value(t,v.quad,quad_pack(.Glyph,5))
    }
    // A size without a face of its own scales the nearest one.
    frame_begin(&ctx,input)
    draw_text(&ctx,"A",0,0,40,{255,255,255,255})
    frame=frame_end(&ctx)
    testing.expect_value(t,len(frame.vertices),6)
    height:=frame.vertices[2].position.y-frame.vertices[0].position.y
    testing.expect(t,height>25 && height<40,"The glyph is as tall as its size asks")
}

@(test)
nine_slices_keep_their_borders :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input()
    frame_begin(&ctx,input)
    draw_nine_slice(&ctx,{100,100,200,80},{.Image,9,{0,0,0.5,0.5}},{10,10,10,10},{0.25,0.25,0.25,0.25},{255,255,255,128})
    frame:=frame_end(&ctx)
    testing.expect_value(t,len(frame.vertices),54)
    // The first quad is the top-left corner, the fifth the stretched middle.
    corner,middle:=frame.vertices[0:6],frame.vertices[24:30]
    testing.expect_value(t,corner[0].position.xy,[2]f32{100,100})
    testing.expect_value(t,corner[2].position.xy,[2]f32{110,110})
    testing.expect_value(t,corner[2].uv,[2]f32{0.125,0.125})
    testing.expect_value(t,middle[0].position.xy,[2]f32{110,110})
    testing.expect_value(t,middle[2].position.xy,[2]f32{290,170})
    testing.expect_value(t,middle[0].uv,[2]f32{0.125,0.125})
    testing.expect_value(t,middle[2].uv,[2]f32{0.375,0.375})
    testing.expect_value(t,middle[0].quad,quad_pack(.Image,9))
    testing.expect(t,test_near(middle[0].color.a,128.0/255))
    // Borders larger than the rectangle shrink together.
    frame_begin(&ctx,input)
    draw_nine_slice(&ctx,{0,0,10,80},{.Image,9,{0,0,1,1}},{10,10,10,10},{0.25,0.25,0.25,0.25})
    frame=frame_end(&ctx)
    testing.expect_value(t,frame.vertices[2].position.x,f32(5))
}

@(test)
shapes_rasterize_with_their_colors_corners_and_antialiasing :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input(64,64)
    frame_begin(&ctx,input)
    draw_rounded(&ctx,{8,8,48,32},8,{200,40,40,255})
    draw_rounded_stroke(&ctx,{8,8,48,32},8,1,{40,200,40,255})
    draw_rect(&ctx,{0,48,64,16},{0,0,255,128})
    draw_line(&ctx,{4,60.25},{60,60.25},2,{255,255,255,255})
    draw_circle(&ctx,{32,24},4,{255,255,0,255})
    frame:=frame_end(&ctx)
    black:=Color{0,0,0,255}
    image:=test_raster(&ctx,frame,64,64,1,black)
    defer test_image_destroy(&image)
    test_image_dump(&image,"shapes")
    testing.expect(t,test_color_near(test_pixel(&image,8,8),black),"Outside the round corner")
    testing.expect(t,test_color_near(test_pixel(&image,20,30),{200,40,40,255}),"Fill")
    testing.expect(t,test_color_near(test_pixel(&image,30,8),{40,200,40,255}),"Stroke along the top edge, inside the bounds")
    testing.expect(t,test_color_near(test_pixel(&image,30,7),black),"Nothing above the bounds")
    testing.expect(t,test_color_near(test_pixel(&image,8,24),{40,200,40,255}),"Stroke along the left edge")
    testing.expect(t,test_color_near(test_pixel(&image,32,24),{255,255,0,255}),"Disc")
    testing.expect(t,test_color_near(test_pixel(&image,10,52),{0,0,128,255}),"Translucent shapes blend once, also along the diagonal of their quad")
    testing.expect(t,test_color_near(test_pixel(&image,16,52),{0,0,128,255}))
    testing.expect(t,test_color_near(test_pixel(&image,30,60),{255,255,255,255}),"Line core")
    edge:=test_pixel(&image,30,59)
    testing.expect(t,edge[0]>0 && edge[0]<255,"Lines fade over one pixel on each side")
}

@(test)
clips_follow_the_transform_they_were_set_under :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input()
    white:=Color{255,255,255,255}
    frame_begin(&ctx,input)
    d:=&ctx.draw
    // A clip of a container still cuts a subtree that is drawn moved and scaled.
    clip_push(&ctx,{0,0,100,100})
    draw_transform(d,{2,0,50,0,2,0},{1,1,1,1},false)
    draw_rect(&ctx,{0,0,100,100},white)
    testing.expect(t,test_rect_near(test_bounds(d.vertices[:6]),{50,0,50,100}))
    // A clip set inside the subtree is in its own space.
    clip_push(&ctx,{0,0,10,10})
    draw_rect(&ctx,{0,0,100,100},white)
    testing.expect(t,test_rect_near(test_bounds(d.vertices[6:12]),{50,0,20,20}))
    clip_pop(&ctx)
    draw_rect(&ctx,{0,0,100,100},white)
    testing.expect(t,test_rect_near(test_bounds(d.vertices[12:18]),{50,0,50,100}))
    // Back outside, the clip of the container is the one it was.
    draw_transform(d,AFFINE_IDENTITY,{1,1,1,1},true)
    draw_rect(&ctx,{0,0,500,500},white)
    testing.expect(t,test_rect_near(test_bounds(d.vertices[18:24]),{0,0,100,100}))
    clip_pop(&ctx)
    draw_rect(&ctx,{0,0,500,500},white)
    testing.expect(t,test_rect_near(test_bounds(d.vertices[24:30]),{0,0,500,500}))
    frame_end(&ctx)
}

// The round shapes as they were written first, a call and four cosines per
// triangle: what the tables and the whole shapes of draw.odin have to match
// vertex by vertex.
@(test)
a_frame_that_only_draws_does_not_lay_anything_out :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    input:=test_input()
    drawn :: proc(ctx:^Context) -> Frame {
        draw_rect(ctx,{10,20,30,40},{255,0,51,255})
        draw_text(ctx,"Cubes: 12",20,60,16,{255,255,255,255})
        return frame_end(ctx)
    }
    // Shapes and text alone: the frame has its vertices and no layout was started.
    frame_begin(&ctx,input)
    frame:=drawn(&ctx)
    testing.expect(t,!ctx.layout_started)
    alone:=len(frame.vertices)
    testing.expect(t,alone>6 && !frame.overflow)
    testing.expect_value(t,ctx.stats.elements,u32(0))
    // The first element sets it up, and what was drawn before it stays under it.
    frame_begin(&ctx,input)
    draw_rect(&ctx,{10,20,30,40},{255,0,51,255})
    testing.expect(t,!ctx.layout_started)
    label(&ctx,"A label")
    testing.expect(t,ctx.layout_started)
    draw_text(&ctx,"Cubes: 12",20,60,16,{255,255,255,255})
    frame=frame_end(&ctx)
    testing.expect(t,len(frame.vertices)>alone && ctx.stats.elements>0)
    testing.expect_value(t,frame.vertices[0].color,[4]f32{1,0,0.2,1})
    // And a frame without elements after one with them draws the same as the first.
    frame_begin(&ctx,input)
    frame=drawn(&ctx)
    testing.expect(t,!ctx.layout_started)
    testing.expect_value(t,len(frame.vertices),alone)
    testing.expect_value(t,ctx.stats.elements,u32(0))
}

@(test)
a_program_is_a_shape_that_carries_its_id_and_values :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    frame_begin(&ctx,test_input())
    draw_program(&ctx,{10,20,40,30},7,{0.25,0.5,1,-2},{255,128,0,200},{4,4,100,0})
    draw_program(&ctx,{10,20,40,30},0,{},{255,255,255,255},{})
    draw_program(&ctx,{10,20,0,30},7,{},{255,255,255,255},{})
    draw_shape(&ctx,{0,0,10,10},{fill={255,255,255,255}})
    frame:=frame_end(&ctx)
    testing.expect_value(t,len(frame.shapes),2)
    testing.expect_value(t,len(frame.vertices),12)
    for v in frame.vertices[:6] {
        testing.expect_value(t,v.quad,quad_pack(.Program,0))
        testing.expect_value(t,v.color,[4]f32{1,1,1,1})
        testing.expect(t,test_near(v.uv.x,v.position.x) && test_near(v.uv.y,v.position.y),"uv is the place in layout units")
    }
    program:=frame.shapes[0]
    testing.expect_value(t,program.bounds,[4]f32{10,20,40,30})
    testing.expect_value(t,program.radii,[4]f32{4,4,15,0})
    testing.expect_value(t,program.fill,[4]f32{255,128,0,200}/255)
    testing.expect_value(t,transmute(u32)program.stroke.x,u32(7))
    testing.expect_value(t,program.params,[4]f32{0.25,0.5,1,-2})
    testing.expect_value(t,frame.vertices[6].quad,quad_pack(.Shape,1))
}

@(test)
a_box_or_a_bar_with_a_program_fills_through_it :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    Case :: struct {program:u32,stroke:bool}
    s:Case
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Case)user
        b:=Box{width=fixed(100),height=fixed(40),fill={10,20,30,255},radius=6,program=s.program,program_values={1,2,3,4}}
        if s.stroke {b.stroke={255,255,255,255}}
        box_begin(ctx,b);box_end(ctx,b)
        progress(ctx,{value=0.5,width=fixed(200),height=fixed(20),fill={200,40,40,255},track={20,20,20,255},radius=4,program=s.program,program_values={0.5,0,0,0}})
    }
    input:=test_input()
    frame:=test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,len(frame.vertices),18)
    testing.expect_value(t,test_count_quad(frame.vertices,.Shape),18)
    plain:=frame.shapes[0]
    s={program=9}
    frame=test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,len(frame.vertices),18)
    testing.expect_value(t,quad_kind(frame.vertices[0].quad),Quad_Kind.Program)
    box:=frame.shapes[quad_data(frame.vertices[0].quad)]
    testing.expect(t,box.bounds==plain.bounds && box.radii==plain.radii && box.fill==plain.fill,"the program gets the rectangle, corners and color of the fill")
    testing.expect(t,transmute(u32)box.stroke.x==9 && box.params==[4]f32{1,2,3,4})
    testing.expect_value(t,quad_kind(frame.vertices[6].quad),Quad_Kind.Shape)
    bar:=frame.vertices[12:18]
    testing.expect_value(t,quad_kind(bar[0].quad),Quad_Kind.Program)
    testing.expect_value(t,test_bounds(bar).w,f32(100))
    testing.expect_value(t,frame.shapes[quad_data(bar[0].quad)].bounds[2],f32(200))
    // The stroke stays a shape over the program.
    s={program=9,stroke=true}
    frame=test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,quad_kind(frame.vertices[0].quad),Quad_Kind.Program)
    testing.expect_value(t,quad_kind(frame.vertices[6].quad),Quad_Kind.Shape)
    stroke:=frame.shapes[quad_data(frame.vertices[6].quad)]
    testing.expect(t,stroke.fill=={} && stroke.stroke==[4]f32{1,1,1,1})
}
