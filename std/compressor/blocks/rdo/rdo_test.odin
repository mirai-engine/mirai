package rdo

import "core:math"
import "core:mem"
import "core:slice"
import "core:testing"
import "core:time"
import "mirai:std/jobs"
import "../rgbcx"
import "../bc7enc"

@(private="file") ALL_FORMATS :: [?]Format{.BC1,.BC3,.BC4,.BC5,.BC7}

@(private="file")
bytes_per_block :: proc(format:Format) -> int {return format==.BC1 || format==.BC4?8:16}

@(private="file")
out_size :: proc(format:Format,width,height:int) -> int {return (width+3)/4*((height+3)/4)*bytes_per_block(format)}

// Gradients with light noise and a noisier corner, the same on every run. No
// block is exactly flat: ERT fills the free selectors of a flat BC4 block with
// bytes of earlier blocks, which helps LZ but raises the order-0 entropy.
@(private="file")
make_image :: proc(width,height:int) -> []u8 {
    pixels:=make([]u8,width*height*4)
    state:u32=0x12345678
    for y in 0..<height {
        for x in 0..<width {
            state=state*1664525+1013904223
            amplitude:=x>=width*3/4 && y>=height*3/4?24:3
            noise:[4]int
            for i in 0..<4 {noise[i]=int((state>>(8*uint(i)))&0xFF)%(2*amplitude+1)-amplitude}
            c:=[4]int{40+x*2,60+y*2,(x+y)+90,200+y/2}+noise
            p:=pixels[(x+y*width)*4:]
            for v,i in c {p[i]=u8(clamp(v,0,255))}
        }
    }
    return pixels
}

@(private="file")
test_params :: proc() -> Params {
    p:=params_default()
    p.bc7_uber_level=1
    p.bc7enc_max_partitions_to_scan=16
    p.bc1_quality_level=8
    return p
}

@(private="file")
decode_block :: proc(format:Format,block:[^]u8,out:^[16]Color_Rgba,p:Params) {
    texels:=([^]u8)(&out[0][0])
    for &c in out {c={0,0,0,255}}
    switch format {
    case .BC1:_=rgbcx.unpack_bc1(block,texels,true,p.bc1_mode)
    case .BC3:_=rgbcx.unpack_bc3(block,texels,p.bc1_mode)
    case .BC4:rgbcx.unpack_bc4(block,texels,4)
    case .BC5:rgbcx.unpack_bc5(block,texels,0,1,4)
    case .BC7:_=bc7enc.unpack_bc7(block,texels)
    }
}

// PSNR over the channels the format stores, against the bordered source.
@(private="file")
psnr :: proc(format:Format,encoded:[]u8,pixels:[]u8,width,height:int,p:Params,channel:=0) -> f64 {
    channels:[]int
    switch format {
    case .BC1:channels={0,1,2}
    case .BC3,.BC7:channels={0,1,2,3}
    case .BC4:channels={channel}
    case .BC5:channels={0,1}
    }
    blocks_x:=(width+3)/4
    blocks_y:=(height+3)/4
    total_err,samples:f64
    for by in 0..<blocks_y {
        for bx in 0..<blocks_x {
            decoded:[16]Color_Rgba
            decode_block(format,&encoded[(bx+by*blocks_x)*bytes_per_block(format)],&decoded,p)
            for y in 0..<4 {
                for x in 0..<4 {
                    src:=pixels[(min(bx*4+x,width-1)+min(by*4+y,height-1)*width)*4:]
                    for c in channels {
                        target:=format==.BC4?0:c
                        d:=f64(src[c])-f64(decoded[x+y*4][target])
                        total_err+=d*d
                        samples+=1
                    }
                }
            }
        }
    }
    mse:=total_err/samples
    return mse==0?200:10*math.log10(255*255/mse)
}

@(private="file")
order0_bits :: proc(data:[]u8) -> f64 {
    histogram:[256]int
    for b in data {histogram[b]+=1}
    bits:f64
    total:=f64(len(data))
    for count in histogram {
        if count>0 {bits-=f64(count)*math.log2(f64(count)/total)}
    }
    return bits
}

@(private="file",rodata)
PSNR_BOUND:=[Format]f64{.BC1=26,.BC3=26,.BC4=28,.BC5=28,.BC7=30}

@(private="file")
check_lambda :: proc(t:^testing.T,format:Format,width,height:int) {
    pixels:=make_image(width,height)
    defer delete(pixels)
    base:=test_params()
    plain:=make([]u8,out_size(format,width,height))
    defer delete(plain)
    testing.expect(t,encode(format,pixels,width,height,base,plain))

    rdo_params:=base
    rdo_params.rdo_lambda=1
    reduced:=make([]u8,len(plain))
    defer delete(reduced)
    testing.expect(t,encode(format,pixels,width,height,rdo_params,reduced))

    plain_psnr:=psnr(format,plain,pixels,width,height,base)
    reduced_psnr:=psnr(format,reduced,pixels,width,height,rdo_params)
    testing.expectf(t,reduced_psnr>PSNR_BOUND[format],"%v %dx%d: PSNR %.2f (plain %.2f)",format,width,height,reduced_psnr,plain_psnr)
    plain_bits:=order0_bits(plain)
    reduced_bits:=order0_bits(reduced)
    testing.expectf(t,reduced_bits<=plain_bits,"%v %dx%d: %.0f bits against %.0f",format,width,height,reduced_bits,plain_bits)
}

@(test)
lambda_keeps_quality_and_lowers_entropy_on_64x64 :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,120*time.Second)
    for format in ALL_FORMATS {check_lambda(t,format,64,64)}
}

@(test)
lambda_keeps_quality_and_lowers_entropy_on_5x3 :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,120*time.Second)
    for format in ALL_FORMATS {check_lambda(t,format,5,3)}
}

@(test)
channels_other_than_red_are_measured_by_rdo :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,120*time.Second)
    pixels:=make_image(64,64)
    defer delete(pixels)
    p:=test_params()
    p.rdo_lambda=4
    p.bc45_channel0=2
    out:=make([]u8,out_size(.BC4,64,64))
    defer delete(out)
    testing.expect(t,encode(.BC4,pixels,64,64,p,out))
    value:=psnr(.BC4,out,pixels,64,64,p,2)
    testing.expectf(t,value>PSNR_BOUND[.BC4],"PSNR %.2f",value)
}

@(test)
invalid_input_returns_false :: proc(t:^testing.T) {
    pixels:=make_image(8,8)
    defer delete(pixels)
    p:=test_params()
    for format in ALL_FORMATS {
        out:=make([]u8,out_size(format,8,8))
        defer delete(out)
        testing.expect(t,encode(format,pixels,8,8,p,out))
        testing.expect(t,!encode(format,pixels,0,8,p,out))
        testing.expect(t,!encode(format,pixels,8,0,p,out))
        testing.expect(t,!encode(format,pixels,-8,-8,p,out))
        testing.expect(t,!encode(format,pixels,max(int),max(int),p,out))
        testing.expect(t,!encode(format,pixels[:len(pixels)-1],8,8,p,out))
        testing.expect(t,!encode(format,pixels,8,8,p,out[:len(out)-1]))
        testing.expect(t,!encode(format,pixels,8,8,p,nil))
        for broken in ([]proc(q:^Params){
            proc(q:^Params){q.bc7_uber_level=-1},
            proc(q:^Params){q.bc7enc_max_partitions_to_scan=bc7enc.MAX_PARTITIONS+1},
            proc(q:^Params){q.bc1_quality_level=rgbcx.MAX_LEVEL+1},
            proc(q:^Params){q.bc45_channel0=4},
            proc(q:^Params){q.bc45_channel1=4},
            proc(q:^Params){q.bc345_search_rad=-1},
        }) {
            q:=p
            broken(&q)
            testing.expect(t,!encode(format,pixels,8,8,q,out))
        }
    }
    p.rdo_lambda=math.nan_f32()
    out:=make([]u8,out_size(.BC4,8,8))
    defer delete(out)
    testing.expect(t,encode(.BC4,pixels,8,8,p,out))
}

@(private="file")
Failing_Allocator :: struct {
    remaining:int,
    backing:mem.Allocator,
}

@(private="file")
failing_allocator_proc :: proc(data:rawptr,mode:mem.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,mem.Allocator_Error) {
    f:=cast(^Failing_Allocator)data
    if mode==.Alloc || mode==.Alloc_Non_Zeroed {
        if f.remaining==0 {return nil,.Out_Of_Memory}
        f.remaining-=1
    }
    return f.backing.procedure(f.backing.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
out_of_memory_returns_false :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,120*time.Second)
    pixels:=make_image(16,16)
    defer delete(pixels)
    p:=test_params()
    p.rdo_lambda=1
    for format in ALL_FORMATS {
        out:=make([]u8,out_size(format,16,16))
        defer delete(out)
        succeeded:=false
        for budget in 0..<32 {
            failing:=Failing_Allocator{budget,context.allocator}
            allocator:=mem.Allocator{failing_allocator_proc,&failing}
            if encode(format,pixels,16,16,p,out,allocator=allocator) {succeeded=true;break}
        }
        testing.expectf(t,succeeded,"%v never succeeded",format)
    }
}

@(test)
unusual_parameters_do_not_fail :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,120*time.Second)
    pixels:=make_image(16,16)
    defer delete(pixels)
    for format in ALL_FORMATS {
        out:=make([]u8,out_size(format,16,16))
        defer delete(out)
        p:=test_params()
        p.rdo_lambda=2
        p.bc345_mode_mask=0
        p.bc7enc_reduce_entropy=true
        p.lookback_window_size=max(u32)
        p.rdo_allow_relative_movement=true
        p.custom_rdo_smooth_block_error_scale=true
        p.rdo_max_smooth_block_std_dev=0
        testing.expect(t,encode(format,pixels,16,16,p,out))
    }
}

@(test)
reduce_entropy_rejects_bad_layouts :: proc(t:^testing.T) {
    unpack :: proc(block:[^]u8,pixels:[^]Color_Rgba,block_index:u32,user:rawptr) -> bool {return true}
    blocks:[32]u8
    pixels:[32]Color_Rgba
    p:=reduce_entropy_params_default()
    _,ok:=reduce_entropy(blocks[:],2,16,16,4,4,4,pixels[:],p,unpack,nil)
    testing.expect(t,ok)
    _,ok=reduce_entropy(blocks[:],3,16,16,4,4,4,pixels[:],p,unpack,nil)
    testing.expect(t,!ok)
    _,ok=reduce_entropy(blocks[:],2,8,16,4,4,4,pixels[:],p,unpack,nil)
    testing.expect(t,!ok)
    _,ok=reduce_entropy(blocks[:],2,16,2,4,4,4,pixels[:],p,unpack,nil)
    testing.expect(t,!ok)
    _,ok=reduce_entropy(blocks[:],2,16,16,4,4,3,pixels[:],p,unpack,nil)
    testing.expect(t,!ok)
    p.color_weights={}
    _,ok=reduce_entropy(blocks[:],2,16,16,4,4,4,pixels[:],p,unpack,nil)
    testing.expect(t,!ok)
    p=reduce_entropy_params_default()
    _,ok=reduce_entropy(blocks[:],2,16,16,4,4,4,pixels[:],p,nil,nil)
    testing.expect(t,!ok)
    _,ok=reduce_entropy(blocks[:],2,16,16,4,4,4,pixels[:8],p,unpack,nil)
    testing.expect(t,!ok)
}

@(private="file")
check_threads :: proc(t:^testing.T,js:^jobs.Job_System,format:Format,width,height:int) {
    pixels:=make_image(width,height)
    defer delete(pixels)
    p:=test_params()
    p.rdo_lambda=1
    serial:=make([]u8,out_size(format,width,height))
    defer delete(serial)
    threaded:=make([]u8,len(serial))
    defer delete(threaded)
    testing.expect(t,encode(format,pixels,width,height,p,serial))
    testing.expect(t,encode(format,pixels,width,height,p,threaded,jobs.Worker_Ref{system=js,worker=jobs.OWNER}))
    testing.expectf(t,slice.equal(serial,threaded),"%v %dx%d differs between one thread and several",format,width,height)
}

@(test)
output_does_not_depend_on_the_thread_count :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,180*time.Second)
    js:jobs.Job_System
    testing.expect(t,jobs.system_init(&js,{threads=3}))
    defer jobs.system_destroy(&js)
    for format in ALL_FORMATS {
        check_threads(t,&js,format,64,64)
        check_threads(t,&js,format,5,3)
    }
    // Above the chunking threshold.
    check_threads(t,&js,.BC4,256,256)
}

// A block RDO rewrites decodes alpha 0 and 255 where the image has them, in each format with
// alpha, at the strongest lambda.
@(test)
rdo_keeps_alpha_0_and_255 :: proc(t:^testing.T) {
    WIDTH,HEIGHT :: 64,64
    pixels:=make_image(WIDTH,HEIGHT);defer delete(pixels)
    for y in 0..<HEIGHT {
        for x in 0..<WIDTH {pixels[(x+y*WIDTH)*4+3]=0 if x<16 else 255 if x<48 else u8(100+y)}
    }
    for format in ([?]Format{.BC3,.BC7}) {
        p:=test_params()
        p.rdo_lambda=10
        out:=make([]u8,out_size(format,WIDTH,HEIGHT));defer delete(out)
        if !testing.expect(t,encode(format,pixels,WIDTH,HEIGHT,p,out)) {continue}
        wrong:=0
        for by in 0..<HEIGHT/4 {
            for bx in 0..<WIDTH/4 {
                decoded:[16]Color_Rgba
                decode_block(format,raw_data(out[(bx+by*WIDTH/4)*bytes_per_block(format):]),&decoded,p)
                for i in 0..<16 {
                    source:=pixels[((bx*4+i%4)+(by*4+i/4)*WIDTH)*4+3]
                    if (source==0 || source==255) && decoded[i][3]!=source {wrong+=1}
                }
            }
        }
        testing.expectf(t,wrong==0,"%v: %d texels of alpha 0 or 255 decode otherwise",format,wrong)
    }
}
