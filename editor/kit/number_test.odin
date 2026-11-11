package kit

import "core:testing"
import "mirai:ui"

@(test)
numbers_are_shown_in_their_shortest_readable_form :: proc(t:^testing.T) {
    buffer:[48]u8
    testing.expect_value(t,ui.number_format(buffer[:],1),"1")
    testing.expect_value(t,ui.number_format(buffer[:],2.8),"2.8")
    testing.expect_value(t,ui.number_format(buffer[:],0.125),"0.125")
    testing.expect_value(t,ui.number_format(buffer[:],0.12345),"0.123")
    testing.expect_value(t,ui.number_format(buffer[:],0.12345,5),"0.12345")
    testing.expect_value(t,ui.number_format(buffer[:],-0.0001),"0")
    testing.expect_value(t,ui.number_format(buffer[:],-12.50),"-12.5")
    testing.expect_value(t,ui.number_format(buffer[:],100),"100")
    testing.expect_value(t,ui.number_format(buffer[:],45.26,1),"45.3")
    testing.expect_value(t,ui.number_format(buffer[:],3.7,0),"4")
    testing.expect_value(t,ui.number_format(buffer[:],1e9),"1000000000")
}

Test_Numbers :: struct {
    value:f64,
    vector:[3]f64,
    count:f64,
    field:ui.Number_Field,
    result,vector_result,count_result:ui.Number_Result,
    axis:int,
    began,ended,changed:int,
}
test_numbers_build :: proc(ctx:^ui.Context,user:rawptr) {
    s:=cast(^Test_Numbers)user
    if ui.panel(ctx,ui.id(ctx,"panel"),{width=ui.fixed(300),height=ui.FIT,gap=4}) {
        s.result=ui.number_field(ctx,ui.id(ctx,"value"),&s.value,s.field)
        if property(ctx,"Position") {s.vector_result,s.axis=vector_field(ctx,ui.id(ctx,"vector"),s.vector[:],{number={speed=0.02}})}
        s.count_result=ui.number_field(ctx,ui.id(ctx,"count"),&s.count,{integer=true,speed=0.1,min=0,max=8,has_min=true,has_max=true})
    }
    if s.result.began {s.began+=1}
    if s.result.ended {s.ended+=1}
    if s.result.changed {s.changed+=1}
}
test_numbers_frame :: proc(ctx:^ui.Context,input:^ui.Input,s:^Test_Numbers) {test_frame(ctx,input,test_numbers_build,s)}

@(test)
a_click_on_a_number_types_it_and_enter_applies_it :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    s:=Test_Numbers{value=1.23456789}
    input:=test_input()
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,test_paint(&ctx,"1.235")!=nil,"Three decimals are shown")
    rect:=test_rect(t,&ctx,ui.id(&ctx,"value"))
    test_point(&input,rect)
    test_numbers_frame(&ctx,&input,&s)
    test_press(&input)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,!s.result.editing && !s.result.scrubbing && s.began==0,"The press waits to see whether it is a drag")
    held:^ui.Paint
    for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Field && p.text=="1.235" {held=&p}}
    testing.expect(t,held!=nil && held.fill==ui.tone(&ctx,"field_active"))
    test_release(&input)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,s.result.editing && s.result.began && s.began==1)
    testing.expect_value(t,ui.text_edit_value(&ctx.edit),"1.23457")
    lo,hi:=ui.text_edit_selection(&ctx.edit)
    testing.expect(t,lo==0 && hi==7,"The value is typed over")
    test_type(&input,"2.5e1 x")
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,ui.text_edit_value(&ctx.edit),"2.5e1")
    testing.expect_value(t,s.value,1.23456789)
    test_key(&input,.Enter)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,s.result.changed && s.result.ended && !s.result.editing && !s.result.invalid)
    testing.expect_value(t,s.value,25.0)
    testing.expect(t,s.ended==1 && s.changed==1)
}

@(test)
a_number_shows_that_it_drags_and_a_double_click_places_the_caret :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_FONT))
    defer ui.context_destroy(&ctx)
    s:=Test_Numbers{value=1234.5}
    input:=test_input()
    test_numbers_frame(&ctx,&input,&s)
    rect:=test_rect(t,&ctx,ui.id(&ctx,"value"))
    test_point(&input,rect)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,ctx.cursor,ui.Cursor.Resize_Horizontal)
    // One click: all of it, over the fill of the field and inside its accent border.
    test_press(&input);test_numbers_frame(&ctx,&input,&s)
    test_release(&input);test_numbers_frame(&ctx,&input,&s)
    lo,hi:=ui.text_edit_selection(&ctx.edit)
    testing.expect(t,s.result.editing && lo==0 && hi==6)
    field:=test_paint(&ctx,"1234.5")
    testing.expect(t,field!=nil && field.fill==ui.tone(&ctx,"well") && field.stroke==ui.tone(&ctx,"accent"))
    testing.expect_value(t,ctx.cursor,ui.Cursor.Text)
    // The second click of a double click puts the caret where it lands, between 2 and 3.
    x,_:=ui.field_text_span(&ctx,rect,"")
    input.pointer={x+ui.text_width(&ctx.font,"12",ui.metric(&ctx,"font_small"))+1,rect.y+rect.h*0.5}
    test_numbers_frame(&ctx,&input,&s)
    test_press(&input,2);test_numbers_frame(&ctx,&input,&s)
    test_release(&input);test_numbers_frame(&ctx,&input,&s)
    lo,hi=ui.text_edit_selection(&ctx.edit)
    testing.expect(t,s.result.editing && lo==2 && hi==2)
    // A drag over the typed number selects a part of it.
    test_press(&input);test_numbers_frame(&ctx,&input,&s)
    input.pointer.x=x+ui.text_width(&ctx.font,"1234",ui.metric(&ctx,"font_small"))+1
    test_numbers_frame(&ctx,&input,&s)
    test_release(&input);test_numbers_frame(&ctx,&input,&s)
    lo,hi=ui.text_edit_selection(&ctx.edit)
    testing.expect(t,s.result.editing && lo==2 && hi==4,"34 is selected")
    test_type(&input,"9")
    test_numbers_frame(&ctx,&input,&s)
    test_key(&input,.Enter)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,s.value,129.5)
}

@(test)
text_that_is_not_a_number_keeps_the_value_and_escape_discards :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    s:=Test_Numbers{value=4}
    input:=test_input()
    edit :: proc(ctx:^ui.Context,input:^ui.Input,s:^Test_Numbers,text:string,key:ui.Key) {
        rect,_:=ui.widget_rect(ctx,ui.id(ctx,"value"))
        test_point(input,rect)
        test_numbers_frame(ctx,input,s)
        test_press(input);test_release(input)
        test_numbers_frame(ctx,input,s)
        test_type(input,text)
        test_numbers_frame(ctx,input,s)
        test_key(input,key)
        test_numbers_frame(ctx,input,s)
    }
    test_numbers_frame(&ctx,&input,&s)
    edit(&ctx,&input,&s,"1.2.3",.Enter)
    testing.expect(t,s.result.invalid && s.result.ended && !s.result.changed)
    testing.expect_value(t,s.value,4.0)
    edit(&ctx,&input,&s,"--",.Enter)
    testing.expect(t,s.result.invalid)
    edit(&ctx,&input,&s,"9",.Escape)
    testing.expect(t,s.result.cancelled && s.result.ended && !s.result.changed && !s.result.invalid)
    testing.expect(t,ctx.escape_used)
    testing.expect_value(t,s.value,4.0)
    // An untouched or emptied field is not an error.
    edit(&ctx,&input,&s,"",.Enter)
    testing.expect(t,!s.result.invalid && !s.result.changed && s.result.ended)
    rect,_:=ui.widget_rect(&ctx,ui.id(&ctx,"value"))
    test_point(&input,rect)
    test_numbers_frame(&ctx,&input,&s)
    test_press(&input);test_release(&input)
    test_numbers_frame(&ctx,&input,&s)
    test_key(&input,.Backspace)
    test_numbers_frame(&ctx,&input,&s)
    test_key(&input,.Enter)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,!s.result.invalid && !s.result.changed)
    testing.expect_value(t,s.value,4.0)
    // Limits apply to what is typed.
    s.field={min=0,max=10,has_min=true,has_max=true}
    edit(&ctx,&input,&s,"250",.Enter)
    testing.expect_value(t,s.value,10.0)
    edit(&ctx,&input,&s,"-3",.Enter)
    testing.expect_value(t,s.value,0.0)
}

@(test)
dragging_a_number_scrubs_it_from_the_value_it_began_with :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    s:=Test_Numbers{value=5,field={speed=0.5}}
    input:=test_input()
    test_numbers_frame(&ctx,&input,&s)
    rect:=test_rect(t,&ctx,ui.id(&ctx,"value"))
    start:=[2]f32{rect.x+100,rect.y+10}
    input.pointer=start
    test_numbers_frame(&ctx,&input,&s)
    test_press(&input)
    test_numbers_frame(&ctx,&input,&s)
    // Inside the tolerance of a click nothing moves.
    input.pointer=start+{3,0}
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,!s.result.scrubbing && s.value==5 && s.began==0)
    input.pointer=start+{10,40}
    frame:=test_frame(&ctx,&input,test_numbers_build,&s)
    testing.expect(t,s.result.scrubbing && s.result.began && s.result.changed && frame.pointer_consumed)
    testing.expect_value(t,s.value,10.0)
    // The pointer may leave the field; every step starts from the first value.
    input.pointer=start+{-600,300}
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,s.value,-295.0)
    testing.expect(t,s.result.scrubbing && !s.result.began)
    // Shift makes the whole drag ten times finer.
    input.pointer=start+{20,0};input.modifiers={.Shift}
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,s.value,6.0)
    input.modifiers={}
    input.pointer=start+{20,0}
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,s.value,15.0)
    testing.expect(t,!s.result.changed || s.changed>0)
    test_release(&input)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,s.result.ended && !s.result.editing && !s.result.scrubbing,"A drag does not start typing")
    testing.expect(t,s.began==1 && s.ended==1)
    testing.expect_value(t,s.value,15.0)
    testing.expect_value(t,ctx.edit.id,ui.Id(0))
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,test_paint(&ctx,"15")!=nil)
}

@(test)
escape_gives_a_scrubbed_number_its_value_back :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    s:=Test_Numbers{value=5,field={speed=1}}
    input:=test_input()
    test_numbers_frame(&ctx,&input,&s)
    rect:=test_rect(t,&ctx,ui.id(&ctx,"value"))
    test_point(&input,rect)
    test_numbers_frame(&ctx,&input,&s)
    test_press(&input)
    test_numbers_frame(&ctx,&input,&s)
    input.pointer.x+=50
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,s.value,55.0)
    test_key(&input,.Escape)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,s.result.cancelled && s.result.ended && s.result.changed)
    testing.expect(t,ctx.escape_used)
    testing.expect_value(t,s.value,5.0)
    // The button is still down: the drag is over all the same.
    input.pointer.x+=50
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,s.value,5.0)
    test_release(&input)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,!s.result.editing && ctx.edit.id==0)
}

@(test)
whole_numbers_and_limits_hold_while_scrubbing :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    s:=Test_Numbers{count=3}
    input:=test_input()
    test_numbers_frame(&ctx,&input,&s)
    rect:=test_rect(t,&ctx,ui.id(&ctx,"count"))
    test_point(&input,rect)
    test_numbers_frame(&ctx,&input,&s)
    test_press(&input)
    test_numbers_frame(&ctx,&input,&s)
    input.pointer.x+=14
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,s.count,4.0)
    input.pointer.x+=500
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,s.count,8.0)
    input.pointer.x-=5000
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,s.count,0.0)
    test_release(&input)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,s.count_result.ended)
    // Typed, it has no decimals to start from.
    test_press(&input);test_release(&input)
    input.pointer=ui.rect_center(rect)
    test_numbers_frame(&ctx,&input,&s)
    test_numbers_frame(&ctx,&input,&s)
    test_press(&input);test_release(&input)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,ui.text_edit_value(&ctx.edit),"0")
    test_type(&input,"2.6")
    test_numbers_frame(&ctx,&input,&s)
    test_key(&input,.Enter)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,s.count,3.0)
}

@(test)
a_vector_is_a_row_of_fields_and_tab_moves_along_its_axes :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    s:=Test_Numbers{vector={1,2,3}}
    input:=test_input()
    test_numbers_frame(&ctx,&input,&s)
    previous:ui.Rect
    for axis in 0..<3 {
        rect:=test_rect(t,&ctx,ui.id_derive(&ctx,ui.id(&ctx,"vector"),"axis",axis+1))
        // 300 less the label column and three gaps, in three equal fields,
        // under the row of the number before it: on whole pixels the fields
        // differ by a pixel at most and the gaps stay whole.
        w:=(300-ui.metric(&ctx,"label_width")-3*4)/3
        testing.expectf(t,test_rect_snapped(rect,{ui.metric(&ctx,"label_width")+4+f32(axis)*(w+4),ui.metric(&ctx,"row")+4,w,ui.metric(&ctx,"row")}),"axis %d: %v",axis,rect)
        if axis>0 {testing.expectf(t,rect.x-(previous.x+previous.w)==4 && abs(rect.w-previous.w)<=1,"axis %d: %v after %v",axis,rect,previous)}
        previous=rect
        paint:^ui.Paint
        for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Field && p.strip==ui.tone(&ctx,AXIS_TOKENS[axis]) {paint=&p}}
        testing.expect(t,paint!=nil && paint.label=="","Each axis has its color and no letter")
    }
    x:=test_rect(t,&ctx,ui.id_derive(&ctx,ui.id(&ctx,"vector"),"axis",1))
    test_point(&input,x)
    test_numbers_frame(&ctx,&input,&s)
    test_press(&input);test_release(&input)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,s.vector_result.editing && s.vector_result.began && s.axis==0)
    test_type(&input,"7")
    test_numbers_frame(&ctx,&input,&s)
    test_key(&input,.Tab)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,s.vector,[3]f64{7,2,3})
    testing.expect_value(t,ctx.edit.id,ui.id_derive(&ctx,ui.id(&ctx,"vector"),"axis",2))
    testing.expect_value(t,ui.text_edit_value(&ctx.edit),"2")
    test_type(&input,"8")
    test_numbers_frame(&ctx,&input,&s)
    test_key(&input,.Tab)
    test_numbers_frame(&ctx,&input,&s)
    test_type(&input,"9")
    test_numbers_frame(&ctx,&input,&s)
    // After the last axis Tab only applies.
    test_key(&input,.Tab)
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,s.vector,[3]f64{7,8,9})
    test_numbers_frame(&ctx,&input,&s)
    testing.expect_value(t,ctx.edit.id,ui.Id(0))
    // Scrubbing one axis leaves the others alone.
    z:=test_rect(t,&ctx,ui.id_derive(&ctx,ui.id(&ctx,"vector"),"axis",3))
    test_point(&input,z)
    test_numbers_frame(&ctx,&input,&s)
    test_press(&input)
    test_numbers_frame(&ctx,&input,&s)
    input.pointer.x+=50
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,s.vector_result.scrubbing && s.axis==2)
    testing.expect_value(t,s.vector,[3]f64{7,8,10})
}

@(test)
mixed_values_show_as_multiple :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    s:=Test_Numbers{value=5,field={mixed=true}}
    input:=test_input()
    test_numbers_frame(&ctx,&input,&s)
    testing.expect(t,test_paint(&ctx,"Multiple")!=nil && test_paint(&ctx,"5")==nil)
}

@(test)
a_color_is_a_swatch_and_its_channels :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    State :: struct {rgb:[3]f32,result:ui.Number_Result,swatch:ui.Interaction}
    s:=State{rgb={0.08,0.65,0.5}}
    build :: proc(ctx:^ui.Context,user:rawptr) {
        s:=cast(^State)user
        if ui.panel(ctx,ui.id(ctx,"panel"),{width=ui.fixed(300),height=ui.FIT}) {
            if property(ctx,"Color") {s.result,s.swatch=color_field(ctx,ui.id(ctx,"color"),&s.rgb)}
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build,&s)
    swatch:=test_rect(t,&ctx,ui.id_derive(&ctx,ui.id(&ctx,"color"),"swatch"))
    testing.expect(t,test_rect_near(swatch,{ui.metric(&ctx,"label_width")+4,0,ui.metric(&ctx,"row"),ui.metric(&ctx,"row")}))
    for i in 0..<3 {
        found:=false
        for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Field && p.label=="" && p.strip==ui.tone(&ctx,CHANNEL_TOKENS[i]) {found=true}}
        testing.expect(t,found,"Each channel has its color and no letter")
    }
    testing.expect(t,test_paint(&ctx,"0.65")!=nil)
    // Scrubbing a channel edits the color inside its range.
    green:=test_rect(t,&ctx,ui.id_derive(&ctx,ui.id_derive(&ctx,ui.id(&ctx,"color"),"channels"),"axis",2))
    test_point(&input,green)
    test_frame(&ctx,&input,build,&s)
    test_press(&input)
    test_frame(&ctx,&input,build,&s)
    input.pointer.x+=50
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,s.result.changed && test_near(s.rgb.g,0.85,0.001) && test_near(s.rgb.r,0.08))
    input.pointer.x+=500
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,s.rgb.g,f32(1))
    test_release(&input)
    test_frame(&ctx,&input,build,&s)
    test_point(&input,swatch)
    test_frame(&ctx,&input,build,&s)
    test_press(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,s.swatch.clicked,"The swatch reports the click that opens a picker")
}
