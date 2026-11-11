package ui

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// Number fields and sliders, of the editor and of a game. In a field a drag
// scrubs the value, a click types it with all of it selected and a double
// click puts the caret where it lands; while it is typed a drag selects part
// of it. Vectors and colors are rows of fields with a colored mark per axis.

@(private)
Scrub :: struct {
    id:Id,
    origin:f64, // the value when the button went down: every step starts from it
    moved:bool, // the pointer left the click tolerance, so it is a scrub
}

SCRUB_TOLERANCE :: f32(3)
// Decimals of the text a number is typed from.
NUMBER_EDIT_DECIMALS :: 5

Number_Field :: struct {
    width:Size,      // GROW when unset
    height:f32,      // the row of the theme when 0
    size:f32,        // text size; font_small when 0
    label:string,    // short text inside the field, before its value
    icon:Icon,       // an icon there instead of the label
    strip:Color,     // axis color on its left edge
    unit:string,     // at the right end of the field: °, ms, Hz
    decimals:int,    // shown; 0 means 3
    integer:bool,    // whole values, shown without decimals
    speed:f64,       // value per unit dragged; 0 means 0.01
    min,max:f64,     // limits, applied when has_min and has_max
    has_min,has_max:bool,
    mixed:bool,      // several objects with different values: shows "Multiple"
    typed_only:bool, // a press types; dragging does nothing
    bare:bool,       // a slider: its track alone, without the field that types the value
    disabled:bool,
    step:f64,        // the value snaps to it, from min when it has one; 0: any
    // Two arrows at its ends step it by step (one without it), as left and
    // right do while it has the focus; a press on its text types it.
    stepper:bool,
    // What it is drawn with, resolved for the state it is in: fill, stroke,
    // corners and text, its mark for the selection and the arrows. nil: the
    // theme. With a look it is ten sizes of its text wide and a line with its
    // room tall, and the press that types it places the caret.
    look:^Node_Style,
}
Number_Result :: struct {
    changed:bool,   // value^ changed this frame
    editing:bool,
    scrubbing:bool,
    began:bool,     // a scrub or an edit began this frame: the last moment before the value changes
    ended:bool,     // the scrub or the edit ended this frame
    cancelled:bool, // Escape: value^ is back to what it was when it began
    invalid:bool,   // the typed text is not a number; value^ keeps its value
    tab:int,        // 1 or -1 when Tab or Shift+Tab ended the edit
}

// Shortest readable form of a number with at most `decimals` decimals, kept
// until the frame is drawn.
number_text :: proc(ctx:^Context,value:f64,decimals:int=3) -> string {
    buffer:=text_reserve(ctx,48)
    if buffer==nil {return ""}
    return text_commit(ctx,number_format(buffer,value,decimals))
}
number_format :: proc(buffer:[]u8,value:f64,decimals:int=3) -> string {
    if math.is_nan(value) {return fmt.bprintf(buffer,"nan")}
    if math.is_inf(value) {return fmt.bprintf(buffer,"inf" if value>0 else "-inf")}
    text:=fmt.bprintf(buffer,"%.*f",clamp(decimals,0,9),value)
    if strings.contains_rune(text,'.') {text=strings.trim_right(strings.trim_right(text,"0"),".")}
    if text=="-0" {return "0"}
    return text
}

@(private)
number_limit :: proc(field:Number_Field,value:f64) -> f64 {
    v:=value
    if field.step>0 {
        base:=field.min if field.has_min else 0
        v=base+math.round((v-base)/field.step)*field.step
    }
    if field.integer {v=math.round(v)}
    if field.has_min {v=max(v,field.min)}
    if field.has_max {v=min(v,field.max)}
    return v
}

number_field :: proc(ctx:^Context,id:Id,value:^f64,field:Number_Field={}) -> (result:Number_Result) {
    field:=field
    field.disabled|=ctx.disabled_depth>0
    field.typed_only|=field.stepper
    e:=&ctx.edit
    s:=&ctx.scrub
    if field.disabled {
        if e.id==id && id!=0 {e^={};result.ended,result.cancelled=true,true}
        if s.id==id && id!=0 {s^={};result.ended,result.cancelled=true,true}
    }
    look:=field.look
    size:=field.size if field.size>0 else metric(ctx,"font_small")
    width:=field.width if field.width!={} else GROW
    height:=field.height if field.height>0 else metric(ctx,"row")
    em:=metric(ctx,"font")
    font:u8
    pad:f32
    if look!=nil {
        em=control_em(ctx,look)
        if look.text.size>0 {size=look.text.size}
        font=look.text.font
        if field.width=={} {width=fixed(em*GAME_WIDTH)}
        if field.height<=0 {height=em*TEXT_LINE+2*em*GAME_PAD}
        pad=em*GAME_PAD
    }
    side:f32
    if field.stepper {
        side=control_height(ctx,id,fixed(height),height)
        pad=side
    }
    decimals:=0 if field.integer else (field.decimals if field.decimals>0 else 3)
    it:=interact(ctx,id,{.Focusable}+({.Disabled} if field.disabled else {})+({.Adjusts} if field.stepper else {}))
    begin_edit:=false
    if e.id==id && id!=0 {
        event,tab:=field_edit_update(ctx,id,it,size,field.label,false,field.strip[3]>0,pad,font,field.icon)
        #partial switch event {
        case .Commit:
            text:=strings.trim_space(text_edit_value(e))
            if e.modified {
                number,ok:=strconv.parse_f64(text)
                if ok && !math.is_nan(number) && !math.is_inf(number) {
                    if limited:=number_limit(field,number);limited!=value^ {value^=limited;result.changed=true}
                } else if text!="" {result.invalid=true}
            }
            e^={}
            result.ended=true;result.tab=tab
            if tab!=0 && ctx.navigation {
                if next:=focus_peek(ctx,id,tab);next!=0 {ctx.focus=next;ctx.focus_ring=true;edit_request(ctx,next)}
            }
        case .Cancel:
            e^={}
            result.cancelled=true;result.ended=true
            ctx.escape_used=true
        }
    } else if !field.disabled && id!=0 {
        if it.pressed {
            if field.typed_only {begin_edit=true} else {s^={id=id,origin=value^}}
        } else if ctx.activate==id || ctx.edit_request==id {begin_edit=true}
        if s.id==id {
            delta:=ctx.pointer.x-ctx.press.x
            if !s.moved && abs(delta)>SCRUB_TOLERANCE {s.moved=true;result.began=true}
            if s.moved {
                // Always from the value the scrub began with, so it never drifts.
                speed:=(field.speed if field.speed>0 else 0.01)*(0.1 if .Shift in ctx.input.modifiers else 1)
                if next:=number_limit(field,s.origin+f64(delta)*speed);next!=value^ {value^=next;result.changed=true}
                if .Escape in ctx.input.keys_pressed {
                    if value^!=s.origin {value^=s.origin;result.changed=true}
                    result.cancelled=true;result.ended=true
                    s^={}
                    ctx.escape_used=true
                    if ctx.active==id {ctx.active=0}
                }
            }
            if s.id==id && (it.released || !it.active) {
                // A click without dragging types the value instead.
                if s.moved {result.ended=true} else if it.released {begin_edit=true}
                s^={}
            }
        }
        if begin_edit {
            buffer:[48]u8
            field_edit_begin(ctx,id,number_format(buffer[:],value^,0 if field.integer else NUMBER_EDIT_DECIMALS),.Number,TEXT_EDIT_CAPACITY,look==nil)
            e.font=font
            if look!=nil && it.pressed {
                if rect,found:=widget_rect(ctx,id);found {text_edit_press(ctx,e,size,field_text_area(ctx,rect,field.label,size,false,field.strip[3]>0,pad,field.icon))}
            }
            result.began=true
        }
        if it.hot || s.id==id {ctx.cursor=.Text if e.id==id || field.typed_only else .Resize_Horizontal}
    }
    result.editing=e.id==id && id!=0
    result.scrubbing=s.id==id && s.moved && id!=0
    text:="Multiple" if field.mixed else number_text(ctx,value^,decimals)
    paint:=field_paint(ctx,id,it,text,size,field.label,field.strip,"",s.id==id && id!=0,field.disabled,field.icon)
    if paint!=nil {
        paint.detail=field.unit
        paint.padding=pad
        paint.style.font=font
        if look!=nil {field_paint_look(paint,look)}
    }
    element:=Element{id=id,layout={width=width,height=fixed(height)},custom=paint}
    if !field.stepper {
        element_leaf(ctx,element)
        return
    }
    by:=field.step if field.step>0 else 1
    next:=value^
    mark:=look.mark if look!=nil else tone(ctx,"text_muted")
    element.layout.direction,element.layout.align_y=.Row,.Center
    if element_open(ctx,element) {
        if control_arrow(ctx,id_derive(ctx,id,"previous"),0,side,em,mark,field.disabled) {next-=by}
        element_leaf(ctx,{layout={width=GROW,height=GROW}})
        if control_arrow(ctx,id_derive(ctx,id,"next"),1,side,em,mark,field.disabled) {next+=by}
    }
    element_close(ctx)
    if !field.disabled && e.id!=id {next+=f64(control_step(ctx,ctx.focus==id))*by}
    if next!=value^ {
        if limited:=number_limit(field,next);limited!=value^ {value^=limited;result.changed=true}
    }
    return
}

// A field of a game takes its fill, stroke, corners and text from its look,
// its selection from the mark (or its text at a quarter) and its placeholder
// from its text at half.
@(private)
field_paint_look :: proc "contextless" (paint:^Paint,look:^Node_Style) {
    text:=look.text.color
    paint.fill,paint.stroke,paint.stroke_width,paint.corners,paint.text_color=look.fill,look.stroke,look.stroke_width,look.radius,text
    paint.fill2=look.mark if look.mark[3]>0 else color_alpha(text,text[3]/4)
    paint.faint=color_alpha(text,text[3]/2)
}

Slider :: struct {
    min,max:f64,       // with max not over min it spans one from min
    step:f64,          // the value snaps to it from min; 0: any
    integer:bool,      // whole values
    key_step:f64,      // what left and right move it by; 0: its step, or a twentieth of its range
    width,height:Size, // unset: what is left wide and the row of the theme tall, or as its look says
    // Its track, the part of it up to the value (mark) and its knob, resolved
    // for the state it is in: the knob is as tall as the slider, over a track
    // a third of that, and without a size it is ten sizes of its text wide and
    // a line with its room tall. nil: the slider of the theme.
    look:^Node_Style,
    disabled:bool,
}
SLIDER_KNOB :: f32(12) // of a slider of the theme: the diameter of its knob
SLIDER_TRACK :: f32(4) // and the thickness of its track

// A slider: the pointer drags its knob, and Escape puts back the value the
// drag began with; left and right step it while it has the focus. The value
// changes only then.
slider :: proc(ctx:^Context,id:Id,value:^f64,sl:Slider) -> (result:Number_Result) {
    lo,hi:=sl.min,sl.max
    if hi<=lo {hi=lo+1}
    disabled:=sl.disabled || ctx.disabled_depth>0
    s:=&ctx.scrub
    if disabled && s.id==id && id!=0 {
        s^={}
        result.ended,result.cancelled=true,true
    }
    it:=interact(ctx,id,{.Focusable,.Adjusts}+({.Disabled} if disabled else {}))
    themed:Node_Style
    look:=sl.look
    width,height:=sl.width,sl.height
    knob,track:=SLIDER_KNOB,SLIDER_TRACK
    if look==nil {
        themed.track,themed.mark,themed.knob=tone(ctx,"rule"),tone(ctx,"accent_soft") if disabled else tone(ctx,"accent"),tone(ctx,"text_faint") if disabled else tone(ctx,"text")
        look=&themed
        if width=={} {width=GROW}
        if height=={} {height=fixed(metric(ctx,"row"))}
    } else {
        line:f32
        width,height,line=control_size(ctx,width,height,look,GAME_WIDTH)
        knob=control_height(ctx,id,height,line)
        track=knob/3
    }
    next:=value^
    moved,keyed:=false,false
    if it.pressed {
        s^={id=id,origin=value^,moved=true}
        result.began=true
    }
    if s.id==id && id!=0 {
        result.scrubbing=true
        if r,found:=widget_rect(ctx,id);found && r.w>knob {
            next=lo+f64(clamp((ctx.pointer.x-r.x-knob*0.5)/(r.w-knob),0,1))*(hi-lo)
            moved=true
        }
        if .Escape in ctx.input.keys_pressed {
            if value^!=s.origin {value^=s.origin;result.changed=true}
            result.cancelled,result.ended=true,true
            s^={}
            ctx.escape_used=true
            if ctx.active==id {ctx.active=0}
            moved=false
        } else if it.released || !it.active {
            result.ended=true
            s^={}
        }
    } else if direction:=control_step(ctx,it.focused);direction!=0 && ctx.edit.id==0 {
        amount:=sl.key_step if sl.key_step>0 else (sl.step if sl.step>0 else (hi-lo)/20)
        if sl.step<=0 && .Shift in ctx.input.modifiers {amount*=0.1}
        if sl.integer {amount=max(amount,1)}
        next+=f64(direction)*amount
        moved,keyed=true,true
    }
    if moved {
        if sl.step>0 {next=lo+math.round((next-lo)/sl.step)*sl.step}
        if sl.integer {next=math.round(next)}
        next=clamp(next,lo,hi)
        if next!=value^ {
            value^=next
            result.changed=true
            if keyed {result.began,result.ended=true,true}
        }
    }
    paint:=Paint{kind=.Slider,value=f32(clamp((value^-lo)/(hi-lo),0,1)),fill=look.track,fill2=look.mark,stroke=look.knob,radius=knob*0.5,stroke_width=track,corners=look.radius}
    element_leaf(ctx,{id=id,layout={width=width,height=height},custom=paint_add(ctx,paint)})
    return
}
