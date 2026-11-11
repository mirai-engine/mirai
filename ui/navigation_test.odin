package ui

import "core:testing"

Test_Navigation :: struct {
    clicks:[6]int,
    name:[16]u8,name_length:int,
    value:f64,
    modal:bool,
    modal_clicks:[2]int,
    checked:bool,
}
// Two rows of three buttons, 100 by 30 each with 10 between them, over a
// text field, a number and a checkbox.
test_navigation_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Navigation)user
    if panel(ctx,id(ctx,"panel"),{width=fixed(340),height=FIT,padding=padding_all(10),gap=10}) {
        for line in 0..<2 {
            if box(ctx,{width=GROW,height=fixed(30),gap=10}) {
                for column in 0..<3 {
                    index:=line*3+column
                    if button(ctx,id(ctx,"button",index+1),{label="Button",width=100,height=30,disabled=index==4}).clicked {s.clicks[index]+=1}
                }
            }
        }
        text_field(ctx,id(ctx,"name"),s.name[:],&s.name_length)
        number_field(ctx,id(ctx,"value"),&s.value)
        checkbox(ctx,id(ctx,"check"),&s.checked)
    }
    if s.modal {
        if modal(ctx,id(ctx,"modal"),{width=300}) {
            if box(ctx,{width=GROW,height=fixed(30),gap=8}) {
                if button(ctx,id(ctx,"no"),{label="No",height=30}).clicked {s.modal_clicks[0]+=1}
                if button(ctx,id(ctx,"yes"),{label="Yes",height=30}).clicked {s.modal_clicks[1]+=1}
            }
        }
    }
}
test_navigation_init :: proc(t:^testing.T,ctx:^Context,s:^Test_Navigation,input:^Input) {
    desc:=TEST_SMALL
    desc.navigation=true
    testing.expect(t,test_context_init(ctx,desc))
    test_tone_set(ctx,"focus",{255,255,255,255})
    input^=test_input()
    input.pointer_absent=true
    test_frame(ctx,input,test_navigation_build,s)
}
test_navigation_key :: proc(ctx:^Context,input:^Input,s:^Test_Navigation,key:Key,modifiers:Modifiers={}) -> Frame {
    test_key(input,key);input.modifiers=modifiers
    frame:=test_frame(ctx,input,test_navigation_build,s)
    input.modifiers={}
    return frame
}
test_navigation_pad :: proc(ctx:^Context,input:^Input,s:^Test_Navigation,pad:Pad) {
    input.pad={pad}
    test_frame(ctx,input,test_navigation_build,s)
}

@(test)
tab_walks_the_focusable_widgets_in_the_order_they_are_built :: proc(t:^testing.T) {
    ctx:Context;s:Test_Navigation;input:Input
    test_navigation_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    testing.expect_value(t,ctx.focus,Id(0))
    frame:=test_navigation_key(&ctx,&input,&s,.Tab)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",1))
    testing.expect(t,frame.keyboard_consumed && !frame.pointer_consumed)
    test_navigation_key(&ctx,&input,&s,.Tab)
    test_navigation_key(&ctx,&input,&s,.Tab)
    test_navigation_key(&ctx,&input,&s,.Tab)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",4))
    test_navigation_key(&ctx,&input,&s,.Tab)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",6))
    test_navigation_key(&ctx,&input,&s,.Tab,{.Shift})
    testing.expect_value(t,ctx.focus,id(&ctx,"button",4))
    for _ in 0..<3 {test_navigation_key(&ctx,&input,&s,.Tab,{.Shift})}
    testing.expect_value(t,ctx.focus,id(&ctx,"button",1))
    test_navigation_key(&ctx,&input,&s,.Tab,{.Shift})
    testing.expect_value(t,ctx.focus,id(&ctx,"check"))
    test_navigation_key(&ctx,&input,&s,.Tab)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",1))
    // The gamepad has the same two steps.
    test_navigation_pad(&ctx,&input,&s,.Next)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",2))
    test_navigation_pad(&ctx,&input,&s,.Previous)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",1))
}

@(test)
arrows_and_the_gamepad_move_the_focus_to_the_nearest_widget_that_way :: proc(t:^testing.T) {
    ctx:Context;s:Test_Navigation;input:Input
    test_navigation_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    test_navigation_key(&ctx,&input,&s,.Right)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",1))
    test_navigation_key(&ctx,&input,&s,.Right)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",2))
    test_navigation_key(&ctx,&input,&s,.Down)
    testing.expect(t,ctx.focus!=id(&ctx,"button",5),"A disabled widget is never focused")
    ctx.focus=id(&ctx,"button",3)
    test_navigation_key(&ctx,&input,&s,.Down)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",6))
    test_navigation_key(&ctx,&input,&s,.Left)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",4))
    test_navigation_key(&ctx,&input,&s,.Left)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",4))
    test_navigation_key(&ctx,&input,&s,.Up)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",1))
    test_navigation_pad(&ctx,&input,&s,.Down)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",4))
    test_navigation_pad(&ctx,&input,&s,.Down)
    testing.expect_value(t,ctx.focus,id(&ctx,"name"))
    test_navigation_pad(&ctx,&input,&s,.Down)
    testing.expect_value(t,ctx.focus,id(&ctx,"value"))
}

@(test)
enter_and_the_gamepad_activate_the_focused_widget :: proc(t:^testing.T) {
    ctx:Context;s:Test_Navigation;input:Input
    test_navigation_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    test_navigation_key(&ctx,&input,&s,.Tab)
    test_navigation_key(&ctx,&input,&s,.Tab)
    test_navigation_key(&ctx,&input,&s,.Enter)
    testing.expect_value(t,s.clicks,[6]int{0,1,0,0,0,0})
    test_navigation_key(&ctx,&input,&s,.Space)
    testing.expect_value(t,s.clicks[1],2)
    test_navigation_pad(&ctx,&input,&s,.Accept)
    testing.expect_value(t,s.clicks[1],3)
    test_frame(&ctx,&input,test_navigation_build,&s)
    testing.expect_value(t,s.clicks[1],3)
    ctx.focus=id(&ctx,"check")
    test_navigation_pad(&ctx,&input,&s,.Accept)
    testing.expect(t,s.checked)
    // A ring marks the widget the navigation is on.
    frame:=test_frame(&ctx,&input,test_navigation_build,&s)
    check:=test_rect(t,&ctx,id(&ctx,"check"))
    last:=frame.vertices[len(frame.vertices)-6]
    ring:=false
    if quad_kind(last.quad)==.Shape {
        shape:=frame.shapes[quad_data(last.quad)]
        focus:=tone(&ctx,"focus")
        ring=test_rect_near(Rect{shape.bounds[0],shape.bounds[1],shape.bounds[2],shape.bounds[3]},{check.x-2,check.y-2,check.w+4,check.h+4}) && shape.stroke==[4]f32{f32(focus[0]),f32(focus[1]),f32(focus[2]),f32(focus[3])}/255 && shape.fill[3]==0
    }
    testing.expect(t,ring,"The last shape of the frame outlines the focused widget")
}

@(test)
activating_a_field_types_in_it_and_tab_moves_on :: proc(t:^testing.T) {
    ctx:Context;s:Test_Navigation;input:Input
    test_navigation_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    s.name_length=copy(s.name[:],"old")
    ctx.focus=id(&ctx,"name")
    test_navigation_key(&ctx,&input,&s,.Enter)
    testing.expect_value(t,ctx.edit.id,id(&ctx,"name"))
    // While a field is edited the arrows belong to it.
    test_navigation_key(&ctx,&input,&s,.Left)
    testing.expect(t,ctx.focus==id(&ctx,"name") && ctx.edit.cursor==0)
    test_type(&input,"new ")
    test_frame(&ctx,&input,test_navigation_build,&s)
    test_navigation_key(&ctx,&input,&s,.Tab)
    testing.expect_value(t,string(s.name[:s.name_length]),"new old")
    testing.expect_value(t,ctx.focus,id(&ctx,"value"))
    testing.expect_value(t,ctx.edit.id,id(&ctx,"value"))
    test_type(&input,"42")
    test_frame(&ctx,&input,test_navigation_build,&s)
    test_navigation_key(&ctx,&input,&s,.Tab,{.Shift})
    testing.expect_value(t,s.value,42.0)
    test_frame(&ctx,&input,test_navigation_build,&s)
    testing.expect_value(t,ctx.edit.id,id(&ctx,"name"))
}

@(test)
navigation_stays_inside_an_open_dialog :: proc(t:^testing.T) {
    ctx:Context;s:Test_Navigation;input:Input
    test_navigation_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    s.modal=true
    test_frame(&ctx,&input,test_navigation_build,&s)
    test_frame(&ctx,&input,test_navigation_build,&s)
    test_navigation_key(&ctx,&input,&s,.Tab)
    testing.expect_value(t,ctx.focus,id(&ctx,"no"))
    test_navigation_key(&ctx,&input,&s,.Tab)
    testing.expect_value(t,ctx.focus,id(&ctx,"yes"))
    test_navigation_key(&ctx,&input,&s,.Tab)
    testing.expect_value(t,ctx.focus,id(&ctx,"no"))
    test_navigation_key(&ctx,&input,&s,.Up)
    testing.expect_value(t,ctx.focus,id(&ctx,"no"))
    test_navigation_key(&ctx,&input,&s,.Right)
    test_navigation_key(&ctx,&input,&s,.Enter)
    testing.expect_value(t,s.modal_clicks,[2]int{0,1})
    testing.expect_value(t,s.clicks,[6]int{})
}

@(test)
a_press_that_no_focusable_widget_takes_takes_the_focus_away :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Navigation
    input:=test_input()
    test_frame(&ctx,&input,test_navigation_build,&s)
    test_point(&input,test_rect(t,&ctx,id(&ctx,"button",1)))
    test_press(&input)
    test_frame(&ctx,&input,test_navigation_build,&s)
    testing.expect_value(t,ctx.focus,id(&ctx,"button",1))
    test_release(&input)
    test_frame(&ctx,&input,test_navigation_build,&s)
    test_point(&input,test_rect(t,&ctx,id(&ctx,"button",5)))
    test_press(&input)
    test_frame(&ctx,&input,test_navigation_build,&s)
    testing.expect_value(t,ctx.focus,Id(0))
    test_release(&input)
    test_frame(&ctx,&input,test_navigation_build,&s)
    ctx.focus=id(&ctx,"button",1)
    input.pointer={700,500}
    test_press(&input)
    test_frame(&ctx,&input,test_navigation_build,&s)
    testing.expect_value(t,ctx.focus,Id(0))
    test_release(&input)
    test_frame(&ctx,&input,test_navigation_build,&s)
    ctx.focus=id(&ctx,"button",1)
    input.pointer={700,500}
    input_button(&input,.Right,true)
    test_frame(&ctx,&input,test_navigation_build,&s)
    testing.expect_value(t,ctx.focus,Id(0))
}

@(test)
the_editor_does_not_navigate_with_the_keyboard :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Navigation
    input:=test_input()
    test_frame(&ctx,&input,test_navigation_build,&s)
    for key in ([4]Key{.Tab,.Down,.Enter,.Space}) {
        test_key(&input,key)
        frame:=test_frame(&ctx,&input,test_navigation_build,&s)
        testing.expect(t,ctx.focus==0 && !frame.keyboard_consumed)
    }
    testing.expect_value(t,s.clicks,[6]int{})
}

@(test)
where_keys_navigate_a_press_on_nothing_keeps_the_focus_without_its_ring :: proc(t:^testing.T) {
    ctx:Context
    s:Test_Navigation
    input:Input
    test_navigation_init(t,&ctx,&s,&input)
    defer context_destroy(&ctx)
    test_navigation_key(&ctx,&input,&s,.Tab)
    focused:=ctx.focus
    testing.expect(t,focused!=0 && ctx.focus_ring)
    input.pointer_absent=false
    input.pointer={700,500}
    test_press(&input)
    test_frame(&ctx,&input,test_navigation_build,&s)
    testing.expect_value(t,ctx.focus,focused)
    testing.expect(t,!ctx.focus_ring,"the mouse hides the ring of the focus")
    test_release(&input)
    test_frame(&ctx,&input,test_navigation_build,&s)
    test_navigation_key(&ctx,&input,&s,.Tab)
    testing.expect(t,ctx.focus!=focused && ctx.focus_ring,"the keys show it again")
}
