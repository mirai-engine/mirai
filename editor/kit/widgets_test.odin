package kit

import "core:math"
import "core:testing"
import "mirai:ui"

Test_Buttons :: struct {
    clicks:[4]int,
    last:[4]ui.Interaction,
    checked,toggled,open:bool,
    tab:int,
    changed:int,
    removed:int,
    disabled:bool,
    cover:bool, // a floating panel over the first button
}
test_buttons_build :: proc(ctx:^ui.Context,user:rawptr) {
    s:=cast(^Test_Buttons)user
    if ui.panel(ctx,ui.id(ctx,"panel"),{width=ui.fixed(300),height=ui.FIT,padding=ui.padding_all(10),gap=10,offset={20,20}}) {
        s.last[0]=ui.button(ctx,ui.id(ctx,"a"),{label="Alpha",variant="field",width=-1,tip="First"})
        s.last[1]=ui.button(ctx,ui.id(ctx,"b"),{label="Beta",variant="accent",width=120,disabled=s.disabled})
        s.last[2]=ui.icon_button(ctx,ui.id(ctx,"c"),.Plus)
        for i in 0..<3 {if s.last[i].clicked {s.clicks[i]+=1}}
        if ui.checkbox(ctx,ui.id(ctx,"check"),&s.checked) {s.changed+=1}
        if toggle(ctx,ui.id(ctx,"toggle"),"On" if s.toggled else "Off",&s.toggled,80) {s.changed+=1}
        if tabs(ctx,ui.id(ctx,"tabs"),{"One","Two","Three"},&s.tab) {s.changed+=1}
        result:=collapsible(ctx,ui.id(ctx,"section"),"SECTION",&s.open,{removable=true,width=280})
        if result.removed {s.removed+=1}
        if result.open {ui.label(ctx,"Inside")}
    }
    if s.cover {
        if ui.panel(ctx,ui.id(ctx,"cover"),{width=ui.fixed(100),height=ui.fixed(26),offset={30,30},layer=ui.LAYER_POPUP}) {}
    }
}

@(test)
buttons_follow_the_pointer_and_activate_on_press_in_the_editor :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    s:Test_Buttons
    input:=test_input()
    frame:=test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,!frame.pointer_consumed,"The pointer is nowhere near the panel")
    a:=test_rect(t,&ctx,ui.id(&ctx,"a"))
    testing.expect(t,test_rect_near(a,{30,30,280,ui.metric(&ctx,"row")}))
    testing.expect_value(t,test_box(&ctx,"Alpha").fill,ui.tone(&ctx,"field"))
    // Over the button: hot from the next frame on, with the rectangles that were shown.
    test_point(&input,a)
    frame=test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,s.last[0].hot && !s.last[0].clicked && frame.pointer_consumed)
    testing.expect_value(t,test_box(&ctx,"Alpha").fill,ui.tone(&ctx,"field_hover"))
    testing.expect_value(t,ctx.hot,ui.id(&ctx,"a"))
    // The press activates it, once.
    test_press(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,s.last[0].pressed && s.last[0].clicked && s.last[0].active)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,s.last[0].active && !s.last[0].clicked,"Holding the button does not repeat")
    test_release(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,s.last[0].released && !s.last[0].clicked)
    testing.expect_value(t,s.clicks,[4]int{1,0,0,0})
    testing.expect_value(t,ctx.active,ui.Id(0))
    // Over the panel but on no button: the panel takes the pointer.
    input.pointer={25,25}
    frame=test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,frame.pointer_consumed && ctx.hot==ui.id(&ctx,"panel"))
    test_press(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    test_release(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect_value(t,s.clicks,[4]int{1,0,0,0})
}

@(test)
buttons_activate_on_release_over_them_when_the_theme_says_so :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    ctx.release_activates=true
    s:Test_Buttons
    input:=test_input()
    test_frame(&ctx,&input,test_buttons_build,&s)
    a:=test_rect(t,&ctx,ui.id(&ctx,"a"))
    test_point(&input,a)
    test_frame(&ctx,&input,test_buttons_build,&s)
    test_press(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,s.last[0].pressed && !s.last[0].clicked)
    test_release(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,s.last[0].clicked)
    // Pressed on it and released elsewhere: nothing.
    test_press(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    input.pointer={600,500}
    frame:=test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,s.last[0].active && !s.last[0].hot && frame.pointer_consumed,"The button holds the pointer while it is down")
    test_release(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,s.last[0].released && !s.last[0].clicked)
    testing.expect_value(t,s.clicks[0],1)
    // A press and its release inside one frame still click.
    test_point(&input,a)
    test_frame(&ctx,&input,test_buttons_build,&s)
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect_value(t,s.clicks[0],2)
}

@(test)
the_highest_layer_under_the_pointer_takes_it :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    s:=Test_Buttons{cover=true}
    input:=test_input()
    test_frame(&ctx,&input,test_buttons_build,&s)
    input.pointer={40,40}
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect_value(t,ctx.hot,ui.id(&ctx,"cover"))
    test_press(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect_value(t,s.clicks[0],0)
    test_release(&input)
    // Beside the cover the button is reachable again.
    input.pointer={200,40}
    test_frame(&ctx,&input,test_buttons_build,&s)
    test_press(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect_value(t,s.clicks[0],1)
}

@(test)
disabled_buttons_show_their_state_and_do_nothing :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    s:=Test_Buttons{disabled=true}
    input:=test_input()
    test_frame(&ctx,&input,test_buttons_build,&s)
    b:=test_rect(t,&ctx,ui.id(&ctx,"b"))
    testing.expect(t,test_near(b.w,120))
    test_point(&input,b)
    test_frame(&ctx,&input,test_buttons_build,&s)
    test_press(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect_value(t,s.clicks[1],0)
    // An accent button keeps its fill and its text at 40 % of their opacity.
    testing.expect_value(t,test_box(&ctx,"Beta").fill,ui.color_faded(ui.tone(&ctx,"accent")))
    testing.expect_value(t,test_paint(&ctx,"Beta").style.color,ui.color_faded(ui.tone(&ctx,"on_accent")))
    test_release(&input)
    s.disabled=false
    test_frame(&ctx,&input,test_buttons_build,&s)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect_value(t,test_box(&ctx,"Beta").fill,ui.tone(&ctx,"accent_hover"))
    testing.expect_value(t,test_paint(&ctx,"Beta").style.color,ui.tone(&ctx,"on_accent"))
}

@(test)
checkboxes_toggles_tabs_and_sections_edit_the_state_they_are_given :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    s:Test_Buttons
    input:=test_input()
    click :: proc(ctx:^ui.Context,input:^ui.Input,s:^Test_Buttons,target:ui.Id) {
        rect,_:=ui.widget_rect(ctx,target)
        test_point(input,rect)
        test_frame(ctx,input,test_buttons_build,s)
        test_press(input)
        test_frame(ctx,input,test_buttons_build,s)
        test_release(input)
        test_frame(ctx,input,test_buttons_build,s)
    }
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,test_rect_near(test_rect(t,&ctx,ui.id(&ctx,"check")),{30,30+3*(ui.metric(&ctx,"row")+10),16,16}))
    click(&ctx,&input,&s,ui.id(&ctx,"check"))
    testing.expect(t,s.checked && s.changed==1)
    click(&ctx,&input,&s,ui.id(&ctx,"check"))
    testing.expect(t,!s.checked && s.changed==2)
    click(&ctx,&input,&s,ui.id(&ctx,"toggle"))
    testing.expect(t,s.toggled && s.changed==3)
    testing.expect_value(t,test_box(&ctx,"On").fill,ui.tone(&ctx,"accent"))
    // Tabs: clicking the selected one changes nothing.
    click(&ctx,&input,&s,ui.id_derive(&ctx,ui.id(&ctx,"tabs"),"tab",3))
    testing.expect(t,s.tab==2 && s.changed==4)
    click(&ctx,&input,&s,ui.id_derive(&ctx,ui.id(&ctx,"tabs"),"tab",3))
    testing.expect(t,s.tab==2 && s.changed==4)
    testing.expect_value(t,test_box(&ctx,"Three").fill,ui.tone(&ctx,"accent"))
    testing.expect_value(t,test_paint(&ctx,"One").style.color,ui.tone(&ctx,"text_label"))
    // The title of a section folds it; its x reports without folding.
    testing.expect(t,test_paint(&ctx,"Inside")==nil)
    click(&ctx,&input,&s,ui.id(&ctx,"section"))
    testing.expect(t,s.open && test_paint(&ctx,"Inside")!=nil)
    click(&ctx,&input,&s,ui.id_derive(&ctx,ui.id(&ctx,"section"),"remove"))
    testing.expect(t,s.open && s.removed==1)
}

@(test)
labels_measure_their_text_and_buttons_fit_their_content :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_FONT))
    defer ui.context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,proc(ctx:^ui.Context,user:rawptr) {
        if ui.box(ctx,{id=ui.id(ctx,"row"),gap=4,track=true}) {
            if ui.box(ctx,{id=ui.id(ctx,"fit"),track=true}) {ui.label(ctx,"Directional light",13)}
            if ui.box(ctx,{id=ui.id(ctx,"fixed"),track=true}) {ui.label(ctx,"Directional light",13,{},40)}
            ui.button(ctx,ui.id(ctx,"button"),{label="Play",icon=.Play,detail="F5"})
            ui.button(ctx,ui.id(ctx,"icon"),{icon=.Plus})
        }
    })
    // A text is as wide as it measures up to a whole device pixel.
    width:=math.ceil(ui.text_width(&ctx.font,"Directional light",13)+1)
    testing.expect(t,test_rect_near(test_rect(t,&ctx,ui.id(&ctx,"fit")),{0,0,width,19}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,ui.id(&ctx,"fixed")),{width+4,0,40,19}))
    // Padding, icon, gap, label and its detail.
    expected:=math.ceil(f32(10+16+6)+ui.text_width(&ctx.font,"Play",ui.metric(&ctx,"font"))+ui.text_width(&ctx.font,"F5",ui.metric(&ctx,"font_small"))+16+10)
    testing.expectf(t,test_near(test_rect(t,&ctx,ui.id(&ctx,"button")).w,expected),"button %v, expected %v",test_rect(t,&ctx,ui.id(&ctx,"button")),expected)
    testing.expect(t,test_rect_near(test_rect(t,&ctx,ui.id(&ctx,"icon")),{test_rect(t,&ctx,ui.id(&ctx,"icon")).x,0,ui.metric(&ctx,"row"),ui.metric(&ctx,"row")}),"An icon alone makes a square of the row height")
}

@(test)
widgets_inside_a_clip_are_reached_only_through_it :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    Clipped :: struct {scroll:[2]f32,clicks:int}
    s:Clipped
    build :: proc(ctx:^ui.Context,user:rawptr) {
        s:=cast(^Clipped)user
        if ui.panel(ctx,ui.id(ctx,"panel"),{width=ui.fixed(200),height=ui.fixed(100),offset={0,0}}) {
            if ui.scroll_area(ctx,ui.id(ctx,"scroll"),&s.scroll,{width=ui.GROW,height=ui.fixed(60)}) {
                for i in 0..<10 {if ui.button(ctx,ui.id(ctx,"row",i+1),{label="Row",width=-1,height=20}).clicked {s.clicks+=1}}
            }
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build,&s)
    fourth:=test_rect(t,&ctx,ui.id(&ctx,"row",4))
    testing.expect(t,test_rect_near(fourth,{0,60,200,20}),"The row is laid out below the visible part")
    test_point(&input,fourth)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,ctx.hot,ui.id(&ctx,"panel"))
    test_press(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,s.clicks,0)
    test_release(&input)
    input.pointer={100,50}
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,ctx.hot,ui.id(&ctx,"row",3))
}

@(test)
rows_and_swatches_draw_as_in_the_editor :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    build :: proc(ctx:^ui.Context,user:rawptr) {
        if ui.panel(ctx,ui.id(ctx,"panel"),{width=ui.fixed(200),height=ui.FIT,padding=ui.padding_all(12),gap=10}) {
            color_swatch(ctx,ui.id(ctx,"swatch"),{1,0.5,0},true)
            ui.row(ctx,ui.id(ctx,"row"),{label="Crate",detail="Mesh",icon=.Mesh,selected=true})
            ui.row(ctx,ui.id(ctx,"plain"),{label="Plain",check_room=true})
            ui.row(ctx,ui.id(ctx,"checked"),{label="Checked",checked=true})
            ui.row(ctx,ui.id(ctx,"leaf"),{label="crate.glb",depth=2,icon=.Mesh})
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build,nil)
    swatch:=&ctx.paints[0]
    for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Swatch {swatch=&p}}
    testing.expect(t,swatch.fill==ui.Color{255,128,0,255} && swatch.stroke==ui.tone(&ctx,"accent"),"An open swatch is outlined with the accent")
    selected,mesh,check:=false,false,false
    for &p in ctx.paints[:ctx.paint_count] {
        selected||=p.kind==.Box && p.fill==ui.tone(&ctx,"accent_soft")
        mesh||=p.kind==.Icon && p.icon==.Mesh
        check||=p.kind==.Icon && p.icon==.Check && p.icon_color==ui.tone(&ctx,"accent")
    }
    testing.expect(t,selected && mesh && check && test_paint(&ctx,"Mesh")!=nil,"A row shows its icon, its label, its detail and its check")
    testing.expect(t,test_near(test_rect(t,&ctx,ui.id(&ctx,"leaf")).x,12+24),"Rows of a tree step in by their depth")
}

@(test)
a_scaled_button_inside_a_clipped_box_takes_the_pointer :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    build :: proc(ctx:^ui.Context,user:rawptr) {
        if ui.box(ctx,{id=ui.id(ctx,"stage"),width=ui.fixed(400),height=ui.fixed(300),clip_x=true,clip_y=true,clip_floats=true}) {
            if ui.animated_begin(ctx,ui.id(ctx,"game"),{scale={0.5,0.5},opacity=1,color={1,1,1,1}}) {}
            if ui.box(ctx,{id=ui.id(ctx,"game"),width=ui.fixed(800),height=ui.fixed(600),float={to=.Parent,anchor=.Center,pivot=.Center}}) {
                ui.button(ctx,ui.id(ctx,"b"),{label="B",width=200,height=100})
            }
            ui.animated_end(ctx)
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build)
    hit:=false
    for y:=f32(0);y<300 && !hit;y+=10 {
        for x:=f32(0);x<400 && !hit;x+=10 {
            input.pointer={x,y}
            test_frame(&ctx,&input,build)
            test_frame(&ctx,&input,build)
            hit=ctx.hot==ui.id(&ctx,"b")
        }
    }
    testing.expect(t,hit,"The pointer reaches the button where the scaled box draws it")
}

// A button that fills itself with a color draws its text in the tone made to
// read on that color, legible at rest (WCAG AA: a contrast of 4.5).
@(test)
filled_buttons_draw_their_text_in_the_tone_on_their_fill :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer ui.context_destroy(&ctx)
    relative :: proc(c:ui.Color) -> f32 {
        lum:[3]f32
        for i in 0..<3 {
            v:=f32(c[i])/255
            lum[i]=v/12.92 if v<=0.04045 else math.pow((v+0.055)/1.055,2.4)
        }
        return 0.2126*lum[0]+0.7152*lum[1]+0.0722*lum[2]
    }
    Case :: struct {variant,fill,text:string}
    for c in ([]Case{{"accent","accent","on_accent"},{"danger","danger_fill","on_danger"}}) {
        look:=ui.sheet_look(&ctx,"button",c.variant,{})
        testing.expectf(t,look.fill==ui.tone(&ctx,c.fill) && look.text.color==ui.tone(&ctx,c.text),"%s: %v on %v",c.variant,look.text.color,look.fill)
        a,b:=relative(look.text.color),relative(look.fill)
        testing.expectf(t,(max(a,b)+0.05)/(min(a,b)+0.05)>=4.5,"%s: its text reads on its fill",c.variant)
    }
}
