package mirai_math

import "core:math"
import "core:math/linalg"

// Colors are linear RGB in a Vec3, or with alpha in a Vec4: what the schema
// flag .Color describes and what lighting computes with. sRGB is the encoding
// of files, hex codes and 8-bit displays.

srgb_to_linear :: proc{srgb_to_linear_scalar,srgb_to_linear_rgb,srgb_to_linear_rgba}
linear_to_srgb :: proc{linear_to_srgb_scalar,linear_to_srgb_rgb,linear_to_srgb_rgba}

srgb_to_linear_scalar :: proc "contextless" (value:f32) -> f32 {
    return math.pow((value+0.055)/1.055,2.4) if value>0.04045 else value/12.92
}
linear_to_srgb_scalar :: proc "contextless" (value:f32) -> f32 {
    return 1.055*math.pow(value,1.0/2.4)-0.055 if value>0.0031308 else 12.92*value
}
srgb_to_linear_rgb :: linalg.vector3_srgb_to_linear_f32
linear_to_srgb_rgb :: linalg.vector3_linear_to_srgb_f32
// Alpha is not encoded: it stays as it is.
srgb_to_linear_rgba :: linalg.vector4_srgb_to_linear_f32
linear_to_srgb_rgba :: linalg.vector4_linear_to_srgb_f32

// Hue, saturation and value, each from 0 to 1; the hue is a fraction of a turn.
hsv_to_rgb :: proc "contextless" (hsv:Vec3) -> Vec3 {
    hue:=(hsv.x-math.floor(hsv.x))*6
    sector:=int(hue)
    fraction:=hue-f32(sector)
    v:=hsv.z
    p,q,t:=v*(1-hsv.y),v*(1-hsv.y*fraction),v*(1-hsv.y*(1-fraction))
    switch sector {
    case 0: return {v,t,p}
    case 1: return {q,v,p}
    case 2: return {p,v,t}
    case 3: return {p,q,v}
    case 4: return {t,p,v}
    }
    return {v,p,q}
}
// A gray has hue 0.
rgb_to_hsv :: proc "contextless" (rgb:Vec3) -> Vec3 {
    high,low:=max(rgb.x,rgb.y,rgb.z),min(rgb.x,rgb.y,rgb.z)
    range:=high-low
    if range<=0 {return {0,0,high}}
    hue:f32
    switch {
    case high==rgb.x: hue=(rgb.y-rgb.z)/range+(6 if rgb.y<rgb.z else 0)
    case high==rgb.y: hue=(rgb.z-rgb.x)/range+2
    case:             hue=(rgb.x-rgb.y)/range+4
    }
    return {hue/6,range/high,high}
}
// Hue, saturation and lightness, each from 0 to 1.
hsl_to_rgb :: proc "contextless" (hsl:Vec3) -> Vec3 {
    return linalg.vector4_hsl_to_rgb_f32(hsl.x-math.floor(hsl.x),hsl.y,hsl.z).xyz
}
rgb_to_hsl :: proc "contextless" (rgb:Vec3) -> Vec3 {
    return linalg.vector4_rgb_to_hsl_f32({rgb.x,rgb.y,rgb.z,1}).xyz
}

// OKLab: lightness, green-red and blue-yellow, in a space where equal
// distances look like equal differences. Mixing there keeps hue and
// brightness even, where mixing linear RGB darkens or grays the middle.
linear_to_oklab :: proc "contextless" (c:Vec3) -> Vec3 {
    l:=math.cbrt(0.4122214708*c.x+0.5363325363*c.y+0.0514459929*c.z)
    m:=math.cbrt(0.2119034982*c.x+0.6806995451*c.y+0.1073969566*c.z)
    s:=math.cbrt(0.0883024619*c.x+0.2817188376*c.y+0.6299787005*c.z)
    return {
        0.2104542553*l+0.7936177850*m-0.0040720468*s,
        1.9779984951*l-2.4285922050*m+0.4505937099*s,
        0.0259040371*l+0.7827717662*m-0.8086757660*s,
    }
}
oklab_to_linear :: proc "contextless" (lab:Vec3) -> Vec3 {
    l:=lab.x+0.3963377774*lab.y+0.2158037573*lab.z
    m:=lab.x-0.1055613458*lab.y-0.0638541728*lab.z
    s:=lab.x-0.0894841775*lab.y-1.2914855480*lab.z
    l,m,s=l*l*l,m*m*m,s*s*s
    return {
        +4.0767416621*l-3.3077115913*m+0.2309699292*s,
        -1.2684380046*l+2.6097574011*m-0.3413193965*s,
        -0.0041960863*l-0.7034186147*m+1.7076147010*s,
    }
}
// Mixes two linear colors through OKLab. Alpha mixes linearly.
color_mix_oklab :: proc "contextless" (a,b:Vec4,t:f32) -> Vec4 {
    mixed:=oklab_to_linear(lerp(linear_to_oklab(a.xyz),linear_to_oklab(b.xyz),t))
    return {mixed.x,mixed.y,mixed.z,a.w+(b.w-a.w)*t}
}

Gradient_Stop :: struct {
    position:f32,
    color:Vec4, // linear, with alpha
}
Gradient_Space :: enum u8 {Linear,Oklab}

// The color of a gradient whose stops are sorted by position. Before the
// first stop and after the last one it holds their colors.
gradient_evaluate :: proc "contextless" (stops:[]Gradient_Stop,position:f32,space:=Gradient_Space.Linear) -> Vec4 {
    if len(stops)==0 {return {}}
    if position<=stops[0].position {return stops[0].color}
    last:=len(stops)-1
    if position>=stops[last].position {return stops[last].color}
    low,high:=0,last
    for high-low>1 {
        middle:=(low+high)>>1
        if stops[middle].position<=position {low=middle} else {high=middle}
    }
    a,b:=stops[low],stops[high]
    span:=b.position-a.position
    t:=(position-a.position)/span if span>0 else 1
    if space==.Oklab {return color_mix_oklab(a.color,b.color,t)}
    return a.color+(b.color-a.color)*t
}

// Four 8-bit channels in one integer, red in the lowest byte: the layout of
// vertex colors and RGBA8 textures.
rgba8_pack :: proc "contextless" (c:Vec4) -> u32 {
    return u32(unorm8_pack(c.x))|u32(unorm8_pack(c.y))<<8|u32(unorm8_pack(c.z))<<16|u32(unorm8_pack(c.w))<<24
}
rgba8_unpack :: proc "contextless" (packed:u32) -> Vec4 {
    return {f32(packed&255),f32(packed>>8&255),f32(packed>>16&255),f32(packed>>24)}*(1.0/255)
}
// A linear color as sRGB bytes, and back.
rgba8_from_linear :: proc "contextless" (c:Vec4) -> u32 {return rgba8_pack(linear_to_srgb_rgba(c))}
rgba8_to_linear :: proc "contextless" (packed:u32) -> Vec4 {return srgb_to_linear_rgba(rgba8_unpack(packed))}

// A non-negative linear color in one integer: three 9-bit mantissas, red in
// the lowest bits, and a 5-bit exponent they share (the layout of
// RGB9_E5). It holds up to RGB9E5_MAX; above, it saturates.
RGB9E5_MAX :: f32(65408)
rgb9e5_pack :: proc "contextless" (c:Vec3) -> u32 {
    r,g,b:=clamp(c.x,0,RGB9E5_MAX),clamp(c.y,0,RGB9E5_MAX),clamp(c.z,0,RGB9E5_MAX)
    if !(r>=0) {r=0}
    if !(g>=0) {g=0}
    if !(b>=0) {b=0}
    high:=max(r,g,b)
    if high<=0 {return 0}
    exponent:=max(i32(-16),i32(math.floor(math.log2(high))))+1+15
    scale:=math.pow(f32(2),f32(exponent-15-9))
    if i32(math.floor(high/scale+0.5))==512 {
        exponent+=1
        scale*=2
    }
    exponent=clamp(exponent,0,31)
    channel :: proc "contextless" (v,scale:f32) -> u32 {return u32(min(math.floor(v/scale+0.5),511))}
    return channel(r,scale)|channel(g,scale)<<9|channel(b,scale)<<18|u32(exponent)<<27
}
rgb9e5_unpack :: proc "contextless" (packed:u32) -> Vec3 {
    scale:=math.pow(f32(2),f32(i32(packed>>27)-15-9))
    return {f32(packed&511),f32(packed>>9&511),f32(packed>>18&511)}*scale
}

// Reads rgb, rgba, rrggbb or rrggbbaa in hex, with or without a leading #,
// as an sRGB color, and returns it linear. Without alpha digits alpha is 1.
color_parse_hex :: proc "contextless" (text:string) -> (color:Vec4,ok:bool) {
    digits:=text[1:] if len(text)>0 && text[0]=='#' else text
    values:[8]u8
    if len(digits)!=3 && len(digits)!=4 && len(digits)!=6 && len(digits)!=8 {return}
    for i in 0..<len(digits) {
        switch c:=digits[i];c {
        case '0'..='9': values[i]=c-'0'
        case 'a'..='f': values[i]=c-'a'+10
        case 'A'..='F': values[i]=c-'A'+10
        case: return
        }
    }
    channels:=[4]u8{0,0,0,255}
    if len(digits)<=4 {
        for i in 0..<len(digits) {channels[i]=values[i]*17}
    } else {
        for i in 0..<len(digits)/2 {channels[i]=values[i*2]<<4|values[i*2+1]}
    }
    return rgba8_to_linear(u32(channels[0])|u32(channels[1])<<8|u32(channels[2])<<16|u32(channels[3])<<24),true
}
// Writes #rrggbbaa for a linear color and returns it; "" when the buffer is shorter than 9 bytes.
color_format_hex :: proc "contextless" (color:Vec4,buffer:[]u8) -> string {
    if len(buffer)<9 {return ""}
    packed:=rgba8_from_linear(color)
    digits:="0123456789abcdef"
    buffer[0]='#'
    for channel in 0..<4 {
        value:=packed>>uint(channel*8)&255
        buffer[1+channel*2]=digits[value>>4]
        buffer[2+channel*2]=digits[value&15]
    }
    return string(buffer[:9])
}

// The linear sRGB color of a black body at temperature kelvin, of luminance
// one, from the Planckian locus in CIE 1960 UCS.
blackbody_linear :: proc "contextless" (kelvin:f32) -> Vec3 {
    t:=f64(clamp(kelvin,1000,15000))
    u:=(0.860117757+1.54118254e-4*t+1.28641212e-7*t*t)/(1+8.42420235e-4*t+7.08145163e-7*t*t)
    v:=(0.317398726+4.22806245e-5*t+4.20481691e-8*t*t)/(1-2.89741816e-5*t+1.61456053e-7*t*t)
    x:=3*u/(2*u-8*v+4)
    y:=2*v/(2*u-8*v+4)
    z:=1-x-y
    X,Y,Z:=x/y,1.0,z/y
    r:=3.2404542*X-1.5371385*Y-0.4985314*Z
    g:=-0.9692660*X+1.8760108*Y+0.0415560*Z
    b:=0.0556434*X-0.2040259*Y+1.0572252*Z
    return {f32(max(r,0)),f32(max(g,0)),f32(max(b,0))}
}
