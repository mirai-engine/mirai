package ui

import "core:math"
import "core:testing"

// Text as a leaf of the layout, the baseline of a row and the rows of a grid.

@(test)
a_text_breaks_to_the_width_the_layout_gives_it_in_the_same_frame :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    CONTENT :: "The quick brown fox jumps over the lazy dog and keeps on running"
    STYLE :: Text_Style{size=14,color={255,255,255,255},wrap=.Words}
    // parent: the width of the column that holds the text; wide: the width the text ends with, its own when 0.
    Case :: struct {name:string,parent:f32,width:Size,wide:f32}
    Cases :: struct {cases:[]Case}
    cases:=[]Case{
        {"fit",600,FIT,0},
        {"fit in less",120,FIT,120},
        {"grow",150,GROW,150},
        {"grow to its most",400,grow(0,110),110},
        {"percent",300,percent(0.5),150},
        {"fixed",600,fixed(90),90},
    }
    s:=Cases{cases}
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Cases)user
        y:f32
        for c,i in s.cases {
            if box(ctx,{id=id(ctx,"case",i+1),width=fixed(c.parent),height=FIT,direction=.Column,track=true,float={to=.Surface,offset={0,y}}}) {
                text(ctx,CONTENT,STYLE,c.width,FIT,id(ctx,"text",i+1))
                rich_text(ctx,id(ctx,"rich",i+1),CONTENT,STYLE,{width=c.width})
            }
            y+=300
        }
    }
    input:=test_input(800,2000)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,dropped_total(&ctx.stats),u32(0))
    whole:=text_width(&ctx.font,CONTENT,STYLE.size)
    line:=STYLE.size*TEXT_LINE
    for c,i in cases {
        r:=test_rect(t,&ctx,id(&ctx,"text",i+1))
        rich:=test_rect(t,&ctx,id(&ctx,"rich",i+1))
        testing.expectf(t,test_near(r.w,c.wide if c.wide>0 else whole,0.05),"%s: %v wide",c.name,r.w)
        lines:=int(r.h/line+0.5)
        testing.expectf(t,(lines>1)==(r.w<whole) && test_near(r.h,f32(lines)*line),"%s: %v lines in %v",c.name,r.h/line,r.w)
        testing.expectf(t,test_near(r.h,text_height(&ctx,CONTENT,STYLE,r.w)),"%s: laid out %v, measured %v",c.name,r.h,text_height(&ctx,CONTENT,STYLE,r.w))
        // Spans in a line break where one span of words does, and what holds them took their height in this frame.
        testing.expectf(t,test_near(rich.w,r.w,0.05) && test_near(rich.h,r.h),"%s: rich text %v, text %v",c.name,rich,r)
        testing.expectf(t,test_near(test_rect(t,&ctx,id(&ctx,"case",i+1)).h,r.h+rich.h),"%s: its column is as high as its lines",c.name)
        broken:[16]string
        count:=test_text_lines(&ctx,id(&ctx,"text",i+1),broken[:])
        for shown in broken[:min(count,len(broken))] {
            testing.expectf(t,text_width(&ctx.font,shown,STYLE.size)<=r.w+0.05,"%s: %q is wider than %v",c.name,shown,r.w)
        }
    }
}

@(test)
a_text_keeps_the_lines_that_fit_and_its_own_line_breaks :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    line:=f32(10)*TEXT_LINE
    Case :: struct {content:string,style:Text_Style,width,lines:f32}
    plain:=Text_Style{size=10}
    words:=Text_Style{size=10,wrap=.Words}
    for c in ([]Case{
        {"",words,100,1},
        // The empty line a newline at the end starts is the caret's: the text itself is no taller.
        {"a\n",words,100,1},
        {"a\n\nb",plain,100,3},
        // Without wrap only its own breaks break it, however narrow its box.
        {"alpha beta gamma",plain,10,1},
        {"alpha beta gamma",words,10,3},
        {"alpha beta gamma",words,-5,3},
        {"alpha beta gamma",words,max(f32),1},
    }) {
        testing.expectf(t,test_near(text_height(&ctx,c.content,c.style,c.width),c.lines*line),"%q at %v: %v lines",c.content,c.width,text_height(&ctx,c.content,c.style,c.width)/line)
    }
    // A box shorter than its lines shows those that fit, and the last one ends in an ellipsis.
    build :: proc(ctx:^Context,user:rawptr) {
        text(ctx,"one two three four five six seven eight nine ten",{size=10,color={255,255,255,255},wrap=.Words,ellipsis=true},fixed(60),fixed(2.5*10*TEXT_LINE),id(ctx,"cut"))
    }
    input:=test_input()
    test_frame(&ctx,&input,build)
    leaf:=&ctx.layout.texts[ctx.layout.nodes[layout_index(&ctx.layout,id(&ctx,"cut"))].text]
    testing.expect(t,leaf.shown==2 && leaf.lines_len>2 && ctx.layout.lines[leaf.lines_first+1].cut && !ctx.layout.lines[leaf.lines_first].cut)
}

@(test)
text_built_out_of_order_or_from_numbers_that_are_none_ends_no_frame :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    nan:=math.nan_f32()
    build :: proc(ctx:^Context,user:rawptr) {
        nan:=math.nan_f32()
        // Spans and ends without a text, a text inside a text, and a text nobody ends.
        text_span(ctx,"stray")
        text_box(ctx,10,10,{})
        text_space(ctx)
        text_end(ctx)
        text_end_height(ctx,100)
        if text_begin(ctx,{size=12}) {
            text_begin(ctx,{size=12})
            text_span(ctx,"kept")
            text_end(ctx)
        }
        for size in ([]f32{nan,-4,0,1e30}) {
            text(ctx,"numbers that are none",{size=size,wrap=.Words,line_height=nan},fixed(nan),FIT)
            text(ctx,"numbers that are none",{size=12,wrap=.Words},grow(nan,nan),percent(nan))
        }
        if text_begin(ctx,{size=12,wrap=.Words},nan,true) {
            text_span(ctx,"a chip",{size=nan,pad=nan,height=nan})
            text_box(ctx,nan,nan,{kind=.Rect},gap=nan)
            text_box(ctx,1e30,-1,{})
            text_end(ctx,{width=fixed(40)},reveal=nan)
        }
        // A grid whose children ask for more rows than it has children, and tracks that say more than they hold.
        tracks:=grid_tracks_add(ctx,{count=255})
        rows:=grid_rows_add(ctx,{count=255,rows={0={kind=.Grow,value=nan},1=percent(nan)}})
        if box(ctx,{width=fixed(100),height=fixed(nan),direction=.Grid,tracks=tracks,row_tracks=rows}) {
            for _ in 0..<5 {element_leaf(ctx,{layout={width=GROW,height=GROW,span=255},row_span=255})}
        }
        if box(ctx,{width=FIT,height=FIT,direction=.Grid,columns=3,align_y=.Baseline,row_tracks=9999}) {
            for i in 0..<7 {element_leaf(ctx,{layout={width=fixed(10),height=fixed(nan if i==3 else 10)},row_span=u8(i*40)})}
        }
        if box(ctx,{width=FIT,height=FIT,align_y=.Baseline}) {
            if box(ctx,{width=FIT,height=FIT,align_y=.Baseline}) {}
            text(ctx,"",{size=12})
        }
        text_begin(ctx,{size=12})
    }
    input:=test_input()
    for _ in 0..<2 {test_frame(&ctx,&input,build)}
    testing.expect(t,ctx.stats.layout_errors>0,"a text left open is counted")
    for width in ([]f32{nan,-1,0,max(f32)}) {
        height:=text_height(&ctx,"numbers that are none",{size=12,wrap=.Words},width)
        testing.expect(t,height>=12*TEXT_LINE)
    }
}

@(test)
a_row_puts_the_first_lines_of_its_children_on_one_baseline :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        white:=Color{255,255,255,255}
        if box(ctx,{id=id(ctx,"row"),width=FIT,height=FIT,gap=4,align_y=.Baseline,padding=padding_all(5),track=true}) {
            text(ctx,"Score",{size=12,color=white},id=id(ctx,"small"))
            text(ctx,"1200",{size=30,color=white},id=id(ctx,"large"))
            test_leaf(ctx,"mark",0,{width=fixed(8),height=fixed(8)})
            if box(ctx,{id=id(ctx,"chip"),width=FIT,height=FIT,direction=.Column,padding=padding_all(3),track=true}) {
                text(ctx,"x2",{size=16,color=white},id=id(ctx,"inner"))
                text(ctx,"bonus",{size=9,color=white})
            }
            test_leaf(ctx,"own",0,{width=fixed(8),height=fixed(8),self_y=.End})
        }
        // Without it the row centers them, as ever.
        if box(ctx,{id=id(ctx,"centered"),width=FIT,height=FIT,align_y=.Center,float={to=.Surface,offset={0,200}}}) {
            text(ctx,"Score",{size=12,color=white},id=id(ctx,"centered small"))
            text(ctx,"1200",{size=30,color=white},id=id(ctx,"centered large"))
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build)
    ascent:=face_ascent(&ctx.font,0)
    large:=test_rect(t,&ctx,id(&ctx,"large"))
    baseline:=large.y+ascent*30
    testing.expect(t,test_near(large.y,5))
    small:=test_rect(t,&ctx,id(&ctx,"small"))
    testing.expectf(t,test_near(small.y+ascent*12,baseline),"small text: %v under %v",small.y+ascent*12,baseline)
    mark:=test_rect(t,&ctx,id(&ctx,"mark"))
    testing.expectf(t,test_near(mark.y+mark.h,baseline),"what has no text stands on the baseline: %v",mark)
    inner:=test_rect(t,&ctx,id(&ctx,"inner"))
    testing.expectf(t,test_near(inner.y+ascent*16,baseline),"the first line inside a container: %v",inner)
    // The row is as high as what goes over the baseline and what hangs under it.
    chip:=test_rect(t,&ctx,id(&ctx,"chip"))
    row:=test_rect(t,&ctx,id(&ctx,"row"))
    testing.expect(t,test_near(row.h,max(large.y+large.h,chip.y+chip.h)-row.y+5))
    own:=test_rect(t,&ctx,id(&ctx,"own"))
    testing.expect(t,test_near(own.y+own.h,row.y+row.h-5),"A child that aligns itself keeps its own place")
    a,b:=test_rect(t,&ctx,id(&ctx,"centered small")),test_rect(t,&ctx,id(&ctx,"centered large"))
    testing.expect(t,test_near(a.y+a.h*0.5,b.y+b.h*0.5))
}

@(test)
a_grid_takes_the_heights_of_its_row_tracks_and_children_span_rows :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        // A child of two rows keeps its column in the row under it, and the children after it flow around it.
        if box(ctx,{id=id(ctx,"spans"),width=fixed(320),height=FIT,direction=.Grid,columns=3,gap=10,align_x=.Start,align_y=.Start,track=true}) {
            if box(ctx,{id=id(ctx,"tall"),width=GROW,height=fixed(50),row_span=2,track=true}) {}
            test_leaf(ctx,"b",0,{width=GROW,height=fixed(10)})
            test_leaf(ctx,"c",0,{width=GROW,height=fixed(12)})
            test_leaf(ctx,"wide",0,{width=GROW,height=fixed(10),span=2})
            test_leaf(ctx,"next",0,{width=GROW,height=fixed(10)})
            if box(ctx,{id=id(ctx,"filled"),width=GROW,height=GROW,row_span=2,span=2,track=true}) {}
            test_leaf(ctx,"last",0,{width=GROW,height=fixed(20)})
        }
        // Rows of a fixed height, of the height of their children and of what is left by their weights.
        rows:=grid_rows_add(ctx,{count=4,rows={0=fixed(30),1=FIT,2=GROW,3={kind=.Grow,value=3}}})
        if box(ctx,{id=id(ctx,"rows"),width=fixed(100),height=fixed(200),direction=.Grid,columns=1,row_tracks=rows,gap=10,track=true,float={to=.Surface,offset={400,0}}}) {
            test_leaf(ctx,"fixed",0,{width=GROW,height=GROW})
            test_leaf(ctx,"fit",0,{width=GROW,height=fixed(20)})
            test_leaf(ctx,"one",0,{width=GROW,height=GROW})
            test_leaf(ctx,"three",0,{width=GROW,height=percent(0.5)})
            test_leaf(ctx,"after",0,{width=GROW,height=fixed(8)})
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    cell:=f32(320-20)/3
    rect :: proc(t:^testing.T,ctx:^Context,name:string) -> Rect {return test_rect(t,ctx,id(ctx,name))}
    testing.expect_value(t,rect(t,&ctx,"tall"),Rect{0,0,cell,50})
    testing.expect(t,test_rect_near(rect(t,&ctx,"b"),{cell+10,0,cell,10}) && test_rect_near(rect(t,&ctx,"c"),{2*(cell+10),0,cell,12}))
    // The first row is as high as its children of one row; the second takes what the tall one still needs.
    wide:=rect(t,&ctx,"wide")
    testing.expectf(t,test_rect_near(wide,{cell+10,12+10,2*cell+10,10}),"beside the tall one: %v",wide)
    next:=rect(t,&ctx,"next")
    testing.expectf(t,test_rect_near(next,{0,12+10+28+10,cell,10}),"under the tall one: %v",next)
    // What grows takes the rows and the columns it spans, with their gaps.
    filled,last:=rect(t,&ctx,"filled"),rect(t,&ctx,"last")
    testing.expectf(t,test_rect_near(filled,{cell+10,60,2*cell+10,10+10+20}) && test_rect_near(last,{0,80,cell,20}),"filled %v, last %v",filled,last)
    testing.expect_value(t,rect(t,&ctx,"spans").h,f32(100))
    // 200 high: 30, 20 and 8 are taken with four gaps, and 102 is shared by one to three.
    testing.expect(t,test_rect_near(rect(t,&ctx,"fixed"),{400,0,100,30}) && test_rect_near(rect(t,&ctx,"fit"),{400,40,100,20}))
    one,three:=rect(t,&ctx,"one"),rect(t,&ctx,"three")
    testing.expectf(t,test_near(one.y,70) && test_near(one.h,25.5,0.05) && test_near(three.y,105.5,0.05) && test_near(three.h,76.5*0.5,0.05),"one %v, three %v",one,three)
    testing.expectf(t,test_near(rect(t,&ctx,"after").y,192,0.05),"after %v in %v",rect(t,&ctx,"after"),rect(t,&ctx,"rows"))
}
