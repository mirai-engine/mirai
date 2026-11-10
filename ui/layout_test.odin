package ui

import "core:fmt"
import "core:testing"

@(private)
CORPUS_SIZE :: [2]f32{640,480}
@(private)
CORPUS_SAFE :: [4]f32{12,8,20,16}

@(private)
Corpus :: struct {
    ctx:^Context,
    stack:[32]Box,
    depth:int,
    names:[128]string,
    count:int,
    fill:bool, // every box draws, so that the order of what is drawn shows
}

@(private)
corpus_begin :: proc(c:^Corpus,name:string,b:Box) {
    b:=b
    b.id=id(c.ctx,name)
    b.track=true
    if c.fill {b.fill={255,255,255,255}}
    c.stack[c.depth]=b
    c.depth+=1
    c.names[c.count]=name
    c.count+=1
    box_begin(c.ctx,b)
}
@(private)
corpus_end :: proc(c:^Corpus) {
    c.depth-=1
    box_end(c.ctx,c.stack[c.depth])
}
@(private)
corpus_leaf :: proc(c:^Corpus,name:string,b:Box) {corpus_begin(c,name,b);corpus_end(c)}

// Rows and columns, every kind of size, alignment, compression, floating
// containers and clipped content moved by a scroll offset.
@(private)
corpus_boxes :: proc(ctx:^Context,user:rawptr) {
    c:=cast(^Corpus)user
    c.ctx=ctx
    c.count=0
    corpus_begin(c,"root",{width=GROW,height=GROW,direction=.Column,padding=padding_all(8),gap=6})
        corpus_begin(c,"bar",{width=GROW,height=fixed(34),padding=padding_xy(10,0),gap=8,align_y=.Center})
            corpus_begin(c,"logo",{width=fixed(28),height=fixed(28)})
                corpus_leaf(c,"logo.mark",{width=fixed(8),height=fixed(8)})
            corpus_end(c)
            corpus_leaf(c,"title",{width=fit(40,200),height=GROW})
            corpus_leaf(c,"filler",{width=GROW,height=GROW})
            corpus_leaf(c,"close",{width=fixed(20),height=fixed(20),align_y=.End})
        corpus_end(c)
        corpus_begin(c,"body",{width=GROW,height=GROW,gap=6})
            corpus_begin(c,"side",{width=fixed(240),height=GROW,direction=.Column,padding=padding_all(12),gap=4})
                corpus_leaf(c,"side.one",{width=GROW,height=fixed(24)})
                corpus_leaf(c,"side.two",{width=percent(0.5),height=fixed(24)})
                corpus_leaf(c,"side.rest",{width=GROW,height=grow(40,90)})
                corpus_begin(c,"squeeze",{width=GROW,height=fixed(30),gap=10})
                    corpus_begin(c,"squeeze.clip",{height=GROW,clip_x=true})
                        corpus_leaf(c,"squeeze.clip.in",{width=fixed(150),height=fixed(10)})
                    corpus_end(c)
                    corpus_leaf(c,"squeeze.grow",{width=grow(30),height=GROW})
                    corpus_leaf(c,"squeeze.fixed",{width=fixed(60),height=fixed(12),align_y=.Center})
                corpus_end(c)
                corpus_begin(c,"share",{width=GROW,height=fixed(20)})
                    corpus_leaf(c,"share.max",{width=grow(0,50),height=GROW})
                    corpus_leaf(c,"share.any",{width=GROW,height=GROW})
                    corpus_leaf(c,"share.min",{width=grow(100),height=GROW})
                corpus_end(c)
                corpus_begin(c,"fit.clamp",{width=fit(80,120),height=fit(0,16)})
                    corpus_leaf(c,"fit.clamp.in",{width=fixed(150),height=fixed(30)})
                corpus_end(c)
            corpus_end(c)
            corpus_begin(c,"main",{width=GROW,height=GROW,direction=.Column,padding={4,6,8,10},gap=3,align_x=.End})
                corpus_begin(c,"main.a",{width=fixed(120),height=fixed(30)})
                    corpus_leaf(c,"main.a.in",{width=GROW,height=GROW,padding=padding_all(2)})
                    corpus_leaf(c,"float.parent",{width=fixed(30),height=fixed(10),float={to=.Parent,anchor=.Bottom_Right,pivot=.Top_Left,offset={4,-2}}})
                    corpus_begin(c,"float.under",{width=GROW,height=FIT,direction=.Column,float={to=.Parent,anchor=.Bottom_Left,pivot=.Top_Left,layer=LAYER_POPUP}})
                        corpus_leaf(c,"float.under.a",{width=fixed(40),height=fixed(12)})
                        corpus_leaf(c,"float.under.b",{width=GROW,height=fixed(12)})
                    corpus_end(c)
                corpus_end(c)
                corpus_begin(c,"main.centered",{width=fixed(200),height=fixed(40),align_x=.Center,align_y=.Center})
                    corpus_leaf(c,"main.centered.in",{width=fixed(60),height=fixed(12)})
                corpus_end(c)
                corpus_leaf(c,"main.bottom",{width=percent(0.25),height=fixed(20),align_y=.End})
                corpus_begin(c,"percent",{width=fixed(200),height=fixed(100),direction=.Column,gap=5,align_x=.Center})
                    corpus_leaf(c,"percent.a",{width=fixed(40),height=percent(0.3)})
                    corpus_leaf(c,"percent.b",{width=percent(0.5),height=percent(0.2)})
                    corpus_leaf(c,"percent.rest",{width=GROW,height=GROW})
                corpus_end(c)
                corpus_begin(c,"scroll",{width=fixed(150),height=fixed(60),direction=.Column,padding=padding_all(5),gap=2,clip_y=true,scroll={0,25}})
                    for name in ([]string{"scroll.0","scroll.1","scroll.2","scroll.3","scroll.4"}) {
                        corpus_leaf(c,name,{width=GROW,height=fixed(20)})
                    }
                corpus_end(c)
                corpus_begin(c,"pan",{width=fixed(100),height=fixed(24),gap=4,clip_x=true,scroll={30,0}})
                    corpus_leaf(c,"pan.0",{width=fixed(60),height=GROW})
                    corpus_leaf(c,"pan.1",{width=fixed(60),height=GROW})
                corpus_end(c)
                corpus_begin(c,"wrap",{height=FIT,direction=.Column,padding=padding_all(3)})
                    corpus_leaf(c,"wrap.grow",{width=GROW,height=fixed(6)})
                    corpus_leaf(c,"wrap.fixed",{width=fixed(70),height=fixed(6)})
                corpus_end(c)
            corpus_end(c)
        corpus_end(c)
    corpus_end(c)
    corpus_leaf(c,"float.center",{width=fixed(50),height=fixed(20),float={to=.Surface,anchor=.Center,pivot=.Center,layer=LAYER_POPUP}})
    corpus_leaf(c,"float.safe",{width=fixed(80),height=fixed(16),float={to=.Safe,anchor=.Bottom_Center,pivot=.Bottom_Center,offset={0,-4},layer=LAYER_PANEL}})
    corpus_begin(c,"float.top",{width=FIT,height=FIT,padding=padding_all(4),gap=2,float={to=.Surface,anchor=.Top_Right,pivot=.Top_Right,offset={-6,6},layer=LAYER_TOOLTIP}})
        corpus_leaf(c,"float.top.a",{width=fixed(16),height=fixed(16)})
        corpus_leaf(c,"float.top.b",{width=fixed(24),height=fixed(10),align_y=.Center})
    corpus_end(c)
    corpus_begin(c,"more",{width=fixed(300),height=FIT,direction=.Column,gap=4,float={to=.Surface,offset={320,250}}})
        corpus_begin(c,"fitrow",{height=fixed(10)})
            corpus_leaf(c,"fitrow.grow",{width=grow(10),height=GROW})
            corpus_leaf(c,"fitrow.fixed",{width=fixed(30),height=GROW})
        corpus_end(c)
        corpus_begin(c,"centered",{width=GROW,height=fixed(16),align_x=.Center,gap=2})
            corpus_leaf(c,"centered.a",{width=fixed(20),height=fixed(8)})
            corpus_leaf(c,"centered.b",{width=fixed(30),height=fixed(8)})
        corpus_end(c)
        corpus_begin(c,"bottom",{width=fixed(40),height=fixed(40),direction=.Column,align_y=.End})
            corpus_leaf(c,"bottom.a",{width=fixed(10),height=fixed(10)})
        corpus_end(c)
        corpus_leaf(c,"empty",{padding={1,2,3,4}})
        corpus_begin(c,"nested",{width=GROW,height=fixed(20)})
            corpus_begin(c,"nested.grow",{width=GROW,height=GROW})
                corpus_leaf(c,"nested.grow.half",{width=percent(0.5),height=percent(0.5)})
            corpus_end(c)
            corpus_leaf(c,"nested.fixed",{width=fixed(100),height=GROW})
        corpus_end(c)
        corpus_leaf(c,"float.wide",{width=percent(0.5),height=fixed(6),float={to=.Parent,anchor=.Bottom_Left,pivot=.Top_Left}})
    corpus_end(c)
    corpus_leaf(c,"float.fill",{width=GROW,height=fixed(4),float={to=.Surface,anchor=.Bottom_Left,pivot=.Bottom_Left,layer=LAYER_BAR}})
    corpus_leaf(c,"float.part",{width=percent(0.25),height=percent(0.1),float={to=.Surface,anchor=.Top_Right,pivot=.Top_Right,layer=LAYER_BAR}})
    corpus_begin(c,"glass",{width=fixed(60),height=fixed(20),padding=padding_all(5),float={to=.Surface,anchor=.Bottom_Left,pivot=.Bottom_Left,layer=LAYER_TOAST},layer={enabled=true,opacity=1}})
        corpus_leaf(c,"glass.in",{width=fixed(10),height=fixed(10)})
    corpus_end(c)
}

@(private)
Text_Case :: struct {name,text:string,width,size:f32}
@(private)
TEXT_CASES :: []Text_Case{
    {"one","a short line",400,12},
    {"wrap","a line that has to be broken into several lines by the layout that holds it",160,12},
    {"doubles","double  spaces   and more of them",120,12},
    {"breaks","first\n\nthird\n",200,12},
    {"wide","unbreakablewordthatiswiderthanthebox and then some more",60,12},
    {"empty","",120,12},
    {"sizes","12 puntos y una línea bastante larga que no entra",140,12},
    {"small","eleven points wrap at another width than twelve do",90,11},
    {"title","a title of thirteen points",100,13},
    {"tiny","ten points for the names of the cards",70,10},
    {"edges"," starts and ends with a space ",80,12},
    {"lone","x",1,12},
}

// Each case in a box of its width, and two runs side by side in a row that
// cannot hold both on one line each.
@(private)
corpus_texts :: proc(ctx:^Context,user:rawptr) {
    for c in TEXT_CASES {
        if box(ctx,{id=id(ctx,c.name),width=fixed(c.width),height=FIT,track=true}) {text(ctx,c.text,prose(ctx,c.size))}
    }
    if box(ctx,{id=id(ctx,"pair"),width=fixed(180),height=FIT,gap=8,track=true}) {
        text(ctx,"the first of two runs that share a row",prose(ctx,12))
        text(ctx,"and the second one",prose(ctx,12))
    }
    if box(ctx,{id=id(ctx,"column"),width=fixed(150),height=FIT,direction=.Column,padding=padding_all(4),gap=2,track=true}) {
        text(ctx,"a column takes the width of its parent and breaks the text to it",prose(ctx,12))
        text(ctx,"short",prose(ctx,12))
    }
    if box(ctx,{id=id(ctx,"beside"),width=fixed(200),height=FIT,gap=4,track=true}) {
        if box(ctx,{id=id(ctx,"beside.icon"),width=fixed(24),height=fixed(24),track=true}) {}
        if box(ctx,{id=id(ctx,"beside.text"),width=GROW,height=FIT,direction=.Column,track=true}) {
            text(ctx,"what is left of the row once the icon is in",prose(ctx,12))
        }
    }
    if box(ctx,{id=id(ctx,"clipped"),width=fixed(100),height=FIT,clip_x=true,track=true}) {
        text(ctx,"a clip moves what does not fit instead of breaking it",prose(ctx,12))
    }
}

// ---------------------------------------------------------------- expected

// What Clay v0.14 placed and broke for these corpora when it was the layout of
// the package: the expected values keep that behavior. The lines of text were
// measured again when sizes became em and the font FreeType's, with kerning;
// at the sizes of before they break and start where Clay put them.

@(private)
Golden_Box :: struct {name:string,rect:Rect}
// The element whose command it is; an end names none.
@(private)
Golden_Command :: struct {kind:Layout_Command_Kind,name:string}

@(private)
Test_Command :: struct {kind:Layout_Command_Kind,id:Id,text:string,rect:Rect}

@(private)
test_layout_commands :: proc(ctx:^Context,out:[]Test_Command) -> int {
    t:=&ctx.layout
    for c,i in t.commands[:min(t.command_count,len(out))] {
        n:=&t.nodes[c.node]
        out[i]={c.kind,n.id,"",n.box}
        if c.kind==.Text {
            line:=&t.lines[c.line]
            piece:=&t.pieces[line.pieces_first]
            out[i].text=t.spans[piece.span].text[piece.start:][:piece.length]
            out[i].rect={line.x,line.y,line.width,line.height}
        }
    }
    return t.command_count
}

@(test)
boxes_are_placed_where_the_layout_always_placed_them :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input(CORPUS_SIZE.x,CORPUS_SIZE.y)
    input.safe=CORPUS_SAFE
    c:Corpus
    test_frame(&ctx,&input,corpus_boxes,&c)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    testing.expect_value(t,c.count,len(GOLDEN_BOXES))
    for want in GOLDEN_BOXES {
        got:=test_rect(t,&ctx,id(&ctx,want.name))
        testing.expectf(t,test_rect_near(got,want.rect),"%s: %v, expected %v",want.name,got,want.rect)
    }
}

@(test)
what_is_drawn_follows_the_layers_and_closes_its_clips :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input(CORPUS_SIZE.x,CORPUS_SIZE.y)
    input.safe=CORPUS_SAFE
    c:=Corpus{fill=true}
    frame_begin(&ctx,input)
    corpus_boxes(&ctx,&c)
    frame_end(&ctx)
    commands:[256]Test_Command
    count:=test_layout_commands(&ctx,commands[:])
    golden:=GOLDEN_COMMANDS
    testing.expect_value(t,count,len(golden))
    for want,i in golden[:min(count,len(golden))] {
        got:=commands[i]
        testing.expectf(t,got.kind==want.kind,"command %d: %v, expected %v of %s",i,got.kind,want.kind,want.name)
        if want.name!="" {testing.expectf(t,got.id==id(&ctx,want.name),"command %d: %v of another element, expected %s",i,got.kind,want.name)}
    }
}

@(test)
paragraphs_break_into_the_lines_they_always_did :: proc(t:^testing.T) {
    // With room to keep the words of every run, and with room for none of the
    // long ones, whose words are measured again as they are broken.
    for words in ([]int{0,4}) {
        desc:=TEST_FONT
        desc.max_text_words=words
        ctx:Context
        testing.expect(t,context_init(&ctx,desc))
        defer context_destroy(&ctx)
        input:=test_input(CORPUS_SIZE.x,CORPUS_SIZE.y)
        input.safe=CORPUS_SAFE
        // Boxes first, so that each run of text takes the place of an element of
        // another kind: a run keeps nothing of what was there before it.
        c:Corpus
        test_frame(&ctx,&input,corpus_boxes,&c)
        test_frame(&ctx,&input,corpus_texts,nil)
        frame_begin(&ctx,input)
        corpus_texts(&ctx,nil)
        frame_end(&ctx)
        testing.expect_value(t,ctx.stats.dropped_elements,u32(0))
        walked:=0
        for r in ctx.layout.spans[:ctx.layout.span_count] {if r.measure.words_first<0 {walked+=1}}
        testing.expectf(t,(walked>0)==(words>0),"%d words: %d runs walked",words,walked)
        for want in GOLDEN_TEXT_BOXES {
            got:=test_rect(t,&ctx,id(&ctx,want.name))
            testing.expectf(t,test_rect_near(got,want.rect),"%d words, %s: %v, expected %v",words,want.name,got,want.rect)
        }
        commands:[256]Test_Command
        count:=test_layout_commands(&ctx,commands[:])
        golden:=GOLDEN_LINES
        lines:=0
        for command in commands[:min(count,len(commands))] {
            if command.kind!=.Text {continue}
            if lines<len(golden) {
                want:=golden[lines]
                testing.expectf(t,command.text==want.name && test_rect_near(command.rect,want.rect),
                    "%d words, line %d: %q %v, expected %q %v",words,lines,command.text,command.rect,want.name,want.rect)
            }
            lines+=1
        }
        testing.expect_value(t,lines,len(golden))
    }
}

@(test)
a_frame_that_shows_the_same_text_measures_none_of_it :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    input:=test_input(CORPUS_SIZE.x,CORPUS_SIZE.y)
    test_frame(&ctx,&input,corpus_texts,nil)
    runs:=u32(ctx.layout.span_count)
    testing.expect(t,runs>0)
    testing.expect_value(t,ctx.stats.text_measured+ctx.stats.text_reused,runs)
    test_frame(&ctx,&input,corpus_texts,nil)
    testing.expect_value(t,ctx.stats.text_measured,u32(0))
    testing.expect_value(t,ctx.stats.text_reused,runs)
}

@(test)
text_that_fills_more_than_half_the_measures_is_not_measured_again :: proc(t:^testing.T) {
    desc:=TEST_FONT
    desc.max_text_words=64
    ctx:Context
    testing.expect(t,context_init(&ctx,desc))
    defer context_destroy(&ctx)
    input:=test_input(CORPUS_SIZE.x,CORPUS_SIZE.y)
    // 16 runs of three words: 48 of the 64 a frame holds.
    RUNS :: 16
    build :: proc(ctx:^Context,user:rawptr) {
        buffer:[32]u8
        for i in 0..<RUNS {
            if box(ctx,{id=id(ctx,"run",i+1),width=fixed(40),height=FIT,track=true}) {
                text(ctx,fmt.bprintf(buffer[:],"unique run %d",i+1),prose(ctx,12))
            }
        }
    }
    test_frame(&ctx,&input,build,nil)
    testing.expect_value(t,ctx.stats.text_measured,u32(RUNS))
    first:[RUNS]Rect
    for &r,i in first {r=test_rect(t,&ctx,id(&ctx,"run",i+1))}
    testing.expectf(t,first[0].h>12*PARAGRAPH_LINE,"each run breaks into lines: %v",first[0])
    for _ in 0..<3 {
        test_frame(&ctx,&input,build,nil)
        testing.expect_value(t,ctx.stats.text_measured,u32(0))
        testing.expect_value(t,ctx.stats.text_reused,u32(RUNS))
        for want,i in first {
            got:=test_rect(t,&ctx,id(&ctx,"run",i+1))
            testing.expectf(t,got==want,"run %d: %v, expected %v",i+1,got,want)
        }
    }
    testing.expect_value(t,ctx.stats.dropped_elements,u32(0))
}

@(test)
a_world_panel_is_laid_out_from_the_origin_of_its_surface :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input(800,600)
    // The panel takes, in the second frame, the place of an element that was
    // somewhere else of the screen in the first.
    before :: proc(ctx:^Context,user:rawptr) {
        box_begin(ctx,{id=id(ctx,"lead"),width=fixed(100),height=fixed(40)});box_end(ctx,{id=id(ctx,"lead")})
        box_begin(ctx,{id=id(ctx,"moved"),width=fixed(70),height=fixed(30)});box_end(ctx,{id=id(ctx,"moved")})
    }
    after :: proc(ctx:^Context,user:rawptr) {
        box_begin(ctx,{id=id(ctx,"lead"),width=fixed(100),height=fixed(40)});box_end(ctx,{id=id(ctx,"lead")})
        if world_panel(ctx,id(ctx,"panel"),{size={200,100},unit=0.01,direction=.Column,padding=padding_all(10),gap=4}) {
            box_begin(ctx,{id=id(ctx,"inside"),width=GROW,height=fixed(16),track=true});box_end(ctx,{id=id(ctx,"inside")})
        }
    }
    test_frame(&ctx,&input,before)
    for _ in 0..<2 {
        test_frame(&ctx,&input,after)
        testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"panel")),{0,0,200,100}))
        testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"inside")),{10,10,180,16}))
    }
}

@(private)
GOLDEN_BOXES :: []Golden_Box{
    {"root",{0,0,640,480}},
    {"bar",{8,8,624,34}},
    {"logo",{18,11,28,28}},
    {"logo.mark",{18,11,8,8}},
    {"title",{54,8,40,34}},
    {"filler",{102,8,492,34}},
    {"close",{602,15,20,20}},
    {"body",{8,48,624,424}},
    {"side",{8,48,240,424}},
    {"side.one",{20,60,216,24}},
    {"side.two",{20,88,108,24}},
    {"side.rest",{20,116,216,90}},
    {"squeeze",{20,210,216,30}},
    {"squeeze.clip",{20,210,106.005,30}},
    {"squeeze.clip.in",{20,210,150,10}},
    {"squeeze.grow",{136.005,210,30,30}},
    {"squeeze.fixed",{176.005,210,60,12}},
    {"share",{20,244,216,20}},
    {"share.max",{20,244,50,20}},
    {"share.any",{70,244,65.993,20}},
    {"share.min",{135.993,244,100,20}},
    {"fit.clamp",{20,268,120,16}},
    {"fit.clamp.in",{20,268,150,30}},
    {"main",{254,48,378,424}},
    {"main.a",{504,54,120,30}},
    {"main.a.in",{504,54,120,30}},
    {"float.parent",{628,82,30,10}},
    {"float.under",{504,84,120,24}},
    {"float.under.a",{504,84,40,12}},
    {"float.under.b",{504,96,120,12}},
    {"main.centered",{424,87,200,40}},
    {"main.centered.in",{494,101,60,12}},
    {"main.bottom",{532.5,130,91.5,20}},
    {"percent",{424,153,200,100}},
    {"percent.a",{504,153,40,27}},
    {"percent.b",{474,185,100,18}},
    {"percent.rest",{424,208,200,45}},
    {"scroll",{474,256,150,60}},
    {"scroll.0",{479,236,140,20}},
    {"scroll.1",{479,258,140,20}},
    {"scroll.2",{479,280,140,20}},
    {"scroll.3",{479,302,140,20}},
    {"scroll.4",{479,324,140,20}},
    {"pan",{524,319,100,24}},
    {"pan.0",{494,319,60,24}},
    {"pan.1",{558,319,60,24}},
    {"wrap",{548,346,76,18}},
    {"wrap.grow",{551,349,70,6}},
    {"wrap.fixed",{551,355,70,6}},
    {"float.center",{295,230,50,20}},
    {"float.safe",{276,444,80,16}},
    {"float.top",{584,6,50,24}},
    {"float.top.a",{588,10,16,16}},
    {"float.top.b",{606,10,24,10}},
    {"more",{320,250,300,102}},
    {"fitrow",{320,250,40,10}},
    {"fitrow.grow",{320,250,10,10}},
    {"fitrow.fixed",{330,250,30,10}},
    {"centered",{320,264,300,16}},
    {"centered.a",{444,264,20,8}},
    {"centered.b",{466,264,30,8}},
    {"bottom",{320,284,40,40}},
    {"bottom.a",{320,314,10,10}},
    {"empty",{320,328,4,0}},
    {"nested",{320,332,300,20}},
    {"nested.grow",{320,332,200,20}},
    {"nested.grow.half",{320,332,100,10}},
    {"nested.fixed",{520,332,100,20}},
    {"float.wide",{320,352,0,6}},
    {"float.fill",{0,476,640,4}},
    {"float.part",{640,0,0,0}},
    {"glass",{0,460,60,20}},
    {"glass.in",{5,465,10,10}},
}
@(private)
GOLDEN_TEXT_BOXES :: []Golden_Box{
    {"one",{0,0,400,19}},
    {"wrap",{400,0,160,57}},
    {"doubles",{560,0,120,38}},
    {"breaks",{680,0,200,57}},
    {"wide",{880,0,60,38}},
    {"empty",{940,0,120,19}},
    {"sizes",{1060,0,140,57}},
    {"small",{1200,0,90,68}},
    {"title",{1290,0,100,40}},
    {"tiny",{1390,0,70,48}},
    {"edges",{1460,0,80,57}},
    {"lone",{1540,0,1,19}},
    {"pair",{1541,0,180,57}},
    {"column",{1721,0,150,86}},
    {"beside",{1871,0,200,38}},
    {"beside.icon",{1871,0,24,24}},
    {"beside.text",{1899,0,172,38}},
    {"clipped",{2071,0,100,19}},
}
@(private)
GOLDEN_LINES :: []Golden_Box{
    {"a short line",{0,0,62.643,19}},
    {"a line that has to be broken",{400,0,153.352,19}},
    {"into several lines by the",{400,19,133.371,19}},
    {"layout that holds it",{400,38,103.717,19}},
    {"double  spaces  ",{560,0,93.111,19}},
    {"and more of them",{560,19,100.488,19}},
    {"first",{680,0,22.125,19}},
    {"third",{680,38,25.594,19}},
    {"unbreakablewordthatiswiderthanthebox ",{880,0,228.469,19}},
    {"and then some more",{880,19,116.467,19}},
    {"12 puntos y una línea",{1060,0,118.992,19}},
    {"bastante larga que no",{1060,19,123.064,19}},
    {"entra",{1060,38,29.268,19}},
    {"eleven points",{1200,0,69.04,17}},
    {"wrap at another",{1200,17,81.947,17}},
    {"width than",{1200,34,54.538,17}},
    {"twelve do",{1200,51,50.499,17}},
    {"a title of",{1290,0,49.601,20}},
    {"thirteen points",{1290,20,88.378,20}},
    {"ten points for",{1390,0,62.607,16}},
    {"the names of",{1390,16,61.729,16}},
    {"the cards",{1390,32,44.253,16}},
    {" starts and",{1460,0,59.83,19}},
    {"ends with a",{1460,19,65.004,19}},
    {"space ",{1460,38,37.764,19}},
    {"x",{1540,0,6.551,19}},
    {"the first of",{1541,0,58.529,19}},
    {"two runs that",{1541,19,74.373,19}},
    {"share a row",{1541,38,66.088,19}},
    {"and the",{1635,0,42.568,19}},
    {"second one",{1635,19,66.475,19}},
    {"a column takes the",{1725,4,106.904,19}},
    {"width of its parent and",{1725,23,127.166,19}},
    {"breaks the text to it",{1725,42,109.037,19}},
    {"short",{1725,63,29.256,19}},
    {"what is left of the row once",{1899,0,153.838,19}},
    {"the icon is in",{1899,19,71.426,19}},
    {"a clip moves what does not fit instead of breaking it",{2071,0,292.02,19}},
}
@(private)
GOLDEN_COMMANDS :: []Golden_Command{
    {.Custom,"root"},
    {.Custom,"bar"},
    {.Custom,"logo"},
    {.Custom,"logo.mark"},
    {.Custom,"title"},
    {.Custom,"filler"},
    {.Custom,"close"},
    {.Custom,"body"},
    {.Custom,"side"},
    {.Custom,"side.one"},
    {.Custom,"side.two"},
    {.Custom,"side.rest"},
    {.Custom,"squeeze"},
    {.Scissor_Start,"squeeze.clip"},
    {.Custom,"squeeze.clip"},
    {.Custom,"squeeze.clip.in"},
    {.Scissor_End,""},
    {.Custom,"squeeze.grow"},
    {.Custom,"squeeze.fixed"},
    {.Custom,"share"},
    {.Custom,"share.max"},
    {.Custom,"share.any"},
    {.Custom,"share.min"},
    {.Custom,"fit.clamp"},
    {.Custom,"fit.clamp.in"},
    {.Custom,"main"},
    {.Custom,"main.a"},
    {.Custom,"main.a.in"},
    {.Custom,"main.centered"},
    {.Custom,"main.centered.in"},
    {.Custom,"main.bottom"},
    {.Custom,"percent"},
    {.Custom,"percent.a"},
    {.Custom,"percent.b"},
    {.Custom,"percent.rest"},
    {.Scissor_Start,"scroll"},
    {.Custom,"scroll"},
    {.Custom,"scroll.0"},
    {.Custom,"scroll.1"},
    {.Custom,"scroll.2"},
    {.Custom,"scroll.3"},
    {.Custom,"scroll.4"},
    {.Scissor_End,""},
    {.Scissor_Start,"pan"},
    {.Custom,"pan"},
    {.Custom,"pan.0"},
    {.Custom,"pan.1"},
    {.Scissor_End,""},
    {.Custom,"wrap"},
    {.Custom,"wrap.grow"},
    {.Custom,"wrap.fixed"},
    {.Custom,"float.parent"},
    {.Custom,"more"},
    {.Custom,"fitrow"},
    {.Custom,"fitrow.grow"},
    {.Custom,"fitrow.fixed"},
    {.Custom,"centered"},
    {.Custom,"centered.a"},
    {.Custom,"centered.b"},
    {.Custom,"bottom"},
    {.Custom,"bottom.a"},
    {.Custom,"empty"},
    {.Custom,"nested"},
    {.Custom,"nested.grow"},
    {.Custom,"nested.grow.half"},
    {.Custom,"nested.fixed"},
    {.Custom,"float.wide"},
    {.Custom,"float.safe"},
    {.Custom,"float.fill"},
    {.Custom,"float.part"},
    {.Custom,"glass"},
    {.Custom,"glass.in"},
    {.Border,""},
    {.Custom,"float.under"},
    {.Custom,"float.under.a"},
    {.Custom,"float.under.b"},
    {.Custom,"float.center"},
    {.Custom,"float.top"},
    {.Custom,"float.top.a"},
    {.Custom,"float.top.b"},
}

@(test)
what_floats_in_a_box_that_cuts_its_floats_is_cut_by_it :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    Test :: struct {cut:bool}
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Test)user
        if box(ctx,{id=id(ctx,"area"),width=fixed(100),height=fixed(100),clip_x=true,clip_y=true,clip_floats=s.cut}) {
            if box(ctx,{id=id(ctx,"float"),width=fixed(80),height=fixed(80),float={to=.Parent,offset={60,60},layer=2},fill={255,0,0,255}}) {}
        }
    }
    input:=test_input()
    for cut in ([2]bool{false,true}) {
        s:=Test{cut}
        frame:=test_frame(&ctx,&input,build,&s)
        widest:=f32(0)
        for command in frame.commands {if command.count>0 {widest=max(widest,command.scissor.x+command.scissor.w)}}
        if cut {testing.expect_value(t,widest,f32(100))} else {testing.expect(t,widest>100,"it floats over the surface")}
    }
}

@(test)
what_floats_in_nested_boxes_that_cut_their_floats_is_cut_by_all_of_them :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    // The stage of a preview moved past the left of its area: what floats on
    // the stage does not show beside the area.
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{width=fixed(40),height=fixed(100)}) {}
        if box(ctx,{id=id(ctx,"area"),width=fixed(100),height=fixed(100),clip_x=true,clip_y=true,clip_floats=true,scroll={60,0}}) {
            if box(ctx,{id=id(ctx,"stage"),width=fixed(100),height=fixed(100),clip_x=true,clip_y=true,clip_floats=true}) {
                if box(ctx,{id=id(ctx,"float"),width=fixed(100),height=fixed(100),float={to=.Parent,layer=2},fill={255,0,0,255}}) {}
            }
        }
    }
    input:=test_input()
    frame:=test_frame(&ctx,&input,build,nil)
    leftmost:=f32(1000)
    for command in frame.commands {if command.count>0 {leftmost=min(leftmost,command.scissor.x)}}
    testing.expect_value(t,leftmost,f32(40))
}
