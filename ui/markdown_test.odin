package ui

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"

@(private="file")
TEST_MARKDOWN :: Context_Desc{max_elements=32768,max_widgets=4096,max_text=1<<18,max_vertices=1<<18,max_commands=1024}

// A context whose font measures without rasterizing: a font on demand it borrows.
@(private="file")
test_markdown_context :: proc(t:^testing.T,ctx:^Context,owner:^Font,desc:=TEST_MARKDOWN) -> bool {
    desc:=desc
    if !testing.expect(t,font_init(owner,nil,nil,1,on_demand=true)) {return false}
    desc.font=owner
    if !testing.expect(t,context_init(ctx,desc)) {font_destroy(owner);return false}
    return true
}

// Entities are pills that select, assets pills that open with a name of
// their own; an entity that is gone is a pill that leads nowhere.
@(private="file")
test_markdown_resolve :: proc(data:rawptr,target,text:string,buffer:[]u8) -> Markdown_Link {
    switch {
    case target=="entity:9": return {pill=true}
    case strings.has_prefix(target,"entity:"): return {pill=true,live=true,selected=target=="entity:7"}
    case strings.has_prefix(target,"asset:"): return {label=fmt.bprintf(buffer,"%s (asset)",text),pill=true,live=true}
    case strings.has_prefix(target,"play:"): return {pill=true,live=true,button=true,icon=.Play}
    }
    return {live=true}
}

@(private="file")
TEST_MARKDOWN_TEXTS :: [?]string{
    "",
    "One line",
    "The agent changed the material of the cube and moved the sphere half a metre to the right so that both sit on the grid.\nA second line of the same paragraph.\n\nAnother paragraph.",
    "# Title\n\nSome **bold** and `code` and *em* text.\n\n## Sub\n### Third\n#### Fourth ##",
    "- one\n- two with a longer line that wraps around\n  - nested\n    1. deep\n- three\n\n1. first\n2) second\n\n   continued after a blank\n\nAfter the list",
    "> quoted line\n> more\n>\n> second paragraph\nlazy line\n\nafter the quote",
    "```odin\nmain :: proc() {\n\tfmt.println(\"a very long line of code that has to wrap at characters\")\n\n}\n```\nafter",
    "above\n\n---\n\nbelow\n***",
    "Moved [Crate 4](entity:7) beside [Table](entity:9). See [the docs of the engine](https://example.com/a/very/long/path) and [Wet stone](asset:materials/Wet stone.mat).",
    "Averyveryverylongwordthatdoesnotfitinanynarrowline and `averylongcodespanthatdoesnotfitanywhere` too",
    "\\*not em\\* and __bold__ and snake_case_name and 2 * 3 * 4 and ***both*** and **unclosed",
    "```\ncode without an end\n\n- not a list",
    "<div>html</div>\n| a | b |\n|---|---|",
    "- item\n\n  ```\n  line one\n  \tline two\n  ```\n- [Point Light 1](entity:3)",
}

@(test)
markdown_height_is_the_height_markdown_builds :: proc(t:^testing.T) {
    ctx:Context
    owner:Font
    if !test_markdown_context(t,&ctx,&owner) {return}
    defer {context_destroy(&ctx);font_destroy(&owner)}
    Case :: struct {text:string,width:f32,style:Markdown_Style}
    Test_Cases :: struct {cases:[]Case}
    texts:=TEST_MARKDOWN_TEXTS
    widths:=[]f32{40,90,181,320,600}
    cases:[len(TEST_MARKDOWN_TEXTS)*5*2]Case
    count:=0
    for text in texts {
        for width,i in widths {
            cases[count]={text,width,{resolve=test_markdown_resolve}};count+=1
            cases[count]={text,width,{size=13 if i%2==0 else 9}};count+=1
        }
    }
    s:=Test_Cases{cases[:count]}
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Test_Cases)user
        if panel(ctx,id(ctx,"panel"),{width=fixed(700),height=FIT,bare=true}) {
            for c,i in s.cases {
                if box(ctx,{id=id(ctx,"case",i+1),width=fixed(c.width),height=FIT,direction=.Column,track=true}) {
                    markdown(ctx,id(ctx,"markdown",i+1),c.text,c.width,c.style)
                }
            }
        }
    }
    input:=test_input(800,60000)
    test_frame(&ctx,&input,build,&s)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    testing.expect_value(t,dropped_total(&ctx.stats),u32(0))
    for c,i in s.cases {
        rect:=test_rect(t,&ctx,id(&ctx,"case",i+1))
        expected:=markdown_height(&ctx,c.text,c.width,c.style)
        testing.expectf(t,test_near(rect.h,expected),"%q at %v: built %v, measured %v",c.text,c.width,rect.h,expected)
        testing.expectf(t,c.text=="" || expected>0,"%q has a height",c.text)
    }
}

@(private="file")
Test_Markdown :: struct {text:string,width:f32,style:Markdown_Style,clicked:string,clipboard:[256]u8,clipboard_length:int}
@(private="file")
test_markdown_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Markdown)user
    if panel(ctx,id(ctx,"panel"),{width=fixed(s.width),height=FIT,bare=true}) {
        if clicked:=markdown(ctx,id(ctx,"markdown"),s.text,s.width,s.style);clicked!="" {s.clicked=clicked}
    }
}
@(private="file")
test_markdown_paint :: proc(ctx:^Context,text:string) -> ^Paint {
    for &p in ctx.paints[:ctx.paint_count] {if strings.trim_right(p.text," ")==text {return &p}}
    return nil
}

@(test)
markdown_lays_out_each_kind_of_block :: proc(t:^testing.T) {
    ctx:Context
    owner:Font
    if !test_markdown_context(t,&ctx,&owner) {return}
    defer {context_destroy(&ctx);font_destroy(&owner)}
    th:=&ctx.theme
    body:=th.font_small
    line:=math.floor(body*PARAGRAPH_LINE)
    s:=Test_Markdown{width=600,text="# Big\n\n## Middle\n\n### Small\n\nSome **strong** words, *em* and _em_ too, `a_code` and <b>tags</b>.\nSame paragraph.\n\n- bullet\n  - nested\n\n3. third\n\n> quoted\n\n---\n\n```odin\nx := 1\n```"}
    input:=test_input(800,2000)
    test_frame(&ctx,&input,test_markdown_build,&s)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    big,middle,small:=test_markdown_paint(&ctx,"Big"),test_markdown_paint(&ctx,"Middle"),test_markdown_paint(&ctx,"Small")
    if testing.expect(t,big!=nil && middle!=nil && small!=nil,"Headings are text") {
        testing.expect(t,big.style.font==FONT_SEMIBOLD && middle.style.font==FONT_SEMIBOLD && small.style.font==FONT_SEMIBOLD)
        testing.expect(t,big.size>middle.size && middle.size>small.size && small.size>body,"Headings grow from the body")
    }
    strong:=test_markdown_paint(&ctx,"strong")
    testing.expect(t,strong!=nil && strong.style.font==FONT_SEMIBOLD,"Bold is SemiBold")
    testing.expect(t,test_markdown_paint(&ctx,"Some")!=nil && test_markdown_paint(&ctx,"Some").style.font==FONT_REGULAR)
    for &p in ctx.paints[:ctx.paint_count] {
        testing.expectf(t,strings.index_byte(p.text,'*')<0 && strings.index(p.text,"_em_")<0,"The markers of emphasis are left out: %q",p.text)
    }
    code:=test_markdown_paint(&ctx,"a_code")
    testing.expect(t,code!=nil && code.kind==.Box && code.style.font==FONT_MONO && code.fill==th.chip_on,"Inline code is a chip in the monospace face")
    html:=false
    for &p in ctx.paints[:ctx.paint_count] {if strings.contains(p.text,"<b>tags</b>.") {html=true}}
    testing.expect(t,html,"HTML stays as text")
    testing.expect(t,test_markdown_paint(&ctx,"Same paragraph.")!=nil,"A paragraph goes on in its next line")
    bullets:=0
    for &p in ctx.paints[:ctx.paint_count] {if p.text=="•" {bullets+=1}}
    testing.expect_value(t,bullets,2)
    testing.expect(t,test_markdown_paint(&ctx,"3.")!=nil,"An ordered item shows its number")
    quoted:=test_markdown_paint(&ctx,"quoted")
    testing.expect(t,quoted!=nil && quoted.text_color==th.text_muted)
    rules,bars:=0,0
    for &p in ctx.paints[:ctx.paint_count] {
        if p.kind==.Rect && p.fill==th.divider {rules+=1}
        if p.kind==.Rect && p.fill==th.border {bars+=1}
    }
    testing.expect_value(t,rules,1)
    testing.expect_value(t,bars,1)
    mono:=test_markdown_paint(&ctx,"x := 1")
    testing.expect(t,mono!=nil && mono.style.font==FONT_MONO,"Code is in the monospace face")
    block:=false
    for &p in ctx.paints[:ctx.paint_count] {if p.fill==th.well && p.radius==th.radius_popup {block=true}}
    testing.expect(t,block,"A code block has a darker rounded background")
    // A line break inside a paragraph is a space: these are one line each.
    testing.expect_value(t,markdown_height(&ctx,"one\ntwo",600),line)
    testing.expect_value(t,markdown_height(&ctx,"one\n\ntwo",600),2*line+math.floor(body*2/3))
}

@(test)
markdown_pills_do_not_break_and_wrap_whole :: proc(t:^testing.T) {
    ctx:Context
    owner:Font
    if !test_markdown_context(t,&ctx,&owner) {return}
    defer {context_destroy(&ctx);font_destroy(&owner)}
    body:=ctx.theme.font_small
    line:=math.floor(body*PARAGRAPH_LINE)
    name:="Point Light 1"
    pill:=text_width(&ctx.font,name,body)+2*MARKDOWN_PILL_PAD
    before:=text_width(&ctx.font,"Moved the ",body)
    s:=Test_Markdown{text="Moved the [Point Light 1](entity:7) over.",style={resolve=test_markdown_resolve}}
    s.width=math.ceil(before+pill*0.5)
    input:=test_input(800,600)
    test_frame(&ctx,&input,test_markdown_build,&s)
    test_frame(&ctx,&input,test_markdown_build,&s)
    markdown_id:=id(&ctx,"markdown")
    r:=test_rect(t,&ctx,id_derive(&ctx,markdown_id,"link",1))
    testing.expect(t,test_near(r.w,pill) && test_near(r.h,line),"A pill keeps its whole name")
    testing.expectf(t,test_near(r.y,line) && test_near(r.x,0),"The pill goes whole to the next line: %v",r)
    p:=test_markdown_paint(&ctx,name)
    testing.expect(t,p!=nil && p.stroke==ctx.theme.text,"The selected pill is outlined")
    // Wider than the line, it is cut to the line.
    s.width=pill*0.5
    test_frame(&ctx,&input,test_markdown_build,&s)
    test_frame(&ctx,&input,test_markdown_build,&s)
    r=test_rect(t,&ctx,id_derive(&ctx,markdown_id,"link",1))
    testing.expect(t,test_near(r.w,s.width) && test_near(r.x,0))
    // A label resolve writes replaces the text of the link.
    testing.expect(t,markdown_height(&ctx,"[Wet stone](asset:a.mat)",1000,{resolve=test_markdown_resolve})==line)
    s.text,s.width="[Wet stone](asset:a.mat)",1000
    test_frame(&ctx,&input,test_markdown_build,&s)
    testing.expect(t,test_markdown_paint(&ctx,"Wet stone (asset)")!=nil)
}

@(test)
markdown_reports_the_target_of_a_live_link_clicked :: proc(t:^testing.T) {
    ctx:Context
    owner:Font
    if !test_markdown_context(t,&ctx,&owner) {return}
    defer {context_destroy(&ctx);font_destroy(&owner)}
    s:=Test_Markdown{width=600,text="See [the docs](https://example.com), [Crate](entity:7) and [Gone](entity:9).",style={resolve=test_markdown_resolve}}
    input:=test_input(800,600)
    test_frame(&ctx,&input,test_markdown_build,&s)
    test_frame(&ctx,&input,test_markdown_build,&s)
    markdown_id:=id(&ctx,"markdown")
    click :: proc(t:^testing.T,ctx:^Context,input:^Input,s:^Test_Markdown,link:Id) -> string {
        s.clicked=""
        test_point(input,test_rect(t,ctx,link))
        test_frame(ctx,input,test_markdown_build,s)
        test_press(input)
        test_frame(ctx,input,test_markdown_build,s)
        test_release(input)
        test_frame(ctx,input,test_markdown_build,s)
        return s.clicked
    }
    testing.expect_value(t,click(t,&ctx,&input,&s,id_derive(&ctx,markdown_id,"link",1)),"https://example.com")
    testing.expect_value(t,click(t,&ctx,&input,&s,id_derive(&ctx,markdown_id,"link",2)),"entity:7")
    _,gone:=widget_rect(&ctx,id_derive(&ctx,markdown_id,"link",3))
    testing.expect(t,!gone && test_markdown_paint(&ctx,"Gone")!=nil,"A pill that leads nowhere is shown and takes no pointer")
    // Under the pointer a link is lit.
    test_point(&input,test_rect(t,&ctx,id_derive(&ctx,markdown_id,"link",1)))
    test_frame(&ctx,&input,test_markdown_build,&s)
    lit:=test_markdown_paint(&ctx,"the docs")
    testing.expect(t,lit!=nil && lit.fill==ctx.theme.chip_on && lit.text_color==ctx.theme.accent)
}

@(test)
markdown_wraps_a_long_line_of_code_at_characters :: proc(t:^testing.T) {
    ctx:Context
    owner:Font
    if !test_markdown_context(t,&ctx,&owner) {return}
    defer {context_destroy(&ctx);font_destroy(&owner)}
    body:=ctx.theme.font_small
    size:=body-1
    line:=math.floor(size*MARKDOWN_CODE_LINE)
    pad:=math.floor(body*2/3)
    code:="0123456789012345678901234567890123456789"
    text:="```\n0123456789012345678901234567890123456789\n```"
    advance:=text_width(&ctx.font,"0",size,FONT_MONO)
    testing.expect(t,test_near(text_width(&ctx.font,code,size,FONT_MONO),40*advance,0.05),"Digits of the monospace face are as wide as each other")
    testing.expect_value(t,markdown_height(&ctx,text,2*pad+41*advance),line+2*pad)
    // Ten characters to a line: four lines.
    testing.expect_value(t,markdown_height(&ctx,text,2*pad+10.5*advance),4*line+2*pad)
    s:=Test_Markdown{text=text,width=2*pad+10.5*advance}
    input:=test_input(800,600)
    test_frame(&ctx,&input,test_markdown_build,&s)
    testing.expect(t,test_markdown_paint(&ctx,"0123456789")!=nil,"Each line holds the characters that fit")
}

@(test)
markdown_breaks_lines_at_spaces_and_inside_a_word_wider_than_the_line :: proc(t:^testing.T) {
    ctx:Context
    owner:Font
    if !test_markdown_context(t,&ctx,&owner) {return}
    defer {context_destroy(&ctx);font_destroy(&owner)}
    body:=ctx.theme.font_small
    line:=math.floor(body*PARAGRAPH_LINE)
    width :: proc(ctx:^Context,text:string) -> f32 {return text_width(&ctx.font,text,ctx.theme.font_small)}
    // fits: the widest text that still fits its line; first: what the first line then shows.
    Case :: struct {text,fits,first:string,lines:f32}
    cases:=[]Case{
        {"one two three","one two three","one two three",1},
        {"one two three","one two thre","one two",2},
        // What no space parts moves to the next line together, whatever its styles.
        {"one two**bold**.","one twobold","one",2},
        {"one two[link](target).","one twolink","one",2},
        // A word wider than the line goes on in the next one.
        {"aaaaaaaaaaaaaaaaaaaa","aaaaaaaaaa","aaaaaaaaaa",2},
        {"x aaaaaaaaaaaaaaaaaaaa","aaaaaaaaaa","x",3},
    }
    input:=test_input(800,600)
    for c in cases {
        s:=Test_Markdown{text=c.text,width=width(&ctx,c.fits)+0.5}
        testing.expectf(t,markdown_height(&ctx,s.text,s.width)==c.lines*line,"%q in the width of %q: %v lines",c.text,c.fits,markdown_height(&ctx,s.text,s.width)/line)
        test_frame(&ctx,&input,test_markdown_build,&s)
        testing.expectf(t,test_markdown_paint(&ctx,c.first)!=nil,"%q in the width of %q starts with %q",c.text,c.fits,c.first)
    }
}

@(test)
markdown_copies_the_code_of_a_block_under_the_pointer :: proc(t:^testing.T) {
    ctx:Context
    owner:Font
    desc:=TEST_MARKDOWN
    s:=Test_Markdown{width=400,text="- item\n\n  ```\n  line one\n  \tline two\n  ```"}
    desc.clipboard_user=&s
    desc.clipboard_set=proc(user:rawptr,text:string) {s:=cast(^Test_Markdown)user;s.clipboard_length=copy(s.clipboard[:],text)}
    if !test_markdown_context(t,&ctx,&owner,desc) {return}
    defer {context_destroy(&ctx);font_destroy(&owner)}
    input:=test_input(800,600)
    test_frame(&ctx,&input,test_markdown_build,&s)
    test_frame(&ctx,&input,test_markdown_build,&s)
    markdown_id:=id(&ctx,"markdown")
    copy_id:=id_derive(&ctx,markdown_id,"copy",1)
    _,shown:=widget_rect(&ctx,copy_id)
    testing.expect(t,!shown,"The copy button waits for the pointer")
    height:=test_rect(t,&ctx,id(&ctx,"panel")).h
    test_point(&input,test_rect(t,&ctx,id_derive(&ctx,markdown_id,"code",1)))
    test_frame(&ctx,&input,test_markdown_build,&s)
    test_frame(&ctx,&input,test_markdown_build,&s)
    button:=test_rect(t,&ctx,copy_id)
    testing.expect(t,test_near(test_rect(t,&ctx,id(&ctx,"panel")).h,height),"The button does not change the height")
    test_point(&input,button)
    test_frame(&ctx,&input,test_markdown_build,&s)
    test_press(&input)
    test_frame(&ctx,&input,test_markdown_build,&s)
    test_release(&input)
    testing.expect_value(t,string(s.clipboard[:s.clipboard_length]),"line one\n\tline two")
}

@(test)
markdown_builds_a_stable_frame_without_allocating :: proc(t:^testing.T) {
    ctx:Context
    owner:Font
    counter:Test_Counter
    desc:=TEST_MARKDOWN
    desc.allocator=test_counter(&counter,context.allocator)
    if !test_markdown_context(t,&ctx,&owner,desc) {return}
    defer {context_destroy(&ctx);font_destroy(&owner)}
    texts:=TEST_MARKDOWN_TEXTS
    s:=Test_Markdown{width=320,text=strings.join(texts[:],"\n\n",context.temp_allocator),style={resolve=test_markdown_resolve}}
    input:=test_input(800,4000)
    input.pointer={40,40}
    test_frame(&ctx,&input,test_markdown_build,&s)
    test_frame(&ctx,&input,test_markdown_build,&s)
    requests:=counter.requests
    test_frame(&ctx,&input,test_markdown_build,&s)
    markdown_height(&ctx,s.text,s.width,s.style)
    test_frame(&ctx,&input,test_markdown_build,&s)
    testing.expect_value(t,counter.requests,requests)
    testing.expect_value(t,dropped_total(&ctx.stats),u32(0))
}

@(test)
markdown_draws_a_button_pill_with_its_icon_in_the_fill_of_the_accent :: proc(t:^testing.T) {
    ctx:Context
    owner:Font
    if !test_markdown_context(t,&ctx,&owner) {return}
    defer {context_destroy(&ctx);font_destroy(&owner)}
    body:=ctx.theme.font_small
    name:="Try the arena"
    s:=Test_Markdown{width=600,text="[Try the arena](play:scenes/arena.scene)",style={resolve=test_markdown_resolve}}
    input:=test_input(800,600)
    test_frame(&ctx,&input,test_markdown_build,&s)
    test_frame(&ctx,&input,test_markdown_build,&s)
    r:=test_rect(t,&ctx,id_derive(&ctx,id(&ctx,"markdown"),"link",1))
    testing.expectf(t,test_near(r.w,text_width(&ctx.font,name,body)+2*MARKDOWN_PILL_PAD+body+6),"its icon widens the pill: %v",r)
    p:=test_markdown_paint(&ctx,name)
    testing.expect(t,p!=nil && p.fill==ctx.theme.accent && p.text_color==ctx.theme.on_accent && p.icon==.Play,"a button is the accent with its icon")
    testing.expect(t,markdown_height(&ctx,s.text,600,s.style)==math.floor(body*PARAGRAPH_LINE),"a button keeps the line")
}
