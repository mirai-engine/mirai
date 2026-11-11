package kit

import "core:math"
import "core:strings"
import mm "mirai:std/math"
import "mirai:ui"

// A slider of the editor followed by the field that types its value. Without
// a finite range it is the field alone.
slider_field :: proc(ctx:^ui.Context,id:ui.Id,value:^f64,field:ui.Number_Field={}) -> (result:ui.Number_Result) {
    span:=field.max-field.min
    if !field.has_min || !field.has_max || field.max<=field.min || math.is_nan(span) || math.is_inf(span) || math.is_nan(value^) || math.is_inf(value^) {
        return ui.number_field(ctx,id,value,field)
    }
    height:=ui.fixed(field.height if field.height>0 else ui.metric(ctx,"row"))
    if ui.box(ctx,{width=field.width if field.width!={} else ui.GROW,height=height,gap=5,align_y=.Center}) {
        result=ui.slider(ctx,ui.id_derive(ctx,id,"track"),value,{min=field.min,max=field.max,integer=field.integer,key_step=field.speed if field.speed>0 else span/100,height=height,disabled=field.disabled})
        if !field.bare {
            number:=field
            number.width,number.typed_only=ui.fixed(46+(ui.text_width(&ctx.font,field.unit,ui.FIELD_UNIT)+4 if field.unit!="" else 0)),true
            typed:=ui.number_field(ctx,ui.id_derive(ctx,id,"number"),value,number)
            result.changed|=typed.changed
            result.began|=typed.began
            result.ended|=typed.ended
            result.cancelled|=typed.cancelled
            result.editing,result.invalid,result.tab=typed.editing,typed.invalid,typed.tab
        }
    }
    return
}

Vector_Field :: struct {
    using number:ui.Number_Field, // what every axis shares; the strip comes from the axis
    channels:bool,   // R, G, B, A with the channel colors instead of X, Y, Z, W
    mixed_axes:[4]bool,
}

// One number field per value, to be placed in a row. axis: the one the result
// is about, or -1 when nothing happened.
vector_field :: proc(ctx:^ui.Context,id:ui.Id,values:[]f64,field:Vector_Field={}) -> (result:ui.Number_Result,axis:int) {
    axis=-1
    count:=min(len(values),4)
    ui.id_push(ctx,id)
    defer ui.id_pop(ctx)
    for i in 0..<count {
        one:=field.number
        one.strip=ui.tone(ctx,CHANNEL_TOKENS[i]) if field.channels else ui.tone(ctx,AXIS_TOKENS[i])
        one.mixed=field.mixed_axes[i] || field.number.mixed
        r:=ui.number_field(ctx,ui.id(ctx,"axis",i+1),&values[i],one)
        // Tab moves to the next component of the same property.
        if r.tab>0 && i+1<count {ui.edit_request(ctx,ui.id(ctx,"axis",i+2))}
        if r.tab<0 && i>0 {ui.edit_request(ctx,ui.id(ctx,"axis",i))}
        if r!={} && (axis<0 || r.changed || r.began || r.ended) {result,axis=r,i}
    }
    return
}

AXIS_NAMES :: [4]string{"X","Y","Z","W"}
CHANNEL_NAMES :: [4]string{"R","G","B","A"}
// The tokens of the theme the strips of the fields of a vector and of a color take.
@(rodata)
AXIS_TOKENS := [4]string{"axis_x","axis_y","axis_z","axis_w"}
@(rodata)
CHANNEL_TOKENS := [4]string{"channel_r","channel_g","channel_b","channel_a"}
