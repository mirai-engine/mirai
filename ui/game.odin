package ui

import "core:math"
import "core:strconv"
import "core:strings"
import "mirai:std/serial"

// What game interfaces add to the widgets of the editor: images, text with a
// style of its own, elements placed from the edges of the screen and the
// controls of a game, which take every color and corner from a Node_Style.

// The scale that fits a layout designed for `reference` into `size`, keeping
// its proportions: pass it in Input.scale.
scale_to_fit :: proc "contextless" (size,reference:[2]f32) -> f32 {
    if reference.x<=0 || reference.y<=0 {return 1}
    return max(min(size.x/reference.x,size.y/reference.y),0.01)
}

Image :: struct {
    id:Id,
    quad:Quad,
    tint:Color,          // white when transparent
    width,height:Size,
    border:[4]f32,       // nine slice when any is set: left, top, right, bottom in layout units
    border_uv:[4]f32,    // the same borders as a fraction of the image
    fit:Image_Fit,       // how it takes its rectangle, keeping size
    size:[2]f32,         // of the part shown, in texels; zero: unknown, it stretches
}
@(private)
image_paint :: proc(i:Image) -> Paint {
    tint:=i.tint if i.tint!={} else Color{255,255,255,255}
    if i.border!={} {return {kind=.Nine_Slice,quad=i.quad,fill=tint,border=i.border,border_uv=i.border_uv}}
    return {kind=.Image,quad=i.quad,fill=tint,fit=i.fit,image_size=i.size}
}

// The frame of a sheet of sprites an image shows: its columns by rows count
// left to right, then down, and wrap. One without frames is itself.
image_frame :: proc "contextless" (image:Node_Image,frame:f32) -> Node_Image {
    columns,rows:=max(int(image.frames[0]),1),max(int(image.frames[1]),1)
    if columns*rows==1 {return image}
    out:=image
    count:=columns*rows
    at:=(int(math.floor(frame))%count+count)%count
    uv:=image.quad.uv
    w,h:=uv.w/f32(columns),uv.h/f32(rows)
    out.quad.uv={uv.x+f32(at%columns)*w,uv.y+f32(at/columns)*h,w,h}
    out.size=image.size/{f32(columns),f32(rows)}
    out.frames={1,1}
    return out
}
// A part of a texture, tinted. With an id its rectangle is kept for widget_rect,
// as that of a progress bar or a text.
image :: proc(ctx:^Context,i:Image) {
    widget_add(ctx,i.id,{.Passive})
    element_leaf(ctx,{id=i.id,layout={width=i.width,height=i.height},custom=paint_add(ctx,image_paint(i))})
}

// An area its owner draws with Context_Desc.draw_user (kind, data): the layout
// places it, the container that clips it cuts what it draws, and the pointer
// on it is its interaction.
canvas :: proc(ctx:^Context,id:Id,width,height:Size,kind:u32,data:u64,flags:Widget_Flags={}) -> Interaction {
    it:=interact(ctx,id,flags)
    element_leaf(ctx,{id=id,layout={width=width,height=height},custom=paint_add(ctx,{kind=.User,user_kind=kind,user_data=data})})
    return it
}

Progress :: struct {
    id:Id,
    value:f32,           // 0 to 1
    width,height:Size,
    fill,track,stroke:Color,
    radius:f32,
    corners:[4]f32,      // of each corner instead of radius when any is set
    fill_mode:Progress_Fill,
    stroke_width:f32,    // of a Radial: the width of its ring; 0: a disc
    quad,quad_track:Quad, // images for the bar and its track, tinted by fill and track
    border:[4]f32,
    border_uv:[4]f32,
    program:u32,          // a ui program that colors the bar without an image, given fill: see draw_program
    program_values:[4]f32,
}
// A bar filled up to value.
progress :: proc(ctx:^Context,p:Progress) {
    white:=Color{255,255,255,255}
    paint:=Paint{kind=.Progress,value=p.value,fill=p.fill,fill2=p.track,stroke=p.stroke,radius=p.radius,corners=p.corners,quad=p.quad,quad2=p.quad_track,border=p.border,border_uv=p.border_uv,
        fill_mode=p.fill_mode,stroke_width=p.stroke_width,program=p.program,program_values=p.program_values}
    if p.quad.kind!=.Solid && p.fill=={} {paint.fill=white}
    if p.quad_track.kind!=.Solid && p.track=={} {paint.fill2=white}
    widget_add(ctx,p.id,{.Passive})
    element_leaf(ctx,{id=p.id,layout={width=p.width,height=p.height},custom=paint_add(ctx,paint)})
}

// Text with a style of its own inside a box of width by height. A FIT width
// is the width of the text on one line; a FIT height holds the lines the
// text takes when wrapped to a fixed width. reveal: the part of its
// characters drawn, 0 to 1, each where the whole text puts it (a typewriter).
text :: proc(ctx:^Context,content:string,style:Text_Style,width:Size=FIT,height:Size=FIT,id:Id=0,reveal:f32=1) {
    w,h:=width,height
    font:=&ctx.font
    f:=int(style.font)
    line_height:=style.size*(style.line_height if style.line_height>0 else TEXT_LINE)
    if w.kind==.Fit {w=fixed(text_width(font,content,style.size,f)+1)}
    if h.kind==.Fit {
        lines:=1
        if w.kind==.Fixed {lines=text_line_count(font,content,style.size,w.value,style.wrap,f)} else {
            for c in content {if c=='\n' {lines+=1}}
        }
        h=fixed(f32(lines)*line_height+2)
    }
    paint:=paint_add(ctx,{kind=.Text_Block,text=content,style=style,revealed=text_revealed(content,reveal)})
    widget_add(ctx,id,{.Passive})
    element_leaf(ctx,{id=id,layout={width=w,height=h},custom=paint})
}

// Paint.revealed for the part reveal (0 to 1) of the characters of a text.
@(private)
text_revealed :: proc "contextless" (content:string,reveal:f32) -> i32 {
    if reveal>=1 {return 0}
    count:=0
    for _ in content {count+=1}
    return i32(math.round(f32(count)*max(reveal,0)))+1
}

// A container placed from a point of the screen instead of the flow of its
// parent: the corner of a HUD, a centered menu.
@(deferred_in=anchored_end)
anchored :: proc(ctx:^Context,id:Id,anchor:Anchor,offset:[2]f32={},layout:Layout={},layer:i16=0,safe:bool=true) -> bool {
    box_begin(ctx,{id=id,layout=layout,float={to=.Safe if safe else .Surface,anchor=anchor,pivot=anchor,offset=offset,layer=layer}})
    return true
}
@(private)
anchored_end :: proc(ctx:^Context,id:Id,anchor:Anchor,offset:[2]f32,layout:Layout,layer:i16,safe:bool) {
    box_end(ctx,{id=id,float={to=.Surface}})
}

Skin :: struct {
    normal,hovered,pressed,disabled:Image_State,
    text:Text_Style,
    width,height:Size,
    padding:[4]f32,
    border:[4]f32,
    border_uv:[4]f32,
    radius:f32,
}
// How a skinned widget looks in one state: an image, or a color when quad is none.
Image_State :: struct {quad:Quad,tint:Color,text_color:Color}

// A button drawn with images or flat colors per state and a centered label.
skin_button :: proc(ctx:^Context,id:Id,content:string,skin:Skin,disabled:bool=false) -> Interaction {
    it:=interact(ctx,id,{.Focusable}+({.Disabled} if disabled else {}))
    state:=skin.normal
    if disabled {if skin.disabled!={} {state=skin.disabled}} else if it.active && skin.pressed!={} {state=skin.pressed} else if (it.hot || it.focused&&ctx.focus_ring) && skin.hovered!={} {state=skin.hovered}
    background:Paint
    if state.quad.kind!=.Solid {
        background=image_paint({quad=state.quad,tint=state.tint,border=skin.border,border_uv=skin.border_uv})
    } else {background={kind=.Rect,fill=state.tint,radius=skin.radius}}
    style:=skin.text
    if state.text_color!={} {style.color=state.text_color}
    style.align_x=.Center;style.align_y=.Center
    width:=skin.width
    if width=={} {width=fixed(text_width(&ctx.font,content,style.size,int(style.font))+skin.padding[0]+skin.padding[2]+1)}
    height:=skin.height
    if height=={} {height=fixed(style.size*TEXT_LINE+skin.padding[1]+skin.padding[3])}
    declaration:=Element{id=id,layout={width=width,height=height},custom=paint_add(ctx,background)}
    if element_open(ctx,declaration) {
        label_paint:=paint_add(ctx,{kind=.Text_Block,text=content,style=style})
        element_leaf(ctx,{layout={width=GROW,height=GROW},custom=label_paint})
    }
    element_close(ctx)
    return it
}

// Code widgets and asset trees apply the same token and state rules.
styled_button :: proc(ctx:^Context,id:Id,content:string,base:Node_Style,rules:[]Style_Variant=nil,style:u16=0,variant:u64=0,layout:Layout={},selected:bool=false,disabled:bool=false,image_ref:Node_Image={},shown:Maybe(Style_States)=nil) -> Interaction {
    disabled:=disabled || ctx.disabled_depth>0
    it:=interact(ctx,id,{.Focusable}+({.Disabled} if disabled else {}))
    // Focused is the focus of navigation, with its ring: a click that gives the focus is not it.
    ring:=it
    ring.focused=it.focused && ctx.focus_ring
    resolved:=style_resolve(&ctx.theme,base,rules,style,variant,shown.? or_else style_states(ring,selected,disabled))
    background:=Paint{kind=.Rect,fill=resolved.fill,fill2=resolved.fill2,stroke=resolved.stroke,corners=resolved.radius,stroke_width=resolved.stroke_width,
        shadow=resolved.shadow,shadow_color=resolved.shadow_color,shadow_blur=resolved.shadow_blur,shadow_offset=resolved.shadow_offset}
    if image_ref.quad.kind!=.Solid {background=image_paint({quad=image_ref.quad,tint=resolved.fill,border=image_ref.border,border_uv=image_ref.border_uv})}
    text_style:=resolved.text
    text_style.align_x=.Center;text_style.align_y=.Center
    width,height:=layout.width,layout.height
    if width=={} {width=fixed(text_width(&ctx.font,content,text_style.size,int(text_style.font))+layout.padding[0]+layout.padding[2]+1)}
    if height=={} {height=fixed(text_style.size*TEXT_LINE+layout.padding[1]+layout.padding[3])}
    declaration:=Element{id=id,layout={width=width,height=height},custom=paint_add(ctx,background)}
    if element_open(ctx,declaration) {
        element_leaf(ctx,{layout={width=GROW,height=GROW},custom=paint_add(ctx,{kind=.Text_Block,text=content,style=text_style})})
    }
    element_close(ctx)
    return it
}

// Squares of two colors, side units wide, over width by height: what shows
// through what is transparent.
checker :: proc(ctx:^Context,width,height:Size,a,b:Color,side:f32=12,float:Float={}) {
    element_leaf(ctx,{layout={width=width,height=height},float=float,custom=paint_add(ctx,{kind=.Checker,fill=a,fill2=b,value=side})})
}

// ---------------------------------------------------------------- controls of a game

GAME_PAD :: f32(0.5)    // room inside a control of a game around its text, in sizes of that text
GAME_WIDTH :: f32(10)   // a slider, a selector, a number, a field or a dropdown without a width, in sizes of its text
GAME_ARROW :: f32(0.75) // the arrows of a selector, a number and a dropdown, in sizes of its text

// What a control of a game is drawn with and how large it is. Every color
// and corner comes from style: a part it leaves transparent is not drawn.
// Without a size, a control is a line of its text tall with GAME_PAD of
// room above and below; a checkbox and a radio, a line of text square.
Game_Control :: struct {
    style:^Node_Style, // resolved for the state of the control; nil: nothing but its text, in the size of the theme
    width,height:Size,
    disabled:bool,
}

@(private)
game_em :: proc(ctx:^Context,style:^Node_Style) -> f32 {
    return style.text.size if style.text.size>0 else ctx.theme.font
}
// What the layout says, or width sizes of its text wide by a line with its room.
@(private)
game_size :: proc(ctx:^Context,c:Game_Control,style:^Node_Style,width:f32) -> (w,h:Size,line:f32) {
    em:=game_em(ctx,style)
    line=em*TEXT_LINE+2*em*GAME_PAD
    w=c.width if c.width!={} else fixed(em*width)
    h=c.height if c.height!={} else fixed(line)
    return
}
// The height a control has: as it was laid out last frame, or as it asks.
@(private)
game_height :: proc(ctx:^Context,id:Id,height:Size,line:f32) -> f32 {
    if r,found:=widget_rect(ctx,id);found && r.h>0 {return r.h}
    return height.value if height.kind==.Fixed else line
}
// -1 or 1 as left or right step a control that has the focus, where the keys reach it.
@(private)
game_step :: proc(ctx:^Context,focused:bool) -> (step:int) {
    if !focused || ctx.unfocusable>0 {return}
    in_:=&ctx.input
    if .Left in in_.keys_repeated || .Left in in_.pad {step-=1}
    if .Right in in_.keys_repeated || .Right in in_.pad {step+=1}
    return
}
@(private)
game_background :: proc(style:^Node_Style) -> Paint {
    return {kind=.Rect,fill=style.fill,fill2=style.fill2,stroke=style.stroke,stroke_width=style.stroke_width,corners=style.radius,
        shadow=style.shadow,shadow_color=style.shadow_color,shadow_blur=style.shadow_blur,shadow_offset=style.shadow_offset}
}
// An arrow of a control: as wide as the control is tall, it steps the control when clicked.
@(private)
game_arrow :: proc(ctx:^Context,id:Id,direction:int,side,em:f32,color:Color,disabled:bool) -> bool {
    it:=interact(ctx,id,{.Disabled} if disabled else {})
    element_leaf(ctx,{id=id,layout={width=fixed(side),height=GROW},custom=paint_add(ctx,{kind=.Arrow,fill=color,size=em*GAME_ARROW,value=f32(direction)})})
    return it.clicked
}

// A slider of a game: its track (track), the part of it up to the value
// (mark) and a knob (knob) as tall as the slider, over a track a third of
// that. The pointer drags it and left and right step it while it has the
// focus; the value changes only then. range: least, most and step (0: any).
game_slider :: proc(ctx:^Context,id:Id,value:^f64,range:[3]f64,c:Game_Control={}) -> (changed:bool) {
    none:Node_Style
    style:=c.style if c.style!=nil else &none
    lo,hi,step:=range[0],range[1],range[2]
    if hi<=lo {hi=lo+1}
    disabled:=c.disabled || ctx.disabled_depth>0
    it:=interact(ctx,id,{.Focusable,.Adjusts}+({.Disabled} if disabled else {}))
    width,height,line:=game_size(ctx,c,style,GAME_WIDTH)
    knob:=game_height(ctx,id,height,line)
    next:=value^
    moved:=it.active
    if it.active {
        if r,found:=widget_rect(ctx,id);found && r.w>knob {next=lo+f64(clamp((ctx.pointer.x-r.x-knob*0.5)/(r.w-knob),0,1))*(hi-lo)}
    }
    if s:=game_step(ctx,it.focused);s!=0 {
        next+=f64(s)*(step if step>0 else (hi-lo)/20)
        moved=true
    }
    if moved {
        if step>0 {next=lo+math.round((next-lo)/step)*step}
        next=clamp(next,lo,hi)
        if next!=value^ {value^,changed=next,true}
    }
    paint:=Paint{kind=.Slider,value=f32(clamp((value^-lo)/(hi-lo),0,1)),fill=style.track,fill2=style.mark,stroke=style.knob,radius=knob*0.5,stroke_width=knob/3,corners=style.radius}
    element_leaf(ctx,{id=id,layout={width=width,height=height},custom=paint_add(ctx,paint)})
    return
}

// The side of a checkbox or a radio: as laid out, or a line of its text.
@(private)
game_side :: proc(ctx:^Context,id:Id,c:Game_Control,style:^Node_Style) -> (w,h:Size,side:f32) {
    line:=game_em(ctx,style)*TEXT_LINE
    w=c.width if c.width!={} else fixed(line)
    h=c.height if c.height!={} else fixed(line)
    side=game_height(ctx,id,h,line)
    return
}

// A checkbox of a game: a box of fill, stroke and corners with a tick of
// mark three quarters of its side while value is true. A click flips it.
game_checkbox :: proc(ctx:^Context,id:Id,value:^bool,c:Game_Control={}) -> (changed:bool) {
    none:Node_Style
    style:=c.style if c.style!=nil else &none
    disabled:=c.disabled || ctx.disabled_depth>0
    it:=interact(ctx,id,{.Focusable}+({.Disabled} if disabled else {}))
    if it.clicked {value^=!value^;changed=true}
    w,h,side:=game_side(ctx,id,c,style)
    paint:=paint_add(ctx,{kind=.Box,fill=style.fill,stroke=style.stroke,stroke_width=style.stroke_width,corners=style.radius,center=true,
        icon=.Check if value^ else .None,icon_color=style.mark,icon_size=side*0.75})
    element_leaf(ctx,{id=id,layout={width=w,height=h},custom=paint})
    return
}

// A radio of a game: a ring of fill and stroke, round unless its corners say
// otherwise, with a dot of mark half its side while it is the one chosen.
// Returns whether it was clicked.
game_radio :: proc(ctx:^Context,id:Id,chosen:bool,c:Game_Control={}) -> bool {
    none:Node_Style
    style:=c.style if c.style!=nil else &none
    disabled:=c.disabled || ctx.disabled_depth>0
    it:=interact(ctx,id,{.Focusable}+({.Disabled} if disabled else {}))
    w,h,side:=game_side(ctx,id,c,style)
    corners:=style.radius if style.radius!={} else [4]f32{side,side,side,side}*0.5
    if element_open(ctx,{id=id,layout={width=w,height=h,align_x=.Center,align_y=.Center},
        custom=paint_add(ctx,{kind=.Rect,fill=style.fill,stroke=style.stroke,stroke_width=style.stroke_width,corners=corners})}) {
        if chosen {element_leaf(ctx,{layout={width=fixed(side*0.5),height=fixed(side*0.5)},custom=paint_add(ctx,{kind=.Rect,fill=style.mark,corners=corners*0.5})})}
    }
    element_close(ctx)
    return it.clicked
}

// A selector of a game: the option chosen between two arrows of mark, which
// step through the options as left and right do while it has the focus, and
// Enter steps forward; they wrap.
game_selector :: proc(ctx:^Context,id:Id,options:Options,current:^int,c:Game_Control={}) -> (changed:bool) {
    none:Node_Style
    style:=c.style if c.style!=nil else &none
    count:=options_count(options)
    disabled:=c.disabled || ctx.disabled_depth>0
    it:=interact(ctx,id,{.Focusable,.Adjusts}+({.Disabled} if disabled else {}))
    next:=current^+game_step(ctx,it.focused)
    width,height,line:=game_size(ctx,c,style,GAME_WIDTH)
    side:=game_height(ctx,id,height,line)
    em:=game_em(ctx,style)
    text_style:=style.text
    text_style.align_x,text_style.align_y=.Center,.Center
    if element_open(ctx,{id=id,layout={width=width,height=height,direction=.Row,align_y=.Center},custom=paint_add(ctx,game_background(style))}) {
        if game_arrow(ctx,id_derive(ctx,id,"previous"),0,side,em,style.mark,disabled) {next-=1}
        shown:=option(options,current^) if count>0 && current^>=0 else ""
        element_leaf(ctx,{layout={width=GROW,height=GROW},custom=paint_add(ctx,{kind=.Text_Block,text=shown,style=text_style})})
        if game_arrow(ctx,id_derive(ctx,id,"next"),1,side,em,style.mark,disabled) {next+=1}
    }
    element_close(ctx)
    if it.clicked && ctx.activate==id {next+=1}
    if count==0 || next==current^ {return}
    if current^<0 && next<current^ {next=count-1} // on none of the options: left takes the last
    next=(next%count+count)%count
    if next!=current^ {current^,changed=next,true}
    return
}

// The decimals a number shows for its step: those of the step, or 3 without one.
@(private)
number_decimals :: proc "contextless" (step:f64) -> int {
    if step<=0 {return 3}
    scaled:=step
    for decimals in 0..<6 {
        if abs(scaled-math.round(scaled))<1e-6*max(abs(scaled),1) {return decimals}
        scaled*=10
    }
    return 6
}

// A number of a game: a field of its style between two arrows of mark that
// step it, as left and right do while it has the focus; a click on its text,
// or Enter, types it. range: least, most and step; with most not over least
// it has no limits, and without a step the arrows move it by one.
game_number :: proc(ctx:^Context,id:Id,value:^f64,range:[3]f64,c:Game_Control={}) -> (changed:bool) {
    none:Node_Style
    style:=c.style if c.style!=nil else &none
    lo,hi,step:=range[0],range[1],range[2]
    em:=game_em(ctx,style)
    width,height,line:=game_size(ctx,c,style,GAME_WIDTH)
    side:=game_height(ctx,id,height,line)
    disabled:=c.disabled || ctx.disabled_depth>0
    scratch,text:[64]u8
    length:=copy(text[:],number_format(scratch[:],value^,number_decimals(step)))
    by:=step if step>0 else 1
    next:=value^
    result:=text_field(ctx,id,text[:],&length,{style=style,padding=side,filter=.Number,adjusts=true,open=true,width=width,height=height.value if height.kind==.Fixed else line,disabled=disabled})
    if result.open {
        if game_arrow(ctx,id_derive(ctx,id,"previous"),0,side,em,style.mark,disabled) {next-=by}
        element_leaf(ctx,{layout={width=GROW,height=GROW}})
        if game_arrow(ctx,id_derive(ctx,id,"next"),1,side,em,style.mark,disabled) {next+=by}
    }
    element_close(ctx)
    if !disabled && ctx.edit.id!=id {next+=f64(game_step(ctx,ctx.focus==id))*by}
    if result.changed {
        if typed,ok:=strconv.parse_f64(string(text[:length]));ok {next=typed}
    }
    if next==value^ {return}
    if step>0 {next=(lo if hi>lo else 0)+math.round((next-(lo if hi>lo else 0))/step)*step}
    if hi>lo {next=clamp(next,lo,hi)}
    if next!=value^ {value^,changed=next,true}
    return
}

// A field of a game.
Game_Field :: struct {
    using control:Game_Control,
    placeholder:string, // shown while it is empty
    limit:int,          // bytes it takes; 0: as many as the buffer holds
    multiline:bool,     // its text keeps line breaks and wraps; three lines tall without a height
    password:bool,      // shows a mark for each character
}
// A text field of a game, typed as an ASCII keyboard types: a field of its
// style whose first click places the caret. Enter applies it; in a multiline
// field Shift+Enter adds a line.
game_field :: proc(ctx:^Context,id:Id,buffer:[]u8,length:^int,f:Game_Field={}) -> Text_Result {
    none:Node_Style
    style:=f.style if f.style!=nil else &none
    width,_,_:=game_size(ctx,f.control,style,GAME_WIDTH)
    em:=game_em(ctx,style)
    return text_field(ctx,id,buffer,length,{style=style,padding=em*GAME_PAD,width=width,height=f.height.value if f.height.kind==.Fixed else 0,
        placeholder=f.placeholder,limit=f.limit,multiline=f.multiline,rows=3 if f.multiline else 1,password=f.password,disabled=f.disabled})
}

// A dropdown of a game: the option chosen and an arrow of mark in a box of
// its style. A click or Enter opens the list of the options under it, in a
// box of the same fill, stroke and corners, where the row under the pointer
// or the focus takes track and the chosen one is written in mark. Opened by
// the keys, the focus goes to the chosen row.
game_dropdown :: proc(ctx:^Context,id:Id,options:Options,selected:^int,c:Game_Control={}) -> (changed:bool) {
    none:Node_Style
    style:=c.style if c.style!=nil else &none
    count:=options_count(options)
    disabled:=c.disabled || ctx.disabled_depth>0
    list:=id_derive(ctx,id,"list")
    it:=interact(ctx,id,{.Focusable}+({.Disabled} if disabled else {}))
    em:=game_em(ctx,style)
    pad:=em*GAME_PAD
    width,height,line:=game_size(ctx,c,style,GAME_WIDTH)
    text_style:=style.text
    text_style.align_y=.Center
    if element_open(ctx,{id=id,layout={width=width,height=height,direction=.Row,align_y=.Center,padding={pad,0,0,0}},custom=paint_add(ctx,game_background(style))}) {
        shown:=option(options,selected^) if selected^>=0 && selected^<count else ""
        element_leaf(ctx,{layout={width=GROW,height=GROW},custom=paint_add(ctx,{kind=.Text_Block,text=shown,style=text_style})})
        element_leaf(ctx,{layout={width=fixed(line),height=GROW},custom=paint_add(ctx,{kind=.Arrow,fill=style.mark,size=em*GAME_ARROW,value=3})})
    }
    element_close(ctx)
    if it.clicked && !popup_is_open(ctx,list) {
        anchor,_:=widget_rect(ctx,id)
        popup_open(ctx,list,anchor)
        if ctx.activate==id {ctx.focus,ctx.focus_ring=id_derive(ctx,list,"row",max(selected^,0)+1),true}
    }
    entry:=popup_find(ctx,list)
    if entry==nil {return}
    choice:=-1
    if popup(ctx,list,{min_width=entry.anchor.w,padding=pad*0.5,style=style}) {
        offset:=[2]f32{0,entry.scroll}
        defer entry.scroll=offset.y
        if scroll_area(ctx,id_derive(ctx,list,"rows"),&offset,{width=GROW,height=FIT,max_height=surface_size(ctx).y*0.5}) {
            for i in 0..<count {
                row:=id_derive(ctx,list,"row",i+1)
                row_it:=interact(ctx,row,{.Focusable})
                lit:=row_it.hot || row_it.focused && ctx.focus_ring
                row_style:=text_style
                if i==selected^ && style.mark[3]>0 {row_style.color=style.mark}
                if element_open(ctx,{id=row,layout={width=GROW,height=fixed(line),padding={pad,0,pad,0}},custom=paint_add(ctx,{kind=.Rect,fill=style.track if lit else {},corners=style.radius})}) {
                    element_leaf(ctx,{layout={width=GROW,height=GROW},custom=paint_add(ctx,{kind=.Text_Block,text=option(options,i),style=row_style})})
                }
                element_close(ctx)
                if row_it.clicked {choice=i}
            }
        }
    }
    if choice>=0 {
        popup_close(ctx,list)
        ctx.focus=id
        if choice!=selected^ {selected^,changed=choice,true}
    }
    return
}

// The options of a selector or a dropdown: given one by one (list), as a
// text that separates them with '|' (joined), or as the elements of an array:
// count texts of stride bytes that end at a zero or at their room, without
// the empty ones at its end, or count enums of size bytes shown by the names
// of their values, which joined shows otherwise when it maps them
// ("Sword=Espada|Bow=Arco").
Options :: struct {
    list:[]string,
    joined:string,
    array:rawptr,
    count,stride:int,
    size:int,              // of each enum; 0: the elements are texts
    names:[]serial.Choice, // of the values of the enum
}
options_count :: proc(o:Options) -> int {
    switch {
    case o.list!=nil:return len(o.list)
    case o.array!=nil:
        if o.size>0 {return o.count}
        for i:=o.count-1;i>=0;i-=1 {if ([^]u8)(o.array)[i*o.stride]!=0 {return i+1}}
        return 0
    case o.joined!="":return strings.count(o.joined,"|")+1
    }
    return 0
}
// The option at index; empty outside them.
option :: proc(o:Options,index:int) -> string {
    if index<0 {return ""}
    switch {
    case o.list!=nil:return o.list[index] if index<len(o.list) else ""
    case o.array!=nil:
        if index>=o.count {return ""}
        at:=rawptr(uintptr(o.array)+uintptr(index*o.stride))
        if o.size==0 {
            bytes:=([^]u8)(at)[:o.stride]
            n:=0
            for n<len(bytes) && bytes[n]!=0 {n+=1}
            return string(bytes[:n])
        }
        value:i64
        switch o.size {
        case 1:value=i64((cast(^i8)at)^)
        case 2:value=i64((cast(^i16)at)^)
        case 4:value=i64((cast(^i32)at)^)
        case 8:value=(cast(^i64)at)^
        }
        for choice in o.names {if choice.value==value {return option_shown(o.joined,choice.name)}}
        return ""
    }
    rest:=o.joined
    for i:=0;;i+=1 {
        bar:=strings.index_byte(rest,'|')
        if i==index {
            entry:=rest if bar<0 else rest[:bar]
            if equal:=strings.index_byte(entry,'=');equal>=0 {return strings.trim_space(entry[:equal])}
            return entry
        }
        if bar<0 {return ""}
        rest=rest[bar+1:]
    }
}
// The value of the option at index of a text "Label=Value|...": empty without one.
option_value :: proc(text:string,index:int) -> string {
    rest:=text
    for i:=0;;i+=1 {
        bar:=strings.index_byte(rest,'|')
        entry:=rest if bar<0 else rest[:bar]
        if i==index {
            equal:=strings.index_byte(entry,'=')
            return strings.trim_space(entry[equal+1:]) if equal>=0 else ""
        }
        if bar<0 {return ""}
        rest=rest[bar+1:]
    }
}
// What a map "Name=Shown|..." shows for name: its text, or name when it has none.
option_shown :: proc(mapping,name:string) -> string {
    rest:=mapping
    for rest!="" {
        bar:=strings.index_byte(rest,'|')
        entry:=rest if bar<0 else rest[:bar]
        if equal:=strings.index_byte(entry,'=');equal>=0 && entry[:equal]==name {return entry[equal+1:]}
        if bar<0 {break}
        rest=rest[bar+1:]
    }
    return name
}
