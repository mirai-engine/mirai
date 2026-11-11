package ui

import "core:math"
import "core:mem"
import "mirai:std/base"
import mm "mirai:std/math"

// The layout of a frame. The widgets open and close its elements, and the size
// an element asks for follows from its children as they close. layout_finish
// hands the space of every container out among its children, one axis at a
// time, breaks the texts into lines, places every element and lists what
// is drawn in the order it is drawn.
//
// A modified version, written in Odin, of the layout of Clay v0.14 (zlib,
// Copyright (c) 2024 Nic Barker; THIRD_PARTY_NOTICES.md). An element that asks
// for it goes between two layouts as Clay's transitions do: from where it was
// drawn to where the layout puts it, its size taken by a second layout.

// Containers open inside one another. A deeper one is refused with what it
// holds and counted in Stats.dropped_elements.
LAYOUT_DEPTH :: 64

@(private)
LAYOUT_EPSILON :: 0.01
// The line box of the running text of the editor in sizes, that of the
// messages of the chat: prose rounds it down to a whole unit.
@(private)
PARAGRAPH_LINE :: f32(1.6)

@(private)
Layout_Node :: struct {
    layout:Layout,
    scroll:[2]f32,      // how far a clip moves its content up and left
    dim,min_dim:[2]f32, // the size it takes and the least it accepts
    box:Rect,
    custom:rawptr,      // the Paint it draws
    user_data:rawptr,   // what its scissor and border commands carry
    id:Id,
    kids_first,kids_len:i32,
    text:i32,           // its row in texts when it is a text; -1 otherwise
    clip_x,clip_y,floating:bool,
    clip_floats:bool,   // the roots that float inside it are cut by it
    clip_outer:i32,     // of one that does: the one it is inside that does too; 0: none
    border:u16,
    row_span:u8,        // rows of a Grid it takes; 0 is 1
    row_tracks:u16,     // of a Grid: row plus one of row_tracks; 0: none
    transition:i32,     // its row in transitions plus one; 0: it goes straight to where it is laid out
}
// Where an element that transitions was and is going. Rectangles from the
// corner of the content of its parent, so a parent that moves or scrolls
// carries it without starting it again.
@(private)
Layout_Transition :: struct {
    id:Id,
    from,to,now:Rect, // now: where it was drawn last
    surface:[2]f32,   // the size of the surface it was laid out on: another one places it at once
    time,seconds:f32,
    frame:u64,        // the last that asked for it; one not asked the frame before starts where it is laid out
    placed:bool,
}
// What a run measures to in one line: its width, the width of its widest word
// and of a space, and the words it is cut into. A word carries the space that
// follows it; a line break is a word of no length.
@(private)
Layout_Measure :: struct {
    width,min_width,space:f32,
    words_first,words_len:i32, // first is -1 when there was no room to keep them
    length:i32, // of the text, which its words index
    breaks:bool,
}
// A run as a generation of the measures keeps it: what it measured to and
// what it was, to tell it from another run of the same key.
@(private)
Layout_Measured :: struct {
    measure:Layout_Measure,
    size:f32,
    text_first:i32, // in chars
    face:u8,
}
// What runs measured to, by what they say, their size and their face, with
// the words they were cut into and a copy of what they say. A slot of an
// earlier generation is free, so a generation costs nothing to empty.
@(private)
Layout_Measures :: struct {
    keys:[]u64,entries:[]Layout_Measured,generations:[]u32,mask,generation:u32,
    count:int,
    words:[]Layout_Word,word_count:int,
    chars:[]u8,char_count:int,
}
// A piece of the content of a text: words in one size and face, a box that
// stands in their line (an image, a pill), or room as wide as width where a
// word ends when it has neither text nor box.
@(private)
Layout_Span :: struct {
    text:string,
    using look:Text_Span, // the font, the size and the color it is drawn with
    box:bool,
    width:f32,     // on one line: of its text with pad, or its own when it is a box or room
    gap:f32,       // room after it that is no part of it
    measure:Layout_Measure,
    paint:^Paint,  // of a box: what draws it
    widget:i32,    // the widget its pieces are, plus one; 0: the pointer goes through
}
// What a text asks of its lines.
@(private)
Layout_Text_Desc :: struct {
    size:f32,    // of its style: a line shows while the box of a line of this size fits in the element
    line:f32,    // the box of a line; one that holds a taller piece is as tall as it
    wrap:Text_Wrap,
    ellipsis:bool,
    hits:bool,   // pieces of it take the pointer: frame_end gives them their rectangles
    align_x,align_y:Align,
}
// A text: the spans it says, and the lines the width it was given breaks them into.
@(private)
Layout_Text :: struct {
    using desc:Layout_Text_Desc,
    node:i32,
    spans_first,spans_len:i32,
    lines_first,lines_len:i32,
    shown:i32,   // lines that fit in its element, once placed
    height:f32,  // of its lines
}
@(private)
Layout_Word :: struct {start,length:i32,width:f32}
// x, y: from the corner of the text until it is placed, on the surface after.
// base: its baseline under its top. cut: it ends in an ellipsis.
@(private)
Layout_Line :: struct {pieces_first,pieces_len:i32,x,y,width,height,base:f32,cut:bool}
// The part of a span on a line. x, y: from the corner of its line.
@(private)
Layout_Piece :: struct {span,start,length:i32,x,y,width:f32}
// A floating element is a root of its own, placed against the node it hangs from.
@(private)
Layout_Root :: struct {
    node,parent:i32,
    anchor,pivot:Anchor,
    offset:[2]f32,
    layer:i16,
    retained:u8,        // the retained subtree it is part of, plus one
    first_command:i32,  // its first in commands, once placed
    clip:i32,           // the node it floats inside that cuts it (clip_floats); 0: none
    contain:bool,       // it stays inside within
    within:i32,         // the node it stays inside: a world panel, the part of a player or the surface (0)
    inset:[4]f32,       // how far inside it
    hung:bool,          // it hangs from rect instead of from parent
    rect:Rect,
}
@(private)
Layout_Attach :: enum u8 {None,Root,Parent}
// Where a floating element hangs: from the root of the layout, or from the
// element with the id it names, or with none from the one it is declared in.
@(private)
Layout_Float :: struct {
    to:Layout_Attach,
    parent:Id,
    anchor,pivot:Anchor,
    offset:[2]f32,
    layer:i16,
    retained:u8,
    contain:bool,
    within:Id,  // what it stays inside when it contains itself; 0: the surface
    inset:[4]f32,
    hung:bool,  // it hangs from rect, a rectangle of the layout, instead of from an element
    rect:Rect,
}
@(private)
Layout_Command_Kind :: enum u8 {Custom,Border,Text,Scissor_Start,Scissor_End}
// line: its row in lines, for a line of a text.
@(private)
Layout_Command :: struct {kind:Layout_Command_Kind,node,line:i32}

@(private)
Layout_Tree :: struct {
    nodes:[]Layout_Node,node_count:int,
    texts:[]Layout_Text,text_count:int,
    spans:[]Layout_Span,span_count:int,
    pieces:[]Layout_Piece,piece_count:int,
    kids:[]i32,kids_len:int,       // the children of each container, one after the other
    pending:[]i32,pending_len:int, // closed and not yet handed to their parent; the work list of a pass
    scratch:[]i32,                 // the containers a pass still has to go through
    roots:[]Layout_Root,root_count:int,
    open:[LAYOUT_DEPTH+1]i32,open_len:int,
    lines:[]Layout_Line,line_count:int,
    commands:[]Layout_Command,command_count:int,
    ids:Id_Table, // where an element is by its id
    duplicates:int,
    // The runs of this frame are measured in the first and what earlier
    // frames measured is found in the second: they change places between frames.
    measures:[2]Layout_Measures,
    measured,reused:int, // runs measured anew and found measured, until frame_end reads them
    overflow:bool, // a line or a command did not fit this frame
    tracks:[]Grid_Tracks,track_count:int, // the widths of the columns of the grids of the frame (grid_tracks_add)
    aspects:bool,  // an element of the frame keeps an aspect
    transitions:[]Layout_Transition, // by id: a power of two of slots, found from the id on
    dt:f32,        // seconds since the last frame, which carry what transitions
    ppu:f32,       // device pixels per layout unit: the grid boxes and the sizes of texts fall on
    allocator:mem.Allocator,
}

@(private)
layout_init :: proc(t:^Layout_Tree,allocator:mem.Allocator,max_elements,max_words,max_chars,max_tracks,max_transitions:int) -> bool {
    t^={allocator=allocator}
    ok:=true
    alloc :: proc($T:typeid,n:int,a:mem.Allocator,ok:^bool) -> []T {
        out,err:=make([]T,n,a)
        if err!=nil {ok^=false}
        return out
    }
    a:=allocator
    nodes:=max_elements+1
    t.nodes=alloc(Layout_Node,nodes,a,&ok)
    t.texts=alloc(Layout_Text,nodes,a,&ok)
    t.spans=alloc(Layout_Span,nodes,a,&ok)
    t.pieces=alloc(Layout_Piece,max_elements*4,a,&ok)
    t.kids=alloc(i32,nodes,a,&ok)
    t.pending=alloc(i32,nodes,a,&ok)
    t.scratch=alloc(i32,nodes,a,&ok)
    t.roots=alloc(Layout_Root,nodes,a,&ok)
    t.lines=alloc(Layout_Line,max_elements*4,a,&ok)
    t.commands=alloc(Layout_Command,max_elements*4,a,&ok)
    t.tracks=alloc(Grid_Tracks,max_tracks,a,&ok)
    transitions:=1
    for transitions<max_transitions {transitions<<=1}
    t.transitions=alloc(Layout_Transition,transitions,a,&ok)
    if !id_table_init(&t.ids,max_elements,a) {ok=false}
    // A frame has fewer runs than elements.
    slots:=16
    for slots<max_elements {slots<<=1}
    for &g in t.measures {
        g.keys=alloc(u64,slots,a,&ok)
        g.entries=alloc(Layout_Measured,slots,a,&ok)
        g.generations=alloc(u32,slots,a,&ok)
        g.mask=u32(slots-1)
        g.words=alloc(Layout_Word,max_words,a,&ok)
        g.chars=alloc(u8,max_chars,a,&ok)
    }
    if !ok {layout_destroy(t);return false}
    // Allocated memory is not promised to be zeroed, and a slot is free by
    // the generation it holds.
    for &g in t.measures {
        mem.zero_slice(g.generations)
        g.generation=1
    }
    mem.zero_slice(t.transitions)
    return true
}

@(private)
layout_destroy :: proc(t:^Layout_Tree) {
    a:=t.allocator
    delete(t.nodes,a);delete(t.texts,a);delete(t.spans,a);delete(t.pieces,a);delete(t.kids,a);delete(t.pending,a);delete(t.scratch,a)
    delete(t.roots,a);delete(t.lines,a);delete(t.commands,a);delete(t.tracks,a);delete(t.transitions,a)
    id_table_destroy(&t.ids,a)
    for g in t.measures {
        delete(g.keys,a);delete(g.entries,a);delete(g.generations,a);delete(g.words,a);delete(g.chars,a)
    }
    t^={}
}

// Starts the tree of a frame on a surface of this size. Node zero is the
// surface: every element at the top level is inside it.
@(private)
layout_begin :: proc(t:^Layout_Tree,size:[2]f32,ppu:f32) {
    t.ppu=ppu
    t.text_count=0;t.span_count=0;t.piece_count=0;t.kids_len=0;t.pending_len=0;t.line_count=0;t.command_count=0
    t.duplicates=0;t.overflow=false;t.aspects=false
    id_table_clear(&t.ids)
    // The generations change places only between frames, because the runs of
    // a frame point at the words of the first. Half full leaves room for a
    // frame of new runs; what the second held and no frame since asked for is
    // forgotten.
    if g:=&t.measures[0];g.count>=len(g.entries)/2 || g.word_count>=len(g.words)/2 || g.char_count>=len(g.chars)/2 {
        t.measures[0],t.measures[1]=t.measures[1],t.measures[0]
        g.generation+=1
        if g.generation==0 {mem.zero_slice(g.generations);g.generation=1}
        g.count,g.word_count,g.char_count=0,0,0
    }
    t.nodes[0]={layout={width=fixed(size.x),height=fixed(size.y)},dim=size,min_dim=size,box={0,0,size.x,size.y},text=-1}
    t.node_count=1
    t.open[0]=0
    t.open_len=1
    t.roots[0]={}
    t.root_count=1
}

// Opens a container. False when it is nested deeper than LAYOUT_DEPTH or the
// tree is full: then neither it nor what it would hold is in the layout.
@(private)
layout_open :: proc(t:^Layout_Tree,e:Element,f:Layout_Float) -> bool {
    if t.open_len>LAYOUT_DEPTH || t.node_count>=len(t.nodes) {return false}
    index:=i32(t.node_count)
    n:=&t.nodes[index]
    // Each field is written but the sizes, which closing the node writes: a
    // frame has thousands of nodes and clearing them whole costs.
    n.layout=e.layout
    n.scroll=e.clip.scroll
    n.box={}
    n.custom=e.custom
    n.user_data=e.user_data
    n.id=e.id
    n.kids_len=0
    n.text=-1
    n.clip_x,n.clip_y=e.clip.x,e.clip.y
    n.clip_floats=e.clip.floats
    n.floating=f.to!=.None
    n.border=e.border
    n.row_span,n.row_tracks=e.row_span,e.row_tracks
    n.transition=0
    t.node_count+=1
    t.aspects||=e.layout.aspect>0
    layout_id_put(t,e.id,index)
    clip:=i32(0)
    if n.floating || n.clip_floats {
        #reverse for open in t.open[:t.open_len] {
            if t.nodes[open].clip_floats {clip=open;break}
        }
    }
    n.clip_outer=clip if n.clip_floats else 0
    if n.floating {
        parent:=i32(0)
        if f.to==.Parent {
            parent=t.open[t.open_len-1]
            if f.parent!=0 {parent=layout_index(t,f.parent)}
        }
        t.roots[t.root_count]={node=index,parent=parent,anchor=f.anchor,pivot=f.pivot,offset=f.offset,layer=f.layer,retained=f.retained,clip=clip,
            contain=f.contain,within=layout_index(t,f.within) if f.contain else 0,inset=f.inset,hung=f.hung,rect=f.rect}
        t.root_count+=1
    }
    t.open[t.open_len]=index
    t.open_len+=1
    return true
}

@(private)
layout_close :: proc(t:^Layout_Tree) {
    if t.open_len<=1 {return}
    t.open_len-=1
    index:=t.open[t.open_len]
    n:=&t.nodes[index]
    layout_kids(t,n)
    layout_fit(t,n)
    // A floating element takes nothing from the flow of its parent.
    if !n.floating {layout_attach(t,index)}
}

// Starts a text: the spans put until it ends are what it says. False when the tree has no room for it.
@(private)
layout_text_begin :: proc(t:^Layout_Tree,desc:Layout_Text_Desc) -> bool {
    if t.text_count>=len(t.texts) {return false}
    text:=&t.texts[t.text_count]
    text^={desc=desc,node=-1,spans_first=i32(t.span_count)}
    // A size or a line that is no number is none.
    if !(text.size>0) {text.size=0}
    if !(text.line>0) {text.line=0}
    return true
}
// A span of the text begun, measured once for what it says. False when the
// tree has no room for it.
@(private)
layout_text_span :: proc(t:^Layout_Tree,font:^Font,span:Layout_Span) -> bool {
    if t.span_count>=len(t.spans) {return false}
    s:=&t.spans[t.span_count]
    s^=span
    if !(s.size>0) {s.size=0}
    if !(s.width>0) {s.width=0}
    if !(s.pad>0) {s.pad=0}
    if !(s.gap>0) {s.gap=0}
    if !(s.height>0) {s.height=0}
    if !s.box && s.text!="" {
        s.measure=layout_measure(t,font,s.text,s.size,s.font)
        s.width=s.measure.width+s.pad+(s.size+6 if s.icon!=.None else 0)
    }
    t.span_count+=1
    t.texts[t.text_count].spans_len+=1
    return true
}
// Ends the text begun as an element. Only a width that fits asks for what it
// says, on one line: any other width is what the layout gives it, and the
// text breaks to it. False when the tree has no room for it.
@(private)
layout_text_end :: proc(t:^Layout_Tree,font:^Font,e:Element) -> bool {
    text:=&t.texts[t.text_count]
    if t.node_count>=len(t.nodes) {
        t.span_count=int(text.spans_first)
        return false
    }
    index:=i32(t.node_count)
    text.node=index
    n:=&t.nodes[index]
    n.layout=e.layout
    n.layout.aspect=0
    n.scroll={}
    n.box={}
    n.custom=e.custom
    n.user_data=nil
    n.id=e.id
    n.kids_len=0
    n.text=i32(t.text_count)
    n.clip_x,n.clip_y,n.floating,n.clip_floats,n.clip_outer=false,false,false,false,0
    n.border=0
    n.row_span,n.row_tracks,n.transition=e.row_span,0,0
    t.text_count+=1
    t.node_count+=1
    layout_id_put(t,e.id,index)
    layout_fit_text(t,font,n)
    layout_attach(t,index)
    return true
}
// What a text asks for: the width of its widest line when its width fits and
// one line when its height does.
@(private)
layout_fit_text :: proc(t:^Layout_Tree,font:^Font,n:^Layout_Node) {
    text:=&t.texts[n.text]
    l:=&n.layout
    n.dim,n.min_dim={},{}
    if l.width.kind==.Fit {
        wide,least:=layout_text_ask(t,font,text)
        // One unit more than a line that does not break: the edge of its last glyph.
        n.dim.x=wide+1 if text.wrap==.None else wide
        n.min_dim.x=n.dim.x if text.wrap==.None else least
    }
    if l.height.kind==.Fit {n.dim.y,n.min_dim.y=text.line,text.line}
    n.dim={layout_whole(t.ppu,n.dim.x),layout_whole(t.ppu,n.dim.y)}
    if text.wrap==.None {n.min_dim.x=n.dim.x}
    n.min_dim.y=n.dim.y
    layout_limit(n)
}
// What a text asks for, up to whole device pixels (ppu per unit): a box
// rounded to them is never smaller than the text it holds.
@(private)
layout_whole :: #force_inline proc "contextless" (ppu,v:f32) -> f32 {
    return math.ceil(v*ppu-LAYOUT_EPSILON)/ppu if ppu>0 && abs(v)<math.F32_MAX/16 else v
}
// A size a widget measures from its text, up to the device pixels of the context.
@(private)
context_whole :: #force_inline proc "contextless" (ctx:^Context,v:f32) -> f32 {return layout_whole(ctx.scale*ctx.font.density,v)}
// The words of a span in order: those its measure kept, or the span walked again.
@(private)
layout_span_walk :: proc "contextless" (t:^Layout_Tree,font:^Font,s:^Layout_Span) -> (w:Layout_Walk) {
    m:=&s.measure
    w={font=font,text=s.text,size=s.size,face=int(s.font),space=m.space}
    if m.words_first>=0 {w.words=t.measures[0].words[m.words_first:][:m.words_len]}
    return
}

// What a text asks for: the width of its widest line when nothing but its own
// line breaks breaks it, and the least it breaks down to.
@(private)
layout_text_ask :: proc "contextless" (t:^Layout_Tree,font:^Font,text:^Layout_Text) -> (wide,least:f32) {
    spans:=t.spans[text.spans_first:][:text.spans_len]
    line:f32
    for &s in spans {
        m:=&s.measure
        if s.box || s.pad>0 || s.solid || s.text=="" || !m.breaks {
            line+=s.width+s.gap
            if s.box {least=max(least,s.width)} else if s.text!="" {least=max(least,s.width if s.pad>0 || s.solid else m.min_width)}
            continue
        }
        least=max(least,m.min_width)
        if len(spans)==1 {wide=m.width;continue}
        words:=layout_span_walk(t,font,&s)
        for {
            w,_,ok:=layout_walk(&words)
            if !ok {break}
            if w.length==0 {wide=max(wide,line);line=0} else {line+=w.width}
        }
    }
    return max(wide,line),least
}

@(private)
layout_attach :: proc(t:^Layout_Tree,index:i32) {
    t.nodes[t.open[t.open_len-1]].kids_len+=1
    t.pending[t.pending_len]=index
    t.pending_len+=1
}

// ---------------------------------------------------------------- by id

@(private)
layout_id_put :: proc(t:^Layout_Tree,id:Id,index:i32) {
    if id!=0 && !id_table_put(&t.ids,id,index) {t.duplicates+=1}
}
// The node of an id in this frame; the surface when no element has it.
@(private)
layout_index :: proc(t:^Layout_Tree,id:Id) -> i32 {
    if id==0 {return 0}
    place,_:=id_table_find(&t.ids,id)
    return place
}
// Where the element of an id was placed by the last layout_finish.
@(private)
layout_find :: proc(t:^Layout_Tree,id:Id) -> (Rect,bool) {
    index:=layout_index(t,id)
    if index==0 {return {},false}
    return t.nodes[index].box,true
}

// ---------------------------------------------------------------- text

// What a run measures to, from this frame or an earlier one when it says the
// same in the same size and face.
@(private)
layout_measure :: proc(t:^Layout_Tree,font:^Font,text:string,size:f32,face:u8) -> Layout_Measure {
    key:=base.hash_mix(base.name_hash(text),u64(transmute(u32)size)|u64(face)<<32)
    current:=&t.measures[0]
    slot,found:=layout_measures_find(current,key,text,size,face)
    if found {t.reused+=1;return current.entries[slot].measure}
    m:Layout_Measure
    if from,kept:=layout_measures_find(&t.measures[1],key,text,size,face);kept {
        previous:=&t.measures[1]
        m=previous.entries[from].measure
        t.reused+=1
        if current.word_count+int(m.words_len)>len(current.words) {
            m.words_first,m.words_len=-1,0
            return m
        }
        copy(current.words[current.word_count:],previous.words[m.words_first:][:m.words_len])
        m.words_first=i32(current.word_count)
        current.word_count+=int(m.words_len)
    } else {
        m=layout_measure_run(current,font,text,size,int(face))
        t.measured+=1
        if m.words_first<0 {return m}
    }
    // What a full generation cannot keep is measured again: slower, never wrong.
    if current.count<int(current.mask) && current.char_count+len(text)<=len(current.chars) {
        copy(current.chars[current.char_count:],text)
        current.generations[slot]=current.generation
        current.keys[slot]=key
        current.entries[slot]={m,size,i32(current.char_count),face}
        current.char_count+=len(text)
        current.count+=1
    }
    return m
}
// The slot of a run in a generation, or the free slot it would take.
@(private)
layout_measures_find :: proc(g:^Layout_Measures,key:u64,text:string,size:f32,face:u8) -> (u32,bool) {
    slot:=u32((key>>32)~key)&g.mask
    for g.generations[slot]==g.generation {
        e:=&g.entries[slot]
        if g.keys[slot]==key && e.size==size && e.face==face && string(g.chars[e.text_first:][:e.measure.length])==text {
            return slot,true
        }
        slot=(slot+1)&g.mask
    }
    return slot,false
}

// One walk over the text: what the run asks for follows from the words it is
// cut into. The widest word is the least it can shrink to.
@(private)
layout_measure_run :: proc(g:^Layout_Measures,font:^Font,text:string,size:f32,face:int) -> (m:Layout_Measure) {
    m.space=text_width(font," ",size,face)
    m.words_first=i32(g.word_count)
    m.length=i32(len(text))
    kept:=true
    walk:=Layout_Walk{font=font,text=text,size=size,face=face,space=m.space}
    for {
        w,bare,more:=layout_walk(&walk)
        if !more {break}
        if w.length==0 {m.breaks=true} else {m.min_width=max(m.min_width,bare)}
        if kept && g.word_count<len(g.words) {
            g.words[g.word_count]=w
            g.word_count+=1
        } else {kept=false}
    }
    // As wide as it is drawn on one line, with the kerning across its spaces.
    m.width=text_width(font,text,size,face)
    m.words_len=i32(g.word_count)-m.words_first
    if !kept {
        g.word_count=int(m.words_first)
        m.words_first,m.words_len=-1,0
    }
    return
}

// The bytes of the mark a word may end after that ends text at byte end: a
// hyphen or a slash (1), a soft hyphen (2: drawn as a hyphen only where a line
// breaks at it), an en or em dash or a zero width space (3); 0 for none.
@(private)
text_mark :: #force_inline proc "contextless" (text:string,end:int) -> int {
    switch c:=text[end-1];c {
    case '-','/':return 1
    case 0xad:if end>=2 && text[end-2]==0xc2 {return 2}
    case 0x93,0x94,0x8b:if end>=3 && text[end-3]==0xe2 && text[end-2]==0x80 {return 3}
    }
    return 0
}

// The words of a run, in order, as they are measured: each with the space or
// the mark (text_mark) that ends it, and a line break as a word of no length
// after the word before it.
@(private)
Layout_Walk :: struct {
    font:^Font,text:string,size:f32,face:int,space:f32,
    words:[]Layout_Word, // those a measure kept, given instead of walking the text
    at:int,     // the byte of text, or the word of words, it goes on from
    broke:bool, // a word before a line break was given: the break comes next
}
@(private)
layout_walk :: proc "contextless" (w:^Layout_Walk) -> (word:Layout_Word,bare:f32,ok:bool) {
    if len(w.words)>0 {
        if w.at>=len(w.words) {return}
        w.at+=1
        return w.words[w.at-1],0,true
    }
    if w.broke {
        w.broke=false
        return {i32(w.at),0,0},0,true
    }
    start:=w.at
    for i in start..<len(w.text) {
        c:=w.text[i]
        if c!=' ' && c!='\n' {
            // A word ends after a mark that follows something and that a word
            // follows, and a hyphen or a slash keeps a number after it (1/2, x-5).
            n:=text_mark(w.text,i+1)
            if n==0 || i+1-n<=start || i+1>=len(w.text) {continue}
            if next:=w.text[i+1];next==' ' || next=='\n' || n==1 && next>='0' && next<='9' {continue}
            w.at=i+1
            bare=text_width(w.font,w.text[start:i+1],w.size,w.face)
            return {i32(start),i32(i+1-start),bare},bare,true
        }
        w.at=i+1
        if c=='\n' && i==start {return {i32(i+1),0,0},0,true}
        bare=text_width(w.font,w.text[start:i],w.size,w.face)
        if c==' ' {return {i32(start),i32(i-start+1),bare+w.space},bare,true}
        w.broke=true
        return {i32(start),i32(i-start),bare},bare,true
    }
    if start<len(w.text) {
        w.at=len(w.text)
        bare=text_width(w.font,w.text[start:],w.size,w.face)
        return {i32(start),i32(len(w.text)-start),bare},bare,true
    }
    return
}

// Where the baseline of a line of text of a face is under its top, in sizes.
@(private)
face_ascent :: #force_inline proc "contextless" (font:^Font,face:u8) -> f32 {
    return font.metrics[face].ascent if font.ready && int(face)<font.font_count else 0.97
}

// The line a span of a text asks for: that of the text, taller by what a
// larger size adds, or the height of a box.
@(private)
layout_span_line :: #force_inline proc "contextless" (text:^Layout_Text,s:^Layout_Span) -> f32 {
    if s.box || s.pad>0 {return max(text.line,s.height)}
    return text.line+max(s.size-text.size,0)*TEXT_LINE
}

// Ends a line of the pieces kept since first, as tall as the tallest of them
// asks: text sits on one baseline, a box or a chip is centered.
@(private)
layout_line_end :: proc(t:^Layout_Tree,font:^Font,text:^Layout_Text,first:int,width:f32,y:^f32) {
    high:=text.line
    pieces:=t.pieces[first:t.piece_count]
    big:^Layout_Span
    for &p in pieces {
        s:=&t.spans[p.span]
        high=max(high,layout_span_line(text,s))
        if !s.box && s.pad==0 && (big==nil || s.size>big.size) {big=s}
    }
    // A line without text stands on its bottom.
    baseline:=high
    if big!=nil {baseline=(high-big.size*TEXT_LINE)*0.5+face_ascent(font,big.font)*big.size}
    for &p in pieces {
        s:=&t.spans[p.span]
        switch {
        case s.box || s.pad>0: p.y=(high-(s.height if s.height>0 else s.size*TEXT_LINE))*0.5
        case big==nil || s.size==big.size && s.font==big.font: p.y=(high-s.size*TEXT_LINE)*0.5
        case: p.y=baseline-face_ascent(font,s.font)*s.size
        }
    }
    if t.line_count<len(t.lines) {
        t.lines[t.line_count]={pieces_first=i32(first),pieces_len=i32(len(pieces)),y=y^,width=width,height=high,base=baseline}
        t.line_count+=1
        text.lines_len+=1
    } else {t.overflow=true}
    y^+=high
}
@(private)
layout_piece :: #force_inline proc(t:^Layout_Tree,p:Layout_Piece) {
    if t.piece_count<len(t.pieces) {
        t.pieces[t.piece_count]=p
        t.piece_count+=1
    } else {t.overflow=true}
}
// Ends the line a flow filled, or all it holds.
@(private)
layout_flow_line :: proc(t:^Layout_Tree,font:^Font,text:^Layout_Text,keep:bool,f:^Flow,y:^f32) {
    line:=flow_line(f,font)
    if keep {
        first:=t.piece_count
        width:f32
        for &p in line {
            s:=&f.spans[p.span]
            start:=i32(uintptr(raw_data(p.text))-uintptr(raw_data(s.text))) if p.text!="" else 0
            layout_piece(t,{span=text.spans_first+p.span,start=start,length=i32(len(p.text)),x=p.x,width=p.width})
            width=p.x+p.width
        }
        layout_line_end(t,font,text,first,width,y)
    } else {
        high:=text.line
        for &p in line {high=max(high,layout_span_line(text,&f.spans[p.span]))}
        y^+=high
    }
    flow_next(f)
}

// Breaks a text into the lines it takes in width and returns their height.
// keep: the lines and their pieces stay for it.
@(private)
layout_text_wrap :: proc(t:^Layout_Tree,font:^Font,text:^Layout_Text,width:f32,keep:bool) -> (height:f32) {
    if keep {text.lines_first,text.lines_len=i32(t.line_count),0}
    spans:=t.spans[text.spans_first:][:text.spans_len]
    y:f32
    defer if keep {text.height=max(y,text.line)}
    f:=Flow{spans=spans,width=width if text.wrap==.Words else max(f32)}
    for &s,i in spans {
        p:=Flow_Piece{span=i32(i),text=s.text,width=s.width,gap=s.gap}
        if s.box || s.pad>0 || s.solid {
            if s.pad>0 {p.width=min(p.width,f.width)}
            // What is solid fills the line it starts on, whatever it follows.
            if s.solid {f.glued,f.unit,f.unit_at,f.unit_x=true,f.count,0,0}
            for !flow_put(&f,font,&p) {layout_flow_line(t,font,text,keep,&f,&y)}
            continue
        }
        if s.text=="" {flow_space(&f,s.width);continue}
        // A text of one run that fits is as wide as it was measured, with the
        // kerning across its spaces: the width it asked for.
        if len(spans)==1 && !s.measure.breaks && s.measure.width<=f.width {
            p.width,p.gap=s.measure.width,0
            flow_put(&f,font,&p)
            continue
        }
        words:=layout_span_walk(t,font,&s)
        for {
            w,_,ok:=layout_walk(&words)
            if !ok {break}
            if w.length==0 {layout_flow_line(t,font,text,keep,&f,&y);continue}
            p.text,p.width,p.gap=s.text[w.start:][:w.length],w.width,0
            for !flow_put(&f,font,&p) {layout_flow_line(t,font,text,keep,&f,&y)}
        }
    }
    if f.count>0 {layout_flow_line(t,font,text,keep,&f,&y)}
    return max(y,text.line)
}

FLOW_PIECES :: 64 // pieces of one line of spans; a line that holds more goes on in the next

// A piece of a line: the words of one span that are on it, or a box.
@(private)
Flow_Piece :: struct {
    span:i32,    // in the spans of its flow
    text:string, // of its span
    x,width:f32, // in its line; width: with the spaces its text ends in
    gap:f32,     // room after it that is no part of it
}
// A line being filled with the words of spans: how every text breaks. Words
// come from layout_walk; a word that does not fit starts the next line, a
// word wider than the line breaks after its last glyph that fits, a line gives
// up the space it breaks at and draws the hyphen of a soft hyphen it breaks
// at, and pieces that no space or mark parts stay on one line. When flow_put
// refuses a piece the line is full: its owner keeps what flow_line gives,
// calls flow_next and puts the piece again.
@(private)
Flow :: struct {
    spans:[]Layout_Span, // what its pieces are of
    pieces:[FLOW_PIECES]Flow_Piece,
    count:int,
    used,width:f32,
    glued:bool,   // the line may not break after the piece put last
    unit:int,     // where the pieces no space parts start: the piece,
    unit_at:int,  // the byte of its text
    unit_x:f32,   // and the place in the line
    ready:int,    // pieces of the line that is full
}

// A piece a space can part: neither a box nor a chip.
@(private)
flow_words :: #force_inline proc "contextless" (f:^Flow,p:^Flow_Piece) -> bool {
    s:=&f.spans[p.span]
    return !s.box && s.pad==0
}
@(private)
flow_joins :: proc "contextless" (f:^Flow,p:^Flow_Piece) -> bool {
    if f.count==0 || !flow_words(f,p) {return false}
    last:=&f.pieces[f.count-1]
    return last.span==p.span && last.gap==0 && uintptr(raw_data(last.text))+uintptr(len(last.text))==uintptr(raw_data(p.text))
}
// Adds a piece where the line ends, whether it fits or not.
@(private)
flow_add :: proc "contextless" (f:^Flow,p:Flow_Piece) {
    p:=p
    if flow_joins(f,&p) {
        last:=&f.pieces[f.count-1]
        last.text=string(raw_data(last.text)[:len(last.text)+len(p.text)])
        last.width+=p.width
    } else if f.count<FLOW_PIECES {
        p.x=f.used
        f.pieces[f.count]=p
        f.count+=1
    }
    f.used+=p.width+p.gap
}
@(private)
flow_put :: proc "contextless" (f:^Flow,font:^Font,p:^Flow_Piece) -> bool {
    joins:=flow_joins(f,p)
    s:=&f.spans[p.span]
    if !f.glued {
        f.unit,f.unit_at,f.unit_x=f.count,0,f.used
        if joins {f.unit,f.unit_at=f.count-1,len(f.pieces[f.count-1].text)}
    }
    if room:=f.width-f.used;p.width>room {
        if f.unit_x>0 {
            // What no space parts from the piece goes with it to the next line.
            f.ready=f.unit
            if f.unit_at>0 && f.unit_at==len(f.pieces[f.unit].text) {
                f.ready=f.unit+1
            } else if f.unit_at>0 {
                if f.count==FLOW_PIECES {f.ready=f.count;return false}
                copy(f.pieces[f.unit+2:f.count+1],f.pieces[f.unit+1:f.count])
                f.count+=1
                head,tail:=&f.pieces[f.unit],&f.pieces[f.unit+1]
                tail^=head^
                tail.text,tail.x,tail.width=head.text[f.unit_at:],f.unit_x,head.x+head.width-f.unit_x
                head.text,head.width,head.gap=head.text[:f.unit_at],f.unit_x-head.x,0
                f.ready=f.unit+1
            }
            return false
        }
        bare:=len(p.text)
        for bare>0 && p.text[bare-1]==' ' {bare-=1}
        if !s.box && bare>0 {
            n,width:=text_prefix(font,p.text,s.size,room-s.pad,int(s.font))
            // A line holds at least one character.
            if n==0 && f.count==0 {
                n=1
                for n<len(p.text) && p.text[n]&0xc0==0x80 {n+=1}
                width=text_width(font,p.text[:n],s.size,int(s.font))
            }
            if n<bare {
                if n>0 {
                    head:=p^
                    head.text,head.width,head.gap=p.text[:n],width+s.pad,0
                    flow_add(f,head)
                    // The rest is the word less its head and the kerning across the cut,
                    // so a long word is not measured again at each of its lines.
                    a,b:=n-1,n+1
                    for a>0 && p.text[a]&0xc0==0x80 {a-=1}
                    for b<len(p.text) && p.text[b]&0xc0==0x80 {b+=1}
                    pair:=text_width(font,p.text[a:b],s.size,int(s.font))
                    kern:=pair-text_width(font,p.text[a:n],s.size,int(s.font))-text_width(font,p.text[n:b],s.size,int(s.font))
                    p.text=p.text[n:]
                    p.width-=width+kern
                }
                f.ready=f.count
                return false
            }
        } else if f.count>0 {
            f.ready=f.count
            return false
        }
    }
    if !joins && f.count==FLOW_PIECES {f.ready=f.count;return false}
    flow_add(f,p^)
    f.glued=!flow_words(f,p) || p.text==""
    if !f.glued {
        switch text_mark(p.text,len(p.text)) {
        case 0:f.glued=p.text[len(p.text)-1]!=' '
        // A soft hyphen breaks only where the hyphen it draws still fits.
        case 2:f.glued=f.used+text_width(font,"-",s.size,int(s.font))>f.width
        }
    }
    return true
}
// Room as wide as a space after what the line holds: a word ends there.
@(private)
flow_space :: proc "contextless" (f:^Flow,width:f32) {
    f.glued=false
    if f.count==0 {return}
    f.pieces[f.count-1].gap+=width
    f.used+=width
}
// The pieces of the line that is full, or of all that was put when its owner
// ends it; it gives up the space it ends at.
@(private)
flow_line :: proc "contextless" (f:^Flow,font:^Font) -> []Flow_Piece {
    if f.ready==0 {f.ready,f.glued=f.count,false}
    n:=f.ready
    if n>0 {
        last:=&f.pieces[n-1]
        if s:=&f.spans[last.span];flow_words(f,last) && len(last.text)>0 {
            if last.text[len(last.text)-1]==' ' {
                last.text=last.text[:len(last.text)-1]
                last.width-=text_width(font," ",s.size,int(s.font))
                if last.text=="" {n-=1}
            } else if text_mark(last.text,len(last.text))==2 {
                last.width+=text_width(font,"-",s.size,int(s.font))
            }
        }
    }
    return f.pieces[:n]
}
// Starts the next line with what the full one left for it.
@(private)
flow_next :: proc "contextless" (f:^Flow) {
    left:=f.count-f.ready
    start:=f.pieces[f.ready].x if left>0 else f.used
    copy(f.pieces[:left],f.pieces[f.ready:f.count])
    for &p in f.pieces[:left] {p.x-=start}
    f.count,f.used,f.ready=left,f.used-start,0
    f.unit,f.unit_at,f.unit_x=0,0,0
}

// ---------------------------------------------------------------- sizes

@(private)
axis_min :: #force_inline proc "contextless" (s:Size) -> f32 {return s.value if s.kind==.Fixed else s.min}
@(private)
axis_max :: #force_inline proc "contextless" (s:Size) -> f32 {
    if s.kind==.Fixed {return s.value}
    return s.max if s.max>0 else math.F32_MAX
}
// The share of what is left a growing size takes against the others.
@(private)
grow_weight :: #force_inline proc "contextless" (s:Size) -> f32 {return s.value if s.value>0 else 1}

// How a node is sized in one axis: the axis its aspect gives is as fixed as
// the one that gives it.
@(private)
axis_sizing :: #force_inline proc "contextless" (n:^Layout_Node,x:bool) -> Size {
    l:=&n.layout
    s:=l.width if x else l.height
    if l.aspect>0 && s.kind!=.Fixed && (!x || l.height.kind==.Fixed) {return fixed(n.dim.x if x else n.dim.y)}
    return s
}
// A child that stretches across its parent, inside its cell or in a stack.
@(private)
stretches :: #force_inline proc "contextless" (n:^Layout_Node,x:bool) -> bool {
    return (n.layout.self_x if x else n.layout.self_y)==.Stretch
}
@(private)
self_align :: #force_inline proc "contextless" (parent:Align,own:Self_Align) -> Align {
    switch own {
    case .Parent:        return parent
    case .Start,.Stretch:return .Start
    case .Center:        return .Center
    case .End:           return .End
    }
    return parent
}

// What a container asks for, from the children it closed with: along its
// direction they add up, across it the largest one counts. What clips in an
// axis does not ask for its content in that axis. A wrap asks for one line
// and accepts its widest child; a stack, its largest child.
@(private)
layout_fit :: proc(t:^Layout_Tree,n:^Layout_Node) {
    l:=&n.layout
    left_right:=l.padding[0]+l.padding[2]
    top_bottom:=l.padding[1]+l.padding[3]
    kids:=t.kids[n.kids_first:][:n.kids_len]
    gap:=f32(max(len(kids)-1,0))*l.gap
    switch l.direction {
    case .Grid:
        layout_fit_grid(t,n,kids)
    case .Row,.Wrap:
        row:=l.direction==.Row
        n.dim={left_right,0}
        n.min_dim={left_right,0}
        for index in kids {
            child:=&t.nodes[index]
            n.dim.x+=child.dim.x
            n.dim.y=max(n.dim.y,child.dim.y+top_bottom)
            if !n.clip_x {n.min_dim.x=n.min_dim.x+child.min_dim.x if row else max(n.min_dim.x,child.min_dim.x+left_right)}
            if !n.clip_y {n.min_dim.y=max(n.min_dim.y,child.min_dim.y+top_bottom)}
        }
        n.dim.x+=gap
        if row {n.min_dim.x+=gap}
    case .Column:
        n.dim={0,top_bottom}
        n.min_dim={0,top_bottom}
        for index in kids {
            child:=&t.nodes[index]
            n.dim.y+=child.dim.y
            n.dim.x=max(n.dim.x,child.dim.x+left_right)
            if !n.clip_y {n.min_dim.y+=child.min_dim.y}
            if !n.clip_x {n.min_dim.x=max(n.min_dim.x,child.min_dim.x+left_right)}
        }
        n.dim.y+=gap
        n.min_dim.y+=gap
    case .Stack:
        n.dim={left_right,top_bottom}
        n.min_dim=n.dim
        for index in kids {
            child:=&t.nodes[index]
            n.dim={max(n.dim.x,child.dim.x+left_right),max(n.dim.y,child.dim.y+top_bottom)}
            if !n.clip_x {n.min_dim.x=max(n.min_dim.x,child.min_dim.x+left_right)}
            if !n.clip_y {n.min_dim.y=max(n.min_dim.y,child.min_dim.y+top_bottom)}
        }
    }
    layout_limit(n)
    // A fixed axis gives the other its size; any other width gives the height once it is known.
    if l.aspect>0 {
        if l.width.kind==.Fixed {
            n.dim.y=clamp(n.dim.x/l.aspect,axis_min(l.height),axis_max(l.height))
            n.min_dim.y=n.dim.y
        } else if l.height.kind==.Fixed {
            n.dim.x=n.dim.y*l.aspect
            n.min_dim.x=n.dim.x
        }
    }
}

// The children a container closed with, from pending to a run of kids of its own.
@(private)
layout_kids :: proc(t:^Layout_Tree,n:^Layout_Node) {
    count:=int(n.kids_len)
    first:=t.pending_len-count
    t.pending_len=first
    n.kids_first=i32(t.kids_len)
    copy(t.kids[t.kids_len:][:count],t.pending[first:][:count])
    t.kids_len+=count
}
// What an element asks for within the limits of its sizes; a percent asks for nothing.
@(private)
layout_limit :: proc "contextless" (n:^Layout_Node) {
    l:=&n.layout
    if l.width.kind!=.Percent {
        n.dim.x=clamp(n.dim.x,axis_min(l.width),axis_max(l.width))
        n.min_dim.x=clamp(n.min_dim.x,axis_min(l.width),axis_max(l.width))
    } else {n.dim.x=0}
    if l.height.kind!=.Percent {
        n.dim.y=clamp(n.dim.y,axis_min(l.height),axis_max(l.height))
        n.min_dim.y=clamp(n.min_dim.y,axis_min(l.height),axis_max(l.height))
    } else {n.dim.y=0}
}

// A Grid asks for its columns side by side, each as wide as its widest
// child (all the same without tracks; a child that spans columns shares its
// width among them), and its rows one under the other.
@(private)
layout_fit_grid :: proc(t:^Layout_Tree,n:^Layout_Node,kids:[]i32) {
    l:=&n.layout
    left_right:=l.padding[0]+l.padding[2]
    top_bottom:=l.padding[1]+l.padding[3]
    columns:=grid_columns(t,l)
    tracks:=grid_tracks_of(t,l)
    cell,least:f32
    fits,leasts:[GRID_TRACKS]f32
    n.dim={0,top_bottom}
    n.min_dim={0,top_bottom}
    g:=Grid_Cells{kids=kids,columns=columns}
    for {
        c,more:=grid_cell_next(t,&g)
        if !more {break}
        child:=&t.nodes[c.kid]
        if tracks==nil {
            spanned:=f32(c.span-1)*l.gap
            cell=max(cell,(child.dim.x-spanned)/f32(c.span))
            least=max(least,(child.min_dim.x-spanned)/f32(c.span))
        } else if c.span==1 {
            fits[c.column]=max(fits[c.column],child.dim.x)
            leasts[c.column]=max(leasts[c.column],child.min_dim.x)
        }
    }
    // The room the children it just closed with left in pending is free.
    heights:=grid_scratch(t.pending[t.pending_len:])
    rows:=grid_rows(t,n,kids,heights,.Asked,false)
    for high in heights[:rows] {n.dim.y+=high}
    if !n.clip_y {
        rows=grid_rows(t,n,kids,heights,.Least,false)
        for low in heights[:rows] {n.min_dim.y+=low}
    }
    gaps:=[2]f32{f32(columns-1),f32(max(rows-1,0))}*l.gap
    if len(kids)==0 {gaps={}}
    if tracks==nil {
        n.dim.x=left_right+cell*f32(columns)+gaps.x
        n.min_dim.x=left_right+(least*f32(columns)+gaps.x if !n.clip_x else 0)
    } else {
        wide,narrow:f32
        for track,c in tracks.columns[:columns] {
            if track.kind==.Fixed {wide+=track.value;narrow+=track.value;continue}
            wide+=max(fits[c],track.min)
            narrow+=max(leasts[c],track.min)
        }
        n.dim.x=left_right+wide+gaps.x
        n.min_dim.x=left_right+(narrow+gaps.x if !n.clip_x else 0)
    }
    n.dim.y+=gaps.y
    if !n.clip_y {n.min_dim.y+=gaps.y}
}

// Hands out the space of each container among its children in one axis:
// growing children share what is left, smallest first by their weights, and
// what does not fit is taken from the largest first, never below the least a
// child accepts.
@(private)
layout_size :: proc(t:^Layout_Tree,x:bool) {
    for &root in t.roots[:t.root_count] {
        r:=&t.nodes[root.node]
        // A growing floating element takes the size of what it hangs from, a percent its share of it.
        if r.floating {
            p:=[2]f32{root.rect.w,root.rect.h} if root.hung else t.nodes[root.parent].dim
            w,h:=r.layout.width,r.layout.height
            if w.kind==.Grow {r.dim.x=p.x} else if w.kind==.Percent {r.dim.x=p.x*w.value}
            if h.kind==.Grow {r.dim.y=p.y} else if h.kind==.Percent {r.dim.y=p.y*h.value}
        }
        r.dim.x=clamp(r.dim.x,axis_min(r.layout.width),axis_max(r.layout.width))
        r.dim.y=clamp(r.dim.y,axis_min(r.layout.height),axis_max(r.layout.height))
        t.scratch[0]=root.node
        queued:=1
        for i:=0;i<queued;i+=1 {
            parent:=&t.nodes[t.scratch[i]]
            l:=&parent.layout
            kids:=t.kids[parent.kids_first:][:parent.kids_len]
            for index in kids {
                if child:=&t.nodes[index];child.text<0 && child.kids_len>0 {
                    t.scratch[queued]=index
                    queued+=1
                }
            }
            #partial switch l.direction {
            case .Grid:
                layout_size_grid(t,parent,x)
                continue
            case .Wrap:
                layout_size_wrap(t,parent,x)
                continue
            }
            parent_size:=parent.dim.x if x else parent.dim.y
            parent_padding:=(l.padding[0]+l.padding[2]) if x else (l.padding[1]+l.padding[3])
            clips:=parent.clip_x if x else parent.clip_y
            along:=l.direction!=.Stack && (l.direction==.Row)==x
            inner:f32
            total:=parent_padding
            grow_count:=0
            weighted:=false
            t.pending_len=0
            for index,c in kids {
                child:=&t.nodes[index]
                sizing:=axis_sizing(child,x)
                // What is neither fixed nor a percentage shares the space; a run of
                // text is among them because its width decides its lines.
                if sizing.kind!=.Percent && sizing.kind!=.Fixed {
                    t.pending[t.pending_len]=index
                    t.pending_len+=1
                }
                if along {
                    inner+=0 if sizing.kind==.Percent else (child.dim.x if x else child.dim.y)
                    if sizing.kind==.Grow {
                        grow_count+=1
                        weighted||=grow_weight(sizing)!=1
                    }
                    if c>0 {
                        inner+=l.gap
                        total+=l.gap
                    }
                } else {inner=max(child.dim.x if x else child.dim.y,inner)}
            }
            // A percentage is a part of what the parent has once its padding
            // and the gaps between its children are out.
            for index in kids {
                child:=&t.nodes[index]
                sizing:=axis_sizing(child,x)
                if sizing.kind!=.Percent {continue}
                value:=(parent_size-total)*sizing.value
                if x {child.dim.x=value} else {child.dim.y=value}
                if along {inner+=value}
            }
            if !along {
                // Across the direction, a growing child fills its parent and
                // nothing goes past it, unless the parent clips: then it moves
                // what is inside, which can be larger.
                max_size:=parent_size-parent_padding
                if clips {max_size=max(max_size,inner)}
                for index in t.pending[:t.pending_len] {
                    child:=&t.nodes[index]
                    sizing:=axis_sizing(child,x)
                    size:=&child.dim.x if x else &child.dim.y
                    if sizing.kind==.Grow || stretches(child,x) {size^=min(max_size,axis_max(sizing))}
                    size^=max(child.min_dim.x if x else child.min_dim.y,min(size^,max_size))
                }
                continue
            }
            to_distribute:=parent_size-parent_padding-inner
            if to_distribute<0 {
                // What clips in this axis moves its content instead of shrinking it.
                if clips {continue}
                for to_distribute< -LAYOUT_EPSILON && t.pending_len>0 {
                    largest,second:f32
                    to_add:=to_distribute
                    for index in t.pending[:t.pending_len] {
                        size:=t.nodes[index].dim.x if x else t.nodes[index].dim.y
                        if math.abs(size-largest)<LAYOUT_EPSILON {continue}
                        if size>largest {second=largest;largest=size}
                        if size<largest {second=max(second,size);to_add=second-largest}
                    }
                    to_add=max(to_add,to_distribute/f32(t.pending_len))
                    for c:=0;c<t.pending_len; {
                        child:=&t.nodes[t.pending[c]]
                        size:=&child.dim.x if x else &child.dim.y
                        least:=child.min_dim.x if x else child.min_dim.y
                        if math.abs(size^-largest)<LAYOUT_EPSILON {
                            previous:=size^
                            size^=max(least,size^+to_add)
                            to_distribute-=size^-previous
                            if math.abs(size^-least)<LAYOUT_EPSILON {
                                t.pending_len-=1
                                t.pending[c]=t.pending[t.pending_len]
                                continue
                            }
                        }
                        c+=1
                    }
                }
            } else if to_distribute>0 && grow_count>0 {
                for c:=0;c<t.pending_len; {
                    if axis_sizing(&t.nodes[t.pending[c]],x).kind!=.Grow {
                        t.pending_len-=1
                        t.pending[c]=t.pending[t.pending_len]
                        continue
                    }
                    c+=1
                }
                if weighted {
                    layout_grow_weighted(t,x,to_distribute)
                    continue
                }
                for to_distribute>LAYOUT_EPSILON && t.pending_len>0 {
                    smallest,second:f32=math.F32_MAX,math.F32_MAX
                    to_add:=to_distribute
                    for index in t.pending[:t.pending_len] {
                        size:=t.nodes[index].dim.x if x else t.nodes[index].dim.y
                        if math.abs(size-smallest)<LAYOUT_EPSILON {continue}
                        if size<smallest {second=smallest;smallest=size}
                        if size>smallest {second=min(second,size);to_add=second-smallest}
                    }
                    to_add=min(to_add,to_distribute/f32(t.pending_len))
                    for c:=0;c<t.pending_len; {
                        child:=&t.nodes[t.pending[c]]
                        size:=&child.dim.x if x else &child.dim.y
                        most:=axis_max(child.layout.width if x else child.layout.height)
                        if math.abs(size^-smallest)<LAYOUT_EPSILON {
                            previous:=size^
                            size^=min(most,size^+to_add)
                            to_distribute-=size^-previous
                            if math.abs(size^-most)<LAYOUT_EPSILON {
                                t.pending_len-=1
                                t.pending[c]=t.pending[t.pending_len]
                                continue
                            }
                        }
                        c+=1
                    }
                }
            }
        }
    }
}

// What is left along a direction, among the growing children in pending by
// their weights: the one whose size over its weight is the least grows first,
// until it meets the next, as the children of weight one do by their sizes.
@(private)
layout_grow_weighted :: proc(t:^Layout_Tree,x:bool,left:f32) {
    to_distribute:=left
    for to_distribute>LAYOUT_EPSILON && t.pending_len>0 {
        smallest,second:f32=math.F32_MAX,math.F32_MAX
        weights:f32
        for index in t.pending[:t.pending_len] {
            child:=&t.nodes[index]
            weight:=grow_weight(child.layout.width if x else child.layout.height)
            weights+=weight
            level:=(child.dim.x if x else child.dim.y)/weight
            if math.abs(level-smallest)<LAYOUT_EPSILON {continue}
            if level<smallest {second=smallest;smallest=level}
            if level>smallest {second=min(second,level)}
        }
        to_add:=to_distribute/weights
        if second<math.F32_MAX {to_add=min(to_add,second-smallest)}
        before:=to_distribute
        for c:=0;c<t.pending_len; {
            child:=&t.nodes[t.pending[c]]
            sizing:=child.layout.width if x else child.layout.height
            weight:=grow_weight(sizing)
            size:=&child.dim.x if x else &child.dim.y
            most:=axis_max(sizing)
            if math.abs(size^/weight-smallest)<LAYOUT_EPSILON {
                previous:=size^
                size^=min(most,size^+to_add*weight)
                to_distribute-=size^-previous
                if math.abs(size^-most)<LAYOUT_EPSILON {
                    t.pending_len-=1
                    t.pending[c]=t.pending[t.pending_len]
                    continue
                }
            }
            c+=1
        }
        if before-to_distribute<=LAYOUT_EPSILON*0.01 {break}
    }
}

// The lines a run took and the sizes across a direction change the height of
// what holds them: it travels from the leaves back to the roots. What keeps
// an aspect keeps the height its width gave it.
@(private)
layout_heights :: proc(t:^Layout_Tree,index:i32) {
    n:=&t.nodes[index]
    if n.text>=0 || n.kids_len==0 {return}
    kids:=t.kids[n.kids_first:][:n.kids_len]
    for kid in kids {layout_heights(t,kid)}
    l:=&n.layout
    if l.aspect>0 {return}
    switch l.direction {
    case .Grid:
        content:=l.padding[1]+l.padding[3]
        heights:=grid_scratch(t.scratch)
        rows:=grid_rows(t,n,kids,heights,.Asked,false)
        for high in heights[:rows] {content+=high}
        content+=f32(max(rows-1,0))*l.gap
        n.dim.y=clamp(content,axis_min(l.height),axis_max(l.height))
    case .Wrap:
        content:=l.padding[1]+l.padding[3]
        inner:=n.dim.x-l.padding[0]-l.padding[2]
        rows:=0
        for start:=0;start<len(kids);rows+=1 {
            end,_:=wrap_line(t,kids,start,inner,l.gap)
            high:f32
            for kid in kids[start:end] {high=max(high,t.nodes[kid].dim.y)}
            content+=high
            start=end
        }
        content+=f32(max(rows-1,0))*l.gap
        n.dim.y=clamp(content,axis_min(l.height),axis_max(l.height))
    case .Row,.Stack:
        for kid in kids {
            n.dim.y=clamp(max(t.nodes[kid].dim.y+l.padding[1]+l.padding[3],n.dim.y),axis_min(l.height),axis_max(l.height))
        }
        // On one baseline the children take what the highest takes over it and the deepest under it.
        if l.direction==.Row && l.align_y==.Baseline {
            above,below:f32
            for kid in kids {
                ascent:=layout_ascent(t,kid)
                above,below=max(above,ascent),max(below,t.nodes[kid].dim.y-ascent)
            }
            n.dim.y=clamp(max(above+below+l.padding[1]+l.padding[3],n.dim.y),axis_min(l.height),axis_max(l.height))
        }
    case .Column:
        content:=l.padding[1]+l.padding[3]
        for kid in kids {content+=t.nodes[kid].dim.y}
        content+=f32(max(n.kids_len-1,0))*l.gap
        n.dim.y=clamp(content,axis_min(l.height),axis_max(l.height))
    }
}

// ---------------------------------------------------------------- placement

@(private)
layout_finish :: proc(t:^Layout_Tree,font:^Font,frame:u64,dt:f32) -> (moving:bool) {
    // The surface closes like any container, which puts the elements of the
    // top level inside it.
    layout_kids(t,&t.nodes[0])
    t.dt=dt if dt>0 else 0
    layout_solve(t,font)
    if layout_transitions_size(t,frame) {
        for i:=t.node_count-1;i>0;i-=1 {
            n:=&t.nodes[i]
            if n.text>=0 {layout_fit_text(t,font,n)} else {layout_fit(t,n)}
        }
        layout_solve(t,font)
    }
    // A floating element of a higher layer covers the lower ones; within a
    // layer, what was declared later covers what was declared before.
    for i in 1..<t.root_count {
        root:=t.roots[i]
        j:=i
        for j>0 && t.roots[j-1].layer>root.layer {t.roots[j]=t.roots[j-1];j-=1}
        t.roots[j]=root
    }
    for &root in t.roots[:t.root_count] {
        root.first_command=i32(t.command_count)
        r:=&t.nodes[root.node]
        position,origin:[2]f32
        if r.floating {
            p:=root.rect if root.hung else t.nodes[root.parent].box
            origin={p.x,p.y}
            position=float_position(p,root.anchor,root.pivot,root.offset,r.dim)
            if root.contain {
                bounds:=t.nodes[root.within].box
                bounds={bounds.x+root.inset[0],bounds.y+root.inset[1],max(bounds.w-root.inset[0]-root.inset[2],0),max(bounds.h-root.inset[1]-root.inset[3],0)}
                position=float_contain(p,&root,r.dim,bounds,position)
            }
        }
        layout_place(t,root.node,position,origin,t.ppu)
    }
    for &e in t.transitions {moving||=e.frame==frame && e.placed && e.time<e.seconds}
    return
}

// Sizes every element from what the leaves ask, one axis at a time.
@(private)
layout_solve :: proc(t:^Layout_Tree,font:^Font) {
    t.line_count,t.piece_count=0,0
    layout_fit(t,&t.nodes[0])
    layout_size(t,true)
    // What keeps an aspect takes the height its width gives.
    if t.aspects {
        for &n in t.nodes[1:t.node_count] {
            l:=&n.layout
            if l.aspect<=0 || l.height.kind==.Fixed {continue}
            n.dim.y=clamp(n.dim.x/l.aspect,axis_min(l.height),axis_max(l.height))
            n.min_dim.y=n.dim.y
        }
    }
    // Every text breaks at the width it was given, and one whose height fits takes that of its lines.
    for &text in t.texts[:t.text_count] {
        n:=&t.nodes[text.node]
        height:=layout_text_wrap(t,font,&text,n.dim.x,true)
        if l:=&n.layout;l.height.kind==.Fit {n.dim.y=clamp(layout_whole(t.ppu,height),axis_min(l.height),axis_max(l.height))}
    }
    for root in t.roots[:t.root_count] {layout_heights(t,root.node)}
    layout_size(t,false)
}

// Asks that the element id of this frame go from where it was drawn to where
// the layout puts it over seconds. One not asked for the frame before, as a
// node shown again, starts where it is laid out. False when every rectangle
// the layout keeps was asked for this frame or the last.
@(private)
layout_transition_ask :: proc "contextless" (t:^Layout_Tree,id:Id,seconds:f32,frame:u64) -> bool {
    if id==0 || !(seconds>0 && seconds<math.F32_MAX) {return true}
    mask:=u64(len(t.transitions)-1)
    free:^Layout_Transition
    for probe in 0..<len(t.transitions) {
        e:=&t.transitions[(u64(id)+u64(probe))&mask]
        if e.id==id {
            if e.frame+1<frame {e^={id=id}}
            e.frame,e.seconds=frame,seconds
            return true
        }
        if free==nil && (e.id==0 || e.frame+1<frame) {free=e}
        if e.id==0 {break}
    }
    if free==nil {return false}
    free^={id=id,frame=frame,seconds=seconds}
    return true
}

// Advances the elements that transition this frame and gives each the size it
// has on its way in place of the one it asked for, so the layout around it
// follows. True when a size changed: the layout runs again.
@(private)
layout_transitions_size :: proc(t:^Layout_Tree,frame:u64) -> (resized:bool) {
    surface:=t.nodes[0].dim
    for &e,i in t.transitions {
        if e.frame!=frame {continue}
        index:=layout_index(t,e.id)
        if index==0 {e.frame=0;continue}
        n:=&t.nodes[index]
        n.transition=i32(i+1)
        if !e.placed || e.surface!=surface {continue}
        e.time=min(e.time+t.dt,e.seconds)
        if !layout_near(n.dim,{e.to.w,e.to.h}) {layout_transition_start(&e,t.dt);e.to.w,e.to.h=n.dim.x,n.dim.y}
        now:=layout_transition_mix(&e)
        if layout_near({now.w,now.h},n.dim) {continue}
        n.layout.width,n.layout.height=fixed(now.w),fixed(now.h)
        resized=true
    }
    return
}

// Where an element that transitions is drawn, from the corner of the content
// of its parent: on its way to at, where the layout put it. The first time, or
// on a surface of another size, it is at at once.
@(private)
layout_transition_place :: proc "contextless" (e:^Layout_Transition,at,dim,surface:[2]f32,dt:f32) -> [2]f32 {
    if !e.placed || e.surface!=surface {
        e.from,e.placed,e.surface,e.time={at.x,at.y,dim.x,dim.y},true,surface,e.seconds
        e.to,e.now=e.from,e.from
        return at
    }
    if !layout_near(at,{e.to.x,e.to.y}) {layout_transition_start(e,dt);e.to.x,e.to.y=at.x,at.y}
    now:=layout_transition_mix(e)
    e.now={now.x,now.y,dim.x,dim.y}
    return {now.x,now.y}
}

// A new place or size starts from where the element is now, with this frame on its way.
@(private)
layout_transition_start :: #force_inline proc "contextless" (e:^Layout_Transition,dt:f32) {
    e.from,e.time=e.now,min(dt,e.seconds)
}

@(private)
layout_transition_mix :: proc "contextless" (e:^Layout_Transition) -> Rect {
    k:=mm.ease_apply(.Cubic_Out,min(e.time/e.seconds,1))
    a,b:=e.from,e.to
    return {a.x+(b.x-a.x)*k,a.y+(b.y-a.y)*k,a.w+(b.w-a.w)*k,a.h+(b.h-a.h)*k}
}

@(private)
layout_near :: #force_inline proc "contextless" (a,b:[2]f32) -> bool {
    return abs(a.x-b.x)<=LAYOUT_EPSILON && abs(a.y-b.y)<=LAYOUT_EPSILON
}

// Where a floating element of size dim goes against the rectangle p it hangs from.
@(private)
float_position :: proc "contextless" (p:Rect,anchor,pivot:Anchor,offset,dim:[2]f32) -> [2]f32 {
    a:=[2]f32{f32(int(anchor)/3),f32(int(anchor)%3)}*0.5
    b:=[2]f32{f32(int(pivot)/3),f32(int(pivot)%3)}*0.5
    return [2]f32{p.x,p.y}+[2]f32{p.w,p.h}*a-dim*b+offset
}

// A floating element that does not fit inside bounds in an axis goes to the
// other side of what it hangs from when it fits better there, and then moves
// in as far as it has to. One lined up with what it hangs from in that axis,
// its own point on the same side, only moves in.
@(private)
float_contain :: proc "contextless" (p:Rect,root:^Layout_Root,dim:[2]f32,bounds:Rect,position:[2]f32) -> [2]f32 {
    position:=position
    low:=[2]f32{bounds.x,bounds.y}
    high:=low+[2]f32{bounds.w,bounds.h}
    origin,size:=[2]f32{p.x,p.y},[2]f32{p.w,p.h}
    anchor:=[2]int{int(root.anchor)/3,int(root.anchor)%3}
    pivot:=[2]int{int(root.pivot)/3,int(root.pivot)%3}
    out :: proc "contextless" (at,dim,low,high:f32) -> f32 {return max(low-at,0)+max(at+dim-high,0)}
    for axis in 0..<2 {
        if out(position[axis],dim[axis],low[axis],high[axis])<=LAYOUT_EPSILON {continue}
        if anchor[axis]!=pivot[axis] {
            other:=origin[axis]+size[axis]*f32(2-anchor[axis])*0.5-dim[axis]*f32(2-pivot[axis])*0.5-root.offset[axis]
            if out(other,dim[axis],low[axis],high[axis])<out(position[axis],dim[axis],low[axis],high[axis]) {position[axis]=other}
        }
        position[axis]=clamp(position[axis],low[axis],max(high[axis]-dim[axis],low[axis]))
    }
    return position
}

// The children are placed from the place of their parent as laid out and each
// box is rounded on its own, so neighbours share an edge. What transitions is
// not rounded while it moves, nor what it holds: ppu 0.
@(private)
layout_place :: proc(t:^Layout_Tree,index:i32,position,origin:[2]f32,ppu:f32) {
    n:=&t.nodes[index]
    position:=position
    ppu:=ppu
    if n.transition>0 {
        e:=&t.transitions[n.transition-1]
        position=origin+layout_transition_place(e,position-origin,n.dim,t.nodes[0].dim,t.dt)
        if e.time<e.seconds {ppu=0}
    }
    n.box={position.x,position.y,n.dim.x,n.dim.y}
    if ppu>0 {
        // Edges on whole device pixels and the size between them (taffy's round_layout).
        lo:=[2]f32{math.round(position.x*ppu),math.round(position.y*ppu)}
        hi:=[2]f32{math.round((position.x+n.dim.x)*ppu),math.round((position.y+n.dim.y)*ppu)}
        if abs(hi.x)+abs(hi.y)<math.F32_MAX {n.box={lo.x/ppu,lo.y/ppu,(hi.x-lo.x)/ppu,(hi.y-lo.y)/ppu}}
    }
    if n.text>=0 {
        layout_place_text(t,index)
        return
    }
    clips:=n.clip_x || n.clip_y
    if clips {layout_command(t,{.Scissor_Start,index,0})}
    if n.custom!=nil {layout_command(t,{.Custom,index,0})}
    if n.kids_len>0 {
        l:=&n.layout
        kids:=t.kids[n.kids_first:][:n.kids_len]
        offset:=-n.scroll if clips else [2]f32{}
        left_right:=l.padding[0]+l.padding[2]
        top_bottom:=l.padding[1]+l.padding[3]
        gaps:=f32(max(n.kids_len-1,0))*l.gap
        switch l.direction {
        case .Grid:
            widths:[GRID_TRACKS]f32
            columns,cell,tracked:=grid_widths(t,n,kids,&widths)
            // The heights of the rows are in a room a child placed would write over: every child gets its place first.
            heights:=grid_scratch(t.pending)
            rows:=grid_rows(t,n,kids,heights,.Given,true)
            y:=position.y+l.padding[1]
            row:=0
            g:=Grid_Cells{kids=kids,columns=columns}
            for {
                c,more:=grid_cell_next(t,&g)
                if !more {break}
                for row<c.row && row<rows {y+=heights[row]+l.gap;row+=1}
                child:=&t.nodes[c.kid]
                width:=grid_span_width(widths[:],cell,tracked,c.column,c.span,l.gap)
                x:=position.x+l.padding[0]
                if tracked {
                    for w in widths[:c.column] {x+=w+l.gap}
                } else {x+=f32(c.column)*(cell+l.gap)}
                high:=grid_span_height(heights[:rows],c,l.gap)
                child.box.x=x+align_offset(self_align(l.align_x,child.layout.self_x),width-child.dim.x)+offset.x
                child.box.y=y+align_offset(self_align(l.align_y,child.layout.self_y),high-child.dim.y)+offset.y
            }
            for kid in kids {layout_place(t,kid,{t.nodes[kid].box.x,t.nodes[kid].box.y},position+offset,ppu)}
        case .Wrap:
            inner:=n.dim.x-left_right
            y:=position.y+l.padding[1]
            for start:=0;start<len(kids); {
                end,used:=wrap_line(t,kids,start,inner,l.gap)
                high:f32
                for kid in kids[start:end] {high=max(high,t.nodes[kid].dim.y)}
                x:=position.x+l.padding[0]+align_offset(l.align_x,inner-used)
                for kid in kids[start:end] {
                    child:=&t.nodes[kid]
                    layout_place(t,kid,[2]f32{x,y+align_offset(self_align(l.align_y,child.layout.self_y),high-child.dim.y)}+offset,position+offset,ppu)
                    x+=child.dim.x+l.gap
                }
                y+=high+l.gap
                start=end
            }
        case .Stack:
            for kid in kids {
                child:=&t.nodes[kid]
                at:=position+{l.padding[0],l.padding[1]}
                at.x+=align_offset(self_align(l.align_x,child.layout.self_x),n.dim.x-left_right-child.dim.x)
                at.y+=align_offset(self_align(l.align_y,child.layout.self_y),n.dim.y-top_bottom-child.dim.y)
                layout_place(t,kid,at+offset,position+offset,ppu)
            }
        case .Row,.Column:
            row:=l.direction==.Row
            next:=position
            content:f32
            baseline:=row && l.align_y==.Baseline
            ascent:f32
            if baseline {
                for kid in kids {ascent=max(ascent,layout_ascent(t,kid))}
            }
            if row {
                for kid in kids {content+=t.nodes[kid].dim.x}
                next.x+=l.padding[0]+align_offset(l.align_x,n.dim.x-left_right-(content+gaps))
                next.y=position.y+l.padding[1]
            } else {
                for kid in kids {content+=t.nodes[kid].dim.y}
                next.y+=l.padding[1]+align_offset(l.align_y,n.dim.y-top_bottom-(content+gaps))
                next.x=position.x+l.padding[0]
            }
            for kid in kids {
                child:=&t.nodes[kid]
                at:=next+offset
                if baseline && child.layout.self_y==.Parent {
                    at.y=position.y+l.padding[1]+ascent-layout_ascent(t,kid)+offset.y
                } else if row {
                    at.y=position.y+l.padding[1]+align_offset(self_align(l.align_y,child.layout.self_y),n.dim.y-top_bottom-child.dim.y)+offset.y
                } else {
                    at.x=position.x+l.padding[0]+align_offset(self_align(l.align_x,child.layout.self_x),n.dim.x-left_right-child.dim.x)+offset.x
                }
                layout_place(t,kid,at,position+offset,ppu)
                if row {next.x+=child.dim.x+l.gap} else {next.y+=child.dim.y+l.gap}
            }
        }
    }
    if n.border>0 {layout_command(t,{.Border,index,0})}
    if clips {layout_command(t,{.Scissor_End,index,0})}
}

// The lines of a text inside its element: those whose text fits, the first
// always, aligned as the text says. The last one in sight of more, or one too
// wide, ends in an ellipsis when the text asks for it.
@(private)
layout_place_text :: proc(t:^Layout_Tree,index:i32) {
    n:=&t.nodes[index]
    text:=&t.texts[n.text]
    lines:=t.lines[text.lines_first:][:text.lines_len]
    shown:=len(lines)
    if text.height>n.dim.y+LAYOUT_EPSILON {
        glyphs:=text.size*TEXT_LINE
        shown=0
        for &line in lines {
            if shown>0 && line.y+(line.height+glyphs)*0.5>n.dim.y+LAYOUT_EPSILON {break}
            shown+=1
        }
    }
    text.shown=i32(shown)
    if shown==0 {return}
    y:=n.box.y+align_offset(text.align_y,n.box.h-(lines[shown-1].y+lines[shown-1].height))
    for &line,i in lines[:shown] {
        line.x=n.box.x+align_offset(text.align_x,n.box.w-line.width)
        line.y+=y
        line.cut=text.ellipsis && (line.width>n.dim.x+LAYOUT_EPSILON || i==shown-1 && shown<len(lines))
        if line.pieces_len>0 {layout_command(t,{.Text,index,text.lines_first+i32(i)})}
    }
}

// ---------------------------------------------------------------- grids and wraps

// The tracks of a Grid, when it names a row of those of the frame that has columns.
@(private)
grid_tracks_of :: #force_inline proc "contextless" (t:^Layout_Tree,l:^Layout) -> ^Grid_Tracks {
    if l.tracks==0 || int(l.tracks)>t.track_count || t.tracks[l.tracks-1].count==0 {return nil}
    return &t.tracks[l.tracks-1]
}
// The tracks of the rows of a Grid, when it names a row of those of the frame that has rows.
@(private)
grid_row_tracks_of :: #force_inline proc "contextless" (t:^Layout_Tree,n:^Layout_Node) -> ^Grid_Tracks {
    if n.row_tracks==0 || int(n.row_tracks)>t.track_count || t.tracks[n.row_tracks-1].count==0 {return nil}
    return &t.tracks[n.row_tracks-1]
}
@(private)
grid_columns :: #force_inline proc "contextless" (t:^Layout_Tree,l:^Layout) -> int {
    if tracks:=grid_tracks_of(t,l);tracks!=nil {return min(int(tracks.count),GRID_TRACKS)}
    return max(int(l.columns),1)
}
@(private)
grid_span :: #force_inline proc "contextless" (n:^Layout_Node,columns:int) -> int {return clamp(int(n.layout.span),1,columns)}

// The width of a cell of a Grid without tracks, from the width it was given.
@(private)
grid_cell :: proc "contextless" (t:^Layout_Tree,n:^Layout_Node) -> f32 {
    l:=&n.layout
    columns:=grid_columns(t,l)
    return max((n.dim.x-l.padding[0]-l.padding[2]-f32(columns-1)*l.gap)/f32(columns),0)
}

// Columns a child that takes more than one row holds under it; past them a
// child takes one row.
@(private)
GRID_HELD_COLUMNS :: 64

// The cells of a Grid in the order of its children: each takes the next
// columns that are free in its row, on the row below when the row has no
// room left for it. A child of several rows keeps its columns in the rows
// under it, and the children after it flow around them.
@(private)
Grid_Cells :: struct {
    kids:[]i32,
    columns:int,
    at,row,column:int,
    held:[GRID_HELD_COLUMNS]u16, // rows a column is taken for from above, this one included
}
@(private)
Grid_Cell :: struct {kid:i32,row,column,span,rows:int}
@(private)
grid_cell_next :: proc "contextless" (t:^Layout_Tree,g:^Grid_Cells) -> (cell:Grid_Cell,ok:bool) {
    if g.at>=len(g.kids) {return}
    child:=&t.nodes[g.kids[g.at]]
    span:=grid_span(child,g.columns)
    held:=g.held[:min(g.columns,GRID_HELD_COLUMNS)]
    place: for {
        if g.column>0 && g.column+span>g.columns {
            g.row+=1
            g.column=0
            for &h in held {if h>0 {h-=1}}
            continue
        }
        for c in g.column..<min(g.column+span,len(held)) {
            if held[c]>0 {
                g.column=c+1
                continue place
            }
        }
        break
    }
    rows:=max(int(child.row_span),1)
    if g.column+span>len(held) {rows=1}
    if rows>1 {
        for c in g.column..<g.column+span {held[c]=u16(rows)}
    }
    cell={g.kids[g.at],g.row,g.column,span,rows}
    g.column+=span
    g.at+=1
    return cell,true
}

// The width of span columns from column, with the gaps between them.
@(private)
grid_span_width :: proc "contextless" (widths:[]f32,cell:f32,tracked:bool,column,span:int,gap:f32) -> f32 {
    if !tracked {return cell*f32(span)+f32(span-1)*gap}
    width:=f32(span-1)*gap
    for w in widths[column:][:span] {width+=w}
    return width
}
// The height of the rows a cell takes, with the gaps between them.
@(private)
grid_span_height :: proc "contextless" (heights:[]f32,c:Grid_Cell,gap:f32) -> (height:f32) {
    last:=min(c.row+c.rows,len(heights))
    for r in c.row..<last {height+=heights[r]}
    return height+f32(max(last-c.row-1,0))*gap
}

// A room of whole numbers the layout is not using, as room for heights.
@(private)
grid_scratch :: #force_inline proc "contextless" (room:[]i32) -> []f32 {
    return ([^]f32)(raw_data(room))[:len(room)]
}

// Which height of a child counts for its row: what it asks for, the least it
// accepts, or, when the heights are handed out, the least of a child that
// takes the height of its row and what any other asks for.
@(private)
Grid_Height :: enum u8 {Asked,Least,Given}
@(private)
grid_child_height :: #force_inline proc "contextless" (n:^Layout_Node,mode:Grid_Height) -> f32 {
    switch mode {
    case .Asked: return n.dim.y
    case .Least: return n.min_dim.y
    case .Given:
        sizing:=axis_sizing(n,false)
        if sizing.kind==.Grow || sizing.kind==.Percent || sizing.kind==.Fit && stretches(n,false) {return n.min_dim.y}
    }
    return n.dim.y
}

// The height of each row of a Grid, into heights, and how many there are: a
// row is as high as its highest child of one row, or what its track says; a
// child of several rows that needs more than they have gives the rest to its
// last one. final: the height of the Grid is known, and its Percent rows take
// their part of it and its Grow rows share what is left by their weights.
@(private)
grid_rows :: proc "contextless" (t:^Layout_Tree,n:^Layout_Node,kids:[]i32,heights:[]f32,mode:Grid_Height,final:bool) -> (rows:int) {
    l:=&n.layout
    columns:=grid_columns(t,l)
    tracks:=grid_row_tracks_of(t,n)
    tracked:=0
    spans:=false
    g:=Grid_Cells{kids=kids,columns=columns}
    for {
        c,more:=grid_cell_next(t,&g)
        if !more {break}
        for rows<c.row+c.rows && rows<len(heights) {heights[rows]=0;rows+=1}
        if c.rows>1 {spans=true} else if c.row<rows {heights[c.row]=max(heights[c.row],grid_child_height(&t.nodes[c.kid],mode))}
    }
    inner:=max(n.dim.y-l.padding[1]-l.padding[3]-f32(max(rows-1,0))*l.gap,0)
    if tracks!=nil {
        tracked=min(rows,int(tracks.count),GRID_TRACKS)
        for track,r in tracks.columns[:tracked] {
            switch track.kind {
            case .Fixed:    heights[r]=track.value
            case .Percent:  if final {heights[r]=inner*track.value}
            case .Fit,.Grow:heights[r]=clamp(heights[r],track.min,axis_max(track))
            }
        }
    }
    if spans {
        g={kids=kids,columns=columns}
        for {
            c,more:=grid_cell_next(t,&g)
            if !more {break}
            if c.rows<=1 || c.row>=rows {continue}
            last:=min(c.row+c.rows,rows)-1
            if last<tracked && tracks.columns[last].kind==.Fixed {continue}
            if need:=grid_child_height(&t.nodes[c.kid],mode)-grid_span_height(heights[:rows],c,l.gap);need>0 {heights[last]+=need}
        }
    }
    if !final || tracked==0 {return}
    left:=inner
    for high in heights[:rows] {left-=high}
    for left>LAYOUT_EPSILON {
        weights:f32
        for track,r in tracks.columns[:tracked] {
            if track.kind==.Grow && heights[r]<axis_max(track)-LAYOUT_EPSILON {weights+=grow_weight(track)}
        }
        if weights==0 {break}
        given:f32
        for track,r in tracks.columns[:tracked] {
            if track.kind!=.Grow || heights[r]>=axis_max(track)-LAYOUT_EPSILON {continue}
            before:=heights[r]
            heights[r]=min(axis_max(track),heights[r]+left*grow_weight(track)/weights)
            given+=heights[r]-before
        }
        left-=given
        if given<=LAYOUT_EPSILON*0.01 {break}
    }
    return
}

// The width of each column of a Grid from the width it was given: all the
// same (cell), or what its tracks say. A Fit track is as wide as its widest
// child of one column, and Grow tracks share what is left by their weights.
@(private)
grid_widths :: proc(t:^Layout_Tree,n:^Layout_Node,kids:[]i32,widths:^[GRID_TRACKS]f32) -> (columns:int,cell:f32,tracked:bool) {
    l:=&n.layout
    columns=grid_columns(t,l)
    tracks:=grid_tracks_of(t,l)
    if tracks==nil {return columns,grid_cell(t,n),false}
    inner:=max(n.dim.x-l.padding[0]-l.padding[2]-f32(columns-1)*l.gap,0)
    fits:[GRID_TRACKS]f32
    g:=Grid_Cells{kids=kids,columns=columns}
    for {
        c,more:=grid_cell_next(t,&g)
        if !more {break}
        if c.span==1 {fits[c.column]=max(fits[c.column],t.nodes[c.kid].dim.x)}
    }
    left:=inner
    for track,c in tracks.columns[:columns] {
        switch track.kind {
        case .Fixed:   widths[c]=track.value
        case .Percent: widths[c]=inner*track.value
        case .Fit:     widths[c]=clamp(fits[c],track.min,axis_max(track))
        case .Grow:    widths[c]=track.min
        }
        left-=widths[c]
    }
    for left>LAYOUT_EPSILON {
        weights:f32
        for track,c in tracks.columns[:columns] {
            if track.kind==.Grow && widths[c]<axis_max(track)-LAYOUT_EPSILON {weights+=grow_weight(track)}
        }
        if weights==0 {break}
        given:f32
        for track,c in tracks.columns[:columns] {
            if track.kind!=.Grow || widths[c]>=axis_max(track)-LAYOUT_EPSILON {continue}
            before:=widths[c]
            widths[c]=min(axis_max(track),widths[c]+left*grow_weight(track)/weights)
            given+=widths[c]-before
        }
        left-=given
        if given<=LAYOUT_EPSILON*0.01 {break}
    }
    return columns,0,true
}

// The sizes of the children of a Grid in one axis: across the columns each
// takes the width of the columns it spans; down the rows a growing or
// stretching child takes the height of the rows it spans, which the others
// and the tracks of the rows decide.
@(private)
layout_size_grid :: proc(t:^Layout_Tree,parent:^Layout_Node,x:bool) {
    l:=&parent.layout
    kids:=t.kids[parent.kids_first:][:parent.kids_len]
    if x {
        widths:[GRID_TRACKS]f32
        columns,cell,tracked:=grid_widths(t,parent,kids,&widths)
        g:=Grid_Cells{kids=kids,columns=columns}
        for {
            c,more:=grid_cell_next(t,&g)
            if !more {break}
            child:=&t.nodes[c.kid]
            width:=grid_span_width(widths[:],cell,tracked,c.column,c.span,l.gap)
            sizing:=axis_sizing(child,true)
            switch {
            case sizing.kind==.Percent:                                 child.dim.x=width*sizing.value
            case sizing.kind==.Grow || sizing.kind==.Fit && stretches(child,true): child.dim.x=min(width,axis_max(sizing))
            }
            child.dim.x=max(child.min_dim.x,min(child.dim.x,width))
        }
        return
    }
    // The children the pass keeps in pending are those of a parent it is done with.
    heights:=grid_scratch(t.pending)
    rows:=grid_rows(t,parent,kids,heights,.Given,true)
    g:=Grid_Cells{kids=kids,columns=grid_columns(t,l)}
    for {
        c,more:=grid_cell_next(t,&g)
        if !more {break}
        child:=&t.nodes[c.kid]
        high:=grid_span_height(heights[:rows],c,l.gap)
        sizing:=axis_sizing(child,false)
        switch {
        case sizing.kind==.Percent: child.dim.y=high*sizing.value
        case sizing.kind==.Grow || sizing.kind==.Fit && stretches(child,false): child.dim.y=max(child.min_dim.y,min(high,axis_max(sizing)))
        }
    }
}

// The children of the line of a wrap that starts at start: as many as fit in
// inner, and at least one. used: their widths and the gaps between them.
@(private)
wrap_line :: proc "contextless" (t:^Layout_Tree,kids:[]i32,start:int,inner,gap:f32) -> (end:int,used:f32) {
    for end=start;end<len(kids);end+=1 {
        next:=used+t.nodes[kids[end]].dim.x+(gap if end>start else 0)
        if end>start && next>inner+LAYOUT_EPSILON {break}
        used=next
    }
    return
}

// The sizes of the children of a wrap in one axis: across, a percentage of
// its width, and a growing child takes what its line leaves, by its weight;
// down, a growing or stretching child takes the height of its line.
@(private)
layout_size_wrap :: proc(t:^Layout_Tree,parent:^Layout_Node,x:bool) {
    l:=&parent.layout
    kids:=t.kids[parent.kids_first:][:parent.kids_len]
    inner:=parent.dim.x-l.padding[0]-l.padding[2]
    if x {
        for index in kids {
            child:=&t.nodes[index]
            if sizing:=axis_sizing(child,true);sizing.kind==.Percent {child.dim.x=inner*sizing.value}
        }
    }
    for start:=0;start<len(kids); {
        end,used:=wrap_line(t,kids,start,inner,l.gap)
        line:=kids[start:end]
        start=end
        if x {
            left:=inner-used
            for left>LAYOUT_EPSILON {
                weights:f32
                for index in line {
                    child:=&t.nodes[index]
                    if sizing:=axis_sizing(child,true);sizing.kind==.Grow && child.dim.x<axis_max(sizing)-LAYOUT_EPSILON {weights+=grow_weight(sizing)}
                }
                if weights==0 {break}
                given:f32
                for index in line {
                    child:=&t.nodes[index]
                    sizing:=axis_sizing(child,true)
                    if sizing.kind!=.Grow || child.dim.x>=axis_max(sizing)-LAYOUT_EPSILON {continue}
                    before:=child.dim.x
                    child.dim.x=min(axis_max(sizing),child.dim.x+left*grow_weight(sizing)/weights)
                    given+=child.dim.x-before
                }
                left-=given
                if given<=LAYOUT_EPSILON*0.01 {break}
            }
            for index in line {
                child:=&t.nodes[index]
                child.dim.x=max(child.min_dim.x,min(child.dim.x,inner))
            }
            continue
        }
        high:f32
        for index in line {
            child:=&t.nodes[index]
            sizing:=axis_sizing(child,false)
            if sizing.kind==.Grow || sizing.kind==.Percent || sizing.kind==.Fit && stretches(child,false) {high=max(high,child.min_dim.y)} else {high=max(high,child.dim.y)}
        }
        for index in line {
            child:=&t.nodes[index]
            sizing:=axis_sizing(child,false)
            switch {
            case sizing.kind==.Percent: child.dim.y=high*sizing.value
            case sizing.kind==.Grow || sizing.kind==.Fit && stretches(child,false): child.dim.y=max(child.min_dim.y,min(high,axis_max(sizing)))
            }
        }
    }
}

@(private)
align_offset :: #force_inline proc "contextless" (a:Align,extra:f32) -> f32 {
    switch a {
    case .Start,.Baseline: return 0
    case .Center: return extra*0.5
    case .End:    return extra
    }
    return 0
}

// How far under its top the baseline of the first line of text of an element
// is, as its sizes are now: of a text, that of its first line; of a
// container, that of its first child where it places it, or the lowest of
// the children it puts on one baseline; of anything else, its bottom.
@(private)
layout_ascent :: proc(t:^Layout_Tree,index:i32) -> f32 {
    n:=&t.nodes[index]
    if n.text>=0 {
        text:=&t.texts[n.text]
        if text.lines_len==0 {return n.dim.y}
        return align_offset(text.align_y,max(n.dim.y-text.height,0))+t.lines[text.lines_first].base
    }
    if n.kids_len==0 {return n.dim.y}
    l:=&n.layout
    kids:=t.kids[n.kids_first:][:n.kids_len]
    first:=&t.nodes[kids[0]]
    inner:=n.dim.y-l.padding[1]-l.padding[3]
    switch l.direction {
    case .Row:
        if l.align_y==.Baseline {
            ascent:f32
            for kid in kids {ascent=max(ascent,layout_ascent(t,kid))}
            return l.padding[1]+ascent
        }
        return l.padding[1]+align_offset(self_align(l.align_y,first.layout.self_y),inner-first.dim.y)+layout_ascent(t,kids[0])
    case .Stack:
        return l.padding[1]+align_offset(self_align(l.align_y,first.layout.self_y),inner-first.dim.y)+layout_ascent(t,kids[0])
    case .Column:
        content:=f32(max(n.kids_len-1,0))*l.gap
        for kid in kids {content+=t.nodes[kid].dim.y}
        return l.padding[1]+align_offset(l.align_y,inner-content)+layout_ascent(t,kids[0])
    case .Grid,.Wrap:
    }
    return l.padding[1]+layout_ascent(t,kids[0])
}

@(private)
layout_command :: proc(t:^Layout_Tree,c:Layout_Command) {
    if t.command_count>=len(t.commands) {t.overflow=true;return}
    t.commands[t.command_count]=c
    t.command_count+=1
}
