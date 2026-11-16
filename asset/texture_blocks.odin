package asset

import "core:math"
import mm "mirai:std/math"

// What the block formats of a .tex decode to: the texels a GPU shows, for a
// device that cannot sample them and for whoever inspects a texture.

@(private="file")
color_565 :: proc "contextless" (c:u16) -> [3]f32 {
    r,g,b:=(c>>11)&31,(c>>5)&63,c&31
    // The bit replication GPUs use to widen 5 and 6 bits to 8.
    return {f32(r<<3|r>>2)/255,f32(g<<2|g>>4)/255,f32(b<<3|b>>2)/255}
}

// The four colors of a color block in the order of their 2-bit indices, as
// the four color mode reads them (first endpoint above the second).
texture_bc1_palette :: proc "contextless" (c0,c1:u16) -> [4][3]f32 {
    a,b:=color_565(c0),color_565(c1)
    return {a,b,(a*2+b)/3,(a+b*2)/3}
}

// Texels of a color block, row by row, in 0..1. alpha tells the texels the
// three color mode leaves transparent. The color block of BC3 is always four
// color, whatever the order of its endpoints.
texture_bc1_block_decode :: proc "contextless" (block:[8]u8,four_color:=false) -> (texels:[16][3]f32,alpha:[16]f32) {
    c0:=u16(block[0])|u16(block[1])<<8
    c1:=u16(block[2])|u16(block[3])<<8
    palette:=texture_bc1_palette(c0,c1)
    opaque:=[4]f32{1,1,1,1}
    if c0<=c1 && !four_color {
        palette[2]=(palette[0]+palette[1])/2
        palette[3]={}
        opaque[3]=0
    }
    indices:=u32(block[4])|u32(block[5])<<8|u32(block[6])<<16|u32(block[7])<<24
    for i in 0..<16 {
        index:=(indices>>(u32(i)*2))&3
        texels[i],alpha[i]=palette[index],opaque[index]
    }
    return
}

// Values of a single channel block (the alpha of BC3, each half of BC5), in 0..1.
texture_bc4_block_decode :: proc "contextless" (block:[8]u8) -> (values:[16]f32) {
    a,b:=f32(block[0]),f32(block[1])
    bits:u64
    for i in 0..<6 {bits|=u64(block[2+i])<<(u32(i)*8)}
    for i in 0..<16 {
        index:=(bits>>(u32(i)*3))&7
        value:f32
        switch {
        case index==0: value=a
        case index==1: value=b
        case block[0]>block[1]: value=(a*f32(8-index)+b*f32(index-1))/7
        case index<6: value=(a*f32(6-index)+b*f32(index-1))/5
        case index==6: value=0
        case: value=255
        }
        values[i]=value/255
    }
    return
}

// One image of a level of a format of 8 bits (RGBA8, BC1, BC3, BC5, BC7) as
// RGBA8, rows from the top, with the values it stores. A BC5 level gets the
// third component of its unit vector in blue. False for another format and
// when either slice does not hold an image of that size.
texture_level_rgba8 :: proc "contextless" (format:Texture_Format,level:[]u8,width,height:int,pixels:[]u8) -> bool {
    if width<=0 || height<=0 || len(level)!=texture_level_size(format,width,height) || len(pixels)!=width*height*4 {return false}
    if format==.RGBA16 || format==.RGBA16F || format==.BC6H {return false}
    if format==.RGBA8 {
        copy(pixels,level)
        return true
    }
    to_byte :: proc "contextless" (value:f32) -> u8 {return u8(clamp(value,0,1)*255+0.5)}
    blocks_x,blocks_y:=(width+3)/4,(height+3)/4
    size:=8 if format==.BC1 else 16
    for by in 0..<blocks_y {
        for bx in 0..<blocks_x {
            block:=level[(by*blocks_x+bx)*size:]
            texels:[16][4]u8
            first,second:[8]u8
            copy(first[:],block[:8])
            if size==16 {copy(second[:],block[8:16])}
            switch format {
            case .RGBA8,.RGBA16,.RGBA16F,.BC6H:
            case .BC1:
                colors,alpha:=texture_bc1_block_decode(first)
                for c,i in colors {texels[i]={to_byte(c.r),to_byte(c.g),to_byte(c.b),to_byte(alpha[i])}}
            case .BC3:
                alpha:=texture_bc4_block_decode(first)
                colors,_:=texture_bc1_block_decode(second,four_color=true)
                for c,i in colors {texels[i]={to_byte(c.r),to_byte(c.g),to_byte(c.b),to_byte(alpha[i])}}
            case .BC5:
                xs,ys:=texture_bc4_block_decode(first),texture_bc4_block_decode(second)
                for i in 0..<16 {
                    x,y:=xs[i]*2-1,ys[i]*2-1
                    z:=math.sqrt(max(1-x*x-y*y,0))
                    texels[i]={to_byte(xs[i]),to_byte(ys[i]),to_byte(z*0.5+0.5),255}
                }
            case .BC7:
                whole:[16]u8
                copy(whole[:],block[:16])
                texels=texture_bc7_block_decode(whole)
            }
            for y in 0..<4 {
                if by*4+y>=height {break}
                for x in 0..<4 {
                    if bx*4+x>=width {break}
                    at:=((by*4+y)*width+bx*4+x)*4
                    texel:=texels[y*4+x]
                    pixels[at],pixels[at+1],pixels[at+2],pixels[at+3]=texel.r,texel.g,texel.b,texel.a
                }
            }
        }
    }
    return true
}

// One image of a level of a format of half floats (RGBA16F, BC6H) as
// RGBA16F, rows from the top: what a device that cannot sample BC6H takes.
// BC6H gives an alpha of 1. False for another format and when either slice
// does not hold an image of that size.
texture_level_rgba16f :: proc "contextless" (format:Texture_Format,level:[]u8,width,height:int,pixels:[]u8) -> bool {
    if width<=0 || height<=0 || len(level)!=texture_level_size(format,width,height) || len(pixels)!=width*height*8 {return false}
    #partial switch format {
    case .RGBA16F:
        copy(pixels,level)
        return true
    case .BC6H:
    case: return false
    }
    ONE :: u16(0x3c00) // 1.0 as a half float
    blocks_x,blocks_y:=(width+3)/4,(height+3)/4
    for by in 0..<blocks_y {
        for bx in 0..<blocks_x {
            block:[16]u8
            copy(block[:],level[(by*blocks_x+bx)*16:][:16])
            texels:=texture_bc6h_block_decode(block)
            for y in 0..<4 {
                if by*4+y>=height {break}
                for x in 0..<4 {
                    if bx*4+x>=width {break}
                    at:=((by*4+y)*width+bx*4+x)*8
                    texel:=texels[y*4+x]
                    for value,c in ([4]u16{texel[0],texel[1],texel[2],ONE}) {pixels[at+c*2],pixels[at+c*2+1]=u8(value),u8(value>>8)}
                }
            }
        }
    }
    return true
}

// One image of a level of any format as linear values, rows from the top:
// color stored as sRGB (flags) is decoded, and the formats of 16 bits give
// what they hold, HDR above 1 too. Scratch from the temp allocator. False
// when either slice does not hold an image of that size.
texture_level_linear :: proc(format:Texture_Format,flags:Texture_Flags,level:[]u8,width,height:int,texels:[][4]f32) -> bool {
    if width<=0 || height<=0 || len(level)!=texture_level_size(format,width,height) || len(texels)!=width*height {return false}
    #partial switch format {
    case .RGBA16:
        for &texel,i in texels {
            for c in 0..<4 {texel[c]=f32(u16(level[i*8+c*2])|u16(level[i*8+c*2+1])<<8)/65535}
        }
        return true
    case .RGBA16F,.BC6H:
        halves:=make([]u8,width*height*8,context.temp_allocator)
        if !texture_level_rgba16f(format,level,width,height,halves) {return false}
        for &texel,i in texels {
            for c in 0..<4 {texel[c]=f32(transmute(f16)(u16(halves[i*8+c*2])|u16(halves[i*8+c*2+1])<<8))}
        }
        return true
    }
    pixels:=make([]u8,width*height*4,context.temp_allocator)
    if !texture_level_rgba8(format,level,width,height,pixels) {return false}
    srgb:=.Srgb in flags
    for &texel,i in texels {
        texel=mm.rgba8_unpack(u32(pixels[i*4])|u32(pixels[i*4+1])<<8|u32(pixels[i*4+2])<<16|u32(pixels[i*4+3])<<24)
        if srgb {texel=mm.srgb_to_linear_rgba(texel)}
    }
    return true
}
