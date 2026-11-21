package textures

import "core:testing"
import "mirai:asset"

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
    testing.expect_value(t,stored_format(source,{}),asset.Texture_Format.BC1)

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
    testing.expect_value(t,stored_format(light,{}),asset.Texture_Format.BC6H)
    free_all(context.temp_allocator)
}
