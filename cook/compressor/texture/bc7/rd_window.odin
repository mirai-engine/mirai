package bc7

import "base:runtime"
import "core:math"
import "mirai:asset"
import "mirai:cook/compressor/texture/common"
import "mirai:std/compressor/lz/entropy"

// Settings, window of recent blocks and per-block helpers of the BC7 RDO.

@(private)
RD_Config :: struct {
    block_encode_effort:common.Level, // effort of new-block encodes inside the RDO
    core_fix_single_color_block:bool,
    core_recompress_block_with_j_bias:bool,
    core_disable_less_common_modes:bool,
    core_endpoints_from_indices:bool,
    mtf_window_endpoints_size:int,
    mtf_window_indices_size:int,
    mtf_window_seed_most_common:bool,
    do_ilm:bool, // in-loop matrix
    ilm_hyperbola_max_index_product:int,
    do_bottom_up_merge:bool,
    do_final_matrix:bool,
    fm_combined_size_limit_sqrt:int,
    do_final_optimize:bool,
}

@(rodata)
@(private)
RD_CONFIG_LEVELS := [common.Level]RD_Config{
    .Very_Fast={.Slow,true,true,true,false,80,2,true,true,80,true,true,60,true},
    .Fast={.Slow,true,true,true,false,128+16+3,2,true,true,128+16+3,true,true,60,true},
    .Slow={.Very_Slow,true,true,true,false,256+64+16+3,2,true,true,200,true,true,100,true},
    .Very_Slow={.Very_Slow,true,true,true,true,256+64+16+3,256+32+8+3,true,true,200,true,true,100,
        true},
    .Reference={.Very_Slow,true,true,true,true,256+64+16+3,256+32+8+3,true,true,512,true,true,100,
        true},
}

// Texels constrained by preserve extremes: bit i texel i is A=0, bit 16+i it is A=255.
@(private)
Constraints :: distinct u32

@(private)
constraints_feasible :: #force_inline proc "contextless" (c:Constraints) -> bool {
    return (c&(c>>16))==0
}
@(private)
constraints_superset_of :: #force_inline proc "contextless" (c,
    x:Constraints) -> bool {return (c&x)==x}
@(private)
constraints_intersects :: #force_inline proc "contextless" (c,
    x:Constraints) -> bool {return (c&x)!=0}
@(private)
constraints_flip :: #force_inline proc "contextless" (c:Constraints) -> Constraints {
    return (c>>16)|(c<<16)
}

@(private)
constraints_from_pixels :: proc "contextless" (b:^common.Color_Block) -> Constraints {
    mask:u32
    for i:=15; i>=0; i-=1 {
        mask<<=1
        if b[i][3]==0 {mask|=1}
        if b[i][3]==255 {mask|=0x10000}
    }
    return Constraints(mask)
}

@(private)
constraints_from_indices :: proc "contextless" (inds:^[16]u8,ib:int) -> Constraints {
    hi_ind:=u8((1<<uint(ib))-1)
    mask:u32
    for i:=15; i>=0; i-=1 {
        mask<<=1
        if inds[i]==0 {mask|=1}
        if inds[i]==hi_ind {mask|=0x10000}
    }
    return Constraints(mask)
}

@(private)
Block_Info :: struct {
    flags:Flags,
    constraints:Constraints,
    baseline_d:f32,
    j,d:f32,
    colors:common.Color_Block, // RGBA
}

@(private)
Window_Entry :: struct {
    st:Block_State,
    encoded:Bits,
}

@(private)
Endpoint_Window_Extra :: struct {
    mode:u8,
    mode_class:u8,
    pca_type:u8, // modes 4-6: which whole-block PCA to compare with; 0 disables the early out
    normalized_axis:[4]f32,
}

@(rodata)
@(private)
MODE_CLASS := [8]u8{3,2,3,2,1,1,1,2}

@(private)
window_extra_init :: proc "contextless" (e:^Endpoint_Window_Extra,st:^Block_State) {
    e.mode=st.mode
    e.mode_class=MODE_CLASS[st.mode&7]
    if st.mode<4 || st.mode>6 {
        e.pca_type=0
        e.normalized_axis={}
        return
    }
    subset:=&st.subsets[0]
    e.pca_type=st.mode==6 ? 1 : subset.rbit+2
    len_sq:f32=1e-15
    diff:[4]f32
    n:=st.mode==6 ? 4 : 3
    for c in 0..<n {
        diff[c]=f32(i32(subset.endpoints[1][c])-i32(subset.endpoints[0][c]))
        len_sq+=diff[c]*diff[c]
    }
    scale:=1.0/math.sqrt(len_sq)
    for c in 0..<4 {e.normalized_axis[c]=scale*diff[c]}
}

@(private)
window_extra_estimate_ssd :: #force_inline proc "contextless" (e:^Endpoint_Window_Extra,
    overall_err:f32,
    scaled_pca:^[4]f32) -> f32 {
    m0:=scaled_pca[0]*e.normalized_axis[0]
    m1:=scaled_pca[1]*e.normalized_axis[1]
    m2:=scaled_pca[2]*e.normalized_axis[2]
    m3:=scaled_pca[3]*e.normalized_axis[3]
    return overall_err-abs((m0+m1)+(m2+m3))
}

// Recent blocks in most-recently-used order; slot [size] is a staging area.
@(private)
Window :: struct {
    backing_store:[]Window_Entry,
    mtf:[]u32, // backing_store slots, most recent first
    size:int,
}

@(private)
window_init :: proc(w:^Window,capacity:int,allocator:runtime.Allocator) -> common.Error {
    err:runtime.Allocator_Error
    w.backing_store,err=make([]Window_Entry,capacity,allocator)
    if err!=nil {return .Out_Of_Memory}
    w.mtf,err=make([]u32,capacity,allocator)
    if err!=nil {return .Out_Of_Memory}
    for i in 0..<capacity {w.mtf[i]=u32(i)}
    w.size=0
    return .None
}

@(private)
window_at :: #force_inline proc "contextless" (w:^Window,index:int) -> ^Window_Entry {
    return &w.backing_store[w.mtf[index]]
}

// Seeds the window with the most common endpoints of the baseline.
@(private)
window_seed :: proc(w:^Window,baseline:[]u8,flags:Flags,extra:[]Endpoint_Window_Extra,
    allocator:runtime.Allocator) -> common.Error {
    n:=len(baseline)/16
    blocks,err:=make([]common.Bits128,n,allocator)
    if err!=nil {return .Out_Of_Memory}
    defer delete(blocks,allocator)
    for bi in 0..<n {
        bits:=bits_load((^[16]u8)(&baseline[bi*16]))
        blocks[bi]=bits_zero_indices(bits,false)
    }
    counting:=make([dynamic]common.Bits128_And_Count,0,n,allocator)
    defer delete(counting)
    if e:=common.sort_and_count_uniques_bits128(&counting,blocks); e!=.None {return e}
    common.sort_bits128_and_count_compare_count_highest_first(counting[:])
    resize(&counting,min(len(counting),len(w.mtf)-1))
    for len(counting)>0 && counting[len(counting)-1].count==1 {pop(&counting)}
    w.size=len(counting)
    for s in 0..<len(counting) {
        entry:=window_at(w,s)
        entry.encoded=counting[s].val
        b:=transmute([16]u8)counting[s].val
        state_from_bits(&entry.st,&b,flags&~PRESERVE_EXTREMES)
        if extra!=nil {window_extra_init(&extra[w.mtf[s]],&entry.st)}
    }
    return .None
}

// Adds new_state (lz_found_i < 0) or moves the reused entry lz_found_i to the front.
@(private)
window_update :: proc "contextless" (w:^Window,new_state:^Window_Entry,lz_found_i:int) {
    lz:=lz_found_i
    if lz<0 {
        if w.size+1<len(w.mtf) {w.size+=1}
        lz=w.size-1
        if lz<0 {return}
        window_at(w,lz)^=new_state^
    }
    new_head:=w.mtf[lz]
    for i:=lz; i>0; i-=1 {w.mtf[i]=w.mtf[i-1]}
    w.mtf[0]=new_head
}

// Decodes block bits to RGBA; with IGNORE_ALPHA, A is 255.
@(private)
decode_block4x4a :: #force_inline proc "contextless" (out:^common.Color_Block,bits:^[16]u8,
    flags:Flags) {
    out^=transmute(common.Color_Block)asset.texture_bc7_block_decode(bits^)
    if flags&IGNORE_ALPHA!=0 {
        for i in 0..<16 {out[i][3]=255}
    }
}

@(private)
decode_bits4x4a :: #force_inline proc "contextless" (out:^common.Color_Block,bits:Bits,
    flags:Flags) {
    b:=transmute([16]u8)bits
    decode_block4x4a(out,&b,flags)
}

@(private)
rd_d_state :: proc "contextless" (st:^Block_State,orig:^common.Color_Block,
    activity:^common.Float_Block) -> f32 {
    decomp:common.Color_Block
    decode_state(st,&decomp)
    return common.vqd(&decomp,orig,activity)
}

@(private)
rd_d_bits :: proc "contextless" (bits:Bits,orig:^common.Color_Block,flags:Flags,
    activity:^common.Float_Block) -> f32 {
    decomp:common.Color_Block
    decode_bits4x4a(&decomp,bits,flags)
    return common.vqd(&decomp,orig,activity)
}

@(private)
rd_ssd_bits :: proc "contextless" (bits:Bits,orig:^common.Color_Block,flags:Flags) -> u32 {
    decomp:common.Color_Block
    decode_bits4x4a(&decomp,bits,flags)
    return common.color_block_ssd_rgba(&decomp,orig)
}

// Expected bits of an LZ match covering matched_bits.
@(private)
matched_bits_to_lz_bits :: proc "contextless" (matched_bits:int) -> f32 {
    matched_bytes:=matched_bits/8
    frac_bits:=matched_bits-matched_bytes*8
    p:=f32(int(256)>>uint(8-frac_bits))/256.0
    mean_bytes:=f32(matched_bytes)+p
    return mean_bytes*8.0
}

@(private)
lz_matched_bits_reendpoint :: #force_inline proc "contextless" (mode:int,change_pbits:bool) -> int {
    m:=mode&7
    b:=BITS_INDICES[m]
    if !change_pbits {b+=BITS_PBITS[m]}
    return b
}

// Bits of an LZ match at block offset lzi (from 1).
@(private)
matched_r_lz :: #force_inline proc "contextless" (lzi:int) -> f32 {
    offset_bits:=entropy.rrlog2_bk(u32(lzi+32))
    return 10+offset_bits
}

@(private)
matched_r :: proc "contextless" (matched_bits,offset:int) -> f32 {
    lz_matched_bits:=matched_bits_to_lz_bits(matched_bits)
    raw_bits:=128-lz_matched_bits
    return raw_bits+matched_r_lz(offset)
}

@(private)
rd_j :: #force_inline proc "contextless" (d,r,lambda:f32) -> f32 {return d+lambda*r}

@(private)
bits_to_ssd_err_bias_j :: #force_inline proc "contextless" (bits,lambda:f32) -> u32 {
    ssd_j:=0.5*(lambda*bits)
    return u32(ssd_j+0.5)
}

@(private)
histogram_mode :: proc "contextless" (histo:^[8]u32,baseline:[]u8) {
    histo^={}
    for bi in 0..<len(baseline)/16 {
        b:=(^[16]u8)(&baseline[bi*16])
        if is_encoded_single_color_block(b) {continue}
        m:=bits_get_mode(bits_load(b))
        if m<8 {histo[m]+=1}
    }
}

@(private)
histogram_to_ssd_err_bias_j :: proc "contextless" (bias:^Mode_Err_Bias,histo:^[8]u32,lambda:f32) {
    COUNT_SCALE :: 8
    COUNT_BIAS :: 1
    tot:u32
    mode_counts:[8]u32
    for m in 0..<8 {
        c:=histo[m]*COUNT_SCALE+COUNT_BIAS
        mode_counts[m]=c
        tot+=c
    }
    log2_tot:=entropy.rrlog2neg_bk_32(tot)
    for m in 0..<8 {
        bits:=entropy.rrlog2neg_bk_32(mode_counts[m])-log2_tot
        bias.ssd_err_bias[m]=bits_to_ssd_err_bias_j(bits,lambda)
    }
}

@(private)
are_endpoints_permitted_cold :: proc "contextless" (st:^Block_State,info:^Block_Info) -> bool {
    flags:=info.flags
    if st.mode<=3 {
        return flags&PRESERVE_A0==0
    } else if st.mode<=5 {
        sst0:=&st.subsets[0]
        if sst0.rbit!=0 {return false}
        a0:=sst0.endpoints[0][3]
        a1:=sst0.endpoints[1][3]
        if flags&PRESERVE_A0!=0 && min(a0,a1)!=0 {return false}
        if flags&PRESERVE_A255!=0 && max(a0,a1)!=255 {return false}
        if info.constraints&0x00010001!=0 {
            return a0==((info.constraints&1)!=0 ? 0 : 255)
        }
        return true
    } else {
        if flags&PRESERVE_EXTREMES==PRESERVE_EXTREMES {return false}
        need_a:=u8(flags&PRESERVE_A0!=0 ? 0 : 255)
        sst0:=&st.subsets[0]
        if sst0.endpoints[0][3]!=need_a || sst0.endpoints[1][3]!=need_a {return false}
        if st.mode==7 {
            sst1:=&st.subsets[1]
            if sst1.endpoints[0][3]!=need_a || sst1.endpoints[1][3]!=need_a {return false}
        }
        return true
    }
}

@(private)
are_endpoints_permitted :: #force_inline proc "contextless" (st:^Block_State,
    info:^Block_Info) -> bool {
    if info.flags&PRESERVE_EXTREMES==0 {return true}
    return are_endpoints_permitted_cold(st,info)
}

@(private)
are_indices_permitted :: proc "contextless" (st:^Block_State,info:^Block_Info,
    out_flags:^Flags) -> bool {
    out_flags^=info.flags
    flags:=info.flags
    if flags&PRESERVE_EXTREMES==0 {return true}
    if st.mode<=3 {
        return flags&PRESERVE_A0==0
    } else if st.mode<=5 {
        sst:=&st.subsets[0]
        if sst.rbit!=0 {return false}
        a_inds:=&sst.idxs[(sst.isbit&1)~1]
        ib:=(st.mode==5 || sst.isbit==1) ? 2 : 3
        satisfiable:=constraints_from_indices(a_inds,ib)
        if constraints_superset_of(satisfiable,info.constraints) {
            out_flags^=flags|AEP0_LO
            return true
        } else if constraints_superset_of(constraints_flip(satisfiable),info.constraints) {
            out_flags^=flags|AEP0_HI
            return true
        }
        return false
    } else {
        if flags&DISABLE_MODE67!=0 {return false}
        if st.mode!=7 {return true}
        need_pbits:=u8(flags&PRESERVE_A255!=0 ? 3 : 0)
        return st.subsets[0].pbits==need_pbits && st.subsets[1].pbits==need_pbits
    }
}

@(private)
read_partition_id :: #force_inline proc "contextless" (block:^[16]u8,mode:int) -> int {
    bytes:=u32(block[0])|(u32(block[1])<<8)
    part_bits:=bytes>>uint(mode+1)
    PB :: [8]u32{4,6,6,6,0,0,0,6}
    pb:=PB
    return int(part_bits&((u32(1)<<pb[mode&7])-1))
}

// Whether the block may take merged indices; accumulates index constraints.
@(private)
may_merge_indices :: proc "contextless" (block:^[16]u8,mode:int,info:^Block_Info,
    out:^[2]Constraints) -> bool {
    if info.flags&PRESERVE_EXTREMES==0 || mode<4 {return true}
    block_constraints:=info.constraints
    st:Block_State
    state_from_bits(&st,block,info.flags)
    if mode<=5 {
        sst:=&st.subsets[0]
        if sst.rbit!=0 {return false}
        ainds:=int(sst.isbit&1)~1
        diff:=int(sst.endpoints[0][3])-int(sst.endpoints[1][3])
        if diff<0 {
            out[ainds]|=block_constraints
        } else if diff>0 {
            out[ainds]|=constraints_flip(block_constraints)
        }
        return true
    } else {
        ns:=mode==6 ? 1 : 2
        for s in 0..<ns {
            if st.subsets[s].endpoints[0][3]!=st.subsets[s].endpoints[1][3] {return false}
        }
        return true
    }
}
