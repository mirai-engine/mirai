package bc7

import "core:math"
import "base:intrinsics"
import "core:simd"
import "mirai:asset"
import "mirai:cook/compressor/texture/bc67"
import "mirai:cook/compressor/texture/common"

// Endpoint refinement of one subset: least squares, PCA fits, linear
// transforms of the indices, jitter, annealing and greedy steps.

// 0xff for the texels inside the subset.
@(private)
count_mask :: #force_inline proc "contextless" (n:int) -> V16b {
    I :: V16b{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}
    return transmute(V16b)simd.lanes_lt(I,V16b(u8(n)))
}

// The lerp weight of each texel of the subset (0 past it).
@(private)
lerp_weights16 :: #force_inline proc "contextless" (indices:^[16]u8,n,ib:int) -> V16b {
    lut:=transmute(V16b)asset.BC7_WEIGHTS[ib&7]
    idx:=intrinsics.unaligned_load((^V16b)(indices))&V16b(15)
    return simd.runtime_swizzle(lut,idx)&count_mask(n)
}

// Coefficients (iata11,-iata10,iata00,_) of the inverse normal matrix for the
// indices, and the lerp weight of each texel (0 past the subset).
@(private)
lls_coeffs :: proc "contextless" (indices:^[16]u8,in_:^Subset_Input,out_lerpf:^V16b,
    ib:int) -> [4]f32 {
    n:=in_.num_pixels
    lerpf:=lerp_weights16(indices,n,ib)
    out_lerpf^=lerpf
    idx:=intrinsics.unaligned_load((^V16b)(indices))
    first:=V16b(indices[0])
    if simd.reduce_or(simd.lanes_ne(idx,first)&count_mask(n))==0 {
        v:=in_.rcp_num_pixels*(1.0/64.0)
        return {v,v,v,v}
    }
    w0:=cast(V8s)simd.shuffle(lerpf,lerpf,0,1,2,3,4,5,6,7)
    w1:=cast(V8s)simd.shuffle(lerpf,lerpf,8,9,10,11,12,13,14,15)
    wsum:=i32(simd.reduce_add_ordered(cast(#simd[16]u32)lerpf))
    wsqsum:=simd.reduce_add_ordered(common.madd_i16(w0,w0)+common.madd_i16(w1,w1))
    sum_int:=[4]i32{wsqsum,wsqsum-64*wsum,wsqsum-128*wsum+4096*i32(n),wsqsum}
    sum_flt:[4]f32
    for k in 0..<4 {sum_flt[k]=f32(sum_int[k])*(1.0/64.0)}
    det:=sum_flt[0]*sum_flt[2]-sum_flt[1]*sum_flt[1]
    return {sum_flt[0]/det,sum_flt[1]/det,sum_flt[2]/det,sum_flt[3]/det}
}

@(private)
init_lsq_endpoints_cache :: proc "contextless" (cache:[^][4]f32,st:^Subset_State,in_:^Subset_Input,
    ib,ib2:int) {
    lerpf:V16b
    cache[0]=lls_coeffs(&st.idxs[st.isbit&1],in_,&lerpf,ib)
    if ib2!=0 {cache[1]=lls_coeffs(&st.idxs[(st.isbit&1)~1],in_,&lerpf,ib2)}
}

// Least-squares endpoints for the current indices into st.endpoints.
@(private)
refine_lsq_endpoints_core :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,ib,ib2:int,
    has_ib2:bool,cache:[^][4]f32=nil) #no_bounds_check {
    isbit:=int(st.isbit&1)
    n:=in_.num_pixels
    lerpf,lerpf_2:V16b
    iata,iata_2:[4]f32
    if cache==nil {
        iata=lls_coeffs(&st.idxs[isbit],in_,&lerpf,ib)
        if has_ib2 {iata_2=lls_coeffs(&st.idxs[isbit~1],in_,&lerpf_2,ib2)}
    } else {
        iata=cache[0]
        lerpf=lerp_weights16(&st.idxs[isbit],n,ib)
        if has_ib2 {
            iata_2=cache[1]
            lerpf_2=lerp_weights16(&st.idxs[isbit~1],n,ib2)
        }
    }
    bsum,atb:V4i
    for i:=0; i<n; i+=4 {
        px:=intrinsics.unaligned_load((^V16b)(&in_.pixels[i]))
        sel:=transmute(V16b)simd.lanes_lt(V16b{0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3},V16b(u8(n-i)))
        // R,R,R,R, G,G,G,G, B,B,B,B, A,A,A,A of the four texels.
        d:=simd.shuffle(px,px,0,4,8,12,1,5,9,13,2,6,10,14,3,7,11,15)&
            simd.shuffle(sel,sel,0,4,8,12,1,5,9,13,2,6,10,14,3,7,11,15)
        w:=simd.runtime_swizzle(lerpf,V16b{0,1,2,3,0,1,2,3,0,1,2,3,0,1,2,3}+V16b(u8(i)))
        if has_ib2 {
            w2:=simd.runtime_swizzle(lerpf_2,V16b{0,1,2,3,0,1,2,3,0,1,2,3,0,1,2,3}+V16b(u8(i)))
            w=simd.shuffle(w,w2,0,1,2,3,4,5,6,7,8,9,10,11,28,29,30,31)
        }
        bsum+=common.dot4_u8(d,V16b(64))
        atb+=common.dot4_u8(d,w)
    }
    c00:=V4f{iata[0],iata[0],iata[0],has_ib2 ? iata_2[0] : iata[0]}
    c01:=V4f{iata[1],iata[1],iata[1],has_ib2 ? iata_2[1] : iata[1]}
    c11:=V4f{iata[2],iata[2],iata[2],has_ib2 ? iata_2[2] : iata[2]}
    atb0:=vcvt(atb)
    atb1:=vcvt(bsum-atb)
    end0:=c00*atb1+c01*atb0
    end1:=c11*atb0+c01*atb1
    store_u8_endpoints(&st.endpoints,end0,end1)
}

@(private)
refine_lsq_endpoints_and_try :: proc "contextless" (cur_best,st:^Subset_State,in_:^Subset_Input,
    flags:Flags,
    $M:int) -> bool {
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    ISB :: MODE_ISB[M]
    ib,ib2:=IB,IB2
    if ISB!=0 && st.isbit!=0 {ib,ib2=ib2,ib}
    orig:=st.endpoints
    refine_lsq_endpoints_core(st,in_,ib,ib2,IB2!=0)
    if st.endpoints==orig {return false}
    return try_and_commit_partial(cur_best,st,in_,flags,-1,M)
}

@(private)
refine_subset_lsq_endpoints_iterated :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,
    flags:Flags,
    lsq_iters:int,$M:int) {
    nst:=st^
    for _ in 0..<lsq_iters {
        if !refine_lsq_endpoints_and_try(st,&nst,in_,flags,M) {break}
    }
}

@(private)
refine_lsq_endpoints_pass_m :: proc "contextless" (input:^Input,st:^Block_State,flags:Flags,
    lsq_iters:int,
    $M:int) {
    total:Error
    for s in 0..<MODE_NS[M] {
        refine_subset_lsq_endpoints_iterated(&st.subsets[s],&input.subsets[s],flags,lsq_iters,M)
        total+=st.subsets[s].err
    }
    st.err=total
}

@(private)
refine_lsq_endpoints_pass :: proc "contextless" (input:^Input,st:^Block_State,flags:Flags,
    lsq_iters:int) {
    switch st.mode {
    case 0: refine_lsq_endpoints_pass_m(input,st,flags,lsq_iters,0)
    case 1: refine_lsq_endpoints_pass_m(input,st,flags,lsq_iters,1)
    case 2: refine_lsq_endpoints_pass_m(input,st,flags,lsq_iters,2)
    case 3: refine_lsq_endpoints_pass_m(input,st,flags,lsq_iters,3)
    case 4: refine_lsq_endpoints_pass_m(input,st,flags,lsq_iters,4)
    case 5: refine_lsq_endpoints_pass_m(input,st,flags,lsq_iters,5)
    case 6: refine_lsq_endpoints_pass_m(input,st,flags,lsq_iters,6)
    case 7: refine_lsq_endpoints_pass_m(input,st,flags,lsq_iters,7)
    }
}

// cvtps2dq: nearest, ties to even; NaN and out of range give min(i32).
@(private)
round_to_int4 :: #force_inline proc "contextless" (x:V4f) -> V4i {
    return common.round_to_int4(x)
}

// cvtps2dq, packssdw, packuswb of lo and hi.
@(private)
store_u8_endpoints :: #force_inline proc "contextless" (out:^[2]Color,lo,hi:V4f) {
    l:=simd.clamp(round_to_int4(lo),V4i(0),V4i(255))
    h:=simd.clamp(round_to_int4(hi),V4i(0),V4i(255))
    out^=transmute([2]Color)cast(#simd[8]u8)simd.shuffle(l,h,0,1,2,3,4,5,6,7)
}

// Endpoints that move index 0 and the last index by adjust quantization steps.
@(private)
linear_transform_endpoints :: proc "contextless" (out:^[2]Color,initial:^[2]Color,adjust:[2]f32,
    ib:int) {
    wiggle:=bc67.LERP_FACTOR_4X[ib&7][1][3]
    sc:=1.0/(wiggle*(adjust[0]-adjust[1])-1.0)
    t0:=wiggle*adjust[0]*sc
    t1:=t0-sc
    c0:=V4i{i32(initial[0][0]),i32(initial[0][1]),i32(initial[0][2]),i32(initial[0][3])}
    c1:=V4i{i32(initial[1][0]),i32(initial[1][1]),i32(initial[1][2]),i32(initial[1][3])}
    base:=vcvt(c0)
    dir:=vcvt(c1-c0)
    store_u8_endpoints(out,base+V4f(t0)*dir,base+V4f(t1)*dir)
}

@(private)
try_linear_transforms :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,col0,col1:Color,
    flags:Flags,
    adjust:[][2]f32,$M:int) {
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    initial:=[2]Color{col0,col1}
    nst:=st^
    when IB2==0 {
        for a in adjust {
            linear_transform_endpoints(&nst.endpoints,&initial,a,st.isbit!=0 ? IB2 : IB)
            try_and_commit(st,&nst,in_,flags,-1,M)
        }
    } else {
        for a in adjust {
            temp:[2]Color
            linear_transform_endpoints(&nst.endpoints,&initial,a,st.isbit!=0 ? IB2 : IB)
            linear_transform_endpoints(&temp,&initial,a,st.isbit!=0 ? IB : IB2)
            merge_endpoints(&nst.endpoints,temp,ENDPOINTS_ALPHA)
            try_and_commit_partial(st,&nst,in_,flags,-1,M)
        }
    }
}

@(rodata)
@(private)
EXTRAPOLATE_ADJUST := [3][3][2]f32{
    {{1.0,-1.0},{1.0,0.0},{0.0,-1.0}},
    {{2.0,-2.0},{2.0,0.0},{0.0,-2.0}},
    {{2.0,-2.0},{2.0,0.0},{0.0,-2.0}},
}

// Endpoints that put col0 and col1 at inner interpolated points.
@(private)
try_extrapolated_fit :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,col0,col1:Color,
    flags:Flags,
    $M:int) {
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    ib:=st.isbit!=0 ? IB2 : IB
    try_linear_transforms(st,in_,col0,col1,flags,EXTRAPOLATE_ADJUST[(ib-2)%3][:],M)
}

@(private)
try_two_color_fit :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,col0,col1:Color,
    flags:Flags,
    $M:int) {
    nst:=st^
    nst.endpoints={col0,col1}
    try_and_commit_partial(st,&nst,in_,flags,-1,M)
    try_extrapolated_fit(st,in_,col0,col1,flags,M)
}

@(private)
refine_jitter_selectors :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,flags:Flags,
    iters:int,
    rand_seed:u64,$M:int) {
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    NUM_INDS :: 1+min(IB2,1)
    ib_masks:=[2]int{(1<<uint(IB))-1,(1<<uint(IB2))-1}
    JITTERS1 :: [8]int{-1,-1,-1,-1,1,1,1,1}
    JITTERS2 :: [8]int{-3,-2,-1,-1,1,1,2,3}
    jitters1:=JITTERS1
    jitters2:=JITTERS2
    rand_state:=rand_seed
    num_pixels:=u32(in_.num_pixels)
    for _ in 0..<iters {
        ni:=int(rand64(&rand_state)>>62)+1
        nst:=st^
        for n in 0..<NUM_INDS {
            ib_mask:=ib_masks[n]
            jitters:=ib_mask==3 ? &jitters1 : &jitters2
            r:=rand64(&rand_state)
            for _ in 0..<ni {
                i:=int((u32(r>>54)*num_pixels)>>10); r<<=10
                push:=jitters[r>>61]; r<<=3
                j:=int(nst.idxs[n][i&15])+push
                j=j<0 ? 0 : (j>ib_mask ? ib_mask : j)
                nst.idxs[n][i&15]=u8(j)
            }
        }
        refine_lsq_endpoints_and_try(st,&nst,in_,flags,M)
    }
}

@(private)
refine_brute_pbits :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,flags:Flags,$M:int) {
    EPB :: MODE_EPB[M]
    SPB :: MODE_SPB[M]
    flags:=flags
    when EPB+SPB==0 {
        if flags&BRUTE_PBITS_IDXS_EXACT!=0 {trial(st,in_,flags|IDXS_EXACT,0,M)}
    } else {
        if flags&BRUTE_PBITS_IDXS_EXACT!=0 {flags|=IDXS_EXACT}
        nst:=st^
        STEP :: 3-2*EPB
        for i:=0; i<4; i+=STEP {try_and_commit(st,&nst,in_,flags,i,M)}
    }
}

// Who re-evaluates a candidate of the annealing and greedy steps.
@(private)
Trial_Kind :: enum {Reindex, No_Reindex, Multi_Block}

Multiblock_Iter_Context :: struct {
    multi:^Multi_Blocks,
    subset:int,
    change_pbits:bool,
}

@(private)
iterative_trial :: #force_inline proc "contextless" (user:rawptr,st:^Subset_State,flags:Flags,
    $M:int,
    $KIND:Trial_Kind) {
    when KIND==.Reindex {
        trial(st,(^Subset_Input)(user),flags,-1,M)
    } else when KIND==.No_Reindex {
        update_subset_error(st,(^Subset_Input)(user),flags,int(st.pbits),M)
    } else {
        ctx:=(^Multiblock_Iter_Context)(user)
        multi:=ctx.multi
        s:=ctx.subset
        st.err=0
        st.scalar_err=0
        calc_endpoints_and_pbits(&st.endpoints_q,st,flags,ctx.change_pbits ? -1 : int(st.pbits),M)
        for i in 0..<len(multi.data) {
            bi:=&multi.data[i]
            local_scalar:Error
            local:=calc_subset_error(&bi.state.subsets[s],&bi.input.subsets[s],&st.endpoints_q,
                &local_scalar,M)
            st.err+=local
            st.scalar_err+=local_scalar
        }
    }
}

@(private)
refine_anneal_endpoints_core :: proc "contextless" (st:^Subset_State,flags:Flags,iters:int,
    rand_seed:u64,
    user:rawptr,$M:int,$KIND:Trial_Kind) {
    if st.err==0 || iters==0 {return}
    CB :: MODE_CB[M]
    AB :: MODE_AB[M]
    PBITS :: MODE_EPB[M]+MODE_SPB[M]
    CB_SHIFT :: max(0,8-(CB+PBITS))
    AB_SHIFT :: max(0,8-(AB+PBITS))
    MAX_STEP :: 1+PBITS
    shifts:=[4]uint{uint(CB_SHIFT),uint(CB_SHIFT),uint(CB_SHIFT),uint(AB_SHIFT)}
    current:=st^
    rand_state:=rand_seed
    START_TEMPERATURE :: f32(64.0)
    nc:=(flags&IGNORE_ALPHA!=0 || AB==0) ? 3 : 4
    for iter in 0..<iters {
        t:=f32(iter)/f32(iters)
        temperature_flt:=START_TEMPERATURE*(1.0-t)
        temperature:=int(temperature_flt)
        part:=current
        r:=rand64(&rand_state)
        c:=int(rand64_mod(r,u32(nc)))
        r<<=7
        start0:=int(part.endpoints[0][c])
        start1:=int(part.endpoints[1][c])
        e0,e1:int
        for {
            d0:=int(rand64_in_range(r,-i32(MAX_STEP),i32(MAX_STEP))); r<<=9
            d1:=int(rand64_in_range(r,-i32(MAX_STEP),i32(MAX_STEP))); r<<=9
            e0=clamp(start0+(d0<<shifts[c]),0,255)
            e1=clamp(start1+(d1<<shifts[c]),0,255)
            if e0==start0 && e1==start1 {
                r=rand64(&rand_state)
                continue
            }
            break
        }
        part.endpoints[0][c]=u8(e0)
        part.endpoints[1][c]=u8(e1)
        iterative_trial(user,&part,flags,M,KIND)
        derr:=int(i32(part.err-current.err))
        if derr>=temperature {continue}
        if derr<0 || (temperature>0 && int(rand64_mod(r,u32(temperature)))>=derr) {
            current=part
            if part.err<st.err {
                st^=part
                if st.err==0 {return}
            }
        }
    }
}

@(private)
refine_greedyoptimize_endpoints_core :: proc "contextless" (st:^Subset_State,flags:Flags,
    user:rawptr,$M:int,
    $KIND:Trial_Kind) {
    if st.err==0 {return}
    CB :: MODE_CB[M]
    AB :: MODE_AB[M]
    CB_SHIFT :: max(0,8-CB)
    AB_SHIFT :: max(0,8-AB)
    shifts:=[4]uint{uint(CB_SHIFT),uint(CB_SHIFT),uint(CB_SHIFT),uint(AB_SHIFT)}
    nc:=(flags&IGNORE_ALPHA!=0 || AB==0) ? 3 : 4
    for {
        cur:=st^
        did_anything:=false
        for c in 0..<nc {
            for ei in 0..<2 {
                start:=int(cur.endpoints[ei][c])
                for delta:=-1; delta<=1; delta+=2 {
                    wiggled:=start+(delta<<shifts[c])
                    if u32(wiggled)>255 {continue}
                    cur.endpoints[ei][c]=u8(wiggled)
                    iterative_trial(user,&cur,flags,M,KIND)
                    if cur.err<st.err {
                        st^=cur
                        if st.err==0 {return}
                        did_anything=true
                    }
                }
                cur.endpoints[ei][c]=u8(start)
            }
        }
        if !did_anything {break}
    }
}

@(private)
refine_anneal_endpoints :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,flags:Flags,
    iters:int,
    rand_seed:u64,no_reindex:bool,$M:int) {
    if no_reindex {
        if iters>0 {refine_anneal_endpoints_core(st,flags,iters,rand_seed,in_,M,.No_Reindex)}
        if iters>=100 || iters<0 {refine_greedyoptimize_endpoints_core(st,flags,in_,M,.No_Reindex)}
    } else {
        if iters>0 {refine_anneal_endpoints_core(st,flags,iters,rand_seed,in_,M,.Reindex)}
        if iters>=100 || iters<0 {refine_greedyoptimize_endpoints_core(st,flags,in_,M,.Reindex)}
    }
}

@(private)
refine_anneal_subset :: proc "contextless" (input:^Input,st:^Block_State,flags:Flags,iters:int,
    rand_seed:u64,
    no_reindex:bool,$M:int) {
    total:Error
    for s in 0..<MODE_NS[M] {
        sst:=&st.subsets[s]
        if sst.err!=0 {refine_anneal_endpoints(sst,&input.subsets[s],flags,iters,rand_seed,
            no_reindex,M)}
        total+=sst.err
    }
    st.err=total
}

@(rodata)
@(private)
SLIDE_ADJUST := [8][2]f32{
    {-0.15,-0.15},{0.00,-0.50},{0.15,-0.15},
    {-0.50,0.00},{0.50,0.00},
    {-0.15,0.15},{0.00,0.50},{0.15,0.15},
}

@(private)
refine_scale_selectors :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,flags:Flags,
    $M:int) {
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    NUM_INDS :: 1+min(IB2,1)
    nst:=st^
    orig:=st.idxs
    for variant in 0..<8 {
        for n in 0..<NUM_INDS {
            ib:=n!=0 ? IB2 : IB
            remap:=&bc67.INDEX_SQUISH_STRETCH[(ib-2)%3][variant]
            for i in 0..<16 {nst.idxs[n][i]=remap[orig[n][i]&15]}
        }
        refine_lsq_endpoints_and_try(st,&nst,in_,flags,M)
    }
}

// The endpoints along the subset's principal axis, from the subset analysis.
@(private)
initial_pca_core :: proc "contextless" (out:^[2]Color,st:^Subset_State,in_:^Subset_Input,prep:^Prep,
    has_ib2:bool,min_separation,min_separation_a:f32,
        scalar_opt:^[256]bc67.Optimal_Endpoint) -> bool {
    if st.pca_subset==0 || !prep.analysis_initialized {return false}
    ana:=&prep.analysis
    sub_id:=has_ib2 ? int(st.pca_subset)+int(st.rbit) : int(st.pca_subset)-1
    if sub_id<0 || sub_id>=ANALYSIS_STRIDE {return false}
    pca:=[4]f32{ana.storage[.Pca_R][sub_id],ana.storage[.Pca_G][sub_id],ana.storage[.Pca_B][sub_id],
        ana.storage[.Pca_A][sub_id]}
    mean:[4]f32
    min_dot:=max(f32)
    max_dot:=-max(f32)
    for i in 0..<in_.num_pixels {
        px:=in_.pixels[i]
        p:=[4]f32{f32(px[0]),f32(px[1]),f32(px[2]),f32(px[3])}
        for c in 0..<4 {mean[c]+=p[c]}
        dot:=(p[0]*pca[0]+p[2]*pca[2])+(p[1]*pca[1]+p[3]*pca[3])
        min_dot=minps(min_dot,dot)
        max_dot=maxps(max_dot,dot)
    }
    for c in 0..<4 {mean[c]*=in_.rcp_num_pixels}
    center:=(mean[0]*pca[0]+mean[2]*pca[2])+(mean[1]*pca[1]+mean[3]*pca[3])
    min_dot-=center
    max_dot-=center
    mean_a:=mean[3]
    SHRINK :: f32(1.0/64.0)
    smin,smax:f32
    if max_dot-min_dot<=min_separation {
        avg:=0.5*(min_dot+max_dot)
        smin=avg-min_separation*0.5
        smax=avg+min_separation*0.5
    } else {
        shrink:=(max_dot-min_dot)*SHRINK
        smin=min_dot+shrink
        smax=max_dot-shrink
    }
    vmean:=transmute(V4f)mean
    vpca:=transmute(V4f)pca
    store_u8_endpoints(out,vmean+vpca*V4f(smin),vmean+vpca*V4f(smax))
    if has_ib2 {
        alpha_chan:=(int(st.rbit)-1)&3
        a0:=prep.info_1sub.bbox[0][0][alpha_chan]
        a1:=prep.info_1sub.bbox[0][1][alpha_chan]
        if a0==a1 {
            out[0][3]=scalar_opt[a0].lo
            out[1][3]=scalar_opt[a0].hi
        } else {
            min_a:=f32(a0)-mean_a
            max_a:=f32(a1)-mean_a
            smin_a,smax_a:f32
            if max_a-min_a<=min_separation_a {
                avg:=0.5*(min_a+max_a)
                smin_a=avg-min_separation_a*0.5
                smax_a=avg+min_separation_a*0.5
            } else {
                shrink_a:=(max_a-min_a)*SHRINK
                smin_a=min_a+shrink_a
                smax_a=max_a-shrink_a
            }
            out[0][3]=round_and_clamp_u8(mean_a+smin_a)
            out[1][3]=round_and_clamp_u8(mean_a+smax_a)
        }
    }
    return true
}

// Stretched variants of the principal-axis fit; returns how many it wrote.
@(private)
refine_pca_core :: proc "contextless" (out:[][2]Color,st:^Subset_State,in_:^Subset_Input,
    flags:Flags,
    opt:^Enc_Options,prep:^Prep,has_ib2:bool) -> int {
    if len(out)==0 || st.pca_subset==0 || !prep.analysis_initialized {return 0}
    ana:=&prep.analysis
    sub_id:=has_ib2 ? int(st.pca_subset)+int(st.rbit) : int(st.pca_subset)-1
    if sub_id<0 || sub_id>=ANALYSIS_STRIDE {return 0}
    pca:=[4]f32{ana.storage[.Pca_R][sub_id],ana.storage[.Pca_G][sub_id],ana.storage[.Pca_B][sub_id],
        ana.storage[.Pca_A][sub_id]}
    vsum:[4]i32
    for i in 0..<in_.num_pixels {
        for c in 0..<4 {vsum[c]+=i32(in_.pixels[i][c])}
    }
    mean:[4]f32
    for c in 0..<4 {mean[c]=f32(vsum[c])*in_.rcp_num_pixels}
    pe:=ana.storage[.Pca_Err][sub_id]
    sum_sqr:=[4]f32{pe,pe,pe,pe}
    if has_ib2 {
        id0:=int(st.pca_subset)-1
        if id0>=0 {sum_sqr[3]=ana.storage[.Overall_Err][id0]-ana.storage[.Overall_Err][sub_id]}
    }
    count:=0
    if flags&PCA_STRETCH!=0 {
        num_passes:=opt.max_pca_stretch_passes
        scaled:[4]f32
        for c in 0..<4 {scaled[c]=math.sqrt(sum_sqr[c]*in_.rcp_num_pixels)*pca[c]}
        BASE :: f32(1.50)
        step:=1.0/(f32(num_passes)-1.0)
        for pass in 0..<num_passes {
            spread:=BASE+f32(pass)*step
            delta:=V4f(spread)*transmute(V4f)scaled
            store_u8_endpoints(&out[count],transmute(V4f)mean-delta,transmute(V4f)mean+delta)
            count+=1
            if count==len(out) {return count}
        }
    }
    return count
}

@(private)
initial_pca_endpoints :: proc "contextless" (results:^[2]Color,st:^Subset_State,in_:^Subset_Input,
    prep:^Prep,$M:int) -> bool {
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    CB :: MODE_CB[M]
    AB :: MODE_AB[M]
    ib1:=(IB2>0 && st.isbit!=0) ? IB2 : IB
    ib2:=(IB2>0 && st.isbit==0) ? IB2 : IB
    a:=255.0/(f32(int(1)<<uint(CB))-1.0)
    b:=f32(int(1)<<uint(ib1))-1.0
    min_sep:=a>b ? a : b
    a=255.0/(f32(int(1)<<uint(max(AB,2)))-1.0)
    b=f32(int(1)<<uint(ib2))-1.0
    min_sep_a:=a>b ? a : b
    scalar_opt:^[256]bc67.Optimal_Endpoint
    when IB2>0 {
        when M==4 {
            scalar_opt=&bc67.BC7_SCALAR_OPTIMAL_ENDPOINTS[st.isbit!=0 ? 1 : 0]
        } else {
            scalar_opt=&bc67.BC7_SCALAR_OPTIMAL_ENDPOINTS[2]
        }
    }
    return initial_pca_core(results,st,in_,prep,IB2!=0,min_sep,min_sep_a,scalar_opt)
}

@(private)
initial_pca :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,flags:Flags,prep:^Prep,
    $M:int) {
    results:[2]Color
    if !initial_pca_endpoints(&results,st,in_,prep,M) {return}
    nst:=st^
    nst.endpoints=results
    try_and_commit_partial(st,&nst,in_,flags,-1,M)
}

@(private)
refine_pca :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,flags:Flags,opt:^Enc_Options,
    prep:^Prep,$M:int) {
    results:[80][2]Color
    count:=initial_pca_endpoints(&results[0],st,in_,prep,M) ? 1 : 0
    if flags&PCA_STRETCH!=0 {
        count+=refine_pca_core(results[count:],st,in_,flags,opt,prep,MODE_IB2[M]!=0)
    }
    if count==0 {return}
    nst:=st^
    if flags&PCA_TRY_HARD!=0 {
        for i in 0..<count {
            temp:Subset_State
            subset_init_empty(&temp,st.isbit,st.rbit)
            temp.endpoints=st.endpoints
            try_two_color_fit(&temp,in_,results[i][0],results[i][1],flags,M)
            if temp.err<st.err {st^=temp}
            refine_lsq_endpoints_and_try(st,&temp,in_,flags,M)
        }
    } else {
        try_two_color_fit(st,in_,results[0][0],results[0][1],flags,M)
        for i in 1..<count {
            nst.endpoints=results[i]
            try_and_commit_partial(st,&nst,in_,flags,-1,M)
        }
    }
}

// The heaviest refinement, on the few remaining candidates.
@(private)
refine_mode :: proc "contextless" (block:^[16]Color,st:^Block_State,flags:Flags,optiters:[2]int,
    opt:^Enc_Options,prep:^Prep,$M:int) {
    NS :: MODE_NS[M]
    p:=int(st.p&63)
    block_in:Block_Input
    block_input_init(&block_in,block,bc67.SUBSET_TO_INDS[NS-1][p],int(st.subsets[0].rbit))
    total_err:Error
    total_pixels:=0
    for s in 0..<NS {
        sst:=&st.subsets[s]
        num:=int(bc67.NUM_PIXELS_PER_SUBSET[NS][p][s])
        if sst.err!=0 {
            input:Subset_Input
            subset_input_init(&input,raw_data(block_in.pixels[total_pixels:]),num,
                alpha_chan_index(int(sst.rbit)),opt.alpha_weight)
            if flags&ALL_PCA!=0 {refine_pca(sst,&input,flags,opt,prep,M)}
            if flags&SLIDE_SELECTORS!=0 {
                try_linear_transforms(sst,&input,sst.endpoints[0],sst.endpoints[1],flags,
                    SLIDE_ADJUST[:],M)
            }
            if flags&EXTRAPOLATE_SELECTORS!=0 {
                try_extrapolated_fit(sst,&input,sst.endpoints[0],sst.endpoints[1],flags,M)
            }
            if flags&SCALE_SELECTORS!=0 {refine_scale_selectors(sst,&input,flags,M)}
            if flags&LSQ_FIT!=0 {refine_subset_lsq_endpoints_iterated(sst,&input,flags,
                opt.max_lsq_iter,M)}
            if flags&JITTER_SELECTORS!=0 && optiters[0]>0 {
                refine_jitter_selectors(sst,&input,flags,optiters[0],
                    prep.rand_seed+u64(s)*0xBF58476D1CE4E5B9,M)
            }
            if flags&ANNEAL_ENDPOINTS!=0 && optiters[1]>0 {
                refine_anneal_endpoints(sst,&input,flags,optiters[1],
                    prep.rand_seed+u64(s+7)*0xBF58476D1CE4E5B9,false,M)
            }
            if flags&BRUTE_PBITS!=0 {refine_brute_pbits(sst,&input,flags,M)}
        }
        total_err+=sst.err
        total_pixels+=num
    }
    st.err=total_err
}

@(private)
refine :: proc "contextless" (block:^[16]Color,st:^Block_State,flags:Flags,optiters:[2]int,
    opt:^Enc_Options,prep:^Prep) {
    switch st.mode {
    case 0: refine_mode(block,st,flags,optiters,opt,prep,0)
    case 1: refine_mode(block,st,flags,optiters,opt,prep,1)
    case 2: refine_mode(block,st,flags,optiters,opt,prep,2)
    case 3: refine_mode(block,st,flags,optiters,opt,prep,3)
    case 4: refine_mode(block,st,flags,optiters,opt,prep,4)
    case 5: refine_mode(block,st,flags,optiters,opt,prep,5)
    case 6: refine_mode(block,st,flags,optiters,opt,prep,6)
    case 7: refine_mode(block,st,flags,optiters,opt,prep,7)
    }
}
