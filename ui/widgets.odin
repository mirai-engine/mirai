package ui

import "core:math"
import "core:strings"

// The controls of the editor and of a game, with the look of the sheet of the
// context when they are given none. Each one is a procedure that reads the
// state it is given, declares its element and reports what the pointer or the
// keyboard did to it this frame.

// What a disabled control draws a color with: 40 % of its opacity.
color_faded :: proc "contextless" (c:Color) -> Color {return {c[0],c[1],c[2],u8(f32(c[3])*0.4)}}

// The tint of the item of a menu or list the pointer is on.
color_hover :: proc "contextless" (ctx:^Context) -> Color {return color_alpha(tone(ctx,"text"),9)}

// ---------------------------------------------------------------- text and icons

// A single line of text that is clipped to its box instead of overflowing.
// width: negative fits the text, 0 grows, positive is fixed. fade: a text that
// does not fit fades out at its end.
label :: proc(ctx:^Context,content:string,size:f32=0,color:Color={},width:f32=-1,center:bool=false,font:u8=0,fade:=false) {
    size:=size if size>0 else metric(ctx,"font")
    if !text_begin(ctx,{font=font,size=size,color=color if color!={} else tone(ctx,"text"),align_x=.Center if center else .Start,align_y=.Center}) {return}
    text_span(ctx,content)
    text_end(ctx,{width=FIT if width<0 else GROW if width==0 else fixed(width),height=fixed(size+6)},fade=fade)
}

icon :: proc(ctx:^Context,icon:Icon,color:Color,size:f32=16) {
    paint:=paint_add(ctx,{kind=.Icon,icon=icon,icon_color=color,icon_size=size})
    element_leaf(ctx,{layout={width=fixed(size),height=fixed(size)},custom=paint})
}

// ---------------------------------------------------------------- buttons

Button :: struct {
    label:string,
    detail:string,    // right aligned: a shortcut, a count
    tip:string,       // tooltip
    icon:Icon,
    icon_color:Color, // the color of the text when transparent
    variant:string,   // of the style button of the sheet: ghost when empty
    active:bool,      // the state Selected of its style: a tab shown, a menu open
    disabled:bool,    // shown, but does nothing
    width:f32,        // 0: fit the content, negative: grow
    height:f32,       // the row of the sheet when 0
    size:f32,         // text size; that of its look, or the font of the sheet, when 0
    center:bool,
    quad:Quad,        // preview or thumbnail before the label
    icon_size:f32,    // 16 when 0
    icon_after:bool,  // the icon follows the label: a menu that opens below
    padding:f32,      // 0: automatic, negative: no inset
    // What it is drawn with, resolved for the state it is in: fill, stroke,
    // corners, shadow and text. nil: the style button of the sheet, in its variant.
    look:^Node_Style,
    // Its size and padding as an element says them, instead of width, height
    // and padding: without a size it fits its label.
    layout:^Layout,
    image:Node_Image, // behind it instead of its fill, which tints it
    block:bool,       // the label takes the lines, the outline and the shadow of the text of its look, centered
}

// A clickable box with an optional icon, preview, label and right aligned
// detail: every button of the editor and of a game. Disabled, the pointer goes
// through it unless it has a tooltip to show.
button :: proc(ctx:^Context,id:Id,b:Button) -> Interaction {
    b:=b
    b.disabled|=ctx.disabled_depth>0
    it:=interact(ctx,id,{.Focusable} if !b.disabled else ({.Block} if b.tip!="" else {.Passive}))
    if b.disabled {it={hot=ctx.hot==id && id!=0}}
    if it.hot && b.tip!="" {tooltip(ctx,b.tip)}
    themed:Node_Style
    look:=b.look
    if look==nil {
        states:Style_States
        if it.hot {states+={.Hovered}}
        if b.active {states+={.Selected}}
        if b.disabled {states+={.Disabled}}
        themed=sheet_look(ctx,"button",b.variant if b.variant!="" else "ghost",states)
        look=&themed
    }
    size:=b.size if b.size>0 else (look.text.size if look.text.size>0 else metric(ctx,"font"))
    text_color:=look.text.color
    icon_color:=b.icon_color if b.icon_color[3]>0 else text_color
    if b.variant=="tab" && b.active {icon_color=tone(ctx,"on_accent")}
    if b.disabled && b.icon_color[3]>0 {icon_color=color_faded(icon_color)}
    icon_size:=b.icon_size if b.icon_size>0 else 16
    width,height:Size
    padding:f32
    if l:=b.layout;l!=nil {
        width,height,padding=l.width,l.height,l.padding[0]
        if width=={} {width=fixed(text_width(&ctx.font,b.label,size,int(look.text.font))+l.padding[0]+l.padding[2]+1)}
        if height=={} {height=fixed(size*TEXT_LINE+l.padding[1]+l.padding[3])}
    } else {
        row:=b.height if b.height>0 else metric(ctx,"row")
        width,height=fixed(b.width),fixed(row)
        padding=f32(10) if b.label!="" else (row-16)/2
        if b.padding!=0 {padding=max(b.padding,0)}
        if b.width==0 {
            content:=f32(0)
            if b.icon!=.None {content+=icon_size}
            if b.quad.kind!=.Solid {content+=row-8+6}
            if b.label!="" {content+=text_width(&ctx.font,b.label,size);if b.icon!=.None {content+=6}}
            if b.detail!="" {content+=text_width(&ctx.font,b.detail,metric(ctx,"font_small"))+(16 if b.label!="" else 6)}
            width=fixed(content+2*padding)
        } else if b.width<0 {width=GROW}
    }
    style:=look.text
    style.size,style.color=size,text_color
    if b.block {style.align_x,style.align_y=.Center,.Center}
    fill:=look.fill
    if b.image.quad.kind!=.Solid && fill=={} {fill={255,255,255,255}}
    detail_color:=color_alpha(tone(ctx,"on_accent"),170) if text_color==tone(ctx,"on_accent") else tone(ctx,"text_faint")
    paint:=Paint{kind=.Box,fill=fill,fill2=look.fill2,stroke=look.stroke,corners=look.radius,stroke_width=look.stroke_width,
        shadow=look.shadow,shadow_color=look.shadow_color,shadow_blur=look.shadow_blur,shadow_offset=look.shadow_offset,
        style=style,text=b.label,detail=b.detail,text_color=text_color,detail_color=detail_color,size=size,center=b.center||(b.label==""&&b.detail==""),padding=padding,
        icon=b.icon,icon_color=icon_color,icon_size=icon_size,icon_after=b.icon_after,quad=b.quad,
        quad2=b.image.quad,border=b.image.border,border_uv=b.image.border_uv}
    if b.block {
        // Its label is a text over the whole of it.
        paint.text,paint.style="",{}
        if element_open(ctx,{id=id,layout={width=width,height=height},custom=paint_add(ctx,paint)}) {text(ctx,b.label,style,GROW,GROW)}
        element_close(ctx)
        return it
    }
    element_leaf(ctx,{id=id,layout={width=width,height=height},custom=paint_add(ctx,paint)})
    return it
}

// A square button that shows an icon alone.
icon_button :: proc(ctx:^Context,id:Id,icon:Icon,size:f32=0,variant:string="",tip:string="",color:Color={},active:bool=false,disabled:bool=false) -> Interaction {
    side:=size if size>0 else metric(ctx,"row")
    return button(ctx,id,{icon=icon,icon_color=color,variant=variant,tip=tip,width=side,height=side,active=active,disabled=disabled})
}

// A box with a check while value is true; a click flips it. look: what it is
// drawn with, resolved for the state it is in: its fill, stroke and corners,
// and a tick of its mark three quarters of its side; nil: that of the theme.
// Without a size it is a line of the text of its look square.
checkbox :: proc(ctx:^Context,id:Id,value:^bool,disabled:bool=false,look:^Node_Style=nil,width:Size={},height:Size={}) -> (changed:bool) {
    disabled:=disabled || ctx.disabled_depth>0
    it:=interact(ctx,id,{.Focusable}+({.Disabled} if disabled else {}))
    if it.clicked {value^=!value^;changed=true}
    on:=value^
    themed:Node_Style
    look:=look
    line:=CHECKBOX_SIDE
    if look==nil {
        themed={fill=tone(ctx,"well"),stroke=tone(ctx,"accent") if on else (tone(ctx,"well_stroke_hover") if it.hot else tone(ctx,"well_stroke")),radius=metric(ctx,"radius_control"),mark=tone(ctx,"text_faint") if disabled else tone(ctx,"accent")}
        look=&themed
    } else {line=control_em(ctx,look)*TEXT_LINE}
    w:=width if width!={} else fixed(line)
    h:=height if height!={} else fixed(line)
    side:=line if h==fixed(line) else control_height(ctx,id,h,line)
    paint:=paint_add(ctx,{kind=.Box,fill=look.fill,fill2=look.fill2,stroke=look.stroke,stroke_width=look.stroke_width,corners=look.radius,center=true,
        shadow=look.shadow,shadow_color=look.shadow_color,shadow_blur=look.shadow_blur,shadow_offset=look.shadow_offset,
        icon=.Check if on else .None,icon_color=look.mark,icon_size=side*0.75})
    element_leaf(ctx,{id=id,layout={width=w,height=h},custom=paint})
    return
}
CHECKBOX_SIDE :: f32(16) // of a checkbox of the theme

// ---------------------------------------------------------------- sections and tabs

// ---------------------------------------------------------------- swatches and rows

Row :: struct {
    label:string,
    detail:string,
    icon:Icon,
    icon_color:Color,
    icon_size:f32,
    text_color:Color, // of the label; transparent: the theme's
    font:u8,          // of the label: FONT_SEMIBOLD for a row that heads what is under it
    quad:Quad,
    selected:bool,   // the row the list is on: tinted with the accent
    checked:bool,    // shows a check before the label
    check_room:bool, // unchecked rows leave the room of the check
    accent:bool,     // under the pointer it fills with the accent, as menu items do
    quiet:bool,      // its list moves the current row instead: the pointer neither tints it nor gives it the focus
    disabled:bool,
    height:f32,
    depth:int,       // indentation of a row of a tree
    indent:f32,      // units per depth; 12 when 0
}
// A row of a list, a menu or a tree.
row :: proc(ctx:^Context,id:Id,r:Row) -> Interaction {
    it:=interact(ctx,id,{.Passive} if r.disabled else ({} if r.quiet else {.Focusable}))
    if r.disabled {it={}}
    // In a popup the keys move over: the row of its cursor shows as pointed at, and Enter takes it.
    keyed:=false
    if p:=&ctx.popup;p.depth>0 && !r.disabled {
        entry:=&p.stack[p.building[p.depth-1]]
        if entry.keys {
            index:=p.rows[p.depth-1]
            p.rows[p.depth-1]+=1
            if it.hot && ctx.pointer_moved {entry.cursor=index}
            if index==entry.cursor {
                keyed=true
                if entry.take {it.clicked,entry.take=true,false}
                if entry.moved {ctx.reveal_next,entry.moved=id,false}
            }
        }
    }
    fill:Color;text_color:=r.text_color if r.text_color!={} else tone(ctx,"text");detail_color:=tone(ctx,"text_faint");icon_color:=r.icon_color if r.icon_color!={} else tone(ctx,"text_muted")
    if r.accent && (it.hot || keyed) {
        fill=tone(ctx,"accent");text_color=tone(ctx,"on_accent");detail_color=color_alpha(tone(ctx,"on_accent"),190)
    } else if r.selected {fill=tone(ctx,"accent_soft")} else if it.hot && !r.accent && !r.quiet {fill=tone(ctx,"field_hover")}
    if r.disabled {text_color,detail_color,icon_color=color_faded(text_color),color_faded(detail_color),color_faded(icon_color)}
    paint:=Paint{kind=.Box,fill=fill,radius=metric(ctx,"radius_control"),text=r.label,detail=r.detail,text_color=text_color,detail_color=detail_color,size=metric(ctx,"font_small"),padding=8,icon=r.icon,icon_color=icon_color,icon_size=r.icon_size if r.icon_size>0 else 16,quad=r.quad,style={font=r.font}}
    if r.checked {paint.icon=.Check;paint.icon_color=tone(ctx,"on_accent") if r.accent&&(it.hot || keyed) else tone(ctx,"accent");paint.icon_size=14} else if r.check_room {paint.padding=28}
    height:=r.height if r.height>0 else metric(ctx,"row")
    if r.depth>0 {
        if box(ctx,{width=GROW,height=fixed(height)}) {
            spacer(ctx,f32(r.depth)*(r.indent if r.indent>0 else 12),1)
            element_leaf(ctx,{id=id,layout={width=GROW,height=fixed(height)},custom=paint_add(ctx,paint)})
        }
    } else {
        element_leaf(ctx,{id=id,layout={width=GROW,height=fixed(height)},custom=paint_add(ctx,paint)})
    }
    return it
}

// Text next to the pointer for this frame: call it while the pointer is on what
// it explains. It shows once the pointer rested TOOLTIP_DELAY on the same
// element, for every tooltip alike. Only the screen has tooltips.
tooltip :: proc(ctx:^Context,text:string) {
    if ctx.surface!=0 {return}
    if ctx.tooltip_hot!=ctx.hot || ctx.tooltip_frame+1<ctx.stats.frame {ctx.tooltip_hot,ctx.tooltip_since=ctx.hot,ctx.time}
    ctx.tooltip_frame=ctx.stats.frame
    if ctx.time-ctx.tooltip_since>=TOOLTIP_DELAY {ctx.tooltip=text_store(ctx,text)}
}

TOOLTIP_DELAY :: 0.4 // s the pointer rests on something before its tooltip shows

// The tooltip hangs under the pointer, and the layout puts it over the pointer
// where it does not fit under it and keeps it inside the surface.
@(private)
tooltip_build :: proc(ctx:^Context) {
    mouse:=ctx.screen_pointer
    wide:=text_width(&ctx.font,ctx.tooltip,metric(ctx,"font_small"))+20
    most:=min(420,ctx.size.x-2*metric(ctx,"margin"))
    ctx.surface=0;ctx.scope=0
    b:=Box{id=id(ctx,"tooltip"),fill=tone(ctx,"popup"),stroke=tone(ctx,"border"),radius=metric(ctx,"radius_control"),
        float={to=.Surface,anchor=.Bottom_Left,pivot=.Top_Left,offset={12,0},layer=LAYER_TOOLTIP},
        from=Rect{mouse.x,mouse.y-8,0,28},contain=true,inset={metric(ctx,"margin"),metric(ctx,"bar_height")+2,metric(ctx,"margin"),metric(ctx,"margin")}}
    if wide>most || strings.contains(ctx.tooltip,"\n") {
        b.width,b.height,b.padding=fixed(most),FIT,padding_all(10)
        if box(ctx,b) {text(ctx,ctx.tooltip,prose(ctx,metric(ctx,"font_small"),tone(ctx,"text")))}
        return
    }
    b.width,b.height,b.align_y=fixed(wide),fixed(26),.Center
    if box(ctx,b) {label(ctx,ctx.tooltip,metric(ctx,"font_small"),tone(ctx,"text"),0,true)}
}
