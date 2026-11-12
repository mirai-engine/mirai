package textures

import "base:runtime"
import "core:hash"
import "core:math"
import "core:testing"

@(private="file")
height_png :: proc(values:[]u16,width,height:int,bits:u8=16) -> [dynamic]u8 {
    bytes,header,raw,zlib:[dynamic]u8
    defer {delete(header);delete(raw);delete(zlib)}
    be32 :: proc(out:^[dynamic]u8,value:u32) {append(out,u8(value>>24),u8(value>>16),u8(value>>8),u8(value))}
    chunk :: proc(out:^[dynamic]u8,kind:string,data:[]u8) {
        be32(out,u32(len(data)))
        first:=len(out^)
        append(out,..transmute([]u8)kind);append(out,..data)
        be32(out,hash.crc32(out^[first:]))
    }
    append(&bytes,137,80,78,71,13,10,26,10)
    be32(&header,u32(width));be32(&header,u32(height));append(&header,bits,0,0,0,0)
    chunk(&bytes,"IHDR",header[:])
    for row in 0..<height {
        append(&raw,0)
        for column in 0..<width {
            value:=values[row*width+column]
            if bits==16 {append(&raw,u8(value>>8))}
            append(&raw,u8(value))
        }
    }
    count:=u16(len(raw));inverse:=~count
    append(&zlib,0x78,0x01,0x01,u8(count),u8(count>>8),u8(inverse),u8(inverse>>8))
    append(&zlib,..raw[:]);be32(&zlib,hash.adler32(raw[:]))
    chunk(&bytes,"IDAT",zlib[:]);chunk(&bytes,"IEND",nil)
    return bytes
}

@(test)
heightmap_preserves_sixteen_bit_steps_and_top_to_bottom_rows :: proc(t:^testing.T) {
    values:=[6]u16{0,1,255,256,32768,65535}
    bytes:=height_png(values[:],3,2)
    defer delete(bytes)
    result,error:=heightmap_decode(bytes[:])
    defer heightmap_destroy(&result)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,result.width,3);testing.expect_value(t,result.height,2)
    testing.expect_value(t,len(result.values),len(values))
    for value,i in values {testing.expect_value(t,result.values[i],f32(value)/65535)}
    testing.expect(t,result.values[1]>0 && result.values[3]>result.values[2])
    testing.expect(t,result.values[4]>0.5 && result.values[4]<0.501)
}

@(test)
heightmap_expands_eight_bit_samples_without_srgb_conversion :: proc(t:^testing.T) {
    values:=[6]u16{0,1,128,254,255,70}
    bytes:=height_png(values[:],2,3,8)
    defer delete(bytes)
    result,error:=heightmap_decode(bytes[:])
    defer heightmap_destroy(&result)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,result.width,2);testing.expect_value(t,result.height,3)
    for value,i in values {testing.expect(t,abs(result.values[i]-f32(value)/255)<1e-7)}
    testing.expect(t,result.values[2]>0.5 && result.values[2]<0.503)
}

@(test)
heightmap_rejects_limits_invalid_sources_and_exhausted_allocators :: proc(t:^testing.T) {
    values:=[6]u16{0,1,128,254,255,70}
    bytes:=height_png(values[:],3,2)
    defer delete(bytes)
    _,error:=heightmap_decode(bytes[:],max_side=2,allocator=runtime.nil_allocator())
    testing.expect_value(t,error,Error.Too_Large)
    _,error=heightmap_decode(bytes[:],max_side=0)
    testing.expect_value(t,error,Error.Invalid)
    result:Heightmap
    result,error=heightmap_decode(bytes[:],allocator=runtime.nil_allocator())
    testing.expect_value(t,error,Error.Out_Of_Memory);testing.expect_value(t,len(result.values),0)
    _,error=heightmap_decode(bytes[:20])
    testing.expect_value(t,error,Error.Unsupported)
    _,error=heightmap_decode(nil)
    testing.expect_value(t,error,Error.Unsupported)
    bytes[16],bytes[17],bytes[18],bytes[19]=0,0,0x40,2
    bytes[20],bytes[21],bytes[22],bytes[23]=0,0,0x40,2
    _,error=heightmap_decode(bytes[:],16385,runtime.nil_allocator())
    testing.expect_value(t,error,Error.Too_Large)
    heightmap_destroy(&result);heightmap_destroy(&result);heightmap_destroy(nil)
}

@(test)
heightmap_returns_cleanly_for_truncations_and_corrupted_png_bytes :: proc(t:^testing.T) {
    values:=[6]u16{0,1,255,256,32768,65535}
    bytes:=height_png(values[:],3,2)
    defer delete(bytes)
    for count in 0..<len(bytes) {
        result,error:=heightmap_decode(bytes[:count],max_side=8)
        if error==.None {testing.expect_value(t,len(result.values),result.width*result.height)}
        heightmap_destroy(&result)
    }
    for &byte in bytes {
        saved:=byte;byte~=0x55
        result,error:=heightmap_decode(bytes[:],max_side=8)
        if error==.None {for value in result.values {testing.expect(t,value>=0 && value<=1)}}
        heightmap_destroy(&result);byte=saved
    }
}

@(test)
heightmap_rejects_pnm_before_the_decoder :: proc(t:^testing.T) {
    cases:=[4]struct {header:string,pixels:[]u8}{
        {"P5\n2 2\n255\n",{0,1,128,255}},
        {"P5\n2 2\n65535\n",{0,1,0,255,1,0,255,255}},
        {"P6\n2 2\n255\n",{0,1,128,255,255,255,128,1,0,0,255,0}},
        {"P6\n2 2\n65535\n",{0,1,0,255,1,0,255,255,255,255,255,255,128,0,0,1,0,0,0,0,255,255,0,0}},
    }
    for entry in cases {
        bytes:[dynamic]u8
        append(&bytes,..transmute([]u8)entry.header);append(&bytes,..entry.pixels)
        for count in 2..=len(bytes) {
            result,error:=heightmap_decode(bytes[:count])
            testing.expect_value(t,error,Error.Unsupported)
            testing.expect_value(t,len(result.values),0)
            testing.expect_value(t,result.width,0);testing.expect_value(t,result.height,0)
            heightmap_destroy(&result)
        }
        result,error:=heightmap_decode(bytes[:],allocator=runtime.nil_allocator())
        testing.expect_value(t,error,Error.Unsupported)
        heightmap_destroy(&result)
        delete(bytes)
    }
}

@(test)
an_encoded_heightmap_decodes_to_its_values_in_each_format :: proc(t:^testing.T) {
    side:=301
    values:=make([]f32,side*side);defer delete(values)
    for &value,i in values {x,z:=f32(i%side),f32(i/side);value=0.5+0.25*math.sin(x*0.05)*math.cos(z*0.03)}
    cases:=[3]struct {format:Heightmap_Format,worst:f32}{{.Image,0.5/65535+1e-7},{.R16,0.5/65535+1e-7},{.R32,0}}
    for entry in cases {
        bytes,error:=heightmap_encode(values,side,side,context.allocator,entry.format)
        defer delete(bytes)
        if !testing.expect_value(t,error,Error.None) {continue}
        testing.expect(t,len(bytes)<=heightmap_bytes_max(side),"the read limit takes what it writes")
        if entry.format==.Image {testing.expectf(t,len(bytes)<side*side*2*3/4,"smooth ground compresses: %d bytes for %d samples",len(bytes),side*side)}
        decoded,decode_error:=heightmap_decode(bytes,format=entry.format)
        defer heightmap_destroy(&decoded)
        if !testing.expect_value(t,decode_error,Error.None) {continue}
        testing.expect(t,decoded.width==side && decoded.height==side)
        worst:=f32(0)
        for value,i in values {worst=max(worst,abs(decoded.values[i]-value))}
        testing.expectf(t,worst<=entry.worst,"%v comes back within %v, not %v",entry.format,entry.worst,worst)
    }
    _,refused:=heightmap_encode(values,side,side-1)
    testing.expect_value(t,refused,Error.Invalid)
    wide:=[6]f32{0,0.2,0.4,0.6,0.8,1}
    _,refused=heightmap_encode(wide[:],3,2,context.allocator,.R16)
    testing.expect_value(t,refused,Error.Invalid)
    _,refused=heightmap_encode([]f32{math.nan_f32()},1,1,context.allocator,.R32)
    testing.expect_value(t,refused,Error.Invalid)
}

@(test)
raw_heightmaps_are_squares_of_finite_values_within_the_limit :: proc(t:^testing.T) {
    format,known:=heightmap_format("ground.R32")
    testing.expect(t,known && format==.R32)
    _,known=heightmap_format("ground.exr")
    testing.expect(t,!known)
    nan:=transmute([4]u8)math.nan_f32()
    cases:=[5]struct {bytes:[]u8,format:Heightmap_Format,max_side:int,error:Error}{
        {{1,2,3},.R16,8,.Invalid},           // not whole samples
        {{1,2,3,4,5,6},.R16,8,.Invalid},     // three samples, not a square
        {{0,0,0,0,0,0,0,0},.R16,1,.Too_Large},
        {nan[:],.R32,8,.Invalid},
        {nil,.R32,8,.Invalid},
    }
    for entry in cases {
        result,error:=heightmap_decode(entry.bytes,entry.max_side,context.allocator,entry.format)
        testing.expect_value(t,error,entry.error)
        testing.expect_value(t,len(result.values),0)
        heightmap_destroy(&result)
    }
    _,error:=heightmap_decode([]u8{0,0,255,255,0,128,255,127},format=.R16,allocator=runtime.nil_allocator())
    testing.expect_value(t,error,Error.Out_Of_Memory)
}

@(test)
a_heightmap_of_the_most_samples_a_terrain_takes_is_not_too_large :: proc(t:^testing.T) {
    values:=[6]u16{0,1,128,254,255,70}
    bytes:=height_png(values[:],3,2)
    defer delete(bytes)
    // Its header says 16385 by 16385: past what the decoder takes in pixels of a texture.
    bytes[16],bytes[17],bytes[18],bytes[19]=0,0,0x40,0x01
    bytes[20],bytes[21],bytes[22],bytes[23]=0,0,0x40,0x01
    _,error:=heightmap_decode(bytes[:],16385,runtime.nil_allocator())
    testing.expect_value(t,error,Error.Out_Of_Memory)
    testing.expect(t,heightmap_bytes_max(16385)>=16385*16385*4,"the read limit takes an R32 of that side")
}
