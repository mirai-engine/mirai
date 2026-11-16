package kit

import "core:math"
import "core:strings"
import mm "mirai:std/math"
import "mirai:ui"

// The color a picker is on. Hue, saturation and value are kept, so a gray
// does not forget its hue.
Color_Picker :: struct {hsv:[3]f32}

color_picker_set :: proc "contextless" (p:^Color_Picker,rgb:[3]f32) {
    hue:=p.hsv[0]
    p.hsv=mm.rgb_to_hsv({clamp(rgb.r,0,1),clamp(rgb.g,0,1),clamp(rgb.b,0,1)})
    if p.hsv[1]==0 {p.hsv[0]=hue}
}

// Display space, 0 to 1.
color_picker_rgb :: proc "contextless" (p:^Color_Picker) -> [3]f32 {return mm.hsv_to_rgb(p.hsv)}

Color_Picker_Result :: struct {
    changed:bool,
    began:bool, // a drag or an edit began this frame
    ended:bool,
}

// The square of saturation and value, the bar of hues, the code and the
// channels of a color, all showing the same color. width: of the column it
// is built in.
color_picker :: proc(ctx:^ui.Context,id:ui.Id,p:^Color_Picker,width:f32=216) -> (result:Color_Picker_Result) {
    ui.id_push(ctx,id)
    defer ui.id_pop(ctx)
    before:=p.hsv
    drag :: proc(ctx:^ui.Context,area:ui.Id,result:^Color_Picker_Result) -> (u,v:f32,held:bool) {
        it:=ui.interact(ctx,area)
        if it.pressed {result.began=true}
        if it.released {result.ended=true}
        r,found:=ui.widget_rect(ctx,area)
        if !it.active || !found || r.w<=0 || r.h<=0 {return}
        return clamp((ctx.pointer.x-r.x)/r.w,0,1),clamp((ctx.pointer.y-r.y)/r.h,0,1),true
    }
    sv:=ui.id(ctx,"sv")
    if u,v,held:=drag(ctx,sv,&result);held {p.hsv[1]=u;p.hsv[2]=1-v}
    ui.element_leaf(ctx,{id=sv,layout={width=ui.GROW,height=ui.fixed(150)},custom=ui.paint_add(ctx,{kind=.Sat_Value,hsv=p.hsv})})
    hue:=ui.id(ctx,"hue")
    if u,_,held:=drag(ctx,hue,&result);held {p.hsv[0]=min(u,0.9999)}
    ui.element_leaf(ctx,{id=hue,layout={width=ui.GROW,height=ui.fixed(14)},custom=ui.paint_add(ctx,{kind=.Hue,hsv=p.hsv})})
    channels:=ui.rgb_color(color_picker_rgb(p))
    column:=(width-2*4)/3
    // The picked color stands over the first channel; its code, over the other two.
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=4,align_y=.Center}) {
        swatch:=ui.paint_add(ctx,{kind=.Swatch,fill=channels,stroke=ui.tone(ctx,"border")})
        ui.element_leaf(ctx,{layout={width=ui.fixed(column),height=ui.fixed(ui.metric(ctx,"row"))},custom=swatch})
        buffer:[8]u8
        digits:="0123456789ABCDEF"
        buffer[0]='#'
        for channel,i in channels.rgb {buffer[1+i*2]=digits[channel>>4];buffer[2+i*2]=digits[channel&15]}
        length:=7
        r:=ui.text_field(ctx,ui.id(ctx,"hex"),buffer[:],&length,{filter=.Hex})
        if r.began {result.began=true}
        if r.committed || r.cancelled {result.ended=true}
        if r.changed {
            if rgb,ok:=ui.hex_color(string(buffer[:length]));ok {color_picker_set(p,{f32(rgb.r)/255,f32(rgb.g)/255,f32(rgb.b)/255})}
        }
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=4,align_y=.Center}) {
        values:=[3]f64{f64(channels.r),f64(channels.g),f64(channels.b)}
        r,axis:=vector_field(ctx,ui.id(ctx,"channels"),values[:],{number={integer=true,typed_only=true,min=0,max=255,has_min=true,has_max=true},channels=true})
        if r.began {result.began=true}
        if r.ended {result.ended=true}
        // Typing a channel keeps the other two.
        if r.changed && axis>=0 {color_picker_set(p,{f32(values[0])/255,f32(values[1])/255,f32(values[2])/255})}
    }
    result.changed=p.hsv!=before
    return
}
