package ui

import "core:math"
import "core:strings"
import "core:testing"

// The running text of the editor with lines line sizes apart; PARAGRAPH_LINE when 0.
test_prose :: proc(ctx:^Context,line:f32) -> Text_Style {
    style:=prose(ctx)
    if line>0 {style.line_height=math.floor(style.size*line)/style.size}
    return style
}

@(test)
a_tooltip_follows_the_pointer_on_a_widget_with_a_tip :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        if panel(ctx,id(ctx,"panel"),{width=fixed(300),height=FIT,padding=padding_all(10),gap=10,offset={20,20}}) {
            button(ctx,id(ctx,"a"),{label="Alpha",variant="field",width=-1,tip="First"})
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build,nil)
    testing.expect(t,test_paint(&ctx,"First")==nil)
    input.pointer={100,40}
    test_frame(&ctx,&input,build,nil)
    testing.expect(t,test_paint(&ctx,"First")==nil,"a tip waits for the pointer to rest")
    // It shows once the pointer rested on the button long enough.
    for _ in 0..<int(TOOLTIP_DELAY*60)+2 {test_frame(&ctx,&input,build,nil)}
    tip:=test_paint(&ctx,"First")
    box:^Paint
    for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Panel && p.fill==tone(&ctx,"popup") {box=&p}}
    testing.expect(t,tip!=nil && tip.style.align_x==.Center && box!=nil)
    // Under the pointer, in the frame that shows it.
    placed,_:=layout_find(&ctx.layout,id(&ctx,"tooltip"))
    testing.expectf(t,test_near(placed.x,100+12) && test_near(placed.y,40+20) && test_near(placed.h,26),"placed at %v",placed)
    // Away from the button it is gone.
    input.pointer={100,400}
    test_frame(&ctx,&input,build,nil)
    testing.expect(t,test_paint(&ctx,"First")==nil)
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
    testing.expect(t,test_context_init(&ctx,desc))
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
        single:=math.floor(metric(&ctx,"font_small")*(c.line if c.line>0 else PARAGRAPH_LINE))
        testing.expectf(t,test_near(f32(int(measured/single+0.5))*single,measured),"%q at %v: lines of %v",c.text,c.width,single)
    }
}


@(test)
text_breaks_into_the_same_lines_wherever_it_is_shown :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_FONT
    desc.max_elements=8192
    testing.expect(t,test_context_init(&ctx,desc))
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
    s.size=metric(&ctx,"font_small")
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
            for c,i in s.shown[:s.count] {
                rich_text(ctx,id(ctx,"rich",i+1),c.text,{size=s.size},{width=fixed(c.width)})
                if box(ctx,{id=id(ctx,"marked",i+1),width=fixed(c.width),height=FIT,track=true}) {markdown(ctx,id(ctx,"markdown",i+1),c.text,c.width,{size=s.size})}
            }
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
        marked:=int(test_rect(t,&ctx,id(&ctx,"marked",i+1)).h/line+0.5)
        testing.expectf(t,marked==lines,"%q at %v: Markdown takes %d lines, a paragraph %d",c.text,c.width,marked,lines)
    }
}

