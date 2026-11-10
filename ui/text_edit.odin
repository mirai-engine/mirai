package ui

import "core:slice"

// ASCII text of a US keyboard: names, typed numbers, filters, color codes and
// the message of a chat. One field is edited at a time; its buffer lives in
// the context, so typing never allocates. No shaping and no IME.

TEXT_EDIT_CAPACITY :: 64<<10

Text_Filter :: enum u8 {
    Any,    // printable ASCII
    Number, // digits, sign, point and exponent
    Hex,    // '#' and hexadecimal digits
}

@(private)
Edit_Drag :: enum u8 {None,Caret,Select}

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
text_edit_select_all :: proc "contextless" (e:^Text_Edit) {e.anchor=0;e.cursor=e.length}
text_edit_move :: proc "contextless" (e:^Text_Edit,index:int,extend:bool) {
    e.cursor=clamp(index,0,e.length)
    if !extend {e.anchor=e.cursor}
}
// The run of characters of one class around index: letters, digits and '_',
// spaces, or the rest. Numbers and codes are one word.
text_edit_word :: proc "contextless" (e:^Text_Edit,index:int) -> (lo,hi:int) {
    if e.length==0 || e.filter!=.Any {return 0,e.length}
    class :: proc "contextless" (c:u8) -> int {
        switch c {
        case 'a'..='z','A'..='Z','0'..='9','_':return 0
        case ' ':return 1
        }
        return 2
    }
    lo=clamp(index,0,e.length-1);hi=lo+1
    kind:=class(e.buffer[lo])
    for lo>0 && class(e.buffer[lo-1])==kind {lo-=1}
    for hi<e.length && class(e.buffer[hi])==kind {hi+=1}
    return
}
// The lines of the text being edited.
@(private)
text_edit_lines :: proc "contextless" (ctx:^Context,e:^Text_Edit,size:f32) -> Text_Lines {
    wrap:Text_Wrap=.Words if e.multiline && e.wrap>0 else .None
    return text_lines(&ctx.font,text_edit_value(e),size,e.wrap,wrap,int(e.font))
}
// The line index is on: its row and its byte range, and how many lines the
// text has.
@(private)
text_edit_line_of :: proc "contextless" (ctx:^Context,e:^Text_Edit,size:f32,index:int) -> (row,start,end,count:int) {
    it:=text_edit_lines(ctx,e,size)
    found:=false
    for {
        line_start,line_end,ok:=text_lines_next(&it)
        if !ok {break}
        count=it.row+1
        if !found {
            row,start,end=it.row,line_start,line_end
            found=index<=line_end
        }
    }
    return
}
// Byte range of line row, or of the last line when the text has fewer.
@(private)
text_edit_line_at :: proc "contextless" (ctx:^Context,e:^Text_Edit,size:f32,row:int) -> (start,end:int) {
    it:=text_edit_lines(ctx,e,size)
    for {
        line_start,line_end,ok:=text_lines_next(&it)
        if !ok {break}
        start,end=line_start,line_end
        if it.row>=row {break}
    }
    return
}
// Moves the caret step lines, keeping the units it had from the start of its
// line. Past the first or the last line it goes to the edge of the text.
@(private)
text_edit_line_move :: proc "contextless" (ctx:^Context,e:^Text_Edit,size:f32,step:int,extend:bool) {
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

text_edit_delete_selection :: proc "contextless" (e:^Text_Edit) -> bool {
    lo,hi:=text_edit_selection(e)
    if lo==hi {return false}
    copy(e.buffer[lo:],e.buffer[hi:e.length])
    e.length-=hi-lo
    e.cursor=lo;e.anchor=lo
    e.changes+=1
    return true
}
// Replaces the selection with c.
text_edit_insert :: proc "contextless" (e:^Text_Edit,c:u8) {
    if !text_edit_takes(e,c) {return}
    text_edit_delete_selection(e)
    if e.length>=e.capacity {return}
    copy(e.buffer[e.cursor+1:e.length+1],e.buffer[e.cursor:e.length])
    e.buffer[e.cursor]=c;e.length+=1;e.cursor+=1;e.anchor=e.cursor
    e.changes+=1
}
text_edit_remove :: proc "contextless" (e:^Text_Edit,at:int) {
    if at<0 || at>=e.length {return}
    copy(e.buffer[at:e.length-1],e.buffer[at+1:e.length])
    e.length-=1
    e.changes+=1
    if e.cursor>at {e.cursor-=1}
    e.anchor=e.cursor
}

// Puts the clipboard at the caret in one move: it is read into the room after
// the text, and what the filter takes turns into place.
@(private)
text_edit_paste :: proc(ctx:^Context,e:^Text_Edit) {
    text_edit_delete_selection(e)
    room:=e.buffer[e.length:e.capacity]
    count:=clamp(ctx.clipboard_get(ctx.clipboard_user,room),0,len(room))
    kept:=0
    for c in room[:count] {
        if text_edit_takes(e,c) {room[kept]=c;kept+=1}
    }
    if kept==0 {return}
    slice.rotate_right(e.buffer[e.cursor:e.length+kept],kept)
    e.length+=kept;e.cursor+=kept;e.anchor=e.cursor
    e.changes+=1
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
    } else {
        for c in in_.text[:in_.text_count] {text_edit_insert(e,c)}
    }
    if .Backspace in in_.keys_repeated && !text_edit_delete_selection(e) {text_edit_remove(e,e.cursor-1)}
    if .Delete in in_.keys_repeated && !text_edit_delete_selection(e) {text_edit_remove(e,e.cursor)}
    // Without Shift an arrow collapses a selection to that edge instead of stepping.
    if .Left in in_.keys_repeated {
        lo,hi:=text_edit_selection(e)
        text_edit_move(e,e.cursor-1 if shift||lo==hi else lo,shift)
    }
    if .Right in in_.keys_repeated {
        lo,hi:=text_edit_selection(e)
        text_edit_move(e,e.cursor+1 if shift||lo==hi else hi,shift)
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

// The caret index under a point of the field, by line when the text wraps.
@(private)
text_edit_index_at :: proc "contextless" (ctx:^Context,e:^Text_Edit,size:f32,a:Text_Area,cell:bool=false) -> int {
    x:=ctx.pointer.x-a.x+e.scroll
    if !e.multiline {return text_index_at(&ctx.font,text_edit_value(e),size,x,cell,int(e.font))}
    row:=max(int((ctx.pointer.y-a.y+e.scroll_y)/a.line),0)
    start,end:=text_edit_line_at(ctx,e,size,row)
    return start+text_index_at(&ctx.font,text_edit_value(e)[start:end],size,x,cell,int(e.font))
}

// A press on the field being edited: the first click places the caret (Shift
// extends the selection), the second selects a word, or places the caret too
// without words, and the third everything.
text_edit_press :: proc(ctx:^Context,e:^Text_Edit,size:f32,a:Text_Area,words:=true) {
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
}
// While the button of that press is held: moving the pointer selects.
text_edit_drag :: proc(ctx:^Context,e:^Text_Edit,size:f32,a:Text_Area) {
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
// pad and font: those of field_text_area and of the text.
@(private)
field_edit_update :: proc(ctx:^Context,id:Id,it:Interaction,size:f32,label:string,words:=true,marked:=false,pad:f32=0,font:u8=0,icon:=Icon.None) -> (event:Edit_Event,tab:int) {
    e:=&ctx.edit
    cursor,anchor:=e.cursor,e.anchor
    e.frame=ctx.stats.frame
    e.font=font
    rect,_:=widget_rect(ctx,id)
    area:=field_text_area(ctx,rect,label,size,e.multiline,marked,pad,icon)
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
    if rect.w>0 {text_edit_reveal(ctx,e,size,area.w,area.h)}
    return
}

@(private)
field_paint :: proc(ctx:^Context,id:Id,it:Interaction,text:string,size:f32,label:string,strip:Color,placeholder:string,held,disabled:bool,icon:=Icon.None) -> ^Paint {
    th:=&ctx.theme
    e:=&ctx.edit
    editing:=e.id==id && id!=0
    // A well with an outline that lightens under the pointer; editing keeps
    // the fill: the accent outline marks it and the selection shows on the text.
    fill:=th.field_active if held else th.well
    stroke:=th.well_stroke_hover if it.hot && !disabled else th.well_stroke
    paint:=Paint{kind=.Field,fill=fill,stroke=stroke,text=text,text_color=th.text_faint if disabled else th.text,size=size,caret=-1,label=label,strip=strip,placeholder=placeholder,icon=icon}
    if editing {
        lo,hi:=text_edit_selection(e)
        paint.stroke=th.accent
        paint.text=text_edit_value(e);paint.caret=e.cursor;paint.selection={lo,hi};paint.scroll=e.scroll
        paint.caret_hidden=int(max(ctx.time-e.caret_started,0)*2)%2!=0
    }
    return paint_add(ctx,paint)
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
    open:bool,           // its element stays open for what the caller builds in it, who closes it when result.open
}
Text_Result :: struct {
    editing:bool,
    began:bool,     // editing began this frame
    changed:bool,   // the buffer of the caller changed this frame
    committed:bool, // Enter, Tab or a click elsewhere ended the edit
    cancelled:bool, // Escape ended it; the buffer keeps what it had
    tab:int,        // 1 or -1 when Tab or Shift+Tab ended it
    open:bool,      // Text_Field.open: its element is open
}

// A field that edits the text in buffer[:length^].
text_field :: proc(ctx:^Context,id:Id,buffer:[]u8,length:^int,field:Text_Field={}) -> (result:Text_Result) {
    field:=field
    field.disabled|=ctx.disabled_depth>0
    th:=&ctx.theme
    e:=&ctx.edit
    look:=field.style
    if field.disabled && e.id==id && id!=0 {e^={};result.cancelled=true}
    size:=field.size if field.size>0 else th.font_small
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
        event,tab:=field_edit_update(ctx,id,it,size,field.label,marked=field.strip[3]>0,pad=field.padding,font=font,icon=field.icon)
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
            if rect,found:=widget_rect(ctx,id);found {text_edit_press(ctx,e,size,field_text_area(ctx,rect,field.label,size,field.multiline,field.strip[3]>0,field.padding,field.icon))}
        }
        result.began=true
    }
    result.editing=e.id==id && id!=0
    paint:=field_paint(ctx,id,it,string(buffer[:length^]),size,field.label,field.strip,field.placeholder,false,field.disabled,field.icon)
    if paint!=nil {
        paint.multiline=field.multiline
        paint.style.font=font
        paint.padding=field.padding
        paint.scroll_y=e.scroll_y if result.editing else 0
        if field.password {
            masked:=text_reserve(ctx,len(paint.text))
            for &c in masked {c='*'}
            paint.text=text_commit(ctx,string(masked))
        }
        if !field.disabled && field.color[3]>0 {paint.text_color=field.color}
        if field.bare {paint.fill={};paint.stroke={}}
        if field.inline && !result.editing {paint.fill={};paint.stroke=th.border if it.hot && !field.disabled else {}}
        if look!=nil {field_paint_look(paint,look)}
    }
    height:=field.height
    if height<=0 {
        line:=size*TEXT_LINE
        if look!=nil {
            height=f32(max(field.rows,1))*line+2*field.padding if field.multiline else line+2*field.padding
        } else {height=f32(max(field.rows,1))*line+10 if field.multiline else th.row}
    }
    element:=Element{id=id,layout={width=(field.width if field.width!={} else GROW),height=fixed(height)},custom=paint}
    if field.open {
        element.layout.direction,element.layout.align_y=.Row,.Center
        result.open=element_open(ctx,element)
    } else {element_leaf(ctx,element)}
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
