package bc4

import "base:intrinsics"
import "base:runtime"
import "core:simd"
import "mirai:cook/compressor/texture/common"
import "mirai:std/compressor/lz/entropy"

// Rate-distortion optimization of BC4 blocks (BC4, each half of BC5, the
// alpha of BC3). Endpoints are two bytes but indices are six, so the work
// is on indices: first each block tries the indices of recent blocks with
// endpoints solved for them, then a bottom-up merge joins groups of blocks
// onto shared indices while the rate saved pays for the distortion.

@(private="file")
LAMBDA_SCALE :: 1.5*common.GLOBAL_LAMBDA_SCALE

@(private="file")
Config :: struct {
    window_size:int,          // blocks searched for index reuse; at most 256
    index_heap_size:int,      // SAD candidates tried beyond the most recent; at most 16
    allow_recalc_for_link:bool,
    max_count_for_recalc:u32,
    // a merge whose distortion is within this factor of the best tries new endpoints
    distortion_ratio_for_refine:i64,
}

@(rodata,private="file")
CONFIGS := [5]Config{
    {256,16,true,4,3},
    {64,4,true,4,2},
    {256,16,true,8,3},
    {256,16,true,8,3},
    {256,16,true,8,3},
}

@(private="file")
Encoding :: struct {
    min_q,max_q:i32,
    min_deq,max_deq:i32,
    dequant:[256]i16,
}

@(private="file")
Enc_Info :: struct {
    lo,hi:f32,  // endpoint clamp range
    scale:f32,  // from dequantized to quantized values
    enc:Encoding,
}

@(private="file")
FOUR :: 0
@(private="file")
SIX :: 1

@(private="file")
superset_of :: #force_inline proc "contextless" (a,b:u32) -> bool {return a&b==b}

@(private="file")
Index_Cache :: struct {
    weights:[16]u8,  // weight_A | weight_B<<4
    inv_ata:[4]f32,  // a00, a01, a11 of (A^T A)^-1 and the weight of the mean
    degen_bias:f32,
    extremes:u32,    // texels that sit on the extremes in this mode
}

// A*A | A*B<<10 | B*B<<20, then A | B<<4 | is_min<<8 | is_max<<24, per index.
@(rodata,private="file")
WEIGHT_TABLE := [2][16]i32{
    {
        5*5, 5|0<<4,
        5*5<<20, 0|5<<4,
        4*4+(4*1<<10)+(1<<20), 4|1<<4,
        3*3+(3*2<<10)+(2*2<<20), 3|2<<4,
        2*2+(2*3<<10)+(3*3<<20), 2|3<<4,
        1+(1*4<<10)+(4*4<<20), 1|4<<4,
        0, 1<<8,
        0, 1<<24,
    },
    {
        7*7, 7|1<<24,
        7*7<<20, 7<<4|1<<8,
        6*6+(6<<10)+(1<<20), 6|1<<4,
        5*5+(5*2<<10)+(2*2<<20), 5|2<<4,
        4*4+(4*3<<10)+(3*3<<20), 4|3<<4,
        3*3+(3*4<<10)+(4*4<<20), 3|4<<4,
        2*2+(2*5<<10)+(5*5<<20), 2|5<<4,
        1+(1*6<<10)+(6*6<<20), 1|6<<4,
    },
}

@(private="file")
init_index_cache :: proc "contextless" (ic:^Index_Cache,in_inds:u64,variant:int,info:^Enc_Info) {
    w:=&WEIGHT_TABLE[variant&1]
    inds:=in_inds
    products:i32
    extremes:u32
    count,bias:i32
    for i in 0..<16 {
        idx:=int(inds&7)
        inds>>=3
        products+=w[idx*2]
        w1:=u32(w[idx*2+1])
        ic.weights[i]=u8(w1&0xff)
        extremes|=(w1>>8)<<uint(i)
        count+=w1&0xff!=0 ? 1 : 0
        bias+=i32((w1>>4)&0xf)
    }
    ic.extremes=extremes
    AA:=products&0x3ff
    AB:=(products>>10)&0x3ff
    BB:=products>>20
    det:=AA*BB-AB*AB
    if det==0 {
        // Equal endpoints: the degenerate solve takes over.
        ic.inv_ata[0],ic.inv_ata[1],ic.inv_ata[2]=0,0,0
    } else {
        scale:=variant==1 ? 7.0/f64(det) : 5.0/f64(det)
        scale*=f64(info.scale)
        ic.inv_ata[0]=f32(scale*f64(BB))
        ic.inv_ata[1]=f32(scale*f64(-AB))
        ic.inv_ata[2]=f32(scale*f64(AA))
    }
    count_scale:=1/f32(count*(variant==1 ? 7 : 5))
    ic.inv_ata[3]=info.scale*count_scale
    ic.degen_bias=variant==1 ? f32(bias)*count_scale : f32(-bias)*count_scale
}

@(private="file")
SAD_WEIGHT_RANGE :: 1*5*7
@(private="file")
SAD_EXTREME_SPACING :: 14
@(private="file")
SAD_EXTREME_MIN :: 0
@(private="file")
SAD_WEIGHT_BASE :: SAD_EXTREME_MIN+SAD_EXTREME_SPACING
@(private="file")
SAD_EXTREME_MAX :: SAD_WEIGHT_BASE+SAD_WEIGHT_RANGE+SAD_EXTREME_SPACING

// Where texels would sit between the endpoints, regardless of quantization.
@(private="file")
sad_from_reference :: proc "contextless" (pixels:^Source_Data,e0,e1:u8,
    info:^Enc_Info) -> (out:[16]u8) {
    d0:=i32(info.enc.dequant[e0])
    d1:=i32(info.enc.dequant[e1])
    LO :: f32(SAD_WEIGHT_BASE/2)
    HI :: f32(255-SAD_WEIGHT_BASE/2)
    if e0>e1 {
        scaling:=f32(SAD_WEIGHT_RANGE)/f32(d0-d1)
        for i in 0..<16 {
            v:=scaling*f32(i32(pixels.values[i])-d1)+(SAD_WEIGHT_BASE+0.5)
            v=clamp(v,LO,HI)
            out[i]=u8(v)
        }
    } else {
        scaling:=d1!=d0 ? f32(SAD_WEIGHT_RANGE)/f32(d1-d0) : 0
        halfway_to_min:=(d0+info.enc.min_deq)/2
        halfway_to_max:=(d1+info.enc.max_deq+1)/2
        for i in 0..<16 {
            input:=i32(pixels.values[i])
            if input<=halfway_to_min {
                out[i]=SAD_EXTREME_MIN
            } else if input>=halfway_to_max {
                out[i]=SAD_EXTREME_MAX
            } else {
                v:=scaling*f32(input-d0)+(SAD_WEIGHT_BASE+0.5)
                v=clamp(v,LO,HI)
                out[i]=u8(v)
            }
        }
    }
    return
}

// SAD_WEIGHT_BASE+SAD_WEIGHT_RANGE*weight of e1, or the extremes, indexed by
// the predecoded (doubled) indices.
@(rodata,private="file")
SAD_LUTS := [2][16]u8{
    {14,0,49,0,21,0,28,0,35,0,42,0,SAD_EXTREME_MIN,0,SAD_EXTREME_MAX,0},
    {49,0,14,0,44,0,39,0,34,0,29,0,24,0,19,0},
}

@(private="file")
sad_from_predecoded :: proc "contextless" (pred:^[16]u8,variant:int) -> (out:[16]u8) {
    lut:=transmute(V16b)SAD_LUTS[variant&1]
    return transmute([16]u8)simd.runtime_swizzle(lut,transmute(V16b)pred^&V16b(15))
}

@(private="file")
V16b :: #simd[16]u8
@(private="file")
V8s :: #simd[8]i16

@(private="file")
Window_Entry :: struct {
    block:u64,
    predecoded:[16]u8,
    sad:[2][16]u8,        // SAD indices for both modes
    inds:[2]Index_Cache,  // index caches for both modes
    most_recent_bi:int,
}

@(private="file")
Subst_Candidate :: struct {
    err:i8,
    index:u8,
}

@(private="file")
DIRECT_CANDIDATES :: 4
@(private="file")
SENTINEL_SAD_ERR :: 127

// Kept in decreasing order of error; equal errors keep the older one later. Each new
// candidate shifts the larger entries down a lane and lands after them.
@(private="file")
reuse_candidates_by_sad :: proc "contextless" (cand:^[16]Subst_Candidate,base:^[16]u8,
    window_inds:[]u16,window:[]Window_Entry,count:int) #no_bounds_check {
    S :: #simd[16]i8
    I :: V16b{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}
    NEXT :: V16b{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,0xff}
    errors:=S(SENTINEL_SAD_ERR)
    indices:V16b
    cand_index:=V16b(DIRECT_CANDIDATES)
    b:=transmute(V16b)base^
    for pb in DIRECT_CANDIDATES..<count {
        e:=&window[window_inds[pb]]
        sad:=min(common.sad_u8x16(b,transmute(V16b)e.sad[0]),
            common.sad_u8x16(b,transmute(V16b)e.sad[1]))
        err:=S(i8((sad>>2)-128))
        cmp:=transmute(V16b)simd.lanes_lt(err,errors)
        move:=I-cmp
        moved_errors:=transmute(S)simd.runtime_swizzle(transmute(V16b)errors,move)
        moved_indices:=simd.runtime_swizzle(indices,move)
        keep:=simd.lanes_eq(cmp,simd.runtime_swizzle(cmp,NEXT))
        errors=simd.select(keep,moved_errors,err)
        indices=simd.select(keep,moved_indices,cand_index)
        cand_index+=1
    }
    cand^=transmute([16]Subst_Candidate)[2]V16b{
        simd.shuffle(transmute(V16b)errors,indices,0,16,1,17,2,18,3,19,4,20,5,21,6,22,7,23),
        simd.shuffle(transmute(V16b)errors,indices,8,24,9,25,10,26,11,27,12,28,13,29,14,30,15,31)}
}

@(rodata,private="file")
PALETTE_W0 := [2][8]i16{{5,0,4,3,2,1,0,0},{7,0,6,5,4,3,2,1}}
@(rodata,private="file")
PALETTE_W1 := [2][8]i16{{0,5,1,2,3,4,0,0},{0,7,1,2,3,4,5,6}}

// The palette as the SIMD decoder makes it: divisions by 5 and 7 through
// 16-bit reciprocal multiplies.
@(private="file")
palette_simd :: proc "contextless" (e0,e1:u8,info:^Enc_Info,variant:int) -> (p:[8]i16) {
    V8w :: #simd[8]i32
    U8w :: #simd[8]u32
    U8h :: #simd[8]u16
    recip:=variant==0 ? i32((0x20000+4)/5) : i32((0x20000+6)/7)
    a:=i16(info.enc.dequant[e0])
    b:=i16(info.enc.dequant[e1])
    scaled:=V8s(a)*transmute(V8s)PALETTE_W0[variant&1]+V8s(b)*transmute(V8s)PALETTE_W1[variant&1]
    hi:=cast(V8s)simd.shr(cast(V8w)scaled*V8w(recip),U8w(16))
    p=transmute([8]i16)(simd.shr(hi,U8h(1))-simd.shr(scaled,U8h(15)))
    if variant==0 {
        p[6]|=i16(info.enc.min_deq)
        p[7]|=i16(info.enc.max_deq)
    }
    return
}

@(private="file")
predecode_inds :: #force_inline proc "contextless" (inds:u64) -> (out:[16]u8) {
    x:=inds
    for i in 0..<16 {
        out[i]=u8((x&7)<<1)
        x>>=3
    }
    return
}

// Indices ordered by the value they decode to: 1..8 in six-value mode,
// 2..7 with 0 and 9 (the extremes) in four-value mode, minus one.
@(private="file")
predecode_ordered_inds :: proc "contextless" (inds:u64,mode:int) -> (out:[16]u8) {
    x:=inds
    for i in 0..<16 {
        ind:=int(x&7)
        if mode==SIX {
            if ind==1 {ind=7} else if ind!=0 {ind-=1}
        } else {
            switch ind {
            case 1: ind=6
            case 0: ind=1
            case 6: ind=0
            }
        }
        out[i]=u8(ind)
        x>>=3
    }
    return
}

@(private="file")
decode_with_pal :: #force_inline proc "contextless" (pred:^[16]u8,pal:^[8]i16) -> (out:[16]i16) {
    // pred holds byte offsets of the 16-bit entries.
    t:=transmute(V16b)pal^
    q:=transmute(V16b)pred^&V16b(14)
    lo:=simd.runtime_swizzle(t,simd.shuffle(q,q,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7)+
        V16b{0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1})
    hi:=simd.runtime_swizzle(t,simd.shuffle(q,q,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15)+
        V16b{0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1})
    return transmute([16]i16)[2]V16b{lo,hi}
}

@(private="file")
decode_block :: proc "contextless" (block:u64,info:^Enc_Info) -> [16]i16 {
    e0:=u8(block)
    e1:=u8(block>>8)
    pal:=palette_simd(e0,e1,info,e0>e1 ? SIX : FOUR)
    pred:=predecode_inds(block>>16)
    return decode_with_pal(&pred,&pal)
}

@(private="file")
decode_with_inds :: #force_inline proc "contextless" (e0,e1:u8,info:^Enc_Info,pred:^[16]u8,
    variant:int) -> [16]i16 {
    pal:=palette_simd(e0,e1,info,variant)
    return decode_with_pal(pred,&pal)
}

@(private="file")
make_block :: #force_inline proc "contextless" (e0,e1:u8,inds:u64) -> u64 {
    return u64(e0)|u64(e1)<<8|inds<<16
}

@(private="file")
ssd16 :: #force_inline proc "contextless" (a,b:^[16]i16) -> i32 {
    x:=transmute([2]V8s)a^
    y:=transmute([2]V8s)b^
    d0:=x[0]-y[0]
    d1:=x[1]-y[1]
    return simd.reduce_add_ordered(common.madd_i16(d0,d0)+common.madd_i16(d1,d1))
}

@(private="file")
Block_Info :: struct {
    baseline_D,J,D:f32,
    constraints:u32,
    pixels:Source_Data,
}

@(private="file")
Mode1_Info :: struct {
    hi,lo:[2]f32,          // per-endpoint float clamp of the solve
    degen_lo,degen_hi:[2]i32,
    activity:^common.Float_Block,
}

@(private="file")
max_ps :: #force_inline proc "contextless" (a,b:f32) -> f32 {return a>b ? a : b}
@(private="file")
min_ps :: #force_inline proc "contextless" (a,b:f32) -> f32 {return a<b ? a : b}

// A^T b, times (A^T A)^-1, clamped and rounded; also the sum of A and B.
@(private="file")
lls_solve_initial :: #force_inline proc "contextless" (blk:^Block_Info,ic:^Index_Cache,lo,
    hi:[2]f32) -> (ep:[2]i32,ab_sum:i32) {
    // Each weight byte twice in a 16-bit lane: the low nibble is A, bits 12 to 15 are B.
    w:=transmute(V16b)ic.weights
    w0:=transmute(V8s)simd.shuffle(w,w,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7)
    w1:=transmute(V8s)simd.shuffle(w,w,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15)
    x:=transmute([2]V8s)blk.pixels.values
    a:=common.madd_i16(w0&V8s(0xf),x[0])+common.madd_i16(w1&V8s(0xf),x[1])
    U :: #simd[8]u16
    b:=common.madd_i16(transmute(V8s)simd.shr(transmute(U)w0,U(12)),x[0])+
        common.madd_i16(transmute(V8s)simd.shr(transmute(U)w1,U(12)),x[1])
    h:=simd.shuffle(a,b,0,1,4,5)+simd.shuffle(a,b,2,3,6,7)
    sums:=h+simd.shuffle(h,h,1,0,3,2) // AX,AX,BX,BX
    ab_sum=simd.extract(sums,0)+simd.extract(sums,2)
    inv:=intrinsics.unaligned_load((^#simd[4]f32)(&ic.inv_ata))
    prods:=(cast(#simd[4]f32)sums)*simd.shuffle(inv,inv,0,1,1,2)
    ep_f:=simd.to_array(prods+simd.shuffle(prods,prods,2,3,0,1))
    e0:=ep_f[0]
    e1:=ep_f[1]
    e0=min_ps(max_ps(e0,lo[0]),hi[0])
    e1=min_ps(max_ps(e1,lo[1]),hi[1])
    ep={common.round_to_int(e0),common.round_to_int(e1)}
    return
}

// Endpoints for the indices of ic in mode (0 four values, 1 six), which the
// constraints of the block must allow.
@(private="file")
cached_lls_solve :: proc "contextless" (blk:^Block_Info,ic:^Index_Cache,info:^Enc_Info,
    mode:int) -> (e0,e1:u8) {
    target_sign:=i32(-mode)
    ep,ab_sum:=lls_solve_initial(blk,ic,{info.lo,info.lo},{info.hi,info.hi})
    ep0,ep1:=ep[0],ep[1]
    c:=blk.constraints
    if c&u32(target_sign)!=0 {
        if c&0x0000ffff!=0 {ep1=info.enc.min_q}
        if c&0xffff0000!=0 {ep0=info.enc.max_q}
    }
    diff:=((ep1-ep0)~target_sign)-target_sign
    if diff<=0 {
        // The ordering constraint is active: the best pair one step apart,
        // from the mean of the texels.
        mean:=f32(ab_sum)*ic.inv_ata[3]+ic.degen_bias
        ep0=common.round_to_int(mean)
        if target_sign==0 {
            ep0=clamp(ep0,info.enc.min_q,info.enc.max_q-1)
            ep1=ep0+1
        } else {
            ep0=clamp(ep0,info.enc.min_q+1,info.enc.max_q)
            ep1=ep0-1
            if c&0x0000ffff!=0 {ep1=info.enc.min_q}
            if c&0xffff0000!=0 {ep0=info.enc.max_q}
        }
    }
    return u8(ep0&0xff),u8(ep1&0xff)
}

@(private="file")
Mode1_Item :: struct {
    ic:^Index_Cache,
    ep:[2]u8,
    pred:^[16]u8,
    D:f32,
}

@(private="file")
batch_lls_solve_mode1 :: proc "contextless" (items:[]Mode1_Item,blk:^Block_Info,m1:^Mode1_Info,
    info:^Enc_Info) {
    for &it in items {
        ep,ab_sum:=lls_solve_initial(blk,it.ic,m1.lo,m1.hi)
        mean:=f32(ab_sum)*it.ic.inv_ata[3]+it.ic.degen_bias
        m:=common.round_to_int(mean)
        d0:=max(min(m,m1.degen_hi[0]),m1.degen_lo[0])
        d1:=max(min(m-1,m1.degen_hi[1]),m1.degen_lo[1])
        if !(ep[0]>ep[1]) {ep={d0,d1}}
        it.ep={u8(ep[0]&0xff),u8(ep[1]&0xff)}
    }
    for &it in items {
        dec:=decode_with_inds(it.ep[0],it.ep[1],info,it.pred,SIX)
        it.D=common.vqd_s16(&dec,&blk.pixels.values,m1.activity)
    }
}

@(private="file")
matched_index_R :: #force_inline proc "contextless" (offset:int) -> f32 {
    // Endpoints sent raw, the indices as an LZ match.
    offset_bits:=entropy.rrlog2_bk(u32(offset+16))
    return 16+(10+offset_bits)
}

@(private="file")
Vq_Block :: struct {
    endpt:[2]u8,
    link:i32,
    palette:[8]i16,
}

@(private="file")
Vq_Entry :: struct {
    inds:u64,
    distortion_sum:i64,
    block_link:i32,       // blocks with these indices, linked through Vq_Block.link
    count:u32,
    count_log2_count:u32,
    merged_onto:i32,      // -1 while not merged
    constraints:u32,      // of the whole cluster
    mode:int,
    index8_scaled:[16]u8,
    indc:Index_Cache,
}

@(private="file")
Vq_Filter :: struct {
    constraints:u32,
    extremes:u32,
    conservative_sad:i32,
    index8_ordered:[16]u8,
}

@(private="file")
Heap_Entry :: struct {
    fm,to:int,
    dJ:f32, // positive is a good merge
    fm_count_save:u32,
    fm_distortion_onto:i64,
}

@(private="file")
heap_less :: proc(a,b:Heap_Entry) -> bool {return a.dJ<b.dJ}
@(private="file")
heap_greater :: proc(a,b:Heap_Entry) -> bool {return b.dJ<a.dJ}

@(private="file")
LARGE_D :: i64(0x48000000)

// The chunk sizes of the original (16 KiB over its 96-byte entries and
// 28-byte filters) fix the order candidates reach the heap.
@(private="file")
ENTRY_CHUNK :: 16*1024/96
@(private="file")
FILTER_CHUNK :: 16*1024/28
@(private="file")
MIN_COUNT_FOR_AID :: 8

@(rodata,private="file")
SAD_BOUND_ORDER := [2][8]int{{6,0,2,3,4,5,1,7},{0,2,3,4,5,6,7,1}}

@(private="file")
index_sad_bound :: proc "contextless" (mode:int,ordered:^[16]u8,src:^[16]i16,raw_palette:^[8]i16,
    constraint_mask:u32,in_limit:i32) -> i32 {
    order:=&SAD_BOUND_ORDER
    limit:=min(in_limit,0x2001*0x2001)
    delta:[16][8]i32
    pal:[24]i32
    for i in 0..<24 {pal[i]=0x3001}
    for i in 0..<8 {pal[8+i]=i32(raw_palette[order[mode][i]])}
    for i in 0..<16 {for j in 0..<8 {delta[i][j]=0x7fffffff}}
    ssd:i32
    for i in 0..<16 {
        cur:=int(ordered[i]&7)
        n:=0
        sq :: #force_inline proc "contextless" (x:i32) -> i32 {return x*x}
        last:=sq(i32(src[i])-pal[8+cur])
        ssd+=last
        if constraint_mask&(0x10001<<uint(i))==0 {
            for d in 1..<8 {
                below:=sq(i32(src[i])-pal[8+cur-d])
                above:=sq(i32(src[i])-pal[8+cur+d])
                nssd:=min(below,above)
                if nssd>limit {break}
                nssd=max(nssd,last)
                delta[i][n]=nssd-last
                n+=1
                last=nssd
            }
        }
    }
    return common.compute_sad_bound_for_ssd_threshold(&delta,ssd,limit)
}

@(private="file")
block_offset :: #force_inline proc "contextless" (bi,group_shift,group_mask,stride,
    offset:int) -> int {
    return offset+(bi>>uint(group_shift))*stride+(bi&group_mask)*8
}

@(private="file")
Merge :: struct {
    to:[]u8,
    stride,offset:int,
    activity:[]common.Float_Block,
    group_shift,group_mask:int,
    infos:[]Block_Info,
    blocks:[]Vq_Block,
    info:^Enc_Info,
    config:^Config,
}

@(private="file")
get_out_block :: #force_inline proc "contextless" (m:^Merge,bi:int) -> u64 {
    return get_block(m.to[block_offset(bi,m.group_shift,m.group_mask,m.stride,m.offset):])
}

@(private="file")
put_out_block :: #force_inline proc "contextless" (m:^Merge,bi:int,bits:u64) {
    put_block(m.to[block_offset(bi,m.group_shift,m.group_mask,m.stride,m.offset):],bits)
}

@(private="file")
single_change_distortion :: #force_inline proc "contextless" (m:^Merge,bi:int,from:^Vq_Entry,
    pal:^[8]i16) -> i64 {
    dec:=decode_with_pal(&from.index8_scaled,pal)
    return i64(ssd16(&dec,&m.infos[bi].pixels.values))
}

// The distortion of the blocks linked from bi with the indices of from;
// LARGE_D once it passes must_beat.
@(private="file")
block_link_distortion :: proc "contextless" (m:^Merge,start:i32,from:^Vq_Entry,
    allow_new_endpoints:bool,must_beat:i64) -> i64 {
    sum:i64
    bi:=start
    for bi>=0 {
        b:=&m.blocks[bi]
        best:=single_change_distortion(m,int(bi),from,&b.palette)
        if allow_new_endpoints && best<=(must_beat-sum)*m.config.distortion_ratio_for_refine {
            e0,e1:=cached_lls_solve(&m.infos[bi],&from.indc,m.info,from.mode)
            if (e0~b.endpt[0])|(e1~b.endpt[1])!=0 {
                pal:=palette_simd(e0,e1,m.info,from.mode)
                best=min(best,single_change_distortion(m,int(bi),from,&pal))
            }
        }
        sum+=best
        if sum>must_beat {return LARGE_D}
        bi=b.link
    }
    return sum
}

@(private="file")
merge_dJ :: proc "contextless" (from,to:^Vq_Entry,D_diff:i64,lambda:f32) -> f32 {
    D:=f32(D_diff)
    merged:=from.count+to.count
    log2_merged:=merged*u32(entropy.log2tabled_bk_32(merged))
    delta:=from.count_log2_count+to.count_log2_count-log2_merged
    // One fewer set of 48 index bits, and cheaper selection.
    R:=f32(delta)*(1.0/f32(entropy.LOG2TABLE_ONE))+48
    return -D+lambda*R
}

@(private="file")
is_legal_merge :: #force_inline proc "contextless" (fm,to:^Vq_Entry) -> bool {
    if fm.mode!=to.mode {return false}
    return superset_of(to.indc.extremes,fm.constraints|to.constraints)
}

@(private="file")
emit_cluster_basic :: proc "contextless" (m:^Merge,cluster:^Vq_Entry) {
    for bi:=cluster.block_link;bi>=0;bi=m.blocks[bi].link {
        b:=&m.blocks[bi]
        act:=&m.activity[int(bi)>>uint(m.group_shift)]
        bits:=make_block(b.endpt[0],b.endpt[1],cluster.inds)
        put_out_block(m,int(bi),bits)
        dec:=decode_block(bits,m.info)
        best:=common.vqd_s16(&dec,&m.infos[bi].pixels.values,act)
        // Endpoints cost the same whatever they are: take better ones.
        e0,e1:=cached_lls_solve(&m.infos[bi],&cluster.indc,m.info,cluster.mode)
        dec=decode_with_inds(e0,e1,m.info,&cluster.index8_scaled,cluster.mode)
        if common.vqd_s16(&dec,&m.infos[bi].pixels.values,act)<best {
            put_out_block(m,int(bi),make_block(e0,e1,cluster.inds))
        }
    }
}

// Emits the cluster, then solves the best shared indices for its blocks and
// emits again with them if they differ.
@(private="file")
emit_cluster_optimize :: proc "contextless" (m:^Merge,cluster:^Vq_Entry) {
    emit_cluster_basic(m,cluster)
    mode:=cluster.mode
    total:[16][8]i64
    for bi:=cluster.block_link;bi>=0;bi=m.blocks[bi].link {
        bits:=get_out_block(m,int(bi))
        pal:=palette_simd(u8(bits),u8(bits>>8),m.info,mode)
        src:=&m.infos[bi].pixels.values
        for i in 0..<16 {
            for j in 0..<8 {
                d:=i64(src[i])-i64(pal[j])
                total[i][j]+=d*d
            }
        }
    }
    nc:=cluster^
    nc.inds=0
    min_ind:=u64(mode==1 ? 1 : 6)
    max_ind:=u64(mode==1 ? 0 : 7)
    for i in 0..<16 {
        best_err:=total[i][0]
        best:=u64(0)
        for j in 1..<8 {
            if total[i][j]<best_err {
                best_err=total[i][j]
                best=u64(j)
            }
        }
        if nc.constraints&(1<<uint(i))!=0 {best=min_ind}
        if nc.constraints&(0x10000<<uint(i))!=0 {best=max_ind}
        nc.inds|=best<<(3*uint(i))
    }
    if nc.inds==cluster.inds {return}
    nc.index8_scaled=predecode_inds(nc.inds)
    init_index_cache(&nc.indc,nc.inds,mode,m.info)
    emit_cluster_basic(m,&nc)
}

@(private="file")
ssd_limit_of :: #force_inline proc "contextless" (best:i64,config:^Config) -> i32 {
    return i32(min(best*config.distortion_ratio_for_refine,0x7fffffff))
}

@(private="file")
push_heap_entry :: proc(heap:^[dynamic]Heap_Entry,limit:int,he:Heap_Entry) -> bool {
    if len(heap)>=limit {
        // Keep the better half.
        common.stdsort(heap[:],heap_greater)
        resize(heap,limit/2)
    }
    _,err:=append(heap,he)
    return err==nil
}

@(private="file")
entry_less :: proc(a,b:Vq_Entry) -> bool {return a.count>b.count}

@(private="file")
Inds_And_Id :: u64 // inds<<16 | mode<<15 | id

@(private="file")
u64_less :: proc(a,b:u64) -> bool {return a<b}

@(private="file")
bottom_up_merge :: proc(m:^Merge,vqd_lambda:f32,allocator:runtime.Allocator) -> common.Error {
    context.allocator=allocator
    config:=m.config
    info:=m.info
    nb:=len(m.blocks)
    // VQD is about twice SSD, and the merge works in SSD.
    lambda:=vqd_lambda/2.0

    v_indices,e1:=make([]Inds_And_Id,nb)
    if e1!=nil {return .Out_Of_Memory}
    defer delete(v_indices)
    for bi in 0..<nb {
        bits:=get_out_block(m,bi)
        b:=&m.blocks[bi]
        b.endpt={u8(bits),u8(bits>>8)}
        mode:=b.endpt[0]>b.endpt[1] ? SIX : FOUR
        b.link=-1
        b.palette=palette_simd(b.endpt[0],b.endpt[1],info,mode)
        v_indices[bi]=(bits>>16)<<16|u64(mode)<<15|u64(bi)
    }
    common.stdsort(v_indices,u64_less)

    entries:=make([dynamic]Vq_Entry,0,nb)
    defer delete(entries)
    if cap(entries)<nb {return .Out_Of_Memory}
    for v in v_indices {
        bi:=int(v&0x7fff)
        mode:=int((v>>15)&1)
        inds:=v>>16
        if m.infos[bi].J==0 {continue} // single color
        n:=len(entries)
        if n==0 || entries[n-1].inds!=inds || entries[n-1].mode!=mode {
            e:Vq_Entry
            e.inds=inds
            e.block_link=i32(bi)
            e.count=1
            e.merged_onto=-1
            e.constraints=m.infos[bi].constraints
            e.mode=mode
            e.index8_scaled=predecode_inds(e.inds)
            init_index_cache(&e.indc,e.inds,e.mode,info)
            e.distortion_sum=single_change_distortion(m,bi,&e,&m.blocks[bi].palette)
            append(&entries,e)
        } else {
            e:=&entries[n-1]
            m.blocks[bi].link=e.block_link
            e.block_link=i32(bi)
            e.count+=1
            e.distortion_sum+=single_change_distortion(m,bi,e,&m.blocks[bi].palette)
            e.constraints|=m.infos[bi].constraints
        }
    }
    if len(entries)<2 {return .None}

    for &e in entries {
        e.count_log2_count=e.count*u32(entropy.log2tabled_bk_32(e.count))
        e.count|=u32(e.mode)<<30 // sort by mode as well as count
    }
    max_distortion_increase:=i64(48.0*lambda)
    common.stdsort(entries[:],entry_less)

    filters,e2:=make([]Vq_Filter,len(entries))
    if e2!=nil {return .Out_Of_Memory}
    defer delete(filters)
    num_for_mode,num_large:[2]int
    for &e,ei in entries {
        e.count&=0x3fffffff
        num_for_mode[e.mode]+=1
        filters[ei]={e.constraints,e.indc.extremes,0,predecode_ordered_inds(e.inds,e.mode)}
        if e.count>=MIN_COUNT_FOR_AID {num_large[e.mode]+=1}
    }

    aids,e3:=make([]common.Any_Index_8D64,num_large[0]+num_large[1])
    if e3!=nil {return .Out_Of_Memory}
    defer delete(aids)
    aid_init :: proc "contextless" (m:^Merge,aid:^common.Any_Index_8D64,start:i32) {
        aid^={}
        for bi:=start;bi>=0;bi=m.blocks[bi].link {
            src:=&m.infos[bi].pixels.values
            pal:=&m.blocks[bi].palette
            for c in 0..<16 {
                for i in 0..<8 {
                    d:=i32(src[c]-pal[i])
                    aid.ssdx[c][i]+=u64(u32(d*d))
                }
            }
        }
    }
    // The sort puts mode 1 first.
    for mode in 0..<2 {
        start:=mode==0 ? num_for_mode[1] : 0
        aid_start:=mode==0 ? num_large[1] : 0
        for i in 0..<num_large[mode] {aid_init(m,&aids[aid_start+i],entries[start+i].block_link)}
    }

    heap_limit:=max(nb,64)*8
    heap:=make([dynamic]Heap_Entry,0,heap_limit)
    defer delete(heap)
    if cap(heap)<heap_limit {return .Out_Of_Memory}

    best_distortions,e4:=make([]i64,len(entries))
    if e4!=nil {return .Out_Of_Memory}
    defer delete(best_distortions)
    chunk_inds:[FILTER_CHUNK][16]u8
    chunk_index8:[FILTER_CHUNK][16]u8
    filtered:[FILTER_CHUNK]i32
    cand_d:[FILTER_CHUNK+1]i32
    cand_d64:[ENTRY_CHUNK]i64
    cand_packs:[(ENTRY_CHUNK+7)/8]common.Any_Index_8D64_Pack
    aid_small:common.Any_Index_8D64

    for modes in 0..<2 {
        start:=modes==0 ? num_for_mode[1] : 0
        aid_start:=modes==0 ? num_large[1] : 0
        entries_size:=start+num_for_mode[modes]
        first_singleton:=entries_size

        // Groups of more than one block.
        for chunk_begin:=start;chunk_begin<entries_size;chunk_begin+=ENTRY_CHUNK {
            chunk_end:=min(chunk_begin+ENTRY_CHUNK,entries_size)
            for to in chunk_begin..<chunk_end {
                k:=to-chunk_begin
                common.any_index_8d64_pack_set(&cand_packs[k>>3],k,&entries[to].index8_scaled)
            }
            fm:=start
            for ;fm<first_singleton;fm+=1 {
                if entries[fm].count<=1 {break}
                fm_base:=entries[fm].distortion_sum
                allow_new:=config.allow_recalc_for_link &&
                    entries[fm].count<=config.max_count_for_recalc
                best:=&best_distortions[fm]
                if chunk_begin==start {best^=fm_base+max_distortion_increase}
                aid:=&aid_small
                if entries[fm].count<MIN_COUNT_FOR_AID {
                    aid_init(m,aid,entries[fm].block_link)
                } else {
                    aid=&aids[aid_start+(fm-start)]
                }
                common.any_index_8d64_batch_lookup_packed(cand_d64[:],aid,cand_packs[:],
                    chunk_end-chunk_begin)
                for to in chunk_begin..<chunk_end {
                    if fm==to {continue}
                    if !is_legal_merge(&entries[fm],&entries[to]) {continue}
                    new_D:=cand_d64[to-chunk_begin]
                    if new_D>best^*(config.distortion_ratio_for_refine+1) {continue}
                    if allow_new {
                        new_D=block_link_distortion(m,entries[fm].block_link,&entries[to],true,
                            best^)
                    }
                    // Sorted by count, so only an improving D needs its J.
                    if new_D<=best^ {
                        best^=new_D
                        dJ:=merge_dJ(&entries[fm],&entries[to],new_D-fm_base,lambda)
                        if dJ>0 {
                            he:=Heap_Entry{fm=fm,to=to,dJ=dJ,fm_count_save=entries[fm].count,
                                fm_distortion_onto=new_D}
                            if !push_heap_entry(&heap,heap_limit,he) {return .Out_Of_Memory}
                        }
                    }
                }
            }
            first_singleton=fm
        }

        // Single blocks, filtered by index SAD first.
        for chunk_begin:=start;chunk_begin<entries_size;chunk_begin+=FILTER_CHUNK {
            chunk_end:=min(chunk_begin+FILTER_CHUNK,entries_size)
            chunk_len:=chunk_end-chunk_begin
            for i in 0..<chunk_len {
                chunk_inds[i]=filters[chunk_begin+i].index8_ordered
                chunk_index8[i]=entries[chunk_begin+i].index8_scaled
            }
            batch:=([^]u8)(&chunk_inds[0])[:chunk_len*16]
            for fm in first_singleton..<entries_size {
                fm_base:=entries[fm].distortion_sum
                fm_bi:=int(entries[fm].block_link)
                best:=&best_distortions[fm]
                if chunk_begin==start {best^=fm_base+max_distortion_increase}
                best_limit:=ssd_limit_of(best^,config)
                if chunk_begin==start {
                    filters[fm].conservative_sad=index_sad_bound(entries[fm].mode,
                        &filters[fm].index8_ordered,
                        &m.infos[fm_bi].pixels.values,&m.blocks[fm_bi].palette,
                        entries[fm].constraints,best_limit)
                }
                pal:=&m.blocks[fm_bi].palette
                count:=common.filter_by_index_sad(filtered[:],chunk_len,batch,
                    &filters[fm].index8_ordered,filters[fm].conservative_sad)
                pixels:=&m.infos[fm_bi].pixels.values
                common.bc4_change_distortion_batch(cand_d[:count],pixels,pal,
                    ([^]u8)(&chunk_index8[0])[:chunk_len*16],filtered[:count])
                cand_d[count]=-1
                for i:=0;;i+=1 {
                    i=common.find_next_below_i32(cand_d[:count+1],i,best_limit)
                    if i>=count {break}
                    to:=chunk_begin+int(filtered[i])
                    if fm==to {continue}
                    if !superset_of(filters[to].extremes,
                        filters[fm].constraints|filters[to].constraints) {continue}
                    new_D:=cand_d[i]
                    {
                        e0,e1:=cached_lls_solve(&m.infos[fm_bi],&entries[to].indc,info,
                            entries[to].mode)
                        np:=palette_simd(e0,e1,info,entries[to].mode)
                        nd:=decode_with_pal(&entries[to].index8_scaled,&np)
                        D:=ssd16(&nd,pixels)
                        new_D=min(new_D,D)
                    }
                    if i64(new_D)<=best^ {
                        best^=i64(new_D)
                        best_limit=ssd_limit_of(best^,config)
                        dJ:=merge_dJ(&entries[fm],&entries[to],i64(new_D)-fm_base,lambda)
                        if dJ>0 {
                            he:=Heap_Entry{fm=fm,to=to,dJ=dJ,fm_count_save=1,
                                fm_distortion_onto=i64(new_D)}
                            if !push_heap_entry(&heap,heap_limit,he) {return .Out_Of_Memory}
                        }
                    }
                }
            }
        }
    }

    common.heap_make(heap[:],heap_less)
    for len(heap)>0 {
        he:=heap[0]
        common.heap_popped(heap[:],heap_less)
        pop(&heap)
        fm:=he.fm
        if entries[fm].merged_onto>=0 {continue}
        dirty:=he.fm_count_save!=entries[fm].count
        to:=he.to
        if entries[to].merged_onto>=0 {
            for entries[to].merged_onto>=0 {to=int(entries[to].merged_onto)}
            if to==fm {continue}
            dirty=true
        }
        if dirty {
            if !is_legal_merge(&entries[fm],&entries[to]) {continue}
            fm_base:=entries[fm].distortion_sum
            allow_new:=config.allow_recalc_for_link &&
                entries[fm].count<=config.max_count_for_recalc
            must_beat:=fm_base+max_distortion_increase
            new_D:=block_link_distortion(m,entries[fm].block_link,&entries[to],allow_new,must_beat)
            if new_D<LARGE_D {
                dJ:=merge_dJ(&entries[fm],&entries[to],new_D-fm_base,lambda)
                if dJ>0 {
                    _,err:=append(&heap,Heap_Entry{fm=fm,to=to,dJ=dJ,
                        fm_count_save=entries[fm].count,fm_distortion_onto=new_D})
                    if err!=nil {return .Out_Of_Memory}
                    common.heap_push(heap[:],heap_less)
                }
            }
            continue
        }

        ef:=&entries[fm]
        et:=&entries[to]
        ef.merged_onto=i32(to)
        et.count+=ef.count
        et.constraints|=ef.constraints
        et.count_log2_count=et.count*u32(entropy.log2tabled_bk_32(et.count))
        link:=ef.block_link
        for m.blocks[link].link>=0 {link=m.blocks[link].link}
        orig_to_head:=et.block_link
        m.blocks[link].link=orig_to_head
        et.block_link=ef.block_link
        if ef.count<=config.max_count_for_recalc {
            // New endpoints for the blocks that joined.
            for bi:=ef.block_link;bi!=orig_to_head;bi=m.blocks[bi].link {
                b:=&m.blocks[bi]
                b.endpt[0],b.endpt[1]=cached_lls_solve(&m.infos[bi],&et.indc,info,et.mode)
                b.palette=palette_simd(b.endpt[0],b.endpt[1],info,et.mode)
                et.distortion_sum+=single_change_distortion(m,int(bi),et,&b.palette)
            }
        } else {
            et.distortion_sum+=he.fm_distortion_onto
        }
    }

    for &e in entries {
        if e.merged_onto>=0 {continue}
        emit_cluster_optimize(m,&e)
    }
    return .None
}

// Four-value blocks put the constrained texels on the explicit extremes.
@(private="file")
canonicalize_for_constraints :: proc "contextless" (block:u64,constraints:u32) -> u64 {
    e0,e1:=u8(block),u8(block>>8)
    if e0>e1 {return block}
    inds:=block>>16
    for i in 0..<16 {
        if constraints&(1<<uint(i))!=0 {inds=(inds&~(u64(7)<<(uint(i)*3)))|u64(6)<<(uint(i)*3)}
    }
    for i in 0..<16 {
        if constraints&(0x10000<<uint(i))!=0 {inds|=u64(7)<<(uint(i)*3)}
    }
    return make_block(e0,e1,inds)
}

@(private="file")
encoding_of :: proc "contextless" (t:Value_Type) -> (e:Encoding) {
    e.min_q,e.max_q=0,255
    e.min_deq=0
    switch t {
    case .UNorm:
        e.max_deq=1<<SCALE_BITS
        for i in 0..<256 {e.dequant[i]=i16(dequantize(i,.UNorm))}
    case .Alpha:
        e.max_deq=255
        for i in 0..<256 {e.dequant[i]=i16(i)}
    }
    return
}

// RDO of a slice of blocks. `from`, `source`, `stride` and `offset` are as in
// compress; `baseline` holds the non-RDO encode of the same blocks at the
// same stride and offset, and `activity` one Float_Block per block of from.
// The lambda of the alpha of BC3 (rd_options.use_bc3_alpha_lambda) is the
// caller's choice: it passes the lambda to use.
rd :: proc(to:[]u8,stride,offset:int,from:[]u8,source:Source,baseline:[]u8,
    activity:[]common.Float_Block,
    lambda:int,options:common.Options,rd_options:common.RD_Options,
    allocator:=context.allocator) -> common.Error {
    sb:=source_bytes(source)
    ob:=block_bytes(source)
    if len(from)%sb!=0 || stride<ob || offset<0 || lambda<0 {return .Invalid}
    count:=len(from)/sb
    if count==0 {return .None}
    last:=offset+(count-1)*stride+ob
    if last>len(to) || last>len(baseline) || len(activity)!=count {return .Invalid}
    if int(rd_options.effort)>=len(CONFIGS) {return .Invalid}
    config:=&CONFIGS[rd_options.effort]

    value_type:=source==.RGBA8_Alpha ? Value_Type.Alpha : Value_Type.UNorm
    flambda:=f32(lambda)*LAMBDA_SCALE
    // 12 bits instead of 8, squared.
    if value_type==.UNorm {flambda*=16.0*16.0}
    preserve:=.BC3457_Preserve_Extremes in options

    info:Enc_Info
    info.enc=encoding_of(value_type)
    info.lo=f32(info.enc.min_q)
    info.hi=f32(info.enc.max_q)
    info.scale=info.hi/f32(info.enc.max_deq)

    group_shift:=source==.RG16 ? 1 : 0
    group_mask:=(1<<uint(group_shift))-1
    nblocks:=count<<uint(group_shift)
    if nblocks>=1<<15 {return .Invalid}

    window,ea:=make([]Window_Entry,config.window_size,allocator)
    if ea!=nil {return .Out_Of_Memory}
    defer delete(window,allocator)
    window_inds,eb:=make([]u16,config.window_size,allocator)
    if eb!=nil {return .Out_Of_Memory}
    defer delete(window_inds,allocator)
    for &w,i in window_inds {w=u16(i)}
    infos,ec:=make([]Block_Info,nblocks,allocator)
    if ec!=nil {return .Out_Of_Memory}
    defer delete(infos,allocator)
    blocks,ed:=make([]Vq_Block,nblocks,allocator)
    if ed!=nil {return .Out_Of_Memory}
    defer delete(blocks,allocator)

    num_in_window:=0
    cand:[16]Subst_Candidate
    pixels:[2]Source_Data
    for bi in 0..<nblocks {
        src_bi:=bi>>uint(group_shift)
        in_group:=bi&group_mask
        act:=&activity[src_bi]
        boff:=block_offset(bi,group_shift,group_mask,stride,offset)
        if in_group==0 {
            src:=from[src_bi*sb:][:sb]
            if group_mask==0 {pixels[0]=read_source(src,source)} else {pixels[0],
                pixels[1]=read_source_bc5(src)}
        }
        blk:Block_Info
        blk.pixels=pixels[in_group]
        original:=get_block(baseline[boff:])
        if preserve {
            for i in 0..<16 {
                v:=i32(blk.pixels.values[i])
                if v==info.enc.min_deq {blk.constraints|=1<<uint(i)}
                if v==info.enc.max_deq {blk.constraints|=0x10000<<uint(i)}
            }
            original=canonicalize_for_constraints(original,blk.constraints)
        }
        m1:Mode1_Info
        m1.activity=act
        m1.lo={info.lo,info.lo}
        m1.hi={info.hi,info.hi}
        m1.degen_lo={info.enc.min_q+1,info.enc.min_q}
        m1.degen_hi={info.enc.max_q,info.enc.max_q-1}
        if blk.constraints&0x0000ffff!=0 {
            m1.hi[1]=info.lo
            m1.degen_hi[1]=info.enc.min_q
        }
        if blk.constraints&0xffff0000!=0 {
            m1.lo[0]=info.hi
            m1.degen_lo[0]=info.enc.max_q
        }

        chosen:=original
        dec:=decode_block(chosen,&info)
        blk.baseline_D=common.vqd_s16(&dec,&blk.pixels.values,act)
        blk.D=blk.baseline_D
        initial_inds:=chosen>>16
        if initial_inds~((initial_inds<<3)&0xffffffffffff)<8 {
            // One index everywhere: left alone, J 0 marks it.
            put_block(to[boff:],original)
            blk.J=0
            infos[bi]=blk
            continue
        }

        best_D:=blk.baseline_D
        best_J:=best_D+flambda*64
        best_index:=-1
        base_sad:=sad_from_reference(&blk.pixels,u8(chosen),u8(chosen>>8),&info)
        reuse_candidates_by_sad(&cand,&base_sad,window_inds,window,num_in_window)

        items:[DIRECT_CANDIDATES+16]Mode1_Item
        pbs:[DIRECT_CANDIDATES+16]int
        rates:[DIRECT_CANDIDATES+16]f32
        n:=0
        for i in 0..<DIRECT_CANDIDATES+config.index_heap_size {
            pb:=i
            j:=i-DIRECT_CANDIDATES
            if j>=0 {
                if cand[15-j].err==SENTINEL_SAD_ERR {continue}
                pb=int(cand[15-j].index)
            } else if pb>=num_in_window {
                continue
            }
            pbs[n]=pb
            w:=&window[window_inds[pb]]
            match_R:=matched_index_R(bi-w.most_recent_bi)
            rates[n]=match_R
            if flambda*match_R<=best_J {
                items[n].ic=&w.inds[1]
                items[n].pred=&w.predecoded
                n+=1
            }
        }
        batch_lls_solve_mode1(items[:n],&blk,&m1,&info)
        for i in 0..<n {
            pb:=pbs[i]
            w:=&window[window_inds[pb]]
            match_R:=rates[i]
            if flambda*match_R>best_J {continue}
            packed:=w.block>>16
            if packed==initial_inds {
                // The same indices: the baseline at a match rate.
                J:=blk.baseline_D+flambda*match_R
                if J<best_J {
                    best_J=J
                    best_D=blk.baseline_D
                    best_index=pb
                    chosen=original
                }
            } else {
                e0,e1:u8
                variant:=-1
                if superset_of(w.inds[SIX].extremes,blk.constraints) {
                    e0,e1=items[i].ep[0],items[i].ep[1]
                    variant=SIX
                } else if superset_of(w.inds[FOUR].extremes,blk.constraints) {
                    e0,e1=cached_lls_solve(&blk,&w.inds[FOUR],&info,FOUR)
                    variant=FOUR
                }
                if variant>=0 {
                    D:f32
                    if variant==SIX {
                        D=items[i].D
                    } else {
                        dec=decode_with_inds(e0,e1,&info,&w.predecoded,variant)
                        D=common.vqd_s16(&dec,&blk.pixels.values,act)
                    }
                    J:=D+flambda*match_R
                    if J<best_J {
                        best_J=J
                        best_D=D
                        best_index=pb
                        chosen=make_block(e0,e1,packed)
                    }
                }
            }
        }

        put_block(to[boff:],chosen)
        blk.D=best_D
        blk.J=best_J
        infos[bi]=blk

        if best_index==-1 {
            if num_in_window<config.window_size {
                best_index=num_in_window
                num_in_window+=1
            } else {
                best_index=config.window_size-1
            }
            e:=&window[window_inds[best_index]]
            e.block=chosen
            inds:=chosen>>16
            e.predecoded=predecode_inds(inds)
            e.sad[0]=sad_from_predecoded(&e.predecoded,0)
            e.sad[1]=sad_from_predecoded(&e.predecoded,1)
            init_index_cache(&e.inds[0],inds,0,&info)
            init_index_cache(&e.inds[1],inds,1,&info)
        }
        // Partway to the front, which rewards frequency too.
        move_to:=best_index/4
        slot:=window_inds[best_index]
        for k:=best_index;k>move_to;k-=1 {window_inds[k]=window_inds[k-1]}
        window_inds[move_to]=slot
        window[slot].most_recent_bi=bi
    }

    m:=Merge{to=to,stride=stride,offset=offset,activity=activity,group_shift=group_shift,
        group_mask=group_mask,infos=infos,blocks=blocks,info=&info,config=config}
    return bottom_up_merge(&m,flambda,allocator)
}
