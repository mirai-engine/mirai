package movie

import "core:c"
import "core:compress/deflate"
import "core:os"
import "core:path/filepath"
import "core:testing"
import stbi "vendor:stb/image"
import "mirai:std/base"

@(private="file")
gradient :: proc(width,height:int,scale:f32) -> []f32 {
    pixels:=make([]f32,width*height*4,context.temp_allocator)
    for y in 0..<height {
        for x in 0..<width {
            at:=(y*width+x)*4
            pixels[at]=f32(x)/f32(width-1)*scale
            pixels[at+1]=f32(y)/f32(height-1)*scale
            pixels[at+2]=f32(x+y)/f32(width+height-2)*scale
            pixels[at+3]=1
        }
    }
    return pixels
}

@(test)
an_exr_keeps_each_channel_as_a_half_beyond_one :: proc(t:^testing.T) {
    width,height:=37,21
    pixels:=gradient(width,height,40)
    pixels[0]=1e9
    out,error:=exr_encode(pixels,width,height,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,len(out)>8 && out[0]==0x76 && out[1]==0x2f && out[2]==0x31 && out[3]==0x01)
    // The offset table follows the header: two blocks of 16 lines.
    header:=0
    for i in 8..<len(out)-1 {
        if string(out[i:][:min(len("screenWindowWidth"),len(out)-i)])=="screenWindowWidth" {header=i;break}
    }
    testing.expect(t,header>0)
    table:=header+len("screenWindowWidth")+1+len("float")+1+4+4+1
    seen:=0
    for block in 0..<2 {
        offset:=0
        for i in 0..<8 {offset|=int(out[table+block*8+i])<<(uint(i)*8)}
        y:=int(out[offset])|int(out[offset+1])<<8
        size:=int(out[offset+4])|int(out[offset+5])<<8|int(out[offset+6])<<16
        lines:=min(16,height-y)
        n:=lines*width*3*2
        raw:=make([]u8,n,context.temp_allocator)
        if size<n {
            unpacked:[dynamic]u8
            defer delete(unpacked)
            testing.expect(t,deflate.inflate_zlib(&unpacked,out[offset+8:][:size])==nil)
            packed:=unpacked[:]
            testing.expect_value(t,len(packed),n)
            for i in 1..<n {packed[i]=u8(int(packed[i-1])+int(packed[i])-128)}
            half_of:=(n+1)/2
            for i in 0..<n {raw[i]=i%2==0?packed[i/2]:packed[half_of+i/2]}
        } else {copy(raw,out[offset+8:][:n])}
        for line in 0..<lines {
            for channel,index in ([3]int{2,1,0}) {
                for x in 0..<width {
                    at:=(line*width*3+index*width+x)*2
                    value:=f32(transmute(f16)(u16(raw[at])|u16(raw[at+1])<<8))
                    wanted:=min(pixels[((y+line)*width+x)*4+channel],EXR_HALF_MAX)
                    if abs(value-wanted)>abs(wanted)*1e-3+1e-4 {testing.expectf(t,false,"pixel %d,%d channel %d is %f, not %f",x,y+line,channel,value,wanted);return}
                    seen+=1
                }
            }
        }
    }
    testing.expect_value(t,seen,width*height*3)
}

@(test)
a_png16_holds_sixteen_bits_a_channel :: proc(t:^testing.T) {
    width,height:=29,13
    pixels:=gradient(width,height,1)
    out,error:=png16_encode(pixels,width,height,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    w,h,channels:c.int
    image:=stbi.load_16_from_memory(raw_data(out),c.int(len(out)),&w,&h,&channels,3)
    if !testing.expect(t,image!=nil) {return}
    defer stbi.image_free(image)
    testing.expect_value(t,int(w),width)
    testing.expect_value(t,int(h),height)
    for y in 0..<height {
        for x in 0..<width {
            for channel in 0..<3 {
                wanted:=u16(pixels[(y*width+x)*4+channel]*65535+0.5)
                testing.expect_value(t,image[(y*width+x)*3+channel],wanted)
            }
        }
    }
}

@(test)
a_wav_written_in_parts_says_how_long_it_is :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"movie")
    if folder=="" {return}
    path,_:=filepath.join({folder,"mirai_movie_test.wav"},context.temp_allocator)
    w:Wav_Writer
    testing.expect_value(t,wav_open(&w,path,48000,2),Error.None)
    part:=[?]f32{0.5,-0.5,0.25,-0.25}
    testing.expect_value(t,wav_append(&w,part[:]),Error.None)
    testing.expect_value(t,wav_append(&w,part[:]),Error.None)
    testing.expect_value(t,wav_close(&w),Error.None)
    data,read_error:=os.read_entire_file(path,context.temp_allocator)
    testing.expect(t,read_error==nil)
    testing.expect_value(t,len(data),WAV_HEADER+8*4)
    le :: proc(b:[]u8) -> u32 {return u32(b[0])|u32(b[1])<<8|u32(b[2])<<16|u32(b[3])<<24}
    testing.expect_value(t,string(data[0:4]),"RIFF")
    testing.expect_value(t,le(data[4:]),u32(len(data)-8))
    testing.expect_value(t,le(data[46:]),4)  // frames, in fact
    testing.expect_value(t,le(data[54:]),32) // bytes of data
    testing.expect_value(t,transmute(f32)le(data[WAV_HEADER+4:]),-0.5)
}
