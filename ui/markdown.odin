package ui

import "core:math"
import "core:strings"

// Markdown laid out in a width, as the answers of an agent: paragraphs,
// headings, lists, quotes, fenced code and rules, with bold, code, links and
// pills inline. The text is parsed line by line and nothing of it is kept: each
// paragraph and each heading is one text (text.odin) whose spans are its
// words, its code, its links and its pills, which the layout breaks into
// lines; each line of fenced code is a text that breaks at no space and is
// cut where its lines end. Its height is the one the layout gives what it
// builds.

Markdown_Link :: struct {
    label:string,   // what it shows; empty: the text of the link
    pill:bool,      // a pill that does not break across lines, as the entities of an answer
    live:bool,      // it leads somewhere: lit under the pointer and reported when clicked
    selected:bool,  // a pill outlined, as what is selected
    color:Color,    // of its text; zero: the accent for a link, theme text for a pill, on_accent for a button
    icon:Icon,      // before the label of a pill
    button:bool,    // a pill that does something: the fill of the accent
}
// Called while text is built, with the same answer for the same target within a frame.
Markdown_Resolve :: #type proc(data:rawptr,target,text:string,buffer:[]u8) -> Markdown_Link
Markdown_Style :: struct {
    size:f32,                 // of the body; 0: theme.font_small
    color:Color,              // of the body; zero: theme.text_body
    resolve:Markdown_Resolve, // nil: every link is accent text, live
    data:rawptr,
}

MARKDOWN_DEPTH :: 8     // lists nested in one another; deeper items stay at the last
MARKDOWN_LABELS :: 2048 // bytes resolve writes the labels of the links of a block in
MARKDOWN_PILL_PAD :: f32(5)
MARKDOWN_PILL_GAP :: f32(2)
MARKDOWN_CHIP_PAD :: f32(3)
MARKDOWN_BAR :: f32(2)             // width of the rule left of a quote
MARKDOWN_CODE_LINE :: f32(1.5)     // line of code, in sizes
MARKDOWN_HEADING_LINE :: f32(1.35) // line of a heading, in sizes

// Builds text laid out in width. Returns the target of the link clicked this frame, or "".
markdown :: proc(ctx:^Context,id:Id,text:string,width:f32,style:Markdown_Style={}) -> (clicked:string) {
    m:Md
    md_init(&m,ctx,width,style)
    box_begin(ctx,{id=id,width=fixed(m.width),height=FIT,direction=.Column})
    id_push(ctx,id)
    md_walk(&m,text)
    id_pop(ctx)
    box_end(ctx,{})
    if m.copied>0 && ctx.clipboard_set!=nil {
        code:=make([dynamic]u8,context.temp_allocator)
        c:Md
        md_init(&c,ctx,width,style)
        c.collect,c.code=m.copied,&code
        md_walk(&c,text)
        ctx.clipboard_set(ctx.clipboard_user,string(code[:]))
    }
    return m.clicked
}

@(private="file")
Md_Block :: enum u8 {Paragraph,Heading,Code,Rule}
@(private="file")
Md_Line_Kind :: enum u8 {Text,Fence,Heading,Rule,Item}
@(private="file")
Md_List :: struct {marker,content:int} // columns of the markers of its items and of their text
@(private="file")
Md :: struct {
    ctx:^Context,
    resolve:Markdown_Resolve,
    data:rawptr,
    clicked:string,
    copied:int,       // the code block whose copy button was clicked, plus one
    collect:int,      // the code block whose text goes to code, plus one: nothing is built
    code:^[dynamic]u8,
    copy_lines:int,
    body:f32,
    color:Color,
    width:f32,
    blocks,codes,widgets:int,
    last_quote,last_depth:int,
    // The block being laid out.
    open:bool,
    block:Md_Block,
    quote,depth:int,
    room:f32,         // width of its lines
    line:f32,         // height of its lines
    size:f32,
    font:u8,
    text_color:Color,
    lines:int,        // of a block of code, as its source has them
    texting:bool,     // the text of its paragraph or heading is begun
    bold,em:int,      // where the ** and the * that close the open ones are on their line; -1: none
    labels:[MARKDOWN_LABELS]u8,labels_used:int,
}

@(private="file")
md_init :: proc(m:^Md,ctx:^Context,width:f32,style:Markdown_Style) {
    m.ctx,m.resolve,m.data,m.width=ctx,style.resolve,style.data,max(width,1)
    m.body=style.size if style.size>0 else metric(ctx,"font_small")
    m.color=style.color if style.color!={} else tone(ctx,"text_body")
    m.bold,m.em=-1,-1
}

// A face of the defaults, or the first font when the context has fonts of its own.
@(private="file")
md_face :: proc(m:^Md,f:u8) -> u8 {return f if int(f)<m.ctx.font.font_count else FONT_REGULAR}

@(private="file")
md_walk :: proc(m:^Md,text:string) {
    lists:[MARKDOWN_DEPTH]Md_List
    depth,list_quote:=0,0
    fence:u8
    fence_count,fence_indent,fence_quote:=0,0,0
    blank:=false
    rest:=text
    for len(rest)>0 {
        line:=rest
        if n:=strings.index_byte(rest,'\n');n>=0 {line,rest=rest[:n],rest[n+1:]} else {rest=""}
        if len(line)>0 && line[len(line)-1]=='\r' {line=line[:len(line)-1]}
        q:=0
        body:=line
        for fence==0 || q<fence_quote {
            s:=md_skip(body,3)
            if len(s)==0 || s[0]!='>' {break}
            q+=1;body=s[1:]
            if len(body)>0 && body[0]==' ' {body=body[1:]}
        }
        if fence!=0 {
            if q>=fence_quote {
                code:=md_skip(body,fence_indent)
                if md_fence_end(code,fence,fence_count) {md_close(m);fence=0;blank=false} else {md_code_line(m,code)}
                continue
            }
            md_close(m);fence=0
        }
        indent,content:=md_indent(body)
        if len(content)==0 {
            if m.open {md_close(m)}
            blank=true
            continue
        }
        kind:=Md_Line_Kind.Text
        first:=content[0]
        run:=md_count(content,first)
        heading:=md_heading(content)
        marker_len:=0
        if (first=='`' || first=='~') && run>=3 && (first=='~' || strings.index_byte(content[run:],'`')<0) {
            kind=.Fence
        } else if heading>0 {
            kind=.Heading
        } else if md_rule(content) {
            kind=.Rule
        } else if marker_len=md_item(content);marker_len>0 {
            kind=.Item
        }
        // A line of text goes on with the paragraph before it, also out of its quote.
        if kind==.Text && m.open && m.block==.Paragraph && !blank && q<=m.quote {
            text_space(m.ctx)
            md_inline(m,strings.trim_space(content))
            continue
        }
        if m.open {md_close(m)}
        if q!=list_quote {depth,list_quote=0,q}
        marker:=""
        if kind==.Item {
            for depth>0 && indent<lists[depth-1].marker {depth-=1}
            if depth==0 || indent>=lists[depth-1].content {
                depth=min(depth+1,MARKDOWN_DEPTH)
                lists[depth-1].marker=indent
            }
            after:=content[marker_len:]
            spaces,text_after:=md_indent(after)
            if spaces>4 || text_after=="" {spaces=1}
            lists[depth-1].content=indent+marker_len+spaces
            marker="•" if marker_len==1 else content[:marker_len]
            content=text_after
        } else {
            for depth>0 && indent<=lists[depth-1].marker {depth-=1}
        }
        switch kind {
        case .Fence:
            md_open(m,.Code,0,q,depth,"",blank)
            fence,fence_count,fence_indent,fence_quote=first,run,indent,q
        case .Heading:
            md_open(m,.Heading,heading,q,depth,"",blank)
            md_inline(m,md_heading_text(content[heading:]))
            md_close(m)
        case .Rule:
            md_open(m,.Rule,0,q,depth,"",blank)
            md_close(m)
        case .Text,.Item:
            md_open(m,.Paragraph,0,q,depth,marker,blank)
            md_inline(m,strings.trim_space(content))
        }
        blank=false
    }
    if m.open {md_close(m)}
}

// ---------------------------------------------------------------- blocks

@(private="file")
md_open :: proc(m:^Md,block:Md_Block,level,quote,depth:int,marker:string,blank:bool) {
    ctx:=m.ctx
    s:=m.body
    gap:f32
    if m.blocks>0 {
        gap=math.floor(s*2/3)
        if !blank && depth>0 && m.last_depth>0 {gap=math.floor(s/4)}
        if block==.Heading {gap+=math.floor(s/2)}
    }
    // The rules of the quotes the block before was in go on through the gap.
    continued:=min(quote,m.last_quote) if m.blocks>0 else 0
    m.block,m.quote,m.depth,m.open=block,quote,depth,true
    m.size,m.font,m.text_color=s,md_face(m,FONT_REGULAR),tone(ctx,"text_muted") if quote>0 else m.color
    m.line=math.floor(s*PARAGRAPH_LINE)
    pad:=math.floor(s*2/3)
    switch block {
    case .Heading:
        m.size=s+(5 if level==1 else 3 if level==2 else 1)
        m.font,m.text_color=md_face(m,FONT_SEMIBOLD),tone(ctx,"text")
        m.line=math.floor(m.size*MARKDOWN_HEADING_LINE)
    case .Code:
        m.size=max(s-1,1)
        m.font,m.text_color=md_face(m,FONT_MONO),m.color
        m.line=math.floor(m.size*MARKDOWN_CODE_LINE)
        m.codes+=1
    case .Paragraph,.Rule:
    }
    quote_width,list_width:=math.floor(s),math.floor(s*1.5)
    outer:=m.width-f32(quote)*quote_width
    m.room=max(outer-f32(depth)*list_width-(2*pad if block==.Code else 0),1)
    m.lines,m.labels_used=0,0
    m.blocks+=1
    m.last_quote,m.last_depth=quote,depth
    if m.collect>0 {return}
    box_begin(ctx,{width=fixed(m.width),height=FIT})
    for k in 0..<quote {
        box_begin(ctx,{width=fixed(quote_width),height=GROW,direction=.Column})
        if k>=continued && gap>0 {spacer(ctx,MARKDOWN_BAR,gap)}
        element_leaf(ctx,{layout={width=fixed(MARKDOWN_BAR),height=GROW},custom=paint_add(ctx,{kind=.Rect,fill=tone(ctx,"border")})})
        box_end(ctx,{})
    }
    box_begin(ctx,{width=fixed(outer),height=FIT,direction=.Column,padding={0,gap,0,0}})
    if depth>0 {
        box_begin(ctx,{width=fixed(outer),height=FIT})
        if depth>1 {spacer(ctx,f32(depth-1)*list_width,0)}
        if marker!="" {
            text(ctx,marker,{font=md_face(m,FONT_REGULAR),size=s,color=tone(ctx,"text_muted"),align_x=.Center,align_y=.Center},fixed(list_width-math.floor(s/4)),fixed(math.floor(s*PARAGRAPH_LINE)))
            spacer(ctx,math.floor(s/4),0)
        } else {
            spacer(ctx,list_width,0)
        }
    }
    if block==.Code {
        box_begin(ctx,{id=id(ctx,"code",m.codes),track=true,width=fixed(m.room+2*pad),height=FIT,direction=.Stack,fill=tone(ctx,"well"),radius=metric(ctx,"radius_popup")})
        box_begin(ctx,{width=fixed(m.room+2*pad),height=FIT,direction=.Column,padding=padding_all(pad)})
    } else {
        box_begin(ctx,{width=fixed(m.room),height=FIT,direction=.Column})
    }
    if block==.Paragraph || block==.Heading {
        m.texting=text_begin(ctx,{font=m.font,size=m.size,color=m.text_color,wrap=.Words},m.line,true)
    }
}

@(private="file")
md_close :: proc(m:^Md) {
    if !m.open {return}
    m.open=false
    if m.collect>0 {return}
    ctx:=m.ctx
    pad:=math.floor(m.body*2/3)
    if m.texting {text_end(ctx,{width=fixed(m.room)})}
    m.texting=false
    // A block of code without lines keeps the height of one.
    if m.block==.Code && m.lines==0 {spacer(ctx,m.room,m.line)}
    if m.block==.Rule {
        if box(ctx,{width=fixed(m.room),height=fixed(m.line),align_y=.Center}) {
            element_leaf(ctx,{layout={width=fixed(m.room),height=fixed(1)},custom=paint_add(ctx,{kind=.Rect,fill=tone(ctx,"divider")})})
        }
    }
    box_end(ctx,{})
    if m.block==.Code {
        // While the pointer is on the block, a button at its corner copies its code.
        copy:=id(ctx,"copy",m.codes)
        if widget_under(ctx,id(ctx,"code",m.codes)) || ctx.hot==copy || ctx.active==copy {
            side:=min(metric(ctx,"row")-4,m.line+2*pad-8)
            if box(ctx,{width=FIT,height=FIT,self_x=.End,self_y=.Start,padding=padding_all(4)}) {
                if button(ctx,copy,{icon=.Copy,variant="ghost",width=side,height=side,icon_size=min(14,side),icon_color=tone(ctx,"text_muted")}).clicked {m.copied=m.codes}
            }
        }
        box_end(ctx,{})
    }
    if m.depth>0 {box_end(ctx,{})}
    box_end(ctx,{})
    box_end(ctx,{})
}

// A line of a fenced code block: a text that breaks at no space, cut where
// each of its lines ends.
@(private="file")
md_code_line :: proc(m:^Md,line:string) {
    if m.collect>0 {
        if m.collect==m.codes {
            if m.copy_lines>0 {append(m.code,'\n')}
            append(m.code,line)
            m.copy_lines+=1
        }
        return
    }
    ctx:=m.ctx
    font:=&ctx.font
    f:=int(m.font)
    m.lines+=1
    if !text_begin(ctx,{font=m.font,size=m.size,color=m.text_color,wrap=.Words},m.line,true) {return}
    // A tab is room up to the next stop of four spaces of its line.
    tab:=4*text_width(font," ",m.size,f)
    x:f32
    start:=0
    for i in 0..<len(line) {
        if line[i]!='\t' {continue}
        run:=line[start:i]
        text_span(ctx,run,{solid=true})
        x+=text_width(font,run,m.size,f)
        stop:=(math.floor(x/tab)+1)*tab if tab>0 else x
        text_box(ctx,min(stop-x,m.room),0,{})
        x,start=stop,i+1
    }
    text_span(ctx,line[start:],{solid=true})
    text_end(ctx,{width=fixed(m.room)})
}

// ---------------------------------------------------------------- inlines

// One line of a paragraph or a heading: what closes on it opens on it.
@(private="file")
md_inline :: proc(m:^Md,s:string) {
    if m.collect>0 {return}
    m.bold,m.em=-1,-1
    start,i:=0,0
    for i<len(s) {
        c:=s[i]
        switch {
        case c=='\\' && i+1<len(s) && md_punctuation(s[i+1]):
            md_emit(m,s[start:i])
            start=i+1;i+=2
        case c=='`':
            n:=md_count(s[i:],'`')
            close:=md_code_close(s,i+n,n)
            if close<0 {i+=n;continue}
            md_emit(m,s[start:i])
            md_code(m,s[i+n:close])
            i=close+n;start=i
        case c=='*' || c=='_':
            n:=md_count(s[i:],c)
            if i==m.bold && n>=2 {
                md_emit(m,s[start:i])
                if m.em==i {m.em=i+2}
                m.bold=-1;i+=2;start=i
                continue
            }
            if i==m.em {
                md_emit(m,s[start:i])
                if m.bold==i {m.bold=i+1}
                m.em=-1;i+=1;start=i
                continue
            }
            if n>=2 && m.bold<0 {
                if close:=md_delimiter_close(s,i,2,c);close>=0 {md_emit(m,s[start:i]);m.bold=close;i+=2;start=i;continue}
            }
            if m.em<0 {
                if close:=md_delimiter_close(s,i,1,c);close>=0 {md_emit(m,s[start:i]);m.em=close;i+=1;start=i;continue}
            }
            i+=n
        case c=='[':
            if end:=md_link(m,s,i,start);end>0 {i,start=end,end;continue}
            i+=1
        case:
            i+=1
        }
    }
    md_emit(m,s[start:])
}

// What the words of the line are drawn with here: nothing of their own, or the bold face.
@(private="file")
md_span :: proc(m:^Md) -> Text_Span {
    if m.bold<0 {return {}}
    return {font=md_face(m,FONT_SEMIBOLD),size=m.size,color=m.text_color}
}

// A run of text in the style the line has here.
@(private="file")
md_emit :: proc(m:^Md,run:string) {
    text_span(m.ctx,run,md_span(m))
}

// Inline code: a chip, which does not break at its spaces.
@(private="file")
md_code :: proc(m:^Md,code:string) {
    code:=code
    if len(code)>=2 && code[0]==' ' && code[len(code)-1]==' ' && strings.trim_space(code)!="" {code=code[1:len(code)-1]}
    if code=="" {return}
    size:=max(m.size-1,1)
    text_span(m.ctx,code,{font=md_face(m,FONT_MONO),size=size,color=tone(m.ctx,"text"),back=tone(m.ctx,"chip_on"),radius=metric(m.ctx,"radius_control"),pad=2*MARKDOWN_CHIP_PAD,height=min(math.floor(size*TEXT_LINE)+2,m.line)})
}

// [text](target) at i, after the text from start; returns where it ends, or 0.
@(private="file")
md_link :: proc(m:^Md,s:string,i,start:int) -> int {
    close:=strings.index_byte(s[i+1:],']')
    if close<=0 {return 0}
    close+=i+1
    label:=s[i+1:close]
    if strings.index_byte(label,'[')>=0 || close+1>=len(s) || s[close+1]!='(' {return 0}
    end:=strings.index_byte(s[close+2:],')')
    if end<0 {return 0}
    end+=close+2
    target:=strings.trim_space(s[close+2:end])
    if target=="" {return 0}
    md_emit(m,s[start:i])
    ctx:=m.ctx
    link:=Markdown_Link{live=true}
    if m.resolve!=nil {link=m.resolve(m.data,target,label,m.labels[m.labels_used:])}
    shown:=label
    if link.label!="" {
        shown=link.label
        // A label written in the room of the labels keeps its bytes until the block ends.
        base,at:=uintptr(raw_data(m.labels[:])),uintptr(raw_data(link.label))
        if at>=base+uintptr(m.labels_used) && at+uintptr(len(link.label))<=base+MARKDOWN_LABELS {m.labels_used=int(at-base)+len(link.label)}
    }
    // What leads somewhere takes the pointer: lit under it, and reported when clicked.
    widget:Id
    lit:=false
    if link.live {
        m.widgets+=1
        widget=id(ctx,"link",m.widgets)
        lit=ctx.hot==widget
    }
    color:=link.color
    if link.pill {
        if color=={} {color=tone(ctx,"on_accent") if link.button else tone(ctx,"text")}
        width:=text_width(&ctx.font,shown,m.size,int(m.font))+2*MARKDOWN_PILL_PAD+(m.size+6 if link.icon!=.None else 0)
        paint:=Paint{kind=.Box,radius=metric(ctx,"radius_control"),text=shown,text_color=color,size=m.size,style={font=m.font},fill=color_alpha(tone(ctx,"accent"),61 if lit else 36),
            padding=MARKDOWN_PILL_PAD,icon=link.icon,icon_color=color,icon_size=m.size}
        if link.button {paint.fill=tone(ctx,"accent_hover") if lit else tone(ctx,"accent")}
        if link.selected {paint.stroke,paint.stroke_width=tone(ctx,"text"),1.5}
        if widget!=0 && interact(ctx,widget).clicked {m.clicked=target}
        text_box(ctx,min(width,m.room),m.line,paint,widget,MARKDOWN_PILL_GAP)
        return end+1
    }
    if color=={} {color=tone(ctx,"accent")}
    span:=Text_Span{font=md_face(m,FONT_SEMIBOLD) if m.bold>=0 else m.font,size=m.size,color=color,radius=metric(ctx,"radius_control")}
    if lit {span.back=tone(ctx,"chip_on")}
    if widget==0 {
        text_span(ctx,shown,span)
    } else if text_link(ctx,widget,shown,span).clicked {m.clicked=target}
    return end+1
}

// ---------------------------------------------------------------- lines of the text

// Up to n spaces off the start of s.
@(private="file")
md_skip :: proc(s:string,n:int) -> string {
    i:=0
    for i<n && i<len(s) && s[i]==' ' {i+=1}
    return s[i:]
}
// The columns of the indentation of s, a tab to the next of four, and what follows it.
@(private="file")
md_indent :: proc(s:string) -> (columns:int,rest:string) {
    i:=0
    for i<len(s) && (s[i]==' ' || s[i]=='\t') {
        columns=(columns/4+1)*4 if s[i]=='\t' else columns+1
        i+=1
    }
    return columns,s[i:]
}
@(private="file")
md_count :: proc(s:string,c:u8) -> int {
    n:=0
    for n<len(s) && s[n]==c {n+=1}
    return n
}
@(private="file")
md_fence_end :: proc(s:string,c:u8,count:int) -> bool {
    s:=md_skip(s,3)
    n:=md_count(s,c)
    return n>=count && strings.trim_space(s[n:])==""
}
// The level of an ATX heading that starts s, or 0.
@(private="file")
md_heading :: proc(s:string) -> int {
    n:=md_count(s,'#')
    return n if n>=1 && n<=6 && (n==len(s) || s[n]==' ' || s[n]=='\t') else 0
}
// The text of a heading without the hashes that may close it.
@(private="file")
md_heading_text :: proc(s:string) -> string {
    s:=strings.trim_space(s)
    end:=len(s)
    for end>0 && s[end-1]=='#' {end-=1}
    if end==0 {return ""}
    if s[end-1]==' ' {return strings.trim_space(s[:end])}
    return s
}
// Three or more of the same -, * or _, with spaces between them.
@(private="file")
md_rule :: proc(s:string) -> bool {
    c:=s[0]
    if c!='-' && c!='*' && c!='_' {return false}
    n:=0
    for i in 0..<len(s) {
        if s[i]==c {n+=1} else if s[i]!=' ' && s[i]!='\t' {return false}
    }
    return n>=3
}
// The bytes of the marker of a list item that starts s (-, *, +, 1. or 1)), or 0.
@(private="file")
md_item :: proc(s:string) -> int {
    n:=0
    if s[0]=='-' || s[0]=='*' || s[0]=='+' {
        n=1
    } else {
        for n<len(s) && n<9 && s[n]>='0' && s[n]<='9' {n+=1}
        if n==0 || n>=len(s) || (s[n]!='.' && s[n]!=')') {return 0}
        n+=1
    }
    return n if n==len(s) || s[n]==' ' || s[n]=='\t' else 0
}
@(private="file")
md_punctuation :: proc(c:u8) -> bool {
    return c>='!' && c<='/' || c>=':' && c<='@' || c>='[' && c<='`' || c>='{' && c<='~'
}
@(private="file")
md_word_char :: proc(c:u8) -> bool {
    return c>='0' && c<='9' || c>='a' && c<='z' || c>='A' && c<='Z' || c>=0x80
}
// Where the run of backticks that closes one of n before from is, or -1.
@(private="file")
md_code_close :: proc(s:string,from,n:int) -> int {
    for j:=from;j<len(s); {
        if s[j]!='`' {j+=1;continue}
        run:=md_count(s[j:],'`')
        if run==n {return j}
        j+=run
    }
    return -1
}
// Where the n markers that close the n at i are on the line, or -1. An opener
// is followed by no space and a closer follows none; underscores do not open
// or close inside a word.
@(private="file")
md_delimiter_close :: proc(s:string,i,n:int,c:u8) -> int {
    after:=i+n
    if after>=len(s) || s[after]==' ' || c=='_' && i>0 && md_word_char(s[i-1]) {return -1}
    for j:=after+1;j+n<=len(s); {
        if s[j]!=c {j+=1;continue}
        run:=md_count(s[j:],c)
        if (n==1 && run==2) || (n==2 && run<2) || s[j-1]==' ' || c=='_' && j+n<len(s) && md_word_char(s[j+n]) {j+=run;continue}
        return j
    }
    return -1
}
