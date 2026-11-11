package ui

import "core:math"
import "core:strconv"
import "core:strings"
import "mirai:std/serial"

// What game interfaces add to the widgets of the editor: images, text with a
// style of its own, elements placed from the edges of the screen and the
// controls only a game has. A button, a checkbox, a slider, a number and a
// dropdown are those of the editor (button, checkbox, slider, number_field,
// dropdown) with a look: the Node_Style resolved for the state they are in.

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

// An area Context.draw_user draws as node says: the layout places it, the
// container that clips it cuts what it draws, and the pointer on it is its
// interaction.
canvas :: proc(ctx:^Context,id:Id,width,height:Size,node:Draw_Node,flags:Widget_Flags={}) -> Interaction {
    it:=interact(ctx,id,flags)
    element_leaf(ctx,{id=id,layout={width=width,height=height},custom=paint_add(ctx,{kind=.Draw,draw=node})})
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

// The images or flat colors of a button per state, with its text and its size.
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

// What a skin gives a button in the state the widget id is in: its look and
// the image that goes behind it.
skin_look :: proc(ctx:^Context,id:Id,skin:Skin,disabled:bool=false) -> (look:Node_Style,image:Node_Image) {
    states:=widget_states(ctx,id,false,disabled)
    state:=skin.normal
    switch {
    case .Disabled in states: if skin.disabled!={} {state=skin.disabled}
    case .Pressed in states && skin.pressed!={}: state=skin.pressed
    case states&{.Hovered,.Focused}!={} && skin.hovered!={}: state=skin.hovered
    }
    look.fill,look.radius,look.text=state.tint,skin.radius,skin.text
    if state.text_color!={} {look.text.color=state.text_color}
    image={quad=state.quad,border=skin.border,border_uv=skin.border_uv}
    return
}

// The states a widget is in before it is built this frame, which a look is
// resolved for: pressed from the press it is about to take. Focused is the
// focus of navigation, with its ring: a click that gives the focus is not it.
widget_states :: proc(ctx:^Context,id:Id,selected:=false,disabled:=false) -> Style_States {
    if id==0 {return style_states({},selected,disabled || ctx.disabled_depth>0)}
    hot:=ctx.hot==id
    active:=ctx.active==id || hot && ctx.active==0 && .Left in ctx.input.pressed && !ctx.press_used
    return style_states({hot=hot,focused=ctx.focus==id && ctx.focus_ring,active=active},selected,disabled || ctx.disabled_depth>0)
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
control_em :: proc(ctx:^Context,style:^Node_Style) -> f32 {
    return style.text.size if style.text.size>0 else ctx.theme.font
}
// What the layout says, or sizes sizes of its text wide by a line with its room.
@(private)
control_size :: proc(ctx:^Context,width,height:Size,style:^Node_Style,sizes:f32) -> (w,h:Size,line:f32) {
    em:=control_em(ctx,style)
    line=em*TEXT_LINE+2*em*GAME_PAD
    w=width if width!={} else fixed(em*sizes)
    h=height if height!={} else fixed(line)
    return
}
// The height a control has: as it was laid out last frame, or as it asks.
@(private)
control_height :: proc(ctx:^Context,id:Id,height:Size,line:f32) -> f32 {
    if r,found:=widget_rect(ctx,id);found && r.h>0 {return r.h}
    return height.value if height.kind==.Fixed else line
}
// -1 or 1 as left or right step a control that has the focus, where the keys reach it.
@(private)
control_step :: proc(ctx:^Context,focused:bool) -> (step:int) {
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
control_arrow :: proc(ctx:^Context,id:Id,direction:int,side,em:f32,color:Color,disabled:bool) -> bool {
    it:=interact(ctx,id,{.Disabled} if disabled else {})
    element_leaf(ctx,{id=id,layout={width=fixed(side),height=GROW},custom=paint_add(ctx,{kind=.Arrow,fill=color,size=em*GAME_ARROW,value=f32(direction)})})
    return it.clicked
}

// The side of a radio: as laid out, or a line of its text.
@(private)
game_side :: proc(ctx:^Context,id:Id,c:Game_Control,style:^Node_Style) -> (w,h:Size,side:f32) {
    line:=control_em(ctx,style)*TEXT_LINE
    w=c.width if c.width!={} else fixed(line)
    h=c.height if c.height!={} else fixed(line)
    side=control_height(ctx,id,h,line)
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
    next:=current^+control_step(ctx,it.focused)
    width,height,line:=control_size(ctx,c.width,c.height,style,GAME_WIDTH)
    side:=control_height(ctx,id,height,line)
    em:=control_em(ctx,style)
    text_style:=style.text
    text_style.align_x,text_style.align_y=.Center,.Center
    if element_open(ctx,{id=id,layout={width=width,height=height,direction=.Row,align_y=.Center},custom=paint_add(ctx,game_background(style))}) {
        if control_arrow(ctx,id_derive(ctx,id,"previous"),0,side,em,style.mark,disabled) {next-=1}
        shown:=option(options,current^) if count>0 && current^>=0 else ""
        text(ctx,shown,text_style,GROW,GROW)
        if control_arrow(ctx,id_derive(ctx,id,"next"),1,side,em,style.mark,disabled) {next+=1}
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
    width,_,_:=control_size(ctx,f.width,f.height,style,GAME_WIDTH)
    em:=control_em(ctx,style)
    return text_field(ctx,id,buffer,length,{style=style,padding=em*GAME_PAD,width=width,height=f.height.value if f.height.kind==.Fixed else 0,
        placeholder=f.placeholder,limit=f.limit,multiline=f.multiline,rows=3 if f.multiline else 1,password=f.password,disabled=f.disabled})
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
// The options in order, each read once, a joined text included: `walk:=options_walk(o)`,
// then `for text,index in option_next(&walk)`.
@(private)
Options_Walk :: struct {options:Options,count,index:int,rest:string}
@(private)
options_walk :: proc(o:Options) -> Options_Walk {return {options=o,count=options_count(o),rest=o.joined}}
@(private)
option_next :: proc(w:^Options_Walk) -> (text:string,index:int,ok:bool) {
    if w.index>=w.count {return}
    index,ok=w.index,true
    w.index+=1
    if w.options.list!=nil || w.options.array!=nil {return option(w.options,index),index,true}
    bar:=strings.index_byte(w.rest,'|')
    text=w.rest if bar<0 else w.rest[:bar]
    w.rest=w.rest[bar+1:] if bar>=0 else ""
    if equal:=strings.index_byte(text,'=');equal>=0 {text=strings.trim_space(text[:equal])}
    return
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
