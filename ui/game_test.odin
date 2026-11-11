package ui

import "core:math"
import "core:testing"

// Bounds of the positions of some vertices.
test_bounds :: proc(vertices:[]Vertex) -> Rect {
    lo,hi:=[2]f32{max(f32),max(f32)},[2]f32{min(f32),min(f32)}
    for v in vertices {
        lo={min(lo.x,v.position.x),min(lo.y,v.position.y)};hi={max(hi.x,v.position.x),max(hi.y,v.position.y)}
    }
    return {lo.x,lo.y,hi.x-lo.x,hi.y-lo.y}
}
// Bounds of what some vertices draw. A shape is its rectangle, carried by
// the transform of its quad and cut where its vertices were clipped, without
// the fringe of one pixel the quad adds around it for antialiasing; anything
// else is its vertices.
test_drawn :: proc(frame:Frame,vertices:[]Vertex) -> Rect {
    lo,hi:=[2]f32{max(f32),max(f32)},[2]f32{min(f32),min(f32)}
    for at:=0;at<len(vertices);at+=6 {
        quad:=vertices[at:min(at+6,len(vertices))]
        q_lo,q_hi:=[2]f32{max(f32),max(f32)},[2]f32{min(f32),min(f32)}
        for v in quad {q_lo={min(q_lo.x,v.position.x),min(q_lo.y,v.position.y)};q_hi={max(q_hi.x,v.position.x),max(q_hi.y,v.position.y)}}
        index:=int(quad_data(quad[0].quad))
        if quad_kind(quad[0].quad)==.Shape && len(quad)>=3 && index<len(frame.shapes) {
            // Layout coordinates (uv) to window points, from the first triangle.
            du1,du2:=quad[1].uv-quad[0].uv,quad[2].uv-quad[0].uv
            dp1,dp2:=quad[1].position.xy-quad[0].position.xy,quad[2].position.xy-quad[0].position.xy
            det:=du1.x*du2.y-du1.y*du2.x
            b:=frame.shapes[index].bounds
            s_lo,s_hi:=[2]f32{max(f32),max(f32)},[2]f32{min(f32),min(f32)}
            for corner in ([4][2]f32{{b[0],b[1]},{b[0]+b[2],b[1]},{b[0],b[1]+b[3]},{b[0]+b[2],b[1]+b[3]}}) {
                d:=corner-quad[0].uv
                u,v:=(d.x*du2.y-d.y*du2.x)/det,(du1.x*d.y-du1.y*d.x)/det
                p:=quad[0].position.xy+u*dp1+v*dp2
                s_lo={min(s_lo.x,p.x),min(s_lo.y,p.y)};s_hi={max(s_hi.x,p.x),max(s_hi.y,p.y)}
            }
            q_lo={max(q_lo.x,s_lo.x),max(q_lo.y,s_lo.y)};q_hi={min(q_hi.x,s_hi.x),min(q_hi.y,s_hi.y)}
        }
        lo={min(lo.x,q_lo.x),min(lo.y,q_lo.y)};hi={max(hi.x,q_hi.x),max(hi.y,q_hi.y)}
    }
    return {lo.x,lo.y,hi.x-lo.x,hi.y-lo.y}
}
// The color a vertex paints: that of its shape, for a shape, times its own.
test_color :: proc(frame:Frame,v:Vertex) -> [4]f32 {
    if quad_kind(v.quad)==.Shape && int(quad_data(v.quad))<len(frame.shapes) {return v.color*frame.shapes[quad_data(v.quad)].fill}
    return v.color
}
test_count_quad :: proc(vertices:[]Vertex,kind:Quad_Kind) -> int {
    count:=0
    for v in vertices {if quad_kind(v.quad)==kind {count+=1}}
    return count
}

@(test)
images_show_a_part_of_a_texture_with_a_tint :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input()
    frame:=test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        if box(ctx,{padding=padding_all(10),gap=10}) {
            image(ctx,{quad={.Image,7,{0.25,0.5,0.5,0.25}},tint={255,128,0,128},width=fixed(64),height=fixed(32)})
            image(ctx,{quad={quad_user(1),300,{0,0,1,1}},width=fixed(20),height=fixed(20)})
        }
    })
    testing.expect_value(t,len(frame.vertices),12)
    first:=frame.vertices[:6]
    testing.expect(t,test_rect_near(test_bounds(first),{10,10,64,32}))
    for v in first {
        testing.expect_value(t,v.quad,quad_pack(.Image,7))
        testing.expect(t,test_near(v.color.r,1) && test_near(v.color.g,128.0/255) && test_near(v.color.a,128.0/255))
        testing.expect(t,test_near(v.uv.x,0.25+(v.position.x-10)/64*0.5) && test_near(v.uv.y,0.5+(v.position.y-10)/32*0.25))
    }
    testing.expect_value(t,frame.vertices[6].quad,quad_pack(quad_user(1),300))
    testing.expect_value(t,frame.vertices[6].color,[4]f32{1,1,1,1})
    testing.expect_value(t,len(frame.commands),1)
}

@(test)
a_box_takes_an_image_or_a_nine_slice_as_its_background :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input()
    frame:=test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"window"),width=fixed(200),height=fixed(100),padding=padding_all(16),image={.Image,3,{0,0,1,1}},image_border={16,16,16,16},image_border_uv={0.25,0.25,0.25,0.25},track=true}) {
            image(ctx,{id=id(ctx,"icon"),quad={.Image,4,{0,0,1,1}},width=fixed(32),height=fixed(32)})
        }
    })
    // Nine quads of the frame, then the icon inside its padding.
    testing.expect_value(t,len(frame.vertices),9*6+6)
    testing.expect(t,test_rect_near(test_bounds(frame.vertices[:54]),{0,0,200,100}))
    testing.expect(t,test_rect_near(test_bounds(frame.vertices[:6]),{0,0,16,16}))
    testing.expect(t,test_rect_near(test_bounds(frame.vertices[24:30]),{16,16,168,68}))
    testing.expect(t,test_rect_near(test_bounds(frame.vertices[54:]),{16,16,32,32}))
    testing.expect_value(t,frame.vertices[54].quad,quad_pack(.Image,4))
}

@(test)
a_progress_bar_is_its_shape_cut_at_its_value :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    Bars :: struct {value:f32,images:bool}
    s:=Bars{value=0.25}
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Bars)user
        p:=Progress{id=id(ctx,"health"),value=s.value,width=fixed(200),height=fixed(20),fill={200,40,40,255},track={20,20,20,255}}
        if s.images {
            p.fill={};p.track={}
            p.quad={.Image,5,{0,0,1,1}};p.quad_track={.Image,6,{0,0,1,1}}
            p.border={4,4,4,4};p.border_uv={0.25,0.25,0.25,0.25}
        }
        progress(ctx,p)
    }
    input:=test_input(256,64)
    frame:=test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,len(frame.vertices),12)
    testing.expect(t,test_rect_near(test_drawn(frame,frame.vertices[:6]),{0,0,200,20}))
    testing.expect(t,test_rect_near(test_drawn(frame,frame.vertices[6:]),{0,0,50,20}))
    image:=test_raster(&ctx,frame,256,64,1,{0,0,0,255})
    defer test_image_destroy(&image)
    testing.expect(t,test_color_near(test_pixel(&image,49,10),{200,40,40,255}) && test_color_near(test_pixel(&image,50,10),{20,20,20,255}))
    s.value=0
    frame=test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,len(frame.vertices),6)
    s.value=7
    frame=test_frame(&ctx,&input,build,&s)
    testing.expect(t,test_rect_near(test_drawn(frame,frame.vertices[6:]),{0,0,200,20}),"A value past the end fills the bar and no more")
    // With images: the track whole, the bar cut with its texture coordinates.
    s={value=0.5,images=true}
    frame=test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,test_count_quad(frame.vertices,.Image),len(frame.vertices))
    bar:=frame.vertices[54:]
    testing.expect(t,test_rect_near(test_bounds(bar),{0,0,100,20}))
    for v in bar {
        testing.expect_value(t,v.quad,quad_pack(.Image,5))
        testing.expect_value(t,v.color,[4]f32{1,1,1,1})
        testing.expect(t,v.uv.x<=0.5+0.0001,"The bar shows the left half of its image")
    }
}

Test_Styles :: struct {style:Text_Style,content:string,width,height:Size}
test_styles_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Styles)user
    if box(ctx,{id=id(ctx,"holder"),padding=padding_all(20),track=true}) {
        text(ctx,s.content,s.style,s.width,s.height,id(ctx,"text"))
    }
}

@(test)
styled_text_is_aligned_and_wrapped_inside_its_box :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    white:=Color{255,255,255,255}
    s:=Test_Styles{style={size=16,color=white},content="Score",width=FIT,height=FIT}
    input:=test_input()
    frame:=test_frame(&ctx,&input,test_styles_build,&s)
    width:=text_width(&ctx.font,"Score",16)
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"text")),{20,20,width+1,16*TEXT_LINE}),"A box that fits holds one line")
    testing.expect_value(t,len(frame.vertices),5*6)
    // Aligned in a larger box.
    s.width,s.height=fixed(300),fixed(100)
    frame=test_frame(&ctx,&input,test_styles_build,&s)
    left:=test_bounds(frame.vertices)
    s.style.align_x=.Center;s.style.align_y=.Center
    frame=test_frame(&ctx,&input,test_styles_build,&s)
    centered:=test_bounds(frame.vertices)
    // The transparent padding of the first glyph is cut at the edge of the box: bounds are good to 3 units.
    testing.expect(t,test_near(centered.x-left.x,(300-width)*0.5,3) && test_near(centered.y-left.y,(100-16*TEXT_LINE)*0.5,1))
    s.style.align_x=.End;s.style.align_y=.End
    frame=test_frame(&ctx,&input,test_styles_build,&s)
    right:=test_bounds(frame.vertices)
    testing.expect(t,test_near(right.x+right.w-left.x-left.w,300-width,3) && test_near(right.y-left.y,100-16*TEXT_LINE,1))
    // Wrapped to a fixed width, the box grows by the lines the text takes.
    s={style={size=16,color=white,wrap=.Words},content="The quick brown fox jumps over the lazy dog",width=fixed(120),height=FIT}
    frame=test_frame(&ctx,&input,test_styles_build,&s)
    broken:[8]string
    lines:=test_text_lines(&ctx,id(&ctx,"text"),broken[:])
    testing.expect(t,lines>=3)
    testing.expect(t,test_near(test_rect(t,&ctx,id(&ctx,"text")).h,f32(lines)*16*TEXT_LINE))
    bounds:=test_bounds(frame.vertices)
    testing.expect(t,bounds.x>=18 && bounds.x+bounds.w<=20+120+2 && bounds.h>f32(lines-1)*16*TEXT_LINE,"Every line stays inside the width")
    testing.expect_value(t,len(frame.vertices),(len(s.content)-8)*6)
    // A line height of its own.
    s.style.line_height=2
    test_frame(&ctx,&input,test_styles_build,&s)
    testing.expect(t,test_near(test_rect(t,&ctx,id(&ctx,"text")).h,f32(lines)*32))
}

@(test)
styled_text_takes_outline_shadow_and_ellipsis :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    white:=Color{255,255,255,255}
    s:=Test_Styles{style={size=16,color=white},content="Level",width=fixed(200),height=fixed(40)}
    input:=test_input()
    frame:=test_frame(&ctx,&input,test_styles_build,&s)
    plain:=len(frame.vertices)
    testing.expect_value(t,plain,5*6)
    s.style.shadow={2,3};s.style.shadow_color={0,0,0,200}
    frame=test_frame(&ctx,&input,test_styles_build,&s)
    testing.expect_value(t,len(frame.vertices),plain*2)
    testing.expect_value(t,frame.vertices[0].color.r,f32(0))
    testing.expect(t,test_near(frame.vertices[0].position.x-frame.vertices[plain].position.x,2) && test_near(frame.vertices[0].position.y-frame.vertices[plain].position.y,3),"The shadow lies under the text, moved by its offset")
    s.style.outline=1;s.style.outline_color={255,0,0,255}
    frame=test_frame(&ctx,&input,test_styles_build,&s)
    testing.expect_value(t,len(frame.vertices),plain*10)
    testing.expect_value(t,frame.vertices[len(frame.vertices)-1].color,[4]f32{1,1,1,1})
    testing.expect_value(t,frame.vertices[plain].color,[4]f32{1,0,0,1})
    // Text too long for one line ends in an ellipsis inside the box.
    s={style={size=16,color=white,ellipsis=true},content="An extremely long title that cannot fit",width=fixed(120),height=fixed(20)}
    frame=test_frame(&ctx,&input,test_styles_build,&s)
    bounds:=test_bounds(frame.vertices)
    testing.expect(t,bounds.x+bounds.w<=20+120+1 && len(frame.vertices)<len(s.content)*6)
    last:=frame.vertices[len(frame.vertices)-6:]
    ellipsis:=font_face(&ctx.font,0,16).glyphs[font_index(&ctx.font,0,'…')].uv
    // At whichever phase the pen puts it.
    is_ellipsis :: proc(uv:[2]f32,ellipsis:Rect) -> bool {
        phase:=(uv.x-ellipsis.x)/ellipsis.w
        return test_near(phase,math.round(phase),0.001) && phase>=-0.001 && phase<4 && test_near(uv.y,ellipsis.y,0.0001)
    }
    testing.expect(t,is_ellipsis(last[0].uv,ellipsis),"The last glyph is the ellipsis")
    // Wrapped text that has more lines than the box shows cuts the last one.
    s={style={size=16,color=white,ellipsis=true,wrap=.Words},content="one two three four five six seven eight nine ten",width=fixed(80),height=fixed(40)}
    frame=test_frame(&ctx,&input,test_styles_build,&s)
    last=frame.vertices[len(frame.vertices)-6:]
    testing.expect(t,is_ellipsis(last[0].uv,ellipsis) && test_bounds(frame.vertices).h<=40+4)
}

@(test)
the_scale_turns_layout_units_into_window_points :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    testing.expect_value(t,scale_to_fit({1920,1080},{1280,720}),f32(1.5))
    testing.expect_value(t,scale_to_fit({1920,800},{1280,720}),f32(800.0/720))
    testing.expect_value(t,scale_to_fit({1920,1080},{0,0}),f32(1))
    Scaled :: struct {clicks:int}
    s:Scaled
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Scaled)user
        if anchored(ctx,id(ctx,"corner"),.Bottom_Right,{-10,-10},{direction=.Column}) {
            if button(ctx,id(ctx,"go"),{label="Go",width=100,height=40,variant="accent"}).clicked {s.clicks+=1}
        }
    }
    input:=test_input(1280,720)
    input.scale=2
    input.safe={0,0,40,20}
    frame:=test_frame(&ctx,&input,build,&s)
    // The surface is 640 by 360 units; the safe area ends 20 and 10 units before its edges.
    go:=test_rect(t,&ctx,id(&ctx,"go"))
    testing.expect(t,test_rect_near(go,{640-20-10-100,360-10-10-40,100,40}))
    // The background of the button is one shape; its label follows.
    box_bounds:=test_drawn(frame,frame.vertices[:6])
    testing.expect(t,box_bounds.x>=go.x*2-0.01 && box_bounds.x+box_bounds.w<=(go.x+go.w)*2+0.01 && box_bounds.w>190,"Vertices are in window points")
    testing.expect_value(t,frame.commands[0].scissor,Rect{0,0,1280,720})
    // Glyphs come from the face nearest to their size on screen.
    glyphs:=0
    for v in frame.vertices {if quad_kind(v.quad)==.Glyph {glyphs+=1}}
    testing.expect_value(t,glyphs,12)
    // The pointer arrives in window points.
    input.pointer={(go.x+50)*2,(go.y+20)*2}
    test_frame(&ctx,&input,build,&s)
    test_press(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,s.clicks,1)
    test_release(&input)
    input.pointer={go.x+50,go.y+20}
    test_frame(&ctx,&input,build,&s)
    test_press(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,s.clicks,1)
}

@(test)
a_skinned_button_changes_its_image_with_its_state :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    ctx.release_activates=true
    State :: struct {clicks:int,disabled:bool}
    s:State
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^State)user
        skin:=Skin{
            normal={quad={.Image,1,{0,0,1,1}}},hovered={quad={.Image,2,{0,0,1,1}}},pressed={quad={.Image,3,{0,0,1,1}},text_color={255,255,0,255}},
            disabled={tint={40,40,40,255}},text={size=20,color={255,255,255,255}},width=fixed(160),height=fixed(48),
        }
        start:=id(ctx,"start")
        look,image:=skin_look(ctx,start,skin,s.disabled)
        if button(ctx,start,{label="Start",look=&look,image=image,layout=&Layout{width=skin.width,height=skin.height,padding=skin.padding},block=true,disabled=s.disabled}).clicked {s.clicks+=1}
    }
    input:=test_input()
    frame:=test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,frame.vertices[0].quad,quad_pack(.Image,1))
    testing.expect(t,test_rect_near(test_bounds(frame.vertices[:6]),{0,0,160,48}))
    input.pointer={80,24}
    test_frame(&ctx,&input,build,&s)
    frame=test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,frame.vertices[0].quad,quad_pack(.Image,2))
    test_press(&input)
    frame=test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,frame.vertices[0].quad,quad_pack(.Image,3))
    testing.expect_value(t,test_paint(&ctx,"Start").style.color,Color{255,255,0,255})
    test_release(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,s.clicks,1)
    s.disabled=true
    frame=test_frame(&ctx,&input,build,&s)
    // Without an image of its own the disabled state is its tint, filled as a shape.
    testing.expect_value(t,quad_kind(frame.vertices[0].quad),Quad_Kind.Shape)
    testing.expect_value(t,frame.shapes[quad_data(frame.vertices[0].quad)].fill,[4]f32{40,40,40,255}/255)
    test_press(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,ctx.hot!=id(&ctx,"start"),"Disabled and without a tooltip, the pointer goes through it")
    test_release(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,s.clicks,1)
}

@(private="file")
Canvas_Seen :: struct {rect:Rect,name:u64,calls:int}

@(test)
a_canvas_is_drawn_by_its_owner_inside_the_clip_of_its_container :: proc(t:^testing.T) {
    seen:Canvas_Seen
    draw :: proc(user:rawptr,ctx:^Context,node:Draw_Node) {
        s:=(^Canvas_Seen)(user)
        s.rect,s.name,s.calls=node.rect,node.name,s.calls+1
        draw_rect(ctx,{node.rect.x-50,node.rect.y,node.rect.w+100,node.rect.h},{255,255,255,255}) // wider than the clip
    }
    desc:=TEST_SMALL
    desc.draw_user,desc.draw_user_data=draw,&seen
    ctx:Context
    testing.expect(t,test_context_init(&ctx,desc));defer context_destroy(&ctx)
    input:=test_input()
    Build :: struct {seen:^Canvas_Seen,it:Interaction}
    b:=Build{seen=&seen}
    build :: proc(ctx:^Context,user:rawptr) {
        b:=(^Build)(user)
        if box(ctx,{id=id(ctx,"area"),width=fixed(200),height=fixed(100),clip_x=true,clip_y=true}) {
            b.it=canvas(ctx,id(ctx,"canvas"),GROW,GROW,{name=7})
        }
    }
    test_frame(&ctx,&input,build,&b)
    frame:=test_frame(&ctx,&input,build,&b)
    testing.expect_value(t,seen.name,u64(7))
    testing.expect(t,seen.calls==2 && test_rect_near(seen.rect,{0,0,200,100}),"the owner draws the area the layout gave it")
    clipped:=false
    for command in frame.commands {if command.count>0 && test_rect_near(command.scissor,{0,0,200,100}) {clipped=true}}
    testing.expect(t,clipped,"what it draws is cut to its container")
    // The pointer on it is its interaction.
    test_point(&input,{0,0,200,100})
    test_press(&input)
    test_frame(&ctx,&input,build,&b)
    testing.expect(t,b.it.pressed && b.it.hot)
}
