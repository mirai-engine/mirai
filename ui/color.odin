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
