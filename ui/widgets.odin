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
    program:u32,      // a ui program that colors the fill instead, given that of its look: see draw_program
    block:bool,       // the label takes the lines, the outline and the shadow of the text of its look, centered
    holds:bool,       // what is built until button_end follows the label, laid out as the whole of layout says
}

// A clickable box with an optional icon, preview, label and right aligned
// detail: every button of the editor and of a game. Disabled, the pointer goes
// through it unless it has a tooltip to show.
button :: proc(ctx:^Context,id:Id,b:Button) -> Interaction {
    it:=button_begin(ctx,id,b)
    button_end(ctx)
    return it
}
// A button whose content goes on until button_end: what is built in between
// is inside it, after its label, and the pointer on it is the button's.
button_begin :: proc(ctx:^Context,id:Id,b:Button) -> Interaction {
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
    padding:[4]f32
    if l:=b.layout;l!=nil {
        width,height,padding=l.width,l.height,l.padding
        if height=={} && !b.holds {height=fixed(size*TEXT_LINE+l.padding[1]+l.padding[3])}
    } else {
        row:=b.height if b.height>0 else metric(ctx,"row")
        width,height=fixed(b.width),fixed(row)
        side:=f32(10) if b.label!="" else (row-16)/2
        if b.padding!=0 {side=max(b.padding,0)}
        padding={side,0,side,0}
        if b.width==0 {width=FIT} else if b.width<0 {width=GROW}
    }
    style:=look.text
    style.size,style.color,style.align_y=size,text_color,.Center
    // A centered label that does not size its button centers in the whole of it.
    center:=(b.center || b.block || (b.label=="" && b.detail=="")) && width.kind!=.Fit
    if center {style.align_x=.Center}
    if center && !b.holds {padding[0],padding[2]=0,0}
    // A text that fits keeps a unit for the edge of its last glyph, which the padding after it already holds.
    if b.detail!="" || b.icon_after || width.kind==.Fit {padding[2]=max(padding[2]-1,0)}
    if !b.block {style.wrap=.None}
    fill:=look.fill
    if b.image.quad.kind!=.Solid && fill=={} {fill={255,255,255,255}}
    paint:=paint_add(ctx,{kind=.Box,fill=fill,fill2=look.fill2,gradient=look.gradient,stroke=look.stroke,corners=look.radius,stroke_width=look.stroke_width,
        shadow=look.shadow,shadow_color=look.shadow_color,shadow_blur=look.shadow_blur,shadow_offset=look.shadow_offset,
        program=b.program,program_values=look.program_values,quad2=b.image.quad,border=b.image.border,border_uv=b.image.border_uv})
    layout:=Layout{width=width,height=height,padding=padding,gap=box_gap(b.label,b.detail),align_y=.Center}
    if b.holds && b.layout!=nil {
        layout=b.layout^
        layout.width,layout.height,layout.padding=width,height,padding
    }
    if element_open(ctx,{id=id,layout=layout,custom=paint}) {
        detail:=color_alpha(tone(ctx,"on_accent"),170) if text_color==tone(ctx,"on_accent") else tone(ctx,"text_faint")
        box_content(ctx,{label=b.label,detail=b.detail,style=style,detail_color=detail,icon=b.icon,icon_color=icon_color,icon_size=icon_size,icon_after=b.icon_after,
            quad=b.quad,preview=max(height.value-(8 if b.label!="" else 4),0),fit=width.kind==.Fit,holds=b.holds,fade=!center && (b.icon_after || b.detail!="")})
    }
    return it
}
button_end :: proc(ctx:^Context) {element_close(ctx)}

// What a button or a row holds inside its padding, each a text: its icon and
// preview in the line of its label, then its detail and the icon that follows
// the label.
@(private)
Box_Content :: struct {
    label,detail:string,
    style:Text_Style,      // of the label
    detail_color:Color,
    icon:Icon,
    icon_color:Color,
    icon_size:f32,
    icon_after:bool,
    quad:Quad,
    preview:f32,           // the side of the quad
    fit:bool,              // the label is as wide as it says, instead of taking what is left
    holds:bool,            // more content follows: the label is as wide and as high as its lines
    fade:bool,             // a label that does not fit fades out before what follows it
}
// Between the content of a button or a row: a label and its detail are 16
// apart and anything else 6, less the unit a text keeps for its last glyph.
@(private)
box_gap :: proc "contextless" (label,detail:string) -> f32 {return 15 if label!="" && detail!="" else 5}
@(private)
box_content :: proc(ctx:^Context,c:Box_Content) {
    leads:=c.icon!=.None && !c.icon_after
    // A label and a detail that do not fit side by side are both cut, the
    // longer first, each ending in an ellipsis: the label in a box that takes
    // the room left, so the detail stays at the end.
    cut:=c.label!="" && c.detail!="" && !c.fit && c.style.align_x!=.Center
    style:=c.style
    if cut {style.ellipsis=true}
    if cut {element_open(ctx,{layout={width=GROW,height=GROW,align_y=.Center}})}
    if (c.label!="" || leads || c.quad.kind!=.Solid) && text_begin(ctx,style) {
        if leads {text_box(ctx,c.icon_size,c.icon_size,{kind=.Icon,icon=c.icon,icon_color=c.icon_color},gap=6 if c.label!="" || c.quad.kind!=.Solid else 0)}
        if c.quad.kind!=.Solid {text_box(ctx,c.preview,c.preview,{kind=.Image,quad=c.quad,fill={255,255,255,255}},gap=6 if c.label!="" else 0)}
        text_span(ctx,c.label)
        text_end(ctx,{width=FIT if c.fit || cut || c.holds else GROW,height=FIT if c.holds else GROW},fade=c.fade && !cut)
    }
    if cut {element_close(ctx)}
    if c.detail!="" {text(ctx,c.detail,{size=metric(ctx,"font_small"),color=c.detail_color,align_y=.Center,ellipsis=cut},FIT,GROW)}
    if c.icon!=.None && c.icon_after && text_begin(ctx,c.style) {
        text_box(ctx,c.icon_size,c.icon_size,{kind=.Icon,icon=c.icon,icon_color=c.icon_color})
        text_end(ctx,{height=GROW})
    }
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
    paint:=paint_add(ctx,{kind=.Box,fill=look.fill,fill2=look.fill2,gradient=look.gradient,stroke=look.stroke,stroke_width=look.stroke_width,corners=look.radius,
        shadow=look.shadow,shadow_color=look.shadow_color,shadow_blur=look.shadow_blur,shadow_offset=look.shadow_offset})
    if element_open(ctx,{id=id,layout={width=w,height=h,align_x=.Center,align_y=.Center},custom=paint}) && on {icon(ctx,.Check,look.mark,side*0.75)}
    element_close(ctx)
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
    mark,mark_size,padding:=r.icon,r.icon_size if r.icon_size>0 else 16,f32(8)
    if r.checked {mark,icon_color,mark_size=.Check,tone(ctx,"on_accent") if r.accent && (it.hot || keyed) else tone(ctx,"accent"),14} else if r.check_room {padding=28}
    height:=r.height if r.height>0 else metric(ctx,"row")
    if r.depth>0 {box_begin(ctx,{width=GROW,height=fixed(height),padding={f32(r.depth)*(r.indent if r.indent>0 else 12),0,0,0}})}
    if element_open(ctx,{id=id,layout={width=GROW,height=fixed(height),padding={padding,0,padding-1 if r.detail!="" else padding,0},gap=box_gap(r.label,r.detail),align_y=.Center},custom=paint_add(ctx,{kind=.Box,fill=fill,radius=metric(ctx,"radius_control")})}) {
        box_content(ctx,{label=r.label,detail=r.detail,style={font=r.font,size=metric(ctx,"font_small"),color=text_color,align_y=.Center},detail_color=detail_color,
            icon=mark,icon_color=icon_color,icon_size=mark_size,quad=r.quad,preview=height-8,fade=r.detail!=""})
    }
    element_close(ctx)
    if r.depth>0 {box_end(ctx,{})}
    return it
}

// The width row draws r at when nothing of it is cut: what a list measures to
// be as wide as its widest row.
row_width :: proc(ctx:^Context,r:Row) -> f32 {
    height:=r.height if r.height>0 else metric(ctx,"row")
    size:=metric(ctx,"font_small")
    mark,mark_size:=r.icon,r.icon_size if r.icon_size>0 else 16
    if r.checked {mark,mark_size=.Check,14}
    width:=f32(28 if r.check_room && !r.checked else 8)+8
    if r.depth>0 {width+=f32(r.depth)*(r.indent if r.indent>0 else 12)}
    if mark!=.None {width+=mark_size+6}
    if r.quad.kind!=.Solid {width+=height-8+6}
    width+=text_width(&ctx.font,r.label,size,int(r.font))+1
    if r.detail!="" {width+=box_gap(r.label,r.detail)+text_width(&ctx.font,r.detail,size)+1}
    return math.ceil(width)
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
