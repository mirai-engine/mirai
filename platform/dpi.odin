package platform

import "core:math"
import sdl "vendor:sdl3"

@(private)
Display_Scale :: struct {content,pixel,coordinate:f32}

@(private)
display_scale :: proc "contextless" (content,pixel:f32) -> Display_Scale {
    density:=pixel
    if !(density>0) || math.is_inf(density) {density=1}
    display:=content
    if !(display>0) || math.is_inf(display) {display=density}
    return {display,density,display/density}
}

@(private)
window_scale :: proc(window:^sdl.Window) -> Display_Scale {
    if window==nil {return {1,1,1}}
    return display_scale(sdl.GetWindowDisplayScale(window),sdl.GetWindowPixelDensity(window))
}

@(private)
window_native_extent :: proc "contextless" (points:i32,scale:f32) -> i32 {
    return i32(math.ceil(f32(points)*scale))
}

@(private)
window_point :: proc "contextless" (p:^Platform,point:[2]f32) -> [2]f32 {
    scale:=p.window.coordinate_scale
    return point/scale if scale>0 else point
}

@(private)
window_metrics_apply :: proc(p:^Platform,frame:^Window_Frame,native,pixels:[2]i32,scale:Display_Scale) {
    w:=&p.window
    previous:=w.coordinate_scale
    if previous>0 && previous!=scale.coordinate {
        factor:=previous/scale.coordinate
        if p.input.frame.mouse_position!=MOUSE_OUTSIDE {p.input.frame.mouse_position*=factor}
        if p.input.live.mouse_position!=MOUSE_OUTSIDE {p.input.live.mouse_position*=factor}
        if p.input.tick.mouse_position!=MOUSE_OUTSIDE {p.input.tick.mouse_position*=factor}
        if !w.relative_mouse {
            p.input.frame.mouse_delta*=factor
            p.input.live.mouse_delta*=factor
            p.input.tick.mouse_delta*=factor
        }
        if w.handle!=nil {
            _=sdl.SetWindowMinimumSize(w.handle,window_native_extent(w.minimum.x,scale.coordinate),window_native_extent(w.minimum.y,scale.coordinate))
        }
    }
    w.coordinate_scale=scale.coordinate
    frame.size={i32(math.round(f32(native.x)/scale.coordinate)),i32(math.round(f32(native.y)/scale.coordinate))}
    frame.pixel_size={max(pixels.x,0),max(pixels.y,0)}
    frame.density=scale.content
    frame.pixel_density=scale.pixel
}
