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
    gpu:Gpu_Context
    if !test_gpu_context(t,&gpu) {return}
    defer gpu_context_destroy(&gpu)
    SIDE :: 16
    values:=make([][4]f32,SIDE*SIDE,context.temp_allocator)
    // A tinted light from 0.5 to 50 across the image: one subset follows it in a block.
    for &value,at in values {
        x,y:=f32(at%SIDE)/(SIDE-1),f32(at/SIDE)/(SIDE-1)
        light:=0.5*math.pow(f32(100),(x+y)/2)
        value={light,light*0.8,light*0.6,1}
    }
    built,error:=build({texels=floats_of(values),width=SIDE,height=SIDE,format=.RGBA32F},{srgb=true},gpu=&gpu)
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
a_cube_cooks_all_faces_in_blocks :: proc(t:^testing.T) {
    gpu:Gpu_Context
    if !test_gpu_context(t,&gpu) {return}
    defer gpu_context_destroy(&gpu)
    SIDE :: 8
    faces: [SIDE*SIDE*4*6]u8
    for i:=3;i<len(faces);i+=4 {faces[i]=255}
    blocks,error:=build({texels=faces[:],width=SIDE,height=SIDE,layers=6,cube=true},{srgb=true},gpu=&gpu)
    defer built_destroy(&blocks)
    if !testing.expect_value(t,error,Error.None) {return}
    testing.expect(t,blocks.format==.BC7 && len(blocks.mips[0])==asset.texture_level_size(.BC7,SIDE,SIDE)*6)
}
