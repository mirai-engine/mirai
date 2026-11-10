package ui

import "core:testing"

Slider_Test :: struct {
    value:f64,
    result:Number_Result,
    disabled:bool,
    field:Number_Field,
}

slider_test_build :: proc(ctx:^Context,user:rawptr) {
    s:=(^Slider_Test)(user)
    if panel(ctx,id(ctx,"panel"),{width=fixed(240),height=FIT,padding=padding_all(8)}) {
        field:=s.field
        if !field.has_min && !field.has_max {field.min,field.max,field.has_min,field.has_max=0,1,true,true}
        field.disabled=s.disabled
        s.result=slider_field(ctx,id(ctx,"value"),&s.value,field)
    }
}

@(test)
slider_drag_and_typed_value_share_limits_and_cancellation :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Slider_Test{value=0.2}
    input:=test_input()
    test_frame(&ctx,&input,slider_test_build,&s)
    track:=id_derive(&ctx,id(&ctx,"value"),"track")
    rect:=test_rect(t,&ctx,track)
    test_point(&input,rect)
    test_frame(&ctx,&input,slider_test_build,&s)
    test_press(&input)
    test_frame(&ctx,&input,slider_test_build,&s)
    testing.expect(t,s.result.began && s.result.changed && s.result.scrubbing)
    testing.expect(t,abs(s.value-0.5)<1e-5)
    input.pointer.x=rect.x+rect.w+60
    test_frame(&ctx,&input,slider_test_build,&s)
    testing.expect_value(t,s.value,1.0)
    test_key(&input,.Escape)
    test_frame(&ctx,&input,slider_test_build,&s)
    testing.expect(t,s.result.ended && s.result.cancelled)
    testing.expect_value(t,s.value,0.2)
    test_release(&input)
    test_frame(&ctx,&input,slider_test_build,&s)
    number:=id_derive(&ctx,id(&ctx,"value"),"number")
    test_click(&ctx,&input,slider_test_build,&s,number)
    testing.expect(t,s.result.editing)
    test_type(&input,"4")
    test_frame(&ctx,&input,slider_test_build,&s)
    test_key(&input,.Enter)
    test_frame(&ctx,&input,slider_test_build,&s)
    testing.expect(t,s.result.changed && s.result.ended)
    testing.expect_value(t,s.value,1.0)
    s.disabled=true
    test_click(&ctx,&input,slider_test_build,&s,track)
    testing.expect_value(t,s.value,1.0)
    testing.expect(t,!s.result.began && !s.result.changed)
    s.disabled=false
    s.value=2
    s.field={min=0,max=8,has_min=true,has_max=true,integer=true,speed=0.05}
    ctx.focus=track
    test_key(&input,.Right)
    test_frame(&ctx,&input,slider_test_build,&s)
    testing.expect_value(t,s.value,3.0)
    testing.expect(t,s.result.began && s.result.ended && s.result.changed)
    s.value=0
    s.field={min=-1e308,max=1e308,has_min=true,has_max=true}
    test_frame(&ctx,&input,slider_test_build,&s)
    _,overflow_track:=widget_rect(&ctx,track)
    _,overflow_number:=widget_rect(&ctx,id(&ctx,"value"))
    testing.expect(t,!overflow_track && overflow_number)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

Dropdown_Search_Test :: struct {selected:int,changes:int,clipped:bool,scroll:[2]f32}

dropdown_search_test_build :: proc(ctx:^Context,user:rawptr) {
    s:=(^Dropdown_Search_Test)(user)
    if panel(ctx,id(ctx,"panel"),{width=fixed(240),height=FIT,padding=padding_all(8)}) {
        if s.clipped {
            if scroll_area(ctx,id(ctx,"scroll"),&s.scroll,{height=fixed(ctx.theme.row)}) {dropdown_search_test_choice(ctx,s)}
        } else {dropdown_search_test_choice(ctx,s)}
    }
}

dropdown_search_test_choice :: proc(ctx:^Context,s:^Dropdown_Search_Test) {
    if dropdown(ctx,id(ctx,"kind"),{"Box","Sphere","Spot light","Directional light"},&s.selected,{width=-1,searchable=true}) {s.changes+=1}
}

@(test)
searchable_dropdown_filters_and_chooses_with_keyboard :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Dropdown_Search_Test{clipped=true}
    input:=test_input()
    test_frame(&ctx,&input,dropdown_search_test_build,&s)
    test_click(&ctx,&input,dropdown_search_test_build,&s,id(&ctx,"kind"))
    list:=id_derive(&ctx,id(&ctx,"kind"),"list")
    search:=id_derive(&ctx,list,"search")
    testing.expect_value(t,ctx.edit.id,search)
    test_type(&input,"SP")
    test_frame(&ctx,&input,dropdown_search_test_build,&s)
    test_frame(&ctx,&input,dropdown_search_test_build,&s)
    _,box:=widget_rect(&ctx,id_derive(&ctx,list,"row",1))
    _,sphere:=widget_rect(&ctx,id_derive(&ctx,list,"row",2))
    _,spot:=widget_rect(&ctx,id_derive(&ctx,list,"row",3))
    testing.expect(t,!box && sphere && spot)
    test_key(&input,.Down)
    test_frame(&ctx,&input,dropdown_search_test_build,&s)
    test_key(&input,.Enter)
    test_frame(&ctx,&input,dropdown_search_test_build,&s)
    testing.expect_value(t,s.selected,1)
    testing.expect_value(t,s.changes,1)
    testing.expect(t,!popup_is_open(&ctx,list) && ctx.edit.id==0)
    test_click(&ctx,&input,dropdown_search_test_build,&s,id(&ctx,"kind"))
    test_click(&ctx,&input,dropdown_search_test_build,&s,id_derive(&ctx,list,"row",3))
    testing.expect_value(t,s.selected,2)
    testing.expect_value(t,s.changes,2)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(test)
a_slider_drags_cancels_and_steps_the_same_with_any_look :: proc(t:^testing.T) {
    Looked :: struct {value:f64,result:Number_Result,look:^Node_Style}
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Looked)user
        if panel(ctx,id(ctx,"panel"),{width=fixed(240),height=FIT,padding=padding_all(8)}) {
            s.result=slider(ctx,id(ctx,"value"),&s.value,{min=0,max=8,step=2,width=fixed(200),look=s.look})
        }
    }
    style:=TEST_CONTROL_STYLE
    for look in ([]^Node_Style{nil,&style}) {
        ctx:Context
        testing.expect(t,context_init(&ctx,TEST_SMALL))
        defer context_destroy(&ctx)
        s:=Looked{value=2,look=look}
        input:=test_input()
        test_frame(&ctx,&input,build,&s)
        value:=id(&ctx,"value")
        rect:=test_rect(t,&ctx,value)
        input.pointer={rect.x+rect.w-1,rect.y+rect.h*0.5}
        test_frame(&ctx,&input,build,&s)
        test_press(&input)
        test_frame(&ctx,&input,build,&s)
        testing.expect(t,s.result.began && s.result.changed && s.result.scrubbing && s.value==8,"The press takes the knob to the pointer")
        input.pointer.x=rect.x+rect.w*0.4
        test_frame(&ctx,&input,build,&s)
        testing.expect_value(t,s.value,4.0)
        test_key(&input,.Escape)
        test_frame(&ctx,&input,build,&s)
        testing.expect(t,s.result.cancelled && s.result.ended && s.value==2,"Escape puts back the value the drag began with")
        test_release(&input)
        test_frame(&ctx,&input,build,&s)
        ctx.focus=value
        test_key(&input,.Right)
        test_frame(&ctx,&input,build,&s)
        testing.expect(t,s.value==4 && s.result.began && s.result.ended,"A key steps it by its step, as one edit")
        test_key(&input,.Left)
        test_frame(&ctx,&input,build,&s)
        test_key(&input,.Left)
        test_frame(&ctx,&input,build,&s)
        test_key(&input,.Left)
        test_frame(&ctx,&input,build,&s)
        testing.expect(t,s.value==0 && !s.result.changed,"It stays in its range")
        paint:^Paint
        for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Slider {paint=&p}}
        if !testing.expect(t,paint!=nil) {continue}
        if look==nil {
            testing.expect(t,paint.fill2==ctx.theme.accent && paint.radius*2==SLIDER_KNOB,"Without a look it is the slider of the theme")
        } else {
            testing.expect(t,paint.fill==look.track && paint.fill2==look.mark && paint.stroke==look.knob && test_near(paint.radius*2,rect.h),"With one, every color is its look's and the knob is as tall as it")
        }
    }
}
