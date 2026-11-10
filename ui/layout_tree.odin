package ui

import "core:hash"
import "core:math"
import "core:mem"

// The layout of a frame. The widgets open and close its elements, and the size
// an element asks for follows from its children as they close. layout_finish
// hands the space of every container out among its children, one axis at a
// time, breaks the paragraphs into lines, places every element and lists what
// is drawn in the order it is drawn.
//
// A modified version, written in Odin, of the layout of Clay v0.14 (zlib,
// Copyright (c) 2024 Nic Barker; THIRD_PARTY_NOTICES.md).

// Containers open inside one another. A deeper one is refused with what it
// holds and counted in Stats.dropped_elements.
LAYOUT_DEPTH :: 64

@(private)
LAYOUT_EPSILON :: 0.01
// The line box of a paragraph in em, that of the messages of the chat,
// rounded down to a whole unit. Each line of text is centered
// in its box.
@(private)
PARAGRAPH_LINE :: f32(1.6)

// The line box of a paragraph of text of size whose lines are line sizes
// apart, PARAGRAPH_LINE when 0, in whole units.
@(private)
paragraph_line :: proc "contextless" (size,line:f32) -> f32 {return math.floor(size*(line if line>0 else PARAGRAPH_LINE))}

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
    run:i32,            // its row in runs when it is a run of text; -1 otherwise
    clip_x,clip_y,floating:bool,
    clip_floats:bool,   // the roots that float inside it are cut by it
    clip_outer:i32,     // of one that does: the one it is inside that does too; 0: none
    border:u16,
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
@(private)
Layout_Run :: struct {
    text:string,
    size,line_height:f32,
    face:u8,
    measure:Layout_Measure,
    node:i32,
    lines_first,lines_len:i32,
}
@(private)
Layout_Word :: struct {start,length:i32,width:f32}
// y: from the top of the run.
@(private)
Layout_Line :: struct {start,length:i32,width,y:f32}
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
}
@(private)
Layout_Command_Kind :: enum u8 {Custom,Border,Text,Scissor_Start,Scissor_End}
// line: its row in lines, for a line of text.
@(private)
Layout_Command :: struct {kind:Layout_Command_Kind,node,line:i32}

@(private)
Layout_Tree :: struct {
    nodes:[]Layout_Node,node_count:int,
    runs:[]Layout_Run,run_count:int,
    kids:[]i32,kids_len:int,       // the children of each container, one after the other
    pending:[]i32,pending_len:int, // closed and not yet handed to their parent; the work list of a pass
    scratch:[]i32,                 // the containers a pass still has to go through
    roots:[]Layout_Root,root_count:int,
    open:[LAYOUT_DEPTH+1]i32,open_len:int,
    lines:[]Layout_Line,line_count:int,
    commands:[]Layout_Command,command_count:int,
    // Where an element is by its id. A slot of an earlier generation is free,
    // so a frame costs nothing to start.
    ids:[]Id,places:[]i32,generations:[]u32,id_mask,generation:u32,
    duplicates:int,
    // The runs of this frame are measured in the first and what earlier
    // frames measured is found in the second: they change places between frames.
    measures:[2]Layout_Measures,
    measured,reused:int, // runs measured anew and found measured, until frame_end reads them
    overflow:bool, // a line or a command did not fit this frame
    tracks:[]Grid_Tracks,track_count:int, // the widths of the columns of the grids of the frame (grid_tracks_add)
    aspects:bool,  // an element of the frame keeps an aspect
    allocator:mem.Allocator,
}

@(private)
layout_init :: proc(t:^Layout_Tree,allocator:mem.Allocator,max_elements,max_words,max_chars,max_tracks:int) -> bool {
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
    t.runs=alloc(Layout_Run,nodes,a,&ok)
    t.kids=alloc(i32,nodes,a,&ok)
    t.pending=alloc(i32,nodes,a,&ok)
    t.scratch=alloc(i32,nodes,a,&ok)
    t.roots=alloc(Layout_Root,nodes,a,&ok)
    t.lines=alloc(Layout_Line,max_elements*4,a,&ok)
    t.commands=alloc(Layout_Command,max_elements*4,a,&ok)
    t.tracks=alloc(Grid_Tracks,max_tracks,a,&ok)
    slots:=16
    for slots<max_elements*2 {slots<<=1}
    t.ids=alloc(Id,slots,a,&ok)
    t.places=alloc(i32,slots,a,&ok)
    t.generations=alloc(u32,slots,a,&ok)
    t.id_mask=u32(slots-1)
    // A frame has fewer runs than elements.
    slots=16
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
    mem.zero_slice(t.generations)
    for &g in t.measures {
        mem.zero_slice(g.generations)
        g.generation=1
    }
    return true
}

@(private)
layout_destroy :: proc(t:^Layout_Tree) {
    a:=t.allocator
    delete(t.nodes,a);delete(t.runs,a);delete(t.kids,a);delete(t.pending,a);delete(t.scratch,a)
    delete(t.roots,a);delete(t.lines,a);delete(t.commands,a);delete(t.tracks,a)
    delete(t.ids,a);delete(t.places,a);delete(t.generations,a)
    for g in t.measures {
        delete(g.keys,a);delete(g.entries,a);delete(g.generations,a);delete(g.words,a);delete(g.chars,a)
    }
    t^={}
}

// Starts the tree of a frame on a surface of this size. Node zero is the
// surface: every element at the top level is inside it.
@(private)
layout_begin :: proc(t:^Layout_Tree,size:[2]f32) {
    t.run_count=0;t.kids_len=0;t.pending_len=0;t.line_count=0;t.command_count=0
    t.duplicates=0;t.overflow=false;t.aspects=false
    t.generation+=1
    if t.generation==0 {mem.zero_slice(t.generations);t.generation=1}
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
    t.nodes[0]={layout={width=fixed(size.x),height=fixed(size.y)},dim=size,min_dim=size,box={0,0,size.x,size.y},run=-1}
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
    n.run=-1
    n.clip_x,n.clip_y=e.clip.x,e.clip.y
    n.clip_floats=e.clip.floats
    n.floating=f.to!=.None
    n.border=e.border
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
            contain=f.contain,within=layout_index(t,f.within) if f.contain else 0}
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
    layout_fit(t,n)
    // A floating element takes nothing from the flow of its parent.
    if !n.floating {layout_attach(t,index)}
}

// A run of text, measured once for what it says and broken into lines by the
// layout. False when the tree has no room for it.
@(private)
layout_text :: proc(t:^Layout_Tree,font:^Font,text:string,size,line:f32,face:u8,paint:rawptr) -> bool {
    if t.node_count>=len(t.nodes) {return false}
    m:=layout_measure(t,font,text,size,face)
    index:=i32(t.node_count)
    run:=i32(t.run_count)
    t.runs[run]={text=text,size=size,face=face,line_height=line,measure=m,node=index}
    t.run_count+=1
    n:=&t.nodes[index]
    n.layout={}
    n.scroll={}
    n.box={}
    n.custom=paint
    n.user_data=nil
    n.id=0
    n.kids_len=0
    n.run=run
    n.clip_x,n.clip_y,n.floating,n.clip_floats,n.clip_outer=false,false,false,false,0
    n.border=0
    n.dim={m.width,line}
    n.min_dim={m.min_width,line}
    t.node_count+=1
    layout_attach(t,index)
    return true
}

@(private)
layout_attach :: proc(t:^Layout_Tree,index:i32) {
    t.nodes[t.open[t.open_len-1]].kids_len+=1
    t.pending[t.pending_len]=index
    t.pending_len+=1
}

// ---------------------------------------------------------------- by id

@(private)
layout_slot :: #force_inline proc "contextless" (t:^Layout_Tree,id:Id) -> u32 {
    // Ids are hashes already: one multiplication spreads them over the slots.
    return (u32(id)*2654435761)>>8 & t.id_mask
}
@(private)
layout_id_put :: proc(t:^Layout_Tree,id:Id,index:i32) {
    if id==0 {return}
    slot:=layout_slot(t,id)
    for t.generations[slot]==t.generation {
        if t.ids[slot]==id {t.duplicates+=1;return}
        slot=(slot+1)&t.id_mask
    }
    t.generations[slot]=t.generation
    t.ids[slot]=id
    t.places[slot]=index
}
// The node of an id in this frame; the surface when no element has it.
@(private)
layout_index :: proc(t:^Layout_Tree,id:Id) -> i32 {
    if id==0 {return 0}
    slot:=layout_slot(t,id)
    for t.generations[slot]==t.generation {
        if t.ids[slot]==id {return t.places[slot]}
        slot=(slot+1)&t.id_mask
    }
    return 0
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
    seed:=u64(0xcbf29ce484222325)~u64(transmute(u32)size)~u64(face)<<32
    key:=hash.fnv64a(transmute([]byte)text,seed)
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
    line:f32
    walk:=Layout_Walk{font=font,text=text,size=size,face=face,space=m.space}
    for {
        w,bare,more:=layout_walk(&walk)
        if !more {break}
        if w.length==0 {
            m.width=max(m.width,line)
            line=0
            m.breaks=true
        } else {
            line+=w.width
            m.min_width=max(m.min_width,bare)
        }
        if kept && g.word_count<len(g.words) {
            g.words[g.word_count]=w
            g.word_count+=1
        } else {kept=false}
    }
    m.width=max(m.width,line)
    m.words_len=i32(g.word_count)-m.words_first
    if !kept {
        g.word_count=int(m.words_first)
        m.words_first,m.words_len=-1,0
    }
    return
}

// The words of a run, in order, as they are measured: each with the space that
// ends it, and a line break as a word of no length after the word before it.
@(private)
Layout_Walk :: struct {
    font:^Font,text:string,size:f32,face:int,space:f32,
    at:int,
    broke:bool, // a word before a line break was given: the break comes next
}
@(private)
layout_walk :: proc "contextless" (w:^Layout_Walk) -> (word:Layout_Word,bare:f32,ok:bool) {
    if w.broke {
        w.broke=false
        return {i32(w.at),0,0},0,true
    }
    start:=w.at
    for i in start..<len(w.text) {
        c:=w.text[i]
        if c!=' ' && c!='\n' {continue}
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

// The lines the words of a run take in a width, one per call of
// layout_break_next: a word that does not fit starts the next line, a word
// wider than the line takes one of its own, and a line gives up the space it
// breaks at. The words are those the measure of the run kept, or the run
// walked again. Every text that wraps at words breaks here.
@(private)
Layout_Break :: struct {
    text:string,
    walk:Layout_Walk,
    words:[]Layout_Word,
    walked:bool,      // the words come from walk instead
    index:int,
    width,space:f32,
    word:Layout_Word, // the one after the lines given so far
    more:bool,
    start:i32,        // where the line after them starts
}
@(private)
layout_break :: proc "contextless" (font:^Font,text:string,size:f32,face:int,space,width:f32) -> (b:Layout_Break) {
    b={text=text,walk={font=font,text=text,size=size,face=face,space=space},walked=true,width=width,space=space}
    layout_break_word(&b)
    return
}
@(private)
layout_break_word :: #force_inline proc "contextless" (b:^Layout_Break) {
    if b.walked {b.word,_,b.more=layout_walk(&b.walk);return}
    b.more=b.index<len(b.words)
    if b.more {b.word=b.words[b.index];b.index+=1}
}
@(private)
layout_break_next :: proc "contextless" (b:^Layout_Break) -> (start,length:i32,width:f32,ok:bool) {
    chars:i32
    for b.more {
        w:=b.word
        if chars==0 && w.width>b.width {
            b.start=w.start+w.length
            layout_break_word(b)
            return w.start,w.length,w.width,true
        }
        if w.length==0 || width+w.width>b.width {
            spaced:=chars>0 && b.text[b.start+chars-1]==' '
            start,length=b.start,chars-(1 if spaced else 0)
            if spaced {width-=b.space}
            b.start=w.start
            if w.length==0 {layout_break_word(b)}
            return start,length,width,true
        }
        width+=w.width
        chars+=w.length
        layout_break_word(b)
    }
    return b.start,chars,width,chars>0
}

// Breaks a measured run into the lines it takes in width. With a run the lines
// are kept for it; either way it returns how many there are.
@(private)
layout_wrap :: proc(t:^Layout_Tree,font:^Font,text:string,m:Layout_Measure,size:f32,face:u8,width:f32,run:^Layout_Run) -> int {
    count:=0
    y:=f32(0)
    add :: proc(t:^Layout_Tree,run:^Layout_Run,count:^int,y:^f32,start,length:i32,width:f32) {
        count^+=1
        if run==nil {return}
        if t.line_count<len(t.lines) {
            t.lines[t.line_count]={start,length,width,y^}
            t.line_count+=1
            run.lines_len+=1
        } else {t.overflow=true}
        y^+=run.line_height
    }
    if !m.breaks && m.width<=width {
        add(t,run,&count,&y,0,i32(len(text)),m.width)
        return count
    }
    b:=Layout_Break{text=text,walk={font=font,text=text,size=size,face=int(face),space=m.space},walked=m.words_first<0,width=width,space=m.space}
    if !b.walked {b.words=t.measures[0].words[m.words_first:][:m.words_len]}
    layout_break_word(&b)
    for {
        start,length,line_width,ok:=layout_break_next(&b)
        if !ok {break}
        add(t,run,&count,&y,start,length,line_width)
    }
    return count
}

FLOW_PIECES :: 64 // pieces of one line of runs; a line that holds more goes on in the next

// A piece of a line of runs: the words of one run that are on it, or a box.
@(private)
Flow_Piece :: struct($Run:typeid) {
    text:string,
    x,width:f32, // in its line; width: with the spaces its text ends in
    gap:f32,     // room after it that is no part of it
    pad:f32,     // of its width, what is no text: a chip. Its text is not words
    size:f32,
    font:u8,
    box:bool,    // it does not break: a pill, an image
    run:Run,     // what its owner draws it with
}
// A line being filled with the words of runs of different styles, as rich text
// and Markdown lay theirs out. Words come from layout_walk and break as the
// layout breaks a paragraph; pieces that no space parts stay on one line. When
// flow_put refuses a piece the line is full: its owner builds what flow_line
// gives, calls flow_next and puts the piece again.
@(private)
Flow :: struct($Run:typeid) {
    pieces:[FLOW_PIECES]Flow_Piece(Run),
    count:int,
    used,width:f32,
    cut:bool,     // a word wider than the line goes on in the next one instead of past its end
    glued:bool,   // no space follows the piece put last
    unit:int,     // where the pieces no space parts start: the piece,
    unit_at:int,  // the byte of its text
    unit_x:f32,   // and the place in the line
    ready:int,    // pieces of the line that is full
}

@(private)
flow_joins :: proc "contextless" (f:^Flow($Run),p:^Flow_Piece(Run)) -> bool {
    if f.count==0 || p.box || p.pad>0 {return false}
    last:=&f.pieces[f.count-1]
    return !last.box && last.pad==0 && last.gap==0 && last.run==p.run && last.size==p.size && last.font==p.font &&
        uintptr(raw_data(last.text))+uintptr(len(last.text))==uintptr(raw_data(p.text))
}
// Adds a piece where the line ends, whether it fits or not.
@(private)
flow_add :: proc "contextless" (f:^Flow($Run),p:Flow_Piece(Run)) {
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
flow_put :: proc "contextless" (f:^Flow($Run),font:^Font,p:^Flow_Piece(Run)) -> bool {
    joins:=flow_joins(f,p)
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
        if f.cut && !p.box && bare>0 {
            n,width:=text_prefix(font,p.text,p.size,room-p.pad,int(p.font))
            if n<bare {
                if n==0 && f.count==0 {
                    n=1
                    for n<len(p.text) && p.text[n]&0xc0==0x80 {n+=1}
                    width=text_width(font,p.text[:n],p.size,int(p.font))
                }
                if n>0 {
                    head:=p^
                    head.text,head.width,head.gap=p.text[:n],width+p.pad,0
                    flow_add(f,head)
                    p.text=p.text[n:]
                    p.width=text_width(font,p.text,p.size,int(p.font))+p.pad
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
    f.glued=p.box || p.pad>0 || p.text=="" || p.text[len(p.text)-1]!=' '
    return true
}
// Room as wide as a space after what the line holds: a word ends there.
@(private)
flow_space :: proc "contextless" (f:^Flow($Run),width:f32) {
    f.glued=false
    if f.count==0 {return}
    f.pieces[f.count-1].gap+=width
    f.used+=width
}
// The pieces of the line that is full, or of all that was put when its owner
// ends it; it gives up the space it ends at.
@(private)
flow_line :: proc "contextless" (f:^Flow($Run),font:^Font) -> []Flow_Piece(Run) {
    if f.ready==0 {f.ready,f.glued=f.count,false}
    n:=f.ready
    if n>0 {
        last:=&f.pieces[n-1]
        if !last.box && last.pad==0 && len(last.text)>0 && last.text[len(last.text)-1]==' ' {
            last.text=last.text[:len(last.text)-1]
            last.width-=text_width(font," ",last.size,int(last.font))
            if last.text=="" {n-=1}
        }
    }
    return f.pieces[:n]
}
// Starts the next line with what the full one left for it.
@(private)
flow_next :: proc "contextless" (f:^Flow($Run)) {
    left:=f.count-f.ready
    start:=f.pieces[f.ready].x if left>0 else f.used
    copy(f.pieces[:left],f.pieces[f.ready:f.count])
    for &p in f.pieces[:left] {p.x-=start}
    f.count,f.used,f.ready=left,f.used-start,0
    f.unit,f.unit_at,f.unit_x=0,0,0
}

// A line of text as it is drawn: what it says and where.
@(private)
layout_line :: proc(t:^Layout_Tree,c:Layout_Command) -> (text:string,rect:Rect,run:^Layout_Run) {
    n:=&t.nodes[c.node]
    run=&t.runs[n.run]
    line:=t.lines[c.line]
    return run.text[line.start:][:line.length],{n.box.x,n.box.y+line.y,line.width,run.line_height},run
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
    count:=int(n.kids_len)
    first:=t.pending_len-count
    t.pending_len=first
    n.kids_first=i32(t.kids_len)
    kids:=t.kids[t.kids_len:][:count]
    copy(kids,t.pending[first:][:count])
    t.kids_len+=count
    gap:=f32(max(count-1,0))*l.gap
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
    if l.width.kind!=.Percent {
        n.dim.x=clamp(n.dim.x,axis_min(l.width),axis_max(l.width))
        n.min_dim.x=clamp(n.min_dim.x,axis_min(l.width),axis_max(l.width))
    } else {n.dim.x=0}
    if l.height.kind!=.Percent {
        n.dim.y=clamp(n.dim.y,axis_min(l.height),axis_max(l.height))
        n.min_dim.y=clamp(n.min_dim.y,axis_min(l.height),axis_max(l.height))
    } else {n.dim.y=0}
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
    rows:=0
    for start:=0;start<len(kids);rows+=1 {
        end,high:=grid_line(t,kids,columns,start)
        low:f32
        column:=0
        for index in kids[start:end] {
            child:=&t.nodes[index]
            span:=grid_span(child,columns)
            if tracks==nil {
                spanned:=f32(span-1)*l.gap
                cell=max(cell,(child.dim.x-spanned)/f32(span))
                least=max(least,(child.min_dim.x-spanned)/f32(span))
            } else if span==1 {
                fits[column]=max(fits[column],child.dim.x)
                leasts[column]=max(leasts[column],child.min_dim.x)
            }
            low=max(low,child.min_dim.y)
            column+=span
        }
        n.dim.y+=high
        if !n.clip_y {n.min_dim.y+=low}
        start=end
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
        // A growing floating element takes the size of what it hangs from.
        if r.floating {
            p:=&t.nodes[root.parent]
            if r.layout.width.kind==.Grow {r.dim.x=p.dim.x}
            if r.layout.height.kind==.Grow {r.dim.y=p.dim.y}
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
                if child:=&t.nodes[index];child.run<0 && child.kids_len>0 {
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
    if n.run>=0 || n.kids_len==0 {return}
    kids:=t.kids[n.kids_first:][:n.kids_len]
    for kid in kids {layout_heights(t,kid)}
    l:=&n.layout
    if l.aspect>0 {return}
    switch l.direction {
    case .Grid:
        content:=l.padding[1]+l.padding[3]
        columns:=grid_columns(t,l)
        rows:=0
        for start:=0;start<len(kids);rows+=1 {
            end,high:=grid_line(t,kids,columns,start)
            content+=high
            start=end
        }
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
    case .Column:
        content:=l.padding[1]+l.padding[3]
        for kid in kids {content+=t.nodes[kid].dim.y}
        content+=f32(max(n.kids_len-1,0))*l.gap
        n.dim.y=clamp(content,axis_min(l.height),axis_max(l.height))
    }
}

// ---------------------------------------------------------------- placement

@(private)
layout_finish :: proc(t:^Layout_Tree,font:^Font) {
    // The surface closes like any container, which puts the elements of the
    // top level inside it.
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
    for &run in t.runs[:t.run_count] {
        n:=&t.nodes[run.node]
        run.lines_first=i32(t.line_count)
        run.lines_len=0
        n.dim.y=run.line_height*f32(max(layout_wrap(t,font,run.text,run.measure,run.size,run.face,n.dim.x,&run),1))
    }
    for root in t.roots[:t.root_count] {layout_heights(t,root.node)}
    layout_size(t,false)
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
        position:[2]f32
        if r.floating {
            p:=t.nodes[root.parent].box
            position=float_position(p,root.anchor,root.pivot,root.offset,r.dim)
            if root.contain {position=float_contain(p,&root,r.dim,t.nodes[root.within].box,position)}
        }
        layout_place(t,root.node,position)
    }
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
// in as far as it has to.
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
        if anchor[axis]!=1 || pivot[axis]!=1 {
            other:=origin[axis]+size[axis]*f32(2-anchor[axis])*0.5-dim[axis]*f32(2-pivot[axis])*0.5-root.offset[axis]
            if out(other,dim[axis],low[axis],high[axis])<out(position[axis],dim[axis],low[axis],high[axis]) {position[axis]=other}
        }
        position[axis]=clamp(position[axis],low[axis],max(high[axis]-dim[axis],low[axis]))
    }
    return position
}

@(private)
layout_place :: proc(t:^Layout_Tree,index:i32,position:[2]f32) {
    n:=&t.nodes[index]
    n.box={position.x,position.y,n.dim.x,n.dim.y}
    if n.run>=0 {
        run:=&t.runs[n.run]
        for line in run.lines_first..<run.lines_first+run.lines_len {
            if t.lines[line].length>0 {layout_command(t,{.Text,index,line})}
        }
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
            y:=position.y+l.padding[1]
            for start:=0;start<len(kids); {
                end,high:=grid_line(t,kids,columns,start)
                column:=0
                x:=position.x+l.padding[0]
                for kid in kids[start:end] {
                    child:=&t.nodes[kid]
                    span:=grid_span(child,columns)
                    width:=grid_span_width(widths[:],cell,tracked,column,span,l.gap)
                    if !tracked {x=position.x+l.padding[0]+f32(column)*(cell+l.gap)}
                    at:=[2]f32{x+align_offset(self_align(l.align_x,child.layout.self_x),width-child.dim.x),y+align_offset(self_align(l.align_y,child.layout.self_y),high-child.dim.y)}
                    layout_place(t,kid,at+offset)
                    x+=width+l.gap
                    column+=span
                }
                y+=high+l.gap
                start=end
            }
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
                    layout_place(t,kid,[2]f32{x,y+align_offset(self_align(l.align_y,child.layout.self_y),high-child.dim.y)}+offset)
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
                layout_place(t,kid,at+offset)
            }
        case .Row,.Column:
            row:=l.direction==.Row
            next:=position
            content:f32
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
                if row {
                    at.y=position.y+l.padding[1]+align_offset(self_align(l.align_y,child.layout.self_y),n.dim.y-top_bottom-child.dim.y)+offset.y
                } else {
                    at.x=position.x+l.padding[0]+align_offset(self_align(l.align_x,child.layout.self_x),n.dim.x-left_right-child.dim.x)+offset.x
                }
                layout_place(t,kid,at)
                if row {next.x+=child.dim.x+l.gap} else {next.y+=child.dim.y+l.gap}
            }
        }
    }
    if n.border>0 {layout_command(t,{.Border,index,0})}
    if clips {layout_command(t,{.Scissor_End,index,0})}
}

// ---------------------------------------------------------------- grids and wraps

// The tracks of a Grid, when it names a row of those of the frame that has columns.
@(private)
grid_tracks_of :: #force_inline proc "contextless" (t:^Layout_Tree,l:^Layout) -> ^Grid_Tracks {
    if l.tracks==0 || int(l.tracks)>t.track_count || t.tracks[l.tracks-1].count==0 {return nil}
    return &t.tracks[l.tracks-1]
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

// The children of the row of a Grid that starts at start, as they flow into
// its columns, and the height of the highest of them.
@(private)
grid_line :: proc "contextless" (t:^Layout_Tree,kids:[]i32,columns,start:int) -> (end:int,high:f32) {
    used:=0
    for end=start;end<len(kids);end+=1 {
        child:=&t.nodes[kids[end]]
        span:=grid_span(child,columns)
        if used>0 && used+span>columns {break}
        used+=span
        high=max(high,child.dim.y)
    }
    return
}

// The width of span columns from column, with the gaps between them.
@(private)
grid_span_width :: proc "contextless" (widths:[]f32,cell:f32,tracked:bool,column,span:int,gap:f32) -> f32 {
    if !tracked {return cell*f32(span)+f32(span-1)*gap}
    width:=f32(span-1)*gap
    for w in widths[column:][:span] {width+=w}
    return width
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
    for start:=0;start<len(kids); {
        end,_:=grid_line(t,kids,columns,start)
        column:=0
        for kid in kids[start:end] {
            child:=&t.nodes[kid]
            span:=grid_span(child,columns)
            if span==1 {fits[column]=max(fits[column],child.dim.x)}
            column+=span
        }
        start=end
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
// stretching child takes the height of its row, which the others decide.
@(private)
layout_size_grid :: proc(t:^Layout_Tree,parent:^Layout_Node,x:bool) {
    l:=&parent.layout
    kids:=t.kids[parent.kids_first:][:parent.kids_len]
    if x {
        widths:[GRID_TRACKS]f32
        columns,cell,tracked:=grid_widths(t,parent,kids,&widths)
        for start:=0;start<len(kids); {
            end,_:=grid_line(t,kids,columns,start)
            column:=0
            for index in kids[start:end] {
                child:=&t.nodes[index]
                span:=grid_span(child,columns)
                width:=grid_span_width(widths[:],cell,tracked,column,span,l.gap)
                column+=span
                sizing:=axis_sizing(child,true)
                switch {
                case sizing.kind==.Percent:                                 child.dim.x=width*sizing.value
                case sizing.kind==.Grow || sizing.kind==.Fit && stretches(child,true): child.dim.x=min(width,axis_max(sizing))
                }
                child.dim.x=max(child.min_dim.x,min(child.dim.x,width))
            }
            start=end
        }
        return
    }
    columns:=grid_columns(t,l)
    for start:=0;start<len(kids); {
        end,_:=grid_line(t,kids,columns,start)
        cells:=kids[start:end]
        high:f32
        for index in cells {
            child:=&t.nodes[index]
            sizing:=axis_sizing(child,false)
            if sizing.kind==.Grow || sizing.kind==.Percent || sizing.kind==.Fit && stretches(child,false) {high=max(high,child.min_dim.y)} else {high=max(high,child.dim.y)}
        }
        for index in cells {
            child:=&t.nodes[index]
            sizing:=axis_sizing(child,false)
            switch {
            case sizing.kind==.Percent: child.dim.y=high*sizing.value
            case sizing.kind==.Grow || sizing.kind==.Fit && stretches(child,false): child.dim.y=max(child.min_dim.y,min(high,axis_max(sizing)))
            }
        }
        start=end
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
    case .Start:  return 0
    case .Center: return extra*0.5
    case .End:    return extra
    }
    return 0
}

@(private)
layout_command :: proc(t:^Layout_Tree,c:Layout_Command) {
    if t.command_count>=len(t.commands) {t.overflow=true;return}
    t.commands[t.command_count]=c
    t.command_count+=1
}
