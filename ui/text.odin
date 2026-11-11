package ui

import "core:math"
import "core:unicode/utf8"

// Text is one leaf of the layout: spans of words in their styles, with boxes
// in their lines, which the layout measures once for what they say, breaks
// into lines at the width it gives the leaf and whose height it takes in the
// same frame. A label, a block of text, rich text and Markdown are this leaf
// with different spans.

// What a span of a text is drawn with. size 0: the font, the size and the
// color of its text.
Text_Span :: struct {
    font:u8,
    size:f32,
    color:Color,
    decoration:Text_Decorations,
    back:Color,   // behind it, as tall as height, or as its line when height is 0
    radius:f32,   // of the corners of back
    pad:f32,      // a chip: room beside its text, half on each side, which does not break at spaces
    height:f32,   // of a chip
    solid:bool,   // its text breaks at no space: in a text that cuts, where each line ends (code)
}

// The text being built between text_begin and text_end.
@(private)
Text_Open :: struct {
    open,measure,hits:bool,
    style:Text_Style,
}

// Starts a text of a style: the spans put until text_end are what it says.
// line: the box of its lines when the style does not say it. cut: a word wider
// than a line goes on in the next one. measure: nothing is built; end it with
// text_end_height. False when the frame has no room for it, and then the
// spans and the end do nothing.
text_begin :: proc(ctx:^Context,style:Text_Style,line:f32=0,cut:=false,measure:=false) -> bool {
    o:=&ctx.text_open
    if o.open {ctx.stats.layout_errors+=1;return false}
    t:=&ctx.layout
    if measure {
        // Before the layout of the frame starts, its rows are free.
        if !ctx.layout_started {t.text_count,t.span_count=0,0}
    } else {
        if ctx.skipped>0 || ctx.elements+ELEMENT_RESERVE>=ctx.max_elements {
            if ctx.skipped==0 {ctx.stats.dropped_elements+=1}
            return false
        }
        layout_start(ctx)
    }
    box:=line
    if box<=0 {
        // In whole units when it is one within a thousandth.
        box=style.size*(style.line_height if style.line_height>0 else TEXT_LINE)
        if whole:=math.round(box);abs(box-whole)<1e-3 {box=whole}
    }
    desc:=Layout_Text_Desc{size=style.size,line=box,wrap=style.wrap,cut=cut,ellipsis=style.ellipsis,align_x=style.align_x,align_y=style.align_y}
    if !layout_text_begin(t,desc) {
        ctx.stats.dropped_elements+=1
        return false
    }
    o^={open=true,measure=measure,style=style}
    return true
}

@(private)
text_put :: proc(ctx:^Context,s:Layout_Span) {
    o:=&ctx.text_open
    s:=s
    if s.size<=0 {s.font,s.size,s.color=o.style.font,o.style.size,o.style.color}
    t:=&ctx.layout
    // Every span after the first takes the room of an element.
    if !o.measure && t.texts[t.text_count].spans_len>0 {
        if ctx.elements+ELEMENT_RESERVE>=ctx.max_elements {ctx.stats.dropped_elements+=1;return}
        ctx.elements+=1
    }
    o.hits||=s.widget!=0
    if !layout_text_span(t,&ctx.font,s) {ctx.stats.dropped_elements+=1}
}

// The widget the last interact registered for id, plus one: what a span of a
// text gives its pieces to.
@(private)
text_widget :: proc(ctx:^Context,id:Id) -> i32 {
    if id==0 || ctx.widget_count==0 || ctx.widgets[ctx.widget_count-1].id!=id {return 0}
    return i32(ctx.widget_count)
}

// Words of the text begun, in its style or in that of span.
text_span :: proc(ctx:^Context,content:string,span:Text_Span={}) {
    text_span_widget(ctx,content,span,0)
}
// Words of the text begun that take the pointer as the widget id, on every
// line they end up on: a link.
text_link :: proc(ctx:^Context,id:Id,content:string,span:Text_Span={}) -> Interaction {
    if !ctx.text_open.open || ctx.text_open.measure {
        text_span(ctx,content,span)
        return {}
    }
    it:=interact(ctx,id)
    text_span_widget(ctx,content,span,text_widget(ctx,id))
    return it
}
@(private)
text_span_widget :: proc(ctx:^Context,content:string,span:Text_Span,widget:i32) {
    o:=&ctx.text_open
    if !o.open || content=="" {return}
    stored:=content if o.measure else text_store(ctx,content)
    if stored!="" {text_put(ctx,{text=stored,look=span,widget=widget})}
}
// Room as wide as a space of the text begun, where a word ends: what joins two
// lines of its source.
text_space :: proc(ctx:^Context) {
    o:=&ctx.text_open
    if !o.open {return}
    text_put(ctx,{width=text_width(&ctx.font," ",o.style.size,int(o.style.font))})
}
// A box in the line of the text begun, which does not break: an image, a
// pill. gap: room after it. After interact(ctx,id), it takes the pointer as
// that widget.
text_box :: proc(ctx:^Context,width,height:f32,paint:Paint,id:Id=0,gap:f32=0) {
    o:=&ctx.text_open
    if !o.open {return}
    s:=Layout_Span{box=true,width=width,gap=gap,look={height=height}}
    if !o.measure {s.paint,s.widget=paint_add(ctx,paint),text_widget(ctx,id)}
    text_put(ctx,s)
}

// Ends the text begun as an element of layout. reveal: the part of its
// characters drawn, 0 to 1, each where the whole text puts it. fade: a line
// wider than the element fades out at its end.
text_end :: proc(ctx:^Context,layout:Layout={},id:Id=0,reveal:f32=1,fade:=false) {
    o:=&ctx.text_open
    if !o.open {return}
    o.open=false
    t:=&ctx.layout
    text:=&t.texts[t.text_count]
    if o.measure {
        t.span_count=int(text.spans_first)
        return
    }
    revealed:i32
    if reveal<1 {
        total:=0
        for &s in t.spans[text.spans_first:][:text.spans_len] {total+=1 if s.box else utf8.rune_count_in_string(s.text)}
        revealed=i32(math.round(f32(total)*max(reveal,0)))+1
    }
    paint:=paint_add(ctx,{kind=.None,style=o.style,fade=fade,revealed=revealed})
    if paint!=nil && text.spans_len==1 {paint.text=t.spans[text.spans_first].text}
    widget_add(ctx,id,{.Passive})
    text.hits=o.hits
    if paint==nil || !layout_text_end(t,&ctx.font,{id=id,layout=layout,custom=paint}) {
        t.span_count=int(text.spans_first)
        ctx.stats.dropped_elements+=1
        return
    }
    ctx.elements+=1
}
// Ends a text begun to measure: the height its lines take in an element of
// width, which is no narrower than its widest word.
text_end_height :: proc(ctx:^Context,width:f32) -> f32 {
    o:=&ctx.text_open
    if !o.open {return 0}
    o.open=false
    t:=&ctx.layout
    text:=&t.texts[t.text_count]
    _,least:=layout_text_ask(t,&ctx.font,text)
    height:=layout_text_wrap(t,&ctx.font,text,max(width,least),false)
    t.span_count=int(text.spans_first)
    return height
}

// Text in a style inside a box of width by height. A FIT width is the width
// of the text on one line, and a text that wraps breaks down to its widest
// word when its parent is narrower; any other width is what the layout gives
// it, and the text breaks to it. A FIT height holds the lines it takes.
// reveal: the part of its characters drawn, 0 to 1, each where the whole text
// puts it (a typewriter).
text :: proc(ctx:^Context,content:string,style:Text_Style,width:Size=FIT,height:Size=FIT,id:Id=0,reveal:f32=1) {
    if !text_begin(ctx,style) {return}
    text_span(ctx,content)
    text_end(ctx,{width=width,height=height},id,reveal)
}

// Height of content as text lays it out in width, without building it: the
// same measure and the same breaks.
text_height :: proc(ctx:^Context,content:string,style:Text_Style,width:f32) -> f32 {
    if !text_begin(ctx,style,measure=true) {return 0}
    text_span(ctx,content)
    return text_end_height(ctx,width)
}

// The style of the running text of the editor: wrapped, its lines
// PARAGRAPH_LINE sizes apart in whole units. size: font_small when 0; color:
// text_muted when transparent.
prose :: proc(ctx:^Context,size:f32=0,color:Color={},font:u8=0) -> Text_Style {
    size:=size if size>0 else metric(ctx,"font_small")
    return {font=font,size=size,color=color if color!={} else tone(ctx,"text_muted"),wrap=.Words,line_height=math.floor(size*PARAGRAPH_LINE)/size}
}

// ---------------------------------------------------------------- drawing

// The characters a text says before a piece, a box counting as one.
@(private)
text_chars_before :: proc(t:^Layout_Tree,text:^Layout_Text,piece:^Layout_Piece) -> int {
    count:=0
    for &s in t.spans[text.spans_first:piece.span] {count+=1 if s.box else utf8.rune_count_in_string(s.text)}
    return count+utf8.rune_count_in_string(t.spans[piece.span].text[:piece.start])
}

// The style a piece of a span is drawn in.
@(private)
text_piece_style :: #force_inline proc(p:^Paint,s:^Layout_Span) -> (style:Text_Style,decoration:Text_Decorations) {
    style=p.style
    style.font,style.size,style.color=s.font,s.size,s.color
    return style,p.decoration+s.decoration
}

// Draws a line of a text where the layout placed it.
@(private)
text_draw_line :: proc(ctx:^Context,n:^Layout_Node,index:i32) {
    p:=cast(^Paint)n.custom
    if p==nil || p.hidden {return}
    t:=&ctx.layout
    text:=&t.texts[n.text]
    line:=&t.lines[index]
    pieces:=t.pieces[line.pieces_first:][:line.pieces_len]
    font:=&ctx.font
    r:=n.box
    limit:=int(p.revealed)-1
    if limit==0 {return}
    paint_select(ctx,p.surface,p.scope)
    x:=line.x
    // A line that is cut ends in an ellipsis, in the style of the piece it is
    // cut in: after as much of its text as leaves it room (cut_length), or in
    // the place of a box that does not.
    cut_piece,cut_length:=-1,0
    cut_width:f32
    if line.cut {
        for &piece,i in pieces {
            s:=&t.spans[piece.span]
            style,_:=text_piece_style(p,s)
            dots:=text_width(font,ELLIPSIS,style.size,int(style.font))
            room:=r.w-dots-piece.x
            last:=i==len(pieces)-1
            cut_piece=i
            if s.box {
                fits:=piece.width<=room
                cut_length,cut_width=1 if fits else 0,piece.width if fits else 0
                if !fits || last {break}
                continue
            }
            shown:=s.text[piece.start:][:piece.length]
            cut_length,cut_width=text_prefix(font,shown,style.size,room-s.pad,int(style.font))
            cut_width+=s.pad
            if cut_length<len(shown) || last {
                x=r.x+align_offset(text.align_x,r.w-(piece.x+cut_width+dots))
                break
            }
        }
    }
    wide:=line.width>r.w+LAYOUT_EPSILON
    clipped:=wide || text.height>r.h+LAYOUT_EPSILON
    d:=&ctx.draw
    fade:=d.fade
    if clipped {
        if p.fade && wide {
            d.fade={r.x+r.w-TEXT_FADE,r.x+r.w}
            clip_push(ctx,r)
        } else {
            margin:=p.style.outline+max(abs(p.style.shadow.x),abs(p.style.shadow.y))+(p.style.size*TEXT_ITALIC if .Italic in p.decoration else 0)
            clip_push(ctx,{r.x-margin,r.y-margin,r.w+2*margin,r.h+2*margin})
        }
    }
    defer if clipped {
        clip_pop(ctx)
        d.fade=fade
    }
    for &piece,i in pieces {
        s:=&t.spans[piece.span]
        left:=-1
        if limit>0 {
            left=limit-text_chars_before(t,text,&piece)
            if left<=0 {return}
        }
        style,decoration:=text_piece_style(p,s)
        px,py:=x+piece.x,line.y+piece.y
        if s.box {
            if (cut_piece!=i || cut_length>0) && s.paint!=nil {
                paint_draw(ctx,{px,py,piece.width,s.height if s.height>0 else line.height},s.paint)
            }
            if cut_piece==i {
                draw_text_decorated(ctx,ELLIPSIS,px+cut_width,line.y+text_leading(style.size,line.height),style,decoration)
                return
            }
            continue
        }
        if s.back[3]>0 {
            high:=s.height if s.height>0 else line.height
            draw_rounded(ctx,{px,line.y+(line.height-high)*0.5,piece.width,high},s.radius,s.back)
        }
        end:=px+cut_width
        if s.pad>0 {
            px+=s.pad*0.5
            py+=text_leading(style.size,s.height if s.height>0 else style.size*TEXT_LINE)
        }
        shown:=s.text[piece.start:][:piece.length]
        whole:=true
        if cut_piece==i {shown=shown[:cut_length]}
        if left>=0 {
            count:=0
            for _,at in shown {
                if count==left {shown,whole=shown[:at],false;break}
                count+=1
            }
        }
        draw_text_decorated(ctx,shown,px,py,style,decoration)
        if cut_piece==i {
            if whole {draw_text_decorated(ctx,ELLIPSIS,end,py,style,decoration)}
            return
        }
    }
}

// After the layout: the pieces of the spans that take the pointer are the
// widgets of their spans, one for each piece on each line.
@(private)
text_widgets_place :: proc(ctx:^Context) {
    t:=&ctx.layout
    ctx.widget_pieces=ctx.widget_count
    for &text in t.texts[:t.text_count] {
        if !text.hits {continue}
        for &line in t.lines[text.lines_first:][:text.shown] {
            for &piece in t.pieces[line.pieces_first:][:line.pieces_len] {
                s:=&t.spans[piece.span]
                widget:=s.widget
                if widget==0 {continue}
                rect:=Rect{line.x+piece.x,line.y,piece.width,line.height}
                w:=&ctx.widgets[widget-1]
                if w.rect.h==0 {
                    w.rect=rect
                    continue
                }
                if ctx.widget_count>=len(ctx.widgets) {ctx.stats.dropped_widgets+=1;continue}
                other:=w^
                other.rect,other.piece_of=rect,widget
                ctx.widgets[ctx.widget_count]=other
                ctx.widget_count+=1
            }
        }
    }
}
