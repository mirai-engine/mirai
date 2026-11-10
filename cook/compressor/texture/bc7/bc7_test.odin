package bc7

import "core:testing"
import "mirai:asset"
import "mirai:cook/compressor/texture/bc67"
import "mirai:cook/compressor/texture/common"

@(private="file")
lcg :: proc(s:^u32) -> u8 {
    s^=s^*1664525+1013904223
    return u8(s^>>24)
}

// Solid, transparent, extreme, noisy and smooth blocks.
@(private="file")
hostile_blocks :: proc() -> [dynamic]common.Color_Block {
    blocks:[dynamic]common.Color_Block
    for c in ([]common.Color{{0,0,0,255},{255,255,255,255},{0,0,0,0},{255,255,255,0},{17,130,201,
        77}}) {
        b:common.Color_Block
        for i in 0..<16 {b[i]=c}
        append(&blocks,b)
    }
    {
        b:common.Color_Block
        for i in 0..<16 {b[i]=(i&1)==0 ? common.Color{0,255,0,0} : common.Color{255,0,255,255}}
        append(&blocks,b)
    }
    seed:=u32(12345)
    for _ in 0..<6 {
        b:common.Color_Block
        for i in 0..<16 {b[i]={lcg(&seed),lcg(&seed),lcg(&seed),lcg(&seed)}}
        append(&blocks,b)
    }
    {
        b:common.Color_Block
        for i in 0..<16 {
            k:=u8(i)
            b[i]={40+k*8,60+k*6,200-k*5,255}
        }
        append(&blocks,b)
    }
    return blocks
}

@(private="file")
decode :: proc(block:[]u8) -> (out:common.Color_Block) {
    return transmute(common.Color_Block)asset.texture_bc7_block_decode((^[16]u8)(raw_data(block))^)
}

@(test)
compress_hostile_blocks_decode_within_bounds :: proc(t:^testing.T) {
    blocks:=hostile_blocks()
    defer delete(blocks)
    out:=make([]u8,len(blocks)*16)
    defer delete(out)
    option_sets:=[]common.Options{{},{.BC7_Ignore_Alpha},{.BC3457_Preserve_Extremes}}
    for level in ([]common.Level{.Very_Fast,.Fast,.Slow,.Very_Slow}) {
        for options in option_sets {
            testing.expect_value(t,compress(out,blocks[:],level,options),common.Error.None)
            for bi in 0..<len(blocks) {
                testing.expect(t,out[bi*16]!=0)
                dec:=decode(out[bi*16:])
                src:=blocks[bi]
                if bi<5 {
                    for i in 0..<16 {
                        for c in 0..<3 {testing.expect_value(t,dec[i][c],src[i][c])}
                        if .BC7_Ignore_Alpha not_in options {testing.expect_value(t,dec[i][3],
                            src[i][3])}
                    }
                }
                if bi==len(blocks)-1 {
                    for i in 0..<16 {
                        for c in 0..<4 {testing.expect(t,abs(int(dec[i][c])-int(src[i][c]))<=6)}
                    }
                }
                if .BC3457_Preserve_Extremes in options {
                    for i in 0..<16 {
                        if src[i][3]==0 || src[i][3]==255 {testing.expect_value(t,dec[i][3],
                            src[i][3])}
                    }
                }
            }
        }
    }
    testing.expect_value(t,compress(out[:15],blocks[:1],.Slow,{}),common.Error.Invalid)
}

@(test)
compress_and_rd_are_deterministic_and_valid :: proc(t:^testing.T) {
    hb:=hostile_blocks()
    defer delete(hb)
    blocks:=make([]common.Color_Block,64)
    defer delete(blocks)
    for i in 0..<len(blocks) {blocks[i]=hb[(i*7)%len(hb)]}
    baseline:=make([]u8,len(blocks)*16)
    defer delete(baseline)
    testing.expect_value(t,compress(baseline,blocks,.Slow,{}),common.Error.None)
    again:=make([]u8,len(blocks)*16)
    defer delete(again)
    compress(again,blocks,.Slow,{})
    testing.expect(t,string(baseline)==string(again))
    activity:=make([]common.Float_Block,len(blocks))
    defer delete(activity)
    for &a in activity {for &v in a {v=1}}
    a:=make([]u8,len(blocks)*16)
    defer delete(a)
    b:=make([]u8,len(blocks)*16)
    defer delete(b)
    for lambda in ([]int{0,10,50}) {
        testing.expect_value(t,rd(a,blocks,baseline,activity,lambda,{},{effort=.Slow}),
            common.Error.None)
        testing.expect_value(t,rd(b,blocks,baseline,activity,lambda,{},{effort=.Slow}),
            common.Error.None)
        testing.expect(t,string(a)==string(b))
        for bi in 0..<len(blocks) {
            desc:bc67.Block_Raw_Desc
            testing.expect(t,bc67.bc7_analyze_block_raw(&desc,(^[16]u8)(&a[bi*16])))
        }
    }
    // a slice of one block and hostile activity
    for &x in activity[:1] {for &v in x {v=-1e30}}
    testing.expect_value(t,rd(a[:16],blocks[:1],baseline[:16],activity[:1],30,{},
        {effort=.Very_Slow}),
        common.Error.None)
    testing.expect_value(t,rd(a[:16],blocks[:2],baseline[:32],activity[:2],30,{},{}),
        common.Error.Invalid)
    zero:=make([]u8,16)
    defer delete(zero)
    testing.expect_value(t,rd(a[:16],blocks[:1],zero,activity[:1],30,{},{}),common.Error.Invalid)
}

// The texels of a block from the fields the encoder reads back and its tables.
@(private="file")
decode_from_fields :: proc(block:^[16]u8) -> (out:common.Color_Block) {
    desc:bc67.Block_Raw_Desc
    if !bc67.bc7_analyze_block_raw(&desc,block) {return}
    m:=desc.mode
    subsets:=bc67.partition_of(m.ns,u32(desc.partition_id)).subset_mask
    for &texel,i in out {
        s:=int((subsets>>(u32(i)*2))&3)
        color,alpha:=desc.inds[0][i],desc.inds[0][i]
        color_bits,alpha_bits:=m.ib,m.ib
        if m.ib2!=0 {
            alpha,alpha_bits=desc.inds[1][i],m.ib2
            if desc.ind_sel!=0 {color,alpha,color_bits,alpha_bits=alpha,color,alpha_bits,color_bits}
        }
        for c in 0..<4 {
            w:=u32(asset.BC7_WEIGHTS[c<3 ? color_bits : alpha_bits][c<3 ? color : alpha])
            low,high:=u32(desc.endpoints_raw[c][s*2]),u32(desc.endpoints_raw[c][s*2+1])
            texel[c]=u8((low*(64-w)+high*w+32)>>6)
        }
        if desc.rot!=0 {texel[desc.rot-1],texel[3]=texel[3],texel[desc.rot-1]}
    }
    return
}

// What the encoder reads back from a block and what the runtime decodes are one format: any
// bits of every mode, and what the encoder writes, give the same texels both ways.
@(test)
the_fields_the_encoder_reads_decode_to_the_texels_of_the_runtime :: proc(t:^testing.T) {
    seed:=u32(99)
    for n in 0..<8*4096 {
        block:[16]u8
        for &b in block {b=lcg(&seed)}
        mode:=uint(n&7)
        block[0]=(block[0]<<(mode+1))|u8(1)<<mode
        if n%1024==0 {block[0]=0}
        if decode(block[:])!=decode_from_fields(&block) {
            testing.expectf(t,false,"mode %d: %v decodes to %v, its fields to %v",mode,block,decode(block[:]),decode_from_fields(&block))
            return
        }
    }
    blocks:=hostile_blocks()
    defer delete(blocks)
    out:=make([]u8,len(blocks)*16)
    defer delete(out)
    for level in ([]common.Level{.Very_Fast,.Slow}) {
        testing.expect_value(t,compress(out,blocks[:],level,{}),common.Error.None)
        for bi in 0..<len(blocks) {
            testing.expect(t,decode(out[bi*16:])==decode_from_fields((^[16]u8)(&out[bi*16])))
        }
    }
}
