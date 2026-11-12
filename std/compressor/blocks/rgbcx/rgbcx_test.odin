package rgbcx

import "core:math"
import "core:testing"

TEST_BLOCKS::32

Test_Block::[64]u8

next_random::proc(state:^u32) -> u32 {
    x:=state^
    x~=x<<13
    x~=x>>17
    x~=x<<5
    state^=x
    return x
}

gradient_block::proc(state:^u32) -> (block:Test_Block) {
    start,end:[4]i32
    for ch in 0..<4 {
        start[ch]=i32(next_random(state)%256)
        end[ch]=i32(next_random(state)%256)
    }
    for y in i32(0)..<4 {
        for x in i32(0)..<4 {
            for ch in 0..<4 {
                block[(y*4+x)*4+i32(ch)]=u8(start[ch]+(end[ch]-start[ch])*(x+y)/6)
            }
        }
    }
    return
}

noise_block::proc(state:^u32) -> (block:Test_Block) {
    for i in 0..<64 {block[i]=u8(next_random(state))}
    return
}

new_tables::proc(mode:Bc1_Approx_Mode) -> ^Tables {
    t:=new(Tables)
    tables_init(t,mode)
    return t
}

psnr::proc(error,samples:u64) -> f64 {
    if error==0 {return 200}
    return 10*math.log10(255.0*255.0*f64(samples)/f64(error))
}

expect_psnr::proc(t:^testing.T,error,samples:u64,bound:f64,loc:=#caller_location) {
    value:=psnr(error,samples)
    testing.expectf(t,value>=bound,"PSNR %v below %v",value,bound,loc=loc)
}

expect_rgb_psnr::proc(t:^testing.T,error:u64,bound:f64,loc:=#caller_location) {
    expect_psnr(t,error,3*16*TEST_BLOCKS,bound,loc)
}

rgb_error::proc(a,b:^Test_Block) -> (error:u64) {
    for i in 0..<16 {
        for ch in 0..<3 {
            d:=i64(a[i*4+ch])-i64(b[i*4+ch])
            error+=u64(d*d)
        }
    }
    return
}

channel_error::proc(a,b:^Test_Block,ch:int) -> (error:u64) {
    for i in 0..<16 {
        d:=i64(a[i*4+ch])-i64(b[i*4+ch])
        error+=u64(d*d)
    }
    return
}

@(test)
test_bc1_bc3_psnr::proc(t:^testing.T) {
    tables:=new_tables(.Ideal)
    defer free(tables)

    low_gradient_err,low_noise_err:u64
    levels:=[2]u32{0,MAX_LEVEL}
    for level,level_index in levels {
        gradient_err,noise_err,bc3_gradient_err,bc3_alpha_err,bc3_hq_alpha_err:u64
        state:=u32(0x1234567)
        for _ in 0..<TEST_BLOCKS {
            g:=gradient_block(&state)
            n:=noise_block(&state)
            dst:[16]u8
            out:Test_Block

            encode_bc1(tables,level,&dst[0],&g[0],true,false)
            unpack_bc1(&dst[0],&out[0],true,.Ideal)
            gradient_err+=rgb_error(&g,&out)

            encode_bc1(tables,level,&dst[0],&n[0],true,false)
            unpack_bc1(&dst[0],&out[0],true,.Ideal)
            noise_err+=rgb_error(&n,&out)

            encode_bc3(tables,level,&dst[0],&g[0])
            testing.expect(t,unpack_bc3(&dst[0],&out[0],.Ideal),"BC3 must not use 3-color blocks")
            bc3_gradient_err+=rgb_error(&g,&out)
            bc3_alpha_err+=channel_error(&g,&out,3)

            encode_bc3_hq(tables,level,&dst[0],&g[0],BC4_DEFAULT_SEARCH_RAD,BC4_USE_ALL_MODES)
            testing.expect(t,unpack_bc3(&dst[0],&out[0],.Ideal),"BC3 must not use 3-color blocks")
            bc3_hq_alpha_err+=channel_error(&g,&out,3)
        }

        // A 7-step full-range ramp limits BC1 to about 30 dB and BC4 to about 35 dB.
        bound:=level_index==0?29.5:30.0
        expect_rgb_psnr(t,gradient_err,bound)
        expect_rgb_psnr(t,bc3_gradient_err,bound)
        expect_rgb_psnr(t,noise_err,level_index==0?8:12)
        expect_psnr(t,bc3_alpha_err,16*TEST_BLOCKS,34)
        testing.expect(t,bc3_hq_alpha_err<=bc3_alpha_err)
        if level_index==1 {
            testing.expect(t,gradient_err<=low_gradient_err,"the max level must not lose to level 0")
            testing.expect(t,noise_err<=low_noise_err,"the max level must not lose to level 0")
        }
        low_gradient_err,low_noise_err=gradient_err,noise_err
    }
}

@(test)
test_bc4_bc5_psnr::proc(t:^testing.T) {
    err0,err1,hq_err0,hq_err1,bc4_err,bc4_hq_err:u64
    state:=u32(0x7654321)
    for _ in 0..<TEST_BLOCKS {
        g:=gradient_block(&state)
        dst:[16]u8
        out:Test_Block

        encode_bc4(&dst[0],&g[0],4)
        unpack_bc4(&dst[0],&out[0],4)
        bc4_err+=channel_error(&g,&out,0)

        encode_bc4_hq(&dst[0],&g[0],4,BC4_DEFAULT_SEARCH_RAD,BC4_USE_ALL_MODES)
        unpack_bc4(&dst[0],&out[0],4)
        bc4_hq_err+=channel_error(&g,&out,0)

        encode_bc5(&dst[0],&g[0],0,1,4)
        unpack_bc5(&dst[0],&out[0],0,1,4)
        err0+=channel_error(&g,&out,0)
        err1+=channel_error(&g,&out,1)

        encode_bc5_hq(&dst[0],&g[0],0,1,4,BC4_DEFAULT_SEARCH_RAD,BC4_USE_ALL_MODES)
        unpack_bc5(&dst[0],&out[0],0,1,4)
        hq_err0+=channel_error(&g,&out,0)
        hq_err1+=channel_error(&g,&out,1)
    }
    samples:=u64(16*TEST_BLOCKS)
    expect_psnr(t,bc4_err,samples,33)
    expect_psnr(t,err0,samples,33)
    expect_psnr(t,err1,samples,33)
    testing.expect(t,bc4_hq_err<=bc4_err)
    testing.expect(t,hq_err0<=err0)
    testing.expect(t,hq_err1<=err1)
}

@(test)
test_solid_blocks::proc(t:^testing.T) {
    tables:=new_tables(.Ideal)
    defer free(tables)

    state:=u32(0xABCDEF)
    levels:=[2]u32{0,MAX_LEVEL}
    for _ in 0..<64 {
        r,g,b,a:=u8(next_random(&state)),u8(next_random(&state)),u8(next_random(&state)),u8(next_random(&state))
        src:Test_Block
        for i in 0..<16 {src[i*4],src[i*4+1],src[i*4+2],src[i*4+3]=r,g,b,a}

        for level in levels {
            dst:[16]u8
            out:Test_Block
            encode_bc1(tables,level,&dst[0],&src[0],false,false)
            unpack_bc1(&dst[0],&out[0],true,.Ideal)
            for i in 0..<16 {
                testing.expect(t,abs(i32(out[i*4])-i32(r))<=8)
                testing.expect(t,abs(i32(out[i*4+1])-i32(g))<=4)
                testing.expect(t,abs(i32(out[i*4+2])-i32(b))<=8)
            }

            encode_bc3(tables,level,&dst[0],&src[0])
            testing.expect(t,unpack_bc3(&dst[0],&out[0],.Ideal),"BC3 must not use 3-color blocks")
            for i in 0..<16 {testing.expect_value(t,out[i*4+3],a)}
        }

        modes:=[3]u32{BC4_USE_MODE6_FLAG,BC4_USE_MODE8_FLAG,BC4_USE_ALL_MODES}
        for mode in modes {
            dst:[8]u8
            out:[16]u8
            value:=[16]u8{0..<16=a}
            encode_bc4_hq(&dst[0],&value[0],1,BC4_DEFAULT_SEARCH_RAD,mode)
            unpack_bc4(&dst[0],&out[0],1)
            testing.expect_value(t,out,value)
        }
    }
}

@(test)
test_deterministic::proc(t:^testing.T) {
    run::proc(mode:Bc1_Approx_Mode) -> (result:[TEST_BLOCKS*5][16]u8) {
        tables:=new_tables(mode)
        defer free(tables)
        state:=u32(0x99887766)
        for i in 0..<TEST_BLOCKS {
            n:=noise_block(&state)
            encode_bc1(tables,MAX_LEVEL,&result[i*5][0],&n[0],true,true)
            encode_bc1(tables,10,&result[i*5+1][0],&n[0],true,false)
            encode_bc3(tables,MAX_LEVEL,&result[i*5+2][0],&n[0])
            encode_bc5(&result[i*5+3][0],&n[0],0,1,4)
            encode_bc5_hq(&result[i*5+4][0],&n[0],0,1,4,BC4_DEFAULT_SEARCH_RAD,BC4_USE_ALL_MODES)
        }
        return
    }
    for mode in Bc1_Approx_Mode {
        first:=run(mode)
        second:=run(mode)
        testing.expect(t,first==second)
    }
}

@(test)
test_hostile_inputs::proc(t:^testing.T) {
    state:=u32(0x5150)
    for mode in Bc1_Approx_Mode {
        tables:=new_tables(mode)
        defer free(tables)
        levels:=[?]u32{0,1,2,3,4,5,6,9,13,MAX_LEVEL,19,20,max(u32)}
        for level in levels {
            n:=noise_block(&state)
            for i in 0..<16 {
                if i%3==0 {n[i*4],n[i*4+1],n[i*4+2]=0,0,0}
            }
            dst:[16]u8
            out:Test_Block
            encode_bc1(tables,level,&dst[0],&n[0],true,true)
            unpack_bc1(&dst[0],&out[0],false,mode)
            encode_bc3(tables,level,&dst[0],&n[0])
            unpack_bc3(&dst[0],&out[0],mode)
        }

        for _ in 0..<256 {
            block:[16]u8
            for i in 0..<16 {block[i]=u8(next_random(&state))}
            out:Test_Block
            unpack_bc1(&block[0],&out[0],true,mode)
            unpack_bc3(&block[0],&out[0],mode)
            unpack_bc4(&block[0],&out[0],4)
            unpack_bc5(&block[0],&out[0],0,1,4)
        }

        n:=noise_block(&state)
        dst:[16]u8
        encode_bc4_hq(&dst[0],&n[0],4,max(u32),BC4_USE_MODE8_FLAG)
        encode_bc4_hq(&dst[0],&n[0],4,0,0)
        encode_bc1_solid_block(tables,&dst[0],max(u32),300,0,true)
    }

    encode_bc1(nil,0,nil,nil,false,false)
    encode_bc3(nil,0,nil,nil)
    encode_bc4(nil,nil,4)
    encode_bc5(nil,nil,0,1,4)
    tables_init(nil,.Ideal)
    testing.expect(t,!unpack_bc1(nil,nil,true,.Ideal))
}
