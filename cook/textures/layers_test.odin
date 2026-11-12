package textures

import "core:math"
import "core:testing"
import "mirai:asset"

@(private="file")
floats_of :: proc(values:[][4]f32) -> []u8 {
    texels:=make([]u8,len(values)*16,context.temp_allocator)
    linear:=transfer_make(false)
    for value,at in values {texel_write(texels,.RGBA32F,at,value,&linear)}
    return texels
}

@(private="file")
decoded_level :: proc(built:^Built,level,layer:int) -> [][4]f32 {
    width,height:=max(built.width>>uint(level),1),max(built.height>>uint(level),1)
    size:=asset.texture_level_size(built.format,width,height)
    texels:=make([][4]f32,width*height,context.temp_allocator)
    asset.texture_level_linear(built.format,built.flags,built.mips[level][layer*size:][:size],width,height,texels)
    return texels
}

@(test)
hdr_is_bc6h_without_clipping_light :: proc(t:^testing.T) {
    SIDE :: 16
    values:=make([][4]f32,SIDE*SIDE,context.temp_allocator)
    // A tinted light from 0.5 to 50 across the image: one subset follows it in a block.
    for &value,at in values {
        x,y:=f32(at%SIDE)/(SIDE-1),f32(at/SIDE)/(SIDE-1)
        light:=0.5*math.pow(f32(100),(x+y)/2)
        value={light,light*0.8,light*0.6,1}
    }
    built,error:=build({texels=floats_of(values),width=SIDE,height=SIDE,format=.RGBA32F},{srgb=true})
    defer built_destroy(&built)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,built.format==.BC6H && .Srgb in built.flags && len(built.mips)==5)
    worst:=f32(0)
    for texel,at in decoded_level(&built,0,0) {
        for c in 0..<3 {worst=max(worst,abs(texel[c]-values[at][c])/values[at][c])}
    }
    testing.expectf(t,worst<0.08,"a gradient of light keeps every texel within %v of its value",worst)
    for texel in decoded_level(&built,4,0) {testing.expectf(t,texel.r>5 && abs(texel.b/texel.r-0.6)<0.05,"the last level keeps the light above 1 and its tint: %v",texel)}

    // What BC6H cannot hold is kept in half floats, and so is what asks for it.
    values[3].a=0.5
    holed,_:=build({texels=floats_of(values),width=SIDE,height=SIDE,format=.RGBA32F},{})
    defer built_destroy(&holed)
    kept:=decoded_level(&holed,0,0)[3]
    testing.expect(t,holed.format==.RGBA16F && kept.a==0.5 && abs(kept.r-values[3].r)<values[3].r*0.001,"half floats keep alpha and light")
    plain,_:=build({texels=floats_of(values[:4]),width=2,height=2,format=.RGBA32F},{encoding=.Uncompressed})
    defer built_destroy(&plain)
    testing.expect(t,plain.format==.RGBA16F && len(plain.mips[0])==2*2*8)
    free_all(context.temp_allocator)
}

@(test)
a_cube_keeps_the_levels_of_each_face_apart :: proc(t:^testing.T) {
    SIDE :: 8
    faces:=make([]u8,SIDE*SIDE*4*6,context.temp_allocator)
    for face in 0..<6 {
        for at in 0..<SIDE*SIDE {
            texel:=faces[(face*SIDE*SIDE+at)*4:]
            texel[0],texel[1],texel[2],texel[3]=u8(face*40),u8(255-face*40),u8(at%2*255),255
        }
    }
    built,error:=build({texels=faces,width=SIDE,height=SIDE,layers=6,cube=true},{encoding=.Uncompressed})
    defer built_destroy(&built)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,built.layers==6 && .Cube in built.flags && len(built.mips)==4)
    for level,i in built.mips {
        side:=max(SIDE>>uint(i),1)
        testing.expect_value(t,len(level),side*side*4*6)
        for face in 0..<6 {
            texel:=level[face*side*side*4:]
            testing.expectf(t,texel[0]==u8(face*40) && texel[1]==u8(255-face*40),"level %d of face %d keeps its color",i,face)
            if i>0 {testing.expectf(t,abs(int(texel[2])-128)<=1,"level %d of face %d is the mean of its own texels",i,face)}
        }
    }
    blocks,_:=build({texels=faces,width=SIDE,height=SIDE,layers=6,cube=true},{srgb=true})
    defer built_destroy(&blocks)
    testing.expect(t,blocks.format==.BC7 && len(blocks.mips[0])==asset.texture_level_size(.BC7,SIDE,SIDE)*6)
    _,refused:=build({texels=faces,width=SIDE,height=SIDE,layers=5,cube=true},{})
    testing.expect_value(t,refused,Error.Invalid)
    _,short:=build({texels=faces[:len(faces)-1],width=SIDE,height=SIDE,layers=6,cube=true},{})
    testing.expect_value(t,short,Error.Invalid)
}

@(test)
images_of_16_bits_and_radiance_keep_what_they_hold :: proc(t:^testing.T) {
    heights:=[]f32{0,1000.0/65535,0.5,1}
    png,png_error:=heightmap_encode(heights,2,2,context.temp_allocator)
    testing.expect_value(t,png_error,Error.None)
    testing.expect(t,source_wide(png))
    source,error:=source_decode(png,context.temp_allocator)
    testing.expect(t,error==.None && source.format==.RGBA16 && source.width==2)
    testing.expect(t,source.texels[8]==u8(1000&0xff) && source.texels[9]==u8(1000>>8),"the second texel keeps its 16 bits")
    built,_:=from_bytes(png,{encoding=.Uncompressed})
    defer built_destroy(&built)
    testing.expect(t,built.format==.RGBA16 && built.mips[0][8]==u8(1000&0xff) && built.mips[0][9]==u8(1000>>8))
    compressed,_:=from_bytes(png,{})
    defer built_destroy(&compressed)
    testing.expect_value(t,compressed.format,asset.Texture_Format.BC1)

    // Radiance, flat: 100 and 0.25 as a mantissa and an exponent.
    hdr:=make([dynamic]u8,context.temp_allocator)
    append(&hdr,"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 2\n")
    append(&hdr,200,200,200,135,128,128,128,127)
    testing.expect(t,source_wide(hdr[:]))
    light,light_error:=source_decode(hdr[:],context.temp_allocator)
    testing.expect(t,light_error==.None && light.format==.RGBA32F)
    linear:=transfer_make(false)
    testing.expect_value(t,texel_read(light.texels,light.format,0,&linear),[4]f32{100,100,100,1})
    testing.expect_value(t,texel_read(light.texels,light.format,1,&linear),[4]f32{0.25,0.25,0.25,1})
    kept,_:=from_bytes(hdr[:],{})
    defer built_destroy(&kept)
    testing.expect_value(t,kept.format,asset.Texture_Format.BC6H)
    testing.expectf(t,abs(decoded_level(&kept,0,0)[0].r-100)<3,"100 is not clipped: %v",decoded_level(&kept,0,0)[0])
    free_all(context.temp_allocator)
}
