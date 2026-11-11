package ui

import "core:math"
import "core:strings"

// The widgets of the editor, with its look as the default theme. Each one is
// a procedure that reads the state it is given, declares its element and
// reports what the pointer or the keyboard did to it this frame.

// What a disabled control draws a color with: 40 % of its opacity.
color_faded :: proc "contextless" (c:Color) -> Color {return {c[0],c[1],c[2],u8(f32(c[3])*0.4)}}

// The tint of the item of a menu or list the pointer is on.
color_hover :: proc "contextless" (th:^Theme) -> Color {return color_alpha(th.text,9)}

// ---------------------------------------------------------------- text and icons

// A single line of text that is clipped to its box instead of overflowing.
// width: negative fits the text, 0 grows, positive is fixed. fade: a text that
// does not fit fades out at its end.
label :: proc(ctx:^Context,text:string,size:f32=0,color:Color={},width:f32=-1,center:bool=false,font:u8=0,fade:=false) {
    th:=&ctx.theme
    size:=size if size>0 else th.font
    sizing:=fixed(width)
    if width<0 {sizing=fixed(text_width(&ctx.font,text,size,int(font))+1)}
    if width==0 {sizing=GROW}
    paint:=paint_add(ctx,{kind=.Text,text=text,text_color=color if color!={} else th.text,size=size,center=center,style={font=font},fade=fade})
    element_leaf(ctx,{layout={width=sizing,height=fixed(size+6)},custom=paint})
}

// A paragraph wrapped by the layout to the width its parent leaves it. Its
// line box is line sizes of its text; PARAGRAPH_LINE when 0.
paragraph :: proc(ctx:^Context,text:string,size:f32=0,color:Color={},font:u8=0,line:f32=0) {
    th:=&ctx.theme
    size:=size if size>0 else th.font_small
    if ctx.skipped>0 || ctx.elements+ELEMENT_RESERVE>=ctx.max_elements {ctx.stats.dropped_elements+=1;return}
    paint:=paint_add(ctx,{kind=.None,style={font=font,size=size,color=color if color!={} else th.text_muted,line_height=line}})
    if paint==nil {return}
    element_text(ctx,paint,text_store(ctx,text),size)
}

// Height of text as paragraph lays it out in width, without building it: the
// same measure and the same breaks. A run is as wide as the width it is given,
// no wider than its longest line and no narrower than its widest word.
paragraph_height :: proc(ctx:^Context,text:string,width:f32,size:f32=0,font:u8=0,line:f32=0) -> f32 {
    size:=size if size>0 else ctx.theme.font_small
    line:=paragraph_line(size,line)
    m:=layout_measure(&ctx.layout,&ctx.font,text,size,font)
    return line*f32(max(layout_wrap(&ctx.layout,&ctx.font,text,m,size,font,max(m.min_width,min(m.width,width)),nil),1))
}

icon :: proc(ctx:^Context,icon:Icon,color:Color,size:f32=16) {
    paint:=paint_add(ctx,{kind=.Icon,icon=icon,icon_color=color,icon_size=size})
    element_leaf(ctx,{layout={width=fixed(size),height=fixed(size)},custom=paint})
}

// ---------------------------------------------------------------- buttons

Button_Style :: enum u8 {
    Ghost,  // nothing until the pointer is on it
    Field,  // the fill of a field
    Accent, // the one action that matters
    Tab,    // a segment of a segmented control: accent while active
    Well,   // a value to choose, outlined like a field
    Danger, // the action destroys something
    Toggle, // as Ghost while off; on, a dark violet with its outline: a tab shown, a menu open
}
Button :: struct {
    label:string,
    detail:string,    // right aligned: a shortcut, a count
    tip:string,       // tooltip
    icon:Icon,
    icon_color:Color, // the color of the text when transparent
    style:Button_Style,
    active:bool,
    disabled:bool,    // shown, but does nothing
    width:f32,        // 0: fit the content, negative: grow
    height:f32,       // the row of the theme when 0
    size:f32,         // text size; that of its look, or the font of the theme, when 0
    center:bool,
    quad:Quad,        // preview or thumbnail before the label
    icon_size:f32,    // 16 when 0
    icon_after:bool,  // the icon follows the label: a menu that opens below
    padding:f32,      // 0: automatic, negative: no inset
    // What it is drawn with, resolved for the state it is in: fill, stroke,
    // corners, shadow and text. nil: what the theme gives its style (button_look).
    look:^Node_Style,
    // Its size and padding as an element says them, instead of width, height
    // and padding: without a size it fits its label.
    layout:^Layout,
    image:Node_Image, // behind it instead of its fill, which tints it
    block:bool,       // the label takes the lines, the outline and the shadow of the text of its look, centered
}

// What the theme draws a button of a style with in a state. Disabled, a
// button that has no fill of its own shows neither fill nor border, not even
// under the pointer, a Field or an Accent one the faded box of a field, and
// every other one keeps its fill faded: only its glyph says it is there.
button_look :: proc "contextless" (th:^Theme,style:Button_Style,hot,active,disabled:bool) -> (look:Node_Style) {
    fill,stroke:Color;text:=th.text
    switch style {
    case .Ghost:if hot {fill=th.field_hover;stroke=th.border}
    case .Field:fill=th.field_hover if hot else th.field;stroke=th.well_stroke_hover if hot else th.border
    case .Accent:fill=th.accent_hover if hot else th.accent;text=th.on_accent
    case .Tab:
        if active {fill=th.accent;text=th.on_accent} else if hot {fill=th.field_hover} else {text=th.text_label}
    case .Well:fill=th.well;stroke=th.accent if active else (th.well_stroke_hover if hot else th.well_stroke)
    case .Danger:fill=th.danger_soft if hot else th.danger;text=th.well
    case .Toggle:
        if active {fill=th.toggle_on;stroke=th.toggle_on_stroke} else if hot {fill=th.field_hover;stroke=th.border}
    }
    if style==.Ghost && active {fill=th.field_active;stroke=th.border}
    if disabled {
        switch style {
        case .Ghost,.Tab,.Toggle: fill,stroke={},{}
        case .Field,.Accent: fill,stroke,text=color_faded(th.field),color_faded(th.border),th.text
        case .Danger: fill=color_faded(th.danger)
        case .Well: stroke=th.well_stroke
        }
        text=color_faded(text)
    }
    look.fill,look.stroke,look.radius,look.text.color=fill,stroke,th.radius_control,text
    return
}

// A clickable box with an optional icon, preview, label and right aligned
// detail: every button of the editor and of a game. Disabled, the pointer goes
// through it unless it has a tooltip to show.
button :: proc(ctx:^Context,id:Id,b:Button) -> Interaction {
    b:=b
    b.disabled|=ctx.disabled_depth>0
    th:=&ctx.theme
    it:=interact(ctx,id,{.Focusable} if !b.disabled else ({.Block} if b.tip!="" else {.Passive}))
    if b.disabled {it={hot=ctx.hot==id && id!=0}}
    if it.hot && b.tip!="" {tooltip(ctx,b.tip)}
    themed:Node_Style
    look:=b.look
    if look==nil {
        themed=button_look(th,b.style,it.hot,b.active,b.disabled)
        look=&themed
    }
    size:=b.size if b.size>0 else (look.text.size if look.text.size>0 else th.font)
    text_color:=look.text.color
    icon_color:=b.icon_color if b.icon_color[3]>0 else text_color
    if b.style==.Tab && b.active {icon_color=th.on_accent}
    if b.disabled && b.icon_color[3]>0 {icon_color=color_faded(icon_color)}
    icon_size:=b.icon_size if b.icon_size>0 else 16
    width,height:Size
    padding:f32
    if l:=b.layout;l!=nil {
        width,height,padding=l.width,l.height,l.padding[0]
        if width=={} {width=fixed(text_width(&ctx.font,b.label,size,int(look.text.font))+l.padding[0]+l.padding[2]+1)}
        if height=={} {height=fixed(size*TEXT_LINE+l.padding[1]+l.padding[3])}
    } else {
        row:=b.height if b.height>0 else th.row
        width,height=fixed(b.width),fixed(row)
        padding=f32(10) if b.label!="" else (row-16)/2
        if b.padding!=0 {padding=max(b.padding,0)}
        if b.width==0 {
            content:=f32(0)
            if b.icon!=.None {content+=icon_size}
            if b.quad.kind!=.Solid {content+=row-8+6}
            if b.label!="" {content+=text_width(&ctx.font,b.label,size);if b.icon!=.None {content+=6}}
            if b.detail!="" {content+=text_width(&ctx.font,b.detail,th.font_small)+(16 if b.label!="" else 6)}
            width=fixed(content+2*padding)
        } else if b.width<0 {width=GROW}
    }
    style:=look.text
    style.size,style.color=size,text_color
    if b.block {style.align_x,style.align_y=.Center,.Center}
    fill:=look.fill
    if b.image.quad.kind!=.Solid && fill=={} {fill={255,255,255,255}}
    detail_color:=color_alpha(th.on_accent,170) if text_color==th.on_accent else th.text_faint
    paint:=paint_add(ctx,{kind=.Box,fill=fill,fill2=look.fill2,stroke=look.stroke,corners=look.radius,stroke_width=look.stroke_width,
        shadow=look.shadow,shadow_color=look.shadow_color,shadow_blur=look.shadow_blur,shadow_offset=look.shadow_offset,
        style=style,text=b.label,detail=b.detail,text_color=text_color,detail_color=detail_color,size=size,center=b.center||(b.label==""&&b.detail==""),padding=padding,
        icon=b.icon,icon_color=icon_color,icon_size=icon_size,icon_after=b.icon_after,quad=b.quad,
        quad2=b.image.quad,border=b.image.border,border_uv=b.image.border_uv,multiline=b.block})
    element_leaf(ctx,{id=id,layout={width=width,height=height},custom=paint})
    return it
}

// A square button that shows an icon alone.
icon_button :: proc(ctx:^Context,id:Id,icon:Icon,size:f32=0,style:Button_Style=.Ghost,tip:string="",color:Color={},active:bool=false,disabled:bool=false) -> Interaction {
    side:=size if size>0 else ctx.theme.row
    return button(ctx,id,{icon=icon,icon_color=color,style=style,tip=tip,width=side,height=side,active=active,disabled=disabled})
}

// A segment that stays lit while value is true; a click flips it.
toggle :: proc(ctx:^Context,id:Id,text:string,value:^bool,width:f32=-1,disabled:bool=false) -> (changed:bool) {
    it:=button(ctx,id,{label=text,style=.Tab,size=ctx.theme.font_small,width=width,center=true,active=value^,disabled=disabled})
    if it.clicked {value^=!value^;changed=true}
    return
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
        th:=&ctx.theme
        themed={fill=th.well,stroke=th.accent if on else (th.well_stroke_hover if it.hot else th.well_stroke),radius=th.radius_control,mark=th.text_faint if disabled else th.accent}
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

// A switch for a value that is on or off: the track fills with the accent while it is on.
toggle_switch :: proc(ctx:^Context,id:Id,value:^bool,disabled:bool=false) -> (changed:bool) {
    disabled:=disabled || ctx.disabled_depth>0
    th:=&ctx.theme
    it:=interact(ctx,id,{.Focusable}+({.Disabled} if disabled else {}))
    if it.clicked {value^=!value^;changed=true}
    on:=value^
    fill:=th.accent if on else color_alpha(th.text,46 if it.hot else 34)
    knob:=Color{255,255,255,255} if on else th.text_muted
    if disabled {fill,knob=color_faded(fill),color_faded(knob)}
    paint:=paint_add(ctx,{kind=.Switch,fill=fill,stroke=knob,value=1 if on else 0})
    element_leaf(ctx,{id=id,layout={width=fixed(29),height=fixed(16)},custom=paint})
    return
}

// ---------------------------------------------------------------- sections and tabs

// A title followed by a rule, with an optional remark at its right end.
section :: proc(ctx:^Context,title:string,note:string="",note_width:f32=0) {
    th:=&ctx.theme
    if box(ctx,{width=GROW,height=fixed(22),gap=8,align_y=.End}) {
        label(ctx,title,th.font_label,th.text_faint)
        if box(ctx,{width=GROW,height=fixed(9),align_y=.Center}) {divider(ctx)}
        if note!="" {label(ctx,note,th.font_label,th.text_muted,min(text_width(&ctx.font,note,th.font_label)+1,note_width if note_width>0 else max(f32)))}
    }
}

Collapsible :: struct {
    note:string,
    note_color:Color, // text_muted when transparent
    width:f32,        // what the title, the note and the remove button share; 0: do not cut them
    removable:bool,   // shows an x at the right end
}
Collapsible_Result :: struct {
    open:bool,    // build the rows of the section
    toggled:bool,
    removed:bool, // the x was clicked
}

// The title of a section that folds: a click on it shows or hides what follows.
collapsible :: proc(ctx:^Context,id:Id,title:string,open:^bool,c:Collapsible={}) -> (result:Collapsible_Result) {
    th:=&ctx.theme
    it:=interact(ctx,id,{.Focusable})
    if it.clicked {open^=!open^;result.toggled=true}
    color:=th.text_muted if it.hot else th.text_faint
    room:=(c.width if c.width>0 else 100000)-16-(24 if c.removable else 0)
    note_width:=min(text_width(&ctx.font,c.note,th.font_label)+1,room*0.6) if c.note!="" else 0
    title_width:=min(text_width(&ctx.font,title,th.font_label)+1,max(room-note_width-22,24))
    if box(ctx,{id=id,width=GROW,height=fixed(22),gap=6,align_y=.End}) {
        if box(ctx,{width=fixed(10),height=fixed(th.font_label+6),align_x=.Center,align_y=.Center}) {
            icon(ctx,.Chevron_Down if open^ else .Chevron_Right,color,10)
        }
        label(ctx,title,th.font_label,color,title_width)
        if box(ctx,{width=GROW,height=fixed(9),align_y=.Center}) {divider(ctx)}
        if c.note!="" {label(ctx,c.note,th.font_label,c.note_color if c.note_color!={} else th.text_muted,note_width)}
        if c.removable {
            id_push(ctx,id)
            result.removed=button(ctx,ui_id(ctx,"remove"),{icon=.Cross,style=.Ghost,width=18,height=18}).clicked
            id_pop(ctx)
        }
    }
    result.open=open^
    return
}
@(private)
ui_id :: proc(ctx:^Context,name:string,index:int=0) -> Id {return id(ctx,name,index)}

// The frame of a segmented control: put buttons of style Tab inside.
@(deferred_in=segments_end)
segments :: proc(ctx:^Context,width:Size=GROW,height:f32=30) -> bool {
    th:=&ctx.theme
    paint:=paint_add(ctx,{kind=.Box,fill=th.well,stroke=th.well_stroke,radius=th.radius_control})
    element_open(ctx,{layout={width=width,height=fixed(height),padding=padding_all(2),gap=2,align_y=.Center},custom=paint})
    return true
}
@(private)
segments_end :: proc(ctx:^Context,width:Size,height:f32) {element_close(ctx)}

// Tabs as one segmented control. Returns true when the selection changed.
tabs :: proc(ctx:^Context,id:Id,titles:[]string,selected:^int,width:Size=GROW,height:f32=30) -> (changed:bool) {
    th:=&ctx.theme
    id_push(ctx,id)
    defer id_pop(ctx)
    if segments(ctx,width,height) {
        for title,index in titles {
            if button(ctx,ui_id(ctx,"tab",index+1),{label=title,style=.Tab,active=selected^==index,width=-1,height=height-4,size=th.font_small,center=true}).clicked && selected^!=index {
                selected^=index;changed=true
            }
        }
    }
    return
}

// ---------------------------------------------------------------- cards, swatches, rows

Card :: struct {
    label:string,
    icon:Icon,
    icon_color:Color,
    icon_size:f32,   // 22 when 0
    quad:Quad,       // a preview instead of the icon
    active:bool,
    width,height:Size, // GROW when unset
}
// A box with an icon or a preview over its name, as in a palette of things to create.
card :: proc(ctx:^Context,id:Id,c:Card) -> Interaction {
    th:=&ctx.theme
    it:=interact(ctx,id,{.Focusable})
    fill:=th.field_active if c.active else (th.field_hover if it.hot else th.field)
    paint:=paint_add(ctx,{kind=.Card,fill=fill,stroke=th.accent if it.hot||c.active else th.divider,radius=th.radius_control+1,text=c.label,text_color=th.text,size=th.font_small,icon=c.icon,icon_color=c.icon_color if c.icon_color!={} else th.text_muted,icon_size=c.icon_size if c.icon_size>0 else 22,quad=c.quad})
    element_leaf(ctx,{id=id,layout={width=(c.width if c.width!={} else GROW),height=(c.height if c.height!={} else GROW)},custom=paint})
    return it
}

// A row of a grid of cards: `columns` cells of the same width, `height` tall.
// Fill it with cards and call grid_fill for the cells left empty.
@(deferred_in=grid_row_end)
grid_row :: proc(ctx:^Context,height:f32=62,gap:f32=8) -> bool {
    element_open(ctx,{layout={width=GROW,height=fixed(height),gap=gap}})
    return true
}
@(private)
grid_row_end :: proc(ctx:^Context,height,gap:f32) {element_close(ctx)}
// Empty cells that keep the width of the columns of a row that is not full.
grid_fill :: proc(ctx:^Context,cells:int) {for _ in 0..<cells {spacer(ctx)}}

// A color as an input: its swatch alone. rgb: display space.
color_swatch :: proc(ctx:^Context,id:Id,rgb:[3]f32,open:bool=false,width:f32=0,height:f32=0) -> Interaction {
    th:=&ctx.theme
    it:=interact(ctx,id,{.Focusable})
    paint:=paint_add(ctx,{kind=.Swatch,fill=rgb_color(rgb),stroke=th.accent if open||it.hot else th.border})
    element_leaf(ctx,{id=id,layout={width=(fixed(width) if width>0 else GROW),height=fixed(height if height>0 else th.row)},custom=paint})
    return it
}

// A color as a swatch followed by its channels. rgb: display space, 0 to 1.
// Returns what happened to the channels and what the pointer did to the swatch.
color_field :: proc(ctx:^Context,id:Id,rgb:^[3]f32,open:bool=false) -> (result:Number_Result,swatch:Interaction) {
    th:=&ctx.theme
    id_push(ctx,id)
    defer id_pop(ctx)
    swatch=color_swatch(ctx,ui_id(ctx,"swatch"),rgb^,open,th.row)
    values:=[3]f64{f64(rgb.r),f64(rgb.g),f64(rgb.b)}
    result,_=vector_field(ctx,ui_id(ctx,"channels"),values[:],{number={decimals=2,speed=0.004,min=0,max=1,has_min=true,has_max=true},channels=true})
    if result.changed {rgb^={f32(values[0]),f32(values[1]),f32(values[2])}}
    return
}

// The label of a row in the column of labels, the same width in every row
// so the controls after it line up; one too long ends in an ellipsis.
column_label :: proc(ctx:^Context,text:string,color:Color={}) {
    th:=&ctx.theme
    text:=text
    if text_width(&ctx.font,text,th.font_small)>th.label_width {
        cut:=text_cut(&ctx.font,text,th.font_small,th.label_width)
        if bytes:=text_reserve(ctx,len(cut)+len(ELLIPSIS));bytes!=nil {
            used:=copy(bytes,cut);used+=copy(bytes[used:],ELLIPSIS)
            text=text_commit(ctx,string(bytes[:used]))
        }
    }
    paint:=paint_add(ctx,{kind=.Text,text=text,text_color=color if color!={} else th.text_label,size=th.font_small})
    element_leaf(ctx,{layout={width=fixed(th.label_width),height=fixed(th.font_small+6)},custom=paint})
}

// A row with a label in the column of labels and controls after it.
@(deferred_in=property_end)
property :: proc(ctx:^Context,text:string,height:f32=0) -> bool {
    th:=&ctx.theme
    element_open(ctx,{layout={width=GROW,height=fixed(height if height>0 else th.row),gap=4,align_y=.Center}})
    column_label(ctx,text)
    return true
}
@(private)
property_end :: proc(ctx:^Context,text:string,height:f32) {element_close(ctx)}

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
    th:=&ctx.theme
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
    fill:Color;text_color:=r.text_color if r.text_color!={} else th.text;detail_color:=th.text_faint;icon_color:=r.icon_color if r.icon_color!={} else th.text_muted
    if r.accent && (it.hot || keyed) {
        fill=th.accent;text_color=th.on_accent;detail_color=color_alpha(th.on_accent,190)
    } else if r.selected {fill=th.accent_soft} else if it.hot && !r.accent && !r.quiet {fill=th.field_hover}
    if r.disabled {text_color,detail_color,icon_color=color_faded(text_color),color_faded(detail_color),color_faded(icon_color)}
    paint:=Paint{kind=.Box,fill=fill,radius=th.radius_control,text=r.label,detail=r.detail,text_color=text_color,detail_color=detail_color,size=th.font_small,padding=8,icon=r.icon,icon_color=icon_color,icon_size=r.icon_size if r.icon_size>0 else 16,quad=r.quad,style={font=r.font}}
    if r.checked {paint.icon=.Check;paint.icon_color=th.on_accent if r.accent&&(it.hot || keyed) else th.accent;paint.icon_size=14} else if r.check_room {paint.padding=28}
    height:=r.height if r.height>0 else th.row
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

@(private)
tooltip_build :: proc(ctx:^Context) {
    th:=&ctx.theme
    width,height:=ctx.size.x,ctx.size.y
    mouse:=ctx.screen_pointer
    text:=text_width(&ctx.font,ctx.tooltip,th.font_small)+20
    w:=min(text,min(420,width-2*th.margin))
    x:=clamp(mouse.x+12,th.margin,max(width-w-th.margin,th.margin))
    y:=mouse.y+20 if mouse.y+48<height-th.margin else mouse.y-30
    y=clamp(y,th.bar_height+2,max(height-28,th.bar_height+2))
    ctx.surface=0;ctx.scope=0
    if text>w || strings.contains(ctx.tooltip,"\n") {
        above:=mouse.y>height*.5
        y=clamp(mouse.y-8 if above else mouse.y+20,th.bar_height+2,height-th.margin)
        if box(ctx,{id=id(ctx,"tooltip"),width=fixed(w),height=FIT,padding=padding_all(10),fill=th.popup,stroke=th.border,radius=th.radius_control,
                    float={to=.Surface,offset={x,y},pivot=.Bottom_Left if above else .Top_Left,layer=LAYER_TOOLTIP}}) {
            paragraph(ctx,ctx.tooltip,th.font_small,th.text)
        }
        return
    }
    paint:=paint_add(ctx,{kind=.Box,fill=th.popup,stroke=th.border,radius=th.radius_control,text=ctx.tooltip,text_color=th.text,size=th.font_small,center=true})
    declaration:=Element{layout={width=fixed(w),height=fixed(26)},custom=paint}
    declaration.float={to=.Root,offset={x,y},layer=LAYER_TOOLTIP}
    element_leaf(ctx,declaration)
}
