package ui

import "core:testing"

Test_Controls :: struct {
    style:Node_Style,
    volume,count:f64,
    on,radio:bool,
    radio_clicks:int,
    choice,picked:int,
    name:[16]u8,
    name_length:int,
    secret:[16]u8,
    secret_length:int,
}
TEST_CONTROL_OPTIONS :: "Low|Medium|High"
test_controls_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Controls)user
    c:=Game_Control{style=&s.style}
    if box(ctx,{direction=.Column,gap=4,padding=padding_all(8)}) {
        slider(ctx,id(ctx,"volume"),&s.volume,{min=0,max=1,step=0.25,look=&s.style})
        checkbox(ctx,id(ctx,"on"),&s.on,look=&s.style)
        if game_radio(ctx,id(ctx,"radio"),s.radio,c) {s.radio_clicks+=1}
        game_selector(ctx,id(ctx,"quality"),{joined=TEST_CONTROL_OPTIONS},&s.choice,c)
        number_field(ctx,id(ctx,"count"),&s.count,{min=0,max=10,has_min=true,has_max=true,step=2,stepper=true,look=&s.style})
        game_field(ctx,id(ctx,"name"),s.name[:],&s.name_length,{control=c,placeholder="Name",limit=4})
        game_field(ctx,id(ctx,"secret"),s.secret[:],&s.secret_length,{control=c,password=true})
        dropdown(ctx,id(ctx,"pick"),{joined=TEST_CONTROL_OPTIONS},&s.picked,{look=&s.style})
    }
}
TEST_CONTROL_STYLE :: Node_Style{
    fill={10,20,30,255},stroke={40,50,60,255},track={70,80,90,255},knob={100,110,120,255},mark={130,140,150,255},
    radius={1,2,3,4},stroke_width=2,text={size=10,color={200,200,200,255}},
}

@(test)
game_controls_take_every_color_corner_and_size_from_their_style :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    s:=Test_Controls{style=TEST_CONTROL_STYLE,volume=0.5}
    input:=test_input()
    test_frame(&ctx,&input,test_controls_build,&s)
    test_frame(&ctx,&input,test_controls_build,&s)
    style:=&s.style
    slider,check,field:^Paint
    arrows:=0
    for &p in ctx.paints[:ctx.paint_count] {
        #partial switch p.kind {
        case .Slider:slider=&p
        case .Box:if p.icon_color==style.mark {check=&p}
        case .Field:if p.placeholder=="Name" {field=&p}
        case .Arrow:if p.fill==style.mark {arrows+=1}
        }
    }
    testing.expect(t,slider!=nil && slider.fill==style.track && slider.fill2==style.mark && slider.stroke==style.knob && slider.corners==style.radius && slider.value==0.5)
    testing.expect(t,check!=nil && check.fill==style.fill && check.stroke==style.stroke && check.corners==style.radius && check.stroke_width==2)
    testing.expect(t,field!=nil && field.fill==style.fill && field.corners==style.radius && field.text_color==style.text.color && field.placeholder=="Name")
    testing.expect_value(t,arrows,5) // two of the selector, two of the number and the one of the dropdown
    // Without a size, a control is a line of its text and its room tall, ten of its sizes wide; a checkbox is a line square.
    line:=10*TEXT_LINE
    testing.expect(t,test_rect_snapped(test_rect(t,&ctx,id(&ctx,"volume")),{8,8,100,line+10}))
    on:=test_rect(t,&ctx,id(&ctx,"on"))
    testing.expect(t,test_near(on.w,line,2*PIXEL_EDGE) && test_near(on.h,line,2*PIXEL_EDGE))
    testing.expect(t,test_near(slider.radius,(line+10)*0.5,PIXEL_EDGE),"The knob is as tall as the slider")
    // A password shows a mark for each character, and the theme gives nothing.
    copy(s.secret[:],"abc");s.secret_length=3
    test_frame(&ctx,&input,test_controls_build,&s)
    testing.expect(t,test_paint(&ctx,"***")!=nil)
    for &p in ctx.paints[:ctx.paint_count] {
        testing.expect(t,p.fill!=tone(&ctx,"accent") && p.fill!=tone(&ctx,"well"),"No control takes a color of the theme")
    }
}

@(test)
game_controls_step_type_and_choose_by_pointer_and_keys :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_FONT
    desc.navigation=true
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    ctx.release_activates=true
    s:=Test_Controls{style=TEST_CONTROL_STYLE}
    input:=test_input()
    build:=test_controls_build
    test_frame(&ctx,&input,build,&s)
    // The arrows of a selector step its options, and wrap.
    quality:=id(&ctx,"quality")
    test_click(&ctx,&input,build,&s,id_derive(&ctx,quality,"next"))
    testing.expect_value(t,s.choice,1)
    test_click(&ctx,&input,build,&s,id_derive(&ctx,quality,"previous"))
    test_click(&ctx,&input,build,&s,id_derive(&ctx,quality,"previous"))
    testing.expect_value(t,s.choice,2)
    // A number steps by its step with its arrows and the keys, inside its range.
    count:=id(&ctx,"count")
    test_click(&ctx,&input,build,&s,id_derive(&ctx,count,"next"))
    testing.expect_value(t,s.count,2.0)
    ctx.focus,ctx.focus_ring=count,true
    test_key(&input,.Left)
    test_frame(&ctx,&input,build,&s)
    test_key(&input,.Left)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,s.count,0.0)
    testing.expect_value(t,ctx.focus,count)
    // A click on its text types it: what is typed snaps to the step and stays in the range.
    test_click(&ctx,&input,build,&s,count)
    testing.expect_value(t,ctx.edit.id,count)
    test_type(&input,"7")
    test_frame(&ctx,&input,build,&s)
    test_key(&input,.Enter)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,s.count,8.0)
    test_click(&ctx,&input,build,&s,count)
    test_type(&input,"99")
    test_frame(&ctx,&input,build,&s)
    test_key(&input,.Enter)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,s.count,10.0)
    // A field takes as many bytes as its limit; its first click places the caret, without selecting.
    name:=id(&ctx,"name")
    test_click(&ctx,&input,build,&s,name)
    test_type(&input,"abcdef")
    test_frame(&ctx,&input,build,&s)
    test_key(&input,.Enter)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,string(s.name[:s.name_length]),"abcd")
    test_click(&ctx,&input,build,&s,name)
    lo,hi:=text_edit_selection(&ctx.edit)
    testing.expect(t,lo==hi && ctx.edit.cursor==4,"The click places the caret at the end of the text, past which it lands")
    test_key(&input,.Escape)
    test_frame(&ctx,&input,build,&s)
    // A checkbox flips, a radio reports its click.
    test_click(&ctx,&input,build,&s,id(&ctx,"on"))
    test_click(&ctx,&input,build,&s,id(&ctx,"radio"))
    testing.expect(t,s.on && s.radio_clicks==1)
    // A dropdown opens its list under it, and a row chooses.
    pick:=id(&ctx,"pick")
    list:=id_derive(&ctx,pick,"list")
    test_click(&ctx,&input,build,&s,pick)
    testing.expect(t,popup_is_open(&ctx,list))
    test_frame(&ctx,&input,build,&s)
    third:=id_derive(&ctx,list,"row",3)
    row:=test_rect(t,&ctx,third)
    testing.expect(t,row.y>test_rect(t,&ctx,pick).y,"The list opens under the dropdown")
    test_click(&ctx,&input,build,&s,third)
    testing.expect_value(t,s.picked,2)
    testing.expect(t,!popup_is_open(&ctx,list))
    // Opened by the keys, the current row is the chosen one; the keys move it and Enter takes it.
    ctx.focus,ctx.focus_ring=pick,true
    test_key(&input,.Enter)
    test_frame(&ctx,&input,build,&s)
    test_frame(&ctx,&input,build,&s)
    test_key(&input,.Up)
    test_frame(&ctx,&input,build,&s)
    test_key(&input,.Enter)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,s.picked,1)
}

@(test)
images_fit_their_rectangle_and_show_a_frame_of_their_sheet :: proc(t:^testing.T) {
    r:=Rect{0,0,100,50}
    uv:=Rect{0,0,1,1}
    place,part:=image_fit(r,uv,{20,20},.Contain)
    testing.expect(t,test_rect_near(place,{25,0,50,50}) && part==uv)
    place,part=image_fit(r,uv,{20,20},.Cover)
    testing.expect(t,test_rect_near(place,r) && test_rect_near(part,{0,0.25,1,0.5}))
    place,part=image_fit(r,uv,{20,10},.Center)
    testing.expect(t,test_rect_near(place,{40,20,20,10}))
    place,_=image_fit(r,uv,{20,20},.Stretch)
    testing.expect(t,place==r)
    sheet:=Node_Image{quad={.Image,1,{0,0,1,1}},frames={4,2},size={64,32}}
    frame:=image_frame(sheet,5)
    testing.expect(t,test_rect_near(frame.quad.uv,{0.25,0.5,0.25,0.5}) && frame.size==[2]f32{16,16})
    testing.expect(t,image_frame(sheet,13).quad.uv==frame.quad.uv,"Frames wrap")
    testing.expect(t,image_frame({quad={.Image,1,{0,0,1,1}}},3).quad.uv==Rect{0,0,1,1},"An image without frames is itself")
}
