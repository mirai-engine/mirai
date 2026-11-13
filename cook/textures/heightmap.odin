package textures

import "core:c"
import "core:compress/deflate"
import "core:hash"
import "core:math"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import stbi "vendor:stb/image"

// What a file of heights holds. Image: a PNG (8 or 16 bits), TGA or BMP whose
// integers go from 0 to 1. R16: little-endian u16 from 0 to 1. R32:
// little-endian f32 as they are, which keeps every height a terrain holds.
// The raw ones have no header: they are square, a side the root of their
// samples, rows from the top.
Heightmap_Format :: enum u8 {Image,R16,R32}

Heightmap :: struct {
    values:[]f32,
    width,height:int,
    allocator:mem.Allocator,
}

heightmap_destroy :: proc(heightmap:^Heightmap) {
    if heightmap==nil {return}
    delete(heightmap.values,heightmap.allocator)
    heightmap^={}
}

// The format of a file by its extension: png, tga and bmp are images, r16
// and raw are R16 and r32 is R32.
heightmap_format :: proc(path:string) -> (format:Heightmap_Format,ok:bool) {
    ext:=filepath.ext(path)
    for name in ([3]string{".png",".tga",".bmp"}) {if strings.equal_fold(ext,name) {return .Image,true}}
    if strings.equal_fold(ext,".r16") || strings.equal_fold(ext,".raw") {return .R16,true}
    if strings.equal_fold(ext,".r32") {return .R32,true}
    return
}

// The most bytes a file of a heightmap of max_side samples a side takes in
// any format: four of R32 per sample, or what a TGA of 32 bits coded by runs
// adds to them.
heightmap_bytes_max :: proc "contextless" (max_side:int) -> int {
    side:=clamp(max_side,0,MAX_SOURCE_SIDE)
    return side*side*4+side*side/32+1<<16
}

// Rows start at the top; integer channels are normalized without gamma conversion.
heightmap_decode :: proc(bytes:[]u8,max_side:int=MAX_SOURCE_SIDE,allocator:=context.allocator,format:=Heightmap_Format.Image) -> (heightmap:Heightmap,error:Error) {
    if max_side<=0 {return {},.Invalid}
    side_max:=min(max_side,MAX_SOURCE_SIDE)
    if format!=.Image {return heightmap_raw_decode(bytes,side_max,format,allocator)}
    if len(bytes)==0 || len(bytes)>int(max(c.int)) {return {},.Unsupported}
    // The bundled stb PNM path mishandles 16-bit channels and truncated payloads.
    if len(bytes)>=2 && bytes[0]=='P' && (bytes[1]=='5' || bytes[1]=='6') {return {},.Unsupported}
    x,y,components:c.int
    if stbi.info_from_memory(raw_data(bytes),c.int(len(bytes)),&x,&y,&components)==0 {return {},.Unsupported}
    if x<=0 || y<=0 || int(x)>side_max || int(y)>side_max {return {},.Too_Large}
    if stbi.is_hdr_from_memory(raw_data(bytes),c.int(len(bytes)))!=0 {return {},.Unsupported}
    width,height:=int(x),int(y)
    count:=width*height
    values,alloc_error:=make([]f32,count,allocator)
    if alloc_error!=nil {return {},.Out_Of_Memory}
    decoded:=stbi.load_16_from_memory(raw_data(bytes),c.int(len(bytes)),&x,&y,&components,1)
    if decoded==nil {delete(values,allocator);return {},.Unsupported}
    defer stbi.image_free(decoded)
    if int(x)!=width || int(y)!=height {delete(values,allocator);return {},.Invalid}
    for value,i in decoded[:count] {values[i]=f32(value)/65535}
    return {values=values,width=width,height=height,allocator=allocator},.None
}

@(private="file")
heightmap_raw_decode :: proc(bytes:[]u8,side_max:int,format:Heightmap_Format,allocator:mem.Allocator) -> (heightmap:Heightmap,error:Error) {
    size:=format==.R16?2:4
    count:=len(bytes)/size
    side:=int(math.sqrt(f64(count)))
    for side*side>count {side-=1}
    for (side+1)*(side+1)<=count {side+=1}
    if side<1 || side*side*size!=len(bytes) {return {},.Invalid}
    if side>side_max {return {},.Too_Large}
    values,alloc_error:=make([]f32,count,allocator)
    if alloc_error!=nil {return {},.Out_Of_Memory}
    for &value,i in values {
        b:=bytes[i*size:]
        if format==.R16 {value=f32(u16(b[0])|u16(b[1])<<8)/65535;continue}
        value=transmute(f32)(u32(b[0])|u32(b[1])<<8|u32(b[2])<<16|u32(b[3])<<24)
        if value-value!=0 {delete(values,allocator);return {},.Invalid}
    }
    return {values=values,width=side,height=side,allocator=allocator},.None
}

// A heightmap as heightmap_decode reads it, rows from the top: a 16-bit
// grayscale PNG or R16 of values from 0 to 1, or R32 of finite values. The
// raw ones are square.
heightmap_encode :: proc(values:[]f32,width,height:int,allocator:=context.allocator,format:=Heightmap_Format.Image) -> (bytes:[]u8,error:Error) {
    if width<=0 || height<=0 || width>MAX_SOURCE_SIDE || height>MAX_SOURCE_SIDE || len(values)!=width*height {return nil,.Invalid}
    unit :: proc "contextless" (v:f32) -> u16 {return u16(clamp(v-v==0?v:0,0,1)*65535+0.5)}
    if format!=.Image {
        if width!=height {return nil,.Invalid}
        size:=format==.R16?2:4
        out,out_error:=make([]u8,len(values)*size,allocator)
        if out_error!=nil {return nil,.Out_Of_Memory}
        for v,i in values {
            if format==.R16 {
                sample:=unit(v)
                out[i*2],out[i*2+1]=u8(sample),u8(sample>>8)
                continue
            }
            if v-v!=0 {delete(out,allocator);return nil,.Invalid}
            bits:=transmute(u32)v
            out[i*4],out[i*4+1],out[i*4+2],out[i*4+3]=u8(bits),u8(bits>>8),u8(bits>>16),u8(bits>>24)
        }
        return out,.None
    }
    // Each row Paeth filtered over the samples before it: smooth ground
    // leaves small differences that deflate takes.
    row:=1+width*2
    raw,raw_error:=make([]u8,row*height,context.temp_allocator)
    if raw_error!=nil {return nil,.Out_Of_Memory}
    for z in 0..<height {
        line:=raw[z*row+1:][:width*2]
        for x in 0..<width {
            sample:=unit(values[x+width*z])
            line[x*2],line[x*2+1]=u8(sample>>8),u8(sample)
        }
    }
    for z:=height-1;z>=0;z-=1 {
        line:=raw[z*row+1:][:width*2]
        above:=z>0?raw[(z-1)*row+1:][:width*2]:nil
        raw[z*row]=4
        for i:=len(line)-1;i>=0;i-=1 {
            a:=i>=2?int(line[i-2]):0
            b:=above!=nil?int(above[i]):0
            d:=i>=2 && above!=nil?int(above[i-2]):0
            p:=a+b-d
            pa,pb,pd:=abs(p-a),abs(p-b),abs(p-d)
            predicted:=pa<=pb && pa<=pd?a:pb<=pd?b:d
            line[i]=u8(int(line[i])-predicted)
        }
    }
    zipped,zip_error:=make([]u8,deflate.deflate_bound(len(raw)),context.temp_allocator)
    if zip_error!=nil {return nil,.Out_Of_Memory}
    state:=new(deflate.Deflate,context.temp_allocator)
    if state==nil {return nil,.Out_Of_Memory}
    written,deflate_error:=deflate.deflate_zlib_to_slice(state,zipped,raw)
    if deflate_error!=nil {return nil,.Out_Of_Memory}
    out,out_error:=make([dynamic]u8,0,8+25+12+written+12,allocator)
    if out_error!=nil {return nil,.Out_Of_Memory}
    big :: proc(out:^[dynamic]u8,value:u32) {append(out,u8(value>>24),u8(value>>16),u8(value>>8),u8(value))}
    chunk_begin :: proc(out:^[dynamic]u8,kind:string,size:int) -> int {
        big(out,u32(size))
        at:=len(out)
        append(out,..transmute([]u8)kind)
        return at
    }
    chunk_end :: proc(out:^[dynamic]u8,at:int) {big(out,hash.crc32(out[at:]))}
    append(&out,0x89,'P','N','G','\r','\n',0x1a,'\n')
    at:=chunk_begin(&out,"IHDR",13)
    big(&out,u32(width));big(&out,u32(height))
    append(&out,16,0,0,0,0) // 16 bits, grayscale, deflate, adaptive filters, no interlace
    chunk_end(&out,at)
    at=chunk_begin(&out,"IDAT",written)
    append(&out,..zipped[:written])
    chunk_end(&out,at)
    at=chunk_begin(&out,"IEND",0)
    chunk_end(&out,at)
    if len(out)!=8+25+12+written+12 {delete(out);return nil,.Invalid}
    return out[:],.None
}
