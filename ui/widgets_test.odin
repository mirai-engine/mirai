package ui

import "core:math"
import "core:testing"

// The paint of the last frame that shows this text.
// The paint of what says text: a widget that draws it, or the text whose first span it is.
test_paint :: proc(ctx:^Context,text:string) -> ^Paint {
    for &p in test_text_pieces(ctx) {if p.text==text {return &p}}
    for &p in ctx.paints[:ctx.paint_count] {if p.text==text {return &p}}
    return nil
}
// Every piece of every line of the texts of the frame as the paint it would
// be: what it says, its style, the fill behind it, and Box when it is a chip.
test_text_pieces :: proc(ctx:^Context) -> []Paint {
    t:=&ctx.layout
    out:=make([dynamic]Paint,context.temp_allocator)
    for &leaf in t.texts[:t.text_count] {
        own:=cast(^Paint)t.nodes[leaf.node].custom
        for &line in t.lines[leaf.lines_first:][:leaf.lines_len] {
            for &piece in t.pieces[line.pieces_first:][:line.pieces_len] {
                s:=&t.spans[piece.span]
                if s.box {continue}
                style,decoration,run:=text_piece_style(ctx,own,s)
                p:=own^
                p.kind,p.text,p.style,p.size,p.text_color,p.decoration=.Box if s.pad>0 else .None,s.text[piece.start:][:piece.length],style,style.size,style.color,decoration
                if run!=nil {p.fill=run.back}
                append(&out,p)
            }
        }
    }
    return out[:]
}
// The running text of the editor with lines line sizes apart; PARAGRAPH_LINE when 0.
test_prose :: proc(ctx:^Context,line:f32) -> Text_Style {
    style:=prose(ctx)
    if line>0 {style.line_height=math.floor(style.size*line)/style.size}
    return style
}
// Whether a paint is that of a text.
test_paint_is_text :: proc(p:Paint) -> bool {return p.kind==.None && p.style.size>0}
// The lines the layout broke the text of the element id into, as they are drawn.
test_text_lines :: proc(ctx:^Context,id:Id,out:[]string) -> int {
    t:=&ctx.layout
    index:=layout_index(t,id)
    if index==0 || t.nodes[index].text<0 {return 0}
    leaf:=&t.texts[t.nodes[index].text]
    for &line,i in t.lines[leaf.lines_first:][:leaf.lines_len] {
        if i>=len(out) {break}
        out[i]=""
        if line.pieces_len==0 {continue}
        first,last:=&t.pieces[line.pieces_first],&t.pieces[line.pieces_first+line.pieces_len-1]
        if first.span==last.span {out[i]=t.spans[first.span].text[first.start:last.start+last.length]}
    }
    return int(leaf.lines_len)
}

Test_Buttons :: struct {
    clicks:[4]int,
    last:[4]Interaction,
    checked,toggled,open:bool,
    tab:int,
    changed:int,
    removed:int,
    disabled:bool,
    cover:bool, // a floating panel over the first button
}
test_buttons_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Buttons)user
    if panel(ctx,id(ctx,"panel"),{width=fixed(300),height=FIT,padding=padding_all(10),gap=10,offset={20,20}}) {
        s.last[0]=button(ctx,id(ctx,"a"),{label="Alpha",style=.Field,width=-1,tip="First"})
        s.last[1]=button(ctx,id(ctx,"b"),{label="Beta",style=.Accent,width=120,disabled=s.disabled})
        s.last[2]=icon_button(ctx,id(ctx,"c"),.Plus)
        for i in 0..<3 {if s.last[i].clicked {s.clicks[i]+=1}}
        if checkbox(ctx,id(ctx,"check"),&s.checked) {s.changed+=1}
        if toggle(ctx,id(ctx,"toggle"),"On" if s.toggled else "Off",&s.toggled,80) {s.changed+=1}
        if tabs(ctx,id(ctx,"tabs"),{"One","Two","Three"},&s.tab) {s.changed+=1}
        result:=collapsible(ctx,id(ctx,"section"),"SECTION",&s.open,{removable=true,width=280})
        if result.removed {s.removed+=1}
        if result.open {label(ctx,"Inside")}
    }
    if s.cover {
        if panel(ctx,id(ctx,"cover"),{width=fixed(100),height=fixed(26),offset={30,30},layer=LAYER_POPUP}) {}
    }
}

@(test)
buttons_follow_the_pointer_and_activate_on_press_in_the_editor :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Buttons
    input:=test_input()
    frame:=test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,!frame.pointer_consumed,"The pointer is nowhere near the panel")
    a:=test_rect(t,&ctx,id(&ctx,"a"))
    testing.expect(t,test_rect_near(a,{30,30,280,THEME_EDITOR.row}))
    testing.expect_value(t,test_paint(&ctx,"Alpha").fill,THEME_EDITOR.field)
    // Over the button: hot from the next frame on, with the rectangles that were shown.
    test_point(&input,a)
    frame=test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,s.last[0].hot && !s.last[0].clicked && frame.pointer_consumed)
    testing.expect_value(t,test_paint(&ctx,"Alpha").fill,THEME_EDITOR.field_hover)
    testing.expect_value(t,ctx.hot,id(&ctx,"a"))
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
    testing.expect_value(t,ctx.active,Id(0))
    // Over the panel but on no button: the panel takes the pointer.
    input.pointer={25,25}
    frame=test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,frame.pointer_consumed && ctx.hot==id(&ctx,"panel"))
    test_press(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    test_release(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect_value(t,s.clicks,[4]int{1,0,0,0})
}

@(test)
buttons_activate_on_release_over_them_when_the_theme_says_so :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    ctx.theme.activate_on_press=false
    s:Test_Buttons
    input:=test_input()
    test_frame(&ctx,&input,test_buttons_build,&s)
    a:=test_rect(t,&ctx,id(&ctx,"a"))
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
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Buttons{cover=true}
    input:=test_input()
    test_frame(&ctx,&input,test_buttons_build,&s)
    input.pointer={40,40}
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect_value(t,ctx.hot,id(&ctx,"cover"))
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
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:=Test_Buttons{disabled=true}
    input:=test_input()
    test_frame(&ctx,&input,test_buttons_build,&s)
    b:=test_rect(t,&ctx,id(&ctx,"b"))
    testing.expect(t,test_near(b.w,120))
    test_point(&input,b)
    test_frame(&ctx,&input,test_buttons_build,&s)
    test_press(&input)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect_value(t,s.clicks[1],0)
    // An accent button keeps its fill and its text at 40 % of their opacity.
    paint:=test_paint(&ctx,"Beta")
    testing.expect_value(t,paint.fill,color_faded(THEME_EDITOR.accent))
    testing.expect_value(t,paint.text_color,color_faded(THEME_EDITOR.on_accent))
    test_release(&input)
    s.disabled=false
    test_frame(&ctx,&input,test_buttons_build,&s)
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect_value(t,test_paint(&ctx,"Beta").fill,THEME_EDITOR.accent_hover)
    testing.expect_value(t,test_paint(&ctx,"Beta").text_color,THEME_EDITOR.on_accent)
}

@(test)
a_tooltip_follows_the_pointer_on_a_widget_with_a_tip :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Buttons
    input:=test_input()
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,test_paint(&ctx,"First")==nil)
    input.pointer={100,40}
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,test_paint(&ctx,"First")==nil,"a tip waits for the pointer to rest")
    // It shows once the pointer rested on the button long enough.
    for _ in 0..<int(TOOLTIP_DELAY*60)+2 {test_frame(&ctx,&input,test_buttons_build,&s)}
    tip:=test_paint(&ctx,"First")
    box:^Paint
    for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Panel && p.fill==THEME_EDITOR.popup {box=&p}}
    testing.expect(t,tip!=nil && tip.style.align_x==.Center && box!=nil)
    // Under the pointer, in the frame that shows it.
    placed,_:=layout_find(&ctx.layout,id(&ctx,"tooltip"))
    testing.expectf(t,test_near(placed.x,100+12) && test_near(placed.y,40+20) && test_near(placed.h,26),"placed at %v",placed)
    // Away from the button it is gone.
    input.pointer={100,400}
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,test_paint(&ctx,"First")==nil)
}

@(test)
checkboxes_toggles_tabs_and_sections_edit_the_state_they_are_given :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Buttons
    input:=test_input()
    click :: proc(ctx:^Context,input:^Input,s:^Test_Buttons,target:Id) {
        rect,_:=widget_rect(ctx,target)
        test_point(input,rect)
        test_frame(ctx,input,test_buttons_build,s)
        test_press(input)
        test_frame(ctx,input,test_buttons_build,s)
        test_release(input)
        test_frame(ctx,input,test_buttons_build,s)
    }
    test_frame(&ctx,&input,test_buttons_build,&s)
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"check")),{30,30+3*(THEME_EDITOR.row+10),16,16}))
    click(&ctx,&input,&s,id(&ctx,"check"))
    testing.expect(t,s.checked && s.changed==1)
    click(&ctx,&input,&s,id(&ctx,"check"))
    testing.expect(t,!s.checked && s.changed==2)
    click(&ctx,&input,&s,id(&ctx,"toggle"))
    testing.expect(t,s.toggled && s.changed==3)
    testing.expect_value(t,test_paint(&ctx,"On").fill,THEME_EDITOR.accent)
    // Tabs: clicking the selected one changes nothing.
    click(&ctx,&input,&s,id_derive(&ctx,id(&ctx,"tabs"),"tab",3))
    testing.expect(t,s.tab==2 && s.changed==4)
    click(&ctx,&input,&s,id_derive(&ctx,id(&ctx,"tabs"),"tab",3))
    testing.expect(t,s.tab==2 && s.changed==4)
    testing.expect_value(t,test_paint(&ctx,"Three").fill,THEME_EDITOR.accent)
    testing.expect_value(t,test_paint(&ctx,"One").text_color,THEME_EDITOR.text_label)
    // The title of a section folds it; its x reports without folding.
    testing.expect(t,test_paint(&ctx,"Inside")==nil)
    click(&ctx,&input,&s,id(&ctx,"section"))
    testing.expect(t,s.open && test_paint(&ctx,"Inside")!=nil)
    click(&ctx,&input,&s,id_derive(&ctx,id(&ctx,"section"),"remove"))
    testing.expect(t,s.open && s.removed==1)
}

@(test)
labels_measure_their_text_and_buttons_fit_their_content :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"row"),gap=4,track=true}) {
            if box(ctx,{id=id(ctx,"fit"),track=true}) {label(ctx,"Directional light",13)}
            if box(ctx,{id=id(ctx,"fixed"),track=true}) {label(ctx,"Directional light",13,{},40)}
            button(ctx,id(ctx,"button"),{label="Play",icon=.Play,detail="F5"})
            button(ctx,id(ctx,"icon"),{icon=.Plus})
        }
    })
    width:=text_width(&ctx.font,"Directional light",13)
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"fit")),{0,0,width+1,19}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"fixed")),{width+1+4,0,40,19}))
    // Padding, icon, gap, label and its detail.
    expected:=f32(10+16+6)+text_width(&ctx.font,"Play",THEME_EDITOR.font)+text_width(&ctx.font,"F5",THEME_EDITOR.font_small)+16+10
    testing.expect(t,test_near(test_rect(t,&ctx,id(&ctx,"button")).w,expected))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"icon")),{test_rect(t,&ctx,id(&ctx,"icon")).x,0,THEME_EDITOR.row,THEME_EDITOR.row}),"An icon alone makes a square of the row height")
}

@(test)
widgets_inside_a_clip_are_reached_only_through_it :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    Clipped :: struct {scroll:[2]f32,clicks:int}
    s:Clipped
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Clipped)user
        if panel(ctx,id(ctx,"panel"),{width=fixed(200),height=fixed(100),offset={0,0}}) {
            if scroll_area(ctx,id(ctx,"scroll"),&s.scroll,{width=GROW,height=fixed(60)}) {
                for i in 0..<10 {if button(ctx,id(ctx,"row",i+1),{label="Row",width=-1,height=20}).clicked {s.clicks+=1}}
            }
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build,&s)
    fourth:=test_rect(t,&ctx,id(&ctx,"row",4))
    testing.expect(t,test_rect_near(fourth,{0,60,200,20}),"The row is laid out below the visible part")
    test_point(&input,fourth)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,ctx.hot,id(&ctx,"panel"))
    test_press(&input)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,s.clicks,0)
    test_release(&input)
    input.pointer={100,50}
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,ctx.hot,id(&ctx,"row",3))
}

@(test)
cards_rows_and_swatches_draw_as_in_the_editor :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    State :: struct {row:Interaction}
    s:State
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^State)user
        if panel(ctx,id(ctx,"panel"),{width=fixed(200),height=FIT,padding=padding_all(12),gap=10}) {
            if grid_row(ctx) {
                card(ctx,id(ctx,"card",1),{label="Cube",icon=.Cube,active=true})
                card(ctx,id(ctx,"card",2),{label="Sphere",icon=.Sphere})
            }
            if grid_row(ctx) {
                card(ctx,id(ctx,"card",3),{label="Cone",icon=.Cone})
                grid_fill(ctx,1)
            }
            color_swatch(ctx,id(ctx,"swatch"),{1,0.5,0},true)
            s.row=row(ctx,id(ctx,"row"),{label="Crate",detail="Mesh",icon=.Mesh,selected=true})
            row(ctx,id(ctx,"plain"),{label="Plain",check_room=true})
            row(ctx,id(ctx,"checked"),{label="Checked",checked=true})
            tree_row(ctx,id(ctx,"folder"),{label="models",folder=true,open=false})
            tree_row(ctx,id(ctx,"leaf"),{label="crate.glb",depth=2,icon=.Mesh})
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build,&s)
    th:=THEME_EDITOR
    first,second,third:=test_rect(t,&ctx,id(&ctx,"card",1)),test_rect(t,&ctx,id(&ctx,"card",2)),test_rect(t,&ctx,id(&ctx,"card",3))
    testing.expect(t,test_rect_near(first,{12,12,84,62}) && test_rect_near(second,{104,12,84,62}))
    testing.expect(t,test_near(third.w,84),"A lone card keeps the column width")
    cube,sphere:=test_paint(&ctx,"Cube"),test_paint(&ctx,"Sphere")
    testing.expect(t,cube.kind==.Card && cube.fill==th.field_active && cube.stroke==th.accent && cube.icon_size==22 && cube.radius==th.radius_control+1)
    testing.expect(t,sphere.fill==th.field && sphere.stroke==th.divider)
    swatch:=&ctx.paints[0]
    for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Swatch {swatch=&p}}
    testing.expect(t,swatch.fill==Color{255,128,0,255} && swatch.stroke==th.accent,"An open swatch is outlined with the accent")
    crate:=test_paint(&ctx,"Crate")
    testing.expect(t,crate.fill==th.accent_soft && crate.detail=="Mesh" && crate.padding==8 && crate.icon==.Mesh)
    testing.expect(t,test_paint(&ctx,"Plain").padding==28,"Rows without a check leave its room")
    checked:=test_paint(&ctx,"Checked")
    testing.expect(t,checked.icon==.Check && checked.icon_color==th.accent && checked.padding==8)
    folder,leaf:=test_paint(&ctx,"models"),test_rect(t,&ctx,id(&ctx,"leaf"))
    testing.expect(t,folder.icon==.Chevron_Right && folder.icon_size==10)
    testing.expect(t,test_near(leaf.x,12+28) && test_near(leaf.h,34),"Rows of a tree step in by their depth")
}

@(test)
paragraph_height_matches_the_lines_the_layout_wraps :: proc(t:^testing.T) {
    // Also when there is no room to keep the words of what it measures.
    for words in ([]int{0,4}) {
        desc:=TEST_FONT
        desc.max_text_words=words
        paragraph_height_matches(t,desc)
    }
}
@(private="file")
paragraph_height_matches :: proc(t:^testing.T,desc:Context_Desc) {
    ctx:Context
    testing.expect(t,context_init(&ctx,desc))
    defer context_destroy(&ctx)
    Case :: struct {text:string,width,line:f32}
    Test_Paragraphs :: struct {cases:[]Case}
    texts:=[]string{
        "",
        " ",
        "One line",
        "The agent changed the material of the cube and moved the sphere half a metre to the right so that both sit on the grid.",
        "Ends with a space ",
        "Two  spaces between  words that wrap  at different  places",
        "A line\nand another\n\nafter an empty one\n",
        "Averyveryverylongwordthatdoesnotfitinanynarrowline next to short ones",
    }
    widths:=[]f32{40,73.5,120,181,260,600}
    cases:[64]Case
    count:=0
    // The line box of each paragraph, in sizes: that of PARAGRAPH_LINE or one of its own.
    lines:=[]f32{0,1.5,1.7}
    for text in texts {for width in widths {cases[count]={text,width,lines[count%len(lines)]};count+=1}}
    s:=Test_Paragraphs{cases[:count]}
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Test_Paragraphs)user
        if panel(ctx,id(ctx,"panel"),{width=fixed(700),height=FIT,offset={0,0}}) {
            for c,i in s.cases {
                if box(ctx,{id=id(ctx,"case",i+1),width=fixed(c.width),height=FIT,direction=.Column,track=true}) {text(ctx,c.text,test_prose(ctx,c.line))}
            }
        }
    }
    input:=test_input(800,20000)
    test_frame(&ctx,&input,build,&s)
    test_frame(&ctx,&input,build,&s)
    for c,i in s.cases {
        laid:=test_rect(t,&ctx,id(&ctx,"case",i+1))
        measured:=text_height(&ctx,c.text,test_prose(&ctx,c.line),c.width)
        testing.expectf(t,test_near(laid.h,measured),"%d words, %q at %v, line %v: laid out %v, measured %v",desc.max_text_words,c.text,c.width,c.line,laid.h,measured)
        single:=math.floor(ctx.theme.font_small*(c.line if c.line>0 else PARAGRAPH_LINE))
        testing.expectf(t,test_near(f32(int(measured/single+0.5))*single,measured),"%q at %v: lines of %v",c.text,c.width,single)
    }
}

@(test)
text_breaks_into_the_same_lines_wherever_it_is_shown :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_FONT
    desc.max_elements=8192
    testing.expect(t,context_init(&ctx,desc))
    defer context_destroy(&ctx)
    // markdown: the text is also a paragraph of Markdown, which trims it and joins its lines.
    Case :: struct {text:string,markdown:bool}
    Shown :: struct {text:string,width:f32}
    Test_Lines :: struct {shown:[64]Shown,count:int,size:f32}
    cases:=[]Case{
        {"One line",true},
        {"The agent changed the material of the cube and moved the sphere half a metre to the right.",true},
        {"Two  spaces between  words that wrap  at different   places",true},
        {"Averyveryverylongwordthatdoesnotfitinanynarrowline next to short ones",true},
        {"a b c d e f g h i j k l m n o p q r s t u v w x y z",true},
        {" ",false},
        {"Ends with a space ",false},
        {"  starts with two spaces",false},
        {"A line\nand another\n\nafter an empty one\n",false},
        {"spaces before a break   \nand after it",false},
    }
    widths:=[]f32{40,73.5,120,181,260,600}
    s:Test_Lines
    s.size=ctx.theme.font_small
    for c in cases {
        m:=layout_measure(&ctx.layout,&ctx.font,c.text,s.size,0)
        for width in widths {
            // A paragraph is no narrower than its widest word and no wider than its text.
            s.shown[s.count]={c.text,max(m.min_width,min(m.width,width))}
            s.count+=1
        }
    }
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Test_Lines)user
        if panel(ctx,id(ctx,"panel"),{width=fixed(700),height=FIT,offset={0,0}}) {
            for c,i in s.shown[:s.count] {rich_text(ctx,id(ctx,"rich",i+1),c.text,{size=s.size},{width=fixed(c.width)})}
        }
    }
    input:=test_input(800,20000)
    test_frame(&ctx,&input,build,&s)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,dropped_total(&ctx.stats),u32(0))
    for c,i in s.shown[:s.count] {
        line:=math.floor(s.size*PARAGRAPH_LINE)
        lines:=int(text_height(&ctx,c.text,prose(&ctx,s.size),c.width)/line+0.5)
        rich:=int(test_rect(t,&ctx,id(&ctx,"rich",i+1)).h/(s.size*TEXT_LINE)+0.5)
        testing.expectf(t,rich==lines,"%q at %v: a rich text takes %d lines, a paragraph %d",c.text,c.width,rich,lines)
        if !cases[i/len(widths)].markdown {continue}
        marked:=int(markdown_height(&ctx,c.text,c.width,{size=s.size})/line+0.5)
        testing.expectf(t,marked==lines,"%q at %v: Markdown takes %d lines, a paragraph %d",c.text,c.width,marked,lines)
    }
}

@(test)
a_scaled_button_inside_a_clipped_box_takes_the_pointer :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"stage"),width=fixed(400),height=fixed(300),clip_x=true,clip_y=true,clip_floats=true}) {
            if animated_begin(ctx,id(ctx,"game"),{scale={0.5,0.5},opacity=1,color={1,1,1,1}}) {}
            if box(ctx,{id=id(ctx,"game"),width=fixed(800),height=fixed(600),float={to=.Parent,anchor=.Center,pivot=.Center}}) {
                button(ctx,id(ctx,"b"),{label="B",width=200,height=100})
            }
            animated_end(ctx)
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
            hit=ctx.hot==id(&ctx,"b")
        }
    }
    testing.expect(t,hit,"The pointer reaches the button where the scaled box draws it")
}
