package ui

import "core:math"
import "core:testing"

@(private)
test_leaf :: proc(ctx:^Context,name:string,index:int,l:Layout) {
    if box(ctx,{id=id(ctx,name,index),layout=l,track=true}) {}
}

@(test)
a_wrap_goes_on_in_another_row_where_the_next_child_does_not_fit :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"wrap"),width=fixed(200),height=FIT,direction=.Wrap,gap=10,padding=padding_all(5),track=true}) {
            widths:=[5]f32{80,80,80,40,30}
            for w,i in widths {test_leaf(ctx,"item",i+1,{width=fixed(w),height=fixed(20+f32(i)*2)})}
            test_leaf(ctx,"rest",0,{width=grow(20),height=fixed(10)})
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build)
    // 190 inside: two of 80 fit with their gap, the third starts the second row.
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"item",2)),Rect{5+90,5,80,22})
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"item",3)),Rect{5,5+22+10,80,24})
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"item",5)).x,f32(5+90+50))
    // What grows takes what its row leaves: the third row holds it alone.
    rest:=test_rect(t,&ctx,id(&ctx,"rest"))
    testing.expect_value(t,rest,Rect{5,5+22+10+28+10,190,10})
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"wrap")).h,f32(5+22+10+28+10+10+5))
}

@(test)
a_stack_lays_its_children_over_one_another_by_their_alignment :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"stack"),width=FIT,height=FIT,direction=.Stack,padding=padding_all(4),align_x=.Center,align_y=.End,track=true}) {
            test_leaf(ctx,"back",0,{width=fixed(100),height=fixed(60)})
            test_leaf(ctx,"middle",0,{width=fixed(20),height=fixed(10)})
            test_leaf(ctx,"corner",0,{width=fixed(10),height=fixed(10),self_x=.End,self_y=.Start})
            test_leaf(ctx,"fill",0,{width=GROW,height=fixed(5),self_y=.Center})
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build)
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"stack")),Rect{0,0,108,68})
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"back")),Rect{4,4,100,60})
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"middle")),Rect{4+40,4+50,20,10})
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"corner")),Rect{4+90,4,10,10})
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"fill")),Rect{4,4+28,100,5}) // 27.5, on a whole pixel
}

@(test)
a_child_aligns_itself_across_its_parent_and_stretches :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"column"),width=fixed(100),height=FIT,direction=.Column,align_x=.Start,track=true}) {
            test_leaf(ctx,"end",0,{width=fixed(20),height=fixed(10),self_x=.End})
            test_leaf(ctx,"center",0,{width=fixed(20),height=fixed(10),self_x=.Center})
            test_leaf(ctx,"stretch",0,{width=FIT,height=fixed(10),self_x=.Stretch})
            test_leaf(ctx,"parent",0,{width=fixed(20),height=fixed(10)})
        }
        if box(ctx,{id=id(ctx,"grid"),width=fixed(100),height=FIT,direction=.Grid,columns=2,align_x=.Start,align_y=.Start,track=true,float={to=.Surface,offset={0,100}}}) {
            test_leaf(ctx,"tall",0,{width=fixed(10),height=fixed(40)})
            test_leaf(ctx,"cell",0,{width=fixed(10),height=fixed(10),self_x=.End,self_y=.Center})
            test_leaf(ctx,"full",0,{width=fixed(10),height=fixed(10),self_x=.Stretch,self_y=.Stretch})
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build)
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"end")).x,f32(80))
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"center")).x,f32(40))
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"stretch")).w,f32(100))
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"parent")).x,f32(0))
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"cell")),Rect{90,100+15,10,10})
    // A fixed size keeps its size; it stretches only what fits its content.
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"full")),Rect{0,140,10,10})
}

@(test)
an_aspect_gives_one_axis_from_the_other :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"row"),width=fixed(300),height=FIT,gap=0,track=true}) {
            test_leaf(ctx,"wide",0,{width=fixed(160),height=FIT,aspect=16.0/9})
            test_leaf(ctx,"tall",0,{width=FIT,height=fixed(40),aspect=0.5})
            test_leaf(ctx,"grown",0,{width=GROW,height=GROW,aspect=2})
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build)
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"wide")),Rect{0,0,160,90})
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"tall")),Rect{160,0,20,40})
    // What grows takes the width that is left, and the height that width gives.
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"grown")),Rect{180,0,120,60})
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"row")).h,f32(90))
}

@(test)
growing_children_share_what_is_left_by_their_weights :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"row"),width=fixed(420),height=fixed(10),gap=10,track=true}) {
            test_leaf(ctx,"one",0,{width=GROW,height=GROW})
            test_leaf(ctx,"three",0,{width={kind=.Grow,value=3},height=GROW})
            test_leaf(ctx,"capped",0,{width={kind=.Grow,value=4,max=40},height=GROW})
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build)
    // 400 to share: the capped one stops at 40 and the others take 360 by one to three.
    testing.expect(t,test_near(test_rect(t,&ctx,id(&ctx,"one")).w,90,0.05))
    testing.expect(t,test_near(test_rect(t,&ctx,id(&ctx,"three")).w,270,0.05))
    testing.expect(t,test_near(test_rect(t,&ctx,id(&ctx,"capped")).w,40,0.05))
}

@(test)
boxes_meet_on_whole_device_pixels :: proc(t:^testing.T) {
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"row"),width=fixed(1000),height=fixed(41),align_y=.Center,track=true}) {
            for i in 1..=3 {if box(ctx,{id=id(ctx,"third",i),width=GROW,height=fixed(10),fill={255,255,255,255},stroke={0,0,0,255},stroke_width=1,track=true}) {}}
        }
    }
    cases:=[]struct{density,scale:f32}{{1.25,1},{1.5,1},{1,1366.0/1920}}
    for c in cases {
        ctx:Context
        testing.expect(t,test_context_init(&ctx,TEST_SMALL))
        defer context_destroy(&ctx)
        testing.expect(t,context_set_density(&ctx,c.density))
        input:=test_input()
        input.scale=c.scale
        frame:=test_frame(&ctx,&input,build)
        ppu:=c.density*c.scale
        whole :: proc(units,ppu:f32) -> bool {return test_near(units*ppu,math.round(units*ppu),0.001)}
        end:=f32(0)
        for i in 1..=3 {
            r:=test_rect(t,&ctx,id(&ctx,"third",i))
            testing.expectf(t,whole(r.x,ppu) && whole(r.y,ppu) && whole(r.x+r.w,ppu) && whole(r.y+r.h,ppu),"%v, third %d: %v",c,i,r)
            testing.expectf(t,i==1 || test_near(r.x,end,0.0001),"%v, third %d starts at %v, the one before ends at %v",c,i,r.x,end)
            end=r.x+r.w
        }
        testing.expect_value(t,len(frame.shapes),3)
        for s in frame.shapes {testing.expectf(t,s.params[0]*ppu>=1 && whole(s.params[0],ppu),"%v: a border %v units wide",c,s.params[0])}
    }
}

@(test)
a_grid_takes_the_widths_of_its_tracks_and_children_span_columns :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.max_grid_tracks=2
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        tracks:=grid_tracks_add(ctx,{count=4,columns={0=fixed(50),1=FIT,2=GROW,3={kind=.Grow,value=3}}})
        if box(ctx,{id=id(ctx,"grid"),width=fixed(430),height=FIT,direction=.Grid,tracks=tracks,gap=10,align_x=.Start,track=true}) {
            test_leaf(ctx,"a",0,{width=GROW,height=fixed(10)})
            test_leaf(ctx,"b",0,{width=fixed(70),height=fixed(10)})
            test_leaf(ctx,"c",0,{width=GROW,height=fixed(10)})
            test_leaf(ctx,"d",0,{width=GROW,height=fixed(10)})
            test_leaf(ctx,"wide",0,{width=GROW,height=fixed(20),span=3})
            test_leaf(ctx,"next",0,{width=GROW,height=fixed(10),span=2})
        }
        if box(ctx,{id=id(ctx,"equal"),width=fixed(320),height=FIT,direction=.Grid,columns=3,gap=10,track=true,float={to=.Surface,offset={0,200}}}) {
            test_leaf(ctx,"pair",0,{width=GROW,height=fixed(10),span=2})
            test_leaf(ctx,"single",0,{width=GROW,height=fixed(10)})
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build)
    // 400 inside the gaps: 50 fixed, 70 for the widest child of the second, 280 shared by one to three.
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"a")),Rect{0,0,50,10})
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"b")).x,f32(60))
    c,d:=test_rect(t,&ctx,id(&ctx,"c")),test_rect(t,&ctx,id(&ctx,"d"))
    testing.expect(t,test_near(c.x,140) && test_near(c.w,70) && test_near(d.x,220) && test_near(d.w,210),"Grow tracks share by weight")
    wide:=test_rect(t,&ctx,id(&ctx,"wide"))
    testing.expect(t,test_near(wide.x,0) && test_near(wide.y,20) && test_near(wide.w,50+10+70+10+70),"A child spans its columns and their gaps")
    next:=test_rect(t,&ctx,id(&ctx,"next"))
    testing.expect(t,test_near(next.y,50) && test_near(next.w,50+10+70),"What does not fit in the rest of a row goes to the next")
    pair:=test_rect(t,&ctx,id(&ctx,"pair"))
    single:=test_rect(t,&ctx,id(&ctx,"single"))
    cell:=f32(320-20)/3
    testing.expect(t,test_near(pair.w,2*cell+10) && test_near(single.x,2*(cell+10)))
    // A frame without room for more tracks drops them and counts them.
    test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        for _ in 0..<3 {grid_tracks_add(ctx,{count=1,columns={0=GROW}})}
    })
    testing.expect_value(t,ctx.stats.dropped_tracks,u32(1))
}

@(test)
a_float_that_contains_itself_flips_and_stays_inside_the_surface :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"anchor"),width=fixed(40),height=fixed(20),float={to=.Surface,offset={770,560}},track=true}) {
            if box(ctx,{id=id(ctx,"tip"),width=fixed(100),height=fixed(30),float={to=.Parent,anchor=.Bottom_Left,pivot=.Top_Left,offset={0,6},layer=LAYER_TOOLTIP},contain=true,track=true}) {}
            if box(ctx,{id=id(ctx,"loose"),width=fixed(100),height=fixed(30),float={to=.Parent,anchor=.Bottom_Left,pivot=.Top_Left,offset={0,6}},track=true}) {}
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build)
    // No room below: it goes over its anchor, as far from it, and moves left into the surface.
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"tip")),Rect{700,560-6-30,100,30})
    testing.expect_value(t,test_rect(t,&ctx,id(&ctx,"loose")),Rect{770,586,100,30})
}
