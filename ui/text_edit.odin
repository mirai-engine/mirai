package ui

import "core:slice"

// ASCII text of a US keyboard: names, typed numbers, filters, color codes and
// the message of a chat. One field is edited at a time; its buffer lives in
// the context, so typing never allocates. No shaping and no IME.

TEXT_EDIT_CAPACITY :: 64<<10
TEXT_EDIT_STEPS :: 100       // edits undo goes back through
TEXT_EDIT_HISTORY :: 64<<10  // bytes of the text they removed and inserted; a larger edit forgets them all

Text_Filter :: enum u8 {
    Any,    // printable ASCII
    Number, // digits, sign, point and exponent
    Hex,    // '#' and hexadecimal digits
}

@(private)
Edit_Drag :: enum u8 {None,Caret,Select}

// What an edit was: a run of typing, of Backspace or of Delete is one step of
// undo, and so is a paste over a selection.
@(private)
Edit_Kind :: enum u8 {Other,Type,Paste,Back,Forward}

// One step of undo: removed bytes at at gave way to inserted ones. Both are
// in Text_Edit.history from first on, the removed first.
@(private)
Edit_Step :: struct {
    at,removed,inserted,first:i32,
    cursor,anchor:i32, // before it
    kind:Edit_Kind,
}

Text_Edit :: struct {
    id:Id,              // the field being edited; 0: none
    buffer:[TEXT_EDIT_CAPACITY]u8,
    length:int,
    changes:u32,        // edits of the text since it began
    capacity:int,       // longest text the field takes
    cursor,anchor:int,  // caret and the other end of the selection (equal: nothing selected)
    scroll:f32,         // units the text is shifted left
    filter:Text_Filter,
    multiline:bool,     // line breaks are part of the text and the lines wrap
    newline:bool,       // Enter adds a line break instead of applying the text
    wrap:f32,           // units the lines wrap at; the field sets it each frame
    scroll_y:f32,       // units the text is shifted up
    goal_x:f32,         // units from the start of the line the caret keeps while moving by lines; negative: measure it
    modified:bool,      // something was typed; untouched fields commit nothing
    frame:u64,          // last frame its field was built
    drag:Edit_Drag,
    caret_started:f64,
    font:u8,            // of the text: what the caret and the lines are measured with; the field sets it each frame
    steps:[TEXT_EDIT_STEPS]Edit_Step,
    history:[TEXT_EDIT_HISTORY]u8,
    done:int,           // steps undo can take back
    step_count:int,     // steps kept: those after done are what redo does again
    joins:bool,         // the last step takes the next edit of its kind that goes on from it
}

text_edit_accepts :: proc "contextless" (filter:Text_Filter,c:u8) -> bool {
    if c<32 || c>126 {return false}
    switch filter {
    case .Any:
    case .Number:return (c>='0'&&c<='9')||c=='.'||c=='-'||c=='+'||c=='e'||c=='E'
    case .Hex:return c=='#'||(c>='0'&&c<='9')||(c>='a'&&c<='f')||(c>='A'&&c<='F')
    }
    return true
}

// A line break belongs to the text only in a multiline field.
@(private)
text_edit_takes :: proc "contextless" (e:^Text_Edit,c:u8) -> bool {
    return e.multiline if c=='\n' else text_edit_accepts(e.filter,c)
}

// Starts editing with the characters of initial the filter accepts.
text_edit_begin :: proc "contextless" (e:^Text_Edit,id:Id,initial:string,filter:Text_Filter=.Any,capacity:int=TEXT_EDIT_CAPACITY,select_all:bool=true,multiline:bool=false) {
    e^={id=id,filter=filter,capacity=clamp(capacity,0,TEXT_EDIT_CAPACITY),multiline=multiline,goal_x=-1}
    for i in 0..<len(initial) {
        if e.length>=e.capacity {break}
        if text_edit_takes(e,initial[i]) {e.buffer[e.length]=initial[i];e.length+=1}
    }
    e.cursor=e.length;e.anchor=e.length
    if select_all {text_edit_select_all(e)}
}
text_edit_value :: proc "contextless" (e:^Text_Edit) -> string {return string(e.buffer[:e.length])}
text_edit_selection :: proc "contextless" (e:^Text_Edit) -> (lo,hi:int) {return min(e.anchor,e.cursor),max(e.anchor,e.cursor)}
text_edit_select_all :: proc "contextless" (e:^Text_Edit) {e.anchor=0;e.cursor=e.length;e.joins=false}
text_edit_move :: proc "contextless" (e:^Text_Edit,index:int,extend:bool) {
    e.cursor=clamp(index,0,e.length)
    if !extend {e.anchor=e.cursor}
    e.joins=false
}
// The class of a character for words: letters, digits and '_' (0), spaces and
// line breaks (1), or the rest (2).
@(private="file")
text_edit_class :: proc "contextless" (c:u8) -> int {
    switch c {
    case 'a'..='z','A'..='Z','0'..='9','_':return 0
    case ' ','\n':return 1
    }
    return 2
}
// The run of characters of one class around index. Numbers and codes are one word.
text_edit_word :: proc "contextless" (e:^Text_Edit,index:int) -> (lo,hi:int) {
    if e.length==0 || e.filter!=.Any {return 0,e.length}
    lo=clamp(index,0,e.length-1);hi=lo+1
    kind:=text_edit_class(e.buffer[lo])
    for lo>0 && text_edit_class(e.buffer[lo-1])==kind {lo-=1}
    for hi<e.length && text_edit_class(e.buffer[hi])==kind {hi+=1}
    return
}
// Where a word away from index is, as Godot moves the caret by words: the
// start of the word before it (step < 0) or the end of the one after it.
@(private)
text_edit_word_step :: proc "contextless" (e:^Text_Edit,index,step:int) -> int {
    i:=clamp(index,0,e.length)
    if step<0 {
        for i>0 && text_edit_class(e.buffer[i-1])==1 {i-=1}
        if i>0 {i,_=text_edit_word(e,i-1)}
    } else {
        for i<e.length && text_edit_class(e.buffer[i])==1 {i+=1}
        if i<e.length {_,i=text_edit_word(e,i)}
    }
    return i
}
// The lines of the text being edited as the text of its field breaks them,
// walked in order by text_edit_lines_next.
@(private)
Edit_Lines :: struct {
    text:string,
    lines:[]Layout_Line,
    pieces:[]Layout_Piece,
    row,at:int,
}
@(private)
text_edit_lines :: proc(ctx:^Context,e:^Text_Edit,size:f32) -> (it:Edit_Lines) {
    it.text=text_edit_value(e)
    if !text_begin(ctx,{font=e.font,size=size,wrap=.Words if e.multiline && e.wrap>0 else .None},measure=true) {return}
    text_span(ctx,it.text)
    ctx.text_open.open=false
    t:=&ctx.layout
    text:=&t.texts[t.text_count]
    lines,pieces:=t.line_count,t.piece_count
    layout_text_wrap(t,&ctx.font,text,e.wrap,true)
    // What was broken stays until the next text is measured.
    it.lines,it.pieces=t.lines[lines:t.line_count],t.pieces[:t.piece_count]
    t.line_count,t.piece_count,t.span_count=lines,pieces,int(text.spans_first)
    return
}
// The byte range of the next line. A line keeps the spaces before its line
// break and none of those it wraps at; a text that ends in a line break has
// one more, empty, line.
@(private)
text_edit_lines_next :: proc "contextless" (it:^Edit_Lines) -> (start,end:int,ok:bool) {
    row:=it.row
    if row>len(it.lines) {return}
    it.row+=1
    if row==len(it.lines) {
        if it.text!="" && it.text[len(it.text)-1]!='\n' {return}
        return len(it.text),len(it.text),true
    }
    line:=&it.lines[row]
    start,end=it.at,it.at
    if line.pieces_len>0 {
        first,last:=&it.pieces[line.pieces_first],&it.pieces[line.pieces_first+line.pieces_len-1]
        start,end=int(first.start),int(last.start+last.length)
        spaces:=end
        for spaces<len(it.text) && it.text[spaces]==' ' {spaces+=1}
        if spaces==len(it.text) || it.text[spaces]=='\n' {end=spaces} else {for end>start && it.text[end-1]==' ' {end-=1}}
    }
    it.at=end+1 if end<len(it.text) && it.text[end]=='\n' else end
    return start,end,true
}
// The line index is on: its row and its byte range, and how many lines the
// text has.
@(private)
text_edit_line_of :: proc(ctx:^Context,e:^Text_Edit,size:f32,index:int) -> (row,start,end,count:int) {
    it:=text_edit_lines(ctx,e,size)
    found:=false
    for {
        line_start,line_end,ok:=text_edit_lines_next(&it)
        if !ok {break}
        count+=1
        if !found {
            row,start,end=count-1,line_start,line_end
            found=index<=line_end
        }
    }
    return
}
// Byte range of line row, or of the last line when the text has fewer.
@(private)
text_edit_line_at :: proc(ctx:^Context,e:^Text_Edit,size:f32,row:int) -> (start,end:int) {
    it:=text_edit_lines(ctx,e,size)
    for {
        line_start,line_end,ok:=text_edit_lines_next(&it)
        if !ok {break}
        start,end=line_start,line_end
        if it.row>row {break}
    }
    return
}
// Moves the caret step lines, keeping the units it had from the start of its
// line. Past the first or the last line it goes to the edge of the text.
@(private)
text_edit_line_move :: proc(ctx:^Context,e:^Text_Edit,size:f32,step:int,extend:bool) {
    row,start,end,count:=text_edit_line_of(ctx,e,size,e.cursor)
    text:=text_edit_value(e)
    if e.goal_x<0 {e.goal_x=text_width(&ctx.font,text[start:clamp(e.cursor,start,end)],size,int(e.font))}
    target:=row+step
    if target<0 || target>=count {
        text_edit_move(e,e.length if step>0 else 0,extend)
        return
    }
    line_start,line_end:=text_edit_line_at(ctx,e,size,target)
    text_edit_move(e,line_start+text_index_at(&ctx.font,text[line_start:line_end],size,e.goal_x,f=int(e.font)),extend)
}

// Puts text in the place of bytes lo..hi, the caret after it. text may be
// what lies after the text in the buffer, where a paste reads it.
@(private)
text_edit_splice :: proc(e:^Text_Edit,lo,hi:int,text:string) {
    copy(e.buffer[lo:],e.buffer[hi:e.length])
    e.length-=hi-lo
    copy(e.buffer[e.length:],text)
    slice.rotate_right(e.buffer[lo:e.length+len(text)],len(text))
    e.length+=len(text)
    e.cursor=lo+len(text);e.anchor=e.cursor
    e.changes+=1
}
// Replaces bytes lo..hi with text as an edit of kind that undo takes back;
// what does not fit in the capacity is dropped.
@(private)
text_edit_replace :: proc(e:^Text_Edit,lo,hi:int,text:string,kind:Edit_Kind) {
    text:=text[:clamp(e.capacity-e.length+hi-lo,0,len(text))]
    if lo==hi && text=="" {return}
    text_edit_record(e,lo,hi,text,kind)
    text_edit_splice(e,lo,hi,text)
}
// Keeps the edit about to replace bytes lo..hi with text: in the last step
// when it goes on from it, as a run of typing does, or in a new one, for which
// the oldest steps make room.
@(private)
text_edit_record :: proc "contextless" (e:^Text_Edit,lo,hi:int,text:string,kind:Edit_Kind) {
    joins:=e.joins && e.done>0 && kind!=.Other
    e.joins=true
    e.step_count=e.done
    used:=0
    if e.done>0 {
        s:=&e.steps[e.done-1]
        used=int(s.first+s.removed+s.inserted)
        if joins && s.kind==kind && used+hi-lo+len(text)<=TEXT_EDIT_HISTORY {
            switch {
            case lo==hi && lo==int(s.at+s.inserted) && (kind==.Type || kind==.Paste):
                copy(e.history[used:],text)
                s.inserted+=i32(len(text))
                return
            case text=="" && s.inserted==0 && kind==.Back && hi==int(s.at):
                copy(e.history[int(s.first)+hi-lo:],e.history[s.first:used])
                copy(e.history[s.first:],e.buffer[lo:hi])
                s.at,s.removed=i32(lo),s.removed+i32(hi-lo)
                return
            case text=="" && s.inserted==0 && kind==.Forward && lo==int(s.at):
                copy(e.history[used:],e.buffer[lo:hi])
                s.removed+=i32(hi-lo)
                return
            }
        }
    }
    size:=hi-lo+len(text)
    if size>TEXT_EDIT_HISTORY {
        e.done,e.step_count,e.joins=0,0,false
        return
    }
    drop:=0
    for drop<e.done && (e.done-drop>=TEXT_EDIT_STEPS || used-int(e.steps[drop].first)+size>TEXT_EDIT_HISTORY) {drop+=1}
    if drop>0 {
        base:=int(e.steps[drop].first) if drop<e.done else used
        copy(e.history[:],e.history[base:used])
        copy(e.steps[:],e.steps[drop:e.done])
        e.done-=drop
        for &s in e.steps[:e.done] {s.first-=i32(base)}
        used-=base
    }
    e.steps[e.done]={at=i32(lo),removed=i32(hi-lo),inserted=i32(len(text)),first=i32(used),cursor=i32(e.cursor),anchor=i32(e.anchor),kind=kind}
    copy(e.history[used:],e.buffer[lo:hi])
    copy(e.history[used+hi-lo:],text)
    e.done+=1
    e.step_count=e.done
}
// Takes back the last edit, with the caret and selection it had before.
text_edit_undo :: proc(e:^Text_Edit) -> bool {
    if e.done==0 {return false}
    e.done-=1
    s:=e.steps[e.done]
    text_edit_splice(e,int(s.at),int(s.at+s.inserted),string(e.history[s.first:][:s.removed]))
    e.cursor,e.anchor,e.joins=int(s.cursor),int(s.anchor),false
    return true
}
// Does again the edit undo took back last.
text_edit_redo :: proc(e:^Text_Edit) -> bool {
    if e.done>=e.step_count {return false}
    s:=e.steps[e.done]
    e.done+=1
    text_edit_splice(e,int(s.at),int(s.at+s.removed),string(e.history[s.first+s.removed:][:s.inserted]))
    e.joins=false
    return true
}

text_edit_delete_selection :: proc(e:^Text_Edit) -> bool {
    lo,hi:=text_edit_selection(e)
    if lo==hi {return false}
    text_edit_replace(e,lo,hi,"",.Other)
    return true
}
// Replaces the selection with c.
text_edit_insert :: proc(e:^Text_Edit,c:u8) {
    if !text_edit_takes(e,c) {return}
    lo,hi:=text_edit_selection(e)
    typed:=[1]u8{c}
    text_edit_replace(e,lo,hi,string(typed[:]),.Type)
}
// Removes the character at, before the caret (Backspace) or after it (Delete).
text_edit_remove :: proc(e:^Text_Edit,at:int) {
    if at<0 || at>=e.length {return}
    text_edit_replace(e,at,at+1,"",.Back if at<e.cursor else .Forward)
}

// Puts the clipboard in the place of the selection as one edit: it is read
// into the room after the text, and what the filter takes turns into place.
@(private)
text_edit_paste :: proc(ctx:^Context,e:^Text_Edit) {
    lo,hi:=text_edit_selection(e)
    text_edit_replace(e,lo,hi,"",.Paste)
    room:=e.buffer[e.length:e.capacity]
    count:=clamp(ctx.clipboard_get(ctx.clipboard_user,room),0,len(room))
    kept:=0
    for c in room[:count] {
        if text_edit_takes(e,c) {room[kept]=c;kept+=1}
    }
    text_edit_replace(e,lo,lo,string(room[:kept]),.Paste)
    e.joins=false
}

// Applies the keys and the text of one frame. Returns true when the text changed.
text_edit_keys :: proc(ctx:^Context,e:^Text_Edit,size:f32) -> bool {
    in_:=&ctx.input
    shift,primary:=.Shift in in_.modifiers,.Primary in in_.modifiers
    before:=e.changes
    by_line:=false
    if primary {
        if .A in in_.keys_pressed {text_edit_select_all(e)}
        if lo,hi:=text_edit_selection(e);hi>lo && ctx.clipboard_set!=nil && (.C in in_.keys_pressed || .X in in_.keys_pressed) {
            ctx.clipboard_set(ctx.clipboard_user,string(e.buffer[lo:hi]))
            if .X in in_.keys_pressed {text_edit_delete_selection(e)}
        }
        if .V in in_.keys_repeated && ctx.clipboard_get!=nil {text_edit_paste(ctx,e)}
        if .Z in in_.keys_repeated {
            if shift {text_edit_redo(e)} else {text_edit_undo(e)}
        }
        if .Y in in_.keys_repeated {text_edit_redo(e)}
    } else {
        for c in in_.text[:in_.text_count] {text_edit_insert(e,c)}
    }
    // With Primary, Backspace, Delete and the arrows go by words.
    if .Backspace in in_.keys_repeated && !text_edit_delete_selection(e) {
        if primary {text_edit_replace(e,text_edit_word_step(e,e.cursor,-1),e.cursor,"",.Other)} else {text_edit_remove(e,e.cursor-1)}
    }
    if .Delete in in_.keys_repeated && !text_edit_delete_selection(e) {
        if primary {text_edit_replace(e,e.cursor,text_edit_word_step(e,e.cursor,1),"",.Other)} else {text_edit_remove(e,e.cursor)}
    }
    // Without Shift an arrow collapses a selection to that edge instead of stepping.
    if .Left in in_.keys_repeated {
        lo,hi:=text_edit_selection(e)
        text_edit_move(e,(text_edit_word_step(e,e.cursor,-1) if primary else e.cursor-1) if shift||lo==hi else lo,shift)
    }
    if .Right in in_.keys_repeated {
        lo,hi:=text_edit_selection(e)
        text_edit_move(e,(text_edit_word_step(e,e.cursor,1) if primary else e.cursor+1) if shift||lo==hi else hi,shift)
    }
    if e.multiline {
        if .Up in in_.keys_repeated {text_edit_line_move(ctx,e,size,-1,shift);by_line=true}
        if .Down in in_.keys_repeated {text_edit_line_move(ctx,e,size,1,shift);by_line=true}
    }
    if .Home in in_.keys_pressed || .End in in_.keys_pressed {
        start,end:=0,e.length
        if e.multiline {_,start,end,_=text_edit_line_of(ctx,e,size,e.cursor)}
        if .Home in in_.keys_pressed {text_edit_move(e,start,shift)}
        if .End in in_.keys_pressed {text_edit_move(e,end,shift)}
    }
    if !by_line {e.goal_x=-1}
    changed:=e.changes!=before
    if changed {e.modified=true}
    return changed
}

// Keeps the caret in sight: sideways in one line, and by lines when the text
// wraps inside height units.
text_edit_reveal :: proc(ctx:^Context,e:^Text_Edit,size,room,height:f32) {
    if e.multiline {
        row,_,_,count:=text_edit_line_of(ctx,e,size,e.cursor)
        line:=size*TEXT_LINE
        scroll_reveal(&e.scroll_y,f32(row)*line,f32(row+1)*line,max(height,line))
        e.scroll_y=clamp(e.scroll_y,0,max(f32(count)*line-height,0))
        e.scroll=0
        return
    }
    text:=text_edit_value(e)
    caret:=text_width(&ctx.font,text[:e.cursor],size,int(e.font))
    e.scroll=clamp(e.scroll,caret-room,caret)
    e.scroll=clamp(e.scroll,0,max(text_width(&ctx.font,text,size,int(e.font))-room,0))
}

// The caret index under a point of the text of the field, which is in a, by
// line when the text wraps.
@(private)
text_edit_index_at :: proc(ctx:^Context,e:^Text_Edit,size:f32,a:Rect,cell:bool=false) -> int {
    x:=ctx.pointer.x-a.x+e.scroll
    if !e.multiline {return text_index_at(&ctx.font,text_edit_value(e),size,x,cell,int(e.font))}
    row:=max(int((ctx.pointer.y-a.y+e.scroll_y)/(size*TEXT_LINE)),0)
    start,end:=text_edit_line_at(ctx,e,size,row)
    return start+text_index_at(&ctx.font,text_edit_value(e)[start:end],size,x,cell,int(e.font))
}

// A press on the field being edited: the first click places the caret (Shift
// extends the selection), the second selects a word, or places the caret too
// without words, and the third everything.
text_edit_press :: proc(ctx:^Context,e:^Text_Edit,size:f32,a:Rect,words:=true) {
    switch {
    case ctx.input.clicks>=3:
        text_edit_select_all(e)
    case ctx.input.clicks==2 && words:
        e.anchor,e.cursor=text_edit_word(e,text_edit_index_at(ctx,e,size,a,true))
    case:
        text_edit_move(e,text_edit_index_at(ctx,e,size,a),.Shift in ctx.input.modifiers)
        e.drag=.Caret
    }
    e.goal_x=-1
    e.joins=false
}
// While the button of that press is held: moving the pointer selects.
text_edit_drag :: proc(ctx:^Context,e:^Text_Edit,size:f32,a:Rect) {
    if e.drag==.None {return}
    if ctx.pointer!=ctx.press {e.drag=.Select}
    if e.drag==.Select {text_edit_move(e,text_edit_index_at(ctx,e,size,a),true)}
}

@(private)
Edit_Event :: enum u8 {None,Changed,Commit,Cancel}

// Starts editing a field, whose element takes the focus.
@(private)
field_edit_begin :: proc(ctx:^Context,id:Id,initial:string,filter:Text_Filter,capacity:int,select_all:bool,multiline:bool=false) {
    text_edit_begin(&ctx.edit,id,initial,filter,capacity,select_all,multiline)
    ctx.edit.frame=ctx.stats.frame
    ctx.edit.caret_started=ctx.time
    ctx.focus=id
    if ctx.edit_request==id {ctx.edit_request=0}
}
// Asks the field with this id to start editing when it is built: this frame
// if it comes later, the next one otherwise.
edit_request :: proc(ctx:^Context,id:Id) {ctx.edit_request=id;ctx.edit_request_frame=ctx.stats.frame}

// One frame of the field being edited: the pointer on it, the keys and the
// caret kept in sight. tab: 1 or -1 when Tab or Shift+Tab ended the edit.
@(private)
field_edit_update :: proc(ctx:^Context,id:Id,it:Interaction,size:f32,words:=true,font:u8=0) -> (event:Edit_Event,tab:int) {
    e:=&ctx.edit
    cursor,anchor:=e.cursor,e.anchor
    e.frame=ctx.stats.frame
    e.font=font
    area,_:=widget_rect(ctx,field_area(ctx,id))
    e.wrap=area.w
    in_:=&ctx.input
    // A click elsewhere applies the text.
    if it.hot || it.active {ctx.cursor=.Text}
    if it.pressed {text_edit_press(ctx,e,size,area,words)} else if .Left in in_.pressed {return .Commit,0}
    if it.active {text_edit_drag(ctx,e,size,area)} else {e.drag=.None}
    // In a multiline field Enter adds a line, and applies the text only when
    // the caller asked for a single line to be sent with it.
    newline:=e.multiline && (e.newline || .Shift in in_.modifiers)
    switch {
    case .Escape in in_.keys_pressed:return .Cancel,0
    case .Enter in in_.keys_pressed && !newline:return .Commit,0
    case .Tab in in_.keys_pressed:return .Commit,-1 if .Shift in in_.modifiers else 1
    }
    if newline && .Enter in in_.keys_repeated {
        text_edit_insert(e,'\n')
        e.modified=true
        event=.Changed
    }
    if text_edit_keys(ctx,e,size) {event=.Changed}
    if it.pressed || event==.Changed || e.cursor!=cursor || e.anchor!=anchor {e.caret_started=ctx.time}
    if area.w>0 {text_edit_reveal(ctx,e,size,area.w,area.h)}
    return
}

// The well of a field: an outline that lightens under the pointer, and the
// accent while it is edited, which keeps the fill.
@(private)
field_paint :: proc(ctx:^Context,id:Id,it:Interaction,held,disabled:bool,strip:Color) -> ^Paint {
    radius:=metric(ctx,"radius_control")
    stroke:=tone(ctx,"well_stroke_hover") if it.hot && !disabled else tone(ctx,"well_stroke")
    if ctx.edit.id==id && id!=0 {stroke=tone(ctx,"accent")}
    return paint_add(ctx,{kind=.Field,fill=tone(ctx,"field_active") if held else tone(ctx,"well"),stroke=stroke,corners={radius,radius,radius,radius},strip=strip})
}

// What a field shows, in a row inside its padding: its icon or the label of
// its axis, its text, with the selection and the caret while it is edited, or
// its placeholder while it is empty, and its unit.
@(private)
Field_Look :: struct {
    text,placeholder,label,unit:string,
    style:Text_Style,      // of its text
    faint,selection:Color, // of the placeholder and of the selected text
    icon:Icon,
    multiline:bool,
}
// The look of a field of the theme.
@(private)
field_look :: proc(ctx:^Context,text:string,size:f32,font:u8,disabled:bool) -> Field_Look {
    return {text=text,style={font=font,size=size,color=tone(ctx,"text_faint") if disabled else tone(ctx,"text")},faint=tone(ctx,"text_faint"),selection=tone(ctx,"text_select")}
}
// The room between the sides of a field and what it shows: that of the
// editor when pad is 0; the unit keeps the right end.
@(private)
field_padding :: proc "contextless" (f:^Field_Look,pad:f32,marked:bool) -> [4]f32 {
    top:=(pad if pad>0 else 5) if f.multiline else 0
    return {pad if pad>0 else 11 if marked else 8,top,5 if f.unit!="" else pad if pad>0 else 8,top}
}
// The element of the text of a field: what the pointer places the caret in.
@(private)
field_area :: proc(ctx:^Context,id:Id) -> Id {return id_derive(ctx,id,"text")}

@(private)
field_content :: proc(ctx:^Context,id:Id,f:Field_Look) {
    e:=&ctx.edit
    editing:=e.id==id && id!=0
    if f.icon!=.None {
        icon(ctx,f.icon,tone(ctx,"text_muted"),FIELD_ICON)
    } else if f.label!="" {text(ctx,f.label,{font=FONT_MEDIUM,size=metric(ctx,"font_axis"),color=tone(ctx,"text"),align_y=.Center},FIT,GROW)}
    area:=field_area(ctx,id)
    style:=f.style
    style.align_y=.Start if f.multiline else .Center
    style.wrap=.Words if f.multiline else .None
    // While it is edited, the text moves inside its clip to keep the caret in sight.
    scroller:=Box{id=area,track=true,width=GROW,height=GROW,align_y=style.align_y,clip_x=!f.multiline,clip_y=f.multiline,scroll={e.scroll,e.scroll_y}}
    if editing {box_begin(ctx,scroller)}
    if text_begin(ctx,style) {
        lo,hi:=text_edit_selection(e)
        lo,hi=clamp(lo,0,len(f.text)),clamp(hi,0,len(f.text))
        caret:=clamp(e.cursor,0,len(f.text))
        if !editing {lo,hi,caret=0,0,len(f.text)}
        text_span(ctx,f.text[:lo if hi>lo else caret])
        if hi>lo {text_span(ctx,f.text[lo:hi],{back=f.selection})}
        if editing && hi<=lo && int(max(ctx.time-e.caret_started,0)*2)%2==0 {text_box(ctx,0,0,{kind=.Caret,fill=style.color})}
        text_span(ctx,f.text[hi if hi>lo else caret:])
        if f.text=="" && f.placeholder!="" {
            if editing && !f.multiline {text_put(ctx,{width=2})}
            text_span(ctx,f.placeholder,{font=style.font,size=style.size,color=f.faint})
        }
        if editing {text_end(ctx,{width=GROW if f.multiline else FIT})} else {text_end(ctx,{width=GROW,height=GROW},area)}
    }
    if editing {box_end(ctx,scroller)}
    if f.unit!="" {text(ctx,f.unit,{size=FIELD_UNIT,color=tone(ctx,"text_faint") if f.style.color==tone(ctx,"text_faint") else tone(ctx,"text_muted"),align_y=.Center},FIT,GROW)}
}

Text_Field :: struct {
    width:Size,          // GROW when unset
    height:f32,          // the row of the theme when 0
    size:f32,            // text size; font_small when 0
    placeholder:string,
    filter:Text_Filter,
    label:string,        // short text inside the field, before its value
    icon:Icon,           // an icon there instead of the label
    strip:Color,         // colored mark on its left edge
    live:bool,           // the buffer follows every key instead of waiting for Enter
    multiline:bool,      // the text keeps its line breaks and wraps
    enter_inserts:bool,  // multiline: Enter adds a line instead of applying the text
    rows:int,            // multiline: lines the field shows when it has no height
    keep_caret:bool,     // focusing places the caret at the end instead of selecting all
    disabled:bool,
    color:Color,
    bare:bool,           // the text alone, without the box of a field
    inline:bool,         // the text on its panel: the outline shows under the pointer, and the field while it is typed
    password:bool,
    font:u8,
    // A field of a game: its fill, stroke, corners and text are those of the
    // style, its selection the mark (or its text at a quarter) and its
    // placeholder its text at half; the first click places the caret.
    style:^Node_Style,
    padding:f32,         // units between its sides and its text; 0: those of the editor
    limit:int,           // bytes it takes; 0: as many as the buffer holds
    adjusts:bool,        // left and right are the caller's while it has the focus and is not typed
}
Text_Result :: struct {
    editing:bool,
    began:bool,     // editing began this frame
    changed:bool,   // the buffer of the caller changed this frame
    committed:bool, // Enter, Tab or a click elsewhere ended the edit
    cancelled:bool, // Escape ended it; the buffer keeps what it had
    tab:int,        // 1 or -1 when Tab or Shift+Tab ended it
}

// A field that edits the text in buffer[:length^].
text_field :: proc(ctx:^Context,id:Id,buffer:[]u8,length:^int,field:Text_Field={}) -> (result:Text_Result) {
    field:=field
    field.disabled|=ctx.disabled_depth>0
    e:=&ctx.edit
    look:=field.style
    if field.disabled && e.id==id && id!=0 {e^={};result.cancelled=true}
    size:=field.size if field.size>0 else metric(ctx,"font_small")
    font:=field.font
    if look!=nil {
        if look.text.size>0 {size=look.text.size}
        font=look.text.font
    }
    capacity:=min(len(buffer),TEXT_EDIT_CAPACITY)
    if field.limit>0 {capacity=min(capacity,field.limit)}
    it:=interact(ctx,id,{.Focusable}+({.Disabled} if field.disabled else {})+({.Adjusts} if field.adjusts else {}))
    if it.hot && !field.disabled {ctx.cursor=.Text}
    if e.id==id && id!=0 {
        e.newline=field.enter_inserts
        event,tab:=field_edit_update(ctx,id,it,size,font=font)
        switch event {
        case .None:
        case .Changed:
            if field.live {length^=copy(buffer,text_edit_value(e));result.changed=true}
        case .Commit:
            value:=text_edit_value(e)
            if e.modified && value!=string(buffer[:length^]) {length^=copy(buffer,value);result.changed=true}
            result.committed=true;result.tab=tab
            e^={}
            if tab!=0 && ctx.navigation {
                if next:=focus_peek(ctx,id,tab);next!=0 {ctx.focus=next;ctx.focus_ring=true;edit_request(ctx,next)}
            }
        case .Cancel:
            result.cancelled=true
            ctx.escape_used=true
            e^={}
        }
    } else if !field.disabled && id!=0 && (it.pressed || ctx.activate==id || ctx.edit_request==id) {
        field_edit_begin(ctx,id,string(buffer[:length^]),field.filter,capacity,!field.keep_caret && look==nil,field.multiline)
        e.font=font
        // The press that starts a field of a game places its caret.
        if look!=nil && it.pressed {
            if area,found:=widget_rect(ctx,field_area(ctx,id));found {text_edit_press(ctx,e,size,area)}
        }
        result.began=true
    }
    result.editing=e.id==id && id!=0
    f:=field_look(ctx,text_edit_value(e) if result.editing else string(buffer[:length^]),size,font,field.disabled)
    f.placeholder,f.label,f.icon,f.multiline=field.placeholder,field.label,field.icon,field.multiline
    if field.password {
        masked:=text_reserve(ctx,len(f.text))
        for &c in masked {c='*'}
        f.text=text_commit(ctx,string(masked))
    }
    if !field.disabled && field.color[3]>0 {f.style.color=field.color}
    paint:=field_paint(ctx,id,it,false,field.disabled,field.strip)
    if paint!=nil {
        if field.bare {paint.fill={};paint.stroke={}}
        if field.inline && !result.editing {paint.fill={};paint.stroke=tone(ctx,"border") if it.hot && !field.disabled else {}}
        if look!=nil {field_paint_look(paint,&f,look)}
    }
    height:=field.height
    if height<=0 {
        line:=size*TEXT_LINE
        if look!=nil {
            height=f32(max(field.rows,1))*line+2*field.padding if field.multiline else line+2*field.padding
        } else {height=f32(max(field.rows,1))*line+10 if field.multiline else metric(ctx,"row")}
    }
    if element_open(ctx,{id=id,layout={width=(field.width if field.width!={} else GROW),height=fixed(height),padding=field_padding(&f,field.padding,field.strip[3]>0),gap=4 if field.icon!=.None else 6,align_y=.Center},custom=paint}) {field_content(ctx,id,f)}
    element_close(ctx)
    return
}

// The focusable widget that follows (step 1) or precedes (step -1) id.
@(private)
focus_peek :: proc(ctx:^Context,id:Id,step:int) -> Id {
    count:=ctx.previous_count
    start,found:=id_table_find(&ctx.previous_ids,id)
    if !found {return 0}
    index:=int(start)
    for _ in 0..<count-1 {
        index=(index+step+count)%count
        w:=&ctx.previous[index]
        if .Focusable in w.flags && .Disabled not_in w.flags && w.layer>=ctx.navigation_layer {return w.id}
    }
    return 0
}
