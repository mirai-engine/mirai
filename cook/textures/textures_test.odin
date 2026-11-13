package textures

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:testing"
import stbi "vendor:stb/image"
import "mirai:asset"
import "mirai:std/base"

@(private="file")
Png_Sink :: struct {bytes:[dynamic]u8,allocator:runtime.Allocator}

@(private="file")
png_sink :: proc "c" (user:rawptr,data:rawptr,size:c.int) {
    sink:=(^Png_Sink)(user)
    context=runtime.default_context()
    context.allocator=sink.allocator
    append(&sink.bytes,..([^]u8)(data)[:size])
}

@(private="file")
png_of :: proc(pixels:[]u8,width,height:int) -> []u8 {
    sink:=Png_Sink{allocator=context.allocator}
    stbi.write_png_to_func(png_sink,&sink,c.int(width),c.int(height),4,raw_data(pixels),c.int(width*4))
    return sink.bytes[:]
}

@(private="file")
checker :: proc(size:int,low,high:u8) -> []u8 {
    pixels:=make([]u8,size*size*4)
    for y in 0..<size {
        for x in 0..<size {
            value:=low if (x+y)%2==0 else high
            at:=(y*size+x)*4
            pixels[at],pixels[at+1],pixels[at+2],pixels[at+3]=value,value,value,255
        }
    }
    return pixels
}

@(test)
chain_runs_down_to_one_texel_with_halving_sizes :: proc(t:^testing.T) {
    pixels:=make([]u8,5*3*4);defer delete(pixels)
    built,error:=build(rgba8(pixels,5,3),{encoding=.Uncompressed})
    defer built_destroy(&built)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,len(built.mips),asset.texture_mip_count(5,3))
    sizes:=[3][2]int{{5,3},{2,1},{1,1}}
    for size,i in sizes {
        testing.expect_value(t,len(built.mips[i]),size.x*size.y*4)
    }
}

@(test)
an_image_wider_than_a_texture_holds_is_refused :: proc(t:^testing.T) {
    pixels:=make([]u8,(asset.TEXTURE_MAX_SIZE+1)*4);defer delete(pixels)
    _,error:=build(rgba8(pixels,asset.TEXTURE_MAX_SIZE+1,1),{encoding=.Uncompressed})
    testing.expect_value(t,error,Error.Too_Large)
    built,fits:=build(rgba8(pixels[:asset.TEXTURE_MAX_SIZE*4],asset.TEXTURE_MAX_SIZE,1),{encoding=.Uncompressed})
    defer built_destroy(&built)
    testing.expect(t,fits==.None && built.width==asset.TEXTURE_MAX_SIZE,"an image of the largest side is kept whole")
}

@(test)
a_linear_checker_keeps_its_average_in_every_level :: proc(t:^testing.T) {
    pixels:=checker(8,0,255);defer delete(pixels)
    built,error:=build(rgba8(pixels,8,8),{encoding=.Uncompressed})
    defer built_destroy(&built)
    testing.expect_value(t,error,Error.None)
    for level,i in built.mips[1:] {
        for at:=0;at<len(level);at+=4 {
            testing.expectf(t,abs(int(level[at])-128)<=1 && level[at+3]==255,"level %d texel %d is %d",i+1,at/4,level[at])
        }
    }
}

@(test)
an_srgb_checker_is_averaged_as_light :: proc(t:^testing.T) {
    pixels:=checker(8,0,255);defer delete(pixels)
    built,error:=build(rgba8(pixels,8,8),{srgb=true,encoding=.Uncompressed})
    defer built_destroy(&built)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,.Srgb in built.flags)
    // Half the light of white is 0.5 linear, which sRGB writes as 188.
    for at:=0;at<len(built.mips[1]);at+=4 {testing.expectf(t,abs(int(built.mips[1][at])-188)<=1,"texel %d is %d",at/4,built.mips[1][at])}
}

@(test)
a_normal_map_whose_green_points_down_is_turned_to_y_up :: proc(t:^testing.T) {
    // One texel tilted toward +Y as DirectX writes it: green below the middle.
    pixels:=[4*4]u8{}
    for at:=0;at<len(pixels);at+=4 {pixels[at],pixels[at+1],pixels[at+2],pixels[at+3]=128,64,220,255}
    built,error:=build(rgba8(pixels[:],2,2),{normal_map=true,green_down=true,encoding=.Uncompressed})
    defer built_destroy(&built)
    testing.expect_value(t,error,Error.None)
    level:=built.mips[0]
    testing.expect(t,level[0]==128 && level[1]==191 && level[2]==220,"green is inverted and the other channels stay")
    testing.expect_value(t,pixels[1],u8(64))
    plain:=Build_Options{normal_map=true}
    turned:=plain
    turned.green_down=true
    testing.expect(t,settings_hash(turned)!=settings_hash(plain),"the setting is part of what a texture is built with")
}

// A gloss map in red, as some games store it, becomes the roughness in the
// green of a metallic-roughness texture: inverted, with red and blue at 1.
@(test)
channels_make_a_roughness_texture_of_a_gloss_map :: proc(t:^testing.T) {
    pixels:=[4*4]u8{}
    for at:=0;at<len(pixels);at+=4 {pixels[at],pixels[at+1],pixels[at+2],pixels[at+3]=200,10,20,255}
    gloss:=Build_Options{encoding=.Uncompressed,channels={from={.One,.R,.One,.One},invert={1}}}
    built,error:=build(rgba8(pixels[:],2,2),gloss)
    defer built_destroy(&built)
    testing.expect_value(t,error,Error.None)
    level:=built.mips[0]
    testing.expectf(t,level[0]==255 && level[1]==55 && level[2]==255 && level[3]==255,"texel %v",level[:4])
    testing.expect_value(t,pixels[0],u8(200))
    testing.expect(t,settings_hash(gloss)!=settings_hash({encoding=.Uncompressed}),"the channels are part of what a texture is built with")
    // The zero value keeps the image's channels.
    kept,_:=build(rgba8(pixels[:],2,2),{encoding=.Uncompressed})
    defer built_destroy(&kept)
    testing.expect(t,kept.mips[0][0]==200 && kept.mips[0][1]==10)
}

@(test)
a_normal_map_stays_normalized_in_every_level :: proc(t:^testing.T) {
    size:=16
    pixels:=make([]u8,size*size*4);defer delete(pixels)
    for y in 0..<size {
        for x in 0..<size {
            angle:=f32(x*7+y*3)*0.37
            n:=[3]f32{math.cos(angle)*0.7,math.sin(angle)*0.7,0.5}
            n/=math.sqrt(n.x*n.x+n.y*n.y+n.z*n.z)
            at:=(y*size+x)*4
            for axis in 0..<3 {pixels[at+axis]=u8((n[axis]*0.5+0.5)*255+0.5)}
            pixels[at+3]=255
        }
    }
    built,error:=build(rgba8(pixels,size,size),{normal_map=true,encoding=.Uncompressed})
    defer built_destroy(&built)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,.Normal_Map in built.flags)
    for level,i in built.mips[1:] {
        for at:=0;at<len(level);at+=4 {
            n:=[3]f32{f32(level[at])/255*2-1,f32(level[at+1])/255*2-1,f32(level[at+2])/255*2-1}
            length:=math.sqrt(n.x*n.x+n.y*n.y+n.z*n.z)
            testing.expectf(t,abs(length-1)<0.03,"level %d texel %d has length %v",i+1,at/4,length)
        }
    }
}

@(test)
a_masked_texture_keeps_the_coverage_of_its_cutoff :: proc(t:^testing.T) {
    size:=64
    pixels:=make([]u8,size*size*4);defer delete(pixels)
    for y in 0..<size {
        for x in 0..<size {
            at:=(y*size+x)*4
            pixels[at],pixels[at+1],pixels[at+2]=60,160,60
            blob:=0.5+0.5*math.sin(f32(x)*0.55)*math.cos(f32(y)*0.43)
            pixels[at+3]=u8(clamp(blob*blob*255+20,0,255))
        }
    }
    cutoff:f32=0.5
    wanted:=alpha_coverage_of(rgba8(pixels,size,size),cutoff,1)
    kept,error:=build(rgba8(pixels,size,size),{alpha_coverage=cutoff,encoding=.Uncompressed})
    defer built_destroy(&kept)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,kept.alpha_coverage,cutoff)
    for level,i in kept.mips[1:4] {
        testing.expectf(t,abs(alpha_coverage_of(rgba8(level,len(level)/4,1),cutoff,1)-wanted)<=1.0/16,"level %d covers %v, the image %v",i+1,alpha_coverage_of(rgba8(level,len(level)/4,1),cutoff,1),wanted)
    }
}

@(test)
a_png_decodes_and_a_broken_one_fails_cleanly :: proc(t:^testing.T) {
    pixels:=checker(4,10,200);defer delete(pixels)
    png:=png_of(pixels,4,4);defer delete(png)
    image,error:=image_decode(png)
    defer image_destroy(&image)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,image.width==4 && image.height==4 && image.pixels[0]==10 && image.pixels[4]==200)

    _,bad:=image_decode(png[:20])
    testing.expect_value(t,bad,Error.Unsupported)
    garbage:=[]u8{1,2,3,4,5,6,7,8,9,10,11,12}
    _,bad=image_decode(garbage)
    testing.expect_value(t,bad,Error.Unsupported)
    _,bad=image_decode(nil)
    testing.expect_value(t,bad,Error.Unsupported)
    _,invalid:=build(rgba8(pixels[:8],4,4),{})
    testing.expect_value(t,invalid,Error.Invalid)
}

@(test)
a_built_texture_is_saved_and_read_back_by_asset :: proc(t:^testing.T) {
    pixels:=checker(8,0,255);defer delete(pixels)
    png:=png_of(pixels,8,8);defer delete(png)
    built,error:=from_bytes(png,{srgb=true,encoding=.Uncompressed})
    defer built_destroy(&built)
    testing.expect_value(t,error,Error.None)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"textures")
    if folder=="" {return}
    path:=fmt.tprintf("%s/texture.tex",folder)
    desc:=built_desc(&built,base.Asset_Id{7,1},nil)
    testing.expect_value(t,asset.texture_save(path,&types,desc),asset.Error.None)
    a:asset.Asset
    testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None)
    defer asset.asset_close(&a)
    view,view_error:=asset.texture_view(&a,&types)
    testing.expect_value(t,view_error,asset.Error.None)
    testing.expect(t,view.info.width==8 && view.info.height==8 && view.info.mip_count==4 && view.info.format==.RGBA8 && .Srgb in view.info.flags)
    testing.expect_value(t,len(asset.texture_mip(view,0)),8*8*4)
    testing.expect_value(t,asset.texture_mip(view,0)[4],u8(255))
}
