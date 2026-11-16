package movie

import "core:hash"
import "core:os"

// A PNG of three channels of 16 bits, from values in display encoding that
// it marks as sRGB; what lies outside 0 to 1 is clipped.
png16_write :: proc(path:string,pixels:[]f32,width,height:int) -> Error {
    bytes,error:=png16_encode(pixels,width,height)
    defer delete(bytes)
    if error!=.None {return error}
    if os.write_entire_file(path,bytes[:])!=nil {return .Write_Failed}
    return .None
}

png16_encode :: proc(pixels:[]f32,width,height:int,allocator:=context.allocator) -> (out:[dynamic]u8,error:Error) {
    out=make([dynamic]u8,allocator)
    if width<=0 || height<=0 || len(pixels)!=width*height*4 {return out,.Invalid}
    append(&out,0x89,'P','N','G','\r','\n',0x1a,'\n')
    chunk_begin :: proc(out:^[dynamic]u8,type:string) -> int {
        put_u32_be(out,0)
        at:=len(out)
        append(out,..transmute([]u8)type)
        return at
    }
    chunk_end :: proc(out:^[dynamic]u8,at:int) {
        size:=u32(len(out)-at-4)
        for i in 0..<4 {out[at-4+i]=u8(size>>(24-8*u32(i)))}
        put_u32_be(out,hash.crc32(out[at:]))
    }
    at:=chunk_begin(&out,"IHDR")
    put_u32_be(&out,u32(width));put_u32_be(&out,u32(height))
    append(&out,16,2,0,0,0) // 16 bits, RGB, deflate, adaptive filters, no interlace
    chunk_end(&out,at)
    at=chunk_begin(&out,"sRGB")
    append(&out,0) // perceptual
    chunk_end(&out,at)
    stride:=1+width*6
    rows,rows_error:=make([]u8,stride*height,allocator)
    defer delete(rows,allocator)
    if rows_error!=nil {return out,.Out_Of_Memory}
    for y in 0..<height {
        row:=rows[y*stride:][:stride]
        // Sub: each byte less the one of the pixel before.
        row[0]=1
        for x in 0..<width {
            for channel in 0..<3 {
                value:=u16(clamp(pixels[(y*width+x)*4+channel],0,1)*65535+0.5)
                offset:=1+x*6+channel*2
                row[offset],row[offset+1]=u8(value>>8),u8(value)
            }
        }
        for i:=stride-1;i>6;i-=1 {row[i]-=row[i-6]}
    }
    at=chunk_begin(&out,"IDAT")
    if !deflate_append(&out,rows) {return out,.Out_Of_Memory}
    chunk_end(&out,at)
    at=chunk_begin(&out,"IEND")
    chunk_end(&out,at)
    return out,.None
}
