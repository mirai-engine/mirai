package movie

import "core:math"
import "core:os"

// The lines of a block of the ZIP compression of OpenEXR.
@(private)
EXR_BLOCK_LINES :: 16
@(private)
EXR_HALF_MAX :: f32(65504)

// An OpenEXR scanline image of three half channels (B, G and R, as the format
// orders them), ZIP compressed, in the primaries of Rec.709 that OpenEXR takes
// when it names none. A value beyond what a half holds is kept at the largest
// one; one that is not a number, at zero.
exr_write :: proc(path:string,pixels:[]f32,width,height:int) -> Error {
    bytes,error:=exr_encode(pixels,width,height)
    defer delete(bytes)
    if error!=.None {return error}
    if os.write_entire_file(path,bytes[:])!=nil {return .Write_Failed}
    return .None
}

exr_encode :: proc(pixels:[]f32,width,height:int,allocator:=context.allocator) -> (out:[dynamic]u8,error:Error) {
    out=make([dynamic]u8,allocator)
    if width<=0 || height<=0 || len(pixels)!=width*height*4 {return out,.Invalid}
    append(&out,0x76,0x2f,0x31,0x01, 2,0,0,0)
    attribute :: proc(out:^[dynamic]u8,name,type:string,size:int) {
        append(out,..transmute([]u8)name);append(out,0)
        append(out,..transmute([]u8)type);append(out,0)
        put_u32_le(out,u32(size))
    }
    attribute(&out,"channels","chlist",3*18+1)
    for name in ([3]string{"B","G","R"}) {
        append(&out,name[0],0)
        put_u32_le(&out,1) // HALF
        append(&out,0,0,0,0)
        put_u32_le(&out,1);put_u32_le(&out,1)
    }
    append(&out,0)
    attribute(&out,"compression","compression",1);append(&out,3) // ZIP, blocks of 16 lines
    for name in ([2]string{"dataWindow","displayWindow"}) {
        attribute(&out,name,"box2i",16)
        put_u32_le(&out,0);put_u32_le(&out,0);put_u32_le(&out,u32(width-1));put_u32_le(&out,u32(height-1))
    }
    attribute(&out,"lineOrder","lineOrder",1);append(&out,0)
    attribute(&out,"pixelAspectRatio","float",4);put_u32_le(&out,transmute(u32)f32(1))
    attribute(&out,"screenWindowCenter","v2f",8);put_u32_le(&out,0);put_u32_le(&out,0)
    attribute(&out,"screenWindowWidth","float",4);put_u32_le(&out,transmute(u32)f32(1))
    append(&out,0)
    blocks:=(height+EXR_BLOCK_LINES-1)/EXR_BLOCK_LINES
    table:=len(out)
    if resize(&out,len(out)+blocks*8)!=nil {return out,.Out_Of_Memory}
    raw,raw_error:=make([]u8,EXR_BLOCK_LINES*width*3*2,allocator)
    defer delete(raw,allocator)
    packed,packed_error:=make([]u8,len(raw),allocator)
    defer delete(packed,allocator)
    if raw_error!=nil || packed_error!=nil {return out,.Out_Of_Memory}
    zipped:=make([dynamic]u8,allocator)
    defer delete(zipped)
    for block in 0..<blocks {
        y0:=block*EXR_BLOCK_LINES
        lines:=min(EXR_BLOCK_LINES,height-y0)
        n:=lines*width*3*2
        at:=0
        for y in y0..<y0+lines {
            row:=pixels[y*width*4:][:width*4]
            for channel in ([3]int{2,1,0}) {
                for x in 0..<width {
                    half:=transmute(u16)exr_half(row[x*4+channel])
                    raw[at],raw[at+1]=u8(half),u8(half>>8)
                    at+=2
                }
            }
        }
        // The predictor of ZIP over the bytes split in halves.
        half_of:=(n+1)/2
        for i in 0..<n {
            if i%2==0 {packed[i/2]=raw[i]} else {packed[half_of+i/2]=raw[i]}
        }
        previous:=int(packed[0])
        for i in 1..<n {
            value:=int(packed[i])
            packed[i]=u8(value-previous+128+256)
            previous=value
        }
        clear(&zipped)
        if !deflate_append(&zipped,packed[:n]) {return out,.Out_Of_Memory}
        offset:=u64(len(out))
        for i in 0..<8 {out[table+block*8+i]=u8(offset>>(u64(i)*8))}
        put_u32_le(&out,u32(y0))
        // Stored as is when compressing does not make it smaller.
        if len(zipped)<n {
            put_u32_le(&out,u32(len(zipped)))
            append(&out,..zipped[:])
        } else {
            put_u32_le(&out,u32(n))
            append(&out,..raw[:n])
        }
    }
    return out,.None
}

@(private)
exr_half :: proc "contextless" (v:f32) -> f16 {
    if math.is_nan(v) {return 0}
    return f16(clamp(v,-EXR_HALF_MAX,EXR_HALF_MAX))
}
