package ui

import "core:testing"

Test_Axes :: struct {
    strip,both,log,rows:[2]f32,
    focusable:bool, // the rows of the log are buttons
}
test_axes_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Axes)user
    if panel(ctx,id(ctx,"top"),{width=fixed(200),height=FIT}) {
        if scroll_area(ctx,id(ctx,"strip"),&s.strip,{width=fixed(200),height=FIT,axes=.Horizontal,gap=10}) {
            for i in 0..<10 {test_leaf(ctx,"card",i+1,{width=fixed(50),height=fixed(30)})}
        }
    }
    if panel(ctx,id(ctx,"side"),{width=fixed(150),height=FIT,offset={400,0}}) {
        if scroll_area(ctx,id(ctx,"log"),&s.log,{height=fixed(100)}) {
            for i in 0..<10 {
                if s.focusable {button(ctx,id(ctx,"line",i+1),{label="Line",width=-1,height=30})} else {test_leaf(ctx,"line",i+1,{width=GROW,height=fixed(30)})}
            }
        }
    }
    if panel(ctx,id(ctx,"map"),{width=fixed(100),height=FIT,offset={0,300}}) {
        if scroll_area(ctx,id(ctx,"both"),&s.both,{height=fixed(100),axes=.Both}) {
            test_leaf(ctx,"plan",0,{width=fixed(300),height=fixed(400)})
        }
    }
}

@(test)
an_area_scrolls_across_with_the_wheel_shift_and_its_bar :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Axes
    input:=test_input()
    test_frame(&ctx,&input,test_axes_build,&s)
    test_frame(&ctx,&input,test_axes_build,&s)
    strip:=test_rect(t,&ctx,id(&ctx,"strip"))
    content:=test_rect(t,&ctx,scroll_content_id(&ctx,id(&ctx,"strip")))
    testing.expect(t,test_near(strip.w,200) && test_near(content.w,10*50+9*10),"The content is as wide as it asks for")
    _,bar:=widget_rect(&ctx,scroll_bar_id(&ctx,id(&ctx,"strip"),false))
    testing.expect(t,bar,"A bar shows what of it is in sight")
    // An area that only scrolls across takes the wheel so.
    test_point(&input,strip)
    input.wheel={0,-1}
    test_frame(&ctx,&input,test_axes_build,&s)
    test_frame(&ctx,&input,test_axes_build,&s)
    testing.expect_value(t,s.strip,[2]f32{36,0})
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"card",1)).x,f32(-36))
    input.wheel={2,0}
    test_frame(&ctx,&input,test_axes_build,&s)
    testing.expect_value(t,s.strip.x,f32(36+72))
    input.wheel={-100,0}
    test_frame(&ctx,&input,test_axes_build,&s)
    testing.expect_value(t,s.strip.x,f32(0))
    // One that scrolls both ways takes Shift and the wheel across, and the wheel down.
    view:=test_rect(t,&ctx,id(&ctx,"both"))
    test_point(&input,view)
    input.wheel={0,-1}
    test_frame(&ctx,&input,test_axes_build,&s)
    testing.expect_value(t,s.both,[2]f32{0,36})
    input.wheel={0,-1}
    input.modifiers={.Shift}
    test_frame(&ctx,&input,test_axes_build,&s)
    testing.expect_value(t,s.both,[2]f32{36,36})
    input.modifiers={}
    input.wheel={0,100}
    test_frame(&ctx,&input,test_axes_build,&s)
    testing.expect_value(t,s.both,[2]f32{36,0})
}

@(test)
page_keys_and_the_stick_scroll_an_area_that_holds_nothing_focusable :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Axes
    input:=test_input()
    test_frame(&ctx,&input,test_axes_build,&s)
    test_frame(&ctx,&input,test_axes_build,&s)
    test_point(&input,test_rect(t,&ctx,id(&ctx,"log")))
    test_key(&input,.Page_Down)
    test_frame(&ctx,&input,test_axes_build,&s)
    testing.expect(t,test_near(s.log.y,90),"A page is most of the area")
    test_key(&input,.End)
    test_frame(&ctx,&input,test_axes_build,&s)
    testing.expect(t,test_near(s.log.y,300-100))
    test_key(&input,.Home)
    test_frame(&ctx,&input,test_axes_build,&s)
    testing.expect_value(t,s.log.y,f32(0))
    // The stick moves the area the keys reach, at its speed for as long as it is held.
    input.scroll={0,0.5}
    test_frame(&ctx,&input,test_axes_build,&s)
    testing.expect(t,test_near(s.log.y,0.5*SCROLL_STICK/60,0.01))
    input.scroll={}
    // With nothing under the pointer, the largest area of the highest layer takes them.
    input.pointer={-100,-100}
    test_key(&input,.Page_Down)
    test_frame(&ctx,&input,test_axes_build,&s)
    testing.expect(t,test_near(s.log.y,0.5*SCROLL_STICK/60+90,0.01) && s.both=={})
    // Over rows that take the focus the keys are navigation's.
    s.focusable,s.log=true,{}
    test_frame(&ctx,&input,test_axes_build,&s)
    test_frame(&ctx,&input,test_axes_build,&s)
    test_point(&input,test_rect(t,&ctx,id(&ctx,"log")))
    test_key(&input,.Page_Down)
    test_frame(&ctx,&input,test_axes_build,&s)
    testing.expect_value(t,s.log.y,f32(0))
}

@(test)
navigation_reaches_what_an_area_scrolled_away_and_brings_it_into_sight :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.navigation=true
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    s:=Test_Axes{focusable=true}
    input:=test_input()
    test_frame(&ctx,&input,test_axes_build,&s)
    test_frame(&ctx,&input,test_axes_build,&s)
    focus_set(&ctx,id(&ctx,"line",3))
    // The fourth line is out of sight, right under the area.
    for _ in 0..<2 {
        test_key(&input,.Down)
        test_frame(&ctx,&input,test_axes_build,&s)
    }
    testing.expect_value(t,ctx.focus,id(&ctx,"line",5))
    test_frame(&ctx,&input,test_axes_build,&s)
    line:=test_rect(t,&ctx,id(&ctx,"line",5))
    log:=test_rect(t,&ctx,id(&ctx,"log"))
    testing.expectf(t,line.y>=log.y-0.5 && line.y+line.h<=log.y+log.h+0.5,"%v in %v",line,log)
}
