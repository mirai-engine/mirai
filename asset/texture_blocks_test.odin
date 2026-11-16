package asset

import "core:mem"
import "core:testing"

@(test)
block_formats_decode_to_the_texels_a_gpu_shows :: proc(t:^testing.T) {
    // Four color mode: red above blue, one texel per index along the first row.
    block:=[8]u8{0x00,0xf8,0x1f,0x00,0b11_10_01_00,0,0,0}
    colors,alpha:=texture_bc1_block_decode(block)
    testing.expect_value(t,colors[0],[3]f32{1,0,0})
    testing.expect_value(t,colors[1],[3]f32{0,0,1})
    testing.expect(t,abs(colors[2].r-2.0/3)<1e-6 && abs(colors[2].b-1.0/3)<1e-6 && abs(colors[3].r-1.0/3)<1e-6 && abs(colors[3].b-2.0/3)<1e-6)
    for value in alpha {testing.expect_value(t,value,f32(1))}
    // Three color mode, the first endpoint not above the second: a midpoint and a transparent texel.
    block={0x1f,0x00,0x00,0xf8,0b11_10_01_00,0,0,0}
    colors,alpha=texture_bc1_block_decode(block)
    testing.expect(t,colors[2]==[3]f32{0.5,0,0.5} && colors[3]==[3]f32{0,0,0})
    testing.expect(t,alpha[0]==1 && alpha[1]==1 && alpha[2]==1 && alpha[3]==0 && alpha[4]==1)
    // The color block of BC3 reads the same endpoints in four color mode, all opaque.
    colors,alpha=texture_bc1_block_decode(block,four_color=true)
    testing.expect(t,abs(colors[2].b-2.0/3)<1e-6 && abs(colors[3].b-1.0/3)<1e-6 && alpha[3]==1)

    // Eight values between a high and a low endpoint, and the six value mode with its 0 and 1.
    values:=texture_bc4_block_decode({200,60,0b10_001_000,0b1_100_011_0,0b111_110_10,0,0,0})
    expected:=[8]f32{200,60,180,160,140,120,100,80}
    for value,i in expected {testing.expectf(t,abs(values[i]*255-value)<1e-3,"index %d decodes to %v",i,values[i]*255)}
    values=texture_bc4_block_decode({60,200,0b10_001_000,0b1_100_011_0,0b111_110_10,0,0,0})
    expected={60,200,88,116,144,172,0,255}
    for value,i in expected {testing.expectf(t,abs(values[i]*255-value)<1e-3,"index %d of the six value mode decodes to %v",i,values[i]*255)}
}

@(test)
a_level_of_any_format_becomes_rgba8 :: proc(t:^testing.T) {
    // 5x3 texels in two BC1 blocks: the texels beyond the image are not written.
    blocks:=[16]u8{0x00,0xf8,0x00,0xf8,0,0,0,0, 0x1f,0x00,0x1f,0x00,0,0,0,0}
    pixels:[5*3*4]u8
    testing.expect(t,texture_level_rgba8(.BC1,blocks[:],5,3,pixels[:]))
    for y in 0..<3 {
        for x in 0..<5 {
            at:=(y*5+x)*4
            testing.expect_value(t,[4]u8{pixels[at],pixels[at+1],pixels[at+2],pixels[at+3]},x<4?[4]u8{255,0,0,255}:[4]u8{0,0,255,255})
        }
    }
    // BC3: alpha first, then color. BC5: two channels and the third of their unit vector.
    bc3:=[16]u8{128,128,0,0,0,0,0,0, 0xe0,0x07,0xe0,0x07,0,0,0,0}
    texel:[4]u8
    testing.expect(t,texture_level_rgba8(.BC3,bc3[:],1,1,texel[:]))
    testing.expect_value(t,texel,[4]u8{0,255,0,128})
    bc5:=[16]u8{128,128,0,0,0,0,0,0, 255,255,0,0,0,0,0,0}
    testing.expect(t,texture_level_rgba8(.BC5,bc5[:],1,1,texel[:]))
    testing.expect(t,texel.r==128 && texel.g==255 && abs(int(texel.b)-128)<=2 && texel.a==255,"a normal along +Y has no Z left")
    // BC7 mode 6, both endpoints 127 with p-bit 1 but green and blue 0 with it.
    bc7:=[16]u8{192,255,31,0,0,0,254,255,1,0,0,0,0,0,0,0}
    testing.expect(t,texture_level_rgba8(.BC7,bc7[:],1,1,texel[:]))
    testing.expect_value(t,texel,[4]u8{255,1,1,255})
    plain:=[8]u8{1,2,3,4,5,6,7,8}
    copied:[8]u8
    testing.expect(t,texture_level_rgba8(.RGBA8,plain[:],2,1,copied[:]) && copied==plain)

    testing.expect(t,!texture_level_rgba8(.BC1,blocks[:8],5,3,pixels[:]),"too few blocks")
    testing.expect(t,!texture_level_rgba8(.BC1,blocks[:],5,3,pixels[:8]),"too few pixels")
    testing.expect(t,!texture_level_rgba8(.BC1,blocks[:],0,3,pixels[:0]))
}

// Mode 11 of BC6H: 3 bits of the first index, 4 of the others, and channels
// that run from the first endpoint to the second through 16 weights.
@(private="file")
bc6h_block :: proc(first,second:[3]u32,indices:[16]u32) -> (block:[16]u8) {
    bits:u128=0b00011
    for c in 0..<3 {
        bits|=u128(first[c])<<(5+u32(c)*10)
        bits|=u128(second[c])<<(35+u32(c)*10)
    }
    at:=u32(65)
    for index,i in indices {
        bits|=u128(index)<<at
        at+=3 if i==0 else 4
    }
    for &b,i in block {b=u8(bits>>(u32(i)*8))}
    return
}

@(test)
bc6h_blocks_decode_to_the_half_floats_a_gpu_shows :: proc(t:^testing.T) {
    indices:[16]u32
    for &index,i in indices {index=u32(i)}
    indices[0]=0
    texels:=texture_bc6h_block_decode(bc6h_block({0,0,0},{1023,1023,1023},indices))
    testing.expect_value(t,texels[0],[3]u16{0,0,0})
    testing.expect_value(t,texels[15],[3]u16{0x7bff,0x7bff,0x7bff})
    // Weight 34 of 64 between 0 and 0xffff, times 31/64.
    testing.expect_value(t,texels[8][1],u16((((0xffff*34+32)>>6)*31)>>6))
    // A quantized endpoint between the ends lands on its value times 64, plus 32.
    texels=texture_bc6h_block_decode(bc6h_block({512,0,0},{512,0,0},{}))
    testing.expect_value(t,texels[3][0],u16(((512*64+32)*31)>>6))
    one:=f32(transmute(f16)texture_bc6h_block_decode(bc6h_block({495,495,495},{495,495,495},{}))[0][0])
    testing.expect_value(t,one,f32(1))
    other:=bc6h_block({1023,1023,1023},{1023,1023,1023},{})
    other[0]=0b10011 // a reserved mode
    testing.expect_value(t,texture_bc6h_block_decode(other)[0],[3]u16{0,0,0})

    halves:[4*4*8]u8
    testing.expect(t,texture_level_rgba16f(.BC6H,other[:],4,4,halves[:]) && halves[6]==0x00 && halves[7]==0x3c,"alpha is 1")
    testing.expect(t,!texture_level_rgba8(.BC6H,other[:],4,4,make([]u8,64,context.temp_allocator)),"BC6H is no 8-bit format")
    linear:[16][4]f32
    bright:=bc6h_block({1023,1023,1023},{1023,1023,1023},{})
    testing.expect(t,texture_level_linear(.BC6H,{},bright[:],4,4,linear[:]) && linear[5]=={65504,65504,65504,1},"HDR is not clipped")
    wide:=[8]u8{0xff,0xff,0,0,0x00,0x80,0xff,0xff}
    testing.expect(t,texture_level_linear(.RGBA16,{.Srgb},wide[:],1,1,linear[:1]) && linear[0].r==1 && linear[0].g==0 && abs(linear[0].b-32768.0/65535)<1e-6,"16 bits are linear")
    free_all(context.temp_allocator)
}

@(test)
fields_split_and_join_give_back_the_same_blocks :: proc(t:^testing.T) {
    state:=u64(11)
    for format in Texture_Format {
        // 5x3 blocks in each of three layers.
        blocks:=make([]u8,texture_level_size(format,20,12)*3,context.temp_allocator)
        for &b in blocks {b=u8(test_random(&state))}
        planes:=make([]u8,len(blocks),context.temp_allocator)
        joined:=make([]u8,len(blocks),context.temp_allocator)
        if !texture_fields_format(format) {
            testing.expectf(t,!texture_fields_split(format,blocks,planes) && !texture_fields_join(format,blocks,joined),"%v has no planes of fields",format)
            continue
        }
        testing.expect(t,texture_fields_split(format,blocks,planes))
        testing.expectf(t,texture_fields_join(format,planes,joined) && mem.compare(joined,blocks)==0,"%v joins back to its blocks",format)
        stride:=8 if format==.BC1 else 16
        testing.expect(t,!texture_fields_split(format,blocks[:len(blocks)-stride/2],planes[:len(blocks)-stride/2]),"a part of a block")
        testing.expect(t,!texture_fields_join(format,planes,joined[:len(joined)-stride]),"planes and blocks of other sizes")
    }
    // The endpoints of a BC5 block go first, those of both channels, then the indices of both.
    blocks:=make([]u8,2*16,context.temp_allocator)
    for &b,i in blocks {b=u8(i)}
    planes:=make([]u8,len(blocks),context.temp_allocator)
    texture_fields_split(.BC5,blocks,planes)
    testing.expect_value(t,[6]u8{planes[0],planes[1],planes[2],planes[3],planes[4],planes[5]},[6]u8{0,1,16,17,8,9})
    testing.expect_value(t,[3]u8{planes[8],planes[13],planes[20]},[3]u8{2,7,10})
    free_all(context.temp_allocator)
}
