package ui

// Containers that clip what they hold and move it with the wheel, the keys
// and the right stick. The offset belongs to the caller. Long lists build
// only the rows in sight.

SCROLL_BAR :: f32(6)       // width of a bar over the right or the bottom edge of an area
SCROLL_GUTTER :: SCROLL_BAR+4 // the room at the right or the bottom of content that scrolls, which the bar takes
SCROLL_THUMB :: f32(20)    // shortest thumb
SCROLL_FADE :: [2]f32{7,20} // how far the content fades into the edges of an area with fade, top and bottom
SCROLL_STICK :: f32(1200)  // layout units a second the stick all the way over moves the content
WHEEL_STEP :: f32(36)       // layout units a notch of the wheel scrolls
SCROLL_PAGE :: f32(0.9)    // of the area, what Page Up and Page Down move the content

// The axes an area scrolls in. Across, its content is as wide as it asks
// for instead of as wide as the area: a paragraph in it does not wrap.
Scroll_Axes :: enum u8 {Vertical,Horizontal,Both}

Scroll :: struct {
    using layout:Layout, // of the content; width and height are those of the area. Vertical: always a column
    step:f32,            // units per wheel notch; WHEEL_STEP when 0
    max_height:f32,      // with a FIT height: the area stops growing here
    fade:Color,          // what is under the area: content scrolled past an edge fades into it there; transparent: none
    axes:Scroll_Axes,
    bar:Scroll_Bar,
}

// How the bars of an area look; zero: as the theme draws them.
Scroll_Bar :: struct {
    width:f32,         // across the bar; SCROLL_BAR when 0
    track,knob:Color,  // the whole bar under its thumb, and the thumb; a transparent knob: the tones of the theme
    radius:[4]f32,     // of both; none: round
}

// The room an area leaves at the right or the bottom of content that scrolls, which its bar takes.
@(private)
scroll_gutter :: proc "contextless" (bar:Scroll_Bar) -> f32 {return (bar.width if bar.width>0 else SCROLL_BAR)+SCROLL_GUTTER-SCROLL_BAR}

@(private)
scroll_content_id :: proc(ctx:^Context,id:Id) -> Id {return id_derive(ctx,id,"content")}

@(private)
scroll_bar_id :: proc(ctx:^Context,id:Id,vertical:bool) -> Id {return id_derive(ctx,id,"bar" if vertical else "bar_x")}

@(private)
scroll_moves :: #force_inline proc "contextless" (axes:Scroll_Axes) -> [2]bool {return {axes!=.Vertical,axes!=.Horizontal}}

@(private)
rect_holds :: proc "contextless" (outer,inner:Rect) -> bool {
    return inner.x>=outer.x-0.5 && inner.y>=outer.y-0.5 && inner.x+inner.w<=outer.x+outer.w+0.5 && inner.y+inner.h<=outer.y+outer.h+0.5
}

// The clip the area id just opened scrolls: what it hides is still reached by navigation.
@(private)
scroll_clip_mark :: proc(ctx:^Context,id:Id) {
    if ctx.clip_depth>0 && ctx.clips[ctx.clip_stack[ctx.clip_depth-1]].id==id {ctx.clips[ctx.clip_stack[ctx.clip_depth-1]].scroll=true}
}

// Moves the rectangle r of the content into sight on the axes the area moves.
@(private)
scroll_reveal_rect :: proc "contextless" (offset:^[2]f32,moves:[2]bool,r,view,content:Rect) {
    if moves.y {scroll_reveal(&offset.y,r.y-content.y,r.y+r.h-content.y,view.h)}
    if moves.x {scroll_reveal(&offset.x,r.x-content.x,r.x+r.w-content.x,view.w)}
}

// Brings the widget the keyboard just moved to into sight. An area inside
// this one that holds it goes first; this one follows on a later frame, with
// the place the inner one left it in.
@(private)
scroll_follow_focus :: proc(ctx:^Context,id:Id,offset:^[2]f32,moves:[2]bool,view,content:Rect) {
    if ctx.focus==0 || !ctx.focus_moved {return}
    r,found:=widget_rect(ctx,ctx.focus)
    if !found || !rect_holds(content,r) {return}
    for &w in ctx.previous[:ctx.previous_count] {
        if w.id==id || .Scroll not_in w.flags || !rect_holds(content,w.rect) || rect_holds(w.rect,r) {continue}
        inner,has_inner:=widget_rect(ctx,scroll_content_id(ctx,w.id))
        if has_inner && rect_holds(inner,r) {ctx.focus_pending=true;return}
    }
    before:=offset^
    scroll_reveal_rect(offset,moves,r,view,content)
    if offset^!=before {ctx.focus_pending=true}
}

// What the wheel, the keys and the stick do to the offset of the area id
// this frame, on the axes it moves. Shift turns the wheel sideways, and an
// area that only scrolls sideways, or whose content fits its height, takes
// the wheel so. view, content: their
// sizes, for the page keys and End.
@(private)
scroll_move :: proc(ctx:^Context,id:Id,offset:^[2]f32,moves:[2]bool,step:f32,view,content:[2]f32) {
    in_:=&ctx.input
    step:=step if step>0 else WHEEL_STEP
    if ctx.wheel_target==id && in_.wheel!={} {
        sideways:=moves.x && (.Shift in in_.modifiers || !moves.y || content.y<=view.y+0.5)
        if moves.y && !sideways {offset.y-=in_.wheel.y*step}
        if moves.x {offset.x+=in_.wheel.x*step-(in_.wheel.y*step if sideways else 0)}
    }
    if ctx.scroll_target!=id || id==0 {return}
    if ctx.scroll_keys {
        axis:=1 if moves.y else 0
        if .Page_Down in in_.keys_repeated {offset[axis]+=view[axis]*SCROLL_PAGE}
        if .Page_Up in in_.keys_repeated {offset[axis]-=view[axis]*SCROLL_PAGE}
        if .Home in in_.keys_pressed {offset[axis]=0}
        if .End in in_.keys_pressed {offset[axis]=max(content[axis]-view[axis],0)}
    }
    for axis in 0..<2 {if moves[axis] {offset[axis]+=in_.scroll[axis]*SCROLL_STICK*in_.dt}}
}

// Whether the area w can still move its content the way the wheel turns, by
// the rectangles of the last frame. An area without content of its own pans
// or zooms, and Ctrl and the wheel zoom: they take any wheel.
@(private)
scroll_room :: proc(ctx:^Context,w:^Widget) -> bool {
    content:=widget_previous(ctx,scroll_content_id(ctx,w.id))
    if content==nil || .Primary in ctx.input.modifiers {return true}
    v,c,wheel:=w.rect,content.rect,ctx.input.wheel
    if .Shift in ctx.input.modifiers || c.h<=v.h+0.5 {wheel={wheel.x-wheel.y,0}}
    return wheel.y>0 && c.y<v.y-0.5 || wheel.y<0 && c.y+c.h>v.y+v.h+0.5 || wheel.x<0 && c.x<v.x-0.5 || wheel.x>0 && c.x+c.w>v.x+v.w+0.5
}

// The area the page keys and the stick move this frame: the innermost one
// under the pointer, or else the innermost one that holds the focus, or else
// the largest of the highest layer navigation reaches. The keys move it only
// while it holds nothing focusable, where they would be navigation.
@(private)
scroll_route :: proc(ctx:^Context) {
    ctx.scroll_target,ctx.scroll_keys=0,false
    in_:=&ctx.input
    keys:=ctx.edit.id==0 && (in_.keys_repeated&{.Page_Up,.Page_Down}!={} || in_.keys_pressed&{.Home,.End}!={})
    if !keys && in_.scroll=={} {return}
    target:^Widget
    areas:=ctx.previous[:ctx.previous_count]
    if !in_.pointer_absent {
        for &w in areas {
            if .Scroll not_in w.flags || w.surface!=0 || ctx.hot!=0 && w.layer<ctx.hot_layer || !widget_contains(ctx,&w,ctx.screen_pointer) {continue}
            if target==nil || w.layer>=target.layer {target=&w}
        }
    }
    if focus,held:=widget_rect(ctx,ctx.focus);target==nil && ctx.focus!=0 && held {
        for &w in areas {
            if .Scroll not_in w.flags || !rect_holds(w.rect,focus) {continue}
            if target==nil || w.layer>target.layer || w.layer==target.layer && rect_holds(target.rect,w.rect) {target=&w}
        }
    }
    if target==nil {
        for &w in areas {
            if .Scroll not_in w.flags || w.layer<ctx.navigation_layer || w.area.w<=0 || w.area.h<=0 {continue}
            if target==nil || w.layer>target.layer || w.layer==target.layer && w.area.w*w.area.h>target.area.w*target.area.h {target=&w}
        }
    }
    if target==nil {return}
    ctx.scroll_target=target.id
    if !keys {return}
    for &w in areas {
        if w.layer>=target.layer && navigation_candidate(ctx,&w) && rect_holds(target.rect,w.rect) {return}
    }
    ctx.scroll_keys=true
}

// The bar of an area with more content than room in an axis: a thumb over
// its track along its right edge, or its bottom edge, that takes no layout
// and can be dragged. Nothing is drawn when it all fits.
@(private)
scroll_bar :: proc(ctx:^Context,id:Id,offset:^f32,vertical:bool,look:Scroll_Bar={}) {
    view,found:=widget_rect(ctx,id)
    content,_:=widget_rect(ctx,scroll_content_id(ctx,id))
    room,length:=view.h,content.h
    if !vertical {room,length=view.w,content.w}
    span:=max(length-room,offset^)
    if !found || span<=0.5 || room<=0 {return}
    bar:=scroll_bar_id(ctx,id,vertical)
    thumb:=max(room*room/length,min(SCROLL_THUMB,room))
    travel:=max(room-thumb,0)
    it:=interact(ctx,bar,{})
    if it.pressed {ctx.scroll_grab=offset^}
    if it.active && travel>0 {
        moved:=ctx.pointer.y-ctx.press.y if vertical else ctx.pointer.x-ctx.press.x
        offset^=clamp(ctx.scroll_grab+moved*span/travel,0,span)
    }
    along:=travel*(offset^/span if span>0 else 0)
    width:=look.width if look.width>0 else SCROLL_BAR
    color:=look.knob
    if color[3]==0 {color=tone(ctx,"text_faint") if it.active || it.hot else tone(ctx,"border")}
    corners:=look.radius if look.radius!={} else [4]f32{width,width,width,width}*0.5
    place :: proc(e:^Element,vertical:bool,view:Rect,width,along,length:f32) {
        if vertical {
            e.layout={width=fixed(width),height=fixed(length)}
            e.float={to=.Parent,offset={view.w-width,along}}
        } else {
            e.layout={width=fixed(length),height=fixed(width)}
            e.float={to=.Parent,offset={along,view.h-width}}
        }
    }
    if look.track[3]>0 {
        track:=Element{custom=paint_add(ctx,{kind=.Rect,fill=look.track,corners=corners})}
        place(&track,vertical,view,width,0,room)
        element_leaf(ctx,track)
    }
    e:=Element{id=bar,custom=paint_add(ctx,{kind=.Rect,fill=color,corners=corners})}
    place(&e,vertical,view,width,along,thumb)
    element_leaf(ctx,e)
}

// Opens an area that scrolls on its axes (vertically unless s.axes says
// otherwise); what is built until scroll_end is its content. offset: how far
// the content is moved left and up, kept in range here.
scroll_begin :: proc(ctx:^Context,id:Id,offset:^[2]f32,s:Scroll={}) {
    content_id:=scroll_content_id(ctx,id)
    view,found:=widget_rect(ctx,id)
    content,_:=widget_rect(ctx,content_id)
    moves:=scroll_moves(s.axes)
    scroll_move(ctx,id,offset,moves,s.step,{view.w,view.h},{content.w,content.h})
    if found {scroll_follow_focus(ctx,id,offset,moves,view,content)}
    if found && ctx.reveal!=0 {
        if r,shown:=widget_rect(ctx,ctx.reveal);shown && rect_holds(content,r) {scroll_reveal_rect(offset,moves,r,view,content)}
    }
    // Content that got shorter keeps what is in sight where it was: the room
    // left under it (scroll_end) goes as the area scrolls up, never down.
    if !moves.x {offset.x=0}
    if !moves.y {offset.y=0}
    if found {
        offset.y=min(offset.y,max(content.h-view.h,0))
        offset.x=min(offset.x,max(content.w-view.w,0))
        offset^={max(offset.x,0),max(offset.y,0)}
    }
    height:=s.height
    if height.kind==.Fit && s.max_height>0 {height.max=s.max_height}
    box_begin(ctx,{id=id,width=s.width if s.width!={} else GROW,height=height,direction=.Column,clip_x=moves.x,clip_y=true,scroll=offset^})
    scroll_clip_mark(ctx,id)
    widget_add(ctx,id,{.Passive,.Scroll})
    inner:=s.layout
    inner.width=GROW
    inner.height=GROW if s.axes==.Horizontal else FIT
    if s.axes==.Vertical {inner.direction=.Column}
    // Content larger than the area leaves the bar a column, or a row, of its own.
    if found && moves.y && content.h-view.h>0.5 {inner.padding[2]=max(inner.padding[2],scroll_gutter(s.bar))}
    if found && moves.x && content.w-view.w>0.5 {inner.padding[3]=max(inner.padding[3],scroll_gutter(s.bar))}
    box_begin(ctx,{id=content_id,layout=inner,track=true})
}
scroll_end :: proc(ctx:^Context,id:Id,offset:^[2]f32=nil,fade:Color={},bar:Scroll_Bar={}) {
    box_end(ctx,{id=scroll_content_id(ctx,id)})
    if offset!=nil {
        view,found:=widget_rect(ctx,id)
        content,_:=widget_rect(ctx,scroll_content_id(ctx,id))
        if slack:=offset.y-max(content.h-view.h,0);found && slack>0 {element_leaf(ctx,{layout={width=fixed(1),height=fixed(slack)}})}
    }
    if offset!=nil && fade[3]>0 {scroll_fade(ctx,id,offset.y,fade)}
    if offset!=nil {
        scroll_bar(ctx,id,&offset.y,true,bar)
        scroll_bar(ctx,id,&offset.x,false,bar)
    }
    box_end(ctx,{id=id,clip_y=true})
}

// Content past the top or the bottom of an area fades into what is under it.
@(private)
scroll_fade :: proc(ctx:^Context,id:Id,offset:f32,color:Color) {
    view,found:=widget_rect(ctx,id)
    content,_:=widget_rect(ctx,scroll_content_id(ctx,id))
    if !found || view.h<=0 {return}
    clear:=Color{color[0],color[1],color[2],0}
    top,bottom:=SCROLL_FADE[0],min(SCROLL_FADE[1],view.h*0.5)
    if offset>0.5 {
        element_leaf(ctx,{layout={width=fixed(view.w),height=fixed(top)},float={to=.Parent,offset={0,0}},custom=paint_add(ctx,{kind=.Bar,fill=color,fill2=clear})})
    }
    if content.h-view.h-offset>0.5 {
        element_leaf(ctx,{layout={width=fixed(view.w),height=fixed(bottom)},float={to=.Parent,offset={0,view.h-bottom}},custom=paint_add(ctx,{kind=.Bar,fill=clear,fill2=color})})
    }
}
@(deferred_in=scroll_area_end)
scroll_area :: proc(ctx:^Context,id:Id,offset:^[2]f32,s:Scroll={}) -> bool {
    scroll_begin(ctx,id,offset,s)
    return true
}
@(private)
scroll_area_end :: proc(ctx:^Context,id:Id,offset:^[2]f32,s:Scroll) {scroll_end(ctx,id,offset,s.fade,s.bar)}

// The notches of a Ctrl+wheel (Cmd on macOS) over the scroll area id: the
// gesture that zooms what it shows. The area does not scroll with them. Call
// it before the area is built; 0 for any other wheel.
zoom :: proc(ctx:^Context,id:Id) -> f32 {
    if ctx.wheel_target!=id || id==0 || .Primary not_in ctx.input.modifiers || ctx.input.wheel.y==0 {return 0}
    ctx.wheel_target=0
    return ctx.input.wheel.y
}

// Moves offset the least that brings the rows [top, bottom) in sight.
scroll_reveal :: proc "contextless" (offset:^f32,top,bottom,visible:f32) {
    if top<offset^ {offset^=top}
    if bottom>offset^+visible {offset^=bottom-visible}
}

// Opens a list of count rows of the same height that shows `height` units of
// them. Build the rows first..<last and call list_end: only they become
// elements, with room above and below that keeps the scroll range.
list_begin :: proc(ctx:^Context,id:Id,offset:^f32,count:int,row_height,height:f32,step:f32=0) -> (first,last:int) {
    moved:=[2]f32{0,offset^}
    scroll_move(ctx,id,&moved,{false,true},step,{0,height},{0,f32(count)*row_height})
    offset^=clamp(moved.y,0,max(f32(count)*row_height-height,0))
    first=clamp(int(offset^/row_height),0,count)
    last=min(first+int(height/row_height)+2,count)
    box_begin(ctx,{id=id,width=GROW,height=fixed(height),direction=.Column,clip_y=true,scroll={0,offset^}})
    scroll_clip_mark(ctx,id)
    widget_add(ctx,id,{.Passive,.Scroll})
    box_begin(ctx,{id=scroll_content_id(ctx,id),width=GROW,height=FIT,direction=.Column,track=true})
    spacer(ctx,-1,f32(first)*row_height)
    return
}
list_end :: proc(ctx:^Context,id:Id,count,last:int,row_height:f32) {
    spacer(ctx,-1,f32(count-last)*row_height)
    box_end(ctx,{id=scroll_content_id(ctx,id)})
    box_end(ctx,{id=id,clip_y=true})
}

// Opens an area of rows of different heights, one per entry of heights, that
// shows `height` units of them with a bar. Build the rows first..<last at
// their heights and call rows_end: only they become elements, with room above
// and below that keeps the scroll range. An offset past the end shows the last
// rows.
rows_begin :: proc(ctx:^Context,id:Id,offset:^f32,heights:[]f32,width:Size,height:f32,step:f32=0,bar_room:f32=0) -> (first,last:int) {
    total:f32
    for h in heights {total+=h}
    moved:=[2]f32{0,offset^}
    scroll_move(ctx,id,&moved,{false,true},step,{0,height},{0,total})
    offset^=clamp(moved.y,0,max(total-height,0))
    top:f32
    first=len(heights)
    for h,i in heights {
        if top+h>offset^ {first=i;break}
        top+=h
    }
    bottom:=top
    last=first
    for last<len(heights) && bottom<offset^+height {bottom+=heights[last];last+=1}
    box_begin(ctx,{id=id,width=width,height=fixed(height),direction=.Column,clip_y=true,scroll={0,offset^}})
    scroll_clip_mark(ctx,id)
    widget_add(ctx,id,{.Passive,.Scroll})
    box_begin(ctx,{id=scroll_content_id(ctx,id),width=GROW,height=FIT,direction=.Column,padding={0,0,bar_room,0},track=true})
    if top>0 {spacer(ctx,-1,top)}
    return
}
rows_end :: proc(ctx:^Context,id:Id,offset:^f32,heights:[]f32,last:int) {
    rest:f32
    for h in heights[last:] {rest+=h}
    if rest>0 {spacer(ctx,-1,rest)}
    box_end(ctx,{id=scroll_content_id(ctx,id)})
    scroll_bar(ctx,id,offset,true)
    box_end(ctx,{id=id,clip_y=true})
}

