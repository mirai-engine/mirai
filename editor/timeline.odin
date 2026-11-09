package editor

import "core:fmt"
import "core:math"
import "mirai:ui"

// The time strip of a document that plays: a row of transport over a ruler
// with its head, lanes of marks and a bar with what is in view. It does not
// own the time: it reads a Timeline_Clock and returns what was asked, and the
// document applies it to its data. Frames count from 0 to the duration.
// The right button on the ruler opens its menu: an end of the range at a
// frame and, for a document that can describe its range, Copy range.

TIMELINE_TRANSPORT :: f32(40)
TIMELINE_RULER :: f32(34)
TIMELINE_LANE :: f32(32)
TIMELINE_OVERVIEW :: f32(18)
TIMELINE_NAMES :: f32(132) // the column of the frame and the names of the lanes
TIMELINE_PAD :: f32(10)    // from the edges of the ruler to the first and the last frame
TIMELINE_REACH :: f32(6)   // points from a mark, a bracket or an edge that the pointer takes it within
TIMELINE_MIN_FRAMES :: f32(4) // the fewest frames the view shows

// What a document keeps of its strip; nothing of it is saved with the asset.
Timeline :: struct {
    start,end:f32,           // frames in view; end<=start: the whole duration
    range:bool,              // in and out bound what plays and what loops
    range_in,range_out:f32,  // frames; range_out<=range_in: the whole duration
    seconds:bool,            // the ruler and the field count seconds
    drag:Timeline_Drag,
    grab:f32,                // frames from what is dragged to the pointer when it was taken
    mark:[2]int,             // lane and index plus one of the mark chosen; index 0: none
    dragged:f32,             // the frame the mark being dragged is at
    pointed:f32,             // the frame the right button went down on in the ruler
}
Timeline_Drag :: enum u8 {None,Head,In,Out,View,View_Start,View_End,Mark}

// A range turned on starts at the head, and ends where it ended if that is after it.
@(private)
timeline_range_start :: proc(t:^Timeline,frame,frames:f32) {
    t.range_in=clamp(frame,0,max(frames-1,0))
    if t.range_out<=t.range_in || t.range_out>frames {t.range_out=frames}
}

// What plays, as the strip reads it.
Timeline_Clock :: struct {
    frame:f32,  // where the head is
    frames:f32, // the duration; 0: nothing plays
    rate:f32,   // frames per second
    playing,loop:bool,
    speed:f32,  // 0: the document has no speed to choose
    here:bool,  // it can play on from the head, without what comes after it
    ask:bool,   // the document describes its range: a button asks the agent about it, and the menu copies it
}

// A row of marks on the time: markers of a clip, keys of a track.
Timeline_Lane :: struct {
    name:string,
    marks:[]Timeline_Mark,
    add:bool, // a button adds a mark at the head
}
Timeline_Mark :: struct {
    frame:f32,
    name:string,
}

// What the strip asks of the document this frame.
Timeline_Result :: struct {
    seek:bool,
    frame:f32,          // where the head goes; it stops playing
    play,loop:bool,     // toggled
    here:bool,          // play on from the head
    speed:f32,          // chosen; 0: none
    moved:bool,         // a mark was dropped at to
    lane,index:int,     // of the mark moved, added to or under the right button (-1: none)
    to:f32,
    add:bool,           // the button of lane adds a mark at the head
    menu:bool,          // the right button went down on lane at to, on index
    ruler:bool,         // the right button went down on the ruler at Timeline.pointed
    anchor:ui.Rect,     // where the menu opens
    ask:bool,           // the button asks the agent about the range
    copy:bool,          // the menu copies the range
}

TIMELINE_SPEED_LABELS :: [4]string{"0.25×","0.5×","1×","2×"}
TIMELINE_SPEEDS :: [4]f32{0.25,0.5,1,2}

timeline_height :: proc(lanes:int) -> f32 {
    return TIMELINE_TRANSPORT+TIMELINE_RULER+f32(lanes)*TIMELINE_LANE+TIMELINE_OVERVIEW
}

// The frames in view and the range, inside the duration.
timeline_view :: proc(t:^Timeline,frames:f32) -> (start,end:f32) {
    if t.end<=t.start || frames<=0 {return 0,max(frames,0)}
    span:=clamp(t.end-t.start,min(TIMELINE_MIN_FRAMES,frames),frames)
    start=clamp(t.start,0,frames-span)
    return start,start+span
}
timeline_range :: proc(t:^Timeline,frames:f32) -> (lo,hi:f32) {
    if t.range_out<=t.range_in {return 0,max(frames,0)}
    lo=clamp(t.range_in,0,frames)
    hi=clamp(t.range_out,lo,frames)
    return
}

// Sets the start or the end of the range at a frame, the range on. The
// other end stays while it keeps start before end; otherwise, or with no
// range, it goes to the head when the head is on its side, else to the
// start or the end of the duration.
timeline_range_set :: proc(t:^Timeline,frames,frame,head:f32,end:bool) {
    if frames<1 {return}
    head:=clamp(math.round(head),0,frames)
    had:=t.range && t.range_out>t.range_in
    lo,hi:=timeline_range(t,frames)
    if end {
        at:=clamp(math.round(frame),1,frames)
        if !had || lo>=at {lo=head<at?head:0}
        t.range_in,t.range_out=lo,at
    } else {
        at:=clamp(math.round(frame),0,frames-1)
        if !had || hi<=at {hi=head>at?head:frames}
        t.range_in,t.range_out=at,hi
    }
    t.range=true
}

// Where what plays starts and ends: the range while it is on.
timeline_bounds :: proc(t:^Timeline,frames:f32) -> (lo,hi:f32) {
    if !t.range {return 0,max(frames,0)}
    return timeline_range(t,frames)
}

@(private)
timeline_text :: proc(t:^Timeline,frame,rate:f32,whole:bool) -> string {
    if !t.seconds || rate<=0 {return fmt.tprintf("%d",int(math.round(frame)))}
    return fmt.tprintf("%.2f",frame/rate) if !whole else fmt.tprintf("%g s",math.round(frame/rate*100)/100)
}

// Frames between the ticks of the ruler and between its labels, for
// points per frame: the smallest steps that keep them apart.
@(private)
timeline_steps :: proc(scale,rate:f32) -> (tick,label:f32) {
    STEPS :: [?]f32{1,2,5,10,15,30,60,120,300,600,1200,3000,6000}
    steps:=STEPS
    tick,label=steps[len(steps)-1],steps[len(steps)-1]
    for step in steps {if step*scale>=6 {tick=step;break}}
    for step in steps {if step*scale>=56 {label=step;break}}
    // A second is a label when it fits.
    if rate>0 && label<rate && rate*scale>=56 && math.mod(rate,label)!=0 {label=rate}
    return
}

timeline_strip :: proc(s:^Session,t:^Timeline,c:Timeline_Clock,lanes:[]Timeline_Lane,id:ui.Id) -> (r:Timeline_Result) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    ui.id_push(ctx,id)
    defer ui.id_pop(ctx)
    r.lane,r.index=-1,-1
    empty:=c.frames<=0
    if empty {t.drag=.None}
    lo,hi:=timeline_bounds(t,c.frames)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(timeline_height(len(lanes))),direction=.Column}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(TIMELINE_TRANSPORT),padding={12,0,12,0},gap=2,align_y=.Center}) {
            if empty {ui.disabled_begin(ctx)}
            defer if empty {ui.disabled_end(ctx)}
            transport :: proc(ctx:^ui.Context,name:string,icon:ui.Icon,tip:string,style:=ui.Button_Style.Ghost,active:=false,width:=f32(28)) -> bool {
                return ui.button(ctx,ui.id(ctx,name),{icon=icon,icon_color=ctx.theme.text_muted,tip=tip,style=style,active=active,width=width,height=ctx.theme.control}).clicked
            }
            if transport(ctx,"to_start",timeline_icon(.To_Start),"Go to start") {r.seek,r.frame=true,lo}
            if transport(ctx,"previous",timeline_icon(.Step_Back),"Previous frame") {r.seek,r.frame=true,max(math.ceil(c.frame)-1,0)}
            if transport(ctx,"play",c.playing?timeline_icon(.Pause):.Play,c.playing?"Pause":"Play",.Tab,c.playing,34) {r.play=true}
            if transport(ctx,"next",timeline_icon(.Step_Forward),"Next frame") {r.seek,r.frame=true,min(math.floor(c.frame)+1,c.frames)}
            if transport(ctx,"to_end",timeline_icon(.To_End),"Go to end") {r.seek,r.frame=true,hi}
            timeline_divider(ctx)
            if transport(ctx,"loop",timeline_icon(.Loop),"Loop",.Tab,c.loop) {r.loop=true}
            if c.speed>0 {
                speeds:=TIMELINE_SPEEDS
                labels:=TIMELINE_SPEED_LABELS
                selected:=2
                for speed,i in speeds {if speed==c.speed {selected=i}}
                if ui.dropdown(ctx,ui.id(ctx,"speed"),labels[:],&selected,{width=58}) {r.speed=speeds[selected]}
            }
            if c.here {
                timeline_divider(ctx)
                if ui.button(ctx,ui.id(ctx,"here"),{label="Play from here",icon=.Play,icon_color=th.text_muted,style=.Field,height=th.control}).clicked {r.here=true}
            }
            ui.spacer(ctx)
            if c.ask && t.range && t.range_out>t.range_in {
                if transport(ctx,"ask",.Sparkle,"Ask agent about the range") {r.ask=true}
            }
            if transport(ctx,"range",timeline_icon(.Range),"Range",.Tab,t.range) {
                t.range=!t.range
                if t.range {timeline_range_start(t,c.frame,c.frames)}
            }
            timeline_divider(ctx)
            if ui.box(ctx,{width=ui.FIT,height=ui.fixed(th.control-2),padding={2,2,2,2},gap=2,fill=th.well,radius=th.radius_control,align_y=.Center}) {
                for unit in ([2]string{"f","s"}) {
                    on:=(unit=="s")==t.seconds
                    if ui.button(ctx,ui.id(ctx,unit),{label=unit,style=on?.Field:.Ghost,width=26,height=th.control-6,size=th.font_small,center=true,tip=unit=="s"?"Seconds":"Frames"}).clicked {t.seconds=unit=="s"}
                }
            }
            if transport(ctx,"fit",timeline_icon(.Fit_Width),"Show all") {t.start,t.end=0,0}
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW}) {
            timeline_names(s,t,c,lanes,&r,empty)
            timeline_area(s,t,c,lanes,&r,empty)
        }
    }
    menu:=ui.id(ctx,"range_menu")
    if r.ruler {ui.popup_open(ctx,menu,r.anchor)}
    if ui.popup(ctx,menu,{min_width=ui.MENU_CHOICE_WIDTH}) {
        if ui.menu_item(ctx,ui.id(ctx,"range_start"),"Set range start") {timeline_range_set(t,c.frames,t.pointed,c.frame,false)}
        if ui.menu_item(ctx,ui.id(ctx,"range_end"),"Set range end") {timeline_range_set(t,c.frames,t.pointed,c.frame,true)}
        if c.ask && ui.menu_item(ctx,ui.id(ctx,"range_copy"),"Copy range",{icon=.Sparkle,disabled=!t.range || t.range_out<=t.range_in}) {r.copy=true}
    }
    return
}

@(private)
timeline_icon :: proc(icon:User_Icon) -> ui.Icon {return ui.icon_user(u8(icon))}

@(private)
timeline_divider :: proc(ctx:^ui.Context) {
    if ui.box(ctx,{width=ui.fixed(1),height=ui.fixed(18),fill=ctx.theme.border}) {}
    ui.spacer(ctx,14,1)
}

// The column at the left: the frame of the head over the names of the lanes.
@(private)
timeline_names :: proc(s:^Session,t:^Timeline,c:Timeline_Clock,lanes:[]Timeline_Lane,r:^Timeline_Result,empty:bool) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    if ui.box(ctx,{width=ui.fixed(TIMELINE_NAMES),height=ui.GROW,direction=.Column}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(TIMELINE_RULER),padding={12,0,8,0},gap=6,align_y=.Center,fill=th.well}) {
            if empty {ui.disabled_begin(ctx)}
            defer if empty {ui.disabled_end(ctx)}
            rate:=max(c.rate,1)
            value:=f64(t.seconds?c.frame/rate:math.round(c.frame))
            field:=ui.Number_Field{width=ui.fixed(56),height=th.control-4,integer=!t.seconds,decimals=2,has_min=true,has_max=true,max=f64(t.seconds?c.frames/rate:c.frames),speed=t.seconds?0.01:0.25}
            if result:=ui.number_field(ctx,ui.id(ctx,"frame"),&value,field);result.changed {
                r.seek,r.frame=true,clamp(t.seconds?f32(value)*rate:f32(value),0,c.frames)
            }
            ui.label(ctx,fmt.tprintf("/ %s",timeline_text(t,c.frames,c.rate,false)),th.font_small,th.text_faint,0)
        }
        for &lane,i in lanes {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(TIMELINE_LANE),padding={12,0,6,0},align_y=.Center}) {
                ui.label(ctx,lane.name,th.font_small,th.text_muted,0)
                ui.spacer(ctx)
                if lane.add && ui.button(ctx,ui.id(ctx,"add",i+1),{icon=.Plus,icon_color=th.text_muted,icon_size=12,tip="Add at the head",style=.Ghost,width=24,height=24,disabled=empty}).clicked {
                    r.add,r.lane,r.to=true,i,math.round(c.frame)
                }
            }
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.row_rule}) {}
        }
    }
}

// The ruler, the lanes and the bar of the view: where the time is.
@(private)
timeline_area :: proc(s:^Session,t:^Timeline,c:Timeline_Clock,lanes:[]Timeline_Lane,r:^Timeline_Result,empty:bool) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    // The ruler takes the width of the area: it measures the time for the lanes and the bar too.
    ruler:=ui.id(ctx,"ruler")
    width:=f32(400)
    origin,found:=ui.widget_rect(ctx,ruler)
    if found {width=origin.w}
    span:=max(width-2*TIMELINE_PAD,1)
    start,end:=timeline_view(t,c.frames)
    scale:=span/max(end-start,1e-3) // points per frame
    x :: proc(frame,start,scale:f32) -> f32 {return TIMELINE_PAD+(frame-start)*scale}
    at :: proc(ctx:^ui.Context,origin:ui.Rect,start,scale:f32) -> f32 {return start+(ctx.input.pointer.x-origin.x-TIMELINE_PAD)/scale}
    lanes_height:=f32(len(lanes))*(TIMELINE_LANE+1)
    rate:=max(c.rate,1)

    it:=ui.interact(ctx,ruler,empty?{.Disabled}:{})
    head:=x(c.frame,start,scale)
    range_lo,range_hi:=timeline_range(t,c.frames)
    if it.pressed {
        pointer:=ctx.input.pointer-[2]f32{origin.x,origin.y}
        switch {
        case pointer.y<20 && abs(pointer.x-head)<=15: t.drag=.Head
        case abs(pointer.x-x(range_lo,start,scale))<=TIMELINE_REACH && pointer.y>8: t.drag=.In
        case abs(pointer.x-x(range_hi,start,scale))<=TIMELINE_REACH && pointer.y>8: t.drag=.Out
        case: t.drag=.Head
        }
        if t.drag!=.Head && t.range_out<=t.range_in {t.range_in,t.range_out=0,c.frames}
    }
    if it.active {
        frame:=clamp(math.round(at(ctx,origin,start,scale)),0,c.frames)
        #partial switch t.drag {
        case .Head: r.seek,r.frame=true,frame
        case .In: t.range,t.range_in=true,min(frame,t.range_out-1)
        case .Out: t.range,t.range_out=true,max(frame,t.range_in+1)
        }
    }
    if it.released {t.drag=.None}
    if it.right {
        t.pointed=clamp(math.round(at(ctx,origin,start,scale)),0,c.frames)
        r.ruler,r.anchor=true,{ctx.input.pointer.x,ctx.input.pointer.y,1,1}
    }
    // The wheel with Ctrl zooms on the pointer.
    if it.hot && .Primary in ctx.input.modifiers && ctx.input.wheel.y!=0 && c.frames>0 {
        pivot:=at(ctx,origin,start,scale)
        frames:=clamp((end-start)*math.pow(f32(0.8),ctx.input.wheel.y),min(TIMELINE_MIN_FRAMES,c.frames),c.frames)
        t.start=pivot-(pivot-start)*frames/(end-start)
        t.end=t.start+frames
        if frames>=c.frames {t.start,t.end=0,0}
        start,end=timeline_view(t,c.frames)
        scale=span/max(end-start,1e-3)
        head=x(c.frame,start,scale)
    }

    if ui.box(ctx,{id=ui.id(ctx,"area"),width=ui.GROW,height=ui.GROW,direction=.Column,clip_x=true,clip_floats=true}) {
        if ui.box(ctx,{id=ruler,width=ui.GROW,height=ui.fixed(TIMELINE_RULER),fill=th.well,clip_x=true,clip_floats=true}) {
            if !empty {
                tick,label:=timeline_steps(scale,rate)
                first:=math.floor(start/tick)*tick
                for frame:=first;frame<=end+tick*0.5;frame+=tick {
                    if frame<0 || frame>c.frames {continue}
                    labeled:=math.mod(frame,label)==0
                    second:=math.mod(frame,rate)==0
                    height:=second?f32(14):(labeled?f32(9):f32(5))
                    color:=second?th.text_faint:(labeled?th.border:th.divider)
                    if ui.box(ctx,{width=ui.fixed(1),height=ui.fixed(height),fill=color,float={to=.Parent,offset={x(frame,start,scale),TIMELINE_RULER-height}}}) {}
                    if labeled {
                        text:=timeline_text(t,frame,c.rate,true)
                        left:=x(frame,start,scale)+3
                        if size:=ui.text_width(&ctx.font,text,th.font_caption);left+size>width {left-=size+6}
                        if ui.box(ctx,{width=ui.FIT,height=ui.fixed(14),float={to=.Parent,offset={left,3}}}) {
                            ui.label(ctx,text,th.font_caption,second?th.text_muted:th.text_faint)
                        }
                    }
                }
                bracket :: proc(ctx:^ui.Context,at:f32,left,hot:bool) {
                    color:=hot?ctx.theme.text:ctx.theme.text_muted
                    side:=left?f32(0):f32(-6)
                    if ui.box(ctx,{width=ui.fixed(2),height=ui.fixed(22),fill=color,float={to=.Parent,offset={left?at:at-2,9}}}) {}
                    for y in ([2]f32{9,29}) {if ui.box(ctx,{width=ui.fixed(6),height=ui.fixed(2),fill=color,float={to=.Parent,offset={at+side,y}}}) {}}
                }
                bracket(ctx,x(range_lo,start,scale),true,t.drag==.In)
                bracket(ctx,x(range_hi,start,scale),false,t.drag==.Out)
            }
        }
        for &lane,i in lanes {
            timeline_lane(s,t,c,&lane,i,r,origin,start,scale,empty)
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.row_rule}) {}
        }
        timeline_overview(s,t,c,span,empty)
        if !empty {
            // Outside the range, dimmed while it bounds what plays.
            shade:=ui.color_alpha(th.well,150)
            covered:=TIMELINE_RULER+lanes_height
            if t.range {
                left:=x(range_lo,start,scale)
                if left>0 {if ui.box(ctx,{width=ui.fixed(left),height=ui.fixed(covered),fill=shade,float={to=.Parent,offset={0,0}}}) {}}
                right:=x(range_hi,start,scale)
                if right<width {if ui.box(ctx,{width=ui.fixed(width-right),height=ui.fixed(covered),fill=shade,float={to=.Parent,offset={right,0}}}) {}}
            }
            fill:=it.hot || it.active?th.accent_hover:th.accent
            // A head out of the view is not drawn.
            if head>=0 && head<=width {
                if ui.box(ctx,{width=ui.fixed(2),height=ui.fixed(covered-20),fill=fill,float={to=.Parent,offset={head-1,20}}}) {}
                text:=timeline_text(t,c.frame,c.rate,false)
                if t.drag==.Head && !t.seconds {text=fmt.tprintf("%s · %.2f s",text,c.frame/rate)}
                handle:=max(ui.text_width(&ctx.font,text,th.font_caption)+12,30)
                if ui.box(ctx,{width=ui.fixed(handle),height=ui.fixed(18),align_x=.Center,align_y=.Center,fill=fill,radius=th.radius_control,float={to=.Parent,offset={head-handle*0.5,2}}}) {
                    ui.label(ctx,text,th.font_caption,th.on_accent,font=ui.FONT_SEMIBOLD)
                }
            }
        }
    }
}

// A lane: its marks, which a press chooses and a drag moves; a press away
// from them moves the head, and the right button asks for the menu.
@(private)
timeline_lane :: proc(s:^Session,t:^Timeline,c:Timeline_Clock,lane:^Timeline_Lane,index:int,r:^Timeline_Result,origin:ui.Rect,start,scale:f32,empty:bool) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    x :: proc(frame,start,scale:f32) -> f32 {return TIMELINE_PAD+(frame-start)*scale}
    id:=ui.id(ctx,"lane",index+1)
    it:=ui.interact(ctx,id,empty?{.Disabled}:{})
    pointer:=start+(ctx.input.pointer.x-origin.x-TIMELINE_PAD)/scale
    under:=-1
    for &mark,i in lane.marks {
        if abs((mark.frame-pointer)*scale)<=TIMELINE_REACH {under=i}
    }
    if it.pressed {
        if under>=0 {
            t.drag,t.mark,t.grab,t.dragged=.Mark,{index,under+1},lane.marks[under].frame-pointer,lane.marks[under].frame
        } else {
            t.drag,t.mark=.Head,{}
        }
    }
    if it.active {
        frame:=clamp(math.round(pointer),0,c.frames)
        if t.drag==.Mark && t.mark[0]==index {t.dragged=clamp(math.round(pointer+t.grab),0,c.frames)}
        if t.drag==.Head {r.seek,r.frame=true,frame}
    }
    if it.released {
        if t.drag==.Mark && t.mark[0]==index && t.mark[1]>0 && t.mark[1]<=len(lane.marks) && t.dragged!=lane.marks[t.mark[1]-1].frame {
            r.moved,r.lane,r.index,r.to=true,index,t.mark[1]-1,t.dragged
        }
        t.drag=.None
    }
    if it.right {
        r.menu,r.lane,r.index=true,index,under
        r.to=under>=0?lane.marks[under].frame:clamp(math.round(pointer),0,c.frames)
        r.anchor={ctx.input.pointer.x,ctx.input.pointer.y,1,1}
    }
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(TIMELINE_LANE),clip_x=true,clip_floats=true}) {
        for &mark,i in lane.marks {
            chosen:=t.mark=={index,i+1}
            frame:=chosen && t.drag==.Mark?t.dragged:mark.frame
            at:=x(frame,start,scale)
            if at<-6 || at>origin.w+6 {continue}
            color:=chosen?th.accent:(i==under && it.hot?th.text:th.text_muted)
            if ui.box(ctx,{width=ui.fixed(12),height=ui.fixed(12),float={to=.Parent,offset={at-6,10}}}) {ui.icon(ctx,ui.icon_user(u8(User_Icon.Marker)),color,12)}
            if mark.name!="" {
                if ui.box(ctx,{width=ui.FIT,height=ui.fixed(16),float={to=.Parent,offset={at+9,8}}}) {ui.label(ctx,mark.name,th.font_small,chosen?th.text:th.text_muted)}
            }
        }
    }
}

// The bar under the lanes: the whole duration, with what is in view as a
// thumb. Its edges zoom, its middle moves it, and a press away from it
// centers the view there.
@(private)
timeline_overview :: proc(s:^Session,t:^Timeline,c:Timeline_Clock,span:f32,empty:bool) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    id:=ui.id(ctx,"overview")
    it:=ui.interact(ctx,id,empty?{.Disabled}:{})
    rect,_:=ui.widget_rect(ctx,id)
    start,end:=timeline_view(t,c.frames)
    whole:=max(c.frames,1e-3)
    scale:=span/whole
    left,right:=TIMELINE_PAD+start*scale,TIMELINE_PAD+end*scale
    pointer:=ctx.input.pointer.x-rect.x
    frame:=(pointer-TIMELINE_PAD)/scale
    if it.pressed {
        switch {
        case abs(pointer-left)<=TIMELINE_REACH: t.drag=.View_Start
        case abs(pointer-right)<=TIMELINE_REACH: t.drag=.View_End
        case pointer>left && pointer<right: t.drag,t.grab=.View,start-frame
        case:
            t.drag,t.grab=.View,-(end-start)*0.5
        }
        t.start,t.end=start,end
    }
    if it.active {
        least:=min(TIMELINE_MIN_FRAMES,c.frames)
        #partial switch t.drag {
        case .View_Start: t.start=clamp(frame,0,t.end-least)
        case .View_End: t.end=clamp(frame,t.start+least,c.frames)
        case .View:
            frames:=t.end-t.start
            t.start=clamp(frame+t.grab,0,c.frames-frames)
            t.end=t.start+frames
        }
        start,end=timeline_view(t,c.frames)
        left,right=TIMELINE_PAD+start*scale,TIMELINE_PAD+end*scale
    }
    if it.released {
        t.drag=.None
        if t.end-t.start>=c.frames {t.start,t.end=0,0}
    }
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(TIMELINE_OVERVIEW),clip_x=true,clip_floats=true}) {
        if !empty {
            if ui.box(ctx,{width=ui.fixed(span),height=ui.fixed(4),fill=th.field,radius=2,float={to=.Parent,offset={TIMELINE_PAD,7}}}) {}
            edge:=it.hot || it.active?th.text:th.text_faint
            if ui.box(ctx,{width=ui.fixed(max(right-left,8)),height=ui.fixed(10),fill=it.hot || it.active?th.raised:th.field_hover,radius=5,float={to=.Parent,offset={left,4}}}) {}
            for side in ([2]f32{left,max(right,left+8)-2}) {if ui.box(ctx,{width=ui.fixed(2),height=ui.fixed(10),fill=edge,float={to=.Parent,offset={side,4}}}) {}}
            if ui.box(ctx,{width=ui.fixed(2),height=ui.fixed(12),fill=th.accent,float={to=.Parent,offset={TIMELINE_PAD+c.frame*scale-1,3}}}) {}
        }
    }
}

// The icons of the strip, as draw_user draws them: c is the center and s
// the size over 16.
@(private)
timeline_icon_draw :: proc(ctx:^ui.Context,icon:User_Icon,c:[2]f32,s:f32,color:ui.Color) {
    line:=1.5*s
    p :: proc(c:[2]f32,s:f32,v:[2]f32) -> [2]f32 {return c+(v-8)*s}
    #partial switch icon {
    case .To_Start:
        ui.draw_line(ctx,p(c,s,{4,3.5}),p(c,s,{4,12.5}),line,color)
        ui.draw_triangle(ctx,p(c,s,{12.5,3.5}),p(c,s,{6.5,8}),p(c,s,{12.5,12.5}),color)
    case .To_End:
        ui.draw_line(ctx,p(c,s,{12,3.5}),p(c,s,{12,12.5}),line,color)
        ui.draw_triangle(ctx,p(c,s,{3.5,3.5}),p(c,s,{9.5,8}),p(c,s,{3.5,12.5}),color)
    case .Step_Back:
        ui.draw_line(ctx,p(c,s,{5,4}),p(c,s,{5,12}),line,color)
        chevron:=[3][2]f32{p(c,s,{11.5,4}),p(c,s,{7.5,8}),p(c,s,{11.5,12})}
        ui.draw_polyline(ctx,chevron[:],line,color)
    case .Step_Forward:
        ui.draw_line(ctx,p(c,s,{11,4}),p(c,s,{11,12}),line,color)
        chevron:=[3][2]f32{p(c,s,{4.5,4}),p(c,s,{8.5,8}),p(c,s,{4.5,12})}
        ui.draw_polyline(ctx,chevron[:],line,color)
    case .Loop:
        top:=[5][2]f32{p(c,s,{2.5,7.5}),p(c,s,{2.8,6}),p(c,s,{3.8,5}),p(c,s,{5,4.5}),p(c,s,{13,4.5})}
        ui.draw_polyline(ctx,top[:],line,color)
        ui.draw_polyline(ctx,([][2]f32{p(c,s,{11,2.5}),p(c,s,{13,4.5}),p(c,s,{11,6.5})}),line,color)
        bottom:=[5][2]f32{p(c,s,{13.5,8.5}),p(c,s,{13.2,10}),p(c,s,{12.2,11}),p(c,s,{11,11.5}),p(c,s,{3,11.5})}
        ui.draw_polyline(ctx,bottom[:],line,color)
        ui.draw_polyline(ctx,([][2]f32{p(c,s,{5,13.5}),p(c,s,{3,11.5}),p(c,s,{5,9.5})}),line,color)
    case .Range:
        ui.draw_polyline(ctx,([][2]f32{p(c,s,{5.5,3}),p(c,s,{3,3}),p(c,s,{3,13}),p(c,s,{5.5,13})}),line,color)
        ui.draw_polyline(ctx,([][2]f32{p(c,s,{10.5,3}),p(c,s,{13,3}),p(c,s,{13,13}),p(c,s,{10.5,13})}),line,color)
    case .Fit_Width:
        for corner in ([4][3][2]f32{{{2.5,6},{2.5,2.5},{6,2.5}},{{10,2.5},{13.5,2.5},{13.5,6}},{{13.5,10},{13.5,13.5},{10,13.5}},{{6,13.5},{2.5,13.5},{2.5,10}}}) {
            points:=[3][2]f32{p(c,s,corner[0]),p(c,s,corner[1]),p(c,s,corner[2])}
            ui.draw_polyline(ctx,points[:],line,color)
        }
    case .Marker:
        ui.draw_triangle(ctx,p(c,s,{8,2}),p(c,s,{14,8}),p(c,s,{8,14}),color)
        ui.draw_triangle(ctx,p(c,s,{8,2}),p(c,s,{8,14}),p(c,s,{2,8}),color)
    }
}
