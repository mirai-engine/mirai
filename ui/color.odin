package ui

import mm "mirai:std/math"

// Colors of widgets are display (sRGB) values; scene colors are linear. A
// swatch or a picker converts at its edge.

rgb_color :: proc "contextless" (rgb:[3]f32,alpha:u8=255) -> Color {
    return {u8(clamp(rgb.r,0,1)*255+0.5),u8(clamp(rgb.g,0,1)*255+0.5),u8(clamp(rgb.b,0,1)*255+0.5),alpha}
}
display_color :: proc "contextless" (linear:[3]f32) -> [3]f32 {
    return {mm.linear_to_srgb(clamp(linear.x,0,1)),mm.linear_to_srgb(clamp(linear.y,0,1)),mm.linear_to_srgb(clamp(linear.z,0,1))}
}
linear_color :: proc "contextless" (display:[3]f32) -> [3]f32 {
    return {mm.srgb_to_linear(clamp(display.x,0,1)),mm.srgb_to_linear(clamp(display.y,0,1)),mm.srgb_to_linear(clamp(display.z,0,1))}
}

// "#RRGGBB", with or without the '#'.
hex_color :: proc "contextless" (text:string) -> (rgb:[3]u8,ok:bool) {
    digits:=text
    if len(digits)>0 && digits[0]=='#' {digits=digits[1:]}
    if len(digits)!=6 {return}
    for i in 0..<6 {
        c:=digits[i];value:u8
        switch c {
        case '0'..='9':value=c-'0'
        case 'a'..='f':value=c-'a'+10
        case 'A'..='F':value=c-'A'+10
        case:return {},false
        }
        rgb[i/2]=rgb[i/2]*16+value
    }
    return rgb,true
}

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
color_picker :: proc(ctx:^Context,id:Id,p:^Color_Picker,width:f32=216) -> (result:Color_Picker_Result) {
    th:=&ctx.theme
    id_push(ctx,id)
    defer id_pop(ctx)
    before:=p.hsv
    drag :: proc(ctx:^Context,area:Id,result:^Color_Picker_Result) -> (u,v:f32,held:bool) {
        it:=interact(ctx,area)
        if it.pressed {result.began=true}
        if it.released {result.ended=true}
        r,found:=widget_rect(ctx,area)
        if !it.active || !found || r.w<=0 || r.h<=0 {return}
        return clamp((ctx.pointer.x-r.x)/r.w,0,1),clamp((ctx.pointer.y-r.y)/r.h,0,1),true
    }
    sv:=ui_id(ctx,"sv")
    if u,v,held:=drag(ctx,sv,&result);held {p.hsv[1]=u;p.hsv[2]=1-v}
    element_leaf(ctx,{id=sv,layout={width=GROW,height=fixed(150)},custom=paint_add(ctx,{kind=.Sat_Value,hsv=p.hsv})})
    hue:=ui_id(ctx,"hue")
    if u,_,held:=drag(ctx,hue,&result);held {p.hsv[0]=min(u,0.9999)}
    element_leaf(ctx,{id=hue,layout={width=GROW,height=fixed(14)},custom=paint_add(ctx,{kind=.Hue,hsv=p.hsv})})
    channels:=rgb_color(color_picker_rgb(p))
    column:=(width-2*4)/3
    // The picked color stands over the first channel; its code, over the other two.
    if box(ctx,{width=GROW,height=fixed(th.row),gap=4,align_y=.Center}) {
        swatch:=paint_add(ctx,{kind=.Swatch,fill=channels,stroke=th.border})
        element_leaf(ctx,{layout={width=fixed(column),height=fixed(th.row)},custom=swatch})
        buffer:[8]u8
        digits:="0123456789ABCDEF"
        buffer[0]='#'
        for channel,i in channels.rgb {buffer[1+i*2]=digits[channel>>4];buffer[2+i*2]=digits[channel&15]}
        length:=7
        r:=text_field(ctx,ui_id(ctx,"hex"),buffer[:],&length,{filter=.Hex})
        if r.began {result.began=true}
        if r.committed || r.cancelled {result.ended=true}
        if r.changed {
            if rgb,ok:=hex_color(string(buffer[:length]));ok {color_picker_set(p,{f32(rgb.r)/255,f32(rgb.g)/255,f32(rgb.b)/255})}
        }
    }
    if box(ctx,{width=GROW,height=fixed(th.row),gap=4,align_y=.Center}) {
        values:=[3]f64{f64(channels.r),f64(channels.g),f64(channels.b)}
        r,axis:=vector_field(ctx,ui_id(ctx,"channels"),values[:],{number={integer=true,typed_only=true,min=0,max=255,has_min=true,has_max=true},channels=true})
        if r.began {result.began=true}
        if r.ended {result.ended=true}
        // Typing a channel keeps the other two.
        if r.changed && axis>=0 {color_picker_set(p,{f32(values[0])/255,f32(values[1])/255,f32(values[2])/255})}
    }
    result.changed=p.hsv!=before
    return
}
