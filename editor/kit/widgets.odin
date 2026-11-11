package kit

import "core:math"
import "core:strings"
import mm "mirai:std/math"
import "mirai:ui"

// A segment that stays lit while value is true; a click flips it.
toggle :: proc(ctx:^ui.Context,id:ui.Id,text:string,value:^bool,width:f32=-1,disabled:bool=false) -> (changed:bool) {
    it:=ui.button(ctx,id,{label=text,variant="tab",size=ui.metric(ctx,"font_small"),width=width,center=true,active=value^,disabled=disabled})
    if it.clicked {value^=!value^;changed=true}
    return
}

// A switch for a value that is on or off: the track fills with the accent while it is on.
toggle_switch :: proc(ctx:^ui.Context,id:ui.Id,value:^bool,disabled:bool=false) -> (changed:bool) {
    disabled:=disabled || ctx.disabled_depth>0
    it:=ui.interact(ctx,id,{.Focusable}+({.Disabled} if disabled else {}))
    if it.clicked {value^=!value^;changed=true}
    on:=value^
    fill:=ui.tone(ctx,"accent") if on else ui.color_alpha(ui.tone(ctx,"text"),46 if it.hot else 34)
    knob:=ui.tone(ctx,"on_accent") if on else ui.tone(ctx,"text_muted")
    if disabled {fill,knob=ui.color_faded(fill),ui.color_faded(knob)}
    paint:=ui.paint_add(ctx,{kind=.Switch,fill=fill,stroke=knob,value=1 if on else 0})
    ui.element_leaf(ctx,{id=id,layout={width=ui.fixed(29),height=ui.fixed(16)},custom=paint})
    return
}

// A title followed by a rule, with an optional remark at its right end.
section :: proc(ctx:^ui.Context,title:string,note:string="",note_width:f32=0) {
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(22),gap=8,align_y=.End}) {
        ui.label(ctx,title,ui.metric(ctx,"font_label"),ui.tone(ctx,"text_faint"))
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(9),align_y=.Center}) {ui.divider(ctx)}
        if note!="" {ui.label(ctx,note,ui.metric(ctx,"font_label"),ui.tone(ctx,"text_muted"),min(ui.text_width(&ctx.font,note,ui.metric(ctx,"font_label"))+1,note_width if note_width>0 else max(f32)))}
    }
}

Collapsible :: struct {
    note:string,
    note_color:ui.Color, // text_muted when transparent
    width:f32,        // what the title, the note and the remove button share; 0: do not cut them
    removable:bool,   // shows an x at the right end
}

Collapsible_Result :: struct {
    open:bool,    // build the rows of the section
    toggled:bool,
    removed:bool, // the x was clicked
}

// The title of a section that folds: a click on it shows or hides what follows.
collapsible :: proc(ctx:^ui.Context,id:ui.Id,title:string,open:^bool,c:Collapsible={}) -> (result:Collapsible_Result) {
    it:=ui.interact(ctx,id,{.Focusable})
    if it.clicked {open^=!open^;result.toggled=true}
    color:=ui.tone(ctx,"text_muted") if it.hot else ui.tone(ctx,"text_faint")
    room:=(c.width if c.width>0 else 100000)-16-(24 if c.removable else 0)
    note_width:=min(ui.text_width(&ctx.font,c.note,ui.metric(ctx,"font_label"))+1,room*0.6) if c.note!="" else 0
    title_width:=min(ui.text_width(&ctx.font,title,ui.metric(ctx,"font_label"))+1,max(room-note_width-22,24))
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(22),gap=6,align_y=.End}) {
        if ui.box(ctx,{width=ui.fixed(10),height=ui.fixed(ui.metric(ctx,"font_label")+6),align_x=.Center,align_y=.Center}) {
            ui.icon(ctx,.Chevron_Down if open^ else .Chevron_Right,color,10)
        }
        ui.label(ctx,title,ui.metric(ctx,"font_label"),color,title_width)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(9),align_y=.Center}) {ui.divider(ctx)}
        if c.note!="" {ui.label(ctx,c.note,ui.metric(ctx,"font_label"),c.note_color if c.note_color!={} else ui.tone(ctx,"text_muted"),note_width)}
        if c.removable {
            ui.id_push(ctx,id)
            result.removed=ui.button(ctx,ui.id(ctx,"remove"),{icon=.Cross,variant="ghost",width=18,height=18}).clicked
            ui.id_pop(ctx)
        }
    }
    result.open=open^
    return
}

// The frame of a segmented control: put buttons of style Tab inside.
@(deferred_in=segments_end)
segments :: proc(ctx:^ui.Context,width:ui.Size=ui.GROW,height:f32=30) -> bool {
    paint:=ui.paint_add(ctx,{kind=.Box,fill=ui.tone(ctx,"well"),stroke=ui.tone(ctx,"well_stroke"),radius=ui.metric(ctx,"radius_control")})
    ui.element_open(ctx,{layout={width=width,height=ui.fixed(height),padding=ui.padding_all(2),gap=2,align_y=.Center},custom=paint})
    return true
}

@(private)
segments_end :: proc(ctx:^ui.Context,width:ui.Size,height:f32) {ui.element_close(ctx)}

// Tabs as one segmented control. Returns true when the selection changed.
tabs :: proc(ctx:^ui.Context,id:ui.Id,titles:[]string,selected:^int,width:ui.Size=ui.GROW,height:f32=30) -> (changed:bool) {
    ui.id_push(ctx,id)
    defer ui.id_pop(ctx)
    if segments(ctx,width,height) {
        for title,index in titles {
            if ui.button(ctx,ui.id(ctx,"tab",index+1),{label=title,variant="tab",active=selected^==index,width=-1,height=height-4,size=ui.metric(ctx,"font_small"),center=true}).clicked && selected^!=index {
                selected^=index;changed=true
            }
        }
    }
    return
}

// A color as an input: its swatch alone. rgb: display space.
color_swatch :: proc(ctx:^ui.Context,id:ui.Id,rgb:[3]f32,open:bool=false,width:f32=0,height:f32=0) -> ui.Interaction {
    it:=ui.interact(ctx,id,{.Focusable})
    paint:=ui.paint_add(ctx,{kind=.Swatch,fill=ui.rgb_color(rgb),stroke=ui.tone(ctx,"accent") if open||it.hot else ui.tone(ctx,"border")})
    ui.element_leaf(ctx,{id=id,layout={width=(ui.fixed(width) if width>0 else ui.GROW),height=ui.fixed(height if height>0 else ui.metric(ctx,"row"))},custom=paint})
    return it
}

// A color as a swatch followed by its channels. rgb: display space, 0 to 1.
// Returns what happened to the channels and what the pointer did to the swatch.
color_field :: proc(ctx:^ui.Context,id:ui.Id,rgb:^[3]f32,open:bool=false) -> (result:ui.Number_Result,swatch:ui.Interaction) {
    ui.id_push(ctx,id)
    defer ui.id_pop(ctx)
    swatch=color_swatch(ctx,ui.id(ctx,"swatch"),rgb^,open,ui.metric(ctx,"row"))
    values:=[3]f64{f64(rgb.r),f64(rgb.g),f64(rgb.b)}
    result,_=vector_field(ctx,ui.id(ctx,"channels"),values[:],{number={decimals=2,speed=0.004,min=0,max=1,has_min=true,has_max=true},channels=true})
    if result.changed {rgb^={f32(values[0]),f32(values[1]),f32(values[2])}}
    return
}

// The label of a row in the column of labels, the same width in every row
// so the controls after it line up; one too long ends in an ellipsis.
column_label :: proc(ctx:^ui.Context,content:string,color:ui.Color={}) {
    ui.text(ctx,content,{size=ui.metric(ctx,"font_small"),color=color if color!={} else ui.tone(ctx,"text_label"),align_y=.Center,ellipsis=true},ui.fixed(ui.metric(ctx,"label_width")),ui.fixed(ui.metric(ctx,"font_small")+6))
}

// A row with a label in the column of labels and controls after it.
@(deferred_in=property_end)
property :: proc(ctx:^ui.Context,text:string,height:f32=0) -> bool {
    ui.element_open(ctx,{layout={width=ui.GROW,height=ui.fixed(height if height>0 else ui.metric(ctx,"row")),gap=4,align_y=.Center}})
    column_label(ctx,text)
    return true
}

@(private)
property_end :: proc(ctx:^ui.Context,text:string,height:f32) {ui.element_close(ctx)}
