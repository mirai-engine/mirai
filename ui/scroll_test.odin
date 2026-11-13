package ui

import "core:testing"

Test_Scroll :: struct {
    outer,inner:[2]f32,
    inner_fits:bool, // the inner area holds one row instead of six
    list:f32,
    rows:int,
    count:int,
    built:int,       // rows of the list that became elements
    first,last:int,
    clicked:int,
    popup:bool,
    modal:bool,
    modal_scroll:f32,
}
test_scroll_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Scroll)user
    if panel(ctx,id(ctx,"panel"),{width=fixed(200),height=FIT,offset={0,0}}) {
        if scroll_area(ctx,id(ctx,"outer"),&s.outer,{width=fixed(200),height=FIT,max_height=300,padding=padding_all(10),gap=10}) {
            for i in 0..<s.rows {button(ctx,id(ctx,"row",i+1),{label="Row",width=-1,height=30})}
            if scroll_area(ctx,id(ctx,"inner"),&s.inner,{height=fixed(60)}) {
                for i in 0..<(1 if s.inner_fits else 6) {button(ctx,id(ctx,"inner_row",i+1),{label="Inner",width=-1,height=30})}
            }
        }
    }
    if panel(ctx,id(ctx,"lists"),{width=fixed(200),height=FIT,offset={300,0}}) {
        s.built=0
        list:=id(ctx,"list")
        s.first,s.last=list_begin(ctx,list,&s.list,s.count,26,104)
        for index in s.first..<s.last {
            if row(ctx,id(ctx,"item",index+1),{label="Item",height=26}).clicked {s.clicked=index}
            s.built+=1
        }
        list_end(ctx,list,s.count,s.last,26)
    }
    if s.popup {
        if panel(ctx,id(ctx,"over"),{width=fixed(100),height=fixed(100),offset={50,50},layer=LAYER_POPUP}) {}
    }
    if s.modal {
        if modal(ctx,id(ctx,"modal"),{width=300,scroll=&s.modal_scroll}) {
            for _ in 0..<40 {label(ctx,"A line of the dialog")}
        }
    }
}
test_scroll_frame :: proc(ctx:^Context,input:^Input,s:^Test_Scroll) {test_frame(ctx,input,test_scroll_build,s)}
test_wheel :: proc(ctx:^Context,input:^Input,s:^Test_Scroll,notches:f32) {
    input.wheel={0,notches}
    test_scroll_frame(ctx,input,s)
    test_scroll_frame(ctx,input,s)
}

@(test)
a_scroll_area_grows_to_its_limit_and_then_scrolls_with_the_wheel :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Scroll{rows=2}
    input:=test_input()
    test_scroll_frame(&ctx,&input,&s)
    // Two rows, the inner area and their gaps inside 10 of padding.
    outer:=test_rect(t,&ctx,id(&ctx,"outer"))
    testing.expect(t,test_rect_near(outer,{0,0,200,10+30+10+30+10+60+10}))
    input.pointer={100,20}
    test_wheel(&ctx,&input,&s,-3)
    testing.expect_value(t,s.outer.y,f32(0))
    // With more rows than fit it stops at its limit and the content goes on.
    s.rows=12
    test_scroll_frame(&ctx,&input,&s)
    test_scroll_frame(&ctx,&input,&s)
    outer=test_rect(t,&ctx,id(&ctx,"outer"))
    content:=test_rect(t,&ctx,id_derive(&ctx,id(&ctx,"outer"),"content"))
    testing.expect(t,test_near(outer.h,300) && test_near(content.h,10+12*40+60+10))
    test_wheel(&ctx,&input,&s,-1)
    testing.expect_value(t,s.outer.y,f32(36))
    testing.expect(t,test_near(test_rect(t,&ctx,id(&ctx,"row",1)).y,10-36),"The content moves up by the offset")
    test_wheel(&ctx,&input,&s,-100)
    testing.expect_value(t,s.outer.y,content.h-300)
    test_wheel(&ctx,&input,&s,100)
    testing.expect_value(t,s.outer.y,f32(0))
    // Beside the panel the wheel is not for it.
    input.pointer={250,20}
    test_wheel(&ctx,&input,&s,-1)
    testing.expect_value(t,s.outer.y,f32(0))
}

@(test)
the_wheel_belongs_to_the_innermost_area_under_the_pointer_that_can_move_that_way :: proc(t:^testing.T) {
    // Six rows: the outer area can move 20 down, and the inner one 120.
    cases:=[]struct{name:string,fits:bool,outer,inner,wheel,want_outer,want_inner:f32}{
        {"the inner area has room",false,0,0,-1,0,36},
        {"the inner area fits what it holds",true,0,0,-1,20,0},
        {"the inner area is at its end",false,0,120,-1,20,120},
        {"the inner area is at its top",false,20,0,1,0,0},
    }
    for c in cases {
        ctx:Context
        testing.expect(t,test_context_init(&ctx,TEST_SMALL))
        defer context_destroy(&ctx)
        s:=Test_Scroll{rows=6,inner_fits=c.fits,outer={0,c.outer},inner={0,c.inner}}
        input:=test_input()
        test_scroll_frame(&ctx,&input,&s)
        test_scroll_frame(&ctx,&input,&s)
        test_point(&input,test_rect(t,&ctx,id(&ctx,"inner")))
        test_wheel(&ctx,&input,&s,c.wheel)
        testing.expectf(t,s.outer.y==c.want_outer && s.inner.y==c.want_inner,"%s: outer %v and inner %v, expected %v and %v",c.name,s.outer.y,s.inner.y,c.want_outer,c.want_inner)
    }
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Scroll{rows=2}
    input:=test_input()
    test_scroll_frame(&ctx,&input,&s)
    inner:=test_rect(t,&ctx,id(&ctx,"inner"))
    testing.expect(t,test_rect_near(inner,{10,90,180,60}))
    test_point(&input,inner)
    test_wheel(&ctx,&input,&s,-1)
    testing.expect(t,s.inner.y==36 && s.outer.y==0)
    test_wheel(&ctx,&input,&s,-10)
    testing.expect_value(t,s.inner.y,f32(6*30-60))
    // A surface of a higher layer over an area keeps the wheel from it.
    s.popup=true;s.inner.y=0
    input.pointer={100,100}
    test_scroll_frame(&ctx,&input,&s)
    test_wheel(&ctx,&input,&s,-1)
    testing.expect_value(t,ctx.hot,id(&ctx,"over"))
    testing.expect(t,s.inner.y==0 && s.outer.y==0)
}

@(test)
a_long_list_builds_only_the_rows_in_sight :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Scroll{count=1000}
    input:=test_input()
    test_scroll_frame(&ctx,&input,&s)
    testing.expect(t,s.first==0 && s.last==6 && s.built==6)
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"list")),{300,0,200,104}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"item",3)),{300,52,200,26}))
    // The bar of the inner area appears once its first layout is known.
    test_scroll_frame(&ctx,&input,&s)
    elements:=ctx.stats.elements
    input.pointer={400,50}
    test_wheel(&ctx,&input,&s,-10)
    testing.expect_value(t,s.list,f32(360))
    testing.expect(t,s.first==13 && s.last==19 && s.built==6)
    testing.expect_value(t,ctx.stats.elements,elements)
    // Row 14 starts at 364 of the content: 4 below the top of the list.
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"item",15)),{300,4,200,26}))
    test_click(&ctx,&input,test_scroll_build,&s,id(&ctx,"item",16))
    testing.expect_value(t,s.clicked,15)
    test_wheel(&ctx,&input,&s,-10000)
    testing.expect_value(t,s.list,f32(1000*26-104))
    testing.expect(t,s.last==1000 && s.first==996)
    // A list shorter than its box does not scroll.
    s.count=2;s.list=50
    test_scroll_frame(&ctx,&input,&s)
    testing.expect(t,s.list==0 && s.first==0 && s.last==2)
    s.count=0
    test_scroll_frame(&ctx,&input,&s)
    testing.expect(t,s.first==0 && s.last==0 && s.built==0)
    offset:=f32(100)
    scroll_reveal(&offset,26,52,104)
    testing.expect_value(t,offset,f32(26))
    scroll_reveal(&offset,200,226,104)
    testing.expect_value(t,offset,f32(122))
    scroll_reveal(&offset,150,176,104)
    testing.expect_value(t,offset,f32(122))
}

@(test)
a_dialog_taller_than_the_surface_scrolls :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Scroll{modal=true}
    input:=test_input(800,400)
    test_scroll_frame(&ctx,&input,&s)
    dialog:=test_rect(t,&ctx,id(&ctx,"modal"))
    testing.expect(t,test_near(dialog.h,400-2*metric(&ctx,"margin")),"The dialog stops at the margins of the surface")
    input.pointer={400,200}
    test_wheel(&ctx,&input,&s,-2)
    testing.expect_value(t,s.modal_scroll,f32(72))
    test_wheel(&ctx,&input,&s,-1000)
    content:=test_rect(t,&ctx,id_derive(&ctx,id(&ctx,"modal"),"content"))
    testing.expect_value(t,s.modal_scroll,content.h-dialog.h)
}

@(test)
clipping_containers_beyond_the_capacity_are_refused_and_counted :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.max_clips=10
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    offsets:[14][2]f32
    input:=test_input()
    frame:=test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        offsets:=cast(^[14][2]f32)user
        for &offset,i in offsets {
            if scroll_area(ctx,id(ctx,"area",i+1),&offset,{width=fixed(50),height=fixed(20)}) {label(ctx,"x")}
        }
    },&offsets)
    testing.expect(t,frame.overflow)
    testing.expect_value(t,ctx.stats.dropped_clips,u32(14-10))
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"area",14)),{650,0,50,20}),"The container is still laid out, without its clip")
}

@(test)
the_bar_of_an_area_shows_what_is_in_sight_and_drags_it :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Scroll{rows=2}
    input:=test_input()
    test_scroll_frame(&ctx,&input,&s)
    test_scroll_frame(&ctx,&input,&s)
    bar:=scroll_bar_id(&ctx,id(&ctx,"outer"),true)
    _,found:=widget_rect(&ctx,bar)
    testing.expect(t,!found,"Everything fits: no bar")
    // With more rows than fit, the thumb keeps the height the view is of the content.
    s.rows=12
    test_scroll_frame(&ctx,&input,&s)
    test_scroll_frame(&ctx,&input,&s)
    view:=test_rect(t,&ctx,id(&ctx,"outer"))
    content:=test_rect(t,&ctx,scroll_content_id(&ctx,id(&ctx,"outer")))
    thumb_rect,_:=widget_rect(&ctx,bar)
    testing.expect(t,test_near(thumb_rect.w,SCROLL_BAR) && test_near(thumb_rect.h,view.h*view.h/content.h,0.5))
    testing.expectf(t,test_near(thumb_rect.x+thumb_rect.w,view.x+view.w) && test_near(thumb_rect.y,view.y),"thumb %v view %v content %v",thumb_rect,view,content)
    // Dragging the thumb moves the content in proportion.
    input.pointer={thumb_rect.x+3,thumb_rect.y+5}
    test_scroll_frame(&ctx,&input,&s)
    test_press(&input)
    test_scroll_frame(&ctx,&input,&s)
    span:=content.h-view.h
    travel:=view.h-thumb_rect.h
    input.pointer={thumb_rect.x+3,thumb_rect.y+5+travel*0.5}
    test_scroll_frame(&ctx,&input,&s)
    testing.expect(t,test_near(s.outer.y,span*0.5,1),"The offset follows the thumb")
    input.pointer={thumb_rect.x+3,thumb_rect.y+5+travel*4}
    test_scroll_frame(&ctx,&input,&s)
    testing.expectf(t,test_near(s.outer.y,span,0.5),"It stops at the end of the content: %v of %v",s.outer.y,span)
    test_release(&input)
    test_scroll_frame(&ctx,&input,&s)
}

@(test)
the_bar_of_an_area_in_a_panel_hangs_from_the_area :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        if panel(ctx,id(ctx,"moved"),{width=fixed(160),height=FIT,offset={420,90}}) {
            if scroll_area(ctx,id(ctx,"area"),cast(^[2]f32)user,{height=FIT,max_height=100}) {
                for i in 0..<10 {button(ctx,id(ctx,"row",i+1),{label="Row",width=-1,height=30})}
            }
        }
    }
    offset:[2]f32
    input:=test_input()
    test_frame(&ctx,&input,build,&offset)
    test_frame(&ctx,&input,build,&offset)
    view:=test_rect(t,&ctx,id(&ctx,"area"))
    thumb:=test_rect(t,&ctx,scroll_bar_id(&ctx,id(&ctx,"area"),true))
    testing.expectf(t,test_near(thumb.x+thumb.w,view.x+view.w) && test_near(thumb.y,view.y),"thumb %v view %v",thumb,view)
}

@(test)
the_keyboard_brings_the_widget_it_focuses_into_sight :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.navigation=true
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    s:=Test_Scroll{rows=12}
    input:=test_input()
    test_scroll_frame(&ctx,&input,&s)
    test_scroll_frame(&ctx,&input,&s)
    testing.expect_value(t,s.outer.y,f32(0))
    // A row at the bottom of the content scrolls the area the least it takes.
    ctx.focus=id(&ctx,"row",11)
    ctx.focus_ring=true
    test_scroll_frame(&ctx,&input,&s)
    view:=test_rect(t,&ctx,id(&ctx,"outer"))
    row:=test_rect(t,&ctx,id(&ctx,"row",11))
    testing.expect(t,s.outer.y>0,"The area moved to the focused row")
    testing.expect(t,row.y>=view.y-0.5 && row.y+row.h<=view.y+view.h+0.5,"The row is inside the view")
    moved:=s.outer.y
    test_scroll_frame(&ctx,&input,&s)
    testing.expect_value(t,s.outer.y,moved)
    // The wheel keeps working after the focus was followed once.
    input.pointer={100,20}
    test_wheel(&ctx,&input,&s,1)
    testing.expect(t,s.outer.y<moved,"The wheel is not fought by the focus")
    // An area inside another: both move, so the row ends up in sight of both.
    ctx.focus=id(&ctx,"inner_row",6)
    ctx.focus_ring=true
    test_scroll_frame(&ctx,&input,&s)
    test_scroll_frame(&ctx,&input,&s)
    inner:=test_rect(t,&ctx,id(&ctx,"inner"))
    row=test_rect(t,&ctx,id(&ctx,"inner_row",6))
    view=test_rect(t,&ctx,id(&ctx,"outer"))
    testing.expect(t,s.inner.y>0,"The inner area scrolled to its last row")
    testing.expect(t,row.y>=inner.y-0.5 && row.y+row.h<=inner.y+inner.h+0.5,"The row is inside the inner view")
    testing.expect(t,inner.y>=view.y-0.5 && inner.y+inner.h<=view.y+view.h+0.5,"The inner area is inside the outer view")
}

@(test)
rows_of_different_heights_build_only_those_in_sight_and_keep_the_range :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    Test_Rows :: struct {heights:[200]f32,offset:f32,first,last,built:int,grow:bool}
    s:Test_Rows
    for &h,i in s.heights {h=f32(20+(i%3)*30)} // 20, 50, 80, ...
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Test_Rows)user
        if panel(ctx,id(ctx,"panel"),{width=fixed(200),height=fixed(300) if s.grow else FIT,offset={0,0}}) {
            area:=id(ctx,"rows")
            s.first,s.last=rows_begin(ctx,area,&s.offset,s.heights[:],GROW,GROW if s.grow else fixed(300))
            s.built=0
            for i in s.first..<s.last {
                if box(ctx,{id=id(ctx,"row",i+1),width=GROW,height=fixed(s.heights[i]),track=true}) {}
                s.built+=1
            }
            rows_end(ctx,area,&s.offset,s.heights[:],s.last)
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,s.first==0 && s.last==6 && s.built==6,"20+50+80+20+50+80 is 300: the seventh row starts below the edge")
    content:=test_rect(t,&ctx,id_derive(&ctx,id(&ctx,"rows"),"content"))
    testing.expect(t,test_near(content.h,f32(200/3)*150+20+50),"the content keeps the height of every row")
    s.offset=100
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,s.first==2 && s.last==9)
    testing.expect(t,test_near(test_rect(t,&ctx,id(&ctx,"row",3)).y,70-100),"a row sits where the rows above it end, moved up by the offset")
    // Past the end the area shows the last rows.
    s.offset=max(f32)
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,s.offset==content.h-300 && s.last==200)
    testing.expect(t,test_near(test_rect(t,&ctx,id(&ctx,"row",200)).y+50,300))
    input.pointer={100,100}
    input.wheel={0,1}
    test_frame(&ctx,&input,build,&s)
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,s.offset<content.h-300,"the wheel moves it back")
    // An area whose height the layout gives shows what fits in the height it had.
    s.grow,s.offset,input.wheel=true,100,{}
    test_frame(&ctx,&input,build,&s)
    test_frame(&ctx,&input,build,&s)
    testing.expect(t,s.first==2 && s.last==9 && test_near(test_rect(t,&ctx,id(&ctx,"rows")).h,300))
}
