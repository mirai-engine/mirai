package common

import "base:intrinsics"

// One texel of a Color_Block. The BC1 code reads it as BGRA (B, G, R, A at
// indices 0..3); the BC7 code as RGBA. As a u32 (color_dw) alpha is the top byte.
Color :: [4]u8

B :: 0
G :: 1
R :: 2
A :: 3

Vec3i :: [3]i32
Vec3f :: [3]f32

// b | g<<8 | r<<16 with b and r in [0,31] and g in [0,63]: a 565 color unpacked to
// bytes but not expanded to 8 bits.
Unpacked_565 :: distinct u32

color_dw :: #force_inline proc "contextless" (c:Color) -> u32 {return transmute(u32)c}

mul8bit :: #force_inline proc "contextless" (a,b:i32) -> i32 {
    t:=a*b+128
    return (t+(t>>8))>>8
}

clamp_u8 :: #force_inline proc "contextless" (x:i32) -> u8 {return u8(clamp(x,0,255))}

delta_sqr_rgb :: #force_inline proc "contextless" (c1,c2:Color) -> u32 {
    dr:=i32(c1[R])-i32(c2[R]); dg:=i32(c1[G])-i32(c2[G]); db:=i32(c1[B])-i32(c2[B])
    return u32(dr*dr+dg*dg+db*db)
}

delta_sqr_rgba :: #force_inline proc "contextless" (c1,c2:Color) -> u32 {
    dr:=i32(c1[R])-i32(c2[R]); dg:=i32(c1[G])-i32(c2[G]); db:=i32(c1[B])-i32(c2[B])
    da:=i32(c1[A])-i32(c2[A])
    return u32(dr*dr+dg*dg+db*db+da*da)
}

// The 8-bit BGRA color a packed 565 value decodes to, alpha 255.
unquantize_565 :: #force_inline proc "contextless" (c:u16) -> Color {
    r:=u8((c>>11)&31); g:=u8((c>>5)&63); b:=u8(c&31)
    return {(b<<3)|(b>>2),(g<<2)|(g>>4),(r<<3)|(r>>2),255}
}

quantize_565 :: #force_inline proc "contextless" (c:Color) -> u16 {
    r:=u16(mul8bit(i32(c[R]),31)); g:=u16(mul8bit(i32(c[G]),63)); b:=u16(mul8bit(i32(c[B]),31))
    return (r<<11)|(g<<5)|b
}

unpacked_565_make :: #force_inline proc "contextless" (r,g,b:u8) -> Unpacked_565 {
    return Unpacked_565(u32(b)|(u32(g)<<8)|(u32(r)<<16))
}
unpacked_565_b :: #force_inline proc "contextless" (u:Unpacked_565) -> u8 {return u8(u)}
unpacked_565_g :: #force_inline proc "contextless" (u:Unpacked_565) -> u8 {return u8(u>>8)}
unpacked_565_r :: #force_inline proc "contextless" (u:Unpacked_565) -> u8 {return u8(u>>16)}

unpacked_565_from_packed :: #force_inline proc "contextless" (c:u16) -> Unpacked_565 {
    return unpacked_565_make(u8((c>>11)&31),u8((c>>5)&63),u8(c&31))
}

unpacked_565_pack :: #force_inline proc "contextless" (u:Unpacked_565) -> u16 {
    return (u16(unpacked_565_r(u)&31)<<11)|(u16(unpacked_565_g(u)&63)<<5)|u16(unpacked_565_b(u)&31)
}

unpacked_565_quantize :: #force_inline proc "contextless" (c:Color) -> Unpacked_565 {
    x:=color_dw(c)
    t:=(x&0xff00ff)*31+0x800080
    t=t+((t>>8)&0xff00ff)
    dw:=(t>>8)&0xff00ff
    dw+=u32(mul8bit(i32(c[G]),63))<<8
    return Unpacked_565(dw)
}

color_to_vec3i :: #force_inline proc "contextless" (c:Color) -> Vec3i {
    return {i32(c[B]),i32(c[G]),i32(c[R])}
}

vec3i_to_color :: #force_inline proc "contextless" (v:Vec3i) -> Color {
    return {u8(v.x),u8(v.y),u8(v.z),255}
}

// Straight to packed 565 with one rounding.
vec3f_to_quantized_565_rn :: proc "contextless" (v:Vec3f) -> u16 {
    SCALE_RB:f32:31.0/255.0
    SCALE_G:f32:63.0/255.0
    b:=u16(clamp(round_to_int(SCALE_RB*v.x),0,31))
    g:=u16(clamp(round_to_int(SCALE_G*v.y),0,63))
    r:=u16(clamp(round_to_int(SCALE_RB*v.z),0,31))
    return (r<<11)|(g<<5)|b
}

vec3i_dot :: #force_inline proc "contextless" (a,b:Vec3i) -> i32 {return a.x*b.x+a.y*b.y+a.z*b.z}
