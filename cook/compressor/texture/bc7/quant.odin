package bc7

import "base:intrinsics"
import "core:simd"
import "mirai:cook/compressor/texture/bc67"
import "mirai:cook/compressor/texture/common"

// Endpoint quantization, index search, errors and decoding of one subset,
// specialized per mode M.

// The channel the alpha of the source ends up in after rotation rbit.
@(private)
alpha_chan_index :: #force_inline proc "contextless" (rbit:int) -> int {return (3+rbit)&3}

// Quantizes st.endpoints for mode M into endpoints_q and returns the pbits:
// the given ones, or the best ones when pbits is -1.
@(private)
calc_endpoints_and_pbits :: #force_inline proc "contextless" (endpoints_q:^[2]Color,
    st:^Subset_State,
    flags:Flags,pbits:int,$M:int) -> u8 {
    CB :: MODE_CB[M]
    AB :: MODE_AB[M]
    EPB :: MODE_EPB[M]
    SPB :: MODE_SPB[M]
    RB :: MODE_RB[M]
    pbits:=pbits
    _=pbits
    result:u8
    endpoints:=st.endpoints
    when AB>0 {
        if flags&PRESERVE_EXTREMES!=0 {
            when EPB!=0 {
                if flags&PRESERVE_A0!=0 {
                    endpoints[0][3]=0; endpoints[1][3]=0
                    pbits=0
                } else {
                    endpoints[0][3]=255; endpoints[1][3]=255
                    pbits=3
                }
            } else {
                lo_ind:=endpoints[0][3]<=endpoints[1][3] ? 0 : 1
                if flags&AEP0_CONSTRAINED!=0 {lo_ind=flags&AEP0_LO!=0 ? 0 : 1}
                if flags&PRESERVE_A0!=0 {endpoints[lo_ind][3]=0}
                if flags&PRESERVE_A255!=0 {endpoints[1-lo_ind][3]=255}
            }
        }
    }
    rbit:=RB!=0 ? int(st.rbit) : 0
    U :: #simd[8]u16
    W :: #simd[8]u32
    mulhi :: #force_inline proc "contextless" (a,b:U) -> U {
        return cast(U)simd.shr(cast(W)a*cast(W)b,W(16))
    }
    e16:=cast(U)transmute(#simd[8]u8)endpoints
    ignore:U
    if AB==0 || flags&IGNORE_ALPHA!=0 {
        ch:=u16((rbit+3)&3)
        ignore=transmute(U)simd.lanes_eq(U{0,1,2,3,0,1,2,3},U(ch))&U(0xff)
    }
    RECIP :: U(0x8081)
    out:U
    when EPB+SPB!=0 {
        CPB :: u16(256>>uint(CB+1))
        APB :: u16(256>>uint(AB+1))
        QC :: u16((2<<uint(CB))-1)
        QA :: u16((2<<uint(AB))-1)
        DC :: u16(((0x10000>>uint(CB))+(0x10000>>uint(2*CB+1)))&0xffff)
        DA :: u16((((0x10000>>uint(AB))+(0x10000>>uint(2*AB+1)))&0xffff)*min(AB,1))
        p1:=e16*U{QC,QC,QC,QA,QC,QC,QC,QA}
        p0:=p1+U(254)
        ds:=U{DC,DC,DC,DA,DC,DC,DC,DA}
        d0:=mulhi(mulhi(p0,RECIP)&U(0xff00),ds)|ignore
        d1:=mulhi(mulhi(p1,RECIP)&U(0xff00),ds)|U{CPB,CPB,CPB,APB,CPB,CPB,CPB,APB}|ignore
        use:[2]bool
        if pbits==-1 {
            x0:=transmute(V8s)(d0-e16)
            x1:=transmute(V8s)(d1-e16)
            s0:=simd.to_array(common.madd_i16(x0,x0))
            s1:=simd.to_array(common.madd_i16(x1,x1))
            sq0:=[2]i32{s0[0]+s0[1],s0[2]+s0[3]}
            sq1:=[2]i32{s1[0]+s1[1],s1[2]+s1[3]}
            when SPB!=0 {
                t0:=sq0[0]+sq0[1]; t1:=sq1[0]+sq1[1]
                sq0={t0,t0}; sq1={t1,t1}
            }
            use={sq0[0]>sq1[0],sq0[1]>sq1[1]}
            result=u8(int(use[0]))|u8(int(use[1]))<<1
        } else {
            result=u8(pbits)
            use={pbits&1!=0,pbits&2!=0}
        }
        sel:=transmute(U)#simd[8]i16{i16(use[0]) * -1,i16(use[0]) * -1,i16(use[0]) * -1,
            i16(use[0]) * -1,i16(use[1]) * -1,i16(use[1]) * -1,i16(use[1]) * -1,i16(use[1]) * -1}
        out=(d1&sel)|(d0&~sel)
    } else {
        QC :: u16((1<<uint(CB))-1)
        QA :: u16((1<<uint(AB))-1)
        DC :: u16(((0x20000>>uint(CB))+(0x20000>>uint(2*CB)))&0xffff)
        DA :: u16((((0x20000>>uint(AB))+(0x20000>>uint(2*AB)))&0xffff)*min(AB,1))
        pre:=e16*U{QC,QC,QC,QA,QC,QC,QC,QA}+U(128)
        out=mulhi(mulhi(pre,RECIP)&U(0xff80),U{DC,DC,DC,DA,DC,DC,DC,DA})|ignore
    }
    o:=simd.clamp(transmute(#simd[8]i16)out,0,255)
    endpoints_q^=transmute([2]Color)cast(#simd[8]u8)o
    return result
}

// lo + round(w*(hi-lo)/64), the BC7 interpolation.
@(private)
lerp_u8 :: #force_inline proc "contextless" (lo,hi:u8,w:int) -> int {
    return int(lo)+((w*(int(hi)-int(lo))+32)>>6)
}

// Exact indices of the scalar (A) channel of a 16-texel subset, weighted.
@(private)
calc_scalar_inds_exact :: proc "contextless" (inds:^[16]u8,in_:^Subset_Input,ep:^[2]Color,
    $IB:int) -> Error #no_bounds_check {
    NUM_LERP :: 1<<uint(IB)
    colors:[NUM_LERP]int
    for j in 0..<NUM_LERP {colors[j]=lerp_u8(ep[0][3],ep[1][3],lerp_factor(IB,j))}
    sum:i32
    for i in 0..<16 {
        a:=int(in_.pixels[i][3])
        best:=0xff00
        for j in 0..<NUM_LERP {
            d:=(abs(colors[j]-a)<<8)|j
            if d<best {best=d}
        }
        inds[i]=u8(best&0xf)
        e:=i32(best>>8)
        sum+=e*e
    }
    return Error(sum)*Error(in_.channel_weights[3])
}

@(private)
calc_indexes_exact :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,$M:int) {
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    ISB :: MODE_ISB[M]
    when IB2==0 {
        st.err=calc_vector_inds_exact(&st.idxs[0],in_,&st.endpoints_q,IB,4)
        st.scalar_err=0
    } else {
        vec_err,scalar_err:Error
        if ISB==0 || st.isbit==0 {
            vec_err=calc_vector_inds_exact(&st.idxs[0],in_,&st.endpoints_q,IB,3)
            scalar_err=calc_scalar_inds_exact(&st.idxs[1],in_,&st.endpoints_q,IB2)
        } else {
            vec_err=calc_vector_inds_exact(&st.idxs[1],in_,&st.endpoints_q,IB2,3)
            scalar_err=calc_scalar_inds_exact(&st.idxs[0],in_,&st.endpoints_q,IB)
        }
        st.err=vec_err+scalar_err
        st.scalar_err=scalar_err
    }
}

// Lanes of the four texels from i that are inside the subset.
@(private)
lane_mask :: #force_inline proc "contextless" (i,n:int) -> V4i {
    LANES :: V4i{0,1,2,3}
    return transmute(V4i)simd.lanes_lt(LANES+V4i(i32(i)),V4i(i32(n)))
}

// Exact vector indices of the IB-bit index set over NC channels (3 leaves A
// out). Writes indices up to the next multiple of 4 texels.
@(private)
calc_vector_inds_exact :: proc "contextless" (inds:^[16]u8,in_:^Subset_Input,ep:^[2]Color,
    $IB:int,$NC:int) -> Error #no_bounds_check {
    NUM_LERP :: 1<<uint(IB)
    // The palette and the texels in 16 bits, the weighted squares summed with pmaddwd as the
    // reference SSE4 kernel does.
    e:=cast(V8s)transmute(#simd[8]u8)ep^
    lo:=simd.shuffle(e,e,0,1,2,3,0,1,2,3)
    d:=simd.shuffle(e,e,4,5,6,7,4,5,6,7)-lo
    U8h :: #simd[8]u16
    colors:[NUM_LERP]V8s
    for j in 0..<NUM_LERP {
        colors[j]=lo+simd.shr(V8s(i16(lerp_factor(IB,j)))*d+V8s(32),U8h(6))
    }
    w:=in_.channel_weights
    cw:=V8s{i16(w[0]),i16(w[1]),i16(w[2]),i16(w[3]),i16(w[0]),i16(w[1]),i16(w[2]),i16(w[3])}
    when NC==3 {cw&=V8s{-1,-1,-1,0,-1,-1,-1,0}}
    sum:V4u
    n:=in_.num_pixels
    for i:=0; i<n; i+=4 {
        p01,p23:=texels4(in_.pixels,i)
        best:=V4u(0xfffffff0)
        for j in 0..<NUM_LERP {
            d01:=colors[j]-p01
            d23:=colors[j]-p23
            dots:=dot4(d01,d23,d01*cw,d23*cw)
            e:=simd.shl(transmute(V4u)dots,V4u(4))+V4u(u32(j))
            best=simd.min(best,e)
        }
        b:=simd.to_array(best)
        for k in 0..<4 {inds[i+k]=u8(b[k]&0xf)}
        sum+=simd.shr(best,V4u(4))&transmute(V4u)lane_mask(i,n)
    }
    return simd.reduce_add_ordered(sum)
}

// The BC7 weights of the indices times -2, as bytes: lerp factors of the 16-bit kernels,
// which interpolate as rounding_shift_right(-(w<<9)*(lo-hi),15)+lo.
@(private,rodata)
LERP_NEG2X := [5][16]i8{
    {},{},{0,-42,-86,-128,0,0,0,0,0,0,0,0,0,0,0,0},{0,-18,-36,-54,-74,-92,-110,-128,0,0,0,0,0,0,0,0},
    {0,-8,-18,-26,-34,-42,-52,-60,-68,-76,-86,-94,-102,-110,-120,-128},
}

@(private)
V16b :: #simd[16]u8
@(private)
V8s :: #simd[8]i16

// The four channels of texels i..i+3 in 16-bit lanes: i and i+1, then i+2 and i+3.
@(private)
texels4 :: #force_inline proc "contextless" (p:[^]Color,i:int) -> (a,b:V8s) {
    v:=intrinsics.unaligned_load((^V16b)(&p[i]))
    a=cast(V8s)simd.shuffle(v,v,0,1,2,3,4,5,6,7)
    b=cast(V8s)simd.shuffle(v,v,8,9,10,11,12,13,14,15)
    return
}

// The endpoints as lanes lo,lo and hi,hi.
@(private)
endpoints16 :: #force_inline proc "contextless" (ep:^[2]Color) -> (lo,hi:V8s) {
    e:=cast(V8s)transmute(#simd[8]u8)ep^
    return simd.shuffle(e,e,0,1,2,3,0,1,2,3),simd.shuffle(e,e,4,5,6,7,4,5,6,7)
}

// The dot products of four texels (a0: texels 0 and 1, a1: 2 and 3) with b0 and b1.
@(private)
dot4 :: #force_inline proc "contextless" (a0,a1,b0,b1:V8s) -> V4i {
    return common.hadd_i32(common.madd_i16(a0,b0),common.madd_i16(a1,b1))
}

// The lerp factors of four texels whose indices are the lanes of q, each for the four
// channels of its texel.
@(private)
lerpf4 :: #force_inline proc "contextless" (tab:V16b,q:V4u) -> (l0,l1:V8s) {
    // Bytes 1..3 of each lane index entry 0, which is 0.
    w:=simd.runtime_swizzle(tab,transmute(V16b)q)
    l0=transmute(V8s)simd.shuffle(w,w,1,0,1,0,1,0,1,0,1,4,1,4,1,4,1,4)
    l1=transmute(V8s)simd.shuffle(w,w,1,8,1,8,1,8,1,8,1,12,1,12,1,12,1,12)
    return
}

@(private)
interp16 :: #force_inline proc "contextless" (lerpf,diff,base:V8s) -> V8s {
    return common.mulhrs_i16(lerpf,diff)+base
}

// Linear index estimate of the vector channels (NC of them, 3 leaves A out) with IB index
// bits; writes indices up to the next multiple of 4 texels.
@(private)
vector_inds_linear_128 :: #force_no_inline proc "contextless" (out_inds:^[16]u8,in_:^Subset_Input,ep:^[2]Color,
    n:int,$IB:int,$NC:int) -> Error #no_bounds_check {
    tab:=transmute(V16b)LERP_NEG2X[IB]
    index_scale:=f32((int(1)<<uint(IB))-1)
    w:=in_.channel_weights
    cw:=V8s{i16(w[0]),i16(w[1]),i16(w[2]),i16(w[3]),i16(w[0]),i16(w[1]),i16(w[2]),i16(w[3])}
    when NC==3 {cw&=V8s{-1,-1,-1,0,-1,-1,-1,0}}
    lo,hi:=endpoints16(ep)
    diff:=lo-hi
    diffw:=diff*cw
    d:=simd.to_array(common.madd_i16(diff,diffw))
    scalef:=V4f(index_scale/f32(d[0]+d[1]))
    vmaxq:=V4f(index_scale)
    total:V4i
    for i:=0; i<n; i+=4 {
        p0,p1:=texels4(in_.pixels,i)
        rel0:=lo-p0
        rel1:=lo-p1
        qf:=vcvt(dot4(rel0,rel1,diffw,diffw))*scalef
        qf=simd.select(simd.lanes_gt(qf,V4f(0)),qf,V4f(0))
        qf=simd.select(simd.lanes_lt(qf,vmaxq),qf,vmaxq)
        q:=transmute(V4u)common.round_to_int4(qf)
        qb:=transmute(V16b)q
        intrinsics.unaligned_store((^#simd[4]u8)(&out_inds[i]),simd.shuffle(qb,qb,0,4,8,12))
        l0,l1:=lerpf4(tab,q)
        e0:=interp16(l0,diff,rel0)
        e1:=interp16(l1,diff,rel1)
        s:=dot4(e0,e1,e0*cw,e1*cw)
        if i+4>n {s&=lane_mask(i,n)}
        total+=s
    }
    return Error(simd.reduce_add_ordered(total))
}

@(private)
calc_indexes_linear_approx :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,$M:int) {
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    ISB :: MODE_ISB[M]
    when IB2==0 {
        st.err=calc_vector_inds_linear(&st.idxs[0],in_,&st.endpoints_q,in_.num_pixels,IB,4)
        st.scalar_err=0
    } else {
        vec_err,scalar_err:Error
        if ISB!=0 && st.isbit!=0 {
            vec_err,scalar_err=calc_twoindex_linear(&st.idxs[1],&st.idxs[0],in_,&st.endpoints_q,
                IB2,IB)
        } else {
            vec_err,scalar_err=calc_twoindex_linear(&st.idxs[0],&st.idxs[1],in_,&st.endpoints_q,
                IB,IB2)
        }
        st.err=vec_err+scalar_err
        st.scalar_err=scalar_err
    }
}

// The vector indices of a 16-texel subset with IBV bits and the scalar (A) ones with IBS bits;
// returns the vector error and the weighted scalar one.
@(private)
twoindex_linear_128 :: #force_no_inline proc "contextless" (idx_v,idx_s:^[16]u8,in_:^Subset_Input,
    ep:^[2]Color,$IBV,$IBS:int) -> (vec_err,scalar_err:Error) {
    vec_err=vector_inds_linear_128(idx_v,in_,ep,16,IBV,3)
    lo:=i32(ep[0][3])
    diff:=lo-i32(ep[1][3])
    // The 16-bit scalar kernel: the alphas relative to lo, two vectors of eight.
    a:=transmute([4]V16b)(^[16]Color)(in_.pixels)^
    al:=simd.shuffle(a[0],a[1],3,7,11,15,19,23,27,31,3,7,11,15,19,23,27,31)
    ah:=simd.shuffle(a[2],a[3],3,7,11,15,19,23,27,31,3,7,11,15,19,23,27,31)
    rel:=[2]V8s{V8s(i16(lo))-cast(V8s)simd.shuffle(al,al,0,1,2,3,4,5,6,7),
        V8s(i16(lo))-cast(V8s)simd.shuffle(ah,ah,0,1,2,3,4,5,6,7)}
    sumv:V4i
    if diff!=0 {
        scalef:=V4f(f32((int(1)<<uint(IBS))-1)/f32(diff))
        maxq:=V4i(i32((1<<uint(IBS))-1))
        qs:[16]u8
        for i:=0; i<16; i+=4 {
            halves:=transmute([2]#simd[4]i16)rel[i>>3]
            rq:=cast(V4i)halves[(i>>2)&1]
            q:=simd.min(simd.clamp(round_to_int4(vcvt(rq)*scalef),V4i(0),V4i(255)),maxq)
            qb:=transmute(V16b)q
            (^#simd[4]u8)(&qs[i])^=simd.shuffle(qb,qb,0,4,8,12)
        }
        idx_s^=qs
        w:=simd.runtime_swizzle(transmute(V16b)LERP_NEG2X[IBS],transmute(V16b)qs)
        d:=V8s(i16(diff))
        for h in 0..<2 {
            var:V16b
            if h==0 {
                var=simd.shuffle(w,w,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7)
            } else {
                var=simd.shuffle(w,w,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15)
            }
            e:=common.mulhrs_i16(transmute(V8s)var&V8s(-256),d)+rel[h]
            sumv+=common.madd_i16(e,e)
        }
    } else {
        for h in 0..<2 {sumv+=common.madd_i16(rel[h],rel[h])}
        idx_s^={}
    }
    scalar_err=Error(simd.reduce_add_ordered(sumv))*Error(in_.channel_weights[3])
    return
}

// The weighted error of the vector channels (3 leaves A out) with the given indices.
@(private)
vector_err_128 :: #force_no_inline proc "contextless" (inds:^[16]u8,in_:^Subset_Input,ep:^[2]Color,
    $IB:int,$NC:int) -> Error #no_bounds_check {
    tab:=transmute(V16b)LERP_NEG2X[IB]
    w:=in_.channel_weights
    cw:=V8s{i16(w[0]),i16(w[1]),i16(w[2]),i16(w[3]),i16(w[0]),i16(w[1]),i16(w[2]),i16(w[3])}
    when NC==3 {cw&=V8s{-1,-1,-1,0,-1,-1,-1,0}}
    lo,hi:=endpoints16(ep)
    diff:=lo-hi
    n:=in_.num_pixels
    total:V4i
    for i:=0; i<n; i+=4 {
        p0,p1:=texels4(in_.pixels,i)
        q:=cast(V4u)intrinsics.unaligned_load((^#simd[4]u8)(&inds[i]))
        l0,l1:=lerpf4(tab,q)
        e0:=interp16(l0,diff,lo-p0)
        e1:=interp16(l1,diff,lo-p1)
        s:=dot4(e0,e1,e0*cw,e1*cw)
        if i+4>n {s&=lane_mask(i,n)}
        total+=s
    }
    return Error(simd.reduce_add_ordered(total))
}

// The weighted error of the scalar channel A of a 16-texel subset with the given indices.
@(private)
calc_scalar_err :: #force_inline proc "contextless" (inds:^[16]u8,in_:^Subset_Input,ep:^[2]Color,
    $IB:int) -> Error #no_bounds_check {
    tab:=transmute(V16b)LERP_NEG2X[IB]
    lo:=V8s(i16(ep[0][3]))
    diff:=V8s(i16(ep[0][3])-i16(ep[1][3]))
    l:=simd.runtime_swizzle(tab,intrinsics.unaligned_load((^V16b)(inds)))
    total:V4i
    for h in 0..<2 {
        a:=intrinsics.unaligned_load((^V16b)(&in_.pixels[h*8]))
        b:=intrinsics.unaligned_load((^V16b)(&in_.pixels[h*8+4]))
        // The alphas of texels 8h..8h+7.
        px:=cast(V8s)simd.shuffle(a,b,3,7,11,15,19,23,27,31)
        lerpf:V8s
        if h==0 {
            lerpf=transmute(V8s)simd.shuffle(l,V16b{},16,0,16,1,16,2,16,3,16,4,16,5,16,6,16,7)
        } else {
            lerpf=transmute(V8s)simd.shuffle(l,V16b{},16,8,16,9,16,10,16,11,16,12,16,13,16,14,16,
                15)
        }
        e:=interp16(lerpf,diff,lo-px)
        total+=common.madd_i16(e,e)
    }
    return Error(simd.reduce_add_ordered(total))*Error(in_.channel_weights[3])
}

// Error of the current indices with the given quantized endpoints.
@(private)
calc_subset_error :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,ep:^[2]Color,
    out_scalar_err:^Error,$M:int) -> Error {
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    ISB :: MODE_ISB[M]
    isbit:=ISB!=0 ? int(st.isbit) : 0
    vec:Error
    scalar:Error
    when IB2==0 {
        vec=calc_vector_err(&st.idxs[0],in_,ep,IB,4)
    } else {
        if isbit!=0 {
            vec=calc_vector_err(&st.idxs[1],in_,ep,IB2,3)
            scalar=calc_scalar_err(&st.idxs[0],in_,ep,IB)
        } else {
            vec=calc_vector_err(&st.idxs[0],in_,ep,IB,3)
            scalar=calc_scalar_err(&st.idxs[1],in_,ep,IB2)
        }
    }
    if out_scalar_err!=nil {out_scalar_err^=scalar}
    return vec+scalar
}

// Decodes num_pixels texels of a subset in subset order.
@(private)
decode_subset :: proc "contextless" (out:^[16]Color,st:^Subset_State,num_pixels:int,
    $M:int) #no_bounds_check {
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    ISB :: MODE_ISB[M]
    isbit:=ISB!=0 ? int(st.isbit) : 0
    lo,hi:=endpoints16(&st.endpoints_q)
    diff:=lo-hi
    when IB2==0 {
        tab:=transmute(V16b)LERP_NEG2X[IB]
        for i:=0; i<num_pixels; i+=4 {
            q:=cast(V4u)intrinsics.unaligned_load((^#simd[4]u8)(&st.idxs[0][i]))
            l0,l1:=lerpf4(tab,q)
            v:=transmute([16]u8)cast(V16b)simd.shuffle(interp16(l0,diff,lo),interp16(l1,diff,lo),
                0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15)
            for k in 0..<min(4,num_pixels-i) {out[i+k]=(^Color)(&v[k*4])^}
        }
    } else {
        ibv:=isbit!=0 ? IB2 : IB
        ibs:=isbit!=0 ? IB : IB2
        tv:=transmute(V16b)LERP_NEG2X[ibv]
        ts:=transmute(V16b)LERP_NEG2X[ibs]
        for i:=0; i<16; i+=4 {
            qv:=cast(V4u)intrinsics.unaligned_load((^#simd[4]u8)(&st.idxs[isbit][i]))
            qs:=cast(V4u)intrinsics.unaligned_load((^#simd[4]u8)(&st.idxs[isbit~1][i]))
            wv:=simd.runtime_swizzle(tv,transmute(V16b)qv)
            ws:=simd.runtime_swizzle(ts,transmute(V16b)qs)
            // Bytes 1..3 of each lane of wv are 0; the scalar weights go to byte 3.
            w:=simd.shuffle(wv,ws,0,0,0,16,4,4,4,20,8,8,8,24,12,12,12,28)
            l0:=transmute(V8s)simd.shuffle(w,wv,17,0,17,1,17,2,17,3,17,4,17,5,17,6,17,7)
            l1:=transmute(V8s)simd.shuffle(w,wv,17,8,17,9,17,10,17,11,17,12,17,13,17,14,17,15)
            v:=transmute([4]Color)cast(V16b)simd.shuffle(interp16(l0,diff,lo),interp16(l1,diff,lo),
                0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15)
            for k in 0..<4 {out[i+k]=v[k]}
        }
    }
}

// Clamps the anchor index of the subset to the largest value with its top bit
// clear, keeping the endpoints, and updates the errors.
@(private)
force_anchor_bit_zero :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,anchor_pos:int,
    $M:int) {
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    ISB :: MODE_ISB[M]
    px:=in_.pixels[anchor_pos]
    isbit:=ISB!=0 ? int(st.isbit) : 0
    lo,diff,base,wt:[4]i32
    for c in 0..<4 {
        lo[c]=i32(st.endpoints_q[0][c])
        diff[c]=i32(st.endpoints_q[1][c])-lo[c]
        base[c]=(i32(px[c])-lo[c])<<1
        wt[c]=(IB2!=0 && c==3) ? 0 : i32(in_.channel_weights[c])
    }
    ib_v:=isbit!=0 ? IB2 : IB
    anchor_bit_v:=u8(1<<uint(ib_v-1))
    idx_v:=&st.idxs[isbit]
    if idx_v[anchor_pos]&anchor_bit_v!=0 {
        f_old:=i32(lerp_factor(ib_v,int(idx_v[anchor_pos])))
        f_new:=i32(lerp_factor(ib_v,int(anchor_bit_v-1)))
        idx_v[anchor_pos]=anchor_bit_v-1
        sum:i32
        for c in 0..<4 {
            d_old:=(f_old*diff[c]+32)>>6
            d_new:=(f_new*diff[c]+32)>>6
            sum+=(base[c]-d_old-d_new)*(d_old-d_new)*wt[c]
        }
        st.err+=Error(sum)
    }
    when IB2!=0 {
        ib_s:=isbit!=0 ? IB : IB2
        anchor_bit_s:=u8(1<<uint(ib_s-1))
        idx_s:=&st.idxs[isbit~1]
        if idx_s[anchor_pos]&anchor_bit_s!=0 {
            f_old:=i32(lerp_factor(ib_s,int(idx_s[anchor_pos])))
            f_new:=i32(lerp_factor(ib_s,int(anchor_bit_s-1)))
            idx_s[anchor_pos]=anchor_bit_s-1
            d_old:=(f_old*diff[3]+32)>>6
            d_new:=(f_new*diff[3]+32)>>6
            vec_err:=st.err-st.scalar_err
            st.scalar_err+=Error((base[3]-d_old-d_new)*(d_old-d_new)*i32(in_.channel_weights[3]))
            st.err=vec_err+st.scalar_err
        }
    }
}

// New endpoints_q from the endpoints, keeping the indices; pbits -1 searches.
@(private)
update_subset_error :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,flags:Flags,pbits:int,
    $M:int) {
    st.pbits=calc_endpoints_and_pbits(&st.endpoints_q,st,flags,pbits,M)
    st.err=calc_subset_error(st,in_,&st.endpoints_q,&st.scalar_err,M)
}

@(private)
calc_indexes :: #force_inline proc "contextless" (st:^Subset_State,in_:^Subset_Input,flags:Flags,
    $M:int) {
    if flags&IDXS_EXACT!=0 {
        calc_indexes_exact(st,in_,M)
    } else {
        calc_indexes_linear_approx(st,in_,M)
    }
}

// Quantizes st.endpoints, finds pbits and indices and sets st.err.
@(private)
trial :: proc "contextless" (st:^Subset_State,in_:^Subset_Input,flags:Flags,pbits:int,$M:int) {
    st.pbits=calc_endpoints_and_pbits(&st.endpoints_q,st,flags,pbits,M)
    calc_indexes(st,in_,flags,M)
}

// Keeps st in cur_best when it is better.
@(private)
try_and_commit :: proc "contextless" (cur_best,st:^Subset_State,in_:^Subset_Input,flags:Flags,
    pbits:int,
    $M:int) -> bool {
    trial(st,in_,flags,pbits,M)
    if st.err>=cur_best.err {return false}
    cur_best^=st^
    return true
}

// As try_and_commit, taking the vector and the scalar channels separately.
@(private)
try_and_commit_partial :: proc "contextless" (cur_best,st:^Subset_State,in_:^Subset_Input,
    flags:Flags,
    pbits:int,$M:int) -> bool {
    IB2 :: MODE_IB2[M]
    trial(st,in_,flags,pbits,M)
    when IB2==0 {
        if st.err>=cur_best.err {return false}
        cur_best^=st^
        return true
    } else {
        any:=false
        isbit:=int(st.isbit)
        cur_best_vec_err:=cur_best.err-cur_best.scalar_err
        st_vec_err:=st.err-st.scalar_err
        if st_vec_err<cur_best_vec_err {
            merge_endpoints(&cur_best.endpoints,st.endpoints,~ENDPOINTS_ALPHA)
            merge_endpoints(&cur_best.endpoints_q,st.endpoints_q,~ENDPOINTS_ALPHA)
            cur_best.idxs[isbit]=st.idxs[isbit]
            cur_best.err=st_vec_err+cur_best.scalar_err
            cur_best_vec_err=st_vec_err
            any=true
        }
        if st.scalar_err<cur_best.scalar_err {
            merge_endpoints(&cur_best.endpoints,st.endpoints,ENDPOINTS_ALPHA)
            merge_endpoints(&cur_best.endpoints_q,st.endpoints_q,ENDPOINTS_ALPHA)
            cur_best.idxs[isbit~1]=st.idxs[isbit~1]
            cur_best.err=cur_best_vec_err+st.scalar_err
            cur_best.scalar_err=st.scalar_err
            any=true
        }
        return any
    }
}

// The bytes of channel A in a [2]Color read as u64.
@(private)
ENDPOINTS_ALPHA :: u64(0xff000000_ff000000)

// The bytes of mask in dst replaced by those of src, as one store: a later 8-byte load of dst
// then forwards from it.
@(private)
merge_endpoints :: #force_inline proc "contextless" (dst:^[2]Color,src:[2]Color,mask:u64) {
    d:=transmute(u64)dst^
    dst^=transmute([2]Color)((d&~mask)|(transmute(u64)src&mask))
}

@(private)
subset_init_empty :: #force_inline proc "contextless" (st:^Subset_State,isb,rb:u8) {
    st.err=ERROR_MAX
    st.scalar_err=ERROR_MAX/2
    st.pbits=0
    st.isbit=isb
    st.rbit=rb
    st.pca_subset=0
}

@(private)
subset_set_rbit :: proc "contextless" (st:^Subset_State,new_rbit:int) {
    if new_rbit==0 {return}
    st.rbit=u8(new_rbit)
    for e in 0..<2 {
        st.endpoints[e][3],st.endpoints[e][new_rbit-1]=st.endpoints[e][new_rbit-1],
            st.endpoints[e][3]
    }
}

// Gathers the texels of partition p (inds from SUBSET_TO_INDS) with
// rotation rbit.
@(private)
block_input_init :: proc "contextless" (bi:^Block_Input,block:^[16]Color,inds:u64,rbit:int) {
    inds:=inds
    for i in 0..<16 {
        bi.pixels[i]=block[inds&0xf]
        inds>>=4
    }
    if rbit!=0 {
        for i in 0..<16 {
            bi.pixels[i][3],bi.pixels[i][rbit-1]=bi.pixels[i][rbit-1],bi.pixels[i][3]
        }
    }
    for i in 16..<24 {bi.pixels[i]={}}
}

@(private)
subset_input_init :: proc "contextless" (si:^Subset_Input,pixels:[^]Color,num,alpha_chan,
    alpha_weight:int) {
    si.pixels=pixels
    si.num_pixels=num
    si.rcp_num_pixels=1.0/f32(num)
    for i in 0..<4 {si.channel_weights[i]=1}
    si.channel_weights[alpha_chan&3]=u16(alpha_weight)
}

@(private)
input_get :: proc "contextless" (input:^Input,block:^[16]Color,ns,p,rbit,alpha_weight:int) {
    block_input_init(&input.block,block,bc67.SUBSET_TO_INDS[(ns-1)&3 if ns<=3 else 0][p&63],
        rbit)
    total:=0
    for s in 0..<ns {
        num:=int(bc67.NUM_PIXELS_PER_SUBSET[ns][p&63][s])
        subset_input_init(&input.subsets[s],raw_data(input.block.pixels[total:]),num,
            alpha_chan_index(rbit),alpha_weight)
        total+=num
    }
}

@(private)
input_get_state :: proc "contextless" (input:^Input,block:^[16]Color,st:^Block_State,
    alpha_weight:=1) {
    ns:=MODE_NS
    input_get(input,block,ns[st.mode&7],int(st.p),int(st.subsets[0].rbit),alpha_weight)
}
