// BC1, BC3, BC4 and BC5 block encoder and decoder.
package rgbcx

MIN_LEVEL::0
MAX_LEVEL::18

MIN_TOTAL_ORDERINGS::1
MAX_TOTAL_ORDERINGS3::32
MAX_TOTAL_ORDERINGS4::128
DEFAULT_TOTAL_ORDERINGS_TO_TRY::10
DEFAULT_TOTAL_ORDERINGS_TO_TRY3::1

BC4_DEFAULT_SEARCH_RAD::3
BC4_USE_MODE8_FLAG::1
BC4_USE_MODE6_FLAG::2
BC4_USE_ALL_MODES::3

DXT1_SELECTOR_BITS::2
DXT1_SELECTOR_VALUES::1<<DXT1_SELECTOR_BITS
DXT1_SELECTOR_MASK::DXT1_SELECTOR_VALUES-1
DXT5_SELECTOR_BITS::3
DXT5_SELECTOR_VALUES::1<<DXT5_SELECTOR_BITS
DXT5_SELECTOR_MASK::DXT5_SELECTOR_VALUES-1

ENCODE_BC1_USE_LIKELY_TOTAL_ORDERINGS::2
ENCODE_BC1_TWO_LEAST_SQUARES_PASSES::4
ENCODE_BC1_USE_3COLOR_BLOCKS_FOR_BLACK_PIXELS::8
ENCODE_BC1_USE_3COLOR_BLOCKS::16
ENCODE_BC1_ITERATIVE::32
ENCODE_BC1_BOUNDING_BOX::64
ENCODE_BC1_USE_FASTER_MSE_EVAL::128
ENCODE_BC1_USE_FULL_MSE_EVAL::256
ENCODE_BC1_USE_2DLS::512
ENCODE_BC1_USE_6_POWER_ITERS::2048
ENCODE_BC1_EXHAUSTIVE::8192
ENCODE_BC1_TRY_ALL_INITIAL_ENDPOINTS::16384
ENCODE_BC1_BOUNDING_BOX_INT::32768
ENCODE_BC1_ENDPOINT_SEARCH_ROUNDS_SHIFT::22
ENCODE_BC1_ENDPOINT_SEARCH_ROUNDS_MASK::u32(1023)<<ENCODE_BC1_ENDPOINT_SEARCH_ROUNDS_SHIFT

Bc1_Approx_Mode::enum {Ideal,Nvidia,AMD,Ideal_Round_4}

// RGBA8 texel, R first in memory.
Color32::[4]u8

// Read-only after tables_init, so threads may share it.
Tables::struct {
    mode:Bc1_Approx_Mode,
    match5_equals_1:[256]Match_Entry,
    match6_equals_1:[256]Match_Entry,
    match5_half:[256]Match_Entry,
    match6_half:[256]Match_Entry,
    total_ordering4_hash:[4096]u16,
    selector_factors4:[NUM_UNIQUE_TOTAL_ORDERINGS4][3]f32,
    total_ordering3_hash:[256]u16,
    selector_factors3:[NUM_UNIQUE_TOTAL_ORDERINGS3][3]f32,
}

tables_init::proc(t:^Tables,mode:Bc1_Approx_Mode) {
    if t==nil {return}
    t.mode=mode

    expand5:[32]u8
    for i in 0..<32 {expand5[i]=u8((i<<3)|(i>>2))}
    prepare_single_color_table(&t.match5_equals_1,expand5[:],false,mode)
    prepare_single_color_table(&t.match5_half,expand5[:],true,mode)

    expand6:[64]u8
    for i in 0..<64 {expand6[i]=u8((i<<2)|(i>>4))}
    prepare_single_color_table(&t.match6_equals_1,expand6[:],false,mode)
    prepare_single_color_table(&t.match6_half,expand6[:],true,mode)

    for i in 0..<NUM_UNIQUE_TOTAL_ORDERINGS4 {
        h:=UNIQUE_TOTAL_ORDERS4[i]
        if h[0]!=16 && h[1]!=16 && h[2]!=16 && h[3]!=16 {
            t.total_ordering4_hash[u32(h[0])|u32(h[1])<<4|u32(h[2])<<8]=u16(i)
        }
        t.selector_factors4[i]=selector_factors4(h)
    }

    for i in 0..<NUM_UNIQUE_TOTAL_ORDERINGS3 {
        h:=UNIQUE_TOTAL_ORDERS3[i]
        if h[0]!=16 && h[1]!=16 && h[2]!=16 {
            t.total_ordering3_hash[u32(h[0])|u32(h[1])<<4]=u16(i)
        }
        t.selector_factors3[i]=selector_factors3(h)
    }
}

// fr, fg and fb are clamped to 8 bits.
encode_bc1_solid_block::proc(t:^Tables,dst:[^]u8,fr,fg,fb:u32,allow_3color:bool) {
    if t==nil || dst==nil {return}
    encode_solid(t,dst,u8(min(fr,255)),u8(min(fg,255)),u8(min(fb,255)),allow_3color)
}

// Low-level BC1 encoder driven by the ENCODE_BC1_* flags.
encode_bc1_flags::proc(t:^Tables,dst,pixels:[^]u8,flags,total_orderings_to_try,total_orderings_to_try3:u32) {
    if t==nil || dst==nil || pixels==nil {return}
    encode_bc1_block(t,dst,cast([^]Color32)pixels,flags,total_orderings_to_try,total_orderings_to_try3)
}

// Levels above MAX_LEVEL behave as level 5, except the exhaustive hidden level 19.
encode_bc1::proc(t:^Tables,level:u32,dst,pixels:[^]u8,allow_3color,use_transparent_texels_for_black:bool) {
    three:u32
    if allow_3color {three|=ENCODE_BC1_USE_3COLOR_BLOCKS}
    if use_transparent_texels_for_black {three|=ENCODE_BC1_USE_3COLOR_BLOCKS_FOR_BLACK_PIXELS}

    TWO_LS::ENCODE_BC1_TWO_LEAST_SQUARES_PASSES
    FASTER::ENCODE_BC1_USE_FASTER_MSE_EVAL
    LIKELY::ENCODE_BC1_USE_LIKELY_TOTAL_ORDERINGS
    FULL::ENCODE_BC1_USE_FULL_MSE_EVAL
    SIX::ENCODE_BC1_USE_6_POWER_ITERS
    INITIAL::ENCODE_BC1_TRY_ALL_INITIAL_ENDPOINTS
    SEARCH::ENCODE_BC1_ENDPOINT_SEARCH_ROUNDS_SHIFT

    flags,orderings4,orderings3:=u32(0),u32(1),u32(1)
    switch level {
    case 0:flags=ENCODE_BC1_BOUNDING_BOX_INT
    case 1:flags=ENCODE_BC1_USE_2DLS
    case 2:flags=0
    case 3:flags=TWO_LS
    case 4:flags=TWO_LS|FULL|SIX
    case 6:flags=TWO_LS|FASTER|LIKELY|three
    case 7:
        flags=TWO_LS|FASTER|LIKELY|three
        orderings4=4
    case 8:
        flags=TWO_LS|FASTER|LIKELY|three
        orderings4=8
    case 9:
        flags=TWO_LS|LIKELY|three
        orderings4,orderings3=11,3
    case 10:
        flags=TWO_LS|LIKELY|three
        orderings4,orderings3=20,8
    case 11:
        flags=TWO_LS|LIKELY|three
        orderings4,orderings3=28,16
    case 12:
        flags=TWO_LS|LIKELY|three
        orderings4,orderings3=32,32
    case 13:
        flags=TWO_LS|FULL|LIKELY|SIX|(20<<SEARCH)|INITIAL|three
        orderings4,orderings3=32,32
    case 14:
        flags=TWO_LS|FULL|LIKELY|SIX|(32<<SEARCH)|INITIAL|three
        orderings4,orderings3=32,32
    case 15:
        flags=TWO_LS|FULL|LIKELY|SIX|(32<<SEARCH)|INITIAL|three
        orderings4,orderings3=((((32+MAX_TOTAL_ORDERINGS4)/2)+32)/2),32
    case 16:
        flags=TWO_LS|FULL|LIKELY|SIX|(256<<SEARCH)|INITIAL|three
        orderings4,orderings3=(32+MAX_TOTAL_ORDERINGS4)/2,32
    case 17:
        flags=TWO_LS|FULL|LIKELY|SIX|(256<<SEARCH)|INITIAL|three
        orderings4,orderings3=MAX_TOTAL_ORDERINGS4,32
    case 18:
        flags=TWO_LS|FULL|LIKELY|SIX|ENCODE_BC1_ITERATIVE|(256<<SEARCH)|INITIAL|three
        orderings4,orderings3=MAX_TOTAL_ORDERINGS4,32
    case 19:
        flags=TWO_LS|FULL|LIKELY|SIX|ENCODE_BC1_EXHAUSTIVE|ENCODE_BC1_ITERATIVE|(256<<SEARCH)|INITIAL|three
        orderings4,orderings3=32,32
    case:
        flags=TWO_LS|FASTER|three
    }

    encode_bc1_flags(t,dst,pixels,flags,orderings4,orderings3)
}

// Low-level BC3 encoder. 3-color blocks are removed from flags: most GPUs do not support them in BC3.
encode_bc3_flags::proc(t:^Tables,dst,pixels:[^]u8,flags,total_orderings_to_try:u32) {
    if t==nil || dst==nil || pixels==nil {return}
    encode_bc4(dst,pixels[3:],4)
    encode_bc1_flags(t,dst[8:],pixels,flags&~(ENCODE_BC1_USE_3COLOR_BLOCKS_FOR_BLACK_PIXELS|ENCODE_BC1_USE_3COLOR_BLOCKS),total_orderings_to_try,DEFAULT_TOTAL_ORDERINGS_TO_TRY3)
}

encode_bc3::proc(t:^Tables,level:u32,dst,pixels:[^]u8) {
    if t==nil || dst==nil || pixels==nil {return}
    encode_bc4(dst,pixels[3:],4)
    encode_bc1(t,level,dst[8:],pixels,false,false)
}

encode_bc3_hq::proc(t:^Tables,level:u32,dst,pixels:[^]u8,search_rad,mode_mask:u32) {
    if t==nil || dst==nil || pixels==nil {return}
    encode_bc4_hq(dst,pixels[3:],4,search_rad,mode_mask)
    encode_bc1(t,level,dst[8:],pixels,false,false)
}

@(private,rodata)
BC4_SELECTOR_TRAN:=[8]u64{1,7,6,5,4,3,2,0}

encode_bc4::proc(dst,pixels:[^]u8,stride:u32) {
    if dst==nil || pixels==nil {return}

    min_v,max_v:=i32(pixels[0]),i32(pixels[0])
    for i in 1..<u32(16) {
        v:=i32(pixels[i*stride])
        min_v=min(min_v,v)
        max_v=max(max_v,v)
    }

    dst[0]=u8(max_v)
    dst[1]=u8(min_v)

    if max_v==min_v {
        for i in 2..<8 {dst[i]=0}
        return
    }

    delta:=max_v-min_v
    // BC4 floors in its divisions: the bias compensates. This matches an exhaustive search of the 8 values.
    bias:=4-min_v*14
    f:u64
    for i in 0..<u32(16) {
        v:=i32(pixels[i*stride])*14+bias
        k:=0
        for m:=i32(1);m<=13;m+=2 {
            if v>=delta*m {k+=1}
        }
        f|=BC4_SELECTOR_TRAN[k]<<(u64(i)*3)
    }

    dst[2]=u8(f)
    dst[3]=u8(f>>8)
    dst[4]=u8(f>>16)
    dst[5]=u8(f>>24)
    dst[6]=u8(f>>32)
    dst[7]=u8(f>>40)
}

@(private)
bc4_block_values::proc "contextless" (vals:^[8]u8,l,h:u32) {
    vals[0]=u8(l)
    vals[1]=u8(h)
    if l>h {
        vals[2]=u8((l*6+h)/7)
        vals[3]=u8((l*5+h*2)/7)
        vals[4]=u8((l*4+h*3)/7)
        vals[5]=u8((l*3+h*4)/7)
        vals[6]=u8((l*2+h*5)/7)
        vals[7]=u8((l+h*6)/7)
    } else {
        vals[2]=u8((l*4+h)/5)
        vals[3]=u8((l*3+h*2)/5)
        vals[4]=u8((l*2+h*3)/5)
        vals[5]=u8((l+h*4)/5)
        vals[6]=0
        vals[7]=255
    }
}

encode_bc4_hq::proc(dst,pixels:[^]u8,stride,search_rad,mode_mask:u32) {
    if dst==nil || pixels==nil {return}

    min_val,max_val:=u32(255),u32(0)
    for i in 0..<u32(16) {
        v:=u32(pixels[i*stride])
        min_val=min(min_val,v)
        max_val=max(max_val,v)
    }

    if min_val==max_val {
        if mode_mask&BC4_USE_MODE6_FLAG!=0 {
            dst[0]=u8(min_val)
            dst[1]=u8(min_val)
            for i in 2..<8 {dst[i]=0}
        } else if min_val>0 {
            dst[0]=u8(min_val)
            dst[1]=u8(min_val)-1
            for i in 2..<8 {dst[i]=0}
        } else {
            CONST_1:=[8]u8{1,0,0x49,0x92,0x24,0x49,0x92,0x24}
            for i in 0..<8 {dst[i]=CONST_1[i]}
        }
        return
    }

    // Beyond 255 every delta clamps to an endpoint already tried.
    rad:=i32(min(search_rad,255))
    best_err:=max(u32)
    for mode in u32(0)..<2 {
        if mode_mask&(1<<mode)==0 {continue}

        for lo_delta:=-rad;lo_delta<=rad;lo_delta+=1 {
            for hi_delta:=-rad;hi_delta<=rad;hi_delta+=1 {
                e0:=u8(clamp(i32(max_val)+hi_delta,0,255))
                e1:=u8(clamp(i32(min_val)+lo_delta,0,255))
                if e0==e1 {continue}

                if mode==0 {
                    if e0<=e1 {e0,e1=e1,e0}
                } else if e0>e1 {
                    e0,e1=e1,e0
                }

                vals:[8]u8=---
                bc4_block_values(&vals,u32(e0),u32(e1))

                trial_err:u32
                trial_sels:[16]u8=---
                for i in 0..<u32(16) {
                    p:=i32(pixels[i*stride])
                    best_index_err:=max(u32)
                    best_index:u8
                    for j in 0..<u8(8) {
                        err:=u32(square(i32(vals[j])-p))
                        if err<best_index_err {
                            best_index_err=err
                            best_index=j
                            if err==0 {break}
                        }
                    }
                    trial_err+=best_index_err
                    if trial_err>=best_err {break}
                    trial_sels[i]=best_index
                }

                if trial_err<best_err {
                    best_err=trial_err
                    sel_vals:u64
                    for i in 0..<u64(16) {sel_vals|=u64(trial_sels[i])<<(i*3)}
                    dst[0]=e0
                    dst[1]=e1
                    dst[2]=u8(sel_vals)
                    dst[3]=u8(sel_vals>>8)
                    dst[4]=u8(sel_vals>>16)
                    dst[5]=u8(sel_vals>>24)
                    dst[6]=u8(sel_vals>>32)
                    dst[7]=u8(sel_vals>>40)
                }
            }
        }
    }
}

encode_bc5::proc(dst,pixels:[^]u8,chan0,chan1,stride:u32) {
    if dst==nil || pixels==nil {return}
    encode_bc4(dst,pixels[chan0:],stride)
    encode_bc4(dst[8:],pixels[chan1:],stride)
}

encode_bc5_hq::proc(dst,pixels:[^]u8,chan0,chan1,stride,search_rad,mode_mask:u32) {
    if dst==nil || pixels==nil {return}
    encode_bc4_hq(dst,pixels[chan0:],stride,search_rad,mode_mask)
    encode_bc4_hq(dst[8:],pixels[chan1:],stride,search_rad,mode_mask)
}

// Returns true if the block is in 3-color punchthrough mode.
unpack_bc1_block_colors::proc(block:[^]u8,c:^[4]Color32,mode:Bc1_Approx_Mode) -> bool {
    if block==nil || c==nil {return false}

    l:=u32(block[0])|u32(block[1])<<8
    h:=u32(block[2])|u32(block[3])<<8

    cr0,cg0,cb0:=i32((l>>11)&31),i32((l>>5)&63),i32(l&31)
    cr1,cg1,cb1:=i32((h>>11)&31),i32((h>>5)&63),i32(h&31)
    r0,g0,b0:=scale_5_to_8(cr0),scale_6_to_8(cg0),scale_5_to_8(cb0)
    r1,g1,b1:=scale_5_to_8(cr1),scale_6_to_8(cg1),scale_5_to_8(cb1)

    rgba::#force_inline proc "contextless" (r,g,b,a:i32) -> Color32 {return {u8(r),u8(g),u8(b),u8(a)}}

    c[0]=rgba(r0,g0,b0,255)
    c[1]=rgba(r1,g1,b1,255)

    if l>h {
        switch mode {
        case .Ideal:
            c[2]=rgba((r0*2+r1)/3,(g0*2+g1)/3,(b0*2+b1)/3,255)
            c[3]=rgba((r1*2+r0)/3,(g1*2+g0)/3,(b1*2+b0)/3,255)
        case .Ideal_Round_4:
            c[2]=rgba((r0*2+r1+1)/3,(g0*2+g1+1)/3,(b0*2+b1+1)/3,255)
            c[3]=rgba((r1*2+r0+1)/3,(g1*2+g0+1)/3,(b1*2+b0+1)/3,255)
        case .Nvidia:
            c[2]=rgba(interp_5_nv(cr0,cr1),interp_6_nv(g0,g1),interp_5_nv(cb0,cb1),255)
            c[3]=rgba(interp_5_nv(cr1,cr0),interp_6_nv(g1,g0),interp_5_nv(cb1,cb0),255)
        case .AMD:
            c[2]=rgba(interp_5_6_amd(r0,r1),interp_5_6_amd(g0,g1),interp_5_6_amd(b0,b1),255)
            c[3]=rgba(interp_5_6_amd(r1,r0),interp_5_6_amd(g1,g0),interp_5_6_amd(b1,b0),255)
        }
        return false
    }

    switch mode {
    case .Ideal,.Ideal_Round_4:
        c[2]=rgba((r0+r1)/2,(g0+g1)/2,(b0+b1)/2,255)
    case .Nvidia:
        c[2]=rgba(interp_half_5_nv(cr0,cr1),interp_half_6_nv(g0,g1),interp_half_5_nv(cb0,cb1),255)
    case .AMD:
        c[2]=rgba(interp_half_5_6_amd(r0,r1),interp_half_5_6_amd(g0,g1),interp_half_5_6_amd(b0,b1),255)
    }
    c[3]=rgba(0,0,0,0)
    return true
}

// Returns true if the block is in 3-color punchthrough mode.
unpack_bc1::proc(block,out:[^]u8,set_alpha:bool,mode:Bc1_Approx_Mode) -> bool {
    if block==nil || out==nil {return false}
    c:[4]Color32
    used_punchthrough:=unpack_bc1_block_colors(block,&c,mode)
    dst:=cast([^]Color32)out
    for i in 0..<16 {
        sel:=(block[4+i/4]>>(u32(i&3)*2))&3
        if set_alpha {
            dst[i]=c[sel]
        } else {
            dst[i].r=c[sel].r
            dst[i].g=c[sel].g
            dst[i].b=c[sel].b
        }
    }
    return used_punchthrough
}

unpack_bc4::proc(block,out:[^]u8,stride:u32) {
    if block==nil || out==nil {return}
    vals:[8]u8=---
    bc4_block_values(&vals,u32(block[0]),u32(block[1]))
    selector_bits:=u64(block[2])|u64(block[3])<<8|u64(block[4])<<16|u64(block[5])<<24|u64(block[6])<<32|u64(block[7])<<40
    for i in 0..<u32(16) {
        out[i*stride]=vals[(selector_bits>>(u64(i)*3))&7]
    }
}

// Returns false if the color block uses 3-color punchthrough mode, which most GPUs do not support in BC3.
unpack_bc3::proc(block,out:[^]u8,mode:Bc1_Approx_Mode) -> bool {
    if block==nil || out==nil {return false}
    success:=!unpack_bc1(block[8:],out,true,mode)
    unpack_bc4(block,out[3:],4)
    return success
}

unpack_bc5::proc(block,out:[^]u8,chan0,chan1,stride:u32) {
    if block==nil || out==nil {return}
    unpack_bc4(block,out[chan0:],stride)
    unpack_bc4(block[8:],out[chan1:],stride)
}
