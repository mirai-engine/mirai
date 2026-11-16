package kit

import "core:testing"
import "mirai:ui"

Test_Picker :: struct {picker:Color_Picker,picker_result:Color_Picker_Result}

@(test)
the_color_picker_keeps_its_square_its_bar_its_code_and_its_channels_on_one_color :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    s:Test_Picker
    color_picker_set(&s.picker,{1,0,0})
    build :: proc(ctx:^ui.Context,user:rawptr) {
        s:=cast(^Test_Picker)user
        if ui.panel(ctx,ui.id(ctx,"picker"),{width=ui.fixed(236),height=ui.FIT,padding=ui.padding_all(10),gap=8,popup=true}) {
            s.picker_result=color_picker(ctx,ui.id(ctx,"color"),&s.picker)
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build,&s)
    picker:=ui.id(&ctx,"color")
    sv:=test_rect(t,&ctx,ui.id_derive(&ctx,picker,"sv"))
    hue:=test_rect(t,&ctx,ui.id_derive(&ctx,picker,"hue"))
    testing.expect(t,test_rect_near(sv,{10,10,216,150}) && test_rect_near(hue,{10,168,216,14}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,ui.id(&ctx,"picker")),{0,0,236,10+150+8+14+8+ui.metric(&ctx,"row")+8+ui.metric(&ctx,"row")+10}))
    testing.expect(t,test_paint(&ctx,"#FF0000")!=nil && test_paint(&ctx,"255")!=nil)
    // Dragging in the square sets saturation and value; the pointer may leave it.
    input.pointer={sv.x+sv.w*0.5,sv.y+sv.h*0.25}
    test_frame(&ctx,&input,build,&s)
    test_press(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,s.picker_result.began && s.picker_result.changed)
    testing.expect(t,test_near(s.picker.hsv[1],0.5) && test_near(s.picker.hsv[2],0.75))
    input.pointer={sv.x+sv.w+500,sv.y-100}
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,s.picker.hsv,[3]f32{0,1,1})
    test_release(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,s.picker_result.ended)
    // The bar sets the hue.
    input.pointer={hue.x+hue.w/3,hue.y+5}
    test_frame(&ctx,&input,build,&s)
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,test_near(s.picker.hsv[0],1.0/3,0.001))
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,test_paint(&ctx,"#00FF00")!=nil)
    // Typing a channel keeps the other two.
    red:=ui.id_derive(&ctx,ui.id_derive(&ctx,picker,"channels"),"axis",1)
    test_click(&ctx,&input,build,&s,red)
    testing.expect_value(t,ctx.edit.id,red)
    test_type(&input,"128")
    test_frame(&ctx,&input,build,&s)
    test_key(&input,.Enter)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,ui.rgb_color(color_picker_rgb(&s.picker)),ui.Color{128,255,0,255})
    // The code sets them all; a text that is not a code changes nothing.
    hex:=ui.id_derive(&ctx,picker,"hex")
    test_click(&ctx,&input,build,&s,hex)
    test_type(&input,"#102030")
    test_frame(&ctx,&input,build,&s)
    test_key(&input,.Enter)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,ui.rgb_color(color_picker_rgb(&s.picker)),ui.Color{16,32,48,255})
    test_click(&ctx,&input,build,&s,hex)
    test_type(&input,"#12")
    test_frame(&ctx,&input,build,&s)
    test_key(&input,.Enter)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,ui.rgb_color(color_picker_rgb(&s.picker)),ui.Color{16,32,48,255})
    rgb,ok:=ui.hex_color("a0B1c2")
    testing.expect(t,ok && rgb==[3]u8{0xa0,0xb1,0xc2})
    _,ok=ui.hex_color("#12345g")
    testing.expect(t,!ok)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}
