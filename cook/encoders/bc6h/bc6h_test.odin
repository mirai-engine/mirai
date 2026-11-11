package bc6h

import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:std/jobs"

@(private="file")
Field :: struct {endpoint,msb,lsb:u8}

@(private="file") R0 :: u8(0)
@(private="file") G0 :: u8(1)
@(private="file") B0 :: u8(2)
@(private="file") R1 :: u8(3)
@(private="file") G1 :: u8(4)
@(private="file") B1 :: u8(5)
@(private="file") R2 :: u8(6)
@(private="file") G2 :: u8(7)
@(private="file") B2 :: u8(8)
@(private="file") R3 :: u8(9)
@(private="file") G3 :: u8(10)
@(private="file") B3 :: u8(11)

@(private="file")
Mode_Layout :: struct {
    prefix:u32,
    prefix_bits,endpoint_bits:int,
    delta_bits:[3]int,
    subsets:int,
    transformed:bool,
    fields:[]Field,
}

@(private="file")
LAYOUTS := [14]Mode_Layout{
    {0,2,10,{5,5,5},2,true,{{G2,4,4},{B2,4,4},{B3,4,4},{R0,9,0},{G0,9,0},{B0,9,0},{R1,4,0},{G3,4,4},{G2,3,0},{G1,4,0},{B3,0,0},{G3,3,0},{B1,4,0},{B3,1,1},{B2,3,0},{R2,4,0},{B3,2,2},{R3,4,0},{B3,3,3}}},
    {1,2,7,{6,6,6},2,true,{{G2,5,5},{G3,4,4},{G3,5,5},{R0,6,0},{B3,0,0},{B3,1,1},{B2,4,4},{G0,6,0},{B2,5,5},{B3,2,2},{G2,4,4},{B0,6,0},{B3,3,3},{B3,5,5},{B3,4,4},{R1,5,0},{G2,3,0},{G1,5,0},{G3,3,0},{B1,5,0},{B2,3,0},{R2,5,0},{R3,5,0}}},
    {2,5,11,{5,4,4},2,true,{{R0,9,0},{G0,9,0},{B0,9,0},{R1,4,0},{R0,10,10},{G2,3,0},{G1,3,0},{G0,10,10},{B3,0,0},{G3,3,0},{B1,3,0},{B0,10,10},{B3,1,1},{B2,3,0},{R2,4,0},{B3,2,2},{R3,4,0},{B3,3,3}}},
    {6,5,11,{4,5,4},2,true,{{R0,9,0},{G0,9,0},{B0,9,0},{R1,3,0},{R0,10,10},{G3,4,4},{G2,3,0},{G1,4,0},{G0,10,10},{G3,3,0},{B1,3,0},{B0,10,10},{B3,1,1},{B2,3,0},{R2,3,0},{B3,0,0},{B3,2,2},{R3,3,0},{G2,4,4},{B3,3,3}}},
    {10,5,11,{4,4,5},2,true,{{R0,9,0},{G0,9,0},{B0,9,0},{R1,3,0},{R0,10,10},{B2,4,4},{G2,3,0},{G1,3,0},{G0,10,10},{B3,0,0},{G3,3,0},{B1,4,0},{B0,10,10},{B2,3,0},{R2,3,0},{B3,1,1},{B3,2,2},{R3,3,0},{B3,4,4},{B3,3,3}}},
    {14,5,9,{5,5,5},2,true,{{R0,8,0},{B2,4,4},{G0,8,0},{G2,4,4},{B0,8,0},{B3,4,4},{R1,4,0},{G3,4,4},{G2,3,0},{G1,4,0},{B3,0,0},{G3,3,0},{B1,4,0},{B3,1,1},{B2,3,0},{R2,4,0},{B3,2,2},{R3,4,0},{B3,3,3}}},
    {18,5,8,{6,5,5},2,true,{{R0,7,0},{G3,4,4},{B2,4,4},{G0,7,0},{B3,2,2},{G2,4,4},{B0,7,0},{B3,3,3},{B3,4,4},{R1,5,0},{G2,3,0},{G1,4,0},{B3,0,0},{G3,3,0},{B1,4,0},{B3,1,1},{B2,3,0},{R2,5,0},{R3,5,0}}},
    {22,5,8,{5,6,5},2,true,{{R0,7,0},{B3,0,0},{B2,4,4},{G0,7,0},{G2,5,5},{G2,4,4},{B0,7,0},{G3,5,5},{B3,4,4},{R1,4,0},{G3,4,4},{G2,3,0},{G1,5,0},{G3,3,0},{B1,4,0},{B3,1,1},{B2,3,0},{R2,4,0},{B3,2,2},{R3,4,0},{B3,3,3}}},
    {26,5,8,{5,5,6},2,true,{{R0,7,0},{B3,1,1},{B2,4,4},{G0,7,0},{B2,5,5},{G2,4,4},{B0,7,0},{B3,5,5},{B3,4,4},{R1,4,0},{G3,4,4},{G2,3,0},{G1,4,0},{B3,0,0},{G3,3,0},{B1,5,0},{B2,3,0},{R2,4,0},{B3,2,2},{R3,4,0},{B3,3,3}}},
    {30,5,6,{6,6,6},2,false,{{R0,5,0},{G3,4,4},{B3,0,0},{B3,1,1},{B2,4,4},{G0,5,0},{G2,5,5},{B2,5,5},{B3,2,2},{G2,4,4},{B0,5,0},{G3,5,5},{B3,3,3},{B3,5,5},{B3,4,4},{R1,5,0},{G2,3,0},{G1,5,0},{G3,3,0},{B1,5,0},{B2,3,0},{R2,5,0},{R3,5,0}}},
    {3,5,10,{10,10,10},1,false,{{R0,9,0},{G0,9,0},{B0,9,0},{R1,9,0},{G1,9,0},{B1,9,0}}},
    {7,5,11,{9,9,9},1,true,{{R0,9,0},{G0,9,0},{B0,9,0},{R1,8,0},{R0,10,10},{G1,8,0},{G0,10,10},{B1,8,0},{B0,10,10}}},
    {11,5,12,{8,8,8},1,true,{{R0,9,0},{G0,9,0},{B0,9,0},{R1,7,0},{R0,10,11},{G1,7,0},{G0,10,11},{B1,7,0},{B0,10,11}}},
    {15,5,16,{4,4,4},1,true,{{R0,9,0},{G0,9,0},{B0,9,0},{R1,3,0},{R0,10,15},{G1,3,0},{G0,10,15},{B1,3,0},{B0,10,15}}},
}

@(private="file")
SUBSET_ONE_MASKS := [32]u16{
    0xCCCC,0x8888,0xEEEE,0xECC8,0xC880,0xFEEC,0xFEC8,0xEC80,0xC800,0xFFEC,0xFE80,0xE800,0xFFE8,0xFF00,0xFFF0,0xF000,
    0xF710,0x008E,0x7100,0x08CE,0x008C,0x7310,0x3100,0x8CCE,0x088C,0x3110,0x6666,0x366C,0x17E8,0x0FF0,0x718E,0x399C,
}

@(private="file")
ANCHORS := [32]int{
    15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,
    15, 2, 8, 2, 2, 8, 8,15, 2, 8, 2, 2, 8, 8, 2, 2,
}

@(private="file") WEIGHTS_3 := [8]u32{0,9,18,27,37,46,55,64}
@(private="file") WEIGHTS_4 := [16]u32{0,4,9,13,17,21,26,30,34,38,43,47,51,55,60,64}

@(private="file")
read_bits :: proc(block:^[16]u8,pos:^int,count:int) -> (value:u32) {
    for i in 0..<count {
        bit:=(block[pos^/8]>>uint(pos^%8))&1
        value|=u32(bit)<<uint(i)
        pos^+=1
    }
    return
}

@(private="file")
unquantize :: proc(component:u32,bits:int) -> u32 {
    if bits>=15 {return component}
    if component==0 {return 0}
    if component==(u32(1)<<uint(bits))-1 {return 0xFFFF}
    return ((component<<16)+0x8000)>>uint(bits)
}

@(private="file")
sign_extend :: proc(v:u32,bits:int) -> i32 {
    shift:=uint(32-bits)
    return i32(v<<shift)>>shift
}

@(private="file")
decode_uf16 :: proc(block:^[16]u8) -> (texels:[16][3]u16,ok:bool) {
    pos:=0
    prefix:=read_bits(block,&pos,2)
    prefix_bits:=2
    if prefix>=2 {
        pos=0
        prefix=read_bits(block,&pos,5)
        prefix_bits=5
    }
    layout:^Mode_Layout
    for &candidate in LAYOUTS {
        if candidate.prefix_bits==prefix_bits && candidate.prefix==prefix {layout=&candidate}
    }
    if layout==nil {return}

    endpoints:[12]u32
    for field in layout.fields {
        step:=field.msb>=field.lsb?1:-1
        count:=abs(int(field.msb)-int(field.lsb))+1
        bit:=int(field.lsb)
        for _ in 0..<count {
            endpoints[field.endpoint]|=read_bits(block,&pos,1)<<uint(bit)
            bit+=step
        }
    }

    partition:=0
    if layout.subsets==2 {
        if pos!=77 {return}
        partition=int(read_bits(block,&pos,5))
    } else if pos!=65 {return}

    endpoint_count:=layout.subsets*2
    if layout.transformed {
        mask:=(u32(1)<<uint(layout.endpoint_bits))-1
        for c in 0..<3 {
            for e in 1..<endpoint_count {
                index:=e*3+c
                delta:=sign_extend(endpoints[index],layout.delta_bits[c])
                endpoints[index]=(u32(i32(endpoints[c])+delta))&mask
            }
        }
    }
    for i in 0..<endpoint_count*3 {endpoints[i]=unquantize(endpoints[i],layout.endpoint_bits)}

    index_bits:=layout.subsets==2?3:4
    for k in 0..<16 {
        subset:=layout.subsets==2?int((SUBSET_ONE_MASKS[partition]>>uint(k))&1):0
        anchor:=k==0 || (layout.subsets==2 && k==ANCHORS[partition])
        index:=read_bits(block,&pos,anchor?index_bits-1:index_bits)
        weight:=layout.subsets==2?WEIGHTS_3[index]:WEIGHTS_4[index]
        for c in 0..<3 {
            a:=endpoints[subset*6+c]
            b:=endpoints[subset*6+3+c]
            value:=(a*(64-weight)+b*weight+32)>>6
            texels[k][c]=u16((value*31)>>6)
        }
    }
    return texels,pos==128
}

@(private="file")
half_of :: proc(v:f32) -> u16 {return transmute(u16)f16(v)}

@(private="file")
float_of :: proc(v:u16) -> f32 {return f32(transmute(f16)v)}

@(private="file")
log_error :: proc(texels:^[16][4]u16,decoded:^[16][3]u16) -> f32 {
    sum:f32
    for k in 0..<16 {
        for c in 0..<3 {
            difference:=math.log2(float_of(texels[k][c])+0.0001)-math.log2(float_of(decoded[k][c])+0.0001)
            sum+=difference*difference
        }
    }
    return math.sqrt(sum/48)
}

@(private="file")
encoded_error :: proc(t:^testing.T,profile:Profile,texels:^[16][4]u16) -> f32 {
    settings:=settings_of(profile)
    block:[16]u8
    encode_block(&settings,texels,&block)
    decoded,ok:=decode_uf16(&block)
    testing.expect(t,ok,"the block does not decode")
    return log_error(texels,&decoded)
}

@(private="file")
Random :: struct {state:u32}

@(private="file")
next_random :: proc(r:^Random) -> f32 {
    r.state=r.state*1664525+1013904223
    return f32(r.state>>8)/f32(1<<24)
}

@(private="file")
solid_block :: proc(r,g,b:f32) -> (texels:[16][4]u16) {
    for k in 0..<16 {texels[k]={half_of(r),half_of(g),half_of(b),0}}
    return
}

@(private="file")
gradient_block :: proc() -> (texels:[16][4]u16) {
    for y in 0..<4 {
        for x in 0..<4 {
            value:=f32(x)/3
            texels[y*4+x]={half_of(0.1+value*4),half_of(0.25+value*2+f32(y)*0.1),half_of(1-value*0.75),0}
        }
    }
    return
}

@(private="file")
high_range_block :: proc() -> (texels:[16][4]u16) {
    for y in 0..<4 {
        for x in 0..<4 {
            shade:=f32(x+y*4)/15
            texels[y*4+x]={half_of(0.01+shade*2000),half_of(0.02+shade*shade*500),half_of(0.5+(1-shade)*30),0}
        }
    }
    return
}

@(private="file")
noise_block :: proc(seed:u32) -> (texels:[16][4]u16) {
    r:=Random{seed}
    for k in 0..<16 {
        texels[k]={half_of(next_random(&r)*4),half_of(next_random(&r)*4),half_of(next_random(&r)*4),0}
    }
    return
}

@(test)
a_solid_block_decodes_to_its_colour :: proc(t:^testing.T) {
    colours:=[][3]f32{{0,0,0},{1,1,1},{0.5,0.25,0.125},{16,64,2},{1000,0.001,3}}
    for colour in colours {
        for profile in Profile {
            texels:=solid_block(colour.r,colour.g,colour.b)
            settings:=settings_of(profile)
            block:[16]u8
            encode_block(&settings,&texels,&block)
            decoded,ok:=decode_uf16(&block)
            testing.expect(t,ok)
            for k in 0..<16 {
                for c in 0..<3 {
                    distance:=abs(int(texels[k][c])-int(decoded[k][c]))
                    testing.expectf(t,distance<=2,"%v %v channel %d: half %d decoded as %d",profile,colour,c,texels[k][c],decoded[k][c])
                }
            }
        }
    }
}

@(test)
hdr_blocks_stay_inside_their_log_error_bound :: proc(t:^testing.T) {
    gradient:=gradient_block()
    high:=high_range_block()
    Bounds :: struct {profile:Profile,gradient,high,noise:f32}
    for bounds in ([]Bounds{{.Very_Fast,0.35,1.1,1.5},{.Basic,0.16,0.5,1.0}}) {
        gradient_err:=encoded_error(t,bounds.profile,&gradient)
        testing.expectf(t,gradient_err<bounds.gradient,"%v gradient: %v",bounds.profile,gradient_err)
        high_err:=encoded_error(t,bounds.profile,&high)
        testing.expectf(t,high_err<bounds.high,"%v high range: %v",bounds.profile,high_err)
        for seed in 1..=8 {
            noise:=noise_block(u32(seed))
            noise_err:=encoded_error(t,bounds.profile,&noise)
            testing.expectf(t,noise_err<bounds.noise,"%v noise %d: %v",bounds.profile,seed,noise_err)
        }
    }
}

@(test)
basic_is_no_worse_than_very_fast :: proc(t:^testing.T) {
    gradient:=gradient_block()
    testing.expectf(t,encoded_error(t,.Basic,&gradient)<=encoded_error(t,.Very_Fast,&gradient),"gradient")

    for seed in 1..=16 {
        noise:=noise_block(u32(seed))
        fast:=encoded_error(t,.Very_Fast,&noise)
        basic:=encoded_error(t,.Basic,&noise)
        testing.expectf(t,basic<=fast,"noise %d: basic %v, very fast %v",seed,basic,fast)
    }
}

@(test)
non_finite_inputs_do_not_crash_and_stay_deterministic :: proc(t:^testing.T) {
    patterns:=[]u16{0x7E00,0x7C00,0xFC00,0xFFFF,0x8000,0x7FFF,0x0001}
    for profile in Profile {
        settings:=settings_of(profile)
        for first in patterns {
            for second in patterns {
                texels:[16][4]u16
                for k in 0..<16 {
                    value:=first if k%3==0 else second
                    texels[k]={value,second,first,0}
                }
                one,two:[16]u8
                encode_block(&settings,&texels,&one)
                encode_block(&settings,&texels,&two)
                testing.expect(t,one==two)
                _,ok:=decode_uf16(&one)
                testing.expect(t,ok)
            }
        }
    }
}

@(test)
out_of_range_settings_do_not_crash :: proc(t:^testing.T) {
    texels:=noise_block(3)
    block:[16]u8
    for threshold in ([]i32{-1,0,1,32,33,1000}) {
        settings:=Settings{slow_mode=true,fast_skip_threshold=threshold,refine_iterations_1p=-1,refine_iterations_2p=1}
        encode_block(&settings,&texels,&block)
        settings.slow_mode=false
        encode_block(&settings,&texels,&block)
    }
    encode_block(nil,&texels,&block)
}

@(test)
every_mode_decodes_to_what_the_encoder_measured :: proc(t:^testing.T) {
    r:=Random{11}
    for mode_index in ([]i32{0,1,2,5,6,9,10,11,12,13}) {
        for wide in 0..<3 {
            for round in 0..<8 {
                texels:[16][4]u16
                base:=u16(8000+next_random(&r)*16000)
                reach:=MODE_SPANS[mode_index]*0.4*31/64
                for k in 0..<16 {
                    subset:=u32(SUBSET_ONE_MASKS[round*3%32]>>uint(k))&1
                    for c in 0..<3 {
                        spread:=c==wide?reach:reach*0.4
                        texels[k][c]=u16(f32(base)+f32(subset)*spread*0.6+next_random(&r)*spread*0.4)
                    }
                }

                s:=State{slow_mode=true,fast_skip_threshold=32,refine_iterations_1p=2,refine_iterations_2p=2}
                s.best_err=math.INF_F32
                for p in 0..<3 {
                    for k in 0..<16 {s.block[p*16+k]=f32(texels[k][p])}
                }
                setup(&s)
                test_mode(&s,mode_index,true,0)

                block:[16]u8
                for k in 0..<4 {
                    for b in 0..<4 {block[k*4+b]=u8(s.best_data[k]>>uint(b*8))}
                }
                decoded,ok:=decode_uf16(&block)
                testing.expectf(t,ok,"mode %d does not decode",s.mode)

                layout:=&LAYOUTS[s.mode]
                prefix:=u32(block[0])&((u32(1)<<uint(layout.prefix_bits))-1)
                testing.expectf(t,prefix==layout.prefix,"mode %d wrote prefix %d",s.mode,prefix)

                sum:f32
                for k in 0..<16 {
                    for c in 0..<3 {
                        distance:=f32(texels[k][c])-f32(decoded[k][c])
                        sum+=distance*distance
                    }
                }
                measured:=math.sqrt(sum/48)
                reported:=math.sqrt(max(s.best_err,0)/48)*31/64
                testing.expectf(t,abs(measured-reported)<=2,"mode %d: decoded rms %v, encoder rms %v",s.mode,measured,reported)
            }
        }
    }
}

@(test)
image_blocks_repeat_the_last_column_and_row :: proc(t:^testing.T) {
    settings:=settings_of(.Basic)
    pixels:[5*3*4]u16
    for y in 0..<3 {
        for x in 0..<5 {
            offset:=(y*5+x)*4
            pixels[offset+0]=half_of(f32(x+1)*0.3)
            pixels[offset+1]=half_of(f32(y+1)*0.7)
            pixels[offset+2]=half_of(f32(x+y)*0.05+0.1)
            pixels[offset+3]=0
        }
    }

    out:[32]u8
    testing.expect(t,encode_image(&settings,pixels[:],5,3,out[:]))

    for block_x in 0..<2 {
        texels:[16][4]u16
        for y in 0..<4 {
            for x in 0..<4 {
                source_x:=min(block_x*4+x,4)
                source_y:=min(y,2)
                offset:=(source_y*5+source_x)*4
                for c in 0..<4 {texels[y*4+x][c]=pixels[offset+c]}
            }
        }
        expected:[16]u8
        encode_block(&settings,&texels,&expected)
        for byte,i in expected {testing.expectf(t,byte==out[block_x*16+i],"block %d byte %d",block_x,i)}
    }
}

@(test)
encode_image_rejects_invalid_sizes :: proc(t:^testing.T) {
    settings:=settings_of(.Very_Fast)
    pixels:[5*3*4]u16
    out:[32]u8
    too_small:[31]u8
    testing.expect(t,!encode_image(&settings,pixels[:],5,3,too_small[:]))
    testing.expect(t,!encode_image(&settings,pixels[:59],5,3,out[:]))
    testing.expect(t,!encode_image(&settings,pixels[:],0,3,out[:]))
    testing.expect(t,!encode_image(&settings,pixels[:],5,-3,out[:]))
    testing.expect(t,!encode_image(&settings,pixels[:],max(int),max(int),out[:]))
    testing.expect(t,!encode_image(nil,pixels[:],5,3,out[:]))
}

@(test)
one_thread_and_several_give_the_same_image :: proc(t:^testing.T) {
    WIDTH :: 61
    HEIGHT :: 47
    pixels:=make([]u16,WIDTH*HEIGHT*4)
    defer delete(pixels)
    r:=Random{7}
    for &value,i in pixels {value=i%4==3?0:half_of(next_random(&r)*8)}

    count:=((WIDTH+3)/4)*((HEIGHT+3)/4)*16
    serial:=make([]u8,count)
    defer delete(serial)
    threaded:=make([]u8,count)
    defer delete(threaded)

    js:jobs.Job_System
    testing.expect(t,jobs.system_init(&js,{threads=3}))
    defer jobs.system_destroy(&js)

    for profile in ([]Profile{.Very_Fast,.Basic}) {
        settings:=settings_of(profile)
        testing.expect(t,encode_image(&settings,pixels,WIDTH,HEIGHT,serial))
        testing.expect(t,encode_image(&settings,pixels,WIDTH,HEIGHT,threaded,jobs.Worker_Ref{system=&js,worker=jobs.OWNER}))
        same:=true
        for byte,i in serial {same&=byte==threaded[i]}
        testing.expect(t,same,fmt.tprintf("%v differs between one thread and several",profile))
    }
}
